drop function if exists booking.admin_resolve_order_request(bigint, text, text), booking.admin_list_order_requests(text), booking.public_change_order_time(uuid, bigint, timestamptz, bigint, date, integer),
  booking.public_request_cancel(uuid, text), booking.public_add_to_order(uuid, jsonb), booking.public_get_order(uuid), booking._notify_staff(text, bigint, jsonb), booking._public_pay_json(bigint),
  booking._order_err(text, text), booking._order_rl(text, uuid, integer, integer);
delete from booking.settings where key in ('rl_order_get_per_10min', 'rl_order_add_per_10min', 'rl_order_req_per_10min');
