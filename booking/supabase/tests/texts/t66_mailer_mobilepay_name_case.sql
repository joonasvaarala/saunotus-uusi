do $t$ declare m text; begin
 m := 'from=' || (select settings ->> 'from' from booking.integration_config where key = 'resend')
  || ' reply_to=' || (select settings ->> 'reply_to' from booking.integration_config where key = 'resend')
  || ' mode=' || (select mode from booking.integration_config where key = 'resend')
  || ' resend_other_same=' || ((select settings - 'from' from booking.integration_config where key = 'resend') = (select settings - 'from' from pre66 where key = 'resend'))
  || ' mp_mode=' || (select mode from booking.integration_config where key = 'mobilepay')
  || ' mp_cfg_same=' || ((select settings from booking.integration_config where key = 'mobilepay') = (select settings from pre66 where key = 'mobilepay'))
  || ' fn_old_left=' || (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'booking' and p.proname = 'mobilepay_payment_prepare' and p.prosrc like '%Sipoonjoen perinnesauna%')
  || ' fn_new=' || (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'booking' and p.proname = 'mobilepay_payment_prepare' and p.prosrc like '%Sipoonjoen Perinnesauna – tilaus %')
  || ' fn_only_name_diff=' || ((select replace(p.prosrc, 'Sipoonjoen Perinnesauna', 'Sipoonjoen perinnesauna') from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'booking' and p.proname = 'mobilepay_payment_prepare') = (select src from pre66f))
  || ' anon_exec=' || has_function_privilege('anon', 'booking.mobilepay_payment_prepare(uuid,uuid,integer)', 'execute')
  || ' svc_exec=' || has_function_privilege('service_role', 'booking.mobilepay_payment_prepare(uuid,uuid,integer)', 'execute')
  || ' anon_exec_pre=' || (select anon_exec from pre66f);
 raise exception 'RESULT %', m; end $t$;
