-- t150: kävijämittauksen kovennus (booking_150).
-- IP-kohtainen raja ja yhteinen IP:ttömien raja (_rate_limit), globaali päiväkatto (hiljainen ohitus), polun normalisointi tunnettuihin
-- sivupolkuihin, UTM-hylkäys (numerojonot, sähköpostit, pituus), palvelinpuolen lähdekategoria, admin_analytics_summary samat luvut kuin
-- booking_144:n määrittelyllä (kopio alla pg_temp.summary144), säilytysajan siivous ja pg_cron-ajo.
-- Kaikki data on feikkiä. Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN. Yksi DO-lohko; tulos: TESTRESULT pass=… fail=…
set local lock_timeout = '3s';
set local statement_timeout = '120s';
create temp table t150_r(ok boolean, label text) on commit drop;
grant all on t150_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t150_r values (coalesce(p_ok, false), p_label) $$;
-- p_ip null = ei IP-otsaketta
create function pg_temp.tr(p jsonb, p_ip text default null) returns jsonb language plpgsql as $$
declare j jsonb; begin perform test.anon(p_ip); j := booking.public_track_event(p); perform test.logout(); return j; end $$;
create function pg_temp.sk(i int) returns text language sql immutable as $$
  select lpad(to_hex(i), 8, '0') || '-0000-4000-8000-' || lpad(to_hex(i), 12, '0') $$;
create function pg_temp.pv(i int, p_path text default '/', p_extra jsonb default '{}'::jsonb) returns jsonb language sql immutable as $$
  select jsonb_build_object('session_key', pg_temp.sk(i), 'event_type', 'page_view', 'path', p_path) || p_extra $$;
create function pg_temp.set(k text, v jsonb) returns void language sql as $$ update booking.settings set value = v where key = k $$;
create function pg_temp.reset() returns void language sql as $$
  delete from booking.rate_limit_hits where bucket like 'analytics:%'; delete from booking.analytics_daily_counts; delete from booking.analytics_events $$;
-- booking_144:n admin_analytics_summary sellaisenaan (vertailua varten)
create function pg_temp.summary144(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  perform booking._require_staff();
  if not (booking.has_permission('reports.view') or booking.has_permission('reports.daily')) then
    perform booking._err('forbidden','Raporttien tarkasteluoikeus puuttuu');
  end if;
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 366 then
    perform booking._err('invalid_range','Aikaväli saa olla enintään 367 päivää');
  end if;
  with e as materialized (
    select * from booking.analytics_events where event_date between p_from and p_to
  ), f as (
    select count(distinct session_key) filter(where event_type='page_view')::int visitors,
           count(distinct session_key) filter(where event_type='product_view')::int product_viewers,
           count(distinct session_key) filter(where event_type='checkout_start')::int checkout_starters,
           count(distinct session_key) filter(where event_type='purchase')::int buyers,
           count(*) filter(where event_type='page_view')::int page_view_events,
           count(*) filter(where event_type='product_view')::int product_view_events,
           count(*) filter(where event_type='checkout_start')::int checkout_events,
           count(*) filter(where event_type='purchase')::int purchase_events
    from e
  ), paid as (
    select count(*)::int orders,coalesce(sum(amount_gross),0)::numeric(12,2) gross from
       (select distinct on(order_id) order_id,amount_gross from e where event_type='purchase' and order_id is not null order by order_id,created_at desc) p
  ), visits as (
    select distinct on (session_key) session_key,source_category,utm_campaign,referrer_domain,device_type,locale
       from e where event_type='page_view' order by session_key,created_at,id
  ), buyer_sessions as (
    select distinct session_key from e where event_type='purchase'
  ), checkout_sessions as (
    select distinct session_key from e where event_type='checkout_start'
  ), sources as (
    select v.source_category, count(*)::int visits,
           count(c.session_key)::int checkouts,count(b.session_key)::int purchases,
           round(100.0*count(b.session_key)/nullif(count(*),0),2) conversion_pct
       from visits v left join checkout_sessions c using(session_key) left join buyer_sessions b using(session_key)
       group by v.source_category
  ), top_campaign as (
     select source_category,utm_campaign,count(*)::int n from visits where utm_campaign is not null group by 1,2
  ), top_ref as (
     select source_category,referrer_domain,count(*)::int n from visits where referrer_domain is not null group by 1,2
  ), products as (
    select coalesce(e.product_id,-1) product_id,e.product_slug,
      count(*) filter (where e.event_type='product_view')::int views,
      count(*) filter (where e.event_type='checkout_start')::int checkouts,
      count(*) filter (where e.event_type='purchase')::int purchases
    from e where e.product_id is not null or e.product_slug is not null group by coalesce(e.product_id,-1),e.product_slug
  ), devices as (
     select device_type,count(*)::int visits,count(b.session_key)::int purchases from visits v left join buyer_sessions b using(session_key) group by device_type
  ), locales as (
     select locale,count(*)::int visits,count(b.session_key)::int purchases from visits v left join buyer_sessions b using(session_key) group by locale
  ), days as (
     select d::date as d_day from generate_series(p_from,p_to,interval '1 day') d
  )
  select jsonb_build_object(
    'from',p_from,'to',p_to,
    'funnel', (select to_jsonb(f) || jsonb_build_object('paid_orders',paid.orders,'amount_gross',paid.gross,'conversion_pct',coalesce(round(100.0*f.buyers/nullif(f.visitors,0),2),0)) from f cross join paid),
    'sources',coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object(
       'top_utm_campaign',(select t.utm_campaign from top_campaign t where t.source_category=s.source_category order by n desc,utm_campaign limit 1),
       'top_referrer_domain',(select t.referrer_domain from top_ref t where t.source_category=s.source_category order by n desc,referrer_domain limit 1)) order by s.visits desc) from sources s),'[]'::jsonb),
    'top_products',coalesce((select jsonb_agg(jsonb_build_object('product_id',nullif(p.product_id,-1),'product_slug',p.product_slug,'name',coalesce(k.name,p.product_slug,'Tuntematon tuote'),
      'views',p.views,'checkouts',p.checkouts,'purchases',p.purchases,
      'conversion_pct',coalesce(round(p.purchases*100.0/nullif(p.views,0),2),0)) order by p.views desc)
      from products p left join kb.products k on k.id=p.product_id or (p.product_id=-1 and k.slug=p.product_slug)),'[]'::jsonb),
    'devices_and_locales',jsonb_build_object(
       'devices',coalesce((select jsonb_agg(to_jsonb(d) order by visits desc) from devices d),'[]'::jsonb),
       'locales',coalesce((select jsonb_agg(to_jsonb(l) order by visits desc) from locales l),'[]'::jsonb)),
    'daily_series',coalesce((select jsonb_agg(jsonb_build_object('date',d_day,
       'visitors',(select count(distinct session_key) from e where event_date=d_day and event_type='page_view'),
       'product_views',(select count(*) from e where event_date=d_day and event_type='product_view'),
       'checkouts',(select count(*) from e where event_date=d_day and event_type='checkout_start'),
       'purchases',(select count(*) from e where event_date=d_day and event_type='purchase')) order by d_day) from days),'[]'::jsonb)
  ) into result;
  return result;
end $$;

do $t$
declare
  v_staff uuid := test.mk_staff('staff150@example.test', 'staff');
  v_today date := (now() at time zone 'Europe/Helsinki')::date;
  j jsonb; j2 jsonb; v_n int; v_ok boolean; v_tok uuid; v_o bigint; i int; r record;
begin
  perform pg_temp.reset();
  -- ===== Tekniset =====
  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_track_event(jsonb)', 'execute'), 'T1: public_track_event yhä anonille');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.analytics_cleanup()', 'execute')
    and not has_function_privilege('authenticated', 'booking.analytics_cleanup()', 'execute')
    and not has_function_privilege('anon', 'booking._analytics_path(text)', 'execute')
    and not has_function_privilege('anon', 'booking._analytics_utm_ok(text,integer)', 'execute'), 'T2: apufunktiot sisäisiä');
  perform pg_temp.ck(not has_table_privilege('anon', 'booking.analytics_daily_counts', 'select')
    and not has_table_privilege('authenticated', 'booking.analytics_daily_counts', 'insert')
    and (select relrowsecurity from pg_class where oid = 'booking.analytics_daily_counts'::regclass), 'T3: päivälaskuri ei suoraan anon/authenticated, RLS');
  perform pg_temp.ck((select count(*) from booking.settings where key in ('analytics_rl_ip_per_10min','analytics_rl_noip_per_10min','analytics_daily_cap','analytics_retention_months')) = 4, 'T4: asetukset');
  perform pg_temp.ck((select count(*) from cron.job where jobname = 'booking_analytics_cleanup' and command = 'select booking.analytics_cleanup()') = 1, 'T5: pg_cron-ajo kerran');
  perform pg_temp.ck(exists (select 1 from pg_indexes where schemaname = 'booking' and indexname = 'analytics_events_date_type_session_idx'), 'T6: päiväkoosteen indeksi');

  -- ===== 1) Rate limit =====
  perform pg_temp.set('analytics_rl_ip_per_10min', '5'::jsonb);
  for i in 1..5 loop j := pg_temp.tr(pg_temp.pv(100 + i), '203.0.113.7'); end loop;
  perform pg_temp.ck((j ->> 'ok')::boolean, 'L1: IP-raja sallii 5');
  j := pg_temp.tr(pg_temp.pv(200), '203.0.113.7');
  perform pg_temp.ck(j ->> 'code' = 'rate_limited' and (select count(*) from booking.analytics_events) = 5, 'L2: 6. tapahtuma samasta IP:stä torjutaan, vaikka session-avain vaihtuu');
  j := pg_temp.tr(pg_temp.pv(201), '203.0.113.7, 10.0.0.1');
  perform pg_temp.ck(j ->> 'code' = 'rate_limited', 'L3: x-forwarded-for-ketjun ensimmäinen osoite ratkaisee');
  j := pg_temp.tr(pg_temp.pv(202), '198.51.100.9');
  perform pg_temp.ck((j ->> 'ok')::boolean, 'L4: toinen IP saa oman kiintiön');
  perform pg_temp.ck(not exists (select 1 from booking.rate_limit_hits where bucket like '%203.0.113.7%' or bucket like '%198.51.100.9%')
    and exists (select 1 from booking.rate_limit_hits where bucket ~ '^analytics:ip:[0-9a-f]{32}$'), 'L5: IP vain tiivisteenä rate_limit_hits-ämpärissä');
  perform pg_temp.set('analytics_rl_noip_per_10min', '3'::jsonb);
  for i in 1..3 loop j := pg_temp.tr(pg_temp.pv(300 + i)); end loop;
  j2 := pg_temp.tr(pg_temp.pv(310));
  perform pg_temp.ck((j ->> 'ok')::boolean and j2 ->> 'code' = 'rate_limited', 'L6: ilman IP:tä yhteinen tiukempi raja');
  perform pg_temp.ck((select count(*) from booking.rate_limit_hits where bucket = 'analytics:noip') = 4, 'L7: torjuttukin kirjataan (_rate_limit)');
  j := pg_temp.tr(jsonb_build_object('session_key', 'x', 'event_type', 'page_view', 'path', '/'), '198.51.100.9');
  perform pg_temp.ck((select count(*) from booking.rate_limit_hits where bucket like 'analytics:ip:%') = 9, 'L8: virheellinenkin kutsu kuluttaa kiintiötä');
  perform pg_temp.set('analytics_rl_ip_per_10min', '120'::jsonb); perform pg_temp.set('analytics_rl_noip_per_10min', '60'::jsonb);

  -- ===== 1b) Päiväkatto =====
  perform pg_temp.reset();
  perform pg_temp.set('analytics_daily_cap', '3'::jsonb);
  for i in 1..5 loop j := pg_temp.tr(pg_temp.pv(400 + i), '192.0.2.' || i); end loop;
  perform pg_temp.ck(j = '{"ok":true}'::jsonb and (select count(*) from booking.analytics_events) = 3, 'K1: katon ylitys ohitetaan hiljaa (sama vastaus, ei tallennu)');
  perform pg_temp.ck((select n from booking.analytics_daily_counts where event_date = v_today) = 5, 'K2: päivälaskuri');
  j := test.pub_book(1, test.next_dow(1, 3), 1, 'osto150@example.test');
  v_tok := (j ->> 'token')::uuid; v_o := (select id from booking.orders where public_token = v_tok);
  update booking.orders set payment_status = 'paid' where id = v_o;
  j := pg_temp.tr(jsonb_build_object('session_key', pg_temp.sk(401), 'event_type', 'purchase', 'path', '/tilaus/?t=' || v_tok, 'order_token', v_tok), '192.0.2.1');
  perform pg_temp.ck((j ->> 'ok')::boolean and exists (select 1 from booking.analytics_events where event_type = 'purchase' and order_id = v_o and path = '/tilaus/'),
    'K3: maksettu osto tallentuu katosta huolimatta, token ei polussa');
  perform pg_temp.set('analytics_daily_cap', '20000'::jsonb);

  -- ===== 3) Polku ja UTM =====
  perform pg_temp.reset();
  insert into booking.articles(status, published_at, slug_fi, slug_en, title_fi) values ('published', now() - interval '1 day', 'testi-artikkeli-150', 'test-article-150', 'Testi');
  insert into booking.articles(status, slug_fi, title_fi) values ('draft', 'luonnos-artikkeli-150', 'Luonnos');
  perform pg_temp.ck(booking._analytics_path('/matti-meikalainen-0401234567') = '/muu'
    and booking._analytics_path('/info/?email=matti@example.fi#x') = '/info/'
    and booking._analytics_path('/info') = '/info/'
    and booking._analytics_path('/EN//Book/') = '/en/book/'
    and booking._analytics_path('/index.html') = '/'
    and booking._analytics_path('/tilaus/?t=11111111-1111-4111-8111-111111111111') = '/tilaus/'
    and booking._analytics_path('/saunatietoa/testi-artikkeli-150/') = '/saunatietoa/testi-artikkeli-150/'
    and booking._analytics_path('/en/sauna-knowledge/test-article-150/') = '/en/sauna-knowledge/test-article-150/'
    and booking._analytics_path('/saunatietoa/luonnos-artikkeli-150/') = '/muu'
    and booking._analytics_path('/saunatietoa/matti-meikalainen/') = '/muu'
    and booking._analytics_path('/saunatietoa/tagi/loyly/') = '/saunatietoa/tagi/'
    and booking._analytics_path('/en/sauna-knowledge/tag/sauna/page/2/') = '/en/sauna-knowledge/tag/'
    and booking._analytics_path('/saunatietoa/sivu/2/') = '/saunatietoa/'
    and booking._analytics_path('varaa') = '/muu'
    and booking._analytics_path(null) = '/muu'
    and booking._analytics_path('/hallinta/') is null, 'N1: polun normalisointi');
  j := pg_temp.tr(pg_temp.pv(500, '/matti-meikalainen-0401234567'), '192.0.2.50');
  perform pg_temp.ck((j ->> 'ok')::boolean and (select path from booking.analytics_events where session_key = pg_temp.sk(500)) = '/muu', 'N2: henkilötietopolku tallentuu muotoon /muu');
  j := pg_temp.tr(pg_temp.pv(501, '/lahjakortti/?email=x@y.fi'), '192.0.2.50');
  perform pg_temp.ck((select path from booking.analytics_events where session_key = pg_temp.sk(501)) = '/lahjakortti/', 'N3: query pois');
  perform pg_temp.ck(pg_temp.tr(pg_temp.pv(502, '/hallinta/varaukset'), '192.0.2.50') ->> 'code' = 'invalid_path', 'N4: hallinta ei mitattava');
  perform pg_temp.ck(pg_temp.tr(pg_temp.pv(503, '/', '{"utm_campaign":"kampanja-0401234567"}'), '192.0.2.50') ->> 'code' = 'invalid_utm'
    and pg_temp.tr(pg_temp.pv(503, '/', '{"utm_source":"matti@example.fi"}'), '192.0.2.50') ->> 'code' = 'invalid_utm'
    and pg_temp.tr(pg_temp.pv(503, '/', '{"utm_campaign":"matti.meikalainen@example.fi"}'), '192.0.2.50') ->> 'code' = 'invalid_utm'
    and pg_temp.tr(pg_temp.pv(503, '/', '{"utm_medium":"abc12345"}'), '192.0.2.50') ->> 'code' = 'invalid_utm'
    and pg_temp.tr(pg_temp.pv(503, '/', '{"utm_campaign":"040-123-45-67"}'), '192.0.2.50') ->> 'code' = 'invalid_utm'
    and pg_temp.tr(pg_temp.pv(503, '/', jsonb_build_object('utm_campaign', repeat('a', 61))), '192.0.2.50') ->> 'code' = 'invalid_utm'
    and pg_temp.tr(pg_temp.pv(503, '/', jsonb_build_object('utm_source', repeat('a', 41))), '192.0.2.50') ->> 'code' = 'invalid_utm'
    and pg_temp.tr(pg_temp.pv(503, '/', '{"utm_campaign":"_x"}'), '192.0.2.50') ->> 'code' = 'invalid_utm'
    and pg_temp.tr(pg_temp.pv(503, '/', '{"utm_campaign":"Kampanja <x>"}'), '192.0.2.50') ->> 'code' = 'invalid_utm', 'U1: UTM-hylkäys (numerojonot, sähköpostit, @, pituus, merkit)');
  perform pg_temp.ck(not exists (select 1 from booking.analytics_events where session_key = pg_temp.sk(503)), 'U2: hylätyt eivät tallennu');
  j := pg_temp.tr(pg_temp.pv(504, '/', jsonb_build_object('utm_source', 'Newsletter', 'utm_medium', 'email', 'utm_campaign', 'black-friday-2026')), '192.0.2.50');
  perform pg_temp.ck((select utm_source = 'newsletter' and utm_campaign = 'black-friday-2026' from booking.analytics_events where session_key = pg_temp.sk(504)), 'U3: kelvollinen kampanja tallentuu pienaakkosin');
  j := pg_temp.tr(pg_temp.pv(505, '/', jsonb_build_object('utm_campaign', repeat('b', 60), 'utm_source', repeat('c', 40))), '192.0.2.50');
  perform pg_temp.ck((j ->> 'ok')::boolean, 'U4: rajapituudet sallitaan');

  -- ===== 4) Lähde palvelimella =====
  j := pg_temp.tr(pg_temp.pv(600, '/', '{"source_category":"google_search"}'), '192.0.2.60');
  j := pg_temp.tr(pg_temp.pv(601, '/', '{"source_category":"direct","referrer_domain":"www.google.fi"}'), '192.0.2.60');
  j := pg_temp.tr(pg_temp.pv(602, '/', '{"source_category":"social","utm_source":"uutiskirje"}'), '192.0.2.60');
  j := pg_temp.tr(pg_temp.pv(603, '/', '{"source_category":"keksitty"}'), '192.0.2.60');
  perform pg_temp.ck((select source_category from booking.analytics_events where session_key = pg_temp.sk(600)) = 'direct'
    and (select source_category from booking.analytics_events where session_key = pg_temp.sk(601)) = 'google_search'
    and (select source_category from booking.analytics_events where session_key = pg_temp.sk(602)) = 'campaign'
    and (j ->> 'ok')::boolean and (select source_category from booking.analytics_events where session_key = pg_temp.sk(603)) = 'direct',
    'S1: asiakkaan source_category ohitetaan, lähde referreristä/UTM:stä');

  -- ===== 5) Raportti: samat luvut kuin booking_144 =====
  delete from booking.analytics_events;
  insert into booking.analytics_events(created_at, event_date, session_key, event_type, path, locale, device_type, source_category, referrer_domain, utm_campaign, product_id, product_slug)
  select now() - (g % 40) * interval '1 day' + (g % 97) * interval '1 minute',
         v_today - (g % 40),
         pg_temp.sk(1000 + (g % 180)),
         (array['page_view','page_view','page_view','product_view','checkout_start'])[1 + g % 5],
         '/', (array['fi','en'])[1 + g % 2], (array['mobile','desktop','tablet'])[1 + g % 3],
         (array['direct','google_search','social','campaign','referral','google_maps'])[1 + g % 6],
         case when g % 6 in (1,2,4) then 'ref' || (g % 4) || '.example.test' end,
         case when g % 6 = 3 then 'kampanja-' || (g % 3) end,
         case when g % 5 in (3,4) then 1 + g % 3 end, null
    from generate_series(1, 2500) g;
  insert into booking.analytics_events(created_at, event_date, session_key, event_type, path, source_category, order_id, amount_gross, product_id)
  values (now() - interval '3 days', v_today - 3, pg_temp.sk(1005), 'purchase', '/tilaus/', 'direct', v_o, 59.00, 2),
         (now() - interval '9 days', v_today - 9, pg_temp.sk(1011), 'purchase', '/tilaus/', 'direct', null, 29.00, 1);
  perform test.login(v_staff);
  v_ok := true;
  for r in select * from (values (v_today - 6, v_today), (v_today - 29, v_today), (v_today - 45, v_today + 2), (v_today - 366, v_today), (v_today + 1, v_today + 3)) x(f, t) loop
    j := booking.admin_analytics_summary(r.f, r.t);
    j2 := pg_temp.summary144(r.f, r.t);
    if j is distinct from j2 then v_ok := false; raise notice 'FAIL summary % - %', r.f, r.t; end if;
  end loop;
  perform test.logout();
  perform pg_temp.ck(v_ok and (j2 -> 'funnel' ->> 'visitors')::int = 0, 'R1: admin_analytics_summary täsmälleen sama kuin booking_144:n määrittely (5 aikaväliä)');
  perform test.login(v_staff);
  j := booking.admin_analytics_summary(v_today - 29, v_today);
  perform test.logout();
  perform pg_temp.ck(jsonb_array_length(j -> 'daily_series') = 30 and (j -> 'funnel' ->> 'visitors')::int > 0
    and (select sum((x ->> 'product_views')::int) from jsonb_array_elements(j -> 'daily_series') x) = (j -> 'funnel' ->> 'product_view_events')::int, 'R2: päiväsarja ja funnel täsmäävät');

  -- ===== 2) Säilytysaika ja siivous =====
  delete from booking.analytics_events;
  insert into booking.analytics_events(event_date, session_key, event_type, path) values
    ((v_today - interval '13 months')::date - 1, pg_temp.sk(700), 'page_view', '/'),
    ((v_today - interval '13 months')::date, pg_temp.sk(701), 'page_view', '/'),
    ((v_today - interval '12 months')::date, pg_temp.sk(702), 'page_view', '/'),
    (v_today, pg_temp.sk(703), 'page_view', '/');
  insert into booking.analytics_daily_counts values (v_today - 5, 10), (v_today - 1, 3) on conflict (event_date) do nothing;
  v_n := booking.analytics_cleanup();
  perform pg_temp.ck(v_n = 1 and not exists (select 1 from booking.analytics_events where session_key = pg_temp.sk(700))
    and (select count(*) from booking.analytics_events) = 3, 'C1: yli 13 kk vanhat poistetaan, 13 kk raja säilyy');
  perform pg_temp.ck(not exists (select 1 from booking.analytics_daily_counts where event_date = v_today - 5)
    and exists (select 1 from booking.analytics_daily_counts where event_date = v_today - 1), 'C2: vanhat päivälaskurit pois');
  perform pg_temp.set('analytics_retention_months', '6'::jsonb);
  v_n := booking.analytics_cleanup();
  perform pg_temp.ck(v_n = 2 and (select count(*) from booking.analytics_events) = 1, 'C3: säilytysaika asetuksesta');
  perform pg_temp.set('analytics_retention_months', '"x"'::jsonb);
  v_n := booking.analytics_cleanup();
  perform pg_temp.ck(v_n = 0 and (select count(*) from booking.analytics_events) = 1, 'C4: virheellinen asetus -> 13 kk oletus, ei kaadu');

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t150_r where ok), (select count(*) from t150_r where not ok),
    coalesce((select string_agg(label, ' | ') from t150_r where not ok), 'ALL OK');
end $t$;
