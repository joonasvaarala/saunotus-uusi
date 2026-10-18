import { assertEquals } from "jsr:@std/assert@1";
import type { Db } from "../_shared/mobilepay.ts";
import { handle } from "../vismapay-start/handler.ts";

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
