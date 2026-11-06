-- LOCAL EMPTY DATABASE only, after local-fixture + migration + rollback-only t259 suite.
insert into booking.email_outbox(kind,dedupe_key,status,payload) values
 ('newsletter','t259-rollback-newsletter','pending','{"customer_id":1,"newsletter_log_id":1}'),
 ('event_message','t259-rollback-existing','pending','{}');
