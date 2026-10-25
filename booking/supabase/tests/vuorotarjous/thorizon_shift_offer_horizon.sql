-- thorizon: tarjousmoottorin takaraja (migraatio 20261025165813_shift_offer_horizon, tuotannossa ajettu 25.10.2026).
-- Puhdas SQL, kaikki data feikkiä (@example.test), mitään ei lähetetä: lähettimen kytkimiin ei kosketa, ja lopun poikkeus
-- (SQLSTATE TRBK0, viesti 'TESTRESULT pass=N fail=M :: ...') kumoaa kaiken, myös testin ajaksi muutetun/poistetun asetuksen
-- 'shift_offer.offer_horizon_until' ja testivuorot/-tarjoukset. Itsenäinen: ei test-skeemaa, ei vault-avainta.
-- Tarkistaa: Europe/Helsinki-päivän raja (17.12. 23:59 mukana, 18.12. 00:00 ei, 17.12. 22:30 UTC = 18.12. 00:30 Helsinki ei),
-- virheellinen/puuttuva arvo = fail closed (horizon_until null, in_horizon false, ensure/tick eivät luo tarjouksia,
-- service_closures ohittaa, cancel_for_closure ei peru), positiivinen kontrolli (takarajan sisällä ensure tarjoaa).
--
-- AJO (tuotanto tai paikallinen; postgres-roolina, yhtenä transaktiona, migraation jälkeen):
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -1 -f booking/supabase/tests/vuorotarjous/thorizon_shift_offer_horizon.sql
-- Odotettu tulos: ERROR:  TESTRESULT pass=27 fail=0 :: -   (SQLSTATE TRBK0; psql:n exit-koodi on 3 – se on tarkoitus,
-- virhe kumoaa transaktion). Mikä tahansa muu virhe tai fail>0 = testi ei mennyt läpi; myös silloin kaikki kumoutuu.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
create temp table thorizon_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into thorizon_r values (coalesce(p_ok, false), p_label) $$;
do $t$
declare
  CS uuid; H1 uuid; S_IN uuid; S_OUT uuid; t0 timestamptz; dH date; v_st timestamptz;
  j jsonb; v_offers bigint; v_msgs bigint; v_skips bigint;
begin
  -- ---------------- K: kiinteä takaraja 2026-12-17 (asetetaan tämän transaktion ajaksi, jotta testi ei riipu tuotannon arvosta)
  perform pg_temp.ck(exists (select 1 from booking.settings where key = 'shift_offer.offer_horizon_until'), 'K0: asetus shift_offer.offer_horizon_until on olemassa');
  update booking.settings set value = to_jsonb('2026-12-17'::text) where key = 'shift_offer.offer_horizon_until';
  perform pg_temp.ck(booking.shift_offer_horizon_until() = date '2026-12-17', 'K1: horizon_until = 2026-12-17');
  perform pg_temp.ck(booking.shift_offer_in_horizon(timestamptz '2026-12-17 23:59 Europe/Helsinki') is true, 'K2: 17.12. 23:59 Helsinki mukana');
  perform pg_temp.ck(booking.shift_offer_in_horizon(timestamptz '2026-12-18 00:00 Europe/Helsinki') is false, 'K3: 18.12. 00:00 Helsinki ei');
  perform pg_temp.ck(booking.shift_offer_in_horizon(timestamptz '2026-12-17 22:30 UTC') is false, 'K4: 17.12. 22:30 UTC (= 18.12. 00:30 Helsinki) ei');
  perform pg_temp.ck(booking.shift_offer_in_horizon(timestamptz '2026-12-17 21:59 UTC') is true, 'K5: 17.12. 21:59 UTC (= 23:59 Helsinki) mukana');
  perform pg_temp.ck(booking.shift_offer_in_horizon(null) is false, 'K6: null-alku = false');
  perform pg_temp.ck(booking.shift_offer_report_issues()->>'offer_horizon_until' = '2026-12-17', 'K7: report_issues raportoi offer_horizon_until');
  update booking.settings set value = to_jsonb('2026-13-45'::text) where key = 'shift_offer.offer_horizon_until';
  perform pg_temp.ck(booking.shift_offer_horizon_until() is null and booking.shift_offer_in_horizon(now()) is false, 'K8: virheellinen päivä (2026-13-45) = fail closed');
  update booking.settings set value = to_jsonb('17.12.2026'::text) where key = 'shift_offer.offer_horizon_until';
  perform pg_temp.ck(booking.shift_offer_horizon_until() is null, 'K9: väärä muoto (17.12.2026) = fail closed');
  update booking.settings set value = '20261217'::jsonb where key = 'shift_offer.offer_horizon_until';
  perform pg_temp.ck(booking.shift_offer_horizon_until() is null, 'K10: numero = fail closed');

  -- ---------------- testidata: lämmittäjävuorot päivinä dH (takarajan päivä) ja dH+1, t0 = huomenna 12:00 Helsinki
  t0 := (((now() at time zone 'Europe/Helsinki')::date + 1) + time '12:00') at time zone 'Europe/Helsinki';
  select d into dH from generate_series((t0 at time zone 'Europe/Helsinki')::date + 20, (t0 at time zone 'Europe/Helsinki')::date + 60, interval '1 day') g(d0)
         cross join lateral (select g.d0::date d) x
   where public.shift_offer_allowed('heater', d) and public.shift_offer_allowed('heater', d + 1)
     and not public.shift_offer_blocked_by_closure('heater', (d + time '10:00') at time zone 'Europe/Helsinki', (d + time '18:00') at time zone 'Europe/Helsinki', 'vacant_shift')
     and not public.shift_offer_blocked_by_closure('heater', (d + 1 + time '10:00') at time zone 'Europe/Helsinki', (d + 1 + time '18:00') at time zone 'Europe/Helsinki', 'vacant_shift')
   order by d limit 1;
  perform pg_temp.ck(dH is not null, 'D0: löytyi testipäivä (lämmittäjävuoro sallittu, ei sulkua)');
  update booking.settings set value = to_jsonb(dH::text) where key = 'shift_offer.offer_horizon_until';
  insert into public.calendar_sources (calendar_name, role_type) values ('thorizon-testi', 'heater') returning id into CS;
  insert into public.staff (name, calendar_name, email, phone_e164, active, whatsapp_enabled, bot_channel)
  values ('Hilja Horizon', 'Hilja Horizon', 'hilja.horizon@example.test', null, true, false, false) returning id into H1;
  insert into public.staff_roles (staff_id, role_type, active) values (H1, 'heater', true);
  -- roolit päälle vain tämän transaktion ajaksi (therapist: service_closures käsittelee vain, jos hoitajarooli on päällä)
  delete from public.shift_offer_settings where role_type in ('heater', 'therapist');
  insert into public.shift_offer_settings (role_type, enabled, auto_close_enabled, start_before) values
    ('heater', true, false, interval '3 months'), ('therapist', true, false, interval '3 months');
  delete from public.shift_offer_rounds where role_type = 'heater';
  insert into public.shift_offer_rounds (role_type, scenario, weekdays, round_no, kind) values ('heater', 'vacant_shift', '{1,2,3,4,5,6,7}', 1, 'named');
  insert into public.shift_offer_round_members (round_id, staff_id, sort_order)
  select r.id, H1, 1 from public.shift_offer_rounds r where r.role_type = 'heater' and r.round_no = 1;
  v_st := (dH + time '10:00') at time zone 'Europe/Helsinki';
  insert into public.work_shifts (calendar_source_id, google_event_id, calendar_title, starts_at, ends_at, role_type, status, staffing_status)
  values (CS, 'thorizon-' || gen_random_uuid()::text, '-', v_st, v_st + interval '8 hours', 'heater', 'active', 'open') returning id into S_IN;
  insert into public.work_shifts (calendar_source_id, google_event_id, calendar_title, starts_at, ends_at, role_type, status, staffing_status)
  values (CS, 'thorizon-' || gen_random_uuid()::text, '-', v_st + interval '1 day', v_st + interval '1 day 8 hours', 'heater', 'active', 'open') returning id into S_OUT;

  -- ---------------- E: takaraja asetettu (dH)
  j := public.shift_offer_ensure(S_OUT, t0, false);
  perform pg_temp.ck(j->>'action' = 'skip' and j->>'reason' = 'horizon' and not exists (select 1 from public.shift_offers where shift_id = S_OUT),
                     'E1: takarajan jälkeinen vuoro (dH+1): ensure skip horizon, ei tarjousta: ' || j::text);
  j := public.shift_offer_tick(true, t0);
  perform pg_temp.ck(j->>'offer_horizon_until' = dH::text, 'E2: tick raportoi offer_horizon_until = dH');
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(j->'actions') a where a->>'shift_id' = S_IN::text and a->>'action' = 'would_offer')
                     and not exists (select 1 from jsonb_array_elements(j->'actions') a where a->>'shift_id' = S_OUT::text),
                     'E3: dry-run tick: dH-vuoro tarjottaisiin, dH+1-vuoroa ei käsitellä');

  -- ---------------- F: asetus poistettu (vain tässä transaktiossa) = fail closed
  delete from booking.settings where key = 'shift_offer.offer_horizon_until';
  perform pg_temp.ck(booking.shift_offer_horizon_until() is null, 'F1: horizon_until null');
  perform pg_temp.ck(booking.shift_offer_in_horizon(v_st) is false and booking.shift_offer_in_horizon(now() + interval '1 day') is false, 'F2: in_horizon false');
  select count(*) into v_offers from public.shift_offers;
  select count(*) into v_msgs from public.shift_offer_messages;
  select count(*) into v_skips from booking.shift_offer_skips;
  j := public.shift_offer_ensure(S_IN, t0, false);
  perform pg_temp.ck(j->>'action' = 'skip' and j->>'reason' = 'horizon', 'F3: ensure skip horizon: ' || j::text);
  j := public.shift_offer_tick(false, t0);
  perform pg_temp.ck(j ? 'offer_horizon_until' and j->'offer_horizon_until' = 'null'::jsonb, 'F4: tick: offer_horizon_until null');
  perform pg_temp.ck(j->'actions' = '[]'::jsonb, 'F5: tick: ei toimenpiteitä: ' || left((j->'actions')::text, 200));
  perform pg_temp.ck(j #>> '{service_closures,reason}' = 'no_horizon' and (j #>> '{service_closures,skipped}')::boolean,
                     'F6: service_closures ohitettu (no_horizon)');
  perform pg_temp.ck((j #>> '{cancel,cancelled}')::int = 0, 'F7: cancel_for_closure ei peru mitään');
  perform pg_temp.ck(not exists (select 1 from public.shift_offers where shift_id in (S_IN, S_OUT))
                     and (select count(*) from public.shift_offers) = v_offers
                     and (select count(*) from public.shift_offer_messages) = v_msgs
                     and (select count(*) from booking.shift_offer_skips) = v_skips,
                     'F8: ensure/tick eivät luoneet tarjouksia, viestejä eivätkä skip-kirjauksia');
  j := public.shift_offer_service_closures(t0, true);
  perform pg_temp.ck(j->>'reason' = 'no_horizon', 'F9: service_closures suoraan: no_horizon');

  -- ---------------- P: positiivinen kontrolli (asetus palautettu dH:ksi): sama vuoro tarjotaan
  insert into booking.settings (key, value, description, is_public) values ('shift_offer.offer_horizon_until', to_jsonb(dH::text), 'thorizon (kumoutuu)', false);
  j := public.shift_offer_ensure(S_IN, t0, false);
  perform pg_temp.ck(j->>'action' = 'offered' and exists (select 1 from public.shift_offers where shift_id = S_IN and status = 'active'),
                     'P1: takarajan sisällä ensure tarjoaa (kontrolli): ' || j::text);
  perform pg_temp.ck(public.shift_offer_ensure(S_OUT, t0, false)->>'reason' = 'horizon', 'P2: dH+1 edelleen skip horizon');
  j := public.shift_offer_service_closures(t0, true);
  perform pg_temp.ck(j ? 'closures' and not j ? 'skipped', 'P3: service_closures käsittelee takarajan ollessa asetettu (dry-run): ' || left(j::text, 200));

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from thorizon_r where ok), (select count(*) from thorizon_r where not ok),
    coalesce((select string_agg(label, ' || ') from thorizon_r where not ok), '-')
    using errcode = 'TRBK0';
end $t$;
