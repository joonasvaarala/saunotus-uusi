-- booking_190: asiakkaan myöhempi lisäys (hoito tai lisäpalvelu) on sama 15 min pito kuin kassan checkout,
-- ja maksamattoman kassapidon vanheneminen lähettää yhden sähköpostin.
--
-- A) Lisäys vahvistettuun tilaukseen (tilaussivu public_add_to_order / vahvistussivu public_upsell_add
--    ja public_upsell_checkout_attach, kun tilaus on jo confirmed). Henkilökunnan lisäys ei saa pitoa.
--    GUC booking.addition_hold_minutes = booking._checkout_hold_minutes() (asetus checkout_hold_minutes, oletus 15).
--    BEFORE INSERT merkitsee uuden varauksen pending + hold_expires_at ja tilausrivin hold_expires_at.
--    booking.expire_holds / _expire_holds vapauttaa vanhentuneen rivin: varaus cancelled (cancel_reason hold_expired),
--    maksamaton rivi poistuu, avoin maksulinkki pienenee tai perutaan. Alkuperäinen vahvistettu tilaus säilyy.
--    Kesken oleva verkkomaksu (_order_mp_inflight) suojaa samaan tapaan kuin kassapito, ja _checkout_extend_hold
--    jatkaa lisäyksen pitoa maksun alkaessa. Maksettu lisäys vahvistetaan (_item_paid) eikä vanhene.
--    Asiakas vapauttaa heti: public_cancel_addition(token, item_id) ('Peru lisätilaus').
--
-- B) Kun koko tilaus perutaan, koska maksua ei saatu valmiiksi (hold_expired), jonotetaan yksi viesti
--    unpaid_booking_cancelled (dedupe unpaid_booking_cancelled:<order_id>). Vain kelvollinen sähköposti
--    (_enqueue_email), ei Johku-historiaa (external_source), ei henkilökunnan tilausta (source_channel <> web),
--    ei laskutilausta (invoice_method einvoice/pdf, payment_status invoiced, laskurivi tai laskulukko).
--    Linkki Yritä uudelleen / Try again = saman tuotteen varaussivu (site_base_url + /varaa/ tai /en/book/ + #/tuote/<slug>).
--    Lähetys seuraa booking.integration_config.resend.modea kuten muut viestit: off → skipped, dry_run → pending
--    ja send-emails merkitsee dry_run, live → pending ja send-emails lähettää. Tuotannossa 28.10.2026 mode = live,
--    ei test_recipients-rajausta. Tätä migraatiota ei ajeta tästä työtilasta.
--
-- Ei hintamuutoksia. Ei maksuvälittäjän nimeä viestissä.
-- Rollback: ei erillistä tiedostoa; palauta edelliset funktiot ja pudota sarake vain tyhjänä.
set local lock_timeout = '5s';

alter table booking.order_items add column if not exists hold_expires_at timestamptz;
comment on column booking.order_items.hold_expires_at is
  'booking_190: asiakkaan maksamattoman lisäyksen pito. null = ei pitoa (alkuperäinen rivi, henkilökunnan lisäys tai jo maksettu).';
create index if not exists order_items_addition_hold_idx
  on booking.order_items (hold_expires_at)
  where hold_expires_at is not null;

alter table booking.email_outbox drop constraint if exists email_outbox_kind_check;
alter table booking.email_outbox add constraint email_outbox_kind_check
  check (kind in ('order_confirmation', 'payment_link', 'receipt', 'refund_receipt', 'cancel_request_ack', 'order_change', 'gift_card_buyer', 'gift_card_recipient', 'voucher_claim_received', 'voucher_claim_problem', 'business_quote_ack', 'business_quote_notify', 'invoice_pdf', 'product_message', 'waitlist_spot_freed', 'annual_card_code', 'staff_shift_notice', 'unpaid_booking_cancelled'));

create or replace function booking._item_paid(p_item bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select i.line_total_gross from booking.order_items i where i.id = p_item), 0) <= 0.004
      or coalesce((
           select sum(pl.amount_gross - coalesce(pl.refunded_gross, 0))
             from booking.payment_lines pl
             join booking.payments p on p.id = pl.payment_id
            where pl.order_item_id = p_item
              and p.status in ('paid', 'partially_refunded', 'refunded')
         ), 0) + 0.004 >= coalesce((select i.line_total_gross from booking.order_items i where i.id = p_item), 0);
$$;

-- Vain kun _add_to_order / _upsell_attach_reservation on asettanut pidon (vahvistettu tilaus, asiakas).
create or replace function booking._addition_hold_item_bi() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_min int := coalesce(nullif(current_setting('booking.addition_hold_minutes', true), '')::int, 0);
begin
  if v_min > 0 and new.hold_expires_at is null and new.kind in ('addon', 'reservation') then
    new.hold_expires_at := now() + make_interval(mins => v_min);
  end if;
  return new;
end $$;

create or replace function booking._addition_hold_res_bi() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_min int := coalesce(nullif(current_setting('booking.addition_hold_minutes', true), '')::int, 0);
begin
  if v_min > 0 and new.status = 'confirmed' then
    new.status := 'pending';
    new.hold_expires_at := now() + make_interval(mins => v_min);
  end if;
  return new;
end $$;

-- Maksettu lisäys saa vahvistua. Maksamaton lisäpito pysyy pendinginä, vaikka payment_mark_paid vahvistaisi muut varaukset.
create or replace function booking._addition_hold_confirm_bu() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.status = 'confirmed' and old.status is distinct from 'confirmed'
     and exists (select 1 from booking.order_items i where i.id = new.order_item_id and i.hold_expires_at is not null) then
    if not booking._item_paid(new.order_item_id) then
      new.status := old.status;
      new.hold_expires_at := old.hold_expires_at;
      return new;
    end if;
    update booking.order_items set hold_expires_at = null where id = new.order_item_id and hold_expires_at is not null;
  end if;
  return new;
end $$;

drop trigger if exists a_addition_hold_item on booking.order_items;
create trigger a_addition_hold_item before insert on booking.order_items
  for each row execute function booking._addition_hold_item_bi();
drop trigger if exists a_addition_hold_res on booking.reservations;
create trigger a_addition_hold_res before insert on booking.reservations
  for each row execute function booking._addition_hold_res_bi();
drop trigger if exists a_addition_hold_confirm on booking.reservations;
create trigger a_addition_hold_confirm before update on booking.reservations
  for each row execute function booking._addition_hold_confirm_bu();

create or replace function booking._pending_additions_json(p_order bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'item_id', i.id,
           'kind', i.kind,
           'name', i.product_name,
           'name_en', coalesce(i.price_breakdown ->> 'name_en', kp.name_en),
           'quantity', i.quantity,
           'line_total', i.line_total_gross,
           'reservation_id', r.id,
           'hold_expires_at', i.hold_expires_at,
           'seconds_left', greatest(floor(extract(epoch from (i.hold_expires_at - now())))::int, 0),
           'expired', i.hold_expires_at <= now()
         ) order by i.id), '[]'::jsonb)
    from booking.order_items i
    left join booking.reservations r on r.order_item_id = i.id and r.order_id = i.order_id and r.hidden_at is null
    left join kb.products kp on kp.id = i.product_id
   where i.order_id = p_order
     and i.hold_expires_at is not null
     and not booking._item_paid(i.id);
$$;

create or replace function booking._release_unpaid_additions(p_order bigint default null, p_item bigint default null, p_reason text default 'hold_expired')
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_order bigint;
  v_ids bigint[];
  v_pays bigint[];
  v_reason text := case when p_reason = 'customer_cancelled' then 'customer_cancelled' else 'hold_expired' end;
  v_maxwait int := booking._checkout_cfg_int('checkout_mobilepay_max_wait_minutes', 30, 0, 120);
  n int := 0;
  v_n int;
begin
  for v_order in
    select distinct i.order_id
      from booking.order_items i
      join booking.orders o on o.id = i.order_id
     where i.hold_expires_at is not null
       and (p_order is null or i.order_id = p_order)
       and (p_item is null or i.id = p_item)
       and o.status in ('confirmed', 'completed')
       and o.external_source is null
       and not booking._order_invoice_locked(o.id)
     order by i.order_id
     for update of o
  loop
    select coalesce(array_agg(i.id order by i.id), '{}') into v_ids
      from booking.order_items i
     where i.order_id = v_order
       and i.hold_expires_at is not null
       and not booking._item_paid(i.id)
       and (p_item is null or i.id = p_item)
       and (p_item is not null or i.hold_expires_at <= now())
       and (p_item is not null or not (booking._order_mp_inflight(v_order) and i.hold_expires_at > now() - make_interval(mins => v_maxwait)))
       and not exists (
         select 1 from booking.order_items c
          where c.parent_item_id = i.id and booking._item_paid(c.id));
    if cardinality(v_ids) > 0 then
      select coalesce(array_agg(distinct x), '{}') into v_ids from (
        select unnest(v_ids) x
        union
        select c.order_item_id
          from booking.reservations c
          join booking.reservations parent on parent.id = c.parent_reservation_id
          join booking.order_items ci on ci.id = c.order_item_id
         where parent.order_item_id = any (v_ids)
           and ci.hold_expires_at is not null
           and not booking._item_paid(ci.id)
           and not exists (select 1 from booking.order_items ch where ch.parent_item_id = ci.id and booking._item_paid(ch.id))
      ) s;
    end if;
    continue when v_ids is null or cardinality(v_ids) = 0;

    update booking.reservations r
       set status = 'cancelled',
           cancelled_at = coalesce(r.cancelled_at, now()),
           cancel_reason = coalesce(r.cancel_reason, v_reason)
     where r.order_id = v_order
       and r.status in ('pending', 'expired')
       and (r.order_item_id = any (v_ids)
            or r.parent_reservation_id in (select p.id from booking.reservations p where p.order_item_id = any (v_ids)));

    select coalesce(array_agg(distinct p.id), '{}') into v_pays
      from booking.payments p
      join booking.payment_lines pl on pl.payment_id = p.id
     where p.order_id = v_order and p.status = 'pending' and pl.order_item_id = any (v_ids);

    delete from booking.payment_lines pl
     using booking.payments p
     where pl.payment_id = p.id and p.id = any (v_pays) and pl.order_item_id = any (v_ids);

    update booking.payments p
       set amount = coalesce((select sum(pl.amount_gross) from booking.payment_lines pl where pl.payment_id = p.id), 0)
     where p.id = any (v_pays) and p.status = 'pending';

    update booking.payments p
       set status = 'cancelled',
           note = concat_ws(' | ', p.note, 'lisäyksen pito vapautettu')
     where p.id = any (v_pays) and p.status = 'pending'
       and not exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id);

    delete from booking.order_items i
     where i.id = any (v_ids) and i.parent_item_id is not null and not booking._item_paid(i.id);
    delete from booking.order_items i
     where i.id = any (v_ids)
       and not booking._item_paid(i.id)
       and not exists (select 1 from booking.order_items c where c.parent_item_id = i.id);

    update booking.orders o
       set total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = o.id), 0)
     where o.id = v_order;
    perform booking._sync_placeholder(v_order);
    perform booking._refresh_order_payment(v_order);
    get diagnostics v_n = row_count;
    n := n + cardinality(v_ids);
  end loop;
  return n;
end $$;

create or replace function booking._enqueue_unpaid_booking_email(p_order bigint) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  o booking.orders;
  v_slug text; v_name text; v_name_en text; v_start timestamptz; v_base text; v_url text;
begin
  select * into o from booking.orders where id = p_order;
  if not found or o.status <> 'cancelled' then return false; end if;
  if o.external_source is not null then return false; end if;                 -- ei Johku-historiaa
  if o.source_channel is distinct from 'web' then return false; end if;       -- ei henkilökunnan tekemää
  if o.payment_status = 'invoiced' then return false; end if;
  if coalesce(o.billing ->> 'invoice_method', '') in ('einvoice', 'pdf') then return false; end if;
  if booking._order_invoice_locked(o.id) then return false; end if;
  if exists (select 1 from booking.invoices i where i.order_id = o.id and i.kind = 'debit') then return false; end if;
  if not exists (select 1 from booking.reservations r where r.order_id = o.id and r.cancel_reason = 'hold_expired') then return false; end if;
  if exists (select 1 from booking.reservations r where r.order_id = o.id and r.status in ('pending', 'confirmed', 'completed')) then return false; end if;
  select p.slug, p.name, p.name_en, r.starts_at
    into v_slug, v_name, v_name_en, v_start
    from booking.reservations r
    join kb.products p on p.id = r.product_id
   where r.order_id = o.id
   order by r.starts_at nulls last, r.id
   limit 1;
  v_base := rtrim(coalesce(booking._setting('site_base_url', '""'::jsonb) #>> '{}', ''), '/');
  v_url := v_base
        || case when o.locale = 'en' then '/en/book/' else '/varaa/' end
        || case when v_slug ~ '^[a-z0-9][a-z0-9-]{0,80}$' then '#/tuote/' || v_slug else '' end;
  return booking._enqueue_email(
    'unpaid_booking_cancelled', o.id, null, null,
    'unpaid_booking_cancelled:' || o.id::text,
    jsonb_strip_nulls(jsonb_build_object(
      'retry_url', nullif(v_url, ''),
      'product_name', v_name,
      'product_name_en', v_name_en,
      'starts_at', v_start)));
exception when others then
  -- viesti ei saa estää pidon vapautusta
  return false;
end $$;

create or replace function booking._expire_holds(p_space bigint default null, p_except bigint default null) returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer := 0; v_res_orders bigint[] := '{}'; v_orders bigint[] := '{}';
        v_maxwait int := booking._checkout_cfg_int('checkout_mobilepay_max_wait_minutes', 30, 0, 120);
        v_id bigint;
begin
  with e as (
    update booking.reservations r
       set status = 'cancelled', cancelled_at = coalesce(r.cancelled_at, now()), cancel_reason = coalesce(r.cancel_reason, 'hold_expired')
     where r.status = 'pending' and r.hold_expires_at <= now()
       and (p_space is null or r.space_id = p_space)
       and r.id is distinct from p_except
       and not (booking._order_mp_inflight(r.order_id) and r.hold_expires_at > now() - make_interval(mins => v_maxwait))
    returning r.order_id
  )
  select count(*), coalesce(array_agg(distinct order_id), '{}') into n, v_res_orders from e;
  if n > 0 then
    with o as (
      update booking.orders o set status = 'cancelled', cancelled_at = coalesce(o.cancelled_at, now())
       where o.id = any (v_res_orders) and o.status = 'pending' and o.payment_status in ('unpaid', 'pending', 'partially_paid')
         and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status in ('pending', 'confirmed'))
         and not exists (select 1 from booking.payments p where p.order_id = o.id and p.status in ('paid', 'partially_refunded', 'refunded')
                            and not (p.method = 'gift_card' and not exists (select 1 from booking.receipts rc where rc.payment_id = p.id)))
      returning o.id
    )
    select coalesce(array_agg(id), '{}') into v_orders from o;
    if cardinality(v_orders) > 0 then
      update booking.payments set status = 'cancelled' where order_id = any (v_orders) and status = 'pending';
      perform booking._checkout_release_gift_cards(v_orders);
      foreach v_id in array v_orders loop
        perform booking._enqueue_unpaid_booking_email(v_id);
      end loop;
    end if;
  end if;
  -- lisäykset vahvistetussa tilauksessa: kapasiteetti ja rivi pois, tilausta ei peruta eikä viestiä lähde
  perform booking._release_unpaid_additions(null, null, 'hold_expired');
  return n;
end $$;

create or replace function booking._checkout_extend_hold(p_order bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare o booking.orders; v_to timestamptz; v_grace int; v_max int;
begin
  select * into o from booking.orders where id = p_order;
  if not found then return; end if;
  v_grace := booking._checkout_cfg_int('checkout_mobilepay_grace_minutes', 15, 0, 60);
  v_max := booking._checkout_cfg_int('checkout_mobilepay_max_wait_minutes', 30, 0, 120);
  if o.status = 'pending' and o.hold_kind is not distinct from 'checkout' then
    v_to := least(now() + make_interval(mins => v_grace),
                  o.created_at + make_interval(mins => booking._checkout_hold_minutes() + v_max));
    update booking.reservations set hold_expires_at = v_to where order_id = p_order and status = 'pending' and hold_expires_at < v_to;
    return;
  end if;
  -- booking_190: vahvistetun tilauksen maksamaton lisäys saa saman jatkon, kun verkkomaksu alkaa
  if o.status = 'confirmed' then
    v_to := now() + make_interval(mins => v_grace);
    update booking.order_items i
       set hold_expires_at = v_to
     where i.order_id = p_order and i.hold_expires_at is not null and i.hold_expires_at < v_to
       and i.hold_expires_at > now() - make_interval(mins => v_max);
    update booking.reservations r
       set hold_expires_at = i.hold_expires_at
      from booking.order_items i
     where r.order_item_id = i.id and r.order_id = p_order and r.status = 'pending'
       and i.hold_expires_at is not null
       and (r.hold_expires_at is null or r.hold_expires_at < i.hold_expires_at);
  end if;
end $$;

create or replace function booking._refresh_order_payment(p_order_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare v_total numeric; v_paid numeric; v_refunded numeric; v_pending int;
begin
  select total_gross into v_total from booking.orders where id = p_order_id;
  select coalesce(sum(amount) filter (where status in ('paid','partially_refunded','refunded')), 0),
         coalesce(sum(refunded_amount), 0),
         count(*) filter (where status = 'pending')
    into v_paid, v_refunded, v_pending from booking.payments where order_id = p_order_id;
  update booking.orders set payment_status = case
      when v_paid > 0 and v_refunded >= v_paid then 'refunded'
      when v_refunded > 0 then 'partially_refunded'
      when v_paid >= v_total and v_total > 0 then 'paid'
      when v_paid > 0 then 'partially_paid'
      when v_pending > 0 and exists (select 1 from booking.payments where order_id = p_order_id and status = 'pending' and provider <> 'manual') then 'pending'
      else 'unpaid' end
   where id = p_order_id;
  -- booking_190: maksettu lisäpito vahvistuu; trigger pudottaa hold_expires_at
  update booking.reservations r
     set status = 'confirmed', hold_expires_at = null
    from booking.order_items i
   where i.id = r.order_item_id and i.order_id = p_order_id and r.order_id = p_order_id
     and r.status = 'pending' and i.hold_expires_at is not null and booking._item_paid(i.id);
  update booking.order_items i
     set hold_expires_at = null
   where i.order_id = p_order_id and i.hold_expires_at is not null and booking._item_paid(i.id);
end $$;


-- ----- _add_to_order: asiakkaan lisäys asettaa pidon -----
CREATE OR REPLACE FUNCTION booking._add_to_order(p_order_id bigint, p_items jsonb, p_staff boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders; e jsonb; v_type text; v_added jsonb := '[]'::jsonb; v_total0 numeric; v_end timestamptz; v_res booking.reservations; a booking.addons; v_qty int; v_cur int; v_lim int;
  v_item bigint; p kb.products; pc booking.product_config; v_resid bigint; v_n int; v_r jsonb; v_pid bigint; v_start timestamptz; v_en timestamptz; v_line numeric; v_vat numeric; v_amt numeric;
  v_desc text; v_ovr boolean; v_chan text := case when p_staff then 'admin' else 'web' end; v_price numeric; v_add numeric; v_idtxt text; v_code text; v_mode text; v_rid bigint;
begin
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if booking._order_invoice_locked(o.id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.'); end if;
  if o.external_source is not null or not (o.status = 'confirmed' or (p_staff and o.status = 'completed')) then perform booking._err('order_not_editable', 'Tilaukseen ei voi lisätä'); end if;
  -- booking_190: asiakkaan lisäys vahvistettuun tilaukseen on 15 min pito (sama kuin kassan checkout_hold_minutes). Henkilökunta ei.
  if not p_staff and o.status = 'confirmed' then
    perform set_config('booking.addition_hold_minutes', booking._checkout_hold_minutes()::text, true);
  end if;
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
                 nullif(e ->> 'space_id', '')::bigint, v_ovr, e ->> 'override_reason', false, nullif(e ->> 'parent_reservation_id', '')::bigint, o.id, e ->> 'option_code');
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

  perform set_config('booking.addition_hold_minutes', '', true);
  perform booking._sync_placeholder(o.id);
  perform booking._refresh_order_payment(o.id);
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'orders', o.id::text, case when p_staff then 'ADMIN_ADD_TO_ORDER' else 'CUSTOMER_ADD_TO_ORDER' end,
          jsonb_build_object('total', v_total0), jsonb_build_object('items', p_items, 'added', v_added, 'total', (select total_gross from booking.orders where id = o.id)));
  return jsonb_build_object('added', v_added, 'added_total', (select total_gross from booking.orders where id = o.id) - v_total0);
end $function$;

-- ----- vahvistussivun hoito vahvistettuun tilaukseen -----
create or replace function booking._upsell_attach_reservation(p_order_id bigint, p_product_id bigint, p_start timestamptz, p_persons integer, p_main_day date, p_option_id bigint default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $f$
declare o booking.orders; v_end timestamptz; v_result jsonb; v_code text;
begin
  select * into o from booking.orders where id = p_order_id for update;
  if not found or o.external_source is not null or o.status not in ('pending', 'confirmed') then perform booking._err('order_not_editable', 'Order cannot be amended'); end if;
  if p_start is null or p_persons not between 1 and 50 or (p_start at time zone booking._tz())::date <> p_main_day then perform booking._err('invalid_date', 'Choose your visit date'); end if;
  if exists (select 1 from booking.reservations where order_id = o.id and product_id = p_product_id and booking._res_active(status, hold_expires_at)) then perform booking._err('duplicate_product', 'Already in order'); end if;
  if not exists (select 1 from booking._upsell_day_slots(p_product_id, p_main_day, p_persons) q where q.starts_at = p_start) then
    perform booking._err('slot_unavailable', 'Selected time is no longer available');
  end if;
  if p_option_id is not null then
    select po.code into v_code from booking.product_options po where po.id = p_option_id and po.product_id = p_product_id and po.active;
    if v_code is null then perform booking._err('invalid_option', 'Virheellinen valinta'); end if;
  end if;
  v_end := booking._treatment_slot_check(p_product_id, p_start, p_persons, true);
  -- 17. argumentti on p_option_code. null sallii tuotteen, joka ei vaadi valintaa. Laskulukko on _create_legs_bookingissa.
  if o.status = 'confirmed' then
    perform set_config('booking.addition_hold_minutes', booking._checkout_hold_minutes()::text, true);
  end if;
  v_result := booking._create_legs_booking('current', p_product_id, p_start, v_end, p_persons, o.customer_id, 'web', null, null, null, null, false, null, false, null, o.id, v_code);
  perform set_config('booking.addition_hold_minutes', '', true);
  return v_result;
end $f$;

-- ----- tilaussivu ja vahvistussivu: pending_additions -----
CREATE OR REPLACE FUNCTION booking.public_get_order(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders; v_cust text; v_bal jsonb; v_end timestamptz; v_conf_n int; v_conf_start timestamptz; v_kind text; v_hours int;
  v_items jsonb; v_res jsonb; v_pay jsonb; v_rec jsonb; v_creq jsonb; v_ups_a jsonb; v_ups_t jsonb; v_can_add boolean; v_pl text; v_open boolean; v_status text; v_online boolean;
  v_cancel_dl timestamptz; v_cancel_closed boolean;   -- booking_149: asiakkaan peruutuspyynnön takaraja
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if not booking._order_rl('get', p_token, (booking._setting('rl_order_get_per_10min', '60'::jsonb) #>> '{}')::int, (booking._setting('rl_order_get_per_10min', '60'::jsonb) #>> '{}')::int) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  v_hours := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  select split_part(c.name, ' ', 1) into v_cust from booking.customers c where c.id = o.customer_id;
  v_bal := booking._order_balance(o.id);
  v_status := case when o.status = 'pending' and exists (select 1 from booking.reservations r where r.order_id = o.id) and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) and not booking._order_mp_inflight(o.id) then 'expired' else o.status end;
  v_online := booking._montonio_online();
  v_pl := booking._setting('payment_link_path', to_jsonb('/maksa/'::text)) #>> '{}';

  select coalesce(jsonb_agg(jsonb_build_object('name', it.product_name, 'quantity', it.quantity, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate, 'kind', it.kind) order by it.id), '[]'::jsonb)
    into v_items from booking.order_items it where it.order_id = o.id;
  select coalesce(jsonb_agg(jsonb_build_object('reservation_id', r.id, 'product_id', r.product_id, 'product_name', oi.product_name, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons,
           'option', booking._option_json(r.product_option_id),
           'option_label', booking._option_label(r.product_id, o.locale), 'option_label_fi', booking._option_label(r.product_id, 'fi'), 'option_label_en', booking._option_label(r.product_id, 'en'), 'option_choices', booking._product_options_json(r.product_id),
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() and not booking._order_mp_inflight(r.order_id) then 'expired' else r.status end,
           'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', a.addon_id, 'name', a.product_name, 'quantity', a.quantity, 'line_total', a.line_total_gross) order by a.id)
                                 from booking.order_items a where a.parent_item_id = r.order_item_id and a.kind = 'addon'), '[]'::jsonb)) order by r.starts_at), '[]'::jsonb)
    into v_res from booking.reservations r left join booking.order_items oi on oi.id = r.order_item_id where r.order_id = o.id and r.hidden_at is null;
  select coalesce(jsonb_agg(jsonb_build_object('status', p.status, 'amount', p.amount, 'paid_at', p.paid_at,
           'method_label', case when p.provider in ('montonio', 'visma_pay', 'mobilepay') or p.method in ('montonio', 'visma_pay', 'mobilepay')
                                then case when coalesce(o.locale, 'fi') = 'en' then 'Pay online' else 'Maksa verkossa' end
                                else coalesce(pm.label, p.method) end,
           'link_token', case when p.status = 'pending' and (p.provider = 'montonio' or (p.provider in ('visma_pay', 'mobilepay') and p.provider_ref is null)) and (p.link_expires_at is null or p.link_expires_at > now()) then p.link_token end,
           'link_path', case when p.status = 'pending' and (p.provider = 'montonio' or (p.provider in ('visma_pay', 'mobilepay') and p.provider_ref is null)) and (p.link_expires_at is null or p.link_expires_at > now()) then v_pl || '?p=' || p.link_token end,
           'refunded', p.refunded_amount,
           'refund_pending', exists (select 1 from booking.refunds rf where rf.payment_id = p.id and rf.status in ('requested', 'processing'))) order by p.created_at, p.id), '[]'::jsonb)
    into v_pay from booking.payments p left join booking.payment_methods pm on pm.code = p.method
   where p.order_id = o.id and p.status <> 'cancelled'
     and not (p.provider = 'manual' and p.status = 'pending' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id));
  select coalesce(jsonb_agg(jsonb_build_object('receipt_no', x.receipt_no, 'kind', x.kind, 'issued_at', x.issued_at, 'token', x.public_token, 'total', x.total_gross) order by x.issued_at, x.id), '[]'::jsonb)
    into v_rec from booking.receipts x where x.order_id = o.id;
  select jsonb_build_object('status', q.status, 'created_at', q.created_at) into v_creq from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' order by q.created_at desc, q.id desc limit 1;

  select max(r.ends_at) into v_end from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at);
  v_can_add := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now() and not booking._order_invoice_locked(o.id);
  v_open := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now() and not exists (select 1 from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' and q.status = 'open');
  -- booking_149: asiakas voi pyytää peruutusta (ja sen hyvitystä) vain, kun ensimmäisen voimassa olevan vuoron alkuun on vähintään customer_change_hours_before tuntia (oletus 48).
  v_cancel_dl := booking._customer_cancel_deadline(o.id);
  v_cancel_closed := v_open and (v_cancel_dl is null or v_cancel_dl < now());
  v_open := v_open and v_cancel_dl is not null and v_cancel_dl >= now();
  select count(*), min(r.starts_at) into v_conf_n, v_conf_start from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  v_kind := case when exists (select 1 from booking.reservations r where r.order_id = o.id and r.rule_id is not null) then 'rules'
                 when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.order_id = o.id and r.rule_id is null) then 'slots'
                 else 'other' end;

  if v_can_add then
    select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name, 'name_en', a.name_en, 'description', a.description, 'description_en', a.description_en, 'price', a.price_gross, 'vat_rate', a.vat_rate,
             'max', x.lim, 'reservation_ids', x.rids) order by a.sort_order, a.id), '[]'::jsonb) into v_ups_a
      from booking.addons a
      join lateral (select max(booking._addon_limit(a.max_per_person, r.persons)) lim, jsonb_agg(r.id order by r.id) rids
                      from booking.reservations r left join booking.product_config pc on pc.product_id = r.product_id left join kb.products p on p.id = r.product_id
                     where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at) and r.ends_at > now()
                       and coalesce(case when pc.sale_kind = 'other' and pc.resource_class = 'resourced' then case when p.category = 'event' then 'event' else 'resource' end else r.mode end, r.mode) = any (a.applies_modes)) x on x.rids is not null
     where a.active;
    select coalesce(jsonb_agg(jsonb_build_object('product_id', p.id, 'name', p.name, 'name_en', p.name_en, 'price', p.price, 'duration_minutes', coalesce(pc.duration_minutes, p.duration_minutes),
             'description', p.description, 'description_en', p.description_en, 'category', p.category) order by pc.sort_order, p.id), '[]'::jsonb) into v_ups_t
      from booking.product_config pc join kb.products p on p.id = pc.product_id
     where pc.public_slots and pc.bookable and pc.shop_visible and pc.lifecycle = 'current' and p.active and p.price is not null;
  end if;

  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'status', v_status, 'payment_status', o.payment_status, 'currency', o.currency, 'locale', coalesce(o.locale, 'fi'),
    'created_at', o.created_at, 'first_name', v_cust, 'customer_kind', o.customer_kind, 'invoice_method', case when o.customer_kind <> 'private' then o.billing ->> 'invoice_method' end,
    'total', v_bal -> 'total', 'paid', v_bal -> 'net_paid', 'refunded', v_bal -> 'refunded', 'unpaid', v_bal -> 'unpaid',
    'items', v_items, 'reservations', v_res, 'payments', v_pay, 'receipts', v_rec,
    'invoice_locked', booking._order_invoice_locked(o.id),
    'can_add', v_can_add, 'add_until', case when v_can_add then v_end end,
    'can_change', (o.status = 'confirmed' and o.external_source is null and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now() and v_kind in ('rules', 'slots')),
    'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end, 'change_hours_before', v_hours,
    'change_via', case v_kind when 'slots' then 'public_change_order_time' when 'rules' then 'public_change_order_time' end, 'booking_kind', v_kind,
    'can_request_cancel', v_open, 'cancel_request', v_creq,
    'cancel_deadline', v_cancel_dl, 'cancel_hours_before', v_hours, 'cancel_closed', coalesce(v_cancel_closed, false), 'online_payment_enabled', v_online,
    'upsell', jsonb_build_object('addons', coalesce(v_ups_a, '[]'::jsonb), 'treatments', coalesce(v_ups_t, '[]'::jsonb)),
    'instructions', booking._order_full_instructions(o.id, coalesce(o.locale, 'fi')))
    || booking._checkout_state_json(o.id)
    || jsonb_build_object('pending_additions', booking._pending_additions_json(o.id));
end $function$;

CREATE OR REPLACE FUNCTION booking.public_get_booking(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders; res jsonb; adds jsonb; cust text;
  v_hours integer := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  v_conf_n integer; v_conf_start timestamptz; v_kind text; v_supported boolean;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select split_part(c.name, ' ', 1) into cust from booking.customers c where c.id = o.customer_id;
  select jsonb_agg(jsonb_build_object(
           'product_name', it.product_name, 'quantity', it.quantity, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate,
           'product_id', r.product_id, 'rule_id', r.rule_id,
           'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'mode', r.mode, 'option', booking._option_json(r.product_option_id),
           'option_label', booking._option_label(r.product_id, o.locale), 'option_label_fi', booking._option_label(r.product_id, 'fi'), 'option_label_en', booking._option_label(r.product_id, 'en'),
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() and not booking._order_mp_inflight(r.order_id) then 'expired' else r.status end,
           'hold_expires_at', r.hold_expires_at,
           'ritual_addon', booking._is_ritual_addon_item(it.id))   -- booking_166: vuoron lisäpalveluna varattu saunarituaali (näytetään vuoron jälkeen)
         order by booking._is_ritual_addon_item(it.id), r.starts_at)
    into res
    from booking.order_items it left join booking.reservations r on r.order_item_id = it.id
   where it.order_id = o.id and it.kind = 'reservation';
  select jsonb_agg(jsonb_build_object('addon_id', it.addon_id, 'name', it.product_name, 'name_en', it.price_breakdown ->> 'name_en',
           'quantity', it.quantity, 'unit_price', it.unit_price_gross, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate,
           'max_per_person', ad.max_per_person) order by it.id)
    into adds from booking.order_items it left join booking.addons ad on ad.id = it.addon_id where it.order_id = o.id and it.kind = 'addon';
  select count(*), min(r.starts_at) into v_conf_n, v_conf_start from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  -- booking_25: varaustyyppi. 'rules' = sääntöpohjainen (muutettavissa public_change_booking), 'slots' = verkossa tehty hoitovaraus (public_change_treatment_booking), 'other' = ei muutettavissa verkossa (tuonti/ylläpito)
  v_kind := case when exists (select 1 from booking.reservations r where r.order_id = o.id and r.rule_id is not null) then 'rules'
                 when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.order_id = o.id and r.rule_id is null) then 'slots'
                 else 'other' end;
  v_supported := v_kind in ('rules', 'slots');
  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'status',
           case when o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) and not booking._order_mp_inflight(o.id) then 'expired' else o.status end,
           'payment_status', o.payment_status, 'total', o.total_gross, 'currency', o.currency, 'created_at', o.created_at,
           'first_name', cust, 'customer_kind', o.customer_kind, 'invoice_method', case when o.customer_kind <> 'private' then o.billing ->> 'invoice_method' end, 'items', coalesce(res, '[]'::jsonb), 'addons', coalesce(adds, '[]'::jsonb),
           'payment_methods', (select coalesce(jsonb_agg(p.method), '[]'::jsonb) from booking.payments p where p.order_id = o.id),
           'can_change', (o.status = 'confirmed' and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now() and v_supported),
           'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end,
           'change_hours_before', v_hours,
           'has_ritual_addon', exists (select 1 from booking.order_items x where x.order_id = o.id and x.kind = 'reservation' and booking._is_ritual_addon_item(x.id)),
           'booking_kind', v_kind, 'change_via', case v_kind when 'slots' then 'public_change_treatment_booking' when 'rules' then 'public_change_booking' end,
           'invoice_locked', booking._order_invoice_locked(o.id))
         || booking._checkout_state_json(o.id)
         || jsonb_build_object('pending_additions', booking._pending_additions_json(o.id));
end $function$;


-- email_outbox_claim: booking_176 + unpaid_booking_cancelled -lohko (retry_url, tuote, aika)
CREATE OR REPLACE FUNCTION booking.email_outbox_claim(p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(case when z.item->>'kind' = 'annual_card_code'
    then z.item || jsonb_build_object('annual_card', booking._annual_card_mail((z.item->>'id')::bigint))
                || coalesce(booking._annual_card_admin_to((z.item->>'id')::bigint), '{}'::jsonb)
    when z.item->>'kind' = 'payment_link'
    then z.item || coalesce((select jsonb_build_object('voucher_difference', jsonb_build_object('total', e.payload -> 'total', 'voucher_value', e.payload -> 'voucher_value', 'difference', e.payload -> 'difference'))
                               from booking.email_outbox e where e.id = (z.item->>'id')::bigint and e.payload ->> 'variant' = 'voucher_difference'), '{}'::jsonb)
    when z.item->>'kind' = 'voucher_claim_received'
    then z.item || coalesce((select jsonb_build_object('order', (z.item->'order') || jsonb_build_object('instructions', booking._order_short_instructions(e.order_id, coalesce(nullif(e.locale, ''), o.locale, 'fi'))))
                               from booking.email_outbox e join booking.orders o on o.id = e.order_id where e.id = (z.item->>'id')::bigint and jsonb_typeof(z.item->'order') = 'object'), '{}'::jsonb)
                || coalesce((select jsonb_build_object('voucher_claim', jsonb_build_object('claim_id', vc.id, 'status', vc.status, 'source', vc.source, 'code_masked', booking._vc_mask(vc.code), 'problem_code', vc.problem_code,
                                   'hold_until', vc.hold_until, 'created_at', vc.created_at, 'customer_name', vc.customer_name))
                               from booking.email_outbox e join booking.voucher_claims vc on vc.order_id = e.order_id
                              where e.id = (z.item->>'id')::bigint and coalesce(z.item #>> '{voucher_claim,status}', 'cancelled') in ('cancelled', 'expired')
                                and vc.status in ('open', 'processing', 'problem', 'redeemed')
                              order by vc.created_at, vc.id limit 1), '{}'::jsonb)
    when z.item->>'kind' = 'unpaid_booking_cancelled'
    then z.item || coalesce((select jsonb_build_object('unpaid_booking', jsonb_strip_nulls(jsonb_build_object(
                  'retry_url', e.payload ->> 'retry_url',
                  'product_name', case when e.locale = 'en' then coalesce(nullif(e.payload ->> 'product_name_en', ''), e.payload ->> 'product_name') else e.payload ->> 'product_name' end,
                  'starts_at', e.payload -> 'starts_at')))
                from booking.email_outbox e where e.id = (z.item->>'id')::bigint), '{}'::jsonb)
    else z.item end order by z.ord), '[]'::jsonb)
  from jsonb_array_elements(booking.email_outbox_claim_base_146(p_limit)) with ordinality as z(item, ord);
$function$;

create or replace function booking.public_cancel_addition(p_token uuid, p_item_id bigint)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o booking.orders; n int;
begin
  if p_token is null or p_item_id is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if not booking._order_rl('addx', p_token, 12, 6) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  select * into o from booking.orders where public_token = p_token for update;
  if not found or o.external_source is not null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if o.status <> 'confirmed' then return jsonb_build_object('ok', false, 'code', 'order_not_editable'); end if;
  if booking._order_invoice_locked(o.id) then
    return jsonb_build_object('ok', false, 'code', 'order_invoiced', 'message', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
  end if;
  if booking._order_mp_inflight(o.id) then
    return jsonb_build_object('ok', false, 'code', 'payment_in_progress', 'message', 'Maksu on kesken');
  end if;
  if not exists (
    select 1 from booking.order_items i
     where i.id = p_item_id and i.order_id = o.id and i.hold_expires_at is not null and not booking._item_paid(i.id)
  ) then
    return jsonb_build_object('ok', false, 'code', 'not_cancellable');
  end if;
  n := booking._release_unpaid_additions(o.id, p_item_id, 'customer_cancelled');
  if coalesce(n, 0) < 1 then return jsonb_build_object('ok', false, 'code', 'not_cancellable'); end if;
  return jsonb_build_object('ok', true, 'released', n);
end $$;

revoke all on function booking._item_paid(bigint) from public, anon, authenticated;
revoke all on function booking._addition_hold_item_bi() from public, anon, authenticated;
revoke all on function booking._addition_hold_res_bi() from public, anon, authenticated;
revoke all on function booking._addition_hold_confirm_bu() from public, anon, authenticated;
revoke all on function booking._pending_additions_json(bigint) from public, anon, authenticated;
revoke all on function booking._release_unpaid_additions(bigint, bigint, text) from public, anon, authenticated;
revoke all on function booking._enqueue_unpaid_booking_email(bigint) from public, anon, authenticated;
revoke all on function booking.public_cancel_addition(uuid, bigint) from public;
grant execute on function booking.public_cancel_addition(uuid, bigint) to anon, authenticated, service_role;
grant execute on function booking._item_paid(bigint) to service_role;
grant execute on function booking._release_unpaid_additions(bigint, bigint, text) to service_role;
grant execute on function booking._enqueue_unpaid_booking_email(bigint) to service_role;
