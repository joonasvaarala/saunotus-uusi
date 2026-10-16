-- 3. Tarkistukset migraatioiden jälkeen (vain luku)
select 'taulut ilman RLS:ää (pitää olla 0)' as check, count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'booking' and c.relkind = 'r' and not c.relrowsecurity;
select 'SECURITY DEFINER ilman search_path (pitää olla 0)', count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'booking' and p.prosecdef and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%');
select 'anonin suoritettavat funktiot', string_agg(p.proname, ', ' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'booking' and has_function_privilege('anon', p.oid, 'execute');
select 'anonin taulu-oikeudet (pitää olla tyhjä)', string_agg(table_name || ':' || privilege_type, ', ') from information_schema.role_table_grants
 where grantee = 'anon' and table_schema = 'booking';
select 'tuotteita verkkovarattavissa', count(*) from booking.product_config where bookable;
select 'sääntöjä', count(*) from booking.schedule_rules where active;
select 'pg_cron-ajastus', count(*) from cron.job where jobname = 'booking_expire_holds';   -- 0 jos pg_cron ei käytössä (ok)
