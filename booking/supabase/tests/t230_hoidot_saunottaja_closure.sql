-- t230: Hoidot kiinni sulkee saunottajaa tarvitsevat tuotteet (Joonas 1.11.2026, booking_230).
-- Sulku on space_blocks saunottaja-resurssilla (closure_calendars.code = hoidot). Tuotteet haetaan slugilla.
-- Avoin päivä: hoito, rituaali ja paketti tarjotaan (ok tai therapist_missing — ei vaadita vapaata saunottajaa).
-- Hoidot kiinni rituaalijalan päällä: rituaali ja paketti piilossa, hoito samalla kellonlyömällä piilossa,
--   myöhempi rituaali ja savusaunan ulkopuolinen hoito tarjotaan, yleinen ja yksityinen savusauna ennallaan.
-- Sulku vain paketin savusaunaosalla: paketin alkuaika tarjotaan yhä.
-- Rauni kiinni: hoito (Lovi) tarjotaan, rituaali ja paketti eivät, savusauna ennallaan.
-- Uusi kassavaraus suljetulle ajalle ei onnistu. Aiempi varaus jää voimaan. Henkilökunnan p_override päästää läpi.
--
-- Ajo (psql, migraatiot kannassa; ei vaadi test-skeemaa). Kaikki yhdessä transaktiossa, lopuksi poikkeus kumoaa kaiken.
--   psql -X -v ON_ERROR_STOP=1 -f booking/supabase/tests/t230_hoidot_saunottaja_closure.sql
-- Odotettu viimeinen rivi: TESTRESULT pass=N fail=0

begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create temp table t230(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  insert into t230 values (coalesce(p_ok, false), p_label)
$$;
create function pg_temp.hel(p_day date, p_hm text) returns timestamptz language sql immutable as $$
  select (p_day + p_hm::time) at time zone 'Europe/Helsinki'
$$;
create function pg_temp.dur(p_product bigint) returns integer language sql stable as $$
  select coalesce(pc.duration_minutes, p.duration_minutes)::integer
    from booking.product_config pc join kb.products p on p.id = pc.product_id
   where pc.product_id = p_product
$$;
create function pg_temp.plan_code(p_product bigint, p_start timestamptz, p_persons integer, p_override boolean) returns text
language plpgsql as $$
declare d text;
begin
  begin
    perform 1 from booking._plan_legs(p_product, p_start, p_start + make_interval(mins => pg_temp.dur(p_product)), p_persons, null, p_override, null, false);
    return 'ok';
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics d = pg_exception_detail;
      return coalesce(nullif(d, ''), sqlstate);
    when others then
      return 'SQLSTATE ' || sqlstate;
  end;
end $$;
create function pg_temp.offered(p_product bigint, p_day date, p_start timestamptz) returns boolean
language sql volatile as $$
  select exists (
    select 1 from booking._treatment_availability_core(p_product, p_day, p_day, 1, false, false) c
     where c.starts_at = p_start)
$$;
create function pg_temp.shifts(p_product bigint, p_day date) returns integer language sql volatile as $$
  select count(*)::integer from booking.public_availability(p_product, p_day, p_day) s where s.status = 'available'
$$;
create function pg_temp.book(p_product bigint, p_start timestamptz, p_email text) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  v := booking.public_create_treatment_booking(
    p_product, p_start, 1, 'Testi Asiakas', p_email, '0401234567', false, 'fi', null, 'private', null);
  return v;
exception when others then
  return jsonb_build_object('ok', false, 'code', sqlstate, 'message', sqlerrm);
end $$;

do $t230$
declare
  v_rit bigint; v_pkg bigint; v_tx bigint; v_pub bigint; v_prv bigint;
  v_th bigint; v_rauni bigint; v_lovi bigint;
  v_leg_off integer; v_leg_min integer; v_th_off integer; v_th_min integer;
  d date;
  t14 timestamptz; t16 timestamptz; t1630 timestamptz; t17 timestamptz;
  st text; n_pub integer; n_prv integer; n_pub2 integer; n_prv2 integer;
  v_book jsonb; v_token uuid; v_res bigint; v_status text;
  v_from timestamptz; v_to timestamptz;
  v_rule bigint; v_addon jsonb; v_times text;
begin
  select id into v_rit from kb.products where slug = 'saunotusrituaali';
  select id into v_pkg from kb.products where slug = 'saunarituaali-ja-savusaunavuoro';
  select id into v_tx from kb.products where slug = 'saunahoito-2';
  select id into v_pub from kb.products where slug = 'yleinensauna';
  select id into v_prv from kb.products where slug = 'oma-saunavuoro';
  select id into v_th from booking.resources where code = 'saunottaja';
  select id into v_rauni from booking.resources where code = 'rauni';
  select id into v_lovi from booking.resources where code = 'lovi';
  perform pg_temp.ck(v_rit is not null and v_pkg is not null and v_tx is not null and v_pub is not null and v_prv is not null
    and v_th is not null and v_rauni is not null and v_lovi is not null, 'A0 tuotteet ja resurssit löytyvät slugilla/koodilla');
  if v_rit is null or v_th is null then
    raise exception 'TESTRESULT pass=0 fail=1 tuotteet tai saunottaja puuttuvat';
  end if;

  perform pg_temp.ck((select c.resource_id = v_th from booking.closure_calendars c where c.code = 'hoidot'),
    'A1 hoidot-kalenteri sulkee saunottajan');
  if to_regprocedure('booking._skill_block_resource(text)') is not null then
    perform pg_temp.ck(booking._skill_block_resource('yleinen') = v_th, 'A2 yleinen-taito sulkeutuu saunottajaan');
    perform pg_temp.ck(booking._skill_block_resource('laura') is distinct from v_th, 'A3 laura ei ole saunottaja');
  end if;

  select r.offset_min, r.minutes into v_leg_off, v_leg_min
    from booking.product_space_rules r
    join booking.resources s on s.id = r.space_id and s.code = 'rauni'
   where r.product_id = v_pkg and r.active
   order by r.leg_no, r.priority limit 1;
  select therapist_offset_min, therapist_minutes into v_th_off, v_th_min
    from booking.product_config where product_id = v_pkg;
  perform pg_temp.ck(v_th_min is not null and v_th_off = v_leg_off and v_th_min = v_leg_min,
    'A4 paketin saunottajaikkuna = Raunin rituaalijalka (' || coalesce(v_th_off::text, '?') || '+' || coalesce(v_th_min::text, '?') || ')');
  if v_th_min is null then
    raise exception 'TESTRESULT pass=0 fail=1 paketin saunottajaikkuna puuttuu';
  end if;

  select s::date into d
    from generate_series(date '2027-03-06', date '2027-11-27', interval '7 days') s
   where extract(isodow from s) = 6
     and booking._public_shift_day_open(s::date)
     and not exists (
       select 1 from booking.space_blocks b
        where b.active and b.space_id in (v_th, v_rauni, v_lovi, (select id from booking.resources where code = 'savusauna'))
          and b.during && tstzrange(pg_temp.hel(s::date, '00:00'), pg_temp.hel(s::date + 1, '00:00'), '[)'))
     and not exists (
       select 1 from booking.reservations r
        where booking._res_active(r.status, r.hold_expires_at)
          and r.starts_at < pg_temp.hel(s::date + 1, '00:00') and r.ends_at > pg_temp.hel(s::date, '00:00'))
   order by s limit 1;
  perform pg_temp.ck(d is not null, 'A5 vapaa lauantai ' || coalesce(d::text, 'ei löytynyt'));
  if d is null then
    raise exception 'TESTRESULT pass=0 fail=1 ei vapaata lauantaita';
  end if;

  update booking.settings set value = '900'::jsonb where key in ('booking_horizon_days', 'public_treatment_horizon_days');
  update booking.settings set value = '"pay_later"'::jsonb where key = 'public_payment_mode';
  update booking.settings set value = 'true'::jsonb where key = 'public_booking_enabled';
  update booking.product_config
     set public_slots = true, bookable = true, shop_visible = true,
         public_weekdays = coalesce(public_weekdays, array[6, 7]::smallint[])
   where product_id = v_pkg;

  t14 := pg_temp.hel(d, '14:00');
  t16 := pg_temp.hel(d, '16:00');
  t1630 := pg_temp.hel(d, '16:30');
  t17 := pg_temp.hel(d, '17:00');
  n_pub := pg_temp.shifts(v_pub, d);
  n_prv := pg_temp.shifts(v_prv, d);
  perform pg_temp.ck(n_pub > 0 and n_prv > 0, 'A6 savusauna myynnissä ennen sulkua (yleinen ' || n_pub || ', yksityinen ' || n_prv || ')');

  st := booking._treatment_plan_status(v_tx, t14, t14 + make_interval(mins => pg_temp.dur(v_tx)), 1);
  perform pg_temp.ck(st in ('ok', 'therapist_missing') and pg_temp.offered(v_tx, d, t14),
    'B1 hoito ilman sulkua tarjotaan (' || coalesce(st, 'null') || ')');
  st := booking._treatment_plan_status(v_rit, t16, t16 + make_interval(mins => pg_temp.dur(v_rit)), 1);
  perform pg_temp.ck(st in ('ok', 'therapist_missing') and pg_temp.offered(v_rit, d, t16),
    'B2 rituaali ilman sulkua tarjotaan (' || coalesce(st, 'null') || ')');
  st := booking._treatment_plan_status(v_pkg, t16, t16 + make_interval(mins => pg_temp.dur(v_pkg)), 1);
  perform pg_temp.ck(st in ('ok', 'therapist_missing') and pg_temp.offered(v_pkg, d, t16),
    'B3 paketti ilman sulkua tarjotaan (' || coalesce(st, 'null') || ')');

  v_book := pg_temp.book(v_rit, t17, 't230-ennen-' || extract(epoch from clock_timestamp())::bigint || '@example.com');
  perform pg_temp.ck((v_book ->> 'ok')::boolean is true, 'B4 rituaali 17:00 varataan ennen sulkua (' || coalesce(v_book ->> 'code', v_book ->> 'status', '?') || ')');
  if (v_book ->> 'ok')::boolean is true then
    v_token := (v_book ->> 'token')::uuid;
    select r.id, r.status into v_res, v_status
      from booking.reservations r join booking.orders o on o.id = r.order_id
     where o.public_token = v_token and r.product_id = v_rit
     order by r.id limit 1;
    perform pg_temp.ck(v_res is not null and v_status = 'confirmed', 'B5 varaus confirmed');
  end if;

  v_from := t16 + make_interval(mins => v_th_off);
  v_to := v_from + make_interval(mins => v_th_min);
  insert into booking.space_blocks(space_id, starts_at, ends_at, active, reason)
  values (v_th, v_from, v_to, true, 't230');

  perform pg_temp.ck(not pg_temp.offered(v_rit, d, t16) and booking._treatment_plan_status(v_rit, t16, t16 + make_interval(mins => pg_temp.dur(v_rit)), 1) is null,
    'C1 hoidot kiinni rituaalijalalla piilottaa 16:00 rituaalin');
  perform pg_temp.ck(pg_temp.offered(v_rit, d, t17), 'C2 myöhempi rituaali 17:00 pysyy');
  perform pg_temp.ck(not pg_temp.offered(v_pkg, d, t16), 'C3 paketti piilossa kun rituaalijalka osuu sulkuun');
  perform pg_temp.ck(pg_temp.offered(v_pkg, d, t17), 'C4 paketti 17:00 pysyy');
  perform pg_temp.ck(not pg_temp.offered(v_tx, d, t16), 'C5 hoito 16:00 piilossa (saunottaja koko hoidon ajan)');
  perform pg_temp.ck(pg_temp.offered(v_tx, d, t14), 'C6 hoito 14:00 pysyy');
  perform pg_temp.ck(pg_temp.shifts(v_pub, d) = n_pub and pg_temp.shifts(v_prv, d) = n_prv,
    'C7 yleinen ja yksityinen savusauna pysyvät (' || pg_temp.shifts(v_pub, d) || '/' || pg_temp.shifts(v_prv, d) || ')');
  perform pg_temp.ck(pg_temp.plan_code(v_rit, t16, 1, false) = 'therapist_closed', 'C8 moottori: therapist_closed');
  perform pg_temp.ck(pg_temp.plan_code(v_rit, t16, 1, true) = 'ok', 'C9 henkilökunnan ylitys (p_override) päästää läpi');

  if to_regprocedure('booking.public_ritual_addon(bigint,date,integer)') is not null then
    select r.id into v_rule from booking.schedule_rules r
     where r.product_id = v_pub and r.active and r.mode = 'shared' and r.start_time = time '16:00'
       and extract(isodow from d)::smallint = any (r.weekdays)
     limit 1;
    if v_rule is not null then
      v_addon := booking.public_ritual_addon(v_rule, d, 1);
      select coalesce(string_agg(to_char((x ->> 'starts_at')::timestamptz at time zone 'Europe/Helsinki', 'HH24:MI'), ',' order by (x ->> 'starts_at')::timestamptz), '')
        into v_times from jsonb_array_elements(coalesce(v_addon -> 'times', '[]'::jsonb)) x;
      perform pg_temp.ck(v_times not like '%16:00%' and v_times like '%17:00%',
        'C10 vuoron lisärituaali: 16:00 pois, 17:00 jäljellä (' || v_times || ')');
    else
      perform pg_temp.ck(false, 'C10 yleisen vuoron 16:00-sääntö puuttuu');
    end if;
  end if;

  v_book := pg_temp.book(v_rit, t16, 't230-sulku-' || extract(epoch from clock_timestamp())::bigint || '@example.com');
  if coalesce(v_book ->> 'code', '') in ('busy', 'rate_limited') then
    perform pg_temp.ck(pg_temp.plan_code(v_rit, t16, 1, false) = 'therapist_closed',
      'C11 kassa ruuhkautui, moottori silti therapist_closed');
  else
    perform pg_temp.ck((v_book ->> 'ok')::boolean is not true and v_book ->> 'code' = 'slot_unavailable',
      'C11 kassa hylkää suljetun rituaalin (' || coalesce(v_book ->> 'code', '?') || ')');
  end if;

  if v_res is not null then
    select r.status into v_status from booking.reservations r where r.id = v_res;
    perform pg_temp.ck(v_status = 'confirmed', 'C12 aiempi varaus ei peruunu osittaisesta sulusta');
  end if;

  delete from booking.space_blocks where reason = 't230';
  insert into booking.space_blocks(space_id, starts_at, ends_at, active, reason)
  values (v_th, v_to, t16 + make_interval(mins => pg_temp.dur(v_pkg)), true, 't230');
  perform pg_temp.ck(pg_temp.offered(v_pkg, d, t16),
    'D1 paketti 16:00 pysyy kun sulku osuu vain savusaunaosaan');
  perform pg_temp.ck(not pg_temp.offered(v_rit, d, t1630),
    'D2 rituaali 16:30 piilossa kun sen saunottajaikkuna osuu sulkuun');
  perform pg_temp.ck(pg_temp.shifts(v_pub, d) = n_pub, 'D3 yleinen vuoro pysyy savusaunaosan sulussa');

  delete from booking.space_blocks where reason = 't230';
  insert into booking.space_blocks(space_id, starts_at, ends_at, active, reason)
  values (v_th, pg_temp.hel(d, '00:00'), pg_temp.hel(d + 1, '00:00'), true, 't230');
  perform pg_temp.ck(not pg_temp.offered(v_rit, d, t16) and not pg_temp.offered(v_pkg, d, t16) and not pg_temp.offered(v_tx, d, t14),
    'E1 koko päivän hoidot kiinni piilottaa rituaalin, paketin ja hoidon');
  n_pub2 := pg_temp.shifts(v_pub, d); n_prv2 := pg_temp.shifts(v_prv, d);
  perform pg_temp.ck(n_pub2 = n_pub and n_prv2 = n_prv, 'E2 savusauna pysyy koko päivän hoidot-sulussa');
  if v_res is not null then
    select r.status into v_status from booking.reservations r where r.id = v_res;
    perform pg_temp.ck(v_status = 'confirmed', 'E3 aiempi varaus ei peruunu koko päivän sulusta');
  end if;

  delete from booking.space_blocks where reason = 't230';
  insert into booking.space_blocks(space_id, starts_at, ends_at, active, reason)
  values (v_rauni, pg_temp.hel(d, '00:00'), pg_temp.hel(d + 1, '00:00'), true, 't230');
  perform pg_temp.ck(pg_temp.offered(v_tx, d, t14), 'F1 Rauni kiinni: hoito siirtyy Loviin ja pysyy');
  perform pg_temp.ck(not pg_temp.offered(v_rit, d, t16), 'F2 Rauni kiinni: rituaali piilossa');
  perform pg_temp.ck(not pg_temp.offered(v_pkg, d, t16), 'F3 Rauni kiinni: paketti piilossa');
  perform pg_temp.ck(pg_temp.shifts(v_pub, d) = n_pub and pg_temp.shifts(v_prv, d) = n_prv, 'F4 Rauni kiinni ei sulje savusaunaa');
  if v_res is not null then
    select r.status into v_status from booking.reservations r where r.id = v_res;
    perform pg_temp.ck(v_status = 'confirmed', 'F5 aiempi rituaalivaraus ei peruunu Rauni-sulusta');
  end if;
end $t230$;

do $out$
declare n_ok integer; n_bad integer; msg text;
begin
  select count(*) filter (where ok), count(*) filter (where not ok) into n_ok, n_bad from t230;
  select string_agg(label, ' | ' order by label) into msg from t230 where not ok;
  raise exception 'TESTRESULT pass=% fail=% %', n_ok, n_bad, coalesce(msg, '');
end $out$;
rollback;
