-- REVIEW ONLY, not approval to run. Prepared hosted-safe attendance/language regression.
-- Transaction+ROLLBACK; synthetic customers/orders/reservations/rules ONLY, real catalog READ.
-- NO all-customer consent update, global config, staff/JWT writes, preview or dispatch.
-- Any sequence/audit/other trigger side effects need review; sequence IDs still advance.
-- Requires approved259 + capture; NEVER use local-fixture/rollback-seed/rollback-check hosted.
begin;
set local lock_timeout='3s';
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
 root_rule bigint;part_rule bigint;space bigint;event_day date:=(now() at time zone 'Europe/Helsinki')::date-7;oid bigint;token uuid;ntoken uuid;nid bigint;eid bigint;eidb bigint;
 data jsonb:='{"subject_fi":"Testi","subject_en":"Test","body_fi":"Testiteksti","body_en":"Test text","style":{"layout":"letter"},"segment":"all","language":"all"}';
 draft jsonb;x jsonb;y jsonb;v integer;email_a text;email_b text;fingerprint_a text;fingerprint_b text;
begin
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

 bad:=false;begin
 insert into booking.schedule_rules(product_id,label,mode,space_id,weekdays,start_time,duration_minutes,kind,valid_from,valid_to)
 values(p_train,'n259 invalid event','shared',space,array[extract(isodow from event_day)::smallint],'12:00',60,'event',event_day,event_day+1);
 exception when check_violation then bad:=true;end;
 perform pg_temp.ck(bad,'real event-shape constraint rejects multi-date event rules');
 -- Configured multi-session course: required child cannot be missing, future or absent.
 insert into booking.schedule_rules(product_id,label,mode,space_id,weekdays,start_time,duration_minutes,kind,training_segment_only,valid_from,valid_to)
 values(p_train,'n259 main','shared',space,array[extract(isodow from event_day)::smallint],'12:00',60,'event',false,event_day,event_day)returning id into root_rule;
 insert into booking.schedule_rules(product_id,label,mode,space_id,weekdays,start_time,duration_minutes,kind,training_segment_only,valid_from,valid_to)
 values(p_train,'n259 required','shared',space,array[extract(isodow from event_day)::smallint],'12:00',60,'event',true,event_day,event_day)returning id into part_rule;
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
end $test$;
rollback;
