-- t123: asetussivun luku ja korttitallennus (booking_123). Lopuksi tahallinen poikkeus, data rullaa takaisin.
drop function if exists public.t123_ck(boolean, text);
drop function if exists public.t123_try(text);
drop function if exists public.t123_call(text);
drop function if exists public.t123_login(uuid);
drop function if exists public.t123_logout();
set local lock_timeout = '3s';
set local statement_timeout = '60s';
select set_config('t123.log', '', true);
create function public.t123_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t123.log', coalesce(current_setting('t123.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t123_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 180) end;
end $$;
create function public.t123_call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text; s text;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return jsonb_build_object('err', case when s = 'BK001' then d else s || ':' || left(m, 180) end);
end $$;
create function public.t123_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t123_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_staff uuid := gen_random_uuid();
  u_mgr uuid := gen_random_uuid();
  u_admin uuid := gen_random_uuid();
  got jsonb; bad jsonb; seller jsonb; payload jsonb; resend_mode text; pay_mode text; npass int; nfail int; log text;
begin
  insert into auth.users(id, email) values
    (u_staff, 't123-staff-' || u_staff::text || '@example.test'),
    (u_mgr, 't123-mgr-' || u_mgr::text || '@example.test'),
    (u_admin, 't123-admin-' || u_admin::text || '@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_staff, 't123-staff-' || u_staff::text || '@example.test', 't123 staff', 'staff'),
    (u_mgr, 't123-mgr-' || u_mgr::text || '@example.test', 't123 manager', 'manager'),
    (u_admin, 't123-admin-' || u_admin::text || '@example.test', 't123 admin', 'admin');
  update booking.settings set value = jsonb_set(coalesce(value, '{}'::jsonb), '{logo_url}', to_jsonb('https://example.test/logo.png'::text), true) where key = 'seller';
  select mode into resend_mode from booking.integration_config where key = 'resend';
  select value #>> '{}' into pay_mode from booking.settings where key = 'public_payment_mode';

  perform public.t123_login(u_staff);
  got := public.t123_call('booking.admin_settings_bundle()');
  perform public.t123_ck(got ->> 'qr_only' = 'true' and got -> 'settings' is null, 'staff vain qr');
  perform public.t123_ck(public.t123_try($s$select booking.admin_save_settings('pause', '{"public_booking_enabled":false}'::jsonb)$s$) = 'forbidden', 'staff ei tallenna');
  perform public.t123_logout();

  perform public.t123_login(u_mgr);
  got := public.t123_call('booking.admin_settings_bundle()');
  perform public.t123_ck(got ->> 'err' is null and got ->> 'qr_only' = 'false' and got ->> 'role' = 'manager', 'manager lukee');
  perform public.t123_ck((got -> 'resend') ? 'allowlist_on' and not ((got -> 'resend') ? 'test_recipients'), 'allowlist ilman listaa');
  seller := jsonb_build_object(
    'name', 'Havuhattu Oy / Sipoonjoen Perinnesauna', 'legal_name', 'Havuhattu Oy', 'trade_name', 'Sipoonjoen Perinnesauna',
    'business_id', '3018112-1', 'vat_id', 'FI30181121', 'street', 'Hindsbyntie 124', 'postal_code', '04130', 'city', 'Sipoo',
    'country', 'FI', 'phone', '010 299 2866', 'email', 'savusauna@saunotus.fi', 'website', 'https://saunotus.fi', 'footer', 'Kiitos käynnistä!');
  payload := jsonb_build_object('business_name', 'Sipoonjoen Perinnesauna', 'seller', seller || jsonb_build_object('business_id', '3018112-2'));
  bad := public.t123_call(format('booking.admin_save_settings(%L, %L::jsonb)', 'business', payload::text));
  perform public.t123_ck(bad ->> 'err' = 'invalid_value', 'väärä y-tunnus');
  payload := jsonb_build_object('business_name', 'Sipoonjoen Perinnesauna', 'seller', seller || jsonb_build_object('footer', 'Kiitos testistä'));
  got := public.t123_call(format('booking.admin_save_settings(%L, %L::jsonb)', 'business', payload::text));
  perform public.t123_ck(got ->> 'err' is null and got ->> 'ok' = 'true', 'yritys tallentuu');
  perform public.t123_ck(public.t123_try($s$select booking.admin_save_settings('pause', '{"public_booking_enabled":true,"public_payment_mode":"hold_until_paid"}'::jsonb)$s$) = 'invalid_value', 'maksutila ei tallennu');
  perform public.t123_ck(public.t123_try($s$select booking.admin_save_settings('vismapay', '{"mode":"live"}'::jsonb)$s$) = 'unknown_section', 'visma-osio hylätään');
  perform public.t123_ck(public.t123_try($s$select booking.admin_save_settings('email_sender', '{"from_name":"Sauna","reply_to":"savusauna@saunotus.fi","test_recipients":[]}'::jsonb)$s$) = 'invalid_value', 'allowlist ei tallennu');
  perform public.t123_ck(public.t123_try($s$select booking.admin_save_settings('payment_methods', '{"methods":{"cash":true,"card_terminal":true}}'::jsonb)$s$) = 'cash_not_accepted', 'käteinen hylätään');
  got := public.t123_call($s$booking.admin_save_settings('payment_hold', '{"checkout_hold_minutes":20,"checkout_mobilepay_grace_minutes":10,"checkout_mobilepay_max_wait_minutes":25}'::jsonb)$s$);
  perform public.t123_ck(got ->> 'err' is null, 'pito tallentuu');
  perform public.t123_ck(public.t123_try($s$select booking.admin_save_settings('technical', '{"limits":{"rl_ip_per_10min":12}}'::jsonb)$s$) = 'forbidden', 'manager ei tallenna teknistä');
  perform public.t123_logout();

  perform public.t123_ck((select value #>> '{}' from booking.settings where key = 'hold_minutes') = '20', 'hold_minutes seuraa');
  perform public.t123_ck((select value #>> '{}' from booking.settings where key = 'checkout_hold_minutes') = '20', 'checkout hold');
  perform public.t123_ck((select value ->> 'logo_url' from booking.settings where key = 'seller') = 'https://example.test/logo.png', 'logo säilyy');
  perform public.t123_ck((select value ->> 'footer' from booking.settings where key = 'seller') = 'Kiitos testistä', 'alatunniste vaihtui');
  perform public.t123_ck((select active from booking.payment_methods where code = 'cash') = false, 'käteinen yhä pois');
  perform public.t123_ck((select mode from booking.integration_config where key = 'resend') = resend_mode, 'sähköpostin tila ennallaan');
  perform public.t123_ck((select value #>> '{}' from booking.settings where key = 'public_payment_mode') is not distinct from pay_mode, 'maksutila ennallaan');

  perform public.t123_login(u_admin);
  got := public.t123_call($s$booking.admin_save_settings('technical', '{"limits":{"rl_ip_per_10min":13}}'::jsonb)$s$);
  perform public.t123_ck(got ->> 'err' is null, 'admin tallentaa rajan');
  perform public.t123_logout();
  perform public.t123_ck((select value #>> '{}' from booking.settings where key = 'rl_ip_per_10min') = '13', 'raja 13');

  log := current_setting('t123.log', true);
  npass := (select count(*) from regexp_matches(log, '^P ', 'gn'));
  nfail := (select count(*) from regexp_matches(log, '^F ', 'gn'));
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, case when nfail = 0 then 'ALL OK' else log end;
end $t$;
