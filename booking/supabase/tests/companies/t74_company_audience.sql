-- booking_74: yritysvuorot (Johku 17 ja 41 / slugit) audience=business. Kuluttajan katalogi ei sisällä niitä.
-- Ei tuhoa sääntöjä. Yksi asetus (admin_update_product_config audience) palauttaa vuoron kuluttajalle.
-- Ajo: psql -v ON_ERROR_STOP=1 -f booking/supabase/tests/companies/t74_company_audience.sql
-- (migraatiot ja kb-fixture jo kannassa, kuten t62).
set local lock_timeout = '3s'; set local statement_timeout = '60s';
select set_config('t74.log', '', true);
create function public.t74_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t74.log', coalesce(current_setting('t74.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t74_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 80) end;
end $$;
create function public.t74_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t74_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;
do $t$
declare u_mgr uuid := gen_random_uuid(); u_st uuid := gen_random_uuid(); id17 bigint; id16 bigint; n int; log text; npass int; nfail int;
begin
  select p.id into id17 from kb.products p where p.external_system = 'johku' and p.external_id = '17';
  select p.id into id16 from kb.products p where p.external_system = 'johku' and p.external_id = '16';
  perform public.t74_ck(id17 is not null and id16 is not null, 'A0: fixture tuntee johku 17 ja 16');
  perform public.t74_ck((select audience from booking.product_config pc join kb.products p on p.id = pc.product_id where p.external_id = '17' and p.external_system = 'johku') = 'business', 'A1: johku 17 business');
  perform public.t74_ck((select audience from booking.product_config pc join kb.products p on p.id = pc.product_id where p.external_id = '41' and p.external_system = 'johku') = 'business', 'A2: johku 41 business');
  perform public.t74_ck((select audience from booking.product_config pc join kb.products p on p.id = pc.product_id where p.external_id = '16' and p.external_system = 'johku') = 'consumer', 'A3: johku 16 kuluttaja');
  perform public.t74_ck((select audience from booking.product_config pc join kb.products p on p.id = pc.product_id where p.external_id = '15' and p.external_system = 'johku') = 'consumer', 'A4: johku 15 kuluttaja');
  perform public.t74_ck(not exists (select 1 from booking.product_config pc join kb.products p on p.id = pc.product_id where p.slug = 'yrityspaivat' and pc.audience = 'business'), 'A5: yrityspaivat ei ole yritysvuoro');
  perform public.t74_ck((select count(*) from booking.schedule_rules r join kb.products p on p.id = r.product_id where p.external_system = 'johku' and p.external_id = '17') >= 1, 'A6: johku 17 säännöt säilyvät');
  select count(*) into n from jsonb_array_elements(booking.public_catalog_for('consumer')) x where x ->> 'slug' in ('saunavuoro-yrityksille', 'jalkiloylyt-yrityksille');
  perform public.t74_ck(n = 0, 'A7: kuluttajan katalogi ei sisällä yritysvuoroja');
  select count(*) into n from jsonb_array_elements(booking.public_catalog_for('business')) x;
  perform public.t74_ck(n = 2 and (select count(*) from jsonb_array_elements(booking.public_catalog_for('business')) x where x ->> 'slug' in ('saunavuoro-yrityksille', 'jalkiloylyt-yrityksille') and x ->> 'audience' = 'business') = 2, 'A8: yrityskatalogi on täsmälleen nämä kaksi');
  select count(*) into n from jsonb_array_elements(booking.public_catalog()) x where x ->> 'slug' in ('saunavuoro-yrityksille', 'jalkiloylyt-yrityksille');
  perform public.t74_ck(n = 2, 'A9: public_catalog() säilyttää rivit (ei tuhoavaa poistoa)');

  insert into auth.users(id, email) values (u_mgr, 't74-mgr@example.test'), (u_st, 't74-st@example.test');
  insert into booking.staff(user_id, email, name, role) values (u_mgr, 't74-mgr@example.test', 't74 mgr', 'manager'), (u_st, 't74-st@example.test', 't74 staff', 'staff');
  perform public.t74_login(u_st);
  perform public.t74_ck(public.t74_try(format('select booking.admin_update_product_config(%s, %L::jsonb)', id17, '{"audience":"consumer"}')) = 'forbidden', 'A10: staff ei vaihda näkyvyyttä');
  perform public.t74_logout(); perform public.t74_login(u_mgr);
  perform public.t74_ck(public.t74_try(format('select booking.admin_update_product_config(%s, %L::jsonb)', id17, '{"audience":"vip"}')) = 'invalid_audience', 'A11: virheellinen audience');
  perform booking.admin_update_product_config(id17, '{"audience":"consumer"}'::jsonb);
  perform public.t74_logout();
  select count(*) into n from jsonb_array_elements(booking.public_catalog_for('consumer')) x where x ->> 'slug' = 'saunavuoro-yrityksille';
  perform public.t74_ck(n = 1, 'A12: consumer-asetus palauttaa vuoron kuluttajan kalenteriin');
  perform public.t74_login(u_mgr);
  perform booking.admin_update_product_config(id17, '{"audience":"business"}'::jsonb);
  perform public.t74_logout();
  select count(*) into n from jsonb_array_elements(booking.public_catalog_for('consumer')) x where x ->> 'slug' = 'saunavuoro-yrityksille';
  perform public.t74_ck(n = 0, 'A13: business-asetus rajaa vuoron taas pois');

  log := current_setting('t74.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
