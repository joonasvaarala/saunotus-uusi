// Välittäjän payloadista talteen vain provisiokentät (booking_216). Ei nimeä, tiliä eikä korttia.
// Järjestys on sama kuin booking._extract_provider_fee ja booking/admin/fee-report-logic.js.

export const EURO_KEYS = ["provider_fee", "providerFee", "merchantFee", "merchant_fee", "feeAmount", "fee_amount", "commissionAmount", "commission_amount", "commission", "provision", "serviceFee", "service_fee", "paymentFee", "payment_fee", "fee"] as const;
export const CENT_KEYS = ["feeCents", "fee_cents", "merchantFeeCents", "merchant_fee_cents", "commissionCents", "commission_cents"] as const;
export const NEST_KEYS = ["fees", "settlement", "pricing", "merchantFees", "merchant_fees"] as const;
const NEST_EURO = [...EURO_KEYS, "amount", "total", "value"] as const;
const NEST_CENT = [...CENT_KEYS, "amount_cents", "amountCents"] as const;

function present(v: unknown): boolean {
  return v != null && v !== "";
}

/** null, jos payloadissa ei ole tunnistettua provisiokenttää. Muuten vain ne kentät. */
export function feeSlice(raw: unknown): Record<string, unknown> | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const src = raw as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  for (const k of EURO_KEYS) if (present(src[k])) out[k] = src[k];
  for (const k of CENT_KEYS) if (present(src[k])) out[k] = src[k];
  for (const n of NEST_KEYS) {
    const obj = src[n];
    if (!obj || typeof obj !== "object" || Array.isArray(obj)) continue;
    const nested: Record<string, unknown> = {};
    const o = obj as Record<string, unknown>;
    for (const k of NEST_EURO) if (present(o[k])) nested[k] = o[k];
    for (const k of NEST_CENT) if (present(o[k])) nested[k] = o[k];
    if (Object.keys(nested).length) out[n] = nested;
  }
  return Object.keys(out).length ? out : null;
}
