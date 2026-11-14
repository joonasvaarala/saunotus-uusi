-- booking_315: bot-gatewayn uutiskirjeluonnokset (scope newsletter.draft). Ajetaan migraation jälkeen; kaikki perutaan (rollback).
-- Käyttö: psql -X -v ON_ERROR_STOP=1 -d <db> -f t315_newsletter_draft.sql   (tulostaa "ok N - ..." -rivit, virhe = epäonnistui)
\set QUIET on
begin;
create function pg_temp.err(p_key text, p_action text, p_args jsonb) returns text language plpgsql as $$
begin
  perform botgw.call(p_key, p_action, p_args);
  return 'no_error';
exception when others then
  return sqlstate || ':' || sqlerrm;
end $$;
create function pg_temp.ok(p_n int, p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'not ok % - %', p_n, p_msg; end if;
  raise notice 'ok % - %', p_n, p_msg;
end $$;

-- Testiasiakkaat: K = newsletter.draft, N = ilman scopea
insert into botgw.bot_clients (name, staff_id, key_hash, scopes, active)
select 't315-nl', s.id, repeat('a', 64), array['me','newsletter.draft'], true from public.staff s where s.active order by s.id limit 1;
insert into botgw.bot_clients (name, staff_id, key_hash, scopes, active)
select 't315-noscope', s.id, repeat('b', 64), array['me','backlog.read','backlog.write','proposals.write'], true from public.staff s where s.active order by s.id limit 1;


do $t$
declare K text := repeat('a',64); N text := repeat('b',64);
  r jsonb; d jsonb; id1 bigint; e text; nid bigint; a text; rq uuid := gen_random_uuid();
  base jsonb := '{"subject_fi":"Joulun saunavuorot","subject_en":"Christmas sauna slots","body_fi":"Hei! Joulun vuorot on nyt avattu.","body_en":"Hi! Christmas slots are now open.","style":{"layout":"letter"},"segment":"all"}';
begin
  -- 1. Luonti
  r := botgw.call(K, 'newsletter_save', base || jsonb_build_object('language','fi'));
  d := r->'data'; id1 := (d->>'id')::bigint;
  perform pg_temp.ok(1, r->>'ok' = 'true' and d->>'state' = 'draft' and (d->>'version')::int = 1 and (d->>'created')::boolean, 'save luo luonnoksen (draft, v1)');
  perform pg_temp.ok(2, (select suggested_send_at is null and state = 'draft' and language = 'fi' from booking.newsletters where id = id1), 'luonnos kannassa, ei ajastusta');
  -- 2. Lista
  r := botgw.call(K, 'newsletter_list', '{}');
  perform pg_temp.ok(3, jsonb_typeof(r->'data') = 'array' and exists (select 1 from jsonb_array_elements(r->'data') x where (x->>'id')::bigint = id1 and (x->>'editable')::boolean), 'list näyttää luonnoksen, editable');
  perform pg_temp.ok(4, not exists (select 1 from jsonb_array_elements(r->'data') x where x ? 'body_fi' or x ? 'preview_token' or x ? 'preview_signature'), 'list ei palauta runkoja eikä esikatselutunnisteita');
  r := botgw.call(K, 'newsletter_list', '{"state":"sent"}');
  perform pg_temp.ok(5, not exists (select 1 from jsonb_array_elements(r->'data') x where (x->>'id')::bigint = id1), 'list state-suodatin');
  perform pg_temp.ok(6, pg_temp.err(K, 'newsletter_list', '{"state":"queued"}') like '22023:bad_state%', 'list: tuntematon tila -> 22023');
  -- 3. Haku
  r := botgw.call(K, 'newsletter_get', jsonb_build_object('id', id1)); d := r->'data';
  perform pg_temp.ok(7, d->>'body_en' = 'Hi! Christmas slots are now open.' and d->'style'->>'layout' = 'letter' and (d->>'editable')::boolean, 'get palauttaa sisällön');
  perform pg_temp.ok(8, not (d ? 'preview_token' or d ? 'preview_signature' or d ? 'preview_at'), 'get ei palauta esikatselutunnisteita');
  perform pg_temp.ok(9, pg_temp.err(K, 'newsletter_get', '{"id":999999999}') like 'P0002:not_found%', 'get: puuttuva -> P0002');
  -- 4. Muokkaus (yhdistää olemassa olevaan)
  r := botgw.call(K, 'newsletter_save', jsonb_build_object('id', id1, 'version', 1, 'subject_fi', 'Joulun vuorot auki'));
  perform pg_temp.ok(10, (r->'data'->>'version')::int = 2 and not (r->'data'->>'created')::boolean, 'päivitys nostaa version');
  perform pg_temp.ok(11, (select subject_fi = 'Joulun vuorot auki' and body_fi = 'Hei! Joulun vuorot on nyt avattu.' and language = 'fi' from booking.newsletters where id = id1), 'päivitys säilyttää muut kentät');
  perform pg_temp.ok(12, pg_temp.err(K, 'newsletter_save', jsonb_build_object('id', id1, 'version', 1, 'subject_fi', 'x')) like '22023:version_conflict%', 'vanha versio -> 22023 version_conflict');
  perform pg_temp.ok(13, pg_temp.err(K, 'newsletter_save', jsonb_build_object('id', id1, 'subject_fi', 'x')) like '22023:%version%', 'id ilman versiota -> 22023');
  perform pg_temp.ok(14, pg_temp.err(K, 'newsletter_save', jsonb_build_object('id', id1, 'version', 2)) like '22023:%', 'ei tallennettavaa -> 22023');
  perform pg_temp.ok(15, pg_temp.err(K, 'newsletter_save', jsonb_build_object('id', id1, 'version', 2, 'suggested_send_at', '2026-12-01T10:00:00Z')) like '42501:field_not_editable%', 'ajastus (suggested_send_at) estetty');
  perform pg_temp.ok(16, pg_temp.err(K, 'newsletter_save', jsonb_build_object('id', id1, 'version', 2, 'state', 'sent')) like '42501:field_not_editable%', 'tilan asetus estetty');
  perform pg_temp.ok(17, pg_temp.err(K, 'newsletter_save', jsonb_build_object('id', id1, 'version', 2, 'segment', 'everyone')) like '22023:invalid_newsletter%', 'virheellinen segmentti -> 22023 invalid_newsletter');
  perform pg_temp.ok(18, pg_temp.err(K, 'newsletter_save', base - 'body_en') like '22023:invalid_newsletter%', 'puutteellinen uusi luonnos -> 22023');
  perform pg_temp.ok(19, pg_temp.err(K, 'newsletter_save', jsonb_build_object('id', 999999999, 'version', 1, 'subject_fi', 'x')) like 'P0002:not_found%', 'puuttuvan muokkaus -> P0002');
  -- 5. Ei-luonnosta ei voi muokata
  update booking.newsletters set state = 'previewed' where id = id1;
  perform pg_temp.ok(20, pg_temp.err(K, 'newsletter_save', jsonb_build_object('id', id1, 'version', 2, 'subject_fi', 'x')) like '42501:not_editable%', 'previewed -> 42501 not_editable');
  update booking.newsletters set state = 'sent' where id = id1;
  perform pg_temp.ok(21, pg_temp.err(K, 'newsletter_save', jsonb_build_object('id', id1, 'version', 2, 'subject_fi', 'x')) like '42501:not_editable%', 'sent -> 42501 not_editable');
  perform pg_temp.ok(22, (select subject_fi = 'Joulun vuorot auki' and version = 2 and state = 'sent' from booking.newsletters where id = id1), 'lähetetty ennallaan');
  r := botgw.call(K, 'newsletter_get', jsonb_build_object('id', id1));
  perform pg_temp.ok(23, not (r->'data'->>'editable')::boolean, 'get: sent ei editable');
  -- 6. Ilman scopea
  foreach a in array array['newsletter_list','newsletter_get','newsletter_save'] loop
    e := pg_temp.err(N, a, jsonb_build_object('id', id1, 'version', 2, 'subject_fi', 'x') - case when a = 'newsletter_list' then array['id','version','subject_fi'] else array[]::text[] end);
    perform pg_temp.ok(24, e = '42501:forbidden:newsletter.draft', a || ' ilman scopea -> 42501 forbidden (' || e || ')');
  end loop;
  -- 7. Lähetys-, ajastus-, esikatselu- ja lipputoiminnot eivät ole olemassa
  foreach a in array array['newsletter_dispatch','newsletter_send','newsletter_schedule','newsletter_test_send','newsletter_preview',
                           'newsletter_queue','newsletter_enable','newsletter_enabled','newsletter_flag','newsletter_delete',
                           'admin_newsletter_dispatch','admin_newsletter_enabled','admin_newsletter_save','svc_newsletter_save','_newsletter_save'] loop
    e := pg_temp.err(K, a, jsonb_build_object('id', id1));
    perform pg_temp.ok(25, e = '22023:unknown_action', a || ' -> unknown_action');
  end loop;
  -- 8. Lokitus + audit
  perform pg_temp.ok(26, (select count(*) from botgw.call_log l join botgw.bot_clients b on b.id = l.client_id
                           where b.name = 't315-nl' and l.action = 'newsletter_save' and l.ok and l.target_type = 'newsletter' and l.target_id = id1::text and l.request_id is not null) = 2, 'call_log: 2 onnistunutta tallennusta, request_id + kohde');
  perform pg_temp.ok(27, (select count(*) from public.audit_log where action = 'newsletter_save' and entity_type = 'newsletter' and entity_id = id1::text and actor_name = 'bot:t315-nl') = 2, 'audit_log kirjattu');
  -- 9. Idempotenssi
  r := botgw.call(K, 'newsletter_save', base || jsonb_build_object('request_id', rq));
  nid := (r->'data'->>'id')::bigint;
  r := botgw.call(K, 'newsletter_save', base || jsonb_build_object('request_id', rq));
  perform pg_temp.ok(28, (r->>'duplicate')::boolean and (select count(*) from booking.newsletters where id >= nid) = 1, 'sama request_id -> duplicate, ei toista luonnosta');
end $t$;

-- 10. Rajoitus: newsletter_save lasketaan kirjoitukseksi (20/min), lukeminen ei kuulu kirjoitusrajaan
do $t$
declare K text := repeat('a',64); cid uuid; e text;
begin
  select id into cid from botgw.bot_clients where name = 't315-nl';
  delete from botgw.call_log where client_id = cid;
  insert into botgw.call_log (client_id, action, ok) select cid, 'newsletter_save', true from generate_series(1, 20);
  e := pg_temp.err(K, 'newsletter_save', '{"subject_fi":"a","subject_en":"a","body_fi":"a","body_en":"a","style":{"layout":"letter"},"segment":"all"}');
  perform pg_temp.ok(29, e like 'BG429:rate_limited%', '20 tallennusta/min -> 21. BG429 (' || e || ')');
  perform pg_temp.ok(30, pg_temp.err(K, 'newsletter_list', '{}') = 'no_error', 'luku toimii kirjoitusrajan täyttyessä');
  delete from botgw.call_log where client_id = cid;
  insert into botgw.call_log (client_id, action, ok, at) select cid, 'newsletter_save', true, now() - interval '2 hours' from generate_series(1, 300);
  e := pg_temp.err(K, 'newsletter_save', '{"subject_fi":"a","subject_en":"a","body_fi":"a","body_en":"a","style":{"layout":"letter"},"segment":"all"}');
  perform pg_temp.ok(31, e like 'BG429:rate_limited%', '300 tallennusta/vrk -> BG429');
  delete from botgw.call_log where client_id = cid;
  insert into botgw.call_log (client_id, action, ok) select cid, 'backlog_add', true from generate_series(1, 20);
  e := pg_temp.err(K, 'newsletter_save', '{"subject_fi":"a","subject_en":"a","body_fi":"a","body_en":"a","style":{"layout":"letter"},"segment":"all"}');
  perform pg_temp.ok(32, e like 'BG429:rate_limited%', 'yhteinen kirjoitusraja muiden kirjoitusten kanssa');
end $t$;

rollback;
\echo 't315 KAIKKI OK'
