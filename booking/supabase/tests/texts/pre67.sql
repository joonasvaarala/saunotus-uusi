set local lock_timeout = '3s'; set local statement_timeout = '90s';
select set_config('t67.log', '', true);
create function public.t67_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t67.log', coalesce(current_setting('t67.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t67_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 80) end;
end $$;
create function public.t67_call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text; s text;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return jsonb_build_object('err', case when s = 'BK001' then d else s || ':' || left(m, 80) end);
end $$;
create function public.t67_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t67_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;
create temp table pre67 as select
  (select string_agg(role_code || ':' || permission, ',' order by role_code, permission) from booking.role_permissions where permission like 'texts.%') perms,
  (select string_agg(code || ':' || sort_order, ',' order by code) from booking.roles) roles,
  (select count(*) from booking.site_texts where class = 'locked') lockedn,
  (select md5(string_agg(id::text || ':' || coalesce(price::text, '') || ':' || coalesce(price_text, '') || ':' || coalesce(vat_rate::text, ''), '|' order by id)) from kb.products) prodsum,
  (select count(*) from booking.text_bots where label = 'Otto tekstibotti' and role_code = 'text_editor') otto_bot_before;
grant select on pre67 to public;
