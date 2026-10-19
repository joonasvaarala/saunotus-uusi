// Procountor-adapteri ilman verkkoa ja ilman oikeita tunnuksia.
// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/_tests/procountor_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { apiPrefix, originFor, ProcountorClient, ProcountorError, readCreds, redact, type Env } from "../procountor-sync/client.ts";
import { buildProcountorInvoice, type NormalizedInvoice } from "../procountor-sync/invoice.ts";
import { handle, type Db } from "../procountor-sync/handler.ts";

const env = (extra: Record<string, string | undefined> = {}): Env => {
  const m: Record<string, string | undefined> = {
    PROCOUNTOR_CLIENT_ID: "test-client",
    PROCOUNTOR_CLIENT_SECRET: "test-secret",
    PROCOUNTOR_API_KEY: "test-api-key",
    PROCOUNTOR_REDIRECT_URI: "https://example.test/procountor",
    ...extra,
  };
  return { get: (k) => m[k] };
};

type Call = { url: string; method: string; headers: Record<string, string>; body: string | undefined };
function mockFetch(routes: Record<string, (c: Call) => { status?: number; json?: unknown }>) {
  const calls: Call[] = [];
  const f = async (url: string, init?: RequestInit) => {
    const headers = (init?.headers ?? {}) as Record<string, string>;
    const raw = init?.body == null ? undefined : String(init.body);
    const c: Call = { url, method: init?.method ?? "GET", headers, body: raw };
    calls.push(c);
    const u = new URL(url);
    const key = `${c.method} ${u.pathname}`;
    const h = routes[key];
    if (!h) return new Response(JSON.stringify({ errors: [{ message: "no route " + key }] }), { status: 404 });
    const r = h(c);
    return new Response(JSON.stringify(r.json ?? {}), { status: r.status ?? 200 });
  };
  return { f, calls };
}
const tokenRoute = { "POST /api/oauth/token": () => ({ json: { access_token: "tok-1", expires_in: 3600 } }) };

const creds = readCreds(env())!;
const invoice = (over: Partial<NormalizedInvoice> = {}): NormalizedInvoice => ({
  customer: { name: "Havuhattu Oy", email: "lasku@example.test", business_id: "3018112-1", address: { street: "Saunatie 1", zip: "04130", city: "Sipoo", country: "FI" } },
  date: "2026-10-01", due_date: "2026-10-15", currency: "EUR",
  lines: [{ description: "Saunavuoro", quantity: 2, unit: "kpl", unit_price_net: 40, vat_rate: 25.5 }],
  ...over,
});

Deno.test("readCreds ja osoitteet: puuttuva tunnus on null, muu kuin prod on PTS", () => {
  assert(readCreds(env()) !== null);
  assertEquals(readCreds(env({ PROCOUNTOR_API_KEY: undefined })), null);
  assertEquals(originFor("prod"), "https://api.procountor.com");
  assertEquals(originFor("pts"), "https://pts-api.procountor.com");
  assertEquals(originFor("jotain"), "https://pts-api.procountor.com");
  assertEquals(apiPrefix("/supported/api"), "/supported/api");
  assertEquals(apiPrefix("/v2610/api"), "/v2610/api");
  assertEquals(apiPrefix("https://evil.example"), "/supported/api");
});

Deno.test("token: lomake runkoon, ei osoitteeseen, välimuisti", async () => {
  const m = mockFetch({ ...tokenRoute, "GET /supported/api/coa": () => ({ json: { ok: true } }) });
  const api = new ProcountorClient(creds, "pts", "/supported/api", m.f);
  await api.call("coa", "GET", "/coa");
  await api.call("coa", "GET", "/coa");
  const tokens = m.calls.filter((c) => c.url.includes("/oauth/token"));
  assertEquals(tokens.length, 1);
  assert(tokens[0].url === "https://pts-api.procountor.com/api/oauth/token");
  assert(!tokens[0].url.includes("test-secret"));
  assert(!tokens[0].url.includes("test-api-key"));
  assert(tokens[0].body?.includes("grant_type=client_credentials"));
  assert(tokens[0].body?.includes("client_secret=test-secret"));
  assertEquals(m.calls[1].headers.authorization, "Bearer tok-1");
  assertEquals(m.calls.filter((c) => c.url.includes("/coa")).length, 2);
});

Deno.test("401 uusii tokenin kerran, 400 ei uudelleenyritä POST-kutsua", async () => {
  let n = 0;
  const m = mockFetch({
    "POST /api/oauth/token": () => ({ json: { access_token: "tok-" + (++n), expires_in: 3600 } }),
    "POST /supported/api/invoices": (c) => (c.headers.authorization === "Bearer tok-1" ? { status: 401, json: { errors: [{ message: "expired" }] } } : { json: { id: 9 } }),
  });
  const api = new ProcountorClient(creds, "pts", "/supported/api", m.f);
  const created = await api.call("invoice_create", "POST", "/invoices", { body: { type: "SALES_INVOICE" } });
  assertEquals((created as { id: number }).id, 9);
  assertEquals(m.calls.filter((c) => c.url.includes("/oauth/token")).length, 2);
  assertEquals(m.calls.filter((c) => c.url.endsWith("/invoices")).length, 2);

  const bad = mockFetch({ ...tokenRoute, "POST /supported/api/ledgerreceipts": () => ({ status: 400, json: { errors: [{ status: 400, message: "account missing", access_token: "should-hide" }] } }) });
  const api2 = new ProcountorClient(creds, "prod", "/supported/api", bad.f);
  let err: ProcountorError | null = null;
  try { await api2.call("ledger", "POST", "/ledgerreceipts", { body: { type: "JOURNAL" } }); }
  catch (e) { err = e as ProcountorError; }
  assert(err instanceof ProcountorError);
  assertEquals(err!.status, 400);
  assertEquals(bad.calls.filter((c) => c.url.includes("/ledgerreceipts")).length, 1);
  assertEquals(err!.summary().message, "account missing");
  assert(!JSON.stringify(redact(err!.body)).includes("should-hide"));
  assert(bad.calls[1].url.startsWith("https://api.procountor.com/"));
});

Deno.test("laskurunko: sähköposti, verkkolasku, numero ja viite", () => {
  const email = buildProcountorInvoice(invoice(), { vatStatus: "1", bankAccount: "FI2112345600000785" });
  assertEquals(email.ok, true);
  assertEquals(email.channel, "EMAIL");
  assertEquals(email.request?.invoiceChannel, "EMAIL");
  assertEquals(email.request?.originalInvoiceNumber, undefined);
  assertEquals((email.request?.paymentInfo as { bankReferenceCode: string }).bankReferenceCode, "");
  assertEquals((email.request?.extraInfo as { unitPricesIncludeVat: boolean }).unitPricesIncludeVat, false);
  assertEquals((email.request?.invoiceRows as { unit: string; unitPrice: number }[])[0].unit, "PIECE");
  assertEquals((email.request?.invoiceRows as { unitPrice: number }[])[0].unitPrice, 40);
  assertEquals(email.request?.status, "UNFINISHED");
  assert(!("invoiceNumber" in (email.request ?? {})));

  const numbered = buildProcountorInvoice(invoice({ number: "L-100", reference: "26013" }), { vatStatus: 12, bankAccount: "FI2112345600000785" });
  assertEquals(numbered.request?.originalInvoiceNumber, "L-100");
  assertEquals((numbered.request?.paymentInfo as { bankReferenceCode: string }).bankReferenceCode, "26013");

  const einvoice = buildProcountorInvoice(invoice({
    customer: { name: "Yritys", business_id: "3018112-1", einvoice_address: "003708369224", einvoice_operator: "003723327487", address: { street: "Saunatie 1", zip: "04130", city: "Sipoo" } },
    notes: "Sauna",
  }), { vatStatus: "1", bankAccount: "FI21" });
  assertEquals(einvoice.channel, "ELECTRONIC_INVOICE");
  const cp = einvoice.request?.counterParty as { einvoiceAddress: { operator: string; address: string }; taxCode?: string };
  assertEquals(cp.einvoiceAddress, { operator: "003723327487", address: "003708369224" });
  assertEquals(einvoice.request?.additionalInformation, "Sauna");
  assert(!JSON.stringify(einvoice.request).includes("\"notes\""));
  assert(!JSON.stringify(einvoice.request).includes("ediId"));
  assertEquals((einvoice.request?.billingAddress as { street: string }).street, "Saunatie 1");

  const missing = buildProcountorInvoice(invoice({ customer: { name: "A" } }), { vatStatus: "1", bankAccount: "FI21" });
  assertEquals(missing.ok, false);
  assert(missing.errors.includes("channel_missing"));
  const half = buildProcountorInvoice(invoice({ customer: { name: "A", einvoice_address: "0037" } }), {});
  assert(half.errors.includes("einvoice_incomplete"));
  assert(half.blockers.includes("vat_status"));
  assert(half.blockers.includes("bank_account"));
  const unit = buildProcountorInvoice(invoice({ lines: [{ description: "X", quantity: 1, unit: "kori", unit_price_net: 1, vat_rate: 25.5 }] }), { vatStatus: "1", bankAccount: "FI21" });
  assert(unit.errors.includes("unknown_unit"));

  const gross = buildProcountorInvoice(invoice({
    lines: [{ description: "Sauna", quantity: 1, unit: "kpl", unit_price_net: 51, unit_price_gross: 64, price_basis: "gross", vat_rate: 25.5 }],
  }), { vatStatus: "1", bankAccount: "FI21" });
  assertEquals((gross.request?.extraInfo as { unitPricesIncludeVat: boolean }).unitPricesIncludeVat, true);
  assertEquals((gross.request?.invoiceRows as { unitPrice: number }[])[0].unitPrice, 64);

  const mixed = buildProcountorInvoice(invoice({
    lines: [
      { description: "A", quantity: 1, unit: "kpl", unit_price_net: 51, unit_price_gross: 64, price_basis: "gross", vat_rate: 25.5 },
      { description: "B", quantity: 1, unit: "kpl", unit_price_net: 100, unit_price_gross: 125.5, price_basis: "net", vat_rate: 25.5 },
    ],
  }), { vatStatus: "1", bankAccount: "FI21" });
  assertEquals((mixed.request?.extraInfo as { unitPricesIncludeVat: boolean }).unitPricesIncludeVat, false);
  assertEquals((mixed.request?.invoiceRows as { unitPrice: number }[])[0].unitPrice, 51);
  assertEquals((mixed.request?.invoiceRows as { unitPrice: number }[])[1].unitPrice, 100);
});

function fakeDb(handlers: Record<string, (a?: any) => any>): { db: Db; calls: { fn: string; args: any }[] } {
  const calls: { fn: string; args: any }[] = [];
  const wrap = async (fn: string, args: any) => {
    calls.push({ fn, args });
    const h = handlers[fn];
    if (!h) throw { message: "missing " + fn, code: "db_error" };
    return h(args);
  };
  const db: Db = {
    cronOk: async (secret) => secret === "cron-secret",
    config: async () => wrap("config", {}),
    dailyPrepare: (date, force) => wrap("daily", { date, force }),
    invoiceReserve: (a) => wrap("reserve", a),
    mark: (id, status, error, response) => wrap("mark", { id, status, error, response }),
  };
  return { db, calls };
}

const post = (body: unknown, secret = "cron-secret") => new Request("https://proj.supabase.co/functions/v1/procountor-sync", {
  method: "POST", headers: { "content-type": "application/json", "x-sync-secret": secret }, body: JSON.stringify(body),
});

Deno.test("dry_run ilman tunnuksia ei kutsu Procountoria", async () => {
  const m = mockFetch(tokenRoute);
  const { db, calls } = fakeDb({
    config: () => ({ mode: "live", settings: { environment: "pts", vat_status: "1", bank_account: "FI21", daily_enabled: true } }),
    daily: () => ({ action: "send", id: 4, status: "processing", business_date: "2026-10-01", request: { type: "JOURNAL", status: "UNFINISHED", name: "Saunotus" } }),
    mark: () => ({ ok: true }),
  });
  const res = await handle(post({ action: "daily" }), { db, env: env({ PROCOUNTOR_CLIENT_SECRET: undefined }), fetchImpl: m.f });
  const body = await res.json();
  assertEquals(res.status, 200);
  assertEquals(body.action, "dry_run");
  assertEquals(body.reason, "credentials_missing");
  assertEquals(calls.find((c) => c.fn === "daily")?.args.force, true);
  assertEquals(m.calls.length, 0);
});

Deno.test("päiväkirja live: createReconciliation ja status ei lähde", async () => {
  const m = mockFetch({ ...tokenRoute, "POST /supported/api/ledgerreceipts": () => ({ json: { id: 55 } }) });
  const { db, calls } = fakeDb({
    config: () => ({ mode: "live", settings: { environment: "pts", api_prefix: "/supported/api" } }),
    daily: () => ({ action: "send", id: 4, business_date: "2026-10-01", request: { type: "JOURNAL", status: "UNFINISHED", name: "Saunotus", receiptDate: "2026-10-01" } }),
    mark: () => ({ ok: true }),
  });
  const res = await handle(post({ action: "daily" }), { db, env: env(), fetchImpl: m.f });
  const body = await res.json();
  assertEquals(body.status, "sent");
  assertEquals(body.ledger_receipt_id, 55);
  const ledger = m.calls.find((c) => c.url.includes("/ledgerreceipts"))!;
  assert(ledger.url.includes("createReconciliation=true"));
  assert(!JSON.parse(ledger.body!).status);
  assertEquals(calls.find((c) => c.fn === "mark")?.args.response, { ledger_receipt_id: 55, step: "sent" });
});

Deno.test("laskun lähetys: jo lähetetty ei kutsu Procountoria", async () => {
  const m = mockFetch(tokenRoute);
  const { db } = fakeDb({
    config: () => ({ mode: "live", settings: { environment: "pts", vat_status: "1", bank_account: "FI2112345600000785" } }),
    reserve: () => ({ action: "already", id: 8, status: "sent", invoice_id: 77 }),
  });
  const res = await handle(post({ action: "send_invoice", idempotency_key: "invoice-1", invoice: invoice() }), { db, env: env(), fetchImpl: m.f });
  const body = await res.json();
  assertEquals(body.action, "already");
  assertEquals(body.invoice_id, 77);
  assertEquals(m.calls.length, 0);
});

Deno.test("laskun lähetys: luonti, hyväksyntä, lähetys ja kumppani", async () => {
  const m = mockFetch({
    ...tokenRoute,
    "GET /supported/api/businesspartners": () => ({ json: { results: [] } }),
    "POST /supported/api/businesspartners": () => ({ json: { id: 3 } }),
    "POST /supported/api/invoices": () => ({ json: { id: 90, ledgerReceiptId: 91 } }),
    "PUT /supported/api/invoices/90/approve": () => ({ json: { message: "ok" } }),
    "PUT /supported/api/invoices/90/send": () => ({ json: { message: "ok" } }),
  });
  const marks: any[] = [];
  const { db } = fakeDb({
    config: () => ({ mode: "live", settings: { environment: "pts", vat_status: "1", bank_account: "FI2112345600000785", api_prefix: "/supported/api" } }),
    reserve: () => ({ action: "send", id: 8, status: "processing", step: null, invoice_id: null }),
    mark: (a) => { marks.push(a); return { ok: true }; },
  });
  const res = await handle(post({ action: "send_invoice", idempotency_key: "invoice-2", invoice: invoice() }), { db, env: env(), fetchImpl: m.f });
  const body = await res.json();
  assertEquals(body.action, "sent");
  assertEquals(body.invoice_id, 90);
  const created = m.calls.find((c) => c.method === "POST" && c.url.endsWith("/invoices"))!;
  const sentBody = JSON.parse(created.body!);
  assertEquals(sentBody.partnerId, 3);
  assert(!sentBody.status);
  assertEquals(sentBody.originalInvoiceNumber, undefined);
  assert(m.calls.some((c) => c.url.endsWith("/approve")));
  assert(m.calls.some((c) => c.url.endsWith("/send")));
  assertEquals(marks[0].status, "processing");
  assertEquals(marks.at(-1).status, "sent");
  assertEquals(marks.at(-1).response.step, "sent");
  const search = m.calls.find((c) => c.url.includes("/businesspartners") && c.method === "GET")!;
  assertEquals(search.headers.identifier, "3018112-1");
});

Deno.test("väärä cron-salaisuus hylätään", async () => {
  const { db } = fakeDb({});
  const res = await handle(post({ action: "daily" }, "nope"), { db, env: env() });
  assertEquals(res.status, 401);
});
