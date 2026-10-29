-- booking_198c: EN-saapumisvirke luontevaksi ja Turvetorstain sulkemisaika kb:hen (PR #238 jatko, Joonas hyväksynyt 28.10.2026).
-- 1) Viestipohja 2 (EN): "…Sipoo, at {saapumisaika}" renderöityi "…Sipoo, at 31.10.2026 at 16:30" → "…Sipoo, on {saapumisaika}".
--    Tekstissä voi olla NBSP (U+00A0) sanojen välissä, joten välilyönti hyväksytään kumpana tahansa ja säilytetään.
-- 2) kb.opening_hours id 4 (Turvetorstai, to): closes 17:00 → 19:00, kuten content/kb/kb.json (PR #238). Ilman tätä
--    kb-snapshotin uudelleenajo palauttaisi vanhan ajan. Vain rivi, jossa on vielä vanha arvo.
-- Ei lähetä viestejä, ei cronia, ei salaisuuksia.
set local lock_timeout = '5s';

update booking.messages set
  short_en = regexp_replace(short_en, '(Sipoo,[[:space:]\u00a0]+)at([[:space:]\u00a0]+\{saapumisaika\})', '\1on\2', 'g'),
  body_en = regexp_replace(body_en, '(Sipoo,[[:space:]\u00a0]+)at([[:space:]\u00a0]+\{saapumisaika\})', '\1on\2', 'g'),
  subject_en = regexp_replace(subject_en, '(Sipoo,[[:space:]\u00a0]+)at([[:space:]\u00a0]+\{saapumisaika\})', '\1on\2', 'g')
where short_en ~ '(Sipoo,[[:space:]\u00a0]+)at([[:space:]\u00a0]+\{saapumisaika\})'
   or body_en ~ '(Sipoo,[[:space:]\u00a0]+)at([[:space:]\u00a0]+\{saapumisaika\})'
   or subject_en ~ '(Sipoo,[[:space:]\u00a0]+)at([[:space:]\u00a0]+\{saapumisaika\})';

update kb.opening_hours set closes = '19:00'
 where id = 4 and weekday = 4 and session_name = 'Turvetorstai' and closes = '17:00';
