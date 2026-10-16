// Kopioi tämä tiedostoksi config.js julkaisussa. anon/publishable-avain saa olla julkinen (oikeudet määrää RLS + kirjautuminen).
// ÄLÄ KOSKAAN laita service role -avainta tähän.
window.BOOKING_CONFIG = {
  url: 'https://<projekti-ref>.supabase.co',
  anonKey: '<anon-tai-publishable-avain>',
  rest: '/rest/v1',
  auth: '/auth/v1',
  schema: 'booking',
};
