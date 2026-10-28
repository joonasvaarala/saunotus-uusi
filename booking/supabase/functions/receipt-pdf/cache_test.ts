// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/receipt-pdf/cache_test.ts
import { assertEquals } from "jsr:@std/assert@1";
import { decideReceiptPdf, isPdfBytes, receiptPdfObjectKey, storageReadAllowed } from "./cache.ts";

const ORDER_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1";
const ORDER_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2";
const TOKEN_A = "11111111-1111-4111-8111-111111111111";
const TOKEN_B = "22222222-2222-4222-8222-222222222222";
const HASH_A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const HASH_B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const SAME_NO = "K-2026-000011";

function row(over: Partial<Parameters<typeof decideReceiptPdf>[0]> = {}) {
  const publicToken = over.publicToken ?? TOKEN_A;
  const contentHash = over.contentHash ?? HASH_A;
  return {
    requestedToken: publicToken,
    requestedOrderToken: ORDER_A,
    receiptNo: SAME_NO,
    publicToken,
    contentHash,
    pdfObjectKey: receiptPdfObjectKey(publicToken, contentHash),
    orderPublicToken: ORDER_A,
    ...over,
  };
}

Deno.test("kaksi kuittia samalla numerolla eivät jaa tiedostoa", () => {
  const a = decideReceiptPdf(row());
  const b = decideReceiptPdf(row({
    requestedToken: TOKEN_B,
    requestedOrderToken: ORDER_B,
    publicToken: TOKEN_B,
    contentHash: HASH_B,
    pdfObjectKey: receiptPdfObjectKey(TOKEN_B, HASH_B),
    orderPublicToken: ORDER_B,
  }));
  assertEquals(a.action, "render");
  assertEquals(b.action, "render");
  const aPath = a.action === "render" ? a.path : null;
  const bPath = b.action === "render" ? b.path : null;
  assertEquals(aPath, `${TOKEN_A}/${HASH_A}.pdf`);
  assertEquals(bPath, `${TOKEN_B}/${HASH_B}.pdf`);
  assertEquals(aPath !== bPath, true);
  assertEquals(storageReadAllowed(aPath, `${SAME_NO}.pdf`), false);
  assertEquals(storageReadAllowed(bPath, `${SAME_NO}.pdf`), false);
  assertEquals(storageReadAllowed(aPath, bPath ?? ""), false);
});

Deno.test("laskurin nollaus: sama numero, uusi token, eri polku", () => {
  const oldPdf = decideReceiptPdf(row());
  const reused = decideReceiptPdf(row({
    requestedToken: TOKEN_B,
    requestedOrderToken: ORDER_B,
    publicToken: TOKEN_B,
    contentHash: HASH_B,
    pdfObjectKey: receiptPdfObjectKey(TOKEN_B, HASH_B),
    orderPublicToken: ORDER_B,
    receiptNo: SAME_NO,
  }));
  const oldPath = oldPdf.action === "render" ? oldPdf.path : null;
  const newPath = reused.action === "render" ? reused.path : null;
  assertEquals(oldPath !== null && newPath !== null && oldPath !== newPath, true);
  assertEquals(storageReadAllowed(newPath, `${SAME_NO}.pdf`), false);
});

Deno.test("väärän tilauksen token ei avaa kuittia", () => {
  assertEquals(decideReceiptPdf(row({ requestedOrderToken: ORDER_B })).action, "deny");
  assertEquals(decideReceiptPdf(row({ requestedToken: TOKEN_B })).action, "deny");
  assertEquals(decideReceiptPdf(row({ requestedOrderToken: "ei-uuid" })).action, "deny");
});

Deno.test("sähköpostilinkki ilman tilaustokenia avaa vain tämän kuitin polun", () => {
  const d = decideReceiptPdf(row({ requestedOrderToken: null }));
  assertEquals(d, { action: "render", path: `${TOKEN_A}/${HASH_A}.pdf` });
});

Deno.test("vanhaa kuittinumerotiedostoa ei lueta eikä kirjoiteta", () => {
  const legacy = decideReceiptPdf(row({ pdfObjectKey: `${SAME_NO}.pdf` }));
  assertEquals(legacy, { action: "render", path: null });
  const missing = decideReceiptPdf(row({ contentHash: "", pdfObjectKey: "" }));
  assertEquals(missing, { action: "render", path: null });
  assertEquals(storageReadAllowed(null, `${SAME_NO}.pdf`), false);
  assertEquals(receiptPdfObjectKey(TOKEN_A, HASH_A) === receiptPdfObjectKey(TOKEN_B, HASH_A), false);
});

Deno.test("välimuisti kelpaa vain, jos tavut ovat PDF", () => {
  assertEquals(isPdfBytes(null), false);
  assertEquals(isPdfBytes(new Uint8Array([0x25, 0x50, 0x44, 0x46])), false);
  assertEquals(isPdfBytes(new TextEncoder().encode("%PDF-1.7")), true);
  assertEquals(isPdfBytes(new TextEncoder().encode("EI PDF")), false);
});
