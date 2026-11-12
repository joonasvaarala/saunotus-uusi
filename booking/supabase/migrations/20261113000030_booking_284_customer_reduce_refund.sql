-- booking_284: asiakkaan oma pienennys + automaattinen Montonio-osahyvitys (tilausnäkymä v3 §3.5 + §4 K, PR 3).
-- LIPPU: settings.customer_auto_partial_refund_enabled (oletus false) – lisäksi vaaditaan partial_refunds_enabled (booking_282): asiakaslippu avataan vasta
-- hallinnan lipun jälkeen. Kun lippu on pois, public_change_booking käyttäytyy täsmälleen kuten ennen (maksettu + hinta muuttuu → price_change_requires_staff).
--
-- Uudet: product_config.cancellation_tier ('general' | 'private_event' | null = luokittelematon → ohjataan henkilökunnalle),
--        settings customer_auto_partial_refund_enabled, customer_reduce_full_refund_days_private (14), customer_reduce_cooldown_minutes (60),
--        _reduce_eval(...), _customer_refund_create(...), public_change_preview(p_token, p_rule_id, p_date, p_persons).
-- Muutettu: _change_booking_core (+ p_allow_paid_decrease, palauttaa old_total), public_change_booking (+ p_expected_refund).
--
-- Ehdot (vain nykyisistä peruutusehdoista, ei uusia):
--   yleinen vuoro ('general'): alkuun ≥ customer_change_hours_before h (48) – ydin valvoo sekä vanhalle että uudelle vuorolle
--   yksityis-/tapahtuma-/perinneilta ('private_event'): alkuun ≥ customer_reduce_full_refund_days_private (14) vrk, sekä vanhalle että uudelle vuorolle;
--       7–14 vrk:n 50 % -porras ja alle 7 vrk jätetään henkilökunnalle (ei automatisoida)
--   luokittelematon tuote: ei automaattista pienennystä (ohjataan henkilökunnalle)
--   kaikkien maksettujen maksujen on oltava Montonio (verkkomaksu, ei lahjakortti/kumppanikoodi/käteinen/lasku), tilauksen oltava kokonaan maksettu
--   hyvitettävä = vanha summa − uusi summa, ≥ 0,05 €, ei koskaan yli maksetun (mikään ylisuoritus ei hyvity automaattisesti)
--   enintään 1 automaattinen pienennys / tunti / tilaus; rate limit (IP + token) kuten muutoksessa
-- Rahaa liikuttava osa on yksi transaktio: muutos + refunds-rivi (requested, provider montonio, created_by null, reason customer_reduce) + audit + viesti.
-- Hyvityksen lähetys Montonioon: Edge montonio-refund käsittelee requested-rivit (Hyvitykset-lista/booking_218). Asiakaspuolelta Edgeä ei voi kutsua
-- (vaatii service_role/henkilökunnan JWT): ajastettu käsittelijä on avoin asia (ks. YHTEENVETO).
-- Rollback: rollbacks/20261113000030_booking_284_ROLLBACK.sql
set local lock_timeout = '5s';

do $pre$
declare v text;
begin
  if to_regprocedure('booking._order_refund_info(bigint,numeric)') is null then raise exception 'booking_284: booking_282 puuttuu. Ei muutoksia.'; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._change_booking_core(bigint,bigint,date,integer,boolean,integer,uuid,text)')));
  if v is not null and v <> '1676470b318f1fa2e15e20499f3b304e' then raise exception 'booking_284: _change_booking_core md5 % ei vastaa odotettua. Ei muutoksia.', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_change_booking(uuid,bigint,date,integer)')));
  if v is not null and v <> 'd2ccd2fd798f8a2f8784b9bf8ce5887f' then raise exception 'booking_284: public_change_booking md5 % ei vastaa odotettua. Ei muutoksia.', v; end if;
end $pre$;

insert into booking.settings(key, value, description, is_public) values
  ('customer_auto_partial_refund_enabled', 'false'::jsonb, 'Asiakkaan oma pienennys + automaattinen Montonio-osahyvitys päällä. Oletus pois. Vaatii myös partial_refunds_enabled.', false),
  ('customer_reduce_full_refund_days_private', '14'::jsonb, 'Yksityis-/tapahtumavuoro: automaattinen pienennys sallittu, kun alkuun on vähintään näin monta vuorokautta (ehtoteksti: maksuton 14 vrk).', true),
  ('customer_reduce_cooldown_minutes', '60'::jsonb, 'Enintään yksi automaattinen pienennys tilausta kohden tässä ajassa (minuuttia).', false)
on conflict (key) do nothing;

alter table booking.product_config add column if not exists cancellation_tier text;
do $c$ begin
  if not exists (select 1 from pg_constraint where conname = 'product_config_cancellation_tier_check') then
    alter table booking.product_config add constraint product_config_cancellation_tier_check check (cancellation_tier is null or cancellation_tier in ('general', 'private_event'));
  end if;
end $c$;
comment on column booking.product_config.cancellation_tier is
  'Peruutusehtojen ryhmä asiakkaan omaa pienennystä varten: general (48 h) | private_event (14 vrk); null = luokittelematon → asiakas ohjataan henkilökunnalle. Luokittelu tehdään erikseen ennen lipun avausta.';

create or replace function booking._change_booking_core(p_reservation_id bigint, p_rule_id bigint, p_date date, p_persons integer, p_enforce_deadline boolean, p_notice_hours integer, p_actor uuid, p_via text, p_allow_paid_decrease boolean DEFAULT false)
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

drop function if exists booking._change_booking_core(bigint, bigint, date, integer, boolean, integer, uuid, text);

-- Arvioi asiakkaan pienennyksen: mode none (ei hinnanlaskua) | unpaid (maksamaton tilaus, ei hyvitystä) | reduce (maksettu tilaus, hinta laskee).
create or replace function booking._reduce_eval(p_order_id bigint, p_reservation_id bigint, p_rule_id bigint, p_date date, p_persons integer)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o booking.orders; res booking.reservations; v_pp jsonb; v_old numeric; v_new numeric; v_net numeric; v_tier text; v_hours int; v_days int; v_refund numeric;
        v_reason text; v_info jsonb; v_cool int; v_today date;
begin
  select * into o from booking.orders where id = p_order_id;
  select * into res from booking.reservations where id = p_reservation_id;
  v_pp := booking._change_price_preview(res.id, p_rule_id, p_persons);
  v_old := (v_pp ->> 'old_total')::numeric; v_new := (v_pp ->> 'new_total')::numeric;
  if v_new >= v_old - 0.004 then
    return jsonb_build_object('mode', 'none', 'old_total', v_old, 'new_total', v_new, 'diff', round(v_new - v_old, 2));
  end if;
  v_info := booking._order_refund_info(o.id);
  v_net := (v_info ->> 'net_paid')::numeric;
  if (booking._order_balance(o.id) ->> 'net_paid')::numeric <= 0.004 and not exists (select 1 from booking.payments x where x.order_id = o.id and x.status in ('paid', 'partially_refunded', 'refunded')) then
    return jsonb_build_object('mode', 'unpaid', 'old_total', v_old, 'new_total', v_new, 'diff', round(v_new - v_old, 2));
  end if;
  v_hours := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  v_days := coalesce((booking._setting('customer_reduce_full_refund_days_private', '14'::jsonb) #>> '{}')::int, 14);
  v_cool := coalesce((booking._setting('customer_reduce_cooldown_minutes', '60'::jsonb) #>> '{}')::int, 60);
  v_today := (now() at time zone booking._tz())::date;
  v_refund := round(v_old - v_new, 2);
  select pc.cancellation_tier into v_tier from booking.product_config pc where pc.product_id = res.product_id;
  v_reason := case
    when o.external_source is not null then 'not_changeable'
    when booking._order_invoice_locked(o.id) then 'order_invoiced'
    when not (booking._flag_on('customer_auto_partial_refund_enabled') and booking._flag_on('partial_refunds_enabled')) then 'feature_disabled'
    when v_tier is null then 'not_classified'
    when v_tier = 'general' and res.starts_at - make_interval(hours => v_hours) < now() then 'too_late'
    when v_tier = 'private_event' and (res.starts_at - make_interval(days => v_days) < now()
                                       or (p_date is not null and p_date < v_today + v_days)) then 'too_late_private'
    when v_net < v_old - 0.004 then 'partially_paid'
    when exists (select 1 from booking.payments x
                  where x.order_id = o.id and x.status in ('paid', 'partially_refunded')
                    and not (x.provider = 'montonio' and x.gift_card_id is null and x.method not like 'partner\_voucher%' and x.method <> 'gift_card'
                             and coalesce((select c.mode from booking.integration_config c where c.key = 'montonio'), 'off') <> 'off')) then 'payment_method'
    when v_refund < 0.05 then 'refund_too_small'
    when v_net - v_refund < v_new - 0.004 or (v_info ->> 'eligible_cap')::numeric < v_refund - 0.004 then 'already_refunding'
    when exists (select 1 from booking.audit_log a where a.action = 'CUSTOMER_REDUCE_REFUND' and a.row_pk = o.id::text and a.at > now() - make_interval(mins => v_cool)) then 'cooldown'
    else null end;
  return jsonb_build_object('mode', 'reduce', 'allowed', v_reason is null, 'reason', v_reason, 'refund_amount', v_refund,
    'old_total', v_old, 'new_total', v_new, 'diff', round(v_new - v_old, 2), 'tier', v_tier);
end $$;

-- Luo Montonio-hyvitysrivit (requested) asiakkaan pienennykselle. Ei admin_refund: ei henkilökunnan oikeuksia, vain verkkomaksu, created_by null.
create or replace function booking._customer_refund_create(p_order_id bigint, p_amount numeric, p_reservation_id bigint)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_plan jsonb; x jsonb; v_id bigint; v_out jsonb := '[]'::jsonb; v_items bigint[]; res booking.reservations;
begin
  select * into res from booking.reservations where id = p_reservation_id;
  select array_agg(i.id) into v_items from booking.order_items i where i.order_id = p_order_id and (i.id = res.order_item_id or i.parent_item_id = res.order_item_id);
  v_plan := booking._refund_allocate(p_order_id, p_amount, null, v_items);   -- sama jako kuin hallinnassa; virhe kumoaa muutoksen
  for x in select * from jsonb_array_elements(v_plan) loop
    if x ->> 'provider' <> 'montonio' then perform booking._err('payment_method', 'Vain verkkomaksu hyvitetään automaattisesti'); end if;
    insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, lines, created_by)
    values ((x ->> 'payment_id')::bigint, p_order_id, (x ->> 'amount')::numeric, 'customer_reduce', 'requested', 'montonio', x -> 'lines', null) returning id into v_id;
    v_out := v_out || jsonb_build_object('refund_id', v_id, 'payment_id', (x ->> 'payment_id')::bigint, 'amount', (x ->> 'amount')::numeric);
  end loop;
  return v_out;
end $$;

create or replace function booking.public_change_preview(p_token uuid, p_rule_id bigint default null, p_date date default null, p_persons integer default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_ip text := booking._client_ip(); o booking.orders; v_res_id bigint; v_n int; v_ev jsonb; v_msg text; v_detail text;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if not booking._rate_limit('chgp:' || p_token::text, (booking._setting('rl_change_per_10min', '10'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if (p_rule_id is null) <> (p_date is null) or (p_rule_id is null and p_persons is null) then
    return jsonb_build_object('ok', false, 'code', 'invalid_change', 'message', 'Valitse uusi vuoro ja/tai henkilömäärä');
  end if;
  if p_persons is not null and (p_persons < 1 or p_persons > 50) then return jsonb_build_object('ok', false, 'code', 'invalid_persons', 'message', 'Tarkista henkilömäärä'); end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select count(*), min(r.id) into v_n, v_res_id from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  if v_n <> 1 or o.status <> 'confirmed' or exists (select 1 from booking.reservations r where r.id = v_res_id and r.rule_id is null) then
    return jsonb_build_object('ok', false, 'code', 'not_changeable', 'message', 'Tätä varausta ei voi muuttaa verkossa – ota yhteyttä sähköpostitse');
  end if;
  if p_rule_id is not null and (select r.product_id from booking.schedule_rules r where r.id = p_rule_id) is distinct from (select product_id from booking.reservations where id = v_res_id) then
    return jsonb_build_object('ok', false, 'code', 'product_mismatch', 'message', 'Varauksen voi siirtää vain saman tuotteen toiseen vuoroon');
  end if;
  v_ev := booking._reduce_eval(o.id, v_res_id, p_rule_id, p_date, p_persons);
  return jsonb_build_object('ok', true, 'old_total', v_ev -> 'old_total', 'new_total', v_ev -> 'new_total', 'diff', v_ev -> 'diff',
    'price_up', (v_ev ->> 'diff')::numeric > 0.004, 'paid', v_ev ->> 'mode' = 'reduce',
    'auto_refund', case when v_ev ->> 'mode' <> 'reduce' then null else jsonb_build_object(
        'enabled', booking._flag_on('customer_auto_partial_refund_enabled') and booking._flag_on('partial_refunds_enabled'),
        'allowed', (v_ev ->> 'allowed')::boolean, 'reason', v_ev ->> 'reason', 'amount', case when (v_ev ->> 'allowed')::boolean then v_ev -> 'refund_amount' end,
        'eta_bank_days', '1-3') end);
end $$;

create or replace function booking.public_change_booking(p_token uuid, p_rule_id bigint DEFAULT NULL::bigint, p_date date DEFAULT NULL::date, p_persons integer DEFAULT NULL::integer, p_expected_refund numeric DEFAULT NULL::numeric)
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

revoke all on function booking._reduce_eval(bigint, bigint, bigint, date, integer), booking._customer_refund_create(bigint, numeric, bigint) from public, anon, authenticated;
revoke all on function booking._change_booking_core(bigint, bigint, date, integer, boolean, integer, uuid, text, boolean) from public, anon, authenticated;
drop function if exists booking.public_change_booking(uuid, bigint, date, integer);
revoke all on function booking.public_change_booking(uuid, bigint, date, integer, numeric), booking.public_change_preview(uuid, bigint, date, integer) from public;
grant execute on function booking.public_change_booking(uuid, bigint, date, integer, numeric), booking.public_change_preview(uuid, bigint, date, integer) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
