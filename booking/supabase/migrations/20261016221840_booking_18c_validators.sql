-- APPLIED 2026-10-17 (Europe/Helsinki ~01:2x): version 20261016221840 (booking_18c_validators) via apply_migration; sama SQL kuin alla (otsikkorivi lisätty tiedostoon ajon jälkeen).
-- ===================================================================================================================
-- booking_18c_validators: Lauran sulku omalle resurssille (hoidot kiinni ei sulje Lauran tuotteita; Laura-sulut tehdään käsin)
-- ===================================================================================================================
set local search_path = booking, extensions, public;

-- sulkuresurssi taidolle: henkilömääräpohjaisella taidolla (laura) oma person-resurssi (code = taito), muuten saunottaja
create or replace function booking._skill_block_resource(p_skill text)
 returns bigint language sql stable security definer set search_path to ''
as $function$
  select coalesce(
    (select r.id from booking.resources r join booking.skills s on s.code = p_skill and not s.shift_based
      where r.code = p_skill and r.kind = 'person' and r.active),
    (select r.id from booking.resources r where r.code = 'saunottaja'))
$function$;
revoke all on function booking._skill_block_resource(text) from public, anon, authenticated;
grant execute on function booking._skill_block_resource(text) to service_role;

-- jo olemassa olevat Lauran therapist-legit siirretään Laura-resurssille (tuotannossa 0 kpl 17.10.2026; validointitrigger ajaa vain aktiivisille)
update booking.reservation_legs l set resource_id = (select id from booking.resources where code = 'laura')
 where l.role = 'therapist' and l.skill = 'laura' and l.resource_id = (select id from booking.resources where code = 'saunottaja');

-- ---------- _therapist_slack (17b + yksi rivi) ----------
create or replace function booking._therapist_slack(p_skill text, p_from timestamptz, p_to timestamptz, p_persons integer default 1,
                                                    p_session_key text default null, p_exclude_leg bigint default null, p_exclude_res bigint default null)
-- JIT pois: pelkkä JIT-käännös söi ~0,5 s per kutsu (kustannusarvio ylitti jit_above_cost); funktio on pieni ja kuumalla polulla
 returns integer language plpgsql stable security definer set search_path to '' set jit to off
as $function$
declare v_shift boolean; v_th bigint; v_slack integer;
begin
  select s.shift_based into v_shift from booking.skills s where s.code = p_skill and s.active;
  if v_shift is null then perform booking._err('skill_unknown', 'Saunottajan taitoa ei tunneta: ' || coalesce(p_skill, '?')); end if;
  v_th := booking._skill_block_resource(p_skill);                    -- booking_18: vuoropohjaiset -> saunottaja; henkilömääräpohjaiset (laura) -> oma resurssi

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

-- ---------- _plan_legs (17c + yksi rivi) ----------
create or replace function booking._plan_legs(p_product_id bigint, p_start timestamptz, p_end timestamptz, p_persons integer,
                                              p_space_id bigint default null, p_override boolean default false, p_res_id bigint default null)
 returns setof booking.leg_plan
 language plpgsql security definer set search_path to ''
as $function$
declare
  pc booking.product_config; r record; v_no integer; v_picked boolean; v_cs timestamptz; v_ce timestamptz; v_pool bigint; v_pools bigint[];
  v_sess text; v_code text; v_msg text; v_e_code text; v_e_msg text; v_th bigint; v_row booking.leg_plan;
begin
  select * into pc from booking.product_config where product_id = p_product_id;
  if not found or pc.resource_class <> 'resourced' then perform booking._err('not_resourced', 'Tuotteella ei ole resurssisääntöjä'); end if;
  if p_persons is null or p_persons < pc.min_persons then perform booking._err('persons_min', format('Vähimmäishenkilömäärä on %s', pc.min_persons)); end if;
  if pc.max_persons is not null and p_persons > pc.max_persons then perform booking._err('persons_max', format('Enimmäishenkilömäärä on %s', pc.max_persons)); end if;
  v_th := booking._skill_block_resource(pc.required_skill);        -- booking_18: Lauran legit omalle resurssille (hoidot kiinni ei sulje Lauraa)
  perform booking._lock_resources((select array_agg(x) from (select psr.space_id as x from booking.product_space_rules psr where psr.product_id = p_product_id and psr.active
                                                             union select v_th) q));
  for v_no in select distinct psr.leg_no from booking.product_space_rules psr where psr.product_id = p_product_id and psr.active order by 1 loop
    v_picked := false; v_code := null; v_msg := null;
    for r in select * from booking.product_space_rules psr where psr.product_id = p_product_id and psr.active and psr.leg_no = v_no order by psr.priority loop
      if p_persons < r.min_persons or (r.max_persons is not null and p_persons > r.max_persons) then
        if v_code is null then v_code := 'persons_limit'; v_msg := format('Henkilömäärä %s ei sovi tilaan (%s–%s)', p_persons, r.min_persons, coalesce(r.max_persons::text, '∞')); end if;
        continue;
      end if;
      if v_no = 1 and p_space_id is not null then
        if r.space_id <> p_space_id then continue; end if;                       -- ylläpito valitsi tilan käsin (myös manual / auto_if_blocked)
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
        if v_code is null then v_code := v_e_code; v_msg := v_e_msg; end if;       -- raportoidaan ensimmäisen (ensisijaisen) vaihtoehdon syy
        continue;
      end;
      v_row := row(v_no, r.role, r.space_id, r.mode, v_pool, r.offset_min, r.minutes, v_cs, v_ce, p_persons, null, v_sess, r.id)::booking.leg_plan;
      return next v_row; v_picked := true; exit;
    end loop;
    if not v_picked then perform booking._err(coalesce(v_code, 'no_space'), coalesce(v_msg, 'Tilaa ei löydy tälle tuotteelle')); end if;
  end loop;

  if pc.required_skill is not null then
    v_cs := p_start + make_interval(mins => pc.therapist_offset_min);
    v_ce := least(p_end, case when pc.therapist_minutes is null then p_end else v_cs + make_interval(mins => pc.therapist_minutes) end);
    v_sess := case when pc.therapist_session_pool_id is not null then 'T:' || pc.therapist_session_pool_id::text || '@' || extract(epoch from v_cs)::bigint::text end;
    perform booking._check_claim(p_res_id, null, v_th, 'therapist', 'shared', v_cs, v_ce, pc.therapists_needed, '{}'::bigint[], pc.required_skill, v_sess, false, p_override);
    v_row := row(0, 'therapist', v_th, 'shared', null, pc.therapist_offset_min, pc.therapist_minutes, v_cs, v_ce, pc.therapists_needed, pc.required_skill, v_sess, null)::booking.leg_plan;
    return next v_row;
  end if;
  return;
end $function$;

-- ---------- admin_day_view (17c + closure_event_id sulkuriveille; additiivinen avain) ----------
create or replace function booking.admin_day_view(p_date date)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
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
    select rs.rule_id, rs.starts_at, rs.ends_at, rs.product_name, ai.addon_id, min(ai.product_name) as name, sum(ai.quantity)::int as qty
      from rs join booking.order_items ai on ai.parent_item_id = rs.order_item_id and ai.kind = 'addon'
     group by rs.rule_id, rs.starts_at, rs.ends_at, rs.product_name, ai.addon_id),
  grp as (
    select rule_id, starts_at, ends_at, product_name,
           jsonb_agg(jsonb_build_object('addon_id', addon_id, 'name', name, 'quantity', qty) order by name) as items
      from per group by rule_id, starts_at, ends_at, product_name)
  select (select coalesce(jsonb_agg(jsonb_build_object('rule_id', g.rule_id, 'starts_at', g.starts_at, 'ends_at', g.ends_at,
                    'product_name', g.product_name, 'items', g.items) order by g.starts_at, g.rule_id), '[]'::jsonb) from grp g),
         (select coalesce(jsonb_agg(jsonb_build_object('addon_id', t.addon_id, 'name', t.name, 'quantity', t.qty) order by t.name), '[]'::jsonb)
            from (select addon_id, min(name) as name, sum(qty)::int as qty from per group by addon_id) t)
    into v_prep, v_totals;
  return jsonb_build_object(
    'date', p_date,
    'sessions', coalesce((select jsonb_agg(to_jsonb(s) order by s.starts_at, s.rule_id)
                           from booking._sessions(p_date, p_date, null, false) s), '[]'::jsonb),
    'reservations', coalesce((select jsonb_agg(jsonb_build_object(
        'reservation_id', r.id, 'order_id', o.id, 'order_no', o.order_no, 'status', r.status, 'payment_status', o.payment_status,
        'product_name', coalesce(it.product_name, p.name), 'mode', r.mode, 'starts_at', r.starts_at, 'ends_at', r.ends_at,
        'persons', r.persons, 'customer_name', c.name, 'customer_phone', c.phone, 'rule_id', r.rule_id, 'notes', r.notes,
        'annual_card', r.annual_card_id is not null, 'hold_expires_at', r.hold_expires_at,
        'source', coalesce(r.external_source, 'native'), 'external_id', r.external_id,
        'customer_kind', o.customer_kind, 'company', case when o.customer_kind <> 'private' then coalesce(o.billing ->> 'company', c.company) end,
        'space_code', sp.code, 'lifecycle', pcf.lifecycle, 'quota_exempt', r.quota_exempt, 'override_reason', r.override_reason,
        'claim_offset_min', r.claim_offset_min, 'claim_minutes', r.claim_minutes, 'parent_reservation_id', r.parent_reservation_id,
        'legs', coalesce((select jsonb_agg(jsonb_build_object('leg_id', l.id, 'role', l.role, 'resource_code', lr.code, 'starts_at', l.starts_at, 'ends_at', l.ends_at,
                                  'persons', l.persons, 'skill', l.skill) order by l.starts_at, l.id)
                            from booking.reservation_legs l join booking.resources lr on lr.id = l.resource_id where l.reservation_id = r.id), '[]'::jsonb),
        'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', ai.addon_id, 'name', ai.product_name, 'quantity', ai.quantity) order by ai.id)
                              from booking.order_items ai where ai.parent_item_id = r.order_item_id and ai.kind = 'addon'), '[]'::jsonb))
        order by r.starts_at, r.id)
        from booking.reservations r join booking.orders o on o.id = r.order_id join booking.resources sp on sp.id = r.space_id
        left join booking.order_items it on it.id = r.order_item_id left join kb.products p on p.id = r.product_id
        left join booking.product_config pcf on pcf.product_id = r.product_id
        left join booking.customers c on c.id = o.customer_id
        where r.starts_at < v_to and r.ends_at > v_from and booking._res_active(r.status, r.hold_expires_at)), '[]'::jsonb),
    'prep', v_prep, 'addon_totals', v_totals,
    'blocks', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'space_id', b.space_id, 'resource_code', br.code, 'closure_event_id', b.closure_event_id, 'starts_at', b.starts_at,
        'ends_at', b.ends_at, 'reason', b.reason) order by b.starts_at)
        from booking.space_blocks b join booking.resources br on br.id = b.space_id where b.active and b.starts_at < v_to and b.ends_at > v_from), '[]'::jsonb));
end $function$;
