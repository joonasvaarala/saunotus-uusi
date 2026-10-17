
// Sähköpostimallit: render(kind, data, locale) -> { subject, text, html }.
// data = booking.email_outbox_claim()-rivi (ks. docs/talous-integraatiot.md): { kind, locale, to_name, order{order_no, order_url, total, items[], reservations[]}, receipt{receipt_no, kind, text_body, total, issued_at}, payment{amount, link_url, link_expires_at} }.
// FI + EN, HTML (taulukkopohjainen, inline-tyylit, sähköpostiyhteensopiva) + tekstiversio. Ei ulkoisia riippuvuuksia (puhdas funktio, testattu node --test).
// Tyyli: tumma vihreä + hiekka, ei sinistä. Logo: sivuston /img/logo-kuitti.png (osoite johdetaan tilauslinkistä; muuten LOGO_FALLBACK).
export type Kind = "order_confirmation" | "payment_link" | "receipt" | "refund_receipt" | "cancel_request_ack" | "order_change" | "gift_card_buyer" | "gift_card_recipient" | "voucher_claim_received" | "voucher_claim_problem";
export interface Rendered { subject: string; text: string; html: string }

export const SELLER = "Sipoonjoen perinnesauna";
export const COMPANY = "Havuhattu Oy";
export const ADDRESS = "Hindsbyntie 124, 04130 Sipoo";
export const EMAIL = "savusauna@saunotus.fi";
export const PHONE = "010 299 2866";
export const LOGO_FALLBACK = "https://joonasvaarala.github.io/saunotus-uusi/img/logo-kuitti.png";
const GREEN = "#1f3d2b", GREEN_SOFT = "#3d5c47", SAND = "#efe7d6", SAND_LIGHT = "#f7f2e7", SAND_LINE = "#d9ccb2", INK = "#2b2a26", MUTED = "#6f6a5d";
const FONT = "Georgia,'Times New Roman',serif", SANS = "Arial,Helvetica,sans-serif";

const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
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
const p = (html: string, extra = "") => `<tr><td style="padding:0 32px 14px 32px;font-family:${SANS};font-size:15px;line-height:1.55;color:${INK};${extra}">${html}</td></tr>`;
const h1 = (title: string) => `<tr><td style="padding:28px 32px 14px 32px;font-family:${FONT};font-size:24px;line-height:1.25;color:${GREEN};font-weight:normal">${esc(title)}</td></tr>`;
const button = (url: string, label: string) => {
  const u = safeUrl(url); if (!u) return "";
  return `<tr><td style="padding:6px 32px 8px 32px"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr><td bgcolor="${GREEN}" style="border-radius:4px"><a href="${esc(u)}" style="display:inline-block;padding:12px 24px;font-family:${SANS};font-size:15px;font-weight:bold;color:${SAND_LIGHT};text-decoration:none;border-radius:4px">${esc(label)}</a></td></tr></table></td></tr>`
    + `<tr><td style="padding:6px 32px 18px 32px;font-family:${SANS};font-size:12px;line-height:1.4;color:${MUTED};word-break:break-all">${esc(u)}</td></tr>`;
};
const th = (s: string, align = "left") => `<td align="${align}" style="padding:6px 8px;font-family:${SANS};font-size:12px;color:${MUTED};text-transform:uppercase;letter-spacing:.04em;border-bottom:2px solid ${SAND_LINE}">${esc(s)}</td>`;
const td = (s: string, align = "left", bold = false) => `<td align="${align}" valign="top" style="padding:8px;font-family:${SANS};font-size:14px;line-height:1.4;color:${INK};border-bottom:1px solid ${SAND};${bold ? "font-weight:bold;" : ""}">${esc(s)}</td>`;
const box = (inner: string) => `<tr><td style="padding:0 32px 18px 32px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="${SAND_LIGHT}" style="background:${SAND_LIGHT};border:1px solid ${SAND_LINE};border-radius:4px"><tr><td style="padding:12px 16px">${inner}</td></tr></table></td></tr>`;

function wrapHtml(d: any, title: string, preheader: string, rows: string, en: boolean, noPhone = false): string {
  const logo = logoUrl(d);
  return `<!doctype html><html lang="${en ? "en" : "fi"}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"><title>${esc(title)}</title></head>
<body style="margin:0;padding:0;background:${SAND};-webkit-text-size-adjust:100%">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;font-size:1px;line-height:1px;color:${SAND}">${esc(preheader)}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="${SAND}" style="background:${SAND}"><tr><td align="center" style="padding:24px 10px">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" bgcolor="#ffffff" style="width:100%;max-width:600px;background:#ffffff;border-radius:6px;border-top:4px solid ${GREEN}">
<tr><td style="padding:22px 32px 4px 32px"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
<td valign="middle" style="padding-right:12px"><img src="${esc(logo)}" width="56" alt="${esc(COMPANY)}" style="display:block;border:0;outline:none;height:auto;width:56px"></td>
<td valign="middle" style="font-family:${FONT};font-size:18px;line-height:1.2;color:${GREEN}">${esc(SELLER)}<br><span style="font-family:${SANS};font-size:12px;color:${MUTED}">${esc(COMPANY)}</span></td>
</tr></table></td></tr>
${rows}
<tr><td style="padding:10px 32px 0 32px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr><td style="border-top:1px solid ${SAND_LINE};font-size:0;line-height:0">&nbsp;</td></tr></table></td></tr>
<tr><td style="padding:8px 32px 26px 32px;font-family:${SANS};font-size:12px;line-height:1.6;color:${MUTED}">${esc(SELLER)} · ${esc(COMPANY)}<br>${esc(ADDRESS)}<br><a href="mailto:${EMAIL}" style="color:${GREEN_SOFT}">${EMAIL}</a>${noPhone ? "" : ` · <a href="tel:${PHONE.replace(/\s/g, "")}" style="color:${GREEN_SOFT};text-decoration:none">${PHONE}</a>`}</td></tr>
</table></td></tr></table></body></html>`;
}

// ---------- tilaus ----------
interface Block { text: string; html: string }
// booking_50: varauksen tuotevalinta (esim. Saunahoito – Hunajahoito); r.option = {code, name, name_en} tai null
const resName = (r: any, en: boolean) => { const o = r?.option; const n = o ? String((en ? o.name_en : o.name) ?? o.name ?? "").trim() : ""; const p = String(r?.product_name ?? ""); return n ? (p ? `${p} – ${n}` : n) : p; };
function orderBlock(d: any, en: boolean): Block {
  const o = d?.order; if (!o) return { text: "", html: "" };
  const res = (o.reservations ?? []).filter((r: any) => r.status !== "cancelled");
  const items: any[] = o.items ?? [];
  const L = en ? { order: "Order", when: "Time", product: "Product", persons: "Guests", qty: "Qty", sum: "Amount", total: "Total", pers: "guests", sauna: "Bookings", lines: "Order lines" }
               : { order: "Tilaus", when: "Aika", product: "Tuote", persons: "Henkilöt", qty: "Kpl", sum: "Summa", total: "Yhteensä", pers: "hlö", sauna: "Varaukset", lines: "Tilausrivit" };
  const tl: string[] = [`${L.order} ${o.order_no}`];
  if (res.length) { tl.push("", `${L.sauna}:`); for (const r of res) tl.push(`  ${resName(r, en)}: ${dt(r.starts_at, en)}–${tm(r.ends_at, en)}, ${r.persons} ${L.pers}`); }
  if (items.length) { tl.push("", `${L.lines}:`); for (const i of items) tl.push(`  ${i.quantity} × ${i.name} ${eur(i.line_total, en)}`); }
  tl.push("", `${L.total}: ${eur(o.total, en)}`);
  let html = `<tr><td style="padding:4px 32px 4px 32px;font-family:${FONT};font-size:17px;color:${GREEN}">${L.order} ${esc(o.order_no)}</td></tr>`;
  if (res.length) {
    html += `<tr><td style="padding:6px 32px 12px 32px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>${th(L.product)}${th(L.when)}${th(L.persons, "right")}</tr>`
      + res.map((r: any) => `<tr>${td(resName(r, en))}${td(`${dt(r.starts_at, en)}–${tm(r.ends_at, en)}`)}${td(String(r.persons ?? ""), "right")}</tr>`).join("") + `</table></td></tr>`;
  }
  if (items.length) {
    html += `<tr><td style="padding:6px 32px 8px 32px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>${th(L.product)}${th(L.qty, "right")}${th(L.sum, "right")}</tr>`
      + items.map((i: any) => `<tr>${td(String(i.name ?? ""))}${td(String(i.quantity ?? ""), "right")}${td(eur(i.line_total, en), "right")}</tr>`).join("")
      + `<tr><td colspan="2" align="right" style="padding:10px 8px;font-family:${SANS};font-size:15px;font-weight:bold;color:${GREEN}">${L.total}</td><td align="right" style="padding:10px 8px;font-family:${SANS};font-size:15px;font-weight:bold;color:${GREEN}">${esc(eur(o.total, en))}</td></tr></table></td></tr>`;
  } else {
    html += p(`<b>${L.total}: ${esc(eur(o.total, en))}</b>`);
  }
  return { text: tl.join("\n") + "\n", html };
}

const textBlock = (...parts: (string | undefined | false)[]) => parts.filter((x) => typeof x === "string" && x !== "").join("\n\n");


// ---------- lahjakortit (gift_card_buyer / gift_card_recipient) ----------
// data.gift_cards[]: { public_token, package_code, package_name(_en), kind, amount, valid_to, recipient_name, greeting, buyer_name, persons, locale, status }
// delivery_to ('buyer'|'recipient'), deliver_on/deliver_time/deliver_at (ajastus), recipient_email (vain ostajan viestissä), cover_message (vain saajan viestissä; EI kortti-PDF:ssä).
// + data.functions_url (…/functions/v1) ja data.redeem_online (lunastus verkossa päällä?) joita send-emails/index.ts lisää. Koodia EI ole viestissä, vain PDF-linkki.
const gcAmt = (n: unknown, en: boolean) => { const x = Number(n ?? 0); const w = Math.abs(x - Math.round(x)) < 0.005; const v = w ? String(Math.round(x)) : x.toFixed(2); return en ? `€${v}` : `${v.replace(".", ",")}${NBSP}€`; };
const gcDate = (s: unknown, en: boolean) => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(s ?? "")); if (!m) return ""; return en ? new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", day: "numeric", month: "short", year: "numeric" }).format(new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], 12))) : `${+m[3]}.${+m[2]}.${m[1]}`; };
const gcOpen = (g: any) => g?.package_code === "open" || (g?.kind === "value" && !g?.package_code);
const gcTitle = (g: any, en: boolean) => gcOpen(g) ? (en ? "Open gift card (valid for all our services)" : "Avoin lahjakortti (käy kaikkiin palveluihimme)") : String((en ? g?.package_name_en : g?.package_name) ?? g?.package_name ?? (en ? "Gift card" : "Lahjakortti"));
const gcUrl = (d: any, g: any, en: boolean) => safeUrl(`${d?.functions_url ?? ""}/gift-card-pdf?t=${g?.public_token}&lang=${en ? "en" : "fi"}`);

function giftCardMail(kind: "gift_card_buyer" | "gift_card_recipient", d: any, en: boolean, hello: string, sign: string, signHtml: string): Rendered {
  const cards: any[] = (d?.gift_cards ?? []).filter((g: any) => g?.public_token);
  const n = cards.length, buyer = kind === "gift_card_buyer", c0 = cards[0] ?? {};
  const from = c0.buyer_name ? String(c0.buyer_name).trim() : "";
  // ostaja valitsee toimitustavan: 'buyer' = kortti ostajalle (PDF-linkki tässä viestissä), 'recipient' = suoraan saajalle (ei PDF-linkkiä ostajalle)
  const toBuyer = (g: any) => (g?.delivery_to ?? "buyer") !== "recipient";
  const anyBuyer = cards.some(toBuyer), anyRecip = cards.some((g) => !toBuyer(g));
  const subject = buyer ? (anyBuyer ? (en ? `Your gift card${n > 1 ? "s" : ""} – ${SELLER}` : `Lahjakorttisi – ${SELLER}`) : (en ? `Your gift card order is confirmed – ${SELLER}` : `Lahjakorttitilauksesi vahvistus – ${SELLER}`))
    : from ? (en ? `${from} sent you a gift card – ${SELLER}` : `${from} lahjoittaa sinulle lahjakortin – ${SELLER}`) : (en ? `You have received a gift card – ${SELLER}` : `Sait lahjakortin – ${SELLER}`);
  const title = buyer ? (anyBuyer ? (en ? "Your gift card" : "Lahjakorttisi") : (en ? "Order confirmation" : "Tilausvahvistus")) : (en ? "You received a gift card" : "Sait lahjakortin");
  const intro = buyer
    ? (anyBuyer
        ? (en ? `Thank you for your purchase! Your gift card${n > 1 ? "s are" : " is"} ready. Open the PDF from the link below – you can print it or forward it to the recipient.` : `Kiitos ostoksestasi! Lahjakortti${n > 1 ? "t ovat valmiit" : " on valmis"}. Avaa PDF alla olevasta linkistä – voit tulostaa sen tai välittää sen lahjan saajalle.`)
        : (en ? `Thank you for your purchase! Your order is confirmed and the gift card${n > 1 ? "s are" : " is"} delivered directly to the recipient by email, as you chose.` : `Kiitos ostoksestasi! Tilauksesi on vahvistettu ja lahjakortti${n > 1 ? "t toimitetaan" : " toimitetaan"} valintasi mukaan suoraan saajalle sähköpostitse.`))
    : (en ? `${from || "Someone"} has sent you a gift card to ${SELLER}. Enjoy!` : `${from || "Joku"} on lahjoittanut sinulle lahjakortin Sipoonjoen perinnesaunalle. Nauti!`);
  const how = d?.redeem_online
    ? (en ? "The gift card code is in the PDF. Book online at saunotus.fi and enter the code at checkout, or tell us the code at the sauna." : "Lahjakortin koodi on PDF-tiedostossa. Varaa aika verkossa osoitteessa saunotus.fi ja syötä koodi maksuvaiheessa, tai kerro koodi saunalla.")
    : (en ? "The gift card code is in the PDF. Tell us the code at the sauna or contact us to book." : "Lahjakortin koodi on PDF-tiedostossa. Kerro koodi saunalla tai ota yhteyttä varataksesi ajan.");
  const note = buyer && anyBuyer ? (en ? "Tip: the link contains the card code – share it only with the recipient." : "Vinkki: linkki sisältää kortin koodin – jaa se vain lahjan saajalle.") : "";
  const recipNote = buyer && anyRecip ? (en ? "The recipient receives the gift card, its code and instructions in a separate email. If it does not arrive, please contact us." : "Saaja saa lahjakortin, sen koodin ja ohjeet omassa sähköpostiviestissään. Jos viesti ei saavu perille, ota yhteyttä.") : "";
  const cover = !buyer && c0.cover_message ? String(c0.cover_message).trim() : "";   // saateteksti: vain sähköpostissa, ei kortti-PDF:ssä
  const contact = en ? `Questions? Reply to this email or call ${PHONE}.` : `Kysyttävää? Vastaa tähän viestiin tai soita ${PHONE}.`;
  const tl: string[] = []; let rows = h1(title) + p(esc(hello)) + p(esc(intro));
  if (cover) rows += `<tr><td style="padding:0 32px 18px 32px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr><td style="padding:10px 16px;border-left:3px solid #c49a6c;font-family:${FONT};font-style:italic;font-size:17px;line-height:1.45;color:${INK}">${esc(cover).replace(/\n/g, "<br>")}${from ? `<br><span style="font-family:${SANS};font-style:normal;font-size:13px;color:${MUTED}">— ${esc(from)}</span>` : ""}</td></tr></table></td></tr>`;
  const hhmm = (s: string) => en ? s : s.replace(":", ".");
  for (const g of cards) {
    const url = gcUrl(d, g, en);
    const showAmt = buyer || gcOpen(g) || !g.package_code;   // saajan viestissä ei pakettihintaa (vain avoimen kortin arvo); ostajan vahvistuksessa hinta saa näkyä
    const meta = [showAmt ? gcAmt(g.amount, en) : "", g.persons && !gcOpen(g) ? (en ? `${g.persons} guests` : `${g.persons} henkilöä`) : "", g.valid_to ? (en ? `valid until ${gcDate(g.valid_to, true)}` : `voimassa ${gcDate(g.valid_to, false)} asti`) : "", buyer && g.recipient_name ? (en ? `for ${g.recipient_name}` : `saaja: ${g.recipient_name}`) : ""].filter(Boolean).join(" · ");
    const who = [g.recipient_name, g.recipient_email].filter(Boolean).join(", ");
    const when = g.deliver_at ? `${gcDate(g.deliver_on, en)}${g.deliver_time ? (en ? ` at ${g.deliver_time}` : ` klo ${hhmm(g.deliver_time)}`) : ""}` : "";
    const deliv = !buyer || toBuyer(g) ? "" : g.deliver_at
      ? (en ? `The gift card will be sent to the recipient (${who}) on ${when}.` : `Lahjakortti lähetetään saajalle (${who}) ${when}.`)
      : (en ? `The gift card has been sent to the recipient (${who}).` : `Lahjakortti on lähetetty saajalle (${who}).`);
    const showLink = !buyer || toBuyer(g);
    tl.push(`• ${gcTitle(g, en)}\n  ${meta}${deliv ? `\n  ${deliv}` : ""}${showLink ? `\n  PDF: ${url}` : ""}`);
    rows += box(`<span style="font-family:${FONT};font-size:19px;color:${GREEN}">${esc(gcTitle(g, en))}</span><br><span style="font-family:${SANS};font-size:13px;color:${MUTED}">${esc(meta)}</span>${deliv ? `<br><span style="font-family:${SANS};font-size:14px;color:${INK}">${esc(deliv)}</span>` : ""}`) + (showLink && url ? button(url, en ? "Open gift card (PDF)" : "Avaa lahjakortti (PDF)") : "");
  }
  const showHow = !buyer || anyBuyer;
  rows += (showHow ? p(esc(how)) : "") + (note ? p(esc(note), `color:${MUTED};font-size:13px`) : "") + (recipNote ? p(esc(recipNote), `color:${MUTED};font-size:13px`) : "") + p(esc(contact), `color:${MUTED};font-size:13px`) + p(signHtml);
  const text = textBlock(hello, intro, cover && `"${cover}"${from ? `\n— ${from}` : ""}`, tl.join("\n\n"), showHow && how, note, recipNote, contact, sign) + "\n";
  return { subject, text, html: wrapHtml(d, title, intro, rows, en) };
}


// ---------- kumppanilahjakorttien lunastuspyynnöt (voucher_claim_received / voucher_claim_problem) ----------
// data.voucher_claim: { claim_id, status, source, code_masked ("…1234"), problem_code (invalid_code|expired_code|already_used|other), customer_name } + data.order (order_url, varaukset). Täyttä koodia ei viesteissä.
// booking_48: varaus ei vanhene lunastuspyynnön vuoksi -> viesteissä EI aikarajoja eikä "aika on pidetty varattuna … asti" (hold_until on poistettu käytöstä; kenttää ei lueta).
// Yhteystieto: vain sähköposti (puhelinnumeroa ei ole vahvistettu -> ei näy näissä viesteissä, ei alatunnisteessakaan).
// Allekirjoitus: Tapio / Sipoonjoen perinnesauna. Ongelmaviesti jonotetaan vain kun asetus voucher_claims.problem_emails_enabled = true.
const VC_LABEL: Record<string, string> = { elamyslahjat: "Elämyslahjat", kokemuskauppa: "Kokemuskauppa", kiitoskauppa: "Kiitoskauppa", offerilla: "Offerilla" };
function voucherMail(kind: "voucher_claim_received" | "voucher_claim_problem", d: any, en: boolean, hello: string): Rendered {
  const vc = d?.voucher_claim ?? {};
  const label = VC_LABEL[String(vc.source ?? "")] ?? (en ? "partner" : "kumppani");
  const masked = String(vc.code_masked ?? "").trim();
  const what = `${label}${masked ? (en ? `, code ${masked}` : `, koodi ${masked}`) : ""}`;
  const orderUrl = safeUrl(d?.order?.order_url);
  const ob = orderBlock(d, en);
  const sign = en ? `Kind regards,\nTapio\n${SELLER}` : `Ystävällisin terveisin,\nTapio\n${SELLER}`;
  const signHtml = esc(sign).replace(/\n/g, "<br>");
  const contact = en ? `Questions? Reply to this email or write to ${EMAIL}.` : `Kysyttävää? Vastaa tähän viestiin tai kirjoita ${EMAIL}.`;
  const viewLabel = en ? "Open your order" : "Avaa tilauksesi";
  let subject: string, title: string, paras: string[];
  if (kind === "voucher_claim_received") {
    subject = en ? `Thank you for your gift card booking – ${SELLER}` : `Kiitos lahjakorttivarauksesta – ${SELLER}`;
    title = en ? "Thank you for your gift card booking" : "Kiitos lahjakorttivarauksesta";
    paras = en
      ? [`Thank you for your booking! We have received your gift card (${what}) and your time is reserved for you.`,
         "We will check and redeem the gift card shortly. If there are any problems with the redemption, we will contact you."]
      : [`Kiitos varauksestasi! Olemme vastaanottaneet lahjakorttisi (${what}) ja aikasi on varattu sinulle.`,
         "Tarkistamme ja lunastamme lahjakortin pian. Jos lunastuksessa ilmenee ongelmia, olemme sinuun yhteydessä."];
  } else {
    const how = en ? "You can fix this in two ways: enter the correct code on your order page (link below), or reply to this email with the correct code."
                   : "Voit korjata asian kahdella tavalla: syötä oikea koodi tilaussivullamme (alla oleva linkki) tai vastaa tähän viestiin ja kerro oikea koodi.";
    switch (vc.problem_code) {
      case "expired_code":
        subject = en ? `Your gift card has expired – ${SELLER}` : `Lahjakortin voimassaolo on päättynyt – ${SELLER}`;
        title = en ? "Your gift card has expired" : "Lahjakortin voimassaolo on päättynyt";
        paras = en
          ? [`Unfortunately we could not redeem your gift card (${what}): the code has expired.`,
             `If you believe the code is still valid, reply to this email or contact us and we will look into it. You can also ask ${label} whether the validity can be extended, or pay for the booking in another way.`]
          : [`Emme valitettavasti pystyneet lunastamaan lahjakorttiasi (${what}): koodin voimassaolo on päättynyt.`,
             `Jos uskot, että koodi on vielä voimassa, vastaa tähän viestiin tai ota yhteyttä saunalle, niin selvitämme asian. Voit myös kysyä lahjakortin myyjältä (${label}) voimassaolon jatkamista tai maksaa varauksen muulla tavalla.`];
        break;
      case "already_used":
        subject = en ? `Your gift card code has already been used – ${SELLER}` : `Lahjakortin koodi on jo käytetty – ${SELLER}`;
        title = en ? "The gift card code has already been used" : "Lahjakortin koodi on jo käytetty";
        paras = en
          ? [`Unfortunately we could not redeem your gift card (${what}): the code appears to have been used already.`,
             `If the gift card has not been used yet, please contact us: ${EMAIL}`,
             "If you have another code, you can send it to us or enter it on your order page."]
          : [`Emme valitettavasti pystyneet lunastamaan lahjakorttiasi (${what}): koodi näyttää olevan jo käytetty.`,
             `Jos lahjakorttia ei ole vielä käytetty, ole meihin yhteydessä: ${EMAIL}`,
             "Jos sinulla on toinen koodi, voit lähettää sen meille tai syöttää sen tilaussivullamme."];
        break;
      case "invalid_code":
        subject = en ? `We could not find your gift card code – ${SELLER}` : `Lahjakortin koodia ei löytynyt – ${SELLER}`;
        title = en ? "We could not find your gift card code" : "Lahjakortin koodia ei löytynyt";
        paras = en
          ? [`Unfortunately we could not redeem your gift card (${what}): the code was not found in the ${label} system. This may be due to a typo in the code.`, how]
          : [`Emme valitettavasti pystyneet lunastamaan lahjakorttiasi (${what}): koodia ei löytynyt kumppanin (${label}) järjestelmästä. Syynä voi olla kirjoitusvirhe koodissa.`, how];
        break;
      default:
        subject = en ? `About your gift card – ${SELLER}` : `Lahjakorttisi lunastuksesta – ${SELLER}`;
        title = en ? "About your gift card" : "Lahjakorttisi lunastuksesta";
        paras = en ? [`We ran into a problem redeeming your gift card (${what}). We will look into it and contact you.`] : [`Lahjakortin (${what}) lunastuksessa on ilmennyt ongelma. Selvitämme asian ja otamme sinuun yhteyttä.`];
    }
  }
  paras = paras.filter(Boolean);
  const more = kind === "voucher_claim_received" ? (en ? "You can follow the status of your booking here:" : "Voit seurata varauksesi tilaa täältä:") : (en ? "Your order:" : "Tilauksesi:");
  const text = textBlock(hello, ...paras, ob.text, orderUrl && `${more}\n${orderUrl}`, contact, sign) + "\n";
  const html = wrapHtml(d, title, paras[0], h1(title) + p(esc(hello)) + paras.map((x) => p(esc(x))).join("") + ob.html + (orderUrl ? p(esc(more)) + button(orderUrl, viewLabel) : "") + p(esc(contact), `color:${MUTED};font-size:13px`) + p(signHtml), en, true);
  return { subject, text, html };
}

export function render(kind: Kind, d: any, locale?: string): Rendered {
  const en = (locale ?? d?.locale) === "en";
  const first = d?.to_name ? String(d.to_name).trim().split(/\s+/)[0] : "";
  const hello = en ? `Hello${first ? " " + first : ""},` : `Hei${first ? " " + first : ""},`;
  const no = d?.order?.order_no ?? "";
  const ob = orderBlock(d, en);
  const orderUrl = safeUrl(d?.order?.order_url);
  const sign = en ? `Kind regards,\n${SELLER}\n${COMPANY}` : `Ystävällisin terveisin,\n${SELLER}\n${COMPANY}`;
  const signHtml = esc(sign).replace(/\n/g, "<br>");
  const viewLabel = en ? "View your order" : "Avaa tilauksesi";
  const contact = en ? `Questions? Reply to this email or call ${PHONE}.` : `Kysyttävää? Vastaa tähän viestiin tai soita ${PHONE}.`;
  const helloRow = p(esc(hello));
  const tail = `${p(esc(contact), `color:${MUTED};font-size:13px`)}${p(signHtml)}`;
  const mk = (title: string, preheader: string, rows: string) => wrapHtml(d, title, preheader, rows, en);

  switch (kind) {
    case "gift_card_buyer":
    case "gift_card_recipient":
      return giftCardMail(kind, d, en, hello, sign, signHtml);
    case "voucher_claim_received":
    case "voucher_claim_problem":
      return voucherMail(kind, d, en, hello);
    case "order_confirmation": {
      const subject = en ? `Order confirmation ${no} – ${SELLER}` : `Tilausvahvistus ${no} – ${SELLER}`;
      const intro = en ? "Thank you for your order. Your booking is confirmed." : "Kiitos tilauksestasi. Varauksesi on vahvistettu.";
      const more = en ? "You can view your order, add services, request changes and download receipts here:" : "Voit katsoa tilaustasi, lisätä siihen palveluita, pyytää muutoksia ja ladata kuitit täältä:";
      const title = en ? "Order confirmation" : "Tilausvahvistus";
      const text = textBlock(hello, intro, ob.text, orderUrl && `${more}\n${orderUrl}`, contact, sign) + "\n";
      const html = mk(title, intro, h1(title) + helloRow + p(esc(intro)) + ob.html + (orderUrl ? p(esc(more)) + button(orderUrl, viewLabel) : "") + tail);
      return { subject, text, html };
    }
    case "payment_link": {
      const url = safeUrl(d?.payment?.link_url) || orderUrl;
      const amount = eur(d?.payment?.amount, en);
      const expires = d?.payment?.link_expires_at ? day(d.payment.link_expires_at, en) : "";
      const subject = en ? `Payment link for order ${no} – ${SELLER}` : `Maksulinkki tilaukseen ${no} – ${SELLER}`;
      const intro = en ? `You can pay the outstanding amount of ${amount} using the link below.` : `Voit maksaa tilauksen maksamattoman osuuden (${amount}) alla olevasta linkistä.`;
      const exp = expires ? (en ? `The link is valid until ${expires}.` : `Linkki on voimassa ${expires} asti.`) : "";
      const title = en ? "Payment link" : "Maksulinkki";
      const lab = en ? "Amount to pay" : "Maksettava";
      const pay = en ? "Pay now" : "Maksa nyt";
      const text = textBlock(hello, intro, url && `${en ? "Payment link" : "Maksulinkki"}:\n${url}`, exp, ob.text, contact, sign) + "\n";
      const html = mk(title, intro, h1(title) + helloRow + p(esc(intro)) + box(`<span style="font-family:${SANS};font-size:12px;color:${MUTED};text-transform:uppercase;letter-spacing:.04em">${esc(lab)}</span><br><span style="font-family:${FONT};font-size:24px;color:${GREEN}">${esc(amount)}</span>`)
        + (url ? button(url, pay) : "") + (exp ? p(esc(exp), `color:${MUTED};font-size:13px`) : "") + ob.html + tail);
      return { subject, text, html };
    }
    case "receipt":
    case "refund_receipt": {
      const r = d?.receipt; const refund = kind === "refund_receipt";
      const rno = r?.receipt_no ?? "";
      const subject = refund ? (en ? `Refund receipt ${rno} – ${SELLER}` : `Hyvityskuitti ${rno} – ${SELLER}`) : (en ? `Receipt ${rno} – ${SELLER}` : `Kuitti ${rno} – ${SELLER}`);
      const amount = r?.total != null ? eur(Math.abs(Number(r.total)), en) : "";
      const intro = refund
        ? (en ? `A refund${amount ? " of " + amount : ""} has been made for your order. The refund receipt is below and attached as a PDF.` : `Tilauksestasi on tehty hyvitys${amount ? " (" + amount + ")" : ""}. Hyvityskuitti on alla ja liitteenä PDF-tiedostona.`)
        : (en ? "Thank you for your payment. Your receipt is below and attached as a PDF." : "Kiitos maksustasi. Kuittisi on alla ja liitteenä PDF-tiedostona.");
      const title = refund ? (en ? "Refund receipt" : "Hyvityskuitti") : (en ? "Receipt" : "Kuitti");
      const body = String(r?.text_body ?? "").trim();
      const meta = [rno && `${en ? "Receipt no." : "Kuittinumero"}: ${rno}`, r?.issued_at && `${en ? "Date" : "Päivämäärä"}: ${day(r.issued_at, en)}`, amount && `${refund ? (en ? "Refunded" : "Hyvitetty") : (en ? "Paid" : "Maksettu")}: ${amount}`].filter(Boolean) as string[];
      const text = textBlock(hello, intro, meta.join("\n"), body, orderUrl && `${en ? "Your order" : "Tilauksesi"}: ${orderUrl}`, contact, sign) + "\n";
      const html = mk(title, intro, h1(title) + helloRow + p(esc(intro))
        + (meta.length ? box(meta.map((m) => `<span style="font-family:${SANS};font-size:14px;color:${INK}">${esc(m)}</span>`).join("<br>")) : "")
        + (body ? `<tr><td style="padding:0 32px 18px 32px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr><td style="padding:12px 14px;background:${SAND_LIGHT};border:1px solid ${SAND_LINE};border-radius:4px;font-family:Consolas,'Courier New',monospace;font-size:12px;line-height:1.5;color:${INK};white-space:pre-wrap">${esc(body)}</td></tr></table></td></tr>` : "")
        + (orderUrl ? button(orderUrl, viewLabel) : "") + tail);
      return { subject, text, html };
    }
    case "cancel_request_ack": {
      const subject = en ? `We received your cancellation request – order ${no}` : `Peruutuspyyntösi on vastaanotettu – tilaus ${no}`;
      const msg = en ? "We have received your cancellation request. Our staff will handle it and contact you. The booking remains valid until the cancellation is confirmed." : "Olemme vastaanottaneet peruutuspyyntösi. Henkilökuntamme käsittelee sen ja ottaa yhteyttä. Varaus on voimassa, kunnes peruutus on vahvistettu.";
      const title = en ? "Cancellation request received" : "Peruutuspyyntö vastaanotettu";
      const text = textBlock(hello, msg, ob.text, orderUrl && `${en ? "Your order" : "Tilauksesi"}: ${orderUrl}`, contact, sign) + "\n";
      return { subject, text, html: mk(title, msg, h1(title) + helloRow + p(esc(msg)) + ob.html + (orderUrl ? button(orderUrl, viewLabel) : "") + tail) };
    }
    case "order_change":
    default: {
      const subject = en ? `Your order has changed – ${no}` : `Tilauksesi on muuttunut – ${no}`;
      const msg = en ? "Your order has been updated. The current details are below." : "Tilaustasi on päivitetty. Ajantasaiset tiedot ovat alla.";
      const title = en ? "Order updated" : "Tilaus päivitetty";
      const text = textBlock(hello, msg, ob.text, orderUrl && `${en ? "Your order" : "Tilauksesi"}: ${orderUrl}`, contact, sign) + "\n";
      return { subject, text, html: mk(title, msg, h1(title) + helloRow + p(esc(msg)) + ob.html + (orderUrl ? button(orderUrl, viewLabel) : "") + tail) };
    }
  }
}


