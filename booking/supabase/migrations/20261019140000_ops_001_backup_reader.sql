-- ops_001_backup_reader
-- Lukurooli ulkoiselle pg_dumpille (GitHub Actions → Google Drive).
-- Ei salasanaa: Joonas asettaa sen SQL-editorissa migraation jälkeen
--   alter role backup_reader password '...';
-- Salasanaa ei kirjoiteta repoon eikä tähän tiedostoon.
--
-- CREATE ROLE ja ALTER ROLE eivät toimi eksplisiittisen transaktion sisällä (SQLSTATE 25001).
-- psql -1 ja Supabasen migraatioajuri aloittavat transaktion. Ensimmäinen COMMIT sulkee sen.
-- Ilman ulkoista transaktiota COMMIT vain varoittaa ja jatkaa.
--
-- BYPASSRLS + pg_read_all_data on Supabasen ohje roolille, jolla pg_dump lukee myös RLS-taulut
-- ja auth/storage-skeemat:
-- https://supabase.com/docs/guides/troubleshooting/pg_dump-fails-with-query-would-be-affected-by-row-level-security-policy-1d5783
-- Jos BYPASSRLS epäonnistuu, dumppi on virheellinen. Älä jatka ilman sitä.
-- Vaihtoehto: SUPABASE_BACKUP_DB_URL postgres-roolin session poolerilla (docs/backup.md).
--
-- Numerointi on ops_001, ei booking_113: toinen muutos voi varata booking_113:n.
-- Aikaleima 20261019140000 on tuotannon booking_112 (20261019102204) jälkeen.
-- Rollback: rollbacks/20261019140000_ops_001_ROLLBACK.sql
-- Ei tuotantoajoa tässä commitissa.

commit;

create role backup_reader
  login
  nosuperuser
  nocreatedb
  nocreaterole
  inherit
  noreplication
  bypassrls
  connection limit 8;

alter role backup_reader set default_transaction_read_only = on;
alter role backup_reader set statement_timeout = '30min';
alter role backup_reader set lock_timeout = '60s';
alter role backup_reader set idle_in_transaction_session_timeout = '5min';

comment on role backup_reader is
  'Vain luku -rooli ulkoiseen pg_dumpiin. BYPASSRLS ja pg_read_all_data. Salasana asetetaan migraation ulkopuolella.';

-- pg_read_all_data (PostgreSQL 14+): implisiittinen SELECT tauluihin, näkymiin ja sekvensseihin
-- sekä USAGE skeemoihin, myös myöhemmin luotuihin. Ei ohita RLS:ää (siksi BYPASSRLS) eikä
-- kata large objecteja.
grant pg_read_all_data to backup_reader;

-- Eksplisiittiset oikeudet ja oletusoikeudet niissä skeemoissa, joihin ajaja pääsee.
-- Oletusoikeudet koskevat vain tämän roolin (tuotannossa postgres) myöhemmin luomia objekteja.
-- Muiden roolien luomat objektit kattaa pg_read_all_data.
do $grants$
declare
  s text;
  schemas text[] := array[
    'public', 'kb', 'booking', 'auth', 'storage', 'supabase_migrations', 'cron',
    'extensions', 'vault', 'graphql', 'graphql_public', 'realtime', 'net', 'supabase_functions'
  ];
begin
  foreach s in array schemas loop
    if not exists (select 1 from pg_namespace where nspname = s) then
      raise notice 'ops_001: skeema % ei ole olemassa, ohitetaan', s;
      continue;
    end if;
    begin
      execute format('grant usage on schema %I to backup_reader', s);
    exception when insufficient_privilege then
      raise notice 'ops_001: usage % ohitettu: %', s, sqlerrm;
    end;
    begin
      execute format('grant select on all tables in schema %I to backup_reader', s);
    exception when insufficient_privilege then
      raise notice 'ops_001: select tables % ohitettu: %', s, sqlerrm;
    end;
    begin
      execute format('grant select on all sequences in schema %I to backup_reader', s);
    exception when insufficient_privilege then
      raise notice 'ops_001: select sequences % ohitettu: %', s, sqlerrm;
    end;
    begin
      execute format('alter default privileges in schema %I grant select on tables to backup_reader', s);
      execute format('alter default privileges in schema %I grant select on sequences to backup_reader', s);
    exception when insufficient_privilege then
      raise notice 'ops_001: default privileges % ohitettu: %', s, sqlerrm;
    end;
  end loop;
end
$grants$;

-- API-roolit eivät saa vaihtua backup_readeriksi.
do $rev$
declare r text;
begin
  foreach r in array array['anon', 'authenticated', 'authenticator', 'service_role'] loop
    if exists (
      select 1
        from pg_auth_members m
        join pg_roles granted on granted.oid = m.roleid and granted.rolname = 'backup_reader'
        join pg_roles member on member.oid = m.member and member.rolname = r
    ) then
      execute format('revoke %I from %I', 'backup_reader', r);
    end if;
  end loop;
end
$rev$;

do $check$
begin
  if not exists (
    select 1 from pg_roles
     where rolname = 'backup_reader' and rolcanlogin and rolbypassrls and not rolsuper
  ) then
    raise exception 'backup_reader ei ole LOGIN + BYPASSRLS ilman superuseria';
  end if;
  if not exists (
    select 1
      from pg_auth_members m
      join pg_roles granted on granted.oid = m.roleid and granted.rolname = 'pg_read_all_data'
      join pg_roles member on member.oid = m.member and member.rolname = 'backup_reader'
  ) then
    raise exception 'backup_reader ei ole pg_read_all_data-roolin jäsen';
  end if;
end
$check$;
