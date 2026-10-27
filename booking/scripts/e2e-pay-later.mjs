// E2E (Playwright + google-chrome): TESTIVAIHTOEHTO "MAKSU PAIKAN PÄÄLLÄ" (booking_57, public_confirm_pay_later) vahvistussivulla – KOKEILUTILASSA (?mock=1&scenario=hold…): kaikki RPC:t vastataan selaimessa, EI yhteyttä palvelimeen eikä tuotantoon.
//   SHOP_DIST=/tmp/shop-pl node booking/shop/build.mjs   (ensin)
//   PW_DIR=<kansio jossa playwright-core> SHOP_DIST=/tmp/shop-pl SHOT_DIR=/workspace/screenshots-pay-later node booking/scripts/e2e-pay-later.mjs
// Tarkistaa: nappi näkyy vain kun palvelin tarjoaa pay_later-tavan (mock: testui=0 piilottaa; vanha skenaario/vahvistettu/vanhentunut: ei nappia), selite "Testivaihtoehto…" FI+EN, napin kutsu → confirmed_unpaid (pitopaneeli pois,
// "Maksamatta"), virheviestit FI+EN (order_expired, payment_in_progress, pay_later_unavailable, order_cancelled, not_found, verkkovirhe), uudelleenyritys, asettelu 360/390/430/1280 (ei vaakavieritystä), 44 px, kontrasti ≥ 4,5:1, ei sinistä,
// ei konsolivirheitä, ei pyyntöjä backendille. Kuvat FI/EN 390 + 1280: nappi, onnistunut tila, virhetila.
import { createServer } from 'node:http';
import { readFile, stat, mkdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { dirname, join, extname, resolve, normalize } from 'node:path';
import { ht, payLaterError } from '../shop/src/hold-texts.js';
const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const pwPath = require.resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', here].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath));
const chromium = pw.chromium || pw.default.chromium;
const SHOP = resolve(process.env.SHOP_DIST || '/tmp/shop-pl'), SHOT = resolve(process.env.SHOT_DIR || '/workspace/screenshots-pay-later');
await mkdir(SHOT, { recursive: true });
const problems = []; let checks = 0;
const expect = (ok, msg) => { checks++; if (!ok) problems.push(msg); };
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.avif': 'image/avif', '.png': 'image/png', '.jpg': 'image/jpeg', '.txt': 'text/plain', '.xml': 'application/xml' };
const server = createServer(async (req, res) => {
  const p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  let file = join(SHOP, normalize(p));
  try { if ((await stat(file)).isDirectory()) file = join(file, 'index.html'); const buf = await readFile(file); res.writeHead(200, { 'content-type': types[extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' }); res.end(buf); }
  catch { res.writeHead(404, { 'content-type': 'text/plain' }); res.end('Not found'); }
});
await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
const ORIGIN = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const TZ = 'Europe/Helsinki';
const today = new Date().toLocaleDateString('sv-SE', { timeZone: TZ });
const addDays = (ds, n) => { const d = new Date(`${ds}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const WIDTHS = [360, 390, 430, 1280];
const PATH = { fi: { shop: '/varaa/', order: '/tilaus/', confirm: '/varaa/vahvistus/' }, en: { shop: '/en/book/', order: '/en/order/', confirm: '/en/book/confirmation/' } };
const TOKEN = '3f2b8c1e-5a7d-4e9f-8b6a-1c2d3e4f5a6b';

async function newPage(width, lang = 'fi', name = 'p', { deviceSkewMs = 0 } = {}) {
  const mobile = width < 600;
  const ctx = await browser.newContext({ viewport: { width, height: mobile ? 844 : 900 }, isMobile: mobile, hasTouch: mobile, locale: lang === 'en' ? 'en-GB' : 'fi-FI', timezoneId: TZ });
  if (deviceSkewMs) await ctx.addInitScript((skew) => { const R = Date.now.bind(Date); Date.now = () => R() + skew; const O = Date; globalThis.Date = class extends O { constructor(...a) { if (a.length) super(...a); else super(R() + skew); } static now() { return R() + skew; } }; }, deviceSkewMs);   // laitteen kello väärässä
  const page = await ctx.newPage(); page.ctx = ctx;
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type())) problems.push(`${name} console.${m.type()}: ${m.text()} ${m.location().url || ''}`); });
  page.on('pageerror', (e) => problems.push(`${name} pageerror: ${e.message}`));
  page.on('requestfailed', (r) => { if (!/ERR_ABORTED/.test(r.failure()?.errorText || '')) problems.push(`${name} requestfailed: ${r.url()}`); });
  page.on('response', (r) => { if (r.status() >= 400) problems.push(`${name} HTTP ${r.status()}: ${r.url()}`); });
  page.on('request', (r) => { if (!r.url().startsWith(ORIGIN) && !r.url().startsWith('data:')) problems.push(`${name} ulkoinen pyyntö: ${r.url()}`); if (/\/rest\/v1\/|\/functions\/v1\/|:4181/.test(r.url())) problems.push(`${name} PYYNTÖ BACKENDILLE (mock-tilan pitäisi olla offline): ${r.url()}`); });
  return page;
}
const settle = (page) => page.waitForTimeout(150);
// ---- asettelu: ei vaakavieritystä; kosketuskohteet ja kontrasti valitsimen alueella ----
const layout = (page, sel, label) => page.evaluate(({ sel, label }) => {
  const out = [];
  const doc = document.documentElement;
  if (doc.scrollWidth > window.innerWidth + 1) out.push(`${label}: vaakavieritys (scrollWidth ${doc.scrollWidth} > ${window.innerWidth})`);
  const root = sel ? document.querySelector(sel) : document.body;
  if (!root) return [`${label}: alue ${sel} puuttuu`];
  const lum = (c) => { const [r, g, b] = c.map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
  const parse = (s) => { const m = s.match(/rgba?\(([^)]+)\)/); if (!m) return null; const p = m[1].split(',').map((x) => parseFloat(x)); return { rgb: p.slice(0, 3), a: p[3] ?? 1 }; };
  const bgOf = (el) => { let e = el; const stack = []; while (e) { const c = parse(getComputedStyle(e).backgroundColor); if (c && c.a > 0) stack.push(c); if (c && c.a >= 1) break; e = e.parentElement; } let base = [244, 239, 231]; for (const c of stack.reverse()) base = base.map((v, i) => Math.round(c.rgb[i] * c.a + v * (1 - c.a))); return base; };
  const ratio = (a, b) => { const A = lum(a), B = lum(b); return (Math.max(A, B) + 0.05) / (Math.min(A, B) + 0.05); };
  // kosketuskohteet: kortit (label) ja painikkeet
  for (const el of root.querySelectorAll('label.bk-opt-card, button, a.btn, select, input[type=text],input[type=email],input[type=tel]')) {
    const r = el.getBoundingClientRect(); if (!r.width || !r.height || getComputedStyle(el).visibility === 'hidden') continue;
    if (r.height < 43.5 || r.width < 43.5) out.push(`${label}: kosketuskohde ${Math.round(r.width)}x${Math.round(r.height)} (${el.className || el.tagName} "${(el.textContent || '').trim().slice(0, 24)}")`);
    if (r.right > window.innerWidth + 1 || r.left < -1) out.push(`${label}: elementti ulos näkymästä (${el.className || el.tagName})`);
  }
  // kontrasti: tekstisolmut
  const seen = new Set();
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    if (!n.textContent.trim()) continue; const el = n.parentElement; if (!el || seen.has(el)) continue; seen.add(el);
    const cs = getComputedStyle(el); if (cs.visibility === 'hidden' || cs.display === 'none' || !el.getClientRects().length) continue;
    if (el.closest('button:disabled, [aria-disabled=true], .bk-cell.off, .mp-btnwrap, .mp-fallback, .sr-only')) continue; // käytöstä poistetut kalenteripäivät: WCAG-poikkeus (ei-aktiivinen)
    const fg = parse(cs.color); if (!fg) continue; const bg = bgOf(el);
    const eff = fg.rgb.map((v, i) => Math.round(v * fg.a + bg[i] * (1 - fg.a)));
    const size = parseFloat(cs.fontSize), bold = parseInt(cs.fontWeight, 10) >= 700, need = size >= 24 || (size >= 18.66 && bold) ? 3 : 4.5;
    const cr = ratio(eff, bg); if (cr < need) out.push(`${label}: kontrasti ${cr.toFixed(2)} < ${need} (${el.className || el.tagName} "${n.textContent.trim().slice(0, 28)}")`);
  }
  // ei sinistä: reunat/taustat/tekstit alueella (hue 190–260, saturaatio > 0.25)
  const isBlue = (c) => { if (!c || c.a === 0) return false; const [r, g, b] = c.rgb.map((v) => v / 255); const mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn; if (d < 0.12 || mx === 0) return false; const s = d / mx; let h = mx === b ? 4 + (r - g) / d : mx === g ? 2 + (b - r) / d : (g - b) / d % 6; h = ((h * 60) + 360) % 360; return h >= 190 && h <= 260 && s > 0.25; };
  for (const el of root.querySelectorAll('*')) { const cs = getComputedStyle(el); if (!el.getClientRects().length) continue;
    if (el.closest('.mp-btnwrap, .mp-fallback')) continue;   // MobilePayn brändipainike saa olla sininen (ainoa poikkeus)
    for (const k of ['color', 'backgroundColor', 'borderTopColor', 'outlineColor']) { if (k.startsWith('border') && parseFloat(cs.borderTopWidth) === 0) continue; if (k === 'outlineColor' && (cs.outlineStyle === 'none' || parseFloat(cs.outlineWidth) === 0)) continue; if (isBlue(parse(cs[k]))) out.push(`${label}: sininen väri ${k} (${el.className || el.tagName})`); } }
  return out;
}, { sel, label }).then((o) => o.forEach((m) => expect(false, m)));

const goto = async (page, url) => { await page.goto(ORIGIN + url, { waitUntil: 'load' }); await settle(page); };
const text = async (page, sel) => ((await page.textContent(sel)) || '').replace(/\s+/g, ' ').trim();
const has = async (page, sel) => (await page.$(sel)) !== null;
const conf = (lang, sc, extra = '') => `${PATH[lang].confirm}?mock=1&scenario=${sc}${extra}#${TOKEN}`;
const waitHold = (page, state, timeout = 20000) => page.waitForSelector(`[data-testid=hold-panel][data-state=${state}]`, { timeout });
const LABEL = { fi: 'Testivaihtoehto: maksu paikan päällä', en: 'Test option: pay on site' };
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
const waitConfirmed = (page) => page.waitForFunction(() => /vahvistettu|confirmed/i.test(document.querySelector('[data-testid=conf-status]')?.textContent || ''), null, { timeout: 15000 });

// ======================= 1) nappi näkyy, selite, 44 px, järjestys; kuvat 390 + 1280 =======================
for (const lang of ['fi', 'en']) for (const w of [390, 1280]) {
  const page = await newPage(w, lang, `btn-${lang}-${w}`);
  await goto(page, conf(lang, 'hold')); await waitHold(page, 'awaiting_payment');
  expect(await has(page, 'button[data-testid=pc-paylater-btn]'), `${lang} ${w}: nappi <button> näkyy kun palvelin tarjoaa pay_later-tavan`);
  expect((await text(page, '[data-testid=pc-paylater-btn]')) === LABEL[lang], `${lang} ${w}: napin selite "${LABEL[lang]}" (${await text(page, '[data-testid=pc-paylater-btn]')})`);
  expect((await text(page, '[data-testid=pc-paylater] .pc-paylater-note')) === ht(lang, 'payLater.text'), `${lang} ${w}: selitysteksti`);
  expect(!(await has(page, '[data-testid=pc-onsite-test]')), `${lang} ${w}: vanha tietolaatikko poissa`);
  const box = await (await page.$('[data-testid=pc-paylater-btn]')).boundingBox(); expect(box.height >= 43.5 && box.width >= 43.5, `${lang} ${w}: nappi ≥ 44 px (${Math.round(box.width)}x${Math.round(box.height)})`);
  expect(await page.evaluate(() => { const b = document.querySelector('[data-testid=pc-paylater-btn]'), m = document.querySelector('[data-testid=pc-online]'), p = document.querySelector('[data-testid=hold-panel]'); return !!(p.compareDocumentPosition(b) & 4) && !!(m.compareDocumentPosition(b) & 4); }), `${lang} ${w}: nappi pitopaneelin ja verkkomaksun jälkeen`);
  expect(!/vahvistuu, kun koko summa|confirmed once the full amount/i.test(await page.textContent('body')), `${lang} ${w}: poistettu lause ei näy`);
  expect((await text(page, '[data-testid=hold-must]')) === ht(lang, 'mustPay', { minutes: 15 }), `${lang} ${w}: 15 min -ohje jäljellä`);
  await layout(page, '#booking-app', `pay-later nappi ${lang} ${w}`);
  await page.screenshot({ path: join(SHOT, `vahvistus-${lang}-${w}-nappi.png`), fullPage: true });
  await page.ctx.close();
}

// ======================= 2) onnistuminen: confirmed_unpaid =======================
for (const lang of ['fi', 'en']) for (const w of [390, 1280]) {
  const page = await newPage(w, lang, `ok-${lang}-${w}`);
  await goto(page, conf(lang, 'hold')); await waitHold(page, 'awaiting_payment');
  await page.click('[data-testid=pc-paylater-btn]');
  await waitConfirmed(page); await page.waitForSelector('[data-testid=pc-notice]'); await settle(page);
  expect(!(await has(page, '[data-testid=hold-panel]')) && !(await has(page, '[data-testid=hold-timer]')), `${lang} ${w}: onnistui → pitopaneeli ja laskuri pois`);
  expect(!(await has(page, '[data-testid=pc-paylater-btn]')), `${lang} ${w}: onnistui → nappi ei enää tarjolla`);
  const st = await text(page, '[data-testid=conf-status]'), nt = await text(page, '[data-testid=pc-notice]');
  expect(/Varaus vahvistettu|Booking confirmed/.test(st), `${lang} ${w}: tilarivi vahvistettu (${st})`);
  expect(nt.includes(ht(lang, 'payLater.done')), `${lang} ${w}: ilmoitus "${ht(lang, 'payLater.done')}" (${nt})`);
  expect(/Maksamatta|Unpaid/.test(await text(page, 'dl.bk-sum')), `${lang} ${w}: yhteenvedossa maksutila Maksamatta/Unpaid`);
  expect((await text(page, '[data-testid=conf-title]')) !== ht(lang, 'h2.awaiting'), `${lang} ${w}: otsikko ei enää "odottaa maksua"`);
  expect(await has(page, 'a[download]'), `${lang} ${w}: kalenterilisäys tarjolla vahvistuksen jälkeen`);
  expect(await has(page, '[data-testid=pc-online]'), `${lang} ${w}: verkkomaksu jää tarjolle (maksamatta)`);
  await layout(page, '#booking-app', `pay-later onnistui ${lang} ${w}`);
  await page.screenshot({ path: join(SHOT, `vahvistus-${lang}-${w}-onnistui.png`), fullPage: true });
  await page.ctx.close();
}

// ======================= 3) virhetilat FI+EN: viesti, nappi takaisin käyttöön (paitsi kun uudelleenyritys on turha), uudelleenyritys onnistuu =======================
const ERR = ['order_expired', 'payment_in_progress', 'pay_later_unavailable', 'order_cancelled', 'not_found', 'rate_limited'];
for (const lang of ['fi', 'en']) {
  for (const code of ERR) {
    const page = await newPage(390, lang, `err-${lang}-${code}`);
    await goto(page, conf(lang, 'hold', `&plfail=${code}`)); await waitHold(page, 'awaiting_payment');
    await page.click('[data-testid=pc-paylater-btn]');
    await page.waitForFunction(() => !document.querySelector('[data-testid=pc-paylater-error]')?.hidden, null, { timeout: 10000 });
    const msg = await text(page, '[data-testid=pc-paylater-error]');
    expect(msg === payLaterError(lang, code) && msg.length > 20, `${lang} ${code}: ystävällinen viesti (${msg})`);
    expect((await page.getAttribute('[data-testid=pc-paylater-error]', 'role')) === 'alert', `${lang} ${code}: viesti role=alert`);
    const dis = await page.isDisabled('[data-testid=pc-paylater-btn]');
    const finalCode = ['pay_later_unavailable', 'order_cancelled', 'order_expired'].includes(code);
    expect(dis === finalCode, `${lang} ${code}: nappi ${finalCode ? 'pois käytöstä' : 'takaisin käyttöön'} (disabled=${dis})`);
    expect(!(await has(page, '[data-testid=conf-status]:has-text("vahvistettu")')) && (await has(page, '[data-testid=hold-panel]')), `${lang} ${code}: tila ei muuttunut vahvistetuksi`);
    if (!finalCode) {   // plfail laukeaa kerran → toinen yritys onnistuu
      await page.click('[data-testid=pc-paylater-btn]'); await waitConfirmed(page);
      expect(!(await has(page, '[data-testid=hold-panel]')), `${lang} ${code}: uudelleenyritys onnistui`);
    }
    if (code === 'order_expired' || code === 'payment_in_progress') { /* kuvat alla */ }
    await layout(page, '#booking-app', `pay-later virhe ${lang} ${code}`);
    await page.ctx.close();
  }
  for (const w of [390, 1280]) {
    const page = await newPage(w, lang, `errshot-${lang}-${w}`);
    await goto(page, conf(lang, 'hold', '&plfail=payment_in_progress')); await waitHold(page, 'awaiting_payment');
    await page.click('[data-testid=pc-paylater-btn]'); await page.waitForFunction(() => !document.querySelector('[data-testid=pc-paylater-error]')?.hidden);
    await layout(page, '#booking-app', `pay-later virhekuva ${lang} ${w}`); await settle(page);
    await page.screenshot({ path: join(SHOT, `vahvistus-${lang}-${w}-virhe.png`), fullPage: true });
    await page.ctx.close();
  }
}
{   // oikea tila vanhentunut kesken: pito vanhenee ennen painallusta → order_expired-viesti tai vanhentunut-näkymä (ei kaadu)
  const page = await newPage(390, 'fi', 'err-real-expired');
  await goto(page, conf('fi', 'hold', '&holdsec=3')); await waitHold(page, 'awaiting_payment');
  await page.waitForTimeout(3500);
  const btn = await page.$('[data-testid=pc-paylater-btn]');
  if (btn) { await btn.click().catch(() => {}); await page.waitForTimeout(600); }
  await waitHold(page, 'expired', 15000);
  expect(!(await has(page, '[data-testid=pc-paylater-btn]')) || (await page.isDisabled('[data-testid=pc-paylater-btn]')), 'vanhentunut pito: nappi ei toimi');
  await page.ctx.close();
}

// ======================= 4) ei nappia kun palvelin ei tarjoa (testui=0, vanha skenaario, vahvistettu, vanhentunut, peruttu, alustava) =======================
for (const [sc, extra, label] of [['hold', '&testui=0', 'testui=0 (tuotanto: lippu false)'], ['pay', '', 'vanha skenaario pay'], ['hold-unpaid', '', 'vahvistettu maksamatta'], ['hold-confirmed', '', 'vahvistettu'], ['hold-expired', '', 'vanhentunut'], ['hold-cancelled', '', 'peruttu'], ['hold-preliminary', '', 'alustava']]) {
  const page = await newPage(390, 'fi', `none-${sc}`);
  await goto(page, conf('fi', sc, extra)); await page.waitForSelector('[data-testid=conf-status]');
  expect(!(await has(page, '[data-testid=pc-paylater]')) && !(await has(page, '[data-testid=pc-paylater-btn]')) && !(await has(page, '[data-testid=pc-onsite-test]')), `ei nappia: ${label}`);
  await page.ctx.close();
}
{   // testui ei tuo nappia ilman palvelimen tapaa: BOOKING_CONFIG.mobilepayTestUi=true + scenario pay
  const page = await newPage(390, 'fi', 'none-cfg');
  await page.addInitScript(() => { window.BOOKING_CONFIG = { ...(window.BOOKING_CONFIG || {}), mobilepayTestUi: true }; });
  await goto(page, conf('fi', 'pay')); await page.waitForSelector('[data-testid=pc-online]');
  expect(!(await has(page, '[data-testid=pc-paylater-btn]')), 'env testUi ei riitä: ei nappia ilman pay_later-tapaa palvelimelta');
  await page.ctx.close();
}

// ======================= 5) asettelu 360/390/430/1280: nappi, virhe, onnistuminen =======================
for (const lang of ['fi', 'en']) for (const w of [360, 390, 430, 1280]) {
  const page = await newPage(w, lang, `layout-${lang}-${w}`);
  await goto(page, conf(lang, 'hold', '&plfail=order_expired')); await waitHold(page, 'awaiting_payment');
  expect(await noHScroll(page), `${lang} ${w}: ei vaakavieritystä (nappi)`); await layout(page, '#booking-app', `layout nappi ${lang} ${w}`);
  await page.click('[data-testid=pc-paylater-btn]'); await page.waitForFunction(() => !document.querySelector('[data-testid=pc-paylater-error]')?.hidden);
  expect(await noHScroll(page), `${lang} ${w}: ei vaakavieritystä (virhe)`); await layout(page, '#booking-app', `layout virhe ${lang} ${w}`);
  await page.goto(ORIGIN + conf(lang, 'hold', '&holdsec=900'), { waitUntil: 'load' }); await waitHold(page, 'awaiting_payment');
  await page.click('[data-testid=pc-paylater-btn]'); await waitConfirmed(page); await settle(page);
  expect(await noHScroll(page), `${lang} ${w}: ei vaakavieritystä (onnistui)`); await layout(page, '#booking-app', `layout onnistui ${lang} ${w}`);
  await page.ctx.close();
}

await browser.close(); server.close();
if (problems.length) { console.error(`EPÄONNISTUI (${problems.length} ongelmaa, ${checks} tarkistusta):\n- ` + [...new Set(problems)].join('\n- ')); process.exit(1); }
console.log(`OK: ${checks} tarkistusta, kuvat: ${SHOT}`);
