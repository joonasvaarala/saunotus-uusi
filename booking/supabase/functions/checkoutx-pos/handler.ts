// checkoutx-pos: Pikakassan kortti puhelimella (CheckoutX / Surfboard demo). booking_286.
// Selain (hallinta, käyttäjän JWT) → tämä funktio → Surfboard API. Avaimet vain täällä (Edge-salaisuudet).
// Toiminnot (POST JSON, action):
//   start {order_id, terminal_id, return?}      pos.use        – luo Surfboard-tilauksen, palauttaa checkoutx://-linkin
//   status {payment_id}                         pos.use        – kysyy tilan Surfboardilta ja kirjaa maksetuksi / epäonnistuneeksi
//   cancel {payment_id}                         pos.use        – peruu Surfboard-tilauksen (jos ei ehtinyt maksua)
//   configure {return?}                         pos.use        – CheckoutX:n valmistelulinkki (PS_0025-toipuminen)
//   register_start {return?}                    settings.edit  – puhelimen liitoskoodi (120 s) ja checkoutx://register-linkki
//   register_check {registration_code, label}   settings.edit  – tallentaa terminalId:n, kun CheckoutX on liitetty
//   refund {refund_id}                          payments.refund – saman päivän koko maksun mitätöinti (void)
// Kaikki vaatii integration_config.checkoutx.mode = 'test' ja salaisuuden CHECKOUTX_ENV = 'demo'.
import { CORS_HEADERS, dbError, type Env, type Fetch, jsonResponse, type Rpc } from "../_shared/mobilepay.ts";
import {
  configureLink, CxError, envAllowed, mapOrderStatus, readConfig, registerLink, SurfboardApi, toMinor, transactionLink, validId,
} from "../_shared/checkoutx.ts";

export type Caller = { uid: string | null; service: boolean; can: (perm: string) => Promise<boolean> };
export type CxDb = { rpc: Rpc; cxMode: () => Promise<string> };
export type Deps = { db: CxDb; env?: Env; fetch?: Fetch; caller: (req: Request) => Promise<Caller | null> };

const HTTP: Record<string, number> = {
  invalid_param: 400, unauthorized: 401, forbidden: 403, not_found: 404, method_not_allowed: 405,
  checkoutx_off: 409, order_not_payable: 409, payment_in_progress: 409, nothing_to_pay: 409, payment_not_pending: 409,
  terminal_not_registered: 409, ref_conflict: 409, payment_not_started: 409, terminal_not_connected: 409,
  not_configured: 503, provider_unavailable: 503, provider_error: 502,
};
const MSG: Record<string, string> = {
  checkoutx_off: "Kortti puhelimella ei ole käytössä.",
  not_configured: "CheckoutX-tunnukset puuttuvat. Maksua ei aloitettu.",
  provider_error: "CheckoutX ei hyväksynyt maksua. Yritä uudelleen.",
  provider_unavailable: "CheckoutX ei vastaa juuri nyt. Yritä hetken kuluttua uudelleen.",
  terminal_not_connected: "Puhelimen CheckoutX ei ole yhteydessä. Avaa CheckoutX valmistelua varten ja yritä uudelleen.",
  forbidden: "Ei oikeutta.",
  unauthorized: "Kirjaudu uudelleen.",
};
const PERM: Record<string, string[]> = {
  start: ["pos.use"], status: ["pos.use"], cancel: ["pos.use"], configure: ["pos.use"],
  register_start: ["settings.edit"], register_check: ["settings.edit"],
  refund: ["payments.refund", "bookings.manage"],
};

const posInt = (v: unknown): number | null => {
  const n = typeof v === "number" ? v : typeof v === "string" && /^\d{1,18}$/.test(v) ? Number(v) : NaN;
  return Number.isSafeInteger(n) && n > 0 ? n : null;
};

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const cors = CORS_HEADERS(req.headers.get("origin"), deps.env?.get("CHECKOUTX_ALLOWED_ORIGINS"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  const respond = (o: Record<string, unknown>, s = 200) => jsonResponse(o, s, cors);
  const fail = (code: string, extra: Record<string, unknown> = {}, message?: string) =>
    respond({ ok: false, code, message: message ?? MSG[code] ?? code, ...extra }, HTTP[code] ?? 500);
  if (req.method !== "POST") return fail("method_not_allowed");

  let b: any = null;
  try { b = await req.json(); } catch { /* tyhjä */ }
  const action = typeof b?.action === "string" ? b.action : "";
  const need = PERM[action];
  if (!need) return fail("invalid_param", {}, "Tuntematon toiminto");

  const caller = await deps.caller(req);
  if (!caller) return fail("unauthorized");
  if (!caller.service) {
    let ok = false;
    for (const p of need) { if (await caller.can(p)) { ok = true; break; } }
    if (!ok) return fail("forbidden");
  }

  const mode = await deps.db.cxMode();
  if (mode !== "test") return action === "refund" ? respond({ ok: true, mode, processed: [] }) : fail("checkoutx_off", { mode });
  if (!deps.env || !deps.fetch || !envAllowed(deps.env)) return fail("not_configured");
  const cfg = readConfig(deps.env);
  if (!cfg) return fail("not_configured");
  const api = new SurfboardApi(cfg, deps.fetch);
  const db = deps.db;
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await db.rpc(fn, args);
    if (error) { const e = dbError(error)!; throw new DbFail(e.code, e.message); }
    return data;
  };

  try {
    switch (action) {
      case "configure":
        return respond({ ok: true, deep_link: configureLink(b?.return) });

      case "register_start": {
        const d = await api.interappCode();
        const code = d?.registrationCode;
        if (typeof code !== "string" || !/^[A-Za-z0-9_-]{4,128}$/.test(code)) return fail("provider_error");
        return respond({ ok: true, registration_code: code, expires_in: 120, deep_link: registerLink(code, b?.return) });
      }

      case "register_check": {
        const code = b?.registration_code;
        if (typeof code !== "string" || !/^[A-Za-z0-9_-]{4,128}$/.test(code)) return fail("invalid_param");
        const d = await api.interappDetails(code);
        if (d?.registrationStatus !== "REGISTERED" || !validId(d?.terminalId)) return respond({ ok: true, registered: false });
        const saved = await rpc("checkoutx_terminal_save", { p_terminal_id: d.terminalId, p_label: typeof b?.label === "string" ? b.label : "", p_actor: caller.uid });
        return respond({ ok: true, registered: true, terminal_id: d.terminalId, label: saved?.label ?? null });
      }

      case "start": {
        const orderId = posInt(b?.order_id);
        if (!orderId || !validId(b?.terminal_id)) return fail("invalid_param");
        const prep = await rpc("checkoutx_pos_prepare", { p_order_id: orderId, p_terminal_id: b.terminal_id, p_actor: caller.uid });
        const paymentId = Number(prep.payment_id);
        try {
          const created = await api.createOrder({
            terminalId: b.terminal_id,
            referenceId: `saunotus-pos-${paymentId}`,
            amountMinor: toMinor(Number(prep.amount)),
            lineId: `pos-${orderId}`,
            lineName: `Pikakassa ${prep.order_no ?? orderId}`.slice(0, 80),
          });
          if (!validId(created?.orderId) || typeof created?.interAppJWT !== "string" || !created.interAppJWT) {
            throw new CxError("provider_error", "bad_create_response");
          }
          await rpc("checkoutx_pos_created", { p_payment_id: paymentId, p_sb_order_id: created.orderId, p_sb_payment_id: validId(created.paymentId) ? created.paymentId : null });
          return respond({
            ok: true, payment_id: paymentId, amount: prep.amount, order_no: prep.order_no ?? null,
            deep_link: transactionLink(b.terminal_id, created.interAppJWT, b?.return),
            configure_link: configureLink(b?.return),
          });
        } catch (e) {
          if (e instanceof CxError) {
            await db.rpc("checkoutx_pos_create_failed", { p_payment_id: paymentId, p_detail: e.summary() });
            if (/PS_0025/.test(e.message)) return fail("terminal_not_connected", { configure_link: configureLink(b?.return) });
            return fail(cxCode(e));
          }
          throw e;
        }
      }

      case "status":
      case "cancel": {
        const paymentId = posInt(b?.payment_id);
        if (!paymentId) return fail("invalid_param");
        const pay = await rpc("checkoutx_pos_lookup", { p_payment_id: paymentId });
        if (pay.source_channel !== "pikakassa") return fail("not_found");
        if (pay.status !== "pending") return respond({ ok: true, state: pay.status, payment_id: paymentId });
        if (!pay.sb_order_id) {
          if (action === "cancel") await rpc("checkoutx_pos_create_failed", { p_payment_id: paymentId, p_detail: { reason: "cancelled_before_start" } });
          return respond({ ok: true, state: action === "cancel" ? "cancelled" : "pending", payment_id: paymentId });
        }
        if (action === "cancel") {
          try { await api.cancelOrder(pay.sb_order_id); } catch (e) { if (!(e instanceof CxError)) throw e; /* tila ratkaistaan alla */ }
        }
        let st;
        try {
          st = mapOrderStatus(await api.orderStatus(pay.sb_order_id));
        } catch (e) {
          if (e instanceof CxError && action === "status") return respond({ ok: true, state: "pending", retry: true, payment_id: paymentId });
          throw e;
        }
        if (st.state === "pending" && action === "cancel") st = { ...st, state: "cancelled" };
        if (st.state !== "pending") {
          await rpc("checkoutx_pos_apply", {
            p_payment_id: paymentId, p_outcome: st.state, p_sb_payment_id: validId(st.paymentId) ? st.paymentId : null,
            p_raw: { orderStatus: st.orderStatus, failureReason: st.failureReason },
          });
        }
        return respond({ ok: true, state: st.state, failure_reason: st.failureReason, payment_id: paymentId });
      }

      case "refund": {
        const refundId = posInt(b?.refund_id);
        if (!refundId) return fail("invalid_param");
        const claim = await rpc("checkoutx_refund_claim", { p_refund_id: refundId });
        const processed: Record<string, unknown>[] = [];
        for (const c of (claim?.claimed ?? []) as any[]) {
          const full = Math.abs(Number(c.amount) - Number(c.payment_amount)) < 0.005 && Number(c.refunded_amount || 0) === 0;
          if (!full) {
            await db.rpc("checkoutx_refund_fail", { p_refund_id: c.refund_id, p_error: { reason: "partial_not_supported" } });
            processed.push({ refund_id: c.refund_id, result: "not_supported" });
            continue;
          }
          if (!validId(c.sb_payment_id)) {
            await db.rpc("checkoutx_refund_fail", { p_refund_id: c.refund_id, p_error: { reason: "missing_payment_id" } });
            processed.push({ refund_id: c.refund_id, result: "failed" });
            continue;
          }
          try {
            const v = await api.voidPayment(c.sb_payment_id);
            await rpc("checkoutx_refund_complete", { p_refund_id: c.refund_id, p_raw: { void: v ?? {} } });
            processed.push({ refund_id: c.refund_id, result: "done" });
          } catch (e) {
            if (!(e instanceof CxError)) throw e;
            if (e.transient) { processed.push({ refund_id: c.refund_id, result: "retry_later" }); continue; }
            await db.rpc("checkoutx_refund_fail", { p_refund_id: c.refund_id, p_error: e.summary() });
            processed.push({ refund_id: c.refund_id, result: "failed", detail: "void_rejected" });
          }
        }
        return respond({ ok: true, mode, processed });
      }
    }
    return fail("invalid_param");
  } catch (e) {
    if (e instanceof DbFail) return fail(e.code, {}, e.message || undefined);
    if (e instanceof CxError) return fail(cxCode(e));
    throw e;
  }
}

/** Surfboard-virhe → selaimen koodi. Väärät/vanhentuneet avaimet ja puuttuva kauppatunnus näkyvät tunnusvirheenä. */
function cxCode(e: CxError): string {
  if (e.code === "unauthorized" || e.code === "not_configured") return "not_configured";
  return e.transient ? "provider_unavailable" : "provider_error";
}

class DbFail extends Error {
  constructor(public code: string, message: string) { super(message); }
}
