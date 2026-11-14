-- DISPOSABLE LOCAL DATABASE ONLY; broad fixture consent/config updates, NEVER hosted.
-- booking_259: rollback-only integration test, psql -X -v ON_ERROR_STOP=1 -1 -f ...
-- Local synthetic fixture only. No mail sender runs; all fixture writes roll back.
begin;
set local statement_timeout='120s';
create function pg_temp.ck(ok boolean,label text) returns void language plpgsql as $$begin
  if ok is not true then raise exception 'FAIL: %',label; end if;
  raise notice 'PASS: %',label;
end$$;
do $test$
declare
  uid uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
  ids bigint[]; c bigint; oid bigint; pid bigint; sauna bigint; res_id bigint;
  x jsonb; y jsonb; draft jsonb; data jsonb; tok uuid; nid bigint; eid bigint; n int; base_n int;
  blocked boolean; typ text; i int; v int;
begin
  perform pg_temp.ck(not has_table_privilege('authenticated','booking.newsletters','select') and not has_table_privilege('anon','booking.newsletter_logs','select'),'direct table reads denied');
  perform pg_temp.ck((select bool_and(relrowsecurity) from pg_class pc where pc.oid in ('booking.newsletters'::regclass,'booking.newsletter_logs'::regclass)),'RLS enabled');
  perform pg_temp.ck(not has_function_privilege('anon','booking.admin_newsletter_dispatch(bigint,integer,boolean,uuid)','execute'),'anon cannot preview or send');
  perform pg_temp.ck(not has_function_privilege('service_role','booking.admin_newsletter_dispatch(bigint,integer,boolean,uuid)','execute'),'bots cannot send');
  perform pg_temp.ck(has_function_privilege('service_role','booking.svc_newsletter_save(bigint,jsonb,integer)','execute') and not has_function_privilege('authenticated','booking.svc_newsletter_save(bigint,jsonb,integer)','execute'),'service-only author RPC');
  perform pg_temp.ck(not has_function_privilege('authenticated','booking._newsletter_recipients(text,text)','execute'),'recipient helper is private');
  insert into auth.users(id,email) values(uid,'newsletter259-manager@example.test'),(outsider,'newsletter259-outsider@example.test');
  insert into booking.staff(user_id,email,name,role) values(uid,'newsletter259-manager@example.test','Newsletter test','manager');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',uid,'role','authenticated')::text,true);
  -- Existing consented contacts must not affect deterministic test audience counts.
  -- Disposable fixture-wide changes: NEVER run this suite on any hosted database.
  update booking.customers set marketing_consent=false where marketing_consent;
  update booking.integration_config set mode='dry_run' where key='resend';
  insert into booking.settings(key,value) values('newsletter_enabled','true'::jsonb) on conflict (key) do update set value='true'::jsonb; -- booking_306: testit lähettävät, joten kytkin avataan (kertakäyttökanta)
  select id into sauna from booking.resources order by id limit 1;
  for i in 1..8 loop
    insert into booking.customers(name,email,marketing_consent,marketing_consent_at,language)
      values('newsletter259-'||i,'newsletter259-'||i||'@example.test',i<>7,now(),case when i=2 then 'en' else 'fi' end) returning id into c;
    ids:=array_append(ids,c);
  end loop;
  update booking.customers set anonymized_at=now() where id=ids[8];
  select count(*) into n from booking._newsletter_recipients('all','all');
  perform pg_temp.ck(n=6,'consent and anonymisation exclusion');
  perform pg_temp.ck((select count(*) from booking._newsletter_recipients('all','en'))=1,'language filter');
  -- Historical product classifications. completed rows avoid capacity/booking-trigger side effects.
  for i in 1..4 loop
    typ:=case i when 1 then 'training' when 2 then 'treatment' when 3 then 'event' else 'public_sauna' end;
    -- Reuse a real product of each category; minimal local fixture seeds equivalent products.
    select id into pid from kb.products where category=typ order by id limit 1;
    if pid is null then raise exception 'Fixture requires product category %',typ; end if;
    insert into booking.orders(customer_id,status,payment_status,locale) values(ids[i],'confirmed','paid',case when i=2 then 'en' else 'fi' end) returning id into oid;
    insert into booking.reservations(order_id,product_id,space_id,mode,persons,starts_at,ends_at,status)
      values(oid,pid,sauna,'shared',1,now()-interval '3 days',now()-interval '2 days','completed') returning id into res_id;
  end loop;
  perform pg_temp.ck((select count(*) from booking._newsletter_recipients('training','all'))=1,'completed training segment');
  perform pg_temp.ck((select count(*) from booking._newsletter_recipients('treatment','all'))=1,'treatment segment');
  perform pg_temp.ck((select count(*) from booking._newsletter_recipients('event','all'))=1,'event segment');
  perform pg_temp.ck((select count(*) from booking._newsletter_recipients('session_only','all'))=1,'session-only segment');
  select id into pid from kb.products where category='treatment' order by id limit 1;
  insert into booking.reservations(order_id,product_id,space_id,mode,persons,starts_at,ends_at,status)
    values(oid,pid,sauna,'shared',1,now()-interval '5 days',now()-interval '4 days','completed');
  perform pg_temp.ck((select count(*) from booking._newsletter_recipients('session_only','all'))=0,'mixed visits excluded from session-only');
  insert into booking.orders(customer_id,status,payment_status,locale,created_at)
    values(ids[5],'confirmed','paid','fi',date_trunc('year',now())-interval '1 month') returning id into oid;
  insert into booking.gift_cards(code,initial_amount,balance,status,purchase_order_id,buyer_customer_id)
    values('HH'||upper(left(replace(uid::text,'-',''),10)),1,1,'active',oid,ids[5]);
  perform pg_temp.ck((select count(*) from booking._newsletter_recipients('gift_buyers','all'))=1,'gift buyer segment');
  perform pg_temp.ck((select count(*) from booking._newsletter_recipients('christmas_gift_buyers','all'))=1,'previous Nov-Dec gift buyers');
  data:='{"subject_fi":"Testi","subject_en":"Test","body_fi":"Suomeksi","body_en":"English","style":{"layout":"editorial","accent":"#123456","cta_url":"https://saunotus.fi/lahjakortti/","cta_fi":"Avaa","cta_en":"Open"},"segment":"all","language":"all"}';
  select count(*) into base_n from booking.email_outbox;
  draft:=booking.svc_newsletter_save(null,data);nid:=(draft->>'id')::bigint;v:=(draft->>'version')::integer;
  perform pg_temp.ck((select count(*) from booking.email_outbox)=base_n,'bot draft never queues mail');
  blocked:=false;begin perform booking.admin_newsletter_save(nid,'{"style":{"layout":"letter"}}',v);exception when others then blocked:=true;end;
  perform pg_temp.ck(blocked,'human cannot alter bot style');
  blocked:=false;begin perform booking.svc_newsletter_save(null,data||'{"style":{"layout":"letter","image_url":"javascript:alert(1)"}}');exception when others then blocked:=true;end;
  perform pg_temp.ck(blocked,'unsafe style URL rejected');
  blocked:=false;begin perform booking.admin_newsletter_dispatch(nid,v,true,null);exception when sqlstate 'BK001' then blocked:=true;end;
  perform pg_temp.ck(blocked,'confirmation cannot bypass preview');
  x:=booking.admin_newsletter_dispatch(nid,v,false);tok:=(x->>'preview_token')::uuid;
  perform pg_temp.ck((x->>'recipient_count')::int=6 and not x?'recipients' and not x?'emails' and (select count(*) from booking.email_outbox)=base_n,'preview counts only, sends nothing');
  update booking.customers set marketing_consent=false where id=ids[6];
  blocked:=false;begin perform booking.admin_newsletter_dispatch(nid,v,true,tok);exception when sqlstate 'BK001' then blocked:=true;end;
  perform pg_temp.ck(blocked,'consent change invalidates preview');
  x:=booking.admin_newsletter_dispatch(nid,v,false);tok:=(x->>'preview_token')::uuid;
  draft:=booking.admin_newsletter_save(nid,'{"subject_fi":"Muokattu"}',v);v:=(draft->>'version')::int;
  blocked:=false;begin perform booking.admin_newsletter_dispatch(nid,v,true,tok);exception when sqlstate 'BK001' then blocked:=true;end;
  perform pg_temp.ck(blocked,'editing invalidates preview');
  x:=booking.admin_newsletter_dispatch(nid,v,false);tok:=(x->>'preview_token')::uuid;
  update booking.newsletters set preview_at=now()-interval '31 minutes' where id=nid;
  blocked:=false;begin perform booking.admin_newsletter_dispatch(nid,v,true,tok);exception when sqlstate 'BK001' then blocked:=true;end;
  perform pg_temp.ck(blocked,'expired preview rejected');
  x:=booking.admin_newsletter_dispatch(nid,v,false);tok:=(x->>'preview_token')::uuid;
  update booking.integration_config set mode='off' where key='resend';
  blocked:=false;begin perform booking.admin_newsletter_dispatch(nid,v,true,tok);exception when sqlstate 'BK001' then blocked:=true;end;
  perform pg_temp.ck(blocked,'off mode does not mark a newsletter sent');
  update booking.integration_config set mode='dry_run' where key='resend';
  y:=booking.admin_newsletter_dispatch(nid,v,true,tok);
  perform pg_temp.ck((y->>'queued_count')::int=5 and (select count(*) from booking.email_outbox)=base_n+5,'one outbox row per eligible customer');
  y:=booking.admin_newsletter_dispatch(nid,v,true,tok);
  perform pg_temp.ck(y->>'already_sent'='true' and (select count(*) from booking.email_outbox)=base_n+5,'retry does not send twice');
  perform pg_temp.ck(not exists(select 1 from booking.email_outbox e where e.kind='newsletter' and e.payload->>'customer_id'=any(array[ids[6]::text,ids[7]::text,ids[8]::text])),'no opt-outs or anonymised recipients queued');
  select id into eid from booking.email_outbox where kind='newsletter' and payload->>'customer_id'=ids[2]::text order by id desc limit 1;
  update booking.email_outbox set status='sending' where id=eid;
  y:=booking.email_newsletter_payload(eid);
  perform pg_temp.ck(y->>'allowed'='true' and y->>'locale'='en' and y->>'subject'='Test' and y->>'body'='English' and y->>'unsubscribe_url' like '%/hallinta/newsletter-unsubscribe.html#token=%&lang=en','English payload with opt-out and bot style');
  update booking.customers set marketing_consent=false where id=ids[2];
  perform pg_temp.ck(booking.email_newsletter_payload(eid)->>'allowed'='false','delivery rechecks consent after queueing');
  perform pg_temp.ck(not exists(select 1 from information_schema.columns where table_schema='booking' and table_name='newsletter_logs' and column_name ~ 'email|recipient.*id'),'no recipient address/list in logs');
  blocked:=false;begin perform booking.svc_newsletter_save(nid,data,v);exception when sqlstate 'BK001' then blocked:=true;end;
  perform pg_temp.ck(blocked,'sent newsletter is immutable to bots');
  -- 5000 is a hard cap, not a silent LIMIT that loses part of the audience.
  insert into booking.customers(name,email,marketing_consent,marketing_consent_at,language)
    select 'newsletter259-cap','newsletter259-cap-'||uid||'-'||g||'@example.test',true,now(),'fi' from generate_series(1,5001) g;
  draft:=booking.svc_newsletter_save(null,data);nid:=(draft->>'id')::bigint;v:=(draft->>'version')::int;
  blocked:=false;begin perform booking.admin_newsletter_dispatch(nid,v,false);exception when sqlstate 'BK001' then blocked:=true;end;
  perform pg_temp.ck(blocked,'recipient cap rejects oversized audience without partial dispatch');
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  blocked:=false;begin perform booking.admin_newsletter_dispatch(nid,v,false);exception when sqlstate 'BK001' then blocked:=true;end;
  perform pg_temp.ck(blocked,'service role cannot use human dispatch even when invoked by owner');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',outsider,'role','authenticated')::text,true);
  blocked:=false;begin perform booking.admin_newsletters_list();exception when sqlstate 'BK001' then blocked:=true;end;
  perform pg_temp.ck(blocked,'non-staff cannot list drafts');
end $test$;
rollback;
