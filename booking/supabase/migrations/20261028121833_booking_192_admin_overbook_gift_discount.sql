-- booking_192: hallinnan ylibuukkaus, aikataulun ulkopuolinen varaus, alennuskoodi ja lahjakortti.
-- Omistajan pyyntö (Uusi varaus + varauksen siirto). Hinnat ja ALV ennallaan: alennus käyttää samaa
-- booking._discount_split / _discount_state -polkua kuin verkkokauppa, lahjakortti samaa booking._gc_redeem-polkua
-- kuin admin_redeem_gift_card ja public_apply_gift_card (myös Johku-lähtöiset kortit).
--
-- Liput p_allow_overbook ja p_allow_off_schedule ovat vain hallinnan RPC:issä (oletus false).
-- Ne kelpaavat vain bookings.manage -oikeudella, samassa transaktiossa. Julkiset RPC:t nollaavat liput
-- eivätkä tarjoa parametreja. Julkinen vapaa kapasiteetti ei mene negatiiviseksi.
-- Varaukselle kirjataan overbooked / off_schedule ja tekijä; audit_log.action = STAFF_OVERRIDE.
-- Migraatiota ei ajeta tästä commitista: dev ja tuotanto ajetaan katselmoinnin jälkeen.

set local lock_timeout = '5s';

-- ---------- 1) varauksen merkinnät ----------
alter table booking.reservations
  add column if not exists overbooked boolean not null default false,
  add column if not exists overbooked_by uuid,
  add column if not exists off_schedule boolean not null default false,
  add column if not exists off_schedule_by uuid;
comment on column booking.reservations.overbooked is 'Henkilökunta ylitti kapasiteetin tai resurssikonfliktin (booking_192). Julkinen myynti näyttää vuoron täynnä.';
comment on column booking.reservations.off_schedule is 'Henkilökunta teki varauksen normaalin aikataulun, aukioloajan tai sulkukalenterin ulkopuolelle (booking_192).';

-- ---------- 2) liput: vain henkilökunta, vain tämä transaktio ----------
create or replace function booking._clear_staff_overrides()
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('booking.allow_overbook', 'off', true);
  perform set_config('booking.allow_off_schedule', 'off', true);
  perform set_config('booking.off_schedule_start', '', true);
  perform set_config('booking.off_schedule_end', '', true);
end $$;

create or replace function booking._arm_staff_overrides(p_overbook boolean, p_off_schedule boolean, p_start timestamptz default null, p_end timestamptz default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform booking._require_permission('bookings.manage');
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
  select current_setting('booking.allow_overbook', true) = 'on' and coalesce(booking.has_permission('bookings.manage'), false)
$$;

create or replace function booking._staff_off_schedule()
returns boolean language sql stable security definer set search_path = '' as $$
  select current_setting('booking.allow_off_schedule', true) = 'on' and coalesce(booking.has_permission('bookings.manage'), false)
$$;

create or replace function booking.reservations_stamp_overrides()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if booking._staff_overbook() then
    new.overbooked := true;
    if new.overbooked_by is null then new.overbooked_by := auth.uid(); end if;
  elsif tg_op = 'INSERT' or not coalesce(old.overbooked, false) then
    new.overbooked := false;
    new.overbooked_by := null;
  end if;
  if booking._staff_off_schedule() then
    new.off_schedule := true;
    if new.off_schedule_by is null then new.off_schedule_by := auth.uid(); end if;
  elsif tg_op = 'INSERT' or not coalesce(old.off_schedule, false) then
    new.off_schedule := false;
    new.off_schedule_by := null;
  end if;
  return new;
end $$;

drop trigger if exists reservations_stamp_overrides on booking.reservations;
create trigger reservations_stamp_overrides before insert or update on booking.reservations
  for each row execute function booking.reservations_stamp_overrides();

create or replace function booking.reservations_audit_overrides()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (new.overbooked and (tg_op = 'INSERT' or not coalesce(old.overbooked, false)))
     or (new.off_schedule and (tg_op = 'INSERT' or not coalesce(old.off_schedule, false))) then
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (auth.uid(), booking._jwt_role(), 'reservations', new.id::text, 'STAFF_OVERRIDE',
            case when tg_op = 'UPDATE' then jsonb_build_object('overbooked', old.overbooked, 'off_schedule', old.off_schedule) else null end,
            jsonb_build_object('overbooked', new.overbooked, 'overbooked_by', new.overbooked_by,
                               'off_schedule', new.off_schedule, 'off_schedule_by', new.off_schedule_by,
                               'starts_at', new.starts_at, 'persons', new.persons));
  end if;
  return null;
end $$;

drop trigger if exists reservations_audit_overrides on booking.reservations;
create trigger reservations_audit_overrides after insert or update on booking.reservations
  for each row execute function booking.reservations_audit_overrides();

-- ---------- 3) julkinen vapaa kapasiteetti ei mene negatiiviseksi ----------
create or replace function booking._pools_remaining(p_pools bigint[], p_from timestamptz, p_to timestamptz, p_exclude bigint default null)
returns integer language sql stable security definer set search_path = '' as $$
  select case when min(res.capacity) is null then null
              else greatest(min(res.capacity - booking._pool_peak(res.id, p_from, p_to, p_exclude)), 0)::integer end
    from booking.resources res where res.id = any (p_pools)
$$;

-- ---------- 4) moottori kunnioittaa lippuja; julkinen polku nollaa ne ----------
CREATE OR REPLACE FUNCTION booking._check_claim(p_res_id bigint, p_leg_id bigint, p_resource bigint, p_role text, p_mode text, p_start timestamp with time zone, p_end timestamp with time zone, p_persons integer, p_pools bigint[], p_skill text, p_session_key text, p_quota_exempt boolean DEFAULT false, p_override boolean DEFAULT false, p_phase text DEFAULT 'all'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_res booking.resources; v_range tstzrange := tstzrange(p_start, p_end, '[)');
  x record; v_pool bigint; v_cap integer; v_peak integer; v_gap integer; v_maxgap integer; v_ritual boolean; v_savu boolean;
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
    if not p_override and not v_ob and booking._therapist_slack(p_skill, p_start, p_end, p_persons, p_session_key, p_leg_id, p_res_id) < 0 then
      perform booking._err('no_therapist', 'Ei vapaata saunottajaa tälle ajalle');
    end if;
    return;
  elsif p_role = 'group' then
    return;
  end if;

  v_savu := (v_res.code = 'savusauna');
  v_ritual := booking._is_ritual(p_pools);
  v_maxgap := greatest(v_res.buffer_after_min, coalesce(v_res.buffer_ritual_ritual_min, 0));
  if not v_ob then
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

    if exists (select 1 from booking.waitlist_entries w
                 join booking.schedule_rules sr on sr.id = w.rule_id and sr.mode = 'exclusive'
                where w.space_id = p_resource and w.status = 'notified' and w.hold_expires_at > now()
                  and p_start < w.ends_at + make_interval(mins => v_res.buffer_after_min)
                  and w.starts_at < p_end + make_interval(mins => v_res.buffer_after_min)
                  and booking._waitlist_hold_counts(w.id)) then
      if v_savu then perform booking._err('private_booked', 'Savusauna on varattu yksityisvuorolle tälle ajalle');
      else perform booking._err('space_busy', 'Tila on varattu tälle ajalle (' || v_res.code || ')'); end if;
    end if;
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

CREATE OR REPLACE FUNCTION booking._resolve_session(p_rule_id bigint, p_date date, p_persons integer, p_enforce_deadline boolean, p_override_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_override_end timestamp with time zone DEFAULT NULL::timestamp with time zone, p_allow_override_shared boolean DEFAULT false)
 RETURNS TABLE(o_rule_id bigint, o_product_id bigint, o_space_id bigint, o_mode text, o_starts_at timestamp with time zone, o_ends_at timestamp with time zone, o_pool_ids bigint[])
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r booking.schedule_rules; pc booking.product_config; p kb.products; v kb.product_price_variants;
  s_start timestamptz; s_end timestamptz; v_pools bigint[];
  v_ob boolean := booking._staff_overbook(); v_os boolean := booking._staff_off_schedule();
  v_os_start text := nullif(current_setting('booking.off_schedule_start', true), '');
  v_os_end text := nullif(current_setting('booking.off_schedule_end', true), '');
begin
  select * into r from booking.schedule_rules where id = p_rule_id and active;
  if not found then perform booking._err('rule_not_found', 'Vuoroa ei löydy tai se ei ole käytössä'); end if;
  select * into pc from booking.product_config where product_id = r.product_id;
  if not found or not pc.bookable or pc.lifecycle <> 'current' then perform booking._err('not_bookable', 'Tuotetta ei voi varata'); end if;
  select * into p from kb.products where id = r.product_id and active;
  if not found then perform booking._err('product_inactive', 'Tuote ei ole myynnissä'); end if;
  if r.price_variant_id is not null then select * into v from kb.product_price_variants where id = r.price_variant_id; end if;
  if r.kind = 'event' and not booking._events_sale_enabled() and not booking.is_staff() then
    perform booking._err('sale_closed', 'Tapahtuman myynti ei ole vielä auki');
  end if;

  if p_persons is null or p_persons < r.min_persons then
    perform booking._err('persons_min', format('Vähimmäishenkilömäärä on %s', r.min_persons));
  end if;
  if not v_ob and r.max_persons is not null and p_persons > r.max_persons then
    perform booking._err('persons_max', format('Enimmäishenkilömäärä on %s', r.max_persons));
  end if;
  if not v_ob and pc.max_persons is not null and p_persons > pc.max_persons then
    perform booking._err('persons_max', format('Enimmäishenkilömäärä on %s', pc.max_persons));
  end if;

  if p_override_start is not null then
    if r.mode <> 'exclusive' and not p_allow_override_shared and not v_os then
      perform booking._err('override_not_allowed', 'Mukautettu aika on sallittu vain yksityisvuoroille');
    end if;
    s_start := p_override_start; s_end := p_override_end;
    if s_end is null or s_end <= s_start then perform booking._err('bad_time', 'Virheellinen aika'); end if;
  else
    if p_date is null then perform booking._err('no_session', 'Valitulle päivälle ei ole tätä vuoroa'); end if;
    if not v_os and (
         not (extract(isodow from p_date)::smallint = any (r.weekdays))
         or (r.valid_from is not null and p_date < r.valid_from) or (r.valid_to is not null and p_date > r.valid_to)
         or (v.id is not null and (not v.active or (v.valid_from is not null and p_date < v.valid_from) or (v.valid_to is not null and p_date > v.valid_to)))
         or (p.valid_from is not null and p_date < p.valid_from) or (p.valid_to is not null and p_date > p.valid_to)) then
      perform booking._err('no_session', 'Valitulle päivälle ei ole tätä vuoroa');
    end if;
    s_start := (p_date + r.start_time) at time zone booking._tz();
    s_end   := (p_date + r.start_time + make_interval(mins => r.duration_minutes)) at time zone booking._tz();
    if v_os and v_os_start is not null then
      s_start := v_os_start::timestamptz;
      s_end := v_os_end::timestamptz;
      if s_end is null or s_end <= s_start then perform booking._err('bad_time', 'Virheellinen aika'); end if;
    end if;
  end if;

  if p_enforce_deadline and s_start - make_interval(mins => r.deadline_minutes) <= now() then
    perform booking._err('sale_closed', 'Vuoron myynti on päättynyt');
  end if;

  select array_agg(pool_id order by pool_id) into v_pools from booking.schedule_rule_pools where rule_id = r.id;
  return query select r.id, r.product_id, r.space_id, r.mode, s_start, s_end, coalesce(v_pools, '{}'::bigint[]);
end $function$;

CREATE OR REPLACE FUNCTION booking.reservations_time_window()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_class text; w booking.time_window_rules; ls timestamp; le timestamp; v_dt text;
begin
  if new.status not in ('pending', 'confirmed') then return new; end if;
  if new.override_reason is not null or booking._staff_off_schedule() then return new; end if;
  if new.external_source is not null and coalesce(booking._jwt_role(), 'service_role') = 'service_role' then return new; end if;
  if tg_op = 'UPDATE' and old.product_id is not distinct from new.product_id and old.starts_at = new.starts_at and old.ends_at = new.ends_at
     and booking._res_active(old.status, old.hold_expires_at) then return new; end if;
  if new.parent_reservation_id is not null and booking._ritual_addon_start_ok(new.parent_reservation_id, new.product_id, new.starts_at) then return new; end if;
  select pc.time_window_class into v_class from booking.product_config pc where pc.product_id = new.product_id;
  if v_class is null then return new; end if;
  ls := new.starts_at at time zone booking._tz();
  le := new.ends_at at time zone booking._tz();
  v_dt := case when extract(isodow from ls) >= 6 then 'weekend' else 'weekday' end;
  select * into w from booking.time_window_rules where class = v_class and day_type = v_dt;
  if not found then return new; end if;
  if w.allowed_starts is not null and not (date_trunc('minute', ls)::time = any (w.allowed_starts)) then
    perform booking._err('ritual_start', 'Rituaalin alkuaika voi olla vain ' || (select string_agg(to_char(t, 'HH24:MI'), ', ' order by t) from unnest(w.allowed_starts) t));
  end if;
  if w.earliest_start is not null and ls::time < w.earliest_start
     or w.latest_end is not null and (le::time > w.latest_end or le::date <> ls::date) then
    perform booking._err('time_window', 'Hoitojen ja saunotusten aika: ' || case v_dt when 'weekday' then 'ma–pe' else 'la–su' end || ' alkaa aikaisintaan '
                         || to_char(w.earliest_start, 'HH24:MI') || ' ja päättyy viimeistään ' || to_char(w.latest_end, 'HH24:MI'));
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION booking._plan_legs(p_product_id bigint, p_start timestamp with time zone, p_end timestamp with time zone, p_persons integer, p_space_id bigint DEFAULT NULL::bigint, p_override boolean DEFAULT false, p_res_id bigint DEFAULT NULL::bigint, p_skip_therapist boolean DEFAULT false)
 RETURNS SETOF booking.leg_plan
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  pc booking.product_config; r record; v_no integer; v_picked boolean; v_cs timestamptz; v_ce timestamptz; v_pool bigint; v_pools bigint[];
  v_sess text; v_code text; v_msg text; v_e_code text; v_e_msg text; v_th bigint; v_row booking.leg_plan;
  v_ob boolean := booking._staff_overbook();
begin
  select * into pc from booking.product_config where product_id = p_product_id;
  if not found or pc.resource_class <> 'resourced' then perform booking._err('not_resourced', 'Tuotteella ei ole resurssisääntöjä'); end if;
  if p_persons is null or p_persons < pc.min_persons then perform booking._err('persons_min', format('Vähimmäishenkilömäärä on %s', pc.min_persons)); end if;
  if pc.max_persons is not null and p_persons > pc.max_persons and not v_ob then perform booking._err('persons_max', format('Enimmäishenkilömäärä on %s', pc.max_persons)); end if;
  v_th := booking._skill_block_resource(pc.required_skill);
  perform booking._lock_resources((select array_agg(x) from (select psr.space_id as x from booking.product_space_rules psr where psr.product_id = p_product_id and psr.active
                                                             union select v_th) q));
  for v_no in select distinct psr.leg_no from booking.product_space_rules psr where psr.product_id = p_product_id and psr.active order by 1 loop
    v_picked := false; v_code := null; v_msg := null;
    for r in select * from booking.product_space_rules psr where psr.product_id = p_product_id and psr.active and psr.leg_no = v_no order by psr.priority loop
      if p_persons < r.min_persons or (r.max_persons is not null and p_persons > r.max_persons and not v_ob) then
        if v_code is null then v_code := 'persons_limit'; v_msg := format('Henkilömäärä %s ei sovi tilaan (%s–%s)', p_persons, r.min_persons, coalesce(r.max_persons::text, '∞')); end if;
        continue;
      end if;
      if v_no = 1 and p_space_id is not null then
        if r.space_id <> p_space_id then continue; end if;
      elsif r.selection = 'manual' then continue;
      end if;
      v_cs := p_start + make_interval(mins => r.offset_min);
      v_ce := least(p_end, case when r.minutes is null then p_end else v_cs + make_interval(mins => r.minutes) end);
      if r.selection = 'auto_if_blocked' and not (v_no = 1 and p_space_id is not null) then
        if not exists (select 1 from booking.space_blocks b where b.active and b.space_id = r.requires_blocked_space_id and b.during && tstzrange(v_cs, v_ce, '[)')) then
          if v_code is null then v_code := 'lovi_only_when_rauni_closed'; v_msg := 'Lovi tarjotaan vain kun Rauni on suljettu'; end if;
          continue;
        end if;
      end if;
      v_pool := r.pool_id;
      if v_pool is null and v_no = 1 and r.role = 'space' and pc.start_pool_prefix is not null then
        select x.id into v_pool from booking.resources x
         where x.code = pc.start_pool_prefix || to_char(v_cs at time zone booking._tz(), 'HH24MI') and x.parent_id = r.space_id;
        if v_pool is null then
          if v_code is null then v_code := 'no_pool_for_start'; v_msg := 'Alkuajalle ei ole kapasiteettipoolia'; end if;
          continue;
        end if;
      end if;
      v_pools := case when v_pool is null then '{}'::bigint[] else array[v_pool] end;
      v_sess := booking._session_key(v_pools, r.mode, v_cs);
      begin
        perform booking._check_claim(p_res_id, null, r.space_id, r.role, r.mode, v_cs, v_ce, p_persons, v_pools, null, v_sess, false, p_override);
      exception when sqlstate 'BK001' then
        get stacked diagnostics v_e_msg = message_text, v_e_code = pg_exception_detail;
        if v_code is null then v_code := v_e_code; v_msg := v_e_msg; end if;
        continue;
      end;
      v_row := row(v_no, r.role, r.space_id, r.mode, v_pool, r.offset_min, r.minutes, v_cs, v_ce, p_persons, null, v_sess, r.id)::booking.leg_plan;
      return next v_row; v_picked := true; exit;
    end loop;
    if not v_picked then perform booking._err(coalesce(v_code, 'no_space'), coalesce(v_msg, 'Tilaa ei löydy tälle tuotteelle')); end if;
  end loop;

  if pc.required_skill is not null and not p_skip_therapist then
    v_cs := p_start + make_interval(mins => pc.therapist_offset_min);
    v_ce := least(p_end, case when pc.therapist_minutes is null then p_end else v_cs + make_interval(mins => pc.therapist_minutes) end);
    v_sess := case when pc.therapist_session_pool_id is not null then 'T:' || pc.therapist_session_pool_id::text || '@' || extract(epoch from v_cs)::bigint::text end;
    perform booking._check_claim(p_res_id, null, v_th, 'therapist', 'shared', v_cs, v_ce, pc.therapists_needed, '{}'::bigint[], pc.required_skill, v_sess, false, p_override);
    v_row := row(0, 'therapist', v_th, 'shared', null, pc.therapist_offset_min, pc.therapist_minutes, v_cs, v_ce, pc.therapists_needed, pc.required_skill, v_sess, null)::booking.leg_plan;
    return next v_row;
  end if;
  return;
end $function$;

create or replace function booking._treatment_slot_check(p_product bigint, p_start timestamptz, p_persons integer, p_lead boolean default true) returns timestamptz
  language plpgsql volatile security definer set search_path to '' as $function$
declare
  pc booking.product_config; p kb.products; ls timestamp; v_end timestamptz; v_code text; v_max integer; v_min integer;
  v_horizon integer := coalesce((booking._setting('public_treatment_horizon_days', '14'::jsonb) #>> '{}')::int, 14);
  v_lead integer := coalesce((booking._setting('public_treatment_min_lead_minutes', '120'::jsonb) #>> '{}')::int, 120);
begin
  -- Julkinen hoitoaika ei saa periä hallinnan lippuja (esim. henkilökunta verkkokaupassa).
  perform booking._clear_staff_overrides();
  select * into pc from booking.product_config where product_id = p_product;
  if not found or not pc.public_slots or not pc.bookable or not pc.shop_visible or pc.lifecycle <> 'current' then
    perform booking._err('not_bookable', 'Tuotetta ei voi varata verkossa');
  end if;
  select * into p from kb.products where id = p_product and active;
  if not found then perform booking._err('not_bookable', 'Tuotetta ei voi varata verkossa'); end if;
  v_min := greatest(coalesce(pc.min_persons, 1), 1);
  v_max := booking._treatment_max_persons(p_product);
  if p_persons is null or p_persons < v_min or p_persons > v_max then
    perform booking._err('invalid_persons', format('Henkilömäärä voi olla %s–%s', v_min, v_max));
  end if;
  if p_start is null then perform booking._err('bad_slot', 'Valitse aika'); end if;
  ls := p_start at time zone booking._tz();
  if extract(second from ls) <> 0 or extract(minute from ls)::int % 30 <> 0 then
    perform booking._err('bad_slot', 'Aloitusaika ei ole varattavissa');
  end if;
  v_end := p_start + make_interval(mins => coalesce(pc.duration_minutes, p.duration_minutes));
  if p_lead and p_start < now() + make_interval(mins => v_lead) then
    perform booking._err('too_soon', 'Aika on liian lähellä – valitse myöhempi aika');
  end if;
  if ls::date > (now() at time zone booking._tz())::date + v_horizon then
    perform booking._err('too_far', format('Aikoja voi varata enintään %s päivän päähän', v_horizon));
  end if;
  if ls::date < (now() at time zone booking._tz())::date then perform booking._err('invalid_date', 'Päivä ei ole varattavissa'); end if;
  if (pc.public_weekdays is not null and not (extract(isodow from ls)::smallint = any (pc.public_weekdays))) or not booking._public_shift_day_open(ls::date) then
    perform booking._err('not_offered_day', 'Tälle päivälle ei ole tarjolla hoitoja');
  end if;
  v_code := booking._time_window_violation(p_product, p_start, v_end);
  if v_code = 'ritual_start' then
    perform booking._err('ritual_start', 'Rituaalin alkuaika voi olla vain ' || (select string_agg(to_char(t, 'HH24:MI'), ', ' order by t) from booking.time_window_rules r, unnest(r.allowed_starts) t
                          where r.class = 'ritual' and r.day_type = case when extract(isodow from ls) >= 6 then 'weekend' else 'weekday' end));
  elsif v_code = 'time_window' then
    perform booking._err('time_window', 'Aika ei ole varattavissa (hoitoaika)');
  end if;
  return v_end;
end $function$;
-- ---------- 5) luonti- ja muutospolut nollaavat liput julkisella kanavalla ----------
CREATE OR REPLACE FUNCTION booking._create_booking_core(p_rule_id bigint, p_date date, p_persons integer, p_customer_id bigint, p_channel text, p_created_by uuid, p_locale text, p_note text, p_status text, p_hold_minutes integer, p_enforce_deadline boolean, p_override_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_override_end timestamp with time zone DEFAULT NULL::timestamp with time zone, p_price_override numeric DEFAULT NULL::numeric, p_annual_card_id bigint DEFAULT NULL::bigint, p_order_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  rs record; p kb.products;
  pr record; v_total numeric; v_order booking.orders; v_item_id bigint; v_res_id bigint;
  v_hold timestamptz;
begin
  if (p_channel is distinct from 'admin' and p_channel not in ('phone', 'email', 'walk_in', 'other')) or p_enforce_deadline then
    perform booking._clear_staff_overrides();
  end if;
  select * into rs from booking._resolve_session(p_rule_id, p_date, p_persons, p_enforce_deadline, p_override_start, p_override_end);
  select * into p from kb.products where id = rs.o_product_id;
  if p.vat_rate is null then perform booking._err('vat_missing', 'Tuotteelta puuttuu ALV-kanta'); end if;

  select * into pr from booking._rule_price(p_rule_id, p_persons);
  v_total := case when p_annual_card_id is not null then 0 else coalesce(p_price_override, pr.total) end;

  if p_order_id is null then
    insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_note, created_by)
    values (p_customer_id, case when p_status = 'confirmed' then 'confirmed' else 'pending' end, 'unpaid', v_total,
            p_channel, coalesce(p_locale, 'fi'), p_note, p_created_by)
    returning * into v_order;
    if p_status = 'confirmed' then update booking.orders set confirmed_at = now() where id = v_order.id; end if;
  else
    select * into v_order from booking.orders where id = p_order_id for update;
    if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
    if booking._order_invoice_locked(p_order_id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.'); end if;
    update booking.orders set total_gross = total_gross + v_total where id = p_order_id;
  end if;

  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
  values (v_order.id, p.id, p.name, 'reservation', 1, v_total, v_total, p.vat_rate,
          pr.breakdown || jsonb_build_object('rule_id', p_rule_id, 'rule_label', (select label from booking.schedule_rules where id = p_rule_id))
                       || case when p_annual_card_id is not null then jsonb_build_object('annual_card_id', p_annual_card_id) else '{}'::jsonb end)
  returning id into v_item_id;

  v_hold := case when p_status = 'pending' then now() + make_interval(mins => greatest(coalesce(p_hold_minutes, 15), 1)) end;
  insert into booking.reservations(order_id, order_item_id, product_id, rule_id, annual_card_id, space_id, mode, starts_at, ends_at, persons,
                                   pool_ids, status, hold_expires_at, created_by)
  values (v_order.id, v_item_id, p.id, p_rule_id, p_annual_card_id, rs.o_space_id, rs.o_mode, rs.o_starts_at, rs.o_ends_at, p_persons,
          rs.o_pool_ids, p_status, v_hold, p_created_by)
  returning id into v_res_id;

  return jsonb_build_object('order_id', v_order.id, 'order_no', v_order.order_no, 'public_token', v_order.public_token,
                            'reservation_id', v_res_id, 'total', v_total, 'starts_at', rs.o_starts_at, 'ends_at', rs.o_ends_at,
                            'status', p_status, 'hold_expires_at', v_hold, 'product_name', p.name);
end $function$;

CREATE OR REPLACE FUNCTION booking._create_legs_booking(p_lifecycle text, p_product_id bigint, p_start timestamp with time zone, p_end timestamp with time zone, p_persons integer, p_customer_id bigint, p_channel text, p_created_by uuid, p_note text, p_price numeric, p_space_id bigint, p_override boolean, p_override_reason text, p_quota_exempt boolean, p_parent_reservation_id bigint, p_order_id bigint DEFAULT NULL::bigint, p_option_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_hmin int := coalesce(nullif(current_setting('booking.checkout_hold_minutes', true), '')::int, 0); v_hold timestamptz; v_st text := 'confirmed'; v_hkind text := nullif(current_setting('booking.checkout_hold_kind', true), '');
  p kb.products; pc booking.product_config; v_end timestamptz; v_total numeric; v_order booking.orders; v_item bigint; v_res booking.reservations;
  v_plan booking.leg_plan[] := '{}'; lp booking.leg_plan; v_prim booking.leg_plan; v_parent bigint; v_pools bigint[]; v_off integer; v_cmin integer; v_n integer := 0; v_missing boolean := false; v_ecode text; v_opt bigint;
begin
  if p_channel is distinct from 'admin' then perform booking._clear_staff_overrides(); end if;
  select * into p from kb.products where id = p_product_id;
  if not found then perform booking._err('product_not_found', 'Tuotetta ei löydy'); end if;
  select * into pc from booking.product_config where product_id = p_product_id;
  if not found then perform booking._err('not_bookable', 'Tuotetta ei voi varata'); end if;
  if p_lifecycle is not null and pc.lifecycle <> p_lifecycle then
    perform booking._err('wrong_lifecycle', case p_lifecycle when 'old' then 'Valitse vanha tuote (current-tuotteet: Uusi varaus)' else 'Valitse nykyinen tuote' end);
  end if;
  if p.vat_rate is null then perform booking._err('vat_missing', 'Tuotteelta puuttuu ALV-kanta'); end if;
  v_opt := booking._resolve_product_option(p_product_id, p_option_code, true);
  v_end := coalesce(p_end, p_start + make_interval(mins => coalesce(pc.duration_minutes, p.duration_minutes)));
  if p_start is null or v_end is null or v_end <= p_start then perform booking._err('bad_time', 'Virheellinen aika'); end if;
  if p_override and (p_override_reason is null or length(btrim(p_override_reason)) < 3) then perform booking._err('override_reason_required', 'Ylitys vaatii perustelun'); end if;

  if cardinality(pc.requires_parent_product_ids) > 0 then
    select r.id into v_parent
      from booking.reservations r join booking.orders o on o.id = r.order_id
     where r.product_id = any (pc.requires_parent_product_ids) and booking._res_active(r.status, r.hold_expires_at)
       and r.starts_at <= p_start and r.ends_at >= v_end
       and (p_parent_reservation_id is null or r.id = p_parent_reservation_id)
     order by (o.customer_id is not distinct from p_customer_id) desc, r.starts_at limit 1;
    if v_parent is null and not p_override then
      perform booking._err('parent_required', 'Lisäpalvelu vaatii jälkilöyly-/yksityisvuorovarauksen samalle ajalle');
    end if;
  end if;

  begin
    for lp in select * from booking._plan_legs(p_product_id, p_start, v_end, p_persons, p_space_id, p_override) loop v_plan := array_append(v_plan, lp); end loop;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_ecode = pg_exception_detail;
    if v_ecode is distinct from 'no_therapist' then raise; end if;
    v_plan := '{}'; v_missing := true;
    for lp in select * from booking._plan_legs(p_product_id, p_start, v_end, p_persons, p_space_id, p_override, null, true) loop v_plan := array_append(v_plan, lp); end loop;
  end;
  select * into v_prim from unnest(v_plan) u where u.leg_no = 1 and u.role = 'space';
  if v_prim.resource_id is null then perform booking._err('no_primary_leg', 'Tuotteelta puuttuu ensisijainen tila (product_space_rules leg 1)'); end if;
  v_off := (extract(epoch from (v_prim.claim_start - p_start)) / 60)::int;
  v_cmin := case when v_prim.claim_end >= v_end then null else (extract(epoch from (v_prim.claim_end - v_prim.claim_start)) / 60)::int end;
  if v_prim.mode = 'exclusive' and (v_off <> 0 or v_cmin is not null) then perform booking._err('bad_rule', 'Yksinoikeusvarauksen claim-ikkuna on aina koko varaus'); end if;
  v_pools := case when v_prim.pool_id is null then '{}'::bigint[] else array[v_prim.pool_id] end;

  v_total := coalesce(p_price, coalesce(p.price, 0) + coalesce(p.extra_person_price, 0) * greatest(p_persons - coalesce(p.included_persons, p_persons), 0));
  if p_order_id is null then
    if v_hmin > 0 then v_st := 'pending'; v_hold := now() + make_interval(mins => v_hmin); end if;
    insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_note, created_by, confirmed_at, hold_kind)
    values (p_customer_id, v_st, 'unpaid', v_total, p_channel, 'fi', p_note, p_created_by, case when v_st = 'confirmed' then now() end,
            case when v_st = 'pending' then coalesce(v_hkind, 'checkout') end) returning * into v_order;
  else
    select * into v_order from booking.orders where id = p_order_id for update;
    if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
    if booking._order_invoice_locked(p_order_id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.'); end if;
    update booking.orders set total_gross = total_gross + v_total where id = p_order_id;
    if v_order.status = 'pending' then
      v_st := 'pending';
      v_hold := coalesce((select max(x.hold_expires_at) from booking.reservations x where x.order_id = p_order_id and x.status = 'pending' and x.hold_expires_at > now()),
                         now() + make_interval(mins => booking._checkout_hold_minutes()));
    end if;
  end if;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
  values (v_order.id, p.id, p.name, 'reservation', 1, v_total, v_total, p.vat_rate,
          jsonb_build_object('model', 'legs_v2', 'lifecycle', pc.lifecycle, 'persons', p_persons)) returning id into v_item;

  insert into booking.reservations(order_id, order_item_id, product_id, space_id, mode, starts_at, ends_at, persons, pool_ids, status, hold_expires_at,
                                   quota_exempt, claim_offset_min, claim_minutes, parent_reservation_id, override_reason, created_by, therapist_missing, product_option_id)
  values (v_order.id, v_item, p.id, v_prim.resource_id, v_prim.mode, p_start, v_end, p_persons, v_pools, v_st, v_hold,
          p_quota_exempt, v_off, v_cmin, v_parent, case when p_override then btrim(p_override_reason) end, p_created_by, v_missing, v_opt)
  returning * into v_res;

  for lp in select * from unnest(v_plan) u where not (u.leg_no = 1 and u.role = 'space') order by u.leg_no loop
    insert into booking.reservation_legs(reservation_id, resource_id, role, mode, starts_at, ends_at, offset_min, minutes, persons, pool_ids, skill, session_key,
                                         quota_exempt, override_reason, rule_id)
    values (v_res.id, lp.resource_id, lp.role, lp.mode, lp.claim_start, lp.claim_end, lp.offset_min, lp.minutes, lp.persons,
            case when lp.pool_id is null then '{}'::bigint[] else array[lp.pool_id] end, lp.skill, lp.session_key,
            p_quota_exempt, case when p_override then btrim(p_override_reason) end, lp.rule_id);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('order_id', v_order.id, 'order_no', v_order.order_no, 'reservation_id', v_res.id, 'total', v_total,
                            'starts_at', v_res.starts_at, 'ends_at', v_res.ends_at, 'legs', v_n, 'space_id', v_res.space_id,
                            'product_name', p.name, 'parent_reservation_id', v_parent, 'hold_expires_at', v_hold, 'res_status', v_st,
                            'therapist_missing', v_missing, 'warning', case when v_missing then 'therapist_missing' end,
                            'option', booking._option_json(v_opt));
end $function$;

create or replace function booking._change_booking_core(
  p_reservation_id bigint, p_rule_id bigint, p_date date, p_persons integer,
  p_enforce_deadline boolean, p_notice_hours integer, p_actor uuid, p_via text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  res booking.reservations; o booking.orders; rs record; pr record; v_keep boolean := (p_rule_id is null and p_date is null);
  v_persons integer; v_rule bigint; v_total numeric; v_paid numeric; v_old booking.reservations; v_addons numeric; v_order_total numeric;
  v_locked boolean;
begin
  if p_enforce_deadline or p_notice_hours is not null or not coalesce(booking.has_permission('bookings.manage'), false) then
    perform booking._clear_staff_overrides();
  end if;
  if (p_rule_id is null) <> (p_date is null) then perform booking._err('invalid_change', 'Anna sekä uusi vuoro että päivä, tai kumpikaan'); end if;
  select * into res from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  select * into o from booking.orders where id = res.order_id;
  v_locked := booking._order_invoice_locked(o.id);
  if res.status <> 'confirmed' or o.status <> 'confirmed' then
    perform booking._err('not_changeable', 'Vain vahvistettua varausta voi muuttaa');
  end if;
  if v_locked and p_notice_hours is not null and coalesce(p_persons, res.persons) <> res.persons then
    perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
  end if;
  if p_notice_hours is not null and res.starts_at - make_interval(hours => p_notice_hours) < now() then
    perform booking._err('change_too_late', format('Varausta voi muuttaa itse viimeistään %s tuntia ennen vuoron alkua – ota yhteyttä sähköpostitse', p_notice_hours));
  end if;
  v_old := res;
  v_persons := coalesce(p_persons, res.persons);
  v_rule := coalesce(p_rule_id, res.rule_id);

  if v_keep then
    select * into rs from booking._resolve_session(v_rule, null, v_persons, false, res.starts_at, res.ends_at, true);
  else
    select * into rs from booking._resolve_session(v_rule, p_date, v_persons, p_enforce_deadline);
  end if;
  if rs.o_product_id is distinct from res.product_id then
    perform booking._err('product_mismatch', 'Varauksen voi siirtää vain saman tuotteen toiseen vuoroon');
  end if;
  if p_notice_hours is not null and rs.o_starts_at - make_interval(hours => p_notice_hours) < now() then
    perform booking._err('change_too_late', format('Uuden vuoron pitää alkaa vähintään %s tuntia päästä', p_notice_hours));
  end if;

  if not v_locked then
    select * into pr from booking._rule_price(v_rule, v_persons);
    v_total := case when res.annual_card_id is not null then 0 else pr.total end;
    v_addons := booking._addon_total_after(res.order_item_id, v_persons);
    select coalesce(sum(amount) filter (where status in ('paid','partially_refunded','refunded')), 0) into v_paid from booking.payments where order_id = o.id;
    if p_notice_hours is not null and v_paid > 0 and (v_total + v_addons) is distinct from o.total_gross then
      perform booking._err('price_change_requires_staff', 'Maksettu varaus, jonka hinta muuttuisi: ota yhteyttä henkilökuntaan');
    end if;
  end if;

  update booking.reservations set rule_id = v_rule, space_id = rs.o_space_id, mode = rs.o_mode, starts_at = rs.o_starts_at,
         ends_at = rs.o_ends_at, persons = v_persons, pool_ids = rs.o_pool_ids
   where id = res.id returning * into res;

  if not v_locked then
    update booking.order_items set unit_price_gross = v_total, line_total_gross = v_total,
           price_breakdown = pr.breakdown || jsonb_build_object('rule_id', v_rule, 'rule_label', (select label from booking.schedule_rules where id = v_rule))
     where id = res.order_item_id;
    perform booking._clamp_addons(res.order_item_id, v_persons);
    update booking.orders set total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = o.id), 0) where id = o.id
      returning total_gross into v_order_total;
    update booking.payments set amount = v_order_total where order_id = o.id and status = 'pending' and provider = 'manual';
    perform booking._refresh_order_payment(o.id);
  else
    v_order_total := o.total_gross;
  end if;

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (p_actor, booking._jwt_role(), 'reservations', res.id::text, p_via, to_jsonb(v_old),
          case when v_locked then to_jsonb(res) || jsonb_build_object('invoice_locked', true) else to_jsonb(res) end);

  return jsonb_build_object('reservation_id', res.id, 'order_id', o.id, 'order_no', o.order_no, 'starts_at', res.starts_at, 'ends_at', res.ends_at,
                            'persons', res.persons, 'total', v_order_total, 'rule_id', v_rule, 'product_id', res.product_id,
                            'overbooked', res.overbooked, 'off_schedule', res.off_schedule)
         || case when v_locked then jsonb_build_object('invoice_locked', true) else '{}'::jsonb end;
end $$;

-- Tekninen lahjakorttivirhe ei näy henkilökunnalle.
create or replace function booking.payments_gift_card_guard_trg() returns trigger language plpgsql security definer set search_path to ''
as $$ begin
  if new.method = 'gift_card' and new.gift_card_id is null then
    perform booking._err('gift_card_required', 'Lahjakorttimaksu tarvitsee lahjakortin koodin.');
  end if;
  if new.method <> 'gift_card' and new.gift_card_id is not null then
    perform booking._err('invalid_payment_method', 'gift_card_id sallitaan vain maksutavalla gift_card');
  end if;
  if new.method = 'gift_card' and exists (select 1 from booking.order_items oi where oi.order_id = new.order_id and oi.kind = 'gift_card') then
    perform booking._err('gift_card_not_allowed', 'Lahjakortilla ei voi ostaa lahjakorttia');
  end if;
  return new;
end $$;
-- ---------- 6) alennus ja lahjakortti hallinnan varaukseen (sama laskenta kuin kaupassa) ----------
create or replace function booking._apply_admin_discount(p_order_id bigint, p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_code text := booking._norm_code(p_code);
  v_card booking.annual_cards; d booking.discount_codes; v_err text;
  r booking.reservations; v_day date; v_lines jsonb; v_calc jsonb; s jsonb;
  v_disc numeric := 0; v_total numeric; pr record; v_inserted boolean := false;
begin
  perform booking._require_permission('bookings.manage');
  select total_gross into v_total from booking.orders where id = p_order_id;
  if v_code is null or v_code = '' then
    return jsonb_build_object('total', v_total, 'discount', 0, 'payment_inserted', false);
  end if;
  if char_length(v_code) > 40 then perform booking._err('invalid_code', booking._code_msg('invalid_code')); end if;
  select * into r from booking.reservations where order_id = p_order_id order by id limit 1;
  if r.id is null then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  v_day := (r.starts_at at time zone booking._tz())::date;
  select * into v_card from booking.annual_cards where code = v_code;
  if v_card.id is null then select * into d from booking.discount_codes where code = v_code for update; end if;
  if v_card.id is null and d.id is null then perform booking._err('invalid_code', booking._code_msg('invalid_code')); end if;

  if v_card.id is not null or coalesce(d.is_annual_card_code, false) then
    if r.persons is distinct from booking._annual_max_persons() then perform booking._err('annual_card_persons', booking._code_msg('annual_card_persons')); end if;
    if exists (select 1 from booking.order_items oi where oi.order_id = p_order_id and oi.kind = 'addon' and oi.quantity > 0) then
      perform booking._err('annual_card_no_addons', booking._code_msg('annual_card_no_addons'));
    end if;
    v_err := booking._annual_rule_check(r.rule_id, v_day, v_card, d);
    if v_err is not null then perform booking._err(v_err, booking._code_msg(v_err)); end if;
    if v_card.id is not null and (select customer_id from booking.orders where id = p_order_id) is distinct from v_card.customer_id then
      perform booking._err('annual_card_customer_mismatch', booking._code_msg('annual_card_customer_mismatch'));
    end if;
    select * into pr from booking._rule_price(r.rule_id, r.persons);
    update booking.order_items set line_total_gross = 0, unit_price_gross = 0,
           discount_amount = case when v_card.id is not null then pr.total else line_total_gross end,
           discount_code_id = d.id
     where order_id = p_order_id and kind = 'reservation';
    update booking.order_items set line_total_gross = 0, discount_amount = line_total_gross where order_id = p_order_id and kind = 'addon';
    update booking.orders set total_gross = 0, discount_code_id = d.id, payment_status = 'paid' where id = p_order_id;
    if d.id is not null then update booking.discount_codes set used_count = used_count + 1 where id = d.id; end if;
    if v_card.id is not null then update booking.reservations set annual_card_id = v_card.id where id = r.id; end if;
    update booking.payments set status = 'cancelled' where order_id = p_order_id and status = 'pending';
    insert into booking.payments(order_id, method, provider, status, amount, paid_at, note, created_by)
    values (p_order_id, 'annual_card', 'manual', 'paid', 0, now(), 'Vuosikortti / koodi ' || v_code, auth.uid());
    return jsonb_build_object('total', 0, 'discount', coalesce(pr.total, v_total), 'discount_code', v_code,
                              'code_type', case when v_card.id is not null then 'annual_card' else 'annual_code' end,
                              'payment_inserted', true);
  end if;

  v_err := booking._discount_state(d);
  if v_err is not null then perform booking._err(v_err, booking._code_msg(v_err)); end if;
  select coalesce(jsonb_agg(jsonb_build_object('key', oi.id, 'product_id', oi.product_id, 'kind', oi.kind, 'gross', oi.line_total_gross) order by oi.id), '[]'::jsonb)
    into v_lines from booking.order_items oi where oi.order_id = p_order_id;
  v_calc := booking._discount_split(d, v_lines);
  v_disc := (v_calc ->> 'discount')::numeric;
  if v_disc <= 0 then perform booking._err('code_not_applicable', booking._code_msg('code_not_applicable')); end if;
  for s in select x from jsonb_array_elements(v_calc -> 'shares') x loop
    update booking.order_items set discount_code_id = d.id, discount_amount = coalesce(discount_amount, 0) + (s ->> 'amount')::numeric,
           line_total_gross = line_total_gross - (s ->> 'amount')::numeric
     where id = (s ->> 'key')::bigint and order_id = p_order_id;
  end loop;
  update booking.orders set discount_code_id = d.id,
         total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = p_order_id), 0)
   where id = p_order_id returning total_gross into v_total;
  update booking.discount_codes set used_count = used_count + 1 where id = d.id;
  if v_total <= 0 then
    update booking.payments set status = 'cancelled' where order_id = p_order_id and status = 'pending';
    insert into booking.payments(order_id, method, provider, status, amount, paid_at, note, created_by)
    values (p_order_id, 'other', 'manual', 'paid', 0, now(), 'Alennuskoodi ' || d.code || ' (100 %)', auth.uid());
    update booking.orders set payment_status = 'paid' where id = p_order_id;
    v_inserted := true;
  end if;
  return jsonb_build_object('total', v_total, 'discount', v_disc, 'discount_code', d.code, 'code_type', 'discount', 'payment_inserted', v_inserted);
end $$;

create or replace function booking._apply_admin_gift(p_order_id bigint, p_code text, p_remainder_method text, p_paid boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  g booking.gift_cards; v_norm text := booking.gift_code_norm(p_code); v_res jsonb; v_rest numeric; v_rm text; v_paid boolean;
  v_total numeric;
begin
  perform booking._require_permission('bookings.manage');
  if v_norm is null or v_norm = '' then
    return jsonb_build_object('gift_card_amount', 0);
  end if;
  if v_norm !~ '^[A-Z0-9]{12}$' then perform booking._err('gift_card_not_found', 'Koodia ei löydy tai se ei ole käytettävissä'); end if;
  select * into g from booking.gift_cards where code = v_norm;
  if not found or g.status in ('cancelled', 'pending_payment') then
    perform booking._err('gift_card_not_found', 'Koodia ei löydy tai se ei ole käytettävissä');
  end if;
  select total_gross into v_total from booking.orders where id = p_order_id;
  if coalesce(v_total, 0) <= 0 then
    return jsonb_build_object('gift_card_amount', 0, 'gift_card_skipped', true, 'remaining', 0, 'total', v_total);
  end if;
  if not exists (select 1 from booking.payments where order_id = p_order_id and status = 'pending') then
    insert into booking.payments(order_id, method, provider, status, amount, created_by)
    values (p_order_id, 'pay_later', 'manual', 'pending', v_total, auth.uid());
  end if;
  v_res := booking._gc_redeem(p_order_id, g.id, null, 'Hallinta', false);
  v_rest := coalesce((v_res ->> 'remaining')::numeric, 0);
  if v_rest > 0.004 then
    v_rm := coalesce(nullif(btrim(coalesce(p_remainder_method, '')), ''), 'pay_later');
    if v_rm = 'gift_card' then v_rm := 'pay_later'; end if;
    if not exists (select 1 from booking.payment_methods where code = v_rm and active) then
      perform booking._err('invalid_payment_method', 'Maksutapa ei ole käytössä');
    end if;
    v_paid := coalesce(p_paid, false) and v_rm not in ('pay_later', 'invoice', 'bank_transfer');
    insert into booking.payments(order_id, method, provider, status, amount, paid_at, note, created_by)
    values (p_order_id, v_rm, 'manual', case when v_paid then 'paid' else 'pending' end, v_rest,
            case when v_paid then now() end, 'Lahjakortin jälkeen jäljelle jäänyt osuus', auth.uid());
    perform booking._refresh_order_payment(p_order_id);
  end if;
  return jsonb_build_object('gift_card_amount', v_res -> 'amount', 'remaining', v_rest, 'gift_card', v_res -> 'gift_card',
                            'total', (select total_gross from booking.orders where id = p_order_id));
end $$;

-- ---------- 7) hallinnan RPC:t ----------
drop function if exists booking.admin_create_booking(bigint, date, integer, bigint, jsonb, text, boolean, text, timestamptz, timestamptz, numeric, text, jsonb, text);
create function booking.admin_create_booking(
  p_rule_id bigint, p_date date, p_persons integer,
  p_customer_id bigint default null, p_customer jsonb default null,
  p_payment_method text default 'pay_later', p_paid boolean default false,
  p_note text default null, p_start timestamptz default null, p_end timestamptz default null,
  p_price numeric default null, p_channel text default 'admin',
  p_addons jsonb default null, p_invoice_reference text default null,
  p_discount_code text default null, p_gift_card_code text default null,
  p_remainder_method text default null,
  p_allow_overbook boolean default false, p_allow_off_schedule boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_cust bigint := p_customer_id; v_res jsonb; v_email text; v_order bigint; v_pm booking.payment_methods;
  v_kind text; v_is_company boolean; v_company jsonb; v_add numeric; v_total numeric; v_consent boolean; v_ref text := nullif(btrim(coalesce(p_invoice_reference, '')), '');
  v_method text := p_payment_method; v_paid boolean := coalesce(p_paid, false); v_gc text := nullif(btrim(coalesce(p_gift_card_code, '')), '');
  v_extra jsonb := '{}'::jsonb; v_disc jsonb;
begin
  perform booking._require_permission('bookings.manage');
  perform booking._arm_staff_overrides(p_allow_overbook, p_allow_off_schedule, p_start, p_end);
  if v_method = 'gift_card' and v_gc is null then perform booking._err('gift_card_code_required', 'Anna lahjakortin koodi.'); end if;
  if v_gc is not null then v_method := 'pay_later'; v_paid := false; end if;
  select * into v_pm from booking.payment_methods where code = v_method and active;
  if not found then perform booking._err('invalid_payment_method', 'Maksutapa ei ole käytössä'); end if;
  if p_channel not in ('admin','phone','email','walk_in','other') then perform booking._err('invalid_channel', 'Virheellinen lähdekanava'); end if;
  if p_price is not null and p_price < 0 then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
  if v_ref is not null and char_length(v_ref) > 100 then perform booking._err('invalid_reference', 'Viite on liian pitkä (enintään 100 merkkiä)'); end if;
  if v_cust is null then
    if p_customer is null or char_length(btrim(coalesce(p_customer ->> 'name', ''))) < 2 then
      perform booking._err('customer_required', 'Valitse asiakas tai anna nimi');
    end if;
    v_kind := lower(btrim(coalesce(nullif(p_customer ->> 'kind', ''), 'private')));
    select ck.is_company into v_is_company from booking.customer_kinds ck where ck.code = v_kind and ck.active;
    if v_is_company is null then perform booking._err('invalid_customer_kind', 'Valitse asiakastyyppi (yksityinen / yritys)'); end if;
    v_email := lower(nullif(btrim(coalesce(p_customer ->> 'email', '')), ''));
    if v_email is not null and not booking._valid_email(v_email) then perform booking._err('invalid_email', 'Tarkista sähköpostiosoite'); end if;
    v_consent := coalesce((p_customer ->> 'marketing_consent')::boolean, false);
    if v_is_company then
      v_company := booking._clean_company(p_customer -> 'company_details');
      v_cust := booking._upsert_company_customer(v_kind, btrim(p_customer ->> 'name'), v_email, nullif(btrim(coalesce(p_customer ->> 'phone', '')), ''),
                  v_company, v_consent, 'admin', coalesce(p_customer ->> 'language', 'fi'));
    elsif v_email is not null then
      v_cust := booking._upsert_customer(btrim(p_customer ->> 'name'), v_email, nullif(btrim(coalesce(p_customer ->> 'phone', '')), ''),
                 v_consent, 'admin', coalesce(p_customer ->> 'language', 'fi'));
    else
      insert into booking.customers(name, phone, company, language, marketing_consent, marketing_consent_at, marketing_consent_source)
      values (btrim(p_customer ->> 'name'), nullif(btrim(coalesce(p_customer ->> 'phone', '')), ''), nullif(btrim(coalesce(p_customer ->> 'company', '')), ''),
              coalesce(p_customer ->> 'language', 'fi'), v_consent,
              case when v_consent then now() end, case when v_consent then 'admin' end)
      returning id into v_cust;
    end if;
  elsif not exists (select 1 from booking.customers where id = v_cust) then
    perform booking._err('customer_not_found', 'Asiakasta ei löydy');
  end if;

  v_res := booking._create_booking_core(p_rule_id, p_date, p_persons, v_cust, p_channel, auth.uid(), 'fi', p_note,
                                        'confirmed', null, false, p_start, p_end, p_price);
  v_order := (v_res ->> 'order_id')::bigint;
  perform booking._stamp_order_billing(v_order, v_cust, v_company);
  if v_ref is not null then update booking.orders set invoice_reference = v_ref where id = v_order and customer_kind <> 'private'; end if;
  v_add := booking._attach_addons((v_res ->> 'reservation_id')::bigint, p_addons);
  v_disc := booking._apply_admin_discount(v_order, p_discount_code);
  v_total := (v_disc ->> 'total')::numeric;
  v_extra := v_disc;
  if coalesce((v_disc ->> 'payment_inserted')::boolean, false) then
    null;
  elsif v_gc is not null then
    v_extra := v_disc || booking._apply_admin_gift(v_order, v_gc, p_remainder_method, p_paid);
    v_total := coalesce((v_extra ->> 'total')::numeric, v_total);
  else
    insert into booking.payments(order_id, method, provider, status, amount, paid_at, created_by)
    values (v_order, v_method, 'manual', case when v_paid then 'paid' else 'pending' end, v_total,
            case when v_paid then now() end, auth.uid());
    update booking.orders set payment_status = case when v_paid or v_total <= 0 then 'paid' else 'unpaid' end where id = v_order;
  end if;
  return v_res - 'public_token' || jsonb_build_object('customer_id', v_cust, 'total', v_total, 'addons_total', v_add) || v_extra;
end $$;

drop function if exists booking.admin_change_booking(bigint, bigint, date, integer);
create function booking.admin_change_booking(
  p_reservation_id bigint, p_rule_id bigint default null, p_date date default null, p_persons integer default null,
  p_allow_overbook boolean default false, p_allow_off_schedule boolean default false,
  p_start timestamptz default null, p_end timestamptz default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform booking._require_permission('bookings.manage');
  if p_rule_id is null and p_date is null and p_persons is null and p_start is null then perform booking._err('invalid_change', 'Ei muutettavaa'); end if;
  perform booking._arm_staff_overrides(p_allow_overbook, p_allow_off_schedule, p_start, p_end);
  return booking._change_booking_core(p_reservation_id, p_rule_id, p_date, p_persons, false, null, auth.uid(), 'ADMIN_CHANGE')
         || jsonb_build_object('ok', true);
end $$;

drop function if exists booking.admin_create_resource_booking(bigint, timestamptz, integer, bigint, jsonb, timestamptz, bigint, text, boolean, text, numeric, boolean, text, jsonb, bigint, text, text);
drop function if exists booking.admin_create_old_booking(bigint, timestamptz, integer, bigint, jsonb, timestamptz, bigint, text, boolean, text, numeric, boolean, text, jsonb, bigint, text, text);
drop function if exists booking._admin_create_legs(text, bigint, timestamptz, timestamptz, integer, bigint, jsonb, text, boolean, text, numeric, bigint, boolean, text, jsonb, bigint, text, boolean, text);

create function booking._admin_create_legs(
  p_lifecycle text, p_product_id bigint, p_start timestamptz, p_end timestamptz, p_persons integer,
  p_customer_id bigint, p_customer jsonb, p_payment_method text, p_paid boolean, p_note text, p_price numeric,
  p_space_id bigint, p_override boolean, p_override_reason text, p_addons jsonb, p_parent_reservation_id bigint,
  p_invoice_reference text, p_quota_exempt boolean, p_option_code text default null,
  p_discount_code text default null, p_gift_card_code text default null, p_remainder_method text default null,
  p_allow_overbook boolean default false, p_allow_off_schedule boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_cust bigint := p_customer_id; v_pm booking.payment_methods; v_res jsonb; v_order bigint; v_add numeric; v_total numeric;
  v_ref text := nullif(btrim(coalesce(p_invoice_reference, '')), '');
  v_method text := p_payment_method; v_paid boolean := coalesce(p_paid, false); v_gc text := nullif(btrim(coalesce(p_gift_card_code, '')), '');
  v_disc jsonb; v_extra jsonb;
begin
  perform booking._require_permission('bookings.manage');
  if p_override then perform booking._require_permission('bookings.override'); end if;
  perform booking._arm_staff_overrides(p_allow_overbook, p_allow_off_schedule, null, null);
  if v_method = 'gift_card' and v_gc is null then perform booking._err('gift_card_code_required', 'Anna lahjakortin koodi.'); end if;
  if v_gc is not null then v_method := 'pay_later'; v_paid := false; end if;
  select * into v_pm from booking.payment_methods where code = v_method and active;
  if not found then perform booking._err('invalid_payment_method', 'Maksutapa ei ole käytössä'); end if;
  if p_price is not null and p_price < 0 then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
  if v_ref is not null and char_length(v_ref) > 100 then perform booking._err('invalid_reference', 'Viite on liian pitkä (enintään 100 merkkiä)'); end if;
  if v_cust is null then
    if p_customer is null then perform booking._err('customer_required', 'Valitse asiakas tai anna nimi'); end if;
    v_cust := (booking.admin_create_customer(p_customer) ->> 'id')::bigint;
  elsif not exists (select 1 from booking.customers where id = v_cust) then
    perform booking._err('customer_not_found', 'Asiakasta ei löydy');
  end if;
  v_res := booking._create_legs_booking(p_lifecycle, p_product_id, p_start, p_end, p_persons, v_cust, 'admin', auth.uid(), p_note, p_price, p_space_id,
                                        p_override, p_override_reason, p_quota_exempt, p_parent_reservation_id, null, p_option_code);
  v_order := (v_res ->> 'order_id')::bigint;
  perform booking._stamp_order_billing(v_order, v_cust, null);
  if v_ref is not null then update booking.orders set invoice_reference = v_ref where id = v_order and customer_kind <> 'private'; end if;
  v_add := booking._attach_addons((v_res ->> 'reservation_id')::bigint, p_addons);
  v_disc := booking._apply_admin_discount(v_order, p_discount_code);
  v_total := (v_disc ->> 'total')::numeric;
  v_extra := v_disc;
  if coalesce((v_disc ->> 'payment_inserted')::boolean, false) then
    null;
  elsif v_gc is not null then
    v_extra := v_disc || booking._apply_admin_gift(v_order, v_gc, p_remainder_method, p_paid);
    v_total := coalesce((v_extra ->> 'total')::numeric, v_total);
  else
    insert into booking.payments(order_id, method, provider, status, amount, paid_at, created_by)
    values (v_order, v_method, 'manual', case when v_paid then 'paid' else 'pending' end, v_total, case when v_paid then now() end, auth.uid());
    update booking.orders set payment_status = case when v_paid or v_total <= 0 then 'paid' else 'unpaid' end where id = v_order;
  end if;
  return v_res || jsonb_build_object('customer_id', v_cust, 'total', v_total, 'addons_total', v_add) || v_extra;
end $$;

create function booking.admin_create_resource_booking(
  p_product_id bigint, p_start timestamptz, p_persons integer, p_customer_id bigint default null, p_customer jsonb default null,
  p_end timestamptz default null, p_space_id bigint default null, p_payment_method text default 'pay_later', p_paid boolean default false,
  p_note text default null, p_price numeric default null, p_override boolean default false, p_override_reason text default null,
  p_addons jsonb default null, p_parent_reservation_id bigint default null, p_invoice_reference text default null, p_option_code text default null,
  p_discount_code text default null, p_gift_card_code text default null, p_remainder_method text default null,
  p_allow_overbook boolean default false, p_allow_off_schedule boolean default false)
returns jsonb language sql security definer set search_path = '' as $$
  select booking._admin_create_legs('current', p_product_id, p_start, p_end, p_persons, p_customer_id, p_customer, p_payment_method, p_paid, p_note, p_price,
    p_space_id, p_override, p_override_reason, p_addons, p_parent_reservation_id, p_invoice_reference, false, p_option_code,
    p_discount_code, p_gift_card_code, p_remainder_method, p_allow_overbook, p_allow_off_schedule)
$$;

create function booking.admin_create_old_booking(
  p_product_id bigint, p_start timestamptz, p_persons integer, p_customer_id bigint default null, p_customer jsonb default null,
  p_end timestamptz default null, p_space_id bigint default null, p_payment_method text default 'pay_later', p_paid boolean default false,
  p_note text default null, p_price numeric default null, p_override boolean default false, p_override_reason text default null,
  p_addons jsonb default null, p_parent_reservation_id bigint default null, p_invoice_reference text default null, p_option_code text default null,
  p_discount_code text default null, p_gift_card_code text default null, p_remainder_method text default null,
  p_allow_overbook boolean default false, p_allow_off_schedule boolean default false)
returns jsonb language sql security definer set search_path = '' as $$
  select booking._admin_create_legs('old', p_product_id, p_start, p_end, p_persons, p_customer_id, p_customer, p_payment_method, p_paid, p_note, p_price,
    p_space_id, p_override, p_override_reason, p_addons, p_parent_reservation_id, p_invoice_reference, false, p_option_code,
    p_discount_code, p_gift_card_code, p_remainder_method, p_allow_overbook, p_allow_off_schedule)
$$;

-- Esikatselu: sama koodilogiikka kuin public_preview_code, ilman julkista rajoitinta. Oma hinta korvaa vuoron hinnan.
create or replace function booking.admin_preview_discount_code(
  p_code text, p_rule_id bigint default null, p_date date default null, p_persons integer default null,
  p_addons jsonb default null, p_price numeric default null, p_product_id bigint default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_code text := booking._norm_code(p_code); v_card booking.annual_cards; d booking.discount_codes;
  r booking.schedule_rules; pr record; v_lines jsonb := '[]'::jsonb; v_sub numeric; v_err text; v_calc jsonb; e jsonb; a booking.addons; v_q int;
  p kb.products;
begin
  perform booking._require_permission('bookings.manage');
  if v_code = '' or char_length(v_code) > 40 then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  if p_rule_id is not null then
    select * into r from booking.schedule_rules where id = p_rule_id and active;
    if r.id is null or p_persons is null or p_persons < 1 then
      return jsonb_build_object('ok', false, 'code', 'invalid_session', 'message', 'Valitse vuoro ja henkilömäärä');
    end if;
    select * into pr from booking._rule_price(p_rule_id, p_persons);
    v_sub := coalesce(p_price, pr.total);
    v_lines := jsonb_build_array(jsonb_build_object('key', 0, 'product_id', r.product_id, 'kind', 'reservation', 'gross', v_sub));
  elsif p_product_id is not null then
    select * into p from kb.products where id = p_product_id;
    if p.id is null or p_persons is null or p_persons < 1 then
      return jsonb_build_object('ok', false, 'code', 'invalid_session', 'message', 'Valitse tuote ja henkilömäärä');
    end if;
    v_sub := coalesce(p_price, coalesce(p.price, 0) + coalesce(p.extra_person_price, 0) * greatest(p_persons - coalesce(p.included_persons, p_persons), 0));
    v_lines := jsonb_build_array(jsonb_build_object('key', 0, 'product_id', p.id, 'kind', 'reservation', 'gross', v_sub));
  else
    return jsonb_build_object('ok', false, 'code', 'invalid_session', 'message', 'Valitse vuoro ja henkilömäärä');
  end if;
  if p_addons is not null and jsonb_typeof(p_addons) = 'array' then
    for e in select x from jsonb_array_elements(p_addons) x limit 20 loop
      continue when jsonb_typeof(e) <> 'object' or coalesce(e ->> 'quantity', '') !~ '^\d{1,4}$' or coalesce(e ->> 'id', '') !~ '^\d{1,18}$';
      v_q := (e ->> 'quantity')::int; continue when v_q = 0;
      select * into a from booking.addons where id = (e ->> 'id')::bigint and active;
      continue when a.id is null;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('key', a.id, 'product_id', null, 'kind', 'addon', 'gross', a.price_gross * v_q));
      v_sub := v_sub + a.price_gross * v_q;
    end loop;
  end if;
  select * into v_card from booking.annual_cards where code = v_code;
  if v_card.id is null then select * into d from booking.discount_codes where code = v_code; end if;
  if v_card.id is null and d.id is null then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  if v_card.id is not null or coalesce(d.is_annual_card_code, false) then
    if p_rule_id is not null then
      v_err := booking._annual_rule_check(p_rule_id, p_date, v_card, d);
      if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
    end if;
    return jsonb_build_object('ok', true, 'type', case when v_card.id is not null then 'annual_card' else 'annual_code' end, 'code', v_code,
      'subtotal', v_sub, 'discount', v_sub, 'total', 0, 'valid_to', coalesce(v_card.valid_to, d.valid_to));
  end if;
  v_err := booking._discount_state(d);
  if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
  v_calc := booking._discount_split(d, v_lines);
  if (v_calc ->> 'discount')::numeric <= 0 then
    return jsonb_build_object('ok', false, 'code', 'code_not_applicable', 'message', booking._code_msg('code_not_applicable'));
  end if;
  return jsonb_build_object('ok', true, 'type', 'discount', 'code', v_code, 'kind', d.kind, 'value', d.value, 'subtotal', v_sub,
    'discount', (v_calc ->> 'discount')::numeric, 'total', v_sub - (v_calc ->> 'discount')::numeric);
end $$;

-- Sama kelpoisuus kuin public_check_gift_card, ilman julkista rajoitinta. Johku-kortit mukana.
create or replace function booking.admin_check_gift_card(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare g booking.gift_cards; v_norm text := booking.gift_code_norm(p_code); v_eff text; v_red boolean; v_why text;
begin
  perform booking._require_permission('bookings.manage');
  if v_norm !~ '^[A-Z0-9]{12}$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', 'Koodia ei löydy tai se ei ole käytettävissä');
  end if;
  select * into g from booking.gift_cards where code = v_norm;
  if not found or g.status in ('cancelled', 'pending_payment') then
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', 'Koodia ei löydy tai se ei ole käytettävissä');
  end if;
  v_eff := case when g.status = 'active' and g.valid_to is not null and g.valid_to < booking._gc_today() then 'expired' else g.status end;
  v_why := case when not booking._gc_flag('gift_cards.redeem_enabled') then 'redeem_disabled'
                when g.source = 'johku' and not booking._gc_flag('gift_cards.johku_cards_redeemable') then 'johku_cards_closed'
                when v_eff = 'expired' then 'expired' when v_eff = 'used' or g.balance <= 0 then 'empty'
                when v_eff = 'pending_verification' or not g.balance_verified then 'verification_pending' end;
  v_red := v_why is null and v_eff = 'active';
  return jsonb_build_object('ok', true, 'code', booking.gift_code_fmt(g.code), 'type', g.kind, 'source', g.source,
    'status', v_eff, 'balance', g.balance, 'currency', g.currency, 'valid_to', g.valid_to, 'redeemable', v_red,
    'not_redeemable_reason', v_why, 'balance_verified', g.balance_verified);
end $$;

-- Varoitukset ennen tallennusta. Ei luo varausta eikä kuluta koodeja.
create or replace function booking.admin_preview_booking_limits(
  p_kind text, p_rule_id bigint default null, p_date date default null, p_persons integer default null,
  p_product_id bigint default null, p_start timestamptz default null, p_end timestamptz default null,
  p_space_id bigint default null, p_exclude_reservation bigint default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r booking.schedule_rules; pc booking.product_config; s_start timestamptz; s_end timestamptz;
  v_pools bigint[]; v_cap integer; v_peak integer; v_over jsonb := '[]'::jsonb; v_off jsonb := '[]'::jsonb;
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
    if r.mode = 'exclusive' and exists (
         select 1 from booking.reservations x where x.space_id = r.space_id and x.id is distinct from p_exclude_reservation
           and booking._res_active(x.status, x.hold_expires_at) and x.starts_at < s_end and x.ends_at > s_start) then
      v_over := v_over || jsonb_build_array(jsonb_build_object('code', 'space_busy'));
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
      if v_detail in ('capacity_exceeded', 'space_busy', 'private_booked', 'public_shift_booked', 'persons_max', 'persons_limit') then
        v_over := v_over || jsonb_build_array(jsonb_build_object('code', v_detail, 'message', v_msg));
      elsif v_detail in ('space_closed', 'therapist_closed') then
        v_off := v_off || jsonb_build_array(jsonb_build_object('code', 'closure', 'message', v_msg));
      end if;
    end;
  else
    return jsonb_build_object('ok', false, 'code', 'invalid_param');
  end if;
  return jsonb_build_object('ok', true, 'overbook', v_over, 'off_schedule', v_off,
                            'overbooked', jsonb_array_length(v_over) > 0, 'off', jsonb_array_length(v_off) > 0);
end $$;

-- Päivänäkymän vuoroihin kapasiteetti, kuorma ja sulku (henkilökunnan varoitus 12/10).
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
          'blocked', cap.blocked)
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
                          and b.starts_at < s.ends_at and b.ends_at > s.starts_at) as blocked
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

-- ---------- 8) oikeudet ----------
revoke all on function booking._clear_staff_overrides(), booking._arm_staff_overrides(boolean, boolean, timestamptz, timestamptz),
  booking._staff_overbook(), booking._staff_off_schedule(), booking.reservations_stamp_overrides(), booking.reservations_audit_overrides(),
  booking._apply_admin_discount(bigint, text), booking._apply_admin_gift(bigint, text, text, boolean),
  booking._admin_create_legs(text, bigint, timestamptz, timestamptz, integer, bigint, jsonb, text, boolean, text, numeric, bigint, boolean, text, jsonb, bigint, text, boolean, text, text, text, text, boolean, boolean)
  from public, anon, authenticated;
revoke all on function
  booking.admin_create_booking(bigint, date, integer, bigint, jsonb, text, boolean, text, timestamptz, timestamptz, numeric, text, jsonb, text, text, text, text, boolean, boolean),
  booking.admin_change_booking(bigint, bigint, date, integer, boolean, boolean, timestamptz, timestamptz),
  booking.admin_create_resource_booking(bigint, timestamptz, integer, bigint, jsonb, timestamptz, bigint, text, boolean, text, numeric, boolean, text, jsonb, bigint, text, text, text, text, text, boolean, boolean),
  booking.admin_create_old_booking(bigint, timestamptz, integer, bigint, jsonb, timestamptz, bigint, text, boolean, text, numeric, boolean, text, jsonb, bigint, text, text, text, text, text, boolean, boolean),
  booking.admin_preview_discount_code(text, bigint, date, integer, jsonb, numeric, bigint),
  booking.admin_check_gift_card(text),
  booking.admin_preview_booking_limits(text, bigint, date, integer, bigint, timestamptz, timestamptz, bigint, bigint)
  from public, anon;
grant execute on function
  booking.admin_create_booking(bigint, date, integer, bigint, jsonb, text, boolean, text, timestamptz, timestamptz, numeric, text, jsonb, text, text, text, text, boolean, boolean),
  booking.admin_change_booking(bigint, bigint, date, integer, boolean, boolean, timestamptz, timestamptz),
  booking.admin_create_resource_booking(bigint, timestamptz, integer, bigint, jsonb, timestamptz, bigint, text, boolean, text, numeric, boolean, text, jsonb, bigint, text, text, text, text, text, boolean, boolean),
  booking.admin_create_old_booking(bigint, timestamptz, integer, bigint, jsonb, timestamptz, bigint, text, boolean, text, numeric, boolean, text, jsonb, bigint, text, text, text, text, text, boolean, boolean),
  booking.admin_preview_discount_code(text, bigint, date, integer, jsonb, numeric, bigint),
  booking.admin_check_gift_card(text),
  booking.admin_preview_booking_limits(text, bigint, date, integer, bigint, timestamptz, timestamptz, bigint, bigint)
  to authenticated, service_role;
grant execute on function booking._clear_staff_overrides(), booking._arm_staff_overrides(boolean, boolean, timestamptz, timestamptz),
  booking._staff_overbook(), booking._staff_off_schedule(), booking._apply_admin_discount(bigint, text), booking._apply_admin_gift(bigint, text, text, boolean),
  booking._admin_create_legs(text, bigint, timestamptz, timestamptz, integer, bigint, jsonb, text, boolean, text, numeric, bigint, boolean, text, jsonb, bigint, text, boolean, text, text, text, text, boolean, boolean)
  to service_role;
