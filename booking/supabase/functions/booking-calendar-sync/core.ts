// Varauskalenterin viennin ydin. Ei Deno- eikä Google-riippuvuutta: testit antavat feikin.
// Suunta on vain varausjärjestelmä -> kalenteri. Kalenterin muutos ei palaa varaukseksi;
// live-ajossa olemassa oleva tapahtuma kirjoitetaan aina uudelleen (patch), jotta käsin tehty muutos palautuu.
// Kuivaharjoitus ja pois-tila eivät kutsu kirjoitusmetodeja.

export interface DesiredEvent {
  event_key: string;
  kind: "reservation" | "shift";
  reservation_id?: number | null;
  resource_code: string;
  google_calendar_id?: string | null;
  google_event_id: string;
  summary: string;
  description: string;
  starts_at: string;
  ends_at: string;
  content_hash: string;
  timezone: string;
}

export interface MappedEvent {
  event_key: string;
  google_calendar_id: string;
  google_event_id: string;
  content_hash?: string;
  starts_at?: string;
  ends_at?: string;
}

export interface ExportPlan {
  ok?: boolean;
  mode: string;
  busy?: boolean;
  run_id?: string | null;
  events?: DesiredEvent[];
  mapped?: MappedEvent[];
  closure_calendar_ids?: string[];
}

export interface GWriteEvent {
  id?: string;
  summary: string;
  description: string;
  status: "confirmed";
  start: { dateTime: string; timeZone: string };
  end: { dateTime: string; timeZone: string };
  extendedProperties: { private: Record<string, string> };
  transparency: "opaque";
  reminders: { useDefault: false };
}

export interface Google {
  insertEvent(calendarId: string, ev: GWriteEvent): Promise<"created" | "exists">;
  patchEvent(calendarId: string, eventId: string, ev: GWriteEvent): Promise<"patched" | "missing">;
  deleteEvent(calendarId: string, eventId: string): Promise<"deleted" | "gone">;
}

export interface SyncOp {
  op: "insert" | "patch" | "delete";
  eventKey: string;
  calendarId: string;
  eventId: string;
  body?: GWriteEvent;
  row?: DesiredEvent;
}

export class HttpError extends Error {
  constructor(public status: number, public reason: string) {
    super(`HTTP ${status}${reason ? ` (${reason})` : ""}`);
  }
}

const EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
const PHONE = /(^|\s)((\+|00|0)\d[\d .()-]{5,20}\d)\b/g;

/** Poistaa sähköpostin ja puhelinnumeron. Tilausnumero (ei ala nollalla tai plus-merkillä) säilyy. */
export function redactContacts(text: string): string {
  return String(text ?? "")
    .replace(EMAIL, "")
    .replace(PHONE, "$1")
    .replace(/[ \t]{2,}/g, " ")
    .replace(/[ \t]+\n/g, "\n")
    .trim();
}

export function toGoogleEvent(ev: DesiredEvent): GWriteEvent {
  const tz = ev.timezone || "Europe/Helsinki";
  return {
    id: ev.google_event_id,
    summary: redactContacts(ev.summary).slice(0, 180),
    description: redactContacts(ev.description).slice(0, 7000),
    status: "confirmed",
    start: { dateTime: ev.starts_at, timeZone: tz },
    end: { dateTime: ev.ends_at, timeZone: tz },
    extendedProperties: { private: { booking_source: "booking_calendar", booking_key: ev.event_key, booking_kind: ev.kind } },
    transparency: "opaque",
    reminders: { useDefault: false },
  };
}

export function planOps(plan: ExportPlan): { ops: SyncOp[]; unconfigured: number; blocked: number } {
  const closure = new Set((plan.closure_calendar_ids ?? []).filter(Boolean));
  const mapped = new Map((plan.mapped ?? []).map((m) => [m.event_key, m]));
  const ops: SyncOp[] = [];
  const wanted = new Set<string>();
  let unconfigured = 0;
  let blocked = 0;
  for (const ev of plan.events ?? []) {
    const cal = (ev.google_calendar_id ?? "").trim();
    if (!cal) { unconfigured++; continue; }
    if (closure.has(cal)) { blocked++; continue; }
    wanted.add(ev.event_key);
    const prev = mapped.get(ev.event_key);
    const body = toGoogleEvent(ev);
    if (prev && prev.google_calendar_id !== cal) {
      if (!closure.has(prev.google_calendar_id)) {
        ops.push({ op: "delete", eventKey: ev.event_key, calendarId: prev.google_calendar_id, eventId: prev.google_event_id });
      } else blocked++;
      ops.push({ op: "insert", eventKey: ev.event_key, calendarId: cal, eventId: ev.google_event_id, body, row: ev });
    } else if (!prev) {
      ops.push({ op: "insert", eventKey: ev.event_key, calendarId: cal, eventId: ev.google_event_id, body, row: ev });
    } else {
      ops.push({ op: "patch", eventKey: ev.event_key, calendarId: cal, eventId: prev.google_event_id, body: { ...body, id: undefined }, row: ev });
    }
  }
  for (const m of plan.mapped ?? []) {
    if (wanted.has(m.event_key)) continue;
    if (closure.has(m.google_calendar_id)) { blocked++; continue; }
    ops.push({ op: "delete", eventKey: m.event_key, calendarId: m.google_calendar_id, eventId: m.google_event_id });
  }
  return { ops, unconfigured, blocked };
}

export interface RunResult {
  ok: boolean;
  mode: string;
  skipped?: string;
  dryRun?: boolean;
  inserted: number;
  patched: number;
  deleted: number;
  failed: number;
  unconfigured: number;
  blocked: number;
  error?: string;
}

export function safeError(err: unknown): string {
  if (err instanceof HttpError) {
    if (err.status === 404) return "google_http_404_calendar_not_shared_or_wrong_id";
    if (err.status === 403) return `google_http_403${err.reason ? `_${err.reason}` : ""}_no_access`;
    return `google_http_${err.status}${err.reason ? `_${err.reason}` : ""}`;
  }
  if (err instanceof Error) return err.message.replace(/ya29\.[\w.-]+/g, "[redacted]").replace(/[\w.-]+@[\w.-]+/g, "[redacted]").slice(0, 300);
  return "unknown_error";
}

export interface Db {
  plan(): Promise<ExportPlan>;
  finish(payload: Record<string, unknown>): Promise<void>;
}

function counts(ops: SyncOp[]) {
  return {
    would_insert: ops.filter((o) => o.op === "insert").length,
    would_patch: ops.filter((o) => o.op === "patch").length,
    would_delete: ops.filter((o) => o.op === "delete").length,
  };
}

export async function runExport(db: Db, google: Google, opts: { dryRun?: boolean } = {}): Promise<RunResult> {
  const plan = await db.plan();
  const mode = plan.mode || "off";
  const empty = { inserted: 0, patched: 0, deleted: 0, failed: 0, unconfigured: 0, blocked: 0 };
  if (mode === "off") return { ok: true, mode, skipped: "off", ...empty };
  if (plan.busy) return { ok: true, mode, skipped: "busy", ...empty };
  const { ops, unconfigured, blocked } = planOps(plan);
  const base = counts(ops);
  if (mode !== "live" || opts.dryRun) {
    await db.finish({
      run_id: plan.run_id ?? null,
      stats: { dry_run: true, ...base, unconfigured, blocked },
      upserts: [],
      deletes: [],
    });
    return { ok: true, mode, dryRun: true, ...empty, unconfigured, blocked, inserted: base.would_insert, patched: base.would_patch, deleted: base.would_delete };
  }
  const upserts: Record<string, unknown>[] = [];
  const deletes: string[] = [];
  let inserted = 0, patched = 0, deleted = 0, failed = 0;
  let error: string | undefined;
  for (const op of ops) {
    try {
      if (op.op === "delete") {
        await google.deleteEvent(op.calendarId, op.eventId);
        deletes.push(op.eventKey);
        deleted++;
      } else if (op.op === "insert" && op.body && op.row) {
        const status = await google.insertEvent(op.calendarId, op.body);
        if (status === "exists") {
          const { id: _id, ...rest } = op.body;
          const p = await google.patchEvent(op.calendarId, op.eventId, rest);
          if (p === "missing") await google.insertEvent(op.calendarId, op.body);
        }
        upserts.push(rowOf(op.row));
        inserted++;
      } else if (op.op === "patch" && op.body && op.row) {
        const p = await google.patchEvent(op.calendarId, op.eventId, op.body);
        if (p === "missing") {
          const created = toGoogleEvent(op.row);
          const ins = await google.insertEvent(op.calendarId, created);
          if (ins === "exists") await google.patchEvent(op.calendarId, op.eventId, { ...created, id: undefined });
        }
        upserts.push(rowOf(op.row));
        patched++;
      }
    } catch (err) {
      failed++;
      error = error ?? safeError(err);
    }
  }
  await db.finish({
    run_id: plan.run_id ?? null,
    error: error ?? null,
    stats: { dry_run: false, inserted, patched, deleted, failed, unconfigured, blocked },
    upserts,
    deletes,
  });
  return { ok: failed === 0, mode, inserted, patched, deleted, failed, unconfigured, blocked, error };
}

function rowOf(ev: DesiredEvent): Record<string, unknown> {
  return {
    event_key: ev.event_key,
    kind: ev.kind,
    reservation_id: ev.reservation_id ?? null,
    resource_code: ev.resource_code,
    google_calendar_id: ev.google_calendar_id,
    google_event_id: ev.google_event_id,
    content_hash: ev.content_hash,
    starts_at: ev.starts_at,
    ends_at: ev.ends_at,
  };
}
