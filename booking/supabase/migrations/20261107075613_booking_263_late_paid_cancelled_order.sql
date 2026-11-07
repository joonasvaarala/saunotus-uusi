-- NUMEROIMATON LUONNOS → booking_263 (varattu; tarkka nimeäminen Bottiavustuksen putkessa). Ei ajettu DEV/PROD.
-- Kapea, ei-regressoiva korjaus: myöhäinen "maksettu"-ilmoitus perutulle tilaukselle (Joonas, Asiakaspalvelu t236u 7.11. 09.19: "Joo toi bugi pitää kyllä korjata").
--
-- Bugi: booking.payment_mark_paid(text,text,numeric,jsonb) (booking_53, PROD md5 8ceb0a7dea60d37e3ea6a17cec0e4c25) asetti ehdoitta
-- orders.status = 'confirmed' myös perutulle tilaukselle (→ tilausvahvistus asiakkaalle) ja _refresh_order_payment vahvisti maksettujen
-- rivien pending-varaukset / purki rivipidot tilauksen tilasta riippumatta.
--
-- Muutos (vain tämä funktio):
--  * Baseline säilyy: maksurivin lukko ja vartijat (not_found / already / amount_mismatch) sekä maksun UPDATE ja sen triggerit
--    (kirjanpitokuitti, payment_lines, kuittiviestin jonotus) samassa järjestyksessä kuin ennen.
--  * Heti maksun UPDATEn jälkeen – kohdassa, jossa baseline siirtyy tilauksen päivitykseen (_refresh_order_payment → UPDATE orders) –
--    tilaus lukitaan FOR NO KEY UPDATE (sama lukkotaso kuin baselinen UPDATE) ja sen tila luetaan tuoreena. Ei NOWAITia, ei varausten
--    ennakkolukitusta, ei aiempaa lukkoa kuittikirjauksen edelle → lukitusjärjestys ja odotuskäytös kuten baselinessa.
--  * status = 'cancelled': vain payment_status lasketaan (sama kaava kuin _refresh_order_payment), ei _refresh_order_payment-kutsua,
--    ei varaus-/rivipito-/status-/cancelled_at-muutoksia, ei tilausvahvistusta; samassa transaktiossa jonotettu kuittiviesti (jos
--    email.receipt_auto_send=true) → skipped; ylimaksuvartija kuten ennen; internal_note + audit LATE_PAID_CANCELLED_ORDER;
--    paluu needs_manual_review + order_cancelled. Ei automaattista palautusta eikä asiakasviestiä.
--  * Muut tilat: baseline-polku sellaisenaan.
-- Ei kuulu tähän: globaalit baseline-deadlockit, retry/reconcile, MobilePay capture-retry, lisäyksen amount_mismatch, jo lähteneet viestit.
-- Rollback: rollbacks/late_paid_cancelled_order_ROLLBACK.sql (lähtöhashvartija).

do $pre$
declare v text;
begin
  v := md5(pg_get_functiondef('booking.payment_mark_paid(text,text,numeric,jsonb)'::regprocedure));
  if v is null or v not in ('8ceb0a7dea60d37e3ea6a17cec0e4c25', 'b35618b8cd17fa9e7c5902719d0804a2') then  -- booking_53 tai tämä korjaus (uudelleenajo)
    raise exception 'late_paid_cancelled_order: payment_mark_paid md5 % ei vastaa odotettua (8ceb0a7d… booking_53 / tämä). Ei muutoksia.', v;
  end if;
end $pre$;

CREATE OR REPLACE FUNCTION booking.payment_mark_paid(p_provider text, p_provider_ref text, p_amount numeric, p_raw jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pay booking.payments; v_over numeric; v_ostatus text; v_total numeric; v_paid numeric; v_refunded numeric; v_pending int;
begin
  select * into pay from booking.payments where provider = p_provider and provider_ref = p_provider_ref for update;
  if not found then perform booking._err('payment_not_found', 'Maksua ei löydy'); end if;
  if pay.status = 'paid' then return jsonb_build_object('ok', true, 'already', true); end if;
  if p_amount is not null and p_amount <> pay.amount then perform booking._err('amount_mismatch', 'Summa ei täsmää'); end if;
  update booking.payments set status = 'paid', paid_at = now(), provider_status = 'paid', raw = coalesce(p_raw, raw) where id = pay.id;
  -- booking_263: tilaus lukitaan ja luetaan tuoreena tässä, missä baseline siirtyy tilauksen päivitykseen (sama lukkotaso kuin UPDATE)
  select o.status into v_ostatus from booking.orders o where o.id = pay.order_id for no key update;
  if v_ostatus = 'cancelled' then
    -- booking_263: vain payment_status (kaava = _refresh_order_payment), ei varausten vahvistusta eikä rivipitojen purkua
    select o.total_gross into v_total from booking.orders o where o.id = pay.order_id;
    select coalesce(sum(p.amount) filter (where p.status in ('paid','partially_refunded','refunded')), 0), coalesce(sum(p.refunded_amount), 0), count(*) filter (where p.status = 'pending')
      into v_paid, v_refunded, v_pending from booking.payments p where p.order_id = pay.order_id;
    update booking.orders set payment_status = case
        when v_paid > 0 and v_refunded >= v_paid then 'refunded'
        when v_refunded > 0 then 'partially_refunded'
        when coalesce(v_total, 0) <= 0.004 then 'paid'
        when v_paid >= v_total and v_total > 0 then 'paid'
        when v_paid > 0 then 'partially_paid'
        when v_pending > 0 and exists (select 1 from booking.payments x where x.order_id = pay.order_id and x.status = 'pending' and x.provider <> 'manual') then 'pending'
        else 'unpaid' end
     where id = pay.order_id;
  else
    perform booking._refresh_order_payment(pay.order_id);
  end if;
  -- booking_53: ylimaksun vartija – ei hylätä jo veloitettua maksua, mutta merkitään tilaukselle palautettavaksi
  select coalesce(sum(p.amount) filter (where p.status in ('paid', 'partially_refunded', 'refunded')), 0) - coalesce(sum(p.refunded_amount), 0) - max(o.total_gross)
    into v_over from booking.payments p join booking.orders o on o.id = p.order_id where p.order_id = pay.order_id;
  if v_over > 0.004 then
    update booking.orders set internal_note = coalesce(internal_note || E'\n', '') || format('YLIMAKSU %s € – palauta asiakkaalle (admin_refund)', round(v_over, 2)) where id = pay.order_id;
  else v_over := 0; end if;
  if v_ostatus = 'cancelled' then
    -- booking_263: perutulle tilaukselle ei automaattista kuittiviestiä; käsin tarkistettavaksi
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
