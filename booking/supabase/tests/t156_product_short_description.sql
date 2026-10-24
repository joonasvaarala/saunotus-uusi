-- t156: tuotteen lyhyt kuvaus (booking_156, migraatio 20261024163053).
-- A sarakkeet + rajoite, B rajoite hylkää kielletyt tagit / hyväksyy sallitut (sama allowlist kuin kuvauksella, booking._rich_text_check),
-- C admin_update_product, D admin_product_create, E public_catalog (anon), F tekstijärjestelmä (product.<id>.short_description fi/en),
-- G migraation uudelleenajo, H rollback (funktiot täsmälleen tuotannon pg_get_functiondef-md5:llä, sarakkeet ja tekstirivit pois) + rollbackin uudelleenajo.
-- Ajo (psql, testikanta tai paikallinen PG17, migraatiot ja fixtures/10_test_helpers.sql ajettu):
--   cd booking/supabase/tests && psql -X -v ON_ERROR_STOP=0 -f t156_product_short_description.sql
-- Kaikki yhdessä transaktiossa; lopussa tahallinen poikkeus "TESTRESULT pass=… fail=…" kumoaa kaiken (myös rollbackin). Ei tuotantoon.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
create temp table t156_r(ok boolean, label text);
grant all on t156_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t156_r values (coalesce(p_ok, false), p_label) $$;

-- G: migraatio ajetaan uudelleen (uudelleenajettavuus)
create temp table t156_before as select (select count(*) from booking.site_texts where source_table = 'kb.products' and source_column in ('short_description', 'short_description_en')) n_texts;
\ir ../migrations/20261024163053_booking_156_product_short_description.sql

do $t$
declare
  u_mgr uuid := test.mk_staff('t156-mgr@example.test', 'manager');
  u_staff uuid := test.mk_staff('t156-staff@example.test', 'staff');
  v_pid bigint; v_cat jsonb; v_row jsonb; res jsonb; v_new bigint; v_n int;
  v_ok text := '<p>Lyhyt <strong>kuvaus</strong> ja <em>linkki</em> <a href="https://example.test/x">tästä</a>.</p><ul><li>yksi</li></ul><h3>Otsikko</h3><br>';
begin
  -- A
  perform pg_temp.ck((select count(*) from information_schema.columns where table_schema = 'kb' and table_name = 'products' and column_name in ('short_description', 'short_description_en') and data_type = 'text' and is_nullable = 'YES') = 2, 'A1: sarakkeet short_description(_en) text null');
  perform pg_temp.ck((select count(*) from pg_constraint where conrelid = 'kb.products'::regclass and conname = 'kb_products_short_description_rich_check') = 1, 'A2/G1: rajoite tasan kerran (uudelleenajo ei monista)');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._short_description_check(text)', 'execute') and not has_function_privilege('authenticated', 'booking._short_description_check(text)', 'execute'), 'A3: apufunktio ei anonille/authenticatedille');
  perform pg_temp.ck((select n_texts from t156_before) = (select count(*) from booking.site_texts where source_table = 'kb.products' and source_column in ('short_description', 'short_description_en')), 'G2: uudelleenajo ei lisännyt tekstirivejä');

  select (e ->> 'id')::bigint into v_pid from jsonb_array_elements(booking.public_catalog()) e limit 1;
  perform pg_temp.ck(v_pid is not null, 'A4: katalogissa on tuote');

  -- B: rajoite (suora päivitys, kuten tekstijärjestelmän julkaisu)
  perform pg_temp.ck(test.code(format('update kb.products set short_description = %L where id = %s', '<p>x</p><script>alert(1)</script>', v_pid)) = 'html_not_allowed', 'B1: <script> hylätään');
  perform pg_temp.ck(test.code(format('update kb.products set short_description_en = %L where id = %s', '<img src=x onerror=alert(1)>', v_pid)) = 'html_not_allowed', 'B2: <img onerror> hylätään (EN)');
  perform pg_temp.ck(test.code(format('update kb.products set short_description = %L where id = %s', '<p style="color:red">x</p>', v_pid)) = 'html_not_allowed', 'B3: style-attribuutti hylätään');
  perform pg_temp.ck(test.code(format('update kb.products set short_description = %L where id = %s', '<a href="javascript:alert(1)">x</a>', v_pid)) = 'html_not_allowed', 'B4: javascript:-linkki hylätään');
  perform pg_temp.ck(test.code(format('update kb.products set short_description = %L where id = %s', '<span>x</span>', v_pid)) = 'html_not_allowed', 'B5: <span> (ei allowlistalla) hylätään');
  perform pg_temp.ck(test.code(format('update kb.products set short_description = %L where id = %s', '<div>x</div>', v_pid)) = 'html_not_allowed', 'B6: <div> hylätään');
  perform pg_temp.ck(test.code(format('update kb.products set short_description = %L where id = %s', repeat('a', 1001), v_pid)) = 'too_long', 'B7: yli 1000 merkkiä hylätään');
  perform pg_temp.ck(test.code(format('update kb.products set short_description = %L, short_description_en = %L where id = %s', v_ok, v_ok, v_pid)) = 'ok', 'B8: sallitut tagit (p, strong, em, a https, ul/li, h3, br) hyväksytään');
  perform pg_temp.ck(test.code(format('update kb.products set short_description = %L where id = %s', 'Pelkkä teksti, personal data: ok', v_pid)) = 'ok', 'B9: pelkkä teksti hyväksytään');
  perform pg_temp.ck(test.code(format('update kb.products set short_description = null, short_description_en = null where id = %s', v_pid)) = 'ok', 'B10: null hyväksytään');
  perform pg_temp.ck(test.code(format('update kb.products set short_description = %L where id = %s', repeat('a', 1000), v_pid)) = 'ok', 'B11: tasan 1000 merkkiä hyväksytään');

  -- C: admin_update_product
  perform test.login(u_staff);
  perform pg_temp.ck(test.code(format($q$select booking.admin_update_product(%s, '{"short_description":"<p>x</p>"}'::jsonb)$q$, v_pid)) = 'forbidden', 'C1: staff ilman catalog.edit ei tallenna');
  perform test.logout();
  update kb.products set short_description = 'vanha', short_description_en = 'old' where id = v_pid;
  perform test.login(u_mgr);
  perform pg_temp.ck(test.code(format($q$select booking.admin_update_product(%s, %L::jsonb)$q$, v_pid, jsonb_build_object('short_description', '<p onclick="x()">x</p>'))) = 'html_not_allowed', 'C2: RPC hylkää on*-attribuutin');
  perform pg_temp.ck(test.code(format($q$select booking.admin_update_product(%s, %L::jsonb)$q$, v_pid, jsonb_build_object('short_description_en', '<iframe src="https://x"></iframe>'))) = 'html_not_allowed', 'C3: RPC hylkää iframen (EN)');
  perform pg_temp.ck(test.code(format($q$select booking.admin_update_product(%s, %L::jsonb)$q$, v_pid, jsonb_build_object('short_description', repeat('b', 1001)))) = 'too_long', 'C4: RPC hylkää yli 1000 merkkiä');
  perform test.logout();
  perform pg_temp.ck((select short_description = 'vanha' and short_description_en = 'old' from kb.products where id = v_pid), 'C5: hylätty tallennus ei muuttanut riviä');
  perform test.login(u_mgr);
  res := booking.admin_update_product(v_pid, jsonb_build_object('short_description', v_ok, 'short_description_en', '<p>Short <em>EN</em></p>'));
  perform test.logout();
  perform pg_temp.ck((res ->> 'ok')::boolean and (select short_description = v_ok and short_description_en = '<p>Short <em>EN</em></p>' from kb.products where id = v_pid), 'C6: sallittu FI+EN tallentuu');
  v_row := jsonb_build_object('name', (select name from kb.products where id = v_pid));
  perform test.login(u_mgr);
  res := booking.admin_update_product(v_pid, v_row);
  perform test.logout();
  perform pg_temp.ck((select short_description = v_ok from kb.products where id = v_pid), 'C7: patch ilman kenttää ei koske lyhyeen kuvaukseen');
  perform test.login(u_mgr);
  res := booking.admin_update_product(v_pid, '{"short_description_en":"  "}'::jsonb);
  v_row := (select e from jsonb_array_elements(booking.admin_list_products()) e where (e ->> 'id')::bigint = v_pid);
  perform test.logout();
  perform pg_temp.ck((select short_description_en is null from kb.products where id = v_pid), 'C8: tyhjä/välilyönnit → null');
  perform pg_temp.ck(v_row ->> 'short_description' = v_ok and v_row ? 'short_description_en', 'C9: admin_list_products palauttaa kentät');

  -- D: admin_product_create
  select count(*) into v_n from kb.products;
  perform test.login(u_mgr);
  perform pg_temp.ck(test.code($q$select booking.admin_product_create('{"name":"T156 huono","price":1,"vat_rate":25.5,"short_description":"<script>x</script>"}'::jsonb)$q$) = 'html_not_allowed', 'D1: luonti hylkää kielletyn tagin');
  perform pg_temp.ck(test.code($q$select booking.admin_product_create('{"name":"T156 huono en","price":1,"vat_rate":25.5,"short_description_en":"<p style=\"x\">a</p>"}'::jsonb)$q$) = 'html_not_allowed', 'D2: luonti hylkää style-attribuutin (EN)');
  perform test.logout();
  perform pg_temp.ck((select count(*) from kb.products) = v_n, 'D3: hylätty luonti ei jättänyt riviä');
  perform test.login(u_mgr);
  res := booking.admin_product_create(jsonb_build_object('name', 'T156 testituote', 'price', 2, 'vat_rate', 25.5, 'short_description', '<p>Lyhyt <strong>FI</strong></p>', 'short_description_en', '<p>Short EN</p>'));
  perform test.logout();
  v_new := (res ->> 'id')::bigint;
  perform pg_temp.ck((select short_description = '<p>Lyhyt <strong>FI</strong></p>' and short_description_en = '<p>Short EN</p>' from kb.products where id = v_new), 'D4: luonti tallentaa FI+EN');
  perform pg_temp.ck(res #>> '{product,short_description}' = '<p>Lyhyt <strong>FI</strong></p>' and res #>> '{product,short_description_en}' = '<p>Short EN</p>', 'D5: luonnin vastaus sisältää kentät');
  perform pg_temp.ck((select count(*) from booking.site_texts where key = 'product.' || v_new || '.short_description' and kind = 'rich' and max_len = 1000 and status = 'published'
                       and ((lang = 'fi' and source_column = 'short_description' and published_text = '<p>Lyhyt <strong>FI</strong></p>') or (lang = 'en' and source_column = 'short_description_en' and published_text = '<p>Short EN</p>'))) = 2, 'D6: uusi tuote rekisteröityy tekstijärjestelmään (fi+en, rich)');

  -- E: public_catalog (anon)
  perform test.anon();
  v_cat := booking.public_catalog();
  perform test.logout();
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(v_cat) e where not (e ? 'short_description' and e ? 'short_description_en')), 'E1: jokaisella katalogirivillä kentät short_description(_en)');
  perform pg_temp.ck((select e ->> 'short_description' = v_ok and e -> 'short_description_en' = 'null'::jsonb from jsonb_array_elements(v_cat) e where (e ->> 'id')::bigint = v_pid), 'E2: arvot katalogissa (null EN → null)');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(v_cat) e where (e ->> 'id')::bigint = v_new), 'E3: uusi (ei verkossa) tuote ei katalogissa');
  perform pg_temp.ck((select count(*) from jsonb_array_elements(booking.public_catalog_for('consumer')) e where e ? 'short_description') = (select count(*) from jsonb_array_elements(booking.public_catalog_for('consumer'))), 'E4: public_catalog_for perii kentät');

  -- F: tekstijärjestelmä
  perform pg_temp.ck((select count(*) from booking.site_texts where source_table = 'kb.products' and source_column = 'short_description' and lang = 'fi' and kind = 'rich' and max_len = 1000 and class = 'normal')
                     = (select count(*) from kb.products where active), 'F1: jokaisella aktiivisella tuotteella product.<id>.short_description [fi]');
  perform pg_temp.ck((select count(*) from booking.site_texts where source_table = 'kb.products' and source_column = 'short_description_en' and lang = 'en' and kind = 'rich' and max_len = 1000)
                     = (select count(*) from kb.products where active), 'F2: … ja [en] (short_description_en)');
  perform pg_temp.ck((select published_text = v_ok and published_version >= 1 from booking.site_texts where key = 'product.' || v_pid || '.short_description' and lang = 'fi'), 'F3: tallennus synkronoi tekstijärjestelmään (trigger)');
  perform pg_temp.ck(test.code($q$select booking._text_validate('normal', 'rich', 1000, '{}', '<p>x</p><script>y</script>')$q$) = 'html_not_allowed'
                     and test.code(format($q$select booking._text_validate('normal', 'rich', 1000, '{}', %L)$q$, v_ok)) = 'ok', 'F4: tekstijärjestelmän validointi (rich) sama allowlist');
  perform pg_temp.ck(test.code($q$select booking._texts_register_sources()$q$) = 'ok' and (select count(*) from booking.site_texts where key = 'product.' || v_pid || '.short_description') = 2, 'F5: _texts_register_sources uudelleen ei monista');
  perform pg_temp.ck((select kind = 'rich' and max_len = 8000 from booking.site_texts where key = 'product.' || v_pid || '.description' and lang = 'fi'), 'F6: kuvauksen rekisteröinti ennallaan (rich 8000)');
end $t$;

-- H: rollback (ajetaan kahdesti)
\ir ../rollbacks/20261024163053_booking_156_ROLLBACK.sql
\ir ../rollbacks/20261024163053_booking_156_ROLLBACK.sql
do $t$
declare v_md5 jsonb := (select jsonb_object_agg(p.proname, md5(pg_get_functiondef(p.oid))) from pg_proc p where p.pronamespace = 'booking'::regnamespace
  and p.proname in ('_texts_reg', '_texts_register_sources', 'admin_update_product', 'admin_product_create', 'admin_list_products', 'public_catalog'));
begin
  -- tuotannon md5(pg_get_functiondef) ennen booking_156:ta (luettu sxbofnuisemspgquoxyv 2026-10-24)
  perform pg_temp.ck(v_md5 = '{"_texts_reg":"957899c59fa87e65994a9ffacb59ab8f","_texts_register_sources":"288af591eefb49d9ad48a7958c44ef14","admin_list_products":"a78891b910ae65a7ea7583979ede71d4","admin_product_create":"0516c7f53b7eae66b04522382ed1c1fb","admin_update_product":"3cca4125054a32111235a25a5b8402de","public_catalog":"a55b3a8bf0d3e8820f83b139b58f6057"}'::jsonb, 'H1: rollback palauttaa funktiot tuotannon md5:een: ' || v_md5::text);
  perform pg_temp.ck(not exists (select 1 from information_schema.columns where table_schema = 'kb' and table_name = 'products' and column_name like 'short_description%'), 'H2: sarakkeet poistettu');
  perform pg_temp.ck(not exists (select 1 from booking.site_texts where source_column in ('short_description', 'short_description_en')), 'H3: tekstirivit poistettu');
  perform pg_temp.ck(to_regprocedure('booking._short_description_check(text)') is null and not exists (select 1 from pg_constraint where conname = 'kb_products_short_description_rich_check'), 'H4: apufunktio ja rajoite poistettu');
  perform pg_temp.ck(jsonb_typeof(booking.public_catalog()) = 'array' and not exists (select 1 from jsonb_array_elements(booking.public_catalog()) e where e ? 'short_description'), 'H5: public_catalog toimii rollbackin jälkeen ilman kenttiä');
end $t$;

do $t$
declare v_pass int; v_fail int; v_list text; begin
  select count(*) filter (where ok), count(*) filter (where not ok), string_agg(case when not ok then label end, ' | ') into v_pass, v_fail, v_list from t156_r;
  raise exception 'TESTRESULT pass=% fail=% :: %', v_pass, v_fail, coalesce(v_list, 'ALL OK');
end $t$;
rollback;
