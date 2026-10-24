-- ROLLBACK booking_142_annual_cards_discount_codes (paketti 10).
-- Poistaa booking_142:n funktiot, triggerit, rajoitteet, asetuksen annual_card_sale_enabled ja uudet sarakkeet.
-- booking_142 ei muuttanut olemassa olevia funktioita, joten mitään ei tarvitse palauttaa aiempaan versioon.
-- HUOM: vuosikorttien koodit ja verkko-ostojen tilauslinkit sekä alennuskoodien kohdistus-/käyttötapatiedot häviävät.
-- Alennuskoodeilla tehdyt varaukset (order_items.discount_amount, discount_code_id) säilyvät sellaisinaan.
set local lock_timeout = '5s';

drop trigger if exists discount_codes_normalize on booking.discount_codes;
drop trigger if exists annual_cards_code on booking.annual_cards;
drop trigger if exists order_items_discount_keep on booking.order_items;
drop trigger if exists reservations_annual_code_guard on booking.reservations;
drop trigger if exists orders_discount_release on booking.orders;
drop trigger if exists orders_annual_paid on booking.orders;

drop function if exists booking.admin_create_annual_card(bigint, date, date, text, text);
drop function if exists booking.admin_list_annual_cards_details();
drop function if exists booking.admin_delete_discount_code(bigint);
drop function if exists booking.admin_save_discount_code(bigint, jsonb);
drop function if exists booking.admin_list_discount_codes();
drop function if exists booking.public_annual_card_purchase_code(uuid);
drop function if exists booking.public_buy_annual_card(text, text, text, boolean, text);
drop function if exists booking.public_annual_card_offer();
drop function if exists booking._annual_sale_product();
drop function if exists booking.public_create_booking_code(bigint, date, integer, text, text, text, boolean, text, text, text, jsonb, jsonb, text);
drop function if exists booking.public_check_code(text, bigint, date, integer, jsonb, text, text);
drop function if exists booking.public_preview_code(text, bigint, date, integer, jsonb, text, text);
drop function if exists booking._annual_card_owner_ok(booking.annual_cards, text, text);
drop function if exists booking._annual_rule_check(bigint, date, booking.annual_cards, booking.discount_codes);
drop function if exists booking._code_msg(text);
drop function if exists booking._discount_state(booking.discount_codes);
drop function if exists booking._discount_split(booking.discount_codes, jsonb);
drop function if exists booking._annual_limit(bigint, text, text);
drop function if exists booking._annual_lock_identity(bigint, text, text);
drop function if exists booking._annual_orders_paid_trg();
drop function if exists booking._annual_card_from_order(bigint);
drop function if exists booking._discount_release_trg();
drop function if exists booking._annual_code_reservation_trg();
drop function if exists booking._order_items_discount_keep_trg();
drop function if exists booking._annual_card_code_trg();
drop function if exists booking._discount_code_normalize_trg();
drop function if exists booking._generate_discount_code();
drop function if exists booking._generate_annual_card_code();
drop function if exists booking._annual_max_persons();
drop function if exists booking._annual_product_ids();
drop function if exists booking._phone_key(text);
drop function if exists booking._norm_code(text);

delete from booking.settings where key = 'annual_card_sale_enabled';

alter table booking.annual_cards drop constraint if exists booking142_card_code_format;
alter table booking.discount_codes drop constraint if exists booking142_discount_annual;
alter table booking.discount_codes drop constraint if exists booking142_discount_dates;
alter table booking.discount_codes drop constraint if exists booking142_discount_percent;
alter table booking.discount_codes drop constraint if exists booking142_discount_count;
alter table booking.discount_codes drop constraint if exists booking142_discount_usage;
alter table booking.discount_codes drop constraint if exists booking142_discount_scope;

alter table booking.discount_codes drop column if exists is_annual_card_code;
alter table booking.discount_codes drop column if exists usage_type;
alter table booking.discount_codes drop column if exists target_scope;

drop index if exists booking.annual_cards_purchase_order_uq;
drop index if exists booking.annual_cards_code_uq;
alter table booking.annual_cards drop column if exists purchase_order_id;
alter table booking.annual_cards drop column if exists code;
