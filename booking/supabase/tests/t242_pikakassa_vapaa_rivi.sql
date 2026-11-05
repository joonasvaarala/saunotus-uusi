-- t242: pikakassan vapaa rivi (booking_242). Ajo migraation jälkeen. Lopussa TESTRESULT + ROLLBACK.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t242.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t242.log', coalesce(current_setting('t242.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;

create function pg_temp.try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then
  get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate;
  return case when s = 'BK001' then d else s || ':' || left(m, 160) end;
end $$;

create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;

create function pg_temp.logout() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

do $t$
declare
  u_staff uuid := gen_random_uuid();
  p_vichy bigint;
  items jsonb; res jsonb; oid bigint; log text; np int; nf int;
  v_kind text; v_pid bigint; v_name text; v_qty int; v_price numeric; v_vat numeric; v_total numeric;
  v_lines jsonb; v_snap jsonb; v_body text; v_pay bigint; v_rc bigint; n_custom int;
begin
  insert into kb.products(name, name_en, category, price, vat_rate, active)
  values ('Vichy t242', 'Vichy t242 EN', 'other', 3.00, 13.5, true) returning id into p_vichy;
  insert into booking.product_config(product_id, sale_kind, bookable, pos_enabled, pos_sort, fridge_sale)
  values (p_vichy, 'other', false, true, 10, false);

  insert into auth.users(id, email) values (u_staff, 't242-staff@example.test');
  insert into booking.staff(user_id, email, name, role)
  values (u_staff, 't242-staff@example.test', 't242 staff', 'staff');

  perform pg_temp.login(u_staff);

  -- Vanha product-muoto toimii
  res := booking.admin_pos_checkout(jsonb_build_array(jsonb_build_object('product_id', p_vichy, 'quantity', 1)), 'fi', null);
  perform pg_temp.ck(res->>'ok' = 'true' and (res->>'total')::numeric = 3, 'A1 vanha product-muoto');

  -- Pelkkä 0 € vapaa rivi → nothing_to_pay
  perform pg_temp.ck(
    pg_temp.try(format(
      'select booking.admin_pos_checkout(%L::jsonb, ''fi'', null)',
      jsonb_build_array(jsonb_build_object('kind','custom','description','Ilmainen','quantity',1,'unit_price',0,'vat_rate',25.5))
    )) = 'nothing_to_pay', 'A2 pelkkä 0e vapaa → nothing_to_pay');

  -- Vapaa rivi + tuote
  items := jsonb_build_array(
    jsonb_build_object('product_id', p_vichy, 'quantity', 1),
    jsonb_build_object('kind','custom','description','  Pyyhevuokra  ','quantity',2,'unit_price',5.5,'vat_rate',25.5)
  );
  res := booking.admin_pos_checkout(items, 'fi', null);
  oid := (res->>'order_id')::bigint;
  perform pg_temp.ck(res->>'ok' = 'true' and (res->>'total')::numeric = 14, 'B1 total 3+11');
  select kind, product_id, product_name, quantity, unit_price_gross, vat_rate, line_total_gross
    into v_kind, v_pid, v_name, v_qty, v_price, v_vat, v_total
    from booking.order_items where order_id = oid and kind = 'custom';
  perform pg_temp.ck(v_kind = 'custom' and v_pid is null and v_name = 'Pyyhevuokra' and v_qty = 2 and v_price = 5.5 and v_vat = 25.5 and v_total = 11, 'B2 custom-rivi tallessa');
  perform pg_temp.ck((select count(*) from booking.order_items where order_id = oid and kind = 'product') = 1, 'B3 product-rivi mukana');
  perform pg_temp.ck((select count(*) from jsonb_array_elements(res->'lines') e where e->>'kind' = 'custom') = 1, 'B4 vastauksen lines.kind=custom');

  -- unit_price_cents
  res := booking.admin_pos_checkout(jsonb_build_array(
    jsonb_build_object('kind','custom','description','Senttihinta','quantity',1,'unit_price_cents',199,'vat_rate',13.5),
    jsonb_build_object('product_id', p_vichy, 'quantity', 1)
  ), 'fi', null);
  oid := (res->>'order_id')::bigint;
  perform pg_temp.ck((res->>'total')::numeric = 4.99, 'C1 cents → 1.99 + 3');
  perform pg_temp.ck((select unit_price_gross from booking.order_items where order_id = oid and kind = 'custom') = 1.99, 'C2 unit 1.99');

  -- Validointivirheet
  perform pg_temp.ck(pg_temp.try(format(
    'select booking.admin_pos_checkout(%L::jsonb,''fi'',null)',
    jsonb_build_array(jsonb_build_object('kind','custom','description','','quantity',1,'unit_price',1,'vat_rate',25.5),
                      jsonb_build_object('product_id', p_vichy, 'quantity', 1))
  )) = 'invalid_items', 'D1 tyhjä kuvaus');
  perform pg_temp.ck(pg_temp.try(format(
    'select booking.admin_pos_checkout(%L::jsonb,''fi'',null)',
    jsonb_build_array(jsonb_build_object('kind','custom','description', repeat('x',201),'quantity',1,'unit_price',1,'vat_rate',25.5),
                      jsonb_build_object('product_id', p_vichy, 'quantity', 1))
  )) = 'invalid_items', 'D2 kuvaus >200');
  perform pg_temp.ck(pg_temp.try(format(
    'select booking.admin_pos_checkout(%L::jsonb,''fi'',null)',
    jsonb_build_array(jsonb_build_object('kind','custom','description','x','quantity',1,'unit_price',-1,'vat_rate',25.5),
                      jsonb_build_object('product_id', p_vichy, 'quantity', 1))
  )) = 'invalid_items', 'D3 negatiivinen hinta');
  perform pg_temp.ck(pg_temp.try(format(
    'select booking.admin_pos_checkout(%L::jsonb,''fi'',null)',
    jsonb_build_array(jsonb_build_object('kind','custom','description','x','quantity',1,'unit_price',1,'vat_rate',10),
                      jsonb_build_object('product_id', p_vichy, 'quantity', 1))
  )) = 'invalid_vat', 'D4 vanha ALV 10%');
  perform pg_temp.ck(pg_temp.try(format(
    'select booking.admin_pos_checkout(%L::jsonb,''fi'',null)',
    jsonb_build_array(jsonb_build_object('kind','custom','description','x','quantity',0,'unit_price',1,'vat_rate',25.5),
                      jsonb_build_object('product_id', p_vichy, 'quantity', 1))
  )) = 'invalid_items', 'D5 quantity 0');
  perform pg_temp.ck(pg_temp.try(format(
    'select booking.admin_pos_checkout(%L::jsonb,''fi'',null)',
    jsonb_build_array(jsonb_build_object('product_id', p_vichy, 'quantity', 1, 'unit_price', 1))
  )) = 'price_locked', 'D6 product+hinta yhä lukittu');

  -- 0 € vapaa rivin kanssa maksettavaa → ok; invoice ohittaa 0 € rivit
  res := booking.admin_pos_checkout(jsonb_build_array(
    jsonb_build_object('product_id', p_vichy, 'quantity', 1),
    jsonb_build_object('kind','custom','description','Ilmainen lisä','quantity',1,'unit_price',0,'vat_rate',0)
  ), 'fi', null);
  oid := (res->>'order_id')::bigint;
  perform pg_temp.ck((res->>'total')::numeric = 3, 'E1 0e custom + tuote ok');
  perform pg_temp.ck((select count(*) from booking.order_items where order_id = oid and kind = 'custom' and line_total_gross = 0) = 1, 'E2 0e custom tallessa');

  -- Kuitti: maksa → _issue_receipt sisältää custom-kuvauksen
  res := booking.admin_pos_checkout(jsonb_build_array(
    jsonb_build_object('kind','custom','description','Kuittirivi','quantity',1,'unit_price',10,'vat_rate',25.5)
  ), 'fi', null);
  oid := (res->>'order_id')::bigint;
  perform booking.admin_record_payment(oid, 'card_terminal', (res->>'total')::numeric);
  select id into v_pay from booking.payments where order_id = oid order by id desc limit 1;
  select id into v_rc from booking.receipts where payment_id = v_pay and kind = 'receipt' limit 1;
  perform pg_temp.ck(v_rc is not null, 'F1 kuitti syntyi');
  select snapshot, text_body into v_snap, v_body from booking.receipts where id = v_rc;
  perform pg_temp.ck(exists (
    select 1 from jsonb_array_elements(v_snap->'lines') e where e->>'description' like '%Kuittirivi%'
  ), 'F2 snapshot description');
  perform pg_temp.ck(position('Kuittirivi' in coalesce(v_body,'')) > 0, 'F3 text_body description');

  -- admin_get_order / admin_pos_status näyttävät rivin
  res := booking.admin_pos_status(oid);
  perform pg_temp.ck(exists (
    select 1 from jsonb_array_elements(res->'lines') e where e->>'name' = 'Kuittirivi'
  ), 'G1 pos_status name');
  res := booking.admin_get_order(oid);
  perform pg_temp.ck(exists (
    select 1 from jsonb_array_elements(res->'items') e
     where e->>'kind' = 'custom' and e->>'name' = 'Kuittirivi' and e->>'product_id' is null
  ), 'G2 get_order custom item');

  -- Kind-check sisältää customin
  perform pg_temp.ck(exists (
    select 1 from pg_constraint c
     where c.conrelid = 'booking.order_items'::regclass and c.conname = 'order_items_kind_check'
       and pg_get_constraintdef(c.oid) like '%custom%'
  ), 'H1 kind_check has custom');

  perform pg_temp.logout();

  log := current_setting('t242.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% %', np, nf, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end
$t$;
rollback;
