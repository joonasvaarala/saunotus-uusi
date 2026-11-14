-- booking_310 ROLLBACK: palauttaa booking._expired_web_order_archivable booking_309-tilaan (md5 38d0f4093802da2d8caa5d01561cdde6).
-- booking_310:n jälkeen arkistoidut tilaukset (esim. #15081) jäävät arkistoiduiksi; tarvittaessa ne puretaan booking_309-rollbackin
-- tavoin external_meta.booking_309:n avulla (ks. rollbacks/20261114095905_booking_309_ROLLBACK.sql).
set local lock_timeout = '5s';
do $pre$
declare v text := md5(pg_get_functiondef(to_regprocedure('booking._expired_web_order_archivable(bigint)')));
begin
  if v is null or v not in ('38d0f4093802da2d8caa5d01561cdde6', '58176d2c27301cdf95bfa7f76861f0bd') then
    raise exception 'booking_310 ROLLBACK: odottamaton tila (md5 %). Ei muutoksia.', v;
  end if;
end $pre$;

CREATE OR REPLACE FUNCTION booking._expired_web_order_archivable(p_order_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1 from booking.orders o
     where o.id = p_order_id
       and o.archived_at is null and o.external_source is null and o.johku_order_no is null
       and o.source_channel = 'web' and o.created_by is null
       and o.status in ('cancelled', 'expired') and o.payment_status in ('unpaid', 'pending', 'failed')
       and ((o.status = 'cancelled'
             and exists (select 1 from booking.reservations r where r.order_id = o.id)
             and not exists (select 1 from booking.reservations r where r.order_id = o.id
                              and (r.status <> 'cancelled' or r.cancel_reason is null or r.cancel_reason not in ('hold_expired', 'customer_cancelled_pending'))))
         or (o.status = 'expired' and not exists (select 1 from booking.reservations r where r.order_id = o.id)))
       and not exists (select 1 from booking.payments p where p.order_id = o.id
                        and (p.status not in ('cancelled', 'failed') or coalesce(p.refunded_amount, 0) <> 0
                             or p.external_source is not null or p.method = 'invoice' or p.paid_at is not null))
       and not exists (select 1 from booking.receipts x where x.order_id = o.id)
       and not exists (select 1 from booking.refunds x where x.order_id = o.id)
       and not exists (select 1 from booking.accounting_outbox x where x.order_id = o.id)
       and not exists (select 1 from booking.invoices x where x.order_id = o.id)
       and not exists (select 1 from booking.annual_cards x where x.purchase_order_id = o.id)
       and not exists (select 1 from booking.training_participants x where x.order_id = o.id)
       and not exists (select 1 from booking.voucher_claims v where v.order_id = o.id and v.status not in ('cancelled', 'expired'))
       and not exists (select 1 from booking.vc_difference_payments d where d.order_id = o.id)
       and not exists (select 1 from booking.gift_cards g where g.purchase_order_id = o.id and g.status <> 'cancelled')
       and coalesce((select sum(l.delta) from booking.gift_card_ledger l where l.order_id = o.id), 0) = 0
       and not exists (select 1 from booking.reservations ch join booking.reservations pr on pr.id = ch.parent_reservation_id
                        where pr.order_id = o.id and ch.order_id <> o.id)
       and not exists (select 1 from booking.email_outbox e
                        where (e.order_id = o.id or e.payment_id in (select p.id from booking.payments p where p.order_id = o.id))
                          and e.status in ('pending', 'failed', 'sending')))
$function$
;

revoke all on function booking._expired_web_order_archivable(bigint) from public, anon, authenticated;
