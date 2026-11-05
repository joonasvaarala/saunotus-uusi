-- t243: admin_create_booking method=payment_link. Ajo booking_243 up.sql:n jälkeen. Lopussa TESTRESULT + ROLLBACK.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t243.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t243.log', coalesce(current_setting('t243.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;

create function pg_temp.j(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text;
begin
  execute p_sql into r; return r;
exception when others then
  get stacked diagnostics d = pg_exception_detail, m = message_text;
  return jsonb_build_object('err', coalesce(nullif(d, ''), sqlstate), 'msg', m);
end $$;

update booking.integration_config set mode = 'dry_run' where key = 'resend';

do $t$
declare
  d_mon date := test.next_dow(1, 10);
  r jsonb; log text; np int; nf int;
  v_staff uuid; v_cust bigint; v_order bigint; v_pid bigint;
  v_ps text; v_prov text; v_method text; v_exp timestamptz; v_raw jsonb;
  v_kind text; v_mail_kind text; v_n_manual int; v_n_link int;
begin
  v_staff := test.mk_staff('t243.admin.' || txid_current() || '@example.com', 'admin');
  perform test.login(v_staff);

  -- A. payment_methods-rivi
  perform pg_temp.ck(exists (
    select 1 from booking.payment_methods
     where code = 'payment_link' and is_manual and active and label = 'Maksulinkki'
  ), 'A1 payment_methods.payment_link is_manual+active');

  -- B. uusi asiakas ilman sähköpostia → email_required
  r := pg_temp.j(format(
    $q$select booking.admin_create_booking(
      p_rule_id => 1, p_date => %L, p_persons => 1,
      p_customer => '{"name":"T243 EiMail","phone":"0401112233","kind":"private"}'::jsonb,
      p_payment_method => 'payment_link', p_paid => true)$q$, d_mon));
  perform pg_temp.ck(r->>'err' = 'email_required', 'B1 ilman emailia → email_required ' || coalesce(r->>'err',''));

  -- C. happy path: luo varaus + linkki + email, ei manual-pending
  r := pg_temp.j(format(
    $q$select booking.admin_create_booking(
      p_rule_id => 1, p_date => %L, p_persons => 2,
      p_customer => %L::jsonb,
      p_payment_method => 'payment_link', p_paid => true, p_note => 't243 link')$q$,
    d_mon,
    jsonb_build_object('name','T243 Linkki','email','t243.'||txid_current()||'@example.com','phone','0409998877','kind','private','language','fi')
  ));
  v_order := (r->>'order_id')::bigint;
  v_pid := (r->>'payment_id')::bigint;
  perform pg_temp.ck(v_order is not null and v_pid is not null and (r->>'payment_link')::boolean is true
                     and not (r ? 'err'), 'C1 vastaus: order+payment_id+payment_link ' || coalesce(r->>'err', coalesce(r->>'msg','')));
  perform pg_temp.ck(coalesce((r->>'email_queued')::boolean, false) or coalesce(r->>'email_queued','') in ('true','t'),
                     'C2 email_queued true (dry_run) ' || coalesce(r->>'email_queued','null'));

  select payment_status into v_ps from booking.orders where id = v_order;
  perform pg_temp.ck(v_ps = 'pending', 'C3 order.payment_status=pending (linkki, ei paid) got=' || coalesce(v_ps,'null'));

  select method, provider, link_expires_at, raw
    into v_method, v_prov, v_exp, v_raw
    from booking.payments where id = v_pid;
  perform pg_temp.ck(v_method = 'montonio' and v_prov = 'montonio' and v_exp is null
                     and coalesce(v_raw->>'paylink','') = 'no_deadline',
                     'C4 linkkimaksu montonio, expires null, no_deadline');

  select count(*) into v_n_manual from booking.payments
   where order_id = v_order and provider = 'manual' and status = 'pending';
  select count(*) into v_n_link from booking.payments
   where order_id = v_order and provider = 'montonio' and status = 'pending';
  perform pg_temp.ck(v_n_manual = 0 and v_n_link = 1, 'C5 ei manual-pending, yksi linkkimaksu');

  select kind into v_mail_kind from booking.email_outbox
   where order_id = v_order and payment_id = v_pid and kind = 'payment_link'
   order by id desc limit 1;
  perform pg_temp.ck(v_mail_kind = 'payment_link', 'C6 email_outbox payment_link-rivi');

  -- _plr_link_kind ei ole grantattu authenticatedille; sama sääntö inline + watch-lista
  v_kind := case
    when v_exp is null and coalesce(v_raw->>'paylink','') = 'no_deadline' then 'onsite'
    when v_exp is not null and v_exp > (select created_at from booking.payments where id = v_pid) + interval '2 hours' then 'prepaid'
    else null end;
  perform pg_temp.ck(v_kind = 'onsite', 'C7 link_kind=onsite (watch-suodatin)');
  perform pg_temp.ck(exists (
    select 1 from booking.payments p
     join booking.orders o on o.id = p.order_id
     where p.id = v_pid and p.status = 'pending' and p.provider <> 'manual'
       and p.external_source is null and o.external_source is null
       and p.reminders_handled_at is null
       and (p.link_expires_at is null or p.link_expires_at > now())
  ), 'C7b maksu täyttää admin_list_payment_link_watch -suodattimet');

  -- D. olemassa oleva asiakas ilman emailia
  perform test.logout();
  insert into booking.customers(name, phone, language)
  values ('T243 NoEmail', '0400001111', 'fi') returning id into v_cust;
  perform test.login(v_staff);
  r := pg_temp.j(format(
    $q$select booking.admin_create_booking(
      p_rule_id => 1, p_date => %L, p_persons => 1,
      p_customer_id => %s, p_payment_method => 'payment_link')$q$, d_mon, v_cust));
  perform pg_temp.ck(r->>'err' = 'email_required', 'D1 olemassa oleva ilman emailia → email_required');

  -- E. regressio: pay_later + paid toimii kuten ennen
  r := pg_temp.j(format(
    $q$select booking.admin_create_booking(
      p_rule_id => 1, p_date => %L, p_persons => 1,
      p_customer => %L::jsonb,
      p_payment_method => 'pay_later', p_paid => true)$q$,
    d_mon,
    jsonb_build_object('name','T243 PayLater','email','t243.pl.'||txid_current()||'@example.com','kind','private')
  ));
  v_order := (r->>'order_id')::bigint;
  select payment_status into v_ps from booking.orders where id = v_order;
  perform pg_temp.ck(v_ps = 'paid' and not coalesce((r->>'payment_link')::boolean, false),
                     'E1 pay_later+paid → paid, ei payment_link ' || coalesce(v_ps,''));

  perform test.logout();

  log := current_setting('t243.log', true);
  np := length(log) - length(replace(log, 'P ', '')); np := np / 2;
  nf := length(log) - length(replace(log, 'F ', '')); nf := nf / 2;
  raise notice E'TESTRESULT pass=% fail=%\n%', np, nf, log;
  if nf > 0 then raise exception 't243 FAIL fail=%', nf; end if;
end $t$;

rollback;
