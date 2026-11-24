// montonio-refund: hallinnan hyvitys. Kuitti syntyy vasta SUCCESSFUL-ilmoituksesta, ei tästä pyynnöstä.
// Vaatii payments.refund, bookings.manage tai admin-roolin, service role -avaimen tai portin varmentaman service_role-JWT:n.
// booking_343: {action:"status", refund_id} = hyvityksen tila Montoniosta VAIN LUKUNA (GET /orders/:uuid). Ei luo hyvitystä eikä kirjoita kantaan.
import { CORS_HEADERS, dbError, type Db, type Env, type Fetch, jsonResponse } from "../_shared/mobilepay.ts";
import { processRefund, refundStatusFromApi } from "../_shared/montonio_flow.ts";
import { PayApi, readCreds, resolveHost } from "../_shared/montonio.ts";

export type Deps = { db: Db; env: Env; fetch: Fetch; authorize: (req: Request) => Promise<boolean> };

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const cors = CORS_HEADERS(req.headers.get("origin"), deps.env.get("MONTONIO_ALLOWED_ORIGINS"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return jsonResponse({ ok: false, code: "method_not_allowed" }, 405, cors);
  if (!(await deps.authorize(req))) return jsonResponse({ ok: false, code: "forbidden", message: "Hyvitys vaatii oikeuden payments.refund." }, 403, cors);

  let b: any = null;
  try { b = await req.json(); } catch { /* tyhjä */ }
  const refundId = Number.isInteger(b?.refund_id) && b.refund_id > 0 ? b.refund_id : null;
  if (b?.action === "status") return statusQuery(refundId, deps, cors);
  const mode = await deps.db.mode();
  if (mode !== "test" && mode !== "live") return jsonResponse({ ok: true, mode, processed: [] }, 200, cors);
  const creds = readCreds(deps.env);
  const host = creds ? resolveHost(mode, deps.env) : null;

  const { data: claim, error } = await deps.db.rpc("montonio_refund_claim", { p_refund_id: refundId, p_limit: 20 });
  if (error) return jsonResponse({ ok: false, code: dbError(error)!.code, message: "Hyvityksiä ei voitu varata käsittelyyn." }, 500, cors);

  const processed: { refund_id: number; result: string; detail?: unknown }[] = [];
  for (const row of (claim?.claimed ?? []) as any[]) {
    if (!creds || !host?.ok) {
      processed.push({ refund_id: row.refund_id, result: "not_configured" });
      continue;
    }
    const api = new PayApi(creds.accessKey, creds.secretKey, host.base, deps.fetch);
    const result = await processRefund(api, deps.db, row);
    processed.push({ refund_id: row.refund_id, result: result.result, detail: result.detail });
  }
  return jsonResponse({ ok: true, mode, processed }, 200, cors);
}

/** booking_343: vain luku. Ei montonio_refund_claim-, stamp- eikä complete-kutsua, ei POST-pyyntöä Montonioon. */
async function statusQuery(refundId: number | null, deps: Deps, cors: Record<string, string>): Promise<Response> {
  if (!refundId) return jsonResponse({ ok: false, code: "invalid_param", message: "refund_id puuttuu" }, 400, cors);
  const { data: info, error } = await deps.db.rpc("montonio_refund_info", { p_refund_id: refundId });
  if (error) return jsonResponse({ ok: false, code: dbError(error)!.code }, 500, cors);
  if (!info?.found) return jsonResponse({ ok: false, code: "not_found" }, 404, cors);
  const local = { refund_id: info.refund_id, status: info.status, provider_status: info.provider_status ?? null, amount: Number(info.amount), provider_refund_id: info.provider_refund_id ?? null };
  const mode = await deps.db.mode();
  if (mode !== "test" && mode !== "live") return jsonResponse({ ok: true, mode, local, montonio: null, code: "off" }, 200, cors);
  const creds = readCreds(deps.env);
  const host = creds ? resolveHost(mode, deps.env) : null;
  if (!creds || !host?.ok) return jsonResponse({ ok: true, mode, local, montonio: null, code: "not_configured" }, 200, cors);
  const api = new PayApi(creds.accessKey, creds.secretKey, host.base, deps.fetch);
  const got = await refundStatusFromApi(api, info);
  return jsonResponse({ ok: true, mode, local, montonio: got }, 200, cors);
}
