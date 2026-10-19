-- t80: pikakassa ja kylmälaite (booking_80–82). Rollback-transaktio: lopuksi tahallinen poikkeus.
-- Hinta tulee tuotteesta. Anon ei näe hallinnan RPC:itä eikä vismapay_payment_preparea.
-- Visma dry_run ei merkitse maksetuksi. Korttipääte on rivinä mutta pois päältä. Käteistä ei ole.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t80.log', '', true);
create function public.t80_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t80.log', coalesce(current_setting('t80.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t80_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 160) end;
end $$;
create function public.t80_call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text; s text;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return jsonb_build_object('err', case when s = 'BK001' then d else s || ':' || left(m, 160) end, 'message', m);
end $$;
create function public.t80_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t80_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_staff uuid := gen_random_uuid();
  u_mgr uuid := gen_random_uuid();
  p_vichy bigint; p_gift bigint; p_beer bigint; p_free bigint; p_grape bigint;
  dev text := 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  dev_grape text := 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  items jsonb; res jsonb; tok uuid; pos_tok uuid; pos_id bigint; i int; n_ok int := 0;
  pay_id bigint; exp timestamptz; log text; npass int; nfail int;
  v_c1 bigint; v_c2 bigint; v_hold timestamptz; v_space bigint; v_pre uuid;
begin
  perform public.t80_ck(not has_function_privilege('anon', 'booking.admin_pos_catalog()', 'execute'), 'G1 anon ei admin_pos_catalog');
  perform public.t80_ck(not has_function_privilege('anon', 'booking.admin_pos_checkout(jsonb,text,text)', 'execute'), 'G2 anon ei checkout');
  perform public.t80_ck(not has_function_privilege('anon', 'booking.vismapay_payment_prepare(uuid)', 'execute'), 'G3 anon ei vismapay');
  perform public.t80_ck(has_function_privilege('anon', 'booking.public_drinks_catalog(text)', 'execute'), 'G4 anon saa katalogin');
  perform public.t80_ck(has_function_privilege('anon', 'booking.public_drinks_checkout(text,jsonb,text,text)', 'execute'), 'G5 anon saa kassan');
  perform public.t80_ck(to_regprocedure('booking.mobilepay_payment_prepare(uuid,uuid,integer)') is null, 'G6 vanha 3-arg prepare poissa');
  perform public.t80_ck(to_regprocedure('booking.mobilepay_payment_prepare(uuid,uuid,integer,text)') is not null, 'G7 4-arg prepare olemassa');
  perform public.t80_ck(not exists (select 1 from booking.pos_tenders where code = 'cash' or handler = 'cash'), 'G8 ei käteistä');
  perform public.t80_ck((select active from booking.pos_tenders where code = 'card_terminal') = false, 'G9 korttipääte pois');
  perform public.t80_ck((select unavailable_reason from booking.pos_tenders where code = 'card_terminal') = 'not_implemented', 'G10 pääte not_implemented');

  insert into kb.products(name, category, price, vat_rate, active) values ('Vichy', 'other', 3.00, 13.5, true) returning id into p_vichy;
  insert into kb.products(name, category, price, vat_rate, active) values ('Lahjakortti testi', 'gift_card', 58, 0, true) returning id into p_gift;
  insert into kb.products(name, category, price, vat_rate, active) values ('Olut', 'other', 4, 25.5, true) returning id into p_beer;
  insert into kb.products(name, name_en, category, price, vat_rate, active) values ('Alkoholiton vichy', 'Non-alcoholic vichy', 'other', 3, 13.5, true) returning id into p_free;
  insert into kb.products(name, category, price, vat_rate, active) values ('Viinirypälemehu', 'other', 2.50, 13.5, true) returning id into p_grape;
  insert into booking.product_config(product_id, sale_kind, bookable, pos_enabled, pos_sort, fridge_sale)
  values (p_vichy, 'other', false, true, 10, true), (p_gift, 'other', false, true, 20, false), (p_grape, 'other', false, false, 30, true);
  perform public.t80_ck(public.t80_try(format('insert into booking.product_config(product_id, sale_kind, fridge_sale) values (%s, ''other'', true)', p_beer)) = 'age_restricted', 'A1 olut ei kylmälaitteeseen');
  insert into booking.product_config(product_id, sale_kind, fridge_sale) values (p_free, 'other', true);
  perform public.t80_ck((select fridge_sale from booking.product_config where product_id = p_free), 'A2 alkoholiton sallittu');
  insert into booking.product_qr(code, product_id, label) values (dev, p_vichy, 'Pukuhuone'), (dev_grape, p_grape, null);

  insert into auth.users(id, email) values (u_staff, 't80-staff@example.test'), (u_mgr, 't80-mgr@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_staff, 't80-staff@example.test', 't80 staff', 'staff'),
    (u_mgr, 't80-mgr@example.test', 't80 mgr', 'manager');

  perform public.t80_login(u_staff);
  perform public.t80_ck((select count(*) from jsonb_array_elements(booking.admin_pos_catalog()) e where (e->>'product_id')::bigint = p_vichy) = 1, 'P1 vichy katalogissa');
  perform public.t80_ck((select count(*) from jsonb_array_elements(booking.admin_pos_catalog()) e where (e->>'product_id')::bigint = p_gift) = 0, 'P2 lahjakortti ei katalogissa');
  items := jsonb_build_array(jsonb_build_object('product_id', p_vichy, 'quantity', 2));
  res := booking.admin_pos_checkout(items, 'fi', null);
  pos_id := (res->>'order_id')::bigint; pos_tok := (res->>'public_token')::uuid;
  perform public.t80_ck(res->>'source_channel' = 'pikakassa', 'P3 lähde pikakassa');
  perform public.t80_ck((res->>'total')::numeric = 6, 'P4 hinta palvelimelta 2 x 3');
  perform public.t80_ck((select unit_price_gross from booking.order_items where order_id = pos_id) = 3, 'P5 rivihinta tuotteesta');
  perform public.t80_ck(public.t80_try(format('select booking.admin_pos_checkout(%L::jsonb, ''fi'', null)', jsonb_build_array(jsonb_build_object('product_id', p_vichy, 'quantity', 1, 'price', 1)))) = 'price_locked', 'P6 hinta lukittu');
  perform public.t80_ck(public.t80_try(format('select booking.admin_pos_checkout(%L::jsonb, ''fi'', null)', jsonb_build_array(jsonb_build_object('product_id', p_gift, 'quantity', 1)))) = 'not_counter_product', 'P7 lahjakortti ei kassarivi');
  res := booking.admin_pos_checkout(items, 'fi', 'Sama@Example.Test');
  select customer_id into v_c1 from booking.orders where id = (res->>'order_id')::bigint;
  res := booking.admin_pos_checkout(items, 'fi', 'sama@example.test');
  select customer_id into v_c2 from booking.orders where id = (res->>'order_id')::bigint;
  perform public.t80_ck(v_c1 is not null and v_c1 = v_c2 and (select count(*) from booking.customers where lower(email) = 'sama@example.test') = 1, 'C1 sama sähköposti käyttää olemassa olevaa asiakasta');
  perform public.t80_logout();
  delete from booking.role_permissions where role_code = 'staff' and permission = 'pos.use';
  perform public.t80_login(u_staff);
  perform public.t80_ck(public.t80_try('select booking.admin_pos_catalog()') = 'forbidden', 'P8 ilman pos.use kielletty');
  perform public.t80_logout();
  insert into booking.role_permissions(role_code, permission) values ('staff', 'pos.use');

  perform public.t80_login(u_mgr);
  perform public.t80_ck(public.t80_try(format('select booking.admin_update_product_config(%s, %L::jsonb)', p_vichy, '{"age_restricted":true,"fridge_sale":true}')) = 'age_restricted', 'A3 molemmat liput');
  perform public.t80_ck(public.t80_try(format('select booking.admin_update_product_config(%s, %L::jsonb)', p_vichy, '{"age_restricted":true}')) = 'ok', 'A4 ikäraja yksin');
  perform public.t80_ck((select fridge_sale from booking.product_config where product_id = p_vichy) = false, 'A5 ikäraja sammuttaa kylmälaite-lipun');
  perform public.t80_ck(public.t80_try(format('select booking.admin_update_product_config(%s, %L::jsonb)', p_vichy, '{"age_restricted":false,"fridge_sale":true}')) = 'ok', 'A6 virvoitus takaisin');
  perform public.t80_ck(public.t80_try(format('select booking.admin_update_product_config(%s, %L::jsonb)', p_vichy, '{"audience":"business"}')) = 'ok', 'A7 audience business');
  perform public.t80_ck((select audience from booking.product_config where product_id = p_vichy) = 'business', 'A8 audience tallentui');
  perform public.t80_ck(public.t80_try(format('select booking.admin_update_product_config(%s, %L::jsonb)', p_vichy, '{"audience":"wholesale"}')) = 'invalid_audience', 'A9 audience vain consumer tai business');
  perform public.t80_ck(public.t80_try(format('select booking.admin_update_product_config(%s, %L::jsonb)', p_vichy, '{"audience":"consumer"}')) = 'ok', 'A10 audience consumer');
  perform public.t80_logout();

  res := booking.public_drinks_catalog(null);
  perform public.t80_ck(res->>'ok' = 'true' and (select count(*) from jsonb_array_elements(res->'products') e where (e->>'product_id')::bigint = p_beer) = 0, 'D1 olut ei julkisessa listassa');
  perform public.t80_ck((booking.public_drinks_catalog('ei-ole') -> 'device' ->> 'unknown') = 'true', 'D2 tuntematon laite');
  res := booking.public_drinks_checkout(null, items, null, 'fi');
  perform public.t80_ck(res->>'code' = 'unknown_device', 'D3 kassa vaatii laitteen');
  res := booking.public_drinks_checkout(dev, jsonb_build_array(jsonb_build_object('product_id', p_vichy, 'quantity', 1, 'unit_price', 0.01)), null, 'fi');
  perform public.t80_ck(res->>'code' = 'price_locked', 'D4 asiakas ei anna hintaa');
  -- kaksi epäonnistunutta kassakutsua kulutti nopeusrajan (8 / 10 min). Jäljellä kuusi onnistumista.
  n_ok := 0;
  for i in 1..7 loop
    if i = 1 then
      res := booking.public_drinks_checkout(dev, jsonb_build_array(jsonb_build_object('product_id', p_vichy, 'quantity', 1)), 'asiakas@example.test', 'fi');
    else
      res := booking.public_drinks_checkout(dev_grape, jsonb_build_array(jsonb_build_object('product_id', p_grape, 'quantity', 1)), null, 'fi');
    end if;
    if res->>'ok' = 'true' then
      n_ok := n_ok + 1;
      if i = 1 then tok := (res->>'public_token')::uuid; end if;
    else
      perform public.t80_ck(i = 7 and n_ok = 6 and res->>'code' = 'rate_limited', 'D9 yhdeksäs kutsu on rate_limited');
      exit;
    end if;
  end loop;
  perform public.t80_ck(n_ok = 6, 'D10 kuusi onnistui kahden hylkäyksen jälkeen');
  perform public.t80_ck(tok is not null, 'D5 lähde ja laite');
  perform public.t80_ck((select source_channel from booking.orders where public_token = tok) = 'kylmalaite', 'D5b lähde kylmalaite');
  perform public.t80_ck((select sale_ref from booking.orders where public_token = tok) = dev, 'D5c laitetunnus');
  perform public.t80_ck((select total_gross from booking.orders where public_token = tok) = 3, 'D6 hinta 3 eikä asiakkaan luku');
  perform public.t80_ck((booking.public_drinks_status(pos_tok) ->> 'code') = 'not_found', 'D7 pikakassan tunniste ei näy juomasivulle');
  perform public.t80_ck((booking.public_drinks_status(tok) ->> 'payment_status') = 'unpaid', 'D8 tila unpaid');

  res := booking.vismapay_payment_prepare(tok);
  perform public.t80_ck(res->>'code' = 'vismapay_off', 'V1 off');
  update booking.integration_config set mode = 'live' where key = 'vismapay';
  res := booking.vismapay_payment_prepare(tok);
  perform public.t80_ck(res->>'code' = 'vismapay_live_not_implemented', 'V2 live ei toteudu');
  update booking.integration_config set mode = 'dry_run' where key = 'vismapay';
  res := booking.vismapay_payment_prepare(tok);
  perform public.t80_ck(res->>'ok' = 'true' and res->>'dry_run' = 'true' and res->>'status' = 'pending', 'V3 dry_run pending');
  perform public.t80_ck((select payment_status from booking.orders where public_token = tok) <> 'paid', 'V4 ei merkitty maksetuksi');
  perform public.t80_ck((select count(*) from booking.receipts where order_id = (select id from booking.orders where public_token = tok)) = 0, 'V5 ei kuittia ennen merkintää');
  perform booking.payment_mark_paid('visma_pay', res->>'provider_ref', (res->>'amount')::numeric, '{"test":true}'::jsonb);
  perform public.t80_ck((select payment_status from booking.orders where public_token = tok) = 'paid', 'V6 payment_mark_paid maksaa');
  perform public.t80_ck((select count(*) from booking.receipts where order_id = (select id from booking.orders where public_token = tok)) >= 1, 'V7 kuitti syntyy');

  update booking.orders set created_at = now() - interval '2 hours' where id = pos_id;
  perform public.t80_login(u_staff);
  res := booking.admin_pos_status(pos_id);
  perform public.t80_ck(res->>'status' = 'expired', 'X1 maksamaton kassatilaus vanhenee');
  res := booking.admin_pos_checkout(jsonb_build_array(jsonb_build_object('product_id', p_vichy, 'quantity', 1)), 'fi', null);
  pos_id := (res->>'order_id')::bigint;
  res := booking.admin_pos_checkout(jsonb_build_array(jsonb_build_object('product_id', p_vichy, 'quantity', 1)), 'fi', null);
  perform booking.admin_record_payment((res->>'order_id')::bigint, 'cash', (res->>'total')::numeric);
  perform public.t80_ck(public.t80_try(format('select booking.admin_pos_void(%s)', (res->>'order_id')::bigint)) = 'already_paid', 'X2 maksettua ei peruta');
  perform public.t80_logout();
  update booking.orders set created_at = now() - interval '31 minutes' where id = pos_id;
  perform public.t80_ck(booking.expire_counter_orders() >= 1, 'X3 expire_counter_orders vanhentaa ilman tilakyselyä');
  perform public.t80_ck((select status from booking.orders where id = pos_id) = 'expired', 'X3b tila expired');

  update booking.integration_config set mode = 'test', settings = settings || '{"approved_by":"testi"}'::jsonb where key = 'mobilepay';
  res := public.t80_call($$select booking.mobilepay_payment_prepare(null, null, 120, 'QR')$$);
  perform public.t80_ck(res->>'err' = 'invalid_param', 'M1 QR ilman tunnistetta hylätään');
  select public_token into tok from booking.orders where source_channel = 'kylmalaite' and payment_status <> 'paid' limit 1;
  res := booking.mobilepay_payment_prepare(tok, null, 120, 'QR');
  pay_id := (res->>'payment_id')::bigint;
  select link_expires_at into exp from booking.payments where id = pay_id;
  perform public.t80_ck(res->>'user_flow' = 'QR' and exp <= now() + interval '21 minutes' and exp > now() + interval '10 minutes', 'M2 QR-voimassaolo noin 20 min');
  perform public.t80_ck(res->>'description' like 'Sipoonjoen Perinnesauna – tilaus %', 'M2b kuvaus Sipoonjoen Perinnesauna');

  insert into booking.orders(status, payment_status, total_gross, currency, source_channel, hold_kind)
  values ('pending', 'unpaid', 3, 'EUR', 'web', 'preliminary') returning public_token into v_pre;
  res := public.t80_call(format('select booking.mobilepay_payment_prepare(%L::uuid, null, 120, ''WEB_REDIRECT'')', v_pre));
  perform public.t80_ck(res->>'err' = 'order_not_payable' and res->>'message' = 'Alustavaa varausta ei makseta ennen vahvistusta', 'M3 alustavaa varausta ei makseta');

  res := public.t80_call(format('select booking.mobilepay_payment_prepare(%L::uuid, null, 120, ''PUSH_MESSAGE'')', tok));
  perform public.t80_ck(res->>'err' = 'push_not_allowed', 'M4 PUSH hylätään kun lähde ei ole pikakassa');

  perform public.t80_login(u_staff);
  res := booking.admin_pos_checkout(jsonb_build_array(jsonb_build_object('product_id', p_vichy, 'quantity', 1)), 'fi', null);
  perform public.t80_logout();
  pos_id := (res->>'order_id')::bigint;
  pos_tok := (res->>'public_token')::uuid;
  res := booking.mobilepay_payment_prepare(pos_tok, null, 120, 'PUSH_MESSAGE');
  perform public.t80_ck(res->>'ok' = 'true' and res->>'user_flow' = 'PUSH_MESSAGE' and res->>'description' like 'Sipoonjoen Perinnesauna – tilaus %', 'M5 pikakassan PUSH ja kuvaus');

  update booking.orders set hold_kind = 'checkout' where id = pos_id;
  select id into v_space from booking.resources where kind = 'space' and active order by id limit 1;
  insert into booking.reservations(order_id, space_id, mode, starts_at, ends_at, persons, status, hold_expires_at)
  values (pos_id, v_space, 'exclusive', now() + interval '400 days', now() + interval '400 days 2 hours', 1, 'pending', now() + interval '2 minutes');
  select hold_expires_at into v_hold from booking.reservations where order_id = pos_id;
  res := booking.mobilepay_payment_prepare(pos_tok, null, 120, 'PUSH_MESSAGE');
  perform public.t80_ck(coalesce(res->>'reuse', '') = 'true', 'M6 sama PUSH-yritys käytetään uudelleen');
  perform public.t80_ck((select min(hold_expires_at) from booking.reservations where order_id = pos_id) > now() + interval '14 minutes', 'M7 hold pidentyy kun MobilePay alkaa');
  perform public.t80_ck((select min(hold_expires_at) from booking.reservations where order_id = pos_id) > v_hold, 'M7b pito on pidempi kuin ennen kutsua');

  log := current_setting('t80.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
