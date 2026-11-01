// supabase/functions/booking-closure-sync/core.ts
// Sulkukalenterien synkan ydin (ei Deno-/Supabase-riippuvuuksia -> testattavissa mockeilla).
// Kulku per kalenteri: Google events.list (ikkuna-snapshot, singleEvents=true, showDeleted=false) -> booking.apply_closure_events (idempotentti täsmäytys).
// Tietokanta päättää luokittelun (booking.closure_event_rules) ja kirjoittaa space_blocks-rivit; tämä koodi ei tulkitse otsikoita eikä tallenna mitään itse.

export interface GEvent {
  id: string;
  status?: string;
  summary?: string;
  updated?: string;
  start?: { dateTime?: string; date?: string };
  end?: { dateTime?: string; date?: string };
  extendedProperties?: { private?: Record<string, string> };
}
// Merkintä, jonka hallinnasta kalenteriin kirjoitettu tapahtuma saa (extendedProperties.private) -> lukusynkka tunnistaa omakseen eikä tuo takaisin
export const OWN_SOURCE_KEY = "booking_source";
export const OWN_SOURCE_VALUE = "admin";
export const OWN_BLOCK_KEY = "booking_block_id";
export const OWN_TITLE_PREFIX = "[HALLINTA]";
export const isOwnEvent = (e: GEvent): boolean => e?.extendedProperties?.private?.[OWN_SOURCE_KEY] === OWN_SOURCE_VALUE ||
  (typeof e?.summary === "string" && e.summary.startsWith(OWN_TITLE_PREFIX));
export interface TargetCalendar { code: string; google_calendar_id: string; timezone: string }
export interface SyncConfig {
  max_timed_hours?: number; guard_min_deletes?: number; guard_ratio?: number;
  window_back_days?: number; window_forward_months?: number; tombstone_days?: number;
}
export interface Db {
  rpc(fn: string, args?: Record<string, unknown>): Promise<{ data: unknown; error: { message: string; code?: string } | null }>;
}
export interface GWriteEvent {
  id: string; summary: string; description: string; status: "confirmed";
  start: { dateTime?: string; date?: string; timeZone?: string }; end: { dateTime?: string; date?: string; timeZone?: string };
  extendedProperties: { private: Record<string, string> }; transparency: "opaque"; reminders: { useDefault: false };
}
export interface Google {
  listEvents(calendarId: string, timeMin: string, timeMax: string): Promise<GEvent[]>;
  // kirjoitus (hallinta -> kalenteri); tuloksissa 409/404/410 on käsitelty idempotenssina
  insertEvent?(calendarId: string, ev: GWriteEvent): Promise<"created" | "exists">;
  patchEvent?(calendarId: string, eventId: string, ev: Partial<GWriteEvent>): Promise<"patched" | "missing">;
  deleteEvent?(calendarId: string, eventId: string): Promise<"deleted" | "gone">;
  probeWrite?(calendarId: string): Promise<"write_ok" | "no_write_access">;
}
export interface RunOptions { dryRun?: boolean; force?: boolean; calendars?: string[]; now?: Date }
export interface CalendarResult {
  calendar: string; status: "ok" | "guard" | "error"; error?: string; stats?: Record<string, unknown>; conflicts?: number;
}

export class HttpError extends Error {
  constructor(public status: number, public reason: string) { super(`HTTP ${status}${reason ? ` (${reason})` : ""}`); }
}

// Vain turvallinen tekninen tieto poistuu funktiosta (ei tokeneita, avaimia, kalenteri-id:itä tai tapahtumasisältöä).
export function safeError(err: unknown): string {
  if (err instanceof HttpError) {
    if (err.status === 404) return "google_http_404_calendar_not_shared_with_service_account_or_wrong_id";
    if (err.status === 403) return `google_http_403${err.reason ? `_${err.reason}` : ""}_no_access_or_api_disabled`;
    return `google_http_${err.status}${err.reason ? `_${err.reason}` : ""}`;
  }
  if (err instanceof Error) return err.message.replace(/ya29\.[\w.-]+/g, "[redacted]").replace(/[\w.-]+@[\w.-]+/g, "[redacted]").slice(0, 300);
  return "unknown_error";
}

export function syncWindow(cfg: SyncConfig | null | undefined, now = new Date()): { from: string; to: string } {
  const back = Number.isFinite(cfg?.window_back_days) ? Number(cfg!.window_back_days) : 1;
  const fwd = Number.isFinite(cfg?.window_forward_months) ? Number(cfg!.window_forward_months) : 18;
  const from = new Date(now.getTime() - back * 86_400_000);
  const to = new Date(now);
  to.setUTCMonth(to.getUTCMonth() + fwd);
  return { from: from.toISOString(), to: to.toISOString() };
}

// Vain DB-funktion tarvitsemat kentät (pienempi payload; mitään arkaluonteista ei ylimääräistä).
export function slim(e: GEvent): GEvent {
  return { id: e.id, status: e.status, summary: e.summary, updated: e.updated, start: e.start, end: e.end };
}

export async function runSync(db: Db, google: Google, opts: RunOptions = {}): Promise<{ ok: boolean; results: CalendarResult[] }> {
  const t = await db.rpc("closure_sync_targets");
  if (t.error) throw new Error(`targets_failed: ${t.error.message}`);
  const targets = t.data as { config: SyncConfig | null; calendars: TargetCalendar[] };
  const win = syncWindow(targets.config, opts.now ?? new Date());
  const wanted = Array.isArray(opts.calendars) && opts.calendars.length ? new Set(opts.calendars) : null;
  const results: CalendarResult[] = [];

  // peräkkäin tarkoituksella: pieni volyymi (4 kalenteria, ~100 tapahtumaa), yksinkertainen rate limit; kukin kalenteri eristetty try/catchilla
  for (const cal of targets.calendars ?? []) {
    if (wanted && !wanted.has(cal.code)) continue;
    try {
      const raw = await google.listEvents(cal.google_calendar_id, win.from, win.to);
      const events = raw.filter((e) => e && e.id && e.status !== "cancelled" && !isOwnEvent(e)).map(slim);   // omat (hallinnasta kirjoitetut) pois -> ei tuplatuontia
      const r = await db.rpc("apply_closure_events", {
        p_calendar: cal.code, p_events: events, p_window_from: win.from, p_window_to: win.to,
        p_dry_run: opts.dryRun === true, p_force: opts.force === true, p_source: "edge",
      });
      if (r.error) throw new Error(`apply_failed: ${r.error.message}`);
      const d = r.data as { ok: boolean; guard?: boolean; stats?: Record<string, unknown>; conflicts?: unknown[] };
      results.push({
        calendar: cal.code, status: d.ok ? "ok" : (d.guard ? "guard" : "error"), stats: d.stats,
        conflicts: Array.isArray(d.conflicts) ? d.conflicts.length : undefined,
        error: d.guard ? "mass_delete_guard" : undefined,
      });
    } catch (err) {
      const msg = safeError(err);
      results.push({ calendar: cal.code, status: "error", error: msg });
      if (opts.dryRun !== true) {
        // kirjataan epäonnistuminen kalenterin tilaan (näkyy ylläpidon yleiskuvassa); virhe ei estä muiden kalenterien ajoa
        await db.rpc("record_closure_sync_failure", { p_calendar: cal.code, p_error: msg, p_source: "edge" }).catch(() => undefined);
      }
    }
  }
  return { ok: results.every((r) => r.status === "ok"), results };
}

// =====================================================================================================================
// Hallinta -> kalenteri (kirjoitus). Jono: booking.closure_outbox (booking_24_closure_writeback.sql). Kalenteri on vain peili:
// hallinnan sulku on "master"; kalenterista tuodut sulut (closure_event_id) eivät koskaan päädy jonoon (trigger rajaa).
// =====================================================================================================================
export interface OutboxItem {
  id: number; op: "upsert" | "delete"; calendar_code: string; google_calendar_id: string; timezone: string;
  event_id: string; block_id: number; starts_at?: string; ends_at?: string; reason?: string | null;
}
export interface WritebackResult { claimed: number; done: number; failed: number; blocked: number; skipped: number; error?: string }

// Helsingin (tai kalenterin) paikallinen kalenteripäivä + kellonaika annetusta hetkestä
function localParts(iso: string, tz: string): { date: string; time: string } {
  const f = new Intl.DateTimeFormat("sv-SE", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" });
  const [date, time] = f.format(new Date(iso)).split(" ");
  return { date, time };
}
const addDay = (d: string) => new Date(Date.parse(d + "T00:00:00Z") + 86_400_000).toISOString().slice(0, 10);

export function buildEvent(it: OutboxItem): GWriteEvent {
  const reason = (it.reason ?? "").replace(/\s+/g, " ").trim().slice(0, 120);
  const s = localParts(it.starts_at!, it.timezone), e = localParts(it.ends_at!, it.timezone);
  const allDay = s.time === "00:00:00" && e.time === "00:00:00" && e.date > s.date;   // kokopäiväsulku -> koko päivän tapahtuma
  const start = allDay ? { date: s.date } : { dateTime: it.starts_at!, timeZone: it.timezone };
  const end = allDay ? { date: e.date } : { dateTime: it.ends_at!, timeZone: it.timezone };
  return {
    id: it.event_id,
    summary: `${OWN_TITLE_PREFIX} ${reason || "Kiinni"}`,
    description: `Luotu varausjärjestelmän hallinnassa (sulku #${it.block_id}). Älä muokkaa tätä tapahtumaa kalenterissa – muutokset tehdään hallinnassa ja ne päivittävät tämän.`,
    status: "confirmed", start, end,
    extendedProperties: { private: { [OWN_SOURCE_KEY]: OWN_SOURCE_VALUE, [OWN_BLOCK_KEY]: String(it.block_id) } },
    transparency: "opaque", reminders: { useDefault: false },
  };
}

export async function runWriteback(db: Db, google: Google, opts: { limit?: number } = {}): Promise<WritebackResult> {
  const out: WritebackResult = { claimed: 0, done: 0, failed: 0, blocked: 0, skipped: 0 };
  if (!google.insertEvent || !google.patchEvent || !google.deleteEvent) return { ...out, error: "google_write_not_supported" };
  const c = await db.rpc("closure_outbox_claim", { p_limit: opts.limit ?? 25 });
  if (c.error) return { ...out, error: `claim_failed: ${c.error.message}`.slice(0, 200) };
  const items = (c.data as OutboxItem[] | null) ?? [];
  out.claimed = items.length;
  for (const it of items) {
    try {
      let status: string;
      if (it.op === "delete") {
        status = await google.deleteEvent(it.google_calendar_id, it.event_id);
      } else {
        const ev = buildEvent(it);
        status = await google.insertEvent(it.google_calendar_id, ev);
        if (status === "exists") {
          const { id: _id, ...rest } = ev;
          const p = await google.patchEvent(it.google_calendar_id, it.event_id, rest);
          if (p === "missing") status = await google.insertEvent(it.google_calendar_id, ev);   // ehti poistua välissä
          else status = p;
        }
      }
      const r = await db.rpc("closure_outbox_complete", { p_id: it.id, p_result: status });
      if (r.error) throw new Error(`complete_failed: ${r.error.message}`);
      out.done++;
    } catch (err) {
      const noWrite = err instanceof HttpError && err.status === 403 && !["rateLimitExceeded", "userRateLimitExceeded"].includes(err.reason);
      const msg = noWrite ? "no_write_access" : safeError(err);
      const r = await db.rpc("closure_outbox_fail", { p_id: it.id, p_error: msg, p_blocked: noWrite });
      if (noWrite) out.blocked++; else out.failed++;
      if (r.error) out.error = `fail_record_failed: ${r.error.message}`.slice(0, 200);
    }
  }
  return out;
}

export async function probeWrite(db: Db, google: Google): Promise<Record<string, string>> {
  const t = await db.rpc("closure_sync_targets");
  if (t.error) throw new Error(`targets_failed: ${t.error.message}`);
  const res: Record<string, string> = {};
  for (const cal of (t.data as { calendars: TargetCalendar[] }).calendars ?? []) {
    try { res[cal.code] = google.probeWrite ? await google.probeWrite(cal.google_calendar_id) : "unsupported"; } catch (err) { res[cal.code] = safeError(err); }
  }
  return res;
}
