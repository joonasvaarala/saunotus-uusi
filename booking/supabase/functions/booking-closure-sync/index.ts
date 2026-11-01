// supabase/functions/booking-closure-sync/index.ts
// Sulkukalenterit (Google Calendar, vain luku) -> booking.space_blocks. Ajetaan pg_cron + pg_net -kutsulla (ehdotus: booking_18_CRON_PROPOSAL.sql) tai käsin.
//
// Autentikointi (sama malli kuin calendar-sync, samat secretit -> ei uusia salaisuuksia):
//   * kutsuja: header x-sync-secret = env SYNC_CRON_SECRET (vakioaikavertailu)
//   * Google: palvelutili, env GOOGLE_SERVICE_ACCOUNT_JSON, JWT bearer -> OAuth, scope calendar.events
//     -> jokainen sulkukalenteri on jaettava palvelutilin sähköpostiosoitteelle: lukuun riittää "See all event details",
//        hallinta -> kalenteri -kirjoitukseen tarvitaan "Make changes to events" (Tee muutoksia tapahtumiin).
// Pyyntö (POST, JSON, kaikki valinnaisia): { "dryRun": true, "force": false, "calendars": ["hoidot","rauni"], "writeback": true, "probeWrite": false }
//   probeWrite: true -> vain kirjoitusoikeustesti (DELETE olemattomalle tapahtumalle: 404/410 = kirjoitusoikeus, 403 = vain luku); ei muuta mitään.
// Vastaus: vain laskurit ja virhekoodit (ei tapahtumien otsikoita, kalenteri-id:itä tai avaimia).

import { createClient } from "npm:@supabase/supabase-js@2";
import { type Db, type GEvent, type Google, type GWriteEvent, HttpError, probeWrite, runSync, runWriteback, safeError } from "./core.ts";

const CAL_API = "https://www.googleapis.com/calendar/v3";
// calendar.events: lukeminen + tapahtumien kirjoitus (hallinta -> kalenteri). Jos kalenterin jako on vain luku, kirjoitukset palauttavat 403 -> jono merkitsee no_write_access ja lukusynkka toimii normaalisti.
const SCOPE = "https://www.googleapis.com/auth/calendar.events";
const PAGE_SIZE = 2500;
const MAX_PAGES = 50;

const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "booking-closure-sync", event, ...data }));
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function secretMatches(provided: string, expected: string): Promise<boolean> {
  if (!expected || !provided) return false;
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([crypto.subtle.digest("SHA-256", enc.encode(provided)), crypto.subtle.digest("SHA-256", enc.encode(expected))]);
  const x = new Uint8Array(a), y = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

function b64url(data: ArrayBuffer | Uint8Array | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// ---------- Google-palvelutili: JWT bearer -> access token ----------
interface ServiceAccount { client_email: string; private_key: string; token_uri?: string }
let cachedToken: { value: string; exp: number } | null = null;

function loadServiceAccount(): ServiceAccount {
  const raw = Deno.env.get("GOOGLE_SERVICE_ACCOUNT_JSON");
  if (!raw) throw new Error("GOOGLE_SERVICE_ACCOUNT_JSON is not set");
  let sa: ServiceAccount;
  try { sa = JSON.parse(raw); } catch { throw new Error("GOOGLE_SERVICE_ACCOUNT_JSON is not valid JSON"); }
  if (!sa.client_email || !sa.private_key) throw new Error("service account JSON is missing client_email/private_key");
  return sa;
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const body = pem.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
}

async function getAccessToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.exp - 60 > now) return cachedToken.value;
  const sa = loadServiceAccount();
  const tokenUri = sa.token_uri ?? "https://oauth2.googleapis.com/token";
  const unsigned = `${b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }))}.${b64url(JSON.stringify({ iss: sa.client_email, scope: SCOPE, aud: tokenUri, iat: now, exp: now + 3600 }))}`;
  const key = await importPrivateKey(sa.private_key);
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned));
  const res = await fetch(tokenUri, {
    method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: `${unsigned}.${b64url(sig)}` }),
  });
  if (!res.ok) throw new Error(`google_token_exchange_failed_${res.status}`);   // vastauksen runkoa ei toisteta
  const json = await res.json();
  cachedToken = { value: json.access_token, exp: now + Number(json.expires_in ?? 3600) };
  return cachedToken.value;
}

async function gget(url: URL): Promise<{ items?: GEvent[]; nextPageToken?: string }> {
  for (let attempt = 0;; attempt++) {
    const res = await fetch(url, { headers: { authorization: `Bearer ${await getAccessToken()}` } });
    if (res.ok) return await res.json();
    let reason = "";
    try { reason = (await res.json())?.error?.errors?.[0]?.reason ?? ""; } catch { /* ignore */ }
    if (res.status === 401 && attempt === 0) { cachedToken = null; continue; }
    const retryable = res.status === 429 || res.status >= 500 || (res.status === 403 && (reason === "rateLimitExceeded" || reason === "userRateLimitExceeded"));
    if (retryable && attempt < 4) { await sleep(Math.min(16000, 500 * 2 ** attempt) + Math.floor(Math.random() * 250)); continue; }
    throw new HttpError(res.status, reason);
  }
}


async function gwrite(method: "POST" | "PATCH" | "DELETE", url: URL, body?: unknown): Promise<{ status: number }> {
  for (let attempt = 0;; attempt++) {
    const res = await fetch(url, {
      method, headers: { authorization: `Bearer ${await getAccessToken()}`, ...(body ? { "content-type": "application/json" } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (res.ok) { await res.body?.cancel(); return { status: res.status }; }
    let reason = "";
    try { reason = (await res.json())?.error?.errors?.[0]?.reason ?? ""; } catch { /* ignore */ }
    if (res.status === 401 && attempt === 0) { cachedToken = null; continue; }
    if (res.status === 409 || res.status === 404 || res.status === 410) return { status: res.status };   // kutsuja tulkitsee (idempotenssi)
    const retryable = res.status === 429 || res.status >= 500 || (res.status === 403 && (reason === "rateLimitExceeded" || reason === "userRateLimitExceeded"));
    if (retryable && attempt < 4) { await sleep(Math.min(16000, 500 * 2 ** attempt) + Math.floor(Math.random() * 250)); continue; }
    throw new HttpError(res.status, reason);
  }
}
const evUrl = (cal: string, id?: string) => new URL(`${CAL_API}/calendars/${encodeURIComponent(cal)}/events${id ? `/${encodeURIComponent(id)}` : ""}`);

const google: Google = {
  async listEvents(calendarId, timeMin, timeMax) {
    const items: GEvent[] = [];
    let pageToken: string | undefined;
    for (let page = 0; page < MAX_PAGES; page++) {
      const url = new URL(`${CAL_API}/calendars/${encodeURIComponent(calendarId)}/events`);
      url.searchParams.set("singleEvents", "true");        // toistuvat -> instanssit (oma id / instanssi)
      url.searchParams.set("showDeleted", "false");
      url.searchParams.set("timeMin", timeMin);
      url.searchParams.set("timeMax", timeMax);
      url.searchParams.set("maxResults", String(PAGE_SIZE));
      url.searchParams.set("fields", "nextPageToken,items(id,status,summary,updated,start,end,extendedProperties/private)");   // vain tarvittavat kentät
      if (pageToken) url.searchParams.set("pageToken", pageToken);
      const res = await gget(url);
      items.push(...(res.items ?? []));
      pageToken = res.nextPageToken;
      if (!pageToken) return items;
    }
    throw new Error("pagination_limit_exceeded");
  },
  async insertEvent(cal, ev: GWriteEvent) {
    const r = await gwrite("POST", evUrl(cal), ev);
    return r.status === 409 ? "exists" : "created";
  },
  async patchEvent(cal, id, ev) {
    const r = await gwrite("PATCH", evUrl(cal, id), ev);
    return r.status === 404 || r.status === 410 ? "missing" : "patched";
  },
  async deleteEvent(cal, id) {
    const r = await gwrite("DELETE", evUrl(cal, id));
    return r.status === 404 || r.status === 410 ? "gone" : "deleted";
  },
  async probeWrite(cal) {
    try { await gwrite("DELETE", evUrl(cal, "bkprobe0000000000")); return "write_ok"; }   // olematon id: 404/410 -> kirjoitusoikeus; 403 -> ei
    catch (err) { if (err instanceof HttpError && err.status === 403) return "no_write_access"; throw err; }
  },
};

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  if (!(await secretMatches(req.headers.get("x-sync-secret") ?? "", Deno.env.get("SYNC_CRON_SECRET") ?? ""))) {
    return new Response("unauthorized", { status: 401 });
  }
  let body: { dryRun?: boolean; force?: boolean; calendars?: string[]; writeback?: boolean; probeWrite?: boolean } = {};
  try { body = req.headers.get("content-length") === "0" ? {} : await req.json(); } catch { body = {}; }

  const runId = crypto.randomUUID();
  // service_role-avain: booking-skeema, apply_closure_events on rajattu service_roolille
  const supa = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
    db: { schema: "booking" },
  });
  const db: Db = { rpc: (fn, args) => supa.rpc(fn, args) as unknown as ReturnType<Db["rpc"]> };
  if (body.probeWrite === true) {
    try { return Response.json({ ok: true, runId, probe: await probeWrite(db, google) }); }
    catch (err) { return Response.json({ ok: false, runId, error: safeError(err) }, { status: 500 }); }
  }
  try {
    log("run_started", { runId, dryRun: body.dryRun === true, force: body.force === true });
    const out = await runSync(db, google, { dryRun: body.dryRun === true, force: body.force === true, calendars: body.calendars });
    // hallinta -> kalenteri: jono tyhjennetään lukusynkan jälkeen (virhe täällä ei kaada lukusynkkaa); dryRun ei kirjoita
    let writeback: unknown = undefined;
    if (body.dryRun !== true && body.writeback !== false) {
      try { writeback = await runWriteback(db, google); } catch (err) { writeback = { error: safeError(err) }; }
    }
    log("run_finished", { runId, ok: out.ok, results: out.results.map((r) => ({ c: r.calendar, s: r.status, e: r.error })), writeback });
    return Response.json({ runId, dryRun: body.dryRun === true, ...out, writeback }, { status: out.ok ? 200 : 500 });
  } catch (err) {
    const msg = safeError(err);
    log("run_crashed", { runId, error: msg });
    return Response.json({ ok: false, runId, error: msg }, { status: 500 });
  }
});
