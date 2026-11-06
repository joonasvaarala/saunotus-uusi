-- Local PG only. Run after migrations + fixtures/10_test_helpers.sql. All test rows roll back.
\set ON_ERROR_STOP on
begin;
set local statement_timeout='60s';
create function pg_temp.ck(ok boolean,label text) returns void language plpgsql as $$ begin
  if ok is not true then raise exception 'FAIL: %',label; end if;
  raise notice 'PASS: %',label;
end $$;
grant execute on function pg_temp.ck(boolean,text) to public;
do $test$
declare
  u uuid:=test.mk_staff('training255-manager@example.test','manager');
  p bigint; r bigint; segment bigint; other_p bigint; other_r bigint; sauna bigint; blockid bigint; manualid bigint;
  d date:=(now() at time zone 'Europe/Helsinki')::date+30;
  x jsonb; y jsonb; person jsonb; oid bigint; resid bigint; mid uuid; count_before int; n int; w1 bigint; w2 bigint; copied bigint;
  hit boolean; cap_before int; hash_before text; body jsonb; payments_before jsonb;
begin
  perform test.login(u); reset role;
  p:=(booking.admin_product_create('{"name":"t255 Training","name_en":"t255 Training","price":200,"vat_rate":25.5,"category":"training","active":true}'::jsonb)->>'id')::bigint;
  perform booking.admin_update_product_config(p,'{"bookable":true,"shop_visible":false,"course_price":1950,"deposit_amount":570}');
  r:=(booking.admin_event_rule_upsert(null,p,jsonb_build_object('date',d,'start_time','10:00','duration_minutes',4320,'max_persons',6))->>'id')::bigint;
  segment:=(booking.admin_event_rule_upsert(null,p,jsonb_build_object('date',d+7,'start_time','10:00','duration_minutes',1440,'max_persons',6))->>'id')::bigint;
  perform booking.admin_training_segments_set(r,array[segment]);
  select id into sauna from booking.resources where code='savusauna';
  x:=booking.admin_training_space_add(r,sauna,d,'14:00','16:00'); blockid:=(x->>'id')::bigint;
  perform pg_temp.ck(exists(select 1 from booking.space_blocks where event_block_id=blockid and active),'training space materializes into existing space_blocks');
  x:=booking.admin_day_view(d);
  perform pg_temp.ck(exists(select 1 from jsonb_array_elements(x->'blocks') b where (b->>'space_id')::bigint=sauna),'day view includes the same block');
  x:=booking.admin_calendar_space_blocks((d::timestamp) at time zone 'Europe/Helsinki',((d+1)::timestamp) at time zone 'Europe/Helsinki');
  perform pg_temp.ck(jsonb_array_length(x)>0,'calendar returns the same block');
  hit:=false; begin perform booking.admin_training_space_add(r,sauna,d,'15:00','17:00'); exception when sqlstate 'BK001' then hit:=true; end;
  perform pg_temp.ck(hit,'overlapping training block rejected');
  x:=booking.admin_create_block(sauna,((d+1)+'12:00'::time) at time zone 'Europe/Helsinki',((d+1)+'14:00'::time) at time zone 'Europe/Helsinki','Tyovuoro-Tapio test');manualid:=(x->>'id')::bigint;
  hit:=false;begin perform booking.admin_training_space_add(r,sauna,d+1,'13:00','15:00'); exception when sqlstate 'BK001' then hit:=true;end;
  perform pg_temp.ck(hit,'existing Tapio/manual block respected');
  hit:=false;begin perform booking.admin_training_space_cancel(r,blockid,false);exception when sqlstate 'BK001' then hit:=true;end;
  perform pg_temp.ck(hit and exists(select 1 from booking.space_blocks where event_block_id=blockid),'cancel requires confirmation');
  perform booking.admin_training_space_cancel(r,blockid,true);
  perform pg_temp.ck(not exists(select 1 from booking.space_blocks where event_block_id=blockid) and exists(select 1 from booking.space_blocks where id=manualid and active),'cancel releases only this course block');
  -- A live booking in the physical sauna must also block a course reservation.
  other_p:=(booking.admin_product_create('{"name":"t255 Other","price":20,"vat_rate":25.5,"category":"training","active":true}'::jsonb)->>'id')::bigint;
  perform booking.admin_update_product_config(other_p,'{"bookable":true}');
  other_r:=(booking.admin_event_rule_upsert(null,other_p,jsonb_build_object('date',d+2,'start_time','14:00','duration_minutes',120,'max_persons',6))->>'id')::bigint;
  update booking.schedule_rules set space_id=sauna where id=other_r;
  x:=booking.admin_create_booking(p_rule_id=>other_r,p_date=>d+2,p_persons=>1,p_customer=>'{"name":"Other person","email":"other255@example.test"}');
  hit:=false;begin perform booking.admin_training_space_add(r,sauna,d+2,'15:00','17:00');exception when sqlstate 'BK001' then hit:=true;end;
  perform pg_temp.ck(hit,'live physical reservation prevents a course space booking');
  x:=booking.admin_training_space_add(r,sauna,d,'14:00','16:00');

  select md5(pg_get_functiondef('booking._training_option_seats_left(bigint)'::regprocedure)) into hash_before;
  cap_before:=booking._training_option_seats_left(segment);
  x:=booking.admin_training_person_add(r,'{"name":"English Participant","email":"english255@example.test","phone":"0401111111","language":"en"}');
  oid:=(x->>'order_id')::bigint;resid:=(x->>'reservation_id')::bigint;
  perform pg_temp.ck(booking._training_option_seats_left(segment)=cap_before-1,'manual full-training participant consumes segment capacity');
  perform pg_temp.ck((select count(*) from booking.reservations where order_id=oid and status='confirmed')=2,'one seat per segment, no duplicate reservations');
  perform booking.admin_training_person_save(resid,'{"diet":"vegan","accommodation":"single","arrival":"15:00","language":"en","present":true}');
  person:=booking.admin_training_people(r)->0;
  perform pg_temp.ck(person->>'diet'='vegan' and (person->>'present')::boolean and (person->>'paid_actual')::numeric=0 and (person->>'due_actual')::numeric=1950,'practical details and real unpaid amount, not nominal deposit_paid');
  begin
    perform booking.admin_add_to_order(oid,'[{"type":"custom","description":"Existing manual partial balance","amount":100,"vat_rate":25.5,"quantity":1}]',false,false,null);
    hit:=false;begin perform booking.admin_training_prepare_balance(r,oid);exception when sqlstate 'BK001' then hit:=true;end;
    raise sqlstate 'P9255' using message='rollback partial billing fixture';
  exception when sqlstate 'P9255' then null;end;
  perform pg_temp.ck(hit,'existing manual billing requires review instead of adding a duplicate nominal balance');
  x:=booking.admin_training_prepare_balance(r,oid);
  perform pg_temp.ck((select total_gross from booking.orders where id=oid)=1950,'saved final balance added using existing billing logic');
  perform booking.admin_training_prepare_balance(r,oid);
  perform pg_temp.ck((select total_gross from booking.orders where id=oid)=1950,'final balance preparation is idempotent');

  hit:=false;begin perform booking.admin_training_payment_link(r,oid,1950,'english255@example.test',false);exception when sqlstate 'BK001' then hit:=true;end;
  perform pg_temp.ck(hit,'payment link requires manual confirmation');
  hit:=false;begin perform booking.admin_training_payment_link(r,oid,1,'english255@example.test',true);exception when sqlstate 'BK001' then hit:=true;end;
  perform pg_temp.ck(hit,'payment link rejects changed preview amount');
  select count(*) into count_before from booking.email_outbox;
  select coalesce(jsonb_agg(to_jsonb(pay) order by pay.id),'[]') into payments_before from booking.payments pay where pay.order_id=oid;
  hit:=false;begin perform booking.admin_training_payment_links(r,jsonb_build_array(
    jsonb_build_object('order_id',oid,'amount',1950,'email','english255@example.test'),
    jsonb_build_object('order_id',oid,'amount',1,'email','english255@example.test')),true);
  exception when sqlstate 'BK001' then hit:=true;end;
  perform pg_temp.ck(hit and payments_before=(select coalesce(jsonb_agg(to_jsonb(pay) order by pay.id),'[]') from booking.payments pay where pay.order_id=oid) and (select count(*) from booking.email_outbox)=count_before,'batch error rolls back all payment links and email queue entries');
  x:=booking.admin_training_payment_links(r,jsonb_build_array(jsonb_build_object('order_id',oid,'amount',1950,'email','english255@example.test')),true)->'payments'->0;
  perform pg_temp.ck(exists(select 1 from booking.payments where id=(x->>'payment_id')::bigint and reminders_paused_at is not null),'manual payment link pauses existing reminder automation');

  w1:=(booking.admin_training_waitlist_add(r,'{"name":"First waiting","email":"first255@example.test"}')->>'id')::bigint;
  w2:=(booking.admin_training_waitlist_add(r,'{"name":"Second waiting","email":"second255@example.test"}')->>'id')::bigint;
  hit:=false;begin perform booking.admin_training_waitlist_update(r,w2,'offered');exception when sqlstate 'BK001' then hit:=true;end;
  perform pg_temp.ck(hit,'FIFO: second waiter cannot be offered first');
  select count(*) into count_before from booking.email_outbox;
  perform booking.admin_training_waitlist_update(r,w1,'offered');
  perform pg_temp.ck((select count(*) from booking.email_outbox)=count_before,'manual waitlist offer does not send email');
  hit:=false;begin perform booking.admin_training_waitlist_update(r,w2,'offered');exception when sqlstate 'BK001' then hit:=true;end;
  perform pg_temp.ck(hit,'open first offer prevents offering next waiter');

  body:='{"fi":{"subject":"Saapuminen","body":"Tervetuloa"},"en":{"subject":"Arrival","body":"Welcome"}}';
  select count(*) into count_before from booking.email_outbox;
  x:=booking.admin_training_message_preview(r,body);mid:=(x->>'id')::uuid;
  perform pg_temp.ck((select count(*) from booking.email_outbox)=count_before and x#>>'{recipients,0,language}'='en' and jsonb_array_length(x->'recipients')=1,'preview sends nothing and chooses participant language');
  hit:=false;begin perform booking.admin_training_message_send(mid,false);exception when sqlstate 'BK001' then hit:=true;end;
  perform pg_temp.ck(hit and (select count(*) from booking.email_outbox)=count_before,'send requires explicit confirmation');
  update kb.products set name='Changed after preview' where id=p;
  perform booking.admin_training_message_send(mid,true);
  perform pg_temp.ck(exists(select 1 from booking.email_outbox where dedupe_key like 'training_message:'||mid||':%' and payload->>'when_text'=x#>>'{content,_context,when_text}' and payload->>'event_name'='t255 Training'),'sent message uses the previewed dates and name snapshot');
  perform pg_temp.ck(exists(select 1 from booking.email_outbox where dedupe_key like 'training_message:'||mid||':%' and payload->>'body'='Welcome' and locale='en'),'existing event_message pipeline receives English body and locale');
  perform booking.admin_training_message_send(mid,true);
  perform pg_temp.ck((select count(*) from booking.email_outbox)=count_before+1,'retry same preview does not send twice');
  x:=booking.admin_training_message_preview(r,body);mid:=(x->>'id')::uuid;
  perform booking.admin_training_person_save(resid,'{"language":"fi"}');
  hit:=false;begin perform booking.admin_training_message_send(mid,true);exception when sqlstate 'BK001' then hit:=true;end;
  perform pg_temp.ck(hit,'changed recipient language invalidates server preview');

  perform booking.admin_training_work_save(r,true,jsonb_build_object('arrival',body));
  x:=booking.admin_training_session_copy(r,d+365,'Training 2028');copied:=(x->>'rule_id')::bigint;
  perform pg_temp.ck(not exists(select 1 from booking.reservations where rule_id=copied),'copy never includes participants');
  perform pg_temp.ck(not (select active from kb.products where id=(x->>'product_id')::bigint),'copy stays unpublished');
  perform pg_temp.ck(exists(select 1 from booking.space_blocks b join booking.event_resource_blocks eb on eb.id=b.event_block_id where eb.rule_id=copied and (b.starts_at at time zone 'Europe/Helsinki')::date=d+365) and exists(select 1 from booking.training_segments where option_rule_id=copied),'copy carries spaces and remapped segments');
  perform pg_temp.ck(exists(select 1 from booking.training_session_work where rule_id=copied and templates->'arrival'=body and not materials_shared),'copy carries templates but resets readiness');
  perform pg_temp.ck(not exists(select 1 from booking.training_waitlist where rule_id=copied) and not exists(select 1 from booking.event_messages where rule_id=copied),'copy leaves waitlist and message history empty');
  perform pg_temp.ck(hash_before=md5(pg_get_functiondef('booking._training_option_seats_left(bigint)'::regprocedure)),'existing capacity function unchanged');

  perform pg_temp.ck((booking.admin_training_work_get(segment)#>>'{rule,training_segment_only}')::boolean and exists(select 1 from jsonb_array_elements(booking.admin_training_work_list()) j where (j->>'rule_id')::bigint=r and (j->>'seats_remaining')::int=booking._training_option_seats_left(r) and (j->>'session_ends_at')::timestamptz=upper(booking._training_rule_range(segment)) and j->'segment_ids' @> jsonb_build_array(segment)),'workspace exposes hidden-segment flag and current shared availability');
  cap_before:=booking._training_option_seats_left(r);
  perform booking.admin_training_person_add(segment,'{"name":"Retreat only","email":"retreat255@example.test"}');
  perform pg_temp.ck(booking._training_option_seats_left(r)=cap_before-1,'standalone retreat signup reduces full-training shared capacity');
  for n in 1..4 loop perform booking.admin_training_person_add(r,jsonb_build_object('name','Full '||n,'email','full255-'||n||'@example.test'));end loop;
  hit:=false;begin perform booking.admin_training_person_add(r,'{"name":"Too many","email":"overflow255@example.test"}');exception when sqlstate 'BK001' then hit:=true;end;
  perform pg_temp.ck(hit and booking._training_option_seats_left(segment)=0,'full-training cannot overbook a shared retreat');
  perform pg_temp.ck(booking._training_option_seats_left(copied)=6,'copied cohort has independent empty capacity');

  -- Access controls: anonymous cannot call, authenticated non-staff cannot read or write.
  perform pg_temp.ck(not has_function_privilege('anon','booking.admin_training_work_get(bigint)','execute'),'anonymous execute revoked');
  perform pg_temp.ck(not has_table_privilege('authenticated','booking.training_participant_details','select'),'no direct participant detail access');
  perform pg_temp.ck((select relrowsecurity from pg_class pc where pc.oid='booking.training_participant_details'::regclass),'participant detail RLS enabled');
  perform test.logout();
  u:=test.mk_user('nonstaff255@example.test');perform test.login(u);reset role;
  hit:=false;begin perform booking.admin_training_work_get(r);exception when sqlstate 'BK001' then hit:=true;end;
  perform pg_temp.ck(hit,'signed-in non-staff cannot read course workspace');
  perform test.logout();
end $test$;
rollback;
