-- t103: Procountor-asetusten muokkaus (booking_103). Lopuksi tahallinen poikkeus, data rullaa takaisin.
drop function if exists public.t103_ck(boolean, text);
drop function if exists public.t103_try(text);
drop function if exists public.t103_call(text);
drop function if exists public.t103_login(uuid);
drop function if exists public.t103_logout();
set local lock_timeout = '3s';
set local statement_timeout = '60s';
select set_config('t103.log', '', true);
create function public.t103_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t103.log', coalesce(current_setting('t103.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t103_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 180) end;
end $$;
create function public.t103_call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text; s text;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return jsonb_build_object('err', case when s = 'BK001' then d else s || ':' || left(m, 180) end);
end $$;
create function public.t103_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t103_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_staff uuid := gen_random_uuid();
  u_mgr uuid := gen_random_uuid();
  got jsonb; prev text; npass int; nfail int; log text;
  accounts text := '{"rounding":"3740","sales_by_vat":{"25.5":"3000"},"clearing_by_method":{"cash":"1910"}}';
begin
  insert into auth.users(id, email) values (u_staff, 't103-staff-' || u_staff::text || '@example.test'), (u_mgr, 't103-mgr-' || u_mgr::text || '@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_staff, 't103-staff-' || u_staff::text || '@example.test', 't103 staff', 'staff'),
    (u_mgr, 't103-mgr-' || u_mgr::text || '@example.test', 't103 manager', 'manager');

  perform public.t103_login(u_staff);
  perform public.t103_ck(public.t103_try('select booking.admin_get_procountor_settings()') = 'forbidden', 'staff ei lue');
  perform public.t103_logout();

  perform public.t103_login(u_mgr);
  got := public.t103_call('booking.admin_get_procountor_settings()');
  perform public.t103_ck(got ->> 'mode' in ('off', 'dry_run', 'live'), 'mode kelpaa');
  prev := got ->> 'mode';
  perform public.t103_ck(public.t103_try($s$select booking.admin_set_procountor_settings('{"mode":"live","approved_by":""}'::jsonb)$s$) = 'approval_required', 'live ilman hyväksyjää');
  perform public.t103_ck(public.t103_try($s$select booking.admin_set_procountor_settings('{"mode":"live","approved_by":"Joonas 2026-10-18","vat_status":"","accounts":{"sales_by_vat":{},"clearing_by_method":{}}}'::jsonb)$s$) = 'live_incomplete', 'live ilman tilejä');
  perform public.t103_ck(public.t103_try($s$select booking.admin_set_procountor_settings('{"mode":"dry_run","api_key":"ei"}'::jsonb)$s$) = 'secrets_not_allowed', 'api_key estetty');
  perform public.t103_ck(public.t103_try($s$select booking.admin_set_procountor_settings('{"mode":"dry_run","accounts":{"sales_by_vat":{"25.5":"12-3"}}}'::jsonb)$s$) = 'invalid_setting', 'tili 12-3');
  got := public.t103_call(format($s$booking.admin_set_procountor_settings('{"mode":"dry_run","environment":"sandbox","approved_by":"Joonas 2026-10-18","vat_status":"12","bank_account":"FI21 1234 5600 0007 85","daily_enabled":false,"accounts":%s}'::jsonb)$s$, accounts));
  perform public.t103_ck(got ->> 'err' is null and got ->> 'mode' = 'dry_run', 'dry_run tallentuu');
  perform public.t103_ck(got ->> 'environment' = 'pts', 'sandbox on pts');
  perform public.t103_ck(got #>> '{accounts,sales_by_vat,25.5}' = '3000', 'myyntitili 25.5');
  perform public.t103_ck(got ->> 'bank_account' = 'FI2112345600000785', 'iban ilman välejä');
  perform public.t103_ck(position('api_key' in got::text) = 0, 'vastaus ei sisällä avainta');
  got := public.t103_call(format($s$booking.admin_set_procountor_settings('{"mode":"dry_run","daily_enabled":false,"accounts":%s}'::jsonb)$s$, accounts));
  perform public.t103_ck(got ->> 'err' is null and got ->> 'approved_by' = 'Joonas 2026-10-18' and got ->> 'vat_status' = '12' and got ->> 'bank_account' = 'FI2112345600000785', 'puuttuva avain säilyttää');
  got := public.t103_call(format($s$booking.admin_set_procountor_settings('{"mode":"dry_run","approved_by":"","bank_account":"","vat_status":"","daily_enabled":false,"accounts":%s}'::jsonb)$s$, accounts));
  perform public.t103_ck(got ->> 'err' is null and got ->> 'approved_by' = '' and got ->> 'vat_status' = '' and got ->> 'bank_account' = '', 'tyhjä merkkijono tyhjentää');
  got := public.t103_call(format($s$booking.admin_set_procountor_settings('{"mode":"live","approved_by":"Joonas 2026-10-18","vat_status":"12","daily_enabled":false,"accounts":%s}'::jsonb)$s$, accounts));
  perform public.t103_ck(got ->> 'err' is null and got ->> 'mode' = 'live' and got ->> 'vat_status' = '12' and got #>> '{accounts,clearing_by_method,cash}' = '1910', 'live täydellisillä tileillä');
  got := public.t103_call($s$booking.admin_procountor_preview_daily('2032-06-15'::date)$s$);
  perform public.t103_ck(got ->> 'sent' = 'false', 'esikatselu ei lähetä');
  perform public.t103_ck(position('@' in got::text) = 0, 'esikatselussa ei ole sähköpostia');
  perform public.t103_logout();

  update booking.integration_config set mode = prev where key = 'procountor';

  log := current_setting('t103.log', true);
  npass := (select count(*) from regexp_matches(log, '^P ', 'gn'));
  nfail := (select count(*) from regexp_matches(log, '^F ', 'gn'));
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, case when nfail = 0 then 'ALL OK' else log end;
end $t$;
