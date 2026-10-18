-- ============================================================
-- booking_101_drop_business_quote_admin
-- Tarjouspyynnöt tulevat sähköpostiin. Hallinnan listaus ja tilan vaihto poistuvat.
-- Säilyy: booking.business_quote_requests (varmuuskopio ja rate limitin kaksoislähetyksen esto),
-- RLS quotes_staff_read, public_create_business_quote ja sähköpostilajit.
-- Poistuu: admin_list_business_quotes, admin_set_business_quote_status, permission quotes.manage.
-- Rollback: rollbacks/20261019010100_booking_101_ROLLBACK.sql (aja 102:n rollbackin jälkeen).
-- ============================================================
set local lock_timeout = '5s';

drop function if exists booking.admin_set_business_quote_status(bigint, text, text);
drop function if exists booking.admin_list_business_quotes(text);
delete from booking.role_permissions where permission = 'quotes.manage';
