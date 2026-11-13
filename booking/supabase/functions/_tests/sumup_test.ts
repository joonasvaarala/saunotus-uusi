// sumup-pos + sumup-notify (booking_295): SumUp-rajapinta mockattu, ei verkkoa eikä tietokantaa.
import { assert, assertEquals } from "jsr:@std/assert@1";
import type { Env } from "../_shared/mobilepay.ts";
import { envMatchesMode, mapTransaction, readConfig, safeEqual, SumupApi } from "../_shared/sumup.ts";
import { type Caller, handle as posHandle, type SumupDb } from "../sumup-pos/handler.ts";
import { handle as notifyHandle } from "../sumup-notify/handler.ts";

const env = (m: Record<string, string>): Env => ({ get: (k) => m[k] });
const SECRETS = {
  SUMUP_API_KEY: "sup_sk_test_x", SUMUP_AFFILIATE_KEY: "sup_afk_test_x", SUMUP_AFFILIATE_APP_ID: "app.example.saunotus",
  SUMUP_MERCHANT_CODE: "MTEST123", SUMUP_WEBHOOK_SECRET: "whsec-test", SUMUP_ENV: "sandbox",
  SUMUP_API_URL: "https://sumup.example", SUMUP_NOTIFY_URL: "https://fn.example/functions/v1/sumup-notify",
};
const post = (body: unknown) => new Request("https://fn.example/sumup-pos", { method: "POST", headers: { "content-type": "application/json", origin: "https://admin.example" }, body: JSON.stringify(body) });
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status });

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
  const db: SumupDb = {
    mode: async () => mode,
    rpc: async (name, args) => { calls.push([name, args]); const r = rpc(name, args); return { data: r.data ?? null, error: r.error ?? null }; },
  };
  return { db, calls };
}
const staff = (perms: string[]): Caller => ({ uid: "u-1", service: false, can: async (p) => perms.includes(p) });
const asCaller = (c: Caller | null) => async () => c;
const payRow = (o: Record<string, unknown> = {}) => ({ ok: true, found: true, payment_id: 5, status: "pending", amount: 7, currency: "EUR", client_transaction_id: "ctx-0001", reader_id: "rdr_0001", source_channel: "pikakassa", order_id: 9, ...o });
const SUCCESS_TX = { id: "txn-0001", status: "SUCCESSFUL", amount: 7, currency: "EUR" };

Deno.test("konfiguraatio: kaikki salaisuudet pakollisia, SUMUP_ENV täsmää tilaan", () => {
  assert(readConfig(env(SECRETS)));
  assertEquals(readConfig(env({ ...SECRETS, SUMUP_AFFILIATE_KEY: "" })), null);
  assertEquals(readConfig(env({ ...SECRETS, SUMUP_API_URL: "http://insecure.example" })), null);
  assert(envMatchesMode(env(SECRETS), "test"));
  assert(!envMatchesMode(env(SECRETS), "live"));
  assert(!envMatchesMode(env({ ...SECRETS, SUMUP_ENV: "live" }), "test"));
  assert(envMatchesMode(env({ ...SECRETS, SUMUP_ENV: "live" }), "live"));
  assert(!envMatchesMode(env({}), "test"));
  assert(safeEqual("a", "a") && !safeEqual("a", "b") && !safeEqual("a", "ab"));
});

Deno.test("mapTransaction: vain SUCCESSFUL on paid", () => {
  assertEquals(mapTransaction({ id: "txn-0001", status: "SUCCESSFUL", amount: 7, currency: "EUR" })?.state, "paid");
  assertEquals(mapTransaction({ status: "FAILED" })?.state, "failed");
  assertEquals(mapTransaction({ status: "CANCELLED" })?.state, "cancelled");
  assertEquals(mapTransaction({ status: "PENDING" })?.state, "pending");
  assertEquals(mapTransaction({ status: "UUSI_TILA" })?.state, "pending");
  assertEquals(mapTransaction(null), null);
});

Deno.test("checkout-pyyntö: POST readers/{id}/checkout, summa minor-yksikössä, affiliate palvelimelta, webhook-osoite", async () => {
  const { f, calls } = fakeFetch(() => json({ data: { client_transaction_id: "ctx-0001" } }, 201));
  const { db, calls: dbc } = fakeDb("test", (n) => {
    if (n === "sumup_pos_prepare") return { data: { payment_id: 5, order_no: "P-1", amount: 7, currency: "EUR", superseded: [] } };
    return { data: { ok: true } };
  });
  const res = await posHandler({ action: "start", order_id: 9, reader_id: "rdr_0001" }, db, f);
  const body = await res.json();
  assertEquals(res.status, 200);
  assertEquals(body.payment_id, 5);
  assertEquals(calls.length, 1);
  const c = calls[0];
  assertEquals(c.method, "POST");
  assertEquals(c.url, "https://sumup.example/v0.1/merchants/MTEST123/readers/rdr_0001/checkout");
  assertEquals(c.headers.authorization, "Bearer sup_sk_test_x");
  assertEquals(c.body.total_amount, { value: 700, currency: "EUR", minor_unit: 2 });
  assertEquals(c.body.affiliate, { app_id: "app.example.saunotus", key: "sup_afk_test_x", foreign_transaction_id: "saunotus-pos-5" });
  assertEquals(c.body.return_url, "https://fn.example/functions/v1/sumup-notify?s=whsec-test");
  assertEquals(dbc.map((x) => x[0]), ["sumup_pos_prepare", "sumup_pos_started"]);
  assertEquals(dbc[1][1], { p_payment_id: 5, p_client_tx_id: "ctx-0001" });
  // vastaus selaimelle ei sisällä salaisuuksia
  const txt = JSON.stringify(body);
  assert(!/sup_sk|sup_afk|whsec|MTEST123/.test(txt));
});

Deno.test("start: lukija offline (404) → luonti epäonnistuu, rivi pois, koodi reader_offline", async () => {
  const { f } = fakeFetch(() => json({ message: "reader not found" }, 404));
  const { db, calls } = fakeDb("test", (n) => (n === "sumup_pos_prepare" ? { data: { payment_id: 5, amount: 7, currency: "EUR", superseded: [] } } : { data: { ok: true } }));
  const res = await posHandler({ action: "start", order_id: 9, reader_id: "rdr_0001" }, db, f);
  assertEquals(res.status, 409);
  assertEquals((await res.json()).code, "reader_offline");
  assert(calls.some((x) => x[0] === "sumup_pos_create_failed"));
});

Deno.test("start: korvattu aiempi yritys → terminate ennen uutta checkoutia", async () => {
  const { f, calls } = fakeFetch((c) => (c.url.endsWith("/terminate") ? json({}, 202) : json({ data: { client_transaction_id: "ctx-0002" } }, 201)));
  const { db } = fakeDb("test", (n) => (n === "sumup_pos_prepare" ? { data: { payment_id: 6, amount: 7, currency: "EUR", superseded: [{ reader_id: "rdr_0001", client_transaction_id: "ctx-0001" }] } } : { data: { ok: true } }));
  await posHandler({ action: "start", order_id: 9, reader_id: "rdr_0001" }, db, f);
  assertEquals(calls.map((c) => c.url.split("/").pop()), ["terminate", "checkout"]);
});

Deno.test("mode off / väärä SUMUP_ENV → ei kutsuja SumUpiin", async () => {
  const { f, calls } = fakeFetch(() => json({}));
  const off = fakeDb("off", () => ({ data: {} }));
  let res = await posHandler({ action: "start", order_id: 9, reader_id: "rdr_0001" }, off.db, f);
  assertEquals((await res.json()).code, "sumup_off");
  const live = fakeDb("live", () => ({ data: {} })); // SUMUP_ENV = sandbox
  res = await posHandler({ action: "start", order_id: 9, reader_id: "rdr_0001" }, live.db, f);
  assertEquals((await res.json()).code, "not_configured");
  assertEquals(calls.length, 0);
  assertEquals(live.calls.length, 0);
});

Deno.test("oikeudet: ilman pos.use / settings.edit / payments.refund → 403, ei sisäänkirjautunut → 401", async () => {
  const { f } = fakeFetch(() => json({}));
  const { db } = fakeDb("test", () => ({ data: {} }));
  const r1 = await handleAs(staff([]), { action: "start", order_id: 1, reader_id: "rdr_0001" }, db, f);
  assertEquals(r1.status, 403);
  const r2 = await handleAs(staff(["pos.use"]), { action: "reader_pair", pairing_code: "ABCD1234", name: "x" }, db, f);
  assertEquals(r2.status, 403);
  const r3 = await handleAs(staff(["pos.use"]), { action: "refund", refund_id: 1 }, db, f);
  assertEquals(r3.status, 403);
  const r4 = await handleAs(null, { action: "status", payment_id: 1 }, db, f);
  assertEquals(r4.status, 401);
});

Deno.test("paritus: POST readers {pairing_code, name}, tallennus RPC:llä; listaus", async () => {
  const { f, calls } = fakeFetch((c) => c.method === "POST" ? json({ id: "rdr_0001", name: "Kassa", status: "processing" }, 201) : json({ items: [{ id: "rdr_0001", name: "Kassa", status: "paired" }, { id: "bad id", name: "x" }] }));
  const { db, calls: dbc } = fakeDb("test", () => ({ data: { ok: true, name: "Kassa" } }));
  let res = await handleAs(staff(["settings.edit"]), { action: "reader_pair", pairing_code: "abcd1234", name: "Kassa" }, db, f);
  const b = await res.json();
  assertEquals(b.reader_id, "rdr_0001");
  assertEquals(calls[0].url, "https://sumup.example/v0.1/merchants/MTEST123/readers");
  assertEquals(calls[0].body, { pairing_code: "ABCD1234", name: "Kassa" });
  assertEquals(dbc[0][0], "sumup_reader_save");
  assertEquals(dbc[0][1].p_reader_id, "rdr_0001");
  res = await handleAs(staff(["settings.edit"]), { action: "reader_pair", pairing_code: "x!", name: "Kassa" }, db, f);
  assertEquals(res.status, 400);
  res = await handleAs(staff(["pos.use"]), { action: "reader_list" }, db, f);
  assertEquals((await res.json()).readers, [{ reader_id: "rdr_0001", name: "Kassa", status: "paired" }]);
});

Deno.test("status: maksetuksi vasta kun rajapinta vahvistaa (SUCCESSFUL + summa)", async () => {
  let txStatus: any = { id: "txn-0001", status: "PENDING", amount: 7, currency: "EUR" };
  const { f, calls } = fakeFetch(() => json({ items: [txStatus] }));
  const { db, calls: dbc } = fakeDb("test", (n) => (n === "sumup_pos_lookup" ? { data: payRow() } : { data: { ok: true } }));
  let body = await (await posHandler({ action: "status", payment_id: 5 }, db, f)).json();
  assertEquals(body.state, "pending");
  assert(!dbc.some((x) => x[0] === "sumup_pos_apply"));
  assert(calls[0].url.includes("/v2.1/merchants/MTEST123/transactions?client_transaction_id=ctx-0001"));
  txStatus = SUCCESS_TX;
  body = await (await posHandler({ action: "status", payment_id: 5 }, db, f)).json();
  assertEquals(body.state, "paid");
  const apply = dbc.find((x) => x[0] === "sumup_pos_apply")!;
  assertEquals(apply[1], { p_payment_id: 5, p_outcome: "paid", p_transaction_id: "txn-0001", p_confirmed_by: "api", p_amount: 7, p_raw: { status: "SUCCESSFUL" } });
});

Deno.test("status: summa ei täsmää → ei merkitä maksetuksi", async () => {
  const { f } = fakeFetch(() => json({ items: [{ ...SUCCESS_TX, amount: 6.5 }] }));
  const { db, calls } = fakeDb("test", (n) => (n === "sumup_pos_lookup" ? { data: payRow() } : { data: { ok: true } }));
  const body = await (await posHandler({ action: "status", payment_id: 5 }, db, f)).json();
  assertEquals(body.state, "pending");
  assert(!calls.some((x) => x[0] === "sumup_pos_apply"));
});

Deno.test("status: FAILED → failed, CANCELLED → cancelled", async () => {
  for (const [st, want] of [["FAILED", "failed"], ["CANCELLED", "cancelled"]] as const) {
    const { f } = fakeFetch(() => json({ items: [{ id: "txn-0001", status: st, amount: 7, currency: "EUR" }] }));
    const { db, calls } = fakeDb("test", (n) => (n === "sumup_pos_lookup" ? { data: payRow() } : { data: { ok: true } }));
    const body = await (await posHandler({ action: "status", payment_id: 5 }, db, f)).json();
    assertEquals(body.state, want);
    assertEquals(calls.find((x) => x[0] === "sumup_pos_apply")![1].p_outcome, want);
  }
});

Deno.test("cancel: terminate lukijalle, sitten tila; ei maksettu → peruttu", async () => {
  const { f, calls } = fakeFetch((c) => (c.url.endsWith("/terminate") ? json({}, 202) : json({ message: "not found" }, 404)));
  const { db, calls: dbc } = fakeDb("test", (n) => (n === "sumup_pos_lookup" ? { data: payRow() } : { data: { ok: true } }));
  const body = await (await posHandler({ action: "cancel", payment_id: 5 }, db, f)).json();
  assertEquals(body.state, "cancelled");
  assertEquals(calls[0].method, "POST");
  assertEquals(calls[0].url, "https://sumup.example/v0.1/merchants/MTEST123/readers/rdr_0001/terminate");
  assertEquals(dbc.find((x) => x[0] === "sumup_pos_apply")![1].p_outcome, "cancelled");
});

Deno.test("cancel: asiakas ehti maksaa → paid, ei peruta", async () => {
  const { f } = fakeFetch((c) => (c.url.endsWith("/terminate") ? json({}, 202) : json({ items: [SUCCESS_TX] })));
  const { db, calls } = fakeDb("test", (n) => (n === "sumup_pos_lookup" ? { data: payRow() } : { data: { ok: true } }));
  const body = await (await posHandler({ action: "cancel", payment_id: 5 }, db, f)).json();
  assertEquals(body.state, "paid");
  assert(!calls.some((x) => x[0] === "sumup_pos_apply" && x[1].p_outcome === "cancelled"));
});

Deno.test("cancel: ei vielä aloitettu (ei client_transaction_id) → rivi pois ilman SumUp-kutsua", async () => {
  const { f, calls } = fakeFetch(() => json({}));
  const { db, calls: dbc } = fakeDb("test", (n) => (n === "sumup_pos_lookup" ? { data: payRow({ client_transaction_id: null }) } : { data: { ok: true } }));
  const body = await (await posHandler({ action: "cancel", payment_id: 5 }, db, f)).json();
  assertEquals(body.state, "cancelled");
  assertEquals(calls.length, 0);
  assert(dbc.some((x) => x[0] === "sumup_pos_create_failed"));
});

const notifyReq = (payload: unknown, secret = "whsec-test") =>
  new Request(`https://fn.example/sumup-notify?s=${secret}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(payload) });
const hook = (status: string) => ({ id: "evt-1", event_type: "solo.transaction.updated", payload: { client_transaction_id: "ctx-0001", merchant_code: "MTEST123", status, transaction_id: "txn-0001" } });

Deno.test("webhook: väärä salaisuus → 401, ei kutsuja", async () => {
  const { f, calls } = fakeFetch(() => json({}));
  const { db, calls: dbc } = fakeDb("test", () => ({ data: payRow() }));
  const res = await notifyHandle(notifyReq(hook("successful"), "väärä"), { db, env: env(SECRETS), fetch: f });
  assertEquals(res.status, 401);
  assertEquals(calls.length + dbc.length, 0);
});

Deno.test("webhook yksin ei merkitse maksetuksi: successful-vihje mutta rajapinta PENDING / 404", async () => {
  for (const apiRes of [json({ items: [{ id: "txn-0001", status: "PENDING", amount: 7, currency: "EUR" }] }), json({ message: "nf" }, 404)]) {
    const { f } = fakeFetch(() => apiRes.clone());
    const { db, calls } = fakeDb("test", (n) => (n === "sumup_pos_lookup_ref" ? { data: payRow() } : { data: { ok: true } }));
    const res = await notifyHandle(notifyReq(hook("successful")), { db, env: env(SECRETS), fetch: f });
    assertEquals(res.status, 200);
    assert(!calls.some((x) => x[0] === "sumup_pos_apply"), "apply ei saa kutsua ilman rajapintavahvistusta");
  }
});

Deno.test("webhook + rajapinta vahvistaa → payment_mark_paid-polku (apply paid, confirmed_by=api)", async () => {
  const { f, calls } = fakeFetch(() => json({ items: [SUCCESS_TX] }));
  const { db, calls: dbc } = fakeDb("test", (n) => (n === "sumup_pos_lookup_ref" ? { data: payRow() } : { data: { ok: true } }));
  const res = await notifyHandle(notifyReq(hook("successful")), { db, env: env(SECRETS), fetch: f });
  assertEquals(res.status, 200);
  assertEquals(calls.length, 1); // GET transactions ennen kirjausta
  const apply = dbc.find((x) => x[0] === "sumup_pos_apply")!;
  assertEquals(apply[1].p_outcome, "paid");
  assertEquals(apply[1].p_confirmed_by, "api");
  assert(dbc.findIndex((x) => x[0] === "sumup_pos_apply") > dbc.findIndex((x) => x[0] === "sumup_pos_lookup_ref"));
});

Deno.test("webhook: failed ilman transaktiota → failed; tuntematon maksu ja mode off ohitetaan; API-virhe → 503", async () => {
  let { f } = fakeFetch(() => json({ message: "nf" }, 404));
  let { db, calls } = fakeDb("test", (n) => (n === "sumup_pos_lookup_ref" ? { data: payRow() } : { data: { ok: true } }));
  await notifyHandle(notifyReq(hook("failed")), { db, env: env(SECRETS), fetch: f });
  assertEquals(calls.find((x) => x[0] === "sumup_pos_apply")![1].p_outcome, "failed");
  ({ db, calls } = fakeDb("test", () => ({ data: { ok: true, found: false } })));
  assertEquals((await notifyHandle(notifyReq(hook("successful")), { db, env: env(SECRETS), fetch: f })).status, 200);
  assert(!calls.some((x) => x[0] === "sumup_pos_apply"));
  const off = fakeDb("off", () => ({ data: {} }));
  assertEquals(await (await notifyHandle(notifyReq(hook("successful")), { db: off.db, env: env(SECRETS), fetch: f })).text(), "ignored");
  assertEquals(off.calls.length, 0);
  ({ f } = fakeFetch(() => json({ message: "boom" }, 500)));
  ({ db } = fakeDb("test", (n) => (n === "sumup_pos_lookup_ref" ? { data: payRow() } : { data: { ok: true } })));
  assertEquals((await notifyHandle(notifyReq(hook("successful")), { db, env: env(SECRETS), fetch: f })).status, 503);
});

Deno.test("hyvitys: koko maksu refund-rajapinnalla; osittainen estetty ellei sallittu; tyhjä off-tilassa", async () => {
  const claim = (amount: number, partial: boolean) => ({ ok: true, partial_refund: partial, claimed: [{ refund_id: 3, payment_id: 5, amount, payment_amount: 7, refunded_amount: 0, transaction_id: "txn-0001" }] });
  let { f, calls } = fakeFetch(() => new Response(null, { status: 204 }));
  let { db, calls: dbc } = fakeDb("test", (n) => (n === "sumup_refund_claim" ? { data: claim(7, false) } : { data: { ok: true } }));
  let body = await (await handleAs(staff(["payments.refund"]), { action: "refund", refund_id: 3 }, db, f)).json();
  assertEquals(body.processed, [{ refund_id: 3, result: "done" }]);
  assertEquals(calls[0].url, "https://sumup.example/v0.1/me/refund/txn-0001");
  assertEquals(calls[0].body, {});
  assert(dbc.some((x) => x[0] === "sumup_refund_complete"));
  ({ f, calls } = fakeFetch(() => new Response(null, { status: 204 })));
  ({ db, calls: dbc } = fakeDb("test", (n) => (n === "sumup_refund_claim" ? { data: claim(3, false) } : { data: { ok: true } })));
  body = await (await handleAs(staff(["payments.refund"]), { action: "refund", refund_id: 3 }, db, f)).json();
  assertEquals(body.processed, [{ refund_id: 3, result: "not_supported" }]);
  assertEquals(calls.length, 0);
  assert(dbc.some((x) => x[0] === "sumup_refund_fail"));
  ({ f, calls } = fakeFetch(() => new Response(null, { status: 204 })));
  ({ db } = fakeDb("test", (n) => (n === "sumup_refund_claim" ? { data: claim(3, true) } : { data: { ok: true } })));
  body = await (await handleAs(staff(["payments.refund"]), { action: "refund", refund_id: 3 }, db, f)).json();
  assertEquals(body.processed, [{ refund_id: 3, result: "done" }]);
  assertEquals(calls[0].body, { amount: 3 });
  ({ f, calls } = fakeFetch(() => json({ message: "x" }, 500)));
  body = await (await handleAs(staff(["payments.refund"]), { action: "refund", refund_id: 3 }, db, f)).json();
  assertEquals(body.processed[0].result, "retry_later");
  const off = fakeDb("off", () => ({ data: {} }));
  body = await (await handleAs(staff(["payments.refund"]), { action: "refund", refund_id: 3 }, off.db, f)).json();
  assertEquals(body.processed, []);
});

Deno.test("SumupApi: refund ilman summaa lähettää tyhjän rungon, 401 → unauthorized", async () => {
  const cfg = readConfig(env(SECRETS))!;
  const { f } = fakeFetch(() => json({ message: "no" }, 401));
  try { await new SumupApi(cfg, f).refund("txn-0001"); throw new Error("ei heittänyt"); } catch (e) { assertEquals((e as any).code, "unauthorized"); }
});

function posHandler(body: unknown, db: SumupDb, f: (u: string, i?: RequestInit) => Promise<Response>) {
  return handleAs(staff(["pos.use", "settings.edit", "payments.refund"]), body, db, f);
}
function handleAs(c: Caller | null, body: unknown, db: SumupDb, f: (u: string, i?: RequestInit) => Promise<Response>) {
  return posHandle(post(body), { db, env: env(SECRETS), fetch: f, caller: asCaller(c) });
}
