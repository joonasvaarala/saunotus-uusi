-- booking_259 rollback. Run transactionally, DEV before production.
-- Stop newsletter dispatch/sender first; back up newsletter drafts/history before running.
-- This removes newsletter drafts and history; never removes existing outbox rows or other mail kinds.
set local lock_timeout='5s';
update booking.email_outbox set status='skipped',last_error='newsletter_rollback',locked_at=null
 where kind='newsletter' and status in ('pending','failed','sending');
drop function if exists booking.admin_newsletter_dispatch(bigint,integer,boolean,uuid);
drop function if exists booking.admin_newsletter_save(bigint,jsonb,integer);
drop function if exists booking.admin_newsletters_list();
drop function if exists booking.svc_newsletter_save(bigint,jsonb,integer);
drop function if exists booking.email_newsletter_payload(bigint);
drop function if exists booking._newsletter_save(bigint,jsonb,integer);
drop function if exists booking._newsletter_recipients(text,text);
drop function if exists booking._newsletter_validate(jsonb);
drop index if exists booking.newsletter_outbox_log_idx;
drop table if exists booking.newsletter_logs;
drop table if exists booking.newsletters;
-- Keep 'newsletter' as an allowed kind while retained outbox history references it.
-- No existing constraint/claim function/permissions/transport settings are replaced.
notify pgrst,'reload schema';
