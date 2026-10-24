-- t160: tietosuojan säilytysajan korjaukset (booking_160). Säännöt 24.10.2026:
-- 1) markkinointilupa: voimassa oleva lupa estää, peruminen on tapahtuma (3 v perumisesta); 2) yrityksen nimi ja Y-tunnus säilyvät
-- tilauksella, kuitilla, laskulla ja laskutusasiakkaalla; 3) sähköpostijonon rivit poistetaan 12 kk jälkeen (avoimet/uudelleenyritettävät eivät);
-- 4) kuitti-/lasku-PDF 6 v, lahjakortti-PDF 3 v: merkintä + ei uudelleenmuodostusta + Storage-lista (ei SQL-poistoa storage.objects-riveistä);
-- 5) anonymisoidun asiakkaan auth.users-tili poistetaan, henkilökunnan ei koskaan. Ehto: tilaus-/maksu-/varausrivit säilyvät.
-- Lisäksi dry_run (oletus true): ajo ei kirjoita mitään. Kaikki data feikkiä (id-alue 916000–916099).
-- Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN yhdessä transaktiossa; tulos: TESTRESULT pass=… fail=…
set local lock_timeout = '3s';
set local statement_timeout = '120s';
create temp table t160_r(ok boolean, label text) on commit drop;
grant all on t160_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t160_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return null; exception when others then return coalesce(nullif(sqlerrm, ''), sqlstate); end $$;
create function pg_temp.fp() returns text language sql as $$
  select md5(concat_ws('|',
    (select string_agg(t::text, ',' order by id) from booking.customers t),
    (select string_agg(t::text, ',' order by id) from booking.orders t),
    (select string_agg(t::text, ',' order by id) from booking.reservations t),
    (select string_agg(t::text, ',' order by id) from booking.payments t),
    (select string_agg(t::text, ',' order by id) from booking.receipts t),
    (select string_agg(t::text, ',' order by id) from booking.invoices t),
    (select string_agg(t::text, ',' order by id) from booking.invoice_customers t),
    (select string_agg(t::text, ',' order by id) from booking.gift_cards t),
    (select string_agg(t::text, ',' order by id) from booking.email_outbox t),
    (select string_agg(t::text, ',' order by id) from booking.audit_log t),
    (select string_agg(t::text, ',' order by id) from auth.users t),
    (select string_agg(t::text, ',' order by auth_user_id) from booking.privacy_auth_deletions t))) $$;

-- ---------- fixtuurit ----------
create temp table t160_u(k text primary key, id uuid) on commit drop;
insert into t160_u values ('cust', test.mk_user('t160-asiakas@example.invalid')), ('staff', test.mk_staff('t160-staff@example.invalid', 'staff')),
  ('shared', test.mk_user('t160-jaettu@example.invalid')), ('ref', test.mk_user('t160-viitattu@example.invalid')),
  ('admin', test.mk_staff('t160-admin@example.invalid', 'admin')), ('user', test.mk_user('t160-user@example.invalid'));
set local session_replication_role = replica;
insert into booking.customers(id, name, email, phone, created_at, customer_kind, company, business_id, marketing_consent, marketing_consent_at, marketing_unsubscribed_at, auth_user_id)
overriding system value values
  (916001, 'T160 Lupa voimassa', 't160-lupa@example.invalid', null, now() - interval '5 years', 'private', null, null, true, now() - interval '5 years', null, null),
  (916002, 'T160 Perui 1 v', 't160-perui1@example.invalid', null, now() - interval '5 years', 'private', null, null, false, now() - interval '5 years', now() - interval '1 year', null),
  (916003, 'T160 Perui 3 v 1 kk', 't160-perui3@example.invalid', null, now() - interval '5 years', 'private', null, null, false, now() - interval '5 years', now() - interval '3 years 1 month', (select id from t160_u where k = 'cust')),
  (916004, 'T160 Lupa peruttu myöhemmin', 't160-ristiriita@example.invalid', null, now() - interval '5 years', 'private', null, null, true, now() - interval '4 years', now() - interval '3 years 2 months', null),
  (916005, 'T160 Luvan tapahtuma', 't160-tapahtuma@example.invalid', null, now() - interval '5 years', 'private', null, null, false, null, null, null),
  (916006, 'T160 Yhteyshenkilö', 't160-yritys@example.invalid', '+358401600006', '2019-05-01 09:00+03', 'company', 'T160 Oy', '7654321-2', false, null, null, null),
  (916007, 'T160 Henkilöasiakas', 't160-henkilo@example.invalid', null, '2019-05-01 09:00+03', 'private', null, null, false, null, null, null),
  (916008, 'T160 Henkilökunta-asiakas', 't160-staff@example.invalid', null, now() - interval '5 years', 'private', null, null, false, null, null, (select id from t160_u where k = 'staff')),
  (916009, 'T160 Jaettu vanha', 't160-jaettu@example.invalid', null, now() - interval '5 years', 'private', null, null, false, null, null, null),
  (916010, 'T160 Jaettu tuore', 't160-jaettu2@example.invalid', null, now() - interval '1 year', 'private', null, null, false, null, null, (select id from t160_u where k = 'shared')),
  (916011, 'T160 Viitattu', 't160-viitattu@example.invalid', null, now() - interval '5 years', 'private', null, null, false, null, null, (select id from t160_u where k = 'ref'));
-- jonossa oleva tili, joka on (uudelleen) linkitetty elävään asiakkaaseen → ei poisteta
insert into booking.privacy_auth_deletions(auth_user_id, customer_id) values ((select id from t160_u where k = 'shared'), 916009);
insert into booking.marketing_consent_events(customer_id, granted, at, source) values (916005, false, now() - interval '1 year', 't160');
insert into booking.day_notes(note_date, author_name, body, created_by) values (current_date, 'T160', 'T160 muistiinpano', (select id from t160_u where k = 'ref'));
insert into booking.orders(id, order_no, customer_id, status, payment_status, total_gross, created_at, confirmed_at, customer_kind, billing, invoice_reference)
overriding system value values
  (916021, 916021, 916006, 'completed', 'paid', 200, '2019-05-01 10:00+03', '2019-05-01 10:00+03', 'company',
   '{"name":"T160 Yhteyshenkilö","email":"t160-yritys@example.invalid","phone":"+358401600006","company":"T160 Oy","business_id":"7654321-2","business_id_raw":"76543212","address":"Yritystie 6","city":"Sipoo"}', 'T160-VIITE'),
  (916022, 916022, 916007, 'completed', 'paid', 100, '2019-05-02 10:00+03', '2019-05-02 10:00+03', 'private',
   '{"name":"T160 Henkilöasiakas","email":"t160-henkilo@example.invalid","company":"ei saa jäädä"}', null),
  (916023, 916023, null, 'completed', 'paid', 100, now() - interval '1 day', now() - interval '1 day', 'private', null, null);
insert into booking.reservations(id, order_id, space_id, mode, starts_at, ends_at, persons, status, notes)
overriding system value values
  (916031, 916021, (select min(id) from booking.resources), 'exclusive', '2019-05-10 16:00+03', '2019-05-10 18:00+03', 4, 'completed', 'T160 huomio');
insert into booking.payments(id, order_id, method, amount, status, created_at, paid_at, raw, note)
overriding system value values
  (916041, 916021, 'invoice', 200, 'paid', '2019-05-01 10:00+03', '2019-05-20 10:00+03', '{"payer":"T160 Oy"}', 'T160 maksu'),
  (916042, 916022, 'card_terminal', 100, 'paid', '2019-05-02 10:00+03', '2019-05-02 10:00+03', '{"payer":"t160-henkilo@example.invalid"}', null),
  (916043, 916023, 'card_terminal', 100, 'paid', now() - interval '1 day', now() - interval '1 day', null, null);
insert into booking.receipts(id, receipt_no, kind, series, year, seq, order_id, payment_id, issued_at, total_gross, snapshot, text_body, pdf_path)
overriding system value values
  (916051, 'K-2019-T160-1', 'receipt', 'T160', 2019, 1, 916021, 916041, '2019-05-20 10:00+03', 200,
   '{"seller":{"name":"T160 Myyjä"},"buyer":{"name":"T160 Yhteyshenkilö","company":"T160 Oy","business_id":"7654321-2","address":"Yritystie 6","zip":"04130","city":"Sipoo","reference":"T160-VIITE"},"total_net":159.36,"total_vat":40.64,"total_gross":200,"lines":[],"payment":{"method_label":"Lasku"}}',
   'T160 teksti', 'K-2019-T160-1.pdf'),
  (916052, 'K-2019-T160-2', 'receipt', 'T160', 2019, 2, 916022, 916042, '2019-05-02 10:00+03', 100,
   '{"seller":{"name":"T160 Myyjä"},"buyer":{"name":"T160 Henkilöasiakas"},"total_net":79.68,"total_vat":20.32,"total_gross":100,"lines":[],"payment":{"method_label":"Kortti"}}',
   'T160 teksti 2', null),
  (916053, 'K-2026-T160-3', 'receipt', 'T160', 2026, 3, 916023, 916043, now() - interval '1 day', 100,
   '{"seller":{"name":"T160 Myyjä"},"buyer":null,"total_net":79.68,"total_vat":20.32,"total_gross":100,"lines":[],"payment":{"method_label":"Kortti"}}', 'T160 tuore', null);
insert into booking.invoice_customers(id, customer_id, company_name, contact_name, email, business_id, vat_id, street, zip, city, country, updated_at)
overriding system value values
  (916061, 916006, 'T160 Oy', 'T160 Yhteyshenkilö', 't160-yritys@example.invalid', '7654321-2', 'FI76543212', 'Yritystie 6', '04130', 'Sipoo', 'FI', '2019-05-01 10:00+03'),
  (916062, 916007, 'T160 Henkilöasiakas', 'T160 Henkilöasiakas', 't160-henkilo@example.invalid', null, null, 'Kotitie 7', '04130', 'Sipoo', 'FI', '2019-05-02 10:00+03');
insert into booking.invoices(id, customer_id, order_id, status, invoice_date, due_date, seller_snapshot, customer_snapshot, notes, buyer_reference, series, seq, invoice_no, paid_at, sent_at, total_net, total_vat, total_gross, created_at, pdf_path)
overriding system value values
  (916071, 916061, 916021, 'paid', '2019-05-01', '2019-05-15', '{"name":"T160 Myyjä"}',
   '{"name":"T160 Oy","company_name":"T160 Oy","contact_name":"T160 Yhteyshenkilö","business_id":"7654321-2","vat_id":"FI76543212","email":"t160-yritys@example.invalid","street":"Yritystie 6"}',
   'T160 huomio', 'T160-OSTAJA', 'L', 916071, 'T160-1', '2019-05-20 10:00+03', '2019-05-01 10:00+03', 159.36, 40.64, 200, '2019-05-01 10:00+03', 'T160-1.pdf'),
  (916072, 916062, null, 'paid', '2019-05-02', '2019-05-16', '{"name":"T160 Myyjä"}',
   '{"name":"T160 Henkilöasiakas","company_name":"T160 Henkilöasiakas","email":"t160-henkilo@example.invalid","street":"Kotitie 7"}',
   null, null, 'L', 916072, 'T160-2', '2019-05-10 10:00+03', '2019-05-02 10:00+03', 79.68, 20.32, 100, '2019-05-02 10:00+03', null);
insert into booking.gift_cards(id, code, initial_amount, balance, status, valid_to, buyer_customer_id, buyer_name, buyer_email, created_at, pdf_path)
overriding system value values
  (916081, 'HH160AAAAAA1', 50, 0, 'used', current_date - interval '4 years', null, 'T160 Ostaja', 't160-lk@example.invalid', now() - interval '5 years', 'lahjakortit/HH160AAAAAA1.pdf'),
  (916082, 'HH160AAAAAA2', 50, 50, 'active', null, null, 'T160 Aktiivinen', 't160-lk2@example.invalid', now() - interval '5 years', null),
  (916083, 'HH160AAAAAA3', 50, 0, 'expired', current_date - interval '2 years', null, 'T160 Tuore', 't160-lk3@example.invalid', now() - interval '3 years', null);
insert into booking.email_outbox(id, kind, dedupe_key, status, attempts, max_attempts, payload, created_at, sent_at)
overriding system value values
  (916091, 'receipt', 't160-1', 'sent', 1, 6, '{"to":"t160-1@example.invalid"}', now() - interval '13 months', now() - interval '13 months'),
  (916092, 'receipt', 't160-2', 'failed', 2, 6, '{"to":"t160-2@example.invalid"}', now() - interval '13 months', null),
  (916093, 'receipt', 't160-3', 'failed', 6, 6, '{"to":"t160-3@example.invalid"}', now() - interval '13 months', null),
  (916094, 'receipt', 't160-4', 'pending', 0, 6, '{"to":"t160-4@example.invalid"}', now() - interval '13 months', null),
  (916095, 'receipt', 't160-5', 'sent', 1, 6, '{"to":"t160-5@example.invalid"}', now() - interval '11 months', now() - interval '11 months'),
  (916096, 'receipt', 't160-6', 'sent', 1, 6, '{"to":"t160-6@example.invalid"}', now() - interval '13 months', now() - interval '11 months'),
  (916097, 'receipt', 't160-7', 'dead', 6, 6, '{"to":"t160-7@example.invalid"}', now() - interval '13 months', null),
  (916098, 'receipt', 't160-8', 'dry_run', 0, 6, '{"to":"t160-8@example.invalid"}', now() - interval '13 months', null);
insert into storage.buckets(id, name, public) values ('t160-lahjakortit', 't160-lahjakortit', false), ('t160-julkinen', 't160-julkinen', true) on conflict do nothing;
insert into storage.objects(bucket_id, name) values
  ('receipts', 'K-2019-T160-1.pdf'), ('receipts', 'K-2026-T160-3.pdf'), ('invoices', 'T160-1.pdf'),
  ('t160-lahjakortit', 'lahjakortit/HH160AAAAAA1.pdf'), ('t160-julkinen', 'lahjakortit/HH160AAAAAA1.pdf');
set local session_replication_role = origin;

do $t$
declare j jsonb; r jsonb; v_fp text; v_n int; v_cnt int; v_tok uuid; v_itok uuid; v_gtok uuid; v_tok3 uuid; v_orders int; v_pay int; v_res int;
        u_admin uuid := (select id from t160_u where k = 'admin'); u_user uuid := (select id from t160_u where k = 'user');
begin
  select public_token into v_tok from booking.receipts where id = 916051;
  select public_token into v_tok3 from booking.receipts where id = 916053;
  select public_token into v_itok from booking.invoices where id = 916071;
  select public_token into v_gtok from booking.gift_cards where id = 916081;
  select count(*) into v_orders from booking.orders; select count(*) into v_pay from booking.payments; select count(*) into v_res from booking.reservations;

  -- ===== A: asetukset ja rakenne =====
  perform pg_temp.ck((select value from booking.settings where key = 'privacy_retention.enabled') = 'false'::jsonb, 'A1 ajo yhä pois päältä (enabled=false)');
  perform pg_temp.ck((select value from booking.settings where key = 'privacy_retention.dry_run') = 'true'::jsonb, 'A2 dry_run oletuksena true');
  perform pg_temp.ck((select value from booking.settings where key = 'privacy_retention.gift_card_pdf_years') = '3'::jsonb, 'A3 lahjakortti-PDF 3 v');
  perform pg_temp.ck(not exists (select 1 from cron.job where jobname like '%privacy%'), 'A4 ei ajastusta');
  perform pg_temp.ck(booking._privacy_keep('{"a":1,"b":null,"c":"","d":2}', array['a','b','c']) = '{"a":1}' and booking._privacy_keep('{"x":1}', array['a']) is null
                     and booking._privacy_keep('null', array['a']) is null, 'A5 _privacy_keep');
  perform pg_temp.ck(booking._privacy_invoice_snapshot('{"name":"Oy","company_name":"Oy","business_id":"1-2","email":"a@b"}') = '{"anonymized":true,"name":"Oy","company_name":"Oy","business_id":"1-2"}'
                     and booking._privacy_invoice_snapshot('{"name":"Matti","email":"a@b"}') = '{"anonymized":true}'
                     and booking._privacy_invoice_snapshot('{"anonymized":true,"name":"Oy","business_id":"1-2"}') = '{"anonymized":true,"name":"Oy","business_id":"1-2"}', 'A6 laskun snapshot: idempotentti');

  -- ===== R: ehdokkaat (sääntö 1) =====
  perform pg_temp.ck(exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'customers' and c.id = 916001 and c.blocked = 'marketing_consent'), 'R1 voimassa oleva lupa estää');
  perform pg_temp.ck(not exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'customers' and c.id = 916002), 'R2 peruttu 1 v sitten: ei ehdokas (3 v perumisesta)');
  perform pg_temp.ck(exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'customers' and c.id = 916003 and c.blocked is null), 'R3 peruttu yli 3 v sitten: erääntynyt');
  perform pg_temp.ck(exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'customers' and c.id = 916004 and c.blocked is null), 'R4 peruminen luvan jälkeen: lupa ei voimassa');
  perform pg_temp.ck(not exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'customers' and c.id = 916005), 'R5 luvan tapahtuma (marketing_consent_events) on tapahtuma');
  -- sääntö 4/5 ehdokkaat
  perform pg_temp.ck(exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'receipt_pdfs_6y' and c.id = 916051 and c.blocked is null)
                     and not exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'receipt_pdfs_6y' and c.id = 916053), 'R6 kuitti-PDF 6 v');
  perform pg_temp.ck(exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'invoice_pdfs_6y' and c.id = 916071 and c.blocked is null), 'R7 lasku-PDF 6 v');
  perform pg_temp.ck(exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'gift_card_pdfs_3y' and c.id = 916081 and c.blocked is null)
                     and exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'gift_card_pdfs_3y' and c.id = 916082 and c.blocked = 'active_gift_card')
                     and not exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'gift_card_pdfs_3y' and c.id = 916083), 'R8 lahjakortti-PDF 3 v, aktiivinen estää');
  perform pg_temp.ck(exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'auth_users' and c.id = 916003 and c.blocked is null)
                     and exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'auth_users' and c.id = 916008 and c.blocked = 'staff_account'), 'R9 auth-tili: asiakas erääntynyt, henkilökunta estetty');
  perform pg_temp.ck(exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'email_outbox' and c.id = 916091 and c.blocked is null)
                     and exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'email_outbox' and c.id = 916092 and c.blocked = 'open_email')
                     and exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'email_outbox' and c.id = 916094 and c.blocked = 'open_email')
                     and not exists (select 1 from booking._privacy_candidates(current_date) c where c.category = 'email_outbox' and c.id in (916095, 916096)), 'R10 sähköpostijono: 12 kk lähetyksestä, avoin/uudelleenyritettävä estää');
  -- raportti
  v_fp := pg_temp.fp();
  perform test.service();
  r := booking.privacy_retention_report(current_date);
  perform test.logout();
  perform pg_temp.ck(pg_temp.fp() = v_fp, 'R11 raportti ei muuta mitään');
  perform pg_temp.ck(r ? 'auth_deletion_queue' and r ? 'storage_objects_pending' and (r #>> '{settings,gift_card_pdf_years}')::int = 3 and (r ->> 'run_dry_run')::boolean
                     and (r #>> '{categories,receipt_pdfs_6y,due}')::int >= 1 and (r #>> '{categories,auth_users,blocked,staff_account}')::int >= 1, 'R12 raportin uudet kentät');

  -- ===== L: kirjanpitolukot (sääntö 2) =====
  perform set_config('booking.privacy_retention', 'on', true);
  perform pg_temp.ck(pg_temp.err($q$update booking.invoices set notes = null, buyer_reference = null, customer_snapshot = '{"anonymized": true}' where id = 916071$q$) like '%Lähetettyä laskua%', 'L1 lasku: yrityksen nimeä/Y-tunnusta ei saa poistaa');
  perform pg_temp.ck(pg_temp.err($q$update booking.receipts set snapshot = snapshot || '{"buyer": null}', text_body = booking._receipt_text(snapshot || '{"buyer": null}') where id = 916051$q$) like '%Kuittia ei voi muuttaa%', 'L2 kuitti: yrityksen nimeä/Y-tunnusta ei saa poistaa');
  perform pg_temp.ck(pg_temp.err($q$update booking.invoices set customer_snapshot = booking._privacy_invoice_snapshot(customer_snapshot) || '{"email":"x@y"}' where id = 916071$q$) like '%Lähetettyä laskua%', 'L3 lasku: vain sallittu osajoukko');
  perform set_config('booking.privacy_retention', '', true);
  perform pg_temp.ck(pg_temp.err($q$update booking.invoices set customer_snapshot = booking._privacy_invoice_snapshot(customer_snapshot), notes = null, buyer_reference = null where id = 916071$q$) like '%Lähetettyä laskua%', 'L4 ilman ajon lippua lukittu');

  -- ===== S: Storage-lista ja oikeudet =====
  perform test.login(u_user);
  perform pg_temp.ck(pg_temp.err('select booking.privacy_storage_due()') is not null, 'S1 tavallinen käyttäjä ei saa Storage-listaa');
  perform test.logout();
  perform test.anon();
  perform pg_temp.ck(pg_temp.err('select booking.privacy_storage_due()') is not null, 'S2 anon ei saa Storage-listaa');
  perform test.logout();
  perform test.service();
  j := booking.privacy_storage_due();
  perform test.logout();
  perform pg_temp.ck((j ->> 'total')::int = 0 and not (j ->> 'enabled')::boolean and (j ->> 'dry_run')::boolean, 'S3 ennen ajoa ei poistettavia, enabled=false, dry_run=true');

  -- ===== D: enabled=true + dry_run=true → ei kirjoituksia =====
  update booking.settings set value = 'true' where key = 'privacy_retention.enabled';
  v_fp := pg_temp.fp();
  perform test.service();
  j := booking.privacy_retention_run();
  perform test.logout();
  perform pg_temp.ck((j ->> 'dry_run')::boolean and pg_temp.fp() = v_fp, 'D1 dry_run: ei muutoksia');
  perform pg_temp.ck((select status = 'dry_run' and enabled and (counts ->> 'customers')::int >= 1 and counts ? 'email_outbox' from booking.privacy_retention_runs order by id desc limit 1), 'D2 dry_run-loki määrineen');
  update booking.settings set value = '"ehkä"' where key = 'privacy_retention.dry_run';
  v_fp := pg_temp.fp();  -- asetusmuutos kirjautuu audit_logiin
  perform test.service(); j := booking.privacy_retention_run(); perform test.logout();
  perform pg_temp.ck((j ->> 'dry_run')::boolean and pg_temp.fp() = v_fp, 'D3 virheellinen dry_run-arvo → kuivaharjoitus');
  delete from booking.settings where key = 'privacy_retention.dry_run';
  v_fp := pg_temp.fp();  -- asetusmuutos kirjautuu audit_logiin
  perform test.service(); j := booking.privacy_retention_run(); perform test.logout();
  perform pg_temp.ck((j ->> 'dry_run')::boolean and pg_temp.fp() = v_fp, 'D4 puuttuva dry_run-asetus → kuivaharjoitus');
  insert into booking.settings(key, value, description) values ('privacy_retention.dry_run', 'true', 't160');
  update booking.settings set value = 'false' where key = 'privacy_retention.enabled';
  v_fp := pg_temp.fp();
  perform test.service(); j := booking.privacy_retention_run(); perform test.logout();
  perform pg_temp.ck(not (j ->> 'enabled')::boolean and pg_temp.fp() = v_fp, 'D5 enabled=false: ei mitään');

  -- ===== E: varsinainen ajo (enabled=true, dry_run=false) =====
  update booking.settings set value = 'true' where key = 'privacy_retention.enabled';
  update booking.settings set value = 'false' where key = 'privacy_retention.dry_run';
  perform test.service();
  j := booking.privacy_retention_run();
  perform test.logout();
  perform pg_temp.ck((j ->> 'ok')::boolean and not (j ->> 'dry_run')::boolean, 'E1 ajo ok: ' || coalesce((j -> 'errors')::text, ''));
  -- sääntö 1
  perform pg_temp.ck((select name = 'T160 Lupa voimassa' and marketing_consent from booking.customers where id = 916001), 'E2 voimassa olevan luvan asiakas säilyy');
  perform pg_temp.ck((select name = 'T160 Perui 1 v' from booking.customers where id = 916002) and (select name = 'T160 Luvan tapahtuma' from booking.customers where id = 916005), 'E3 äskettäin perunut säilyy');
  perform pg_temp.ck((select anonymized_at is not null and email is null from booking.customers where id = 916003)
                     and (select anonymized_at is not null and not marketing_consent from booking.customers where id = 916004), 'E4 yli 3 v sitten perunut anonymisoitu');
  -- sääntö 2
  perform pg_temp.ck((select billing = '{"company":"T160 Oy","business_id":"7654321-2","business_id_raw":"76543212"}' and customer_id is null and invoice_reference is null and total_gross = 200
                        from booking.orders where id = 916021), 'E5 yritystilaus: vain yrityksen nimi ja Y-tunnus jäävät');
  perform pg_temp.ck((select billing is null from booking.orders where id = 916022), 'E6 henkilötilaus: laskutustieto kokonaan pois');
  perform pg_temp.ck((select snapshot -> 'buyer' = '{"company":"T160 Oy","business_id":"7654321-2"}' and text_body = booking._receipt_text(snapshot)
                        and text_body like '%T160 Oy%' and text_body not like '%Yhteyshenkilö%' and total_gross = 200 from booking.receipts where id = 916051), 'E7 kuitti: yrityksen nimi ja Y-tunnus jäävät');
  perform pg_temp.ck((select coalesce(snapshot -> 'buyer', 'null') = 'null' from booking.receipts where id = 916052), 'E8 henkilön kuitti: ostaja pois');
  perform pg_temp.ck((select customer_snapshot = '{"anonymized":true,"name":"T160 Oy","company_name":"T160 Oy","business_id":"7654321-2","vat_id":"FI76543212"}'
                             and notes is null and buyer_reference is null and invoice_no = 'T160-1' and total_gross = 200 from booking.invoices where id = 916071), 'E9 yrityslasku: nimi, Y- ja ALV-tunnus jäävät');
  perform pg_temp.ck((select customer_snapshot = '{"anonymized":true}' from booking.invoices where id = 916072), 'E10 henkilölasku: asiakastiedot pois');
  perform pg_temp.ck((select company_name = 'T160 Oy' and business_id = '7654321-2' and street = 'Yritystie 6' and contact_name is null and email is null from booking.invoice_customers where id = 916061), 'E11 yrityslaskutusasiakas: yritystiedot jäävät');
  perform pg_temp.ck((select company_name = 'Anonymisoitu' and street is null and city is null and contact_name is null from booking.invoice_customers where id = 916062), 'E12 henkilölaskutusasiakas: nimi ja osoite pois');
  perform pg_temp.ck((select company = 'T160 Oy' and business_id = '7654321-2' and email is null from booking.customers where id = 916006), 'E13 yritysasiakas: yritystiedot jäävät');
  -- sääntö 3
  perform pg_temp.ck((select count(*) from booking.email_outbox where id in (916091, 916093, 916097, 916098)) = 0, 'E14 vanhat päättyneet sähköpostit poistettu');
  perform pg_temp.ck((select count(*) from booking.email_outbox where id in (916092, 916094, 916095, 916096) and payload ? 'to') = 4, 'E15 uudelleenyritettävä, odottava ja tuoreet ennallaan');
  -- sääntö 4
  perform pg_temp.ck((select pdf_deleted_at is not null from booking.receipts where id = 916051) and (select pdf_deleted_at is null from booking.receipts where id = 916053)
                     and (select pdf_deleted_at is not null from booking.invoices where id = 916071)
                     and (select pdf_deleted_at is not null from booking.gift_cards where id = 916081) and (select pdf_deleted_at is null from booking.gift_cards where id in (916082)), 'E16 PDF-merkinnät');
  perform pg_temp.ck(booking.receipt_by_token(v_tok) is null and booking.receipt_by_token(v_tok3) is not null and booking.invoice_by_token(v_itok) is null, 'E17 poistettua kuitti-/lasku-PDF:ää ei muodosteta');
  perform pg_temp.ck(booking.svc_get_gift_card_pdf_data(v_gtok) ->> 'code' = 'not_found', 'E18 poistettua lahjakortti-PDF:ää ei muodosteta');
  perform test.service();
  j := booking.privacy_storage_due();
  perform test.logout();
  perform pg_temp.ck((j ->> 'total')::int = 3 and j -> 'items' @> '[{"bucket":"receipts","path":"K-2019-T160-1.pdf"},{"bucket":"invoices","path":"T160-1.pdf"},{"bucket":"t160-lahjakortit","path":"lahjakortit/HH160AAAAAA1.pdf"}]'
                     and not (j -> 'items' @> '[{"path":"K-2026-T160-3.pdf"}]') and not (j -> 'items' @> '[{"bucket":"t160-julkinen"}]')
                     and (j ->> 'enabled')::boolean and not (j ->> 'dry_run')::boolean, 'E19 Storage-lista: vain poistetut PDF:t, ei julkisia: ' || j::text);
  perform pg_temp.ck((select count(*) from storage.objects where name in ('K-2019-T160-1.pdf', 'T160-1.pdf')) = 2, 'E20 SQL ei poista storage.objects-rivejä (poisto Storage-API:lla)');
  -- sääntö 5
  perform pg_temp.ck(not exists (select 1 from auth.users where id = (select id from t160_u where k = 'cust'))
                     and (select deleted_at is not null from booking.privacy_auth_deletions where auth_user_id = (select id from t160_u where k = 'cust')), 'E21 anonymisoidun asiakkaan auth-tili poistettu');
  perform pg_temp.ck(exists (select 1 from auth.users where id = (select id from t160_u where k = 'staff'))
                     and exists (select 1 from booking.staff where user_id = (select id from t160_u where k = 'staff'))
                     and (select skipped_reason = 'staff' from booking.privacy_auth_deletions where auth_user_id = (select id from t160_u where k = 'staff')), 'E22 henkilökunnan tili säilyy (staff)');
  perform pg_temp.ck(exists (select 1 from auth.users where id = (select id from t160_u where k = 'shared'))
                     and (select skipped_reason = 'linked_customer' from booking.privacy_auth_deletions where auth_user_id = (select id from t160_u where k = 'shared')), 'E23 toiseen asiakkaaseen linkitetty tili säilyy');
  perform pg_temp.ck(exists (select 1 from auth.users where id = (select id from t160_u where k = 'ref'))
                     and (select skipped_reason = 'referenced:booking.day_notes' from booking.privacy_auth_deletions where auth_user_id = (select id from t160_u where k = 'ref')), 'E24 muualta viitattu tili säilyy');
  perform pg_temp.ck(exists (select 1 from auth.users where id = u_admin) and exists (select 1 from booking.staff where user_id = u_admin), 'E25 admin säilyy');
  perform pg_temp.ck(booking._privacy_auth_protected(u_admin) = 'staff', 'E26 admin suojattu');
  -- ehto
  perform pg_temp.ck((select count(*) from booking.orders) = v_orders and (select count(*) from booking.payments) = v_pay and (select count(*) from booking.reservations) = v_res
                     and exists (select 1 from booking.reservations where id = 916031) and exists (select 1 from booking.payments where id = 916041 and amount = 200), 'E27 tilaus-, maksu- ja varausrivit säilyvät');
  perform pg_temp.ck((select (counts ->> 'auth_users')::int >= 1 and (counts ->> 'auth_users_skipped')::int >= 3 and (counts ->> 'email_outbox')::int >= 4 from booking.privacy_retention_runs order by id desc limit 1), 'E28 ajoloki: uudet määrät');
  -- uusinta
  v_fp := pg_temp.fp();
  perform test.service(); j := booking.privacy_retention_run(); perform test.logout();
  perform pg_temp.ck(coalesce((j #>> '{counts,orders_6y}')::int, -1) = 0 and coalesce((j #>> '{counts,receipts_6y}')::int, -1) = 0 and coalesce((j #>> '{counts,invoices_6y}')::int, -1) = 0
                     and coalesce((j #>> '{counts,invoice_customers_6y}')::int, -1) = 0 and coalesce((j #>> '{counts,receipt_pdfs_6y}')::int, -1) = 0
                     and coalesce((j #>> '{counts,auth_users}')::int, -1) = 0 and coalesce((j #>> '{counts,email_outbox}')::int, -1) = 0, 'E29 uusinta-ajo: ei muutoksia: ' || (j -> 'counts')::text);
  perform pg_temp.ck(not exists (select 1 from booking._privacy_candidates(current_date) c where c.blocked is null and c.id between 916000 and 916099
                                   and c.category in ('orders_6y', 'receipts_6y', 'invoices_6y', 'invoice_customers_6y', 'receipt_pdfs_6y', 'invoice_pdfs_6y', 'gift_card_pdfs_3y')), 'E30 ehdokaslohko idempotentti');
  update booking.settings set value = 'false' where key = 'privacy_retention.enabled';
  update booking.settings set value = 'true' where key = 'privacy_retention.dry_run';

  select count(*) filter (where not ok), count(*) into v_n, v_cnt from t160_r;
  raise exception 'TESTRESULT pass=% fail=% :: %', v_cnt - v_n, v_n,
    coalesce((select string_agg(label, ' | ') from t160_r where not ok), 'ALL OK');
end $t$;
