
// Sähköpostimallit: render(kind, data, locale) -> { subject, text, html }.
// data = booking.email_outbox_claim()-rivi (ks. docs/talous-integraatiot.md): { kind, locale, to_name, order{order_no, order_url, total, items[], reservations[]}, receipt{receipt_no, kind, text_body, total, issued_at}, payment{amount, link_url, link_expires_at} }.
// FI + EN, HTML (taulukkopohjainen, inline-tyylit, sähköpostiyhteensopiva) + tekstiversio. Ei ulkoisia riippuvuuksia (puhdas funktio, testattu node --test).
// Tyyli: tumma vihreä + hiekka, ei sinistä. Logo: sivuston /img/logo-kuitti.png (osoite johdetaan tilauslinkistä; muuten LOGO_FALLBACK).
export type Kind = "order_confirmation" | "payment_link" | "payment_link_reminder" | "receipt" | "refund_receipt" | "cancel_request_ack" | "order_change" | "gift_card_buyer" | "gift_card_recipient" | "voucher_claim_received" | "voucher_claim_problem" | "business_quote_ack" | "business_quote_notify" | "invoice_pdf" | "product_message" | "waitlist_spot_freed" | "waitlist_joined" | "annual_card_code" | "unpaid_booking_cancelled" | "event_message";
export interface Rendered { subject: string; text: string; html: string }
// Asiakasnäkyvät tekstit: texts.ts (repon oletukset = varateksti) tai tietokannasta (email.*-avaimet, _shared/site_texts.ts). render() ottaa valinnaisen tekstihaun (4. parametri).
import { makeT, type TFn } from "../_shared/site_texts.ts";
import { EMAIL_TEXTS } from "./texts.ts";
import { isRichHtml, richToText, emailHtml } from "../_shared/rich-text.js";
export { EMAIL_TEXTS };
const DEFAULT_T: TFn = makeT(EMAIL_TEXTS);
type X = (key: string, vars?: Record<string, string | number | null | undefined>) => string;

export const SELLER = "Sipoonjoen Perinnesauna";
export const COMPANY = "Havuhattu Oy";
export const ADDRESS = "Hindsbyntie 124, 04130 Sipoo";
export const EMAIL = "savusauna@saunotus.fi";
// Puhelin: näkyvä muoto kielen mukaan (fi "010 299 2866", en "+358 10 299 2866"), linkki aina tel:+358102992866. Deno-funktio ei voi tuoda repon booking/shop/src/phone.js:ää (julkaistaan erikseen) → oma kopio; templates.test.mjs vertaa sitä vakioon.
export const PHONE_FI = "010 299 2866";
export const PHONE_EN = "+358 10 299 2866";
export const phoneFor = (en: boolean) => (en ? PHONE_EN : PHONE_FI);
export const PHONE_TEL = "+358102992866";
export const LOGO_FALLBACK = "https://saunotus.fi/img/logo-kuitti.png";
const GREEN = "#1f3d2b", GREEN_SOFT = "#3d5c47", SAND = "#efe7d6", SAND_LIGHT = "#f7f2e7", SAND_LINE = "#d9ccb2", INK = "#2b2a26", MUTED = "#6f6a5d";
const FONT = "Georgia,'Times New Roman',serif", SANS = "Arial,Helvetica,sans-serif";

const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const RICH_EMAIL = {
  p: `margin:0 0 12px;font-family:${SANS};font-size:15px;line-height:1.5;color:${INK};overflow-wrap:anywhere;word-wrap:break-word`,
  h2: `margin:16px 0 8px;font-family:${FONT};font-size:20px;line-height:1.3;color:${GREEN};font-weight:normal;overflow-wrap:anywhere;word-wrap:break-word`,
  h3: `margin:14px 0 6px;font-family:${SANS};font-size:16px;line-height:1.35;color:${GREEN};font-weight:bold;overflow-wrap:anywhere;word-wrap:break-word`,
  ul: `margin:0 0 12px;padding:0 0 0 20px;font-family:${SANS};font-size:15px;line-height:1.5;color:${INK}`,
  ol: `margin:0 0 12px;padding:0 0 0 20px;font-family:${SANS};font-size:15px;line-height:1.5;color:${INK}`,
  li: `margin:0 0 4px;overflow-wrap:anywhere;word-wrap:break-word`,
  a: `color:${GREEN};text-decoration:underline;overflow-wrap:anywhere;word-break:break-all`,
};
// rich === false: pohja on pelkkää tekstiä, vaikka täytetty merkkijono näyttäisi tagilta.
// rich === true: pohja on rich. Puuttuva lippu (vanhat testit, ei viestipohjaa) päättelee merkkijonosta.
function customerHtml(raw: string, templateRich?: unknown): { text: string; html: string; rich: boolean } {
  const rich = templateRich === false ? false : templateRich === true ? true : isRichHtml(raw);
  if (!rich) return { text: raw, html: esc(raw).replace(/\n/g, "<br>"), rich: false };
  const html = emailHtml(raw, RICH_EMAIL);
  if (!html) return { text: raw, html: esc(raw).replace(/\n/g, "<br>"), rich: false };
  return { text: richToText(raw), html, rich: true };
}
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
/** Tarjouspyynnön ilmoituksessa reply-to on asiakkaan osoite, jotta siihen voi vastata suoraan. Muissa lajeissa käytetään Resendin yhteistä reply_to-asetusta. */
/** Vuosikortin koodiviestiä ei lähetetä, jos korttia ei löydy, se on peruttu tai pois käytöstä tai koodi puuttuu (booking_146). null = saa renderöidä. */
export function annualCardBlock(row: { kind?: string; annual_card?: { code?: unknown; active?: unknown; revoked?: unknown } | null } | null | undefined): string | null {
  if (row?.kind !== "annual_card_code") return null;
  const c = row.annual_card;
  if (!c) return "vuosikorttia ei löydy";
  if (c.revoked === true) return "vuosikortti on peruttu";
  if (c.active === false) return "vuosikortti ei ole käytössä";
  if (!String(c.code ?? "").trim()) return "vuosikortin koodi puuttuu";
  return null;
}
/** Muistutusta ei lähetetä, jos maksulinkki ei ole enää auki (claim poistaa link_url:n) tai tilaus on peruttu. */
export function paymentReminderBlock(row: { kind?: string; order?: { status?: unknown }; payment?: { link_url?: unknown } | null } | null | undefined): string | null {
  if (row?.kind !== "payment_link_reminder") return null;
  const st = String(row.order?.status || "");
  if (["cancelled", "expired", "draft"].includes(st)) return "tilaus ei ole lähetettävissä";
  if (!String(row.payment?.link_url || "").trim()) return "maksulinkki ei ole enää avoinna";
  return null;
}
/** Tuoteviestiä ei lähetetä, jos pohja on pois päältä, tilaus on peruttu tai hyvitetty, tai teksti on tyhjä. null = saa renderöidä. Allowlistia tämä ei koske. */
export function productMessageBlock(row: { kind?: string; order?: { status?: unknown }; product_message?: { active?: unknown; category?: unknown; marketing_consent?: unknown; order_status?: unknown; payment_status?: unknown; subject?: unknown; text?: unknown } } | null | undefined): string | null {
  if (row?.kind !== "product_message") return null;
  const pm = row.product_message || {};
  const st = String(pm.order_status || row.order?.status || "");
  const pay = String(pm.payment_status || "");
  if (pm.active === false) return "tuoteviesti ei ole käytössä";
  if (["cancelled", "expired", "draft"].includes(st)) return "tilaus ei ole lähetettävissä";
  if (pay === "refunded") return "tilaus on hyvitetty";
  if (pm.category === "after_marketing" && pm.marketing_consent !== true) return "ei markkinointilupaa";
  if (!String(pm.subject || "").trim() && !String(pm.text || "").trim()) return "tuoteviesti on tyhjä";
  return null;
}
export function outboundReplyTo(kind: string, row: { reply_to?: unknown; quote?: { email?: unknown } } | null | undefined, globalReply?: string | null): string | undefined {
  if (kind === "business_quote_notify") {
    for (const raw of [row?.reply_to, row?.quote?.email]) {
      const cand = String(raw ?? "").trim();
      if (EMAIL_RE.test(cand)) return cand;
    }
  }
  const g = String(globalReply ?? "").trim();
  return g || undefined;
}
const safeUrl = (u: unknown): string => { const s = String(u ?? "").trim(); return /^https?:\/\/[^\s"'<>]+$/i.test(s) ? s : ""; };
const NBSP = "\u00a0";
const eur = (n: unknown, en: boolean) => { const v = Number(n ?? 0); const s = Math.abs(v).toFixed(2); return (v < 0 ? "-" : "") + (en ? s : s.replace(".", ",")) + NBSP + "€"; };
const fmt = (iso: unknown, en: boolean, opts: Intl.DateTimeFormatOptions) => { const d = new Date(String(iso ?? "")); return Number.isNaN(d.getTime()) ? "" : new Intl.DateTimeFormat(en ? "en-GB" : "fi-FI", { timeZone: "Europe/Helsinki", ...opts }).format(d); };
const dt = (iso: unknown, en: boolean) => fmt(iso, en, { weekday: "short", day: "numeric", month: "numeric", year: "numeric", hour: "2-digit", minute: "2-digit" });
const tm = (iso: unknown, en: boolean) => fmt(iso, en, { hour: "2-digit", minute: "2-digit" });
const day = (iso: unknown, en: boolean) => fmt(iso, en, { day: "numeric", month: "numeric", year: "numeric" });

/** Sivuston juuri tilauslinkistä (…/tilaus/?t=…) tai maksulinkistä (…/maksa/?p=…); muuten null. */
export function siteBase(d: any): string | null {
  for (const u of [d?.order?.order_url, d?.payment?.link_url]) {
    const m = /^(https?:\/\/[^\s?#]+?)\/(?:tilaus|maksa|en\/order)\/?\?/i.exec(String(u ?? ""));
    if (m) return m[1];
  }
  return null;
}
export const logoUrl = (d: any): string => { const b = siteBase(d); return b ? `${b}/img/logo-kuitti.png` : LOGO_FALLBACK; };

// ---------- HTML-rakennuspalikat (taulukkopohjaiset) ----------
// Gmailin iOS-sovellus zoomaa viestin leveimmän kohdan mukaan. Kuitti skaalautuu, koska sen runko on
// yksi sarake ja white-space:pre-wrap. Tilausvahvistus lisää monisarakkeisen tuote/aika-taulukon ja
// pitkän tilauslinkin painikkeen alle: ne levittävät dokumentin 600px-korttia leveämmäksi, jolloin
// kortti jää noin 60 % ruudusta ja hiekkatusta täyttää reunat. Kortissa ei ole width="600"-attribuuttia
// (width="100%" + max-width:600px). Asemointi on inline-tyyleissä; @media on vain lisä.
const CELL_WRAP = "overflow-wrap:anywhere;word-wrap:break-word";
const TD_WRAP = "overflow-wrap:break-word;word-wrap:break-word";
const FLUID_TABLE = `role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:100%;table-layout:fixed;border-collapse:collapse"`;
const shownUrl = (u: string) => esc(u).replace(/([/?&=#])/g, "$1<wbr>");
const p = (html: string, extra = "") => `<tr><td style="padding:0 32px 14px 32px;font-family:${SANS};font-size:15px;line-height:1.55;color:${INK};${CELL_WRAP};${extra}">${html}</td></tr>`;
const h1 = (title: string) => `<tr><td style="padding:28px 32px 14px 32px;font-family:${FONT};font-size:24px;line-height:1.25;color:${GREEN};font-weight:normal;${CELL_WRAP}">${esc(title)}</td></tr>`;
const button = (url: string, label: string) => {
  const u = safeUrl(url); if (!u) return "";
  return `<tr><td style="padding:6px 32px 8px 32px"><table role="presentation" cellpadding="0" cellspacing="0" border="0" style="max-width:100%"><tr><td bgcolor="${GREEN}" style="border-radius:4px"><a href="${esc(u)}" style="display:inline-block;padding:12px 24px;font-family:${SANS};font-size:15px;font-weight:bold;color:${SAND_LIGHT};text-decoration:none;border-radius:4px">${esc(label)}</a></td></tr></table></td></tr>`
    + `<tr><td style="padding:6px 32px 18px 32px;font-family:${SANS};font-size:12px;line-height:1.4;color:${MUTED};word-break:break-all;overflow-wrap:anywhere;word-wrap:break-word">${shownUrl(u)}</td></tr>`;
};
const th = (s: string, align = "left", width = "") => `<td align="${align}"${width ? ` width="${width}"` : ""} style="padding:6px 8px;font-family:${SANS};font-size:12px;color:${MUTED};text-transform:uppercase;letter-spacing:.04em;border-bottom:2px solid ${SAND_LINE};${width ? `width:${width};` : ""}${TD_WRAP}">${esc(s)}</td>`;
const td = (s: string, align = "left", bold = false, width = "") => `<td align="${align}" valign="top"${width ? ` width="${width}"` : ""} style="padding:8px;font-family:${SANS};font-size:14px;line-height:1.4;color:${INK};border-bottom:1px solid ${SAND};${bold ? "font-weight:bold;" : ""}${width ? `width:${width};` : ""}${TD_WRAP}">${esc(s)}</td>`;
const box = (inner: string) => `<tr><td style="padding:0 32px 18px 32px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="${SAND_LIGHT}" style="width:100%;max-width:100%;table-layout:fixed;border-collapse:collapse;background:${SAND_LIGHT};border:1px solid ${SAND_LINE};border-radius:4px"><tr><td style="padding:12px 16px;${CELL_WRAP}">${inner}</td></tr></table></td></tr>`;

function wrapHtml(d: any, title: string, preheader: string, rows: string, en: boolean, noPhone = false): string {
  const logo = logoUrl(d);
  return `<!doctype html><html lang="${en ? "en" : "fi"}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="color-scheme" content="light"><title>${esc(title)}</title><style type="text/css">@media only screen and (max-width:620px){.email-card{width:100%!important;max-width:100%!important} }</style></head>
<body style="margin:0;padding:0;width:100%;background:${SAND};-webkit-text-size-adjust:100%;text-size-adjust:100%">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;font-size:1px;line-height:1px;color:${SAND}">${esc(preheader)}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="${SAND}" style="width:100%;background:${SAND}"><tr><td align="center" style="padding:24px 10px">
<table role="presentation" class="email-card" align="center" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#ffffff" style="width:100%;max-width:600px;margin:0 auto;background:#ffffff;border-radius:6px;border-top:4px solid ${GREEN}">
<tr><td style="padding:22px 32px 4px 32px"><table role="presentation" cellpadding="0" cellspacing="0" border="0" style="max-width:100%"><tr>
<td valign="middle" style="padding-right:12px"><img src="${esc(logo)}" width="56" alt="${esc(COMPANY)}" style="display:block;border:0;outline:none;height:auto;width:56px;max-width:100%"></td>
<td valign="middle" style="font-family:${FONT};font-size:18px;line-height:1.2;color:${GREEN};${CELL_WRAP}">${esc(SELLER)}<br><span style="font-family:${SANS};font-size:12px;color:${MUTED}">${esc(COMPANY)}</span></td>
</tr></table></td></tr>
${rows}
<tr><td style="padding:10px 32px 0 32px"><table ${FLUID_TABLE}><tr><td style="border-top:1px solid ${SAND_LINE};font-size:0;line-height:0">&nbsp;</td></tr></table></td></tr>
<tr><td style="padding:8px 32px 26px 32px;font-family:${SANS};font-size:12px;line-height:1.6;color:${MUTED};${CELL_WRAP}">${esc(SELLER)} · ${esc(COMPANY)}<br>${esc(ADDRESS)}<br><a href="mailto:${EMAIL}" style="color:${GREEN_SOFT}">${EMAIL}</a>${noPhone ? "" : ` · <a href="tel:${PHONE_TEL}" style="color:${GREEN_SOFT};text-decoration:none">${phoneFor(en)}</a>`}</td></tr>
</table></td></tr></table></body></html>`;
}

// ---------- tilaus ----------
interface Block { text: string; html: string }
// booking_50: varauksen tuotevalinta (esim. Saunahoito – Hunajahoito); r.option = {code, name, name_en} tai null
const resName = (r: any, en: boolean) => { const o = r?.option; const n = o ? String((en ? o.name_en : o.name) ?? o.name ?? "").trim() : ""; const p = String(r?.product_name ?? ""); return n ? (p ? `${p} – ${n}` : n) : p; };
function orderBlock(d: any, en: boolean, X: X): Block {
  const o = d?.order; if (!o) return { text: "", html: "" };
  const res = (o.reservations ?? []).filter((r: any) => r.status !== "cancelled");
  const items: any[] = o.items ?? [];
  const L = { order: X("email.order_block.order"), when: X("email.order_block.when"), product: X("email.order_block.product"), persons: X("email.order_block.persons"), qty: X("email.order_block.qty"),
    sum: X("email.order_block.sum"), total: X("email.order_block.total"), pers: X("email.order_block.pers"), sauna: X("email.order_block.bookings"), lines: X("email.order_block.lines") };
  const tl: string[] = [`${L.order} ${o.order_no}`];
  if (res.length) { tl.push("", `${L.sauna}:`); for (const r of res) tl.push(`  ${resName(r, en)}: ${dt(r.starts_at, en)}–${tm(r.ends_at, en)}, ${r.persons} ${L.pers}`); }
  if (items.length) { tl.push("", `${L.lines}:`); for (const i of items) tl.push(`  ${i.quantity} × ${i.name} ${eur(i.line_total, en)}`); }
  const tr = o.training;
  if (tr) {
    tl.push("", `${X("email.training.course")}: ${tr.course_price != null ? eur(tr.course_price, en) : "–"}`);
    for (const a of tr.addons || []) tl.push(`  ${a.code === "single_room" ? X("email.training.single") : a.code === "internship" ? X("email.training.internship") : a.code}: +${eur(a.price, en)}`);
    if (tr.total != null) tl.push(`${X("email.training.total")}: ${eur(tr.total, en)}`);
    if (tr.remaining != null) tl.push(`${X("email.training.remaining")}: ${eur(tr.remaining, en)}`);
    tl.push(X("email.training.balance"));
  }
  tl.push("", `${tr ? X("email.training.deposit") : L.total}: ${eur(o.total, en)}`);
  let html = `<tr><td style="padding:4px 32px 4px 32px;font-family:${FONT};font-size:17px;color:${GREEN}">${L.order} ${esc(o.order_no)}</td></tr>`;
  if (res.length) {
    html += `<tr><td style="padding:6px 32px 12px 32px"><table ${FLUID_TABLE}><tr>${th(L.product, "left", "32%")}${th(L.when, "left", "40%")}${th(L.persons, "right", "28%")}</tr>`
      + res.map((r: any) => `<tr>${td(resName(r, en), "left", false, "32%")}${td(`${dt(r.starts_at, en)}–${tm(r.ends_at, en)}`, "left", false, "40%")}${td(String(r.persons ?? ""), "right", false, "28%")}</tr>`).join("") + `</table></td></tr>`;
  }
  if (items.length) {
    html += `<tr><td style="padding:6px 32px 8px 32px"><table ${FLUID_TABLE}><tr>${th(L.product, "left", "62%")}${th(L.qty, "right", "14%")}${th(L.sum, "right", "24%")}</tr>`
      + items.map((i: any) => `<tr>${td(String(i.name ?? ""), "left", false, "62%")}${td(String(i.quantity ?? ""), "right", false, "14%")}${td(eur(i.line_total, en), "right", false, "24%")}</tr>`).join("")
      + `<tr><td colspan="2" align="right" style="padding:10px 8px;font-family:${SANS};font-size:15px;font-weight:bold;color:${GREEN};${TD_WRAP}">${tr ? esc(X("email.training.deposit")) : L.total}</td><td align="right" width="24%" style="padding:10px 8px;font-family:${SANS};font-size:15px;font-weight:bold;color:${GREEN};width:24%;${TD_WRAP}">${esc(eur(o.total, en))}</td></tr></table></td></tr>`;
    if (tr) html += p(esc(X("email.training.balance")));
  } else {
    html += p(`<b>${tr ? esc(X("email.training.deposit")) : L.total}: ${esc(eur(o.total, en))}</b>`);
    if (tr) html += p(esc(X("email.training.balance")));
  }
  return { text: tl.join("\n") + "\n", html };
}

const textBlock = (...parts: (string | undefined | false)[]) => parts.filter((x) => typeof x === "string" && x !== "").join("\n\n");
function instructionNotes(list: unknown, title: string): { text: string; html: string } {
  const rows = (Array.isArray(list) ? list : []).map((row) => {
    const item = row as { title?: unknown; text?: unknown; rich?: unknown };
    const raw = String(item?.text ?? "").trim();
    const head = String(item?.title ?? "").trim();
    if (!raw) return null;
    const body = customerHtml(raw, item.rich);
    return { head, text: body.text, html: body.html };
  }).filter((row): row is { head: string; text: string; html: string } => !!row);
  if (!rows.length) return { text: "", html: "" };
  const text = [title, ...rows.map((row) => [row.head, row.text].filter(Boolean).join("\n"))].join("\n\n");
  const html = box(`<span style="font-family:${SANS};font-size:12px;color:${MUTED};text-transform:uppercase;letter-spacing:.04em">${esc(title)}</span><br><br>`
    + rows.map((row) => `<span style="font-family:${SANS};font-size:14px;line-height:1.5;color:${INK};${CELL_WRAP}">${row.head ? `<b>${esc(row.head)}</b><br>` : ""}${row.html}</span>`).join("<br><br>"));
  return { text, html };
}


// ---------- lahjakortit (gift_card_buyer / gift_card_recipient) ----------
// data.gift_cards[]: { public_token, package_code, package_name(_en), kind, amount, valid_to, recipient_name, greeting, buyer_name, persons, locale, status }
// delivery_to ('buyer'|'recipient'), deliver_on/deliver_time/deliver_at (ajastus), recipient_email (vain ostajan viestissä), cover_message (vain saajan viestissä; EI kortti-PDF:ssä).
// + data.functions_url (…/functions/v1) ja data.redeem_online (lunastus verkossa päällä?) joita send-emails/index.ts lisää. Koodia EI ole viestissä, vain PDF-linkki.
const gcAmt = (n: unknown, en: boolean) => { const x = Number(n ?? 0); const w = Math.abs(x - Math.round(x)) < 0.005; const v = w ? String(Math.round(x)) : x.toFixed(2); return en ? `€${v}` : `${v.replace(".", ",")}${NBSP}€`; };
const gcDate = (s: unknown, en: boolean) => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(s ?? "")); if (!m) return ""; return en ? new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", day: "numeric", month: "short", year: "numeric" }).format(new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], 12))) : `${+m[3]}.${+m[2]}.${m[1]}`; };
const gcOpen = (g: any) => g?.package_code === "open" || (g?.kind === "value" && !g?.package_code);
const gcTitle = (g: any, en: boolean, X: X) => gcOpen(g) ? X("email.gift_card.card_open") : String((en ? g?.package_name_en : g?.package_name) ?? g?.package_name ?? X("email.gift_card.card_default"));
const gcUrl = (d: any, g: any, en: boolean) => safeUrl(`${d?.functions_url ?? ""}/gift-card-pdf?t=${g?.public_token}&lang=${en ? "en" : "fi"}`);

function giftCardMail(kind: "gift_card_buyer" | "gift_card_recipient", d: any, en: boolean, hello: string, sign: string, signHtml: string, X: X): Rendered {
  const cards: any[] = (d?.gift_cards ?? []).filter((g: any) => g?.public_token);
  const n = cards.length, buyer = kind === "gift_card_buyer", c0 = cards[0] ?? {};
  const from = c0.buyer_name ? String(c0.buyer_name).trim() : "";
  // ostaja valitsee toimitustavan: 'buyer' = kortti ostajalle (PDF-linkki tässä viestissä), 'recipient' = suoraan saajalle (ei PDF-linkkiä ostajalle)
  const toBuyer = (g: any) => (g?.delivery_to ?? "buyer") !== "recipient";
  const anyBuyer = cards.some(toBuyer), anyRecip = cards.some((g) => !toBuyer(g));
  const subject = buyer ? (anyBuyer ? X(n > 1 ? "email.gift_card.subject_buyer_many" : "email.gift_card.subject_buyer") : X("email.gift_card.subject_buyer_to_recipient"))
    : from ? X("email.gift_card.subject_recipient_from", { from }) : X("email.gift_card.subject_recipient");
  const title = buyer ? (anyBuyer ? X("email.gift_card.title_buyer") : X("email.gift_card.title_buyer_to_recipient")) : X("email.gift_card.title_recipient");
  const intro = buyer
    ? (anyBuyer ? X(n > 1 ? "email.gift_card.intro_buyer_many" : "email.gift_card.intro_buyer") : X(n > 1 ? "email.gift_card.intro_buyer_to_recipient_many" : "email.gift_card.intro_buyer_to_recipient"))
    : X("email.gift_card.intro_recipient", { from: from || X("email.gift_card.someone") });
  const how = d?.redeem_online ? X("email.gift_card.how_online") : X("email.gift_card.how_offline");
  const note = buyer && anyBuyer ? X("email.gift_card.note_share") : "";
  const recipNote = buyer && anyRecip ? X("email.gift_card.note_recipient_separate") : "";
  const cover = !buyer && c0.cover_message ? String(c0.cover_message).trim() : "";   // saateteksti: vain sähköpostissa, ei kortti-PDF:ssä
  const contact = X("email.common.contact", { phone: phoneFor(en) });
  const tl: string[] = []; let rows = h1(title) + p(esc(hello)) + p(esc(intro));
  if (cover) rows += `<tr><td style="padding:0 32px 18px 32px"><table ${FLUID_TABLE}><tr><td style="padding:10px 16px;border-left:3px solid #c49a6c;font-family:${FONT};font-style:italic;font-size:17px;line-height:1.45;color:${INK};${CELL_WRAP}">${esc(cover).replace(/\n/g, "<br>")}${from ? `<br><span style="font-family:${SANS};font-style:normal;font-size:13px;color:${MUTED}">— ${esc(from)}</span>` : ""}</td></tr></table></td></tr>`;
  const hhmm = (s: string) => en ? s : s.replace(":", ".");
  for (const g of cards) {
    const url = gcUrl(d, g, en);
    const showAmt = buyer || gcOpen(g) || !g.package_code;   // saajan viestissä ei pakettihintaa (vain avoimen kortin arvo); ostajan vahvistuksessa hinta saa näkyä
    const meta = [showAmt ? gcAmt(g.amount, en) : "", g.persons && !gcOpen(g) ? X("email.gift_card.meta_persons", { n: g.persons }) : "", g.valid_to ? X("email.gift_card.meta_valid", { date: gcDate(g.valid_to, en) }) : "", buyer && g.recipient_name ? X("email.gift_card.meta_for", { name: g.recipient_name }) : ""].filter(Boolean).join(" · ");
    const who = [g.recipient_name, g.recipient_email].filter(Boolean).join(", ");
    const when = g.deliver_at ? (g.deliver_time ? X("email.gift_card.when_at", { date: gcDate(g.deliver_on, en), time: en ? g.deliver_time : hhmm(g.deliver_time) }) : gcDate(g.deliver_on, en)) : "";
    const deliv = !buyer || toBuyer(g) ? "" : g.deliver_at
      ? X("email.gift_card.delivery_scheduled", { who, when })
      : X("email.gift_card.delivery_sent", { who });
    const showLink = !buyer || toBuyer(g);
    tl.push(`• ${gcTitle(g, en, X)}\n  ${meta}${deliv ? `\n  ${deliv}` : ""}${showLink ? `\n  PDF: ${url}` : ""}`);
    rows += box(`<span style="font-family:${FONT};font-size:19px;color:${GREEN}">${esc(gcTitle(g, en, X))}</span><br><span style="font-family:${SANS};font-size:13px;color:${MUTED}">${esc(meta)}</span>${deliv ? `<br><span style="font-family:${SANS};font-size:14px;color:${INK}">${esc(deliv)}</span>` : ""}`) + (showLink && url ? button(url, X("email.gift_card.open_button")) : "");
  }
  const showHow = !buyer || anyBuyer;
  rows += (showHow ? p(esc(how)) : "") + (note ? p(esc(note), `color:${MUTED};font-size:13px`) : "") + (recipNote ? p(esc(recipNote), `color:${MUTED};font-size:13px`) : "") + p(esc(contact), `color:${MUTED};font-size:13px`) + p(signHtml);
  const text = textBlock(hello, intro, cover && `"${cover}"${from ? `\n— ${from}` : ""}`, tl.join("\n\n"), showHow && how, note, recipNote, contact, sign) + "\n";
  return { subject, text, html: wrapHtml(d, title, intro, rows, en) };
}


// ---------- kumppanilahjakorttien lunastuspyynnöt (voucher_claim_received / voucher_claim_problem) ----------
// data.voucher_claim: { claim_id, status, source, code_masked ("…1234"), problem_code (invalid_code|expired_code|already_used|other), customer_name } + data.order (order_url, varaukset). Täyttä koodia ei viesteissä.
// booking_48: varaus ei vanhene lunastuspyynnön vuoksi -> viesteissä EI aikarajoja eikä "aika on pidetty varattuna … asti" (hold_until on poistettu käytöstä; kenttää ei lueta).
// Ongelmaviesti: yhteystieto vain sähköposti (ei puhelinnumeroa, ei alatunnisteessakaan). booking_176: ongelmaviestiä ei jonoteta automaattisesti lainkaan (_vc_notify_problem pois).
// booking_176: voucher_claim_received = kumppanilahjakorttivarauksen AINOA varausvahvistus (korvaa "Kiitos lahjakorttivarauksesta" -viestin, tilausvahvistuksen ja erillisen ohjeviestin):
//   aika varattu + lahjakortti tarkistetaan + "Olemme sinuun yhteydessä, jos …", tiivis ohjelaatikko (order.instructions, email_outbox_claim), linkki koko ohjeeseen ja tilaussivulle, puhelin näkyy.
// Allekirjoitus: Tapio / Sipoonjoen Perinnesauna.
const VC_SOURCES = ["elamyslahjat", "kokemuskauppa", "kiitoskauppa", "offerilla"];   // kumppanien nimet: email.voucher.partner_<lähde>
function voucherMail(kind: "voucher_claim_received" | "voucher_claim_problem", d: any, en: boolean, hello: string, X: X): Rendered {
  const vc = d?.voucher_claim ?? {};
  const label = VC_SOURCES.includes(String(vc.source ?? "")) ? X(`email.voucher.partner_${vc.source}`) : X("email.voucher.partner_other");
  const masked = String(vc.code_masked ?? "").trim();
  const what = masked ? X("email.voucher.what_with_code", { label, code: masked }) : label;
  const orderUrl = safeUrl(d?.order?.order_url);
  const ob = orderBlock(d, en, X);
  const sign = `${X("email.common.closing")}\n${X("email.voucher.sign_name")}\n${SELLER}`;
  const signHtml = esc(sign).replace(/\n/g, "<br>");
  const contact = X("email.voucher.contact", { email: EMAIL });
  const viewLabel = X("email.voucher.view_order");
  const V = { what, label, email: EMAIL };
  let subject: string, title: string, paras: string[];
  if (kind === "voucher_claim_received") return voucherConfirmMail(d, en, hello, X, { what, orderUrl, ob, sign, signHtml });
  {
    const how = X("email.voucher.problem_how");
    switch (vc.problem_code) {
      case "expired_code":
        subject = X("email.voucher.expired_subject");
        title = X("email.voucher.expired_title");
        paras = [X("email.voucher.expired_p1", V), X("email.voucher.expired_p2", V)];
        break;
      case "already_used":
        subject = X("email.voucher.used_subject");
        title = X("email.voucher.used_title");
        paras = [X("email.voucher.used_p1", V), X("email.voucher.used_p2", V), X("email.voucher.used_p3")];
        break;
      case "invalid_code":
        subject = X("email.voucher.invalid_subject");
        title = X("email.voucher.invalid_title");
        paras = [X("email.voucher.invalid_p1", V), how];
        break;
      default:
        subject = X("email.voucher.other_subject");
        title = X("email.voucher.other_title");
        paras = [X("email.voucher.other_p1", V)];
    }
  }
  paras = paras.filter(Boolean);
  const more = X("email.voucher.more_problem");
  const text = textBlock(hello, ...paras, ob.text, orderUrl && `${more}\n${orderUrl}`, contact, sign) + "\n";
  const html = wrapHtml(d, title, paras[0], h1(title) + p(esc(hello)) + paras.map((x) => p(esc(x))).join("") + ob.html + (orderUrl ? p(esc(more)) + button(orderUrl, viewLabel) : "") + p(esc(contact), `color:${MUTED};font-size:13px`) + p(signHtml), en, true);
  return { subject, text, html };
}

// booking_176: kumppanilahjakorttivarauksen varausvahvistus (yksi viesti heti varauksen jälkeen). Koko ohje: tilaussivun ohjeosio (#ord-g).
function voucherConfirmMail(d: any, en: boolean, hello: string, X: X, c: { what: string; orderUrl: string; ob: Block; sign: string; signHtml: string }): Rendered {
  const no = d?.order?.order_no ?? "";
  const subject = X("email.voucher.confirm_subject", { no });
  const title = X("email.voucher.confirm_title");
  const paras = [X("email.voucher.confirm_reserved", { what: c.what }), X("email.voucher.confirm_check"), X("email.voucher.confirm_problem")].filter(Boolean);
  const notes = instructionNotes(d?.order?.instructions, X("email.voucher.confirm_guide_title"));
  const guideUrl = notes.text && c.orderUrl ? `${c.orderUrl}#ord-g` : "";
  const guide = X("email.voucher.confirm_guide");
  const more = X("email.voucher.confirm_more");
  const contact = X("email.common.contact", { phone: phoneFor(en) });
  const text = textBlock(hello, ...paras, c.ob.text, notes.text, guideUrl && `${guide}:\n${guideUrl}`, c.orderUrl && `${more}\n${c.orderUrl}`, contact, c.sign) + "\n";
  const html = wrapHtml(d, title, paras[0], h1(title) + p(esc(hello)) + paras.map((x) => p(esc(x))).join("") + c.ob.html + notes.html + (guideUrl ? button(guideUrl, guide) : "")
    + (c.orderUrl ? p(esc(more)) + button(c.orderUrl, X("email.voucher.view_order")) : "") + p(esc(contact), `color:${MUTED};font-size:13px`) + p(c.signHtml), en);
  return { subject, text, html };
}

// Asiakkaan kuittaus (booking_75). Ei hintaa eikä vahvistettua ajankohtaa. Allekirjoitus: Tapio. Lähetystila (dry_run) on index.ts:ssä.
function businessQuoteMail(d: any, en: boolean, hello: string, X: X): Rendered {
  const subject = X("email.business_quote.ack_subject");
  const title = X("email.business_quote.ack_title");
  const intro = X("email.business_quote.ack_intro");
  const extra = X("email.business_quote.no_promise");
  const sign = `${X("email.common.closing")}\n${X("email.business_quote.sign_name")}\n${SELLER}`;
  const signHtml = esc(sign).replace(/\n/g, "<br>");
  const contact = X("email.common.contact", { phone: phoneFor(en) });
  const text = textBlock(hello, intro, extra, contact, sign) + "\n";
  const html = wrapHtml(d, title, intro, h1(title) + p(esc(hello)) + p(esc(intro)) + p(esc(extra)) + p(esc(contact), `color:${MUTED};font-size:13px`) + p(signHtml), en);
  return { subject, text, html };
}

const OFFERING_ORDER = ["ritual", "forest_yoga", "campfire_meal", "sauna", "vihta_workshop", "other"] as const;
function offeringLine(q: any, X: X): string {
  const list = Array.isArray(q?.offerings) ? q.offerings.map((x: unknown) => String(x)) : [];
  const known = new Set<string>(OFFERING_ORDER);
  const named = OFFERING_ORDER.filter((c) => list.includes(c)).map((c) => {
    const name = X(`email.business_quote.offering_${c}`);
    if (c !== "other") return name;
    const extra = String(q?.offering_other ?? "").trim();
    return extra ? `${name}: ${extra}` : name;
  });
  const rest = list.filter((c) => !known.has(c));
  return [...named, ...rest].join(", ");
}

// Henkilökunnan ilmoitus. Teksti on aina suomeksi. d.quote = email_outbox_claim()-lohko (myös jonon payloadissa).
function businessQuoteNotify(d: any, hello: string, X: X): Rendered {
  const q = d?.quote && typeof d.quote === "object" ? d.quote : {};
  const dash = "—";
  const show = (v: unknown) => { const s = String(v ?? "").trim(); return s ? s : dash; };
  const personsN = q.persons == null || String(q.persons).trim() === "" ? "" : String(q.persons).trim();
  const persons = personsN ? X("email.business_quote.persons_value", { n: personsN }) : dash;
  const offerings = offeringLine(q, X) || dash;
  const locFi = X("email.business_quote.locale_fi");
  const locEn = X("email.business_quote.locale_en");
  const locale = String(q.locale ?? "").trim().toLowerCase() === "en" ? locEn : locFi;
  const sent = (q.created_at ? dt(q.created_at, false) : "") || dash;
  const id = q.id == null || String(q.id).trim() === "" ? dash : String(q.id);
  const rows: [string, string][] = [
    [X("email.business_quote.field_company"), show(q.company_name)],
    [X("email.business_quote.field_contact"), show(q.contact_name)],
    [X("email.business_quote.field_email"), show(q.email)],
    [X("email.business_quote.field_phone"), show(q.phone)],
    [X("email.business_quote.field_persons"), persons],
    [X("email.business_quote.field_offerings"), offerings],
    [X("email.business_quote.field_when"), show(q.preferred_when)],
    [X("email.business_quote.field_message"), show(q.message)],
    [X("email.business_quote.field_locale"), locale],
    [X("email.business_quote.field_sent"), sent],
    [X("email.business_quote.field_id"), id],
  ];
  const lines = rows.map(([k, v]) => `${k}: ${v}`).join("\n");
  const subject = X("email.business_quote.notify_subject_detail", { company: show(q.company_name), persons: personsN || dash, when: show(q.preferred_when) }).replace(/\s+/g, " ");
  const title = X("email.business_quote.notify_title_detail");
  const intro = X("email.business_quote.notify_intro_detail");
  const sign = `${X("email.common.closing")}\n${X("email.business_quote.sign_name")}\n${SELLER}`;
  const signHtml = esc(sign).replace(/\n/g, "<br>");
  const contact = X("email.common.contact", { phone: phoneFor(false) });
  const text = textBlock(hello, intro, lines, contact, sign) + "\n";
  const htmlLines = rows.map(([k, v]) => `<span style="font-family:${SANS};font-size:14px;line-height:1.45;color:${INK}"><b>${esc(k)}</b>: ${esc(v).replace(/\n/g, "<br>")}</span>`).join("<br>");
  const html = wrapHtml(d, title, intro, h1(title) + p(esc(hello)) + p(esc(intro)) + box(htmlLines) + p(esc(contact), `color:${MUTED};font-size:13px`) + p(signHtml), false);
  return { subject, text, html };
}

// booking_176: lahjakortti kattaa vain osan → YKSI yhdistetty viesti: lunastettu ja varaus vahvistettu, summa / lahjakortin arvo / erotus, Maksa nyt. Erotuksen maksusta ei kuittisähköpostia (kuitti tilaussivulla).
function voucherDifferenceMail(d: any, en: boolean, hello: string, X: X, v: { no: string | number; total: string; voucher: string; difference: string }, c: { url: string; expires: string; ob: Block; contact: string }): Rendered {
  const subject = X("email.payment_link.voucher_subject", v);
  const title = X("email.voucher.difference_title");
  const confirmed = X("email.voucher.difference_confirmed");
  const intro = X("email.payment_link.voucher_intro", v);
  const receipt = X("email.voucher.difference_receipt");
  const exp = c.expires ? X("email.payment_link.expires", { date: c.expires }) : "";
  const pay = X("email.payment_link.pay_button");
  const L = { total: X("email.voucher.difference_total_label"), voucher: X("email.voucher.difference_voucher_label"), diff: X("email.payment_link.voucher_amount_label") };
  const sign = `${X("email.common.closing")}\n${X("email.payment_link.sign_name")}\n${SELLER}`;
  const lines = `${L.total}: ${v.total}\n${L.voucher}: ${v.voucher}\n${L.diff}: ${v.difference}`;
  const text = textBlock(hello, confirmed, intro, lines, c.url && `${pay}:\n${c.url}`, exp, receipt, c.ob.text, c.contact, sign) + "\n";
  const row = (k: string, val: string, big = false) => `<tr><td style="padding:4px 0;font-family:${SANS};font-size:14px;color:${big ? GREEN : INK};${big ? "font-weight:bold;" : ""}${CELL_WRAP}">${esc(k)}</td><td align="right" width="46%" style="padding:4px 0;font-family:${big ? FONT : SANS};font-size:${big ? 22 : 14}px;color:${big ? GREEN : INK};width:46%;${CELL_WRAP}">${esc(val)}</td></tr>`;
  const sums = box(`<table ${FLUID_TABLE}>${row(L.total, v.total)}${row(L.voucher, v.voucher)}${row(L.diff, v.difference, true)}</table>`);
  const html = wrapHtml(d, title, confirmed, h1(title) + p(esc(hello)) + p(esc(confirmed)) + p(esc(intro)) + sums + (c.url ? button(c.url, pay) : "") + (exp ? p(esc(exp), `color:${MUTED};font-size:13px`) : "")
    + p(esc(receipt), `color:${MUTED};font-size:13px`) + c.ob.html + p(esc(c.contact), `color:${MUTED};font-size:13px`) + p(esc(sign).replace(/\n/g, "<br>")), en);
  return { subject, text, html };
}

export function render(kind: Kind, d: any, locale?: string, t: TFn = DEFAULT_T): Rendered {
  const en = (locale ?? d?.locale) === "en";
  const X: X = (key, vars) => t(key, en ? "en" : "fi", vars);
  const first = d?.to_name ? String(d.to_name).trim().split(/\s+/)[0] : "";
  const hello = first ? X("email.common.hello", { name: first }) : X("email.common.hello_anon");
  const no = d?.order?.order_no ?? "";
  const ob = orderBlock(d, en, X);
  const orderUrl = safeUrl(d?.order?.order_url);
  const sign = `${X("email.common.closing")}\n${SELLER}\n${COMPANY}`;
  const signHtml = esc(sign).replace(/\n/g, "<br>");
  const viewLabel = X("email.common.view_order");
  const yourOrder = X("email.common.your_order");
  const contact = X("email.common.contact", { phone: phoneFor(en) });
  const helloRow = p(esc(hello));
  const tail = `${p(esc(contact), `color:${MUTED};font-size:13px`)}${p(signHtml)}`;
  const mk = (title: string, preheader: string, rows: string) => wrapHtml(d, title, preheader, rows, en);

  switch (kind) {
    case "gift_card_buyer":
    case "gift_card_recipient":
      return giftCardMail(kind, d, en, hello, sign, signHtml, X);
    case "voucher_claim_received":
    case "voucher_claim_problem":
      return voucherMail(kind, d, en, hello, X);
    case "order_confirmation": {
      const subject = X("email.order_confirmation.subject", { no });
      const intro = d?.order?.training ? X("email.training.intro") : X("email.order_confirmation.intro");
      const more = X("email.order_confirmation.more");
      const title = X("email.order_confirmation.title");
      const notes = instructionNotes(d?.order?.instructions, X("email.order_confirmation.instructions_title"));
      const text = textBlock(hello, intro, ob.text, notes.text, orderUrl && `${more}\n${orderUrl}`, contact, sign) + "\n";
      const html = mk(title, intro, h1(title) + helloRow + p(esc(intro)) + ob.html + notes.html + (orderUrl ? p(esc(more)) + button(orderUrl, viewLabel) : "") + tail);
      return { subject, text, html };
    }
    case "product_message": {
      const pm = d?.product_message || {};
      const subject = String(pm.subject || "").replace(/[<>]/g, "").replace(/\s+/g, " ").trim() || X("email.product_message.subject_fallback", { no });
      const body = String(pm.text || "").trim();
      const shown = customerHtml(body, pm.rich);
      const rawLink = String(pm.link_url || "").trim();
      const link = /^https:\/\/\S+$/.test(rawLink) ? rawLink : "";
      const linkLabel = X("email.product_message.open_link");
      const rawUnsub = pm.category === "after_marketing" ? String(pm.unsubscribe_url || "").trim() : "";
      const unsub = /^https:\/\/\S+$/.test(rawUnsub) ? rawUnsub : "";
      const unsubLabel = unsub ? X("email.product_message.unsubscribe") : "";
      const pre = (shown.rich ? shown.text.replace(/\s+/g, " ").trim() : body).slice(0, 140);
      const bodyRow = body ? (shown.rich ? `<tr><td style="padding:0 32px 14px 32px;${CELL_WRAP}">${shown.html}</td></tr>` : p(shown.html)) : "";
      const text = textBlock(hello, shown.text, link, orderUrl && `${viewLabel}:\n${orderUrl}`, unsub && `${unsubLabel}\n${unsub}`, contact, sign) + "\n";
      const html = mk(subject, pre || subject, h1(subject) + helloRow + bodyRow + (link ? button(link, linkLabel) : "") + (orderUrl ? button(orderUrl, viewLabel) : "") + (unsub ? p(`<a href="${esc(unsub)}" style="color:${MUTED};font-size:13px">${esc(unsubLabel)}</a>`, `color:${MUTED};font-size:13px`) : "") + tail);
      return { subject, text, html };
    }
    case "payment_link": {
      const url = safeUrl(d?.payment?.link_url) || orderUrl;
      const amount = eur(d?.payment?.amount, en);
      const expires = d?.payment?.link_expires_at ? day(d.payment.link_expires_at, en) : "";
      // booking_174: kumppanilahjakortin erotus (email_outbox_claim → voucher_difference {total, voucher_value, difference}); muuten tavallinen maksulinkki
      const vd = d?.voucher_difference;
      const vdOk = !!vd && [vd.total, vd.voucher_value, vd.difference].every((v: unknown) => v != null && v !== "" && Number.isFinite(Number(v))) && Number(vd.difference) > 0;
      const vdVars = vdOk ? { no, total: eur(vd.total, en), voucher: eur(vd.voucher_value, en), difference: eur(vd.difference, en) } : null;
      if (vdVars) return voucherDifferenceMail(d, en, hello, X, vdVars, { url, expires, ob, contact });
      const subject = X("email.payment_link.subject", { no });
      const intro = X("email.payment_link.intro", { amount });
      const exp = expires ? X("email.payment_link.expires", { date: expires }) : "";
      const title = X("email.payment_link.title");
      const lab = X("email.payment_link.amount_label");
      const pay = X("email.payment_link.pay_button");
      const linkSign = `${X("email.common.closing")}\n${X("email.payment_link.sign_name")}\n${SELLER}`;
      const linkTail = `${p(esc(contact), `color:${MUTED};font-size:13px`)}${p(esc(linkSign).replace(/\n/g, "<br>"))}`;
      const text = textBlock(hello, intro, url && `${title}:\n${url}`, exp, ob.text, contact, linkSign) + "\n";
      const html = mk(title, intro, h1(title) + helloRow + p(esc(intro)) + box(`<span style="font-family:${SANS};font-size:12px;color:${MUTED};text-transform:uppercase;letter-spacing:.04em">${esc(lab)}</span><br><span style="font-family:${FONT};font-size:24px;color:${GREEN}">${esc(amount)}</span>`)
        + (url ? button(url, pay) : "") + (exp ? p(esc(exp), `color:${MUTED};font-size:13px`) : "") + ob.html + linkTail);
      return { subject, text, html };
    }
    case "payment_link_reminder": {
      // booking_215: sama maksulinkki kuin payment_link-pohjassa. Asiakas ei näe maksuvälittäjän nimeä (painike: Maksa verkossa). Allekirjoitus Tapio.
      const url = safeUrl(d?.payment?.link_url) || orderUrl;
      const amount = eur(d?.payment?.amount, en);
      const pr = d?.payment_reminder || {};
      const cancel = pr.cancel_if_unpaid === true;
      const due = cancel && d?.payment?.link_expires_at ? day(d.payment.link_expires_at, en) : "";
      const subject = X("email.payment_link_reminder.subject", { no });
      const intro = X("email.payment_link_reminder.intro", { amount });
      const warn = due ? X("email.payment_link_reminder.cancel", { date: due }) : "";
      const title = X("email.payment_link_reminder.title");
      const lab = X("email.payment_link.amount_label");
      const pay = X("email.payment_link_reminder.pay_button");
      const linkSign = `${X("email.common.closing")}\n${X("email.payment_link.sign_name")}\n${SELLER}`;
      const linkTail = `${p(esc(contact), `color:${MUTED};font-size:13px`)}${p(esc(linkSign).replace(/\n/g, "<br>"))}`;
      const text = textBlock(hello, intro, warn, url && `${pay}:\n${url}`, ob.text, contact, linkSign) + "\n";
      const html = mk(title, intro, h1(title) + helloRow + p(esc(intro)) + box(`<span style="font-family:${SANS};font-size:12px;color:${MUTED};text-transform:uppercase;letter-spacing:.04em">${esc(lab)}</span><br><span style="font-family:${FONT};font-size:24px;color:${GREEN}">${esc(amount)}</span>`)
        + (warn ? p(esc(warn)) : "") + (url ? button(url, pay) : "") + ob.html + linkTail);
      return { subject, text, html };
    }
    case "receipt":
    case "refund_receipt": {
      const r = d?.receipt; const refund = kind === "refund_receipt";
      const rno = r?.receipt_no ?? "";
      const ns = refund ? "email.refund_receipt" : "email.receipt";
      const subject = X(`${ns}.subject`, { no: rno });
      const amount = r?.total != null ? eur(Math.abs(Number(r.total)), en) : "";
      const intro = refund ? (amount ? X("email.refund_receipt.intro_amount", { amount }) : X("email.refund_receipt.intro")) : X("email.receipt.intro");
      const title = X(`${ns}.title`);
      const body = String(r?.text_body ?? "").trim();
      const meta = [rno && `${X("email.receipt.meta_no")}: ${rno}`, r?.issued_at && `${X("email.receipt.meta_date")}: ${day(r.issued_at, en)}`, amount && `${refund ? X("email.refund_receipt.meta_refunded") : X("email.receipt.meta_paid")}: ${amount}`].filter(Boolean) as string[];
      const text = textBlock(hello, intro, meta.join("\n"), body, orderUrl && `${yourOrder}: ${orderUrl}`, contact, sign) + "\n";
      const html = mk(title, intro, h1(title) + helloRow + p(esc(intro))
        + (meta.length ? box(meta.map((m) => `<span style="font-family:${SANS};font-size:14px;color:${INK}">${esc(m)}</span>`).join("<br>")) : "")
        + (body ? `<tr><td style="padding:0 32px 18px 32px"><table ${FLUID_TABLE}><tr><td style="padding:12px 14px;background:${SAND_LIGHT};border:1px solid ${SAND_LINE};border-radius:4px;font-family:Consolas,'Courier New',monospace;font-size:12px;line-height:1.5;color:${INK};white-space:pre-wrap;${CELL_WRAP}">${esc(body)}</td></tr></table></td></tr>` : "")
        + (orderUrl ? button(orderUrl, viewLabel) : "") + tail);
      return { subject, text, html };
    }
    case "cancel_request_ack": {
      const subject = X("email.cancel_request_ack.subject", { no });
      const msg = X("email.cancel_request_ack.message");
      const title = X("email.cancel_request_ack.title");
      const text = textBlock(hello, msg, ob.text, orderUrl && `${yourOrder}: ${orderUrl}`, contact, sign) + "\n";
      return { subject, text, html: mk(title, msg, h1(title) + helloRow + p(esc(msg)) + ob.html + (orderUrl ? button(orderUrl, viewLabel) : "") + tail) };
    }
    case "business_quote_ack":
      return businessQuoteMail(d, en, hello, X);
    case "business_quote_notify": {
      const Xfi: X = (key, vars) => t(key, "fi", vars);
      const firstFi = d?.to_name ? String(d.to_name).trim().split(/\s+/)[0] : "";
      const helloFi = firstFi ? t("email.common.hello", "fi", { name: firstFi }) : t("email.common.hello_anon", "fi");
      return businessQuoteNotify(d, helloFi, Xfi);
    }
    case "invoice_pdf": {
      const inv = d?.invoice;
      const ino = inv?.invoice_no ?? "";
      const amount = inv?.total != null ? eur(inv.total, en) : "";
      const due = inv?.due_date ? day(inv.due_date, en) : "";
      const subject = X("email.invoice.subject", { no: ino });
      const title = X("email.invoice.title");
      const intro = X("email.invoice.intro", { no: ino, amount, date: due });
      const attach = X("email.invoice.attach");
      const terms = X("email.invoice.terms");
      const ref = inv?.reference_no ? `${X("email.receipt.meta_no")}: ${inv.reference_no}` : "";
      const text = textBlock(hello, intro, attach, ref, terms, contact, sign) + "\n";
      const html = mk(title, intro, h1(title) + helloRow + p(esc(intro)) + p(esc(attach)) + (ref ? p(esc(ref)) : "") + p(esc(terms)) + tail);
      return { subject, text, html };
    }
    case "annual_card_code": {
      // booking_146: vuosikortin koodi ostajalle (verkko tai kassa). Payload tulee claimin 'annual_card'-kentästä; tilaus antaa vain tervehdyksen nimen.
      const c = d?.annual_card || {};
      const code = String(c.code ?? "").trim();
      const book = safeUrl(c.booking_url);
      const subject = X("email.annual_card.subject");
      const title = X("email.annual_card.title");
      // booking_154: hallinnasta myönnetty kortti (source 'admin', ei tilausta) → johdanto ilman ostoa
      const granted = c.source === "admin";
      const intro = X(granted ? "email.annual_card_granted.intro" : "email.annual_card.intro");
      const codeLabel = X("email.annual_card.code_label");
      const valid = X("email.annual_card.valid", { from: day(c.valid_from, en), to: day(c.valid_to, en) });
      const howTitle = X("email.annual_card.how_title");
      const how = [X("email.annual_card.how_1"), X("email.annual_card.how_2"), X(granted ? "email.annual_card_granted.how_3" : "email.annual_card.how_3"), X("email.annual_card.how_4")];
      const bookLabel = X("email.annual_card.book_button");
      const keep = X("email.annual_card.keep");
      const cardSign = `${X("email.common.closing")}\n${X("email.annual_card.sign_name")}\n${SELLER}`;
      const cardTail = `${p(esc(contact), `color:${MUTED};font-size:13px`)}${p(esc(cardSign).replace(/\n/g, "<br>"))}`;
      const text = textBlock(hello, intro, `${codeLabel}: ${code}`, valid, `${howTitle}:\n${how.map((x, i) => `${i + 1}. ${x}`).join("\n")}`, book && `${bookLabel}:\n${book}`, keep, contact, cardSign) + "\n";
      const html = mk(title, intro, h1(title) + helloRow + p(esc(intro))
        + box(`<span style="font-family:${SANS};font-size:12px;color:${MUTED};text-transform:uppercase;letter-spacing:.04em">${esc(codeLabel)}</span><br><span style="font-family:Consolas,Menlo,monospace;font-size:28px;line-height:1.3;letter-spacing:.08em;color:${GREEN};font-weight:bold">${esc(code)}</span><br><span style="font-family:${SANS};font-size:14px;color:${INK}">${esc(valid)}</span>`)
        + p(`<strong>${esc(howTitle)}</strong>`, "padding-bottom:6px") + p(how.map((x, i) => `${i + 1}. ${esc(x)}`).join("<br>"))
        + (book ? button(book, bookLabel) : "") + p(esc(keep), `color:${MUTED};font-size:13px`) + cardTail);
      return { subject, text, html };
    }
    case "waitlist_spot_freed": {
      // booking_132: jonotuslistan vapautumisilmoitus. Payload tulee claimin 'waitlist'-kentästä; ei tilausta.
      const w = d?.waitlist || {};
      const book = safeUrl(w.book_url);
      const leaveUrl = safeUrl(w.leave_url);
      const subject = X("email.waitlist.subject");
      const title = X("email.waitlist.title");
      const intro = X("email.waitlist.intro");
      // booking_148: yksityisvuoron jonovarauksella ei ole henkilömäärää (payload persons null) → rivi ilman henkilömäärää.
      const session = w.persons == null
        ? X("email.waitlist.session_private", { what: String(w.product_name ?? "").trim(), when: dt(w.starts_at, en) })
        : X("email.waitlist.session", { what: String(w.product_name ?? "").trim(), when: dt(w.starts_at, en), n: String(Number(w.persons) || 1) });
      const notice = X("email.waitlist.notice");
      const bookLabel = X("email.waitlist.book_button");
      const leaveLead = X("email.waitlist.leave");
      const leaveLabel = X("email.waitlist.leave_link");
      const text = textBlock(hello, intro, session, notice, book && `${bookLabel}:\n${book}`, leaveUrl && `${leaveLead}\n${leaveUrl}`, contact, sign) + "\n";
      const html = mk(title, intro, h1(title) + helloRow + p(esc(intro)) + box(`<span style="font-family:${SANS};font-size:15px;line-height:1.5;color:${INK}">${esc(session)}</span>`) + p(esc(notice))
        + (book ? button(book, bookLabel) : "")
        + (leaveUrl ? p(`${esc(leaveLead)} <a href="${esc(leaveUrl)}" style="color:${GREEN_SOFT}">${esc(leaveLabel)}</a>`, `color:${MUTED};font-size:13px`) : "") + tail);
      return { subject, text, html };
    }
    case "waitlist_joined": {
      // booking_210: jonoon liittymisen vahvistus. Ei varausta. Allekirjoitus Tapio.
      const w = d?.waitlist || {};
      const leaveUrl = safeUrl(w.leave_url);
      const subject = X("email.waitlist_joined.subject");
      const title = X("email.waitlist_joined.title");
      const intro = X("email.waitlist_joined.intro");
      const session = X("email.waitlist_joined.session", { what: String(w.product_name ?? "").trim(), when: dt(w.starts_at, en), n: String(Number(w.persons) || 1) });
      const notice = X("email.waitlist_joined.notice");
      const leaveLead = X("email.waitlist_joined.leave");
      const leaveLabel = X("email.waitlist.leave_link");
      const cardSign = `${X("email.common.closing")}\n${X("email.waitlist_joined.sign_name")}\n${SELLER}`;
      const cardTail = `${p(esc(contact), `color:${MUTED};font-size:13px`)}${p(esc(cardSign).replace(/\n/g, "<br>"))}`;
      const text = textBlock(hello, intro, session, notice, leaveUrl && `${leaveLead}\n${leaveUrl}`, contact, cardSign) + "\n";
      const html = mk(title, intro, h1(title) + helloRow + p(esc(intro)) + box(`<span style="font-family:${SANS};font-size:15px;line-height:1.5;color:${INK}">${esc(session)}</span>`) + p(esc(notice))
        + (leaveUrl ? p(`${esc(leaveLead)} <a href="${esc(leaveUrl)}" style="color:${GREEN_SOFT}">${esc(leaveLabel)}</a>`, `color:${MUTED};font-size:13px`) : "") + cardTail);
      return { subject, text, html };
    }
    case "unpaid_booking_cancelled": {
      // booking_190: kassapito vanheni, maksua ei saatu valmiiksi. Yritä uudelleen = saman tuotteen varaussivu. Allekirjoitus Tapio.
      const u = d?.unpaid_booking || {};
      const retry = safeUrl(u.retry_url);
      const what = String(u.product_name || "").trim();
      const when = u.starts_at ? dt(u.starts_at, en) : "";
      const subject = X("email.unpaid_booking.subject", { no });
      const title = X("email.unpaid_booking.title");
      const intro = X("email.unpaid_booking.intro");
      const again = X("email.unpaid_booking.try_again");
      const product = what ? X("email.unpaid_booking.product", { what }) : "";
      const time = when ? X("email.unpaid_booking.when", { when }) : "";
      const cardSign = `${X("email.common.closing")}\n${X("email.unpaid_booking.sign_name")}\n${SELLER}`;
      const cardTail = `${p(esc(contact), `color:${MUTED};font-size:13px`)}${p(esc(cardSign).replace(/\n/g, "<br>"))}`;
      const text = textBlock(hello, intro, product, time, retry && `${again}:\n${retry}`, contact, cardSign) + "\n";
      const html = mk(title, intro, h1(title) + helloRow + p(esc(intro))
        + (product || time ? box([product, time].filter(Boolean).map((line) => `<span style="font-family:${SANS};font-size:15px;line-height:1.5;color:${INK}">${esc(line)}</span>`).join("<br>")) : "")
        + (retry ? button(retry, again) : "") + cardTail);
      return { subject, text, html };
    }
    case "event_message": {
      // booking_202/213: henkilökunnan viesti tapahtuman osallistujille. Ei tilauslohkoa, ei summia, ei maksuvälittäjän nimeä.
      // booking_213 (Joonas 29.10.2026): ei automaattista allekirjoitusta (ei Tapio, ei loppukaneettia) – henkilökunta kirjoittaa allekirjoituksen itse viestiin.
      const em = d?.event_message || {};
      const rawSubject = String(em.subject || "").replace(/[<>]/g, "").replace(/\s+/g, " ").trim();
      const subject = rawSubject || X("email.event_message.subject_fallback");
      const body = String(em.body || "").replace(/montonio|visma|paybyway|mobilepay|vipps|paytrail/ig, "").trim();
      const what = String((en && em.event_name_en) || em.event_name || "").trim();
      const when = String(em.when_text || "").trim();
      const eventLine = what ? X("email.event_message.event", { what }) : "";
      const whenLine = when ? X("email.event_message.when", { when }) : "";
      const cardTail = p(esc(contact), `color:${MUTED};font-size:13px`);
      // Kaksoistervehdyksen esto: jos henkilökunnan teksti alkaa omalla tervehdyksellä (Hei!, Moi Matti, Hello…), pohjan tervehdys jätetään pois.
      const ownGreeting = /^\s*(hei|heippa|moi|moikka|terve|tervehdys|hyvää (huomenta|päivää|iltaa)|hello|hi|dear|good (morning|afternoon|evening))(?=[\s,!.:]|$)[^\n]{0,60}(\n|$)/i.test(body);
      const text = textBlock(ownGreeting ? "" : hello, body, eventLine, whenLine, contact) + "\n";
      const html = mk(subject, (body || subject).slice(0, 140), h1(subject) + (ownGreeting ? "" : helloRow) + (body ? p(esc(body).replace(/\n/g, "<br>")) : "")
        + (eventLine || whenLine ? box([eventLine, whenLine].filter(Boolean).map((line) => `<span style="font-family:${SANS};font-size:15px;line-height:1.5;color:${INK}">${esc(line)}</span>`).join("<br>")) : "")
        + cardTail);
      return { subject, text, html };
    }
    case "order_change":
    default: {
      const subject = X("email.order_change.subject", { no });
      const msg = X("email.order_change.message");
      const title = X("email.order_change.title");
      const text = textBlock(hello, msg, ob.text, orderUrl && `${yourOrder}: ${orderUrl}`, contact, sign) + "\n";
      return { subject, text, html: mk(title, msg, h1(title) + helloRow + p(esc(msg)) + ob.html + (orderUrl ? button(orderUrl, viewLabel) : "") + tail) };
    }
  }
}


