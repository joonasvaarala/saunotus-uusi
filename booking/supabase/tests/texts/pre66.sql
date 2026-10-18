create temp table pre66 as select key, mode, settings from booking.integration_config;
create temp table pre66f as select p.prosrc src, has_function_privilege('anon', p.oid, 'execute') anon_exec from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'booking' and p.proname = 'mobilepay_payment_prepare';
