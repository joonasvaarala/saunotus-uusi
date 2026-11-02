-- ROLLBACK booking_238 (20261102180000_booking_238_receipt_multiday_when.sql). Uudelleenajettava.
-- Palauttaa booking_199:n _receipt_text-funktion ja poistaa aikaväliapurit.
set local lock_timeout = '5s';

drop function if exists booking._when_range(timestamptz, timestamptz, text, timestamptz);
drop function if exists booking._when_part(timestamp, boolean, boolean);

create or replace function booking._receipt_text(s jsonb) returns text
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
    t := t || ('   ' || case
                 when nullif(l ->> 'unit_gross', '') is not null then
                   coalesce(l ->> 'quantity', '1') || ' × ' || booking._money((l ->> 'unit_gross')::numeric, loc)
                   || ' = ' || booking._money(v_gross, loc) || ' · '
                 else coalesce(l ->> 'quantity', '1') || ' ' || w_qty || ' · '
               end
               || w_net || ' ' || booking._money(v_net, loc)
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

revoke all on function booking._receipt_text(jsonb) from public, anon, authenticated;
grant execute on function booking._receipt_text(jsonb) to service_role;
