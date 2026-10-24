-- t147: booking_147 – public_catalog() ja admin_list_products() palauttavat 'duration_text_en' (kb.products.duration_text_en).
-- Ajetaan paikallisessa PG17:ssä: fixtures + migraatiot booking_148:aan asti → kesto/pre147.sql → booking_147-migraatio → tämä tiedosto
-- (sama istunto, pre147 on temp-taulu). Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken. Tulos: TESTRESULT pass=… fail=…
-- Kaikki data on feikkiä (@example.test).
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t147_r(ok boolean, label text) on commit drop;
grant all on t147_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t147_r values (coalesce(p_ok, false), p_label) $$;
-- jsonb-taulukko ilman annettua avainta joka alkiossa
create function pg_temp.strip(a jsonb, k text) returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(x - k order by o), '[]'::jsonb) from jsonb_array_elements(a) with ordinality e(x, o) $$;
do $t$
declare
  pre record; v_adm uuid := test.mk_staff('adm147@example.test', 'admin'); c jsonb; a jsonb; pid bigint; pid2 bigint; n int;
begin
  select * into pre from pre147;
  -- ===== Tekniset =====
  perform pg_temp.ck(exists (select 1 from information_schema.columns where table_schema = 'kb' and table_name = 'products' and column_name = 'duration_text_en' and data_type = 'text' and is_nullable = 'YES'), 'T1: kb.products.duration_text_en (text, nullable)');
  perform pg_temp.ck(pre.md5_cat = '0cd7d46e6d9bb24499e1b2ab6e334587' and pre.md5_alp = '7a881ee43d8231528c5a05f8359da540', 'T2: repon ketju ennen booking_147:ää = tuotannon määritelmät (md5 pg_get_functiondef 24.10.2026)');
  perform pg_temp.ck((select bool_and(prosecdef and proconfig = array['search_path=""'] and provolatile = 's') from pg_proc where oid in ('booking.public_catalog()'::regprocedure, 'booking.admin_list_products()'::regprocedure)), 'T3: security definer, search_path tyhjä, stable');
  perform pg_temp.ck((select proacl::text from pg_proc where oid = 'booking.public_catalog()'::regprocedure) = pre.acl_cat
    and (select proacl::text from pg_proc where oid = 'booking.admin_list_products()'::regprocedure) = pre.acl_alp, 'T4: oikeudet (proacl) ennallaan');
  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_catalog()', 'execute') and not has_function_privilege('anon', 'booking.admin_list_products()', 'execute')
    and has_function_privilege('authenticated', 'booking.admin_list_products()', 'execute'), 'T5: anon saa katalogin, ei hallinnan tuotelistaa');
  -- ===== Katalogi =====
  c := booking.public_catalog();
  perform pg_temp.ck(jsonb_array_length(c) > 0 and jsonb_array_length(c) = jsonb_array_length(pre.cat), 'T6: katalogin rivimäärä ennallaan (' || jsonb_array_length(c) || ')');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(c) x where not x ? 'duration_text_en'), 'T7: jokaisella rivillä avain duration_text_en');
  perform pg_temp.ck(pg_temp.strip(c, 'duration_text_en') = pre.cat, 'T8: muut kentät ja järjestys täsmälleen ennallaan (hinnat, ALV, slugit, kestot)');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(c) x where x -> 'duration_text_en' <> 'null'::jsonb), 'T9: tyhjä sarake → null (frontend käyttää duration_text)');
  select (x ->> 'id')::bigint into pid from jsonb_array_elements(c) x where x ->> 'booking_kind' = 'slots' order by (x ->> 'id')::bigint limit 1;
  select (x ->> 'id')::bigint into pid2 from jsonb_array_elements(c) x where x ->> 'booking_kind' = 'rules' order by (x ->> 'id')::bigint limit 1;
  update kb.products set duration_text_en = 'approx. 1 h (test)' where id = pid;
  update kb.products set duration_text_en = '1.5 h (test)' where id = pid2;
  c := booking.public_catalog();
  perform pg_temp.ck((select x ->> 'duration_text_en' from jsonb_array_elements(c) x where (x ->> 'id')::bigint = pid) = 'approx. 1 h (test)'
    and (select x ->> 'duration_text_en' from jsonb_array_elements(c) x where (x ->> 'id')::bigint = pid2) = '1.5 h (test)', 'T10: täytetty EN-kesto näkyy (hoito ' || pid || ', vuoro ' || pid2 || ')');
  perform pg_temp.ck((select count(*) from jsonb_array_elements(c) x where x ->> 'duration_text_en' is not null) = 2, 'T11: vain täytetyt rivit saavat EN-keston');
  perform pg_temp.ck(pg_temp.strip(c, 'duration_text_en') = pre.cat, 'T12: suomenkielinen duration_text ei muutu');
  perform test.anon();
  c := booking.public_catalog();
  perform test.logout();
  perform pg_temp.ck((select x ->> 'duration_text_en' from jsonb_array_elements(c) x where (x ->> 'id')::bigint = pid) = 'approx. 1 h (test)', 'T13: anon näkee EN-keston');
  perform pg_temp.ck(booking.public_catalog_for('consumer') -> 0 ? 'duration_text_en', 'T14: public_catalog_for perii kentän');
  -- ===== Hallinta =====
  perform test.login(v_adm);
  a := booking.admin_list_products();
  perform test.logout();
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(a) x where not x ? 'duration_text_en')
    and (select x ->> 'duration_text_en' from jsonb_array_elements(a) x where (x ->> 'id')::bigint = pid) = 'approx. 1 h (test)', 'T15: admin_list_products palauttaa duration_text_en');
  perform pg_temp.ck(pg_temp.strip(pg_temp.strip(a, 'duration_text_en'), 'updated_at') = pg_temp.strip(pre.alp, 'updated_at'), 'T16: hallinnan tuotelista muuten ennallaan (updated_at pois vertailusta)');
  begin
    perform test.anon(); perform booking.admin_list_products(); perform test.logout();
    perform pg_temp.ck(false, 'T17: anon ei saa hallinnan tuotelistaa');
  exception when others then perform test.logout(); perform pg_temp.ck(true, 'T17: anon ei saa hallinnan tuotelistaa');
  end;
  perform pg_temp.ck((select md5(string_agg(id::text || ':' || coalesce(price::text, '') || ':' || coalesce(price_text, '') || ':' || coalesce(vat_rate::text, ''), '|' order by id)) from kb.products) = pre.prices, 'T18: hinnat, hintatekstit ja ALV ennallaan');

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t147_r where ok), (select count(*) from t147_r where not ok),
    coalesce((select string_agg(label, ' | ') from t147_r where not ok), 'ALL OK');
end $t$;
