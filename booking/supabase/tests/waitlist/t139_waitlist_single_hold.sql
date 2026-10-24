-- t139: jonotuslistan pito vain yhdelle kerrallaan per vuoro (booking_139, omistajan päätös).
-- a) vuoroon ≥ 48 h: vain ensimmäinen mahtuva saa pidon, muut eivät saa mitään pidon aikana
-- b) pito vanhenee: ei uutta pitoa, kaikki mahtuvat saavat ilmoituksen kerran, vanhentuneen pidon haltija voi varata
-- c) alle 48 h: ilmoitus kaikille mahtuville, ei pitoa, paikka myynnissä
-- d) uusi vapautuminen (vapaa kapasiteetti > offered_free): yksi uusi pito seuraavalle, jolla ei ole ollut pitoa;
--    pidon aikana vapautuneet paikat käsitellään pidon jälkeen; pidot eivät kasaudu
-- e) ei tuplailmoituksia (#126 / booking_135)
-- "≥ 48 h" ja "< 48 h" simuloidaan asetuksella waitlist_hold_min_hours_before (vuorot ovat viikkojen päässä), kuten t137.
-- Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN (mock-data: Miesten sauna ma, kapasiteetti 16).
-- Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken. Tulos: TESTRESULT pass=… fail=…
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t139_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t139_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.st(p_email text) returns text language sql as $$ select status from booking.waitlist_entries where customer_email = p_email $$;
create function pg_temp.held(p_email text) returns boolean language sql as $$
  select status = 'notified' and coalesce(hold_expires_at > now(), false) from booking.waitlist_entries where customer_email = p_email $$;
create function pg_temp.had_hold(p_email text) returns boolean language sql as $$
  select hold_expires_at is not null from booking.waitlist_entries where customer_email = p_email $$;
create function pg_temp.rid(p_email text) returns bigint language sql as $$
  select r.id from booking.reservations r join booking.orders o on o.id = r.order_id join booking.customers c on c.id = o.customer_id where c.email = p_email order by r.id limit 1 $$;
create function pg_temp.mails(p_email text) returns int language sql as $$
  select count(*)::int from booking.email_outbox where kind = 'waitlist_spot_freed' and payload ->> 'to_email' = p_email $$;
create function pg_temp.mails_like(p_like text) returns int language sql as $$
  select count(*)::int from booking.email_outbox where kind = 'waitlist_spot_freed' and payload ->> 'to_email' like p_like $$;
create function pg_temp.dups() returns int language sql as $$
  select count(*)::int from (select payload ->> 'to_email' e, payload ->> 'starts_at' s from booking.email_outbox
    where kind = 'waitlist_spot_freed' group by 1, 2 having count(*) > 1) x $$;
create function pg_temp.active_holds(p_rule bigint, p_date date) returns int language sql as $$
  select count(*)::int from booking.waitlist_entries where rule_id = p_rule and session_date = p_date and status = 'notified' and hold_expires_at > now() $$;
create function pg_temp.expire(p_email text) returns void language sql as $$
  update booking.waitlist_entries set notified_at = now() - interval '121 minutes', hold_expires_at = now() - interval '1 minute' where customer_email = p_email $$;
create function pg_temp.offered(p_rule bigint, p_date date) returns int language sql as $$
  select offered_free from booking.waitlist_session_state where rule_id = p_rule and session_date = p_date $$;
create function pg_temp.claim(p_token text) returns jsonb language plpgsql as $$
declare c jsonb; begin perform test.anon(); c := booking.public_waitlist_claim(p_token::uuid); perform test.logout(); return c; end $$;
create function pg_temp.join(p_rule bigint, p_date date, p_persons int, p_email text) returns jsonb language plpgsql as $$
declare j jsonb; begin perform test.anon(); j := booking.public_join_waitlist(p_rule, p_date, p_persons, 'Jono ' || p_email, p_email); perform test.logout(); return j; end $$;
create function pg_temp.hrs(p_rule bigint, p_date date) returns int language sql as $$
  select floor(extract(epoch from s.starts_at - now()) / 3600)::int from booking._sessions(p_date, p_date, null, true) s where s.rule_id = p_rule limit 1 $$;
create function pg_temp.hold_hours(p_h int) returns void language sql as $$
  insert into booking.settings(key, value) values ('waitlist_hold_min_hours_before', to_jsonb(p_h)) on conflict (key) do update set value = excluded.value $$;
do $t$
declare
  v_rule bigint := test.rule('Miesten sauna%');
  d1 date := test.next_dow(1) + 56; d2 date := test.next_dow(1) + 63; d3 date := test.next_dow(1) + 70; d4 date := test.next_dow(1) + 77;
  b jsonb; ja jsonb; jb jsonb; jc jsonb; jd jsonb; jp jsonb; jq jsonb; jr jsonb; js jsonb; c jsonb; n int; m int;
  v_space bigint; v_s timestamptz; v_e timestamptz;
begin
  perform booking.public_join_waitlist(v_rule, d1, 1, 'x', 'x');   -- lämmittely: rate limit -avain ei kaada

  -- ===== a) ≥ 48 h: tuotannon tapaus A5, B1, C4, D3, vapautuu 4 → vain B pitoon =====
  b := test.pub_book(v_rule, d1, 12, 'iso1@t139.example');  perform pg_temp.ck((b ->> 'ok')::boolean, 'A1: 12 hlöä');
  b := test.pub_book(v_rule, d1, 4, 'nelja1@t139.example'); perform pg_temp.ck((b ->> 'ok')::boolean, 'A2: 4 hlöä (vuoro täynnä)');
  ja := pg_temp.join(v_rule, d1, 5, 'a@t139.example'); jb := pg_temp.join(v_rule, d1, 1, 'b@t139.example');
  jc := pg_temp.join(v_rule, d1, 4, 'c@t139.example'); jd := pg_temp.join(v_rule, d1, 3, 'd@t139.example');
  perform pg_temp.ck((ja ->> 'ok')::boolean and (jb ->> 'ok')::boolean and (jc ->> 'ok')::boolean and (jd ->> 'ok')::boolean, 'A3: A5, B1, C4, D3 jonoon');
  perform pg_temp.hold_hours(pg_temp.hrs(v_rule, d1) - 1);   -- vuoroon yli pitorajan
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('nelja1@t139.example');
  perform pg_temp.ck(pg_temp.held('b@t139.example') and pg_temp.mails('b@t139.example') = 1, 'A4: ensimmäinen mahtuva B1 saa pidon ja yhden viestin');
  perform pg_temp.ck((select hold_expires_at = notified_at + interval '120 minutes' from booking.waitlist_entries where customer_email = 'b@t139.example'), 'A5: pito 120 min');
  perform pg_temp.ck(pg_temp.st('a@t139.example') = 'waiting' and pg_temp.st('c@t139.example') = 'waiting' and pg_temp.st('d@t139.example') = 'waiting', 'A6: A, C ja D odottavat (D ei saa toista pitoa)');
  perform pg_temp.ck(pg_temp.mails('a@t139.example') + pg_temp.mails('c@t139.example') + pg_temp.mails('d@t139.example') = 0, 'A7: muut eivät saa viestiä pidon aikana');
  perform pg_temp.ck(pg_temp.active_holds(v_rule, d1) = 1, 'A8: yksi aktiivinen pito vuorossa');
  perform pg_temp.ck(pg_temp.offered(v_rule, d1) = 4, 'A9: offered_free = 4 (vapaa kapasiteetti tallennettu)');
  select space_id, starts_at, ends_at into v_space, v_s, v_e from booking.waitlist_entries where customer_email = 'b@t139.example';
  n := booking._notify_waitlist_for_window(v_space, v_s, v_e); m := booking.waitlist_sweep();
  perform pg_temp.ck(n = 0 and m = 0 and pg_temp.st('c@t139.example') = 'waiting' and pg_temp.st('d@t139.example') = 'waiting', 'A10: uudet ajot ja sweep pidon aikana → ei mitään');
  update booking.waitlist_entries set hold_expires_at = now() + interval '1 minute', notified_at = now() - interval '119 minutes' where customer_email = 'b@t139.example';
  m := booking.waitlist_sweep();
  perform pg_temp.ck(m = 0 and pg_temp.held('b@t139.example'), 'A11: 119 min → pito yhä voimassa');
  c := pg_temp.claim(jb ->> 'token');
  perform pg_temp.ck((c ->> 'ok')::boolean and (c ->> 'enough')::boolean and not (c ->> 'hold_expired')::boolean, 'A12: pidon haltija lunastaa');

  -- ===== b) pito vanhenee: ei uutta pitoa, ilmoitus kaikille mahtuville kerran, haltija voi varata =====
  perform pg_temp.expire('b@t139.example');
  m := booking.waitlist_sweep();
  perform pg_temp.ck(m = 2 and pg_temp.st('c@t139.example') = 'notified' and pg_temp.st('d@t139.example') = 'notified', 'B1: sweep: C4 ja D3 saavat ilmoituksen');
  perform pg_temp.ck(not pg_temp.had_hold('c@t139.example') and not pg_temp.had_hold('d@t139.example') and pg_temp.active_holds(v_rule, d1) = 0, 'B2: ei uutta pitoa');
  perform pg_temp.ck(pg_temp.st('a@t139.example') = 'waiting' and pg_temp.mails('a@t139.example') = 0, 'B3: A5 ei mahdu');
  perform pg_temp.ck(pg_temp.mails('b@t139.example') = 1 and pg_temp.mails('c@t139.example') = 1 and pg_temp.mails('d@t139.example') = 1, 'B4: kukin yhden viestin');
  m := booking.waitlist_sweep(); n := booking._notify_waitlist_for_window(v_space, v_s, v_e);
  perform pg_temp.ck(m = 0 and n = 0 and pg_temp.mails_like('%@t139.example') = 3, 'B5: uusi sweep/ajo → ei uusia viestejä');
  c := pg_temp.claim(jb ->> 'token');
  perform pg_temp.ck((c ->> 'ok')::boolean and (c ->> 'enough')::boolean and (c ->> 'hold_expired')::boolean and c ->> 'code' is null, 'B6: vanhentunut pito → lunastus ok (hold_expired), ei offer_expired');
  b := test.pub_book(v_rule, d1, 1, 'b@t139.example');
  perform pg_temp.ck((b ->> 'ok')::boolean, 'B7: vanhentuneen pidon haltija varaa normaalisti');
  set constraints all immediate;   -- _waitlist_booked_trg on deferrable initially deferred
  perform pg_temp.ck(pg_temp.st('b@t139.example') = 'booked', 'B8: jonovaraus → booked');
  set constraints all deferred;
  c := pg_temp.claim(jd ->> 'token');
  perform pg_temp.ck((c ->> 'ok')::boolean and (c ->> 'enough')::boolean and not (c ->> 'hold_expired')::boolean, 'B9: D3 (ilmoitus ilman pitoa) lunastaa, 3 vapaata riittää');
  b := test.pub_book(v_rule, d1, 3, 'muu1@t139.example');
  perform pg_temp.ck((b ->> 'ok')::boolean, 'B10: paikka on vapaasti myynnissä: muu asiakas varaa');

  -- ===== c) alle 48 h: kaikille mahtuville ilmoitus, ei pitoa =====
  b := test.pub_book(v_rule, d2, 12, 'iso2@t139.example');  perform pg_temp.ck((b ->> 'ok')::boolean, 'C1: 12 hlöä');
  b := test.pub_book(v_rule, d2, 4, 'nelja2@t139.example'); perform pg_temp.ck((b ->> 'ok')::boolean, 'C2: 4 hlöä (täynnä)');
  jp := pg_temp.join(v_rule, d2, 5, 'p@t139.example'); jq := pg_temp.join(v_rule, d2, 1, 'q@t139.example');
  jr := pg_temp.join(v_rule, d2, 4, 'r@t139.example'); js := pg_temp.join(v_rule, d2, 3, 's@t139.example');
  perform pg_temp.hold_hours(pg_temp.hrs(v_rule, d2) + 1);   -- vuoroon alle pitorajan
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('nelja2@t139.example');
  perform pg_temp.ck(pg_temp.st('q@t139.example') = 'notified' and pg_temp.st('r@t139.example') = 'notified' and pg_temp.st('s@t139.example') = 'notified', 'C3: kaikki mahtuvat Q1, R4, S3 saavat ilmoituksen');
  perform pg_temp.ck(pg_temp.st('p@t139.example') = 'waiting' and pg_temp.mails('p@t139.example') = 0, 'C4: P5 ei mahdu');
  perform pg_temp.ck(not pg_temp.had_hold('q@t139.example') and not pg_temp.had_hold('r@t139.example') and not pg_temp.had_hold('s@t139.example') and pg_temp.active_holds(v_rule, d2) = 0, 'C5: ei pitoa');
  perform pg_temp.ck(pg_temp.mails('q@t139.example') = 1 and pg_temp.mails('r@t139.example') = 1 and pg_temp.mails('s@t139.example') = 1, 'C6: yksi viesti kullekin');
  m := booking.waitlist_sweep();
  perform pg_temp.ck(m = 0 and pg_temp.mails_like('_@t139.example') = 3 + 3, 'C7: sweep ei lähetä uudelleen');
  b := test.pub_book(v_rule, d2, 4, 'nopea2@t139.example');
  perform pg_temp.ck((b ->> 'ok')::boolean, 'C8: paikka myynnissä: muu asiakas varaa kaikki 4');
  c := pg_temp.claim(jr ->> 'token');
  perform pg_temp.ck((c ->> 'ok')::boolean and not (c ->> 'enough')::boolean and pg_temp.st('r@t139.example') = 'waiting', 'C9: R ei enää mahdu → takaisin jonoon');

  -- ===== d) uusi vapautuminen: yksi uusi pito seuraavalle, jolla ei ole ollut pitoa =====
  b := test.pub_book(v_rule, d3, 12, 'iso3@t139.example');  perform pg_temp.ck((b ->> 'ok')::boolean, 'D1: 12 hlöä');
  b := test.pub_book(v_rule, d3, 2, 'kaksi3a@t139.example'); b := test.pub_book(v_rule, d3, 2, 'kaksi3b@t139.example');
  perform pg_temp.ck((b ->> 'ok')::boolean, 'D2: 2 + 2 hlöä (täynnä)');
  jp := pg_temp.join(v_rule, d3, 2, 'w1@t139.example'); jq := pg_temp.join(v_rule, d3, 2, 'w2@t139.example');
  jr := pg_temp.join(v_rule, d3, 2, 'w3@t139.example'); js := pg_temp.join(v_rule, d3, 2, 'w4@t139.example');
  perform pg_temp.hold_hours(pg_temp.hrs(v_rule, d3) - 1);
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('kaksi3a@t139.example');
  perform pg_temp.ck(pg_temp.held('w1@t139.example') and pg_temp.st('w2@t139.example') = 'waiting', 'D3: 2 vapautuu → W1 pitoon, W2 odottaa');
  -- Uusi vapautuminen pidon aikana: ei toista pitoa eikä ilmoituksia (pidot eivät kasaudu).
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('kaksi3b@t139.example');
  perform pg_temp.ck(pg_temp.active_holds(v_rule, d3) = 1 and pg_temp.st('w2@t139.example') = 'waiting' and pg_temp.mails('w2@t139.example') = 0, 'D4: vapautuminen pidon aikana → ei toista pitoa, W2 ei saa viestiä');
  perform pg_temp.ck(pg_temp.offered(v_rule, d3) = 2, 'D5: pidon aikana offered_free ei kasva (2), vapautuminen odottaa');
  -- W1:n pito vanhenee → 4 vapaata > offered 2 → uusi vapautuminen → pito seuraavalle, jolla ei ole ollut pitoa (W2).
  perform pg_temp.expire('w1@t139.example');
  m := booking.waitlist_sweep();
  perform pg_temp.ck(m = 1 and pg_temp.held('w2@t139.example') and pg_temp.active_holds(v_rule, d3) = 1, 'D6: uusi vapautuminen → yksi pito W2:lle');
  perform pg_temp.ck(pg_temp.st('w3@t139.example') = 'waiting' and pg_temp.st('w4@t139.example') = 'waiting' and pg_temp.mails('w1@t139.example') = 1, 'D7: W3, W4 odottavat, W1 ei saa uutta viestiä');
  perform pg_temp.ck(pg_temp.offered(v_rule, d3) = 4, 'D8: offered_free = 4');
  -- W2 varaa pidon aikana → kapasiteetti laskee; sweep kirjaa laskun (offered 2), ei ilmoituksia.
  b := test.pub_book(v_rule, d3, 2, 'w2@t139.example'); perform pg_temp.ck((b ->> 'ok')::boolean, 'D9: W2 varaa');
  set constraints all immediate; set constraints all deferred;
  m := booking.waitlist_sweep();
  perform pg_temp.ck(pg_temp.st('w2@t139.example') = 'booked' and pg_temp.offered(v_rule, d3) = 2, 'D10: W2 booked, offered_free laski 2:een');
  -- 2 jäljellä, ei uutta vapautumista → kaikki mahtuvat (W3, W4) saavat ilmoituksen ilman pitoa.
  perform pg_temp.ck(m = 2 and pg_temp.st('w3@t139.example') = 'notified' and pg_temp.st('w4@t139.example') = 'notified'
    and not pg_temp.had_hold('w3@t139.example') and not pg_temp.had_hold('w4@t139.example'), 'D11: jäljelle jääneet 2 paikkaa → W3 ja W4 ilman pitoa');
  -- Joku varaa ne 2, sweep kirjaa 0; uusi vapautuminen (2) → ei waiting-jonottajia → ei mitään.
  b := test.pub_book(v_rule, d3, 2, 'muu3@t139.example'); m := booking.waitlist_sweep();
  perform pg_temp.ck((b ->> 'ok')::boolean and pg_temp.offered(v_rule, d3) = 0, 'D12: varattu täyteen, offered_free 0');
  -- W3 palaa jonoon (lunastus ei riitä), sitten uusi vapautuminen: W3:lla ei ole ollut pitoa → pito W3:lle.
  c := pg_temp.claim(jr ->> 'token');
  perform pg_temp.ck(not (c ->> 'enough')::boolean and pg_temp.st('w3@t139.example') = 'waiting', 'D13: W3 takaisin jonoon');
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('muu3@t139.example');
  perform pg_temp.ck(pg_temp.held('w3@t139.example') and pg_temp.mails('w3@t139.example') = 2, 'D14: uusi vapautuminen → pito W3:lle (uusi ilmoitus uudesta vapautumisesta)');
  -- Uusi vapautuminen, kun mahtuvilla jonottajilla on kaikilla jo ollut pito → ei pitoa, ilmoitus kaikille mahtuville.
  -- Pidon aikana pidetyt 2 paikkaa eivät ole myynnissä; vanhenemisen jälkeen ne myydään.
  b := test.pub_book(v_rule, d3, 1, 'muu4@t139.example');
  perform pg_temp.ck(not (b ->> 'ok')::boolean and b ->> 'code' = 'capacity_exceeded', 'D15a: W3:n pidon aikana viimeisiä pidettyjä paikkoja ei voi varata');
  perform pg_temp.expire('w3@t139.example');
  b := test.pub_book(v_rule, d3, 2, 'muu4@t139.example'); m := booking.waitlist_sweep();
  perform pg_temp.ck((b ->> 'ok')::boolean and pg_temp.offered(v_rule, d3) = 0, 'D15: pito vanheni → paikat myynnissä, varattu täyteen (offered_free 0)');
  c := pg_temp.claim(jp ->> 'token');
  perform pg_temp.ck(not (c ->> 'enough')::boolean and pg_temp.st('w1@t139.example') = 'waiting', 'D16: W1 (vanhentunut pito) takaisin jonoon');
  c := pg_temp.claim(jr ->> 'token');
  perform pg_temp.ck(not (c ->> 'enough')::boolean and (c ->> 'hold_expired')::boolean and pg_temp.st('w3@t139.example') = 'waiting', 'D17: W3 (vanhentunut pito) takaisin jonoon');
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('muu4@t139.example');
  perform pg_temp.ck(pg_temp.active_holds(v_rule, d3) = 0 and pg_temp.st('w1@t139.example') = 'notified' and pg_temp.st('w3@t139.example') = 'notified', 'D18: uusi vapautuminen, kaikilla jo ollut pito → ilmoitus kaikille mahtuville ilman pitoa');
  perform pg_temp.ck((select bool_and(hold_expires_at <= now()) from booking.waitlist_entries where customer_email in ('w1@t139.example','w3@t139.example')), 'D19: aiempi pito ei uusiudu (historia säilyy)');

  -- ===== e) ei tuplailmoituksia =====
  for n in 1..3 loop m := booking.waitlist_sweep(); perform booking._notify_waitlist_for_window(v_space, v_s, v_e); end loop;
  perform pg_temp.ck(pg_temp.mails('b@t139.example') = 1 and pg_temp.mails('c@t139.example') = 1 and pg_temp.mails('d@t139.example') = 1 and pg_temp.mails('a@t139.example') = 0, 'E1: a)–b): B, C, D yksi viesti kukin, A ei yhtään');
  perform pg_temp.ck(pg_temp.mails('q@t139.example') = 1 and pg_temp.mails('r@t139.example') = 1 and pg_temp.mails('s@t139.example') = 1 and pg_temp.mails('p@t139.example') = 0, 'E2: c): Q, R, S yksi viesti kukin');
  perform pg_temp.ck(pg_temp.mails('w1@t139.example') = 2 and pg_temp.mails('w2@t139.example') = 1 and pg_temp.mails('w3@t139.example') = 3 and pg_temp.mails('w4@t139.example') = 1,
    'E3: d): viesti vain kerran per vapautuminen (W1 2, W2 1, W3 3, W4 1)');
  perform pg_temp.ck((select count(distinct dedupe_key) = count(*) from booking.email_outbox where kind = 'waitlist_spot_freed'), 'E4: dedupe-avaimet uniikit');
  perform pg_temp.ck(pg_temp.mails_like('%@t139.example') = 13, 'E5: toistuvat sweepit ja ajot eivät lähetä lisää (yhteensä 13)');

  -- ===== Tekniset =====
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.waitlist_sweep()', 'execute') and not has_function_privilege('authenticated', 'booking.waitlist_sweep()', 'execute'), 'T1: sweep ei anonille/authenticatedille');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._waitlist_process_session(bigint,date)', 'execute') and not has_function_privilege('anon', 'booking._waitlist_notify_entry(bigint,timestamptz)', 'execute'), 'T2: sisäiset funktiot ei anonille');
  perform pg_temp.ck(not has_table_privilege('anon', 'booking.waitlist_session_state', 'select') and not has_table_privilege('authenticated', 'booking.waitlist_session_state', 'select')
    and (select relrowsecurity from pg_class where oid = 'booking.waitlist_session_state'::regclass), 'T3: tilataulu: RLS, ei oikeuksia');
  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_waitlist_claim(uuid)', 'execute'), 'T4: anon saa lunastaa');
  perform pg_temp.ck(exists (select 1 from cron.job where jobname = 'booking_waitlist_sweep' and schedule = '* * * * *' and command = 'select booking.waitlist_sweep()'), 'T5: pg_cron-ajo minuutin välein');
  perform pg_temp.ck((select bool_and(prosecdef and proconfig @> array['search_path=""']) from pg_proc where oid in ('booking.waitlist_sweep()'::regprocedure, 'booking._waitlist_process_session(bigint,date)'::regprocedure, 'booking._waitlist_notify_entry(bigint,timestamptz)'::regprocedure)), 'T6: security definer, search_path tyhjä');
  update booking.settings set value = 'false'::jsonb where key = 'waitlist_enabled';
  perform pg_temp.ck(booking.waitlist_sweep() = 0, 'T7: waitlist_enabled=false → sweep ei tee mitään');
  update booking.settings set value = 'true'::jsonb where key = 'waitlist_enabled';

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t139_r where ok), (select count(*) from t139_r where not ok),
    coalesce((select string_agg(label, ' | ') from t139_r where not ok), 'ALL OK');
end $t$;
