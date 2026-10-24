-- t152: vuosikortin poisto hallinnasta (booking_152).
-- Käyttämätön, hallinnasta myönnetty kortti poistuu, asiakastyyppi palautuu (annual_cards_sync) ja audit-rivi syntyy (audit_trg);
-- varauksellinen (myös peruttu kortti / peruttu varaus) ja tilauksella ostettu kortti antavat virheen; ilman annual_cards.manage-oikeutta virhe;
-- oikeudet (anon/public/service_role ei, authenticated kyllä), security definer + search_path; korttilistan deletable / reservations_count.
-- Kaikki data on feikkiä (@example.test). Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN.
-- Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken. Tulos: TESTRESULT pass=… fail=…
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t152_r(ok boolean, label text) on commit drop;
grant all on t152_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t152_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare v text; begin execute p_sql; return 'NO ERROR'; exception when others then get stacked diagnostics v = pg_exception_detail; return coalesce(nullif(v, ''), sqlerrm); end $$;
create function pg_temp.msg(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'NO ERROR'; exception when others then return sqlerrm; end $$;
do $t$
declare
  v_adm uuid; v_mgr uuid; v_staff uuid;
  v_rule bigint := test.rule('Naisten sauna%');
  v_day date := test.next_dow(2, 6);
  v_c1 bigint; v_c2 bigint; v_c3 bigint; v_a1 bigint; v_a2 bigint; v_a3 bigint; v_a4 bigint; v_o bigint; j jsonb; v_list jsonb; v_audit int; v_price43 numeric;
begin
  -- auth.users.id:llä ei ole tuotannossa oletusarvoa → id annetaan itse; test.mk_user löytää valmiin rivin sähköpostilla
  insert into auth.users(id, email)
    select gen_random_uuid(), e from unnest(array['adm152@example.test', 'mgr152@example.test', 'staff152@example.test']) e
     where not exists (select 1 from auth.users u where u.email = e);
  v_adm := test.mk_staff('adm152@example.test', 'admin');
  v_mgr := test.mk_staff('mgr152@example.test', 'manager');
  v_staff := test.mk_staff('staff152@example.test', 'staff');
  insert into booking.customers(name, email, phone) values ('Poisto Pekka', 'poisto1@example.test', '0405550001') returning id into v_c1;
  insert into booking.customers(name, email, phone) values ('Poisto Paula', 'poisto2@example.test', '0405550002') returning id into v_c2;
  insert into booking.customers(name, email, phone) values ('Poisto Piia', 'poisto3@example.test', '0405550003') returning id into v_c3;

  -- rakenne ja oikeudet
  perform pg_temp.ck((select p.prosecdef and p.proconfig @> array['search_path=""'] from pg_proc p where p.oid = 'booking.admin_delete_annual_card(bigint)'::regprocedure), 'R1: security definer + search_path');
  perform pg_temp.ck(has_function_privilege('authenticated', 'booking.admin_delete_annual_card(bigint)', 'execute'), 'R2: authenticated saa kutsua');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_delete_annual_card(bigint)', 'execute'), 'R3: anon ei');
  perform pg_temp.ck(not has_function_privilege('service_role', 'booking.admin_delete_annual_card(bigint)', 'execute'), 'R4: service_role ei (vain authenticated)');
  perform pg_temp.ck(not exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                                  where p.oid = 'booking.admin_delete_annual_card(bigint)'::regprocedure and a.grantee = 0), 'R5: PUBLIC ei');

  -- A) käyttämätön hallinnasta myönnetty kortti
  perform test.login(v_mgr);
  v_a1 := (booking.admin_create_annual_card(v_c1, current_date, current_date + 364, null, 'poistettava') ->> 'id')::bigint;
  perform test.logout();
  perform pg_temp.ck((select customer_type from booking.customers where id = v_c1) = 'annual_card', 'A1: myöntö → annual_card');
  perform test.login(v_mgr);
  v_list := booking.admin_list_annual_cards_details();
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(v_list) x where (x ->> 'id')::bigint = v_a1 and (x ->> 'deletable')::boolean and (x ->> 'reservations_count')::int = 0),
    'A2: lista: deletable = true, reservations_count = 0');
  perform test.logout();
  perform test.login(v_staff);
  perform pg_temp.ck(pg_temp.err(format('select booking.admin_delete_annual_card(%s)', v_a1)) = 'forbidden', 'A3: staff (ei annual_cards.manage) → forbidden');
  perform pg_temp.ck(pg_temp.msg(format('select booking.admin_delete_annual_card(%s)', v_a1)) like '%annual_cards.manage%', 'A4: virheviesti nimeää oikeuden');
  perform test.logout();
  perform pg_temp.ck(exists (select 1 from booking.annual_cards where id = v_a1), 'A5: kortti säilyi oikeusvirheen jälkeen');
  v_audit := (select count(*) from booking.audit_log where table_name = 'annual_cards' and action = 'DELETE' and row_pk = v_a1::text);
  perform test.login(v_mgr);
  j := booking.admin_delete_annual_card(v_a1);
  perform test.logout();
  perform pg_temp.ck((j ->> 'ok')::boolean and (j ->> 'deleted')::boolean and (j ->> 'id')::bigint = v_a1 and (j ->> 'customer_id')::bigint = v_c1, 'A6: poisto ok');
  perform pg_temp.ck(not exists (select 1 from booking.annual_cards where id = v_a1), 'A7: kortti poistui');
  perform pg_temp.ck((select customer_type from booking.customers where id = v_c1) = 'customer', 'A8: asiakastyyppi palautui customeriksi');
  perform pg_temp.ck((select count(*) from booking.audit_log where table_name = 'annual_cards' and action = 'DELETE' and row_pk = v_a1::text) = v_audit + 1
    and exists (select 1 from booking.audit_log where table_name = 'annual_cards' and action = 'DELETE' and row_pk = v_a1::text and actor = v_mgr
                and old_data ->> 'notes' = 'poistettava' and new_data is null), 'A9: audit-rivi (DELETE, tekijä, old_data)');
  perform test.login(v_mgr);
  perform pg_temp.ck(pg_temp.err(format('select booking.admin_delete_annual_card(%s)', v_a1)) = 'not_found', 'A10: toinen poisto → not_found');
  perform test.logout();

  -- B) kortti, jolla on varaus → annual_card_used (myös perumisen jälkeen)
  perform test.login(v_adm);
  v_a2 := (booking.admin_create_annual_card(v_c2, current_date, current_date + 364, null, null) ->> 'id')::bigint;
  j := booking.admin_create_annual_card_booking(v_c2, v_rule, v_day, 'kortilla');
  perform pg_temp.ck(exists (select 1 from booking.reservations where annual_card_id = v_a2), 'B1: vuosikorttivaraus luotu');
  v_list := booking.admin_list_annual_cards_details();
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(v_list) x where (x ->> 'id')::bigint = v_a2 and not (x ->> 'deletable')::boolean and (x ->> 'reservations_count')::int = 1),
    'B2: lista: deletable = false, reservations_count = 1');
  perform pg_temp.ck(pg_temp.err(format('select booking.admin_delete_annual_card(%s)', v_a2)) = 'annual_card_used', 'B3: käytetty kortti → annual_card_used');
  perform pg_temp.ck(pg_temp.msg(format('select booking.admin_delete_annual_card(%s)', v_a2)) like '%Peru kortti%', 'B4: virhe neuvoo perumaan');
  perform booking.admin_revoke_annual_card(v_a2, true);
  perform pg_temp.ck(pg_temp.err(format('select booking.admin_delete_annual_card(%s)', v_a2)) = 'annual_card_used', 'B5: peruttu kortti peruttuine varauksineen → yhä annual_card_used');
  perform test.logout();
  perform pg_temp.ck(exists (select 1 from booking.annual_cards where id = v_a2) and (select customer_type from booking.customers where id = v_c2) = 'customer',
    'B6: kortti säilyi; peruminen palautti asiakastyypin');

  -- C) tilauksella ostettu kortti → annual_card_purchased
  update booking.settings set value = 'true'::jsonb where key = 'annual_card_sale_enabled';
  v_price43 := (select price from kb.products where id = 43);
  perform test.anon(); j := booking.public_buy_annual_card('Osto Olli', 'osto152@example.test', '0405550009'); perform test.logout();
  v_o := (select id from booking.orders where public_token = (j ->> 'token')::uuid);
  perform test.login(v_adm);
  perform booking.admin_record_payment(v_o, 'card_terminal', v_price43, 'kassa', null);
  v_a3 := (select id from booking.annual_cards where purchase_order_id = v_o);
  perform pg_temp.ck(v_a3 is not null, 'C1: maksu loi kortin');
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(booking.admin_list_annual_cards_details()) x where (x ->> 'id')::bigint = v_a3 and not (x ->> 'deletable')::boolean),
    'C2: lista: ostettu kortti ei deletable');
  perform pg_temp.ck(pg_temp.err(format('select booking.admin_delete_annual_card(%s)', v_a3)) = 'annual_card_purchased', 'C3: ostettu kortti → annual_card_purchased');
  perform test.logout();
  perform pg_temp.ck(exists (select 1 from booking.annual_cards where id = v_a3), 'C4: ostettu kortti säilyi');

  -- D) asiakkaalla toinen aktiivinen kortti → tyyppi pysyy annual_card
  perform test.login(v_adm);
  v_a4 := (booking.admin_create_annual_card(v_c3, current_date, current_date + 100, null, null) ->> 'id')::bigint;
  perform booking.admin_create_annual_card(v_c3, current_date + 101, current_date + 300, null, null);
  perform booking.admin_delete_annual_card(v_a4);
  perform test.logout();
  perform pg_temp.ck((select customer_type from booking.customers where id = v_c3) = 'annual_card', 'D1: toinen aktiivinen kortti → tyyppi pysyy');

  -- E) anonyymi ei pääse
  perform test.anon();
  perform pg_temp.ck(pg_temp.err(format('select booking.admin_delete_annual_card(%s)', v_a3)) <> 'NO ERROR', 'E1: anon → virhe');
  perform test.logout();

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t152_r where ok), (select count(*) from t152_r where not ok),
    coalesce((select string_agg(label, ' | ') from t152_r where not ok), 'ALL OK');
end $t$;
