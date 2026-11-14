-- booking_302 ROLLBACK (DEV): alkuperäinen cancellation_tier oli NULL kaikilla tuotteilla (orig_dev.json).
set local lock_timeout = '5s';
select set_config('booking.text_apply', 'on', true);
update booking.product_config set cancellation_tier = null where product_id in (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 48, 49, 110);
