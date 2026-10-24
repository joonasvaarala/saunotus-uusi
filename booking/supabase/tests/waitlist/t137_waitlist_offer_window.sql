-- t137: jonotuslistan pito ja tarjousaika (booking_137, Joonaksen päätös t161u).
-- Vuoroon ≥ waitlist_hold_min_hours_before (48) h ilmoitushetkellä → ensimmäinen mahtuva saa ilmoituksen ja pidon
-- waitlist_offer_minutes (120) min; alle 48 h → ei pitoa, ilmoitus kaikille mahtuville. Vanhentunut pito → offer_expired.
-- Kiinteät rajat (47 h / 49 h / 48 h, 119 / 121 min) testataan booking._waitlist_offer_expires_at-funktiolla kiinteillä
-- aikaleimoilla (now() on transaktiossa vakio). Kokonaisuudessa vuorot ovat viikkojen päässä, joten "47 h" ja "49 h"
-- simuloidaan asettamalla waitlist_hold_min_hours_before = vuoron etäisyys tunteina ±1 (vuoro 0–1 h rajan alla / 1–2 h yli).
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
create function pg_temp.valid(p_n timestamptz, p_s timestamptz, p_after interval) returns boolean language sql as $$
  select coalesce(booking._waitlist_offer_expires_at(p_n, p_s) > p_n + p_after, false) $$;
create function pg_temp.mins(p_n timestamptz, p_s timestamptz) returns numeric language sql as $$
  select extract(epoch from booking._waitlist_offer_expires_at(p_n, p_s) - p_n) / 60 $$;
create function pg_temp.claim(p_token text) returns jsonb language plpgsql as $$
declare c jsonb; begin perform test.anon(); c := booking.public_waitlist_claim(p_token::uuid); perform test.logout(); return c; end $$;
create function pg_temp.join(p_rule bigint, p_date date, p_persons int, p_email text) returns jsonb language plpgsql as $$
declare j jsonb; begin perform test.anon(); j := booking.public_join_waitlist(p_rule, p_date, p_persons, 'Jono ' || p_email, p_email); perform test.logout(); return j; end $$;
-- Vuoron etäisyys kokonaisina tunteina (alaspäin) ja pitorajan asetus
create function pg_temp.hrs(p_rule bigint, p_date date) returns int language sql as $$
  select floor(extract(epoch from s.starts_at - now()) / 3600)::int from booking._sessions(p_date, p_date, null, true) s where s.rule_id = p_rule limit 1 $$;
create function pg_temp.hold_hours(p_h int) returns void language sql as $$
  insert into booking.settings(key, value) values ('waitlist_hold_min_hours_before', to_jsonb(p_h)) on conflict (key) do update set value = excluded.value $$;
do $t$
declare
  v_rule bigint := test.rule('Miesten sauna%');
  d1 date := test.next_dow(1) + 35; d2 date := test.next_dow(1) + 42; d3 date := test.next_dow(1) + 49;
  n0 timestamptz := '2026-11-10 10:00 Europe/Helsinki';
  b jsonb; ja jsonb; jb jsonb; jc jsonb; jd jsonb; jp jsonb; jq jsonb; jr jsonb; jx jsonb; jy jsonb; jz jsonb; c jsonb; n int;
  v_space bigint; v_s timestamptz; v_e timestamptz;
begin
  -- ===== Asetukset: migraatio lisää oletusrivit =====
  perform pg_temp.ck((select value from booking.settings where key = 'waitlist_offer_minutes') = '120'::jsonb, 'A1: waitlist_offer_minutes = 120');
  perform pg_temp.ck((select value from booking.settings where key = 'waitlist_hold_min_hours_before') = '48'::jsonb, 'A2: waitlist_hold_min_hours_before = 48');
  perform pg_temp.ck(not exists (select 1 from booking.settings where key = 'waitlist_offer_minutes_same_day'), 'A3: waitlist_offer_minutes_same_day ei käytössä');

  -- ===== Rajat kiinteillä aikaleimoilla (oletus 48 h / 120 min) =====
  perform pg_temp.ck(booking._waitlist_offer_expires_at(n0, n0 + interval '47 hours') is null, 'B1: vuoro 47 h päässä → ei pitoa');
  perform pg_temp.ck(pg_temp.mins(n0, n0 + interval '49 hours') = 120, 'B2: vuoro 49 h päässä → pito 120 min');
  perform pg_temp.ck(pg_temp.valid(n0, n0 + interval '49 hours', interval '119 minutes'), 'B3: 49 h, 119 min → pito voimassa');
  perform pg_temp.ck(not pg_temp.valid(n0, n0 + interval '49 hours', interval '121 minutes'), 'B4: 49 h, 121 min → pito vanhentunut');
  perform pg_temp.ck(not pg_temp.valid(n0, n0 + interval '49 hours', interval '120 minutes'), 'B5: täsmälleen 120 min → vanhentunut');
  perform pg_temp.ck(pg_temp.mins(n0, n0 + interval '48 hours') = 120, 'B6: täsmälleen 48 h → pito');
  perform pg_temp.ck(booking._waitlist_offer_expires_at(n0, n0 + interval '47 hours 59 minutes') is null, 'B7: 47 h 59 min → ei pitoa');
  perform pg_temp.ck(pg_temp.mins('2026-10-23 10:00 Europe/Helsinki', '2026-10-25 10:00 Europe/Helsinki') = 120, 'B8: kesäajan päättyminen välissä (49 todellista tuntia) → pito');
  perform pg_temp.ck(booking._waitlist_offer_expires_at(null, n0) is null and booking._waitlist_offer_expires_at(n0, null) is null, 'B9: null → null');

  -- ===== Asetusarvot =====
  update booking.settings set value = '24'::jsonb where key = 'waitlist_hold_min_hours_before';
  update booking.settings set value = '90'::jsonb where key = 'waitlist_offer_minutes';
  perform pg_temp.ck(pg_temp.mins(n0, n0 + interval '25 hours') = 90 and booking._waitlist_offer_expires_at(n0, n0 + interval '23 hours') is null, 'C1: asetukset 24 h / 90 min käytössä');
  update booking.settings set value = '"36"'::jsonb where key = 'waitlist_hold_min_hours_before';
  perform pg_temp.ck(pg_temp.mins(n0, n0 + interval '37 hours') = 90, 'C2: merkkijono "36" hyväksytään');
  update booking.settings set value = '"ei-numero"'::jsonb where key = 'waitlist_hold_min_hours_before';
  update booking.settings set value = '0'::jsonb where key = 'waitlist_offer_minutes';
  perform pg_temp.ck(booking._waitlist_offer_expires_at(n0, n0 + interval '47 hours') is null and pg_temp.mins(n0, n0 + interval '49 hours') = 120, 'C3: ei-numero ja 0 → oletukset 48 h / 120 min');
  update booking.settings set value = '-5'::jsonb where key = 'waitlist_hold_min_hours_before';
  update booking.settings set value = '1.5'::jsonb where key = 'waitlist_offer_minutes';
  perform pg_temp.ck(booking._waitlist_offer_expires_at(n0, n0 + interval '47 hours') is null and pg_temp.mins(n0, n0 + interval '49 hours') = 120, 'C4: negatiivinen ja desimaali → oletukset');
  update booking.settings set value = '9999999'::jsonb where key = 'waitlist_offer_minutes';
  perform pg_temp.ck(pg_temp.mins(n0, n0 + interval '49 hours') = 120, 'C5: liian suuri → oletus, ei ylivuotoa');
  update booking.settings set value = '0'::jsonb where key = 'waitlist_hold_min_hours_before';
  perform pg_temp.ck(pg_temp.mins(n0, n0 + interval '1 hour') = 120, 'C6: raja 0 h → aina pito');
  delete from booking.settings where key in ('waitlist_hold_min_hours_before', 'waitlist_offer_minutes');
  perform pg_temp.ck(booking._waitlist_offer_expires_at(n0, n0 + interval '47 hours') is null and pg_temp.mins(n0, n0 + interval '49 hours') = 120, 'C7: puuttuvat rivit → oletukset');

  -- ===== "47 h": ei pitoa, kaikki mahtuvat saavat ilmoituksen (vuoro d1) =====
  b := test.pub_book(v_rule, d1, 12, 'iso1@t137.example');  perform pg_temp.ck((b ->> 'ok')::boolean, 'D1: 12 hlöä');
  b := test.pub_book(v_rule, d1, 4, 'nelja1@t137.example'); perform pg_temp.ck((b ->> 'ok')::boolean, 'D2: 4 hlöä (vuoro täynnä)');
  ja := pg_temp.join(v_rule, d1, 4, 'a@t137.example'); jb := pg_temp.join(v_rule, d1, 3, 'b@t137.example');
  jc := pg_temp.join(v_rule, d1, 5, 'c@t137.example'); jd := pg_temp.join(v_rule, d1, 2, 'd@t137.example');
  perform pg_temp.ck((ja ->> 'ok')::boolean and (jb ->> 'ok')::boolean and (jc ->> 'ok')::boolean and (jd ->> 'ok')::boolean, 'D3: A4, B3, C5, D2 jonoon');
  perform pg_temp.hold_hours(pg_temp.hrs(v_rule, d1) + 1);   -- vuoro 0–1 h alle pitorajan
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('nelja1@t137.example');
  perform pg_temp.ck(pg_temp.st('a@t137.example') = 'notified' and pg_temp.st('b@t137.example') = 'notified' and pg_temp.st('d@t137.example') = 'notified',
    'D4: alle 48 h: kaikki mahtuvat (A4, B3, D2 ≤ 4 vapaata) saavat ilmoituksen');
  perform pg_temp.ck(pg_temp.st('c@t137.example') = 'waiting' and pg_temp.mails('c@t137.example') = 0, 'D5: isompi C5 ei mahdu → ei ilmoitusta');
  perform pg_temp.ck(pg_temp.mails('a@t137.example') = 1 and pg_temp.mails('b@t137.example') = 1 and pg_temp.mails('d@t137.example') = 1, 'D6: yksi sähköposti kullekin');
  perform pg_temp.ck((select bool_and(booking._waitlist_offer_expires_at(notified_at, starts_at) is null) from booking.waitlist_entries where customer_email in ('a@t137.example','b@t137.example','d@t137.example')),
    'D7: ilmoitukset eivät ole pidossa');
  select space_id, starts_at, ends_at into v_space, v_s, v_e from booking.waitlist_entries where customer_email = 'a@t137.example';
  n := booking._notify_waitlist_for_window(v_space, v_s, v_e);
  perform pg_temp.ck(n = 0 and pg_temp.mails('a@t137.example') = 1 and pg_temp.mails('b@t137.example') = 1 and pg_temp.mails('d@t137.example') = 1, 'D8: uusi ajo → ei uusia ilmoituksia samoille (idempotenssi)');
  -- 3 h vanha ilmoitus: raja siirretään +5 h, jotta ilmoitushetkelläkin vuoroon oli rajaa vähemmän (ei pitoa).
  perform pg_temp.hold_hours(pg_temp.hrs(v_rule, d1) + 5);
  perform pg_temp.age('a@t137.example', interval '3 hours');
  c := pg_temp.claim(ja ->> 'token');
  perform pg_temp.ck((c ->> 'ok')::boolean and (c ->> 'enough')::boolean, 'D9: ilman pitoa ei offer_expired (3 h vanha ilmoitus) → lunastus, paikat riittävät');
  b := test.pub_book(v_rule, d1, 3, 'nopea1@t137.example'); perform pg_temp.ck((b ->> 'ok')::boolean, 'D10: paikka myynnissä: muu asiakas varaa 3 / 4 vapaasta');
  c := pg_temp.claim(jb ->> 'token');
  perform pg_temp.ck((c ->> 'ok')::boolean and not (c ->> 'enough')::boolean and pg_temp.st('b@t137.example') = 'waiting', 'D11: B3: paikat eivät enää riitä → enough=false (not_enough), takaisin jonoon');
  c := pg_temp.claim(jd ->> 'token');
  perform pg_temp.ck((c ->> 'ok')::boolean and not (c ->> 'enough')::boolean, 'D12: D2: 1 vapaa → ei riitä');

  -- ===== "49 h": pito, vain ensimmäinen mahtuva saa ilmoituksen; 119 / 121 min (vuoro d2) =====
  b := test.pub_book(v_rule, d2, 12, 'iso2@t137.example');  perform pg_temp.ck((b ->> 'ok')::boolean, 'E1: 12 hlöä');
  b := test.pub_book(v_rule, d2, 4, 'nelja2@t137.example'); perform pg_temp.ck((b ->> 'ok')::boolean, 'E2: 4 hlöä (vuoro täynnä)');
  jr := pg_temp.join(v_rule, d2, 5, 'r@t137.example');
  jp := pg_temp.join(v_rule, d2, 4, 'p@t137.example'); jq := pg_temp.join(v_rule, d2, 3, 'q@t137.example');
  perform pg_temp.hold_hours(pg_temp.hrs(v_rule, d2) - 1);   -- vuoro 1–2 h yli pitorajan
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('nelja2@t137.example');
  perform pg_temp.ck(pg_temp.st('p@t137.example') = 'notified' and pg_temp.st('q@t137.example') = 'waiting' and pg_temp.mails('q@t137.example') = 0,
    'E3: yli 48 h: vain ensimmäinen mahtuva P4 saa ilmoituksen, Q ei');
  perform pg_temp.ck(pg_temp.st('r@t137.example') = 'waiting' and pg_temp.mails('r@t137.example') = 0, 'E4: isompi R5 (jonossa ensin) ei mahdu → ei ilmoitusta');
  perform pg_temp.ck((select booking._waitlist_offer_expires_at(notified_at, starts_at) = notified_at + interval '120 minutes' from booking.waitlist_entries where customer_email = 'p@t137.example'), 'E5: P:n pito 120 min');
  select space_id, starts_at, ends_at into v_space, v_s, v_e from booking.waitlist_entries where customer_email = 'p@t137.example';
  perform pg_temp.age('p@t137.example', interval '119 minutes');
  n := booking._notify_waitlist_for_window(v_space, v_s, v_e);
  perform pg_temp.ck(n = 0 and pg_temp.st('q@t137.example') = 'waiting', 'E6: 119 min → pito voimassa, Q ei saa paikkoja');
  c := pg_temp.claim(jp ->> 'token');
  perform pg_temp.ck((c ->> 'ok')::boolean and (c ->> 'enough')::boolean, 'E7: P lunastaa 119 min kohdalla');
  perform pg_temp.age('p@t137.example', interval '121 minutes');
  c := pg_temp.claim(jp ->> 'token');
  perform pg_temp.ck(c ->> 'code' = 'offer_expired' and not (c ->> 'ok')::boolean and pg_temp.st('p@t137.example') = 'notified', 'E8: 121 min → offer_expired, tila ennallaan');
  n := booking._notify_waitlist_for_window(v_space, v_s, v_e);
  perform pg_temp.ck(n = 1 and pg_temp.st('q@t137.example') = 'notified' and pg_temp.mails('q@t137.example') = 1, 'E9: pito vanheni (vuoroon yhä yli 48 h) → seuraava mahtuva Q saa ilmoituksen');
  perform pg_temp.ck(pg_temp.st('r@t137.example') = 'waiting' and pg_temp.mails('p@t137.example') = 1, 'E10: R ei, P ei saa uutta ilmoitusta');
  n := booking._notify_waitlist_for_window(v_space, v_s, v_e);
  perform pg_temp.ck(n = 0, 'E11: Q:n pito voimassa → ei muita');

  -- ===== Pito vanhenee, kun vuoroon on alle 48 h → kaikki mahtuvat saavat ilmoituksen (vuoro d3) =====
  b := test.pub_book(v_rule, d3, 12, 'iso3@t137.example');  perform pg_temp.ck((b ->> 'ok')::boolean, 'F1: 12 hlöä');
  b := test.pub_book(v_rule, d3, 4, 'nelja3@t137.example'); perform pg_temp.ck((b ->> 'ok')::boolean, 'F2: 4 hlöä (vuoro täynnä)');
  jx := pg_temp.join(v_rule, d3, 4, 'x@t137.example'); jy := pg_temp.join(v_rule, d3, 2, 'y@t137.example');
  jz := pg_temp.join(v_rule, d3, 3, 'z@t137.example');
  perform pg_temp.hold_hours(pg_temp.hrs(v_rule, d3) - 1);
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('nelja3@t137.example');
  perform pg_temp.ck(pg_temp.st('x@t137.example') = 'notified' and pg_temp.st('y@t137.example') = 'waiting' and pg_temp.st('z@t137.example') = 'waiting', 'F3: yli 48 h: X4 pidossa, Y ja Z odottavat');
  select space_id, starts_at, ends_at into v_space, v_s, v_e from booking.waitlist_entries where customer_email = 'x@t137.example';
  -- Vanhenemishetkellä vuoroon alle 48 h: X:n pito alkoi ilmoitushetkellä yli rajan (starts - notified ≥ raja), mutta
  -- nyt vuoroon on rajaa vähemmän → uudet ilmoitukset ilman pitoa.
  perform pg_temp.age('x@t137.example', interval '121 minutes');
  perform pg_temp.hold_hours(pg_temp.hrs(v_rule, d3) + 1);
  perform pg_temp.ck((select booking._waitlist_offer_expires_at(notified_at, starts_at) is not null from booking.waitlist_entries where customer_email = 'x@t137.example'), 'F4: X oli pidossa (ilmoitettu yli rajan ennen vuoroa)');
  n := booking._notify_waitlist_for_window(v_space, v_s, v_e);
  perform pg_temp.ck(n = 2 and pg_temp.st('y@t137.example') = 'notified' and pg_temp.st('z@t137.example') = 'notified', 'F5: X:n pito vanheni alle 48 h ennen vuoroa → Y2 ja Z3 molemmat saavat ilmoituksen');
  perform pg_temp.ck(pg_temp.mails('x@t137.example') = 1 and pg_temp.mails('y@t137.example') = 1 and pg_temp.mails('z@t137.example') = 1, 'F6: yksi ilmoitus kullekin');
  c := pg_temp.claim(jx ->> 'token');
  perform pg_temp.ck(c ->> 'code' = 'offer_expired', 'F7: X:n vanhentunut pito → offer_expired');
  c := pg_temp.claim(jz ->> 'token');
  perform pg_temp.ck((c ->> 'ok')::boolean and (c ->> 'enough')::boolean, 'F8: Z lunastaa (ei pitoa, paikat riittävät)');
  -- Voimassa oleva pito kunnioitetaan loppuun myös alle 48 h:n ajossa: X ilmoitettiin 60 min sitten, jolloin vuoroon oli
  -- vielä rajaa enemmän (H + 1 h ≥ raja), mutta nyt vuoroon on rajaa vähemmän (H < raja).
  update booking.waitlist_entries set status = 'waiting', notified_at = null where customer_email in ('y@t137.example', 'z@t137.example');
  update booking.waitlist_entries set status = 'notified' where customer_email = 'x@t137.example';
  perform pg_temp.age('x@t137.example', interval '60 minutes');
  perform pg_temp.ck((select booking._waitlist_offer_expires_at(notified_at, starts_at) > now() from booking.waitlist_entries where customer_email = 'x@t137.example'), 'F9: X:n pito voimassa (ilmoitettu yli rajan ennen vuoroa, 60 min sitten)');
  n := booking._notify_waitlist_for_window(v_space, v_s, v_e);
  perform pg_temp.ck(n = 0 and pg_temp.st('y@t137.example') = 'waiting' and pg_temp.st('z@t137.example') = 'waiting', 'F10: alle 48 h:n ajo kunnioittaa voimassa olevaa pitoa (4 − 4 = 0 vapaata)');
  perform pg_temp.age('x@t137.example', interval '121 minutes');
  n := booking._notify_waitlist_for_window(v_space, v_s, v_e);
  perform pg_temp.ck(n = 2, 'F11: pito vanheni → Y ja Z saavat ilmoituksen');

  perform pg_temp.ck(not has_function_privilege('anon', 'booking._waitlist_offer_expires_at(timestamptz,timestamptz)', 'execute'), 'H1: apufunktio ei anonille');
  perform pg_temp.ck(not has_function_privilege('authenticated', 'booking._waitlist_offer_expires_at(timestamptz,timestamptz)', 'execute'), 'H2: apufunktio ei authenticatedille');
  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_waitlist_claim(uuid)', 'execute'), 'H3: anon saa lunastaa');
  perform pg_temp.ck((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'booking._waitlist_offer_expires_at(timestamptz,timestamptz)'::regprocedure), 'H4: security definer, search_path tyhjä');

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t137_r where ok), (select count(*) from t137_r where not ok),
    coalesce((select string_agg(label, ' | ') from t137_r where not ok), 'ALL OK');
end $t$;
