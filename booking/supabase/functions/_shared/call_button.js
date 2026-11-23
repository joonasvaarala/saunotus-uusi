// Terassin hälytysnappi (booking_340/341/342): call-button-press ja call-button-hangup -funktioiden logiikka.
// Puhdas ES-moduuli (Deno + Node >= 20, Web Crypto). Ei omia riippuvuuksia, jotta yksikkötestit ajetaan node --testillä.
//
// Säännöt (Joonas 23.11.2026 t1913u, t1922u, t1923u, t1926u):
//  - Yksi soitto per painallus, ei eskalointia eikä uusintasoittoja. Uusi painallus = uusi soitto (kanta päättää).
//  - Soitetaan VAIN kun svc_call_button_press palauttaa call === true. Kaikki muut tilat (duplicate, disabled,
//    no_recipient, ignored, buffered, unknown_device, …) eivät soita.
//  - Vastaaminen ei ole pakollista: vastaamaton puhelu on normaali tapaus, ei johda mihinkään.
//  - Puhelinnumeroa, salaisuuksia tai 46elks-tunnuksia ei koskaan lokiteta eikä palauteta vastauksessa.

export const ELKS_CALLS_URL = 'https://api.46elks.com/a1/calls';
export const CALL_TIMEOUT_SECONDS = 30;
export const DEFAULT_AUDIO_BASE = 'https://saunotus.fi/call-button/';
const MAX_BODY_BYTES = 4096;
const ELKS_HTTP_TIMEOUT_MS = 10000;

const enc = new TextEncoder();

/** Vakioaikainen merkkijonovertailu (pituusero ei oikaise silmukkaa). */
export function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const x = enc.encode(a), y = enc.encode(b);
  const n = Math.max(x.length, y.length, 1);
  let diff = x.length ^ y.length;
  for (let i = 0; i < n; i++) diff |= (x[i % (x.length || 1)] ?? 0) ^ (y[i % (y.length || 1)] ?? 0);
  return diff === 0 && x.length === y.length;
}

/** HMAC-SHA256 hex. Viesti: "<press_id>.<attempt>". */
export async function hmacHex(secret, message) {
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(message)));
  return Array.from(sig, (b) => b.toString(16).padStart(2, '0')).join('');
}
export const hangupSigMessage = (pressId, attempt) => `${pressId}.${attempt}`;

/** place_name → mp3-tiedoston nimi. Tuntematon paikka → yleinen hälytys ilman paikkaa. */
export function audioFileFor(placeName) {
  const p = String(placeName ?? '').trim().toLowerCase().normalize('NFC');
  if (p === 'mökki' || p === 'mokki') return 'mokki.mp3';
  if (p === 'yläterassi' || p === 'ylaterassi') return 'ylaterassi.mp3';
  return 'halytys.mp3';
}
export function audioUrlFor(placeName, base) {
  let b = String(base || DEFAULT_AUDIO_BASE);
  if (!b.endsWith('/')) b += '/';
  return b + audioFileFor(placeName);
}

/** 46elks-virheteksti lyhyeksi ja ilman numeroita (vastaanottajan numero voi olla virheviestissä). */
export function sanitizeError(s) {
  return String(s ?? '').replace(/\+?\d[\d\s-]{5,}\d/g, '[num]').replace(/[\r\n\t]+/g, ' ').trim().slice(0, 200);
}

/** 46elks whenhangup-tila → svc_call_button_result-tila. failed ilman start-aikaa = ei vastattu (no_answer). */
export function mapHangupState(state, startedAt) {
  const s = String(state ?? '').trim().toLowerCase();
  if (s === 'success') return { status: 'answered', error: null };
  if (s === 'busy') return { status: 'busy', error: null };
  if (s === 'failed') {
    return String(startedAt ?? '').trim() ? { status: 'failed', error: '46elks state=failed' } : { status: 'no_answer', error: null };
  }
  return { status: 'failed', error: sanitizeError(`46elks state=${s || 'missing'}`) };
}

const json = (status, body) => new Response(JSON.stringify(body), {
  status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
});
const envGet = (env, k) => { try { return (env?.get?.(k) ?? '').trim(); } catch { return ''; } };
const noop = () => {};

async function readBody(req) {
  const t = await req.text();
  if (enc.encode(t).length > MAX_BODY_BYTES) throw new Error('too_large');
  return t;
}

function pidOrNull(v) {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isInteger(n) ? n : NaN;
}

/**
 * call-button-press. deps = { rpc(fn, args) → {data, error}, env: {get}, fetch, log? }
 * Gatewaylle aina 200, kun pyyntö on käsitelty (myös ei-soittavat tilat ja epäonnistunut soitto) → ei turhia uusintoja.
 * 5xx vain, kun kantakutsu ei onnistunut (uusinta on turvallinen: kanta deduppaa MAC + pid).
 */
export async function handlePress(req, deps) {
  const log = deps.log ?? ((...a) => console.log(...a));
  if (req.method !== 'POST') return json(405, { ok: false, code: 'method_not_allowed' });
  const secret = envGet(deps.env, 'CALL_BUTTON_WEBHOOK_SECRET');
  if (!secret) { log('call-button-press: misconfigured (CALL_BUTTON_WEBHOOK_SECRET puuttuu)'); return json(500, { ok: false, code: 'misconfigured' }); }
  if (!safeEqual(req.headers.get('x-call-button-secret') ?? '', secret)) return json(401, { ok: false, code: 'unauthorized' });

  let b;
  try { b = JSON.parse(await readBody(req)); } catch { return json(400, { ok: false, code: 'invalid_json' }); }
  if (!b || typeof b !== 'object' || Array.isArray(b)) return json(400, { ok: false, code: 'invalid_json' });
  const pid = pidOrNull(b.pid);
  if (Number.isNaN(pid)) return json(200, { ok: false, code: 'invalid_pid', call: false });

  const { data: r, error } = await deps.rpc('svc_call_button_press', {
    p_mac: typeof b.mac === 'string' ? b.mac : '',
    p_pid: pid,
    p_gateway: typeof b.gateway === 'string' ? b.gateway.slice(0, 100) : null,
    p_event: typeof b.event === 'string' ? b.event.slice(0, 40) : null,
  });
  if (error || !r || typeof r !== 'object') {
    log('call-button-press: rpc_error', sanitizeError(error?.code ?? error?.message ?? 'empty'));
    return json(503, { ok: false, code: 'retry' });
  }
  if (r.ok !== true) {
    log('call-button-press:', r.code ?? 'error', 'press', r.press_id ?? '-');
    return json(200, { ok: false, code: r.code ?? 'error', press_id: r.press_id ?? null, call: false });
  }
  // Soitetaan VAIN kun call === true (tiukka vertailu). duplicate/disabled/no_recipient/ignored/buffered → ei soittoa.
  if (r.call !== true) {
    log('call-button-press: no_call', r.call_status ?? '-', 'press', r.press_id, r.duplicate ? 'duplicate' : '');
    return json(200, { ok: true, call: false, duplicate: r.duplicate === true, call_status: r.call_status ?? null, press_id: r.press_id ?? null });
  }

  const pressId = r.press_id;
  const attempt = Number.isInteger(r.attempt_no) && r.attempt_no > 0 ? r.attempt_no : 1;
  const result = async (status, providerId, err) => {
    const { data, error: e2 } = await deps.rpc('svc_call_button_result', {
      p_press_id: pressId, p_status: status, p_provider_call_id: providerId, p_error: err,
    });
    if (e2 || data?.ok === false) log('call-button-press: result_rpc', sanitizeError(e2?.code ?? e2?.message ?? data?.code ?? ''), 'press', pressId);
    log('call-button-press:', status, 'press', pressId, 'to', r.phone_masked ?? '-', err ? sanitizeError(err) : '');
    return json(200, { ok: true, call: true, call_status: status, press_id: pressId, attempt_no: attempt, ...(err ? { error: sanitizeError(err) } : {}) });
  };

  const from = envGet(deps.env, 'ELKS_FROM_NUMBER');
  const user = envGet(deps.env, 'ELKS_API_USERNAME');
  const pass = envGet(deps.env, 'ELKS_API_PASSWORD');
  const hookSecret = envGet(deps.env, 'CALL_BUTTON_WEBHOOK_SECRET');
  const base = envGet(deps.env, 'SUPABASE_URL').replace(/\/+$/, '');
  if (!from) return await result('failed', null, 'missing_from_number');
  if (!user || !pass) return await result('failed', null, 'missing_elks_credentials');
  if (!base) return await result('failed', null, 'missing_supabase_url');
  const phone = typeof r.phone === 'string' ? r.phone.trim() : '';
  if (!/^\+\d{7,15}$/.test(phone)) return await result('failed', null, 'invalid_phone');

  const sig = await hmacHex(hookSecret, hangupSigMessage(pressId, attempt));
  const whenhangup = `${base}/functions/v1/call-button-hangup?press_id=${encodeURIComponent(String(pressId))}&attempt=${attempt}&sig=${sig}`;
  const form = new URLSearchParams({
    from, to: phone, timeout: String(CALL_TIMEOUT_SECONDS), whenhangup,
    voice_start: JSON.stringify({ play: audioUrlFor(r.place_name, envGet(deps.env, 'CALL_BUTTON_AUDIO_BASE')) }),
  });

  // Yksi POST, ei uusintaa (Joonas t1923u). Epäonnistuminen kirjataan failed-tilaksi.
  let res;
  const ac = typeof AbortController === 'function' ? new AbortController() : null;
  const timer = ac ? setTimeout(() => ac.abort(), ELKS_HTTP_TIMEOUT_MS) : null;
  try {
    res = await deps.fetch(ELKS_CALLS_URL, {
      method: 'POST',
      headers: { authorization: 'Basic ' + btoa(`${user}:${pass}`), 'content-type': 'application/x-www-form-urlencoded' },
      body: form.toString(),
      signal: ac?.signal,
    });
  } catch (e) {
    return await result('failed', null, `network_error: ${sanitizeError(e?.name === 'AbortError' ? 'timeout' : (e?.name ?? 'error'))}`);
  } finally { if (timer) clearTimeout(timer); }

  let text = '';
  try { text = await res.text(); } catch { text = ''; }
  if (!res.ok) return await result('failed', null, `http ${res.status}: ${sanitizeError(text)}`);
  let id = null;
  try { id = JSON.parse(text)?.id ?? null; } catch { id = null; }
  if (typeof id !== 'string' || !id) return await result('failed', null, `http ${res.status}: missing call id`);
  return await result('calling', id, null);
}

/**
 * call-button-hangup (46elks whenhangup). Allekirjoitus ?sig = HMAC(press_id.attempt). Pelkkä kirjaus, ei soittoja.
 * 200 aina kun allekirjoitus kelpaa ja kanta vastasi (myös ok:false) → 46elks ei toista. 503 jos kanta ei vastannut (46elks yrittää uudelleen).
 */
export async function handleHangup(req, deps) {
  const log = deps.log ?? ((...a) => console.log(...a));
  if (req.method !== 'POST') return json(405, { ok: false, code: 'method_not_allowed' });
  const secret = envGet(deps.env, 'CALL_BUTTON_WEBHOOK_SECRET');
  if (!secret) { log('call-button-hangup: misconfigured'); return json(500, { ok: false, code: 'misconfigured' }); }
  const q = new URL(req.url).searchParams;
  const pressRaw = q.get('press_id') ?? '', attemptRaw = q.get('attempt') ?? '', sig = q.get('sig') ?? '';
  if (!/^\d{1,18}$/.test(pressRaw) || !/^\d{1,3}$/.test(attemptRaw)) return json(400, { ok: false, code: 'invalid_params' });
  const expected = await hmacHex(secret, hangupSigMessage(pressRaw, attemptRaw));
  if (!safeEqual(sig.toLowerCase(), expected)) return json(401, { ok: false, code: 'bad_signature' });

  let f;
  try { f = new URLSearchParams(await readBody(req)); } catch { return json(400, { ok: false, code: 'invalid_body' }); }
  const map = mapHangupState(f.get('state'), f.get('start'));
  const providerId = (f.get('id') ?? '').trim().slice(0, 200) || null;
  const { data: r, error } = await deps.rpc('svc_call_button_result', {
    p_press_id: Number(pressRaw), p_status: map.status, p_provider_call_id: providerId, p_error: map.error,
  });
  if (error || !r || typeof r !== 'object') {
    log('call-button-hangup: rpc_error', sanitizeError(error?.code ?? error?.message ?? 'empty'), 'press', pressRaw);
    return json(503, { ok: false, code: 'retry' });
  }
  if (r.ok !== true) {
    log('call-button-hangup:', r.code ?? 'error', 'press', pressRaw);
    return json(200, { ok: false, code: r.code ?? 'error', press_id: Number(pressRaw) });
  }
  log('call-button-hangup:', map.status, 'press', pressRaw, r.late ? 'late' : '');
  const out = { ok: true, press_id: r.press_id ?? Number(pressRaw), call_status: r.call_status ?? map.status, attempt_no: r.attempt_no ?? Number(attemptRaw) };
  if (r.late === true) out.late = true;
  return json(200, out);
}
