-- booking_343: hyvityksen valmistuminen ja hyvityskuitit (Bottiavustus 22.35 + KirjanpitoTapio 22.40, 24.11.2026; K1 osa 1).
-- 1) montonio_refund_complete: kirjataan refunds.amount (rivit skaalataan summaan, booking._refund_scaled_lines).
--    payments.refunded_amount = least(refunded + amount, amount); maksurivin refunded_gross rajataan rivin summaan.
--    Jos refunded + amount ylittäisi maksun, hyvitystä ei merkitä valmiiksi: provider_status = 'needs_review', raw.review,
--    audit_log MONTONIO_REFUND_NEEDS_REVIEW; ei kuittia eikä viestiä. claim/fail/release eivät koske tällaiseen riviin.
-- 2) refunds.covered_by_receipt_id (uusi sarake). _issue_refund_receipt: kuitin summa = refunds.amount. Kuittia (eikä viestiä,
--    _on_refund_done) ei luoda, jos covered_by_receipt_id on asetettu tai maksun hyvityskuitit kattavat jo hyvitetyn summan
--    (kattava kuitti kirjataan, audit REFUND_RECEIPT_COVERED), eikä silloin kun kuitit ylittäisivät hyvitetyn (audit REFUND_RECEIPT_BLOCKED).
-- 3) admin_refund: kesken oleva hyvitys estää koko maksun rivijaon (juurisyy hyvitykseen 69: rivit 180 € / summa 162 €);
--    rivikatot (_payment_line_open) vähentävät kesken olevat hyvitykset.
-- 4) refunds_lines_guard (BEFORE INSERT): rivien summa = amount, eikä rivi ylity kesken olevat hyvitykset mukaan lukien.
-- 5) montonio_refund_info(refund_id): read-only tiedot Montonion tilakyselyä varten (montonio-refund action=status, vain GET).
-- Ei datakorjauksia (hyvitys 68 → covered_by_receipt_id = H-2026-000006 on Bottiavustuksen datakorjaus). Ei asetus- eikä lippumuutoksia.

-- Hyvitys, jonka aiempi hyvityskuitti jo kattaa (esim. hyvitys 68 → H-2026-000006): ei omaa kuittia eikä viestiä.
alter table booking.refunds add column if not exists covered_by_receipt_id bigint references booking.receipts(id) on delete restrict;
comment on column booking.refunds.covered_by_receipt_id is 'booking_343: aiempi hyvityskuitti, joka kattaa tämän hyvityksen. Asetettu → _issue_refund_receipt ei luo kuittia eikä viestiä.';
-- Rivit skaalataan hyvityksen summaan (sentit, jäännös suurimmalle riville). Ennallaan, jos summa täsmää.
create or replace function booking._refund_scaled_lines(p_lines jsonb, p_amount numeric)
 returns jsonb
 language plpgsql
 immutable
 set search_path to ''
as $function$
declare v_sum numeric; v_n int; v_i int := 0; v_left numeric; v_a numeric; x jsonb; v_out jsonb := '[]'::jsonb;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 or p_amount is null then return p_lines; end if;
  select sum((e ->> 'amount')::numeric), count(*) into v_sum, v_n from jsonb_array_elements(p_lines) e;
  if v_sum is null or v_sum <= 0 or abs(v_sum - p_amount) < 0.005 then return p_lines; end if;
  v_left := round(p_amount, 2);
  for x in select e from jsonb_array_elements(p_lines) with ordinality t(e, i) order by (e ->> 'amount')::numeric, i loop
    v_i := v_i + 1;
    v_a := case when v_i = v_n then v_left else round((x ->> 'amount')::numeric * p_amount / v_sum, 2) end;
    v_left := v_left - v_a;
    if v_a <> 0 then
      v_out := v_out || jsonb_build_array((x - 'persons') || jsonb_build_object('amount', v_a, 'scaled_from', (x ->> 'amount')::numeric));
    end if;
  end loop;
  return v_out;
end $function$;
revoke all on function booking._refund_scaled_lines(jsonb, numeric) from public;
grant execute on function booking._refund_scaled_lines(jsonb, numeric) to service_role;

-- Maksurivin hyvitettävissä oleva osuus: rivi − jo hyvitetty − kesken olevat (requested/processing) hyvitykset.
create or replace function booking._payment_line_open(p_payment_line_id bigint)
 returns numeric
 language sql
 stable security definer
 set search_path to ''
as $function$
  select pl.amount_gross - pl.refunded_gross
         - coalesce((select sum((e ->> 'amount')::numeric)
                       from booking.refunds f, jsonb_array_elements(coalesce(f.lines, '[]'::jsonb)) e
                      where f.payment_id = pl.payment_id and f.status in ('requested', 'processing')
                        and (e ->> 'payment_line_id')::bigint = pl.id), 0)
    from booking.payment_lines pl where pl.id = p_payment_line_id
$function$;
revoke all on function booking._payment_line_open(bigint) from public, anon, authenticated;
grant execute on function booking._payment_line_open(bigint) to service_role;

-- Uusi hyvitys: rivien summa = amount, eikä rivi ylity (mukana kesken olevat hyvitykset). Koskee kaikkia polkuja.
create or replace function booking._refunds_lines_guard_trg()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_sum numeric; v_bad bigint;
begin
  if new.lines is null or jsonb_typeof(new.lines) <> 'array' or jsonb_array_length(new.lines) = 0 then return new; end if;
  select coalesce(sum((e ->> 'amount')::numeric), 0) into v_sum from jsonb_array_elements(new.lines) e;
  if abs(v_sum - new.amount) > 0.004 then
    perform booking._err('invalid_items', format('Hyvityksen rivien summa (%s €) ei vastaa hyvityksen summaa (%s €)', v_sum, new.amount));
  end if;
  select pl.id into v_bad
    from (select (e ->> 'payment_line_id')::bigint as pl_id, sum((e ->> 'amount')::numeric) as amt from jsonb_array_elements(new.lines) e group by 1) x
    join booking.payment_lines pl on pl.id = x.pl_id
   where x.amt > 0
     and pl.refunded_gross + x.amt + coalesce((select sum((e2 ->> 'amount')::numeric)
                                                 from booking.refunds f, jsonb_array_elements(coalesce(f.lines, '[]'::jsonb)) e2
                                                where f.payment_id = new.payment_id and f.status in ('requested', 'processing')
                                                  and (e2 ->> 'payment_line_id')::bigint = pl.id), 0) > pl.amount_gross + 0.004
   limit 1;
  if v_bad is not null then
    perform booking._err('amount_exceeds_refundable', 'Rivin hyvitys ylittää hyvitettävissä olevan (mukana kesken olevat hyvitykset)');
  end if;
  return new;
end $function$;
revoke all on function booking._refunds_lines_guard_trg() from public;
drop trigger if exists refunds_lines_guard on booking.refunds;
create trigger refunds_lines_guard before insert on booking.refunds for each row execute function booking._refunds_lines_guard_trg();

-- Montonion hyvitystilan kyselyä varten (read-only): hyvityksen tunnisteet. Ei muuta mitään.
create or replace function booking.montonio_refund_info(p_refund_id bigint)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare rf booking.refunds; pay booking.payments;
begin
  select * into rf from booking.refunds where id = p_refund_id and provider = 'montonio';
  if not found then return jsonb_build_object('found', false); end if;
  select * into pay from booking.payments where id = rf.payment_id;
  return jsonb_build_object('found', true, 'refund_id', rf.id, 'status', rf.status, 'provider_status', rf.provider_status, 'amount', rf.amount,
    'provider_refund_id', rf.provider_refund_id, 'order_uuid', pay.raw ->> 'order_uuid', 'payment_id', pay.id,
    'payment_amount', pay.amount, 'refunded_amount', pay.refunded_amount, 'env', coalesce(pay.raw ->> 'env', 'test'),
    'review', rf.raw -> 'review');
end $function$;
revoke all on function booking.montonio_refund_info(bigint) from public, anon, authenticated;
grant execute on function booking.montonio_refund_info(bigint) to service_role;

CREATE OR REPLACE FUNCTION booking._issue_refund_receipt(p_refund_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare f booking.refunds; pay booking.payments; o booking.orders; pm booking.payment_methods; orig booking.receipts; v_lines jsonb; v_vat jsonb; v_gross numeric; v_vatsum numeric; v_buyer jsonb;
        v_seq int; v_year int; v_no text; v_ts timestamptz; v_snap jsonb; v_id bigint; v_series text; v_rnd numeric := 0; v_flines jsonb; v_receipted numeric; v_cover bigint;
begin
  select * into f from booking.refunds where id = p_refund_id;
  if not found or f.status <> 'done' then return null; end if;
  select id into v_id from booking.receipts where refund_id = f.id;
  if found then return v_id; end if;
  select * into pay from booking.payments where id = f.payment_id;
  if booking._acct_excluded(pay.order_id, pay.id) then return null; end if;
  -- booking_343: hyvitys on jo katettu aiemmalla hyvityskuitilla (covered_by_receipt_id) → ei uutta kuittia eikä viestiä
  if f.covered_by_receipt_id is not null then return null; end if;
  -- booking_343: jos maksun hyvityskuitit kattavat jo hyvitetyn summan, kuittia ei luoda; hyvitykseen kirjataan kattava kuitti
  select -coalesce(sum(r.total_gross), 0), max(r.id) into v_receipted, v_cover
    from booking.receipts r where r.payment_id = pay.id and r.kind = 'refund_receipt';
  if v_cover is not null and v_receipted >= pay.refunded_amount - 0.004 then
    update booking.refunds set covered_by_receipt_id = v_cover, updated_at = now() where id = f.id;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
    values (auth.uid(), booking._jwt_role(), 'refunds', f.id::text, 'REFUND_RECEIPT_COVERED',
            jsonb_build_object('covered_by_receipt_id', v_cover, 'payment_id', pay.id, 'refunded_amount', pay.refunded_amount, 'receipted', v_receipted, 'amount', f.amount));
    return null;
  end if;
  select * into o from booking.orders where id = f.order_id;
  select * into pm from booking.payment_methods where code = pay.method;
  select * into orig from booking.receipts where payment_id = pay.id and kind = 'receipt';
  -- booking_343: kuitin summa = refunds.amount. Rivit skaalataan summaan, jos ne poikkeavat.
  v_flines := booking._refund_scaled_lines(f.lines, f.amount);
  select jsonb_agg(jsonb_build_object(
           'description', pl.description,
           'quantity', coalesce((pp.u ->> 'quantity')::int, 1),
           'unit_gross', coalesce((pp.u ->> 'unit_gross')::numeric, -(x ->> 'amount')::numeric),
           'unit_net', case when pp.u is not null then round(( -((x ->> 'amount')::numeric - round((x ->> 'amount')::numeric * pl.vat_rate / (100 + pl.vat_rate), 2)) ) / greatest((pp.u ->> 'quantity')::numeric, 1), 2)
                            else -((x ->> 'amount')::numeric - round((x ->> 'amount')::numeric * pl.vat_rate / (100 + pl.vat_rate), 2)) end,
           'line_gross', -(x ->> 'amount')::numeric,
           'line_net', -((x ->> 'amount')::numeric - round((x ->> 'amount')::numeric * pl.vat_rate / (100 + pl.vat_rate), 2)),
           'vat_rate', pl.vat_rate, 'kind', pl.kind, 'category', coalesce(case when oi.kind = 'addon' then 'addon' end, prod.category, pl.kind),
           'starts_at', svc.starts_at, 'ends_at', svc.ends_at) order by pl.id)
    into v_lines
    from jsonb_array_elements(v_flines) x
    join booking.payment_lines pl on pl.id = (x ->> 'payment_line_id')::bigint
    left join booking.order_items oi on oi.id = pl.order_item_id
    left join kb.products prod on prod.id = oi.product_id
    left join lateral (
      select r.starts_at, r.ends_at
        from booking.reservations r
       where r.order_item_id = coalesce(oi.parent_item_id, oi.id)
       order by r.starts_at
       limit 1
    ) svc on true
    left join lateral (
      select booking._receipt_item_persons(oi.id) as party,
             case when booking._receipt_item_persons(oi.id) >= 1
                       and round(round(pl.amount_gross / booking._receipt_item_persons(oi.id), 2) * booking._receipt_item_persons(oi.id), 2) = round(pl.amount_gross, 2)
                  then round(pl.amount_gross / booking._receipt_item_persons(oi.id), 2) end as unit
    ) src on true
    left join lateral (
      select booking._receipt_refund_units(
               -(x ->> 'amount')::numeric,
               src.unit,
               src.party,
               case when coalesce(x ->> 'persons', '') ~ '^\d{1,3}$' then (x ->> 'persons')::integer end) as u
    ) pp on true;
  if v_lines is null then return null; end if;
  v_vat := booking._vat_groups(v_lines);
  select sum((x ->> 'gross')::numeric), sum((x ->> 'vat')::numeric) into v_gross, v_vatsum from jsonb_array_elements(v_vat) x;
  if pay.method = 'cash' then v_rnd := -booking._cash_rounding(-v_gross); end if;
  -- booking_343: saman maksun hyvityskuittien summa ei saa ylittää maksun hyvitettyä summaa (osittain katettu → käsin)
  if v_receipted - v_gross > pay.refunded_amount + 0.004 then
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
    values (auth.uid(), booking._jwt_role(), 'refunds', f.id::text, 'REFUND_RECEIPT_BLOCKED',
            jsonb_build_object('reason', 'receipts_exceed_refunded', 'payment_id', pay.id, 'refunded_amount', pay.refunded_amount, 'receipted', v_receipted, 'new', -v_gross));
    return null;
  end if;
  v_buyer := booking._buyer_json(o.id);
  v_ts := coalesce(f.done_at, now());
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
end $function$;

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
  -- booking_280 (t42u): lahjakorttimaksua ei hyvitetä rahana eikä kortille kysymättä; kumppanikoodimaksua ei hyvitetä lainkaan.
  if pay.gift_card_id is not null or pay.method = 'gift_card' then
    perform booking._err('gift_card_requires_keep_choice', 'Lahjakorttimaksua ei hyvitetä: peru varaus ja valitse, jätetäänkö lahjakorttikoodi voimaan');
  end if;
  if pay.method = 'partner_voucher' or pay.method like 'partner\_voucher\_%' then
    perform booking._err('voucher_not_refundable', 'Kumppanikoodilla maksettua osuutta ei hyvitetä');
  end if;
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
  -- booking_343: kesken oleva hyvitys estää koko maksun rivijaon (muuten rivit hyvitettäisiin kahdesti)
  v_full := abs(p_amount - v_cap) < 0.005 and pay.refunded_amount = 0
            and not exists (select 1 from booking.refunds f where f.payment_id = pay.id and f.status in ('requested','processing'));
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
      if (l ->> 'amount')::numeric <= 0 or (l ->> 'amount')::numeric > booking._payment_line_open(v_pl.id) + 0.004 then perform booking._err('amount_exceeds_refundable', 'Rivin hyvitys ylittää hyvitettävissä olevan'); end if;
      v_alloc_json := v_alloc_json || jsonb_build_object('payment_line_id', v_pl.id, 'amount', (l ->> 'amount')::numeric);
      v_sum := v_sum + (l ->> 'amount')::numeric;
    end loop;
    if abs(v_sum - p_amount) > 0.004 then perform booking._err('invalid_items', 'Rivien summa ei vastaa hyvityksen summaa'); end if;
  elsif v_full then
    select coalesce(jsonb_agg(jsonb_build_object('payment_line_id', id, 'amount', amount_gross - refunded_gross) order by id), '[]'::jsonb) into v_alloc_json
      from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross <> 0;
  else   -- suhteessa positiivisten rivien hyvitettävään osuuteen
    select coalesce(sum(booking._payment_line_open(id)), 0) into v_total_cap from booking.payment_lines where payment_id = pay.id and booking._payment_line_open(id) > 0;
    if v_total_cap < p_amount - 0.004 then perform booking._err('invalid_items', 'Anna rivijako (p_lines)'); end if;
    v_left := p_amount; select count(*) into v_n from booking.payment_lines where payment_id = pay.id and booking._payment_line_open(id) > 0;
    for r in select id, booking._payment_line_open(id) as cap from booking.payment_lines where payment_id = pay.id and booking._payment_line_open(id) > 0 order by id loop
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
end $function$;

CREATE OR REPLACE FUNCTION booking.montonio_refund_claim(p_refund_id bigint DEFAULT NULL::bigint, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_rows jsonb;
begin
  if booking._montonio_mode() not in ('test', 'live') then
    return jsonb_build_object('ok', true, 'claimed', '[]'::jsonb, 'mode', booking._montonio_mode());
  end if;
  with c as (
    select f.id from booking.refunds f
     where f.provider = 'montonio' and (p_refund_id is null or f.id = p_refund_id)
       and coalesce(f.provider_status, '') <> 'needs_review'
       and (f.status = 'requested'
            or (f.status = 'processing' and f.provider_status = 'awaiting_settlement' and (p_refund_id is not null or f.updated_at < now() - interval '12 hours'))
            or (f.status = 'processing' and f.provider_refund_id is not null and p_refund_id is not null)
            or (f.status = 'processing' and coalesce(f.provider_status, '') <> 'awaiting_settlement' and f.updated_at < now() - interval '10 minutes'))
     order by f.id limit greatest(least(coalesce(p_limit, 20), 50), 1)
     for update skip locked),
  u as (
    update booking.refunds f set status = 'processing', provider_status = coalesce(f.provider_status, 'processing'), updated_at = now()
     from c where f.id = c.id returning f.*)
  select coalesce(jsonb_agg(jsonb_build_object(
           'refund_id', u.id, 'payment_id', u.payment_id, 'amount', u.amount,
           'order_uuid', p.raw ->> 'order_uuid', 'currency', p.currency,
           'env', coalesce(p.raw ->> 'env', 'test'),
           'provider_refund_id', u.provider_refund_id,
           'idempotency_key', 'refund-' || u.id::text
         ) order by u.id), '[]'::jsonb) into v_rows
    from u join booking.payments p on p.id = u.payment_id;
  return jsonb_build_object('ok', true, 'claimed', v_rows, 'mode', booking._montonio_mode());
end $function$;

CREATE OR REPLACE FUNCTION booking.montonio_refund_complete(p_refund_id bigint, p_provider_refund_id text, p_raw jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rf booking.refunds; pay booking.payments; v_full boolean; v_gc boolean; v_lines jsonb;
begin
  select * into rf from booking.refunds where id = p_refund_id and provider = 'montonio' for update;
  if not found then perform booking._err('not_found', 'Hyvitystä ei löydy'); end if;
  if rf.status = 'done' then return jsonb_build_object('ok', true, 'already', true); end if;
  if rf.status not in ('requested', 'processing') then perform booking._err('refund_not_pending', 'Hyvitys ei ole käsiteltävänä'); end if;
  select * into pay from booking.payments where id = rf.payment_id for update;
  -- booking_343: valmistuminen kirjataan refunds.amountin mukaan (rivit skaalataan summaan). refunded_amount ja maksurivin
  -- refunded_gross rajataan maksun / rivin summaan. Jos maksu ylittyisi, hyvitys jää käsin tarkistettavaksi
  -- (provider_status needs_review, audit_log): ei tilamuutosta, ei kuittia, ei viestiä.
  if rf.provider_status = 'needs_review' then
    return jsonb_build_object('ok', true, 'needs_review', true, 'already', true, 'refund_id', rf.id, 'reason', rf.raw #>> '{review,reason}');
  end if;
  if pay.refunded_amount + rf.amount > pay.amount + 0.004 then
    update booking.refunds
       set provider_status = 'needs_review', provider_refund_id = coalesce(p_provider_refund_id, provider_refund_id),
           raw = coalesce(raw, '{}'::jsonb) || jsonb_build_object('review', jsonb_build_object('reason', 'payment_over_refunded', 'at', now(),
                   'payment_amount', pay.amount, 'refunded_amount', pay.refunded_amount, 'provider', coalesce(p_raw, '{}'::jsonb))),
           updated_at = now()
     where id = rf.id;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
    values (null, 'service_role', 'refunds', rf.id::text, 'MONTONIO_REFUND_NEEDS_REVIEW',
            jsonb_build_object('reason', 'payment_over_refunded', 'amount', rf.amount, 'payment_id', pay.id, 'payment_amount', pay.amount,
                               'refunded_amount', pay.refunded_amount, 'provider_refund_id', coalesce(p_provider_refund_id, rf.provider_refund_id)));
    return jsonb_build_object('ok', true, 'needs_review', true, 'reason', 'payment_over_refunded', 'refund_id', rf.id);
  end if;
  v_lines := booking._refund_scaled_lines(coalesce(rf.lines, '[]'::jsonb), rf.amount);
  v_full := abs(rf.amount - pay.amount) < 0.005 and pay.refunded_amount = 0;
  v_gc := exists (select 1 from booking.payment_lines pl join booking.order_items oi on oi.id = pl.order_item_id where pl.payment_id = pay.id and oi.kind = 'gift_card')
          and exists (select 1 from booking.gift_cards gc where gc.purchase_order_id = pay.order_id and gc.status <> 'cancelled');
  update booking.refunds
     set status = 'done', provider_status = 'refunded', provider_refund_id = coalesce(p_provider_refund_id, provider_refund_id),
         raw = case when v_lines is distinct from rf.lines then coalesce(p_raw, raw, '{}'::jsonb) || jsonb_build_object('lines_original', rf.lines) else coalesce(p_raw, raw) end,
         lines = v_lines, done_at = now(), updated_at = now()
   where id = rf.id;
  update booking.payment_lines pl set refunded_gross = least(pl.refunded_gross + x.amt, pl.amount_gross)
    from (select (e ->> 'payment_line_id')::bigint as pl_id, sum((e ->> 'amount')::numeric) as amt from jsonb_array_elements(v_lines) e group by 1) x
   where pl.id = x.pl_id;
  update booking.payments set refunded_amount = least(refunded_amount + rf.amount, amount),
         status = case when refunded_amount + rf.amount >= amount - 0.004 then 'refunded' else 'partially_refunded' end
   where id = pay.id;
  perform booking._sync_placeholder(pay.order_id);
  perform booking._refresh_order_payment(pay.order_id);
  perform booking._on_refund_done(rf.id);
  if v_gc and v_full then perform booking._gc_cancel_order_cards(pay.order_id, 'Ostomaksu hyvitetty (hyvitys #' || rf.id || ')'); end if;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (null, 'service_role', 'refunds', rf.id::text, 'MONTONIO_REFUND', jsonb_build_object('provider_refund_id', coalesce(p_provider_refund_id, rf.provider_refund_id), 'amount', rf.amount));
  return jsonb_build_object('ok', true, 'refund_id', rf.id);
end $function$;

CREATE OR REPLACE FUNCTION booking.montonio_refund_fail(p_refund_id bigint, p_error jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rf booking.refunds;
begin
  select * into rf from booking.refunds where id = p_refund_id and provider = 'montonio' for update;
  if not found then perform booking._err('not_found', 'Hyvitystä ei löydy'); end if;
  if rf.status = 'done' then return jsonb_build_object('ok', true, 'unchanged', true, 'status', rf.status); end if;
  if rf.status not in ('requested', 'processing') then return jsonb_build_object('ok', true, 'unchanged', true, 'status', rf.status); end if;
  if rf.provider_status = 'needs_review' then return jsonb_build_object('ok', true, 'unchanged', true, 'status', rf.status, 'needs_review', true); end if;
  update booking.refunds set status = 'failed', provider_status = 'failed', raw = jsonb_build_object('error', p_error, 'at', now()), updated_at = now() where id = rf.id;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (null, 'service_role', 'refunds', rf.id::text, 'MONTONIO_REFUND_FAIL', coalesce(p_error, '{}'::jsonb));
  return jsonb_build_object('ok', true, 'status', 'failed');
end $function$;

CREATE OR REPLACE FUNCTION booking.montonio_refund_release(p_refund_id bigint, p_raw jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rf booking.refunds;
begin
  select * into rf from booking.refunds where id = p_refund_id and provider = 'montonio' for update;
  if not found then perform booking._err('not_found', 'Hyvitystä ei löydy'); end if;
  if rf.status = 'done' then return jsonb_build_object('ok', true, 'unchanged', true, 'status', rf.status); end if;
  if rf.status not in ('requested', 'processing') then return jsonb_build_object('ok', true, 'unchanged', true, 'status', rf.status); end if;
  if rf.provider_status = 'needs_review' then return jsonb_build_object('ok', true, 'unchanged', true, 'status', rf.status, 'needs_review', true); end if;
  update booking.refunds
     set status = 'processing', provider_status = 'awaiting_settlement', raw = coalesce(p_raw, raw), updated_at = now()
   where id = rf.id;
  return jsonb_build_object('ok', true, 'status', 'awaiting_settlement');
end $function$;
