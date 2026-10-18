-- booking_70_sales_chart (18.10.2026)
-- Talous-sivun myyntikäyrä: booking.admin_sales_chart(p_year) → 12 kuukautta, netto + ALV + erittelemätön brutto.
-- Vain luku. Ei taulumuutoksia. Ei korvaa admin_report_* / _report_json / admin_report_csv -funktioita.
--
-- Päiväperuste (sama kuin myyntiraportti, sopimus §5): kuitin antamispäivä Europe/Helsinki (receipts.issued_at). Ei käyntipäivä.
-- Johku-päivä: external_meta.johku.paid_at → booking._try_ts, Helsingin päivä (sama kuin statistics.johku).
--
-- Johku näkyy VAIN tässä funktiossa yhdistettynä kuukausisummiin. Raporttien totals/by_*/CSV/PDF/kuitit eivät muutu.
-- Päällekkäisyys: Johku-puoli ohittaa tilauksen, jolla on kuitti ja booking._acct_excluded on false.
--   Tuotannossa Johku-kuitin estää receipts_no_johku (BK001 johku_not_accounted), joten sama tilaus ei voi olla molemmissa.
--   Kahta erillistä tilausriviä (Johku-tuonti + uusi kirjaus samasta kaupasta) ei tunnisteta.
-- ALV Johkulle: brutto = johku.amount (jos ei lukua, orders.total_gross). Jos rivien line_total_gross > 0,
--   ALV = round(brutto * sum(line_vat) / sum(line_total_gross), 2), netto = brutto − ALV.
--   Muuten kantaa ei keksitä: unsplit_gross. Kokonaan hyvitetty (payment_status refunded) miinustetaan maksupäivän kuukauteen
--   (Johkussa ei ole erillistä hyvityspäivää). Osittain hyvitetty pysyy Johkun koko summassa (osahyvityksen määrä ei ole metassa).
-- Lahjakortit: vain kuitit, joita _acct_excluded ei sulje pois = sama joukko kuin raportin gross_after_refunds.
-- Oikeus: reports.view (manager, admin). Ei anonille.
-- Rollback: rollbacks/20261018190000_booking_70_ROLLBACK.sql

create or replace function booking.admin_sales_chart(p_year integer)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_from date;
  v_to date;
  v_res jsonb;
begin
  perform booking._require_staff();
  perform booking._require_permission('reports.view');
  if p_year is null or p_year < 2000 or p_year > 2100 then
    perform booking._err('invalid_param', 'Vuosi välillä 2000–2100');
  end if;
  v_from := make_date(p_year, 1, 1);
  v_to := make_date(p_year, 12, 31);

  with native as (
    select extract(month from (r.issued_at at time zone 'Europe/Helsinki'))::int as m,
           r.total_gross as gross,
           coalesce((r.snapshot ->> 'total_vat')::numeric, 0) as vat,
           coalesce((r.snapshot ->> 'total_net')::numeric, 0) as net
      from booking.receipts r
     where (r.issued_at at time zone 'Europe/Helsinki')::date between v_from and v_to
       and not booking._acct_excluded(r.order_id, r.payment_id)
  ), johku_src as (
    select o.id,
           (booking._try_ts(o.external_meta -> 'johku' ->> 'paid_at') at time zone 'Europe/Helsinki')::date as d,
           case when (o.external_meta -> 'johku' ->> 'amount') ~ '^-?[0-9]+(\.[0-9]+)?$'
                then (o.external_meta -> 'johku' ->> 'amount')::numeric
                else o.total_gross end as amt,
           o.payment_status as st
      from booking.orders o
     where (o.external_source = 'johku' or o.johku_order_no is not null or o.source_channel = 'johku_import')
       and o.payment_status in ('paid', 'partially_refunded', 'refunded')
       and not exists (
         select 1 from booking.receipts r
          where r.order_id = o.id
            and not booking._acct_excluded(r.order_id, r.payment_id)
       )
  ), johku as (
    select extract(month from j.d)::int as m,
           case when j.st = 'refunded' then -j.amt else j.amt end as signed,
           coalesce((select sum(i.line_total_gross) from booking.order_items i where i.order_id = j.id), 0) as lg,
           coalesce((select sum(i.line_vat) from booking.order_items i where i.order_id = j.id), 0) as lv
      from johku_src j
     where j.d between v_from and v_to
       and j.amt is not null
  ), native_m as (
    select m, coalesce(sum(net), 0) as net, coalesce(sum(vat), 0) as vat, coalesce(sum(gross), 0) as gross
      from native group by m
  ), johku_m as (
    select m,
           coalesce(sum(case when lg > 0 then signed - round(signed * lv / lg, 2) else 0 end), 0) as net,
           coalesce(sum(case when lg > 0 then round(signed * lv / lg, 2) else 0 end), 0) as vat,
           coalesce(sum(case when lg > 0 then signed else 0 end), 0) as split_gross,
           coalesce(sum(case when lg > 0 then 0 else signed end), 0) as unsplit
      from johku group by m
  ), months as (
    select gs.m,
           coalesce(n.net, 0) as native_net,
           coalesce(n.vat, 0) as native_vat,
           coalesce(n.gross, 0) as native_gross,
           coalesce(j.net, 0) as johku_net,
           coalesce(j.vat, 0) as johku_vat,
           coalesce(j.split_gross, 0) as johku_gross,
           coalesce(j.unsplit, 0) as unsplit_gross
      from generate_series(1, 12) as gs(m)
      left join native_m n on n.m = gs.m
      left join johku_m j on j.m = gs.m
  ), shaped as (
    select m, native_net, native_vat, native_gross, johku_net, johku_vat, johku_gross, unsplit_gross,
           native_net + johku_net as net,
           native_vat + johku_vat as vat,
           native_gross + johku_gross + unsplit_gross as gross
      from months
  ), yrs as (
    select y from (
      select extract(year from (r.issued_at at time zone 'Europe/Helsinki'))::int as y
        from booking.receipts r
       where not booking._acct_excluded(r.order_id, r.payment_id)
      union
      select extract(year from (booking._try_ts(o.external_meta -> 'johku' ->> 'paid_at') at time zone 'Europe/Helsinki'))::int
        from booking.orders o
       where (o.external_source = 'johku' or o.johku_order_no is not null or o.source_channel = 'johku_import')
         and o.payment_status in ('paid', 'partially_refunded', 'refunded')
         and booking._try_ts(o.external_meta -> 'johku' ->> 'paid_at') is not null
      union
      select extract(year from (now() at time zone 'Europe/Helsinki'))::int
    ) s
    where y between 2000 and 2100
  )
  select jsonb_build_object(
           'year', p_year,
           'tz', 'Europe/Helsinki',
           'basis', 'cash_receipt_issued_at',
           'johku_basis', 'johku_paid_at',
           'vat_method', 'order_item_rates_proportional',
           'generated_at', now(),
           'months', coalesce((select jsonb_agg(jsonb_build_object(
                      'month', m, 'native_net', native_net, 'native_vat', native_vat, 'native_gross', native_gross,
                      'johku_net', johku_net, 'johku_vat', johku_vat, 'johku_gross', johku_gross, 'unsplit_gross', unsplit_gross,
                      'net', net, 'vat', vat, 'gross', gross) order by m) from shaped), '[]'::jsonb),
           'totals', (select jsonb_build_object(
                      'native_net', coalesce(sum(native_net), 0), 'native_vat', coalesce(sum(native_vat), 0), 'native_gross', coalesce(sum(native_gross), 0),
                      'johku_net', coalesce(sum(johku_net), 0), 'johku_vat', coalesce(sum(johku_vat), 0), 'johku_gross', coalesce(sum(johku_gross), 0),
                      'unsplit_gross', coalesce(sum(unsplit_gross), 0),
                      'net', coalesce(sum(net), 0), 'vat', coalesce(sum(vat), 0), 'gross', coalesce(sum(gross), 0)) from shaped),
           'years', coalesce((select jsonb_agg(y order by y) from yrs), '[]'::jsonb))
    into v_res;
  return v_res;
end
$function$;

comment on function booking.admin_sales_chart(integer) is
  'Talous-myyntikäyrä (reports.view). Kuukausi = kuitin antamispäivä Helsinki + Johku paid_at. Johku ei siirry raportteihin. booking_70.';

revoke all on function booking.admin_sales_chart(integer) from public, anon, authenticated;
grant execute on function booking.admin_sales_chart(integer) to service_role;
grant execute on function booking.admin_sales_chart(integer) to authenticated;
