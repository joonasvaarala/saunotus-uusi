-- booking_219: suoriteperusteinen myynti ja saadut ennakot.
--
-- Kassaperuste (_report_json, kuitin antopäivä) säilyy. ALV ennakosta erääntyy maksupäivänä,
-- ja se raportti on sitä varten. Tämä raportti tulouttaa palvelun palvelupäivänä
-- (varauksen tai tapahtuman starts_at, Helsinki). Ilman aikaa (kassa, myymälä) palvelupäivä
-- on kuitin päivä. Lahjakortin myynti ei ole palvelumyyntiä: se on ennakko, kunnes kortti
-- lunastetaan tai vanhenee. Oman kortin ALV on kirjattu myynnissä (at_sale).
--
-- Hyvitys kohdistuu alkuperäisen rivin palvelupäivään (kuitin starts_at, muuten alkuperäinen
-- kuitti tai tilauksen varaus, muuten hyvityskuitin päivä).
-- Saadut ennakot päivänä D: maksettu viimeistään D ja palvelupäivä D:n jälkeen, miinus
-- siihen mennessä kirjatut hyvitykset. Käyttämätön oma lahjakorttisaldo on oma rivinsä.
-- Johku jää _acct_excluded-suodatuksen taakse, kuten muissakin kirjanpitoraporteissa.
-- Rollback: ../rollbacks/20261030120100_booking_219_ROLLBACK.sql

set local lock_timeout = '5s';

create or replace function booking._accrual_json(p_from date, p_to date, p_as_of date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v jsonb;
begin
  with raw as (
    select r.id as receipt_id, r.kind, r.issued_at, r.order_id, r.original_receipt_id,
           coalesce(l.elem ->> 'description', '') as product,
           coalesce(l.elem ->> 'kind', '') as line_kind,
           coalesce((l.elem ->> 'vat_rate')::numeric, 0) as rate,
           coalesce((l.elem ->> 'quantity')::numeric, 0) as qty,
           booking._snap_line_net(l.elem) as net,
           coalesce((l.elem ->> 'line_gross')::numeric, 0) as gross,
           (r.issued_at at time zone 'Europe/Helsinki')::date as issued_on,
           case
             when coalesce(l.elem ->> 'starts_at', '') ~ '^\d{4}-\d{2}-\d{2}'
               then ((l.elem ->> 'starts_at')::timestamptz at time zone 'Europe/Helsinki')::date
           end as line_day
      from booking.receipts r
      cross join lateral jsonb_array_elements(coalesce(r.snapshot -> 'lines', '[]'::jsonb)) as l(elem)
     where not booking._acct_excluded(r.order_id, r.payment_id)
  ), lined as (
    select raw.*,
           coalesce(
             raw.line_day,
             case when raw.kind = 'refund_receipt' then (
               select ((ol.elem ->> 'starts_at')::timestamptz at time zone 'Europe/Helsinki')::date
                 from booking.receipts orig
                 cross join lateral jsonb_array_elements(coalesce(orig.snapshot -> 'lines', '[]'::jsonb)) ol(elem)
                where orig.id = raw.original_receipt_id
                  and coalesce(ol.elem ->> 'starts_at', '') ~ '^\d{4}-\d{2}-\d{2}'
                  and coalesce(ol.elem ->> 'description', '') = raw.product
                limit 1
             ) end,
             (select min((rr.starts_at at time zone 'Europe/Helsinki')::date)
                from booking.reservations rr
               where rr.order_id = raw.order_id),
             raw.issued_on
           ) as service_on
      from raw
  ), svc as (
    select * from lined where line_kind is distinct from 'gift_card'
  ), sales as (
    select product, rate,
           sum(qty) as quantity,
           sum(net) as net,
           sum(gross - net) as vat,
           sum(gross) as gross
      from svc
     where kind = 'receipt' and service_on between p_from and p_to
     group by product, rate
  ), refs as (
    select product, rate,
           sum(abs(qty)) as quantity,
           sum(abs(net)) as net,
           sum(abs(gross - net)) as vat,
           sum(abs(gross)) as gross
      from svc
     where kind = 'refund_receipt' and service_on between p_from and p_to
     group by product, rate
  ), sales_vat as (
    select rate, sum(quantity) as quantity, sum(net) as net, sum(vat) as vat, sum(gross) as gross
      from sales group by rate
  ), refs_vat as (
    select rate, sum(quantity) as quantity, sum(net) as net, sum(vat) as vat, sum(gross) as gross
      from refs group by rate
  ), adv as (
    select rate,
           sum(net) as net,
           sum(gross - net) as vat,
           sum(gross) as gross,
           count(*) filter (where kind = 'receipt') as sale_lines
      from svc
     where issued_on <= p_as_of and service_on > p_as_of
     group by rate
  ), gc as (
    select count(*) filter (where bal > 0.004)::int as cards,
           coalesce(sum(bal) filter (where bal > 0.004), 0) as gross
      from (
        select coalesce((
                 select sum(l.delta)
                   from booking.gift_card_ledger l
                  where l.gift_card_id = g.id
                    and (l.at at time zone 'Europe/Helsinki')::date <= p_as_of
               ), 0) as bal
          from booking.gift_cards g
         where g.accounting_origin is distinct from 'johku'
           and g.source is distinct from 'johku'
           and g.external_source is distinct from 'johku'
           and coalesce(g.complimentary, false) = false
           and g.vat_treatment = 'at_sale'
           and (g.valid_to is null or g.valid_to >= p_as_of)
           and (coalesce(g.activated_at, g.created_at) at time zone 'Europe/Helsinki')::date <= p_as_of
      ) s
  )
  select jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to, 'tz', 'Europe/Helsinki',
                                 'kind', case when p_from = p_to then 'day' else 'range' end),
    'generated_at', now(),
    'basis', 'service (palvelupäivä, Europe/Helsinki)',
    'as_of', p_as_of,
    'sales_by_product', coalesce((
      select jsonb_agg(jsonb_build_object('product', product, 'rate', rate, 'quantity', quantity, 'net', net, 'vat', vat, 'gross', gross) order by product, rate)
        from sales), '[]'::jsonb),
    'sales_by_vat', coalesce((
      select jsonb_agg(jsonb_build_object('rate', rate, 'quantity', quantity, 'net', net, 'vat', vat, 'gross', gross) order by rate)
        from sales_vat), '[]'::jsonb),
    'refunds_by_product', coalesce((
      select jsonb_agg(jsonb_build_object('product', product, 'rate', rate, 'quantity', quantity, 'net', net, 'vat', vat, 'gross', gross) order by product, rate)
        from refs), '[]'::jsonb),
    'refunds_by_vat', coalesce((
      select jsonb_agg(jsonb_build_object('rate', rate, 'quantity', quantity, 'net', net, 'vat', vat, 'gross', gross) order by rate)
        from refs_vat), '[]'::jsonb),
    'totals', jsonb_build_object(
      'sales_net', coalesce((select sum(net) from sales), 0),
      'sales_vat', coalesce((select sum(vat) from sales), 0),
      'sales_gross', coalesce((select sum(gross) from sales), 0),
      'refunds_net', coalesce((select sum(net) from refs), 0),
      'refunds_vat', coalesce((select sum(vat) from refs), 0),
      'refunds_gross', coalesce((select sum(gross) from refs), 0),
      'net', coalesce((select sum(net) from sales), 0) - coalesce((select sum(net) from refs), 0),
      'vat', coalesce((select sum(vat) from sales), 0) - coalesce((select sum(vat) from refs), 0),
      'gross', coalesce((select sum(gross) from sales), 0) - coalesce((select sum(gross) from refs), 0)
    ),
    'advances', jsonb_build_object(
      'as_of', p_as_of,
      'services', jsonb_build_object(
        'net', coalesce((select sum(net) from adv), 0),
        'vat', coalesce((select sum(vat) from adv), 0),
        'gross', coalesce((select sum(gross) from adv), 0),
        'lines', coalesce((select sum(sale_lines) from adv), 0),
        'by_vat', coalesce((
          select jsonb_agg(jsonb_build_object('rate', rate, 'net', net, 'vat', vat, 'gross', gross) order by rate)
            from adv), '[]'::jsonb)
      ),
      'gift_cards_unused', jsonb_build_object(
        'count', (select cards from gc),
        'gross', (select gross from gc),
        'vat', round((select gross from gc) * 25.5 / 125.5, 2),
        'net', (select gross from gc) - round((select gross from gc) * 25.5 / 125.5, 2),
        'rate', 25.5,
        'vat_at_sale', true
      ),
      'total_gross', coalesce((select sum(gross) from adv), 0) + (select gross from gc)
    )
  ) into v;
  return v;
end $$;

create or replace function booking.admin_report_accrual(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform booking._report_check(p_from is distinct from p_to);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    perform booking._err('invalid_param', 'Virheellinen aikaväli (enintään 366 päivää)');
  end if;
  return booking._accrual_json(p_from, p_to, p_to);
end $$;

create or replace function booking.admin_report_accrual_csv(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_body text := '';
  v_cr text := E'\r\n';
  rep jsonb;
  el jsonb;
  g jsonb;
begin
  perform booking._report_check(true);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    perform booking._err('invalid_param', 'Virheellinen aikaväli (enintään 366 päivää)');
  end if;
  rep := booking._accrual_json(p_from, p_to, p_to);
  for el in select value from jsonb_array_elements(rep -> 'sales_by_product') loop
    v_body := v_body || concat_ws(';', 'myynti', booking._csv(el ->> 'product'), booking._csvnum((el ->> 'rate')::numeric),
      booking._csvnum((el ->> 'quantity')::numeric), booking._csvmoney((el ->> 'net')::numeric),
      booking._csvmoney((el ->> 'vat')::numeric), booking._csvmoney((el ->> 'gross')::numeric)) || v_cr;
  end loop;
  for el in select value from jsonb_array_elements(rep -> 'refunds_by_product') loop
    v_body := v_body || concat_ws(';', 'hyvitys', booking._csv(el ->> 'product'), booking._csvnum((el ->> 'rate')::numeric),
      booking._csvnum((el ->> 'quantity')::numeric), booking._csvmoney((el ->> 'net')::numeric),
      booking._csvmoney((el ->> 'vat')::numeric), booking._csvmoney((el ->> 'gross')::numeric)) || v_cr;
  end loop;
  for el in select value from jsonb_array_elements(rep -> 'sales_by_vat') loop
    v_body := v_body || concat_ws(';', 'alv_myynti', '', booking._csvnum((el ->> 'rate')::numeric),
      booking._csvnum((el ->> 'quantity')::numeric), booking._csvmoney((el ->> 'net')::numeric),
      booking._csvmoney((el ->> 'vat')::numeric), booking._csvmoney((el ->> 'gross')::numeric)) || v_cr;
  end loop;
  for el in select value from jsonb_array_elements(rep -> 'refunds_by_vat') loop
    v_body := v_body || concat_ws(';', 'alv_hyvitys', '', booking._csvnum((el ->> 'rate')::numeric),
      booking._csvnum((el ->> 'quantity')::numeric), booking._csvmoney((el ->> 'net')::numeric),
      booking._csvmoney((el ->> 'vat')::numeric), booking._csvmoney((el ->> 'gross')::numeric)) || v_cr;
  end loop;
  for el in select value from jsonb_array_elements(rep -> 'advances' -> 'services' -> 'by_vat') loop
    v_body := v_body || concat_ws(';', 'ennakko', 'Saadut ennakot', booking._csvnum((el ->> 'rate')::numeric), '',
      booking._csvmoney((el ->> 'net')::numeric), booking._csvmoney((el ->> 'vat')::numeric),
      booking._csvmoney((el ->> 'gross')::numeric)) || v_cr;
  end loop;
  g := rep -> 'advances' -> 'gift_cards_unused';
  v_body := v_body || concat_ws(';', 'ennakko', 'Lahjakortit kayttamatta', booking._csvnum(25.5),
    booking._csvnum(coalesce((g ->> 'count')::numeric, 0)),
    booking._csvmoney(coalesce((g ->> 'net')::numeric, 0)),
    booking._csvmoney(coalesce((g ->> 'vat')::numeric, 0)),
    booking._csvmoney(coalesce((g ->> 'gross')::numeric, 0))) || v_cr;
  v_body := v_body || concat_ws(';', 'ennakko', 'Saadut ennakot yhteensa', '', '', '', '',
    booking._csvmoney(coalesce((rep #>> '{advances,total_gross}')::numeric, 0))) || v_cr;
  return jsonb_build_object(
    'filename', format('suorite_%s_%s.csv', p_from, p_to),
    'mime', 'text/csv;charset=utf-8',
    'content', chr(65279) || 'osio;tuote;alv_%;maara;netto;alv_eur;brutto' || v_cr || v_body
  );
end $$;

revoke all on function booking._accrual_json(date, date, date) from public, anon, authenticated;
grant execute on function booking._accrual_json(date, date, date) to service_role;
revoke all on function booking.admin_report_accrual(date, date) from public, anon, authenticated;
grant execute on function booking.admin_report_accrual(date, date) to authenticated, service_role;
revoke all on function booking.admin_report_accrual_csv(date, date) from public, anon, authenticated;
grant execute on function booking.admin_report_accrual_csv(date, date) to authenticated, service_role;

comment on function booking.admin_report_accrual(date, date) is
  'booking_219: suoriteperuste (palvelupäivä) ja saadut ennakot jakson lopussa. Päivä = reports.daily tai reports.view, pidempi jakso = reports.view. Enintään 366 päivää.';
comment on function booking.admin_report_accrual_csv(date, date) is
  'booking_219: suorite-CSV, sama erotin, BOM ja rivinvaihto kuin admin_report_csv. Vain reports.view.';
