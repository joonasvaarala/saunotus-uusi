-- booking_182: aja fixtures/10_test_helpers.sql:n jälkeen. Kaikki testidata kumotaan.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '90s';
create temp table t182_result(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  insert into t182_result values (coalesce(p_ok,false),p_label)
$$;
create function pg_temp.as_(p_user uuid, p_sql text) returns jsonb language plpgsql as $$
declare v jsonb; d text;
begin
  perform test.login(p_user);
  begin execute p_sql into v;
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err',coalesce(nullif(d,''),sqlstate),'msg',sqlerrm);
  end;
  perform test.logout(); return v;
end $$;
do $t182$
declare
  vrule bigint := test.rule('Miesten sauna%');
  dt date := test.next_dow(1) + 105;
  mgr uuid := test.mk_staff('manager@t182.example.test','manager');
  outsider uuid := test.mk_user('outsider@t182.example.test');
  b jsonb; v jsonb; o bigint; res bigint; parent bigint; addon bigint;
  initial_gross numeric; addon_gross numeric; pay bigint; base_lines bigint; base_fingerprint text;
  new_item bigint; linkpay bigint; left_ numeric;
begin
  perform pg_temp.ck(exists (select 1 from booking.settings where key='admin_order_reservation_flow_enabled' and value='false'::jsonb),
    'S1: ominaisuuskytkin on olemassa ja oletuksena false');
  perform pg_temp.ck(not has_function_privilege('anon','booking.admin_add_to_order(bigint,jsonb,boolean,boolean,text)','execute'),
    'S2: anon ei voi kutsua admin_add_to_order');
  b := test.pub_book(vrule,dt,2,'pay@t182.example.test');
  perform pg_temp.ck(b->>'ok'='true','A0: testivaraus syntyi');
  o := (test.ord((b->>'token')::uuid)).id;
  select id,order_item_id into res,parent from booking.reservations where order_id=o limit 1;
  select id into addon from booking.addons where code='saunavihta';
  select total_gross into initial_gross from booking.orders where id=o;
  v := pg_temp.as_(mgr,format('select booking.admin_record_payment(%s,%L,%s,null,null)',o,'card_terminal',initial_gross));
  perform pg_temp.ck(v->>'ok'='true','A1: tilaus maksettu kokonaan');
  select id into pay from booking.payments where order_id=o and status='paid' order by id desc limit 1;
  select count(*),md5(coalesce(string_agg(row_to_json(pl)::text, '|' order by pl.id),''))
    into base_lines,base_fingerprint from booking.payment_lines pl where payment_id=pay;
  v := pg_temp.as_(mgr,format('select booking.admin_add_to_order(%s,%L::jsonb,false,false,null)',o,
    jsonb_build_array(jsonb_build_object('type','addon','reservation_id',res,'code','saunavihta','quantity',1))::text));
  perform pg_temp.ck(jsonb_array_length(coalesce(v->'added','[]'::jsonb))=1,'A2: maksettuun tilaukseen lisätty addon');
  select id,line_total_gross into new_item,addon_gross from booking.order_items where order_id=o and parent_item_id=parent and addon_id=addon order by id desc limit 1;
  perform pg_temp.ck(new_item is not null and addon_gross > 0,'A3: addon-hinta palvelimelta');
  perform pg_temp.ck((select payment_status from booking.orders where id=o)='partially_paid','A4: maksutila partially_paid');
  perform pg_temp.ck((booking._order_balance(o)->>'unpaid')::numeric=addon_gross,'A5: kattamaton saldo on lisäys');
  perform pg_temp.ck((select count(*) from booking.payment_lines where payment_id=pay)=base_lines and
    (select md5(coalesce(string_agg(row_to_json(pl)::text,'|' order by pl.id),'')) from booking.payment_lines pl where payment_id=pay)=base_fingerprint,
    'A6: aiemmat maksurivit ennallaan');
  perform pg_temp.ck((select payment_status from booking.orders where id=o)='partially_paid' and
    (select total_gross from booking.orders where id=o)=initial_gross+addon_gross,
    'A7: loppusumma alkuperäinen + addon');
  -- Maksulinkki kattaa vain maksamattoman addonin.
  v := pg_temp.as_(mgr,format('select booking.admin_create_payment_link(%s,false,14,null)',o));
  perform pg_temp.ck(v->>'ok'='true','L1: maksulinkki luotiin');
  select id into linkpay from booking.payments where order_id=o and provider='visma_pay' and status='pending' order by id desc limit 1;
  perform pg_temp.ck(linkpay is not null and
    (select amount from booking.payments where id=linkpay)=addon_gross,'L2: maksulinkki vain lisäyksen summalle');
  perform pg_temp.ck((select count(*) from booking.payment_lines where payment_id=linkpay)=1 and
    (select order_item_id from booking.payment_lines where payment_id=linkpay)=new_item,
    'L3: linkin maksurivi vain uudelle addonille');
  -- Vanha funktio suojaa maksettujen rivien vähennystä. Koko alkuperäinen varaus oli maksettu.
  v := pg_temp.as_(mgr,format('select booking.admin_set_reservation_addons(%s,%L::jsonb)',res,'[]'));
  perform pg_temp.ck(v->>'err' in ('addon_link_open','addon_paid'),'R1: maksulinkillä oleva lisäpalvelu lukittu');
  perform pg_temp.ck(exists(select 1 from booking.order_items where id=new_item),'R2: linkitetty rivi säilyy');
  -- Ulkopuolinen, jolta puuttuu bookings.manage.
  v := pg_temp.as_(outsider,format('select booking.admin_add_to_order(%s,%L::jsonb,false,false,null)',o,
    jsonb_build_array(jsonb_build_object('type','addon','reservation_id',res,'code','saunavihta','quantity',1))::text));
  perform pg_temp.ck(v->>'err'='forbidden','P1: bookings.manage puuttuu (BK001)');
  -- Johku: muuta ainoastaan tämän testissä juuri luodun tilauksen lähde hetkeksi.
  update booking.orders set external_source='johku', external_id='t182-example.test' where id=o;
  v := pg_temp.as_(mgr,format('select booking.admin_add_to_order(%s,%L::jsonb,false,false,null)',o,
    jsonb_build_array(jsonb_build_object('type','addon','reservation_id',res,'code','saunavihta','quantity',1))::text));
  perform pg_temp.ck(v->>'err'='order_not_editable','P2: Johku-tilaukseen ei voi lisätä');
end $t182$;
select label,case when ok then 'PASS' else 'FAIL' end status from t182_result order by label;
select format('TESTRESULT pass=%s fail=%s',count(*) filter(where ok), count(*) filter(where not ok)) as testresult from t182_result;
rollback;
