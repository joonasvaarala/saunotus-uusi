-- booking_259 rollback. Run transactionally, DEV before production.
-- Stop newsletter dispatch/sender first; back up newsletter drafts/history before running.
-- This removes newsletter drafts and history; never removes existing outbox rows or other mail kinds.
set local lock_timeout='5s';
update booking.email_outbox set status='skipped',last_error='newsletter_rollback',locked_at=null
 where kind='newsletter' and status in ('pending','failed','sending');
-- If the separately approved general-opt-out proposal was installed, remove only that newsletter hook.
drop trigger if exists newsletter_capture_general_optout on booking.customers;
drop function if exists booking._newsletter_capture_general_optout();
drop function if exists booking.admin_newsletter_dispatch(bigint,integer,boolean,uuid);
drop function if exists booking.admin_newsletter_save(bigint,jsonb,integer);
drop function if exists booking.admin_newsletters_list();
drop function if exists booking.svc_newsletter_save(bigint,jsonb,integer);
drop function if exists booking.email_newsletter_payload(bigint);
drop function if exists booking._newsletter_save(bigint,jsonb,integer);
drop function if exists booking._newsletter_recipients(text,text);
drop function if exists booking._newsletter_validate(jsonb);
drop function if exists booking._newsletter_address_blocked(text,text);
drop function if exists booking._newsletter_fingerprint(text);
drop index if exists booking.newsletter_outbox_log_idx;
drop index if exists booking.newsletter_outbox_address_uq;
drop index if exists booking.newsletter_customers_optout_email_idx;
drop table if exists booking.newsletter_logs;
drop table if exists booking.newsletters;
-- Keep 'newsletter' as an allowed kind while retained outbox history references it.
-- No existing constraint/claim function/permissions/transport settings are replaced.
notify pgrst,'reload schema';

-- Intentionally retain newsletter_suppressions + newsletter_optout_tokens and
-- public_newsletter_unsubscribe(uuid). Old links must still opt out after rollback;
-- retain newsletter-unsubscribe.html/.js, its text fallbacks and existing public config.
-- No re-subscription or table grants are added. Do not delete suppression history.
