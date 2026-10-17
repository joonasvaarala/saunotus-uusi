-- =====================================================================
-- booking_22_therapist_missing (17.10.2026): varaus saa syntyä ILMAN saunottajaa, mutta siitä tulee ilmoitus ja muistutus kunnes poikkeus myönnetään.
-- Joonaksen päätös 17.10.: natiivivaraus saa olla ilman saunottajalegiä (therapist-legi puuttuu), merkintä therapist_missing, näkyy admin_review_list():ssä
-- (avain missing_therapist) ja poikkeus myönnetään admin_grant_therapist_exception(reservation_id, note):lla. Sama tila tuoduille (Johku) varauksille.
--
--  1) reservations: therapist_missing (bool), therapist_exception_by/_at/_note. Rajoite: poikkeus vain merkitylle. Osittainen indeksi avoimille.
--  2) _plan_legs: uusi 8. parametri p_skip_therapist (oletus false) = suunnitelma ilman saunottajalegiä. Muu logiikka ennallaan.
--  3) _create_legs_booking (admin/natiivi): jos VAIN saunottajatarkistus epäonnistuu (no_therapist) -> varaus + kaikki muut legit, therapist_missing = true,
--     paluujsoniin 'therapist_missing': true ja 'warning': 'therapist_missing' (ilmoitus ylläpidolle heti). Muut virheet (space_busy, capacity_exceeded, therapist_closed ...) nousevat ennallaan.
--     p_override=true ohittaa edelleen saunottajatarkistuksen (legi luodaan, override_reason) – eri asia kuin puuttuva saunottaja.
--  4) import_attach_legs: no_therapist ei enää peruuta kaikkia legejä: muut legit liitetään, merkintä therapist_missing, paluu {ok:true, legs:n, therapist_missing:true}.
--  5) admin_review_list: uusi avain missing_therapist (avoimet: merkitty, ei poikkeusta, ei saunottajalegiä, tuleva/aktiivinen).
--  6) admin_day_view: kentät therapist_missing, therapist_missing_open, therapist_exception_at, therapist_exception_note.
--  7) admin_grant_therapist_exception(reservation_id, note): oikeus bookings.override (admin/manager); virhekoodit forbidden, note_required, not_found, not_missing, therapist_present.
--  8) therapist_missing_digest(p_days): vain luku, vain service_role; yhteenveto muistutusta varten (EI ajastusta, EI lähetystä).
-- Ei muuta olemassa olevaa rivitietoa. Rollback: booking_22_ROLLBACK.sql.
-- =====================================================================
set local search_path = booking, extensions, public;

-- ---------- 1) skeema ----------
alter table booking.reservations
  add column if not exists therapist_missing boolean not null default false,
  add column if not exists therapist_exception_by uuid,
  add column if not exists therapist_exception_at timestamptz,
  add column if not exists therapist_exception_note text;
alter table booking.reservations drop constraint if exists reservations_therapist_exception_ok;
alter table booking.reservations add constraint reservations_therapist_exception_ok check (therapist_exception_at is null or therapist_missing);
create index if not exists reservations_therapist_missing_idx on booking.reservations (starts_at) where therapist_missing and therapist_exception_at is null;

-- ---------- 2) _plan_legs: uusi 8. parametri (vanha 7-parametrinen poistetaan; kutsut 7 parametrilla toimivat oletusarvolla) ----------
drop function if exists booking._plan_legs(bigint, timestamptz, timestamptz, integer, bigint, boolean, bigint);
CREATE OR REPLACE FUNCTION booking._plan_legs(p_product_id bigint, p_start timestamp with time zone, p_end timestamp with time zone, p_persons integer, p_space_id bigint DEFAULT NULL::bigint, p_override boolean DEFAULT false, p_res_id bigint DEFAULT NULL::bigint, p_skip_therapist boolean DEFAULT false)
 RETURNS SETOF booking.leg_plan
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  if pc.required_skill is not null and not p_skip_therapist then          -- booking_22: p_skip_therapist = suunnitelma ilman saunottajalegiä (therapist_missing)
    v_cs := p_start + make_interval(mins => pc.therapist_offset_min);
    v_ce := least(p_end, case when pc.therapist_minutes is null then p_end else v_cs + make_interval(mins => pc.therapist_minutes) end);
    v_sess := case when pc.therapist_session_pool_id is not null then 'T:' || pc.therapist_session_pool_id::text || '@' || extract(epoch from v_cs)::bigint::text end;
    perform booking._check_claim(p_res_id, null, v_th, 'therapist', 'shared', v_cs, v_ce, pc.therapists_needed, '{}'::bigint[], pc.required_skill, v_sess, false, p_override);
    v_row := row(0, 'therapist', v_th, 'shared', null, pc.therapist_offset_min, pc.therapist_minutes, v_cs, v_ce, pc.therapists_needed, pc.required_skill, v_sess, null)::booking.leg_plan;
    return next v_row;
  end if;
  return;
end $function$;
revoke all on function booking._plan_legs(bigint, timestamptz, timestamptz, integer, bigint, boolean, bigint, boolean) from public, anon, authenticated;
grant execute on function booking._plan_legs(bigint, timestamptz, timestamptz, integer, bigint, boolean, bigint, boolean) to service_role;

-- ---------- 3) natiivipolku: _create_legs_booking ----------
CREATE OR REPLACE FUNCTION booking._create_legs_booking(p_lifecycle text, p_product_id bigint, p_start timestamp with time zone, p_end timestamp with time zone, p_persons integer, p_customer_id bigint, p_channel text, p_created_by uuid, p_note text, p_price numeric, p_space_id bigint, p_override boolean, p_override_reason text, p_quota_exempt boolean, p_parent_reservation_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  p kb.products; pc booking.product_config; v_end timestamptz; v_total numeric; v_order booking.orders; v_item bigint; v_res booking.reservations;
  v_plan booking.leg_plan[] := '{}'; lp booking.leg_plan; v_prim booking.leg_plan; v_parent bigint; v_pools bigint[]; v_off integer; v_cmin integer; v_n integer := 0; v_missing boolean := false; v_ecode text;
begin
  select * into p from kb.products where id = p_product_id;
  if not found then perform booking._err('product_not_found', 'Tuotetta ei löydy'); end if;
  select * into pc from booking.product_config where product_id = p_product_id;
  if not found then perform booking._err('not_bookable', 'Tuotetta ei voi varata'); end if;
  if p_lifecycle is not null and pc.lifecycle <> p_lifecycle then
    perform booking._err('wrong_lifecycle', case p_lifecycle when 'old' then 'Valitse vanha tuote (current-tuotteet: Uusi varaus)' else 'Valitse nykyinen tuote' end);
  end if;
  if p.vat_rate is null then perform booking._err('vat_missing', 'Tuotteelta puuttuu ALV-kanta'); end if;
  v_end := coalesce(p_end, p_start + make_interval(mins => coalesce(pc.duration_minutes, p.duration_minutes)));
  if p_start is null or v_end is null or v_end <= p_start then perform booking._err('bad_time', 'Virheellinen aika'); end if;
  if p_override and (p_override_reason is null or length(btrim(p_override_reason)) < 3) then perform booking._err('override_reason_required', 'Ylitys vaatii perustelun'); end if;

  -- lisäpalvelu (kb 27/28): vaatii kattavan vanhempivarauksen (jälkilöyly / oma vuoro)
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
    -- booking_22: ei vapaata saunottajaa -> varaus syntyy ilman saunottajalegiä (therapist_missing), kaikki muut virheet nousevat ennallaan
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
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_note, created_by, confirmed_at)
  values (p_customer_id, 'confirmed', 'unpaid', v_total, p_channel, 'fi', p_note, p_created_by, now()) returning * into v_order;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
  values (v_order.id, p.id, p.name, 'reservation', 1, v_total, v_total, p.vat_rate,
          jsonb_build_object('model', 'legs_v2', 'lifecycle', pc.lifecycle, 'persons', p_persons)) returning id into v_item;

  insert into booking.reservations(order_id, order_item_id, product_id, space_id, mode, starts_at, ends_at, persons, pool_ids, status,
                                   quota_exempt, claim_offset_min, claim_minutes, parent_reservation_id, override_reason, created_by, therapist_missing)
  values (v_order.id, v_item, p.id, v_prim.resource_id, v_prim.mode, p_start, v_end, p_persons, v_pools, 'confirmed',
          p_quota_exempt, v_off, v_cmin, v_parent, case when p_override then btrim(p_override_reason) end, p_created_by, v_missing)
  returning * into v_res;                                    -- trigger validoi ensisijaisen claimin

  for lp in select * from unnest(v_plan) u where not (u.leg_no = 1 and u.role = 'space') order by u.leg_no loop
    insert into booking.reservation_legs(reservation_id, resource_id, role, mode, starts_at, ends_at, offset_min, minutes, persons, pool_ids, skill, session_key,
                                         quota_exempt, override_reason, rule_id)
    values (v_res.id, lp.resource_id, lp.role, lp.mode, lp.claim_start, lp.claim_end, lp.offset_min, lp.minutes, lp.persons,
            case when lp.pool_id is null then '{}'::bigint[] else array[lp.pool_id] end, lp.skill, lp.session_key,
            p_quota_exempt, case when p_override then btrim(p_override_reason) end, lp.rule_id);   -- trigger validoi legin
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('order_id', v_order.id, 'order_no', v_order.order_no, 'reservation_id', v_res.id, 'total', v_total,
                            'starts_at', v_res.starts_at, 'ends_at', v_res.ends_at, 'legs', v_n, 'space_id', v_res.space_id,
                            'product_name', p.name, 'parent_reservation_id', v_parent,
                            'therapist_missing', v_missing, 'warning', case when v_missing then 'therapist_missing' end);
end $function$;

-- ---------- 4) tuontipolku: import_attach_legs ----------
CREATE OR REPLACE FUNCTION booking.import_attach_legs(p_reservation_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare res booking.reservations; pc booking.product_config; lp booking.leg_plan; v_prim booking.leg_plan; v_plan booking.leg_plan[] := '{}'; v_n integer := 0;
        v_code text; v_msg text; v_off integer; v_cmin integer; v_missing boolean := false; v_ecode text;
begin
  select * into res from booking.reservations where id = p_reservation_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select * into pc from booking.product_config where product_id = res.product_id;
  if not found or pc.resource_class <> 'resourced' or not booking._res_active(res.status, res.hold_expires_at) then
    return jsonb_build_object('ok', true, 'legs', 0, 'note', 'nothing_to_do');
  end if;
  begin
    begin
      for lp in select * from booking._plan_legs(res.product_id, res.starts_at, res.ends_at, res.persons, res.space_id, false, res.id) loop v_plan := array_append(v_plan, lp); end loop;
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_ecode = pg_exception_detail;                       -- booking_22: ei saunottajaa -> muut legit liitetään, varaus merkitään therapist_missing
      if v_ecode is distinct from 'no_therapist' then raise; end if;
      v_plan := '{}'; v_missing := true;
      for lp in select * from booking._plan_legs(res.product_id, res.starts_at, res.ends_at, res.persons, res.space_id, false, res.id, true) loop v_plan := array_append(v_plan, lp); end loop;
    end;
    select * into v_prim from unnest(v_plan) u where u.leg_no = 1 and u.role = 'space';
    v_off := (extract(epoch from (v_prim.claim_start - res.starts_at)) / 60)::int;
    v_cmin := case when v_prim.claim_end >= res.ends_at then null else (extract(epoch from (v_prim.claim_end - v_prim.claim_start)) / 60)::int end;
    if res.mode = 'shared' and (res.claim_offset_min <> v_off or res.claim_minutes is distinct from v_cmin) then
      update booking.reservations set claim_offset_min = v_off, claim_minutes = v_cmin where id = res.id;
    end if;
    for lp in select * from unnest(v_plan) u where not (u.leg_no = 1 and u.role = 'space') order by u.leg_no loop
      insert into booking.reservation_legs(reservation_id, resource_id, role, mode, starts_at, ends_at, offset_min, minutes, persons, pool_ids, skill, session_key, quota_exempt, rule_id)
      values (res.id, lp.resource_id, lp.role, lp.mode, lp.claim_start, lp.claim_end, lp.offset_min, lp.minutes, lp.persons,
              case when lp.pool_id is null then '{}'::bigint[] else array[lp.pool_id] end, lp.skill, lp.session_key, res.quota_exempt, lp.rule_id)
      on conflict (reservation_id, role, resource_id, offset_min) do update
        set starts_at = excluded.starts_at, ends_at = excluded.ends_at, minutes = excluded.minutes, persons = excluded.persons,
            pool_ids = excluded.pool_ids, skill = excluded.skill, session_key = excluded.session_key, rule_id = excluded.rule_id;
      v_n := v_n + 1;
    end loop;
    if v_missing then
      if not exists (select 1 from booking.reservation_legs l where l.reservation_id = res.id and l.role = 'therapist') then
        update booking.reservations set therapist_missing = true where id = res.id and not therapist_missing;
      else v_missing := false; end if;                                                -- vanha saunottajalegi on jo olemassa: ei merkintää
    elsif exists (select 1 from unnest(v_plan) u where u.role = 'therapist') then
      update booking.reservations set therapist_missing = false where id = res.id and therapist_missing and therapist_exception_at is null;
    end if;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_msg = message_text, v_code = pg_exception_detail;
    return jsonb_build_object('ok', false, 'code', v_code, 'message', v_msg);       -- sisäinen alilohko peruuntui: ei osittaisia legejä
  end;
  return jsonb_build_object('ok', true, 'legs', v_n, 'therapist_missing', v_missing);
end $function$;

-- ---------- 5) admin_review_list (uusi avain missing_therapist) ----------
CREATE OR REPLACE FUNCTION booking.admin_review_list()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform booking._require_staff();
  return jsonb_build_object(
    'therapist_conflicts', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', c.reservation_id, 'leg_id', c.leg_id, 'starts_at', c.claim_start, 'ends_at', c.claim_end, 'skill', c.skill) order by c.claim_start)
        from booking.v_claims c where c.role = 'therapist' and not c.is_override and booking._res_active(c.status, c.hold_expires_at) and c.claim_end > now()
         and booking._therapist_slack(c.skill, c.claim_start, c.claim_end, c.persons, c.session_key, c.leg_id, c.reservation_id) < 0), '[]'::jsonb),
    'block_conflicts', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', c.reservation_id, 'leg_id', c.leg_id, 'resource_id', c.resource_id, 'block_id', b.id, 'starts_at', c.claim_start) order by c.claim_start)
        from booking.v_claims c join booking.space_blocks b on b.active and b.space_id = c.resource_id and b.during && tstzrange(c.claim_start, c.claim_end, '[)')
       where not c.is_override and booking._res_active(c.status, c.hold_expires_at) and c.claim_end > now()), '[]'::jsonb),
    'overrides', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', r.id, 'reason', r.override_reason, 'starts_at', r.starts_at) order by r.starts_at)
        from booking.reservations r where r.override_reason is not null and r.ends_at > now() and booking._res_active(r.status, r.hold_expires_at)), '[]'::jsonb),
    'orphan_addons', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', r.id, 'starts_at', r.starts_at) order by r.starts_at)
        from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and cardinality(pc.requires_parent_product_ids) > 0
        left join booking.reservations pr on pr.id = r.parent_reservation_id
       where r.ends_at > now() and booking._res_active(r.status, r.hold_expires_at) and r.override_reason is null
         and (pr.id is null or not booking._res_active(pr.status, pr.hold_expires_at))), '[]'::jsonb),
    'missing_therapist', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', r.id, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'product_id', r.product_id,
              'product_name', coalesce(p.name, ''), 'persons', r.persons, 'order_no', o.order_no, 'source', coalesce(r.external_source, 'native'),
              'days_to_start', ((r.starts_at at time zone 'Europe/Helsinki')::date - (now() at time zone 'Europe/Helsinki')::date)) order by r.starts_at)
        from booking.reservations r join booking.orders o on o.id = r.order_id left join kb.products p on p.id = r.product_id
       where r.therapist_missing and r.therapist_exception_at is null and r.ends_at > now() and booking._res_active(r.status, r.hold_expires_at)
         and not exists (select 1 from booking.reservation_legs l where l.reservation_id = r.id and l.role = 'therapist')), '[]'::jsonb));
end $function$;

-- ---------- 6) admin_day_view (uudet kentät) ----------
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
        'therapist_missing', r.therapist_missing, 'therapist_exception_at', r.therapist_exception_at, 'therapist_exception_note', r.therapist_exception_note,
        'therapist_missing_open', (r.therapist_missing and r.therapist_exception_at is null and not exists (select 1 from booking.reservation_legs tl where tl.reservation_id = r.id and tl.role = 'therapist')),
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

-- ---------- 7) poikkeuksen myöntäminen ----------
create or replace function booking.admin_grant_therapist_exception(p_reservation_id bigint, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r booking.reservations; v_note text := btrim(coalesce(p_note, ''));
begin
  perform booking._require_permission('bookings.override');
  if char_length(v_note) < 3 then perform booking._err('note_required', 'Poikkeus vaatii perustelun (vähintään 3 merkkiä)'); end if;
  select * into r from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  if not r.therapist_missing then perform booking._err('not_missing', 'Varauksella ei ole puuttuvaa saunottajaa'); end if;
  if exists (select 1 from booking.reservation_legs l where l.reservation_id = r.id and l.role = 'therapist') then
    perform booking._err('therapist_present', 'Varauksella on jo saunottajalegi – poikkeusta ei tarvita');
  end if;
  if r.therapist_exception_at is not null then
    return jsonb_build_object('ok', true, 'reservation_id', r.id, 'already', true, 'granted_at', r.therapist_exception_at);
  end if;
  update booking.reservations set therapist_exception_by = auth.uid(), therapist_exception_at = now(), therapist_exception_note = left(v_note, 300) where id = r.id;
  return jsonb_build_object('ok', true, 'reservation_id', r.id, 'already', false);
end $$;
revoke all on function booking.admin_grant_therapist_exception(bigint, text) from public, anon;
grant execute on function booking.admin_grant_therapist_exception(bigint, text) to authenticated, service_role;

-- ---------- 8) muistutuksen pohja (vain luku; ei ajastusta eikä lähetystä) ----------
create or replace function booking.therapist_missing_digest(p_days integer default 14)
returns jsonb language sql stable security definer set search_path = '' as $$
  with o as (
    select r.id, r.starts_at, r.persons, o.order_no, coalesce(p.name, '') as product_name,
           ((r.starts_at at time zone 'Europe/Helsinki')::date - (now() at time zone 'Europe/Helsinki')::date) as days_to_start
      from booking.reservations r join booking.orders o on o.id = r.order_id left join kb.products p on p.id = r.product_id
     where r.therapist_missing and r.therapist_exception_at is null and r.ends_at > now() and booking._res_active(r.status, r.hold_expires_at)
       and not exists (select 1 from booking.reservation_legs l where l.reservation_id = r.id and l.role = 'therapist'))
  select jsonb_build_object('generated_at', now(), 'open_total', (select count(*) from o),
         'within_days', (select count(*) from o where days_to_start <= greatest(p_days, 0)),
         'next_7_days', (select count(*) from o where days_to_start <= 7),
         'items', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', id, 'order_no', order_no, 'starts_at', starts_at, 'persons', persons,
                            'product_name', product_name, 'days_to_start', days_to_start) order by starts_at) from o where days_to_start <= greatest(p_days, 0)), '[]'::jsonb)) $$;
revoke all on function booking.therapist_missing_digest(integer) from public, anon, authenticated;
grant execute on function booking.therapist_missing_digest(integer) to service_role;      -- ajastus/Edge myöhemmin; henkilökunta näkee saman admin_review_list():stä
