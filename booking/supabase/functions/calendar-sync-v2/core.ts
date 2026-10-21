// calendar-sync-v2 ydin. Ei Deno-salaisuuksia eikä oikeaa verkkoa: testit antavat feikin fetchille ja tietokannalle.
// Suunta: Google -> DB (apply_calendar_changes_v2) ja DB -> Google (shift_outbox).
// Poissaoloja (staff_unavailability) ei kirjoiteta. Henkilökohtaista kalenteria ei ole tässä polussa:
// lähteet tulevat vain calendar_sources-riveistä, ja vienti vain shift_outboxista.

export const CAL_API = "https://www.googleapis.com/calendar/v3";
export const CLAIM_LIMIT = 25;
export const DB_EVENT_DESCRIPTION = "Luotu vuorotietokannasta…";

const WINDOW_BACK_DAYS = 60;
const WINDOW_FORWARD_MONTHS = 12;
const PAGE_SIZE = 2500;
const MAX_PAGES = 200;
const SYNC_PARAMS = { singleEvents: "false", showDeleted: "true" } as const;

export interface GEvent {
  id: string;
  status?: string;
  summary?: string;
  updated?: string;
  etag?: string;
  start?: { dateTime?: string; date?: string };
  end?: { dateTime?: string; date?: string };
  recurringEventId?: string;
  originalStartTime?: { dateTime?: string; date?: string };
  recurrence?: string[];
  extendedProperties?: { private?: Record<string, string> };
}

export interface Scope {
  type: "calendar" | "series";
  recurring_event_id?: string;
  from: string;
  to: string;
}

export interface BuiltSync {
  events: GEvent[];
  scopes: Scope[];
  newToken: string;
}

export type ListAll = (
  path: string,
  params: Record<string, string | undefined>,
) => Promise<{ items: GEvent[]; nextSyncToken?: string }>;

export interface OutboxItem {
  id: number;
  op: "insert" | "patch" | "delete";
  shift_id: string;
  version: number;
  google_calendar_id: string;
  calendar_name: string;
  event_id: string;
  etag: string | null;
  timezone: string;
  summary: string;
  starts_at: string;
  ends_at: string;
  title_changed: boolean;
  time_changed: boolean;
  reactivate: boolean;
  recurring: boolean;
  attempt: number;
}

export interface PushPlanItem {
  op: "insert" | "patch" | "delete";
  summary: string;
  title_changed: boolean;
  time_changed: boolean;
  reactivate: boolean;
}

export interface WriteOutcome {
  status: number;
  updated: string | null;
  etag: string | null;
  reason: string;
}

export interface GoogleWrites {
  insert(calendarId: string, body: Record<string, unknown>): Promise<WriteOutcome>;
  patch(calendarId: string, eventId: string, body: Record<string, unknown>, etag: string | null): Promise<WriteOutcome>;
  delete(calendarId: string, eventId: string, etag: string | null): Promise<WriteOutcome>;
}

export interface GoogleClient extends GoogleWrites {
  listAll: ListAll;
}

export interface TokenSource {
  token(): Promise<string>;
  invalidate?: () => void;
}

export interface PushDb {
  config(): Promise<{ db_first_enabled?: boolean; push_enabled?: boolean } | null>;
  claim(sourceId: string, dryRun: boolean): Promise<OutboxItem[]>;
  complete(id: number, result: "created" | "patched" | "deleted" | "gone", updated: string | null, etag: string | null): Promise<void>;
  fail(id: number, error: string, blocked?: boolean, conflict?: boolean, missing?: boolean): Promise<void>;
}

export interface WriteGate {
  dryRun: boolean;
  pushRequested: boolean;
  killSwitch: boolean;
  dbFirstEnabled: boolean;
  pushEnabled: boolean;
}

export interface PushResult {
  writes: boolean;
  writeSkip: string | null;
  claimed: number;
  created: number;
  patched: number;
  deleted: number;
  gone: number;
  blocked: number;
  conflicts: number;
  missing: number;
  failed: number;
  plan?: PushPlanItem[];
}

export class GoneError extends Error {
  constructor() {
    super("sync token expired (410 Gone)");
  }
}

export class HttpError extends Error {
  constructor(public status: number, public reason: string) {
    super(`HTTP ${status}${reason ? ` (${reason})` : ""}`);
  }
}

export function safeError(err: unknown): string {
  if (err instanceof GoneError) return "google_410_gone";
  if (err instanceof HttpError) return `google_http_${err.status}${err.reason ? `_${err.reason}` : ""}`;
  if (err instanceof Error) {
    return err.message
      .replace(/ya29\.[\w.-]+/g, "[redacted]")
      .replace(/[\w.+-]+@[\w.-]+/g, "[redacted]")
      .slice(0, 500);
  }
  return "unknown_error";
}

export function eventUrl(calendarId: string, eventId?: string): URL {
  const idPart = eventId ? `/${encodeURIComponent(eventId)}` : "";
  return new URL(`${CAL_API}/calendars/${encodeURIComponent(calendarId)}/events${idPart}`);
}

export const eventsPath = (calendarId: string) => `/calendars/${encodeURIComponent(calendarId)}/events`;

/** Pitää etagin ja vain sipoo_*-yksityisavaimet. Muut kentät pudotetaan (ei htmlLinkiä, ei jaettuja ominaisuuksia). */
export function slim(e: GEvent): GEvent {
  const out: GEvent = { id: e.id };
  if (e.status !== undefined) out.status = e.status;
  if (e.summary !== undefined) out.summary = e.summary;
  if (e.updated !== undefined) out.updated = e.updated;
  if (e.start !== undefined) out.start = e.start;
  if (e.end !== undefined) out.end = e.end;
  if (e.recurringEventId !== undefined) out.recurringEventId = e.recurringEventId;
  if (e.originalStartTime !== undefined) out.originalStartTime = e.originalStartTime;
  if (e.etag) out.etag = e.etag;
  const priv = e.extendedProperties?.private;
  if (priv) {
    const keep: Record<string, string> = {};
    for (const [k, v] of Object.entries(priv)) {
      if (!k.startsWith("sipoo_") || v == null || v === "") continue;
      keep[k] = String(v);
    }
    if (Object.keys(keep).length) out.extendedProperties = { private: keep };
  }
  return out;
}

export function reconciliationWindow(now = new Date()): { from: string; to: string } {
  const from = new Date(now.getTime() - WINDOW_BACK_DAYS * 86_400_000);
  const to = new Date(now);
  to.setUTCMonth(to.getUTCMonth() + WINDOW_FORWARD_MONTHS);
  return { from: from.toISOString(), to: to.toISOString() };
}

export async function buildFull(calendarId: string, listAll: ListAll, now = new Date()): Promise<BuiltSync> {
  const win = reconciliationWindow(now);
  const tokenRun = await listAll(eventsPath(calendarId), { ...SYNC_PARAMS });
  if (!tokenRun.nextSyncToken) throw new Error("google_did_not_return_sync_token");
  const snap = await listAll(eventsPath(calendarId), {
    singleEvents: "true",
    showDeleted: "false",
    timeMin: win.from,
    timeMax: win.to,
  });
  const events = snap.items.filter((e) => e.status !== "cancelled").map(slim);
  const scopes: Scope[] = [{ type: "calendar", from: win.from, to: win.to }];
  return { events, scopes, newToken: tokenRun.nextSyncToken };
}

export async function buildIncremental(calendarId: string, syncToken: string, listAll: ListAll, now = new Date()): Promise<BuiltSync> {
  const win = reconciliationWindow(now);
  const changed = await listAll(eventsPath(calendarId), { ...SYNC_PARAMS, syncToken });
  if (!changed.nextSyncToken) throw new Error("google_did_not_return_sync_token");

  const byId = new Map<string, GEvent>();
  const scopes: Scope[] = [];

  for (const item of changed.items) {
    if (item.recurringEventId) {
      byId.set(item.id, slim(item));
    } else if (item.recurrence && item.status !== "cancelled") {
      const inst = await listAll(`${eventsPath(calendarId)}/${encodeURIComponent(item.id)}/instances`, {
        showDeleted: "true",
        timeMin: win.from,
        timeMax: win.to,
      });
      for (const e of inst.items) byId.set(e.id, slim(e));
      scopes.push({ type: "series", recurring_event_id: item.id, from: win.from, to: win.to });
    } else if (item.status === "cancelled") {
      const tomb: GEvent = { id: item.id, status: "cancelled" };
      if (item.updated !== undefined) tomb.updated = item.updated;
      if (item.etag) tomb.etag = item.etag;
      byId.set(item.id, tomb);
      scopes.push({ type: "series", recurring_event_id: item.id, from: win.from, to: win.to });
    } else {
      byId.set(item.id, slim(item));
    }
  }
  return { events: [...byId.values()], scopes, newToken: changed.nextSyncToken };
}

export function dryRunDiagnostics(events: GEvent[], scopes: Scope[]) {
  const ids = events.map((e) => e.id);
  const titleCounts: Record<string, number> = {};
  for (const e of events) {
    if (e.status === "cancelled") continue;
    const t = (e.summary ?? "").trim() || "(empty)";
    titleCounts[t] = (titleCounts[t] ?? 0) + 1;
  }
  const starts = events.map((e) => e.start?.dateTime ?? e.start?.date).filter(Boolean).sort() as string[];
  return {
    scopes,
    eventsSent: events.length,
    distinctIds: new Set(ids).size,
    cancelledItems: events.filter((e) => e.status === "cancelled").length,
    allDayEvents: events.filter((e) => !e.start?.dateTime && e.start?.date).length,
    firstStart: starts[0] ?? null,
    lastStart: starts[starts.length - 1] ?? null,
    titleCounts,
  };
}

function zone(item: OutboxItem): string {
  return item.timezone || "Europe/Helsinki";
}

export function privateProps(item: OutboxItem): Record<string, string> {
  return {
    sipoo_src: "db",
    sipoo_shift_id: String(item.shift_id),
    sipoo_shift_ver: String(item.version),
  };
}

export function insertBody(item: OutboxItem): Record<string, unknown> {
  const tz = zone(item);
  return {
    id: item.event_id,
    summary: item.summary,
    description: DB_EVENT_DESCRIPTION,
    start: { dateTime: item.starts_at, timeZone: tz },
    end: { dateTime: item.ends_at, timeZone: tz },
    extendedProperties: { private: privateProps(item) },
  };
}

/** 409:n jälkeinen PATCH: sama sisältö kuin insert, ilman id:tä (id on URLissa). */
export function insertPatchBody(item: OutboxItem): Record<string, unknown> {
  const body = insertBody(item);
  delete body.id;
  return body;
}

/** Vain muuttuneet kentät + extendedProperties.private aina. */
export function patchBody(item: OutboxItem): Record<string, unknown> {
  const tz = zone(item);
  const body: Record<string, unknown> = {
    extendedProperties: { private: privateProps(item) },
  };
  if (item.title_changed) body.summary = item.summary;
  if (item.time_changed) {
    body.start = { dateTime: item.starts_at, timeZone: tz };
    body.end = { dateTime: item.ends_at, timeZone: tz };
  }
  if (item.reactivate) body.status = "confirmed";
  return body;
}

export function planItem(item: OutboxItem): PushPlanItem {
  return {
    op: item.op,
    summary: item.summary ?? "",
    title_changed: item.title_changed === true,
    time_changed: item.time_changed === true,
    reactivate: item.reactivate === true,
  };
}

export function writeSkipReason(g: WriteGate): string | null {
  if (g.dryRun) return "dry_run";
  if (!g.pushRequested) return "push_not_requested";
  if (g.killSwitch) return "kill_switch";
  if (!g.dbFirstEnabled) return "db_first_off";
  if (!g.pushEnabled) return "push_disabled";
  return null;
}

export function writesAllowed(g: WriteGate): boolean {
  return writeSkipReason(g) === null;
}

function etagOrNull(item: OutboxItem): string | null {
  if (item.etag == null) return null;
  const s = String(item.etag).trim();
  return s === "" ? null : s;
}

function httpMsg(res: WriteOutcome): string {
  return `google_http_${res.status}${res.reason ? `_${res.reason}` : ""}`;
}

function okStatus(status: number): boolean {
  return status >= 200 && status < 300;
}

interface ItemCount {
  created?: number;
  patched?: number;
  deleted?: number;
  gone?: number;
  blocked?: number;
  conflicts?: number;
  missing?: number;
  failed?: number;
}

async function settleHttp(item: OutboxItem, res: WriteOutcome, db: PushDb, kind: "insert" | "patch" | "delete"): Promise<ItemCount> {
  if (res.status === 412) {
    await db.fail(item.id, "google_http_412", false, true, false);
    return { conflicts: 1 };
  }
  if (res.status === 403) {
    await db.fail(item.id, "no_write_access", true);
    return { blocked: 1 };
  }
  if (kind === "patch" && (res.status === 404 || res.status === 410)) {
    await db.fail(item.id, httpMsg(res), false, false, true);
    return { missing: 1 };
  }
  if (kind === "delete" && (res.status === 404 || res.status === 410)) {
    await db.complete(item.id, "gone", null, null);
    return { gone: 1 };
  }
  await db.fail(item.id, httpMsg(res));
  return { failed: 1 };
}

async function applyItem(item: OutboxItem, google: GoogleWrites, db: PushDb): Promise<ItemCount> {
  try {
    if (!item.google_calendar_id || !item.event_id) {
      await db.fail(item.id, "push_target_missing", false, false, true);
      return { missing: 1 };
    }
    if (item.op === "insert") {
      const res = await google.insert(item.google_calendar_id, insertBody(item));
      if (okStatus(res.status)) {
        await db.complete(item.id, "created", res.updated, res.etag);
        return { created: 1 };
      }
      if (res.status === 409) {
        const patched = await google.patch(item.google_calendar_id, item.event_id, insertPatchBody(item), etagOrNull(item));
        if (okStatus(patched.status)) {
          await db.complete(item.id, "patched", patched.updated, patched.etag);
          return { patched: 1 };
        }
        return await settleHttp(item, patched, db, "patch");
      }
      return await settleHttp(item, res, db, "insert");
    }
    if (item.op === "patch") {
      const res = await google.patch(item.google_calendar_id, item.event_id, patchBody(item), etagOrNull(item));
      if (okStatus(res.status)) {
        await db.complete(item.id, "patched", res.updated, res.etag);
        return { patched: 1 };
      }
      return await settleHttp(item, res, db, "patch");
    }
    if (item.op === "delete") {
      const res = await google.delete(item.google_calendar_id, item.event_id, etagOrNull(item));
      if (okStatus(res.status)) {
        await db.complete(item.id, "deleted", res.updated, res.etag);
        return { deleted: 1 };
      }
      return await settleHttp(item, res, db, "delete");
    }
    await db.fail(item.id, "unknown_op");
    return { failed: 1 };
  } catch (err) {
    await db.fail(item.id, safeError(err));
    return { failed: 1 };
  }
}

export async function runPush(opts: {
  sourceId: string;
  dryRun: boolean;
  pushRequested: boolean;
  killSwitch: boolean;
  db: PushDb;
  google: GoogleWrites;
}): Promise<PushResult> {
  const cfg = await opts.db.config();
  const writeSkip = writeSkipReason({
    dryRun: opts.dryRun,
    pushRequested: opts.pushRequested,
    killSwitch: opts.killSwitch,
    dbFirstEnabled: cfg?.db_first_enabled === true,
    pushEnabled: cfg?.push_enabled === true,
  });
  const allow = writeSkip === null;
  const items = await opts.db.claim(opts.sourceId, !allow);
  const out: PushResult = {
    writes: allow,
    writeSkip,
    claimed: items.length,
    created: 0,
    patched: 0,
    deleted: 0,
    gone: 0,
    blocked: 0,
    conflicts: 0,
    missing: 0,
    failed: 0,
  };
  if (!allow) {
    // Suunnitelma (otsikot) vain kuivaharjoituksessa. Muut kiellot palauttavat laskurit.
    return opts.dryRun ? { ...out, plan: items.map(planItem) } : out;
  }
  for (const item of items) {
    const c = await applyItem(item, opts.google, opts.db);
    out.created += c.created ?? 0;
    out.patched += c.patched ?? 0;
    out.deleted += c.deleted ?? 0;
    out.gone += c.gone ?? 0;
    out.blocked += c.blocked ?? 0;
    out.conflicts += c.conflicts ?? 0;
    out.missing += c.missing ?? 0;
    out.failed += c.failed ?? 0;
  }
  return out;
}

const realSleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

async function readJson(res: Response): Promise<{ text: string; json: unknown }> {
  const text = await res.text();
  if (!text) return { text, json: null };
  try {
    return { text, json: JSON.parse(text) };
  } catch {
    return { text, json: null };
  }
}

function reasonOf(json: unknown): string {
  const raw = (json as { error?: { errors?: Array<{ reason?: unknown }> } } | null)?.error?.errors?.[0]?.reason;
  return typeof raw === "string" ? raw.slice(0, 80) : "";
}

function outcomeOf(status: number, json: unknown, reason = ""): WriteOutcome {
  const obj = json as { updated?: unknown; etag?: unknown } | null;
  return {
    status,
    updated: typeof obj?.updated === "string" ? obj.updated : null,
    etag: typeof obj?.etag === "string" ? obj.etag : null,
    reason,
  };
}

async function gwrite(
  fetchImpl: typeof fetch,
  tokens: TokenSource,
  sleepFn: (ms: number) => Promise<void>,
  method: "POST" | "PATCH" | "DELETE",
  url: URL,
  body?: Record<string, unknown>,
  ifMatch?: string | null,
): Promise<WriteOutcome> {
  for (let attempt = 0; ; attempt++) {
    const headers: Record<string, string> = { authorization: `Bearer ${await tokens.token()}` };
    if (body) headers["content-type"] = "application/json";
    if (ifMatch) headers["If-Match"] = ifMatch;
    const res = await fetchImpl(url, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
    });
    const parsed = await readJson(res);
    if (res.ok) return outcomeOf(res.status, parsed.json);
    const reason = reasonOf(parsed.json);
    if (res.status === 401 && attempt === 0) {
      tokens.invalidate?.();
      continue;
    }
    if (res.status === 409 || res.status === 404 || res.status === 410 || res.status === 412) {
      return outcomeOf(res.status, null, reason);
    }
    const rateLimited = res.status === 403 && (reason === "rateLimitExceeded" || reason === "userRateLimitExceeded");
    const retryable = res.status === 429 || res.status >= 500 || rateLimited;
    if (retryable && attempt < 4) {
      await sleepFn(Math.min(16000, 500 * 2 ** attempt) + Math.floor(Math.random() * 250));
      continue;
    }
    if (res.status === 403 && !rateLimited) return outcomeOf(403, null, reason);
    throw new HttpError(res.status, reason);
  }
}

async function gget(
  fetchImpl: typeof fetch,
  tokens: TokenSource,
  sleepFn: (ms: number) => Promise<void>,
  path: string,
  params: Record<string, string | undefined>,
): Promise<{ items?: GEvent[]; nextPageToken?: string; nextSyncToken?: string }> {
  const url = new URL(CAL_API + path);
  for (const [k, v] of Object.entries(params)) if (v !== undefined) url.searchParams.set(k, v);
  for (let attempt = 0; ; attempt++) {
    const res = await fetchImpl(url, { headers: { authorization: `Bearer ${await tokens.token()}` } });
    if (res.ok) return await res.json();
    if (res.status === 410) {
      await res.body?.cancel();
      throw new GoneError();
    }
    const parsed = await readJson(res);
    const reason = reasonOf(parsed.json);
    if (res.status === 401 && attempt === 0) {
      tokens.invalidate?.();
      continue;
    }
    const retryable = res.status === 429 || res.status >= 500 ||
      (res.status === 403 && (reason === "rateLimitExceeded" || reason === "userRateLimitExceeded"));
    if (retryable && attempt < 4) {
      await sleepFn(Math.min(16000, 500 * 2 ** attempt) + Math.floor(Math.random() * 250));
      continue;
    }
    throw new HttpError(res.status, reason);
  }
}

export function createGoogle(
  fetchImpl: typeof fetch,
  tokens: TokenSource,
  sleepFn: (ms: number) => Promise<void> = realSleep,
): GoogleClient {
  return {
    async listAll(path, params) {
      const items: GEvent[] = [];
      let pageToken: string | undefined;
      let nextSyncToken: string | undefined;
      for (let page = 0; page < MAX_PAGES; page++) {
        const res = await gget(fetchImpl, tokens, sleepFn, path, { ...params, pageToken, maxResults: String(PAGE_SIZE) });
        items.push(...(res.items ?? []));
        pageToken = res.nextPageToken;
        if (!pageToken) {
          nextSyncToken = res.nextSyncToken;
          return { items, nextSyncToken };
        }
      }
      throw new Error("pagination_limit_exceeded");
    },
    insert(calendarId, body) {
      return gwrite(fetchImpl, tokens, sleepFn, "POST", eventUrl(calendarId), body, null);
    },
    patch(calendarId, eventId, body, etag) {
      return gwrite(fetchImpl, tokens, sleepFn, "PATCH", eventUrl(calendarId, eventId), body, etag);
    },
    delete(calendarId, eventId, etag) {
      return gwrite(fetchImpl, tokens, sleepFn, "DELETE", eventUrl(calendarId, eventId), undefined, etag);
    },
  };
}
