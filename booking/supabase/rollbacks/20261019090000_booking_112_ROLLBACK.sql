-- ROLLBACK booking_112_invoice_customer_lookup.
-- Palauttaa booking_91/92-funktiot. Poistaa haun (laskutus- ja varausasiakkaat), siivousapurit ja Y-tunnuksen yksilöivän indeksin.
-- Ei poista laskutusasiakkaita.

set local lock_timeout = '5s';

drop index if exists booking.invoice_customers_business_uidx;

create or replace function booking._invoice_recalc(p_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare v_net numeric(12,2); v_vat numeric(12,2); v_gross numeric(12,2); v_break jsonb;
begin
  select coalesce(sum(line_net), 0), coalesce(sum(line_vat), 0), coalesce(sum(line_gross), 0)
    into v_net, v_vat, v_gross from booking.invoice_lines where invoice_id = p_id;
  select coalesce(jsonb_agg(jsonb_build_object('rate', rate, 'net', net, 'vat', vat, 'gross', gross) order by rate), '[]'::jsonb)
    into v_break
    from (select vat_rate as rate, sum(line_net) as net, sum(line_vat) as vat, sum(line_gross) as gross
            from booking.invoice_lines where invoice_id = p_id group by vat_rate) g;
  update booking.invoices set total_net = v_net, total_vat = v_vat, total_gross = v_gross, vat_breakdown = v_break,
         customer_snapshot = coalesce(booking._invoice_customer_json(customer_id), customer_snapshot)
   where id = p_id and status = 'draft';
end $$;

create or replace function booking.admin_save_invoice_customer(p_id bigint, p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_name text := btrim(coalesce(p ->> 'company_name', p ->> 'name', ''));
  v_contact text := nullif(btrim(coalesce(p ->> 'contact_name', '')), '');
  v_bid text := booking._norm_business_id(p ->> 'business_id');
  v_vat text := nullif(upper(regexp_replace(coalesce(p ->> 'vat_id', ''), '\s', '', 'g')), '');
  v_email text := nullif(lower(btrim(coalesce(p ->> 'email', ''))), '');
  v_phone text := nullif(btrim(coalesce(p ->> 'phone', '')), '');
  v_street text := nullif(btrim(coalesce(p ->> 'street', '')), '');
  v_zip text := nullif(btrim(coalesce(p ->> 'zip', '')), '');
  v_city text := nullif(btrim(coalesce(p ->> 'city', '')), '');
  v_country text := upper(btrim(coalesce(nullif(p ->> 'country', ''), 'FI')));
  v_ei text := nullif(upper(regexp_replace(coalesce(p ->> 'einvoice_address', ''), '\s', '', 'g')), '');
  v_op text := nullif(upper(regexp_replace(coalesce(p ->> 'einvoice_operator', ''), '\s', '', 'g')), '');
  v_ref text := nullif(btrim(coalesce(p ->> 'buyer_reference', p ->> 'reference', '')), '');
  v_id bigint := p_id;
begin
  perform booking._require_permission('invoices.manage');
  if char_length(v_name) < 2 or char_length(v_name) > 200 then perform booking._err('invalid_company_name', 'Anna yrityksen nimi'); end if;
  if v_bid is not null and not booking._business_id_ok(v_bid) then perform booking._err('invalid_business_id', 'Tarkista y-tunnus'); end if;
  if v_vat is null and v_bid is not null then v_vat := 'FI' || regexp_replace(v_bid, '\D', '', 'g'); end if;
  if v_vat is not null and v_vat !~ '^[A-Z]{2}[A-Z0-9]{8,14}$' then perform booking._err('invalid_vat_id', 'Tarkista ALV-tunnus'); end if;
  if v_email is not null and not booking._valid_email(v_email) then perform booking._err('invalid_email', 'Tarkista sähköposti'); end if;
  if v_country !~ '^[A-Z]{2}$' then perform booking._err('invalid_country', 'Tarkista maa'); end if;
  if (v_ei is null) <> (v_op is null) then perform booking._err('einvoice_incomplete', 'Anna sekä verkkolaskuosoite että välittäjätunnus'); end if;
  if v_ei is not null and not booking._ovt_ok(v_ei, v_bid) then perform booking._err('invalid_einvoice_address', 'Tarkista verkkolaskuosoite. OVT alkaa 0037 ja sisältää y-tunnuksen.'); end if;
  if v_op is not null and v_op !~ '^[A-Z0-9]{3,35}$' then perform booking._err('invalid_einvoice_operator', 'Tarkista välittäjätunnus'); end if;
  if v_ref is not null and char_length(v_ref) > 100 then perform booking._err('invalid_reference', 'Viite on liian pitkä'); end if;
  if v_id is null then
    insert into booking.invoice_customers(customer_id, company_name, contact_name, business_id, vat_id, email, phone, street, zip, city, country, einvoice_address, einvoice_operator, buyer_reference)
    values ((p ->> 'customer_id')::bigint, v_name, v_contact, v_bid, v_vat, v_email, v_phone, v_street, v_zip, v_city, v_country, v_ei, v_op, v_ref)
    returning id into v_id;
  else
    update booking.invoice_customers set
      company_name = v_name, contact_name = v_contact, business_id = v_bid, vat_id = v_vat, email = v_email, phone = v_phone,
      street = v_street, zip = v_zip, city = v_city, country = v_country, einvoice_address = v_ei, einvoice_operator = v_op, buyer_reference = v_ref
    where id = v_id;
    if not found then perform booking._err('not_found', 'Asiakasta ei löydy'); end if;
  end if;
  return booking._invoice_customer_json(v_id);
end $$;

create or replace function booking.admin_save_invoice(p_id bigint, p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_id bigint := p_id;
  v_cust bigint := (p ->> 'customer_id')::bigint;
  v_date date := coalesce((p ->> 'invoice_date')::date, (now() at time zone 'Europe/Helsinki')::date);
  v_due date := (p ->> 'due_date')::date;
  v_days int := coalesce((booking._setting('invoice_due_days', '14'::jsonb) #>> '{}')::int, 14);
  v_loc text := case when p ->> 'locale' = 'en' then 'en' else 'fi' end;
  v_notes text := nullif(btrim(coalesce(p ->> 'notes', '')), '');
  v_ref text := nullif(btrim(coalesce(p ->> 'buyer_reference', '')), '');
  v_order bigint := (p ->> 'order_id')::bigint;
begin
  perform booking._require_permission('invoices.manage');
  if v_cust is null or not exists (select 1 from booking.invoice_customers c where c.id = v_cust) then
    perform booking._err('invalid_customer', 'Valitse laskutusasiakas');
  end if;
  if v_due is null then v_due := v_date + v_days; end if;
  if v_due < v_date then perform booking._err('invalid_due', 'Eräpäivä ei voi olla ennen laskun päivää'); end if;
  if v_notes is not null and char_length(v_notes) > 2000 then perform booking._err('invalid_notes', 'Lisätiedot ovat liian pitkät'); end if;
  if v_id is null then
    insert into booking.invoices(customer_id, order_id, invoice_date, due_date, buyer_reference, notes, locale, seller_snapshot, customer_snapshot, created_by)
    values (v_cust, v_order, v_date, v_due, v_ref, v_notes, v_loc, booking._seller_invoice(), booking._invoice_customer_json(v_cust), auth.uid())
    returning id into v_id;
  else
    update booking.invoices set customer_id = v_cust, invoice_date = v_date, due_date = v_due, buyer_reference = v_ref, notes = v_notes, locale = v_loc,
           seller_snapshot = booking._seller_invoice()
     where id = v_id and status = 'draft';
    if not found then perform booking._err('invoice_locked', 'Vain luonnosta voi muokata'); end if;
  end if;
  perform booking._invoice_put_lines(v_id, coalesce(p -> 'lines', '[]'::jsonb), false);
  return booking._invoice_row(v_id);
end $$;

create or replace function booking._invoice_allocate(p_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare i booking.invoices; n int; v_no text;
begin
  select * into i from booking.invoices where id = p_id for update;
  if i.status <> 'draft' then perform booking._err('invoice_locked', 'Vain luonnos voidaan lähettää'); end if;
  if not exists (select 1 from booking.invoice_lines l where l.invoice_id = p_id) then
    perform booking._err('invalid_lines', 'Laskulla ei ole rivejä');
  end if;
  n := booking._next_invoice_seq(i.series);
  v_no := i.series || lpad(n::text, 6, '0');
  update booking.invoices set
    seq = n, invoice_no = v_no, reference_no = booking._fi_reference(lpad(n::text, 3, '0')),
    seller_snapshot = booking._seller_invoice(),
    customer_snapshot = booking._invoice_customer_json(i.customer_id),
    status = 'sent', sent_at = now(), locked_at = now()
  where id = p_id;
end $$;

create or replace function booking.admin_credit_invoice(p_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i booking.invoices; v_new bigint; v_days int := coalesce((booking._setting('invoice_due_days', '14'::jsonb) #>> '{}')::int, 14); v_date date;
begin
  perform booking._require_permission('invoices.manage');
  select * into i from booking.invoices where id = p_id for update;
  if not found then perform booking._err('not_found', 'Laskua ei löydy'); end if;
  if i.kind <> 'debit' or i.status not in ('sent', 'paid', 'overdue') then
    perform booking._err('invalid_status', 'Hyvitys tehdään lähetetystä veloituslaskusta');
  end if;
  if exists (select 1 from booking.invoices x where x.credit_of_id = i.id and x.status <> 'voided') then
    perform booking._err('already_credited', 'Laskulla on jo hyvityslasku');
  end if;
  v_date := (now() at time zone 'Europe/Helsinki')::date;
  insert into booking.invoices(kind, credit_of_id, customer_id, order_id, invoice_date, due_date, buyer_reference, notes, locale, seller_snapshot, customer_snapshot, created_by)
  values ('credit', i.id, i.customer_id, i.order_id, v_date, v_date + v_days, i.buyer_reference,
          left(nullif(concat_ws(E'\n', 'Hyvitys laskulle ' || coalesce(i.invoice_no, '#' || i.id::text), i.notes), ''), 2000),
          i.locale, booking._seller_invoice(), i.customer_snapshot, auth.uid())
  returning id into v_new;
  insert into booking.invoice_lines(invoice_id, line_no, description, quantity, unit, unit_price_net, vat_rate, line_net, line_vat, line_gross)
  select v_new, l.line_no, l.description, l.quantity, l.unit, -l.unit_price_net, l.vat_rate, -l.line_net, -l.line_vat, -l.line_gross
    from booking.invoice_lines l where l.invoice_id = i.id order by l.line_no;
  perform booking._invoice_recalc(v_new);
  return booking._invoice_row(v_new);
end $$;

create or replace function booking._ensure_draft_invoice(p_order_id bigint)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  o booking.orders; c booking.customers; v_cid bigint; v_iid bigint; v_has_c boolean := false;
  v_days int := coalesce((booking._setting('invoice_due_days', '14'::jsonb) #>> '{}')::int, 14);
  v_date date := (now() at time zone 'Europe/Helsinki')::date;
  v_name text; v_bid text; v_email text; r record; n int := 0;
  v_qty numeric; v_gross numeric; v_vat numeric; v_net numeric; v_rate numeric;
begin
  select * into o from booking.orders where id = p_order_id;
  if not found then return null; end if;
  select id into v_iid from booking.invoices where order_id = o.id and kind = 'debit' and status <> 'voided';
  if found then return v_iid; end if;
  if o.customer_id is not null then
    select * into c from booking.customers where id = o.customer_id;
    v_has_c := found;
  end if;
  v_name := coalesce(nullif(btrim(o.billing ->> 'company'), ''), case when v_has_c then nullif(btrim(c.company), '') end, 'Yritys');
  v_bid := nullif(coalesce(o.billing ->> 'business_id', case when v_has_c then c.business_id end), '');
  if v_bid is not null and not booking._business_id_ok(v_bid) then v_bid := null; end if;
  v_email := case when v_has_c then nullif(lower(btrim(coalesce(c.email, ''))), '') end;
  if v_email is not null and not booking._valid_email(v_email) then v_email := null; end if;
  insert into booking.invoice_customers(customer_id, company_name, contact_name, business_id, vat_id, email, phone, street, zip, city, country, einvoice_address, einvoice_operator, buyer_reference)
  values (o.customer_id, v_name, case when v_has_c then nullif(btrim(c.name), '') end, v_bid,
          case when v_bid is not null then 'FI' || regexp_replace(v_bid, '\D', '', 'g') end,
          v_email, case when v_has_c then nullif(btrim(c.phone), '') end,
          nullif(coalesce(o.billing ->> 'street', case when v_has_c then c.address end), ''),
          nullif(coalesce(o.billing ->> 'zip', case when v_has_c then c.zip end), ''),
          nullif(coalesce(o.billing ->> 'city', case when v_has_c then c.city end), ''),
          coalesce(nullif(o.billing ->> 'country', ''), case when v_has_c then nullif(c.country, '') end, 'FI'),
          nullif(upper(coalesce(o.billing ->> 'einvoice_address', case when v_has_c then c.einvoice_address end, '')), ''),
          nullif(upper(coalesce(o.billing ->> 'einvoice_operator', case when v_has_c then c.einvoice_operator end, '')), ''),
          nullif(coalesce(nullif(o.invoice_reference, ''), o.billing ->> 'reference', case when v_has_c then c.invoice_reference end), ''))
  returning id into v_cid;
  insert into booking.invoices(customer_id, order_id, invoice_date, due_date, buyer_reference, locale, seller_snapshot, customer_snapshot, created_by)
  values (v_cid, o.id, v_date, v_date + v_days,
          nullif(coalesce(nullif(o.invoice_reference, ''), o.billing ->> 'reference'), ''),
          case when o.locale = 'en' then 'en' else 'fi' end,
          booking._seller_invoice(), booking._invoice_customer_json(v_cid), null)
  returning id into v_iid;
  for r in select product_name, quantity, line_total_gross, vat_rate, line_net, line_vat from booking.order_items where order_id = o.id order by id loop
    v_gross := r.line_total_gross; v_rate := r.vat_rate;
    if v_gross = 0 then continue; end if;
    v_qty := case when coalesce(r.quantity, 0) = 0 then 1 else r.quantity end;
    v_net := coalesce(r.line_net, v_gross - round(v_gross * v_rate / (100 + v_rate), 2));
    v_vat := coalesce(r.line_vat, v_gross - v_net);
    n := n + 1;
    insert into booking.invoice_lines(invoice_id, line_no, description, quantity, unit, unit_price_net, vat_rate, line_net, line_vat, line_gross)
    values (v_iid, n, left(r.product_name, 300), v_qty, 'kpl', round(v_net / v_qty, 4), v_rate, v_net, v_vat, v_gross);
  end loop;
  if n = 0 and o.total_gross <> 0 then
    v_rate := coalesce((select rate from booking.vat_rates where active order by sort_order, rate desc limit 1), 0);
    v_gross := o.total_gross;
    v_vat := round(v_gross * v_rate / (100 + v_rate), 2);
    v_net := v_gross - v_vat;
    insert into booking.invoice_lines(invoice_id, line_no, description, quantity, unit, unit_price_net, vat_rate, line_net, line_vat, line_gross)
    values (v_iid, 1, 'Tilaus ' || o.order_no::text, 1, 'kpl', v_net, v_rate, v_net, v_vat, v_gross);
  end if;
  perform booking._invoice_recalc(v_iid);
  return v_iid;
end $$;

drop function if exists booking.admin_search_invoice_customers(text, integer);
drop function if exists booking._invoice_customer_snapshot(bigint, jsonb);
drop function if exists booking._invoice_customer_clean(jsonb);
drop function if exists booking._err_hint(text, text, text);

alter table booking.invoices drop column if exists customer_snapshot_locked;
