-- booking_32_talous_reports (17.10.2026): vaihe D – raportit kuittien snapshoteista (kassaperuste: kuitin antamispäivä Helsingin ajassa). Vaatii booking_31. Rollback: booking_32_ROLLBACK.sql
create function booking._category_label(p text) returns text language sql immutable set search_path = '' as $$
  select case p when 'treatment' then 'Hoidot' when 'ritual' then 'Rituaalit' when 'ceremony' then 'Seremoniat' when 'event' then 'Tapahtumat' when 'public_sauna' then 'Yleiset vuorot'
    when 'private_sauna' then 'Yksityiset vuorot' when 'corporate' then 'Yritysvuorot' when 'addon' then 'Lisäpalvelut' when 'product_rental' then 'Tuotteet ja vuokrat'
    when 'fee' then 'Maksut' when 'discount' then 'Alennukset' when 'gift_card' then 'Lahjakortit' when 'season_card' then 'Kausikortit' when 'reservation' then 'Varaukset' when 'other' then 'Muu' else coalesce(p, 'Muu') end
$$;
create function booking._report_check(p_full boolean) returns void language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_staff();
  if p_full then perform booking._require_permission('reports.view');
  elsif not (booking.has_permission('reports.daily') or booking.has_permission('reports.view')) then perform booking._err('forbidden', 'Ei oikeutta raportteihin'); end if;
end $$;

create function booking._report_json(p_from date, p_to date, p_receipts boolean, p_days boolean) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_res jsonb;
begin
  with rc as (
    select r.id, r.receipt_no, r.kind, r.issued_at, (r.issued_at at time zone 'Europe/Helsinki')::date as d, r.snapshot s, o.order_no,
           r.snapshot -> 'payment' ->> 'method' as method, coalesce(r.snapshot -> 'payment' ->> 'method_label', r.snapshot -> 'payment' ->> 'method') as mlabel,
           r.total_gross as gross, (r.snapshot ->> 'total_net')::numeric as net, (r.snapshot ->> 'total_vat')::numeric as vat, coalesce((r.snapshot ->> 'rounding')::numeric, 0) as rnd
      from booking.receipts r join booking.orders o on o.id = r.order_id
     where (r.issued_at at time zone 'Europe/Helsinki')::date between p_from and p_to
  ), tot as (
    select jsonb_build_object('receipts', count(*) filter (where kind = 'receipt'), 'refund_receipts', count(*) filter (where kind = 'refund_receipt'),
             'gross', coalesce(sum(gross) filter (where kind = 'receipt'), 0), 'net', coalesce(sum(net) filter (where kind = 'receipt'), 0), 'vat', coalesce(sum(vat) filter (where kind = 'receipt'), 0),
             'refunds_gross', coalesce(-sum(gross) filter (where kind = 'refund_receipt'), 0), 'net_after_refunds', coalesce(sum(gross), 0),
             'vat_after_refunds', coalesce(sum(vat), 0), 'net_ex_vat_after_refunds', coalesce(sum(net), 0), 'rounding', coalesce(sum(rnd), 0)) j from rc
  ), bm as (
    select coalesce(jsonb_agg(jsonb_build_object('method', method, 'label', label, 'payments', pc, 'gross', g, 'refunds', rf, 'rounding', rn) order by method), '[]'::jsonb) j from (
      select method, max(mlabel) label, count(*) filter (where kind = 'receipt') pc, coalesce(sum(gross) filter (where kind = 'receipt'), 0) g,
             coalesce(-sum(gross) filter (where kind = 'refund_receipt'), 0) rf, coalesce(sum(rnd), 0) rn from rc group by method) x
  ), bv as (
    select coalesce(jsonb_agg(jsonb_build_object('rate', rate, 'net', n, 'vat', v, 'gross', g) order by rate), '[]'::jsonb) j from (
      select (e ->> 'rate')::numeric rate, sum((e ->> 'net')::numeric) n, sum((e ->> 'vat')::numeric) v, sum((e ->> 'gross')::numeric) g from rc, jsonb_array_elements(rc.s -> 'vat') e group by 1) x
  ), bmv as (
    select coalesce(jsonb_agg(jsonb_build_object('method', method, 'rate', rate, 'net', n, 'vat', v, 'gross', g) order by method, rate), '[]'::jsonb) j from (
      select method, (e ->> 'rate')::numeric rate, sum((e ->> 'net')::numeric) n, sum((e ->> 'vat')::numeric) v, sum((e ->> 'gross')::numeric) g from rc, jsonb_array_elements(rc.s -> 'vat') e group by 1, 2) x
  ), bc as (
    select coalesce(jsonb_agg(jsonb_build_object('category', cat, 'label', booking._category_label(cat), 'rate', rate, 'quantity', q, 'gross', g, 'net', n, 'vat', g - n) order by cat, rate), '[]'::jsonb) j from (
      select l ->> 'category' cat, (l ->> 'vat_rate')::numeric rate, sum((l ->> 'quantity')::int * case when rc.kind = 'refund_receipt' then -1 else 1 end) q,
             sum((l ->> 'line_gross')::numeric) g, sum((l ->> 'line_net')::numeric) n from rc, jsonb_array_elements(rc.s -> 'lines') l group by 1, 2) x
  ), rl as (
    select case when p_receipts then coalesce(jsonb_agg(jsonb_build_object('receipt_no', receipt_no, 'kind', kind, 'issued_at', issued_at, 'order_no', order_no, 'method', method, 'gross', gross, 'net', net, 'vat', vat) order by issued_at, id), '[]'::jsonb) end j from rc
  ), bd as (
    select case when p_days then coalesce(jsonb_agg(jsonb_build_object('date', d, 'receipts', c, 'gross', g, 'vat', v, 'refunds', rf) order by d), '[]'::jsonb) end j from (
      select d, count(*) filter (where kind = 'receipt') c, coalesce(sum(gross) filter (where kind = 'receipt'), 0) g, coalesce(sum(vat), 0) v, coalesce(-sum(gross) filter (where kind = 'refund_receipt'), 0) rf from rc group by d) x
  ), op as (
    select jsonb_build_object('orders', count(*), 'unpaid', coalesce(sum(u), 0)) j from (
      select o.id, greatest(o.total_gross - coalesce((select sum(p.amount - p.refunded_amount) from booking.payments p where p.order_id = o.id and p.status in ('paid','partially_refunded','refunded')), 0), 0) u
        from booking.orders o where o.external_source is null and o.status = 'confirmed'
         and (select min(r.starts_at at time zone 'Europe/Helsinki')::date from booking.reservations r where r.order_id = o.id and r.status = 'confirmed') between p_from and p_to) y where u > 0
  ), ur as (
    select jsonb_build_object('payments', count(*), 'amount', coalesce(sum(p.amount), 0)) j from booking.payments p
     where p.external_source is null and p.status in ('paid','partially_refunded','refunded') and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to
       and not exists (select 1 from booking.receipts r where r.payment_id = p.id and r.kind = 'receipt')
  )
  select jsonb_build_object('period', jsonb_build_object('from', p_from, 'to', p_to, 'tz', 'Europe/Helsinki'), 'generated_at', now(), 'basis', 'cash (kuitin antamispäivä)',
         'totals', tot.j, 'by_method', bm.j, 'by_vat', bv.j, 'by_method_vat', bmv.j, 'by_category', bc.j, 'open', op.j, 'unreceipted', ur.j)
         || case when p_receipts then jsonb_build_object('receipts', rl.j) else '{}'::jsonb end
         || case when p_days then jsonb_build_object('by_day', bd.j) else '{}'::jsonb end
    into v_res from tot, bm, bv, bmv, bc, rl, bd, op, ur;
  return v_res;
end $$;

create function booking.admin_report_daily(p_date date) returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._report_check(false);
  if p_date is null then perform booking._err('invalid_param', 'Anna päivämäärä'); end if;
  return booking._report_json(p_date, p_date, true, false);
end $$;
create function booking.admin_report_month(p_ym text) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_from date;
begin
  perform booking._report_check(true);
  if p_ym is null or p_ym !~ '^\d{4}-(0[1-9]|1[0-2])$' then perform booking._err('invalid_param', 'Kuukausi muodossa YYYY-MM'); end if;
  v_from := (p_ym || '-01')::date;
  return booking._report_json(v_from, (v_from + interval '1 month' - interval '1 day')::date, false, true);
end $$;

create function booking._csv(p text) returns text language sql immutable set search_path = '' as $$
  select case when p ~ '[;"\r\n]' then '"' || replace(p, '"', '""') || '"' else coalesce(p, '') end
$$;
create function booking._csvnum(p numeric) returns text language sql immutable set search_path = '' as $$ select replace(trim_scale(round(p, 2))::text, '.', ',') $$;
create function booking._csvmoney(p numeric) returns text language sql immutable set search_path = '' as $$ select replace(to_char(round(p, 2), 'FM9999999990.00'), '.', ',') $$;

create function booking.admin_report_csv(p_from date, p_to date, p_kind text default 'lines') returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_body text; v_hdr text; v_cr text := E'\r\n';
begin
  perform booking._report_check(true);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then perform booking._err('invalid_param', 'Virheellinen aikaväli (enintään 366 päivää)'); end if;
  if p_kind not in ('lines','vat') then perform booking._err('invalid_param', 'p_kind: lines|vat'); end if;
  if p_kind = 'lines' then
    v_hdr := 'pvm;klo;kuitti;tilaus;tyyppi;maksutapa;tuoteryhma;tuote;maara;brutto;alv_prosentti;alv_eur;netto';
    select coalesce(string_agg(concat_ws(';', to_char(r.issued_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY'), to_char(r.issued_at at time zone 'Europe/Helsinki', 'HH24:MI'), r.receipt_no, o.order_no::text,
             case when r.kind = 'receipt' then 'kuitti' else 'hyvitys' end, booking._csv(r.snapshot -> 'payment' ->> 'method_label'), booking._csv(booking._category_label(l.e ->> 'category')),
             booking._csv(l.e ->> 'description'), ((l.e ->> 'quantity')::int * case when r.kind = 'refund_receipt' then -1 else 1 end)::text, booking._csvmoney((l.e ->> 'line_gross')::numeric),
             booking._csvnum((l.e ->> 'vat_rate')::numeric), booking._csvmoney((l.e ->> 'line_gross')::numeric - (l.e ->> 'line_net')::numeric), booking._csvmoney((l.e ->> 'line_net')::numeric)),
             v_cr order by r.issued_at, r.id, l.n), '') into v_body
      from booking.receipts r join booking.orders o on o.id = r.order_id, jsonb_array_elements(r.snapshot -> 'lines') with ordinality as l(e, n)
     where (r.issued_at at time zone 'Europe/Helsinki')::date between p_from and p_to;
  else
    v_hdr := 'pvm;kuitti;tilaus;tyyppi;maksutapa;alv_prosentti;netto;alv_eur;brutto';
    select coalesce(string_agg(concat_ws(';', to_char(r.issued_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY'), r.receipt_no, o.order_no::text, case when r.kind = 'receipt' then 'kuitti' else 'hyvitys' end,
             booking._csv(r.snapshot -> 'payment' ->> 'method_label'), booking._csvnum((v.e ->> 'rate')::numeric), booking._csvmoney((v.e ->> 'net')::numeric),
             booking._csvmoney((v.e ->> 'vat')::numeric), booking._csvmoney((v.e ->> 'gross')::numeric)), v_cr order by r.issued_at, r.id, v.n), '') into v_body
      from booking.receipts r join booking.orders o on o.id = r.order_id, jsonb_array_elements(r.snapshot -> 'vat') with ordinality as v(e, n)
     where (r.issued_at at time zone 'Europe/Helsinki')::date between p_from and p_to;
  end if;
  return jsonb_build_object('filename', format('kuitit_%s_%s_%s.csv', p_kind, p_from, p_to), 'mime', 'text/csv;charset=utf-8',
                            'content', chr(65279) || v_hdr || v_cr || v_body || case when v_body <> '' then v_cr else '' end);
end $$;

do $$ declare r record; begin
  for r in select p.oid::regprocedure as f, p.proname from pg_proc p where p.pronamespace = 'booking'::regnamespace
            and p.proname in ('_category_label','_report_check','_report_json','admin_report_daily','admin_report_month','_csv','_csvnum','_csvmoney','admin_report_csv') loop
    execute format('revoke all on function %s from public, anon, authenticated', r.f);
    execute format('grant execute on function %s to service_role', r.f);
    if r.proname like 'admin\_%' then execute format('grant execute on function %s to authenticated', r.f); end if;
  end loop;
end $$;
