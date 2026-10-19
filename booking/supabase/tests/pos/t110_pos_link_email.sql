-- t110: pikakassan maksulinkki sähköpostiin (booking_110). Rollback-transaktio: lopuksi tahallinen poikkeus.
-- Kelpaamaton osoite, tuplakutsu (yksi outbox-rivi), uudelleenlähetyksen katto ja rate_limited,
-- ei oikeutta, maskaus, tilaus ei muokattavissa. Ei muuta resend- eikä vismapay-tilaa.
-- Ei CI:ssä. GitHub Pages -työnkulussa ei ole Postgresia, ja booking/supabase/tests/run.sh ajaa vain juuren [0-9]*.test.sql.
-- Bottiavustus ajaa tämän psql:llä migraatioiden jälkeen.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t110.log', '', true);
create function public.t110_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t110.log', coalesce(current_setting('t110.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t110_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 160) end;
end $$;
create function public.t110_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t110_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_staff uuid := gen_random_uuid();
  u_plain uuid := gen_random_uuid();
  p_vichy bigint;
  items jsonb;
  res jsonb;
  res2 jsonb;
  oid bigint;
  oid2 bigint;
  pid bigint;
  n int;
  v_email text := 'asiakas@example.test';
  v_mode text;
  v_visma text;
  log text;
  npass int;
  nfail int;
begin
  select mode into v_mode from booking.integration_config where key = 'resend';
  select mode into v_visma from booking.integration_config where key = 'vismapay';

  perform public.t110_ck(not has_function_privilege('anon', 'booking.admin_pos_send_link(bigint,text,boolean)', 'execute'), 'G1 anon ei send_link');
  perform public.t110_ck(not has_function_privilege('public', 'booking.admin_pos_send_link(bigint,text,boolean)', 'execute'), 'G2 public ei send_link');
  perform public.t110_ck(not has_function_privilege('anon', 'booking.admin_pos_email_status(bigint)', 'execute'), 'G3 anon ei email_status');
  perform public.t110_ck(not has_function_privilege('public', 'booking.admin_pos_email_status(bigint)', 'execute'), 'G4 public ei email_status');
  perform public.t110_ck(has_function_privilege('authenticated', 'booking.admin_pos_send_link(bigint,text,boolean)', 'execute'), 'G5 authenticated saa send_link');
  perform public.t110_ck(has_function_privilege('authenticated', 'booking.admin_pos_email_status(bigint)', 'execute'), 'G6 authenticated saa email_status');
  perform public.t110_ck((select prosecdef and proconfig::text like '%search_path=%' from pg_proc where proname = 'admin_pos_send_link' and pronamespace = 'booking'::regnamespace), 'G7 send_link definer ja search_path');
  perform public.t110_ck((select prosecdef and proconfig::text like '%search_path=%' from pg_proc where proname = 'admin_pos_email_status' and pronamespace = 'booking'::regnamespace), 'G8 email_status definer ja search_path');

  insert into kb.products(name, category, price, vat_rate, active) values ('Vichy', 'other', 3.00, 13.5, true) returning id into p_vichy;
  insert into booking.product_config(product_id, sale_kind, bookable, pos_enabled, pos_sort, fridge_sale)
  values (p_vichy, 'other', false, true, 10, true);
  items := jsonb_build_array(jsonb_build_object('product_id', p_vichy, 'quantity', 1));

  insert into auth.users(id, email) values (u_staff, 't110-staff@example.test'), (u_plain, 't110-plain@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_staff, 't110-staff@example.test', 't110 staff', 'staff'),
    (u_plain, 't110-plain@example.test', 't110 plain', 'staff');

  delete from booking.role_permissions where role_code = 'staff' and permission = 'pos.use';
  perform public.t110_login(u_plain);
  perform public.t110_ck(public.t110_try(format('select booking.admin_pos_send_link(1, %L, false)', v_email)) = 'forbidden', 'R1 ilman pos.use kielletty');
  perform public.t110_ck(public.t110_try('select booking.admin_pos_email_status(1)') = 'forbidden', 'R2 tilakysely ilman oikeutta kielletty');
  perform public.t110_logout();
  insert into booking.role_permissions(role_code, permission) values ('staff', 'pos.use');
  delete from booking.role_permissions where role_code = 'staff' and permission = 'payments.manage';
  perform public.t110_login(u_plain);
  res := booking.admin_pos_checkout(items, 'fi', null);
  oid := (res->>'order_id')::bigint;
  perform public.t110_ck(public.t110_try(format('select booking.admin_create_payment_link(%s, false, 1, ''pikakassa'')', oid)) = 'forbidden', 'R3 payments.manage puuttuu, create_payment_link kielletty');
  res := booking.admin_pos_send_link(oid, '  Asiakas@Example.Test  ', false);
  perform public.t110_ck(res->>'ok' = 'true', 'R4 pos.use riittää send_linkiin');
  perform public.t110_logout();
  insert into booking.role_permissions(role_code, permission) values ('staff', 'payments.manage');

  perform public.t110_login(u_staff);
  perform public.t110_ck((select customer_id from booking.orders where id = oid) is not null, 'C1 asiakas luotiin');
  perform public.t110_ck((select marketing_consent from booking.customers c join booking.orders o on o.customer_id = c.id where o.id = oid) = false, 'C2 ei markkinointilupaa');
  perform public.t110_ck((select marketing_consent_source from booking.customers c join booking.orders o on o.customer_id = c.id where o.id = oid) = 'pikakassa', 'C3 lähde pikakassa');
  perform public.t110_ck((select email from booking.customers c join booking.orders o on o.customer_id = c.id where o.id = oid) = v_email, 'C4 osoite lowercase ja trim');

  perform public.t110_ck(public.t110_try(format('select booking.admin_pos_send_link(%s, %L, false)', oid, 'ei-kelpaa')) = 'invalid_email', 'E1 kelpaamaton osoite');
  perform public.t110_ck(public.t110_try(format('select booking.admin_pos_send_link(%s, %L, false)', oid, '   ')) = 'invalid_email', 'E2 tyhjä osoite');
  perform public.t110_ck((select count(*) from booking.email_outbox where order_id = oid and kind = 'payment_link') = 1, 'E3 virhe ei luonut toista riviä');

  res2 := booking.admin_pos_send_link(oid, v_email, false);
  select count(*) into n from booking.email_outbox where order_id = oid and dedupe_key like 'pos_link:%';
  perform public.t110_ck(n = 1 and res2->>'email_queued' = 'false', 'D1 tuplakutsu ei luo uutta riviä');
  perform public.t110_ck(res->>'payment_id' = res2->>'payment_id', 'D2 sama maksu');
  pid := (res->>'payment_id')::bigint;
  perform public.t110_ck(res->>'outbox_status' = case when coalesce(v_mode, 'off') = 'off' then 'skipped' else 'pending' end, 'D3 jonon tila seuraa nykyistä resend-tilaa');
  perform public.t110_ck(res->>'masked_to' = 'a***@e***.test', 'M1 maskaus');
  perform public.t110_ck(position(v_email in res::text) = 0 and position(v_email in res2::text) = 0, 'M2 vastauksessa ei ole kokonaista osoitetta');
  perform public.t110_ck(res->>'link_path' like '%?p=%' and (res->>'amount')::numeric = 3, 'L1 linkki ja summa');

  perform public.t110_ck(public.t110_try(format('select booking.admin_pos_send_link(%s, %L, true)', oid, v_email)) = 'rate_limited', 'S1 edellinen alle 60 s');
  perform public.t110_ck((select count(*) from booking.email_outbox where payment_id = pid and dedupe_key like 'pos_link:' || pid::text || ':%') = 1, 'S2 rate_limited ei lisännyt riviä');
  perform public.t110_logout();
  update booking.email_outbox set created_at = now() - interval '2 minutes' where payment_id = pid and dedupe_key like 'pos_link:%';
  perform public.t110_login(u_staff);
  res := booking.admin_pos_send_link(oid, v_email, true);
  perform public.t110_ck(res->>'ok' = 'true' and res->>'email_queued' = 'true', 'S3 uudelleenlähetys onnistuu vanhan rivin jälkeen');
  perform public.t110_ck((select count(*) from booking.email_outbox where payment_id = pid and dedupe_key like 'pos_link:' || pid::text || ':%') = 2, 'S4 kaksi pos_link-riviä');
  perform public.t110_logout();
  update booking.email_outbox set created_at = now() - interval '2 minutes' where payment_id = pid and dedupe_key like 'pos_link:%';
  perform public.t110_login(u_staff);
  perform booking.admin_pos_send_link(oid, v_email, true);
  perform public.t110_logout();
  update booking.email_outbox set created_at = now() - interval '2 minutes' where payment_id = pid and dedupe_key like 'pos_link:%';
  perform public.t110_login(u_staff);
  perform public.t110_ck(public.t110_try(format('select booking.admin_pos_send_link(%s, %L, true)', oid, v_email)) = 'rate_limited', 'S5 neljäs lähetys torjutaan');
  perform public.t110_ck((select count(*) from booking.email_outbox where payment_id = pid and dedupe_key like 'pos_link:' || pid::text || ':%') = 3, 'S6 enintään kolme lähetystä');

  perform public.t110_logout();
  update booking.email_outbox set last_error = repeat('x', 200) where id = (select max(id) from booking.email_outbox where order_id = oid);
  perform public.t110_login(u_staff);
  res := booking.admin_pos_email_status(oid);
  perform public.t110_ck(res->>'ok' = 'true' and res->>'masked_to' = 'a***@e***.test', 'T1 tila maskattuna');
  perform public.t110_ck(char_length(res->>'last_error') = 120, 'T2 virhe katkaistaan');
  perform public.t110_ck(position(v_email in res::text) = 0, 'T3 tilavastauksessa ei ole kokonaista osoitetta');
  perform public.t110_ck((res->>'attempts') is not null and (res->>'max_attempts') is not null and res ? 'sent_at' and res ? 'status', 'T4 tilakentät');

  res := booking.admin_pos_checkout(items, 'fi', 'vanha@example.test');
  oid2 := (res->>'order_id')::bigint;
  perform booking.admin_pos_send_link(oid2, 'uusi@example.test', false);
  perform public.t110_ck((select email from booking.customers c join booking.orders o on o.customer_id = c.id where o.id = oid2) = 'uusi@example.test', 'C5 maksamattoman osoite päivittyy');

  perform public.t110_logout();
  update booking.orders set status = 'cancelled' where id = oid2;
  perform public.t110_login(u_staff);
  perform public.t110_ck(public.t110_try(format('select booking.admin_pos_send_link(%s, %L, false)', oid2, 'uusi@example.test')) = 'order_not_editable', 'X1 peruttu tilaus ei muokattavissa');
  res := booking.admin_pos_checkout(items, 'fi', v_email);
  perform public.t110_logout();
  update booking.orders set payment_status = 'paid' where id = (res->>'order_id')::bigint;
  perform public.t110_login(u_staff);
  perform public.t110_ck(public.t110_try(format('select booking.admin_pos_send_link(%s, %L, false)', (res->>'order_id')::bigint, v_email)) = 'order_not_editable', 'X2 maksettu tilaus ei muokattavissa');
  perform public.t110_ck(public.t110_try('select booking.admin_pos_send_link(0, ''a@b.co'', false)') = 'not_found', 'X3 tuntematon tilaus');
  perform public.t110_logout();
  insert into booking.orders(status, payment_status, total_gross, currency, source_channel)
  values ('pending', 'unpaid', 3, 'EUR', 'web') returning id into oid2;
  perform public.t110_login(u_staff);
  perform public.t110_ck(public.t110_try(format('select booking.admin_pos_send_link(%s, %L, false)', oid2, v_email)) = 'not_found', 'X4 muu lähde ei ole pikakassa');
  perform public.t110_logout();

  perform public.t110_ck((select mode from booking.integration_config where key = 'resend') is not distinct from v_mode, 'Z1 resend-tila ennallaan');
  perform public.t110_ck((select mode from booking.integration_config where key = 'vismapay') is not distinct from v_visma, 'Z2 vismapay-tila ennallaan');

  log := current_setting('t110.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
