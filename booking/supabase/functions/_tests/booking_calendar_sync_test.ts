// Varauskalenterin vienti ilman Googlea ja ilman verkkoa.
// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/_tests/booking_calendar_sync_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { planOps, redactContacts, runExport, toGoogleEvent, type Db, type DesiredEvent, type ExportPlan, type Google } from "../booking-calendar-sync/core.ts";
import { createGoogle } from "../booking-calendar-sync/google.ts";

const CAL = "varaukset-test@group.calendar.google.com";
const CLOSURE = "sulku-test@group.calendar.google.com";

function ev(over: Partial<DesiredEvent> = {}): DesiredEvent {
  return {
    event_key: "r:42",
    kind: "reservation",
    reservation_id: 42,
    resource_code: "savusauna",
    google_calendar_id: CAL,
    google_event_id: "bkr00000042",
    summary: "Savusauna – yksityisvaraus, 8 hlö",
    description: "Tilaus #88011401\nMaija\nHallinta: https://example.test/hallinta/#/varaukset?q=88011401",
    starts_at: "2026-12-01T06:00:00.000Z",
    ends_at: "2026-12-01T09:00:00.000Z",
    content_hash: "abc",
    timezone: "Europe/Helsinki",
    ...over,
  };
}

Deno.test("redact säilyttää tilausnumeron ja poistaa sähköpostin sekä puhelimen", () => {
  const text = "Tilaus #88011401 Maija 0401234567 maija@example.test +358401112233";
  const out = redactContacts(text);
  assert(out.includes("#88011401"));
  assert(!out.includes("@"));
  assert(!out.includes("0401234567"));
  assert(!out.includes("+358"));
  assertEquals(redactContacts("040 123 4567"), "");
  assertEquals(redactContacts("Hallinta: https://example.test/hallinta/#/varaukset?q=88011401"), "Hallinta: https://example.test/hallinta/#/varaukset?q=88011401");
});

Deno.test("planOps: lisäys, aina patch, siirto, poisto, sulku ja tyhjä kalenteri", () => {
  const shift = ev({ event_key: "s:savusauna|a|b", kind: "shift", reservation_id: null, google_event_id: "bksabcdef0123456789abcd" });
  const bare = ev({ event_key: "r:7", google_calendar_id: "", google_event_id: "bkr00000007" });
  const blocked = ev({ event_key: "r:8", google_calendar_id: CLOSURE, google_event_id: "bkr00000008" });
  const plan: ExportPlan = {
    mode: "live",
    closure_calendar_ids: [CLOSURE],
    events: [ev(), shift, bare, blocked],
    mapped: [
      { event_key: "r:42", google_calendar_id: CAL, google_event_id: "bkr00000042" },
      { event_key: "s:savusauna|a|b", google_calendar_id: "vanha-kalenteri", google_event_id: "bksabcdef0123456789abcd" },
      { event_key: "s:savusauna|old", google_calendar_id: CAL, google_event_id: "bksffff0123456789abcdef" },
      { event_key: "r:9", google_calendar_id: CLOSURE, google_event_id: "bkr00000009" },
    ],
  };
  const { ops, unconfigured, blocked: nBlocked } = planOps(plan);
  assertEquals(unconfigured, 1);
  assertEquals(nBlocked, 2);
  assert(ops.some((o) => o.op === "patch" && o.eventKey === "r:42"));
  assert(ops.some((o) => o.op === "delete" && o.eventKey === "s:savusauna|a|b" && o.calendarId === "vanha-kalenteri"));
  assert(ops.some((o) => o.op === "insert" && o.eventKey === "s:savusauna|a|b" && o.calendarId === CAL));
  assert(ops.some((o) => o.op === "delete" && o.eventKey === "s:savusauna|old"));
  assert(!ops.some((o) => o.calendarId === CLOSURE));
  assert(!ops.some((o) => o.eventKey === "r:7" || o.eventKey === "r:8" || o.eventKey === "r:9"));
  const again = planOps({ mode: "live", events: [ev()], mapped: [{ event_key: "r:42", google_calendar_id: CAL, google_event_id: "bkr00000042" }] });
  assertEquals(again.ops.map((o) => o.op), ["patch"]);
});

Deno.test("planOps: sama tarkiste ohitetaan, eri tarkiste ja täysi kirjoitus päivittävät", () => {
  const mapped = [{ event_key: "r:42", google_calendar_id: CAL, google_event_id: "bkr00000042", content_hash: "abc" }];
  const same = planOps({ mode: "live", reconcile: false, events: [ev()], mapped });
  assertEquals(same.ops, []);
  assertEquals(same.unchanged, 1);

  const changed = planOps({ mode: "live", events: [ev({ content_hash: "def" })], mapped });
  assertEquals(changed.ops.map((o) => o.op), ["patch"]);
  assertEquals(changed.unchanged, 0);

  const full = planOps({ mode: "live", reconcile: true, events: [ev()], mapped });
  assertEquals(full.ops.map((o) => o.op), ["patch"]);
  assertEquals(full.unchanged, 0);

  const gone = planOps({
    mode: "live",
    reconcile: false,
    events: [],
    mapped,
  });
  assertEquals(gone.ops.map((o) => o.op), ["delete"]);
});

Deno.test("toGoogleEvent merkitsee lähteen eikä laita puhelinta", () => {
  const g = toGoogleEvent(ev({ summary: "Savusauna 0401234567", description: "Tilaus #88011401\nmaija@example.test" }));
  assertEquals(g.extendedProperties.private.booking_source, "booking_calendar");
  assertEquals(g.extendedProperties.private.booking_key, "r:42");
  assert(!g.summary.includes("040"));
  assert(g.description.includes("#88011401"));
  assert(!g.description.includes("@"));
  assertEquals(g.reminders.useDefault, false);
});

function throwingGoogle(): Google {
  const boom = () => { throw new Error("google_write_called"); };
  return { insertEvent: boom, patchEvent: boom, deleteEvent: boom };
}

Deno.test("off ja dry_run eivät kirjoita Googleen", async () => {
  const box: { payload: Record<string, unknown> | null } = { payload: null };
  const db: Db = {
    plan: async () => ({ mode: "off", events: [ev()], mapped: [] }),
    finish: async (p) => { box.payload = p; },
  };
  const off = await runExport(db, throwingGoogle());
  assertEquals(off.skipped, "off");
  assertEquals(box.payload, null);

  const dryDb: Db = {
    plan: async () => ({ mode: "dry_run", run_id: null, events: [ev()], mapped: [], closure_calendar_ids: [] }),
    finish: async (p) => { box.payload = p; },
  };
  const dry = await runExport(dryDb, throwingGoogle());
  assertEquals(dry.dryRun, true);
  assertEquals(dry.inserted, 1);
  const stats = box.payload?.stats as { dry_run: boolean };
  assertEquals((box.payload?.upserts as unknown[]).length, 0);
  assertEquals(stats.dry_run, true);
});

Deno.test("live: 409 johtaa patchiin ja 404-poisto onnistuu", async () => {
  const calls: string[] = [];
  const google: Google = {
    async insertEvent() { calls.push("insert"); return "exists"; },
    async patchEvent() { calls.push("patch"); return "patched"; },
    async deleteEvent() { calls.push("delete"); return "gone"; },
  };
  const box: { payload: Record<string, unknown> | null } = { payload: null };
  const db: Db = {
    plan: async () => ({
      mode: "live",
      run_id: "run-1",
      events: [ev()],
      mapped: [{ event_key: "s:old", google_calendar_id: CAL, google_event_id: "bksgone0123456789abcdef" }],
    }),
    finish: async (p) => { box.payload = p; },
  };
  const out = await runExport(db, google);
  assertEquals(calls, ["insert", "patch", "delete"]);
  assertEquals(out.inserted, 1);
  assertEquals(out.deleted, 1);
  assertEquals(out.failed, 0);
  assertEquals((box.payload?.upserts as { event_key: string }[])[0].event_key, "r:42");
  assert((box.payload?.deletes as string[]).includes("s:old"));
});

Deno.test("live ohittaa saman tarkisteen eikä leimaa täyttä kirjoitusta", async () => {
  const google = throwingGoogle();
  const box: { payload: Record<string, unknown> | null } = { payload: null };
  const db: Db = {
    plan: async () => ({
      mode: "live",
      reconcile: false,
      run_id: "run-same",
      events: [ev()],
      mapped: [{ event_key: "r:42", google_calendar_id: CAL, google_event_id: "bkr00000042", content_hash: "abc" }],
    }),
    finish: async (p) => { box.payload = p; },
  };
  const out = await runExport(db, google);
  assertEquals(out.patched, 0);
  assertEquals(out.unchanged, 1);
  assertEquals(out.failed, 0);
  assertEquals(box.payload?.reconcile, false);
  assertEquals((box.payload?.upserts as unknown[]).length, 0);
});

Deno.test("täysi kirjoitus päivittää saman tarkisteen ja palauttaa poistetun tapahtuman", async () => {
  const calls: string[] = [];
  const google: Google = {
    async insertEvent() { calls.push("insert"); return "created"; },
    async patchEvent() { calls.push("patch"); return "missing"; },
    async deleteEvent() { calls.push("delete"); return "deleted"; },
  };
  const box: { payload: Record<string, unknown> | null } = { payload: null };
  const db: Db = {
    plan: async () => ({
      mode: "live",
      reconcile: true,
      run_id: "run-full",
      events: [ev()],
      mapped: [{ event_key: "r:42", google_calendar_id: CAL, google_event_id: "bkr00000042", content_hash: "abc" }],
    }),
    finish: async (p) => { box.payload = p; },
  };
  const out = await runExport(db, google);
  assertEquals(calls, ["patch", "insert"]);
  assertEquals(out.patched, 1);
  assertEquals(out.unchanged, 0);
  assertEquals(box.payload?.reconcile, true);
  assertEquals((box.payload?.upserts as { event_key: string }[])[0].event_key, "r:42");
});

Deno.test("epäonnistunut täysi kirjoitus ei leimaa onnistumista", async () => {
  const { HttpError } = await import("../booking-calendar-sync/core.ts");
  const google: Google = {
    async insertEvent() { return "created"; },
    async patchEvent() { throw new HttpError(403, "forbidden"); },
    async deleteEvent() { return "deleted"; },
  };
  const box: { payload: Record<string, unknown> | null } = { payload: null };
  const db: Db = {
    plan: async () => ({
      mode: "live",
      reconcile: true,
      run_id: "run-fail",
      events: [ev()],
      mapped: [{ event_key: "r:42", google_calendar_id: CAL, google_event_id: "bkr00000042", content_hash: "abc" }],
    }),
    finish: async (p) => { box.payload = p; },
  };
  const out = await runExport(db, google);
  assertEquals(out.ok, false);
  assertEquals(box.payload?.reconcile, false);
  assert(String(box.payload?.error).includes("google_http_403"));
});

Deno.test("live 403 kirjataan ja finish saa virhekoodin", async () => {
  const { HttpError } = await import("../booking-calendar-sync/core.ts");
  const google: Google = {
    async insertEvent() { throw new HttpError(403, "forbidden"); },
    async patchEvent() { return "patched"; },
    async deleteEvent() { return "deleted"; },
  };
  const box: { payload: Record<string, unknown> | null } = { payload: null };
  const db: Db = {
    plan: async () => ({ mode: "live", run_id: "run-2", events: [ev()], mapped: [] }),
    finish: async (p) => { box.payload = p; },
  };
  const out = await runExport(db, google);
  assertEquals(out.ok, false);
  assertEquals(out.failed, 1);
  assertEquals(out.inserted, 0);
  assert(String(box.payload?.error).includes("google_http_403"));
});

Deno.test("createGoogle: 409 -> exists, 401 uusii tokenin, 404-poisto on gone, 403 heittää", async () => {
  let tokens = 0;
  let posts = 0;
  const seen: { method: string; url: string; body?: string }[] = [];
  const fetchImpl: typeof fetch = async (input, init) => {
    const url = String(input);
    seen.push({ method: init?.method ?? "GET", url, body: init?.body == null ? undefined : String(init.body) });
    if (init?.method === "POST") {
      posts++;
      if (posts === 1) return new Response("{}", { status: 401 });
      return new Response(JSON.stringify({ error: { errors: [{ reason: "duplicate" }] } }), { status: 409 });
    }
    if (init?.method === "DELETE" && url.includes("missing")) return new Response("{}", { status: 404 });
    if (init?.method === "DELETE") return new Response(JSON.stringify({ error: { errors: [{ reason: "forbidden" }] } }), { status: 403 });
    return new Response("{}", { status: 500 });
  };
  const google = createGoogle(fetchImpl, { token: async () => { tokens++; return "tok"; }, invalidate: () => {} });
  assertEquals(await google.insertEvent(CAL, toGoogleEvent(ev())), "exists");
  assertEquals(tokens, 2);
  assert(!seen.some((s) => (s.body ?? "").includes("040")));
  assertEquals(await google.deleteEvent(CAL, "missingev"), "gone");
  let status = 0;
  try { await google.deleteEvent(CAL, "bkr00000099"); } catch (err) { status = (err as { status?: number }).status ?? 0; }
  assertEquals(status, 403);
});
