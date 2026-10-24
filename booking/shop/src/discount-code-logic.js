// Alennus- ja vuosikorttikoodien DOM-riippumaton logiikka (paketti 10 / booking_142). Palvelin on ainoa totuus: hinnat, alennus ja ALV
// lasketaan tietokannassa (public_check_code / public_create_booking_code). Tämän tiedoston laskenta on vain mockia ja testejä varten
// ja noudattaa samaa sääntöä kuin booking._discount_split (prosentti pyöristetään senteiksi, euromäärä enintään kohdesumma,
// jako riveille suhteessa riviin, viimeinen rivi saa pyöristyserotuksen).
import { DISCOUNT_TEXTS } from './discount-texts.js';

export const DISCOUNT_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
// vuosikortin koodi (booking_143, sama kuin booking._generate_annual_card_code): 10 satunnaismerkkiä ilman 0/O, 1/I/L
export const ANNUAL_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
export const ANNUAL_CODE_LENGTH = 10;
export const CODE_RE = /^[A-Z0-9-]{3,40}$/;
// sama kuin booking._norm_code: välilyönnit pois, isot kirjaimet
export const normalizeCode = (code) => String(code ?? '').replace(/\s/g, '').toUpperCase();
export const validCodeFormat = (code) => CODE_RE.test(normalizeCode(code));
export function generatedDiscountCode(random = Math.random) {
  return Array.from({ length: 6 }, () => DISCOUNT_ALPHABET[Math.floor(random() * DISCOUNT_ALPHABET.length)]).join('');
}
export function generatedAnnualCardCode(random) {
  const n = ANNUAL_ALPHABET.length;
  if (random) return Array.from({ length: ANNUAL_CODE_LENGTH }, () => ANNUAL_ALPHABET[Math.floor(random() * n)]).join('');
  let out = '';
  while (out.length < ANNUAL_CODE_LENGTH) {   // kryptografinen satunnaisuus, hylkäysotanta (248 = 8 × 31) → tasajakauma
    for (const v of globalThis.crypto.getRandomValues(new Uint8Array(16))) {
      if (v < 248 && out.length < ANNUAL_CODE_LENGTH) out += ANNUAL_ALPHABET[v % n];
    }
  }
  return out;
}
const r2 = (n) => Math.round(Number(n) * 100) / 100;
// lines: [{ key, product_id, kind: 'reservation'|'addon'|'product', gross }]
export function discountSplit({ kind, value, target_scope = 'order', product_ids = [] }, lines) {
  const ok = (l) => +l.gross > 0 && ['reservation', 'addon', 'product'].includes(l.kind) && (target_scope === 'order' || (product_ids || []).map(Number).includes(Number(l.product_id)));
  const elig = lines.filter(ok);
  const eligible = r2(elig.reduce((a, l) => a + +l.gross, 0));
  if (eligible <= 0) return { eligible: 0, discount: 0, shares: [] };
  const disc = Math.min(Math.max(kind === 'percent' ? r2(eligible * +value / 100) : Math.min(+value, eligible), 0), eligible);
  let left = disc;
  const shares = elig.map((l, i) => {
    let s = i === elig.length - 1 ? left : Math.min(r2(disc * +l.gross / eligible), left);
    s = r2(Math.min(s, +l.gross)); left = r2(left - s);
    return { key: l.key, amount: s };
  });
  return { eligible, discount: r2(disc - left), shares };
}
// Kassan tila: koodi on sidottu henkilömäärään ja lisäpalveluihin; muutos → tarkistus uudelleen.
export const quoteSignature = (persons, addonQty = []) => JSON.stringify([+persons, ...addonQty.map((q) => +q || 0)]);
export const isAnnualQuote = (q) => !!q && q.ok && (q.type === 'annual_card' || q.type === 'annual_code');
export function codeError(lang, res) {
  const E = DISCOUNT_TEXTS[lang === 'en' ? 'en' : 'fi'].codeErrors;
  return E[res?.code] || E.generic;
}
export const CODE_ERROR_CODES = Object.freeze(Object.keys(DISCOUNT_TEXTS.fi.codeErrors).filter((k) => k !== 'generic'));
export const isCodeError = (code) => CODE_ERROR_CODES.includes(code);
