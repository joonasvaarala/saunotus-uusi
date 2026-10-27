-- t189: booking_189. Visma Pay ja MobilePay eivät käynnistä maksua. Englanninkielisen Montonio-kuitin
-- method_label on Pay online. Kassan tenderit palauttavat montonio_mode. Hyvityksen off-ohje ei mainitse Visman portaalia.
-- Aja booking_189:n jälkeen, yhdessä transaktiossa. Lopussa tahallinen TESTRESULT + ROLLBACK.
-- psql -X -v ON_ERROR_STOP=0 -f booking/supabase/tests/checkout/t189_visma_mobilepay_removed.sql
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';
select set_config('t189.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t189.log', coalesce(current_setting('t189.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function pg_temp.svc() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"service_role"}', true); execute 'set local role service_role'; end $$;
create function pg_temp.anon() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon'; end $$;
create function pg_temp.logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
create function pg_temp.call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; s text;
begin execute 'select (' || p_sql || ')::jsonb' into r; return coalesce(r, 'null'::jsonb);
exception when others then get stacked diagnostics d = pg_exception_detail; s := sqlstate;
  return jsonb_build_object('state', s, 'err', case when s = 'BK001' then d else s end, 'msg', sqlerrm);
end $$;

do $t$
declare
  run text := substr(md5(gen_random_uuid()::text), 1, 10);
  u_adm uuid := gen_random_uuid();
  cu bigint; o bigint; pid bigint; rf bigint; n int;
  r jsonb; a1 text; amt numeric; tok uuid; mo_mode text; mo_settings jsonb;
  log text; np int; nf int; ns int;
begin
  select mode, settings into mo_mode, mo_settings from booking.integration_config where key = 'montonio';

  perform pg_temp.ck(md5(pg_get_functiondef('booking.mobilepay_payment_prepare(uuid,uuid,integer,text)'::regprocedure)) = 'c6a64c1ff9353a5e581d72af10966665'
      and md5(pg_get_functiondef('booking.vismapay_payment_prepare(uuid,uuid)'::regprocedure)) = 'd22cda7beb5cea5967b267e52d79ab99'
      and md5(pg_get_functiondef('booking.admin_refund(bigint,numeric,text,jsonb,boolean)'::regprocedure)) = '709d5fd54d877846682571b60c5d21bd'
      and md5(pg_get_functiondef('booking._issue_receipt(bigint)'::regprocedure)) = '1bd426bef2ff856c712749d0a665f2b3'
      and md5(pg_get_functiondef('booking._issue_refund_receipt(bigint)'::regprocedure)) = 'ce97e81bd11e71aa92ba70f9719cae66'
      and md5(pg_get_functiondef('booking.admin_pos_tenders()'::regprocedure)) = '443e6462ede3ec9d3118d08be43759fa', 'A1 md5 = booking_189');
  perform pg_temp.ck((select bool_and(prosecdef and proconfig = array['search_path=""'] and proowner = 'postgres'::regrole)
      from pg_proc where oid in (
        'booking.mobilepay_payment_prepare(uuid,uuid,integer,text)'::regprocedure,
        'booking.vismapay_payment_prepare(uuid,uuid)'::regprocedure,
        'booking.admin_refund(bigint,numeric,text,jsonb,boolean)'::regprocedure,
        'booking._issue_receipt(bigint)'::regprocedure,
        'booking._issue_refund_receipt(bigint)'::regprocedure,
        'booking.admin_pos_tenders()'::regprocedure))
      and (select provolatile from pg_proc where oid = 'booking.admin_pos_tenders()'::regprocedure) = 's', 'A2 SECURITY DEFINER, search_path, omistaja, tenderit STABLE');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.mobilepay_payment_prepare(uuid,uuid,integer,text)', 'execute')
      and not has_function_privilege('authenticated', 'booking.mobilepay_payment_prepare(uuid,uuid,integer,text)', 'execute')
      and has_function_privilege('service_role', 'booking.mobilepay_payment_prepare(uuid,uuid,integer,text)', 'execute')
      and not has_function_privilege('anon', 'booking.vismapay_payment_prepare(uuid,uuid)', 'execute')
      and has_function_privilege('service_role', 'booking.vismapay_payment_prepare(uuid,uuid)', 'execute')
      and not has_function_privilege('anon', 'booking.admin_pos_tenders()', 'execute')
      and has_function_privilege('authenticated', 'booking.admin_pos_tenders()', 'execute')
      and position('Visman portaali' in pg_get_functiondef('booking.admin_refund(bigint,numeric,text,jsonb,boolean)'::regprocedure)) = 0
      and position('kirjaa hyvitys käsin' in pg_get_functiondef('booking.admin_refund(bigint,numeric,text,jsonb,boolean)'::regprocedure)) > 0
      and position('Pay online' in pg_get_functiondef('booking._issue_receipt(bigint)'::regprocedure)) > 0
      and position('Pay online' in pg_get_functiondef('booking._issue_refund_receipt(bigint)'::regprocedure)) > 0
      and position('montonio_mode' in pg_get_functiondef('booking.admin_pos_tenders()'::regprocedure)) > 0, 'A3 oikeudet ja tekstit');

  insert into auth.users(id, email) values (u_adm, 't189-admin-' || run || '@example.test');
  insert into booking.staff(user_id, email, name, role) values (u_adm, 't189-admin-' || run || '@example.test', 't189 admin', 'admin');
  insert into booking.customers(name, email, phone) values ('T189 Asiakas ' || run, 't189-' || run || '@example.test', '+358401890189') returning id into cu;

  select count(*) into n from booking.payments;
  perform pg_temp.svc();
  r := booking.mobilepay_payment_prepare(gen_random_uuid(), null, 120, 'WEB_REDIRECT');
  perform pg_temp.ck(r ->> 'code' = 'payment_not_online' and coalesce((r ->> 'ok')::boolean, false) = false
      and (select count(*) from booking.payments) = n, 'B1 MobilePay-aloitus estetty, ei uutta riviä ' || left(r::text, 80));
  r := booking.mobilepay_payment_prepare(null, gen_random_uuid(), 20, 'QR');
  perform pg_temp.ck(r ->> 'code' = 'payment_not_online' and (select count(*) from booking.payments) = n, 'B2 MobilePay-linkki estetty');
  r := booking.vismapay_payment_prepare(gen_random_uuid(), null);
  perform pg_temp.ck(r ->> 'code' = 'payment_not_online' and (select count(*) from booking.payments) = n, 'B3 Visma-aloitus estetty ' || left(r::text, 80));
  r := booking.vismapay_payment_prepare(null, gen_random_uuid());
  perform pg_temp.ck(r ->> 'code' = 'payment_not_online' and (select count(*) from booking.payments) = n, 'B4 Visma-linkki estetty');
  perform pg_temp.logout();
  perform pg_temp.anon();
  r := pg_temp.call('booking.mobilepay_payment_prepare(null, null, 120, ''WEB_REDIRECT'')');
  perform pg_temp.ck(r ->> 'state' = '42501', 'B5 anon ei kutsu MobilePay-valmistelua');
  r := pg_temp.call('booking.vismapay_payment_prepare(null, null)');
  perform pg_temp.ck(r ->> 'state' = '42501', 'B6 anon ei kutsu Visma-valmistelua');
  perform pg_temp.logout();

  perform pg_temp.login(u_adm);
  r := booking.admin_pos_tenders();
  perform pg_temp.logout();
  perform pg_temp.ck(r ? 'montonio_mode' and r ? 'mobilepay_mode' and r ? 'vismapay_mode' and r ? 'tenders',
      'C1 kassan tenderit: montonio_mode mukana ' || left(r::text, 120));

  insert into booking.integration_config(key, mode, settings) values ('montonio', 'test', '{"approved_by":"t189"}'::jsonb)
    on conflict (key) do update set mode = 'test', settings = booking.integration_config.settings || '{"approved_by":"t189"}'::jsonb;
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_kind)
  values (cu, 'confirmed', 'unpaid', 18, 'admin', 'en', 'private') returning id into o;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o, 'T189 service', 'product', 1, 18, 18, 25.5);
  select public_token into tok from booking.orders where id = o;
  perform pg_temp.svc();
  r := booking.montonio_payment_prepare(tok, null, 'cardPayments');
  a1 := r ->> 'order_number'; amt := (r ->> 'amount')::numeric; pid := (r ->> 'payment_id')::bigint;
  r := booking.montonio_payment_apply(a1, 'paid', amt, jsonb_build_object('uuid', 'uuid-t189-en', 'paymentStatus', 'PAID'));
  perform pg_temp.logout();
  perform pg_temp.ck(coalesce((r ->> 'ok')::boolean, false)
      and (select snapshot -> 'payment' ->> 'method_label' from booking.receipts where order_id = o and kind = 'receipt') = 'Pay online',
      'D1 EN-kuitti method_label Pay online ' || left(coalesce(r::text, ''), 80));
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, lines)
  select pid, o, amt, 't189 refund', 'requested', 'montonio',
         coalesce((select jsonb_agg(jsonb_build_object('payment_line_id', pl.id, 'amount', pl.amount_gross) order by pl.id)
                     from booking.payment_lines pl where pl.payment_id = pid), '[]'::jsonb)
  returning id into rf;
  perform pg_temp.svc();
  r := booking.montonio_refund_complete(rf, 'refund-uuid-t189', jsonb_build_object('refundStatus', 'SUCCESSFUL'));
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true'
      and (select snapshot -> 'payment' ->> 'method_label' from booking.receipts where refund_id = rf and kind = 'refund_receipt') = 'Pay online',
      'D2 EN-hyvityskuitti method_label Pay online ' || left(coalesce(r::text, ''), 80));

  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_kind)
  values (cu, 'confirmed', 'unpaid', 12, 'admin', 'fi', 'private') returning id into o;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o, 'T189 palvelu', 'product', 1, 12, 12, 25.5);
  select public_token into tok from booking.orders where id = o;
  perform pg_temp.svc();
  r := booking.montonio_payment_prepare(tok, null, 'paymentInitiation');
  a1 := r ->> 'order_number'; amt := (r ->> 'amount')::numeric;
  r := booking.montonio_payment_apply(a1, 'paid', amt, jsonb_build_object('uuid', 'uuid-t189-fi', 'paymentStatus', 'PAID'));
  perform pg_temp.logout();
  perform pg_temp.ck(coalesce((r ->> 'ok')::boolean, false)
      and (select snapshot -> 'payment' ->> 'method_label' from booking.receipts where order_id = o and kind = 'receipt') = 'Maksa verkossa',
      'D3 FI-kuitti method_label Maksa verkossa ' || left(coalesce(r::text, ''), 80));

  if mo_mode is null then delete from booking.integration_config where key = 'montonio';
  else update booking.integration_config set mode = mo_mode, settings = mo_settings where key = 'montonio'; end if;

  log := current_setting('t189.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  ns := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'S %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% skip=% %', np, nf, ns, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
