-- t60: tekstijärjestelmä (booking_60). Rollback-transaktio, tahallinen poikkeus lopussa. Ei botti-/oikeita tunnuksia: testikäyttäjät luodaan transaktion sisällä ja ne kumoutuvat.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t60.log', '', true);
create function public.t60_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t60.log', coalesce(current_setting('t60.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
-- yrittää SQL:n; palauttaa 'ok' tai BK001-detail / sqlstate:viesti
create function public.t60_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 80) end;
end $$;
create function public.t60_call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text; s text;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return jsonb_build_object('err', case when s = 'BK001' then d else s || ':' || left(m, 80) end);
end $$;
create function public.t60_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t60_anon() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon'; end $$;
create function public.t60_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_bot uuid := gen_random_uuid(); u_otto uuid := gen_random_uuid(); u_adm uuid := gen_random_uuid();
  k1 text; k2 text; k3 text; k4 text; kp text; kl text; ks text; pid1 text; pidb text; r jsonb; n int; n2 int; v1 bigint; v2 bigint; v3 bigint; v4 bigint; vp bigint;
  src text; t text; sum0 numeric; cnt0 int; sum1 numeric; cnt1 int; txt text; log text; npass int; nfail int; vc int; fid bigint;
begin
  select sum(price), count(*) into sum0, cnt0 from kb.products;
  -- testikäyttäjät
  insert into auth.users(id, email) values (u_bot, 't60-bot@example.test'), (u_otto, 't60-otto@example.test'), (u_adm, 't60-admin@example.test');
  insert into booking.text_bots(user_id, label) values (u_bot, 't60 bot');
  insert into booking.staff(user_id, email, name, role) values (u_otto, 't60-otto@example.test', 't60 otto', 'manager'), (u_adm, 't60-admin@example.test', 't60 admin', 'admin');

  -- ===== A: rakenne, rooli, seed =====
  perform public.t60_ck((select array_agg(permission order by permission) from booking.role_permissions where role_code = 'text_editor') = array['texts.propose'], 'A1: text_editor: vain texts.propose');
  perform public.t60_ck((select array_agg(permission order by permission) from booking.role_permissions where role_code = 'manager' and permission like 'texts.%') = array['texts.approve', 'texts.propose'], 'A2: manager (Otto): propose + approve, ei approve_protected/manage');
  perform public.t60_ck((select array_agg(permission order by permission) from booking.role_permissions where role_code = 'admin' and permission like 'texts.%') = array['texts.approve', 'texts.approve_protected', 'texts.manage', 'texts.propose'], 'A3: admin: kaikki neljä');
  perform public.t60_ck((select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'booking' and c.relname in ('site_texts', 'site_text_versions') and c.relrowsecurity) = 2, 'A4: RLS päällä molemmissa tauluissa');
  select count(*) into n from booking.site_texts;
  perform public.t60_ck(n >= 300, 'A5: seed: rivejä ' || n);
  perform public.t60_ck((select count(*) from booking.site_texts where published_version = 1) = (select count(*) from booking.site_text_versions where version = 1 and status = 'published' and author_kind = 'system'), 'A6: jokaisella seedatulla tekstillä versio 1 (published)');
  perform public.t60_ck(jsonb_array_length(booking.admin_texts_drift() -> 'drift') = 0, 'A7: ei driftiä: julkaistu teksti = lähdesarake (kaikki sidotut rivit) ' || jsonb_array_length(booking.admin_texts_drift() -> 'drift'));
  perform public.t60_ck(not exists (select 1 from booking.site_texts t where t.key like 'product.%' and t.source_pk::bigint in (select id from kb.products where not active)), 'A8: epäaktiivisten tuotteiden tekstejä ei rekisteröity');
  perform public.t60_ck(not exists (select 1 from booking.site_texts t where t.source_table = 'kb.policies' and t.source_pk::bigint in (select id from kb.policies where status <> 'active' or internal)), 'A9: sisäisiä/epäaktiivisia ehtoja ei rekisteröity');
  perform public.t60_ck((select count(*) from booking.site_texts where class = 'locked' and key ~ '\.(price_text|slug|booking_url)$') > 0 and not exists (select 1 from booking.site_texts where class <> 'locked' and key ~ '\.(price_text|slug|booking_url)$'), 'A10: price_text/slug/booking_url ovat locked');
  perform public.t60_ck(not exists (select 1 from booking.site_texts where source_table = 'kb.policies' and class <> 'protected'), 'A11: kaikki ehdot/käytännöt protected');
  perform public.t60_ck(not exists (select 1 from booking.site_texts where source_table in ('kb.locations', 'kb.opening_hours', 'kb.event_dates', 'kb.businesses') and class <> 'protected' and class <> 'locked'), 'A12: sijainnit/aukioloajat/tapahtumat/yritys protected');
  -- eskalointi (yksikkötesti)
  perform public.t60_ck(booking._text_escalation('Hinta 49 €', 'Hinta 50 €') = array['numbers'], 'E1: hinnan numero muuttuu -> numbers');
  perform public.t60_ck(booking._text_escalation('Hinta 49 €', 'Hinta 49 e') = array['currency'], 'E2: €-merkki poistuu -> currency');
  perform public.t60_ck(booking._text_escalation('Avoinna klo 16:00', 'Avoinna klo 17:00') = array['numbers', 'time'], 'E3: kellonaika -> numbers+time');
  perform public.t60_ck('phone' = any (booking._text_escalation('Soita 010 299 2866', 'Soita 010 299 2867')), 'E4: puhelin');
  perform public.t60_ck('email' = any (booking._text_escalation('Kirjoita a@b.fi', 'Kirjoita c@d.fi')), 'E5: sähköposti');
  perform public.t60_ck('link' = any (booking._text_escalation('Katso sivu', 'Katso www.esimerkki.fi')), 'E6: linkki');
  perform public.t60_ck('percent' = any (booking._text_escalation('Alennus', 'Alennus 10 %')), 'E7: prosentti');
  perform public.t60_ck(booking._text_escalation('Lämmin sauna', 'Erittäin lämmin ja rauhallinen sauna') = '{}', 'E8: pelkkä sanamuutos ei eskaloidu');

  -- valitaan testitekstit
  select key, split_part(key, '.', 2) into k1, pid1 from booking.site_texts where key like 'product.%.description' and lang = 'fi' and class = 'normal' and published_text <> '' order by key limit 1;
  select key into k2 from booking.site_texts where key like 'product.%.description' and lang = 'fi' and class = 'normal' and published_text <> '' and key <> k1 order by key limit 1;
  select key into k3 from booking.site_texts where key like 'product.%.name' and lang = 'fi' and class = 'normal' and published_text <> '' and key not in (k1, k2) order by key limit 1;
  select key into k4 from booking.site_texts where key like 'addon.%.name' and lang = 'fi' and class = 'normal' and published_text <> '' limit 1;
  select key into kp from booking.site_texts where source_table = 'kb.policies' and lang = 'fi' and published_text <> '' and source_column = 'body' order by key limit 1;
  select key into kl from booking.site_texts where key like 'product.%.price_text' and published_text <> '' limit 1;
  select key into ks from booking.site_texts where key like 'product.%.slug' limit 1;
  perform public.t60_ck(k1 is not null and k2 is not null and k3 is not null and kp is not null and kl is not null and ks is not null, 'A13: testitekstit löytyivät (' || coalesce(k1, '-') || ', ' || coalesce(kp, '-') || ')');

  -- julkinen luku (anon)
  perform public.t60_anon();
  r := public.t60_call($q$booking.public_get_site_texts('fi')$q$);
  select coalesce((select count(*) from jsonb_array_elements(r -> 'texts')), 0) into n;
  perform public.t60_ck((r ->> 'ok')::boolean and n > 100, 'P1: anon: public_get_site_texts palauttaa tekstejä (' || n || ')');
  perform public.t60_ck(not exists (select 1 from jsonb_array_elements(r -> 'texts') e where e ->> 'text' = '' or (e ->> 'key') ~ '\.(price_text|slug|booking_url)$'), 'P2: anon: ei tyhjiä eikä lukittuja');
  perform public.t60_ck((select e ->> 'text' from jsonb_array_elements(r -> 'texts') e where e ->> 'key' = k1 and e ->> 'lang' = 'fi') = (select description from kb.products where id = pid1::bigint), 'P3: anon: teksti = tuotteen nykyinen kuvaus (sivut ennallaan)');
  perform public.t60_ck(public.t60_try('select count(*) from booking.site_texts') like '42501%', 'P4: anon ei lue site_texts-taulua suoraan');
  perform public.t60_ck(public.t60_try('select booking.texts_list()') like '42501%' or public.t60_try('select booking.texts_list()') = 'forbidden', 'P5: anon ei kutsu texts_list');
  perform public.t60_ck(public.t60_try(format('insert into booking.staff(user_id, email, name, role) values (%L, ''x'', ''x'', ''text_editor'')', u_bot)) ~ '^(23503|42501)', 'P6: text_editor ei kelpaa henkilöstöroolina (FK): ' || public.t60_try(format('insert into booking.staff(user_id, email, name, role) values (%L, ''x'', ''x'', ''text_editor'')', u_bot)));
  perform public.t60_logout();

  -- ===== B: botti (text_editor) =====
  perform public.t60_login(u_bot);
  r := public.t60_call('booking.texts_list(''product.'', ''fi'')');
  perform public.t60_ck((r ->> 'ok')::boolean and (r ->> 'total')::int > 0, 'B1: botti näkee tekstilistan');
  r := public.t60_call(format('booking.texts_propose(%L, ''fi'', %L, ''selkeämpi'')', k1, (select published_text from booking.site_texts where key = k1 and lang = 'fi') || ' Lisälause selkeyden vuoksi.'));
  perform public.t60_ck((r ->> 'ok')::boolean and r ->> 'status' = 'proposed' and not (r ->> 'protected')::boolean, 'B2: botti ehdottaa tavallisen tekstin -> proposed, ei suojattu (' || coalesce(r ->> 'err', 'ok') || ')');
  v1 := (r ->> 'version_id')::bigint;
  perform public.t60_ck((select published_text from booking.site_texts where key = k1 and lang = 'fi') = (select description from kb.products where id = pid1::bigint) and (select status from booking.site_texts where key = k1 and lang = 'fi') = 'proposed', 'B3: ehdotus ei muuta julkaistua tekstiä eikä lähdettä');
  perform public.t60_ck(public.t60_try(format('select booking.admin_texts_approve(%s)', v1)) = 'forbidden', 'B4: botti ei hyväksy');
  perform public.t60_ck(public.t60_try(format('select booking.admin_texts_publish(%s)', v1)) = 'forbidden', 'B5: botti ei julkaise');
  perform public.t60_ck(public.t60_try(format('select booking.admin_texts_reject(%s)', v1)) = 'forbidden', 'B6: botti ei hylkää');
  perform public.t60_ck(public.t60_try('select booking.admin_texts_queue()') = 'forbidden', 'B7: botti ei näe hyväksyntäjonoa');
  perform public.t60_ck(public.t60_try(format('select booking.admin_texts_set_class(%L, ''fi'', ''normal'')', kl)) = 'forbidden', 'B8: botti ei muuta luokkaa');
  perform public.t60_ck(public.t60_try('select booking.admin_texts_sync()') = 'forbidden', 'B9: botti ei aja synkkaa');
  perform public.t60_ck(public.t60_try(format('select booking.admin_texts_rollback(%L, ''fi'', 1)', k1)) = 'forbidden', 'B10: botti ei palauta versioita');
  perform public.t60_ck(public.t60_try(format('select booking.texts_propose(%L, ''fi'', ''Uusi hinta'')', kl)) = 'text_locked', 'B11: lukittu price_text: ehdotus estetty');
  perform public.t60_ck(public.t60_try(format('select booking.texts_propose(%L, ''all'', ''x'')', ks)) = 'text_locked', 'B12: lukittu slug: ehdotus estetty');
  -- booking_122: tuotekuvaus on kind rich (k2). Tavallinen kenttä (k3, tuotteen nimi) hylkää yhä HTML:n.
  -- Rich-kuvaus hylkää skriptin, onclickin ja javascript-linkin. Onnistunutta rich-ehdotusta ei tehdä tässä, ettei päiväraja (B38) kulu.
  perform public.t60_ck(public.t60_try(format('select booking.texts_propose(%L, ''fi'', %L)', k3, '<b>Lihavoitu</b> teksti')) = 'html_not_allowed', 'B13: raaka HTML estetty tavallisessa kentässä');
  perform public.t60_ck(public.t60_try(format('select booking.texts_propose(%L, ''fi'', %L)', k3, '<script>x</script>')) = 'html_not_allowed', 'B14: script estetty');
  perform public.t60_ck(public.t60_try(format('select booking.texts_propose(%L, ''fi'', %L)', k3, repeat('a', 5000))) = 'too_long', 'B15: liian pitkä estetty');
  perform public.t60_ck(public.t60_try(format('select booking.texts_propose(%L, ''fi'', %L)', k2, '<script>alert(1)</script>')) = 'html_not_allowed', 'B13b: script estetty rich-kuvauksessa');
  perform public.t60_ck(public.t60_try(format('select booking.texts_propose(%L, ''fi'', %L)', k2, '<p onclick="alert(1)">x</p>')) = 'html_not_allowed', 'B13c: onclick estetty rich-kuvauksessa');
  perform public.t60_ck(public.t60_try(format('select booking.texts_propose(%L, ''fi'', %L)', k2, '<p><a href="javascript:alert(1)">x</a></p>')) = 'html_not_allowed', 'B13d: javascript-linkki estetty rich-kuvauksessa');
  perform public.t60_ck(public.t60_try(format('select booking.texts_propose(%L, ''fi'', %L)', k2, '   ')) = 'text_empty', 'B16: tyhjä estetty');
  perform public.t60_ck(public.t60_try(format('select booking.texts_propose(%L, ''fi'', %L)', k2, 'Hinta {{price:7}}')) = 'placeholder_mismatch', 'B17: ei-sallittu paikkamerkki estetty');
  perform public.t60_ck(public.t60_try(format('select booking.texts_propose(%L, ''fi'', %L)', k2, 'Rikki {{price')) = 'placeholder_invalid', 'B18: rikkinäinen paikkamerkki estetty');
  perform public.t60_ck(public.t60_try(format('select booking.texts_propose(%L, ''fi'', %L)', k2, (select published_text from booking.site_texts where key = k2 and lang = 'fi'))) = 'no_change', 'B19: muuttumaton teksti estetty');
  perform public.t60_ck(public.t60_try(format('select booking.texts_propose(%L, ''fi'', %L)', 'ei.olemassa.avain', 'x')) = 'not_found', 'B20: tuntematon avain');
  perform public.t60_ck(public.t60_try(format('select booking.texts_propose(%L, ''de'', %L)', k2, 'x')) = 'not_found', 'B21: tuntematon kieli');
  -- eskalointi ehdotuksessa
  r := public.t60_call(format('booking.texts_propose(%L, ''fi'', %L)', k2, (select published_text from booking.site_texts where key = k2 and lang = 'fi') || ' Nyt vain 19 € ja klo 16:30.'));
  perform public.t60_ck((r ->> 'ok')::boolean and (r ->> 'protected')::boolean and r -> 'escalation' ? 'numbers' and r -> 'escalation' ? 'currency' and r -> 'escalation' ? 'time', 'B22: numero/€/kellonaika -> automaattisesti suojattu (' || coalesce(r ->> 'escalation', r ->> 'err') || ')');
  vp := (r ->> 'version_id')::bigint;
  r := public.t60_call(format('booking.texts_propose(%L, ''fi'', %L)', k3, (select published_text from booking.site_texts where key = k3 and lang = 'fi') || ' www.esimerkki.fi'));
  perform public.t60_ck((r ->> 'ok')::boolean and (r ->> 'protected')::boolean and r -> 'escalation' ? 'link', 'B23: linkki -> suojattu');
  r := public.t60_call(format('booking.texts_propose(%L, ''fi'', %L)', kp, (select published_text from booking.site_texts where key = kp and lang = 'fi') || ' Lisäys.'));
  perform public.t60_ck((r ->> 'ok')::boolean and (r ->> 'protected')::boolean and jsonb_array_length(r -> 'escalation') = 0, 'B24: ehdot (protected-avain) -> suojattu ilman numeromuutosta');
  -- luonnos -> lähetys, peruutus
  r := public.t60_call(format('booking.texts_propose(%L, ''fi'', %L, ''luonnos'', true)', k4, (select published_text from booking.site_texts where key = k4 and lang = 'fi') || ' (luonnos)'));
  perform public.t60_ck(r ->> 'status' = 'draft', 'B25: luonnos tilassa draft');
  v2 := (r ->> 'version_id')::bigint;
  r := public.t60_call(format('booking.texts_submit(%s)', v2));
  perform public.t60_ck(r ->> 'status' = 'proposed', 'B26: luonnos -> proposed');
  r := public.t60_call(format('booking.texts_withdraw(%s)', v2));
  perform public.t60_ck((r ->> 'ok')::boolean and (select status from booking.site_text_versions where id = v2) = 'rejected', 'B27: botti vetää oman ehdotuksensa pois');
  -- botti ei lue asiakas-/tilaus-/maksutietoja eikä muuta hintoja/asetuksia
  foreach t in array array['customers', 'orders', 'order_items', 'payments', 'reservations', 'gift_cards', 'receipts', 'refunds', 'email_outbox', 'order_requests', 'voucher_claims', 'staff', 'audit_log', 'settings'] loop
    r := public.t60_call(format('(select to_jsonb(count(*)) from booking.%I)', t));
    perform public.t60_ck(r = '0'::jsonb or (r ->> 'err') like '42501%', 'B28: botti ei näe rivejä taulussa booking.' || t || ' (' || r::text || ')');
  end loop;
  perform public.t60_ck(public.t60_try(format('select booking.admin_update_product(%s, ''{"price": 1}'')', pid1)) = 'forbidden', 'B29: botti ei muuta hintaa (admin_update_product)');
  perform public.t60_ck(public.t60_try(format('select booking.admin_update_product(%s, ''{"description": "x"}'')', pid1)) = 'forbidden', 'B30: botti ei muokkaa tuotetta suoraan');
  perform public.t60_ck(public.t60_try('select booking.admin_set_setting(''hold_minutes'', ''20'')') = 'forbidden', 'B31: botti ei muuta asetuksia');
  perform public.t60_ck(public.t60_try('select booking.admin_upsert_article(null, ''{"title_fi":"x"}''::jsonb)') = 'forbidden', 'B32: botti ei kirjoita artikkeleita');
  perform public.t60_ck(public.t60_try(format('update kb.products set price = 1 where id = %s', pid1)) like '42501%', 'B33: botti ei kirjoita kb.products-taulua suoraan');
  perform public.t60_ck(public.t60_try(format('update booking.site_texts set published_text = ''x'' where key = %L', k1)) like '42501%', 'B34: botti ei kirjoita site_texts-taulua suoraan');
  perform public.t60_ck(public.t60_try('insert into booking.site_text_versions(text_id, version, text, status) values (1, 999, ''x'', ''published'')') like '42501%', 'B35: botti ei kirjoita versiotauluun suoraan');
  perform public.t60_ck(public.t60_try('select booking.admin_my_permissions()') <> 'ok' or (public.t60_call('booking.admin_my_permissions()') ->> 'role') is null, 'B36: botti ei ole henkilöstöä (admin_my_permissions ei anna roolia)');
  perform public.t60_logout();
  perform public.t60_ck((select sum(price) from kb.products) = sum0 and (select count(*) from kb.products) = cnt0, 'B37: tuotteiden hinnat ennallaan botin toimien jälkeen');

  -- raja: botti ei hyväksy omaakaan, päivärajoitus
  update booking.settings set value = '2'::jsonb where key = 'texts_max_proposals_per_day';
  perform public.t60_login(u_bot);
  perform public.t60_ck(public.t60_try(format('select booking.texts_propose(%L, ''fi'', %L)', k2, (select published_text from booking.site_texts where key = k2 and lang = 'fi') || ' Taas.')) = 'rate_limited', 'B38: päivittäinen ehdotusraja pysäyttää botin');
  perform public.t60_logout();
  update booking.settings set value = '200'::jsonb where key = 'texts_max_proposals_per_day';

  -- ===== C: Otto (manager) ja Joonas (admin) =====
  perform public.t60_login(u_otto);
  r := public.t60_call('booking.admin_texts_queue()');
  perform public.t60_ck((r ->> 'ok')::boolean and jsonb_array_length(r -> 'items') >= 4, 'C1: Otto näkee jonon (' || coalesce(jsonb_array_length(r -> 'items')::text, r ->> 'err') || ')');
  perform public.t60_ck(exists (select 1 from jsonb_array_elements(r -> 'items') i where (i ->> 'version_id')::bigint = vp and not (i ->> 'can_approve')::boolean) and exists (select 1 from jsonb_array_elements(r -> 'items') i where (i ->> 'version_id')::bigint = v1 and (i ->> 'can_approve')::boolean), 'C2: jonossa can_approve: tavallinen true, suojattu false');
  perform public.t60_ck(public.t60_try(format('select booking.admin_texts_approve(%s)', vp)) = 'forbidden', 'C3: Otto ei hyväksy suojattua (numerot/€/kellonaika)');
  r := public.t60_call(format('booking.admin_texts_approve(%s, ''ok'')', v1));
  perform public.t60_ck((r ->> 'ok')::boolean and r ->> 'status' = 'published', 'C4: Otto hyväksyy ja julkaisee tavallisen tekstin (' || coalesce(r ->> 'err', 'ok') || ')');
  perform public.t60_logout();
  select description into src from kb.products where id = pid1::bigint;
  perform public.t60_ck(src like '% Lisälause selkeyden vuoksi.' and (select published_version from booking.site_texts where key = k1 and lang = 'fi') = 2, 'C5: julkaisu kirjoitti lähdesarakkeeseen (kb.products.description) ja versio on 2');
  perform public.t60_ck((select string_agg(status, ',' order by version) from booking.site_text_versions where text_id = (select id from booking.site_texts where key = k1 and lang = 'fi')) = 'superseded,published', 'C6: historia: v1 superseded, v2 published');
  perform public.t60_anon();
  select e ->> 'text' into txt from jsonb_array_elements(booking.public_get_site_texts('fi') -> 'texts') e where e ->> 'key' = k1;
  select e ->> 'text' into src from jsonb_array_elements(booking.public_get_site_texts('fi') -> 'texts') e where e ->> 'key' = kp;
  perform public.t60_logout();
  perform public.t60_ck(txt like '% Lisälause selkeyden vuoksi.', 'C7: anon näkee julkaistun uuden tekstin');
  perform public.t60_ck(src = (select published_text from booking.site_texts where key = kp and lang = 'fi') and src = (select body from kb.policies where id = (select split_part(kp, '.', 2))::bigint), 'C8: hyväksymätön ehdotus ei näy anonille (ehdot ennallaan)');
  -- itsehyväksyntä ja vanhentunut pohja
  perform public.t60_login(u_otto);
  r := public.t60_call(format('booking.texts_propose(%L, ''fi'', %L)', k3, (select published_text from booking.site_texts where key = k3 and lang = 'fi') || ' Ottolta.'));
  perform public.t60_ck(public.t60_try(format('select booking.admin_texts_approve(%s)', (r ->> 'version_id')::bigint)) = 'self_approval', 'C9: Otto ei hyväksy omaa ehdotustaan');
  v3 := (r ->> 'version_id')::bigint;
  perform public.t60_logout();
  perform public.t60_login(u_adm);
  perform public.t60_ck((public.t60_call(format('booking.admin_texts_approve(%s, ''joonas'')', vp)) ->> 'status') = 'published', 'C10: Joonas (admin) hyväksyy suojatun');
  perform public.t60_logout();
  perform public.t60_ck((select description from kb.products where id = (select split_part(k2, '.', 2))::bigint) like '%19 € ja klo 16:30.', 'C11: suojattu julkaisu kirjoitti lähdesarakkeeseen');
  -- k3: aiempi bot-ehdotus (link) ja Oton ehdotus kilpailevat -> toinen vanhenee
  perform public.t60_login(u_adm);
  select id into v4 from booking.site_text_versions where text_id = (select id from booking.site_texts where key = k3 and lang = 'fi') and status = 'proposed' and author = u_bot;
  r := public.t60_call(format('booking.admin_texts_approve(%s)', v3));
  perform public.t60_ck((r ->> 'ok')::boolean, 'C12: admin hyväksyy Oton tavallisen ehdotuksen (' || coalesce(r ->> 'err', 'ok') || ')');
  perform public.t60_ck(public.t60_try(format('select booking.admin_texts_approve(%s)', v4)) in ('stale_base', 'bad_state'), 'C13: kilpaileva ehdotus ei hyväksyttävissä (vanhentunut)');
  perform public.t60_ck((select status from booking.site_text_versions where id = v4) = 'stale', 'C14: vanhentunut versio merkitty stale');
  -- palautus
  r := public.t60_call(format('booking.admin_texts_rollback(%L, ''fi'', 1, ''testipalautus'')', k1));
  perform public.t60_ck((r ->> 'ok')::boolean and r ->> 'status' = 'published', 'C15: palautus versioon 1 (' || coalesce(r ->> 'err', 'ok') || ')');
  perform public.t60_logout();
  perform public.t60_ck((select count(*) from booking.site_text_versions where text_id = (select id from booking.site_texts where key = k1 and lang = 'fi')) = 3 and (select published_version from booking.site_texts where key = k1 and lang = 'fi') = 3, 'C16: palautus loi uuden version (3), historia säilyy');
  perform public.t60_ck(booking.admin_texts_drift() -> 'drift' = '[]'::jsonb, 'C17: ei driftiä julkaisujen ja palautuksen jälkeen');
  -- manager ei muuta luokkaa eikä aja synkkaa; admin voi lukita (avoimet hylätään)
  perform public.t60_login(u_otto);
  perform public.t60_ck(public.t60_try(format('select booking.admin_texts_set_class(%L, ''fi'', ''locked'')', k4)) = 'forbidden', 'C18: Otto ei muuta luokkaa');
  perform public.t60_ck(public.t60_try('select booking.admin_texts_sync()') = 'forbidden', 'C19: Otto ei aja synkkaa');
  perform public.t60_logout();
  perform public.t60_login(u_bot);
  r := public.t60_call(format('booking.texts_propose(%L, ''fi'', %L)', k4, (select published_text from booking.site_texts where key = k4 and lang = 'fi') || ' avoin'));
  v2 := (r ->> 'version_id')::bigint;
  perform public.t60_logout();
  perform public.t60_login(u_adm);
  perform public.t60_ck((public.t60_call(format('booking.admin_texts_set_class(%L, ''fi'', ''locked'')', k4)) ->> 'class') = 'locked', 'C20: admin lukitsee tekstin');
  perform public.t60_ck(public.t60_try(format('select booking.admin_texts_approve(%s)', v2)) = 'text_locked', 'C21: lukitun tekstin avoin ehdotus ei hyväksyttävissä');
  perform public.t60_logout();
  perform public.t60_ck((select status from booking.site_text_versions where id = v2) = 'rejected', 'C22: lukitus hylkäsi avoimen ehdotuksen');
  -- suora muokkaus lähdetaulussa synkkautuu versioksi, julkaisu ei silmukkaa
  select count(*) into vc from booking.site_text_versions where text_id = (select id from booking.site_texts where key = k3 and lang = 'fi');
  update kb.products set name = name || ' (suora)' where id = (select split_part(k3, '.', 2))::bigint;
  perform public.t60_ck((select published_text from booking.site_texts where key = k3 and lang = 'fi') like '% (suora)' and (select count(*) from booking.site_text_versions where text_id = (select id from booking.site_texts where key = k3 and lang = 'fi')) = vc + 1, 'C23: suora muokkaus lähdetaulussa -> uusi julkaistu versio (yksi)');
  perform public.t60_ck((select string_agg(status, ',' order by version desc) from (select version, status from booking.site_text_versions where text_id = (select id from booking.site_texts where key = k3 and lang = 'fi') order by version desc limit 1) z) = 'published' and (select reason from booking.site_text_versions where text_id = (select id from booking.site_texts where key = k3 and lang = 'fi') order by version desc limit 1) like 'Muokattu suoraan%', 'C24: suora muokkaus kirjattu syyllä');
  -- synkka: uusi UKK-rivi rekisteröityy; idempotentti
  insert into kb.faq(question, answer, language, active) values ('Testikysymys t60?', 'Testivastaus t60.', 'fi', true) returning id into fid;
  r := booking.admin_texts_sync();
  perform public.t60_ck((r ->> 'added')::int = 2 and (select published_text from booking.site_texts where key = 'faq.' || fid || '.answer' and lang = 'fi') = 'Testivastaus t60.', 'C25: admin_texts_sync rekisteröi uuden UKK-rivin (2 tekstiä)');
  perform public.t60_ck((booking.admin_texts_sync() ->> 'added')::int = 0, 'C26: sync on idempotentti');
  -- kielipari: toisen kielen julkaisu merkitsee parin tarkistettavaksi
  select split_part(a.key, '.', 2) into pidb from booking.site_texts a join booking.site_texts b on b.key = a.key and b.lang = 'en' and b.published_text <> ''
   where a.key like 'product.%.description' and a.lang = 'fi' and a.published_text <> '' and a.class = 'normal' order by a.key limit 1;
  if pidb is not null then
    perform public.t60_login(u_bot);
    r := public.t60_call(format('booking.texts_propose(%L, ''fi'', %L)', 'product.' || pidb || '.description', (select published_text from booking.site_texts where key = 'product.' || pidb || '.description' and lang = 'fi') || ' Uusi virke.'));
    v2 := (r ->> 'version_id')::bigint;
    perform public.t60_logout();
    perform public.t60_login(u_otto);
    perform public.t60_call(format('booking.admin_texts_approve(%s)', v2));
    perform public.t60_logout();
    perform public.t60_ck((select needs_translation from booking.site_texts where key = 'product.' || pidb || '.description' and lang = 'en') and not (select needs_translation from booking.site_texts where key = 'product.' || pidb || '.description' and lang = 'fi'), 'C27: FI-muutos merkitsee EN-parin needs_translation');
  else perform public.t60_ck(true, 'C27: (ohitettu: ei FI+EN-paria)'); end if;
  perform public.t60_ck((select count(*) from booking.audit_log where table_name = 'booking.site_texts' and action in ('TEXT_PROPOSE', 'TEXT_PUBLISH', 'TEXT_APPROVE')) >= 6, 'C28: audit_log kirjaa ehdotukset/hyväksynnät/julkaisut');
  perform public.t60_ck((select sum(price) from kb.products) = sum0 and (select count(*) from kb.products) = cnt0, 'C29: hinnat ennallaan koko testin jälkeen');
  perform public.t60_ck(not exists (select 1 from booking.site_text_versions where status = 'published' group by text_id having count(*) > 1), 'C30: jokaisella tekstillä enintään yksi published-versio');

  log := current_setting('t60.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
