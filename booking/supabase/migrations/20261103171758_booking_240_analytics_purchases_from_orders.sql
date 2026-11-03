-- booking_240_analytics_purchases_from_orders
-- Kävijät-välilehti (admin_analytics_summary): 'Ostaneet', 'Maksettuja tilauksia' ja euromäärä lasketaan booking.orders-taulusta,
-- ei enää pelkästä kävijämittauksen purchase-tapahtumasta (mittaus oli tuotannossa pois päältä → aina 0).
--
-- MÄÄRITELMÄ "maksettu verkkokauppatilaus" (booking._analytics_paid_orders):
--   * payment_status in ('paid','partially_refunded')  – sama joukko kuin admin_sales_chart käyttää maksetuille tilauksille.
--     Ei: partially_paid (kesken), invoiced (laskutettu, ei vielä maksettu), unpaid, refunded.
--   * status not in ('cancelled','expired','pending')  – peruttu/vanhentunut/kesken ei ole myyntiä (myös jos maksu on vielä palauttamatta).
--   * ei Johku-tuontia: external_source is null and johku_order_no is null and source_channel <> 'johku_import'
--     (sama ehto kuin booking._is_johku_row / _acct_excluded).
--   * päivä = tilauksen created_at Helsingin aikaan (Europe/Helsinki), välillä p_from..p_to (sama päivärajaus kuin mittauksella).
--   * Ostaneet/funnel ja paid_orders/amount_gross = vain source_channel='web' (sivuston kävijäputken viimeinen askel; pikakassa
--     ja hallinnan tilaukset eivät ole sivuston kävijöitä). Kaikki natiivit kanavat (web+admin+pikakassa) lisäkentissä
--     paid_orders_all_channels / amount_gross_all_channels.
--   * Ostaneet = tilausten määrä (ei uniikit asiakkaat). Euro = orders.total_gross (osittain hyvitetyissä brutto ennen hyvitystä).
--   * buyers_linked = näistä tilauksista ne, joille on mittauksen purchase-tapahtuma (analytics_events.order_id).
--     HUOM: analytics.js:n session_key on sivulataus-kohtainen (ei evästettä/storagea), ja osto kirjataan tilaus-/vahvistussivun
--     uudella sivulatauksella, joten linkitetty istunto ei kerro alkuperäistä kävijälähdettä. Kuukausikoosteessa order_id ei säily.
-- PALAUTUSMUOTO: ennallaan. funnel.buyers/paid_orders/amount_gross/conversion_pct samat avaimet ja tyypit (int/int/numeric/numeric).
--   Lisätty vain uusia avaimia funneliin: buyers_source, buyers_linked, buyers_events, paid_orders_events, amount_gross_events,
--   paid_orders_all_channels, amount_gross_all_channels. conversion_pct = buyers/visitors, visitors=0 → 0 (kuten ennen).
-- SECURITY DEFINER, search_path='' ja oikeustarkistus (reports.view/reports.daily) ennallaan. Rollback: prod_before/admin_analytics_summary.sql.

create or replace function booking._analytics_paid_orders(p_from date, p_to date)
returns table(buyers integer, orders integer, gross numeric(12,2), linked integer, orders_all integer, gross_all numeric(12,2))
language sql stable
set search_path to ''
as $$
  with o as (
    select o.id, o.total_gross, o.source_channel
      from booking.orders o
     where o.created_at >= (p_from::timestamp at time zone 'Europe/Helsinki')
       and o.created_at <  ((p_to + 1)::timestamp at time zone 'Europe/Helsinki')
       and o.payment_status in ('paid', 'partially_refunded')
       and o.status not in ('cancelled', 'expired', 'pending')
       and o.external_source is null and o.johku_order_no is null
       and o.source_channel is distinct from 'johku_import'
  )
  select count(*) filter (where o.source_channel = 'web')::int,
         count(*) filter (where o.source_channel = 'web')::int,
         coalesce(sum(o.total_gross) filter (where o.source_channel = 'web'), 0)::numeric(12,2),
         count(*) filter (where o.source_channel = 'web' and exists (
           select 1 from booking.analytics_events e where e.event_type = 'purchase' and e.order_id = o.id))::int,
         count(*)::int,
         coalesce(sum(o.total_gross), 0)::numeric(12,2)
    from o
$$;
revoke all on function booking._analytics_paid_orders(date, date) from public, anon, authenticated;
comment on function booking._analytics_paid_orders(date, date) is 'booking_240: Kävijät-välilehden maksetut tilaukset booking.ordersista (ks. migraation määritelmä). Vain admin_analytics_summary käyttää.';

CREATE OR REPLACE FUNCTION booking.admin_analytics_summary(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb; v_today date := (now() at time zone 'Europe/Helsinki')::date;
begin
  perform booking._require_staff();
  if not (booking.has_permission('reports.view') or booking.has_permission('reports.daily')) then
    perform booking._err('forbidden','Raporttien tarkasteluoikeus puuttuu');
  end if;
  -- booking_157: menneisyyteen osuva pitkä aikaväli luetaan kuukausikoosteesta (enintään 3661 päivää); muuten enintään 367 päivää.
  if p_from is null or p_to is null or p_from > p_to or (p_to - p_from > 366 and (p_to > v_today or p_to - p_from > 3660)) then
    perform booking._err('invalid_range','Aikaväli saa olla enintään 367 päivää (menneisyydessä enintään 3661 päivää)');
  end if;
  if not exists (select 1 from booking.analytics_monthly m where m.month between date_trunc('month', p_from)::date and p_to) then
    -- Ei koostekuukausia: täsmälleen booking_150:n kysely.
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
      'funnel', (select to_jsonb(f) || jsonb_build_object('paid_orders',ow.orders,'amount_gross',ow.gross,'conversion_pct',coalesce(round(100.0*ow.buyers/nullif(f.visitors,0),2),0),
        -- booking_240: Ostaneet ja maksetut tilaukset booking.ordersista (ks. booking._analytics_paid_orders). Vanhat mittausarvot *_events-avaimissa.
        'buyers',ow.buyers,'buyers_source','orders','buyers_linked',ow.linked,
        'buyers_events',f.buyers,'paid_orders_events',paid.orders,'amount_gross_events',paid.gross,
        'paid_orders_all_channels',ow.orders_all,'amount_gross_all_channels',ow.gross_all)
        from f cross join paid cross join booking._analytics_paid_orders(p_from,p_to) ow),
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
  end if;
  -- Koostekuukausia mukana: raakadata (vielä säilytetyt päivät) + kooste (poistetut päivät). Jokainen tapahtuma on vain toisessa,
  -- joten tuplalaskentaa ei ole. Koostekuukausi sisältyy kokonaisena; uniikit istunnot ovat päiväkohtaisten summa.
  with e as materialized (
    select * from booking.analytics_events where event_date between p_from and p_to
  ), ag as materialized (
    select * from booking.analytics_monthly m where m.month between date_trunc('month', p_from)::date and p_to
  ), fr as (
    select count(distinct session_key) filter(where event_type='page_view')::int visitors,
           count(distinct session_key) filter(where event_type='product_view')::int product_viewers,
           count(distinct session_key) filter(where event_type='checkout_start')::int checkout_starters,
           count(distinct session_key) filter(where event_type='purchase')::int buyers,
           count(*) filter(where event_type='page_view')::int page_view_events,
           count(*) filter(where event_type='product_view')::int product_view_events,
           count(*) filter(where event_type='checkout_start')::int checkout_events,
           count(*) filter(where event_type='purchase')::int purchase_events
    from e
  ), fa as (
    select coalesce(sum(events) filter(where kind='unique' and event_type='page_view'),0)::int visitors,
           coalesce(sum(events) filter(where kind='unique' and event_type='product_view'),0)::int product_viewers,
           coalesce(sum(events) filter(where kind='unique' and event_type='checkout_start'),0)::int checkout_starters,
           coalesce(sum(events) filter(where kind='unique' and event_type='purchase'),0)::int buyers,
           coalesce(sum(events) filter(where kind='event' and event_type='page_view'),0)::int page_view_events,
           coalesce(sum(events) filter(where kind='event' and event_type='product_view'),0)::int product_view_events,
           coalesce(sum(events) filter(where kind='event' and event_type='checkout_start'),0)::int checkout_events,
           coalesce(sum(events) filter(where kind='event' and event_type='purchase'),0)::int purchase_events,
           coalesce(sum(orders) filter(where kind='unique' and event_type='purchase'),0)::int orders,
           coalesce(sum(amount_gross_sum) filter(where kind='unique' and event_type='purchase'),0)::numeric(12,2) gross
    from ag
  ), f as (
    select fr.visitors+fa.visitors visitors, fr.product_viewers+fa.product_viewers product_viewers,
           fr.checkout_starters+fa.checkout_starters checkout_starters, fr.buyers+fa.buyers buyers,
           fr.page_view_events+fa.page_view_events page_view_events, fr.product_view_events+fa.product_view_events product_view_events,
           fr.checkout_events+fa.checkout_events checkout_events, fr.purchase_events+fa.purchase_events purchase_events
    from fr cross join fa
  ), paid_raw as (
    select count(*)::int orders,coalesce(sum(amount_gross),0)::numeric(12,2) gross from
       (select distinct on(order_id) order_id,amount_gross from e where event_type='purchase' and order_id is not null order by order_id,created_at desc) p
  ), paid as (
    select paid_raw.orders+fa.orders orders, (paid_raw.gross+fa.gross)::numeric(12,2) gross from paid_raw cross join fa
  ), visits as (
    select distinct on (session_key) session_key,source_category,utm_campaign,referrer_domain,device_type,locale
       from e where event_type='page_view' order by session_key,created_at,id
  ), buyer_sessions as (
    select distinct session_key from e where event_type='purchase'
  ), checkout_sessions as (
    select distinct session_key from e where event_type='checkout_start'
  ), src_all as (
    select v.source_category, count(*) visits, count(c.session_key) checkouts, count(b.session_key) purchases
       from visits v left join checkout_sessions c using(session_key) left join buyer_sessions b using(session_key)
       group by v.source_category
    union all
    select source_category, sum(events), sum(checkouts), sum(purchases) from ag where kind='visit' group by source_category
  ), sources as (
    select source_category, sum(visits)::int visits, sum(checkouts)::int checkouts, sum(purchases)::int purchases,
           round(100.0*sum(purchases)/nullif(sum(visits),0),2) conversion_pct
      from src_all group by source_category
  ), top_campaign as (
     select source_category,utm_campaign,count(*)::int n from visits where utm_campaign is not null group by 1,2
  ), top_ref as (
     select source_category,referrer_domain,count(*)::int n from visits where referrer_domain is not null group by 1,2
  ), prod_all as (
    select coalesce(e.product_id,-1) product_id,e.product_slug,
      count(*) filter (where e.event_type='product_view') views,
      count(*) filter (where e.event_type='checkout_start') checkouts,
      count(*) filter (where e.event_type='purchase') purchases
    from e where e.product_id is not null or e.product_slug is not null group by coalesce(e.product_id,-1),e.product_slug
    union all
    select m.product_id, null::text,
      sum(m.events) filter (where m.event_type='product_view'),
      sum(m.events) filter (where m.event_type='checkout_start'),
      sum(m.events) filter (where m.event_type='purchase')
    from ag m where m.kind='event' and m.product_id <> 0 group by m.product_id
  ), products as (
    select min(product_id) product_id, max(product_slug) product_slug,
           coalesce(sum(views),0)::int views, coalesce(sum(checkouts),0)::int checkouts, coalesce(sum(purchases),0)::int purchases
      from prod_all
     group by case when product_id > 0 then product_id::text else 'slug:' || coalesce(product_slug, '') end
  ), dev_all as (
     select device_type,count(*) visits,count(b.session_key) purchases from visits v left join buyer_sessions b using(session_key) group by device_type
     union all select device_type, sum(events), sum(purchases) from ag where kind='visit' group by device_type
  ), devices as (
     select device_type, sum(visits)::int visits, sum(purchases)::int purchases from dev_all group by device_type
  ), loc_all as (
     select locale,count(*) visits,count(b.session_key) purchases from visits v left join buyer_sessions b using(session_key) group by locale
     union all select locale, sum(events), sum(purchases) from ag where kind='visit' group by locale
  ), locales as (
     select locale, sum(visits)::int visits, sum(purchases)::int purchases from loc_all group by locale
  ), days as (
     select d::date as d_day from generate_series(p_from,p_to,interval '1 day') d
  ), daily as (
     select a.event_date,
            count(distinct a.session_key) filter (where a.event_type='page_view') visitors,
            count(*) filter (where a.event_type='product_view') product_views,
            count(*) filter (where a.event_type='checkout_start') checkouts,
            count(*) filter (where a.event_type='purchase') purchases
       from booking.analytics_events a
      where a.event_date between p_from and p_to
      group by a.event_date
  ), months as (
     select m::date as m_month from generate_series(date_trunc('month', p_from), date_trunc('month', p_to), interval '1 month') m
  ), monthly as (
     select x.m, sum(x.visitors)::int visitors, sum(x.product_views)::int product_views, sum(x.checkouts)::int checkouts, sum(x.purchases)::int purchases
       from (select date_trunc('month', event_date)::date m, visitors, product_views, checkouts, purchases from daily
             union all
             select month,
                    coalesce(sum(events) filter (where kind='unique' and event_type='page_view'),0),
                    coalesce(sum(events) filter (where kind='event' and event_type='product_view'),0),
                    coalesce(sum(events) filter (where kind='event' and event_type='checkout_start'),0),
                    coalesce(sum(events) filter (where kind='event' and event_type='purchase'),0)
               from ag group by month) x
      group by x.m
  )
  select jsonb_build_object(
    'from',p_from,'to',p_to,
    'funnel', (select to_jsonb(f) || jsonb_build_object('paid_orders',ow.orders,'amount_gross',ow.gross,'conversion_pct',coalesce(round(100.0*ow.buyers/nullif(f.visitors,0),2),0),
        -- booking_240: Ostaneet ja maksetut tilaukset booking.ordersista (ks. booking._analytics_paid_orders). Vanhat mittausarvot *_events-avaimissa.
        'buyers',ow.buyers,'buyers_source','orders','buyers_linked',ow.linked,
        'buyers_events',f.buyers,'paid_orders_events',paid.orders,'amount_gross_events',paid.gross,
        'paid_orders_all_channels',ow.orders_all,'amount_gross_all_channels',ow.gross_all)
        from f cross join paid cross join booking._analytics_paid_orders(p_from,p_to) ow),
    'sources',coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object(
       'top_utm_campaign',(select t.utm_campaign from top_campaign t where t.source_category=s.source_category order by n desc,utm_campaign limit 1),
       'top_referrer_domain',(select t.referrer_domain from top_ref t where t.source_category=s.source_category order by n desc,referrer_domain limit 1)) order by s.visits desc) from sources s),'[]'::jsonb),
    'top_products',coalesce((select jsonb_agg(jsonb_build_object('product_id',nullif(p.product_id,-1),'product_slug',p.product_slug,
      'name',coalesce(k.name,p.product_slug,case when p.product_id=-1 then 'Muut tuotteet (kuukausikooste)' end,'Tuntematon tuote'),
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
       'purchases',coalesce(x.purchases,0)) order by d.d_day) from days d left join daily x on x.event_date=d.d_day),'[]'::jsonb),
    'monthly_series',coalesce((select jsonb_agg(jsonb_build_object('month',mo.m_month,
       'visitors',coalesce(y.visitors,0),'product_views',coalesce(y.product_views,0),
       'checkouts',coalesce(y.checkouts,0),'purchases',coalesce(y.purchases,0)) order by mo.m_month) from months mo left join monthly y on y.m=mo.m_month),'[]'::jsonb),
    'aggregated_months',coalesce((select jsonb_agg(z.m order by z.m) from (select distinct to_char(ag.month,'YYYY-MM') m from ag) z),'[]'::jsonb)
  ) into result;
  return result;
end $function$;
