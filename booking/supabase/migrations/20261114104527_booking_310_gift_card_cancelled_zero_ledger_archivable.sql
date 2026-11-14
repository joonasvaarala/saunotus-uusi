-- booking_310: Joonaksen päätös 14.11.2026 klo 12.34 (Bottiavustus t1741s7272): "Piilotetaan #15081, mutta markkinointiluvan antanut asiakas jää näkyviin".
-- booking._expired_web_order_archivable: maksurivi ei estä piilotusta, jos se on PERUTTU lahjakorttimaksu (method gift_card, status cancelled),
-- jonka kaikki lahjakorttikirjaukset (gift_card_ledger.payment_id) kohdistuvat maksun omaan korttiin ja ovat nettona 0 (veloitus palautettu kortille),
-- vaikka paid_at on täytetty, eikä maksulla ole kuitteja eikä hyvityksiä. Kaikki muut rahalliset tapaukset estävät edelleen (Montonio/Visma/muut maksut,
-- aktiiviset tai osittaiset lahjakorttiveloitukset, hyvitetyt, refunded_amount ≠ 0, ulkoiset, laskut). Tilaustason ledger-netto 0 -ehto ennallaan.
-- Ei muuta: sweep (kutsuu tätä funktiota, md5 afe9100c20f3d5083e8494d77a100085), _customer_archivable (md5 172f72b8587d232e20914c6214b2b4bf, markkinointilupasääntö ennallaan), grantit, asetukset.
-- PROD 14.11. (SELECT): ainoa uusi piilotettava #15081 (order 14027, payment 1013, kortti 1139: -149 / +149, kortin saldo 149). Asiakas 10382 jää näkyviin (markkinointilupa).
-- Rollback: rollbacks/20261114103608_booking_310_ROLLBACK.sql (palauttaa booking_309-version md5 38d0f4093802da2d8caa5d01561cdde6; jo arkistoidut tilaukset jäävät arkistoiduiksi).
set local lock_timeout = '5s';

do $pre$
declare v text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking._expired_web_order_archivable(bigint)')));
  if v is null then raise exception 'booking_310: booking._expired_web_order_archivable puuttuu (booking_309 ajamatta). Ei muutoksia.'; end if;
  if v not in ('38d0f4093802da2d8caa5d01561cdde6', '58176d2c27301cdf95bfa7f76861f0bd') then
    raise exception 'booking_310: booking._expired_web_order_archivable md5 % odottamaton (odotettu 38d0f4093802da2d8caa5d01561cdde6). Ei muutoksia.', v;
  end if;
  if md5(pg_get_functiondef(to_regprocedure('booking.expired_web_orders_archive_sweep(integer)'))) is distinct from 'afe9100c20f3d5083e8494d77a100085' then
    raise exception 'booking_310: booking.expired_web_orders_archive_sweep md5 odottamaton. Ei muutoksia.';
  end if;
  if md5(pg_get_functiondef(to_regprocedure('booking._customer_archivable(bigint)'))) is distinct from '172f72b8587d232e20914c6214b2b4bf' then
    raise exception 'booking_310: booking._customer_archivable md5 odottamaton. Ei muutoksia.';
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
                             or p.external_source is not null or p.method = 'invoice'
                             or (p.paid_at is not null
                                 -- booking_310: peruttu lahjakorttimaksu, jonka kirjaukset kortille ovat nettona 0 (veloitus palautettu kortille), ei ole rahaa
                                 and not (p.method = 'gift_card' and p.status = 'cancelled' and p.gift_card_id is not null
                                          and exists (select 1 from booking.gift_card_ledger l where l.payment_id = p.id)
                                          and not exists (select 1 from booking.gift_card_ledger l where l.payment_id = p.id and l.gift_card_id is distinct from p.gift_card_id)
                                          and (select sum(l.delta) from booking.gift_card_ledger l where l.payment_id = p.id) = 0
                                          and not exists (select 1 from booking.receipts rc where rc.payment_id = p.id)
                                          and not exists (select 1 from booking.refunds rf where rf.payment_id = p.id)))))
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
