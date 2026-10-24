-- t144: evästeetön kävijämittaus (booking_144, paketti 11).
-- Julkinen public_track_event: kenttien rajaus, botit, polut, UTM, tuotteen tunnistus katalogista, ostotapahtuma vain maksetulle tilaukselle
-- (summa ja tuote tietokannasta), tupla-ostoa ei synny. Hallinnan admin_analytics_summary: oikeudet, aikaväli, funnel ja osiot.
-- Kaikki data on feikkiä. Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN.
-- Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken. Tulos: TESTRESULT pass=… fail=…
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t144_r(ok boolean, label text) on commit drop;
grant all on t144_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t144_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.tr(p jsonb, p_ua text default null) returns jsonb language plpgsql as $$
declare j jsonb; begin perform test.anon();
  if p_ua is not null then perform set_config('request.headers', json_build_object('user-agent', p_ua)::text, true); end if;
  j := booking.public_track_event(p); perform test.logout(); return j; end $$;
do $t$
declare
  v_adm uuid := test.mk_staff('adm144@example.test', 'admin');
  v_staff uuid := test.mk_staff('staff144@example.test', 'staff');
  v_ed uuid := test.mk_user('asiakas144@example.test');
  s1 text := '11111111-1111-4111-8111-111111111111';
  s2 text := '22222222-2222-4222-9222-222222222222';
  s3 text := '33333333-3333-4333-a333-333333333333';
  v_today date := (now() at time zone 'Europe/Helsinki')::date;
  j jsonb; v_o bigint; v_tok uuid; v_n int; v_err text;
  v_price1 numeric := (select price from kb.products where id = 1);
begin
  -- ===== Tekniset =====
  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_track_event(jsonb)', 'execute'), 'T1: public_track_event anonille');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_analytics_summary(date,date)', 'execute')
    and has_function_privilege('authenticated', 'booking.admin_analytics_summary(date,date)', 'execute'), 'T2: raportti vain kirjautuneelle');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._analytics_source(text,text,text)', 'execute')
    and not has_function_privilege('authenticated', 'booking._analytics_source(text,text,text)', 'execute'), 'T3: luokittelija sisäinen');
  perform pg_temp.ck(not has_table_privilege('anon', 'booking.analytics_events', 'select')
    and not has_table_privilege('anon', 'booking.analytics_events', 'insert')
    and not has_table_privilege('authenticated', 'booking.analytics_events', 'select'), 'T4: taulu ei suoraan anon/authenticated');
  perform pg_temp.ck((select relrowsecurity from pg_class where oid = 'booking.analytics_events'::regclass), 'T5: RLS päällä');
  perform pg_temp.ck((select bool_and(prosecdef and proconfig @> array['search_path=""']) from pg_proc
    where pronamespace = 'booking'::regnamespace and proname in ('public_track_event', 'admin_analytics_summary')), 'T6: security definer, search_path tyhjä');
  perform pg_temp.ck(not exists (select 1 from information_schema.columns where table_schema = 'booking' and table_name = 'analytics_events'
    and column_name ~ '(ip|user_agent|email|name|phone)'), 'T7: ei IP/UA/henkilötietosarakkeita');
  perform pg_temp.ck((select count(*) from booking.analytics_events) = 0, 'T8: migraatio ei luo tapahtumia');

  -- ===== Luokittelu =====
  perform pg_temp.ck(booking._analytics_source('www.google.fi', null, null) = 'google_search'
    and booking._analytics_source('maps.google.com', null, null) = 'google_maps'
    and booking._analytics_source('l.instagram.com', null, null) = 'social'
    and booking._analytics_source('www.google.fi', null, 'syysloma') = 'campaign'
    and booking._analytics_source(null, null, null) = 'direct'
    and booking._analytics_source('joonasvaarala.github.io', null, null) = 'direct'
    and booking._analytics_source('visitfinland.com', null, null) = 'referral', 'C1: liikennelähteet');

  -- ===== Validointi =====
  perform pg_temp.ck(pg_temp.tr(jsonb_build_object('session_key', s1, 'event_type', 'page_view', 'path', '/', 'email', 'x@example.test')) ->> 'code' = 'invalid_field', 'V1: ylimääräinen kenttä hylätään');
  perform pg_temp.ck(pg_temp.tr(jsonb_build_object('session_key', 'abc', 'event_type', 'page_view', 'path', '/')) ->> 'code' = 'invalid_event', 'V2: virheellinen session_key');
  perform pg_temp.ck(pg_temp.tr(jsonb_build_object('session_key', s1, 'event_type', 'click', 'path', '/')) ->> 'code' = 'invalid_event', 'V3: tuntematon tapahtuma');
  perform pg_temp.ck(pg_temp.tr(jsonb_build_object('session_key', s1, 'event_type', 'page_view', 'path', '/hallinta/')) ->> 'code' = 'invalid_path', 'V4: hallinta ei mitattava');
  -- booking_150 normalisoi polun (query pois, tuntematon -> /muu): ks. t150 N1–N3. Tämä tarkistus pätee kumpaankin versioon.
  perform pg_temp.ck(pg_temp.tr(jsonb_build_object('session_key', s1, 'event_type', 'page_view', 'path', '/hallinta/?email=x')) ->> 'code' = 'invalid_path', 'V5: kysely ei tee hallinnasta mitattavaa');
  perform pg_temp.ck(pg_temp.tr(jsonb_build_object('session_key', s1, 'event_type', 'page_view', 'path', '/', 'utm_campaign', 'Kampanja <x>')) ->> 'code' = 'invalid_utm', 'V6: UTM rajattu');
  perform pg_temp.ck(pg_temp.tr(jsonb_build_object('session_key', s1, 'event_type', 'page_view', 'path', '/', 'referrer_domain', 'a@b.fi')) ->> 'code' = 'invalid_referrer', 'V7: referrer rajattu');
  perform pg_temp.ck(pg_temp.tr(jsonb_build_object('session_key', s1, 'event_type', 'page_view', 'path', '/', 'bot', 'true')) ->> 'code' = 'bot'
    and pg_temp.tr(jsonb_build_object('session_key', s1, 'event_type', 'page_view', 'path', '/'), 'Mozilla/5.0 HeadlessChrome Playwright') ->> 'code' = 'bot', 'V8: botit ohitetaan');
  perform pg_temp.ck(pg_temp.tr(jsonb_build_object('session_key', s1, 'event_type', 'product_view', 'path', '/varaa/', 'product_slug', 'Ei Kelpaa')) ->> 'code' = 'invalid_slug', 'V9: slug rajattu');
  perform pg_temp.ck((select count(*) from booking.analytics_events) = 0, 'V10: hylätyt eivät tallennu');

  -- ===== Tallennus =====
  j := pg_temp.tr(jsonb_build_object('session_key', s1, 'event_type', 'page_view', 'path', '/', 'locale', 'fi', 'device_type', 'mobile', 'referrer_domain', 'www.google.fi'));
  perform pg_temp.ck((j ->> 'ok')::boolean and (select source_category from booking.analytics_events where session_key = s1 and event_type = 'page_view') = 'google_search', 'S1: sivunäyttö + lähde palvelimella');
  j := pg_temp.tr(jsonb_build_object('session_key', s1, 'event_type', 'product_view', 'path', '/varaa/', 'product_slug', 'yleinensauna'));
  perform pg_temp.ck((select product_id from booking.analytics_events where session_key = s1 and event_type = 'product_view') = 1, 'S2: tuote katalogista slugilla');
  j := pg_temp.tr(jsonb_build_object('session_key', s1, 'event_type', 'product_view', 'path', '/varaa/', 'product_slug', 'ei-olemassa'));
  perform pg_temp.ck((select count(*) from booking.analytics_events where session_key = s1 and event_type = 'product_view' and product_id is null and product_slug is null) = 1, 'S3: tuntematon slug ei tallennu tuotteeksi');
  j := pg_temp.tr(jsonb_build_object('session_key', s1, 'event_type', 'checkout_start', 'path', '/varaa/', 'product_id', 1));
  j := pg_temp.tr(jsonb_build_object('session_key', s2, 'event_type', 'page_view', 'path', '/en/', 'locale', 'en', 'device_type', 'desktop', 'utm_source', 'newsletter', 'utm_campaign', 'lokakuu'));
  perform pg_temp.ck((select source_category = 'campaign' and utm_campaign = 'lokakuu' from booking.analytics_events where session_key = s2), 'S4: kampanja');
  j := pg_temp.tr(jsonb_build_object('session_key', s3, 'event_type', 'page_view', 'path', '/lahjakortti/'));
  j := pg_temp.tr(jsonb_build_object('session_key', s3, 'event_type', 'product_view', 'path', '/lahjakortti/'));
  perform pg_temp.ck((select product_id from booking.analytics_events where session_key = s3 and event_type = 'product_view') = 38, 'S5: lahjakorttisivu -> lahjakorttituote');

  -- ===== Osto =====
  j := test.pub_book(1, test.next_dow(1, 3), 1, 'osto144@example.test');   -- sääntö 1 = Miesten sauna (tuote 2)
  v_tok := (j ->> 'token')::uuid; v_o := (select id from booking.orders where public_token = v_tok);
  perform pg_temp.ck(v_o is not null, 'P0: testitilaus syntyi');
  j := pg_temp.tr(jsonb_build_object('session_key', s1, 'event_type', 'purchase', 'path', '/tilaus/', 'order_token', v_tok));
  perform pg_temp.ck(j ->> 'code' = 'not_paid' and not exists (select 1 from booking.analytics_events where event_type = 'purchase'), 'P1: maksamaton ei ole osto');
  update booking.orders set payment_status = 'paid' where id = v_o;
  j := pg_temp.tr(jsonb_build_object('session_key', s1, 'event_type', 'purchase', 'path', '/tilaus/', 'order_token', v_tok, 'product_id', 38));
  perform pg_temp.ck((j ->> 'ok')::boolean and (select order_id = v_o and amount_gross = (select total_gross from booking.orders where id = v_o) and product_id = 2
    from booking.analytics_events where event_type = 'purchase'), 'P2: summa ja tuote tietokannasta, ei selaimelta');
  j := pg_temp.tr(jsonb_build_object('session_key', s2, 'event_type', 'purchase', 'path', '/tilaus/', 'order_token', v_tok));
  perform pg_temp.ck((select count(*) from booking.analytics_events where event_type = 'purchase') = 1, 'P3: sama tilaus vain kerran');
  perform pg_temp.ck(pg_temp.tr(jsonb_build_object('session_key', s1, 'event_type', 'purchase', 'path', '/tilaus/', 'order_token', 'ei-uuid')) ->> 'code' = 'invalid_order', 'P4: virheellinen token');
  perform pg_temp.ck((select price from kb.products where id = 1) = v_price1, 'P5: hinnat ennallaan');

  -- ===== Raportti =====
  perform test.login(v_ed);
  begin perform booking.admin_analytics_summary(v_today, v_today); v_err := 'NO ERROR';
  exception when others then v_err := sqlerrm; end;
  perform test.logout();
  perform pg_temp.ck(v_err <> 'NO ERROR', 'R1: ei-henkilökunta ei näe raporttia (' || v_err || ')');
  perform test.login(v_staff);
  begin perform booking.admin_analytics_summary(v_today, v_today + 400); v_err := 'NO ERROR';
  exception when others then v_err := sqlerrm; end;
  perform pg_temp.ck(v_err <> 'NO ERROR', 'R2: yli 367 päivää hylätään');
  j := booking.admin_analytics_summary(v_today - 6, v_today);
  perform test.logout();
  perform pg_temp.ck((j -> 'funnel' ->> 'visitors')::int = 3 and (j -> 'funnel' ->> 'product_viewers')::int = 2
    and (j -> 'funnel' ->> 'checkout_starters')::int = 1 and (j -> 'funnel' ->> 'buyers')::int = 1
    and (j -> 'funnel' ->> 'paid_orders')::int = 1, 'R3: funnel (staff, reports.daily)');
  perform pg_temp.ck(jsonb_array_length(j -> 'sources') = 3
    and (select (x ->> 'purchases')::int from jsonb_array_elements(j -> 'sources') x where x ->> 'source_category' = 'google_search') = 1
    and (select x ->> 'top_utm_campaign' from jsonb_array_elements(j -> 'sources') x where x ->> 'source_category' = 'campaign') = 'lokakuu', 'R4: lähteet');
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(j -> 'top_products') x where (x ->> 'product_id')::int = 1 and (x ->> 'views')::int = 1 and (x ->> 'checkouts')::int = 1)
    and exists (select 1 from jsonb_array_elements(j -> 'top_products') x where (x ->> 'product_id')::int = 2 and (x ->> 'purchases')::int = 1), 'R5: tuotteet (osto tilausriviltä: sääntö 1 = tuote 2)');
  perform pg_temp.ck(jsonb_array_length(j -> 'devices_and_locales' -> 'devices') = 2 and jsonb_array_length(j -> 'devices_and_locales' -> 'locales') = 2, 'R6: laitteet ja kielet');
  perform pg_temp.ck(jsonb_array_length(j -> 'daily_series') = 7, 'R7: päiväsarja 7 pv');
  perform test.login(v_adm);
  j := booking.admin_analytics_summary(v_today + 1, v_today + 1);
  perform test.logout();
  perform pg_temp.ck((j -> 'funnel' ->> 'visitors')::int = 0 and jsonb_array_length(j -> 'sources') = 0, 'R8: tyhjä jakso');

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t144_r where ok), (select count(*) from t144_r where not ok),
    coalesce((select string_agg(label, ' | ') from t144_r where not ok), 'ALL OK');
end $t$;
