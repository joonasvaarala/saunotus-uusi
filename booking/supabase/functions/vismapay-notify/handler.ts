// vismapay-notify: Visma Payn palvelinilmoitus (GET, MAC) ja tilaussivun tilatarkistus (POST reconcile).
// Maksetuksi ei merkitä pelkän queryn perusteella: MAC + get_payment/check_payment_status.
import { CORS_HEADERS, dbError, type Db, type Env, type Fetch, jsonResponse, UUID_RE } from "../_shared/mobilepay.ts";
import { envOf, settleOrder } from "../_shared/vismapay_flow.ts";
import { functionBase, macMatches, ORDER_NUMBER_RE, readCreds, refundMacMessage, returnMacMessage, VismaApi, type PayEnv } from "../_shared/vismapay.ts";

export type Deps = { db: Db; env: Env; fetch: Fetch };

const text = (status: number, body: string) => new Response(body, { status, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });

function qOf(req: Request): Record<string, string> {
  const u = new URL(req.url);
  const out: Record<string, string> = {};
  for (const [k, v] of u.searchParams.entries()) out[k] = v;
  return out;
}

async function credsFor(env: Env, which: PayEnv) {
  return readCreds(env, which);
}

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const cors = CORS_HEADERS(req.headers.get("origin"), deps.env.get("VISMAPAY_ALLOWED_ORIGINS"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method === "GET") return handleGet(req, deps);
  if (req.method === "POST") return handlePost(req, deps, cors);
  return jsonResponse({ ok: false, code: "method_not_allowed" }, 405, cors);
}

async function handleGet(req: Request, deps: Deps): Promise<Response> {
  const q = qOf(req);
  if (q.REFUND_ID) return refundNotify(deps, q);
  if (q.ORDER_NUMBER) return paymentNotify(deps, q);
  return text(400, "missing");
}

async function paymentNotify(deps: Deps, q: Record<string, string>): Promise<Response> {
  const orderNumber = q.ORDER_NUMBER || "";
  if (!ORDER_NUMBER_RE.test(orderNumber)) return text(400, "order");
  const { data, error } = await deps.db.rpc("vismapay_payment_lookup", { p_order_number: orderNumber });
  if (error) return text(503, "retry");
  if (!data?.found) return text(200, "ignored");
  const creds = await credsFor(deps.env, envOf(data.env));
  if (!creds) return text(503, "not_configured");
  const ok = await macMatches(creds.privateKey, returnMacMessage(q), q.AUTHCODE);
  if (!ok) return text(401, "bad_signature");
  const settled = await settleOrder(new VismaApi(creds, deps.fetch), deps.db, orderNumber);
  return text(settled.http, settled.http === 200 ? "OK" : "retry");
}

async function refundNotify(deps: Deps, q: Record<string, string>): Promise<Response> {
  const refundId = String(q.REFUND_ID || "");
  if (!/^\d{1,18}$/.test(refundId)) return text(400, "refund");
  const { data, error } = await deps.db.rpc("vismapay_refund_lookup", { p_provider_refund_id: refundId });
  if (error) return text(503, "retry");
  if (!data?.found) return text(200, "ignored");
  const creds = await credsFor(deps.env, envOf(data.env));
  if (!creds) return text(503, "not_configured");
  const ok = await macMatches(creds.privateKey, refundMacMessage(q.RETURN_CODE || "", refundId), q.AUTHCODE);
  if (!ok) return text(401, "bad_signature");
  if (q.RETURN_CODE === "0") {
    const { error: ce } = await deps.db.rpc("vismapay_refund_complete", { p_refund_id: data.refund_id, p_provider_refund_id: refundId, p_raw: { notify: "accepted" } });
    if (ce) return text(503, "retry");
    return text(200, "OK");
  }
  if (q.RETURN_CODE === "1") {
    await deps.db.rpc("vismapay_refund_fail", { p_refund_id: data.refund_id, p_error: { notify: "rejected" } });
    return text(200, "OK");
  }
  return text(200, "OK");
}

async function handlePost(req: Request, deps: Deps, cors: Record<string, string>): Promise<Response> {
  let b: any = null;
  try { b = await req.json(); } catch { /* tyhjä */ }
  if (b?.action !== "reconcile" || typeof b?.order_token !== "string" || !UUID_RE.test(b.order_token)) {
    return jsonResponse({ ok: false, code: "invalid_param" }, 400, cors);
  }
  const { data, error } = await deps.db.rpc("vismapay_order_refs", { p_order_token: b.order_token });
  if (error) return jsonResponse({ ok: false, code: dbError(error)!.code }, 500, cors);
  if (!data?.ok) return jsonResponse({ ok: false, code: data?.code || "not_found" }, data?.code === "rate_limited" ? 429 : 404, cors);
  const results: { order_number: string; outcome: string }[] = [];
  for (const ref of (data.refs ?? []) as any[]) {
    const orderNumber = String(ref.order_number || "");
    if (!ORDER_NUMBER_RE.test(orderNumber)) continue;
    const creds = readCreds(deps.env, envOf(ref.env));
    if (!creds) { results.push({ order_number: orderNumber, outcome: "not_configured" }); continue; }
    const settled = await settleOrder(new VismaApi(creds, deps.fetch), deps.db, orderNumber);
    results.push({ order_number: orderNumber, outcome: settled.outcome });
  }
  const paid = results.some((r) => r.outcome === "paid");
  return jsonResponse({ ok: true, payment_status: paid ? "paid" : (data.payment_status ?? null), results }, 200, cors);
}

export { functionBase };
