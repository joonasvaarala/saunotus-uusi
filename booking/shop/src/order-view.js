// Tilaussivun näkymäpäätökset. Ei DOMia, ei maksulogikkaa: vain mitä asiakkaalle näytetään.
// Lahjakortin osto (ei varausta) on yksi yhteenveto. Varaus ja osittainen maksu säilyttävät rivit ja maksetun summan.

export function orderChrome({
  reservations = [], giftCards = [], paid = 0, unpaid = 0, paymentStatus = '', status = '',
  receipts = [], cancelRequest = null, holdView = false,
} = {}) {
  const cards = giftCards.length;
  const giftOnly = cards > 0 && reservations.length === 0;
  const paidAmt = +paid || 0;
  const due = +unpaid || 0;
  const cancelOpen = !!(cancelRequest && (cancelRequest.status || cancelRequest));
  let badge = null;
  if (!holdView) {
    const st = cancelOpen ? 'cancel_requested' : status;
    if (st === 'cancel_requested') badge = { kind: 'st-cancel_requested', key: 'st.cancel_requested' };
    else if (st === 'cancelled') badge = { kind: 'st-cancelled', key: 'st.cancelled' };
    else if (st === 'expired') badge = { kind: 'st-expired', key: 'st.expired' };
    else if (paymentStatus === 'refunded' || paymentStatus === 'partially_refunded' || paymentStatus === 'failed') badge = { kind: `pay-${paymentStatus}`, key: `pay.${paymentStatus}` };
    else if (paymentStatus === 'partially_paid' || (paidAmt > 0 && due > 0)) badge = { kind: 'pay-partially_paid', key: 'pay.partially_paid' };
    else if (due > 0) badge = { kind: 'st-pending', key: 'st.pending' };
    else badge = { kind: 'pay-paid', key: 'pay.paid' };
  }
  return {
    giftOnly,
    badge,
    // Osittainen maksu: yhteensä, maksettu ja maksamatta. Muuten yksi summa (ei 0 € -laatikkoa).
    sums: paidAmt > 0 && due > 0 ? 'partial' : 'total',
    showLines: !giftOnly,
    showReceipts: receipts.length > 0,
    showAdd: !giftOnly,
    showCancel: !giftOnly || cancelOpen,
    // Lahjakortilla maksamisen ohje vain kun tilauksella ei ole lahjakorttirivejä.
    explainGiftPay: cards === 0,
    heading: giftOnly ? (due > 0 ? 'pay' : 'thanks') : 'order',
  };
}
