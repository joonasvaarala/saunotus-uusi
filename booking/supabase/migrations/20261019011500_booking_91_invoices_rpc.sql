-- booking_91_invoices_rpc (18.10.2026)
-- Laskunumerot (aukoton, sama transaktio), suomalainen viite, normalisoitu JSON, lukitus, hallinnan RPC:t.
-- Kaikki kirjoittavat funktiot: SECURITY DEFINER, search_path '', invoices.manage.
-- Rollback: rollbacks/20261019011500_booking_91_ROLLBACK.sql
-- Ei tuotantoajoa. Ei salaisuuksia. Procountor-asiakasta ei ole tässä.

set local lock_timeout = '5s';

create unique index invoices_one_credit on booking.invoices(credit_of_id)
  where credit_of_id is not null and status <> 'voided';

-- ---------- viite ja numerointi ----------
create function booking._fi_reference(p_base text)
returns text language plpgsql immutable set search_path = '' as $$
declare
  s text := regexp_replace(coalesce(p_base, ''), '\D', '', 'g');
  i int; d int; acc int := 0; w int;
begin
  if s = '' then s := '0'; end if;
  s := lpad(s, greatest(char_length(s), 3), '0');
  if char_length(s) > 19 then perform booking._err('invalid_reference', 'Viitteen pohja on liian pitkä'); end if;
  for i in 1..char_length(s) loop
    d := substr(s, char_length(s) - i + 1, 1)::int;
    w := case (i - 1) % 3 when 0 then 7 when 1 then 3 else 1 end;
    acc := acc + d * w;
  end loop;
  return s || ((10 - (acc % 10)) % 10)::text;
end $$;

create function booking._next_invoice_seq(p_series text default 'L')
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  perform pg_advisory_xact_lock(hashtext('booking.invoice_counters'), hashtext(p_series));
  update booking.invoice_counters set last_seq = last_seq + 1 where series = p_series returning last_seq into n;
  if n is null then perform booking._err('invalid_series', 'Laskusarjaa ei ole'); end if;
  return n;
end $$;

create function booking._ovt_ok(p_address text, p_business_id text)
returns boolean language plpgsql immutable set search_path = '' as $$
declare v text := upper(regexp_replace(coalesce(p_address, ''), '\s', '', 'g'));
        digits text := regexp_replace(coalesce(p_business_id, ''), '\D', '', 'g');
begin
  if v !~ '^0037[0-9]{8,13}$' then return false; end if;
  if digits <> '' and substr(v, 5, 8) <> digits then return false; end if;
  return true;
end $$;

create function booking._seller_invoice()
returns jsonb language sql stable security definer set search_path = '' as $$
  select booking._seller() || jsonb_build_object(
    'iban', coalesce(b ->> 'iban', ''),
    'bic', coalesce(b ->> 'bic', ''),
    'bank_name', coalesce(b ->> 'name', ''))
  from (select coalesce(booking._setting('invoice_bank'), '{}'::jsonb) as b) x
$$;

create function booking._invoice_customer_json(p_id bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', c.id, 'customer_id', c.customer_id, 'name', c.company_name, 'company_name', c.company_name,
    'contact_name', c.contact_name, 'business_id', c.business_id, 'vat_id', c.vat_id,
    'email', c.email, 'phone', c.phone, 'street', c.street, 'zip', c.zip, 'city', c.city, 'country', c.country,
    'einvoice_address', c.einvoice_address, 'einvoice_operator', c.einvoice_operator, 'buyer_reference', c.buyer_reference,
    'address', nullif(concat_ws(', ', nullif(btrim(c.street), ''), nullif(concat_ws(' ', nullif(btrim(c.zip), ''), nullif(btrim(c.city), '')), '')), ''))
  from booking.invoice_customers c where c.id = p_id
$$;

create function booking._invoice_recalc(p_id bigint)
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

create function booking.invoice_normalized(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare i booking.invoices; c jsonb; v_notes text;
begin
  select * into i from booking.invoices where id = p_id;
  if not found then return null; end if;
  c := i.customer_snapshot;
  v_notes := nullif(btrim(coalesce(i.notes, '')), '');
  if nullif(btrim(coalesce(i.buyer_reference, c ->> 'buyer_reference', '')), '') is not null then
    v_notes := nullif(concat_ws(E'\n', 'Viitteenne: ' || coalesce(i.buyer_reference, c ->> 'buyer_reference'), v_notes), '');
  end if;
  return jsonb_build_object(
    'customer', jsonb_build_object(
      'name', c ->> 'name',
      'business_id', c ->> 'business_id',
      'vat_id', c ->> 'vat_id',
      'einvoice_address', c ->> 'einvoice_address',
      'einvoice_operator', c ->> 'einvoice_operator',
      'email', c ->> 'email',
      'address', c ->> 'address'),
    'number', i.invoice_no,
    'date', i.invoice_date,
    'due_date', i.due_date,
    'reference', i.reference_no,
    'currency', i.currency,
    'lines', coalesce((select jsonb_agg(jsonb_build_object(
        'description', l.description, 'quantity', l.quantity, 'unit', l.unit,
        'unit_price_net', l.unit_price_net, 'vat_rate', l.vat_rate) order by l.line_no)
      from booking.invoice_lines l where l.invoice_id = i.id), '[]'::jsonb),
    'notes', v_notes);
end $$;

-- ---------- lukitus ----------
create function booking.invoices_lock_trg()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    perform booking._err('invoice_locked', 'Laskua ei poisteta. Mitätöi luonnos tai tee hyvityslasku.');
  end if;
  if old.status <> 'draft' then
    if new.customer_id is distinct from old.customer_id
       or new.order_id is distinct from old.order_id
       or new.credit_of_id is distinct from old.credit_of_id
       or new.kind is distinct from old.kind
       or new.invoice_date is distinct from old.invoice_date
       or new.due_date is distinct from old.due_date
       or new.reference_no is distinct from old.reference_no
       or new.buyer_reference is distinct from old.buyer_reference
       or new.currency is distinct from old.currency
       or new.notes is distinct from old.notes
       or new.locale is distinct from old.locale
       or new.seller_snapshot is distinct from old.seller_snapshot
       or new.customer_snapshot is distinct from old.customer_snapshot
       or new.total_net is distinct from old.total_net
       or new.total_vat is distinct from old.total_vat
       or new.total_gross is distinct from old.total_gross
       or new.vat_breakdown is distinct from old.vat_breakdown
       or new.series is distinct from old.series
       or new.seq is distinct from old.seq
       or new.invoice_no is distinct from old.invoice_no
       or new.public_token is distinct from old.public_token
       or new.created_by is distinct from old.created_by
    then
      perform booking._err('invoice_locked', 'Lähetettyä laskua ei voi muokata. Tee hyvityslasku.');
    end if;
    if new.status is distinct from old.status and not (
         (old.status = 'sent' and new.status in ('paid', 'overdue', 'credited'))
         or (old.status = 'overdue' and new.status in ('paid', 'credited'))
         or (old.status = 'paid' and new.status = 'credited'))
    then
      perform booking._err('invalid_status', 'Laskun tilasiirtymä ei ole sallittu');
    end if;
  elsif new.status is distinct from old.status and new.status not in ('sent', 'voided') then
    perform booking._err('invalid_status', 'Luonnos voidaan lähettää tai mitätöidä');
  end if;
  return new;
end $$;
create trigger invoices_lock before update or delete on booking.invoices
  for each row execute function booking.invoices_lock_trg();

create function booking.invoice_lines_lock_trg()
returns trigger language plpgsql set search_path = '' as $$
declare st text;
begin
  select status into st from booking.invoices where id = coalesce(new.invoice_id, old.invoice_id);
  if st is distinct from 'draft' then
    perform booking._err('invoice_locked', 'Lähetetyn laskun rivejä ei voi muuttaa. Tee hyvityslasku.');
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
create trigger invoice_lines_lock before insert or update or delete on booking.invoice_lines
  for each row execute function booking.invoice_lines_lock_trg();

-- ---------- rivit ----------
create function booking._invoice_put_lines(p_id bigint, p_lines jsonb, p_allow_inactive boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
declare l jsonb; n int := 0; v_qty numeric; v_price numeric; v_rate numeric; v_net numeric; v_vat numeric; v_desc text; v_unit text;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 1 or jsonb_array_length(p_lines) > 100 then
    perform booking._err('invalid_lines', 'Laskulla pitää olla 1–100 riviä');
  end if;
  delete from booking.invoice_lines where invoice_id = p_id;
  for l in select value from jsonb_array_elements(p_lines) loop
    n := n + 1;
    v_desc := btrim(coalesce(l ->> 'description', ''));
    v_unit := coalesce(nullif(btrim(coalesce(l ->> 'unit', '')), ''), 'kpl');
    v_qty := (l ->> 'quantity')::numeric;
    v_price := (l ->> 'unit_price_net')::numeric;
    v_rate := (l ->> 'vat_rate')::numeric;
    if char_length(v_desc) < 1 or char_length(v_desc) > 300 then perform booking._err('invalid_lines', 'Tarkista rivin kuvaus'); end if;
    if v_qty is null or v_qty = 0 or v_qty <> round(v_qty, 3) then perform booking._err('invalid_lines', 'Tarkista määrä'); end if;
    if v_price is null or v_price <> round(v_price, 4) then perform booking._err('invalid_lines', 'Tarkista yksikköhinta'); end if;
    if v_rate is null or not exists (select 1 from booking.vat_rates r where r.rate = v_rate and (p_allow_inactive or r.active)) then
      perform booking._err('invalid_vat', 'ALV-kanta ei ole käytössä');
    end if;
    v_net := round(v_qty * v_price, 2);
    v_vat := round(v_net * v_rate / 100, 2);
    insert into booking.invoice_lines(invoice_id, line_no, description, quantity, unit, unit_price_net, vat_rate, line_net, line_vat, line_gross)
    values (p_id, n, v_desc, v_qty, v_unit, v_price, v_rate, v_net, v_vat, v_net + v_vat);
  end loop;
  perform booking._invoice_recalc(p_id);
end $$;

create function booking._invoice_row(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare i booking.invoices;
begin
  select * into i from booking.invoices where id = p_id;
  if not found then return null; end if;
  return to_jsonb(i) || jsonb_build_object(
    'customer', booking._invoice_customer_json(i.customer_id),
    'lines', coalesce((select jsonb_agg(to_jsonb(l) order by l.line_no) from booking.invoice_lines l where l.invoice_id = i.id), '[]'::jsonb),
    'normalized', booking.invoice_normalized(i.id));
end $$;

-- ---------- asiakas ----------
create function booking.admin_save_invoice_customer(p_id bigint, p jsonb)
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

create function booking.admin_list_invoice_customers(p_search text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_s text := nullif(btrim(coalesce(p_search, '')), ''); v_like text;
begin
  perform booking._require_permission('invoices.manage');
  if v_s is not null then v_like := '%' || replace(replace(replace(v_s, '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;
  return coalesce((select jsonb_agg(booking._invoice_customer_json(c.id) order by c.company_name, c.id)
    from booking.invoice_customers c
   where v_s is null or c.company_name ilike v_like or c.email ilike v_like or c.business_id ilike v_like or c.contact_name ilike v_like), '[]'::jsonb);
end $$;

-- ---------- lasku ----------
create function booking.admin_save_invoice(p_id bigint, p jsonb)
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

create function booking.admin_get_invoice(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_permission('invoices.manage');
  if booking._invoice_row(p_id) is null then perform booking._err('not_found', 'Laskua ei löydy'); end if;
  return booking._invoice_row(p_id);
end $$;

create function booking.admin_list_invoices(
  p_search text default null, p_status text default null, p_kind text default null,
  p_from date default null, p_to date default null, p_limit integer default 50, p_offset integer default 0)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_s text := nullif(btrim(coalesce(p_search, '')), '');
  v_like text; v_lim int := coalesce(p_limit, 50); v_off int := greatest(coalesce(p_offset, 0), 0);
  v_total int; v_rows jsonb;
begin
  perform booking._require_permission('invoices.manage');
  if v_lim < 1 or v_lim > 200 then perform booking._err('invalid_param', 'p_limit 1–200'); end if;
  if p_status is not null and p_status not in ('draft','sent','paid','overdue','credited','voided') then
    perform booking._err('invalid_param', 'p_status'); end if;
  if p_kind is not null and p_kind not in ('debit','credit') then perform booking._err('invalid_param', 'p_kind'); end if;
  update booking.invoices set status = 'overdue'
   where status = 'sent' and due_date < (now() at time zone 'Europe/Helsinki')::date;
  if v_s is not null then v_like := '%' || replace(replace(replace(v_s, '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;
  with base as (
    select i.id
      from booking.invoices i
      join booking.invoice_customers c on c.id = i.customer_id
     where (p_status is null or i.status = p_status)
       and (p_kind is null or i.kind = p_kind)
       and (p_from is null or i.invoice_date >= p_from)
       and (p_to is null or i.invoice_date <= p_to)
       and (v_s is null or i.invoice_no ilike v_like or c.company_name ilike v_like or c.business_id ilike v_like
            or c.email ilike v_like or i.reference_no ilike v_like or i.buyer_reference ilike v_like)
  )
  select (select count(*) from base),
         coalesce((select jsonb_agg(booking._invoice_row(b.id) order by b.id desc)
            from (select id from base order by id desc offset v_off limit v_lim) b), '[]'::jsonb)
    into v_total, v_rows;
  return jsonb_build_object('total', v_total, 'rows', v_rows);
end $$;

create function booking._invoice_allocate(p_id bigint)
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

create function booking._invoice_queue_dispatch(p_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare i booking.invoices; v_mode text := coalesce(booking._setting('invoice_dispatch_mode', '"dry_run"'::jsonb) #>> '{}', 'dry_run');
        v_payload jsonb; v_status text;
begin
  select * into i from booking.invoices where id = p_id for update;
  if i.customer_snapshot ->> 'einvoice_address' is null or i.customer_snapshot ->> 'einvoice_operator' is null then
    perform booking._err('einvoice_incomplete', 'Verkkolasku tarvitsee OVT-tunnuksen ja välittäjätunnuksen');
  end if;
  v_payload := booking.invoice_normalized(p_id);
  if v_mode = 'live' then
    v_status := 'queued';
  else
    v_status := 'dry_run';
  end if;
  update booking.invoices set dispatch_status = v_status, dispatch_attempts = dispatch_attempts + 1,
         dispatch_error = case when v_status = 'dry_run' then 'dry_run' else null end
   where id = p_id;
  insert into booking.invoice_dispatch_log(invoice_id, attempt, status, provider, error, payload)
  values (p_id, (select dispatch_attempts from booking.invoices where id = p_id), v_status,
          case when v_status = 'dry_run' then 'dry_run' else 'provider' end,
          case when v_status = 'dry_run' then 'dry_run: Procountor-adapteri ei ole kytketty' else null end,
          v_payload);
end $$;

create function booking.admin_send_invoice(p_id bigint, p_einvoice boolean default true, p_email boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i booking.invoices; v_email text;
begin
  perform booking._require_permission('invoices.manage');
  if not coalesce(p_einvoice, false) and not coalesce(p_email, false) then
    perform booking._err('invalid_param', 'Valitse verkkolasku tai sähköposti');
  end if;
  select * into i from booking.invoices where id = p_id for update;
  if not found then perform booking._err('not_found', 'Laskua ei löydy'); end if;
  if i.status = 'draft' then
    perform booking._invoice_allocate(p_id);
  elsif i.status not in ('sent', 'overdue') then
    perform booking._err('invalid_status', 'Tätä laskua ei voi lähettää');
  end if;
  select * into i from booking.invoices where id = p_id;
  if coalesce(p_einvoice, false) then
    if i.dispatch_status in ('sent', 'dry_run', 'sending', 'queued') then
      perform booking._err('already_sent', 'Verkkolasku on jo jonossa tai lähetetty');
    end if;
    perform booking._invoice_queue_dispatch(p_id);
  end if;
  if coalesce(p_email, false) then
    v_email := nullif(i.customer_snapshot ->> 'email', '');
    if v_email is null or not booking._valid_email(v_email) then perform booking._err('invalid_email', 'Asiakkaalla ei ole sähköpostia'); end if;
    insert into booking.email_outbox(kind, order_id, locale, dedupe_key, payload)
    values ('invoice_pdf', i.order_id, i.locale,
            'invoice_pdf:' || i.id || ':' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'),
            jsonb_build_object('to_email', v_email, 'to_name', coalesce(i.customer_snapshot ->> 'contact_name', i.customer_snapshot ->> 'name'), 'invoice_id', i.id));
  end if;
  if i.credit_of_id is not null then
    update booking.invoices set status = 'credited' where id = i.credit_of_id and status in ('sent', 'paid', 'overdue');
  end if;
  return booking._invoice_row(p_id);
end $$;

create function booking.admin_mark_invoice_paid(p_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i booking.invoices;
begin
  perform booking._require_permission('invoices.manage');
  select * into i from booking.invoices where id = p_id for update;
  if not found then perform booking._err('not_found', 'Laskua ei löydy'); end if;
  if i.kind = 'credit' then perform booking._err('invalid_status', 'Hyvityslaskua ei merkitä maksetuksi'); end if;
  if i.status not in ('sent', 'overdue') then perform booking._err('invalid_status', 'Vain lähetetty lasku voidaan merkitä maksetuksi'); end if;
  update booking.invoices set status = 'paid', paid_at = now() where id = p_id;
  if i.order_id is not null then
    update booking.payments set status = 'paid', paid_at = now()
     where order_id = i.order_id and method = 'invoice' and status = 'pending';
    perform booking._refresh_order_payment(i.order_id);
  end if;
  return booking._invoice_row(p_id);
end $$;

create function booking.admin_void_invoice(p_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform booking._require_permission('invoices.manage');
  update booking.invoices set status = 'voided', voided_at = now()
   where id = p_id and status = 'draft' and invoice_no is null;
  if not found then perform booking._err('invalid_status', 'Vain numeroimaton luonnos voidaan mitätöidä'); end if;
  return booking._invoice_row(p_id);
end $$;

create function booking.admin_credit_invoice(p_id bigint)
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

create function booking.admin_retry_invoice_dispatch(p_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i booking.invoices;
begin
  perform booking._require_permission('invoices.manage');
  select * into i from booking.invoices where id = p_id for update;
  if not found then perform booking._err('not_found', 'Laskua ei löydy'); end if;
  if i.status not in ('sent', 'overdue', 'paid') then perform booking._err('invalid_status', 'Lähetä lasku ensin'); end if;
  if i.dispatch_status not in ('failed', 'dry_run', 'skipped', 'none') then
    perform booking._err('invalid_status', 'Lähetys ei ole uudelleenyritystilassa');
  end if;
  update booking.invoices set dispatch_status = 'none', dispatch_error = null where id = p_id;
  perform booking._invoice_queue_dispatch(p_id);
  return booking._invoice_row(p_id);
end $$;

create function booking.admin_list_invoice_dispatch(p_invoice_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_permission('invoices.manage');
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', d.id, 'attempt', d.attempt, 'status', d.status, 'provider', d.provider, 'error', d.error, 'created_at', d.created_at)
      order by d.id desc)
    from booking.invoice_dispatch_log d where d.invoice_id = p_invoice_id), '[]'::jsonb);
end $$;

-- ---------- edge: PDF ja dispatch (vain service_role) ----------
create function booking.invoice_by_token(p_token uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select booking._invoice_row(i.id) from booking.invoices i where i.public_token = p_token and i.status <> 'voided'
$$;

create function booking.invoice_set_pdf(p_invoice_id bigint, p_path text)
returns void language sql security definer set search_path = '' as $$
  update booking.invoices set pdf_path = p_path, pdf_generated_at = now() where id = p_invoice_id and invoice_no is not null
$$;

create function booking.invoice_dispatch_claim(p_limit integer default 10)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_ids bigint[]; v_res jsonb;
begin
  update booking.invoices set dispatch_status = 'queued', dispatch_error = 'sending timeout'
   where dispatch_status = 'sending' and updated_at < now() - interval '15 minutes';
  select coalesce(array_agg(id), '{}') into v_ids from (
    select id from booking.invoices where dispatch_status = 'queued' order by id
     limit greatest(least(coalesce(p_limit, 10), 20), 1) for update skip locked) q;
  update booking.invoices set dispatch_status = 'sending', dispatch_attempts = dispatch_attempts + 1, dispatch_error = null
   where id = any (v_ids);
  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'attempt', i.dispatch_attempts, 'invoice', booking.invoice_normalized(i.id)) order by i.id), '[]'::jsonb)
    into v_res from booking.invoices i where i.id = any (v_ids);
  return v_res;
end $$;

create function booking.invoice_dispatch_mark(p_id bigint, p_status text, p_error text default null, p_provider_ref text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare i booking.invoices; v_status text := p_status;
begin
  if v_status not in ('dry_run', 'sent', 'failed', 'skipped') then
    perform booking._err('invalid_param', 'dispatch status');
  end if;
  select * into i from booking.invoices where id = p_id for update;
  if not found or i.dispatch_status not in ('sending', 'queued', 'failed') then return; end if;
  update booking.invoices set dispatch_status = v_status, dispatch_error = left(p_error, 500), provider_ref = coalesce(p_provider_ref, provider_ref)
   where id = p_id;
  insert into booking.invoice_dispatch_log(invoice_id, attempt, status, provider, error, payload)
  values (p_id, greatest(i.dispatch_attempts, 1), v_status,
          case when v_status = 'dry_run' then 'dry_run' else 'provider' end,
          left(p_error, 500), booking.invoice_normalized(p_id));
end $$;

revoke all on function
  booking._fi_reference(text), booking._next_invoice_seq(text), booking._ovt_ok(text, text), booking._seller_invoice(),
  booking._invoice_customer_json(bigint), booking._invoice_recalc(bigint), booking.invoice_normalized(bigint),
  booking.invoices_lock_trg(), booking.invoice_lines_lock_trg(), booking._invoice_put_lines(bigint, jsonb, boolean),
  booking._invoice_row(bigint), booking._invoice_allocate(bigint), booking._invoice_queue_dispatch(bigint),
  booking.admin_save_invoice_customer(bigint, jsonb), booking.admin_list_invoice_customers(text),
  booking.admin_save_invoice(bigint, jsonb), booking.admin_get_invoice(bigint),
  booking.admin_list_invoices(text, text, text, date, date, integer, integer),
  booking.admin_send_invoice(bigint, boolean, boolean), booking.admin_mark_invoice_paid(bigint),
  booking.admin_void_invoice(bigint), booking.admin_credit_invoice(bigint),
  booking.admin_retry_invoice_dispatch(bigint), booking.admin_list_invoice_dispatch(bigint),
  booking.invoice_by_token(uuid), booking.invoice_set_pdf(bigint, text),
  booking.invoice_dispatch_claim(integer), booking.invoice_dispatch_mark(bigint, text, text, text)
  from public, anon, authenticated;

grant execute on function
  booking.admin_save_invoice_customer(bigint, jsonb), booking.admin_list_invoice_customers(text),
  booking.admin_save_invoice(bigint, jsonb), booking.admin_get_invoice(bigint),
  booking.admin_list_invoices(text, text, text, date, date, integer, integer),
  booking.admin_send_invoice(bigint, boolean, boolean), booking.admin_mark_invoice_paid(bigint),
  booking.admin_void_invoice(bigint), booking.admin_credit_invoice(bigint),
  booking.admin_retry_invoice_dispatch(bigint), booking.admin_list_invoice_dispatch(bigint)
  to authenticated, service_role;

grant execute on function
  booking.invoice_by_token(uuid), booking.invoice_set_pdf(bigint, text),
  booking.invoice_dispatch_claim(integer), booking.invoice_dispatch_mark(bigint, text, text, text),
  booking.invoice_normalized(bigint)
  to service_role;
