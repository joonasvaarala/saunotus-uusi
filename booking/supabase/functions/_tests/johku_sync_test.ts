// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/_tests/johku_sync_test.ts
import { assertEquals } from "jsr:@std/assert@1";
import { secretOk } from "../johku-sync/auth.ts";
import { forbiddenKey, handle, type Db, type Env } from "../johku-sync/handler.ts";

const env = (secret?: string): Env => ({ get: (k) => (k === "JOHKU_SYNC_SECRET" ? secret : undefined) });

function db(calls: string[]): Db {
  return {
    state: async () => { calls.push("state"); return { hidden_count: 33 }; },
    apply: async (payload) => { calls.push("apply:" + JSON.stringify(payload)); return { ok: true, applied: {} }; },
    giftCards: async (rows) => { calls.push("gift:" + (rows as unknown[]).length); return { ok: true, new: 0, updated: 1 }; },
    log: async (row) => { calls.push("log:" + (row as { status?: string }).status); return { ok: true, id: 1 }; },
  };
}

const post = (body: unknown, secret: string | null) =>
  new Request("https://example.test/johku-sync", {
    method: "POST",
    headers: { "content-type": "application/json", ...(secret ? { "x-johku-sync-secret": secret } : {}) },
    body: JSON.stringify(body),
  });

Deno.test("secret compare does not accept a missing or wrong secret", () => {
  assertEquals(secretOk(undefined, "x"), false);
  assertEquals(secretOk("right-secret", null), false);
  assertEquals(secretOk("right-secret", "wrong"), false);
  assertEquals(secretOk("right-secret", "right-secret"), true);
  assertEquals(secretOk("right-secret", "right-secret-extra"), false);
});

Deno.test("missing secret is misconfigured, wrong secret is unauthorized", async () => {
  const calls: string[] = [];
  let res = await handle(post({ action: "state" }, "x"), { db: db(calls), env: env(undefined) });
  assertEquals(res.status, 503);
  res = await handle(post({ action: "state" }, "nope"), { db: db(calls), env: env("right-secret") });
  assertEquals(res.status, 401);
  assertEquals(calls, []);
});

Deno.test("state and apply are forwarded and forbidden keys are refused", async () => {
  const calls: string[] = [];
  const d = db(calls);
  let res = await handle(post({ action: "state" }, "right-secret"), { db: d, env: env("right-secret") });
  assertEquals(res.status, 200);
  const state = await res.json();
  assertEquals(state.state.hidden_count, 33);

  res = await handle(post({ action: "apply", payload: { customers: [{ external_id: "1" }] } }, "right-secret"), { db: d, env: env("right-secret") });
  assertEquals(res.status, 200);
  assertEquals(calls.includes("apply:{\"customers\":[{\"external_id\":\"1\"}]}"), true);

  res = await handle(post({ action: "apply", payload: { payments: [{ amount: 1 }] } }, "right-secret"), { db: d, env: env("right-secret") });
  assertEquals(res.status, 400);
  const body = await res.json();
  assertEquals(body.error, "forbidden_key");
  assertEquals(body.key, "payments");
});

Deno.test("gift card response does not echo codes", async () => {
  const calls: string[] = [];
  const res = await handle(post({ action: "gift_cards", rows: [{ external_id: "9", code: "AAAA-BBBB-CCCC", balance: 10 }] }, "right-secret"), {
    db: db(calls), env: env("right-secret"),
  });
  assertEquals(res.status, 200);
  const text = await res.text();
  assertEquals(text.includes("AAAA"), false);
  assertEquals(text.includes("code"), false);
  assertEquals(calls[0], "gift:1");
});

Deno.test("forbiddenKey walks nested objects", () => {
  assertEquals(forbiddenKey({ orders: [{ external_meta: { johku: { payment_method: "cash" } } }] }), null);
  assertEquals(forbiddenKey({ reservations: [{ hidden_at: null }] }), "hidden_at");
  assertEquals(forbiddenKey({ a: [{ b: { email_outbox: [] } }] }), "email_outbox");
});
