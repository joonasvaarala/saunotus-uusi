-- booking_188 rollback. Palauttaa korvatut funktiot tuotannon runkoihin. Poistaa montonio-avaimen vain jos tila on yhä off eikä maksuja ole.
-- Procountorin mode ja daily_enabled eivät muutu. Kopioitu clearing-avain voi jäädä (ei haittaa, vienti on pois päältä).
set local lock_timeout = '5s';
CREATE OR REPLACE FUNCTION booking.public_payment_options(p_token uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_mode text := booking._mobilepay_mode();
  v_vp text := booking._vismapay_mode();
  o booking.orders; v_unpaid numeric; v_can boolean := false; v_methods jsonb := '[]'::jsonb; v_order jsonb := null; v_pending boolean := false;
  v_any boolean;
begin
  v_any := v_mode <> 'off' or v_vp in ('test', 'live');
  if v_mode <> 'off' then
    v_methods := jsonb_build_array(jsonb_build_object('code', 'mobilepay', 'provider', 'vipps_mobilepay', 'label', 'MobilePay', 'label_en', 'MobilePay', 'test', v_mode = 'test',
      'start', jsonb_build_object('function', 'mobilepay-start', 'method', 'POST', 'body', case when p_token is not null then jsonb_build_object('order_token', p_token) else '{}'::jsonb end)));
  end if;
  if v_vp in ('test', 'live') then
    v_methods := v_methods || jsonb_build_array(jsonb_build_object('code', 'visma_pay', 'provider', 'visma_pay', 'label', 'Visma Pay', 'label_en', 'Visma Pay', 'test', v_vp = 'test',
      'start', jsonb_build_object('function', 'vismapay-start', 'method', 'POST', 'body', case when p_token is not null then jsonb_build_object('order_token', p_token) else '{}'::jsonb end)));
  end if;
  if p_token is null and booking._pay_later_test_enabled() then v_methods := v_methods || jsonb_build_array(booking._pay_later_method_json()); end if;
  if p_token is not null then
    if not booking._order_rl('popt', p_token, 120, 60) then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;
    select * into o from booking.orders where public_token = p_token;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
    v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
    v_can := v_any and o.external_source is null and o.status in ('pending', 'confirmed', 'completed', 'expired') and o.currency = 'EUR' and v_unpaid > 0.004
      and not (o.status = 'pending' and o.hold_kind = 'preliminary')
      and o.payment_status is distinct from 'invoiced' and not booking._order_pays_by_invoice(o.customer_kind, o.billing);
    v_pending := exists (select 1 from booking.payments where order_id = o.id and provider = 'mobilepay' and status = 'pending' and (link_expires_at is null or link_expires_at > now()));
    v_order := jsonb_build_object('order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status, 'unpaid', v_unpaid, 'can_pay_online', v_can, 'mobilepay_pending', v_pending) || booking._checkout_state_json(o.id);
    if not v_can then v_methods := '[]'::jsonb; end if;
    if booking._pay_later_test_enabled() and o.external_source is null and v_order ->> 'checkout_state' = 'awaiting_payment'
       and o.payment_status is distinct from 'invoiced' and not booking._order_pays_by_invoice(o.customer_kind, o.billing) then
      v_methods := v_methods || jsonb_build_array(booking._pay_later_method_json());
    end if;
  end if;
  return jsonb_build_object('ok', true, 'online_enabled', v_any, 'methods', v_methods, 'order', v_order);
end $function$;
CREATE OR REPLACE FUNCTION booking.public_payment_link_info(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- booking_177: maksulinkkisivun (/maksa/?p=, /en/pay/?p=) yhteenveto ENNEN maksun aloitusta. Vain luku (ei muuta tilausta eikä maksua; ainoa kirjoitus
-- on yhteinen nopeusrajoitin _order_rl). Palauttaa vain vähimmäistiedot: tila + kieletön syykoodi, summa, valuutta, tilausnumero, rivit (nimi, pvm, klo
-- Europe/Helsinki) ja voimassaolo. EI asiakkaan nimeä, sähköpostia, puhelinta, osoitetta, muistiinpanoja, tilauksen tokenia eikä maksuvälittäjän tunnisteita.
-- Tila seuraa vismapay_payment_prepare-funktion linkkihaaran tarkistuksia (sama järjestys), joten "open" = painike voi käynnistää maksun.
--   open | paid (link_paid, order_paid) | expired (link_expired, payment_cancelled, payment_not_pending) | replaced (replaced, link_stale)
--   not_payable (other_provider_started, order_not_payable, vismapay_off) | not_found (tuntematon tai puuttuva token; ei muita tietoja)
-- booking_178: peruttu/hylätty Visma-yritys ei kuluta maksulinkkiä (vismapay_payment_apply jättää maksun pending-tilaan) → tila on taas "open" ja
-- last_attempt = cancelled | failed kertoo sivulle, että edellinen yritys jäi kesken (muuten null). payment_cancelled jää vain vanhoille (ennen booking_178:aa
-- perutuille) riveille; peruttu + summa ei enää vastaa maksamatonta → replaced (link_stale).
declare
  pay booking.payments; o booking.orders;
  v_ip_max int; v_unpaid numeric; v_paid_any boolean; v_newer boolean; v_mode text;
  v_status text; v_reason text; v_items jsonb;
begin
  v_ip_max := coalesce((booking._setting('rl_order_get_per_10min', '60'::jsonb) #>> '{}')::int, 60);
  if not booking._order_rl('pli', p_token, v_ip_max, v_ip_max) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited');
  end if;
  if p_token is not null then
    select * into pay from booking.payments where link_token = p_token;
  end if;
  if pay.id is null then
    return jsonb_build_object('ok', true, 'status', 'not_found', 'reason', 'not_found', 'can_pay', false);
  end if;
  select * into o from booking.orders where id = pay.order_id;

  v_unpaid := coalesce((booking._order_balance(o.id) ->> 'unpaid')::numeric, 0);
  v_paid_any := exists (select 1 from booking.payments x where x.order_id = o.id and x.status in ('paid', 'partially_refunded', 'refunded'));
  -- korvattu: tilaukselle on kirjattu tämän jälkeen uusi maksu tai maksulinkki (_create_link_payment / admin_record_payment perui tämän)
  v_newer := exists (select 1 from booking.payments x where x.order_id = o.id and x.id > pay.id);
  v_mode := booking._vismapay_mode();

  if pay.status in ('paid', 'partially_refunded', 'refunded') then
    v_status := 'paid'; v_reason := 'link_paid';
  elsif pay.status <> 'pending' then
    if v_unpaid <= 0.004 and v_paid_any then v_status := 'paid'; v_reason := 'order_paid';
    elsif v_newer then v_status := 'replaced'; v_reason := 'replaced';
    elsif pay.link_expires_at is not null and pay.link_expires_at < now() then v_status := 'expired'; v_reason := 'link_expired';
    elsif pay.amount > v_unpaid + 0.004 then v_status := 'replaced'; v_reason := 'link_stale';
    elsif pay.provider_status in ('failed', 'cancelled') then v_status := 'expired'; v_reason := 'payment_cancelled';
    else v_status := 'expired'; v_reason := 'payment_not_pending'; end if;
  elsif pay.provider = 'mobilepay' and pay.provider_ref is not null then
    v_status := 'not_payable'; v_reason := 'other_provider_started';
  elsif pay.link_expires_at is not null and pay.link_expires_at < now() then
    if v_unpaid <= 0.004 and v_paid_any then v_status := 'paid'; v_reason := 'order_paid';
    elsif v_newer then v_status := 'replaced'; v_reason := 'replaced';
    else v_status := 'expired'; v_reason := 'link_expired'; end if;
  elsif pay.amount > v_unpaid + 0.004 then
    if v_unpaid <= 0.004 and v_paid_any then v_status := 'paid'; v_reason := 'order_paid';
    else v_status := 'replaced'; v_reason := 'link_stale'; end if;
  elsif o.external_source is not null or o.status not in ('pending', 'confirmed', 'completed', 'expired') or o.currency <> 'EUR'
     or o.payment_status = 'invoiced' or booking._order_pays_by_invoice(o.customer_kind, o.billing)
     or (o.status = 'pending' and o.hold_kind = 'preliminary') then
    v_status := 'not_payable'; v_reason := 'order_not_payable';
  elsif v_mode is null or v_mode not in ('test', 'live') then
    v_status := 'not_payable'; v_reason := 'vismapay_off';
  else
    v_status := 'open'; v_reason := 'open';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', it.kind,
           'name', it.product_name,
           'name_en', nullif(btrim(coalesce(ad.name_en, kp.name_en, '')), ''),
           'quantity', it.quantity,
           'date', to_char(r.starts_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD'),
           'start', to_char(r.starts_at at time zone 'Europe/Helsinki', 'HH24:MI'),
           'end', to_char(r.ends_at at time zone 'Europe/Helsinki', 'HH24:MI'),
           'end_date', to_char(r.ends_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD'))
         order by coalesce(it.parent_item_id, it.id), it.parent_item_id is not null, r.starts_at nulls last, it.id), '[]'::jsonb)
    into v_items
    from booking.order_items it
    left join kb.products kp on kp.id = it.product_id and it.kind in ('reservation', 'product')
    left join booking.addons ad on ad.id = it.addon_id
    left join booking.reservations r on r.order_item_id = it.id and r.order_id = it.order_id and r.hidden_at is null and r.status <> 'cancelled'
   where it.order_id = o.id and it.kind <> 'discount';

  return jsonb_build_object(
    'ok', true, 'status', v_status, 'reason', v_reason, 'can_pay', v_status = 'open',
    'amount', pay.amount, 'amount_cents', round(pay.amount * 100)::bigint, 'currency', pay.currency,
    'order_no', o.order_no, 'order_total', o.total_gross,
    'expires_at', pay.link_expires_at,
    'expires_date', to_char(pay.link_expires_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD'),
    'expires_time', to_char(pay.link_expires_at at time zone 'Europe/Helsinki', 'HH24:MI'),
    'paid_at', case when v_reason = 'link_paid' then pay.paid_at end,
    'last_attempt', case when v_status = 'open' and pay.provider_status in ('cancelled', 'failed') then pay.provider_status end,
    'items', v_items);
end $function$;
CREATE OR REPLACE FUNCTION booking.public_get_order(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders; v_cust text; v_bal jsonb; v_end timestamptz; v_conf_n int; v_conf_start timestamptz; v_kind text; v_hours int;
  v_items jsonb; v_res jsonb; v_pay jsonb; v_rec jsonb; v_creq jsonb; v_ups_a jsonb; v_ups_t jsonb; v_can_add boolean; v_pl text; v_open boolean; v_status text; v_online boolean;
  v_cancel_dl timestamptz; v_cancel_closed boolean;   -- booking_149: asiakkaan peruutuspyynnön takaraja
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if not booking._order_rl('get', p_token, (booking._setting('rl_order_get_per_10min', '60'::jsonb) #>> '{}')::int, (booking._setting('rl_order_get_per_10min', '60'::jsonb) #>> '{}')::int) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  v_hours := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  select split_part(c.name, ' ', 1) into v_cust from booking.customers c where c.id = o.customer_id;
  v_bal := booking._order_balance(o.id);
  v_status := case when o.status = 'pending' and exists (select 1 from booking.reservations r where r.order_id = o.id) and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) and not booking._order_mp_inflight(o.id) then 'expired' else o.status end;
  v_online := booking._vismapay_online();
  v_pl := booking._setting('payment_link_path', to_jsonb('/maksa/'::text)) #>> '{}';

  select coalesce(jsonb_agg(jsonb_build_object('name', it.product_name, 'quantity', it.quantity, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate, 'kind', it.kind) order by it.id), '[]'::jsonb)
    into v_items from booking.order_items it where it.order_id = o.id;
  select coalesce(jsonb_agg(jsonb_build_object('reservation_id', r.id, 'product_id', r.product_id, 'product_name', oi.product_name, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons,
           'option', booking._option_json(r.product_option_id),
           'option_label', booking._option_label(r.product_id, o.locale), 'option_label_fi', booking._option_label(r.product_id, 'fi'), 'option_label_en', booking._option_label(r.product_id, 'en'), 'option_choices', booking._product_options_json(r.product_id),
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() and not booking._order_mp_inflight(r.order_id) then 'expired' else r.status end,
           'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', a.addon_id, 'name', a.product_name, 'quantity', a.quantity, 'line_total', a.line_total_gross) order by a.id)
                                 from booking.order_items a where a.parent_item_id = r.order_item_id and a.kind = 'addon'), '[]'::jsonb)) order by r.starts_at), '[]'::jsonb)
    into v_res from booking.reservations r left join booking.order_items oi on oi.id = r.order_item_id where r.order_id = o.id and r.hidden_at is null;
  select coalesce(jsonb_agg(jsonb_build_object('status', p.status, 'amount', p.amount, 'paid_at', p.paid_at, 'method_label', coalesce(pm.label, p.method),
           'link_token', case when p.status = 'pending' and p.provider = 'visma_pay' and (p.link_expires_at is null or p.link_expires_at > now()) then p.link_token end,
           'link_path', case when p.status = 'pending' and p.provider = 'visma_pay' and (p.link_expires_at is null or p.link_expires_at > now()) then v_pl || '?p=' || p.link_token end,
           'refunded', p.refunded_amount) order by p.created_at, p.id), '[]'::jsonb)
    into v_pay from booking.payments p left join booking.payment_methods pm on pm.code = p.method
   where p.order_id = o.id and p.status <> 'cancelled'
     and not (p.provider = 'manual' and p.status = 'pending' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id));
  select coalesce(jsonb_agg(jsonb_build_object('receipt_no', x.receipt_no, 'kind', x.kind, 'issued_at', x.issued_at, 'token', x.public_token, 'total', x.total_gross) order by x.issued_at, x.id), '[]'::jsonb)
    into v_rec from booking.receipts x where x.order_id = o.id;
  select jsonb_build_object('status', q.status, 'created_at', q.created_at) into v_creq from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' order by q.created_at desc, q.id desc limit 1;

  select max(r.ends_at) into v_end from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at);
  v_can_add := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now() and not booking._order_invoice_locked(o.id);
  v_open := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now() and not exists (select 1 from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' and q.status = 'open');
  -- booking_149: asiakas voi pyytää peruutusta (ja sen hyvitystä) vain, kun ensimmäisen voimassa olevan vuoron alkuun on vähintään customer_change_hours_before tuntia (oletus 48).
  v_cancel_dl := booking._customer_cancel_deadline(o.id);
  v_cancel_closed := v_open and (v_cancel_dl is null or v_cancel_dl < now());
  v_open := v_open and v_cancel_dl is not null and v_cancel_dl >= now();
  select count(*), min(r.starts_at) into v_conf_n, v_conf_start from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  v_kind := case when exists (select 1 from booking.reservations r where r.order_id = o.id and r.rule_id is not null) then 'rules'
                 when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.order_id = o.id and r.rule_id is null) then 'slots'
                 else 'other' end;

  if v_can_add then
    select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name, 'name_en', a.name_en, 'description', a.description, 'description_en', a.description_en, 'price', a.price_gross, 'vat_rate', a.vat_rate,
             'max', x.lim, 'reservation_ids', x.rids) order by a.sort_order, a.id), '[]'::jsonb) into v_ups_a
      from booking.addons a
      join lateral (select max(booking._addon_limit(a.max_per_person, r.persons)) lim, jsonb_agg(r.id order by r.id) rids
                      from booking.reservations r left join booking.product_config pc on pc.product_id = r.product_id left join kb.products p on p.id = r.product_id
                     where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at) and r.ends_at > now()
                       and coalesce(case when pc.sale_kind = 'other' and pc.resource_class = 'resourced' then case when p.category = 'event' then 'event' else 'resource' end else r.mode end, r.mode) = any (a.applies_modes)) x on x.rids is not null
     where a.active;
    select coalesce(jsonb_agg(jsonb_build_object('product_id', p.id, 'name', p.name, 'name_en', p.name_en, 'price', p.price, 'duration_minutes', coalesce(pc.duration_minutes, p.duration_minutes),
             'description', p.description, 'description_en', p.description_en, 'category', p.category) order by pc.sort_order, p.id), '[]'::jsonb) into v_ups_t
      from booking.product_config pc join kb.products p on p.id = pc.product_id
     where pc.public_slots and pc.bookable and pc.shop_visible and pc.lifecycle = 'current' and p.active and p.price is not null;
  end if;

  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'status', v_status, 'payment_status', o.payment_status, 'currency', o.currency, 'locale', coalesce(o.locale, 'fi'),
    'created_at', o.created_at, 'first_name', v_cust, 'customer_kind', o.customer_kind, 'invoice_method', case when o.customer_kind <> 'private' then o.billing ->> 'invoice_method' end,
    'total', v_bal -> 'total', 'paid', v_bal -> 'net_paid', 'refunded', v_bal -> 'refunded', 'unpaid', v_bal -> 'unpaid',
    'items', v_items, 'reservations', v_res, 'payments', v_pay, 'receipts', v_rec,
    'invoice_locked', booking._order_invoice_locked(o.id),
    'can_add', v_can_add, 'add_until', case when v_can_add then v_end end,
    'can_change', (o.status = 'confirmed' and o.external_source is null and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now() and v_kind in ('rules', 'slots')),
    'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end, 'change_hours_before', v_hours,
    'change_via', case v_kind when 'slots' then 'public_change_order_time' when 'rules' then 'public_change_order_time' end, 'booking_kind', v_kind,
    'can_request_cancel', v_open, 'cancel_request', v_creq,
    'cancel_deadline', v_cancel_dl, 'cancel_hours_before', v_hours, 'cancel_closed', coalesce(v_cancel_closed, false), 'online_payment_enabled', v_online,
    'upsell', jsonb_build_object('addons', coalesce(v_ups_a, '[]'::jsonb), 'treatments', coalesce(v_ups_t, '[]'::jsonb)),
    'instructions', booking._order_full_instructions(o.id, coalesce(o.locale, 'fi')))
    || booking._checkout_state_json(o.id);
end $function$;
CREATE OR REPLACE FUNCTION booking._create_link_payment(p_order_id bigint, p_expires_days integer DEFAULT NULL::integer, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- booking_184: p_expires_days null = maksulinkki ilman takarajaa (link_expires_at null, raw.paylink = 'no_deadline'); muuten 1–60 päivää kuten ennen.
-- Uudelleenkäyttö (sama summa, yksi avoin Visma-rivi): takarajaton pyyntö käyttää vain merkittyä takarajatonta linkkiä; takarajallinen pyyntö käyttää
-- avointa riviä kuten ennen, paitsi henkilökunta (is_staff) korvaa takarajattoman linkin takarajallisella. Asiakkaan/järjestelmän polut eivät siis peru
-- henkilökunnan takarajatonta linkkiä, kun summa ei muutu.
declare o booking.orders; v_tot numeric; v_open booking.payments; v_n int; v_id bigint; v_token uuid; v_exp timestamptz; v_unpaid numeric; v_open_nd boolean;
begin
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if booking._order_invoice_locked(o.id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.'); end if;
  if o.external_source is not null or o.status not in ('pending','confirmed','completed') then perform booking._err('order_not_editable', 'Tilaukselle ei voi luoda maksulinkkiä'); end if;
  if p_expires_days is not null and (p_expires_days < 1 or p_expires_days > 60) then perform booking._err('invalid_param', 'Linkin voimassaolo 1–60 päivää'); end if;
  select coalesce(sum(remaining) filter (where remaining > 0), 0) into v_tot from booking._order_uncovered(o.id, false);
  v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
  v_tot := least(v_tot, v_unpaid);
  if v_tot <= 0.004 then perform booking._err('nothing_to_pay', 'Ei maksettavaa'); end if;
  select count(*) into v_n from booking.payments where order_id = o.id and status = 'pending' and provider = 'visma_pay' and (link_expires_at is null or link_expires_at > now());
  if v_n = 1 then
    select * into v_open from booking.payments where order_id = o.id and status = 'pending' and provider = 'visma_pay' and (link_expires_at is null or link_expires_at > now());
    v_open_nd := v_open.link_expires_at is null and coalesce(v_open.raw ->> 'paylink', '') = 'no_deadline';
    if v_open.amount = v_tot and (case when p_expires_days is null then v_open_nd
                                       when v_open_nd then not booking.is_staff()
                                       else true end) then
      return jsonb_build_object('payment_id', v_open.id, 'link_token', v_open.link_token, 'amount', v_open.amount, 'expires_at', v_open.link_expires_at, 'reused', true);
    end if;
  end if;
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu uudella maksulinkillä')
   where order_id = o.id and status = 'pending' and provider = 'visma_pay';
  v_exp := case when p_expires_days is null then null else now() + make_interval(days => p_expires_days) end;
  insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, raw, note, created_by)
  values (o.id, 'visma_pay', 'visma_pay', 'pending', v_tot, o.currency, v_exp,
          case when v_exp is null then jsonb_build_object('paylink', 'no_deadline') end, p_note, auth.uid()) returning id, link_token into v_id, v_token;
  insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
  select v_id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
  -- jos rivit ylittävät jäännöksen (poikkeus: hyvitetty/poistettu rivi), pienennetään suurinta riviä
  update booking.payment_lines set amount_gross = amount_gross - ((select sum(amount_gross) from booking.payment_lines where payment_id = v_id) - v_tot)
   where id = (select id from booking.payment_lines where payment_id = v_id order by amount_gross desc, id limit 1)
     and (select sum(amount_gross) from booking.payment_lines where payment_id = v_id) > v_tot;
  perform booking._refresh_order_payment(o.id);
  return jsonb_build_object('payment_id', v_id, 'link_token', v_token, 'amount', v_tot, 'expires_at', v_exp, 'reused', false);
end $function$
;
CREATE OR REPLACE FUNCTION booking.admin_create_payment_link(p_order_id bigint, p_send_email boolean DEFAULT false, p_expires_days integer DEFAULT NULL::integer, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v jsonb; v_pid bigint; v_mail boolean := false;
begin
  perform booking._require_permission('payments.manage');
  v := booking._create_link_payment(p_order_id, p_expires_days, p_note);
  v_pid := (v ->> 'payment_id')::bigint;
  if p_send_email then v_mail := booking._enqueue_email('payment_link', p_order_id, null, v_pid, 'payment_link:' || v_pid || ':' || to_char(now(), 'YYYYMMDDHH24MI')); end if;
  return jsonb_build_object('ok', true) || (booking._link_json(v_pid)) || jsonb_build_object('online_payment_enabled', booking._vismapay_online(), 'email_queued', v_mail);
end $function$
;
CREATE OR REPLACE FUNCTION booking._vc_redeem(p_id bigint, p_amount numeric, p_partner_ref text, p_note text, p_by text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c booking.voucher_claims; o booking.orders; v jsonb; v_due numeric; v_link jsonb; v_pid bigint; v_diff numeric; v_mail boolean := false;
begin
  if p_amount is not null then
    if p_amount <= 0 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Lahjakortin arvon pitää olla yli 0 € (enintään 2 desimaalia)'); end if;
    select * into c from booking.voucher_claims where id = p_id for update;
    if found and c.status in ('open', 'processing', 'problem') then
      select * into o from booking.orders where id = c.order_id for update;
      if found and o.status in ('pending', 'confirmed') and o.external_source is null then
        v_due := booking._vc_due(o, c);
        if p_amount > v_due then
          perform booking._err('voucher_exceeds_total', format('Lahjakortin arvo %s € ylittää maksettavan summan %s €', p_amount, v_due));
        end if;
      end if;
    end if;
  end if;
  v := booking._vc_mark_redeemed(p_id, p_amount, p_partner_ref, p_note, p_by);
  -- booking_174 (booking_176: myös botti): arvo pienempi kuin maksettava → erotus maksulinkkinä asiakkaalle (Visma Pay -linkki, sähköposti payment_link / voucher_difference)
  if v_due is not null and p_amount < v_due and not coalesce((v ->> 'already')::boolean, false) and (v ->> 'payment_id') is not null then
    select * into o from booking.orders where id = o.id;
    v_link := booking._create_link_payment(o.id, null::integer, 'Kumppanilahjakortin erotus, pyyntö #' || p_id);   -- booking_184: ei takarajaa
    v_pid := (v_link ->> 'payment_id')::bigint;
    v_diff := (v_link ->> 'amount')::numeric;
    v_mail := booking._enqueue_email('payment_link', o.id, null, v_pid, 'payment_link:voucher_difference:' || p_id || ':' || v_pid,
                jsonb_build_object('variant', 'voucher_difference', 'claim_id', p_id, 'voucher_value', (v ->> 'amount')::numeric, 'difference', v_diff,
                                   'total', (v ->> 'amount')::numeric + v_diff));
    -- booking_176: erotuksen maksusta ei kuittisähköpostia (_on_payment_paid)
    insert into booking.vc_difference_payments(order_id, claim_id, payment_id) values (o.id, p_id, v_pid) on conflict (payment_id) do nothing;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (auth.uid(), booking._jwt_role(), 'booking.voucher_claims', p_id::text, 'VOUCHER_DIFFERENCE_LINK', null,
            jsonb_build_object('voucher_value', (v ->> 'amount')::numeric, 'due', v_due, 'difference', v_diff, 'link_payment_id', v_pid, 'email_queued', v_mail, 'by', p_by));
  end if;
  return v || jsonb_build_object('voucher_value', case when (v ->> 'already')::boolean then null else (v ->> 'amount')::numeric end, 'due', v_due,
    'difference', v_diff, 'payment_link', case when v_pid is not null then booking._link_json(v_pid) || jsonb_build_object('online_payment_enabled', booking._vismapay_online()) end,
    'email_queued', v_mail);
end $function$
;
CREATE OR REPLACE FUNCTION booking.admin_set_procountor_settings(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  cur booking.integration_config;
  s jsonb; v_mode text; env text; approved text; vat text; prefix text; iban text;
  accounts jsonb; sales jsonb := '{}'::jsonb; clearing jsonb := '{}'::jsonb; rounding text;
  k text; v text;
  rates text[] := array['25.5','13.5','0','14','24','10'];
  methods text[] := array['cash','card_terminal','mobilepay','bank_transfer','invoice','gift_card','partner_voucher','partner_voucher_kokemuskauppa','partner_voucher_offerilla','partner_voucher_elamyslahjat','visma_pay','annual_card','pay_later','other'];
begin
  perform booking._require_permission('settings.edit');
  if p is null or jsonb_typeof(p) <> 'object' then perform booking._err('invalid_setting', 'Asetusten pitää olla objekti'); end if;
  if booking._json_has_secret_key(p) then perform booking._err('secrets_not_allowed', 'Salaisuuksia ei tallenneta asetuksiin'); end if;
  select * into cur from booking.integration_config where key = 'procountor';
  if not found then perform booking._err('not_configured', 'procountor-asetus puuttuu'); end if;
  v_mode := coalesce(nullif(btrim(p->>'mode'), ''), cur.mode);
  if v_mode not in ('off', 'dry_run', 'live') then perform booking._err('invalid_setting', 'Tila on off, dry_run tai live'); end if;
  env := lower(btrim(coalesce(p->>'environment', cur.settings->>'environment', 'pts')));
  if env in ('sandbox', '') then env := 'pts'; end if;
  if env not in ('pts', 'prod') then perform booking._err('invalid_setting', 'Ympäristö on pts tai prod'); end if;
  if p ? 'approved_by' then approved := btrim(coalesce(p->>'approved_by', ''));
  else approved := btrim(coalesce(cur.settings->>'approved_by', '')); end if;
  if approved <> '' and (char_length(approved) < 3 or char_length(approved) > 80 or approved like 'eyJ%') then
    perform booking._err('invalid_setting', 'approved_by on nimi ja päivä, ei tunnusta');
  end if;
  if v_mode = 'live' and approved = '' then perform booking._err('approval_required', 'Yhdistetty tila vaatii approved_by'); end if;
  if p ? 'daily_enabled' and jsonb_typeof(p->'daily_enabled') is distinct from 'boolean' then perform booking._err('invalid_setting', 'daily_enabled on totuusarvo'); end if;
  if p ? 'vat_status' then vat := btrim(coalesce(p->>'vat_status', ''));
  else vat := btrim(coalesce(cur.settings->>'vat_status', '')); end if;
  if vat <> '' and vat !~ '^[0-9]{1,4}$' then perform booking._err('invalid_setting', 'ALV-tila on 1–4 numeroa'); end if;
  prefix := btrim(coalesce(nullif(p->>'api_prefix', ''), cur.settings->>'api_prefix', '/supported/api'));
  if prefix !~ '^/api$|^/latest/api$|^/supported/api$|^/v[0-9]{4}/api$' then perform booking._err('invalid_setting', 'API-etuliite ei kelpaa'); end if;
  if p ? 'bank_account' then iban := upper(regexp_replace(coalesce(p->>'bank_account', ''), '\s', '', 'g'));
  else iban := coalesce(cur.settings->>'bank_account', ''); end if;
  if iban <> '' and iban !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{10,30}$' then perform booking._err('invalid_setting', 'Tilinumero on IBAN tai tyhjä'); end if;
  accounts := coalesce(p->'accounts', '{}'::jsonb);
  if jsonb_typeof(accounts) <> 'object' then perform booking._err('invalid_setting', 'accounts on objekti'); end if;
  rounding := btrim(coalesce(accounts->>'rounding', ''));
  if rounding <> '' and rounding !~ '^[0-9A-Za-z]{1,20}$' then perform booking._err('invalid_setting', 'Tilinumero ei kelpaa'); end if;
  if accounts ? 'sales_by_vat' then
    if jsonb_typeof(accounts->'sales_by_vat') <> 'object' then perform booking._err('invalid_setting', 'sales_by_vat on objekti'); end if;
    for k, v in select key, btrim(value) from jsonb_each_text(accounts->'sales_by_vat') loop
      if not (k = any (rates)) then perform booking._err('invalid_setting', 'Tuntematon ALV-kanta: ' || k); end if;
      if v <> '' and v !~ '^[0-9A-Za-z]{1,20}$' then perform booking._err('invalid_setting', 'Tilinumero ei kelpaa'); end if;
      if v <> '' then sales := sales || jsonb_build_object(k, v); end if;
    end loop;
  end if;
  if accounts ? 'clearing_by_method' then
    if jsonb_typeof(accounts->'clearing_by_method') <> 'object' then perform booking._err('invalid_setting', 'clearing_by_method on objekti'); end if;
    for k, v in select key, btrim(value) from jsonb_each_text(accounts->'clearing_by_method') loop
      if not (k = any (methods)) then perform booking._err('invalid_setting', 'Tuntematon maksutapa: ' || k); end if;
      if v <> '' and v !~ '^[0-9A-Za-z]{1,20}$' then perform booking._err('invalid_setting', 'Tilinumero ei kelpaa'); end if;
      if v <> '' then clearing := clearing || jsonb_build_object(k, v); end if;
    end loop;
  end if;
  if v_mode = 'live' and (vat !~ '^[0-9]{1,4}$' or sales = '{}'::jsonb or clearing = '{}'::jsonb) then
    perform booking._err('live_incomplete', 'Yhdistetty tila vaatii ALV-tilan, vähintään yhden myyntitilin ja maksutavan tilin');
  end if;
  s := coalesce(cur.settings, '{}'::jsonb)
    || jsonb_build_object(
         'environment', env,
         'daily_enabled', case when p ? 'daily_enabled' then (p->>'daily_enabled')::boolean else coalesce((cur.settings->>'daily_enabled')::boolean, false) end,
         'api_prefix', prefix,
         'vat_status', vat,
         'approved_by', nullif(approved, ''),
         'bank_account', nullif(iban, ''),
         'accounts', jsonb_build_object('rounding', nullif(rounding, ''), 'sales_by_vat', sales, 'clearing_by_method', clearing));
  s := jsonb_strip_nulls(s);
  update booking.integration_config
     set mode = v_mode, settings = s, updated_by = auth.uid()
   where key = 'procountor';
  return booking.admin_get_procountor_settings();
end $function$;
create or replace function booking.public_checkout_payment_options() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_mp text := booking._mobilepay_mode();
  v_vp text := booking._vismapay_mode();
  v_gc boolean := coalesce((booking._setting('gift_cards.redeem_enabled', 'false'::jsonb) #>> '{}')::boolean, false);
  v_m jsonb := '[]'::jsonb;
begin
  if v_mp <> 'off' then
    v_m := v_m || jsonb_build_array(jsonb_build_object('code', 'mobilepay', 'kind', 'online', 'provider', 'vipps_mobilepay', 'label', 'MobilePay', 'label_en', 'MobilePay', 'test', v_mp = 'test',
      'start', jsonb_build_object('function', 'mobilepay-start', 'method', 'POST', 'body', jsonb_build_object('order_token', '<tilauksen public_token>'))));
  end if;
  if v_vp in ('test', 'live') then
    v_m := v_m || jsonb_build_array(jsonb_build_object('code', 'visma_pay', 'kind', 'online', 'provider', 'visma_pay', 'label', 'Visma Pay', 'label_en', 'Visma Pay', 'test', v_vp = 'test',
      'start', jsonb_build_object('function', 'vismapay-start', 'method', 'POST', 'body', jsonb_build_object('order_token', '<tilauksen public_token>'))));
  end if;
  if v_gc then
    v_m := v_m || jsonb_build_array(jsonb_build_object('code', 'gift_card', 'kind', 'redeem', 'provider', 'gift_card', 'label', 'Lahjakortti', 'label_en', 'Gift card', 'test', false,
      'check_rpc', 'public_check_gift_card', 'apply_rpc', 'public_apply_gift_card'));
  end if;
  if booking._pay_later_test_enabled() then v_m := v_m || jsonb_build_array(booking._pay_later_method_json()); end if;
  return jsonb_build_object('ok', true, 'methods', v_m, 'mobilepay_enabled', v_mp <> 'off', 'vismapay_enabled', v_vp in ('test', 'live'), 'gift_card_redeem_enabled', v_gc, 'pay_later_test_enabled', booking._pay_later_test_enabled(),
    'hold_until_paid', (booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}') <> 'pay_later', 'hold_minutes', booking._checkout_hold_minutes(),
    'group_threshold_persons', booking._checkout_cfg_int('checkout_group_threshold_persons', 0, 0, 1000), 'group_hold_days', booking._checkout_cfg_int('checkout_group_hold_days', 7, 1, 60));
end $$;
create or replace function booking._checkout_online_available() returns boolean language sql stable security definer set search_path = '' as $$
  select booking._mobilepay_mode() <> 'off'
$$;
create or replace function booking._order_mp_inflight(p_order bigint) returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from booking.payments p
     where p.order_id = p_order and p.provider = 'mobilepay' and p.status = 'pending' and p.provider_ref is not null
       and coalesce(p.raw #>> '{mobilepay,last_state}', 'CREATED') in ('CREATED', 'AUTHORIZED')
       and coalesce(nullif(p.raw #>> '{mobilepay,attempt_started_at}', '')::timestamptz, p.created_at)
           > now() - make_interval(mins => booking._checkout_cfg_int('checkout_mobilepay_grace_minutes', 15, 0, 60)))
$$;

drop trigger if exists payments_montonio_attempt on booking.payments;
drop trigger if exists integration_config_montonio_guard on booking.integration_config;
drop function if exists booking.admin_set_montonio_mode(text,text);
drop function if exists booking.admin_get_montonio_status();
drop function if exists booking.montonio_refund_lookup(text,text);
drop function if exists booking.montonio_refund_release(bigint,jsonb);
drop function if exists booking.montonio_refund_fail(bigint,jsonb);
drop function if exists booking.montonio_refund_complete(bigint,text,jsonb);
drop function if exists booking.montonio_refund_stamp(bigint,text,text,jsonb);
drop function if exists booking.montonio_refund_claim(bigint,integer);
drop function if exists booking.montonio_order_refs(uuid);
drop function if exists booking.montonio_payment_apply(text,text,numeric,jsonb);
drop function if exists booking.montonio_payment_lookup(text);
drop function if exists booking.montonio_payment_event(text,text,text,text,jsonb);
drop function if exists booking.montonio_payment_prepare(uuid,uuid,text);
drop function if exists booking._montonio_attempt_trg();
drop function if exists booking._montonio_online();
drop function if exists booking._montonio_mode();
drop function if exists booking._montonio_guard_trg();
drop table if exists booking.montonio_attempts;
delete from booking.integration_config where key = 'montonio' and mode = 'off'
  and not exists (select 1 from booking.payments where provider = 'montonio');
delete from booking.payment_methods where code = 'montonio'
  and not exists (select 1 from booking.payments where method = 'montonio' or provider = 'montonio');
alter table booking.integration_config drop constraint if exists integration_config_key_check;
alter table booking.integration_config add constraint integration_config_key_check
  check (key in ('resend', 'vismapay', 'procountor', 'mobilepay', 'booking_calendar'));
alter table booking.integration_config drop constraint if exists integration_config_test_only_online;
alter table booking.integration_config add constraint integration_config_test_only_online
  check (mode <> 'test' or key in ('mobilepay', 'vismapay'));
