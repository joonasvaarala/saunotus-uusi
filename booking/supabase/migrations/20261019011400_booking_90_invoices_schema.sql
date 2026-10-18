-- booking_90_invoices_schema (18.10.2026)
-- Laskutus: asiakkaat, laskut, rivit, aukoton numerosarja, lähetysloki.
-- Maksutila invoiced = vahvistettu tilaus, jota ei ole maksettu (odottaa laskua).
-- Oikeus invoices.manage: pääkäyttäjä (admin) ja ylläpitäjä (manager). Ei anon-oikeuksia.
-- Rollback: rollbacks/20261019011400_booking_90_ROLLBACK.sql
-- Ei tuotantoajoa tästä tiedostosta. Ei salaisuuksia.

set local lock_timeout = '5s';

alter table booking.orders drop constraint if exists orders_payment_status_check;
alter table booking.orders add constraint orders_payment_status_check
  check (payment_status in ('unpaid','pending','paid','partially_paid','refunded','partially_refunded','failed','invoiced'));
comment on column booking.orders.payment_status is
  'unpaid|pending|paid|partially_paid|refunded|partially_refunded|failed|invoiced. invoiced = yritysverkkolasku: varaus vahvistettu, ei maksettu, ei kuittia.';

insert into booking.role_permissions(role_code, permission) values
  ('admin', 'invoices.manage'),
  ('manager', 'invoices.manage')
on conflict do nothing;

insert into booking.settings(key, value, description, is_public) values
  ('invoice_due_days', '14'::jsonb, 'Laskun oletuseräpäivä päivinä laskun päivästä', false),
  ('invoice_bank', '{"iban":"","bic":"","name":""}'::jsonb, 'Laskun pankkiyhteys (IBAN, BIC, pankin nimi). Julkinen laskulla, ei salasana. Tyhjä kunnes Joonas täyttää.', false),
  ('invoice_dispatch_mode', to_jsonb('dry_run'::text), 'invoice-dispatch: dry_run ei kutsu Procountoria. live jää Procountor-agentin kytkettäväksi.', false)
on conflict (key) do nothing;

create table booking.invoice_customers (
  id                 bigint generated always as identity primary key,
  customer_id        bigint references booking.customers(id) on delete set null,
  company_name       text not null check (char_length(btrim(company_name)) between 2 and 200),
  contact_name       text check (contact_name is null or char_length(contact_name) between 2 and 120),
  business_id        text check (business_id is null or booking._business_id_ok(business_id)),
  vat_id             text check (vat_id is null or vat_id ~ '^[A-Z]{2}[A-Z0-9]{8,14}$'),
  email              text check (email is null or booking._valid_email(email)),
  phone              text,
  street             text,
  zip                text,
  city               text,
  country            text not null default 'FI' check (country ~ '^[A-Z]{2}$'),
  einvoice_address   text,
  einvoice_operator  text,
  buyer_reference    text check (buyer_reference is null or char_length(buyer_reference) <= 100),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index invoice_customers_business_idx on booking.invoice_customers(business_id) where business_id is not null;
create index invoice_customers_email_idx on booking.invoice_customers(lower(email)) where email is not null;
create trigger invoice_customers_updated before update on booking.invoice_customers
  for each row execute function booking.set_updated_at();
comment on table booking.invoice_customers is
  'Laskutusasiakkaat (uusi tai tallennettu). Voi viitata booking.customers-riviin. Kirjoitus vain SECURITY DEFINER -RPC:llä.';

create table booking.invoice_counters (
  series   text primary key check (series ~ '^[A-Z]$'),
  last_seq integer not null default 0 check (last_seq >= 0)
);
insert into booking.invoice_counters(series, last_seq) values ('L', 0);
comment on table booking.invoice_counters is
  'Aukoton laskunumerosarja. Kasvaa vain samassa transaktiossa kun lasku lähtee luonnoksesta. Peruutus peruu numeron.';

create table booking.invoices (
  id                 bigint generated always as identity primary key,
  invoice_no         text unique,
  series             text not null default 'L' references booking.invoice_counters(series),
  seq                integer check (seq is null or seq > 0),
  kind               text not null default 'debit' check (kind in ('debit','credit')),
  status             text not null default 'draft' check (status in ('draft','sent','paid','overdue','credited','voided')),
  customer_id        bigint not null references booking.invoice_customers(id),
  order_id           bigint references booking.orders(id) on delete restrict,
  credit_of_id       bigint references booking.invoices(id) on delete restrict,
  invoice_date       date not null default (now() at time zone 'Europe/Helsinki')::date,
  due_date           date not null,
  reference_no       text,
  buyer_reference    text check (buyer_reference is null or char_length(buyer_reference) <= 100),
  currency           text not null default 'EUR' check (currency = 'EUR'),
  notes              text check (notes is null or char_length(notes) <= 2000),
  locale             text not null default 'fi' check (locale in ('fi','en')),
  seller_snapshot    jsonb not null,
  customer_snapshot  jsonb not null,
  total_net          numeric(12,2) not null default 0,
  total_vat          numeric(12,2) not null default 0,
  total_gross        numeric(12,2) not null default 0,
  vat_breakdown      jsonb not null default '[]'::jsonb,
  public_token       uuid not null default gen_random_uuid() unique,
  dispatch_status    text not null default 'none' check (dispatch_status in ('none','queued','sending','dry_run','sent','failed','skipped')),
  dispatch_attempts  integer not null default 0,
  dispatch_error     text,
  provider_ref       text,
  locked_at          timestamptz,
  sent_at            timestamptz,
  paid_at            timestamptz,
  voided_at          timestamptz,
  pdf_path           text,
  pdf_generated_at   timestamptz,
  created_by         uuid,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (series, seq),
  check (due_date >= invoice_date),
  check ((kind = 'credit') = (credit_of_id is not null)),
  check ((invoice_no is null) = (seq is null)),
  check (status <> 'draft' or invoice_no is null)
);
create unique index invoices_one_debit_order on booking.invoices(order_id)
  where order_id is not null and kind = 'debit' and status <> 'voided';
create index invoices_status_idx on booking.invoices(status, invoice_date desc);
create index invoices_customer_idx on booking.invoices(customer_id);
create index invoices_dispatch_idx on booking.invoices(dispatch_status, id)
  where dispatch_status in ('queued','failed');
create trigger invoices_updated before update on booking.invoices
  for each row execute function booking.set_updated_at();
comment on table booking.invoices is
  'Myyntilasku. Luonnos on muokattava. Lähetys lukitsee rivit ja antaa aukottoman numeron. Korjaus vain hyvityslaskulla.';

create table booking.invoice_lines (
  id              bigint generated always as identity primary key,
  invoice_id      bigint not null references booking.invoices(id) on delete cascade,
  line_no         integer not null check (line_no > 0),
  description     text not null check (char_length(btrim(description)) between 1 and 300),
  quantity        numeric(12,3) not null check (quantity <> 0),
  unit            text not null default 'kpl' check (char_length(unit) between 1 and 20),
  unit_price_net  numeric(12,4) not null,
  vat_rate        numeric(5,2) not null,
  line_net        numeric(12,2) not null,
  line_vat        numeric(12,2) not null,
  line_gross      numeric(12,2) not null,
  unique (invoice_id, line_no)
);
create index invoice_lines_invoice_idx on booking.invoice_lines(invoice_id);

create table booking.invoice_dispatch_log (
  id          bigint generated always as identity primary key,
  invoice_id  bigint not null references booking.invoices(id) on delete cascade,
  attempt     integer not null check (attempt > 0),
  status      text not null check (status in ('queued','dry_run','sent','failed','skipped')),
  provider    text not null default 'dry_run',
  error       text,
  payload     jsonb not null,
  created_at  timestamptz not null default now()
);
create index invoice_dispatch_log_invoice_idx on booking.invoice_dispatch_log(invoice_id, created_at desc);
comment on table booking.invoice_dispatch_log is
  'Verkkolaskun lähetysloki. payload on normalisoitu lasku-JSON ilman salaisuuksia.';

insert into storage.buckets(id, name, public) values ('invoices', 'invoices', false) on conflict (id) do nothing;

alter table booking.invoice_customers enable row level security;
alter table booking.invoice_counters enable row level security;
alter table booking.invoices enable row level security;
alter table booking.invoice_lines enable row level security;
alter table booking.invoice_dispatch_log enable row level security;

revoke all on booking.invoice_customers, booking.invoice_counters, booking.invoices, booking.invoice_lines, booking.invoice_dispatch_log
  from public, anon, authenticated;
grant all on booking.invoice_customers, booking.invoice_counters, booking.invoices, booking.invoice_lines, booking.invoice_dispatch_log
  to service_role;
grant select on booking.invoice_customers, booking.invoices, booking.invoice_lines, booking.invoice_dispatch_log
  to authenticated;

create policy invoices_manage_read on booking.invoice_customers for select to authenticated
  using ((select booking.has_permission('invoices.manage')));
create policy invoices_manage_read on booking.invoices for select to authenticated
  using ((select booking.has_permission('invoices.manage')));
create policy invoices_manage_read on booking.invoice_lines for select to authenticated
  using ((select booking.has_permission('invoices.manage')));
create policy invoices_manage_read on booking.invoice_dispatch_log for select to authenticated
  using ((select booking.has_permission('invoices.manage')));

select booking._add_audit('booking.invoice_customers'::regclass);
select booking._add_audit('booking.invoices'::regclass);
select booking._add_audit('booking.invoice_lines'::regclass);
select booking._add_audit('booking.invoice_dispatch_log'::regclass);
