-- DISPOSABLE LOCAL DATABASE ONLY. After rollback + forward-only re-enable proposal.
do $$begin
 if to_regclass('booking.newsletters') is null or to_regprocedure('booking.admin_newsletter_dispatch(bigint,integer,boolean,uuid)') is null then raise exception 'Feature not re-enabled';end if;
 if not exists(select 1 from booking.newsletter_optout_tokens where token='00000000-0000-4000-8000-000000000259' and address_fingerprint=repeat('a',64))
 or not exists(select 1 from booking.newsletter_suppressions where address_fingerprint=repeat('a',64))then raise exception 'Re-enable lost shipped token/suppression';end if;
 if not exists(select 1 from booking.email_outbox where dedupe_key='t259-rollback-newsletter' and status='skipped')then raise exception 'Re-enable discarded outbox history';end if;
end$$;
