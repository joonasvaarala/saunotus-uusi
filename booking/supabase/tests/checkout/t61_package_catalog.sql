-- t61: booking_61 (paketin tietokantapuoli). Rollback-transaktio, tahallinen poikkeus lopussa. Tilausnumerolaskuri palautetaan.
set local lock_timeout = '3s';
set local statement_timeout = '150s';
select set_config('t61.log', '', true);
create function public.t61_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t61.log', coalesce(current_setting('t61.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t61_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 80) end;
end $$;
create function public.t61_call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text; s text;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return jsonb_build_object('err', case when s = 'BK001' then d else s || ':' || left(m, 80) end);
end $$;
create function public.t61_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t61_anon() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon'; end $$;
create function public.t61_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
create function public.t61_ts(p_d date, p_t text) returns timestamptz language sql as $$ select (p_d + p_t::time) at time zone 'Europe/Helsinki' $$;
create function public.t61_mk(p_slot timestamptz, p_persons int, p_email text, p_addons jsonb) returns jsonb language sql as $$
  select booking.public_create_treatment_booking(7, p_slot, p_persons, 'Testi Asiakas', p_email, '+358401234567', false, 'fi', null, 'private', null, null, p_addons) $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_bot uuid := gen_random_uuid(); u_otto uuid := gen_random_uuid(); u_adm uuid := gen_random_uuid(); pre record;
  v_seq0 bigint; v_maxid bigint; v_foreign int; d date; w1 date; r jsonb; e jsonb; o jsonb; n int; txt text; cat7 jsonb; v_old jsonb; v_new jsonb; ok boolean; oid bigint; v_ver bigint;
  k text; log text; npass int; nfail int; v_cnt0 int; v_tl jsonb;
begin
  select * into pre from pre61;
  select last_value into v_seq0 from booking.orders_order_no_seq; select coalesce(max(id), 0) into v_maxid from booking.orders;
  insert into auth.users(id, email) values (u_bot, 't61-bot@example.test'), (u_otto, 't61-otto@example.test'), (u_adm, 't61-admin@example.test');
  insert into booking.text_bots(user_id, label) values (u_bot, 't61 bot');
  insert into booking.staff(user_id, email, name, role) values (u_otto, 't61-otto@example.test', 't61 otto', 'manager'), (u_adm, 't61-admin@example.test', 't61 admin', 'admin');

  -- ===== A: public_catalog =====
  v_new := booking.public_catalog(); v_old := pre.cat;
  select x into cat7 from jsonb_array_elements(v_new) x where (x ->> 'id')::bigint = 7;
  perform public.t61_ck(length(coalesce(cat7 ->> 'description_en', '')) > 150 and cat7 ->> 'description_en' !~* 'elämyslahj', 'A1: tuote 7 description_en olemassa, ei lahjakorttihuomautusta');
  perform public.t61_ck(cat7 ->> 'description' !~ 'Elämyslahjojen' and cat7 ->> 'description' = regexp_replace(pre.d7, ' Elämyslahjojen lahjakortilla:.*$', ''), 'A2: FI-kuvaus = vanha kuvaus ilman lahjakorttihuomautusta (muu teksti ennallaan)');
  perform public.t61_ck(cat7 ->> 'voucher_note' = 'Elämyslahjojen lahjakortilla: varaa ensin yleinen vuoro ja osta rituaali erikseen.' and length(cat7 ->> 'voucher_note_en') > 30, 'A3: voucher_note FI/EN erillisessä kentässä');
  perform public.t61_ck(cat7 ->> 'timeline_text' = 'rituaali 20 min · tauko 10 min · savusauna 1 h 30 min', 'A4: timeline_text FI: ' || coalesce(cat7 ->> 'timeline_text', 'NULL'));
  perform public.t61_ck(cat7 ->> 'timeline_text_en' = 'ritual 20 min · break 10 min · smoke sauna 1 h 30 min', 'A5: timeline_text_en: ' || coalesce(cat7 ->> 'timeline_text_en', 'NULL'));
  perform public.t61_ck(jsonb_array_length(cat7 -> 'timeline') = 3 and (select array_agg((s ->> 'start_min')::int order by (s ->> 'seq')::int) from jsonb_array_elements(cat7 -> 'timeline') s) = array[0, 20, 30]
        and (select array_agg((s ->> 'end_min')::int order by (s ->> 'seq')::int) from jsonb_array_elements(cat7 -> 'timeline') s) = array[20, 30, 120] and (cat7 ->> 'duration_minutes')::int = 120, 'A6: rakenteiset osavaiheet 0–20, 20–30, 30–120 (loppu = alku + 2 h)');
  -- muut tuotteet: vain uudet avaimet (null) lisätty; tuote 7: vain kuvaus/EN + uudet avaimet muuttuneet
  select bool_and((qn - 'voucher_note' - 'voucher_note_en' - 'timeline' - 'timeline_text' - 'timeline_text_en') = qo and qn ->> 'voucher_note' is null and qn ->> 'timeline' is null) into ok
    from (select x qn, (select y from jsonb_array_elements(v_old) y where y -> 'id' = x -> 'id') qo from jsonb_array_elements(v_new) x where (x ->> 'id')::bigint <> 7) q;
  perform public.t61_ck(coalesce(ok, false) and jsonb_array_length(v_new) = jsonb_array_length(v_old), 'A7: muiden tuotteiden katalogirivit täsmälleen ennallaan (hinnat, kestot, valinnat) + uudet avaimet null');
  select (qc - 'voucher_note' - 'voucher_note_en' - 'timeline' - 'timeline_text' - 'timeline_text_en' - 'description' - 'description_en') = (qo - 'description' - 'description_en') into ok
    from (select cat7 qc, (select y from jsonb_array_elements(v_old) y where (y ->> 'id')::bigint = 7) qo) q;
  perform public.t61_ck(coalesce(ok, false), 'A8: tuote 7: hinta, kesto, henkilömäärät, nimet ennallaan');
  perform public.t61_ck((select md5(string_agg(id::text || ':' || coalesce(price::text, '') || ':' || coalesce(price_text, '') || ':' || coalesce(vat_rate::text, ''), '|' order by id)) from kb.products) = pre.prices, 'A9: kb.products hinnat, hintatekstit ja ALV ennallaan');
  perform public.t61_anon();
  v_new := booking.public_catalog(); select coalesce(x ->> 'timeline_text', '') into txt from jsonb_array_elements(v_new) x where (x ->> 'id')::bigint = 7;
  perform public.t61_logout();
  perform public.t61_ck(txt <> '', 'A10: anon-rooli näkee aikajanan katalogissa');
  update booking.product_config set duration_minutes = 121 where product_id = 7;
  perform public.t61_ck(booking._timeline_json(7) is null, 'A11: kesto <> osavaiheiden summa -> aikajanaa ei näytetä');
  update booking.product_config set duration_minutes = 120 where product_id = 7;
  perform public.t61_ck(booking._fmt_minutes(60) = '1 h' and booking._fmt_minutes(90) = '1 h 30 min' and booking._fmt_minutes(5) = '5 min' and booking._fmt_minutes(120) = '2 h', 'A12: kestojen muotoilu');

  -- ===== S: public_settings =====
  v_new := booking.public_settings();
  perform public.t61_ck((v_new -> 'public_treatment_horizon_days') = (select value from booking.settings where key = 'public_treatment_horizon_days') and (v_new - 'public_treatment_horizon_days') = pre.st, 'S1: public_settings sisältää public_treatment_horizon_days; muut avaimet ennallaan');
  perform public.t61_ck(not (v_new ? 'public_treatment_min_lead_minutes') and not (v_new ? 'public_treatment_global_per_hour'), 'S2: muita yksityisiä asetuksia ei paljastettu');

  -- ===== T: tekstijärjestelmä =====
  perform public.t61_ck(jsonb_array_length(booking.admin_texts_drift() -> 'drift') = 0, 'T1: ei driftiä uusien lähteiden jälkeen');
  perform public.t61_ck((select count(*) from booking.site_texts where key in ('product.7.description', 'product_voucher.7.note', 'timeline.' || (select min(id)::text from booking.product_timeline_segments) || '.label')) = 6, 'T2: uudet tekstit rekisterissä (kuvaus fi/en, huomautus fi/en, aikajanan nimi)');
  perform public.t61_ck((select count(*) from booking.site_texts where lang = 'en' and needs_review) = 5 and not exists (select 1 from booking.site_texts where lang = 'fi' and needs_review), 'T3: EN-luonnokset (kuvaus, huomautus, 3 aikajanan nimeä) merkitty needs_review; FI ei');
  perform public.t61_ck(not exists (select 1 from booking.site_texts where key in ('product.7.description', 'product_voucher.7.note') and needs_translation), 'T4: FI/EN-pari ei jää needs_translation-tilaan');
  perform public.t61_ck((select class from booking.site_texts where key = 'product_voucher.7.note' and lang = 'fi') = 'protected' and (select class from booking.site_texts where key = 'product.7.description' and lang = 'en') = 'normal', 'T5: lahjakorttihuomautus protected, kuvaus normal');
  perform public.t61_ck((select published_version from booking.site_texts where key = 'product.7.description' and lang = 'fi') = 2 and (select published_version from booking.site_texts where key = 'product.7.description' and lang = 'en') = 1
        and exists (select 1 from booking.site_text_versions v join booking.site_texts t on t.id = v.text_id where t.key = 'product.7.description' and t.lang = 'fi' and v.version = 1 and v.text like '%Elämyslahjojen%'), 'T6: kuvausmuutos kirjautui historiaan (v1 = vanha teksti säilyy)');
  perform public.t61_anon();
  select count(*) into n from jsonb_array_elements(booking.public_get_site_texts('en') -> 'texts') x where x ->> 'key' in ('product.7.description', 'product_voucher.7.note');
  perform public.t61_logout();
  perform public.t61_ck(n = 2, 'T7: anon näkee EN-tekstit public_get_site_texts-funktiolla');
  -- botti ehdottaa huomautuksen muutoksen -> protected; Otto ei hyväksy; admin hyväksyy; julkaisu poistaa needs_review
  perform public.t61_login(u_bot);
  o := public.t61_call($q$booking.texts_propose('product_voucher.7.note', 'en', 'With an Elämyslahjat gift card: please book a regular session first and buy the ritual separately.', 'selkeämpi')$q$);
  perform public.t61_logout();
  perform public.t61_ck((o ->> 'ok')::boolean and (o ->> 'protected')::boolean, 'T8: botti ehdottaa huomautuksen -> protected: ' || o::text);
  perform public.t61_login(u_otto);
  perform public.t61_ck(public.t61_try(format('select booking.admin_texts_approve(%s)', (o ->> 'version_id'))) = 'forbidden', 'T9: Otto ei hyväksy suojattua huomautusta');
  perform public.t61_logout();
  perform public.t61_login(u_adm);
  perform public.t61_ck(public.t61_try(format('select booking.admin_texts_approve(%s)', (o ->> 'version_id'))) = 'ok', 'T10: Joonas/admin hyväksyy ja julkaisee');
  perform public.t61_logout();
  perform public.t61_ck(not (select needs_review from booking.site_texts where key = 'product_voucher.7.note' and lang = 'en') and (select published_text from booking.site_texts where key = 'product_voucher.7.note' and lang = 'en') like '%please book%', 'T11: ihmisen hyväksymä EN-teksti ei enää needs_review');
  perform public.t61_login(u_otto);
  perform public.t61_ck(public.t61_try($q$select booking.admin_texts_mark_reviewed('product.7.description', 'en', 'luettu')$q$) = 'ok', 'T12: Otto merkitsee EN-kuvauksen tarkistetuksi');
  perform public.t61_ck(public.t61_try($q$select booking.admin_texts_mark_reviewed('product.7.description', 'en')$q$) = 'no_change', 'T13: toinen merkintä -> no_change');
  perform public.t61_logout();
  perform public.t61_login(u_bot);
  perform public.t61_ck(public.t61_try($q$select booking.admin_texts_mark_reviewed('timeline.1.label', 'en')$q$) = 'forbidden' and public.t61_try($q$select booking.admin_texts_review_queue()$q$) = 'forbidden', 'T14: botti ei voi merkitä tarkistetuksi eikä lukea jonoa');
  perform public.t61_logout();
  perform public.t61_login(u_otto);
  perform public.t61_ck(jsonb_array_length(public.t61_call('booking.admin_texts_review_queue()') -> 'items') = 3, 'T15: tarkistusjonossa 3 EN-tekstiä (aikajanan nimet) jäljellä');
  perform public.t61_logout();
  -- suora muokkaus product_config.voucher_note -> uusi versio, ei driftiä
  update booking.product_config set voucher_note = 'Elämyslahjojen lahjakortilla: varaa ensin yleinen vuoro, osta rituaali erikseen.' where product_id = 7;
  perform public.t61_ck((select published_version from booking.site_texts where key = 'product_voucher.7.note' and lang = 'fi') = 2 and jsonb_array_length(booking.admin_texts_drift() -> 'drift') = 0, 'T16: suora muokkaus product_config.voucher_note synkkautuu versioksi');
  -- aikajanan hallinta
  perform public.t61_login(u_adm);
  perform public.t61_ck(public.t61_try($q$select booking.admin_set_product_timeline(7, '[{"kind":"ritual","label":"rituaali","label_en":"ritual","minutes":20},{"kind":"smoke_sauna","label":"savusauna","label_en":"smoke sauna","minutes":60}]'::jsonb)$q$) = 'timeline_sum', 'T17: osavaiheiden summa <> kesto hylätään');
  perform public.t61_logout();
  perform public.t61_login(u_bot);
  perform public.t61_ck(public.t61_try($q$select booking.admin_set_product_timeline(7, '[]'::jsonb)$q$) = 'forbidden', 'T18: botti ei muokkaa aikajanaa');
  perform public.t61_logout();
  perform public.t61_anon();
  perform public.t61_ck(public.t61_try($q$select booking.admin_set_product_timeline(7, '[]'::jsonb)$q$) like '42501%' and public.t61_try('select count(*) from booking.product_timeline_segments') like '42501%', 'T19: anon ei muokkaa eikä lue aikajanataulua');
  perform public.t61_logout();
  perform public.t61_login(u_adm);
  o := public.t61_call($q$booking.admin_set_product_timeline(7, '[{"kind":"ritual","label":"rituaali","label_en":"ritual","minutes":20},{"kind":"break","label":"tauko","label_en":"break","minutes":10},{"kind":"smoke_sauna","label":"savusauna","label_en":"smoke sauna","minutes":90}]'::jsonb)$q$);
  perform public.t61_logout();
  perform public.t61_ck((o ->> 'ok')::boolean and booking._timeline_json(7) ->> 'text' = 'rituaali 20 min · tauko 10 min · savusauna 1 h 30 min' and jsonb_array_length(booking.admin_texts_drift() -> 'drift') = 0
        and (select count(*) from booking.site_texts where key like 'timeline.%') = 6, 'T20: aikajanan korvaus toimii, tekstit uudelleenrekisteröity, ei orpoja rivejä');

  -- ===== L: lisäpalvelut (p_addons) =====
  update booking.settings set value = '"pay_later"'::jsonb where key = 'public_payment_mode';
  update booking.settings set value = '400'::jsonb where key = 'public_treatment_horizon_days';
  update booking.settings set value = '1000'::jsonb where key in ('public_treatment_global_per_hour', 'public_treatment_max_open_per_email', 'rl_email_per_10min', 'rl_ip_per_10min');
  for d in select x::date from generate_series(current_date + 20, current_date + 160, interval '7 days') x where extract(isodow from x) = 6 loop
    continue when not (booking._public_shift_day_open(d) and booking._public_shift_day_open(d + 1));
    continue when exists (select 1 from booking.reservations r where r.status in ('pending', 'confirmed') and r.starts_at >= (d::timestamp) at time zone 'Europe/Helsinki' and r.starts_at < ((d + 2)::timestamp) at time zone 'Europe/Helsinki');
    continue when exists (select 1 from booking.space_blocks b where b.active and b.during && tstzrange((d::timestamp) at time zone 'Europe/Helsinki', ((d + 2)::timestamp) at time zone 'Europe/Helsinki'));
    continue when (select count(*) from booking._treatment_availability_core(7, d, d, 1, true, false)) <> 3;
    w1 := d; exit;
  end loop;
  if w1 is null then raise exception 'TESTRESULT_ABORT ei siistiä viikonloppua'; end if;
  select count(*) into v_cnt0 from booking.orders;
  -- L1: vanha 12-parametrinen kutsu toimii edelleen (p_addons oletus null)
  r := booking.public_create_treatment_booking(7, public.t61_ts(w1, '16:00'), 2, 'Testi Asiakas', 'l1@t61.example', '+358401234567', false, 'fi', null, 'private', null, null);
  perform public.t61_ck((r ->> 'ok')::boolean and (r ->> 'total')::numeric = 98 and (r ->> 'addons_total')::numeric = 0, 'L1: ilman lisäpalveluja toimii kuten ennen (98 €) ' || coalesce(r ->> 'code', ''));
  -- L2: pyyhe x2 koodilla
  r := public.t61_mk(public.t61_ts(w1, '16:30'), 2, 'l2@t61.example', '[{"code":"pyyhe","quantity":2}]'::jsonb);
  select id into oid from booking.orders where public_token = (r ->> 'token')::uuid;
  perform public.t61_ck((r ->> 'ok')::boolean and (r ->> 'total')::numeric = 108 and (r ->> 'addons_total')::numeric = 10, 'L2: pyyhe x2 -> yhteensä 108 € (98 + 10) ' || coalesce(r ->> 'code', ''));
  perform public.t61_ck((select total_gross from booking.orders where id = oid) = 108 and (select count(*) from booking.order_items where order_id = oid and kind = 'addon' and quantity = 2 and unit_price_gross = 5 and line_total_gross = 10 and vat_rate = 25.5
        and parent_item_id = (select id from booking.order_items where order_id = oid and kind <> 'addon' limit 1)) = 1, 'L3: tilaus: lisäpalvelurivi (2 x 5 €, ALV 25,5, vanhempana pääriveä), tilauksen summa 108');
  perform public.t61_ck((select amount from booking.payments where order_id = oid) = 108, 'L4: pay_later-maksurivin summa sisältää lisäpalvelut (108)');
  -- L5: pyyhe id:llä anon-roolilla
  perform public.t61_anon();
  execute format($q$select booking.public_create_treatment_booking(7, %L::timestamptz, 1, 'Testi Asiakas', 'l5@t61.example', '+358401234567', false, 'fi', null, 'private', null, null, '[{"id":5,"quantity":1}]'::jsonb)$q$, public.t61_ts(w1, '17:00')) into r;
  perform public.t61_logout();
  perform public.t61_ck((r ->> 'ok')::boolean and (r ->> 'total')::numeric = 54, 'L5: anon-rooli, pyyhe id:llä, 1 hlö -> 54 € ' || coalesce(r ->> 'code', ''));
  select count(*) into n from booking.orders;
  -- virhetapaukset (ei tilauksia, aikaa ei pidetä)
  r := public.t61_mk(public.t61_ts(w1 + 1, '16:00'), 2, 'l6@t61.example', '[{"code":"turvenaamio_jalkakylpy","quantity":1}]'::jsonb);
  perform public.t61_ck(not (r ->> 'ok')::boolean and r ->> 'code' = 'addon_not_allowed', 'L6: turvenaamio ei sovi rituaalipakettiin -> addon_not_allowed: ' || coalesce(r ->> 'code', 'ok'));
  r := public.t61_mk(public.t61_ts(w1 + 1, '16:00'), 2, 'l7@t61.example', '[{"code":"ei_ole","quantity":1}]'::jsonb);
  perform public.t61_ck(not (r ->> 'ok')::boolean and r ->> 'code' = 'addon_not_found', 'L7: tuntematon lisäpalvelu -> addon_not_found');
  r := public.t61_mk(public.t61_ts(w1 + 1, '16:00'), 2, 'l8@t61.example', '[{"code":"pyyhe","quantity":9999}]'::jsonb);
  perform public.t61_ck(not (r ->> 'ok')::boolean and r ->> 'code' = 'addon_quantity', 'L8: liian suuri määrä -> addon_quantity: ' || coalesce(r ->> 'code', 'ok'));
  r := public.t61_mk(public.t61_ts(w1 + 1, '16:00'), 2, 'l9@t61.example', '{"code":"pyyhe"}'::jsonb);
  perform public.t61_ck(not (r ->> 'ok')::boolean and r ->> 'code' = 'invalid_addons', 'L9: väärä muoto -> invalid_addons: ' || coalesce(r ->> 'code', 'ok'));
  r := public.t61_mk(public.t61_ts(w1 + 1, '16:00'), 2, 'l10@t61.example', '[{"code":"pyyhe","quantity":"abc"}]'::jsonb);
  perform public.t61_ck(not (r ->> 'ok')::boolean and r ->> 'code' = 'addon_quantity', 'L10: määrä ei kokonaisluku -> addon_quantity');
  perform public.t61_ck((select count(*) from booking.orders) = n, 'L11: virheelliset yritykset eivät luoneet tilauksia');
  -- sama aika onnistuu virheiden jälkeen (alitransaktio kumosi varauksen)
  r := public.t61_mk(public.t61_ts(w1 + 1, '16:00'), 2, 'l12@t61.example', '[{"code":"pyyhe","quantity":1}]'::jsonb);
  perform public.t61_ck((r ->> 'ok')::boolean and (r ->> 'total')::numeric = 103, 'L12: virheiden jälkeen sama aika varattavissa, 98 + 5 = 103 ' || coalesce(r ->> 'code', ''));
  -- pitotila (verkkomaksu): lisäpalvelut mukana odottavan tilauksen summassa
  update booking.settings set value = '"hold_until_paid"'::jsonb where key = 'public_payment_mode';
  update booking.integration_config set mode = 'test' where key = 'mobilepay';
  r := public.t61_mk(public.t61_ts(w1 + 1, '17:00'), 2, 'l13@t61.example', '[{"code":"pyyhe","quantity":2}]'::jsonb);
  select id into oid from booking.orders where public_token = (r ->> 'token')::uuid;
  perform public.t61_ck((r ->> 'ok')::boolean and r ->> 'status' = 'pending' and (r ->> 'total')::numeric = 108 and (select total_gross from booking.orders where id = oid) = 108 and r ->> 'checkout_state' = 'awaiting_payment',
                        'L13: pitotila: tilaus odottaa maksua summalla 108 € (lisäpalvelut mukana) ' || coalesce(r ->> 'code', '') || '/' || coalesce(r ->> 'checkout_state', ''));
  perform public.t61_ck((select count(*) from booking.reservations where order_id = oid and status = 'pending') = 1 and (select count(*) from booking.order_items where order_id = oid and kind = 'addon') = 1, 'L14: pitotilan varaus + lisäpalvelurivi');

  log := current_setting('t61.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
exception when others then
  -- alitransaktio on kumoutunut: palautetaan tilausnumerolaskuri jos ei vieraita tilauksia
  select count(*) into v_foreign from booking.orders where id > v_maxid;
  if v_foreign = 0 then perform setval('booking.orders_order_no_seq', v_seq0, true); end if;
  raise;
end $t$;
