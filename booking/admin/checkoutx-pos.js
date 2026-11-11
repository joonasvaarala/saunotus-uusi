// Pikakassan kortti puhelimella (CheckoutX / Surfboard demo, booking_286). Puhtaat apurit ja laitekohtainen muisti.
// Selain ei koskaan näe Surfboardin avaimia: kaikki API-kutsut kulkevat checkoutx-pos-Edge-funktion kautta (fn).
// Tämä puhelin = yksi CheckoutX-terminaali. Sen terminalId muistetaan localStorageen (ei salaisuus).

export const CX_TERMINAL_KEY = 'saunotus.pos.checkoutx.terminal';
export const CX_PENDING_KEY = 'saunotus.pos.checkoutx.pending';
export const CX_PENDING_TTL_MS = 20 * 60 * 1000;
export const CX_REGISTER_TTL_MS = 120 * 1000;
const ID_RE = /^[A-Za-z0-9_-]{4,64}$/;
const LINK_PREFIX = 'checkoutx://com.surfboard.checkoutx/';

/** Maksutapa näkyy vain, kun palvelin kertoo tilan test (tuotannossa off → ei näy). */
export function cxEnabled(modes) {
  return !!modes && modes.checkoutx_mode === 'test';
}

function readJson(storage, key) {
  try {
    const raw = storage?.getItem?.(key);
    return raw ? JSON.parse(raw) : null;
  } catch { return null; }
}
function writeJson(storage, key, value) {
  try { if (value == null) storage?.removeItem?.(key); else storage?.setItem?.(key, JSON.stringify(value)); } catch { /* yksityinen tila tms. */ }
}

export function readTerminal(storage) {
  const t = readJson(storage, CX_TERMINAL_KEY);
  if (!t || !ID_RE.test(String(t.terminal_id || ''))) return null;
  return { terminal_id: String(t.terminal_id), label: String(t.label || '').slice(0, 60) };
}
export function saveTerminal(storage, t) {
  if (!t || !ID_RE.test(String(t.terminal_id || ''))) return null;
  const v = { terminal_id: String(t.terminal_id), label: String(t.label || '').slice(0, 60) };
  writeJson(storage, CX_TERMINAL_KEY, v);
  return v;
}
export function clearTerminal(storage) { writeJson(storage, CX_TERMINAL_KEY, null); }

/** Muistettu puhelin kelpaa vain, jos se on yhä palvelimen aktiivisten listalla. Yksi rekisteröity → valitaan suoraan. */
export function pickTerminal(saved, list) {
  const rows = Array.isArray(list) ? list.filter((x) => x && ID_RE.test(String(x.terminal_id || ''))) : [];
  if (saved && rows.some((x) => x.terminal_id === saved.terminal_id)) {
    const row = rows.find((x) => x.terminal_id === saved.terminal_id);
    return { terminal_id: row.terminal_id, label: row.label || saved.label || '' };
  }
  if (rows.length === 1) return { terminal_id: rows[0].terminal_id, label: rows[0].label || '' };
  return null;
}

/** Kesken oleva maksu muistiin: selain voi pudottaa välilehden taustalla (Surfboardin ohje). */
export function savePending(storage, p, now = Date.now()) {
  const order = Number(p?.order_id), pay = Number(p?.payment_id);
  if (!Number.isSafeInteger(order) || order <= 0 || !Number.isSafeInteger(pay) || pay <= 0) return null;
  const v = { order_id: order, payment_id: pay, at: now };
  writeJson(storage, CX_PENDING_KEY, v);
  return v;
}
export function readPending(storage, now = Date.now()) {
  const p = readJson(storage, CX_PENDING_KEY);
  if (!p || !Number.isSafeInteger(p.order_id) || !Number.isSafeInteger(p.payment_id) || !Number.isFinite(p.at)) return null;
  if (now - p.at > CX_PENDING_TTL_MS || now < p.at - 60000) return null;
  return p;
}
export function clearPending(storage) { writeJson(storage, CX_PENDING_KEY, null); }

export function isCheckoutxLink(url) {
  return typeof url === 'string' && url.startsWith(LINK_PREFIX) && !/[\s"'<>]/.test(url);
}

/** Avaa CheckoutX-sovelluksen. Tilapäinen linkki on luotettavampi kuin location-sijoitus (Surfboardin ohje). */
export function openAppLink(url, doc = globalThis.document) {
  if (!isCheckoutxLink(url) || !doc?.createElement) return false;
  const a = doc.createElement('a');
  a.href = url;
  a.style.display = 'none';
  a.rel = 'noopener';
  doc.body.append(a);
  a.click();
  setTimeout(() => a.remove(), 100);
  return true;
}

/** Edge-funktion tilat → näytettävä tila. */
export function cxStateOf(res) {
  const s = res?.state;
  return s === 'paid' || s === 'failed' || s === 'cancelled' ? s : 'pending';
}

/** Virhekoodi → pos-tekstin avain. Tuntematon → yleinen. */
export function cxErrorKey(code) {
  const map = {
    checkoutx_off: 'cx_off', not_configured: 'cx_not_configured', terminal_not_registered: 'cx_no_terminal',
    terminal_not_connected: 'cx_not_connected', provider_unavailable: 'cx_unavailable', provider_error: 'cx_provider_error',
    payment_in_progress: 'cx_in_progress', forbidden: 'cx_forbidden',
  };
  return map[code] || 'cx_provider_error';
}
