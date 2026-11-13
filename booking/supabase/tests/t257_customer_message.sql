-- t257: Viesti asiakkaalle (booking_257). Paikallinen Postgres migraatioiden ja fixtures/10_test_helpers.sql jälkeen.
--   cd booking/supabase/tests && psql -X -v ON_ERROR_STOP=1 -f t257_customer_message.sql
-- Yksi transaktio; lopussa rollback kumoaa kaiken. Ei tuotantoon.
\set ON_ERROR_STOP on
begin;
set local statement_timeout = '120s';
set local lock_timeout = '3s';
\ir ../migrations/20261106220000_booking_257_customer_message.sql

create function pg_temp.ck(ok boolean, label text) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'FAIL: %', label; end if;
  raise notice 'PASS: %', label;
end $$;

do $test$
declare
  u_mgr uuid := test.mk_staff('t257-mgr@example.test', 'manager');
  u_staff uuid := test.mk_staff('t257-staff@example.test', 'staff');
  d date := date '2027-06-16';
  d_pay date := date '2027-06-10';
  res jsonb;
  v_rule bigint;
  v_rule2 bigint;
  v_ord bigint;
  v_ord2 bigint;
  v_res bigint;
  v_token uuid;
  v_mail text;
  v_before int;
  v_after int;
  v_cu bigint;
  v_buy bigint;
  v_wl bigint;
  v_noint int;
  v_subj text := 'Hei {asiakkaan nimi}';
  v_body text := 'Tuote {tuote} päivä {päivämäärä} kello {kellonaika} hlö {henkilömäärä} linkki {tilauslinkki}';
  v_subj_en text := 'Hello {asiakkaan nimi}';
  v_body_en text := 'Product {tuote} date {päivämäärä} time {kellonaika} pax {henkilömäärä} link {tilauslinkki}';
begin
  perform pg_temp.ck(not has_table_privilege('authenticated', 'booking.customer_messages', 'select')
    and not has_table_privilege('anon', 'booking.customer_messages', 'select'), 'A1: lokitaulua ei lueta suoraan');
  perform pg_temp.ck((select relrowsecurity from pg_class where oid = 'booking.customer_messages'::regclass), 'A2: RLS');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_customer_message_send(date, date, bigint[], text, text, text, text, boolean)', 'execute')
    and has_function_privilege('authenticated', 'booking.admin_customer_message_send(date, date, bigint[], text, text, text, text, boolean)', 'execute')
    and not has_function_privilege('authenticated', 'booking._customer_message_hits(date, date, bigint[])', 'execute'), 'A3: RPC authenticatedille, apu ei');

  update booking.product_config set bookable = true, shop_visible = true, lifecycle = 'current' where product_id = 33;
  update booking.settings set value = '400'::jsonb where key = 'booking_horizon_days';
  update booking.settings set value = '"pay_later"'::jsonb where key = 'public_payment_mode';
  update booking.settings set value = 'true'::jsonb where key = 'events.sale_enabled';
  update booking.settings set value = '"https://saunotus.fi"'::jsonb where key = 'site_base_url';
  update booking.settings set value = '"/tilaus/"'::jsonb where key = 'order_page_path';

  perform test.login(u_mgr);
  res := booking.admin_event_rule_upsert(null, 33, jsonb_build_object('date', d, 'start_time', '17:00', 'duration_minutes', 120, 'max_persons', 12));
  v_rule := (res ->> 'id')::bigint;
  res := booking.admin_event_rule_upsert(null, 33, jsonb_build_object('date', d + 1, 'start_time', '17:00', 'duration_minutes', 120, 'max_persons', 12));
  v_rule2 := (res ->> 'id')::bigint;
  perform test.logout();
  perform pg_temp.ck(v_rule is not null and v_rule2 is not null, 'B1: kerrat luotu');

  perform test.reset_rl();
  perform test.anon('10.257.0.1'); res := test.pub_book(v_rule, d, 2, 't257-a@example.com', 'Anna Asiakas'); perform test.logout();
  v_token := (res ->> 'token')::uuid;
  select o.id, r.id into v_ord, v_res from booking.orders o join booking.reservations r on r.order_id = o.id where o.public_token = v_token;
  perform test.reset_rl();
  perform test.anon('10.257.0.2'); res := test.pub_book(v_rule2, d + 1, 3, 't257-a@example.com', 'Anna Asiakas'); perform test.logout();
  select o.id into v_ord2 from booking.orders o where o.public_token = (res ->> 'token')::uuid;
  -- Sama asiakas kahteen tilaukseen, jotta dedup testataan customer_id:llä.
  update booking.orders set customer_id = (select customer_id from booking.orders where id = v_ord) where id = v_ord2;

  perform test.reset_rl();
  perform test.anon('10.257.0.3'); res := test.pub_book(v_rule, d, 1, 't257-b@example.com', 'Bertta'); perform test.logout();

  perform test.reset_rl();
  perform test.anon('10.257.0.4'); res := test.pub_book(v_rule, d, 1, 't257-c@example.com', 'Cecilia'); perform test.logout();
  update booking.customers set email = null where id = (select customer_id from booking.orders where public_token = (res ->> 'token')::uuid);

  perform test.reset_rl();
  perform test.anon('10.257.0.5'); res := test.pub_book(v_rule, d, 1, 't257-d@example.com', 'Peruttu'); perform test.logout();
  update booking.reservations set status = 'cancelled', cancelled_at = now()
   where order_id = (select id from booking.orders where public_token = (res ->> 'token')::uuid);

  perform test.reset_rl();
  perform test.anon('10.257.0.6'); res := test.pub_book(v_rule, d, 1, 't257-e@example.com', 'Vanhentunut pito'); perform test.logout();
  update booking.reservations set status = 'pending', hold_expires_at = now() - interval '1 hour'
   where order_id = (select id from booking.orders where public_token = (res ->> 'token')::uuid);

  perform test.reset_rl();
  perform test.anon('10.257.0.7'); res := test.pub_book(v_rule, d, 1, 't257-f@example.com', 'Johku'); perform test.logout();
  update booking.orders set external_source = 'johku', external_id = 't257-j' where public_token = (res ->> 'token')::uuid;

  insert into booking.waitlist_entries(product_id, rule_id, session_date, starts_at, ends_at, space_id, persons, customer_name, customer_email, status)
  select r.product_id, r.id, d,
         (d + r.start_time) at time zone 'Europe/Helsinki',
         (d + r.start_time + make_interval(mins => r.duration_minutes)) at time zone 'Europe/Helsinki',
         r.space_id, 1, 'Jono Testi', 't257-jono@example.test', 'waiting'
    from booking.schedule_rules r where r.id = v_rule
  returning id into v_wl;

  -- Lahjakorttiosto (tuote 38) maksupäivällä d_pay Helsingissä.
  insert into booking.customers(name, email) values ('Ostaja', 't257-buy@example.test') returning id into v_cu;
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, confirmed_at)
  values (v_cu, 'confirmed', 'paid', 58, 'web', 'en', now()) returning id into v_buy;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (v_buy, 38, 'Avoin lahjakortti', 'gift_card', 1, 58, 58, 25.5);
  alter table booking.payments disable trigger payments_paid_ins;
  alter table booking.payments disable trigger payments_paid_upd;
  insert into booking.payments(order_id, method, provider, status, amount, paid_at)
  values (v_buy, 'other', 'manual', 'paid', 58, ((d_pay::text || ' 12:00')::timestamp at time zone 'Europe/Helsinki'));
  alter table booking.payments enable trigger payments_paid_ins;
  alter table booking.payments enable trigger payments_paid_upd;

  -- Aikavyöhyke: UTC 21:30 15.6. = Helsinki 00:30 16.6. Päivitys yhdelle varaukselle ei tarvita, kerrat ovat jo 16.6. 17:00 HH.

  perform test.login(u_staff);
  perform pg_temp.ck(test.code($q$select booking.admin_customer_message_send('2027-06-16','2027-06-16', array[33], 'Hei', 'Teksti', 'Hi', 'Text', true)$q$) = 'forbidden', 'C1: staff ei lähetä');
  perform test.logout();

  perform test.login(u_mgr);
  perform pg_temp.ck(test.code($q$select booking.admin_customer_message_send('2027-06-16','2027-06-16', array[33], 'Hei Montonio', 'Teksti', 'Hi', 'Text', false)$q$) = 'provider_name', 'C2: välittäjän nimi hylätään');

  -- Vain 16.6. + tuote 33: Anna (yksi, vaikka toinen varaus 17.6.), Bertta, Cecilia (ei sähköpostia). Ei peruttua, pitoa, Johkua, jonoa.
  res := booking.admin_customer_message_send(d, d, array[33], v_subj, v_body, v_subj_en, v_body_en, false);
  perform pg_temp.ck((res ->> 'sent')::boolean = false and (res ->> 'recipient_count')::int = 2 and (res ->> 'skipped_count')::int = 1
    and jsonb_array_length(res -> 'recipients') = 2
    and jsonb_array_length(res -> 'skipped') = 1
    and (res -> 'skipped' -> 0 ->> 'reason') = 'no_email'
    and res ->> 'signature' is null, 'D1: esikatselu 16.6. tuote 33');
  perform pg_temp.ck((res -> 'preview' ->> 'subject_fi') like 'Hei Anna Asiakas%'
    and (res -> 'preview' ->> 'body_fi') like '%16.06.2027%'
    and (res -> 'preview' ->> 'body_fi') like '%17:00%'
    and (res -> 'preview' ->> 'body_fi') like '%https://saunotus.fi/tilaus/?t=%'
    and (res -> 'preview' ->> 'body_fi') not like '%{tuote}%'
    and (res -> 'preview' ->> 'body_fi') like '%hlö 2%', 'D2: paikkamerkit täyttyvät esikatselussa');

  select count(*) into v_before from booking.email_outbox where kind = 'event_message';
  res := booking.admin_customer_message_send(d, d, array[33], v_subj, v_body, v_subj_en, v_body_en, false);
  select count(*) into v_after from booking.email_outbox where kind = 'event_message';
  perform pg_temp.ck(v_after = v_before, 'D3: esikatselu ei lisää jonoon');

  -- Aikaväli 10.–17.6. tuotteet 33 ja 38: Anna (dedup kahdesta varauksesta), Bertta, Ostaja (EN), Cecilia ohitettu.
  res := booking.admin_customer_message_send(d_pay, d + 1, array[33, 38], v_subj, v_body, v_subj_en, v_body_en, false);
  perform pg_temp.ck((res ->> 'recipient_count')::int = 3 and (res ->> 'skipped_count')::int = 1, 'E1: väli + kaksi tuotetta, dedup');

  select count(*) into v_before from booking.email_outbox where kind = 'event_message';
  res := booking.admin_customer_message_send(d_pay, d + 1, array[33, 38], v_subj, v_body, v_subj_en, v_body_en, true);
  select count(*) into v_after from booking.email_outbox where kind = 'event_message';
  perform pg_temp.ck((res ->> 'sent')::boolean and (res ->> 'recipient_count')::int = 3
    and v_after = v_before + 3, 'E2: lähetys jonoon kolme kertaa');

  -- Ostajan EN-viesti ja lahjakortin nimi, ei kellonaikaa eikä henkilömäärää.
  select e.payload::text, e.locale into v_mail, v_subj from booking.email_outbox e
   where e.kind = 'event_message' and e.order_id = v_buy order by e.id desc limit 1;
  perform pg_temp.ck(v_mail like '%Hello Ostaja%'
    and v_mail like '%Gift Card%'
    and v_mail like '%10.06.2027%'
    and v_mail like '%time  pax  link%'
    and v_mail not like '%{tuote}%'
    and v_mail not like '%17:00%', 'E3: EN-osto ilman varausaikaa');
  -- locale of buy order is en
  perform pg_temp.ck(exists (
    select 1 from booking.email_outbox e where e.order_id = v_buy and e.kind = 'event_message' and coalesce(e.locale, '') = 'en'
  ), 'E4: ostajan locale en');

  -- Annan viesti: varaus ensisijainen, molemmat tuotenimet jos 38 ei osumaa hänellä... vain 33.
  select e.payload::text into v_mail from booking.email_outbox e
   where e.kind = 'event_message' and e.order_id = v_ord order by e.id desc limit 1;
  perform pg_temp.ck(v_mail is not null and v_mail like '%Anna Asiakas%' and v_mail like '%Sipoonjoen Kekri%' and v_mail like '%17:00%'
    and v_mail like '%https://saunotus.fi/tilaus/?t=%'
    and v_mail not like '%Montonio%' and v_mail not like '%event_name%', 'E5: Annan FI-varausviesti');

  perform pg_temp.ck(not exists (
    select 1 from booking.email_outbox e
     where e.kind = 'event_message' and e.payload ->> 'body' like '%Jono Testi%'
  ) and v_wl is not null, 'E6: jono ei ole vastaanottaja');

  res := booking.admin_customer_messages_list();
  perform pg_temp.ck(jsonb_array_length(res) >= 1 and res -> 0 ->> 'subject_fi' = 'Hei {asiakkaan nimi}'
    and not (res::text ~* '@'), 'F1: lokissa ei osoitteita');

  -- Pelkkä ostojen päivä + tuote 38.
  res := booking.admin_customer_message_send(d_pay, d_pay, array[38], v_subj, v_body, v_subj_en, v_body_en, false);
  perform pg_temp.ck((res ->> 'recipient_count')::int = 1 and res -> 'recipients' -> 0 ->> 'language' = 'en', 'G1: pelkkä lahjakorttiosto');

  -- Väärä tuote samana päivänä: ei osumia esikatselussa.
  res := booking.admin_customer_message_send(d, d, array[1], v_subj, v_body, v_subj_en, v_body_en, false);
  perform pg_temp.ck((res ->> 'recipient_count')::int = 0 and (res ->> 'sent')::boolean = false, 'G2: väärä tuote ei osu');
  perform pg_temp.ck(test.code($q$select booking.admin_customer_message_send('2027-06-16','2027-06-16', array[1], 'Hei', 'Teksti suomeksi tässä', 'Hi', 'English body here', true)$q$) = 'no_recipients', 'G3: lähetys ilman vastaanottajia');

  perform test.logout();
end $test$;

rollback;
