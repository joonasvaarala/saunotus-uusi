-- booking_125: saatavuus- ja päivänäkymäregressio (vanha vs uusi tulos)
begin;
set local search_path = extensions, public;
select no_plan();

select test.next_dow(6) as sat,
       test.rule('Yleinen vuoro la–su 14:00%') as r1400,
       test.rule('Yleinen vuoro la–su 14:30%') as r1430 \gset
select product_id as pid from booking.schedule_rules where id = :r1400 \gset

select test.anon();
select is((test.pub_book(:r1400, :'sat', 6) ->> 'ok')::boolean, true, '14:00 täyteen');
select is((test.pub_book(:r1430, :'sat', 4) ->> 'ok')::boolean, true, '14:30 osittain täyteen');
select test.logout();

with legacy as (
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
      join booking.product_config pc on pc.product_id = r.product_id and pc.bookable and pc.shop_visible
      left join kb.product_price_variants v on v.id = r.price_variant_id
      cross join lateral generate_series(:'sat'::timestamp, :'sat'::timestamp, interval '1 day') as d(d)
     where r.active
       and r.product_id = :pid
       and extract(isodow from d.d)::smallint = any (r.weekdays)
       and (r.valid_from is null or d.d::date >= r.valid_from)
       and (r.valid_to is null or d.d::date <= r.valid_to)
       and (v.id is null or (v.active and (v.valid_from is null or d.d::date >= v.valid_from) and (v.valid_to is null or d.d::date <= v.valid_to)))
       and (p.valid_from is null or d.d::date >= p.valid_from)
       and (p.valid_to is null or d.d::date <= p.valid_to)
  )
  select c.rule_id, c.product_id, c.label, c.mode, c.session_date, c.starts_at, c.ends_at,
         case
           when c.starts_at - make_interval(mins => c.deadline_minutes) <= now() then 'closed'
           when exists (select 1 from booking.space_blocks b where b.active and b.space_id = c.space_id and b.during && tstzrange(c.starts_at, c.ends_at, '[)')) then 'unavailable'
           when c.mode = 'exclusive' then
             case when exists (select 1 from booking.reservations x where x.space_id = c.space_id and booking._res_active(x.status, x.hold_expires_at) and x.during && tstzrange(c.starts_at, c.ends_at, '[)'))
                  then 'unavailable' else 'available' end
           else
             case when exists (select 1 from booking.reservations x where x.space_id = c.space_id and x.mode = 'exclusive' and booking._res_active(x.status, x.hold_expires_at) and x.during && tstzrange(c.starts_at, c.ends_at, '[)'))
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
         case when c.price_mode = 'fixed_plus_extra' then c.extra end as extra_person_price
    from cand c
)
select is(
  (select coalesce(jsonb_agg(to_jsonb(x) order by x.starts_at, x.rule_id), '[]'::jsonb) from booking.public_availability(:pid, :'sat', :'sat') x),
  (select coalesce(jsonb_agg(to_jsonb(l) order by l.starts_at, l.rule_id), '[]'::jsonb) from legacy l),
  'saatavuus: vanha ja uusi tulos täsmäävät'
);

select test.mk_staff('perf-admin@example.com', 'manager') as sid \gset
select test.login(:'sid');
select is((booking.admin_day_bundle(:'sat'::date) -> 'view'), booking.admin_day_view(:'sat'::date), 'päiväbundle sisältää saman näkymän');
select ok((booking.admin_day_bundle(:'sat'::date) ? 'site_texts'), 'päiväbundle sisältää site_texts');
select test.logout();

select * from finish();
rollback;
