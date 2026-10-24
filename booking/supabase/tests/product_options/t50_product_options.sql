-- ================= booking_50: tuotevalinta (product_options) =================
create function pg_temp.adm() returns text language sql as $$ select json_build_object('sub', (select user_id from booking.staff where role = 'admin' and active limit 1), 'role', 'authenticated')::text $$;
create function pg_temp.as_(p text) returns void language sql as $$ select set_config('request.jwt.claims', p, true) $$;
create function pg_temp.slot(p_prod bigint, p_n int default 0, p_persons int default 1) returns timestamptz language sql volatile as $$
  select a.starts_at from booking.public_treatment_availability(p_prod, (now() at time zone 'Europe/Helsinki')::date + 3, (now() at time zone 'Europe/Helsinki')::date + 16, p_persons) a where a.status = 'available' order by a.starts_at offset p_n limit 1 $$;
create function pg_temp.mkw(p_n int, p_email text, p_opt text default null, p_prod bigint default 10) returns jsonb language plpgsql volatile as $$
begin
  perform pg_temp.as_(''); delete from booking.rate_limit_hits;
  return booking.public_create_treatment_booking(p_prod, pg_temp.slot(p_prod, p_n), 1, 'Testi Asiakas', p_email, '+358401234567', false, 'fi', null, 'private', null, p_opt);
end $$;
create function pg_temp.oid(p_no bigint) returns bigint language sql stable as $$ select id from booking.orders where order_no = p_no $$;
create function pg_temp.rid(p_no bigint) returns bigint language sql stable as $$ select min(id) from booking.reservations where order_id = pg_temp.oid(p_no) $$;

create temp table _st(k text primary key, v text);
do $$ declare
  r jsonb; r2 jsonb; n0 int; n1 int; v_no bigint; v_tok uuid; v_oid bigint; v_rid bigint; v_no2 bigint; v_oid2 bigint; v_rid2 bigint; x jsonb; v_cl jsonb; v_ok boolean; v_cnt int;
  v_o_h bigint; v_o_other bigint; v_mailn0 int; v_mailn1 int; v_j_tok uuid; v_j_oid bigint; v_desc text;
begin
  perform pg_temp.as_('');
  -- ---- A. skeema, seed, oikeudet ----
  perform pg_temp.t_ok((select count(*) from information_schema.columns where table_schema = 'booking' and table_name = 'product_options' and column_name in ('id','product_id','code','name','name_en','description','description_en','sort_order','active','created_at','updated_at')) = 11
     and (select relrowsecurity from pg_class where oid = 'booking.product_options'::regclass) and has_table_privilege('authenticated', 'booking.product_options', 'select') and not has_table_privilege('authenticated', 'booking.product_options', 'insert')
     and not has_table_privilege('anon', 'booking.product_options', 'select') and (select count(*) from pg_policies where schemaname = 'booking' and tablename = 'product_options') = 1, 'A1 product_options: sarakkeet, RLS (vain henkilökunnan luku), ei kirjoitusta/anon-lukua');
  perform pg_temp.t_ok(exists (select 1 from information_schema.columns where table_schema = 'booking' and table_name = 'reservations' and column_name = 'product_option_id' and is_nullable = 'YES')
     and (select count(*) from information_schema.columns where table_schema = 'booking' and table_name = 'product_config' and column_name in ('option_required','option_label','option_label_en')) = 3
     and exists (select 1 from pg_trigger where tgrelid = 'booking.reservations'::regclass and tgname = 'reservations_option_check' and tgenabled = 'O') and exists (select 1 from pg_trigger where tgrelid = 'booking.product_options'::regclass and tgname = 'audit_trg'), 'A2 reservations.product_option_id (nullable), product_config-kentät, validointitrigger ja audit päällä');
  perform pg_temp.t_ok((select count(*) from booking.product_options where product_id = 10) = 4
     and (select string_agg(code || ':' || name || ':' || name_en, ',' order by sort_order) from booking.product_options where product_id = 10) = 'hunajahoito:Hunajahoito:Honey treatment,vihtahoito:Vihtahoito:Birch whisk treatment,suolahoito:Suolahoito:Salt treatment,turvehoito:Turvehoito:Peat treatment'
     and (select option_required from booking.product_config where product_id = 10) and (select option_label from booking.product_config where product_id = 10) = 'Valitse hoito'
     and (select count(*) from booking.product_options) = 4 and (select count(*) from booking.product_config where option_required) = 1, 'A3 seed: Saunahoidolla 4 vaihtoehtoa FI/EN oikeassa järjestyksessä, pakollinen; muille tuotteille ei vaihtoehtoja eikä pakollisuutta');
  perform pg_temp.t_ok(has_function_privilege('anon', 'booking.public_create_treatment_booking(bigint,timestamptz,integer,text,text,text,boolean,text,text,text,jsonb,text)', 'execute') and has_function_privilege('anon', 'booking.public_change_order_time(uuid,bigint,timestamptz,bigint,date,integer,text)', 'execute')
     and has_function_privilege('anon', 'booking.public_change_treatment_booking(uuid,timestamptz,integer,text)', 'execute') and not has_function_privilege('anon', 'booking.admin_set_reservation_option(bigint,text,boolean)', 'execute')
     and has_function_privilege('authenticated', 'booking.admin_set_reservation_option(bigint,text,boolean)', 'execute') and has_function_privilege('authenticated', 'booking.admin_list_product_options(bigint)', 'execute') and not has_function_privilege('anon', 'booking.admin_list_product_options(bigint)', 'execute')
     and has_function_privilege('authenticated', 'booking.admin_upsert_product_option(bigint,text,text,text,integer,boolean,text,text)', 'execute') and has_function_privilege('authenticated', 'booking.admin_set_product_option_settings(bigint,boolean,text,text)', 'execute')
     and has_function_privilege('authenticated', 'booking.admin_create_resource_booking(bigint,timestamptz,integer,bigint,jsonb,timestamptz,bigint,text,boolean,text,numeric,boolean,text,jsonb,bigint,text,text)', 'execute') and not has_function_privilege('anon', 'booking.admin_create_resource_booking(bigint,timestamptz,integer,bigint,jsonb,timestamptz,bigint,text,boolean,text,numeric,boolean,text,jsonb,bigint,text,text)', 'execute')
     and has_function_privilege('authenticated', 'booking.admin_list_reservations(timestamptz,timestamptz,text,text,bigint,integer,integer,text,boolean,text,bigint)', 'execute') and not has_function_privilege('anon', 'booking.admin_list_reservations(timestamptz,timestamptz,text,text,bigint,integer,integer,text,boolean,text,bigint)', 'execute')
     and not has_function_privilege('anon', 'booking._resolve_product_option(bigint,text,boolean)', 'execute') and not has_function_privilege('authenticated', 'booking._create_legs_booking(text,bigint,timestamptz,timestamptz,integer,bigint,text,uuid,text,numeric,bigint,boolean,text,boolean,bigint,bigint,text)', 'execute')
     and not exists (select 1 from pg_proc where pronamespace = 'booking'::regnamespace and proname in ('public_create_treatment_booking','public_change_treatment_booking','public_change_order_time','_create_legs_booking','_admin_create_legs','admin_create_resource_booking','admin_create_old_booking','admin_list_reservations') group by proname having count(*) > 1), 'A4 oikeudet oikein; vanhat allekirjoitukset poistettu (ei ylikuormia)');

  -- ---- B. julkinen katalogi ----
  perform pg_temp.as_('');
  x := (select e from jsonb_array_elements(booking.public_catalog()) e where (e ->> 'id')::bigint = 10);
  perform pg_temp.t_ok(jsonb_array_length(x -> 'options') = 4 and x -> 'options' -> 0 ->> 'code' = 'hunajahoito' and x -> 'options' -> 3 ->> 'code' = 'turvehoito' and x -> 'options' -> 1 ->> 'name_en' = 'Birch whisk treatment'
     and (x ->> 'option_required')::boolean and x ->> 'option_label' = 'Valitse hoito' and x ->> 'option_label_en' = 'Choose your treatment', 'B1 public_catalog: Saunahoidolla options-lista (4, järjestys), option_required, otsikot FI/EN');
  perform pg_temp.t_ok(not exists (select 1 from jsonb_array_elements(booking.public_catalog()) e where (e ->> 'id')::bigint <> 10 and (jsonb_array_length(e -> 'options') > 0 or (e ->> 'option_required')::boolean)) and (select count(*) from jsonb_array_elements(booking.public_catalog()) e) >= 4, 'B2 muut tuotteet: options [] ja option_required false');

exception when others then declare c_ text; begin get stacked diagnostics c_ = pg_exception_context; insert into pg_temp._res(kind,ok,msg) values ('T', false, 'RYHMÄ A-B KESKEYTYI: ' || sqlstate || ' ' || sqlerrm || ' @ ' || replace(c_, E'\n', ' | ')); end;
end $$;
do $$ declare
  r jsonb; r2 jsonb; n0 int; v_no bigint; v_tok uuid; v_oid bigint; v_rid bigint; x jsonb; v_cl jsonb; v_ok boolean;
begin
  perform pg_temp.as_('');
  -- ---- C. julkinen varaus: pakollisuus ja validointi ----
  select count(*) into n0 from booking.orders;
  r := pg_temp.mkw(0, 'opt1@example.invalid', null);
  perform pg_temp.t_ok(r ->> 'ok' = 'false' and r ->> 'code' = 'option_required' and r ->> 'message' = 'Valitse hoito' and (select count(*) from booking.orders) = n0 and not exists (select 1 from booking.customers where email = 'opt1@example.invalid'), 'C1 ilman valintaa: option_required (ei tilausta eikä asiakasta)');
  r := pg_temp.mkw(0, 'opt2@example.invalid', 'foo');
  perform pg_temp.t_ok(r ->> 'ok' = 'false' and r ->> 'code' = 'invalid_option' and (select count(*) from booking.orders) = n0, 'C2 tuntematon koodi: invalid_option');
  r := pg_temp.mkw(0, 'opt3@example.invalid', '   ');
  perform pg_temp.t_ok(r ->> 'code' = 'option_required', 'C3 tyhjä/välilyönnit = ei valintaa -> option_required');
  perform pg_temp.as_(pg_temp.adm());
  perform booking.admin_upsert_product_option(11, 'test_x', 'Testivalinta', 'Test option', 5);
  r := pg_temp.mkw(0, 'opt4@example.invalid', 'test_x');
  perform pg_temp.t_ok(r ->> 'code' = 'invalid_option' and (select count(*) from booking.orders) = n0, 'C4 toisen tuotteen vaihtoehto -> invalid_option');
  r := pg_temp.mkw(0, 'opt5@example.invalid', 'HunajaHoito');
  v_no := (r ->> 'order_no')::bigint; v_tok := (r ->> 'token')::uuid; v_oid := pg_temp.oid(v_no); v_rid := pg_temp.rid(v_no);
  perform pg_temp.t_ok(r ->> 'ok' = 'true' and r -> 'option' ->> 'code' = 'hunajahoito' and r -> 'option' ->> 'name' = 'Hunajahoito' and r -> 'option' ->> 'name_en' = 'Honey treatment'
     and (select product_option_id from booking.reservations where id = v_rid) = (select id from booking.product_options where product_id = 10 and code = 'hunajahoito') and (r ->> 'total')::numeric = 99, 'C5 oikea valinta (kirjainkoolla ei väliä): ok, vastaus sisältää option, varaukselle tallentuu product_option_id, hinta ei muutu (99 €)');
  perform pg_temp.t_ok((select price_breakdown ->> 'model' from booking.order_items where order_id = v_oid and kind = 'reservation') = 'legs_v2' and (select line_total_gross from booking.order_items where order_id = v_oid and kind = 'reservation') = 99, 'C6 tilausrivi ennallaan (legs_v2, 99 €) – ei hintaeroa valinnan mukaan');
  -- vanha 11-parametrinen kutsu toimii tuotteelle ilman vaihtoehtoja
  perform pg_temp.as_(''); delete from booking.rate_limit_hits;
  r2 := booking.public_create_treatment_booking(11, pg_temp.slot(11, 0, 1), 1, 'Testi Asiakas', 'opt6@example.invalid', '+358401234567', false, 'fi', null, 'private', null);
  perform pg_temp.t_ok(r2 ->> 'ok' = 'true' and r2 -> 'option' = 'null'::jsonb and (select product_option_id from booking.reservations where id = pg_temp.rid((r2 ->> 'order_no')::bigint)) is null, 'C7 taaksepäin yhteensopiva: vanha kutsu tuotteelle ilman vaihtoehtoja ok (option null)');
  r2 := pg_temp.mkw(1, 'opt7@example.invalid', 'hunajahoito', 11);
  perform pg_temp.t_ok(r2 ->> 'code' = 'invalid_option', 'C8 vaihtoehdoton tuote + annettu koodi -> invalid_option');
  -- aktiivisuus: poistettu käytöstä -> invalid_option; vastaava valinta pakollisuudessa
  perform pg_temp.as_(pg_temp.adm());
  perform booking.admin_upsert_product_option(10, 'suolahoito', 'Suolahoito', 'Salt treatment', 30, false);
  r2 := pg_temp.mkw(1, 'opt8@example.invalid', 'suolahoito');
  perform pg_temp.t_ok(r2 ->> 'code' = 'invalid_option' and jsonb_array_length((select e -> 'options' from jsonb_array_elements(booking.public_catalog()) e where (e ->> 'id')::bigint = 10)) = 3, 'C9 passivoitu vaihtoehto: ei valittavissa, ei katalogissa');
  perform pg_temp.as_(pg_temp.adm());
  perform booking.admin_upsert_product_option(10, 'suolahoito', 'Suolahoito', 'Salt treatment', 30, true);

  -- ---- D. julkinen tilaus ----
  perform pg_temp.as_(''); delete from booking.rate_limit_hits;
  x := booking.public_get_order(v_tok);
  perform pg_temp.t_ok(x ->> 'ok' = 'true' and x -> 'reservations' -> 0 -> 'option' ->> 'code' = 'hunajahoito' and x -> 'reservations' -> 0 -> 'option' ->> 'name_en' = 'Honey treatment' and jsonb_array_length(x -> 'reservations' -> 0 -> 'option_choices') = 4
     and x -> 'reservations' -> 0 -> 'option_choices' -> 2 ->> 'code' = 'suolahoito', 'D1 public_get_order: varauksella option + option_choices (4)');
  x := booking.public_get_booking(v_tok);
  perform pg_temp.t_ok(x ->> 'ok' = 'true' and x -> 'items' -> 0 -> 'option' ->> 'code' = 'hunajahoito', 'D2 public_get_booking: item.option');
  -- vaihto asiakkaan toimesta
  delete from booking.rate_limit_hits;
  r := booking.public_change_order_time(v_tok, v_rid, null, null, null, null, 'turvehoito');
  perform pg_temp.t_ok(r ->> 'ok' = 'true' and r -> 'option' ->> 'code' = 'turvehoito' and (select po.code from booking.reservations rr join booking.product_options po on po.id = rr.product_option_id where rr.id = v_rid) = 'turvehoito'
     and (select count(*) from booking.email_outbox where order_id = v_oid and kind = 'order_change') = 1 and (select total_gross from booking.orders where id = v_oid) = 99, 'D3 public_change_order_time pelkällä valinnalla: vaihtuu, order_change-viesti jonossa, hinta ennallaan');
  delete from booking.rate_limit_hits;
  r := booking.public_change_order_time(v_tok, v_rid, null, null, null, null, 'foo');
  perform pg_temp.t_ok(r ->> 'ok' = 'false' and r ->> 'code' = 'invalid_option' and (select po.code from booking.reservations rr join booking.product_options po on po.id = rr.product_option_id where rr.id = v_rid) = 'turvehoito', 'D4 virheellinen vaihto: invalid_option, valinta ennallaan');
  delete from booking.rate_limit_hits;
  r := booking.public_change_order_time(v_tok, v_rid, null, null, null, null, null);
  perform pg_temp.t_ok(r ->> 'ok' = 'false' and r ->> 'code' = 'invalid_change', 'D5 ei muutettavaa (ei aikaa/henkilöitä/valintaa) -> invalid_change');
  delete from booking.rate_limit_hits;
  r := booking.public_change_order_time(v_tok, v_rid, pg_temp.slot(10, 3), null, null, 1);
  perform pg_temp.t_ok(r ->> 'ok' = 'true' and r -> 'option' ->> 'code' = 'turvehoito' and (select po.code from booking.reservations rr join booking.product_options po on po.id = rr.product_option_id where rr.id = v_rid) = 'turvehoito', 'D6 ajan vaihto säilyttää valinnan');
  -- lisäys tilaukseen verkossa: hoitorivi vaatii valinnan
  delete from booking.rate_limit_hits;
  r := booking.public_add_to_order(v_tok, jsonb_build_array(jsonb_build_object('type', 'reservation', 'product_id', 10, 'persons', 1, 'start', pg_temp.slot(10, 6))));
  perform pg_temp.t_ok(r ->> 'ok' = 'false' and r ->> 'code' = 'option_required' and (select count(*) from booking.reservations where order_id = v_oid) = 1, 'D7 public_add_to_order hoitorivi ilman valintaa: option_required (ei riviä)');
  delete from booking.rate_limit_hits;
  r := booking.public_add_to_order(v_tok, jsonb_build_array(jsonb_build_object('type', 'reservation', 'product_id', 10, 'persons', 1, 'start', pg_temp.slot(10, 6), 'option_code', 'vihtahoito')));
  perform pg_temp.t_ok(r ->> 'ok' = 'true' and (select count(*) from booking.reservations where order_id = v_oid) = 2 and (select po.code from booking.reservations rr join booking.product_options po on po.id = rr.product_option_id where rr.order_id = v_oid and rr.id <> v_rid) = 'vihtahoito', 'D8 public_add_to_order option_code: toinen hoitovaraus valinnalla vihtahoito');
  delete from booking.rate_limit_hits;
  r := booking.public_add_to_order(v_tok, jsonb_build_array(jsonb_build_object('type', 'reservation', 'product_id', 10, 'persons', 1, 'start', pg_temp.slot(10, 9), 'option_code', 'nope')));
  perform pg_temp.t_ok(r ->> 'ok' = 'false' and r ->> 'code' = 'invalid_option', 'D9 public_add_to_order väärä koodi: invalid_option');

  -- ---- E. sähköpostidata (email_outbox_claim) ----
  update booking.email_outbox set status = 'sent' where status in ('pending', 'failed') and order_id is distinct from v_oid;
  update booking.email_outbox set next_attempt_at = now() - interval '1 minute' where order_id = v_oid;
  v_cl := booking.email_outbox_claim(50);
  x := (select e from jsonb_array_elements(v_cl) e where e ->> 'kind' = 'order_confirmation' and (e -> 'order' ->> 'order_no')::bigint = v_no limit 1);
  perform pg_temp.t_ok(x is not null and (select count(*) from jsonb_array_elements(x -> 'order' -> 'reservations')) = 2 and exists (select 1 from jsonb_array_elements(x -> 'order' -> 'reservations') rr where rr -> 'option' ->> 'code' in ('turvehoito') and rr -> 'option' ->> 'name' = 'Turvehoito' and rr -> 'option' ->> 'name_en' = 'Peat treatment')
     and exists (select 1 from jsonb_array_elements(x -> 'order' -> 'reservations') rr where rr -> 'option' ->> 'code' = 'vihtahoito'), 'E1 order_confirmation-data: reservations[].option (code, name, name_en) mukana');
  x := (select e from jsonb_array_elements(v_cl) e where e ->> 'kind' = 'order_change' and (e -> 'order' ->> 'order_no')::bigint = v_no limit 1);
  perform pg_temp.t_ok(x is not null and exists (select 1 from jsonb_array_elements(x -> 'order' -> 'reservations') rr where rr -> 'option' ->> 'code' = 'turvehoito'), 'E2 order_change-data sisältää option');

  insert into pg_temp._st values ('no', v_no::text), ('tok', v_tok::text), ('oid', v_oid::text), ('rid', v_rid::text);
exception when others then declare c_ text; begin get stacked diagnostics c_ = pg_exception_context; insert into pg_temp._res(kind,ok,msg) values ('T', false, 'RYHMÄ C-E KESKEYTYI: ' || sqlstate || ' ' || sqlerrm || ' @ ' || replace(c_, E'\n', ' | ')); end;
end $$;

create function pg_temp.admc(p_n int, p_opt text, p_paid boolean default false, p_email text default 'admopt@example.invalid', p_prod bigint default 10, p_method text default 'pay_later', p_persons int default 2) returns jsonb language plpgsql volatile as $$
begin
  perform pg_temp.as_(pg_temp.adm());
  return booking.admin_create_resource_booking(p_prod, pg_temp.slot(p_prod, p_n, case when p_prod = 10 then 1 else p_persons end), p_persons, null, jsonb_build_object('name', 'Admin Testi', 'email', p_email), null, null, p_method, p_paid, null, null, false, null, null, null, null, p_opt);
end $$;
create function pg_temp.st(p_k text) returns text language sql as $$ select v from pg_temp._st where k = p_k $$;

do $$ declare
  r jsonb; r2 jsonb; x jsonb; v_no bigint; v_oid bigint; v_rid bigint; v_no2 bigint; v_oid2 bigint; v_rid2 bigint; v_oid3 bigint; v_desc text; v_j_tok uuid; v_j_oid bigint; v_cnt int; v_mail0 int; v_day date;
  v_sql text;
begin
  perform pg_temp.as_(pg_temp.adm());
  -- ---- F. hallinta: luonti ----
  perform pg_temp.t_err($q$select pg_temp.admc(0, null)$q$, 'option_required', 'F1 admin_create_resource_booking ilman valintaa: option_required');
  perform pg_temp.t_err($q$select pg_temp.admc(0, 'foo')$q$, 'invalid_option', 'F2 admin_create_resource_booking väärä koodi: invalid_option');
  perform pg_temp.t_ok(not exists (select 1 from booking.customers where email = 'admopt@example.invalid'), 'F3 virhe ei jätä asiakasta/tilausta');
  r := pg_temp.admc(0, 'turvehoito', false, 'admopt1@example.invalid');
  v_no := (r ->> 'order_no')::bigint; v_oid := pg_temp.oid(v_no); v_rid := (r ->> 'reservation_id')::bigint;
  perform pg_temp.t_ok(r ->> 'reservation_id' is not null and r -> 'option' ->> 'code' = 'turvehoito' and (select product_option_id from booking.reservations where id = v_rid) = (select id from booking.product_options where product_id = 10 and code = 'turvehoito') and (r ->> 'total')::numeric = 134, 'F4 admin_create_resource_booking option_code=turvehoito: ok, tallentuu, hinta 99 + 35 (2 hlö) = 134 (ei hintaeroa valinnasta)');
  r2 := pg_temp.admc(0, null, false, 'admopt2@example.invalid', 11, 'pay_later', 1);
  perform pg_temp.t_ok(r2 ->> 'reservation_id' is not null and r2 -> 'option' = 'null'::jsonb, 'F5 admin_create_resource_booking tuotteelle ilman vaihtoehtoja ei vaadi valintaa');
  r2 := booking.admin_create_old_booking(16, pg_temp.slot(10, 0), 1, null, jsonb_build_object('name', 'Admin Vanha', 'email', 'admold@example.invalid'), null, null, 'pay_later', false, null, 0, true, 'testi vanha tuote', null, null, null);
  perform pg_temp.t_ok(r2 ->> 'reservation_id' is not null, 'F6 admin_create_old_booking vanha 16-parametrinen kutsu toimii (vanha tuote, ei vaihtoehtoja)');
  -- hallinnan listaukset
  perform pg_temp.t_ok((select option_code from booking.admin_list_reservations(null, null, null, null, 10, 50, 0, 'native') where reservation_id = v_rid) = 'turvehoito'
     and (select option_name from booking.admin_list_reservations(null, null, null, null, 10, 50, 0, 'native') where reservation_id = v_rid) = 'Turvehoito'
     and not (select option_missing from booking.admin_list_reservations(null, null, null, null, 10, 50, 0, 'native') where reservation_id = v_rid), 'F7 admin_list_reservations: option_code/option_name, option_missing=false');
  perform pg_temp.t_ok((select count(*) from booking.admin_list_reservations(null, null, null, null, 10, 100, 0, 'johku')) = 7 and (select bool_and(option_missing and option_code is null) from booking.admin_list_reservations(null, null, null, null, 10, 100, 0, 'johku'))
     and not exists (select 1 from booking.admin_list_reservations(null, null, null, null, 16, 100, 0, null) where option_missing), 'F8 Johku-/vanhat Saunahoito-varaukset (7): option null + option_missing=true ("valitsematta"); vaihtoehdottomat tuotteet eivät ole option_missing');
  v_day := (select (starts_at at time zone 'Europe/Helsinki')::date from booking.reservations where id = v_rid);
  x := (select e from jsonb_array_elements(booking.admin_day_view(v_day) -> 'reservations') e where (e ->> 'reservation_id')::bigint = v_rid);
  perform pg_temp.t_ok(x -> 'option' ->> 'code' = 'turvehoito' and x -> 'option' ->> 'name' = 'Turvehoito' and x ->> 'option_missing' = 'false', 'F9 admin_day_view: reservations[].option + option_missing');
  x := booking.admin_get_order(v_oid);
  perform pg_temp.t_ok(x -> 'reservations' -> 0 -> 'option' ->> 'code' = 'turvehoito' and jsonb_array_length(x -> 'reservations' -> 0 -> 'option_choices') = 4 and x -> 'reservations' -> 0 ->> 'option_missing' = 'false' and (x -> 'reservations' -> 0 ->> 'product_id')::bigint = 10, 'F10 admin_get_order: option, option_choices (4), option_missing, product_id');
  -- Johku-tilaus: ei rikkoudu
  select o.id, o.public_token into v_j_oid, v_j_tok from booking.orders o join booking.reservations rr on rr.order_id = o.id where rr.product_id = 10 and rr.external_source = 'johku' order by o.id limit 1;
  x := booking.admin_get_order(v_j_oid);
  perform pg_temp.t_ok(x ->> 'ok' is distinct from 'false' and x -> 'reservations' -> 0 -> 'option' = 'null'::jsonb and x -> 'reservations' -> 0 ->> 'option_missing' = 'true', 'F11 admin_get_order Johku-tilaus: option null, option_missing true, ei virhettä');
  perform pg_temp.as_(''); delete from booking.rate_limit_hits;
  x := booking.public_get_order(v_j_tok);
  perform pg_temp.t_ok(x ->> 'ok' = 'true' and x -> 'reservations' -> 0 -> 'option' = 'null'::jsonb and jsonb_array_length(x -> 'reservations' -> 0 -> 'option_choices') = 4, 'F12 public_get_order Johku-tilaus: ok, option null (ei rikkoudu)');
  perform pg_temp.t_ok((select count(*) from booking.reservations where product_id = 10 and external_source = 'johku' and product_option_id is null) = 7, 'F13 Johku-varausten valinta pysyy null (7 kpl, ei muutettu)');
  -- ---- G. valinnan muutos hallinnasta ----
  perform pg_temp.as_(pg_temp.adm());
  r := booking.admin_set_reservation_option(v_rid, 'suolahoito');
  perform pg_temp.t_ok(r ->> 'ok' = 'true' and r -> 'option' ->> 'code' = 'suolahoito' and r -> 'previous' ->> 'code' = 'turvehoito' and r ->> 'email_queued' = 'false'
     and (select count(*) from booking.audit_log where table_name = 'reservations' and row_pk = v_rid::text and action = 'ADMIN_SET_OPTION') = 1, 'G1 admin_set_reservation_option: vaihtuu, edellinen palautuu, audit-rivi, ei sähköpostia oletuksena');
  perform pg_temp.t_err(format($q$select booking.admin_set_reservation_option(%s, 'foo')$q$, v_rid), 'invalid_option', 'G2 väärä koodi: invalid_option');
  perform pg_temp.t_err(format($q$select booking.admin_set_reservation_option(%s, null)$q$, v_rid), 'option_required', 'G3 tyhjennys pakolliselta tuotteelta: option_required');
  perform pg_temp.t_err($q$select booking.admin_set_reservation_option(999999999, 'suolahoito')$q$, 'not_found', 'G4 tuntematon varaus: not_found');
  perform pg_temp.t_err(format($q$select booking.admin_set_reservation_option(%s, 'hunajahoito')$q$, (select id from booking.reservations where product_id = 11 order by id desc limit 1)), 'invalid_option', 'G5 toisen tuotteen varaukselle Saunahoidon valinta: invalid_option');
  select count(*) into v_cnt from booking.email_outbox where order_id = v_oid and kind = 'order_change';
  r := booking.admin_set_reservation_option(v_rid, 'vihtahoito', true);
  perform pg_temp.t_ok(r ->> 'email_queued' = 'true' and (select count(*) from booking.email_outbox where order_id = v_oid and kind = 'order_change') = v_cnt + 1, 'G6 p_notify=true: order_change-viesti jonoon');
  -- ei oikeuksia
  perform pg_temp.as_('');
  perform pg_temp.t_err(format($q$select booking.admin_set_reservation_option(%s, 'suolahoito')$q$, v_rid), 'forbidden', 'G7 ei-henkilökunta: forbidden');
  perform pg_temp.t_err($q$select booking.admin_list_product_options(10)$q$, 'forbidden', 'G8 admin_list_product_options: ei-henkilökunta forbidden');
  perform pg_temp.t_err($q$select booking.admin_upsert_product_option(10, 'x', 'X')$q$, 'forbidden', 'G9 admin_upsert_product_option: ei-henkilökunta forbidden');
  perform pg_temp.t_err($q$select booking.admin_set_product_option_settings(10, true)$q$, 'forbidden', 'G10 admin_set_product_option_settings: ei-henkilökunta forbidden');
  -- trigger: väärän tuotteen valinta suoraan
  perform pg_temp.t_err(format($q$update booking.reservations set product_option_id = (select id from booking.product_options where product_id = 11 limit 1) where id = %s$q$, v_rid), 'invalid_option', 'G11 reservations-trigger: toisen tuotteen valinta estetty myös suoraan');
  -- ---- H. vaihtoehtojen hallinta ----
  perform pg_temp.as_(pg_temp.adm());
  x := booking.admin_list_product_options(10);
  perform pg_temp.t_ok(jsonb_array_length(x) = 1 and x -> 0 ->> 'product_name' = 'Saunahoito' and (x -> 0 ->> 'option_required')::boolean and jsonb_array_length(x -> 0 -> 'options') = 4 and (x -> 0 ->> 'reservations_without_option')::int = 2, 'H1 admin_list_product_options(10): 4 vaihtoehtoa, pakollinen, 2 tulevaa valitsematonta (Johku)');
  perform pg_temp.t_ok(jsonb_array_length(booking.admin_list_product_options(null)) = 2 and exists (select 1 from jsonb_array_elements(booking.admin_list_product_options(null)) e where (e ->> 'product_id')::bigint = 11), 'H2 admin_list_product_options(null): tuotteet joilla vaihtoehtoja (10 ja testivaihtoehto 11)');
  r := booking.admin_upsert_product_option(10, 'kuumakivihoito', 'Kuumakivihoito', null, 50);
  perform pg_temp.t_ok(r -> 'option' ->> 'code' = 'kuumakivihoito' and (r -> 'option' ->> 'sort_order')::int = 50 and (select name_en from booking.product_options where code = 'kuumakivihoito') is null and jsonb_array_length((select e -> 'options' from jsonb_array_elements(booking.public_catalog()) e where (e ->> 'id')::bigint = 10)) = 5, 'H3 admin_upsert_product_option: uusi vaihtoehto ilman EN-nimeä, näkyy katalogissa');
  r := booking.admin_upsert_product_option(10, 'kuumakivihoito', 'Kuumakivihoito 2', 'Hot stone', 50, false);
  perform pg_temp.t_ok((select name from booking.product_options where code = 'kuumakivihoito') = 'Kuumakivihoito 2' and not (select active from booking.product_options where code = 'kuumakivihoito') and (select count(*) from booking.product_options where product_id = 10) = 5, 'H4 upsert päivittää olemassa olevan (ei duplikaattia), passivointi');
  perform pg_temp.t_err($q$select booking.admin_upsert_product_option(10, 'Bad Code!', 'X')$q$, 'invalid_param', 'H5 virheellinen koodi: invalid_param');
  perform pg_temp.t_err($q$select booking.admin_upsert_product_option(10, 'abc', '')$q$, 'invalid_param', 'H6 tyhjä nimi: invalid_param');
  perform pg_temp.t_err($q$select booking.admin_upsert_product_option(999999, 'abc', 'Abc')$q$, 'product_not_found', 'H7 tuntematon tuote: product_not_found');
  perform pg_temp.t_err($q$select booking.admin_set_product_option_settings(12, true)$q$, 'no_options', 'H8 pakollisuus ilman aktiivisia vaihtoehtoja: no_options');
  -- pakollisuuden kytkeminen pois: ilman valintaa voi varata, tyhjennys sallittu
  r := booking.admin_set_product_option_settings(10, false, 'Valitse hoito', 'Choose your treatment');
  perform pg_temp.as_(''); delete from booking.rate_limit_hits;
  r2 := pg_temp.mkw(2, 'nopt1@example.invalid', null);
  perform pg_temp.t_ok(r2 ->> 'ok' = 'true' and r2 -> 'option' = 'null'::jsonb, 'H9 option_required=false: varaus onnistuu ilman valintaa (option null)');
  perform pg_temp.t_ok(not (select (e ->> 'option_required')::boolean from jsonb_array_elements(booking.public_catalog()) e where (e ->> 'id')::bigint = 10) and jsonb_array_length((select e -> 'options' from jsonb_array_elements(booking.public_catalog()) e where (e ->> 'id')::bigint = 10)) = 4, 'H10 katalogi: option_required=false, vaihtoehdot silti listattu');
  perform pg_temp.as_(pg_temp.adm());
  r := booking.admin_set_reservation_option(pg_temp.rid((r2 ->> 'order_no')::bigint), null);
  perform pg_temp.t_ok(r ->> 'ok' = 'true' and r -> 'option' = 'null'::jsonb, 'H11 tyhjennys sallittu kun valinta ei ole pakollinen');
  r := booking.admin_set_product_option_settings(10, true, 'Valitse hoito', 'Choose your treatment');
  perform pg_temp.t_ok(r ->> 'option_required' = 'true' and (select option_label_en from booking.product_config where product_id = 10) = 'Choose your treatment', 'H12 pakollisuus takaisin päälle');
  -- kaikki vaihtoehdot passiivisiksi -> varaus ei vaadi valintaa (ei lukkiudu)
  update booking.product_options set active = false where product_id = 10;
  perform pg_temp.as_(''); delete from booking.rate_limit_hits;
  r2 := pg_temp.mkw(3, 'nopt2@example.invalid', null);
  perform pg_temp.t_ok(r2 ->> 'ok' = 'true' and not (select (e ->> 'option_required')::boolean from jsonb_array_elements(booking.public_catalog()) e where (e ->> 'id')::bigint = 10), 'H13 jos kaikki vaihtoehdot passiivisia: ei pakollista (ei lukkiudu)');
  update booking.product_options set active = true where product_id = 10 and code in ('hunajahoito','vihtahoito','suolahoito','turvehoito');

  -- ---- I. lisäys tilaukseen hallinnasta ----
  perform pg_temp.as_(pg_temp.adm());
  perform pg_temp.t_err(format($q$select booking.admin_add_to_order(%s, jsonb_build_array(jsonb_build_object('type','reservation','product_id',10,'persons',1,'start',pg_temp.slot(10, 1))))$q$, v_oid), 'option_required', 'I1 admin_add_to_order hoitorivi ilman valintaa: option_required');
  r := booking.admin_add_to_order(v_oid, jsonb_build_array(jsonb_build_object('type','reservation','product_id',10,'persons',1,'start',pg_temp.slot(10, 1),'option_code','hunajahoito')));
  perform pg_temp.t_ok(r ->> 'ok' = 'true' and (select count(*) from booking.reservations rr join booking.product_options po on po.id = rr.product_option_id where rr.order_id = v_oid and po.code = 'hunajahoito') = 1, 'I2 admin_add_to_order option_code: toinen varaus valinnalla hunajahoito');

  -- ---- J. kuitti ja tilausrivi ----
  r := pg_temp.admc(0, 'vihtahoito', true, 'admopt3@example.invalid', 10, 'cash', 1);
  v_oid2 := pg_temp.oid((r ->> 'order_no')::bigint);
  select snapshot -> 'lines' -> 0 ->> 'description' into v_desc from booking.receipts where order_id = v_oid2 and kind = 'receipt';
  perform pg_temp.t_ok(v_desc = 'Saunahoito – Vihtahoito' and (select (snapshot ->> 'total_gross')::numeric from booking.receipts where order_id = v_oid2) = 99 and (select text_body from booking.receipts where order_id = v_oid2) like '%Saunahoito – Vihtahoito%', 'J1 kuittirivi FI: "Saunahoito – Vihtahoito" (myös tekstirungossa), summa ennallaan 99 €');
  r := pg_temp.admc(0, 'turvehoito', false, 'admopt4@example.invalid', 10, 'pay_later', 1);
  v_oid3 := pg_temp.oid((r ->> 'order_no')::bigint);
  update booking.orders set locale = 'en' where id = v_oid3;
  perform booking.admin_record_payment(v_oid3, 'cash', (select total_gross from booking.orders where id = v_oid3), null);
  select snapshot -> 'lines' -> 0 ->> 'description' into v_desc from booking.receipts where order_id = v_oid3 and kind = 'receipt';
  perform pg_temp.t_ok(v_desc = 'Saunahoito – Peat treatment', 'J2 kuittirivi EN-tilaukselle: "Saunahoito – Peat treatment"');
  -- lisäpalvelurivit eivät saa valintaa; Johku-/valinnaton rivi ennallaan
  perform pg_temp.t_ok((select count(*) from booking.receipts where order_id in (v_oid2, v_oid3)) = 2, 'J3 kuitit syntyivät (2)');

  -- ---- K. muut ----
  perform pg_temp.t_ok((booking._therapist_missing_payload((select r2_ from booking.reservations r2_ where r2_.id = v_rid)) -> 'option' ->> 'code') = 'vihtahoito', 'K1 _therapist_missing_payload sisältää option');
  perform pg_temp.t_ok((select count(*) from booking.reservations where product_id = 10 and external_source = 'johku') = 7 and (select count(*) from booking.orders where external_source = 'johku') >= 7, 'K2 Johku-data ennallaan (7 Saunahoito-varausta)');
  perform pg_temp.t_ok(booking._public_slot_error('option_required', 'x') ->> 'code' = 'option_required' and booking._public_slot_error('invalid_option', 'x') ->> 'code' = 'invalid_option' and booking._public_slot_error('muu', 'x') ->> 'code' = 'slot_unavailable', 'K3 _public_slot_error: option-koodit läpi, muut ennallaan');
exception when others then declare c_ text; begin get stacked diagnostics c_ = pg_exception_context; insert into pg_temp._res(kind,ok,msg) values ('T', false, 'RYHMÄ F-K KESKEYTYI: ' || sqlstate || ' ' || sqlerrm || ' @ ' || replace(c_, E'\n', ' | ')); end;
end $$;
