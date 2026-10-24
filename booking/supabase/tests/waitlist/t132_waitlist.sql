-- t132: jonotuslista (booking_132). Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN (mock-data: Miesten sauna ma, kapasiteetti 16).
-- Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken. Tulos: TESTRESULT pass=… fail=…
-- Migraation/rollbackin uudelleenajettavuus testataan erikseen (migraatio 2x, rollback 2x, migraatio uudelleen).
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t132_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t132_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.st(p_email text) returns text language sql as $$ select status from booking.waitlist_entries where customer_email = p_email $$;
create function pg_temp.rid(p_email text) returns bigint language sql as $$
  select r.id from booking.reservations r join booking.orders o on o.id = r.order_id join booking.customers c on c.id = o.customer_id where c.email = p_email order by r.id limit 1 $$;
do $t$
declare
  v_rule bigint := test.rule('Miesten sauna%'); d date := test.next_dow(1); d2 date := test.next_dow(1) + 21;
  b jsonb; j jsonb; j2 jsonb; v jsonb; cl jsonb; w jsonb; v_err text; v_n int;
begin
  perform booking.public_join_waitlist(v_rule, d, 1, 'x', 'x');   -- lämmittely: rate limit -avain ei kaada
  b := test.pub_book(v_rule, d, 10, 'eka@t132.example'); perform pg_temp.ck((b ->> 'ok')::boolean, 'A1: 10 hlöä varattu');
  b := test.pub_book(v_rule, d, 6, 'toka@t132.example'); perform pg_temp.ck((b ->> 'ok')::boolean, 'A2: 6 hlöä varattu (täynnä)');
  j := booking.public_join_waitlist(v_rule, d + 7, 2, 'Ei Taynna', 'ei@t132.example');
  perform pg_temp.ck(j ->> 'code' = 'not_full', 'A3: vapaaseen vuoroon ei voi jonottaa');
  perform pg_temp.ck(booking.public_join_waitlist(v_rule, d, 2, 'Nimi', 'ei-sahkoposti') ->> 'code' = 'invalid_email', 'A4: virheellinen sähköposti');

  perform test.anon();
  j := booking.public_join_waitlist(v_rule, d, 2, 'Jonottaja Testi', 'Jono@T132.example', null, 'fi', false);
  j2 := booking.public_join_waitlist(v_rule, d, 3, 'Jonottaja Testi', 'jono@t132.example', null, 'fi', false);
  begin perform count(*) from booking.waitlist_entries; v_err := 'ok'; exception when insufficient_privilege then v_err := 'denied'; end;
  perform test.logout();
  perform pg_temp.ck((j ->> 'ok')::boolean and j ->> 'token' is not null, 'B1: anon liittyy jonoon');
  perform pg_temp.ck(j2 ->> 'token' = j ->> 'token' and (select persons from booking.waitlist_entries where customer_email = 'jono@t132.example') = 3, 'B2: sama sähköposti päivittää saman rivin');
  perform pg_temp.ck(v_err = 'denied', 'B3: anon ei lue waitlist_entries-taulua');

  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('eka@t132.example');
  perform pg_temp.ck(pg_temp.st('jono@t132.example') = 'notified', 'C1: peruminen ilmoittaa jonottajalle');
  select count(*) into v_n from booking.email_outbox where kind = 'waitlist_spot_freed' and payload ->> 'to_email' = 'jono@t132.example';
  perform pg_temp.ck(v_n = 1, 'C2: yksi waitlist_spot_freed-viesti outboxissa');
  perform pg_temp.ck((select payload ->> 'book_url' from booking.email_outbox where kind = 'waitlist_spot_freed' and payload ->> 'to_email' = 'jono@t132.example') like '%/varaa/#/varaa/' || v_rule || '/' || d || '/%?n=3&wl=%', 'C3: fi-varauslinkki /varaa/');
  perform test.service(); cl := booking.email_outbox_claim(50); perform test.logout();
  select x into w from jsonb_array_elements(cl) x where x ->> 'kind' = 'waitlist_spot_freed' limit 1;
  perform pg_temp.ck(w ->> 'to' = 'jono@t132.example' and w -> 'waitlist' ->> 'product_name' is not null, 'C4: claim palauttaa vastaanottajan ja waitlist-payloadin');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(cl) x where x ->> 'kind' <> 'waitlist_spot_freed' and x ? 'waitlist'), 'C5: muut viestit ennallaan');

  v := booking.public_leave_waitlist((j ->> 'token')::uuid); perform pg_temp.ck((v ->> 'cancelled')::boolean, 'D1: poistuminen');
  v := booking.public_leave_waitlist((j ->> 'token')::uuid); perform pg_temp.ck((v ->> 'ok')::boolean and not (v ->> 'cancelled')::boolean, 'D2: toinen poistuminen idempotentti');

  update booking.reservations set status = 'confirmed' where id = pg_temp.rid('eka@t132.example');
  j := booking.public_join_waitlist(v_rule, d, 1, 'Kolmas Testi', 'kolmas@t132.example');
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('toka@t132.example');
  perform pg_temp.ck(pg_temp.st('kolmas@t132.example') = 'notified', 'E1: toinen vapautus ilmoittaa seuraavalle');
  update booking.email_outbox set status = 'pending' where kind = 'waitlist_spot_freed' and payload ->> 'to_email' = 'kolmas@t132.example';
  b := test.pub_book(v_rule, d, 1, 'kolmas@t132.example');
  set constraints all immediate;
  perform pg_temp.ck(pg_temp.st('kolmas@t132.example') = 'booked', 'E2: jonottajan oma varaus → booked');
  perform pg_temp.ck((select status from booking.email_outbox where kind = 'waitlist_spot_freed' and payload ->> 'to_email' = 'kolmas@t132.example') = 'skipped', 'E3: odottava ilmoitus ohitetaan varauksen jälkeen');

  b := test.pub_book(v_rule, d2, 16, 'pito@t132.example');
  j := booking.public_join_waitlist(v_rule, d2, 2, 'Nelja Testi', 'nelja@t132.example', null, 'en', false);
  perform pg_temp.ck((j ->> 'ok')::boolean, 'F1: en-jonottaja');
  update booking.reservations set status = 'pending', hold_expires_at = now() - interval '1 minute' where id = pg_temp.rid('pito@t132.example');
  perform booking._expire_holds(null, null);
  perform pg_temp.ck(pg_temp.st('nelja@t132.example') = 'notified', 'F2: vanhentunut pito (_expire_holds) ilmoittaa');
  perform pg_temp.ck((select payload ->> 'book_url' from booking.email_outbox where kind = 'waitlist_spot_freed' and payload ->> 'to_email' = 'nelja@t132.example') like '%/en/book/#/varaa/%', 'F3: en-linkki /en/book/');
  perform pg_temp.ck((select payload ->> 'leave_url' from booking.email_outbox where kind = 'waitlist_spot_freed' and payload ->> 'to_email' = 'nelja@t132.example') like '%/en/book/?poistu_jonosta=%', 'F4: en-poistumislinkki');

  perform pg_temp.ck(booking._setting('waitlist_whatsapp_enabled') = 'false'::jsonb, 'G1: WhatsApp pois oletuksena');
  perform pg_temp.ck((select whatsapp_send_after from booking.waitlist_entries where customer_email = 'nelja@t132.example') is null, 'G2: ei WhatsApp-ajastusta');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._notify_waitlist_for_window(bigint,timestamptz,timestamptz)', 'execute'), 'G3: sisäinen funktio ei anonille');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.email_outbox_claim(integer)', 'execute') and not has_function_privilege('anon', 'booking.email_outbox_claim_base_132(integer)', 'execute'), 'G4: claim ei anonille');
  perform pg_temp.ck((select mode from booking.integration_config where key = 'resend') is distinct from 'live', 'G5: resend ei live');

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t132_r where ok), (select count(*) from t132_r where not ok),
    coalesce((select string_agg(label, ' | ') from t132_r where not ok), 'ALL OK');
end $t$;
