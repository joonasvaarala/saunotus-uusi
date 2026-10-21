// vismapay-start: luo Visma Pay -maksun (auth_payment) ja palauttaa ohjausosoitteen.
// dry_run ja off eivät kutsu Vismaa (vanhat testit: ei env/fetch-riippuvuutta). test/live tekevät HTTP:n.
// POST {order_token} tai {link_token}; GET ?p=<link_token> ohjaa Vismaan (302).
import { CORS_HEADERS, dbError, type Db, type Env, type Fetch, jsonResponse, UUID_RE } from "../_shared/mobilepay.ts";
import { chargeUrl, customerPayload, functionBase, readCreds, safeChargeUrl, VismaApi, VismaError, type PayEnv } from "../_shared/vismapay.ts";

export type Deps = { db: Db; env?: Env; fetch?: Fetch; now?: () => number };

const HTTP: Record<string, number> = {
  not_found: 404, rate_limited: 429, invalid_param: 400, already_paid: 409, nothing_to_pay: 409,
  order_not_payable: 409, payment_not_pending: 409, link_expired: 410, link_stale: 409,
  other_provider_started: 409, unsupported_currency: 400, payment_in_progress: 409,
  not_configured: 503, provider_error: 502, maintenance: 503,
};

function httpFor(code: string): number {
  return HTTP[code] ?? 500;
}

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const cors = CORS_HEADERS(req.headers.get("origin"), deps.env?.get("VISMAPAY_ALLOWED_ORIGINS"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  const respond = (o: unknown, s = 200) => jsonResponse(o, s, cors);

  let orderToken: string | null = null, linkToken: string | null = null;
  if (req.method === "GET") linkToken = new URL(req.url).searchParams.get("p");
  else if (req.method === "POST") {
    let b: any = null;
    try { b = await req.json(); } catch { /* tyhjä */ }
    orderToken = typeof b?.order_token === "string" ? b.order_token : null;
    linkToken = typeof b?.link_token === "string" ? b.link_token : null;
  } else return respond({ ok: false, code: "method_not_allowed" }, 405);
  if ((orderToken && !UUID_RE.test(orderToken)) || (linkToken && !UUID_RE.test(linkToken)) || (!orderToken && !linkToken) || (orderToken && linkToken)) {
    return respond({ ok: false, code: "invalid_param", message: "Virheellinen pyyntö" }, 400);
  }

  const { data, error } = await deps.db.rpc("vismapay_payment_prepare", { p_order_token: orderToken, p_link_token: linkToken });
  if (error) {
    const e = dbError(error)!;
    return respond({ ok: false, code: e.code, message: e.message }, httpFor(e.code));
  }
  if (!data || data.ok === false) {
    const code = data?.code || "vismapay_off";
    const status = code === "vismapay_live_not_implemented" || code === "vismapay_off" ? 501 : httpFor(code);
    return respond({ ok: false, code, mode: data?.mode ?? null, implemented: false, message: data?.message || "Verkkomaksu ei ole käytössä" }, status);
  }
  if (data.dry_run === true || data.mode === "dry_run") {
    return respond({
      ok: true, mode: "dry_run", dry_run: true, implemented: false,
      payment_id: data.payment_id, provider_ref: data.provider_ref, amount: data.amount,
      order_no: data.order_no, reference: data.provider_ref, message: data.message,
    });
  }

  const mode = data.mode === "live" ? "live" : data.mode === "test" ? "test" : null;
  if (!mode) return respond({ ok: false, code: "vismapay_off", implemented: false, message: "Verkkomaksu ei ole käytössä" }, 501);
  if (!deps.env || !deps.fetch) return respond({ ok: false, code: "not_configured", mode, message: "Visma Payn avaimet puuttuvat" }, 503);
  const creds = readCreds(deps.env, mode as PayEnv);
  if (!creds) return respond({ ok: false, code: "not_configured", mode, message: "Visma Payn avaimet puuttuvat" }, 503);

  const reused = safeChargeUrl(data.redirect_url);
  if (data.reuse && reused) {
    return respond({ ok: true, mode, reuse: true, implemented: true, redirect_url: reused, reference: data.order_number, payment_id: data.payment_id, amount: data.amount });
  }

  const base = functionBase(deps.env);
  if (!base) return respond({ ok: false, code: "not_configured", mode, message: "Paluuosoitetta ei voitu muodostaa" }, 503);
  const lang = data.locale === "en" || data.locale === "sv" ? data.locale : "fi";
  const now = deps.now ? deps.now() : Date.now();
  const until = String(Math.floor(now / 1000) + 60 * 60);
  const api = new VismaApi(creds, deps.fetch);
  const fail = async (detail: unknown, status: number) => {
    await deps.db.rpc("vismapay_payment_event", { p_order_number: data.order_number, p_state: "create_failed", p_redirect_url: null, p_token: null, p_detail: detail });
    return respond({ ok: false, code: "provider_error", mode, message: "Visma Pay ei ottanut maksua vastaan. Yritä hetken kuluttua uudelleen." }, status);
  };
  try {
    const created = await api.authPayment({
      orderNumber: data.order_number,
      amountMinor: Number(data.amount_minor),
      currency: data.currency || "EUR",
      returnUrl: `${base}/vismapay-return`,
      notifyUrl: `${base}/vismapay-notify`,
      lang,
      tokenValidUntil: data.token_valid_until || until,
      customer: customerPayload(data.customer),
    });
    const result = Number(created?.result);
    if (result === 10) return respond({ ok: false, code: "maintenance", mode, message: "Visma Pay on huoltokatkolla. Yritä hetken kuluttua uudelleen." }, 503);
    if (result !== 0 || !created.token) return await fail({ result, errors: created?.errors ?? null }, result === 2 ? 409 : 502);
    const redirect = chargeUrl(created.token);
    await deps.db.rpc("vismapay_payment_event", {
      p_order_number: data.order_number, p_state: "CREATED", p_redirect_url: redirect, p_token: created.token,
      p_detail: { type: created.type ?? null, token_valid_until: data.token_valid_until || until },
    });
    return respond({ ok: true, mode, reuse: false, implemented: true, redirect_url: redirect, reference: data.order_number, payment_id: data.payment_id, amount: data.amount });
  } catch (e) {
    if (e instanceof VismaError) return await fail(e.summary(), e.transient ? 503 : 502);
    throw e;
  }
}

/** GET ?p= maksulinkki: onnistunut JSON → 302 Vismaan. Muuten lyhyt HTML, ei avointa uudelleenohjausta. */
export async function asRedirect(req: Request, res: Response): Promise<Response> {
  if (req.method !== "GET") return res;
  const body = await res.clone().json().catch(() => null);
  if (body?.ok && safeChargeUrl(body.redirect_url)) {
    return new Response(null, { status: 302, headers: { location: body.redirect_url, "cache-control": "no-store" } });
  }
  const msg = String(body?.message ?? "Maksua ei voitu aloittaa").replace(/[<>&]/g, "");
  return new Response(`<!doctype html><meta charset="utf-8"><title>Visma Pay</title><p>${msg}</p>`, {
    status: res.status, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
  });
}
