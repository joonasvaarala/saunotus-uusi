// Lahjakortit (kauppa): puhdas logiikka ilman DOM:ia (node --test). Koodin normalisointi, kenttien tarkistukset, ostoskorin rivit → public_buy_gift_card:n p_items.
// Sopimus: KOODARI_talous_A_D_fi.md §13.2. Palvelin tarkistaa aina uudelleen; nämä ovat vain nopea käyttäjäpalaute.
export const GREETING_MAX = 300;
export const CODE_LEN = 12;
// Koodi: isot kirjaimet, vain A–Z0–9 (viivat, välilyönnit ja muut merkit pois) = booking.gift_code_norm
export const normalizeCode = (s) => String(s ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
// Näyttömuoto XXXX-XXXX-XXXX (täsmälleen 12 merkkiä)
export const formatCode = (s) => { const n = normalizeCode(s); return n.length === CODE_LEN ? `${n.slice(0, 4)}-${n.slice(4, 8)}-${n.slice(8)}` : n; };
// Muotoilu kirjoitettaessa: ryhmät neljään viivalla, enintään 12 merkkiä
export const formatCodeTyping = (s) => normalizeCode(s).slice(0, CODE_LEN).replace(/(.{4})(?=.)/g, '$1-');
export const codeComplete = (s) => normalizeCode(s).length === CODE_LEN;
// Tervehdys: samat ohjausmerkit pois kuin palvelimella (rivinvaihto säilyy), trimmaus; pituus koodipisteinä
export const cleanGreeting = (s) => String(s ?? '').replace(/[\x00-\x09\x0b\x0c\x0e-\x1f\x7f]/g, '').trim();
export const charCount = (s) => [...cleanGreeting(s)].length;
export const rawCharCount = (s) => [...String(s ?? '')].length;
export const greetingState = (s) => { const n = charCount(s); return { n, left: GREETING_MAX - n, over: n > GREETING_MAX }; };
export const validEmail = (e) => /^[^\s@,;]+@[^\s@,;]+\.[^\s@,;]{2,}$/.test(String(e ?? '').trim());
export const validPhone = (p) => { const s = String(p ?? '').trim(); return /^[+\d][\d\s()\-]*$/.test(s) && s.replace(/\D/g, '').length >= 6 && s.replace(/\D/g, '').length <= 15; };
// Summa: enintään kaksi desimaalia, pilkku tai piste; ei tyhjää
export const parseAmount = (v) => { const s = String(v ?? '').trim().replace(',', '.'); return /^\d+(\.\d{1,2})?$/.test(s) ? Math.round(parseFloat(s) * 100) / 100 : null; };
export const round2 = (n) => Math.round((+n + Number.EPSILON) * 100) / 100;

// Rivi = { id, pkg: <paketin code>, amount: <merkkijono avoimelle>, qty, recipientName, recipientEmail, greeting }
export function validateLine(line, pkg) {
  const err = {};
  if (!pkg) { err.pkg = 'pkg'; return err; }
  if (pkg.is_open) { const a = parseAmount(line.amount); if (a == null || a < pkg.min_amount || a > pkg.max_amount) err.amount = 'amount'; }
  const q = Number(line.qty); if (!Number.isInteger(q) || q < 1) err.qty = 'qty';
  if (String(line.recipientName ?? '').trim().length > 120) err.recipientName = 'name';
  if (String(line.recipientEmail ?? '').trim() && !validEmail(line.recipientEmail)) err.recipientEmail = 'email';
  if (greetingState(line.greeting).over) err.greeting = 'greeting';
  return err;
}
export function validateBuyer(b) {
  const err = {};
  if (String(b.name ?? '').trim().length < 2) err.name = 'name';
  if (!validEmail(b.email)) err.email = 'email';
  if (!validPhone(b.phone)) err.phone = 'phone';
  if (!b.terms) err.terms = 'terms';
  return err;
}
export const lineAmount = (line, pkg) => (!pkg ? 0 : pkg.is_open ? (parseAmount(line.amount) ?? 0) : +pkg.price);
export const lineTotal = (line, pkg) => round2(lineAmount(line, pkg) * (Number(line.qty) || 0));
export function totals(lines, pkgs) {
  const by = new Map(pkgs.map((p) => [p.code, p]));
  return { cards: lines.reduce((s, l) => s + (Number(l.qty) || 0), 0), total: round2(lines.reduce((s, l) => s + lineTotal(l, by.get(l.pkg)), 0)) };
}
export const cardsLeft = (lines, max) => Math.max(0, (Number(max) || 10) - lines.reduce((s, l) => s + (Number(l.qty) || 0), 0));
// p_items: yksi alkio per rivi; vain täytetyt kentät; avoimella `amount`, paketilla ei (hinta kiinteä palvelimella)
export function itemsPayload(lines, pkgs) {
  const by = new Map(pkgs.map((p) => [p.code, p]));
  return lines.map((l) => {
    const p = by.get(l.pkg), it = { package: l.pkg, quantity: Math.trunc(Number(l.qty)) || 1 };
    if (p?.is_open) it.amount = parseAmount(l.amount);
    const rn = String(l.recipientName ?? '').trim(), re = String(l.recipientEmail ?? '').trim().toLowerCase(), gr = cleanGreeting(l.greeting);
    if (rn) it.recipient_name = rn; if (re) it.recipient_email = re; if (gr) it.greeting = gr;
    return it;
  });
}
export function buyArgs({ lines, pkgs, buyer, locale }) {
  return { p_items: itemsPayload(lines, pkgs), p_name: buyer.name.trim(), p_email: buyer.email.trim().toLowerCase(), p_phone: buyer.phone.trim(), p_marketing_consent: !!buyer.marketing, p_locale: locale === 'en' ? 'en' : 'fi' };
}
export const validToken = (t) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(t || ''));
