-- ============================================================
-- booking_43_ROLLBACK: lahjakorttiskeema takaisin booking_42-tilaan (ajetaan booking_44_ROLLBACK jälkeen)
-- Huom: poistaa uudet sarakkeet (ostaja/saaja/tervehdys/token/ym.) ja paketit/estolistan/lokin. Johku-tuonnin rivit (source='johku') säilyvät
-- perussarakkeiltaan; poista ne tarvittaessa ensin booking_43_import_ROLLBACK.sql:llä.
-- ============================================================
do $$ begin
  if exists (select 1 from booking.gift_cards where source = 'native') then
    raise exception 'ROLLBACK ESTETTY: natiiveja lahjakortteja on olemassa';
  end if;
  if exists (select 1 from booking.gift_cards where status = 'pending_payment') then
    raise exception 'ROLLBACK ESTETTY: maksua odottavia kortteja on olemassa';
  end if;
  if exists (select 1 from booking.payments where method = 'gift_card' or gift_card_id is not null) then
    raise exception 'ROLLBACK ESTETTY: lahjakorttimaksuja on olemassa';
  end if;
end $$;

drop trigger if exists payments_gift_card_guard on booking.payments;
drop function if exists booking.payments_gift_card_guard_trg();
update booking.payment_methods set is_manual = true, label = 'Lahjakortti (oma)' where code = 'gift_card';

delete from booking.settings where key in ('gift_cards.redeem_enabled', 'gift_cards.johku_cards_redeemable', 'gift_cards.sale_enabled', 'gift_cards.max_cards_per_order',
  'gift_cards.rl_check_fail_per_10min', 'gift_cards.rl_global_fail_per_10min', 'gift_cards.rl_buy_per_10min');
delete from booking.role_permissions where permission in ('giftcards.manage', 'giftcards.admin');

drop trigger if exists gift_card_ledger_append_only on booking.gift_card_ledger;
drop function if exists booking.gift_card_ledger_append_only_trg();
drop trigger if exists gift_cards_norm on booking.gift_cards;
drop function if exists booking.gift_cards_norm_trg();

alter table booking.gift_card_ledger drop constraint if exists gift_card_ledger_reason_check;
drop index if exists booking.gift_card_ledger_order_idx;
drop index if exists booking.gift_card_ledger_payment_idx;
alter table booking.gift_card_ledger drop column if exists note, drop column if exists meta, drop column if exists old_valid_to, drop column if exists new_valid_to;

alter table booking.gift_cards drop constraint if exists gift_cards_code_format, drop constraint if exists gift_cards_origin_check, drop constraint if exists gift_cards_native_hh;
drop index if exists booking.gift_cards_public_token_uq;
drop index if exists booking.gift_cards_purchase_order_idx;
drop index if exists booking.gift_cards_status_valid_idx;
drop index if exists booking.gift_cards_source_idx;
drop index if exists booking.gift_cards_buyer_idx;
drop index if exists booking.gift_cards_order_item_idx;
drop index if exists booking.gift_cards_package_idx;
alter table booking.gift_cards drop column if exists source, drop column if exists package_code, drop column if exists valid_from, drop column if exists valid_months, drop column if exists buyer_customer_id, drop column if exists buyer_name, drop column if exists buyer_email, drop column if exists recipient_name, drop column if exists recipient_email, drop column if exists greeting, drop column if exists locale, drop column if exists vat_treatment, drop column if exists sale_vat_rate, drop column if exists accounting_origin, drop column if exists public_token, drop column if exists purchase_order_item_id, drop column if exists balance_verified, drop column if exists balance_verified_at, drop column if exists balance_source, drop column if exists single_order, drop column if exists activated_at, drop column if exists last_used_at, drop column if exists pdf_path, drop column if exists external_meta, drop column if exists created_by;
alter table booking.gift_cards drop constraint if exists gift_cards_status_check;
alter table booking.gift_cards add constraint gift_cards_status_check check (status in ('active', 'used', 'expired', 'cancelled', 'pending_verification'));

drop table if exists booking.gift_card_check_log;
drop table if exists booking.gift_card_blocked_codes;
drop table if exists booking.gift_card_packages;
drop function if exists booking.gift_code_fmt(text);
drop function if exists booking.gift_code_norm(text);
