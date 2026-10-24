import { render } from "./templates.ts";
const g = (o: any = {}) => ({ public_token: "0654361d-a2b1-43f4-a25c-8c7223907dd0", package_code: "sauna_treatment_2", package_name: "Savusaunaelämys ja saunahoito kahdelle", package_name_en: "Smoke sauna experience and sauna treatment for two", kind: "product", amount: 192, valid_to: "2027-04-01", recipient_name: "Mikko Mallikas", greeting: "Kortin tervehdys", buyer_name: "Olli Ostaja", persons: 2, locale: "fi", status: "active", delivery_to: "buyer", deliver_on: null, deliver_time: null, deliver_at: null, recipient_email: "mikko@example.invalid", cover_message: null, ...o });
const base = { functions_url: "https://x.supabase.co/functions/v1", redeem_online: false, to_name: "Mikko Mallikas" };
const sched = { delivery_to: "recipient", deliver_on: "2026-12-24", deliver_time: "14:30", deliver_at: "2026-12-24T12:30:00Z" };
const out: any[] = []; const must = (c: boolean, m: string) => { if (!c) throw new Error("FAIL " + m); };
for (const [k, d, l, check] of [
  ["gift_card_buyer", { ...base, to_name: "Olli Ostaja", gift_cards: [g(), g({ package_code: "open", kind: "value", amount: 50.5, delivery_to: "recipient" })] }, "fi", (r: any) => must(r.text.includes("PDF:") && r.text.includes("lähetetty saajalle") && r.subject.startsWith("Lahjakorttisi"), "buyer mixed")],
  ["gift_card_buyer", { ...base, to_name: "Olli Ostaja", gift_cards: [g({ ...sched, delivery_to: "recipient" })] }, "fi", (r: any) => must(!r.text.includes("PDF:") && !r.html.includes("gift-card-pdf") && r.text.includes("24.12.2026 klo 14.30") && r.subject.startsWith("Lahjakorttitilauksesi vahvistus") && !r.text.includes("Kortin tervehdys"), "buyer scheduled recipient: ei PDF-linkkiä, toimituspäivä")],
  ["gift_card_buyer", { ...base, gift_cards: [g({ ...sched, delivery_to: "recipient", locale: "en" })] }, "en", (r: any) => must(r.text.includes("on 24 Dec 2026 at 14:30") && r.subject.includes("order is confirmed"), "buyer EN scheduled")],
  ["gift_card_recipient", { ...base, redeem_online: true, gift_cards: [g({ delivery_to: "recipient", cover_message: "Hei Mikko,\nTässä saate <b>&" })] }, "fi", (r: any) => must(r.text.includes("Tässä saate") && r.text.includes("— Olli Ostaja") && r.text.includes("gift-card-pdf?t=") && !r.text.includes("Kortin tervehdys") && r.html.includes("&lt;b&gt;") && !r.html.includes("<b>&"), "recipient cover")],
  ["gift_card_recipient", { ...base, gift_cards: [g({ delivery_to: "recipient", locale: "en", cover_message: null, buyer_name: null })] }, "en", (r: any) => must(r.subject.includes("received a gift card") && !r.text.includes('"'), "recipient EN no cover")],
  ["gift_card_recipient", { ...base, gift_cards: [g({ delivery_to: "recipient" })] }, "fi", (r: any) => must(!/192|€/.test(r.text) && !/192|€/.test(r.html.replace(/<style[\s\S]*?<\/style>/g, "")) && r.text.includes("2 henkilöä"), "saajan viestissä ei pakettihintaa")],
  ["gift_card_recipient", { ...base, gift_cards: [g({ delivery_to: "recipient", package_code: "open", kind: "value", amount: 50.5, locale: "en" })] }, "en", (r: any) => must(r.text.includes("€50.50"), "saajan viestissä avoimen kortin arvo näkyy")],
  ["gift_card_buyer", { ...base, to_name: "Olli Ostaja", gift_cards: [g()] }, "fi", (r: any) => must(r.text.includes("192"), "ostajan viestissä hinta saa näkyä")],
  ["gift_card_buyer", { ...base, gift_cards: [g({ locale: "en" })] }, "en", (r: any) => must(r.text.includes("PDF:") && r.text.includes("share it only"), "buyer EN direct")],
] as any) {
  const r = render(k, d, l); check(r); out.push(r); console.log("=====", k, l, "\nSUBJECT:", r.subject, "\n" + r.text);
}
Deno.writeTextFileSync("tpl_out.html", out.map((r) => `<h3>${r.subject}</h3>` + r.html).join("<hr>"));
console.log("ALL OK");

// ---- voucher_claim_received / voucher_claim_problem (tuotannon send-emails v6) ----
{
  const vcd = (o: any = {}) => ({ to_name: "Matti Meikäläinen", order: { order_no: 15321, order_url: "https://saunotus.fi/tilaus/?t=3f2b8c1e-7a4d-4e9b-9c55-1d2e3f4a5b6c", total: 0, items: [], reservations: [] }, voucher_claim: { claim_id: 7, status: "received", source: "elamyslahjat", code_masked: "…1234", problem_code: "invalid_code", ...o } });
  const vout: any[] = [];
  for (const [k, d, l] of [
    ["voucher_claim_received", vcd(), "fi"], ["voucher_claim_received", vcd(), "en"],
    ["voucher_claim_problem", vcd({ status: "problem" }), "fi"], ["voucher_claim_problem", vcd({ status: "problem", problem_code: "expired_code" }), "en"],
    ["voucher_claim_problem", vcd({ status: "problem", problem_code: "already_used" }), "fi"], ["voucher_claim_problem", vcd({ status: "problem", problem_code: "other" }), "en"],
  ] as any) {
    const r = render(k, d, l); vout.push(r);
    must(r.text.includes("…1234") && r.text.includes("/tilaus/?t=") && r.text.includes("Tapio"), `${k} ${l}: koodi, tilauslinkki, allekirjoitus`);
    must(!r.html.includes("tel:") && r.html.includes("mailto:"), `${k} ${l}: ei puhelinnumeroa alatunnisteessa`);
    must(!/undefined|\bnull\b|NaN/.test(r.subject + r.text + r.html), `${k} ${l}: ei tyhjiä arvoja`);
  }
  must(render("order_confirmation", { ...base, order: vcd().order, to_name: "Matti" }, "fi").html.includes("tel:"), "muiden pohjien alatunnisteessa puhelin säilyy");
  console.log("VOUCHER_CLAIM OK");
}
