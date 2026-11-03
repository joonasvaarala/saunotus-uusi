-- booking_240 referenssi: sama määritelmä suoraan booking.orders-taulusta, sekä vertailuluku "kaikki paid" (77-tyyppinen laskenta).
select count(*) filter (where source_channel='web' and payment_status in ('paid','partially_refunded') and status not in ('cancelled','expired','pending') and external_source is null and johku_order_no is null) web_paid,
       sum(total_gross) filter (where source_channel='web' and payment_status in ('paid','partially_refunded') and status not in ('cancelled','expired','pending') and external_source is null and johku_order_no is null) web_gross,
       count(*) filter (where payment_status in ('paid','partially_refunded') and status not in ('cancelled','expired','pending') and external_source is null and johku_order_no is null and source_channel <> 'johku_import') native_paid,
       sum(total_gross) filter (where payment_status in ('paid','partially_refunded') and status not in ('cancelled','expired','pending') and external_source is null and johku_order_no is null and source_channel <> 'johku_import') native_gross,
       count(*) filter (where payment_status='paid') all_paid_raw, sum(total_gross) filter (where payment_status='paid') all_paid_raw_gross,
       count(*) filter (where payment_status='paid' and source_channel='johku_import') johku_paid, sum(total_gross) filter (where payment_status='paid' and source_channel='johku_import') johku_gross,
       count(*) filter (where payment_status='paid' and status='cancelled') cancelled_paid, sum(total_gross) filter (where payment_status='paid' and status='cancelled') cancelled_paid_gross
  from booking.orders
 where (created_at at time zone 'Europe/Helsinki')::date between '2026-10-28' and '2026-11-03';
