-- booking_123 rollback: poistaa asetussivun uudet kutsut. Asetusrivejä ei poisteta eikä vanhaa admin_set_settingiä muuteta.
-- Aja vain jos booking_123 on käytössä.

set local lock_timeout = '5s';

drop function if exists booking.admin_save_settings(text, jsonb);
drop function if exists booking.admin_settings_bundle();
drop function if exists booking._settings_ui_iban(text);
drop function if exists booking._settings_ui_put(text, jsonb);
drop function if exists booking._settings_ui_bool(jsonb, text);
drop function if exists booking._settings_ui_int(jsonb, int, int, text);
drop function if exists booking._settings_ui_only(jsonb, text[]);
