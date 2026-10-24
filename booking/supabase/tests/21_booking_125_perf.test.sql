-- booking_125: _pool_peak lukee v_claims (sama tulos kuin pisteotanta), _sessions säilyttää lifecycle=current,
-- ja admin_day_bundle palauttaa admin_list_reservations-listan (peruutetut mukana, piilotetut pois).
begin;
set local search_path = extensions, public;
select no_plan();

select ok(
  pg_get_functiondef('booking._pool_peak(bigint,timestamptz,timestamptz,bigint)'::regprocedure) ~ 'booking\.v_claims'
  or pg_get_functiondef('booking._pool_peak(bigint,timestamptz,timestamptz,bigint)'::regprocedure) ~ 'booking\.reservation_legs',
  '_pool_peak lukee v_claims (booking_125) tai sen kaksi lähdettä suoraan (booking_133)');
select ok(
  pg_get_functiondef('booking._sessions(date,date,bigint,boolean)'::regprocedure) ~ 'lifecycle = ''current''',
  '_sessions rajaa bookable-polun lifecycle=current');
select ok(
  pg_get_functiondef('booking.admin_day_bundle(date)'::regprocedure) ~ 'admin_list_reservations',
  'päivänippu käyttää admin_list_reservations-funktiota');
select ok(
  pg_get_functiondef('booking.admin_day_bundle(date)'::regprocedure) !~ 'sp\.code',
  'päivänippu ei viittaa liittämättömään sp-aliasiin');
select has_index('booking', 'reservations', 'reservations_shared_pool_ids_idx', 'jaetun varauksen pooli-indeksi');
select ok(
  not has_function_privilege('anon', 'booking.admin_day_bundle(date)', 'execute'),
  'anon ei saa kutsua päivänippua');
select ok(
  has_function_privilege('authenticated', 'booking.admin_day_bundle(date)', 'execute'),
  'authenticated saa kutsua päivänippua');

select test.rule('Yleinen vuoro la–su 14:00%') as r1400,
       test.rule('Yleinen vuoro la–su 14:30%') as r1430 \gset
select product_id as pid from booking.schedule_rules where id = :r1400 \gset

-- Seuraava lauantai voi olla täynnä tuotannossa. Haetaan kahdeksan viikon sisältä päivä, jossa molempiin vuoroihin mahtuu yksi.
select coalesce((
  select d::date
    from generate_series(test.next_dow(6), test.next_dow(6) + 56, interval '7 days') d
   where exists (
           select 1 from booking.public_availability(:pid, d::date, d::date) a
            where a.rule_id = :r1400 and a.status = 'available' and coalesce(a.remaining, 0) >= 1)
     and exists (
           select 1 from booking.public_availability(:pid, d::date, d::date) a
            where a.rule_id = :r1430 and a.status = 'available' and coalesce(a.remaining, 0) >= 1)
   order by d
   limit 1
), '0001-01-01'::date) as sat \gset
select ok(:'sat'::date > (now() at time zone 'Europe/Helsinki')::date, 'löytyi vapaa lauantai 14:00- ja 14:30-vuorolle');

select test.anon();
select j ->> 'ok' as ok14, j ->> 'token' as tok14 from (select test.pub_book(:r1400, :'sat', 1) as j) s \gset
select j ->> 'ok' as ok1430, j ->> 'token' as tok1430 from (select test.pub_book(:r1430, :'sat', 1) as j) s \gset
select test.logout();
select is(:'ok14'::boolean, true, '14:00 yhden hengen varaus');
select is(:'ok1430'::boolean, true, '14:30 yhden hengen varaus');

-- Saatavuus vastaa booking_14:n kaavaa (lifecycle=current, _pools_remaining kahdesti). Optimointi ei saa muuttaa lukuja.
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
                         and pc.lifecycle = 'current'
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
  select c.rule_id, c.label, c.mode, c.session_date, c.starts_at, c.ends_at,
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
   where c.starts_at - make_interval(mins => c.deadline_minutes) > now()
)
select is(
  (select coalesce(jsonb_agg(to_jsonb(x) order by x.starts_at, x.rule_id), '[]'::jsonb) from booking.public_availability(:pid, :'sat', :'sat') x),
  (select coalesce(jsonb_agg(to_jsonb(l) order by l.starts_at, l.rule_id), '[]'::jsonb) from legacy l),
  'saatavuus vastaa lifecycle=current-kaavaa'
);

-- Huippu = booking_17b:n pisteotanta v_claims-näkymästä (osat ja claim-ikkuna), ei reservations.during.
select ok(exists (
  select 1
    from booking.schedule_rule_pools rp
    join booking._sessions(:'sat'::date, :'sat'::date, :pid, true) s on s.rule_id = rp.rule_id
   where rp.rule_id = :r1400
), '14:00-vuoro ja sen pooli löytyvät');

with win as (
  select rp.pool_id, st.starts_at, st.ends_at
    from booking.schedule_rule_pools rp
    join lateral (
      select s.starts_at, s.ends_at
        from booking._sessions(:'sat'::date, :'sat'::date, :pid, true) s
       where s.rule_id = :r1400
    ) st on true
   where rp.rule_id = :r1400
   limit 1
), rs as (
  select c.claim_start as starts_at, c.claim_end as ends_at, c.persons
    from booking.v_claims c
    cross join win w
   where c.mode = 'shared' and w.pool_id = any (c.pool_ids)
     and booking._res_active(c.status, c.hold_expires_at)
     and c.claim_start < w.ends_at and c.claim_end > w.starts_at
), pts as (
  select w.starts_at as t from win w
  union
  select rs.starts_at
    from rs
    cross join win w
   where rs.starts_at > w.starts_at and rs.starts_at < w.ends_at
)
select is(
  (select booking._pool_peak(w.pool_id, w.starts_at, w.ends_at) from win w),
  (select coalesce(max(l), 0)::integer
     from (select (select coalesce(sum(rs.persons), 0) from rs where rs.starts_at <= pts.t and rs.ends_at > pts.t) as l from pts) x),
  'huippu vastaa v_claims-pisteotantaa'
);

-- Peruutettu jää listaan, piilotettu ei. Vain tämän testin omat varaukset (token), ei päivän muita rivejä.
select (test.res(:'tok1430'::uuid)).id as cid \gset
select (test.res(:'tok14'::uuid)).id as hid \gset
update booking.reservations set status = 'cancelled' where id = :cid;
update booking.reservations set hidden_at = now(), hidden_reason = 'booking_125_test' where id = :hid;

select test.mk_staff('perf-admin@example.com', 'manager') as sid \gset
select test.login(:'sid');
select is((booking.admin_day_bundle(:'sat'::date) -> 'view'), booking.admin_day_view(:'sat'::date), 'päivänippu sisältää saman näkymän');
select ok((booking.admin_day_bundle(:'sat'::date) ? 'site_texts'), 'päivänippu sisältää site_texts');
select is(
  booking.admin_day_bundle(:'sat'::date) -> 'reservations',
  coalesce((
    select jsonb_agg(to_jsonb(x) order by x.starts_at desc, x.reservation_id desc)
      from booking.admin_list_reservations(
        (:'sat'::date::timestamp at time zone booking._tz()),
        ((:'sat'::date + 1)::timestamp at time zone booking._tz()),
        null, null, null, 200, 0, null, null) x
  ), '[]'::jsonb),
  'varauslista on sama kuin admin_list_reservations');
select ok(
  exists (
    select 1 from jsonb_array_elements(booking.admin_day_bundle(:'sat'::date) -> 'reservations') e
     where (e ->> 'reservation_id')::bigint = :cid
       and e ->> 'status' = 'cancelled'
       and e ? 'total_gross'
       and e ? 'option_missing'
       and e ? 'option_name'
  ),
  'peruutettu varaus jää listaan, hoitovalinta ja total_gross mukana');
select ok(
  not exists (
    select 1 from jsonb_array_elements(booking.admin_day_bundle(:'sat'::date) -> 'reservations') e
     where (e ->> 'reservation_id')::bigint = :hid
  ),
  'piilotettu varaus ei näy listassa');
select test.logout();

select * from finish();
rollback;
