-- t137: jonotuslistan tarjousaika (booking_137). Sama Helsingin päivä 30 min (waitlist_offer_minutes_same_day),
-- seuraava päivä tai myöhemmin 120 min (waitlist_offer_minutes); puuttuva/virheellinen asetus → 30 / 120.
-- Rajat testataan kiinteillä aikaleimoilla booking._waitlist_offer_expires_at-funktiolla (now() on transaktiossa vakio),
-- ja _notify_waitlist_for_window / public_waitlist_claim ikäännyttämällä notified_at-arvoa.
-- Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN (mock-data: Miesten sauna ma, kapasiteetti 16).
-- Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken. Tulos: TESTRESULT pass=… fail=…
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t137_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t137_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.st(p_email text) returns text language sql as $$ select status from booking.waitlist_entries where customer_email = p_email $$;
create function pg_temp.rid(p_email text) returns bigint language sql as $$
  select r.id from booking.reservations r join booking.orders o on o.id = r.order_id join booking.customers c on c.id = o.customer_id where c.email = p_email order by r.id limit 1 $$;
create function pg_temp.mails(p_email text) returns int language sql as $$
  select count(*)::int from booking.email_outbox where kind = 'waitlist_spot_freed' and payload ->> 'to_email' = p_email $$;
create function pg_temp.age(p_email text, p_age interval) returns void language sql as $$
  update booking.waitlist_entries set notified_at = now() - p_age where customer_email = p_email $$;
-- Voimassa hetkellä n + p_after? (tarjous voimassa, kun päättymisaika > hetki)
create function pg_temp.valid(p_n timestamptz, p_s timestamptz, p_after interval) returns boolean language sql as $$
  select booking._waitlist_offer_expires_at(p_n, p_s) > p_n + p_after $$;
create function pg_temp.mins(p_n timestamptz, p_s timestamptz) returns numeric language sql as $$
  select extract(epoch from booking._waitlist_offer_expires_at(p_n, p_s) - p_n) / 60 $$;
create function pg_temp.claim(p_token text) returns jsonb language plpgsql as $$
declare c jsonb; begin perform test.anon(); c := booking.public_waitlist_claim(p_token::uuid); perform test.logout(); return c; end $$;
do $t$
declare
  v_rule bigint := test.rule('Miesten sauna%'); d date := test.next_dow(1) + 35;
  n0 timestamptz := '2026-11-10 10:00 Europe/Helsinki';
  b jsonb; ja jsonb; jb jsonb; c jsonb; n int; v_space bigint; v_s timestamptz; v_e timestamptz;
  v_today_end timestamptz;
begin
  -- ===== Asetukset: migraatio lisää oletusrivit =====
  perform pg_temp.ck((select value from booking.settings where key = 'waitlist_offer_minutes_same_day') = '30'::jsonb, 'A1: waitlist_offer_minutes_same_day = 30');
  perform pg_temp.ck((select value from booking.settings where key = 'waitlist_offer_minutes') = '120'::jsonb, 'A2: waitlist_offer_minutes = 120');

  -- ===== Sama päivä: 30 min =====
  perform pg_temp.ck(pg_temp.mins(n0, '2026-11-10 18:00 Europe/Helsinki') = 30, 'B1: sama päivä → 30 min');
  perform pg_temp.ck(pg_temp.valid(n0, '2026-11-10 18:00 Europe/Helsinki', interval '29 minutes'), 'B2: sama päivä, 29 min → voimassa');
  perform pg_temp.ck(not pg_temp.valid(n0, '2026-11-10 18:00 Europe/Helsinki', interval '31 minutes'), 'B3: sama päivä, 31 min → vanhentunut');
  perform pg_temp.ck(not pg_temp.valid(n0, '2026-11-10 18:00 Europe/Helsinki', interval '30 minutes'), 'B4: täsmälleen 30 min → vanhentunut (päättymishetki ei ole voimassa)');
  -- ===== Seuraava päivä tai myöhemmin: 120 min =====
  perform pg_temp.ck(pg_temp.mins(n0, '2026-11-11 10:00 Europe/Helsinki') = 120, 'C1: seuraava päivä → 120 min');
  perform pg_temp.ck(pg_temp.valid(n0, '2026-11-11 10:00 Europe/Helsinki', interval '119 minutes'), 'C2: seuraava päivä, 119 min → voimassa');
  perform pg_temp.ck(not pg_temp.valid(n0, '2026-11-11 10:00 Europe/Helsinki', interval '121 minutes'), 'C3: seuraava päivä, 121 min → vanhentunut');
  perform pg_temp.ck(pg_temp.mins(n0, '2026-12-20 10:00 Europe/Helsinki') = 120, 'C4: viikkojen päässä → 120 min');
  -- ===== Helsingin päivänraja =====
  perform pg_temp.ck(pg_temp.mins('2026-11-10 23:50 Europe/Helsinki', '2026-11-11 00:30 Europe/Helsinki') = 120, 'D1: ilmoitus 23:50, vuoro 00:30 seuraavana päivänä → 120 min');
  perform pg_temp.ck(pg_temp.valid('2026-11-10 23:50 Europe/Helsinki', '2026-11-11 00:30 Europe/Helsinki', interval '119 minutes')
    and not pg_temp.valid('2026-11-10 23:50 Europe/Helsinki', '2026-11-11 00:30 Europe/Helsinki', interval '121 minutes'), 'D2: 23:50 → 00:30: 119 min voimassa, 121 min ei');
  perform pg_temp.ck(pg_temp.mins('2026-11-11 00:10 Europe/Helsinki', '2026-11-11 00:30 Europe/Helsinki') = 30, 'D3: ilmoitus 00:10 samana päivänä → 30 min');
  -- UTC-päivä eri kuin Helsingin päivä: 01:30 Helsinki = 23:30 UTC edellisenä päivänä → silti sama Helsingin päivä
  perform pg_temp.ck(pg_temp.mins('2026-11-11 01:30 Europe/Helsinki', '2026-11-11 18:00 Europe/Helsinki') = 30, 'D4: talviaika: Helsingin päivä ratkaisee, ei UTC');
  perform pg_temp.ck(pg_temp.mins('2027-06-15 00:30 Europe/Helsinki', '2027-06-15 20:00 Europe/Helsinki') = 30, 'D5: kesäaika: Helsingin päivä ratkaisee, ei UTC');
  perform pg_temp.ck(pg_temp.mins('2027-06-14 23:30 Europe/Helsinki', '2027-06-15 00:30 Europe/Helsinki') = 120, 'D6: kesäaika: 23:30 → 00:30 → 120 min');
  perform pg_temp.ck(booking._waitlist_offer_expires_at(null, n0) is null and booking._waitlist_offer_expires_at(n0, null) is null, 'D7: null → null');

  -- ===== Asetusarvot =====
  update booking.settings set value = '45'::jsonb where key = 'waitlist_offer_minutes_same_day';
  update booking.settings set value = '90'::jsonb where key = 'waitlist_offer_minutes';
  perform pg_temp.ck(pg_temp.mins(n0, '2026-11-10 18:00 Europe/Helsinki') = 45 and pg_temp.mins(n0, '2026-11-11 10:00 Europe/Helsinki') = 90, 'E1: asetukset 45 / 90 käytössä');
  update booking.settings set value = '"50"'::jsonb where key = 'waitlist_offer_minutes_same_day';
  perform pg_temp.ck(pg_temp.mins(n0, '2026-11-10 18:00 Europe/Helsinki') = 50, 'E2: merkkijono "50" hyväksytään');
  update booking.settings set value = '0'::jsonb where key = 'waitlist_offer_minutes_same_day';
  update booking.settings set value = '"ei-numero"'::jsonb where key = 'waitlist_offer_minutes';
  perform pg_temp.ck(pg_temp.mins(n0, '2026-11-10 18:00 Europe/Helsinki') = 30 and pg_temp.mins(n0, '2026-11-11 10:00 Europe/Helsinki') = 120, 'E3: 0 ja ei-numero → oletukset 30 / 120');
  update booking.settings set value = '1.5'::jsonb where key = 'waitlist_offer_minutes_same_day';
  update booking.settings set value = '-5'::jsonb where key = 'waitlist_offer_minutes';
  perform pg_temp.ck(pg_temp.mins(n0, '2026-11-10 18:00 Europe/Helsinki') = 30 and pg_temp.mins(n0, '2026-11-11 10:00 Europe/Helsinki') = 120, 'E4: desimaali ja negatiivinen → oletukset');
  update booking.settings set value = '9999999'::jsonb where key = 'waitlist_offer_minutes';
  perform pg_temp.ck(pg_temp.mins(n0, '2026-11-11 10:00 Europe/Helsinki') = 120, 'E5: liian suuri (yli 6 numeroa) → oletus, ei ylivuotoa');
  delete from booking.settings where key in ('waitlist_offer_minutes_same_day', 'waitlist_offer_minutes');
  perform pg_temp.ck(pg_temp.mins(n0, '2026-11-10 18:00 Europe/Helsinki') = 30 and pg_temp.mins(n0, '2026-11-11 10:00 Europe/Helsinki') = 120, 'E6: puuttuvat rivit → oletukset 30 / 120');

  -- ===== _notify_waitlist_for_window: 119 min voimassa, 121 min vanhentunut (vuoro 5 viikon päässä → 120 min) =====
  b := test.pub_book(v_rule, d, 12, 'iso@t137.example');  perform pg_temp.ck((b ->> 'ok')::boolean, 'F1: 12 hlöä');
  b := test.pub_book(v_rule, d, 4, 'nelja@t137.example'); perform pg_temp.ck((b ->> 'ok')::boolean, 'F2: 4 hlöä (vuoro täynnä)');
  perform test.anon();
  ja := booking.public_join_waitlist(v_rule, d, 4, 'Jono A', 'a@t137.example');
  jb := booking.public_join_waitlist(v_rule, d, 4, 'Jono B', 'b@t137.example');
  perform test.logout();
  perform pg_temp.ck((ja ->> 'ok')::boolean and (jb ->> 'ok')::boolean, 'F3: A4 ja B4 jonoon');
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('nelja@t137.example');
  perform pg_temp.ck(pg_temp.st('a@t137.example') = 'notified' and pg_temp.st('b@t137.example') = 'waiting', 'F4: 4 paikkaa → A ilmoitetaan, B odottaa');
  select space_id, starts_at, ends_at into v_space, v_s, v_e from booking.waitlist_entries where customer_email = 'a@t137.example';
  perform pg_temp.age('a@t137.example', interval '119 minutes');
  n := booking._notify_waitlist_for_window(v_space, v_s, v_e);
  perform pg_temp.ck(n = 0 and pg_temp.st('b@t137.example') = 'waiting' and pg_temp.mails('b@t137.example') = 0, 'F5: A:n tarjous 119 min → voimassa, B ei saa samoja paikkoja');
  c := pg_temp.claim(ja ->> 'token');
  perform pg_temp.ck((c ->> 'ok')::boolean and (c ->> 'enough')::boolean, 'F6: A lunastaa 119 min kohdalla');
  perform pg_temp.age('a@t137.example', interval '121 minutes');
  n := booking._notify_waitlist_for_window(v_space, v_s, v_e);
  perform pg_temp.ck(n = 1 and pg_temp.st('b@t137.example') = 'notified' and pg_temp.mails('b@t137.example') = 1, 'F7: A:n tarjous 121 min → vanhentunut, B saa ilmoituksen');
  c := pg_temp.claim(ja ->> 'token');
  perform pg_temp.ck(c ->> 'code' = 'offer_expired' and not (c ->> 'ok')::boolean, 'F8: A:n lunastus 121 min jälkeen → offer_expired');
  perform pg_temp.ck(pg_temp.st('a@t137.example') = 'notified' and pg_temp.mails('a@t137.example') = 1, 'F9: offer_expired ei muuta tilaa eikä lähetä uutta ilmoitusta');
  n := booking._notify_waitlist_for_window(v_space, v_s, v_e);
  perform pg_temp.ck(n = 0 and pg_temp.mails('a@t137.example') = 1, 'F10: uusi ajo: B:n tarjous voimassa, A ei palaa jonoon');
  -- Asetus vaikuttaa myös claimiin: 180 min → A:n 121 min vanha tarjous on taas voimassa
  insert into booking.settings(key, value) values ('waitlist_offer_minutes', '180'::jsonb) on conflict (key) do update set value = excluded.value;
  c := pg_temp.claim(ja ->> 'token');
  perform pg_temp.ck((c ->> 'ok')::boolean, 'F11: asetus 180 min → 121 min vanha tarjous lunastettavissa');
  delete from booking.settings where key = 'waitlist_offer_minutes';
  perform pg_temp.age('b@t137.example', interval '119 minutes');
  c := pg_temp.claim(jb ->> 'token');
  perform pg_temp.ck((c ->> 'ok')::boolean and (c ->> 'persons')::int = 4, 'F12: B lunastaa 119 min kohdalla');
  perform pg_temp.age('b@t137.example', interval '121 minutes');
  c := pg_temp.claim(jb ->> 'token');
  perform pg_temp.ck(c ->> 'code' = 'offer_expired', 'F13: B 121 min → offer_expired');
  -- Odottava (ei ilmoitettu) jonovaraus ei vanhene tarjousajan mukaan
  update booking.waitlist_entries set status = 'waiting', notified_at = null where customer_email = 'b@t137.example';
  c := pg_temp.claim(jb ->> 'token');
  perform pg_temp.ck((c ->> 'ok')::boolean, 'F14: waiting-tila → ei offer_expired');

  -- ===== Claim samana päivänä alkavalle vuorolle (vuoron alku siirretään tämän Helsingin päivän loppuun) =====
  v_today_end := ((now() at time zone 'Europe/Helsinki')::date + 1)::timestamp at time zone 'Europe/Helsinki' - interval '1 second';
  if test.hel_date(now() - interval '31 minutes') = test.hel_date(now()) and v_today_end > now() then
    update booking.waitlist_entries set status = 'notified', notified_at = now() - interval '31 minutes', starts_at = v_today_end
     where customer_email = 'b@t137.example';
    c := pg_temp.claim(jb ->> 'token');
    perform pg_temp.ck(c ->> 'code' = 'offer_expired', 'G1: sama päivä, 31 min → offer_expired');
    update booking.waitlist_entries set notified_at = now() - interval '29 minutes' where customer_email = 'b@t137.example';
    c := pg_temp.claim(jb ->> 'token');
    perform pg_temp.ck((c ->> 'ok')::boolean, 'G2: sama päivä, 29 min → lunastettavissa');
  else
    perform pg_temp.ck(true, 'G1: ohitettu (klo 00:00–00:31 Helsinki, sama päivä ei mahdollinen)');
    perform pg_temp.ck(true, 'G2: ohitettu');
  end if;

  perform pg_temp.ck(not has_function_privilege('anon', 'booking._waitlist_offer_expires_at(timestamptz,timestamptz)', 'execute'), 'H1: apufunktio ei anonille');
  perform pg_temp.ck(not has_function_privilege('authenticated', 'booking._waitlist_offer_expires_at(timestamptz,timestamptz)', 'execute'), 'H2: apufunktio ei authenticatedille');
  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_waitlist_claim(uuid)', 'execute'), 'H3: anon saa lunastaa');
  perform pg_temp.ck((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'booking._waitlist_offer_expires_at(timestamptz,timestamptz)'::regprocedure), 'H4: security definer, search_path tyhjä');

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t137_r where ok), (select count(*) from t137_r where not ok),
    coalesce((select string_agg(label, ' | ') from t137_r where not ok), 'ALL OK');
end $t$;
