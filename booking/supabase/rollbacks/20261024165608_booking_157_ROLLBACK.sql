-- ROLLBACK booking_157: tietosuojan säilytysajat ja kävijämittauksen kuukausikooste.
-- Palauttaa neljä uudelleenmääriteltyä funktiota TÄSMÄLLEEN tuotannon nykyiseen muotoon (pg_get_functiondef-teksti sellaisenaan;
-- CREATE OR REPLACE säilyttää oikeudet) ja tarkistaa lopuksi md5(pg_get_functiondef):n — jos ei täsmää, koko rollback perutaan.
-- Poistaa booking_157:n uudet funktiot ja asetukset. Taulut booking.analytics_monthly ja booking.privacy_retention_runs poistetaan
-- vain, jos ne ovat tyhjiä (muuten jätetään paikalleen, jotta koostettu kävijädata ja ajoloki eivät katoa; poista käsin tarvittaessa).
-- HUOM: jo anonymisoituja henkilötietoja rollback ei palauta (anonymisointi on tarkoituksella peruuttamaton).
-- Ajettavissa uudelleen.
set local lock_timeout = '5s';

-- Ensin pg_cron-ajo pois, jos manuaalitiedosto booking_157_retention_cron.sql on ajettu.
do $$ begin
  if to_regclass('cron.job') is not null and exists (select 1 from cron.job where jobname = 'booking_privacy_retention') then
    perform cron.unschedule('booking_privacy_retention');
  end if;
end $$;

-- booking.receipts_guard_trg()  md5 ea08f705bc87c141b6c3aa21b30e5d12
CREATE OR REPLACE FUNCTION booking.receipts_guard_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'DELETE' then perform booking._err('receipt_immutable', 'Kuittia ei voi poistaa (säilytysvelvollisuus 6 v)'); end if;
  if (new.receipt_no, new.kind, new.series, new.year, new.seq, new.order_id, new.payment_id, new.refund_id, new.original_receipt_id, new.issued_at, new.total_gross, new.snapshot, new.text_body, new.public_token)
     is distinct from
     (old.receipt_no, old.kind, old.series, old.year, old.seq, old.order_id, old.payment_id, old.refund_id, old.original_receipt_id, old.issued_at, old.total_gross, old.snapshot, old.text_body, old.public_token) then
    perform booking._err('receipt_immutable', 'Kuittia ei voi muuttaa (vain pdf_path/pdf_generated_at/sent_at)');
  end if;
  return new;
end $function$;

-- booking.invoices_lock_trg()  md5 4195a369d8bf7dc8cd15e24663f41b0a
CREATE OR REPLACE FUNCTION booking.invoices_lock_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'DELETE' then
    perform booking._err('invoice_locked', 'Laskua ei poisteta. Mitätöi luonnos tai tee hyvityslasku.');
  end if;
  if old.status <> 'draft' then
    if new.customer_id is distinct from old.customer_id
       or new.order_id is distinct from old.order_id
       or new.credit_of_id is distinct from old.credit_of_id
       or new.kind is distinct from old.kind
       or new.invoice_date is distinct from old.invoice_date
       or new.due_date is distinct from old.due_date
       or new.reference_no is distinct from old.reference_no
       or new.buyer_reference is distinct from old.buyer_reference
       or new.currency is distinct from old.currency
       or new.notes is distinct from old.notes
       or new.locale is distinct from old.locale
       or new.seller_snapshot is distinct from old.seller_snapshot
       or new.customer_snapshot is distinct from old.customer_snapshot
       or new.total_net is distinct from old.total_net
       or new.total_vat is distinct from old.total_vat
       or new.total_gross is distinct from old.total_gross
       or new.vat_breakdown is distinct from old.vat_breakdown
       or new.series is distinct from old.series
       or new.seq is distinct from old.seq
       or new.invoice_no is distinct from old.invoice_no
       or new.public_token is distinct from old.public_token
       or new.created_by is distinct from old.created_by
    then
      perform booking._err('invoice_locked', 'Lähetettyä laskua ei voi muokata. Tee hyvityslasku.');
    end if;
    if new.status is distinct from old.status and not (
         (old.status = 'sent' and new.status in ('paid', 'overdue', 'credited'))
         or (old.status = 'overdue' and new.status in ('paid', 'credited'))
         or (old.status = 'paid' and new.status = 'credited'))
    then
      perform booking._err('invalid_status', 'Laskun tilasiirtymä ei ole sallittu');
    end if;
  elsif new.status is distinct from old.status and new.status not in ('sent', 'voided') then
    perform booking._err('invalid_status', 'Luonnos voidaan lähettää tai mitätöidä');
  end if;
  return new;
end $function$;

-- booking.analytics_cleanup()  md5 e7a029b50af8a35743babb726aa7a38f
CREATE OR REPLACE FUNCTION booking.analytics_cleanup()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;

-- booking.admin_analytics_summary(date,date)  md5 f21c0cbdde8587fbdf709ab7c724a08e
CREATE OR REPLACE FUNCTION booking.admin_analytics_summary(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;

drop function if exists booking.privacy_retention_run();
drop function if exists booking.privacy_retention_report(date);
drop function if exists booking._privacy_kb_leads(date);
drop function if exists booking._privacy_candidates(date);
drop function if exists booking._privacy_pii_keys();
drop function if exists booking._privacy_require_admin();
drop function if exists booking._privacy_acct_due(date, date);
drop function if exists booking._privacy_acct_year(date);
drop function if exists booking._privacy_fy_end_mmdd();
drop function if exists booking._privacy_int(text, integer, integer, integer);
drop function if exists booking._analytics_monthly_kanon();

do $$ begin
  if to_regclass('booking.privacy_retention_runs') is not null then
    if exists (select 1 from booking.privacy_retention_runs) then
      raise notice 'booking.privacy_retention_runs sisältää rivejä – jätetään paikalleen';
    else
      drop table booking.privacy_retention_runs;
    end if;
  end if;
  if to_regclass('booking.analytics_monthly') is not null then
    if exists (select 1 from booking.analytics_monthly) then
      raise notice 'booking.analytics_monthly sisältää koostettua dataa – jätetään paikalleen (palautettu raportti ei lue sitä)';
    else
      drop table booking.analytics_monthly;
    end if;
  end if;
end $$;

delete from booking.settings where key in ('privacy_retention.enabled', 'privacy_retention.fiscal_year_end', 'privacy_retention.customer_years',
  'privacy_retention.accounting_years', 'privacy_retention.email_outbox_months', 'analytics_k_min');

-- Tarkistus: funktiot ovat täsmälleen tuotannon booking_157:ää edeltävät määrittelyt.
do $$
declare r record; v_bad text := '';
begin
  for r in select * from (values
      ('booking.receipts_guard_trg()', 'ea08f705bc87c141b6c3aa21b30e5d12'),
      ('booking.invoices_lock_trg()', '4195a369d8bf7dc8cd15e24663f41b0a'),
      ('booking.analytics_cleanup()', 'e7a029b50af8a35743babb726aa7a38f'),
      ('booking.admin_analytics_summary(date,date)', 'f21c0cbdde8587fbdf709ab7c724a08e')
    ) v(sig, md5)
  loop
    if md5(pg_get_functiondef(r.sig::regprocedure)) is distinct from r.md5 then v_bad := v_bad || ' ' || r.sig; end if;
  end loop;
  if v_bad <> '' then raise exception 'booking_157 rollback: md5 ei täsmää:%', v_bad; end if;
  if to_regprocedure('booking.privacy_retention_run()') is not null then raise exception 'booking_157 rollback: privacy_retention_run jäi'; end if;
end $$;
