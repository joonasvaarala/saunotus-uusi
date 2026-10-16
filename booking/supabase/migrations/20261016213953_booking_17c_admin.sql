-- DRAFT (EI AJETTU) 17.10.2026 – booking_17c_admin: legien suunnittelu ja luonti, "Vanha varaus", Rauni->Lovi-siirto, Tarkista-lista, tuonnin leg-backfill, hallintanäkymät
-- Edellyttää 17a + 17b. Julkiset rajapinnat (public_*) EIVÄT muutu (hoitokauppa = booking_19).
set local search_path = booking, extensions, public;

do $$ begin
  if not exists (select 1 from pg_type where typname = 'leg_plan' and typnamespace = 'booking'::regnamespace) then
    create type booking.leg_plan as (leg_no integer, role text, resource_id bigint, mode text, pool_id bigint, offset_min integer, minutes integer,
                                      claim_start timestamptz, claim_end timestamptz, persons integer, skill text, session_key text, rule_id bigint);
  end if;
end $$;

-- ---------- _plan_legs: tuote -> legit (product_space_rules + product_config) ----------
-- Käy jokaisen leg_no:n säännöt prioriteettijärjestyksessä ja valitsee ensimmäisen jonka _check_claim läpäisee:
--   auto = tarjolla aina; auto_if_blocked (Lovi) = vain jos requires_blocked_space (Rauni) on suljettu claim-ikkunassa; manual = vain jos p_space_id osoittaa siihen (leg 1).
-- Ottaa tilalukot ensin nousevassa id-järjestyksessä. Palauttaa myös saunottajalegin (leg_no 0, role 'therapist') jos tuote vaatii taidon.
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
  select id into v_th from booking.resources where code = 'saunottaja';
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

-- ---------- _create_legs_booking: tilaus + rivi + varaus + legit yhdessä transaktiossa ----------
create or replace function booking._create_legs_booking(p_lifecycle text, p_product_id bigint, p_start timestamptz, p_end timestamptz, p_persons integer,
    p_customer_id bigint, p_channel text, p_created_by uuid, p_note text, p_price numeric, p_space_id bigint, p_override boolean, p_override_reason text,
    p_quota_exempt boolean, p_parent_reservation_id bigint)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  p kb.products; pc booking.product_config; v_end timestamptz; v_total numeric; v_order booking.orders; v_item bigint; v_res booking.reservations;
  v_plan booking.leg_plan[] := '{}'; lp booking.leg_plan; v_prim booking.leg_plan; v_parent bigint; v_pools bigint[]; v_off integer; v_cmin integer; v_n integer := 0;
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

  for lp in select * from booking._plan_legs(p_product_id, p_start, v_end, p_persons, p_space_id, p_override) loop v_plan := array_append(v_plan, lp); end loop;
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
                                   quota_exempt, claim_offset_min, claim_minutes, parent_reservation_id, override_reason, created_by)
  values (v_order.id, v_item, p.id, v_prim.resource_id, v_prim.mode, p_start, v_end, p_persons, v_pools, 'confirmed',
          p_quota_exempt, v_off, v_cmin, v_parent, case when p_override then btrim(p_override_reason) end, p_created_by)
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
                            'product_name', p.name, 'parent_reservation_id', v_parent);
end $function$;

-- ---------- admin-kääre: asiakas, maksutapa, lisäpalvelut (kuten admin_create_booking) ----------
create or replace function booking._admin_create_legs(p_lifecycle text, p_product_id bigint, p_start timestamptz, p_end timestamptz, p_persons integer,
    p_customer_id bigint, p_customer jsonb, p_payment_method text, p_paid boolean, p_note text, p_price numeric, p_space_id bigint,
    p_override boolean, p_override_reason text, p_addons jsonb, p_parent_reservation_id bigint, p_invoice_reference text, p_quota_exempt boolean)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare v_cust bigint := p_customer_id; v_pm booking.payment_methods; v_res jsonb; v_order bigint; v_add numeric; v_total numeric;
        v_ref text := nullif(btrim(coalesce(p_invoice_reference, '')), '');
begin
  perform booking._require_permission('bookings.manage');
  if p_override then perform booking._require_permission('bookings.override'); end if;
  select * into v_pm from booking.payment_methods where code = p_payment_method and active;
  if not found then perform booking._err('invalid_payment_method', 'Maksutapa ei ole käytössä'); end if;
  if p_price is not null and p_price < 0 then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
  if v_ref is not null and char_length(v_ref) > 100 then perform booking._err('invalid_reference', 'Viite on liian pitkä (enintään 100 merkkiä)'); end if;
  if v_cust is null then
    if p_customer is null then perform booking._err('customer_required', 'Valitse asiakas tai anna nimi'); end if;
    v_cust := (booking.admin_create_customer(p_customer) ->> 'id')::bigint;           -- sama polku kuin hallinnan asiakaslomake
  elsif not exists (select 1 from booking.customers where id = v_cust) then
    perform booking._err('customer_not_found', 'Asiakasta ei löydy');
  end if;
  v_res := booking._create_legs_booking(p_lifecycle, p_product_id, p_start, p_end, p_persons, v_cust, 'admin', auth.uid(), p_note, p_price, p_space_id,
                                        p_override, p_override_reason, p_quota_exempt, p_parent_reservation_id);
  v_order := (v_res ->> 'order_id')::bigint;
  perform booking._stamp_order_billing(v_order, v_cust, null);
  if v_ref is not null then update booking.orders set invoice_reference = v_ref where id = v_order and customer_kind <> 'private'; end if;
  v_add := booking._attach_addons((v_res ->> 'reservation_id')::bigint, p_addons);
  v_total := (v_res ->> 'total')::numeric + v_add;
  insert into booking.payments(order_id, method, provider, status, amount, paid_at, created_by)
  values (v_order, p_payment_method, 'manual', case when p_paid then 'paid' else 'pending' end, v_total, case when p_paid then now() end, auth.uid());
  update booking.orders set payment_status = case when p_paid then 'paid' else 'unpaid' end where id = v_order;     -- total_gross päivittyy _attach_addons:ssa kuten admin_create_booking:ssa
  return v_res || jsonb_build_object('customer_id', v_cust, 'total', v_total, 'addons_total', v_add);
end $function$;

-- "Vanha varaus" (DESIGN B2): vain lifecycle='old' -tuotteet; resurssivaikutus säilyy (sulut/poissulku/pooli/saunottaja), p_override vaatii oikeuden bookings.override
create or replace function booking.admin_create_old_booking(p_product_id bigint, p_start timestamptz, p_persons integer, p_customer_id bigint default null,
    p_customer jsonb default null, p_end timestamptz default null, p_space_id bigint default null, p_payment_method text default 'pay_later',
    p_paid boolean default false, p_note text default null, p_price numeric default null, p_override boolean default false, p_override_reason text default null,
    p_addons jsonb default null, p_parent_reservation_id bigint default null, p_invoice_reference text default null)
 returns jsonb language sql security definer set search_path to ''
as $$ select booking._admin_create_legs('old', p_product_id, p_start, p_end, p_persons, p_customer_id, p_customer, p_payment_method, p_paid, p_note, p_price,
                                         p_space_id, p_override, p_override_reason, p_addons, p_parent_reservation_id, p_invoice_reference, false) $$;

-- Nykyinen resurssituote (hoito, saunotus, rituaali, seremonia, lisäpalvelu) ylläpidon kautta ennen julkista hoitokauppaa (booking_19)
create or replace function booking.admin_create_resource_booking(p_product_id bigint, p_start timestamptz, p_persons integer, p_customer_id bigint default null,
    p_customer jsonb default null, p_end timestamptz default null, p_space_id bigint default null, p_payment_method text default 'pay_later',
    p_paid boolean default false, p_note text default null, p_price numeric default null, p_override boolean default false, p_override_reason text default null,
    p_addons jsonb default null, p_parent_reservation_id bigint default null, p_invoice_reference text default null)
 returns jsonb language sql security definer set search_path to ''
as $$ select booking._admin_create_legs('current', p_product_id, p_start, p_end, p_persons, p_customer_id, p_customer, p_payment_method, p_paid, p_note, p_price,
                                         p_space_id, p_override, p_override_reason, p_addons, p_parent_reservation_id, p_invoice_reference, false) $$;

-- ---------- käsin-siirto Rauni <-> Lovi (vain ensisijainen tila; vain jos tuotteella on sääntö kohdetilaan; Lovi vain 1 hlö) ----------
create or replace function booking.admin_move_reservation_space(p_reservation_id bigint, p_space_code text, p_reason text default null)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare res booking.reservations; tgt booking.resources; rule booking.product_space_rules;
begin
  perform booking._require_permission('bookings.manage');
  select * into res from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  if res.status <> 'confirmed' then perform booking._err('not_changeable', 'Vain vahvistetun varauksen tilaa voi vaihtaa'); end if;
  select * into tgt from booking.resources where code = p_space_code and kind = 'space' and active;
  if not found then perform booking._err('space_not_found', 'Tilaa ei löydy'); end if;
  select * into rule from booking.product_space_rules psr
   where psr.product_id = res.product_id and psr.leg_no = 1 and psr.space_id = tgt.id and psr.active and res.persons between psr.min_persons and coalesce(psr.max_persons, res.persons) limit 1;
  if not found then perform booking._err('space_not_allowed', 'Tuote/henkilömäärä ei sovi valittuun tilaan'); end if;
  perform booking._lock_resources(array[res.space_id, tgt.id]);
  update booking.reservations set space_id = tgt.id,
         notes = left(coalesce(notes || E'\n', '') || 'Siirretty tilaan ' || tgt.code || coalesce(': ' || nullif(btrim(p_reason), ''), ''), 1000)
   where id = res.id;                                    -- trigger validoi kohteen (sulku, päällekkäisyys, puskuri)
  return jsonb_build_object('ok', true, 'reservation_id', res.id, 'space', tgt.code);
end $function$;

-- ---------- "Tarkista"-lista (vain luku): saunottajakonfliktit, sulkukonfliktit, ylitykset, orvot lisäpalvelut ----------
create or replace function booking.admin_review_list()
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
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
         and (pr.id is null or not booking._res_active(pr.status, pr.hold_expires_at))), '[]'::jsonb));
end $function$;

-- ---------- tuonnin leg-backfill (service_role): tuodulle TULEVALLE varaukselle legit + claim-ikkuna; virhe = ei kirjoitusta, palauttaa koodin ----------
create or replace function booking.import_attach_legs(p_reservation_id bigint)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare res booking.reservations; pc booking.product_config; lp booking.leg_plan; v_prim booking.leg_plan; v_plan booking.leg_plan[] := '{}'; v_n integer := 0;
        v_code text; v_msg text; v_off integer; v_cmin integer;
begin
  select * into res from booking.reservations where id = p_reservation_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select * into pc from booking.product_config where product_id = res.product_id;
  if not found or pc.resource_class <> 'resourced' or not booking._res_active(res.status, res.hold_expires_at) then
    return jsonb_build_object('ok', true, 'legs', 0, 'note', 'nothing_to_do');
  end if;
  begin
    for lp in select * from booking._plan_legs(res.product_id, res.starts_at, res.ends_at, res.persons, res.space_id, false, res.id) loop v_plan := array_append(v_plan, lp); end loop;
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
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_msg = message_text, v_code = pg_exception_detail;
    return jsonb_build_object('ok', false, 'code', v_code, 'message', v_msg);       -- sisäinen alilohko peruuntui: ei osittaisia legejä
  end;
  return jsonb_build_object('ok', true, 'legs', v_n);
end $function$;

-- ---------- hallintanäkymät: legit, lifecycle, claim, lisäpalvelun vanhempi (ei nimiä saunottajista) ----------
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
    'blocks', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'space_id', b.space_id, 'resource_code', br.code, 'starts_at', b.starts_at,
        'ends_at', b.ends_at, 'reason', b.reason) order by b.starts_at)
        from booking.space_blocks b join booking.resources br on br.id = b.space_id where b.active and b.starts_at < v_to and b.ends_at > v_from), '[]'::jsonb));
end $function$;

drop function if exists booking.admin_list_reservations(timestamptz, timestamptz, text, text, bigint, integer, integer, text);
create function booking.admin_list_reservations(p_from timestamptz default null, p_to timestamptz default null, p_search text default null, p_status text default null,
    p_product_id bigint default null, p_limit integer default 50, p_offset integer default 0, p_source text default null)
 returns table(reservation_id bigint, order_id bigint, order_no bigint, status text, order_status text, payment_status text, product_id bigint, product_name text, mode text,
               starts_at timestamptz, ends_at timestamptz, persons integer, total_gross numeric, customer_id bigint, customer_name text, customer_email text, customer_phone text,
               source_channel text, created_at timestamptz, hold_expires_at timestamptz, notes text, annual_card_id bigint, total_count bigint, source text, external_id text,
               lifecycle text, space_code text, legs jsonb, parent_reservation_id bigint)
 language plpgsql stable security definer set search_path to ''
as $function$
declare q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform booking._require_staff();
  return query
    select r.id, o.id, o.order_no,
           case when r.status = 'pending' and r.hold_expires_at <= now() then 'expired' else r.status end,
           o.status, o.payment_status, r.product_id, coalesce(it.product_name, p.name), r.mode, r.starts_at, r.ends_at, r.persons,
           o.total_gross, c.id, c.name, c.email, c.phone, o.source_channel, o.created_at, r.hold_expires_at, r.notes, r.annual_card_id,
           count(*) over (), coalesce(r.external_source, 'native'), r.external_id,
           pcf.lifecycle, sp.code,
           coalesce((select jsonb_agg(jsonb_build_object('role', l.role, 'resource_code', lr.code, 'starts_at', l.starts_at, 'ends_at', l.ends_at, 'persons', l.persons, 'skill', l.skill)
                                      order by l.starts_at, l.id)
                       from booking.reservation_legs l join booking.resources lr on lr.id = l.resource_id where l.reservation_id = r.id), '[]'::jsonb),
           r.parent_reservation_id
      from booking.reservations r
      join booking.orders o on o.id = r.order_id
      join booking.resources sp on sp.id = r.space_id
      left join booking.order_items it on it.id = r.order_item_id
      left join kb.products p on p.id = r.product_id
      left join booking.product_config pcf on pcf.product_id = r.product_id
      left join booking.customers c on c.id = o.customer_id
     where (p_from is null or r.starts_at >= p_from) and (p_to is null or r.starts_at < p_to)
       and (p_product_id is null or r.product_id = p_product_id)
       and (p_source is null or coalesce(r.external_source, 'native') = p_source)
       and (p_status is null
            or (p_status = 'active' and booking._res_active(r.status, r.hold_expires_at))
            or (p_status = 'expired' and r.status = 'pending' and r.hold_expires_at <= now()) or r.status = p_status)
       and (q is null or c.name ilike '%' || q || '%' or c.email ilike '%' || q || '%' or c.phone ilike '%' || q || '%'
            or o.order_no::text = q or c.company ilike '%' || q || '%')
     order by r.starts_at desc, r.id desc
     limit least(greatest(p_limit, 1), 500) offset greatest(p_offset, 0);
end $function$;

-- ---------- oikeudet (uudet funktiot: oletuksena ei kenellekään; vain tarkoitetut roolit) ----------
revoke all on function booking._plan_legs(bigint, timestamptz, timestamptz, integer, bigint, boolean, bigint) from public, anon, authenticated;
revoke all on function booking._create_legs_booking(text, bigint, timestamptz, timestamptz, integer, bigint, text, uuid, text, numeric, bigint, boolean, text, boolean, bigint) from public, anon, authenticated;
revoke all on function booking._admin_create_legs(text, bigint, timestamptz, timestamptz, integer, bigint, jsonb, text, boolean, text, numeric, bigint, boolean, text, jsonb, bigint, text, boolean) from public, anon, authenticated;
revoke all on function booking.admin_create_old_booking(bigint, timestamptz, integer, bigint, jsonb, timestamptz, bigint, text, boolean, text, numeric, boolean, text, jsonb, bigint, text) from public, anon;
revoke all on function booking.admin_create_resource_booking(bigint, timestamptz, integer, bigint, jsonb, timestamptz, bigint, text, boolean, text, numeric, boolean, text, jsonb, bigint, text) from public, anon;
revoke all on function booking.admin_move_reservation_space(bigint, text, text) from public, anon;
revoke all on function booking.admin_review_list() from public, anon;
revoke all on function booking.import_attach_legs(bigint) from public, anon, authenticated;
revoke all on function booking.admin_list_reservations(timestamptz, timestamptz, text, text, bigint, integer, integer, text) from public, anon;
grant execute on function booking._plan_legs(bigint, timestamptz, timestamptz, integer, bigint, boolean, bigint) to service_role;
grant execute on function booking._create_legs_booking(text, bigint, timestamptz, timestamptz, integer, bigint, text, uuid, text, numeric, bigint, boolean, text, boolean, bigint) to service_role;
grant execute on function booking._admin_create_legs(text, bigint, timestamptz, timestamptz, integer, bigint, jsonb, text, boolean, text, numeric, bigint, boolean, text, jsonb, bigint, text, boolean) to service_role;
grant execute on function booking.admin_create_old_booking(bigint, timestamptz, integer, bigint, jsonb, timestamptz, bigint, text, boolean, text, numeric, boolean, text, jsonb, bigint, text) to authenticated, service_role;
grant execute on function booking.admin_create_resource_booking(bigint, timestamptz, integer, bigint, jsonb, timestamptz, bigint, text, boolean, text, numeric, boolean, text, jsonb, bigint, text) to authenticated, service_role;
grant execute on function booking.admin_move_reservation_space(bigint, text, text) to authenticated, service_role;
grant execute on function booking.admin_review_list() to authenticated, service_role;
grant execute on function booking.import_attach_legs(bigint) to service_role;
grant execute on function booking.admin_list_reservations(timestamptz, timestamptz, text, text, bigint, integer, integer, text) to authenticated, service_role;
