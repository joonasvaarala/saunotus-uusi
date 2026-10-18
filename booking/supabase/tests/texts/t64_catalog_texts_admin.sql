-- t64: booking_61 (paketin tietokantapuoli). Rollback-transaktio, tahallinen poikkeus lopussa. Tilausnumerolaskuri palautetaan.
set local lock_timeout = '3s';
set local statement_timeout = '150s';
select set_config('t64.log', '', true);
create function public.t64_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t64.log', coalesce(current_setting('t64.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t64_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 80) end;
end $$;
create function public.t64_call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text; s text;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return jsonb_build_object('err', case when s = 'BK001' then d else s || ':' || left(m, 80) end);
end $$;
create function public.t64_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t64_anon() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon'; end $$;
create function public.t64_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
create function public.t64_ts(p_d date, p_t text) returns timestamptz language sql as $$ select (p_d + p_t::time) at time zone 'Europe/Helsinki' $$;
create function public.t64_mk(p_slot timestamptz, p_persons int, p_email text, p_addons jsonb) returns jsonb language sql as $$
  select booking.public_create_treatment_booking(7, p_slot, p_persons, 'Testi Asiakas', p_email, '+358401234567', false, 'fi', null, 'private', null, null, p_addons) $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_bot uuid := gen_random_uuid(); u_otto uuid := gen_random_uuid(); u_adm uuid := gen_random_uuid(); pre record;
  v_seq0 bigint; v_maxid bigint; v_foreign int; d date; w1 date; r jsonb; o jsonb; n int; txt text; cat7 jsonb; v_old jsonb; v_new jsonb; ok boolean; log text; npass int; nfail int; seg bigint;
begin
  select * into pre from pre64;
  select last_value into v_seq0 from booking.orders_order_no_seq; select coalesce(max(id), 0) into v_maxid from booking.orders;
  insert into auth.users(id, email) values (u_bot, 't64-bot@example.test'), (u_otto, 't64-otto@example.test'), (u_adm, 't64-admin@example.test');
  insert into booking.text_bots(user_id, label) values (u_bot, 't64 botti');
  insert into booking.staff(user_id, email, name, role) values (u_otto, 't64-otto@example.test', 'T64 Otto', 'manager'), (u_adm, 't64-admin@example.test', 'T64 Joonas', 'admin');
  v_new := booking.public_catalog(); v_old := pre.cat;
  select x into cat7 from jsonb_array_elements(v_new) x where (x ->> 'id')::bigint = 7;
  -- ===== A: tauko sisäinen =====
  perform public.t64_ck(cat7 ->> 'timeline_text' = 'rituaali 20 min · savusauna 1 h 30 min', 'A1: timeline_text ilman taukoa: ' || coalesce(cat7 ->> 'timeline_text', 'NULL'));
  perform public.t64_ck(cat7 ->> 'timeline_text_en' = 'ritual 20 min · smoke sauna 1 h 30 min', 'A2: timeline_text_en ilman taukoa: ' || coalesce(cat7 ->> 'timeline_text_en', 'NULL'));
  perform public.t64_ck(jsonb_array_length(cat7 -> 'timeline') = 2 and (select array_agg(s ->> 'kind' order by (s ->> 'seq')::int) from jsonb_array_elements(cat7 -> 'timeline') s) = array['ritual', 'smoke_sauna']
        and (select array_agg((s ->> 'start_min')::int order by (s ->> 'seq')::int) from jsonb_array_elements(cat7 -> 'timeline') s) = array[0, 30]
        and (select array_agg((s ->> 'end_min')::int order by (s ->> 'seq')::int) from jsonb_array_elements(cat7 -> 'timeline') s) = array[20, 120], 'A3: timeline[]: vain rituaali 0–20 ja savusauna 30–120 (tauko ei näy, ajat oikein)');
  perform public.t64_ck((cat7 ->> 'duration_minutes')::int = 120 and (select sum(minutes) from booking.product_timeline_segments where product_id = 7) = 120 and (select count(*) from booking.product_timeline_segments where product_id = 7 and not customer_visible) = 1, 'A4: kesto 120 min ja sisäinen tauko säilyy tietokannassa');
  perform public.t64_ck(cat7::text !~* 'tauko|break', 'A5: tuotteen 7 katalogirivissä ei sanaa tauko/break (kaikki kentät FI/EN)');
  perform public.t64_ck(cat7 ->> 'duration_text' = 'rituaali 20 min + savusauna 1 h 30 min (yhteensä 2 h)', 'A6: duration_text ilman taukoa: ' || coalesce(cat7 ->> 'duration_text', 'NULL'));
  perform public.t64_ck(not exists (select 1 from jsonb_array_elements(booking.public_get_site_texts() -> 'texts') x where x ->> 'text' ~* '\mtauko\M|\mbreak\M'), 'A7: public_get_site_texts: yksikään teksti (FI/EN) ei sisällä sanaa tauko/break');
  perform public.t64_ck(not exists (select 1 from booking.site_texts t where t.source_table = 'booking.product_timeline_segments' and t.source_pk in (select id::text from booking.product_timeline_segments where not customer_visible)), 'A8: sisäisen jakson tekstit eivät ole rekisterissä');
  perform public.t64_ck(not exists (select 1 from booking.site_texts t where t.class <> 'locked' and t.published_text ~* '\mtauko\M' and t.key not like 'timeline.%') , 'A9: ei muita asiakasnäkyviä tauko-mainintoja (kaikki site_texts)');
  perform public.t64_ck(jsonb_array_length(booking.admin_texts_drift() -> 'drift') = 0, 'A10: ei driftiä');
  -- muut tuotteet ennallaan (paitsi uudet avaimet)
  select bool_and((qn - 'addons_enabled' - 'allowed_addons') = qo) into ok
    from (select x qn, (select y from jsonb_array_elements(v_old) y where y -> 'id' = x -> 'id') qo from jsonb_array_elements(v_new) x where (x ->> 'id')::bigint <> 7) q;
  perform public.t64_ck(coalesce(ok, false) and jsonb_array_length(v_new) = jsonb_array_length(v_old), 'A11: muiden tuotteiden katalogirivit ennallaan + addons_enabled/allowed_addons');
  select (qc - 'addons_enabled' - 'allowed_addons' - 'timeline' - 'timeline_text' - 'timeline_text_en' - 'duration_text') = (qo - 'timeline' - 'timeline_text' - 'timeline_text_en' - 'duration_text') into ok
    from (select cat7 qc, (select y from jsonb_array_elements(v_old) y where (y ->> 'id')::bigint = 7) qo) q;
  perform public.t64_ck(coalesce(ok, false) and (cat7 ->> 'price')::numeric = 49, 'A12: tuote 7: hinta, kuvaus, EN, huomautus, henkilömäärät ennallaan');
  perform public.t64_ck((select md5(string_agg(id::text || ':' || coalesce(price::text, '') || ':' || coalesce(price_text, '') || ':' || coalesce(vat_rate::text, ''), '|' order by id)) from kb.products) = pre.prices, 'A13: hinnat, hintatekstit, ALV ennallaan');
  perform public.t64_ck((select duration_text from kb.products where id = 7) !~* 'tauko' and (select count(*) from booking.site_text_versions v join booking.site_texts t on t.id = v.text_id where t.key = 'product.7.duration_text' and v.version = 2 and v.status = 'published') = 1, 'A14: duration_text-muutos kirjautui versiohistoriaan');
  -- kaikki piilotettu -> aikajanaa ei näytetä; piilotuksen hallinta RPC:llä
  update booking.product_timeline_segments set customer_visible = false where product_id = 7;
  perform public.t64_ck(booking._timeline_json(7) is null, 'A15: ei näkyviä jaksoja -> aikajanaa ei näytetä');
  update booking.product_timeline_segments set customer_visible = true where product_id = 7 and kind <> 'break';
  perform public.t64_login(u_adm);
  o := public.t64_call($q$booking.admin_set_product_timeline(7, '[{"kind":"ritual","label":"rituaali","label_en":"ritual","minutes":20},{"kind":"break","label":"tauko","label_en":"break","minutes":10,"customer_visible":false},{"kind":"smoke_sauna","label":"savusauna","label_en":"smoke sauna","minutes":90}]'::jsonb)$q$);
  perform public.t64_logout();
  perform public.t64_ck((o ->> 'ok')::boolean and booking._timeline_json(7) ->> 'text' = 'rituaali 20 min · savusauna 1 h 30 min' and (select count(*) from booking.site_texts where key like 'timeline.%') = 4
        and not exists (select 1 from jsonb_array_elements(booking.public_get_site_texts() -> 'texts') x where x ->> 'text' ~* '\mtauko\M|\mbreak\M'), 'A16: admin_set_product_timeline tukee customer_visible=false; piilotettu jakso ei rekisterissä');

  -- ===== L: lisäpalvelut tuotekohtaisesti =====
  perform public.t64_ck(cat7 -> 'addons_enabled' = 'true'::jsonb and cat7 -> 'allowed_addons' = '["pyyhe"]'::jsonb, 'L1: tuote 7: addons_enabled=true, allowed_addons=["pyyhe"]');
  perform public.t64_ck(not exists (select 1 from jsonb_array_elements(v_new) x where (x ->> 'id')::bigint in (8, 10, 11, 12) and (x -> 'addons_enabled' <> 'false'::jsonb or x -> 'allowed_addons' <> '[]'::jsonb)), 'L2: muut slot-tuotteet (8, 10, 11, 12): lisäpalvelut ei käytössä');
  perform public.t64_ck(not exists (select 1 from jsonb_array_elements(v_new) x where jsonb_typeof(x -> 'allowed_addons') <> 'array' or jsonb_typeof(x -> 'addons_enabled') <> 'boolean'), 'L3: kaikilla tuotteilla addons_enabled boolean ja allowed_addons taulukko');
  perform public.t64_ck(exists (select 1 from jsonb_array_elements(v_new) x where x ->> 'booking_kind' = 'rules' and x -> 'addons_enabled' = 'true'::jsonb), 'L4: sääntöpohjaisilla tuotteilla lisäpalvelut johdetaan vuorosäännöistä (kuten ennen)');
  perform public.t64_anon();
  select count(*) into n from jsonb_array_elements(booking.public_catalog()) x where x ? 'allowed_addons';
  perform public.t64_logout();
  perform public.t64_ck(n = jsonb_array_length(v_new), 'L5: anon näkee kentät');
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
  r := public.t64_mk(public.t64_ts(w1, '16:00'), 2, 'l6@t64.example', '[{"code":"pyyhe","quantity":2}]'::jsonb);
  perform public.t64_ck((r ->> 'ok')::boolean and (r ->> 'total')::numeric = 108, 'L6: pyyhe x2 tuotteelle 7 onnistuu (108 €) ' || coalesce(r ->> 'code', ''));
  delete from booking.product_addon_allow where product_id = 7;
  n := (select count(*) from booking.orders);
  r := public.t64_mk(public.t64_ts(w1, '16:30'), 2, 'l7@t64.example', '[{"code":"pyyhe","quantity":1}]'::jsonb);
  perform public.t64_ck(not (r ->> 'ok')::boolean and r ->> 'code' = 'addon_not_allowed' and (select count(*) from booking.orders) = n, 'L7: ilman sallintaa pyyhe hylätään (addon_not_allowed), ei tilausta: ' || coalesce(r ->> 'code', 'ok'));
  perform public.t64_ck(booking._product_addon_codes(7) = '[]'::jsonb, 'L8: ilman sallintaa allowed_addons tyhjä');
  r := public.t64_mk(public.t64_ts(w1, '16:30'), 2, 'l9@t64.example', null);
  perform public.t64_ck((r ->> 'ok')::boolean and (r ->> 'total')::numeric = 98, 'L9: varaus ilman lisäpalveluja toimii (98 €) ' || coalesce(r ->> 'code', ''));
  insert into booking.product_addon_allow(product_id, addon_id) select 7, id from booking.addons where code = 'pyyhe';
  r := public.t64_mk(public.t64_ts(w1, '17:00'), 1, 'l10@t64.example', '[{"code":"turvenaamio_jalkakylpy","quantity":1}]'::jsonb);
  perform public.t64_ck(not (r ->> 'ok')::boolean and r ->> 'code' = 'addon_not_allowed', 'L10: turvenaamio edelleen hylätty: ' || coalesce(r ->> 'code', 'ok'));

  -- ===== I: tuonti needs_review =====
  perform public.t64_login(u_adm);
  o := public.t64_call($q$booking.admin_texts_import('[{"key":"ui.t64.a","lang":"fi","text":"Testi yksi"},{"key":"ui.t64.a","lang":"en","text":"Test one","needs_review":true,"review_note":"EN-luonnos"},{"key":"ui.t64.b","lang":"en","text":"Test two","needs_review":true}]'::jsonb)$q$);
  perform public.t64_logout();
  perform public.t64_ck((o ->> 'created')::int = 3 and (select needs_review and review_note = 'EN-luonnos' from booking.site_texts where key = 'ui.t64.a' and lang = 'en') and not (select needs_review from booking.site_texts where key = 'ui.t64.a' and lang = 'fi')
        and (select needs_review and review_note is not null from booking.site_texts where key = 'ui.t64.b'), 'I1: admin_texts_import tukee needs_review (+ review_note)');
  perform public.t64_login(u_otto);
  perform public.t64_ck(public.t64_try($q$select booking.admin_texts_import('[]'::jsonb)$q$) = 'forbidden', 'I2: Otto ei tuo (ennallaan)');
  perform public.t64_ck(jsonb_array_length(public.t64_call('booking.admin_texts_review_queue()') -> 'items') >= 2, 'I3: tuodut EN-tekstit review-jonossa');
  perform public.t64_logout();

  -- ===== M: admin_texts_list / admin_texts_versions =====
  perform public.t64_login(u_bot);
  perform public.t64_ck(public.t64_try($q$select booking.admin_texts_list()$q$) = 'forbidden' and public.t64_try($q$select booking.admin_texts_versions('ui.t64.a', 'fi')$q$) = 'forbidden', 'M1: botti ei käytä admin_texts_list/versions');
  o := public.t64_call($q$booking.texts_propose('ui.t64.a', 'fi', 'Testi yksi, selkeämpi', 'testi')$q$);
  perform public.t64_logout();
  perform public.t64_anon();
  perform public.t64_ck(public.t64_try($q$select booking.admin_texts_list()$q$) like '42501%', 'M2: anon ei käytä admin_texts_list');
  perform public.t64_logout();
  perform public.t64_login(u_otto);
  r := public.t64_call($q$booking.admin_texts_list(p_prefix => 'ui.t64.', p_limit => 10)$q$);
  perform public.t64_ck((r ->> 'total')::int = 3 and jsonb_array_length(r -> 'items') = 3 and (select (i ->> 'pending_count')::int from jsonb_array_elements(r -> 'items') i where i ->> 'key' = 'ui.t64.a' and i ->> 'lang' = 'fi') = 1, 'M3: admin_texts_list: avainprefiksi, total, pending_count');
  r := public.t64_call($q$booking.admin_texts_list(p_needs_review => true, p_prefix => 'ui.t64.')$q$);
  perform public.t64_ck((r ->> 'total')::int = 2, 'M4: suodatin needs_review');
  r := public.t64_call($q$booking.admin_texts_list(p_pending => true, p_q => 'yksi')$q$);
  perform public.t64_ck((r ->> 'total')::int >= 1 and not exists (select 1 from jsonb_array_elements(r -> 'items') i where (i ->> 'pending_count')::int = 0), 'M5: suodatin pending + haku (q)');
  r := public.t64_call($q$booking.admin_texts_list(p_class => 'locked', p_limit => 5)$q$);
  perform public.t64_ck((r ->> 'total')::int = (select count(*) from booking.site_texts where class = 'locked') and not exists (select 1 from jsonb_array_elements(r -> 'items') i where (i -> 'editable') <> 'false'::jsonb), 'M6: lukitut näkyvät, editable=false');
  r := public.t64_call($q$booking.admin_texts_list(p_lang => 'en', p_missing => true, p_limit => 500)$q$);
  perform public.t64_ck((r ->> 'total')::int = (select count(*) from booking.site_texts where lang = 'en' and published_text = '' and class <> 'locked'), 'M7: p_missing');
  r := public.t64_call($q$booking.admin_texts_versions('ui.t64.a', 'fi')$q$);
  perform public.t64_ck(jsonb_array_length(r -> 'versions') = 2 and r -> 'versions' -> 0 ->> 'status' = 'proposed' and r -> 'versions' -> 0 ->> 'proposed_by' = 'botti: t64 botti' and r -> 'versions' -> 1 ->> 'status' = 'published'
        and (r -> 'versions' -> 1 ->> 'is_current')::boolean and r -> 'text' ->> 'text' = 'Testi yksi', 'M8: admin_texts_versions: versiot uusimmat ensin, ehdottaja nimellä, nykyinen merkitty');
  perform public.t64_ck(public.t64_try($q$select booking.admin_texts_versions('ei.ole', 'fi')$q$) = 'not_found', 'M9: tuntematon avain -> not_found');
  perform public.t64_logout();
  -- ===== E: ennallaan =====
  perform public.t64_ck(jsonb_array_length(booking.admin_texts_drift() -> 'drift') = 0 and (select array_agg(permission) from booking.role_permissions where role_code = 'text_editor') = array['texts.propose'], 'E1: ei driftiä; botin oikeudet ennallaan (vain texts.propose)');
  log := current_setting('t64.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
exception when others then
  select count(*) into v_foreign from booking.orders where id > v_maxid;
  if v_foreign = 0 then perform setval('booking.orders_order_no_seq', v_seq0, true); end if;
  raise;
end $t$;
