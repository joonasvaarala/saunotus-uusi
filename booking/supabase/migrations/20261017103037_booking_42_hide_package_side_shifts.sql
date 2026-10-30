-- booking_42_hide_package_side_shifts (17.10.2026): piilota paketin kb 7 (rituaali + savusaunavuoro) oheisvuorovaraukset (Johku "Yleinen vuoro" 0 €, optiontype 3),
-- jotka on tuotu omiksi varauksiksi ja merkitty external_meta.model.merged_into_package (25 kpl: 3 tulevaa + 22 menneitä). Paketti-varaus (2 h, legit) hoitaa savusaunaosan jo itse
-- -> oheisvuoro kulutti poolipaikat ja näkyi ylläpidossa kahdesti. Tapa kuten booking_38/40: status 'cancelled' + cancel_reason/hidden_reason 'merged_into_package' + hidden_at.
-- EI poisteta; tilausrivit (0 €), tilaukset, paketit, maksut ennallaan. Alkuperäinen status/cancelled_at/cancel_reason tallennetaan external_meta.merged_into -kenttään (rollback).
-- Varmuuskopio: staging/lisapalvelu/backup_before_booking42_20261017.json. Rollback: booking_42_ROLLBACK.sql. (booking_41 on varattu johku_ei_kirjanpitoon.)
do $$
declare n int; v_cnt int;
begin
  select count(*) into v_cnt from booking.reservations where external_meta->'model' ? 'merged_into_package' and hidden_at is null;
  if v_cnt = 0 then
    raise notice 'booking_42: ei merged_into_package-varauksia, piilotus ohitetaan';
    return;
  end if;
  if v_cnt <> 25 then raise exception 'odotettiin 25 piilotettavaa oheisvuoroa, löytyi %', v_cnt; end if;

  update booking.reservations r set
      status = 'cancelled', cancelled_at = now(), cancel_reason = 'merged_into_package',
      hidden_at = now(), hidden_reason = 'merged_into_package:package_reservation=' || p.id,
      external_meta = coalesce(r.external_meta, '{}'::jsonb) || jsonb_build_object('merged_into', jsonb_build_object(
          'kind', 'package_side_shift', 'package_reservation_id', p.id, 'package_external_id', r.external_meta->'model'->>'merged_into_package',
          'original_status', r.status, 'original_cancelled_at', r.cancelled_at, 'original_cancel_reason', r.cancel_reason, 'migration', 'booking_42'))
    from booking.reservations p
   where r.external_meta->'model' ? 'merged_into_package' and r.hidden_at is null
     and r.external_source = 'johku' and r.product_id = 1 and r.status in ('confirmed', 'completed')
     and p.external_source = 'johku' and p.external_id = r.external_meta->'model'->>'merged_into_package'
     and p.order_id = r.order_id and p.product_id = 7 and p.status in ('confirmed', 'completed') and p.hidden_at is null;
  get diagnostics n = row_count;
  if n <> 25 then raise exception 'piilotettiin % riviä, odotettiin 25', n; end if;
  if exists (select 1 from booking.reservation_legs l join booking.reservations r on r.id = l.reservation_id where r.hidden_reason like 'merged_into_package:%') then raise exception 'piilotetulla oheisvuorolla on legejä'; end if;
  if exists (select 1 from booking.reservations r join booking.order_items i on i.id = r.order_item_id where r.hidden_reason like 'merged_into_package:%' and i.line_total_gross <> 0) then raise exception 'oheisvuoron rivi ei ole 0 €'; end if;
end $$;
