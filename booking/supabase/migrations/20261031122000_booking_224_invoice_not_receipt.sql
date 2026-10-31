-- booking_224: lasku on myyntitosite. Maksuksi merkitseminen ei luo K-kuittia
-- eikä vie myyntiä Procountorin päiväkirjaan. Laskuraportti on kirjanpidon lähde,
-- kunnes lasku lähetetään Procountoriin myyntilaskuna.
set local lock_timeout = '5s';

alter table booking.invoices
  add column if not exists procountor_invoice_id text,
  add column if not exists procountor_export_status text;

alter table booking.invoices drop constraint if exists invoices_procountor_export_status_check;
alter table booking.invoices
  add constraint invoices_procountor_export_status_check
  check (procountor_export_status is null or procountor_export_status in ('pending', 'exported', 'failed'));

comment on column booking.invoices.procountor_invoice_id is
  'booking_224: Procountorin myyntilaskun tunniste. Tyhjä, kunnes seuraava vaihe lähettää laskun. Ei käytössä vielä.';
comment on column booking.invoices.procountor_export_status is
  'booking_224: pending, exported tai failed. Tyhjä, kun vientiä ei ole yritetty.';

create or replace function booking.admin_mark_invoice_paid(p_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i booking.invoices; n int;
begin
  perform booking._require_permission('invoices.manage');
  select * into i from booking.invoices where id = p_id for update;
  if not found then perform booking._err('not_found', 'Laskua ei löydy'); end if;
  if i.kind = 'credit' then perform booking._err('invalid_status', 'Hyvityslaskua ei merkitä maksetuksi'); end if;
  if i.status not in ('sent', 'overdue') then perform booking._err('invalid_status', 'Vain lähetetty lasku voidaan merkitä maksetuksi'); end if;
  update booking.invoices set status = 'paid', paid_at = now() where id = p_id;
  if i.order_id is not null then
    update booking.payments set status = 'paid', paid_at = now(),
           note = left(concat_ws(' | ', note, 'Lasku merkitty maksetuksi. Myynti on laskussa, ei kassakuitissa.'), 500)
     where order_id = i.order_id and method = 'invoice' and status = 'pending';
    get diagnostics n = row_count;
    perform booking._refresh_order_payment(i.order_id);
  end if;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (auth.uid(), booking._jwt_role(), 'invoices', p_id::text, 'INVOICE_MARK_PAID',
          jsonb_build_object('invoice_no', i.invoice_no, 'paid_at', now(), 'receipt', false));
  return booking._invoice_row(p_id);
end $$;

create or replace function booking.admin_report_invoices(p_from date, p_to date, p_format text default 'json')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_rows jsonb; v_credits jsonb; v_body text := ''; v_cr text := E'\r\n'; el jsonb;
  v_today date := (timezone('Europe/Helsinki', now()))::date;
begin
  perform booking._report_check(true);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    perform booking._err('invalid_param', 'Virheellinen aikaväli (enintään 366 päivää)');
  end if;
  if coalesce(p_format, 'json') not in ('json', 'csv') then perform booking._err('invalid_param', 'p_format: json|csv'); end if;
  with base as (
    select i.*,
           coalesce(i.customer_snapshot ->> 'company_name', i.customer_snapshot ->> 'name', '') as customer_name,
           case
             when i.status = 'paid' then 'paid'
             when i.status = 'credited' then 'credited'
             when i.status = 'overdue' or (i.status = 'sent' and i.due_date < v_today) then 'overdue'
             else 'open'
           end as ui_status
      from booking.invoices i
     where i.status not in ('draft', 'voided')
       and i.invoice_date between p_from and p_to
  ), shaped as (
    select b.kind, b.invoice_date, b.invoice_no,
           jsonb_build_object(
             'id', b.id,
             'invoice_no', coalesce(b.invoice_no, ''),
             'customer', b.customer_name,
             'invoice_date', b.invoice_date,
             'due_date', b.due_date,
             'net', b.total_net,
             'vat', b.total_vat,
             'gross', b.total_gross,
             'vat_breakdown', coalesce(b.vat_breakdown, '[]'::jsonb),
             'status', b.ui_status,
             'paid_at', b.paid_at,
             'kind', b.kind,
             'procountor_invoice_id', b.procountor_invoice_id,
             'procountor_export_status', b.procountor_export_status) as obj
      from base b
  )
  select coalesce((select jsonb_agg(obj order by invoice_date, invoice_no) from shaped where kind = 'debit'), '[]'::jsonb),
         coalesce((select jsonb_agg(obj order by invoice_date, invoice_no) from shaped where kind = 'credit'), '[]'::jsonb)
    into v_rows, v_credits;
  if p_format = 'json' then
    return jsonb_build_object(
      'period', jsonb_build_object('from', p_from, 'to', p_to, 'tz', 'Europe/Helsinki', 'kind', 'invoices'),
      'invoices', v_rows,
      'credits', v_credits,
      'totals', jsonb_build_object(
        'net', coalesce((select round(sum((e ->> 'net')::numeric), 2) from jsonb_array_elements(v_rows) e), 0),
        'vat', coalesce((select round(sum((e ->> 'vat')::numeric), 2) from jsonb_array_elements(v_rows) e), 0),
        'gross', coalesce((select round(sum((e ->> 'gross')::numeric), 2) from jsonb_array_elements(v_rows) e), 0),
        'credit_gross', coalesce((select round(sum((e ->> 'gross')::numeric), 2) from jsonb_array_elements(v_credits) e), 0)));
  end if;
  for el in select * from jsonb_array_elements(v_rows) loop
    v_body := v_body || concat_ws(';', 'lasku', booking._csv(el ->> 'invoice_no'), booking._csv(el ->> 'customer'),
      to_char((el ->> 'invoice_date')::date, 'DD.MM.YYYY'), to_char((el ->> 'due_date')::date, 'DD.MM.YYYY'),
      booking._csvmoney((el ->> 'net')::numeric), booking._csvmoney((el ->> 'vat')::numeric), booking._csvmoney((el ->> 'gross')::numeric),
      booking._csv(el ->> 'status'), coalesce(to_char((el ->> 'paid_at')::timestamptz at time zone 'Europe/Helsinki', 'DD.MM.YYYY'), '')) || v_cr;
  end loop;
  for el in select * from jsonb_array_elements(v_credits) loop
    v_body := v_body || concat_ws(';', 'hyvitys', booking._csv(el ->> 'invoice_no'), booking._csv(el ->> 'customer'),
      to_char((el ->> 'invoice_date')::date, 'DD.MM.YYYY'), to_char((el ->> 'due_date')::date, 'DD.MM.YYYY'),
      booking._csvmoney((el ->> 'net')::numeric), booking._csvmoney((el ->> 'vat')::numeric), booking._csvmoney((el ->> 'gross')::numeric),
      booking._csv(el ->> 'status'), '') || v_cr;
  end loop;
  return jsonb_build_object(
    'filename', format('laskut_%s_%s.csv', p_from, p_to),
    'mime', 'text/csv;charset=utf-8',
    'content', chr(65279) || 'osio;numero;asiakas;paiva;erapaiva;netto;alv;brutto;tila;maksettu' || v_cr || v_body);
end $$;

revoke all on function booking.admin_report_invoices(date, date, text) from public, anon, authenticated;
grant execute on function booking.admin_report_invoices(date, date, text) to authenticated, service_role;
comment on function booking.admin_report_invoices(date, date, text) is
  'booking_224: laskut laskun päivän mukaan. Ei kassamyyntiä. Vain reports.view.';
