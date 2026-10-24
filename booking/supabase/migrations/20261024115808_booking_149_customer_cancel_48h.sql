-- booking_149: asiakkaan itsepalveluperuutuksen ja -hyvityksen takaraja 48 h (Joonaksen päätös 24.10.2026).
-- Asiakkaan itse tekemä peruutus (tilaussivun peruutuspyyntö public_request_cancel, jonka kautta myös hyvitys) ei ole sallittu,
-- kun ensimmäisen voimassa olevan vuoron alkuun on alle customer_change_hours_before tuntia (olemassa oleva asetus, tuotannossa 48;
-- oletus 48, jos riviä ei ole). Sama asetus rajaa jo asiakkaan ajanmuutoksen (public_change_booking / public_change_treatment_booking /
-- public_change_order_time → _change_booking_core) ja sen kautta syntyvän hyvityspyynnön (refund_due).
-- * uusi booking._customer_cancel_deadline(order_id): takaraja = ensimmäisen voimassa olevan, päättymättömän vuoron alku − asetuksen tunnit
-- * public_request_cancel: palvelin hylkää liian myöhäisen pyynnön koodilla cancel_too_late (ei pyyntöä, ei ilmoitusta, ei sähköpostia)
-- * public_get_order: can_request_cancel = false takarajan jälkeen; uudet kentät cancel_deadline, cancel_hours_before, cancel_closed
-- * settings.customer_change_hours_before: rivi varmistetaan (on conflict do nothing → tuotannon arvo 48 ei muutu), kuvaus päivitetään
-- Ennallaan: public_cancel_booking (vain maksamaton, pending-tilainen tilaus: pidon vapautus, ei rahaa), hallinnan peruutus ja hyvitys
-- (admin_cancel_reservation, admin_refund, admin_refund_order, admin_resolve_order_request, admin_set_reservation_status, admin_change_booking)
-- eivät katso takarajaa. Ei taulumuutoksia, ei public-skeemaa, ei jonotuslistan, lahjakorttilistan eikä kassan vuosikorttikoodin funktioita.
-- Uudelleenajettava. Rollback: booking/supabase/rollbacks/20261024115808_booking_149_ROLLBACK.sql
set local lock_timeout = '5s';

insert into booking.settings(key, value, description, is_public)
values ('customer_change_hours_before', '48'::jsonb, 'Kuinka monta tuntia ennen vuoron alkua asiakas voi viimeistään itse muuttaa varaustaan (siirto toiseen vapaaseen vuoroon / henkilömäärä) tai lähettää peruutuspyynnön tilaussivulta (peruutus ja hyvitys). Tämän jälkeen asiakas ei voi perua eikä pyytää hyvitystä itse; henkilökunnan peruutukset ja hyvitykset toimivat aina.', true)
on conflict (key) do nothing;
update booking.settings set description = 'Kuinka monta tuntia ennen vuoron alkua asiakas voi viimeistään itse muuttaa varaustaan (siirto toiseen vapaaseen vuoroon / henkilömäärä) tai lähettää peruutuspyynnön tilaussivulta (peruutus ja hyvitys). Tämän jälkeen asiakas ei voi perua eikä pyytää hyvitystä itse; henkilökunnan peruutukset ja hyvitykset toimivat aina.'
 where key = 'customer_change_hours_before' and description is distinct from 'Kuinka monta tuntia ennen vuoron alkua asiakas voi viimeistään itse muuttaa varaustaan (siirto toiseen vapaaseen vuoroon / henkilömäärä) tai lähettää peruutuspyynnön tilaussivulta (peruutus ja hyvitys). Tämän jälkeen asiakas ei voi perua eikä pyytää hyvitystä itse; henkilökunnan peruutukset ja hyvitykset toimivat aina.';

-- Asiakkaan peruutuksen takaraja: ensimmäisen voimassa olevan (ei peruttu / pito voimassa) ja päättymättömän vuoron alku − asetuksen tunnit.
-- null = tilauksella ei ole tulevaa voimassa olevaa vuoroa.
create or replace function booking._customer_cancel_deadline(p_order_id bigint) returns timestamptz
language sql stable security definer set search_path = '' as $$
  select min(r.starts_at) - make_interval(hours => coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48))
    from booking.reservations r
   where r.order_id = p_order_id and booking._res_active(r.status, r.hold_expires_at) and r.ends_at > now()
$$;
revoke all on function booking._customer_cancel_deadline(bigint) from public, anon, authenticated;

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
  v_can_add := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now();
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
    'created_at', o.created_at, 'first_name', v_cust, 'customer_kind', o.customer_kind,
    'total', v_bal -> 'total', 'paid', v_bal -> 'net_paid', 'refunded', v_bal -> 'refunded', 'unpaid', v_bal -> 'unpaid',
    'items', v_items, 'reservations', v_res, 'payments', v_pay, 'receipts', v_rec,
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

CREATE OR REPLACE FUNCTION booking.public_request_cancel(p_token uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; v_id bigint; v_at timestamptz; v_reason text := nullif(btrim(coalesce(p_reason, '')), ''); v_first timestamptz; v_bal jsonb;
  v_hours integer := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);   -- booking_149
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if not booking._order_rl('req', p_token, (booking._setting('rl_order_req_per_10min', '6'::jsonb) #>> '{}')::int * 2, (booking._setting('rl_order_req_per_10min', '6'::jsonb) #>> '{}')::int) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_reason is not null and char_length(v_reason) > 1000 then return booking._order_err('invalid_reason', 'Syy on liian pitkä (enintään 1000 merkkiä)'); end if;
  select * into o from booking.orders where public_token = p_token for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select min(r.starts_at) into v_first from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at) and r.ends_at > now();
  if o.external_source is not null or o.status <> 'confirmed' or v_first is null then
    return booking._order_err('order_closed', 'Tilausta ei voi enää peruuttaa verkossa – ota yhteyttä sähköpostitse');
  end if;
  if exists (select 1 from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' and q.status = 'open') then
    return booking._order_err('request_exists', 'Peruutuspyyntö on jo lähetetty ja odottaa käsittelyä');
  end if;
  -- booking_149: alle customer_change_hours_before (oletus 48) tuntia ennen vuoron alkua asiakas ei voi enää perua eikä pyytää hyvitystä itse.
  if booking._customer_cancel_deadline(o.id) < now() then
    return booking._order_err('cancel_too_late', format('Peruutus ei ole enää mahdollinen, koska vuoron alkuun on alle %s tuntia. Ota yhteyttä puhelimitse: 010 299 2866.', v_hours));
  end if;
  insert into booking.order_requests(order_id, kind, reason) values (o.id, 'cancel', v_reason) returning id, created_at into v_id, v_at;
  v_bal := booking._order_balance(o.id);
  perform booking._notify_staff('cancel_request', v_id, jsonb_build_object('request_id', v_id, 'order_id', o.id, 'order_no', o.order_no, 'first_start', v_first, 'total', o.total_gross, 'paid', v_bal -> 'net_paid', 'has_reason', v_reason is not null));
  perform booking._enqueue_email('cancel_request_ack', o.id, null, null, 'cancel_ack:' || v_id);
  return jsonb_build_object('ok', true, 'request', jsonb_build_object('id', v_id, 'status', 'open', 'created_at', v_at));
end $function$;

