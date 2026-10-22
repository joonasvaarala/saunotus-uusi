// Vuorotarjousmoottorin puhdas ydin: tunniste, kuivaharjoitus, token ja lähettäjäkytkin.
// Ei verkkoa eikä Deno.env-lukua. Viestit jäävät tietokannan outboxiin; tämä ei lähetä niitä.

export type TickBody = { dryRun?: unknown; dry_run?: unknown; mode?: unknown };

const enc = new TextEncoder();

export function b64url(data: Uint8Array | string): string {
  const bytes = typeof data === "string" ? enc.encode(data) : data;
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function b64urlDecode(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export async function hmacSha256(key: string, payload: string): Promise<string> {
  const cryptoKey = await crypto.subtle.importKey("raw", enc.encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", cryptoKey, enc.encode(payload));
  return b64url(new Uint8Array(sig));
}

export function canonicalToken(offerId: string, staffId: string, expEpoch: number): string {
  return `{"o":"${offerId}","s":"${staffId}","e":${expEpoch}}`;
}

export async function signToken(key: string, offerId: string, staffId: string, expEpoch: number): Promise<string> {
  const payload = b64url(canonicalToken(offerId, staffId, expEpoch));
  const sig = await hmacSha256(key, payload);
  return `${payload}.${sig}`;
}

export async function verifyToken(key: string, token: string, nowEpoch: number): Promise<
  { ok: true; offerId: string; staffId: string; exp: number } | { ok: false; error: "bad_token" | "expired" | "no_key" }
> {
  if (!key) return { ok: false, error: "no_key" };
  const parts = token.split(".");
  if (parts.length !== 2 || !parts[0] || !parts[1]) return { ok: false, error: "bad_token" };
  const expect = await hmacSha256(key, parts[0]);
  if (!timingSafeEqual(expect, parts[1])) return { ok: false, error: "bad_token" };
  let json: { o?: string; s?: string; e?: number };
  try {
    json = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[0])));
  } catch {
    return { ok: false, error: "bad_token" };
  }
  if (!json.o || !json.s || typeof json.e !== "number") return { ok: false, error: "bad_token" };
  if (json.e <= nowEpoch) return { ok: false, error: "expired" };
  return { ok: true, offerId: json.o, staffId: json.s, exp: json.e };
}

export function timingSafeEqual(a: string, b: string): boolean {
  const x = enc.encode(a);
  const y = enc.encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

export async function secretMatches(provided: string, expected: string): Promise<boolean> {
  if (!expected || !provided) return false;
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(provided)),
    crypto.subtle.digest("SHA-256", enc.encode(expected)),
  ]);
  const x = new Uint8Array(a), y = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

export type Intent = "tick" | "respond";

export function requestIntent(method: string, token: string | null): Intent | "invalid" {
  if (method === "GET") return token ? "respond" : "invalid";
  if (method === "POST") return token ? "respond" : "tick";
  return "invalid";
}

// Kuivaharjoitus: kyselyparametri, JSON-runko tai tietokannan kytkin. Kytkin päälle voittaa pyynnön false-arvon.
export function dryRunRequested(url: URL, body: TickBody, settingOn: boolean): boolean {
  if (settingOn) return true;
  const q = url.searchParams.get("dry_run");
  if (q === "1" || q === "true") return true;
  return body.dryRun === true || body.dry_run === true;
}

export type ResponseAction = "accept" | "decline" | "snooze";

export function parseAction(raw: string | null): ResponseAction | null {
  if (raw === "accept" || raw === "decline" || raw === "snooze") return raw;
  return null;
}

// Lähettäjä on stubi. Kytkin pois: jonoon ei kosketa eikä verkkoa ole.
// Kytkin päällä: kutsuja saa merkitä jonon stubiksi, ei lähettää.
export function senderDecision(enabled: boolean): "leave_queued" | "mark_stub" {
  return enabled ? "mark_stub" : "leave_queued";
}

export function respondPage(action: ResponseAction | null, result: string | null): string {
  const title = result === "accepted" ? "Vuoro on sinun."
    : result === "already_taken" ? "Vuoro on jo täytetty."
    : result === "declined" ? "Kieltäytyminen kirjattu."
    : result === "snoozed" ? "Palaat asiaan myöhemmin."
    : result === "bad_token" ? "Linkki ei kelpaa."
    : "Vahvista vastauksesi";
  const snooze = action === "snooze" || !result
    ? `<label>Palaan asiaan, päivä <input name="until" type="date"></label>`
    : "";
  const buttons = result ? "" : `
    <button name="r" value="accept">Hyväksy</button>
    <button name="r" value="decline">Kieltäydy</button>
    <button name="r" value="snooze">Palaan asiaan</button>
    ${snooze}`;
  return `<!doctype html><meta charset="utf-8"><title>${title}</title><p>${title}</p><form method="POST">${buttons}</form><p>–Tapio</p>`;
}
