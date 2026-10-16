-- APPLIED 2026-10-16 klo 23.35 (Europe/Helsinki): versio 20261016203530 (booking_14_lifecycle) via apply_migration; sama SQL kuin tässä tiedostossa. Generoitu gen/gen_14_16.py:llä.
-- 14_lifecycle (Joonas hyväksyi ajon chatissa 16.10.2026; schema booking; ei kb-/public-muutoksia)
-- Sisältö (DESIGN_resources_v2.md B1, §0b–§0e; lähde: model_v2.py):
--  * product_config: lifecycle (current|old), resource_class (resourced|text_only|none), closure_group, duration_minutes, required_skill (FK tulee booking_16:ssa),
--    therapists_needed, therapist_offset_min, therapist_minutes. Kaikki oletuksilla -> nykyisten 10 rivin toiminta ei muutu.
--  * product_config-rivit kaikille kb-tuotteille joilla ei vielä ollut (40 kpl): lifecycle/resource_class/kesto/max_persons mallin mukaan.
--    Uudet rivit: shop_visible=false; bookable=true vain old+resourced (ei schedule_rules -> ei myytävissä missään); current-rivit bookable=false kunnes säännöt tulevat.
--  * max_persons: kb 25 -> 18, kb 26/48/49 -> 20 (product_config JA schedule_rules, jotta julkinen polku (min(sääntö, config)) noudattaa rajaa).
--    Muut: tapahtumat 9/32/33/34 = 8, 27/28/30/31 = 8, 29 = 15, 10/11/12 = 4 (Rauni), 7/8 = 6, 13 = 6 (min 3). kb 29 hinta jää kb:hen (EI muuteta).
--  * Kauppa/julkiset polut rajataan lifecycle='current': public_catalog, public_availability, _sessions (kun p_only_bookable), _resolve_session.
--    (kb.products.active-ohitus vanhoille tuodaan vasta booking_17:ssä: admin_create_old_booking.)
--  * admin_update_product_config: allow-lista laajennettu uusilla kentillä (oikeus catalog.edit). admin_list_products palauttaa uudet kentät automaattisesti (config = to_jsonb(pc)).
--  * EI mukana (DESIGN D1 -> booking_17): admin_create_old_booking, legit, v_claims, _resolve_space.
-- Idempotentti: add column if not exists, constraintit DO-lohkoissa, INSERT ... ON CONFLICT DO NOTHING, UPDATEt toistettavia.
set local search_path = booking, extensions, public;

alter table booking.product_config
  add column if not exists lifecycle text not null default 'current',
  add column if not exists resource_class text not null default 'resourced',
  add column if not exists closure_group text,
  add column if not exists duration_minutes integer,
  add column if not exists required_skill text,
  add column if not exists therapists_needed integer not null default 1,
  add column if not exists therapist_offset_min integer not null default 0,
  add column if not exists therapist_minutes integer;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'product_config_lifecycle_check' and conrelid = 'booking.product_config'::regclass) then
    alter table booking.product_config add constraint product_config_lifecycle_check check (lifecycle in ('current','old'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'product_config_resource_class_check' and conrelid = 'booking.product_config'::regclass) then
    alter table booking.product_config add constraint product_config_resource_class_check check (resource_class in ('resourced','text_only','none'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'product_config_duration_check' and conrelid = 'booking.product_config'::regclass) then
    alter table booking.product_config add constraint product_config_duration_check check (duration_minutes is null or duration_minutes > 0);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'product_config_therapist_check' and conrelid = 'booking.product_config'::regclass) then
    alter table booking.product_config add constraint product_config_therapist_check
      check (therapists_needed >= 1 and therapist_offset_min >= 0 and (therapist_minutes is null or therapist_minutes > 0));
  end if;
end $$;

create index if not exists product_config_lifecycle_idx on booking.product_config (lifecycle);

-- nykyiset 10 riviä: kesto + resource_class (kaikki 'resourced', lifecycle 'current' = oletus)
update booking.product_config pc set duration_minutes = v.d, resource_class = v.rc, closure_group = v.cg
  from (values
  (1, 120, 'resourced', null),
  (2, 180, 'resourced', null),
  (3, 180, 'resourced', null),
  (4, 180, 'resourced', null),
  (5, 180, 'resourced', null),
  (6, 60, 'resourced', null),
  (25, 120, 'resourced', null),
  (26, 120, 'resourced', null),
  (48, 120, 'resourced', null),
  (49, 120, 'resourced', null)
  ) v(id, d, rc, cg)
 where pc.product_id = v.id and pc.duration_minutes is null;

-- rivit kaikille puuttuville kb-tuotteille (kb:tä vain luetaan; FK product_config_product_id_fkey)
insert into booking.product_config
  (product_id, sale_kind, bookable, shop_visible, sort_order, min_persons, max_persons, lifecycle, resource_class, closure_group, duration_minutes)
select v.id, v.sk, v.bk, v.sv, v.so, v.mn, v.mx, v.lc, v.rc, v.cg, v.d
  from (values
  (7, 'other', false, false, 207, 1, 6, 'current', 'resourced', null, 120),
  (8, 'other', false, false, 208, 1, 6, 'current', 'resourced', null, 20),
  (9, 'other', false, false, 209, 1, 8, 'current', 'resourced', null, 90),
  (10, 'other', false, false, 210, 1, 4, 'current', 'resourced', null, 60),
  (11, 'other', false, false, 211, 1, 4, 'current', 'resourced', 'perinnesaunotus', 120),
  (12, 'other', false, false, 212, 1, 4, 'current', 'resourced', 'perinnesaunotus', 180),
  (13, 'other', true, false, 1013, 3, 6, 'old', 'resourced', null, 180),
  (14, 'other', true, false, 1014, 1, null, 'old', 'resourced', 'perinnesaunotus', 60),
  (15, 'other', true, false, 1015, 1, null, 'old', 'resourced', 'perinnesaunotus', 90),
  (16, 'other', true, false, 1016, 1, null, 'old', 'resourced', null, 30),
  (17, 'other', true, false, 1017, 1, null, 'old', 'resourced', null, 60),
  (18, 'other', true, false, 1018, 1, null, 'old', 'resourced', null, 30),
  (19, 'other', true, false, 1019, 1, null, 'old', 'resourced', null, 30),
  (20, 'other', true, false, 1020, 1, null, 'old', 'resourced', null, 60),
  (21, 'other', true, false, 1021, 1, null, 'old', 'resourced', null, 60),
  (22, 'other', true, false, 1022, 1, null, 'old', 'resourced', null, 30),
  (23, 'other', true, false, 1023, 1, null, 'old', 'resourced', 'perinnesaunotus', 90),
  (24, 'other', true, false, 1024, 1, null, 'old', 'resourced', null, 30),
  (27, 'other', false, false, 227, 1, 8, 'current', 'resourced', null, 60),
  (28, 'other', false, false, 228, 1, 8, 'current', 'resourced', null, 90),
  (29, 'other', false, false, 229, 1, 15, 'current', 'resourced', null, 180),
  (30, 'other', false, false, 230, 1, 8, 'current', 'resourced', null, 120),
  (31, 'other', false, false, 231, 1, 8, 'current', 'resourced', null, 120),
  (32, 'other', false, false, 232, 1, 8, 'current', 'resourced', null, 180),
  (33, 'other', false, false, 233, 1, 8, 'current', 'resourced', null, 240),
  (34, 'other', false, false, 234, 1, 8, 'current', 'resourced', null, 540),
  (35, 'other', false, false, 1035, 1, null, 'old', 'text_only', null, null),
  (36, 'other', false, false, 236, 1, null, 'current', 'text_only', null, null),
  (37, 'other', false, false, 1037, 1, null, 'old', 'text_only', null, null),
  (38, 'other', false, false, 238, 1, null, 'current', 'none', null, null),
  (39, 'other', false, false, 239, 1, null, 'current', 'none', null, null),
  (40, 'other', false, false, 240, 1, null, 'current', 'none', null, null),
  (41, 'other', false, false, 241, 1, null, 'current', 'none', null, null),
  (42, 'other', false, false, 242, 1, null, 'current', 'none', null, null),
  (43, 'other', false, false, 243, 1, null, 'current', 'none', null, null),
  (44, 'other', false, false, 244, 1, null, 'current', 'none', null, null),
  (45, 'other', false, false, 245, 1, null, 'current', 'none', null, null),
  (46, 'other', false, false, 246, 1, null, 'current', 'none', null, null),
  (47, 'other', false, false, 247, 1, null, 'current', 'none', null, null),
  (50, 'other', false, false, 250, 1, null, 'current', 'text_only', null, null)
  ) v(id, sk, bk, sv, so, mn, mx, lc, rc, cg, d)
  join kb.products p on p.id = v.id
on conflict (product_id) do nothing;

-- henkilömäärärajat (Joonas): oma savusaunavuoro 18, jälkilöylyt (kb 26/48/49) 20
update booking.product_config set max_persons = 18 where product_id = 25 and max_persons is distinct from 18;
update booking.product_config set max_persons = 20 where product_id in (26, 48, 49) and max_persons is distinct from 20;
update booking.schedule_rules set max_persons = 18 where product_id = 25 and max_persons is distinct from 18;
update booking.schedule_rules set max_persons = 20 where product_id in (26, 48, 49) and max_persons is distinct from 20;

-- ---------- julkisten polkujen rajaus: vain lifecycle = 'current' (rungot samat kuin ennen; muutos yksi ehto) ----------
CREATE OR REPLACE FUNCTION booking.public_catalog()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'slug', p.slug, 'name', p.name, 'name_en', p.name_en,
      'description', p.description, 'description_en', p.description_en,
      'category', p.category, 'sale_kind', pc.sale_kind,
      'price', p.price, 'price_type', p.price_type, 'price_text', p.price_text,
      'duration_text', p.duration_text, 'duration_minutes', p.duration_minutes,
      'min_persons', pc.min_persons, 'max_persons', pc.max_persons
    ) order by pc.sort_order, p.id), '[]'::jsonb)
  from booking.product_config pc
  join kb.products p on p.id = pc.product_id and p.active
  where pc.bookable and pc.shop_visible and pc.lifecycle = 'current'
    and exists (select 1 from booking.schedule_rules r where r.product_id = p.id and r.active)
$function$
;

CREATE OR REPLACE FUNCTION booking.public_availability(p_product_id bigint, p_from date, p_to date)
 RETURNS TABLE(rule_id bigint, label text, mode text, session_date date, starts_at timestamp with time zone, ends_at timestamp with time zone, status text, remaining integer, min_persons integer, max_persons integer, price_mode text, unit_price numeric, base_price numeric, included_persons integer, extra_person_price numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_product_id is null or p_from is null or p_to is null or p_to < p_from or p_to - p_from > 92 then
    perform booking._err('bad_range', 'Virheellinen päiväväli (enintään 92 päivää)');
  end if;
  if not exists (select 1 from booking.product_config pc where pc.product_id = p_product_id and pc.bookable and pc.shop_visible and pc.lifecycle = 'current') then
    return;
  end if;
  return query
    select s.rule_id, s.label, s.mode, s.session_date, s.starts_at, s.ends_at,
           case when s.status = 'closed' then 'closed' else s.status end,
           s.remaining, s.min_persons, s.max_persons, s.price_mode, s.unit_price, s.base_price, s.included_persons, s.extra_person_price
      from booking._sessions(greatest(p_from, (now() at time zone booking._tz())::date),
                             least(p_to, (now() at time zone booking._tz())::date + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int),
                             p_product_id, true) s
     where s.status <> 'closed';
end $function$
;

CREATE OR REPLACE FUNCTION booking._sessions(p_from date, p_to date, p_product_id bigint DEFAULT NULL::bigint, p_only_bookable boolean DEFAULT true)
 RETURNS TABLE(rule_id bigint, product_id bigint, label text, mode text, session_date date, starts_at timestamp with time zone, ends_at timestamp with time zone, status text, remaining integer, min_persons integer, max_persons integer, price_mode text, unit_price numeric, base_price numeric, included_persons integer, extra_person_price numeric, sale_closes_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with cand as (
    select r.id as rule_id, r.product_id, r.label, r.mode, d.d::date as session_date, r.space_id,
           r.min_persons, r.max_persons, r.price_mode, r.deadline_minutes, r.sort_order,
           r.included_persons as r_inc, r.extra_person_price as r_extra,
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
     where r.active
       and (p_product_id is null or r.product_id = p_product_id)
       and extract(isodow from d.d)::smallint = any (r.weekdays)
       and (r.valid_from is null or d.d::date >= r.valid_from)
       and (r.valid_to is null or d.d::date <= r.valid_to)
       and (v.id is null or (v.active
            and (v.valid_from is null or d.d::date >= v.valid_from)
            and (v.valid_to is null or d.d::date <= v.valid_to)))
       and (p.valid_from is null or d.d::date >= p.valid_from)
       and (p.valid_to is null or d.d::date <= p.valid_to)
  )
  select c.rule_id, c.product_id, c.label, c.mode, c.session_date, c.starts_at, c.ends_at,
         case
           when c.starts_at - make_interval(mins => c.deadline_minutes) <= now() then 'closed'
           when exists (select 1 from booking.space_blocks b where b.active and b.space_id = c.space_id
                         and b.during && tstzrange(c.starts_at, c.ends_at, '[)')) then 'unavailable'
           when c.mode = 'exclusive' then
             case when exists (select 1 from booking.reservations x where x.space_id = c.space_id
                                and booking._res_active(x.status, x.hold_expires_at)
                                and x.during && tstzrange(c.starts_at, c.ends_at, '[)'))
                  then 'unavailable' else 'available' end
           else
             case when exists (select 1 from booking.reservations x where x.space_id = c.space_id
                                and x.mode = 'exclusive' and booking._res_active(x.status, x.hold_expires_at)
                                and x.during && tstzrange(c.starts_at, c.ends_at, '[)'))
                  then 'unavailable'
                  when coalesce(booking._pools_remaining(c.pools, c.starts_at, c.ends_at), 1000) < c.min_persons
                  then 'full'
                  else 'available' end
         end as status,
         case when c.mode = 'exclusive' then c.max_persons
              else least(coalesce(c.max_persons, 1000), greatest(coalesce(booking._pools_remaining(c.pools, c.starts_at, c.ends_at), 1000), 0)) end as remaining,
         c.min_persons, c.max_persons, c.price_mode,
         case when c.price_mode = 'per_person' then c.base_price end as unit_price,
         case when c.price_mode <> 'per_person' then c.base_price end as base_price,
         case when c.price_mode = 'fixed_plus_extra' then c.inc end as included_persons,
         case when c.price_mode = 'fixed_plus_extra' then c.extra end as extra_person_price,
         c.starts_at - make_interval(mins => c.deadline_minutes) as sale_closes_at
    from cand c
   order by c.session_date, c.starts_at, c.rule_id
$function$
;

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
end $function$
;

-- ---------- hallinta: product_config-kenttien muokkaus (oikeus catalog.edit) ----------
create or replace function booking.admin_update_product_config(p_product_id bigint, p_patch jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $fn$
declare allowed text[] := array['bookable','shop_visible','sort_order','min_persons','max_persons','notes',
                                'lifecycle','resource_class','closure_group','duration_minutes','required_skill',
                                'therapists_needed','therapist_offset_min','therapist_minutes']; k text;
begin
  perform booking._require_permission('catalog.edit');
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
  update booking.product_config set
    bookable = case when p_patch ? 'bookable' then (p_patch ->> 'bookable')::boolean else bookable end,
    shop_visible = case when p_patch ? 'shop_visible' then (p_patch ->> 'shop_visible')::boolean else shop_visible end,
    sort_order = case when p_patch ? 'sort_order' then (p_patch ->> 'sort_order')::int else sort_order end,
    min_persons = case when p_patch ? 'min_persons' then (p_patch ->> 'min_persons')::int else min_persons end,
    max_persons = case when p_patch ? 'max_persons' then (p_patch ->> 'max_persons')::int else max_persons end,
    notes = case when p_patch ? 'notes' then p_patch ->> 'notes' else notes end,
    lifecycle = case when p_patch ? 'lifecycle' then p_patch ->> 'lifecycle' else lifecycle end,
    resource_class = case when p_patch ? 'resource_class' then p_patch ->> 'resource_class' else resource_class end,
    closure_group = case when p_patch ? 'closure_group' then nullif(btrim(p_patch ->> 'closure_group'), '') else closure_group end,
    duration_minutes = case when p_patch ? 'duration_minutes' then (p_patch ->> 'duration_minutes')::int else duration_minutes end,
    required_skill = case when p_patch ? 'required_skill' then nullif(btrim(p_patch ->> 'required_skill'), '') else required_skill end,
    therapists_needed = case when p_patch ? 'therapists_needed' then (p_patch ->> 'therapists_needed')::int else therapists_needed end,
    therapist_offset_min = case when p_patch ? 'therapist_offset_min' then (p_patch ->> 'therapist_offset_min')::int else therapist_offset_min end,
    therapist_minutes = case when p_patch ? 'therapist_minutes' then (p_patch ->> 'therapist_minutes')::int else therapist_minutes end
   where product_id = p_product_id;
  if not found then perform booking._err('not_found', 'Tuotteella ei ole varauskonfiguraatiota'); end if;
  return jsonb_build_object('ok', true);
end $fn$;
