-- DISPOSABLE LOCAL DATABASE ONLY. Fixed fixtures + temp contract snapshot before proposal.
create temp table newsletter_shared_contract as select oid,pg_get_functiondef(oid) as definition,proacl::text as acl
from pg_proc where oid='booking.public_marketing_unsubscribe(uuid)'::regprocedure;
insert into booking.customers(name,email,marketing_consent,marketing_consent_at,marketing_unsubscribed_at)
values('Old explicit optout fixture','n259-backfill@example.test',false,now()-interval '1 day',now());
insert into booking.customers(name,email,marketing_consent)
values('Old never-consented fixture','n259-never-backfill@example.test',false);
