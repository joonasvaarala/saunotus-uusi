// calendar-sync-v2: 412 / jaettu sarjan etag (calsync412, 25.10.2026). Ei Googlea eikä Supabasea: tilallinen feikkikalenteri.
// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/calendar-sync-v2/core_412_test.ts
//
// Feikki mallintaa pahimman tapauksen (tuotannossa havaittu): kaikki sarjan instanssit raportoivat sarjan etagin, ja JOKAINEN
// kirjoitus mihin tahansa instanssiin vaihtaa sen -> kaikkien sisarten etag vaihtuu. If-Match väärällä etagilla -> 412.
import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  classifyLive,
  createGoogle,
  instantOf,
  type Mirror,
  needsPrecheck,
  type OutboxItem,
  type PushDb,
  runPush,
  titleNorm,
} from "./core.ts";

const CAL = "shift-test@group.calendar.google.com";
const SERIES = "ksenia_mon";
const noop = async () => {};
const enabled = { db_first_enabled: true, push_enabled: true };

// Maanantait 09:00–15:00 -> tavoite 09:00–16:00 (Helsinki, talviaika UTC+2 marraskuusta)
const OLD_TITLE = "Ksenia";
const NEW_TITLE = "Ksenia";
function mondays(n: number): string[] {
  const out: string[] = [];
  let t = Date.UTC(2026, 10, 2, 7, 0); // ma 2.11.2026 09:00 Helsinki
  for (let i = 0; i < n; i++, t += 7 * 86_400_000) out.push(new Date(t).toISOString());
  return out;
}
const iso = (ms: number) => new Date(ms).toISOString();
const plusH = (s: string, h: number) => iso(Date.parse(s) + h * 3_600_000);
const instanceId = (startIso: string) => `${SERIES}_${startIso.replace(/[-:]/g, "").replace(/\.\d+Z$/, "Z")}`;

interface Ev {
  id: string;
  status: string;
  summary: string;
  start: string;
  end: string;
  updated: string;
}

interface Seen {
  method: string;
  id: string;
  ifMatch: string | null;
  status: number;
}

class FakeCalendar {
  events = new Map<string, Ev>();
  seriesEtag = '"s-0"';
  private n = 0;
  private clock = Date.UTC(2026, 9, 25, 13, 0);
  seen: Seen[] = [];
  /** kutsutaan jokaisen GETin jälkeen (esim. joku muu kirjoittaa sisarta GETin ja PATCHin välissä) */
  afterGet: ((id: string, nth: number) => void) | null = null;
  private getsById = new Map<string, number>();

  add(id: string, summary: string, start: string, end: string) {
    this.events.set(id, { id, status: "confirmed", summary, start, end, updated: this.tick() });
  }
  private tick(): string {
    this.clock += 1000;
    return iso(this.clock);
  }
  rotate() {
    this.seriesEtag = `"s-${++this.n}"`;
  }
  etagOf(_id: string) {
    return this.seriesEtag; // jaettu sarjan etag
  }
  /** ihmisen muutos kalenterin käyttöliittymässä */
  humanEdit(id: string, patch: Partial<Ev>) {
    const e = this.events.get(id)!;
    Object.assign(e, patch, { updated: this.tick() });
    this.rotate();
  }
  /** joku muu kirjoittaa sarjaan (esim. toisen instanssin kuvaus): kenttämme ennallaan, etag vaihtuu */
  siblingWrite() {
    this.rotate();
  }
  json(e: Ev) {
    return {
      id: e.id,
      status: e.status,
      summary: e.summary,
      etag: this.etagOf(e.id),
      updated: e.updated,
      recurringEventId: SERIES,
      start: { dateTime: e.start, timeZone: "Europe/Helsinki" },
      end: { dateTime: e.end, timeZone: "Europe/Helsinki" },
    };
  }

  fetchImpl: typeof fetch = async (input, init) => {
    const url = new URL(String(input));
    if (url.origin !== "https://www.googleapis.com") throw new Error("unexpected_url");
    const prefix = `/calendar/v3/calendars/${encodeURIComponent(CAL)}/events/`;
    if (!url.pathname.startsWith(prefix)) throw new Error(`unexpected_path ${url.pathname}`);
    const id = decodeURIComponent(url.pathname.slice(prefix.length));
    const method = init?.method ?? "GET";
    const ifMatch = new Headers(init?.headers).get("If-Match");
    const e = this.events.get(id);
    const reply = (status: number, body: unknown) => {
      this.seen.push({ method, id, ifMatch, status });
      if (body == null) return new Response(null, { status });
      return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
    };
    if (!e) return reply(404, { error: { errors: [{ reason: "notFound" }] } });
    if (method === "GET") {
      const r = reply(200, this.json(e));
      const nth = (this.getsById.get(id) ?? 0) + 1;
      this.getsById.set(id, nth);
      this.afterGet?.(id, nth);
      return r;
    }
    if (ifMatch && ifMatch !== this.etagOf(id)) return reply(412, { error: { errors: [{ reason: "conditionNotMet" }] } });
    if (method === "PATCH") {
      const body = JSON.parse(String(init?.body ?? "{}"));
      if (body.summary !== undefined) e.summary = body.summary;
      if (body.start?.dateTime) e.start = iso(Date.parse(body.start.dateTime));
      if (body.end?.dateTime) e.end = iso(Date.parse(body.end.dateTime));
      if (body.status) e.status = body.status;
      e.updated = this.tick();
      this.rotate();
      return reply(200, this.json(e));
    }
    if (method === "DELETE") {
      e.status = "cancelled";
      e.updated = this.tick();
      this.rotate();
      return reply(204, null);
    }
    throw new Error(`unexpected_method ${method}`);
  };
}

function recordingDb(items: OutboxItem[]) {
  const completes: Array<{ id: number; result: string; updated: string | null; etag: string | null }> = [];
  const fails: Array<{ id: number; error: string; blocked: boolean; conflict: boolean; missing: boolean }> = [];
  const db: PushDb = {
    config: async () => enabled,
    claim: async () => items,
    complete: async (id, result, updated, etag) => {
      completes.push({ id, result, updated, etag });
    },
    fail: async (id, error, blocked = false, conflict = false, missing = false) => {
      fails.push({ id, error, blocked, conflict, missing });
    },
  };
  return { db, completes, fails };
}

async function push(cal: FakeCalendar, items: OutboxItem[]) {
  const rec = recordingDb(items);
  const google = createGoogle(cal.fetchImpl, { token: async () => "t" }, noop);
  const out = await runPush({ sourceId: "src", dryRun: false, pushRequested: true, killSwitch: false, db: rec.db, google });
  return { out, ...rec };
}

/** Kalenteri, jossa n maanantai-instanssia 09–15, ja jonon itemit tavoitteella 09–16. */
function scenario(n: number, opts: { recurring?: boolean; mirror?: boolean } = {}) {
  const cal = new FakeCalendar();
  const items: OutboxItem[] = mondays(n).map((s, i) => {
    const id = instanceId(s);
    cal.add(id, OLD_TITLE, s, plusH(s, 6));
    const mirror: Mirror = { title: OLD_TITLE, starts_at: s, ends_at: plusH(s, 6), status: "active", updated: null };
    return {
      id: 124 + i,
      op: "patch",
      shift_id: `00000000-0000-0000-0000-${String(i).padStart(12, "0")}`,
      version: 3,
      google_calendar_id: CAL,
      calendar_name: "Saunottaja",
      event_id: id,
      etag: cal.seriesEtag, // pull tallensi sarjan etagin kaikille
      timezone: "Europe/Helsinki",
      summary: NEW_TITLE,
      starts_at: s,
      ends_at: plusH(s, 7),
      title_changed: false,
      time_changed: true,
      reactivate: false,
      recurring: opts.recurring !== false,
      attempt: 1,
      ...(opts.mirror === false ? {} : { mirror }),
    };
  });
  return { cal, items };
}

const writes = (cal: FakeCalendar) => cal.seen.filter((s) => s.method !== "GET");
const count412 = (cal: FakeCalendar) => cal.seen.filter((s) => s.status === 412).length;

Deno.test("kontrolli: vanha käytös (ei peiliä) toistaa häiriön – 1 patch, loput 412 -> conflict", async () => {
  const { cal, items } = scenario(52, { mirror: false });
  const { out, completes, fails } = await push(cal, items);
  assertEquals(out.patched, 1);
  assertEquals(out.conflicts, 51);
  assertEquals(completes.length, 1);
  assertEquals(fails.length, 51);
  assertEquals(count412(cal), 51);
  assert(writes(cal).length === 52, "ei uusintayritystä ilman peiliä");
});

Deno.test("kaikki 52 toistuvaa instanssia päivittyvät yhdellä ajolla, vaikka sisarten etag vaihtuu jokaisen patchin jälkeen", async () => {
  const { cal, items } = scenario(52);
  const { out, completes, fails } = await push(cal, items);
  assertEquals(out.claimed, 52);
  assertEquals(out.patched, 52);
  assertEquals(out.conflicts, 0);
  assertEquals(out.failed, 0);
  assertEquals(fails, []);
  assertEquals(completes.length, 52);
  assert(completes.every((c) => c.result === "patched" && c.etag !== null));
  for (const it of items) assertEquals(cal.events.get(it.event_id)!.end, it.ends_at);
  // jokainen PATCH lähti instanssin juuri haetulla (tuoreella) etagilla, ei jaetulla tallennetulla
  const ws = writes(cal);
  assertEquals(ws.length, 52);
  assert(ws.every((w) => w.status === 200 && w.ifMatch !== null));
  assertEquals(new Set(ws.map((w) => w.ifMatch)).size, 52);
  assertEquals(cal.seen.filter((s) => s.method === "GET").length, 52);
  // ajon aikana sarjan etag vaihtui 52 kertaa
  assertEquals(cal.seriesEtag, '"s-52"');
});

Deno.test("412-polku: etag vaihtuu GETin ja PATCHin välissä -> uusi GET ja yksi uusi yritys, kaikki N valmiiksi", async () => {
  const { cal, items } = scenario(10);
  cal.afterGet = (_id, nth) => {
    if (nth === 1) cal.siblingWrite(); // joku kirjoittaa sarjaan juuri ennen PATCHiamme
  };
  const { out, fails, completes } = await push(cal, items);
  assertEquals(out.patched, 10);
  assertEquals(out.conflicts, 0);
  assertEquals(fails, []);
  assertEquals(completes.length, 10);
  assertEquals(count412(cal), 10);
  // per instanssi: GET, PATCH(412), GET, PATCH(200)
  assertEquals(cal.seen.slice(0, 4).map((s) => `${s.method}:${s.status}`), ["GET:200", "PATCH:412", "GET:200", "PATCH:200"]);
});

Deno.test("412-polku ilman esitarkistusta (ei-toistuva, vanhentunut tallennettu etag): GET + yksi uusi yritys", async () => {
  const { cal, items } = scenario(5, { recurring: false });
  // tallennettu etag on validi vain ensimmäiselle -> sisaret saavat 412:n, kuten häiriössä
  const { out, fails } = await push(cal, items);
  assertEquals(out.patched, 5);
  assertEquals(fails, []);
  assertEquals(count412(cal), 4);
  assertEquals(writes(cal).length, 9); // 1 + 4 * (412 + uusinta)
});

Deno.test("ihmisen muutos havaitaan yhä (esitarkistus): ei kirjoitusta, conflict-polku, muut instanssit päivittyvät", async () => {
  const { cal, items } = scenario(5);
  const victim = items[2];
  cal.humanEdit(victim.event_id, { start: plusH(victim.starts_at, 1) }); // joku siirsi alun 10:00:aan
  const { out, fails, completes } = await push(cal, items);
  assertEquals(out.patched, 4);
  assertEquals(out.conflicts, 1);
  assertEquals(fails, [{ id: victim.id, error: "google_human_edit", blocked: false, conflict: true, missing: false }]);
  assert(!completes.some((c) => c.id === victim.id));
  assert(!writes(cal).some((w) => w.id === victim.event_id), "ihmisen muokkaamaan instanssiin ei kirjoiteta");
  assertEquals(cal.events.get(victim.event_id)!.start, plusH(victim.starts_at, 1));
});

Deno.test("ihmisen muutos havaitaan yhä (412-polku): GET näyttää eri kentät -> conflict, ei uusintaa", async () => {
  const { cal, items } = scenario(1, { recurring: false });
  const it = items[0];
  cal.humanEdit(it.event_id, { summary: "Ksenia & Anni" });
  const { out, fails } = await push(cal, items);
  assertEquals(out.conflicts, 1);
  assertEquals(out.patched, 0);
  assertEquals(fails[0].error, "google_http_412_human_edit");
  assertEquals(fails[0].conflict, true);
  assertEquals(cal.seen.map((s) => `${s.method}:${s.status}`), ["PATCH:412", "GET:200"]);
  assertEquals(cal.events.get(it.event_id)!.summary, "Ksenia & Anni");
});

Deno.test("jo tavoitetilassa oleva instanssi merkitään valmiiksi tuoreella etagilla ilman kirjoitusta", async () => {
  const { cal, items } = scenario(3);
  const done = items[1];
  cal.humanEdit(done.event_id, { end: done.ends_at }); // joku teki saman muutoksen jo käsin
  const { out, completes, fails } = await push(cal, items);
  assertEquals(fails, []);
  assertEquals(out.patched, 2);
  assertEquals(out.converged, 1);
  const c = completes.find((x) => x.id === done.id)!;
  assertEquals(c.result, "converged");
  assert(c.etag !== null && c.updated !== null);
  assert(!writes(cal).some((w) => w.id === done.event_id));
});

Deno.test("jo tavoitetilassa (412-polku): PATCH 412 -> GET = tavoite -> converged", async () => {
  const { cal, items } = scenario(1, { recurring: false });
  cal.humanEdit(items[0].event_id, { end: items[0].ends_at });
  const { out, completes } = await push(cal, items);
  assertEquals(out.converged, 1);
  assertEquals(completes[0].result, "converged");
  assertEquals(completes[0].etag, cal.seriesEtag);
  assertEquals(cal.seen.map((s) => `${s.method}:${s.status}`), ["PATCH:412", "GET:200"]);
});

Deno.test("toinen 412 uusinnan jälkeen -> conflict, korkeintaan 2 kirjoitusta (ei silmukkaa)", async () => {
  const { cal, items } = scenario(1);
  cal.afterGet = () => cal.siblingWrite(); // aina kilpailu
  const { out, fails } = await push(cal, items);
  assertEquals(out.conflicts, 1);
  assertEquals(fails[0].error, "google_http_412");
  assertEquals(writes(cal).length, 2);
});

Deno.test("toistuvan instanssin delete: esitarkistus + tuore etag; jo peruttu -> gone", async () => {
  const { cal, items } = scenario(2);
  const del = items.map((i) => ({ ...i, op: "delete" as const }));
  cal.events.get(del[1].event_id)!.status = "cancelled";
  const { out, completes } = await push(cal, del);
  assertEquals(out.deleted, 1);
  assertEquals(out.gone, 1);
  assertEquals(completes.map((c) => c.result), ["deleted", "gone"]);
  assertEquals(writes(cal).length, 1);
});

Deno.test("esitarkistus vain toistuville tai ilman etagia, ja vain kun peili on mukana", () => {
  const { items } = scenario(1);
  const it = items[0];
  assertEquals(needsPrecheck(it), true);
  assertEquals(needsPrecheck({ ...it, recurring: false }), false);
  assertEquals(needsPrecheck({ ...it, recurring: false, etag: null }), true);
  assertEquals(needsPrecheck({ ...it, recurring: false, etag: "  " }), true);
  assertEquals(needsPrecheck({ ...it, mirror: undefined }), false);
});

Deno.test("classifyLive: otsikon normalisointi, peruttu, koko päivä Helsingin ajassa", () => {
  const { items } = scenario(1);
  const it = items[0];
  const base = { id: it.event_id, status: "confirmed", summary: " Ksenia ", start: { dateTime: it.starts_at }, end: { dateTime: it.ends_at } };
  assertEquals(classifyLive(it, base), "at_target");
  assertEquals(classifyLive(it, { ...base, end: { dateTime: it.mirror!.ends_at! } }), "clean");
  assertEquals(classifyLive(it, { ...base, status: "cancelled" }), "human_edit");
  assertEquals(classifyLive({ ...it, mirror: { ...it.mirror!, status: "cancelled" }, reactivate: true }, { ...base, status: "cancelled" }), "clean");
  assertEquals(classifyLive({ ...it, mirror: null }, { ...base, end: { dateTime: it.mirror!.ends_at! } }), "human_edit");
  assertEquals(titleNorm("A&B"), "A & B");
  assertEquals(titleNorm("  A  &   B "), "A & B");
  assertEquals(titleNorm(""), "-");
  assertEquals(titleNorm(" - "), "-");
  assertEquals(instantOf({ date: "2026-11-02" }), Date.parse("2026-11-01T22:00:00Z"));
  assertEquals(instantOf({ date: "2026-07-01" }), Date.parse("2026-06-30T21:00:00Z"));
  assertEquals(instantOf("2026-11-02T09:00:00+02:00"), Date.parse("2026-11-02T07:00:00Z"));
});
