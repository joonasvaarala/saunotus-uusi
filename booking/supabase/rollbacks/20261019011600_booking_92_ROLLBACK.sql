-- ROLLBACK booking_92_invoice_checkout.
-- Palauttaa _clean_company (booking_11), public_payment_options (booking_57) ja admin_list_orders (booking_76).
set local lock_timeout = '5s';
drop trigger if exists orders_invoice_draft on booking.orders;
drop trigger if exists orders_invoice_status on booking.orders;
drop function if exists booking.admin_create_invoice_from_order(bigint);
drop function if exists booking.orders_invoice_draft_trg();
drop function if exists booking.orders_invoice_status_trg();
drop function if exists booking._ensure_draft_invoice(bigint);

create or replace function booking._clean_company(p jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare
  v_name text := btrim(coalesce(p ->> 'company_name', p ->> 'name', ''));
  v_bid text := booking._norm_business_id(p ->> 'business_id');
  v_street text := btrim(coalesce(p ->> 'street', p ->> 'address', ''));
  v_zip text := btrim(coalesce(p ->> 'zip', ''));
  v_city text := btrim(coalesce(p ->> 'city', ''));
  v_country text := upper(btrim(coalesce(nullif(p ->> 'country', ''), 'FI')));
  v_ei text := upper(regexp_replace(coalesce(p ->> 'einvoice_address', ''), '\s', '', 'g'));
  v_op text := upper(regexp_replace(coalesce(p ->> 'einvoice_operator', ''), '\s', '', 'g'));
  v_ref text := btrim(coalesce(p ->> 'reference', ''));
begin
  if p is null or jsonb_typeof(p) <> 'object' then perform booking._err('invalid_company', 'Anna yrityksen tiedot'); end if;
  if char_length(v_name) < 2 or char_length(v_name) > 200 then perform booking._err('invalid_company_name', 'Anna yrityksen nimi'); end if;
  if v_bid is null or not booking._business_id_ok(v_bid) then perform booking._err('invalid_business_id', 'Tarkista y-tunnus (muoto 1234567-8)'); end if;
  if char_length(v_street) < 2 or char_length(v_street) > 200 then perform booking._err('invalid_address', 'Anna yrityksen katuosoite'); end if;
  if v_country !~ '^[A-Z]{2}$' then perform booking._err('invalid_country', 'Tarkista maa (kaksikirjaiminen koodi, esim. FI)'); end if;
  if (v_country = 'FI' and v_zip !~ '^\d{5}$') or (v_country <> 'FI' and v_zip !~ '^[A-Za-z0-9 -]{2,12}$') then perform booking._err('invalid_zip', 'Tarkista postinumero'); end if;
  if char_length(v_city) < 2 or char_length(v_city) > 100 then perform booking._err('invalid_city', 'Anna postitoimipaikka'); end if;
  if v_ei <> '' and v_ei !~ '^[A-Z0-9]{6,35}$' then perform booking._err('invalid_einvoice_address', 'Tarkista verkkolaskuosoite / OVT-tunnus'); end if;
  if v_op <> '' and v_op !~ '^[A-Z0-9]{3,35}$' then perform booking._err('invalid_einvoice_operator', 'Tarkista verkkolaskuoperaattorin välittäjätunnus'); end if;
  if (v_ei = '') <> (v_op = '') then perform booking._err('einvoice_incomplete', 'Anna sekä verkkolaskuosoite että operaattorin välittäjätunnus (tai kumpikaan)'); end if;
  if char_length(v_ref) > 100 then perform booking._err('invalid_reference', 'Viite on liian pitkä (enintään 100 merkkiä)'); end if;
  return jsonb_build_object('company_name', v_name, 'business_id', v_bid, 'street', v_street, 'zip', v_zip, 'city', v_city, 'country', v_country,
                            'einvoice_address', nullif(v_ei, ''), 'einvoice_operator', nullif(v_op, ''), 'reference', nullif(v_ref, ''));
end $$;

CREATE OR REPLACE FUNCTION booking.public_payment_options(p_token uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_mode text := booking._mobilepay_mode(); o booking.orders; v_unpaid numeric; v_can boolean := false; v_methods jsonb := '[]'::jsonb; v_order jsonb := null; v_pending boolean := false;
begin
  if v_mode <> 'off' then
    v_methods := jsonb_build_array(jsonb_build_object('code', 'mobilepay', 'provider', 'vipps_mobilepay', 'label', 'MobilePay', 'label_en', 'MobilePay', 'test', v_mode = 'test',
      'start', jsonb_build_object('function', 'mobilepay-start', 'method', 'POST', 'body', case when p_token is not null then jsonb_build_object('order_token', p_token) else '{}'::jsonb end)));
  end if;
  if p_token is null and booking._pay_later_test_enabled() then v_methods := v_methods || jsonb_build_array(booking._pay_later_method_json()); end if;   -- booking_57
  if p_token is not null then
    if not booking._order_rl('popt', p_token, 120, 60) then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;
    select * into o from booking.orders where public_token = p_token;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
    v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
    v_can := v_mode <> 'off' and o.external_source is null and o.status in ('pending', 'confirmed', 'completed', 'expired') and o.currency = 'EUR' and v_unpaid > 0.004 and not (o.status = 'pending' and o.hold_kind = 'preliminary');
    v_pending := exists (select 1 from booking.payments where order_id = o.id and provider = 'mobilepay' and status = 'pending' and (link_expires_at is null or link_expires_at > now()));
    v_order := jsonb_build_object('order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status, 'unpaid', v_unpaid, 'can_pay_online', v_can, 'mobilepay_pending', v_pending) || booking._checkout_state_json(o.id);
    if not v_can then v_methods := '[]'::jsonb; end if;
    -- booking_57: 'maksa myöhemmin' (testi) vain kun lippu päällä, tilaus ei ole ulkoinen ja odottaa maksua (pito käynnissä, ei maksu kesken)
    if booking._pay_later_test_enabled() and o.external_source is null and v_order ->> 'checkout_state' = 'awaiting_payment' then
      v_methods := v_methods || jsonb_build_array(booking._pay_later_method_json());
    end if;
  end if;
  return jsonb_build_object('ok', true, 'online_enabled', v_mode <> 'off', 'methods', v_methods, 'order', v_order);
end $function$;


create or replace function booking.admin_list_orders(
  p_search text default null,
  p_status text default null,
  p_payment_status text default null,
  p_source text default null,
  p_native boolean default null,
  p_date_field text default 'created',
  p_from date default null,
  p_to date default null,
  p_sort text default 'created_desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_payment_filter text default 'paid'
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_s text := nullif(btrim(coalesce(p_search, '')), '');
  v_num bigint;
  v_like text;
  v_total int;
  v_rows jsonb;
  v_lim int := coalesce(p_limit, 50);
  v_off int := greatest(coalesce(p_offset, 0), 0);
  v_pf text := coalesce(nullif(btrim(p_payment_filter), ''), 'paid');
begin
  perform booking._require_staff();
  if p_sort is null or p_sort not in ('created_desc','created_asc','order_no_desc','order_no_asc','total_desc','total_asc','start_desc','start_asc','paid_desc','paid_asc','unpaid_desc') then
    perform booking._err('invalid_sort', 'Tuntematon lajittelu'); end if;
  if v_lim < 1 or v_lim > 200 then perform booking._err('invalid_param', 'p_limit 1–200'); end if;
  if coalesce(p_date_field, 'created') not in ('created','start') then perform booking._err('invalid_param', 'p_date_field: created|start'); end if;
  if v_pf not in ('paid','unpaid','all','refunded','cancelled') then
    perform booking._err('invalid_param', 'p_payment_filter: paid|unpaid|all|refunded|cancelled'); end if;
  if v_s ~ '^\d{1,12}$' then v_num := v_s::bigint; end if;
  if v_s is not null then v_like := '%' || replace(replace(replace(v_s, '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;
  with base as (
    select o.id, o.order_no, o.johku_order_no, o.created_at, o.status, o.payment_status, o.source_channel, (o.external_source is null) as is_native, o.total_gross,
           pp.paid, pp.refunded, pp.pc, pp.lp, rr.fs, rr.le, rr.cnt, rcc.rc,
           case when o.status in ('cancelled','expired','draft') then 0 else greatest(o.total_gross - (pp.paid - pp.refunded), 0) end as unpaid,
           c.id as cid, c.name as cname, c.company as ccompany, o.customer_kind
      from booking.orders o
      left join booking.customers c on c.id = o.customer_id
      left join lateral (select min(r.starts_at) fs, max(r.ends_at) le, count(*) cnt from booking.reservations r where r.order_id = o.id and r.hidden_at is null) rr on true
      left join lateral (select coalesce(sum(p.amount) filter (where p.status in ('paid','partially_refunded','refunded')), 0) paid, coalesce(sum(p.refunded_amount), 0) refunded,
                                count(*) filter (where p.status in ('paid','partially_refunded','refunded')) pc, max(p.paid_at) lp
                           from booking.payments p where p.order_id = o.id) pp on true
      left join lateral (select count(*) rc from booking.receipts x where x.order_id = o.id) rcc on true
     where (p_status is null or o.status = p_status)
       and (p_payment_status is null or o.payment_status = p_payment_status)
       and (p_source is null or o.source_channel = p_source)
       and (p_native is null or (o.external_source is null) = p_native)
       and (v_s is null or (v_num is not null and (o.order_no = v_num or o.johku_order_no = v_num))
            or (v_num is null and (c.name ilike v_like or c.email ilike v_like or c.phone ilike v_like or c.company ilike v_like)))
       and (p_from is null or case when coalesce(p_date_field, 'created') = 'created' then (o.created_at at time zone 'Europe/Helsinki')::date else (rr.fs at time zone 'Europe/Helsinki')::date end >= p_from)
       and (p_to   is null or case when coalesce(p_date_field, 'created') = 'created' then (o.created_at at time zone 'Europe/Helsinki')::date else (rr.fs at time zone 'Europe/Helsinki')::date end <= p_to)
       and case v_pf
             when 'all' then true
             when 'paid' then o.payment_status in ('paid','partially_refunded')
               and o.status not in ('cancelled','expired')
               and (case when pp.pc > 0 then pp.paid - pp.refunded
                         when o.payment_status in ('paid','partially_refunded') then o.total_gross
                         else 0 end) > 0.004
             when 'unpaid' then o.payment_status in ('unpaid','pending','failed','partially_paid')
               and o.status not in ('cancelled','expired')
             when 'refunded' then o.payment_status in ('refunded','partially_refunded')
             when 'cancelled' then o.status in ('cancelled','expired')
             else false
           end
  ), page as (
    select b.*, row_number() over (order by
        case when p_sort = 'created_asc' then b.created_at end asc, case when p_sort = 'created_desc' then b.created_at end desc,
        case when p_sort = 'order_no_asc' then b.order_no end asc, case when p_sort = 'order_no_desc' then b.order_no end desc,
        case when p_sort = 'total_asc' then b.total_gross end asc, case when p_sort = 'total_desc' then b.total_gross end desc,
        case when p_sort = 'start_asc' then b.fs end asc nulls last, case when p_sort = 'start_desc' then b.fs end desc nulls last,
        case when p_sort = 'paid_asc' then b.lp end asc nulls last, case when p_sort = 'paid_desc' then b.lp end desc nulls last,
        case when p_sort = 'unpaid_desc' then b.unpaid end desc, b.id desc) as rn
      from base b
  )
  select (select count(*) from base),
         coalesce(jsonb_agg(jsonb_build_object('order_id', p.id, 'order_no', p.order_no, 'johku_order_no', p.johku_order_no, 'created_at', p.created_at, 'status', p.status,
           'payment_status', p.payment_status, 'source_channel', p.source_channel, 'is_native', p.is_native, 'total', p.total_gross, 'paid', p.paid, 'refunded', p.refunded,
           'unpaid', p.unpaid, 'customer_id', p.cid, 'customer_name', p.cname, 'customer_company', p.ccompany, 'customer_kind', p.customer_kind, 'first_start', p.fs, 'last_end', p.le,
           'reservation_count', p.cnt, 'payment_count', p.pc, 'last_paid_at', p.lp, 'receipt_count', p.rc) order by p.rn), '[]'::jsonb)
    into v_total, v_rows from page p where p.rn > v_off and p.rn <= v_off + v_lim;
  return jsonb_build_object('total', v_total, 'rows', v_rows);
end $function$;

comment on function booking.admin_list_orders(text, text, text, text, boolean, text, date, date, text, integer, integer, text) is
  'Talous-tilauslista. p_payment_filter oletus paid (paid|partially_refunded, netto>0, ei cancelled/expired). all = koko kanta. booking_76.';

