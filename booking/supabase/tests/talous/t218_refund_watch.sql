-- t218: booking_218 hyvitysten seuranta ja käsin kirjattu hyvitys.
-- Aja migraatioiden jälkeen. Yksi transaktio, lopussa TESTRESULT + ROLLBACK.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t218.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t218.log', coalesce(current_setting('t218.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 180) end;
end $$;
create function pg_temp.call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then return jsonb_build_object('err', pg_temp.try(p_sql));
end $$;
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function pg_temp.logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;

do $t$
declare
  u_ad uuid := gen_random_uuid();
  u_st uuid := gen_random_uuid();
  cu bigint; o bigint; p bigint; pl bigint; f bigint; o2 bigint; p2 bigint; f2 bigint;
  oj bigint; pj bigint; fj bigint;
  r jsonb; n int; log text; np int; nf int;
begin
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_list_open_refunds(text)', 'execute')
      and not has_function_privilege('anon', 'booking.admin_record_manual_refund(bigint,numeric,date,text,text)', 'execute')
      and has_function_privilege('authenticated', 'booking.admin_list_open_refunds(text)', 'execute'), 'A1 oikeudet');

  insert into auth.users(id, email) values
    (u_ad, 't218-admin@example.test'), (u_st, 't218-staff@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_ad, 't218-admin@example.test', 't218 admin', 'admin'),
    (u_st, 't218-staff@example.test', 't218 staff', 'staff');
  delete from booking.role_permissions where role_code = 'admin' and permission = 'bookings.manage';
  delete from booking.role_permissions where role_code = 'staff' and permission = 'bookings.manage';

  insert into booking.customers(name, email) values ('T218 Asiakas', 't218@example.test') returning id into cu;
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, confirmed_at)
  values (cu, 'confirmed', 'paid', 58, 'admin', 'fi', '2032-06-01 10:00:00+00') returning id into o;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o, 'T218 vuoro', 'reservation', 2, 29, 58, 25.5);
  alter table booking.payments disable trigger payments_paid_ins;
  alter table booking.payments disable trigger payments_paid_upd;
  insert into booking.payments(order_id, method, provider, status, amount, paid_at)
  values (o, 'montonio', 'montonio', 'paid', 58, '2032-06-02 12:00:00+00') returning id into p;
  insert into booking.payment_lines(payment_id, description, kind, quantity, amount_gross, vat_rate)
  values (p, 'T218 vuoro', 'reservation', 2, 58, 25.5) returning id into pl;
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, provider_status, lines, created_at, updated_at)
  values (p, o, 58, 'Jumissa', 'processing', 'montonio', 'PENDING', jsonb_build_array(jsonb_build_object('payment_line_id', pl, 'amount', 58)), now() - interval '30 hours', now() - interval '30 hours')
  returning id into f;

  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale)
  values (cu, 'confirmed', 'paid', 20, 'admin', 'fi') returning id into o2;
  insert into booking.payments(order_id, method, provider, status, amount, paid_at)
  values (o2, 'montonio', 'montonio', 'paid', 20, now() - interval '2 hours') returning id into p2;
  insert into booking.payment_lines(payment_id, description, kind, quantity, amount_gross, vat_rate)
  values (p2, 'T218 tuore', 'reservation', 1, 20, 25.5);
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, lines)
  values (p2, o2, 20, 'Tuore', 'requested', 'montonio', jsonb_build_array(jsonb_build_object('payment_line_id', (select id from booking.payment_lines where payment_id = p2), 'amount', 20)))
  returning id into f2;

  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, external_source, external_id, johku_order_no)
  values (cu, 'confirmed', 'paid', 10, 'johku_import', 'fi', 'johku', 't218-johku', 880218) returning id into oj;
  insert into booking.payments(order_id, method, provider, status, amount, paid_at, external_source, external_id)
  values (oj, 'montonio', 'johku', 'paid', 10, now(), 'johku', 't218-jpay') returning id into pj;
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, lines)
  values (pj, oj, 10, 'Johku', 'failed', 'montonio', '[]'::jsonb) returning id into fj;
  alter table booking.payments enable trigger payments_paid_ins;
  alter table booking.payments enable trigger payments_paid_upd;

  perform pg_temp.login(u_st);
  perform pg_temp.ck(pg_temp.try('select booking.admin_list_open_refunds(null)') = 'forbidden', 'B1 staff ilman bookings.manage');
  perform pg_temp.logout();

  perform pg_temp.login(u_ad);
  r := pg_temp.call('booking.admin_list_open_refunds(null)');
  perform pg_temp.ck(r ->> 'err' is null, 'B2 admin ilman bookings.manage-oikeutta näkee listan: ' || coalesce(r ->> 'err', 'ok'));
  perform pg_temp.ck((r ->> 'total')::int >= 2, 'B3 vähintään kaksi natiivia');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(r -> 'rows') x where (x ->> 'refund_id')::bigint = fj), 'B4 Johku ei listalla');
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(r -> 'rows') x where (x ->> 'refund_id')::bigint = f and (x ->> 'aging')::boolean), 'B5 yli 24 h on aging');
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(r -> 'rows') x where (x ->> 'refund_id')::bigint = f2 and (x ->> 'aging')::boolean = false), 'B6 tuore ei ole aging');

  r := pg_temp.call(format('booking.admin_retry_provider_refund(%s)', f));
  perform pg_temp.ck(r ->> 'status' = 'requested' and (select status from booking.refunds where id = f) = 'requested', 'C1 uudelleenyritys jonoon: ' || coalesce(r ->> 'err', r ->> 'status'));
  perform pg_temp.ck(exists (select 1 from booking.audit_log where action = 'REFUND_RETRY' and row_pk = f::text and actor = u_ad), 'C2 audit retry');

  r := pg_temp.call(format($q$booking.admin_record_manual_refund(%s, 58, '2032-06-03', 'portal-t218', 'Hyvitetty portaalissa')$q$, f));
  perform pg_temp.ck(r ->> 'status' = 'done' and r ->> 'receipt_no' is not null, 'D1 käsinkirjaus tekee hyvityskuitin: ' || coalesce(r ->> 'err', r::text));
  perform pg_temp.ck((select status from booking.refunds where id = f) = 'done'
      and (select provider_status from booking.refunds where id = f) = 'manual_done'
      and (select provider_refund_id from booking.refunds where id = f) = 'portal-t218', 'D2 tila ja viite');
  perform pg_temp.ck((select status from booking.payments where id = p) = 'refunded', 'D3 maksu refunded');
  perform pg_temp.ck((select (issued_at at time zone 'Europe/Helsinki')::date from booking.receipts where refund_id = f) = '2032-06-03', 'D4 kuitin päivä on hyvityspäivä');
  perform pg_temp.ck(exists (select 1 from booking.audit_log where action = 'MANUAL_REFUND' and row_pk = f::text and actor = u_ad and new_data ->> 'note' = 'Hyvitetty portaalissa'), 'D5 audit henkilökunta');
  select count(*) into n from booking.receipts where refund_id = f;
  perform pg_temp.ck(n = 1, 'D6 yksi hyvityskuitti');
  r := pg_temp.call(format($q$booking.admin_record_manual_refund(%s, 58, '2032-06-03', 'portal-t218', 'Uudelleen')$q$, f));
  perform pg_temp.ck((r ->> 'already')::boolean, 'D7 toinen kirjaus ei tee toista kuittia');
  perform pg_temp.ck(pg_temp.try(format($q$select booking.admin_record_manual_refund(%s, 99, '2032-06-03', 'x', 'Liikaa rahaa')$q$, f2)) = 'amount_exceeds_refundable', 'D8 liian suuri summa');
  perform pg_temp.logout();

  log := current_setting('t218.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% %', np, nf, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
