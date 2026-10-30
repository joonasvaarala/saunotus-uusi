-- t188: booking_188 verkkomaksu (Montonio / Stargate Orders API).
-- Ajaa migraation JÄLKEEN, yhdessä transaktiossa. Lopussa tahallinen TESTRESULT + ROLLBACK.
-- Montonion tila asetetaan testin sisällä: ensin off (A2, C1), sitten test + approved_by (D–I).
-- Läpäisee, oli kannan tila off tai test. Alkuperäinen tila palautetaan ennen tulosta; ROLLBACK kumoaa kaiken.
-- Procountorin mode ja daily_enabled eivät saa muuttua.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t188.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t188.log', coalesce(current_setting('t188.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function pg_temp.svc() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"service_role"}', true); execute 'set local role service_role'; end $$;
create function pg_temp.anon() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon'; end $$;
create function pg_temp.logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
create function pg_temp.mkorder(p_cu bigint, p_total numeric) returns bigint language plpgsql as $$
declare v bigint;
begin
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_kind)
  values (p_cu, 'confirmed', 'unpaid', p_total, 'admin', 'fi', 'private') returning id into v;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (v, 'T188 palvelu', 'product', 1, p_total, p_total, 25.5);
  return v;
end $$;

do $t$
declare
  run text := substr(md5(gen_random_uuid()::text), 1, 10);
  u_adm uuid := gen_random_uuid();
  cu bigint; o bigint; o2 bigint; o3 bigint; pid bigint; rf bigint;
  r jsonb; r2 jsonb; a1 text; a2 text; amt numeric; tok uuid; ltok uuid;
  pc_mode text; pc_daily text; d text; log text; np int; nf int; ns int;
  mo_mode text; mo_settings jsonb;
begin
  select mode, settings ->> 'daily_enabled' into pc_mode, pc_daily from booking.integration_config where key = 'procountor';
  select mode, settings into mo_mode, mo_settings from booking.integration_config where key = 'montonio';
  update booking.integration_config set mode = 'off' where key = 'montonio';

  -- ===== A rakenne
  perform pg_temp.ck(to_regclass('booking.montonio_attempts') is not null, 'A1 montonio_attempts');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.montonio_payment_prepare(uuid,uuid,text)'::regprocedure)) = '438ba5857d711f4686e3665bacd0eb18'
      and md5(pg_get_functiondef('booking.montonio_payment_event(text,text,text,text,jsonb)'::regprocedure)) = '23efc7c7d357fc3c80fe7852a5357f25'
      and md5(pg_get_functiondef('booking.montonio_payment_apply(text,text,numeric,jsonb)'::regprocedure)) = 'ef052d2d9baa94bbe8cc4a9e1784d0ed'
      and md5(pg_get_functiondef('booking.montonio_refund_complete(bigint,text,jsonb)'::regprocedure)) = 'e56363b9adacd24dd3237c5cfa78c0e0'
      and md5(pg_get_functiondef('booking.admin_set_montonio_mode(text,text)'::regprocedure)) = '9716a05fb410e4b4980be6b66dc4f551'
      and md5(pg_get_functiondef('booking._montonio_mode()'::regprocedure)) = 'bd80449b1c324f39825aad817a0e25be', 'A1 uudet funktiot = booking_188');
  perform pg_temp.ck(has_function_privilege('service_role', 'booking.montonio_payment_prepare(uuid,uuid,text)', 'execute')
      and not has_function_privilege('anon', 'booking.montonio_payment_prepare(uuid,uuid,text)', 'execute')
      and not has_function_privilege('authenticated', 'booking.montonio_payment_prepare(uuid,uuid,text)', 'execute')
      and has_function_privilege('authenticated', 'booking.admin_set_montonio_mode(text,text)', 'execute')
      and not has_function_privilege('anon', 'booking.admin_set_montonio_mode(text,text)', 'execute'), 'A1 oikeudet');
  perform pg_temp.ck((select mode from booking.integration_config where key = 'montonio') = 'off', 'A2 mode off (asetettu testin transaktiossa)');
  perform pg_temp.ck(exists (select 1 from booking.payment_methods where code = 'montonio' and is_manual = false and active = true), 'A3 payment_methods montonio on käytössä oleva verkkomaksu, ei käsinkirjaus');
  perform pg_temp.ck((select mode from booking.integration_config where key = 'procountor') is not distinct from pc_mode
      and (select settings ->> 'daily_enabled' from booking.integration_config where key = 'procountor') is not distinct from pc_daily, 'A4 procountor ennallaan heti migraation jälkeen');

  insert into auth.users(id, email) values (u_adm, 't188-admin-' || run || '@example.test');
  insert into booking.staff(user_id, email, name, role) values (u_adm, 't188-admin-' || run || '@example.test', 't188 admin', 'admin');
  insert into booking.customers(name, email, phone) values ('T188 Asiakas ' || run, 't188-' || run || '@example.test', '+358401880188') returning id into cu;

  -- ===== B hyväksyntä
  perform pg_temp.login(u_adm);
  begin
    perform booking.admin_set_montonio_mode('test', null);
    r := '{"unexpected":true}'::jsonb;
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    r := jsonb_build_object('state', sqlstate, 'code', d);
  end;
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'state' = 'BK001' and r ->> 'code' = 'approval_required', 'B1 test ilman approved_by → approval_required ' || left(r::text, 80));

  -- ===== C pois päältä
  o := pg_temp.mkorder(cu, 30);
  select public_token into tok from booking.orders where id = o;
  perform pg_temp.svc();
  r := booking.montonio_payment_prepare(tok, null, 'paymentInitiation');
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'ok' = 'false' and r ->> 'code' = 'online_off', 'C1 prepare mode off → online_off ' || left(r::text, 80));

  update booking.integration_config set mode = 'test', settings = coalesce(settings, '{}'::jsonb) || '{"approved_by":"t188"}'::jsonb where key = 'montonio';

  -- ===== D maksu, kuitti, order_uuid säilyy
  perform pg_temp.svc();
  r := booking.montonio_payment_prepare(tok, null, 'paymentInitiation');
  a1 := r ->> 'order_number'; amt := (r ->> 'amount')::numeric;
  perform pg_temp.ck(r ->> 'ok' = 'true' and a1 ~ '^sauna-o[0-9]+-p[0-9]+-a1$', 'D1 viite sauna-o…-p…-a1 ' || coalesce(a1, 'null'));
  r2 := booking.montonio_payment_event(a1, 'CREATED', 'https://pay.montonio.com/session/t188', 'uuid-t188-1', '{}'::jsonb);
  r := booking.montonio_payment_apply(a1, 'paid', amt, jsonb_build_object('uuid', 'uuid-t188-1', 'paymentStatus', 'PAID'));
  perform pg_temp.ck(r2 ->> 'ok' = 'true' and coalesce((r ->> 'ok')::boolean, false) and (select status from booking.payments where provider_ref = a1) = 'paid', 'D2 apply paid ' || left(r::text, 100));
  perform pg_temp.ck((select raw ->> 'order_uuid' from booking.payments where provider_ref = a1) = 'uuid-t188-1', 'D3 order_uuid säilyy maksun rawssa');
  perform pg_temp.ck(exists (select 1 from booking.receipts where order_id = o and receipt_no like 'K-%'), 'D4 K-kuitti');
  r2 := booking.montonio_payment_apply(a1, 'paid', amt, jsonb_build_object('uuid', 'uuid-t188-1'));
  perform pg_temp.ck(coalesce((r2 ->> 'already')::boolean, false) and (select count(*) from booking.receipts where order_id = o and receipt_no like 'K-%') = 1, 'D5 toinen paid on idempotentti');
  perform pg_temp.logout();

  -- ===== E takarajaton linkki: peruutus on yritettävissä
  o2 := pg_temp.mkorder(cu, 20);
  perform pg_temp.login(u_adm);
  r := booking.admin_create_payment_link(o2, false);
  perform pg_temp.logout();
  pid := coalesce((r ->> 'payment_id')::bigint, (r -> 'link' ->> 'payment_id')::bigint, (r ->> 'id')::bigint);
  select link_token into ltok from booking.payments where id = pid;
  perform pg_temp.svc();
  r := booking.montonio_payment_prepare(null, ltok, 'cardPayments');
  a1 := r ->> 'order_number'; amt := (r ->> 'amount')::numeric;
  perform booking.montonio_payment_event(a1, 'CREATED', 'https://pay.montonio.com/session/t188b', 'uuid-t188-link', '{}'::jsonb);
  r2 := booking.montonio_payment_apply(a1, 'cancelled', null, jsonb_build_object('paymentStatus', 'ABANDONED'));
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and coalesce((r2 ->> 'retryable')::boolean, false)
      and (select status = 'pending' and link_expires_at is null and raw ->> 'paylink' = 'no_deadline' from booking.payments where id = pid),
      'E1 takarajaton linkki: cancelled on retryable ' || left(r2::text, 100));

  -- ===== F tuplamaksu
  o3 := pg_temp.mkorder(cu, 15);
  select public_token into tok from booking.orders where id = o3;
  perform pg_temp.svc();
  r := booking.montonio_payment_prepare(tok, null, 'paymentInitiation');
  a1 := r ->> 'order_number'; amt := (r ->> 'amount')::numeric; pid := (r ->> 'payment_id')::bigint;
  perform pg_temp.logout();
  -- payments_updated sets updated_at = now() on every update, so the backdate must bypass the trigger.
  -- disable trigger vaatii taulun omistajan; service_role ei ole omistaja.
  alter table booking.payments disable trigger payments_updated;
  update booking.payments set updated_at = now() - interval '3 minutes' where id = pid;
  alter table booking.payments enable trigger payments_updated;
  perform pg_temp.svc();
  r := booking.montonio_payment_prepare(tok, null, 'paymentInitiation');
  a2 := r ->> 'order_number';
  perform pg_temp.ck(a2 ~ '-a2$' and a2 is distinct from a1, 'F1 toinen yritys a2 ' || coalesce(a2, 'null'));
  r := booking.montonio_payment_apply(a2, 'paid', amt, jsonb_build_object('uuid', 'uuid-t188-a2', 'paymentStatus', 'PAID'));
  r2 := booking.montonio_payment_apply(a1, 'paid', amt, jsonb_build_object('uuid', 'uuid-t188-a1', 'paymentStatus', 'PAID'));
  perform pg_temp.logout();
  perform pg_temp.ck(coalesce((r ->> 'ok')::boolean, false) and r2 ->> 'outcome' = 'needs_review' and r2 ->> 'code' = 'duplicate_paid'
      and (select count(*) from booking.receipts where order_id = o3 and receipt_no like 'K-%') = 1, 'F2 tuplamaksu needs_review, yksi kuitti ' || left(r2::text, 80));

  -- ===== G hyvitys: leima ei luo H-kuittia, complete luo
  select id into pid from booking.payments where provider_ref = a2;
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, lines)
  select pid, o3, amt, 't188 hyvitys', 'requested', 'montonio',
         coalesce((select jsonb_agg(jsonb_build_object('payment_line_id', pl.id, 'amount', pl.amount_gross) order by pl.id)
                     from booking.payment_lines pl where pl.payment_id = pid), '[]'::jsonb)
  returning id into rf;
  perform pg_temp.svc();
  r := booking.montonio_refund_stamp(rf, 'refund-uuid-t188', 'PENDING', jsonb_build_object('status', 'PENDING'));
  perform pg_temp.ck(r ->> 'ok' = 'true' and (select status from booking.refunds where id = rf) = 'processing'
      and not exists (select 1 from booking.receipts where refund_id = rf), 'G1 stamp ei luo hyvityskuittia');
  r := booking.montonio_refund_complete(rf, 'refund-uuid-t188', jsonb_build_object('refundStatus', 'SUCCESSFUL'));
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and (select status from booking.refunds where id = rf) = 'done'
      and exists (select 1 from booking.receipts where refund_id = rf and kind = 'refund_receipt' and receipt_no like 'H-%'), 'G2 complete luo H-kuitin ' || left(r::text, 80));

  -- ===== H laskutettu tilaus
  update booking.orders set payment_status = 'invoiced' where id = o2;
  perform pg_temp.svc();
  r := booking.montonio_payment_prepare((select public_token from booking.orders where id = o2), null, 'paymentInitiation');
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'code' = 'order_not_payable', 'H1 laskutettu tilaus ei ole maksettavissa ' || left(r::text, 80));

  -- ===== I asiakkaan maksutavat: nimi, ei välittäjän nimeä valinnoissa
  perform pg_temp.anon();
  r := booking.public_payment_options(null);
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true'
      and (select m ->> 'code' from jsonb_array_elements(r -> 'methods') m where m ->> 'code' = 'online') = 'online'
      and (select m ->> 'label' from jsonb_array_elements(r -> 'methods') m where m ->> 'code' = 'online') = 'Maksa verkossa'
      and (select m ->> 'label_en' from jsonb_array_elements(r -> 'methods') m where m ->> 'code' = 'online') = 'Pay online'
      and position('ontonio' in lower((select m -> 'choices' from jsonb_array_elements(r -> 'methods') m where m ->> 'code' = 'online')::text)) = 0,
      'I1 code online, Maksa verkossa, valinnat ilman välittäjän nimeä');

  perform pg_temp.ck((select mode from booking.integration_config where key = 'procountor') is not distinct from pc_mode
      and (select settings ->> 'daily_enabled' from booking.integration_config where key = 'procountor') is not distinct from pc_daily, 'K procountor mode ja daily_enabled ennallaan');

  if mo_mode is null then delete from booking.integration_config where key = 'montonio';
  else update booking.integration_config set mode = mo_mode, settings = mo_settings where key = 'montonio'; end if;

  log := current_setting('t188.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  ns := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'S %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% skip=% %', np, nf, ns, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
