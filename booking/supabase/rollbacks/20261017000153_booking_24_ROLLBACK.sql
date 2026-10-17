drop trigger if exists space_blocks_zz_outbox on booking.space_blocks;
drop function if exists booking.closure_blocks_outbox_trg(), booking.closure_outbox_claim(integer), booking.closure_outbox_complete(bigint, text), booking.closure_outbox_fail(bigint, text, boolean),
  booking.closure_outbox_backfill(), booking.admin_closure_outbox_status(), booking.admin_closure_outbox_retry(), booking._closure_event_id(bigint), booking._closure_calendar_for(bigint), booking._closure_block_hash(bigint);
drop table if exists booking.closure_outbox, booking.closure_exports;
delete from booking.closure_event_rules where calendar_code is null and match_type = 'prefix' and pattern = '[HALLINTA]';
