-- booking_340_call_button ROLLBACK
drop function if exists booking.svc_call_button_result(bigint, text, text, text);
drop function if exists booking.svc_call_button_press(text, integer, text, text);
drop function if exists booking._call_button_route(timestamptz);
drop table if exists booking.call_button_presses;
drop table if exists booking.call_button_devices;
delete from booking.settings where key in ('call_button_enabled', 'call_button.config');
