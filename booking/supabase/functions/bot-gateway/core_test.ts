// bot-gateway ilman Supabasea: mock-rpc, ei oikeaa avainta, ei verkkoa.
// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/bot-gateway/core_test.ts
import { assert, assertEquals, assertMatch } from "jsr:@std/assert@1";
import {
  ACTIONS,
  createHandler,
  EDGE_LIMIT_PER_IP,
  EDGE_LIMIT_PER_KEY,
  MAX_BODY_BYTES,
  RateLimiter,
  type RpcError,
  type RpcName,
  type RpcResult,
  sha256Hex,
  validateArgs,
} from "./core.ts";

// Testiavain (ei oikea): 32 tavua hexinä.
const KEY = "test-key-0123456789abcdef0123456789abcdef0123456789abcdef";
const SENSITIVE = ["+358401234567", "Salainen Henkilö", "terveystieto-xyz", "secret.person@example.com", "ARGVALUE-123"];
const U1 = "11111111-1111-4111-8111-111111111111";
const U2 = "22222222-2222-4222-8222-222222222222";
const RID = "33333333-3333-4333-8333-333333333333";

interface Call {
  fn: RpcName;
  args: Record<string, unknown>;
}

function mockRpc(opts: { error?: RpcError; data?: unknown; throws?: boolean; logFails?: boolean } = {}) {
  const calls: Call[] = [];
  const rpc = (fn: RpcName, args: Record<string, unknown>): Promise<RpcResult> => {
    assert(fn === "botgw_call" || fn === "botgw_log_failure", `vain sallitut RPC:t, saatiin ${fn}`);
    calls.push({ fn, args });
    if (fn === "botgw_log_failure") {
      if (opts.logFails) return Promise.reject(new Error("network down"));
      return Promise.resolve({ data: null, error: null });
    }
    if (opts.throws) return Promise.reject(new Error("fetch failed ARGVALUE-123"));
    if (opts.error) return Promise.resolve({ data: null, error: opts.error });
    const p = args.p_args as Record<string, unknown>;
    return Promise.resolve({
      data: opts.data ?? { ok: true, data: { echo: args.p_action }, ...(p?.request_id ? { request_id: p.request_id } : {}) },
      error: null,
    });
  };
  return { rpc, calls };
}

// Kaappaa kaikki konsolitulosteet testin ajaksi.
async function captured<T>(fn: () => Promise<T>): Promise<{ out: string; value: T }> {
  const lines: string[] = [];
  const c = console as unknown as Record<string, (...a: unknown[]) => void>;
  const names = ["log", "info", "warn", "error", "debug"];
  const orig = names.map((n) => c[n]);
  names.forEach((n) => (c[n] = (...a: unknown[]) => lines.push(a.map((x) => typeof x === "string" ? x : JSON.stringify(x)).join(" "))));
  try {
    const value = await fn();
    return { out: lines.join("\n"), value };
  } finally {
    names.forEach((n, i) => (c[n] = orig[i]));
  }
}

async function assertNoSecrets(out: string) {
  const hash = await sha256Hex(KEY);
  assert(!out.includes(KEY), "avain lokissa");
  assert(!out.includes(hash), "tiiviste lokissa");
  assert(!out.toLowerCase().includes("x-bot-key"), "otsikko lokissa");
  for (const s of SENSITIVE) assert(!out.includes(s), `args-sisältö lokissa: ${s}`);
}

function req(body: unknown, opts: { key?: string | null; method?: string; ip?: string; headers?: Record<string, string> } = {}) {
  const h: Record<string, string> = { "content-type": "application/json", "x-forwarded-for": opts.ip ?? "203.0.113.7", ...opts.headers };
  if (opts.key !== null) h["x-bot-key"] = opts.key ?? KEY;
  const method = opts.method ?? "POST";
  return new Request("https://example.test/functions/v1/bot-gateway", {
    method,
    headers: h,
    body: method === "GET" || method === "HEAD" ? undefined : typeof body === "string" ? body : JSON.stringify(body),
  });
}

async function run(r: Request, rpcOpts: Parameters<typeof mockRpc>[0] = {}, disabled = false) {
  const m = mockRpc(rpcOpts);
  const h = createHandler({ rpc: m.rpc, disabled: () => disabled, limiter: new RateLimiter() });
  const { out, value: res } = await captured(() => h(r));
  const body = await res.json();
  await assertNoSecrets(out);
  return { res, body, calls: m.calls, out };
}

// ---------- perusasiat ----------
Deno.test("sha256Hex: tunnettu testivektori", async () => {
  assertEquals(await sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
});

Deno.test("BOTGW_DISABLED: 503 eikä tietokantakutsua", async () => {
  const { res, body, calls } = await run(req({ action: "me", args: {} }), {}, true);
  assertEquals(res.status, 503);
  assertEquals(body, { ok: false, error: "disabled" });
  assertEquals(calls.length, 0);
});

Deno.test("vain POST: GET/OPTIONS/PUT -> 405, Allow: POST, ei CORS-otsikoita", async () => {
  for (const method of ["GET", "OPTIONS", "PUT", "DELETE"]) {
    const { res, calls } = await run(req({ action: "me" }, { method }));
    assertEquals(res.status, 405, method);
    assertEquals(res.headers.get("allow"), "POST");
    assertEquals(res.headers.get("access-control-allow-origin"), null);
    assertEquals(calls.length, 0);
  }
});

Deno.test("auth: puuttuva, tyhjä tai liian lyhyt avain -> 401 ilman tietokantaa", async () => {
  for (const key of [null, "", "short"]) {
    const { res, body, calls } = await run(req({ action: "me" }, { key }));
    assertEquals(res.status, 401);
    assertEquals(body, { ok: false, error: "unauthorized" });
    assertEquals(calls.length, 0);
  }
});

Deno.test("auth: tuntematon avain -> tietokanta 42501 unauthorized -> 401 + botgw_log_failure", async () => {
  const { res, body, calls } = await run(req({ action: "me" }, { key: "wrong-key-wrong-key-wrong-key-0000" }), {
    error: { code: "42501", message: "unauthorized" },
  });
  assertEquals(res.status, 401);
  assertEquals(body, { ok: false, error: "unauthorized" });
  assertEquals(calls.map((c) => c.fn), ["botgw_call", "botgw_log_failure"]);
  assertEquals(calls[0].args.p_key_hash, await sha256Hex("wrong-key-wrong-key-wrong-key-0000"));
  assertEquals(calls[1].args, {
    p_key_hash: await sha256Hex("wrong-key-wrong-key-wrong-key-0000"),
    p_action: "me",
    p_error: "42501:unauthorized",
  });
});

Deno.test("rpc saa tiivisteen (64 hex), ei avainta", async () => {
  const { calls } = await run(req({ action: "me", args: {} }));
  assertEquals(calls.length, 1);
  assertEquals(calls[0].fn, "botgw_call");
  assertEquals(Object.keys(calls[0].args).sort(), ["p_action", "p_args", "p_key_hash"]);
  assertMatch(calls[0].args.p_key_hash as string, /^[0-9a-f]{64}$/);
  assertEquals(calls[0].args.p_key_hash, await sha256Hex(KEY));
  assert(!JSON.stringify(calls[0].args).includes(KEY));
});

// ---------- koko ----------
Deno.test("koko: content-length > 16 kB -> 413 ilman tietokantaa", async () => {
  const big = JSON.stringify({ action: "proposal_add", args: { title: "t", body: "x".repeat(MAX_BODY_BYTES) } });
  const { res, body, calls } = await run(req(big, { headers: { "content-length": String(big.length) } }));
  assertEquals(res.status, 413);
  assertEquals(body.error, "payload_too_large");
  assertEquals(calls.length, 0);
});

Deno.test("koko: virtaava runko > 16 kB ilman content-lengthiä -> 413 + log_failure", async () => {
  const enc = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    start(c) {
      for (let i = 0; i < 20; i++) c.enqueue(enc.encode("x".repeat(1024)));
      c.close();
    },
  });
  const r = new Request("https://example.test/", { method: "POST", headers: { "x-bot-key": KEY }, body: stream });
  assertEquals(r.headers.get("content-length"), null);
  const { res, calls } = await run(r);
  assertEquals(res.status, 413);
  assertEquals(calls.map((c) => c.fn), ["botgw_log_failure"]);
  assertEquals(calls[0].args.p_error, "edge:too_large");
});

Deno.test("koko: tasan 16 kB menee läpi", async () => {
  const mk = (n: number) => JSON.stringify({ action: "proposal_add", args: { title: "t", body: "y", proposed_change: { p: "z".repeat(n) } } });
  const n = MAX_BODY_BYTES - mk(0).length;
  const s = mk(n);
  assertEquals(new TextEncoder().encode(s).length, MAX_BODY_BYTES);
  const { res, calls } = await run(req(s));
  assertEquals(res.status, 200);
  assertEquals(calls[0].fn, "botgw_call");
  const { res: r2 } = await run(req(mk(n + 1)));
  assertEquals(r2.status, 413);
});

// ---------- runko ja validointi ----------
Deno.test("runko: rikki JSON, ei-objekti, väärä action, args ei objekti -> 400 + log_failure", async () => {
  const cases: [unknown, string][] = [
    ["{not json", "bad_json"],
    [[1, 2], "bad_request"],
    [{ action: 5 }, "bad_action"],
    [{ action: "x".repeat(51) }, "bad_action"],
    [{ action: "Me; drop" }, "bad_action"],
    [{ action: "me", args: [1] }, "args_must_be_object"],
    [{ action: "me", args: "ARGVALUE-123" }, "args_must_be_object"],
    [{ action: "me", args: {}, extra: 1 }, "bad_request"],
    [{ action: "no_such_action", args: {} }, "unknown_action"],
  ];
  for (const [b, err] of cases) {
    const { res, body, calls } = await run(req(b));
    assertEquals(res.status, 400, JSON.stringify(b));
    assertEquals(body, { ok: false, error: err });
    assertEquals(calls.map((c) => c.fn), ["botgw_log_failure"], err);
    assert(!String(calls[0].args.p_action).includes("drop"));
  }
});

Deno.test("validointi: toimintokohtaiset säännöt (§2) ennen tietokantaa", () => {
  const bad: [string, Record<string, unknown>, string][] = [
    ["shift_change", { action: "create", shift_id: U1, role: "heater", starts: "2026-11-01T10:00", ends: "2026-11-01T12:00" }, "create ei ota shift_id:tä"],
    ["shift_change", { action: "create", starts: "2026-11-01T10:00", ends: "2026-11-01T12:00" }, "create vaatii roolin, alun ja lopun"],
    ["shift_change", { action: "assign", shift_id: U1 }, "assign vaatii staff_id:n"],
    ["shift_change", { action: "unassign", shift_id: U1 }, "unassign vaatii staff_id:n"],
    ["shift_change", { action: "cancel", shift_id: U1, staff_id: U2 }, "cancel ei ota staff_id:tä"],
    ["shift_change", { action: "change_time", shift_id: U1, staff_id: U2, starts: "2026-11-01T10:00", ends: "2026-11-01T11:00" }, "change_time ei ota staff_id:tä"],
    ["shift_change", { action: "change_time", shift_id: U1 }, "change_time vaatii alun ja lopun"],
    ["shift_change", { action: "delete", shift_id: U1 }, "bad_arg:action"],
    ["shift_change", { action: "cancel" }, "cancel vaatii shift_id:n"],
    ["shift_change", { action: "assign", shift_id: U1, staff_id: U2, role: "boss" }, "bad_arg:role"],
    ["shift_change", { action: "cancel", shift_id: U1, note: "n".repeat(501) }, "too_long:note"],
    ["shift_change", { action: "cancel", shift_id: "not-a-uuid" }, "bad_arg:shift_id"],
    ["shift_change", { action: "change_time", shift_id: U1, starts: "huomenna", ends: "2026-11-01T11:00" }, "bad_arg:starts"],
    ["shift_reassign", { shift_id: U1, from_staff_id: U2, to_staff_id: U2 }, "Sama henkilö"],
    ["shift_reassign", { shift_id: U1, from_staff_id: U2 }, "missing_arg:to_staff_id"],
    ["shifts_list", { from: "25.10.2026" }, "bad_arg:from"],
    ["shift_history", {}, "missing_arg:shift_id"],
    ["staff_create", { name: "A" }, "missing_arg:calendar_name"],
    ["staff_create", { name: "n".repeat(101), calendar_name: "A" }, "too_long:name"],
    ["staff_create", { name: "A", calendar_name: "Matti & Maija" }, "bad_arg:calendar_name"],
    ["staff_create", { name: "A", calendar_name: "Matti-M" }, "bad_arg:calendar_name"],
    ["staff_create", { name: "A", calendar_name: "c".repeat(51) }, "too_long:calendar_name"],
    ["staff_create", { name: "A", calendar_name: "A", email: "no-at" }, "bad_arg:email"],
    ["staff_create", { name: "A", calendar_name: "A", roles: ["heater", "pilot"] }, "bad_arg:roles"],
    ["staff_update", { staff_id: U1, notes: "x".repeat(1001) }, "too_long:notes"],
    ["staff_update", { staff_id: U1, active: "false" }, "bad_arg:active"],
    ["staff_update", { staff_id: U1, ssn: "x" }, "unknown_arg:ssn"],
    ["staff_role_set", { staff_id: U1, role: "heater" }, "missing_arg:active"],
    ["unavailability_add", { staff_id: U1, starts: "2026-11-01T10:00" }, "missing_arg:ends"],
    ["unavailability_update", { starts: "2026-11-01T10:00", ends: "2026-11-01T11:00" }, "missing_arg:id"],
    ["unavailability_delete", { id: 5 }, "bad_arg:id"],
    ["proposal_add", { title: "t".repeat(201), body: "b" }, "too_long:title"],
    ["proposal_add", { title: "t", body: "b".repeat(4001) }, "too_long:body"],
    ["proposal_add", { title: "t", body: "b", area: "pricing" }, "bad_arg:area"],
    ["proposal_add", { title: "t", body: "b", proposed_change: [1] }, "bad_arg:proposed_change"],
    ["proposal_add", { title: " ", body: "b" }, "missing_arg:title"],
    ["offer_respond", { offer_id: U1, response: "maybe" }, "bad_arg:response"],
    ["backlog_update", { item_id: 1, task_id: 2 }, "task_id ja task_done annetaan yhdessä"],
    ["backlog_update", { item_id: 1, status: "approved" }, "bad_arg:status"],
    ["backlog_add", { title: "t" }, "missing_arg:category"],
    ["inbox_ack", { ids: ["1"] }, "bad_arg:ids"],
    ["me", { request_id: "nope" }, "bad_arg:request_id"],
  ];
  for (const [action, args, err] of bad) assertEquals(validateArgs(action, args), err, `${action} ${JSON.stringify(args)}`);
  // ilman aikavyöhykettä ja vyöhykkeen kanssa kelpaa (tietokanta tulkitsee Europe/Helsinki)
  assertEquals(validateArgs("unavailability_add", { staff_id: U1, starts: "2026-11-01 10:00", ends: "2026-11-01T12:00:00+02:00" }), null);
  assertEquals(validateArgs("unavailability_add", { staff_id: U1, starts: "2026-11-01T08:00:00Z", ends: "2026-11-01T12:00" }), null);
  assertEquals(validateArgs("staff_update", { staff_id: U1, phone: null, email: "", notes: null }), null);
});

Deno.test("validointivirhe: 400, log_failure lyhyellä koodilla, ei arvoja lokiin", async () => {
  const { res, body, calls, out } = await run(req({ action: "staff_update", args: { staff_id: U1, name: "Salainen Henkilö".repeat(10) } }));
  assertEquals(res.status, 400);
  assertEquals(body.error, "too_long:name");
  assertEquals(calls.map((c) => c.fn), ["botgw_log_failure"]);
  assertEquals(calls[0].args.p_error, "edge:validation");
  assertMatch(out, /"action":"staff_update"/);
});

// ---------- virhekoodien mappaus ----------
const MAPPINGS: { name: string; error: RpcError; status: number; body: string; logCode: string; retryAfter?: string }[] = [
  { name: "42501 unauthorized", error: { code: "42501", message: "unauthorized" }, status: 401, body: "unauthorized", logCode: "42501:unauthorized" },
  { name: "42501 forbidden", error: { code: "42501", message: "forbidden:staff.manage" }, status: 403, body: "forbidden:staff.manage", logCode: "42501:forbidden" },
  { name: "42501 not_editable", error: { code: "42501", message: "not_editable" }, status: 403, body: "not_editable", logCode: "42501:not_editable" },
  { name: "42501 field_not_editable", error: { code: "42501", message: "field_not_editable" }, status: 403, body: "field_not_editable", logCode: "42501:field_not_editable" },
  {
    name: "42501 calendar_managed",
    error: { code: "42501", message: "calendar_managed: tämä este tulee kalenterista, muuta se kalenterissa" },
    status: 403,
    body: "calendar_managed: tämä este tulee kalenterista, muuta se kalenterissa",
    logCode: "42501:calendar_managed",
  },
  { name: "42501 muu viesti -> 401", error: { code: "42501", message: "permission denied for function botgw_call" }, status: 401, body: "unauthorized", logCode: "42501:unauthorized" },
  { name: "22023 viesti sellaisenaan", error: { code: "22023", message: "Vuoro voi olla enintään 24 h" }, status: 400, body: "Vuoro voi olla enintään 24 h", logCode: "22023" },
  { name: "22023 bad_time (toistaa syötteen; ei lokiin)", error: { code: "22023", message: "bad_time:ARGVALUE-123" }, status: 400, body: "bad_time:ARGVALUE-123", logCode: "22023" },
  { name: "22P02", error: { code: "22P02", message: 'invalid input syntax for type uuid: "ARGVALUE-123"' }, status: 400, body: "bad_input", logCode: "22P02" },
  { name: "23505", error: { code: "23505", message: "duplicate key value violates unique constraint (ARGVALUE-123)" }, status: 400, body: "already_exists", logCode: "23505" },
  { name: "P0002", error: { code: "P0002", message: "Vuoroa ei löytynyt" }, status: 404, body: "Vuoroa ei löytynyt", logCode: "P0002" },
  { name: "BG429", error: { code: "BG429", message: "rate_limited" }, status: 429, body: "rate_limited", logCode: "BG429", retryAfter: "60" },
  { name: "55000", error: { code: "55000", message: "DB-first-vuorosynkka ei ole käytössä (shift_sync_settings.db_first_enabled)" }, status: 503, body: "shift_sync_disabled", logCode: "55000" },
  { name: "XX000 -> 500 yleinen", error: { code: "XX000", message: "internal detail ARGVALUE-123" }, status: 500, body: "internal_error", logCode: "db:XX000" },
  { name: "PGRST202 -> 500", error: { code: "PGRST202", message: "Could not find the function" }, status: 500, body: "internal_error", logCode: "db:PGRST202" },
];

for (const m of MAPPINGS) {
  Deno.test(`mappaus: ${m.name} -> ${m.status}`, async () => {
    const { res, body, calls, out } = await run(
      req({ action: "unavailability_add", args: { staff_id: U1, starts: "2026-11-01T10:00", ends: "2026-11-01T12:00", request_id: RID } }),
      { error: m.error },
    );
    assertEquals(res.status, m.status);
    assertEquals(body, { ok: false, error: m.body });
    assertEquals(res.headers.get("retry-after"), m.retryAfter ?? null);
    assertEquals(calls.map((c) => c.fn), ["botgw_call", "botgw_log_failure"]);
    assertEquals(calls[1].args, { p_key_hash: await sha256Hex(KEY), p_action: "unavailability_add", p_error: m.logCode });
    if (!/^[a-z_]+$/.test(m.error.message ?? "")) assert(!out.includes(m.error.message ?? "@@"), "tietokannan viesti ei lokiin");
    assertMatch(out, new RegExp(`"status":${m.status}`));
    assertMatch(out, new RegExp(`"request_id":"${RID}"`));
  });
}

Deno.test("rpc heittää -> 500 internal_error + log_failure, ei virheviestiä lokiin", async () => {
  const { res, body, calls } = await run(req({ action: "me" }), { throws: true });
  assertEquals(res.status, 500);
  assertEquals(body, { ok: false, error: "internal_error" });
  assertEquals(calls.map((c) => c.fn), ["botgw_call", "botgw_log_failure"]);
  assertEquals(calls[1].args.p_error, "edge:rpc_failed");
});

Deno.test("botgw_log_failure epäonnistuu -> vastaus silti oikea", async () => {
  const { res, body } = await run(req({ action: "me" }), { error: { code: "BG429", message: "rate_limited" }, logFails: true });
  assertEquals(res.status, 429);
  assertEquals(body.error, "rate_limited");
});

Deno.test("tietokanta palauttaa odottamatonta -> 500", async () => {
  const { res } = await run(req({ action: "me" }), { data: "nope" });
  assertEquals(res.status, 500);
});

// ---------- onnistuneet polut: jokainen toiminto ----------
const SUCCESS: Record<string, Record<string, unknown>> = {
  me: {},
  my_shifts: { from: "2026-11-01", to: "2026-11-30" },
  offers_open: {},
  offer_respond: { offer_id: U1, response: "accept", request_id: RID },
  inbox: {},
  inbox_ack: { ids: [1, 2, 3] },
  backlog_list: { all: true },
  backlog_update: { item_id: 7, status: "in_progress", note: "ARGVALUE-123", task_id: 3, task_done: true, request_id: RID },
  backlog_add: { title: "Uusi kohta", description: "ARGVALUE-123", category: "vuorot", kind: "fix", request_id: RID },
  shifts_list: { from: "2026-11-01", to: "2026-12-01", role: "heater", staff_id: U1, include_cancelled: false },
  shift_history: { shift_id: U1 },
  shift_change: { action: "create", role: "reception", starts: "2026-11-02T10:00", ends: "2026-11-02T16:00", note: "ARGVALUE-123", request_id: RID },
  shift_reassign: { shift_id: U1, from_staff_id: U2, to_staff_id: "44444444-4444-4444-8444-444444444444", note: "vaihto", request_id: RID },
  staff_list: { include_inactive: true },
  staff_create: {
    name: "Salainen Henkilö",
    calendar_name: "Salainen",
    phone: "+358401234567",
    email: "secret.person@example.com",
    notes: "terveystieto-xyz",
    roles: ["heater", "reception"],
    request_id: RID,
  },
  staff_update: { staff_id: U1, phone: "+358401234567", active: false, request_id: RID },
  staff_role_set: { staff_id: U1, role: "therapist", active: true, request_id: RID },
  unavailability_list: { from: "2026-11-01", to: "2026-11-30", staff_id: U1 },
  unavailability_add: { staff_id: U1, starts: "2026-11-03T08:00", ends: "2026-11-03T18:00", request_id: RID },
  unavailability_update: { id: U2, starts: "2026-11-03T09:00", ends: "2026-11-03T18:00", request_id: RID },
  unavailability_delete: { id: U2, request_id: RID },
  proposal_add: { area: "shift_offers", title: "Ehdotus", body: "ARGVALUE-123", proposed_change: { key: "x" }, request_id: RID },
  proposal_list: {},
};

Deno.test("jokaiselle spec-toiminnolle on onnistumistesti", () => {
  assertEquals(Object.keys(SUCCESS).sort(), Object.keys(ACTIONS).sort());
  assertEquals(Object.keys(ACTIONS).length, 23);
});

for (const [action, args] of Object.entries(SUCCESS)) {
  Deno.test(`onnistuu: ${action}`, async () => {
    const { res, body, calls, out } = await run(req({ action, args }));
    assertEquals(res.status, 200);
    assertEquals(body.ok, true);
    assertEquals(body.data, { echo: action });
    assertEquals(calls.length, 1, "ei log_failurea onnistuessa");
    assertEquals(calls[0], { fn: "botgw_call", args: { p_key_hash: await sha256Hex(KEY), p_action: action, p_args: args } });
    if (args.request_id) assertEquals(body.request_id, RID);
    assertMatch(out, new RegExp(`"action":"${action}".*"status":200.*"result":"ok"`));
    assertEquals(res.headers.get("cache-control"), "no-store");
  });
}

Deno.test("args puuttuu -> {} tietokannalle", async () => {
  const { res, calls } = await run(req({ action: "me" }));
  assertEquals(res.status, 200);
  assertEquals(calls[0].args.p_args, {});
});

Deno.test("idempotentti uusinta: duplicate välitetään sellaisenaan", async () => {
  const { res, body, out } = await run(req({ action: "shift_change", args: { action: "cancel", shift_id: U1, request_id: RID } }), {
    data: { ok: true, duplicate: true, request_id: RID },
  });
  assertEquals(res.status, 200);
  assertEquals(body, { ok: true, duplicate: true, request_id: RID });
  assertMatch(out, /"result":"duplicate"/);
});

Deno.test("staff_update whatsapp_enabled/bot_channel välitetään tietokannalle -> field_not_editable 403", async () => {
  for (const k of ["whatsapp_enabled", "bot_channel"]) {
    assertEquals(validateArgs("staff_update", { staff_id: U1, [k]: true }), null);
    const { res, body } = await run(req({ action: "staff_update", args: { staff_id: U1, [k]: true } }), {
      error: { code: "42501", message: "field_not_editable" },
    });
    assertEquals(res.status, 403);
    assertEquals(body.error, "field_not_editable");
  }
});

// ---------- edge-rajat ----------
Deno.test("raja: 60/min per tiiviste -> 429 Retry-After 60, ei tietokantakutsua; ikkuna nollautuu", async () => {
  let t = 1_000_000;
  const m = mockRpc();
  const h = createHandler({ rpc: m.rpc, disabled: () => false, now: () => t, limiter: new RateLimiter() });
  const { out } = await captured(async () => {
    for (let i = 0; i < EDGE_LIMIT_PER_KEY; i++) {
      const r = await h(req({ action: "me" }, { ip: `198.51.100.${i}` }));
      assertEquals(r.status, 200);
      await r.body?.cancel();
    }
    const n = m.calls.length;
    const r = await h(req({ action: "me" }, { ip: "198.51.100.250" }));
    assertEquals(r.status, 429);
    assertEquals(r.headers.get("retry-after"), "60");
    assertEquals((await r.json()).error, "rate_limited");
    assertEquals(m.calls.length, n, "ei tietokantaa rajan ylittyessä");
    t += 60_001;
    const r2 = await h(req({ action: "me" }, { ip: "198.51.100.251" }));
    assertEquals(r2.status, 200);
    await r2.body?.cancel();
  });
  await assertNoSecrets(out);
  assert(!out.includes("198.51.100"), "IP ei lokiin");
});

Deno.test("raja: 30/min per IP", async () => {
  const m = mockRpc();
  const h = createHandler({ rpc: m.rpc, disabled: () => false, now: () => 5, limiter: new RateLimiter() });
  await captured(async () => {
    for (let i = 0; i < EDGE_LIMIT_PER_IP; i++) {
      const r = await h(req({ action: "me" }, { key: `key-${i}-padding-padding-padding`, ip: "192.0.2.1" }));
      assertEquals(r.status, 200);
      await r.body?.cancel();
    }
    const r = await h(req({ action: "me" }, { key: "another-key-padding-padding-pad", ip: "192.0.2.1" }));
    assertEquals(r.status, 429);
    assertEquals(r.headers.get("retry-after"), "60");
    await r.body?.cancel();
    const r2 = await h(req({ action: "me" }, { key: "another-key-padding-padding-pad", ip: "192.0.2.2" }));
    assertEquals(r2.status, 200);
    await r2.body?.cancel();
  });
});

Deno.test("RateLimiter: avainmäärä rajattu", () => {
  const l = new RateLimiter(3);
  for (let i = 0; i < 10; i++) l.hit(`k${i}`, 1, 0);
  assertEquals(l.hit("k9", 1, 0), false);
  assertEquals(l.hit("k0", 1, 0), true, "vanhin avain poistui");
});

// ---------- lähdekoodin vartijat ----------
Deno.test("lähde: vain botgw_call/botgw_log_failure, ei .from()-taulukutsuja eikä Google-kutsuja", async () => {
  for (const f of ["core.ts", "index.ts"]) {
    const src = await Deno.readTextFile(new URL(`./${f}`, import.meta.url));
    const code = src.split("\n").filter((l) => !l.trim().startsWith("//")).join("\n");
    assert(!/(?<!Array)\.from\(/.test(code), `${f}: .from(`);
    assert(!/\.schema\(/.test(code), `${f}: .schema(`);
    assert(!/googleapis|calendar\/v3/.test(code), `${f}: Google`);
    assert(!/work_shifts|shift_assignments|shift_outbox/.test(code), `${f}: suora vuorotaulu`);
    const rpcs = [...code.matchAll(/rpc\(\s*"([a-z_]+)"/g)].map((m) => m[1]);
    for (const r of rpcs) assert(r === "botgw_call" || r === "botgw_log_failure", `${f}: rpc ${r}`);
    assert(!/console\.[a-z]+\([^)]*(key|hash|args)\b/i.test(code.replace(/keyHash \? /g, "")), `${f}: epäilyttävä lokitus`);
  }
});

Deno.test("config.toml: bot-gateway verify_jwt = false", async () => {
  const toml = await Deno.readTextFile(new URL("../../config.toml", import.meta.url));
  assertMatch(toml, /\[functions\.bot-gateway\]\s*\nverify_jwt = false/);
});
