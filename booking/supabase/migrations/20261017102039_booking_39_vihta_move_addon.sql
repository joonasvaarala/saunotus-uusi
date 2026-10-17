-- booking_39_vihta_move_addon (17.10.2026): Sini Alakangas, Johku-saunavihta (order_item 13620, tilaus 11552, varaus 10212)
-- -> lisäpalvelu (addon 2 saunavihta, 13 €, "Maksettu Johkussa") varauksen 10213 (tilaus 11551, order_item 13618, 17.10. klo 14:00, 6 hlö) alle.
-- Rivi SIIRRETÄÄN (sama order_item-id, ei uusia rivejä): order_id 11552 -> 11551, parent_item_id = 13618, kind 'addon', addon_id 2.
-- orders.total_gross: 11551 203 -> 216 (+13), 11552 13 -> 0 (-13), jolloin Σ rivit = total kummassakin. payment_status/status ennallaan.
-- Ei payments/payment_lines/receipts/email_outbox -rivejä (Johku-tilauksilla ei ole; tarkistetaan). Varauksen 10212 piilotus vasta booking_40:ssä.
-- Varmuuskopio: staging/lisapalvelu/backup_before_booking39_20261017.json. Rollback: booking_39_40_ROLLBACK.sql.
do $$
declare v_a booking.addons; n int; t_a numeric; t_b numeric; s_a numeric; s_b numeric;
begin
  select * into v_a from booking.addons where id = 2 and code = 'saunavihta';
  if not found then raise exception 'addon 2 puuttuu'; end if;
  if v_a.price_gross is distinct from 13 then raise exception 'addon 2 hinta ei 13 (%)', v_a.price_gross; end if;
  if exists (select 1 from booking.payments where order_id in (11551, 11552)) or exists (select 1 from booking.receipts where order_id in (11551, 11552))
     or exists (select 1 from booking.email_outbox where order_id in (11551, 11552))
     or exists (select 1 from booking.payment_lines where order_item_id in (select id from booking.order_items where order_id in (11551, 11552)))
  then raise exception 'tilauksilla 11551/11552 on maksuja/kuitteja/sähköposteja – keskeytetään'; end if;
  select total_gross into t_a from booking.orders where id = 11551 and payment_status = 'paid' and status = 'confirmed' and external_source = 'johku' and customer_id = 8878;
  select total_gross into t_b from booking.orders where id = 11552 and payment_status = 'paid' and status = 'confirmed' and external_source = 'johku' and customer_id = 8878;
  if t_a is distinct from 203 or t_b is distinct from 13 then raise exception 'tilausten summat eivät ole 203/13 (% / %)', t_a, t_b; end if;
  if not exists (select 1 from booking.reservations r where r.id = 10213 and r.order_id = 11551 and r.order_item_id = 13618 and r.status = 'confirmed' and r.hidden_at is null and r.persons = 6)
  then raise exception 'varaus 10213 ei vastaa odotettua'; end if;

  update booking.order_items i set
      order_id = 11551, parent_item_id = 13618, kind = 'addon', addon_id = v_a.id, product_id = null, product_name = v_a.name,
      price_breakdown = coalesce(i.price_breakdown, '{}'::jsonb) || jsonb_build_object(
        'addon_code', v_a.code, 'name_en', v_a.name_en, 'unit_price', i.unit_price_gross, 'quantity', i.quantity, 'max_per_person', v_a.max_per_person,
        'prepaid', true, 'paid_in', 'johku', 'note', 'Maksettu Johkussa',
        'merged_from', jsonb_build_object('order_item_kind', 'reservation', 'product_id', 44, 'product_name', i.product_name, 'reservation_id', 10212,
                                          'order_id', 11552, 'johku_order_no', 13791, 'migration', 'booking_39'))
    where i.id = 13620 and i.order_id = 11552 and i.kind = 'reservation' and i.product_id = 44 and i.parent_item_id is null and i.quantity = 1 and i.line_total_gross = 13;
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'order_item 13620 ei vastannut odotettua (rows=%)', n; end if;

  update booking.orders set total_gross = 216,
      external_meta = coalesce(external_meta, '{}'::jsonb) || jsonb_build_object('addon_merge', jsonb_build_object('role', 'target', 'moved_order_item_id', 13620, 'from_order_id', 11552, 'amount', 13, 'migration', 'booking_39'))
    where id = 11551 and total_gross = 203;
  get diagnostics n = row_count; if n <> 1 then raise exception 'orders 11551 ei päivittynyt'; end if;
  update booking.orders set total_gross = 0,
      external_meta = coalesce(external_meta, '{}'::jsonb) || jsonb_build_object('addon_merge', jsonb_build_object('role', 'source', 'moved_order_item_id', 13620, 'to_order_id', 11551, 'amount', 13, 'migration', 'booking_39'))
    where id = 11552 and total_gross = 13;
  get diagnostics n = row_count; if n <> 1 then raise exception 'orders 11552 ei päivittynyt'; end if;

  select coalesce(sum(line_total_gross), 0) into s_a from booking.order_items where order_id = 11551;
  select coalesce(sum(line_total_gross), 0) into s_b from booking.order_items where order_id = 11552;
  if s_a <> 216 or s_b <> 0 then raise exception 'rivisummat eivät täsmää: % / %', s_a, s_b; end if;
  if not exists (select 1 from booking.order_items p where p.id = 13618 and p.order_id = 11551 and p.kind = 'reservation') then raise exception 'emorivi puuttuu'; end if;
end $$;
