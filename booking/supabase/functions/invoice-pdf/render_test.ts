import { assertEquals, assertGreater } from "jsr:@std/assert@1";
import { PDFDocument } from "npm:pdf-lib@1.17.1";
import qrcode from "npm:qrcode-generator@1.4.4";
import { buildInvoicePdf } from "./render.ts";

Deno.test("EPC QR käyttää oikeita UTF-8-tavuja", () => {
  assertEquals(qrcode.stringToBytes("Höyry & Löyly"), [...new TextEncoder().encode("Höyry & Löyly")]);
});

Deno.test("pitkä laskuhuomautus jatkuu uudelle sivulle", async () => {
  const bytes = await buildInvoicePdf({
    invoice_no: "L000123",
    status: "sent",
    kind: "debit",
    locale: "fi",
    invoice_date: "2026-10-25",
    due_date: "2026-11-08",
    reference_no: "559582243294671",
    seller_snapshot: {
      name: "Sipoonjoen Perinnesauna",
      legal_name: "Havuhattu Oy",
      business_id: "3018112-1",
      vat_id: "FI30181121",
      address: "Hindsbyntie 124",
      zip: "04130",
      city: "Sipoo",
      email: "savusauna@saunotus.fi",
      phone: "010 299 2866",
      iban: "",
      bic: "",
    },
    customer: { company_name: "Testiasiakas Oy", street: "Testikatu 1", zip: "00100", city: "Helsinki" },
    lines: [{ description: "Yksityinen savusaunailta", quantity: 1, unit: "kpl", unit_price_net: 398.41, vat_rate: 25.5, line_gross: 500 }],
    vat_breakdown: [{ rate: 25.5, net: 398.41, vat: 101.59, gross: 500 }],
    total_gross: 500,
    notes: "Pitkä laskuhuomautus turvallista sivutusta varten. ".repeat(40).slice(0, 2_000),
  }, undefined, { logoBytes: null });
  const pdf = await PDFDocument.load(bytes);
  assertGreater(pdf.getPageCount(), 1);
});
