-- booking_259 rollback. Run transactionally, DEV before production.
-- Stop newsletter dispatch/sender first; back up newsletter drafts/history before running.
-- Removes feature draft/log snapshots (back up first), NEVER permanent opt-out history,
-- existing outbox rows or other mail kinds. This file is NOT an execution authorization.
set local lock_timeout='5s';
update booking.email_outbox set status='skipped',last_error='newsletter_rollback',locked_at=null
 where kind='newsletter' and status in ('pending','failed','sending');
-- Permanent capture infrastructure MUST keep running throughout feature rollback.
-- Retain OWNED BY NONE newsletter_campaign_id_seq + newsletter_log_id_seq without
-- reset/restart/setval: retained outbox keys MUST never alias a later campaign/log.
-- Never drop newsletter_capture_general_optout or _newsletter_capture_general_optout.
drop function if exists booking.admin_newsletter_dispatch(bigint,integer,boolean,uuid);
drop function if exists booking.admin_newsletter_save(bigint,jsonb,integer);
drop function if exists booking.admin_newsletters_list();
drop function if exists booking.svc_newsletter_save(bigint,jsonb,integer);
drop function if exists booking.email_newsletter_payload(bigint);
drop function if exists booking._newsletter_save(bigint,jsonb,integer);
drop function if exists booking._newsletter_recipients(text,text);
drop function if exists booking._newsletter_validate(jsonb);
drop index if exists booking.newsletter_outbox_log_idx;
drop index if exists booking.newsletter_outbox_address_uq;
drop table if exists booking.newsletter_logs;
drop table if exists booking.newsletters;
-- Keep 'newsletter' as an allowed kind while retained outbox history references it.
-- No existing constraint/claim function/permissions/transport settings are replaced.
notify pgrst,'reload schema';

-- Intentionally retain capture trigger/helper, fingerprint/address-blocked helpers,
-- customer opt-out index, newsletter_suppressions + newsletter_optout_tokens and
-- public_newsletter_unsubscribe(uuid). Old links must still opt out after rollback;
-- retain newsletter-unsubscribe.html/.js, texts/fallbacks, sb/ui/i18n transitive modules,
-- CSS and existing public config (exact lifecycle boundary: docs/newsletters-259.md).
-- Koodari compatibility confirmation is planning only, not permission to run this rollback.
-- No re-subscription or table grants are added. Do not delete suppression history.
