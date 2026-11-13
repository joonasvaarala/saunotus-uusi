-- ROLLBACK: booking_288 cancelled_order_close_payment_links.
-- Poistaa triggerin orders_cancel_close_links ja funktiot _orders_cancel_close_links_trg / _close_cancelled_order_links sekä palauttaa
-- admin_list_payment_link_watch- ja payment_link_reminders_sweep-funktioiden PRODin edeltävät määrittelyt sanatarkasti
-- (md5 c2b369e29b5e2f49ac4af804b5b74afd ja 663d8db811b784bd8784df586338e4fb = booking_288:n omat lähtövartijat).
-- Lähtöhashvartija: ajetaan vain, jos nykyiset määrittelyt ovat täsmälleen booking_288 (PROD/DEV, luettu 13.11.2026).
-- Ei koske dataan: backfillin ja triggerin jo sulkemat maksulinkit (payments.status) ja audit_log-rivit jäävät ennalleen.
do $pre$
declare v text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_list_payment_link_watch(text,text,integer,integer)')));
  if v is distinct from '0de62059e2da597f590100583119bda3' then raise exception 'rollback 288: admin_list_payment_link_watch md5 % ei ole booking_288-versio. Ei muutoksia.', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.payment_link_reminders_sweep(timestamptz)')));
  if v is distinct from 'c60b8c000bd812eda4d05a76fc1c2c5b' then raise exception 'rollback 288: payment_link_reminders_sweep md5 % ei ole booking_288-versio. Ei muutoksia.', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._close_cancelled_order_links(bigint,text)')));
  if v is distinct from '2a020d3b17c43244b7a14f656511ed9b' then raise exception 'rollback 288: _close_cancelled_order_links md5 % ei ole booking_288-versio. Ei muutoksia.', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._orders_cancel_close_links_trg()')));
  if v is distinct from '1f99b571cfd308bacdf084dff41ee251' then raise exception 'rollback 288: _orders_cancel_close_links_trg md5 % ei ole booking_288-versio. Ei muutoksia.', v; end if;
end $pre$;

drop trigger if exists orders_cancel_close_links on booking.orders;
drop function if exists booking._orders_cancel_close_links_trg();
drop function if exists booking._close_cancelled_order_links(bigint, text);

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
end $function$
;

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
end $function$
;

do $post$
begin
  if md5(pg_get_functiondef('booking.admin_list_payment_link_watch(text,text,integer,integer)'::regprocedure)) <> 'c2b369e29b5e2f49ac4af804b5b74afd'
     or md5(pg_get_functiondef('booking.payment_link_reminders_sweep(timestamptz)'::regprocedure)) <> '663d8db811b784bd8784df586338e4fb' then
    raise exception 'rollback 288: palautettu määrittely ei vastaa booking_288:aa edeltänyttä PROD-versiota';
  end if;
end $post$;

notify pgrst, 'reload schema';
