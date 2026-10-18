do $t$
declare u_bot uuid := gen_random_uuid(); u_old uuid := gen_random_uuid(); u_tmp uuid := gen_random_uuid(); u_otto uuid := gen_random_uuid(); u_adm uuid := gen_random_uuid();
  kn text; kn2 text; kn3 text; kn4 text; kp text; kp2 text; kl text; r jsonb; r2 jsonb; v1 bigint; v2 bigint; v3 bigint; v4 bigint; v5 bigint; v6 bigint; p0 text; t0 text; a jsonb; tb text;
  nb int; log text; npass int; nfail int;
begin
  insert into auth.users(id, email) values (u_bot, 't67-bot@example.test'), (u_old, 't67-old@example.test'), (u_tmp, 't67-tmp@example.test'), (u_otto, 't67-otto@example.test'), (u_adm, 't67-admin@example.test');
  insert into booking.text_bots(user_id, label, role_code) values (u_bot, 't67 botti', 'text_editor_approver'), (u_old, 't67 vanha botti', 'text_editor');
  insert into booking.roles(code, label, description, is_staff, sort_order) values ('t67_tmp', 'tmp', 'tmp', false, 99);
  insert into booking.role_permissions(role_code, permission) values ('t67_tmp', 'texts.propose'), ('t67_tmp', 'texts.approve');
  insert into booking.text_bots(user_id, label, role_code) values (u_tmp, 't67 tmp-botti', 't67_tmp');
  insert into booking.staff(user_id, email, name, role) values (u_otto, 't67-otto@example.test', 'T67 Otto', 'manager'), (u_adm, 't67-admin@example.test', 'T67 Joonas', 'admin');
  select key into kn  from booking.site_texts where key like 'product.%.description' and lang = 'fi' and class = 'normal' and published_text <> '' order by key limit 1 offset 0;
  select key into kn2 from booking.site_texts where key like 'product.%.description' and lang = 'fi' and class = 'normal' and published_text <> '' order by key limit 1 offset 1;
  select key into kn3 from booking.site_texts where key like 'product.%.description' and lang = 'fi' and class = 'normal' and published_text <> '' order by key limit 1 offset 2;
  select key into kn4 from booking.site_texts where key like 'product.%.description' and lang = 'fi' and class = 'normal' and published_text <> '' order by key limit 1 offset 3;
  select key into kp  from booking.site_texts where source_table = 'kb.policies' and lang = 'fi' and published_text <> '' and source_column = 'body' order by key limit 1;
  select key into kp2 from booking.site_texts where source_table = 'kb.policies' and lang = 'fi' and published_text <> '' and source_column = 'body' and key <> kp order by key limit 1;
  select key into kl  from booking.site_texts where key like 'product.%.price_text' and published_text <> '' limit 1;
  -- A: oikeusmalli
  perform public.t67_ck((select array_agg(permission order by permission) from booking.role_permissions where role_code = 'text_editor_approver') = array['texts.approve', 'texts.approve_own', 'texts.propose'], 'A1: text_editor_approver = propose + approve + approve_own (EI approve_protected, EI manage)');
  perform public.t67_ck((select array_agg(permission order by permission) from booking.role_permissions where role_code = 'text_editor') = array['texts.propose'], 'A2: text_editor ennallaan: vain texts.propose');
  perform public.t67_ck((select string_agg(role_code || ':' || permission, ',' order by role_code, permission) from booking.role_permissions where permission like 'texts.%' and role_code in ('manager', 'admin', 'text_editor'))
        = (select string_agg(x, ',' order by x) from (select unnest(string_to_array(perms, ',')) x from pre67) q where x ~ '^(manager|admin|text_editor):'), 'A3: manager-, admin- ja text_editor-oikeudet täsmälleen ennallaan');
  perform public.t67_ck((select count(*) from booking.roles where code = 'text_editor_approver' and not is_staff) = 1 and (select count(*) from booking.staff where role = 'text_editor_approver') = 0, 'A4: uusi rooli ei ole henkilöstörooli');
  perform public.t67_ck((select count(*) from booking.text_bots where label = 'Otto tekstibotti') = 0 or (select role_code from booking.text_bots where label = 'Otto tekstibotti') = 'text_editor_approver', 'A6: Otto tekstibotti on siirretty rooliin text_editor_approver (jos rivi on)');
  perform public.t67_ck(not exists (select 1 from booking.site_text_versions where approved_by is not null and approved_by_kind is null), 'A7: vanhat hyväksynnät täydennetty approved_by_kind-arvolla');

  -- B: botti ehdottaa ja hyväksyy itse tavallisen tekstin
  p0 := (select published_text from booking.site_texts where key = kn and lang = 'fi');
  perform public.t67_login(u_bot);
  r := public.t67_call(format($q$booking.texts_propose(%L, 'fi', %L, 'selkeämpi')$q$, kn, p0 || ' Tervetuloa.'));
  v1 := (r ->> 'version_id')::bigint;
  perform public.t67_ck((r ->> 'ok')::boolean and not (r ->> 'protected')::boolean, 'B1: botti ehdottaa tavallisen tekstin (ei protected)');
  r2 := public.t67_call(format('booking.admin_texts_approve(%s, ''Oton ohjeesta'')', v1));
  perform public.t67_logout();
  perform public.t67_ck((r2 ->> 'ok')::boolean and r2 ->> 'status' = 'published' and not (r2 ->> 'protected')::boolean, 'B2: botti hyväksyy ja julkaisee oman tavallisen ehdotuksensa: ' || r2::text);
  perform public.t67_ck((select published_text from booking.site_texts where key = kn and lang = 'fi') = p0 || ' Tervetuloa.', 'B3: teksti muuttui julkaistuksi');
  perform public.t67_ck((select author = u_bot and approved_by = u_bot and published_by = u_bot and author_kind = 'bot' and approved_by_kind = 'bot' from booking.site_text_versions where id = v1), 'B4: versio: ehdottaja, hyväksyjä ja julkaisija = botti; approved_by_kind = bot');
  perform public.t67_ck((select new_data ->> 'approved_by_kind' = 'bot' and (new_data -> 'self_approved')::text = 'true' and new_data ->> 'approved_by_label' = 'botti: t67 botti' and new_data ->> 'actor_kind' = 'bot' and new_data ->> 'actor_label' = 'botti: t67 botti'
        and new_data ->> 'old_text' = p0 and new_data ->> 'new_text' = p0 || ' Tervetuloa.' from booking.audit_log where action = 'TEXT_APPROVE' and actor = u_bot order by id desc limit 1), 'B5: audit TEXT_APPROVE: actor_kind bot, approved_by_kind bot, self_approved true, vanha+uusi teksti');
  perform public.t67_ck((select new_data ->> 'approved_by_kind' = 'bot' and (new_data -> 'self_approved')::text = 'true' and new_data ->> 'actor_kind' = 'bot' from booking.audit_log where action = 'TEXT_PUBLISH' and actor = u_bot order by id desc limit 1), 'B6: audit TEXT_PUBLISH: bot, self_approved true');
  perform public.t67_login(u_otto);
  a := public.t67_call(format($q$booking.admin_texts_audit(%L, 'fi', 5)$q$, kn));
  r := public.t67_call(format($q$booking.admin_texts_versions(%L, 'fi')$q$, kn));
  perform public.t67_logout();
  perform public.t67_ck((a -> 'items' -> 0 ->> 'approved_by_kind') = 'bot' and (a -> 'items' -> 0 -> 'self_approved')::text = 'true' and (a -> 'items' -> 0 ->> 'approved_by') = 'botti: t67 botti', 'B7: admin_texts_audit (Otto) näyttää hyväksyjäksi botin ja self_approved: ' || coalesce((a -> 'items' -> 0)::text, a::text));
  perform public.t67_ck((r -> 'versions' -> 0 ->> 'approved_by_kind') = 'bot' and (r -> 'versions' -> 0 -> 'self_approved')::text = 'true', 'B8: admin_texts_versions näyttää approved_by_kind ja self_approved');
  perform public.t67_ck((select count(*) from booking.audit_log where action = 'TEXT_APPROVE' and actor = u_bot) = 1, 'B9: yksi TEXT_APPROVE-rivi botille');

  -- C: eskaloitu (numero, €, aika, puhelin, sähköposti, linkki) -> botti ei hyväksy; Otto hyväksyy
  perform public.t67_login(u_bot);
  for r in select to_jsonb(x) from (values ('numbers', ' Kesto 55 minuuttia.'), ('currency', ' Hinta euroa.'), ('time', ' Aukeaa klo 18:30.'), ('phone', ' Soita +358 40 123 4567.'), ('email', ' Kysy test@example.test.'), ('link', ' Katso https://example.test/x.'), ('percent', ' Alennus yli %.')) x(k, s) loop
    r2 := public.t67_call(format($q$booking.texts_propose(%L, 'fi', %L, 'testi')$q$, kn2, (select published_text from booking.site_texts where key = kn2 and lang = 'fi') || (r ->> 's')));
    v2 := (r2 ->> 'version_id')::bigint;
    perform public.t67_ck((r2 ->> 'protected')::boolean and (r2 -> 'escalation') ? (r ->> 'k'), 'C1-' || (r ->> 'k') || ': ehdotus eskaloituu protected-tilaan');
    perform public.t67_ck(public.t67_try(format('select booking.admin_texts_approve(%s)', v2)) = 'forbidden', 'C2-' || (r ->> 'k') || ': botti ei hyväksy eskaloitua (forbidden)');
    perform public.t67_ck(public.t67_try(format('select booking.admin_texts_publish(%s)', v2)) in ('forbidden', 'bad_state'), 'C3-' || (r ->> 'k') || ': botti ei julkaise eskaloitua');
    perform public.t67_ck((select status from booking.site_text_versions where id = v2) = 'proposed', 'C4-' || (r ->> 'k') || ': versio jää proposed-tilaan');
  end loop;
  perform public.t67_logout();
  perform public.t67_login(u_otto);
  perform public.t67_ck(public.t67_try(format('select booking.admin_texts_approve(%s, ''ok'')', v2)) = 'ok', 'C6: Otto hyväksyy botin eskaloidun ehdotuksen');
  perform public.t67_logout();
  perform public.t67_ck((select approved_by_kind = 'human' and author_kind = 'bot' from booking.site_text_versions where id = v2) and (select new_data ->> 'approved_by_kind' = 'human' and (new_data -> 'self_approved')::text = 'false' from booking.audit_log where action = 'TEXT_APPROVE' and actor = u_otto order by id desc limit 1), 'C7: Oton hyväksyntä: approved_by_kind human, self_approved false');

  -- D: suojattu luokka (ehdot): botti ehdottaa, ei hyväksy
  perform public.t67_login(u_bot);
  r := public.t67_call(format($q$booking.texts_propose(%L, 'fi', %L, 'testi')$q$, kp, (select published_text from booking.site_texts where key = kp and lang = 'fi') || ' Selventävä lause.'));
  v3 := (r ->> 'version_id')::bigint;
  perform public.t67_ck((r ->> 'protected')::boolean, 'D1: suojatun luokan ehdotus on protected, vaikka teksti ei sisällä numeroita');
  perform public.t67_ck(public.t67_try(format('select booking.admin_texts_approve(%s)', v3)) = 'forbidden' and public.t67_try(format('select booking.admin_texts_publish(%s)', v3)) in ('forbidden', 'bad_state') and public.t67_try(format('select booking.admin_texts_reject(%s)', v3)) = 'forbidden', 'D2: botti ei hyväksy, julkaise eikä hylkää suojattua');
  perform public.t67_ck(public.t67_try($q$select booking.admin_texts_mark_reviewed('x', 'fi')$q$) in ('forbidden', 'not_found', 'no_change') and public.t67_try(format($q$select booking.admin_texts_set_class(%L, 'fi', 'normal')$q$, kp)) = 'forbidden', 'D3: botti ei muuta luokkaa (set_class forbidden)');
  perform public.t67_logout();
  perform public.t67_ck((select status from booking.site_text_versions where id = v3) = 'proposed', 'D4: suojattu versio jää proposed');
  perform public.t67_login(u_otto);
  perform public.t67_ck(public.t67_try(format('select booking.admin_texts_approve(%s)', v3)) = 'ok', 'D5: Otto hyväksyy suojatun');
  perform public.t67_logout();

  -- E: lukittu rivi
  perform public.t67_login(u_bot);
  perform public.t67_ck(public.t67_call(format($q$booking.texts_propose(%L, 'fi', 'Uusi hinta 1 €')$q$, kl)) ->> 'err' = 'text_locked', 'E1: botti ei ehdota lukittua hintatekstiä');
  r := public.t67_call(format($q$booking.texts_propose(%L, 'fi', %L, 'testi')$q$, kn3, (select published_text from booking.site_texts where key = kn3 and lang = 'fi') || ' Lisäys.'));
  v4 := (r ->> 'version_id')::bigint;
  perform public.t67_logout();
  update booking.site_texts set class = 'locked' where key = kn3 and lang = 'fi';
  perform public.t67_login(u_bot);
  perform public.t67_ck(public.t67_try(format('select booking.admin_texts_approve(%s)', v4)) = 'text_locked' and public.t67_try(format('select booking.admin_texts_publish(%s)', v4)) = 'text_locked', 'E2: botti ei hyväksy ehdotusta joka kohdistuu lukittuun riviin (text_locked)');
  perform public.t67_ck(public.t67_try(format($q$select booking.admin_texts_rollback(%L, 'fi', 1)$q$, kn3)) = 'text_locked', 'E3: botti ei palauta lukittua riviä');
  perform public.t67_logout();
  update booking.site_texts set class = 'normal' where key = kn3 and lang = 'fi';

  -- F: muut roolit ennallaan
  perform public.t67_login(u_old);
  r := public.t67_call(format($q$booking.texts_propose(%L, 'fi', %L, 'testi')$q$, kn4, (select published_text from booking.site_texts where key = kn4 and lang = 'fi') || ' Lisäys.'));
  v5 := (r ->> 'version_id')::bigint;
  perform public.t67_ck(public.t67_try(format('select booking.admin_texts_approve(%s)', v5)) = 'forbidden' and public.t67_try(format('select booking.admin_texts_publish(%s)', v5)) = 'forbidden', 'F1: text_editor-botti (vanha rooli) ei hyväksy (ennallaan)');
  perform public.t67_logout();
  perform public.t67_login(u_tmp);
  r := public.t67_call(format($q$booking.texts_propose(%L, 'fi', %L, 'testi')$q$, kn4, (select published_text from booking.site_texts where key = kn4 and lang = 'fi') || ' Toinen lisäys.'));
  v6 := (r ->> 'version_id')::bigint;
  perform public.t67_ck(public.t67_try(format('select booking.admin_texts_approve(%s)', v6)) = 'self_approval', 'F2: rooli jolla approve mutta ei approve_own: itsehyväksyntä estetty (self_approval)');
  perform public.t67_logout();
  perform public.t67_login(u_bot);
  perform public.t67_ck(public.t67_try(format('select booking.admin_texts_approve(%s)', v6)) = 'ok', 'F3: text_editor_approver-botti hyväksyy toisen botin tavallisen ehdotuksen');
  perform public.t67_logout();
  perform public.t67_login(u_otto);
  r := public.t67_call(format($q$booking.texts_propose(%L, 'fi', %L, 'Oton ehdotus')$q$, kp2, (select published_text from booking.site_texts where key = kp2 and lang = 'fi') || ' Oton lisäys.'));
  v5 := (r ->> 'version_id')::bigint;
  perform public.t67_logout();
  perform public.t67_login(u_bot);
  perform public.t67_ck(public.t67_try(format('select booking.admin_texts_approve(%s)', v5)) = 'forbidden', 'F4: botti ei hyväksy Oton suojattua ehdotusta');
  perform public.t67_logout();
  perform public.t67_login(u_otto);
  perform public.t67_ck(public.t67_try(format('select booking.admin_texts_approve(%s)', v5)) = 'ok', 'F5: Otto hyväksyy oman suojatun ehdotuksensa kuten ennen (itsehyväksyntä manager/admin)');
  perform public.t67_logout();

  -- G: palautus
  perform public.t67_login(u_bot);
  r := public.t67_call(format($q$booking.admin_texts_rollback(%L, 'fi', 1, 'palautus')$q$, kn));
  perform public.t67_ck((r ->> 'ok')::boolean and (select published_text from booking.site_texts where key = kn and lang = 'fi') = p0, 'G1: botti palauttaa tavallisen tekstin edelliseen versioon: ' || r::text);
  perform public.t67_ck(public.t67_try(format($q$select booking.admin_texts_rollback(%L, 'fi', 1)$q$, kn2)) = 'forbidden', 'G3: botti ei palauta versioon, jossa numerot/€/aika/linkki muuttuvat (eskaloitu -> forbidden)');
  perform public.t67_logout();
  perform public.t67_ck((select new_data ->> 'approved_by_kind' = 'bot' and new_data ->> 'actor_kind' = 'bot' from booking.audit_log where action = 'TEXT_ROLLBACK' and actor = u_bot order by id desc limit 1), 'G2a: TEXT_ROLLBACK-audit: approved_by_kind bot, actor_kind bot: ' || coalesce((select new_data::text from booking.audit_log where action = 'TEXT_ROLLBACK' and actor = u_bot order by id desc limit 1), 'EI RIVIÄ'));
  perform public.t67_ck((select approved_by_kind = 'bot' from booking.site_text_versions v join booking.site_texts t on t.id = v.text_id where t.key = kn and t.lang = 'fi' order by v.version desc limit 1), 'G2b: palautusversion approved_by_kind bot');

  -- H: rajat
  select count(*) into nb from booking.audit_log where actor = u_bot and action in ('TEXT_APPROVE', 'TEXT_ROLLBACK');
  update booking.settings set value = to_jsonb(nb) where key = 'texts_bot_max_approvals_per_day';
  perform public.t67_login(u_bot);
  r := public.t67_call(format($q$booking.texts_propose(%L, 'fi', %L, 'testi')$q$, kn3, (select published_text from booking.site_texts where key = kn3 and lang = 'fi') || ' Raja.'));
  v4 := (r ->> 'version_id')::bigint;
  perform public.t67_ck(public.t67_try(format('select booking.admin_texts_approve(%s)', v4)) = 'rate_limited', 'H1: botin päivittäinen hyväksymisraja toimii (rate_limited)');
  perform public.t67_logout();
  update booking.settings set value = to_jsonb(nb + 1) where key = 'texts_bot_max_approvals_per_day';
  perform public.t67_login(u_bot);
  perform public.t67_ck(public.t67_try(format('select booking.admin_texts_approve(%s)', v4)) = 'ok', 'H2: rajan sisällä hyväksyntä onnistuu');
  perform public.t67_logout();
  update booking.settings set value = to_jsonb((select count(*) from booking.site_text_versions where author = u_bot and created_at > now() - interval '24 hours')) where key = 'texts_max_proposals_per_day';
  perform public.t67_login(u_bot);
  perform public.t67_ck(public.t67_call(format($q$booking.texts_propose(%L, 'fi', %L, 'testi')$q$, kn4, (select published_text from booking.site_texts where key = kn4 and lang = 'fi') || ' Yli rajan.')) ->> 'err' = 'rate_limited', 'H3: ehdotusraja koskee bottia vaikka botilla on hyväksymisoikeus');
  perform public.t67_logout();
  perform public.t67_login(u_otto);
  perform public.t67_ck(public.t67_call(format($q$booking.texts_propose(%L, 'fi', %L, 'testi')$q$, kn4, (select published_text from booking.site_texts where key = kn4 and lang = 'fi') || ' Oton ehdotus.')) ->> 'err' is null, 'H4: ihmishyväksyjää (Otto) ehdotusraja ei koske');
  perform public.t67_logout();

  -- I: botti ei näe asiakas-/tilaus-/maksutietoja eikä pääse hallintaan
  perform public.t67_login(u_bot);
  foreach tb in array array['customers', 'orders', 'order_items', 'payments', 'reservations', 'gift_cards', 'receipts', 'refunds', 'email_outbox', 'order_requests', 'voucher_claims', 'staff', 'audit_log', 'settings'] loop
    r := public.t67_call(format('(select to_jsonb(count(*)) from booking.%I)', tb));
    perform public.t67_ck(r = '0'::jsonb or (r ->> 'err') like '42501%', 'I1: botti ei näe rivejä taulussa booking.' || tb || ' (' || r::text || ')');
  end loop;
  perform public.t67_ck(public.t67_try('select booking.admin_my_permissions()') <> 'ok' or (public.t67_call('booking.admin_my_permissions()') ->> 'role') is null, 'I2: botti ei ole henkilöstöä (ei roolia)');
  perform public.t67_ck(public.t67_try($q$select booking.admin_set_setting('hold_minutes', '20')$q$) = 'forbidden' and public.t67_try($q$select booking.admin_texts_import('[]'::jsonb)$q$) = 'forbidden' and public.t67_try('select booking.admin_texts_sync()') = 'forbidden', 'I3: botti ei muuta asetuksia eikä tuo/synkkaa tekstejä (texts.manage puuttuu)');
  perform public.t67_ck(public.t67_try($q$select booking.admin_update_product(1, '{"price": 1}')$q$) = 'forbidden' and public.t67_try('update kb.products set price = 1') like '42501%' and public.t67_try($q$update booking.site_texts set published_text = 'x'$q$) like '42501%', 'I4: botti ei muuta hintoja, tuotteita eikä tekstitaulua suoraan');
  perform public.t67_ck(public.t67_try($q$select booking.admin_texts_audit()$q$) = 'ok', 'I5: botti näkee tekstiaudit-RPC:n (vain tekstit; ei asiakastietoja)');
  perform public.t67_logout();

  -- J: lukitut ja hinnat ennallaan
  perform public.t67_ck((select count(*) from booking.site_texts where class = 'locked') = (select lockedn from pre67) and (select md5(string_agg(id::text || ':' || coalesce(price::text, '') || ':' || coalesce(price_text, '') || ':' || coalesce(vat_rate::text, ''), '|' order by id)) from kb.products) = (select prodsum from pre67), 'J1: lukittuja rivejä yhtä monta; hinnat, hintatekstit ja ALV ennallaan');
  perform public.t67_ck(jsonb_array_length(booking.admin_texts_drift() -> 'drift') = 0, 'J2: ei driftiä lähdetauluihin');
  log := current_setting('t67.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
