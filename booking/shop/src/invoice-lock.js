// booking_185: asiakkaan näkymä, kun veloituslasku on lähetetty. Sama sääntö kuin booking._order_invoice_locked.
export function customerInvoiceLock(booking) {
  const locked = booking?.invoice_locked === true;
  return { locked, showPendingCancel: !locked, personsDisabled: locked, showPriceEstimate: !locked };
}
