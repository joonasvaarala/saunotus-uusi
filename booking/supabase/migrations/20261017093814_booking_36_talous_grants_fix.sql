-- booking_36_talous_grants_fix (17.10.2026): sisäinen apufunktio _vat_active ei saa olla kutsuttavissa REST-rajapinnasta (get_advisors). Kaikki kutsujat ovat SECURITY DEFINER (postgres). Rollback: booking_36_ROLLBACK.sql
revoke all on function booking._vat_active(numeric) from public, anon, authenticated;
grant execute on function booking._vat_active(numeric) to service_role;
