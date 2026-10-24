-- booking_166 ROLLBACK (migraatio 20261024380000_booking_166_ritual_addon.sql).
-- Palauttaa korvatut funktiot tuotannon määrittelyiksi täsmälleen (md5 alla), poistaa triggerin, uudet funktiot ja asetuksen.
-- Jo tehdyt rituaalivaraukset jäävät tavallisiksi kb 8 -varauksiksi (parent_reservation_id säilyy, tilausrivin price_breakdown.ritual_addon säilyy);
-- niitä ei peruta eikä poisteta. Vartija: funktioiden md5 on oltava booking_166:n tai tuotannon; muuten mitään ei muuteta.
set local lock_timeout = '5s';


do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef('booking._attach_addons(bigint,jsonb)'::regprocedure));
  if v not in ('6a780e8e00229ff273a321591f197541', '319cac689b7c883bbba857af6b254a3f') then ok := false; msg := msg || ' _attach_addons=' || v; end if;
  v := md5(pg_get_functiondef('booking._reservation_refund_plan(bigint)'::regprocedure));
  if v not in ('cb44c682ac0095617fe20b297b0cdac3', 'a22952905fc68f119427f7fd4e6025fa') then ok := false; msg := msg || ' _reservation_refund_plan=' || v; end if;
  v := md5(pg_get_functiondef('booking.public_get_booking(uuid)'::regprocedure));
  if v not in ('a155cd472c356c09e595cbda46b4dada', '778f1024006308d0dcd879ef9428ed00') then ok := false; msg := msg || ' public_get_booking=' || v; end if;
  v := md5(pg_get_functiondef('booking.public_preview_code(text,bigint,date,integer,jsonb,text,text)'::regprocedure));
  if v not in ('fec859d04960f42d79412bbdf7dc6561', '4816fbaf5149e501a128aed40f2bf505') then ok := false; msg := msg || ' public_preview_code=' || v; end if;
  v := md5(pg_get_functiondef('booking.reservations_time_window()'::regprocedure));
  if v not in ('023b689b0366602ab32738b7821dcc16', '4bff7a9af49ade40e5a953eaeea03547') then ok := false; msg := msg || ' reservations_time_window=' || v; end if;
  if not ok then raise exception 'booking_166 rollback: funktioiden md5 ei ole booking_166:n eikä tuotannon (%); mitään ei muutettu', msg; end if;
end $g$;

drop trigger if exists reservations_ritual_addon_parent on booking.reservations;

-- booking._attach_addons(bigint,jsonb) (tuotanto, md5 6a780e8e00229ff273a321591f197541)
CREATE OR REPLACE FUNCTION booking._attach_addons(p_reservation_id bigint, p_addons jsonb)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r booking.reservations; a booking.addons; e jsonb; v_acc jsonb := '{}'::jsonb; v_key text; v_qty integer; v_total numeric := 0;
  v_idtxt text; v_code text; v_lim integer; v_mode text;
begin
  if p_addons is null or p_addons = 'null'::jsonb then return 0; end if;
  if jsonb_typeof(p_addons) <> 'array' then perform booking._err('invalid_addons', 'Lisäpalvelut väärässä muodossa'); end if;
  if jsonb_array_length(p_addons) = 0 then return 0; end if;
  if jsonb_array_length(p_addons) > 20 then perform booking._err('invalid_addons', 'Liian monta lisäpalvelua'); end if;
  select * into r from booking.reservations where id = p_reservation_id;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;

  -- tehokas tila: yleinen vuoro / yksityisvuoro = r.mode (shared / exclusive); resurssivaraus (hoito, saunotus, rituaali; sale_kind 'other') = 'resource';
  -- tapahtuma (kb.products.category = 'event') = 'event' (ei lisäpalveluita)
  select case when pc.sale_kind = 'other' and pc.resource_class = 'resourced' then case when p.category = 'event' then 'event' else 'resource' end else r.mode end
    into v_mode from booking.product_config pc join kb.products p on p.id = pc.product_id where pc.product_id = r.product_id;
  v_mode := coalesce(v_mode, r.mode);

  for e in select * from jsonb_array_elements(p_addons) loop
    if jsonb_typeof(e) <> 'object' then perform booking._err('invalid_addons', 'Lisäpalvelut väärässä muodossa'); end if;
    v_idtxt := e ->> 'id'; v_code := e ->> 'code';
    if coalesce(e ->> 'quantity', '') !~ '^\d{1,4}$' then perform booking._err('addon_quantity', 'Lisäpalvelun määrän pitää olla kokonaisluku'); end if;
    v_qty := (e ->> 'quantity')::int;
    if v_idtxt is not null and v_idtxt !~ '^\d{1,18}$' then perform booking._err('addon_not_found', 'Lisäpalvelua ei löydy'); end if;
    select * into a from booking.addons where (v_idtxt is not null and id = v_idtxt::bigint) or (v_idtxt is null and v_code is not null and code = v_code);
    if not found then perform booking._err('addon_not_found', 'Lisäpalvelua ei löydy'); end if;
    v_acc := jsonb_set(v_acc, array[a.id::text], to_jsonb(coalesce((v_acc ->> a.id::text)::int, 0) + v_qty));
  end loop;

  for v_key, v_qty in select k, (v_acc ->> k)::int from jsonb_object_keys(v_acc) k order by k::bigint loop
    continue when v_qty = 0;
    select * into a from booking.addons where id = v_key::bigint;
    if not a.active then perform booking._err('addon_inactive', format('Lisäpalvelu "%s" ei ole käytössä', a.name)); end if;
    if not (v_mode = any (a.applies_modes)) then perform booking._err('addon_not_allowed', format('Lisäpalvelu "%s" ei ole saatavilla tälle vuorolle', a.name)); end if;
    v_lim := booking._addon_limit(a.max_per_person, r.persons);
    if v_qty > v_lim then perform booking._err('addon_quantity', format('Lisäpalvelua "%s" voi valita enintään %s kpl', a.name, v_lim)); end if;
    insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, addon_id, parent_item_id, price_breakdown)
    values (r.order_id, a.name, 'addon', v_qty, a.price_gross, a.price_gross * v_qty, a.vat_rate, a.id, r.order_item_id,
            jsonb_build_object('addon_code', a.code, 'name_en', a.name_en, 'unit_price', a.price_gross, 'quantity', v_qty, 'max_per_person', a.max_per_person));
    v_total := v_total + a.price_gross * v_qty;
  end loop;
  if v_total > 0 then update booking.orders set total_gross = total_gross + v_total where id = r.order_id; end if;
  return v_total;
end $function$;

-- booking._reservation_refund_plan(bigint) (tuotanto, md5 cb44c682ac0095617fe20b297b0cdac3)
CREATE OR REPLACE FUNCTION booking._reservation_refund_plan(p_reservation_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r booking.reservations; o booking.orders; p record; l record;
  v_items bigint[]; v_pending numeric; v_cap numeric; v_net numeric; v_amt numeric; v_left numeric; v_use numeric;
  v_lines jsonb; v_out jsonb := '[]'::jsonb; v_total numeric := 0; v_unalloc int := 0;
begin
  select * into r from booking.reservations where id = p_reservation_id;
  if not found then return null; end if;
  select * into o from booking.orders where id = r.order_id;
  if r.order_item_id is null or o.external_source is not null then
    return jsonb_build_object('reservation_id', r.id, 'order_id', r.order_id, 'status', r.status, 'total', 0, 'unallocated', 0, 'payments', '[]'::jsonb);
  end if;
  select array_agg(i.id order by i.id) into v_items from booking.order_items i
   where i.order_id = r.order_id and (i.id = r.order_item_id or i.parent_item_id = r.order_item_id);
  for p in select * from booking.payments x where x.order_id = r.order_id and x.status in ('paid','partially_refunded')
             and x.external_source is null order by x.id loop
    if not exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id) then v_unalloc := v_unalloc + 1; continue; end if;
    v_pending := coalesce((select sum(f.amount) from booking.refunds f where f.payment_id = p.id and f.status in ('requested','processing')), 0);
    v_cap := p.amount - p.refunded_amount - v_pending;
    select coalesce(sum(c.cap), 0) into v_net from (
      select pl.amount_gross - pl.refunded_gross - coalesce((select sum((x ->> 'amount')::numeric) from booking.refunds f, jsonb_array_elements(coalesce(f.lines, '[]'::jsonb)) x
              where f.payment_id = p.id and f.status in ('requested','processing') and (x ->> 'payment_line_id')::bigint = pl.id), 0) as cap
        from booking.payment_lines pl where pl.payment_id = p.id and pl.order_item_id = any(v_items)) c;
    v_amt := round(least(v_net, v_cap), 2);
    if v_amt <= 0 then continue; end if;
    v_left := v_amt; v_lines := '[]'::jsonb;
    for l in select pl.id, pl.amount_gross - pl.refunded_gross - coalesce((select sum((x ->> 'amount')::numeric) from booking.refunds f, jsonb_array_elements(coalesce(f.lines, '[]'::jsonb)) x
                     where f.payment_id = p.id and f.status in ('requested','processing') and (x ->> 'payment_line_id')::bigint = pl.id), 0) as cap
               from booking.payment_lines pl where pl.payment_id = p.id and pl.order_item_id = any(v_items) order by pl.id loop
      exit when v_left <= 0.004;
      continue when l.cap <= 0;
      v_use := least(l.cap, v_left);
      v_lines := v_lines || jsonb_build_object('payment_line_id', l.id, 'amount', v_use);
      v_left := v_left - v_use;
    end loop;
    if v_left > 0.004 then v_amt := v_amt - v_left; end if;
    if v_amt <= 0 then continue; end if;
    v_out := v_out || jsonb_build_object('payment_id', p.id, 'provider', p.provider, 'method', p.method, 'gift_card', p.gift_card_id is not null,
      'online_off', p.provider <> 'manual' and coalesce((select c.mode from booking.integration_config c where c.key = replace(p.provider, '_', '')), 'off') = 'off',
      'amount', v_amt, 'lines', v_lines);
    v_total := v_total + v_amt;
  end loop;
  return jsonb_build_object('reservation_id', r.id, 'order_id', r.order_id, 'status', r.status, 'total', v_total, 'unallocated', v_unalloc, 'payments', v_out);
end $function$;

-- booking.public_get_booking(uuid) (tuotanto, md5 a155cd472c356c09e595cbda46b4dada)
CREATE OR REPLACE FUNCTION booking.public_get_booking(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders; res jsonb; adds jsonb; cust text;
  v_hours integer := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  v_conf_n integer; v_conf_start timestamptz; v_kind text; v_supported boolean;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select split_part(c.name, ' ', 1) into cust from booking.customers c where c.id = o.customer_id;
  select jsonb_agg(jsonb_build_object(
           'product_name', it.product_name, 'quantity', it.quantity, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate,
           'product_id', r.product_id, 'rule_id', r.rule_id,
           'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'mode', r.mode, 'option', booking._option_json(r.product_option_id),
           'option_label', booking._option_label(r.product_id, o.locale), 'option_label_fi', booking._option_label(r.product_id, 'fi'), 'option_label_en', booking._option_label(r.product_id, 'en'),
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() and not booking._order_mp_inflight(r.order_id) then 'expired' else r.status end,
           'hold_expires_at', r.hold_expires_at) order by r.starts_at)
    into res
    from booking.order_items it left join booking.reservations r on r.order_item_id = it.id
   where it.order_id = o.id and it.kind = 'reservation';
  select jsonb_agg(jsonb_build_object('addon_id', it.addon_id, 'name', it.product_name, 'name_en', it.price_breakdown ->> 'name_en',
           'quantity', it.quantity, 'unit_price', it.unit_price_gross, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate,
           'max_per_person', ad.max_per_person) order by it.id)
    into adds from booking.order_items it left join booking.addons ad on ad.id = it.addon_id where it.order_id = o.id and it.kind = 'addon';
  select count(*), min(r.starts_at) into v_conf_n, v_conf_start from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  -- booking_25: varaustyyppi. 'rules' = sääntöpohjainen (muutettavissa public_change_booking), 'slots' = verkossa tehty hoitovaraus (public_change_treatment_booking), 'other' = ei muutettavissa verkossa (tuonti/ylläpito)
  v_kind := case when exists (select 1 from booking.reservations r where r.order_id = o.id and r.rule_id is not null) then 'rules'
                 when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.order_id = o.id and r.rule_id is null) then 'slots'
                 else 'other' end;
  v_supported := v_kind in ('rules', 'slots');
  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'status',
           case when o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) and not booking._order_mp_inflight(o.id) then 'expired' else o.status end,
           'payment_status', o.payment_status, 'total', o.total_gross, 'currency', o.currency, 'created_at', o.created_at,
           'first_name', cust, 'customer_kind', o.customer_kind, 'items', coalesce(res, '[]'::jsonb), 'addons', coalesce(adds, '[]'::jsonb),
           'payment_methods', (select coalesce(jsonb_agg(p.method), '[]'::jsonb) from booking.payments p where p.order_id = o.id),
           'can_change', (o.status = 'confirmed' and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now() and v_supported),
           'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end,
           'change_hours_before', v_hours,
           'booking_kind', v_kind, 'change_via', case v_kind when 'slots' then 'public_change_treatment_booking' when 'rules' then 'public_change_booking' end)
         || booking._checkout_state_json(o.id);
end $function$;

-- booking.public_preview_code(text,bigint,date,integer,jsonb,text,text) (tuotanto, md5 fec859d04960f42d79412bbdf7dc6561)
CREATE OR REPLACE FUNCTION booking.public_preview_code(p_code text, p_rule_id bigint, p_date date, p_persons integer, p_addons jsonb DEFAULT NULL::jsonb, p_email text DEFAULT NULL::text, p_phone text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_code text := booking._norm_code(p_code); v_ip text := booking._client_ip(); v_card booking.annual_cards; d booking.discount_codes;
  r booking.schedule_rules; pr record; v_lines jsonb := '[]'::jsonb; v_sub numeric; v_err text; v_calc jsonb; e jsonb; a booking.addons; v_q int;
  v_quiet jsonb; v_qamt numeric := 0;  -- booking_162
begin
  if v_code = '' or char_length(v_code) > 40 then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  select * into r from booking.schedule_rules where id = p_rule_id and active;
  if r.id is null or p_persons is null or p_persons < 1 or p_persons > 50 then
    return jsonb_build_object('ok', false, 'code', 'invalid_session', 'message', 'Valitse vuoro ja henkilömäärä');
  end if;
  select * into pr from booking._rule_price(p_rule_id, p_persons);
  v_lines := jsonb_build_array(jsonb_build_object('key', 0, 'product_id', r.product_id, 'kind', 'reservation', 'gross', pr.total));
  v_sub := pr.total;
  if p_addons is not null and jsonb_typeof(p_addons) = 'array' then
    for e in select x from jsonb_array_elements(p_addons) x limit 20 loop
      continue when jsonb_typeof(e) <> 'object' or coalesce(e ->> 'quantity', '') !~ '^\d{1,4}$' or coalesce(e ->> 'id', '') !~ '^\d{1,18}$';
      v_q := (e ->> 'quantity')::int; continue when v_q = 0;
      select * into a from booking.addons where id = (e ->> 'id')::bigint and active;
      continue when a.id is null;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('key', a.id, 'product_id', null, 'kind', 'addon', 'gross', a.price_gross * v_q));
      v_sub := v_sub + a.price_gross * v_q;
    end loop;
  end if;

  select * into v_card from booking.annual_cards where code = v_code;
  if v_card.id is null then select * into d from booking.discount_codes where code = v_code; end if;
  if v_card.id is null and d.id is null then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  -- booking_143: henkilökohtainen kortti + yhteystiedot, jotka eivät ole omistajan → sama vastaus kuin tuntemattomalla koodilla
  if v_card.id is not null and (nullif(btrim(coalesce(p_email, '')), '') is not null or booking._phone_key(p_phone) is not null)
     and not booking._annual_card_owner_ok(v_card, p_email, p_phone) then
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code'));
  end if;

  if v_card.id is not null or d.is_annual_card_code then
    v_err := booking._annual_rule_check(p_rule_id, p_date, v_card, d);
    if v_err is null and (nullif(btrim(coalesce(p_email, '')), '') is not null or booking._phone_key(p_phone) is not null)
       and booking._annual_limit(v_card.customer_id, p_email, p_phone) then v_err := 'annual_card_limit'; end if;
    if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
    select * into pr from booking._rule_price(p_rule_id, booking._annual_max_persons());
    return jsonb_build_object('ok', true, 'type', case when v_card.id is not null then 'annual_card' else 'annual_code' end, 'code', v_code,
      'persons', booking._annual_max_persons(), 'addons_allowed', false, 'subtotal', pr.total, 'discount', pr.total, 'total', 0,
      'valid_to', coalesce(v_card.valid_to, d.valid_to));
  end if;

  v_err := booking._discount_state(d);
  if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
  v_calc := booking._discount_split(d, v_lines);
  if (v_calc ->> 'discount')::numeric <= 0 then
    return jsonb_build_object('ok', false, 'code', 'code_not_applicable', 'message', booking._code_msg('code_not_applicable'));
  end if;
  -- booking_162: hiljaisen ajan ale ei pinoudu koodin kanssa; koodi voittaa vain jos se on suurempi etu
  v_quiet := booking._quiet_for_rule(p_rule_id, p_date);
  if v_quiet is not null then v_qamt := least(pr.total, round(pr.total * (v_quiet ->> 'percent')::numeric / 100, 2)); end if;
  if v_qamt > 0 and v_qamt >= (v_calc ->> 'discount')::numeric then
    return jsonb_build_object('ok', true, 'type', 'discount', 'code', v_code, 'kind', d.kind, 'value', d.value, 'subtotal', v_sub,
      'discount', v_qamt, 'total', v_sub - v_qamt, 'addons_allowed', true, 'discount_source', 'quiet', 'code_applied', false,
      'code_discount', (v_calc ->> 'discount')::numeric, 'quiet', jsonb_build_object('percent', (v_quiet ->> 'percent')::numeric, 'amount', v_qamt));
  end if;
  return jsonb_build_object('ok', true, 'type', 'discount', 'code', v_code, 'kind', d.kind, 'value', d.value, 'subtotal', v_sub,
    'discount', (v_calc ->> 'discount')::numeric, 'total', v_sub - (v_calc ->> 'discount')::numeric, 'addons_allowed', true)
    || case when v_qamt > 0 then jsonb_build_object('discount_source', 'code', 'code_applied', true,
         'quiet', jsonb_build_object('percent', (v_quiet ->> 'percent')::numeric, 'amount', v_qamt)) else '{}'::jsonb end;
end $function$;

-- booking.reservations_time_window() (tuotanto, md5 023b689b0366602ab32738b7821dcc16)
CREATE OR REPLACE FUNCTION booking.reservations_time_window()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_class text; w booking.time_window_rules; ls timestamp; le timestamp; v_dt text;
begin
  if new.status not in ('pending', 'confirmed') then return new; end if;
  if new.override_reason is not null then return new; end if;
  if new.external_source is not null and coalesce(booking._jwt_role(), 'service_role') = 'service_role' then return new; end if;
  if tg_op = 'UPDATE' and old.product_id is not distinct from new.product_id and old.starts_at = new.starts_at and old.ends_at = new.ends_at
     and booking._res_active(old.status, old.hold_expires_at) then return new; end if;
  select pc.time_window_class into v_class from booking.product_config pc where pc.product_id = new.product_id;
  if v_class is null then return new; end if;
  ls := new.starts_at at time zone booking._tz();
  le := new.ends_at at time zone booking._tz();
  v_dt := case when extract(isodow from ls) >= 6 then 'weekend' else 'weekday' end;
  select * into w from booking.time_window_rules where class = v_class and day_type = v_dt;
  if not found then return new; end if;
  if w.allowed_starts is not null and not (date_trunc('minute', ls)::time = any (w.allowed_starts)) then
    perform booking._err('ritual_start', 'Rituaalin alkuaika voi olla vain ' || (select string_agg(to_char(t, 'HH24:MI'), ', ' order by t) from unnest(w.allowed_starts) t));
  end if;
  if w.earliest_start is not null and ls::time < w.earliest_start
     or w.latest_end is not null and (le::time > w.latest_end or le::date <> ls::date) then
    perform booking._err('time_window', 'Hoitojen ja saunotusten aika: ' || case v_dt when 'weekday' then 'ma–pe' else 'la–su' end || ' alkaa aikaisintaan '
                         || to_char(w.earliest_start, 'HH24:MI') || ' ja päättyy viimeistään ' || to_char(w.latest_end, 'HH24:MI'));
  end if;
  return new;
end $function$;

drop function if exists booking.public_ritual_addon(bigint, date, integer);
drop function if exists booking._ritual_addon_parent_trg();
drop function if exists booking._ritual_addon_move(bigint, timestamptz);
drop function if exists booking._ritual_addon_attach(bigint, jsonb);
drop function if exists booking._ritual_addon_start_ok(bigint, bigint, timestamptz);
drop function if exists booking._ritual_addon_fit(timestamptz, integer, boolean);
drop function if exists booking._ritual_addon_session_ok(bigint);
drop function if exists booking._is_ritual_addon_item(bigint);
drop function if exists booking._ritual_addon_starts(timestamptz, timestamptz);
drop function if exists booking._ritual_addon_cfg();
delete from booking.settings where key = 'ritual_addon';
