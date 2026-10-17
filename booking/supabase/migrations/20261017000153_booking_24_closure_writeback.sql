-- ===================================================================================================================
-- booking_24_closure_writeback: hallinnan sulut -> Google-sulkukalenteri (jono / outbox). Additiivinen.
--  * hallinnassa tehty sulku (space_blocks ILMAN closure_event_id) resurssille jolla on aktiivinen sulkukalenteri -> jonoon upsert/delete
--  * kalenterista tuodut sulut (closure_event_id IS NOT NULL) EIVÄT koskaan päädy jonoon (silmukkaesto 1: trigger rajaa)
--  * kalenteriin kirjoitettu tapahtuma saa extendedProperties.private.booking_source=admin + otsikon alkuun [HALLINTA]:
--    lukusynkka ohittaa omansa (silmukkaesto 2: edge-funktio) ja ignore-sääntö [HALLINTA] estää tuplatuonnin vaikka tunniste puuttuisi (3)
--  * tapahtuman id on deterministinen (bkadm + sulun id) -> kirjoitus on idempotentti (409 -> patch)
--  * edge-funktio: closure_outbox_claim -> Google insert/patch/delete -> closure_outbox_complete / closure_outbox_fail
-- ===================================================================================================================
set local search_path = booking, extensions, public;

create table if not exists booking.closure_exports (
  block_id      bigint primary key,
  calendar_code text not null references booking.closure_calendars(code),
  event_id      text not null,
  state_hash    text not null,
  synced_at     timestamptz not null default now()
);
create table if not exists booking.closure_outbox (
  id              bigint generated always as identity primary key,
  block_id        bigint not null,
  calendar_code   text not null references booking.closure_calendars(code),
  op              text not null check (op in ('upsert', 'delete')),
  event_id        text not null,
  status          text not null default 'pending' check (status in ('pending', 'processing', 'done', 'blocked', 'error', 'skipped')),
  attempts        integer not null default 0,
  last_error      text,
  result          text,
  next_attempt_at timestamptz not null default now(),
  locked_at       timestamptz,
  created_at      timestamptz not null default now(),
  processed_at    timestamptz
);
create index if not exists closure_outbox_work_idx on booking.closure_outbox (status, next_attempt_at) where status in ('pending', 'processing', 'blocked');
create index if not exists closure_outbox_block_idx on booking.closure_outbox (block_id);
create index if not exists closure_exports_cal_idx on booking.closure_exports (calendar_code);

alter table booking.closure_exports enable row level security;
alter table booking.closure_outbox  enable row level security;
do $$ begin
  if not exists (select 1 from pg_policy where polrelid = 'booking.closure_outbox'::regclass and polname = 'staff_read') then
    create policy staff_read on booking.closure_outbox for select to authenticated using ((select booking.is_staff()));
  end if;
  if not exists (select 1 from pg_policy where polrelid = 'booking.closure_exports'::regclass and polname = 'staff_read') then
    create policy staff_read on booking.closure_exports for select to authenticated using ((select booking.is_staff()));
  end if;
end $$;
revoke all on booking.closure_outbox, booking.closure_exports from public, anon, authenticated;
grant select on booking.closure_outbox, booking.closure_exports to authenticated;
grant all on booking.closure_outbox, booking.closure_exports to service_role;

-- ---------- silmukkaesto 3: ignore-sääntö omille tapahtumille ----------
insert into booking.closure_event_rules(sort_order, match_type, pattern, action, class, note)
select 11, 'prefix', '[HALLINTA]', 'ignore', 'mirror', 'Hallinnasta kalenteriin kirjoitettu sulku – ei tuoda takaisin (booking_24)'
 where not exists (select 1 from booking.closure_event_rules where calendar_code is null and match_type = 'prefix' and pattern = '[HALLINTA]');

-- ---------- apufunktiot ----------
create or replace function booking._closure_event_id(p_block bigint) returns text
  language sql immutable set search_path to '' as $$ select 'bkadm' || lpad(p_block::text, 10, '0') $$;   -- base32hex-merkit (0-9) -> kelpaa Google-tapahtuman id:ksi

create or replace function booking._closure_calendar_for(p_space bigint) returns text
  language sql stable set search_path to '' as $$
  select c.code from booking.closure_calendars c where c.resource_id = p_space and c.active and c.google_calendar_id is not null order by c.sort_order limit 1 $$;

create or replace function booking._closure_block_hash(p_block bigint) returns text
  language sql stable set search_path to '' as $$
  select md5(concat_ws('|', b.space_id, b.starts_at, b.ends_at, coalesce(b.reason, ''), b.active)) from booking.space_blocks b where b.id = p_block $$;

-- ---------- trigger: hallinnan sulku -> jono ----------
create or replace function booking.closure_blocks_outbox_trg() returns trigger
  language plpgsql security definer set search_path to '' as $function$
declare
  v_exp booking.closure_exports;
  v_cal text;
begin
  -- silmukkaesto 1: kalenterista tuodut (hallitut) sulut eivät koskaan mene takaisin kalenteriin
  if tg_op = 'INSERT' and new.closure_event_id is not null then return new; end if;
  if tg_op in ('UPDATE', 'DELETE') and (old.closure_event_id is not null or (tg_op = 'UPDATE' and new.closure_event_id is not null)) then return coalesce(new, old); end if;

  if tg_op = 'DELETE' then
    select * into v_exp from booking.closure_exports where block_id = old.id;
    if found then
      insert into booking.closure_outbox(block_id, calendar_code, op, event_id) values (old.id, v_exp.calendar_code, 'delete', v_exp.event_id);
    end if;
    return old;
  end if;

  v_cal := case when new.active then booking._closure_calendar_for(new.space_id) end;
  if tg_op = 'INSERT' then
    if v_cal is not null then
      insert into booking.closure_outbox(block_id, calendar_code, op, event_id) values (new.id, v_cal, 'upsert', booking._closure_event_id(new.id));
    end if;
    return new;
  end if;

  -- UPDATE
  select * into v_exp from booking.closure_exports where block_id = new.id;
  if found and (v_cal is null or v_cal <> v_exp.calendar_code) then
    insert into booking.closure_outbox(block_id, calendar_code, op, event_id) values (new.id, v_exp.calendar_code, 'delete', v_exp.event_id);
  end if;
  if v_cal is not null and (old.space_id, old.starts_at, old.ends_at, old.reason, old.active) is distinct from (new.space_id, new.starts_at, new.ends_at, new.reason, new.active) then
    insert into booking.closure_outbox(block_id, calendar_code, op, event_id) values (new.id, v_cal, 'upsert', booking._closure_event_id(new.id));
  end if;
  return new;
end $function$;
drop trigger if exists space_blocks_zz_outbox on booking.space_blocks;
create trigger space_blocks_zz_outbox after insert or update or delete on booking.space_blocks
  for each row execute function booking.closure_blocks_outbox_trg();

-- ---------- edge-funktion rajapinta (service_role) ----------
create or replace function booking.closure_outbox_claim(p_limit integer default 25) returns jsonb
  language plpgsql security definer set search_path to '' as $function$
declare
  r booking.closure_outbox;
  b booking.space_blocks;
  c booking.closure_calendars;
  e booking.closure_exports;
  v_out jsonb := '[]'::jsonb;
  v_ids bigint[];
begin
  if booking._jwt_role() is distinct from 'service_role' and current_user not in ('postgres', 'service_role') then
    perform booking._err('forbidden', 'Vain service_role');
  end if;
  delete from booking.closure_outbox where status in ('done', 'skipped') and processed_at < now() - interval '30 days';
  select coalesce(array_agg(id order by id), '{}') into v_ids from (
    select o.id from booking.closure_outbox o
     where (o.status in ('pending', 'blocked') and o.next_attempt_at <= now()) or (o.status = 'processing' and o.locked_at < now() - interval '10 minutes')
     order by o.id limit greatest(1, least(coalesce(p_limit, 25), 100)) for update skip locked) q;
  for r in select * from booking.closure_outbox where id = any (v_ids) order by id loop
    update booking.closure_outbox set status = 'processing', attempts = attempts + 1, locked_at = now() where id = r.id;
    select * into c from booking.closure_calendars where code = r.calendar_code;
    select * into e from booking.closure_exports where block_id = r.block_id and calendar_code = r.calendar_code;
    select * into b from booking.space_blocks where id = r.block_id;
    if r.op = 'upsert' then
      if not found or not b.active or b.closure_event_id is not null or booking._closure_calendar_for(b.space_id) is distinct from r.calendar_code then
        -- lähde poistunut/muuttunut: jos aiemmin viety -> poisto, muuten ohita
        if e.block_id is not null then
          v_out := v_out || jsonb_build_object('id', r.id, 'op', 'delete', 'calendar_code', r.calendar_code, 'google_calendar_id', c.google_calendar_id, 'timezone', c.timezone, 'event_id', r.event_id, 'block_id', r.block_id);
        else
          update booking.closure_outbox set status = 'skipped', result = 'source_gone', processed_at = now(), locked_at = null where id = r.id;
        end if;
      elsif e.block_id is not null and e.state_hash = booking._closure_block_hash(r.block_id) then
        update booking.closure_outbox set status = 'skipped', result = 'unchanged', processed_at = now(), locked_at = null where id = r.id;   -- jo kalenterissa samassa tilassa
      else
        v_out := v_out || jsonb_build_object('id', r.id, 'op', 'upsert', 'calendar_code', r.calendar_code, 'google_calendar_id', c.google_calendar_id, 'timezone', c.timezone, 'event_id', r.event_id,
                   'block_id', r.block_id, 'starts_at', b.starts_at, 'ends_at', b.ends_at, 'reason', b.reason);
      end if;
    else
      if e.block_id is null then
        update booking.closure_outbox set status = 'skipped', result = 'not_exported', processed_at = now(), locked_at = null where id = r.id;
      else
        v_out := v_out || jsonb_build_object('id', r.id, 'op', 'delete', 'calendar_code', r.calendar_code, 'google_calendar_id', c.google_calendar_id, 'timezone', c.timezone, 'event_id', r.event_id, 'block_id', r.block_id);
      end if;
    end if;
  end loop;
  return v_out;
end $function$;

create or replace function booking.closure_outbox_complete(p_id bigint, p_result text default 'ok') returns void
  language plpgsql security definer set search_path to '' as $function$
declare
  r booking.closure_outbox;
  v_op text;
begin
  if booking._jwt_role() is distinct from 'service_role' and current_user not in ('postgres', 'service_role') then
    perform booking._err('forbidden', 'Vain service_role');
  end if;
  select * into r from booking.closure_outbox where id = p_id for update;
  if not found then return; end if;
  v_op := case when p_result in ('deleted', 'gone') then 'delete' else r.op end;
  if v_op = 'delete' then
    delete from booking.closure_exports where block_id = r.block_id and calendar_code = r.calendar_code;
  else
    insert into booking.closure_exports(block_id, calendar_code, event_id, state_hash)
    values (r.block_id, r.calendar_code, r.event_id, coalesce(booking._closure_block_hash(r.block_id), ''))
    on conflict (block_id) do update set calendar_code = excluded.calendar_code, event_id = excluded.event_id, state_hash = excluded.state_hash, synced_at = now();
  end if;
  update booking.closure_outbox set status = 'done', result = left(p_result, 40), last_error = null, processed_at = now(), locked_at = null where id = p_id;
end $function$;

create or replace function booking.closure_outbox_fail(p_id bigint, p_error text, p_blocked boolean default false) returns void
  language plpgsql security definer set search_path to '' as $function$
declare r booking.closure_outbox;
begin
  if booking._jwt_role() is distinct from 'service_role' and current_user not in ('postgres', 'service_role') then
    perform booking._err('forbidden', 'Vain service_role');
  end if;
  select * into r from booking.closure_outbox where id = p_id for update;
  if not found then return; end if;
  if p_blocked then
    -- ei kirjoitusoikeutta: yritetään tunnin välein (alkaa toimia kun jako korjataan)
    update booking.closure_outbox set status = 'blocked', last_error = left(p_error, 200), next_attempt_at = now() + interval '1 hour', locked_at = null where id = p_id;
  elsif r.attempts >= 8 then
    update booking.closure_outbox set status = 'error', last_error = left(p_error, 200), locked_at = null, processed_at = now() where id = p_id;
  else
    update booking.closure_outbox set status = 'pending', last_error = left(p_error, 200), locked_at = null,
           next_attempt_at = now() + make_interval(mins => least(360, 5 * r.attempts * r.attempts)) where id = p_id;
  end if;
end $function$;

-- manuaalinen taustatäyttö (EI ajeta automaattisesti): vie tulevat hallintasulut joita ei ole viety
create or replace function booking.closure_outbox_backfill() returns integer
  language plpgsql security definer set search_path to '' as $function$
declare v_n integer;
begin
  if booking._jwt_role() is distinct from 'service_role' and current_user not in ('postgres', 'service_role') then
    perform booking._err('forbidden', 'Vain service_role');
  end if;
  with ins as (
    insert into booking.closure_outbox(block_id, calendar_code, op, event_id)
    select b.id, booking._closure_calendar_for(b.space_id), 'upsert', booking._closure_event_id(b.id)
      from booking.space_blocks b
     where b.active and b.closure_event_id is null and b.ends_at > now() and booking._closure_calendar_for(b.space_id) is not null
       and not exists (select 1 from booking.closure_exports x where x.block_id = b.id)
       and not exists (select 1 from booking.closure_outbox o where o.block_id = b.id and o.status in ('pending', 'processing', 'blocked'))
    returning 1) select count(*) into v_n from ins;
  return v_n;
end $function$;

-- ---------- hallinnan näkymä ----------
create or replace function booking.admin_closure_outbox_status() returns jsonb
  language plpgsql stable security definer set search_path to '' as $function$
begin
  perform booking._require_permission('blocks.manage');
  return jsonb_build_object(
    'by_status', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from booking.closure_outbox group by 1) q), '{}'::jsonb),
    'exported_blocks', (select count(*) from booking.closure_exports),
    'problems', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'block_id', block_id, 'calendar', calendar_code, 'op', op, 'status', status, 'attempts', attempts, 'error', last_error, 'next_attempt_at', next_attempt_at) order by id)
                            from booking.closure_outbox where status in ('blocked', 'error') or (status = 'pending' and attempts > 0)), '[]'::jsonb));
end $function$;

create or replace function booking.admin_closure_outbox_retry() returns integer
  language plpgsql security definer set search_path to '' as $function$
declare v_n integer;
begin
  perform booking._require_permission('blocks.manage');
  with u as (update booking.closure_outbox set status = 'pending', attempts = 0, next_attempt_at = now(), last_error = null where status in ('blocked', 'error') returning 1)
  select count(*) into v_n from u;
  return v_n;
end $function$;

-- ---------- oikeudet ----------
revoke all on function booking._closure_event_id(bigint), booking._closure_calendar_for(bigint), booking._closure_block_hash(bigint), booking.closure_blocks_outbox_trg(),
  booking.closure_outbox_claim(integer), booking.closure_outbox_complete(bigint, text), booking.closure_outbox_fail(bigint, text, boolean), booking.closure_outbox_backfill(),
  booking.admin_closure_outbox_status(), booking.admin_closure_outbox_retry() from public, anon, authenticated;
grant execute on function booking._closure_event_id(bigint), booking._closure_calendar_for(bigint), booking._closure_block_hash(bigint),
  booking.closure_outbox_claim(integer), booking.closure_outbox_complete(bigint, text), booking.closure_outbox_fail(bigint, text, boolean), booking.closure_outbox_backfill() to service_role;
grant execute on function booking.admin_closure_outbox_status(), booking.admin_closure_outbox_retry() to authenticated, service_role;
