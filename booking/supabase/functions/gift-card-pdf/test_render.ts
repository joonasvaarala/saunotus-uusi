// Ajo: deno run -A --node-modules-dir=none test_render.ts   (kirjoittaa out_*.pdf tämän kansion viereen; OUT_DIR=... vaihtaa kohteen)
import { PDFDocument } from "npm:pdf-lib@1.17.1";
import { buildGiftCardPdf, san, sanGreeting, showsPrice } from "./render.ts";
const logo = await Deno.readFile(new URL("../../../docs/giftcards/logo.png", import.meta.url));
const seller = { name: "Havuhattu Oy / Sipoonjoen perinnesauna", legal_name: "Havuhattu Oy", business_id: "3018112-1", address: "Hindsbyntie 124", zip: "04130", city: "Sipoo", email: "savusauna@saunotus.fi", phone: "010 299 2866", web: "https://saunotus.fi" };
const longG = ("Rakas Mikko, onnea syntymäpäivänä! Toivomme että saat nauttia lämmöstä ja rauhasta yhdessä rakkaasi kanssa. Nauti löylyistä, vihdasta ja hiljaisuudesta. Kiitos kaikesta mitä olet tehnyt. Ota rennosti, ja muista juoda vettä. Nähdään pian! Tässä vielä hieman lisää tekstiä, jotta pituus täyttyy kolmeensataan merkkiin asti. Ok.").slice(0, 300);
const longEn = "Dear Mikko, happy birthday! We hope you enjoy the warmth and the quiet together with your loved one. Enjoy the steam, the birch whisk and the silence. Thank you for everything you have done. Take it easy and remember to drink water. See you soon! Here is a little more text so that the length reaches three hundred characters. Ok.".slice(0, 300);
const base = { ok: true, status: "active", currency: "EUR", locale: "fi", valid_from: "2026-10-01", valid_to: "2027-04-01", issued_at: "2026-10-01T09:00:00+03:00", seller, redeemable_now: true, source: "native" };
const pkgItems4 = [{ label: "Yleinen vuoro", label_en: "General session", persons: 4 }, { label: "Turvenaamio ja jalkakylpy", label_en: "Peat mask and foot bath", persons: 4 }, { label: "Vihtahieronta", label_en: "Whisk massage", persons: 2 }, { label: "Tee ja hunaja", label_en: "Tea and honey", persons: 4 }];
const cases: Record<string, any> = {
  fi_pkg_greet: { ...base, code: "HH3A-7CEF-HJKL", kind: "product", package_code: "sauna_treatment_2", package: { name: "Savusaunaelämys ja saunahoito kahdelle", name_en: "Smoke sauna experience and sauna treatment for two", persons: 2, is_open: false, items: [{ label: "Yleinen vuoro", label_en: "General session", persons: 2 }, { label: "Saunahoito", label_en: "Sauna treatment", persons: 2 }] }, initial_amount: 192, balance: 192, recipient_name: "Mikko Mallikas", buyer_name: "Olli Ostaja", greeting: "Hyvää syntymäpäivää, Mikko!\nNauti lämmöstä ja rauhasta yhdessä." },
  fi_pkg_long_greeting: { ...base, code: "HH9A-ECFH-JKLM", kind: "product", package_code: "peat_mask_2", package: { name: "Savusaunaelämys turvenaamiolla ja jalkakylvyllä kahdelle", name_en: "x", persons: 2, is_open: false, items: [{ label: "Yleinen vuoro", persons: 2 }, { label: "Turvenaamio ja jalkakylpy", persons: 2 }] }, initial_amount: 88, balance: 88, recipient_name: "Mikko Mallikas", buyer_name: "Olli Ostaja", greeting: longG },
  fi_pkg_4items_long_name: { ...base, code: "HH9A-ECFH-JKLM", kind: "product", package_code: "x", package: { name: "Savusaunaelämys turvenaamiolla ja jalkakylvyllä kahdelle", persons: 4, is_open: false, items: pkgItems4 }, initial_amount: 388, balance: 388, recipient_name: "Maria-Kristiina Mallikas-Esimerkkinen", buyer_name: "Olli Ostaja", greeting: longG },
  fi_open: { ...base, code: "HH7M-RTUV-WXY3", kind: "value", package_code: "open", package: { name: "Avoin lahjakortti", is_open: true, items: [] }, initial_amount: 75, balance: 75, recipient_name: "Mikko Mallikas", buyer_name: "Olli Ostaja", greeting: null },
  fi_open_partial_greet: { ...base, code: "HH7M-RTUV-WXY3", kind: "value", package_code: "open", package: { is_open: true }, initial_amount: 100, balance: 62.5, recipient_name: null, buyer_name: null, greeting: "Nauti!" },
  en_pkg_greet: { ...base, locale: "en", code: "HHCE-FHJK-LMRT", kind: "product", package_code: "sauna_treatment_2", package: { name: "Savusaunaelämys ja saunahoito kahdelle", name_en: "Smoke sauna experience and sauna treatment for two", persons: 2, is_open: false, items: [{ label: "Yleinen vuoro", label_en: "General session", persons: 2 }, { label: "Saunahoito", label_en: "Sauna treatment", persons: 2 }] }, initial_amount: 192, balance: 192, recipient_name: "Mikko Mallikas", buyer_name: "Olli Ostaja", greeting: longEn },
  en_open: { ...base, locale: "en", code: "HH7M-RTUV-WXY3", kind: "value", package_code: "open", package: { name: "Avoin lahjakortti", name_en: "Open gift card", is_open: true, items: [] }, initial_amount: 75, balance: 75, recipient_name: "Mikko Mallikas", buyer_name: "Olli Ostaja", greeting: null },
  fi_emoji_expired: { ...base, status: "expired", code: "HHAA-CCCC-EECE", kind: "value", package_code: "open", package: { is_open: true }, initial_amount: 50.5, balance: 20.25, recipient_name: "Ŝaaja Šíä", buyer_name: null, greeting: "Moi 😀🎉 hyvää joulua!\n\n\n\nÄÖÅ €uro “lainaus” – ok\u0000\u200b", redeemable_now: false },
  fi_pkg_expired: { ...base, status: "expired", code: "HH3A-7CEF-HJKL", kind: "product", package_code: "x", package: { name: "Savusaunaelämys kahdelle", persons: 2, is_open: false, items: [{ label: "Yleinen vuoro", persons: 2 }] }, initial_amount: 96, balance: 96, recipient_name: "Mikko Mallikas", buyer_name: "Olli Ostaja", greeting: "Hyvää joulua!", redeemable_now: false },
  johku_used: { ...base, source: "johku", status: "used", code: "ZZ3479ACEFHJ".replace(/(.{4})(.{4})(.{4})/, "$1-$2-$3"), kind: "product", package_code: null, package: null, initial_amount: 58, balance: 0, recipient_name: null, buyer_name: "Johku Ostaja", greeting: null, redeemable_now: false },
  fi_ei_logoa_pitka_sana: { ...base, code: "HH3A-7CEF-HJKL", kind: "value", package_code: "open", package: { is_open: true }, initial_amount: 40, balance: 40, recipient_name: "A".repeat(80), buyer_name: "B".repeat(60), greeting: "W".repeat(300) },
};
const outDir = Deno.env.get("OUT_DIR") ?? new URL(".", import.meta.url).pathname;
let fail = 0; const check = (ok: boolean, msg: string) => { if (!ok) { fail++; console.error("VIRHE:", msg); } };
for (const [k, v] of Object.entries(cases)) {
  const noLogo = k === "johku_used" || k === "fi_ei_logoa_pitka_sana";
  const b = await buildGiftCardPdf(v, noLogo ? null : logo);
  await Deno.writeFile(`${outDir}/out_${k}.pdf`, b);
  const doc = await PDFDocument.load(b); const pg = doc.getPage(0); const { width, height } = pg.getSize();
  console.log(k, b.length, "B", `${width.toFixed(1)}x${height.toFixed(1)}`, "sivuja", doc.getPageCount());
  check(new TextDecoder().decode(b.slice(0, 5)) === "%PDF-", `${k}: ei PDF`);
  check(doc.getPageCount() === 1, `${k}: sivuja ${doc.getPageCount()}`);
  check(Math.abs(width - 595.28) < 0.1 && Math.abs(height - 841.89) < 0.1, `${k}: ei A4 pysty`);
  check(b.length < 600_000, `${k}: tiedosto liian suuri ${b.length}`);
}
// 'fi'-ohitus
const b2 = await buildGiftCardPdf(cases.en_open, logo, "fi"); await Deno.writeFile(`${outDir}/out_en_open_as_fi.pdf`, b2);
const b3 = await buildGiftCardPdf(cases.fi_open, logo, "en"); await Deno.writeFile(`${outDir}/out_fi_open_as_en.pdf`, b3);
// hinta vain avoimessa summakortissa (+ Johku); paketilla ei
check(!showsPrice(cases.fi_pkg_greet) && !showsPrice(cases.en_pkg_greet) && !showsPrice(cases.fi_pkg_4items_long_name) && !showsPrice(cases.fi_pkg_expired), "paketti: hintaa ei saa näyttää");
check(showsPrice(cases.fi_open) && showsPrice(cases.en_open) && showsPrice(cases.fi_open_partial_greet) && showsPrice(cases.fi_emoji_expired), "avoin kortti: hinta näytetään");
check(showsPrice(cases.johku_used), "Johku-kortti: ennallaan (hinta näkyy)");
// siivous
check(san("Moi 😀 šäö €") === "Moi ? säö €", "san emoji/aksentti");
check(sanGreeting("a\r\n\n\n\nb  \n c") === "a\n\nb\nc", "sanGreeting rivinvaihdot");
check(san("A\u0000B\u200bC\tD") === "ABC D", "san kontrollimerkit");
console.log("san:", san("Moi 😀 šäö €"), "|", JSON.stringify(sanGreeting("a\r\n\n\n\nb  \n c")));
if (fail) { console.error(`${fail} virhettä`); Deno.exit(1); } else console.log("OK");
