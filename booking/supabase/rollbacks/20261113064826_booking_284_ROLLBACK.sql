-- booking_284 ROLLBACK: palauttaa booking_281/PROD-tilan (_change_booking_core 8 arg, public_change_booking 4 arg), pudottaa asiakkaan pienennyksen funktiot,
-- product_config.cancellation_tier -sarakkeen ja asetukset. Koko tiedosto yhtenä transaktiona (psql -1).
-- EI saa ajaa, jos on avoimia (requested/processing) customer_reduce-hyvityksiä: ne jäisivät käsittelemättä. Valmiit hyvitysrivit ja audit säilyvät datana.
-- Luokittelutiedot (cancellation_tier) menetetään: varmista ennen ajoa, ettei luokittelua ole tehty (muuten forward-fix).
set local lock_timeout = '5s';
do $pre$
declare v text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking._change_booking_core(bigint,bigint,date,integer,boolean,integer,uuid,text,boolean)')));
  if v is distinct from '5b29ef6f52316114896763d865a37205' then raise exception 'rollback 284: % md5 % ei vastaa booking_284-versiota (5b29ef6f52316114896763d865a37205). Ei muutoksia.', 'booking._change_booking_core(bigint,bigint,date,integer,boolean,integer,uuid,text,boolean)', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_change_booking(uuid,bigint,date,integer,numeric)')));
  if v is distinct from 'aab5cde293509314f17117f909a10d79' then raise exception 'rollback 284: % md5 % ei vastaa booking_284-versiota (aab5cde293509314f17117f909a10d79). Ei muutoksia.', 'booking.public_change_booking(uuid,bigint,date,integer,numeric)', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._reduce_eval(bigint,bigint,bigint,date,integer)')));
  if v is distinct from '8ed770ad0468fbecff25fd813c9d8569' then raise exception 'rollback 284: % md5 % ei vastaa booking_284-versiota (8ed770ad0468fbecff25fd813c9d8569). Ei muutoksia.', 'booking._reduce_eval(bigint,bigint,bigint,date,integer)', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._customer_refund_create(bigint,numeric,bigint)')));
  if v is distinct from '4a0f7b7e3784fa12f326550875cf571f' then raise exception 'rollback 284: % md5 % ei vastaa booking_284-versiota (4a0f7b7e3784fa12f326550875cf571f). Ei muutoksia.', 'booking._customer_refund_create(bigint,numeric,bigint)', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_change_preview(uuid,bigint,date,integer)')));
  if v is distinct from '2efbd04181c9bd0636437744ec8f6951' then raise exception 'rollback 284: % md5 % ei vastaa booking_284-versiota (2efbd04181c9bd0636437744ec8f6951). Ei muutoksia.', 'booking.public_change_preview(uuid,bigint,date,integer)', v; end if;
end $pre$;
do $pre2$ begin
  if exists (select 1 from booking.refunds where reason = 'customer_reduce' and status in ('requested', 'processing')) then
    raise exception 'rollback booking_284: avoimia customer_reduce-hyvityksiä; käsittele ne ensin. Ei muutoksia.';
  end if;
  if exists (select 1 from booking.product_config where cancellation_tier is not null) then
    raise exception 'rollback booking_284: tuotteita on luokiteltu (cancellation_tier); forward-fix tai nollaa luokittelu tarkoituksella. Ei muutoksia.';
  end if;
end $pre2$;

drop function if exists booking.public_change_preview(uuid, bigint, date, integer);
drop function if exists booking.public_change_booking(uuid, bigint, date, integer, numeric);
drop function if exists booking._customer_refund_create(bigint, numeric, bigint);
drop function if exists booking._reduce_eval(bigint, bigint, bigint, date, integer);
drop function if exists booking._change_booking_core(bigint, bigint, date, integer, boolean, integer, uuid, text, boolean);
CREATE OR REPLACE FUNCTION booking._change_booking_core(p_reservation_id bigint, p_rule_id bigint, p_date date, p_persons integer, p_enforce_deadline boolean, p_notice_hours integer, p_actor uuid, p_via text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  res booking.reservations; o booking.orders; rs record; pr record; v_keep boolean := (p_rule_id is null and p_date is null);
  v_persons integer; v_rule bigint; v_total numeric; v_paid numeric; v_old booking.reservations; v_addons numeric; v_order_total numeric;
  v_locked boolean;
begin
  if p_enforce_deadline or p_notice_hours is not null or not coalesce(booking.has_permission('bookings.manage'), false) then
    perform booking._clear_staff_overrides();
  end if;
  if (p_rule_id is null) <> (p_date is null) then perform booking._err('invalid_change', 'Anna sekä uusi vuoro että päivä, tai kumpikaan'); end if;
  select * into res from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  select * into o from booking.orders where id = res.order_id;
  v_locked := booking._order_invoice_locked(o.id);
  if res.status <> 'confirmed' or o.status <> 'confirmed' then
    perform booking._err('not_changeable', 'Vain vahvistettua varausta voi muuttaa');
  end if;
  if v_locked and p_notice_hours is not null and coalesce(p_persons, res.persons) <> res.persons then
    perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
  end if;
  if p_notice_hours is not null and res.starts_at - make_interval(hours => p_notice_hours) < now() then
    perform booking._err('change_too_late', format('Varausta voi muuttaa itse viimeistään %s tuntia ennen vuoron alkua – ota yhteyttä sähköpostitse', p_notice_hours));
  end if;
  v_old := res;
  v_persons := coalesce(p_persons, res.persons);
  v_rule := coalesce(p_rule_id, res.rule_id);

  if v_keep then
    select * into rs from booking._resolve_session(v_rule, null, v_persons, false, res.starts_at, res.ends_at, true);
  else
    select * into rs from booking._resolve_session(v_rule, p_date, v_persons, p_enforce_deadline);
  end if;
  if rs.o_product_id is distinct from res.product_id then
    perform booking._err('product_mismatch', 'Varauksen voi siirtää vain saman tuotteen toiseen vuoroon');
  end if;
  if p_notice_hours is not null and rs.o_starts_at - make_interval(hours => p_notice_hours) < now() then
    perform booking._err('change_too_late', format('Uuden vuoron pitää alkaa vähintään %s tuntia päästä', p_notice_hours));
  end if;

  if not v_locked then
    select * into pr from booking._rule_price(v_rule, v_persons);
    v_total := case when res.annual_card_id is not null then 0 else pr.total end;
    v_addons := booking._addon_total_after(res.order_item_id, v_persons);
    select coalesce(sum(amount) filter (where status in ('paid','partially_refunded','refunded')), 0) into v_paid from booking.payments where order_id = o.id;
    if p_notice_hours is not null and v_paid > 0 and (v_total + v_addons) is distinct from o.total_gross then
      perform booking._err('price_change_requires_staff', 'Maksettu varaus, jonka hinta muuttuisi: ota yhteyttä henkilökuntaan');
    end if;
  end if;

  update booking.reservations set rule_id = v_rule, space_id = rs.o_space_id, mode = rs.o_mode, starts_at = rs.o_starts_at,
         ends_at = rs.o_ends_at, persons = v_persons, pool_ids = rs.o_pool_ids
   where id = res.id returning * into res;

  if not v_locked then
    update booking.order_items set unit_price_gross = v_total, line_total_gross = v_total,
           price_breakdown = pr.breakdown || jsonb_build_object('rule_id', v_rule, 'rule_label', (select label from booking.schedule_rules where id = v_rule))
     where id = res.order_item_id;
    perform booking._clamp_addons(res.order_item_id, v_persons);
    update booking.orders set total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = o.id), 0) where id = o.id
      returning total_gross into v_order_total;
    update booking.payments set amount = v_order_total where order_id = o.id and status = 'pending' and provider = 'manual';
    perform booking._refresh_order_payment(o.id);
  else
    v_order_total := o.total_gross;
  end if;

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (p_actor, booking._jwt_role(), 'reservations', res.id::text, p_via, to_jsonb(v_old),
          case when v_locked then to_jsonb(res) || jsonb_build_object('invoice_locked', true) else to_jsonb(res) end);

  return jsonb_build_object('reservation_id', res.id, 'order_id', o.id, 'order_no', o.order_no, 'starts_at', res.starts_at, 'ends_at', res.ends_at,
                            'persons', res.persons, 'total', v_order_total, 'rule_id', v_rule, 'product_id', res.product_id,
                            'overbooked', res.overbooked, 'off_schedule', res.off_schedule)
         || case when v_locked then jsonb_build_object('invoice_locked', true) else '{}'::jsonb end;
end $function$;
CREATE OR REPLACE FUNCTION booking.public_change_booking(p_token uuid, p_rule_id bigint DEFAULT NULL::bigint, p_date date DEFAULT NULL::date, p_persons integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_ip text := booking._client_ip(); o booking.orders; v_res_id bigint; v_n int; v_out jsonb; v_detail text; v_msg text;
  v_hours integer := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if not booking._rate_limit('chg:' || p_token::text, (booking._setting('rl_change_per_10min', '10'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if (p_rule_id is null) <> (p_date is null) or (p_rule_id is null and p_persons is null) then
    return jsonb_build_object('ok', false, 'code', 'invalid_change', 'message', 'Valitse uusi vuoro ja/tai henkilömäärä');
  end if;
  if p_persons is not null and (p_persons < 1 or p_persons > 50) then
    return jsonb_build_object('ok', false, 'code', 'invalid_persons', 'message', 'Tarkista henkilömäärä');
  end if;
  if p_date is not null and (p_date < (now() at time zone booking._tz())::date
     or p_date > (now() at time zone booking._tz())::date + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int) then
    return jsonb_build_object('ok', false, 'code', 'invalid_date', 'message', 'Päivä ei ole varattavissa');
  end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select count(*), min(r.id) into v_n, v_res_id from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  if v_n <> 1 or o.status <> 'confirmed' then
    return jsonb_build_object('ok', false, 'code', 'not_changeable', 'message', 'Tätä varausta ei voi muuttaa verkossa – ota yhteyttä sähköpostitse');
  end if;
  if exists (select 1 from booking.reservations r where r.id = v_res_id and r.rule_id is null) then   -- booking_25: aikaväli-/legipohjainen varaus -> oma muutosfunktio tai ei muutettavissa
    return jsonb_build_object('ok', false, 'code', case when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.id = v_res_id) then 'use_treatment_change' else 'not_changeable' end,
      'message', 'Tätä varausta ei voi muuttaa tällä toiminnolla – ota yhteyttä sähköpostitse',
      'change_via', case when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.id = v_res_id) then 'public_change_treatment_booking' end);
  end if;

  begin  -- alitransaktio: virhe kumoaa muutoksen kokonaan (vanha varaus säilyy) mutta rate limit -kirjaus säilyy
    v_out := booking._change_booking_core(v_res_id, p_rule_id, p_date, p_persons, true, v_hours, null, 'CUSTOMER_CHANGE');
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  return jsonb_build_object('ok', true, 'order_no', v_out -> 'order_no', 'starts_at', v_out -> 'starts_at', 'ends_at', v_out -> 'ends_at',
                            'persons', v_out -> 'persons', 'total', v_out -> 'total');
end $function$;

revoke all on function booking._change_booking_core(bigint, bigint, date, integer, boolean, integer, uuid, text) from public, anon, authenticated;
revoke all on function booking.public_change_booking(uuid, bigint, date, integer) from public;
grant execute on function booking.public_change_booking(uuid, bigint, date, integer) to anon, authenticated, service_role;

alter table booking.product_config drop constraint if exists product_config_cancellation_tier_check;
alter table booking.product_config drop column if exists cancellation_tier;
delete from booking.settings where key in ('customer_auto_partial_refund_enabled', 'customer_reduce_full_refund_days_private', 'customer_reduce_cooldown_minutes');

notify pgrst, 'reload schema';
