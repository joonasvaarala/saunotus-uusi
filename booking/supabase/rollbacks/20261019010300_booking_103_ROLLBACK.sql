-- Purkaa booking_103. Ei poista integration_config-riviä eikä booking_77–79-tauluja.
drop function if exists booking.admin_procountor_preview_daily(date);
drop function if exists booking.admin_set_procountor_settings(jsonb);
drop function if exists booking.admin_get_procountor_settings();
drop function if exists booking._json_has_secret_key(jsonb);
