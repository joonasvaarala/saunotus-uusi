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
  /** Peilitila (mitä viimeksi luimme tai kirjoitimme), shift_outbox_claim 20261025140422 alkaen. Puuttuu vanhalta claimilta. */
  mirror?: Mirror | null;
}

export interface Mirror {
  title: string | null;
  starts_at: string | null;
  ends_at: string | null;
  status: string | null;
  updated: string | null;
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

export interface ReadOutcome {
  status: number;
  event: GEvent | null;
  reason: string;
}

export interface GoogleWrites {
  /** Yksittäisen tapahtuman/instanssin tuore tila ja oma etag (vain 412-polku ja toistuvien instanssien esitarkistus). */
  get(calendarId: string, eventId: string): Promise<ReadOutcome>;
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
  complete(id: number, result: "created" | "patched" | "deleted" | "gone" | "converged", updated: string | null, etag: string | null): Promise<void>;
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
  converged: number;
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
  converged?: number;
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

// ---------- 412 / etag ----------
// Toistuvan sarjan muuttamattomat instanssit jakavat Googlessa sarjan etagin (tuotanto 25.10.2026: 53 instanssia, 1 etag),
// joten tallennettu etag ei ole instanssin oma: jokainen instanssi-PATCH vaihtaa sisarten etagin ja ne saavat 412:n.
// Siksi toistuvalle instanssille (ja kun etagia ei ole, esim. 412:n jälkeen tyhjennetty) haetaan ensin instanssin tuore tila
// ja etag (GET), verrataan peilitilaan ja kirjoitetaan tällä tuoreella etagilla. 412 kirjoituksessa -> GET ja:
//   * jo tavoitetilassa -> done (converged) tuoreella etagilla, ei kirjoitusta
//   * ihmisen muutos (kentät eroavat sekä peilistä että tavoitteesta) -> nykyinen conflict-polku (shift_outbox_fail p_conflict)
//   * muuten (vain etag vaihtui, esim. sisarinstanssin PATCH) -> yksi uusi yritys tuoreella etagilla

export type LiveVerdict = "at_target" | "human_edit" | "clean";

/** Sama kuin public._shift_title_norm: tyhjä / '-' -> '-', muuten btrim ja '&' välilyönneillä. */
export function titleNorm(t: string | null | undefined): string {
  const b = (t ?? "").replace(/^\s+|\s+$/g, "");
  if (b === "" || b === "-") return "-";
  return b.replace(/\s*&\s*/g, " & ");
}

function helsinkiMidnight(date: string): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
  if (!m) return null;
  const guess = Date.UTC(+m[1], +m[2] - 1, +m[3]);
  // Europe/Helsinki-poikkeama tuolla hetkellä (UTC+2 / UTC+3)
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "Europe/Helsinki",
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).formatToParts(new Date(guess));
  const get = (k: string) => Number(parts.find((p) => p.type === k)?.value);
  const asUtc = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"));
  return guess - (asUtc - guess);
}

export function instantOf(v: { dateTime?: string; date?: string } | string | null | undefined): number | null {
  if (v == null) return null;
  if (typeof v === "string") {
    const t = Date.parse(v);
    return Number.isNaN(t) ? null : t;
  }
  if (v.dateTime) {
    const t = Date.parse(v.dateTime);
    return Number.isNaN(t) ? null : t;
  }
  if (v.date) return helsinkiMidnight(v.date);
  return null;
}

function liveActive(ev: GEvent): boolean {
  return ev.status !== "cancelled";
}

/** Tuore tapahtuma vs. tavoite (item) ja peili (item.mirror). Ilman peiliä ihmisen muutosta ei voi erottaa -> human_edit (ei kirjoitusta). */
export function classifyLive(item: OutboxItem, ev: GEvent): LiveVerdict {
  const live = {
    active: liveActive(ev),
    title: titleNorm(ev.summary),
    start: instantOf(ev.start),
    end: instantOf(ev.end),
  };
  if (item.op === "delete") {
    if (!live.active) return "at_target";
  } else if (
    live.active && live.title === titleNorm(item.summary) &&
    live.start === instantOf(item.starts_at) && live.end === instantOf(item.ends_at)
  ) {
    return "at_target";
  }
  const m = item.mirror;
  if (!m) return "human_edit";
  const mirrorActive = (m.status ?? "active") !== "cancelled";
  if (live.active !== mirrorActive) return "human_edit";
  if (!live.active) return "clean"; // peruttu kuten peilissä (reactivate-polku): sisältökentät eivät ratkaise
  if (live.title !== titleNorm(m.title)) return "human_edit";
  if (live.start !== instantOf(m.starts_at) || live.end !== instantOf(m.ends_at)) return "human_edit";
  return "clean";
}

/** Esitarkistus ennen PATCH/DELETEä: toistuva instanssi (jaettu sarjan etag) tai etag puuttuu. Vaatii peilin (uusi claim). */
export function needsPrecheck(item: OutboxItem): boolean {
  return item.mirror != null && (item.recurring === true || etagOrNull(item) === null);
}

type Writer = (etag: string | null) => Promise<WriteOutcome>;

async function settleLive(
  item: OutboxItem,
  db: PushDb,
  live: ReadOutcome,
  kind: "patch" | "delete",
  reason: string,
): Promise<{ done: ItemCount } | { etag: string | null }> {
  if (!okStatus(live.status) || !live.event) {
    return { done: await settleHttp(item, { status: live.status, updated: null, etag: null, reason: live.reason }, db, kind) };
  }
  const verdict = classifyLive(item, live.event);
  if (verdict === "at_target") {
    const ev = live.event;
    if (kind === "delete") {
      await db.complete(item.id, "gone", ev.updated ?? null, ev.etag ?? null);
      return { done: { gone: 1 } };
    }
    await db.complete(item.id, "converged", ev.updated ?? null, ev.etag ?? null);
    return { done: { converged: 1 } };
  }
  if (verdict === "human_edit") {
    await db.fail(item.id, reason, false, true, false);
    return { done: { conflicts: 1 } };
  }
  return { etag: live.event.etag ?? null };
}

async function finishWrite(item: OutboxItem, res: WriteOutcome, db: PushDb, kind: "patch" | "delete"): Promise<ItemCount> {
  if (okStatus(res.status)) {
    if (kind === "delete") {
      await db.complete(item.id, "deleted", res.updated, res.etag);
      return { deleted: 1 };
    }
    await db.complete(item.id, "patched", res.updated, res.etag);
    return { patched: 1 };
  }
  return await settleHttp(item, res, db, kind);
}

/** PATCH/DELETE: (esitarkistus) -> kirjoitus -> 412: GET + luokittelu + korkeintaan yksi uusi yritys tuoreella etagilla. */
async function conditionalWrite(
  item: OutboxItem,
  google: GoogleWrites,
  db: PushDb,
  kind: "patch" | "delete",
  write: Writer,
  initialEtag: string | null,
): Promise<ItemCount> {
  let etag = initialEtag;
  if (needsPrecheck(item)) {
    const pre = await settleLive(item, db, await google.get(item.google_calendar_id, item.event_id), kind, "google_human_edit");
    if ("done" in pre) return pre.done;
    etag = pre.etag;
  }
  const res = await write(etag);
  if (res.status !== 412) return await finishWrite(item, res, db, kind);

  const after = await settleLive(item, db, await google.get(item.google_calendar_id, item.event_id), kind, "google_http_412_human_edit");
  if ("done" in after) return after.done;
  const retry = await write(after.etag);
  return await finishWrite(item, retry, db, kind); // toinen 412 -> conflict-polku (shift_outbox_fail), ei silmukkaa
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
        // Tapahtuma on jo olemassa (aiempi oma insert ilman kuittausta). Ei esitarkistusta: insertillä ei ole peiliä.
        // 412 (vain jos etag oli asetettu) käsitellään kuten patchissa.
        const body = insertPatchBody(item);
        const w: Writer = (etag) => google.patch(item.google_calendar_id, item.event_id, body, etag);
        return await conditionalWrite({ ...item, mirror: null }, google, db, "patch", w, etagOrNull(item));
      }
      return await settleHttp(item, res, db, "insert");
    }
    if (item.op === "patch") {
      const body = patchBody(item);
      const w: Writer = (etag) => google.patch(item.google_calendar_id, item.event_id, body, etag);
      return await conditionalWrite(item, google, db, "patch", w, etagOrNull(item));
    }
    if (item.op === "delete") {
      const w: Writer = (etag) => google.delete(item.google_calendar_id, item.event_id, etag);
      return await conditionalWrite(item, google, db, "delete", w, etagOrNull(item));
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
    converged: 0,
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
    out.converged += c.converged ?? 0;
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

/** Yksittäisen tapahtuman GET. 404/410/403 palautetaan tilana (ei poikkeusta), 429/5xx/rate limit uusitaan kuten gget. */
async function gread(
  fetchImpl: typeof fetch,
  tokens: TokenSource,
  sleepFn: (ms: number) => Promise<void>,
  url: URL,
): Promise<ReadOutcome> {
  for (let attempt = 0; ; attempt++) {
    const res = await fetchImpl(url, { headers: { authorization: `Bearer ${await tokens.token()}` } });
    const parsed = await readJson(res);
    if (res.ok) {
      const ev = parsed.json as GEvent | null;
      return { status: res.status, event: ev && typeof ev === "object" ? slim(ev) : null, reason: "" };
    }
    const reason = reasonOf(parsed.json);
    if (res.status === 401 && attempt === 0) {
      tokens.invalidate?.();
      continue;
    }
    if (res.status === 404 || res.status === 410) return { status: res.status, event: null, reason };
    const rateLimited = res.status === 403 && (reason === "rateLimitExceeded" || reason === "userRateLimitExceeded");
    const retryable = res.status === 429 || res.status >= 500 || rateLimited;
    if (retryable && attempt < 4) {
      await sleepFn(Math.min(16000, 500 * 2 ** attempt) + Math.floor(Math.random() * 250));
      continue;
    }
    if (res.status === 403 && !rateLimited) return { status: 403, event: null, reason };
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
    get(calendarId, eventId) {
      return gread(fetchImpl, tokens, sleepFn, eventUrl(calendarId, eventId));
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
