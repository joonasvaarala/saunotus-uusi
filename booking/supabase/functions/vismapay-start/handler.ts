// vismapay-start: kylmälaite- ja kassatilauksen Visma Pay -valmistelu.
// live-tilaa ei kutsuta (ei tunnuksia, ei HTTP:tä Vismaan). dry_run luo pending-maksun RPC:llä eikä merkitse maksetuksi.
// off palauttaa vismapay_off. Vanha 501-runko korvattiin tällä; tuotannon ohjausosoite on avoin asia.
import { CORS_HEADERS, dbError, type Db, httpForCode, jsonResponse, UUID_RE } from "../_shared/mobilepay.ts";

export type Deps = { db: Db };

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const cors = CORS_HEADERS(req.headers.get("origin"), undefined);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  const respond = (o: unknown, s = 200) => jsonResponse(o, s, cors);
  if (req.method !== "POST") return respond({ ok: false, code: "method_not_allowed" }, 405);
  let b: any = null;
  try { b = await req.json(); } catch { /* tyhjä */ }
  const orderToken = typeof b?.order_token === "string" ? b.order_token : "";
  if (!UUID_RE.test(orderToken)) return respond({ ok: false, code: "invalid_param", message: "Virheellinen pyyntö" }, 400);
  const { data, error } = await deps.db.rpc("vismapay_payment_prepare", { p_order_token: orderToken });
  if (error) {
    const e = dbError(error)!;
    return respond({ ok: false, code: e.code, message: e.message }, httpForCode(e.code));
  }
  if (!data || data.ok === false) {
    const code = data?.code || "vismapay_off";
    const status = code === "vismapay_live_not_implemented" || code === "vismapay_off" ? 501 : httpForCode(code);
    return respond({ ok: false, code, mode: data?.mode ?? null, implemented: false, message: data?.message || "Verkkomaksu ei ole käytössä" }, status);
  }
  return respond({
    ok: true, mode: "dry_run", dry_run: true, implemented: false,
    payment_id: data.payment_id, provider_ref: data.provider_ref, amount: data.amount,
    order_no: data.order_no, reference: data.provider_ref, message: data.message,
  });
}
