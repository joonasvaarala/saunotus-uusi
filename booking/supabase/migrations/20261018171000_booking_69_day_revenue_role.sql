-- ============================================================
-- booking_69_day_revenue_role: päivän tuotto vain admin- ja manager-rooleille
-- EI muuta booking_68-tiedostoa (se on jo tuotannossa). Korvaa admin_day_extras-funktion rungon
-- ja lisää booking.admin_day_revenue(p_date).
--
-- admin_day_extras: tapahtumat kaikille henkilökunnan rooleille (kuten vuorot).
--   revenue ja revenue_rows ovat JSON null, jos kutsuja ei ole admin tai manager.
-- admin_day_revenue: sama tuottolaskenta kuin booking_68. Muu henkilöstö (staff ja muut roolit) → forbidden.
--   Anonilla ei ole EXECUTE-oikeutta.
-- Ei taulumuutoksia. Rollback: rollbacks/20261018171000_booking_69_ROLLBACK.sql
-- Testi: tests/day/t69_day_revenue_role.sql
-- ============================================================
set local lock_timeout = '5s';

create or replace function booking.admin_day_revenue(p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $fn$
declare
  v_from timestamptz := p_date::timestamp at time zone 'Europe/Helsinki';
  v_to timestamptz := (p_date + 1)::timestamp at time zone 'Europe/Helsinki';
  v_rows jsonb;
  v_rev jsonb;
begin
  perform booking._require_staff();
  if booking.current_staff_role() not in ('admin', 'manager') then
    perform booking._err('forbidden', 'Päivän tuotto näkyy vain ylläpitäjälle');
  end if;
  if p_date is null then perform booking._err('invalid_date', 'Päivä puuttuu'); end if;
  with lines as (
    select r.id as reservation_id, r.starts_at, r.status, r.hold_expires_at, o.payment_status, o.created_at as order_created_at,
           coalesce(sum(i.line_total_gross), 0) as line_gross,
           coalesce(sum(i.line_vat), 0) as line_vat,
           coalesce(sum(i.line_net), 0) as line_net
      from booking.reservations r
      join booking.orders o on o.id = r.order_id
      left join booking.order_items i
        on r.order_item_id is not null
       and (i.id = r.order_item_id or i.parent_item_id = r.order_item_id)
     where r.hidden_at is null
       and r.starts_at >= v_from
       and r.starts_at < v_to
     group by r.id, r.starts_at, r.status, r.hold_expires_at, o.payment_status, o.created_at
  ),
  marked as (
    select lines.*,
           case when lines.status = 'pending' and lines.hold_expires_at is not null and lines.hold_expires_at > now() then 'pending'
                when lines.status = 'pending' then 'expired'
                else lines.status end as eff
      from lines
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'reservation_id', reservation_id, 'starts_at', starts_at, 'status', status, 'hold_expires_at', hold_expires_at,
           'line_gross', line_gross, 'line_vat', line_vat, 'line_net', line_net,
           'payment_status', payment_status, 'hidden', false, 'order_created_at', order_created_at
         ) order by starts_at, reservation_id), '[]'::jsonb),
         jsonb_build_object(
           'basis', 'visit_start', 'vat_basis', 'gross_incl_vat', 'currency', 'EUR',
           'gross', coalesce(sum(line_gross) filter (where eff in ('confirmed', 'completed')), 0),
           'vat', coalesce(sum(line_vat) filter (where eff in ('confirmed', 'completed')), 0),
           'net', coalesce(sum(line_net) filter (where eff in ('confirmed', 'completed')), 0),
           'count', count(*) filter (where eff in ('confirmed', 'completed')),
           'pending_gross', coalesce(sum(line_gross) filter (where eff = 'pending'), 0),
           'pending_count', count(*) filter (where eff = 'pending'),
           'unpaid_gross', coalesce(sum(line_gross) filter (where eff in ('confirmed', 'completed') and payment_status in ('unpaid', 'pending', 'failed')), 0),
           'unpaid_count', count(*) filter (where eff in ('confirmed', 'completed') and payment_status in ('unpaid', 'pending', 'failed')))
    into v_rows, v_rev
    from marked;

  return jsonb_build_object('date', p_date, 'tz', 'Europe/Helsinki', 'revenue', v_rev, 'revenue_rows', v_rows);
end $fn$;

revoke all on function booking.admin_day_revenue(date) from public, anon, authenticated;
grant execute on function booking.admin_day_revenue(date) to service_role, authenticated;

create or replace function booking.admin_day_extras(p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $fn$
declare
  v_from timestamptz := p_date::timestamp at time zone 'Europe/Helsinki';
  v_to timestamptz := (p_date + 1)::timestamp at time zone 'Europe/Helsinki';
  v_rows jsonb := 'null'::jsonb;
  v_rev jsonb := 'null'::jsonb;
  v_events jsonb;
  v_money jsonb;
begin
  perform booking._require_staff();
  if p_date is null then perform booking._err('invalid_date', 'Päivä puuttuu'); end if;
  if booking.current_staff_role() in ('admin', 'manager') then
    v_money := booking.admin_day_revenue(p_date);
    v_rev := v_money -> 'revenue';
    v_rows := v_money -> 'revenue_rows';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'event_id', e.id, 'product_id', e.product_id, 'name', p.name, 'name_en', p.name_en, 'category', p.category,
           'starts_on', e.starts_on, 'ends_on', e.ends_on, 'time_text', e.time_text, 'capacity_max', p.capacity_max, 'active', e.active,
           'persons', part.persons, 'participants', part.participants
         ) order by e.starts_on, e.id), '[]'::jsonb)
    into v_events
    from kb.event_dates e
    join kb.products p on p.id = e.product_id
    left join lateral (
      select coalesce(sum(r.persons), 0)::int as persons,
             coalesce(jsonb_agg(jsonb_build_object(
               'reservation_id', r.id, 'order_id', o.id, 'order_no', o.order_no, 'status', r.status, 'payment_status', o.payment_status,
               'product_id', r.product_id, 'product_name', coalesce(it.product_name, p.name), 'mode', r.mode,
               'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons,
               'total_gross', o.total_gross, 'customer_name', c.name, 'customer_email', c.email, 'customer_phone', c.phone,
               'source_channel', o.source_channel, 'created_at', o.created_at, 'hold_expires_at', r.hold_expires_at, 'notes', r.notes,
               'source', coalesce(r.external_source, 'native'), 'external_id', r.external_id,
               'customer_kind', o.customer_kind,
               'company', case when o.customer_kind <> 'private' then coalesce(o.billing ->> 'company', c.company) end,
               'space_code', sp.code, 'lifecycle', pcf.lifecycle,
               'option', booking._option_json(r.product_option_id),
               'option_missing', (r.product_option_id is null and exists (select 1 from booking.product_options x where x.product_id = r.product_id and x.active)),
               'legs', coalesce((select jsonb_agg(jsonb_build_object('leg_id', l.id, 'role', l.role, 'resource_code', lr.code, 'starts_at', l.starts_at, 'ends_at', l.ends_at, 'persons', l.persons, 'skill', l.skill) order by l.starts_at, l.id)
                                   from booking.reservation_legs l join booking.resources lr on lr.id = l.resource_id where l.reservation_id = r.id), '[]'::jsonb),
               'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', ai.addon_id, 'name', ai.product_name, 'quantity', ai.quantity) order by ai.id)
                                     from booking.order_items ai where ai.parent_item_id = r.order_item_id and ai.kind = 'addon'), '[]'::jsonb)
             ) order by r.starts_at, r.id), '[]'::jsonb) as participants
        from booking.reservations r
        join booking.orders o on o.id = r.order_id
        join booking.resources sp on sp.id = r.space_id
        left join booking.order_items it on it.id = r.order_item_id
        left join booking.product_config pcf on pcf.product_id = r.product_id
        left join booking.customers c on c.id = o.customer_id
       where r.product_id = e.product_id
         and r.hidden_at is null
         and r.starts_at < v_to and r.ends_at > v_from
         and (r.status in ('confirmed', 'completed') or (r.status = 'pending' and r.hold_expires_at > now()))
    ) part on true
   where e.active
     and e.starts_on <= p_date
     and coalesce(e.ends_on, e.starts_on) >= p_date;

  return jsonb_build_object('date', p_date, 'tz', 'Europe/Helsinki', 'revenue', v_rev, 'revenue_rows', v_rows, 'events', coalesce(v_events, '[]'::jsonb));
end $fn$;

comment on function booking.admin_day_revenue(date) is
  'Hallinta, vain luku: päivän tuotto (käynnin alkupäivä, brutto sis. ALV). Vain roolit admin ja manager. Ks. docs/paivanakyma-tuotto.md';
comment on function booking.admin_day_extras(date) is
  'Hallinta, vain luku: kb.event_dates-tapahtumat osallistujineen kaikille henkilökunnan rooleille. Tuottokentät vain admin ja manager (muille JSON null). Ks. docs/paivanakyma-tuotto.md';
