-- booking_153 (a): Otto (public.staff 2975633f-c53f-48d6-8a38-41cae0be5a83) Resendin testivastaanottajalistalle.
-- AJETAAN VAIN JOONAKSEN LUVALLA, käsin. Migraatio EI tee tätä.
-- Lisää Oton sähköpostin booking.integration_config('resend').settings.test_recipients -listaan, jos lista on käytössä (taulukko)
-- eikä osoite ole siellä jo. Tyhjä/puuttuva lista = ei rajausta, jolloin mitään ei muuteta. Uudelleenajettava.
-- Lisäksi moottorin sähköpostit vaativat booking.settings shift_offer.email_enabled = true (erillinen päätös).
update booking.integration_config c
   set settings = jsonb_set(c.settings, '{test_recipients}', (c.settings -> 'test_recipients') || to_jsonb(lower(btrim(s.email))))
  from public.staff s
 where c.key = 'resend'
   and s.id = '2975633f-c53f-48d6-8a38-41cae0be5a83'
   and nullif(btrim(s.email), '') is not null
   and jsonb_typeof(c.settings -> 'test_recipients') = 'array'
   and not exists (select 1 from jsonb_array_elements_text(c.settings -> 'test_recipients') e where lower(btrim(e)) = lower(btrim(s.email)));

-- Peruminen:
-- update booking.integration_config c set settings = jsonb_set(c.settings, '{test_recipients}',
--   coalesce((select jsonb_agg(e) from jsonb_array_elements_text(c.settings -> 'test_recipients') e
--              where lower(btrim(e)) <> (select lower(btrim(s.email)) from public.staff s where s.id = '2975633f-c53f-48d6-8a38-41cae0be5a83')), '[]'::jsonb))
--  where c.key = 'resend' and jsonb_typeof(c.settings -> 'test_recipients') = 'array';
