-- booking_158: tapahtumat ja koulutukset (tietokantaosa).
-- Versio 20261024300000 on väliaikainen; Bottiavustus vaihtaa sen tuotannon migraatioversioksi ajon yhteydessä.
-- Uudelleenajettava: toinen ajo ei muuta mitään (if not exists / create or replace / on conflict do nothing / idempotentit päivitykset).
-- Joonaksen päätökset 24.10.2026 (sitovat): kerrat ovat erillisiä alkuaikoja (ei toistuvuutta), monipäiväinen yksi lippu vain koulutuksille,
-- tapahtuma voi varata yhden tai useamman resurssin (tila tai saunottaja), hoitojen varauslogiikkaa ei muuteta, myynti omaan kauppaan 1.11.2026
-- -> ominaisuus valmiiksi, myynti pois päältä (events.sale_enabled = false).
--
-- Muutokset:
--  1) booking.schedule_rules.kind ('regular' | 'event'). Tapahtumakerta = kind 'event', valid_from = valid_to = päivä, weekdays = päivän ISO-viikonpäivä,
--     mode 'shared', tila 'ei_resurssia' (lipun paikka), oma kapasiteettipooli resources.code = 'event_rule_<id>' (kapasiteetti = kerran max_persons).
--  2) Uusi taulu booking.event_resource_blocks: kerran resurssivaraukset. Ajoitus joko suhteellinen (offset_min + minutes kerran alusta)
--     tai kellonaika (start_day + start_clock .. end_day + end_clock, päivä suhteessa kerran päivään, Helsingin aikaa).
--     Tilan (kind space) exclusive-blokit materialisoidaan heti booking.space_blocks-riveiksi (space_blocks.event_block_id), myös ilman lippuja.
--     Henkilöresurssien (saunottaja) ja shared-tilan blokit tallennetaan, mutta niitä ei materialisoida eikä _therapist_slack muutu (päätös 3).
--  3) Oma lippu ohittaa oman tapahtumakerran blokit: _sessions, _check_claim ja _block_conflict_pairs (booking._event_block_is_own).
--     Tapahtumablokit eivät mene sulkukalenteriin (closure_blocks_outbox_trg, closure_outbox_backfill) ja niitä voi muuttaa vain tapahtumien
--     hallinnasta (space_blocks_managed_guard, virhe event_managed).
--  4) booking.product_config.channels text[] (null = oletus kategoriasta: training -> {widget}, muut -> {shop}). public_catalog,
--     public_availability ja public_availability_all näyttävät vain shop-kanavan tuotteet; koulutukset eivät näy kaupassa, mutta niiden blokit varaavat.
--  5) Myyntikytkin booking.settings 'events.sale_enabled' = false. Kun false: kind 'event' -kerrat eivät näy julkisessa saatavuudessa,
--     _resolve_session hylkää asiakkaan varauksen (sale_closed; henkilökunta voi), public_catalog piilottaa event/training-tuotteet,
--     public_events palauttaa kerrat tilassa 'closed'. Tuotteiden bookable-arvoja ei muuteta.
--  6) Uudet RPC:t (security definer, search_path ''): admin_event_list, admin_event_rule_upsert, admin_event_rule_delete, admin_event_blocks_set,
--     admin_event_set_channels, admin_product_copy, admin_event_copy, admin_event_rule_copy (catalog.edit; admin_event_list: henkilökunta luku),
--     public_events (anon). Virheet {code,message}; konfliktin tiedot (details) JSON-taulukkona virheen hint-kentässä.
--  7) Lovi-sääntö (product_space_rules): Loviin saa ohjautua vain yhden hengen saunahoito, saunotus ja syväsaunous (tuotteet 10, 11, 12, kun Rauni
--     on suljettu). Muiden tuotteiden aktiiviset Lovi-rivit passivoidaan (active = false); muutetut rivit tallennetaan booking.m158_lovi_rows (rollback).
-- Ei hintoja, ALV:tä, slugeja, URL:eja, maksuja eikä public-skeemaa. Ei sähköposteja.
-- Rollback: rollbacks/20261024300000_booking_158_ROLLBACK.sql
-- Tuotannon funktioiden md5(pg_get_functiondef) ennen tätä migraatiota (rollback palauttaa nämä täsmälleen):
--   booking._sessions: 872ef0fc6a9d38726ea2438f11ba3f01
--   booking._check_claim: bf875a55f4d73bfdcbaf107c29f09f45
--   booking._resolve_session: 132d5ce9356106af79cfa84658e76fd1
--   booking._block_conflict_pairs: cd2a64faf36994de5c99979816876f99
--   booking.space_blocks_managed_guard: 6b9f525403f3a69285b65921c1a79196
--   booking.closure_blocks_outbox_trg: 17ce83a9fbf50bebaffe2568438757ec
--   booking.closure_outbox_backfill: d6ddcaf1e152d74b8093d158e3394209
--   booking.public_catalog: b869be5d3444cc3d6923153efc336120
--   booking.public_availability: 503709f45fe0e98b9d4701c95297312f
--   booking.public_availability_all: eeb7cf54b957b2d29b9ea2fcc4f2a409
set local lock_timeout = '5s';

-- ---------- 1) skeema ----------
alter table booking.schedule_rules add column if not exists kind text not null default 'regular';
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid = 'booking.schedule_rules'::regclass and conname = 'schedule_rules_kind_check') then
    alter table booking.schedule_rules add constraint schedule_rules_kind_check check (kind in ('regular', 'event'));
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'booking.schedule_rules'::regclass and conname = 'schedule_rules_event_shape') then
    alter table booking.schedule_rules add constraint schedule_rules_event_shape check (
      kind <> 'event' or (valid_from is not null and valid_to = valid_from and weekdays = array[extract(isodow from valid_from)::smallint]));
  end if;
end $$;
create index if not exists schedule_rules_event_idx on booking.schedule_rules (product_id, valid_from) where kind = 'event';
comment on column booking.schedule_rules.kind is 'booking_158: regular = toistuva vuoro, event = yksittäinen tapahtumakerta (valid_from = valid_to = päivä)';

create table if not exists booking.event_resource_blocks (
  id bigint generated always as identity primary key,
  rule_id bigint not null references booking.schedule_rules(id) on delete cascade,
  resource_id bigint not null references booking.resources(id),
  mode text not null default 'exclusive' check (mode in ('exclusive', 'shared')),
  offset_min integer check (offset_min is null or offset_min between -1440 and 20160),
  minutes integer check (minutes is null or minutes between 1 and 20160),
  start_day smallint check (start_day is null or start_day between -1 and 14),
  start_clock time,
  end_day smallint check (end_day is null or end_day between -1 and 14),
  end_clock time,
  note text check (note is null or char_length(note) <= 500),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint event_resource_blocks_timing check (
    (offset_min is not null and minutes is not null and start_day is null and start_clock is null and end_day is null and end_clock is null)
    or (offset_min is null and minutes is null and start_day is not null and start_clock is not null and end_day is not null and end_clock is not null
        and (end_day > start_day or (end_day = start_day and end_clock > start_clock))))
);
create index if not exists event_resource_blocks_rule_idx on booking.event_resource_blocks (rule_id);
create index if not exists event_resource_blocks_resource_idx on booking.event_resource_blocks (resource_id);
alter table booking.event_resource_blocks enable row level security;
revoke all on booking.event_resource_blocks from public, anon, authenticated;
grant select on booking.event_resource_blocks to authenticated;
grant all on booking.event_resource_blocks to service_role;
drop policy if exists staff_read on booking.event_resource_blocks;
create policy staff_read on booking.event_resource_blocks for select to authenticated using ((select booking.is_staff()));
drop trigger if exists audit_trg on booking.event_resource_blocks;
create trigger audit_trg after insert or update or delete on booking.event_resource_blocks for each row execute function booking.audit_trg();
drop trigger if exists event_resource_blocks_updated on booking.event_resource_blocks;
create trigger event_resource_blocks_updated before update on booking.event_resource_blocks for each row execute function booking.set_updated_at();
comment on table booking.event_resource_blocks is 'booking_158: tapahtumakerran resurssivaraukset. offset_min+minutes (suhteessa kerran alkuun) TAI start_day/start_clock..end_day/end_clock (päivä suhteessa kerran päivään, Helsingin aikaa). Tilan exclusive-blokit materialisoidaan space_blocks-riveiksi.';

alter table booking.space_blocks add column if not exists event_block_id bigint references booking.event_resource_blocks(id) on delete cascade;
create unique index if not exists space_blocks_event_block_uq on booking.space_blocks (event_block_id) where event_block_id is not null;
comment on column booking.space_blocks.event_block_id is 'booking_158: tapahtuman resurssiblokista materialisoitu sulku (muutetaan vain booking._event_sync_blocks)';

alter table booking.product_config add column if not exists channels text[];
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid = 'booking.product_config'::regclass and conname = 'product_config_channels_check') then
    alter table booking.product_config add constraint product_config_channels_check check (channels is null or channels <@ array['shop', 'widget']::text[]);
  end if;
end $$;
comment on column booking.product_config.channels is 'booking_158: myyntikanavat (shop = oma verkkokauppa, widget = myöhempi upotus). null = oletus kategoriasta: training -> {widget}, muut -> {shop}';

insert into booking.settings(key, value, description, is_public)
values ('events.sale_enabled', 'false'::jsonb, 'booking_158: tapahtumien ja koulutusten myynti verkossa (false = kerrat näkyvät etusivulla suljettuina, varaus vain henkilökunnalle). Avataan 1.11.2026.', true)
on conflict (key) do nothing;

-- ---------- 2) apufunktiot ----------
create or replace function booking._events_sale_enabled() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((booking._setting('events.sale_enabled', 'false'::jsonb) #>> '{}')::boolean, false)
$$;

create or replace function booking._channels_effective(p_channels text[], p_category text) returns text[]
language sql immutable set search_path = '' as $$
  select coalesce(p_channels, case when p_category = 'training' then array['widget']::text[] else array['shop']::text[] end)
$$;

create or replace function booking._event_block_range(p_date date, p_start time, b booking.event_resource_blocks) returns tstzrange
language sql stable set search_path = '' as $$
  select case
    when b.offset_min is not null then
      tstzrange(((p_date + p_start) + make_interval(mins => b.offset_min)) at time zone booking._tz(),
                ((p_date + p_start) + make_interval(mins => b.offset_min + b.minutes)) at time zone booking._tz(), '[)')
    else
      tstzrange(((p_date + b.start_day) + b.start_clock) at time zone booking._tz(),
                ((p_date + b.end_day) + b.end_clock) at time zone booking._tz(), '[)')
  end
$$;

create or replace function booking._event_block_is_own(p_event_block_id bigint, p_res_id bigint, p_pools bigint[]) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_event_block_id is not null and exists (
    select 1 from booking.event_resource_blocks e
     where e.id = p_event_block_id
       and ((p_res_id is not null and exists (select 1 from booking.reservations r where r.id = p_res_id and r.rule_id = e.rule_id))
            or exists (select 1 from booking.resources pr where pr.code = 'event_rule_' || e.rule_id::text and pr.id = any (coalesce(p_pools, '{}'::bigint[])))))
$$;

create or replace function booking._event_block_json(b booking.event_resource_blocks) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', b.id, 'rule_id', b.rule_id, 'resource_id', b.resource_id, 'resource_name', res.name, 'resource_code', res.code, 'resource_kind', res.kind,
    'mode', b.mode, 'timing', case when b.offset_min is not null then 'relative' else 'clock' end,
    'offset_min', b.offset_min, 'minutes', b.minutes,
    'start_day', b.start_day, 'start_clock', to_char(b.start_clock, 'HH24:MI'), 'end_day', b.end_day, 'end_clock', to_char(b.end_clock, 'HH24:MI'),
    'starts_at', lower(x.rg), 'ends_at', upper(x.rg), 'note', b.note, 'sort_order', b.sort_order,
    'materialized', (b.mode = 'exclusive' and res.kind = 'space'))
  from booking.schedule_rules r
  join booking.resources res on res.id = b.resource_id
  cross join lateral (select booking._event_block_range(r.valid_from, r.start_time, b) as rg) x
  where r.id = b.rule_id
$$;

create or replace function booking._event_rule_json(p_rule_id bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', r.id, 'product_id', r.product_id, 'kind', r.kind, 'date', r.valid_from, 'start_time', to_char(r.start_time, 'HH24:MI'),
    'duration_minutes', r.duration_minutes,
    'starts_at', (r.valid_from + r.start_time) at time zone booking._tz(),
    'ends_at', ((r.valid_from + r.start_time) + make_interval(mins => r.duration_minutes)) at time zone booking._tz(),
    'max_persons', r.max_persons, 'min_persons', r.min_persons, 'deadline_minutes', r.deadline_minutes,
    'label', r.label, 'label_en', r.label_en, 'active', r.active, 'price_variant_id', r.price_variant_id, 'space_id', r.space_id,
    'pool_id', (select pr.id from booking.resources pr where pr.code = 'event_rule_' || r.id::text),
    'sold_persons', (select coalesce(sum(x.persons), 0)::int from booking.reservations x
                      where x.rule_id = r.id and booking._res_active(x.status, x.hold_expires_at)),
    'waitlist_count', (select count(*)::int from booking.waitlist_entries w where w.rule_id = r.id and w.status in ('waiting', 'notified')),
    'blocks', coalesce((select jsonb_agg(booking._event_block_json(b) order by b.sort_order, b.id)
                          from booking.event_resource_blocks b where b.rule_id = r.id), '[]'::jsonb))
  from booking.schedule_rules r where r.id = p_rule_id
$$;

-- tapahtumakerran oma kapasiteettipooli (resources.code = 'event_rule_<id>', parent = kerran tila, kapasiteetti = kerran max_persons)
create or replace function booking._event_rule_pool_sync(p_rule_id bigint) returns bigint
language plpgsql security definer set search_path = '' as $$
declare r booking.schedule_rules; v_cap integer; v_pool bigint; v_name text; v_code text := 'event_rule_' || p_rule_id::text;
begin
  select * into r from booking.schedule_rules where id = p_rule_id;
  if not found or r.kind <> 'event' then return null; end if;
  v_cap := coalesce(r.max_persons, (select pc.max_persons from booking.product_config pc where pc.product_id = r.product_id));
  if v_cap is null then perform booking._err('max_persons_required', 'Anna kerralle enimmäishenkilömäärä'); end if;
  v_name := left('Tapahtumakerta: ' || coalesce((select p.name from kb.products p where p.id = r.product_id), '') || ' ' || to_char(r.valid_from, 'DD.MM.YYYY'), 200);
  select id into v_pool from booking.resources where code = v_code;
  if v_pool is null then
    insert into booking.resources(code, name, kind, parent_id, capacity, active, sort_order, notes)
    values (v_code, v_name, 'capacity_pool', r.space_id, v_cap, true, 900, 'booking_158: tapahtumakerran oma kapasiteetti (luodaan ja poistetaan automaattisesti)')
    returning id into v_pool;
  else
    update booking.resources set capacity = v_cap, parent_id = r.space_id, name = v_name, active = true
     where id = v_pool and (capacity, parent_id, name, active) is distinct from (v_cap, r.space_id, v_name, true);
  end if;
  insert into booking.schedule_rule_pools(rule_id, pool_id) values (r.id, v_pool) on conflict do nothing;
  return v_pool;
end $$;

-- materialisoi kerran tilan exclusive-blokit space_blocks-riveiksi (aktiivinen kerta) tai poistaa ne (passiivinen / poistettu kerta)
create or replace function booking._event_sync_blocks(p_rule_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare r booking.schedule_rules; v_reason text; v_prev text := coalesce(current_setting('booking.event_sync', true), '');
begin
  perform set_config('booking.event_sync', 'on', true);
  select * into r from booking.schedule_rules where id = p_rule_id;
  if not found or r.kind <> 'event' or not r.active then
    delete from booking.space_blocks b using booking.event_resource_blocks e where b.event_block_id = e.id and e.rule_id = p_rule_id;
  else
    v_reason := left('Tapahtuma: ' || coalesce((select p.name from kb.products p where p.id = r.product_id), '') || ' (' || r.label || ')', 500);
    delete from booking.space_blocks b using booking.event_resource_blocks e, booking.resources res
     where b.event_block_id = e.id and e.rule_id = p_rule_id and res.id = e.resource_id and not (e.mode = 'exclusive' and res.kind = 'space');
    insert into booking.space_blocks(space_id, starts_at, ends_at, reason, active, event_block_id)
    select e.resource_id, lower(x.rg), upper(x.rg), v_reason, true, e.id
      from booking.event_resource_blocks e
      join booking.resources res on res.id = e.resource_id and res.kind = 'space'
      cross join lateral (select booking._event_block_range(r.valid_from, r.start_time, e) as rg) x
     where e.rule_id = p_rule_id and e.mode = 'exclusive'
    on conflict (event_block_id) where event_block_id is not null do update
       set space_id = excluded.space_id, starts_at = excluded.starts_at, ends_at = excluded.ends_at, reason = excluded.reason, active = true
     where (booking.space_blocks.space_id, booking.space_blocks.starts_at, booking.space_blocks.ends_at, booking.space_blocks.reason, booking.space_blocks.active)
           is distinct from (excluded.space_id, excluded.starts_at, excluded.ends_at, excluded.reason, true);
  end if;
  perform set_config('booking.event_sync', v_prev, true);
end $$;

-- ristiriidat: kerran materialisoituvat blokit vs. muut aktiiviset varaukset (ei saman kerran omat liput) ja muiden kertojen tapahtumablokit
create or replace function booking._event_rule_conflicts(p_rule_id bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  with blk as (
    select e.id, e.resource_id, booking._event_block_range(r.valid_from, r.start_time, e) as rg
      from booking.event_resource_blocks e
      join booking.schedule_rules r on r.id = e.rule_id and r.active and r.kind = 'event'
      join booking.resources res on res.id = e.resource_id and res.kind = 'space'
     where e.rule_id = p_rule_id and e.mode = 'exclusive'
  ), hits as (
    select b.resource_id, c.claim_start as starts_at, c.claim_end as ends_at, 'reservation'::text as reason
      from blk b
      join booking.v_claims c on c.resource_id = b.resource_id and tstzrange(c.claim_start, c.claim_end, '[)') && b.rg
      join booking.reservations rr on rr.id = c.reservation_id
     where booking._res_active(c.status, c.hold_expires_at) and c.claim_end > now() and rr.rule_id is distinct from p_rule_id
    union
    select b.resource_id, sb.starts_at, sb.ends_at, 'event_block'::text
      from blk b
      join booking.space_blocks sb on sb.active and sb.space_id = b.resource_id and sb.during && b.rg
      join booking.event_resource_blocks e2 on e2.id = sb.event_block_id and e2.rule_id <> p_rule_id
  )
  select coalesce(jsonb_agg(jsonb_build_object('resource_id', h.resource_id, 'resource_name', res.name, 'starts_at', h.starts_at, 'ends_at', h.ends_at, 'reason', h.reason)
                            order by h.starts_at, h.resource_id), '[]'::jsonb)
    from hits h join booking.resources res on res.id = h.resource_id
$$;

create or replace function booking._event_raise_conflicts(p_rule_id bigint) returns void
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb := booking._event_rule_conflicts(p_rule_id);
begin
  if jsonb_array_length(v) > 0 then
    raise exception '%', 'Resurssi on jo varattu tälle ajalle (' || jsonb_array_length(v)::text || ' ristiriitaa)'
      using errcode = 'BK001', detail = 'conflict', hint = v::text;
  end if;
end $$;

create or replace function booking._event_jint(p_val jsonb, p_field text, p_min integer, p_max integer) returns integer
language plpgsql immutable set search_path = '' as $$
declare v integer;
begin
  if p_val is null or jsonb_typeof(p_val) = 'null' then return null; end if;
  if jsonb_typeof(p_val) not in ('number', 'string') or btrim(p_val #>> '{}') !~ '^-?\d{1,6}$' then
    perform booking._err('invalid_param', 'Virheellinen arvo: ' || p_field);
  end if;
  v := btrim(p_val #>> '{}')::integer;
  if v < p_min or v > p_max then perform booking._err('invalid_param', format('Arvo %s on sallitun välin %s–%s ulkopuolella', p_field, p_min, p_max)); end if;
  return v;
end $$;

create or replace function booking._event_jbool(p_val jsonb, p_field text) returns boolean
language plpgsql immutable set search_path = '' as $$
begin
  if p_val is null or jsonb_typeof(p_val) = 'null' then return null; end if;
  if jsonb_typeof(p_val) = 'boolean' then return (p_val #>> '{}')::boolean; end if;
  if jsonb_typeof(p_val) = 'string' and lower(btrim(p_val #>> '{}')) in ('true', 'false', 't', 'f') then return lower(btrim(p_val #>> '{}')) in ('true', 't'); end if;
  perform booking._err('invalid_param', 'Virheellinen arvo: ' || p_field);
end $$;

-- muuttuneet tapahtumakerrat (myös muiden RPC:iden kautta, esim. admin_update_rule): blokit ja pooli ajan tasalle
create or replace function booking._event_rule_changed_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.kind = 'event' or old.kind = 'event' then
    perform booking._event_sync_blocks(new.id);
    if new.kind = 'event' and exists (select 1 from booking.resources where code = 'event_rule_' || new.id::text) then
      perform booking._event_rule_pool_sync(new.id);
    end if;
  end if;
  return null;
end $$;
drop trigger if exists zz_event_sync on booking.schedule_rules;
create trigger zz_event_sync after update of active, valid_from, valid_to, start_time, duration_minutes, label, max_persons, space_id, product_id, kind
  on booking.schedule_rules for each row execute function booking._event_rule_changed_trg();

create or replace function booking._event_blocks_changed_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then perform booking._event_sync_blocks(old.rule_id); end if;
  if tg_op in ('INSERT', 'UPDATE') and (tg_op = 'INSERT' or new.rule_id <> old.rule_id) then perform booking._event_sync_blocks(new.rule_id); end if;
  return null;
end $$;
drop trigger if exists zz_event_sync on booking.event_resource_blocks;
create trigger zz_event_sync after insert or update or delete on booking.event_resource_blocks
  for each row execute function booking._event_blocks_changed_trg();

do $$
declare f text;
begin
  foreach f in array array['booking._events_sale_enabled()', 'booking._channels_effective(text[], text)',
    'booking._event_block_range(date, time without time zone, booking.event_resource_blocks)', 'booking._event_block_is_own(bigint, bigint, bigint[])',
    'booking._event_block_json(booking.event_resource_blocks)', 'booking._event_rule_json(bigint)', 'booking._event_rule_pool_sync(bigint)',
    'booking._event_sync_blocks(bigint)', 'booking._event_rule_conflicts(bigint)', 'booking._event_raise_conflicts(bigint)',
    'booking._event_jint(jsonb, text, integer, integer)', 'booking._event_jbool(jsonb, text)',
    'booking._event_rule_changed_trg()', 'booking._event_blocks_changed_trg()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- ---------- 3) korvatut funktiot (tuotannon teksti + booking_158-muutokset, merkitty kommentein) ----------
CREATE OR REPLACE FUNCTION booking._sessions(p_from date, p_to date, p_product_id bigint DEFAULT NULL::bigint, p_only_bookable boolean DEFAULT true)
 RETURNS TABLE(rule_id bigint, product_id bigint, label text, mode text, session_date date, starts_at timestamp with time zone, ends_at timestamp with time zone, status text, remaining integer, min_persons integer, max_persons integer, price_mode text, unit_price numeric, base_price numeric, included_persons integer, extra_person_price numeric, sale_closes_at timestamp with time zone, label_en text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with cand as materialized (
    select r.id as rule_id, r.product_id, r.label, r.label_en, r.mode, d.d::date as session_date, r.space_id,
           r.min_persons, r.max_persons, r.price_mode, r.deadline_minutes, r.sort_order,
           ((d.d + r.start_time) at time zone booking._tz()) as starts_at,
           ((d.d + r.start_time + make_interval(mins => r.duration_minutes)) at time zone booking._tz()) as ends_at,
           coalesce(v.price, p.price) as base_price,
           coalesce(r.included_persons, v.included_persons, p.included_persons) as inc,
           coalesce(r.extra_person_price, v.extra_person_price, p.extra_person_price) as extra,
           (select array_agg(rp.pool_id) from booking.schedule_rule_pools rp where rp.rule_id = r.id) as pools
      from booking.schedule_rules r
      join kb.products p on p.id = r.product_id and p.active
      join booking.product_config pc on pc.product_id = r.product_id and (pc.bookable or not p_only_bookable)
            and (pc.lifecycle = 'current' or not p_only_bookable)
      left join kb.product_price_variants v on v.id = r.price_variant_id
      cross join lateral generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') as d(d)
     where r.active and (p_product_id is null or r.product_id = p_product_id)
       -- booking_158: tapahtumakerrat (kind = 'event') eivät näy julkisesti ennen kuin myynti avataan (events.sale_enabled)
       and (not p_only_bookable or r.kind <> 'event' or booking._events_sale_enabled())
       and extract(isodow from d.d)::smallint = any (r.weekdays)
       and (r.valid_from is null or d.d::date >= r.valid_from)
       and (r.valid_to is null or d.d::date <= r.valid_to)
       and (v.id is null or (v.active and (v.valid_from is null or d.d::date >= v.valid_from)
                         and (v.valid_to is null or d.d::date <= v.valid_to)))
       and (p.valid_from is null or d.d::date >= p.valid_from)
       and (p.valid_to is null or d.d::date <= p.valid_to)
  ), bounds as (
    select min(c.starts_at) as since, max(c.ends_at) as until from cand c
  ), active_space as materialized (
    select r.space_id, r.mode, r.starts_at, r.ends_at
      from booking.reservations r cross join bounds b
     where r.status in ('pending', 'confirmed')
       and booking._res_active(r.status, r.hold_expires_at)
       and r.starts_at < b.until and r.ends_at > b.since
    union all
    -- booking_148: voimassa oleva yksityisvuoron jonotuspito varaa koko tilan vuoron ajaksi (kuten exclusive-varaus).
    -- Ei koske pidon haltijaa eikä henkilökuntaa (_waitlist_hold_counts), joten admin näkee vuoron ennallaan.
    select w.space_id, 'exclusive'::text, w.starts_at, w.ends_at
      from booking.waitlist_entries w
      join booking.schedule_rules sr on sr.id = w.rule_id and sr.mode = 'exclusive'
      cross join bounds b
     where w.status = 'notified' and w.hold_expires_at > now()
       and w.starts_at < b.until and w.ends_at > b.since
       and booking._waitlist_hold_counts(w.id)
  ), active_blocks as materialized (
    -- booking_158: tapahtuman resurssiblokki ei sulje saman tapahtumakerran omaa lippua (event_rule_id = c.rule_id)
    select b.space_id, b.starts_at, b.ends_at, e.rule_id as event_rule_id
      from booking.space_blocks b cross join bounds lim
      left join booking.event_resource_blocks e on e.id = b.event_block_id
     where b.active and b.starts_at < lim.until and b.ends_at > lim.since
  ), calc as materialized (
    select c.*, case when c.mode = 'exclusive' then null::integer
                     else booking._pools_remaining(c.pools, c.starts_at, c.ends_at) end as pool_remaining
      from cand c
  )
  select c.rule_id, c.product_id, c.label, c.mode, c.session_date, c.starts_at, c.ends_at,
         case
           when c.starts_at - make_interval(mins => c.deadline_minutes) <= now() then 'closed'
           when exists (select 1 from active_blocks b where b.space_id = c.space_id
                        and b.starts_at < c.ends_at and b.ends_at > c.starts_at
                        and b.event_rule_id is distinct from c.rule_id) then 'unavailable'
           when c.mode = 'exclusive' then
             case when exists (select 1 from active_space x where x.space_id = c.space_id
                                and x.starts_at < c.ends_at and x.ends_at > c.starts_at)
                  then 'unavailable' else 'available' end
           else
             case when exists (select 1 from active_space x where x.space_id = c.space_id
                                and x.mode = 'exclusive'
                                and x.starts_at < c.ends_at and x.ends_at > c.starts_at)
                  then 'unavailable'
                  when coalesce(c.pool_remaining, 1000) < c.min_persons then 'full'
                  else 'available' end
         end as status,
         case when c.mode = 'exclusive' then c.max_persons
              else least(coalesce(c.max_persons, 1000), greatest(coalesce(c.pool_remaining, 1000), 0)) end as remaining,
         c.min_persons, c.max_persons, c.price_mode,
         case when c.price_mode = 'per_person' then c.base_price end as unit_price,
         case when c.price_mode <> 'per_person' then c.base_price end as base_price,
         case when c.price_mode = 'fixed_plus_extra' then c.inc end as included_persons,
         case when c.price_mode = 'fixed_plus_extra' then c.extra end as extra_person_price,
         c.starts_at - make_interval(mins => c.deadline_minutes) as sale_closes_at,
         c.label_en  -- booking_151: vuoron nimi englanniksi (schedule_rules.label_en, null = ei käännöstä)
    from calc c
   order by c.session_date, c.starts_at, c.rule_id
$function$;

CREATE OR REPLACE FUNCTION booking._check_claim(p_res_id bigint, p_leg_id bigint, p_resource bigint, p_role text, p_mode text, p_start timestamp with time zone, p_end timestamp with time zone, p_persons integer, p_pools bigint[], p_skill text, p_session_key text, p_quota_exempt boolean DEFAULT false, p_override boolean DEFAULT false, p_phase text DEFAULT 'all'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_res booking.resources; v_range tstzrange := tstzrange(p_start, p_end, '[)');
  x record; v_pool bigint; v_cap integer; v_peak integer; v_gap integer; v_maxgap integer; v_ritual boolean; v_savu boolean;
begin
  select * into v_res from booking.resources where id = p_resource;
  if not found then perform booking._err('resource_not_found', 'Resurssia ei löydy'); end if;
  perform pg_advisory_xact_lock(hashtextextended('booking:space:' || p_resource::text, 0));

  if p_phase in ('all', 'blocks') then
    -- booking_158: saman tapahtumakerran oma lippu ohittaa tapahtuman omat blokit (_event_block_is_own)
    if not p_override and exists (select 1 from booking.space_blocks b where b.active and b.space_id = p_resource and b.during && v_range
                                    and not booking._event_block_is_own(b.event_block_id, p_res_id, p_pools)) then
      if p_role = 'therapist' then perform booking._err('therapist_closed', 'Saunottajat eivät ole saatavilla tälle ajalle (hoidot kiinni)');
      else perform booking._err('space_closed', 'Aika ei ole varattavissa (tila suljettu)'); end if;
    end if;
    if p_phase = 'blocks' then return; end if;
  end if;

  if p_role = 'therapist' then
    if not p_override and booking._therapist_slack(p_skill, p_start, p_end, p_persons, p_session_key, p_leg_id, p_res_id) < 0 then
      perform booking._err('no_therapist', 'Ei vapaata saunottajaa tälle ajalle');
    end if;
    return;
  elsif p_role = 'group' then
    return;                                   -- sulkuryhmä: vain sulkutarkistus (yllä)
  end if;

  -- role = 'space'
  v_savu := (v_res.code = 'savusauna');
  v_ritual := booking._is_ritual(p_pools);
  v_maxgap := greatest(v_res.buffer_after_min, coalesce(v_res.buffer_ritual_ritual_min, 0));
  for x in
    select c.mode, c.claim_start, c.claim_end, c.session_key, c.pool_ids
      from booking.v_claims c
     where c.resource_id = p_resource and c.role = 'space' and c.reservation_id is distinct from p_res_id
       and booking._res_active(c.status, c.hold_expires_at)
       and c.claim_start < p_end + make_interval(mins => v_maxgap) and c.claim_end > p_start - make_interval(mins => v_maxgap)
     order by (c.mode = 'exclusive') desc
  loop
    v_gap := case when v_ritual and booking._is_ritual(x.pool_ids) and v_res.buffer_ritual_ritual_min is not null
                  then v_res.buffer_ritual_ritual_min else v_res.buffer_after_min end;
    -- puoliavoin väli + puskuri: konflikti vain jos [alku, loppu+puskuri) leikkaavat molempiin suuntiin
    if not (p_start < x.claim_end + make_interval(mins => v_gap) and x.claim_start < p_end + make_interval(mins => v_gap)) then continue; end if;
    if p_mode = 'exclusive' and x.mode = 'exclusive' then
      if v_savu then perform booking._err('private_booked', 'Savusauna on jo varattu yksityisvuorolle tälle ajalle');
      else perform booking._err('space_busy', 'Tila on jo varattu tälle ajalle (' || v_res.code || ')'); end if;
    elsif p_mode = 'exclusive' then
      if v_savu then perform booking._err('public_shift_booked', 'Ajalle on jo varauksia yleisille vuoroille – yksityisvuoroa ei voi varata');
      else perform booking._err('space_busy', 'Tilassa on jo toinen istunto tälle ajalle tai sen puskuriin (' || v_res.code || ')'); end if;
    elsif x.mode = 'exclusive' then
      if v_savu then perform booking._err('private_booked', 'Ajalle on yksityisvuoro – yleistä vuoroa ei voi varata');
      else perform booking._err('space_busy', 'Tila on varattu yksinoikeudella tälle ajalle (' || v_res.code || ')'); end if;
    elsif v_res.session_exclusive and (p_session_key is null or p_session_key is distinct from x.session_key) then
      perform booking._err('space_busy', 'Tilassa on toinen istunto tälle ajalle tai sen puskuriin (' || v_res.code || ')');
    end if;
  end loop;

  -- booking_148: yksityisvuoron jonotuspito (vuoroon >= 48 h, 120 min) varaa koko tilan kuten exclusive-varaus.
  -- Pidon haltija itse ja henkilökunta ohittavat (_waitlist_hold_counts).
  if exists (select 1 from booking.waitlist_entries w
               join booking.schedule_rules sr on sr.id = w.rule_id and sr.mode = 'exclusive'
              where w.space_id = p_resource and w.status = 'notified' and w.hold_expires_at > now()
                and p_start < w.ends_at + make_interval(mins => v_res.buffer_after_min)
                and w.starts_at < p_end + make_interval(mins => v_res.buffer_after_min)
                and booking._waitlist_hold_counts(w.id)) then
    if v_savu then perform booking._err('private_booked', 'Savusauna on varattu yksityisvuorolle tälle ajalle');
    else perform booking._err('space_busy', 'Tila on varattu tälle ajalle (' || v_res.code || ')'); end if;
  end if;

  if p_mode = 'shared' then
    foreach v_pool in array coalesce(p_pools, '{}') loop
      select r.capacity into v_cap from booking.resources r where r.id = v_pool and r.kind = 'capacity_pool' and r.parent_id = p_resource;
      if v_cap is null then perform booking._err('bad_pool', 'Kapasiteettipooli ' || v_pool::text || ' ei kuulu tähän tilaan'); end if;
      if not p_quota_exempt then
        v_peak := booking._pool_peak(v_pool, p_start, p_end, p_res_id);
        if v_peak + p_persons > v_cap then
          perform booking._err('capacity_exceeded', format('Ei tarpeeksi vapaita paikkoja (vapaana %s, pyydetty %s)', greatest(v_cap - v_peak, 0), p_persons));
        end if;
      end if;
    end loop;
  end if;
end $function$;

CREATE OR REPLACE FUNCTION booking._resolve_session(p_rule_id bigint, p_date date, p_persons integer, p_enforce_deadline boolean, p_override_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_override_end timestamp with time zone DEFAULT NULL::timestamp with time zone, p_allow_override_shared boolean DEFAULT false)
 RETURNS TABLE(o_rule_id bigint, o_product_id bigint, o_space_id bigint, o_mode text, o_starts_at timestamp with time zone, o_ends_at timestamp with time zone, o_pool_ids bigint[])
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r booking.schedule_rules; pc booking.product_config; p kb.products; v kb.product_price_variants;
  s_start timestamptz; s_end timestamptz; v_pools bigint[];
begin
  select * into r from booking.schedule_rules where id = p_rule_id and active;
  if not found then perform booking._err('rule_not_found', 'Vuoroa ei löydy tai se ei ole käytössä'); end if;
  select * into pc from booking.product_config where product_id = r.product_id;
  if not found or not pc.bookable or pc.lifecycle <> 'current' then perform booking._err('not_bookable', 'Tuotetta ei voi varata'); end if;
  select * into p from kb.products where id = r.product_id and active;
  if not found then perform booking._err('product_inactive', 'Tuote ei ole myynnissä'); end if;
  if r.price_variant_id is not null then select * into v from kb.product_price_variants where id = r.price_variant_id; end if;
  -- booking_158: tapahtumakertojen myynti on kiinni, kunnes events.sale_enabled = true (henkilökunta voi silti tehdä käsivarauksen)
  if r.kind = 'event' and not booking._events_sale_enabled() and not booking.is_staff() then
    perform booking._err('sale_closed', 'Tapahtuman myynti ei ole vielä auki');
  end if;

  if p_persons is null or p_persons < r.min_persons then
    perform booking._err('persons_min', format('Vähimmäishenkilömäärä on %s', r.min_persons));
  end if;
  if r.max_persons is not null and p_persons > r.max_persons then
    perform booking._err('persons_max', format('Enimmäishenkilömäärä on %s', r.max_persons));
  end if;
  if pc.max_persons is not null and p_persons > pc.max_persons then
    perform booking._err('persons_max', format('Enimmäishenkilömäärä on %s', pc.max_persons));
  end if;

  if p_override_start is not null then
    -- vapaa aika (vain käsivaraus / admin): vain yksityisvuoroille
    if r.mode <> 'exclusive' and not p_allow_override_shared then perform booking._err('override_not_allowed', 'Mukautettu aika on sallittu vain yksityisvuoroille'); end if;
    s_start := p_override_start; s_end := p_override_end;
    if s_end is null or s_end <= s_start then perform booking._err('bad_time', 'Virheellinen aika'); end if;
  else
    if p_date is null
       or not (extract(isodow from p_date)::smallint = any (r.weekdays))
       or (r.valid_from is not null and p_date < r.valid_from) or (r.valid_to is not null and p_date > r.valid_to)
       or (v.id is not null and (not v.active or (v.valid_from is not null and p_date < v.valid_from) or (v.valid_to is not null and p_date > v.valid_to)))
       or (p.valid_from is not null and p_date < p.valid_from) or (p.valid_to is not null and p_date > p.valid_to) then
      perform booking._err('no_session', 'Valitulle päivälle ei ole tätä vuoroa');
    end if;
    s_start := (p_date + r.start_time) at time zone booking._tz();
    s_end   := (p_date + r.start_time + make_interval(mins => r.duration_minutes)) at time zone booking._tz();
  end if;

  if p_enforce_deadline and s_start - make_interval(mins => r.deadline_minutes) <= now() then
    perform booking._err('sale_closed', 'Vuoron myynti on päättynyt');
  end if;

  select array_agg(pool_id order by pool_id) into v_pools from booking.schedule_rule_pools where rule_id = r.id;
  return query select r.id, r.product_id, r.space_id, r.mode, s_start, s_end, coalesce(v_pools, '{}'::bigint[]);
end $function$;

CREATE OR REPLACE FUNCTION booking._block_conflict_pairs()
 RETURNS TABLE(reservation_id bigint, leg_id bigint, resource_id bigint, block_id bigint, closure_event_id bigint, claim_start timestamp with time zone, claim_end timestamp with time zone, block_reason text, closure_reason text, calendar_name text, block_signature text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select c.reservation_id, c.leg_id, c.resource_id, b.id, b.closure_event_id,
         c.claim_start, c.claim_end, b.reason, ev.reason, cal.name,
         booking._block_conflict_signature(b.id)
    from booking.v_claims c
    join booking.space_blocks b
      on b.active and b.space_id = c.resource_id
     and b.during && tstzrange(c.claim_start, c.claim_end, '[)')
    left join booking.closure_events ev on ev.id = b.closure_event_id
    left join booking.closure_calendars cal on cal.code = ev.calendar_code
   where not c.is_override
     and not booking._event_block_is_own(b.event_block_id, c.reservation_id, c.pool_ids)  -- booking_158: oma lippu ei ole ristiriita
     and booking._res_active(c.status, c.hold_expires_at)
     and c.claim_end > now()
$function$;

CREATE OR REPLACE FUNCTION booking.space_blocks_managed_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if old.closure_event_id is not null and coalesce(current_setting('booking.closure_sync', true), '') <> 'on' then
    perform booking._err('closure_managed', 'Tämä sulku tulee sulkukalenterista – muuta tai poista tapahtuma kalenterissa (tai merkitse tapahtuma ohitettavaksi)');
  end if;
  -- booking_158: tapahtuman resurssivarauksista syntyneet sulut muutetaan vain tapahtumien hallinnasta (booking._event_sync_blocks)
  if old.event_block_id is not null and coalesce(current_setting('booking.event_sync', true), '') <> 'on'
     and exists (select 1 from booking.event_resource_blocks e where e.id = old.event_block_id) then
    perform booking._err('event_managed', 'Tämä sulku tulee tapahtumasta – muuta tapahtuman resurssivarauksia tapahtumien hallinnassa');
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION booking.closure_blocks_outbox_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_exp booking.closure_exports;
  v_cal text;
begin
  -- silmukkaesto 1: kalenterista tuodut (hallitut) sulut eivät koskaan mene takaisin kalenteriin
  if tg_op = 'INSERT' and new.closure_event_id is not null then return new; end if;
  -- booking_158: tapahtuman resurssiblokit eivät mene sulkukalenteriin (ei closure_outbox-rivejä)
  if (tg_op <> 'DELETE' and new.event_block_id is not null) or (tg_op <> 'INSERT' and old.event_block_id is not null) then return coalesce(new, old); end if;
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

CREATE OR REPLACE FUNCTION booking.closure_outbox_backfill()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_n integer;
begin
  if booking._jwt_role() is distinct from 'service_role' and current_user not in ('postgres', 'service_role') then
    perform booking._err('forbidden', 'Vain service_role');
  end if;
  with ins as (
    insert into booking.closure_outbox(block_id, calendar_code, op, event_id)
    select b.id, booking._closure_calendar_for(b.space_id), 'upsert', booking._closure_event_id(b.id)
      from booking.space_blocks b
     where b.active and b.closure_event_id is null and b.event_block_id is null and b.ends_at > now() and booking._closure_calendar_for(b.space_id) is not null
       and not exists (select 1 from booking.closure_exports x where x.block_id = b.id)
       and not exists (select 1 from booking.closure_outbox o where o.block_id = b.id and o.status in ('pending', 'processing', 'blocked'))
    returning 1) select count(*) into v_n from ins;
  return v_n;
end $function$;

CREATE OR REPLACE FUNCTION booking.public_catalog()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'slug', p.slug, 'name', p.name, 'name_en', p.name_en,
      'description', p.description, 'description_en', p.description_en,
      'short_description', p.short_description, 'short_description_en', p.short_description_en,
      'category', p.category, 'sale_kind', pc.sale_kind,
      'price', p.price, 'price_type', p.price_type, 'price_text', p.price_text,
      'duration_text', p.duration_text, 'duration_text_en', p.duration_text_en, 'duration_minutes', p.duration_minutes,
      'min_persons', pc.min_persons, 'max_persons', case when pc.public_slots then booking._treatment_max_persons(p.id) else pc.max_persons end,
      'booking_kind', case when pc.public_slots then 'slots' else 'rules' end, 'slot_grid_minutes', case when pc.public_slots then 30 end,
      'options', booking._product_options_json(p.id, true), 'option_required', (pc.option_required and exists (select 1 from booking.product_options x where x.product_id = p.id and x.active)),
      'option_label', pc.option_label, 'option_label_en', pc.option_label_en,
      'voucher_note', pc.voucher_note, 'voucher_note_en', pc.voucher_note_en,
      'addons_enabled', (jsonb_array_length(booking._product_addon_codes(p.id)) > 0), 'allowed_addons', booking._product_addon_codes(p.id),
      'timeline', booking._timeline_json(p.id) -> 'segments', 'timeline_text', booking._timeline_json(p.id) ->> 'text', 'timeline_text_en', booking._timeline_json(p.id) ->> 'text_en'
    ) order by pc.sort_order, p.id), '[]'::jsonb)
  from booking.product_config pc
  join kb.products p on p.id = pc.product_id and p.active
  where pc.bookable and pc.shop_visible and pc.lifecycle = 'current'
    -- booking_158: vain kauppa-kanavan tuotteet; tapahtumat ja koulutukset vasta kun events.sale_enabled = true
    and 'shop' = any (booking._channels_effective(pc.channels, p.category))
    and (p.category not in ('event', 'training') or booking._events_sale_enabled())
    and (pc.public_slots or exists (select 1 from booking.schedule_rules r where r.product_id = p.id and r.active)) $function$;

CREATE OR REPLACE FUNCTION booking.public_availability(p_product_id bigint, p_from date, p_to date)
 RETURNS TABLE(rule_id bigint, label text, mode text, session_date date, starts_at timestamp with time zone, ends_at timestamp with time zone, status text, remaining integer, min_persons integer, max_persons integer, price_mode text, unit_price numeric, base_price numeric, included_persons integer, extra_person_price numeric, label_en text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_product_id is null or p_from is null or p_to is null or p_to < p_from or p_to - p_from > 92 then
    perform booking._err('bad_range', 'Virheellinen päiväväli (enintään 92 päivää)');
  end if;
  if not exists (select 1 from booking.product_config pc join kb.products p on p.id = pc.product_id
                  where pc.product_id = p_product_id and pc.bookable and pc.shop_visible and pc.lifecycle = 'current'
                    and 'shop' = any (booking._channels_effective(pc.channels, p.category))) then  -- booking_158: kanava
    return;
  end if;
  return query
    select s.rule_id, s.label, s.mode, s.session_date, s.starts_at, s.ends_at,
           case when s.status = 'closed' then 'closed'
                when s.mode = 'exclusive' and s.status = 'unavailable'
                     and booking._waitlist_private_taken(s.rule_id, s.starts_at, s.ends_at) then 'full'
                else s.status end,
           s.remaining, s.min_persons, s.max_persons, s.price_mode, s.unit_price, s.base_price, s.included_persons, s.extra_person_price,
           s.label_en
      from booking._sessions(greatest(p_from, (now() at time zone booking._tz())::date),
                             least(p_to, (now() at time zone booking._tz())::date + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int),
                             p_product_id, true) s
     where s.status <> 'closed';
end $function$;

CREATE OR REPLACE FUNCTION booking.public_availability_all(p_from date, p_to date, p_audience text DEFAULT 'consumer'::text)
 RETURNS TABLE(product_id bigint, rule_id bigint, label text, mode text, session_date date, starts_at timestamp with time zone, ends_at timestamp with time zone, status text, remaining integer, min_persons integer, max_persons integer, price_mode text, unit_price numeric, base_price numeric, included_persons integer, extra_person_price numeric, label_en text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_from date;
  v_to date;
  v_audience text := case when lower(btrim(coalesce(p_audience, ''))) = 'business' then 'business' else 'consumer' end;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 92 then
    perform booking._err('bad_range', 'Virheellinen päiväväli (enintään 92 päivää)');
  end if;
  v_from := greatest(p_from, (now() at time zone booking._tz())::date);
  v_to := least(p_to, (now() at time zone booking._tz())::date
                       + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int);
  if v_from > v_to then return; end if;
  return query
    select s.product_id, s.rule_id, s.label, s.mode, s.session_date,
           s.starts_at, s.ends_at,
           case when s.mode = 'exclusive' and s.status = 'unavailable'
                     and booking._waitlist_private_taken(s.rule_id, s.starts_at, s.ends_at) then 'full'
                else s.status end,
           s.remaining, s.min_persons,
           s.max_persons, s.price_mode, s.unit_price, s.base_price, s.included_persons,
           s.extra_person_price, s.label_en
      from booking._sessions(v_from, v_to, null, true) s
      join booking.product_config pc on pc.product_id = s.product_id
      join kb.products p on p.id = s.product_id
     where pc.bookable and pc.shop_visible and pc.lifecycle = 'current'
       and 'shop' = any (booking._channels_effective(pc.channels, p.category))  -- booking_158: kanava
       and pc.audience = v_audience and s.status <> 'closed';
end $function$;

-- ---------- 4) hallinnan RPC:t ----------
create or replace function booking.admin_event_list(p_category text default null, p_include_past boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_today date := (now() at time zone booking._tz())::date;
begin
  perform booking._require_staff();
  if p_category is not null and p_category not in ('event', 'training') then
    perform booking._err('invalid_param', 'Kategoria on event tai training');
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'product_id', p.id, 'slug', p.slug, 'name', p.name, 'name_en', p.name_en, 'category', p.category, 'active', p.active,
      'bookable', coalesce(pc.bookable, false), 'shop_visible', coalesce(pc.shop_visible, false), 'lifecycle', pc.lifecycle,
      'channels', to_jsonb(booking._channels_effective(pc.channels, p.category)),
      'max_persons', pc.max_persons, 'duration_minutes', coalesce(pc.duration_minutes, p.duration_minutes), 'image_path', pc.image_path,
      'price', p.price, 'price_text', p.price_text, 'sale_enabled', booking._events_sale_enabled(),
      'rules', coalesce((select jsonb_agg(booking._event_rule_json(r.id) order by r.valid_from, r.start_time, r.id)
                           from booking.schedule_rules r
                          where r.product_id = p.id and r.kind = 'event' and (p_include_past or r.valid_from >= v_today - 1)), '[]'::jsonb)
    ) order by coalesce(pc.sort_order, 100), p.id)
      from kb.products p
      left join booking.product_config pc on pc.product_id = p.id
     where p.category in ('event', 'training') and (p_category is null or p.category = p_category)
  ), '[]'::jsonb);
end $$;

create or replace function booking.admin_event_rule_upsert(p_id bigint default null, p_product_id bigint default null, p_patch jsonb default '{}'::jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  allowed text[] := array['date','start_time','duration_minutes','max_persons','min_persons','deadline_minutes','label','label_en','active','price_variant_id'];
  k text; r booking.schedule_rules; p kb.products; pc booking.product_config;
  v_date date; v_start time; v_dur integer; v_max integer; v_min integer; v_deadline integer; v_label text; v_label_en text; v_active boolean;
  v_variant bigint; v_space bigint; v_sold integer; v_has_res boolean; v_id bigint; v_auto_label boolean := false;
begin
  perform booking._require_permission('catalog.edit');
  p_patch := coalesce(p_patch, '{}'::jsonb);
  if jsonb_typeof(p_patch) <> 'object' then perform booking._err('invalid_param', 'p_patch puuttuu'); end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;

  if p_id is not null then
    select * into r from booking.schedule_rules where id = p_id for update;
    if not found or r.kind <> 'event' then perform booking._err('not_found', 'Tapahtumakertaa ei löydy'); end if;
    if p_product_id is not null and p_product_id <> r.product_id then perform booking._err('invalid_param', 'Kerta kuuluu toiseen tuotteeseen'); end if;
    p_product_id := r.product_id;
  end if;
  select * into p from kb.products where id = p_product_id;
  if not found then perform booking._err('not_found', 'Tuotetta ei löydy'); end if;
  if p.category not in ('event', 'training') then perform booking._err('not_event', 'Tuote ei ole tapahtuma tai koulutus'); end if;
  select * into pc from booking.product_config where product_id = p.id;
  if not found then perform booking._err('not_found', 'Tuotteen varausasetukset puuttuvat'); end if;

  -- päivä ja aika
  if p_patch ? 'date' then
    if coalesce(p_patch ->> 'date', '') !~ '^\d{4}-\d{2}-\d{2}$' then perform booking._err('invalid_param', 'Päivä muodossa VVVV-KK-PP'); end if;
    begin v_date := (p_patch ->> 'date')::date; exception when others then perform booking._err('invalid_param', 'Virheellinen päivä'); end;
  else v_date := r.valid_from; end if;
  if p_patch ? 'start_time' then
    if coalesce(p_patch ->> 'start_time', '') !~ '^\d{1,2}[:.]\d{2}(:00)?$' then perform booking._err('invalid_param', 'Alkuaika muodossa HH:MM'); end if;
    begin v_start := replace(p_patch ->> 'start_time', '.', ':')::time; exception when others then perform booking._err('invalid_param', 'Virheellinen alkuaika'); end;
  else v_start := r.start_time; end if;
  if v_date is null then perform booking._err('invalid_param', 'Päivä puuttuu'); end if;
  if v_start is null then perform booking._err('invalid_param', 'Alkuaika puuttuu'); end if;

  v_dur := case when p_patch ? 'duration_minutes' then booking._event_jint(p_patch -> 'duration_minutes', 'duration_minutes', 1, 20160)
                else coalesce(r.duration_minutes, pc.duration_minutes, p.duration_minutes) end;
  if v_dur is null then perform booking._err('invalid_param', 'Kesto puuttuu'); end if;
  if v_dur > 1440 and p.category <> 'training' then
    perform booking._err('multi_day_training_only', 'Monipäiväinen kerta (yksi lippu) on sallittu vain koulutuksille');
  end if;
  v_max := case when p_patch ? 'max_persons' then booking._event_jint(p_patch -> 'max_persons', 'max_persons', 1, 1000)
                when p_id is not null then r.max_persons else pc.max_persons end;
  v_min := coalesce(case when p_patch ? 'min_persons' then booking._event_jint(p_patch -> 'min_persons', 'min_persons', 1, 1000) end,
                    r.min_persons, pc.min_persons, 1);
  if v_max is not null and v_min > v_max then perform booking._err('invalid_param', 'Vähimmäismäärä on suurempi kuin enimmäismäärä'); end if;
  v_deadline := coalesce(case when p_patch ? 'deadline_minutes' then booking._event_jint(p_patch -> 'deadline_minutes', 'deadline_minutes', 0, 43200) end,
                         r.deadline_minutes, 0);
  v_active := coalesce(case when p_patch ? 'active' then booking._event_jbool(p_patch -> 'active', 'active') end, r.active, true);
  if p_patch ? 'price_variant_id' then
    v_variant := booking._event_jint(p_patch -> 'price_variant_id', 'price_variant_id', 1, 2000000000);
    if v_variant is not null and not exists (select 1 from kb.product_price_variants v where v.id = v_variant and v.product_id = p.id) then
      perform booking._err('invalid_param', 'Hintavaihtoehto ei kuulu tuotteeseen');
    end if;
  else v_variant := r.price_variant_id; end if;
  if p_patch ? 'label' then v_label := nullif(btrim(coalesce(p_patch ->> 'label', '')), ''); else v_label := r.label; end if;
  if v_label is null
     or (p_id is not null and not (p_patch ? 'label') and r.label = to_char(r.valid_from, 'DD.MM.YYYY') || ' klo ' || to_char(r.start_time, 'HH24.MI')) then
    v_label := to_char(v_date, 'DD.MM.YYYY') || ' klo ' || to_char(v_start, 'HH24.MI');
    v_auto_label := true;
  end if;
  if char_length(v_label) > 200 then perform booking._err('invalid_param', 'Nimi on liian pitkä'); end if;
  if p_patch ? 'label_en' then v_label_en := nullif(btrim(coalesce(p_patch ->> 'label_en', '')), ''); else v_label_en := r.label_en; end if;
  if v_label_en is not null and char_length(v_label_en) > 200 then perform booking._err('invalid_param', 'Englanninkielinen nimi on liian pitkä'); end if;

  if p_id is null then
    select id into v_space from booking.resources where code = 'ei_resurssia';
    if v_space is null then perform booking._err('not_found', 'Resurssia ei_resurssia ei löydy'); end if;
    insert into booking.schedule_rules(product_id, label, label_en, mode, space_id, weekdays, start_time, duration_minutes, valid_from, valid_to,
                                       min_persons, max_persons, price_mode, price_variant_id, deadline_minutes, active, sort_order, kind, notes)
    values (p.id, v_label, v_label_en, 'shared', v_space, array[extract(isodow from v_date)::smallint], v_start, v_dur, v_date, v_date,
            v_min, v_max, 'per_person', v_variant, v_deadline, v_active, 100, 'event', 'booking_158: tapahtumakerta')
    returning id into v_id;
  else
    select coalesce(sum(x.persons), 0)::int, count(*) > 0 into v_sold, v_has_res
      from booking.reservations x where x.rule_id = r.id and booking._res_active(x.status, x.hold_expires_at);
    if v_has_res and ((v_date, v_start, v_dur) is distinct from (r.valid_from, r.start_time, r.duration_minutes) or (r.active and not v_active)) then
      perform booking._err('has_reservations', 'Kerralla on varauksia: aikaa ei voi muuttaa eikä kertaa passivoida');
    end if;
    if coalesce(v_max, pc.max_persons) is not null and coalesce(v_max, pc.max_persons) < v_sold then
      perform booking._err('max_below_sold', format('Enimmäismäärä ei voi olla pienempi kuin myydyt paikat (%s)', v_sold));
    end if;
    update booking.schedule_rules
       set label = v_label, label_en = v_label_en, weekdays = array[extract(isodow from v_date)::smallint], start_time = v_start,
           duration_minutes = v_dur, valid_from = v_date, valid_to = v_date, min_persons = v_min, max_persons = v_max,
           price_variant_id = v_variant, deadline_minutes = v_deadline, active = v_active
     where id = r.id;
    v_id := r.id;
  end if;

  perform booking._event_rule_pool_sync(v_id);
  perform booking._event_sync_blocks(v_id);
  perform booking._event_raise_conflicts(v_id);
  perform booking._texts_register_sources();
  return booking._event_rule_json(v_id);
end $$;

create or replace function booking.admin_event_rule_delete(p_id bigint)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r booking.schedule_rules; v_pool bigint; v_prev text := coalesce(current_setting('booking.event_sync', true), '');
begin
  perform booking._require_permission('catalog.edit');
  select * into r from booking.schedule_rules where id = p_id for update;
  if not found or r.kind <> 'event' then perform booking._err('not_found', 'Tapahtumakertaa ei löydy'); end if;
  if exists (select 1 from booking.reservations x where x.rule_id = r.id) then
    perform booking._err('has_reservations', 'Kerralla on varauksia – sitä ei voi poistaa (passivoi tai siirrä varaukset ensin)');
  end if;
  if exists (select 1 from booking.waitlist_entries w where w.rule_id = r.id) then
    perform booking._err('has_waitlist', 'Kerralla on jonotuksia – sitä ei voi poistaa');
  end if;
  perform set_config('booking.event_sync', 'on', true);
  delete from booking.space_blocks b using booking.event_resource_blocks e where b.event_block_id = e.id and e.rule_id = r.id;
  delete from booking.site_texts where source_table = 'booking.schedule_rules' and source_pk = r.id::text;
  delete from booking.schedule_rules where id = r.id;  -- blokit (cascade), poolilinkit (cascade)
  select id into v_pool from booking.resources where code = 'event_rule_' || r.id::text;
  if v_pool is not null and not exists (select 1 from booking.schedule_rule_pools rp where rp.pool_id = v_pool)
     and not exists (select 1 from booking.reservations x where v_pool = any (x.pool_ids)) then
    delete from booking.resources where id = v_pool;
  end if;
  perform set_config('booking.event_sync', v_prev, true);
  return jsonb_build_object('ok', true, 'id', r.id);
end $$;

create or replace function booking.admin_event_blocks_set(p_rule_id bigint, p_blocks jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  r booking.schedule_rules; b jsonb; k text; res booking.resources;
  v_mode text; v_off integer; v_min integer; v_sd smallint; v_sc time; v_ed smallint; v_ec time; v_note text; v_i integer := 0;
  v_s text; v_e text; v_ts timestamptz; v_local timestamp; v_occ tstzrange; v_prev text := coalesce(current_setting('booking.event_sync', true), '');
  allowed text[] := array['resource_id','mode','offset_min','minutes','starts_at','ends_at','note','id','resource_name','resource_code','resource_kind',
                          'timing','start_day','start_clock','end_day','end_clock','sort_order','materialized','rule_id'];
begin
  perform booking._require_permission('catalog.edit');
  select * into r from booking.schedule_rules where id = p_rule_id for update;
  if not found or r.kind <> 'event' then perform booking._err('not_found', 'Tapahtumakertaa ei löydy'); end if;
  p_blocks := coalesce(p_blocks, '[]'::jsonb);
  if jsonb_typeof(p_blocks) <> 'array' then perform booking._err('invalid_param', 'p_blocks on taulukko'); end if;
  if jsonb_array_length(p_blocks) > 50 then perform booking._err('invalid_param', 'Enintään 50 resurssivarausta'); end if;
  v_occ := tstzrange((r.valid_from + r.start_time) at time zone booking._tz(),
                     ((r.valid_from + r.start_time) + make_interval(mins => r.duration_minutes)) at time zone booking._tz(), '[)');

  perform set_config('booking.event_sync', 'on', true);
  delete from booking.event_resource_blocks where rule_id = r.id;

  for b in select value from jsonb_array_elements(p_blocks) loop
    v_i := v_i + 1;
    if jsonb_typeof(b) <> 'object' then perform booking._err('invalid_param', 'Resurssivaraus on objekti'); end if;
    for k in select jsonb_object_keys(b) loop
      if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
    end loop;
    select * into res from booking.resources where id = booking._event_jint(b -> 'resource_id', 'resource_id', 1, 2000000000);
    if not found or not res.active or res.kind not in ('space', 'person') or res.code = 'ei_resurssia' then
      perform booking._err('invalid_resource', 'Valitse aktiivinen tila tai henkilöresurssi');
    end if;
    v_mode := coalesce(nullif(btrim(coalesce(b ->> 'mode', '')), ''), 'exclusive');
    if v_mode not in ('exclusive', 'shared') then perform booking._err('invalid_param', 'mode on exclusive tai shared'); end if;
    v_note := nullif(btrim(coalesce(b ->> 'note', '')), '');
    if v_note is not null and char_length(v_note) > 500 then perform booking._err('invalid_param', 'Muistiinpano on liian pitkä'); end if;
    v_off := null; v_min := null; v_sd := null; v_sc := null; v_ed := null; v_ec := null;
    v_s := nullif(btrim(coalesce(b ->> 'starts_at', '')), ''); v_e := nullif(btrim(coalesce(b ->> 'ends_at', '')), '');
    if b ? 'offset_min' and jsonb_typeof(b -> 'offset_min') <> 'null' then
      -- suhteellinen ajoitus; mahdolliset starts_at/ends_at (laskettu paluuarvo) ohitetaan
      v_off := booking._event_jint(b -> 'offset_min', 'offset_min', -1440, 20160);
      v_min := booking._event_jint(b -> 'minutes', 'minutes', 1, 20160);
      if v_min is null then perform booking._err('invalid_param', 'minutes puuttuu'); end if;
    else
      if v_s is null or v_e is null then perform booking._err('invalid_param', 'Anna joko offset_min + minutes tai starts_at + ends_at'); end if;
      -- 'HH:MM' = kerran päivä; ISO-aikaleima (VVVV-KK-PPTHH:MM[+TZ]) = mikä tahansa päivä (monipäiväinen koulutus)
      if v_s ~ '^\d{1,2}[:.]\d{2}(:00)?$' then v_sd := 0; v_sc := replace(v_s, '.', ':')::time;
      elsif v_s ~ '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}' then
        begin v_ts := v_s::timestamptz; exception when others then perform booking._err('invalid_param', 'Virheellinen starts_at'); end;
        v_local := v_ts at time zone booking._tz(); v_sd := (v_local::date - r.valid_from); v_sc := v_local::time;
      else perform booking._err('invalid_param', 'starts_at muodossa HH:MM tai ISO-aikaleima'); end if;
      if v_e ~ '^\d{1,2}[:.]\d{2}(:00)?$' then v_ed := 0; v_ec := replace(v_e, '.', ':')::time;
        if v_e ~ '^24[:.]00' then v_ed := 1; v_ec := '00:00'; end if;
      elsif v_e ~ '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}' then
        begin v_ts := v_e::timestamptz; exception when others then perform booking._err('invalid_param', 'Virheellinen ends_at'); end;
        v_local := v_ts at time zone booking._tz(); v_ed := (v_local::date - r.valid_from); v_ec := v_local::time;
      else perform booking._err('invalid_param', 'ends_at muodossa HH:MM tai ISO-aikaleima'); end if;
      if v_sd not between -1 and 14 or v_ed not between -1 and 14 then perform booking._err('invalid_param', 'Varaus on liian kaukana kerrasta'); end if;
      if not (v_ed > v_sd or (v_ed = v_sd and v_ec > v_sc)) then perform booking._err('invalid_param', 'Loppu on ennen alkua'); end if;
    end if;
    insert into booking.event_resource_blocks(rule_id, resource_id, mode, offset_min, minutes, start_day, start_clock, end_day, end_clock, note, sort_order)
    values (r.id, res.id, v_mode, v_off, v_min, v_sd, v_sc, v_ed, v_ec, v_note, v_i * 10);
  end loop;

  -- järkevyysraja: varaus enintään vuorokauden ennen kerran alkua / sen loppumisen jälkeen
  if exists (select 1 from booking.event_resource_blocks e
              where e.rule_id = r.id
                and (lower(booking._event_block_range(r.valid_from, r.start_time, e)) < lower(v_occ) - interval '1 day'
                     or upper(booking._event_block_range(r.valid_from, r.start_time, e)) > upper(v_occ) + interval '1 day')) then
    perform booking._err('invalid_param', 'Resurssivaraus saa alkaa enintään vuorokauden ennen kertaa ja loppua vuorokauden sen jälkeen');
  end if;

  perform booking._event_sync_blocks(r.id);
  perform set_config('booking.event_sync', v_prev, true);
  perform booking._event_raise_conflicts(r.id);
  return coalesce((select jsonb_agg(booking._event_block_json(e) order by e.sort_order, e.id) from booking.event_resource_blocks e where e.rule_id = r.id), '[]'::jsonb);
end $$;

create or replace function booking.admin_event_set_channels(p_product_id bigint, p_channels text[])
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v text[];
begin
  perform booking._require_permission('catalog.edit');
  if not exists (select 1 from booking.product_config where product_id = p_product_id) then perform booking._err('not_found', 'Tuotetta ei löydy'); end if;
  select coalesce(array_agg(distinct c order by c), '{}'::text[]) into v from unnest(coalesce(p_channels, '{}'::text[])) c where c is not null;
  if not (v <@ array['shop', 'widget']::text[]) then perform booking._err('invalid_param', 'Kanavat: shop, widget'); end if;
  update booking.product_config set channels = v where product_id = p_product_id and channels is distinct from v;
  return jsonb_build_object('ok', true, 'product_id', p_product_id, 'channels', to_jsonb(v));
end $$;

-- tuotteen kopio: kaikki sarakkeet sellaisenaan (hinnat, ALV, vaihtoehdot, tilasäännöt), paitsi nimi 'Kopio: …', uusi slug, active = false, ei myynnissä
create or replace function booking._product_copy_core(p_product_id bigint) returns kb.products
language plpgsql volatile security definer set search_path = '' as $$
declare
  src kb.products; n kb.products; v_cols text; v_sel text; v_base text; v_slug text; v_i integer := 2; v_new bigint; v_key text;
  v_map jsonb := '{}'::jsonb; x record; v_nv bigint;
begin
  select * into src from kb.products where id = p_product_id;
  if not found then perform booking._err('not_found', 'Tuotetta ei löydy'); end if;
  v_base := left(coalesce(nullif(src.slug, ''), 'tuote'), 74);
  v_base := 'kopio-' || regexp_replace(v_base, '^kopio-', '');
  v_slug := v_base;
  while exists (select 1 from kb.products p where p.slug = v_slug) loop
    v_slug := v_base || '-' || v_i; v_i := v_i + 1;
    if v_i > 500 then perform booking._err('invalid_name', 'Kopiolle ei löydy vapaata osoitetta'); end if;
  end loop;

  select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position),
         string_agg(case c.column_name
                      when 'name' then quote_literal(left('Kopio: ' || src.name, 200))
                      when 'name_en' then quote_literal(left('Copy: ' || coalesce(nullif(src.name_en, ''), src.name), 200))
                      when 'slug' then quote_literal(v_slug)
                      when 'active' then 'false'
                      when 'booking_url' then 'null'
                      when 'external_system' then 'null'
                      when 'external_id' then 'null'
                      when 'created_at' then 'now()'
                      when 'updated_at' then 'now()'
                      else 's.' || quote_ident(c.column_name) end, ', ' order by c.ordinal_position)
    into v_cols, v_sel
    from information_schema.columns c
   where c.table_schema = 'kb' and c.table_name = 'products' and c.is_identity = 'NO' and c.is_generated = 'NEVER' and c.column_name <> 'id';
  execute format('insert into kb.products (%s) select %s from kb.products s where s.id = $1 returning id', v_cols, v_sel) into v_new using src.id;
  select * into n from kb.products where id = v_new;

  -- varausasetukset: sellaisenaan, mutta ei myynnissä / kassassa / jääkaapissa
  select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position),
         string_agg(case c.column_name
                      when 'product_id' then '$2'
                      when 'bookable' then 'false'
                      when 'shop_visible' then 'false'
                      when 'pos_enabled' then 'false'
                      when 'fridge_sale' then 'false'
                      when 'updated_at' then 'now()'
                      else 's.' || quote_ident(c.column_name) end, ', ' order by c.ordinal_position)
    into v_cols, v_sel
    from information_schema.columns c
   where c.table_schema = 'booking' and c.table_name = 'product_config' and c.is_identity = 'NO' and c.is_generated = 'NEVER';
  execute format('insert into booking.product_config (%s) select %s from booking.product_config s where s.product_id = $1', v_cols, v_sel) using src.id, n.id;

  -- hintavaihtoehdot (id-kartta tapahtumakertojen kopiointia varten)
  for x in select id from kb.product_price_variants where product_id = src.id order by id loop
    select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position),
           string_agg(case c.column_name when 'product_id' then '$2' when 'created_at' then 'now()' when 'updated_at' then 'now()'
                        else 's.' || quote_ident(c.column_name) end, ', ' order by c.ordinal_position)
      into v_cols, v_sel
      from information_schema.columns c
     where c.table_schema = 'kb' and c.table_name = 'product_price_variants' and c.is_identity = 'NO' and c.is_generated = 'NEVER' and c.column_name <> 'id';
    execute format('insert into kb.product_price_variants (%s) select %s from kb.product_price_variants s where s.id = $1 returning id', v_cols, v_sel)
      into v_nv using x.id, n.id;
    v_map := v_map || jsonb_build_object(x.id::text, v_nv);
  end loop;

  insert into booking.product_options(product_id, code, name, name_en, description, description_en, sort_order, active)
  select n.id, o.code, o.name, o.name_en, o.description, o.description_en, o.sort_order, o.active
    from booking.product_options o where o.product_id = src.id order by o.id;
  insert into booking.product_space_rules(product_id, leg_no, priority, role, space_id, mode, pool_id, min_persons, max_persons, selection,
                                          requires_blocked_space_id, offset_min, minutes, active, notes)
  select n.id, s.leg_no, s.priority, s.role, s.space_id, s.mode, s.pool_id, s.min_persons, s.max_persons, s.selection,
         s.requires_blocked_space_id, s.offset_min, s.minutes, s.active, s.notes
    from booking.product_space_rules s where s.product_id = src.id order by s.id;
  insert into booking.product_timeline_segments(product_id, seq, kind, label, label_en, minutes, customer_visible)
  select n.id, t.seq, t.kind, t.label, t.label_en, t.minutes, t.customer_visible
    from booking.product_timeline_segments t where t.product_id = src.id order by t.seq;
  insert into booking.product_addon_allow(product_id, addon_id)
  select n.id, a.addon_id from booking.product_addon_allow a where a.product_id = src.id;

  v_key := 'product.' || n.id::text || '.name';
  insert into booking.site_texts (key, lang, class, kind, max_len, source_table, source_pk_col, source_pk, source_column,
                                  published_text, published_version, latest_version, status, published_at)
  values (v_key, 'fi', 'normal', 'plain', 200, 'kb.products', 'id', n.id::text, 'name', n.name, 1, 1, 'published', now()),
         (v_key, 'en', 'normal', 'plain', 200, 'kb.products', 'id', n.id::text, 'name_en', coalesce(n.name_en, ''), 1, 1, 'published', now())
  on conflict (key, lang) do nothing;
  perform booking._texts_register_sources();

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'kb.products', n.id::text, 'ADMIN_COPY', jsonb_build_object('source_product_id', src.id), to_jsonb(n));
  insert into kb.change_log(table_name, row_id, action, actor, old_data, new_data)
  values ('products', n.id, 'insert', 'booking-admin:' || coalesce(auth.uid()::text, 'unknown'), null, to_jsonb(n));
  perform set_config('booking.m158_variant_map', v_map::text, true);
  return n;
end $$;

-- kopioi tapahtumakerran (ja sen resurssivaraukset) uudelle päivälle / tuotteelle; palauttaa uuden kerran id:n
create or replace function booking._event_rule_copy_core(p_rule_id bigint, p_product_id bigint, p_date date, p_active boolean, p_variant_map jsonb)
returns bigint language plpgsql volatile security definer set search_path = '' as $$
declare r booking.schedule_rules; v_id bigint; v_label text;
begin
  select * into r from booking.schedule_rules where id = p_rule_id;
  if not found or r.kind <> 'event' then perform booking._err('not_found', 'Tapahtumakertaa ei löydy'); end if;
  v_label := case when r.label = to_char(r.valid_from, 'DD.MM.YYYY') || ' klo ' || to_char(r.start_time, 'HH24.MI')
                  then to_char(p_date, 'DD.MM.YYYY') || ' klo ' || to_char(r.start_time, 'HH24.MI') else r.label end;
  insert into booking.schedule_rules(product_id, label, label_en, mode, space_id, weekdays, start_time, duration_minutes, valid_from, valid_to,
                                     min_persons, max_persons, price_mode, price_variant_id, included_persons, extra_person_price,
                                     deadline_minutes, active, sort_order, kind, notes)
  values (p_product_id, v_label, r.label_en, r.mode, r.space_id, array[extract(isodow from p_date)::smallint], r.start_time, r.duration_minutes, p_date, p_date,
          r.min_persons, coalesce(r.max_persons, (select pc.max_persons from booking.product_config pc where pc.product_id = r.product_id)),
          r.price_mode, case when r.price_variant_id is null then null
                             when p_variant_map ? r.price_variant_id::text then (p_variant_map ->> r.price_variant_id::text)::bigint
                             when p_product_id = r.product_id then r.price_variant_id end,
          r.included_persons, r.extra_person_price, r.deadline_minutes, p_active, r.sort_order, 'event', r.notes)
  returning id into v_id;
  insert into booking.event_resource_blocks(rule_id, resource_id, mode, offset_min, minutes, start_day, start_clock, end_day, end_clock, note, sort_order)
  select v_id, e.resource_id, e.mode, e.offset_min, e.minutes, e.start_day, e.start_clock, e.end_day, e.end_clock, e.note, e.sort_order
    from booking.event_resource_blocks e where e.rule_id = r.id order by e.sort_order, e.id;
  perform booking._event_rule_pool_sync(v_id);
  perform booking._event_sync_blocks(v_id);
  return v_id;
end $$;

create or replace function booking.admin_product_copy(p_product_id bigint)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare n kb.products;
begin
  perform booking._require_permission('catalog.edit');
  n := booking._product_copy_core(p_product_id);
  return jsonb_build_object('ok', true, 'product_id', n.id, 'slug', n.slug, 'name', n.name, 'name_en', n.name_en);
end $$;

create or replace function booking.admin_event_copy(p_product_id bigint, p_include_rules boolean default false, p_shift_days integer default 0)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare n kb.products; v_map jsonb; x record; v_n integer := 0; v_today date := (now() at time zone booking._tz())::date;
begin
  perform booking._require_permission('catalog.edit');
  if not exists (select 1 from kb.products where id = p_product_id and category in ('event', 'training')) then
    perform booking._err('not_event', 'Tuote ei ole tapahtuma tai koulutus');
  end if;
  if p_shift_days is not null and (p_shift_days < -3650 or p_shift_days > 3650) then perform booking._err('invalid_param', 'Siirto enintään 3650 päivää'); end if;
  n := booking._product_copy_core(p_product_id);
  v_map := coalesce(nullif(current_setting('booking.m158_variant_map', true), ''), '{}')::jsonb;
  if coalesce(p_include_rules, false) then
    for x in select r.id, r.valid_from from booking.schedule_rules r
              where r.product_id = p_product_id and r.kind = 'event' and r.valid_from >= v_today
              order by r.valid_from, r.start_time, r.id loop
      perform booking._event_rule_copy_core(x.id, n.id, x.valid_from + coalesce(p_shift_days, 0), false, v_map);
      v_n := v_n + 1;
    end loop;
    perform booking._texts_register_sources();
  end if;
  return jsonb_build_object('ok', true, 'product_id', n.id, 'slug', n.slug, 'name', n.name, 'rules_copied', v_n);
end $$;

create or replace function booking.admin_event_rule_copy(p_rule_id bigint, p_date date)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r booking.schedule_rules; v_id bigint;
begin
  perform booking._require_permission('catalog.edit');
  select * into r from booking.schedule_rules where id = p_rule_id;
  if not found or r.kind <> 'event' then perform booking._err('not_found', 'Tapahtumakertaa ei löydy'); end if;
  if p_date is null then perform booking._err('invalid_param', 'Päivä puuttuu'); end if;
  v_id := booking._event_rule_copy_core(r.id, r.product_id, p_date, r.active, '{}'::jsonb);
  perform booking._event_raise_conflicts(v_id);
  perform booking._texts_register_sources();
  return booking._event_rule_json(v_id);
end $$;

-- ---------- 5) julkinen: etusivun tapahtumakortit ----------
create or replace function booking.public_events(p_from date default null, p_channel text default 'shop')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_today date := (now() at time zone booking._tz())::date;
  v_from date := greatest(coalesce(p_from, v_today), v_today);
  v_sale boolean := booking._events_sale_enabled();
  v_fi text[] := array['ma', 'ti', 'ke', 'to', 'pe', 'la', 'su'];
begin
  if coalesce(p_channel, 'shop') not in ('shop', 'widget') then perform booking._err('invalid_param', 'Kanava on shop tai widget'); end if;
  return coalesce((
    select jsonb_agg(ev.j order by ev.first_start, ev.pid) from (
      select p.id as pid, min(o.starts_at) as first_start,
             jsonb_build_object(
               'product_id', p.id, 'slug', p.slug, 'name', p.name, 'name_en', p.name_en,
               'description_short', p.short_description, 'description_short_en', p.short_description_en,
               'price', p.price, 'price_text', p.price_text, 'image_path', pc.image_path, 'image_alt', pc.image_alt, 'category', p.category,
               'sale_open', v_sale,
               'occurrences', jsonb_agg(jsonb_build_object(
                  'rule_id', o.rule_id, 'starts_at', o.starts_at, 'ends_at', o.ends_at, 'label', o.label, 'label_en', o.label_en,
                  'time_text', o.time_text, 'time_text_en', o.time_text_en, 'status', o.status,
                  'remaining', case when o.status = 'closed' then null else greatest(o.remaining, 0) end,
                  'price', o.price) order by o.starts_at, o.rule_id)) as j
        from kb.products p
        join booking.product_config pc on pc.product_id = p.id
        cross join lateral (
          select r.id as rule_id, s.starts_at, s.ends_at, r.label, r.label_en, s.remaining,
                 case when v_sale and pc.bookable and pc.lifecycle = 'current' and s.status in ('available', 'full') then s.status else 'closed' end as status,
                 coalesce(s.unit_price, s.base_price) as price,
                 v_fi[extract(isodow from ls)::int] || ' ' || to_char(ls, 'FMDD.FMMM.') || ' klo ' || to_char(ls, 'HH24.MI')
                   || case when ls::date = le::date then '–' || to_char(le, 'HH24.MI')
                           else ' – ' || v_fi[extract(isodow from le)::int] || ' ' || to_char(le, 'FMDD.FMMM.') || ' klo ' || to_char(le, 'HH24.MI') end as time_text,
                 to_char(ls, 'Dy FMDD Mon HH24:MI')
                   || case when ls::date = le::date then '–' || to_char(le, 'HH24:MI') else ' – ' || to_char(le, 'Dy FMDD Mon HH24:MI') end as time_text_en
            from booking.schedule_rules r
            cross join lateral booking._sessions(r.valid_from, r.valid_from, r.product_id, false) s
            cross join lateral (select s.starts_at at time zone booking._tz() as ls, s.ends_at at time zone booking._tz() as le) t
           where r.product_id = p.id and r.kind = 'event' and r.active and r.valid_from >= v_from and r.valid_from <= v_today + 400
             and s.rule_id = r.id and s.ends_at > now()
        ) o
       where p.active and p.category in ('event', 'training')
         and coalesce(p_channel, 'shop') = any (booking._channels_effective(pc.channels, p.category))
       group by p.id, pc.product_id
    ) ev
  ), '[]'::jsonb);
end $$;

-- ---------- 6) oikeudet ----------
do $$
declare f text;
begin
  foreach f in array array['booking._product_copy_core(bigint)', 'booking._event_rule_copy_core(bigint, bigint, date, boolean, jsonb)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  foreach f in array array['booking.admin_event_list(text, boolean)', 'booking.admin_event_rule_upsert(bigint, bigint, jsonb)',
    'booking.admin_event_rule_delete(bigint)', 'booking.admin_event_blocks_set(bigint, jsonb)', 'booking.admin_event_set_channels(bigint, text[])',
    'booking.admin_product_copy(bigint)', 'booking.admin_event_copy(bigint, boolean, integer)', 'booking.admin_event_rule_copy(bigint, date)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
  revoke all on function booking.public_events(date, text) from public;
  grant execute on function booking.public_events(date, text) to anon, authenticated, service_role;
end $$;

comment on function booking.admin_event_list(text, boolean) is 'booking_158: tapahtumat ja koulutukset kertoineen ja resurssivarauksineen (henkilökunta, luku).';
comment on function booking.admin_event_rule_upsert(bigint, bigint, jsonb) is 'booking_158: luo/muokkaa tapahtumakerran (catalog.edit). Virheet: not_event, has_reservations, max_below_sold, max_persons_required, multi_day_training_only, conflict.';
comment on function booking.admin_event_rule_delete(bigint) is 'booking_158: poistaa tapahtumakerran ilman varauksia (catalog.edit). Virheet: has_reservations, has_waitlist.';
comment on function booking.admin_event_blocks_set(bigint, jsonb) is 'booking_158: korvaa kerran resurssivaraukset (catalog.edit). Virhe conflict: details (hint) = [{resource_id,resource_name,starts_at,ends_at,reason}].';
comment on function booking.admin_event_set_channels(bigint, text[]) is 'booking_158: tuotteen myyntikanavat shop/widget (catalog.edit).';
comment on function booking.admin_product_copy(bigint) is 'booking_158: kopioi tuotteen (Kopio: nimi, uusi slug, active=false, ei myynnissä; hinnat, ALV, vaihtoehdot ja tilasäännöt sellaisenaan).';
comment on function booking.admin_event_copy(bigint, boolean, integer) is 'booking_158: kopioi tapahtuman, valinnaisesti tulevat kerrat siirrettynä p_shift_days päivällä (kopiokerrat passiivisia).';
comment on function booking.admin_event_rule_copy(bigint, date) is 'booking_158: kopioi kerran resurssivarauksineen uudelle päivälle (sama tuote).';
comment on function booking.public_events(date, text) is 'booking_158: etusivun tapahtumakortit; tulevat kerrat tiloineen (available/full/closed). Myynnin ollessa kiinni kaikki closed.';

-- ---------- 7) Lovi-sääntö (Joonaksen päätös 1) ----------
create table if not exists booking.m158_lovi_rows (
  psr_id bigint primary key,
  product_id bigint not null,
  deactivated_at timestamptz not null default now()
);
alter table booking.m158_lovi_rows enable row level security;
revoke all on booking.m158_lovi_rows from public, anon, authenticated;
grant all on booking.m158_lovi_rows to service_role;
comment on table booking.m158_lovi_rows is 'booking_158: passivoidut Lovi-rivit (product_space_rules), rollback aktivoi nämä takaisin. Voi poistaa, kun 158 on vakiintunut.';

do $$
declare v_lovi bigint; v_rauni bigint; v_n integer;
begin
  select id into v_lovi from booking.resources where code = 'lovi';
  select id into v_rauni from booking.resources where code = 'rauni';
  if v_lovi is null then raise notice 'booking_158: Lovi-resurssia ei löydy, Lovi-sääntöä ei muutettu'; return; end if;
  -- sallitut: 10 = yhden hengen saunahoito, 11 = saunotus, 12 = syväsaunous (vain kun Rauni suljettu, 1 hlö)
  insert into booking.m158_lovi_rows(psr_id, product_id)
  select s.id, s.product_id from booking.product_space_rules s
   where s.space_id = v_lovi and s.active and s.product_id not in (10, 11, 12)
  on conflict (psr_id) do nothing;
  update booking.product_space_rules s set active = false
    from booking.m158_lovi_rows m where m.psr_id = s.id and s.active;
  get diagnostics v_n = row_count;
  raise notice 'booking_158: Lovi-rivejä passivoitu %', v_n;
  if exists (select 1 from booking.product_space_rules s where s.space_id = v_lovi and s.active and s.product_id in (10, 11, 12)
              and (s.selection <> 'auto_if_blocked' or s.requires_blocked_space_id is distinct from v_rauni or coalesce(s.max_persons, 99) <> 1)) then
    raise notice 'booking_158: HUOM tuotteiden 10–12 Lovi-rivi poikkeaa odotetusta (auto_if_blocked, Rauni, 1 hlö) – tarkista';
  end if;
end $$;
