-- ============================================================
-- booking_44_ROLLBACK: lahjakorttien RPC:t pois, muutetut funktiot takaisin booking_42-tilaan
-- Ajetaan ENNEN booking_43_ROLLBACK.sql. Turvatarkistus: ei natiiveja kortteja/ledger-rivejä natiiveille (jotta rahaa kuvaava data ei katoa huomaamatta).
-- ============================================================
do $$ begin
  if exists (select 1 from booking.gift_cards where source = 'native') then
    raise exception 'ROLLBACK ESTETTY: natiiveja lahjakortteja on % kpl. Tyhjennä tai arkistoi ne ensin (tämä rollback ei poista rahadataa).', (select count(*) from booking.gift_cards where source = 'native');
  end if;
  if exists (select 1 from booking.payments where method = 'gift_card') then
    raise exception 'ROLLBACK ESTETTY: lahjakorttimaksuja on olemassa (payments.method = gift_card)';
  end if;
end $$;

-- ajastus pois
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'booking_gift_cards_housekeeping';
  end if;
exception when others then raise notice 'cron-poisto ohitettu: %', sqlerrm;
end $$;

drop trigger if exists orders_gc_paid on booking.orders;
drop trigger if exists orders_gc_cancel on booking.orders;

-- muutetut funktiot takaisin tuotantomääritelmiin (booking_41/42)
CREATE OR REPLACE FUNCTION booking._acct_excluded(p_order_id bigint, p_payment_id bigint DEFAULT NULL::bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((select true from booking.orders o
                    where o.id = coalesce(p_order_id, (select p.order_id from booking.payments p where p.id = p_payment_id))
                      and (o.external_source is not null or o.johku_order_no is not null or o.source_channel = 'johku_import')), false)
      or coalesce((select true from booking.payments p where p.id = p_payment_id and p.external_source is not null), false)
$function$;
comment on function booking._acct_excluded(bigint, bigint) is 'true = Johku-lähtöinen tilaus/maksu: ei kuitteihin, kirjanpitoraportteihin eikä accounting_outboxiin (booking_41)';
CREATE OR REPLACE FUNCTION booking.admin_refund(p_payment_id bigint, p_amount numeric, p_reason text, p_lines jsonb DEFAULT NULL::jsonb, p_manual_done boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pay booking.payments; o booking.orders; v_cap numeric; v_mode text; v_online boolean; v_id bigint; l jsonb; v_pl booking.payment_lines; v_sum numeric := 0; v_full boolean;
        r record; v_total_cap numeric; v_alloc numeric; v_left numeric; v_alloc_json jsonb := '[]'::jsonb; v_status text; rc record; v_n int; v_i int := 0;
begin
  perform booking._require_permission('payments.refund');
  select * into pay from booking.payments where id = p_payment_id for update;
  if not found then perform booking._err('not_found', 'Maksua ei löydy'); end if;
  select * into o from booking.orders where id = pay.order_id for update;
  if o.external_source is not null or pay.external_source is not null then perform booking._err('order_not_editable', 'Johku-historian maksuja ei voi hyvittää tässä'); end if;
  if pay.status = 'refunded' then perform booking._err('already_refunded', 'Maksu on jo hyvitetty kokonaan'); end if;
  if pay.status not in ('paid','partially_refunded') then perform booking._err('refund_not_allowed', 'Vain maksettu maksu voidaan hyvittää'); end if;
  if p_reason is null or char_length(btrim(p_reason)) < 3 or char_length(p_reason) > 500 then perform booking._err('invalid_param', 'Anna hyvityksen syy (3–500 merkkiä)'); end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  v_cap := pay.amount - pay.refunded_amount - coalesce((select sum(f.amount) from booking.refunds f where f.payment_id = pay.id and f.status in ('requested','processing')), 0);
  if p_amount > v_cap + 0.004 then perform booking._err('amount_exceeds_refundable', format('Hyvitettävissä enintään %s €', v_cap)); end if;
  v_online := pay.provider <> 'manual';
  select mode into v_mode from booking.integration_config where key = replace(pay.provider, '_', '');
  if v_online and coalesce(v_mode, 'off') = 'off' then
    if not p_manual_done then perform booking._err('refund_not_allowed', 'Verkkomaksun hyvitys ei ole vielä käytössä – hyvitä Visman portaalissa ja kirjaa käsin (vain admin)'); end if;
    if booking.current_staff_role() is distinct from 'admin' then perform booking._err('forbidden', 'Käsinkirjaus verkkomaksulle vaatii admin-roolin'); end if;
  end if;
  v_full := abs(p_amount - v_cap) < 0.005 and pay.refunded_amount = 0;

  -- rivijako
  if p_lines is not null then
    if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then perform booking._err('invalid_items', 'p_lines väärässä muodossa'); end if;
    for l in select * from jsonb_array_elements(p_lines) loop
      if coalesce(l ->> 'payment_line_id', '') !~ '^\d{1,18}$' or coalesce(l ->> 'amount', '') !~ '^\d{1,6}(\.\d{1,2})?$' then perform booking._err('invalid_items', 'Rivi virheellinen'); end if;
      select * into v_pl from booking.payment_lines where id = (l ->> 'payment_line_id')::bigint and payment_id = pay.id;
      if not found then perform booking._err('item_not_found', 'Maksun riviä ei löydy'); end if;
      if (l ->> 'amount')::numeric <= 0 or (l ->> 'amount')::numeric > v_pl.amount_gross - v_pl.refunded_gross + 0.004 then perform booking._err('amount_exceeds_refundable', 'Rivin hyvitys ylittää hyvitettävissä olevan'); end if;
      v_alloc_json := v_alloc_json || jsonb_build_object('payment_line_id', v_pl.id, 'amount', (l ->> 'amount')::numeric);
      v_sum := v_sum + (l ->> 'amount')::numeric;
    end loop;
    if abs(v_sum - p_amount) > 0.004 then perform booking._err('invalid_items', 'Rivien summa ei vastaa hyvityksen summaa'); end if;
  elsif v_full then
    select coalesce(jsonb_agg(jsonb_build_object('payment_line_id', id, 'amount', amount_gross - refunded_gross) order by id), '[]'::jsonb) into v_alloc_json
      from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross <> 0;
  else   -- suhteessa positiivisten rivien hyvitettävään osuuteen
    select coalesce(sum(amount_gross - refunded_gross), 0) into v_total_cap from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross > 0;
    if v_total_cap < p_amount - 0.004 then perform booking._err('invalid_items', 'Anna rivijako (p_lines)'); end if;
    v_left := p_amount; select count(*) into v_n from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross > 0;
    for r in select id, amount_gross - refunded_gross as cap from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross > 0 order by id loop
      v_i := v_i + 1;
      v_alloc := case when v_i = v_n then v_left else least(round(p_amount * r.cap / v_total_cap, 2), r.cap) end;
      v_alloc := least(v_alloc, r.cap, v_left);
      if v_alloc > 0 then v_alloc_json := v_alloc_json || jsonb_build_object('payment_line_id', r.id, 'amount', v_alloc); v_left := v_left - v_alloc; end if;
    end loop;
    if v_left > 0.004 then perform booking._err('invalid_items', 'Anna rivijako (p_lines)'); end if;
  end if;

  v_status := case when v_online and coalesce(v_mode, 'off') <> 'off' then 'requested' else 'done' end;
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, provider_status, lines, created_by, done_at)
  values (pay.id, pay.order_id, p_amount, btrim(p_reason), v_status, case when v_online and v_status = 'requested' then pay.provider else 'manual' end,
          case when v_online and v_status = 'done' then 'manual_done' end, v_alloc_json, auth.uid(), case when v_status = 'done' then now() end) returning id into v_id;
  if v_status = 'done' then
    update booking.payment_lines pl set refunded_gross = pl.refunded_gross + (x ->> 'amount')::numeric
      from jsonb_array_elements(v_alloc_json) x where pl.id = (x ->> 'payment_line_id')::bigint;
    update booking.payments set refunded_amount = refunded_amount + p_amount,
           status = case when refunded_amount + p_amount >= amount then 'refunded' else 'partially_refunded' end where id = pay.id;
    perform booking._sync_placeholder(pay.order_id);
    perform booking._refresh_order_payment(pay.order_id);
    perform booking._on_refund_done(v_id);
  end if;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'refunds', v_id::text, 'ADMIN_REFUND', null, jsonb_build_object('payment_id', pay.id, 'amount', p_amount, 'reason', p_reason, 'status', v_status));
  select id, receipt_no into rc from booking.receipts where refund_id = v_id;
  return jsonb_build_object('ok', true, 'refund_id', v_id, 'status', v_status, 'balance', booking._order_balance(pay.order_id), 'receipt_id', rc.id, 'receipt_no', rc.receipt_no);
end $function$;
CREATE OR REPLACE FUNCTION booking.admin_list_payments(p_search text DEFAULT NULL::text, p_method text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_sort text DEFAULT 'paid_desc'::text, p_include_placeholders boolean DEFAULT false, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_s text := nullif(btrim(coalesce(p_search, '')), ''); v_num bigint; v_like text; v_total int; v_rows jsonb; v_sp numeric; v_sr numeric; v_spx numeric; v_srx numeric; v_jn int; v_lim int := coalesce(p_limit, 50); v_off int := greatest(coalesce(p_offset, 0), 0);
begin
  perform booking._require_staff();
  if p_sort is null or p_sort not in ('paid_desc','paid_asc','amount_desc','amount_asc','order_no_desc','order_no_asc') then perform booking._err('invalid_sort', 'Tuntematon lajittelu'); end if;
  if v_lim < 1 or v_lim > 200 then perform booking._err('invalid_param', 'p_limit 1–200'); end if;
  if v_s ~ '^\d{1,12}$' then v_num := v_s::bigint; end if;
  if v_s is not null then v_like := '%' || replace(replace(replace(v_s, '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;
  with base as (
    select p.id, p.order_id, o.order_no, p.method, pm.label as mlabel, p.provider, p.status, p.amount, p.refunded_amount, p.rounding, p.paid_at, p.created_at,
           c.name as cname, (select count(*) from booking.payment_lines pl where pl.payment_id = p.id) as lc,
           rc.receipt_no, rc.public_token as rtoken, coalesce(p.paid_at, p.created_at) as ts, booking._acct_excluded(p.order_id, p.id) as jk
      from booking.payments p join booking.orders o on o.id = p.order_id
      left join booking.customers c on c.id = o.customer_id left join booking.payment_methods pm on pm.code = p.method
      left join lateral (select x.receipt_no, x.public_token from booking.receipts x where x.payment_id = p.id and x.kind = 'receipt' limit 1) rc on true
     where (p_method is null or p.method = p_method) and (p_status is null or p.status = p_status)
       and (p_include_placeholders or not (p.provider = 'manual' and p.status = 'pending' and p.external_source is null
                                           and not exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id)))
       and (p_from is null or (coalesce(p.paid_at, p.created_at) at time zone 'Europe/Helsinki')::date >= p_from)
       and (p_to is null or (coalesce(p.paid_at, p.created_at) at time zone 'Europe/Helsinki')::date <= p_to)
       and (v_s is null or (v_num is not null and (o.order_no = v_num or p.id = v_num)) or rc.receipt_no ilike v_like or (v_num is null and (c.name ilike v_like or c.email ilike v_like)))
  ), page as (
    select b.*, row_number() over (order by
       case when p_sort = 'paid_asc' then b.ts end asc, case when p_sort = 'paid_desc' then b.ts end desc,
       case when p_sort = 'amount_asc' then b.amount end asc, case when p_sort = 'amount_desc' then b.amount end desc,
       case when p_sort = 'order_no_asc' then b.order_no end asc, case when p_sort = 'order_no_desc' then b.order_no end desc, b.id desc) rn from base b)
  select (select count(*) from base),
         (select coalesce(sum(amount) filter (where status in ('paid','partially_refunded','refunded')), 0) from base),
         (select coalesce(sum(refunded_amount), 0) from base),
         (select coalesce(sum(amount) filter (where status in ('paid','partially_refunded','refunded') and not jk), 0) from base),
         (select coalesce(sum(refunded_amount) filter (where not jk), 0) from base),
         (select count(*) from base where jk),
         coalesce(jsonb_agg(jsonb_build_object('payment_id', p.id, 'order_id', p.order_id, 'order_no', p.order_no, 'method', p.method, 'method_label', p.mlabel, 'provider', p.provider,
           'status', p.status, 'amount', p.amount, 'refunded_amount', p.refunded_amount, 'rounding', p.rounding, 'paid_at', p.paid_at, 'created_at', p.created_at,
           'customer_name', p.cname, 'line_count', p.lc, 'receipt_no', p.receipt_no, 'receipt_token', p.rtoken,
           'source', case when p.jk then 'johku' else 'native' end, 'is_johku', p.jk) order by p.rn), '[]'::jsonb)
    into v_total, v_sp, v_sr, v_spx, v_srx, v_jn, v_rows from page p where p.rn > v_off and p.rn <= v_off + v_lim;
  return jsonb_build_object('total', v_total, 'sum_paid', v_sp, 'sum_refunded', v_sr, 'sum_paid_ex_johku', v_spx, 'sum_refunded_ex_johku', v_srx, 'johku_rows', v_jn, 'rows', v_rows);
end $function$;
comment on function booking.admin_list_payments(text, text, text, date, date, text, boolean, integer, integer) is 'Maksulista ilman laskurivejä (kevyt lista); rivit haetaan admin_get_order():sta. Tarkoituksellinen.';
CREATE OR REPLACE FUNCTION booking._report_json(p_from date, p_to date, p_receipts boolean, p_days boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_res jsonb;
begin
  with jx as (
    select o.payment_status st, coalesce(o.external_meta -> 'johku' ->> 'payment_method', 'unknown') m,
           case when (o.external_meta -> 'johku' ->> 'amount') ~ '^-?\d+(\.\d+)?$' then (o.external_meta -> 'johku' ->> 'amount')::numeric else o.total_gross end amt
      from booking.orders o
     where (o.external_source = 'johku' or o.johku_order_no is not null or o.source_channel = 'johku_import')
       and o.payment_status in ('paid','partially_refunded','refunded')
       and left(o.external_meta -> 'johku' ->> 'paid_at', 10) between to_char(p_from - 1, 'YYYY-MM-DD') and to_char(p_to + 1, 'YYYY-MM-DD')
       and (booking._try_ts(o.external_meta -> 'johku' ->> 'paid_at') at time zone 'Europe/Helsinki')::date between p_from and p_to
  ), rc as (
    select r.id, r.receipt_no, r.kind, r.issued_at, (r.issued_at at time zone 'Europe/Helsinki')::date as d, r.snapshot s, o.order_no,
           r.snapshot -> 'payment' ->> 'method' as method, coalesce(r.snapshot -> 'payment' ->> 'method_label', r.snapshot -> 'payment' ->> 'method') as mlabel,
           r.total_gross as gross, (r.snapshot ->> 'total_net')::numeric as net, (r.snapshot ->> 'total_vat')::numeric as vat, coalesce((r.snapshot ->> 'rounding')::numeric, 0) as rnd
      from booking.receipts r join booking.orders o on o.id = r.order_id
     where (r.issued_at at time zone 'Europe/Helsinki')::date between p_from and p_to
       and not booking._acct_excluded(r.order_id, r.payment_id)   -- Johku ei kirjanpitoraporttiin
  ), tot as (
    select jsonb_build_object('receipts', count(*) filter (where kind = 'receipt'), 'refund_receipts', count(*) filter (where kind = 'refund_receipt'),
             'gross', coalesce(sum(gross) filter (where kind = 'receipt'), 0), 'net', coalesce(sum(net) filter (where kind = 'receipt'), 0), 'vat', coalesce(sum(vat) filter (where kind = 'receipt'), 0),
             'refunds_gross', coalesce(sum(gross) filter (where kind = 'refund_receipt'), 0), 'net_after_refunds', coalesce(sum(gross), 0),
             'vat_after_refunds', coalesce(sum(vat), 0), 'net_ex_vat_after_refunds', coalesce(sum(net), 0), 'rounding', coalesce(sum(rnd), 0)) j from rc
  ), bm as (
    select coalesce(jsonb_agg(jsonb_build_object('method', method, 'label', label, 'payments', pc, 'gross', g, 'refunds', rf, 'rounding', rn) order by method), '[]'::jsonb) j from (
      select method, max(mlabel) label, count(*) filter (where kind = 'receipt') pc, coalesce(sum(gross) filter (where kind = 'receipt'), 0) g,
             coalesce(sum(gross) filter (where kind = 'refund_receipt'), 0) rf, coalesce(sum(rnd), 0) rn from rc group by method) x
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
      select d, count(*) filter (where kind = 'receipt') c, coalesce(sum(gross) filter (where kind = 'receipt'), 0) g, coalesce(sum(vat), 0) v, coalesce(sum(gross) filter (where kind = 'refund_receipt'), 0) rf from rc group by d) x
  ), js as (
    -- Tilastolohko (EI kirjanpitoon): Johku-tilaukset, joiden Johku-maksupäivä (external_meta.johku.paid_at, Helsingin päivä) osuu jaksolle. Ei kosketa totals/by_*-avaimia.
    select jsonb_build_object('label', 'Johku (ei kirjanpitoon)', 'accounting', false, 'basis', 'johku_paid_at',
             'orders', coalesce(count(*) filter (where st in ('paid','partially_refunded')), 0),
             'gross', coalesce(sum(amt) filter (where st in ('paid','partially_refunded')), 0),
             'refunded_orders', coalesce(count(*) filter (where st = 'refunded'), 0),
             'refunded_gross', coalesce(sum(amt) filter (where st = 'refunded'), 0),
             'by_method', coalesce((select jsonb_agg(jsonb_build_object('method', m, 'orders', c, 'gross', g) order by m)
                                      from (select m2.m, count(*) c, sum(m2.amt) g from jx m2 where m2.st in ('paid','partially_refunded') group by m2.m) mm), '[]'::jsonb)) j
      from jx
  ), op as (
    select jsonb_build_object('orders', count(*), 'unpaid', coalesce(sum(u), 0)) j from (
      select o.id, greatest(o.total_gross - coalesce((select sum(p.amount - p.refunded_amount) from booking.payments p where p.order_id = o.id and p.status in ('paid','partially_refunded','refunded')), 0), 0) u
        from booking.orders o where not booking._acct_excluded(o.id, null) and o.status = 'confirmed'
         and (select min(r.starts_at at time zone 'Europe/Helsinki')::date from booking.reservations r where r.order_id = o.id and r.status = 'confirmed') between p_from and p_to) y where u > 0
  ), ur as (
    select jsonb_build_object('payments', count(*), 'amount', coalesce(sum(p.amount), 0)) j from booking.payments p
     where not booking._acct_excluded(p.order_id, p.id) and p.status in ('paid','partially_refunded','refunded') and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to
       and not exists (select 1 from booking.receipts r where r.payment_id = p.id and r.kind = 'receipt')
  )
  select jsonb_build_object('period', jsonb_build_object('from', p_from, 'to', p_to, 'tz', 'Europe/Helsinki'), 'generated_at', now(), 'basis', 'cash (kuitin antamispäivä)',
         'totals', tot.j, 'by_method', bm.j, 'by_vat', bv.j, 'by_method_vat', bmv.j, 'by_category', bc.j, 'open', op.j, 'unreceipted', ur.j, 'statistics', jsonb_build_object('johku', js.j))
         || case when p_receipts then jsonb_build_object('receipts', rl.j) else '{}'::jsonb end
         || case when p_days then jsonb_build_object('by_day', bd.j) else '{}'::jsonb end
    into v_res from tot, bm, bv, bmv, bc, rl, bd, op, ur, js;
  return v_res;
end $function$;

-- uudet funktiot pois (kaikki ylikuormitukset)
do $$ declare r record; begin
  for r in select p.oid::regprocedure as f from pg_proc p where p.pronamespace = 'booking'::regnamespace and p.proname = any (array['_gc_today', '_gc_flag', '_gc_random_code', '_gc_card_json', '_gc_create_card', '_gc_apply', '_gc_activate_order', '_gc_orders_paid_trg', '_gc_orders_cancel_trg', '_gc_cancel_order_cards', '_gc_sell', '_gc_redeem', '_gc_rl_blocked', '_gc_log', '_is_johku_row', 'public_gift_card_packages', 'public_check_gift_card', 'public_apply_gift_card', 'public_buy_gift_card', 'public_get_order_gift_cards', 'public_get_gift_card', '_gc_find', 'admin_list_gift_card_packages', 'admin_update_gift_card_package', 'admin_list_gift_cards', 'admin_get_gift_card', 'admin_create_gift_card', 'admin_set_gift_card_expiry', 'admin_adjust_gift_card', 'admin_deactivate_gift_card', 'admin_reactivate_gift_card', 'admin_redeem_gift_card', 'gift_cards_housekeeping', 'svc_gift_cards_johku_upsert']) loop
    execute 'drop function ' || r.f;
  end loop;
end $$;
