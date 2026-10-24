-- t172: yritysasiakkaat löytyvät Uusi varaus- ja Uusi lasku -hausta (booking_172, tuotannossa versio 20261024222000).
-- A rakenne, md5 ja oikeudet, B tilausten yritykset (_order_company_hits), C Uusi varaus -haku (admin_search_customers),
-- D Uusi lasku -haku (admin_search_invoice_customers), E oikeudet (forbidden / ei EXECUTE-oikeutta), G Asiakkaat-lista (admin_list_customers) ennallaan,
-- Z lopputarkistus ROLLBACKin jälkeen (testirivejä ei jäänyt).
--
-- Ajettavissa TUOTANNOSSA kumottavana kuivaharjoituksena (kuten t112/t171): kaikki yhdessä transaktiossa, lopussa tahallinen poikkeus
-- "TESTRESULT pass=… fail=…" ja ROLLBACK. Ei riipu tuotannon datasta eikä test-skeemasta (fixtures/10_test_helpers.sql):
--   * testirivit luodaan ilman id:tä (GENERATED ALWAYS) ja id:t otetaan RETURNING-lauseella talteen (t172_fx);
--   * jokaisella ajolla oma satunnainen kirjaintunniste (:sfx, ei numeroita → y-tunnuksen numerohaku ei osu tuotannon riveihin) nimissä ja
--     sähköposteissa, ja y-tunnukset ovat 9-alkuisia tarkistemerkiltään kelvollisia tunnuksia, joita ei ole tuotannossa (tarkistetaan);
--   * henkilökunta kuten tuotannossa: auth.users-rivi + booking.staff (manager = invoices.manage, staff = ei invoices.manage) ja
--     kutsu roolina authenticated, request.jwt.claims.sub = käyttäjä (auth.uid() → current_staff_role → role_permissions);
--   * virheet tarkistetaan SQLSTATEn ja DETAIL-koodin perusteella (BK001 / forbidden, 42501), ei virhetekstistä.
-- Ajo (psql, tietokannan omistajana, esim. postgres; tuotannossa tai paikallisessa PG17:ssä migraatioiden jälkeen):
--   cd booking/supabase/tests/customers && psql -X -v ON_ERROR_STOP=0 -f t172_company_customer_search.sql
-- Odotettu tulos: rivi "ERROR:  TESTRESULT pass=N fail=0", sen jälkeen ROLLBACK ja "t172 leftover rows = 0".
-- (Vanha paikallinen minipohja t172_fixture_local.sql ei ole tämän testin edellytys.)
select 'zq' || translate(substr(md5(random()::text || clock_timestamp()::text), 1, 10), '0123456789', 'ghijklmnop') as sfx \gset
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
create temp table t172_r(ok boolean, label text);
create temp table t172_fx(k text primary key, id bigint, s text);
grant all on t172_r, t172_fx to public;
insert into t172_fx(k, s) values ('sfx', :'sfx');
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t172_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.names(j jsonb, k text) returns text[] language sql as $$ select coalesce(array_agg(e ->> k order by o), '{}') from jsonb_array_elements(coalesce(j, '[]'::jsonb)) with ordinality x(e, o) $$;
create function pg_temp.s() returns text language sql stable as $$ select s from t172_fx where k = 'sfx' $$;
create function pg_temp.id(p_k text) returns bigint language sql stable as $$ select id from t172_fx where k = p_k $$;
create function pg_temp.b(p_k text) returns text language sql stable as $$ select s from t172_fx where k = p_k $$;
create function pg_temp.uid(p_k text) returns uuid language sql stable as $$ select s::uuid from t172_fx where k = p_k $$;
-- uusi kelvollinen y-tunnus 9xxxxxx-c, jota ei löydy tuotannon asiakkailta, tilauksilta eikä laskutusasiakkailta (myöskään puhelinnumeron osana)
create function pg_temp.new_bid() returns text language plpgsql as $$
declare d text; w int[] := array[7,9,10,5,8,4,2]; v_sum int; r int; i int; c int; v text;
begin
  loop
    d := '9' || lpad((floor(random() * 1000000))::int::text, 6, '0');
    v_sum := 0;
    for i in 1..7 loop v_sum := v_sum + substr(d, i, 1)::int * w[i]; end loop;
    r := v_sum % 11;
    continue when r = 1;
    c := case when r = 0 then 0 else 11 - r end;
    v := d || '-' || c;
    continue when exists (select 1 from t172_fx where s = v)
      or exists (select 1 from booking.customers x where position(d || c in regexp_replace(concat_ws(' ', x.business_id, x.phone, x.email, x.name, x.company), '\D', '', 'g')) > 0)
      or exists (select 1 from booking.invoice_customers x where position(d || c in regexp_replace(concat_ws(' ', x.business_id, x.phone, x.email, x.company_name), '\D', '', 'g')) > 0)
      or exists (select 1 from booking.orders o where position(d || c in regexp_replace(coalesce(o.billing::text, ''), '\D', '', 'g')) > 0);
    return v;
  end loop;
end $$;
-- kutsu kirjautuneena (p_user) tai anonina (p_user null): {"r": tulos} tai {"err": DETAIL-koodi tai SQLSTATE, "state": SQLSTATE}
create function pg_temp.as_(p_user uuid, p_sql text) returns jsonb language plpgsql as $$
declare v jsonb; d text; st text;
begin
  if p_user is null then
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    set local role anon;
  else
    perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
    set local role authenticated;
  end if;
  begin
    execute p_sql into v;
    v := jsonb_build_object('r', v);
  exception when others then
    get stacked diagnostics d = pg_exception_detail, st = returned_sqlstate;
    v := jsonb_build_object('err', coalesce(nullif(d, ''), st), 'state', st);
  end;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  return v;
end $$;
create function pg_temp.sc(p_user uuid, p_q text, p_lim int default 8) returns jsonb language sql as $$
  select pg_temp.as_(p_user, format('select booking.admin_search_customers(%L, %s)', p_q, p_lim)) -> 'r' $$;
create function pg_temp.si(p_user uuid, p_q text, p_lim int default 10) returns jsonb language sql as $$
  select pg_temp.as_(p_user, format('select booking.admin_search_invoice_customers(%L, %s)', p_q, p_lim)) -> 'r' $$;
create function pg_temp.lc(p_user uuid, p_q text) returns jsonb language sql as $$
  select pg_temp.as_(p_user, format('select coalesce(jsonb_agg(to_jsonb(x) order by x.id), ''[]''::jsonb) from booking.admin_list_customers(%L, 50, 0) x', p_q)) -> 'r' $$;
grant execute on all functions in schema pg_temp to public;

-- ===== A rakenne
select pg_temp.ck(md5(pg_get_functiondef('booking.admin_search_invoice_customers(text,integer)'::regprocedure)) = '0b6a95a0bb492fe96632c719ff72e42c', 'A1 admin_search_invoice_customers = booking_172');
select pg_temp.ck(md5(pg_get_functiondef('booking.admin_search_customers(text,integer)'::regprocedure)) = '6ab4f8a588a792ca3af0614a20ceb659', 'A2 admin_search_customers md5');
select pg_temp.ck(md5(pg_get_functiondef('booking._order_company_hits(text,integer)'::regprocedure)) = '007c407a3fb71e6ee9098796ca34f57c', 'A3 _order_company_hits md5');
select pg_temp.ck(md5(pg_get_functiondef('booking.admin_list_customers(text,integer,integer)'::regprocedure)) = '1ffba8df04ac14a996400bc97182ec21', 'A4 admin_list_customers ennallaan (md5)');
select pg_temp.ck(has_function_privilege('authenticated', 'booking.admin_search_customers(text,integer)', 'execute'), 'A5 authenticated saa kutsua admin_search_customers');
select pg_temp.ck(not has_function_privilege('anon', 'booking.admin_search_customers(text,integer)', 'execute'), 'A6 anon ei admin_search_customers');
select pg_temp.ck(not has_function_privilege('authenticated', 'booking._order_company_hits(text,integer)', 'execute')
              and not has_function_privilege('anon', 'booking._order_company_hits(text,integer)', 'execute'), 'A7 _order_company_hits ei suoraan kutsuttavissa');

-- ===== fixture (feikki, kumoutuu): henkilökunta + Johku-yhteyshenkilö yksityisenä + yritystilaukset, rekisterin yritys, nimetön yritys
-- (ei y-tunnusta), anonymisoitu, henkilö, laskutusasiakas. Kaikki nimet/sähköpostit sisältävät ajon tunnisteen s.
do $fx$
declare s text := pg_temp.s(); v bigint; u uuid; r record;
begin
  insert into t172_fx(k, s) values ('bA', pg_temp.new_bid());
  insert into t172_fx(k, s) values ('bP', pg_temp.new_bid());
  insert into t172_fx(k, s) values ('bR', pg_temp.new_bid());
  insert into t172_fx(k, s) values ('bL', pg_temp.new_bid());
  -- henkilökunta (kuten tuotannossa: auth.users + booking.staff; auth.users.id annetaan itse)
  for r in select * from (values ('u_mgr', 'manager'), ('u_staff', 'staff')) t(k, role) loop
    u := gen_random_uuid();
    insert into auth.users(id, email) values (u, r.k || '.' || s || '@example.invalid');
    insert into booking.staff(user_id, email, name, role) values (u, r.k || '.' || s || '@example.invalid', 't172 ' || r.role || ' ' || s, r.role);
    insert into t172_fx(k, s) values (r.k, u::text);
  end loop;
  insert into t172_fx(k, s) values ('u_none', gen_random_uuid()::text);   -- kirjautunut, ei henkilökuntaa (ei riviä missään)
  -- asiakkaat (id GENERATED ALWAYS → RETURNING)
  insert into booking.customers(name, email, customer_kind, external_source, external_id)
    values ('Pekka ' || s || 'yhteys', 'pekka.' || s || '@example.test', 'private', 'johku', 't172-' || s || '-1') returning id into v;
  insert into t172_fx(k, id) values ('c_pekka', v);
  insert into booking.customers(name, email, customer_kind, external_source, external_id)
    values ('Tiina ' || s || 'tilaaja', 'tiina.' || s || '@example.test', 'private', 'johku', 't172-' || s || '-2') returning id into v;
  insert into t172_fx(k, id) values ('c_tiina', v);
  insert into booking.customers(name, email, customer_kind, external_source, external_id, anonymized_at)
    values ('Anni ' || s || 'anonyymi', 'anni.' || s || '@example.test', 'private', 'johku', 't172-' || s || '-3', now()) returning id into v;
  insert into t172_fx(k, id) values ('c_anni', v);
  insert into booking.customers(name, email, customer_kind, company, business_id, address, zip, city)
    values ('Rauno ' || s || 'rekisteri', 'rauno.' || s || '@example.test', 'company', 'Rekisteriyhtiö ' || s || ' Oy', pg_temp.b('bR'), 'Rekisterikatu 1', '00100', 'Helsinki')
    returning id into v;
  insert into t172_fx(k, id) values ('c_rauno', v);
  insert into booking.customers(name, email, customer_kind) values ('Henkilö ' || s || 'testinen', 'henkilo.' || s || '@example.test', 'private') returning id into v;
  insert into t172_fx(k, id) values ('c_henkilo', v);
  -- tilaukset (status completed: ei vahvistusviesti-triggeriä; Johku-rivit external_source + external_id)
  insert into booking.orders(customer_id, customer_kind, status, source_channel, external_source, external_id, created_at, billing) values
    (pg_temp.id('c_pekka'), 'company', 'completed', 'johku_import', 'johku', 't172-' || s || '-o1', now() - interval '200 days',
     jsonb_build_object('company', 'Saunaseura ' || s || ' Oy', 'business_id', pg_temp.b('bA'), 'name', 'Pekka ' || s || 'yhteys',
                        'email', 'laskut@saunaseura-' || s || '.example.test', 'address', 'Vanha tie 1', 'zip', '00200', 'city', 'Espoo', 'country', 'FI')),
    (pg_temp.id('c_pekka'), 'company', 'completed', 'johku_import', 'johku', 't172-' || s || '-o2', now() - interval '20 days',
     jsonb_build_object('company', 'Saunaseura ' || s || ' Oy', 'business_id', replace(pg_temp.b('bA'), '-', ''), 'name', 'Pekka ' || s || 'yhteys',
                        'email', 'laskut@saunaseura-' || s || '.example.test', 'address', 'Uusi katu 5', 'zip', '00210', 'city', 'Helsinki', 'country', 'FI',
                        'einvoice_address', '003799999999', 'einvoice_operator', 'e204503')),
    (pg_temp.id('c_tiina'), 'company', 'completed', 'johku_import', 'johku', 't172-' || s || '-o3', now() - interval '50 days',
     jsonb_build_object('company', 'Nimetön Kioski ' || s || ' Ky', 'name', 'Tiina ' || s || 'tilaaja', 'address', 'Torikatu 3', 'zip', '33100', 'city', 'Tampere')),
    (pg_temp.id('c_anni'), 'company', 'completed', 'johku_import', 'johku', 't172-' || s || '-o4', now() - interval '10 days',
     jsonb_build_object('company', 'Piilotettu ' || s || ' Oy', 'business_id', pg_temp.b('bP'), 'name', 'Anni ' || s || 'anonyymi')),
    (pg_temp.id('c_rauno'), 'company', 'completed', 'admin', null, null, now() - interval '5 days',
     jsonb_build_object('company', 'Rekisteriyhtiö ' || s || ' Oy', 'business_id', pg_temp.b('bR'), 'name', 'Rauno ' || s || 'rekisteri')),
    (pg_temp.id('c_henkilo'), 'private', 'completed', 'admin', null, null, now() - interval '3 days', null);
  insert into booking.invoice_customers(company_name, business_id, email) values ('Laskutusasiakas ' || s || ' Oy', pg_temp.b('bL'), 'lasku.' || s || '@example.test')
    returning id into v;
  insert into t172_fx(k, id) values ('ic_lasku', v);
end $fx$;
select pg_temp.ck((select count(*) from t172_fx where k like 'b_' and booking._business_id_ok(s)) = 4
              and (select count(distinct s) from t172_fx where k like 'b_') = 4, 'X1 fixture: 4 eri kelvollista y-tunnusta, joita ei ollut kannassa');

-- ===== B _order_company_hits (tietokannan omistajana; funktiota ei ole myönnetty authenticated-roolille)
select pg_temp.ck((select count(*) from booking._order_company_hits('saunaseura ' || pg_temp.s(), 10)) = 1, 'B1 kaksi tilausta samalle y-tunnukselle → yksi yritys');
select pg_temp.ck((select h.street = 'Uusi katu 5' and h.city = 'Helsinki' and h.einvoice_address = '003799999999' and h.einvoice_operator = 'E204503'
                     and h.business_id = pg_temp.b('bA') and h.orders_count = 2 and h.customer_id = pg_temp.id('c_pekka')
                     and h.contact_name = 'Pekka ' || pg_temp.s() || 'yhteys' and h.email = 'laskut@saunaseura-' || pg_temp.s() || '.example.test'
                     from booking._order_company_hits('saunaseura ' || pg_temp.s(), 10) h), 'B2 uusimman tilauksen tiedot, verkkolasku normalisoitu, yhteyshenkilö');
select pg_temp.ck((select count(*) = 1 and bool_and(h.customer_id = pg_temp.id('c_pekka')) from booking._order_company_hits(pg_temp.b('bA'), 10) h), 'B3 y-tunnus väliviivalla');
select pg_temp.ck((select count(*) = 1 and bool_and(h.customer_id = pg_temp.id('c_pekka')) from booking._order_company_hits(replace(pg_temp.b('bA'), '-', ''), 10) h), 'B4 y-tunnus ilman väliviivaa');
select pg_temp.ck((select count(*) from booking._order_company_hits(pg_temp.s() || 'yhteys', 10)) = 1, 'B5 yhteyshenkilön nimellä');
select pg_temp.ck((select count(*) from booking._order_company_hits('laskut@saunaseura-' || pg_temp.s(), 10)) = 1, 'B6 laskutussähköpostilla');
select pg_temp.ck((select count(*) from booking._order_company_hits('pekka.' || pg_temp.s() || '@example', 10)) = 1, 'B7 yhteyshenkilön rekisterisähköpostilla');
select pg_temp.ck((select count(*) = 1 and bool_and(h.business_id is null and h.company = 'Nimetön Kioski ' || pg_temp.s() || ' Ky'
                                                    and h.company_key = 'n:nimetön kioski ' || pg_temp.s() || ' ky')
                     from booking._order_company_hits('kioski ' || pg_temp.s(), 10) h), 'B8 yritys ilman y-tunnusta');
select pg_temp.ck(not exists (select 1 from booking._order_company_hits('piilotettu ' || pg_temp.s(), 10))
              and not exists (select 1 from booking._order_company_hits(pg_temp.b('bP'), 10)), 'B9 anonymisoidun asiakkaan yritys ei näy (nimi eikä y-tunnus)');
select pg_temp.ck(not exists (select 1 from booking._order_company_hits('S', 10)) and not exists (select 1 from booking._order_company_hits(null, 10)), 'B10 alle 2 merkkiä → ei osumia');
select pg_temp.ck(exists (select 1 from booking._order_company_hits('saunaseura ' || pg_temp.s(), 10))
              and not exists (select 1 from booking._order_company_hits('saunaseura ' || pg_temp.s() || '%', 10))
              and not exists (select 1 from booking._order_company_hits('saunaseura ' || left(pg_temp.s(), -1) || '_', 10)), 'B11 % ja _ eivät ole jokerimerkkejä');

-- ===== C Uusi varaus -haku (henkilökunta: staff-rooli riittää, _require_staff)
select pg_temp.ck(pg_temp.names(pg_temp.sc(pg_temp.uid('u_staff'), 'saunaseura ' || pg_temp.s()), 'company') = array['Saunaseura ' || pg_temp.s() || ' Oy'], 'C1 yritys nimellä (staff-rooli)');
select pg_temp.ck((select count(*) = 1 and bool_and(e ->> 'source' = 'orders' and e ->> 'customer_kind' = 'company' and e ->> 'business_id' = pg_temp.b('bA')
                     and e ->> 'street' = 'Uusi katu 5' and e ->> 'zip' = '00210' and e ->> 'einvoice_operator' = 'E204503'
                     and e ->> 'name' = 'Pekka ' || pg_temp.s() || 'yhteys' and (e -> 'id') = 'null'::jsonb and (e ->> 'customer_id')::bigint = pg_temp.id('c_pekka'))
                     from jsonb_array_elements(pg_temp.sc(pg_temp.uid('u_mgr'), pg_temp.b('bA'))) e), 'C2 y-tunnuksella väliviivalla: lähde orders, id null, yritystiedot');
select pg_temp.ck((select count(*) = 1 and bool_and((e ->> 'customer_id')::bigint = pg_temp.id('c_pekka'))
                     from jsonb_array_elements(pg_temp.sc(pg_temp.uid('u_mgr'), replace(pg_temp.b('bA'), '-', ''))) e), 'C3a y-tunnus ilman väliviivaa');
select pg_temp.ck(jsonb_array_length(pg_temp.sc(pg_temp.uid('u_mgr'), replace(pg_temp.b('bA'), '-', ' '))) = 1, 'C3b y-tunnus välilyönnillä');
select pg_temp.ck(pg_temp.names(pg_temp.sc(pg_temp.uid('u_mgr'), 'pekka ' || pg_temp.s()), 'source') = array['customer', 'orders'], 'C4 yhteyshenkilön nimellä: henkilö + yritys');
select pg_temp.ck(pg_temp.names(pg_temp.sc(pg_temp.uid('u_mgr'), 'rekisteriyhtiö ' || pg_temp.s()), 'source') = array['customer'], 'C5 rekisterin yritys ei tuplana (sama y-tunnus)');
select pg_temp.ck((select count(*) = 1 and bool_and(e ->> 'business_id' = pg_temp.b('bR') and e ->> 'street' = 'Rekisterikatu 1' and e ->> 'source' = 'customer')
                     from jsonb_array_elements(pg_temp.sc(pg_temp.uid('u_mgr'), pg_temp.b('bR'))) e), 'C6 rekisterin yritys y-tunnuksella, osoite mukana');
select pg_temp.ck(pg_temp.names(pg_temp.sc(pg_temp.uid('u_mgr'), 'henkilö ' || pg_temp.s()), 'source') = array['customer'], 'C7 henkilöhaku kuten ennen');
select pg_temp.ck(pg_temp.sc(pg_temp.uid('u_mgr'), 'piilotettu ' || pg_temp.s()) = '[]'::jsonb and pg_temp.sc(pg_temp.uid('u_mgr'), pg_temp.b('bP')) = '[]'::jsonb
              and pg_temp.sc(pg_temp.uid('u_mgr'), 'anni ' || pg_temp.s()) = '[]'::jsonb, 'C8 anonymisoitu ei näy (yritys, y-tunnus, henkilö)');
select pg_temp.ck(pg_temp.sc(pg_temp.uid('u_mgr'), 'k') = '[]'::jsonb, 'C9 1 merkki → []');
select pg_temp.ck(pg_temp.names(pg_temp.sc(pg_temp.uid('u_mgr'), 'kioski ' || pg_temp.s()), 'company') = array['Nimetön Kioski ' || pg_temp.s() || ' Ky'], 'C10 y-tunnukseton yritys nimellä');

-- ===== D Uusi lasku -haku (manager: invoices.manage)
select pg_temp.ck((select count(*) = 1 and bool_and(e ->> 'source' = 'booking' and e ->> 'origin' = 'orders' and e ->> 'company_name' = 'Saunaseura ' || pg_temp.s() || ' Oy'
                     and e ->> 'business_id' = pg_temp.b('bA') and e ->> 'einvoice_address' = '003799999999' and e ->> 'einvoice_operator' = 'E204503'
                     and e ->> 'contact_name' = 'Pekka ' || pg_temp.s() || 'yhteys' and e ->> 'street' = 'Uusi katu 5'
                     and (e ->> 'customer_id')::bigint = pg_temp.id('c_pekka') and (e -> 'buyer_reference') = 'null'::jsonb)
                     from jsonb_array_elements(pg_temp.si(pg_temp.uid('u_mgr'), 'saunaseura ' || pg_temp.s())) e), 'D1 laskun haku: yritys tilauksilta, verkkolasku täytettäväksi');
select pg_temp.ck(pg_temp.names(pg_temp.si(pg_temp.uid('u_mgr'), pg_temp.b('bA')), 'origin') = array['orders'], 'D2a y-tunnus väliviivalla');
select pg_temp.ck(pg_temp.names(pg_temp.si(pg_temp.uid('u_mgr'), replace(pg_temp.b('bA'), '-', '')), 'origin') = array['orders'], 'D2b y-tunnus ilman väliviivaa');
select pg_temp.ck(pg_temp.names(pg_temp.si(pg_temp.uid('u_mgr'), 'pekka ' || pg_temp.s()), 'origin') = array['orders', null], 'D3 yhteyshenkilö: yritys ennen henkilöä');
select pg_temp.ck(pg_temp.names(pg_temp.si(pg_temp.uid('u_mgr'), 'laskutusasiakas ' || pg_temp.s()), 'source') = array['invoice'], 'D4 laskutusasiakas kuten ennen');
select pg_temp.ck(pg_temp.si(pg_temp.uid('u_mgr'), 'piilotettu ' || pg_temp.s()) = '[]'::jsonb and pg_temp.si(pg_temp.uid('u_mgr'), pg_temp.b('bP')) = '[]'::jsonb, 'D8 anonymisoitu ei näy laskun haussa');
select pg_temp.ck(pg_temp.names(pg_temp.si(pg_temp.uid('u_mgr'), 'rekisteriyhtiö ' || pg_temp.s()), 'source') = array['booking']
              and pg_temp.names(pg_temp.si(pg_temp.uid('u_mgr'), 'rekisteriyhtiö ' || pg_temp.s()), 'origin') = array[null], 'D6 rekisterin yritys ei tuplana');
select pg_temp.ck(jsonb_array_length(pg_temp.si(pg_temp.uid('u_mgr'), pg_temp.s(), 2)) = 2 and jsonb_array_length(pg_temp.si(pg_temp.uid('u_mgr'), pg_temp.s(), 10)) > 2, 'D7 raja p_limit pätee');
insert into booking.invoice_customers(company_name, business_id, customer_id) values ('Saunaseura ' || pg_temp.s() || ' Oy', pg_temp.b('bA'), pg_temp.id('c_pekka'));
select pg_temp.ck(pg_temp.names(pg_temp.si(pg_temp.uid('u_mgr'), 'saunaseura ' || pg_temp.s()), 'source') = array['invoice'], 'D5 tallennettu laskutusasiakas korvaa tilausrivin (ei tuplaa)');

-- ===== E oikeudet (SQLSTATE BK001 + DETAIL forbidden; anon: 42501 ei EXECUTE-oikeutta)
select pg_temp.ck((select j ->> 'state' = 'BK001' and j ->> 'err' = 'forbidden' from pg_temp.as_(pg_temp.uid('u_staff'), $$select booking.admin_search_invoice_customers('saunaseura', 10)$$) j),
                  'E1 laskuhaku vaatii invoices.manage (staff-rooli → forbidden)');
select pg_temp.ck((select j ->> 'state' = 'BK001' and j ->> 'err' = 'forbidden' from pg_temp.as_(pg_temp.uid('u_none'), $$select booking.admin_search_customers('saunaseura', 8)$$) j),
                  'E2 varaushaku vaatii henkilökunnan (kirjautunut ei-henkilökunta → forbidden)');
select pg_temp.ck((select j ->> 'state' = 'BK001' and j ->> 'err' = 'forbidden' from pg_temp.as_(pg_temp.uid('u_none'), $$select booking.admin_search_invoice_customers('saunaseura', 10)$$) j),
                  'E3 laskuhaku: ei-henkilökunta → forbidden');
select pg_temp.ck((select j ->> 'state' = 'BK001' and j ->> 'err' = 'forbidden' from pg_temp.as_(pg_temp.uid('u_none'), $$select count(*) from booking.admin_list_customers('saunaseura', 5, 0)$$) j),
                  'E4 asiakaslista: ei-henkilökunta → forbidden');
select pg_temp.ck((select j ->> 'state' = '42501' from pg_temp.as_(null, $$select booking.admin_search_customers('saunaseura', 8)$$) j), 'E5 anon: ei EXECUTE-oikeutta (42501)');
select pg_temp.ck((select j ? 'r' and not j ? 'err' from pg_temp.as_(pg_temp.uid('u_mgr'), $$select booking.admin_search_customers('zz', 8)$$) j), 'E6 manager: varaushaku sallittu');

-- ===== G Asiakkaat-lista (admin_list_customers) ennallaan: hakee vain rekisteristä
select pg_temp.ck(pg_temp.lc(pg_temp.uid('u_mgr'), 'saunaseura ' || pg_temp.s()) = '[]'::jsonb and pg_temp.lc(pg_temp.uid('u_mgr'), pg_temp.b('bA')) = '[]'::jsonb,
                  'G1 tilauksen yritys ei näy Asiakkaat-listassa (ennallaan)');
select pg_temp.ck((select count(*) = 1 and bool_and((e ->> 'id')::bigint = pg_temp.id('c_pekka') and e ->> 'customer_kind' = 'private')
                     from jsonb_array_elements(pg_temp.lc(pg_temp.uid('u_mgr'), 'pekka ' || pg_temp.s())) e), 'G2 yhteyshenkilö yksityisenä kuten ennen');
select pg_temp.ck((select count(*) = 1 and bool_and((e ->> 'id')::bigint = pg_temp.id('c_rauno') and e ->> 'business_id' = pg_temp.b('bR'))
                     from jsonb_array_elements(pg_temp.lc(pg_temp.uid('u_mgr'), pg_temp.b('bR'))) e), 'G3 rekisterin yritys y-tunnuksella');
select pg_temp.ck(pg_temp.lc(pg_temp.uid('u_mgr'), 'anni ' || pg_temp.s()) = '[]'::jsonb, 'G4 anonymisoitu ei näy');
select pg_temp.ck((select array_agg((e ->> 'id')::bigint order by (e ->> 'id')::bigint) from jsonb_array_elements(pg_temp.lc(pg_temp.uid('u_mgr'), pg_temp.s())) e)
                  = (select array_agg(id order by id) from t172_fx where k in ('c_pekka', 'c_tiina', 'c_rauno', 'c_henkilo')), 'G5 tunnisteella vain fixture-asiakkaat (ei anonymisoitua)');

select label, ok from t172_r order by label;
do $$ declare p int; f int; begin
  select count(*) filter (where ok), count(*) filter (where not ok) into p, f from t172_r;
  raise exception 'TESTRESULT pass=% fail=%', p, f;
end $$;
rollback;

-- ===== Z ROLLBACKin jälkeen: yhtään testiriviä ei jäänyt (pelkkiä SELECTejä)
select 't172 leftover rows = ' || (
    (select count(*) from booking.customers where email like '%' || :'sfx' || '%' or name like '%' || :'sfx' || '%')
  + (select count(*) from booking.orders where external_id like 't172-' || :'sfx' || '%' or billing::text like '%' || :'sfx' || '%')
  + (select count(*) from booking.invoice_customers where company_name like '%' || :'sfx' || '%' or email like '%' || :'sfx' || '%')
  + (select count(*) from booking.staff where email like '%' || :'sfx' || '%')
  + (select count(*) from auth.users where email like '%' || :'sfx' || '%')
  + (select count(*) from booking.audit_log where new_data::text like '%' || :'sfx' || '%')) as leftover;
