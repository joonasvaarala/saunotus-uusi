-- REVIEW PACKAGE ONLY. Do NOT run on DEV/PROD without explicit approval.
-- Hosted-safe shape: transaction + ROLLBACK, ONLY generated synthetic customer rows;
-- no fixture/schema installation, global consent changes, config changes or mail dispatch.
-- Run after approved capture install; also valid DURING feature rollback (no UI tables used).
-- Sequences and any nontransactional/audit side effects need operator review; IDs advance.
begin;
set local lock_timeout='3s';
set local statement_timeout='30s';
do $test$
declare a bigint;b bigint;n bigint;token uuid;addr text;other text;fp text;otherfp text;x jsonb;y jsonb;
 definition text;acl text;
begin
 if not exists(select 1 from pg_catalog.pg_trigger t where t.tgrelid='booking.customers'::regclass
  and t.tgname='newsletter_capture_general_optout' and t.tgenabled in('O','A')
  and t.tgfoid=to_regprocedure('booking._newsletter_capture_general_optout()')) then raise exception 'Approved capture must be installed';end if;
 select pg_get_functiondef(oid),proacl::text into definition,acl from pg_catalog.pg_proc
 where oid='booking.public_marketing_unsubscribe(uuid)'::regprocedure;
 addr:='n259-safe-'||replace(gen_random_uuid()::text,'-','')||'@example.test';
 other:='n259-safe-'||replace(gen_random_uuid()::text,'-','')||'@example.test';
 fp:=booking._newsletter_fingerprint(addr);otherfp:=booking._newsletter_fingerprint(other);
 insert into booking.customers(name,email,marketing_consent,marketing_consent_at)
 values('Newsletter synthetic optout test',addr,true,now())returning id,unsubscribe_token into a,token;
 insert into booking.customers(name,email,marketing_consent,marketing_consent_at)
 values('Newsletter synthetic duplicate',upper(addr),true,now())returning id into b;
 -- Invoke the REAL pre-existing token RPC, not an equivalent UPDATE.
 set local role anon;
 x:=booking.public_marketing_unsubscribe(token);y:=booking.public_marketing_unsubscribe(token);
 reset role;
 if x is distinct from '{"ok":true}'::jsonb or y is distinct from x then raise exception 'Shared RPC success/repeat response changed';end if;
 if not exists(select 1 from booking.newsletter_suppressions where address_fingerprint=fp)then raise exception 'Token opt-out not captured';end if;
 if not booking._newsletter_address_blocked(fp,addr)then raise exception 'Duplicate address not blocked';end if;
 update booking.customers set email=other where id=a;
 delete from booking.customers where id=a;
 update booking.customers set marketing_consent=false where id=b;
 update booking.customers set marketing_consent=true,marketing_consent_at=now(),marketing_unsubscribed_at=null where id=b;
 if not booking._newsletter_address_blocked(fp,addr) then raise exception 'Address edit/deletion or duplicate re-consent erased suppression';end if;
 -- A never-consented profile and ordinary address edit must NOT create suppression.
 insert into booking.customers(name,email,marketing_consent)values('Newsletter never consented',other,false)returning id into n;
 update booking.customers set email='never-'||other where id=n;
 if exists(select 1 from booking.newsletter_suppressions where address_fingerprint in(otherfp,booking._newsletter_fingerprint('never-'||other)))then raise exception 'Never-consented profile was suppressed';end if;
 -- Simultaneous email change AND withdrawal captures BOTH valid OLD and NEW addresses.
 insert into booking.customers(name,email,marketing_consent,marketing_consent_at)
 values('Newsletter simultaneous withdrawal',other,true,now())returning id,unsubscribe_token into a,token;
 update booking.customers set email='new-'||other,marketing_consent=false,marketing_unsubscribed_at=now()where id=a;
 if not exists(select 1 from booking.newsletter_suppressions where address_fingerprint=otherfp)
  or not exists(select 1 from booking.newsletter_suppressions where address_fingerprint=booking._newsletter_fingerprint('new-'||other))then raise exception 'Combined email/withdrawal lost old or new fingerprint';end if;
 perform booking.public_marketing_unsubscribe(token);
 update booking.customers set marketing_consent=true,marketing_consent_at=now(),marketing_unsubscribed_at=null,email='third-'||other where id=a;
 delete from booking.customers where id=a;
 if not booking._newsletter_address_blocked(otherfp,other) then raise exception 'Suppression did not survive re-consent/edit/deletion';end if;
 if booking.public_marketing_unsubscribe(null) is distinct from '{"ok":false,"code":"not_found"}'::jsonb
  or booking.public_marketing_unsubscribe(gen_random_uuid()) is distinct from '{"ok":false,"code":"not_found"}'::jsonb then raise exception 'Shared missing-token contract changed';end if;
 if exists(select 1 from pg_catalog.pg_proc where oid='booking.public_marketing_unsubscribe(uuid)'::regprocedure
   and(pg_get_functiondef(oid) is distinct from definition or proacl::text is distinct from acl))then raise exception 'Shared function/grants changed';end if;
 raise notice 'PASS: real token RPC, repeat, duplicate re-consent, address edit/delete, OLD+NEW withdrawal, never-consented, shared contract unchanged';
end $test$;
rollback;
