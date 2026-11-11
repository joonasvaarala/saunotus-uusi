// checkoutx-pos (booking_286): Surfboard-rajapinta mockattu, ei verkkoa eikä tietokantaa.
import { assert, assertEquals } from "jsr:@std/assert@1";
import type { Env } from "../_shared/mobilepay.ts";
import { b64url, configureLink, mapOrderStatus, readConfig, registerLink, SurfboardApi, toMinor, transactionLink } from "../_shared/checkoutx.ts";
import { type Caller, type CxDb, handle } from "../checkoutx-pos/handler.ts";

const env = (m: Record<string, string>): Env => ({ get: (k) => m[k] });
const SECRETS = {
  SURFBOARD_API_URL: "https://demo.surfboard.example/api",
  SURFBOARD_API_KEY: "demo-key",
  SURFBOARD_API_SECRET: "demo-secret",
  SURFBOARD_MERCHANT_ID: "m123",
  SURFBOARD_STORE_ID: "s456",
  CHECKOUTX_ENV: "demo",
};
const post = (body: unknown) => new Request("https://fn.example/checkoutx-pos", { method: "POST", headers: { "content-type": "application/json", origin: "https://admin.example" }, body: JSON.stringify(body) });
const ok = (data: unknown) => new Response(JSON.stringify({ status: "SUCCESS", data, message: "ok" }), { status: 200 });
const err = (message: string, status = 200) => new Response(JSON.stringify({ status: "ERROR", message }), { status });
const decode = (s: string) => new TextDecoder().decode(Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4)), (c) => c.charCodeAt(0)));

type Call = { url: string; method: string; headers: Record<string, string>; body: any };
function fakeFetch(route: (c: Call) => Response) {
  const calls: Call[] = [];
  const f = async (url: string, init?: RequestInit) => {
    const c: Call = { url, method: init?.method ?? "GET", headers: (init?.headers ?? {}) as Record<string, string>, body: init?.body ? JSON.parse(String(init.body)) : null };
    calls.push(c);
    return route(c);
  };
  return { f, calls };
}
function fakeDb(mode: string, rpc: (name: string, args: any) => { data?: unknown; error?: { message: string; code?: string; details?: string } | null }) {
  const calls: [string, any][] = [];
  const db: CxDb = {
    cxMode: async () => mode,
    rpc: async (name, args) => { calls.push([name, args]); const r = rpc(name, args); return { data: r.data ?? null, error: r.error ?? null }; },
  };
  return { db, calls };
}
const staff = (perms: string[]): Caller => ({ uid: "u-1", service: false, can: async (p) => perms.includes(p) });
const asCaller = (c: Caller | null) => async () => c;

Deno.test("syvälinkit: base64url ilman täytettä, data sisältää terminalId:n ja interAppJWTokenin", () => {
  assertEquals(b64url("googlechrome://com.android.chrome"), "Z29vZ2xlY2hyb21lOi8vY29tLmFuZHJvaWQuY2hyb21l");
  const link = transactionLink("T1234", "eyJ.jwt.x");
  assert(link.startsWith("checkoutx://com.surfboard.checkoutx/transaction?redirectUrl="));
  const u = new URL(link.replace("checkoutx://", "https://"));
  assertEquals(decode(u.searchParams.get("redirectUrl")!), "googlechrome://com.android.chrome");
  assertEquals(JSON.parse(decode(u.searchParams.get("data")!)), { terminalId: "T1234", interAppJWToken: "eyJ.jwt.x" });
  assert(!/[=+/]/.test(u.searchParams.get("data")!));
  const reg = new URL(registerLink("abc123").replace("checkoutx://", "https://"));
  assertEquals(JSON.parse(decode(reg.searchParams.get("data")!)), { registrationCode: "abc123" });
  assert(configureLink().startsWith("checkoutx://com.surfboard.checkoutx/configure?redirectUrl="));
  // tuntematon paluukohde → Chrome (ei avointa uudelleenohjausta)
  assertEquals(transactionLink("T1234", "j", "https://evil.example"), transactionLink("T1234", "j", "chrome"));
});

Deno.test("readConfig: pakolliset salaisuudet ja https", () => {
  assert(readConfig(env(SECRETS)));
  assertEquals(readConfig(env({ ...SECRETS, SURFBOARD_API_KEY: "" })), null);
  assertEquals(readConfig(env({ ...SECRETS, SURFBOARD_API_URL: "http://demo.example" })), null);
  assertEquals(toMinor(7), 700);
  assertEquals(toMinor(12.345), 1235);
});

Deno.test("mapOrderStatus: valmis, peruttu, epäonnistunut, kesken, tuntematon", () => {
  assertEquals(mapOrderStatus({ orderStatus: "PAYMENT_COMPLETED", paymentIds: ["p1"], payments: [{ paymentId: "p1", paymentStatus: "PAYMENT_COMPLETED" }] }).state, "paid");
  assertEquals(mapOrderStatus({ orderStatus: "PAYMENT_COMPLETED", paymentIds: ["p9"] }).paymentId, "p9");
  assertEquals(mapOrderStatus({ orderStatus: "PAYMENT_CANCELLED" }).state, "cancelled");
  const f = mapOrderStatus({ orderStatus: "PENDING", payments: [{ paymentStatus: "PAYMENT_FAILED", failureReason: "CARD_DECLINED" }] });
  assertEquals([f.state, f.failureReason], ["failed", "CARD_DECLINED"]);
  assertEquals(mapOrderStatus({ orderStatus: "PENDING", payments: [{ paymentStatus: "PAYMENT_FAILED" }, { paymentStatus: "PAYMENT_PROCESSING" }] }).state, "pending");
  assertEquals(mapOrderStatus({ orderStatus: "PENDING", payments: [] }).state, "pending");
  assertEquals(mapOrderStatus({ orderStatus: "PAYMENT_PROCESSED" }).state, "pending");
  assertEquals(mapOrderStatus({ orderStatus: "SOMETHING_NEW" }).state, "pending");
  assertEquals(mapOrderStatus(null).state, "pending");
});

Deno.test("SurfboardApi: otsikot, polut ja ERROR-vastaus HTTP 200:lla", async () => {
  const { f, calls } = fakeFetch((c) => c.url.endsWith("/orders") ? ok({ orderId: "ord1234", paymentId: "pay1234", interAppJWT: "jwt" }) : err("Order not found"));
  const api = new SurfboardApi(readConfig(env(SECRETS))!, f);
  const r = await api.createOrder({ terminalId: "T1234", referenceId: "saunotus-pos-5", amountMinor: 700, lineId: "pos-1", lineName: "Pikakassa 1" });
  assertEquals(r.orderId, "ord1234");
  assertEquals(calls[0].url, "https://demo.surfboard.example/api/orders");
  assertEquals(calls[0].headers["API-KEY"], "demo-key");
  assertEquals(calls[0].headers["API-SECRET"], "demo-secret");
  assertEquals(calls[0].headers["MERCHANT-ID"], "m123");
  assertEquals(calls[0].body["terminal$id"], "T1234");
  assertEquals(calls[0].body.totalOrderAmount, { regular: 700, total: 700, currency: "978" });
  assertEquals(calls[0].body.controlFunctions.initiatePaymentsOptions.paymentMethod, "CARD");
  let thrown = "";
  try { await api.orderStatus("ord1234"); } catch (e) { thrown = (e as Error).message; }
  assertEquals(thrown, "Order not found");
  assertEquals(calls[1].url, "https://demo.surfboard.example/api/orders/ord1234/status");
});

Deno.test("portti: tila off → checkoutx_off ilman Surfboard-kutsua; ilman CHECKOUTX_ENV=demo → not_configured", async () => {
  const { f, calls } = fakeFetch(() => ok({}));
  const off = fakeDb("off", () => ({ data: null }));
  let res = await handle(post({ action: "start", order_id: 1, terminal_id: "T1234" }), { db: off.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["pos.use"])) });
  assertEquals(res.status, 409);
  assertEquals((await res.json()).code, "checkoutx_off");
  const on = fakeDb("test", () => ({ data: null }));
  res = await handle(post({ action: "start", order_id: 1, terminal_id: "T1234" }), { db: on.db, env: env({ ...SECRETS, CHECKOUTX_ENV: "live" }), fetch: f, caller: asCaller(staff(["pos.use"])) });
  assertEquals((await res.json()).code, "not_configured");
  res = await handle(post({ action: "start", order_id: 1, terminal_id: "T1234" }), { db: on.db, env: env({ ...SECRETS, SURFBOARD_API_SECRET: "" }), fetch: f, caller: asCaller(staff(["pos.use"])) });
  assertEquals((await res.json()).code, "not_configured");
  assertEquals(calls.length, 0);
  assertEquals(on.calls.length, 0);
  // hyvitys tilassa off: tyhjä käsittely (käyttöliittymä näyttää "ei käytössä")
  res = await handle(post({ action: "refund", refund_id: 3 }), { db: off.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["payments.refund"])) });
  assertEquals(await res.json(), { ok: true, mode: "off", processed: [] });
});

Deno.test("oikeudet: ei kirjautumista → 401, pos.use puuttuu → 403, liitos vaatii settings.edit", async () => {
  const { f } = fakeFetch(() => ok({}));
  const d = fakeDb("test", () => ({ data: null }));
  let res = await handle(post({ action: "status", payment_id: 1 }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(null) });
  assertEquals(res.status, 401);
  res = await handle(post({ action: "status", payment_id: 1 }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff([])) });
  assertEquals(res.status, 403);
  res = await handle(post({ action: "register_start" }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["pos.use"])) });
  assertEquals(res.status, 403);
  res = await handle(post({ action: "nope" }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["pos.use"])) });
  assertEquals(res.status, 400);
  res = await handle(new Request("https://fn.example/x", { method: "GET" }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["pos.use"])) });
  assertEquals(res.status, 405);
});

Deno.test("start: prepare → Surfboard-tilaus → created; vastauksessa syvälinkki, ei avaimia", async () => {
  const { f, calls } = fakeFetch(() => ok({ orderId: "ord5555", paymentId: "pay5555", interAppJWT: "jwt-5" }));
  const d = fakeDb("test", (name) => name === "checkoutx_pos_prepare" ? { data: { payment_id: 77, amount: 7, order_no: "K-1001", currency: "EUR" } } : { data: { ok: true } });
  const res = await handle(post({ action: "start", order_id: 12, terminal_id: "T1234" }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["pos.use"])) });
  const j = await res.json();
  assertEquals(res.status, 200);
  assertEquals(j.payment_id, 77);
  assert(String(j.deep_link).startsWith("checkoutx://com.surfboard.checkoutx/transaction?"));
  const text = JSON.stringify(j);
  assert(!text.includes("demo-key") && !text.includes("demo-secret") && !text.includes("demo.surfboard.example"));
  assertEquals(d.calls[0], ["checkoutx_pos_prepare", { p_order_id: 12, p_terminal_id: "T1234", p_actor: "u-1" }]);
  assertEquals(d.calls[1], ["checkoutx_pos_created", { p_payment_id: 77, p_sb_order_id: "ord5555", p_sb_payment_id: "pay5555" }]);
  assertEquals(calls[0].body.totalOrderAmount.total, 700);
  assertEquals(calls[0].body.referenceId, "saunotus-pos-77");
});

Deno.test("start: virheellinen syöte ja tietokannan virhekoodi välittyvät", async () => {
  const { f, calls } = fakeFetch(() => ok({}));
  const d = fakeDb("test", () => ({ error: { message: "Puhelinta ei ole liitetty CheckoutX:ään", code: "BK001", details: "terminal_not_registered" } }));
  let res = await handle(post({ action: "start", order_id: "x", terminal_id: "T1234" }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["pos.use"])) });
  assertEquals(res.status, 400);
  res = await handle(post({ action: "start", order_id: 1, terminal_id: "bad id!" }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["pos.use"])) });
  assertEquals(res.status, 400);
  res = await handle(post({ action: "start", order_id: 1, terminal_id: "T1234" }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["pos.use"])) });
  assertEquals(res.status, 409);
  assertEquals((await res.json()).code, "terminal_not_registered");
  assertEquals(calls.length, 0);
});

Deno.test("start: Surfboard-virhe → rivi pois (create_failed); PS_0025 → configure-linkki", async () => {
  for (const [resp, code, status] of [[err("PS_0025: Terminal is not connected to server"), "terminal_not_connected", 409], [new Response("x", { status: 503 }), "provider_unavailable", 503], [err("bad"), "provider_error", 502], [new Response("{}", { status: 401 }), "not_configured", 503]] as const) {
    const { f } = fakeFetch(() => resp.clone());
    const d = fakeDb("test", (name) => name === "checkoutx_pos_prepare" ? { data: { payment_id: 8, amount: 3.5, order_no: "K-2" } } : { data: { ok: true } });
    const res = await handle(post({ action: "start", order_id: 2, terminal_id: "T1234" }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["pos.use"])) });
    const j = await res.json();
    assertEquals([res.status, j.code], [status, code]);
    assertEquals(d.calls[1][0], "checkoutx_pos_create_failed");
    if (code === "terminal_not_connected") assert(String(j.configure_link).includes("/configure?"));
  }
});

Deno.test("status: maksettu → apply paid Surfboardin maksutunnuksella; kesken → ei kirjausta; verkkovirhe → pending+retry", async () => {
  const lookup = { data: { payment_id: 9, status: "pending", sb_order_id: "ord9999", source_channel: "pikakassa", amount: 7 } };
  let st: Response = ok({ orderStatus: "PAYMENT_COMPLETED", paymentIds: ["pay9999"], payments: [{ paymentId: "pay9999", paymentStatus: "PAYMENT_COMPLETED" }] });
  const { f } = fakeFetch(() => st.clone());
  let d = fakeDb("test", (name) => name === "checkoutx_pos_lookup" ? lookup : { data: { ok: true } });
  let res = await handle(post({ action: "status", payment_id: 9 }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["pos.use"])) });
  assertEquals((await res.json()).state, "paid");
  assertEquals(d.calls[1][0], "checkoutx_pos_apply");
  assertEquals(d.calls[1][1].p_outcome, "paid");
  assertEquals(d.calls[1][1].p_sb_payment_id, "pay9999");

  st = ok({ orderStatus: "PENDING", payments: [{ paymentStatus: "PAYMENT_PROCESSING" }] });
  d = fakeDb("test", (name) => name === "checkoutx_pos_lookup" ? lookup : { data: { ok: true } });
  res = await handle(post({ action: "status", payment_id: 9 }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["pos.use"])) });
  assertEquals((await res.json()).state, "pending");
  assertEquals(d.calls.length, 1);

  st = ok({ orderStatus: "PENDING", payments: [{ paymentStatus: "PAYMENT_FAILED", failureReason: "DECLINED" }] });
  d = fakeDb("test", (name) => name === "checkoutx_pos_lookup" ? lookup : { data: { ok: true } });
  res = await handle(post({ action: "status", payment_id: 9 }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["pos.use"])) });
  const j = await res.json();
  assertEquals([j.state, j.failure_reason], ["failed", "DECLINED"]);
  assertEquals(d.calls[1][1].p_outcome, "failed");

  st = new Response("down", { status: 502 });
  d = fakeDb("test", (name) => name === "checkoutx_pos_lookup" ? lookup : { data: { ok: true } });
  res = await handle(post({ action: "status", payment_id: 9 }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["pos.use"])) });
  assertEquals(await res.json(), { ok: true, state: "pending", retry: true, payment_id: 9 });
});

Deno.test("status: jo maksettu tai muu kanava → ei Surfboard-kutsua", async () => {
  const { f, calls } = fakeFetch(() => ok({}));
  let d = fakeDb("test", () => ({ data: { status: "paid", sb_order_id: "ord1111", source_channel: "pikakassa" } }));
  let res = await handle(post({ action: "status", payment_id: 1 }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["pos.use"])) });
  assertEquals((await res.json()).state, "paid");
  d = fakeDb("test", () => ({ data: { status: "pending", sb_order_id: "ord1111", source_channel: "web" } }));
  res = await handle(post({ action: "status", payment_id: 1 }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["pos.use"])) });
  assertEquals(res.status, 404);
  assertEquals(calls.length, 0);
});

Deno.test("cancel: DELETE /orders → peruttu; jos asiakas ehti maksaa → paid (ei perua)", async () => {
  const lookup = { data: { payment_id: 4, status: "pending", sb_order_id: "ord4444", source_channel: "pikakassa" } };
  let statusResp = ok({ orderStatus: "PAYMENT_CANCELLED" });
  const { f, calls } = fakeFetch((c) => c.method === "DELETE" ? ok({ orderStatus: "PAYMENT_CANCELLED" }) : statusResp.clone());
  let d = fakeDb("test", (name) => name === "checkoutx_pos_lookup" ? lookup : { data: { ok: true } });
  let res = await handle(post({ action: "cancel", payment_id: 4 }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["pos.use"])) });
  assertEquals((await res.json()).state, "cancelled");
  assertEquals(calls[0].method, "DELETE");
  assertEquals(calls[0].url, "https://demo.surfboard.example/api/orders/ord4444");
  assertEquals(d.calls[1][1].p_outcome, "cancelled");
  statusResp = ok({ orderStatus: "PAYMENT_COMPLETED", paymentIds: ["pay4444"] });
  d = fakeDb("test", (name) => name === "checkoutx_pos_lookup" ? lookup : { data: { ok: true } });
  res = await handle(post({ action: "cancel", payment_id: 4 }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["pos.use"])) });
  assertEquals((await res.json()).state, "paid");
  assertEquals(d.calls[1][1].p_outcome, "paid");
});

Deno.test("liitos: register_start → koodi ja linkki; register_check tallentaa terminalId:n", async () => {
  let details: unknown = { registrationStatus: "NOT_REGISTERED" };
  const { f, calls } = fakeFetch((c) => c.url.endsWith("/terminals/interapp") ? ok({ registrationCode: "regcode1" }) : ok(details));
  const d = fakeDb("test", () => ({ data: { ok: true, label: "Kassapuhelin" } }));
  const deps = { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["settings.edit"])) };
  let j = await (await handle(post({ action: "register_start" }), deps)).json();
  assertEquals(j.registration_code, "regcode1");
  assert(String(j.deep_link).includes("/register?"));
  assertEquals(calls[0].url, "https://demo.surfboard.example/api/merchants/m123/stores/s456/terminals/interapp");
  j = await (await handle(post({ action: "register_check", registration_code: "regcode1", label: "Kassapuhelin" }), deps)).json();
  assertEquals(j, { ok: true, registered: false });
  details = { registrationStatus: "REGISTERED", terminalId: "83abab731f6fb00704" };
  j = await (await handle(post({ action: "register_check", registration_code: "regcode1", label: "Kassapuhelin" }), deps)).json();
  assertEquals([j.registered, j.terminal_id], [true, "83abab731f6fb00704"]);
  assertEquals(d.calls[0], ["checkoutx_terminal_save", { p_terminal_id: "83abab731f6fb00704", p_label: "Kassapuhelin", p_actor: "u-1" }]);
  const noStore = await handle(post({ action: "register_start" }), { ...deps, env: env({ ...SECRETS, SURFBOARD_STORE_ID: "" }) });
  assertEquals((await noStore.json()).code, "not_configured");
});

Deno.test("hyvitys: koko maksu → void + complete; osittainen → not_supported; Surfboard hylkää → failed", async () => {
  const { f, calls } = fakeFetch((c) => c.url.includes("/pay-full/") ? ok({ paymentStatus: "PAYMENT_VOIDED" }) : err("Void not allowed after 23:50 CET"));
  const claim = (rows: unknown[]) => fakeDb("test", (name) => name === "checkoutx_refund_claim" ? { data: { ok: true, claimed: rows } } : { data: { ok: true } });
  let d = claim([{ refund_id: 1, amount: 7, payment_amount: 7, refunded_amount: 0, sb_payment_id: "pay-full" }]);
  let j = await (await handle(post({ action: "refund", refund_id: 1 }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["payments.refund"])) })).json();
  assertEquals(j.processed, [{ refund_id: 1, result: "done" }]);
  assertEquals([calls[0].method, calls[0].url], ["PUT", "https://demo.surfboard.example/api/payments/pay-full/void"]);
  assertEquals(d.calls[1][0], "checkoutx_refund_complete");
  d = claim([{ refund_id: 2, amount: 3, payment_amount: 7, refunded_amount: 0, sb_payment_id: "pay-full" }]);
  j = await (await handle(post({ action: "refund", refund_id: 2 }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["bookings.manage"])) })).json();
  assertEquals(j.processed, [{ refund_id: 2, result: "not_supported" }]);
  assertEquals(d.calls[1], ["checkoutx_refund_fail", { p_refund_id: 2, p_error: { reason: "partial_not_supported" } }]);
  d = claim([{ refund_id: 3, amount: 7, payment_amount: 7, refunded_amount: 0, sb_payment_id: "pay-late" }]);
  j = await (await handle(post({ action: "refund", refund_id: 3 }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["payments.refund"])) })).json();
  assertEquals(j.processed, [{ refund_id: 3, result: "failed", detail: "void_rejected" }]);
  assertEquals(d.calls[1][0], "checkoutx_refund_fail");
  const res = await handle(post({ action: "refund", refund_id: 3 }), { db: d.db, env: env(SECRETS), fetch: f, caller: asCaller(staff(["pos.use"])) });
  assertEquals(res.status, 403);
});
