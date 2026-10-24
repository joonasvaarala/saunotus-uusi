-- booking_148: jonotuslistan henkilömäärän raja palvelutyypin mukaan (omistajan päätös).
-- Palvelutyyppi tunnistetaan olemassa olevista sarakkeista, ei nimistä:
--   * yksityisvuoro = booking.schedule_rules.mode = 'exclusive' (booking_03: exclusive = koko tila yhdelle varaukselle;
--     tuotannossa kaikki exclusive-säännöt ovat product_config.sale_kind = 'private_shift', kategoriat private_sauna/corporate),
--   * tapahtuma     = kb.products.category = 'event' (sama tunnistus kuin booking_52/53 lisäpalveluiden applies_modes 'event'),
--   * yleinen vuoro = muut (mode 'shared', sale_kind 'public_shift': miesten, naisten, hiljainen, to/la/su yleiset).
-- Säännöt:
-- 1. Yleinen vuoro: 1–6 henkilöä ja vuoron oma min/max kuten booking_134 (ennallaan).
-- 2. Yksityisvuoro: henkilömäärää ei kysytä. public_join_waitlist ohittaa p_persons-arvon ja tallentaa vuoron minimin
--    (persons NOT NULL 1..50, käytännössä 1). Mahtuvuus on aina tosi, kun vuoro vapautuu (koko vuoro vapautuu kerralla).
--    Varattu yksityisvuoro (päällekkäinen exclusive-varaus tai jonotuspito samassa tilassa, ei sulku) näkyy julkisessa
--    saatavuudessa tilassa 'full' (aiemmin 'unavailable'), jotta siihen voi jonottaa. Admin (henkilökunta) näkee _sessionsin ennallaan.
-- 3. Tapahtuma: 1..tapahtuman maksimiosallistujamäärä = pienin vuoron max_persons, product_config.max_persons ja vuoron
--    kapasiteettipoolien capacity (booking.resources), enintään 50 (waitlist_entries.persons-tarkistus).
-- 48 h -sääntö ja 120 min pito ennallaan (booking_139). Yksityisvuoron pito varaa koko tilan kuten exclusive-varaus:
-- _sessions (julkinen saatavuus) ja _check_claim (varauksen luonti) huomioivat sen; poikkeukset _waitlist_hold_counts (haltija, henkilökunta).
-- Paluu: booking/supabase/rollbacks/20261024120446_booking_148_ROLLBACK.sql.

create or replace function booking._waitlist_party(p_rule_id bigint)
returns table (kind text, min_persons integer, max_persons integer)
language sql stable security definer set search_path = '' as $$
  select k.kind,
         case when k.kind = 'private' then null else greatest(1, coalesce(r.min_persons, 1)) end,
         case k.kind
           when 'private' then null
           when 'event' then least(50, coalesce(least(r.max_persons, pc.max_persons,
                  (select min(res.capacity) from booking.schedule_rule_pools rp
                     join booking.resources res on res.id = rp.pool_id
                    where rp.rule_id = r.id and res.capacity > 0)), 50))
           else least(6, coalesce(r.max_persons, 6)) end
    from booking.schedule_rules r
    join kb.products p on p.id = r.product_id
    left join booking.product_config pc on pc.product_id = r.product_id
    cross join lateral (select case when r.mode = 'exclusive' then 'private'
                                    when p.category = 'event' then 'event'
                                    else 'general' end as kind) k
   where r.id = p_rule_id
$$;
comment on function booking._waitlist_party(bigint) is
  'booking_148: jonotuslistan palvelutyyppi (general/private/event) ja henkilömäärän raja vuorolle. private: ei henkilömäärää (null).';

create or replace function booking._waitlist_private_taken(p_rule_id bigint, p_starts timestamptz, p_ends timestamptz)
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
           select 1 from booking.schedule_rules sr
            where sr.id = p_rule_id and sr.mode = 'exclusive'
              and (exists (select 1 from booking.reservations x
                            where x.space_id = sr.space_id and x.mode = 'exclusive'
                              and x.status in ('pending', 'confirmed') and booking._res_active(x.status, x.hold_expires_at)
                              and x.starts_at < p_ends and x.ends_at > p_starts)
                or exists (select 1 from booking.waitlist_entries w
                             join booking.schedule_rules wr on wr.id = w.rule_id and wr.mode = 'exclusive'
                            where w.space_id = sr.space_id and w.status = 'notified' and w.hold_expires_at > now()
                              and w.starts_at < p_ends and w.ends_at > p_starts
                              and booking._waitlist_hold_counts(w.id)))
              and not exists (select 1 from booking.space_blocks b
                               where b.active and b.space_id = sr.space_id
                                 and b.starts_at < p_ends and b.ends_at > p_starts))
$$;
comment on function booking._waitlist_private_taken(bigint, timestamptz, timestamptz) is
  'booking_148: yksityisvuoron tila on varattu toiselle yksityisvuorolle tai jonotuspidolle (ei sulkua) → vuoro on täynnä ja jonotettava.';

revoke all on function booking._waitlist_party(bigint) from public, anon, authenticated;
revoke all on function booking._waitlist_private_taken(bigint, timestamptz, timestamptz) from public, anon, authenticated;


CREATE OR REPLACE FUNCTION booking._sessions(p_from date, p_to date, p_product_id bigint DEFAULT NULL::bigint, p_only_bookable boolean DEFAULT true)
 RETURNS TABLE(rule_id bigint, product_id bigint, label text, mode text, session_date date, starts_at timestamp with time zone, ends_at timestamp with time zone, status text, remaining integer, min_persons integer, max_persons integer, price_mode text, unit_price numeric, base_price numeric, included_persons integer, extra_person_price numeric, sale_closes_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with cand as materialized (
    select r.id as rule_id, r.product_id, r.label, r.mode, d.d::date as session_date, r.space_id,
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
         c.starts_at - make_interval(mins => c.deadline_minutes) as sale_closes_at
    from calc c
   order by c.session_date, c.starts_at, c.rule_id
$function$
;

CREATE OR REPLACE FUNCTION booking._check_claim(p_res_id bigint, p_leg_id bigint, p_resource bigint, p_role text, p_mode text, p_start timestamp with time zone, p_end timestamp with time zone, p_persons integer, p_pools bigint[], p_skill text, p_session_key text, p_quota_exempt boolean DEFAULT false, p_override boolean DEFAULT false, p_phase text DEFAULT 'all'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_res booking.resources; v_range tstzrange := tstzrange(p_start, p_end, '[)');
  x record; v_pool bigint; v_cap integer; v_peak integer; v_gap integer; v_maxgap integer; v_ritual boolean; v_savu boolean;
begin
  select * into v_res from booking.resources where id = p_resource;
  if not found then perform booking._err('resource_not_found', 'Resurssia ei löydy'); end if;
  perform pg_advisory_xact_lock(hashtextextended('booking:space:' || p_resource::text, 0));

  if p_phase in ('all', 'blocks') then
    if not p_override and exists (select 1 from booking.space_blocks b where b.active and b.space_id = p_resource and b.during && v_range) then
      if p_role = 'therapist' then perform booking._err('therapist_closed', 'Saunottajat eivät ole saatavilla tälle ajalle (hoidot kiinni)');
      else perform booking._err('space_closed', 'Aika ei ole varattavissa (tila suljettu)'); end if;
    end if;
    if p_phase = 'blocks' then return; end if;
  end if;

  if p_role = 'therapist' then
    if not p_override and booking._therapist_slack(p_skill, p_start, p_end, p_persons, p_session_key, p_leg_id, p_res_id) < 0 then
      perform booking._err('no_therapist', 'Ei vapaata saunottajaa tälle ajalle');
    end if;
    return;
  elsif p_role = 'group' then
    return;                                   -- sulkuryhmä: vain sulkutarkistus (yllä)
  end if;

  -- role = 'space'
  v_savu := (v_res.code = 'savusauna');
  v_ritual := booking._is_ritual(p_pools);
  v_maxgap := greatest(v_res.buffer_after_min, coalesce(v_res.buffer_ritual_ritual_min, 0));
  for x in
    select c.mode, c.claim_start, c.claim_end, c.session_key, c.pool_ids
      from booking.v_claims c
     where c.resource_id = p_resource and c.role = 'space' and c.reservation_id is distinct from p_res_id
       and booking._res_active(c.status, c.hold_expires_at)
       and c.claim_start < p_end + make_interval(mins => v_maxgap) and c.claim_end > p_start - make_interval(mins => v_maxgap)
     order by (c.mode = 'exclusive') desc
  loop
    v_gap := case when v_ritual and booking._is_ritual(x.pool_ids) and v_res.buffer_ritual_ritual_min is not null
                  then v_res.buffer_ritual_ritual_min else v_res.buffer_after_min end;
    -- puoliavoin väli + puskuri: konflikti vain jos [alku, loppu+puskuri) leikkaavat molempiin suuntiin
    if not (p_start < x.claim_end + make_interval(mins => v_gap) and x.claim_start < p_end + make_interval(mins => v_gap)) then continue; end if;
    if p_mode = 'exclusive' and x.mode = 'exclusive' then
      if v_savu then perform booking._err('private_booked', 'Savusauna on jo varattu yksityisvuorolle tälle ajalle');
      else perform booking._err('space_busy', 'Tila on jo varattu tälle ajalle (' || v_res.code || ')'); end if;
    elsif p_mode = 'exclusive' then
      if v_savu then perform booking._err('public_shift_booked', 'Ajalle on jo varauksia yleisille vuoroille – yksityisvuoroa ei voi varata');
      else perform booking._err('space_busy', 'Tilassa on jo toinen istunto tälle ajalle tai sen puskuriin (' || v_res.code || ')'); end if;
    elsif x.mode = 'exclusive' then
      if v_savu then perform booking._err('private_booked', 'Ajalle on yksityisvuoro – yleistä vuoroa ei voi varata');
      else perform booking._err('space_busy', 'Tila on varattu yksinoikeudella tälle ajalle (' || v_res.code || ')'); end if;
    elsif v_res.session_exclusive and (p_session_key is null or p_session_key is distinct from x.session_key) then
      perform booking._err('space_busy', 'Tilassa on toinen istunto tälle ajalle tai sen puskuriin (' || v_res.code || ')');
    end if;
  end loop;

  -- booking_148: yksityisvuoron jonotuspito (vuoroon >= 48 h, 120 min) varaa koko tilan kuten exclusive-varaus.
  -- Pidon haltija itse ja henkilökunta ohittavat (_waitlist_hold_counts).
  if exists (select 1 from booking.waitlist_entries w
               join booking.schedule_rules sr on sr.id = w.rule_id and sr.mode = 'exclusive'
              where w.space_id = p_resource and w.status = 'notified' and w.hold_expires_at > now()
                and p_start < w.ends_at + make_interval(mins => v_res.buffer_after_min)
                and w.starts_at < p_end + make_interval(mins => v_res.buffer_after_min)
                and booking._waitlist_hold_counts(w.id)) then
    if v_savu then perform booking._err('private_booked', 'Savusauna on varattu yksityisvuorolle tälle ajalle');
    else perform booking._err('space_busy', 'Tila on varattu tälle ajalle (' || v_res.code || ')'); end if;
  end if;

  if p_mode = 'shared' then
    foreach v_pool in array coalesce(p_pools, '{}') loop
      select r.capacity into v_cap from booking.resources r where r.id = v_pool and r.kind = 'capacity_pool' and r.parent_id = p_resource;
      if v_cap is null then perform booking._err('bad_pool', 'Kapasiteettipooli ' || v_pool::text || ' ei kuulu tähän tilaan'); end if;
      if not p_quota_exempt then
        v_peak := booking._pool_peak(v_pool, p_start, p_end, p_res_id);
        if v_peak + p_persons > v_cap then
          perform booking._err('capacity_exceeded', format('Ei tarpeeksi vapaita paikkoja (vapaana %s, pyydetty %s)', greatest(v_cap - v_peak, 0), p_persons));
        end if;
      end if;
    end loop;
  end if;
end $function$
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
           case when s.status = 'closed' then 'closed'
                when s.mode = 'exclusive' and s.status = 'unavailable'
                     and booking._waitlist_private_taken(s.rule_id, s.starts_at, s.ends_at) then 'full'
                else s.status end,
           s.remaining, s.min_persons, s.max_persons, s.price_mode, s.unit_price, s.base_price, s.included_persons, s.extra_person_price
      from booking._sessions(greatest(p_from, (now() at time zone booking._tz())::date),
                             least(p_to, (now() at time zone booking._tz())::date + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int),
                             p_product_id, true) s
     where s.status <> 'closed';
end $function$
;

CREATE OR REPLACE FUNCTION booking.public_availability_all(p_from date, p_to date, p_audience text DEFAULT 'consumer'::text)
 RETURNS TABLE(product_id bigint, rule_id bigint, label text, mode text, session_date date, starts_at timestamp with time zone, ends_at timestamp with time zone, status text, remaining integer, min_persons integer, max_persons integer, price_mode text, unit_price numeric, base_price numeric, included_persons integer, extra_person_price numeric)
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
           s.extra_person_price
      from booking._sessions(v_from, v_to, null, true) s
      join booking.product_config pc on pc.product_id = s.product_id
     where pc.bookable and pc.shop_visible and pc.lifecycle = 'current'
       and pc.audience = v_audience and s.status <> 'closed';
end $function$
;

CREATE OR REPLACE FUNCTION booking.public_join_waitlist(p_rule_id bigint, p_date date, p_persons integer DEFAULT 1, p_name text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_locale text DEFAULT 'fi'::text, p_whatsapp_opt_in boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_rule booking.schedule_rules;
  v_s record;
  v_name text := btrim(coalesce(p_name,''));
  v_email text := lower(btrim(coalesce(p_email,'')));
  v_phone text := nullif(btrim(coalesce(p_phone,'')), '');
  v_token uuid;
  v_opt boolean := coalesce(p_whatsapp_opt_in, false);
  v_party record;
  v_persons integer;
begin
  if booking._setting('waitlist_enabled', 'true'::jsonb) <> 'true'::jsonb then
    return jsonb_build_object('ok',false,'code','disabled');
  end if;
  if not booking._rate_limit('waitlist:email:' || v_email, 8, interval '10 minutes') then
    return jsonb_build_object('ok',false,'code','rate_limited');
  end if;
  if length(v_name) not between 2 and 120 then return jsonb_build_object('ok',false,'code','invalid_name'); end if;
  if length(v_email) > 200 or not booking._valid_email(v_email) then return jsonb_build_object('ok',false,'code','invalid_email'); end if;
  if v_phone is not null and (length(v_phone) > 30 or v_phone !~ '^[0-9+()\- ]{6,30}$') then
    return jsonb_build_object('ok',false,'code','invalid_phone');
  end if;
  if p_locale not in ('fi','en') or p_locale is null then return jsonb_build_object('ok',false,'code','invalid_locale'); end if;
  select * into v_rule from booking.schedule_rules where id = p_rule_id and active;
  if not found or p_date is null then
    return jsonb_build_object('ok',false,'code','invalid_session');
  end if;
  -- booking_148: henkilömäärän raja palvelutyypin mukaan (booking._waitlist_party):
  --   general (yleiset vuorot) 1–6 ja vuoron oma min/max kuten booking_134,
  --   event (kb.products.category = 'event') 1..tapahtuman kapasiteetti,
  --   private (schedule_rules.mode = 'exclusive') henkilömäärää ei kysytä: p_persons ohitetaan, tallennetaan vuoron minimi.
  select * into v_party from booking._waitlist_party(p_rule_id);
  if v_party.kind = 'private' then
    v_persons := greatest(1, coalesce(v_rule.min_persons, 1));
  else
    if p_persons is null or p_persons < v_party.min_persons or p_persons > v_party.max_persons then
      return jsonb_build_object('ok',false,'code','invalid_persons','kind',v_party.kind,
        'min',v_party.min_persons,'max',v_party.max_persons);
    end if;
    v_persons := p_persons;
  end if;
  -- Tarkistus tehdään tuoreesta saatavuudesta: sulut ja exclusive-blokit eivät ole jonotettavia.
  select * into v_s from booking._sessions(p_date,p_date,v_rule.product_id,true) s
    where s.rule_id = p_rule_id and s.session_date = p_date limit 1;
  -- Yksityisvuoro on jonotettava, kun sen tila on varattu toiselle yksityisvuorolle tai jonotuspidolle (ei sulku).
  if not found or v_s.starts_at <= now()
     or not (v_s.status = 'full'
             or (v_party.kind = 'private' and v_s.status = 'unavailable'
                 and booking._waitlist_private_taken(p_rule_id, v_s.starts_at, v_s.ends_at))) then
    return jsonb_build_object('ok',false,'code','not_full');
  end if;
  insert into booking.waitlist_entries(product_id,rule_id,session_date,starts_at,ends_at,space_id,persons,
    customer_name,customer_email,customer_phone,locale,preferred_channel,whatsapp_opt_in)
  values (v_rule.product_id,v_rule.id,p_date,v_s.starts_at,v_s.ends_at,v_rule.space_id,v_persons,
    v_name,v_email,v_phone,p_locale,case when v_opt then 'both' else 'email' end,v_opt)
  on conflict (rule_id,session_date,(lower(customer_email))) where status in ('waiting','notified')
  do update set persons=excluded.persons, customer_name=excluded.customer_name,
    customer_phone=excluded.customer_phone,locale=excluded.locale,preferred_channel=excluded.preferred_channel,
    whatsapp_opt_in=excluded.whatsapp_opt_in,starts_at=excluded.starts_at,ends_at=excluded.ends_at,
    status='waiting',notified_at=null,whatsapp_queued_at=null,whatsapp_send_after=null,updated_at=now()
  returning public_token into v_token;
  return jsonb_build_object('ok',true,'token',v_token,'starts_at',v_s.starts_at,'ends_at',v_s.ends_at,
    'persons',case when v_party.kind = 'private' then null else v_persons end,'kind',v_party.kind);
end $function$
;

CREATE OR REPLACE FUNCTION booking.public_waitlist_claim(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  w booking.waitlist_entries;
  v_s record;
  v_enough boolean;
  v_ip text := booking._client_ip();
  v_hold_expired boolean;
  v_kind text;
begin
  if p_token is null then return jsonb_build_object('ok',false,'code','not_found'); end if;
  select * into w from booking.waitlist_entries where public_token = p_token and status in ('waiting','notified') for update;
  if not found then return jsonb_build_object('ok',false,'code','not_found'); end if;
  if not booking._rate_limit('waitlist:claim:' || p_token::text, 30, interval '10 minutes')
     or (v_ip is not null and not booking._rate_limit('waitlist:claim:ip:' || v_ip, 60, interval '10 minutes')) then
    return jsonb_build_object('ok',false,'code','rate_limited');
  end if;
  if w.starts_at <= now() then return jsonb_build_object('ok',false,'code','expired'); end if;
  v_hold_expired := w.status = 'notified' and w.hold_expires_at is not null and w.hold_expires_at <= now();
  -- Oma voimassa oleva pito ei vähennä haltijan saatavuutta; muiden pidot vähentävät.
  perform set_config('booking.waitlist_hold_exempt', w.id::text, true);
  select * into v_s from booking._sessions(w.session_date,w.session_date,w.product_id,true) s
    where s.rule_id = w.rule_id and s.session_date = w.session_date limit 1;
  perform set_config('booking.waitlist_hold_exempt', '', true);
  -- booking_148: yksityisvuorossa riittää, että vuoro on vapaa (koko vuoro vapautuu kerralla).
  v_kind := (select p.kind from booking._waitlist_party(w.rule_id) p);
  v_enough := found and v_s.starts_at = w.starts_at and v_s.status = 'available'
              and (v_kind = 'private' or v_s.remaining >= w.persons);
  if not v_enough and w.status = 'notified' then
    -- clock_timestamp: uusi updated_at → uusi dedupe-avain seuraavalle ilmoitukselle.
    update booking.waitlist_entries set status='waiting',notified_at=null,whatsapp_queued_at=null,whatsapp_send_after=null,
      updated_at=clock_timestamp() where id = w.id;
  end if;
  return jsonb_build_object('ok',true,'rule_id',w.rule_id,'product_id',w.product_id,'session_date',w.session_date,
    'persons',w.persons,'kind',v_kind,'enough',v_enough,'hold_expired',v_hold_expired,
    'remaining',case when v_enough then v_s.remaining end);
end $function$
;

CREATE OR REPLACE FUNCTION booking._waitlist_notify_entry(p_id bigint, p_hold_expires_at timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  w booking.waitlist_entries;
  v_site text := rtrim(coalesce(booking._setting('site_base_url') #>> '{}',''),'/');
  v_shop text;
  v_name text;
  v_dedupe text;
  v_wa boolean := booking._setting('waitlist_whatsapp_enabled','false'::jsonb) = 'true'::jsonb;
  v_h integer := extract(hour from now() at time zone 'Europe/Helsinki')::int;
  v_start integer := (booking._setting('waitlist_quiet_hours_start','21'::jsonb) #>> '{}')::int;
  v_end integer := (booking._setting('waitlist_quiet_hours_end','8'::jsonb) #>> '{}')::int;
  v_wa_after timestamptz;
  v_private boolean;
begin
  select * into w from booking.waitlist_entries where id = p_id and status = 'waiting';
  if not found then return; end if;
  -- Kaupan polku kielen mukaan (content/site.json pages.book): fi /varaa/, en /en/book/.
  v_shop := case when w.locale='en' then '/en/book/' else '/varaa/' end;
  select coalesce(case when w.locale='en' then nullif(p.name_en,'') end,p.name)
    into v_name from kb.products p where p.id=w.product_id;
  -- booking_148: yksityisvuorossa henkilömäärää ei kysytty → ei viestiin eikä varauslinkkiin.
  v_private := exists (select 1 from booking.schedule_rules r where r.id = w.rule_id and r.mode = 'exclusive');
  v_dedupe := 'waitlist:'||w.id||':spot_freed:'||to_char(w.updated_at,'YYYYMMDDHH24MISSUS');
  -- Jonotuslistan sähköposti kuuluu nykyiseen send-emails -putkeen; dedupe estää kaksoislähetyksen.
  insert into booking.email_outbox(kind,locale,dedupe_key,status,payload)
  values ('waitlist_spot_freed',w.locale,v_dedupe,'pending',jsonb_build_object(
    'to_email',w.customer_email,'to_name',w.customer_name,'product_name',v_name,
    'starts_at',w.starts_at,'ends_at',w.ends_at,'persons',case when v_private then null else w.persons end,
    'book_url',v_site||v_shop||'#/varaa/'||w.rule_id||'/'||w.session_date||'/'||w.product_id
      ||case when v_private then '?' else '?n='||w.persons||'&' end||'wl='||w.public_token,
    'leave_url',v_site||v_shop||'?poistu_jonosta='||w.public_token))
  on conflict (dedupe_key) do nothing;
  v_wa_after := null;
  if v_wa and w.whatsapp_opt_in and w.customer_phone is not null then
    if v_start > v_end then
      if v_h >= v_start then
        v_wa_after := (((now() at time zone 'Europe/Helsinki')::date + 1)::timestamp + make_interval(hours=>v_end)) at time zone 'Europe/Helsinki';
      elsif v_h < v_end then
        v_wa_after := ((now() at time zone 'Europe/Helsinki')::date::timestamp + make_interval(hours=>v_end)) at time zone 'Europe/Helsinki';
      else v_wa_after := now(); end if;
    else
      v_wa_after := case when v_h >= v_start and v_h < v_end then
        ((now() at time zone 'Europe/Helsinki')::date::timestamp + make_interval(hours=>v_end)) at time zone 'Europe/Helsinki'
        else now() end;
    end if;
  end if;
  -- hold_expires_at kirjoitetaan vain pidolle; aiempi pito säilyy historiana (ei toista pitoa samaan vuoroon).
  update booking.waitlist_entries set status='notified',notified_at=now(),
    hold_expires_at=coalesce(p_hold_expires_at,hold_expires_at),
    whatsapp_send_after=v_wa_after,whatsapp_queued_at=null,updated_at=now()
  where id=w.id;
end $function$
;

CREATE OR REPLACE FUNCTION booking._waitlist_process_session(p_rule_id bigint, p_date date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  w booking.waitlist_entries;
  v_s record;
  v_product bigint;
  v_space bigint;
  v_prev text;
  v_cur integer;
  v_offered integer;
  v_hold_until timestamptz;
  v_active boolean;
  v_mode text;
  v_held integer;
  v_n integer := 0;
  v_private boolean;
begin
  if p_rule_id is null or p_date is null then return 0; end if;
  -- Sama vuoro yksi transaktio kerrallaan (ei kahta rinnakkaista pitoa). Varattu → ohitetaan, sweep hoitaa myöhemmin.
  if not pg_try_advisory_xact_lock(hashtextextended('booking:waitlist:'||p_rule_id||':'||p_date, 0)) then return 0; end if;
  select r.product_id, r.space_id, r.mode = 'exclusive' into v_product, v_space, v_private
    from booking.schedule_rules r where r.id = p_rule_id;
  if not found then return 0; end if;
  -- Sama tilan lukko kuin varauksen kapasiteettitarkistuksella: pito ei kilpaile rinnakkaisen varauksen kanssa. Varattu → ohitetaan.
  if not pg_try_advisory_xact_lock(hashtextextended('booking:space:' || v_space::text, 0)) then return 0; end if;
  -- Raaka vapaa kapasiteetti ilman pitoja (pidot vähennetään alla itse).
  v_prev := current_setting('booking.waitlist_hold_exempt', true);
  perform set_config('booking.waitlist_hold_exempt', 'all', true);
  select * into v_s from booking._sessions(p_date,p_date,v_product,true) s
    where s.rule_id=p_rule_id and s.session_date=p_date limit 1;
  perform set_config('booking.waitlist_hold_exempt', coalesce(v_prev, ''), true);
  if not found or v_s.starts_at <= now() then return 0; end if;
  v_cur := case when v_s.status = 'available' then greatest(coalesce(v_s.remaining,0),0) else 0 end;
  select st.offered_free into v_offered from booking.waitlist_session_state st
   where st.rule_id=p_rule_id and st.session_date=p_date;
  v_offered := coalesce(v_offered, 0);
  -- Pitotila: ilmoitus nyt antaisi pidon (vuoroon ≥ waitlist_hold_min_hours_before h).
  v_hold_until := booking._waitlist_offer_expires_at(now(), v_s.starts_at);
  v_active := exists (select 1 from booking.waitlist_entries a
    where a.rule_id=p_rule_id and a.session_date=p_date and a.status='notified' and a.hold_expires_at > now());
  if v_hold_until is not null and v_active then
    -- Yksi pito kerrallaan: muut eivät saa mitään. Vain lasku kirjataan; kasvu jää uudeksi vapautumiseksi pidon jälkeen.
    insert into booking.waitlist_session_state(rule_id,session_date,offered_free,updated_at)
    values (p_rule_id,p_date,v_cur,now())
    on conflict (rule_id,session_date) do update
      set offered_free = least(booking.waitlist_session_state.offered_free, excluded.offered_free), updated_at = now();
    return 0;
  end if;
  v_mode := case when v_hold_until is not null and v_cur > v_offered then 'hold' else 'all' end;
  for w in select * from booking.waitlist_entries
    where rule_id=p_rule_id and session_date=p_date and status='waiting' and starts_at>now()
      and (v_mode = 'all' or hold_expires_at is null)
    order by created_at,id for update skip locked
  loop
    if v_s.starts_at<>w.starts_at or v_s.status<>'available' then continue; end if;
    -- booking_134/135: jonon järjestys, mahtuvuus ratkaisee. Vähennetään voimassa olevat pidot samasta vuorosta ja
    -- päällekkäisistä, kapasiteettipoolin jakavista vuoroista (booking_139: vain hold_expires_at > now()).
    select coalesce(sum(o.persons),0)::int into v_held
      from booking.waitlist_entries o
     where o.status='notified' and o.id<>w.id and o.starts_at>now() and o.hold_expires_at > now()
       and o.starts_at<w.ends_at and o.ends_at>w.starts_at
       and ((o.rule_id=w.rule_id and o.session_date=w.session_date)
         or exists (select 1 from booking.schedule_rule_pools a
                      join booking.schedule_rule_pools b on b.pool_id=a.pool_id
                     where a.rule_id=o.rule_id and b.rule_id=w.rule_id));
    if v_private then
      -- booking_148: yksityisvuoro vapautuu kokonaan → mahtuu aina, kun vuoro on vapaa eikä tilaa pidetä toiselle
      -- (voimassa oleva pito samaan tai päällekkäiseen yksityisvuoroon samassa tilassa).
      if exists (select 1 from booking.waitlist_entries o
                   join booking.schedule_rules orr on orr.id = o.rule_id and orr.mode = 'exclusive'
                  where o.status='notified' and o.id<>w.id and o.hold_expires_at > now()
                    and o.space_id = w.space_id and o.starts_at<w.ends_at and o.ends_at>w.starts_at) then continue; end if;
    elsif v_cur - v_held < w.persons then continue; end if;
    if v_mode = 'hold' then
      perform booking._waitlist_notify_entry(w.id, v_hold_until);
      v_n := 1;
      exit;   -- vain yksi pito
    end if;
    perform booking._waitlist_notify_entry(w.id, null);
    v_n := v_n + 1;
  end loop;
  if v_mode = 'hold' and v_n = 0 then
    -- Uusi vapautuminen, mutta kukaan mahtuva ilman aiempaa pitoa ei ole jonossa → ilmoitus kaikille mahtuville ilman pitoa.
    for w in select * from booking.waitlist_entries
      where rule_id=p_rule_id and session_date=p_date and status='waiting' and starts_at>now()
      order by created_at,id for update skip locked
    loop
      if v_s.starts_at<>w.starts_at or v_s.status<>'available' then continue; end if;
      select coalesce(sum(o.persons),0)::int into v_held
        from booking.waitlist_entries o
       where o.status='notified' and o.id<>w.id and o.starts_at>now() and o.hold_expires_at > now()
         and o.starts_at<w.ends_at and o.ends_at>w.starts_at
         and ((o.rule_id=w.rule_id and o.session_date=w.session_date)
           or exists (select 1 from booking.schedule_rule_pools a
                        join booking.schedule_rule_pools b on b.pool_id=a.pool_id
                       where a.rule_id=o.rule_id and b.rule_id=w.rule_id));
      if v_private then
        if exists (select 1 from booking.waitlist_entries o
                     join booking.schedule_rules orr on orr.id = o.rule_id and orr.mode = 'exclusive'
                    where o.status='notified' and o.id<>w.id and o.hold_expires_at > now()
                      and o.space_id = w.space_id and o.starts_at<w.ends_at and o.ends_at>w.starts_at) then continue; end if;
      elsif v_cur - v_held < w.persons then continue; end if;
      perform booking._waitlist_notify_entry(w.id, null);
      v_n := v_n + 1;
    end loop;
  end if;
  insert into booking.waitlist_session_state(rule_id,session_date,offered_free,updated_at)
  values (p_rule_id,p_date,v_cur,now())
  on conflict (rule_id,session_date) do update set offered_free = excluded.offered_free, updated_at = now();
  return v_n;
end $function$
;

-- Oikeudet: create or replace säilyttää olemassa olevien funktioiden oikeudet (booking_133/134/139 ennallaan).
