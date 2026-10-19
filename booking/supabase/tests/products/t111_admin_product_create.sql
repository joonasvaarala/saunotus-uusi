-- t111: hallinnan tuotteen luonti (booking_111). Rollback-transaktio: lopuksi tahallinen poikkeus.
-- Oikeudet, tyhjä nimi, hinta, ALV, duplikaatti, oletuskentät, site_texts, audit, sarjan nosto.
-- Ei CI:ssä. GitHub Pages -työnkulussa ei ole Postgresia, ja booking/supabase/tests/run.sh ajaa vain juuren [0-9]*.test.sql.
-- Bottiavustus ajaa tämän psql:llä migraatioiden jälkeen. Ei tuotantoon.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t111.log', '', true);
create function public.t111_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t111.log', coalesce(current_setting('t111.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t111_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 160) end;
end $$;
create function public.t111_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t111_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_staff uuid := gen_random_uuid();
  u_mgr uuid := gen_random_uuid();
  res jsonb;
  res2 jsonb;
  pid bigint;
  n_before int;
  log text;
  npass int;
  nfail int;
begin
  perform public.t111_ck(not has_function_privilege('anon', 'booking.admin_product_create(jsonb)', 'execute'), 'G1 anon ei luo');
  perform public.t111_ck(not has_function_privilege('public', 'booking.admin_product_create(jsonb)', 'execute'), 'G2 public ei luo');
  perform public.t111_ck(has_function_privilege('authenticated', 'booking.admin_product_create(jsonb)', 'execute'), 'G3 authenticated saa');
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    perform public.t111_ck(has_function_privilege('service_role', 'booking.admin_product_create(jsonb)', 'execute'), 'G4 service_role saa');
  else
    perform public.t111_ck(false, 'G4 service_role puuttuu');
  end if;
  perform public.t111_ck((select prosecdef and proconfig::text like '%search_path=%' from pg_proc where proname = 'admin_product_create' and pronamespace = 'booking'::regnamespace), 'G5 definer ja search_path');

  delete from booking.role_permissions where role_code = 'staff' and permission = 'catalog.edit';
  insert into auth.users(id, email) values (u_staff, 't111-staff@example.test'), (u_mgr, 't111-mgr@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_staff, 't111-staff@example.test', 't111 staff', 'staff'),
    (u_mgr, 't111-mgr@example.test', 't111 manager', 'manager');

  perform public.t111_login(u_staff);
  perform public.t111_ck(public.t111_try($q$select booking.admin_product_create('{"name":"Ei oikeutta","price":1,"vat_rate":25.5}'::jsonb)$q$) = 'forbidden', 'R1 staff ilman catalog.edit');
  perform public.t111_logout();

  perform public.t111_login(u_mgr);
  select count(*) into n_before from kb.products;
  perform public.t111_ck(public.t111_try($q$select booking.admin_product_create('{"name":"   ","price":1,"vat_rate":25.5}'::jsonb)$q$) = 'invalid_name', 'E1 tyhjä nimi');
  perform public.t111_ck(public.t111_try($q$select booking.admin_product_create('{"name":"Miinus","price":-1,"vat_rate":25.5}'::jsonb)$q$) = 'invalid_price', 'E2 negatiivinen hinta');
  perform public.t111_ck(public.t111_try($q$select booking.admin_product_create('{"name":"Vanha alv","price":1,"vat_rate":14}'::jsonb)$q$) = 'invalid_vat', 'E3 alv 14 ei käytössä');
  perform public.t111_ck(public.t111_try($q$select booking.admin_product_create('{"name":"Outo alv","price":1,"vat_rate":17}'::jsonb)$q$) = 'invalid_vat', 'E4 alv 17 ei sallittu');
  perform public.t111_ck(public.t111_try($q$select booking.admin_product_create('{"name":"Outo kentta","price":1,"vat_rate":25.5,"slug":"x"}'::jsonb)$q$) = 'unknown_field', 'E5 tuntematon kenttä');
  perform public.t111_ck(public.t111_try($q$select booking.admin_product_create('{"name":"Väärä kategoria","price":1,"vat_rate":25.5,"category":"juoma"}'::jsonb)$q$) = 'invalid_category', 'E6 kategoria');
  perform public.t111_ck((select count(*) from kb.products) = n_before, 'E7 virhe ei jättänyt riviä');

  res := booking.admin_product_create(jsonb_build_object(
    'name', 'Virvoitusjuoma',
    'price', 3.50,
    'vat_rate', 13.5,
    'category', 'product_rental',
    'active', true,
    'shop_visible', false,
    'age_restricted', false
  ));
  pid := (res->>'id')::bigint;
  perform public.t111_ck(res->>'ok' = 'true' and pid is not null, 'C1 luonti onnistuu');
  perform public.t111_ck((select name from kb.products where id = pid) = 'Virvoitusjuoma', 'C2 nimi');
  perform public.t111_ck((select name_en from kb.products where id = pid) = 'Virvoitusjuoma', 'C3 tyhjä en tallentaa saman nimen');
  perform public.t111_ck((select price from kb.products where id = pid) = 3.50, 'C4 hinta');
  perform public.t111_ck((select price_text from kb.products where id = pid) = '3,50 €', 'C5 hintateksti');
  perform public.t111_ck((select vat_rate from kb.products where id = pid) = 13.5, 'C6 alv');
  perform public.t111_ck((select category from kb.products where id = pid) = 'product_rental', 'C7 kategoria');
  perform public.t111_ck((select price_type from kb.products where id = pid) = 'per_unit', 'C8 price_type');
  perform public.t111_ck((select price_includes_vat from kb.products where id = pid) is true, 'C9 hinta sis alv');
  perform public.t111_ck((select external_system from kb.products where id = pid) is null and (select external_id from kb.products where id = pid) is null, 'C10 ei ulkoista tunnusta');
  perform public.t111_ck((select active from kb.products where id = pid) is true, 'C11 aktiivinen');
  perform public.t111_ck((select sale_kind from booking.product_config where product_id = pid) = 'other', 'K1 sale_kind');
  perform public.t111_ck((select resource_class from booking.product_config where product_id = pid) = 'none', 'K2 resource_class none');
  perform public.t111_ck((select bookable from booking.product_config where product_id = pid) is false, 'K3 bookable');
  perform public.t111_ck((select shop_visible from booking.product_config where product_id = pid) is false, 'K4 shop');
  perform public.t111_ck((select lifecycle from booking.product_config where product_id = pid) = 'current', 'K5 lifecycle');
  perform public.t111_ck((select audience from booking.product_config where product_id = pid) = 'consumer', 'K6 audience');
  perform public.t111_ck((select pos_enabled from booking.product_config where product_id = pid) is false, 'K7 ei pikakassassa');
  perform public.t111_ck((select fridge_sale from booking.product_config where product_id = pid) is false, 'K8 ei kylmälaitteessa');
  perform public.t111_ck((select age_restricted from booking.product_config where product_id = pid) is false, 'K9 ei ikärajaa');
  perform public.t111_ck((select min_persons from booking.product_config where product_id = pid) = 1, 'K10 min hlö');
  perform public.t111_ck((select public_slots from booking.product_config where product_id = pid) is false, 'K11 ei julkisia slotteja');
  perform public.t111_ck((res->'product'->'config'->>'audience') = 'consumer', 'K12 vastauksessa audience');

  perform public.t111_ck(public.t111_try(format($q$select booking.admin_product_create(jsonb_build_object('name','  virvoitusjuoma  ','price','3,50','vat_rate','13,5','active',true))$q$)) = 'duplicate_name', 'D1 duplikaatti kirjainkoosta riippumatta');
  perform public.t111_ck((select count(*) from kb.products where lower(btrim(name)) = 'virvoitusjuoma') = 1, 'D2 virhe ei luonut toista');

  res2 := booking.admin_product_create(jsonb_build_object('name', 'Virvoitusjuoma', 'price', 0, 'vat_rate', 0, 'active', false));
  perform public.t111_ck(res2->>'ok' = 'true' and (select active from kb.products where id = (res2->>'id')::bigint) is false, 'D3 passiivinen saa saman nimen');

  res2 := booking.admin_product_create(jsonb_build_object(
    'name', 'Kauppatuote', 'name_en', 'Shop item', 'price', '10', 'vat_rate', '25.5',
    'shop_visible', true, 'age_restricted', true
  ));
  perform public.t111_ck((select category from kb.products where id = (res2->>'id')::bigint) = 'product_rental', 'F1 oletuskategoria');
  perform public.t111_ck((select name_en from kb.products where id = (res2->>'id')::bigint) = 'Shop item', 'F2 englannin nimi');
  perform public.t111_ck((select bookable and shop_visible from booking.product_config where product_id = (res2->>'id')::bigint), 'F3 verkko asettaa bookable');
  perform public.t111_ck((select age_restricted from booking.product_config where product_id = (res2->>'id')::bigint) is true, 'F4 ikäraja');
  perform public.t111_ck((select fridge_sale from booking.product_config where product_id = (res2->>'id')::bigint) is false, 'F5 ikäraja ei kylmälaitteeseen');

  perform public.t111_ck((select published_text from booking.site_texts where key = 'product.' || pid::text || '.name' and lang = 'fi') = 'Virvoitusjuoma', 'T1 nimi fi');
  perform public.t111_ck((select published_text from booking.site_texts where key = 'product.' || pid::text || '.name' and lang = 'en') = 'Virvoitusjuoma', 'T2 nimi en');
  perform public.t111_ck((select class from booking.site_texts where key = 'product.' || pid::text || '.name' and lang = 'fi') = 'normal', 'T3 luokka normal');
  perform public.t111_ck(exists (select 1 from booking.site_text_versions v join booking.site_texts t on t.id = v.text_id where t.key = 'product.' || pid::text || '.name' and t.lang = 'fi' and v.version = 1), 'T4 versio');

  perform public.t111_ck(exists (select 1 from booking.audit_log where table_name = 'kb.products' and row_pk = pid::text and action = 'ADMIN_CREATE'), 'A1 audit ADMIN_CREATE');
  perform public.t111_ck(exists (select 1 from kb.change_log where table_name = 'products' and row_id = pid and action = 'insert'), 'A2 change_log');
  perform public.t111_ck(exists (select 1 from booking.audit_log where table_name = 'product_config' and row_pk = pid::text and action = 'INSERT'), 'A3 asetusrivin audit');

  insert into kb.products(id, name, category, price, vat_rate, active)
  overriding system value values (900000, 'Sekvenssikoe', 'other', 1, 0, false);
  res2 := booking.admin_product_create(jsonb_build_object('name', 'Sekvenssin jalkeen', 'price', 1, 'vat_rate', 25.5, 'active', true));
  perform public.t111_ck((res2->>'id')::bigint > 900000, 'S1 sarja nousee suurimman tunnuksen yli');

  perform public.t111_logout();

  log := current_setting('t111.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
