// calendar-sync-v2: työvuorokalenterit, tietokanta päälähteenä.
// v1 calendar-sync jää ennalleen (paluu). Tätä ei deployata tästä haarasta.
//
// Autentikointi (ei uusia salaisuuksia):
//   * kutsuja: header x-sync-secret = env SYNC_CRON_SECRET (vakioaikavertailu)
//   * Google: palvelutili, env GOOGLE_SERVICE_ACCOUNT_JSON, JWT bearer
//   * scope https://www.googleapis.com/auth/calendar.events
//   * tietokanta: SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY (public-skeema)
// Kirjoitus Googleen vain kun dryRun !== true, body.push !== false, shift_sync_config
// palauttaa db_first_enabled && push_enabled, eikä SHIFT_PUSH_DISABLED=1.
// Poissaoloja ei viedä. Henkilökohtaiseen kalenteriin ei kirjoiteta: lähteet ovat
// vain aktiivisia calendar_sources-rivejä, vienti vain shift_outboxista.
//
// Pyyntö POST JSON:
//   {"mode":"auto"|"full"|"push", "dryRun":bool, "calendarSourceIds":[uuid], "push":bool}
//   auto/full: vuokra -> luku -> vienti -> vapautus. push: vuokra -> vienti.
// Vastaus: laskurit, virhekoodit ja kuivaharjoituksen suunnitelma (op, summary, muuttuneet kentät).
// Ei tokeneita, salaisuuksia eikä kalenteri-id:itä.
//
// Cron (EHDOTUS, ei luoda tässä):
//   * calendar-sync-incremental-10m ja calendar-sync-full-weekly: vaihda vain URL
//     .../functions/v1/calendar-sync -> .../functions/v1/calendar-sync-v2. Runko ennallaan.
//   * uusi työ calendar-sync-v2-push-2m (*/2 * * * *), sama kuvio kuin booking_send_emails.
//     Aja vain kun jonossa on työtä. Salaisuus vaultista kuten nykyisissä töissä
//     (vault.decrypted_secrets.name = calendar_sync_cron_secret):
//
//     select cron.schedule('calendar-sync-v2-push-2m', '*/2 * * * *', $cron$
//       select case when exists (
//         select 1 from public.shift_outbox
//          where status in ('pending','blocked') and next_attempt_at <= now()
//       ) then
//         net.http_post(
//           url := 'https://sxbofnuisemspgquoxyv.supabase.co/functions/v1/calendar-sync-v2',
//           body := '{"mode":"push"}'::jsonb,
//           headers := jsonb_build_object(
//             'content-type', 'application/json',
//             'x-sync-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'calendar_sync_cron_secret')
//           ),
//           timeout_milliseconds := 50000)
//       end;
//     $cron$);
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  buildFull,
  buildIncremental,
  createGoogle,
  dryRunDiagnostics,
  GoneError,
  HttpError,
  type OutboxItem,
  type PushDb,
  type PushResult,
  CLAIM_LIMIT,
  runPush,
  safeError,
  type TokenSource,
} from "./core.ts";

const SCOPE = "https://www.googleapis.com/auth/calendar.events";
const LEASE_TTL_SECONDS = 600;

type RequestMode = "auto" | "full" | "push";
type PullMode = "incremental" | "full" | "recovery";

interface SourceRow {
  id: string;
  calendar_name: string;
  google_calendar_id: string;
}
interface SyncStateRow {
  sync_token: string | null;
  full_sync_required: boolean;
}
interface RequestBody {
  mode?: string;
  dryRun?: boolean;
  push?: boolean;
  calendarSourceIds?: string[];
}

const log = (event: string, data: Record<string, unknown> = {}) =>
  console.log(JSON.stringify({ fn: "calendar-sync-v2", event, ...data }));

async function secretMatches(provided: string, expected: string): Promise<boolean> {
  if (!expected || !provided) return false;
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(provided)),
    crypto.subtle.digest("SHA-256", enc.encode(expected)),
  ]);
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

interface ServiceAccount {
  client_email: string;
  private_key: string;
  token_uri?: string;
}
let cachedToken: { value: string; exp: number } | null = null;

function loadServiceAccount(): ServiceAccount {
  const raw = Deno.env.get("GOOGLE_SERVICE_ACCOUNT_JSON");
  if (!raw) throw new Error("GOOGLE_SERVICE_ACCOUNT_JSON is not set");
  let sa: ServiceAccount;
  try {
    sa = JSON.parse(raw);
  } catch {
    throw new Error("GOOGLE_SERVICE_ACCOUNT_JSON is not valid JSON");
  }
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
  const header = { alg: "RS256", typ: "JWT" };
  const claims = { iss: sa.client_email, scope: SCOPE, aud: tokenUri, iat: now, exp: now + 3600 };
  const unsigned = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claims))}`;
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

const tokens: TokenSource = {
  token: getAccessToken,
  invalidate: () => {
    cachedToken = null;
  },
};

function requestMode(raw: unknown): RequestMode | "invalid" {
  if (raw == null || raw === "" || raw === "auto" || raw === "incremental") return "auto";
  if (raw === "full" || raw === "push") return raw;
  return "invalid";
}

function asItems(data: unknown): OutboxItem[] {
  const value = typeof data === "string" ? JSON.parse(data) : data;
  return Array.isArray(value) ? value as OutboxItem[] : [];
}

function asConfig(data: unknown): { db_first_enabled?: boolean; push_enabled?: boolean } | null {
  const value = typeof data === "string" ? JSON.parse(data) : data;
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  return value as { db_first_enabled?: boolean; push_enabled?: boolean };
}

function makePushDb(supa: SupabaseClient): PushDb {
  return {
    async config() {
      const { data, error } = await supa.rpc("shift_sync_config");
      if (error) throw new Error("shift_sync_config_failed");
      return asConfig(data);
    },
    async claim(sourceId, dryRun) {
      const { data, error } = await supa.rpc("shift_outbox_claim", {
        p_calendar_source_id: sourceId,
        p_limit: CLAIM_LIMIT,
        p_dry_run: dryRun,
      });
      if (error) throw new Error("shift_outbox_claim_failed");
      return asItems(data);
    },
    async complete(id, result, updated, etag) {
      const { error } = await supa.rpc("shift_outbox_complete", {
        p_id: id,
        p_result: result,
        p_g_updated: updated,
        p_etag: etag,
      });
      if (error) throw new Error("shift_outbox_complete_failed");
    },
    async fail(id, error, blocked = false, conflict = false, missing = false) {
      const { error: rpcErr } = await supa.rpc("shift_outbox_fail", {
        p_id: id,
        p_error: error,
        p_blocked: blocked,
        p_conflict: conflict,
        p_missing: missing,
      });
      if (rpcErr) throw new Error("shift_outbox_fail_failed");
    },
  };
}

function publicPush(push: PushResult) {
  return {
    writes: push.writes,
    writeSkip: push.writeSkip,
    claimed: push.claimed,
    created: push.created,
    patched: push.patched,
    deleted: push.deleted,
    gone: push.gone,
    blocked: push.blocked,
    conflicts: push.conflicts,
    missing: push.missing,
    failed: push.failed,
    ...(push.plan ? { plan: push.plan } : {}),
  };
}

async function syncCalendar(
  supa: SupabaseClient,
  pushDb: PushDb,
  google: ReturnType<typeof createGoogle>,
  src: SourceRow,
  opts: { requestMode: RequestMode; dryRun: boolean; pushRequested: boolean; killSwitch: boolean; runId: string },
) {
  const owner = `${opts.runId}:${src.id}`;
  const { data: gotLease, error: leaseErr } = await supa.rpc("acquire_calendar_sync_lease", {
    p_source_id: src.id,
    p_owner: owner,
    p_ttl_seconds: LEASE_TTL_SECONDS,
  });
  if (leaseErr) throw new Error("lease_rpc_failed");
  if (!gotLease) return { calendar: src.calendar_name, status: "skipped_locked" };

  let pullMode: PullMode = "incremental";
  let pullError: string | null = null;
  let summary: unknown;
  let diagnostics: ReturnType<typeof dryRunDiagnostics> | undefined;
  try {
    if (opts.requestMode !== "push") {
      try {
        const { data: st, error: stErr } = await supa
          .from("sync_state")
          .select("sync_token, full_sync_required")
          .eq("calendar_source_id", src.id)
          .single<SyncStateRow>();
        if (stErr) throw new Error("sync_state_read_failed");
        pullMode = opts.requestMode === "full" || st.full_sync_required || !st.sync_token ? "full" : "incremental";
        let built;
        if (pullMode === "incremental") {
          try {
            built = await buildIncremental(src.google_calendar_id, st.sync_token!, google.listAll);
          } catch (e) {
            if (!(e instanceof GoneError)) throw e;
            log("token_gone", { runId: opts.runId, calendar: src.calendar_name });
            pullMode = "recovery";
            built = await buildFull(src.google_calendar_id, google.listAll);
          }
        } else {
          built = await buildFull(src.google_calendar_id, google.listAll);
        }
        const applied = await supa.rpc("apply_calendar_changes_v2", {
          p_source_id: src.id,
          p_events: built.events,
          p_new_sync_token: built.newToken,
          p_mode: pullMode,
          p_scopes: built.scopes,
          p_run_id: opts.runId,
          p_dry_run: opts.dryRun,
        });
        if (applied.error) throw new Error("apply_failed");
        summary = applied.data;
        if (opts.dryRun) diagnostics = dryRunDiagnostics(built.events, built.scopes);
        log("calendar_pulled", { runId: opts.runId, calendar: src.calendar_name, mode: pullMode, dryRun: opts.dryRun });
      } catch (err) {
        pullError = safeError(err);
        log("calendar_pull_failed", { runId: opts.runId, calendar: src.calendar_name, mode: pullMode, error: pullError });
        if (!opts.dryRun) {
          const { error: failErr } = await supa.rpc("record_calendar_sync_failure", {
            p_source_id: src.id,
            p_error: `${pullMode}: ${pullError}`,
            p_require_full: err instanceof GoneError || pullMode === "recovery" ||
              (pullMode === "incremental" && err instanceof HttpError && err.status === 400),
          });
          if (failErr) log("record_failure_failed", { runId: opts.runId, calendar: src.calendar_name });
        }
      }
    }

    let push: PushResult;
    try {
      push = await runPush({
        sourceId: src.id,
        dryRun: opts.dryRun,
        pushRequested: opts.pushRequested,
        killSwitch: opts.killSwitch,
        db: pushDb,
        google,
      });
    } catch (err) {
      const msg = safeError(err);
      log("calendar_push_failed", { runId: opts.runId, calendar: src.calendar_name, error: msg });
      const error = pullError ? `${pullError}; ${msg}` : msg;
      return {
        calendar: src.calendar_name,
        status: "error",
        mode: opts.requestMode === "push" ? "push" : pullMode,
        summary,
        diagnostics,
        error,
      };
    }
    log("calendar_pushed", {
      runId: opts.runId,
      calendar: src.calendar_name,
      writes: push.writes,
      writeSkip: push.writeSkip,
      claimed: push.claimed,
      failed: push.failed,
    });
    if (pullError) {
      return {
        calendar: src.calendar_name,
        status: "error",
        mode: pullMode,
        summary,
        diagnostics,
        push: publicPush(push),
        error: pullError,
      };
    }
    return {
      calendar: src.calendar_name,
      status: "ok",
      mode: opts.requestMode === "push" ? "push" : pullMode,
      summary,
      diagnostics,
      push: publicPush(push),
    };
  } finally {
    const { error: relErr } = await supa.rpc("release_calendar_sync_lease", { p_source_id: src.id, p_owner: owner });
    if (relErr) log("lease_release_failed", { runId: opts.runId, calendar: src.calendar_name });
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  const expected = Deno.env.get("SYNC_CRON_SECRET") ?? "";
  const provided = req.headers.get("x-sync-secret") ?? "";
  if (!(await secretMatches(provided, expected))) return new Response("unauthorized", { status: 401 });

  let body: RequestBody = {};
  try {
    if (req.headers.get("content-length") !== "0") {
      const parsed = await req.json();
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) body = parsed as RequestBody;
    }
  } catch {
    body = {};
  }
  const mode = requestMode(body.mode);
  if (mode === "invalid") return Response.json({ ok: false, error: "invalid_mode" }, { status: 400 });

  const dryRun = body.dryRun === true;
  const pushRequested = body.push !== false;
  const killSwitch = Deno.env.get("SHIFT_PUSH_DISABLED") === "1";
  const runId = crypto.randomUUID();
  const supa = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const pushDb = makePushDb(supa);
  const google = createGoogle(fetch, tokens);

  let q = supa.from("calendar_sources").select("id, calendar_name, google_calendar_id").eq("active", true)
    .not("google_calendar_id", "is", null);
  if (Array.isArray(body.calendarSourceIds) && body.calendarSourceIds.length) q = q.in("id", body.calendarSourceIds);
  const { data: sources, error } = await q;
  if (error) {
    log("sources_read_failed", { runId });
    return Response.json({ ok: false, runId, error: "sources_read_failed" }, { status: 500 });
  }

  log("run_started", { runId, mode, dryRun, pushRequested, killSwitch, calendars: (sources ?? []).length });
  const results = [];
  for (const src of (sources ?? []) as SourceRow[]) {
    try {
      results.push(await syncCalendar(supa, pushDb, google, src, { requestMode: mode, dryRun, pushRequested, killSwitch, runId }));
    } catch (err) {
      const msg = safeError(err);
      log("calendar_crashed", { runId, calendar: src.calendar_name, error: msg });
      results.push({ calendar: src.calendar_name, status: "error", error: msg });
    }
  }
  const ok = results.every((r) => r.status !== "error");
  log("run_finished", { runId, ok });
  return Response.json({ ok, runId, mode, dryRun, results }, { status: ok ? 200 : 500 });
});
