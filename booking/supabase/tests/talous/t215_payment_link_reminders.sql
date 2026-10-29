-- t215: booking_215 maksulinkkien muistutukset (Joonas 29.10.2026).
--   A) asetukset, ei cron-jobia oletuksena, sweep ei lähetä kun reminders_enabled = false, oikeudet.
--   B) ennakkomaksu: 3 vrk ja 1 vrk ennen; alle/tasan 4 vrk vain eräpäivämuistutus; peruutuspäivä payloadissa.
--   C) paikan päällä: 4 muistutusta 72 h välein, sitten vaatii toimenpiteitä; viides ei lähde.
--   D) ikkuna 10–18 Helsinki; maksettu/peruttu lopettaa; käsin ja Johku ja lyhyt istunto eivät kuulu; idempotentti dedupe.
--   E) keskeytys, lähetä nyt ikkunan ulkopuolella, claim poistaa linkin jos maksu ei ole auki, merkitse hoidetuksi (kuitti, ei kuittisähköpostia jonossa).
-- Aja migraatioiden ja fixtures/10_test_helpers.sql:n jälkeen. Yksi transaktio, lopussa TESTRESULT + ROLLBACK.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t215.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t215.log', coalesce(current_setting('t215.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function pg_temp.logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
create function pg_temp.mkorder(p_cu bigint, p_total numeric, p_locale text default 'fi') returns bigint language plpgsql as $$
declare v bigint;
begin
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_kind)
  values (p_cu, 'confirmed', 'unpaid', p_total, 'admin', p_locale, 'private') returning id into v;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (v, 'T215 palvelu', 'product', 1, p_total, p_total, 25.5);
  return v;
end $$;
create function pg_temp.link(p_admin uuid, p_order bigint, p_days int default null) returns bigint language plpgsql as $$
declare r jsonb;
begin
  perform pg_temp.login(p_admin);
  if p_days is null then r := booking.admin_create_payment_link(p_order, false);
  else r := booking.admin_create_payment_link(p_order, false, p_days, 'T215'); end if;
  perform pg_temp.logout();
  return coalesce((r ->> 'payment_id')::bigint, (r -> 'link' ->> 'payment_id')::bigint);
end $$;
create function pg_temp.nout(p_pid bigint) returns int language sql as $$
  select count(*)::int from booking.email_outbox where payment_id = p_pid and kind = 'payment_link_reminder' and dedupe_key like 'payment_link_reminder:' || p_pid || ':%' $$;

do $t$
declare
  run text := substr(md5(gen_random_uuid()::text), 1, 10);
  u_adm uuid := gen_random_uuid(); u_st uuid := gen_random_uuid();
  cu bigint; o bigint; pid bigint; o2 bigint; p2 bigint; o3 bigint; p3 bigint; o4 bigint; p4 bigint;
  v_noon timestamptz; v_morn timestamptz; v_open timestamptz; v_eve timestamptz;
  n int; r jsonb; d text; log text; np int; nf int; ns int;
  v_resend text;
begin
  select mode into v_resend from booking.integration_config where key = 'resend';
  insert into booking.integration_config(key, mode) values ('resend', 'dry_run')
    on conflict (key) do update set mode = 'dry_run';
  v_noon := (date_trunc('day', now() at time zone 'Europe/Helsinki') + time '12:00') at time zone 'Europe/Helsinki';
  v_morn := (date_trunc('day', v_noon at time zone 'Europe/Helsinki') + time '09:30') at time zone 'Europe/Helsinki';
  v_open := (date_trunc('day', v_noon at time zone 'Europe/Helsinki') + time '10:00') at time zone 'Europe/Helsinki';
  v_eve := (date_trunc('day', v_noon at time zone 'Europe/Helsinki') + time '21:00') at time zone 'Europe/Helsinki';

  perform pg_temp.ck(coalesce(booking._setting('payment_link.reminders_enabled') #>> '{}', '') = 'false', 'A1 reminders_enabled oletus false');
  perform pg_temp.ck((booking._setting('payment_link.remind_prepaid_after_hours') #>> '{}') = '72'
      and (booking._setting('payment_link.remind_before_expiry_hours') #>> '{}') = '24'
      and (booking._setting('payment_link.remind_onsite_interval_hours') #>> '{}') = '72'
      and (booking._setting('payment_link.remind_onsite_max') #>> '{}') = '4'
      and (booking._setting('payment_link.remind_window') #>> '{}') = '10-18', 'A2 välit ja ikkuna');
  if to_regclass('cron.job') is not null then
    perform pg_temp.ck((select count(*) from cron.job where jobname = 'booking_payment_link_reminders') = 0, 'A3 migraatio ei luonut cron-jobia');
  else
    perform pg_temp.ck(true, 'A3 cron-skeemaa ei ole');
  end if;
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_list_payment_link_watch(text,text,integer,integer)', 'execute')
      and not has_function_privilege('anon', 'booking.payment_link_reminders_sweep(timestamptz)', 'execute')
      and not has_function_privilege('authenticated', 'booking.payment_link_reminders_sweep(timestamptz)', 'execute')
      and has_function_privilege('authenticated', 'booking.admin_list_payment_link_watch(text,text,integer,integer)', 'execute')
      and has_function_privilege('service_role', 'booking.payment_link_reminders_sweep(timestamptz)', 'execute'), 'A4 oikeudet');
  perform pg_temp.ck(booking.payment_link_reminders_sweep(v_noon) = 0, 'A5 sweep ei lähetä kun asetus on false');

  insert into auth.users(id, email) values (u_adm, 't215-admin-' || run || '@example.test'), (u_st, 't215-staff-' || run || '@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_adm, 't215-admin-' || run || '@example.test', 't215 admin', 'admin'),
    (u_st, 't215-staff-' || run || '@example.test', 't215 staff', 'staff');
  delete from booking.role_permissions where role_code = 'staff' and permission = 'payments.manage';
  begin
    perform pg_temp.login(u_st);
    perform booking.admin_list_payment_link_watch();
    perform pg_temp.ck(false, 'A6 staff ilman payments.manage pääsi listaan');
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    perform pg_temp.logout();
    perform pg_temp.ck(d = 'forbidden', 'A6 staff ilman payments.manage: forbidden (' || coalesce(d, sqlstate) || ')');
  end;
  perform pg_temp.logout();
  insert into booking.role_permissions(role_code, permission) values ('staff', 'payments.manage');

  insert into booking.customers(name, email, phone) values ('T215 Asiakas ' || run, 't215-' || run || '@example.test', '+358401215215') returning id into cu;
  update booking.settings set value = 'true'::jsonb where key = 'payment_link.reminders_enabled';

  -- B ennakkomaksu, yli 4 vrk
  o := pg_temp.mkorder(cu, 49);
  pid := pg_temp.link(u_adm, o, 7);
  update booking.payments set created_at = v_noon - interval '5 days', link_expires_at = v_noon + interval '2 days' where id = pid;
  perform pg_temp.ck(booking.payment_link_reminders_sweep(v_noon) = 1 and pg_temp.nout(pid) = 1, 'B1 5 vrk vanha ennakko: yksi muistutus');
  perform pg_temp.ck((select r.kind = 'prepaid_unpaid' and r.emailed and (e.payload ->> 'cancel_if_unpaid')::boolean
        from booking.payment_link_reminders r join booking.email_outbox e on e.id = r.email_outbox_id
       where r.payment_id = pid and r.reminder_no = 1), 'B2 ensimmäinen on 3 vrk -muistutus ja peruutusvaroitus');
  perform pg_temp.ck(booking.payment_link_reminders_sweep(v_noon) = 0 and pg_temp.nout(pid) = 1, 'B3 sama hetki ei lähetä toista (dedupe)');
  n := booking.payment_link_reminders_sweep(v_noon + interval '25 hours');
  perform pg_temp.ck(n = 1
      and (select kind from booking.payment_link_reminders where payment_id = pid and reminder_no = 2) = 'prepaid_before_expiry', 'B4 vuorokausi ennen eräpäivää: toinen muistutus');
  update booking.payments set reminders_handled_at = now() where id = pid;

  -- alle 4 vrk ja tasan 4 vrk: vain eräpäivämuistutus
  o2 := pg_temp.mkorder(cu, 30, 'en');
  p2 := pg_temp.link(u_adm, o2, 3);
  update booking.payments set created_at = v_noon - interval '2 days', link_expires_at = v_noon + interval '1 day' where id = p2;
  n := booking.payment_link_reminders_sweep(v_noon);
  perform pg_temp.ck(n = 1 and not exists (select 1 from booking.payment_link_reminders where payment_id = p2 and reminder_no = 1 and emailed)
      and (select kind from booking.payment_link_reminders where payment_id = p2 and reminder_no = 2) = 'prepaid_before_expiry'
      and (select locale from booking.email_outbox where payment_id = p2 and kind = 'payment_link_reminder') = 'en', 'B5 alle 4 vrk: vain eräpäivämuistutus, kieli en');
  o3 := pg_temp.mkorder(cu, 30);
  p3 := pg_temp.link(u_adm, o3, 4);
  update booking.payments set created_at = v_noon, link_expires_at = v_noon + interval '96 hours' where id = p3;
  perform pg_temp.ck(booking.payment_link_reminders_sweep(v_noon + interval '1 hour') = 0, 'B6 tasan 4 vrk: 3 vrk -muistutusta ei ole vielä eikä se ole vuorossa');
  n := booking.payment_link_reminders_sweep(v_noon + interval '73 hours');
  perform pg_temp.ck(n = 1
      and not exists (select 1 from booking.payment_link_reminders where payment_id = p3 and reminder_no = 1 and emailed)
      and exists (select 1 from booking.payment_link_reminders where payment_id = p3 and reminder_no = 2 and kind = 'prepaid_before_expiry' and emailed), 'B6b tasan 4 vrk: vain eräpäivämuistutus');
  update booking.payments set reminders_handled_at = now() where id in (p2, p3);

  -- C paikan päällä, 4 kpl
  o4 := pg_temp.mkorder(cu, 40);
  p4 := pg_temp.link(u_adm, o4);
  update booking.payments set created_at = v_noon - interval '73 hours' where id = p4;
  perform pg_temp.ck((select link_expires_at is null and raw ->> 'paylink' = 'no_deadline' from booking.payments where id = p4), 'C0 takarajaton linkki');
  perform pg_temp.ck(booking.payment_link_reminders_sweep(v_noon) = 1, 'C1 ensimmäinen 72 h jälkeen');
  perform pg_temp.ck(booking.payment_link_reminders_sweep(v_noon + interval '73 hours') = 1, 'C2 toinen');
  perform pg_temp.ck(booking.payment_link_reminders_sweep(v_noon + interval '146 hours') = 1, 'C3 kolmas');
  n := booking.payment_link_reminders_sweep(v_noon + interval '219 hours');
  perform pg_temp.ck(n = 1
      and (select reminders_needs_action from booking.payments where id = p4), 'C4 neljäs merkitsee vaatii toimenpiteitä');
  n := booking.payment_link_reminders_sweep(v_noon + interval '400 hours');
  perform pg_temp.ck(n = 0
      and (select count(*) from booking.payment_link_reminders where payment_id = p4 and emailed and kind = 'onsite') = 4, 'C5 viidettä automaattista ei lähde');

  -- D ikkuna, rajaukset, peruutus
  o := pg_temp.mkorder(cu, 22);
  pid := pg_temp.link(u_adm, o);
  update booking.payments set created_at = v_morn - interval '80 hours' where id = pid;
  perform pg_temp.ck(booking.payment_link_reminders_sweep(v_morn) = 0 and pg_temp.nout(pid) = 0, 'D1 klo 9.30 ei lähetä');
  perform pg_temp.login(u_adm);
  r := booking.admin_list_payment_link_watch(null, null, 50, 0);
  perform pg_temp.logout();
  perform pg_temp.ck((select (x ->> 'next_reminder_at')::timestamptz = booking._plr_next_open(greatest((v_morn - interval '80 hours') + interval '72 hours', now()))
        from jsonb_array_elements(r -> 'rows') x where (x ->> 'payment_id')::bigint = pid), 'D2 seuraava muistutus on ikkunan seuraava aukko');
  perform pg_temp.ck(booking.payment_link_reminders_sweep(v_open) = 1 and pg_temp.nout(pid) = 1, 'D3 klo 10 lähettää');
  update booking.payments set status = 'cancelled' where id = pid;
  perform pg_temp.ck((select status from booking.email_outbox where payment_id = pid and kind = 'payment_link_reminder') = 'skipped', 'D4 peruttu linkki keskeyttää jonossa olevan muistutuksen');

  o := pg_temp.mkorder(cu, 18);
  pid := pg_temp.link(u_adm, o, 7);
  update booking.payments set created_at = v_noon - interval '10 days', link_expires_at = v_noon - interval '1 hour' where id = pid;
  perform pg_temp.ck(booking.payment_link_reminders_sweep(v_noon) = 0 and pg_temp.nout(pid) = 0, 'D5 vanhentunut linkki ei saa muistutusta');

  o := pg_temp.mkorder(cu, 18);
  pid := pg_temp.link(u_adm, o, 7);
  update booking.payments set created_at = v_noon - interval '8 days', link_expires_at = v_noon + interval '2 days' where id = pid;
  update booking.orders set external_source = 'johku', external_id = 't215-' || run where id = o;
  perform pg_temp.ck(booking.payment_link_reminders_sweep(v_noon) = 0 and pg_temp.nout(pid) = 0, 'D6 Johku-tilaus ei saa muistutusta');

  o := pg_temp.mkorder(cu, 18);
  pid := pg_temp.link(u_adm, o, 1);
  update booking.payments set link_expires_at = created_at + interval '30 minutes', raw = null where id = pid;
  perform pg_temp.ck(booking.payment_link_reminders_sweep(v_noon + interval '5 days') = 0 and pg_temp.nout(pid) = 0, 'D7 lyhyt maksuistunto ei ole linkki');

  insert into booking.payments(order_id, method, provider, status, amount)
  values (o, 'card_terminal', 'manual', 'pending', 5);
  perform pg_temp.login(u_adm);
  r := booking.admin_list_payment_link_watch(null, 'needs_action', 50, 0);
  perform pg_temp.logout();
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(r -> 'rows') x where (x ->> 'payment_id')::bigint = p4 and x ->> 'status' = 'needs_action')
      and not exists (select 1 from jsonb_array_elements(r -> 'rows') x where (x ->> 'link_kind') is null), 'D8 lista: vaatii toimenpiteitä, ei käsin kirjattua');

  -- E tauko, lähetä nyt, claim, hoidettu
  o := pg_temp.mkorder(cu, 55);
  pid := pg_temp.link(u_adm, o);
  update booking.payments set created_at = v_eve - interval '80 hours' where id = pid;
  perform pg_temp.login(u_adm);
  perform booking.admin_payment_link_pause_reminders(pid);
  perform pg_temp.logout();
  perform pg_temp.ck(booking.payment_link_reminders_sweep(v_noon + interval '30 days') = 0 and pg_temp.nout(pid) = 0, 'E1 tauko estää automaattisen');
  perform pg_temp.login(u_adm);
  r := booking.admin_payment_link_remind_now(pid);
  perform pg_temp.logout();
  perform pg_temp.ck((r ->> 'queued')::boolean and pg_temp.nout(pid) = 1, 'E2 lähetä nyt toimii tauosta ja kellonajasta huolimatta');
  r := booking.email_outbox_claim(20);
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(r) x
        where (x ->> 'kind') = 'payment_link_reminder'
          and (x #>> '{payment,link_url}') like '%/maksa/?p=%'
          and (x #>> '{payment_reminder,kind}') = 'onsite'
          and coalesce((x #>> '{payment_reminder,cancel_if_unpaid}')::boolean, true) = false
          and (x::text) not ilike '%montonio%'), 'E3 claim: sama maksulinkki, ei peruutusvaroitusta, ei Montonio-nimeä');
  o2 := pg_temp.mkorder(cu, 15);
  p2 := pg_temp.link(u_adm, o2);
  update booking.payments set created_at = v_noon - interval '80 hours' where id = p2;
  perform pg_temp.ck(booking.payment_link_reminders_sweep(v_noon) = 1 and pg_temp.nout(p2) = 1, 'E4 toinen linkki jonoon');
  update booking.payments set status = 'cancelled' where id = p2;
  update booking.email_outbox set status = 'pending', last_error = null, locked_at = null
   where payment_id = p2 and kind = 'payment_link_reminder';
  r := booking.email_outbox_claim(20);
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(r) x
        where (x #>> '{payment,id}') = p2::text and nullif(x #>> '{payment,link_url}', '') is null), 'E5 peruttu linkki: claim ei anna maksulinkkiä');

  o3 := pg_temp.mkorder(cu, 33);
  p3 := pg_temp.link(u_adm, o3, 7);
  perform pg_temp.login(u_adm);
  r := booking.admin_payment_link_mark_handled(p3, 'card_terminal', 'T215 hoidettu');
  perform pg_temp.logout();
  perform pg_temp.ck((r ->> 'handled')::boolean and (r ->> 'receipt_no') is not null
      and (select status from booking.payments where id = p3) = 'cancelled'
      and not exists (select 1 from booking.email_outbox e where e.order_id = o3 and e.kind = 'receipt' and e.status = 'pending'), 'E6 hoidettu: kuitti, linkki peruttu, ei kuittisähköpostia jonossa');

  if v_resend is null then delete from booking.integration_config where key = 'resend';
  else update booking.integration_config set mode = v_resend where key = 'resend'; end if;

  log := current_setting('t215.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  ns := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'S %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% skip=% %', np, nf, ns, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
