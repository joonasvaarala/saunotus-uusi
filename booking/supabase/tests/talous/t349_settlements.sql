begin;
-- t349: tilitykset ja CSV-tuonti (K9). booking_349, 25.11.2026.
-- Vaatii migraation 349 + fixtures/10_test_helpers.sql. Yksi transaktio; lopuksi rollback. Ei ulkoisia kutsuja.
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t349_r(ok boolean, label text) on commit drop;
grant all on t349_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t349_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare d text; begin execute p_sql; return 'no error'; exception when others then get stacked diagnostics d = pg_exception_detail; return coalesce(d, sqlerrm) || ' :: ' || sqlerrm; end $$;
do $t$
declare
  u_adm uuid := test.mk_staff('adm@t349.example', 'admin');
  u_mgr uuid := test.mk_staff('mgr@t349.example', 'manager');
  u_stf uuid := test.mk_staff('stf@t349.example', 'staff');
  o1 bigint; o2 bigint; o3 bigint; p1 bigint; p2 bigint; p3 bigint; f1 bigint; csv text; v jsonb; s_id bigint; e text; st jsonb;
begin
  insert into booking.orders default values returning id into o1;
  insert into booking.orders default values returning id into o2;
  insert into booking.orders default values returning id into o3;
  insert into booking.payments(order_id, method, provider, provider_ref, status, amount, raw) values (o1, 'montonio', 'montonio', 'sauna-t349-a', 'pending', 50, '{"order_uuid":"uuid-t349-a"}') returning id into p1;
  insert into booking.payments(order_id, method, provider, provider_ref, status, amount, raw) values (o2, 'montonio', 'montonio', 'sauna-t349-b', 'pending', 30, '{"order_uuid":"uuid-t349-b"}') returning id into p2;
  insert into booking.payments(order_id, method, provider, provider_ref, status, amount, raw) values (o3, 'montonio', 'montonio', 'sauna-t349-c', 'pending', 20, '{}') returning id into p3;
  update booking.payments set provider_fee = 0.99 where id = p3;
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, provider_refund_id) values (p2, o2, 10, 'testi', 'processing', 'montonio', 'rf-t349-1') returning id into f1;
  update booking.integration_config set settings = settings || jsonb_build_object('accounts', coalesce(settings -> 'accounts', '{}'::jsonb) || '{"provider_fee":"8460"}'::jsonb) where key = 'procountor';

  csv := E'\uFEFFerä;päivä;laji;viite;brutto;kulu;netto\r\n'
      || E'T349-1;2026-11-20;maksu;sauna-t349-a;50,00;0,85;49,15\r\n'
      || E'T349-1;2026-11-20;maksu;uuid-t349-b;30,00;0,60;29,40\r\n'
      || E'T349-1;2026-11-20;hyvitys;rf-t349-1;-10,00;0,10;-10,10\r\n'
      || E'T349-1;2026-11-20;maksu;sauna-t349-c;20,00;0,45;19,55\r\n'
      || E'T349-1;2026-11-20;maksu;tuntematon-1;5,00;0,15;4,85\r\n'
      || E'T349-1;2026-11-20;kulu;kk-maksu;0;4,90;-4,90\r\n';
  -- oikeudet
  perform test.login(u_stf);
  e := pg_temp.err(format('select booking.admin_import_settlement_csv(%L, %L)', 'montonio', csv));
  perform pg_temp.ck(e like '%forbidden%', 'A1: henkilökunta ei saa tuoda ' || e);
  e := pg_temp.err('select booking.admin_list_settlements(''2026-11-01'', ''2026-11-30'')');
  perform pg_temp.ck(e like '%forbidden%', 'A2: henkilökunta ei näe tilityksiä ' || e);
  perform test.logout();
  -- esikatselu
  perform test.login(u_adm);
  v := booking.admin_import_settlement_csv('montonio', csv, 'tilitys.csv');
  perform test.logout();
  perform pg_temp.ck((v ->> 'dry_run')::boolean and (v ->> 'rows')::int = 6 and not exists (select 1 from booking.settlements), 'B1: oletuksena esikatselu, ei tallennusta ' || v::text);
  perform pg_temp.ck(v #>> '{batches,0,batch}' = 'T349-1' and (v #>> '{batches,0,gross}')::numeric = 95 and (v #>> '{batches,0,fee}')::numeric = 7.05 and (v #>> '{batches,0,net}')::numeric = 87.95, 'B2: erän summat 95 / 7,05 / 87,95 ' || (v -> 'batches')::text);
  perform pg_temp.ck((v #>> '{batches,0,payments}')::int = 4 and (v #>> '{batches,0,refunds}')::int = 1 and (v #>> '{batches,0,other}')::int = 1 and (v #>> '{batches,0,matched}')::int = 4 and (v #>> '{batches,0,unmatched}')::int = 1, 'B3: määrät 4/1/1, kohdistettu 4, ei 1');
  perform pg_temp.ck(jsonb_array_length(v -> 'unmatched') = 1 and v #>> '{unmatched,0,reference}' = 'tuntematon-1', 'B4: kohdistamaton rivi listattu');
  perform pg_temp.ck(v ->> 'fee_account' = '8460' and v ->> 'fee_posting' = 'not_posted', 'B5: kulutili asetuksista, ei kirjata');
  perform pg_temp.ck(jsonb_array_length(v -> 'fee_conflicts') = 1 and (v #>> '{fee_conflicts,0,payment_id}')::bigint = p3, 'B6: ristiriita maksulla, jolla jo eri kulu');
  perform pg_temp.ck((select provider_fee from booking.payments where id = p1) is null, 'B7: esikatselu ei täytä kulua');
  -- tuonti
  perform test.login(u_adm);
  v := booking.admin_import_settlement_csv('montonio', csv, 'tilitys.csv', false);
  perform test.logout();
  perform pg_temp.ck((v ->> 'imported')::boolean and (v ->> 'fees_set')::int = 3 and (v ->> 'fee_conflicts_kept')::int = 1, 'C1: tuotu, kuluja täytetty 3, ristiriita 1 ' || v::text);
  perform pg_temp.ck((select provider_fee from booking.payments where id = p1) = 0.85 and (select provider_fee from booking.payments where id = p2) = 0.60, 'C2: payments.provider_fee täytetty (viite ja order_uuid)');
  perform pg_temp.ck((select provider_fee from booking.payments where id = p3) = 0.99, 'C3: olemassa olevaa eri kulua ei ylikirjoiteta');
  perform pg_temp.ck((select provider_fee from booking.refunds where id = f1) = 0.10, 'C4: refunds.provider_fee täytetty');
  select id into s_id from booking.settlements where provider = 'montonio' and batch_ref = 'T349-1';
  perform pg_temp.ck((select settled_on = '2026-11-20' and gross = 95 and fee = 7.05 and net = 87.95 and payment_count = 4 and fee_account = '8460' and not posted and source_filename = 'tilitys.csv' from booking.settlements where id = s_id), 'C5: erärivi');
  perform pg_temp.ck((select count(*) from booking.settlement_items where settlement_id = s_id) = 6
                     and (select fee_applied from booking.settlement_items where settlement_id = s_id and payment_id = p3) = 'conflict'
                     and (select match_status from booking.settlement_items where settlement_id = s_id and reference = 'tuntematon-1') = 'unmatched'
                     and (select match_status from booking.settlement_items where settlement_id = s_id and kind = 'fee') = 'not_applicable', 'C6: rivit ja tilat');
  perform pg_temp.ck(exists (select 1 from booking.audit_log where action = 'SETTLEMENT_IMPORTED' and row_pk = s_id::text), 'C7: audit');
  perform test.login(u_adm);
  e := pg_temp.err(format('select booking.admin_import_settlement_csv(%L, %L, null, false)', 'montonio', csv));
  perform pg_temp.ck(e like '%settlement_exists%', 'C8: samaa erää ei tuoda kahdesti ' || e);
  -- listaus ja yksittäinen
  v := booking.admin_list_settlements('2026-11-01', '2026-11-30');
  perform pg_temp.ck(jsonb_array_length(v -> 'rows') = 1 and (v #>> '{totals,fee}')::numeric = 7.05 and v ->> 'fee_account' = '8460', 'D1: listaus ' || (v -> 'totals')::text);
  v := booking.admin_get_settlement(s_id);
  perform pg_temp.ck(jsonb_array_length(v -> 'items') = 6 and not v ? 'imported_by', 'D2: erä riveineen');
  perform test.logout();
  -- manageri: listaus kyllä, tuonti (settings.edit) kyllä
  perform test.login(u_mgr);
  v := booking.admin_list_settlements('2026-11-01', '2026-11-30');
  perform pg_temp.ck(jsonb_array_length(v -> 'rows') = 1, 'D3: manageri näkee');
  -- ylikirjoitus
  csv := E'batch_id,settled_on,type,reference,payment_id,gross,fee,net\n'
      || E'T349-2,21.11.2026,payment,,' || p3 || E',20.00,0.45,19.55\n';
  v := booking.admin_import_settlement_csv('montonio', csv, null, false, true);
  perform test.logout();
  perform pg_temp.ck((select provider_fee from booking.payments where id = p3) = 0.45 and (v ->> 'fees_set')::int = 1, 'E1: pilkkuerotin, payment_id, päivä pp.kk.vvvv, ylikirjoitus ' || v::text);
  perform pg_temp.ck((select settled_on from booking.settlements where batch_ref = 'T349-2') = '2026-11-21', 'E2: päivä luettu');
  perform test.logout();
  -- virheet: kaikki tai ei mitään
  perform test.login(u_adm);
  e := pg_temp.err(format('select booking.admin_import_settlement_csv(%L, %L, null, false)', 'montonio', E'erä;päivä;laji;brutto;kulu;netto\nX;2026-11-20;maksu;10;1;8\n'));
  perform pg_temp.ck(e like '%settlement_csv_invalid%', 'F1: netto ≠ brutto − kulu ' || e);
  e := pg_temp.err(format('select booking.admin_import_settlement_csv(%L, %L, null, false)', 'montonio', E'erä;päivä;viite;brutto\nX;2026-11-20;a;10\n'));
  perform pg_temp.ck(e like '%settlement_csv_invalid%', 'F2: pakollinen sarake puuttuu ' || e);
  e := pg_temp.err(format('select booking.admin_import_settlement_csv(%L, %L, null, false)', 'montonio', E'erä;päivä;laji;brutto;kulu\nX;2026-11-20;maksu;10;1\nX;2026-11-21;maksu;5;1\n'));
  perform pg_temp.ck(e like '%eri päiviltä%', 'F3: erän rivit eri päiviltä ' || e);
  e := pg_temp.err(format('select booking.admin_import_settlement_csv(%L, %L, null, false)', 'montonio', E'erä;päivä;laji;brutto;kulu\nX;2026-11-20;outo;10;1\n'));
  perform pg_temp.ck(e like '%tuntematon laji%', 'F4: tuntematon laji ' || e);
  e := pg_temp.err(format('select booking.admin_import_settlement_csv(%L, %L, null, false)', 'montonio', E'erä;päivä;laji;brutto;kulu\nX;2026-11-20;maksu;abc;1\n'));
  perform pg_temp.ck(e like '%Luku ei kelpaa%', 'F5: kelvoton luku ' || e);
  e := pg_temp.err(format('select booking.admin_import_settlement_csv(%L, %L, null, false)', 'montonio', E'erä;päivä;laji;viite;brutto;kulu\nY;2026-11-20;maksu;"sauna-t349-a";"1 234,50";"1,00"\nY;2026-11-20;maksu;x;-1;0\n'));
  perform test.logout();
  perform pg_temp.ck(e like '%positiivinen%' and not exists (select 1 from booking.settlements where batch_ref = 'Y'), 'F6: virhe kumoaa koko tuonnin ' || e);
  perform test.login(u_adm);
  e := pg_temp.err(format('select booking.admin_import_settlement_csv(%L, %L, null, false)', 'manual', E'erä;päivä;laji;brutto;kulu\nZ;2026-11-20;maksu;1;0\n'));
  perform pg_temp.ck(e like '%invalid_param%', 'F7: manual ei käy ' || e);
  perform test.logout();
  -- numerot ja CSV-jäsennys
  perform pg_temp.ck(booking._settlement_num('1 234,56') = 1234.56 and booking._settlement_num('1.234,56') = 1234.56 and booking._settlement_num('1,234.56') = 1234.56
                     and booking._settlement_num('-0,5') = -0.5 and booking._settlement_num('12 €') = 12 and booking._settlement_num('') is null, 'G1: lukumuodot');
  v := booking._settlement_parse_csv(E'erä;päivä;laji;viite;brutto;kulu\nA;2026-11-20;maksu;"x;""y""";1;0\n\n');
  perform pg_temp.ck(v #>> '{0,reference}' = 'x;"y"' and jsonb_array_length(v) = 1, 'G2: lainausmerkit ja tyhjät rivit ' || v::text);
  -- asetukset: accounts.provider_fee
  perform test.login(u_adm);
  st := booking.admin_get_procountor_settings();
  perform pg_temp.ck(st #>> '{accounts,provider_fee}' = '8460', 'H1: get palauttaa provider_fee ' || coalesce(st #>> '{accounts}', 'null'));
  e := pg_temp.err(format('select booking.admin_set_procountor_settings(%L::jsonb)', jsonb_set(st, '{accounts,provider_fee}', '"84 60"')::text));
  perform pg_temp.ck(e like '%invalid_setting%', 'H2: kelvoton tili hylätään ' || e);
  perform booking.admin_set_procountor_settings(jsonb_set(st, '{accounts,provider_fee}', '"8470"'));
  st := booking.admin_get_procountor_settings();
  perform pg_temp.ck(st #>> '{accounts,provider_fee}' = '8470' and st #>> '{daily_enabled}' is distinct from 'true', 'H3: tallennus ja luku, daily ei päälle ' || coalesce(st::text, 'null'));
  -- vanha lomake ilman avainta säilyttää arvon; oma kutsu vaihtaa vain tilin
  perform booking.admin_set_procountor_settings(st #- '{accounts,provider_fee}');
  perform pg_temp.ck(booking.admin_get_procountor_settings() #>> '{accounts,provider_fee}' = '8470', 'H4: puuttuva avain säilyttää arvon');
  v := booking.admin_set_provider_fee_account(' 8480 ');
  st := booking.admin_get_procountor_settings();
  perform pg_temp.ck(v ->> 'provider_fee' = '8480' and st #>> '{accounts,provider_fee}' = '8480' and st ->> 'mode' is not distinct from 'off', 'H5: admin_set_provider_fee_account ' || st::text);
  e := pg_temp.err('select booking.admin_set_provider_fee_account(''x-1'')');
  perform pg_temp.ck(e like '%invalid_setting%', 'H6: kelvoton tili ' || e);
  perform test.logout();
  perform test.login(u_stf);
  e := pg_temp.err('select booking.admin_set_provider_fee_account(''8490'')');
  perform pg_temp.ck(e like '%forbidden%', 'H7: henkilökunta ei saa asettaa ' || e);
  perform test.logout();
  -- svc
  perform pg_temp.ck(not has_function_privilege('authenticated', 'booking.svc_import_settlement_csv(text,text,text,boolean,boolean,text)', 'execute')
                     and has_function_privilege('service_role', 'booking.svc_import_settlement_csv(text,text,text,boolean,boolean,text)', 'execute')
                     and not has_function_privilege('authenticated', 'booking._settlement_import(text,text,text,boolean,boolean,text)', 'execute')
                     and not has_table_privilege('authenticated', 'booking.settlements', 'select') and not has_table_privilege('anon', 'booking.settlement_items', 'select'), 'I1: oikeudet');
  perform test.service();
  v := booking.svc_import_settlement_csv('montonio', E'erä;päivä;laji;brutto;kulu\nS;2026-11-22;kulu;0;1,5\n');
  perform pg_temp.ck((v ->> 'dry_run')::boolean and (v #>> '{batches,0,net}')::numeric = -1.5, 'I2: svc esikatselu ' || v::text);
  perform test.logout();
  perform pg_temp.ck(position('procountor_daily' in pg_get_functiondef('booking._settlement_import'::regproc)) = 0 and position('net.http' in pg_get_functiondef('booking._settlement_import'::regproc)) = 0 and position('outbox' in pg_get_functiondef('booking._settlement_import'::regproc)) = 0, 'I3: ei Procountor-, HTTP- eikä outbox-kutsuja');
end $t$;
do $r$
declare n int; f text;
begin
  select count(*), string_agg(label, ' | ') filter (where not ok) into n, f from t349_r;
  raise notice 'TESTRESULT pass=% fail=% %', n - (select count(*) from t349_r where not ok), (select count(*) from t349_r where not ok), coalesce(f, ':: ALL OK');
end $r$;
rollback;
