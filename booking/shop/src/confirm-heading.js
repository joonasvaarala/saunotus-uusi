// Vahvistussivun otsikon laji. "Varausvahvistus" vain kun varaus on oikeasti vahvistettu
// (myös lasku ja maksu paikan päällä). Maksua odottava sivu on "Viimeistele varaus".

export function confirmPageKind(b, co, paysInvoice) {
  if (!b || b.ok === false) return 'missing';
  if (b.status === 'cancelled' || co?.cancelled) return 'cancelled';
  if (b.status === 'expired' || co?.expired) return 'expired';
  if (co?.preliminary) return 'preliminary';
  if (co?.awaiting || co?.processing) return 'finish';
  if (co?.confirmed || b.status === 'confirmed' || b.payment_status === 'paid' || b.payment_status === 'invoiced' || paysInvoice) return 'confirmed';
  if (b.status === 'pending') return 'finish';
  return 'confirmed';
}
