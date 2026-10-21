-- Rollback booking_125: palauttaa saatavuus- ja päivänäkymälogiikan edellisen version.
set local lock_timeout = '5s';

drop function if exists booking.admin_day_bundle(date);
drop index if exists booking.reservations_shared_pool_ids_idx;
drop index if exists booking.reservations_shared_during_idx;
drop index if exists booking.reservation_legs_shared_pool_ids_idx;
drop index if exists booking.reservation_legs_shared_during_idx;

create or replace function booking._pool_peak(p_pool bigint, p_from timestamptz, p_to timestamptz, p_exclude bigint default null)
returns integer language sql stable security definer set search_path = '' as $$
  with rs as (
    select r.starts_at, r.ends_at, r.persons
      from booking.reservations r
     where r.mode = 'shared' and p_pool = any (r.pool_ids)
       and booking._res_active(r.status, r.hold_expires_at)
       and r.starts_at < p_to and r.ends_at > p_from
       and r.id is distinct from p_exclude
  ), pts as (
    select p_from as t
    union
    select starts_at from rs where starts_at > p_from and starts_at < p_to
  )
  select coalesce(max(l), 0)::integer
    from (select (select coalesce(sum(rs.persons), 0) from rs where rs.starts_at <= pts.t and rs.ends_at > pts.t) as l from pts) x
$$;

create or replace function booking._pools_remaining(p_pools bigint[], p_from timestamptz, p_to timestamptz, p_exclude bigint default null)
returns integer language sql stable security definer set search_path = '' as $$
  select min(res.capacity - booking._pool_peak(res.id, p_from, p_to, p_exclude))::integer
    from booking.resources res where res.id = any (p_pools)
$$;

create or replace function booking._sessions(p_from date, p_to date, p_product_id bigint default null, p_only_bookable boolean default true)
returns table (
  rule_id bigint, product_id bigint, label text, mode text, session_date date,
  starts_at timestamptz, ends_at timestamptz, status text,
  remaining integer, min_persons integer, max_persons integer,
  price_mode text, unit_price numeric, base_price numeric, included_persons integer, extra_person_price numeric,
  sale_closes_at timestamptz
)
language sql stable security definer set search_path = '' as $$
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
$$;
