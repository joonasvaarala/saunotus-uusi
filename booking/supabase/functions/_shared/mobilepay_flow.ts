// Maksutapahtuman käsittely: Vippsin tila -> tietokanta (jaettu: webhook ja tilaussivun reconcile).
// Periaate: tilaus/maksu merkitään maksetuksi VAIN onnistuneen capturen jälkeen (booking.payment_mark_paid -> _on_payment_paid: kuitti + kirjanpito-outbox).
import { aggVal, dbError, type Db, MobilePayApi, VippsError, type VippsPayment } from "./mobilepay.ts";

export type Outcome = { reference: string; outcome: string; state?: string; detail?: unknown };
export class DbFailure extends Error { constructor(public fn: string, public info: { code: string; message: string }) { super(`db_${fn}_${info.code}`); } }

async function rpc(db: Db, fn: string, args: Record<string, unknown>) {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new DbFailure(fn, dbError(error)!);
  return data;
}

/** Peruu varauksen Vippsissä. Palauttaa true jos peruttu/ei enää peruttavissa; heittää vain tilapäisestä virheestä (jotta kutsu toistetaan). */
async function cancelAtVipps(api: MobilePayApi, ref: string): Promise<{ ok: boolean; error?: unknown }> {
  try { await api.cancel(ref); return { ok: true }; }
  catch (e) {
    if (e instanceof VippsError) { if (e.transient) throw e; return { ok: false, error: e.summary() }; }
    throw e;
  }
}

export function customerFromProfile(u: VippsPayment["userDetails"]) {
  const name = [u?.firstName, u?.lastName].map((s) => (s ?? "").trim()).filter(Boolean).join(" ") || null;
  return { name, email: (u?.email ?? "").trim() || null, phone: (u?.mobileNumber ?? "").trim() || null };
}

export async function processReference(ref: string, deps: { db: Db; api: MobilePayApi }): Promise<Outcome> {
  const { db, api } = deps;
  const lk = await rpc(db, "mobilepay_payment_lookup", { p_reference: ref });
  if (!lk?.found) return { reference: ref, outcome: "unknown_reference" };

  const vp = await api.getPayment(ref);          // tila aina Vippsistä (webhookin sisältöön ei luoteta)
  const state = vp.state ?? "UNKNOWN";
  const amountMinor = Number(lk.amount_minor), currency = String(lk.currency);

  if (lk.stale) {   // vanha yritys (asiakas aloitti uuden): vapautetaan mahdollinen varaus, ei kosketa maksuun
    if (state === "AUTHORIZED" && aggVal(vp, "capturedAmount") === 0) {
      const c = await cancelAtVipps(api, ref);
      await rpc(db, "mobilepay_payment_event", { p_reference: ref, p_state: "stale_cancelled", p_redirect_url: null, p_detail: c.ok ? null : { cancel_error: c.error } });
      return { reference: ref, state, outcome: "stale_cancelled" };
    }
    await rpc(db, "mobilepay_payment_event", { p_reference: ref, p_state: state, p_redirect_url: null, p_detail: null });
    return { reference: ref, state, outcome: "stale" };
  }

  if (state !== "AUTHORIZED") {
    await rpc(db, "mobilepay_payment_event", { p_reference: ref, p_state: state, p_redirect_url: null, p_detail: null });
    if (lk.status === "paid") return { reference: ref, state, outcome: "already_paid" };
    return { reference: ref, state, outcome: state === "CREATED" ? "pending" : "not_authorized" };   // ABORTED/EXPIRED/TERMINATED: maksu jää pending, asiakas voi yrittää uudelleen
  }

  // --- AUTHORIZED ---
  // Asiakastiedot (nimi/sähköposti/puhelin) tilaukselle: vain puuttuvat kentät (RPC ei ylikirjoita)
  let filled: unknown = [];
  if (vp.userDetails) {
    const c = customerFromProfile(vp.userDetails);
    try { filled = (await rpc(db, "mobilepay_fill_customer", { p_payment_id: lk.payment_id, p_name: c.name, p_email: c.email, p_phone: c.phone }))?.filled ?? []; }
    catch (e) { if (!(e instanceof DbFailure)) throw e; /* asiakastiedon täydennys ei saa estää maksun käsittelyä */ }
  }

  if (lk.status === "paid") return { reference: ref, state, outcome: "already_paid", detail: { filled } };
  if (lk.status !== "pending") {
    await cancelAtVipps(api, ref);
    await rpc(db, "mobilepay_payment_event", { p_reference: ref, p_state: "cancelled_not_pending", p_redirect_url: null, p_detail: { payment_status: lk.status } });
    return { reference: ref, state, outcome: "cancelled_not_pending" };
  }

  const authorized = vp.aggregate?.authorizedAmount ?? vp.amount;
  if (!authorized || authorized.value !== amountMinor || authorized.currency !== currency) {
    const c = await cancelAtVipps(api, ref);
    await rpc(db, "mobilepay_payment_fail", { p_reference: ref, p_status: "failed", p_reason: "amount_mismatch", p_detail: { expected: amountMinor, got: authorized ?? null, cancel: c.ok } });
    return { reference: ref, state, outcome: "amount_mismatch" };
  }

  let captured = aggVal(vp, "capturedAmount");
  if (captured < amountMinor) {
    const cf = await rpc(db, "mobilepay_payment_confirmable", { p_reference: ref });
    if (!cf?.confirmable) {   // aika/tilaus ei enää kunnossa -> ei veloiteta: vapautetaan varaus
      const c = await cancelAtVipps(api, ref);
      await rpc(db, "mobilepay_payment_fail", { p_reference: ref, p_status: "cancelled", p_reason: cf?.reason ?? "not_confirmable", p_detail: { cancel: c.ok } });
      return { reference: ref, state, outcome: `cancelled_${cf?.reason ?? "not_confirmable"}` };
    }
    try {
      const cap = await api.capture(ref, amountMinor, currency);
      captured = aggVal(cap, "capturedAmount");
      if (captured < amountMinor) captured = aggVal(await api.getPayment(ref), "capturedAmount");   // varmistus: capture-vastauksessa ei välttämättä aggregatea
    } catch (e) {
      if (e instanceof VippsError && !e.transient) {
        await rpc(db, "mobilepay_payment_event", { p_reference: ref, p_state: "capture_failed", p_redirect_url: null, p_detail: e.summary() });
        return { reference: ref, state, outcome: "capture_failed", detail: e.summary() };
      }
      throw e;   // tilapäinen: webhook-uudelleenyritys / reconcile toistaa (Idempotency-Key estää tuplacapturen)
    }
    if (captured < amountMinor) {
      await rpc(db, "mobilepay_payment_event", { p_reference: ref, p_state: "capture_unverified", p_redirect_url: null, p_detail: { captured } });
      return { reference: ref, state, outcome: "capture_unverified" };
    }
  }

  const paid = await rpc(db, "payment_mark_paid", { p_provider: "mobilepay", p_provider_ref: ref, p_amount: lk.amount, p_raw: null });
  await rpc(db, "mobilepay_payment_event", { p_reference: ref, p_state: "CAPTURED", p_redirect_url: null, p_detail: null });
  return { reference: ref, state, outcome: paid?.needs_manual_review ? "paid_needs_review" : "paid", detail: { filled } };
}
