// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/receipt-pdf/qty_test.ts
import { assertEquals } from "jsr:@std/assert@1";
import { lineAmounts, receiptQtyUnitFormula } from "./render.ts";

Deno.test("henkilöhinta näkyy 2 × 29,00 € = 58,00 €", () => {
  const line = { description: "Yleinen vuoro", quantity: 2, unit_gross: 29, line_gross: 58, line_net: 46.22, vat_rate: 25.5 };
  assertEquals(receiptQtyUnitFormula(line, "fi"), "2 × 29,00 € = 58,00 €");
  assertEquals(receiptQtyUnitFormula(line, "en"), "2 × 29.00 € = 58.00 €");
  assertEquals(lineAmounts(line).gross, 58);
  assertEquals(lineAmounts({ line_gross: 58, line_net: 46.22, vat_rate: 25.5 }).gross, 58);
  assertEquals(lineAmounts({ line_gross: 58, line_net: 46.22, vat_rate: 25.5 }).vat, 11.78);
});

Deno.test("pyyhe ja kiinteä hinta käyttävät omaa kappalemääräänsä", () => {
  assertEquals(receiptQtyUnitFormula({ quantity: 1, unit_gross: 5, line_gross: 5 }, "fi"), "1 × 5,00 € = 5,00 €");
  assertEquals(receiptQtyUnitFormula({ quantity: 1, unit_gross: 58, line_gross: 58 }, "fi"), "1 × 58,00 € = 58,00 €");
  assertEquals(receiptQtyUnitFormula({ quantity: 2, unit_gross: -29, line_gross: -58 }, "fi"), "2 × -29,00 € = -58,00 €");
  assertEquals(receiptQtyUnitFormula({ quantity: 2, line_gross: 58 }, "fi"), null);
});
