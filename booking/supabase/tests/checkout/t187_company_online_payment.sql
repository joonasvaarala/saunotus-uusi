-- t187: booking_187 yrityksen verkkomaksu (invoice_method = online).
-- Ajo migraation JA booking/supabase/tests/fixtures/10_test_helpers.sql:n JÄLKEEN, PG17 Tapio-dev.
--   psql -X -v ON_ERROR_STOP=0 -f booking/supabase/tests/fixtures/10_test_helpers.sql -f booking/supabase/tests/checkout/t187_company_online_payment.sql
-- Ei psql-metakomentoja (ei \i). Ei run.sh-listassa (run.sh ajaa vain tests/[0-9]*.test.sql). Aja kuten t186.
-- Yksi transaktio. Lopun poikkeus kumoaa kaiken. Ei lähetä mitään ulos. Vapaa vuoro haetaan; jos ei löydy → skip ja suora tilausrivi.
-- booking_189: Visma Pay ja MobilePay eivät käynnistä maksua. Online-yrityksen maksu kokeillaan Montoniolla.
-- Odotettu: ERROR: TESTRESULT pass=N fail=0 skip=S :: ALL OK
begin;
set local lock_timeout = '5s';
set local statement_timeout = '180s';

create temp table t187_r(st text, label text) on commit drop;
insert into booking.invoice_counters(series, last_seq) values ('L', 0) on conflict do nothing;  -- PATCH: kuten t185 (dev: invoices_series_fkey)
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  insert into t187_r values (case when coalesce(p_ok, false) then 'P' else 'F' end, p_label) $$;
create function pg_temp.skip(p_label text) returns void language sql as $$
  insert into t187_r values ('S', p_label) $$;
create function pg_temp.call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; s text;
begin execute 'select (' || p_sql || ')::jsonb' into r; return coalesce(r, 'null'::jsonb);
exception when others then get stacked diagnostics d = pg_exception_detail; s := sqlstate;
  return jsonb_build_object('state', s, 'err', case when s = 'BK001' then d else s end, 'msg', sqlerrm);
end $$;
create function pg_temp.bid() returns text language plpgsql volatile as $$
declare d text; s int; r int;
begin
  loop
    d := '9' || lpad((floor(random() * 1000000))::int::text, 6, '0');
    s := substr(d,1,1)::int*7 + substr(d,2,1)::int*9 + substr(d,3,1)::int*10 + substr(d,4,1)::int*5 + substr(d,5,1)::int*8 + substr(d,6,1)::int*4 + substr(d,7,1)::int*2;
    r := s % 11; exit when r <> 1;
  end loop;
  return d || '-' || case when r = 0 then 0 else 11 - r end;
end $$;
create function pg_temp.company(p_bid text, p_method text, p_ovt boolean) returns jsonb language sql as $$
  select jsonb_build_object('company_name', 'T187 Verkko Oy', 'business_id', p_bid, 'street', 'Testikatu 1', 'zip', '00100', 'city', 'Helsinki', 'reference', 'T187-VIITE')
      || case when p_method is not null then jsonb_build_object('invoice_method', p_method) else '{}'::jsonb end
      || case when p_ovt then jsonb_build_object('einvoice_address', '0037' || replace(p_bid, '-', ''), 'einvoice_operator', '003723327487') else '{}'::jsonb end $$;
-- suora yrityksen verkkomaksutilaus (ei vuoroa): pending, ei laskumaksua, rivit maksua varten
create function pg_temp.direct_online(p_bid text, p_email text, p_status text) returns bigint language plpgsql as $$
declare v_cc jsonb := booking._clean_company(pg_temp.company(p_bid, 'online', true)); v_cu bigint; v_o bigint;
begin
  v_cu := booking._upsert_company_customer('company', 'T187 Yhteys', p_email, '0401234567', v_cc, false, 'web', 'fi');
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_kind, hold_kind)
  values (v_cu, p_status, 'unpaid', 40, 'web', 'fi', 'company', 'checkout') returning id into v_o;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (v_o, 'T187 saunavuoro', 'product', 1, 40, 40, 25.5);
  perform booking._stamp_order_billing(v_o, v_cu, v_cc);
  return v_o;
end $$;
create function pg_temp.direct_private(p_email text, p_status text) returns bigint language plpgsql as $$
declare v_cu bigint; v_o bigint;
begin
  v_cu := booking._upsert_customer('T187 Yksityinen', p_email, '0401234567', false, 'web_booking', 'fi', 'v1');
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_kind, hold_kind)
  values (v_cu, p_status, 'unpaid', 40, 'web', 'fi', 'private', 'checkout') returning id into v_o;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (v_o, 'T187 saunavuoro', 'product', 1, 40, 40, 25.5);
  return v_o;
end $$;
-- verkkokaupan laskutilaus kuten t175: laskumaksu + unpaid → trigger → invoiced + luonnos
create function pg_temp.invoice_order(p_bid text, p_method text) returns bigint language plpgsql as $$
declare v_cc jsonb := booking._clean_company(pg_temp.company(p_bid, p_method, p_method = 'einvoice')); v_cu bigint; v_o bigint;
begin
  v_cu := booking._upsert_company_customer('company', 'T187 Lasku', 't187-inv-' || replace(p_bid, '-', '') || '@example.test', '0401234567', v_cc, false, 'web', 'fi');
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_kind)
  values (v_cu, 'confirmed', 'pending', 62, 'web', 'fi', 'company') returning id into v_o;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (v_o, 'T187 saunavuoro', 'product', 2, 31, 62, 25.5);
  perform booking._stamp_order_billing(v_o, v_cu, v_cc);
  insert into booking.payments(order_id, method, provider, status, amount) values (v_o, 'invoice', 'manual', 'pending', 62);
  update booking.orders set payment_status = 'unpaid' where id = v_o;
  return v_o;
end $$;

do $t$
declare
  run text := lower(substr(md5(random()::text), 1, 8));
  vp0 text; mp0 text; pc0 text; mo0 text; mode0 text; cinv0 text; mode_j jsonb; cinv_j jsonb;
  r jsonb; g jsonb; o bigint; o2 bigint; op bigint; oc bigint; oe bigint; ol bigint; tok uuid; tokp uuid;
  b1 text; b2 text; d date; rl record; k int; n int; np int; nf int; ns int; fails text;
  tprod bigint; tstart timestamptz; opt text; code text; methods jsonb;
begin
  select mode into vp0 from booking.integration_config where key = 'vismapay';
  select mode into mp0 from booking.integration_config where key = 'mobilepay';
  select mode into pc0 from booking.integration_config where key = 'procountor';
  select mode into mo0 from booking.integration_config where key = 'montonio';
  select value into mode_j from booking.settings where key = 'public_payment_mode';
  select value into cinv_j from booking.settings where key = 'checkout_company_invoice_enabled';
  mode0 := mode_j #>> '{}'; cinv0 := cinv_j #>> '{}';
  delete from booking.rate_limit_hits;
  update booking.settings set value = '500'::jsonb where key in ('rl_email_per_10min', 'rl_ip_per_10min', 'rl_order_get_per_10min');

  -- ===== 1 rakenne
  perform pg_temp.ck(md5(pg_get_functiondef('booking._clean_company(jsonb)'::regprocedure)) = '019579f7b2a615f691c206aeb214195d', '1 _clean_company = booking_187');
  perform pg_temp.ck(md5(pg_get_functiondef('booking._stamp_order_billing(bigint,bigint,jsonb)'::regprocedure)) = 'ded4c037a352e2b65b6f5e3100643334', '1 _stamp_order_billing = booking_187');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.public_create_booking(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb)'::regprocedure)) = '6bf51ffd45c259ef5546aa19f63f5066', '1 public_create_booking = booking_187');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.public_create_treatment_booking(bigint,timestamptz,integer,text,text,text,boolean,text,text,text,jsonb,text,jsonb)'::regprocedure)) = 'ece168b714a2478bd8a1e5d31f6e6fb7', '1 public_create_treatment_booking = booking_187');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.vismapay_payment_prepare(uuid,uuid)'::regprocedure)) in ('d1f8df803a45c2b77aa9f8554fc41890', 'd22cda7beb5cea5967b267e52d79ab99'), '1 vismapay_payment_prepare = booking_187 tai booking_189');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.public_payment_options(uuid)'::regprocedure)) in ('46834d95db5127935ad94e8759758ceb', '2557c31f99a77e70e5a3f35a3c44304e'), '1 public_payment_options = booking_187 tai booking_188');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.public_payment_link_info(uuid)'::regprocedure)) in ('1b729ef4d72dc925001169c38bad3315', '2c9e06b3153aa5c0edd25341024ae6a8'), '1 public_payment_link_info = booking_187 tai booking_188');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.public_get_booking(uuid)'::regprocedure)) = '31b07afa6d8e5b61ed9c044d39e76275', '1 public_get_booking = booking_187');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.public_get_order(uuid)'::regprocedure)) in ('5d0a5c1623ed4495be2d3ad0173284f1', '78d7b0b394dbd4d6d0a47a234d613159'), '1 public_get_order = booking_187 tai booking_188');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.orders_invoice_status_trg()'::regprocedure)) = '7f7eced664b101cb2672a78059c90682', '1 orders_invoice_status_trg = booking_187');
  perform pg_temp.ck(md5(pg_get_functiondef('booking._order_pays_by_invoice(text,jsonb)'::regprocedure)) = '40b7b4498592ad7ae0b2883941364573', '1 _order_pays_by_invoice = booking_187');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.public_create_booking_code(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb,text)'::regprocedure)) = '0741abee882e4a30cf46f5c8160de7a3'
    and md5(pg_get_functiondef('booking.mobilepay_payment_prepare(uuid,uuid,integer,text)'::regprocedure)) in ('e6888446c4b44e554d31c0920609ddb6', 'c6a64c1ff9353a5e581d72af10966665')
    and md5(pg_get_functiondef('booking.public_checkout_payment_options()'::regprocedure)) in ('e6f019284f2b222013133af83d8fface', '36b2d584cb3dd5abdf3bdf48e448c6aa')
    and md5(pg_get_functiondef('booking._public_pay_json(bigint)'::regprocedure)) = 'cc3e61dbdfbd9a816cd9c982c73820c5'
    and md5(pg_get_functiondef('booking.orders_invoice_draft_trg()'::regprocedure)) = 'a48fe50340cff5f6e9709ad46055ecb9'
    and md5(pg_get_functiondef('booking._order_invoice_locked(bigint)'::regprocedure)) = '96713008e2d1fce8c81aeda3a2b6b025', '1 riippuvuudet = tuotanto');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._clean_company(jsonb)', 'execute')
    and not has_function_privilege('authenticated', 'booking._clean_company(jsonb)', 'execute')
    and has_function_privilege('service_role', 'booking._clean_company(jsonb)', 'execute')
    and not has_function_privilege('anon', 'booking._stamp_order_billing(bigint,bigint,jsonb)', 'execute')
    and has_function_privilege('service_role', 'booking.vismapay_payment_prepare(uuid,uuid)', 'execute')
    and not has_function_privilege('anon', 'booking.vismapay_payment_prepare(uuid,uuid)', 'execute'), '1 proacl sisäiset ja Visma vain service_role');
  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_create_booking(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb)', 'execute')
    and has_function_privilege('anon', 'booking.public_create_treatment_booking(bigint,timestamptz,integer,text,text,text,boolean,text,text,text,jsonb,text,jsonb)', 'execute')
    and has_function_privilege('authenticated', 'booking.public_payment_options(uuid)', 'execute')
    and has_function_privilege('anon', 'booking.public_payment_link_info(uuid)', 'execute')
    and has_function_privilege('anon', 'booking.public_get_booking(uuid)', 'execute')
    and has_function_privilege('anon', 'booking.public_get_order(uuid)', 'execute')
    and not has_function_privilege('anon', 'booking.orders_invoice_status_trg()', 'execute')
    and not has_function_privilege('authenticated', 'booking.orders_invoice_status_trg()', 'execute'), '1 proacl julkiset funktiot ennallaan, trigger ei anonille');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._order_pays_by_invoice(text,jsonb)', 'execute')
    and not has_function_privilege('authenticated', 'booking._order_pays_by_invoice(text,jsonb)', 'execute')
    and not has_function_privilege('public', 'booking._order_pays_by_invoice(text,jsonb)', 'execute'), '1 apufunktio ei ole julkinen');
  perform pg_temp.ck(booking._order_pays_by_invoice('private', '{}'::jsonb) = false
    and booking._order_pays_by_invoice('company', '{"invoice_method":"einvoice"}'::jsonb)
    and booking._order_pays_by_invoice('company', '{"invoice_method":"pdf"}'::jsonb)
    and booking._order_pays_by_invoice('company', '{}'::jsonb)
    and not booking._order_pays_by_invoice('company', '{"invoice_method":"online"}'::jsonb), '1 apufunktio: vain laskuyritys');
  perform pg_temp.ck(mode0 = 'hold_until_paid' and coalesce(cinv0, 'true') = 'true', '1 asetukset hold_until_paid ja yrityslasku päällä');
  perform pg_temp.ck(mp0 = 'test' and vp0 = 'test' and pc0 is distinct from 'live', '1 integraatiot: mobilepay/vismapay test, procountor ei live');
  insert into booking.integration_config(key, mode, settings) values ('montonio', 'test', '{"approved_by":"t187"}'::jsonb)
    on conflict (key) do update set mode = 'test', settings = booking.integration_config.settings || '{"approved_by":"t187"}'::jsonb;

  b1 := pg_temp.bid(); b2 := pg_temp.bid();

  -- ===== 2 _clean_company
  r := booking._clean_company(pg_temp.company(b1, 'online', false));
  perform pg_temp.ck(r ->> 'invoice_method' = 'online' and r ->> 'einvoice_address' is null and r ->> 'einvoice_operator' is null, '2 online ilman OVT:tä');
  r := booking._clean_company(pg_temp.company(b1, 'online', true));
  perform pg_temp.ck(r ->> 'invoice_method' = 'online' and r ->> 'einvoice_address' is null and r ->> 'einvoice_operator' is null, '2 online pudottaa annetun OVT:n');
  r := booking._clean_company(pg_temp.company(b1, 'online', false) || '{"require_einvoice":true}');
  perform pg_temp.ck(r ->> 'invoice_method' = 'online' and r ->> 'einvoice_address' is null, '2 online + require_einvoice ei vaadi OVT:tä');
  r := pg_temp.call(format('booking._clean_company(%L::jsonb)', pg_temp.company(b1, 'einvoice', false)));
  perform pg_temp.ck(r ->> 'state' = 'BK001' and r ->> 'err' = 'einvoice_incomplete', '2 verkkolasku ilman OVT:tä ennallaan');
  r := booking._clean_company(pg_temp.company(b1, 'pdf', true));
  perform pg_temp.ck(r ->> 'invoice_method' = 'pdf' and r ->> 'einvoice_address' is null, '2 pdf ennallaan');
  r := pg_temp.call(format('booking._clean_company(%L::jsonb)', pg_temp.company(b1, 'foo', false)));
  perform pg_temp.ck(r ->> 'state' = 'BK001' and r ->> 'err' = 'invalid_invoice_method', '2 foo → BK001 invalid_invoice_method');
  r := pg_temp.call(format('booking._clean_company(%L::jsonb)', pg_temp.company('1234567-0', 'online', false)));
  perform pg_temp.ck(r ->> 'err' = 'invalid_business_id', '2 online tarkistaa y-tunnuksen');

  -- ===== 3 julkinen vuoro, yritys + online. Varapolku: suora rivi.
  r := null;
  <<haku>>
  for rl in select sr.id, sr.weekdays from booking.schedule_rules sr where sr.active and sr.mode = 'shared' and sr.kind = 'regular' order by sr.id loop
    for k in 3..45 loop
      d := current_date + k;
      continue when not (extract(isodow from d)::smallint = any (rl.weekdays));
      execute 'set local role anon';
      r := pg_temp.call(format($q$booking.public_create_booking(%s, %L::date, 2, 'T187 Yhteys', %L, '0401234567', false, 'fi', null, 'company', %L::jsonb, null)$q$,
        rl.id, d, 't187-web-' || run || '-' || k || '@example.test', pg_temp.company(b1, 'online', true)));
      execute 'reset role';
      exit haku when coalesce((r ->> 'ok')::boolean, false);
    end loop;
  end loop;
  if r is null or not coalesce((r ->> 'ok')::boolean, false) then
    perform pg_temp.skip('3 public_create_booking: vapaata yleistä vuoroa ei löytynyt, käytetään suoraa tilausriviä');
    o := pg_temp.direct_online(b1, 't187-direct-' || run || '@example.test', 'pending');
    select public_token into tok from booking.orders where id = o;
  else
    tok := (r ->> 'token')::uuid;
    select id into o from booking.orders where public_token = tok;
    perform pg_temp.ck((select status from booking.orders where id = o) = 'pending'
      and (select hold_kind from booking.orders where id = o) = 'checkout'
      and (select payment_status from booking.orders where id = o) = 'unpaid'
      and (r ->> 'checkout_state') = 'awaiting_payment'
      and (r ->> 'hold_expires_at')::timestamptz between now() + interval '10 minutes' and now() + interval '20 minutes', '3 pito pending/checkout, noin 15 min');
  end if;
  perform pg_temp.ck(o is not null
    and (select customer_kind from booking.orders where id = o) = 'company'
    and (select billing ->> 'invoice_method' from booking.orders where id = o) = 'online'
    and (select billing ->> 'company' from booking.orders where id = o) = 'T187 Verkko Oy'
    and (select billing ->> 'business_id' from booking.orders where id = o) = b1
    and (select billing ->> 'einvoice_address' from booking.orders where id = o) is null
    and (select billing ->> 'einvoice_operator' from booking.orders where id = o) is null
    and (select invoice_reference from booking.orders where id = o) = 'T187-VIITE'
    and not exists (select 1 from booking.payments p where p.order_id = o and p.method = 'invoice')
    and not exists (select 1 from booking.invoices i where i.order_id = o), '3 ei laskua eikä laskumaksua, billing online');

  -- ===== 4 maksutavat ja kentät
  op := pg_temp.direct_private('t187-priv-' || run || '@example.test', 'pending');
  select public_token into tokp from booking.orders where id = op;
  r := booking.public_payment_options(tok);
  g := booking.public_payment_options(tokp);
  perform pg_temp.ck(coalesce((r -> 'order' ->> 'can_pay_online')::boolean, false)
    and (select jsonb_agg(m ->> 'code' order by m ->> 'code') from jsonb_array_elements(r -> 'methods') m) = (select jsonb_agg(m ->> 'code' order by m ->> 'code') from jsonb_array_elements(g -> 'methods') m)  -- PATCH: body sisältää tilauksen tokenin
    and coalesce((g -> 'order' ->> 'can_pay_online')::boolean, false), '4 can_pay_online ja samat maksutavat kuin yksityisellä');
  g := booking.public_get_booking(tok);
  r := booking.public_get_order(tok);
  perform pg_temp.ck(g ->> 'invoice_method' = 'online' and g ->> 'customer_kind' = 'company'
    and r ->> 'invoice_method' = 'online' and r ->> 'customer_kind' = 'company', '4 get_booking ja get_order palauttavat invoice_method');

  -- ===== 5 Montonio sallii online-yrityksen (Visma Pay ja MobilePay eivät käynnistä maksua)
  insert into booking.integration_config(key, mode, settings) values ('montonio', 'test', '{"approved_by":"t187"}'::jsonb)
    on conflict (key) do update set mode = 'test', settings = booking.integration_config.settings || '{"approved_by":"t187"}'::jsonb;
  o2 := pg_temp.direct_online(pg_temp.bid(), 't187-mp-' || run || '@example.test', 'pending');
  r := booking.montonio_payment_prepare((select public_token from booking.orders where id = o2), null, 'cardPayments');
  perform pg_temp.ck(coalesce((r ->> 'ok')::boolean, false) and r ->> 'order_number' is not null and r ->> 'code' is distinct from 'order_not_payable', '5 Montonio-valmistelu sallii online-yrityksen ' || left(coalesce(r::text, ''), 120));

  -- ===== 6 maksu + kuitti, ei laskua
  if coalesce((r ->> 'ok')::boolean, false) then
    g := pg_temp.call(format('booking.payment_mark_paid(%L, %L, %s, %L::jsonb)', 'montonio', r ->> 'order_number', r ->> 'amount', '{"t187":true}'));
    perform pg_temp.ck(coalesce((g ->> 'ok')::boolean, false)
      and (select status from booking.orders where id = o2) = 'confirmed'
      and (select payment_status from booking.orders where id = o2) = 'paid'
      and not booking._order_invoice_locked(o2)
      and not exists (select 1 from booking.invoices i where i.order_id = o2)
      and exists (select 1 from booking.receipts rc where rc.order_id = o2 and rc.kind = 'receipt'
                    and rc.snapshot -> 'buyer' ->> 'company' = 'T187 Verkko Oy'
                    and rc.snapshot -> 'buyer' ->> 'business_id' is not null
                    and rc.text_body like '%T187 Verkko Oy%')
      and not exists (select 1 from booking.email_outbox e where e.order_id = o2 and e.kind = 'invoice_pdf'), '6 maksettu, kuitti yritystiedoin, ei laskua eikä invoice_pdf');
  else
    perform pg_temp.ck(false, '6 Montonio-valmistelu epäonnistui, maksua ei voitu kuitata');
  end if;

  -- ===== 7 vanhentunut pito perutaan kuten yksityiseltä
  oc := pg_temp.direct_online(pg_temp.bid(), 't187-exp-c-' || run || '@example.test', 'expired');
  op := pg_temp.direct_private('t187-exp-p-' || run || '@example.test', 'expired');
  perform booking._cancel_unpaid_expired_orders();
  perform pg_temp.ck((select status from booking.orders where id = oc) = 'cancelled'
    and (select status from booking.orders where id = op) = 'cancelled', '7 online-yritys ja yksityinen peruuntuvat samoin');

  -- ===== 8 trigger ei merkitse online-tilausta laskutetuksi
  oe := pg_temp.direct_online(pg_temp.bid(), 't187-trg-' || run || '@example.test', 'confirmed');
  update booking.orders set hold_kind = null where id = oe;
  insert into booking.payments(order_id, method, provider, status, amount) values (oe, 'invoice', 'manual', 'pending', 40);
  update booking.orders set payment_status = 'unpaid' where id = oe;
  perform pg_temp.ck((select payment_status from booking.orders where id = oe) = 'unpaid'
    and not exists (select 1 from booking.invoices i where i.order_id = oe), '8 invoice-maksu ei tee online-tilauksesta invoiced eikä luonnosta');

  -- ===== 9 verkkolasku ennallaan + booking_185 lukko
  ol := pg_temp.invoice_order(b2, 'einvoice');
  perform pg_temp.ck((select status from booking.orders where id = ol) = 'confirmed'
    and (select payment_status from booking.orders where id = ol) = 'invoiced'
    and exists (select 1 from booking.invoices i where i.order_id = ol and i.kind = 'debit' and i.status = 'draft' and i.invoice_no is null)
    and not exists (select 1 from booking.email_outbox e where e.order_id = ol and e.kind = 'invoice_pdf'), '9 verkkolasku: confirmed, invoiced, luonnos, ei sähköpostia');
  r := booking.vismapay_payment_prepare((select public_token from booking.orders where id = ol), null);
  g := booking.public_payment_options((select public_token from booking.orders where id = ol));
  perform pg_temp.ck(r ->> 'code' = 'payment_not_online' and coalesce((g -> 'order' ->> 'can_pay_online')::boolean, true) = false, '9 verkkolaskun verkkomaksu estetty');
  update booking.invoices set status = 'sent', locked_at = now() where order_id = ol and kind = 'debit';
  perform pg_temp.ck(booking._order_invoice_locked(ol), '9b booking_185 lukko yhä päällä lähetetylle laskulle');
  r := booking.vismapay_payment_prepare((select public_token from booking.orders where id = ol), null);
  perform pg_temp.ck(r ->> 'code' = 'payment_not_online', '9b lukittu lasku: verkkomaksun aloitus estetty');

  -- ===== 10 pdf ennallaan
  o := pg_temp.invoice_order(pg_temp.bid(), 'pdf');
  perform pg_temp.ck((select payment_status from booking.orders where id = o) = 'invoiced'
    and (select count(*) from booking.invoices i where i.order_id = o and i.kind = 'debit' and i.invoice_no is not null) = 1
    and (select count(*) from booking.email_outbox e where e.order_id = o and e.kind = 'invoice_pdf') = 1, '10 pdf: numero ja yksi invoice_pdf');
  r := booking.public_payment_options((select public_token from booking.orders where id = o));
  perform pg_temp.ck(coalesce((r -> 'order' ->> 'can_pay_online')::boolean, true) = false, '10 pdf-verkkomaksu estetty');

  -- ===== 11 hallinnan yritys, invoice_method null
  o := pg_temp.direct_online(pg_temp.bid(), 't187-admin-' || run || '@example.test', 'confirmed');
  update booking.orders set source_channel = 'admin', hold_kind = null,
    billing = (select billing - 'invoice_method' from booking.orders where id = o) where id = o;
  insert into booking.payments(order_id, method, provider, status, amount, link_token)
  values (o, 'visma_pay', 'visma_pay', 'pending', 40, gen_random_uuid());
  r := booking.public_payment_link_info((select link_token from booking.payments where order_id = o and provider = 'visma_pay' limit 1));
  g := booking.public_payment_options((select public_token from booking.orders where id = o));
  perform pg_temp.ck(r ->> 'status' = 'not_payable' and r ->> 'reason' = 'order_not_payable'
    and coalesce((g -> 'order' ->> 'can_pay_online')::boolean, true) = false, '11 hallinnan yritys: maksulinkki not_payable, ei verkkomaksua');
  r := booking.vismapay_payment_prepare((select public_token from booking.orders where id = o), null);
  perform pg_temp.ck(r ->> 'code' = 'payment_not_online', '11 hallinnan yritys: verkkomaksun aloitus estetty');

  -- ===== 12 yksityinen ennallaan
  r := null;
  <<yks>>
  for rl in select sr.id, sr.weekdays from booking.schedule_rules sr where sr.active and sr.mode = 'shared' and sr.kind = 'regular' order by sr.id loop
    for k in 3..45 loop
      d := current_date + k;
      continue when not (extract(isodow from d)::smallint = any (rl.weekdays));
      execute 'set local role anon';
      r := pg_temp.call(format($q$booking.public_create_booking(%s, %L::date, 1, 'T187 Yksityinen', %L, '0401234567', false, 'fi', null, 'private', null, null)$q$,
        rl.id, d, 't187-pri-' || run || '-' || k || '@example.test'));
      execute 'reset role';
      exit yks when coalesce((r ->> 'ok')::boolean, false);
    end loop;
  end loop;
  if r is null or not coalesce((r ->> 'ok')::boolean, false) then
    perform pg_temp.skip('12 public_create_booking yksityinen: vapaata vuoroa ei löytynyt');
    perform pg_temp.ck((select status from booking.orders where public_token = tokp) = 'pending'
      and (select customer_kind from booking.orders where public_token = tokp) = 'private'
      and not exists (select 1 from booking.payments p where p.order_id = (select id from booking.orders where public_token = tokp) and p.method = 'invoice'), '12 suora yksityinen: pending, ei laskumaksua');
  else
    select id into o from booking.orders where public_token = (r ->> 'token')::uuid;
    g := booking.public_payment_options((r ->> 'token')::uuid);
    perform pg_temp.ck((select status from booking.orders where id = o) = 'pending'
      and (select customer_kind from booking.orders where id = o) = 'private'
      and not exists (select 1 from booking.payments p where p.order_id = o and p.method = 'invoice')
      and coalesce((g -> 'order' ->> 'can_pay_online')::boolean, false), '12 yksityinen pending, ei laskumaksua, can_pay_online');
  end if;

  -- ===== 13 hoito
  select pc.product_id into tprod from booking.product_config pc
   where pc.public_slots and coalesce(pc.bookable, true) and not coalesce(pc.option_required, false)
   order by pc.product_id limit 1;
  if tprod is null then
    select pc.product_id into tprod from booking.product_config pc where pc.public_slots and coalesce(pc.bookable, true) order by pc.product_id limit 1;
    select po.code into opt from booking.product_options po where po.product_id = tprod and po.active order by po.id limit 1;
  end if;
  tstart := null;
  if tprod is not null then
    select q.starts_at into tstart from booking.public_treatment_availability(tprod, current_date + 2, current_date + 15, 1) q
     where q.status = 'available' order by 1 limit 1;
  end if;
  if tprod is null or tstart is null then
    perform pg_temp.skip('13 hoito: tuotetta tai vapaata aikaa ei löytynyt');
  else
    execute 'set local role anon';
    r := pg_temp.call(format($q$booking.public_create_treatment_booking(%s, %L::timestamptz, 1, 'T187 Hoito', %L, '0401234567', false, 'fi', null, 'company', %L::jsonb, %L, null)$q$,
      tprod, tstart, 't187-tr-' || run || '@example.test', pg_temp.company(pg_temp.bid(), 'online', true), opt));
    execute 'reset role';
    if coalesce((r ->> 'ok')::boolean, false) then
      select id into o from booking.orders where public_token = (r ->> 'token')::uuid;
      perform pg_temp.ck((select status from booking.orders where id = o) = 'pending'
        and (select hold_kind from booking.orders where id = o) = 'checkout'
        and (select billing ->> 'invoice_method' from booking.orders where id = o) = 'online'
        and (select billing ->> 'einvoice_address' from booking.orders where id = o) is null
        and not exists (select 1 from booking.payments p where p.order_id = o and p.method = 'invoice')
        and not exists (select 1 from booking.invoices i where i.order_id = o), '13 hoito + online: pito, ei laskua');
    else
      perform pg_temp.ck(false, '13 hoito epäonnistui: ' || coalesce(r ->> 'code', r ->> 'err', r::text));
    end if;
  end if;

  -- ===== 14 lahjakoodi (ei vuosikortti): delegoi public_create_bookingille
  code := 'T187' || upper(run);
  insert into booking.discount_codes(code, kind, value, active) values (code, 'percent', 10, true);
  r := null;
  <<koodi>>
  for rl in select sr.id, sr.weekdays from booking.schedule_rules sr where sr.active and sr.mode = 'shared' and sr.kind = 'regular' order by sr.id loop
    for k in 3..45 loop
      d := current_date + k;
      continue when not (extract(isodow from d)::smallint = any (rl.weekdays));
      execute 'set local role anon';
      r := pg_temp.call(format($q$booking.public_create_booking_code(%s, %L::date, 1, 'T187 Koodi', %L, '0401234567', false, 'fi', null, 'company', %L::jsonb, null, %L)$q$,
        rl.id, d, 't187-code-' || run || '-' || k || '@example.test', pg_temp.company(pg_temp.bid(), 'online', false), code));
      execute 'reset role';
      exit koodi when coalesce((r ->> 'ok')::boolean, false);
    end loop;
  end loop;
  if r is null or not coalesce((r ->> 'ok')::boolean, false) then
    perform pg_temp.skip('14 lahjakoodi: vapaata vuoroa ei löytynyt');
  else
    select id into o from booking.orders where public_token = (r ->> 'token')::uuid;
    perform pg_temp.ck((select status from booking.orders where id = o) = 'pending'
      and (select hold_kind from booking.orders where id = o) = 'checkout'
      and (select customer_kind from booking.orders where id = o) = 'company'
      and (select billing ->> 'invoice_method' from booking.orders where id = o) = 'online'
      and not exists (select 1 from booking.payments p where p.order_id = o and p.method = 'invoice')
      and not exists (select 1 from booking.invoices i where i.order_id = o), '14 lahjakoodi + online: sama pito, ei laskua');
  end if;

  -- asetukset ja integraatiot takaisin (rollback kumoaa muutenkin)
  update booking.settings set value = mode_j where key = 'public_payment_mode';
  update booking.settings set value = cinv_j where key = 'checkout_company_invoice_enabled' and cinv_j is not null;
  update booking.integration_config set mode = vp0 where key = 'vismapay';
  if mo0 is null then delete from booking.integration_config where key = 'montonio';
  else update booking.integration_config set mode = mo0 where key = 'montonio'; end if;
  perform pg_temp.ck((select mode from booking.integration_config where key = 'vismapay') = vp0
    and (select mode from booking.integration_config where key = 'mobilepay') = mp0
    and (select mode from booking.integration_config where key = 'procountor') = pc0
    and (select mode from booking.integration_config where key = 'montonio') is not distinct from mo0
    and (select value #>> '{}' from booking.settings where key = 'public_payment_mode') = mode0, '1b asetukset ja integraatiot palautettu');

  select count(*) filter (where st = 'P'), count(*) filter (where st = 'F'), count(*) filter (where st = 'S'),
         coalesce(string_agg(label, ' | ') filter (where st = 'F'), '')
    into np, nf, ns, fails from t187_r;
  raise exception 'TESTRESULT pass=% fail=% skip=% :: %', np, nf, ns, case when nf = 0 then 'ALL OK' else fails end;
end $t$;
rollback;
