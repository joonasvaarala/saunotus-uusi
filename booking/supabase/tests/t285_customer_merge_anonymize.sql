-- t285: asiakkaiden yhdistäminen ja anonymisointi (booking_285). Paikallinen Postgres migraatioiden ja
-- fixtures/10_test_helpers.sql jälkeen:
--   cd booking/supabase/tests && psql -X -v ON_ERROR_STOP=1 -f t285_customer_merge_anonymize.sql
-- Yksi transaktio; lopussa rollback kumoaa kaiken (myös hetkellisesti päälle kytketyt kytkimet). Ei tuotantoon.
-- Kytkimiä customer_merge_enabled / customer_anonymize_enabled EI kytketä päälle pysyvästi: testi kytkee ne vain tässä transaktiossa.
\set ON_ERROR_STOP on
begin;
set local statement_timeout = '120s';
set local lock_timeout = '3s';
\ir ../migrations/20261113000050_booking_285_customer_merge_anonymize.sql

create function pg_temp.ck(ok boolean, label text) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'FAIL: %', label; end if;
  raise notice 'PASS: %', label;
end $$;
-- kutsun virhekoodi (BK001 detail) tai 'ok'
create function pg_temp.code(p_sql text) returns text language plpgsql as $$
declare d text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail; return coalesce(d, sqlstate);
end $$;
grant execute on function pg_temp.code(text), pg_temp.ck(boolean, text) to public;

do $test$
declare
  u_admin uuid := test.mk_staff('t285-admin@example.test', 'admin');
  u_mgr uuid := test.mk_staff('t285-manager@example.test', 'manager');
  u_staff uuid := test.mk_staff('t285-staff@example.test', 'staff');
  v_space bigint := (select id from booking.resources order by id limit 1);
  k bigint; m bigint; m2 bigint; a bigint; b bigint; c3 bigint; ko bigint; mo bigint; mo2 bigint; mo3 bigint; v_res bigint; v_seg bigint; v_camp bigint;
  v_card bigint; v_gc bigint; v_ic bigint; j jsonb; j2 jsonb; n int; h1 text; h2 text; v_log int; v_aud int;
begin
  -- ---------- oletukset ja oikeudet ----------
  perform pg_temp.ck((select value from booking.settings where key = 'customer_anonymize_enabled') = 'false'::jsonb, 'D1: customer_anonymize_enabled on oletuksena false');
  perform pg_temp.ck((select value from booking.settings where key = 'customer_merge_enabled') = 'false'::jsonb, 'D2: customer_merge_enabled on oletuksena false');
  perform pg_temp.ck((select array_agg(role_code order by role_code) from booking.role_permissions where permission = 'customers.admin') = array['admin','manager'], 'D3: customers.admin vain admin + manager');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_merge_customers(bigint,bigint,boolean,text)', 'execute')
    and has_function_privilege('authenticated', 'booking.admin_merge_customers(bigint,bigint,boolean,text)', 'execute')
    and not has_function_privilege('anon', 'booking.admin_anonymize_customer(bigint,text,boolean)', 'execute')
    and not has_function_privilege('authenticated', 'booking._customer_move_refs(bigint,bigint)', 'execute')
    and not has_function_privilege('authenticated', 'booking._customer_merge_plan(bigint,bigint)', 'execute')
    and not has_function_privilege('anon', 'booking.admin_merge_customers_preview(bigint,bigint)', 'execute')
    and not has_table_privilege('authenticated', 'booking.customer_merge_log', 'select')
    and not has_table_privilege('authenticated', 'booking.marketing_suppressions', 'select'), 'R1: anon ei, authenticated kyllä; sisäiset ja lokitaulut eivät kutsuttavissa');
  perform pg_temp.ck((select bool_and(p.prosecdef and p.proconfig @> array['search_path=""'])
      from pg_proc p where p.pronamespace = 'booking'::regnamespace and p.proname in ('admin_merge_customers','admin_merge_customers_preview','admin_anonymize_customer','admin_anonymize_customer_preview','admin_customer_admin_status')),
    'R2: SECURITY DEFINER + search_path tyhjä');

  -- ---------- testidata ----------
  insert into booking.customers (name, email, phone, notes, marketing_consent, marketing_consent_at, marketing_consent_source)
    values ('T285 Säilytettävä', 't285-keep@example.test', null, 'keep-muistiinpano', false, null, null) returning id into k;
  insert into booking.customers (name, email, phone, notes, marketing_consent, marketing_consent_at, marketing_consent_source, external_source, external_id, address, city)
    values ('T285 Yhdistettävä', 't285-merge@example.test', '+358400000285', 'merge-muistiinpano', true, now() - interval '30 days', 'web_booking', 'johku', '928501', 'Katu 1', 'Sipoo') returning id into m;
  set local session_replication_role = replica;
  insert into booking.orders (order_no, customer_id, status, payment_status, total_gross, locale, source_channel, customer_note, internal_note, created_at)
    values (928501, k, 'confirmed', 'paid', 50, 'fi', 'web', null, null, now() - interval '60 days') returning id into ko;
  insert into booking.orders (order_no, customer_id, status, payment_status, total_gross, locale, source_channel, customer_note, internal_note, created_at)
    values (928502, m, 'confirmed', 'paid', 80, 'fi', 'web', 'merge-asiakkaan toive', 'järjestelmähuomautus', now() - interval '50 days') returning id into mo;
  insert into booking.orders (order_no, customer_id, status, payment_status, total_gross, locale, source_channel, created_at)
    values (928503, m, 'confirmed', 'paid', 40, 'fi', 'web', now() - interval '40 days') returning id into mo2;
  insert into booking.reservations (order_id, space_id, mode, starts_at, ends_at, persons, status, notes)
    values (mo, v_space, 'shared', now() - interval '45 days', now() - interval '45 days' + interval '2 hours', 2, 'completed', 'varausmuistiinpano') returning id into v_res;
  insert into booking.payments (order_id, method, provider, status, amount, paid_at) values (mo, 'cash', 'manual', 'paid', 80, now() - interval '50 days'), (mo2, 'cash', 'manual', 'paid', 40, now() - interval '40 days'), (ko, 'cash', 'manual', 'paid', 50, now() - interval '60 days');
  insert into booking.gift_cards (code, initial_amount, balance, buyer_customer_id, buyer_name, buyer_email, status, kind, valid_to)
    values ('HHT285GI0001', 100, 100, m, 'Ostaja Nimi', 'ostaja@example.test', 'active', 'value', current_date + 200) returning id into v_gc;
  set local session_replication_role = origin;
  insert into booking.annual_cards (customer_id, valid_from, valid_to, active, code) values (m, current_date - 10, current_date + 100, true, 'T285-CARD1') returning id into v_card;
  perform pg_temp.ck((select customer_type from booking.customers where id = m) = 'annual_card', 'S0: vuosikortti asettaa asiakastyypin (lähtötila)');
  insert into booking.marketing_segments (name, filter) values ('T285 segmentti', '{}') returning id into v_seg;
  insert into booking.marketing_segment_members (segment_id, customer_id) values (v_seg, k), (v_seg, m);
  insert into booking.campaigns (name, kind) values ('T285 kampanja', 'manual') returning id into v_camp;
  insert into booking.campaign_sends (campaign_id, customer_id, email, status) values (v_camp, k, 't285-keep@example.test', 'sent'), (v_camp, m, 't285-merge@example.test', 'sent');
  insert into booking.invoice_customers (customer_id, company_name, email) values (m, 'T285 Laskuasiakas Oy', 't285-merge@example.test') returning id into v_ic;
  insert into booking.marketing_consent_events (customer_id, granted, at, source) values (m, true, now() - interval '30 days', 'web_booking');
  perform pg_temp.ck(v_res is not null and v_gc is not null and v_card is not null, 'S1: testidata luotu');

  -- ---------- oikeustarkistus: staff estetty, kytkin pois päältä ----------
  perform test.login(u_staff);
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_merge_customers_preview(%s,%s)', k, m)) = 'forbidden', 'P1: staff ei saa esikatselua');
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_merge_customers(%s,%s,true)', k, m)) = 'forbidden', 'P2: staff ei saa yhdistää');
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_anonymize_customer(%s,''syy'',true)', m)) = 'forbidden', 'P3: staff ei saa anonymisoida');
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_anonymize_customer_preview(%s)', m)) = 'forbidden', 'P4: staff ei saa anonymisoinnin esikatselua');
  j := booking.admin_customer_admin_status();
  perform pg_temp.ck((j ->> 'can_admin')::boolean = false and (j ->> 'merge_enabled')::boolean = false and (j ->> 'anonymize_enabled')::boolean = false, 'P5: tila: staff ei can_admin, kytkimet pois');
  perform test.logout();
  perform test.anon();
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_merge_customers(%s,%s,true)', k, m)) <> 'ok', 'P6: anon ei pääse');
  perform test.logout();
  perform test.login(u_admin);
  j := booking.admin_customer_admin_status();
  perform pg_temp.ck((j ->> 'can_admin')::boolean and not (j ->> 'merge_enabled')::boolean, 'P7: admin can_admin, yhdistäminen kytketty pois');
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_merge_customers(%s,%s,true)', k, m)) = 'merge_disabled', 'P8: kytkin pois → merge_disabled (admin)');
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_merge_customers_preview(%s,%s)', k, m)) = 'merge_disabled', 'P9: kytkin pois → esikatselu merge_disabled');
  perform test.logout();
  perform pg_temp.ck((select customer_id from booking.orders where id = mo) = m and (select merged_into from booking.customers where id = m) is null, 'P10: kytkin pois → mitään ei muutettu');

  -- kytketään yhdistäminen päälle vain tässä transaktiossa
  update booking.settings set value = 'true'::jsonb where key = 'customer_merge_enabled';
  perform test.login(u_staff);
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_merge_customers(%s,%s,true)', k, m)) = 'forbidden', 'P11: kytkin päällä, staff silti estetty');
  perform test.logout();

  -- ---------- esikatselu ei muuta mitään ----------
  perform test.login(u_mgr);
  j := booking.admin_merge_customers_preview(k, m);
  perform pg_temp.ck((j ->> 'ok')::boolean and not (j ->> 'applied')::boolean and (j -> 'counts' ->> 'orders')::int = 2 and (j -> 'counts' ->> 'gift_cards')::int = 1
    and (j -> 'counts' ->> 'annual_cards')::int = 1 and (j -> 'counts' ->> 'marketing_consent_events')::int >= 1 and (j -> 'counts' ->> 'marketing_segment_members')::int = 1
    and (j -> 'counts' ->> 'campaign_sends')::int = 1 and (j -> 'counts' ->> 'invoice_customers')::int = 1 and j ->> 'johku' = 'move_to_keep', 'E1: esikatselu (manager): laskurit ja Johku-päätös');
  perform pg_temp.ck(j -> 'consent' ->> 'action' = 'unchanged' and (j -> 'warnings') ? 'consent_not_inherited_other_email' and (j -> 'warnings') ? 'different_email', 'E2: eri osoite → suostumus ei periydy, varoitukset');
  j2 := booking.admin_merge_customers(k, m, false);
  perform pg_temp.ck(not (j2 ->> 'applied')::boolean, 'E3: p_confirm=false ei toteuta');
  perform test.logout();
  perform pg_temp.ck((select count(*) from booking.orders where customer_id = m) = 2 and (select anonymized_at from booking.customers where id = m) is null
    and (select count(*) from booking.customer_merge_log) = 0, 'E4: esikatselun jälkeen data ennallaan');

  -- ---------- virhetapaukset ----------
  perform test.login(u_admin);
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_merge_customers(%s,%s,true)', k, k)) = 'same_customer', 'V1: sama asiakas kahdesti (keep = merge) → same_customer');
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_merge_customers_preview(%s,%s)', k, k)) = 'same_customer', 'V2: sama asiakas, esikatselu');
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_merge_customers(%s,999999999,true)', k)) = 'not_found', 'V3: tuntematon asiakas');
  perform pg_temp.ck(pg_temp.code('select booking.admin_merge_customers(null,1,true)') = 'invalid_argument', 'V4: null-tunniste');
  perform test.logout();

  -- ---------- yhdistäminen ----------
  perform test.login(u_admin);
  j := booking.admin_merge_customers(k, m, true, 'T285 testi');
  perform test.logout();
  perform pg_temp.ck((j ->> 'applied')::boolean and not (j ->> 'already_merged')::boolean and (j ->> 'merge_log_id') is not null, 'M1: yhdistäminen toteutui');
  perform pg_temp.ck((select count(*) from booking.orders where customer_id = k) = 3 and (select count(*) from booking.orders where customer_id = m) = 0, 'M2: tilaukset siirtyivät');
  perform pg_temp.ck((select buyer_customer_id from booking.gift_cards where id = v_gc) = k, 'M3: lahjakortti siirtyi (ostaja)');
  perform pg_temp.ck((select customer_id from booking.annual_cards where id = v_card) = k and (select customer_type from booking.customers where id = k) = 'annual_card'
    and (select customer_type from booking.customers where id = m) = 'customer', 'M4: vuosikortti siirtyi, tyypit päivittyivät');
  perform pg_temp.ck((select count(*) from booking.marketing_consent_events where customer_id = m and granted and source = 'web_booking') = 0
    and (select count(*) from booking.marketing_consent_events where customer_id = k and granted and source = 'web_booking') = 2, 'M5: suostumushistoria siirtyi');
  perform pg_temp.ck((select count(*) from booking.marketing_segment_members where customer_id = k) = 1 and (select count(*) from booking.marketing_segment_members where customer_id = m) = 1, 'M6: segmenttijäsenyys: päällekkäinen jää hautakivelle (ei duplikaattia)');
  perform pg_temp.ck((select count(*) from booking.campaign_sends where campaign_id = v_camp and customer_id = k) = 1 and (select count(*) from booking.campaign_sends where campaign_id = v_camp and customer_id = m) = 1
    and (j -> 'moved' -> 'campaign_sends' ->> 'left')::int = 1, 'M7: uniikkirajoitus (sama kampanja) ei kaada yhdistämistä, jäännös raportoitu');
  perform pg_temp.ck((select external_source from booking.customers where id = k) = 'johku' and (select external_id from booking.customers where id = k) = '928501'
    and (select external_id from booking.customers where id = m) is null, 'M8: Johku-tunniste siirtyi säilytettävälle');
  perform pg_temp.ck((select phone from booking.customers where id = k) = '+358400000285' and (select city from booking.customers where id = k) = 'Sipoo'
    and (select notes from booking.customers where id = k) like 'keep-muistiinpano%merge-muistiinpano' , 'M9: tyhjät kentät täytetty, muistiinpano liitetty');
  perform pg_temp.ck((select marketing_consent from booking.customers where id = k) = false and (select marketing_consent from booking.customers where id = m) = false, 'M10: suostumus ei periydy toiselle osoitteelle; hautakivellä ei suostumusta');
  perform pg_temp.ck((select anonymized_at is not null and merged_into = k and email is null and phone is null and notes is null and name = 'Yhdistetty asiakas #' || m from booking.customers where id = m), 'M11: hautakivi: ei henkilötietoja, merged_into asetettu');
  perform pg_temp.ck((select count(*) from booking.customer_merge_log where keep_id = k and merge_id = m) = 1
    and (select merge_snapshot ->> 'email' from booking.customer_merge_log where merge_id = m) = 't285-merge@example.test'
    and (select moved -> 'orders' ->> 'moved' from booking.customer_merge_log where merge_id = m) = '2', 'M12: yhdistämisloki + snapshot');
  perform pg_temp.ck((select count(*) from booking.audit_log where table_name = 'customers' and row_pk = k::text and action = 'MERGE') = 1
    and (select count(*) from booking.audit_log where table_name = 'customers' and row_pk = m::text and action = 'MERGED_INTO') = 1, 'M13: audit_log MERGE + MERGED_INTO');
  perform pg_temp.ck((select count(*) from booking.audit_log where table_name = 'orders' and row_pk = mo::text and action = 'UPDATE' and new_data ->> 'customer_id' = k::text) >= 1, 'M14: tilauksen siirto näkyy audit_logissa');
  perform pg_temp.ck(not booking.is_email_suppressed('t285-merge@example.test'), 'M15: suostumuksellisen asiakkaan osoitetta ei merkitä suppressioon');
  perform pg_temp.ck((select customer_id from booking.invoice_customers where id = v_ic) = k, 'M17: laskuasiakas siirtyi');
  perform pg_temp.ck((select count(*) from booking.reservations where order_id = mo) = 1 and (select order_id from booking.reservations where id = v_res) = mo, 'M16: tilauksen varaukset säilyvät tilauksella');

  -- ---------- idempotenssi ----------
  select count(*) into v_log from booking.customer_merge_log; select count(*) into v_aud from booking.audit_log where action in ('MERGE', 'MERGED_INTO');
  perform test.login(u_admin);
  j := booking.admin_merge_customers(k, m, true);
  perform test.logout();
  perform pg_temp.ck((j ->> 'already_merged')::boolean and not (j ->> 'applied')::boolean, 'I1: toinen kutsu → already_merged');
  perform pg_temp.ck((select count(*) from booking.customer_merge_log) = v_log and (select count(*) from booking.audit_log where action in ('MERGE', 'MERGED_INTO')) = v_aud, 'I2: ei uutta lokia eikä audit-riviä');
  perform test.login(u_admin);
  -- välissä syntynyt jäännösviittaus siirtyy
  perform test.logout();
  set local session_replication_role = replica;
  insert into booking.orders (order_no, customer_id, status, payment_status, total_gross, locale, source_channel) values (928504, m, 'confirmed', 'paid', 10, 'fi', 'web') returning id into mo3;
  set local session_replication_role = origin;
  perform test.login(u_admin);
  j := booking.admin_merge_customers(k, m, true);
  perform pg_temp.ck((select customer_id from booking.orders where id = mo3) = k and (j -> 'swept' -> 'orders' ->> 'moved')::int = 1, 'I3: jäännöstilaus siirtyy uudelleenajossa');
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_merge_customers(%s,%s,true)', m, k)) = 'merge_blocked', 'I4: käänteinen yhdistäminen estetty (hautakivi)');
  perform test.logout();

  -- ---------- estot ----------
  insert into booking.customers (name, email, customer_kind, business_id, company) values ('T285 Yritys', 't285-co@example.test', 'company', '0112038-9', 'T285 Oy') returning id into c3;
  perform test.login(u_admin);
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_merge_customers(%s,%s,true)', k, c3)) = 'merge_blocked', 'B1: yritys + yksityinen estetty (kind_mismatch)');
  perform pg_temp.ck(booking.admin_merge_customers_preview(k, c3) -> 'blockers' ? 'kind_mismatch', 'B2: esikatselu listaa kind_mismatch');
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_merge_customers(%s,%s,true)', c3, k)) = 'merge_blocked', 'B3: hautakiveä ei voi yhdistää toiseen (merge_anonymized/keep)');
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_merge_customers(%s,%s,true)', m, c3)) = 'merge_blocked', 'B4: hautakivi ei voi olla säilytettävä');
  perform test.logout();
  -- päällekkäiset aktiiviset vuosikortit
  insert into booking.customers (name, email) values ('T285 Kortti A', 't285-a@example.test') returning id into a;
  insert into booking.customers (name, email) values ('T285 Kortti B', 't285-b@example.test') returning id into b;
  insert into booking.annual_cards (customer_id, valid_from, valid_to, active, code) values (a, current_date, current_date + 50, true, 'T285-CARDA'), (b, current_date + 10, current_date + 60, true, 'T285-CARDB');
  perform test.login(u_admin);
  perform pg_temp.ck(booking.admin_merge_customers_preview(a, b) -> 'blockers' ? 'annual_card_overlap', 'B5: päällekkäiset aktiiviset vuosikortit estävät');
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_merge_customers(%s,%s,true)', a, b)) = 'merge_blocked', 'B6: yhdistäminen estetty');
  perform test.logout();
  perform pg_temp.ck((select count(*) from booking.annual_cards where customer_id = b) = 1 and (select merged_into from booking.customers where id = b) is null, 'B7: estetty yhdistäminen ei muuttanut mitään');

  -- ---------- suostumussäännöt ----------
  -- peruutus voittaa; peruttu osoite jää suppressioon, kun se poistuu riviltä
  insert into booking.customers (name, email, marketing_consent, marketing_consent_at, marketing_consent_source) values ('T285 K2', 't285-k2@example.test', true, now() - interval '5 days', 'web_booking') returning id into a;
  insert into booking.customers (name, email, marketing_consent, marketing_consent_at, marketing_unsubscribed_at) values ('T285 M2', 't285-m2@example.test', false, now() - interval '90 days', now() - interval '10 days') returning id into b;
  perform test.login(u_admin);
  j := booking.admin_merge_customers(a, b, true);
  perform test.logout();
  perform pg_temp.ck(j -> 'consent' ->> 'action' = 'unsubscribe_wins' and (j -> 'warnings') ? 'consent_removed_unsubscribed', 'C1: peruutus voittaa, varoitus näkyy');
  perform pg_temp.ck((select marketing_consent from booking.customers where id = a) = false and (select marketing_unsubscribed_at from booking.customers where id = a) is not null, 'C2: säilytettävän suostumus poistui, peruutusaika asetettu');
  perform pg_temp.ck(booking.is_email_suppressed('T285-M2@example.test ') and not booking.is_email_suppressed('t285-k2@example.test') is null, 'C3: peruttu osoite suppressiossa (kirjainkoko ja välilyönnit ohitetaan)');
  perform pg_temp.ck((select count(*) from booking.marketing_consent_events where customer_id = a and granted = false) >= 1, 'C4: peruutus kirjautui suostumushistoriaan (customers_consent-trigger)');
  -- suostumus periytyy samalle osoitteelle
  insert into booking.customers (name, email) values ('T285 K3', 'T285-SAMA@example.test') returning id into a;
  insert into booking.customers (name, email, marketing_consent, marketing_consent_at, marketing_consent_source, marketing_consent_text_version)
    values ('T285 M3', 't285-sama@example.test', true, now() - interval '3 days', 'newsletter_form', 'v2') returning id into b;
  perform test.login(u_admin);
  j := booking.admin_merge_customers(a, b, true);
  perform test.logout();
  perform pg_temp.ck(j -> 'consent' ->> 'action' = 'inherit_consent' and (select marketing_consent from booking.customers where id = a)
    and (select marketing_consent_source from booking.customers where id = a) = 'newsletter_form' and (select marketing_consent_text_version from booking.customers where id = a) = 'v2', 'C5: sama osoite → suostumus periytyy lähteineen');
  perform pg_temp.ck((select marketing_consent from booking.customers where id = b) = false, 'C6: hautakivellä ei suostumusta');

  -- ---------- anonymisointi: kytkin pois ----------
  insert into booking.customers (name, email, phone, notes, marketing_consent, marketing_consent_at, marketing_consent_source, address, city)
    values ('T285 Anonyymi', 't285-anon@example.test', '+358400000999', 'arkaluontoinen muistiinpano', true, now() - interval '400 days', 'web_booking', 'Tie 5', 'Sipoo') returning id into a;
  set local session_replication_role = replica;
  insert into booking.orders (order_no, customer_id, status, payment_status, total_gross, locale, source_channel, customer_note, internal_note, created_at)
    values (928510, a, 'confirmed', 'paid', 70, 'fi', 'web', 'henkilökohtainen toive', 'sisäinen huomio', now() - interval '300 days') returning id into ko;
  insert into booking.reservations (order_id, space_id, mode, starts_at, ends_at, persons, status, notes)
    values (ko, v_space, 'shared', now() - interval '290 days', now() - interval '290 days' + interval '2 hours', 2, 'completed', 'allergia: pähkinä') returning id into v_res;
  insert into booking.payments (order_id, method, provider, status, amount, paid_at) values (ko, 'cash', 'manual', 'paid', 70, now() - interval '300 days');
  insert into booking.gift_cards (code, initial_amount, balance, buyer_customer_id, buyer_name, buyer_email, status, kind, valid_to)
    values ('HHT285GI0002', 50, 0, a, 'Anonyymi Ostaja', 'anon-ostaja@example.test', 'used', 'value', current_date + 10);
  set local session_replication_role = origin;
  update booking.customers set notes = 'päivitetty muistiinpano' where id = a;   -- tuottaa audit-rivin, jossa on henkilötietoja
  perform pg_temp.ck(exists (select 1 from booking.audit_log where table_name = 'customers' and row_pk = a::text and new_data ->> 'email' = 't285-anon@example.test'), 'A0: audit_logissa on henkilötietoja ennen anonymisointia');
  select md5(to_jsonb(x)::text) into h1 from booking.customers x where id = a;
  select count(*) into v_aud from booking.audit_log;
  perform test.login(u_admin);
  j := booking.admin_customer_admin_status();
  perform pg_temp.ck((j ->> 'can_admin')::boolean and not (j ->> 'anonymize_enabled')::boolean, 'A1: admin can_admin, anonymisointi kytketty pois');
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_anonymize_customer(%s,''testisyy'',true)', a)) = 'anonymize_disabled', 'A2: kytkin pois → anonymize_disabled (admin, p_confirm=true)');
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_anonymize_customer(%s,''testisyy'',false)', a)) = 'anonymize_disabled', 'A3: kytkin pois → virhe myös ilman vahvistusta');
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_anonymize_customer_preview(%s)', a)) = 'anonymize_disabled', 'A4: kytkin pois → esikatselu virhe');
  perform test.logout();
  select md5(to_jsonb(x)::text) into h2 from booking.customers x where id = a;
  perform pg_temp.ck(h1 = h2 and (select count(*) from booking.audit_log) = v_aud and (select anonymized_at from booking.customers where id = a) is null
    and (select customer_note from booking.orders where id = ko) = 'henkilökohtainen toive' and (select count(*) from booking.marketing_suppressions where customer_id = a) = 0, 'A5: kytkin pois → mikään ei muuttunut (rivi, audit, tilaus, suppression)');
  perform test.login(u_mgr);
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_anonymize_customer(%s,''testisyy'',true)', a)) = 'anonymize_disabled', 'A6: kytkin pois → manageriltakin virhe');
  perform test.logout();

  -- ---------- anonymisointi: kytkin hetkellisesti päällä tässä transaktiossa ----------
  update booking.settings set value = 'true'::jsonb where key = 'customer_anonymize_enabled';
  perform test.login(u_staff);
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_anonymize_customer(%s,''testisyy'',true)', a)) = 'forbidden', 'A7: kytkin päällä, staff silti estetty');
  perform test.logout();
  perform test.login(u_admin);
  perform pg_temp.ck(pg_temp.code(format('select booking.admin_anonymize_customer(%s,null,true)', a)) = 'reason_required', 'A8: syy vaaditaan');
  j := booking.admin_anonymize_customer_preview(a);
  perform pg_temp.ck((j ->> 'ok')::boolean and not (j ->> 'applied')::boolean and (j -> 'counts' ->> 'orders')::int = 1 and (j ->> 'suppression')::boolean, 'A9: esikatselu: laskurit, suppression ilmoitettu');
  perform pg_temp.ck(not (booking.admin_anonymize_customer(a, 'testisyy', false) ->> 'applied')::boolean and (select anonymized_at from booking.customers where id = a) is null, 'A10: p_confirm=false ei toteuta');
  -- tuleva varaus estää
  perform test.logout();
  set local session_replication_role = replica;
  insert into booking.reservations (order_id, space_id, mode, starts_at, ends_at, persons, status)
    values (ko, v_space, 'shared', now() + interval '5 days', now() + interval '5 days 2 hours', 2, 'confirmed') returning id into mo3;
  set local session_replication_role = origin;
  perform test.login(u_admin);
  perform pg_temp.ck(booking.admin_anonymize_customer_preview(a) -> 'blockers' ? 'future_reservations'
    and pg_temp.code(format('select booking.admin_anonymize_customer(%s,''testisyy'',true)', a)) = 'anonymize_blocked', 'A11: tuleva varaus estää anonymisoinnin');
  perform test.logout();
  delete from booking.reservations where id = mo3;
  perform test.login(u_admin);
  j := booking.admin_anonymize_customer(a, 'T285 testisyy', true);
  perform test.logout();
  perform pg_temp.ck((j ->> 'applied')::boolean, 'A12: anonymisointi toteutui');
  perform pg_temp.ck((select name = 'Anonymisoitu asiakas' and email is null and phone is null and address is null and city is null and notes is null
                             and anonymized_at is not null and marketing_consent = false from booking.customers where id = a), 'A13: asiakkaan henkilötiedot poistettu');
  perform pg_temp.ck((select customer_note is null and internal_note is null and total_gross = 70 and customer_id = a from booking.orders where id = ko)
    and (select notes is null from booking.reservations where id = v_res)
    and (select count(*) from booking.payments where order_id = ko and amount = 70 and status = 'paid') = 1, 'A14: tilaus, summa ja maksu säilyivät; vapaat tekstit poistettu');
  perform pg_temp.ck((select buyer_name is null and buyer_email is null from booking.gift_cards where code = 'HHT285GI0002'), 'A15: lahjakortin ostajan tiedot poistettu, kortti säilyy');
  perform pg_temp.ck(booking.is_email_suppressed('t285-anon@example.test') and (select reason from booking.marketing_suppressions where customer_id = a) = 'anonymized', 'A16: uutiskirjeen suppression säilyy (osoite ei palaa listalle)');
  perform pg_temp.ck((select count(*) from booking.marketing_consent_events where customer_id = a) >= 1, 'A17: suostumushistoria säilyy');
  perform pg_temp.ck(not exists (select 1 from booking.audit_log where table_name = 'customers' and row_pk = a::text and (old_data ?| array['email','name','phone','notes','address'] or new_data ?| array['email','name','phone','notes','address']))
    and not exists (select 1 from booking.audit_log where table_name in ('orders','reservations') and row_pk in (ko::text, v_res::text) and (old_data::text like '%henkilökohtainen%' or new_data::text like '%allergia%')), 'A18: audit_login henkilötiedot poistettu');
  perform pg_temp.ck((select count(*) from booking.audit_log where table_name = 'customers' and row_pk = a::text and action = 'ANONYMIZE') = 1, 'A19: ANONYMIZE-audit-rivi');
  select count(*) into v_aud from booking.audit_log;
  perform test.login(u_admin);
  j := booking.admin_anonymize_customer(a, 'uusi yritys', true);
  perform test.logout();
  perform pg_temp.ck((j ->> 'already_anonymized')::boolean and not (j ->> 'applied')::boolean and (select count(*) from booking.audit_log) = v_aud, 'A20: idempotentti: toinen kutsu ei tee mitään');
  -- maksamaton tilaus estää
  insert into booking.customers (name, email) values ('T285 Velallinen', 't285-debt@example.test') returning id into b;
  set local session_replication_role = replica;
  insert into booking.orders (order_no, customer_id, status, payment_status, total_gross, locale, source_channel) values (928511, b, 'confirmed', 'unpaid', 90, 'fi', 'web');
  set local session_replication_role = origin;
  perform test.login(u_admin);
  perform pg_temp.ck(booking.admin_anonymize_customer_preview(b) -> 'blockers' ? 'unpaid_orders'
    and pg_temp.code(format('select booking.admin_anonymize_customer(%s,''testisyy'',true)', b)) = 'anonymize_blocked', 'A21: maksamaton tilaus estää anonymisoinnin');
  -- yhdistetty hautakivi on jo anonymisoitu → idempotentti
  j := booking.admin_anonymize_customer(m, 'hautakivi', true);
  perform pg_temp.ck((j ->> 'already_anonymized')::boolean, 'A22: hautakivi on jo anonymisoitu');
  perform test.logout();

  -- ---------- säilytettävän asiakkaan anonymisointi poistaa yhdistämislokin snapshotin ----------
  insert into booking.customers (name, email, phone) values ('T285 L-keep', 't285-lk@example.test', '+358400000111') returning id into a;
  insert into booking.customers (name, email, phone) values ('T285 L-merge', 't285-lm@example.test', '+358400000222') returning id into b;
  perform test.login(u_admin);
  perform booking.admin_merge_customers(a, b, true);
  perform test.logout();
  perform pg_temp.ck((select merge_snapshot ->> 'phone' from booking.customer_merge_log where merge_id = b) = '+358400000222', 'L1: snapshot sisältää yhdistetyn tiedot');
  perform test.login(u_admin);
  perform booking.admin_anonymize_customer(a, 'T285 L-testi', true);
  perform test.logout();
  perform pg_temp.ck((select merge_snapshot from booking.customer_merge_log where merge_id = b) is null, 'L2: keep-asiakkaan anonymisointi tyhjentää snapshotin');
  perform pg_temp.ck(not exists (select 1 from booking.audit_log where table_name = 'customers' and row_pk = a::text and (old_data ?| array['email','name','phone'] or new_data ?| array['email','name','phone'])), 'L3: keep-asiakkaan audit-rivit siivottu');

  raise notice 'KAIKKI t285-TESTIT OK';
end
$test$;
rollback;
