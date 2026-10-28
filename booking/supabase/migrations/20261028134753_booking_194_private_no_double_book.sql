-- booking_194: yksityistä vuoroa ei ylibuukata päällekkäin. Ylibuukkaus vain admin-roolille.
--
-- Yksityinen = varaus, joka vie resurssin yksinoikeudella:
--   reservations.mode = 'exclusive' tai reservation_legs.mode = 'exclusive' (product_space_rules.mode),
--   sekä resources.session_exclusive (eri istunto samassa tilassa, esim. Rauni/Lovi).
--   Exclusive-jonopito (waitlist notified) on sama kova esto, myös p_allow_overbookilla.
--   Puskuri (buffer_after_min, rituaali–rituaali oma) on mukana sekä moottorissa että private_conflict-kortissa.
-- Ei tuotenimistä. Jaettu vuoro (schedule_rules.mode = 'shared') saa yhä ylittää kapasiteetin,
-- mutta ei yksityisen varauksen päälle.
--
-- p_allow_overbook kelpaa vain booking.is_admin() (staff.role = 'admin').
-- Managerilla ja staffilla on bookings.manage, mutta ei admin-roolia: lippu hylätään koodilla overbook_admin_only.
-- p_allow_off_schedule pysyy bookings.manage -oikeudella (ei sama portti: bookings.override on admin+manager).
-- Julkiset RPC:t eivät saa lippuja. Hintoja ja ALV:tä ei muuteta.
-- Migraatiota ei ajeta tästä commitista.

set local lock_timeout = '5s';

-- ---------- 1) ylibuukkaus vain adminille ----------
create or replace function booking._arm_staff_overrides(p_overbook boolean, p_off_schedule boolean, p_start timestamptz default null, p_end timestamptz default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform booking._require_permission('bookings.manage');
  if coalesce(p_overbook, false) and not booking.is_admin() then
    perform booking._err('overbook_admin_only', 'Vain admin voi ylibuukata.');
  end if;
  if coalesce(p_overbook, false) or coalesce(p_off_schedule, false) then
    perform set_config('booking.allow_overbook', case when coalesce(p_overbook, false) then 'on' else 'off' end, true);
    perform set_config('booking.allow_off_schedule', case when coalesce(p_off_schedule, false) then 'on' else 'off' end, true);
    perform set_config('booking.off_schedule_start', coalesce(p_start::text, ''), true);
    perform set_config('booking.off_schedule_end', coalesce(p_end::text, ''), true);
  else
    perform booking._clear_staff_overrides();
  end if;
end $$;

create or replace function booking._staff_overbook()
returns boolean language sql stable security definer set search_path = '' as $$
  select current_setting('booking.allow_overbook', true) = 'on' and coalesce(booking.is_admin(), false)
$$;

comment on function booking._staff_overbook() is 'booking_194: kapasiteetin tai henkilömäärän ylitys vain admin-roolille. Aikataulun ulkopuolinen varaus on erillinen lippu.';

-- ---------- 2) yksinoikeus, puskuri ja exclusive-jonopito (näkymä ja esikatselu = moottori) ----------
-- Haltijan oma lunastus (waitlist_hold_exempt = pidon id) ja jonon sisäinen laskenta ('all') eivät törmää itseensä.
-- Henkilökunta ja p_allow_overbook eivät ohita exclusive-pitoa: _waitlist_hold_counts päästää staffin läpi, tätä ei.
create or replace function booking._exclusive_hold_blocks(p_space bigint, p_start timestamptz, p_end timestamptz)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from booking.waitlist_entries w
    join booking.schedule_rules sr on sr.id = w.rule_id and sr.mode = 'exclusive'
    join booking.resources res on res.id = p_space
    where w.space_id = p_space and w.status = 'notified' and w.hold_expires_at > now()
      and p_start < w.ends_at + make_interval(mins => res.buffer_after_min)
      and w.starts_at < p_end + make_interval(mins => res.buffer_after_min)
      and coalesce(current_setting('booking.waitlist_hold_exempt', true), '') is distinct from 'all'
      and coalesce(current_setting('booking.waitlist_hold_exempt', true), '') is distinct from w.id::text)
$$;

create or replace function booking._private_overlap_code(
  p_space bigint, p_mode text, p_start timestamptz, p_end timestamptz,
  p_exclude bigint default null, p_pools bigint[] default null)
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  v_res booking.resources;
  v_ritual boolean := booking._is_ritual(p_pools);
  v_gap integer;
  v_key text := booking._session_key(p_pools, p_mode, p_start);
  x record;
begin
  select * into v_res from booking.resources where id = p_space;
  if not found or p_start is null or p_end is null or p_end <= p_start then return null; end if;
  for x in
    select c.mode, c.claim_start, c.claim_end, c.session_key, c.pool_ids
      from booking.v_claims c
     where c.resource_id = p_space and c.role = 'space' and c.reservation_id is distinct from p_exclude
       and booking._res_active(c.status, c.hold_expires_at)
       and c.claim_start < p_end + make_interval(mins => greatest(v_res.buffer_after_min, coalesce(v_res.buffer_ritual_ritual_min, 0)))
       and c.claim_end > p_start - make_interval(mins => greatest(v_res.buffer_after_min, coalesce(v_res.buffer_ritual_ritual_min, 0)))
     order by (c.mode = 'exclusive') desc
  loop
    v_gap := case when v_ritual and booking._is_ritual(x.pool_ids) and v_res.buffer_ritual_ritual_min is not null
                  then v_res.buffer_ritual_ritual_min else v_res.buffer_after_min end;
    if not (p_start < x.claim_end + make_interval(mins => v_gap) and x.claim_start < p_end + make_interval(mins => v_gap)) then
      continue;
    end if;
    if x.mode = 'exclusive' then return 'private_booked'; end if;
    if coalesce(p_mode, '') = 'exclusive' then return 'public_shift_booked'; end if;
    if v_res.session_exclusive and (v_key is null or v_key is distinct from x.session_key) then return 'space_busy'; end if;
  end loop;
  if booking._exclusive_hold_blocks(p_space, p_start, p_end) then return 'private_booked'; end if;
  return null;
end $$;

comment on function booking._exclusive_hold_blocks(bigint, timestamptz, timestamptz) is
  'booking_194: voimassa oleva exclusive-jonopito (puskuri mukana). Ei väisty ylibuukkauksella eikä staff-roolilla. Haltijan exempt ja ''all'' eivät osu.';
comment on function booking._private_overlap_code(bigint, text, timestamptz, timestamptz, bigint, bigint[]) is
  'booking_194: sama ikkuna kuin _check_claim (buffer_after_min, rituaali–rituaali buffer_ritual_ritual_min, exclusive-jonopito). null = kortti ei ole varattu.';

-- ---------- 3) moottori: yksinoikeus ei ole ylibuukkausta ----------
CREATE OR REPLACE FUNCTION booking._check_claim(p_res_id bigint, p_leg_id bigint, p_resource bigint, p_role text, p_mode text, p_start timestamp with time zone, p_end timestamp with time zone, p_persons integer, p_pools bigint[], p_skill text, p_session_key text, p_quota_exempt boolean DEFAULT false, p_override boolean DEFAULT false, p_phase text DEFAULT 'all'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_res booking.resources; v_range tstzrange := tstzrange(p_start, p_end, '[)');
  x record; v_pool bigint; v_cap integer; v_peak integer; v_gap integer; v_maxgap integer; v_ritual boolean;
  v_ob boolean := booking._staff_overbook(); v_os boolean := booking._staff_off_schedule();
begin
  select * into v_res from booking.resources where id = p_resource;
  if not found then perform booking._err('resource_not_found', 'Resurssia ei löydy'); end if;
  perform pg_advisory_xact_lock(hashtextextended('booking:space:' || p_resource::text, 0));

  if p_phase in ('all', 'blocks') then
    if not p_override and not v_os and exists (select 1 from booking.space_blocks b where b.active and b.space_id = p_resource and b.during && v_range
                                    and not booking._event_block_is_own(b.event_block_id, p_res_id, p_pools)) then
      if p_role = 'therapist' then perform booking._err('therapist_closed', 'Saunottajat eivät ole saatavilla tälle ajalle (hoidot kiinni)');
      else perform booking._err('space_closed', 'Aika ei ole varattavissa (tila suljettu)'); end if;
    end if;
    if p_phase = 'blocks' then return; end if;
  end if;

  if p_role = 'therapist' then
    -- Ylibuukkaus ei vapauta saunottajaa kahteen varaukseen. Erillinen ylitys (p_override + perustelu) säilyy.
    if not p_override and booking._therapist_slack(p_skill, p_start, p_end, p_persons, p_session_key, p_leg_id, p_res_id) < 0 then
      perform booking._err('no_therapist', 'Ei vapaata saunottajaa tälle ajalle');
    end if;
    return;
  elsif p_role = 'group' then
    return;
  end if;

  v_ritual := booking._is_ritual(p_pools);
  v_maxgap := greatest(v_res.buffer_after_min, coalesce(v_res.buffer_ritual_ritual_min, 0));
  -- booking_194: exclusive ja session_exclusive eivät riipu ylibuukkauslipusta. Kapasiteetti (shared, sama istunto) riippuu.
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
    if not (p_start < x.claim_end + make_interval(mins => v_gap) and x.claim_start < p_end + make_interval(mins => v_gap)) then continue; end if;
    if p_mode = 'exclusive' and x.mode = 'exclusive' then
      perform booking._err('private_booked', 'Ajalle on jo yksityinen varaus – päällekkäistä varausta ei voi tehdä.');
    elsif p_mode = 'exclusive' then
      perform booking._err('public_shift_booked', 'Tälle ajalle on jo varaus – yksityisvuoroa ei voi varata päällekkäin.');
    elsif x.mode = 'exclusive' then
      perform booking._err('private_booked', 'Ajalle on jo yksityinen varaus – päällekkäistä varausta ei voi tehdä.');
    elsif v_res.session_exclusive and (p_session_key is null or p_session_key is distinct from x.session_key) then
      perform booking._err('space_busy', 'Tilassa on toinen istunto tälle ajalle – päällekkäistä varausta ei voi tehdä.');
    end if;
  end loop;

  -- Exclusive-jonopito on yksityinen claim: ylibuukkaus ei ohita (eikä _waitlist_hold_countsin staff-poikkeus).
  if booking._exclusive_hold_blocks(p_resource, p_start, p_end) then
    perform booking._err('private_booked', 'Ajalle on jo yksityinen varaus – päällekkäistä varausta ei voi tehdä.');
  end if;

  if p_mode = 'shared' and not v_ob then
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

-- ---------- 4) esikatselu: konflikti on kova esto, kapasiteetti ylibuukkaus ----------
create or replace function booking.admin_preview_booking_limits(
  p_kind text, p_rule_id bigint default null, p_date date default null, p_persons integer default null,
  p_product_id bigint default null, p_start timestamptz default null, p_end timestamptz default null,
  p_space_id bigint default null, p_exclude_reservation bigint default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r booking.schedule_rules; pc booking.product_config; s_start timestamptz; s_end timestamptz;
  v_over jsonb := '[]'::jsonb; v_off jsonb := '[]'::jsonb; v_conflict jsonb := '[]'::jsonb;
  v_code text; v_msg text; v_detail text; x record;
begin
  perform booking._require_permission('bookings.manage');
  perform booking._clear_staff_overrides();
  if p_kind = 'shift' then
    select * into r from booking.schedule_rules where id = p_rule_id and active;
    if r.id is null then return jsonb_build_object('ok', false, 'code', 'rule_not_found'); end if;
    if p_date is null then return jsonb_build_object('ok', false, 'code', 'no_session'); end if;
    s_start := coalesce(p_start, (p_date + r.start_time) at time zone booking._tz());
    s_end := coalesce(p_end, s_start + make_interval(mins => r.duration_minutes));
    if not (extract(isodow from p_date)::smallint = any (r.weekdays))
       or (r.valid_from is not null and p_date < r.valid_from) or (r.valid_to is not null and p_date > r.valid_to) then
      v_off := v_off || jsonb_build_array(jsonb_build_object('code', 'no_session'));
    end if;
    if p_start is not null and p_start is distinct from ((p_date + r.start_time) at time zone booking._tz()) then
      v_off := v_off || jsonb_build_array(jsonb_build_object('code', 'outside_hours'));
    end if;
    if exists (select 1 from booking.space_blocks b where b.active and b.space_id = r.space_id and b.starts_at < s_end and b.ends_at > s_start) then
      v_off := v_off || jsonb_build_array(jsonb_build_object('code', 'closure'));
    end if;
    if r.max_persons is not null and p_persons > r.max_persons then
      v_over := v_over || jsonb_build_array(jsonb_build_object('code', 'persons_max', 'max', r.max_persons, 'persons', p_persons));
    end if;
    for x in
      select res.capacity as cap, booking._pool_peak(rp.pool_id, s_start, s_end, p_exclude_reservation) as peak
        from booking.schedule_rule_pools rp join booking.resources res on res.id = rp.pool_id
       where rp.rule_id = r.id and res.capacity is not null
    loop
      if coalesce(x.peak, 0) + coalesce(p_persons, 0) > x.cap then
        v_over := v_over || jsonb_build_array(jsonb_build_object('code', 'capacity_exceeded', 'used', coalesce(x.peak, 0) + coalesce(p_persons, 0), 'capacity', x.cap));
        exit;
      end if;
    end loop;
    v_code := booking._private_overlap_code(r.space_id, r.mode, s_start, s_end, p_exclude_reservation,
      (select array_agg(rp.pool_id) from booking.schedule_rule_pools rp where rp.rule_id = r.id));
    if v_code is not null then
      v_conflict := v_conflict || jsonb_build_array(jsonb_build_object('code', v_code));
    end if;
  elsif p_kind = 'resource' then
    select * into pc from booking.product_config where product_id = p_product_id;
    if pc.product_id is null then return jsonb_build_object('ok', false, 'code', 'not_bookable'); end if;
    s_end := coalesce(p_end, p_start + make_interval(mins => pc.duration_minutes));
    if pc.max_persons is not null and p_persons > pc.max_persons then
      v_over := v_over || jsonb_build_array(jsonb_build_object('code', 'persons_max', 'max', pc.max_persons, 'persons', p_persons));
    end if;
    v_code := booking._time_window_violation(p_product_id, p_start, s_end);
    if v_code is not null then v_off := v_off || jsonb_build_array(jsonb_build_object('code', v_code)); end if;
    if p_space_id is not null and exists (select 1 from booking.space_blocks b where b.active and b.space_id = p_space_id and b.starts_at < s_end and b.ends_at > p_start) then
      v_off := v_off || jsonb_build_array(jsonb_build_object('code', 'closure'));
    end if;
    begin
      perform 1 from booking._plan_legs(p_product_id, p_start, s_end, p_persons, p_space_id, false, p_exclude_reservation, false);
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      if v_detail in ('space_busy', 'private_booked', 'public_shift_booked', 'no_therapist') then
        v_conflict := v_conflict || jsonb_build_array(jsonb_build_object('code', v_detail, 'message', v_msg));
      elsif v_detail in ('capacity_exceeded', 'persons_max', 'persons_limit') then
        v_over := v_over || jsonb_build_array(jsonb_build_object('code', v_detail, 'message', v_msg));
      elsif v_detail in ('space_closed', 'therapist_closed') then
        v_off := v_off || jsonb_build_array(jsonb_build_object('code', 'closure', 'message', v_msg));
      end if;
    end;
  else
    return jsonb_build_object('ok', false, 'code', 'invalid_param');
  end if;
  return jsonb_build_object('ok', true, 'overbook', v_over, 'off_schedule', v_off, 'conflict', v_conflict,
                            'overbooked', jsonb_array_length(v_over) > 0, 'off', jsonb_array_length(v_off) > 0,
                            'blocked', jsonb_array_length(v_conflict) > 0);
end $$;

-- ---------- 5) päivän vuorokortit: private_conflict ----------
CREATE OR REPLACE FUNCTION booking.admin_day_view(p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_from timestamptz := p_date::timestamp at time zone 'Europe/Helsinki';
        v_to timestamptz := (p_date + 1)::timestamp at time zone 'Europe/Helsinki';
        v_prep jsonb; v_totals jsonb;
begin
  perform booking._require_staff();
  with rs as (
    select r.rule_id, r.starts_at, r.ends_at, r.order_item_id, coalesce(it.product_name, '') as product_name
      from booking.reservations r left join booking.order_items it on it.id = r.order_item_id
     where r.starts_at < v_to and r.ends_at > v_from and booking._res_active(r.status, r.hold_expires_at)),
  per as (
    select rs.rule_id, rs.starts_at, rs.ends_at, rs.product_name, ai.addon_id, min(ad.code) as code, min(ai.product_name) as name, sum(ai.quantity)::int as qty
      from rs join booking.order_items ai on ai.parent_item_id = rs.order_item_id and ai.kind = 'addon'
      left join booking.addons ad on ad.id = ai.addon_id
     group by rs.rule_id, rs.starts_at, rs.ends_at, rs.product_name, ai.addon_id),
  grp as (
    select rule_id, starts_at, ends_at, product_name,
           jsonb_agg(jsonb_build_object('addon_id', addon_id, 'code', code, 'name', name, 'quantity', qty) order by name) as items
      from per group by rule_id, starts_at, ends_at, product_name)
  select (select coalesce(jsonb_agg(jsonb_build_object('rule_id', g.rule_id, 'starts_at', g.starts_at, 'ends_at', g.ends_at,
                    'product_name', g.product_name, 'items', g.items) order by g.starts_at, g.rule_id), '[]'::jsonb) from grp g),
         (select coalesce(jsonb_agg(jsonb_build_object('addon_id', t.addon_id, 'code', t.code, 'name', t.name, 'quantity', t.qty) order by t.name), '[]'::jsonb)
            from (select addon_id, min(code) as code, min(name) as name, sum(qty)::int as qty from per group by addon_id) t)
    into v_prep, v_totals;
  return jsonb_build_object(
    'date', p_date,
    'sessions', coalesce((select jsonb_agg(
        to_jsonb(s) || jsonb_build_object(
          'pool_capacity', cap.pool_capacity,
          'pool_peak', cap.pool_peak,
          'blocked', cap.blocked,
          'private_conflict', cap.private_conflict)
        order by s.starts_at, s.rule_id)
      from booking._sessions(p_date, p_date, null, false) s
      cross join lateral (
        select (select min(res.capacity) from booking.schedule_rule_pools rp
                  join booking.resources res on res.id = rp.pool_id where rp.rule_id = s.rule_id) as pool_capacity,
               (select coalesce(max(booking._pool_peak(rp.pool_id, s.starts_at, s.ends_at)), 0)
                  from booking.schedule_rule_pools rp where rp.rule_id = s.rule_id) as pool_peak,
               exists (select 1 from booking.space_blocks b
                         join booking.schedule_rules sr on sr.id = s.rule_id
                        where b.active and b.space_id = sr.space_id
                          and b.starts_at < s.ends_at and b.ends_at > s.starts_at) as blocked,
               booking._private_overlap_code((select sr.space_id from booking.schedule_rules sr where sr.id = s.rule_id),
                                            s.mode, s.starts_at, s.ends_at, null,
                                            (select array_agg(rp.pool_id) from booking.schedule_rule_pools rp where rp.rule_id = s.rule_id)) is not null as private_conflict
      ) cap), '[]'::jsonb),
    'reservations', coalesce((select jsonb_agg(jsonb_build_object(
        'reservation_id', r.id, 'order_id', o.id, 'order_no', o.order_no, 'status', r.status, 'payment_status', o.payment_status,
        'product_name', coalesce(it.product_name, p.name), 'mode', r.mode, 'starts_at', r.starts_at, 'ends_at', r.ends_at,
        'persons', r.persons, 'customer_name', c.name, 'customer_phone', c.phone, 'rule_id', r.rule_id, 'notes', r.notes,
        'annual_card', r.annual_card_id is not null, 'hold_expires_at', r.hold_expires_at,
        'source', coalesce(r.external_source, 'native'), 'external_id', r.external_id,
        'customer_kind', o.customer_kind, 'company', case when o.customer_kind <> 'private' then coalesce(o.billing ->> 'company', c.company) end,
        'space_code', sp.code, 'lifecycle', pcf.lifecycle, 'quota_exempt', r.quota_exempt, 'override_reason', r.override_reason,
        'overbooked', r.overbooked, 'off_schedule', r.off_schedule,
        'therapist_missing', r.therapist_missing, 'therapist_exception_at', r.therapist_exception_at, 'therapist_exception_note', r.therapist_exception_note,
        'therapist_missing_open', (r.therapist_missing and r.therapist_exception_at is null and not exists (select 1 from booking.reservation_legs tl where tl.reservation_id = r.id and tl.role = 'therapist')),
        'claim_offset_min', r.claim_offset_min, 'claim_minutes', r.claim_minutes, 'parent_reservation_id', r.parent_reservation_id,
        'option', booking._option_json(r.product_option_id),
        'option_missing', (r.product_option_id is null and exists (select 1 from booking.product_options x where x.product_id = r.product_id and x.active)),
        'legs', coalesce((select jsonb_agg(jsonb_build_object('leg_id', l.id, 'role', l.role, 'resource_code', lr.code, 'starts_at', l.starts_at, 'ends_at', l.ends_at,
                                  'persons', l.persons, 'skill', l.skill) order by l.starts_at, l.id)
                            from booking.reservation_legs l join booking.resources lr on lr.id = l.resource_id where l.reservation_id = r.id), '[]'::jsonb),
        'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', ai.addon_id, 'code', (select a2.code from booking.addons a2 where a2.id = ai.addon_id), 'name', ai.product_name, 'quantity', ai.quantity) order by ai.id)
                              from booking.order_items ai where ai.parent_item_id = r.order_item_id and ai.kind = 'addon'), '[]'::jsonb))
        order by r.starts_at, r.id)
        from booking.reservations r join booking.orders o on o.id = r.order_id join booking.resources sp on sp.id = r.space_id
        left join booking.order_items it on it.id = r.order_item_id left join kb.products p on p.id = r.product_id
        left join booking.product_config pcf on pcf.product_id = r.product_id
        left join booking.customers c on c.id = o.customer_id
        where r.starts_at < v_to and r.ends_at > v_from and booking._res_active(r.status, r.hold_expires_at)), '[]'::jsonb),
    'prep', v_prep, 'addon_totals', v_totals,
    'waitlist_holds', coalesce((select jsonb_agg(jsonb_build_object('rule_id', w.rule_id, 'starts_at', w.starts_at, 'persons', w.persons,
        'hold_expires_at', w.hold_expires_at) order by w.starts_at, w.id)
        from booking.waitlist_entries w where w.status = 'notified' and w.hold_expires_at > now()
         and w.starts_at < v_to and w.ends_at > v_from), '[]'::jsonb),
    'blocks', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'space_id', b.space_id, 'resource_code', br.code, 'closure_event_id', b.closure_event_id, 'starts_at', b.starts_at,
        'ends_at', b.ends_at, 'reason', b.reason) order by b.starts_at)
        from booking.space_blocks b join booking.resources br on br.id = b.space_id where b.active and b.starts_at < v_to and b.ends_at > v_from), '[]'::jsonb));
end $function$;

revoke all on function booking._exclusive_hold_blocks(bigint, timestamptz, timestamptz),
  booking._private_overlap_code(bigint, text, timestamptz, timestamptz, bigint, bigint[]) from public, anon, authenticated;
grant execute on function booking._exclusive_hold_blocks(bigint, timestamptz, timestamptz),
  booking._private_overlap_code(bigint, text, timestamptz, timestamptz, bigint, bigint[]) to service_role;
