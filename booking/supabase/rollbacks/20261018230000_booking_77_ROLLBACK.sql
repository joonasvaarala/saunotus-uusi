-- ROLLBACK booking_77_procountor_exports.
-- Aja vasta kun booking_78:n funktiot on pudotettu (ne viittaavat tauluun).
-- Palauttaa integration_config.procountor-asetuksen ilman daily_enabled- ja api_prefix-avaimia.

drop policy if exists procountor_admin_read on booking.accounting_exports;
drop trigger if exists audit_trg on booking.accounting_exports;
drop trigger if exists accounting_exports_updated on booking.accounting_exports;
drop table if exists booking.accounting_exports;

update booking.integration_config
   set settings = (settings - 'daily_enabled' - 'api_prefix'),
       notes = 'Salaisuudet PROCOUNTOR_CLIENT_ID, PROCOUNTOR_CLIENT_SECRET, PROCOUNTOR_API_KEY. Ks. PLAN_fi.md.',
       updated_at = now()
 where key = 'procountor';
