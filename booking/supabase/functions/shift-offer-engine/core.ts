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

// Sama oven veistos kuin lahjakortin kaarikuvassa (ovi-kaari.jpg / sivuston ovi-kaiverrus).
// GitHub Pages palauttaa kuvan. uusi.saunotus.com/img/ ei sitä vielä tarjoa.
export const DOOR_ARCH_URL = "https://joonasvaarala.github.io/saunotus-uusi/img/ovi-kaiverrus-1024.webp";

export type ShiftOfferCard = {
  offerId: string;
  role: string;
  startsAt: string | null;
  endsAt: string | null;
  deadlineAt: string | null;
  snoozeAllowed: boolean;
};

export type RespondPageInput = {
  result: string | null;
  acted: ShiftOfferCard | null;
  offers: ShiftOfferCard[];
  focusOfferId: string | null;
  snoozeOpenOfferId: string | null;
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

function resultTitle(result: string | null): string {
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

const DONE = new Set(["accepted", "already_taken", "already_filled", "already_yours", "declined", "snoozed"]);

function offerCard(card: ShiftOfferCard, focus: boolean, snoozeOpen: boolean, buttons: boolean): string {
  const role = escapeHtml(roleTitle(card.role));
  const when = escapeHtml(formatShiftWhen(card.startsAt, card.endsAt));
  const deadline = escapeHtml(formatDeadline(card.deadlineAt));
  const id = escapeHtml(card.offerId);
  const snooze = buttons && card.snoozeAllowed
    ? `<details class="snooze"${snoozeOpen ? " open" : ""}><summary class="btn">Palaan asiaan</summary><label class="fld">Päivä<input name="until" type="date" required></label><button class="btn" type="submit" name="r" value="snooze">Vahvista päivä</button></details>`
    : "";
  const form = buttons
    ? `<form method="POST"><input type="hidden" name="offer_id" value="${id}"><button class="btn primary" type="submit" name="r" value="accept">Hyväksy</button><button class="btn" type="submit" name="r" value="decline">Kieltäydy</button>${snooze}</form>`
    : "";
  return `<article class="card offer${focus ? " focus" : ""}">${focus ? `<p class="kicker">Tämä tarjous</p>` : ""}<h2>${role}</h2><p class="when">${when}</p><p class="deadline">Vastaa viimeistään ${deadline}</p>${form}</article>`;
}

// Hallinnan värit ja napit: booking/admin/admin.css. Kaari: sama ovi kuin lahjakortin kuva.
const PAGE_CSS = `
:root{--ink:#2F2923;--text:#4F443A;--muted:#6B5E52;--gold:#7A5530;--green:#2B3A30;--card:#fff;--bg:#F4EFE7;--line:rgba(63,53,44,.18);--ok:#1d4d2b;--okbg:#e8f3ea;--err:#7b1d12;--errbg:#fbeaea;--r:12px}
*,*::before,*::after{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--text);font:400 16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
:focus-visible{outline:3px solid var(--gold);outline-offset:2px}
.top{display:flex;align-items:center;min-height:56px;padding:10px 14px;background:var(--green);color:#fff}
.brand{font-weight:600;letter-spacing:.01em}
main{padding:14px 14px 28px;max-width:480px;margin:0 auto}
.arch{position:relative;width:min(220px,62vw);height:252px;margin:8px auto 16px;border-radius:999px 999px 8px 8px;overflow:hidden;border:1px solid #C49A6C;background:var(--green)}
.arch img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;object-position:center 40%;display:block;font-size:0;color:transparent}
h1{font-size:24px;margin:0 0 12px;color:var(--ink);font-weight:600}
h2{font-size:19px;margin:0 0 6px;color:var(--ink);font-weight:600}
.card{background:var(--card);border:1px solid var(--line);border-radius:var(--r);padding:14px 16px}
.stack{display:grid;gap:12px}
.offer.focus{border-color:var(--green);box-shadow:inset 3px 0 0 var(--green)}
.kicker{margin:0 0 6px;font-size:12px;font-weight:600;letter-spacing:.04em;text-transform:uppercase;color:var(--green)}
.when,.deadline{margin:0 0 8px}
.deadline{color:var(--muted)}
.banner{margin:0 0 12px}
.banner.ok{background:var(--okbg);color:var(--ok);border-color:transparent}
.banner.bad{background:var(--errbg);color:var(--err);border-color:transparent}
form{display:grid;gap:8px}.snooze[open]{display:grid;gap:8px}
button,summary{appearance:none;font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;font-size:16px;font-weight:600;font-style:normal;line-height:1.2;letter-spacing:normal;text-transform:none}
.btn,button.btn,summary.btn{font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;font-size:16px;font-weight:600;font-style:normal;line-height:1.2;letter-spacing:normal;text-transform:none;padding:12px 16px;min-height:48px;border-radius:8px;border:1px solid var(--green);background:#fff;color:var(--green);cursor:pointer;width:100%;display:flex;align-items:center;justify-content:center}
.btn.primary,button.btn.primary{background:var(--green);color:#fff}
.btn.primary:hover{background:#1c2720}
.fld{display:grid;gap:4px;font-size:14px;font-weight:600;color:var(--ink)}
input{font:inherit;padding:10px 12px;border:1px solid #8b7f73;border-radius:8px;background:#fff;color:var(--ink);min-height:44px;width:100%}
summary.btn{list-style:none}
summary.btn::-webkit-details-marker{display:none}
.sign{margin:18px 0 0;color:var(--ink)}
`.replace(/\n/g, "");

export function respondPage(input: RespondPageInput): string {
  const title = resultTitle(input.result);
  const bad = input.result === "bad_token" || input.result === "not_owner" || input.result === "not_recipient";
  const banner = input.result
    ? `<h1>${escapeHtml(title)}</h1>`
    : `<h1>${escapeHtml(title)}</h1>`;
  const acted = input.acted && input.result
    ? offerCard(input.acted, false, false, false)
    : "";
  const hideId = input.result && DONE.has(input.result) ? input.acted?.offerId ?? null : null;
  const offers = [...input.offers]
    .filter((o) => o.offerId !== hideId)
    .sort((a, b) => {
      const af = a.offerId === input.focusOfferId ? 0 : 1;
      const bf = b.offerId === input.focusOfferId ? 0 : 1;
      if (af !== bf) return af - bf;
      return String(a.startsAt ?? "").localeCompare(String(b.startsAt ?? ""));
    });
  const cards = offers.map((o) => offerCard(
    o,
    o.offerId === input.focusOfferId,
    o.offerId === input.snoozeOpenOfferId,
    input.result !== "bad_token",
  )).join("");
  const empty = !acted && cards === "" && !bad
    ? `<article class="card"><p>Ei avoimia tarjouksia.</p></article>`
    : "";
  const tone = input.result === "accepted" || input.result === "already_yours" || input.result === "snoozed" || input.result === "declined"
    ? " ok"
    : input.result ? " bad" : "";
  return `<!doctype html><html lang="fi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${escapeHtml(title)}</title><style>${PAGE_CSS}</style></head><body><header class="top"><span class="brand">Sipoonjoen Perinnesauna</span></header><main><div class="arch"><img src="${DOOR_ARCH_URL}" alt="Sipoonjoen Perinnesaunan oven veistos"></div><div class="banner${tone}">${banner}</div><div class="stack">${acted}${cards}${empty}</div><p class="sign">–Tapio</p></main></body></html>`;
}
