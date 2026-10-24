import { assertEquals, assertGreater } from "jsr:@std/assert@1";
import { PDFDocument } from "npm:pdf-lib@1.17.1";
import qrcode from "npm:qrcode-generator@1.4.4";
import { buildInvoicePdf } from "./render.ts";

const baseInvoice = {
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
    iban: "",
    bic: "",
  },
  customer: { company_name: "Testiasiakas Oy", street: "Testikatu 1", zip: "00100", city: "Helsinki" },
  lines: [{ description: "Yksityinen savusaunailta", quantity: 1, unit: "kpl", unit_price_net: 398.41, vat_rate: 25.5, line_gross: 500 }],
  vat_breakdown: [{ rate: 25.5, net: 398.41, vat: 101.59, gross: 500 }],
  total_gross: 500,
};

Deno.test("EPC QR käyttää oikeita UTF-8-tavuja", () => {
  assertEquals(qrcode.stringToBytes("Höyry & Löyly"), [...new TextEncoder().encode("Höyry & Löyly")]);
});

Deno.test("pitkä laskuhuomautus jatkuu uudelle sivulle", async () => {
  const bytes = await buildInvoicePdf({
    ...baseInvoice,
    notes: "Pitkä laskuhuomautus turvallista sivutusta varten. ".repeat(40).slice(0, 2_000),
  }, undefined, { logoBytes: null });
  const pdf = await PDFDocument.load(bytes);
  assertGreater(pdf.getPageCount(), 1);
});

Deno.test("pitkä ostajan nimi, osoite ja verkkolaskutieto renderöityvät", async () => {
  const bytes = await buildInvoicePdf({
    ...baseInvoice,
    locale: "en",
    customer: {
      company_name: "Exceptionally Long Example Customer Company Name for Invoice Layout Verification and Testing Limited",
      business_id: "1234567-1",
      vat_id: "FI12345671",
      street: "A Very Long Example Street Address with Building, Staircase and Department Details 123 B 456",
      zip: "00100",
      city: "Helsinki, Finland",
      einvoice_address: "003712345671000000000000",
      einvoice_operator: "EXAMPLE-OPERATOR-WITH-A-LONG-NAME",
    },
  }, undefined, { logoBytes: null });
  const pdf = await PDFDocument.load(bytes);
  assertGreater(pdf.getPageCount(), 0);
});
