// sumup-notify: SumUp Cloud API -webhook (checkoutin return_url). booking_295.
// Webhookiin ei luoteta yksin: salaisuus (?s=) tarkistetaan, mutta maksu merkitään maksetuksi vasta, kun SumUpin rajapinta
// (GET transactions) vahvistaa tilan ja summan (reconcilePayment). Webhookin status on vain vihje.
// Vastaukset: 200 = käsitelty tai ohitettu, 401 = väärä salaisuus, 503 = yritä uudelleen.
import type { Env, Fetch, Rpc } from "../_shared/mobilepay.ts";
import { envMatchesMode, readConfig, safeEqual, SumupApi, validId } from "../_shared/sumup.ts";
import { reconcilePayment } from "../_shared/sumup_flow.ts";

export type Deps = { db: { rpc: Rpc; mode: () => Promise<string> }; env: Env; fetch: Fetch };
const text = (status: number, body: string) => new Response(body, { status, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== "POST") return text(405, "method_not_allowed");
  const mode = await deps.db.mode();
  if (mode !== "test" && mode !== "live") return text(200, "ignored");
  if (!envMatchesMode(deps.env, mode)) return text(503, "not_configured");
  const cfg = readConfig(deps.env);
  if (!cfg) return text(503, "not_configured");
  const given = new URL(req.url).searchParams.get("s") ?? "";
  if (!safeEqual(given, cfg.webhookSecret)) return text(401, "bad_secret");

  let b: any = null;
  try { b = await req.json(); } catch { return text(400, "bad_json"); }
  const p = b?.payload ?? b;
  const clientTxId = p?.client_transaction_id;
  if (!validId(clientTxId)) return text(200, "ignored");
  if (typeof p?.merchant_code === "string" && p.merchant_code !== cfg.merchantCode) return text(200, "ignored");
  const hint = typeof p?.status === "string" ? p.status.toLowerCase() : null;

  const { data: pay, error } = await deps.db.rpc("sumup_pos_lookup_ref", { p_client_tx_id: clientTxId });
  if (error) return text(503, "retry");
  if (!pay?.found) return text(200, "ignored");
  try {
    const r = await reconcilePayment(deps.db.rpc, new SumupApi(cfg, deps.fetch), pay, { hint });
    if (r.retry) return text(503, "retry");
    return text(200, "OK");
  } catch (e) {
    console.error("sumup-notify", (e as Error).message);
    return text(503, "retry");
  }
}
