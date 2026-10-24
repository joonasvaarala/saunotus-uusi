-- t157: tietosuojan säilytysajat (booking_157).
-- 3 v raja (2 v 11 kk ei, 3 v 1 kk kyllä), 6 v tilikausiraja (31.12. vs 1.1., tilikauden päättymispäivä asetuksena), turvapoikkeukset
-- (aktiivinen lahjakortti, aktiivinen vuosikortti, tuleva varaus, avoin maksu, markkinointilupa), kuivaharjoitus ilman sivuvaikutuksia,
-- ajo vain admin/service ja vain kun privacy_retention.enabled = true, kirjanpitolukkojen kapea poikkeus, audit_login henkilöavaimet,
-- kävijämittauksen kuukausikooste (summat täsmäävät, k-anonymiteetti < 5 yhdistetään) ja pitkän aikavälin raportti.
-- Rollbackin palautus: t157_privacy_retention_rollback.psql. Kaikki data on feikkiä (id-alue 915700–915799).
-- Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN yhdessä transaktiossa; tulos: TESTRESULT pass=… fail=…
set local lock_timeout = '3s';
set local statement_timeout = '120s';
create temp table t157_r(ok boolean, label text) on commit drop;
grant all on t157_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t157_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return null; exception when others then return coalesce(nullif(sqlerrm, ''), sqlstate); end $$;
-- Taulujen sisällön sormenjälki (sivuvaikutustesti).
create function pg_temp.fp() returns text language sql as $$
  select md5(concat_ws('|',
    (select string_agg(t::text, ',' order by id) from booking.customers t),
    (select string_agg(t::text, ',' order by id) from booking.orders t),
    (select string_agg(t::text, ',' order by id) from booking.reservations t),
    (select string_agg(t::text, ',' order by id) from booking.payments t),
    (select string_agg(t::text, ',' order by id) from booking.receipts t),
    (select string_agg(t::text, ',' order by id) from booking.invoices t),
    (select string_agg(t::text, ',' order by id) from booking.gift_cards t),
    (select string_agg(t::text, ',' order by id) from booking.annual_cards t),
    (select string_agg(t::text, ',' order by id) from booking.email_outbox t),
    (select string_agg(t::text, ',' order by id) from booking.audit_log t),
    (select string_agg(t::text, ',' order by id) from booking.analytics_events t),
    (select string_agg(t::text, ',' order by month, kind, event_type, path) from booking.analytics_monthly t),
    (select count(*)::text from booking.privacy_retention_runs))) $$;

-- ---------- fixtuurit (triggerit pois vain lisäyksen ajaksi) ----------
set local session_replication_role = replica;
delete from booking.analytics_events; delete from booking.analytics_monthly;
insert into booking.customers(id, name, email, phone, created_at, customer_kind, company, business_id, marketing_consent, marketing_consent_at)
overriding system value values
  (915701, 'T157 Vanha', 't157-vanha@example.invalid', '+358401570001', now() - interval '3 years 1 month', 'private', null, null, false, null),
  (915702, 'T157 Tuore', 't157-tuore@example.invalid', '+358401570002', now() - interval '2 years 11 months', 'private', null, null, false, null),
  (915703, 'T157 Lahjakortti', 't157-lk@example.invalid', null, now() - interval '5 years', 'private', null, null, false, null),
  (915704, 'T157 Vuosikortti', 't157-vk@example.invalid', null, now() - interval '5 years', 'private', null, null, false, null),
  (915705, 'T157 Tuleva', 't157-tuleva@example.invalid', null, now() - interval '5 years', 'private', null, null, false, null),
  (915706, 'T157 Avoin maksu', 't157-avoin@example.invalid', null, now() - interval '5 years', 'private', null, null, false, null),
  (915707, 'T157 Lupa', 't157-lupa@example.invalid', null, now() - interval '5 years', 'private', null, null, true, now() - interval '5 years'),
  (915708, 'T157 Yritys Yhteyshenkilö', 't157-yritys@example.invalid', '+358401570008', now() - interval '5 years', 'company', 'T157 Oy', '1234567-1', false, null),
  (915709, 'T157 Kirjanpito', 't157-kp@example.invalid', null, '2019-06-01 09:00+03', 'private', null, null, false, null),
  (915710, 'T157 Uusivuosi', 't157-uv@example.invalid', null, '2020-12-31 12:00+02', 'private', null, null, false, null);
insert into booking.orders(id, order_no, customer_id, status, payment_status, total_gross, created_at, confirmed_at, customer_note, internal_note, billing, invoice_reference)
overriding system value values
  (915711, 915711, 915701, 'completed', 'paid', 50, now() - interval '3 years 1 month', now() - interval '3 years 1 month', 'T157 toive', 'T157 sisäinen', '{"name":"T157 Vanha","email":"t157-vanha@example.invalid","phone":"+358401570001","address":"Testitie 1"}', null),
  (915712, 915712, 915702, 'completed', 'paid', 50, now() - interval '2 years 11 months', null, 'T157 tuore toive', null, null, null),
  (915715, 915715, 915705, 'confirmed', 'paid', 50, now() - interval '5 years', null, 'T157 tuleva toive', null, '{"email":"t157-tuleva@example.invalid"}', null),
  (915716, 915716, 915706, 'confirmed', 'paid', 50, now() - interval '5 years', null, 'T157 avoin toive', null, null, null),
  (915719, 915719, 915709, 'completed', 'paid', 100, '2019-06-01 10:00+03', '2019-06-01 10:00+03', 'T157 2019 toive', null, '{"name":"T157 Kirjanpito","email":"t157-kp@example.invalid","address":"Testitie 9"}', 'T157-VIITE'),
  (915720, 915720, 915710, 'completed', 'paid', 100, '2020-12-31 12:00+02', '2020-12-31 12:00+02', 'T157 2020 toive', null, '{"name":"T157 Uusivuosi","email":"t157-uv@example.invalid","address":"Testitie 10"}', 'T157-VIITE2'),
  (915721, 915721, null, 'completed', 'paid', 100, '2018-03-01 10:00+02', '2018-03-01 10:00+02', 'T157 tuleva 2018', null, '{"name":"T157 Ennakko","email":"t157-ennakko@example.invalid"}', null);
insert into booking.reservations(id, order_id, space_id, mode, starts_at, ends_at, persons, status, notes)
overriding system value values
  (915731, 915711, (select min(id) from booking.resources), 'exclusive', now() - interval '3 years 1 month', now() - interval '3 years 1 month' + interval '2 hours', 2, 'completed', 'T157 allergia'),
  (915735, 915715, (select min(id) from booking.resources), 'exclusive', now() + interval '20 days', now() + interval '20 days 2 hours', 2, 'confirmed', 'T157 tuleva huomio'),
  (915741, 915721, (select min(id) from booking.resources), 'exclusive', now() + interval '30 days', now() + interval '30 days 2 hours', 2, 'confirmed', 'T157 ennakko huomio');
insert into booking.payments(id, order_id, method, amount, status, created_at, paid_at, raw, note)
overriding system value values
  (915751, 915716, 'card_terminal', 50, 'pending', now() - interval '5 years', null, '{"payer":"t157-avoin@example.invalid"}', 'T157 avoin'),
  (915752, 915719, 'card_terminal', 100, 'paid', '2019-06-01 10:00+03', '2019-06-01 10:00+03', '{"payer":"t157-kp@example.invalid"}', 'T157 maksu'),
  (915753, 915720, 'card_terminal', 100, 'paid', '2020-12-31 12:00+02', '2020-12-31 12:00+02', '{"payer":"t157-uv@example.invalid"}', 'T157 maksu 2020');
insert into booking.receipts(id, receipt_no, kind, series, year, seq, order_id, payment_id, issued_at, total_gross, snapshot, text_body)
overriding system value values
  (915761, 'K-2019-T157-1', 'receipt', 'T157', 2019, 1, 915719, 915752, '2019-06-01 10:00+03', 100,
   '{"seller":{"name":"T157 Myyjä"},"buyer":{"name":"T157 Kirjanpito","email":"t157-kp@example.invalid"},"total_net":79.68,"total_vat":20.32,"total_gross":100,"lines":[{"description":"t157 sauna","quantity":1,"line_gross":100,"line_net":79.68,"vat_rate":25.5}],"payment":{"method_label":"Kortti"}}', 'T157 vanha teksti'),
  (915762, 'K-2020-T157-2', 'receipt', 'T157', 2020, 2, 915720, 915753, '2020-12-31 12:00+02', 100,
   '{"seller":{"name":"T157 Myyjä"},"buyer":{"name":"T157 Uusivuosi"},"total_net":79.68,"total_vat":20.32,"total_gross":100,"lines":[],"payment":{"method_label":"Kortti"}}', 'T157 teksti 2020');
insert into booking.invoice_customers(id, customer_id, company_name, contact_name, email, business_id, country, updated_at)
overriding system value values
  (915773, 915709, 'T157 Kirjanpito Tmi', 'T157 Kirjanpito', 't157-kp@example.invalid', '1234567-1', 'FI', '2019-06-01 10:00+03'),
  (915774, 915710, 'T157 Uusivuosi Tmi', 'T157 Uusivuosi', 't157-uv@example.invalid', null, 'FI', '2020-12-31 12:00+02');
insert into booking.invoices(id, customer_id, order_id, status, invoice_date, due_date, seller_snapshot, customer_snapshot, notes, buyer_reference, series, seq, invoice_no, paid_at, sent_at, total_net, total_vat, total_gross, created_at)
overriding system value values
  (915771, 915773, 915719, 'paid', '2019-06-01', '2019-06-15', '{"name":"T157 Myyjä"}', '{"name":"T157 Kirjanpito","email":"t157-kp@example.invalid"}', 'T157 laskun huomio', 'T157-OSTAJA', 'L', 915771, 'T157-1', '2019-06-10 10:00+03', '2019-06-01 10:00+03', 79.68, 20.32, 100, '2019-06-01 10:00+03'),
  (915772, 915774, 915720, 'paid', '2020-12-31', '2020-12-31', '{"name":"T157 Myyjä"}', '{"name":"T157 Uusivuosi"}', 'T157 huomio 2020', null, 'L', 915772, 'T157-2', '2020-12-31 12:00+02', '2020-12-31 12:00+02', 79.68, 20.32, 100, '2020-12-31 12:00+02');
insert into booking.gift_cards(id, code, initial_amount, balance, status, valid_to, buyer_customer_id, buyer_name, buyer_email, created_at)
overriding system value values
  (915781, 'HH157AAAAAA1', 50, 50, 'active', current_date + 100, 915703, 'T157 Lahjakortti', 't157-lk@example.invalid', now() - interval '5 years'),
  (915782, 'HH157AAAAAA2', 50, 50, 'active', null, 915703, 'T157 Lahjakortti', 't157-lk@example.invalid', now() - interval '5 years'),
  (915783, 'HH157AAAAAA3', 50, 0, 'used', current_date - interval '4 years', 915701, 'T157 Vanha', 't157-vanha@example.invalid', now() - interval '5 years'),
  (915784, 'HH157AAAAAA4', 50, 50, 'active', (now() - interval '3 years 2 months')::date, null, 'T157 Vanhentunut', 't157-vanh@example.invalid', now() - interval '5 years');
insert into booking.annual_cards(id, customer_id, valid_from, valid_to, code, active, notes, created_at)
overriding system value values
  (915791, 915704, current_date - 300, current_date + 65, 'T157-VK-1', true, 'T157 vuosikortin huomio', now() - interval '5 years'),
  (915792, 915701, current_date - interval '5 years', current_date - interval '4 years', 'T157-VK-2', false, 'T157 vanha vuosikortti', now() - interval '5 years');
insert into booking.email_outbox(id, kind, dedupe_key, status, payload, created_at)
overriding system value values
  (915795, 'receipt', 't157-1', 'sent', '{"to":"t157-vanha@example.invalid","name":"T157"}', now() - interval '37 months'),  -- booking_160: 3 v
  (915796, 'receipt', 't157-2', 'pending', '{"to":"t157-odottaa@example.invalid"}', now() - interval '13 months'),
  (915797, 'receipt', 't157-3', 'sent', '{"to":"t157-tuore@example.invalid"}', now() - interval '11 months');
insert into booking.audit_log(id, table_name, action, row_pk, old_data, new_data, at)
overriding system value values
  (915798, 'customers', 'UPDATE', '915702', '{"name":"T157 Vanha audit","email":"t157-a@example.invalid","language":"fi"}', '{"name":"T157 Uusi","language":"fi"}', now() - interval '3 years 2 months'),
  (915799, 'customers', 'UPDATE', '915702', '{"name":"T157 Tuore audit"}', '{"name":"T157 Tuore audit 2"}', now() - interval '1 year');
-- Kävijätapahtumat 14 kk sitten: /a 7 istuntoa (jää omaksi ryhmäkseen), /b 2 ja /c 1 (yhdistetään), 1 osto.
insert into booking.analytics_events(session_key, event_type, path, locale, device_type, source_category, event_date, created_at, order_id, amount_gross)
select lpad(to_hex(g), 8, '0') || '-0000-4157-8000-' || lpad(to_hex(g), 12, '0'), 'page_view', '/a', 'fi', 'mobile', 'direct', (current_date - interval '14 months')::date, now() - interval '14 months', null::bigint, null::numeric from generate_series(1, 7) g
union all select lpad(to_hex(g), 8, '0') || '-0000-4157-8000-' || lpad(to_hex(g), 12, '0'), 'page_view', '/b', 'en', 'desktop', 'google_search', (current_date - interval '14 months')::date, now() - interval '14 months', null, null from generate_series(8, 9) g
union all select lpad(to_hex(10), 8, '0') || '-0000-4157-8000-' || lpad(to_hex(10), 12, '0'), 'page_view', '/c', 'en', 'tablet', 'social', (current_date - interval '14 months')::date, now() - interval '14 months', null, null
union all select lpad(to_hex(1), 8, '0') || '-0000-4157-8000-' || lpad(to_hex(1), 12, '0'), 'purchase', '/kiitos', 'fi', 'mobile', 'direct', (current_date - interval '14 months')::date, now() - interval '14 months', 915711, 50
union all select lpad(to_hex(11), 8, '0') || '-0000-4157-8000-' || lpad(to_hex(11), 12, '0'), 'page_view', '/a', 'fi', 'mobile', 'direct', current_date - 1, now() - interval '1 day', null, null;
set local session_replication_role = origin;

do $t$
declare j jsonb; r jsonb; v_fp text; v_n int; u_admin uuid := test.mk_staff('t157-admin@example.invalid', 'admin');
        u_user uuid := test.mk_user('t157-user@example.invalid'); v_txt text; v_cnt int;
begin
  -- ===== A: apufunktiot ja tilikausiraja =====
  perform pg_temp.ck(booking._privacy_acct_year('2020-12-31') = 2020 and booking._privacy_acct_year('2021-01-01') = 2021, 'A1 kalenteritilikausi');
  perform pg_temp.ck(not booking._privacy_acct_due('2020-12-31', '2026-12-31') and booking._privacy_acct_due('2020-12-31', '2027-01-01'), 'A2 6 v: 31.12.2020 → vapautuu vasta 1.1.2027');
  perform pg_temp.ck(booking._privacy_acct_due('2019-06-01', '2026-01-01'), 'A3 2019 vapautuu 2026');
  update booking.settings set value = '"06-30"' where key = 'privacy_retention.fiscal_year_end';
  perform pg_temp.ck(booking._privacy_acct_year('2020-06-30') = 2020 and booking._privacy_acct_year('2020-07-01') = 2021, 'A4 tilikausi 1.7.–30.6.');
  perform pg_temp.ck(not booking._privacy_acct_due('2020-07-01', '2027-06-30') and booking._privacy_acct_due('2020-07-01', '2028-01-01'), 'A5 tilikausi 6/2021 → vapautuu 2028');
  update booking.settings set value = '"13-45"' where key = 'privacy_retention.fiscal_year_end';
  perform pg_temp.ck(booking._privacy_fy_end_mmdd() = '12-31', 'A6 virheellinen asetus → 12-31');
  update booking.settings set value = '"12-31"' where key = 'privacy_retention.fiscal_year_end';
  perform pg_temp.ck((select value from booking.settings where key = 'privacy_retention.enabled') = 'false'::jsonb, 'A7 ajo oletuksena pois päältä');

  -- ===== R: kuivaharjoitus =====
  v_fp := pg_temp.fp();
  perform test.service();
  r := booking.privacy_retention_report(current_date);
  perform test.logout();
  perform pg_temp.ck(pg_temp.fp() = v_fp, 'R1 raportti ei muuta mitään');
  perform pg_temp.ck((r ->> 'dry_run')::boolean and not (r ->> 'enabled')::boolean, 'R2 dry_run, ei päällä');
  perform pg_temp.ck(exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'customers' and c.id = 915701 and c.blocked is null), 'R3 3 v 1 kk asiakas erääntynyt');
  perform pg_temp.ck(not exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'customers' and c.id = 915702), 'R4 2 v 11 kk asiakas ei ehdokas');
  perform pg_temp.ck(not exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'customers' and c.id = 915703 and c.blocked is null), 'R5 aktiivisen lahjakortin asiakas ei erääntynyt');
  perform pg_temp.ck(exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'gift_cards_3y' and c.id = 915782 and c.blocked = 'active_gift_card'), 'R6 aktiivinen lahjakortti (ei päättymispäivää) ei anonymisoida');
  perform pg_temp.ck(not exists (select 1 from booking._privacy_candidates(current_date) c where c.id in (915704, 915705) and c.category = 'customers' and c.blocked is null), 'R7 vuosikortti/tuleva varaus: asiakas ei erääntynyt');
  perform pg_temp.ck(exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'customers' and c.id = 915706 and c.blocked = 'open_payment'), 'R8 avoin maksu estää');
  perform pg_temp.ck(exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'customers' and c.id = 915707 and c.blocked = 'marketing_consent'), 'R9 markkinointilupa estää');
  perform pg_temp.ck(exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'orders_6y' and c.id = 915721 and c.blocked = 'future_reservation'), 'R10 tuleva varaus estää 6 v tilauksen');
  perform pg_temp.ck(exists (select 1 from booking._privacy_candidates('2027-01-01') c where c.category = 'orders_6y' and c.id = 915720)
                     and not exists (select 1 from booking._privacy_candidates('2026-12-31') c where c.category = 'orders_6y' and c.id = 915720), 'R11 6 v raja 31.12.2026 / 1.1.2027');
  -- R12 ei riipu tietokannan muusta datasta (tuotannossa pienemmät asiakas-id:t täyttävät 5 esimerkin otoksen): raportin määrä vastaa
  -- ehdokasjoukkoa, testiasiakas kuuluu siihen, ja otos on joukon 5 pienintä id:tä (ei testiasiakkaan läsnäoloa otoksessa).
  perform pg_temp.ck((r #>> '{categories,customers,due}')::int
                       = (select count(*) from booking._privacy_candidates(current_date) c where c.category = 'customers' and c.blocked is null)
                     and (r #>> '{categories,customers,due}')::int >= 1
                     and (r #> '{categories,customers,sample_ids}')
                       = (select coalesce(jsonb_agg(s.id order by s.id), '[]'::jsonb) from (select c.id from booking._privacy_candidates(current_date) c
                            where c.category = 'customers' and c.blocked is null order by c.id limit 5) s)
                     and exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'customers' and c.id = 915701 and c.blocked is null)
                     and not ((r #> '{categories,customers,sample_ids}') @> '[915702]'::jsonb)
                     and (r #>> '{categories,gift_cards_3y,blocked,active_gift_card}')::int >= 1 and (r #>> '{categories,customers,blocked,marketing_consent}')::int >= 1, 'R12 raportin luokat, esteet ja esimerkki-id:t');
  perform test.login(u_user);
  perform pg_temp.ck(pg_temp.err('select booking.privacy_retention_report(current_date)') is not null, 'R13 tavallinen käyttäjä ei saa raporttia');
  perform pg_temp.ck(pg_temp.err('select booking.privacy_retention_run()') is not null, 'R14 tavallinen käyttäjä ei saa ajaa');
  perform test.logout();
  perform test.anon();
  perform pg_temp.ck(pg_temp.err('select booking.privacy_retention_report(current_date)') is not null, 'R15 anon ei saa raporttia');
  perform test.logout();

  -- ===== L: kirjanpitolukot ennallaan ilman ajoa =====
  perform pg_temp.ck(pg_temp.err($q$update booking.invoices set notes = null where id = 915771$q$) like '%Lähetettyä laskua%', 'L1 lasku lukittu ilman ajoa');
  perform pg_temp.ck(pg_temp.err($q$update booking.receipts set snapshot = snapshot - 'buyer' where id = 915761$q$) like '%Kuittia ei voi muuttaa%', 'L2 kuitti lukittu ilman ajoa');
  perform set_config('booking.privacy_retention', 'on', true);
  perform pg_temp.ck(pg_temp.err($q$update booking.invoices set notes = null, buyer_reference = null, customer_snapshot = '{"anonymized": true}' where id = 915772$q$) like '%Lähetettyä laskua%', 'L3 alle 6 v lasku lukittu myös ajon lipulla');
  perform pg_temp.ck(pg_temp.err($q$update booking.invoices set total_gross = 1 where id = 915771$q$) like '%Lähetettyä laskua%', 'L4 summaa ei voi muuttaa ajon lipulla');
  perform pg_temp.ck(pg_temp.err($q$update booking.receipts set snapshot = snapshot - 'buyer' where id = 915761$q$) like '%Kuittia ei voi muuttaa%', 'L5 kuitti: tekstin on vastattava snapshotia');
  perform pg_temp.ck(pg_temp.err($q$update booking.receipts set snapshot = jsonb_set(snapshot, '{total_gross}', '1') - 'buyer' where id = 915761$q$) like '%Kuittia ei voi muuttaa%', 'L6 kuitin summaa ei voi muuttaa');
  perform pg_temp.ck(pg_temp.err($q$delete from booking.receipts where id = 915761$q$) like '%Kuittia ei voi poistaa%', 'L7 kuittia ei voi poistaa');
  perform set_config('booking.privacy_retention', '', true);

  -- ===== D: ajo pois päältä =====
  v_fp := pg_temp.fp();
  perform test.service();
  j := booking.privacy_retention_run();
  perform test.logout();
  perform pg_temp.ck(not (j ->> 'enabled')::boolean, 'D1 ajo palauttaa enabled=false');
  perform pg_temp.ck((select status from booking.privacy_retention_runs order by id desc limit 1) = 'disabled', 'D2 ajoloki: disabled');
  perform pg_temp.ck((select name from booking.customers where id = 915701) = 'T157 Vanha', 'D3 pois päältä: ei muutoksia');

  -- ===== E: ajo päällä =====
  update booking.settings set value = 'true' where key = 'privacy_retention.enabled';
  -- booking_160 lisää privacy_retention.dry_run (oletus true → ajo vain laskee). Varsinainen ajo vaatii dry_run = false; ilman 160:tä
  -- asetusta ei lueta. Muutos perutaan testin transaktion mukana.
  insert into booking.settings(key, value, description) values ('privacy_retention.dry_run', 'false', 't157')
    on conflict (key) do update set value = excluded.value;
  perform test.service();
  j := booking.privacy_retention_run();
  perform test.logout();
  perform pg_temp.ck((j ->> 'ok')::boolean and jsonb_array_length(j -> 'errors') = 0, 'E1 ajo ok ilman virheitä: ' || coalesce((j -> 'errors')::text, ''));
  perform pg_temp.ck((select status from booking.privacy_retention_runs order by id desc limit 1) = 'ok'
                     and (select (counts ->> 'customers')::int from booking.privacy_retention_runs order by id desc limit 1) >= 1, 'E2 ajoloki: määrät');
  perform pg_temp.ck((select name = 'Anonymisoitu asiakas' and email is null and phone is null and anonymized_at is not null from booking.customers where id = 915701), 'E3 3 v 1 kk asiakas anonymisoitu');
  perform pg_temp.ck((select name = 'T157 Tuore' and email is not null from booking.customers where id = 915702), 'E4 2 v 11 kk asiakas ennallaan');
  perform pg_temp.ck((select name = 'T157 Lahjakortti' and email is not null from booking.customers where id = 915703), 'E5 aktiivisen lahjakortin asiakas ennallaan');
  perform pg_temp.ck((select count(*) = 2 from booking.gift_cards where id in (915781, 915782) and buyer_email is not null and balance = 50 and status = 'active'), 'E6 aktiiviset lahjakortit ennallaan');
  perform pg_temp.ck((select buyer_name is null and buyer_email is null from booking.gift_cards where id = 915783), 'E7 käytetty vanha lahjakortti anonymisoitu');
  perform pg_temp.ck((select buyer_name is null from booking.gift_cards where id = 915784), 'E8 vanhentunut (valid_to) lahjakortti anonymisoitu');
  perform pg_temp.ck((select name = 'T157 Vuosikortti' from booking.customers where id = 915704) and (select notes is not null from booking.annual_cards where id = 915791), 'E9 aktiivinen vuosikortti ja asiakas ennallaan');
  perform pg_temp.ck((select notes is null from booking.annual_cards where id = 915792), 'E10 vanha vuosikortti: huomio poistettu');
  perform pg_temp.ck((select name = 'T157 Tuleva' from booking.customers where id = 915705) and (select notes is not null from booking.reservations where id = 915735)
                     and (select customer_note is not null from booking.orders where id = 915715), 'E11 tulevan varauksen asiakas/tilaus/varaus ennallaan');
  perform pg_temp.ck((select billing is not null and customer_note is not null from booking.orders where id = 915721)
                     and (select notes is not null from booking.reservations where id = 915741), 'E12 6 v tilaus jolla tuleva varaus ennallaan');
  perform pg_temp.ck((select name = 'T157 Avoin maksu' from booking.customers where id = 915706) and (select raw is not null from booking.payments where id = 915751), 'E13 avoin maksu ennallaan');
  perform pg_temp.ck((select name = 'T157 Lupa' from booking.customers where id = 915707), 'E14 markkinointiluvan asiakas ennallaan');
  perform pg_temp.ck((select name = 'Anonymisoitu asiakas' and company = 'T157 Oy' and business_id = '1234567-1' and email is null from booking.customers where id = 915708), 'E15 yritysasiakas: yhteyshenkilö pois, yritystiedot säilyvät');
  perform pg_temp.ck((select customer_note is null and internal_note is null and not (billing ? 'email') and not (billing ? 'phone') and billing ->> 'address' = 'Testitie 1' from booking.orders where id = 915711), 'E16 3 v tilaus: vapaa teksti ja yhteystiedot pois');
  perform pg_temp.ck((select notes is null from booking.reservations where id = 915731), 'E17 päättyneen varauksen huomio pois');
  -- 6 v: 2019 erääntynyt, 2020-12-31 ei
  perform pg_temp.ck((select billing is null and invoice_reference is null and customer_id is null and total_gross = 100 and status = 'completed' from booking.orders where id = 915719), 'E18 6 v tilaus: henkilökentät pois, summa/tila säilyy');
  perform pg_temp.ck((select raw is null and note is null and amount = 100 and method = 'card_terminal' and paid_at is not null from booking.payments where id = 915752), 'E19 6 v maksu: raw pois, summa/tapa/päivä säilyy');
  perform pg_temp.ck((select coalesce(snapshot -> 'buyer', 'null') = 'null' and total_gross = 100 and snapshot -> 'lines' is not null and text_body = booking._receipt_text(snapshot)
                        and text_body not like '%t157-kp@%' from booking.receipts where id = 915761), 'E20 6 v kuitti: ostaja pois, rivit/summat säilyvät, teksti uudelleen');
  perform pg_temp.ck((select customer_snapshot = '{"anonymized": true}' and notes is null and buyer_reference is null and total_gross = 100 and invoice_no = 'T157-1' and status = 'paid'
                        from booking.invoices where id = 915771), 'E21 6 v lasku: asiakastiedot pois, numero/summat säilyvät');
  perform pg_temp.ck((select billing ->> 'address' = 'Testitie 10' and invoice_reference = 'T157-VIITE2' and customer_id = 915710 from booking.orders where id = 915720)
                     and (select snapshot -> 'buyer' is not null and text_body = 'T157 teksti 2020' from booking.receipts where id = 915762)
                     and (select customer_snapshot ->> 'name' = 'T157 Uusivuosi' and notes is not null from booking.invoices where id = 915772)
                     and (select raw is not null from booking.payments where id = 915753), 'E22 alle 6 v: kirjanpidon henkilötiedot säilyvät vaikka asiakas anonymisoitu');
  perform pg_temp.ck((select name = 'Anonymisoitu asiakas' from booking.customers where id = 915710)
                     and (select contact_name is not null and email is not null from booking.invoice_customers where id = 915774), 'E23 asiakasrekisteri anonymisoitu 3 v jälkeen, alle 6 v laskutusasiakas säilyy');
  perform pg_temp.ck((select contact_name is null and email is null and company_name = 'T157 Kirjanpito Tmi' and business_id = '1234567-1' from booking.invoice_customers where id = 915773), 'E23b 6 v laskutusasiakas: yhteyshenkilö pois, yritystiedot säilyvät');
  perform pg_temp.ck((select payload = '{"anonymized": true}' from booking.email_outbox where id = 915795)
                     and (select payload ->> 'to' is not null from booking.email_outbox where id = 915796)
                     and (select payload ->> 'to' is not null from booking.email_outbox where id = 915797), 'E24 sähköpostijono: yli 3 v vanha lähetetty tyhjennetty, odottava ja tuore ennallaan');
  perform pg_temp.ck((select count(*) from booking.email_outbox where id in (915795, 915796, 915797)) = 3, 'E24b sähköpostijonon rivejä ei poisteta');
  perform pg_temp.ck((select not (old_data ? 'name') and not (old_data ? 'email') and old_data ->> 'language' = 'fi' and not (new_data ? 'name') from booking.audit_log where id = 915798)
                     and (select old_data ? 'name' from booking.audit_log where id = 915799), 'E25 audit_log: yli 3 v henkilöavaimet pois, tuore ennallaan');
  perform pg_temp.ck(not exists (select 1 from booking.audit_log a where a.id > 915799 and a.table_name = 'customers' and a.row_pk = '915701'
                       and (a.old_data ? 'email' or a.new_data ? 'email')), 'E26 ajon omat audit-rivit eivät sisällä henkilötietoja');
  -- toinen ajo ei muuta enää mitään asiakkaissa
  perform test.service();
  j := booking.privacy_retention_run();
  perform test.logout();
  perform pg_temp.ck(coalesce((j #>> '{counts,customers}')::int, -1) = 0 and coalesce((j #>> '{counts,receipts_6y}')::int, -1) = 0, 'E27 uusinta-ajo: ei uusia muutoksia');
  update booking.settings set value = 'false' where key = 'privacy_retention.enabled';
  update booking.settings set value = 'true' where key = 'privacy_retention.dry_run';

  -- ===== K: kävijämittauksen kuukausikooste =====
  perform test.service();
  v_n := booking.analytics_cleanup();
  perform test.logout();
  perform pg_temp.ck(v_n = 11, 'K1 siivous palauttaa poistettujen määrän (11): ' || v_n);
  perform pg_temp.ck((select count(*) from booking.analytics_events) = 1, 'K2 tuore tapahtuma jää');
  perform pg_temp.ck((select sum(events) from booking.analytics_monthly where kind = 'event') = 11, 'K3 koosteen tapahtumasumma = poistetut');
  perform pg_temp.ck((select sum(events) from booking.analytics_monthly where kind = 'visit') = 10
                     and (select events from booking.analytics_monthly where kind = 'unique' and event_type = 'page_view') = 10, 'K4 käynnit ja uniikit istunnot');
  perform pg_temp.ck((select orders = 1 and amount_gross_sum = 50 from booking.analytics_monthly where kind = 'unique' and event_type = 'purchase'), 'K5 tilaukset ja summa');
  perform pg_temp.ck(not exists (select 1 from booking.analytics_monthly where kind in ('event', 'visit') and events < 5
                                   and not (locale = 'muu' and device_type = 'muu' and source_category = 'muu')), 'K6 alle 5 ryhmät yhdistetty (muu)');
  perform pg_temp.ck(exists (select 1 from booking.analytics_monthly where kind = 'event' and path = '/a' and events = 7 and locale = 'fi'), 'K7 riittävän suuri ryhmä säilyy tarkkana');
  perform pg_temp.ck(not exists (select 1 from booking.analytics_monthly where path in ('/b', '/c', '/kiitos')), 'K8 pienet polut → /muu');
  perform pg_temp.ck((select count(*) from information_schema.columns where table_schema = 'booking' and table_name = 'analytics_monthly'
                        and column_name in ('session_key', 'order_id', 'utm_campaign', 'utm_source', 'referrer_domain')) = 0, 'K9 koosteessa ei istunto-/tilaus-/UTM-kenttiä');
  -- uusinta: idempotentti (ei poistettavaa → kooste ennallaan)
  v_txt := (select string_agg(t::text, ',' order by month, kind, event_type, path, locale, device_type, source_category, product_id) from booking.analytics_monthly t);
  perform test.service(); v_n := booking.analytics_cleanup(); perform test.logout();
  perform pg_temp.ck(v_n = 0 and v_txt = (select string_agg(t::text, ',' order by month, kind, event_type, path, locale, device_type, source_category, product_id) from booking.analytics_monthly t), 'K10 uusinta ei muuta koostetta');
  -- raportti: pitkä menneisyysväli kooste + raaka, ei tuplalaskentaa
  perform test.login(u_admin);
  r := booking.admin_analytics_summary((current_date - interval '15 months')::date, current_date);
  perform pg_temp.ck((r #>> '{funnel,page_view_events}')::int = 11 and (r #>> '{funnel,visitors}')::int = 11, 'K11 pitkä väli: 10 koosteesta + 1 raaka = 11: ' || coalesce(r #>> '{funnel}', ''));
  perform pg_temp.ck((r #>> '{funnel,paid_orders}')::int = 1 and jsonb_array_length(r -> 'aggregated_months') = 1 and r ? 'monthly_series', 'K12 tilaukset ja koostekuukaudet');
  perform pg_temp.ck((select sum((x ->> 'visits')::int) from jsonb_array_elements(r -> 'sources') x) = 11, 'K13 lähteiden käynnit = 11');
  r := booking.admin_analytics_summary(current_date - 30, current_date);
  perform pg_temp.ck(not (r ? 'aggregated_months') and (r #>> '{funnel,page_view_events}')::int = 1, 'K14 lyhyt väli: booking_150-muoto ennallaan');
  perform pg_temp.ck(pg_temp.err('select booking.admin_analytics_summary(current_date, current_date + 400)') is not null, 'K15 yli 367 pv tulevaisuuteen estetty');
  perform pg_temp.ck(pg_temp.err($q$select booking.admin_analytics_summary((current_date - interval '11 years')::date, current_date)$q$) is not null, 'K16 yli 3661 pv estetty');
  perform test.logout();

  select count(*) filter (where not ok), count(*) into v_n, v_cnt from t157_r;
  raise exception 'TESTRESULT pass=% fail=% :: %', v_cnt - v_n, v_n,
    coalesce((select string_agg(label, ' | ') from t157_r where not ok), 'ALL OK');
end $t$;
