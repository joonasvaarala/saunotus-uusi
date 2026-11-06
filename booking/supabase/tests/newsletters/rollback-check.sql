do $$begin
 if to_regclass('booking.newsletters') is not null or to_regclass('booking.newsletter_logs') is not null then raise exception 'Newsletter tables remain';end if;
 if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='booking' and p.proname in ('admin_newsletter_dispatch','svc_newsletter_save','_newsletter_save','_newsletter_recipients','email_newsletter_payload')) then raise exception 'Newsletter RPCs remain';end if;
 if not exists(select 1 from booking.email_outbox where dedupe_key='t259-rollback-newsletter' and status='skipped') then raise exception 'Newsletter queue not stopped';end if;
 if not exists(select 1 from booking.email_outbox where dedupe_key='t259-rollback-existing' and status='pending') then raise exception 'Existing mail changed';end if;
end$$;
