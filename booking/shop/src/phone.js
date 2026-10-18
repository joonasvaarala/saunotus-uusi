// Yrityksen puhelinnumero: YKSI vakio. Päätös (Joonas 18.10.2026): näkyvä muoto aina "010 299 2866", linkki aina tel:+358102992866.
// Selain-, Node- ja build-koodi lukevat numeron täältä (ei riippuvuuksia). Muualla (sivusto src/lib.mjs, kaupan build, kaupan sanakirjat, tekstien oletukset)
// numeroa EI kirjoiteta käsin: näkyvä teksti = PHONE_DISPLAY, linkki = phoneHref(). Sähköpostipohjat (Deno, supabase/functions/send-emails/templates.ts)
// pitävät oman kopion, jonka testi (templates.test.mjs) vertaa tähän vakioon.
export const PHONE_DISPLAY = '010 299 2866';
export const PHONE_TEL = '+358102992866';
export const phoneHref = () => `tel:${PHONE_TEL}`;
