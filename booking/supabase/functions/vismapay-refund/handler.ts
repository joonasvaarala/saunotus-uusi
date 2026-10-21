// vismapay-refund: hallinnan hyvitys Visma Payhin (täysi tai osittainen). Vaatii payments.refund tai service role -avaimen.
// create_refund ei ole idempotentti Vismassa: provider_refund_id leimataan heti, uusinta kysyy get_refund.
import { CORS_HEADERS, dbError, type Db, type Env, type Fetch, jsonResponse } from "../_shared/mobilepay.ts";
import { envOf, processRefund } from "../_shared/vismapay_flow.ts";
import { functionBase, readCreds, VismaApi } from "../_shared/vismapay.ts";

export type Deps = { db: Db; env: Env; fetch: Fetch; authorize: (req: Request) => Promise<boolean> };

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const cors = CORS_HEADERS(req.headers.get("origin"), deps.env.get("VISMAPAY_ALLOWED_ORIGINS"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return jsonResponse({ ok: false, code: "method_not_allowed" }, 405, cors);
  if (!(await deps.authorize(req))) return jsonResponse({ ok: false, code: "forbidden", message: "Hyvitys vaatii oikeuden payments.refund." }, 403, cors);

  let b: any = null;
  try { b = await req.json(); } catch { /* tyhjä */ }
  const refundId = Number.isInteger(b?.refund_id) && b.refund_id > 0 ? b.refund_id : null;
  const mode = await deps.db.mode();
  if (mode !== "test" && mode !== "live") return jsonResponse({ ok: true, mode, processed: [] }, 200, cors);

  const { data: claim, error } = await deps.db.rpc("vismapay_refund_claim", { p_refund_id: refundId, p_limit: 20 });
  if (error) return jsonResponse({ ok: false, code: dbError(error)!.code, message: "Hyvityksiä ei voitu varata käsittelyyn." }, 500, cors);

  const notifyBase = functionBase(deps.env);
  const processed: { refund_id: number; result: string; detail?: unknown }[] = [];
  for (const row of (claim?.claimed ?? []) as any[]) {
    const which = envOf(row.env);
    const creds = readCreds(deps.env, which);
    if (!creds || !notifyBase) {
      processed.push({ refund_id: row.refund_id, result: "not_configured" });
      continue;
    }
    const result = await processRefund(new VismaApi(creds, deps.fetch), deps.db, row, `${notifyBase}/vismapay-notify`);
    processed.push({ refund_id: row.refund_id, result: result.result, detail: result.detail });
  }
  return jsonResponse({ ok: true, mode, processed }, 200, cors);
}
