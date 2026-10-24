-- t172: yritysasiakkaat löytyvät Uusi varaus- ja Uusi lasku -hausta (booking_172, tuotannossa versio 20261024222000).
-- A rakenne, md5 ja oikeudet, B tilausten yritykset (_order_company_hits), C Uusi varaus -haku (admin_search_customers),
-- D Uusi lasku -haku (admin_search_invoice_customers), E oikeudet (forbidden), F vartija (väärä md5 → keskeytys, ei muutoksia).
-- Ajo paikallisessa PG17:ssä migraation jälkeen (pohja: tuotannon tarkat funktiomäärittelyt + minimitaulut, ks. raportti):
--   psql -X -v ON_ERROR_STOP=0 -f t172_company_customer_search.sql
-- Kaikki yhdessä transaktiossa; lopussa tahallinen poikkeus "TESTRESULT pass=… fail=…" kumoaa kaiken. Data feikkiä (@example.test).
begin;
set local lock_timeout = '3s';
create temp table t172_r(ok boolean, label text);
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t172_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.names(j jsonb, k text) returns text[] language sql as $$ select coalesce(array_agg(e ->> k order by o), '{}') from jsonb_array_elements(j) with ordinality x(e, o) $$;

-- ===== A rakenne
select pg_temp.ck(md5(pg_get_functiondef('booking.admin_search_invoice_customers(text,integer)'::regprocedure)) = '0b6a95a0bb492fe96632c719ff72e42c', 'A1 admin_search_invoice_customers = booking_172');
select pg_temp.ck(md5(pg_get_functiondef('booking.admin_search_customers(text,integer)'::regprocedure)) = '6ab4f8a588a792ca3af0614a20ceb659', 'A2 admin_search_customers md5');
select pg_temp.ck(md5(pg_get_functiondef('booking._order_company_hits(text,integer)'::regprocedure)) = '007c407a3fb71e6ee9098796ca34f57c', 'A3 _order_company_hits md5');
select pg_temp.ck(md5(pg_get_functiondef('booking.admin_list_customers(text,integer,integer)'::regprocedure)) = '1ffba8df04ac14a996400bc97182ec21', 'A4 admin_list_customers ennallaan');
select pg_temp.ck(has_function_privilege('authenticated', 'booking.admin_search_customers(text,integer)', 'execute'), 'A5 authenticated saa kutsua admin_search_customers');
select pg_temp.ck(not has_function_privilege('anon', 'booking.admin_search_customers(text,integer)', 'execute'), 'A6 anon ei admin_search_customers');
select pg_temp.ck(not has_function_privilege('authenticated', 'booking._order_company_hits(text,integer)', 'execute')
              and not has_function_privilege('anon', 'booking._order_company_hits(text,integer)', 'execute'), 'A7 _order_company_hits ei suoraan kutsuttavissa');

-- ===== fixture (feikki): Johku-yhteyshenkilö yksityisenä + yritystilaukset, rekisterin yritys, nimetön (ei y-tunnusta), anonymisoitu, henkilö
insert into booking.customers(id, name, email, phone, customer_kind, external_source) values
  (9001, 'Pekka Yhteyshenkilö', 'pekka@example.test', '0401110001', 'private', 'johku'),
  (9002, 'Tiina Tilaaja', 'tiina@example.test', null, 'private', 'johku'),
  (9003, 'Anni Anonyymi', 'anni@example.test', null, 'private', 'johku'),
  (9005, 'Henkilö Testinen', 'henkilo@example.test', '0401110005', 'private', null);
insert into booking.customers(id, name, email, customer_kind, company, business_id, address, zip, city, einvoice_address, einvoice_operator) values
  (9004, 'Rauno Rekisteri', 'rauno@example.test', 'company', 'Rekisteriyhtiö Oy', '1234562-0', 'Rekisterikatu 1', '00100', 'Helsinki', null, null);
update booking.customers set anonymized_at = now() where id = 9003;
insert into booking.orders(customer_id, customer_kind, billing, external_source, created_at) values
  (9001, 'company', '{"company":"Saunaseura Testi Oy","business_id":"1234560-4","name":"Pekka Yhteyshenkilö","email":"laskut@saunaseura.example.test","address":"Vanha tie 1","zip":"00200","city":"Espoo","country":"FI"}', 'johku', now() - interval '200 days'),
  (9001, 'company', '{"company":"Saunaseura Testi Oy","business_id":"12345604","name":"Pekka Yhteyshenkilö","email":"laskut@saunaseura.example.test","address":"Uusi katu 5","zip":"00210","city":"Helsinki","country":"FI","einvoice_address":"003712345604","einvoice_operator":"e204503"}', 'johku', now() - interval '20 days'),
  (9002, 'company', '{"company":"Nimetön Kioski Ky","name":"Tiina Tilaaja","address":"Torikatu 3","zip":"33100","city":"Tampere"}', 'johku', now() - interval '50 days'),
  (9003, 'company', '{"company":"Piilotettu Oy","business_id":"1234561-2","name":"Anni Anonyymi"}', 'johku', now() - interval '10 days'),
  (9004, 'company', '{"company":"Rekisteriyhtiö Oy","business_id":"1234562-0","name":"Rauno Rekisteri"}', null, now() - interval '5 days'),
  (9005, 'private', null, null, now() - interval '3 days');
insert into booking.invoice_customers(company_name, business_id, email) values ('Laskutusasiakas Oy', '1234563-9', 'lasku@example.test');

-- ===== B _order_company_hits
select pg_temp.ck((select count(*) from booking._order_company_hits('saunaseura', 10)) = 1, 'B1 kaksi tilausta samalle y-tunnukselle → yksi yritys');
select pg_temp.ck((select h.street = 'Uusi katu 5' and h.city = 'Helsinki' and h.einvoice_address = '003712345604' and h.einvoice_operator = 'E204503'
                     and h.business_id = '1234560-4' and h.orders_count = 2 and h.customer_id = 9001 and h.contact_name = 'Pekka Yhteyshenkilö'
                     and h.email = 'laskut@saunaseura.example.test'
                     from booking._order_company_hits('saunaseura', 10) h), 'B2 uusimman tilauksen tiedot, verkkolasku normalisoitu, yhteyshenkilö');
select pg_temp.ck((select count(*) from booking._order_company_hits('1234560-4', 10)) = 1, 'B3 y-tunnus väliviivalla');
select pg_temp.ck((select count(*) from booking._order_company_hits('12345604', 10)) = 1, 'B4 y-tunnus ilman väliviivaa');
select pg_temp.ck((select count(*) from booking._order_company_hits('Yhteyshenk', 10)) = 1, 'B5 yhteyshenkilön nimellä');
select pg_temp.ck((select count(*) from booking._order_company_hits('laskut@saunaseura', 10)) = 1, 'B6 laskutussähköpostilla');
select pg_temp.ck((select count(*) from booking._order_company_hits('pekka@example', 10)) = 1, 'B7 yhteyshenkilön rekisterisähköpostilla');
select pg_temp.ck((select h.business_id is null and h.company = 'Nimetön Kioski Ky' and h.company_key = 'n:nimetön kioski ky' from booking._order_company_hits('kioski', 10) h), 'B8 yritys ilman y-tunnusta');
select pg_temp.ck(not exists (select 1 from booking._order_company_hits('piilotettu', 10)), 'B9 anonymisoidun asiakkaan yritys ei näy');
select pg_temp.ck(not exists (select 1 from booking._order_company_hits('S', 10)) and not exists (select 1 from booking._order_company_hits(null, 10)), 'B10 alle 2 merkkiä → ei osumia');
select pg_temp.ck(not exists (select 1 from booking._order_company_hits('100%', 10)) and not exists (select 1 from booking._order_company_hits('__', 10)), 'B11 % ja _ eivät ole jokerimerkkejä');

-- ===== C Uusi varaus -haku (staff)
select set_config('t.staff', '1', true);
select pg_temp.ck(pg_temp.names(booking.admin_search_customers('saunaseura', 8), 'company') = array['Saunaseura Testi Oy'], 'C1 yritys nimellä (aiemmin 0 osumaa)');
select pg_temp.ck((select e ->> 'source' = 'orders' and e ->> 'customer_kind' = 'company' and e ->> 'business_id' = '1234560-4' and e ->> 'street' = 'Uusi katu 5'
                     and e ->> 'zip' = '00210' and e ->> 'einvoice_operator' = 'E204503' and e ->> 'name' = 'Pekka Yhteyshenkilö' and (e -> 'id') = 'null'::jsonb
                     and (e ->> 'customer_id')::bigint = 9001
                     from jsonb_array_elements(booking.admin_search_customers('1234560-4', 8)) e), 'C2 y-tunnuksella: lähde orders, id null, yritystiedot täytettäviksi');
select pg_temp.ck(jsonb_array_length(booking.admin_search_customers('1234560 4', 8)) = 1, 'C3 y-tunnus välilyönnillä');
select pg_temp.ck(pg_temp.names(booking.admin_search_customers('Pekka', 8), 'source') = array['customer', 'orders'], 'C4 yhteyshenkilön nimellä: henkilö + yritys');
select pg_temp.ck(pg_temp.names(booking.admin_search_customers('rekisteriyhtiö', 8), 'source') = array['customer'], 'C5 rekisterin yritys ei tuplana (sama y-tunnus)');
select pg_temp.ck((select e ->> 'business_id' = '1234562-0' and e ->> 'street' = 'Rekisterikatu 1' from jsonb_array_elements(booking.admin_search_customers('1234562-0', 8)) e), 'C6 rekisterin yritys y-tunnuksella, osoite mukana');
select pg_temp.ck(pg_temp.names(booking.admin_search_customers('Testinen', 8), 'source') = array['customer'], 'C7 henkilöhaku kuten ennen');
select pg_temp.ck(jsonb_array_length(booking.admin_search_customers('piilotettu', 8)) = 0, 'C8 anonymisoitu ei näy');
select pg_temp.ck(booking.admin_search_customers('k', 8) = '[]'::jsonb, 'C9 1 merkki → []');
select pg_temp.ck(pg_temp.names(booking.admin_search_customers('kioski', 8), 'company') = array['Nimetön Kioski Ky'], 'C10 y-tunnukseton yritys nimellä');

-- ===== D Uusi lasku -haku (invoices.manage)
select set_config('t.perm', 'invoices.manage', true);
select pg_temp.ck((select e ->> 'source' = 'booking' and e ->> 'origin' = 'orders' and e ->> 'company_name' = 'Saunaseura Testi Oy' and e ->> 'business_id' = '1234560-4'
                     and e ->> 'einvoice_address' = '003712345604' and e ->> 'einvoice_operator' = 'E204503' and e ->> 'contact_name' = 'Pekka Yhteyshenkilö'
                     and e ->> 'street' = 'Uusi katu 5' and (e ->> 'customer_id')::bigint = 9001 and (e -> 'buyer_reference') = 'null'::jsonb
                     from jsonb_array_elements(booking.admin_search_invoice_customers('saunaseura', 10)) e), 'D1 laskun haku: yritys tilauksilta, verkkolasku täytettäväksi');
select pg_temp.ck(jsonb_array_length(booking.admin_search_invoice_customers('12345604', 10)) = 1, 'D2 y-tunnus ilman väliviivaa');
select pg_temp.ck(pg_temp.names(booking.admin_search_invoice_customers('Pekka', 10), 'origin') = array['orders', null], 'D3 yhteyshenkilö: yritys ennen henkilöä');
select pg_temp.ck(pg_temp.names(booking.admin_search_invoice_customers('Laskutusasiakas', 10), 'source') = array['invoice'], 'D4 laskutusasiakas kuten ennen');
insert into booking.invoice_customers(company_name, business_id, customer_id) values ('Saunaseura Testi Oy', '1234560-4', 9001);
select pg_temp.ck(pg_temp.names(booking.admin_search_invoice_customers('saunaseura', 10), 'source') = array['invoice'], 'D5 tallennettu laskutusasiakas korvaa tilausrivin (ei tuplaa)');
select pg_temp.ck(pg_temp.names(booking.admin_search_invoice_customers('rekisteriyhtiö', 10), 'source') = array['booking'] and pg_temp.names(booking.admin_search_invoice_customers('rekisteriyhtiö', 10), 'origin') = array[null], 'D6 rekisterin yritys ei tuplana');
select pg_temp.ck(jsonb_array_length(booking.admin_search_invoice_customers('kioski', 1)) = 1 and jsonb_array_length(booking.admin_search_invoice_customers('e', 2)) <= 2, 'D7 raja p_limit pätee');

-- ===== E oikeudet
select set_config('t.perm', '', true);
do $$ begin perform booking.admin_search_invoice_customers('saunaseura', 10); insert into t172_r values (false, 'E1 laskuhaku vaatii invoices.manage');
exception when others then insert into t172_r values (sqlerrm like '%invoices.manage%', 'E1 laskuhaku vaatii invoices.manage'); end $$;
select set_config('t.staff', '', true);
do $$ begin perform booking.admin_search_customers('saunaseura', 8); insert into t172_r values (false, 'E2 varaushaku vaatii henkilökunnan');
exception when others then insert into t172_r values (sqlerrm = 'Ei oikeuksia', 'E2 varaushaku vaatii henkilökunnan'); end $$;

-- ===== F vartija: väärä md5 → migraatio keskeytyy (testataan vartijalohko suoraan)
create or replace function booking.admin_search_customers(p_search text default null, p_limit integer default 8) returns jsonb language sql as $x$ select '[]'::jsonb $x$;
do $$ declare v text; begin
  v := md5(pg_get_functiondef('booking.admin_search_customers(text,integer)'::regprocedure));
  insert into t172_r values (v <> '6ab4f8a588a792ca3af0614a20ceb659', 'F1 muokattu funktio tunnistetaan (md5 ' || v || ')');
end $$;

select label, ok from t172_r order by label;
do $$ declare p int; f int; begin
  select count(*) filter (where ok), count(*) filter (where not ok) into p, f from t172_r;
  raise exception 'TESTRESULT pass=% fail=%', p, f;
end $$;
