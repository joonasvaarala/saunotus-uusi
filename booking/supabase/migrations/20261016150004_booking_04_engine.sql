-- =====================================================================
-- booking 04: varausmoottori – päällekkäisyys- ja kapasiteettisäännöt tietokantatasolla
--
-- Invariantit (ylläpidetään AINA triggerillä reservations_validate, riippumatta siitä mitä kautta rivi kirjoitetaan):
--  1. Yksityisvuoro (mode='exclusive') ei voi olla päällekkäin minkään muun aktiivisen varauksen kanssa samassa tilassa.
--  2. Yleinen vuoro (mode='shared') ei voi olla päällekkäin aktiivisen yksityisvuoron kanssa.
--     => yksi henkilökin yleisellä vuorolla estää yksityisvuoron samalle ajalle ja päinvastoin.
--  3. Yleisten vuorojen samanaikainen henkilömäärä jokaisessa kapasiteettipoolissa <= pool.capacity (huippukuorma
--     varauksen ajalta: limittäiset vuorot lasketaan yhteen).
--  4. Sulku (space_blocks) estää kaiken.
-- Kilpailutilanteet: jokainen kirjoitus ottaa tila-kohtaisen pg_advisory_xact_lock-lukon ennen tarkistusta,
-- joten kaksi samanaikaista varausta serialisoituvat. Lisäksi exclusion constraint estää yksityisvuorojen
-- päällekkäisyyden vaikka trigger ohitettaisiin.
-- Aktiivinen varaus = status 'confirmed' TAI 'pending' jonka hold_expires_at > now().
-- =====================================================================
set local search_path = booking, extensions, public;

create or replace function booking._res_active(p_status text, p_hold timestamptz)
returns boolean language sql stable set search_path = '' as $$
  select p_status = 'confirmed' or (p_status = 'pending' and p_hold is not null and p_hold > now())
$$;

create or replace function booking._tz() returns text language sql immutable set search_path = '' as $$ select 'Europe/Helsinki' $$;

create or replace function booking._setting(p_key text, p_default jsonb default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((select s.value from booking.settings s where s.key = p_key), p_default)
$$;

-- ---------- pitojen vanhentaminen ----------
-- Vapauttaa vanhentuneet pending-varaukset (ja niiden maksamattomat tilaukset).
create or replace function booking._expire_holds(p_space bigint default null, p_except bigint default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  with e as (
    update booking.reservations r
       set status = 'expired', cancelled_at = coalesce(r.cancelled_at, now()), cancel_reason = coalesce(r.cancel_reason, 'hold_expired')
     where r.status = 'pending' and r.hold_expires_at <= now()
       and (p_space is null or r.space_id = p_space)
       and r.id is distinct from p_except
    returning r.order_id
  ), o as (
    update booking.orders o set status = 'expired'
     where o.id in (select order_id from e) and o.status = 'pending' and o.payment_status in ('unpaid','pending')
       and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status in ('pending','confirmed'))
    returning 1
  )
  select count(*) into n from e;
  return n;
end $$;

-- Ajastettava (pg_cron / Edge Function / service_role): vanhentaa pitoja ja siivoaa rate limit -lokin
create or replace function booking.expire_holds()
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  n := booking._expire_holds(null);
  delete from booking.rate_limit_hits where at < now() - interval '2 days';
  return n;
end $$;

-- ---------- kapasiteetti ----------
-- Samanaikaisten henkilöiden huippumäärä poolissa välillä [p_from, p_to). Laskee vain aktiiviset yleiset varaukset.
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

-- Vapaa tila: pienin (kapasiteetti - huippukuorma) kaikista poolista. null = ei pooleja (ei rajaa).
create or replace function booking._pools_remaining(p_pools bigint[], p_from timestamptz, p_to timestamptz, p_exclude bigint default null)
returns integer language sql stable security definer set search_path = '' as $$
  select min(res.capacity - booking._pool_peak(res.id, p_from, p_to, p_exclude))::integer
    from booking.resources res where res.id = any (p_pools)
$$;

-- ---------- validointitrigger ----------
create or replace function booking.reservations_validate()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_range tstzrange := tstzrange(new.starts_at, new.ends_at, '[)');
  v_pool bigint; v_cap integer; v_peak integer;
begin
  if new.status not in ('pending','confirmed') then
    return new;
  end if;
  -- Ei tarvetta tarkistaa uudelleen, jos aktiivinen varaus ei muuta aikaa/tilaa/määrää
  if tg_op = 'UPDATE' and booking._res_active(old.status, old.hold_expires_at)
     and old.space_id = new.space_id and old.mode = new.mode
     and old.starts_at = new.starts_at and old.ends_at = new.ends_at
     and old.persons = new.persons and old.pool_ids = new.pool_ids then
    return new;
  end if;

  -- Tila-kohtainen lukko: serialisoi kaikki samaa tilaa koskevat varaukset
  perform pg_advisory_xact_lock(hashtextextended('booking:space:' || new.space_id::text, 0));
  perform booking._expire_holds(new.space_id, new.id);

  -- pitoaika pakollinen pending-tilassa ja pitää olla tulevaisuudessa uutta riviä tehdessä
  if new.status = 'pending' and (new.hold_expires_at is null or new.hold_expires_at <= now()) then
    perform booking._err('hold_expired', 'Varauksen pitoaika on jo päättynyt');
  end if;

  -- 4. sulku
  if exists (select 1 from booking.space_blocks b
              where b.active and b.space_id = new.space_id and b.during && v_range) then
    perform booking._err('space_closed', 'Aika ei ole varattavissa (tila suljettu)');
  end if;

  if new.mode = 'exclusive' then
    -- 1+2: mikään muu aktiivinen varaus ei saa osua väliin
    if exists (select 1 from booking.reservations r
                where r.space_id = new.space_id and r.id is distinct from new.id
                  and booking._res_active(r.status, r.hold_expires_at)
                  and r.mode = 'exclusive' and r.during && v_range) then
      perform booking._err('private_booked', 'Savusauna on jo varattu yksityisvuorolle tälle ajalle');
    end if;
    if exists (select 1 from booking.reservations r
                where r.space_id = new.space_id and r.id is distinct from new.id
                  and booking._res_active(r.status, r.hold_expires_at)
                  and r.mode = 'shared' and r.during && v_range) then
      perform booking._err('public_shift_booked', 'Ajalle on jo varauksia yleisille vuoroille – yksityisvuoroa ei voi varata');
    end if;
  else
    -- 2: yleinen vuoro ei saa osua yksityisvuoron päälle
    if exists (select 1 from booking.reservations r
                where r.space_id = new.space_id and r.id is distinct from new.id
                  and booking._res_active(r.status, r.hold_expires_at)
                  and r.mode = 'exclusive' and r.during && v_range) then
      perform booking._err('private_booked', 'Ajalle on yksityisvuoro – yleistä vuoroa ei voi varata');
    end if;
    -- 3: kapasiteetti jokaisessa poolissa
    foreach v_pool in array new.pool_ids loop
      select r.capacity into v_cap from booking.resources r where r.id = v_pool and r.kind = 'capacity_pool' and r.parent_id = new.space_id;
      if v_cap is null then
        perform booking._err('bad_pool', 'Kapasiteettipooli ' || v_pool::text || ' ei kuulu tähän tilaan');
      end if;
      v_peak := booking._pool_peak(v_pool, new.starts_at, new.ends_at, new.id);
      if v_peak + new.persons > v_cap then
        perform booking._err('capacity_exceeded',
          format('Ei tarpeeksi vapaita paikkoja (vapaana %s, pyydetty %s)', greatest(v_cap - v_peak, 0), new.persons));
      end if;
    end loop;
  end if;
  return new;
end $$;

create trigger reservations_validate
  before insert or update on booking.reservations
  for each row execute function booking.reservations_validate();

-- ---------- hinnoittelu (kb on totuus) ----------
create or replace function booking._rule_price(p_rule_id bigint, p_persons integer)
returns table(total numeric, unit_price numeric, breakdown jsonb)
language plpgsql stable security definer set search_path = '' as $$
declare
  r booking.schedule_rules; p kb.products; v kb.product_price_variants;
  base numeric; inc integer; extra numeric; extra_n integer; tot numeric;
begin
  select * into r from booking.schedule_rules where id = p_rule_id;
  if not found then perform booking._err('rule_not_found', 'Vuoromallia ei löydy'); end if;
  select * into p from kb.products where id = r.product_id;
  if r.price_variant_id is not null then select * into v from kb.product_price_variants where id = r.price_variant_id; end if;
  base := coalesce(v.price, p.price);
  if base is null then perform booking._err('price_missing', 'Tuotteella ei ole hintaa'); end if;
  if r.price_mode = 'per_person' then
    tot := base * p_persons;
    return query select tot, base, jsonb_build_object('mode','per_person','unit_price',base,'persons',p_persons);
  elsif r.price_mode = 'fixed' then
    return query select base, base, jsonb_build_object('mode','fixed','base',base,'persons',p_persons);
  else
    inc := coalesce(r.included_persons, v.included_persons, p.included_persons);
    extra := coalesce(r.extra_person_price, v.extra_person_price, p.extra_person_price, 0);
    extra_n := case when inc is null then 0 else greatest(p_persons - inc, 0) end;
    tot := base + extra_n * extra;
    return query select tot, base, jsonb_build_object('mode','fixed_plus_extra','base',base,'included_persons',inc,
                                                       'extra_persons',extra_n,'extra_person_price',extra,'persons',p_persons);
  end if;
end $$;

-- ---------- vuorojen generointi + saatavuus ----------
-- Generoi säännöistä vuorot päiväväliltä ja laskee tilan: available / full / unavailable / closed.
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
