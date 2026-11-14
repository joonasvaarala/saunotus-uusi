-- DISPOSABLE LOCAL DATABASE ONLY. Hosted-safe real-token test is ../t259_newsletters_capture_hosted_safe.sql.
-- After262 on an isolated fixture only.
-- This test demonstrates the shared-boundary integration requiring Koodari agreement.
begin;
do $$declare a bigint;b bigint;addr text;fp text;begin
 insert into booking.customers(name,email,marketing_consent,marketing_consent_at)
 values('general optout fixture','n259-hook-'||gen_random_uuid()||'@example.test',true,now())returning id,email into a,addr;
 insert into booking.customers(name,email,marketing_consent,marketing_consent_at)
 values('general sibling fixture',upper(addr),true,now())returning id into b;
 fp:=booking._newsletter_fingerprint(addr);
 -- Same record changes as the existing public_marketing_unsubscribe, which is NOT replaced.
 update booking.customers set marketing_consent=false,marketing_unsubscribed_at=now()where id=a;
 if not exists(select 1 from booking.newsletter_suppressions where address_fingerprint=fp)then raise exception 'General opt-out not persisted';end if;
 update booking.customers set email='moved-'||addr where id=a;
 delete from booking.customers where id=a;
 if exists(select 1 from booking._newsletter_recipients('all','all')where customer_id=b)then raise exception 'Deleted/moved opt-out row leaked into newsletter';end if;
 update booking.customers set marketing_consent=true,marketing_consent_at=now(),marketing_unsubscribed_at=null where id=b;
 if exists(select 1 from booking._newsletter_recipients('all','all')where customer_id=b)then raise exception 'Duplicate re-consent erased durable suppression';end if;
end$$;
rollback;
