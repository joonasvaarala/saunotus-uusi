-- DRAFT (EI AJETTU) 17.10.2026 – booking_17b_validators: claim-validointi, Rauni-puskuri, saunottajan Hall-tarkistus, legit-triggerit
-- Muuttaa käyttäytymistä: korvaa reservations_validate, _pool_peak, admin_create_block. Perustuu v_claims-näkymään (17a).
-- Regressioperiaate: varaukselle ilman legejä ja claim_offset=0/claim_minutes=NULL kaikki tarkistukset ja virhekoodit ovat samat kuin ennen
-- (space_closed, private_booked, public_shift_booked, bad_pool, capacity_exceeded, annual_card_*, hold_expired). Tarkistusjärjestys säilyy: pito -> sulku -> vuosikortti -> päällekkäisyys -> poolit.
-- Historia (completed/cancelled/no_show/expired) ohittaa edelleen kaiken (trigger palaa heti).
set local search_path = booking, extensions, public;

-- ---------- _pool_peak: lukee claimit (legit + claim-ikkuna) ----------
create or replace function booking._pool_peak(p_pool bigint, p_from timestamptz, p_to timestamptz, p_exclude bigint default null)
 returns integer language sql stable security definer set search_path to ''
as $function$
  with rs as (
    select c.claim_start as starts_at, c.claim_end as ends_at, c.persons
      from booking.v_claims c
     where c.mode = 'shared' and p_pool = any (c.pool_ids)
       and booking._res_active(c.status, c.hold_expires_at)
       and c.claim_start < p_to and c.claim_end > p_from
       and c.reservation_id is distinct from p_exclude
  ), pts as (
    select p_from as t
    union
    select starts_at from rs where starts_at > p_from and starts_at < p_to
  )
  select coalesce(max(l), 0)::integer
    from (select (select coalesce(sum(rs.persons), 0) from rs where rs.starts_at <= pts.t and rs.ends_at > pts.t) as l from pts) x
$function$;

-- ---------- _therapist_slack: Hallin ehto taitojoukoille ----------
-- Palauttaa vapaan kapasiteetin (cap - kysyntä) minimin ikkunassa SEN JÄLKEEN kun kandidaattileg (p_persons, p_session_key) on lisätty kysyntään.
-- >= 0 = mahtuu. Vuoropohjaiset taidot (yleinen, saunotus, morsiussauna): jokaiselle taitojoukolle S (jossa p_skill): vuorossa olevat joilla jokin S:n taito >= kysyntä jonka taito kuuluu S:ään.
-- Henkilömääräpohjaiset (Laura): kapasiteetti = taidon haltijoiden lukumäärä (vuoroja ei katsota). Sulku (space_blocks saunottaja-resurssille) = kapasiteetti 0.
create or replace function booking._therapist_slack(p_skill text, p_from timestamptz, p_to timestamptz, p_persons integer default 1,
                                                    p_session_key text default null, p_exclude_leg bigint default null, p_exclude_res bigint default null)
-- JIT pois: pelkkä JIT-käännös söi ~0,5 s per kutsu (kustannusarvio ylitti jit_above_cost); funktio on pieni ja kuumalla polulla
 returns integer language plpgsql stable security definer set search_path to '' set jit to off
as $function$
declare v_shift boolean; v_th bigint; v_slack integer;
begin
  select s.shift_based into v_shift from booking.skills s where s.code = p_skill and s.active;
  if v_shift is null then perform booking._err('skill_unknown', 'Saunottajan taitoa ei tunneta: ' || coalesce(p_skill, '?')); end if;
  select r.id into v_th from booking.resources r where r.code = 'saunottaja';

  if not v_shift then
    with dem0 as (
      select coalesce(c.session_key, 'L' || c.leg_id::text) as k, c.claim_start as s, c.claim_end as e, max(c.persons) as n
        from booking.v_claims c
       where c.role = 'therapist' and c.skill = p_skill and booking._res_active(c.status, c.hold_expires_at)
         and c.claim_start < p_to and c.claim_end > p_from
         and c.leg_id is distinct from p_exclude_leg and c.reservation_id is distinct from p_exclude_res
       group by 1, 2, 3
      union all select coalesce(p_session_key, 'NEW'), p_from, p_to, p_persons),
    dem as (select k, s, e, max(n) as n from dem0 group by k, s, e),
    pts as (select p_from as t union select s from dem where s > p_from and s < p_to
            union select b.starts_at from booking.space_blocks b where b.active and b.space_id = v_th and b.starts_at > p_from and b.starts_at < p_to
            union select b.ends_at from booking.space_blocks b where b.active and b.space_id = v_th and b.ends_at > p_from and b.ends_at < p_to),
    cap as (select count(distinct ts.staff_id)::int as c from booking.therapist_skills() ts where ts.skill = p_skill)
    select min(case when exists (select 1 from booking.space_blocks b where b.active and b.space_id = v_th and b.during @> pts.t) then 0 else (select c from cap) end
               - (select coalesce(sum(dem.n), 0) from dem where dem.s <= pts.t and dem.e > pts.t))::int
      into v_slack from pts;
    return v_slack;
  end if;

  with sk as (select s.code, (row_number() over (order by s.code) - 1)::int as i from booking.skills s where s.active and s.shift_based),
  me as (select (1 << sk.i) as bit from sk where sk.code = p_skill),
  duty as (select d.starts_at as s, d.ends_at as e,
                  coalesce((select sum(1 << sk.i) from sk where sk.code = any (d.skills)), 0)::int as mask
             from booking.therapist_on_duty(p_from, p_to) d),
  dem0 as (
    select coalesce(c.session_key, 'L' || c.leg_id::text) as k, c.claim_start as s, c.claim_end as e, max(c.persons) as n, (1 << sk.i) as bit
      from booking.v_claims c join sk on sk.code = c.skill
     where c.role = 'therapist' and booking._res_active(c.status, c.hold_expires_at)
       and c.claim_start < p_to and c.claim_end > p_from
       and c.leg_id is distinct from p_exclude_leg and c.reservation_id is distinct from p_exclude_res
     group by 1, 2, 3, sk.i
    union all select coalesce(p_session_key, 'NEW'), p_from, p_to, p_persons, (select bit from me)),
  dem as (select k, s, e, bit, max(n) as n from dem0 group by k, s, e, bit),
  pts as (select p_from as t
          union select dem.s from dem where dem.s > p_from and dem.s < p_to
          union select duty.s from duty where duty.s > p_from and duty.s < p_to
          union select duty.e from duty where duty.e > p_from and duty.e < p_to
          union select b.starts_at from booking.space_blocks b where b.active and b.space_id = v_th and b.starts_at > p_from and b.starts_at < p_to
          union select b.ends_at from booking.space_blocks b where b.active and b.space_id = v_th and b.ends_at > p_from and b.ends_at < p_to),
  subs as (select m from generate_series(1, (1 << (select count(*)::int from sk)) - 1) m where (m & (select bit from me)) <> 0)
  select min(case when exists (select 1 from booking.space_blocks b where b.active and b.space_id = v_th and b.during @> pts.t) then 0
                  else (select count(*) from duty where duty.s <= pts.t and duty.e > pts.t and (duty.mask & subs.m) <> 0) end
             - (select coalesce(sum(dem.n), 0) from dem where dem.s <= pts.t and dem.e > pts.t and (dem.bit & subs.m) <> 0))::int
    into v_slack from pts cross join subs;
  return v_slack;
end $function$;

-- ---------- _check_claim: yksi claim kerrallaan (ensisijainen tila tai leg) ----------
-- p_phase: 'all' | 'blocks' (vain sulku) | 'rest' (kaikki paitsi sulku) – reservations_validate säilyttää alkuperäisen tarkistusjärjestyksen.
-- p_override: ohittaa sulun ja saunottajatarkistuksen (EI päällekkäisyyttä/kiintiötä); vain admin (oikeus tarkistetaan kutsujassa).
create or replace function booking._check_claim(p_res_id bigint, p_leg_id bigint, p_resource bigint, p_role text, p_mode text,
    p_start timestamptz, p_end timestamptz, p_persons integer, p_pools bigint[], p_skill text, p_session_key text,
    p_quota_exempt boolean default false, p_override boolean default false, p_phase text default 'all')
 returns void language plpgsql security definer set search_path to ''
as $function$
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

-- ---------- reservations_validate: sama rakenne kuin nykyinen, claim-ikkuna + legit ----------
create or replace function booking.reservations_validate()
 returns trigger language plpgsql security definer set search_path to ''
as $function$
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
end $function$;

-- ---------- legit: validointi (BEFORE INSERT/UPDATE) ----------
create or replace function booking.reservation_legs_validate()
 returns trigger language plpgsql security definer set search_path to ''
as $function$
declare r booking.reservations;
begin
  select * into r from booking.reservations where id = new.reservation_id;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  if not booking._res_active(r.status, r.hold_expires_at) then return new; end if;    -- historia/peruttu/vanhentunut: ei tarkistusta
  perform booking._check_claim(new.reservation_id, new.id, new.resource_id, new.role, new.mode, new.starts_at, new.ends_at, new.persons,
                               new.pool_ids, new.skill, new.session_key, (new.quota_exempt or r.quota_exempt), (new.override_reason is not null or r.override_reason is not null), 'all');
  return new;
end $function$;
drop trigger if exists reservation_legs_validate on booking.reservation_legs;
create trigger reservation_legs_validate before insert or update on booking.reservation_legs
  for each row execute function booking.reservation_legs_validate();

-- ---------- legit seuraavat varausta (siirto/henkilömäärä/uudelleenaktivointi) ----------
create or replace function booking.reservations_sync_legs()
 returns trigger language plpgsql security definer set search_path to ''
as $function$
begin
  update booking.reservation_legs l set
         starts_at = new.starts_at + make_interval(mins => l.offset_min),
         ends_at = case when l.minutes is null then new.ends_at else new.starts_at + make_interval(mins => l.offset_min + l.minutes) end,
         persons = case when l.role = 'therapist' then l.persons else new.persons end,
         quota_exempt = new.quota_exempt
   where l.reservation_id = new.id;
  return null;
end $function$;
drop trigger if exists reservations_sync_legs on booking.reservations;
create trigger reservations_sync_legs after update on booking.reservations
  for each row when (old.starts_at is distinct from new.starts_at or old.ends_at is distinct from new.ends_at or old.status is distinct from new.status
                     or old.persons is distinct from new.persons or old.hold_expires_at is distinct from new.hold_expires_at
                     or old.quota_exempt is distinct from new.quota_exempt)
  execute function booking.reservations_sync_legs();

-- ---------- admin_create_block: päällekkäisyys claimeja vastaan (myös legit; saunottaja-/Rauni-sulku) ----------
create or replace function booking.admin_create_block(p_space_id bigint, p_starts_at timestamptz, p_ends_at timestamptz, p_reason text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare v_id bigint;
begin
  perform booking._require_permission('blocks.manage');
  perform pg_advisory_xact_lock(hashtextextended('booking:space:' || p_space_id::text, 0));
  perform booking._expire_holds(p_space_id);
  if exists (select 1 from booking.v_claims c where c.resource_id = p_space_id and booking._res_active(c.status, c.hold_expires_at)
              and tstzrange(c.claim_start, c.claim_end, '[)') && tstzrange(p_starts_at, p_ends_at, '[)')) then
    perform booking._err('has_reservations', 'Ajalla on varauksia – peru ne ensin');
  end if;
  insert into booking.space_blocks(space_id, starts_at, ends_at, reason, created_by)
  values (p_space_id, p_starts_at, p_ends_at, p_reason, auth.uid()) returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $function$;

-- ---------- oikeudet (CREATE OR REPLACE säilyttää olemassa olevat grantit; uudet vain service_role) ----------
revoke all on function booking._therapist_slack(text, timestamptz, timestamptz, integer, text, bigint, bigint) from public, anon, authenticated;
revoke all on function booking._check_claim(bigint, bigint, bigint, text, text, timestamptz, timestamptz, integer, bigint[], text, text, boolean, boolean, text) from public, anon, authenticated;
revoke all on function booking.reservation_legs_validate() from public, anon, authenticated;
revoke all on function booking.reservations_sync_legs() from public, anon, authenticated;
grant execute on function booking._therapist_slack(text, timestamptz, timestamptz, integer, text, bigint, bigint) to service_role;
grant execute on function booking._check_claim(bigint, bigint, bigint, text, text, timestamptz, timestamptz, integer, bigint[], text, text, boolean, boolean, text) to service_role;
grant execute on function booking.reservation_legs_validate() to service_role;
grant execute on function booking.reservations_sync_legs() to service_role;
