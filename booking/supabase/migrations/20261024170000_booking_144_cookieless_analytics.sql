-- booking_144 (paketti 11): evästeetön, pseudonyyminen sivustotapahtumien mittaus + hallinnan Kävijät-raportti.
-- Perustuu muutospaketin 11 luonnokseen (booking_130_cookieless_analytics); numeroitu uudelleen booking_144:ksi.
-- Korjattu luonnoksesta: PL/pgSQL-muuttujat v_-etuliitteellä (luonnoksen "where p.slug = slug" oli moniselitteinen
-- ja kaatui ajossa), oikeudet tarkistettu PG17:ssä koko migraatioketjun päällä.
-- Ei IP-osoitteita, user-agentia, evästeitä eikä vapaata tekstiä. Selain ei määrää summaa eikä ostettua tuotetta.
-- HUOM: ostotapahtuma (purchase) liittää satunnaisen session_key:n tilaukseen -> tieto on pseudonyymiä, ei anonyymiä.
-- Sivuston seuranta-skripti on OLETUKSENA POIS (scripts/build-pages.mjs: vain SITE_ANALYTICS=on ja SITE_ENV != test).
-- Ei käyttöön tuotannossa ennen tietosuojaselosteen päivitystä ja suostumus-/oikeusperustepäätöstä.
-- Ei koske vuosikortti- tai alennuskoodifunktioihin (booking_142/143). Rollback: rollbacks/20261024170000_booking_144_ROLLBACK.sql
create table if not exists booking.analytics_events (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  event_date date not null default ((now() at time zone 'Europe/Helsinki')::date),
  session_key text not null check (session_key ~ '^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$'),
  event_type text not null check (event_type in ('page_view', 'product_view', 'checkout_start', 'purchase')),
  path text not null,
  locale text not null default 'fi' check (locale in ('fi', 'en')),
  device_type text not null default 'desktop' check (device_type in ('mobile', 'desktop', 'tablet')),
  source_category text not null default 'direct' check (source_category in ('google_search','google_maps','social','campaign','referral','direct')),
  referrer_domain text,
  utm_source text,
  utm_medium text,
  utm_campaign text,
  product_id bigint references kb.products(id) on delete set null,
  product_slug text,
  order_id bigint references booking.orders(id) on delete set null,
  amount_gross numeric(10,2)
);
create index if not exists analytics_events_date_type_idx on booking.analytics_events(event_date, event_type);
create index if not exists analytics_events_date_source_idx on booking.analytics_events(event_date, source_category);
create index if not exists analytics_events_date_product_idx on booking.analytics_events(event_date, product_id);
create index if not exists analytics_events_session_date_idx on booking.analytics_events(session_key, event_date);
create unique index if not exists analytics_events_unique_paid_order_idx on booking.analytics_events(order_id) where event_type = 'purchase' and order_id is not null;
alter table booking.analytics_events enable row level security;
revoke all on booking.analytics_events from public, anon, authenticated;
grant all on booking.analytics_events to service_role;
revoke all on sequence booking.analytics_events_id_seq from public, anon, authenticated;
grant usage, select on sequence booking.analytics_events_id_seq to service_role;

-- Puhdas luokittelufunktio mahdollistaa kohdennetut regressiotestit.
create or replace function booking._analytics_source(p_referrer text, p_utm_source text, p_utm_campaign text)
returns text language plpgsql immutable set search_path = '' as $$
declare d text := lower(coalesce(p_referrer,''));
begin
  if p_utm_source is not null or p_utm_campaign is not null then return 'campaign'; end if;
  if d ~ '^maps\.google\.[a-z.]+$' then return 'google_maps'; end if;
  if d ~ '(^|\.)(google\.[a-z.]+|bing\.com|duckduckgo\.com)$' then return 'google_search'; end if;
  if d ~ '(^|\.)(instagram\.com|facebook\.com|fb\.com|tiktok\.com|t\.co)$' then return 'social'; end if;
  if d = '' or d ~ '(^|\.)(saunotus\.(fi|com)|github\.io)$' or d = 'localhost' then return 'direct'; end if;
  return 'referral';
end $$;
-- Google Maps voidaan tunnistaa vain, jos HTTP Referrer paljastaa maps-alidomainin.
-- Polkua/queryä ei tietosuojasyistä kerätä; maps.google.com tunnistetaan erikseen.

create or replace function booking.public_track_event(p_payload jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_type text; v_sk text; v_path text; v_locale text; v_dev text; v_domain text; v_us text; v_um text; v_uc text; v_source text; v_slug text;
  v_pid bigint; v_token uuid; v_order bigint; v_gross numeric(10,2); v_status text;
  v_key text;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' or octet_length(p_payload::text) > 4096 then return '{"ok":false,"code":"invalid_payload"}'::jsonb; end if;
  -- Älä hyväksy ylimääräisiä henkilötietoja / HTTP-tunnisteita.
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
  v_path := left(coalesce(p_payload->>'path',''), 160);
  if v_path !~ '^/[a-zA-Z0-9_/-]*$' or v_path like '/hallinta/%' or v_path = '/hallinta' then return '{"ok":false,"code":"invalid_path"}'::jsonb; end if;
  v_locale := coalesce(p_payload->>'locale','fi'); v_dev := coalesce(p_payload->>'device_type','desktop');
  if v_locale not in ('fi','en') or v_dev not in ('mobile','desktop','tablet') then return '{"ok":false,"code":"invalid_device_or_locale"}'::jsonb; end if;
  v_domain := lower(nullif(left(coalesce(p_payload->>'referrer_domain',''), 180),''));
  if v_domain is not null and (v_domain !~ '^[a-z0-9.-]+$' or not (v_domain like '%.%') or v_domain like '%..%' or v_domain like '.%' or v_domain like '%.' or v_domain like '%@%') then
    return '{"ok":false,"code":"invalid_referrer"}'::jsonb;
  end if;
  v_us := nullif(lower(left(coalesce(p_payload->>'utm_source',''), 80)), '');
  v_um := nullif(lower(left(coalesce(p_payload->>'utm_medium',''), 80)), '');
  v_uc := nullif(lower(left(coalesce(p_payload->>'utm_campaign',''), 100)), '');
  if (v_us is not null and v_us !~ '^[a-z0-9_.-]+$') or (v_um is not null and v_um !~ '^[a-z0-9_.-]+$') or (v_uc is not null and v_uc !~ '^[a-z0-9_.-]+$') then
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
  v_source := coalesce(p_payload->>'source_category', booking._analytics_source(v_domain, v_us, v_uc));
  if v_source not in ('google_search','google_maps','social','campaign','referral','direct') then return '{"ok":false,"code":"invalid_source"}'::jsonb; end if;
  if v_type <> 'purchase' and (select count(*) from booking.analytics_events where session_key=v_sk and event_date=(now() at time zone 'Europe/Helsinki')::date) >= 200 then
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
  end if;
  insert into booking.analytics_events(session_key,event_type,path,locale,device_type,source_category,referrer_domain,utm_source,utm_medium,utm_campaign,product_id,product_slug,order_id,amount_gross)
  values(v_sk,v_type,v_path,v_locale,v_dev,v_source,v_domain,v_us,v_um,v_uc,v_pid,v_slug,v_order,v_gross)
  on conflict do nothing;
  return '{"ok":true}'::jsonb;
end $$;
revoke all on function booking.public_track_event(jsonb) from public;
grant execute on function booking.public_track_event(jsonb) to anon,authenticated,service_role;
revoke all on function booking._analytics_source(text,text,text) from public,anon,authenticated;

-- Kaikki luvut perustuvat tallennettuihin anonyymeihin tapahtumiin.
-- Maksetut tilaukset ovat vain mittauksen tavoittamia tilauksia, eivät kaikki kirjanpidon maksut.
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
revoke all on function booking.admin_analytics_summary(date,date) from public,anon;
grant execute on function booking.admin_analytics_summary(date,date) to authenticated,service_role;
