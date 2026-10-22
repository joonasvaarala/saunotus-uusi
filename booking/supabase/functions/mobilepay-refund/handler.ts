// mobilepay-refund: käsittelee booking.refunds-rivit (provider='mobilepay', status='requested' / 10 min jumissa ollut 'processing').
// Auth: verify_jwt=true (portin tarkistus) + funktiossa vaaditaan henkilökunnan oikeus payments.refund (booking.has_permission), service role -avain tai portin varmentama service_role-JWT (cron/huolto).
// POST {} = kaikki odottavat, POST {refund_id} = yksittäinen. Vipps: POST /epayment/v1/payments/{reference}/refund (Idempotency-Key = sauna-refund-<id>).
import { CORS_HEADERS, dbError, type Db, type Env, type Fetch, jsonResponse, type Mode, MobilePayApi, readCreds, VippsError, aggVal } from "../_shared/mobilepay.ts";

export type Deps = { db: Db; env: Env; fetch: Fetch; authorize: (req: Request) => Promise<boolean> };

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const cors = CORS_HEADERS(req.headers.get("origin"), deps.env.get("MOBILEPAY_ALLOWED_ORIGINS"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return jsonResponse({ ok: false, code: "method_not_allowed" }, 405, cors);
  if (!(await deps.authorize(req))) return jsonResponse({ ok: false, code: "forbidden" }, 403, cors);

  let b: any = null; try { b = await req.json(); } catch { /* tyhjä */ }
  const refundId = Number.isInteger(b?.refund_id) && b.refund_id > 0 ? b.refund_id : null;

  const mode: Mode = await deps.db.mode();
  if (mode === "off") return jsonResponse({ ok: true, mode: "off", processed: [] }, 200, cors);
  const creds = readCreds(deps.env);
  if (!creds) return jsonResponse({ ok: false, code: "not_configured" }, 503, cors);
  const api = new MobilePayApi(mode, creds, deps.fetch);

  const { data: claim, error } = await deps.db.rpc("mobilepay_refund_claim", { p_refund_id: refundId, p_limit: 20 });
  if (error) return jsonResponse({ ok: false, code: dbError(error)!.code }, 500, cors);

  const processed: { refund_id: number; result: string; detail?: unknown }[] = [];
  for (const r of (claim?.claimed ?? []) as any[]) {
    const fail = async (error: unknown, result = "failed") => { await deps.db.rpc("mobilepay_refund_fail", { p_refund_id: r.refund_id, p_error: error }); processed.push({ refund_id: r.refund_id, result, detail: error }); };
    if (!r.reference) { await fail({ reason: "no_provider_ref" }); continue; }
    try {
      const res = await api.refund(r.reference, r.amount_minor, r.currency, `sauna-refund-${r.refund_id}`);
      // varmistus: Vippsin kokonaishyvitys kattaa aiemmat + tämän (uusinta samalla avaimella palauttaa saman vastauksen)
      let refunded = aggVal(res, "refundedAmount");
      if (refunded < Number(r.refunded_minor) + Number(r.amount_minor)) refunded = aggVal(await api.getPayment(r.reference), "refundedAmount");
      if (refunded < Number(r.refunded_minor) + Number(r.amount_minor)) { await fail({ reason: "refund_unverified", refunded }, "unverified"); continue; }
      const { error: ce } = await deps.db.rpc("mobilepay_refund_complete", { p_refund_id: r.refund_id, p_provider_refund_id: `${r.reference}#${r.refund_id}`, p_raw: { aggregate_refunded: refunded, state: res.state ?? null } });
      if (ce) { processed.push({ refund_id: r.refund_id, result: "db_error", detail: dbError(ce)!.code }); continue; }   // jää processing -> uusinta (idempotentti)
      processed.push({ refund_id: r.refund_id, result: "done" });
    } catch (e) {
      if (e instanceof VippsError && !e.transient) await fail(e.summary());
      else processed.push({ refund_id: r.refund_id, result: "retry_later" });   // tilapäinen: rivi jää processing -> otetaan uudelleen 10 min kuluttua (tai heti kutsulla refund_id)
    }
  }
  return jsonResponse({ ok: true, mode, processed }, 200, cors);
}
