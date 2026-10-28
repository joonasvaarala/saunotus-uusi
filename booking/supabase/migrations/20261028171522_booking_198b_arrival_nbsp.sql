-- booking_198b: booking_198:n viestipohjakorjaus, kun "klo" ja {saapumisaika} on erotettu NBSP:llä (U+00A0).
-- booking_198 etsi vain tavallista välilyöntiä, joten pohjat 2 ja 6 jäivät muotoon "klo {saapumisaika}"
-- ja uusi arvo "31.10.2026 klo 16.30" olisi näkynyt "klo 31.10.2026 klo 16.30". Idempotentti.
-- Koskee vain FI-kenttiä (EN-arvo "31.10.2026 at 16:30"; EN-pohjiin ei kosketa).

set local lock_timeout = '5s';

update booking.messages set
  short_fi = regexp_replace(short_fi, '(^|[^[:alnum:]])klo[[:space:]\u00a0]+\{saapumisaika\}', '\1{saapumisaika}', 'g'),
  body_fi = regexp_replace(body_fi, '(^|[^[:alnum:]])klo[[:space:]\u00a0]+\{saapumisaika\}', '\1{saapumisaika}', 'g'),
  subject_fi = regexp_replace(subject_fi, '(^|[^[:alnum:]])klo[[:space:]\u00a0]+\{saapumisaika\}', '\1{saapumisaika}', 'g')
where short_fi ~ '(^|[^[:alnum:]])klo[[:space:]\u00a0]+\{saapumisaika\}'
   or body_fi ~ '(^|[^[:alnum:]])klo[[:space:]\u00a0]+\{saapumisaika\}'
   or subject_fi ~ '(^|[^[:alnum:]])klo[[:space:]\u00a0]+\{saapumisaika\}';
