-- booking_40_vihta_hide_10212 (17.10.2026): piilota alkuperäinen Johku-saunavihtavaraus 10212 (tilaus 11552) samalla tavalla kuin 7 aiempaa (booking_38).
-- Ajetaan vasta kun lisäpalvelu (order_item 13620) on varmistettu näkyvän admin_get_order(11551).reservations[10213].addons. Ei poistoa. checkin_at säilyy.
do $$
declare n int;
begin
  if not exists (select 1 from booking.order_items a where a.id = 13620 and a.kind = 'addon' and a.addon_id = 2 and a.parent_item_id = 13618 and a.order_id = 11551) then
    raise notice 'booking_40: addon-rivi 13620 puuttuu, piilotus ohitetaan';
    return;
  end if;
  update booking.reservations r set
      status = 'cancelled', cancelled_at = now(), cancel_reason = 'merged_into_addon',
      hidden_at = now(), hidden_reason = 'merged_into_addon:order_item=13620',
      external_meta = coalesce(r.external_meta, '{}'::jsonb) || jsonb_build_object('merged_into', jsonb_build_object('addon_order_item_id', 13620, 'parent_order_item_id', 13618, 'target_reservation_id', 10213, 'target_order_id', 11551, 'migration', 'booking_40'))
    where r.id = 10212 and r.order_id = 11552 and r.order_item_id = 13620 and r.product_id = 44 and r.status = 'confirmed' and r.external_source = 'johku' and r.hidden_at is null;
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'varaus 10212 ei vastannut odotettua (rows=%)', n; end if;
  if exists (select 1 from booking.reservation_legs l where l.reservation_id = 10212) then raise exception 'varauksella 10212 on legejä'; end if;
end $$;
