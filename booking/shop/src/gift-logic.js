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

// Rivi = { id, pkg: <paketin code>, amount: <merkkijono avoimelle>, qty, recipientName, recipientEmail, greeting, deliveryTo: 'buyer'|'recipient', coverMessage, sendMode: 'now'|'later', deliverOn: 'YYYY-MM-DD', deliverTime: 'HH:MM' }
export function validateLine(line, pkg, now = new Date()) {
  const err = {};
  if (!pkg) { err.pkg = 'pkg'; return err; }
  if (pkg.is_open) { const a = parseAmount(line.amount); if (a == null || a < pkg.min_amount || a > pkg.max_amount) err.amount = 'amount'; }
  const q = Number(line.qty); if (!Number.isInteger(q) || q < 1) err.qty = 'qty';
  if (greetingState(line.greeting).over) err.greeting = 'invalid_greeting';
  Object.assign(err, validateDelivery(line, pkg.valid_months, now));   // saajan nimi/sähköposti, saateteksti, ajankohta (vain kun 'suoraan saajalle')
  if (err.recipientName === undefined && String(line.recipientName ?? '').trim().length > 120) err.recipientName = 'name';
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
    const to = l.deliveryTo === 'recipient' ? 'recipient' : 'buyer';
    it.delivery_to = to;   // valinta aina eksplisiittisesti (oletus: minulle)
    if (rn) it.recipient_name = rn; if (gr) it.greeting = gr;
    if (to === 'recipient') {   // saajan sähköposti, saateteksti ja ajankohta vain suoraan saajalle -toimituksessa; ajankohta vain kun "Valitse ajankohta"
      if (re) it.recipient_email = re;
      const cv = cleanCover(l.coverMessage); if (cv) it.cover_message = cv;
      if (l.sendMode === 'later' && String(l.deliverOn ?? '').trim()) { it.deliver_on = String(l.deliverOn).trim(); const tm = String(l.deliverTime ?? '').trim(); if (tm) it.deliver_time = tm; }
    }
    return it;
  });
}
export function buyArgs({ lines, pkgs, buyer, locale }) {
  return { p_items: itemsPayload(lines, pkgs), p_name: buyer.name.trim(), p_email: buyer.email.trim().toLowerCase(), p_phone: buyer.phone.trim(), p_marketing_consent: !!buyer.marketing, p_locale: locale === 'en' ? 'en' : 'fi' };
}
export const validToken = (t) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(t || ''));

// ---------- Toimitusvalinta (sopimus §13.11, migraatio booking_46) ----------
// Peilaa palvelimen booking._gc_delivery_resolve:n (sama tarkistusjärjestys ja virhekoodit); palvelin tarkistaa aina uudelleen.
export const COVER_MAX = 1000;
export const DELIVER_TIME_DEFAULT = '09:00';
export const DELIVER_MAX_MONTHS = 12;
const TZ = 'Europe/Helsinki';
const p2 = (n) => String(n).padStart(2, '0');
// Helsingin kellonaika annetusta hetkestä: { date: 'YYYY-MM-DD', time: 'HH:MM' }
export function helsinkiNow(now = new Date()) {
  const f = new Intl.DateTimeFormat('en-GB', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(now);
  const g = (t) => f.find((x) => x.type === t).value;
  return { date: `${g('year')}-${g('month')}-${g('day')}`, time: `${g('hour')}:${g('minute')}` };
}
const validYmd = (s) => { const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s); if (!m) return false; const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3])); return d.getUTCFullYear() === +m[1] && d.getUTCMonth() === +m[2] - 1 && d.getUTCDate() === +m[3]; };
// Helsingin paikallinen päivä+aika → UTC-millisekunnit (kesäaika huomioiden)
export function helsinkiToMs(ymd, hm) {
  const [y, mo, d] = ymd.split('-').map(Number), [h, mi] = hm.split(':').map(Number);
  const guess = Date.UTC(y, mo - 1, d, h, mi);
  const off = (ms) => { const t = helsinkiNow(new Date(ms)); const [yy, mm, dd] = t.date.split('-').map(Number), [hh, nn] = t.time.split(':').map(Number); return Date.UTC(yy, mm - 1, dd, hh, nn) - ms; };
  let ms = guess - off(guess); ms = guess - off(ms); return ms;
}
// date + n kuukautta (kuten Postgres: päivä rajataan kuukauden loppuun)
export function addMonths(ymd, n) {
  const [y, m, d] = ymd.split('-').map(Number), t = (m - 1) + n, yy = y + Math.floor(t / 12), mm = ((t % 12) + 12) % 12;
  const last = new Date(Date.UTC(yy, mm + 1, 0)).getUTCDate();
  return `${yy}-${p2(mm + 1)}-${p2(Math.min(d, last))}`;
}
export const deliverMaxDate = (today, months) => addMonths(today, Math.min(DELIVER_MAX_MONTHS, Math.max(1, Number(months) || 6)));
export const cleanCover = (s) => String(s ?? '').replace(/\r\n/g, '\n').replace(/[\x00-\x09\x0b-\x1f\x7f]/g, '').trim();
export const coverState = (s) => { const n = [...cleanCover(s)].length; return { n, left: COVER_MAX - n, over: n > COVER_MAX }; };
// Palauttaa { ok: true, value: { delivery_to, cover_message, deliver_on, deliver_time } } tai { ok: false, code } (palvelimen virhekoodi)
export function resolveDelivery({ to, recipientEmail, cover, on, time, months = 6, now = new Date() } = {}) {
  const bad = (code) => ({ ok: false, code });
  const re = String(recipientEmail ?? '').trim() || null;
  let v = String(to ?? '').trim().toLowerCase() || (re ? 'recipient' : 'buyer');
  if (v !== 'buyer' && v !== 'recipient') return bad('invalid_delivery_to');
  if (v === 'buyer') return { ok: true, value: { delivery_to: 'buyer', cover_message: null, deliver_on: null, deliver_time: null } };
  if (!re) return bad('recipient_email_required');
  const c = cleanCover(cover) || null;
  if (c && [...c].length > COVER_MAX) return bad('invalid_cover_message');
  const t0 = helsinkiNow(now), today = t0.date;
  let onTxt = String(on ?? '').trim() || null, timeTxt = String(time ?? '').trim() || null, d = null, t = null;
  if (onTxt) {
    const m = /^(\d{4}-\d{2}-\d{2})(?:[T ](\d{2}:\d{2}))?$/.exec(onTxt);
    if (!m || !validYmd(m[1])) return bad('invalid_deliver_on');
    d = m[1]; if (m[2]) timeTxt = timeTxt || m[2];
  } else if (timeTxt) return bad('invalid_deliver_on');
  if (timeTxt) { if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(timeTxt)) return bad('invalid_deliver_time'); t = timeTxt; }
  if (d) {
    if (d < today) return bad('deliver_on_past');
    if (t && helsinkiToMs(d, t) < now.getTime() - 5 * 60 * 1000) return bad('deliver_on_past');
    if (d > deliverMaxDate(today, months)) return bad('deliver_on_too_far');
    if (d === today && !t) d = null;   // tänään ilman kellonaikaa = heti
  }
  return { ok: true, value: { delivery_to: 'recipient', cover_message: c, deliver_on: d, deliver_time: t } };
}
// Lomakerivin toimitusvalinta → resolveDelivery-parametrit (ajankohta vain kun "Valitse ajankohta")
export const lineDeliveryInput = (l, months, now) => ({ to: l.deliveryTo || 'buyer', recipientEmail: l.recipientEmail, cover: l.coverMessage, on: l.sendMode === 'later' ? l.deliverOn : '', time: l.sendMode === 'later' ? l.deliverTime : '', months, now });
// Kenttäkohtaiset virheet: { recipientName?, recipientEmail?, cover?, deliverOn?, deliverTime? } – arvo = virhekoodi (teksti err.<koodi>)
export function validateDelivery(l, months, now = new Date()) {
  const err = {};
  if ((l.deliveryTo || 'buyer') !== 'recipient') return err;
  if (!String(l.recipientName ?? '').trim()) err.recipientName = 'recipient_name_required';
  const re = String(l.recipientEmail ?? '').trim();
  if (!re) err.recipientEmail = 'recipient_email_required'; else if (!validEmail(re)) err.recipientEmail = 'invalid_email';
  if (coverState(l.coverMessage).over) err.cover = 'invalid_cover_message';
  if (l.sendMode === 'later') {
    if (!String(l.deliverOn ?? '').trim()) err.deliverOn = 'invalid_deliver_on';
    else {
      const r = resolveDelivery({ ...lineDeliveryInput(l, months, now), recipientEmail: re || 'x@x.fi' });
      if (!r.ok) { if (r.code === 'invalid_deliver_time') err.deliverTime = r.code; else if (['invalid_deliver_on', 'deliver_on_past', 'deliver_on_too_far'].includes(r.code)) err.deliverOn = r.code; else if (r.code === 'invalid_cover_message') err.cover = r.code; }
    }
  }
  return err;
}
// Palvelimen virhekoodi → rivin kenttä (jonka alle virhe näytetään); null = ei rivikohtainen
export const SERVER_FIELD = { deliver_on_past: 'deliverOn', deliver_on_too_far: 'deliverOn', invalid_deliver_on: 'deliverOn', invalid_deliver_time: 'deliverTime', invalid_cover_message: 'cover', invalid_greeting: 'greeting', recipient_email_required: 'recipientEmail', invalid_email: 'recipientEmail' };
export const DELIVERY_ERROR_CODES = Object.keys(SERVER_FIELD);

// Paketin sisältölista (public_gift_card_packages.items[]): FI = label, EN = label_en (migraatio booking_45). Vain rivit joilla on nimi kyseisellä kielellä (ei FI-nimeä EN-sivulle).
export const itemLabels = (p, lang) => (Array.isArray(p?.items) ? p.items : []).map((it) => String((lang === 'en' ? it?.label_en : it?.label) ?? '').trim()).filter(Boolean);

// ---------- Yksi koodikenttä: oma kortti vs. kumppanin lahjakortti (sopimus §13.12, migraatiot booking_47/48) ----------
// Palvelin on totuus (public_resolve_gift_code); nämä ovat vain nopea käyttäjäpalaute ja mockin peili.
export const CODE_MIN = 6;
export const CODE_MAX = 24;
export const codeValid = (s) => { const n = normalizeCode(s).length; return n >= CODE_MIN && n <= CODE_MAX; };
// Julkiset lähteet (public_submit_voucher_claim, booking_173: Kokemuskauppa, Offerilla, Elämyslahjat; Kiitoskauppa = käytännössä oma lahjakortti → ei valinnoissa,
// vanhat Kiitoskauppa-rivit näkyvät edelleen nimellä). partner_other ei julkisesti. Järjestys kuten _vc_sources().
export const CLAIM_SOURCES = ['kokemuskauppa', 'offerilla', 'elamyslahjat'];
export const SOURCE_LABELS = { elamyslahjat: 'Elämyslahjat', kokemuskauppa: 'Kokemuskauppa', kiitoskauppa: 'Kiitoskauppa', offerilla: 'Offerilla', partner_other: 'Muu kumppani' };
// Myyjäkohtainen maksutapa (booking.payment_methods, booking_173): partner_voucher_<myyjä>; vanhat/muut → partner_voucher
export const claimMethod = (source) => (CLAIM_SOURCES.includes(source) ? `partner_voucher_${source}` : 'partner_voucher');
// Lähde koodin muodosta (peilaa booking._vc_guess, booking_173): KK-alku → Kokemuskauppa (varma), OK-muoto → Offerilla (varma),
// Elämyslahjat-muoto → Elämyslahjat (todennäköinen), muu → Offerilla ehdotuksena (low). Tyhjä → ei arvausta.
export function guessSource(code) {
  const n = normalizeCode(code);
  if (!n) return { source: null, confidence: null };
  if (/^KK/.test(n)) return { source: 'kokemuskauppa', confidence: 'high' };
  if (/^OK[0-9]{5}[A-Z]{3}$/.test(n)) return { source: 'offerilla', confidence: 'high' };
  if (/^[A-Z0-9]{12}$/.test(n) && /[^3479ACEFHJKLMNPRTUVWXY]/.test(n)) return { source: 'elamyslahjat', confidence: 'medium' };
  return { source: 'offerilla', confidence: 'low' };
}
// DOM-lapset ilman tyhjiä: replaceChildren/append muuttaa null/undefined tekstiksi "null"/"undefined" → suodatetaan aina ennen (booking_173-korjaus)
export const kids = (...a) => a.flat(Infinity).filter((x) => x != null && x !== false && x !== '');
// Varoitus "koodi näyttää toisen myyjän koodilta" vain varmalla / todennäköisellä tunnistuksella (ei pelkästä Offerilla-ehdotuksesta)
export const isMismatch = (code, source) => { const g = guessSource(code); return !!g.source && g.source !== source && (g.confidence === 'high' || g.confidence === 'medium'); };
// Lunastuspyynnön näyttötila tilaussivulla (public_get_order_voucher_claims): received | redeemed | problem | cancelled | expired.
// Teksti-avain: vc.st.<tila> tai ongelmassa vc.problem.<problem_code> (tuntematon koodi → other). Ei aikarajoja (booking_48).
export const PROBLEM_CODES = ['invalid_code', 'expired_code', 'already_used', 'other'];
export function claimView(c) {
  const st = ['received', 'redeemed', 'problem', 'cancelled', 'expired'].includes(c?.public_status) ? c.public_status : 'received';
  const pc = st === 'problem' ? (PROBLEM_CODES.includes(c.problem_code) ? c.problem_code : 'other') : null;
  return { claimNo: c?.claim_no, state: st, textKey: st === 'problem' ? `vc.problem.${pc}` : `vc.st.${st}`, problemCode: pc, canUpdate: c?.can_update_code === true && (st === 'received' || st === 'problem'),
    source: c?.source ?? null, sourceLabel: c?.source_label || SOURCE_LABELS[c?.source] || '', methodLabel: c?.payment_method_label || '', codeMasked: c?.code_masked || '', amount: st === 'redeemed' && c?.amount != null ? +c.amount : null };
}
// Virhekoodi → tekstiavain: kumppanipolun omat (vc.err.*) ensin, muuten tavallinen lahjakorttivirhe (err.*), muuten err.generic
export function errorKey(code, has) {
  if (!code) return 'err.generic';
  return has(`vc.err.${code}`) ? `vc.err.${code}` : has(`err.${code}`) ? `err.${code}` : 'err.generic';
}
// Koodin käsittely yhdellä kentällä. api = createGiftApi (resolve/apply/submitClaim/updateClaimCode). Palauttaa aina { type, ... }:
//   applied (oma kortti käytetty) | blocked (oma kortti, ei lunastettavissa: reason) | choose_source (tuntematon + kumppanilunastus päällä) | not_found (tuntematon, kumppanilunastus pois) | error (code)
export async function resolveCode({ api, token, code, amount = null }) {
  const r = await api.resolve(code);
  if (r?.notReady) return { type: 'error', code: 'notReady' };
  if (!r?.ok) return { type: 'error', code: r?.code || 'generic', where: 'resolve' };
  if (r.kind === 'own') {
    if (r.redeemable === false) return { type: 'blocked', reason: r.not_redeemable_reason || 'redeem_disabled', card: r };
    const a = await api.apply({ token, code, amount });
    if (a?.notReady) return { type: 'error', code: 'notReady' };
    return a?.ok ? { type: 'applied', result: a } : { type: 'error', code: a?.code || 'generic', where: 'apply' };
  }
  if (r.kind !== 'unknown') return { type: 'error', code: 'generic' };
  if (!r.partner_claims_enabled) return { type: 'not_found' };
  const known = (Array.isArray(r.sources) ? r.sources : []).map((s) => s.code).filter((c) => CLAIM_SOURCES.includes(c));
  const sources = (known.length ? known : CLAIM_SOURCES).map((c) => { const s = (r.sources || []).find((x) => x.code === c); return { code: c, label: s?.label || SOURCE_LABELS[c], label_en: s?.label_en || s?.label || SOURCE_LABELS[c] }; });
  return { type: 'choose_source', sources, suggested: CLAIM_SOURCES.includes(r.suggested_source) ? r.suggested_source : null, confidence: r.suggestion_confidence || null };
}
export async function submitClaim({ api, token, code, source }) {
  if (!CLAIM_SOURCES.includes(source)) return { type: 'error', code: 'invalid_source' };
  const r = await api.submitClaim({ token, code, source });
  if (r?.notReady) return { type: 'error', code: 'notReady' };
  return r?.ok ? { type: 'claimed', claimNo: r.claim_no, already: r.already === true, sourceLabel: r.source_label || SOURCE_LABELS[source], codeMasked: r.code_masked || '', mismatch: r.source_mismatch === true,
    source: r.source || source, method: r.payment_method || claimMethod(r.source || source), methodLabel: r.payment_method_label || '' } : { type: 'error', code: r?.code || 'generic' };
}
// Koodin ja/tai myyjän korjaus ennen lunastusta. Tyhjä koodi = vain myyjän vaihto (palvelin pitää vanhan koodin, booking_173).
// current = pyynnön nykyinen myyjä: vanha (esim. Kiitoskauppa) kelpaa vain, jos sitä ei vaihdeta.
export async function updateClaimCode({ api, token, claimNo, code, source, current = null }) {
  if (source && !CLAIM_SOURCES.includes(source) && source !== current) return { type: 'error', code: 'invalid_source' };
  const empty = !normalizeCode(code);
  if (empty && (!source || source === current)) return { type: 'error', code: 'invalid_code' };
  if (!empty && !codeValid(code)) return { type: 'error', code: 'invalid_code' };
  const r = await api.updateClaimCode({ token, claimNo, code, source });
  if (r?.notReady) return { type: 'error', code: 'notReady' };
  return r?.ok ? { type: 'updated', claimNo: r.claim_no, sourceLabel: r.source_label || '', codeMasked: r.code_masked || '', mismatch: r.source_mismatch === true, methodLabel: r.payment_method_label || '' } : { type: 'error', code: r?.code || 'generic' };
}
