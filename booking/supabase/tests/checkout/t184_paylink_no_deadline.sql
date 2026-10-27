-- t184: booking_184 henkilökunnan maksulinkki ilman takarajaa (omistaja Joonas 26.10.2026).
--   A) rakenne: kuusi muutettua funktiota = booking_184 (md5), SECURITY DEFINER, search_path '', omistaja postgres, oikeudet ennallaan, ei PUBLIC;
--      oletus p_expires_days = NULL; riippuvuudet (_public_pay_json 14 vrk, admin_pos_send_link 1 vrk, expire_payment_links, link_info, prepare) ennallaan.
--   B) admin_create_payment_link ilman päiviä → link_expires_at null + raw.paylink = 'no_deadline'; toisto käyttää saman linkin; 0/61 → invalid_param,
--      1 ja 60 kelpaavat; henkilökunnan 7 vrk korvaa takarajattoman; takarajaton pyyntö korvaa takarajallisen.
--   C) asiakkaan/järjestelmän polut (_public_pay_json 14 vrk, _create_link_payment 1 vrk ilman henkilökuntaa) käyttävät takarajattoman linkin uudelleen
--      (eivät peru sitä); merkitsemätön verkkokaupan null-rivi: henkilökunnan takarajaton pyyntö EI käytä sitä (korvaa merkityllä linkillä).
--   D) admin_add_to_order(p_create_link) → takarajaton linkki. (_vc_redeem: t174 E4.)
--   E) cron expire_payment_links: takarajaton (100 vrk vanha) jää pending; vanhentunut takarajallinen perutaan. _order_balance pending_link,
--      public_payment_link_info: open, expires_at null, can_pay.
--   F) Visma: takarajaton linkki peruutus → retryable (pending, null säilyy, merkintä säilyy) → uusi yritys -a2 → paid.
--      Verkkokaupan maksurivi link_expires_at null (public_create_booking-tyyli) peruutus → cancelled kuten ennen (EI linkki).
--   G) MobilePay: takarajaton linkki MobilePaylle → tilaustokenin QR EI lyhennä (null säilyy); 14 vrk linkki ei lyhene; verkkokaupan maksu lyhenee ≤ 20 min.
-- TUOTANTOKELPOINEN rakenne kuten t178: yksi transaktio, lopussa tahallinen poikkeus "TESTRESULT pass=… fail=… skip=…" + ROLLBACK. Ei ulkoisia kutsuja.
-- Aja booking_184-migraation jälkeen (samassa transaktiossa dry runissa).
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t184.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t184.log', coalesce(current_setting('t184.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function pg_temp.anon() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon'; end $$;
create function pg_temp.svc() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"service_role"}', true); execute 'set local role service_role'; end $$;
create function pg_temp.logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
create function pg_temp.mkorder(p_cu bigint, p_total numeric) returns bigint language plpgsql as $$
declare v bigint;
begin
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_kind)
  values (p_cu, 'confirmed', 'unpaid', p_total, 'admin', 'fi', 'private') returning id into v;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (v, 'T184 palvelu', 'product', 1, p_total, p_total, 25.5);
  return v;
end $$;
-- henkilökunnan linkki; p_days null = ei takarajaa (parametri jätetään pois kuten UI:ssa)
create function pg_temp.link(p_admin uuid, p_order bigint, p_days int default null) returns jsonb language plpgsql as $$
declare r jsonb; d text;
begin
  perform pg_temp.login(p_admin);
  if p_days is null then r := booking.admin_create_payment_link(p_order, false);
  else r := booking.admin_create_payment_link(p_order, false, p_days, 'T184 linkki'); end if;
  perform pg_temp.logout();
  return r || jsonb_build_object('pid', coalesce((r ->> 'payment_id')::bigint, (r -> 'link' ->> 'payment_id')::bigint, (r ->> 'id')::bigint));
exception when others then get stacked diagnostics d = pg_exception_detail; perform pg_temp.logout(); return jsonb_build_object('state', sqlstate, 'code', d);
end $$;
create function pg_temp.tok(p_pid bigint) returns uuid language sql as $$ select link_token from booking.payments where id = p_pid $$;
create function pg_temp.info(p_token uuid) returns jsonb language plpgsql as $$
declare r jsonb;
begin perform pg_temp.anon(); r := booking.public_payment_link_info(p_token); perform pg_temp.logout(); return r; end $$;
create function pg_temp.prep(p_link uuid, p_order uuid) returns jsonb language plpgsql as $$
declare r jsonb;
begin perform pg_temp.svc(); r := booking.vismapay_payment_prepare(p_order, p_link); perform pg_temp.logout(); return r; end $$;
create function pg_temp.created(p_onum text) returns jsonb language plpgsql as $$
declare r jsonb;
begin perform pg_temp.svc();
  r := booking.vismapay_payment_event(p_onum, 'CREATED', 'https://www.vismapay.com/pbwapi/token/t184' || md5(p_onum), 't184' || md5(p_onum),
         jsonb_build_object('token_valid_until', (floor(extract(epoch from now())) + 3600)::bigint::text));
  perform pg_temp.logout(); return r; end $$;
create function pg_temp.apply(p_onum text, p_outcome text, p_amount numeric default null) returns jsonb language plpgsql as $$
declare r jsonb;
begin perform pg_temp.svc(); r := booking.vismapay_payment_apply(p_onum, p_outcome, p_amount, jsonb_build_object('t184', true)); perform pg_temp.logout(); return r; end $$;
create function pg_temp.mprep(p_link uuid, p_order uuid) returns jsonb language plpgsql as $$
declare r jsonb;
begin perform pg_temp.svc(); r := booking.montonio_payment_prepare(p_order, p_link, 'paymentInitiation'); perform pg_temp.logout(); return r; end $$;
create function pg_temp.mcreated(p_onum text) returns jsonb language plpgsql as $$
declare r jsonb;
begin perform pg_temp.svc();
  r := booking.montonio_payment_event(p_onum, 'CREATED', 'https://pay.montonio.com/session/t184' || md5(p_onum), 'uuid-t184-' || left(md5(p_onum), 12), '{}'::jsonb);
  perform pg_temp.logout(); return r; end $$;
create function pg_temp.mapply(p_onum text, p_outcome text, p_amount numeric default null) returns jsonb language plpgsql as $$
declare r jsonb;
begin perform pg_temp.svc(); r := booking.montonio_payment_apply(p_onum, p_outcome, p_amount, jsonb_build_object('t184', true)); perform pg_temp.logout(); return r; end $$;
create function pg_temp.mp(p_order uuid, p_link uuid, p_flow text) returns jsonb language plpgsql as $$
declare r jsonb; d text;
begin perform pg_temp.svc(); r := booking.mobilepay_payment_prepare(p_order, p_link, case when p_flow = 'WEB_REDIRECT' then 120 else 20 end, p_flow); perform pg_temp.logout(); return r;
exception when others then get stacked diagnostics d = pg_exception_detail; perform pg_temp.logout(); return jsonb_build_object('state', sqlstate, 'code', d);
end $$;
create function pg_temp.audits(p_pay bigint, p_action text) returns int language sql as $$
  select count(*)::int from booking.audit_log where table_name = 'payments' and row_pk = p_pay::text and action = p_action $$;
create function pg_temp.nd(p_pid bigint) returns boolean language sql as $$
  select link_expires_at is null and raw ->> 'paylink' = 'no_deadline' and status = 'pending' from booking.payments where id = p_pid $$;

do $t$
declare
  run text := substr(md5(gen_random_uuid()::text), 1, 10);
  u_adm uuid := gen_random_uuid();
  cu bigint; o bigint; o2 bigint; o3 bigint; o4 bigint; o5 bigint; o6 bigint; o7 bigint; o8 bigint; o9 bigint; o10 bigint;
  p1 bigint; p2 bigint; p3 bigint; pc bigint; tk uuid; otok uuid; a1 text; a2 text;
  r jsonb; r2 jsonb; prow booking.payments; log text; np int; nf int; ns int; n int;
  s_vp booking.integration_config; s_mp booking.integration_config; s_rl jsonb; v_has_rl boolean;
  fns text[] := array['booking._create_link_payment(bigint,integer,text)', 'booking.admin_create_payment_link(bigint,boolean,integer,text)',
                      'booking.admin_add_to_order(bigint,jsonb,boolean,boolean,text)', 'booking._vc_redeem(bigint,numeric,text,text,text)',
                      'booking.vismapay_payment_apply(text,text,numeric,jsonb)', 'booking.mobilepay_payment_prepare(uuid,uuid,integer,text)'];
begin
  select * into s_vp from booking.integration_config where key = 'vismapay';
  select * into s_mp from booking.integration_config where key = 'mobilepay';
  select value, true into s_rl, v_has_rl from booking.settings where key = 'rl_order_get_per_10min';

  -- ===== A rakenne
  perform pg_temp.ck(md5(pg_get_functiondef(fns[1]::regprocedure)) in ('5e432077c560a10822db8ac0d2bbe7c2', 'f40db96ca201e40467f20cc1db5866c9', 'adc14e6983e60d80498508c9b969f60d')
      and md5(pg_get_functiondef(fns[2]::regprocedure)) in ('80004933a80f77a10fcf625f493a20ef', '5d44526fd3c8ce105d8f6c1f6bc74327')
      and md5(pg_get_functiondef(fns[3]::regprocedure)) = '5babbf859133aebd3e9e7c827bee3261'
      and md5(pg_get_functiondef(fns[4]::regprocedure)) in ('2aa8e44cb2c6f150d3488f53f8d94c25', '6576dc3dda048de2a438f1cdf333b0d9')
      and md5(pg_get_functiondef(fns[5]::regprocedure)) = '2f8a7e56ae9bb4e29f4025f91e7ea706'
      and md5(pg_get_functiondef(fns[6]::regprocedure)) in ('37573920d2f9f882e3d95c4f0c66575f', 'e6888446c4b44e554d31c0920609ddb6', 'c6a64c1ff9353a5e581d72af10966665'), 'A1 muutetut funktiot = booking_184 (tai booking_185 / booking_189: mobilepay_payment_prepare)');
  perform pg_temp.ck((select bool_and(prosecdef and proconfig = array['search_path=""'] and proowner = 'postgres'::regrole) and count(*) = 6
      from pg_proc where oid = any (fns::regprocedure[])), 'A2 SECURITY DEFINER, search_path tyhjä, omistaja postgres');
  perform pg_temp.ck(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = any (fns::regprocedure[]) and a.grantee = 0)
      and not has_function_privilege('anon', fns[1], 'execute') and not has_function_privilege('authenticated', fns[1], 'execute') and has_function_privilege('service_role', fns[1], 'execute')
      and not has_function_privilege('anon', fns[2], 'execute') and has_function_privilege('authenticated', fns[2], 'execute') and has_function_privilege('service_role', fns[2], 'execute')
      and not has_function_privilege('anon', fns[3], 'execute') and has_function_privilege('authenticated', fns[3], 'execute') and has_function_privilege('service_role', fns[3], 'execute')
      and not has_function_privilege('anon', fns[4], 'execute') and not has_function_privilege('authenticated', fns[4], 'execute') and not has_function_privilege('service_role', fns[4], 'execute')
      and not has_function_privilege('anon', fns[5], 'execute') and not has_function_privilege('authenticated', fns[5], 'execute') and has_function_privilege('service_role', fns[5], 'execute')
      and not has_function_privilege('anon', fns[6], 'execute') and not has_function_privilege('authenticated', fns[6], 'execute') and has_function_privilege('service_role', fns[6], 'execute'),
      'A3 oikeudet ennallaan (ei PUBLIC/anon; admin-RPC:t authenticated; sisäiset vain service_role/postgres)');
  perform pg_temp.ck(pg_get_function_arguments(fns[1]::regprocedure) like '%p_expires_days integer DEFAULT NULL::integer%'
      and pg_get_function_arguments(fns[2]::regprocedure) like '%p_expires_days integer DEFAULT NULL::integer%', 'A4 oletus p_expires_days = NULL');
  perform pg_temp.ck(md5(pg_get_functiondef('booking._public_pay_json(bigint)'::regprocedure)) = 'cc3e61dbdfbd9a816cd9c982c73820c5'
      and md5(pg_get_functiondef('booking.admin_pos_send_link(bigint,text,boolean)'::regprocedure)) = '735e92d8c8c52784bbba9b928c5a122b'
      and md5(pg_get_functiondef('booking.expire_payment_links()'::regprocedure)) = '0109d701ab1ccc4e57f6210989644f5c'
      and md5(pg_get_functiondef('booking.public_payment_link_info(uuid)'::regprocedure)) in ('647c556562046c75b7e7e33703c050a0', '1b729ef4d72dc925001169c38bad3315', '2c9e06b3153aa5c0edd25341024ae6a8')
      and md5(pg_get_functiondef('booking.vismapay_payment_prepare(uuid,uuid)'::regprocedure)) in ('703c03c301f5a3008192cdbe65e559e2', 'cca997c4e900e78b8bb9e2e0c7da25d4', 'd1f8df803a45c2b77aa9f8554fc41890', 'd22cda7beb5cea5967b267e52d79ab99')
      and md5(pg_get_functiondef('booking._order_balance(bigint)'::regprocedure)) = 'a6b31f93559de53d75a52d8a285f1170'
      and md5(pg_get_functiondef('booking.is_staff()'::regprocedure)) = '40d8b86aa41ab71f29ef4e6c5257aa77', 'A5 riippuvuudet ennallaan (asiakkaan 14 vrk, pikakassa 1 vrk)');

  -- ===== fixture (feikki, vain tässä transaktiossa)
  insert into booking.integration_config(key, mode, settings) values ('vismapay', 'test', '{"approved_by":"t184"}'::jsonb)
    on conflict (key) do update set mode = 'test', settings = booking.integration_config.settings || '{"approved_by":"t184"}'::jsonb;
  insert into booking.integration_config(key, mode, settings) values ('mobilepay', 'test', '{"approved_by":"t184"}'::jsonb)
    on conflict (key) do update set mode = 'test', settings = booking.integration_config.settings || '{"approved_by":"t184"}'::jsonb;
  insert into booking.integration_config(key, mode, settings) values ('montonio', 'test', '{"approved_by":"t184"}'::jsonb)
    on conflict (key) do update set mode = 'test', settings = booking.integration_config.settings || '{"approved_by":"t184"}'::jsonb;
  if v_has_rl then update booking.settings set value = '500'::jsonb where key = 'rl_order_get_per_10min';
  else insert into booking.settings(key, value) values ('rl_order_get_per_10min', '500'::jsonb); end if;
  insert into auth.users(id, email) values (u_adm, 't184-admin-' || run || '@example.test');
  insert into booking.staff(user_id, email, name, role) values (u_adm, 't184-admin-' || run || '@example.test', 't184 admin', 'admin');
  insert into booking.customers(name, email, phone) values ('T184 Asiakas ' || run, 't184-' || run || '@example.test', '+358401840184') returning id into cu;
  o := pg_temp.mkorder(cu, 49); o2 := pg_temp.mkorder(cu, 59); o3 := pg_temp.mkorder(cu, 30); o4 := pg_temp.mkorder(cu, 30); o5 := pg_temp.mkorder(cu, 30);
  o6 := pg_temp.mkorder(cu, 30); o7 := pg_temp.mkorder(cu, 30); o8 := pg_temp.mkorder(cu, 30); o9 := pg_temp.mkorder(cu, 30); o10 := pg_temp.mkorder(cu, 30);

  -- ===== B henkilökunnan linkki
  r := pg_temp.link(u_adm, o); p1 := (r ->> 'pid')::bigint;
  perform pg_temp.ck(p1 is not null and pg_temp.nd(p1) and r ? 'expires_at' and r -> 'expires_at' = 'null'::jsonb, 'B1 oletus: link_expires_at null + merkintä, vastaus expires_at null ' || left(r::text, 120));
  r2 := pg_temp.link(u_adm, o);
  perform pg_temp.ck((r2 ->> 'pid')::bigint = p1 and pg_temp.nd(p1) and (select count(*) from booking.payments where order_id = o) = 1, 'B2 toisto käyttää saman takarajattoman linkin');
  perform pg_temp.ck(pg_temp.link(u_adm, o, 0) ->> 'code' = 'invalid_param' and pg_temp.link(u_adm, o, 61) ->> 'code' = 'invalid_param'
      and pg_temp.link(u_adm, o, -1) ->> 'code' = 'invalid_param' and pg_temp.nd(p1), 'B3 0 / 61 / -1 → invalid_param, linkki koskematon');
  r := pg_temp.link(u_adm, o, 7); p2 := (r ->> 'pid')::bigint;
  perform pg_temp.ck(p2 <> p1 and (select status from booking.payments where id = p1) = 'cancelled'
      and (select abs(extract(epoch from link_expires_at - (now() + interval '7 days'))) < 5 and raw is null from booking.payments where id = p2), 'B4 henkilökunnan 7 vrk korvaa takarajattoman, raw ei merkintää');
  r := pg_temp.link(u_adm, o); p3 := (r ->> 'pid')::bigint;
  perform pg_temp.ck(p3 not in (p1, p2) and (select status from booking.payments where id = p2) = 'cancelled' and pg_temp.nd(p3), 'B5 takarajaton pyyntö korvaa takarajallisen');
  r := pg_temp.link(u_adm, o2, 1); r2 := pg_temp.link(u_adm, o3, 60);
  perform pg_temp.ck((select abs(extract(epoch from link_expires_at - (now() + interval '1 day'))) < 5 from booking.payments where id = (r ->> 'pid')::bigint)
      and (select abs(extract(epoch from link_expires_at - (now() + interval '60 days'))) < 5 from booking.payments where id = (r2 ->> 'pid')::bigint), 'B6 1 ja 60 vrk kelpaavat');
  r2 := pg_temp.link(u_adm, o2, 1);
  perform pg_temp.ck((r2 ->> 'pid')::bigint = (r ->> 'pid')::bigint, 'B7 takarajallinen toisto käyttää takarajallisen linkin kuten ennen');

  -- ===== C asiakkaan / järjestelmän polut eivät peru takarajatonta linkkiä
  update booking.integration_config set mode = 'live' where key = 'vismapay';   -- _public_pay_json toimii vain live-tilassa (transaktio kumotaan)
  r := booking._public_pay_json(o);
  update booking.integration_config set mode = 'test' where key = 'vismapay';
  perform pg_temp.ck(r is not null and pg_temp.nd(p3) and (select count(*) from booking.payments where order_id = o and status = 'pending') = 1
      and r -> 'expires_at' = 'null'::jsonb, 'C1 tilaussivu (_public_pay_json 14 vrk) käyttää takarajattoman linkin, ei peru ' || coalesce(left(r::text, 100), 'null'));
  r := booking._create_link_payment(o, 1, null);
  perform pg_temp.ck((r ->> 'payment_id')::bigint = p3 and pg_temp.nd(p3), 'C2 _create_link_payment 1 vrk ilman henkilökuntaa (pikakassa) käyttää takarajattoman linkin');
  insert into booking.payments(order_id, method, provider, status, amount, currency, note) values (o4, 'visma_pay', 'visma_pay', 'pending', 30, 'EUR', 'Visma Pay') returning id into pc;
  r := pg_temp.link(u_adm, o4);
  perform pg_temp.ck((r ->> 'pid')::bigint <> pc and (select status from booking.payments where id = pc) = 'cancelled' and pg_temp.nd((r ->> 'pid')::bigint),
      'C3 merkitsemätön verkkokaupan null-rivi ei kelpaa takarajattomaksi linkiksi (korvataan)');
  insert into booking.payments(order_id, method, provider, status, amount, currency, note) values (o5, 'visma_pay', 'visma_pay', 'pending', 30, 'EUR', 'Visma Pay') returning id into pc;
  r := booking._create_link_payment(o5, 14, null);
  perform pg_temp.ck((r ->> 'payment_id')::bigint = pc and (select link_expires_at is null and status = 'pending' from booking.payments where id = pc), 'C4 takarajallinen pyyntö + verkkokaupan null-rivi: ennallaan (käyttää)');

  -- ===== D admin_add_to_order
  perform pg_temp.login(u_adm);
  begin
    r := booking.admin_add_to_order(o6, '[{"type":"custom","description":"T184 lisärivi","amount":"10","vat_rate":"25.5"}]'::jsonb, true, false, 'T184 lisäys');
  exception when others then r := jsonb_build_object('err', sqlstate || ' ' || sqlerrm);
  end;
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and r -> 'payment' ->> 'payment_id' is not null and pg_temp.nd((r -> 'payment' ->> 'payment_id')::bigint)
      and (select amount from booking.payments where id = (r -> 'payment' ->> 'payment_id')::bigint) = 40, 'D1 admin_add_to_order linkki ilman takarajaa ' || left(r::text, 160));

  -- ===== E cron, saldo, julkinen tieto
  r := pg_temp.link(u_adm, o7); p1 := (r ->> 'pid')::bigint;
  r := pg_temp.link(u_adm, o8, 3); p2 := (r ->> 'pid')::bigint;
  update booking.payments set created_at = now() - interval '100 days' where id = p1;
  update booking.payments set link_expires_at = now() - interval '1 minute' where id = p2;
  perform booking.expire_payment_links();
  perform pg_temp.ck(pg_temp.nd(p1) and (select status from booking.payments where id = p2) = 'cancelled', 'E1 cron: takarajaton jää, vanhentunut takarajallinen perutaan');
  perform pg_temp.ck((booking._order_balance(o7) ->> 'pending_link')::numeric = 30 and (select payment_status from booking.orders where id = o7) = 'pending', 'E2 saldo pending_link 30, tilaus pending');
  r := pg_temp.info(pg_temp.tok(p1));
  perform pg_temp.ck(r ->> 'status' = 'open' and (r ->> 'can_pay')::boolean and r -> 'expires_at' = 'null'::jsonb and r ->> 'expires_date' is null and (r ->> 'amount')::numeric = 30,
      'E3 link_info: open, can_pay, expires_at null ' || left(r::text, 120));

  -- ===== F verkkomaksu (Montonio-linkki)
  tk := pg_temp.tok(p1);
  r := pg_temp.mprep(tk, null); a1 := r ->> 'order_number';
  perform pg_temp.mcreated(a1);
  r := pg_temp.mapply(a1, 'cancelled');
  select * into prow from booking.payments where id = p1;
  perform pg_temp.ck(r ->> 'outcome' = 'cancelled' and (r ->> 'retryable')::boolean and prow.status = 'pending' and prow.link_expires_at is null
      and prow.raw ->> 'paylink' = 'no_deadline' and pg_temp.audits(p1, 'MONTONIO_CANCELLED_RETRYABLE') = 1, 'F1 takarajaton linkki: peruutus → retryable, null ja merkintä säilyvät ' || left(r::text, 100));
  perform pg_temp.ck(pg_temp.info(tk) ->> 'status' = 'open' and pg_temp.info(tk) ->> 'last_attempt' = 'cancelled', 'F2 link_info open, last_attempt cancelled');
  r := pg_temp.mprep(tk, null); a2 := r ->> 'order_number';
  perform pg_temp.ck(r ->> 'ok' = 'true' and a2 ~ '-a2$' and (r ->> 'payment_id')::bigint = p1, 'F3 uusi yritys -a2 samalle maksulle');
  perform pg_temp.mcreated(a2);
  r := pg_temp.mapply(a2, 'paid', 30);
  perform pg_temp.ck(r ->> 'ok' = 'true' and (select status from booking.payments where id = p1) = 'paid' and (select payment_status from booking.orders where id = o7) = 'paid', 'F4 maksu -a2 → paid ' || left(r::text, 100));
  -- verkkokaupan maksurivi ilman takarajaa (public_create_booking / public_buy_gift_card -tyyli): EI linkki
  insert into booking.payments(order_id, method, provider, status, amount, currency, note) values (o9, 'visma_pay', 'visma_pay', 'pending', 30, 'EUR', 'Visma Pay') returning id into pc;
  select public_token into otok from booking.orders where id = o9;
  r := pg_temp.prep(null, otok);
  perform pg_temp.ck(r ->> 'code' = 'payment_not_online'
      and (select provider = 'visma_pay' and status = 'pending' and link_expires_at is null from booking.payments where id = pc),
      'F5 tilaustoken ei avaa Visma-maksua, rivi jää pending ' || left(r::text, 100));
  r := pg_temp.prep(null, otok);
  perform pg_temp.ck(r ->> 'code' = 'payment_not_online'
      and (select status from booking.payments where id = pc) = 'pending'
      and (select count(*) from booking.payments where order_id = o9 and provider = 'visma_pay') = 1,
      'F6 toinen Visma-aloitus ei luo riviä eikä merkitse maksettua ' || left(r::text, 100));

  -- ===== G MobilePay (lepotilassa): montonio-linkkiä ei avata MobilePaylla
  r := pg_temp.link(u_adm, o10); p1 := (r ->> 'pid')::bigint;
  r := pg_temp.mp(null, pg_temp.tok(p1), 'WEB_REDIRECT');
  perform pg_temp.ck(r ->> 'code' = 'payment_not_online'
      and (select provider = 'montonio' and link_expires_at is null and raw ->> 'paylink' = 'no_deadline' and status = 'pending' from booking.payments where id = p1),
      'G1 linkkitoken MobilePaylla montonio-linkille: payment_not_online, rivi ennallaan ' || left(r::text, 120));
  select public_token into otok from booking.orders where id = o10;
  r := pg_temp.mp(otok, null, 'QR');
  perform pg_temp.ck((select provider = 'montonio' and link_expires_at is null and raw ->> 'paylink' = 'no_deadline' and status = 'pending' from booking.payments where id = p1),
      'G2 tilaustoken ei muuta takarajatonta montonio-linkkiä ' || left(r::text, 100));
  o := pg_temp.mkorder(cu, 30);
  r := pg_temp.link(u_adm, o, 14); p2 := (r ->> 'pid')::bigint;
  r := pg_temp.mp(null, pg_temp.tok(p2), 'WEB_REDIRECT');
  select public_token into otok from booking.orders where id = o;
  r := pg_temp.mp(otok, null, 'QR');
  perform pg_temp.ck(r ->> 'code' = 'payment_not_online' and (select provider = 'montonio' and link_expires_at > now() + interval '13 days' from booking.payments where id = p2),
      'G3 14 vrk montonio-linkki: tilaustokenin MobilePay-aloitus estetty, linkki ei lyhene ' || left(r::text, 100));
  o := pg_temp.mkorder(cu, 30);
  select public_token into otok from booking.orders where id = o;
  n := (select count(*) from booking.payments where order_id = o);
  r := pg_temp.mp(otok, null, 'WEB_REDIRECT');
  perform pg_temp.ck(r ->> 'code' = 'payment_not_online' and (select count(*) from booking.payments where order_id = o) = n,
      'G4 verkkokaupan MobilePay-aloitus estetty ' || left(r::text, 100));
  r := pg_temp.mp(otok, null, 'QR');
  perform pg_temp.ck(r ->> 'code' = 'payment_not_online' and (select count(*) from booking.payments where order_id = o) = n,
      'G5 QR-aloitus estetty, uutta maksuriviä ei synny ' || left(r::text, 100));

  -- palautus (transaktio kumotaan joka tapauksessa)
  if s_vp.key is null then delete from booking.integration_config where key = 'vismapay'; else update booking.integration_config set mode = s_vp.mode, settings = s_vp.settings where key = 'vismapay'; end if;
  if s_mp.key is null then delete from booking.integration_config where key = 'mobilepay'; else update booking.integration_config set mode = s_mp.mode, settings = s_mp.settings where key = 'mobilepay'; end if;
  if v_has_rl then update booking.settings set value = s_rl where key = 'rl_order_get_per_10min'; else delete from booking.settings where key = 'rl_order_get_per_10min'; end if;

  log := current_setting('t184.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  ns := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'S %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% skip=% %', np, nf, ns, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
select 't184 leftover rows = ' || ((select count(*) from booking.customers where email like 't184-%@example.test') + (select count(*) from auth.users where email like 't184-%@example.test')) as t184_check;
