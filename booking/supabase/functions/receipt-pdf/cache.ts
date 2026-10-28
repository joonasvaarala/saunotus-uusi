// Kuitti-PDF:n tallennusavain. Ei koskaan kuittinumero: sama numero voi jäädä Storageen
// vanhan kuitin tiedostona, jos laskuri nollattiin ja numero annettiin uudelle kuitille.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HASH = /^[0-9a-f]{32}$/;
const LEGACY = /^[A-Za-z]+-\d{4}-[^/]+\.pdf$/;

export interface ReceiptPdfInput {
  requestedToken: string;
  requestedOrderToken: string | null;
  receiptNo: string;
  publicToken: string;
  contentHash: string;
  pdfObjectKey: string;
  orderPublicToken: string;
}

export type ReceiptPdfDecision =
  | { action: "deny" }
  | { action: "render"; path: string | null };

/** {public_token}/{snapshot-md5}.pdf — tyhjä, jos tunniste tai tiiviste ei ole kelvollinen. */
export function receiptPdfObjectKey(publicToken: string, contentHash: string): string {
  const token = publicToken.trim().toLowerCase();
  const hash = contentHash.trim().toLowerCase();
  if (!UUID.test(token) || !HASH.test(hash)) return "";
  return `${token}/${hash}.pdf`;
}

/** true vain, kun ehdokas on juuri tämän kuitin avain. Kuittinumeron .pdf ei kelpaa. */
export function storageReadAllowed(expectedPath: string | null, candidate: string): boolean {
  if (!expectedPath || candidate !== expectedPath) return false;
  if (!candidate.includes("/")) return false;
  if (LEGACY.test(candidate)) return false;
  return true;
}

/**
 * Päätä, saako välimuistitiedoston lukea.
 * deny = väärä tilaus tai väärä kuittitoken (404, ei tiedostoa).
 * render + path = lue ja kirjoita vain tämä polku.
 * render + null = piirrä snapshotista, älä lue äläkä kirjoita Storagea
 * (vanha avain tai puuttuva tiiviste; ei koskaan toisen kuitin tiedostoa).
 */
export function decideReceiptPdf(input: ReceiptPdfInput): ReceiptPdfDecision {
  const token = input.requestedToken.trim().toLowerCase();
  const rowToken = input.publicToken.trim().toLowerCase();
  if (!UUID.test(token) || token !== rowToken) return { action: "deny" };
  const order = input.requestedOrderToken?.trim().toLowerCase() || "";
  if (order) {
    if (!UUID.test(order) || order !== input.orderPublicToken.trim().toLowerCase()) return { action: "deny" };
  }
  const expected = receiptPdfObjectKey(input.publicToken, input.contentHash);
  if (!expected || expected === `${input.receiptNo}.pdf` || expected !== input.pdfObjectKey) {
    return { action: "render", path: null };
  }
  if (!storageReadAllowed(expected, expected)) return { action: "render", path: null };
  return { action: "render", path: expected };
}

export function isPdfBytes(bytes: Uint8Array | null): boolean {
  return !!bytes && bytes.length >= 5 && bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46 && bytes[4] === 0x2d;
}
