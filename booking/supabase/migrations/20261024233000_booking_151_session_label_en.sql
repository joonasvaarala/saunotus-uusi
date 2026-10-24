-- booking_151: vuorojen englanninkieliset nimet kauppaan (booking.schedule_rules.label_en).
-- Sarake label_en (nullable) on jo tuotannossa: Bottiavustuksen migraatio kb_texts_en_sources (20261024122952), Kääntäjä täyttää sen site_texts-putken kautta.
-- Muutos: booking._sessions(), booking.public_availability() ja booking.public_availability_all() palauttavat lisäksi viimeisenä sarakkeena label_en.
--   Kaikki muut sarakkeet, rajaukset, tilalogiikka (booking_148: yksityisvuoron jonotuspito), järjestys ja oikeudet ennallaan.
-- Pohja: mainin viimeisin määritelmä (booking_148, 20261024120446) = tuotannon pg_get_functiondef (md5 050f3e9e / 5eb846fa / 6a12314f, tarkistettu 24.10.2026).
-- RETURNS TABLE muuttuu → drop + create. Riippuvuudet: ei pg_depend-riippuvuuksia (näkymiä tms. ei ole). plpgsql-kutsujat sidotaan ajossa:
--   admin_day_view (to_jsonb(s) → päivän sessions-riveihin tulee lisäavain label_en), public_join_waitlist, public_waitlist_claim,
--   _waitlist_process_session (select * into record, käyttävät nimettyjä kenttiä) – toimivat ennallaan.
-- Ei hintojen, ALV:n, URLien eikä public-skeeman muutoksia. Rollback: booking/supabase/rollbacks/20261024233000_booking_151_ROLLBACK.sql
set local lock_timeout = '5s';
drop function booking.public_availability_all(date, date, text);
drop function booking.public_availability(bigint, date, date);
drop function booking._sessions(date, date, bigint, boolean);

CREATE FUNCTION booking._sessions(p_from date, p_to date, p_product_id bigint DEFAULT NULL::bigint, p_only_bookable boolean DEFAULT true)
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
    select b.space_id, b.starts_at, b.ends_at
      from booking.space_blocks b cross join bounds lim
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
                        and b.starts_at < c.ends_at and b.ends_at > c.starts_at) then 'unavailable'
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

CREATE FUNCTION booking.public_availability(p_product_id bigint, p_from date, p_to date)
 RETURNS TABLE(rule_id bigint, label text, mode text, session_date date, starts_at timestamp with time zone, ends_at timestamp with time zone, status text, remaining integer, min_persons integer, max_persons integer, price_mode text, unit_price numeric, base_price numeric, included_persons integer, extra_person_price numeric, label_en text)
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

CREATE FUNCTION booking.public_availability_all(p_from date, p_to date, p_audience text DEFAULT 'consumer'::text)
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
     where pc.bookable and pc.shop_visible and pc.lifecycle = 'current'
       and pc.audience = v_audience and s.status <> 'closed';
end $function$;

revoke all on function booking._sessions(date, date, bigint, boolean) from public, anon, authenticated;
grant execute on function booking._sessions(date, date, bigint, boolean) to service_role;
revoke all on function booking.public_availability(bigint, date, date) from public, anon, authenticated;
grant execute on function booking.public_availability(bigint, date, date) to anon, authenticated, service_role;
revoke all on function booking.public_availability_all(date, date, text) from public, anon, authenticated;
grant execute on function booking.public_availability_all(date, date, text) to anon, authenticated, service_role;
comment on function booking.public_availability_all(date, date, text) is
  'Kauppa, vain luku: kuukauden kaikkien julkisten vuorotuotteiden saatavuus yhdellä kutsulla (sama rajaus kuin public_availability, audience consumer/business).';
