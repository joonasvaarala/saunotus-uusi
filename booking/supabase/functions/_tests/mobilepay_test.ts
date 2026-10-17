// Yksikkötestit (ei verkkoyhteyttä, ei oikeita avaimia): deno test --allow-none booking/supabase/functions/_tests/mobilepay_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { aggVal, buildReturnUrl, type Db, type Env, MobilePayApi, readCreds, verifyWebhook, webhookAuthorization, sha256b64 } from "../_shared/mobilepay.ts";
import { processReference } from "../_shared/mobilepay_flow.ts";
import { handle as startHandle } from "../mobilepay-start/handler.ts";
import { handle as notifyHandle } from "../mobilepay-notify/handler.ts";
import { handle as refundHandle } from "../mobilepay-refund/handler.ts";

const TOK = "11111111-2222-4333-8444-555555555555";
const REF = "sauna-o900001-p7-a1";
const env = (extra: Record<string, string> = {}): Env => { const m: Record<string, string> = { MOBILEPAY_CLIENT_ID: "cid", MOBILEPAY_CLIENT_SECRET: "csec", MOBILEPAY_SUBSCRIPTION_KEY: "sub", MOBILEPAY_MSN: "123456", MOBILEPAY_WEBHOOK_SECRET: "whsec", SUPABASE_URL: "https://proj.supabase.co", ...extra }; return { get: (k) => m[k] }; };

type Call = { url: string; method: string; headers: Record<string, string>; body: any };
function mockVipps(routes: Record<string, (c: Call) => { status?: number; json?: unknown }>) {
  const calls: Call[] = [];
  const f = async (url: string, init?: RequestInit) => {
    const c: Call = { url, method: init?.method ?? "GET", headers: (init?.headers ?? {}) as Record<string, string>, body: init?.body ? (() => { try { return JSON.parse(init!.body as string); } catch { return init!.body; } })() : undefined };
    calls.push(c);
    const path = new URL(url).pathname;
    const key = `${c.method} ${path}`;
    const h = routes[key] ?? Object.entries(routes).find(([k]) => k.endsWith("*") && key.startsWith(k.slice(0, -1)))?.[1];
    if (!h) return new Response(JSON.stringify({ title: "no route " + key }), { status: 404 });
    const r = h(c);
    return new Response(JSON.stringify(r.json ?? {}), { status: r.status ?? 200 });
  };
  return { f, calls };
}
const tokenRoute = { "POST /accesstoken/get": () => ({ json: { access_token: "tok", expires_in: "3600" } }) };

function fakeDb(handlers: Record<string, (a: any) => any>, mode: "off" | "test" | "live" = "test") {
  const calls: { fn: string; args: any }[] = [];
  const db: Db = {
    mode: async () => mode,
    rpc: async (fn, args) => {
      calls.push({ fn, args });
      const h = handlers[fn];
      if (!h) return { data: { ok: true }, error: null };
      const r = h(args);
      if (r && r.__error) return { data: null, error: r.__error };
      return { data: r, error: null };
    },
  };
  return { db, calls };
}
const lookup = (o: Partial<Record<string, unknown>> = {}) => ({ found: true, payment_id: 7, status: "pending", amount: 40, amount_minor: 4000, currency: "EUR", provider_ref: REF, stale: false, order_id: 1, order_no: 900001, order_status: "pending", order_token: TOK, env: "test", ...o });

Deno.test("readCreds: puuttuva avain -> null", () => {
  assert(readCreds(env()) !== null);
  const e = env(); const e2: Env = { get: (k) => (k === "MOBILEPAY_MSN" ? undefined : e.get(k)) };
  assertEquals(readCreds(e2), null);
});

Deno.test("buildReturnUrl: vain https, token + pay=mobilepay", () => {
  assertEquals(buildReturnUrl("https://uusi.example.fi", "/tilaus/", TOK), `https://uusi.example.fi/tilaus/?t=${TOK}&pay=mobilepay`);
  assertEquals(buildReturnUrl("http://uusi.example.fi", "/tilaus/", TOK), null);
  assertEquals(buildReturnUrl(null, "/tilaus/", TOK), null);
});

Deno.test("MobilePayApi: tokenin välimuisti, otsikot ja luontirunko", async () => {
  const m = mockVipps({ ...tokenRoute, "POST /epayment/v1/payments": () => ({ json: { redirectUrl: "https://vipps.example/r", reference: REF } }) });
  const api = new MobilePayApi("test", readCreds(env())!, m.f);
  const r = await api.createPayment({ reference: REF, amountMinor: 4000, currency: "EUR", returnUrl: "https://x.fi/tilaus/?t=1", description: "Testi" });
  await api.createPayment({ reference: REF, amountMinor: 4000, currency: "EUR", returnUrl: "https://x.fi/tilaus/?t=1", description: "Testi" });
  assertEquals(r.redirectUrl, "https://vipps.example/r");
  assertEquals(m.calls.filter((c) => c.url.endsWith("/accesstoken/get")).length, 1, "token haetaan kerran");
  const c = m.calls.find((c) => c.url.endsWith("/epayment/v1/payments"))!;
  assert(c.url.startsWith("https://apitest.vipps.no/"));
  assertEquals(c.headers["Authorization"], "Bearer tok"); assertEquals(c.headers["Idempotency-Key"], REF);
  assertEquals(c.headers["Merchant-Serial-Number"], "123456"); assertEquals(c.headers["Ocp-Apim-Subscription-Key"], "sub");
  assertEquals(c.body.amount, { currency: "EUR", value: 4000 }); assertEquals(c.body.userFlow, "WEB_REDIRECT");
  assertEquals(c.body.profile.scope, "name email phoneNumber"); assertEquals(c.body.paymentMethod.type, "WALLET"); assertEquals(c.body.reference, REF);
  const live = new MobilePayApi("live", readCreds(env())!, m.f); assertEquals(live.base, "https://api.vipps.no");
});

Deno.test("webhook-allekirjoitus: oikea hyväksytään, väärä/muokattu runko hylätään", async () => {
  const body = new TextEncoder().encode(JSON.stringify({ reference: REF, name: "epayments.payment.authorized.v1" }));
  const hash = await sha256b64(body); const date = "Sat, 17 Oct 2026 10:00:00 GMT";
  const auth = await webhookAuthorization("whsec", "/functions/v1/mobilepay-notify", date, "proj.supabase.co", hash);
  const mk = (a: string, h = hash) => new Headers({ "x-ms-date": date, "x-ms-content-sha256": h, authorization: a, host: "proj.supabase.co" });
  const base = { secret: "whsec", rawBody: body, pathCandidates: ["/mobilepay-notify", "/functions/v1/mobilepay-notify"], hostCandidates: ["proj.supabase.co"] };
  assert(await verifyWebhook({ ...base, headers: mk(auth) }));
  assert(!(await verifyWebhook({ ...base, secret: "toinen", headers: mk(auth) })));
  assert(!(await verifyWebhook({ ...base, headers: mk(auth), rawBody: new TextEncoder().encode("{}") })));
  assert(!(await verifyWebhook({ ...base, headers: mk(auth, "xxx") })));
  assert(!(await verifyWebhook({ ...base, headers: new Headers() })));
});

// ---------- start ----------
const prepOk = (o: Record<string, unknown> = {}) => ({ ok: true, reuse: false, payment_id: 7, reference: REF, attempt: 1, amount: 40, amount_minor: 4000, currency: "EUR", order_id: 1, order_no: 900001, order_token: TOK, mode: "test", superseded: [], description: "Sipoonjoen perinnesauna – tilaus 900001", site_base_url: "https://uusi.example.fi", order_page_path: "/tilaus/", ...o });
const post = (url: string, body: unknown, headers: Record<string, string> = {}) => new Request(url, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });

Deno.test("start: off -> 503, ei kutsuja Vippsiin eikä prepare-kutsua", async () => {
  const d = fakeDb({}, "off"); const m = mockVipps({});
  const r = await startHandle(post("https://f/mobilepay-start", { order_token: TOK }), { db: d.db, env: env(), fetch: m.f });
  assertEquals(r.status, 503); assertEquals((await r.json()).code, "mobilepay_off");
  assertEquals(m.calls.length, 0); assertEquals(d.calls.length, 0);
});
Deno.test("start: puuttuva salaisuus -> not_configured; virheellinen token -> 400", async () => {
  const d = fakeDb({}); const m = mockVipps({});
  const e: Env = { get: (k) => (k === "MOBILEPAY_CLIENT_SECRET" ? undefined : env().get(k)) };
  assertEquals((await startHandle(post("https://f/s", { order_token: TOK }), { db: d.db, env: e, fetch: m.f })).status, 503);
  assertEquals((await startHandle(post("https://f/s", { order_token: "x" }), { db: d.db, env: env(), fetch: m.f })).status, 400);
  assertEquals((await startHandle(post("https://f/s", { order_token: TOK, link_token: TOK }), { db: d.db, env: env(), fetch: m.f })).status, 400);
});
Deno.test("start: onnistunut luonti -> redirect_url, CREATED tallennetaan, vanha yritys perutaan", async () => {
  const d = fakeDb({ mobilepay_payment_prepare: () => prepOk({ superseded: ["sauna-o900001-p7-a0"] }) });
  const m = mockVipps({ ...tokenRoute, "POST /epayment/v1/payments": () => ({ json: { redirectUrl: "https://vipps.example/r", reference: REF } }), "POST /epayment/v1/payments/sauna-o900001-p7-a0/cancel": () => ({ json: {} }) });
  const r = await startHandle(post("https://f/s", { order_token: TOK }), { db: d.db, env: env(), fetch: m.f });
  const j = await r.json();
  assertEquals(r.status, 200); assertEquals(j.redirect_url, "https://vipps.example/r");
  const create = m.calls.find((c) => c.url.endsWith("/epayment/v1/payments"))!;
  assertEquals(create.body.returnUrl, `https://uusi.example.fi/tilaus/?t=${TOK}&pay=mobilepay`);
  assert(d.calls.some((c) => c.fn === "mobilepay_payment_event" && c.args.p_state === "CREATED" && c.args.p_redirect_url === "https://vipps.example/r"));
  assert(m.calls.some((c) => c.url.endsWith("/sauna-o900001-p7-a0/cancel")));
});
Deno.test("start: reuse -> ei Vipps-kutsua; RPC-virhe (already_paid) -> 409", async () => {
  const d = fakeDb({ mobilepay_payment_prepare: () => ({ ok: true, reuse: true, redirect_url: "https://vipps.example/same", reference: REF, payment_id: 7 }) }); const m = mockVipps({});
  const r = await startHandle(post("https://f/s", { order_token: TOK }), { db: d.db, env: env(), fetch: m.f });
  assertEquals((await r.json()).redirect_url, "https://vipps.example/same"); assertEquals(m.calls.length, 0);
  const d2 = fakeDb({ mobilepay_payment_prepare: () => ({ __error: { code: "BK001", details: "already_paid", message: "Tilaus on jo maksettu" } }) });
  const r2 = await startHandle(post("https://f/s", { order_token: TOK }), { db: d2.db, env: env(), fetch: m.f });
  assertEquals(r2.status, 409); assertEquals((await r2.json()).code, "already_paid");
});
Deno.test("start: Vipps-virhe -> create_failed kirjataan, 502, ei vuoda salaisuuksia", async () => {
  const d = fakeDb({ mobilepay_payment_prepare: () => prepOk() });
  const m = mockVipps({ ...tokenRoute, "POST /epayment/v1/payments": () => ({ status: 400, json: { title: "Bad request", detail: "nope" } }) });
  const r = await startHandle(post("https://f/s", { order_token: TOK }), { db: d.db, env: env(), fetch: m.f });
  assertEquals(r.status, 502);
  const txt = JSON.stringify(await r.json()) + JSON.stringify(d.calls);
  assert(!txt.includes("csec") && !txt.includes("sub\"") && !txt.includes("Bearer"));
  assert(d.calls.some((c) => c.fn === "mobilepay_payment_event" && c.args.p_state === "create_failed"));
});
Deno.test("start: site_base_url puuttuu -> ei luoda maksua Vippsiin", async () => {
  const d = fakeDb({ mobilepay_payment_prepare: () => prepOk({ site_base_url: null }) }); const m = mockVipps({ ...tokenRoute });
  const r = await startHandle(post("https://f/s", { order_token: TOK }), { db: d.db, env: env(), fetch: m.f });
  assertEquals(r.status, 503); assert(!m.calls.some((c) => c.url.endsWith("/epayment/v1/payments")));
});
Deno.test("start: GET ?p=link -> 302 Vippsiin", async () => {
  const d = fakeDb({ mobilepay_payment_prepare: () => prepOk() });
  const m = mockVipps({ ...tokenRoute, "POST /epayment/v1/payments": () => ({ json: { redirectUrl: "https://vipps.example/r", reference: REF } }) });
  const r = await startHandle(new Request(`https://f/mobilepay-start?p=${TOK}`), { db: d.db, env: env(), fetch: m.f });
  assertEquals(r.status, 302); assertEquals(r.headers.get("location"), "https://vipps.example/r");
  assertEquals(d.calls.find((c) => c.fn === "mobilepay_payment_prepare")!.args.p_link_token, TOK);
});

// ---------- flow ----------
const vp = (o: Record<string, unknown> = {}) => ({ state: "AUTHORIZED", reference: REF, amount: { currency: "EUR", value: 4000 }, aggregate: { authorizedAmount: { currency: "EUR", value: 4000 }, capturedAmount: { currency: "EUR", value: 0 } }, userDetails: { email: "a@b.fi", firstName: "Maija", lastName: "Meikäläinen", mobileNumber: "358401234567" }, ...o });
const capturedAgg = { aggregate: { authorizedAmount: { currency: "EUR", value: 4000 }, capturedAmount: { currency: "EUR", value: 4000 } } };

Deno.test("flow: AUTHORIZED -> täydennys, confirmable, capture, vasta sitten payment_mark_paid", async () => {
  const order: string[] = [];
  const d = fakeDb({
    mobilepay_payment_lookup: () => lookup(), mobilepay_payment_confirmable: () => { order.push("confirmable"); return { confirmable: true, reason: "ok" }; },
    mobilepay_fill_customer: () => { order.push("fill"); return { ok: true, filled: ["email", "phone"] }; },
    payment_mark_paid: () => { order.push("mark_paid"); return { ok: true }; },
  });
  const m = mockVipps({ ...tokenRoute, "GET /epayment/v1/payments/*": () => ({ json: vp() }), "POST /epayment/v1/payments/sauna-o900001-p7-a1/capture": (c) => { order.push("capture"); assertEquals(c.body.modificationAmount, { currency: "EUR", value: 4000 }); assertEquals(c.headers["Idempotency-Key"], `capture-${REF}`); return { json: { ...capturedAgg } }; } });
  const out = await processReference(REF, { db: d.db, api: new MobilePayApi("test", readCreds(env())!, m.f) });
  assertEquals(out.outcome, "paid"); assertEquals(order, ["fill", "confirmable", "capture", "mark_paid"]);
  const fill = d.calls.find((c) => c.fn === "mobilepay_fill_customer")!.args;
  assertEquals(fill, { p_payment_id: 7, p_name: "Maija Meikäläinen", p_email: "a@b.fi", p_phone: "358401234567" });
  assertEquals(d.calls.find((c) => c.fn === "payment_mark_paid")!.args, { p_provider: "mobilepay", p_provider_ref: REF, p_amount: 40, p_raw: null });
});
Deno.test("flow: capture epäonnistuu (4xx) -> EI merkitä maksetuksi", async () => {
  const d = fakeDb({ mobilepay_payment_lookup: () => lookup(), mobilepay_payment_confirmable: () => ({ confirmable: true }) });
  const m = mockVipps({ ...tokenRoute, "GET /epayment/v1/payments/*": () => ({ json: vp() }), "POST /epayment/v1/payments/*": () => ({ status: 400, json: { title: "x" } }) });
  const out = await processReference(REF, { db: d.db, api: new MobilePayApi("test", readCreds(env())!, m.f) });
  assertEquals(out.outcome, "capture_failed"); assert(!d.calls.some((c) => c.fn === "payment_mark_paid"));
});
Deno.test("flow: capture tilapäinen virhe -> heitetään (webhook-uudelleenyritys), ei mark_paid", async () => {
  const d = fakeDb({ mobilepay_payment_lookup: () => lookup(), mobilepay_payment_confirmable: () => ({ confirmable: true }) });
  const m = mockVipps({ ...tokenRoute, "GET /epayment/v1/payments/*": () => ({ json: vp() }), "POST /epayment/v1/payments/*": () => ({ status: 503, json: {} }) });
  let threw = false;
  try { await processReference(REF, { db: d.db, api: new MobilePayApi("test", readCreds(env())!, m.f) }); } catch { threw = true; }
  assert(threw); assert(!d.calls.some((c) => c.fn === "payment_mark_paid"));
});
Deno.test("flow: capture-vastaus ilman aggregatea -> varmistetaan GET:llä", async () => {
  let n = 0;
  const d = fakeDb({ mobilepay_payment_lookup: () => lookup(), mobilepay_payment_confirmable: () => ({ confirmable: true }), payment_mark_paid: () => ({ ok: true }) });
  const m = mockVipps({ ...tokenRoute, "GET /epayment/v1/payments/*": () => ({ json: n++ === 0 ? vp() : vp(capturedAgg) }), "POST /epayment/v1/payments/*": () => ({ json: {} }) });
  assertEquals((await processReference(REF, { db: d.db, api: new MobilePayApi("test", readCreds(env())!, m.f) })).outcome, "paid");
});
Deno.test("flow: aika ei enää vapaana -> varaus perutaan Vippsissä, maksu cancelled, ei capturea", async () => {
  const d = fakeDb({ mobilepay_payment_lookup: () => lookup(), mobilepay_payment_confirmable: () => ({ confirmable: false, reason: "slot_lost" }) });
  const m = mockVipps({ ...tokenRoute, "GET /epayment/v1/payments/*": () => ({ json: vp() }), "POST /epayment/v1/payments/sauna-o900001-p7-a1/cancel": () => ({ json: {} }) });
  const out = await processReference(REF, { db: d.db, api: new MobilePayApi("test", readCreds(env())!, m.f) });
  assertEquals(out.outcome, "cancelled_slot_lost");
  assert(m.calls.some((c) => c.url.endsWith("/cancel")) && !m.calls.some((c) => c.url.endsWith("/capture")));
  assertEquals(d.calls.find((c) => c.fn === "mobilepay_payment_fail")!.args.p_reason, "slot_lost");
});
Deno.test("flow: summa ei täsmää -> peruutus + failed, ei capturea", async () => {
  const d = fakeDb({ mobilepay_payment_lookup: () => lookup() });
  const m = mockVipps({ ...tokenRoute, "GET /epayment/v1/payments/*": () => ({ json: vp({ amount: { currency: "EUR", value: 100 }, aggregate: { authorizedAmount: { currency: "EUR", value: 100 }, capturedAmount: { currency: "EUR", value: 0 } } }) }), "POST /epayment/v1/payments/*": () => ({ json: {} }) });
  const out = await processReference(REF, { db: d.db, api: new MobilePayApi("test", readCreds(env())!, m.f) });
  assertEquals(out.outcome, "amount_mismatch"); assert(!m.calls.some((c) => c.url.endsWith("/capture")));
  assert(d.calls.some((c) => c.fn === "mobilepay_payment_fail" && c.args.p_reason === "amount_mismatch"));
});
Deno.test("flow: jo maksettu -> ei uutta capturea", async () => {
  const d = fakeDb({ mobilepay_payment_lookup: () => lookup({ status: "paid" }) });
  const m = mockVipps({ ...tokenRoute, "GET /epayment/v1/payments/*": () => ({ json: vp(capturedAgg) }) });
  assertEquals((await processReference(REF, { db: d.db, api: new MobilePayApi("test", readCreds(env())!, m.f) })).outcome, "already_paid");
  assert(!m.calls.some((c) => c.method === "POST" && c.url.includes("/capture")));
});
Deno.test("flow: aiemmin veloitettu mutta mark_paid jäi tekemättä -> merkitään maksetuksi ilman uutta capturea", async () => {
  const d = fakeDb({ mobilepay_payment_lookup: () => lookup(), payment_mark_paid: () => ({ ok: true }) });
  const m = mockVipps({ ...tokenRoute, "GET /epayment/v1/payments/*": () => ({ json: vp(capturedAgg) }) });
  assertEquals((await processReference(REF, { db: d.db, api: new MobilePayApi("test", readCreds(env())!, m.f) })).outcome, "paid");
  assert(!m.calls.some((c) => c.url.endsWith("/capture")));
});
Deno.test("flow: vanha (stale) yritys AUTHORIZED -> perutaan, nykyiseen maksuun ei kosketa", async () => {
  const d = fakeDb({ mobilepay_payment_lookup: () => lookup({ stale: true }) });
  const m = mockVipps({ ...tokenRoute, "GET /epayment/v1/payments/*": () => ({ json: vp() }), "POST /epayment/v1/payments/*": () => ({ json: {} }) });
  const out = await processReference(REF, { db: d.db, api: new MobilePayApi("test", readCreds(env())!, m.f) });
  assertEquals(out.outcome, "stale_cancelled"); assert(m.calls.some((c) => c.url.endsWith("/cancel")));
  assert(!d.calls.some((c) => c.fn === "payment_mark_paid" || c.fn === "mobilepay_payment_fail"));
});
Deno.test("flow: ABORTED -> vain tapahtuma, maksu jää pending; tuntematon viite -> unknown_reference", async () => {
  const d = fakeDb({ mobilepay_payment_lookup: () => lookup() });
  const m = mockVipps({ ...tokenRoute, "GET /epayment/v1/payments/*": () => ({ json: vp({ state: "ABORTED" }) }) });
  const out = await processReference(REF, { db: d.db, api: new MobilePayApi("test", readCreds(env())!, m.f) });
  assertEquals(out.outcome, "not_authorized"); assert(!d.calls.some((c) => c.fn === "payment_mark_paid" || c.fn === "mobilepay_payment_fail"));
  const d2 = fakeDb({ mobilepay_payment_lookup: () => ({ found: false }) });
  assertEquals((await processReference(REF, { db: d2.db, api: new MobilePayApi("test", readCreds(env())!, m.f) })).outcome, "unknown_reference");
});
Deno.test("flow: asiakastiedon täydennysvirhe ei estä maksun käsittelyä", async () => {
  const d = fakeDb({ mobilepay_payment_lookup: () => lookup(), mobilepay_payment_confirmable: () => ({ confirmable: true }), mobilepay_fill_customer: () => ({ __error: { code: "XX", message: "boom" } }), payment_mark_paid: () => ({ ok: true }) });
  const m = mockVipps({ ...tokenRoute, "GET /epayment/v1/payments/*": () => ({ json: vp() }), "POST /epayment/v1/payments/*": () => ({ json: capturedAgg }) });
  assertEquals((await processReference(REF, { db: d.db, api: new MobilePayApi("test", readCreds(env())!, m.f) })).outcome, "paid");
});

// ---------- notify ----------
async function signedWebhook(body: unknown, secret = "whsec", path = "/functions/v1/mobilepay-notify", host = "proj.supabase.co") {
  const raw = JSON.stringify(body); const hash = await sha256b64(raw); const date = new Date().toUTCString();
  return new Request(`https://${host}${path}`, { method: "POST", body: raw, headers: { host, "x-ms-date": date, "x-ms-content-sha256": hash, authorization: await webhookAuthorization(secret, path, date, host, hash), "content-type": "application/json" } });
}
Deno.test("notify: allekirjoittamaton/väärä -> 401, ei tietokantakutsuja", async () => {
  const d = fakeDb({}); const m = mockVipps({});
  const r = await notifyHandle(await signedWebhook({ reference: REF }, "vaara"), { db: d.db, env: env(), fetch: m.f });
  assertEquals(r.status, 401); assertEquals(d.calls.length, 0); assertEquals(m.calls.length, 0);
});
Deno.test("notify: oikein allekirjoitettu webhook -> käsittely (paid)", async () => {
  const d = fakeDb({ mobilepay_payment_lookup: () => lookup(), mobilepay_payment_confirmable: () => ({ confirmable: true }), payment_mark_paid: () => ({ ok: true }) });
  const m = mockVipps({ ...tokenRoute, "GET /epayment/v1/payments/*": () => ({ json: vp() }), "POST /epayment/v1/payments/*": () => ({ json: capturedAgg }) });
  const r = await notifyHandle(await signedWebhook({ reference: REF, name: "epayments.payment.authorized.v1" }), { db: d.db, env: env(), fetch: m.f });
  assertEquals(r.status, 200); assertEquals((await r.json()).outcome, "paid");
  const r2 = await notifyHandle(await signedWebhook({ reference: REF }, "whsec", "/mobilepay-notify"), { db: d.db, env: env(), fetch: m.f });
  assertEquals(r2.status, 200, "myös ilman /functions/v1-etuliitettä");
});
Deno.test("notify: webhook-salaisuus puuttuu -> 503; vieras viite -> 200 ignored; Vipps 5xx -> 503 (uudelleenyritys)", async () => {
  const d = fakeDb({}); const m = mockVipps({});
  const e: Env = { get: (k) => (k === "MOBILEPAY_WEBHOOK_SECRET" ? undefined : env().get(k)) };
  assertEquals((await notifyHandle(await signedWebhook({ reference: REF }), { db: d.db, env: e, fetch: m.f })).status, 503);
  const r = await notifyHandle(await signedWebhook({ reference: "joku-muu" }), { db: d.db, env: env(), fetch: m.f });
  assertEquals(r.status, 200); assertEquals((await r.json()).ignored, "no_reference");
  const d2 = fakeDb({ mobilepay_payment_lookup: () => lookup() });
  const m2 = mockVipps({ ...tokenRoute, "GET /epayment/v1/payments/*": () => ({ status: 500, json: {} }) });
  assertEquals((await notifyHandle(await signedWebhook({ reference: REF }), { db: d2.db, env: env(), fetch: m2.f })).status, 503);
});
Deno.test("notify: off-tilassa webhook kuitataan mutta ei käsitellä", async () => {
  const d = fakeDb({}, "off"); const m = mockVipps({});
  const r = await notifyHandle(await signedWebhook({ reference: REF }), { db: d.db, env: env(), fetch: m.f });
  assertEquals(r.status, 200); assertEquals(m.calls.length, 0); assertEquals(d.calls.length, 0);
});
Deno.test("notify: reconcile käsittelee vain tilauksen omat viitteet; huono token -> 400", async () => {
  const d = fakeDb({ mobilepay_order_refs: () => ({ ok: true, payment_status: "pending", refs: [REF] }), mobilepay_payment_lookup: () => lookup(), mobilepay_payment_confirmable: () => ({ confirmable: true }), payment_mark_paid: () => ({ ok: true }) });
  const m = mockVipps({ ...tokenRoute, "GET /epayment/v1/payments/*": () => ({ json: vp() }), "POST /epayment/v1/payments/*": () => ({ json: capturedAgg }) });
  const r = await notifyHandle(post("https://f/mobilepay-notify", { action: "reconcile", order_token: TOK }), { db: d.db, env: env(), fetch: m.f });
  const j = await r.json(); assertEquals(r.status, 200); assertEquals(j.results[0].outcome, "paid");
  assertEquals((await notifyHandle(post("https://f/mobilepay-notify", { action: "reconcile", order_token: "x" }), { db: d.db, env: env(), fetch: m.f })).status, 400);
  assertEquals((await notifyHandle(post("https://f/mobilepay-notify", { reference: REF }), { db: d.db, env: env(), fetch: m.f })).status, 400, "ilman allekirjoitusta ei voi ajaa mielivaltaista viitettä");
});

// ---------- refund ----------
Deno.test("refund: ei oikeutta -> 403, off -> ei toimia", async () => {
  const m = mockVipps({}); const d = fakeDb({});
  assertEquals((await refundHandle(post("https://f/r", {}), { db: d.db, env: env(), fetch: m.f, authorize: async () => false })).status, 403);
  const d2 = fakeDb({}, "off");
  const r = await refundHandle(post("https://f/r", {}), { db: d2.db, env: env(), fetch: m.f, authorize: async () => true });
  assertEquals((await r.json()).mode, "off"); assertEquals(d2.calls.length, 0);
});
const claimRow = { refund_id: 5, payment_id: 7, amount: 10, amount_minor: 1000, refunded_minor: 0, reference: REF, currency: "EUR" };
Deno.test("refund: onnistunut hyvitys -> refund API, vahvistus, mobilepay_refund_complete", async () => {
  const d = fakeDb({ mobilepay_refund_claim: () => ({ ok: true, claimed: [claimRow] }) });
  const m = mockVipps({ ...tokenRoute, [`POST /epayment/v1/payments/${REF}/refund`]: (c) => { assertEquals(c.body.modificationAmount, { currency: "EUR", value: 1000 }); assertEquals(c.headers["Idempotency-Key"], "sauna-refund-5"); return { json: { state: "AUTHORIZED", aggregate: { refundedAmount: { currency: "EUR", value: 1000 } } } }; } });
  const r = await refundHandle(post("https://f/r", {}), { db: d.db, env: env(), fetch: m.f, authorize: async () => true });
  assertEquals((await r.json()).processed[0].result, "done");
  assertEquals(d.calls.find((c) => c.fn === "mobilepay_refund_complete")!.args.p_refund_id, 5);
});
Deno.test("refund: Vipps hylkää (4xx) -> refund_fail; tilapäinen -> retry_later (ei failed)", async () => {
  const d = fakeDb({ mobilepay_refund_claim: () => ({ ok: true, claimed: [claimRow] }) });
  const m = mockVipps({ ...tokenRoute, [`POST /epayment/v1/payments/${REF}/refund`]: () => ({ status: 400, json: { title: "no" } }) });
  assertEquals((await (await refundHandle(post("https://f/r", {}), { db: d.db, env: env(), fetch: m.f, authorize: async () => true })).json()).processed[0].result, "failed");
  assert(d.calls.some((c) => c.fn === "mobilepay_refund_fail"));
  const d2 = fakeDb({ mobilepay_refund_claim: () => ({ ok: true, claimed: [claimRow] }) });
  const m2 = mockVipps({ ...tokenRoute, [`POST /epayment/v1/payments/${REF}/refund`]: () => ({ status: 503, json: {} }) });
  assertEquals((await (await refundHandle(post("https://f/r", {}), { db: d2.db, env: env(), fetch: m2.f, authorize: async () => true })).json()).processed[0].result, "retry_later");
  assert(!d2.calls.some((c) => c.fn === "mobilepay_refund_fail" || c.fn === "mobilepay_refund_complete"));
});
Deno.test("refund: vastaus ei vahvista summaa -> ei merkitä tehdyksi", async () => {
  const d = fakeDb({ mobilepay_refund_claim: () => ({ ok: true, claimed: [{ ...claimRow, refunded_minor: 1000 }] }) });
  const m = mockVipps({ ...tokenRoute, [`POST /epayment/v1/payments/${REF}/refund`]: () => ({ json: { aggregate: { refundedAmount: { currency: "EUR", value: 1000 } } } }), [`GET /epayment/v1/payments/${REF}`]: () => ({ json: { aggregate: { refundedAmount: { currency: "EUR", value: 1000 } } } }) });
  const r = await refundHandle(post("https://f/r", {}), { db: d.db, env: env(), fetch: m.f, authorize: async () => true });
  assertEquals((await r.json()).processed[0].result, "unverified"); assert(!d.calls.some((c) => c.fn === "mobilepay_refund_complete"));
});
Deno.test("aggVal", () => { assertEquals(aggVal({ aggregate: { capturedAmount: { currency: "EUR", value: 5 } } }, "capturedAmount"), 5); assertEquals(aggVal({}, "x"), 0); });
