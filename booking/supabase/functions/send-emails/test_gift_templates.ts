import { render } from "./templates.ts";
const g = (o: any = {}) => ({ public_token: "0654361d-a2b1-43f4-a25c-8c7223907dd0", package_code: "sauna_treatment_2", package_name: "Savusaunaelämys ja saunahoito kahdelle", package_name_en: "Smoke sauna experience and sauna treatment for two", kind: "product", amount: 192, valid_to: "2027-04-01", recipient_name: "Mikko Mallikas", greeting: "Kortin tervehdys", buyer_name: "Olli Ostaja", persons: 2, locale: "fi", status: "active", delivery_to: "buyer", deliver_on: null, deliver_time: null, deliver_at: null, recipient_email: "mikko@example.invalid", cover_message: null, ...o });
const base = { functions_url: "https://x.supabase.co/functions/v1", redeem_online: false, to_name: "Mikko Mallikas" };
const sched = { delivery_to: "recipient", deliver_on: "2026-12-24", deliver_time: "14:30", deliver_at: "2026-12-24T12:30:00Z" };
const out: any[] = []; const must = (c: boolean, m: string) => { if (!c) throw new Error("FAIL " + m); };
for (const [k, d, l, check] of [
  ["gift_card_buyer", { ...base, to_name: "Olli Ostaja", gift_cards: [g(), g({ package_code: "open", kind: "value", amount: 50.5, delivery_to: "recipient" })] }, "fi", (r: any) => must(r.text.includes("PDF:") && r.text.includes("lähetetty saajalle") && r.subject.startsWith("Lahjakorttisi"), "buyer mixed")],
  ["gift_card_buyer", { ...base, to_name: "Olli Ostaja", gift_cards: [g({ delivery_to: "recipient", ...sched })] }, "fi", (r: any) => must(!r.text.includes("PDF:") && !r.html.includes("gift-card-pdf") && r.text.includes("24.12.2026 klo 14.30") && r.subject.startsWith("Lahjakorttitilauksesi vahvistus") && !r.text.includes("Kortin tervehdys"), "buyer scheduled recipient: ei PDF-linkkiä, toimituspäivä")],
  ["gift_card_buyer", { ...base, gift_cards: [g({ delivery_to: "recipient", ...sched, locale: "en" })] }, "en", (r: any) => must(r.text.includes("on 24 Dec 2026 at 14:30") && r.subject.includes("order is confirmed"), "buyer EN scheduled")],
  ["gift_card_recipient", { ...base, redeem_online: true, gift_cards: [g({ delivery_to: "recipient", cover_message: "Hei Mikko,\nTässä saate <b>&" })] }, "fi", (r: any) => must(r.text.includes("Tässä saate") && r.text.includes("— Olli Ostaja") && r.text.includes("gift-card-pdf?t=") && !r.text.includes("Kortin tervehdys") && r.html.includes("&lt;b&gt;") && !r.html.includes("<b>&"), "recipient cover")],
  ["gift_card_recipient", { ...base, gift_cards: [g({ delivery_to: "recipient", locale: "en", cover_message: null, buyer_name: null })] }, "en", (r: any) => must(r.subject.includes("received a gift card") && !r.text.includes('"'), "recipient EN no cover")],
  ["gift_card_buyer", { ...base, gift_cards: [g({ locale: "en" })] }, "en", (r: any) => must(r.text.includes("PDF:") && r.text.includes("share it only"), "buyer EN direct")],
] as any) {
  const r = render(k, d, l); check(r); out.push(r); console.log("=====", k, l, "\nSUBJECT:", r.subject, "\n" + r.text);
}
Deno.writeTextFileSync("tpl_out.html", out.map((r) => `<h3>${r.subject}</h3>` + r.html).join("<hr>"));
console.log("ALL OK");
