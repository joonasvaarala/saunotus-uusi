-- booking_77_procountor_exports (18.10.2026)
-- Procountor-lähetysten tila: päivän myyntikirjaus ja laskun välitys.
-- Ei salaisuuksia. Tunnukset ovat vain Edge-salaisuuksina.
-- RLS: select vain settings.edit (admin ja ylläpitäjä/manager). Ei anon-oikeuksia.
-- Kirjoitus vain service_role -funktioilla (booking_78).
-- Rollback: rollbacks/20261018230000_booking_77_ROLLBACK.sql

create table booking.accounting_exports (
  id                     bigint generated always as identity primary key,
  kind                   text not null check (kind in ('daily_sales', 'sales_invoice')),
  dedupe_key             text not null unique,
  business_date          date,
  environment            text not null default 'pts' check (environment in ('pts', 'prod')),
  status                 text not null check (status in ('pending', 'processing', 'dry_run', 'sent', 'failed', 'skipped', 'needs_review')),
  report                 jsonb,
  request                jsonb,
  response               jsonb,
  procountor_invoice_id  bigint,
  procountor_ledger_id   bigint,
  attempts               integer not null default 0 check (attempts >= 0),
  last_error             text,
  locked_at              timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  sent_at                timestamptz,
  check (kind <> 'daily_sales' or business_date is not null),
  check (kind <> 'sales_invoice' or dedupe_key like 'invoice:%')
);
create unique index accounting_exports_daily_uq on booking.accounting_exports (business_date) where kind = 'daily_sales';
create index accounting_exports_status_idx on booking.accounting_exports (status, business_date);
comment on table booking.accounting_exports is 'Procountor-lähetysten tila (päivän myynti ja laskun välitys). Ei salaisuuksia eikä tunnuksia.';

create trigger accounting_exports_updated before update on booking.accounting_exports
  for each row execute function booking.set_updated_at();

alter table booking.accounting_exports enable row level security;
revoke all on booking.accounting_exports from public, anon, authenticated;
grant all on booking.accounting_exports to service_role;
grant select on booking.accounting_exports to authenticated;
create policy procountor_admin_read on booking.accounting_exports
  for select to authenticated
  using ((select booking.has_permission('settings.edit')));

do $$ begin
  perform booking._add_audit('booking.accounting_exports');
end $$;

update booking.integration_config
   set settings = settings || jsonb_build_object('daily_enabled', false, 'api_prefix', '/supported/api'),
       notes = 'Salaisuudet vain Edge: PROCOUNTOR_CLIENT_ID, PROCOUNTOR_CLIENT_SECRET, PROCOUNTOR_API_KEY, PROCOUNTOR_REDIRECT_URI. Tilit settings.accounts. Ks. docs/procountor-integraatio.md.',
       updated_at = now()
 where key = 'procountor';
