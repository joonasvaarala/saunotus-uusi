// mobilepay-notify: (1) Vippsin webhook (allekirjoitus tarkistetaan; tila haetaan aina GET /payments/{reference}),
//                   (2) tilaussivun reconcile: POST {action:"reconcile", order_token} (asiakkaan paluu Vippsistä; ei allekirjoitusta, käsittelee vain tilauksen omat keskeneräiset viitteet).
// Maksu merkitään maksetuksi vasta onnistuneen capturen jälkeen (ks. _shared/mobilepay_flow.ts).
import { CORS_HEADERS, dbError, type Db, type Env, type Fetch, jsonResponse, type Mode, MobilePayApi, readCreds, UUID_RE, verifyWebhook, VippsError } from "../_shared/mobilepay.ts";
import { DbFailure, processReference, type Outcome } from "../_shared/mobilepay_flow.ts";

export type Deps = { db: Db; env: Env; fetch: Fetch };
const REF_RE = /^sauna-o[0-9]+-p[0-9]+-a[0-9]+$/;

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const cors = CORS_HEADERS(req.headers.get("origin"), deps.env.get("MOBILEPAY_ALLOWED_ORIGINS"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return jsonResponse({ ok: false, code: "method_not_allowed" }, 405, cors);

  const raw = new Uint8Array(await req.arrayBuffer());
  const isWebhook = req.headers.has("x-ms-content-sha256") || req.headers.has("x-ms-date");

  const mode: Mode = await deps.db.mode();
  const creds = readCreds(deps.env);

  if (isWebhook) {
    const secret = deps.env.get("MOBILEPAY_WEBHOOK_SECRET");
    if (!secret) return jsonResponse({ ok: false, code: "not_configured" }, 503);
    const u = new URL(req.url);
    const registered = deps.env.get("MOBILEPAY_WEBHOOK_URL");
    const regUrl = registered ? new URL(registered) : null;
    const supaHost = (() => { try { return new URL(deps.env.get("SUPABASE_URL") ?? "").host; } catch { return ""; } })();
    const okSig = await verifyWebhook({
      secret, headers: req.headers, rawBody: raw,
      pathCandidates: [u.pathname + u.search, "/functions/v1/mobilepay-notify" + u.search, "/mobilepay-notify" + u.search, regUrl ? regUrl.pathname + regUrl.search : ""],
      hostCandidates: [req.headers.get("host") ?? "", req.headers.get("x-forwarded-host") ?? "", u.host, supaHost, regUrl?.host ?? ""],
    });
    if (!okSig) return jsonResponse({ ok: false, code: "bad_signature" }, 401);
    if (mode === "off") return jsonResponse({ ok: true, ignored: "off" });
    if (!creds) return jsonResponse({ ok: false, code: "not_configured" }, 503);   // Vipps yrittää uudelleen
    let body: any = null; try { body = JSON.parse(new TextDecoder().decode(raw)); } catch { /* ei JSON */ }
    const ref = typeof body?.reference === "string" ? body.reference : null;
    if (!ref || !REF_RE.test(ref)) return jsonResponse({ ok: true, ignored: "no_reference" });   // ei meidän viite: vastataan 200, ettei Vipps yritä loputtomiin
    const api = new MobilePayApi(mode, creds, deps.fetch);
    try { return jsonResponse({ ok: true, ...(await processReference(ref, { db: deps.db, api })) }); }
    catch (e) { return failure(e); }
  }

  // --- reconcile (selaimesta) ---
  let b: any = null; try { b = JSON.parse(new TextDecoder().decode(raw)); } catch { /* tyhjä */ }
  if (b?.action !== "reconcile" || typeof b?.order_token !== "string" || !UUID_RE.test(b.order_token)) return jsonResponse({ ok: false, code: "invalid_param" }, 400, cors);
  if (mode === "off") return jsonResponse({ ok: false, code: "mobilepay_off" }, 503, cors);
  if (!creds) return jsonResponse({ ok: false, code: "not_configured" }, 503, cors);
  const { data: refs, error } = await deps.db.rpc("mobilepay_order_refs", { p_order_token: b.order_token });
  if (error) { const e = dbError(error)!; return jsonResponse({ ok: false, code: e.code }, 500, cors); }
  if (!refs?.ok) return jsonResponse({ ok: false, code: refs?.code ?? "not_found" }, refs?.code === "rate_limited" ? 429 : 404, cors);
  const api = new MobilePayApi(mode, creds, deps.fetch);
  const results: Outcome[] = [];
  for (const ref of ((refs.refs ?? []) as string[]).slice(0, 3)) {
    try { results.push(await processReference(ref, { db: deps.db, api })); }
    catch (e) { results.push({ reference: ref, outcome: "error", detail: e instanceof VippsError ? e.summary().status : "internal" }); console.error("mobilepay-notify reconcile", (e as Error).message); }
  }
  return jsonResponse({ ok: true, payment_status: refs.payment_status, results: results.map((r) => ({ outcome: r.outcome, state: r.state })) }, 200, cors);
}

function failure(e: unknown) {
  // Tilapäinen virhe -> 5xx, jolloin Vipps toistaa webhookin; pysyvä tietokantavirhe kirjataan lokiin (ilman henkilötietoja)
  if (e instanceof VippsError) { console.error("mobilepay-notify vipps", JSON.stringify(e.summary())); return jsonResponse({ ok: false, code: e.transient ? "provider_unavailable" : "provider_error" }, e.transient ? 503 : 500); }
  if (e instanceof DbFailure) { console.error("mobilepay-notify db", e.fn, e.info.code); return jsonResponse({ ok: false, code: "db_error", fn: e.fn, error: e.info.code }, 500); }
  console.error("mobilepay-notify", (e as Error).message);
  return jsonResponse({ ok: false, code: "internal_error" }, 500);
}
