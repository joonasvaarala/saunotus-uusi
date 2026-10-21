// calendar-sync-v2 ilman Googlea ja ilman Supabasea.
// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/calendar-sync-v2/core_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  buildIncremental,
  createGoogle,
  DB_EVENT_DESCRIPTION,
  eventUrl,
  patchBody,
  runPush,
  slim,
  writeSkipReason,
  writesAllowed,
  type GEvent,
  type OutboxItem,
  type PushDb,
} from "./core.ts";

const CAL = "shift-test@group.calendar.google.com";
const INSTANCE = "spsabc_20261022T050000Z";
const noop = async () => {};

function item(over: Partial<OutboxItem> = {}): OutboxItem {
  return {
    id: 11,
    op: "patch",
    shift_id: "11111111-1111-1111-1111-111111111111",
    version: 4,
    google_calendar_id: CAL,
    calendar_name: "Vastaanotto",
    event_id: INSTANCE,
    etag: '"etag-1"',
    timezone: "Europe/Helsinki",
    summary: "Maija & Matti",
    starts_at: "2026-10-22T05:00:00+00:00",
    ends_at: "2026-10-22T08:00:00+00:00",
    title_changed: false,
    time_changed: false,
    reactivate: false,
    recurring: true,
    attempt: 1,
    ...over,
  };
}

interface Seen {
  method: string;
  url: string;
  body?: Record<string, unknown>;
  ifMatch: string | null;
}

function scriptedFetch(steps: Array<(seen: Seen) => Response>): { fetchImpl: typeof fetch; seen: Seen[] } {
  const seen: Seen[] = [];
  let i = 0;
  const fetchImpl: typeof fetch = async (input, init) => {
    const headers = new Headers(init?.headers);
    const entry: Seen = {
      method: init?.method ?? "GET",
      url: String(input),
      body: init?.body == null ? undefined : JSON.parse(String(init.body)),
      ifMatch: headers.get("If-Match"),
    };
    seen.push(entry);
    if (!entry.url.startsWith("https://www.googleapis.com/") || entry.url.includes("test-token")) {
      throw new Error("unexpected_url");
    }
    if (i >= steps.length) throw new Error(`unexpected_fetch_${i + 1}`);
    return steps[i++](entry);
  };
  return { fetchImpl, seen };
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function recordingDb(items: OutboxItem[], cfg: { db_first_enabled?: boolean; push_enabled?: boolean } | null) {
  const claims: boolean[] = [];
  const completes: Array<{ id: number; result: string; updated: string | null; etag: string | null }> = [];
  const fails: Array<{ id: number; error: string; blocked: boolean; conflict: boolean; missing: boolean }> = [];
  const db: PushDb = {
    config: async () => cfg,
    claim: async (_sourceId, dryRun) => {
      claims.push(dryRun);
      return items;
    },
    complete: async (id, result, updated, etag) => {
      completes.push({ id, result, updated, etag });
    },
    fail: async (id, error, blocked = false, conflict = false, missing = false) => {
      fails.push({ id, error, blocked, conflict, missing });
    },
  };
  return { db, claims, completes, fails };
}

async function pushWith(
  fetchImpl: typeof fetch,
  db: PushDb,
  over: { dryRun?: boolean; pushRequested?: boolean; killSwitch?: boolean } = {},
) {
  const google = createGoogle(fetchImpl, { token: async () => "test-token" }, noop);
  return await runPush({
    sourceId: "22222222-2222-2222-2222-222222222222",
    dryRun: over.dryRun === true,
    pushRequested: over.pushRequested !== false,
    killSwitch: over.killSwitch === true,
    db,
    google,
  });
}

const enabled = { db_first_enabled: true, push_enabled: true };

Deno.test("slim säilyttää etagin ja vain sipoo-avaimet", () => {
  const raw = {
    id: "e1",
    status: "confirmed",
    summary: "A & B",
    updated: "2026-10-22T00:00:00Z",
    etag: '"abc"',
    start: { dateTime: "2026-10-22T05:00:00Z" },
    end: { dateTime: "2026-10-22T08:00:00Z" },
    recurringEventId: "master",
    htmlLink: "https://calendar.example/secret",
    extendedProperties: {
      private: { sipoo_src: "db", sipoo_shift_id: "sid", sipoo_shift_ver: "3", other: "no" },
      shared: { x: "y" },
    },
  } as GEvent & { htmlLink?: string; extendedProperties: { private: Record<string, string>; shared?: Record<string, string> } };
  const out = slim(raw);
  assertEquals(out.etag, '"abc"');
  assertEquals(out.extendedProperties?.private, { sipoo_src: "db", sipoo_shift_id: "sid", sipoo_shift_ver: "3" });
  assertEquals("htmlLink" in out, false);
  assertEquals("shared" in (out.extendedProperties ?? {}), false);
  assertEquals(slim({ id: "e2", extendedProperties: { private: { noise: "x" } } }).extendedProperties, undefined);
});

Deno.test("inkrementaalinen instanssi kulkee slimin läpi", async () => {
  const calls: string[] = [];
  const listAll = async (path: string) => {
    calls.push(path);
    return {
      items: [{
        id: INSTANCE,
        recurringEventId: "spsabc",
        summary: "Maija",
        etag: '"etag1"',
        updated: "2026-10-22T00:00:00Z",
        start: { dateTime: "2026-10-22T05:00:00Z" },
        end: { dateTime: "2026-10-22T08:00:00Z" },
        extendedProperties: { private: { sipoo_src: "db", sipoo_shift_id: "sid", noise: "x" } },
      }],
      nextSyncToken: "next-token",
    };
  };
  const built = await buildIncremental(CAL, "sync-token", listAll);
  assertEquals(built.events.length, 1);
  assertEquals(built.events[0].etag, '"etag1"');
  assertEquals(built.events[0].extendedProperties?.private, { sipoo_src: "db", sipoo_shift_id: "sid" });
  assertEquals(built.events[0].recurrence, undefined);
  assertEquals(built.newToken, "next-token");
  assert(calls[0].includes(encodeURIComponent(CAL)));
});

Deno.test("insert 409 johtaa patchiin ja kuittaukseen", async () => {
  const { fetchImpl, seen } = scriptedFetch([
    () => jsonResponse(409, { error: { errors: [{ reason: "duplicate" }] } }),
    () => jsonResponse(200, { updated: "2026-10-22T01:00:00.000Z", etag: '"e2"' }),
  ]);
  const rec = recordingDb([item({ op: "insert", etag: null, recurring: false, event_id: "spsabc" })], enabled);
  const out = await pushWith(fetchImpl, rec.db);
  assertEquals(seen.map((s) => s.method), ["POST", "PATCH"]);
  assertEquals(seen[0].url, eventUrl(CAL).toString());
  assertEquals(seen[0].body?.id, "spsabc");
  assertEquals(seen[0].body?.description, DB_EVENT_DESCRIPTION);
  assertEquals((seen[0].body?.extendedProperties as { private: Record<string, string> }).private, {
    sipoo_src: "db",
    sipoo_shift_id: "11111111-1111-1111-1111-111111111111",
    sipoo_shift_ver: "4",
  });
  assertEquals(seen[1].body && "id" in seen[1].body, false);
  assertEquals(seen[1].url, eventUrl(CAL, "spsabc").toString());
  assertEquals(out.created, 0);
  assertEquals(out.patched, 1);
  assertEquals(rec.completes, [{ id: 11, result: "patched", updated: "2026-10-22T01:00:00.000Z", etag: '"e2"' }]);
  assertEquals(rec.fails, []);
});

Deno.test("patch lähettää If-Matchin kun etag on asetettu", async () => {
  const { fetchImpl, seen } = scriptedFetch([
    () => jsonResponse(200, { updated: "2026-10-22T02:00:00.000Z", etag: '"next"' }),
  ]);
  const rec = recordingDb([item({ title_changed: true })], enabled);
  await pushWith(fetchImpl, rec.db);
  assertEquals(seen.length, 1);
  assertEquals(seen[0].method, "PATCH");
  assertEquals(seen[0].ifMatch, '"etag-1"');
  assertEquals(rec.completes[0].result, "patched");
  assertEquals(rec.completes[0].etag, '"next"');
});

Deno.test("patch ilman etagia ei lähetä If-Matchia", async () => {
  const { fetchImpl, seen } = scriptedFetch([
    () => jsonResponse(200, { updated: "2026-10-22T02:00:00.000Z", etag: '"next"' }),
  ]);
  const rec = recordingDb([item({ etag: null, title_changed: true })], enabled);
  await pushWith(fetchImpl, rec.db);
  assertEquals(seen[0].ifMatch, null);
});

Deno.test("412 on conflict eikä uutta yritystä samassa pyynnössä", async () => {
  const { fetchImpl, seen } = scriptedFetch([
    () => jsonResponse(412, { error: { errors: [{ reason: "conditionNotMet" }] } }),
  ]);
  const rec = recordingDb([item()], enabled);
  const out = await pushWith(fetchImpl, rec.db);
  assertEquals(seen.length, 1);
  assertEquals(out.conflicts, 1);
  assertEquals(rec.fails, [{ id: 11, error: "google_http_412", blocked: false, conflict: true, missing: false }]);
  assertEquals(rec.completes, []);
});

Deno.test("404 patch on missing", async () => {
  const { fetchImpl, seen } = scriptedFetch([
    () => jsonResponse(404, { error: { errors: [{ reason: "notFound" }] } }),
  ]);
  const rec = recordingDb([item()], enabled);
  const out = await pushWith(fetchImpl, rec.db);
  assertEquals(seen.length, 1);
  assertEquals(out.missing, 1);
  assertEquals(rec.fails[0].blocked, false);
  assertEquals(rec.fails[0].conflict, false);
  assertEquals(rec.fails[0].missing, true);
  assert(rec.fails[0].error.startsWith("google_http_404"));
});

Deno.test("403 ilman rate limitia on blocked eikä sitä uusita", async () => {
  const { fetchImpl, seen } = scriptedFetch([
    () => jsonResponse(403, { error: { errors: [{ reason: "forbidden" }] } }),
  ]);
  const rec = recordingDb([item({ op: "insert", etag: null })], enabled);
  const out = await pushWith(fetchImpl, rec.db);
  assertEquals(seen.length, 1);
  assertEquals(out.blocked, 1);
  assertEquals(rec.fails, [{ id: 11, error: "no_write_access", blocked: true, conflict: false, missing: false }]);
});

Deno.test("403 rate limit uusitaan eikä ole heti blocked", async () => {
  let n = 0;
  const { fetchImpl, seen } = scriptedFetch([
    () => jsonResponse(403, { error: { errors: [{ reason: "rateLimitExceeded" }] } }),
    () => jsonResponse(403, { error: { errors: [{ reason: "userRateLimitExceeded" }] } }),
    () => jsonResponse(200, { updated: "2026-10-22T03:00:00.000Z", etag: '"ok"' }),
  ]);
  const wrapped: typeof fetch = async (input, init) => {
    n++;
    return await fetchImpl(input, init);
  };
  const rec = recordingDb([item()], enabled);
  const out = await pushWith(wrapped, rec.db);
  assertEquals(n, 3);
  assertEquals(seen.length, 3);
  assertEquals(out.patched, 1);
  assertEquals(rec.fails, []);
});

Deno.test("delete 404 ja 410 ovat gone ja If-Match lähtee etagin kanssa", async () => {
  for (const status of [404, 410]) {
    const { fetchImpl, seen } = scriptedFetch([() => new Response("", { status })]);
    const rec = recordingDb([item({ op: "delete" })], enabled);
    const out = await pushWith(fetchImpl, rec.db);
    assertEquals(seen[0].method, "DELETE");
    assertEquals(seen[0].ifMatch, '"etag-1"');
    assertEquals(seen[0].url, eventUrl(CAL, INSTANCE).toString());
    assertEquals(out.gone, 1);
    assertEquals(rec.completes[0].result, "gone");
    assertEquals(rec.fails, []);
  }
});

Deno.test("dryRun ei tee kirjoituskutsuja ja palauttaa suunnitelman", async () => {
  const fetchImpl: typeof fetch = async () => {
    throw new Error("google_write_called");
  };
  const row = item({ op: "insert", title_changed: true, time_changed: true, reactivate: false });
  const rec = recordingDb([row], enabled);
  const out = await pushWith(fetchImpl, rec.db, { dryRun: true });
  assertEquals(out.writes, false);
  assertEquals(out.writeSkip, "dry_run");
  assertEquals(rec.claims, [true]);
  assertEquals(rec.completes, []);
  assertEquals(rec.fails, []);
  assertEquals(out.plan, [{
    op: "insert",
    summary: "Maija & Matti",
    title_changed: true,
    time_changed: true,
    reactivate: false,
  }]);
  const plan = out.plan?.[0] as unknown as Record<string, unknown>;
  assertEquals("google_calendar_id" in plan, false);
  assertEquals("event_id" in plan, false);
  assertEquals("etag" in plan, false);
});

Deno.test("push_enabled false ei tee kirjoituskutsuja", async () => {
  const fetchImpl: typeof fetch = async () => {
    throw new Error("google_write_called");
  };
  const rec = recordingDb([item({ op: "delete" })], { db_first_enabled: true, push_enabled: false });
  const out = await pushWith(fetchImpl, rec.db);
  assertEquals(out.writes, false);
  assertEquals(out.writeSkip, "push_disabled");
  assertEquals(rec.claims, [true]);
  assertEquals(out.deleted, 0);
  assertEquals(out.plan, undefined);
});

Deno.test("kirjoitusportti: dryRun, push false, kill switch ja db_first", () => {
  const open = { dryRun: false, pushRequested: true, killSwitch: false, dbFirstEnabled: true, pushEnabled: true };
  assertEquals(writesAllowed(open), true);
  assertEquals(writeSkipReason({ ...open, dryRun: true }), "dry_run");
  assertEquals(writeSkipReason({ ...open, pushRequested: false }), "push_not_requested");
  assertEquals(writeSkipReason({ ...open, killSwitch: true }), "kill_switch");
  assertEquals(writeSkipReason({ ...open, dbFirstEnabled: false }), "db_first_off");
  assertEquals(writeSkipReason({ ...open, pushEnabled: false }), "push_disabled");
  assertEquals(writesAllowed({ ...open, pushEnabled: false }), false);
});

Deno.test("patch lähettää vain muuttuneet kentät", () => {
  const timeOnly = patchBody(item({ title_changed: false, time_changed: true, reactivate: false }));
  assertEquals(Object.keys(timeOnly).sort(), ["end", "extendedProperties", "start"]);
  assertEquals("summary" in timeOnly, false);
  assertEquals("status" in timeOnly, false);
  assertEquals((timeOnly.start as { timeZone: string }).timeZone, "Europe/Helsinki");

  const titleAndRevive = patchBody(item({ title_changed: true, time_changed: false, reactivate: true }));
  assertEquals(Object.keys(titleAndRevive).sort(), ["extendedProperties", "status", "summary"]);
  assertEquals(titleAndRevive.status, "confirmed");
  assertEquals("start" in titleAndRevive, false);

  const propsOnly = patchBody(item());
  assertEquals(Object.keys(propsOnly), ["extendedProperties"]);
});

Deno.test("instanssi-id menee URLiin encodeURIComponentilla muuttumattomana", () => {
  const url = eventUrl(CAL, INSTANCE);
  assertEquals(url.toString(), `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(CAL)}/events/${encodeURIComponent(INSTANCE)}`);
  assert(url.pathname.endsWith(`/events/${INSTANCE}`));
  const spaced = "series id_20261022T080000Z";
  const encoded = eventUrl(CAL, spaced);
  const segment = encoded.pathname.split("/events/")[1];
  assertEquals(segment, encodeURIComponent(spaced));
  assert(!segment.includes("/"));
  assert(!encoded.pathname.includes(spaced));
});

Deno.test("patchin URL käyttää instanssi-idiä eikä sarjan masteria", async () => {
  const { fetchImpl, seen } = scriptedFetch([
    () => jsonResponse(200, { updated: "2026-10-22T04:00:00.000Z", etag: '"i"' }),
  ]);
  const rec = recordingDb([item({ event_id: INSTANCE, recurring: true, time_changed: true })], enabled);
  await pushWith(fetchImpl, rec.db);
  assertEquals(seen[0].url, eventUrl(CAL, INSTANCE).toString());
  assert(!seen[0].url.includes("/spsabc/"));
  assertEquals(Object.keys(seen[0].body ?? {}).sort(), ["end", "extendedProperties", "start"]);
});
