-- booking_305 ROLLBACK: poistaa hyvitysvalvonnan (ajastus, funktio, asetukset, refund_stuck-hälytykset). Ei koske hyvityksiin eikä maksuihin.
set local lock_timeout = '5s';
do $cron$ begin perform cron.unschedule(j.jobid) from cron.job j where j.jobname = 'booking_refunds_stuck_sweep'; end $cron$;
drop function if exists booking.refunds_stuck_sweep();
delete from booking.settings where key in ('refund_stuck_requested_hours', 'refund_stuck_customer_hours', 'refund_stuck_processing_hours');
delete from booking.notifications_outbox where topic = 'refund_stuck';
