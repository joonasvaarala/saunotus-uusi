-- APPLIED 2026-10-16 (Europe/Helsinki ~23:25): version 20261016202540 (booking_12_johku_marker) via apply_migration; sama SQL kuin tässä tiedostossa.
-- booking_12_johku_marker
-- Joonas hyväksyi ajon chatissa 16.10.2026. Vain: Johku-merkintä (PLAN.md §4, §7.3; DESIGN_resources_v2.md).
-- Sisältö:
--  1. orders.external_meta jsonb, reservations.external_meta jsonb (NULLable; maksutieto/malli tiedoksi, sisältö PLAN §2.2).
--  2. Indeksi reservations_source_idx ((coalesce(external_source,'native')), starts_at) lähdesuodattimelle.
--     (UNIQUE (external_source, external_id) -indeksit orders_external_uq / reservations_external_uq ovat jo olemassa -> ei uutta.)
--  3. admin_day_view (RETURNS jsonb, allekirjoitus ennallaan -> CREATE OR REPLACE, grants säilyvät): jokaiseen reservations-objektiin
--     'source' ('johku' | 'native') ja 'external_id'.
--  4. admin_list_reservations: uusi p_source text default null (null = kaikki; 'johku' | 'native'); RETURNS TABLE saa kaksi uutta
--     saraketta LOPPUUN (source text, external_id text) -> DROP + CREATE. Grants täsmälleen kuten ennen: authenticated + service_role
--     (+ postgres omistajana); EI anon / PUBLIC (revoke, koska oletusoikeudet antaisivat anonille).
-- Ei muutoksia RLS-politiikkoihin tai tauluoikeuksiin. Nykyinen toiminta säilyy: kaikki vanhat sarakkeet samassa järjestyksessä,
-- vanhat kutsut (nimetyt argumentit) toimivat sellaisenaan.
-- Frontend (Koodari): lue uusi kenttä `source` (+`external_id`) listasta ja päivänäkymän reservations-objekteista; p_source: 'johku' | 'native'.
-- Huom: PLAN §7.3 mainitsi myös external_synced_at; jätetty pois (synkkasaraketta ei vielä ole) -> lisättävä myöhemmin DROP+CREATE:lla.

alter table booking.orders add column if not exists external_meta jsonb;
alter table booking.reservations add column if not exists external_meta jsonb;

create index if not exists reservations_source_idx on booking.reservations ((coalesce(external_source, 'native')), starts_at);

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
        'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', ai.addon_id, 'name', ai.product_name, 'quantity', ai.quantity) order by ai.id)
                              from booking.order_items ai where ai.parent_item_id = r.order_item_id and ai.kind = 'addon'), '[]'::jsonb))
        order by r.starts_at, r.id)
        from booking.reservations r join booking.orders o on o.id = r.order_id
        left join booking.order_items it on it.id = r.order_item_id left join kb.products p on p.id = r.product_id
        left join booking.customers c on c.id = o.customer_id
        where r.starts_at < v_to and r.ends_at > v_from and booking._res_active(r.status, r.hold_expires_at)), '[]'::jsonb),
    'prep', v_prep, 'addon_totals', v_totals,
    'blocks', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'space_id', b.space_id, 'starts_at', b.starts_at,
        'ends_at', b.ends_at, 'reason', b.reason) order by b.starts_at)
        from booking.space_blocks b where b.active and b.starts_at < v_to and b.ends_at > v_from), '[]'::jsonb));
end $function$
;

drop function if exists booking.admin_list_reservations(timestamp with time zone, timestamp with time zone, text, text, bigint, integer, integer);

CREATE FUNCTION booking.admin_list_reservations(p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_product_id bigint DEFAULT NULL::bigint, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_source text DEFAULT NULL::text)
 RETURNS TABLE(reservation_id bigint, order_id bigint, order_no bigint, status text, order_status text, payment_status text, product_id bigint, product_name text, mode text, starts_at timestamp with time zone, ends_at timestamp with time zone, persons integer, total_gross numeric, customer_id bigint, customer_name text, customer_email text, customer_phone text, source_channel text, created_at timestamp with time zone, hold_expires_at timestamp with time zone, notes text, annual_card_id bigint, total_count bigint, source text, external_id text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform booking._require_staff();
  return query
    select r.id, o.id, o.order_no,
           case when r.status = 'pending' and r.hold_expires_at <= now() then 'expired' else r.status end,
           o.status, o.payment_status, r.product_id, coalesce(it.product_name, p.name), r.mode, r.starts_at, r.ends_at, r.persons,
           o.total_gross, c.id, c.name, c.email, c.phone, o.source_channel, o.created_at, r.hold_expires_at, r.notes, r.annual_card_id,
           count(*) over (), coalesce(r.external_source, 'native'), r.external_id
      from booking.reservations r
      join booking.orders o on o.id = r.order_id
      left join booking.order_items it on it.id = r.order_item_id
      left join kb.products p on p.id = r.product_id
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
end $function$
;

revoke all on function booking.admin_list_reservations(timestamp with time zone, timestamp with time zone, text, text, bigint, integer, integer, text) from public, anon;
grant execute on function booking.admin_list_reservations(timestamp with time zone, timestamp with time zone, text, text, bigint, integer, integer, text) to authenticated, service_role;
