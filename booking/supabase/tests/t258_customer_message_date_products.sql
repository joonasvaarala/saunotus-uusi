-- t258: Viesti asiakkaalle – päivämäärän tuotteet (booking_258).
-- Paikallinen Postgres migraatioiden ja fixtures/10_test_helpers.sql jälkeen.
--   cd booking/supabase/tests && psql -X -v ON_ERROR_STOP=1 -f t258_customer_message_date_products.sql
-- Yksi transaktio; lopussa rollback. Ei sähköposteja confirm=true -testeissä paitsi kun erikseen jonotetaan.
-- Ei tuotantoon.
\set ON_ERROR_STOP on
begin;
set local statement_timeout = '120s';
set local lock_timeout = '3s';
\ir ../migrations/20261106220000_booking_257_customer_message.sql
\ir ../migrations/20261106234000_booking_258_customer_message_date_products.sql

create function pg_temp.ck(ok boolean, label text) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'FAIL: %', label; end if;
  raise notice 'PASS: %', label;
end $$;

do $test$
declare
  u_mgr uuid := test.mk_staff('t258-mgr@example.test', 'manager');
  u_staff uuid := test.mk_staff('t258-staff@example.test', 'staff');
  d date := date '2027-06-16';
  d_pay date := date '2027-06-10';
  d_empty date := date '2027-07-01';
  res jsonb;
  v_rule bigint;
  v_rule2 bigint;
  v_token uuid;
  v_ord bigint;
  v_ord2 bigint;
  v_cu bigint;
  v_buy bigint;
  v_wl bigint;
  v_ids bigint[];
  v_noint int;
begin
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_customer_message_products(date, date)', 'execute')
    and has_function_privilege('authenticated', 'booking.admin_customer_message_products(date, date)', 'execute')
    and not has_function_privilege('authenticated', 'booking._customer_message_hits(date, date, bigint[])', 'execute'),
    'A1: products-RPC authenticatedille, apu ei');

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

  perform test.reset_rl();
  perform test.anon('10.258.0.1'); res := test.pub_book(v_rule, d, 2, 't258-a@example.com', 'Anna Asiakas'); perform test.logout();
  v_token := (res ->> 'token')::uuid;
  select o.id into v_ord from booking.orders o where o.public_token = v_token;

  perform test.reset_rl();
  perform test.anon('10.258.0.2'); res := test.pub_book(v_rule2, d + 1, 3, 't258-a@example.com', 'Anna Asiakas'); perform test.logout();
  select o.id into v_ord2 from booking.orders o where o.public_token = (res ->> 'token')::uuid;
  update booking.orders set customer_id = (select customer_id from booking.orders where id = v_ord) where id = v_ord2;

  perform test.reset_rl();
  perform test.anon('10.258.0.3'); res := test.pub_book(v_rule, d, 1, 't258-b@example.com', 'Bertta'); perform test.logout();

  perform test.reset_rl();
  perform test.anon('10.258.0.4'); res := test.pub_book(v_rule, d, 1, 't258-c@example.com', 'Peruttu'); perform test.logout();
  update booking.reservations set status = 'cancelled', cancelled_at = now()
   where order_id = (select id from booking.orders where public_token = (res ->> 'token')::uuid);

  perform test.reset_rl();
  perform test.anon('10.258.0.5'); res := test.pub_book(v_rule, d, 1, 't258-d@example.com', 'Vanhentunut'); perform test.logout();
  update booking.reservations set status = 'pending', hold_expires_at = now() - interval '1 hour'
   where order_id = (select id from booking.orders where public_token = (res ->> 'token')::uuid);

  perform test.reset_rl();
  perform test.anon('10.258.0.6'); res := test.pub_book(v_rule, d, 1, 't258-e@example.com', 'Johku'); perform test.logout();
  update booking.orders set external_source = 'johku', external_id = 't258-j' where public_token = (res ->> 'token')::uuid;

  insert into booking.waitlist_entries(product_id, rule_id, session_date, starts_at, ends_at, space_id, persons, customer_name, customer_email, status)
  select r.product_id, r.id, d,
         (d + r.start_time) at time zone 'Europe/Helsinki',
         (d + r.start_time + make_interval(mins => r.duration_minutes)) at time zone 'Europe/Helsinki',
         r.space_id, 1, 'Jono', 't258-jono@example.test', 'waiting'
    from booking.schedule_rules r where r.id = v_rule
  returning id into v_wl;

  insert into booking.customers(name, email) values ('Ostaja', 't258-buy@example.test') returning id into v_cu;
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

  perform test.login(u_staff);
  perform pg_temp.ck(test.code($q$select booking.admin_customer_message_products('2027-06-16','2027-06-16')$q$) = 'forbidden', 'B1: staff ei hae tuotteita');
  perform test.logout();

  perform test.login(u_mgr);

  -- Maanantai 16.6.: vain tuote 33 (Miesten/Kekri-testituote), ei 38.
  res := booking.admin_customer_message_products(d, d);
  select array_agg((e ->> 'id')::bigint order by (e ->> 'id')::bigint) into v_ids from jsonb_array_elements(res) e;
  perform pg_temp.ck(v_ids = array[33]::bigint[], 'C1: 16.6. vain tuote 33');
  perform pg_temp.ck((res -> 0 ->> 'name') is not null and (res -> 0 ->> 'category') is not null, 'C2: nimi ja kategoria');

  -- Pelkkä maksupäivä: vain lahjakortti 38.
  res := booking.admin_customer_message_products(d_pay, d_pay);
  select array_agg((e ->> 'id')::bigint order by (e ->> 'id')::bigint) into v_ids from jsonb_array_elements(res) e;
  perform pg_temp.ck(v_ids = array[38]::bigint[], 'C3: maksupäivä vain 38');

  -- Väli 10.–17.6.: 33 ja 38.
  res := booking.admin_customer_message_products(d_pay, d + 1);
  select array_agg((e ->> 'id')::bigint order by (e ->> 'id')::bigint) into v_ids from jsonb_array_elements(res) e;
  perform pg_temp.ck(v_ids = array[33, 38]::bigint[], 'C4: väli 33+38');

  -- Tyhjä päivä: tyhjä lista, ei katalogia.
  res := booking.admin_customer_message_products(d_empty, d_empty);
  perform pg_temp.ck(res = '[]'::jsonb, 'C5: tyhjä päivä → []');

  -- Sama kelpoisuus kuin hits: distinct product_id hits(null) = products RPC.
  -- hits on apufunktio ilman authenticated-executea → service_role.
  -- hits: ei granttia authenticated/service_role → superuser (logout)
  perform test.logout();
  perform pg_temp.ck(
    (select coalesce(array_agg(distinct h.product_id order by h.product_id), '{}'::bigint[])
       from booking._customer_message_hits(d, d, null) h)
    = array[33]::bigint[],
    'D1: hits(null) 16.6. = 33');
  perform pg_temp.ck(
    (select coalesce(array_agg(distinct h.product_id order by h.product_id), '{}'::bigint[])
       from booking._customer_message_hits(d_pay, d + 1, null) h)
    = array[33, 38]::bigint[],
    'D2: hits(null) väli = 33+38');

  -- Poissulut: peruttu/vanhentunut/johku/jono eivät tuo muita tuotteita.
  select count(*) into v_noint from booking._customer_message_hits(d, d, null) h
   where h.cust_name in ('Peruttu', 'Vanhentunut', 'Johku', 'Jono');
  perform pg_temp.ck(v_noint = 0 and v_wl is not null, 'D3: poissulut eivät osu');
  perform test.login(u_mgr);

  -- Esikatselu ei lähetä (regressio): products + preview.
  select count(*) into v_noint from booking.email_outbox where kind = 'event_message';
  res := booking.admin_customer_message_send(d, d, array[33], 'Hei', 'Teksti FI pitkä', 'Hi', 'Text EN long', false);
  perform pg_temp.ck((res ->> 'sent')::boolean = false
    and (select count(*) from booking.email_outbox where kind = 'event_message') = v_noint,
    'E1: esikatselu ei jonota');

  perform test.logout();
end $test$;

rollback;
