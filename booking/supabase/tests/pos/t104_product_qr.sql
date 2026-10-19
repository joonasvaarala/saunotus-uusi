-- t104: tuotekohtainen QR (booking_104–105). Rollback-transaktio: lopuksi tahallinen poikkeus, ei jälkiä.
-- Anon saa vain public_drinks_*. Katalogi ilman koodia on tyhjä. Kelvollinen koodi palauttaa yhden tuotteen nimen ja hinnan.
-- Ikärajallinen ei saa koodia. Hinta tulee palvelimelta. lower(email) käyttää samaa asiakasta. expire_counter_orders koskee kylmalaite-lähdettä.
-- Ei CI:ssä. GitHub Pages -työnkulussa ei ole Postgresia, ja booking/supabase/tests/run.sh ajaa vain juuren [0-9]*.test.sql.
-- Bottiavustus ajaa tämän psql:llä migraatioiden jälkeen. site_base_url asetetaan tässä transaktiossa
-- (tuotannossa arvo on joonasvaarala.github.io/saunotus-uusi); peruutus palauttaa sen.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t104.log', '', true);
create function public.t104_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t104.log', coalesce(current_setting('t104.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t104_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 160) end;
end $$;
create function public.t104_call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text; s text;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return jsonb_build_object('err', case when s = 'BK001' then d else s || ':' || left(m, 160) end, 'message', m);
end $$;
create function public.t104_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t104_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_staff uuid := gen_random_uuid();
  u_mgr uuid := gen_random_uuid();
  u_admin uuid := gen_random_uuid();
  p_vichy bigint; p_grape bigint; p_beer bigint; p_gift bigint; p_hidden bigint;
  v_biz bigint;
  rowj jsonb; code text; other text; res jsonb; tok uuid; tok2 uuid; v_id bigint;
  v_c1 bigint; v_c2 bigint; log text; npass int; nfail int;
begin
  perform public.t104_ck(not has_function_privilege('anon', 'booking.admin_create_product_qr(bigint,text)', 'execute'), 'G1 anon ei luo QR:ää');
  perform public.t104_ck(not has_function_privilege('anon', 'booking.admin_list_product_qr()', 'execute'), 'G2 anon ei listaa');
  perform public.t104_ck(not has_function_privilege('anon', 'booking.admin_set_pos_product(bigint,boolean,integer)', 'execute'), 'G3 anon ei muokkaa kassaa');
  perform public.t104_ck(not has_function_privilege('anon', 'booking.admin_delete_product_qr(bigint)', 'execute'), 'G4 anon ei poista');
  perform public.t104_ck(has_function_privilege('anon', 'booking.public_drinks_catalog(text)', 'execute'), 'G5 anon saa katalogin');
  perform public.t104_ck(has_function_privilege('anon', 'booking.public_drinks_checkout(text,jsonb,text,text)', 'execute'), 'G6 anon saa kassan');
  perform public.t104_ck(to_regclass('booking.product_qr') is not null, 'G7 product_qr olemassa');
  perform public.t104_ck(to_regclass('booking.cold_units') is null, 'G8 cold_units poissa');
  perform public.t104_ck(to_regclass('booking.cold_units_archive') is not null, 'G8b arkisto olemassa');
  execute 'set local role anon';
  perform public.t104_ck(public.t104_try('select count(*) from booking.product_qr') <> 'ok', 'G9 anon ei lue taulua');
  perform public.t104_ck(public.t104_try('select count(*) from booking.cold_units_archive') <> 'ok', 'G9b anon ei lue arkistoa');
  perform public.t104_logout();

  select id into v_biz from kb.businesses where id = 1;
  perform public.t104_ck(v_biz is not null, 'B0 yritystunnus');
  insert into booking.settings(key, value, description, is_public)
  values ('site_base_url', to_jsonb('https://uusi.saunotus.com'::text), 'Testi asettaa osoitteen; transaktion peruutus palauttaa tuotannon arvon', false)
  on conflict (key) do update set value = excluded.value;

  insert into kb.products(business_id, name, category, price, vat_rate, active) values (v_biz, 'Vichy', 'other', 3.00, 13.5, true) returning id into p_vichy;
  insert into kb.products(business_id, name, category, price, vat_rate, active) values (v_biz, 'Viinirypälemehu', 'other', 2.50, 13.5, true) returning id into p_grape;
  insert into kb.products(business_id, name, category, price, vat_rate, active) values (v_biz, 'Olut', 'other', 4, 25.5, true) returning id into p_beer;
  insert into kb.products(business_id, name, category, price, vat_rate, active) values (v_biz, 'Lahjakortti testi', 'gift_card', 58, 0, true) returning id into p_gift;
  insert into kb.products(business_id, name, category, price, vat_rate, active) values (v_biz, 'Käsipyyhe', 'other', 4, 25.5, true) returning id into p_hidden;
  insert into booking.product_config(product_id, sale_kind, bookable, shop_visible, pos_enabled, fridge_sale)
  values
    (p_vichy, 'other', false, false, false, false),
    (p_grape, 'other', false, true, false, true),
    (p_gift, 'other', false, false, false, false),
    (p_hidden, 'other', false, false, false, false);
  perform public.t104_ck(public.t104_try(format('insert into booking.product_config(product_id, sale_kind, fridge_sale) values (%s, ''other'', true)', p_beer)) = 'age_restricted', 'A1 olut ei QR-tilaan');
  insert into booking.product_config(product_id, sale_kind, bookable, shop_visible, pos_enabled, fridge_sale, age_restricted)
  values (p_beer, 'other', false, false, false, false, true);

  insert into auth.users(id, email) values
    (u_staff, 't104-staff@example.test'),
    (u_mgr, 't104-mgr@example.test'),
    (u_admin, 't104-admin@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_staff, 't104-staff@example.test', 't104 staff', 'staff'),
    (u_mgr, 't104-mgr@example.test', 't104 mgr', 'manager'),
    (u_admin, 't104-admin@example.test', 't104 admin', 'admin');

  perform public.t104_login(u_staff);
  perform public.t104_ck(public.t104_try(format('select booking.admin_set_pos_product(%s, true, 10)', p_hidden)) = 'ok', 'P1 staff lisää piilotetun tuotteen kassaan');
  perform public.t104_ck((select pos_enabled from booking.product_config where product_id = p_hidden), 'P2 pos_enabled');
  perform public.t104_ck((select shop_visible from booking.product_config where product_id = p_hidden) = false, 'P3 verkkokauppa pysyy piilossa');
  perform public.t104_ck(public.t104_try(format('select booking.admin_set_pos_product(%s, true, 20)', p_gift)) = 'not_counter_product', 'P4 lahjakortti ei kassaan');
  perform public.t104_ck(public.t104_try(format('select booking.admin_create_product_qr(%s, %L)', p_beer, 'baari')) = 'age_restricted', 'A2 olut ei saa koodia');
  perform public.t104_ck(public.t104_try(format('select booking.admin_create_product_qr(%s, null)', p_gift)) = 'not_counter_product', 'A3 lahjakortti ei saa koodia');
  rowj := booking.admin_create_product_qr(p_vichy, 'Pukuhuone');
  code := rowj ->> 'code';
  v_id := (rowj ->> 'id')::bigint;
  perform public.t104_ck(code ~ '^[a-f0-9]{32}$' and length(code) = 32, 'Q1 koodi on 32 heksaa');
  perform public.t104_ck(code <> p_vichy::text, 'Q2 koodi ei ole tuotetunnus');
  perform public.t104_ck(rowj ->> 'print_url' = 'https://uusi.saunotus.com/juomat/?laite=' || code, 'Q3 tulostusosoite');
  perform public.t104_ck(rowj ->> 'path' = '/juomat/?laite=' || code, 'Q4 polku');
  perform public.t104_ck(rowj ->> 'path_en' = '/en/drinks/?laite=' || code, 'Q5 englannin polku');
  perform public.t104_ck((rowj ->> 'price')::numeric = 3, 'Q6 hinta tuotteesta');
  perform public.t104_ck(not (rowj ? 'vat_rate'), 'Q7 hallinnan rivi ei palauta ALV:tä');
  perform public.t104_ck((select fridge_sale from booking.product_config where product_id = p_vichy), 'Q8 luonti asettaa QR-tilan');
  perform public.t104_logout();

  delete from booking.role_permissions where role_code = 'staff' and permission = 'pos.use';
  perform public.t104_login(u_staff);
  perform public.t104_ck(public.t104_try('select booking.admin_list_product_qr()') = 'forbidden', 'R1 staff ilman pos.use kielletty');
  perform public.t104_logout();
  insert into booking.role_permissions(role_code, permission) values ('staff', 'pos.use');

  delete from booking.role_permissions where role_code = 'manager' and permission = 'pos.use';
  perform public.t104_login(u_mgr);
  rowj := booking.admin_create_product_qr(p_grape, null);
  other := rowj ->> 'code';
  perform public.t104_ck(other ~ '^[a-f0-9]{32}$' and other <> code, 'R2 ylläpitäjä settings.editillä, eri koodi');
  perform public.t104_logout();
  insert into booking.role_permissions(role_code, permission) values ('manager', 'pos.use');

  perform public.t104_login(u_admin);
  perform public.t104_ck(jsonb_array_length(booking.admin_list_product_qr()) = 2, 'R3 pääkäyttäjä näkee molemmat');
  perform public.t104_logout();

  res := booking.public_drinks_catalog(null);
  perform public.t104_ck(res ->> 'ok' = 'true' and jsonb_array_length(res -> 'products') = 0, 'D1 ilman koodia ei tuotteita');
  perform public.t104_ck((booking.public_drinks_catalog('ei-ole') -> 'device' ->> 'unknown') = 'true', 'D2 tuntematon');
  res := booking.public_drinks_catalog(code);
  perform public.t104_ck(jsonb_array_length(res -> 'products') = 1, 'D3 yksi tuote');
  perform public.t104_ck((res -> 'products' -> 0 ->> 'product_id')::bigint = p_vichy, 'D4 oikea tuote');
  perform public.t104_ck(res -> 'products' -> 0 ->> 'name' = 'Vichy', 'D5 nimi');
  perform public.t104_ck((res -> 'products' -> 0 ->> 'price')::numeric = 3, 'D6 hinta');
  perform public.t104_ck(not (res -> 'products' -> 0 ? 'vat_rate'), 'D7 ei ALV:tä');
  perform public.t104_ck(not (res -> 'products' -> 0 ? 'description'), 'D8 ei kuvausta');
  perform public.t104_ck(not (res -> 'device' ? 'code'), 'D9 laitetunnusta ei toisteta');
  perform public.t104_ck(position('Viinirypäle' in res::text) = 0 and position('Olut' in res::text) = 0, 'D10 muut tuotteet eivät vuoda');
  perform public.t104_ck(res -> 'device' ->> 'label' = 'Pukuhuone', 'D11 tarra');

  res := booking.public_drinks_checkout(code, jsonb_build_array(jsonb_build_object('product_id', p_grape, 'quantity', 1)), null, 'fi');
  perform public.t104_ck(res ->> 'code' = 'not_counter_product', 'C1 vieras tuote hylätään');
  res := booking.public_drinks_checkout(code, jsonb_build_array(jsonb_build_object('product_id', p_vichy, 'quantity', 1, 'unit_price', 0.01)), null, 'fi');
  perform public.t104_ck(res ->> 'code' = 'price_locked', 'C2 hinta lukittu');
  res := booking.public_drinks_checkout(code, jsonb_build_array(jsonb_build_object('product_id', p_vichy, 'quantity', 2)), 'Qr@Example.Test', 'fi');
  tok := (res ->> 'public_token')::uuid;
  perform public.t104_ck(res ->> 'ok' = 'true' and (res ->> 'total')::numeric = 6, 'C3 hinta 2 x 3 palvelimelta');
  perform public.t104_ck((select source_channel from booking.orders where public_token = tok) = 'kylmalaite', 'C4 lähde kylmalaite');
  perform public.t104_ck((select sale_ref from booking.orders where public_token = tok) = code, 'C5 sale_ref on koodi');
  select customer_id into v_c1 from booking.orders where public_token = tok;
  res := booking.public_drinks_checkout(code, jsonb_build_array(jsonb_build_object('product_id', p_vichy, 'quantity', 1)), 'qr@example.test', 'fi');
  tok2 := (res ->> 'public_token')::uuid;
  select customer_id into v_c2 from booking.orders where public_token = tok2;
  perform public.t104_ck(v_c1 is not null and v_c1 = v_c2 and (select count(*) from booking.customers where lower(email) = 'qr@example.test') = 1, 'C6 lower(email) käyttää samaa asiakasta');

  update booking.integration_config set mode = 'test', settings = settings || '{"approved_by":"testi"}'::jsonb where key = 'mobilepay';
  res := public.t104_call(format('select booking.mobilepay_payment_prepare(%L::uuid, null, 120, ''PUSH_MESSAGE'')', tok));
  perform public.t104_ck(res ->> 'err' = 'push_not_allowed', 'M1 PUSH ei kylmälaite-lähteelle');

  update booking.orders set created_at = now() - interval '31 minutes' where public_token = tok2;
  perform public.t104_ck(booking.expire_counter_orders() >= 1, 'X1 expire_counter_orders');
  perform public.t104_ck((select status from booking.orders where public_token = tok2) = 'expired', 'X2 kylmalaite-tilaus vanhenee');

  perform public.t104_login(u_staff);
  perform public.t104_ck(public.t104_try(format('select booking.admin_delete_product_qr(%s)', v_id)) = 'ok', 'Q9 poisto');
  perform public.t104_logout();
  perform public.t104_ck((booking.public_drinks_catalog(code) -> 'device' ->> 'unknown') = 'true', 'Q10 poistettu koodi ei myy');

  log := current_setting('t104.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
