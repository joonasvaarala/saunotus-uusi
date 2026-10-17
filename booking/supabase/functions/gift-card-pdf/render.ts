// Lahjakortin PDF (A4 pysty, pdf-lib + fontkit). Pohja: booking/docs/lahjakortti-pdf-pohja.md; esimerkkikuvat samassa kansiossa.
// Syöte = booking.svc_get_gift_card_pdf_data()-vastaus (sopimus §13.2) + valinnainen logo (PNG/JPG). Ei verkkokutsuja täällä.
// Kirjasimet (Cormorant Garamond, Lato, IBM Plex Mono; SIL OFL) ja oven veistoskuva on upotettu moduuleihin fonts.ts / photos.ts
// (generoi assets/build_assets.py). Kirjasimet ovat latin-1/WinAnsi-osajoukkoja, joten san()-siivous pysyy voimassa (ei emojeita).
import {
  PDFDocument, PDFFont, PDFImage, rgb, pushGraphicsState, popGraphicsState, moveTo, lineTo, appendBezierCurve, closePath, clip, endPath,
  concatTransformationMatrix,
} from "npm:pdf-lib@1.17.1";
import fontkit from "npm:@pdf-lib/fontkit@1.1.1";
import { FONT_B64 } from "./fonts.ts";
import { PHOTO_B64 } from "./photos.ts";

const W = 595.28, H = 841.89;              // A4 pysty, pt
const hex = (h: number) => rgb(((h >> 16) & 255) / 255, ((h >> 8) & 255) / 255, (h & 255) / 255);
const C = {
  bg: hex(0xF4EFE7), ink: hex(0x2F2923), text: hex(0x4A3F35), muted: hex(0x66594D), gold: hex(0x7A5530), accent: hex(0xC49A6C),
  green: hex(0x2B3A30), card: hex(0xFAF7F1), kick: hex(0xE3C79A), cream: hex(0xF4EFE7), stamp: hex(0x8A2B1F), rule: hex(0xD9CBB6),
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
  return en ? `€${v}` : `${v.replace(".", ",")}\u00A0€`;
};
const stripProto = (u: string) => String(u ?? "").replace(/^https?:\/\//, "").replace(/\/$/, "");
const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

/** Avoin summakortti? */
export const isOpenCard = (d: any): boolean => !!(d?.package?.is_open) || d?.kind === "value" && !d?.package_code || d?.package_code === "open";
/** Näytetäänkö hinta/arvo PDF:ssä: vain avoimessa summakortissa (ja Johku-kortilla); lahjakorttipaketilla ei. */
export const showsPrice = (d: any): boolean => isOpenCard(d) || d?.source === "johku";

export interface LogoImage { bytes: Uint8Array }

export async function buildGiftCardPdf(d: any, logo?: Uint8Array | null, langOverride?: string): Promise<Uint8Array> {
  const en = (langOverride ?? d.locale) === "en";
  const pdf = await PDFDocument.create();
  pdf.registerFontkit(fontkit);
  const code = san(d.code);
  pdf.setTitle(san(`${en ? "Gift card" : "Lahjakortti"} ${code}`)); pdf.setProducer("Sipoonjoen perinnesauna"); pdf.setCreator("booking");
  pdf.setSubject(en ? "Gift card" : "Lahjakortti");
  let page = pdf.addPage([W, H]);
  const ef = (k: string) => pdf.embedFont(unb64(FONT_B64[k]), { subset: true, features: k.startsWith("cormorant") ? { lnum: true } : undefined });
  const serif = await ef("cormorant-500"), serifB = await ef("cormorant-600"), serifI = await ef("cormorant-italic-500");
  const sans = await ef("lato-regular"), sansB = await ef("lato-bold"), mono = await ef("plexmono-semibold");
  const S = d.seller ?? {};
  let logoImg: PDFImage | null = null;
  if (logo && logo.length > 0) {
    try { logoImg = logo[0] === 0x89 && logo[1] === 0x50 ? await pdf.embedPng(logo) : await pdf.embedJpg(logo); } catch { logoImg = null; }
  }
  const photo = await pdf.embedJpg(unb64(PHOTO_B64.photo_arch));   // oven veistos, upotetaan kerran

  // ---------- sisältömalli ----------
  const isOpen = isOpenCard(d);
  const pkgName = isOpen ? (en ? "Valid for all our services" : "Käy kaikkiin palveluihimme")
    : san((en ? d.package?.name_en : d.package?.name) ?? d.package?.name ?? (en ? "Smoke sauna gift card" : "Savusaunalahjakortti"));
  // hinta näytetään vain avoimessa summakortissa (ja Johku-kortilla); lahjakorttipaketilla ei (saaja ei näe pakettihintaa)
  const hidePrice = !showsPrice(d);
  const value = money(Number(d.initial_amount ?? 0), en);
  const recipient = san(d.recipient_name), buyer = san(d.buyer_name), greeting = sanGreeting(d.greeting);
  const items: any[] = isOpen ? [] : (Array.isArray(d.package?.items) ? d.package.items : []);
  const itemLines = items.map((it) => { const lb = san((en ? it.label_en : it.label) ?? it.label ?? it.label_en ?? ""); return lb ? `${lb}${it.persons ? ` × ${it.persons}` : ""}` : ""; }).filter(Boolean).slice(0, 4);
  const meta: [string, string][] = [];
  const validTxt = d.valid_to ? (en ? dateOnly(d.valid_to, true) : `${dateOnly(d.valid_to, false)} asti`) : "";
  if (!isOpen && d.package?.persons) meta.push([en ? "Persons" : "Henkilömäärä", en ? `${d.package.persons} persons` : `${d.package.persons} henkilöä`]);
  if (!hidePrice && Math.abs(Number(d.balance ?? 0) - Number(d.initial_amount ?? 0)) > 0.004) meta.push([en ? "Balance" : "Saldo", money(Number(d.balance ?? 0), en)]);
  meta.push([en ? "Issued" : "Myönnetty", helsinkiDate(d.issued_at, en)]);
  const web = stripProto(S.web ?? "saunotus.fi");
  const how = d.redeemable_now
    ? (en ? `Book at ${web} and enter the code at checkout, or tell us the code at the sauna.` : `Varaa aika osoitteessa ${web} ja syötä koodi maksuvaiheessa tai kerro koodi saunalla.`)
    : (en ? `Tell us the code at the sauna or contact us: ${[S.email, S.phone].filter(Boolean).join(" · ")}.` : `Kerro koodi saunalla tai ota yhteyttä: ${[S.email, S.phone].filter(Boolean).join(" · ")}.`);
  const stampTxt = d.status === "expired" ? (en ? "EXPIRED" : "VANHENTUNUT") : d.status === "used" ? (en ? "USED" : "KÄYTETTY") : "";
  const addr = [S.address, [S.zip, S.city].filter(Boolean).join(" ")].filter(Boolean).join(", ");
  const footLines = [
    "Sipoonjoen Perinnesauna",
    san([addr, [S.legal_name, S.business_id ? `${en ? "Business ID" : "Y-tunnus"} ${S.business_id}` : ""].filter(Boolean).join(", ")].filter(Boolean).join(" · ")),
    san([S.phone, S.email, S.web ? stripProto(S.web) : ""].filter(Boolean).join(" · ")),
  ].filter(Boolean);

  // ---------- piirtoapurit (t = etäisyys sivun yläreunasta) ----------
  const yb = (t: number) => H - t;
  const wid = (s: string, f: PDFFont, size: number) => f.widthOfTextAtSize(s, size);
  type Al = "l" | "c" | "r";
  const txt = (s: string, x: number, t: number, size: number, f: PDFFont, color = C.text, al: Al = "l") => {
    if (!s) return;
    const w = al === "l" ? 0 : wid(s, f, size);
    page.drawText(s, { x: al === "l" ? x : al === "c" ? x - w / 2 : x - w, y: yb(t), size, font: f, color });
  };
  const caps = (s: string, x: number, t: number, size: number, f: PDFFont, color = C.gold, track = 1.6, al: Al = "l"): number => {
    const u = san(s).toUpperCase(); const chs = Array.from(u); const ws = chs.map((ch) => wid(ch, f, size));
    const tot = ws.reduce((a, b) => a + b, 0) + track * (chs.length - 1);
    let cx = al === "l" ? x : al === "c" ? x - tot / 2 : x - tot;
    chs.forEach((ch, i) => { if (ch !== " ") page.drawText(ch, { x: cx, y: yb(t), size, font: f, color }); cx += ws[i] + track; });
    return tot;
  };
  const wrap = (t: string, f: PDFFont, size: number, maxW: number): string[] => {
    const out: string[] = [];
    for (const para of String(t ?? "").split("\n")) {
      if (!para.trim()) { out.push(""); continue; }
      let cur = "";
      for (const w0 of san(para).split(/\s+/).filter(Boolean)) {
        let w = w0;
        while (wid(w, f, size) > maxW) { // hyvin pitkä sana: katkaistaan
          let n = w.length; while (n > 1 && wid(w.slice(0, n), f, size) > maxW) n--;
          if (cur) { out.push(cur); cur = ""; }
          out.push(w.slice(0, n)); w = w.slice(n);
        }
        const tt = cur ? cur + " " + w : w;
        if (wid(tt, f, size) > maxW && cur) { out.push(cur); cur = w; } else cur = tt;
      }
      if (cur) out.push(cur);
    }
    return out;
  };
  /** Yksi rivi mahtumaan: pienennetään kirjasinkokoa, viime kädessä katkaistaan ellipsiin */
  const fit = (s: string, f: PDFFont, size: number, minSize: number, maxW: number) => {
    let sz = size; while (sz > minSize && wid(s, f, sz) > maxW) sz -= 0.5;
    if (wid(s, f, sz) > maxW) { let n = s.length; while (n > 1 && wid(s.slice(0, n) + "…", f, sz) > maxW) n--; s = s.slice(0, n).trimEnd() + "…"; }
    return { s, sz };
  };
  const hline = (x1: number, x2: number, t: number, color = C.accent, th = 0.6) => page.drawLine({ start: { x: x1, y: yb(t) }, end: { x: x2, y: yb(t) }, thickness: th, color });
  /** Kuva peittämään laatikko (cover); fx/fy = kohdistuspiste 0..1 */
  const coverImg = (img: PDFImage, x: number, t: number, w: number, h: number, fx = 0.5, fy = 0.5) => {
    const sc = Math.max(w / img.width, h / img.height); const iw = img.width * sc, ih = img.height * sc;
    page.drawImage(img, { x: x - (iw - w) * fx, y: yb(t + h) - (ih - h) * (1 - fy), width: iw, height: ih });
  };
  const clipOps = (ops: any[]) => page.pushOperators(pushGraphicsState(), ...ops, clip(), endPath());
  const archOps = (x: number, t: number, w: number, h: number) => {
    const r = w / 2, k = 0.5523 * r, yt = yb(t), yB = yb(t + h);
    return [moveTo(x, yB), lineTo(x, yt - r), appendBezierCurve(x, yt - r + k, x + r - k, yt, x + r, yt), appendBezierCurve(x + r + k, yt, x + w, yt - r + k, x + w, yt - r), lineTo(x + w, yB), closePath()];
  };
  const archSvg = (w: number, h: number, inset = 0) => { const r = w / 2 - inset, x0 = inset, x1 = w - inset; return `M ${x0} ${h - inset} V ${r + inset} A ${r} ${r} 0 0 1 ${x1} ${r + inset} V ${h - inset} Z`; };
  const stamp = (cx: number, t: number, size = 30) => {
    if (!stampTxt) return;
    const chs = Array.from(stampTxt), tr = 3, ws = chs.map((ch) => wid(ch, serifB, size)), tot = ws.reduce((x, y) => x + y, 0) + tr * (chs.length - 1);
    const bh = size * 1.55, bw = tot + 36, a = 9 * Math.PI / 180;      // laatikko + 9 asteen kierto
    page.pushOperators(pushGraphicsState(), concatTransformationMatrix(Math.cos(a), Math.sin(a), -Math.sin(a), Math.cos(a), cx, yb(t)));
    page.drawRectangle({ x: -bw / 2, y: -bh / 2, width: bw, height: bh, color: C.card, opacity: 0.92, borderColor: C.stamp, borderWidth: 2.2, borderOpacity: 1 });
    page.drawRectangle({ x: -bw / 2 + 4, y: -bh / 2 + 4, width: bw - 8, height: bh - 8, borderColor: C.stamp, borderWidth: 0.7, borderOpacity: 1 });
    let px = -tot / 2; chs.forEach((ch, i) => { page.drawText(ch, { x: px, y: -size * 0.28, size, font: serifB, color: C.stamp }); px += ws[i] + tr; });
    page.pushOperators(popGraphicsState());
  };
  // ---------- taustat ----------
  page.drawRectangle({ x: 0, y: 0, width: W, height: H, color: C.bg });

  layoutKaari();
  return await pdf.save();

  // Asettelu: kaari (keskitetty, print-turvallinen: kaikki marginaalin sisällä, ei täysreunakuvaa)
  function layoutKaari() {
    const M = 22, cx = W / 2, colW = 396, archTop = 50, archWMax = 284;
    const title = en ? "Gift card" : "Lahjakortti", titleSz = 46;
    const logoH = 36, fs = 8, flh = 11.5, footBlockH = Math.max(footLines.length * flh, logoImg ? logoH : 0);
    const footTop = H - M - 16 - footBlockH;
    const target = footTop - 30;                 // viimeisen ohjerivin perusviiva korkeintaan tähän
    const howL = wrap(how, sans, 9.8, 452);
    const n = greeting.length;
    const gStart = n <= 45 ? 28 : n <= 100 ? 24 : n <= 180 ? 21 : 19;

    /** Piirtää koko sisällön; palauttaa viimeisen rivin perusviivan. Kuivakierroksella `page` on väliaikainen sivu. */
    const flow = (archH: number, gap: number, gsz: number): number => {
      // kaari
      const archW = Math.min(archWMax, archH * 1.9);   // matala kaari kapenee, jotta puoliympyrä pysyy kelvollisena
      const ax = cx - archW / 2;
      page.drawSvgPath(archSvg(archW + 14, archH + 7), { x: ax - 7, y: yb(archTop - 7), borderColor: C.accent, borderWidth: 0.7 });
      clipOps(archOps(ax, archTop, archW, archH));
      coverImg(photo, ax, archTop, archW, archH, 0.5, 0.4);
      page.pushOperators(popGraphicsState());
      stamp(cx, archTop + archH - 54, stampTxt.length > 8 ? 26 : 30);
      let t = archTop + archH + gap + titleSz * 0.66;
      txt(title, cx, t, titleSz, serif, C.green, "c"); t += 10 + gap * 0.4;
      // tarjous
      if (isOpen) {
        t += 38; txt(value, cx, t, 46, serif, C.gold, "c"); t += 28; txt(pkgName, cx, t, 16, serifI, C.text, "c"); t += 6;
      } else if (!hidePrice) {      // Johku-kortti: ennallaan (nimi + arvo + sisältö)
        let nsz = 23; let nl = wrap(pkgName, serifB, nsz, colW); if (nl.length > 2) { nsz = 19; nl = wrap(pkgName, serifB, nsz, colW); }
        t += nsz * 0.7;
        for (const l of nl.slice(0, 3)) { txt(l, cx, t, nsz, serifB, C.ink, "c"); t += nsz * 1.08; }
        t += 6; txt(value, cx, t + 14, 26, serif, C.gold, "c"); t += 20;
        const il = wrap(itemLines.join("   ·   "), sans, 10, colW);
        if (il.length) { t += 6; for (const l of il) { t += 13.5; txt(l, cx, t, 10, sans, C.muted, "c"); } }
      } else {                      // lahjakorttipaketti: EI hintaa; paketin nimi ja sisältö isommin esille
        let nsz = 30; let nl = wrap(pkgName, serifB, nsz, colW);
        for (const s2 of [26, 22, 19]) { if (nl.length <= 2) break; nsz = s2; nl = wrap(pkgName, serifB, nsz, colW); }
        t += nsz * 0.72;
        for (const l of nl.slice(0, 3)) { txt(l, cx, t, nsz, serifB, C.ink, "c"); t += nsz * 1.08; }
        const il = itemLines.flatMap((l) => wrap(l, sans, 11.5, colW));
        if (il.length) {
          t += 12; caps(en ? "Includes" : "Sisältää", cx, t + 6, 6.8, sansB, C.gold, 2.4, "c"); t += 10;
          for (const l of il) { t += 16; txt(l, cx, t, 11.5, sans, C.text, "c"); }
        }
      }
      t += gap * 1.3;
      // saaja + tervehdys
      if (recipient) {
        caps(en ? "For" : "Saajalle", cx, t + 4, 7.2, sansB, C.gold, 2.6, "c"); t += 6;
        let rs = 27; while (rs > 15 && wid(recipient, serifB, rs) > colW) rs -= 1;
        for (const l of wrap(recipient, serifB, rs, colW).slice(0, 2)) { t += rs * 1.0; txt(l, cx, t, rs, serifB, C.ink, "c"); t += rs * 0.12; }
        t += 4;
      }
      if (greeting) {
        const lh = gsz * 1.2; t += recipient ? 8 : 0;
        for (const l of wrap(`\u201C${greeting}\u201D`, serifI, gsz, colW)) { t += lh; if (l) txt(l, cx, t, gsz, serifI, C.ink, "c"); }
      }
      if (buyer && greeting) { const f = fit(`— ${buyer}`, serifB, 13.5, 9, colW); t += 24; txt(f.s, cx, t, f.sz, serifB, C.gold, "c"); }
      else if (buyer) {
        t += recipient ? 16 : 0; caps(en ? "From" : "Lahjoittaja", cx, t + 4, 7.2, sansB, C.gold, 2.6, "c"); t += 6;
        const f = fit(buyer, serifB, 21, 13, colW); t += f.sz; txt(f.s, cx, t, f.sz, serifB, C.ink, "c");
      }
      t += 18 + gap;
      // koodi
      const bw = 332, bh = 70, bx = cx - bw / 2;
      page.drawRectangle({ x: bx, y: yb(t + bh), width: bw, height: bh, color: C.green });
      page.drawRectangle({ x: bx + 4, y: yb(t + bh) + 4, width: bw - 8, height: bh - 8, borderColor: C.accent, borderWidth: 0.6, borderOpacity: 0.75 });
      caps(en ? "Gift card code" : "Lahjakortin koodi", cx, t + 21, 6.8, sansB, C.kick, 2.2, "c");
      let csz = 28; while (csz > 18 && wid(code, mono, csz) > bw - 36) csz -= 1;
      txt(code, cx, t + 51, csz, mono, C.cream, "c");
      t += bh + gap + 6;
      // voimassaolo + muut tiedot
      const cells = ([[en ? "Valid until" : "Voimassa", validTxt], ...meta] as [string, string][]).filter((c) => c[1]);
      const cw = Math.min(150, 450 / cells.length);
      cells.forEach(([k, v], i) => {
        const x = cx - (cells.length * cw) / 2 + cw * i + cw / 2;
        caps(k, x, t, 6.6, sansB, C.muted, 1.8, "c");
        let vs = i === 0 ? 17 : 15; while (vs > 10 && wid(v, serifB, vs) > cw - 12) vs -= 1;
        txt(v, x, t + 20, vs, serifB, C.ink, "c");
        if (i > 0) page.drawLine({ start: { x: x - cw / 2, y: yb(t - 7) }, end: { x: x - cw / 2, y: yb(t + 25) }, thickness: 0.5, color: C.rule });
      });
      t += 36 + gap * 0.5;
      let last = t;
      for (const l of howL) { last = t; txt(l, cx, t, 9.8, sans, C.text, "c"); t += 13; }
      return last;
    };

    // kuivakierros väliaikaisella sivulla: valitaan tervehdyksen koko ja kaaren korkeus niin, että sisältö täyttää sivun
    const realPage = page; const dry = pdf.addPage([W, H]); page = dry;
    let MIN_ARCH = 150; const MAX_ARCH = 340;
    let gsz = gStart;
    const pick = () => { for (const c of [gStart, 20, 18, 17, 16, 15, 14, 13].filter((c) => c <= gStart)) { gsz = c; if (flow(MIN_ARCH, 14, c) <= target) return true; } return false; };
    if (!pick()) { MIN_ARCH = 118; pick(); }       // ei mahdu: ensin pienempi tervehdys, sitten matalampi kaari
    const slack = target - flow(MIN_ARCH, 14, gsz);
    const g1 = Math.min(Math.max(slack, 0) / 6, 9);                         // ensin ilmaa väleihin (korkeintaan +9 pt)
    const archH = Math.max(MIN_ARCH, Math.min(MAX_ARCH, MIN_ARCH + slack - g1 * 6));
    const rem = Math.max(0, slack - g1 * 6 - (archH - MIN_ARCH));
    const gap = 14 + g1 + Math.min(rem / 6, 12);
    pdf.removePage(pdf.getPageCount() - 1); page = realPage;

    page.drawRectangle({ x: M, y: M, width: W - 2 * M, height: H - 2 * M, borderColor: C.accent, borderWidth: 0.6, borderOpacity: 0.8 });
    flow(archH, gap, gsz);
    // alatunniste
    hline(M + 26, W - M - 26, footTop - 4, C.rule, 0.6);
    const tw = Math.max(...footLines.map((l, i) => wid(l, i === 0 ? sansB : sans, fs)));
    const lw = logoImg ? logoH * logoImg.width / logoImg.height : 0;
    const gw = (logoImg ? lw + 14 : 0) + tw, gx = cx - gw / 2; let tx = gx;
    if (logoImg) { page.drawImage(logoImg, { x: gx, y: yb(footTop + 6 + logoH), width: lw, height: logoH }); tx = gx + lw + 14; }
    const ty0 = footTop + 6 + (footBlockH - footLines.length * flh) / 2 + 8.5;
    footLines.forEach((l, i) => txt(l, tx, ty0 + i * flh, fs, i === 0 ? sansB : sans, i === 0 ? C.ink : C.muted));
  }
}
