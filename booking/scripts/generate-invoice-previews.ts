// Paikallinen, täysin keinotekoinen lasku-PDF-esikatselu. Ei tietokanta- tai verkkoyhteyksiä.
// Ajo: deno run -A --node-modules-dir=auto booking/scripts/generate-invoice-previews.ts /opt/cursor/artifacts
import { buildInvoicePdf } from "../supabase/functions/invoice-pdf/render.ts";

const output = Deno.args[0] || "/opt/cursor/artifacts";
await Deno.mkdir(output, { recursive: true });
const logoBytes = await Deno.readFile(new URL("../../public/img/logo-kuitti.png", import.meta.url));

const seller = {
  name: "Sipoonjoen Perinnesauna",
  legal_name: "Havuhattu Oy",
  business_id: "3018112-1",
  vat_id: "FI30181121",
  address: "Hindsbyntie 124",
  zip: "04130",
  city: "Sipoo",
  email: "savusauna@saunotus.fi",
  phone: "010 299 2866",
  web: "saunotus.fi",
  bank_name: "Testipankki (esimerkki)",
  iban: "FI21 1234 5600 0007 85",
  bic: "TESTFIHH",
};

const invoice = (locale: "fi" | "en", withBank: boolean) => ({
  invoice_no: "L000123",
  status: "sent",
  kind: "debit",
  locale,
  invoice_date: "2026-10-25",
  due_date: "2026-11-08",
  reference_no: "55958 22432 94671",
  seller_snapshot: withBank ? seller : { ...seller, bank_name: "", iban: "", bic: "" },
  customer: {
    company_name: locale === "en" ? "Example Customer Ltd" : "Malliyritys Testi Oy",
    business_id: "1234567-1",
    vat_id: "FI12345671",
    street: locale === "en" ? "Example Street 10" : "Mallikatu 10",
    zip: "00100",
    city: locale === "en" ? "Helsinki, Finland" : "Helsinki",
    country: "FI",
    einvoice_address: "003712345671",
    einvoice_operator: "003723327487",
  },
  lines: [
    {
      description: locale === "en" ? "Private smoke sauna evening" : "Yksityinen savusaunailta",
      quantity: 1,
      unit: locale === "en" ? "item" : "kpl",
      unit_price_net: 398.41,
      vat_rate: 25.5,
      line_net: 398.41,
      line_vat: 101.59,
      line_gross: 500,
    },
    {
      description: locale === "en" ? "Sauna refreshments" : "Saunatarjoilut",
      quantity: 1,
      unit: locale === "en" ? "item" : "kpl",
      unit_price_net: 44.05,
      vat_rate: 13.5,
      line_net: 44.05,
      line_vat: 5.95,
      line_gross: 50,
    },
  ],
  vat_breakdown: [
    { rate: 13.5, net: 44.05, vat: 5.95, gross: 50 },
    { rate: 25.5, net: 398.41, vat: 101.59, gross: 500 },
  ],
  total_net: 442.46,
  total_vat: 107.54,
  total_gross: 550,
  notes: locale === "en" ? "Preview only – no payment is due." : "Esikatselu – ei maksettavaa.",
});

for (const locale of ["fi", "en"] as const) {
  for (const withBank of [true, false]) {
    const suffix = withBank ? "with_iban" : "missing_iban";
    const name = `invoice_preview_${locale}_${suffix}.pdf`;
    const bytes = await buildInvoicePdf(invoice(locale, withBank), undefined, { logoBytes });
    await Deno.writeFile(`${output}/${name}`, bytes);
    console.log(`${output}/${name}`);
  }
}
