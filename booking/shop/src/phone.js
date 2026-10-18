// Yrityksen puhelinnumero: YKSI vakio. Päätös (Joonas 18.10.2026): näkyvä muoto on kielikohtainen, suomeksi "010 299 2866" ja englanniksi "+358 10 299 2866";
// tel-linkki on kaikkialla tel:+358102992866. Selain-, Node- ja build-koodi lukevat numeron täältä (ei riippuvuuksia). Muualla (sivusto src/lib.mjs ja render.mjs,
// kaupan build, kaupan sanakirjat, tekstien oletukset) numeroa EI kirjoiteta käsin: näkyvä teksti = phoneDisplay(lang), linkki = phoneHref().
// Sähköpostipohjat (Deno, supabase/functions/send-emails/templates.ts) pitävät oman kopion, jonka testi (templates.test.mjs) vertaa tähän vakioon.
export const PHONE_DISPLAY_FI = '010 299 2866';
export const PHONE_DISPLAY_EN = '+358 10 299 2866';
export const PHONE_TEL = '+358102992866';
/** Näkyvä numero kielen mukaan ('en' → kansainvälinen muoto; kaikki muu → suomalainen). */
export const phoneDisplay = (lang) => (lang === 'en' ? PHONE_DISPLAY_EN : PHONE_DISPLAY_FI);
export const phoneHref = () => `tel:${PHONE_TEL}`;
