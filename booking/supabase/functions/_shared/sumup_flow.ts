// SumUp-maksun tilan täsmäytys. Käytetään sekä sumup-pos (status) että sumup-notify (webhook).
// Periaate: maksetuksi merkitään vain, kun SumUpin rajapinta (GET transactions) itse sanoo SUCCESSFUL ja summa täsmää.
// Webhookin sisältö on vain vihje siitä, että kannattaa kysyä.
import type { Rpc } from "./mobilepay.ts";
import { SumupApi, SumupError, toMinor, validId } from "./sumup.ts";

export type Reconciled = { state: "pending" | "paid" | "failed" | "cancelled"; applied: boolean; retry?: boolean };

/** hint = webhookin ilmoittama tila (successful/failed) – ei käytetä maksetuksi merkitsemiseen. */
export async function reconcilePayment(rpc: Rpc, api: SumupApi, pay: any, opts: { hint?: string | null } = {}): Promise<Reconciled> {
  if (pay.status === "paid") return { state: "paid", applied: false };
  if (pay.status !== "pending" && pay.status !== "cancelled" && pay.status !== "failed") return { state: pay.status, applied: false };
  if (!validId(pay.client_transaction_id)) return { state: "pending", applied: false };
  let tx;
  try {
    tx = await api.transactionByClientId(pay.client_transaction_id);
  } catch (e) {
    if (e instanceof SumupError) return { state: "pending", applied: false, retry: true };
    throw e;
  }
  const apply = async (outcome: string, extra: Record<string, unknown> = {}) => {
    const { error } = await rpc("sumup_pos_apply", { p_payment_id: pay.payment_id, p_outcome: outcome, ...extra });
    if (error) throw new SumupError("db_error", error.message ?? "db");
  };
  if (!tx) {
    // Transaktiota ei ole (vielä). Webhookin "failed" ilman transaktiota = lukijalla peruttu/hylätty ennen kortin lukua.
    if (opts.hint === "failed" && pay.status === "pending") { await apply("failed", { p_raw: { reason: "no_transaction" } }); return { state: "failed", applied: true }; }
    return { state: "pending", applied: false };
  }
  if (tx.state === "paid") {
    if (tx.amount === null || toMinor(tx.amount) !== toMinor(Number(pay.amount)) || (tx.currency && tx.currency !== pay.currency)) {
      // Summa ei täsmää: ei merkitä maksetuksi. Jää avoimeksi tarkistettavaksi.
      return { state: "pending", applied: false, retry: false };
    }
    await apply("paid", { p_transaction_id: tx.transactionId, p_confirmed_by: "api", p_amount: tx.amount, p_raw: { status: tx.status } });
    return { state: "paid", applied: true };
  }
  if (tx.state === "failed" || tx.state === "cancelled") {
    if (pay.status === "pending") await apply(tx.state, { p_raw: { status: tx.status } });
    return { state: tx.state, applied: pay.status === "pending" };
  }
  return { state: "pending", applied: false };
}
