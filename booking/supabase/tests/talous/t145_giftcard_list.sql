-- t145: hallinnan lahjakorttilista (booking_145): tuotteen nimi riville, haku tuotteella, aakkosjärjestys (name_asc), sivutus 20.
-- Kaikki data on feikkiä (@example.test). Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN.
-- Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken. Tulos: TESTRESULT pass=… fail=…
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t145_r(ok boolean, label text) on commit drop;
grant all on t145_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t145_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare v text; begin execute p_sql; return 'NO ERROR'; exception when others then get stacked diagnostics v = pg_exception_detail; return coalesce(nullif(v, ''), sqlerrm); end $$;
create function pg_temp.l(p jsonb) returns jsonb language plpgsql as $$
begin return booking.admin_list_gift_cards(p_search => p ->> 'q', p_source => p ->> 's', p_sort => coalesce(p ->> 'sort', 'created_desc'),
  p_limit => coalesce((p ->> 'lim')::int, 200), p_offset => coalesce((p ->> 'off')::int, 0)); end $$;
do $t$
declare
  v_adm uuid := test.mk_staff('adm145@example.test', 'admin');
  v_p40 text := (select name from kb.products where id = 40); v_pkg text := (select name from booking.gift_card_packages where code = 'entry_2');
  j jsonb; v_names text[]; v_codes text[]; v_n int; i int;
begin
  -- 3 omaa (paketti), 2 Johkua tuotteella (kb.products 40), 1 Johku pelkällä mallin nimellä, 40 Johku-täytettä sivutukseen
  insert into booking.gift_cards(code, issuer, kind, package_code, initial_amount, balance, status, source, vat_treatment, accounting_origin, balance_verified, valid_to, recipient_name, buyer_name, buyer_email, created_at)
  values ('HHT145AAAA01', 'own', 'product', 'entry_2', 58, 58, 'active', 'native', 'at_sale', 'native', true, date '2036-01-01', 'Örjan Testi', 'Bertta Ostaja', 'bertta145@example.test', now() - interval '3 days'),
         ('HHT145AAAA02', 'own', 'value', 'open', 50, 50, 'active', 'native', 'at_sale', 'native', true, date '2036-01-01', null, 'Åke Testi', 'ake145@example.test', now() - interval '2 days'),
         ('HHT145AAAA03', 'own', 'value', 'open', 70, 70, 'active', 'native', 'at_sale', 'native', true, date '2036-01-01', 'ärrä testi', null, null, now() - interval '1 days');
  insert into booking.gift_cards(code, issuer, kind, product_id, initial_amount, balance, status, source, vat_treatment, accounting_origin, balance_verified, valid_to, buyer_name, buyer_email, external_source, external_id, external_meta, created_at)
  values ('JT145BBBBB01', 'johku', 'value', 40, 120, 120, 'active', 'johku', 'at_sale', 'johku', true, date '2036-01-01', 'Zeta Johku', 'zeta145@example.test', 'johku', 't145-1', '{"template":"Muu malli"}', now() - interval '400 days'),
         ('JT145BBBBB02', 'johku', 'value', 40, 120, 0, 'used', 'johku', 'at_sale', 'johku', true, date '2036-01-01', 'aatu johku', 'aatu145@example.test', 'johku', 't145-2', null, now() - interval '300 days'),
         ('JT145BBBBB03', 'johku', 'value', null, 40, 40, 'active', 'johku', 'at_sale', 'johku', true, date '2036-01-01', null, null, 'johku', 't145-3', '{"template":"Arkivuoro kahdelle T145"}', now() - interval '200 days');
  for i in 1..40 loop
    insert into booking.gift_cards(code, issuer, kind, initial_amount, balance, status, source, vat_treatment, accounting_origin, balance_verified, valid_to, buyer_name, external_source, external_id, created_at)
    values ('JT145FF' || lpad(i::text, 5, '0'), 'johku', 'value', 25, 25, 'active', 'johku', 'at_sale', 'johku', true, date '2036-01-01', 'Täyte ' || lpad(i::text, 2, '0'), 'johku', 't145-f' || i, now() - interval '500 days' - i * interval '1 day');
  end loop;

  -- ===== Oikeudet =====
  perform test.anon();
  perform pg_temp.ck(pg_temp.err($$select pg_temp.l('{}')$$) <> 'NO ERROR', 'O1: anon ei saa listaa');
  perform test.logout();
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._gc_product_name(booking.gift_cards)', 'execute')
    and not has_function_privilege('authenticated', 'booking._gc_product_name(booking.gift_cards)', 'execute'), 'O2: _gc_product_name ei anonille/authenticatedille');
  perform pg_temp.ck((select prosecdef and proconfig = array['search_path=""'] from pg_proc where oid = 'booking.admin_list_gift_cards(text,text,text,text,text,text,boolean,integer,boolean,text,integer,integer)'::regprocedure),
    'O3: admin_list_gift_cards SECURITY DEFINER + search_path ''''');
  perform pg_temp.ck(has_function_privilege('authenticated', 'booking.admin_list_gift_cards(text,text,text,text,text,text,boolean,integer,boolean,text,integer,integer)', 'execute')
    and not has_function_privilege('anon', 'booking.admin_list_gift_cards(text,text,text,text,text,text,boolean,integer,boolean,text,integer,integer)', 'execute'), 'O4: oikeudet ennallaan');

  perform test.login(v_adm);
  -- ===== Tuotteen nimi =====
  j := pg_temp.l('{"q":"JT145BBBBB01"}');
  perform pg_temp.ck(j ->> 'total' = '1' and j -> 'rows' -> 0 ->> 'product_name' = v_p40, 'P1: Johku + product_id → kb.products.name (ennen mallin nimeä)');
  j := pg_temp.l('{"q":"JT145BBBBB03"}');
  perform pg_temp.ck(j -> 'rows' -> 0 ->> 'product_name' = 'Arkivuoro kahdelle T145', 'P2: Johku ilman tuotetta → mallin nimi');
  j := pg_temp.l('{"q":"HHT145AAAA01"}');
  perform pg_temp.ck(j -> 'rows' -> 0 ->> 'product_name' = v_pkg
    and j -> 'rows' -> 0 ->> 'package_name' = j -> 'rows' -> 0 ->> 'product_name', 'P3: oma kortti → paketin nimi');
  perform pg_temp.ck((j -> 'rows' -> 0) ?& array['id', 'code', 'source', 'balance', 'initial_amount', 'valid_to', 'effective_status', 'buyer_name', 'recipient_name', 'created_at'], 'P4: rivin vanhat kentät ennallaan');

  -- ===== Haku =====
  perform pg_temp.ck((pg_temp.l('{"q":"arkivuoro KAHDELLE t145"}') ->> 'total')::int = 1, 'H1: tuotteen nimi, kirjainkoko ei vaikuta');
  perform pg_temp.ck((pg_temp.l('{"q":"saunahoito -lahjakortti"}') ->> 'total')::int = 2, 'H2: tuotehaku osuu Johku-kortteihin (kb.products)');
  perform pg_temp.ck((pg_temp.l('{"q":"ZETA145@EXAMPLE"}') ->> 'total')::int = 1, 'H3: sähköposti kirjainkoosta riippumatta (Johku)');
  perform pg_temp.ck((pg_temp.l('{"q":"ÖRJAN"}') ->> 'total')::int = 1, 'H4: saajan nimi isoilla kirjaimilla');
  perform pg_temp.ck((pg_temp.l('{"q":"jt145 bbbbb 02"}') ->> 'total')::int = 1, 'H5: koodi pienillä ja välilyönneillä (Johku)');
  perform pg_temp.ck((pg_temp.l('{"q":"T145","s":"johku"}') ->> 'total')::int = 43, 'H6: haku + lähde');
  perform pg_temp.ck((pg_temp.l('{"q":"ei-osu-t145-xyz"}') ->> 'total')::int = 0, 'H7: ei osumia');

  -- ===== Järjestys =====
  j := pg_temp.l('{"sort":"name_asc","lim":200}');
  select array_agg(coalesce(nullif(x ->> 'recipient_name', ''), x ->> 'buyer_name') order by n) into v_names from jsonb_array_elements(j -> 'rows') with ordinality e(x, n);
  v_names := array(select v from unnest(v_names) v where v in ('aatu johku', 'Bertta Ostaja', 'Zeta Johku', 'Åke Testi', 'ärrä testi', 'Örjan Testi'));
  perform pg_temp.ck(v_names = array['aatu johku', 'Zeta Johku', 'Åke Testi', 'ärrä testi', 'Örjan Testi'], 'J1: name_asc: saaja ennen ostajaa, fi-aakkostus (Z < Å < Ä < Ö), kirjainkoko ei vaikuta: ' || coalesce(array_to_string(v_names, ','), 'null'));
  perform pg_temp.ck(j -> 'rows' -> -1 ->> 'code' = 'JT14-5BBB-BB03', 'J2: nimetön viimeisenä');
  j := pg_temp.l('{"q":"T145","lim":200}');
  perform pg_temp.ck(j -> 'rows' -> 0 ->> 'code' = 'HHT1-45AA-AA03' and j -> 'rows' -> -1 ->> 'code' = 'JT14-5FF0-0040', 'J3: oletus uusin ensin');
  j := pg_temp.l('{"q":"T145","sort":"created_asc","lim":200}');
  perform pg_temp.ck(j -> 'rows' -> 0 ->> 'code' = 'JT14-5FF0-0040' and j -> 'rows' -> -1 ->> 'code' = 'HHT1-45AA-AA03', 'J4: vanhin ensin');
  perform pg_temp.ck(pg_temp.err($$select pg_temp.l('{"sort":"name_desc"}')$$) ilike '%invalid_sort%' or pg_temp.err($$select pg_temp.l('{"sort":"name_desc"}')$$) ilike '%lajittelu%', 'J5: tuntematon järjestys hylätään');

  -- ===== Sivutus 20 =====
  j := pg_temp.l('{"q":"T145","lim":20}');
  perform pg_temp.ck((j ->> 'total')::int = 46 and jsonb_array_length(j -> 'rows') = 20, 'S1: 20 riviä / sivu, total 46');
  j := pg_temp.l('{"q":"T145","lim":20,"off":40}');
  perform pg_temp.ck(jsonb_array_length(j -> 'rows') = 6, 'S2: viimeinen sivu 6');
  select count(distinct x ->> 'id') into v_n from generate_series(0, 2) p, jsonb_array_elements(pg_temp.l(jsonb_build_object('q', 'T145', 'sort', 'name_asc', 'lim', 20, 'off', p * 20)) -> 'rows') x;
  perform pg_temp.ck(v_n = 46, 'S3: name_asc-sivut eivät toista eivätkä hukkaa rivejä');
  perform test.logout();

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t145_r where ok), (select count(*) from t145_r where not ok),
    coalesce((select string_agg(label, ' | ') from t145_r where not ok), 'ALL OK');
end $t$;
