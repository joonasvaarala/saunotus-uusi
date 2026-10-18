// mobilepay-start: luo Vipps MobilePay -maksun tilaukselle ja palauttaa ohjausosoitteen (WEB_REDIRECT).
// POST {order_token} (tilaussivu) tai {link_token} (maksulinkki) -> {ok, redirect_url, reference}; GET ?p=<link_token> -> 302 Vippsiin.
import { buildReturnUrl, CORS_HEADERS, dbError, type Db, type Env, type Fetch, httpForCode, jsonResponse, type Mode, MobilePayApi, readCreds, UUID_RE, VippsError } from "../_shared/mobilepay.ts";
import { finnishMobileMsisdn } from "../_shared/phone-fi.ts";

import { makeT, type TFn } from "../_shared/site_texts.ts";
import { MOBILEPAY_START_TEXTS } from "./texts.ts";

/** texts: tekstihaku (index.ts: tietokanta → oletus); puuttuessa repon oletukset */
export type Deps = { db: Db; env: Env; fetch: Fetch; texts?: TFn };
const DEFAULT_TEXTS: TFn = makeT(MOBILEPAY_START_TEXTS);

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const res = await handleJson(req, deps);
  if (req.method !== "GET") return res;
  // GET (maksulinkki): onnistuessa 302 Vippsiin, muuten yksinkertainen virhesivu
  const body = await res.clone().json().catch(() => null);
  if (body?.ok && body.redirect_url) return new Response(null, { status: 302, headers: { location: body.redirect_url, "cache-control": "no-store" } });
  const msg = String(body?.message ?? (deps.texts ?? DEFAULT_TEXTS)("ui.mobilepay.start_error_default", "fi")).replace(/[<>&]/g, "");
  return new Response(`<!doctype html><meta charset="utf-8"><title>MobilePay</title><p>${msg}</p>`, { status: res.status, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
}

async function handleJson(req: Request, deps: Deps): Promise<Response> {
  const cors = CORS_HEADERS(req.headers.get("origin"), deps.env.get("MOBILEPAY_ALLOWED_ORIGINS"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  const respond = (o: unknown, s = 200) => jsonResponse(o, s, cors);
  const tx = (key: string) => (deps.texts ?? DEFAULT_TEXTS)(key, "fi");   // asiakasnäkyvä virheteksti (§18)

  let orderToken: string | null = null, linkToken: string | null = null;
  let userFlow: "WEB_REDIRECT" | "QR" | "PUSH_MESSAGE" = "WEB_REDIRECT";
  let phone: string | null = null;
  if (req.method === "GET") linkToken = new URL(req.url).searchParams.get("p");
  else if (req.method === "POST") {
    let b: any = null; try { b = await req.json(); } catch { /* tyhjä */ }
    orderToken = typeof b?.order_token === "string" ? b.order_token : null; linkToken = typeof b?.link_token === "string" ? b.link_token : null;
    const rawFlow = typeof b?.user_flow === "string" ? b.user_flow : "WEB_REDIRECT";
    if (rawFlow !== "WEB_REDIRECT" && rawFlow !== "QR" && rawFlow !== "PUSH_MESSAGE") return respond({ ok: false, code: "invalid_param", message: tx("ui.mobilepay.start_error_invalid_param") }, 400);
    userFlow = rawFlow;
    if (userFlow === "PUSH_MESSAGE") {
      phone = finnishMobileMsisdn(b?.phone);
      if (!phone) return respond({ ok: false, code: "invalid_phone", message: tx("ui.mobilepay.start_error_invalid_phone") }, 400);
    }
  } else return respond({ ok: false, code: "method_not_allowed" }, 405);
  if ((orderToken && !UUID_RE.test(orderToken)) || (linkToken && !UUID_RE.test(linkToken)) || (!orderToken && !linkToken) || (orderToken && linkToken)) return respond({ ok: false, code: "invalid_param", message: tx("ui.mobilepay.start_error_invalid_param") }, 400);
  if (userFlow !== "WEB_REDIRECT" && !orderToken) return respond({ ok: false, code: "invalid_param", message: tx("ui.mobilepay.start_error_invalid_param") }, 400);

  const mode: Mode = await deps.db.mode();
  if (mode === "off") return respond({ ok: false, code: "mobilepay_off", message: tx("ui.mobilepay.start_error_off") }, 503);
  const creds = readCreds(deps.env);
  if (!creds) return respond({ ok: false, code: "not_configured", message: tx("ui.mobilepay.start_error_unavailable") }, 503);
  const api = new MobilePayApi(mode, creds, deps.fetch);

  const expires = userFlow === "WEB_REDIRECT" ? 120 : 20;
  const { data: prep, error } = await deps.db.rpc("mobilepay_payment_prepare", { p_order_token: orderToken, p_link_token: linkToken, p_expires_minutes: expires, p_user_flow: userFlow });
  if (error) { const e = dbError(error)!; return respond({ ok: false, code: e.code, message: e.message }, httpForCode(e.code)); }
  const reuseUrl = prep.redirect_url || null;
  if (prep.reuse) {
    if (userFlow === "PUSH_MESSAGE") return respond({ ok: true, reuse: true, pushed: true, user_flow: userFlow, reference: prep.reference, payment_id: prep.payment_id });
    return respond({ ok: true, reuse: true, user_flow: userFlow, redirect_url: reuseUrl, qr_url: userFlow === "QR" ? reuseUrl : undefined, reference: prep.reference, payment_id: prep.payment_id });
  }

  const returnUrl = buildReturnUrl(prep.site_base_url, prep.order_page_path, prep.order_token);
  const fail = async (detail: unknown, code: string, status: number, message: string) => {
    await deps.db.rpc("mobilepay_payment_event", { p_reference: prep.reference, p_state: "create_failed", p_redirect_url: null, p_detail: detail });
    return respond({ ok: false, code, message }, status);
  };
  if (userFlow === "WEB_REDIRECT" && !returnUrl) return await fail({ reason: "site_base_url_missing_or_not_https" }, "not_configured", 503, tx("ui.mobilepay.start_error_unavailable"));

  try {
    const created = await api.createPayment({ reference: prep.reference, amountMinor: prep.amount_minor, currency: prep.currency, returnUrl, description: prep.description, userFlow, phoneNumber: phone ?? undefined });
    const redirectUrl = created?.redirectUrl || created?.url || null;
    if (userFlow !== "PUSH_MESSAGE" && !redirectUrl) return await fail({ reason: "no_redirect_url" }, "provider_error", 502, tx("ui.mobilepay.start_error_provider"));
    await deps.db.rpc("mobilepay_payment_event", { p_reference: prep.reference, p_state: "CREATED", p_redirect_url: redirectUrl, p_detail: userFlow === "WEB_REDIRECT" ? null : { user_flow: userFlow } });
    for (const old of (prep.superseded ?? []) as string[]) { try { await api.cancel(old); } catch { /* vanhentuu itsestään; notify siivoaa */ } }
    if (userFlow === "PUSH_MESSAGE") return respond({ ok: true, reuse: false, pushed: true, user_flow: userFlow, redirect_url: redirectUrl, reference: prep.reference, payment_id: prep.payment_id });
    return respond({ ok: true, reuse: false, user_flow: userFlow, redirect_url: redirectUrl, qr_url: userFlow === "QR" ? redirectUrl : undefined, reference: prep.reference, payment_id: prep.payment_id });
  } catch (e) {
    if (e instanceof VippsError) return await fail(e.summary(), "provider_error", e.transient ? 503 : 502, tx("ui.mobilepay.start_error_provider_retry"));
    throw e;
  }
}
