-- t135: voimassa olevat ilmoitukset vähennetään vapaista paikoista myös seuraavissa ajoissa (booking_135),
-- kapasiteettipoolin jakavat säännöt, tarjouksen vanheneminen ja claim-rate limit ilman rivejä tuntemattomalle tokenille.
-- Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN (mock-data: Miesten sauna ma, kapasiteetti 16;
-- to: Turvetorstai 16–19 (poolit yleinen_arki + turve) ja Yleinen vuoro 17–19 (yleinen_arki) jakavat poolin).
-- Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken. Tulos: TESTRESULT pass=… fail=…
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t135_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t135_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.st(p_email text) returns text language sql as $$ select status from booking.waitlist_entries where customer_email = p_email $$;
create function pg_temp.rid(p_email text) returns bigint language sql as $$
  select r.id from booking.reservations r join booking.orders o on o.id = r.order_id join booking.customers c on c.id = o.customer_id where c.email = p_email order by r.id limit 1 $$;
create function pg_temp.mails(p_email text) returns int language sql as $$
  select count(*)::int from booking.email_outbox where kind = 'waitlist_spot_freed' and payload ->> 'to_email' = p_email $$;
create function pg_temp.rl() returns int language sql as $$ select count(*)::int from booking.rate_limit_hits where bucket like 'waitlist:claim:%' $$;
create function pg_temp.age(p_email text, p_age interval) returns void language sql as $$
  update booking.waitlist_entries set notified_at = now() - p_age where customer_email = p_email $$;
do $t$
declare
  v_rule bigint := test.rule('Miesten sauna%'); d date := test.next_dow(1) + 42;
  v_turve bigint := test.rule('Turvetorstai%'); v_yl bigint := test.rule('Yleinen vuoro to%'); dt date := test.next_dow(4) + 42;
  v_space bigint; v_s timestamptz; v_e timestamptz; v_sp2 bigint; v_s2 timestamptz; v_e2 timestamptz;
  b jsonb; ja jsonb; jb jsonb; jc jsonb; jd jsonb; jp jsonb; jq jsonb; c jsonb; n int; v_rl0 int; v_bad int := 0; i int;
begin
  perform booking.public_join_waitlist(v_rule, d, 1, 'x', 'x');   -- lämmittely: rate limit -avain ei kaada
  -- ===== Tuotannon tapaus: jonossa A5, B1, C4, D3, vapautuu 4 paikkaa =====
  b := test.pub_book(v_rule, d, 12, 'iso@t135.example');  perform pg_temp.ck((b ->> 'ok')::boolean, 'A1: 12 hlöä');
  b := test.pub_book(v_rule, d, 4, 'nelja@t135.example'); perform pg_temp.ck((b ->> 'ok')::boolean, 'A2: 4 hlöä (vuoro täynnä)');
  perform test.anon();
  ja := booking.public_join_waitlist(v_rule, d, 5, 'Jono A', 'a@t135.example');
  jb := booking.public_join_waitlist(v_rule, d, 1, 'Jono B', 'b@t135.example');
  jc := booking.public_join_waitlist(v_rule, d, 4, 'Jono C', 'c@t135.example');
  jd := booking.public_join_waitlist(v_rule, d, 3, 'Jono D', 'd@t135.example');
  perform test.logout();
  perform pg_temp.ck((ja ->> 'ok')::boolean and (jb ->> 'ok')::boolean and (jc ->> 'ok')::boolean and (jd ->> 'ok')::boolean, 'A3: A5, B1, C4, D3 jonoon');
  -- jonon järjestys created_at,id: sama transaktio → id ratkaisee (A < B < C < D)
  select space_id, starts_at, ends_at into v_space, v_s, v_e from booking.waitlist_entries where customer_email = 'a@t135.example';

  -- 1. ajo (peruminen → trigger): 4 vapaata → B (1) ja D (3); A (5) ei mahdu, C (4) ei mahdu B:n jälkeen.
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('nelja@t135.example');
  perform pg_temp.ck(pg_temp.st('a@t135.example') = 'waiting', 'B1: A5 ei mahdu');
  perform pg_temp.ck(pg_temp.st('b@t135.example') = 'notified' and pg_temp.mails('b@t135.example') = 1, 'B2: B1 ilmoitetaan');
  perform pg_temp.ck(pg_temp.st('c@t135.example') = 'waiting', 'B3: C4 ei mahdu 1. ajossa');
  perform pg_temp.ck(pg_temp.st('d@t135.example') = 'notified' and pg_temp.mails('d@t135.example') = 1, 'B4: D3 ilmoitetaan');

  -- 2. ajo samalle ikkunalle: B:n ja D:n tarjoukset ovat voimassa → C ei saa ilmoitusta (tuotannon vika).
  n := booking._notify_waitlist_for_window(v_space, v_s, v_e);
  perform pg_temp.ck(n = 0, 'C1: 2. ajo ei ilmoita ketään');
  perform pg_temp.ck(pg_temp.st('c@t135.example') = 'waiting' and pg_temp.mails('c@t135.example') = 0, 'C2: C ei saa samoja 4 paikkaa');
  perform pg_temp.ck(pg_temp.st('a@t135.example') = 'waiting', 'C3: A edelleen jonossa');
  n := booking._notify_waitlist_for_window(v_space, v_s, v_e);
  perform pg_temp.ck(n = 0 and pg_temp.mails('c@t135.example') = 0, 'C4: 3. ajo sama tulos');

  -- ===== Tarjouksen vanheneminen: asetus waitlist_offer_minutes (oletus 60) =====
  perform pg_temp.age('b@t135.example', interval '2 hours'); perform pg_temp.age('d@t135.example', interval '2 hours');
  insert into booking.settings(key, value) values ('waitlist_offer_minutes', '180'::jsonb)
    on conflict (key) do update set value = excluded.value;
  n := booking._notify_waitlist_for_window(v_space, v_s, v_e);
  perform pg_temp.ck(n = 0 and pg_temp.st('c@t135.example') = 'waiting', 'D1: 180 min tarjous: 2 h vanhat ilmoitukset yhä voimassa');
  update booking.settings set value = '"ei-numero"'::jsonb where key = 'waitlist_offer_minutes';
  n := booking._notify_waitlist_for_window(v_space, v_s, v_e);   -- virheellinen arvo → oletus 60 min, ei poikkeusta
  perform pg_temp.ck(n = 1, 'D2: virheellinen asetus → oletus 60 min, vanhentuneet tarjoukset vapauttavat paikat');
  perform pg_temp.ck(pg_temp.st('c@t135.example') = 'notified' and pg_temp.mails('c@t135.example') = 1, 'D3: C saa vapautuneet 4 paikkaa');
  perform pg_temp.ck(pg_temp.st('a@t135.example') = 'waiting', 'D4: A5 ei edelleenkään mahdu');
  perform pg_temp.ck(pg_temp.st('b@t135.example') = 'notified' and pg_temp.st('d@t135.example') = 'notified', 'D5: vanhentunut tarjous ei muuta B:n/D:n tilaa');
  n := booking._notify_waitlist_for_window(v_space, v_s, v_e);
  perform pg_temp.ck(n = 0 and pg_temp.mails('c@t135.example') = 1, 'D6: C:n tarjous voimassa → ei uusia ilmoituksia');
  delete from booking.settings where key = 'waitlist_offer_minutes';
  -- Vanhentunut tarjous ei estä uusintailmoitusta: C:n tarjous vanhenee, mutta C on 'notified' (ei uudelleen jonossa).
  perform pg_temp.age('c@t135.example', interval '61 minutes');
  n := booking._notify_waitlist_for_window(v_space, v_s, v_e);
  perform pg_temp.ck(n = 0 and pg_temp.st('a@t135.example') = 'waiting', 'D7: oletus 60 min; A5 ei mahdu 4 paikkaan');

  -- ===== Kapasiteettipooli: Turvetorstai (poolit 2+3) ja Yleinen vuoro to 17–19 (pooli 2) =====
  b := test.pub_book(v_yl, dt, 13, 'to-iso@t135.example'); perform pg_temp.ck((b ->> 'ok')::boolean, 'E1: to 13 hlöä');
  b := test.pub_book(v_yl, dt, 3, 'to-kolme@t135.example'); perform pg_temp.ck((b ->> 'ok')::boolean, 'E2: to 3 hlöä (pooli täynnä)');
  perform test.anon();
  jp := booking.public_join_waitlist(v_yl, dt, 3, 'Jono P', 'p@t135.example');
  jq := booking.public_join_waitlist(v_turve, dt, 2, 'Jono Q', 'q@t135.example');
  perform test.logout();
  perform pg_temp.ck((jp ->> 'ok')::boolean and (jq ->> 'ok')::boolean, 'E3: P (yleinen 3) ja Q (turve 2) jonoon, molemmat täynnä');
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('to-kolme@t135.example');
  perform pg_temp.ck(pg_temp.st('p@t135.example') = 'notified', 'E4: P saa poolin 3 vapaata');
  perform pg_temp.ck(pg_temp.st('q@t135.example') = 'waiting' and pg_temp.mails('q@t135.example') = 0, 'E5: Q (toinen sääntö, sama pooli) ei saa samoja paikkoja samassa ajossa');
  select space_id, starts_at, ends_at into v_sp2, v_s2, v_e2 from booking.waitlist_entries where customer_email = 'q@t135.example';
  n := booking._notify_waitlist_for_window(v_sp2, v_s2, v_e2);
  perform pg_temp.ck(n = 0 and pg_temp.st('q@t135.example') = 'waiting', 'E6: 2. ajo: P:n tarjous poolissa voimassa → Q ei');
  perform pg_temp.age('p@t135.example', interval '2 hours');
  n := booking._notify_waitlist_for_window(v_sp2, v_s2, v_e2);
  perform pg_temp.ck(n = 1 and pg_temp.st('q@t135.example') = 'notified', 'E7: P:n tarjous vanheni → Q saa ilmoituksen');

  -- ===== Rate limit: tuntematon token ei luo rate_limit_hits-rivejä =====
  v_rl0 := pg_temp.rl();
  perform test.anon('203.0.113.7');
  for i in 1..40 loop
    if booking.public_waitlist_claim(gen_random_uuid()) ->> 'code' is distinct from 'not_found' then v_bad := v_bad + 1; end if;
  end loop;
  perform test.logout();
  perform pg_temp.ck(v_bad = 0, 'F1: satunnaiset tokenit → not_found');
  perform pg_temp.ck(pg_temp.rl() = v_rl0, 'F2: tuntemattomat tokenit eivät luo rate limit -rivejä (IP:n kanssa)');
  perform test.anon(); c := booking.public_waitlist_claim(gen_random_uuid()); perform test.logout();
  perform pg_temp.ck(c ->> 'code' = 'not_found' and pg_temp.rl() = v_rl0, 'F3: ilman IP:tä sama');
  perform booking.public_leave_waitlist((ja ->> 'token')::uuid);
  perform test.anon('203.0.113.7'); c := booking.public_waitlist_claim((ja ->> 'token')::uuid); perform test.logout();
  perform pg_temp.ck(c ->> 'code' = 'not_found' and pg_temp.rl() = v_rl0, 'F4: peruttu jonovaraus → not_found ilman riviä');
  perform test.anon('203.0.113.7'); c := booking.public_waitlist_claim((jc ->> 'token')::uuid); perform test.logout();
  perform pg_temp.ck((c ->> 'ok')::boolean and (c ->> 'persons')::int = 4, 'F5: tunnettu token lunastetaan');
  perform pg_temp.ck(pg_temp.rl() = v_rl0 + 2
    and exists (select 1 from booking.rate_limit_hits where bucket = 'waitlist:claim:' || (jc ->> 'token'))
    and exists (select 1 from booking.rate_limit_hits where bucket = 'waitlist:claim:ip:203.0.113.7'), 'F6: tunnettu token → token- ja IP-rivi');
  perform test.anon();
  for i in 2..30 loop c := booking.public_waitlist_claim((jc ->> 'token')::uuid); end loop;
  jp := booking.public_waitlist_claim((jc ->> 'token')::uuid);
  perform test.logout();
  perform pg_temp.ck((c ->> 'ok')::boolean, 'F7: 30 lunastusta sallitaan');
  c := jp;
  perform pg_temp.ck(c ->> 'code' = 'rate_limited', 'F8: 31. lunastus 10 min sisällä → rate_limited');

  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_waitlist_claim(uuid)', 'execute'), 'G1: anon saa lunastaa');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._notify_waitlist_for_window(bigint,timestamptz,timestamptz)', 'execute'), 'G2: sisäinen funktio ei anonille');
  perform pg_temp.ck(not has_function_privilege('authenticated', 'booking._notify_waitlist_for_window(bigint,timestamptz,timestamptz)', 'execute'), 'G3: sisäinen funktio ei authenticatedille');

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t135_r where ok), (select count(*) from t135_r where not ok),
    coalesce((select string_agg(label, ' | ') from t135_r where not ok), 'ALL OK');
end $t$;
