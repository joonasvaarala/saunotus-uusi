-- t139 (osa 2): jonotuspidon aikana paikka EI ole julkisessa myynnissä (booking_139, omistajan lisävaatimus).
-- a) pidon aikana julkinen haku (public_availability, public_availability_all, _sessions) näyttää vähemmän paikkoja eikä
--    julkinen varaus tai ajanmuutos onnistu viimeiseen pidettyyn paikkaan
-- b) pidon haltija voi lunastaa ja varata (oma pito ei vähennä); varaus vapauttaa pidon heti
-- c) vanhenemisen jälkeen paikka on heti taas myynnissä; sweep ilmoittaa kaikille mahtuville
-- d) jonotuksen peruminen vapauttaa paikan heti
-- e) alle 48 h: ei vaikutusta (ei pitoa)
-- f) kapasiteettipooli: pito vähentää myös saman poolin toisen vuoron paikkoja
-- g) henkilökunta ohittaa pidon, hallinnan päivänäkymä näyttää pidon (admin_day_view.waitlist_holds)
-- "≥ 48 h" / "< 48 h" simuloidaan asetuksella waitlist_hold_min_hours_before kuten t137/t139.
-- Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN (mock-data: Miesten sauna ma, kapasiteetti 16).
-- Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken. Tulos: TESTRESULT pass=… fail=…
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t139h_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t139h_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.st(p_email text) returns text language sql as $$ select status from booking.waitlist_entries where customer_email = p_email $$;
create function pg_temp.held(p_email text) returns boolean language sql as $$
  select status = 'notified' and coalesce(hold_expires_at > now(), false) from booking.waitlist_entries where customer_email = p_email $$;
create function pg_temp.rid(p_email text) returns bigint language sql as $$
  select r.id from booking.reservations r join booking.orders o on o.id = r.order_id join booking.customers c on c.id = o.customer_id where c.email = p_email order by r.id limit 1 $$;
create function pg_temp.expire(p_email text) returns void language sql as $$
  update booking.waitlist_entries set notified_at = now() - interval '121 minutes', hold_expires_at = now() - interval '1 minute' where customer_email = p_email $$;
create function pg_temp.join(p_rule bigint, p_date date, p_persons int, p_email text) returns jsonb language plpgsql as $$
declare j jsonb; begin perform test.anon(); j := booking.public_join_waitlist(p_rule, p_date, p_persons, 'Jono ' || p_email, p_email); perform test.logout(); return j; end $$;
create function pg_temp.claim(p_token text) returns jsonb language plpgsql as $$
declare c jsonb; begin perform test.anon(); c := booking.public_waitlist_claim(p_token::uuid); perform test.logout(); return c; end $$;
-- Julkinen saatavuus anonina kolmella polulla: tuotteen haku, kuukauden kaikki tuotteet (booking_133) ja _sessions.
create function pg_temp.pub_rem(p_rule bigint, p_date date) returns int language plpgsql as $$
declare v_p bigint; a int; b int; c int; begin
  select product_id into v_p from booking.schedule_rules where id = p_rule;
  perform test.anon();
  select remaining into a from booking.public_availability(v_p, p_date, p_date) where rule_id = p_rule;
  select remaining into b from booking.public_availability_all(p_date, p_date, 'consumer') where rule_id = p_rule;
  perform test.logout();
  select remaining into c from booking._sessions(p_date, p_date, v_p, true) where rule_id = p_rule;
  if a is distinct from b or a is distinct from c then return -100 - coalesce(a, 0); end if;   -- polut eivät täsmää
  return a; end $$;
create function pg_temp.pub_status(p_rule bigint, p_date date) returns text language plpgsql as $$
declare v_p bigint; s text; begin
  select product_id into v_p from booking.schedule_rules where id = p_rule;
  perform test.anon(); select status into s from booking.public_availability(v_p, p_date, p_date) where rule_id = p_rule; perform test.logout();
  return s; end $$;
create function pg_temp.hrs(p_rule bigint, p_date date) returns int language sql as $$
  select floor(extract(epoch from s.starts_at - now()) / 3600)::int from booking._sessions(p_date, p_date, null, true) s where s.rule_id = p_rule limit 1 $$;
create function pg_temp.hold_hours(p_h int) returns void language sql as $$
  insert into booking.settings(key, value) values ('waitlist_hold_min_hours_before', to_jsonb(p_h)) on conflict (key) do update set value = excluded.value $$;
do $t$
declare
  v_rule bigint := test.rule('Miesten sauna%');
  v_turve bigint := test.rule('Turvetorstai%'); v_yl bigint := test.rule('Yleinen vuoro to%'); dt date := test.next_dow(4) + 84;
  d1 date := test.next_dow(1) + 84; d2 date := test.next_dow(1) + 91; d3 date := test.next_dow(1) + 98; d4 date := test.next_dow(1) + 105; d5 date := test.next_dow(1) + 77;
  b jsonb; ja jsonb; jb jsonb; jc jsonb; jd jsonb; je jsonb; jq jsonb; c jsonb; v jsonb; m int; tok uuid; v_staff uuid;
begin
  perform booking.public_join_waitlist(v_rule, d1, 1, 'x', 'x');   -- lämmittely: rate limit -avain ei kaada

  -- ===== a) pidon aikana julkinen haku ja varaus =====
  b := test.pub_book(v_rule, d1, 12, 'iso1@t139h.example'); b := test.pub_book(v_rule, d1, 4, 'nelja1@t139h.example');
  perform pg_temp.ck(pg_temp.pub_rem(v_rule, d1) = 0, 'A1: vuoro täynnä (16)');
  ja := pg_temp.join(v_rule, d1, 2, 'a@t139h.example'); jb := pg_temp.join(v_rule, d1, 1, 'b@t139h.example');
  perform pg_temp.hold_hours(pg_temp.hrs(v_rule, d1) - 1);   -- vuoroon yli pitorajan
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('nelja1@t139h.example');
  perform pg_temp.ck(pg_temp.held('a@t139h.example') and pg_temp.st('b@t139h.example') = 'waiting', 'A2: 4 vapautuu → A2 pitoon');
  perform pg_temp.ck(pg_temp.pub_rem(v_rule, d1) = 2, 'A3: julkinen haku (tuote, kuukausi/booking_133, _sessions) näyttää 4 − 2 = 2 vapaata');
  b := test.pub_book(v_rule, d1, 3, 'kolme1@t139h.example');
  perform pg_temp.ck(not (b ->> 'ok')::boolean and b ->> 'code' = 'capacity_exceeded', 'A4: julkinen 3 hengen varaus ei mahdu (pidetyt 2 eivät myynnissä)');
  b := test.pub_book(v_rule, d1, 2, 'kaksi1@t139h.example');
  perform pg_temp.ck((b ->> 'ok')::boolean and pg_temp.pub_rem(v_rule, d1) = 0 and pg_temp.pub_status(v_rule, d1) = 'full', 'A5: myynnissä olevat 2 myydään → julkisesti täynnä');
  b := test.pub_book(v_rule, d1, 1, 'yksi1@t139h.example');
  perform pg_temp.ck(not (b ->> 'ok')::boolean and b ->> 'code' = 'capacity_exceeded', 'A6: viimeiseen pidettyyn paikkaan ei voi varata');
  b := test.pub_book(v_rule, d4, 1, 'siirto@t139h.example');
  perform test.anon(); v := booking.public_change_booking((b ->> 'token')::uuid, v_rule, d1, null); perform test.logout();
  perform pg_temp.ck(not coalesce((v ->> 'ok')::boolean, false), 'A7: ajanmuutos pidettyyn paikkaan ei onnistu');
  perform pg_temp.ck(pg_temp.st('b@t139h.example') = 'waiting', 'A8: muut jonottajat eivät saa pidettyjä paikkoja');

  -- ===== b) haltija lunastaa ja varaa =====
  c := pg_temp.claim(ja ->> 'token');
  perform pg_temp.ck((c ->> 'ok')::boolean and (c ->> 'enough')::boolean and not (c ->> 'hold_expired')::boolean and (c ->> 'remaining')::int = 2,
    'B1: haltijan lunastus: oma pito ei vähennä (2 vapaana hänelle)');
  b := test.pub_book(v_rule, d1, 2, 'a@t139h.example');
  perform pg_temp.ck((b ->> 'ok')::boolean, 'B2: haltija varaa pidetyt 2 paikkaa');
  set constraints all immediate; set constraints all deferred;   -- _waitlist_booked_trg on deferrable initially deferred
  perform pg_temp.ck(pg_temp.st('a@t139h.example') = 'booked' and pg_temp.pub_rem(v_rule, d1) = 0, 'B3: varaus vapauttaa pidon heti (booked), vuoro täynnä varauksista');
  perform pg_temp.ck((select coalesce(sum(persons), 0) from booking.reservations where rule_id = v_rule and (starts_at at time zone 'Europe/Helsinki')::date = d1
    and status in ('pending', 'confirmed')) = 16, 'B4: ei ylivarausta (16/16)');

  -- ===== c) vanheneminen palauttaa paikat myyntiin =====
  b := test.pub_book(v_rule, d2, 12, 'iso2@t139h.example'); b := test.pub_book(v_rule, d2, 4, 'nelja2@t139h.example');
  jc := pg_temp.join(v_rule, d2, 3, 'c@t139h.example'); jd := pg_temp.join(v_rule, d2, 1, 'd@t139h.example');
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('nelja2@t139h.example');
  perform pg_temp.ck(pg_temp.held('c@t139h.example') and pg_temp.pub_rem(v_rule, d2) = 1, 'C1: C3 pidossa → 1 myynnissä');
  perform pg_temp.expire('c@t139h.example');
  perform pg_temp.ck(pg_temp.pub_rem(v_rule, d2) = 4 and pg_temp.pub_status(v_rule, d2) = 'available', 'C2: pito vanheni → kaikki 4 heti myynnissä (now()-ehto, ei ajoa)');
  m := booking.waitlist_sweep();
  perform pg_temp.ck(pg_temp.st('d@t139h.example') = 'notified' and not pg_temp.held('d@t139h.example') and pg_temp.pub_rem(v_rule, d2) = 4,
    'C3: sweep ilmoittaa mahtuvalle D1 ilman pitoa, paikat pysyvät myynnissä');
  b := test.pub_book(v_rule, d2, 4, 'muu2@t139h.example');
  perform pg_temp.ck((b ->> 'ok')::boolean, 'C4: vanhentuneen pidon paikat voi varata');

  -- ===== d) jonotuksen peruminen vapauttaa paikan =====
  b := test.pub_book(v_rule, d3, 12, 'iso3@t139h.example'); b := test.pub_book(v_rule, d3, 4, 'nelja3@t139h.example');
  je := pg_temp.join(v_rule, d3, 3, 'e@t139h.example');
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('nelja3@t139h.example');
  perform pg_temp.ck(pg_temp.held('e@t139h.example') and pg_temp.pub_rem(v_rule, d3) = 1, 'D1: E3 pidossa → 1 myynnissä');
  perform test.anon(); v := booking.public_leave_waitlist((je ->> 'token')::uuid); perform test.logout();
  perform pg_temp.ck((v ->> 'ok')::boolean and pg_temp.st('e@t139h.example') = 'cancelled' and pg_temp.pub_rem(v_rule, d3) = 4, 'D2: jonosta poistuminen vapauttaa pidetyt paikat heti');
  b := test.pub_book(v_rule, d3, 4, 'muu3@t139h.example');
  perform pg_temp.ck((b ->> 'ok')::boolean, 'D3: paikat varattavissa');

  -- ===== e) alle 48 h: ei vaikutusta =====
  b := test.pub_book(v_rule, d5, 12, 'iso5@t139h.example'); b := test.pub_book(v_rule, d5, 4, 'nelja5@t139h.example');
  jq := pg_temp.join(v_rule, d5, 2, 'f@t139h.example');
  perform pg_temp.hold_hours(pg_temp.hrs(v_rule, d5) + 1);   -- vuoroon alle pitorajan
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('nelja5@t139h.example');
  perform pg_temp.ck(pg_temp.st('f@t139h.example') = 'notified' and not pg_temp.held('f@t139h.example'), 'E1: alle 48 h: ilmoitus ilman pitoa');
  perform pg_temp.ck(pg_temp.pub_rem(v_rule, d5) = 4, 'E2: alle 48 h: kaikki 4 julkisesti myynnissä');
  b := test.pub_book(v_rule, d5, 4, 'muu5@t139h.example');
  perform pg_temp.ck((b ->> 'ok')::boolean, 'E3: alle 48 h: muu asiakas voi varata kaikki');

  -- ===== f) kapasiteettipooli: Turvetorstai (poolit 2+3) ja Yleinen vuoro to (pooli 2) =====
  b := test.pub_book(v_yl, dt, 13, 'to-iso@t139h.example'); b := test.pub_book(v_yl, dt, 3, 'to-kolme@t139h.example');
  jq := pg_temp.join(v_yl, dt, 2, 'p@t139h.example');
  perform pg_temp.hold_hours(pg_temp.hrs(v_yl, dt) - 1);
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('to-kolme@t139h.example');
  perform pg_temp.ck(pg_temp.held('p@t139h.example') and pg_temp.pub_rem(v_yl, dt) = 1, 'F1: yleinen vuoro: P2 pidossa → 1 myynnissä');
  perform pg_temp.ck(pg_temp.pub_rem(v_turve, dt) <= 1, 'F2: saman poolin Turvetorstai ei näytä pidettyjä paikkoja');
  b := test.pub_book(v_turve, dt, 2, 'turve@t139h.example');
  perform pg_temp.ck(not (b ->> 'ok')::boolean and b ->> 'code' = 'capacity_exceeded', 'F3: saman poolin toinen vuoro ei voi varata pidettyjä paikkoja');

  -- ===== g) henkilökunta =====
  b := test.pub_book(v_rule, d4, 11, 'iso4@t139h.example'); b := test.pub_book(v_rule, d4, 4, 'nelja4@t139h.example');   -- + siirto 1 = 16
  jd := pg_temp.join(v_rule, d4, 2, 'g@t139h.example');
  perform pg_temp.hold_hours(pg_temp.hrs(v_rule, d4) - 1);
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('nelja4@t139h.example');
  perform pg_temp.ck(pg_temp.held('g@t139h.example') and pg_temp.pub_rem(v_rule, d4) = 2, 'G1: G2 pidossa → julkisesti 2 vapaana');
  v_staff := test.mk_staff('staff@t139h.example', 'admin');
  perform test.login(v_staff);
  v := booking.admin_day_view(d4);
  b := booking.admin_create_booking(v_rule, d4, 4, null, '{"kind":"private","name":"Puhelin Asiakas","email":"puhelin@t139h.example","phone":"0401234567"}'::jsonb);
  perform test.logout();
  perform pg_temp.ck((select (s ->> 'remaining')::int from jsonb_array_elements(v -> 'sessions') s where (s ->> 'rule_id')::bigint = v_rule) = 4,
    'G2: hallinta näkee vapaan kapasiteetin ilman pitoa (4)');
  perform pg_temp.ck(jsonb_array_length(v -> 'waitlist_holds') = 1 and (v -> 'waitlist_holds' -> 0 ->> 'persons')::int = 2
    and (v -> 'waitlist_holds' -> 0 ->> 'rule_id')::bigint = v_rule and (v -> 'waitlist_holds' -> 0 ->> 'hold_expires_at') is not null,
    'G3: admin_day_view.waitlist_holds näyttää pidon (2 hlöä, päättymisaika)');
  perform pg_temp.ck(b ? 'order_id' or (b ->> 'ok')::boolean, 'G4: henkilökunta voi ohittaa pidon (4 paikkaa)');
  perform pg_temp.ck((select coalesce(sum(persons), 0) from booking.reservations where rule_id = v_rule and (starts_at at time zone 'Europe/Helsinki')::date = d4
    and status in ('pending', 'confirmed')) = 16, 'G5: ei ylivarausta varauksissa (16/16)');
  c := pg_temp.claim(jd ->> 'token');
  perform pg_temp.ck((c ->> 'ok')::boolean and not (c ->> 'enough')::boolean and pg_temp.st('g@t139h.example') = 'waiting', 'G6: ohitetun pidon haltija ei mahdu → takaisin jonoon');

  -- ===== tekniset =====
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._waitlist_hold_counts(bigint)', 'execute')
    and not has_function_privilege('authenticated', 'booking._waitlist_hold_counts(bigint)', 'execute'), 'T1: _waitlist_hold_counts ei asiakkaille');
  perform pg_temp.ck(exists (select 1 from pg_indexes where schemaname = 'booking' and indexname = 'waitlist_entries_active_hold_idx'), 'T2: osittainen indeksi voimassa oleville pidoille');
  perform pg_temp.ck(coalesce(current_setting('booking.waitlist_hold_exempt', true), '') = '', 'T3: poikkeusasetus ei jää päälle');

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t139h_r where ok), (select count(*) from t139h_r where not ok),
    coalesce((select string_agg(label, ' | ') from t139h_r where not ok), 'ALL OK');
end $t$;
