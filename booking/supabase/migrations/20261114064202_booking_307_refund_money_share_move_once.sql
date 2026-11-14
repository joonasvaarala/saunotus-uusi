-- booking_307: hyvitys lahjakortti-/kumppaniosuuden tilauksessa + yleisen vuoron siirto vain kerran (Joonas 14.11.2026 klo 8.23 "Kyllä, Koodari korjatkoon molemmat").
--
-- 2) _refund_allocate (booking_282): jos tilaus on maksettu osin lahjakortilla tai kumppanikoodilla ja pyydetty hyvitys ylittää rahaosuuden,
--    summa leikataan rahana maksettuun hyvitettävään osuuteen (Joonas 13.11.: rahana palautetaan vain rahana maksettu osuus) eikä kaadu virheeseen
--    amount_exceeds_refundable. Lahjakorttiosuutta EI palauteta lahjakortille (siitä ei ole päätöstä). Rahaosuus 0 → hyvitys 0 €, muutos tehdään.
--    admin_change_booking palauttaa lisäksi refund_requested, refund_capped, refund_skipped ('no_money_share') ja non_refundable_amount.
--    Ennallaan: tilaus ilman lahjakortti-/kumppaniosuutta (liian suuri summa → virhe), koko tilauksen peruutus (p_cancel_mode), asiakkaan oma pienennys
--    (vaatii yhä pelkän Montonio-maksun, _reduce_eval payment_method).
-- 4) Siirto vain kerran (ehdot: yleisen vuoron siirto vain kerran): _change_booking_core estää asiakkaan toisen siirron (already_moved) tuotteille, joiden
--    cancellation_tier = 'general'; public_change_booking palauttaa saman koodin jo ennen ydintä. Henkilökunta (admin_change_booking) saa ohittaa.
--    Uusi sisäinen apufunktio _customer_move_blocked(bigint).
-- Ei lippumuutoksia, ei hinta-/ALV-muutoksia, ei public-skeemaa.
-- Rollback: rollbacks/20261114063015_booking_307_ROLLBACK.sql
set local lock_timeout = '5s';

do $pre$
declare v text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking._refund_allocate(bigint,numeric,bigint,bigint[],numeric,boolean)')));
  if v is distinct from 'd6d5da3dc9c44e195a473b01e0825b69' then raise exception 'booking_307: booking._refund_allocate md5 % ei vastaa odotettua. Ei muutoksia.', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_change_booking(bigint,bigint,date,integer,boolean,boolean,timestamptz,timestamptz,numeric,text,boolean)')));
  if v is distinct from '80cd08f2a84d016bc66a6a8593960a41' then raise exception 'booking_307: booking.admin_change_booking md5 % ei vastaa odotettua. Ei muutoksia.', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._change_booking_core(bigint,bigint,date,integer,boolean,integer,uuid,text,boolean)')));
  if v is distinct from '5b29ef6f52316114896763d865a37205' then raise exception 'booking_307: booking._change_booking_core md5 % ei vastaa odotettua. Ei muutoksia.', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_change_booking(uuid,bigint,date,integer,numeric)')));
  if v is distinct from 'aab5cde293509314f17117f909a10d79' then raise exception 'booking_307: booking.public_change_booking md5 % ei vastaa odotettua. Ei muutoksia.', v; end if;
  if to_regprocedure('booking._customer_move_blocked(bigint)') is not null then raise exception 'booking_307: _customer_move_blocked on jo olemassa. Ei muutoksia.'; end if;
end $pre$;

-- Onko asiakas jo siirtänyt tämän varauksen kerran itse ja koskeeko sääntö tuotetta (peruutusehtoryhmä 'general' = yleiset vuorot).
-- Siirto = CUSTOMER_CHANGE-auditrivi, jossa alkuaika muuttui. Henkilökunnan siirrot (ADMIN_CHANGE) eivät kuluta asiakkaan siirtoa.
create or replace function booking._customer_move_blocked(p_reservation_id bigint)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id
                  where r.id = p_reservation_id and pc.cancellation_tier = 'general')
     and exists (select 1 from booking.audit_log a
                  where a.table_name = 'reservations' and a.row_pk = p_reservation_id::text and a.action = 'CUSTOMER_CHANGE'
                    and (a.old_data ->> 'starts_at')::timestamptz is distinct from (a.new_data ->> 'starts_at')::timestamptz)
$$;
revoke all on function booking._customer_move_blocked(bigint) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION booking._refund_allocate(p_order_id bigint, p_amount numeric, p_payment_id bigint DEFAULT NULL::bigint, p_prefer_items bigint[] DEFAULT NULL::bigint[], p_total_override numeric DEFAULT NULL::numeric, p_cancel_mode boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_info jsonb; v_left numeric; pay jsonb; l record; it record; v_take numeric; v_rem numeric; v_c numeric; v_lines jsonb; v_out jsonb := '[]'::jsonb;
        v_ex jsonb := '{}'::jsonb; v_used jsonb := '{}'::jsonb; v_pass int; v_max numeric; v_pid bigint; v_exc numeric; v_online boolean;
        v_gp_share boolean;
begin
  if p_amount is null or p_amount < 0.05 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Hyvityksen vähimmäissumma on 0,05 € (kaksi desimaalia)'); end if;
  v_info := booking._order_refund_info(p_order_id, p_total_override);
  if v_info is null then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  v_max := case when p_cancel_mode then (v_info ->> 'eligible_cap')::numeric else (v_info ->> 'refundable_max')::numeric end;
  if p_amount > v_max + 0.004 then
    -- booking_307 (Joonas 13.11.2026): jos tilaus on maksettu osin lahjakortilla/kumppanikoodilla, rahaa hyvitetään enintään rahana maksettu osuus.
    -- Pyydetty summa leikataan rahaosuuteen (v_max) virheen sijaan; lahjakorttiosuutta ei palauteta (ei päätöstä). Rahaosuus < 0,05 € → tyhjä jako (0 €).
    -- Ilman lahjakortti-/kumppaniosuutta ja koko tilauksen peruutuksessa (p_cancel_mode) virhe säilyy ennallaan.
    v_gp_share := exists (select 1 from jsonb_array_elements(coalesce(v_info -> 'payments', '[]'::jsonb)) e where e ->> 'kind' in ('gift_card', 'partner_voucher'));
    if p_cancel_mode or not v_gp_share then perform booking._err('amount_exceeds_refundable', format('Hyvitettävissä enintään %s €', v_max)); end if;
    p_amount := round(greatest(v_max, 0), 2);
    if p_amount < 0.05 then return '[]'::jsonb; end if;
  end if;
  -- ylisuoritus per tilausrivi = katettu − rivin summa
  for it in select i.id, i.line_total_gross, coalesce((select sum(booking._pl_cap(pl.id)) from booking.payment_lines pl join booking.payments p on p.id = pl.payment_id
                    where pl.order_item_id = i.id and p.status in ('paid','partially_refunded')), 0) as covered
              from booking.order_items i where i.order_id = p_order_id loop
    v_exc := it.covered - it.line_total_gross;
    if v_exc > 0.004 then v_ex := v_ex || jsonb_build_object(it.id::text, v_exc); end if;
  end loop;
  v_left := p_amount;
  for pay in select e from jsonb_array_elements(v_info -> 'payments') e
              where e ->> 'kind' = 'refundable' and (p_payment_id is null or (e ->> 'payment_id')::bigint = p_payment_id)
              order by (e ->> 'online')::boolean desc, (e ->> 'payment_id')::bigint loop
    exit when v_left <= 0.004;
    v_pid := (pay ->> 'payment_id')::bigint; v_online := (pay ->> 'online')::boolean;
    v_take := least(v_left, (pay ->> 'cap')::numeric);
    if v_online and v_take < 0.05 then continue; end if;
    v_rem := v_take; v_lines := '[]'::jsonb;
    for v_pass in 1..3 loop
      for l in select pl.id, pl.order_item_id, booking._pl_cap(pl.id) as cap from booking.payment_lines pl where pl.payment_id = v_pid order by pl.id loop
        exit when v_rem <= 0.004;
        v_c := l.cap - coalesce((v_used ->> l.id::text)::numeric, 0);
        if v_c <= 0.004 then continue; end if;
        if v_pass = 1 then
          if p_cancel_mode then continue; end if;
          v_c := least(v_c, coalesce((v_ex ->> l.order_item_id::text)::numeric, 0));
        elsif v_pass = 2 then
          if p_prefer_items is null or not (l.order_item_id = any (p_prefer_items)) then continue; end if;
        end if;
        v_c := least(v_c, v_rem);
        if v_c <= 0.004 then continue; end if;
        v_lines := v_lines || jsonb_build_object('payment_line_id', l.id, 'amount', round(v_c, 2));
        v_used := v_used || jsonb_build_object(l.id::text, coalesce((v_used ->> l.id::text)::numeric, 0) + round(v_c, 2));
        if v_pass = 1 then v_ex := v_ex || jsonb_build_object(l.order_item_id::text, coalesce((v_ex ->> l.order_item_id::text)::numeric, 0) - round(v_c, 2)); end if;
        v_rem := v_rem - round(v_c, 2);
      end loop;
    end loop;
    v_take := round(v_take - greatest(v_rem, 0), 2);
    if v_take <= 0.004 or (v_online and v_take < 0.05) then continue; end if;
    v_out := v_out || jsonb_build_object('payment_id', v_pid, 'provider', pay ->> 'provider', 'method', pay ->> 'method', 'amount', v_take, 'lines', v_lines);
    v_left := v_left - v_take;
  end loop;
  if v_left > 0.004 then perform booking._err('amount_exceeds_refundable', 'Hyvitystä ei voida jakaa maksuille (maksurivit puuttuvat tai summa alle 0,05 €)'); end if;
  return v_out;
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_change_booking(p_reservation_id bigint, p_rule_id bigint DEFAULT NULL::bigint, p_date date DEFAULT NULL::date, p_persons integer DEFAULT NULL::integer, p_allow_overbook boolean DEFAULT false, p_allow_off_schedule boolean DEFAULT false, p_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end timestamp with time zone DEFAULT NULL::timestamp with time zone, p_refund_amount numeric DEFAULT NULL::numeric, p_refund_reason text DEFAULT NULL::text, p_notify boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_res booking.reservations; v_out jsonb; v_info jsonb; v_plan jsonb; v_done jsonb := '{"refunds":[],"total":0}'::jsonb; v_reason text; v_items bigint[];
        v_notified boolean := false; v_ids jsonb; v_skip text; v_gp_share boolean;
begin
  perform booking._require_permission('bookings.manage');
  if p_rule_id is null and p_date is null and p_persons is null and p_start is null then perform booking._err('invalid_change', 'Ei muutettavaa'); end if;
  if p_refund_amount is not null then
    perform booking._require_permission('payments.refund');
    if not booking._flag_on('partial_refunds_enabled') then perform booking._err('partial_refunds_disabled', 'Osahyvitys ei ole käytössä'); end if;
    if p_refund_amount < 0.05 or p_refund_amount <> round(p_refund_amount, 2) then perform booking._err('invalid_amount', 'Hyvityksen vähimmäissumma on 0,05 €'); end if;
  end if;
  select * into v_res from booking.reservations where id = p_reservation_id;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  -- Lukitus: tilaus ensin (kaikki hyvitysreitit serialisoituvat tähän), sitten ydin lukitsee varauksen
  perform 1 from booking.orders where id = v_res.order_id for update;
  if p_refund_amount is not null and booking._order_invoice_locked(v_res.order_id) then
    perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
  end if;
  perform booking._arm_staff_overrides(p_allow_overbook, p_allow_off_schedule, p_start, p_end);
  v_out := booking._change_booking_core(p_reservation_id, p_rule_id, p_date, p_persons, false, null, auth.uid(), 'ADMIN_CHANGE');
  if p_refund_amount is not null then
    v_info := booking._order_refund_info(v_res.order_id);
    v_gp_share := exists (select 1 from jsonb_array_elements(coalesce(v_info -> 'payments', '[]'::jsonb)) e where e ->> 'kind' in ('gift_card', 'partner_voucher'));
    if (v_info ->> 'refundable_max')::numeric < 0.05 then
      -- booking_307: maksettu kokonaan lahjakortilla/kumppanikoodilla (rahaosuus 0) → muutos tehdään, rahaa ei hyvitetä (0 €), ei virhettä
      if not v_gp_share then perform booking._err('nothing_to_refund', 'Muutoksesta ei synny hyvitettävää ylisuoritusta'); end if;
      v_skip := 'no_money_share';
    end if;
    select array_agg(i.id) into v_items from booking.order_items i where i.order_id = v_res.order_id and (i.id = v_res.order_item_id or i.parent_item_id = v_res.order_item_id);
    -- booking_307: lahjakortti-/kumppaniosuuden tilauksessa summa leikataan rahaosuuteen (_refund_allocate); muuten virhe amount_exceeds_refundable kumoaa koko muutoksen
    v_plan := case when v_skip is null then booking._refund_allocate(v_res.order_id, p_refund_amount, null, v_items) else '[]'::jsonb end;
    v_reason := coalesce(nullif(btrim(p_refund_reason), ''), 'Varauksen muutos (varaus #' || v_res.id || ')');
    v_done := booking._do_refunds(v_plan, v_reason, coalesce(p_notify, false));
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (auth.uid(), booking._jwt_role(), 'reservations', v_res.id::text, 'ADMIN_CHANGE_REFUND', null,
            jsonb_build_object('refund_total', v_done -> 'total', 'refunds', v_done -> 'refunds', 'reason', v_reason,
                               'refund_requested', p_refund_amount, 'refund_skipped', v_skip));
  end if;
  if coalesce(p_notify, false) then
    select coalesce(jsonb_agg(e -> 'refund_id'), '[]'::jsonb) into v_ids from jsonb_array_elements(v_done -> 'refunds') e;
    v_notified := coalesce(booking._enqueue_email('order_change', v_res.order_id, null, null,
      'order_change:' || v_res.order_id || ':' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'),
      jsonb_build_object('source', 'admin_change', 'reservation_id', v_res.id, 'refund_ids', v_ids)), false);
  end if;
  return v_out || jsonb_build_object('ok', true, 'refunds', v_done -> 'refunds', 'refunded_total', v_done -> 'total', 'notified', v_notified,
                                     'balance', booking._order_balance(v_res.order_id))
         || case when p_refund_amount is not null then jsonb_build_object('refund_requested', p_refund_amount,
                   'refund_capped', (v_done ->> 'total')::numeric < p_refund_amount - 0.004, 'refund_skipped', v_skip,
                   'non_refundable_amount', (booking._order_refund_info(v_res.order_id) -> 'non_refundable_amount')) else '{}'::jsonb end;
end $function$;

CREATE OR REPLACE FUNCTION booking._change_booking_core(p_reservation_id bigint, p_rule_id bigint, p_date date, p_persons integer, p_enforce_deadline boolean, p_notice_hours integer, p_actor uuid, p_via text, p_allow_paid_decrease boolean DEFAULT false)
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
  -- booking_307: yleisen vuoron siirto vain kerran (ehdot: "siirto vain kerran"). Koskee asiakkaan omaa siirtoa (p_notice_hours annettu = asiakaspolku);
  -- henkilökunta (admin_change_booking, p_notice_hours null) saa ohittaa. Siirto = alkuaika muuttuu; pelkkä henkilömäärän muutos ei ole siirto.
  if p_notice_hours is not null and rs.o_starts_at is distinct from res.starts_at and booking._customer_move_blocked(res.id) then
    perform booking._err('already_moved', 'Varauksen voi siirtää verkossa vain kerran – ota yhteyttä sähköpostitse');
  end if;

  if not v_locked then
    select * into pr from booking._rule_price(v_rule, v_persons);
    v_total := case when res.annual_card_id is not null then 0 else pr.total end;
    v_addons := booking._addon_total_after(res.order_item_id, v_persons);
    select coalesce(sum(amount) filter (where status in ('paid','partially_refunded','refunded')), 0) into v_paid from booking.payments where order_id = o.id;
    if p_notice_hours is not null and v_paid > 0 and (v_total + v_addons) is distinct from o.total_gross
       and not (p_allow_paid_decrease and (v_total + v_addons) < o.total_gross) then   -- booking_284: asiakkaan automaattinen pienennys (palvelin on jo tarkistanut ehdot)
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
                            'old_total', o.total_gross, 'overbooked', res.overbooked, 'off_schedule', res.off_schedule)
         || case when v_locked then jsonb_build_object('invoice_locked', true) else '{}'::jsonb end;
end $function$;

CREATE OR REPLACE FUNCTION booking.public_change_booking(p_token uuid, p_rule_id bigint DEFAULT NULL::bigint, p_date date DEFAULT NULL::date, p_persons integer DEFAULT NULL::integer, p_expected_refund numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_ip text := booking._client_ip(); o booking.orders; v_res_id bigint; v_n int; v_out jsonb; v_detail text; v_msg text;
  v_hours integer := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  v_ev jsonb; v_refunds jsonb := '[]'::jsonb; v_old_total numeric; v_days integer;
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

  -- booking_307: yleisen vuoron siirto vain kerran – selkeä vastaus jo ennen ydintä (ydin valvoo lopullisesti alkuajan perusteella)
  if p_rule_id is not null and booking._customer_move_blocked(v_res_id)
     and exists (select 1 from booking.reservations r where r.id = v_res_id
                  and (r.rule_id is distinct from p_rule_id or (r.starts_at at time zone booking._tz())::date is distinct from p_date)) then
    return jsonb_build_object('ok', false, 'code', 'already_moved', 'message', 'Varauksen voi siirtää verkossa vain kerran – ota yhteyttä sähköpostitse');
  end if;

  -- booking_284: tilaus lukitaan ennen arviota (kaksi samanaikaista pyyntöä ei voi hyvittää kahdesti), arvio tuoreesta tilasta
  select * into o from booking.orders where id = o.id for update;
  v_ev := booking._reduce_eval(o.id, v_res_id, p_rule_id, p_date, p_persons);
  if v_ev ->> 'mode' = 'reduce' then
    if not (v_ev ->> 'allowed')::boolean then
      -- sama vastaus kuin ennen (price_change_requires_staff); syy erikseen käyttöliittymälle
      return jsonb_build_object('ok', false, 'code', 'price_change_requires_staff', 'reduce_reason', v_ev ->> 'reason',
                                'message', 'Maksettu varaus, jonka hinta muuttuisi: ota yhteyttä henkilökuntaan');
    end if;
    if p_expected_refund is null or abs(p_expected_refund - (v_ev ->> 'refund_amount')::numeric) > 0.004 then
      return jsonb_build_object('ok', false, 'code', 'refund_confirmation_required', 'refund_amount', v_ev -> 'refund_amount',
                                'message', 'Vahvista hyvitys: hinta tai hyvitys on muuttunut');
    end if;
  end if;

  begin  -- alitransaktio: virhe kumoaa muutoksen kokonaan (vanha varaus säilyy) mutta rate limit -kirjaus säilyy
    v_out := booking._change_booking_core(v_res_id, p_rule_id, p_date, p_persons, true, v_hours, null, 'CUSTOMER_CHANGE', v_ev ->> 'mode' = 'reduce');
    if v_ev ->> 'mode' = 'reduce' then
      v_old_total := (v_out ->> 'old_total')::numeric;
      -- yksityis-/tapahtumavuoro: myös uuden vuoron alkuun ≥ 14 vrk (tarkka aika vasta ytimen jälkeen)
      v_days := coalesce((booking._setting('customer_reduce_full_refund_days_private', '14'::jsonb) #>> '{}')::int, 14);
      if v_ev ->> 'tier' = 'private_event' and (v_out ->> 'starts_at')::timestamptz - make_interval(days => v_days) < now() then
        perform booking._err('change_too_late', 'Uuden vuoron pitää alkaa vähintään ' || v_days || ' vrk päästä – ota yhteyttä henkilökuntaan');
      end if;
      if abs((v_old_total - (v_out ->> 'total')::numeric) - (v_ev ->> 'refund_amount')::numeric) > 0.004 then
        perform booking._err('preview_stale', 'Hinta muuttui, yritä uudelleen');
      end if;
      v_refunds := booking._customer_refund_create(o.id, (v_ev ->> 'refund_amount')::numeric, v_res_id);
      insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
      values (null, booking._jwt_role(), 'orders', o.id::text, 'CUSTOMER_REDUCE_REFUND', jsonb_build_object('total', v_old_total),
              jsonb_build_object('total', v_out -> 'total', 'refund_amount', v_ev -> 'refund_amount', 'refunds', v_refunds, 'reservation_id', v_res_id));
      perform booking._enqueue_email('order_change', o.id, null, null, 'order_change:' || o.id || ':' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'),
        jsonb_build_object('source', 'customer_reduce', 'reservation_id', v_res_id, 'refund_ids', (select coalesce(jsonb_agg(e -> 'refund_id'), '[]'::jsonb) from jsonb_array_elements(v_refunds) e),
                           'refund_amount', v_ev -> 'refund_amount'));
    end if;
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  return jsonb_build_object('ok', true, 'order_no', v_out -> 'order_no', 'starts_at', v_out -> 'starts_at', 'ends_at', v_out -> 'ends_at',
                            'persons', v_out -> 'persons', 'total', v_out -> 'total')
         || case when jsonb_array_length(v_refunds) > 0 then jsonb_build_object('refund_amount', v_ev -> 'refund_amount', 'refund_pending', true) else '{}'::jsonb end;
end $function$;

notify pgrst, 'reload schema';
