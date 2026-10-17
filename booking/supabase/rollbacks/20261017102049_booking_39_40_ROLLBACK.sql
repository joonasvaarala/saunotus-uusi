-- ROLLBACK booking_39 + booking_40 (17.10.2026). Palauttaa varauksen 10212, order_item 13620 (takaisin tilaukseen 11552 varausriviksi) ja tilausten summat.
-- Varmuuskopio: staging/lisapalvelu/backup_before_booking39_20261017.json. Ajetaan tässä järjestyksessä. Ei kosketa payments-tauluihin. (updated_at-sarakkeet päivittyvät triggerillä.)
do $$
declare n int;
begin
  update booking.reservations r set status = 'confirmed', cancelled_at = null, cancel_reason = null, hidden_at = null, hidden_reason = null,
      external_meta = r.external_meta - 'merged_into'
    where r.id = 10212 and r.order_id = 11552 and r.hidden_reason = 'merged_into_addon:order_item=13620';
  get diagnostics n = row_count; if n <> 1 then raise exception 'rollback: varaus 10212 (rows=%)', n; end if;

  update booking.order_items i set order_id = 11552, parent_item_id = null, kind = 'reservation', addon_id = null, product_id = 44, product_name = 'Saunavihta',
      price_breakdown = i.price_breakdown - 'addon_code' - 'name_en' - 'unit_price' - 'quantity' - 'max_per_person' - 'prepaid' - 'paid_in' - 'note' - 'merged_from'
    where i.id = 13620 and i.order_id = 11551 and i.kind = 'addon' and i.addon_id = 2;
  get diagnostics n = row_count; if n <> 1 then raise exception 'rollback: order_item 13620 (rows=%)', n; end if;

  update booking.orders set total_gross = 203, external_meta = external_meta - 'addon_merge' where id = 11551 and total_gross = 216;
  get diagnostics n = row_count; if n <> 1 then raise exception 'rollback: order 11551'; end if;
  update booking.orders set total_gross = 13, external_meta = external_meta - 'addon_merge' where id = 11552 and total_gross = 0;
  get diagnostics n = row_count; if n <> 1 then raise exception 'rollback: order 11552'; end if;
  if (select sum(line_total_gross) from booking.order_items where order_id = 11551) <> 203 or (select sum(line_total_gross) from booking.order_items where order_id = 11552) <> 13 then raise exception 'rollback: summat'; end if;
end $$;
