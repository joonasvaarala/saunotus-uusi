-- ops_002_backup_storage_read
-- Pelkkä SELECT storage.objects-riveihin bucketeissa receipts ja invoices.
-- Tunnistus on app_metadata.backup_role = storage_reader, ei sähköposti eikä auth.uid()-lista.
-- Käyttäjän luo Joonas dashboardissa (docs/backup.md). Tätä tiedostoa ei ajeta tuotantoon tästä commitista.
-- Ei booking.staff-riviä eikä hallintaoikeutta: muut politiikat vaativat is_staff() tai has_permission().
-- Rollback: rollbacks/20261019140100_ops_002_ROLLBACK.sql
-- Aikaleima on ops_001:n (20261019140000) jälkeen.

drop policy if exists backup_storage_reader_select on storage.objects;

create policy backup_storage_reader_select
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id in ('receipts', 'invoices')
    and coalesce((select auth.jwt() -> 'app_metadata' ->> 'backup_role'), '') = 'storage_reader'
  );

do $check$
begin
  if not exists (
    select 1
      from pg_policy p
      join pg_class c on c.oid = p.polrelid
      join pg_namespace n on n.oid = c.relnamespace
      join pg_roles r on r.oid = any (p.polroles)
     where n.nspname = 'storage'
       and c.relname = 'objects'
       and p.polname = 'backup_storage_reader_select'
       and p.polcmd = 'r'
       and r.rolname = 'authenticated'
  ) then
    raise exception 'backup_storage_reader_select ei ole authenticated-roolin SELECT-politiikka';
  end if;
end
$check$;
