// montonio-notify: palvelinilmoitus (orderToken / refundToken) ja tilaussivun tilatarkistus (POST reconcile).
// Maksetuksi ei merkitä ilman varmennettua HS256-tokenia, täsmäävää viitettä ja summaa.
import { CORS_HEADERS, dbError, type Db, type Env, type Fetch, jsonResponse, UUID_RE } from "../_shared/mobilepay.ts";
import { applyRefundStatus, applyVerified, settleFromApi } from "../_shared/montonio_flow.ts";
import { PayApi, readCreds, resolveHost, verifyJwt } from "../_shared/montonio.ts";

export type Deps = { db: Db; env: Env; fetch: Fetch };

const text = (status: number, body: string) => new Response(body, { status, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const cors = CORS_HEADERS(req.headers.get("origin"), deps.env.get("MONTONIO_ALLOWED_ORIGINS"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return jsonResponse({ ok: false, code: "method_not_allowed" }, 405, cors);
  let b: any = null;
  try { b = await req.json(); } catch { /* tyhjä */ }
  if (b?.action === "reconcile") return reconcile(b, deps, cors);
  if (typeof b?.orderToken === "string") return orderNotify(b.orderToken, deps);
  if (typeof b?.refundToken === "string") return refundNotify(b.refundToken, deps);
  return text(400, "missing");
}

async function orderNotify(token: string, deps: Deps): Promise<Response> {
  const creds = readCreds(deps.env);
  if (!creds) return text(503, "not_configured");
  const verified = await verifyJwt(token, creds.secretKey);
  if (!verified.ok) return text(401, "bad_signature");
  const ref = String(verified.payload.merchantReference || "");
  if (!/^sauna-[a-z0-9_-]+$/i.test(ref)) return text(400, "order");
  const { data, error } = await deps.db.rpc("montonio_payment_lookup", { p_order_number: ref });
  if (error) return text(503, "retry");
  if (!data?.found) return text(200, "ignored");
  const applied = await applyVerified(deps.db, verified.payload, {
    accessKey: creds.accessKey,
    merchantReference: ref,
    amount: Number(data.amount),
    orderUuid: data.order_uuid ?? null,
  });
  return text(applied.http, applied.http === 200 ? "OK" : "retry");
}

async function refundNotify(token: string, deps: Deps): Promise<Response> {
  const creds = readCreds(deps.env);
  if (!creds) return text(503, "not_configured");
  const verified = await verifyJwt(token, creds.secretKey);
  if (!verified.ok) return text(401, "bad_signature");
  if (verified.payload.accessKey !== creds.accessKey) return text(200, "ignored");
  const refundUuid = String(verified.payload.refundUuid || verified.payload.uuid || "");
  const orderUuid = String(verified.payload.orderUuid || "");
  const { data, error } = await deps.db.rpc("montonio_refund_lookup", { p_provider_refund_id: refundUuid || null, p_order_uuid: orderUuid || null });
  if (error) return text(503, "retry");
  if (!data?.found) return text(503, "retry");
  const result = await applyRefundStatus(deps.db, {
    refund_id: data.refund_id,
    amount: Number(data.amount),
    order_uuid: data.order_uuid,
    provider_refund_id: data.provider_refund_id,
  }, verified.payload);
  if (result.result === "db_error" || result.result === "retry_later") return text(503, "retry");
  return text(200, "OK");
}

async function reconcile(b: any, deps: Deps, cors: Record<string, string>): Promise<Response> {
  if (typeof b?.order_token !== "string" || !UUID_RE.test(b.order_token)) return jsonResponse({ ok: false, code: "invalid_param" }, 400, cors);
  const { data, error } = await deps.db.rpc("montonio_order_refs", { p_order_token: b.order_token });
  if (error) return jsonResponse({ ok: false, code: dbError(error)!.code }, 500, cors);
  if (!data?.ok) return jsonResponse({ ok: false, code: data?.code || "not_found" }, data?.code === "rate_limited" ? 429 : 404, cors);
  const creds = readCreds(deps.env);
  const mode = await deps.db.mode();
  const host = creds ? resolveHost(mode, deps.env) : { ok: false as const, code: "off" };
  const results: { order_number: string; outcome: string }[] = [];
  for (const ref of (data.refs ?? []) as any[]) {
    const orderNumber = String(ref.order_number || "");
    if (!/^sauna-[a-z0-9_-]+$/i.test(orderNumber)) continue;
    if (!creds || !host.ok) { results.push({ order_number: orderNumber, outcome: "not_configured" }); continue; }
    const api = new PayApi(creds.accessKey, creds.secretKey, host.base, deps.fetch);
    const settled = await settleFromApi(api, deps.db, { order_number: orderNumber, amount: Number(ref.amount), order_uuid: ref.order_uuid }, creds.accessKey);
    results.push({ order_number: orderNumber, outcome: settled.outcome });
  }
  const paid = results.some((r) => r.outcome === "paid");
  return jsonResponse({ ok: true, payment_status: paid ? "paid" : (data.payment_status ?? null), results }, 200, cors);
}
