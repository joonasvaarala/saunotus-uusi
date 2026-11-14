-- booking_290: Rauni kiinni -kalenterin jokainen merkintä sulkee Raunin (Joonas 13.11.2026 t1705u)
alter table booking.closure_calendars add column if not exists close_all boolean not null default false;
comment on column booking.closure_calendars.close_all is 'true = kalenterin jokainen merkintä sulkee resurssin (myös Koulutus/merkinnät ja yli 36 h ajastetut); vain [AUTO-JOHKU]/[HALLINTA]-peilit ohitetaan';
update booking.closure_calendars set close_all = true, updated_at = now() where code = 'rauni';

insert into booking.closure_event_rules(calendar_code, sort_order, match_type, pattern, action, class, extra_resource_code, note, active)
select 'rauni', 15, 'regex', '.*', 'block', 'closure', null, 'Rauni kiinni: jokainen merkintä sulkee Raunin, myös Koulutus (Joonas 13.11.2026)', true
where not exists (select 1 from booking.closure_event_rules where calendar_code = 'rauni' and sort_order = 15 and pattern = '.*');

create or replace view booking.v_closure_wanted_blocks as
 SELECT ev.id AS closure_event_id, ev.calendar_code, cal.resource_id AS space_id, ev.starts_at, ev.ends_at,
    "left"((('Kalenteri ('::text || cal.name) || '): '::text) || COALESCE(NULLIF(ev.reason, ''::text), '(ei otsikkoa)'::text), 300) AS reason
   FROM booking.closure_events ev JOIN booking.closure_calendars cal ON cal.code = ev.calendar_code
  WHERE ev.status = 'active' AND (ev.override = 'block' OR (ev.override IS NULL AND (ev.class = 'closure' OR (ev.class = 'rough' AND cal.close_all))))
UNION ALL
 SELECT ev.id, ev.calendar_code, ev.extra_resource_id, ev.starts_at, ev.ends_at,
    "left"((((('Kalenteri ('::text || cal.name) || '): '::text) || COALESCE(NULLIF(ev.reason, ''::text), '(ei otsikkoa)'::text)) || ' ['::text || xr.code) || ']'::text, 300)
   FROM booking.closure_events ev JOIN booking.closure_calendars cal ON cal.code = ev.calendar_code JOIN booking.resources xr ON xr.id = ev.extra_resource_id
  WHERE ev.status = 'active' AND ev.extra_resource_id IS NOT NULL AND (ev.override = 'block' OR (ev.override IS NULL AND (ev.class = 'closure' OR (ev.class = 'rough' AND cal.close_all))));
