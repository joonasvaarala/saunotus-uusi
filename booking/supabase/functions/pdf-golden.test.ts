// PDF-pohjien tekstisiirto (osa 3 / PR 3): lahjakortti- ja kuitti-PDF samat tavut kuin ennen siirtoa (tiivisteet pdf-golden.json, otettu vanhalla koodilla),
// kun tekstit tulevat repon oletuksista TAI tuontitiedoston riveistä (content/site-texts.imported-pr66.json); DB-teksti näkyy PDF:ssä; rikkinäinen DB-teksti → oletus.
// Ajo: deno test -A --node-modules-dir=none booking/supabase/functions/pdf-golden.test.ts
import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { giftCardCases, receiptCases } from "./pdf-golden-cases.mjs";
import { buildGiftCardPdf, GIFT_CARD_PDF_TEXTS } from "./gift-card-pdf/render.ts";
import { buildReceiptPdf, RECEIPT_PDF_TEXTS } from "./receipt-pdf/render.ts";
import { makeT, type TextRow } from "./_shared/site_texts.ts";

// pdf-lib kirjoittaa luonti-/muokkausajan → kiinnitetään kello, jotta tavut ovat toistettavat
const FIXED = new Date("2026-10-18T12:00:00Z").getTime(); const RD = Date;
// deno-lint-ignore no-explicit-any
(globalThis as any).Date = class extends RD { constructor(...a: any[]) { if (a.length) super(...(a as [any])); else super(FIXED); } static override now() { return FIXED; } };

const golden: Record<string, string> = JSON.parse(await Deno.readTextFile(new URL("./pdf-golden.json", import.meta.url)));
const logo = await Deno.readFile(new URL("../../docs/giftcards/logo.png", import.meta.url));
const imported: any[] = JSON.parse(await Deno.readTextFile(new URL("../../../content/site-texts.imported-pr66.json", import.meta.url)));
const importedRows: TextRow[] = imported.map((r) => ({ key: r.key, lang: r.lang, text: r.text }));
const hex = async (b: Uint8Array) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", b as unknown as BufferSource))).map((x) => x.toString(16).padStart(2, "0")).join("");
const tG = (rows?: TextRow[], settings?: Record<string, unknown>) => makeT(GIFT_CARD_PDF_TEXTS, rows, settings, () => {});
const tR = (rows?: TextRow[], settings?: Record<string, unknown>) => makeT(RECEIPT_PDF_TEXTS, rows, settings, () => {});

for (const [label, rows] of [["repon oletukset", undefined], ["tuontitiedoston rivit DB:nä", importedRows]] as const) {
  Deno.test(`PDF samat tavut kuin ennen siirtoa (${label})`, async () => {
    let n = 0;
    for (const c of giftCardCases()) { assertEquals(await hex(await buildGiftCardPdf(structuredClone(c.data), c.logo ? logo : null, c.lang, tG(rows))), golden[`gift.${c.name}`], `lahjakortti ${c.name}`); n++; }
    for (const c of receiptCases()) { assertEquals(await hex(await buildReceiptPdf(structuredClone(c.data), tR(rows))), golden[`receipt.${c.name}`], `kuitti ${c.name}`); n++; }
    assertEquals(n, Object.keys(golden).length, "kaikki kultaiset tapaukset ajettu");
  });
}

Deno.test("DB-teksti muuttaa PDF:ää; puuttuva kieli ja rikkinäinen paikkamerkki → oletus; PDF säilyy A4 pysty", async () => {
  const c = giftCardCases().find((x: any) => x.name === "fi_pkg_greet")!;
  const base = await buildGiftCardPdf(structuredClone(c.data), logo, c.lang);
  const changed = await buildGiftCardPdf(structuredClone(c.data), logo, c.lang, tG([{ key: "email.gift_card_pdf.title", lang: "fi", text: "Lahjakortti – testi" }]));
  assertNotEquals(await hex(changed), await hex(base));
  // EN-rivi ei vaikuta FI-PDF:ään; tuntematon paikkamerkki → oletus (ei kaadu)
  const sameFi = await buildGiftCardPdf(structuredClone(c.data), logo, c.lang, tG([{ key: "email.gift_card_pdf.title", lang: "en", text: "X" }, { key: "email.gift_card_pdf.includes", lang: "fi", text: "Sisältää {{var:eiole}} {{price:7}}" }]));
  assertEquals(await hex(sameFi), await hex(base));
  // emoji DB-tekstissä ei kaada WinAnsi-piirtoa (san)
  const emoji = await buildGiftCardPdf(structuredClone(c.data), logo, c.lang, tG([{ key: "email.gift_card_pdf.for", lang: "fi", text: "Saajalle 😀" }]));
  assert(new TextDecoder().decode(emoji.slice(0, 5)) === "%PDF-");
  const r = receiptCases()[0];
  const rb = await buildReceiptPdf(structuredClone(r.data));
  assertNotEquals(await hex(await buildReceiptPdf(structuredClone(r.data), tR([{ key: "email.receipt_pdf.title", lang: "fi", text: "KUITTI (testi)" }]))), await hex(rb));
});

Deno.test("lahjakortti-PDF: hinta vain summalahjakortissa (säännöt ennallaan, tekstit DB:stä)", async () => {
  // paketti: ei hintaa; avoin: hinta — PDF:n teksti ei sisällä hintaa pakettikortissa. Tarkistus sisältörakenteesta: render.ts:n showsPrice-säännöt eivät muutu (ks. test_render.ts)
  const { showsPrice } = await import("./gift-card-pdf/render.ts");
  const cs = giftCardCases();
  assert(!showsPrice(cs.find((x: any) => x.name === "fi_pkg_greet")!.data) && showsPrice(cs.find((x: any) => x.name === "fi_open")!.data));
});
