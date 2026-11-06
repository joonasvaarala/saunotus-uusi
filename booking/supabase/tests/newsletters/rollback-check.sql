-- DISPOSABLE LOCAL DATABASE ONLY; reads/writes fixed synthetic fixture identifiers.
do $$begin
 if to_regclass('booking.newsletters') is not null or to_regclass('booking.newsletter_logs') is not null then raise exception 'Newsletter tables remain';end if;
 if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='booking' and p.proname in ('admin_newsletter_dispatch','svc_newsletter_save','_newsletter_save','_newsletter_recipients','email_newsletter_payload')) then raise exception 'Newsletter RPCs remain';end if;
 if not exists(select 1 from booking.email_outbox where dedupe_key='t259-rollback-newsletter' and status='skipped') then raise exception 'Newsletter queue not stopped';end if;
 if not exists(select 1 from booking.email_outbox where dedupe_key='t259-rollback-existing' and status='pending') then raise exception 'Existing mail changed';end if;
end$$;
do $$begin
 if to_regclass('booking.newsletter_optout_tokens') is null or to_regclass('booking.newsletter_suppressions') is null then raise exception 'Rollback must preserve opt-out history';end if;
 perform booking.public_newsletter_unsubscribe('00000000-0000-4000-8000-000000000259');
 if not exists(select 1 from booking.newsletter_suppressions where address_fingerprint=repeat('a',64))then raise exception 'Old opt-out token broken after rollback';end if;
end$$;

do $$begin
 if to_regprocedure('booking._newsletter_fingerprint(text)') is null
 or to_regprocedure('booking._newsletter_capture_general_optout()') is null
 or not exists(select 1 from pg_trigger where tgname='newsletter_capture_general_optout' and tgrelid='booking.customers'::regclass and tgenabled in('O','A'))then
 raise exception 'Permanent capture infrastructure lost during rollback';end if;
end$$;
