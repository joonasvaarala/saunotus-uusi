-- booking_288_cancelled_order_close_payment_links (Joonas t1663u 12.11.2026 19.43: "Varauksen perumisen pitää tietenkin poistaa tuo maksulinkki sekä poistaa se tuolta listasta")
-- Juurisyy: admin_cancel_reservation → admin_set_reservation_status ja svc_cancel_reservation asettavat orders.status='cancelled'
-- mutta jättävät avoimet (pending) maksulinkit voimaan (vain public_cancel_booking ja _cancel_unpaid_expired_orders sulkivat ne).
-- admin_list_payment_link_watch ja payment_link_reminders_sweep eivät katsoneet tilauksen tilaa → peruttu tilaus näkyi
-- "seurattavissa maksuissa" ja sai muistutusrivejä.
-- Muutos:
--  1) booking._close_cancelled_order_links(order_id, source): sulkee perutun tilauksen pending-maksut (ei lahjakorttia, ei kesken
--     olevaa MobilePay/Montonio-maksuyritystä), laskee payment_statusin (kaava = _refresh_order_payment, ilman varausvahvistuksia), audit.
--  2) AFTER UPDATE OF status -trigger booking.orders: status → 'cancelled' kutsuu 1):n → kaikki peruutuspolut kattaa.
--  3) admin_list_payment_link_watch + payment_link_reminders_sweep: o.status <> 'cancelled'.
--  4) Backfill: jo perutut tilaukset, joilla avoimia linkkejä.
-- Ei asiakasviestejä, ei hyvityksiä. Maksettuihin maksuihin ei kosketa. Myöhäinen maksu → booking_263-polku kuten ennen.

do $pre$
declare v text;
begin
  v := md5(pg_get_functiondef('booking.admin_list_payment_link_watch(text,text,integer,integer)'::regprocedure));
  if v not in ('c2b369e29b5e2f49ac4af804b5b74afd') then raise exception 'booking_288: admin_list_payment_link_watch md5 % ei vastaa', v; end if;
  v := md5(pg_get_functiondef('booking.payment_link_reminders_sweep(timestamptz)'::regprocedure));
  if v not in ('663d8db811b784bd8784df586338e4fb') then raise exception 'booking_288: payment_link_reminders_sweep md5 % ei vastaa', v; end if;
end $pre$;

create or replace function booking._close_cancelled_order_links(p_order bigint, p_source text default 'trigger')
 returns integer
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_ids bigint[]; v_total numeric; v_paid numeric; v_refunded numeric; v_pending int; v_inflight boolean;
begin
  if not exists (select 1 from booking.orders o where o.id = p_order and o.status = 'cancelled') then return 0; end if;
  v_inflight := booking._order_mp_inflight(p_order);
  with c as (
    update booking.payments p
       set status = 'cancelled',
           note = concat_ws(' | ', p.note, 'tilaus peruttu – maksulinkki suljettu'),
           raw = coalesce(case when jsonb_typeof(p.raw) = 'object' then p.raw end, '{}'::jsonb)
                 || jsonb_build_object('booking_288', jsonb_build_object('prev_status', p.status, 'at', now(), 'source', p_source))
     where p.order_id = p_order and p.status = 'pending'
       and p.method <> 'gift_card'
       and not (v_inflight and p.provider_ref is not null and p.provider in ('mobilepay', 'montonio'))
    returning p.id)
  select coalesce(array_agg(id order by id), '{}') into v_ids from c;
  if cardinality(v_ids) = 0 then return 0; end if;
  select o.total_gross into v_total from booking.orders o where o.id = p_order;
  select coalesce(sum(p.amount) filter (where p.status in ('paid','partially_refunded','refunded')), 0), coalesce(sum(p.refunded_amount), 0),
         count(*) filter (where p.status = 'pending')
    into v_paid, v_refunded, v_pending from booking.payments p where p.order_id = p_order;
  update booking.orders set payment_status = case
      when v_paid > 0 and v_refunded >= v_paid then 'refunded'
      when v_refunded > 0 then 'partially_refunded'
      when coalesce(v_total, 0) <= 0.004 then 'paid'
      when v_paid >= v_total and v_total > 0 then 'paid'
      when v_paid > 0 then 'partially_paid'
      when v_pending > 0 and exists (select 1 from booking.payments x where x.order_id = p_order and x.status = 'pending' and x.provider <> 'manual') then 'pending'
      else 'unpaid' end
   where id = p_order and payment_status is distinct from 'invoiced';
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (auth.uid(), coalesce(booking._jwt_role(), 'service_role'), 'orders', p_order::text, 'CANCELLED_ORDER_LINKS_CLOSED',
          jsonb_build_object('payment_ids', to_jsonb(v_ids), 'source', p_source));
  return cardinality(v_ids);
end $function$;
revoke all on function booking._close_cancelled_order_links(bigint, text) from public, anon, authenticated;

create or replace function booking._orders_cancel_close_links_trg()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  perform booking._close_cancelled_order_links(new.id, 'order_cancelled');
  return null;
end $function$;
revoke all on function booking._orders_cancel_close_links_trg() from public, anon, authenticated;

drop trigger if exists orders_cancel_close_links on booking.orders;
create trigger orders_cancel_close_links after update of status on booking.orders
  for each row when (new.status = 'cancelled' and old.status is distinct from 'cancelled')
  execute function booking._orders_cancel_close_links_trg();

CREATE OR REPLACE FUNCTION booking.admin_list_payment_link_watch(p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_s text := nullif(btrim(coalesce(p_search, '')), '');
  v_num bigint; v_like text; v_lim integer := coalesce(p_limit, 50); v_off integer := greatest(coalesce(p_offset, 0), 0);
  v_total integer; v_rows jsonb; v_now timestamptz := now();
begin
  perform booking._require_permission('payments.manage');
  if p_status is not null and p_status not in ('watching', 'paused', 'needs_action') then
    perform booking._err('invalid_param', 'Tuntematon tila');
  end if;
  if v_lim < 1 or v_lim > 200 then perform booking._err('invalid_param', 'p_limit 1–200'); end if;
  if v_s ~ '^\d{1,12}$' then v_num := v_s::bigint; end if;
  if v_s is not null then v_like := '%' || replace(replace(replace(v_s, '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;
  with base as (
    select p.id, p.order_id, o.order_no, p.amount, c.name as customer_name, p.created_at, p.link_expires_at, p.raw,
           p.reminders_paused_at, p.reminders_needs_action,
           booking._plr_link_kind(p.created_at, p.link_expires_at, p.raw) as link_kind,
           booking._plr_plan(p.id, p.created_at, p.link_expires_at, p.raw, v_now) as plan
      from booking.payments p
      join booking.orders o on o.id = p.order_id
      left join booking.customers c on c.id = o.customer_id
     where p.status = 'pending'
       and p.provider <> 'manual'
       and p.external_source is null
       and o.external_source is null
       and o.status <> 'cancelled'   -- booking_288: peruttu tilaus ei kuulu seurattaviin maksuihin
       and p.reminders_handled_at is null
       and booking._plr_link_kind(p.created_at, p.link_expires_at, p.raw) is not null
       and (p.link_expires_at is null or p.link_expires_at > v_now)
       and (v_s is null or (v_num is not null and (o.order_no = v_num or p.id = v_num))
            or (v_like is not null and (c.name ilike v_like escape '\' or c.email ilike v_like escape '\')))
  ), marked as (
    select b.*,
           case when b.reminders_needs_action or coalesce((b.plan ->> 'needs_action')::boolean, false) then 'needs_action'
                when b.reminders_paused_at is not null then 'paused'
                else 'watching' end as watch_status,
           case when b.reminders_paused_at is not null or coalesce((b.plan ->> 'needs_action')::boolean, false) or b.reminders_needs_action
                  or (b.plan #>> '{next,due_at}') is null then null
                else booking._plr_next_open(greatest((b.plan #>> '{next,due_at}')::timestamptz, v_now)) end as next_at
      from base b
  ), filtered as (
    select * from marked where p_status is null or watch_status = p_status
  ), page as (
    select f.*, row_number() over (order by (f.watch_status = 'needs_action') desc, f.created_at asc, f.id asc) as rn
      from filtered f
  )
  select (select count(*) from filtered),
         coalesce(jsonb_agg(jsonb_build_object(
           'payment_id', p.id, 'order_id', p.order_id, 'order_no', p.order_no, 'amount', p.amount,
           'customer_name', p.customer_name, 'created_at', p.created_at, 'link_expires_at', p.link_expires_at,
           'link_kind', p.link_kind, 'status', p.watch_status, 'paused_at', p.reminders_paused_at,
           'needs_action', p.watch_status = 'needs_action', 'next_reminder_at', p.next_at,
           'reservation', (
             select jsonb_build_object('product_name', coalesce(it.product_name, ''), 'starts_at', r.starts_at,
                      'count', (select count(*) from booking.reservations r2 where r2.order_id = p.order_id and r2.status <> 'cancelled'))
               from booking.reservations r
               left join booking.order_items it on it.id = r.order_item_id
              where r.order_id = p.order_id and r.status <> 'cancelled'
              order by r.starts_at nulls last, r.id limit 1),
           'reminders', coalesce((
             select jsonb_agg(jsonb_build_object('no', x.reminder_no, 'at', x.sent_at, 'kind', x.kind) order by x.reminder_no)
               from booking.payment_link_reminders x where x.payment_id = p.id and x.emailed), '[]'::jsonb),
           'reminder_count', (select count(*) from booking.payment_link_reminders x where x.payment_id = p.id and x.emailed),
           'last_reminder_at', (select max(x.sent_at) from booking.payment_link_reminders x where x.payment_id = p.id and x.emailed)
         ) order by p.rn), '[]'::jsonb)
    into v_total, v_rows
    from page p where p.rn > v_off and p.rn <= v_off + v_lim;
  return jsonb_build_object('total', coalesce(v_total, 0), 'rows', coalesce(v_rows, '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION booking.payment_link_reminders_sweep(p_now timestamp with time zone DEFAULT now())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_now timestamptz := coalesce(p_now, now());
  n integer := 0;
  r record;
  v_plan jsonb;
  v_next jsonb;
begin
  if not booking._plr_enabled() then return 0; end if;
  if not booking._plr_in_window(v_now) then return 0; end if;
  for r in
    select p.id, p.order_id, p.created_at, p.link_expires_at, p.raw, p.reminders_needs_action
      from booking.payments p
      join booking.orders o on o.id = p.order_id
     where p.status = 'pending'
       and p.provider <> 'manual'
       and p.external_source is null
       and o.external_source is null
       and o.status <> 'cancelled'   -- booking_288: peruttu tilaus ei kuulu muistutuksiin
       and p.reminders_handled_at is null
       and p.reminders_paused_at is null
       and booking._plr_link_kind(p.created_at, p.link_expires_at, p.raw) is not null
       and (p.link_expires_at is null or p.link_expires_at > v_now)
     order by p.id
     for update of p skip locked
  loop
    v_plan := booking._plr_plan(r.id, r.created_at, r.link_expires_at, r.raw, v_now);
    if coalesce((v_plan ->> 'needs_action')::boolean, false) and not r.reminders_needs_action then
      update booking.payments set reminders_needs_action = true where id = r.id;
    end if;
    if jsonb_typeof(v_plan -> 'skip') = 'array' then
      insert into booking.payment_link_reminders(payment_id, reminder_no, kind, emailed, sent_at)
      select r.id, x::integer, 'skipped', false, v_now
        from jsonb_array_elements_text(v_plan -> 'skip') x
      on conflict (payment_id, reminder_no) do nothing;
    end if;
    v_next := v_plan -> 'next';
    if v_next is null or jsonb_typeof(v_next) = 'null' then continue; end if;
    if not coalesce((v_plan ->> 'due')::boolean, false) then continue; end if;
    if booking._plr_enqueue(r.id, r.order_id, (v_next ->> 'no')::integer, v_next ->> 'kind',
                            (v_next ->> 'due_at')::timestamptz, (v_next ->> 'cancel')::boolean, v_now) then
      n := n + 1;
    end if;
  end loop;
  return n;
end $function$;

-- Backfill: jo perutut tilaukset
do $bf$
declare r record; n int := 0;
begin
  for r in select distinct p.order_id from booking.payments p join booking.orders o on o.id = p.order_id
            where o.status = 'cancelled' and p.status = 'pending' and p.method <> 'gift_card' order by 1 loop
    n := n + booking._close_cancelled_order_links(r.order_id, 'booking_288_backfill');
  end loop;
  raise notice 'booking_288 backfill: % maksua suljettu', n;
end $bf$;
