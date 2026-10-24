import { assertEquals } from "jsr:@std/assert@1";
import type { Db, Env, Fetch } from "../_shared/mobilepay.ts";
import { handle } from "../vismapay-start/handler.ts";
import { handle as notify } from "../vismapay-notify/handler.ts";
import { handle as ret } from "../vismapay-return/handler.ts";
import { handle as refund } from "../vismapay-refund/handler.ts";
import { hmacSha256Hex, macMatches, readCreds, returnMacMessage } from "../_shared/vismapay.ts";

const TOK = "11111111-2222-4333-8444-555555555555";
function db(data: unknown): Db {
  return { mode: async () => "off", rpc: async () => ({ data, error: null }) };
}
const post = (body: unknown) => new Request("https://f/vismapay-start", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });

Deno.test("vismapay-start: dry_run ei merkitse maksua maksetuksi eikä ohjaa", async () => {
  const r = await handle(post({ order_token: TOK }), { db: db({ ok: true, mode: "dry_run", dry_run: true, payment_id: 4, provider_ref: "dryrun-4", amount: 3, order_no: 100, status: "pending", message: "Testitila" }) });
  const j = await r.json();
  assertEquals(r.status, 200);
  assertEquals(j.ok, true);
  assertEquals(j.dry_run, true);
  assertEquals(j.implemented, false);
  assertEquals(j.provider_ref, "dryrun-4");
  assertEquals(j.redirect_url, undefined);
});

Deno.test("vismapay-start: live ei kutsu Vismaa", async () => {
  const r = await handle(post({ order_token: TOK }), { db: db({ ok: false, code: "vismapay_live_not_implemented", mode: "live", message: "ei toteutettu" }) });
  const j = await r.json();
  assertEquals(r.status, 501);
  assertEquals(j.code, "vismapay_live_not_implemented");
  assertEquals(j.implemented, false);
});

Deno.test("vismapay-start: off", async () => {
  const r = await handle(post({ order_token: TOK }), { db: db({ ok: false, code: "vismapay_off", mode: "off" }) });
  assertEquals((await r.json()).code, "vismapay_off");
});

const PRIV = "xad3b23s2a0d0328b4ea08yd95";
const ORDER = "sauna-o10001-p4-a1";
const TEST_CARDS = ["4012888888881881", "5244024870672677", "378748900392307", "36319163670450", "4400000000000008", "4484070000000000", "4462030000000000", "4900000000000003", "4900000000000011", "4900000000000086", "4917610000000000", "4917300800000000"];

function envOf(map: Record<string, string>): Env {
  return { get: (k) => map[k] };
}
const testEnv = () => envOf({
  VISMAPAY_TEST_API_KEY: "test-api",
  VISMAPAY_TEST_PRIVATE_KEY: PRIV,
  VISMAPAY_LIVE_API_KEY: "live-api",
  VISMAPAY_LIVE_PRIVATE_KEY: "live-secret",
  VISMAPAY_API_KEY: "alias-api",
  VISMAPAY_PRIVATE_KEY: "alias-secret",
  SUPABASE_URL: "https://example.supabase.co",
});
const asJson = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

Deno.test("MAC: dokumentoidut vektorit ja väärä koodi ei täsmää", async () => {
  assertEquals(await hmacSha256Hex(PRIV, "0|12345|1"), "CCE582990AFB0BFF29A928E8B47E88403505AAF083181E8A7F93B7A42C306E77");
  assertEquals(await hmacSha256Hex(PRIV, "1|12345"), "864F74A47EDEDE35FBD3676C4F41376157AD54D17164633E09A54C4BAD1E573F");
  assertEquals(returnMacMessage({ RETURN_CODE: "0", ORDER_NUMBER: "12345", SETTLED: "1" }), "0|12345|1");
  assertEquals(returnMacMessage({ RETURN_CODE: "1", ORDER_NUMBER: "12345" }), "1|12345");
  assertEquals(await macMatches(PRIV, "0|12345|1", "cce582990afb0bff29a928e8b47e88403505aaf083181e8a7f93b7a42c306e77"), true);
  assertEquals(await macMatches(PRIV, "0|12345|1", "0000000000000000000000000000000000000000000000000000000000000000"), false);
});

Deno.test("readCreds: testitila ei käytä live-avaimia, live suosii LIVE_*", () => {
  const e = testEnv();
  assertEquals(readCreds(e, "test")?.apiKey, "test-api");
  assertEquals(readCreds(e, "live")?.apiKey, "live-api");
  assertEquals(readCreds(envOf({ VISMAPAY_LIVE_API_KEY: "live-api", VISMAPAY_LIVE_PRIVATE_KEY: "live-secret", VISMAPAY_API_KEY: "alias-api", VISMAPAY_PRIVATE_KEY: "alias-secret" }), "test"), null);
  assertEquals(readCreds(envOf({ VISMAPAY_API_KEY: "alias-api", VISMAPAY_PRIVATE_KEY: "alias-secret" }), "live")?.apiKey, "alias-api");
});

Deno.test("testikortit on dokumentoitu", async () => {
  const doc = await Deno.readTextFile(new URL("../../../../docs/vismapay-integraatio.md", import.meta.url));
  for (const pan of TEST_CARDS) assertEquals(doc.includes(pan), true, pan);
});

function routed(fn: (name: string, args: Record<string, unknown> | undefined, calls: unknown[]) => { data: unknown; error: null | { message: string } }, mode: "test" | "live" | "off" = "test") {
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

Deno.test("vismapay-start: test luo auth_paymentin ja palauttaa vain Visma-ohjauksen", async () => {
  const seen: { url: string; body: Record<string, unknown> }[] = [];
  const fetchImpl: Fetch = async (url, init) => {
    const body = JSON.parse(String(init?.body));
    seen.push({ url: String(url), body });
    return asJson(200, { result: 0, token: "tokentokentoken", type: "e-payment" });
  };
  const { db, calls } = routed((name) => {
    if (name === "vismapay_payment_prepare") {
      return { data: { ok: true, mode: "test", dry_run: false, order_number: ORDER, amount: 40, amount_minor: 4000, currency: "EUR", locale: "fi", payment_id: 4, customer: { firstname: "Aada", lastname: "Aalto", email: "aada@example.test", phone: "0401234567" } }, error: null };
    }
    return { data: { ok: true }, error: null };
  });
  const r = await handle(post({ order_token: TOK }), { db, env: testEnv(), fetch: fetchImpl, now: () => 1_700_000_000_000 });
  const j = await r.json();
  assertEquals(r.status, 200);
  assertEquals(j.redirect_url, "https://www.vismapay.com/pbwapi/token/tokentokentoken");
  assertEquals(j.token, undefined);
  assertEquals(seen.length, 1);
  assertEquals(seen[0].url, "https://www.vismapay.com/pbwapi/auth_payment");
  const body = seen[0].body;
  assertEquals(body.order_number, ORDER);
  assertEquals(body.amount, 4000);
  assertEquals((body.payment_method as { override_auto_settlement: number }).override_auto_settlement, 2);
  assertEquals("products" in body, false);
  assertEquals((body.customer as { phone?: string }).phone, undefined);
  assertEquals(body.authcode, await hmacSha256Hex(PRIV, `test-api|${ORDER}`));
  assertEquals((body.payment_method as { return_url: string }).return_url, "https://example.supabase.co/functions/v1/vismapay-return");
  const created = calls.find((c) => (c as [string])[0] === "vismapay_payment_event") as [string, { p_state: string; p_token: string }];
  assertEquals(created[1].p_state, "CREATED");
  assertEquals(created[1].p_token, "tokentokentoken");
});

Deno.test("vismapay-start: testitilan puuttuvat avaimet eivät käytä live-avaimia", async () => {
  const { db } = routed(() => ({ data: { ok: true, mode: "test", dry_run: false, order_number: ORDER, amount: 40, amount_minor: 4000, currency: "EUR", locale: "fi", payment_id: 4 }, error: null }));
  const r = await handle(post({ order_token: TOK }), { db, env: envOf({ VISMAPAY_LIVE_API_KEY: "live-api", VISMAPAY_LIVE_PRIVATE_KEY: "live-secret", SUPABASE_URL: "https://example.supabase.co" }), fetch: async () => { throw new Error("ei http"); } });
  const j = await r.json();
  assertEquals(r.status, 503);
  assertEquals(j.code, "not_configured");
});

function payDb(apply: (args: Record<string, unknown>) => unknown, extra: Record<string, unknown> = {}) {
  const calls: unknown[] = [];
  const dbx: Db = {
    mode: async () => "test",
    rpc: async (name, args) => {
      calls.push([name, args]);
      if (name === "vismapay_payment_lookup" || name === "vismapay_order_refs") {
        return { data: { found: true, ok: true, env: "test", amount: 40, order_token: TOK, site_base_url: "https://saunotus.fi", order_page_path: "/tilaus/", payment_status: "pending", refs: [{ order_number: ORDER, env: "test" }], ...extra }, error: null };
      }
      if (name === "vismapay_payment_apply") return { data: apply(args ?? {}), error: null };
      return { data: { ok: true }, error: null };
    },
  };
  return { db: dbx, calls };
}

function vismaFetch(payment: Record<string, unknown>, more: Record<string, unknown> = {}): Fetch {
  return async (url) => {
    const path = String(url);
    if (path.endsWith("/get_payment")) return asJson(200, { result: 0, payment });
    if (path.endsWith("/check_payment_status")) return asJson(200, more.check ?? { result: 2 });
    if (path.endsWith("/capture")) return asJson(200, more.capture ?? { result: 0 });
    if (path.endsWith("/create_refund")) return asJson(200, more.refund ?? { result: 0, type: "instant", refund_id: 77 });
    if (path.endsWith("/get_refund")) return asJson(200, more.getRefund ?? { result: 0, refund: { status: 9, refund_id: 77 } });
    return asJson(500, { result: 10 });
  };
}

Deno.test("notify: väärä MAC ei muuta maksua", async () => {
  const { db, calls } = payDb(() => ({ outcome: "paid" }));
  const r = await notify(new Request(`https://f/vismapay-notify?RETURN_CODE=0&ORDER_NUMBER=${ORDER}&SETTLED=1&AUTHCODE=NO`), { db, env: testEnv(), fetch: vismaFetch({ amount: 4000, status: 4 }) });
  assertEquals(r.status, 401);
  assertEquals(calls.some((c) => (c as [string])[0] === "vismapay_payment_apply"), false);
});

Deno.test("notify: maksettu, epäonnistunut ja summan täsmäys", async () => {
  const mac = await hmacSha256Hex(PRIV, `0|${ORDER}|1`);
  const paid = payDb((args) => ({ outcome: args.p_outcome, already: false, code: args.p_amount === "40.00" ? null : "amount_mismatch" }));
  const ok = await notify(new Request(`https://f/vismapay-notify?RETURN_CODE=0&ORDER_NUMBER=${ORDER}&SETTLED=1&AUTHCODE=${mac}`), { db: paid.db, env: testEnv(), fetch: vismaFetch({ amount: 4000, status: 4, source: { object: "card", brand: "visa", last4: "1881", card_token: "secret" } }) });
  assertEquals(ok.status, 200);
  assertEquals(await ok.text(), "OK");
  const apply = paid.calls.find((c) => (c as [string])[0] === "vismapay_payment_apply") as [string, { p_outcome: string; p_amount: string; p_raw: { source: { card_token?: string } } }];
  assertEquals(apply[1].p_outcome, "paid");
  assertEquals(apply[1].p_amount, "40.00");
  assertEquals(apply[1].p_raw.source.card_token, undefined);

  const again = payDb(() => ({ outcome: "paid", already: true }));
  const second = await notify(new Request(`https://f/vismapay-notify?RETURN_CODE=0&ORDER_NUMBER=${ORDER}&SETTLED=1&AUTHCODE=${mac}`), { db: again.db, env: testEnv(), fetch: vismaFetch({ amount: 4000, status: 4 }) });
  assertEquals(second.status, 200);

  const failMac = await hmacSha256Hex(PRIV, `1|${ORDER}`);
  const failed = payDb((args) => ({ outcome: args.p_outcome }));
  const fr = await notify(new Request(`https://f/vismapay-notify?RETURN_CODE=1&ORDER_NUMBER=${ORDER}&AUTHCODE=${failMac}`), { db: failed.db, env: testEnv(), fetch: vismaFetch({ amount: 4000, status: 2 }) });
  assertEquals(fr.status, 200);
  const fapply = failed.calls.find((c) => (c as [string])[0] === "vismapay_payment_apply") as [string, { p_outcome: string }];
  assertEquals(fapply[1].p_outcome, "failed");

  const mismatch = payDb(() => ({ outcome: "needs_review", code: "amount_mismatch" }));
  const mr = await notify(new Request(`https://f/vismapay-notify?RETURN_CODE=0&ORDER_NUMBER=${ORDER}&SETTLED=1&AUTHCODE=${mac}`), { db: mismatch.db, env: testEnv(), fetch: vismaFetch({ amount: 100, status: 5 }) });
  assertEquals(mr.status, 200);
  const mapply = mismatch.calls.find((c) => (c as [string])[0] === "vismapay_payment_apply") as [string, { p_amount: string }];
  assertEquals(mapply[1].p_amount, "1.00");
});

Deno.test("paluu: väärä MAC ei muuta tilaa eikä ohjaa kyselyn osoitteeseen", async () => {
  const { db, calls } = payDb(() => ({ outcome: "paid" }));
  const bad = await ret(new Request(`https://f/vismapay-return?RETURN_CODE=0&ORDER_NUMBER=${ORDER}&SETTLED=1&AUTHCODE=NO&return=https://evil.example/`), { db, env: testEnv(), fetch: vismaFetch({ amount: 4000, status: 4 }) });
  assertEquals(bad.status, 401);
  assertEquals(calls.some((c) => (c as [string])[0] === "vismapay_payment_apply"), false);
  const mac = await hmacSha256Hex(PRIV, `0|${ORDER}|1`);
  const good = await ret(new Request(`https://f/vismapay-return?RETURN_CODE=0&ORDER_NUMBER=${ORDER}&SETTLED=1&AUTHCODE=${mac}&next=https://evil.example/phish`), { db, env: testEnv(), fetch: vismaFetch({ amount: 4000, status: 4 }) });
  assertEquals(good.status, 302);
  const loc = good.headers.get("location") || "";
  assertEquals(loc.startsWith("https://saunotus.fi/tilaus/"), true);
  assertEquals(loc.includes("pay=vismapay"), true);
  assertEquals(loc.includes("evil.example"), false);
});

function refundDb(mode: "test" | "off" = "test") {
  const calls: unknown[] = [];
  const dbx: Db = {
    mode: async () => mode,
    rpc: async (name, args) => {
      calls.push([name, args]);
      if (name === "vismapay_refund_claim") {
        return { data: { claimed: [{ refund_id: 9, amount_minor: 500, order_number: ORDER, env: "test", provider_refund_id: null, sibling_refund_ids: [] }] }, error: null };
      }
      if (name === "vismapay_refund_lookup") return { data: { found: true, refund_id: 9, env: "test" }, error: null };
      return { data: { ok: true }, error: null };
    },
  };
  return { db: dbx, calls };
}

Deno.test("hyvitys: osittainen instant leimataan ennen kuittia, sähköposti jää odottamaan", async () => {
  const { db, calls } = refundDb();
  const seen: number[] = [];
  const fetchImpl: Fetch = async (url, init) => {
    const body = JSON.parse(String(init?.body || "{}"));
    if (String(url).endsWith("/get_payment")) return asJson(200, { result: 0, payment: { amount: 4000, status: 4, customer: { email: "aada@example.test" }, refunds: [] } });
    if (String(url).endsWith("/create_refund")) { seen.push(body.amount); return asJson(200, { result: 0, type: "instant", refund_id: 77 }); }
    return asJson(500, {});
  };
  const r = await refund(new Request("https://f/vismapay-refund", { method: "POST", body: JSON.stringify({ refund_id: 9 }) }), { db, env: testEnv(), fetch: fetchImpl, authorize: async () => true });
  const j = await r.json();
  assertEquals(j.processed[0].result, "done");
  assertEquals(seen, [500]);
  const names = calls.map((c) => (c as [string])[0]);
  assertEquals(names.indexOf("vismapay_refund_stamp") < names.indexOf("vismapay_refund_complete"), true);
  const stamp = calls.find((c) => (c as [string])[0] === "vismapay_refund_stamp") as [string, { p_provider_refund_id: string }];
  assertEquals(stamp[1].p_provider_refund_id, "77");

  const email = refundDb();
  const er = await refund(new Request("https://f/vismapay-refund", { method: "POST", body: JSON.stringify({ refund_id: 9 }) }), {
    db: email.db, env: testEnv(), authorize: async () => true,
    fetch: async (url) => String(url).endsWith("/get_payment")
      ? asJson(200, { result: 0, payment: { amount: 4000, status: 5, refunds: [] } })
      : asJson(200, { result: 0, type: "email", refund_id: 88, refund_url: "https://www.vismapay.com/refund/88" }),
  });
  const ej = await er.json();
  assertEquals(ej.processed[0].result, "awaiting_customer");
  assertEquals(email.calls.some((c) => (c as [string])[0] === "vismapay_refund_complete"), false);

  const denied = await refund(new Request("https://f/vismapay-refund", { method: "POST", body: "{}" }), { db, env: testEnv(), fetch: fetchImpl, authorize: async () => false });
  assertEquals(denied.status, 403);
});

Deno.test("hyvityksen notify: väärä MAC ei kirjaa, hyväksytty kirjaa", async () => {
  const bad = refundDb();
  const br = await notify(new Request("https://f/vismapay-notify?RETURN_CODE=0&REFUND_ID=77&AUTHCODE=NO"), { db: bad.db, env: testEnv(), fetch: async () => asJson(500, {}) });
  assertEquals(br.status, 401);
  assertEquals(bad.calls.some((c) => (c as [string])[0] === "vismapay_refund_complete"), false);
  const mac = await hmacSha256Hex(PRIV, "0|77");
  const good = refundDb();
  const gr = await notify(new Request(`https://f/vismapay-notify?RETURN_CODE=0&REFUND_ID=77&AUTHCODE=${mac}`), { db: good.db, env: testEnv(), fetch: async () => asJson(500, {}) });
  assertEquals(gr.status, 200);
  assertEquals(good.calls.some((c) => (c as [string])[0] === "vismapay_refund_complete"), true);
});
