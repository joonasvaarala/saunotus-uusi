-- booking_31_talous_receipts (17.10.2026): vaihe B – kuitit, hyvityskuitit, sähköpostijono, tilausvahvistus. Vaatii booking_29–30. Rollback: booking_31_ROLLBACK.sql
insert into booking.settings(key, value, description, is_public) values
  ('functions_base_url', to_jsonb('https://sxbofnuisemspgquoxyv.supabase.co/functions/v1'::text), 'Edge-funktioiden osoite (kuitti-PDF-linkit viesteihin)', false),
  ('receipt_series', '{"receipt":"K","refund_receipt":"H"}'::jsonb, 'Kuittisarjat (aukoton numerointi vuosittain)', false)
on conflict (key) do nothing;

-- ===== apufunktiot =====
create function booking._money(p numeric, p_loc text default 'fi') returns text language sql immutable set search_path = '' as $$
  select case when p_loc = 'en' then to_char(p, 'FM999999990.00') else replace(to_char(p, 'FM999999990.00'), '.', ',') end || ' €'
$$;
create function booking._rate_txt(p numeric, p_loc text default 'fi') returns text language sql immutable set search_path = '' as $$
  select case when p_loc = 'en' then trim_scale(p)::text else replace(trim_scale(p)::text, '.', ',') end || ' %'
$$;
create function booking._seller() returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('name', s ->> 'name', 'legal_name', s ->> 'legal_name', 'business_id', s ->> 'business_id', 'vat_id', s ->> 'vat_id',
         'address', s ->> 'street', 'zip', s ->> 'postal_code', 'city', s ->> 'city', 'email', s ->> 'email', 'phone', s ->> 'phone', 'web', s ->> 'website',
         'logo_url', s ->> 'logo_url', 'footer', s ->> 'footer')
    from (select coalesce(booking._setting('seller'), '{}'::jsonb) as s) x
$$;
create function booking._next_receipt_no(p_series text, p_year integer) returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  insert into booking.receipt_counters(series, year, last_seq) values (p_series, p_year, 1)
  on conflict (series, year) do update set last_seq = booking.receipt_counters.last_seq + 1 returning last_seq into n;
  return n;
end $$;
-- ALV-erittely verokannoittain: pyöristys ryhmätasolla (KUITTI_VAATIMUKSET §2)
create function booking._vat_groups(p_lines jsonb) returns jsonb language sql immutable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('rate', rate, 'net', gross - vat, 'vat', vat, 'gross', gross) order by rate), '[]'::jsonb)
    from (select rate, gross, round(gross * rate / (100 + rate), 2) as vat
            from (select (l ->> 'vat_rate')::numeric as rate, sum((l ->> 'line_gross')::numeric) as gross from jsonb_array_elements(p_lines) l group by 1) g) h
$$;

-- ===== tekstikuitti snapshotista =====
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

-- ===== kuitin muodostus =====
create function booking._receipt_year(p_ts timestamptz) returns integer language sql immutable set search_path = '' as $$ select extract(year from p_ts at time zone 'Europe/Helsinki')::int $$;

create function booking._buyer_json(p_order_id bigint) returns jsonb language sql stable security definer set search_path = '' as $$
  select case when o.customer_kind <> 'private' and o.billing is not null then
           jsonb_build_object('name', o.billing ->> 'contact_name', 'company', o.billing ->> 'company', 'business_id', o.billing ->> 'business_id', 'address', o.billing ->> 'street',
                              'zip', o.billing ->> 'zip', 'city', o.billing ->> 'city', 'reference', o.invoice_reference) end
    from booking.orders o where o.id = p_order_id
$$;

create function booking._issue_receipt(p_payment_id bigint) returns bigint language plpgsql security definer set search_path = '' as $$
declare pay booking.payments; o booking.orders; pm booking.payment_methods; v_lines jsonb; v_vat jsonb; v_gross numeric; v_vatsum numeric; v_buyer jsonb; v_seq int; v_year int; v_no text;
        v_ts timestamptz := now(); v_snap jsonb; v_id bigint; v_series text;
begin
  select * into pay from booking.payments where id = p_payment_id;
  if not found or pay.external_source is not null or pay.amount <= 0 then return null; end if;
  select id into v_id from booking.receipts where payment_id = pay.id and kind = 'receipt';
  if found then return v_id; end if;
  select * into o from booking.orders where id = pay.order_id;
  select * into pm from booking.payment_methods where code = pay.method;
  select jsonb_agg(jsonb_build_object('description', pl.description, 'quantity', pl.quantity, 'unit_gross', round(pl.amount_gross / greatest(pl.quantity, 1), 2),
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
     'payment', jsonb_build_object('id', pay.id, 'method', pay.method, 'method_label', coalesce(pm.label, pay.method), 'paid_at', pay.paid_at),
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
end $$;

create function booking._issue_refund_receipt(p_refund_id bigint) returns bigint language plpgsql security definer set search_path = '' as $$
declare f booking.refunds; pay booking.payments; o booking.orders; pm booking.payment_methods; orig booking.receipts; v_lines jsonb; v_vat jsonb; v_gross numeric; v_vatsum numeric; v_buyer jsonb;
        v_seq int; v_year int; v_no text; v_ts timestamptz := now(); v_snap jsonb; v_id bigint; v_series text; v_rnd numeric := 0;
begin
  select * into f from booking.refunds where id = p_refund_id;
  if not found or f.status <> 'done' then return null; end if;
  select id into v_id from booking.receipts where refund_id = f.id;
  if found then return v_id; end if;
  select * into pay from booking.payments where id = f.payment_id;
  if pay.external_source is not null then return null; end if;
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
     'payment', jsonb_build_object('id', pay.id, 'method', pay.method, 'method_label', coalesce(pm.label, pay.method), 'paid_at', pay.paid_at),
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
end $$;

create or replace function booking._on_payment_paid(p_payment_id bigint) returns void language plpgsql security definer set search_path = '' as $$
declare v_id bigint; v_order bigint;
begin
  v_id := booking._issue_receipt(p_payment_id);
  if v_id is not null then
    select order_id into v_order from booking.payments where id = p_payment_id;
    perform booking._enqueue_email('receipt', v_order, v_id, p_payment_id, 'receipt:' || v_id);
  end if;
end $$;
create or replace function booking._on_refund_done(p_refund_id bigint) returns void language plpgsql security definer set search_path = '' as $$
declare v_id bigint; v_order bigint; v_pay bigint;
begin
  v_id := booking._issue_refund_receipt(p_refund_id);
  if v_id is not null then
    select order_id, payment_id into v_order, v_pay from booking.refunds where id = p_refund_id;
    perform booking._enqueue_email('refund_receipt', v_order, v_id, v_pay, 'receipt:' || v_id);
  end if;
end $$;

-- ===== tilausvahvistus (aina kun natiivi tilaus vahvistuu; viive 45 s) =====
create function booking.orders_confirmed_mail_trg() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.external_source is not null then return null; end if;
  if booking._enqueue_email('order_confirmation', new.id, null, null, 'order_confirmation:' || new.id) then
    update booking.email_outbox set next_attempt_at = now() + interval '45 seconds' where dedupe_key = 'order_confirmation:' || new.id;
  end if;
  return null;
end $$;
create trigger orders_confirmed_ins after insert on booking.orders for each row when (new.status = 'confirmed') execute function booking.orders_confirmed_mail_trg();
create trigger orders_confirmed_upd after update of status on booking.orders for each row when (new.status = 'confirmed' and old.status is distinct from 'confirmed') execute function booking.orders_confirmed_mail_trg();
-- ===== sähköpostijono: lähettäjän (edge send-emails) rajapinta =====
create function booking._cron_secret_ok(p_secret text) returns boolean language sql stable security definer set search_path = '' as $$
  select p_secret is not null and exists (select 1 from vault.decrypted_secrets where name = 'calendar_sync_cron_secret' and decrypted_secret = p_secret)
$$;

create function booking.email_outbox_claim(p_limit integer default 20) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_ids bigint[]; v_site text := coalesce(booking._setting('site_base_url') #>> '{}', ''); v_op text := coalesce(booking._setting('order_page_path') #>> '{}', '/tilaus/');
        v_pp text := coalesce(booking._setting('payment_link_path') #>> '{}', '/maksa/'); v_res jsonb;
begin
  update booking.email_outbox set status = 'pending', locked_at = null where status = 'sending' and locked_at < now() - interval '10 minutes';
  select coalesce(array_agg(id), '{}') into v_ids from (
    select id from booking.email_outbox where status in ('pending','failed') and next_attempt_at <= now() order by id limit greatest(least(coalesce(p_limit, 20), 50), 1) for update skip locked) q;
  update booking.email_outbox set status = 'sending', locked_at = now(), attempts = attempts + 1 where id = any (v_ids);
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'kind', e.kind, 'locale', e.locale, 'attempts', e.attempts, 'max_attempts', e.max_attempts, 'to', c.email, 'to_name', c.name,
      'order', case when o.id is null then null else jsonb_build_object('order_no', o.order_no, 'order_url', v_site || v_op || '?t=' || o.public_token, 'total', o.total_gross, 'status', o.status,
          'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.product_name, 'quantity', i.quantity, 'line_total', i.line_total_gross, 'vat_rate', i.vat_rate, 'kind', i.kind) order by i.id) from booking.order_items i where i.order_id = o.id), '[]'::jsonb),
          'reservations', coalesce((select jsonb_agg(jsonb_build_object('product_name', it.product_name, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'status', r.status) order by r.starts_at)
              from booking.reservations r left join booking.order_items it on it.id = r.order_item_id where r.order_id = o.id), '[]'::jsonb)) end,
      'receipt', case when rc.id is null then null else jsonb_build_object('id', rc.id, 'receipt_no', rc.receipt_no, 'kind', rc.kind, 'text_body', rc.text_body, 'public_token', rc.public_token, 'total', rc.total_gross, 'issued_at', rc.issued_at) end,
      'payment', case when p.id is null then null else jsonb_build_object('id', p.id, 'amount', p.amount, 'link_url', case when p.provider <> 'manual' and p.status = 'pending' then v_site || v_pp || '?p=' || p.link_token end,
          'link_expires_at', p.link_expires_at) end) order by e.id), '[]'::jsonb)
    into v_res
    from booking.email_outbox e left join booking.orders o on o.id = e.order_id left join booking.customers c on c.id = o.customer_id
    left join booking.receipts rc on rc.id = e.receipt_id left join booking.payments p on p.id = e.payment_id
   where e.id = any (v_ids);
  return v_res;
end $$;

create function booking.email_outbox_mark(p_id bigint, p_result text, p_provider_id text default null, p_error text default null) returns void language plpgsql security definer set search_path = '' as $$
declare e booking.email_outbox;
begin
  if p_result not in ('sent','dry_run','failed','skipped') then perform booking._err('invalid_param', 'p_result'); end if;
  select * into e from booking.email_outbox where id = p_id for update;
  if not found then perform booking._err('not_found', 'Viestiä ei löydy'); end if;
  if p_result = 'sent' then
    update booking.email_outbox set status = 'sent', sent_at = now(), provider_id = p_provider_id, last_error = null, locked_at = null where id = p_id;
    if e.receipt_id is not null then update booking.receipts set sent_at = now() where id = e.receipt_id and sent_at is null; end if;
    if e.kind = 'payment_link' and e.payment_id is not null then update booking.payments set link_sent_at = now() where id = e.payment_id; end if;
  elsif p_result = 'failed' then
    update booking.email_outbox set status = case when attempts >= max_attempts then 'dead' else 'failed' end, last_error = left(p_error, 500), locked_at = null,
           next_attempt_at = now() + make_interval(mins => attempts * attempts) where id = p_id;
  else
    update booking.email_outbox set status = p_result, last_error = left(p_error, 500), locked_at = null where id = p_id;
  end if;
end $$;

-- ===== kuittien RPC:t =====
create function booking._receipt_json(rc booking.receipts, p_with_order boolean default true) returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', rc.id, 'receipt_no', rc.receipt_no, 'kind', rc.kind, 'issued_at', rc.issued_at, 'total_gross', rc.total_gross, 'snapshot', rc.snapshot, 'text_body', rc.text_body,
    'public_token', rc.public_token, 'pdf_url', (booking._setting('functions_base_url') #>> '{}') || '/receipt-pdf?t=' || rc.public_token, 'sent_at', rc.sent_at)
    || case when p_with_order then jsonb_build_object('order_id', rc.order_id, 'payment_id', rc.payment_id, 'refund_id', rc.refund_id) else '{}'::jsonb end
$$;
create function booking.admin_get_receipt(p_receipt_id bigint) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare rc booking.receipts;
begin
  perform booking._require_staff();
  select * into rc from booking.receipts where id = p_receipt_id;
  if not found then perform booking._err('receipt_not_found', 'Kuittia ei löydy'); end if;
  return booking._receipt_json(rc, true);
end $$;
create function booking.admin_resend_receipt(p_receipt_id bigint) returns jsonb language plpgsql security definer set search_path = '' as $$
declare rc booking.receipts; v_ok boolean;
begin
  perform booking._require_permission('payments.manage');
  select * into rc from booking.receipts where id = p_receipt_id;
  if not found then perform booking._err('receipt_not_found', 'Kuittia ei löydy'); end if;
  v_ok := booking._enqueue_email(case when rc.kind = 'receipt' then 'receipt' else 'refund_receipt' end, rc.order_id, rc.id, rc.payment_id, 'receipt:' || rc.id || ':resend:' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISS'));
  return jsonb_build_object('ok', true, 'email_queued', v_ok);
end $$;
create function booking.public_get_receipt(p_order_token uuid, p_receipt_no text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare rc booking.receipts;
begin
  if booking._client_ip() is not null and not booking._rate_limit('receipt:' || booking._client_ip(), 60, interval '10 minutes') then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta pyyntöä'); end if;
  select r.* into rc from booking.receipts r join booking.orders o on o.id = r.order_id where o.public_token = p_order_token and r.receipt_no = p_receipt_no;
  if not found then return jsonb_build_object('ok', false, 'code', 'receipt_not_found', 'message', 'Kuittia ei löydy'); end if;
  return jsonb_build_object('ok', true) || booking._receipt_json(rc, false);
end $$;
-- edge receipt-pdf (service_role): kuitti julkisella tokenilla
create function booking.receipt_by_token(p_token uuid) returns jsonb language sql stable security definer set search_path = '' as $$
  select booking._receipt_json(rc, false) from booking.receipts rc where rc.public_token = p_token
$$;
create function booking.receipt_set_pdf(p_receipt_id bigint, p_path text) returns void language sql security definer set search_path = '' as $$
  update booking.receipts set pdf_path = p_path, pdf_generated_at = now() where id = p_receipt_id
$$;

-- ALV-puutelista: vain tuotteet joilla on hinta (tarjouspyyntötuotteet eivät mene tilaukselle)
create or replace function booking.admin_list_vat_rates() returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_staff();
  return jsonb_build_object(
    'rates', coalesce((select jsonb_agg(jsonb_build_object('rate', v.rate, 'label', v.label, 'active', v.active,
        'products', (select count(*) from kb.products p where p.vat_rate = v.rate), 'addons', (select count(*) from booking.addons a where a.vat_rate = v.rate)) order by v.sort_order, v.rate)
        from booking.vat_rates v), '[]'::jsonb),
    'missing', coalesce((select jsonb_agg(m) from (
        select jsonb_build_object('kind', 'product', 'id', p.id, 'name', p.name) m from kb.products p where p.vat_rate is null and p.active and p.price is not null
        union all select jsonb_build_object('kind', 'addon', 'id', a.id, 'name', a.name) from booking.addons a where a.vat_rate is null) x), '[]'::jsonb),
    'quote_only', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name)) from kb.products p where p.vat_rate is null and p.active and p.price is null), '[]'::jsonb));
end $$;

-- ===== tallennus ja ajastus =====
insert into storage.buckets(id, name, public) values ('receipts', 'receipts', false) on conflict (id) do nothing;

do $$ declare r record; begin
  for r in select p.oid::regprocedure as f, p.proname from pg_proc p where p.pronamespace = 'booking'::regnamespace
            and p.proname in ('_money','_rate_txt','_seller','_next_receipt_no','_vat_groups','_receipt_text','_receipt_year','_buyer_json','_issue_receipt','_issue_refund_receipt','_on_payment_paid','_on_refund_done',
                              'orders_confirmed_mail_trg','_cron_secret_ok','email_outbox_claim','email_outbox_mark','_receipt_json','admin_get_receipt','admin_resend_receipt','public_get_receipt',
                              'receipt_by_token','receipt_set_pdf','admin_list_vat_rates') loop
    execute format('revoke all on function %s from public, anon, authenticated', r.f);
    execute format('grant execute on function %s to service_role', r.f);
    if r.proname like 'admin\_%' then execute format('grant execute on function %s to authenticated', r.f); end if;
    if r.proname = 'public_get_receipt' then execute format('grant execute on function %s to anon, authenticated', r.f); end if;
  end loop;
end $$;

select cron.schedule('booking_send_emails', '* * * * *', $cron$
  select case when exists (select 1 from booking.email_outbox where status in ('pending','failed') and next_attempt_at <= now()) then
    net.http_post(url := 'https://sxbofnuisemspgquoxyv.supabase.co/functions/v1/send-emails', body := '{}'::jsonb,
      headers := jsonb_build_object('content-type', 'application/json', 'x-sync-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'calendar_sync_cron_secret')),
      timeout_milliseconds := 50000) end;
$cron$);
