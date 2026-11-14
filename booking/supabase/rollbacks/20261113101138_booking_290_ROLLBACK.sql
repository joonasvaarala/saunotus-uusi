delete from booking.closure_event_rules where calendar_code='rauni' and sort_order=15 and pattern='.*';
-- palauta näkymä alkuperäiseksi (class='closure' ilman rough-ehtoa), sitten:
-- alter table booking.closure_calendars drop column close_all;
