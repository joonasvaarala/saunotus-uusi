-- DEV/local only, synthetic data, rolls back rows. Sequence advances DO NOT roll back.
-- Run after reviewed 259, never production. Shared opt-out hook is tested separately.
begin;
set local statement_timeout='120s';
create function pg_temp.ck(ok boolean,label text) returns void language plpgsql as $$begin
 if ok is not true then raise exception 'FAIL: %',label;end if;raise notice 'PASS: %',label;
end$$;
create function pg_temp.nc(label text,lang text default 'fi') returns bigint language plpgsql as $$declare c bigint;begin
 insert into booking.customers(name,email,marketing_consent,marketing_consent_at,language)
 values('n259-'||label,'n259-'||replace(gen_random_uuid()::text,'-','')||'@example.test',true,now(),lang) returning id into c;return c;
end$$;
create function pg_temp.nr(c bigint,p bigint,st text default 'completed',future boolean default false,rule bigint default null) returns bigint language plpgsql as $$
declare o bigint;r bigint;space bigint;finish timestamptz:=case when future then now()+interval '2 days' else now()-interval '2 days' end;begin
 select id into space from booking.resources order by id limit 1;
 insert into booking.orders(customer_id,status,payment_status,locale)values(c,'confirmed','paid','fi')returning id into o;
 insert into booking.reservations(order_id,product_id,space_id,mode,persons,starts_at,ends_at,status,rule_id)
 values(o,p,space,'shared',1,finish-interval '1 hour',finish,st,rule)returning id into r;return r;
end$$;
do $test$
declare
 uid uuid:=gen_random_uuid();bad boolean;cat text;p_train bigint;p_treat bigint;p_event bigint;p_session bigint;
 c bigint;c_old bigint;c_absent bigint;c_unchecked bigint;c_cancel bigint;c_future bigint;c_multi bigint;
 c_a bigint;c_b bigint;c_dupfi bigint;c_dupen bigint;c_general bigint;c_sibling bigint;r bigint;r2 bigint;
 root_rule bigint;part_rule bigint;space bigint;oid bigint;token uuid;ntoken uuid;nid bigint;eid bigint;eidb bigint;
 data jsonb:='{"subject_fi":"Testi","subject_en":"Test","body_fi":"Testiteksti","body_en":"Test text","style":{"layout":"letter"},"segment":"all","language":"all"}';
 draft jsonb;x jsonb;y jsonb;v integer;email_a text;email_b text;fingerprint_a text;fingerprint_b text;
begin
 insert into auth.users(id,email)values(uid,'n259-'||uid||'@example.test');
 insert into booking.staff(user_id,email,name,role)values(uid,'n259-'||uid||'@example.test','Newsletter edge test','manager');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',uid,'role','authenticated')::text,true);
 update booking.customers set marketing_consent=false where marketing_consent;
 update booking.integration_config set mode='dry_run' where key='resend';
 select id into p_train from kb.products where category='training' order by id limit 1;
 select id into p_treat from kb.products where category='treatment' order by id limit 1;
 select id into p_event from kb.products where category='event' order by id limit 1;
 select p.id into p_session from kb.products p join booking.product_config pc on pc.product_id=p.id where pc.sale_kind='public_shift' order by p.id limit 1;
 select id into space from booking.resources order by id limit 1;
 perform pg_temp.ck(p_train is not null and p_treat is not null and p_event is not null and p_session is not null,'required real catalog fixture categories exist');
 bad:=false;begin insert into booking.customers(name,marketing_consent)values('Missing consent date',true);exception when check_violation then bad:=true;end;
 perform pg_temp.ck(bad,'real consent timestamp constraint rejects old broken fixture');
 bad:=false;begin insert into booking.gift_cards(code,initial_amount,balance)values('ABCDEFGHIJKL',1,1);exception when check_violation then bad:=true;end;
 perform pg_temp.ck(bad,'native card requires HH prefix');
 bad:=false;begin insert into booking.gift_cards(code,initial_amount,balance)values('HH-INVALID',1,1);exception when check_violation then bad:=true;end;
 perform pg_temp.ck(bad,'card requires exactly 12 uppercase alphanumeric characters');

 c:=pg_temp.nc('session');r:=pg_temp.nr(c,p_session);
 perform pg_temp.ck(exists(select 1 from booking._newsletter_recipients('session_only','all')where customer_id=c),'completed actual session qualifies');
 c_unchecked:=pg_temp.nc('unchecked');r:=pg_temp.nr(c_unchecked,p_train,'confirmed');perform pg_temp.nr(c_unchecked,p_session);
 perform pg_temp.ck(not exists(select 1 from booking._newsletter_recipients('training','all')where customer_id=c_unchecked),'past confirmed unchecked training is not attendance');
 perform pg_temp.ck(not exists(select 1 from booking._newsletter_recipients('session_only','all')where customer_id=c_unchecked),'non-session history is separate from completed-course predicate');
 c_absent:=pg_temp.nc('absent');r:=pg_temp.nr(c_absent,p_train);update booking.reservations set checkin_at=now()-interval '3 days' where id=r;
 insert into booking.training_participant_details(reservation_id,present)values(r,false);
 perform pg_temp.ck(not exists(select 1 from booking._newsletter_recipients('training','all')where customer_id=c_absent),'explicit present=false overrides completed/check-in');
 c_cancel:=pg_temp.nc('cancelled');r:=pg_temp.nr(c_cancel,p_train,'cancelled');insert into booking.training_participant_details(reservation_id,present)values(r,true);perform pg_temp.nr(c_cancel,p_session);
 perform pg_temp.ck(not exists(select 1 from booking._newsletter_recipients('training','all')where customer_id=c_cancel),'cancelled attendance marker does not qualify');
 perform pg_temp.ck(exists(select 1 from booking._newsletter_recipients('session_only','all')where customer_id=c_cancel),'cancelled-only non-session reservation is not confirmed history');
 c_future:=pg_temp.nc('future');r:=pg_temp.nr(c_future,p_train,'completed',true);insert into booking.training_participant_details(reservation_id,present)values(r,true);
 perform pg_temp.ck(not exists(select 1 from booking._newsletter_recipients('training','all')where customer_id=c_future),'future-only training never proves completion');
 r:=pg_temp.nr(c_future,p_session,'completed',true);
 perform pg_temp.ck(not exists(select 1 from booking._newsletter_recipients('session_only','all')where customer_id=c_future),'future-only session never proves visit');
 c:=pg_temp.nc('no-show');r:=pg_temp.nr(c,p_train,'no_show');insert into booking.training_participant_details(reservation_id,present)values(r,true);
 perform pg_temp.ck(not exists(select 1 from booking._newsletter_recipients('training','all')where customer_id=c),'no-show does not qualify even with contradictory present marker');
 c_old:=pg_temp.nc('old-course');r:=pg_temp.nr(c_old,p_train);insert into booking.training_participant_details(reservation_id,present)values(r,true);
 perform pg_temp.nr(c_old,p_train,'completed',true);perform pg_temp.nr(c_old,p_session);
 perform pg_temp.ck(exists(select 1 from booking._newsletter_recipients('training','all')where customer_id=c_old),'future enrollment does not erase a previously completed course');
 perform pg_temp.ck(not exists(select 1 from booking._newsletter_recipients('session_only','all')where customer_id=c_old),'prior course customer cannot leak into session-only');
 c:=pg_temp.nc('checkin');r:=pg_temp.nr(c,p_treat,'confirmed');update booking.reservations set checkin_at=now()-interval '3 days' where id=r;
 perform pg_temp.ck(exists(select 1 from booking._newsletter_recipients('treatment','all')where customer_id=c),'past confirmed treatment with check-in is actual attendance');
 c:=pg_temp.nc('unchecked-treatment');perform pg_temp.nr(c,p_treat,'confirmed');
 perform pg_temp.ck(not exists(select 1 from booking._newsletter_recipients('treatment','all')where customer_id=c),'past unchecked treatment is not attendance');
 c:=pg_temp.nc('checkout');r:=pg_temp.nr(c,p_event,'confirmed');update booking.reservations set checkout_at=now()-interval '3 days' where id=r;
 perform pg_temp.ck(exists(select 1 from booking._newsletter_recipients('event','all')where customer_id=c),'past event with checkout qualifies');

 -- Configured multi-session course: required child cannot be missing, future or absent.
 insert into booking.schedule_rules(product_id,label,mode,space_id,weekdays,start_time,duration_minutes,kind,training_segment_only)
 values(p_train,'n259 main','shared',space,array[1]::smallint[],'12:00',60,'event',false)returning id into root_rule;
 insert into booking.schedule_rules(product_id,label,mode,space_id,weekdays,start_time,duration_minutes,kind,training_segment_only)
 values(p_train,'n259 required','shared',space,array[1]::smallint[],'12:00',60,'event',true)returning id into part_rule;
 insert into booking.training_segments(option_rule_id,position,segment_rule_id)values(root_rule,1,part_rule);
 c_multi:=pg_temp.nc('multi');r:=pg_temp.nr(c_multi,p_train,'completed',false,root_rule);insert into booking.training_participant_details(reservation_id,present)values(r,true);
 select order_id into oid from booking.reservations where id=r;
 perform pg_temp.ck(not exists(select 1 from booking._newsletter_recipients('training','all')where customer_id=c_multi),'required missing session prevents course completion');
 insert into booking.reservations(order_id,product_id,space_id,mode,persons,starts_at,ends_at,status,rule_id)
 values(oid,p_train,space,'shared',1,now()+interval '1 day',now()+interval '2 days','completed',part_rule)returning id into r2;
 insert into booking.training_participant_details(reservation_id,present)values(r2,true);
 perform pg_temp.ck(not exists(select 1 from booking._newsletter_recipients('training','all')where customer_id=c_multi),'required future session prevents course completion');
 update booking.reservations set starts_at=now()-interval '4 days',ends_at=now()-interval '3 days' where id=r2;
 update booking.training_participant_details set present=false where reservation_id=r2;
 perform pg_temp.ck(not exists(select 1 from booking._newsletter_recipients('training','all')where customer_id=c_multi),'one absent session prevents course completion');
 update booking.training_participant_details set present=true where reservation_id=r2;
 perform pg_temp.ck(exists(select 1 from booking._newsletter_recipients('training','all')where customer_id=c_multi),'all required sessions ended and positively attended qualifies');
 c:=pg_temp.nc('segment-alone');r:=pg_temp.nr(c,p_train,'completed',false,part_rule);insert into booking.training_participant_details(reservation_id,present)values(r,true);
 perform pg_temp.ck(not exists(select 1 from booking._newsletter_recipients('training','all')where customer_id=c),'standalone segment-only booking cannot certify full course');

 c_dupfi:=pg_temp.nc('duplicate-fi');c_dupen:=pg_temp.nc('duplicate-en','en');
 update booking.customers set email=(select upper(email) from booking.customers where id=c_dupfi) where id=c_dupen;
 perform pg_temp.ck(exists(select 1 from booking._newsletter_recipients('all','en')where customer_id=c_dupen),'explicit EN filter runs before address dedup');
 perform pg_temp.ck(exists(select 1 from booking._newsletter_recipients('all','all')where customer_id=c_dupfi) and not exists(select 1 from booking._newsletter_recipients('all','all')where customer_id=c_dupen),'all-languages duplicate uses deterministic lowest eligible id');
 c_a:=pg_temp.nc('address-a');c_b:=pg_temp.nc('address-b');
 select email,booking._newsletter_fingerprint(email) into email_a,fingerprint_a from booking.customers where id=c_a;
 select email,booking._newsletter_fingerprint(email) into email_b,fingerprint_b from booking.customers where id=c_b;
 draft:=booking.svc_newsletter_save(null,data);nid:=(draft->>'id')::bigint;v:=(draft->>'version')::int;
 x:=booking.admin_newsletter_dispatch(nid,v,false);token:=(x->>'preview_token')::uuid;
 update booking.customers set email='changed-'||email_a where id=c_a;
 bad:=false;begin perform booking.admin_newsletter_dispatch(nid,v,true,token);exception when sqlstate 'BK001' then bad:=true;end;
 perform pg_temp.ck(bad,'address change after preview invalidates confirmation');
 update booking.customers set email=email_a where id=c_a;
 x:=booking.admin_newsletter_dispatch(nid,v,false);perform booking.admin_newsletter_dispatch(nid,v,true,(x->>'preview_token')::uuid);
 select id into eid from booking.email_outbox where kind='newsletter' and payload->>'customer_id'=c_a::text and payload->>'newsletter_log_id'=(select id::text from booking.newsletter_logs where newsletter_id=nid);
 select id into eidb from booking.email_outbox where kind='newsletter' and payload->>'customer_id'=c_b::text and payload->>'newsletter_log_id'=(select id::text from booking.newsletter_logs where newsletter_id=nid);
 update booking.email_outbox set status='sending' where id in(eid,eidb);
 perform pg_temp.ck((select payload->>'address_fingerprint' from booking.email_outbox where id=eid)=fingerprint_a,'queue persists SHA256 of approved normalized address');
 perform pg_temp.ck(booking.email_newsletter_payload(eid)->>'to'=lower(email_a),'unchanged approved address can deliver');
 update booking.customers set email=upper(email_a) where id=c_a;
 perform pg_temp.ck(booking.email_newsletter_payload(eid)->>'to'=lower(email_a),'case-only spelling preserves approved normalized address');
 bad:=false;begin
 insert into booking.email_outbox(kind,locale,dedupe_key,payload,status)
 select kind,locale,'n259-duplicate-'||gen_random_uuid(),jsonb_set(payload,'{customer_id}',to_jsonb(c_b)),'pending' from booking.email_outbox where id=eid;
 exception when unique_violation then bad:=true;end;
 perform pg_temp.ck(bad,'unique log/address fingerprint rejects duplicate customer payload');
 update booking.customers set email='changed-'||email_a where id=c_a;
 perform pg_temp.ck(booking.email_newsletter_payload(eid)->>'allowed'='false','queue never follows customer to an unapproved new address');
 update booking.customers set email=email_a where id=c_a;
 update booking.customers set email=upper(email_a) where id=c_b;
 perform pg_temp.ck(booking.email_newsletter_payload(eid)->>'allowed'='true' and booking.email_newsletter_payload(eidb)->>'allowed'='false','address convergence cannot duplicate newsletter delivery');
 update booking.customers set email=email_b where id=c_b;
 update booking.email_outbox set payload=payload-'address_fingerprint' where id=eidb;
 perform pg_temp.ck(booking.email_newsletter_payload(eidb)->>'allowed'='false','missing snapshot fingerprint fails closed');
 update booking.email_outbox set status='dead' where id=eidb;
 select j->'delivery' into x from jsonb_array_elements(booking.admin_newsletters_list())j where (j->>'id')::bigint=nid;
 perform pg_temp.ck(x->>'failed'='1','failed summary includes terminal dead rows');
 select t.token into ntoken from booking.newsletter_optout_tokens t where t.address_fingerprint=fingerprint_a;
 update booking.customers set email='changed-'||email_a where id=c_a;
 set local role anon;
 x:=booking.public_newsletter_unsubscribe(ntoken);y:=booking.public_newsletter_unsubscribe(gen_random_uuid());
 reset role;
 perform pg_temp.ck(x=y and x='{"ok":true}'::jsonb,'anonymous token opt-out reveals no recipient or token existence');
 c:=pg_temp.nc('new-duplicate');update booking.customers set email=email_a where id=c;
 perform pg_temp.ck(not exists(select 1 from booking._newsletter_recipients('all','all')where customer_id=c),'persistent opt-out suppresses another consented profile at same address');
 perform pg_temp.ck(not exists(select 1 from booking.newsletter_suppressions where address_fingerprint=booking._newsletter_fingerprint('changed-'||email_a)),'old token remains bound to OLD address, not current profile address');
 update booking.customers set email=email_a where id=c_a;
 perform pg_temp.ck(booking.email_newsletter_payload(eid)->>'allowed'='false','address opt-out is freshly rechecked after queueing');
 delete from booking.email_outbox where id=eid;
 perform booking.public_newsletter_unsubscribe(ntoken);
 perform pg_temp.ck(exists(select 1 from booking.newsletter_optout_tokens t where t.token=ntoken),'opt-out token remains usable after outbox cleanup');
 perform pg_temp.ck(not has_table_privilege('anon','booking.newsletter_optout_tokens','select') and not has_table_privilege('authenticated','booking.newsletter_suppressions','select'),'opt-out maps are private; no address enumeration');
 c_general:=pg_temp.nc('general-optout');c_sibling:=pg_temp.nc('general-sibling');
 update booking.customers set email=(select email from booking.customers where id=c_general)where id=c_sibling;
 update booking.customers set marketing_consent=false,marketing_unsubscribed_at=now()where id=c_general;
 perform pg_temp.ck(not exists(select 1 from booking._newsletter_recipients('all','all')where customer_id=c_sibling),'existing general opt-out is respected across current duplicate rows');
end $test$;
rollback;
