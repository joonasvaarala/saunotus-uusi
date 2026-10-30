-- booking_216 rollback. Provisioraportti, säännöt ja provider_fee-sarakkeet pois.
-- Jo kirjatut provider_fee-arvot katoavat sarakkeen mukana. Maksut ja hyvitykset säilyvät.

drop trigger if exists payments_provider_fee on booking.payments;
drop trigger if exists refunds_provider_fee on booking.refunds;
drop trigger if exists audit_trg on booking.payment_fee_rules;

drop function if exists booking.admin_delete_payment_fee_rule(bigint);
drop function if exists booking.admin_upsert_payment_fee_rule(jsonb);
drop function if exists booking.admin_list_payment_fee_rules();
drop function if exists booking.admin_report_provider_fees(date, date, text);
drop function if exists booking._provider_admin_label(text);
drop function if exists booking._stamp_provider_fee();
drop function if exists booking._extract_provider_fee(jsonb);
drop function if exists booking._json_num(jsonb);

drop table if exists booking.payment_fee_rules;

alter table booking.payments drop constraint if exists payments_provider_fee_range;
alter table booking.refunds drop constraint if exists refunds_provider_fee_range;
alter table booking.payments drop column if exists provider_fee;
alter table booking.refunds drop column if exists provider_fee;

drop index if exists booking.payments_fee_paid_idx;
drop index if exists booking.refunds_fee_done_idx;
