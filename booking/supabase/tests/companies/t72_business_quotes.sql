-- booking_72: tarjouspyyntö, validointi, honeypot, rate limit, RLS (anon luo vain RPC:llä, vain admin/manager lukee).
-- Ajo: psql -v ON_ERROR_STOP=1 -f booking/supabase/tests/companies/t72_business_quotes.sql
set local lock_timeout = '3s'; set local statement_timeout = '60s';
select set_config('t72.log', '', true);
create function public.t72_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t72.log', coalesce(current_setting('t72.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t72_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 100) end;
end $$;
create function public.t72_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t72_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;
do $t$
declare
  u_mgr uuid := gen_random_uuid(); u_adm uuid := gen_random_uuid(); u_st uuid := gen_random_uuid();
  r jsonb; n0 int; n1 int; log text; npass int; nfail int; qid bigint;
begin
  insert into auth.users(id, email) values (u_mgr, 't72-mgr@example.test'), (u_adm, 't72-adm@example.test'), (u_st, 't72-st@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_mgr, 't72-mgr@example.test', 't72 mgr', 'manager'),
    (u_adm, 't72-adm@example.test', 't72 adm', 'admin'),
    (u_st, 't72-st@example.test', 't72 staff', 'staff');

  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.headers', '{"cf-connecting-ip":"203.0.113.20"}', true);
  execute 'set local role anon';
  perform public.t72_ck(public.t72_try('select * from booking.business_quote_requests') like '42501%', 'R1: anon ei lue taulua');
  perform public.t72_ck(public.t72_try($q$insert into booking.business_quote_requests(company_name, contact_name, email, phone, preferred_when, persons, offerings, privacy_accepted) values ('Oy','Maija','a@b.fi','0401234567','ensi viikko',4,array['sauna'],true)$q$) like '42501%', 'R2: anon ei lisää riviä suoraan');
  r := booking.public_create_business_quote('Sipoon Testi Oy', 'Maija Meikäläinen', 'maija@example.test', '0401234567', 'ensi viikon perjantai', 12, '["sauna","ritual"]'::jsonb, null, 'toive metsäkävelystä', 'fi', true, '');
  perform public.t72_ck(r = '{"ok":true,"code":"ok"}'::jsonb, 'R3: kelvollinen pyyntö: ' || coalesce(r::text, 'null'));
  perform public.t72_logout();
  perform public.t72_ck((select count(*) from booking.business_quote_requests where email = 'maija@example.test') = 1, 'R4: yksi rivi, status new');
  perform public.t72_ck((select status from booking.business_quote_requests where email = 'maija@example.test') = 'new', 'R5: tila new');
  perform public.t72_ck((select count(*) from booking.email_outbox where kind = 'business_quote_ack' and payload ->> 'to_email' = 'maija@example.test' and status = 'pending') = 1, 'R6: asiakkaan kuittaus jonossa');
  perform public.t72_ck((select count(*) from booking.email_outbox where kind = 'business_quote_notify' and dedupe_key like 'business_quote_notify:%' and payload ->> 'to_email' = 'savusauna@saunotus.fi') = 1, 'R7: ilmoitus oletusosoitteeseen');

  perform set_config('request.headers', '{"cf-connecting-ip":"203.0.113.21"}', true);
  execute 'set local role anon';
  n0 := (select count(*) from booking.business_quote_requests);
  r := booking.public_create_business_quote('Botti Oy', 'Botti', 'botti@example.test', '0401234567', 'huomenna', 4, '["sauna"]'::jsonb, null, null, 'fi', true, 'http://spam.example');
  perform public.t72_logout();
  perform public.t72_ck(r ->> 'ok' = 'true' and (select count(*) from booking.business_quote_requests) = n0, 'R8: honeypot ei tallenna');
  perform public.t72_ck((select count(*) from booking.email_outbox where payload ->> 'to_email' = 'botti@example.test') = 0, 'R9: honeypot ei sähköpostia');

  update booking.settings set value = '50'::jsonb where key = 'business_quote_rl_ip_per_10min';
  perform set_config('request.headers', '{"cf-connecting-ip":"203.0.113.22"}', true);
  execute 'set local role anon';
  r := booking.public_create_business_quote('Oy', 'Maija', 'x@example.test', '0401234567', 'ensi viikko', 4, '["sauna"]'::jsonb, null, null, 'en', false, '');
  perform public.t72_ck(r ->> 'code' = 'privacy_required', 'R10: tietosuoja');
  r := booking.public_create_business_quote('Oy', 'Maija', 'ei-osoite', '0401234567', 'ensi viikko', 4, '["sauna"]'::jsonb, null, null, 'fi', true, '');
  perform public.t72_ck(r ->> 'code' = 'invalid_email', 'R11: sähköposti');
  r := booking.public_create_business_quote('Oy', 'Maija', 'ok2@example.test', '12', 'ensi viikko', 4, '["sauna"]'::jsonb, null, null, 'fi', true, '');
  perform public.t72_ck(r ->> 'code' = 'invalid_phone', 'R12: puhelin');
  r := booking.public_create_business_quote('Oy', 'Maija', 'ok3@example.test', '0401234567', 'ensi viikko', 4, '[]'::jsonb, null, null, 'fi', true, '');
  perform public.t72_ck(r ->> 'code' = 'invalid_offerings', 'R13: sisällöt');
  r := booking.public_create_business_quote('Oy', 'Maija', 'ok4@example.test', '0401234567', 'ensi viikko', 4, '["other"]'::jsonb, 'x', null, 'fi', true, '');
  perform public.t72_ck(r ->> 'code' = 'invalid_offering_other', 'R14: muu sisältö');
  r := booking.public_create_business_quote('Oy', 'Maija', 'ok5@example.test', '0401234567', 'ensi viikko', 0, '["sauna"]'::jsonb, null, null, 'fi', true, '');
  perform public.t72_ck(r ->> 'code' = 'invalid_persons', 'R15: henkilömäärä');
  perform public.t72_logout();
  perform public.t72_ck((select count(*) from booking.business_quote_requests where email like 'ok%@example.test' or email = 'x@example.test' or email = 'ei-osoite') = 0, 'R16: virheet eivät jätä riviä');

  -- rate limit: 3 onnistunutta / tunti / sähköposti, 4. estetään
  perform set_config('request.headers', '{"cf-connecting-ip":"203.0.113.30"}', true);
  execute 'set local role anon';
  r := booking.public_create_business_quote('Rate Oy', 'Raija', 'rate@example.test', '0401234567', 'syksy', 8, '["forest_yoga"]'::jsonb, null, null, 'fi', true, '');
  r := booking.public_create_business_quote('Rate Oy', 'Raija', 'rate@example.test', '0401234567', 'syksy', 8, '["forest_yoga"]'::jsonb, null, null, 'fi', true, '');
  r := booking.public_create_business_quote('Rate Oy', 'Raija', 'rate@example.test', '0401234567', 'syksy', 8, '["forest_yoga"]'::jsonb, null, null, 'fi', true, '');
  r := booking.public_create_business_quote('Rate Oy', 'Raija', 'rate@example.test', '0401234567', 'syksy', 8, '["forest_yoga"]'::jsonb, null, null, 'fi', true, '');
  perform public.t72_logout();
  perform public.t72_ck(r ->> 'code' = 'rate_limited' and (select count(*) from booking.business_quote_requests where email = 'rate@example.test') = 3, 'R17: rate limit, kolme riviä');

  perform public.t72_login(u_st);
  perform public.t72_ck((select count(*) from booking.business_quote_requests) = 0, 'R18: staffin RLS ei näytä rivejä');
  perform public.t72_ck(public.t72_try($q$select booking.admin_list_business_quotes(null)$q$) = 'forbidden', 'R19: staff ei listaa');
  perform public.t72_logout();
  perform public.t72_login(u_mgr);
  r := booking.admin_list_business_quotes(null);
  perform public.t72_ck(jsonb_array_length(r) >= 4 and (select count(*) from jsonb_array_elements(r) x where x ->> 'email' = 'maija@example.test' and x ->> 'status' = 'new') = 1, 'R20: manager näkee listan');
  select (x ->> 'id')::bigint into qid from jsonb_array_elements(r) x where x ->> 'email' = 'maija@example.test';
  perform booking.admin_set_business_quote_status(qid, 'offered', 'luonnos');
  perform public.t72_ck((select status from booking.business_quote_requests where id = qid) = 'offered' and (select admin_note from booking.business_quote_requests where id = qid) = 'luonnos', 'R21: tila tarjottu');
  perform public.t72_ck(public.t72_try(format('select booking.admin_set_business_quote_status(%s, %L, null)', qid, 'archived')) = 'invalid_status', 'R22: virheellinen tila');
  perform public.t72_logout();
  perform public.t72_login(u_adm);
  r := booking.admin_list_business_quotes('offered');
  perform public.t72_ck((select count(*) from jsonb_array_elements(r) x where (x ->> 'id')::bigint = qid) = 1, 'R23: admin suodattaa tarjotut');
  perform public.t72_logout();

  log := current_setting('t72.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
