-- ROLLBACK: late_paid_cancelled_order (booking_263). Palauttaa PRODin booking_53-määrittelyn (md5 8ceb0a7dea60d37e3ea6a17cec0e4c25) sanatarkasti.
-- Lähtöhashvartija: ajetaan vain, jos nykyinen määrittely on täsmälleen tämä korjaus (b35618b8cd17fa9e7c5902719d0804a2) – ei korvaa myöhempää korjausta.
-- Jo valmiiksi palautettu (8ceb…) → ei muutosta. Ei koske dataan (maksut, internal_note, audit_log, skipped-kuittiviestit jäävät).
do $pre$
declare v text := md5(pg_get_functiondef('booking.payment_mark_paid(text,text,numeric,jsonb)'::regprocedure));
begin
  if v = '8ceb0a7dea60d37e3ea6a17cec0e4c25' then raise notice 'rollback: payment_mark_paid on jo booking_53-versio'; return; end if;
  if v is distinct from 'b35618b8cd17fa9e7c5902719d0804a2' then
    raise exception 'rollback: payment_mark_paid md5 % ei ole late_paid_cancelled_order-versio (b35618b8…). Ei muutoksia.', v;
  end if;
end $pre$;

CREATE OR REPLACE FUNCTION booking.payment_mark_paid(p_provider text, p_provider_ref text, p_amount numeric, p_raw jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pay booking.payments; v_over numeric;
begin
  select * into pay from booking.payments where provider = p_provider and provider_ref = p_provider_ref for update;
  if not found then perform booking._err('payment_not_found', 'Maksua ei löydy'); end if;
  if pay.status = 'paid' then return jsonb_build_object('ok', true, 'already', true); end if;
  if p_amount is not null and p_amount <> pay.amount then perform booking._err('amount_mismatch', 'Summa ei täsmää'); end if;
  update booking.payments set status = 'paid', paid_at = now(), provider_status = 'paid', raw = coalesce(p_raw, raw) where id = pay.id;
  perform booking._refresh_order_payment(pay.order_id);
  -- booking_53: ylimaksun vartija – ei hylätä jo veloitettua maksua, mutta merkitään tilaukselle palautettavaksi
  select coalesce(sum(p.amount) filter (where p.status in ('paid', 'partially_refunded', 'refunded')), 0) - coalesce(sum(p.refunded_amount), 0) - max(o.total_gross)
    into v_over from booking.payments p join booking.orders o on o.id = p.order_id where p.order_id = pay.order_id;
  if v_over > 0.004 then
    update booking.orders set internal_note = coalesce(internal_note || E'\n', '') || format('YLIMAKSU %s € – palauta asiakkaalle (admin_refund)', round(v_over, 2)) where id = pay.order_id;
  else v_over := 0; end if;
  -- vahvista pitovaraukset; jos pito ehti vanhentua ja aika on mennyt, trigger estää → tilaus jää tarkistettavaksi
  begin
    update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = pay.order_id and status in ('pending','expired');
    update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()) where id = pay.order_id;
  exception when sqlstate 'BK001' then
    update booking.orders set internal_note = coalesce(internal_note || E'\n', '') || 'MAKSETTU MUTTA AIKA EI ENÄÄ VAPAA – tarkista käsin / palauta maksu' where id = pay.order_id;
    return jsonb_build_object('ok', true, 'needs_manual_review', true, 'overpaid_amount', v_over);
  end;
  return jsonb_build_object('ok', true, 'overpaid_amount', v_over);
end $function$
;

do $post$ begin
  if md5(pg_get_functiondef('booking.payment_mark_paid(text,text,numeric,jsonb)'::regprocedure)) <> '8ceb0a7dea60d37e3ea6a17cec0e4c25' then
    raise exception 'rollback: payment_mark_paid md5 ei palautunut';
  end if;
end $post$;
