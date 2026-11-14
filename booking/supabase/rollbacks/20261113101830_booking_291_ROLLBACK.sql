-- rollback booking_291
update booking.schedule_rules set active=false where product_id=24 and notes like 'booking_291:%';
update booking.product_config set lifecycle='old', shop_visible=false where product_id=24;
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
$function$
;

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
$function$
;

CREATE OR REPLACE FUNCTION booking.reservations_validate()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_cs timestamptz := new.starts_at + make_interval(mins => new.claim_offset_min);
  v_ce timestamptz := case when new.claim_minutes is null then new.ends_at else new.starts_at + make_interval(mins => new.claim_offset_min + new.claim_minutes) end;
  v_card booking.annual_cards; v_order_total numeric; v_order_cust bigint;
begin
  if new.status not in ('pending','confirmed') then
    return new;
  end if;
  -- Ei tarvetta tarkistaa uudelleen, jos aktiivinen varaus ei muuta aikaa/tilaa/määrää (legit validoidaan omassa triggerissään)
  if tg_op = 'UPDATE' and booking._res_active(old.status, old.hold_expires_at)
     and old.space_id = new.space_id and old.mode = new.mode
     and old.starts_at = new.starts_at and old.ends_at = new.ends_at
     and old.claim_offset_min = new.claim_offset_min and old.claim_minutes is not distinct from new.claim_minutes
     and old.persons = new.persons and old.pool_ids = new.pool_ids and old.quota_exempt = new.quota_exempt
     and old.override_reason is not distinct from new.override_reason
     and old.annual_card_id is not distinct from new.annual_card_id then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('booking:space:' || new.space_id::text, 0));
  perform booking._expire_holds(new.space_id, new.id);

  if new.status = 'pending' and (new.hold_expires_at is null or new.hold_expires_at <= now()) then
    perform booking._err('hold_expired', 'Varauksen pitoaika on jo päättynyt');
  end if;

  -- 4. sulku (claim-ikkunalle)
  perform booking._check_claim(new.id, null, new.space_id, 'space', new.mode, v_cs, v_ce, new.persons, new.pool_ids, null,
                               booking._session_key(new.pool_ids, new.mode, v_cs), new.quota_exempt, (new.override_reason is not null), 'blocks');

  -- 5. vuosikortti (ennallaan)
  if new.annual_card_id is not null then
    perform pg_advisory_xact_lock(hashtextextended('booking:card:' || new.annual_card_id::text, 0));
    select * into v_card from booking.annual_cards where id = new.annual_card_id;
    if not found or not v_card.active then
      perform booking._err('annual_card_inactive', 'Vuosikortti ei ole voimassa');
    end if;
    if new.mode <> 'shared' then
      perform booking._err('annual_card_shared_only', 'Vuosikortilla voi varata vain yleisiä vuoroja (ei yksityisvuoroja)');
    end if;
    if (new.starts_at at time zone booking._tz())::date not between v_card.valid_from and v_card.valid_to then
      perform booking._err('annual_card_expired', 'Vuosikortti ei ole voimassa vuoron päivänä');
    end if;
    select o.total_gross, o.customer_id into v_order_total, v_order_cust from booking.orders o where o.id = new.order_id;
    if v_order_total is distinct from 0 then
      perform booking._err('annual_card_must_be_free', 'Vuosikorttivarauksen hinta on 0 €');
    end if;
    if v_order_cust is distinct from v_card.customer_id then
      perform booking._err('annual_card_customer_mismatch', 'Vuosikortti kuuluu toiselle asiakkaalle');
    end if;
    if new.persons > coalesce((booking._setting('annual_card_max_persons', '1'::jsonb) #>> '{}')::int, 1) then
      perform booking._err('annual_card_persons', format('Vuosikorttivarauksessa enintään %s henkilöä',
              coalesce((booking._setting('annual_card_max_persons', '1'::jsonb) #>> '{}')::int, 1)));
    end if;
    if new.starts_at > now() and exists (
         select 1 from booking.reservations r
          where r.annual_card_id = new.annual_card_id and r.id is distinct from new.id
            and booking._res_active(r.status, r.hold_expires_at) and r.starts_at > now()) then
      perform booking._err('annual_card_limit', 'Vuosikortilla voi olla vain yksi tuleva varaus kerrallaan');
    end if;
  end if;

  -- 1–3. päällekkäisyys (claimit: myös muiden varausten legit samassa tilassa), Rauni-puskuri, poolikapasiteetti (ei quota_exempt)
  perform booking._check_claim(new.id, null, new.space_id, 'space', new.mode, v_cs, v_ce, new.persons, new.pool_ids, null,
                               booking._session_key(new.pool_ids, new.mode, v_cs), new.quota_exempt, (new.override_reason is not null), 'rest');
  return new;
end $function$
;

drop function if exists booking._rule_closure_exempt(bigint,bigint);
alter table booking.schedule_rules drop column if exists closure_exempt;
