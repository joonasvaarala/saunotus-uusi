// Tilauslistan riville laskunumero ja laskun tila (booking_270).
// Tilatekstit samoista avaimista kuin Laskut-näkymä (ui.admin.invoices.st_*).
import { invoiceText } from './invoices-texts.js';

export const INVOICE_STATUSES = ['draft', 'sent', 'paid', 'overdue', 'credited', 'voided'];

/** Palauttaa esim. "L000001 / Lähetetty", luonnokselle ilman numeroa "Luonnos". Puuttuvat kentät → tyhjä (ei roskaa). */
export function orderInvoiceCaption(o, text = invoiceText) {
  if (!o || typeof o !== 'object') return '';
  const no = o.invoice_no != null && String(o.invoice_no).trim() ? String(o.invoice_no).trim() : '';
  const st = o.invoice_status != null ? String(o.invoice_status).trim() : '';
  const statusText = INVOICE_STATUSES.includes(st) ? text(`ui.admin.invoices.st_${st}`) : '';
  const credit = o.invoice_kind === 'credit' ? text('ui.admin.invoices.kind_credit') : '';
  const detail = [credit, statusText].filter(Boolean).join(' · ');
  if (no && detail) return `${no} / ${detail}`;
  return no || detail;
}
