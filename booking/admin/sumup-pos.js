// Pikakassan korttipääte (SumUp Solo, Cloud API, booking_295). Puhtaat apurit ja laitekohtainen muisti.
// Selain ei koskaan näe SumUpin avaimia: kaikki API-kutsut kulkevat sumup-pos-Edge-funktion kautta (fn).
// Lukija on kassan oma laite (ei puhelin): sen reader_id muistetaan localStorageen (ei salaisuus).
// Rakenne: maksutapa on handler 'sumup'; muut kanavat (esim. myöhempi lisälaite) lisätään uusina handlereina ilman muutoksia tähän polkuun.

export const SU_READER_KEY = 'saunotus.pos.sumup.reader';
export const SU_PENDING_KEY = 'saunotus.pos.sumup.pending';
export const SU_PENDING_TTL_MS = 20 * 60 * 1000;
const ID_RE = /^[A-Za-z0-9_-]{4,64}$/;
const PAIRING_RE = /^[A-Za-z0-9]{6,12}$/;

/** Maksutapa näkyy vain, kun palvelin kertoo tilan test tai live. Tila off → ei näy lainkaan. */
export function suEnabled(modes) {
  return !!modes && (modes.sumup_mode === 'test' || modes.sumup_mode === 'live');
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

export function readReader(storage) {
  const r = readJson(storage, SU_READER_KEY);
  if (!r || !ID_RE.test(String(r.reader_id || ''))) return null;
  return { reader_id: String(r.reader_id), name: String(r.name || '').slice(0, 60) };
}
export function saveReader(storage, r) {
  if (!r || !ID_RE.test(String(r.reader_id || ''))) return null;
  const v = { reader_id: String(r.reader_id), name: String(r.name || '').slice(0, 60) };
  writeJson(storage, SU_READER_KEY, v);
  return v;
}
export function clearReader(storage) { writeJson(storage, SU_READER_KEY, null); }

/** Muistettu lukija kelpaa vain, jos se on yhä palvelimen aktiivisten listalla. Muuten oletuslukija, muuten ainoa lukija. */
export function pickReader(saved, list) {
  const rows = Array.isArray(list) ? list.filter((x) => x && ID_RE.test(String(x.reader_id || ''))) : [];
  const pick = (row) => ({ reader_id: row.reader_id, name: row.name || '' });
  const keep = saved && rows.find((x) => x.reader_id === saved.reader_id);
  if (keep) return pick(keep);
  const def = rows.find((x) => x.is_default);
  if (def) return pick(def);
  if (rows.length === 1) return pick(rows[0]);
  return null;
}

/** t1865u: Pikakassa käyttää aina oletuslukijaa (is_default, aktiivinen). Ei oletusta → null (ohje Asetuksiin). */
export function defaultReader(list) {
  const row = (Array.isArray(list) ? list : []).find((x) => x && x.is_default && x.active !== false && ID_RE.test(String(x.reader_id || '')));
  return row ? { reader_id: row.reader_id, name: row.name || '' } : null;
}

export function normalizePairingCode(raw) {
  return String(raw ?? '').replace(/\s+/g, '').toUpperCase();
}
export function validPairingCode(raw) {
  return PAIRING_RE.test(normalizePairingCode(raw));
}

/** Kesken oleva maksu muistiin: välilehti voi latautua uudelleen lukijan odottaessa korttia. */
export function savePending(storage, p, now = Date.now()) {
  const order = Number(p?.order_id), pay = Number(p?.payment_id);
  if (!Number.isSafeInteger(order) || order <= 0 || !Number.isSafeInteger(pay) || pay <= 0) return null;
  const v = { order_id: order, payment_id: pay, at: now };
  writeJson(storage, SU_PENDING_KEY, v);
  return v;
}
export function readPending(storage, now = Date.now()) {
  const p = readJson(storage, SU_PENDING_KEY);
  if (!p || !Number.isSafeInteger(p.order_id) || !Number.isSafeInteger(p.payment_id) || !Number.isFinite(p.at)) return null;
  if (now - p.at > SU_PENDING_TTL_MS || now < p.at - 60000) return null;
  return p;
}
export function clearPending(storage) { writeJson(storage, SU_PENDING_KEY, null); }

/** Edge-funktion tila → näytettävä tila: pending (odotus), paid (onnistui), failed (hylätty), cancelled (peruttu). */
export function suStateOf(res) {
  const s = res?.state;
  return s === 'paid' || s === 'failed' || s === 'cancelled' ? s : 'pending';
}

/** Virhekoodi → pos-tekstin avain. Tuntematon → yleinen. */
export function suErrorKey(code) {
  const map = {
    sumup_off: 'su_off', not_configured: 'su_not_configured', reader_not_paired: 'su_no_reader', reader_offline: 'su_reader_offline',
    provider_unavailable: 'su_unavailable', provider_error: 'su_provider_error', payment_in_progress: 'su_in_progress', forbidden: 'su_forbidden',
  };
  return map[code] || 'su_provider_error';
}
