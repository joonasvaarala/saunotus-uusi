-- booking_189: Visma Pay ja MobilePay eivät enää käynnistä verkkomaksua. Verkkomaksu on Montonio (booking_188).
-- Ei koske booking_188:n funktiorunkoja. Ei kytke Montonion tilaa eikä Procountoria.
-- md5 = md5(pg_get_functiondef), PostgreSQL 16.15. Vanhat täsmäävät kirjattuihin pinneihin
-- (mobilepay e6888446c4b44e554d31c0920609ddb6, vismapay d1f8df803a45c2b77aa9f8554fc41890, _issue_receipt ae8b663945b78d1849b0028987689c8e).
-- Rollback: rollbacks/20261027140000_booking_189_ROLLBACK.sql
-- Testi: tests/checkout/t189_visma_mobilepay_removed.sql
--
-- Korvattavat (vanha -> uusi):
--   booking.mobilepay_payment_prepare(uuid,uuid,integer,text): e6888446c4b44e554d31c0920609ddb6 -> c6a64c1ff9353a5e581d72af10966665
--   booking.vismapay_payment_prepare(uuid,uuid): d1f8df803a45c2b77aa9f8554fc41890 -> d22cda7beb5cea5967b267e52d79ab99
--   booking.admin_refund(bigint,numeric,text,jsonb,boolean): 73923b95960933015bc121cd5a4845ef -> 709d5fd54d877846682571b60c5d21bd
--   booking._issue_receipt(bigint): ae8b663945b78d1849b0028987689c8e -> 1bd426bef2ff856c712749d0a665f2b3
--   booking._issue_refund_receipt(bigint): 1286d1a2a7cf12718a0022e72126b526 -> ce97e81bd11e71aa92ba70f9719cae66
--   booking.admin_pos_tenders(): 0b100e5beb55de1d34bd7aa3cbdb9b54 -> 443e6462ede3ec9d3118d08be43759fa
set local lock_timeout = '5s';

do $g$
declare v text;
begin
  if to_regprocedure('booking._montonio_mode()') is null then
    raise exception 'booking_189: booking_188 puuttuu (_montonio_mode)';
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.mobilepay_payment_prepare(uuid,uuid,integer,text)')));
  if v is null or v not in ('e6888446c4b44e554d31c0920609ddb6','c6a64c1ff9353a5e581d72af10966665') then
    raise exception 'booking_189: mobilepay_payment_prepare md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.vismapay_payment_prepare(uuid,uuid)')));
  if v is null or v not in ('d1f8df803a45c2b77aa9f8554fc41890','d22cda7beb5cea5967b267e52d79ab99') then
    raise exception 'booking_189: vismapay_payment_prepare md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_refund(bigint,numeric,text,jsonb,boolean)')));
  if v is null or v not in ('73923b95960933015bc121cd5a4845ef','709d5fd54d877846682571b60c5d21bd') then
    raise exception 'booking_189: admin_refund md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._issue_receipt(bigint)')));
  if v is null or v not in ('ae8b663945b78d1849b0028987689c8e','1bd426bef2ff856c712749d0a665f2b3') then
    raise exception 'booking_189: _issue_receipt md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._issue_refund_receipt(bigint)')));
  if v is null or v not in ('1286d1a2a7cf12718a0022e72126b526','ce97e81bd11e71aa92ba70f9719cae66') then
    raise exception 'booking_189: _issue_refund_receipt md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_pos_tenders()')));
  if v is null or v not in ('0b100e5beb55de1d34bd7aa3cbdb9b54','443e6462ede3ec9d3118d08be43759fa') then
    raise exception 'booking_189: admin_pos_tenders md5=%', coalesce(v,'puuttuu');
  end if;
end $g$;

-- mobilepay_payment_prepare: e6888446c4b44e554d31c0920609ddb6 -> c6a64c1ff9353a5e581d72af10966665
CREATE OR REPLACE FUNCTION booking.mobilepay_payment_prepare(p_order_token uuid DEFAULT NULL::uuid, p_link_token uuid DEFAULT NULL::uuid, p_expires_minutes integer DEFAULT 120, p_user_flow text DEFAULT 'WEB_REDIRECT'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  return jsonb_build_object('ok', false, 'code', 'payment_not_online', 'message', 'Verkkomaksu ei ole käytössä');
end
$function$


;

-- vismapay_payment_prepare: d1f8df803a45c2b77aa9f8554fc41890 -> d22cda7beb5cea5967b267e52d79ab99
CREATE OR REPLACE FUNCTION booking.vismapay_payment_prepare(p_order_token uuid DEFAULT NULL::uuid, p_link_token uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  return jsonb_build_object('ok', false, 'code', 'payment_not_online', 'message', 'Verkkomaksu ei ole käytössä');
end
$function$


;

-- admin_refund: 73923b95960933015bc121cd5a4845ef -> 709d5fd54d877846682571b60c5d21bd
-- Off-tilan ohje ei enää käske hyvittämään Visman portaalissa.
CREATE OR REPLACE FUNCTION booking.admin_refund(p_payment_id bigint, p_amount numeric, p_reason text, p_lines jsonb DEFAULT NULL::jsonb, p_manual_done boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pay booking.payments; o booking.orders; v_cap numeric; v_mode text; v_online boolean; v_id bigint; l jsonb; v_pl booking.payment_lines; v_sum numeric := 0; v_full boolean;
        r record; v_total_cap numeric; v_alloc numeric; v_left numeric; v_alloc_json jsonb := '[]'::jsonb; v_status text; rc record; v_n int; v_i int := 0;
        v_gc_sale boolean := false;
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
    if not p_manual_done then perform booking._err('refund_not_allowed', 'Verkkomaksun hyvitys ei ole käytössä – kirjaa hyvitys käsin (vain admin)'); end if;
    if booking.current_staff_role() is distinct from 'admin' then perform booking._err('forbidden', 'Käsinkirjaus verkkomaksulle vaatii admin-roolin'); end if;
  end if;
  v_full := abs(p_amount - v_cap) < 0.005 and pay.refunded_amount = 0;
  -- lahjakortit (booking_44): lahjakorttien ostomaksu hyvitetään vain kokonaan ja vain käyttämättömille korteille (kortit mitätöidään)
  if exists (select 1 from booking.payment_lines pl join booking.order_items oi on oi.id = pl.order_item_id where pl.payment_id = pay.id and oi.kind = 'gift_card')
     and exists (select 1 from booking.gift_cards gc where gc.purchase_order_id = pay.order_id and gc.status <> 'cancelled') then
    if not v_full then perform booking._err('gift_card_refund_full_only', 'Lahjakorttien ostomaksu hyvitetään kokonaan (kortit mitätöidään)'); end if;
    if exists (select 1 from booking.gift_cards gc where gc.purchase_order_id = pay.order_id and gc.status not in ('cancelled', 'pending_payment') and gc.balance < gc.initial_amount) then
      perform booking._err('gift_card_in_use', 'Kortilla on jo käyttöä: ostoa ei voi hyvittää kokonaan (mitätöi kortti hallinnassa ja hyvitä tarvittaessa käsin)');
    end if;
    v_gc_sale := true;
  end if;

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
    -- lahjakortit (booking_44): ostomaksun hyvitys mitätöi kortit; lahjakorttimaksun hyvitys palautetaan kortille (ei rahana)
    if v_gc_sale then perform booking._gc_cancel_order_cards(pay.order_id, 'Ostomaksu hyvitetty (hyvitys #' || v_id || ')'); end if;
    if pay.gift_card_id is not null then perform booking._gc_apply(pay.gift_card_id, p_amount, 'refund', pay.order_id, pay.id, 'Hyvitys kortille: ' || btrim(p_reason)); end if;
  end if;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'refunds', v_id::text, 'ADMIN_REFUND', null, jsonb_build_object('payment_id', pay.id, 'amount', p_amount, 'reason', p_reason, 'status', v_status));
  select id, receipt_no into rc from booking.receipts where refund_id = v_id;
  return jsonb_build_object('ok', true, 'refund_id', v_id, 'status', v_status, 'balance', booking._order_balance(pay.order_id), 'receipt_id', rc.id, 'receipt_no', rc.receipt_no);
end $function$


;

-- _issue_receipt: ae8b663945b78d1849b0028987689c8e -> 1bd426bef2ff856c712749d0a665f2b3
-- Englanninkielisen tilauksen Montonio-kuitin method_label on Pay online.
CREATE OR REPLACE FUNCTION booking._issue_receipt(p_payment_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pay booking.payments; o booking.orders; pm booking.payment_methods; v_lines jsonb; v_vat jsonb; v_gross numeric; v_vatsum numeric; v_buyer jsonb; v_seq int; v_year int; v_no text;
        v_ts timestamptz := now(); v_snap jsonb; v_id bigint; v_series text;
begin
  select * into pay from booking.payments where id = p_payment_id;
  if not found or pay.amount <= 0 or booking._acct_excluded(pay.order_id, pay.id) then return null; end if;   -- Johku-lähtöinen (tilaus tai maksu) ei kuittiin/kirjanpitoon
  select id into v_id from booking.receipts where payment_id = pay.id and kind = 'receipt';
  if found then return v_id; end if;
  select * into o from booking.orders where id = pay.order_id;
  select * into pm from booking.payment_methods where code = pay.method;
  select jsonb_agg(jsonb_build_object('description', concat(pl.description, (select ' – ' || case when o.locale = 'en' then coalesce(po.name_en, po.name) else po.name end from booking.reservations rr join booking.product_options po on po.id = rr.product_option_id where rr.order_item_id = oi.id and oi.kind = 'reservation')), 'quantity', pl.quantity, 'unit_gross', round(pl.amount_gross / greatest(pl.quantity, 1), 2),
           'unit_net', round(pl.line_net / greatest(pl.quantity, 1), 2), 'line_gross', pl.amount_gross, 'line_net', pl.line_net, 'vat_rate', pl.vat_rate, 'kind', pl.kind,
           'category', coalesce(case when oi.kind = 'addon' then 'addon' end, prod.category, pl.kind), 'starts_at', r.starts_at, 'ends_at', r.ends_at) order by pl.id)
    into v_lines
    from booking.payment_lines pl left join booking.order_items oi on oi.id = pl.order_item_id left join kb.products prod on prod.id = oi.product_id
    left join booking.reservations r on r.order_item_id = coalesce(oi.parent_item_id, oi.id)
   where pl.payment_id = pay.id;
  if v_lines is null then return null; end if;
  v_vat := booking._vat_groups(v_lines);
  select sum((x ->> 'gross')::numeric), sum((x ->> 'vat')::numeric) into v_gross, v_vatsum from jsonb_array_elements(v_vat) x;
  v_buyer := booking._buyer_json(o.id);
  v_year := booking._receipt_year(v_ts);
  v_series := booking._setting('receipt_series', '{"receipt":"K"}'::jsonb) ->> 'receipt';
  v_seq := booking._next_receipt_no(v_series, v_year);
  v_no := format('%s-%s-%s', v_series, v_year, lpad(v_seq::text, 6, '0'));
  v_snap := jsonb_build_object('v', 1, 'document', 'receipt', 'receipt_no', v_no, 'issued_at', v_ts, 'issued_local', to_char(v_ts at time zone 'Europe/Helsinki', 'DD.MM.YYYY HH24:MI'),
     'seller', booking._seller(), 'order_no', o.order_no,
     'payment', jsonb_build_object('id', pay.id, 'method', pay.method, 'method_label', case when o.locale = 'en' and pay.method = 'montonio' then 'Pay online' else coalesce(pm.label, pay.method) end, 'paid_at', pay.paid_at),
     'buyer', v_buyer, 'invoice_required', v_buyer is not null and v_gross > 400, 'lines', v_lines, 'vat', v_vat,
     'total_gross', v_gross, 'total_net', v_gross - v_vatsum, 'total_vat', v_vatsum, 'rounding', pay.rounding, 'total_paid', v_gross + pay.rounding,
     'currency', 'EUR', 'original', null, 'reason', null, 'locale', case when o.locale = 'en' then 'en' else 'fi' end);
  insert into booking.receipts(receipt_no, kind, series, year, seq, order_id, payment_id, issued_at, total_gross, locale, snapshot, text_body, created_by)
  values (v_no, 'receipt', v_series, v_year, v_seq, o.id, pay.id, v_ts, v_gross, v_snap ->> 'locale', v_snap, booking._receipt_text(v_snap), auth.uid()) returning id into v_id;
  if exists (select 1 from booking.integration_config where key = 'procountor' and mode <> 'off') then
    insert into booking.accounting_outbox(kind, order_id, payment_id, receipt_id, dedupe_key, payload, environment)
    values ('receipt', o.id, pay.id, v_id, 'receipt:' || v_id, v_snap, coalesce(booking._setting('procountor_env') #>> '{}', 'pts')) on conflict (dedupe_key) do nothing;
  end if;
  return v_id;
end $function$


;

-- _issue_refund_receipt: 1286d1a2a7cf12718a0022e72126b526 -> ce97e81bd11e71aa92ba70f9719cae66
CREATE OR REPLACE FUNCTION booking._issue_refund_receipt(p_refund_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare f booking.refunds; pay booking.payments; o booking.orders; pm booking.payment_methods; orig booking.receipts; v_lines jsonb; v_vat jsonb; v_gross numeric; v_vatsum numeric; v_buyer jsonb;
        v_seq int; v_year int; v_no text; v_ts timestamptz := now(); v_snap jsonb; v_id bigint; v_series text; v_rnd numeric := 0;
begin
  select * into f from booking.refunds where id = p_refund_id;
  if not found or f.status <> 'done' then return null; end if;
  select id into v_id from booking.receipts where refund_id = f.id;
  if found then return v_id; end if;
  select * into pay from booking.payments where id = f.payment_id;
  if booking._acct_excluded(pay.order_id, pay.id) then return null; end if;   -- Johku-lähtöinen ei hyvityskuittiin/kirjanpitoon
  select * into o from booking.orders where id = f.order_id;
  select * into pm from booking.payment_methods where code = pay.method;
  select * into orig from booking.receipts where payment_id = pay.id and kind = 'receipt';
  select jsonb_agg(jsonb_build_object('description', pl.description, 'quantity', 1, 'unit_gross', -(x ->> 'amount')::numeric,
           'unit_net', -((x ->> 'amount')::numeric - round((x ->> 'amount')::numeric * pl.vat_rate / (100 + pl.vat_rate), 2)),
           'line_gross', -(x ->> 'amount')::numeric, 'line_net', -((x ->> 'amount')::numeric - round((x ->> 'amount')::numeric * pl.vat_rate / (100 + pl.vat_rate), 2)),
           'vat_rate', pl.vat_rate, 'kind', pl.kind, 'category', coalesce(case when oi.kind = 'addon' then 'addon' end, prod.category, pl.kind), 'starts_at', null, 'ends_at', null) order by pl.id)
    into v_lines
    from jsonb_array_elements(f.lines) x join booking.payment_lines pl on pl.id = (x ->> 'payment_line_id')::bigint
    left join booking.order_items oi on oi.id = pl.order_item_id left join kb.products prod on prod.id = oi.product_id;
  if v_lines is null then return null; end if;
  v_vat := booking._vat_groups(v_lines);
  select sum((x ->> 'gross')::numeric), sum((x ->> 'vat')::numeric) into v_gross, v_vatsum from jsonb_array_elements(v_vat) x;
  if pay.method = 'cash' then v_rnd := -booking._cash_rounding(-v_gross); end if;
  v_buyer := booking._buyer_json(o.id);
  v_year := booking._receipt_year(v_ts);
  v_series := booking._setting('receipt_series', '{"refund_receipt":"H"}'::jsonb) ->> 'refund_receipt';
  v_seq := booking._next_receipt_no(v_series, v_year);
  v_no := format('%s-%s-%s', v_series, v_year, lpad(v_seq::text, 6, '0'));
  v_snap := jsonb_build_object('v', 1, 'document', 'refund_receipt', 'receipt_no', v_no, 'issued_at', v_ts, 'issued_local', to_char(v_ts at time zone 'Europe/Helsinki', 'DD.MM.YYYY HH24:MI'),
     'seller', booking._seller(), 'order_no', o.order_no,
     'payment', jsonb_build_object('id', pay.id, 'method', pay.method, 'method_label', case when o.locale = 'en' and pay.method = 'montonio' then 'Pay online' else coalesce(pm.label, pay.method) end, 'paid_at', pay.paid_at),
     'buyer', v_buyer, 'invoice_required', false, 'lines', v_lines, 'vat', v_vat,
     'total_gross', v_gross, 'total_net', v_gross - v_vatsum, 'total_vat', v_vatsum, 'rounding', v_rnd, 'total_paid', v_gross + v_rnd,
     'currency', 'EUR', 'original', case when orig.id is null then null else jsonb_build_object('receipt_no', orig.receipt_no, 'issued_at', orig.issued_at,
         'issued_local', to_char(orig.issued_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY HH24:MI')) end,
     'reason', f.reason, 'locale', case when o.locale = 'en' then 'en' else 'fi' end);
  insert into booking.receipts(receipt_no, kind, series, year, seq, order_id, payment_id, refund_id, original_receipt_id, issued_at, total_gross, locale, snapshot, text_body, created_by)
  values (v_no, 'refund_receipt', v_series, v_year, v_seq, o.id, pay.id, f.id, orig.id, v_ts, v_gross, v_snap ->> 'locale', v_snap, booking._receipt_text(v_snap), auth.uid()) returning id into v_id;
  if exists (select 1 from booking.integration_config where key = 'procountor' and mode <> 'off') then
    insert into booking.accounting_outbox(kind, order_id, payment_id, receipt_id, dedupe_key, payload, environment)
    values ('refund_receipt', o.id, pay.id, v_id, 'receipt:' || v_id, v_snap, coalesce(booking._setting('procountor_env') #>> '{}', 'pts')) on conflict (dedupe_key) do nothing;
  end if;
  return v_id;
end $function$


;

-- admin_pos_tenders: 0b100e5beb55de1d34bd7aa3cbdb9b54 -> 443e6462ede3ec9d3118d08be43759fa
-- Palauttaa myös montonio_mode. mobilepay_mode ja vismapay_mode säilyvät.
CREATE OR REPLACE FUNCTION booking.admin_pos_tenders()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_base text := rtrim(coalesce(booking._setting('site_base_url', to_jsonb(''::text)) #>> '{}', ''), '/');
begin
  perform booking._require_permission('pos.use');
  return jsonb_build_object(
    'montonio_mode', booking._montonio_mode(),
    'mobilepay_mode', booking._mobilepay_mode(),
    'vismapay_mode', coalesce((select mode from booking.integration_config where key = 'vismapay'), 'off'),
    'site_base_url', v_base,
    'drinks_path', booking._drinks_path('fi'),
    'drinks_path_en', booking._drinks_path('en'),
    'tenders', coalesce((select jsonb_agg(jsonb_build_object(
        'code', t.code, 'handler', t.handler, 'channels', to_jsonb(t.channels), 'active', t.active,
        'sort_order', t.sort_order, 'unavailable_reason', t.unavailable_reason) order by t.sort_order, t.code)
      from booking.pos_tenders t), '[]'::jsonb));
end $function$


;

revoke all on function booking.mobilepay_payment_prepare(uuid,uuid,integer,text) from public, anon, authenticated;
grant execute on function booking.mobilepay_payment_prepare(uuid,uuid,integer,text) to service_role;
revoke all on function booking.vismapay_payment_prepare(uuid,uuid) from public, anon, authenticated;
grant execute on function booking.vismapay_payment_prepare(uuid,uuid) to service_role;
revoke all on function booking.admin_refund(bigint,numeric,text,jsonb,boolean) from public, anon, authenticated;
grant execute on function booking.admin_refund(bigint,numeric,text,jsonb,boolean) to service_role, authenticated;
revoke all on function booking._issue_receipt(bigint) from public, anon, authenticated;
grant execute on function booking._issue_receipt(bigint) to service_role;
revoke all on function booking._issue_refund_receipt(bigint) from public, anon, authenticated;
grant execute on function booking._issue_refund_receipt(bigint) to service_role;
revoke all on function booking.admin_pos_tenders() from public, anon;
grant execute on function booking.admin_pos_tenders() to authenticated, service_role;

do $g$
declare v text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking.mobilepay_payment_prepare(uuid,uuid,integer,text)')));
  if v <> 'c6a64c1ff9353a5e581d72af10966665' then raise exception 'booking_189: mobilepay_payment_prepare uusi md5=%', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.vismapay_payment_prepare(uuid,uuid)')));
  if v <> 'd22cda7beb5cea5967b267e52d79ab99' then raise exception 'booking_189: vismapay_payment_prepare uusi md5=%', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_refund(bigint,numeric,text,jsonb,boolean)')));
  if v <> '709d5fd54d877846682571b60c5d21bd' then raise exception 'booking_189: admin_refund uusi md5=%', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._issue_receipt(bigint)')));
  if v <> '1bd426bef2ff856c712749d0a665f2b3' then raise exception 'booking_189: _issue_receipt uusi md5=%', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._issue_refund_receipt(bigint)')));
  if v <> 'ce97e81bd11e71aa92ba70f9719cae66' then raise exception 'booking_189: _issue_refund_receipt uusi md5=%', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_pos_tenders()')));
  if v <> '443e6462ede3ec9d3118d08be43759fa' then raise exception 'booking_189: admin_pos_tenders uusi md5=%', v; end if;
  if exists (select 1 from pg_proc p where p.oid in (
       'booking.mobilepay_payment_prepare(uuid,uuid,integer,text)'::regprocedure,
       'booking.vismapay_payment_prepare(uuid,uuid)'::regprocedure,
       'booking.admin_refund(bigint,numeric,text,jsonb,boolean)'::regprocedure,
       'booking._issue_receipt(bigint)'::regprocedure,
       'booking._issue_refund_receipt(bigint)'::regprocedure,
       'booking.admin_pos_tenders()'::regprocedure)
     and (not p.prosecdef or p.proconfig is distinct from array['search_path=""'] or p.proowner <> 'postgres'::regrole)) then
    raise exception 'booking_189: SECURITY DEFINER / search_path / omistaja väärin';
  end if;
  if (select provolatile from pg_proc where oid = 'booking.admin_pos_tenders()'::regprocedure) <> 's' then
    raise exception 'booking_189: admin_pos_tenders ei ole STABLE';
  end if;
  if exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid in (
       'booking.mobilepay_payment_prepare(uuid,uuid,integer,text)'::regprocedure,
       'booking.vismapay_payment_prepare(uuid,uuid)'::regprocedure,
       'booking.admin_refund(bigint,numeric,text,jsonb,boolean)'::regprocedure,
       'booking._issue_receipt(bigint)'::regprocedure,
       'booking._issue_refund_receipt(bigint)'::regprocedure,
       'booking.admin_pos_tenders()'::regprocedure) and a.grantee = 0) then
    raise exception 'booking_189: PUBLIC-oikeus jäi';
  end if;
  if has_function_privilege('anon', 'booking.mobilepay_payment_prepare(uuid,uuid,integer,text)', 'execute')
     or has_function_privilege('authenticated', 'booking.mobilepay_payment_prepare(uuid,uuid,integer,text)', 'execute')
     or not has_function_privilege('service_role', 'booking.mobilepay_payment_prepare(uuid,uuid,integer,text)', 'execute')
     or has_function_privilege('anon', 'booking.vismapay_payment_prepare(uuid,uuid)', 'execute')
     or has_function_privilege('authenticated', 'booking.vismapay_payment_prepare(uuid,uuid)', 'execute')
     or not has_function_privilege('service_role', 'booking.vismapay_payment_prepare(uuid,uuid)', 'execute')
     or has_function_privilege('anon', 'booking.admin_refund(bigint,numeric,text,jsonb,boolean)', 'execute')
     or not has_function_privilege('authenticated', 'booking.admin_refund(bigint,numeric,text,jsonb,boolean)', 'execute')
     or has_function_privilege('anon', 'booking._issue_receipt(bigint)', 'execute')
     or has_function_privilege('authenticated', 'booking._issue_receipt(bigint)', 'execute')
     or not has_function_privilege('service_role', 'booking._issue_receipt(bigint)', 'execute')
     or has_function_privilege('anon', 'booking.admin_pos_tenders()', 'execute')
     or not has_function_privilege('authenticated', 'booking.admin_pos_tenders()', 'execute')
     or not has_function_privilege('service_role', 'booking.admin_pos_tenders()', 'execute') then
    raise exception 'booking_189: funktio-oikeudet väärin';
  end if;
end $g$;
