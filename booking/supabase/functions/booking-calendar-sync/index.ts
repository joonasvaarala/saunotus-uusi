// booking-calendar-sync: yksisuuntainen vienti varausjärjestelmä -> Google-kalenteri.
// pg_cron kutsuu POST + x-sync-secret (booking.booking_calendar_dispatch), sama salaisuus kuin sulkusynkassa.
//
// Autentikointi (ei uusia salaisuuksia):
//   * kutsuja: header x-sync-secret = env SYNC_CRON_SECRET (vakioaikavertailu)
//   * Google: palvelutili, env GOOGLE_SERVICE_ACCOUNT_JSON, JWT bearer, scope calendar.events
// Kohdekalenterit jaetaan palvelutilin client_email-osoitteelle oikeudella "Make changes to events".
// Sulkukalenterien id:tä ei kirjoiteta (kanta ja planOps hylkäävät).
//
// Pyyntö (POST, JSON, valinnainen): { "dryRun": true }
// Vastaus: vain laskurit ja virhekoodit. Ei otsikoita, kuvauksia, kalenteri-id:itä tai avaimia.
//
// Deploy (ei ajeta tästä haarasta):
//   supabase functions deploy booking-calendar-sync --project-ref sxbofnuisemspgquoxyv
// verify_jwt = false (config.toml). Ajastus syntyy migraatiossa booking_114, kun booking.skip_cron ei ole päällä.
// booking_115: suunnitelman reconcile=true pyytää täyden kirjoituksen. Muuten sama content_hash ohitetaan.
import { createClient } from "npm:@supabase/supabase-js@2";
import { type Db, type ExportPlan, runExport, safeError } from "./core.ts";
import { createGoogle, type TokenSource } from "./google.ts";

const SCOPE = "https://www.googleapis.com/auth/calendar.events";

const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "booking-calendar-sync", event, ...data }));

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
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: `${unsigned}.${b64url(sig)}` }),
  });
  if (!res.ok) throw new Error(`google_token_exchange_failed_${res.status}`);
  const json = await res.json();
  cachedToken = { value: json.access_token, exp: now + Number(json.expires_in ?? 3600) };
  return cachedToken.value;
}

const tokens: TokenSource = { token: getAccessToken, invalidate: () => { cachedToken = null; } };

function countsOnly(out: Awaited<ReturnType<typeof runExport>>) {
  return {
    ok: out.ok,
    mode: out.mode,
    skipped: out.skipped ?? null,
    dryRun: out.dryRun === true,
    inserted: out.inserted,
    patched: out.patched,
    deleted: out.deleted,
    failed: out.failed,
    unconfigured: out.unconfigured,
    blocked: out.blocked,
    error: out.error ?? null,
  };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  if (!(await secretMatches(req.headers.get("x-sync-secret") ?? "", Deno.env.get("SYNC_CRON_SECRET") ?? ""))) {
    return new Response("unauthorized", { status: 401 });
  }
  let dryRun = false;
  try {
    if (req.headers.get("content-length") !== "0") {
      const body = await req.json();
      dryRun = body?.dryRun === true;
    }
  } catch { dryRun = false; }

  const runId = crypto.randomUUID();
  const supa = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
    db: { schema: "booking" },
  });
  const db: Db = {
    async plan() {
      const r = await supa.rpc("booking_calendar_export_plan");
      if (r.error) throw new Error("plan_failed");
      return (r.data ?? {}) as ExportPlan;
    },
    async finish(payload) {
      const r = await supa.rpc("booking_calendar_export_finish", { p: payload });
      if (r.error) throw new Error("finish_failed");
    },
  };
  try {
    log("run_started", { runId, dryRun });
    const out = await runExport(db, createGoogle(fetch, tokens), { dryRun });
    const safe = countsOnly(out);
    log("run_finished", { runId, ...safe });
    return Response.json({ runId, ...safe }, { status: out.ok ? 200 : 500 });
  } catch (err) {
    const msg = safeError(err);
    log("run_crashed", { runId, error: msg });
    return Response.json({ ok: false, runId, error: msg }, { status: 500 });
  }
});
