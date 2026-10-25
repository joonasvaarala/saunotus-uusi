// booking_175: laskun avaus Laskut-näkymässä osoitteella #/laskut?invoice=<id> (Uusi varaus → laskumaksu → lasku auki; myös suora linkki).
/** Laskun id URL-kyselystä (URLSearchParams tai vastaava get()); vain positiivinen kokonaisluku, muuten null. */
export function invoiceIdFromQuery(query) {
  const raw = String(query?.get?.('invoice') ?? '').trim();
  if (!/^[1-9][0-9]{0,15}$/.test(raw)) return null;
  const n = Number(raw);
  return Number.isSafeInteger(n) ? n : null;
}
/** Hash-linkki laskuun Laskut-näkymässä. */
export const invoiceHref = (id) => `#/laskut?invoice=${encodeURIComponent(id)}`;
/** Avataanko lasku heti hallinnan varauksen jälkeen: laskumaksu, yritysasiakas, oikeus laskuihin, ei vuosikorttia. Lasku jää luonnokseksi (lähetys napista). */
export const openInvoiceAfterBooking = ({ card, method, kind, canInvoices, orderId }) =>
  !card && method === 'invoice' && kind === 'company' && !!canInvoices && Number.isSafeInteger(Number(orderId)) && Number(orderId) > 0;
