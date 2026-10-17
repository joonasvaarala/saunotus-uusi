-- ROLLBACK booking_42_hide_package_side_shifts: palauttaa 25 oheisvuorovarausta (status, cancelled_at, cancel_reason alkuperäisiksi, hidden_* tyhjiksi, external_meta.merged_into pois).
-- Varmuuskopio: staging/lisapalvelu/backup_before_booking42_20261017.json. (updated_at päivittyy triggerillä.)
do $$
declare n int;
begin
  update booking.reservations r set
      status = r.external_meta->'merged_into'->>'original_status',
      cancelled_at = nullif(r.external_meta->'merged_into'->>'original_cancelled_at', '')::timestamptz,
      cancel_reason = nullif(r.external_meta->'merged_into'->>'original_cancel_reason', ''),
      hidden_at = null, hidden_reason = null,
      external_meta = r.external_meta - 'merged_into'
    where r.hidden_reason like 'merged_into_package:%' and r.external_meta->'merged_into'->>'migration' = 'booking_42';
  get diagnostics n = row_count;
  if n <> 25 then raise exception 'rollback: % riviä, odotettiin 25', n; end if;
end $$;
