-- booking_119_receipt_cash (20.10.2026)
-- Kuitin rivillä tuote, veroton, ALV-%, ALV euroina ja brutto.
-- Käteistä ei oteta uusissa kirjauksissa eikä uutta käteispyöristystä lasketa.
-- Vanhat käteismaksut ja hyvityskuitin pyöristys säilyvät.
-- Rollback: rollbacks/20261020142000_booking_119_ROLLBACK.sql
set local lock_timeout = '5s';

create or replace function booking._published_text(p_key text, p_lang text, p_fallback text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select s.published_text
      from booking.site_texts s
     where s.key = p_key
       and s.lang = case when p_lang = 'en' then 'en' else 'fi' end
       and s.published_version > 0
       and btrim(s.published_text) <> ''
     limit 1
  ), p_fallback)
$$;

drop function booking._receipt_text(jsonb);
create function booking._receipt_text(s jsonb) returns text
language plpgsql
stable
set search_path = ''
as $$
declare en boolean := coalesce(s ->> 'locale', 'fi') = 'en'; loc text := case when coalesce(s ->> 'locale', 'fi') = 'en' then 'en' else 'fi' end; t text[] := '{}'; l jsonb; v jsonb;
        sel jsonb := s -> 'seller'; b jsonb := s -> 'buyer'; d text; title text; refund boolean := s ->> 'document' = 'refund_receipt'; rnd numeric := coalesce((s ->> 'rounding')::numeric, 0);
        v_gross numeric; v_net numeric; v_vat numeric; v_rate numeric;
        w_qty text; w_net text; w_vat text; w_gross text;
begin
  w_qty := booking._published_text('email.receipt_pdf.word_qty', loc, case when en then 'pcs' else 'kpl' end);
  w_net := booking._published_text('email.receipt_pdf.word_net', loc, case when en then 'excl. VAT' else 'veroton' end);
  w_vat := booking._published_text('email.receipt_pdf.word_vat', loc, case when en then 'VAT' else 'ALV' end);
  w_gross := booking._published_text('email.receipt_pdf.word_gross', loc, case when en then 'gross' else 'brutto' end);
  title := case when refund then case when en then 'REFUND RECEIPT' else 'HYVITYSKUITTI' end
                when (s ->> 'invoice_required')::boolean then case when en then 'RECEIPT / INVOICE' else 'KUITTI / LASKU' end
                else case when en then 'RECEIPT' else 'KUITTI' end end;
  t := t || (sel ->> 'name');
  t := t || concat_ws(', ', sel ->> 'legal_name', (case when en then 'Business ID ' else 'Y-tunnus ' end) || (sel ->> 'business_id'), (case when en then 'VAT ID ' else 'ALV-tunnus ' end) || (sel ->> 'vat_id'));
  t := t || concat_ws(', ', sel ->> 'address', concat_ws(' ', sel ->> 'zip', sel ->> 'city'));
  t := t || concat_ws(' · ', sel ->> 'email', sel ->> 'phone', sel ->> 'web');
  t := t || ''::text;
  t := t || (title || ' ' || (s ->> 'receipt_no'));
  t := t || ((case when en then 'Date: ' else 'Päivämäärä: ' end) || replace(s ->> 'issued_local', ' ', case when en then ' at ' else ' klo ' end));
  t := t || ((case when en then 'Order: ' else 'Tilaus: ' end) || (s ->> 'order_no'));
  t := t || ((case when en then 'Payment method: ' else 'Maksutapa: ' end) || coalesce(s -> 'payment' ->> 'method_label', s -> 'payment' ->> 'method'));
  if coalesce((s ->> 'informational')::boolean, false) then
    t := t || booking._published_text('email.receipt_pdf.giftcard_info', loc,
      case when en then 'VAT was recorded when the gift card was sold. This breakdown is for information only and is not recorded again.'
           else 'Arvonlisävero on kirjattu lahjakortin myynnissä. Tämä erittely on vain tiedoksi, eikä sitä kirjata uudelleen.' end);
  end if;
  if b is not null and b <> 'null'::jsonb then
    t := t || ((case when en then 'Buyer: ' else 'Ostaja: ' end) || concat_ws(', ', b ->> 'company', b ->> 'name'));
    t := t || concat_ws(', ', (case when en then 'Business ID ' else 'Y-tunnus ' end) || nullif(b ->> 'business_id', ''), b ->> 'address', concat_ws(' ', b ->> 'zip', b ->> 'city'));
    if nullif(b ->> 'reference', '') is not null then t := t || ((case when en then 'Your reference: ' else 'Viitteenne: ' end) || (b ->> 'reference')); end if;
  end if;
  if s -> 'original' is not null and s -> 'original' <> 'null'::jsonb then
    t := t || ((case when en then 'Original receipt: ' else 'Alkuperäinen kuitti: ' end) || (s -> 'original' ->> 'receipt_no') || ' (' || (s -> 'original' ->> 'issued_local') || ')');
  end if;
  if nullif(s ->> 'reason', '') is not null then t := t || ((case when en then 'Reason: ' else 'Hyvityksen syy: ' end) || (s ->> 'reason')); end if;
  t := t || ''::text;
  for l in select * from jsonb_array_elements(s -> 'lines') loop
    d := l ->> 'description';
    if l ->> 'starts_at' is not null then
      d := d || ' (' || to_char((l ->> 'starts_at')::timestamptz at time zone 'Europe/Helsinki', 'DD.MM.YYYY HH24:MI') || '–' || to_char((l ->> 'ends_at')::timestamptz at time zone 'Europe/Helsinki', 'HH24:MI') || ')';
    end if;
    v_gross := coalesce((l ->> 'line_gross')::numeric, 0);
    v_rate := coalesce((l ->> 'vat_rate')::numeric, 0);
    v_net := booking._snap_line_net(l);
    v_vat := v_gross - v_net;
    t := t || d;
    t := t || ('   ' || coalesce(l ->> 'quantity', '1') || ' ' || w_qty
               || ' · ' || w_net || ' ' || booking._money(v_net, loc)
               || ' · ' || w_vat || ' ' || booking._rate_txt(v_rate, loc)
               || ' · ' || w_vat || ' ' || booking._money(v_vat, loc)
               || ' · ' || w_gross || ' ' || booking._money(v_gross, loc));
  end loop;
  t := t || ''::text;
  t := t || (case when en then 'VAT breakdown' else 'ALV-erittely' end);
  for v in select * from jsonb_array_elements(s -> 'vat') loop
    t := t || ((case when en then 'VAT ' else 'ALV ' end) || booking._rate_txt((v ->> 'rate')::numeric, loc) || ': ' || (case when en then 'excl. VAT ' else 'veroton ' end) || booking._money((v ->> 'net')::numeric, loc)
               || (case when en then ', VAT ' else ', ALV ' end) || booking._money((v ->> 'vat')::numeric, loc) || (case when en then ', total ' else ', yhteensä ' end) || booking._money((v ->> 'gross')::numeric, loc));
  end loop;
  t := t || ''::text;
  t := t || ((case when en then 'Total (incl. VAT) ' else 'Yhteensä (sis. ALV) ' end) || booking._money((s ->> 'total_gross')::numeric, loc));
  t := t || ((case when en then 'of which VAT ' else 'josta ALV ' end) || booking._money((s ->> 'total_vat')::numeric, loc) || ', ' || (case when en then 'excl. VAT ' else 'veroton ' end) || booking._money((s ->> 'total_net')::numeric, loc));
  if rnd <> 0 then t := t || ((case when en then 'Cash rounding ' else 'Käteispyöristys ' end) || case when rnd > 0 then '+' else '' end || booking._money(rnd, loc)); end if;
  t := t || ((case when refund then (case when en then 'Refunded ' else 'Hyvitetty ' end) else (case when en then 'Paid ' else 'Maksettu ' end) end) || booking._money((s ->> 'total_paid')::numeric, loc));
  if nullif(sel ->> 'footer', '') is not null then t := t || ''::text || (sel ->> 'footer'); end if;
  return array_to_string(t, E'\n') || E'\n';
end $$;

-- Johku-esto säilyy. Poikkeus on vain oman maksetun at_sale-kortin tiedoksi-kuitti: snapshot merkitsee, ettei riviä kirjata.
create or replace function booking.receipts_no_johku_trg() returns trigger language plpgsql security definer set search_path to ''
as $$
begin
  if booking._acct_excluded(new.order_id, new.payment_id) then
    if coalesce((new.snapshot ->> 'informational')::boolean, false)
       and coalesce((new.snapshot ->> 'accounting')::boolean, true) = false
       and not booking._is_johku_row(new.order_id, new.payment_id)
       and exists (
         select 1 from booking.payments p
         join booking.gift_cards g on g.id = p.gift_card_id
        where p.id = new.payment_id
          and g.accounting_origin = 'native'
          and g.source is distinct from 'johku'
          and g.vat_treatment = 'at_sale'
          and g.complimentary = false)
    then
      return new;
    end if;
    perform booking._err('johku_not_accounted', 'Johku-lähtöiselle tilaukselle/maksulle ei anneta kuittia');
  end if;
  return new;
end $$;

create or replace function booking._issue_giftcard_info_receipt(p_payment_id bigint)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare pay booking.payments; o booking.orders; g booking.gift_cards; pm booking.payment_methods; v_lines jsonb; v_vat jsonb; v_gross numeric; v_vatsum numeric; v_buyer jsonb;
        v_seq int; v_year int; v_no text; v_ts timestamptz := now(); v_snap jsonb; v_id bigint; v_series text;
begin
  select * into pay from booking.payments where id = p_payment_id;
  if not found or pay.method is distinct from 'gift_card' or pay.amount <= 0 then return null; end if;
  if booking._is_johku_row(pay.order_id, pay.id) then return null; end if;
  select * into g from booking.gift_cards where id = pay.gift_card_id;
  if not found or g.accounting_origin is distinct from 'native' or g.source = 'johku' or g.vat_treatment is distinct from 'at_sale' or g.complimentary then return null; end if;
  select id into v_id from booking.receipts where payment_id = pay.id and kind = 'receipt';
  if found then return v_id; end if;
  select * into o from booking.orders where id = pay.order_id;
  if o.status = 'pending' then return null; end if;
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
  v_snap := jsonb_build_object('v', 1, 'document', 'receipt', 'informational', true, 'accounting', false, 'receipt_no', v_no, 'issued_at', v_ts, 'issued_local', to_char(v_ts at time zone 'Europe/Helsinki', 'DD.MM.YYYY HH24:MI'),
     'seller', booking._seller(), 'order_no', o.order_no,
     'payment', jsonb_build_object('id', pay.id, 'method', pay.method, 'method_label', coalesce(pm.label, pay.method), 'paid_at', pay.paid_at),
     'buyer', v_buyer, 'invoice_required', false, 'lines', v_lines, 'vat', v_vat,
     'total_gross', v_gross, 'total_net', v_gross - v_vatsum, 'total_vat', v_vatsum, 'rounding', 0, 'total_paid', v_gross,
     'currency', 'EUR', 'original', null, 'reason', null, 'locale', case when o.locale = 'en' then 'en' else 'fi' end);
  insert into booking.receipts(receipt_no, kind, series, year, seq, order_id, payment_id, issued_at, total_gross, locale, snapshot, text_body, created_by)
  values (v_no, 'receipt', v_series, v_year, v_seq, o.id, pay.id, v_ts, v_gross, v_snap ->> 'locale', v_snap, booking._receipt_text(v_snap), auth.uid()) returning id into v_id;
  perform booking._enqueue_email('receipt', o.id, v_id, pay.id, 'receipt:' || v_id);
  return v_id;
end $$;

CREATE OR REPLACE FUNCTION booking.payments_paid_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_info boolean;
begin
  v_info := exists (
    select 1 from booking.gift_cards g
     where g.id = new.gift_card_id
       and new.method = 'gift_card'
       and g.accounting_origin = 'native'
       and g.source is distinct from 'johku'
       and g.vat_treatment = 'at_sale'
       and g.complimentary = false
       and not booking._is_johku_row(new.order_id, new.id));
  if booking._acct_excluded(new.order_id, new.id) then
    if v_info and not exists (select 1 from booking.orders o where o.id = new.order_id and o.status = 'pending') then
      perform booking._alloc_payment_lines(new.id);
      perform booking._issue_giftcard_info_receipt(new.id);
    end if;
    return null;
  end if;
  perform booking._alloc_payment_lines(new.id);
  if new.method = 'gift_card' and exists (select 1 from booking.orders o where o.id = new.order_id and o.status = 'pending') then return null; end if;
  perform booking._on_payment_paid(new.id);
  return null;
end $function$;

CREATE OR REPLACE FUNCTION booking.orders_confirmed_mail_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pid bigint;
begin
  if new.external_source is not null then return null; end if;
  if booking._enqueue_email('order_confirmation', new.id, null, null, 'order_confirmation:' || new.id) then
    update booking.email_outbox set next_attempt_at = now() + interval '45 seconds' where dedupe_key = 'order_confirmation:' || new.id;
  end if;
  for pid in select p.id from booking.payments p
              join booking.gift_cards g on g.id = p.gift_card_id
              where p.order_id = new.id and p.method = 'gift_card' and p.status in ('paid', 'partially_refunded')
                and not exists (select 1 from booking.receipts rc where rc.payment_id = p.id and rc.kind = 'receipt')
                and g.accounting_origin = 'native' and g.source is distinct from 'johku'
                and g.vat_treatment = 'at_sale' and g.complimentary = false
                and not booking._is_johku_row(new.id, p.id)
              order by p.id loop
    perform booking._issue_giftcard_info_receipt(pid);
  end loop;
  for pid in select p.id from booking.payments p
              where p.order_id = new.id and p.method = 'gift_card' and p.status in ('paid', 'partially_refunded')
                and not exists (select 1 from booking.receipts rc where rc.payment_id = p.id and rc.kind = 'receipt')
                and not booking._acct_excluded(new.id, p.id)
              order by p.id loop
    perform booking._on_payment_paid(pid);
  end loop;
  return null;
end $function$;

create or replace function booking.admin_record_payment(p_order_id bigint, p_method text, p_amount numeric, p_note text default null, p_lines jsonb default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o booking.orders; v_pm booking.payment_methods; v_id bigint; v_unpaid numeric; l jsonb; v_it record; v_sum numeric := 0; v_rem numeric; v_round numeric; rc record;
begin
  perform booking._require_permission('payments.manage');
  if p_method = 'cash' then perform booking._err('cash_not_accepted', 'Käteistä ei oteta vastaan'); end if;
  select * into v_pm from booking.payment_methods where code = p_method and active and is_manual;
  if not found then perform booking._err('invalid_payment_method', 'Maksutapa ei ole käytössä / ei käsin kirjattava'); end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if o.external_source is not null or o.status not in ('pending','confirmed','completed') then perform booking._err('order_not_editable', 'Tilaukselle ei voi kirjata maksua'); end if;
  v_unpaid := case when o.status = 'pending' then greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0) else (booking._order_balance(o.id) ->> 'unpaid')::numeric end;
  if p_amount > v_unpaid + 0.004 then perform booking._err('amount_exceeds_unpaid', format('Summa ylittää maksamattoman osuuden (%s €)', v_unpaid)); end if;
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu käsin kirjatulla maksulla')
   where order_id = o.id and status = 'pending' and external_source is null
     and ((provider = 'manual' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = payments.id)) or provider <> 'manual');
  v_round := 0;
  insert into booking.payments(order_id, method, provider, status, amount, rounding, note, created_by)
  values (o.id, p_method, 'manual', 'pending', p_amount, v_round, p_note, auth.uid()) returning id into v_id;
  if p_lines is not null then
    if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then perform booking._err('invalid_items', 'p_lines väärässä muodossa'); end if;
    for l in select * from jsonb_array_elements(p_lines) loop
      if coalesce(l ->> 'item_id', '') !~ '^\d{1,18}$' or coalesce(l ->> 'amount', '') !~ '^\d{1,6}(\.\d{1,2})?$' then perform booking._err('invalid_items', 'Rivi virheellinen'); end if;
      select * into v_it from booking._order_uncovered(o.id, false) u where u.item_id = (l ->> 'item_id')::bigint;
      if not found then perform booking._err('item_not_found', 'Riviä ei löydy tai se on jo maksettu'); end if;
      if (l ->> 'amount')::numeric <= 0 or (l ->> 'amount')::numeric > v_it.remaining + 0.004 then perform booking._err('invalid_items', 'Rivin summa ylittää maksamattoman osuuden'); end if;
      insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
      values (v_id, v_it.item_id, v_it.description, v_it.kind, case when (l ->> 'amount')::numeric = v_it.remaining then v_it.quantity else 1 end, (l ->> 'amount')::numeric, v_it.vat_rate);
      v_sum := v_sum + (l ->> 'amount')::numeric;
    end loop;
    if abs(v_sum - p_amount) > 0.004 then perform booking._err('invalid_items', 'Rivien summa ei vastaa maksun summaa'); end if;
  else
    perform booking._alloc_payment_lines(v_id);
  end if;
  update booking.payments set status = 'paid', paid_at = now() where id = v_id;
  perform booking._sync_placeholder(o.id);
  perform booking._refresh_order_payment(o.id);
  update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = o.id and status = 'pending';
  update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()) where id = o.id and status = 'pending';
  select receipt_no, id into rc from booking.receipts where payment_id = v_id and kind = 'receipt';
  return jsonb_build_object('ok', true, 'payment_id', v_id, 'balance', booking._order_balance(o.id), 'receipt_id', rc.id, 'receipt_no', rc.receipt_no,
                            'rounding', (select rounding from booking.payments where id = v_id));
end $$;

update booking.payment_methods set active = false, is_manual = false where code = 'cash';

revoke all on function booking._published_text(text, text, text) from public, anon, authenticated;
grant execute on function booking._published_text(text, text, text) to service_role;
revoke all on function booking._issue_giftcard_info_receipt(bigint) from public, anon, authenticated;
grant execute on function booking._issue_giftcard_info_receipt(bigint) to service_role;

comment on function booking._issue_giftcard_info_receipt(bigint) is 'Maksetun oman at_sale-kortin lunastuksen tiedoksi-kuitti. Ei accounting_outboxia eikä myyntiraporttia. booking_119.';

comment on function booking._receipt_text(jsonb) is 'Tekstikuitti: rivillä veroton, ALV-%, ALV euroina ja brutto. booking_119.';
comment on function booking.admin_record_payment(bigint, text, numeric, text, jsonb) is 'Käsin kirjattu maksu. Käteinen hylätään (cash_not_accepted) eikä uutta käteispyöristystä lasketa. booking_119.';
