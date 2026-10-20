-- ROLLBACK booking_119_receipt_cash.
-- Palauttaa tekstikuitin, käteisen ja käteispyöristyksen booking_119:ää edeltävään tilaan.
set local lock_timeout = '5s';

drop function if exists booking._receipt_text(jsonb);
create function booking._receipt_text(s jsonb) returns text language plpgsql immutable set search_path = '' as $$
declare en boolean := coalesce(s ->> 'locale', 'fi') = 'en'; loc text := case when coalesce(s ->> 'locale', 'fi') = 'en' then 'en' else 'fi' end; t text[] := '{}'; l jsonb; v jsonb;
        sel jsonb := s -> 'seller'; b jsonb := s -> 'buyer'; d text; title text; refund boolean := s ->> 'document' = 'refund_receipt'; rnd numeric := coalesce((s ->> 'rounding')::numeric, 0);
begin
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
    t := t || d;
    t := t || ('   ' || (l ->> 'quantity') || (case when en then ' pcs × ' else ' kpl × ' end) || booking._money((l ->> 'unit_gross')::numeric, loc) || ' = ' || booking._money((l ->> 'line_gross')::numeric, loc)
               || ' (' || (case when en then 'VAT ' else 'ALV ' end) || booking._rate_txt((l ->> 'vat_rate')::numeric, loc) || ')');
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

CREATE OR REPLACE FUNCTION booking.payments_paid_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if booking._acct_excluded(new.order_id, new.id) then return null; end if;   -- Johku-historia (tilaus tai maksu) ei kuittiin
  perform booking._alloc_payment_lines(new.id);
  if new.method = 'cash' and new.rounding = 0 then
    update booking.payments set rounding = booking._cash_rounding(new.amount) where id = new.id;
  end if;
  -- booking_53: lahjakorttiosuus odottavalla tilauksella: kuitti viivästetään tilauksen vahvistukseen (orders_confirmed_mail_trg); jos pito vanhenee, kuittia ei synny
  if new.method = 'gift_card' and exists (select 1 from booking.orders o where o.id = new.order_id and o.status = 'pending') then return null; end if;
  perform booking._on_payment_paid(new.id);
  return null;
end $function$;

create or replace function booking.admin_record_payment(p_order_id bigint, p_method text, p_amount numeric, p_note text default null, p_lines jsonb default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o booking.orders; v_pm booking.payment_methods; v_id bigint; v_unpaid numeric; l jsonb; v_it record; v_sum numeric := 0; v_rem numeric; v_round numeric; rc record;
begin
  perform booking._require_permission('payments.manage');
  select * into v_pm from booking.payment_methods where code = p_method and active and is_manual;
  if not found then perform booking._err('invalid_payment_method', 'Maksutapa ei ole käytössä / ei käsin kirjattava'); end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if o.external_source is not null or o.status not in ('pending','confirmed','completed') then perform booking._err('order_not_editable', 'Tilaukselle ei voi kirjata maksua'); end if;
  v_unpaid := case when o.status = 'pending' then greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0) else (booking._order_balance(o.id) ->> 'unpaid')::numeric end;
  if p_amount > v_unpaid + 0.004 then perform booking._err('amount_exceeds_unpaid', format('Summa ylittää maksamattoman osuuden (%s €)', v_unpaid)); end if;
  -- rivittömät paikkaajat ja avoimet linkit peruutetaan; linkki luodaan tarvittaessa uudelleen jäännökselle
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu käsin kirjatulla maksulla')
   where order_id = o.id and status = 'pending' and external_source is null
     and ((provider = 'manual' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = payments.id)) or provider <> 'manual');
  v_round := case when p_method = 'cash' then booking._cash_rounding(p_amount) else 0 end;
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
  update booking.payments set status = 'paid', paid_at = now() where id = v_id;       -- trigger: rivit (jos puuttuvat), kuitti (vaihe B)
  perform booking._sync_placeholder(o.id);
  perform booking._refresh_order_payment(o.id);
  update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = o.id and status = 'pending';
  update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()) where id = o.id and status = 'pending';
  select receipt_no, id into rc from booking.receipts where payment_id = v_id and kind = 'receipt';
  return jsonb_build_object('ok', true, 'payment_id', v_id, 'balance', booking._order_balance(o.id), 'receipt_id', rc.id, 'receipt_no', rc.receipt_no,
                            'rounding', (select rounding from booking.payments where id = v_id));
end $$;

update booking.payment_methods set active = true, is_manual = true where code = 'cash';
drop function if exists booking._published_text(text, text, text);
drop function if exists booking._issue_giftcard_info_receipt(bigint);

create or replace function booking.receipts_no_johku_trg() returns trigger language plpgsql security definer set search_path to ''
as $$
begin
  if booking._acct_excluded(new.order_id, new.payment_id) then perform booking._err('johku_not_accounted', 'Johku-lähtöiselle tilaukselle/maksulle ei anneta kuittia'); end if;
  return new;
end $$;

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
              where p.order_id = new.id and p.method = 'gift_card' and p.status in ('paid', 'partially_refunded')
                and not exists (select 1 from booking.receipts rc where rc.payment_id = p.id and rc.kind = 'receipt')
                and not booking._acct_excluded(new.id, p.id)
              order by p.id loop
    perform booking._on_payment_paid(pid);
  end loop;
  return null;
end $function$;
