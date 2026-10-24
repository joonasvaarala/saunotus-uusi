-- t141: viestin toimitustapa (booking_141, paketti 09). Rollback-transaktio: lopuksi tahallinen poikkeus.
-- Sarake + rajoitteet, tallennus (scheduled / order_only), ajastuksen tyhjennys, vanhat kutsut,
-- ajastettu lähetys ohittaa order_only-ohjeet, jonossa olevat rivit ohitetaan, tilaussivun/vahvistuksen kentät.
-- Ei lähetä mitään: ei edge-funktioita, rivit jäävät rollbackissa pois. Testiasiakkaat ovat feikkejä (@example.test).
-- Ei CI:ssä (Pages-työnkulussa ei ole Postgresia). Bottiavustus ajaa tämän psql:llä migraatioiden jälkeen. Ei tuotantoon.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t141.log', '', true);
create function public.t141_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t141.log', coalesce(current_setting('t141.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t141_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 160) end;
end $$;
create function public.t141_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t141_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_mgr uuid := gen_random_uuid();
  res jsonb;
  rows jsonb;
  pid bigint;
  m_sched bigint;
  m_only bigint;
  m_fb bigint;
  m_flip bigint;
  c_id bigint;
  o_id bigint;
  tok uuid;
  e_pending bigint;
  e_failed bigint;
  e_sent bigint;
  log text;
  npass int;
  nfail int;
begin
  -- Rakenne ja oikeudet
  perform public.t141_ck((select column_default from information_schema.columns where table_schema = 'booking' and table_name = 'messages' and column_name = 'delivery_mode') = '''scheduled''::text', 'C1 oletus scheduled');
  perform public.t141_ck((select is_nullable from information_schema.columns where table_schema = 'booking' and table_name = 'messages' and column_name = 'delivery_mode') = 'NO', 'C2 not null');
  perform public.t141_ck(not exists (select 1 from booking.messages where delivery_mode <> 'scheduled'), 'C3 vanhat rivit scheduled');
  perform public.t141_ck((select count(*) from pg_constraint where conrelid = 'booking.messages'::regclass and conname in ('messages_delivery_mode_check', 'messages_order_only_instruction', 'messages_order_only_no_timing')) = 3, 'C4 rajoitteet');
  perform public.t141_ck(not has_function_privilege('anon', 'booking.admin_save_message(bigint, jsonb)', 'execute'), 'G1 anon ei tallenna');
  perform public.t141_ck(has_function_privilege('authenticated', 'booking.admin_save_message(bigint, jsonb)', 'execute'), 'G2 authenticated tallentaa');
  perform public.t141_ck(not has_function_privilege('authenticated', 'booking.messages_dispatch(integer)', 'execute'), 'G3 authenticated ei aja ajastusta');
  perform public.t141_ck(not has_function_privilege('authenticated', 'booking._order_message_rows(bigint, text, boolean)', 'execute'), 'G4 ohjerivit eivät ole julkisia');
  perform public.t141_ck(not has_function_privilege('authenticated', 'booking._product_message_mail(bigint)', 'execute'), 'G5 viestipohja ei ole julkinen');
  perform public.t141_ck(booking._setting('messages.timed_enabled', 'false'::jsonb) = 'false'::jsonb, 'S1 ajastus yhä oletuksena pois');

  insert into auth.users(id, email) values (u_mgr, 't141-mgr@example.test');
  insert into booking.staff(user_id, email, name, role) values (u_mgr, 't141-mgr@example.test', 't141 manager', 'manager');

  perform public.t141_login(u_mgr);
  res := booking.admin_product_create(jsonb_build_object('name', 'T141 viestituote', 'price', 1, 'vat_rate', 25.5, 'active', false));
  pid := (res ->> 'id')::bigint;

  -- Virheet
  perform public.t141_ck(public.t141_try($q$select booking.admin_save_message(null, '{"name":"T141","category":"instruction","delivery_mode":"sms"}'::jsonb)$q$) = 'invalid_delivery_mode', 'E1 tuntematon tapa');
  perform public.t141_ck(public.t141_try($q$select booking.admin_save_message(null, '{"name":"T141","category":"feedback","delivery_mode":"order_only"}'::jsonb)$q$) = 'invalid_delivery_mode', 'E2 order_only vain ohjeelle');
  perform public.t141_ck(public.t141_try($q$select booking.admin_save_message(null, '{"name":"T141","category":"after_marketing","delivery_mode":"order_only"}'::jsonb)$q$) = 'invalid_delivery_mode', 'E3 jälkimarkkinointi ei order_only');
  perform public.t141_ck(public.t141_try($q$select booking.admin_save_message(null, '{"name":"T141","category":"instruction","slug":"x"}'::jsonb)$q$) = 'unknown_field', 'E4 tuntematon kenttä yhä estetty');

  -- Ajastettu ohje: ennallaan
  res := booking.admin_save_message(null, jsonb_build_object(
    'name', 'T141 ajastettu', 'category', 'instruction', 'active', true,
    'subject_fi', 'Ennen käyntiä', 'short_fi', 'Lyhyt {asiakas_nimi}', 'body_fi', 'Täysi {tuote}',
    'send_amount', 1, 'send_unit', 'minutes', 'send_direction', 'after', 'send_anchor', 'booking',
    'product_ids', jsonb_build_array(pid)));
  m_sched := (res ->> 'id')::bigint;
  perform public.t141_ck(res -> 'message' ->> 'delivery_mode' = 'scheduled' and (res -> 'message' ->> 'send_amount')::int = 1, 'P1 vanha kutsu = scheduled, ajastus säilyy');

  -- Tilauksen yhteydessä: ajastus tyhjennetään
  res := booking.admin_save_message(null, jsonb_build_object(
    'name', 'T141 tilaus', 'category', 'instruction', 'active', true, 'delivery_mode', 'order_only',
    'subject_fi', 'Saunaohje', 'subject_en', 'Sauna guide',
    'short_fi', '<p>Ota pyyhe, {asiakas_nimi}</p>', 'short_en', 'Bring a towel', 'body_fi', '<h2>Tarkemmat ohjeet</h2><p>{tuote}</p>',
    'send_amount', 3, 'send_unit', 'days', 'send_direction', 'after', 'send_anchor', 'booking',
    'product_ids', jsonb_build_array(pid)));
  m_only := (res ->> 'id')::bigint;
  perform public.t141_ck(res -> 'message' ->> 'delivery_mode' = 'order_only', 'P2 order_only tallentuu');
  perform public.t141_ck(res -> 'message' -> 'send_amount' = 'null'::jsonb and res -> 'message' -> 'send_unit' = 'null'::jsonb
    and res -> 'message' -> 'send_direction' = 'null'::jsonb and res -> 'message' -> 'send_anchor' = 'null'::jsonb, 'P3 ajastus tyhjennetty');
  res := booking.admin_save_message(m_only, jsonb_build_object(
    'name', 'T141 tilaus', 'category', 'instruction', 'active', true,
    'subject_fi', 'Saunaohje', 'subject_en', 'Sauna guide',
    'short_fi', '<p>Ota pyyhe, {asiakas_nimi}</p>', 'short_en', 'Bring a towel', 'body_fi', '<h2>Tarkemmat ohjeet</h2><p>{tuote}</p>',
    'send_amount', 2, 'send_unit', 'days', 'send_direction', 'before', 'send_anchor', 'arrival',
    'product_ids', jsonb_build_array(pid)));
  perform public.t141_ck(res -> 'message' ->> 'delivery_mode' = 'order_only' and (res -> 'message' ->> 'send_amount') is null, 'P4 vanha hallinta ei vaihda tapaa, ajastus pysyy tyhjänä');

  res := booking.admin_save_message(null, jsonb_build_object(
    'name', 'T141 palaute', 'category', 'feedback', 'active', true,
    'subject_fi', 'Palaute', 'body_fi', 'Kerro',
    'send_amount', 1, 'send_unit', 'minutes', 'send_direction', 'after', 'send_anchor', 'booking',
    'product_ids', jsonb_build_array(pid)));
  m_fb := (res ->> 'id')::bigint;
  perform public.t141_ck(public.t141_try(format($q$select booking.admin_save_message(%s, '{"name":"T141 palaute","category":"feedback","delivery_mode":"order_only"}'::jsonb)$q$, m_fb)) = 'invalid_delivery_mode', 'E5 palautetta ei vaihdeta order_onlyksi');

  res := booking.admin_list_messages();
  perform public.t141_ck(exists (select 1 from jsonb_array_elements(res -> 'messages') x where (x ->> 'id')::bigint = m_only and x ->> 'delivery_mode' = 'order_only'), 'L1 lista: order_only');
  perform public.t141_ck(exists (select 1 from jsonb_array_elements(res -> 'messages') x where (x ->> 'id')::bigint = m_sched and x ->> 'delivery_mode' = 'scheduled'), 'L2 lista: scheduled');
  perform public.t141_logout();

  -- Tietokannan rajoitteet suoraan (ohi tallennusfunktion)
  perform public.t141_ck(public.t141_try(format($q$update booking.messages set send_amount = 1, send_unit = 'days', send_direction = 'after', send_anchor = 'booking' where id = %s$q$, m_only)) like '23514:%', 'K1 order_only ei saa ajastusta');
  perform public.t141_ck(public.t141_try(format($q$update booking.messages set delivery_mode = 'order_only', send_amount = null, send_unit = null, send_direction = null, send_anchor = null where id = %s$q$, m_fb)) like '23514:%', 'K2 palaute ei order_only');
  perform public.t141_ck(public.t141_try(format($q$update booking.messages set delivery_mode = 'email' where id = %s$q$, m_sched)) like '23514:%', 'K3 tuntematon arvo');

  -- Tilaus (feikkiasiakas) ja ohjeet
  insert into booking.customers(name, email) values ('T141 Aada', 't141-aada@example.test') returning id into c_id;
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, created_at)
  values (c_id, 'completed', 'paid', 10, 'admin', 'fi', now() - interval '5 minutes') returning id, public_token into o_id, tok;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_id, pid, 'T141 viestituote', 'product', 1, 10, 10, 25.5);

  rows := booking._order_full_instructions(o_id, 'fi');
  perform public.t141_ck(jsonb_array_length(rows) = 2, 'I1 molemmat ohjeet tilaussivulla');
  perform public.t141_ck(exists (select 1 from jsonb_array_elements(rows) x where (x ->> 'id')::bigint = m_only
    and x ->> 'short_text' = '<p>Ota pyyhe, T141 Aada</p>' and x ->> 'short_rich' = 'true'
    and x ->> 'body' like '%T141 viestituote%' and x ->> 'rich' = 'true' and x ->> 'delivery_mode' = 'order_only' and x ->> 'text' is null), 'I2 lyhyt + täysi + tapa');
  perform public.t141_ck(exists (select 1 from jsonb_array_elements(rows) x where (x ->> 'id')::bigint = m_sched
    and x ->> 'short_text' = 'Lyhyt T141 Aada' and x ->> 'short_rich' = 'false' and x ->> 'delivery_mode' = 'scheduled'), 'I3 ajastetun ohjeen lyhyt teksti');
  rows := booking._order_short_instructions(o_id, 'en');
  perform public.t141_ck(exists (select 1 from jsonb_array_elements(rows) x where (x ->> 'id')::bigint = m_only
    and x ->> 'text' = 'Bring a towel' and x ->> 'short_text' = 'Bring a towel' and x ->> 'rich' = 'false' and x ->> 'body' is null), 'I4 vahvistuksen lyhyt ohje ennallaan (text/rich)');
  res := booking.public_get_order(tok);
  perform public.t141_ck(exists (select 1 from jsonb_array_elements(res -> 'instructions') x where (x ->> 'id')::bigint = m_only and x ->> 'short_text' = '<p>Ota pyyhe, T141 Aada</p>'), 'I5 tilaussivun RPC palauttaa lyhyen ohjeen');

  -- Ajastettu lähetys: kytkin pois → ei mitään
  perform public.t141_ck(booking.messages_dispatch() = 0, 'J1 kytkin pois');
  perform public.t141_ck(not exists (select 1 from booking.email_outbox e where e.order_id = o_id and e.kind = 'product_message'), 'J2 ei rivejä');

  insert into booking.settings(key, value, is_public) values ('messages.timed_enabled', 'true'::jsonb, false)
  on conflict (key) do update set value = excluded.value;
  perform booking.messages_dispatch();
  perform public.t141_ck(exists (select 1 from booking.email_outbox e where e.dedupe_key = 'product_message:' || m_sched::text || ':' || o_id::text), 'J3 ajastettu ohje jonoutuu');
  perform public.t141_ck(not exists (select 1 from booking.email_outbox e where e.dedupe_key = 'product_message:' || m_only::text || ':' || o_id::text), 'J4 order_only ei jonoudu');
  perform public.t141_ck(exists (select 1 from booking.email_outbox e where e.dedupe_key = 'product_message:' || m_fb::text || ':' || o_id::text), 'J5 palautepyyntö ennallaan');

  -- Ennen vaihtoa jonoon jääneet rivit: viimeinen suodatin ja jonon ohitus
  m_flip := m_sched;
  update booking.email_outbox set status = 'pending', last_error = null
   where dedupe_key = 'product_message:' || m_flip::text || ':' || o_id::text returning id into e_pending;
  insert into booking.email_outbox(kind, order_id, locale, dedupe_key, status, payload, last_error)
  values ('product_message', o_id, 'fi', 't141-failed-' || m_flip::text, 'failed', jsonb_build_object('message_id', m_flip), 'temp')
  returning id into e_failed;
  insert into booking.email_outbox(kind, order_id, locale, dedupe_key, status, payload, last_error)
  values ('product_message', o_id, 'fi', 't141-sent-' || m_flip::text, 'sent', jsonb_build_object('message_id', m_flip), null)
  returning id into e_sent;
  perform public.t141_ck((booking._product_message_mail(e_pending) ->> 'active') = 'true', 'M1 ajastettu pohja aktiivinen');

  perform public.t141_login(u_mgr);
  res := booking.admin_save_message(m_flip, jsonb_build_object(
    'name', 'T141 ajastettu', 'category', 'instruction', 'active', true, 'delivery_mode', 'order_only',
    'subject_fi', 'Ennen käyntiä', 'short_fi', 'Lyhyt {asiakas_nimi}', 'body_fi', 'Täysi {tuote}',
    'send_amount', 1, 'send_unit', 'minutes', 'send_direction', 'after', 'send_anchor', 'booking',
    'product_ids', jsonb_build_array(pid)));
  perform public.t141_logout();
  perform public.t141_ck((select status = 'skipped' and last_error = 'order_only' from booking.email_outbox where id = e_pending), 'Q1 pending → skipped');
  perform public.t141_ck((select status = 'skipped' and last_error = 'order_only' from booking.email_outbox where id = e_failed), 'Q2 failed → skipped');
  perform public.t141_ck((select status = 'sent' from booking.email_outbox where id = e_sent), 'Q3 lähetettyä ei muuteta');
  perform public.t141_ck((booking._product_message_mail(e_pending) ->> 'active') = 'false'
    and (booking._product_message_mail(e_pending) ->> 'delivery_mode') = 'order_only'
    and booking._product_message_mail(e_pending) ->> 'text' is null, 'M2 order_only-pohja ei ole lähetettävä');

  -- Takaisin ajastetuksi: lähtee taas tavalliseen tapaan (uudet tilaukset)
  perform public.t141_login(u_mgr);
  res := booking.admin_save_message(m_flip, jsonb_build_object(
    'name', 'T141 ajastettu', 'category', 'instruction', 'active', true, 'delivery_mode', 'scheduled',
    'subject_fi', 'Ennen käyntiä', 'short_fi', 'Lyhyt {asiakas_nimi}', 'body_fi', 'Täysi {tuote}',
    'send_amount', 1, 'send_unit', 'minutes', 'send_direction', 'after', 'send_anchor', 'booking',
    'product_ids', jsonb_build_array(pid)));
  perform public.t141_logout();
  perform public.t141_ck(res -> 'message' ->> 'delivery_mode' = 'scheduled' and (res -> 'message' ->> 'send_amount')::int = 1, 'P5 takaisin ajastetuksi');
  perform public.t141_ck((select status from booking.email_outbox where id = e_pending) = 'skipped', 'Q4 ohitettu rivi ei palaa jonoon');

  log := current_setting('t141.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
