-- booking_113_invoice_price_basis (19.10.2026)
-- Riville hintaperuste: veroton tai verollinen á-hinta. Verollisessa tapauksessa
-- rivin verollinen summa on täsmälleen round(määrä × syötetty verollinen hinta, 2).
-- Vanhoja rivejä ei lasketa uudelleen (price_basis oletus net, unit_price_gross null).
-- Rollback: rollbacks/20261019150000_booking_113_ROLLBACK.sql
-- Ei tuotantoajoa.

set local lock_timeout = '5s';

alter table booking.invoice_lines
  add column price_basis text not null default 'net',
  add column unit_price_gross numeric(12,4);

alter table booking.invoice_lines
  add constraint invoice_lines_price_basis_chk check (price_basis in ('net', 'gross'));

comment on column booking.invoice_lines.price_basis is
  'Mistä yksikköhinnasta rivin sentit on laskettu. net: vanha kaava. gross: verollinen rivisumma on round(määrä × verollinen á-hinta, 2). Vanhoja rivejä ei lasketa uudelleen.';
comment on column booking.invoice_lines.unit_price_gross is
  'Verollinen á-hinta. Gross-perusteella käyttäjän syöttämä. Net-perusteella johdettu round(veroton á-hinta × (100 + kanta) / 100, 4). Vanhoilla riveillä null.';

create or replace function booking._invoice_put_lines(p_id bigint, p_lines jsonb, p_allow_inactive boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
declare
  l jsonb; n int := 0;
  v_qty numeric; v_rate numeric; v_desc text; v_unit text; v_basis text;
  v_price_net numeric; v_price_gross numeric;
  v_net numeric; v_vat numeric; v_gross numeric;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 1 or jsonb_array_length(p_lines) > 100 then
    perform booking._err('invalid_lines', 'Laskulla pitää olla 1–100 riviä');
  end if;
  delete from booking.invoice_lines where invoice_id = p_id;
  for l in select value from jsonb_array_elements(p_lines) loop
    n := n + 1;
    v_desc := btrim(coalesce(l ->> 'description', ''));
    v_unit := coalesce(nullif(btrim(coalesce(l ->> 'unit', '')), ''), 'kpl');
    v_basis := lower(btrim(coalesce(l ->> 'price_basis', '')));
    if v_basis = '' then v_basis := 'net'; end if;
    v_qty := (l ->> 'quantity')::numeric;
    v_rate := (l ->> 'vat_rate')::numeric;
    if v_basis not in ('net', 'gross') then perform booking._err('invalid_lines', 'Tarkista hintaperuste'); end if;
    if char_length(v_desc) < 1 or char_length(v_desc) > 300 then perform booking._err('invalid_lines', 'Tarkista rivin kuvaus'); end if;
    if v_qty is null or v_qty = 0 or v_qty <> round(v_qty, 3) then perform booking._err('invalid_lines', 'Tarkista määrä'); end if;
    if v_rate is null or not exists (select 1 from booking.vat_rates r where r.rate = v_rate and (p_allow_inactive or r.active)) then
      perform booking._err('invalid_vat', 'ALV-kanta ei ole käytössä');
    end if;
    if v_basis = 'gross' then
      v_price_gross := (l ->> 'unit_price_gross')::numeric;
      if v_price_gross is null or v_price_gross <> round(v_price_gross, 4) then perform booking._err('invalid_lines', 'Tarkista yksikköhinta'); end if;
      v_gross := round(v_qty * v_price_gross, 2);
      v_vat := round(v_gross * v_rate / (100 + v_rate), 2);
      v_net := v_gross - v_vat;
      v_price_net := round(v_net / v_qty, 4);
    else
      v_price_net := (l ->> 'unit_price_net')::numeric;
      if v_price_net is null or v_price_net <> round(v_price_net, 4) then perform booking._err('invalid_lines', 'Tarkista yksikköhinta'); end if;
      v_net := round(v_qty * v_price_net, 2);
      v_vat := round(v_net * v_rate / 100, 2);
      v_gross := v_net + v_vat;
      v_price_gross := round(v_price_net * (100 + v_rate) / 100, 4);
    end if;
    insert into booking.invoice_lines(invoice_id, line_no, description, quantity, unit, unit_price_net, unit_price_gross, price_basis, vat_rate, line_net, line_vat, line_gross)
    values (p_id, n, v_desc, v_qty, v_unit, v_price_net, v_price_gross, v_basis, v_rate, v_net, v_vat, v_gross);
  end loop;
  perform booking._invoice_recalc(p_id);
end $$;

create or replace function booking.invoice_normalized(p_id bigint)
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
        'unit_price_net', l.unit_price_net, 'unit_price_gross', l.unit_price_gross,
        'price_basis', l.price_basis, 'vat_rate', l.vat_rate) order by l.line_no)
      from booking.invoice_lines l where l.invoice_id = i.id), '[]'::jsonb),
    'notes', v_notes);
end $$;

create or replace function booking.admin_credit_invoice(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
  insert into booking.invoices(kind, credit_of_id, customer_id, order_id, invoice_date, due_date, buyer_reference, notes, locale, seller_snapshot, customer_snapshot, customer_snapshot_locked, created_by)
  values ('credit', i.id, i.customer_id, i.order_id, v_date, v_date + v_days, i.buyer_reference,
          left(nullif(concat_ws(E'\n', 'Hyvitys laskulle ' || coalesce(i.invoice_no, '#' || i.id::text), i.notes), ''), 2000),
          i.locale, booking._seller_invoice(), i.customer_snapshot, i.customer_snapshot_locked, auth.uid())
  returning id into v_new;
  insert into booking.invoice_lines(invoice_id, line_no, description, quantity, unit, unit_price_net, unit_price_gross, price_basis, vat_rate, line_net, line_vat, line_gross)
  select v_new, l.line_no, l.description, l.quantity, l.unit, -l.unit_price_net, -l.unit_price_gross, l.price_basis, l.vat_rate, -l.line_net, -l.line_vat, -l.line_gross
    from booking.invoice_lines l where l.invoice_id = i.id order by l.line_no;
  perform booking._invoice_recalc(v_new);
  return booking._invoice_row(v_new);
end $$;
