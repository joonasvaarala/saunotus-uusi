-- booking_125: saatavuuskyselyn, hallinnan päivänäkymän ja etusivun datapolun nopeutus.
-- Vain lisäyksiä / korvauksia, ei datamuutoksia.
set local lock_timeout = '5s';

-- Claims-taulujen indeksit: kapasiteettikysely etsii aktiiviset shared-varaukset poolin ja aikavälin perusteella.
create index if not exists reservations_shared_pool_ids_idx on booking.reservations using gin (pool_ids)
  where mode = 'shared' and status in ('pending', 'confirmed');
create index if not exists reservations_shared_during_idx on booking.reservations using gist (during)
  where mode = 'shared' and status in ('pending', 'confirmed');
create index if not exists reservation_legs_shared_pool_ids_idx on booking.reservation_legs using gin (pool_ids)
  where mode = 'shared';
create index if not exists reservation_legs_shared_during_idx on booking.reservation_legs using gist (during)
  where mode = 'shared';

-- Kapasiteetin huippukuorma yhdellä hakurakenteella. Sama tulos kuin ennen, mutta sijoitettu index-ystävälliseen muotoon.
create or replace function booking._pool_peak(p_pool bigint, p_from timestamptz, p_to timestamptz, p_exclude bigint default null)
returns integer language sql stable security definer set search_path = '' as $$
  with rs as (
    select r.starts_at, r.ends_at, r.persons
      from booking.reservations r
     where r.mode = 'shared' and p_pool = any (r.pool_ids)
       and booking._res_active(r.status, r.hold_expires_at)
       and r.during && tstzrange(p_from, p_to, '[)')
       and r.id is distinct from p_exclude
  ), pts as (
    select p_from as t
    union
    select starts_at from rs where starts_at > p_from and starts_at < p_to
  )
  select coalesce(max(l), 0)::integer
    from (select (select coalesce(sum(rs.persons), 0) from rs where rs.starts_at <= pts.t and rs.ends_at > pts.t) as l from pts) x
$$;

-- Vapaa tila: pienin (kapasiteetti - huippukuorma) kaikista pooleista. null = ei pooleja.
create or replace function booking._pools_remaining(p_pools bigint[], p_from timestamptz, p_to timestamptz, p_exclude bigint default null)
returns integer language sql stable security definer set search_path = '' as $$
  select min(res.capacity - booking._pool_peak(res.id, p_from, p_to, p_exclude))::integer
    from booking.resources res where res.id = any (p_pools)
$$;

-- _sessions: laske vapaa kapasiteetti kerran per rivi, älä kahdesti; status käyttää samaa arvoa.
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
  ), rem as (
    select c.*, case when c.mode = 'exclusive' then c.max_persons else booking._pools_remaining(c.pools, c.starts_at, c.ends_at) end as pool_remaining
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
    from rem c
   order by c.session_date, c.starts_at, c.rule_id
$$;

create or replace function booking.admin_day_bundle(p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $fn$
declare
  v_from timestamptz := p_date::timestamp at time zone 'Europe/Helsinki';
  v_to timestamptz := (p_date + 1)::timestamp at time zone 'Europe/Helsinki';
begin
  perform booking._require_staff();
  if p_date is null then perform booking._err('invalid_date', 'Päivä puuttuu'); end if;
  return jsonb_build_object(
    'date', p_date,
    'view', booking.admin_day_view(p_date),
    'reservations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'reservation_id', r.id, 'order_id', o.id, 'order_no', o.order_no, 'status', r.status, 'payment_status', o.payment_status,
        'product_name', coalesce(it.product_name, p.name), 'mode', r.mode, 'starts_at', r.starts_at, 'ends_at', r.ends_at,
        'persons', r.persons, 'customer_name', c.name, 'customer_email', c.email, 'customer_phone', c.phone, 'rule_id', r.rule_id, 'notes', r.notes,
        'annual_card', r.annual_card_id is not null, 'hold_expires_at', r.hold_expires_at,
        'source', coalesce(r.external_source, 'native'), 'external_id', r.external_id,
        'customer_kind', o.customer_kind, 'company', case when o.customer_kind <> 'private' then coalesce(o.billing ->> 'company', c.company) end,
        'space_code', sp.code, 'lifecycle', pcf.lifecycle, 'quota_exempt', r.quota_exempt, 'override_reason', r.override_reason,
        'therapist_missing', r.therapist_missing, 'therapist_exception_at', r.therapist_exception_at, 'therapist_exception_note', r.therapist_exception_note,
        'therapist_missing_open', (r.therapist_missing and r.therapist_exception_at is null and not exists (select 1 from booking.reservation_legs tl where tl.reservation_id = r.id and tl.role = 'therapist')),
        'claim_offset_min', r.claim_offset_min, 'claim_minutes', r.claim_minutes, 'parent_reservation_id', r.parent_reservation_id,
        'legs', coalesce((select jsonb_agg(jsonb_build_object('leg_id', l.id, 'role', l.role, 'resource_code', lr.code, 'starts_at', l.starts_at, 'ends_at', l.ends_at,
                                  'persons', l.persons, 'skill', l.skill) order by l.starts_at, l.id)
                            from booking.reservation_legs l join booking.resources lr on lr.id = l.resource_id where l.reservation_id = r.id), '[]'::jsonb),
        'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', ai.addon_id, 'code', (select a2.code from booking.addons a2 where a2.id = ai.addon_id), 'name', ai.product_name, 'quantity', ai.quantity) order by ai.id)
                              from booking.order_items ai where ai.parent_item_id = r.order_item_id and ai.kind = 'addon'), '[]'::jsonb))
        order by r.starts_at, r.id)
        from booking.reservations r join booking.orders o on o.id = r.order_id
        left join booking.order_items it on it.id = r.order_item_id left join kb.products p on p.id = r.product_id
        left join booking.product_config pcf on pcf.product_id = r.product_id
        left join booking.customers c on c.id = o.customer_id
        where r.starts_at < v_to and r.ends_at > v_from and booking._res_active(r.status, r.hold_expires_at)), '[]'::jsonb),
    'shifts', coalesce((select jsonb_agg(to_jsonb(s) order by s.starts_at, s.shift_id) from booking.admin_day_shifts(p_date) s), '[]'::jsonb),
    'addons', booking.admin_list_addons(),
    'options', booking.admin_list_product_options(),
    'extras', booking.admin_day_extras(p_date),
    'site_texts', booking.public_get_site_texts(null)
  );
end $fn$;

revoke all on function booking.admin_day_bundle(date) from public, anon, authenticated;
grant execute on function booking.admin_day_bundle(date) to authenticated, service_role;

