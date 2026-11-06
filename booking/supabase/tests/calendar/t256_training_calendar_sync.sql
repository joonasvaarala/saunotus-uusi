-- Local Postgres only, after booking_255 + booking_256 and fixtures/10_test_helpers.sql.
-- No Google calls or committed test data, no public schema changes.
\set ON_ERROR_STOP on
begin;
set local statement_timeout='60s';
create function pg_temp.ck(ok boolean,label text) returns void language plpgsql as $$ begin
  if ok is not true then raise exception 'FAIL: %',label; end if;
  raise notice 'PASS: %',label;
end $$;
do $test$
declare
  u uuid := test.mk_staff('training256@example.test','manager');
  p bigint; r bigint; other_rule bigint; sauna bigint; rauni bigint; lovi bigint; bid bigint; rid bigint; lid bigint;
  d date := (now() at time zone 'Europe/Helsinki')::date + 300;
  ev jsonb; remote jsonb; x jsonb; before_n int; outbox_n int; sbid bigint; conflict_id bigint; hit boolean;
  runid text := 'training256-test';
begin
  perform test.login(u); reset role;
  p := (booking.admin_product_create('{"name":"Training 256","category":"training","price":20,"vat_rate":25.5,"active":true}')->>'id')::bigint;
  perform booking.admin_update_product_config(p,'{"bookable":true}');
  r := (booking.admin_event_rule_upsert(null,p,jsonb_build_object('date',d,'start_time','10:00','duration_minutes',4320,'max_persons',6))->>'id')::bigint;
  select id into sauna from booking.resources where code='savusauna';
  select id into rauni from booking.resources where code='rauni';
  select id into lovi from booking.resources where code='lovi';
  bid := (booking.admin_training_space_add(r,sauna,d,'16:00','19:00')->>'id')::bigint;
  -- Multiday and relative blocks use the same _event_block_range.
  insert into booking.event_resource_blocks(rule_id,resource_id,mode,start_day,start_clock,end_day,end_clock)
    values(r,rauni,'exclusive',1,'08:00',2,'09:00') returning id into rid;
  insert into booking.event_resource_blocks(rule_id,resource_id,mode,offset_min,minutes)
    values(r,lovi,'exclusive',0,60) returning id into lid;
  select id into sbid from booking.space_blocks where event_block_id=bid;
  select count(*) into outbox_n from booking.closure_outbox;
  update booking.integration_config set mode='live',settings=settings || '{"window_forward_days":180,"resource_calendars":{"savusauna":"savu256-calendar","rauni":"rauni256-calendar","lovi":"lovi256-calendar"}}' where key='booking_calendar';
  x := booking._booking_calendar_desired();
  select value into ev from jsonb_array_elements(x->'events') where value->>'event_key'='e:block:'||bid;
  perform pg_temp.ck(ev is not null and (ev->>'starts_at')::timestamptz=((d+'16:00'::time) at time zone 'Europe/Helsinki') and (ev->>'ends_at')::timestamptz=((d+'19:00'::time) at time zone 'Europe/Helsinki'),'exact block hours, not whole course; beyond 180 days');
  perform pg_temp.ck(ev->>'google_calendar_id'='savu256-calendar' and ev->>'summary' like '%Savusauna%' and ev->>'kind'='event','own sauna calendar + room in title');
  perform pg_temp.ck(exists(select 1 from jsonb_array_elements(x->'events') a where a->>'event_key'='e:block:'||rid and a->>'google_calendar_id'='rauni256-calendar' and (a->>'ends_at')::timestamptz=((d+2+'09:00'::time) at time zone 'Europe/Helsinki')),'Rauni own calendar, overnight end');
  perform pg_temp.ck(exists(select 1 from jsonb_array_elements(x->'events') a where a->>'event_key'='e:block:'||lid and a->>'google_calendar_id'='lovi256-calendar' and (a->>'ends_at')::timestamptz=((d+'11:00'::time) at time zone 'Europe/Helsinki')),'Lovi own calendar, relative range');
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  update booking.integration_config set mode='dry_run' where key='booking_calendar';
  x := booking.booking_calendar_export_plan();
  perform pg_temp.ck(not exists(select 1 from jsonb_array_elements(x->'events') a where a->>'event_key' like 'e:block:%'),'old Edge plan does not export training before deployment');
  x := booking.booking_calendar_training_export_plan();
  perform pg_temp.ck(exists(select 1 from jsonb_array_elements(x->'events') a where a->>'event_key'='e:block:'||bid),'new Edge plan includes training, same export infrastructure');
  perform pg_temp.ck(coalesce(current_setting('booking.training_calendar_sync',true),'')<>'on','capability flag does not leak');
  update booking.integration_config set mode='live' where key='booking_calendar';
  update booking.booking_calendar_state set locked_by=runid,locked_at=now() where id=1;
  -- Same finish/mapping table, no parallel outbox or migration backfill.
  perform booking.booking_calendar_export_finish(jsonb_build_object('run_id','not-this-run','upserts',jsonb_build_array(ev),'deletes','[]'::jsonb));
  remote := ev || jsonb_build_object('status','confirmed','booking_source','booking_calendar','booking_key',ev->>'event_key','starts_at',((d+'17:00'::time) at time zone 'Europe/Helsinki'),'ends_at',((d+'20:00'::time) at time zone 'Europe/Helsinki'));
  x := booking.apply_training_calendar_events(runid,jsonb_build_array(remote));
  perform pg_temp.ck((x->>'changed')::int=1 and exists(select 1 from booking.space_blocks where id=sbid and starts_at=((d+'17:00'::time) at time zone 'Europe/Helsinki') and ends_at=((d+'20:00'::time) at time zone 'Europe/Helsinki')),'Google move updates block + same materialized space_block');
  perform pg_temp.ck((select start_clock='17:00' and end_clock='20:00' from booking.event_resource_blocks where id=bid),'Hallinta source clocks updated');
  perform pg_temp.ck((select count(*) from booking.closure_outbox)=outbox_n,'no closure-calendar echo');
  x := booking.apply_training_calendar_events(runid,jsonb_build_array(remote));
  perform pg_temp.ck((x->>'changed')::int=0,'retry after accepted inbound/failed outbound is idempotent');
  select value into ev from jsonb_array_elements(x->'events') where value->>'event_key'='e:block:'||bid;
  perform booking.booking_calendar_export_finish(jsonb_build_object('run_id','not-this-run','upserts',jsonb_build_array(ev),'deletes','[]'::jsonb));
  remote := remote || ev;
  update booking.integration_config set mode='dry_run' where key='booking_calendar';
  x := booking.booking_calendar_export_plan();
  perform pg_temp.ck(not exists(select 1 from jsonb_array_elements(x->'mapped') a where a->>'event_key'='e:block:'||bid),'old Edge cannot delete new mapped training events');
  hit:=false; begin perform booking.apply_training_calendar_events(runid,jsonb_build_array(remote)); exception when sqlstate 'BK001' then hit:=true; end;
  perform pg_temp.ck(hit,'dry-run cannot apply inbound');
  update booking.integration_config set mode='live' where key='booking_calendar';
  hit:=false; begin perform booking.apply_training_calendar_events(runid,jsonb_build_array(remote || '{"booking_key":"e:block:copied"}')); exception when sqlstate 'BK001' then hit:=true; end;
  perform pg_temp.ck(hit,'active event must retain export ownership metadata');

  -- New calendar-created events (even keys copied from another event) cannot create blocks.
  select count(*) into before_n from booking.event_resource_blocks;
  x := booking.apply_training_calendar_events(runid,jsonb_build_array(remote || '{"event_key":"e:block:999999999","google_event_id":"copied"}'));
  perform pg_temp.ck((x->>'ignored')::int=1 and (select count(*) from booking.event_resource_blocks)=before_n,'unmapped calendar event never creates/adopts a block');
  x := booking.apply_training_calendar_events(runid,jsonb_build_array(remote || '{"google_calendar_id":"wrong"}'));
  perform pg_temp.ck((x->>'ignored')::int=1,'mapping calendar must match');
  -- Manual closures cannot be overwritten by Google dragging a room booking onto them.
  insert into booking.space_blocks(space_id,starts_at,ends_at,reason) values(sauna,((d+'21:00'::time) at time zone 'Europe/Helsinki'),((d+'22:00'::time) at time zone 'Europe/Helsinki'),'manual256') returning id into conflict_id;
  hit:=false; begin
    perform booking.apply_training_calendar_events(runid,jsonb_build_array(remote || jsonb_build_object('starts_at',((d+'21:00'::time) at time zone 'Europe/Helsinki'),'ends_at',((d+'22:00'::time) at time zone 'Europe/Helsinki'))));
  exception when sqlstate 'BK001' then hit:=true; end;
  perform pg_temp.ck(hit and exists(select 1 from booking.space_blocks where id=conflict_id and active),'conflicting inbound rejected atomically, manual closure intact');
  perform test.login(u); reset role;
  other_rule := (booking.admin_event_rule_upsert(null,p,jsonb_build_object('date',d+1,'start_time','14:00','duration_minutes',120,'max_persons',6))->>'id')::bigint;
  update booking.schedule_rules set space_id=sauna where id=other_rule;
  perform booking.admin_create_booking(p_rule_id=>other_rule,p_date=>d+1,p_persons=>1,p_customer=>'{"name":"Other training","email":"other256@example.test"}'::jsonb);
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  hit:=false; begin
    perform booking.apply_training_calendar_events(runid,jsonb_build_array(remote || jsonb_build_object('starts_at',((d+1+'14:30'::time) at time zone 'Europe/Helsinki'),'ends_at',((d+1+'15:30'::time) at time zone 'Europe/Helsinki'))));
  exception when sqlstate 'BK001' then hit:=true; end;
  perform pg_temp.ck(hit,'inbound respects existing active physical bookings as well as manual closures');
  hit:=false; begin perform booking.apply_training_calendar_events('expired',jsonb_build_array(remote)); exception when sqlstate 'BK001' then hit:=true; end;
  perform pg_temp.ck(hit,'stale export lease rejected');
  perform pg_temp.ck(not has_function_privilege('anon','booking.apply_training_calendar_events(text,jsonb)','execute') and not has_function_privilege('authenticated','booking.apply_training_calendar_events(text,jsonb)','execute') and has_function_privilege('service_role','booking.apply_training_calendar_events(text,jsonb)','execute'),'service-role only');
  hit:=false; begin
    perform booking.apply_training_calendar_events(runid,jsonb_build_array(remote || jsonb_build_object('starts_at',((d+20+'17:00'::time) at time zone 'Europe/Helsinki'),'ends_at',((d+20+'20:00'::time) at time zone 'Europe/Helsinki'))));
  exception when sqlstate 'BK001' then hit:=true; end;
  perform pg_temp.ck(hit,'cannot detach block from its course day-offset bounds');
  -- Hallinta time changes win over a stale remote time observation.
  update booking.event_resource_blocks set start_clock='18:00' where id=bid;
  x := booking.apply_training_calendar_events(runid,jsonb_build_array(remote));
  perform pg_temp.ck((x->>'ignored')::int=1 and (select start_clock='18:00' from booking.event_resource_blocks where id=bid),'concurrent Hallinta time edit wins');
  -- Explicit deletion wins and frees only this room, without cancelling the course.
  x := booking.apply_training_calendar_events(runid,jsonb_build_array(remote || '{"status":"cancelled"}'));
  perform pg_temp.ck((x->>'deleted')::int=1 and not exists(select 1 from booking.event_resource_blocks where id=bid) and not exists(select 1 from booking.space_blocks where event_block_id=bid),'Google deletion releases room in both tables');
  perform pg_temp.ck((select active from booking.schedule_rules where id=r) and exists(select 1 from booking.space_blocks where event_block_id=rid) and exists(select 1 from booking.space_blocks where id=conflict_id),'course, other room and manual closure remain');
  x := booking.apply_training_calendar_events(runid,jsonb_build_array(remote || '{"status":"cancelled"}'));
  perform pg_temp.ck((x->>'deleted')::int=0,'duplicate deletion is idempotent');
  update booking.integration_config set settings=jsonb_set(settings,'{resource_calendars}','{"rauni":"same256-calendar","lovi":"same256-calendar"}') where key='booking_calendar';
  x := booking._booking_calendar_desired();
  perform pg_temp.ck(exists(select 1 from jsonb_array_elements(x->'events') a where a->>'event_key'='e:block:'||rid and a->>'google_calendar_id' is null),'no shared/fallback calendar for training rooms');
end $test$;
rollback;
