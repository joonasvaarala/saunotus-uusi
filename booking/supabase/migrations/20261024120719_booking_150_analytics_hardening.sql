-- booking_150: kävijämittauksen (booking_144) kovennus ennen päälle kytkemistä. Mittaus pysyy pois päältä (SITE_ANALYTICS ei muutu).
-- Rollback: rollbacks/20261024120719_booking_150_ROLLBACK.sql (palauttaa booking_144:n määritelmät täsmälleen).
-- 1) Tulvimisen esto public_track_event-funktiossa:
--    * IP-kohtainen raja olemassa olevalla booking._rate_limit-mekanismilla (IP booking._client_ip(): cf-connecting-ip / x-forwarded-for
--      kuten muissa public-funktioissa). IP:tä ei tallenneta selväkielisenä: ämpäri on 'analytics:ip:' || md5(päivä || ip), rate_limit_hits
--      siivoutuu 2 vrk:ssa (booking.expire_holds). Ilman IP:tä kaikki jakavat yhden tiukemman ämpärin 'analytics:noip'.
--      Rajat asetuksina: analytics_rl_ip_per_10min (120), analytics_rl_noip_per_10min (60). Ylitys: {"ok":false,"code":"rate_limited"}.
--    * Globaali päiväkatto analytics_daily_cap (20000 tapahtumaa / Helsingin päivä) laskurilla booking.analytics_daily_counts.
--      Ylitys ohitetaan hiljaa: vastaus on sama {"ok":true} eikä paljasta tilaa. Ostotapahtumat (vain maksetut, kerran per tilaus) eivät kuluta kattoa.
-- 2) Säilytysaika: booking.analytics_cleanup() poistaa raakatapahtumat, jotka ovat vanhempia kuin analytics_retention_months (13) kk,
--    sekä yli 2 vrk vanhat päivälaskurit. pg_cron-ajo booking_analytics_cleanup (päivittäin 03:17 UTC), luonti idempotentti kuten
--    booking_139:n booking_waitlist_sweep.
-- 3) Polku normalisoidaan palvelimella (booking._analytics_path): query ja fragment pois, vain tunnetut sivuston polut (content/site.json,
--    tilaussivu, Saunatietoa-listaus, julkaistut artikkelit); tagi- ja sivutussivut kootaan listaukseen, muut -> '/muu'. Hallinta hylätään kuten ennen.
--    UTM-arvot (booking._analytics_utm_ok): source/medium enintään 40, campaign enintään 60 merkkiä, vain [a-z0-9_.-] (alkaa kirjaimella tai
--    numerolla), ei 5 numeron jonoja, ei yhteensä 9+ numeroa (puhelinnumerot erottimilla), ei @-merkkiä/sähköposteja. Virheellinen -> invalid_utm.
-- 4) Lähdekategoria johdetaan aina palvelimella (booking._analytics_source referreristä ja UTM-arvoista); asiakkaan source_category ohitetaan
--    (kenttä sallitaan yhä, jotta vanha välimuistissa oleva skripti ei saa invalid_field-virhettä).
-- 5) admin_analytics_summary: päiväsarja yhdellä GROUP BY event_date -koosteella (ei enää päiväkohtaisia alikyselyitä koko jaksolle),
--    uusi indeksi analytics_events_date_type_session_idx (event_date, event_type, session_key). Tulosmuoto ja luvut ennallaan.
-- Ei koske public-skeemaan eikä booking_145/146/148/149:n funktioihin. Ei muuta hintoja, ALV:tä eikä URL-osoitteita.
set local lock_timeout = '5s';

insert into booking.settings(key, value, description) values
 ('analytics_rl_ip_per_10min', '120'::jsonb, 'Kävijämittaus: tapahtumia enintään per IP-osoite 10 minuutissa (public_track_event). Oletus 120.'),
 ('analytics_rl_noip_per_10min', '60'::jsonb, 'Kävijämittaus: tapahtumia enintään 10 minuutissa yhteensä pyynnöille, joiden IP-osoite ei ole tiedossa. Oletus 60.'),
 ('analytics_daily_cap', '20000'::jsonb, 'Kävijämittaus: tallennettavia tapahtumia enintään vuorokaudessa (Helsingin aika). Ylitys ohitetaan hiljaa. Oletus 20000.'),
 ('analytics_retention_months', '13'::jsonb, 'Kävijämittaus: raakatapahtumien säilytysaika kuukausina; vanhemmat poistetaan päivittäin (pg_cron booking_analytics_cleanup). Oletus 13.')
on conflict (key) do nothing;

-- Päivälaskuri globaalia kattoa varten (yksi rivi per päivä, ei tunnisteita).
create table if not exists booking.analytics_daily_counts (
  event_date date primary key,
  n integer not null default 0
);
alter table booking.analytics_daily_counts enable row level security;
revoke all on booking.analytics_daily_counts from public, anon, authenticated;
grant all on booking.analytics_daily_counts to service_role;

-- Päiväsarjan ja päiväkohtaisen kävijämäärän kooste ilman taulun lukemista (index-only scan).
create index if not exists analytics_events_date_type_session_idx on booking.analytics_events(event_date, event_type, session_key);

-- UTM-arvon tarkistus. null = ei arvoa (sallittu).
create or replace function booking._analytics_utm_ok(p_value text, p_max integer)
returns boolean language sql immutable set search_path = '' as $$
  select p_value is null or (
    char_length(p_value) <= p_max
    and p_value ~ '^[a-z0-9][a-z0-9_.-]*$'
    and p_value !~ '[0-9]{5,}'
    and char_length(regexp_replace(p_value, '[^0-9]', '', 'g')) < 9
    and position('@' in p_value) = 0)
$$;

-- Polun normalisointi tunnettuihin sivupolkuihin. null = ei mitattava (hallinta).
create or replace function booking._analytics_path(p_path text)
returns text language plpgsql stable set search_path = '' as $$
declare
  v text;
  m text[];
begin
  v := lower(left(coalesce(p_path, ''), 300));
  v := split_part(split_part(v, '#', 1), '?', 1);
  v := regexp_replace(v, '/{2,}', '/', 'g');
  v := regexp_replace(v, '/index\.html?$', '/');
  if v = '' or left(v, 1) <> '/' then return '/muu'; end if;
  if right(v, 1) <> '/' then v := v || '/'; end if;
  if v ~ '^/(en/)?(hallinta|admin)/' then return null; end if;
  -- Sivuston reitit (content/site.json pages + tilaussivu + Saunatietoa-listaus, content/articles.json path).
  if v in ('/', '/en/', '/saunavuorot/', '/en/sauna/', '/hoidot-rituaalit/', '/en/treatments-rituals/', '/lahjakortti/', '/en/gift-card/',
           '/varaa/', '/en/book/', '/info/', '/en/info/', '/yritykset/', '/en/companies/', '/ehdot/', '/en/terms/', '/tietosuoja/',
           '/tilaus/', '/en/order/', '/saunatietoa/', '/en/sauna-knowledge/') then
    return v;
  end if;
  if v ~ '^/saunatietoa/tagi/' then return '/saunatietoa/tagi/'; end if;
  if v ~ '^/en/sauna-knowledge/tag/' then return '/en/sauna-knowledge/tag/'; end if;
  if v ~ '^/saunatietoa/sivu/[0-9]{1,3}/$' then return '/saunatietoa/'; end if;
  if v ~ '^/en/sauna-knowledge/page/[0-9]{1,3}/$' then return '/en/sauna-knowledge/'; end if;
  m := regexp_match(v, '^/saunatietoa/([a-z0-9]+(?:-[a-z0-9]+)*)/$');
  if m is not null and exists (select 1 from booking.articles a where a.slug_fi = m[1] and a.status = 'published'
                                 and a.published_at <= now() and a.deleted_at is null) then
    return v;
  end if;
  m := regexp_match(v, '^/en/sauna-knowledge/([a-z0-9]+(?:-[a-z0-9]+)*)/$');
  if m is not null and exists (select 1 from booking.articles a where a.slug_en = m[1] and a.status = 'published'
                                 and a.published_at <= now() and a.deleted_at is null) then
    return v;
  end if;
  return '/muu';
end $$;

-- Säilytysajan siivous (pg_cron). Palauttaa poistettujen tapahtumien määrän.
create or replace function booking.analytics_cleanup()
returns integer language plpgsql volatile security definer set search_path = '' as $$
declare
  v_months integer;
  v_n integer;
begin
  begin
    v_months := (booking._setting('analytics_retention_months', '13'::jsonb) #>> '{}')::integer;
  exception when others then v_months := 13;
  end;
  if v_months is null or v_months < 1 then v_months := 13; end if;
  delete from booking.analytics_events
   where event_date < ((now() at time zone 'Europe/Helsinki')::date - make_interval(months => v_months))::date;
  get diagnostics v_n = row_count;
  delete from booking.analytics_daily_counts where event_date < (now() at time zone 'Europe/Helsinki')::date - 2;
  return v_n;
end $$;
revoke all on function booking.analytics_cleanup() from public, anon, authenticated;
grant execute on function booking.analytics_cleanup() to service_role;
revoke all on function booking._analytics_path(text) from public, anon, authenticated;
revoke all on function booking._analytics_utm_ok(text, integer) from public, anon, authenticated;

create or replace function booking.public_track_event(p_payload jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_type text; v_sk text; v_path text; v_locale text; v_dev text; v_domain text; v_us text; v_um text; v_uc text; v_source text; v_slug text;
  v_pid bigint; v_token uuid; v_order bigint; v_gross numeric(10,2); v_status text;
  v_key text; v_ip text; v_today date := (now() at time zone 'Europe/Helsinki')::date; v_lim integer; v_cap integer; v_n integer;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' or octet_length(p_payload::text) > 4096 then return '{"ok":false,"code":"invalid_payload"}'::jsonb; end if;
  -- booking_150: IP-kohtainen raja (_rate_limit kirjaa myös estetyt). IP vain tiivisteenä ämpärin nimessä, ei tapahtumatauluun.
  v_ip := booking._client_ip();
  begin
    if v_ip is not null then
      v_lim := (booking._setting('analytics_rl_ip_per_10min', '120'::jsonb) #>> '{}')::integer;
    else
      v_lim := (booking._setting('analytics_rl_noip_per_10min', '60'::jsonb) #>> '{}')::integer;
    end if;
  exception when others then v_lim := case when v_ip is not null then 120 else 60 end;
  end;
  if not booking._rate_limit(case when v_ip is not null then 'analytics:ip:' || md5(v_today::text || ':' || v_ip) else 'analytics:noip' end,
                             coalesce(v_lim, 60), interval '10 minutes') then
    return '{"ok":false,"code":"rate_limited"}'::jsonb;
  end if;
  -- Älä hyväksy ylimääräisiä henkilötietoja / HTTP-tunnisteita. source_category sallitaan vanhan skriptin vuoksi, mutta sitä ei käytetä.
  for v_key in select jsonb_object_keys(p_payload) loop
    if v_key not in ('session_key','event_type','path','locale','device_type','referrer_domain','utm_source','utm_medium','utm_campaign','source_category','product_id','product_slug','order_token','bot') then
      return '{"ok":false,"code":"invalid_field"}'::jsonb;
    end if;
  end loop;
  if p_payload->>'bot' = 'true' then return '{"ok":false,"code":"bot"}'::jsonb; end if;
  -- Pyyntöotsaketta käytetään vain hetkelliseen suodatukseen: sitä ei tallenneta.
  if coalesce((nullif(current_setting('request.headers',true),'')::jsonb)->>'user-agent','') ~* '(bot|crawler|spider|headless|lighthouse|playwright|puppeteer|selenium)' then
    return '{"ok":false,"code":"bot"}'::jsonb;
  end if;
  v_type := p_payload->>'event_type'; v_sk := lower(coalesce(p_payload->>'session_key',''));
  if v_type is null or v_type not in ('page_view','product_view','checkout_start','purchase')
     or v_sk !~ '^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$'
  then return '{"ok":false,"code":"invalid_event"}'::jsonb; end if;
  -- booking_150: polku tunnettuihin sivupolkuihin (query/fragment pois, tuntematon -> '/muu').
  v_path := booking._analytics_path(p_payload->>'path');
  if v_path is null then return '{"ok":false,"code":"invalid_path"}'::jsonb; end if;
  v_locale := coalesce(p_payload->>'locale','fi'); v_dev := coalesce(p_payload->>'device_type','desktop');
  if v_locale not in ('fi','en') or v_dev not in ('mobile','desktop','tablet') then return '{"ok":false,"code":"invalid_device_or_locale"}'::jsonb; end if;
  v_domain := lower(nullif(left(coalesce(p_payload->>'referrer_domain',''), 180),''));
  if v_domain is not null and (v_domain !~ '^[a-z0-9.-]+$' or not (v_domain like '%.%') or v_domain like '%..%' or v_domain like '.%' or v_domain like '%.' or v_domain like '%@%') then
    return '{"ok":false,"code":"invalid_referrer"}'::jsonb;
  end if;
  -- booking_150: UTM-arvot tiukemmin (pituus, merkit, ei numerojonoja eikä sähköposteja). Ei katkaista: liian pitkä hylätään.
  v_us := nullif(lower(coalesce(p_payload->>'utm_source','')), '');
  v_um := nullif(lower(coalesce(p_payload->>'utm_medium','')), '');
  v_uc := nullif(lower(coalesce(p_payload->>'utm_campaign','')), '');
  if not booking._analytics_utm_ok(v_us, 40) or not booking._analytics_utm_ok(v_um, 40) or not booking._analytics_utm_ok(v_uc, 60) then
    return '{"ok":false,"code":"invalid_utm"}'::jsonb;
  end if;
  v_slug := nullif(left(coalesce(p_payload->>'product_slug',''), 100),'');
  if v_slug is not null and v_slug !~ '^[a-z0-9-]+$' then return '{"ok":false,"code":"invalid_slug"}'::jsonb; end if;
  if p_payload ? 'product_id' and p_payload->>'product_id' ~ '^[0-9]{1,12}$' then v_pid := (p_payload->>'product_id')::bigint; end if;
  if v_pid is not null and not exists(select 1 from kb.products where id=v_pid) then v_pid := null; end if;
  -- Älä tallenna mielivaltaisia merkkijonoja tuoteniminä. Tuote hyväksytään vain katalogista.
  if v_pid is null and v_slug is not null then select p.id into v_pid from kb.products p where p.slug=v_slug order by p.id limit 1; end if;
  if v_pid is null and v_path in ('/lahjakortti/','/en/gift-card/') then
    select p.id into v_pid from kb.products p where p.slug='lahjakortti' order by p.id limit 1;
  end if;
  if v_pid is not null then select p.slug into v_slug from kb.products p where p.id=v_pid;
  else v_slug := null; end if;
  -- booking_150: lähde aina palvelimella referreristä ja UTM-arvoista (asiakkaan source_category ohitetaan).
  v_source := booking._analytics_source(v_domain, v_us, v_uc);
  if v_type <> 'purchase' and (select count(*) from booking.analytics_events where session_key=v_sk and event_date=v_today) >= 200 then
    return '{"ok":false,"code":"too_many_events"}'::jsonb;
  end if;
  if v_type = 'purchase' then
    begin v_token := (p_payload->>'order_token')::uuid; exception when invalid_text_representation then return '{"ok":false,"code":"invalid_order"}'::jsonb; end;
    if v_token is null then return '{"ok":false,"code":"invalid_order"}'::jsonb; end if;
    select o.id,o.total_gross,o.payment_status into v_order,v_gross,v_status from booking.orders o where o.public_token=v_token;
    if v_order is null or v_status <> 'paid' then return '{"ok":false,"code":"not_paid"}'::jsonb; end if;
    -- Oikea tuote päätellään tilausrivistä; selain ei saa määrätä ostosummaa eikä tuotetta.
    select oi.product_id, p.slug into v_pid,v_slug from booking.order_items oi
      left join kb.products p on p.id=oi.product_id
      where oi.order_id=v_order and oi.product_id is not null
      order by oi.id limit 1;
  else
    -- booking_150: globaali päiväkatto. Ylitys ohitetaan hiljaa (sama vastaus kuin tallennuksessa, ei paljasta tilaa).
    begin
      v_cap := (booking._setting('analytics_daily_cap', '20000'::jsonb) #>> '{}')::integer;
    exception when others then v_cap := 20000;
    end;
    insert into booking.analytics_daily_counts as c(event_date, n) values (v_today, 1)
      on conflict (event_date) do update set n = c.n + 1
      returning c.n into v_n;
    if v_n > coalesce(v_cap, 20000) then return '{"ok":true}'::jsonb; end if;
  end if;
  insert into booking.analytics_events(session_key,event_type,path,locale,device_type,source_category,referrer_domain,utm_source,utm_medium,utm_campaign,product_id,product_slug,order_id,amount_gross)
  values(v_sk,v_type,v_path,v_locale,v_dev,v_source,v_domain,v_us,v_um,v_uc,v_pid,v_slug,v_order,v_gross)
  on conflict do nothing;
  return '{"ok":true}'::jsonb;
end $$;
revoke all on function booking.public_track_event(jsonb) from public;
grant execute on function booking.public_track_event(jsonb) to anon,authenticated,service_role;

-- booking_150: sama tulosmuoto ja luvut kuin booking_144:ssä; vain päiväsarjan laskenta muuttui.
create or replace function booking.admin_analytics_summary(p_from date, p_to date)
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
  ), daily as (
     -- booking_150: yksi kooste päivittäin (GROUP BY), ei päiväkohtaisia alikyselyitä. Indeksi analytics_events_date_type_session_idx.
     select a.event_date,
            count(distinct a.session_key) filter (where a.event_type='page_view') visitors,
            count(*) filter (where a.event_type='product_view') product_views,
            count(*) filter (where a.event_type='checkout_start') checkouts,
            count(*) filter (where a.event_type='purchase') purchases
       from booking.analytics_events a
      where a.event_date between p_from and p_to
      group by a.event_date
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
    'daily_series',coalesce((select jsonb_agg(jsonb_build_object('date',d.d_day,
       'visitors',coalesce(x.visitors,0),
       'product_views',coalesce(x.product_views,0),
       'checkouts',coalesce(x.checkouts,0),
       'purchases',coalesce(x.purchases,0)) order by d.d_day) from days d left join daily x on x.event_date=d.d_day),'[]'::jsonb)
  ) into result;
  return result;
end $$;
revoke all on function booking.admin_analytics_summary(date,date) from public,anon;
grant execute on function booking.admin_analytics_summary(date,date) to authenticated,service_role;

-- Säilytysajan siivous päivittäin. Idempotentti (ei luoda toista samannimistä ajoa), kuten booking_139 booking_waitlist_sweep.
do $$ begin
  if to_regprocedure('cron.schedule(text,text,text)') is not null
     and not exists (select 1 from cron.job where jobname = 'booking_analytics_cleanup') then
    perform cron.schedule('booking_analytics_cleanup', '17 3 * * *', 'select booking.analytics_cleanup()');
  end if;
exception when others then
  raise notice 'pg_cron-ajastus ohitettu: %', sqlerrm;
end $$;
