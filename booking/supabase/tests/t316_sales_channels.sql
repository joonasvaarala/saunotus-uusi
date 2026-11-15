-- DISPOSABLE LOCAL DATABASE ONLY (rollback-only). booking_316: myyntikanavat datana + tuotekohtainen monivalinta.
-- Ajo (hakemistosta booking/supabase/tests, kanta = migraatiot ennen booking_316:ta):
--   psql -X -v ON_ERROR_STOP=1 -f t316_sales_channels.sql      → tulostaa TESTRESULT pass=N fail=0; kaikki muutokset perutaan.
-- Tarkistaa: backfill = PRODin 15.11. tila (synteettinen kopio), julkisten funktioiden/kassojen tulos sama ennen ja jälkeen,
-- rollback palauttaa PRODin md5:t ja saman tuloksen, uudelleenajo, synkka molempiin suuntiin, suora API estyy, oikeudet ja RLS.
\set ON_ERROR_STOP 1
begin;
set local check_function_bodies = off;
create temp table t316_res(n serial, ok boolean, label text);
create function pg_temp.ck(ok boolean, label text) returns void language plpgsql as $$begin
  insert into t316_res(ok, label) values (coalesce(ok, false), label);
  raise notice '%: %', case when ok then 'PASS' else 'FAIL' end, label;
end$$;
create function pg_temp.errcode(sql text) returns text language plpgsql as $$
declare d text; begin execute sql; return null; exception when sqlstate 'BK001' then get stacked diagnostics d = pg_exception_detail; return coalesce(d, 'BK001'); end$$;

-- ---------- 0) paikallinen kanta → PRODin 15.11. määrittely _public_create_training_signup_impl:lle (booking_254-kommentti) ----------
do $al$
declare d text := pg_get_functiondef('booking._public_create_training_signup_impl(bigint,date,text,text,text,text,text,text,text,boolean,boolean,text[])'::regprocedure);
begin
  if md5(d) <> 'd5017b23bde3ff427459c77caea0b807' then
    d := replace(d, E'    for v_sid in\n      select s.rule_id from booking._training_segments_of(p_rule_id) s\n       where s.rule_id is distinct from p_rule_id\n       order by s.rule_id\n    loop\n      perform booking._training_hold_segment(v_order, v_sid, v_hold_at);\n    end loop;\n',
                    E'    -- booking_254: _create_booking_core now holds the segments for every channel.\n');
    d := regexp_replace(d, E'\n\n(\\$function\\$)', E'\n\\1');
    execute d;
  end if;
end $al$;
select pg_temp.ck(md5(pg_get_functiondef('booking._public_create_training_signup_impl(bigint,date,text,text,text,text,text,text,text,boolean,boolean,text[])'::regprocedure)) = 'd5017b23bde3ff427459c77caea0b807', 'training_signup_impl = PROD md5');

-- ---------- 1) PRODin 15.11. tuotetila (synteettinen kopio; puuttuvat tuotteet kopioidaan) ----------
set local session_replication_role = replica;
insert into kb.products overriding system value select (jsonb_populate_record(null::kb.products, to_jsonb(p) || jsonb_build_object('id', x.nid, 'slug', p.slug || '-t316-' || x.nid))).*
  from kb.products p join (values (82, 47), (113, 9), (114, 36), (115, 36), (116, 36), (117, 36), (118, 36), (119, 36), (120, 36), (121, 36)) x(nid, src) on p.id = x.src
 where not exists (select 1 from kb.products q where q.id = x.nid);
insert into booking.product_config select (jsonb_populate_record(null::booking.product_config, to_jsonb(c) || jsonb_build_object('product_id', x.nid))).*
  from booking.product_config c join (values (82, 47), (113, 9), (114, 36), (115, 36), (116, 36), (117, 36), (118, 36), (119, 36), (120, 36), (121, 36)) x(nid, src) on c.product_id = x.src
 where not exists (select 1 from booking.product_config q where q.product_id = x.nid);
update kb.products set active = true where id in (82, 113, 114, 115, 116, 117, 118, 119, 120, 121);
update booking.product_config pc set bookable = s.b, lifecycle = s.l, shop_visible = s.sv, channels = s.ch, fridge_sale = s.fr, pos_enabled = s.pos, age_restricted = false
  from (values
   (1,true,'current',true,null::text[],false,false),(2,true,'current',true,null,false,false),(3,true,'current',true,null,false,false),(4,true,'current',true,null,false,false),
   (5,true,'current',true,null,false,false),(6,true,'current',true,null,false,false),(7,true,'current',true,null,false,false),(8,true,'current',true,null,false,false),
   (9,true,'current',true,null,false,false),(10,true,'current',true,null,false,false),(11,true,'current',true,null,false,false),(12,true,'current',true,null,false,false),
   (13,true,'old',false,null,false,false),(24,true,'current',true,null,false,false),(25,true,'current',true,null,false,false),(26,true,'current',true,null,false,false),
   (27,false,'current',false,null,false,false),(28,false,'current',false,null,false,false),(29,false,'current',false,null,false,false),(30,false,'current',false,null,false,false),
   (31,true,'current',true,null,false,false),(32,true,'current',true,null,false,false),(33,true,'current',true,null,false,false),(34,true,'current',true,null,false,false),
   (35,false,'old',false,null,false,false),(36,false,'current',false,null,false,false),(37,false,'old',false,null,false,false),
   (38,false,'current',false,null,false,false),(39,false,'current',false,null,false,false),(40,false,'current',false,null,false,false),(41,false,'current',false,null,false,false),(42,false,'current',false,null,false,false),
   (43,true,'current',true,null,false,false),(44,false,'current',false,null,false,true),(45,false,'current',false,null,false,true),(46,false,'current',false,null,false,true),(47,false,'current',false,null,false,false),
   (48,true,'current',true,null,false,false),(49,true,'current',true,null,false,false),(50,false,'current',false,null,false,false),
   (82,false,'current',false,null,true,true),(113,true,'current',true,null,false,false),
   (114,true,'current',false,array['link'],false,false),(115,true,'current',false,array['link'],false,false),(116,true,'current',false,array['link'],false,false),
   (117,true,'current',false,array['link'],false,false),(118,true,'current',false,array['link'],false,false),(119,true,'current',false,array['link'],false,false),
   (120,true,'current',false,array['link'],false,false),(121,true,'current',true,array['link'],true,false)
  ) s(id,b,l,sv,ch,fr,pos) where pc.product_id = s.id;
update booking.product_config set bookable = true, lifecycle = 'old', shop_visible = false, channels = null where product_id between 14 and 23;
insert into booking.schedule_rules overriding system value select (jsonb_populate_record(null::booking.schedule_rules, to_jsonb(r) || jsonb_build_object('id', 90000 + x.pid, 'product_id', x.pid, 'kind', 'event',
         'valid_from', current_date + 20, 'valid_to', current_date + 20, 'weekdays', jsonb_build_array(extract(isodow from current_date + 20)::int), 'active', true, 'training_segment_only', false))).*
  from booking.schedule_rules r cross join (values (113), (114), (121)) x(pid) where r.id = 1;
-- (PRODissa koulutuksilla 35–37 ei ole yhtään vuorosääntöä 15.11.; koulutuksen 36 tapahtumakerta lisätään vasta kohdassa 5)
insert into booking.product_qr(code, product_id, label, active) values ('a316a316a316a316a316a316a316a082', 82, 'T316', true), ('a316a316a316a316a316a316a316a121', 121, 'T316', true);
set local session_replication_role = origin;
update booking.settings set value = 'true'::jsonb where key in ('events.sale_enabled', 'gift_cards.sale_enabled');

-- ---------- 2) tilannekuva julkisista funktioista ja kassoista ----------
create temp table t316_snap(phase text, k text, v text);
create function pg_temp.snap(p_phase text) returns void language plpgsql as $$
declare r record; v text;
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  insert into t316_snap values (p_phase, 'catalog', booking.public_catalog()::text);
  insert into t316_snap select p_phase, 'events:' || c, booking.public_events(current_date, c)::text from unnest(array['shop', 'widget']) c;
  insert into t316_snap values (p_phase, 'events:null', booking.public_events(current_date, null)::text);
  for r in select id from kb.products order by id loop
    insert into t316_snap select p_phase, 'avail:' || r.id, coalesce(jsonb_agg(to_jsonb(a) order by a.starts_at, a.rule_id)::text, '[]')
      from booking.public_availability(r.id, current_date, current_date + 30) a;
  end loop;
  insert into t316_snap select p_phase, 'avail_all:' || aud, coalesce(jsonb_agg(to_jsonb(a) order by a.product_id, a.starts_at, a.rule_id)::text, '[]')
    from unnest(array['consumer', 'business']) aud cross join lateral booking.public_availability_all(current_date, current_date + 30, aud) a group by aud;
  for r in select slug from kb.products where slug is not null order by id loop
    insert into t316_snap values (p_phase, 'slug:' || r.slug, coalesce(booking.public_product_by_slug(r.slug)::text, 'null'));
  end loop;
  for r in select id, valid_from from booking.schedule_rules where id > 90000 loop
    insert into t316_snap values (p_phase, 'training_checkout:' || r.id, booking.public_training_checkout(r.id, r.valid_from)::text);
  end loop;
  insert into t316_snap values (p_phase, 'upsell', coalesce((select jsonb_agg(to_jsonb(u))::text from booking._upsell_options(array[1, 2, 25]::bigint[], '{}'::bigint[], current_date + 5, 2) u), '[]'));
  insert into t316_snap values (p_phase, 'gift_packages', booking.public_gift_card_packages()::text);
  insert into t316_snap select p_phase, 'drinks:' || c, booking.public_drinks_catalog(c)::text from unnest(array['a316a316a316a316a316a316a316a082', 'a316a316a316a316a316a316a316a121']) c;
  for r in select id from booking.schedule_rules where product_id = 1 and active order by id limit 2 loop
    insert into t316_snap values (p_phase, 'ritual:' || r.id, booking.public_ritual_addon(r.id, current_date + 7, 2)::text);
  end loop;
  insert into t316_snap values (p_phase, 'ritual_fit', coalesce(booking._ritual_addon_fit(date_trunc('hour', now()) + interval '7 days 2 hours', 2, true)::text, 'null'));
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-000000000316', 'role', 'authenticated')::text, true);
  insert into t316_snap values (p_phase, 'pos_catalog', booking.admin_pos_catalog()::text);
  perform set_config('request.jwt.claims', '', true);
end $$;
insert into auth.users(id, email) values ('00000000-0000-4000-8000-000000000316', 't316-manager@example.test');
insert into booking.staff(user_id, email, name, role) values ('00000000-0000-4000-8000-000000000316', 't316-manager@example.test', 'T316 manager', 'manager');
insert into auth.users(id, email) values ('00000000-0000-4000-8000-000000000317', 't316-staff@example.test');
insert into booking.staff(user_id, email, name, role) values ('00000000-0000-4000-8000-000000000317', 't316-staff@example.test', 'T316 staff', 'staff');
select pg_temp.snap('before');

-- ---------- 3) migraatio ----------
\ir ../migrations/20261115091122_booking_316_sales_channels.sql
create temp table t316_cnt as select count(*) n from booking.product_sales_channels;
select pg_temp.snap('after');
select pg_temp.ck(not exists (select 1 from t316_snap b join t316_snap a on a.k = b.k and a.phase = 'after' where b.phase = 'before' and a.v is distinct from b.v)
                  and (select count(*) from t316_snap where phase = 'before') = (select count(*) from t316_snap where phase = 'after'),
                  'migraatio: kaikkien julkisten funktioiden ja kassan tulos sama kuin ennen (' || (select count(*) from t316_snap where phase = 'before') || ' kutsua)');
select pg_temp.ck(jsonb_array_length((select v from t316_snap where phase = 'before' and k = 'catalog')::jsonb) >= 10
                  and (select count(*) from t316_snap where phase = 'before' and k like 'avail:%' and v <> '[]') >= 10
                  and (select v from t316_snap where phase = 'before' and k = 'events:shop') <> '[]'
                  and (select v from t316_snap where phase = 'before' and k = 'pos_catalog') <> '[]'
                  and (select v from t316_snap where phase = 'before' and k = 'upsell') <> '[]'
                  and (select v from t316_snap where phase = 'before' and k = 'drinks:a316a316a316a316a316a316a316a082')::jsonb -> 'products' <> '[]'
                  and (select count(*) from t316_snap where phase = 'before' and k like 'training_checkout:%' and v::jsonb ->> 'ok' = 'true') >= 1,
                  'tilannekuvassa on sisältöä (lista, saatavuus, tapahtumat, kassa, lisämyynti, kylmälaite, kurssikassa)');
select pg_temp.ck(string_agg(k, ',') is null, 'eroavat kutsut: ' || coalesce(string_agg(k, ','), '-'))
  from t316_snap b where phase = 'before' and exists (select 1 from t316_snap a where a.phase = 'after' and a.k = b.k and a.v is distinct from b.v);
select pg_temp.ck((select string_agg(code || ':' || public_booking, ',' order by sort_order) from booking.sales_channels)
                  = 'shop:true,widget:true,link:true,pos:false,qr:false,gift_shop:false', 'kuusi kanavaa, julkinen varaus vain shop/widget/link');
select pg_temp.ck((select array_agg(product_id order by product_id) from booking.product_sales_channels where channel_code = 'shop')
                  = array[1,2,3,4,5,6,7,8,9,10,11,12,24,25,26,31,32,33,34,43,48,49,113]::bigint[], 'backfill shop = shop_visible ja shop-kanava');
select pg_temp.ck((select array_agg(product_id order by product_id) from booking.product_sales_channels where channel_code = 'link')
                  = array[114,115,116,117,118,119,120,121]::bigint[], 'backfill link = koulutukset 114–121');
select pg_temp.ck((select array_agg(product_id order by product_id) from booking.product_sales_channels where channel_code = 'widget')
                  is null, 'backfill widget: ei yhtään (koulutukset 35–37 ovat bookable = false)');
select pg_temp.ck(not exists (select 1 from booking.product_sales_channels s join booking.product_config pc on pc.product_id = s.product_id
                               where s.channel_code in ('shop', 'widget', 'link') and not pc.bookable)
                  and not exists (select 1 from booking.product_sales_channels where product_id in (35, 36, 37)), 'backfill: julkinen kanava vain bookable-tuotteelle');
select pg_temp.ck((select array_agg(product_id order by product_id) from booking.product_sales_channels where channel_code = 'pos')
                  = array[44,45,46,82]::bigint[], 'backfill pos = pos_enabled');
select pg_temp.ck((select array_agg(product_id order by product_id) from booking.product_sales_channels where channel_code = 'qr')
                  = array[82,121]::bigint[], 'backfill qr = fridge_sale (myös 121)');
select pg_temp.ck((select array_agg(product_id order by product_id) from booking.product_sales_channels where channel_code = 'gift_shop')
                  = array[1,7,10,11,38,41,42]::bigint[], 'backfill gift_shop = pakettien tuotteet');
select pg_temp.ck(not exists (select 1 from booking.product_sales_channels where product_id = 13 or product_id between 14 and 23), 'vanha 13 ja passiiviset lisät 14–23 eivät ole missään kanavassa');
select pg_temp.ck((select relrowsecurity from pg_class where oid = 'booking.sales_channels'::regclass) and (select relrowsecurity from pg_class where oid = 'booking.product_sales_channels'::regclass), 'RLS päällä');
select pg_temp.ck(not has_table_privilege('anon', 'booking.product_sales_channels', 'select') and not has_table_privilege('anon', 'booking.sales_channels', 'select')
                  and not has_table_privilege('authenticated', 'booking.product_sales_channels', 'insert') and has_table_privilege('authenticated', 'booking.product_sales_channels', 'select'), 'taulujen oikeudet');
select pg_temp.ck(not has_function_privilege('anon', 'booking._in_channel(bigint,text)', 'execute') and not has_function_privilege('authenticated', 'booking._in_channel(bigint,text)', 'execute')
                  and not has_function_privilege('authenticated', 'booking._public_channel_ok(bigint)', 'execute') and not has_function_privilege('anon', 'booking._gc_package_in_shop(text)', 'execute')
                  and not has_function_privilege('anon', 'booking.admin_set_product_sales_channels(bigint,text[])', 'execute') and has_function_privilege('authenticated', 'booking.admin_set_product_sales_channels(bigint,text[])', 'execute')
                  and not has_function_privilege('anon', 'booking.admin_list_sales_channels()', 'execute'), 'funktioiden oikeudet');
select pg_temp.ck(has_function_privilege('anon', 'booking.public_catalog()', 'execute') and has_function_privilege('anon', 'booking.public_create_booking(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb,jsonb)', 'execute'), 'julkiset grantit säilyvät');

-- ---------- 4) rollback ja uudelleenajo ----------
savepoint before_rb;
\ir ../rollbacks/20261115091122_booking_316_ROLLBACK.sql
select pg_temp.ck(to_regclass('booking.sales_channels') is null and to_regclass('booking.product_sales_channels') is null and to_regprocedure('booking._in_channel(bigint,text)') is null
                  and not exists (select 1 from pg_trigger where tgname = 'zz_sales_channels_sync'), 'rollback: taulut, apufunktiot ja triggerit poistettu');
select pg_temp.ck(count(*) = 18, 'rollback: 18 funktiota PRODin md5:llä (' || count(*) || ')') from (values
  ('booking.public_join_waitlist(bigint,date,integer,text,text,text,text,boolean,boolean)','af0188264002fdb1b42bb22092fd94c6'),
  ('booking.public_catalog()','a14cb1f474b5858c47bafbb8d96091aa'),('booking.public_availability(bigint,date,date)','5e3634cd8c5e6e2cf8576acf15b02c2e'),
  ('booking.public_availability_all(date,date,text)','e0fece192800777e3a7554edc704ed07'),('booking.public_events(date,text)','32f88991275054c7aae90df0229708c5'),
  ('booking.public_training_checkout(bigint,date)','89398f45d01322cf4ffaa117bb4d9924'),('booking.public_product_by_slug(text)','630a9db6ab457b4c412bb368dcb4ae8d'),
  ('booking._upsell_options(bigint[],bigint[],date,integer,integer)','66abc9abd7ea2b4962e52db8ff14ceb9'),
  ('booking._public_create_booking_impl(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb)','2fb0e0c5d84feea78e7adb904676481a'),
  ('booking._public_create_booking_code_impl(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb,text)','786b3856991464fe118d2d6bc0b5826b'),
  ('booking._public_create_training_signup_impl(bigint,date,text,text,text,text,text,text,text,boolean,boolean,text[])','d5017b23bde3ff427459c77caea0b807'),
  ('booking.public_ritual_addon(bigint,date,integer)','aed97660d894b70129acfac243ecabbf'),('booking._ritual_addon_fit(timestamp with time zone,integer,boolean)','3201a2c1db7f0c8e7016c807f5f10446'),
  ('booking._counter_lines(jsonb,text)','ac50053b47c2b14d8c20034b0d62ffb1'),('booking.admin_pos_catalog()','3abd467f4f8aab624a90b48e60f356e0'),
  ('booking.public_drinks_catalog(text)','e7e507a766b7287ff03e794711ac6ace'),('booking.public_gift_card_packages()','3ac6c50c3af91a5f771db71ebd0f2d6f'),
  ('booking._public_buy_gift_card_impl(jsonb,text,text,text,boolean,text,text,text,text,text,text,text,text)','367323d3aab88fc78e552a7c1475fbc3')) x(sig, m)
 where md5(pg_get_functiondef(x.sig::regprocedure)) = x.m;
select pg_temp.snap('rollback');
select pg_temp.ck(not exists (select 1 from t316_snap b join t316_snap a on a.k = b.k and a.phase = 'rollback' where b.phase = 'before' and a.v is distinct from b.v), 'rollback: tulos sama kuin ennen migraatiota');
\ir ../migrations/20261115091122_booking_316_sales_channels.sql
select pg_temp.ck((select count(*) from booking.product_sales_channels) = (select n from t316_cnt) and (select n from t316_cnt) = 44, 'uudelleenajo rollbackin jälkeen onnistuu (' || (select n from t316_cnt) || ' kanavariviä)');
release savepoint before_rb;

-- RLS: kirjautunut ei-henkilökunta ei näe rivejä, henkilökunta näkee
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000003ff"}', true) is not null as x \gset
select (select count(*) from booking.product_sales_channels) + (select count(*) from booking.sales_channels) as rls_other \gset
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-000000000317"}', true) is not null as x \gset
select (select count(*) from booking.product_sales_channels) as rls_staff_psc, (select count(*) from booking.sales_channels) as rls_staff_sc \gset
reset role;
select set_config('request.jwt.claims', '', true) is not null as x \gset
select pg_temp.ck(:rls_other = 0, 'RLS: kirjautunut ei-henkilökunta ei näe rivejä');
select pg_temp.ck(:rls_staff_psc = (select n from t316_cnt) and :rls_staff_sc = 6, 'RLS: henkilökunta näkee rivit');

-- ---------- 5) hallinnan RPC:t, synkka ja suora API ----------
do $t$
declare x jsonb; e text; rid bigint; v jsonb; tok text;
begin
  -- oikeudet
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform pg_temp.ck(pg_temp.errcode('select booking.admin_list_sales_channels()') = 'forbidden', 'anon: admin_list_sales_channels estetty');
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-000000000317', 'role', 'authenticated')::text, true);
  perform pg_temp.ck(jsonb_array_length(booking.admin_list_sales_channels() -> 'channels') = 6, 'staff: kanavalista luettavissa');
  perform pg_temp.ck(pg_temp.errcode('select booking.admin_set_product_sales_channels(1, array[''shop''])') = 'forbidden', 'staff ilman catalog.edit: tallennus estetty');
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-000000000316', 'role', 'authenticated')::text, true);
  x := booking.admin_list_sales_channels();
  perform pg_temp.ck(x -> 'products' -> '121' = '["link", "qr"]'::jsonb and x -> 'products' -> '1' = '["shop", "gift_shop"]'::jsonb, 'admin_list_sales_channels: tuotteiden kanavat');
  perform pg_temp.ck(pg_temp.errcode('select booking.admin_set_product_sales_channels(1, array[''partner_x''])') = 'unknown_channel', 'tuntematon kanava hylätään');
  perform pg_temp.ck(pg_temp.errcode('select booking.admin_set_product_sales_channels(38, array[''pos'',''gift_shop''])') = 'not_counter_product', 'lahjakortti ei pikakassaan');
  perform pg_temp.ck(pg_temp.errcode('select booking.admin_set_product_sales_channels(999999, array[''shop''])') = 'not_found', 'tuntematon tuote');
  update booking.product_config set age_restricted = true where product_id = 45;
  perform pg_temp.ck(pg_temp.errcode('select booking.admin_set_product_sales_channels(45, array[''pos'',''qr''])') = 'age_restricted', 'ikäraja estää QR-myynnin');

  -- liitostaulu → vanhat kentät
  x := booking.admin_set_product_sales_channels(2, array['widget', 'pos']);
  perform pg_temp.ck(x -> 'channels' = '["widget", "pos"]'::jsonb, 'tallennus palauttaa kanavat');
  perform pg_temp.ck((select not shop_visible and channels = array['widget'] and pos_enabled and not fridge_sale from booking.product_config where product_id = 2), 'synkka: shop pois → shop_visible false, channels {widget}, pos_enabled true');
  x := booking.admin_set_product_sales_channels(2, array['shop', 'link', 'gift_shop']);
  perform pg_temp.ck((select shop_visible and channels = array['shop', 'link'] and not pos_enabled from booking.product_config where product_id = 2), 'synkka: shop+link → shop_visible true, channels {shop,link}, pos pois');
  x := booking.admin_set_product_sales_channels(3, array['shop']);
  perform pg_temp.ck((select shop_visible and channels is null from booking.product_config where product_id = 3), 'synkka: ennallaan oleva oletus jää null-arvoksi');
  x := booking.admin_set_product_sales_channels(121, array['link', 'qr']);
  perform pg_temp.ck((select shop_visible and fridge_sale from booking.product_config where product_id = 121), '121: muuttamaton tallennus ei koske shop_visibleen');
  x := booking.admin_set_product_sales_channels(82, array['pos']);
  perform pg_temp.ck((select not fridge_sale from booking.product_config where product_id = 82), 'synkka: qr pois → fridge_sale false');

  -- vanhat kentät → liitostaulu (nykyinen hallinta ja muut funktiot)
  perform booking.admin_update_product_config(4, '{"shop_visible": false}'::jsonb);
  perform pg_temp.ck(not booking._in_channel(4, 'shop') and booking._in_channel(4, 'gift_shop') is false, 'synkka: shop_visible false → shop pois');
  perform booking.admin_update_product_config(4, '{"shop_visible": true, "pos_enabled": true}'::jsonb);
  perform pg_temp.ck(booking._in_channel(4, 'shop') and booking._in_channel(4, 'pos'), 'synkka: shop_visible/pos_enabled true → shop ja pos');
  perform booking.admin_update_product_config(5, '{"bookable": false}'::jsonb);
  perform pg_temp.ck(not booking._in_channel(5, 'shop') and not booking.public_catalog() @> '[{"id": 5}]', 'vanha polku: bookable false → julkiset kanavat pois');
  perform booking.admin_update_product_config(5, '{"bookable": true}'::jsonb);
  perform pg_temp.ck(booking._in_channel(5, 'shop') and booking.public_catalog() @> '[{"id": 5}]', 'vanha polku: bookable true → kanavat vanhoista kentistä');
  perform booking.admin_update_product_config(1, '{"pos_sort": 5}'::jsonb);
  perform pg_temp.ck(booking._in_channel(1, 'gift_shop') and booking._in_channel(1, 'shop'), 'synkka ei koske gift_shopiin');

  -- suora API estyy
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  select id into rid from booking.schedule_rules where product_id = 13 and active limit 1;
  if rid is null then
    set local session_replication_role = replica;
    insert into booking.schedule_rules overriding system value select (jsonb_populate_record(null::booking.schedule_rules, to_jsonb(r) || jsonb_build_object('id', 90013, 'product_id', 13))).* from booking.schedule_rules r where r.id = 1;
    set local session_replication_role = origin;
    rid := 90013;
  end if;
  v := booking.public_create_booking(rid, current_date + 7, 2, 'T316 Testi', 't316@example.test', '+358401234567', false, 'fi', null, 'private', null, null);
  perform pg_temp.ck(v ->> 'code' = 'not_bookable', 'public_create_booking: tuote ilman julkista kanavaa → not_bookable (' || coalesce(v ->> 'code', v::text) || ')');
  v := booking.public_create_booking_code(rid, current_date + 7, 2, 'T316 Testi', 't316@example.test', '+358401234567', false, 'fi', null, 'private', null, null, 'KOODI316');
  perform pg_temp.ck(v ->> 'code' = 'not_bookable', 'public_create_booking_code: → not_bookable (' || coalesce(v ->> 'code', v::text) || ')');
  v := booking.public_create_booking_code(rid, current_date + 7, 2, 'T316 Testi', 't316@example.test', '+358401234567', false, 'fi', null, 'private', null, null, '');
  perform pg_temp.ck(v ->> 'code' = 'not_bookable', 'public_create_booking_code ilman koodia: → not_bookable');
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-000000000316', 'role', 'authenticated')::text, true);
  perform booking.admin_set_product_sales_channels(1, array[]::text[]);
  perform booking.admin_set_product_sales_channels(8, array[]::text[]);
  perform booking.admin_set_product_sales_channels(114, array[]::text[]);
  perform pg_temp.ck((select bookable and not shop_visible and channels = '{}' from booking.product_config where product_id = 114)
                     and (select bookable from booking.product_config where product_id = 1), 'julkisten kanavien poisto ei muuta bookablea (hallinnan varaukset toimivat)');
  -- jonoon liittyminen: täysi vuoro, tuote ilman julkista kanavaa → not_full (kuten ei-varattavalla tuotteella)
  insert into booking.resources(code, name, kind, capacity, parent_id) values ('t316_full', 'T316 täysi', 'capacity_pool', 1, (select min(id) from booking.resources where kind = 'space'));
  update booking.schedule_rules set min_persons = 2 where id in (90114, 90121);
  insert into booking.schedule_rule_pools(rule_id, pool_id) select x.rid, (select id from booking.resources where code = 't316_full') from (values (90114), (90121)) x(rid);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  v := booking.public_join_waitlist(90121, current_date + 20, 2, 'T316 Testi', 't316w@example.test', null, 'fi', false, true);
  perform pg_temp.ck((v ->> 'ok')::boolean, 'jono: koulutus 121 (Suora linkki) täysi → jonoon (' || coalesce(v ->> 'code', 'ok') || ')');
  v := booking.public_join_waitlist(90114, current_date + 20, 2, 'T316 Testi', 't316w@example.test', null, 'fi', false, true);
  perform pg_temp.ck(v ->> 'code' = 'not_full', 'jono: koulutus 114 ilman julkista kanavaa → not_full (' || coalesce(v ->> 'code', 'ok') || ')');
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-000000000316', 'role', 'authenticated')::text, true);
  perform booking.admin_set_product_sales_channels(82, array[]::text[]);
  perform booking.admin_set_product_sales_channels(44, array[]::text[]);
  perform booking.admin_set_product_sales_channels(7, array['shop', 'gift_shop']);
  perform pg_temp.ck(booking.admin_pos_catalog() @> '[{"product_id": 45}]' and not booking.admin_pos_catalog() @> '[{"product_id": 44}]', 'pikakassa: pos pois → tuote pois kassalta');
  perform pg_temp.ck(pg_temp.errcode('select booking.admin_pos_checkout(''[{"product_id": 44, "quantity": 1}]''::jsonb, ''fi'', null)') = 'not_counter_product', 'pikakassan maksu estetty tuotteelle ilman pos-kanavaa');
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  select id into rid from booking.schedule_rules where product_id = 1 and active order by id limit 1;
  v := booking.public_create_booking(rid, current_date + 7, 2, 'T316 Testi', 't316b@example.test', '+358401234567', false, 'fi', null, 'private', null, null);
  perform pg_temp.ck(v ->> 'code' = 'not_bookable', 'tuote 1 ilman shop-kanavaa: varaus estyy (' || coalesce(v ->> 'code', v::text) || ')');
  perform pg_temp.ck(not booking.public_catalog() @> '[{"id": 1}]' and not exists (select 1 from booking.public_availability(1, current_date, current_date + 30)), 'tuote 1 ilman shop-kanavaa: ei listassa eikä saatavuudessa');
  perform pg_temp.ck((select coalesce(v2 ->> 'reason', '') from (select booking.public_ritual_addon(rid, current_date + 7, 2) v2) z) = 'product_unavailable', 'rituaalilisä ilman julkista kanavaa: product_unavailable');
  perform pg_temp.ck(booking._ritual_addon_fit(date_trunc('hour', now()) + interval '7 days 2 hours', 2, true) is null, '_ritual_addon_fit(julkinen) ilman kanavaa: null');
  -- verkkomaksun saatavuus ohitetaan tässä testissä (vain tämä transaktio), jotta kanavatarkistus tavoitetaan
  execute 'create or replace function booking._checkout_online_available() returns boolean language sql stable set search_path to '''' as $f$ select true $f$';
  v := booking._public_create_training_signup_impl(90114, current_date + 20, 'T316 Testi', 't316c@example.test', '+358401234567', 'FI', 'fi', 'fi', null, false, true, '{}');
  perform pg_temp.ck(v ->> 'code' = 'not_bookable', 'koulutusilmoittautuminen ilman kanavaa: not_bookable (' || coalesce(v ->> 'code', v::text) || ')');
  v := booking._public_create_training_signup_impl(90121, current_date + 20, 'T316 Testi', 't316e@example.test', '+358401234567', 'FI', 'fi', 'fi', null, false, true, '{}');
  perform pg_temp.ck(coalesce(v ->> 'code', 'ok') <> 'not_bookable', 'koulutus 121 (link) ohittaa kanavatarkistuksen (' || coalesce(v ->> 'code', 'ok') || ')');
  perform pg_temp.ck(booking.public_training_checkout(90114, current_date + 20) ->> 'code' = 'not_found' and booking.public_product_by_slug((select slug from kb.products where id = 114)) is null, 'koulutus 114 ilman linkkiä: ei kassaa eikä kurssisivua');
  perform pg_temp.ck((booking.public_drinks_catalog('a316a316a316a316a316a316a316a082') -> 'products') = '[]'::jsonb, 'kylmälaite: qr pois → ei tuotetta');
  perform pg_temp.ck(not booking.public_gift_card_packages()::text like '%"code": "entry_2"%' and booking.public_gift_card_packages()::text like '%"code": "saunarituaali_2"%', 'lahjakorttipaketti piiloon, jos sen tuote ei ole lahjakorttikaupassa');
  v := booking._public_buy_gift_card_impl('[{"package": "entry_2", "quantity": 1}]'::jsonb, 'T316 Testi', 't316d@example.test', '+358401234567');
  perform pg_temp.ck(v ->> 'code' = 'package_inactive', 'lahjakortin osto estyy suoralla kutsulla (' || coalesce(v ->> 'code', v::text) || ')');
  perform pg_temp.ck(not exists (select 1 from booking._upsell_options(array[2]::bigint[], '{}'::bigint[], current_date + 5, 2) u where to_jsonb(u)::text like '%"product_id": 8,%'), 'lisämyynti: tuote 8 ilman shop-kanavaa ei tarjolla');

  -- passiivinen kanava = ei kanavassa
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-000000000316', 'role', 'authenticated')::text, true);
  -- bookable = false -tuote saa julkisen kanavan → bookable = true ja vanhat kentät liitostaulun mukaisiksi
  set local session_replication_role = replica;
  insert into booking.schedule_rules overriding system value select (jsonb_populate_record(null::booking.schedule_rules, to_jsonb(r) || jsonb_build_object('id', 90036, 'product_id', 36, 'kind', 'event',
         'valid_from', current_date + 20, 'valid_to', current_date + 20, 'weekdays', jsonb_build_array(extract(isodow from current_date + 20)::int), 'active', true, 'training_segment_only', false))).*
    from booking.schedule_rules r where r.id = 1;
  set local session_replication_role = origin;
  -- muutos vanhaan: bookable = false -koulutus ei enää näy upotuksen listassa suljettuna (sillä ei ole julkista kanavaa; PRODissa ei tällaisia kertoja)
  perform pg_temp.ck(not booking.public_events(current_date, 'widget') @> '[{"product_id": 36}]', 'koulutus 36 (bookable false) ei upotuksessa ennen kanavaa');
  x := booking.admin_set_product_sales_channels(36, array['widget']);
  perform pg_temp.ck((x -> 'config' ->> 'bookable')::boolean and (select bookable and channels is null and not shop_visible from booking.product_config where product_id = 36),
                     'julkisen kanavan lisäys: bookable = true, channels = koulutuksen oletus (null = widget)');
  perform pg_temp.ck(booking.public_events(current_date, 'widget') @> '[{"product_id": 36}]'
                     and booking.public_events(current_date, 'widget') -> 0 -> 'occurrences' -> 0 ->> 'status' = 'available', 'koulutus 36 näkyy upotuksessa varattavana kanavan lisäyksen jälkeen');
  x := booking.admin_set_product_sales_channels(27, array['pos']);
  perform pg_temp.ck((select not bookable from booking.product_config where product_id = 27), 'ei-julkinen kanava (pos) ei muuta bookablea');
  -- uusi tuote: bookable = false eikä kanavia, kunnes julkinen kanava valitaan
  x := booking.admin_product_create('{"name": "T316 uusi hoito", "price": 50, "vat_rate": 25.5, "category": "treatment"}'::jsonb);
  perform pg_temp.ck(not (select bookable from booking.product_config where product_id = (x ->> 'id')::bigint)
                     and not exists (select 1 from booking.product_sales_channels where product_id = (x ->> 'id')::bigint), 'uusi tuote: bookable false, ei kanavia');
  v := booking.admin_set_product_sales_channels((x ->> 'id')::bigint, array['link']);
  perform pg_temp.ck((select bookable and channels = array['link'] and not shop_visible from booking.product_config where product_id = (x ->> 'id')::bigint), 'uusi tuote + Suora linkki → bookable true');
  update booking.sales_channels set active = false where code = 'widget';
  perform pg_temp.ck(not booking._in_channel(36, 'widget') and booking.public_events(current_date, 'widget') = '[]'::jsonb, 'passiivinen kanava ei näy julkisesti');
  perform pg_temp.ck(pg_temp.errcode('select booking.admin_set_product_sales_channels(5, array[''shop'',''widget''])') = 'channel_inactive', 'passiivista kanavaa ei voi lisätä');
  perform booking.admin_set_product_sales_channels(36, array['widget']);
  perform pg_temp.ck(booking.admin_list_sales_channels() -> 'products' -> '36' = '["widget"]'::jsonb, 'olemassa oleva passiivinen valinta säilyy tallennuksessa');

  -- uusi tuote saa kanavat vanhoista kentistä
  set local session_replication_role = replica;
  insert into kb.products overriding system value select (jsonb_populate_record(null::kb.products, to_jsonb(p) || jsonb_build_object('id', 99316, 'slug', 't316-uusi'))).* from kb.products p where p.id = 5;
  set local session_replication_role = origin;
  insert into booking.product_config select (jsonb_populate_record(null::booking.product_config, to_jsonb(c) || jsonb_build_object('product_id', 99316, 'shop_visible', true, 'pos_enabled', true))).* from booking.product_config c where c.product_id = 5;
  perform pg_temp.ck((select array_agg(channel_code order by channel_code) from booking.product_sales_channels where product_id = 99316) = array['pos', 'shop'], 'uusi product_config-rivi → kanavat triggeristä');
  perform pg_temp.ck(pg_temp.errcode('update booking.product_sales_channels set channel_code = ''link'' where product_id = 99316 and channel_code = ''pos''') = 'invalid_param', 'kanavariviä ei päivitetä (vain lisäys/poisto)');
  perform set_config('request.jwt.claims', '', true);
end $t$;

select format('TESTRESULT pass=%s fail=%s', count(*) filter (where ok), count(*) filter (where not ok)) from t316_res;
select 'FAILED: ' || label from t316_res where not ok;
rollback;
