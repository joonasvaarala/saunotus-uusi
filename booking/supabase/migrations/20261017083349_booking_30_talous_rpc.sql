-- booking_30_talous_rpc (17.10.2026): vaihe A – RPC:t, kohdistus, maksulinkki, hyvitys, ALV. Vaatii booking_29. Rollback: booking_30_ROLLBACK.sql
-- Sopimus: /workspace/procountor/KOODARI_talous_A_D_fi.md
drop function booking._create_legs_booking(text, bigint, timestamptz, timestamptz, integer, bigint, text, uuid, text, numeric, bigint, boolean, text, boolean, bigint);
drop function booking._create_booking_core(bigint, date, integer, bigint, text, uuid, text, text, text, integer, boolean, timestamptz, timestamptz, numeric, bigint);
-- ===== 0. moottori: lisäys olemassa olevaan tilaukseen (p_order_id) =====
CREATE OR REPLACE FUNCTION booking._create_legs_booking(p_lifecycle text, p_product_id bigint, p_start timestamp with time zone, p_end timestamp with time zone, p_persons integer, p_customer_id bigint, p_channel text, p_created_by uuid, p_note text, p_price numeric, p_space_id bigint, p_override boolean, p_override_reason text, p_quota_exempt boolean, p_parent_reservation_id bigint, p_order_id bigint DEFAULT NULL::bigint)
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
  if p_order_id is null then
    insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_note, created_by, confirmed_at)
    values (p_customer_id, 'confirmed', 'unpaid', v_total, p_channel, 'fi', p_note, p_created_by, now()) returning * into v_order;
  else   -- lisäys olemassa olevaan tilaukseen (booking_30): ei uutta tilausnumeroa
    select * into v_order from booking.orders where id = p_order_id for update;
    if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
    update booking.orders set total_gross = total_gross + v_total where id = p_order_id;
  end if;
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
  else   -- lisäys olemassa olevaan tilaukseen (booking_30)
    select * into v_order from booking.orders where id = p_order_id for update;
    if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
    update booking.orders set total_gross = total_gross + v_total where id = p_order_id;
  end if;

  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
  values (v_order.id, p.id, p.name, 'reservation', 1, v_total, v_total, p.vat_rate,
          pr.breakdown || jsonb_build_object('rule_id', p_rule_id, 'rule_label', (select label from booking.schedule_rules where id = p_rule_id))
                       || case when p_annual_card_id is not null then jsonb_build_object('annual_card_id', p_annual_card_id) else '{}'::jsonb end)
  returning id into v_item_id;

  v_hold := case when p_status = 'pending' then now() + make_interval(mins => greatest(coalesce(p_hold_minutes, 15), 1)) end;
  -- Trigger reservations_validate lukitsee tilan ja tarkistaa päällekkäisyydet/kapasiteetin/vuosikortin; virhe kumoaa koko lisäyksen.
  insert into booking.reservations(order_id, order_item_id, product_id, rule_id, annual_card_id, space_id, mode, starts_at, ends_at, persons,
                                   pool_ids, status, hold_expires_at, created_by)
  values (v_order.id, v_item_id, p.id, p_rule_id, p_annual_card_id, rs.o_space_id, rs.o_mode, rs.o_starts_at, rs.o_ends_at, p_persons,
          rs.o_pool_ids, p_status, v_hold, p_created_by)
  returning id into v_res_id;

  return jsonb_build_object('order_id', v_order.id, 'order_no', v_order.order_no, 'public_token', v_order.public_token,
                            'reservation_id', v_res_id, 'total', v_total, 'starts_at', rs.o_starts_at, 'ends_at', rs.o_ends_at,
                            'status', p_status, 'hold_expires_at', v_hold, 'product_name', p.name);
end $function$;

-- ===== 1. apufunktiot =====
create function booking._cash_rounding(p numeric) returns numeric language sql immutable set search_path = '' as
$$ select round(round(p * 20) / 20 - p, 2) $$;

create function booking._order_uncovered(p_order_id bigint, p_include_links boolean default false)
returns table(item_id bigint, description text, kind text, quantity integer, remaining numeric, vat_rate numeric)
language sql stable security definer set search_path = '' as $$
  select i.id, i.product_name, i.kind, i.quantity, i.line_total_gross - coalesce(c.cov, 0), i.vat_rate
    from booking.order_items i
    left join lateral (select sum(pl.amount_gross - pl.refunded_gross) as cov
                         from booking.payment_lines pl join booking.payments p on p.id = pl.payment_id
                        where pl.order_item_id = i.id
                          and (p.status in ('paid','partially_refunded','refunded')
                               or (p_include_links and p.status = 'pending' and p.provider <> 'manual'))) c on true
   where i.order_id = p_order_id and i.line_total_gross <> 0 and (i.line_total_gross - coalesce(c.cov, 0)) <> 0
   order by i.id
$$;

create function booking._order_balance(p_order_id bigint) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o booking.orders; v_paid numeric; v_ref numeric; v_link numeric; v_unpaid numeric;
begin
  select * into o from booking.orders where id = p_order_id;
  if not found then return null; end if;
  select coalesce(sum(amount) filter (where status in ('paid','partially_refunded','refunded')), 0),
         coalesce(sum(refunded_amount), 0),
         coalesce(sum(amount) filter (where status = 'pending' and provider <> 'manual' and (link_expires_at is null or link_expires_at > now())), 0)
    into v_paid, v_ref, v_link from booking.payments where order_id = p_order_id;
  v_unpaid := case when o.status in ('cancelled','expired','draft') then 0 else greatest(o.total_gross - (v_paid - v_ref), 0) end;
  return jsonb_build_object('total', o.total_gross, 'paid', v_paid, 'refunded', v_ref, 'pending_link', v_link, 'unpaid', v_unpaid,
                            'unpaid_unlinked', greatest(v_unpaid - v_link, 0), 'net_paid', v_paid - v_ref);
end $$;

-- rivitön "odotettu maksu" -paikkaaja pidetään ajan tasalla (ei kosketa, jos ei ole)
create function booking._sync_placeholder(p_order_id bigint) returns void language plpgsql security definer set search_path = '' as $$
declare v_unpaid numeric := (booking._order_balance(p_order_id) ->> 'unpaid')::numeric;
begin
  if v_unpaid > 0 then
    update booking.payments set amount = v_unpaid
     where order_id = p_order_id and status = 'pending' and provider = 'manual' and external_source is null
       and not exists (select 1 from booking.payment_lines pl where pl.payment_id = payments.id);
  else
    update booking.payments set status = 'cancelled'
     where order_id = p_order_id and status = 'pending' and provider = 'manual' and external_source is null
       and not exists (select 1 from booking.payment_lines pl where pl.payment_id = payments.id);
  end if;
end $$;

-- sähköpostijonon lisäys (Resend; send-emails lähettää). off -> skipped; dry_run/live -> pending (edge-funktio merkitsee dry_run)
create function booking._enqueue_email(p_kind text, p_order_id bigint, p_receipt_id bigint, p_payment_id bigint, p_dedupe text, p_payload jsonb default '{}'::jsonb)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_mode text; v_loc text; v_email text; v_n int;
begin
  select o.locale, c.email into v_loc, v_email from booking.orders o left join booking.customers c on c.id = o.customer_id where o.id = p_order_id;
  if v_email is null or not booking._valid_email(v_email) then return false; end if;
  select mode into v_mode from booking.integration_config where key = 'resend';
  insert into booking.email_outbox(kind, order_id, receipt_id, payment_id, locale, dedupe_key, status, payload)
  values (p_kind, p_order_id, p_receipt_id, p_payment_id, coalesce(v_loc, 'fi'), p_dedupe,
          case when coalesce(v_mode, 'off') = 'off' then 'skipped' else 'pending' end, coalesce(p_payload, '{}'::jsonb))
  on conflict (dedupe_key) do nothing;
  get diagnostics v_n = row_count;
  return v_n > 0;
end $$;

-- ===== 2. maksun rivit ja koukku =====
create function booking._alloc_payment_lines(p_payment_id bigint) returns void language plpgsql security definer set search_path = '' as $$
declare pay booking.payments; v_tot numeric; v_left numeric; r record; v_use numeric; v_last bigint; v_vat numeric;
begin
  select * into pay from booking.payments where id = p_payment_id;
  if not found or pay.amount <= 0 then return; end if;
  if exists (select 1 from booking.payment_lines where payment_id = pay.id) then return; end if;
  select coalesce(sum(remaining), 0) into v_tot from booking._order_uncovered(pay.order_id, true);
  v_left := pay.amount;
  if abs(v_tot - pay.amount) < 0.005 then
    insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
    select pay.id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(pay.order_id, true);
    return;
  end if;
  for r in select * from booking._order_uncovered(pay.order_id, true) where remaining > 0 loop
    exit when v_left <= 0.004;
    v_use := least(r.remaining, v_left);
    insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
    values (pay.id, r.item_id, r.description, r.kind, case when v_use = r.remaining then r.quantity else 1 end, v_use, r.vat_rate) returning id into v_last;
    v_left := v_left - v_use;
  end loop;
  if v_left > 0.004 then   -- ylimääräinen osuus (esim. vanha paikkaaja): kohdistetaan suurimman rivin verokannalla
    select vat_rate into v_vat from booking.order_items where order_id = pay.order_id order by line_total_gross desc, id limit 1;
    insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
    values (pay.id, null, 'Maksu', 'other', 1, v_left, coalesce(v_vat, 25.5));
  end if;
end $$;

create function booking._on_payment_paid(p_payment_id bigint) returns void language plpgsql security definer set search_path = '' as $$
begin
  null;   -- vaihe B (booking_31) korvaa: kuitin luonti + sähköpostijono
end $$;
create function booking._on_refund_done(p_refund_id bigint) returns void language plpgsql security definer set search_path = '' as $$
begin
  null;   -- vaihe B (booking_31) korvaa: hyvityskuitti + sähköpostijono
end $$;

create function booking.payments_paid_trg() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.external_source is not null then return null; end if;   -- Johku-historia ei kuittiin
  perform booking._alloc_payment_lines(new.id);
  if new.method = 'cash' and new.rounding = 0 then
    update booking.payments set rounding = booking._cash_rounding(new.amount) where id = new.id;
  end if;
  perform booking._on_payment_paid(new.id);
  return null;
end $$;
create trigger payments_paid_ins after insert on booking.payments for each row when (new.status = 'paid') execute function booking.payments_paid_trg();
create trigger payments_paid_upd after update of status on booking.payments for each row when (new.status = 'paid' and old.status is distinct from 'paid') execute function booking.payments_paid_trg();

-- ===== 3. maksulinkki (pysyvä link_token; tuore Visma-token vasta avattaessa, vaihe E) =====
create function booking._create_link_payment(p_order_id bigint, p_expires_days integer default 14, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o booking.orders; v_tot numeric; v_open booking.payments; v_n int; v_id bigint; v_token uuid; v_exp timestamptz; v_unpaid numeric;
begin
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if o.external_source is not null or o.status not in ('pending','confirmed','completed') then perform booking._err('order_not_editable', 'Tilaukselle ei voi luoda maksulinkkiä'); end if;
  if p_expires_days is null or p_expires_days < 1 or p_expires_days > 60 then perform booking._err('invalid_param', 'Linkin voimassaolo 1–60 päivää'); end if;
  select coalesce(sum(remaining) filter (where remaining > 0), 0) into v_tot from booking._order_uncovered(o.id, false);
  v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
  v_tot := least(v_tot, v_unpaid);
  if v_tot <= 0.004 then perform booking._err('nothing_to_pay', 'Ei maksettavaa'); end if;
  select count(*) into v_n from booking.payments where order_id = o.id and status = 'pending' and provider = 'visma_pay' and (link_expires_at is null or link_expires_at > now());
  if v_n = 1 then
    select * into v_open from booking.payments where order_id = o.id and status = 'pending' and provider = 'visma_pay' and (link_expires_at is null or link_expires_at > now());
    if v_open.amount = v_tot then
      return jsonb_build_object('payment_id', v_open.id, 'link_token', v_open.link_token, 'amount', v_open.amount, 'expires_at', v_open.link_expires_at, 'reused', true);
    end if;
  end if;
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu uudella maksulinkillä')
   where order_id = o.id and status = 'pending' and provider = 'visma_pay';
  v_exp := now() + make_interval(days => p_expires_days);
  insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, note, created_by)
  values (o.id, 'visma_pay', 'visma_pay', 'pending', v_tot, o.currency, v_exp, p_note, auth.uid()) returning id, link_token into v_id, v_token;
  insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
  select v_id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
  -- jos rivit ylittävät jäännöksen (poikkeus: hyvitetty/poistettu rivi), pienennetään suurinta riviä
  update booking.payment_lines set amount_gross = amount_gross - ((select sum(amount_gross) from booking.payment_lines where payment_id = v_id) - v_tot)
   where id = (select id from booking.payment_lines where payment_id = v_id order by amount_gross desc, id limit 1)
     and (select sum(amount_gross) from booking.payment_lines where payment_id = v_id) > v_tot;
  perform booking._refresh_order_payment(o.id);
  return jsonb_build_object('payment_id', v_id, 'link_token', v_token, 'amount', v_tot, 'expires_at', v_exp, 'reused', false);
end $$;

create function booking._link_json(p_payment_id bigint) returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('payment_id', p.id, 'link_token', p.link_token,
           'link_path', booking._setting('payment_link_path', to_jsonb('/maksa/'::text)) #>> '{}' || '?p=' || p.link_token,
           'amount', p.amount, 'expires_at', p.link_expires_at,
           'lines', coalesce((select jsonb_agg(jsonb_build_object('id', pl.id, 'order_item_id', pl.order_item_id, 'description', pl.description,
                        'quantity', pl.quantity, 'amount_gross', pl.amount_gross, 'vat_rate', pl.vat_rate) order by pl.id)
                     from booking.payment_lines pl where pl.payment_id = p.id), '[]'::jsonb))
    from booking.payments p where p.id = p_payment_id
$$;

create function booking.expire_payment_links() returns integer language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0;
begin
  for r in update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'maksulinkki vanheni')
            where status = 'pending' and provider <> 'manual' and external_source is null and link_expires_at is not null and link_expires_at < now()
        returning order_id loop
    perform booking._refresh_order_payment(r.order_id); n := n + 1;
  end loop;
  return n;
end $$;

create or replace function booking.payment_prepare(p_order_id bigint) returns jsonb language plpgsql security definer set search_path = '' as $$
declare o booking.orders; c booking.customers; v jsonb;
begin
  select * into o from booking.orders where id = p_order_id;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  select * into c from booking.customers where id = o.customer_id;
  v := booking._create_link_payment(o.id, 1, null);
  return jsonb_build_object('payment_id', (v ->> 'payment_id')::bigint, 'order_no', o.order_no, 'amount', (v ->> 'amount')::numeric, 'currency', o.currency,
                            'email', c.email, 'locale', o.locale, 'link_token', v ->> 'link_token');
end $$;

-- ===== 4. luku: Tilaukset ja Maksut =====
create function booking.admin_list_orders(
  p_search text default null, p_status text default null, p_payment_status text default null, p_source text default null, p_native boolean default null,
  p_date_field text default 'created', p_from date default null, p_to date default null, p_sort text default 'created_desc', p_limit integer default 50, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_s text := nullif(btrim(coalesce(p_search, '')), ''); v_num bigint; v_like text; v_total int; v_rows jsonb; v_lim int := coalesce(p_limit, 50); v_off int := greatest(coalesce(p_offset, 0), 0);
begin
  perform booking._require_staff();
  if p_sort is null or p_sort not in ('created_desc','created_asc','order_no_desc','order_no_asc','total_desc','total_asc','start_desc','start_asc','paid_desc','paid_asc','unpaid_desc') then
    perform booking._err('invalid_sort', 'Tuntematon lajittelu'); end if;
  if v_lim < 1 or v_lim > 200 then perform booking._err('invalid_param', 'p_limit 1–200'); end if;
  if coalesce(p_date_field, 'created') not in ('created','start') then perform booking._err('invalid_param', 'p_date_field: created|start'); end if;
  if v_s ~ '^\d{1,12}$' then v_num := v_s::bigint; end if;
  if v_s is not null then v_like := '%' || replace(replace(replace(v_s, '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;
  with base as (
    select o.id, o.order_no, o.johku_order_no, o.created_at, o.status, o.payment_status, o.source_channel, (o.external_source is null) as is_native, o.total_gross,
           pp.paid, pp.refunded, pp.pc, pp.lp, rr.fs, rr.le, rr.cnt, rcc.rc,
           case when o.status in ('cancelled','expired','draft') then 0 else greatest(o.total_gross - (pp.paid - pp.refunded), 0) end as unpaid,
           c.id as cid, c.name as cname, c.company as ccompany, o.customer_kind
      from booking.orders o
      left join booking.customers c on c.id = o.customer_id
      left join lateral (select min(r.starts_at) fs, max(r.ends_at) le, count(*) cnt from booking.reservations r where r.order_id = o.id) rr on true
      left join lateral (select coalesce(sum(p.amount) filter (where p.status in ('paid','partially_refunded','refunded')), 0) paid, coalesce(sum(p.refunded_amount), 0) refunded,
                                count(*) filter (where p.status in ('paid','partially_refunded','refunded')) pc, max(p.paid_at) lp
                           from booking.payments p where p.order_id = o.id) pp on true
      left join lateral (select count(*) rc from booking.receipts x where x.order_id = o.id) rcc on true
     where (p_status is null or o.status = p_status)
       and (p_payment_status is null or o.payment_status = p_payment_status)
       and (p_source is null or o.source_channel = p_source)
       and (p_native is null or (o.external_source is null) = p_native)
       and (v_s is null or (v_num is not null and (o.order_no = v_num or o.johku_order_no = v_num))
            or (v_num is null and (c.name ilike v_like or c.email ilike v_like or c.phone ilike v_like or c.company ilike v_like)))
       and (p_from is null or case when coalesce(p_date_field, 'created') = 'created' then (o.created_at at time zone 'Europe/Helsinki')::date else (rr.fs at time zone 'Europe/Helsinki')::date end >= p_from)
       and (p_to   is null or case when coalesce(p_date_field, 'created') = 'created' then (o.created_at at time zone 'Europe/Helsinki')::date else (rr.fs at time zone 'Europe/Helsinki')::date end <= p_to)
  ), page as (
    select b.*, row_number() over (order by
        case when p_sort = 'created_asc' then b.created_at end asc, case when p_sort = 'created_desc' then b.created_at end desc,
        case when p_sort = 'order_no_asc' then b.order_no end asc, case when p_sort = 'order_no_desc' then b.order_no end desc,
        case when p_sort = 'total_asc' then b.total_gross end asc, case when p_sort = 'total_desc' then b.total_gross end desc,
        case when p_sort = 'start_asc' then b.fs end asc nulls last, case when p_sort = 'start_desc' then b.fs end desc nulls last,
        case when p_sort = 'paid_asc' then b.lp end asc nulls last, case when p_sort = 'paid_desc' then b.lp end desc nulls last,
        case when p_sort = 'unpaid_desc' then b.unpaid end desc, b.id desc) as rn
      from base b
  )
  select (select count(*) from base),
         coalesce(jsonb_agg(jsonb_build_object('order_id', p.id, 'order_no', p.order_no, 'johku_order_no', p.johku_order_no, 'created_at', p.created_at, 'status', p.status,
           'payment_status', p.payment_status, 'source_channel', p.source_channel, 'is_native', p.is_native, 'total', p.total_gross, 'paid', p.paid, 'refunded', p.refunded,
           'unpaid', p.unpaid, 'customer_id', p.cid, 'customer_name', p.cname, 'customer_company', p.ccompany, 'customer_kind', p.customer_kind, 'first_start', p.fs, 'last_end', p.le,
           'reservation_count', p.cnt, 'payment_count', p.pc, 'last_paid_at', p.lp, 'receipt_count', p.rc) order by p.rn), '[]'::jsonb)
    into v_total, v_rows from page p where p.rn > v_off and p.rn <= v_off + v_lim;
  return jsonb_build_object('total', v_total, 'rows', v_rows);
end $$;

create or replace function booking.admin_get_order(p_order_id bigint) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o booking.orders; c booking.customers; v_end timestamptz; v_site text; v_op text; v_pp text;
begin
  perform booking._require_staff();
  select * into o from booking.orders where id = p_order_id;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  select * into c from booking.customers where id = o.customer_id;
  select max(r.ends_at) into v_end from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at);
  v_site := coalesce(booking._setting('site_base_url') #>> '{}', ''); v_op := coalesce(booking._setting('order_page_path') #>> '{}', '/tilaus/');
  v_pp := coalesce(booking._setting('payment_link_path') #>> '{}', '/maksa/');
  return jsonb_build_object(
    'order_id', o.id, 'order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status, 'total', o.total_gross,
    'source_channel', o.source_channel, 'created_at', o.created_at, 'customer_note', o.customer_note, 'internal_note', o.internal_note,
    'customer_kind', o.customer_kind, 'billing', o.billing, 'invoice_reference', o.invoice_reference,
    'customer', case when c.id is null then null else jsonb_build_object('id', c.id, 'name', c.name, 'email', c.email, 'phone', c.phone,
        'company', c.company, 'customer_kind', c.customer_kind, 'business_id', c.business_id) end,
    'reservations', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status, 'product_name', it.product_name, 'mode', r.mode,
        'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'notes', r.notes, 'item_total', it.line_total_gross, 'item_id', r.order_item_id,
        'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', ai.addon_id, 'name', ai.product_name, 'quantity', ai.quantity,
                     'unit_price', ai.unit_price_gross, 'line_total', ai.line_total_gross, 'vat_rate', ai.vat_rate) order by ai.id)
                   from booking.order_items ai where ai.parent_item_id = r.order_item_id and ai.kind = 'addon'), '[]'::jsonb)) order by r.starts_at)
        from booking.reservations r left join booking.order_items it on it.id = r.order_item_id where r.order_id = o.id), '[]'::jsonb),
    'public_token', o.public_token, 'order_page_path', v_site || v_op || '?t=' || o.public_token, 'is_native', o.external_source is null,
    'balance', booking._order_balance(o.id),
    'can_add', o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now(), 'add_until', v_end,
    'staff_can_add', o.external_source is null and o.status in ('confirmed','completed'),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'parent_item_id', i.parent_item_id, 'kind', i.kind, 'product_id', i.product_id, 'name', i.product_name,
        'quantity', i.quantity, 'unit_price', i.unit_price_gross, 'line_total', i.line_total_gross, 'vat_rate', i.vat_rate, 'line_vat', i.line_vat, 'line_net', i.line_net,
        'covered', cv.cov, 'remaining', i.line_total_gross - cv.cov) order by i.id)
        from booking.order_items i
        left join lateral (select coalesce(sum(pl.amount_gross - pl.refunded_gross), 0) cov from booking.payment_lines pl join booking.payments p on p.id = pl.payment_id
                            where pl.order_item_id = i.id and p.status in ('paid','partially_refunded','refunded')) cv on true
       where i.order_id = o.id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'method', p.method, 'status', p.status, 'amount', p.amount, 'paid_at', p.paid_at,
        'provider', p.provider, 'provider_status', p.provider_status, 'refunded_amount', p.refunded_amount, 'rounding', p.rounding, 'link_token', p.link_token,
        'link_path', case when p.provider <> 'manual' and p.status = 'pending' then v_pp || '?p=' || p.link_token end, 'link_expires_at', p.link_expires_at,
        'note', p.note, 'created_at', p.created_at,
        'lines', coalesce((select jsonb_agg(jsonb_build_object('id', pl.id, 'order_item_id', pl.order_item_id, 'description', pl.description, 'quantity', pl.quantity,
                      'amount_gross', pl.amount_gross, 'vat_rate', pl.vat_rate, 'refunded_gross', pl.refunded_gross) order by pl.id)
                    from booking.payment_lines pl where pl.payment_id = p.id), '[]'::jsonb),
        'receipts', coalesce((select jsonb_agg(jsonb_build_object('id', rc.id, 'receipt_no', rc.receipt_no, 'kind', rc.kind, 'issued_at', rc.issued_at,
                      'public_token', rc.public_token, 'sent_at', rc.sent_at) order by rc.id) from booking.receipts rc where rc.payment_id = p.id), '[]'::jsonb),
        'refunds', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'amount', f.amount, 'status', f.status, 'reason', f.reason, 'created_at', f.created_at,
                      'done_at', f.done_at) order by f.id) from booking.refunds f where f.payment_id = p.id), '[]'::jsonb)) order by p.id)
        from booking.payments p where p.order_id = o.id), '[]'::jsonb),
    'receipts', coalesce((select jsonb_agg(jsonb_build_object('id', rc.id, 'receipt_no', rc.receipt_no, 'kind', rc.kind, 'issued_at', rc.issued_at, 'total', rc.total_gross,
        'payment_id', rc.payment_id, 'refund_id', rc.refund_id, 'public_token', rc.public_token, 'sent_at', rc.sent_at) order by rc.id)
        from booking.receipts rc where rc.order_id = o.id), '[]'::jsonb),
    'refunds', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'payment_id', f.payment_id, 'amount', f.amount, 'status', f.status, 'reason', f.reason,
        'created_at', f.created_at, 'done_at', f.done_at) order by f.id) from booking.refunds f where f.order_id = o.id), '[]'::jsonb),
    'emails', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'status', e.status, 'sent_at', e.sent_at, 'created_at', e.created_at) order by e.id)
        from booking.email_outbox e where e.order_id = o.id), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'status', q.status, 'reason', q.reason, 'created_at', q.created_at,
        'handled_at', q.handled_at, 'note', q.note) order by q.id) from booking.order_requests q where q.order_id = o.id), '[]'::jsonb));
end $$;

create function booking.admin_list_payments(
  p_search text default null, p_method text default null, p_status text default null, p_from date default null, p_to date default null,
  p_sort text default 'paid_desc', p_include_placeholders boolean default false, p_limit integer default 50, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_s text := nullif(btrim(coalesce(p_search, '')), ''); v_num bigint; v_like text; v_total int; v_rows jsonb; v_sp numeric; v_sr numeric; v_lim int := coalesce(p_limit, 50); v_off int := greatest(coalesce(p_offset, 0), 0);
begin
  perform booking._require_staff();
  if p_sort is null or p_sort not in ('paid_desc','paid_asc','amount_desc','amount_asc','order_no_desc','order_no_asc') then perform booking._err('invalid_sort', 'Tuntematon lajittelu'); end if;
  if v_lim < 1 or v_lim > 200 then perform booking._err('invalid_param', 'p_limit 1–200'); end if;
  if v_s ~ '^\d{1,12}$' then v_num := v_s::bigint; end if;
  if v_s is not null then v_like := '%' || replace(replace(replace(v_s, '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;
  with base as (
    select p.id, p.order_id, o.order_no, p.method, pm.label as mlabel, p.provider, p.status, p.amount, p.refunded_amount, p.rounding, p.paid_at, p.created_at,
           c.name as cname, (select count(*) from booking.payment_lines pl where pl.payment_id = p.id) as lc,
           rc.receipt_no, rc.public_token as rtoken, coalesce(p.paid_at, p.created_at) as ts
      from booking.payments p join booking.orders o on o.id = p.order_id
      left join booking.customers c on c.id = o.customer_id left join booking.payment_methods pm on pm.code = p.method
      left join lateral (select x.receipt_no, x.public_token from booking.receipts x where x.payment_id = p.id and x.kind = 'receipt' limit 1) rc on true
     where (p_method is null or p.method = p_method) and (p_status is null or p.status = p_status)
       and (p_include_placeholders or not (p.provider = 'manual' and p.status = 'pending' and p.external_source is null
                                           and not exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id)))
       and (p_from is null or (coalesce(p.paid_at, p.created_at) at time zone 'Europe/Helsinki')::date >= p_from)
       and (p_to is null or (coalesce(p.paid_at, p.created_at) at time zone 'Europe/Helsinki')::date <= p_to)
       and (v_s is null or (v_num is not null and (o.order_no = v_num or p.id = v_num)) or rc.receipt_no ilike v_like or (v_num is null and (c.name ilike v_like or c.email ilike v_like)))
  ), page as (
    select b.*, row_number() over (order by
       case when p_sort = 'paid_asc' then b.ts end asc, case when p_sort = 'paid_desc' then b.ts end desc,
       case when p_sort = 'amount_asc' then b.amount end asc, case when p_sort = 'amount_desc' then b.amount end desc,
       case when p_sort = 'order_no_asc' then b.order_no end asc, case when p_sort = 'order_no_desc' then b.order_no end desc, b.id desc) rn from base b)
  select (select count(*) from base),
         (select coalesce(sum(amount) filter (where status in ('paid','partially_refunded','refunded')), 0) from base),
         (select coalesce(sum(refunded_amount), 0) from base),
         coalesce(jsonb_agg(jsonb_build_object('payment_id', p.id, 'order_id', p.order_id, 'order_no', p.order_no, 'method', p.method, 'method_label', p.mlabel, 'provider', p.provider,
           'status', p.status, 'amount', p.amount, 'refunded_amount', p.refunded_amount, 'rounding', p.rounding, 'paid_at', p.paid_at, 'created_at', p.created_at,
           'customer_name', p.cname, 'line_count', p.lc, 'receipt_no', p.receipt_no, 'receipt_token', p.rtoken) order by p.rn), '[]'::jsonb)
    into v_total, v_sp, v_sr, v_rows from page p where p.rn > v_off and p.rn <= v_off + v_lim;
  return jsonb_build_object('total', v_total, 'sum_paid', v_sp, 'sum_refunded', v_sr, 'rows', v_rows);
end $$;

-- ===== 5. lisäys tilaukseen =====
create function booking._add_to_order(p_order_id bigint, p_items jsonb, p_staff boolean) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  o booking.orders; e jsonb; v_type text; v_added jsonb := '[]'::jsonb; v_total0 numeric; v_end timestamptz; v_res booking.reservations; a booking.addons; v_qty int; v_cur int; v_lim int;
  v_item bigint; p kb.products; pc booking.product_config; v_resid bigint; v_n int; v_r jsonb; v_pid bigint; v_start timestamptz; v_en timestamptz; v_line numeric; v_vat numeric; v_amt numeric;
  v_desc text; v_ovr boolean; v_chan text := case when p_staff then 'admin' else 'web' end; v_price numeric; v_add numeric; v_idtxt text; v_code text; v_mode text; v_rid bigint;
begin
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if o.external_source is not null or not (o.status = 'confirmed' or (p_staff and o.status = 'completed')) then perform booking._err('order_not_editable', 'Tilaukseen ei voi lisätä'); end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 20 then perform booking._err('invalid_items', 'Anna 1–20 lisättävää riviä'); end if;
  select max(r.ends_at) into v_end from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at);
  if not p_staff and (v_end is null or v_end <= now()) then perform booking._err('order_closed', 'Lisäysaika on päättynyt'); end if;
  v_total0 := o.total_gross;

  for e in select * from jsonb_array_elements(p_items) loop
    if jsonb_typeof(e) <> 'object' then perform booking._err('invalid_items', 'Rivi väärässä muodossa'); end if;
    v_type := e ->> 'type';
    if v_type = 'addon' then
      if coalesce(e ->> 'reservation_id', '') ~ '^\d{1,18}$' then v_resid := (e ->> 'reservation_id')::bigint;
      elsif e ->> 'reservation_id' is not null then perform booking._err('item_not_found', 'Varausta ei löydy');
      else
        select count(*), min(r.id) into v_n, v_resid from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at);
        if v_n <> 1 then perform booking._err('invalid_items', 'Anna reservation_id'); end if;
      end if;
      select * into v_res from booking.reservations where id = v_resid and order_id = o.id;
      if not found then perform booking._err('item_not_found', 'Varausta ei löydy tilauksesta'); end if;
      if not booking._res_active(v_res.status, v_res.hold_expires_at) then perform booking._err('order_not_editable', 'Varaus ei ole voimassa'); end if;
      if not p_staff and v_res.ends_at <= now() then perform booking._err('order_closed', 'Lisäysaika on päättynyt'); end if;
      v_idtxt := e ->> 'addon_id'; v_code := e ->> 'code';
      if v_idtxt is not null and v_idtxt !~ '^\d{1,18}$' then perform booking._err('addon_not_found', 'Lisäpalvelua ei löydy'); end if;
      select * into a from booking.addons where (v_idtxt is not null and id = v_idtxt::bigint) or (v_idtxt is null and v_code is not null and code = v_code);
      if not found then perform booking._err('addon_not_found', 'Lisäpalvelua ei löydy'); end if;
      if coalesce(e ->> 'quantity', '') !~ '^\d{1,4}$' or (e ->> 'quantity')::int = 0 then perform booking._err('addon_quantity', 'Lisäpalvelun määrän pitää olla kokonaisluku'); end if;
      v_qty := (e ->> 'quantity')::int;
      select coalesce(sum(quantity), 0) into v_cur from booking.order_items where parent_item_id = v_res.order_item_id and addon_id = a.id and kind = 'addon';
      v_lim := booking._addon_limit(a.max_per_person, v_res.persons);
      if v_cur + v_qty > v_lim then perform booking._err('addon_quantity', format('Lisäpalvelua "%s" voi olla enintään %s kpl (nyt %s)', a.name, v_lim, v_cur)); end if;
      perform booking._attach_addons(v_res.id, jsonb_build_array(jsonb_build_object('id', a.id, 'quantity', v_qty)));
      select max(id) into v_item from booking.order_items where parent_item_id = v_res.order_item_id and addon_id = a.id;
      select line_total_gross into v_line from booking.order_items where id = v_item;
      v_added := v_added || jsonb_build_object('item_id', v_item, 'name', a.name, 'line_total', v_line, 'reservation_id', v_res.id);

    elsif v_type = 'reservation' then
      v_add := 0; v_rid := null;
      if e ? 'product_id' then
        if coalesce(e ->> 'product_id', '') !~ '^\d{1,18}$' then perform booking._err('invalid_items', 'product_id virheellinen'); end if;
        v_pid := (e ->> 'product_id')::bigint;
        if coalesce(e ->> 'persons', '') !~ '^\d{1,3}$' then perform booking._err('invalid_items', 'persons virheellinen'); end if;
        v_start := (e ->> 'start')::timestamptz; v_en := nullif(e ->> 'end', '')::timestamptz;
        v_ovr := coalesce((e ->> 'override')::boolean, false);
        if not p_staff then
          select * into pc from booking.product_config where product_id = v_pid;
          if not found or not pc.bookable or not pc.shop_visible or not pc.public_slots or e ? 'price' or e ? 'space_id' or e ? 'parent_reservation_id' or v_ovr then
            perform booking._err('invalid_items', 'Tuotetta ei voi lisätä verkossa');
          end if;
          if v_start is null or v_start < now() then perform booking._err('bad_time', 'Virheellinen aika'); end if;
        elsif v_ovr and not booking.has_permission('bookings.override') then perform booking._err('forbidden', 'Ei oikeutta ylitykseen (bookings.override)');
        end if;
        v_price := case when p_staff and e ? 'price' then (e ->> 'price')::numeric end;
        if v_price is not null and v_price < 0 then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
        v_r := booking._create_legs_booking('current', v_pid, v_start, v_en, (e ->> 'persons')::int, o.customer_id, v_chan, auth.uid(), null, v_price,
                 nullif(e ->> 'space_id', '')::bigint, v_ovr, e ->> 'override_reason', false, nullif(e ->> 'parent_reservation_id', '')::bigint, o.id);
      elsif e ? 'rule_id' then
        if coalesce(e ->> 'rule_id', '') !~ '^\d{1,18}$' or coalesce(e ->> 'persons', '') !~ '^\d{1,3}$' then perform booking._err('invalid_items', 'rule_id/persons virheellinen'); end if;
        v_r := booking._create_booking_core((e ->> 'rule_id')::bigint, (e ->> 'date')::date, (e ->> 'persons')::int, o.customer_id, v_chan, auth.uid(), o.locale, null,
                 'confirmed', null, not p_staff, null, null, null, null, o.id);
      else perform booking._err('invalid_items', 'Varausrivillä pitää olla product_id tai rule_id');
      end if;
      v_rid := (v_r ->> 'reservation_id')::bigint;
      if e ? 'addons' then v_add := booking._attach_addons(v_rid, e -> 'addons'); end if;
      select order_item_id into v_item from booking.reservations where id = v_rid;
      v_added := v_added || jsonb_build_object('item_id', v_item, 'name', v_r ->> 'product_name', 'line_total', (v_r ->> 'total')::numeric + v_add, 'reservation_id', v_rid);

    elsif v_type = 'product' then
      if coalesce(e ->> 'product_id', '') !~ '^\d{1,18}$' or coalesce(e ->> 'quantity', '') !~ '^\d{1,2}$' or (e ->> 'quantity')::int = 0 then perform booking._err('invalid_items', 'Tuote/määrä virheellinen'); end if;
      select * into p from kb.products where id = (e ->> 'product_id')::bigint and active;
      if not found or p.category <> 'product_rental' then perform booking._err('item_not_found', 'Tuotetta ei löydy / ei lisättävissä'); end if;
      if p.vat_rate is null then perform booking._err('vat_missing', 'Tuotteelta puuttuu ALV-kanta'); end if;
      if p.price is null then perform booking._err('invalid_items', 'Tuotteella ei ole hintaa'); end if;
      v_qty := (e ->> 'quantity')::int; v_line := p.price * v_qty;
      insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
      values (o.id, p.id, p.name, 'product', v_qty, p.price, v_line, p.vat_rate, jsonb_build_object('model', 'add_to_order')) returning id into v_item;
      update booking.orders set total_gross = total_gross + v_line where id = o.id;
      v_added := v_added || jsonb_build_object('item_id', v_item, 'name', p.name, 'line_total', v_line);

    elsif v_type = 'custom' then
      if not p_staff then perform booking._err('invalid_items', 'Rivityyppi ei ole sallittu'); end if;
      if not booking.has_permission('bookings.override') then perform booking._err('forbidden', 'Vapaa rivi vaatii oikeuden bookings.override'); end if;
      v_desc := btrim(coalesce(e ->> 'description', ''));
      if char_length(v_desc) not between 3 and 120 then perform booking._err('invalid_items', 'Kuvaus 3–120 merkkiä'); end if;
      if coalesce(e ->> 'amount', '') !~ '^-?\d{1,5}(\.\d{1,2})?$' then perform booking._err('invalid_items', 'Summa virheellinen'); end if;
      v_amt := (e ->> 'amount')::numeric;
      if v_amt = 0 then perform booking._err('invalid_items', 'Summa ei voi olla 0'); end if;
      if coalesce(e ->> 'vat_rate', '') !~ '^\d{1,3}(\.\d{1,2})?$' then perform booking._err('invalid_vat', 'ALV-kanta puuttuu'); end if;
      v_vat := (e ->> 'vat_rate')::numeric;
      if not booking._vat_active(v_vat) then perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu'); end if;
      v_qty := coalesce(nullif(e ->> 'quantity', '')::int, 1);
      if v_qty not between 1 and 99 then perform booking._err('invalid_items', 'Määrä 1–99'); end if;
      v_line := v_amt * v_qty;
      if (select total_gross from booking.orders where id = o.id) + v_line < 0 then perform booking._err('invalid_items', 'Alennus ylittää tilauksen summan'); end if;
      insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
      values (o.id, v_desc, case when v_amt < 0 then 'discount' else 'fee' end, v_qty, v_amt, v_line, v_vat, jsonb_build_object('model', 'custom_line')) returning id into v_item;
      update booking.orders set total_gross = total_gross + v_line where id = o.id;
      v_added := v_added || jsonb_build_object('item_id', v_item, 'name', v_desc, 'line_total', v_line);
    else
      perform booking._err('invalid_items', 'Tuntematon rivityyppi');
    end if;
  end loop;

  perform booking._sync_placeholder(o.id);
  perform booking._refresh_order_payment(o.id);
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'orders', o.id::text, case when p_staff then 'ADMIN_ADD_TO_ORDER' else 'CUSTOMER_ADD_TO_ORDER' end,
          jsonb_build_object('total', v_total0), jsonb_build_object('items', p_items, 'added', v_added, 'total', (select total_gross from booking.orders where id = o.id)));
  return jsonb_build_object('added', v_added, 'added_total', (select total_gross from booking.orders where id = o.id) - v_total0);
end $$;

create function booking.admin_add_to_order(p_order_id bigint, p_items jsonb, p_create_link boolean default false, p_send_email boolean default false, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; v_pay jsonb; v_link jsonb := null; v_mail boolean := false; v_pid bigint; v_code text;
begin
  perform booking._require_permission('bookings.manage');
  v := booking._add_to_order(p_order_id, p_items, true);
  if p_note is not null then update booking.orders set internal_note = concat_ws(E'\n', internal_note, btrim(p_note)) where id = p_order_id; end if;
  if p_create_link or p_send_email then
    begin
      v_pay := booking._create_link_payment(p_order_id, 14, p_note);
      v_pid := (v_pay ->> 'payment_id')::bigint;
      v_link := booking._link_json(v_pid);
      if p_send_email then
        v_mail := booking._enqueue_email('payment_link', p_order_id, null, v_pid, 'payment_link:' || v_pid || ':' || to_char(now(), 'YYYYMMDDHH24MI'));
      end if;
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_code = pg_exception_detail;
      if v_code is distinct from 'nothing_to_pay' then raise; end if;
    end;
  end if;
  return jsonb_build_object('ok', true, 'order_id', p_order_id, 'added', v -> 'added', 'added_total', v -> 'added_total',
                            'balance', booking._order_balance(p_order_id),
                            'payment', case when v_link is null then null else v_link - 'lines' end, 'email_queued', v_mail);
end $$;

-- ===== 6. maksulinkki (hallinta) =====
drop function booking.admin_create_payment_link(bigint);
create function booking.admin_create_payment_link(p_order_id bigint, p_send_email boolean default false, p_expires_days integer default 14, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; v_pid bigint; v_mail boolean := false; v_mode text;
begin
  perform booking._require_permission('payments.manage');
  v := booking._create_link_payment(p_order_id, p_expires_days, p_note);
  v_pid := (v ->> 'payment_id')::bigint;
  if p_send_email then v_mail := booking._enqueue_email('payment_link', p_order_id, null, v_pid, 'payment_link:' || v_pid || ':' || to_char(now(), 'YYYYMMDDHH24MI')); end if;
  select mode into v_mode from booking.integration_config where key = 'vismapay';
  return jsonb_build_object('ok', true) || (booking._link_json(v_pid)) || jsonb_build_object('online_payment_enabled', coalesce(v_mode, 'off') = 'live', 'email_queued', v_mail);
end $$;

-- ===== 7. käsin kirjattu maksu =====
drop function booking.admin_record_payment(bigint, text, numeric, text);
create function booking.admin_record_payment(p_order_id bigint, p_method text, p_amount numeric, p_note text default null, p_lines jsonb default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o booking.orders; v_pm booking.payment_methods; v_id bigint; v_unpaid numeric; l jsonb; v_it record; v_sum numeric := 0; v_rem numeric; v_round numeric; rc record;
begin
  perform booking._require_permission('payments.manage');
  select * into v_pm from booking.payment_methods where code = p_method and active and is_manual;
  if not found then perform booking._err('invalid_payment_method', 'Maksutapa ei ole käytössä / ei käsin kirjattava'); end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if o.external_source is not null or o.status not in ('pending','confirmed','completed') then perform booking._err('order_not_editable', 'Tilaukselle ei voi kirjata maksua'); end if;
  v_unpaid := case when o.status = 'pending' then greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0) else (booking._order_balance(o.id) ->> 'unpaid')::numeric end;
  if p_amount > v_unpaid + 0.004 then perform booking._err('amount_exceeds_unpaid', format('Summa ylittää maksamattoman osuuden (%s €)', v_unpaid)); end if;
  -- rivittömät paikkaajat ja avoimet linkit peruutetaan; linkki luodaan tarvittaessa uudelleen jäännökselle
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu käsin kirjatulla maksulla')
   where order_id = o.id and status = 'pending' and external_source is null
     and ((provider = 'manual' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = payments.id)) or provider <> 'manual');
  v_round := case when p_method = 'cash' then booking._cash_rounding(p_amount) else 0 end;
  insert into booking.payments(order_id, method, provider, status, amount, rounding, note, created_by)
  values (o.id, p_method, 'manual', 'pending', p_amount, v_round, p_note, auth.uid()) returning id into v_id;
  if p_lines is not null then
    if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then perform booking._err('invalid_items', 'p_lines väärässä muodossa'); end if;
    for l in select * from jsonb_array_elements(p_lines) loop
      if coalesce(l ->> 'item_id', '') !~ '^\d{1,18}$' or coalesce(l ->> 'amount', '') !~ '^\d{1,6}(\.\d{1,2})?$' then perform booking._err('invalid_items', 'Rivi virheellinen'); end if;
      select * into v_it from booking._order_uncovered(o.id, false) u where u.item_id = (l ->> 'item_id')::bigint;
      if not found then perform booking._err('item_not_found', 'Riviä ei löydy tai se on jo maksettu'); end if;
      if (l ->> 'amount')::numeric <= 0 or (l ->> 'amount')::numeric > v_it.remaining + 0.004 then perform booking._err('invalid_items', 'Rivin summa ylittää maksamattoman osuuden'); end if;
      insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
      values (v_id, v_it.item_id, v_it.description, v_it.kind, case when (l ->> 'amount')::numeric = v_it.remaining then v_it.quantity else 1 end, (l ->> 'amount')::numeric, v_it.vat_rate);
      v_sum := v_sum + (l ->> 'amount')::numeric;
    end loop;
    if abs(v_sum - p_amount) > 0.004 then perform booking._err('invalid_items', 'Rivien summa ei vastaa maksun summaa'); end if;
  else
    perform booking._alloc_payment_lines(v_id);
  end if;
  update booking.payments set status = 'paid', paid_at = now() where id = v_id;       -- trigger: rivit (jos puuttuvat), kuitti (vaihe B)
  perform booking._sync_placeholder(o.id);
  perform booking._refresh_order_payment(o.id);
  update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = o.id and status = 'pending';
  update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()) where id = o.id and status = 'pending';
  select receipt_no, id into rc from booking.receipts where payment_id = v_id and kind = 'receipt';
  return jsonb_build_object('ok', true, 'payment_id', v_id, 'balance', booking._order_balance(o.id), 'receipt_id', rc.id, 'receipt_no', rc.receipt_no,
                            'rounding', (select rounding from booking.payments where id = v_id));
end $$;

-- ===== 8. hyvitys =====
create function booking.admin_refund(p_payment_id bigint, p_amount numeric, p_reason text, p_lines jsonb default null, p_manual_done boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare pay booking.payments; o booking.orders; v_cap numeric; v_mode text; v_online boolean; v_id bigint; l jsonb; v_pl booking.payment_lines; v_sum numeric := 0; v_full boolean;
        r record; v_total_cap numeric; v_alloc numeric; v_left numeric; v_alloc_json jsonb := '[]'::jsonb; v_status text; rc record; v_n int; v_i int := 0;
begin
  perform booking._require_permission('payments.refund');
  select * into pay from booking.payments where id = p_payment_id for update;
  if not found then perform booking._err('not_found', 'Maksua ei löydy'); end if;
  select * into o from booking.orders where id = pay.order_id for update;
  if o.external_source is not null or pay.external_source is not null then perform booking._err('order_not_editable', 'Johku-historian maksuja ei voi hyvittää tässä'); end if;
  if pay.status = 'refunded' then perform booking._err('already_refunded', 'Maksu on jo hyvitetty kokonaan'); end if;
  if pay.status not in ('paid','partially_refunded') then perform booking._err('refund_not_allowed', 'Vain maksettu maksu voidaan hyvittää'); end if;
  if p_reason is null or char_length(btrim(p_reason)) < 3 or char_length(p_reason) > 500 then perform booking._err('invalid_param', 'Anna hyvityksen syy (3–500 merkkiä)'); end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  v_cap := pay.amount - pay.refunded_amount - coalesce((select sum(f.amount) from booking.refunds f where f.payment_id = pay.id and f.status in ('requested','processing')), 0);
  if p_amount > v_cap + 0.004 then perform booking._err('amount_exceeds_refundable', format('Hyvitettävissä enintään %s €', v_cap)); end if;
  v_online := pay.provider <> 'manual';
  select mode into v_mode from booking.integration_config where key = replace(pay.provider, '_', '');
  if v_online and coalesce(v_mode, 'off') = 'off' then
    if not p_manual_done then perform booking._err('refund_not_allowed', 'Verkkomaksun hyvitys ei ole vielä käytössä – hyvitä Visman portaalissa ja kirjaa käsin (vain admin)'); end if;
    if booking.current_staff_role() is distinct from 'admin' then perform booking._err('forbidden', 'Käsinkirjaus verkkomaksulle vaatii admin-roolin'); end if;
  end if;
  v_full := abs(p_amount - v_cap) < 0.005 and pay.refunded_amount = 0;

  -- rivijako
  if p_lines is not null then
    if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then perform booking._err('invalid_items', 'p_lines väärässä muodossa'); end if;
    for l in select * from jsonb_array_elements(p_lines) loop
      if coalesce(l ->> 'payment_line_id', '') !~ '^\d{1,18}$' or coalesce(l ->> 'amount', '') !~ '^\d{1,6}(\.\d{1,2})?$' then perform booking._err('invalid_items', 'Rivi virheellinen'); end if;
      select * into v_pl from booking.payment_lines where id = (l ->> 'payment_line_id')::bigint and payment_id = pay.id;
      if not found then perform booking._err('item_not_found', 'Maksun riviä ei löydy'); end if;
      if (l ->> 'amount')::numeric <= 0 or (l ->> 'amount')::numeric > v_pl.amount_gross - v_pl.refunded_gross + 0.004 then perform booking._err('amount_exceeds_refundable', 'Rivin hyvitys ylittää hyvitettävissä olevan'); end if;
      v_alloc_json := v_alloc_json || jsonb_build_object('payment_line_id', v_pl.id, 'amount', (l ->> 'amount')::numeric);
      v_sum := v_sum + (l ->> 'amount')::numeric;
    end loop;
    if abs(v_sum - p_amount) > 0.004 then perform booking._err('invalid_items', 'Rivien summa ei vastaa hyvityksen summaa'); end if;
  elsif v_full then
    select coalesce(jsonb_agg(jsonb_build_object('payment_line_id', id, 'amount', amount_gross - refunded_gross) order by id), '[]'::jsonb) into v_alloc_json
      from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross <> 0;
  else   -- suhteessa positiivisten rivien hyvitettävään osuuteen
    select coalesce(sum(amount_gross - refunded_gross), 0) into v_total_cap from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross > 0;
    if v_total_cap < p_amount - 0.004 then perform booking._err('invalid_items', 'Anna rivijako (p_lines)'); end if;
    v_left := p_amount; select count(*) into v_n from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross > 0;
    for r in select id, amount_gross - refunded_gross as cap from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross > 0 order by id loop
      v_i := v_i + 1;
      v_alloc := case when v_i = v_n then v_left else least(round(p_amount * r.cap / v_total_cap, 2), r.cap) end;
      v_alloc := least(v_alloc, r.cap, v_left);
      if v_alloc > 0 then v_alloc_json := v_alloc_json || jsonb_build_object('payment_line_id', r.id, 'amount', v_alloc); v_left := v_left - v_alloc; end if;
    end loop;
    if v_left > 0.004 then perform booking._err('invalid_items', 'Anna rivijako (p_lines)'); end if;
  end if;

  v_status := case when v_online and coalesce(v_mode, 'off') <> 'off' then 'requested' else 'done' end;
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, provider_status, lines, created_by, done_at)
  values (pay.id, pay.order_id, p_amount, btrim(p_reason), v_status, case when v_online and v_status = 'requested' then pay.provider else 'manual' end,
          case when v_online and v_status = 'done' then 'manual_done' end, v_alloc_json, auth.uid(), case when v_status = 'done' then now() end) returning id into v_id;
  if v_status = 'done' then
    update booking.payment_lines pl set refunded_gross = pl.refunded_gross + (x ->> 'amount')::numeric
      from jsonb_array_elements(v_alloc_json) x where pl.id = (x ->> 'payment_line_id')::bigint;
    update booking.payments set refunded_amount = refunded_amount + p_amount,
           status = case when refunded_amount + p_amount >= amount then 'refunded' else 'partially_refunded' end where id = pay.id;
    perform booking._sync_placeholder(pay.order_id);
    perform booking._refresh_order_payment(pay.order_id);
    perform booking._on_refund_done(v_id);
  end if;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'refunds', v_id::text, 'ADMIN_REFUND', null, jsonb_build_object('payment_id', pay.id, 'amount', p_amount, 'reason', p_reason, 'status', v_status));
  select id, receipt_no into rc from booking.receipts where refund_id = v_id;
  return jsonb_build_object('ok', true, 'refund_id', v_id, 'status', v_status, 'balance', booking._order_balance(pay.order_id), 'receipt_id', rc.id, 'receipt_no', rc.receipt_no);
end $$;

-- ===== 9. ALV =====
create function booking.admin_list_vat_rates() returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_staff();
  return jsonb_build_object(
    'rates', coalesce((select jsonb_agg(jsonb_build_object('rate', v.rate, 'label', v.label, 'active', v.active,
        'products', (select count(*) from kb.products p where p.vat_rate = v.rate), 'addons', (select count(*) from booking.addons a where a.vat_rate = v.rate)) order by v.sort_order, v.rate)
        from booking.vat_rates v), '[]'::jsonb),
    'missing', coalesce((select jsonb_agg(m) from (
        select jsonb_build_object('kind', 'product', 'id', p.id, 'name', p.name) m from kb.products p where p.vat_rate is null and p.active
        union all select jsonb_build_object('kind', 'addon', 'id', a.id, 'name', a.name) from booking.addons a where a.vat_rate is null) x), '[]'::jsonb));
end $$;

create function booking.admin_set_product_vat(p_product_id bigint, p_vat_rate numeric, p_note text default null) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_old numeric;
begin
  perform booking._require_permission('catalog.edit');
  select vat_rate into v_old from kb.products where id = p_product_id;
  if not found then perform booking._err('not_found', 'Tuotetta ei löydy'); end if;
  if p_vat_rate is null or not booking._vat_active(p_vat_rate) then perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu'); end if;
  perform booking.admin_update_product(p_product_id, jsonb_build_object('vat_rate', p_vat_rate));
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'kb.products', p_product_id::text, 'ADMIN_SET_VAT', jsonb_build_object('vat_rate', v_old), jsonb_build_object('vat_rate', p_vat_rate, 'note', p_note));
  return jsonb_build_object('ok', true, 'product_id', p_product_id, 'old', v_old, 'new', p_vat_rate, 'applies', 'new_rows_only');
end $$;

create function booking.admin_set_addon_vat(p_addon_id bigint, p_vat_rate numeric) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_old numeric;
begin
  perform booking._require_permission('catalog.edit');
  select vat_rate into v_old from booking.addons where id = p_addon_id;
  if not found then perform booking._err('not_found', 'Lisäpalvelua ei löydy'); end if;
  if p_vat_rate is null or not booking._vat_active(p_vat_rate) then perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu'); end if;
  perform booking.admin_update_addon(p_addon_id, jsonb_build_object('vat_rate', p_vat_rate));
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'addons', p_addon_id::text, 'ADMIN_SET_VAT', jsonb_build_object('vat_rate', v_old), jsonb_build_object('vat_rate', p_vat_rate));
  return jsonb_build_object('ok', true, 'addon_id', p_addon_id, 'old', v_old, 'new', p_vat_rate, 'applies', 'new_rows_only');
end $$;

create function booking.admin_upsert_vat_rate(p_rate numeric, p_label text, p_active boolean) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform booking._require_permission('settings.edit');
  if p_rate is null or p_rate < 0 or p_rate > 100 or p_rate <> round(p_rate, 2) then perform booking._err('invalid_vat', 'Virheellinen ALV-kanta'); end if;
  if p_label is null or char_length(btrim(p_label)) < 2 then perform booking._err('invalid_param', 'Anna nimi'); end if;
  insert into booking.vat_rates(rate, label, active, sort_order) values (p_rate, btrim(p_label), coalesce(p_active, true), 100)
  on conflict (rate) do update set label = excluded.label, active = excluded.active;
  return jsonb_build_object('ok', true, 'rate', p_rate);
end $$;

-- ===== 10. olemassa olevien funktioiden muutokset (ALV-validointi vat_rates:n kautta; below_paid) =====
CREATE OR REPLACE FUNCTION booking.admin_update_product(p_product_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  allowed text[] := array['name','name_en','description','description_en','price','price_text','vat_rate','active'];
  k text; o kb.products; n kb.products; v_price numeric; v_vat numeric;
begin
  perform booking._require_permission('catalog.edit');
  select * into o from kb.products where id = p_product_id;
  if not found then perform booking._err('not_found', 'Tuotetta ei löydy'); end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
  if p_patch ? 'name' and char_length(btrim(coalesce(p_patch ->> 'name', ''))) = 0 then perform booking._err('invalid_name', 'Nimi ei voi olla tyhjä'); end if;
  if p_patch ? 'price' then
    v_price := (p_patch ->> 'price')::numeric;
    if v_price is null or v_price < 0 or v_price > 100000 then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
  end if;
  if p_patch ? 'vat_rate' then
    v_vat := (p_patch ->> 'vat_rate')::numeric;
    if v_vat is null or not booking._vat_active(v_vat) then perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu (sallitut: ks. vat_rates)'); end if;
  end if;
  update kb.products set
    name           = case when p_patch ? 'name' then btrim(p_patch ->> 'name') else name end,
    name_en        = case when p_patch ? 'name_en' then nullif(btrim(p_patch ->> 'name_en'), '') else name_en end,
    description    = case when p_patch ? 'description' then nullif(p_patch ->> 'description', '') else description end,
    description_en = case when p_patch ? 'description_en' then nullif(p_patch ->> 'description_en', '') else description_en end,
    price          = case when p_patch ? 'price' then v_price else price end,
    price_text     = case when p_patch ? 'price_text' then nullif(p_patch ->> 'price_text', '') else price_text end,
    vat_rate       = case when p_patch ? 'vat_rate' then v_vat else vat_rate end,
    active         = case when p_patch ? 'active' then (p_patch ->> 'active')::boolean else active end,
    updated_at     = now()
   where id = p_product_id returning * into n;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'kb.products', p_product_id::text, 'ADMIN_UPDATE', to_jsonb(o), to_jsonb(n));
  insert into kb.change_log(table_name, row_id, action, actor, old_data, new_data)
  values ('products', p_product_id, 'update', 'booking-admin:' || coalesce(auth.uid()::text, 'unknown'), to_jsonb(o), to_jsonb(n));
  return jsonb_build_object('ok', true, 'id', n.id);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_update_addon(p_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  allowed text[] := array['name','name_en','description','description_en','price','vat_rate','max_per_person','applies_modes','active','sort_order'];
  k text; v_price numeric; v_vat numeric; v_max integer; v_modes text[];
begin
  perform booking._require_permission('catalog.edit');
  if not exists (select 1 from booking.addons where id = p_id) then perform booking._err('not_found', 'Lisäpalvelua ei löydy'); end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
  if p_patch ? 'name' and (char_length(btrim(coalesce(p_patch ->> 'name', ''))) = 0 or char_length(p_patch ->> 'name') > 200) then perform booking._err('invalid_name', 'Nimi ei voi olla tyhjä'); end if;
  if p_patch ? 'price' then
    if coalesce(p_patch ->> 'price', '') !~ '^\d{1,6}([.,]\d{1,2})?$' then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
    v_price := replace(p_patch ->> 'price', ',', '.')::numeric;
  end if;
  if p_patch ? 'vat_rate' then
    v_vat := case when coalesce(p_patch ->> 'vat_rate', '') ~ '^\d{1,2}([.,]\d)?$' then replace(p_patch ->> 'vat_rate', ',', '.')::numeric else -1 end;
    if not booking._vat_active(v_vat) then perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu (sallitut: ks. vat_rates)'); end if;
  end if;
  if p_patch ? 'max_per_person' and nullif(p_patch ->> 'max_per_person', '') is not null then
    if p_patch ->> 'max_per_person' !~ '^\d{1,2}$' or (p_patch ->> 'max_per_person')::int not between 1 and 20 then perform booking._err('invalid_max', 'Enimmäismäärä / henkilö: 1–20'); end if;
    v_max := (p_patch ->> 'max_per_person')::int;
  end if;
  if p_patch ? 'applies_modes' then
    if jsonb_typeof(p_patch -> 'applies_modes') <> 'array' then perform booking._err('invalid_modes', 'Vuorotyypit virheellisessä muodossa'); end if;
    select array_agg(distinct x) into v_modes from jsonb_array_elements_text(p_patch -> 'applies_modes') x;
    if v_modes is null or not (v_modes <@ array['shared','exclusive','resource']) then perform booking._err('invalid_modes', 'Vuorotyyppi: shared (yleinen), exclusive (yksityinen) ja/tai resource (hoito, saunotus)'); end if;
  end if;
  if p_patch ? 'sort_order' and coalesce(p_patch ->> 'sort_order', '') !~ '^\d{1,5}$' then perform booking._err('invalid_sort', 'Virheellinen järjestys'); end if;
  update booking.addons set
    name = case when p_patch ? 'name' then btrim(p_patch ->> 'name') else name end,
    name_en = case when p_patch ? 'name_en' then nullif(btrim(coalesce(p_patch ->> 'name_en', '')), '') else name_en end,
    description = case when p_patch ? 'description' then nullif(p_patch ->> 'description', '') else description end,
    description_en = case when p_patch ? 'description_en' then nullif(p_patch ->> 'description_en', '') else description_en end,
    price_gross = case when p_patch ? 'price' then v_price else price_gross end,
    vat_rate = case when p_patch ? 'vat_rate' then v_vat else vat_rate end,
    max_per_person = case when p_patch ? 'max_per_person' then v_max else max_per_person end,
    applies_modes = case when p_patch ? 'applies_modes' then v_modes else applies_modes end,
    active = case when p_patch ? 'active' then (p_patch ->> 'active')::boolean else active end,
    sort_order = case when p_patch ? 'sort_order' then (p_patch ->> 'sort_order')::int else sort_order end
   where id = p_id;
  return jsonb_build_object('ok', true, 'id', p_id);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_create_addon(p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  allowed text[] := array['code','name','name_en','description','description_en','price','vat_rate','max_per_person','applies_modes','active','sort_order'];
  k text; v_price numeric; v_vat numeric; v_max integer; v_modes text[]; v_id bigint; v_sort integer;
begin
  perform booking._require_permission('catalog.edit');
  if p_data is null or jsonb_typeof(p_data) <> 'object' then perform booking._err('invalid_addon', 'Anna lisäpalvelun tiedot'); end if;
  for k in select jsonb_object_keys(p_data) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa antaa: ' || k); end if;
  end loop;
  if coalesce(p_data ->> 'code', '') !~ '^[a-z][a-z0-9_]{1,40}$' then perform booking._err('invalid_code', 'Tunnus: pienet kirjaimet, numerot ja alaviiva (alkaa kirjaimella)'); end if;
  if exists (select 1 from booking.addons where code = p_data ->> 'code') then perform booking._err('code_exists', 'Tunnus on jo käytössä'); end if;
  if char_length(btrim(coalesce(p_data ->> 'name', ''))) = 0 or char_length(p_data ->> 'name') > 200 then perform booking._err('invalid_name', 'Anna nimi'); end if;
  if coalesce(p_data ->> 'price', '') !~ '^\d{1,6}([.,]\d{1,2})?$' then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
  v_price := replace(p_data ->> 'price', ',', '.')::numeric;
  v_vat := case when coalesce(p_data ->> 'vat_rate', '') ~ '^\d{1,2}([.,]\d)?$' then replace(p_data ->> 'vat_rate', ',', '.')::numeric when p_data ? 'vat_rate' then -1 else 25.5 end;
  if not booking._vat_active(v_vat) then perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu (sallitut: ks. vat_rates)'); end if;
  if p_data ? 'max_per_person' and nullif(p_data ->> 'max_per_person', '') is not null then
    if p_data ->> 'max_per_person' !~ '^\d{1,2}$' or (p_data ->> 'max_per_person')::int not between 1 and 20 then perform booking._err('invalid_max', 'Enimmäismäärä / henkilö: 1–20'); end if;
    v_max := (p_data ->> 'max_per_person')::int;
  end if;
  if p_data ? 'applies_modes' then
    if jsonb_typeof(p_data -> 'applies_modes') <> 'array' then perform booking._err('invalid_modes', 'Vuorotyypit virheellisessä muodossa'); end if;
    select array_agg(distinct x) into v_modes from jsonb_array_elements_text(p_data -> 'applies_modes') x;
    if v_modes is null or not (v_modes <@ array['shared','exclusive','resource']) then perform booking._err('invalid_modes', 'Vuorotyyppi: shared (yleinen), exclusive (yksityinen) ja/tai resource (hoito, saunotus)'); end if;
  end if;
  v_sort := case when coalesce(p_data ->> 'sort_order', '') ~ '^\d{1,5}$' then (p_data ->> 'sort_order')::int else 100 end;
  insert into booking.addons(code, name, name_en, description, description_en, price_gross, vat_rate, max_per_person, applies_modes, active, sort_order)
  values (p_data ->> 'code', btrim(p_data ->> 'name'), nullif(btrim(coalesce(p_data ->> 'name_en', '')), ''), nullif(p_data ->> 'description', ''),
          nullif(p_data ->> 'description_en', ''), v_price, v_vat, v_max, coalesce(v_modes, '{shared,exclusive}'),
          coalesce((p_data ->> 'active')::boolean, true), v_sort)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_set_reservation_addons(p_reservation_id bigint, p_addons jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare res booking.reservations; v_old jsonb; v_total numeric;
begin
  perform booking._require_permission('bookings.manage');
  select * into res from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  if res.status not in ('pending','confirmed') then perform booking._err('not_editable', 'Lisäpalveluita voi muuttaa vain voimassa olevaan varaukseen'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('addon_id', addon_id, 'name', product_name, 'quantity', quantity) order by id), '[]'::jsonb)
    into v_old from booking.order_items where parent_item_id = res.order_item_id and kind = 'addon';
  delete from booking.order_items where parent_item_id = res.order_item_id and kind = 'addon';
  update booking.orders set total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = res.order_id), 0) where id = res.order_id;
  perform booking._attach_addons(res.id, p_addons);
  select total_gross into v_total from booking.orders where id = res.order_id;
  if v_total < (select coalesce(sum(p.amount), 0) - coalesce(sum(p.refunded_amount), 0) from booking.payments p
                 where p.order_id = res.order_id and p.status in ('paid','partially_refunded','refunded')) then
    perform booking._err('below_paid', 'Tilauksen summa ei voi laskea alle maksetun summan (hyvitä ensin)');
  end if;
  perform booking._sync_placeholder(res.order_id);
  perform booking._refresh_order_payment(res.order_id);
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'order_items', res.order_id::text, 'ADMIN_SET_ADDONS', jsonb_build_object('addons', v_old),
          jsonb_build_object('addons', coalesce(p_addons, '[]'::jsonb), 'total', v_total));
  return jsonb_build_object('ok', true, 'total', v_total);
end $function$;

-- ===== 11. oikeudet =====
do $$ declare r record; begin
  for r in select p.oid::regprocedure as f, p.proname from pg_proc p where p.pronamespace = 'booking'::regnamespace
            and p.proname in ('_cash_rounding','_order_uncovered','_order_balance','_sync_placeholder','_enqueue_email','_alloc_payment_lines','_on_payment_paid','_on_refund_done',
                              'payments_paid_trg','_create_link_payment','_link_json','expire_payment_links','_add_to_order','_create_legs_booking','_create_booking_core','payment_prepare',
                              'admin_list_orders','admin_get_order','admin_list_payments','admin_add_to_order','admin_create_payment_link','admin_record_payment','admin_refund',
                              'admin_list_vat_rates','admin_set_product_vat','admin_set_addon_vat','admin_upsert_vat_rate','vat_guard_trg','receipts_guard_trg','_vat_active') loop
    execute format('revoke all on function %s from public, anon, authenticated', r.f);
    execute format('grant execute on function %s to service_role', r.f);
    if r.proname like 'admin\_%' or r.proname in ('_vat_active') then execute format('grant execute on function %s to authenticated', r.f); end if;
  end loop;
end $$;

-- ===== 12. cron: vanhentuneet maksulinkit =====
select cron.schedule('booking_expire_payment_links', '*/15 * * * *', 'select booking.expire_payment_links()');

-- ===== 13. täydennys: natiivit maksetut maksut ilman rivejä =====
do $$ declare r record; begin
  for r in select id from booking.payments where status in ('paid','partially_refunded') and external_source is null and not exists (select 1 from booking.payment_lines pl where pl.payment_id = payments.id) loop
    perform booking._alloc_payment_lines(r.id);
  end loop;
end $$;

