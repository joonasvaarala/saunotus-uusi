// Maksun ja hyvityksen kirjaus. Maksetuksi vain varmennetusta PAID-tilasta, jonka summa ja viite täsmäävät.
// Hyvityskuitti syntyy vasta SUCCESSFUL-tilasta (ilmoitus tai sama varmennettu tila). Leima ei luo kuittia.
import type { Db } from "./mobilepay.ts";
import { dbError } from "./mobilepay.ts";
import { centsEqual, notSettled, paymentStatusOf, refundStatusOf, type PayApi, PayError } from "./montonio.ts";
import { feeSlice } from "./provider_fee.ts";

export type ApplyOutcome = "paid" | "failed" | "cancelled" | "pending" | "authorized" | "needs_review";

function scrub(raw: Record<string, unknown>) {
  const drop = ["senderName", "senderIban", "customer", "email", "accessKey", "secretKey"];
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(raw)) if (!drop.includes(k)) out[k] = v;
  return out;
}

export async function applyOutcome(db: Db, orderNumber: string, outcome: ApplyOutcome, amountEur: number | null, raw: Record<string, unknown>) {
  const { data, error } = await db.rpc("montonio_payment_apply", {
    p_order_number: orderNumber,
    p_outcome: outcome,
    p_amount: amountEur,
    p_raw: scrub(raw),
  });
  if (error) return { ok: false as const, code: dbError(error)!.code, outcome };
  return { ok: true as const, ...(data ?? {}), outcome: data?.outcome ?? outcome };
}

/** Varmennettu tilaustoken tai haettu tilaus. Ei merkitse maksetuksi, jos summa, viite tai avain ei täsmää. */
export async function applyVerified(db: Db, payload: Record<string, unknown>, expect: { accessKey: string; merchantReference: string; amount: number; orderUuid?: string | null }): Promise<{ http: number; outcome: string }> {
  const ref = String(payload.merchantReference || "");
  const status = paymentStatusOf(payload);
  if (payload.accessKey !== expect.accessKey || ref !== expect.merchantReference) {
    return { http: 200, outcome: "ignored" };
  }
  if (expect.orderUuid && payload.uuid && String(payload.uuid) !== expect.orderUuid) {
    return { http: 200, outcome: "ignored" };
  }
  if (status === "PAID") {
    const total = Number(payload.grandTotal);
    if (!Number.isFinite(total) || !centsEqual(total, expect.amount)) {
      const applied = await applyOutcome(db, ref, "needs_review", Number.isFinite(total) ? total : null, { reason: "amount_mismatch", paymentStatus: status, ...(feeSlice(payload) || {}) });
      return { http: applied.ok ? 200 : 503, outcome: "needs_review" };
    }
    const applied = await applyOutcome(db, ref, "paid", total, { paymentStatus: status, paymentMethod: payload.paymentMethod ?? null, uuid: payload.uuid ?? null, ...(feeSlice(payload) || {}) });
    if (!applied.ok) return { http: 503, outcome: "retry" };
    if (applied.outcome === "needs_review" || applied.code === "amount_mismatch" || applied.code === "duplicate_paid") return { http: 200, outcome: "needs_review" };
    return { http: 200, outcome: "paid" };
  }
  if (status === "VOIDED" || status === "ABANDONED") {
    await applyOutcome(db, ref, "cancelled", null, { paymentStatus: status });
    return { http: 200, outcome: "cancelled" };
  }
  await applyOutcome(db, ref, "pending", null, { paymentStatus: status || "PENDING" });
  return { http: 200, outcome: "pending" };
}

export async function settleFromApi(api: PayApi, db: Db, row: { order_number: string; amount: number; order_uuid?: string | null; env?: string }, accessKey: string) {
  if (!row.order_uuid) return { http: 200, outcome: "pending" };
  let got: Record<string, unknown>;
  try { got = await api.getOrder(row.order_uuid); }
  catch (e) {
    if (e instanceof PayError && e.transient) return { http: 503, outcome: "retry" };
    return { http: 200, outcome: "pending" };
  }
  const payload = (got.paymentStatus || got.merchantReference) ? got : (got.data as Record<string, unknown> | undefined) || got;
  return applyVerified(db, payload, { accessKey, merchantReference: row.order_number, amount: Number(row.amount), orderUuid: row.order_uuid });
}

type Claim = {
  refund_id: number; amount: number; order_uuid?: string | null; idempotency_key?: string | null;
  provider_refund_id?: string | null; env?: string;
};

async function release(db: Db, refundId: number, detail: unknown) {
  await db.rpc("montonio_refund_release", { p_refund_id: refundId, p_raw: { reason: "awaiting_settlement", detail } });
  return { result: "awaiting_settlement" as const, detail };
}

async function fail(db: Db, refundId: number, error: unknown) {
  await db.rpc("montonio_refund_fail", { p_refund_id: refundId, p_error: error });
  return { result: "failed" as const, detail: error };
}

async function complete(db: Db, claim: Claim, refundUuid: string, raw: Record<string, unknown>) {
  const { error } = await db.rpc("montonio_refund_complete", { p_refund_id: claim.refund_id, p_provider_refund_id: refundUuid, p_raw: raw });
  if (error) return { result: "db_error" as const, detail: dbError(error)!.code };
  return { result: "done" as const };
}

/** SUCCESSFUL kirjaa hyvityksen kerran. PENDING/PROCESSING ja selvittämätön tila jättävät rivin uudelleen yritettäväksi. */
export async function applyRefundStatus(db: Db, claim: Claim, payload: Record<string, unknown>): Promise<{ result: string; detail?: unknown }> {
  const status = refundStatusOf(payload);
  const uuid = String(payload.refundUuid || payload.uuid || claim.provider_refund_id || "");
  if (status === "SUCCESSFUL" || status === "REFUNDED") {
    if (!uuid) return { result: "retry_later" };
    return complete(db, claim, uuid, { refundStatus: status, ...(feeSlice(payload) || {}) });
  }
  if (status === "REJECTED" || status === "CANCELED" || status === "CANCELLED") {
    if (notSettled(payload)) return release(db, claim.refund_id, { refundStatus: status });
    return fail(db, claim.refund_id, { refundStatus: status });
  }
  if (uuid && !claim.provider_refund_id) {
    await db.rpc("montonio_refund_stamp", { p_refund_id: claim.refund_id, p_provider_refund_id: uuid, p_provider_status: status || "PENDING", p_raw: { refundStatus: status || "PENDING" } });
  }
  return { result: "pending", detail: { refundStatus: status || "PENDING" } };
}

export async function processRefund(api: PayApi, db: Db, claim: Claim): Promise<{ result: string; detail?: unknown }> {
  if (!claim.order_uuid) return fail(db, claim.refund_id, { reason: "no_order_uuid" });
  if (!(Number(claim.amount) >= 0.05)) return fail(db, claim.refund_id, { reason: "amount_below_minimum" });
  if (claim.provider_refund_id) return { result: "pending", detail: { provider_refund_id: claim.provider_refund_id } };
  let created: any;
  try {
    created = await api.createRefund({ orderUuid: claim.order_uuid, amount: Number(claim.amount), idempotencyKey: claim.idempotency_key || `refund-${claim.refund_id}` });
  } catch (e) {
    if (e instanceof PayError && notSettled(e.summary())) return release(db, claim.refund_id, e.summary());
    if (e instanceof PayError && e.transient) return { result: "retry_later" };
    if (e instanceof PayError) return fail(db, claim.refund_id, e.summary());
    return { result: "retry_later" };
  }
  const status = String(created?.status || created?.refundStatus || "PENDING").toUpperCase();
  const uuid = String(created?.uuid || created?.refundUuid || "");
  if (notSettled(created)) return release(db, claim.refund_id, { status });
  if (uuid) {
    const { error } = await db.rpc("montonio_refund_stamp", {
      p_refund_id: claim.refund_id, p_provider_refund_id: uuid, p_provider_status: status || "PENDING", p_raw: { status: status || "PENDING", ...(feeSlice(created) || {}) },
    });
    if (error) return { result: "db_error", detail: dbError(error)!.code };
  }
  // Hyvityskuitti syntyy vain varmennetusta SUCCESSFUL-ilmoituksesta (applyRefundStatus), ei luontivastauksesta.
  if (status === "REJECTED" || status === "CANCELED" || status === "CANCELLED") return fail(db, claim.refund_id, { status });
  return { result: "pending", detail: { status: status || "PENDING", refund_uuid: uuid || null } };
}
