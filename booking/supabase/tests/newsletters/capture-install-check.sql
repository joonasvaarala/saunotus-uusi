-- DISPOSABLE LOCAL DATABASE ONLY. No schema installation and no hosted use.
do $$begin
 if not exists(select 1 from booking.newsletter_suppressions where address_fingerprint=booking._newsletter_fingerprint('n259-backfill@example.test'))then raise exception 'Existing explicit opt-out not backfilled';end if;
 if exists(select 1 from booking.newsletter_suppressions where address_fingerprint=booking._newsletter_fingerprint('n259-never-backfill@example.test'))then raise exception 'Never-consented profile backfilled as opt-out';end if;
 if exists(select 1 from newsletter_shared_contract s join pg_proc p using(oid)where pg_get_functiondef(p.oid) is distinct from s.definition or p.proacl::text is distinct from s.acl)then raise exception 'Shared RPC definition/grants changed';end if;
 if has_function_privilege('anon','booking._newsletter_capture_general_optout()','execute')or has_function_privilege('authenticated','booking._newsletter_fingerprint(text)','execute')then raise exception 'Permanent helpers exposed';end if;
 if has_sequence_privilege('anon','booking.newsletter_log_id_seq','usage')
 or has_sequence_privilege('authenticated','booking.newsletter_campaign_id_seq','usage')
 or has_sequence_privilege('service_role','booking.newsletter_log_id_seq','update')then raise exception 'Permanent identity sequences exposed';end if;
end$$;
