-- Visma Pay (booking_120): tila pysyy off, test vaatii approved_by, kirjaus on idempotentti ja hyvitys tekee H-kuitin.
begin;
set local search_path = extensions, public;
select no_plan();

select is((select mode from booking.integration_config where key = 'vismapay'), 'off', 'migraatio jättää vismapayn off-tilaan');

select throws_ok(
  $$update booking.integration_config set mode = 'test' where key = 'vismapay'$$,
  'BK001', 'Visma Payta ei voi kytkeä test- tai live-tilaan ilman settings.approved_by -merkintää',
  'test ilman approved_by estetään');

select lives_ok(
  $$update booking.integration_config set mode = 'test', settings = settings || '{"approved_by":"sql-testi"}'::jsonb where key = 'vismapay'$$,
  'test approved_bylla onnistuu');

insert into booking.customers(name, email, phone) values ('Visa Testi', 'visa.pay@example.test', '+358401234567');
insert into booking.orders(customer_id, status, payment_status, total_gross, currency, source_channel, locale, customer_kind)
select id, 'confirmed', 'unpaid', 40, 'EUR', 'web', 'fi', 'private' from booking.customers where email = 'visa.pay@example.test';
insert into booking.order_items(order_id, kind, product_name, quantity, unit_price_gross, line_total_gross, vat_rate)
select o.id, 'product', 'Visma testituote', 1, 40, 40, 25.5 from booking.orders o join booking.customers c on c.id = o.customer_id where c.email = 'visa.pay@example.test';

create temp table vp_prep as
select booking.vismapay_payment_prepare((select public_token from booking.orders o join booking.customers c on c.id = o.customer_id where c.email = 'visa.pay@example.test'), null) as j;

select ok((select j ->> 'ok' = 'true' and not (j ? 'code') from vp_prep), 'prepare test-tilassa onnistuu');
select ok((select (j ->> 'order_number') ~ '^sauna-o[0-9]+-p[0-9]+-a[0-9]+$' from vp_prep), 'tilausnumero on sauna-o…-p…-a…');
select is((select (j ->> 'amount_minor')::int from vp_prep), 4000, 'summa on 4000 senttiä');

select is(
  (select count(*)::int from booking.receipts r join booking.orders o on o.id = r.order_id join booking.customers c on c.id = o.customer_id where c.email = 'visa.pay@example.test'),
  0, 'prepare ei tee kuittia');

select is(
  (select status from booking.payments p join booking.orders o on o.id = p.order_id join booking.customers c on c.id = o.customer_id where c.email = 'visa.pay@example.test' and p.provider = 'visma_pay' and p.provider_ref like 'sauna-%' order by p.id desc limit 1),
  'pending', 'maksu on pending');

-- toinen prepare kesken olevan avauksen aikana
select is(
  (select booking.vismapay_payment_prepare((select public_token from booking.orders o join booking.customers c on c.id = o.customer_id where c.email = 'visa.pay@example.test'), null) ->> 'code'),
  'payment_in_progress', 'päällekkäinen avaus ei luo toista veloitusta');

select is(
  (select booking.vismapay_payment_apply(
      (select provider_ref from booking.payments p join booking.orders o on o.id = p.order_id join booking.customers c on c.id = o.customer_id where c.email = 'visa.pay@example.test' and p.provider_ref like 'sauna-%'),
      'paid', 1, '{"test":true}'::jsonb) ->> 'code'),
  'amount_mismatch', 'väärä summa ei merkitse maksetuksi');

select is(
  (select status from booking.payments p where p.provider_ref like 'sauna-%' and p.order_id in (select o.id from booking.orders o join booking.customers c on c.id = o.customer_id where c.email = 'visa.pay@example.test')),
  'pending', 'summaerotus jättää maksun pendingiksi');

select is(
  (select booking.vismapay_payment_apply(
      (select provider_ref from booking.payments p join booking.orders o on o.id = p.order_id join booking.customers c on c.id = o.customer_id where c.email = 'visa.pay@example.test' and p.provider_ref like 'sauna-%'),
      'paid', 40, '{"source":{"object":"card","brand":"Visa","last4":"1881"}}'::jsonb) ->> 'outcome'),
  'paid', 'oikea summa merkitsee maksetuksi');

select ok(
  (select receipt_no like 'K-%' from booking.receipts r join booking.orders o on o.id = r.order_id join booking.customers c on c.id = o.customer_id where c.email = 'visa.pay@example.test' and r.kind = 'receipt'),
  'myyntikuitti on K-sarjaa');

select is(
  (select booking.vismapay_payment_apply(
      (select provider_ref from booking.payments p join booking.orders o on o.id = p.order_id join booking.customers c on c.id = o.customer_id where c.email = 'visa.pay@example.test' and p.provider_ref like 'sauna-%'),
      'paid', 40, '{}'::jsonb) ->> 'already'),
  'true', 'toinen kirjaus on idempotentti');

select is(
  (select count(*)::int from booking.receipts r join booking.orders o on o.id = r.order_id join booking.customers c on c.id = o.customer_id where c.email = 'visa.pay@example.test' and r.kind = 'receipt'),
  1, 'toinen kirjaus ei tee toista kuittia');

select is((select payment_status from booking.orders o join booking.customers c on c.id = o.customer_id where c.email = 'visa.pay@example.test'), 'paid', 'tilaus on maksettu');

-- epäonnistunut yritys
insert into booking.orders(customer_id, status, payment_status, total_gross, currency, source_channel, locale, customer_kind)
select id, 'confirmed', 'unpaid', 10, 'EUR', 'web', 'fi', 'private' from booking.customers where email = 'visa.pay@example.test' order by id desc limit 1;
insert into booking.order_items(order_id, kind, product_name, quantity, unit_price_gross, line_total_gross, vat_rate)
select o.id, 'product', 'Epäonnistuva', 1, 10, 10, 13.5
  from booking.orders o join booking.customers c on c.id = o.customer_id
 where c.email = 'visa.pay@example.test' and o.total_gross = 10;

select ok((select (booking.vismapay_payment_prepare((select public_token from booking.orders where total_gross = 10 and customer_id = (select id from booking.customers where email = 'visa.pay@example.test') order by id desc limit 1), null) ->> 'ok') = 'true'), 'toinen prepare onnistuu');
select is(
  (select booking.vismapay_payment_apply((select provider_ref from booking.payments where order_id = (select id from booking.orders where total_gross = 10 order by id desc limit 1) and provider_ref like 'sauna-%'), 'failed', null, '{}'::jsonb) ->> 'outcome'),
  'failed', 'failed merkitsee epäonnistuneeksi');
select is((select count(*)::int from booking.receipts where order_id = (select id from booking.orders where total_gross = 10 order by id desc limit 1)), 0, 'epäonnistunut maksu ei tee kuittia');

-- hyvitys: osittainen ja täysi
insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, lines)
select p.id, p.order_id, 10, 'Osittainen testi', 'requested', 'visma_pay',
       jsonb_build_array(jsonb_build_object('payment_line_id', (select id from booking.payment_lines where payment_id = p.id order by id limit 1), 'amount', 10))
  from booking.payments p
  join booking.orders o on o.id = p.order_id
  join booking.customers c on c.id = o.customer_id
 where c.email = 'visa.pay@example.test' and p.status = 'paid';

select is(jsonb_array_length((select booking.vismapay_refund_claim(null, 20) -> 'claimed')), 1, 'hyvitys varataan');
select lives_ok($$select booking.vismapay_refund_stamp((select id from booking.refunds where reason = 'Osittainen testi'), '9001', 'instant', '{"type":"instant"}'::jsonb)$$, 'leima ennen valmista');
select is((select booking.vismapay_refund_complete((select id from booking.refunds where reason = 'Osittainen testi'), '9001', '{"type":"instant"}'::jsonb) ->> 'ok'), 'true', 'osittainen hyvitys valmistuu');
select is((select status from booking.payments p join booking.orders o on o.id = p.order_id join booking.customers c on c.id = o.customer_id where c.email = 'visa.pay@example.test' and p.status in ('partially_refunded','refunded') limit 1), 'partially_refunded', 'maksu on osittain hyvitetty');
select ok((select receipt_no like 'H-%' from booking.receipts where kind = 'refund_receipt' and refund_id = (select id from booking.refunds where reason = 'Osittainen testi')), 'hyvityskuitti on H-sarjaa');
select is((select booking.vismapay_refund_complete((select id from booking.refunds where reason = 'Osittainen testi'), '9001', '{}'::jsonb) ->> 'already'), 'true', 'hyvityksen uusinta on idempotentti');

select test.anon();
select throws_ok($$select booking.vismapay_payment_prepare('00000000-0000-4000-8000-000000000001'::uuid, null)$$, '42501', null, 'anon ei valmistele Visma-maksua');
select throws_ok($$select booking.vismapay_refund_claim(null, 1)$$, '42501', null, 'anon ei varaa hyvitystä');
select test.logout();

select test.mk_user('vp-random@example.test') as uid \gset
select test.login(:'uid');
select throws_ok($$select booking.admin_set_vismapay_mode('live', 'ei saa')$$, 'BK001', null, 'ilman settings.edit ei voi vaihtaa tilaa');
select test.logout();

update booking.integration_config set mode = 'off' where key = 'vismapay';
select is((select mode from booking.integration_config where key = 'vismapay'), 'off', 'testi palauttaa tilan off');
select is(jsonb_array_length((select booking.vismapay_refund_claim(null, 5) -> 'claimed')), 0, 'off-tilassa hyvityksiä ei varata');

select * from finish();
rollback;
