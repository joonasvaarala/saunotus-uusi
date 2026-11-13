// sumup-pos: Pikakassan korttipääte (SumUp Solo, Cloud API). booking_295.
// Selain (hallinta, käyttäjän JWT) → tämä funktio → SumUp. Avaimet ja affiliate key vain täällä (Edge-salaisuudet).
// Toiminnot (POST JSON, action):
//   reader_pair {pairing_code, name}   settings.edit   – paritus: POST readers, tallentaa lukijan id:n ja nimen
//   reader_list {}                     pos.use         – lukijat SumUpin rajapinnasta (id, nimi, tila)
//   start {order_id, reader_id}        pos.use         – luo avoimen maksun ja POST readers/{id}/checkout
//   status {payment_id}                pos.use         – kysyy tilan SumUpilta ja kirjaa (maksettu vain rajapinnan vahvistamana)
//   cancel {payment_id}                pos.use         – terminate lukijalle, sitten tilan täsmäytys; ei-maksettu → peruttu
//   refund {refund_id}                 payments.refund – hyvitys SumUpin refund-rajapinnalla
// Kaikki vaatii integration_config.sumup.mode = test|live ja SUMUP_ENV:n vastaavan tilaa (sandbox|live).
import { CORS_HEADERS, dbError, type Env, type Fetch, jsonResponse, type Rpc } from "../_shared/mobilepay.ts";
import { envMatchesMode, readConfig, SumupApi, SumupError, toMinor, validId, validPairingCode } from "../_shared/sumup.ts";
import { reconcilePayment } from "../_shared/sumup_flow.ts";

export type Caller = { uid: string | null; service: boolean; can: (perm: string) => Promise<boolean> };
export type SumupDb = { rpc: Rpc; mode: () => Promise<string> };
export type Deps = { db: SumupDb; env?: Env; fetch?: Fetch; caller: (req: Request) => Promise<Caller | null> };

const HTTP: Record<string, number> = {
  invalid_param: 400, unauthorized: 401, forbidden: 403, not_found: 404, method_not_allowed: 405,
  sumup_off: 409, order_not_payable: 409, payment_in_progress: 409, nothing_to_pay: 409, payment_not_pending: 409,
  reader_not_paired: 409, ref_conflict: 409, payment_not_started: 409, reader_offline: 409,
  not_configured: 503, provider_unavailable: 503, provider_error: 502,
};
const MSG: Record<string, string> = {
  sumup_off: "Korttipääte ei ole käytössä.",
  not_configured: "SumUp-tunnukset puuttuvat tai eivät vastaa tilaa. Maksua ei aloitettu.",
  provider_error: "SumUp ei hyväksynyt pyyntöä. Yritä uudelleen.",
  provider_unavailable: "SumUp ei vastaa juuri nyt. Yritä hetken kuluttua uudelleen.",
  reader_not_paired: "Lukijaa ei ole paritettu.",
  reader_offline: "Lukija ei ole yhteydessä. Tarkista lukijan verkkoyhteys ja yritä uudelleen.",
  forbidden: "Ei oikeutta.",
  unauthorized: "Kirjaudu uudelleen.",
};
const PERM: Record<string, string[]> = {
  reader_pair: ["settings.edit"], reader_list: ["pos.use"],
  start: ["pos.use"], status: ["pos.use"], cancel: ["pos.use"],
  refund: ["payments.refund", "bookings.manage"],
};

const posInt = (v: unknown): number | null => {
  const n = typeof v === "number" ? v : typeof v === "string" && /^\d{1,18}$/.test(v) ? Number(v) : NaN;
  return Number.isSafeInteger(n) && n > 0 ? n : null;
};

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const cors = CORS_HEADERS(req.headers.get("origin"), deps.env?.get("SUMUP_ALLOWED_ORIGINS"));
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

  const mode = await deps.db.mode();
  if (mode !== "test" && mode !== "live") return action === "refund" ? respond({ ok: true, mode, processed: [] }) : fail("sumup_off", { mode });
  if (!deps.env || !deps.fetch || !envMatchesMode(deps.env, mode)) return fail("not_configured");
  const cfg = readConfig(deps.env);
  if (!cfg) return fail("not_configured");
  const api = new SumupApi(cfg, deps.fetch);
  const db = deps.db;
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await db.rpc(fn, args);
    if (error) { const e = dbError(error)!; throw new DbFail(e.code, e.message); }
    return data;
  };
  const notifyUrl = (deps.env.get("SUMUP_NOTIFY_URL") ?? "").trim();
  const returnUrl = /^https:\/\//.test(notifyUrl) ? `${notifyUrl}${notifyUrl.includes("?") ? "&" : "?"}s=${encodeURIComponent(cfg.webhookSecret)}` : null;

  try {
    switch (action) {
      case "reader_pair": {
        if (!validPairingCode(b?.pairing_code)) return fail("invalid_param", {}, "Virheellinen parituskoodi");
        const name = typeof b?.name === "string" ? b.name.trim().slice(0, 60) : "";
        const r = await api.pairReader(b.pairing_code, name || "Lukija");
        if (!validId(r?.id)) return fail("provider_error");
        const saved = await rpc("sumup_reader_save", { p_reader_id: r.id, p_name: name, p_actor: caller.uid });
        return respond({ ok: true, reader_id: r.id, name: saved?.name ?? name, status: typeof r.status === "string" ? r.status : null });
      }

      case "reader_list": {
        const d = await api.listReaders();
        const readers = (d?.items ?? []).filter((x) => validId(x?.id)).map((x) => ({
          reader_id: x.id, name: typeof x.name === "string" ? x.name.slice(0, 60) : "", status: typeof x.status === "string" ? x.status : null,
        }));
        return respond({ ok: true, readers });
      }

      case "start": {
        const orderId = posInt(b?.order_id);
        if (!orderId || !validId(b?.reader_id)) return fail("invalid_param");
        const prep = await rpc("sumup_pos_prepare", { p_order_id: orderId, p_reader_id: b.reader_id, p_actor: caller.uid });
        const paymentId = Number(prep.payment_id);
        // Aiempi yritys saattaa yhä näkyä lukijalla: keskeytetään (virhe ei estä uutta yritystä).
        if (Array.isArray(prep.superseded) && prep.superseded.length) {
          try { await api.readerTerminate(b.reader_id); } catch { /* lukija ei ehkä ole enää checkoutissa */ }
        }
        try {
          const created = await api.readerCheckout({
            readerId: b.reader_id,
            amountMinor: toMinor(Number(prep.amount)),
            currency: String(prep.currency || "EUR"),
            foreignId: `saunotus-pos-${paymentId}`,
            description: `Pikakassa ${prep.order_no ?? orderId}`.slice(0, 80),
            returnUrl,
          });
          const ctx = created?.data?.client_transaction_id;
          if (!validId(ctx)) throw new SumupError("provider_error", "bad_checkout_response");
          await rpc("sumup_pos_started", { p_payment_id: paymentId, p_client_tx_id: ctx });
          return respond({ ok: true, payment_id: paymentId, amount: prep.amount, order_no: prep.order_no ?? null, reader_id: b.reader_id });
        } catch (e) {
          if (e instanceof SumupError) {
            await db.rpc("sumup_pos_create_failed", { p_payment_id: paymentId, p_detail: e.summary() });
            return fail(sumupCode(e, true));
          }
          throw e;
        }
      }

      case "status":
      case "cancel": {
        const paymentId = posInt(b?.payment_id);
        if (!paymentId) return fail("invalid_param");
        const pay = await rpc("sumup_pos_lookup", { p_payment_id: paymentId });
        if (pay.source_channel !== "pikakassa") return fail("not_found");
        if (pay.status === "paid" || (pay.status !== "pending" && action === "status")) return respond({ ok: true, state: pay.status, payment_id: paymentId });
        if (pay.status !== "pending") return respond({ ok: true, state: pay.status, payment_id: paymentId });
        if (!pay.client_transaction_id) {
          if (action === "cancel") await rpc("sumup_pos_create_failed", { p_payment_id: paymentId, p_detail: { reason: "cancelled_before_start" } });
          return respond({ ok: true, state: action === "cancel" ? "cancelled" : "pending", payment_id: paymentId });
        }
        if (action === "cancel" && validId(pay.reader_id)) {
          try { await api.readerTerminate(pay.reader_id); } catch (e) { if (!(e instanceof SumupError)) throw e; /* tila ratkaistaan alla */ }
        }
        const r = await reconcilePayment(db.rpc, api, pay);
        let state = r.state;
        if (state === "pending" && action === "cancel") {
          // Ei maksettu: peruttu. Jos asiakas ehtii maksaa terminaatin jälkeen, status/webhook kirjaa maksun (apply sallii paid myös perutulle).
          await rpc("sumup_pos_apply", { p_payment_id: paymentId, p_outcome: "cancelled", p_raw: { by: "pos_cancel" } });
          state = "cancelled";
        }
        return respond({ ok: true, state, payment_id: paymentId, ...(r.retry ? { retry: true } : {}) });
      }

      case "refund": {
        const refundId = posInt(b?.refund_id);
        if (!refundId) return fail("invalid_param");
        const claim = await rpc("sumup_refund_claim", { p_refund_id: refundId });
        const processed: Record<string, unknown>[] = [];
        for (const c of (claim?.claimed ?? []) as any[]) {
          const full = Math.abs(Number(c.amount) - Number(c.payment_amount)) < 0.005 && Number(c.refunded_amount || 0) === 0;
          if (!full && claim?.partial_refund !== true) {
            await db.rpc("sumup_refund_fail", { p_refund_id: c.refund_id, p_error: { reason: "partial_not_supported" } });
            processed.push({ refund_id: c.refund_id, result: "not_supported" });
            continue;
          }
          if (!validId(c.transaction_id)) {
            await db.rpc("sumup_refund_fail", { p_refund_id: c.refund_id, p_error: { reason: "missing_transaction_id" } });
            processed.push({ refund_id: c.refund_id, result: "failed" });
            continue;
          }
          try {
            await api.refund(c.transaction_id, full ? undefined : Number(c.amount));
            await rpc("sumup_refund_complete", { p_refund_id: c.refund_id, p_raw: { transaction_id: c.transaction_id, partial: !full } });
            processed.push({ refund_id: c.refund_id, result: "done" });
          } catch (e) {
            if (!(e instanceof SumupError)) throw e;
            if (e.transient) { processed.push({ refund_id: c.refund_id, result: "retry_later" }); continue; }
            await db.rpc("sumup_refund_fail", { p_refund_id: c.refund_id, p_error: e.summary() });
            processed.push({ refund_id: c.refund_id, result: "failed", detail: "refund_rejected" });
          }
        }
        return respond({ ok: true, mode, processed });
      }
    }
    return fail("invalid_param");
  } catch (e) {
    if (e instanceof DbFail) return fail(e.code, {}, e.message || undefined);
    if (e instanceof SumupError) return fail(sumupCode(e, false));
    throw e;
  }
}

/** SumUp-virhe → selaimen koodi. Lukijan offline-tila (404/422 checkoutissa) näkyy omana virheenä. */
function sumupCode(e: SumupError, checkout: boolean): string {
  if (e.code === "unauthorized") return "not_configured";
  if (checkout && (e.status === 404 || e.status === 422)) return "reader_offline";
  return e.transient ? "provider_unavailable" : "provider_error";
}

class DbFail extends Error {
  constructor(public code: string, message: string) { super(message); }
}
