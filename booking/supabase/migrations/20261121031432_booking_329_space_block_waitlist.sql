CREATE OR REPLACE FUNCTION booking._sessions(p_from date, p_to date, p_product_id bigint DEFAULT NULL::bigint, p_only_bookable boolean DEFAULT true)
 RETURNS TABLE(rule_id bigint, product_id bigint, label text, mode text, session_date date, starts_at timestamp with time zone, ends_at timestamp with time zone, status text, remaining integer, min_persons integer, max_persons integer, price_mode text, unit_price numeric, base_price numeric, included_persons integer, extra_person_price numeric, sale_closes_at timestamp with time zone, label_en text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with cand as materialized (
    select r.id as rule_id, r.product_id, r.label, r.label_en, r.mode, d.d::date as session_date, r.space_id,
           r.min_persons, r.max_persons, r.price_mode, r.deadline_minutes, r.sort_order, r.closure_exempt,
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
    select b.space_id, b.starts_at, b.ends_at, e.rule_id as event_rule_id, b.closure_event_id, b.event_block_id
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
                        and b.event_rule_id is distinct from c.rule_id
                        -- booking_291: closure_exempt-vuoroa ei sulje kalenterisulku (closure_event_id), muut sulut sulkevat
                        and not (c.closure_exempt and b.closure_event_id is not null)
                        -- booking_329: oma käsisulku (ei kalenteri-/tapahtumasulku) ei sulje yleistä vuoroa vaan näyttää sen täytenä (jonoon)
                        and not (c.mode <> 'exclusive' and b.closure_event_id is null and b.event_block_id is null)) then 'unavailable'
           when c.mode = 'exclusive' then
             case when exists (select 1 from active_space x where x.space_id = c.space_id
                                and x.starts_at < c.ends_at and x.ends_at > c.starts_at)
                  then 'unavailable' else 'available' end
           else
             case when exists (select 1 from active_blocks mb where mb.space_id = c.space_id and mb.starts_at < c.ends_at and mb.ends_at > c.starts_at and mb.closure_event_id is null and mb.event_block_id is null)
                  then 'full'
                  when exists (select 1 from active_space x where x.space_id = c.space_id
                                and x.mode = 'exclusive'
                                and x.starts_at < c.ends_at and x.ends_at > c.starts_at)
                  then 'unavailable'
                  when coalesce(c.pool_remaining, 1000) < c.min_persons then 'full'
                  else 'available' end
         end as status,
         case when c.mode = 'exclusive' then c.max_persons
              else case when exists (select 1 from active_blocks mb where mb.space_id = c.space_id and mb.starts_at < c.ends_at and mb.ends_at > c.starts_at and mb.closure_event_id is null and mb.event_block_id is null) then 0 else least(coalesce(c.max_persons, 1000), greatest(coalesce(c.pool_remaining, 1000), 0)) end end as remaining,
         c.min_persons, c.max_persons, c.price_mode,
         case when c.price_mode = 'per_person' then c.base_price end as unit_price,
         case when c.price_mode <> 'per_person' then c.base_price end as base_price,
         case when c.price_mode = 'fixed_plus_extra' then c.inc end as included_persons,
         case when c.price_mode = 'fixed_plus_extra' then c.extra end as extra_person_price,
         c.starts_at - make_interval(mins => c.deadline_minutes) as sale_closes_at,
         c.label_en  -- booking_151: vuoron nimi englanniksi (schedule_rules.label_en, null = ei käännöstä)
    from calc c
   order by c.session_date, c.starts_at, c.rule_id
$function$
;

create or replace function booking._space_blocks_waitlist_trg() returns trigger
 language plpgsql security definer set search_path to '' as $f$
begin
  -- booking_329: oma käsisulku (ei kalenteri-/tapahtumasulku) avataan/poistetaan/siirretään -> jono käsittelee ikkunan
  if tg_op = 'DELETE' then
    if old.active and old.closure_event_id is null and old.event_block_id is null then
      perform booking._notify_waitlist_for_window(old.space_id, old.starts_at, old.ends_at);
    end if;
    return old;
  end if;
  if old.active and old.closure_event_id is null and old.event_block_id is null
     and (not new.active or new.space_id is distinct from old.space_id
          or new.starts_at is distinct from old.starts_at or new.ends_at is distinct from old.ends_at) then
    perform booking._notify_waitlist_for_window(old.space_id, old.starts_at, old.ends_at);
  end if;
  return new;
end $f$;
drop trigger if exists space_blocks_zz_waitlist on booking.space_blocks;
create trigger space_blocks_zz_waitlist after update or delete on booking.space_blocks
  for each row execute function booking._space_blocks_waitlist_trg();
