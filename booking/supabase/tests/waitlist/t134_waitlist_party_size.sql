-- t134: jonotuslistan henkilömäärä ja mahtuvuuteen perustuva jako (booking_134).
-- Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN (mock-data: Miesten sauna ma, kapasiteetti 16).
-- Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken. Tulos: TESTRESULT pass=… fail=…
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t134_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t134_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.st(p_email text) returns text language sql as $$ select status from booking.waitlist_entries where customer_email = p_email $$;
create function pg_temp.rid(p_email text) returns bigint language sql as $$
  select r.id from booking.reservations r join booking.orders o on o.id = r.order_id join booking.customers c on c.id = o.customer_id where c.email = p_email order by r.id limit 1 $$;
create function pg_temp.mails(p_email text) returns int language sql as $$
  select count(*)::int from booking.email_outbox where kind = 'waitlist_spot_freed' and payload ->> 'to_email' = p_email $$;
do $t$
declare
  v_rule bigint := test.rule('Miesten sauna%'); d date := test.next_dow(1) + 35;
  b jsonb; ja jsonb; jb jsonb; jc jsonb; c jsonb; c2 jsonb; c3 jsonb; x1 jsonb; x2 jsonb; x3 jsonb;
begin
  perform booking.public_join_waitlist(v_rule, d, 1, 'x', 'x');   -- lämmittely: rate limit -avain ei kaada
  b := test.pub_book(v_rule, d, 10, 'iso@t134.example');   perform pg_temp.ck((b ->> 'ok')::boolean, 'A1: 10 hlöä');
  b := test.pub_book(v_rule, d, 5, 'viisi@t134.example');  perform pg_temp.ck((b ->> 'ok')::boolean, 'A2: 5 hlöä');
  b := test.pub_book(v_rule, d, 1, 'yksi@t134.example');   perform pg_temp.ck((b ->> 'ok')::boolean, 'A3: 1 hlö (vuoro täynnä)');

  perform test.anon();
  x1 := booking.public_join_waitlist(v_rule, d, 7, 'Liian Monta', 'seiska@t134.example');
  x2 := booking.public_join_waitlist(v_rule, d, 0, 'Nolla Hlo', 'nolla@t134.example');
  x3 := booking.public_join_waitlist(v_rule, d, null, 'Null Hlo', 'null@t134.example');
  ja := booking.public_join_waitlist(v_rule, d, 2, 'Kaksi Hloa', 'kaksi@t134.example');   -- jonossa ensimmäisenä
  jb := booking.public_join_waitlist(v_rule, d, 1, 'Yksi Hlo', 'yksi-jono@t134.example');
  jc := booking.public_join_waitlist(v_rule, d, 1, 'Toinen Yksi', 'toinen@t134.example');
  b := booking.public_join_waitlist(v_rule, d, 6, 'Kuusi Hloa', 'kuusi@t134.example');
  perform test.logout();
  perform pg_temp.ck(x1 ->> 'code' = 'invalid_persons', 'B1: 7 hlöä hylätään');
  perform pg_temp.ck(x2 ->> 'code' = 'invalid_persons', 'B2: 0 hlöä hylätään');
  perform pg_temp.ck(x3 ->> 'code' = 'invalid_persons', 'B3: null hylätään');
  perform pg_temp.ck(not exists (select 1 from booking.waitlist_entries where customer_email in ('seiska@t134.example','nolla@t134.example','null@t134.example')), 'B3b: hylättyjä ei tallenneta');
  perform pg_temp.ck((ja ->> 'ok')::boolean and ja ->> 'token' is not null, 'B4: 2 hlöä jonoon');
  perform pg_temp.ck((b ->> 'ok')::boolean and (select persons from booking.waitlist_entries where customer_email = 'kuusi@t134.example') = 6, 'B5: 6 hlöä tallennetaan');
  perform pg_temp.ck((select persons from booking.waitlist_entries where customer_email = 'kaksi@t134.example') = 2, 'B6: henkilömäärä tallessa');

  -- Esimerkkitapaus: vapautuu 1 paikka, jonossa ensin 2 hengen ja sitten 1 hengen jonovaraus → ilmoitus 1 hengen varaukselle.
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('yksi@t134.example');
  perform pg_temp.ck(pg_temp.st('kaksi@t134.example') = 'waiting' and pg_temp.mails('kaksi@t134.example') = 0, 'C1: 2 hengen jonovaraus ei mahdu (1 vapaa), ei ilmoitusta');
  perform pg_temp.ck(pg_temp.st('yksi-jono@t134.example') = 'notified' and pg_temp.mails('yksi-jono@t134.example') = 1, 'C2: 1 hengen jonovaraus saa ilmoituksen');
  perform pg_temp.ck(pg_temp.st('toinen@t134.example') = 'waiting', 'C3: yksi paikka ilmoitetaan vain yhdelle');
  perform pg_temp.ck(pg_temp.st('kuusi@t134.example') = 'waiting', 'C4: 6 hengen jonovaraus odottaa');

  -- Lunastus: määrä = jonovarauksen henkilömäärä, sallitaan vain jos paikkoja riittää.
  perform test.anon();
  c := booking.public_waitlist_claim((jb ->> 'token')::uuid);
  c2 := booking.public_waitlist_claim((ja ->> 'token')::uuid);
  c3 := booking.public_waitlist_claim('00000000-0000-4000-8000-000000000000');
  perform test.logout();
  perform pg_temp.ck((c ->> 'ok')::boolean and (c ->> 'enough')::boolean and (c ->> 'persons')::int = 1 and (c ->> 'rule_id')::bigint = v_rule and (c ->> 'session_date')::date = d, 'D1: 1 hengen lunastus mahtuu');
  perform pg_temp.ck((c2 ->> 'ok')::boolean and not (c2 ->> 'enough')::boolean and (c2 ->> 'persons')::int = 2, 'D2: 2 hengen lunastus ei mahdu');
  perform pg_temp.ck(pg_temp.st('kaksi@t134.example') = 'waiting' and pg_temp.st('yksi-jono@t134.example') = 'notified', 'D2b: tilat ennallaan');
  perform pg_temp.ck(c3 ->> 'code' = 'not_found', 'D3: tuntematon token');
  perform pg_temp.ck(not (c ? 'customer_email') and not (c ? 'customer_name') and not (c ? 'token'), 'D4: ei henkilötietoja');

  -- Vapautuu 5 paikkaa (6 vapaana): järjestyksessä 2 hengen (mahtuu) ja 1 hengen; 6 hengen ei mahdu jäljelle jääviin.
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('viisi@t134.example');
  perform pg_temp.ck(pg_temp.st('kaksi@t134.example') = 'notified', 'E1: 2 hengen jonovaraus saa ilmoituksen');
  perform pg_temp.ck(pg_temp.st('toinen@t134.example') = 'notified', 'E2: jäljelle jääneet paikat seuraavalle mahtuvalle');
  perform pg_temp.ck(pg_temp.st('kuusi@t134.example') = 'waiting', 'E3: 6 hengen ei mahdu jäljelle jääviin (6 - 2 - 1)');

  -- Paikat täyttyvät ennen lunastusta → lunastus estyy ja jonovaraus palaa jonoon.
  b := test.pub_book(v_rule, d, 6, 'ehti@t134.example'); perform pg_temp.ck((b ->> 'ok')::boolean, 'F1: joku muu varaa 6 paikkaa');
  perform test.anon(); c := booking.public_waitlist_claim((ja ->> 'token')::uuid); perform test.logout();
  perform pg_temp.ck((c ->> 'ok')::boolean and not (c ->> 'enough')::boolean, 'F2: lunastus estyy, kun paikat eivät enää riitä');
  perform pg_temp.ck(pg_temp.st('kaksi@t134.example') = 'waiting', 'F3: jonovaraus palaa jonoon');
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('ehti@t134.example');
  perform pg_temp.ck(pg_temp.st('kaksi@t134.example') = 'notified' and pg_temp.mails('kaksi@t134.example') = 2, 'F4: uusi vapautuminen ilmoittaa uudelleen');

  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_waitlist_claim(uuid)', 'execute'), 'G1: anon saa lunastaa');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._notify_waitlist_for_window(bigint,timestamptz,timestamptz)', 'execute'), 'G2: sisäinen funktio ei anonille');
  perform pg_temp.ck(booking._setting('waitlist_whatsapp_enabled') = 'false'::jsonb, 'G3: WhatsApp pois');

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t134_r where ok), (select count(*) from t134_r where not ok),
    coalesce((select string_agg(label, ' | ') from t134_r where not ok), 'ALL OK');
end $t$;
