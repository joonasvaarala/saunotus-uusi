-- ============================================================
-- booking_49_ROLLBACK: poistaa MobilePay-adapterin. Aja vain kun mobilepay.mode='off' eikä mobilepay-maksuja ole (tarkistus alla).
-- ============================================================
do $$ begin
  if exists (select 1 from booking.payments where provider = 'mobilepay') or exists (select 1 from booking.refunds where provider = 'mobilepay') then
    raise exception 'rollback: mobilepay-maksuja/hyvityksiä on olemassa – älä poista (ks. payments/refunds provider=mobilepay)';
  end if;
end $$;
drop function if exists booking.public_payment_options(uuid);
drop function if exists booking.mobilepay_order_refs(uuid);
drop function if exists booking.mobilepay_refund_fail(bigint, jsonb);
drop function if exists booking.mobilepay_refund_complete(bigint, text, jsonb);
drop function if exists booking.mobilepay_refund_claim(bigint, integer);
drop function if exists booking.mobilepay_fill_customer(bigint, text, text, text);
drop function if exists booking.mobilepay_payment_fail(text, text, text, jsonb);
drop function if exists booking.mobilepay_payment_confirmable(text);
drop function if exists booking.mobilepay_payment_lookup(text);
drop function if exists booking.mobilepay_payment_event(text, text, text, jsonb);
drop function if exists booking.mobilepay_payment_prepare(uuid, uuid, integer);
drop trigger if exists integration_config_mobilepay_guard on booking.integration_config;
drop function if exists booking._mobilepay_guard_trg();
drop function if exists booking._mobilepay_mode();
delete from booking.integration_config where key = 'mobilepay';
alter table booking.integration_config drop constraint if exists integration_config_mobilepay_no_dry_run;
alter table booking.integration_config drop constraint if exists integration_config_test_only_mobilepay;
alter table booking.integration_config drop constraint integration_config_mode_check;
alter table booking.integration_config add constraint integration_config_mode_check check (mode in ('off', 'dry_run', 'live'));
alter table booking.integration_config drop constraint integration_config_key_check;
alter table booking.integration_config add constraint integration_config_key_check check (key in ('resend', 'vismapay', 'procountor'));
