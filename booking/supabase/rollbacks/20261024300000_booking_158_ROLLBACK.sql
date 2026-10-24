-- ROLLBACK booking_158 (migraatio 20261024300000_booking_158_events.sql). Uudelleenajettava (toinen ajo ei tee mitään).
-- HUOM: poistaa pysyvästi tapahtumien resurssivaraukset (booking.event_resource_blocks) ja niistä syntyneet sulut (space_blocks.event_block_id),
-- sarakkeet schedule_rules.kind ja product_config.channels sekä asetuksen events.sale_enabled.
-- Tapahtumakerrat (schedule_rules) ja niiden kapasiteettipoolit (resources 'event_rule_<id>') jäävät tavallisiksi yhden päivän vuoroiksi.
-- Ota ennen ajoa talteen: select * from booking.event_resource_blocks; select id, product_id, kind from booking.schedule_rules where kind = 'event';
--   select product_id, channels from booking.product_config where channels is not null;
-- Lovi: booking.m158_lovi_rows-taulun rivit aktivoidaan takaisin (product_space_rules.active = true) ja taulu poistetaan.
-- Palauttaa funktiot täsmälleen tuotannon muotoon ennen booking_158:aa (pg_get_functiondef-tuloste sellaisenaan). Odotetut md5(pg_get_functiondef) ajon jälkeen:
--   booking._sessions: 872ef0fc6a9d38726ea2438f11ba3f01
--   booking._check_claim: bf875a55f4d73bfdcbaf107c29f09f45
--   booking._resolve_session: 132d5ce9356106af79cfa84658e76fd1
--   booking._block_conflict_pairs: cd2a64faf36994de5c99979816876f99
--   booking.space_blocks_managed_guard: 6b9f525403f3a69285b65921c1a79196
--   booking.closure_blocks_outbox_trg: 17ce83a9fbf50bebaffe2568438757ec
--   booking.closure_outbox_backfill: d6ddcaf1e152d74b8093d158e3394209
--   booking.public_catalog: b869be5d3444cc3d6923153efc336120
--   booking.public_availability: 503709f45fe0e98b9d4701c95297312f
--   booking.public_availability_all: eeb7cf54b957b2d29b9ea2fcc4f2a409
-- Lopussa tarkistus: jos jokin md5 ei täsmää, rollback keskeytyy (exception) ja koko transaktio perutaan.
set local lock_timeout = '5s';

-- 1) tapahtumien sulut pois (ennen funktioiden palautusta, jotta sulkukalenterin outbox ei saa rivejä)
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'booking' and table_name = 'space_blocks' and column_name = 'event_block_id') then
    perform set_config('booking.event_sync', 'on', true);
    execute 'delete from booking.space_blocks where event_block_id is not null';
    perform set_config('booking.event_sync', '', true);
  end if;
end $$;

drop trigger if exists zz_event_sync on booking.schedule_rules;
do $$ begin
  if to_regclass('booking.event_resource_blocks') is not null then
    execute 'drop trigger if exists zz_event_sync on booking.event_resource_blocks';
  end if;
end $$;

-- 2) korvatut funktiot tuotannon muotoon
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
end $function$;

CREATE OR REPLACE FUNCTION booking._resolve_session(p_rule_id bigint, p_date date, p_persons integer, p_enforce_deadline boolean, p_override_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_override_end timestamp with time zone DEFAULT NULL::timestamp with time zone, p_allow_override_shared boolean DEFAULT false)
 RETURNS TABLE(o_rule_id bigint, o_product_id bigint, o_space_id bigint, o_mode text, o_starts_at timestamp with time zone, o_ends_at timestamp with time zone, o_pool_ids bigint[])
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r booking.schedule_rules; pc booking.product_config; p kb.products; v kb.product_price_variants;
  s_start timestamptz; s_end timestamptz; v_pools bigint[];
begin
  select * into r from booking.schedule_rules where id = p_rule_id and active;
  if not found then perform booking._err('rule_not_found', 'Vuoroa ei löydy tai se ei ole käytössä'); end if;
  select * into pc from booking.product_config where product_id = r.product_id;
  if not found or not pc.bookable or pc.lifecycle <> 'current' then perform booking._err('not_bookable', 'Tuotetta ei voi varata'); end if;
  select * into p from kb.products where id = r.product_id and active;
  if not found then perform booking._err('product_inactive', 'Tuote ei ole myynnissä'); end if;
  if r.price_variant_id is not null then select * into v from kb.product_price_variants where id = r.price_variant_id; end if;

  if p_persons is null or p_persons < r.min_persons then
    perform booking._err('persons_min', format('Vähimmäishenkilömäärä on %s', r.min_persons));
  end if;
  if r.max_persons is not null and p_persons > r.max_persons then
    perform booking._err('persons_max', format('Enimmäishenkilömäärä on %s', r.max_persons));
  end if;
  if pc.max_persons is not null and p_persons > pc.max_persons then
    perform booking._err('persons_max', format('Enimmäishenkilömäärä on %s', pc.max_persons));
  end if;

  if p_override_start is not null then
    -- vapaa aika (vain käsivaraus / admin): vain yksityisvuoroille
    if r.mode <> 'exclusive' and not p_allow_override_shared then perform booking._err('override_not_allowed', 'Mukautettu aika on sallittu vain yksityisvuoroille'); end if;
    s_start := p_override_start; s_end := p_override_end;
    if s_end is null or s_end <= s_start then perform booking._err('bad_time', 'Virheellinen aika'); end if;
  else
    if p_date is null
       or not (extract(isodow from p_date)::smallint = any (r.weekdays))
       or (r.valid_from is not null and p_date < r.valid_from) or (r.valid_to is not null and p_date > r.valid_to)
       or (v.id is not null and (not v.active or (v.valid_from is not null and p_date < v.valid_from) or (v.valid_to is not null and p_date > v.valid_to)))
       or (p.valid_from is not null and p_date < p.valid_from) or (p.valid_to is not null and p_date > p.valid_to) then
      perform booking._err('no_session', 'Valitulle päivälle ei ole tätä vuoroa');
    end if;
    s_start := (p_date + r.start_time) at time zone booking._tz();
    s_end   := (p_date + r.start_time + make_interval(mins => r.duration_minutes)) at time zone booking._tz();
  end if;

  if p_enforce_deadline and s_start - make_interval(mins => r.deadline_minutes) <= now() then
    perform booking._err('sale_closed', 'Vuoron myynti on päättynyt');
  end if;

  select array_agg(pool_id order by pool_id) into v_pools from booking.schedule_rule_pools where rule_id = r.id;
  return query select r.id, r.product_id, r.space_id, r.mode, s_start, s_end, coalesce(v_pools, '{}'::bigint[]);
end $function$;

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
     and booking._res_active(c.status, c.hold_expires_at)
     and c.claim_end > now()
$function$;

CREATE OR REPLACE FUNCTION booking.space_blocks_managed_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if old.closure_event_id is not null and coalesce(current_setting('booking.closure_sync', true), '') <> 'on' then
    perform booking._err('closure_managed', 'Tämä sulku tulee sulkukalenterista – muuta tai poista tapahtuma kalenterissa (tai merkitse tapahtuma ohitettavaksi)');
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION booking.closure_blocks_outbox_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_exp booking.closure_exports;
  v_cal text;
begin
  -- silmukkaesto 1: kalenterista tuodut (hallitut) sulut eivät koskaan mene takaisin kalenteriin
  if tg_op = 'INSERT' and new.closure_event_id is not null then return new; end if;
  if tg_op in ('UPDATE', 'DELETE') and (old.closure_event_id is not null or (tg_op = 'UPDATE' and new.closure_event_id is not null)) then return coalesce(new, old); end if;

  if tg_op = 'DELETE' then
    select * into v_exp from booking.closure_exports where block_id = old.id;
    if found then
      insert into booking.closure_outbox(block_id, calendar_code, op, event_id) values (old.id, v_exp.calendar_code, 'delete', v_exp.event_id);
    end if;
    return old;
  end if;

  v_cal := case when new.active then booking._closure_calendar_for(new.space_id) end;
  if tg_op = 'INSERT' then
    if v_cal is not null then
      insert into booking.closure_outbox(block_id, calendar_code, op, event_id) values (new.id, v_cal, 'upsert', booking._closure_event_id(new.id));
    end if;
    return new;
  end if;

  -- UPDATE
  select * into v_exp from booking.closure_exports where block_id = new.id;
  if found and (v_cal is null or v_cal <> v_exp.calendar_code) then
    insert into booking.closure_outbox(block_id, calendar_code, op, event_id) values (new.id, v_exp.calendar_code, 'delete', v_exp.event_id);
  end if;
  if v_cal is not null and (old.space_id, old.starts_at, old.ends_at, old.reason, old.active) is distinct from (new.space_id, new.starts_at, new.ends_at, new.reason, new.active) then
    insert into booking.closure_outbox(block_id, calendar_code, op, event_id) values (new.id, v_cal, 'upsert', booking._closure_event_id(new.id));
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION booking.closure_outbox_backfill()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_n integer;
begin
  if booking._jwt_role() is distinct from 'service_role' and current_user not in ('postgres', 'service_role') then
    perform booking._err('forbidden', 'Vain service_role');
  end if;
  with ins as (
    insert into booking.closure_outbox(block_id, calendar_code, op, event_id)
    select b.id, booking._closure_calendar_for(b.space_id), 'upsert', booking._closure_event_id(b.id)
      from booking.space_blocks b
     where b.active and b.closure_event_id is null and b.ends_at > now() and booking._closure_calendar_for(b.space_id) is not null
       and not exists (select 1 from booking.closure_exports x where x.block_id = b.id)
       and not exists (select 1 from booking.closure_outbox o where o.block_id = b.id and o.status in ('pending', 'processing', 'blocked'))
    returning 1) select count(*) into v_n from ins;
  return v_n;
end $function$;

CREATE OR REPLACE FUNCTION booking.public_catalog()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'slug', p.slug, 'name', p.name, 'name_en', p.name_en,
      'description', p.description, 'description_en', p.description_en,
      'short_description', p.short_description, 'short_description_en', p.short_description_en,
      'category', p.category, 'sale_kind', pc.sale_kind,
      'price', p.price, 'price_type', p.price_type, 'price_text', p.price_text,
      'duration_text', p.duration_text, 'duration_text_en', p.duration_text_en, 'duration_minutes', p.duration_minutes,
      'min_persons', pc.min_persons, 'max_persons', case when pc.public_slots then booking._treatment_max_persons(p.id) else pc.max_persons end,
      'booking_kind', case when pc.public_slots then 'slots' else 'rules' end, 'slot_grid_minutes', case when pc.public_slots then 30 end,
      'options', booking._product_options_json(p.id, true), 'option_required', (pc.option_required and exists (select 1 from booking.product_options x where x.product_id = p.id and x.active)),
      'option_label', pc.option_label, 'option_label_en', pc.option_label_en,
      'voucher_note', pc.voucher_note, 'voucher_note_en', pc.voucher_note_en,
      'addons_enabled', (jsonb_array_length(booking._product_addon_codes(p.id)) > 0), 'allowed_addons', booking._product_addon_codes(p.id),
      'timeline', booking._timeline_json(p.id) -> 'segments', 'timeline_text', booking._timeline_json(p.id) ->> 'text', 'timeline_text_en', booking._timeline_json(p.id) ->> 'text_en'
    ) order by pc.sort_order, p.id), '[]'::jsonb)
  from booking.product_config pc
  join kb.products p on p.id = pc.product_id and p.active
  where pc.bookable and pc.shop_visible and pc.lifecycle = 'current'
    and (pc.public_slots or exists (select 1 from booking.schedule_rules r where r.product_id = p.id and r.active)) $function$;

CREATE OR REPLACE FUNCTION booking.public_availability(p_product_id bigint, p_from date, p_to date)
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

CREATE OR REPLACE FUNCTION booking.public_availability_all(p_from date, p_to date, p_audience text DEFAULT 'consumer'::text)
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

-- 3) uudet funktiot pois
drop function if exists booking.public_events(date, text);
drop function if exists booking.admin_event_list(text, boolean);
drop function if exists booking.admin_event_rule_upsert(bigint, bigint, jsonb);
drop function if exists booking.admin_event_rule_delete(bigint);
drop function if exists booking.admin_event_blocks_set(bigint, jsonb);
drop function if exists booking.admin_event_set_channels(bigint, text[]);
drop function if exists booking.admin_product_copy(bigint);
drop function if exists booking.admin_event_copy(bigint, boolean, integer);
drop function if exists booking.admin_event_rule_copy(bigint, date);
drop function if exists booking._product_copy_core(bigint);
drop function if exists booking._event_rule_copy_core(bigint, bigint, date, boolean, jsonb);
drop function if exists booking._event_rule_changed_trg();
drop function if exists booking._event_blocks_changed_trg();
drop function if exists booking._event_raise_conflicts(bigint);
drop function if exists booking._event_rule_conflicts(bigint);
drop function if exists booking._event_sync_blocks(bigint);
drop function if exists booking._event_rule_pool_sync(bigint);
drop function if exists booking._event_rule_json(bigint);
drop function if exists booking._event_jint(jsonb, text, integer, integer);
drop function if exists booking._event_jbool(jsonb, text);
drop function if exists booking._event_local_ts(text);
drop function if exists booking._event_block_is_own(bigint, bigint, bigint[]);
drop function if exists booking._channels_effective(text[], text);
drop function if exists booking._events_sale_enabled();
do $$ begin
  if to_regclass('booking.event_resource_blocks') is not null then
    execute 'drop function if exists booking._event_block_json(booking.event_resource_blocks)';
    execute 'drop function if exists booking._event_block_range(date, time without time zone, booking.event_resource_blocks)';
  end if;
end $$;

-- 4) skeema
drop index if exists booking.space_blocks_event_block_uq;
alter table booking.space_blocks drop column if exists event_block_id;
drop table if exists booking.event_resource_blocks;
alter table booking.product_config drop constraint if exists product_config_channels_check;
alter table booking.product_config drop column if exists channels;
drop index if exists booking.schedule_rules_event_idx;
alter table booking.schedule_rules drop constraint if exists schedule_rules_event_shape;
alter table booking.schedule_rules drop constraint if exists schedule_rules_kind_check;
alter table booking.schedule_rules drop column if exists kind;

-- 5) Lovi-rivit takaisin
do $$ begin
  if to_regclass('booking.m158_lovi_rows') is not null then
    execute 'update booking.product_space_rules s set active = true from booking.m158_lovi_rows m where m.psr_id = s.id and not s.active';
    execute 'drop table booking.m158_lovi_rows';
  end if;
end $$;

-- 6) asetus pois
delete from booking.settings where key = 'events.sale_enabled';

-- 7) tarkistus
do $$
declare x record; v text;
begin
  for x in select * from (values
    ('_sessions', '872ef0fc6a9d38726ea2438f11ba3f01'),
    ('_check_claim', 'bf875a55f4d73bfdcbaf107c29f09f45'),
    ('_resolve_session', '132d5ce9356106af79cfa84658e76fd1'),
    ('_block_conflict_pairs', 'cd2a64faf36994de5c99979816876f99'),
    ('space_blocks_managed_guard', '6b9f525403f3a69285b65921c1a79196'),
    ('closure_blocks_outbox_trg', '17ce83a9fbf50bebaffe2568438757ec'),
    ('closure_outbox_backfill', 'd6ddcaf1e152d74b8093d158e3394209'),
    ('public_catalog', 'b869be5d3444cc3d6923153efc336120'),
    ('public_availability', '503709f45fe0e98b9d4701c95297312f'),
    ('public_availability_all', 'eeb7cf54b957b2d29b9ea2fcc4f2a409')
  ) t(f, m) loop
    select md5(pg_get_functiondef(p.oid)) into v from pg_proc p where p.pronamespace = 'booking'::regnamespace and p.proname = x.f;
    if v is distinct from x.m then
      raise exception 'booking_158 rollback: booking.% md5 % <> odotettu %', x.f, v, x.m;
    end if;
  end loop;
end $$;
