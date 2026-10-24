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

export type ShiftRoute = "offers" | "respond" | "redirect" | "options" | "tick" | "invalid";

// Sivut, joilta selain saa kutsua JSON-rajapintaa. Origin on skeema + isäntä, ei polkua.
export const SHIFT_OFFER_PAGE_ORIGINS = [
  "https://joonasvaarala.github.io",
  "https://saunotus.fi",
  "https://www.saunotus.fi",
];

export const DEFAULT_SHIFT_OFFER_PAGE_BASE = "https://joonasvaarala.github.io/saunotus-uusi";

export function pageBase(envValue: string | undefined): string {
  const raw = (envValue ?? "").trim() || DEFAULT_SHIFT_OFFER_PAGE_BASE;
  return raw.replace(/\/+$/, "");
}

export function offerPageLocation(base: string, token: string): string {
  return `${base.replace(/\/+$/, "")}/vuoro/?token=${encodeURIComponent(token)}`;
}

export function corsHeaders(origin: string | null): Record<string, string> | null {
  if (!origin || !SHIFT_OFFER_PAGE_ORIGINS.includes(origin)) return null;
  return {
    "access-control-allow-origin": origin,
    "access-control-allow-methods": "GET, POST, OPTIONS",
    "access-control-allow-headers": "content-type",
    vary: "origin",
  };
}

export function shiftRoute(method: string, pathname: string, token: string | null): ShiftRoute {
  const api = pathname.endsWith("/api/offers") || pathname.endsWith("/api/respond");
  if (api && method === "OPTIONS") return "options";
  if (pathname.endsWith("/api/offers")) return method === "GET" ? "offers" : "invalid";
  if (pathname.endsWith("/api/respond")) return method === "POST" ? "respond" : "invalid";
  if (method === "GET" && token) return "redirect";
  if (method === "POST" && !token) return "tick";
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

// Yleinen lähettäjäkytkin. Pois: jonoa ei varata eikä Metalle soiteta.
// Päällä: kutsuja ajaa kanavasovittimen. Oletus on pois.
export function senderDecision(enabled: boolean): "leave_queued" | "deliver" {
  return enabled ? "deliver" : "leave_queued";
}

// Päivämäärä YYYY-MM-DD kello 08:00 Europe/Helsinki, ISO-aikaleimana.
// Kesä- ja talviaika tulevat vyöhykkeestä; kiinteää +02:00-siirtoa ei käytetä.
export function helsinkiMorning(isoDate: string): string | null {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(isoDate)) return null;
  const year = Number(isoDate.slice(0, 4));
  const month = Number(isoDate.slice(5, 7));
  const day = Number(isoDate.slice(8, 10));
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  const utcGuess = Date.UTC(year, month - 1, day, 8, 0, 0);
  const guess = new Date(utcGuess);
  if (guess.getUTCFullYear() !== year || guess.getUTCMonth() !== month - 1 || guess.getUTCDate() !== day) return null;
  const fmt = new Intl.DateTimeFormat("en-US", {
    timeZone: "Europe/Helsinki",
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
  const wallOffset = (at: Date) => {
    const parts = fmt.formatToParts(at);
    const n = (t: string) => Number(parts.find((p) => p.type === t)?.value);
    return Date.UTC(n("year"), n("month") - 1, n("day"), n("hour"), n("minute"), n("second")) - at.getTime();
  };
  const result = new Date(utcGuess - wallOffset(guess));
  const check = fmt.formatToParts(result);
  const n = (t: string) => Number(check.find((p) => p.type === t)?.value);
  if (n("year") !== year || n("month") !== month || n("day") !== day || n("hour") !== 8 || n("minute") !== 0) return null;
  return result.toISOString();
}

export function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

export type ShiftOfferCard = {
  offerId: string;
  role: string;
  startsAt: string | null;
  endsAt: string | null;
  deadlineAt: string | null;
  snoozeAllowed: boolean;
};

const WD_FI = ["sunnuntai", "maanantai", "tiistai", "keskiviikko", "torstai", "perjantai", "lauantai"];

export function roleTitle(role: string | null): string {
  if (role === "heater") return "Lämmitysvuoro";
  if (role === "reception") return "Vastaanottovuoro";
  if (role === "therapist") return "Hoitajavuoro";
  return "Vuoro";
}

function helsinkiParts(iso: string): { y: number; m: number; d: number; hh: string; mi: string } | null {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  const fmt = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/Helsinki",
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
  const parts = fmt.formatToParts(date);
  const pick = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  const y = Number(pick("year"));
  const m = Number(pick("month"));
  const d = Number(pick("day"));
  if (!y || !m || !d) return null;
  return { y, m, d, hh: pick("hour") === "24" ? "00" : pick("hour"), mi: pick("minute") };
}

export function formatShiftWhen(startsAt: string | null, endsAt: string | null): string {
  if (!startsAt) return "Ajankohta puuttuu";
  const start = helsinkiParts(startsAt);
  if (!start) return "Ajankohta puuttuu";
  const wd = WD_FI[new Date(Date.UTC(start.y, start.m - 1, start.d)).getUTCDay()];
  const day = wd.charAt(0).toUpperCase() + wd.slice(1);
  const date = `${String(start.d).padStart(2, "0")}.${String(start.m).padStart(2, "0")}.${start.y}`;
  let clock = `${start.hh}:${start.mi}`;
  if (endsAt) {
    const end = helsinkiParts(endsAt);
    if (end) clock += `–${end.hh}:${end.mi}`;
  }
  return `${day} ${date} klo ${clock}`;
}

export function formatDeadline(deadlineAt: string | null): string {
  if (!deadlineAt) return "pian";
  const w = helsinkiParts(deadlineAt);
  if (!w) return "pian";
  return `${String(w.d).padStart(2, "0")}.${String(w.m).padStart(2, "0")}.${w.y} klo ${w.hh}:${w.mi}`;
}

export function resultTitle(result: string | null): string {
  if (result === "accepted") return "Vuoro on sinun";
  if (result === "already_taken" || result === "already_filled") return "Vuoro on jo täytetty";
  if (result === "already_yours") return "Vuoro on jo sinun";
  if (result === "declined") return "Kieltäytyminen kirjattu";
  if (result === "snoozed") return "Palaat asiaan myöhemmin";
  if (result === "bad_token") return "Linkki ei kelpaa";
  if (result === "not_owner" || result === "not_recipient") return "Tähän vuoroon ei voi vastata";
  if (result === "offer_closed") return "Tarjous ei ole enää auki";
  if (result === "snooze_not_allowed") return "Tähän vuoroon ei voi palata myöhemmin";
  if (result === "invalid_state") return "Vastausta ei voitu kirjata";
  return "Vahvista vastauksesi";
}

export type OfferJson = {
  offer_id: string;
  role: string;
  role_title: string;
  when: string;
  deadline: string;
  snooze_allowed: boolean;
};

export function offerJson(card: ShiftOfferCard): OfferJson {
  return {
    offer_id: card.offerId,
    role: card.role,
    role_title: roleTitle(card.role),
    when: formatShiftWhen(card.startsAt, card.endsAt),
    deadline: formatDeadline(card.deadlineAt),
    snooze_allowed: card.snoozeAllowed,
  };
}
