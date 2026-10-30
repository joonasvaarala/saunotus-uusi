// Maksun vahvistus ja hyvityksen lähetys. Maksetuksi merkitään vasta get_payment-summan täsmätessä.
// Selainpaluu ei yksin riitä: sama polku tarkistaa MAC:n (kutsuja) ja Visma Payn tilan.
import type { Db } from "./mobilepay.ts";
import { dbError } from "./mobilepay.ts";
import { PAY_SETTLED, REFUND_DONE, REFUND_PENDING, REFUND_REJECTED, scrubSource, VismaApi, VismaError, type PayEnv } from "./vismapay.ts";
import { feeSlice } from "./provider_fee.ts";

export type ApplyOutcome = "paid" | "failed" | "cancelled" | "pending" | "authorized" | "needs_review";

const euros = (cents: number) => (Math.round(cents) / 100).toFixed(2);

export function refundKey(row: { refund_id?: unknown; id?: unknown }): string | null {
  const id = row?.refund_id ?? row?.id;
  if (id == null || id === "") return null;
  return String(id);
}

function safeDetail(extra: Record<string, unknown>) {
  const src = scrubSource(extra.source);
  return { ...extra, source: src, customer: undefined, email: undefined, api_key: undefined, authcode: undefined, card_token: undefined };
}

export async function applyOutcome(db: Db, orderNumber: string, outcome: ApplyOutcome, amountEur: string | null, raw: Record<string, unknown>) {
  const { data, error } = await db.rpc("vismapay_payment_apply", {
    p_order_number: orderNumber,
    p_outcome: outcome,
    p_amount: amountEur,
    p_raw: safeDetail(raw),
  });
  if (error) return { ok: false as const, code: dbError(error)!.code, outcome };
  return { ok: true as const, ...(data ?? {}), outcome: data?.outcome ?? outcome };
}

/** Hakee get_payment, kaappaa tarvittaessa (status 1) ja kirjaa tuloksen. Ei merkitse maksetuksi jos summa ei täsmää. */
export async function settleOrder(api: VismaApi, db: Db, orderNumber: string): Promise<{ http: number; outcome: string; detail?: unknown }> {
  let got: any;
  try { got = await api.getPayment(orderNumber); }
  catch (e) {
    if (e instanceof VismaError && e.transient) return { http: 503, outcome: "maintenance", detail: e.summary() };
    return { http: 503, outcome: "retry", detail: e instanceof VismaError ? e.summary() : { reason: "get_payment" } };
  }
  if (Number(got?.result) === 10) return { http: 503, outcome: "maintenance" };
  if (Number(got?.result) !== 0 || !got?.payment) {
    return settleFromStatus(api, db, orderNumber, got);
  }
  let payment = got.payment;
  let status = Number(payment.status);
  if (status === 1) {
    let cap: any;
    try { cap = await api.capture(orderNumber); }
    catch (e) {
      if (e instanceof VismaError && e.transient) return { http: 503, outcome: "maintenance" };
      await applyOutcome(db, orderNumber, "authorized", null, { reason: "capture_error", status });
      return { http: 200, outcome: "authorized" };
    }
    if (Number(cap?.result) === 10) return { http: 503, outcome: "maintenance" };
    if (Number(cap?.result) !== 0) {
      await applyOutcome(db, orderNumber, "needs_review", null, { reason: "capture_failed", capture_result: cap?.result ?? null, errors: cap?.errors ?? null });
      return { http: 200, outcome: "needs_review" };
    }
    try {
      const again = await api.getPayment(orderNumber);
      if (Number(again?.result) === 0 && again.payment) { payment = again.payment; status = Number(payment.status); }
    } catch { /* kaappaus onnistui; alla oleva status ratkaisee */ }
  }
  const cents = Number(payment.amount);
  const source = payment.source;
  if (PAY_SETTLED.has(status)) {
    const applied = await applyOutcome(db, orderNumber, "paid", Number.isFinite(cents) ? euros(cents) : null, { visma_status: status, source, settled: 1, ...(feeSlice(payment) || {}) });
    if (!applied.ok) return { http: 503, outcome: "retry", detail: applied.code };
    if (applied.outcome === "needs_review" || applied.code === "amount_mismatch") return { http: 200, outcome: "needs_review" };
    return { http: 200, outcome: applied.already ? "paid" : "paid", detail: { already: !!applied.already } };
  }
  if (status === 2 || status === 3) {
    await applyOutcome(db, orderNumber, "failed", null, { visma_status: status, source });
    return { http: 200, outcome: "failed" };
  }
  if (status === 14) {
    await applyOutcome(db, orderNumber, "cancelled", null, { visma_status: status, source });
    return { http: 200, outcome: "cancelled" };
  }
  await applyOutcome(db, orderNumber, status === 1 ? "authorized" : "pending", null, { visma_status: status, source });
  return { http: 200, outcome: status === 1 ? "authorized" : "pending" };
}

async function settleFromStatus(api: VismaApi, db: Db, orderNumber: string, getResult: any): Promise<{ http: number; outcome: string; detail?: unknown }> {
  let st: any;
  try { st = await api.checkStatus(orderNumber); }
  catch (e) {
    if (e instanceof VismaError && e.transient) return { http: 503, outcome: "maintenance" };
    return { http: 503, outcome: "retry" };
  }
  const result = Number(st?.result);
  if (result === 10) return { http: 503, outcome: "maintenance" };
  if (result === 3 || result === 1 && Number(getResult?.result) === 2) {
    await applyOutcome(db, orderNumber, "pending", null, { check_result: result });
    return { http: 200, outcome: "pending" };
  }
  if (result === 2) {
    await applyOutcome(db, orderNumber, "failed", null, { check_result: result, source: st?.source });
    return { http: 200, outcome: "failed" };
  }
  if (result === 4) {
    await applyOutcome(db, orderNumber, "cancelled", null, { check_result: result });
    return { http: 200, outcome: "cancelled" };
  }
  if (result === 0 && Number(st?.settled) === 0) {
    await applyOutcome(db, orderNumber, "authorized", null, { check_result: result, settled: 0, source: st?.source });
    return { http: 200, outcome: "authorized" };
  }
  return { http: 503, outcome: "retry", detail: { get_result: getResult?.result ?? null, check_result: result } };
}

type Claim = {
  refund_id: number; amount_minor: number; order_number: string; env?: string;
  provider_refund_id?: string | null; sibling_refund_ids?: string[]; currency?: string;
};

function unlinkedMatch(payment: any, claim: Claim): string | null {
  const rows = Array.isArray(payment?.refunds) ? payment.refunds : [];
  const used = new Set((claim.sibling_refund_ids ?? []).map(String));
  if (claim.provider_refund_id) used.add(String(claim.provider_refund_id));
  const hits = rows.filter((r: any) => {
    const id = refundKey(r);
    if (!id || used.has(id)) return false;
    return Math.abs(Math.round(Number(r.amount))) === Math.round(Number(claim.amount_minor));
  });
  return hits.length === 1 ? refundKey(hits[0]) : null;
}

async function finishFromVisma(api: VismaApi, db: Db, claim: Claim, refundId: string): Promise<{ result: string; detail?: unknown }> {
  let g: any;
  try { g = await api.getRefund(refundId); }
  catch (e) {
    if (e instanceof VismaError && !e.transient) return fail(db, claim.refund_id, e.summary(), "failed");
    return { result: "retry_later" };
  }
  if (Number(g?.result) === 10) return { result: "retry_later" };
  if (Number(g?.result) === 2) return fail(db, claim.refund_id, { reason: "refund_not_found", refund_id: refundId }, "failed");
  const status = Number(g?.refund?.status);
  if (REFUND_DONE.has(status)) {
    const { error } = await db.rpc("vismapay_refund_complete", { p_refund_id: claim.refund_id, p_provider_refund_id: refundId, p_raw: { visma_status: status, type: "confirmed", ...(feeSlice(g?.refund) || {}) } });
    if (error) return { result: "db_error", detail: dbError(error)!.code };
    return { result: "done" };
  }
  if (REFUND_REJECTED.has(status)) return fail(db, claim.refund_id, { reason: "rejected", visma_status: status }, "failed");
  if (REFUND_PENDING.has(status)) return { result: "awaiting_customer", detail: { visma_status: status } };
  return { result: "retry_later", detail: { visma_status: status } };
}

async function fail(db: Db, refundId: number, error: unknown, result = "failed") {
  await db.rpc("vismapay_refund_fail", { p_refund_id: refundId, p_error: error });
  return { result, detail: error };
}

export async function processRefund(api: VismaApi, db: Db, claim: Claim, notifyUrl: string): Promise<{ result: string; detail?: unknown }> {
  if (!claim.order_number) return fail(db, claim.refund_id, { reason: "no_provider_ref" });
  if (claim.provider_refund_id) return finishFromVisma(api, db, claim, String(claim.provider_refund_id));

  let payment: any = null;
  try {
    const got = await api.getPayment(claim.order_number);
    if (Number(got?.result) === 10) return { result: "retry_later" };
    if (Number(got?.result) !== 0 || !got.payment) return fail(db, claim.refund_id, { reason: "payment_unknown", result: got?.result ?? null }, "not_settled");
    payment = got.payment;
  } catch (e) {
    if (e instanceof VismaError && e.transient) return { result: "retry_later" };
    return fail(db, claim.refund_id, e instanceof VismaError ? e.summary() : { reason: "get_payment" });
  }
  const status = Number(payment.status);
  if (!PAY_SETTLED.has(status)) return fail(db, claim.refund_id, { reason: "not_settled", visma_status: status }, "not_settled");
  const recovered = unlinkedMatch(payment, claim);
  if (recovered) {
    await db.rpc("vismapay_refund_stamp", { p_refund_id: claim.refund_id, p_provider_refund_id: recovered, p_provider_status: "recovered", p_raw: { recovered: true } });
    return finishFromVisma(api, db, { ...claim, provider_refund_id: recovered }, recovered);
  }
  const email = typeof payment.customer?.email === "string" ? payment.customer.email : null;
  let created: any;
  try {
    created = await api.createRefund({ orderNumber: claim.order_number, amountMinor: Math.round(Number(claim.amount_minor)), email, notifyUrl });
  } catch (e) {
    if (e instanceof VismaError && e.transient) return { result: "retry_later" };
    return fail(db, claim.refund_id, e instanceof VismaError ? e.summary() : { reason: "create_refund" });
  }
  if (Number(created?.result) === 10) return { result: "retry_later" };
  if (Number(created?.result) !== 0 || created.refund_id == null) {
    return fail(db, claim.refund_id, { reason: "create_refund", result: created?.result ?? null, errors: created?.errors ?? null });
  }
  const id = String(created.refund_id);
  const providerStatus = created.type === "email" ? "email_pending" : "instant";
  const { error: se } = await db.rpc("vismapay_refund_stamp", {
    p_refund_id: claim.refund_id, p_provider_refund_id: id, p_provider_status: providerStatus,
    p_raw: { type: created.type ?? null },
  });
  if (se) return { result: "db_error", detail: dbError(se)!.code };
  if (created.type === "email") return { result: "awaiting_customer", detail: { refund_id: id } };
  const { error } = await db.rpc("vismapay_refund_complete", { p_refund_id: claim.refund_id, p_provider_refund_id: id, p_raw: { type: "instant", visma_refund_id: id } });
  if (error) return { result: "db_error", detail: dbError(error)!.code };
  return { result: "done" };
}

export function envOf(raw: unknown): PayEnv {
  return raw === "live" ? "live" : "test";
}
