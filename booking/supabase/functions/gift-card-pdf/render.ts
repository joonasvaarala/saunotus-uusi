// Lahjakortin PDF (A5 vaaka, pdf-lib, StandardFonts = WinAnsi). Pohja: booking/docs/lahjakortti-pdf-pohja.md (+ mockup HTML).
// Syöte = booking.svc_get_gift_card_pdf_data()-vastaus (sopimus §13.2) + valinnainen logo (PNG/JPG). Ei verkkokutsuja täällä.
import { PDFDocument, StandardFonts, rgb, degrees, PDFFont, PDFPage } from "npm:pdf-lib@1.17.1";

const W = 595.28, H = 419.53;              // A5 landscape, pt
const K = 0.75;                            // mockup px -> pt
const C = {
  ink: rgb(0x2F / 255, 0x29 / 255, 0x23 / 255), text: rgb(0x4F / 255, 0x44 / 255, 0x3A / 255), muted: rgb(0x6B / 255, 0x5E / 255, 0x52 / 255),
  gold: rgb(0x7A / 255, 0x55 / 255, 0x30 / 255), accent: rgb(0xC4 / 255, 0x9A / 255, 0x6C / 255), green: rgb(0x2B / 255, 0x3A / 255, 0x30 / 255),
  card: rgb(0xFA / 255, 0xF7 / 255, 0xF1 / 255), tint: rgb(0xF3 / 255, 0xEC / 255, 0xE1 / 255), sand: rgb(0xED / 255, 0xE3 / 255, 0xD0 / 255),
  kick: rgb(0xE3 / 255, 0xC7 / 255, 0x9A / 255), stamp: rgb(0x8A / 255, 0x2B / 255, 0x1F / 255),
};

const WINANSI_EXTRA = "\u20AC\u2013\u2014\u2018\u2019\u201A\u201C\u201D\u201E\u2022\u2026";
const okChar = (ch: string) => { const c = ch.codePointAt(0)!; return (c >= 0x20 && c <= 0x7E) || (c >= 0xA0 && c <= 0xFF) || WINANSI_EXTRA.includes(ch); };
/** WinAnsi-siivous: tuetut merkit säilyvät, aksentit pudotetaan (š->s), muut (emoji yms.) -> ? (yksi per koodipiste), kontrollimerkit pois, väli-/rivinvaihdot -> välilyönti. */
export function san(s: unknown): string {
  let out = "";
  for (const ch of Array.from(String(s ?? "").replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f\u200b-\u200f\u2028\u2029\ufeff]/g, "").replace(/[\t\r\n]+/g, " "))) {
    if (okChar(ch)) { out += ch; continue; }
    const base = ch.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
    out += base.length === 1 && okChar(base) ? base : (/\p{M}/u.test(ch) ? "" : "?");
  }
  return out;
}
/** Tervehdys: rivinvaihdot säilytetään (max 1 tyhjä rivi peräkkäin), muuten kuten san */
export function sanGreeting(s: unknown): string {
  return String(s ?? "").replace(/\r\n?/g, "\n").split("\n").map((l) => san(l).trim()).join("\n").replace(/\n{3,}/g, "\n\n").trim();
}

const dateOnly = (iso: string, en: boolean): string => {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso ?? ""); if (!m) return "";
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], 12));
  return en ? new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", day: "numeric", month: "short", year: "numeric" }).format(d) : `${+m[3]}.${+m[2]}.${m[1]}`;
};
const helsinkiDate = (iso: string, en: boolean): string => {
  if (!iso) return "";
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Helsinki", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(iso));
  return dateOnly(parts, en);
};
const money = (n: number, en: boolean): string => {
  const whole = Math.abs(n - Math.round(n)) < 0.005;
  const v = whole ? String(Math.round(n)) : n.toFixed(2);
  return en ? `€${v}` : `${v.replace(".", ",")} €`;
};
const stripProto = (u: string) => String(u ?? "").replace(/^https?:\/\//, "").replace(/\/$/, "");

export interface LogoImage { bytes: Uint8Array }

export async function buildGiftCardPdf(d: any, logo?: Uint8Array | null, langOverride?: string): Promise<Uint8Array> {
  const en = (langOverride ?? d.locale) === "en";
  const pdf = await PDFDocument.create();
  const code = String(d.code ?? "");
  pdf.setTitle(san(`${en ? "Gift card" : "Lahjakortti"} ${code}`)); pdf.setProducer("Sipoonjoen perinnesauna"); pdf.setCreator("booking");
  pdf.setSubject(en ? "Gift card" : "Lahjakortti");
  const page = pdf.addPage([W, H]);
  const serif = await pdf.embedFont(StandardFonts.TimesRoman), serifB = await pdf.embedFont(StandardFonts.TimesRomanBold), serifI = await pdf.embedFont(StandardFonts.TimesRomanItalic);
  const sans = await pdf.embedFont(StandardFonts.Helvetica), sansB = await pdf.embedFont(StandardFonts.HelveticaBold), mono = await pdf.embedFont(StandardFonts.CourierBold);
  const S = d.seller ?? {};

  // taustat
  page.drawRectangle({ x: 0, y: 0, width: W, height: H, color: C.card });
  const bandH = 118 * K, footH = 56 * K;
  page.drawRectangle({ x: 0, y: H - bandH, width: W, height: bandH, color: C.green });
  page.drawRectangle({ x: 0, y: H - bandH, width: W, height: 3, color: C.accent });
  page.drawRectangle({ x: 0, y: 0, width: W, height: footH, color: C.tint });
  page.drawLine({ start: { x: 0, y: footH }, end: { x: W, y: footH }, thickness: 0.5, color: rgb(0.86, 0.82, 0.77) });
  // hieno sisäkehys (leikkausviiva)
  page.drawRectangle({ x: 8, y: 8, width: W - 16, height: H - 16, borderColor: rgb(0.78, 0.68, 0.56), borderWidth: 0.5, borderDashArray: [3, 3], opacity: 0, borderOpacity: 0.55 });

  const spaced = (p: PDFPage, t: string, x: number, y: number, size: number, f: PDFFont, color: any, sp: number, align: "l" | "c" | "r" = "l", maxW?: number) => {
    const s = san(t).toUpperCase(); const ws = Array.from(s).map((ch) => f.widthOfTextAtSize(ch, size));
    const tot = ws.reduce((a, b) => a + b, 0) + sp * (ws.length - 1); let cx = align === "l" ? x : align === "c" ? x - tot / 2 : x - tot;
    Array.from(s).forEach((ch, i) => { p.drawText(ch, { x: cx, y, size, font: f, color }); cx += ws[i] + sp; });
    return tot;
  };
  const text = (t: string, x: number, y: number, size: number, f: PDFFont, color: any = C.text) => page.drawText(san(t), { x, y, size, font: f, color });
  const wrap = (t: string, f: PDFFont, size: number, maxW: number): string[] => {
    const out: string[] = [];
    for (const para of String(t ?? "").split("\n")) {
      if (!para.trim()) { out.push(""); continue; }
      let cur = "";
      for (const w0 of san(para).split(/\s+/).filter(Boolean)) {
        let w = w0;
        while (f.widthOfTextAtSize(w, size) > maxW) { // hyvin pitkä sana: katkaistaan
          let n = w.length; while (n > 1 && f.widthOfTextAtSize(w.slice(0, n), size) > maxW) n--;
          if (cur) { out.push(cur); cur = ""; }
          out.push(w.slice(0, n)); w = w.slice(n);
        }
        const tt = cur ? cur + " " + w : w;
        if (f.widthOfTextAtSize(tt, size) > maxW && cur) { out.push(cur); cur = w; } else cur = tt;
      }
      if (cur) out.push(cur);
    }
    return out;
  };
  const roundRectPath = (w: number, h: number, r: number) => `M ${r} 0 H ${w - r} A ${r} ${r} 0 0 1 ${w} ${r} V ${h - r} A ${r} ${r} 0 0 1 ${w - r} ${h} H ${r} A ${r} ${r} 0 0 1 0 ${h - r} V ${r} A ${r} ${r} 0 0 1 ${r} 0 Z`;

  // yläpalkki: logo (kermanvärisellä pohjalla, logo on tummanvihreä), nimi, otsikko
  const padX = 44 * K; let brandX = padX;
  if (logo && logo.length > 0) {
    try {
      const isPng = logo[0] === 0x89 && logo[1] === 0x50; const img = isPng ? await pdf.embedPng(logo) : await pdf.embedJpg(logo);
      const bh = 60, bw = 60 * 0.82; const bx = padX, by = H - bandH / 2 - bh / 2 + 1;
      page.drawEllipse({ x: bx + bw / 2, y: by + bh / 2, xScale: bw / 2 + 2, yScale: bh / 2 + 1, color: C.card });
      const sc = Math.min((bw - 8) / img.width, (bh - 10) / img.height);
      page.drawImage(img, { x: bx + bw / 2 - (img.width * sc) / 2, y: by + bh / 2 - (img.height * sc) / 2, width: img.width * sc, height: img.height * sc });
      brandX = bx + bw + 16;
    } catch { /* ilman logoa */ }
  }
  text("Sipoonjoen Perinnesauna", brandX, H - bandH / 2 + 3, 20, serif, C.card);
  spaced(page, en ? "Smoke sauna · Sipoo" : "Savusauna · Sipoo", brandX, H - bandH / 2 - 14, 7.5, sansB, C.kick, 1.6);
  const title = en ? "Gift card" : "Lahjakortti"; const tsz = 34;
  page.drawText(title, { x: W - padX - serifI.widthOfTextAtSize(title, tsz), y: H - bandH / 2 - 8, size: tsz, font: serifI, color: C.tint });

  // sarakkeet
  const colGap = 36 * K, leftW = (670 * 1.25 / 2.25) * K, left = padX, right = left + leftW + colGap, rightW = W - padX - right;
  let y = H - bandH - 26 * K - 8;   // ensimmäisen rivin perusviiva
  const isOpen = !!(d.package?.is_open) || d.kind === "value" && !d.package_code || d.package_code === "open";
  const pkgName = isOpen ? (en ? "Valid for all our services" : "Käy kaikkiin palveluihimme") : String((en ? d.package?.name_en : d.package?.name) ?? d.package?.name ?? (en ? "Smoke sauna gift card" : "Savusaunalahjakortti"));
  const kicker = isOpen ? (en ? "Open gift card" : "Avoin lahjakortti") : d.package?.name ? (en ? "Gift card package" : "Lahjakorttipaketti") : (en ? "Sipoo smoke sauna" : "Sipoon savusauna");
  spaced(page, kicker, left, y, 7.5, sansB, C.gold, 1.5); y -= 27;
  let nsz = 20; let nl = wrap(pkgName, serifB, nsz, leftW); if (nl.length > 2) { nsz = 16; nl = wrap(pkgName, serifB, nsz, leftW); }
  for (const l of nl.slice(0, 3)) { text(l, left, y, nsz, serifB, C.ink); y -= nsz * 1.08; }
  y -= 8;
  const val = money(Number(d.initial_amount ?? 0), en);
  text(val, left, y - 6, 27, serifB, C.gold); y -= 34;
  if (d.recipient_name) {
    const lab = en ? "For: " : "Saaja: "; text(lab, left, y, 11, sans, C.text);
    text(String(d.recipient_name), left + sans.widthOfTextAtSize(lab, 11), y, 11, sansB, C.ink); y -= 18;
  }
  // tervehdys
  const greeting = sanGreeting(d.greeting);
  const fromLine = d.buyer_name ? `${en ? "From: " : "Lahjoittaja: "}${san(d.buyer_name)}` : "";
  if (greeting) {
    const bottom = footH + 18 + (fromLine ? 18 : 0); const avail = y - bottom; const bar = 3, gp = 11, gw = leftW - bar - gp;
    let size = 13.5, lines: string[] = [], lh = 0;
    for (const sz of [13.5, 12, 10.5, 9.5]) { size = sz; lh = sz * 1.28; lines = wrap(greeting, serifI, sz, gw); if (lines.length * lh <= avail) break; }
    const maxLines = Math.max(1, Math.floor(avail / lh));
    if (lines.length > maxLines) { lines = lines.slice(0, maxLines); lines[maxLines - 1] = lines[maxLines - 1].replace(/\s*\S{0,3}$/, "") + "…"; }
    const blockH = lines.length * lh;
    page.drawRectangle({ x: left, y: y - blockH + lh * 0.72, width: bar, height: blockH, color: C.accent });
    lines.forEach((l, i) => { if (l) text(l, left + bar + gp, y - i * lh, size, serifI, C.ink); });
    y -= blockH + 6;
  }
  if (fromLine) { text(fromLine, left, Math.max(y - 4, footH + 14), 10, sans, C.muted); }

  // oikea sarake: koodilaatikko
  let ry = H - bandH - 26 * K - 8 + 6; const boxH = 62;
  page.drawSvgPath(roundRectPath(rightW, boxH, 8), { x: right, y: ry, color: C.sand, borderColor: rgb(0.72, 0.58, 0.42), borderWidth: 0.7 });
  spaced(page, en ? "Gift card code" : "Lahjakortin koodi", right + rightW / 2, ry - 18, 7, sansB, C.ink, 1.5, "c");
  const csz = rightW - 20 > mono.widthOfTextAtSize(code, 21) ? 21 : 18;
  page.drawText(san(code), { x: right + rightW / 2 - mono.widthOfTextAtSize(san(code), csz) / 2, y: ry - 45, size: csz, font: mono, color: C.green });
  ry -= boxH + 18;
  const meta: [string, string][] = [];
  meta.push([en ? "Valid until" : "Voimassa", d.valid_to ? (en ? dateOnly(d.valid_to, true) : `${dateOnly(d.valid_to, false)} asti`) : ""]);
  if (!isOpen && d.package?.persons) meta.push([en ? "Persons" : "Henkilömäärä", en ? `${d.package.persons} persons` : `${d.package.persons} henkilöä`]);
  if (Math.abs(Number(d.balance ?? 0) - Number(d.initial_amount ?? 0)) > 0.004) meta.push([en ? "Balance" : "Saldo", money(Number(d.balance ?? 0), en)]);
  meta.push([en ? "Issued" : "Myönnetty", helsinkiDate(d.issued_at, en)]);
  const lw = 76;
  for (const [k, v] of meta) { if (!v) continue; text(k, right, ry, 9.5, sans, C.muted); text(v, right + lw, ry, 10, sansB, C.ink); ry -= 14; }
  // sisältö (paketit)
  const items: any[] = isOpen ? [] : (Array.isArray(d.package?.items) ? d.package.items : []);
  const itemLines = items.map((it) => { const lb = String((en ? it.label_en : it.label) ?? it.label ?? it.label_en ?? ""); return lb ? `${lb}${it.persons ? ` × ${it.persons}` : ""}` : ""; }).filter(Boolean);
  if (itemLines.length) {
    ry -= 2; text(en ? "Includes" : "Sisältää", right, ry, 9.5, sans, C.muted); let iy = ry;
    for (const l of itemLines.slice(0, 4)) { for (const w of wrap(l, sansB, 9.5, rightW - lw)) { text(w, right + lw, iy, 9.5, sansB, C.ink); iy -= 12; } }
    ry = iy - 4;
  }
  // käyttöohje
  const web = stripProto(S.web ?? "saunotus.fi");
  const how = d.redeemable_now
    ? (en ? `Book at ${web} and enter the code at checkout, or tell us the code at the sauna.` : `Varaa aika osoitteessa ${web} ja syötä koodi maksuvaiheessa, tai kerro koodi saunalla.`)
    : (en ? `Tell us the code at the sauna or contact us: ${[S.email, S.phone].filter(Boolean).join(" · ")}.` : `Kerro koodi saunalla tai ota yhteyttä: ${[S.email, S.phone].filter(Boolean).join(" · ")}.`);
  ry -= 4;
  for (const l of wrap(how, sans, 9.5, rightW).slice(0, 5)) { text(l, right, ry, 9.5, sans, C.text); ry -= 12.5; }

  // alapalkki
  const sn = "Sipoonjoen Perinnesauna", legal = S.legal_name ? ` · ${S.legal_name}` : "";
  const addr = [S.address, [S.zip, S.city].filter(Boolean).join(" ")].filter(Boolean).join(", ");
  const fy = footH / 2 + 3;
  page.drawText(san(sn), { x: padX, y: fy + 4, size: 8.5, font: sansB, color: C.ink });
  page.drawText(san(`${addr}${S.business_id ? ` · ${en ? "Business ID" : "Y-tunnus"} ${S.business_id}` : ""}`), { x: padX, y: fy - 7, size: 8, font: sans, color: C.muted });
  const contact = [S.phone, S.email].filter(Boolean).join(" · ");
  const cw = sans.widthOfTextAtSize(san(contact), 8.5);
  page.drawText(san(contact), { x: W - padX - cw, y: fy + 4, size: 8.5, font: sans, color: C.muted });
  if (S.web) { const ww = sans.widthOfTextAtSize(san(stripProto(S.web)), 8.5); page.drawText(san(stripProto(S.web)), { x: W - padX - ww, y: fy - 7, size: 8.5, font: sansB, color: C.ink }); }
  void legal;

  // tilaleima
  const stampTxt = d.status === "expired" ? (en ? "EXPIRED" : "VANHENTUNUT") : d.status === "used" ? (en ? "USED" : "KÄYTETTY") : "";
  if (stampTxt) {
    const w = 0;
    page.drawText(stampTxt, { x: left + 4, y: footH + 52, size: 34, font: serifB, color: C.stamp, rotate: degrees(9), opacity: 0.6 });
    void w;
  }
  return await pdf.save();
}
