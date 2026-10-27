// montonio-start: luo verkkomaksun (Orders API) ja palauttaa ohjausosoitteen.
// Asiakkaalle näkyviin viesteihin ei kirjoiteta välittäjän nimeä.
// POST {order_token|link_token, method}; GET ?p=<link_token>&method= ohjaa (302).
import { CORS_HEADERS, dbError, type Db, type Env, type Fetch, jsonResponse, UUID_RE } from "../_shared/mobilepay.ts";
import { functionBase, isMethod, PayApi, PayError, readCreds, resolveHost, safePaymentUrl, type PayMethod } from "../_shared/montonio.ts";

export type Deps = { db: Db; env?: Env; fetch?: Fetch; now?: () => number };

const HTTP: Record<string, number> = {
  not_found: 404, rate_limited: 429, invalid_param: 400, already_paid: 409, nothing_to_pay: 409,
  order_not_payable: 409, payment_not_pending: 409, link_expired: 410, link_stale: 409,
  other_provider_started: 409, unsupported_currency: 400, payment_in_progress: 409,
  not_configured: 503, provider_error: 502, maintenance: 503, online_off: 501, mode_mismatch: 503,
};

function httpFor(code: string): number {
  return HTTP[code] ?? 500;
}

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const cors = CORS_HEADERS(req.headers.get("origin"), deps.env?.get("MONTONIO_ALLOWED_ORIGINS"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  const respond = (o: unknown, s = 200) => jsonResponse(o, s, cors);

  let orderToken: string | null = null, linkToken: string | null = null, methodRaw: unknown = null;
  if (req.method === "GET") {
    const u = new URL(req.url);
    linkToken = u.searchParams.get("p");
    methodRaw = u.searchParams.get("method");
  } else if (req.method === "POST") {
    let b: any = null;
    try { b = await req.json(); } catch { /* tyhjä */ }
    orderToken = typeof b?.order_token === "string" ? b.order_token : null;
    linkToken = typeof b?.link_token === "string" ? b.link_token : null;
    methodRaw = b?.method;
  } else return respond({ ok: false, code: "method_not_allowed" }, 405);
  if ((orderToken && !UUID_RE.test(orderToken)) || (linkToken && !UUID_RE.test(linkToken)) || (!orderToken && !linkToken) || (orderToken && linkToken)) {
    return respond({ ok: false, code: "invalid_param", message: "Virheellinen pyyntö" }, 400);
  }
  if (!isMethod(methodRaw)) return respond({ ok: false, code: "invalid_param", message: "Valitse maksutapa." }, 400);
  const method: PayMethod = methodRaw;

  const { data, error } = await deps.db.rpc("montonio_payment_prepare", { p_order_token: orderToken, p_link_token: linkToken, p_method: method });
  if (error) {
    const e = dbError(error)!;
    return respond({ ok: false, code: e.code, message: e.message }, httpFor(e.code));
  }
  if (!data || data.ok === false) {
    const code = data?.code || "online_off";
    return respond({ ok: false, code, mode: data?.mode ?? null, message: "Verkkomaksu ei ole käytössä" }, httpFor(code));
  }
  if (data.dry_run === true || data.mode === "dry_run") {
    return respond({
      ok: true, mode: "dry_run", dry_run: true,
      payment_id: data.payment_id, amount: data.amount, order_no: data.order_no,
      reference: data.order_number, message: "Verkkomaksu on testitilassa. Maksua ei veloiteta.",
    });
  }

  const mode = data.mode === "live" ? "live" : data.mode === "test" ? "test" : null;
  if (!mode) return respond({ ok: false, code: "online_off", message: "Verkkomaksu ei ole käytössä" }, 501);
  if (!deps.env || !deps.fetch) return respond({ ok: false, code: "not_configured", mode, message: "Verkkomaksu ei ole juuri nyt käytettävissä." }, 503);
  const host = resolveHost(mode, deps.env);
  if (!host.ok) return respond({ ok: false, code: host.code, mode, message: "Verkkomaksu ei ole juuri nyt käytettävissä." }, 503);
  const creds = readCreds(deps.env);
  if (!creds) return respond({ ok: false, code: "not_configured", mode, message: "Verkkomaksu ei ole juuri nyt käytettävissä." }, 503);

  const reused = safePaymentUrl(data.redirect_url);
  if (data.reuse && reused) {
    return respond({ ok: true, mode, reuse: true, redirect_url: reused, reference: data.order_number, payment_id: data.payment_id, amount: data.amount });
  }

  const base = functionBase(deps.env);
  if (!base) return respond({ ok: false, code: "not_configured", mode, message: "Verkkomaksu ei ole juuri nyt käytettävissä." }, 503);
  const api = new PayApi(creds.accessKey, creds.secretKey, host.base, deps.fetch, deps.now);
  const description = `Tilaus ${data.order_no ?? ""}`.trim();
  const fail = async (detail: unknown, status: number) => {
    await deps.db.rpc("montonio_payment_event", {
      p_order_number: data.order_number, p_state: "create_failed", p_redirect_url: null, p_order_uuid: null, p_detail: detail,
    });
    return respond({ ok: false, code: "provider_error", mode, message: "Verkkomaksua ei voitu aloittaa. Yritä hetken kuluttua uudelleen." }, status);
  };
  try {
    const created = await api.createOrder({
      merchantReference: data.order_number,
      amount: Number(data.amount),
      currency: data.currency || "EUR",
      locale: data.locale === "en" || data.locale === "sv" ? data.locale : "fi",
      returnUrl: `${base}/montonio-return`,
      notificationUrl: `${base}/montonio-notify`,
      method,
      description,
    });
    const redirect = safePaymentUrl(created?.paymentUrl);
    if (!redirect) return await fail({ reason: "bad_payment_url" }, 502);
    await deps.db.rpc("montonio_payment_event", {
      p_order_number: data.order_number, p_state: "CREATED", p_redirect_url: redirect, p_order_uuid: created.uuid ?? null,
      p_detail: { method, env: host.env },
    });
    return respond({ ok: true, mode, reuse: false, redirect_url: redirect, reference: data.order_number, payment_id: data.payment_id, amount: data.amount });
  } catch (e) {
    if (e instanceof PayError) return await fail(e.summary(), e.transient ? 503 : 502);
    throw e;
  }
}

/** GET ?p= maksulinkki: onnistunut JSON → 302. Muuten lyhyt HTML ilman välittäjän nimeä. */
export async function asRedirect(req: Request, res: Response): Promise<Response> {
  if (req.method !== "GET") return res;
  const body = await res.clone().json().catch(() => null);
  if (body?.ok && safePaymentUrl(body.redirect_url)) {
    return new Response(null, { status: 302, headers: { location: body.redirect_url, "cache-control": "no-store" } });
  }
  const msg = String(body?.message ?? "Maksua ei voitu aloittaa").replace(/[<>&]/g, "");
  return new Response(`<!doctype html><meta charset="utf-8"><title>Verkkomaksu</title><p>${msg}</p>`, {
    status: res.status, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
  });
}
