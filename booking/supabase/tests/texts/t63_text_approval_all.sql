set local lock_timeout = '3s'; set local statement_timeout = '90s';
select set_config('t63.log', '', true);
create function public.t63_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t63.log', coalesce(current_setting('t63.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t63_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 80) end;
end $$;
create function public.t63_call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text; s text;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return jsonb_build_object('err', case when s = 'BK001' then d else s || ':' || left(m, 80) end);
end $$;
create function public.t63_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t63_anon() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon'; end $$;
create function public.t63_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;
do $t$
declare u_bot uuid := gen_random_uuid(); u_otto uuid := gen_random_uuid(); u_adm uuid := gen_random_uuid(); r jsonb; r2 jsonb; kp text; kp2 text; kn text; kl text; v1 bigint; v2 bigint; v3 bigint;
  sum0 text; n int; lockedn int; log text; npass int; nfail int; txt text; a jsonb;
begin
  select md5(string_agg(id::text || ':' || coalesce(price::text, '') || ':' || coalesce(price_text, '') || ':' || coalesce(vat_rate::text, ''), '|' order by id)) into sum0 from kb.products;
  select count(*) into lockedn from booking.site_texts where class = 'locked';
  insert into auth.users(id, email) values (u_bot, 't63-bot@example.test'), (u_otto, 't63-otto@example.test'), (u_adm, 't63-admin@example.test');
  insert into booking.text_bots(user_id, label) values (u_bot, 't63 botti');
  insert into booking.staff(user_id, email, name, role) values (u_otto, 't63-otto@example.test', 'T63 Otto', 'manager'), (u_adm, 't63-admin@example.test', 'T63 Joonas', 'admin');
  select key into kp from booking.site_texts where source_table = 'kb.policies' and lang = 'fi' and published_text <> '' and source_column = 'body' order by key limit 1;
  select key into kp2 from booking.site_texts where source_table = 'kb.policies' and lang = 'fi' and published_text <> '' and source_column = 'body' and key <> kp order by key limit 1;
  select key into kn from booking.site_texts where key like 'product.%.description' and lang = 'fi' and class = 'normal' and published_text <> '' order by key limit 1;
  select key into kl from booking.site_texts where key like 'product.%.price_text' and published_text <> '' limit 1;
  -- A: oikeudet
  perform public.t63_ck((select array_agg(permission order by permission) from booking.role_permissions where role_code = 'text_editor') = array['texts.propose'], 'A1: text_editor ennallaan: vain texts.propose');
  perform public.t63_ck((select array_agg(permission order by permission) from booking.role_permissions where role_code = 'manager' and permission like 'texts.%') = array['texts.approve', 'texts.approve_protected', 'texts.propose'], 'A2: manager (Otto): propose + approve + approve_protected, EI manage');
  perform public.t63_ck((select array_agg(permission order by permission) from booking.role_permissions where role_code = 'admin' and permission like 'texts.%') = array['texts.approve', 'texts.approve_protected', 'texts.manage', 'texts.propose'], 'A3: admin (Joonas): kaikki neljä');
  -- B: Otto hyväksyy suojatun (ehdot) botin ehdotuksen
  perform public.t63_login(u_bot);
  r := public.t63_call(format($q$booking.texts_propose(%L, 'fi', %L, 'selkeämpi sanamuoto')$q$, kp, (select published_text from booking.site_texts where key = kp and lang = 'fi') || ' Lisätty selventävä lause.'));
  perform public.t63_logout();
  v1 := (r ->> 'version_id')::bigint;
  perform public.t63_ck((r ->> 'ok')::boolean and (r ->> 'protected')::boolean, 'B1: botti ehdottaa ehtotekstin muutoksen (protected)');
  perform public.t63_login(u_otto);
  r2 := public.t63_call(format('booking.admin_texts_approve(%s, ''ok Otto'')', v1));
  perform public.t63_logout();
  perform public.t63_ck((r2 ->> 'ok')::boolean and (r2 ->> 'status') = 'published', 'B2: Otto hyväksyy ja julkaisee suojatun ehtotekstin: ' || r2::text);
  perform public.t63_ck((select approved_by = u_otto and published_by = u_otto and author = u_bot and author_kind = 'bot' from booking.site_text_versions where id = v1), 'B3: versiolla ehdottaja = botti, hyväksyjä = Otto, julkaisija = Otto');
  perform public.t63_ck((select (new_data ->> 'approved_by')::uuid = u_otto and (new_data ->> 'proposed_by')::uuid = u_bot and new_data ->> 'proposed_by_kind' = 'bot' and new_data ->> 'actor_label' like '%T63 Otto%'
        and new_data ->> 'new_text' like '%Lisätty selventävä lause.' and new_data ->> 'old_text' is not null and (new_data -> 'protected')::text = 'true' from booking.audit_log where action = 'TEXT_APPROVE' and actor = u_otto order by id desc limit 1),
        'B4: audit_log TEXT_APPROVE: hyväksyjä Otto, ehdottaja botti, vanha+uusi teksti');
  perform public.t63_ck((select (new_data ->> 'published_by')::uuid = u_otto and (new_data ->> 'approved_by')::uuid = u_otto and new_data ->> 'proposed_by_label' like 'botti: t63 botti' from booking.audit_log where action = 'TEXT_PUBLISH' and actor = u_otto order by id desc limit 1), 'B5: audit_log TEXT_PUBLISH: julkaisija, hyväksyjä, ehdottaja nimineen');
  -- C: Otto hyväksyy eskaloidun (numero) ehdotuksen kun ehdottaja on botti; Joonas peruu
  perform public.t63_login(u_bot);
  r := public.t63_call(format($q$booking.texts_propose(%L, 'fi', %L, 'lisätty luku')$q$, kn, (select published_text from booking.site_texts where key = kn and lang = 'fi') || ' Kesto 55 minuuttia.'));
  perform public.t63_logout();
  v2 := (r ->> 'version_id')::bigint;
  perform public.t63_ck((r ->> 'protected')::boolean and (r -> 'escalation') ? 'numbers', 'C1: numero eskaloi ehdotuksen protected-tilaan');
  perform public.t63_login(u_otto);
  perform public.t63_ck(public.t63_try(format('select booking.admin_texts_approve(%s)', v2)) = 'ok', 'C2: Otto hyväksyy eskaloidun (numerot) ehdotuksen');
  perform public.t63_logout();
  perform public.t63_login(u_adm);
  r2 := public.t63_call(format($q$booking.admin_texts_rollback(%L, 'fi', 1, 'palautus')$q$, kn));
  perform public.t63_logout();
  perform public.t63_ck((r2 ->> 'ok')::boolean and (select new_data ->> 'approved_by' = u_adm::text and (new_data ->> 'to_version')::int = 1 and new_data ->> 'old_text' like '%55 minuuttia%' from booking.audit_log where action = 'TEXT_ROLLBACK' and actor = u_adm order by id desc limit 1), 'C3: Joonas peruu: audit TEXT_ROLLBACK (hyväksyjä, vanha/uusi teksti)');
  -- D: hylkäys kirjataan
  perform public.t63_login(u_bot);
  r := public.t63_call(format($q$booking.texts_propose(%L, 'fi', %L, 'testi')$q$, kp2, (select published_text from booking.site_texts where key = kp2 and lang = 'fi') || ' Epäselvä lisäys.'));
  perform public.t63_logout();
  v3 := (r ->> 'version_id')::bigint;
  perform public.t63_login(u_otto);
  perform public.t63_ck(public.t63_try(format('select booking.admin_texts_reject(%s, ''ei tarpeen'')', v3)) = 'ok', 'D1: Otto hylkää suojatun ehdotuksen');
  perform public.t63_logout();
  perform public.t63_ck((select rejected_by = u_otto and rejected_at is not null and status = 'rejected' from booking.site_text_versions where id = v3)
        and (select new_data ->> 'rejected_by' = u_otto::text and new_data ->> 'proposed_by_kind' = 'bot' from booking.audit_log where action = 'TEXT_REJECT' order by id desc limit 1), 'D2: hylkääjä kirjattu versioon ja auditiin');
  -- E: botti ennallaan
  perform public.t63_login(u_bot);
  perform public.t63_ck(public.t63_try(format('select booking.admin_texts_approve(%s)', v1)) = 'forbidden' and public.t63_try(format('select booking.admin_texts_publish(%s)', v1)) = 'forbidden'
        and public.t63_try(format('select booking.admin_texts_reject(%s)', v1)) = 'forbidden' and public.t63_try($q$select booking.admin_texts_rollback('x', 'fi', 1)$q$) = 'forbidden', 'E1: botti ei hyväksy, julkaise, hylkää eikä peru');
  perform public.t63_ck(public.t63_try($q$select booking.admin_texts_audit()$q$) = 'forbidden' and public.t63_try($q$select booking.admin_texts_queue()$q$) = 'forbidden' and public.t63_try($q$select booking.admin_texts_mark_reviewed('x', 'fi')$q$) = 'forbidden'
        and public.t63_try($q$select booking.admin_texts_import('[]'::jsonb)$q$) = 'forbidden' and public.t63_try($q$select booking.admin_texts_sync()$q$) = 'forbidden', 'E2: botti ei näe auditia/jonoa eikä hallinta-RPC:itä');
  perform public.t63_ck((select count(*) from booking.customers) = 0 and (select count(*) from booking.orders) = 0 and (select count(*) from booking.payments) = 0, 'E3: botti ei näe asiakkaita, tilauksia, maksuja');
  r := public.t63_call(format($q$booking.texts_propose(%L, 'fi', 'Uusi hinta 1 €')$q$, kl));
  perform public.t63_ck(r ->> 'err' = 'text_locked', 'E4: botti ei ehdota lukittua hintatekstiä');
  perform public.t63_logout();
  -- F: lukitut ennallaan
  perform public.t63_login(u_otto);
  perform public.t63_ck(public.t63_call(format($q$booking.texts_propose(%L, 'fi', 'Uusi hinta 1 €')$q$, kl)) ->> 'err' = 'text_locked', 'F1: Otto ei ehdota lukittua hintatekstiä');
  perform public.t63_ck(public.t63_try(format($q$select booking.admin_texts_set_class(%L, 'fi', 'normal')$q$, kl)) = 'forbidden' and public.t63_try('select booking.admin_texts_sync()') = 'forbidden', 'F2: Otto ei muuta luokkia eikä synkkaa (texts.manage vain adminilla)');
  perform public.t63_logout();
  perform public.t63_login(u_adm);
  perform public.t63_ck(public.t63_call(format($q$booking.texts_propose(%L, 'fi', 'Uusi hinta 1 €')$q$, kl)) ->> 'err' = 'text_locked', 'F3: Joonaskaan ei ehdota lukittua hintatekstiä tekstinä');
  perform public.t63_logout();
  perform public.t63_ck((select count(*) from booking.site_texts where class = 'locked') = lockedn and (select md5(string_agg(id::text || ':' || coalesce(price::text, '') || ':' || coalesce(price_text, '') || ':' || coalesce(vat_rate::text, ''), '|' order by id)) from kb.products) = sum0, 'F4: lukittuja rivejä yhtä monta; hinnat, hintatekstit ja ALV ennallaan');
  -- G: audit-RPC
  perform public.t63_login(u_otto);
  a := public.t63_call(format($q$booking.admin_texts_audit(%L, 'fi', 20)$q$, kp));
  perform public.t63_logout();
  perform public.t63_ck(jsonb_array_length(a -> 'items') >= 2 and (a -> 'items' -> 0 ->> 'approved_by') like '%T63 Otto%' and (a -> 'items' -> 0 ->> 'proposed_by') = 'botti: t63 botti' and (a -> 'items' -> 0 ->> 'published_by') like '%T63 Otto%', 'G1: admin_texts_audit näyttää ehdottajan, hyväksyjän ja julkaisijan nimineen: ' || coalesce((a -> 'items' -> 0)::text, a::text));
  perform public.t63_anon();
  perform public.t63_ck(public.t63_try($q$select booking.admin_texts_audit()$q$) like '42501%', 'G2: anon ei kutsu audit-RPC:tä');
  perform public.t63_logout();
  perform public.t63_ck(jsonb_array_length(booking.admin_texts_drift() -> 'drift') = 0, 'G3: ei driftiä lähdetauluihin');
  log := current_setting('t63.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
