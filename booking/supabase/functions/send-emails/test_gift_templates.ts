import { render } from "./templates.ts";
const g = (o: any = {}) => ({ public_token: "0654361d-a2b1-43f4-a25c-8c7223907dd0", package_code: "sauna_treatment_2", package_name: "Savusaunaelämys ja saunahoito kahdelle", package_name_en: "Smoke sauna experience and sauna treatment for two", kind: "product", amount: 192, valid_to: "2027-04-01", recipient_name: "Mikko Mallikas", greeting: "Hyvää syntymäpäivää!\nNauti <3 & rentoudu", buyer_name: "Olli Ostaja", persons: 2, locale: "fi", status: "active", ...o });
const base = { functions_url: "https://x.supabase.co/functions/v1", redeem_online: false, to_name: "Mikko Mallikas" };
const out: any[] = [];
for (const [k, d, l] of [["gift_card_buyer", { ...base, to_name: "Olli Ostaja", gift_cards: [g(), g({ package_code: "open", kind: "value", amount: 50.5 })] }, "fi"], ["gift_card_recipient", { ...base, redeem_online: true, gift_cards: [g()] }, "fi"], ["gift_card_recipient", { ...base, gift_cards: [g({ locale: "en", greeting: null, buyer_name: null })] }, "en"], ["gift_card_buyer", { ...base, gift_cards: [g({ locale: "en" })] }, "en"]] as any) {
  const r = render(k, d, l); out.push(r); console.log("=====", k, l, "\nSUBJECT:", r.subject, "\n" + r.text);
  if (!r.html.includes("<html") || r.html.includes("<3")) throw new Error("html bad");
}
Deno.writeTextFileSync("tpl_out.html", out.map((r) => `<h3>${r.subject}</h3>` + r.html).join("<hr>"));
