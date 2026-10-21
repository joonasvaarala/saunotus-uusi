-- booking_125: saatavuuskyselyn ja hallinnan päivänäkymän nopeutus.
-- Vain funktioiden korvauksia ja indeksejä, ei datamuutoksia.
-- _pool_peak perustuu booking_17b:hen (v_claims: varauksen osat ja claim-ikkunan aikasiirtymä).
-- _sessions perustuu booking_14:een (pc.lifecycle = 'current', kun p_only_bookable).
-- Huippukuorma lasketaan samalla tuloksella yhdellä pyyhkäisyllä, ja _sessions kutsuu
-- _pools_remaining-funktiota kerran riviä kohden.
set local lock_timeout = '5s';

-- Jaetun vuoron poolijäsenyys. Osittainen indeksi vastaa v_claims-haun ehtoa mode = 'shared'
-- (claim-ikkuna ei ole reservations.during, joten during-indeksi ei kelpaa).
create index if not exists reservations_shared_pool_ids_idx on booking.reservations using gin (pool_ids)
  where mode = 'shared';
create index if not exists reservation_legs_shared_pool_ids_idx on booking.reservation_legs using gin (pool_ids)
  where mode = 'shared';

-- Sama tulos kuin booking_17b: pisteotanta claim-ikkunan alussa ja sisäisissä alkuhetkissä.
-- Pyyhkäisy lisää alut ja vähentää loput (loppu on avoin), joten kuorma ei jää päälle loppuneesta claimista.
create or replace function booking._pool_peak(p_pool bigint, p_from timestamptz, p_to timestamptz, p_exclude bigint default null)
 returns integer language sql stable security definer set search_path to ''
as $function$
  with rs as (
    select c.claim_start as s, c.claim_end as e, c.persons as n
      from booking.v_claims c
     where c.mode = 'shared' and p_pool = any (c.pool_ids)
       and booking._res_active(c.status, c.hold_expires_at)
       and c.claim_start < p_to and c.claim_end > p_from
       and c.reservation_id is distinct from p_exclude
  ), base as (
    select coalesce(sum(n), 0) as n from rs where s <= p_from
  ), ev as (
    select e as t, -n as d from rs where e > p_from and e < p_to
    union all
    select s, n from rs where s > p_from and s < p_to
  ), step as (
    select t, sum(d) as d from ev group by t
  ), run as (
    select (select n from base) + sum(d) over (order by t) as load from step
  )
  select coalesce(greatest((select n from base), (select max(load) from run)), 0)::integer
$function$;

-- booking_14:n _sessions, mutta poolin vapaa kapasiteetti lasketaan kerran (pool_remaining).
create or replace function booking._sessions(p_from date, p_to date, p_product_id bigint default null, p_only_bookable boolean default true)
returns table (
  rule_id bigint, product_id bigint, label text, mode text, session_date date,
  starts_at timestamptz, ends_at timestamptz, status text,
  remaining integer, min_persons integer, max_persons integer,
  price_mode text, unit_price numeric, base_price numeric, included_persons integer, extra_person_price numeric,
  sale_closes_at timestamptz
)
language sql stable security definer set search_path to ''
as $function$
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
  ), calc as (
    select c.*,
           case when c.mode = 'exclusive' then null::integer
                else booking._pools_remaining(c.pools, c.starts_at, c.ends_at) end as pool_remaining
      from cand c
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
                  when coalesce(c.pool_remaining, 1000) < c.min_persons
                  then 'full'
                  else 'available' end
         end as status,
         case when c.mode = 'exclusive' then c.max_persons
              else least(coalesce(c.max_persons, 1000), greatest(coalesce(c.pool_remaining, 1000), 0)) end as remaining,
         c.min_persons, c.max_persons, c.price_mode,
         case when c.price_mode = 'per_person' then c.base_price end as unit_price,
         case when c.price_mode <> 'per_person' then c.base_price end as base_price,
         case when c.price_mode = 'fixed_plus_extra' then c.inc end as included_persons,
         case when c.price_mode = 'fixed_plus_extra' then c.extra end as extra_person_price,
         c.starts_at - make_interval(mins => c.deadline_minutes) as sale_closes_at
    from calc c
   order by c.session_date, c.starts_at, c.rule_id
$function$;

-- Yksi kierros päivänäkymän datalle. Varauslista on admin_list_reservations (sama ikkuna ja raja 200):
-- peruutetut ja päättyneet mukana, piilotetut pois, hoitovalinta ja total_gross mukana.
create or replace function booking.admin_day_bundle(p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $fn$
declare
  v_from timestamptz := (p_date::timestamp at time zone booking._tz());
  v_to timestamptz := ((p_date + 1)::timestamp at time zone booking._tz());
begin
  perform booking._require_staff();
  if p_date is null then perform booking._err('invalid_date', 'Päivä puuttuu'); end if;
  return jsonb_build_object(
    'date', p_date,
    'view', booking.admin_day_view(p_date),
    'reservations', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.starts_at desc, x.reservation_id desc)
        from booking.admin_list_reservations(v_from, v_to, null, null, null, 200, 0, null, null) x
    ), '[]'::jsonb),
    'shifts', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.starts_at, s.shift_id, s.staff_name nulls last)
        from booking.admin_day_shifts(p_date) s
    ), '[]'::jsonb),
    'addons', booking.admin_list_addons(),
    'options', booking.admin_list_product_options(null),
    'extras', booking.admin_day_extras(p_date),
    'site_texts', booking.public_get_site_texts(null)
  );
end $fn$;

revoke all on function booking.admin_day_bundle(date) from public, anon, authenticated;
grant execute on function booking.admin_day_bundle(date) to authenticated, service_role;

comment on function booking.admin_day_bundle(date) is
  'Hallinta, vain luku: päivänäkymän data yhdellä kutsulla (näkymä, admin_list_reservations, työvuorot, lisäpalvelut, hoitovalinnat, tapahtumat/tuotto, sivutekstit).';
