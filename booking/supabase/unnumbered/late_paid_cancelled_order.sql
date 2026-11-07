-- NUMEROIMATON LUONNOS (Bottiavustus varaa booking-numeron; nimeä migrations/<ts>_booking_<n>_late_paid_cancelled_order.sql vasta varauksen jälkeen).
-- Myöhäinen "maksettu"-ilmoitus perutulle tilaukselle.
--
-- Bugi: booking.payment_mark_paid(text,text,numeric,jsonb) (booking_53, PROD md5 8ceb0a7dea60d37e3ea6a17cec0e4c25) kirjasi maksun ja asetti
-- ehdoitta orders.status = 'confirmed' myös perutulle (cancelled) tilaukselle. Varaukset jäivät cancelled-tilaan → tilaus "heräsi" ilman
-- varauksia ja orders_confirmed_upd jonotti tilausvahvistuksen asiakkaalle. Kutsujat: montonio_payment_apply (montonio-notify/return),
-- vismapay_payment_apply, mobilepay-flow (edge RPC).
--
-- Korjaus (vain payment_mark_paid):
--  * Lukitusjärjestys sama kuin svc_cancel_reservation: maksu (kutsuja) → tilauksen varaukset id-järjestyksessä → tilaus FOR UPDATE.
--    Näin peruutus ja maksu serialisoituvat eivätkä lukitu ristiin; tilauksen tila luetaan lukituksen jälkeen (READ COMMITTED: tuorein).
--  * Jos tilaus on cancelled: aito maksu kirjataan kerran (payments.status paid, payment_status päivittyy, kuitti kirjanpitoon), mutta
--    tilaus ja varaukset EIVÄT muutu, tilausvahvistusta ei jonoteta, kuittisähköposti merkitään skipped (ei automaattiviestiä),
--    tilaukselle internal_note-merkintä + audit_log LATE_PAID_CANCELLED_ORDER käsin tarkistettavaksi. Ei automaattista palautusta.
--    Paluuarvo: ok, needs_manual_review, order_cancelled, overpaid_amount (montonio/vismapay_payment_apply välittävät sen sellaisenaan).
--  * Muut tilat (pending/expired/confirmed/completed …): käyttäytyminen ennallaan (sama vahvistus- ja BK001-polku).
--  * Ennallaan: allekirjoitus, SECURITY DEFINER, search_path '', grantit (CREATE OR REPLACE säilyttää ACL:n), already/amount_mismatch-vartijat,
--    ylimaksuvartija, montonio_payment_apply, vismapay_payment_apply, edge-funktiot.
-- Rollback: rollbacks/late_paid_cancelled_order_ROLLBACK.sql (palauttaa md5 8ceb0a7dea60d37e3ea6a17cec0e4c25).

do $pre$
declare v text;
begin
  v := md5(pg_get_functiondef('booking.payment_mark_paid(text,text,numeric,jsonb)'::regprocedure));
  if v is null or v not in ('8ceb0a7dea60d37e3ea6a17cec0e4c25', '247db4154bf651d16c25d2caea8d2825') then  -- booking_53 tai tämä korjaus (uudelleenajo)
    raise exception 'late_paid_cancelled_order: payment_mark_paid md5 % ei vastaa odotettua (8ceb0a7d… booking_53 / 247db415… tämä). Ei muutoksia.', v;
  end if;
end $pre$;

CREATE OR REPLACE FUNCTION booking.payment_mark_paid(p_provider text, p_provider_ref text, p_amount numeric, p_raw jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pay booking.payments; v_over numeric; v_ostatus text;
begin
  select * into pay from booking.payments where provider = p_provider and provider_ref = p_provider_ref for update;
  if not found then perform booking._err('payment_not_found', 'Maksua ei löydy'); end if;
  if pay.status = 'paid' then return jsonb_build_object('ok', true, 'already', true); end if;
  if p_amount is not null and p_amount <> pay.amount then perform booking._err('amount_mismatch', 'Summa ei täsmää'); end if;
  -- late-paid-korjaus: lukitusjärjestys kuten svc_cancel_reservation (varaukset id-järjestyksessä, sitten tilaus) → peruutus/maksu serialisoituvat
  perform 1 from booking.reservations r where r.order_id = pay.order_id order by r.id for update;
  select o.status into v_ostatus from booking.orders o where o.id = pay.order_id for update;
  update booking.payments set status = 'paid', paid_at = now(), provider_status = 'paid', raw = coalesce(p_raw, raw) where id = pay.id;
  perform booking._refresh_order_payment(pay.order_id);
  -- booking_53: ylimaksun vartija – ei hylätä jo veloitettua maksua, mutta merkitään tilaukselle palautettavaksi
  select coalesce(sum(p.amount) filter (where p.status in ('paid', 'partially_refunded', 'refunded')), 0) - coalesce(sum(p.refunded_amount), 0) - max(o.total_gross)
    into v_over from booking.payments p join booking.orders o on o.id = p.order_id where p.order_id = pay.order_id;
  if v_over > 0.004 then
    update booking.orders set internal_note = coalesce(internal_note || E'\n', '') || format('YLIMAKSU %s € – palauta asiakkaalle (admin_refund)', round(v_over, 2)) where id = pay.order_id;
  else v_over := 0; end if;
  -- late-paid-korjaus: perutulle tilaukselle maksu kirjataan, mutta tilaus/varaukset eivät herää eikä asiakkaalle lähde automaattiviestiä
  if v_ostatus = 'cancelled' then
    update booking.email_outbox set status = 'skipped', last_error = 'late_paid_cancelled_order: ei automaattista kuittia perutulle tilaukselle'
     where payment_id = pay.id and kind = 'receipt' and status = 'pending';
    update booking.orders set internal_note = coalesce(internal_note || E'\n', '') || format('MAKSU PERUTULLE TILAUKSELLE %s € (%s %s) – tilaus pysyy peruttuna, tarkista käsin / palauta maksu', round(pay.amount, 2), p_provider, p_provider_ref)
     where id = pay.order_id;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
    values (null, booking._jwt_role(), 'payments', pay.id::text, 'LATE_PAID_CANCELLED_ORDER',
            jsonb_build_object('order_id', pay.order_id, 'provider', p_provider, 'provider_ref', p_provider_ref, 'amount', pay.amount, 'payment_status_before', pay.status));
    return jsonb_build_object('ok', true, 'needs_manual_review', true, 'order_cancelled', true, 'overpaid_amount', v_over);
  end if;
  -- vahvista pitovaraukset; jos pito ehti vanhentua ja aika on mennyt, trigger estää → tilaus jää tarkistettavaksi
  begin
    update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = pay.order_id and status in ('pending','expired');
    update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()) where id = pay.order_id;
  exception when sqlstate 'BK001' then
    update booking.orders set internal_note = coalesce(internal_note || E'\n', '') || 'MAKSETTU MUTTA AIKA EI ENÄÄ VAPAA – tarkista käsin / palauta maksu' where id = pay.order_id;
    return jsonb_build_object('ok', true, 'needs_manual_review', true, 'overpaid_amount', v_over);
  end;
  return jsonb_build_object('ok', true, 'overpaid_amount', v_over);
end $function$;
