-- t192: hallinnan ylibuukkaus, aikataulun ulkopuolinen varaus, alennuskoodi ja lahjakortti (booking_192).
-- Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN, paikallisessa PG17:ssä.
-- Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken. Tulos: TESTRESULT pass=… fail=…
-- Ei koske tuotantoa. Julkiset RPC:t eivät saa ylibuukata eivätkä ohittaa aikataulua.
set local lock_timeout = '3s';
set local statement_timeout = '90s';
create temp table t192_r(ok boolean, label text) on commit drop;
grant all on t192_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t192_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare v text; begin execute p_sql; return 'NO ERROR'; exception when others then get stacked diagnostics v = pg_exception_detail; return coalesce(nullif(v, ''), sqlerrm); end $$;
do $t$
declare
  v_adm uuid := test.mk_staff('adm192@example.test', 'admin');
  v_staff uuid := test.mk_staff('staff192@example.test', 'staff');
  s record; j jsonb; v_rem int; v_rule bigint; v_date date; v_off date; v_wd int; v_id bigint; v_total numeric; v_disc numeric;
  v_code text := 'KIITOS192'; v_gc text := 'HH192GIFT001'; v_jk text := 'JK192000AB12'; i int;
begin
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_create_booking(bigint,date,integer,bigint,jsonb,text,boolean,text,timestamptz,timestamptz,numeric,text,jsonb,text,text,text,text,boolean,boolean)', 'execute'), 'T1: anon ei saa luoda hallinnan varausta');
  perform pg_temp.ck(has_function_privilege('authenticated', 'booking.admin_check_gift_card(text)', 'execute')
    and has_function_privilege('authenticated', 'booking.admin_preview_discount_code(text,bigint,date,integer,jsonb,numeric,bigint)', 'execute')
    and not has_function_privilege('anon', 'booking._arm_staff_overrides(boolean,boolean,timestamptz,timestamptz)', 'execute'), 'T2: tarkistus authenticatedille, lipun viritys ei anonille');
  perform pg_temp.ck(pg_get_function_identity_arguments('booking.public_create_booking(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb)'::regprocedure) not like '%allow_overbook%'
    and pg_get_function_identity_arguments('booking.public_create_treatment_booking(bigint,timestamptz,integer,text,text,text,boolean,text,text,text,jsonb,text,jsonb)'::regprocedure) not like '%allow_overbook%', 'T3: julkisissa RPC:issä ei ylibuukkausparametria');

  select q.rule_id, q.session_date, q.remaining into v_rule, v_date, v_rem
    from booking.schedule_rules r
    join lateral booking.public_availability(r.product_id, (now() at time zone 'Europe/Helsinki')::date + 2, (now() at time zone 'Europe/Helsinki')::date + 21) q on true
   where r.mode = 'shared' and r.active and q.status = 'available' and q.remaining between 1 and 30
   order by q.session_date, q.rule_id limit 1;
  if v_rule is null then raise exception 'TESTRESULT_ABORT ei vapaata yhteistä vuoroa'; end if;

  perform test.anon();
  perform set_config('booking.allow_overbook', 'on', true);
  perform set_config('booking.allow_off_schedule', 'on', true);
  j := booking.public_create_booking(v_rule, v_date, least(v_rem + 1, 50), 'Julkinen Yli', 'pub192@example.test', '0401112233', false, 'fi', null, 'private', null, null);
  perform pg_temp.ck(coalesce(j ->> 'ok', 'false') <> 'true', 'P1: julkinen varaus ei ylibuukkaa vaikka lippu on päällä: ' || coalesce(j ->> 'code', j ->> 'message', 'ok'));
  perform test.logout();

  perform test.login(v_staff);
  perform set_config('booking.allow_overbook', 'on', true);
  j := booking.public_create_booking(v_rule, v_date, least(v_rem + 1, 50), 'Henkilo Yli', 'staffpub192@example.test', '0401112244', false, 'fi', null, 'private', null, null);
  perform pg_temp.ck(coalesce(j ->> 'ok', 'false') <> 'true', 'P2: henkilökunnan julkinen kutsu ei ylibuukkaa: ' || coalesce(j ->> 'code', 'ok'));
  perform test.logout();

  perform test.login(v_adm);
  perform pg_temp.ck(pg_temp.err(format('select booking.admin_create_booking(p_rule_id := %s, p_date := %L, p_persons := %s, p_customer := %L, p_allow_overbook := false)', v_rule, v_date, least(v_rem + 1, 50), '{"name":"Yli Asiakas","kind":"private"}')) in ('capacity_exceeded', 'persons_max'), 'A1: ilman lippua kapasiteetti estää');
  j := booking.admin_create_booking(p_rule_id := v_rule, p_date := v_date, p_persons := least(v_rem + 1, 50), p_customer := '{"name":"Yli Asiakas","kind":"private"}'::jsonb, p_allow_overbook := true);
  perform pg_temp.ck((j ->> 'reservation_id') is not null, 'A2: lipulla ylibuukkaus onnistuu');
  perform pg_temp.ck((select overbooked and overbooked_by = v_adm from booking.reservations where id = (j ->> 'reservation_id')::bigint), 'A3: varauksella overbooked ja tekijä');
  perform pg_temp.ck(exists (select 1 from booking.audit_log where action = 'STAFF_OVERRIDE' and row_pk = j ->> 'reservation_id' and (new_data ->> 'overbooked')::boolean), 'A4: auditointi');
  perform test.logout();

  perform pg_temp.ck(not exists (select 1 from booking.public_availability((select product_id from booking.schedule_rules where id = v_rule), v_date, v_date) q where q.rule_id = v_rule and q.session_date = v_date and coalesce(q.remaining, 0) < 0), 'P3: julkinen remaining ei ole negatiivinen');
  perform pg_temp.ck((select q.status from booking.public_availability((select product_id from booking.schedule_rules where id = v_rule), v_date, v_date) q where q.rule_id = v_rule and q.session_date = v_date) in ('full', 'unavailable'), 'P4: ylibuukattu vuoro ei näy vapaana');

  select id into v_id from booking.schedule_rules where active and mode = 'shared' and cardinality(weekdays) < 7 order by id limit 1;
  if v_id is not null then
    v_off := (now() at time zone 'Europe/Helsinki')::date + 3;
    for i in 1..14 loop
      v_wd := extract(isodow from v_off)::int;
      exit when not (v_wd::smallint = any ((select weekdays from booking.schedule_rules where id = v_id)::smallint[]));
      v_off := v_off + 1;
    end loop;
    perform test.login(v_adm);
    perform pg_temp.ck(pg_temp.err(format('select booking.admin_create_booking(p_rule_id := %s, p_date := %L, p_persons := 1, p_customer := %L)', v_id, v_off, '{"name":"Sivu Asiakas","kind":"private"}')) = 'no_session', 'S1: ilman lippua väärä viikonpäivä estetään');
    perform test.anon();
    perform set_config('booking.allow_off_schedule', 'on', true);
    j := booking.public_create_booking(v_id, v_off, 1, 'Julkinen Sivu', 'off192@example.test', '0402223344', false, 'fi', null, 'private', null, null);
    perform pg_temp.ck(coalesce(j ->> 'ok', 'false') <> 'true', 'S2: julkinen ei tee vuoroa aikataulun ulkopuolelle');
    perform test.login(v_adm);
    j := booking.admin_create_booking(p_rule_id := v_id, p_date := v_off, p_persons := 1, p_customer := '{"name":"Sivu Asiakas","kind":"private"}'::jsonb, p_allow_off_schedule := true);
    perform pg_temp.ck((select off_schedule and off_schedule_by = v_adm from booking.reservations where id = (j ->> 'reservation_id')::bigint), 'S3: off_schedule ja tekijä');
    perform test.logout();
  end if;

  update booking.settings set value = 'true'::jsonb where key = 'gift_cards.redeem_enabled';
  update booking.settings set value = 'true'::jsonb where key = 'gift_cards.johku_cards_redeemable';
  insert into booking.gift_cards(code, issuer, kind, initial_amount, balance, status, source, vat_treatment, accounting_origin, balance_verified, valid_to)
  values (v_gc, 'own', 'value', 5, 5, 'active', 'native', 'at_redemption', 'native', true, current_date + 100);
  insert into booking.gift_cards(code, issuer, source, accounting_origin, vat_treatment, sale_vat_rate, initial_amount, balance, status, buyer_name, activated_at, valid_to, balance_verified)
  values (v_jk, 'johku', 'johku', 'johku', 'at_sale', 25.5, 80, 80, 'active', 'Johku Ostaja', now(), current_date + 200, true);
  perform test.login(v_adm);
  perform booking.admin_save_discount_code(null, jsonb_build_object('code', v_code, 'kind', 'percent', 'value', '10', 'usage_type', 'permanent', 'target_scope', 'order'));
  j := booking.admin_preview_discount_code(v_code, v_rule, v_date, 1, null, null, null);
  perform pg_temp.ck((j ->> 'ok')::boolean and (j ->> 'discount')::numeric > 0 and j ->> 'type' = 'discount', 'D1: esikatselu käyttää alennusta: ' || coalesce(j ->> 'message', j ->> 'discount'));
  j := booking.admin_check_gift_card(v_gc);
  perform pg_temp.ck((j ->> 'ok')::boolean and (j ->> 'redeemable')::boolean and (j ->> 'balance')::numeric = 5, 'G1: lahjakortin saldo');
  j := booking.admin_check_gift_card(v_jk);
  perform pg_temp.ck((j ->> 'ok')::boolean and j ->> 'source' = 'johku' and (j ->> 'redeemable')::boolean, 'G2: Johku-kortti kelpaa samoin');
  j := booking.admin_create_booking(p_rule_id := v_rule, p_date := v_date, p_persons := 1, p_customer := '{"name":"Ale Asiakas","email":"ale192@example.test","kind":"private"}'::jsonb,
        p_discount_code := v_code, p_gift_card_code := v_gc, p_payment_method := 'gift_card', p_remainder_method := 'pay_later', p_allow_overbook := true);
  v_id := (j ->> 'order_id')::bigint;
  select total_gross, (select sum(discount_amount) from booking.order_items where order_id = v_id) into v_total, v_disc from booking.orders where id = v_id;
  perform pg_temp.ck(v_disc > 0 and (select discount_code_id is not null from booking.orders where id = v_id), 'D2: alennus kirjattu ennen lahjakorttia');
  perform pg_temp.ck(exists (select 1 from booking.payments p join booking.gift_cards g on g.id = p.gift_card_id where p.order_id = v_id and p.method = 'gift_card' and p.status = 'paid' and g.code = v_gc and p.amount <= 5), 'G3: lahjakortti lunastettu');
  perform pg_temp.ck((select balance from booking.gift_cards where code = v_gc) < 5, 'G4: saldo pieneni');
  j := booking.admin_create_booking(p_rule_id := v_rule, p_date := v_date, p_persons := 1, p_customer := '{"name":"Johku Asiakas","kind":"private"}'::jsonb, p_gift_card_code := v_jk, p_payment_method := 'gift_card', p_allow_overbook := true);
  perform pg_temp.ck(exists (select 1 from booking.payments p join booking.gift_cards g on g.id = p.gift_card_id where p.order_id = (j ->> 'order_id')::bigint and g.source = 'johku' and p.status = 'paid'), 'G5: Johku-kortti lunastuu samalla polulla');
  perform pg_temp.ck(pg_temp.err($$select booking.admin_create_booking(p_rule_id := 1, p_date := current_date, p_persons := 1, p_customer := '{"name":"X","kind":"private"}'::jsonb, p_payment_method := 'gift_card')$$) = 'gift_card_code_required', 'G6: lahjakortti ilman koodia');
  perform test.logout();

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t192_r where ok), (select count(*) from t192_r where not ok),
    coalesce((select string_agg(label, ' | ') from t192_r where not ok), 'ALL OK');
end $t$;
