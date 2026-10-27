import { assertEquals } from "jsr:@std/assert@1";
import type { Db, Env, Fetch } from "../_shared/mobilepay.ts";
import { handle as start } from "../montonio-start/handler.ts";
import { handle as ret } from "../montonio-return/handler.ts";
import { handle as notify } from "../montonio-notify/handler.ts";
import { handle as refund } from "../montonio-refund/handler.ts";
import { applyRefundStatus, processRefund } from "../_shared/montonio_flow.ts";
import { b64urlJson, PayApi, readCreds, resolveHost, safePaymentUrl, signJwt, verifyJwt } from "../_shared/montonio.ts";

const TOK = "11111111-2222-4333-8444-555555555555";
const SECRET = "sandbox-secret";
const ACCESS = "sandbox-access";
const REF = "sauna-o10001-p4-a1";

function envOf(map: Record<string, string>): Env {
  return { get: (k) => map[k] };
}
const testEnv = () => envOf({
  MONTONIO_ACCESS_KEY: ACCESS,
  MONTONIO_SECRET_KEY: SECRET,
  MONTONIO_MODE: "sandbox",
  SUPABASE_URL: "https://example.supabase.co",
});
const post = (url: string, body: unknown) => new Request(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
const asJson = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

function routed(fn: (name: string, args: Record<string, unknown> | undefined, calls: unknown[]) => { data: unknown; error: null | { message: string; code?: string } }, mode: "test" | "live" | "off" = "test") {
  const calls: unknown[] = [];
  const dbx: Db = {
    mode: async () => mode,
    rpc: async (name, args) => {
      calls.push([name, args]);
      return fn(name, args, calls);
    },
  };
  return { db: dbx, calls };
}

Deno.test("JWT: HS256 allekirjoitus varmennetaan ja alg=none hylätään", async () => {
  const token = await signJwt({ accessKey: ACCESS, merchantReference: REF, paymentStatus: "PAID", grandTotal: 40, exp: 4_000_000_000 }, SECRET);
  const ok = await verifyJwt(token, SECRET, 1_700_000_000);
  assertEquals(ok.ok, true);
  if (ok.ok) assertEquals(ok.payload.merchantReference, REF);
  assertEquals((await verifyJwt(token, "wrong", 1_700_000_000)).ok, false);
  const none = `${b64urlJson({ alg: "none", typ: "JWT" })}.${b64urlJson({ paymentStatus: "PAID" })}.`;
  assertEquals((await verifyJwt(none, SECRET)).ok, false);
  const hs384 = `${b64urlJson({ alg: "HS384", typ: "JWT" })}.${b64urlJson({ paymentStatus: "PAID" })}.aaaa`;
  const badAlg = await verifyJwt(hs384, SECRET);
  assertEquals(badAlg.ok, false);
  if (!badAlg.ok) assertEquals(badAlg.reason, "alg");
  const expired = await signJwt({ exp: 10 }, SECRET);
  const exp = await verifyJwt(expired, SECRET, 20);
  assertEquals(exp.ok, false);
  if (!exp.ok) assertEquals(exp.reason, "expired");
});

Deno.test("resolveHost: test on sandbox, live vaatii live-tilan, väärä pari hylätään", () => {
  assertEquals(resolveHost("test", testEnv()).ok, true);
  assertEquals(resolveHost("test", envOf({ MONTONIO_MODE: "live" })).ok, false);
  assertEquals(resolveHost("live", envOf({ MONTONIO_MODE: "live" })).ok, true);
  assertEquals(resolveHost("live", testEnv()).ok, false);
  assertEquals(resolveHost("off", testEnv()).ok, false);
  assertEquals(readCreds(envOf({})) , null);
  assertEquals(safePaymentUrl("https://evil.example/pay"), null);
  assertEquals(safePaymentUrl("https://sandbox-stargate.montonio.com/pay/1")?.includes("sandbox-stargate"), true);
});

Deno.test("createOrder: JWT-runko ja kuvaus ilman välittäjän nimeä", async () => {
  let seen: { url: string; body: { data: string } } | null = null;
  const fetchImpl: Fetch = async (url, init) => {
    seen = { url: String(url), body: JSON.parse(String(init?.body)) };
    return asJson(200, { paymentUrl: "https://sandbox-stargate.montonio.com/pay/abc", uuid: "ord-1" });
  };
  const api = new PayApi(ACCESS, SECRET, "https://sandbox-stargate.montonio.com", fetchImpl, () => 1_700_000_000_000);
  const created = await api.createOrder({
    merchantReference: REF, amount: 40.005, currency: "EUR", locale: "fi",
    returnUrl: "https://example.supabase.co/functions/v1/montonio-return",
    notificationUrl: "https://example.supabase.co/functions/v1/montonio-notify",
    method: "paymentInitiation", description: "Tilaus 10001",
  });
  assertEquals(created.uuid, "ord-1");
  assertEquals(seen!.url, "https://sandbox-stargate.montonio.com/api/orders");
  const payload = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(seen!.body.data.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0))));
  assertEquals(payload.merchantReference, REF);
  assertEquals(payload.payment.method, "paymentInitiation");
  assertEquals(payload.payment.methodOptions.preferredCountry, "FI");
  assertEquals(payload.payment.methodOptions.paymentDescription, "Tilaus 10001");
  assertEquals(String(payload.payment.methodOptions.paymentDescription).toLowerCase().includes("montonio"), false);
  assertEquals((await verifyJwt(seen!.body.data, SECRET, 1_700_000_000)).ok, true);
});

Deno.test("start: dry_run ei ohjaa eikä kutsu rajapintaa", async () => {
  let called = false;
  const { db } = routed((name) => {
    if (name === "montonio_payment_prepare") return { data: { ok: true, mode: "dry_run", dry_run: true, payment_id: 4, amount: 40, order_no: 100, order_number: REF }, error: null };
    return { data: { ok: true }, error: null };
  });
  const r = await start(post("https://f/montonio-start", { order_token: TOK, method: "cardPayments" }), { db, env: testEnv(), fetch: async () => { called = true; return asJson(500, {}); } });
  const j = await r.json();
  assertEquals(j.dry_run, true);
  assertEquals(j.redirect_url, undefined);
  assertEquals(called, false);
  assertEquals(JSON.stringify(j).toLowerCase().includes("montonio"), false);
});

Deno.test("start: test luo tilauksen ja palauttaa vain sallitun ohjauksen", async () => {
  const seen: string[] = [];
  const fetchImpl: Fetch = async (url) => {
    seen.push(String(url));
    return asJson(200, { paymentUrl: "https://pay.montonio.com/session/1", uuid: "ord-9" });
  };
  const { db, calls } = routed((name) => {
    if (name === "montonio_payment_prepare") return { data: { ok: true, mode: "test", order_number: REF, amount: 12.5, currency: "EUR", locale: "fi", payment_id: 4, order_no: 10001 }, error: null };
    return { data: { ok: true }, error: null };
  });
  const r = await start(post("https://f/montonio-start", { order_token: TOK, method: "cardPayments" }), { db, env: testEnv(), fetch: fetchImpl, now: () => 1_700_000_000_000 });
  const j = await r.json();
  assertEquals(r.status, 200);
  assertEquals(j.redirect_url, "https://pay.montonio.com/session/1");
  assertEquals(seen[0], "https://sandbox-stargate.montonio.com/api/orders");
  const ev = calls.find((c) => (c as [string])[0] === "montonio_payment_event") as [string, { p_state: string; p_order_uuid: string }];
  assertEquals(ev[1].p_state, "CREATED");
  assertEquals(ev[1].p_order_uuid, "ord-9");
});

Deno.test("start: vieras ohjausosoite hylätään", async () => {
  const { db } = routed((name) => {
    if (name === "montonio_payment_prepare") return { data: { ok: true, mode: "test", order_number: REF, amount: 10, currency: "EUR", payment_id: 4, order_no: 1 }, error: null };
    return { data: { ok: true }, error: null };
  });
  const r = await start(post("https://f/montonio-start", { link_token: TOK, method: "mobilePay" }), {
    db, env: testEnv(), fetch: async () => asJson(200, { paymentUrl: "https://evil.example/pay", uuid: "x" }),
  });
  const j = await r.json();
  assertEquals(j.code, "provider_error");
  assertEquals(JSON.stringify(j).includes("Montonio"), false);
});

Deno.test("webhook: PAID merkitään kerran, toinen ilmoitus on idempotentti", async () => {
  let applies = 0;
  const { db } = routed((name, args) => {
    if (name === "montonio_payment_lookup") return { data: { found: true, amount: 40, order_uuid: "ord-1", site_base_url: "https://example.test", order_page_path: "/tilaus/", order_token: TOK }, error: null };
    if (name === "montonio_payment_apply") {
      applies += 1;
      const outcome = applies === 1 ? "paid" : "paid";
      return { data: { ok: true, outcome, already: applies > 1 }, error: null };
    }
    return { data: { ok: true }, error: null };
  });
  const token = await signJwt({ accessKey: ACCESS, merchantReference: REF, paymentStatus: "PAID", grandTotal: 40, uuid: "ord-1", exp: 4_000_000_000 }, SECRET);
  const a = await notify(post("https://f/montonio-notify", { orderToken: token }), { db, env: testEnv(), fetch: async () => asJson(500, {}) });
  const b = await notify(post("https://f/montonio-notify", { orderToken: token }), { db, env: testEnv(), fetch: async () => asJson(500, {}) });
  assertEquals(await a.text(), "OK");
  assertEquals(await b.text(), "OK");
  assertEquals(applies, 2);
  const forged = await signJwt({ accessKey: "other", merchantReference: REF, paymentStatus: "PAID", grandTotal: 40, uuid: "ord-1" }, SECRET);
  let extra = 0;
  const { db: db2 } = routed((name) => {
    if (name === "montonio_payment_lookup") return { data: { found: true, amount: 40, order_uuid: "ord-1" }, error: null };
    if (name === "montonio_payment_apply") { extra += 1; return { data: { outcome: "paid" }, error: null }; }
    return { data: {}, error: null };
  });
  const badKey = await notify(post("https://f/montonio-notify", { orderToken: forged }), { db: db2, env: testEnv(), fetch: async () => asJson(500, {}) });
  assertEquals(await badKey.text(), "OK");
  assertEquals(extra, 0);
  const mismatch = await signJwt({ accessKey: ACCESS, merchantReference: REF, paymentStatus: "PAID", grandTotal: 1, uuid: "ord-1" }, SECRET);
  const review = await notify(post("https://f/montonio-notify", { orderToken: mismatch }), { db, env: testEnv(), fetch: async () => asJson(500, {}) });
  assertEquals(review.status, 200);
  const bad = await notify(post("https://f/montonio-notify", { orderToken: "a.b.c" }), { db, env: testEnv(), fetch: async () => asJson(500, {}) });
  assertEquals(bad.status, 401);
});

Deno.test("return: varmentaa tokenin ja ohjaa pay=online", async () => {
  const token = await signJwt({ accessKey: ACCESS, merchantReference: REF, paymentStatus: "PAID", grandTotal: 40, uuid: "ord-1" }, SECRET);
  const { db } = routed((name) => {
    if (name === "montonio_payment_lookup") return { data: { found: true, amount: 40, order_uuid: "ord-1", site_base_url: "https://joonasvaarala.github.io/saunotus-uusi", order_page_path: "/varaa/tilaus/", order_token: TOK }, error: null };
    if (name === "montonio_payment_apply") return { data: { outcome: "paid" }, error: null };
    return { data: {}, error: null };
  });
  const r = await ret(new Request(`https://f/montonio-return?order-token=${encodeURIComponent(token)}`), { db, env: testEnv(), fetch: async () => asJson(500, {}) });
  assertEquals(r.status, 302);
  const loc = r.headers.get("location") || "";
  assertEquals(loc.includes("pay=online"), true);
  assertEquals(loc.toLowerCase().includes("montonio"), false);
  const bad = await ret(new Request("https://f/montonio-return?order-token=nope"), { db, env: testEnv(), fetch: async () => asJson(500, {}) });
  assertEquals(bad.status, 401);
  assertEquals((await bad.text()).includes("Montonio"), false);
});

Deno.test("hyvitys: luonti ei tee kuittia, SUCCESSFUL-ilmoitus kirjaa kerran, hylkäys ja selvitys erikseen", async () => {
  const calls: string[] = [];
  const db: Db = {
    mode: async () => "test",
    rpc: async (name) => { calls.push(name); return { data: { ok: true, outcome: "done" }, error: null }; },
  };
  const api = new PayApi(ACCESS, SECRET, "https://sandbox-stargate.montonio.com", async () => asJson(200, { uuid: "rf-1", status: "SUCCESSFUL" }));
  const created = await processRefund(api, db, { refund_id: 9, amount: 10, order_uuid: "ord-1", idempotency_key: "refund-9" });
  assertEquals(created.result, "pending");
  assertEquals(calls.includes("montonio_refund_complete"), false);
  assertEquals(calls.includes("montonio_refund_stamp"), true);

  calls.length = 0;
  const pending = await applyRefundStatus(db, { refund_id: 9, amount: 10, order_uuid: "ord-1" }, { refundStatus: "PROCESSING", refundUuid: "rf-1" });
  assertEquals(pending.result, "pending");
  assertEquals(calls.includes("montonio_refund_complete"), false);

  const done = await applyRefundStatus(db, { refund_id: 9, amount: 10, order_uuid: "ord-1", provider_refund_id: "rf-1" }, { refundStatus: "SUCCESSFUL", refundUuid: "rf-1" });
  assertEquals(done.result, "done");
  const again = await applyRefundStatus(db, { refund_id: 9, amount: 10, order_uuid: "ord-1", provider_refund_id: "rf-1" }, { refundStatus: "SUCCESSFUL", refundUuid: "rf-1" });
  assertEquals(again.result, "done");

  calls.length = 0;
  const rejected = await applyRefundStatus(db, { refund_id: 9, amount: 10 }, { refundStatus: "REJECTED", refundUuid: "rf-2" });
  assertEquals(rejected.result, "failed");
  assertEquals(calls.includes("montonio_refund_fail"), true);
  const waiting = await applyRefundStatus(db, { refund_id: 9, amount: 10 }, { refundStatus: "REJECTED", refundStatusDescription: "awaiting_settlement" });
  assertEquals(waiting.result, "awaiting_settlement");

  const unsettled = new PayApi(ACCESS, SECRET, "https://sandbox-stargate.montonio.com", async () => asJson(422, { message: "Order is not settled" }));
  calls.length = 0;
  const rel = await processRefund(unsettled, db, { refund_id: 3, amount: 5, order_uuid: "ord-2" });
  assertEquals(rel.result, "awaiting_settlement");
  assertEquals(calls.includes("montonio_refund_release"), true);
  assertEquals(calls.includes("montonio_refund_fail"), false);
});

Deno.test("refund-käsittelijä: ei oikeutta ja odottava luonti", async () => {
  const denied = await refund(post("https://f/montonio-refund", { refund_id: 1 }), { db: { mode: async () => "test", rpc: async () => ({ data: null, error: null }) }, env: testEnv(), fetch: async () => asJson(500, {}), authorize: async () => false });
  assertEquals(denied.status, 403);
  const { db, calls } = routed((name) => {
    if (name === "montonio_refund_claim") return { data: { claimed: [{ refund_id: 9, amount: 10, order_uuid: "ord-1", idempotency_key: "refund-9" }] }, error: null };
    return { data: { ok: true }, error: null };
  });
  const r = await refund(post("https://f/montonio-refund", { refund_id: 9 }), {
    db, env: testEnv(), fetch: async () => asJson(200, { uuid: "rf-9", status: "PENDING" }), authorize: async () => true,
  });
  const j = await r.json();
  assertEquals(j.processed[0].result, "pending");
  assertEquals(calls.some((c) => (c as [string])[0] === "montonio_refund_complete"), false);
});
