set local lock_timeout = '3s'; set local statement_timeout = '60s';
select set_config('t62.log', '', true);
create function public.t62_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t62.log', coalesce(current_setting('t62.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t62_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 80) end;
end $$;
create function public.t62_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t62_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;
do $t$
declare u_bot uuid := gen_random_uuid(); u_otto uuid := gen_random_uuid(); u_adm uuid := gen_random_uuid(); r jsonb; n0 int; v bigint; log text; npass int; nfail int; txt text;
begin
  select count(*) into n0 from booking.site_texts;
  insert into auth.users(id, email) values (u_bot, 't62-bot@example.test'), (u_otto, 't62-otto@example.test'), (u_adm, 't62-admin@example.test');
  insert into booking.text_bots(user_id, label) values (u_bot, 't62 bot');
  insert into booking.staff(user_id, email, name, role) values (u_otto, 't62-otto@example.test', 't62 otto', 'manager'), (u_adm, 't62-admin@example.test', 't62 admin', 'admin');
  perform public.t62_login(u_otto);
  perform public.t62_ck(public.t62_try($q$select booking.admin_texts_import('[]'::jsonb)$q$) = 'forbidden', 'I1: Otto ei tuo');
  perform public.t62_logout(); perform public.t62_login(u_bot);
  perform public.t62_ck(public.t62_try($q$select booking.admin_texts_import('[]'::jsonb)$q$) = 'forbidden', 'I2: botti ei tuo');
  perform public.t62_logout(); perform public.t62_login(u_adm);
  r := booking.admin_texts_import($j$[
    {"key":"ui.shop.cta_book","lang":"fi","text":"Varaa aika"},
    {"key":"ui.shop.cta_book","lang":"en","text":"Book now"},
    {"key":"ui.shop.price_from","lang":"fi","text":"Hinta alkaen {{price:7}}","placeholders":["{{price:7}}"],"class":"protected"},
    {"key":"ui.bad","lang":"fi","text":"Hinta {{price:7}}"},
    {"key":"product.99.description","lang":"fi","text":"varattu"},
    {"key":"Ui Huono Avain","lang":"fi","text":"x"},
    {"key":"ui.html","lang":"fi","text":"<script>alert(1)</script>"},
    {"key":"ui.lang","lang":"sv","text":"hej"},
    {"key":"ui.empty","lang":"fi","text":"  "}]$j$::jsonb);
  perform public.t62_logout();
  perform public.t62_ck((r ->> 'created')::int = 3 and (r ->> 'errors')::int = 6, 'I3: luotu 3, virheitä 6: ' || r::text);
  perform public.t62_ck((select array_agg(i ->> 'code' order by ord) from jsonb_array_elements(r -> 'items') with ordinality x(i, ord) where i ->> 'result' = 'error') = array['placeholder_mismatch', 'reserved_key', 'invalid_key', 'html_not_allowed', 'invalid_lang', 'text_empty'], 'I4: virhekoodit riveittäin');
  perform public.t62_ck((select count(*) from booking.site_texts where source_table is null) = 3 and (select count(*) from booking.site_text_versions v join booking.site_texts t on t.id = v.text_id where t.source_table is null and v.version = 1 and v.status = 'published') = 3, 'I5: rivit + versio 1');
  perform public.t62_login(u_adm);
  r := booking.admin_texts_import('[{"key":"ui.shop.cta_book","lang":"fi","text":"Muu teksti"}]'::jsonb);
  perform public.t62_logout();
  perform public.t62_ck((r ->> 'existing')::int = 1 and (select published_text from booking.site_texts where key = 'ui.shop.cta_book' and lang = 'fi') = 'Varaa aika', 'I6: toisto ei ylikirjoita (exists)');
  perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon';
  select x ->> 'text' into txt from jsonb_array_elements(booking.public_get_site_texts('fi') -> 'texts') x where x ->> 'key' = 'ui.shop.price_from';
  select count(*) into n0 from jsonb_array_elements(booking.public_get_site_texts('fi') -> 'texts') x where x ->> 'key' = 'ui.shop.price_from' and x -> 'placeholders' = '["{{price:7}}"]'::jsonb;
  perform public.t62_logout();
  perform public.t62_ck(txt = 'Hinta alkaen {{price:7}}' and n0 = 1, 'I7: anon näkee tekstin ja placeholders-kentän (build täyttää)');
  -- botti ehdottaa muutosta vapaaseen tekstiin: paikkamerkin pitää säilyä; protected -> Joonas
  perform public.t62_login(u_bot);
  perform public.t62_ck(public.t62_try($q$select booking.texts_propose('ui.shop.price_from', 'fi', 'Hinta alkaen')$q$) = 'placeholder_mismatch', 'I8: botti ei voi poistaa paikkamerkkiä');
  r := booking.texts_propose('ui.shop.price_from', 'fi', 'Tästä alkaen {{price:7}}', 'selkeämpi');
  perform public.t62_ck((r ->> 'ok')::boolean and (r ->> 'protected')::boolean, 'I9: ehdotus säilyttää paikkamerkin, protected-luokka -> Joonas hyväksyy');
  r := booking.texts_propose('ui.shop.cta_book', 'fi', 'Varaa aikasi');
  perform public.t62_ck((r ->> 'ok')::boolean and not (r ->> 'protected')::boolean and r ->> 'approver' = 'texts.approve', 'I10: tavallinen vapaa teksti -> Otto hyväksyy');
  perform public.t62_logout();
  log := current_setting('t62.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
