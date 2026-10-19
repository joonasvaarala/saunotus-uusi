-- ROLLBACK ops_001_backup_reader.
-- Poistaa lukuroolin. Ei poista tauluja eikä dataa.

do $rev$
declare s text;
begin
  if not exists (select 1 from pg_roles where rolname = 'backup_reader') then
    raise notice 'backup_reader ei ole olemassa';
    return;
  end if;
  for s in
    select nspname from pg_namespace
     where nspname not in ('pg_catalog', 'information_schema')
       and nspname not like 'pg_toast%'
       and nspname not like 'pg_temp%'
  loop
    begin
      execute format('revoke all privileges on all tables in schema %I from backup_reader', s);
      execute format('revoke all privileges on all sequences in schema %I from backup_reader', s);
      execute format('revoke usage on schema %I from backup_reader', s);
    exception when insufficient_privilege then
      raise notice 'ops_001 rollback revoke %: %', s, sqlerrm;
    end;
    begin
      execute format('alter default privileges in schema %I revoke select on tables from backup_reader', s);
      execute format('alter default privileges in schema %I revoke select on sequences from backup_reader', s);
    exception when insufficient_privilege then
      raise notice 'ops_001 rollback default privileges %: %', s, sqlerrm;
    end;
  end loop;
end
$rev$;

do $m$
begin
  if exists (
    select 1 from pg_auth_members m
    join pg_roles g on g.oid = m.roleid and g.rolname = 'pg_read_all_data'
    join pg_roles u on u.oid = m.member and u.rolname = 'backup_reader'
  ) then
    execute 'revoke pg_read_all_data from backup_reader';
  end if;
end
$m$;

-- PG17: roolin luojalla on vain admin-oikeus, ei oikeutta pudottaa roolin omistamia objekteja.
grant backup_reader to current_user with inherit true, set false;
drop owned by backup_reader;
drop role backup_reader;
