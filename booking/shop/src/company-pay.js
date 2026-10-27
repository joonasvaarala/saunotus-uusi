// booking_187: sama lasku-/verkkomaksurajaus kuin booking._order_pays_by_invoice.
export const paysByInvoice = (booking) =>
  booking?.customer_kind === 'company' && booking?.invoice_method !== 'online';

export const formPaysOnline = (customer) =>
  customer.kind !== 'company' || customer.invoiceMethod() === 'online';
