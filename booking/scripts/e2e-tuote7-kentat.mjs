// E2E (Playwright + google-chrome): tuotteen 7 (Saunarituaali ja savusaunavuoro) KENTÄT kannasta (booking_61, sopimus §18.11) + lisäpalvelu pyyhe kassalla – KOKEILUTILASSA (?mock=1): EI yhteyttä palvelimeen eikä tuotantoon.
//   SITE_TEXTS_FIXTURE=1 SHOP_DIST=/tmp/shop-kentat node booking/shop/build.mjs   (ensin; fixture = tuotannon julkaistut tekstit + tuontia odottavat uudet avaimet)
//   PW_DIR=/workspace/pw/node_modules SHOP_DIST=/tmp/shop-kentat SHOT_DIR=/workspace/screenshots-tuote7-kentat node booking/scripts/e2e-tuote7-kentat.mjs
// Tarkistaa FI/EN × 390/1280: lahjakorttihuomautus (voucher_note) omana huomautuksenaan eikä kuvauksessa; EN-kuvaus (description_en); aikajana kentistä ilman taukoa (ei "tauko"/"break");
// varausikkuna public_settings-asetuksesta; kassa: pyyhe-lisäpalvelu (hinta palvelimelta 5 €), yhteenveto + hinta + tarkistus; palvelimen lisäpalveluvirhe → kannasta tulevat site_texts-tekstit (FI/EN);
// asettelu (ei vaakavieritystä, kosketuskohteet ≥ 44 px, kontrasti ≥ 4,5:1, ei sinistä), ei konsolivirheitä, ei pyyntöjä backendille. Kuvat: SHOT_DIR.
import { createServer } from 'node:http';
import { readFile, stat, mkdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { dirname, join, extname, resolve, normalize } from 'node:path';
const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const pwPath = require.resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', here].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath));
const chromium = pw.chromium || pw.default.chromium;
const SHOP = resolve(process.env.SHOP_DIST || '/tmp/shop-kentat'), SHOT = resolve(process.env.SHOT_DIR || '/workspace/screenshots-tuote7-kentat');
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
const PATH = { fi: { shop: '/varaa/', order: '/tilaus/' }, en: { shop: '/en/book/', order: '/en/order/' } };
const TOKEN = '3f2b8c1e-5a7d-4e9f-8b6a-1c2d3e4f5a6b';

const STUB = `class B extends HTMLElement{connectedCallback(){const r=this.attachShadow({mode:'open'});r.innerHTML='<button type="button" part="b" style="display:block;width:100%;min-height:48px;background:#2B3A30;color:#fff;border:0;border-radius:24px;font:700 17px sans-serif">'+(this.getAttribute('language')==='en'?'Pay with MobilePay':'Maksa MobilePaylla')+'</button>';r.querySelector('button').addEventListener('click',()=>this.dispatchEvent(new Event('click',{bubbles:true})));}}customElements.get('vipps-mobilepay-button')||customElements.define('vipps-mobilepay-button',B);`;
async function newPage(width, lang = 'fi', name = 'p') {
  const mobile = width < 600;
  const ctx = await browser.newContext({ viewport: { width, height: mobile ? 844 : 900 }, isMobile: mobile, hasTouch: mobile, locale: lang === 'en' ? 'en-GB' : 'fi-FI', timezoneId: TZ });
  await ctx.route('https://cdn.vippsmobilepay.com/**', (route) => route.fulfill({ status: 200, contentType: 'text/javascript', body: STUB }));   // MobilePayn virallinen painike: tynkä (ei verkkoa; tynkä vihreä, ei brändiväriä)
  const page = await ctx.newPage(); page.ctx = ctx;
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type())) problems.push(`${name} console.${m.type()}: ${m.text()} ${m.location().url || ''}`); });
  page.on('pageerror', (e) => problems.push(`${name} pageerror: ${e.message}`));
  page.on('requestfailed', (r) => { if (!/ERR_ABORTED/.test(r.failure()?.errorText || '')) problems.push(`${name} requestfailed: ${r.url()}`); });
  page.on('response', (r) => { if (r.status() >= 400) problems.push(`${name} HTTP ${r.status()}: ${r.url()}`); });
  page.on('request', (r) => { if (!r.url().startsWith(ORIGIN) && !r.url().startsWith('data:') && !r.url().startsWith('https://cdn.vippsmobilepay.com/')) problems.push(`${name} ulkoinen pyyntö: ${r.url()}`); if (/\/rest\/v1\/|\/functions\/v1\/|:4181/.test(r.url())) problems.push(`${name} PYYNTÖ BACKENDILLE (mock-tilan pitäisi olla offline): ${r.url()}`); });
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
  for (const el of root.querySelectorAll('label.bk-opt-card, button, a.btn, a.bk-pick-change, a.bk-navbtn, select, input[type=text],input[type=email],input[type=tel]')) {
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
    if (el.closest('button:disabled, [aria-disabled=true], .bk-cell.off')) continue; // käytöstä poistetut kalenteripäivät: WCAG-poikkeus (ei-aktiivinen)
    const fg = parse(cs.color); if (!fg) continue; const bg = bgOf(el);
    const eff = fg.rgb.map((v, i) => Math.round(v * fg.a + bg[i] * (1 - fg.a)));
    const size = parseFloat(cs.fontSize), bold = parseInt(cs.fontWeight, 10) >= 700, need = size >= 24 || (size >= 18.66 && bold) ? 3 : 4.5;
    const cr = ratio(eff, bg); if (cr < need) out.push(`${label}: kontrasti ${cr.toFixed(2)} < ${need} (${el.className || el.tagName} "${n.textContent.trim().slice(0, 28)}")`);
  }
  // ei sinistä: reunat/taustat/tekstit alueella (hue 190–260, saturaatio > 0.25)
  const isBlue = (c) => { if (!c || c.a === 0) return false; const [r, g, b] = c.rgb.map((v) => v / 255); const mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn; if (d < 0.12 || mx === 0) return false; const s = d / mx; let h = mx === b ? 4 + (r - g) / d : mx === g ? 2 + (b - r) / d : (g - b) / d % 6; h = ((h * 60) + 360) % 360; return h >= 190 && h <= 260 && s > 0.25; };
  for (const el of root.querySelectorAll('*')) { const cs = getComputedStyle(el); if (!el.getClientRects().length) continue;
    for (const k of ['color', 'backgroundColor', 'borderTopColor', 'outlineColor']) { if (k.startsWith('border') && parseFloat(cs.borderTopWidth) === 0) continue; if (k === 'outlineColor' && (cs.outlineStyle === 'none' || parseFloat(cs.outlineWidth) === 0)) continue; if (isBlue(parse(cs[k]))) out.push(`${label}: sininen väri ${k} (${el.className || el.tagName})`); } }
  return out;
}, { sel, label }).then((o) => o.forEach((m) => expect(false, m)));

const pickDay = async (page, minAhead = 4) => {   // valitse ensimmäinen vapaa päivä, joka on vähintään N päivän päässä; palauttaa päivän
  const want = addDays(today, minAhead);
  for (let hop = 0; hop < 3; hop++) {
    const cells = await page.$$eval('button.bk-cell.free', (els) => els.map((e) => e.dataset.date));
    const ds = cells.find((d) => d >= want);
    if (ds) { await page.click(`button.bk-cell.free[data-date="${ds}"]`); await settle(page); return ds; }
    await page.click('.bk-calnav button[aria-label]:last-child'); await settle(page);
  }
  throw new Error('ei vapaata päivää');
};
const goto = async (page, url) => { await page.goto(ORIGIN + url, { waitUntil: 'load' }); await settle(page); };


import { readFileSync } from 'node:fs';
const PROD = JSON.parse(readFileSync(join(here, '../tests/fixtures/prod-catalog-61.json'), 'utf8'));
const ROW = PROD.catalog.find((r) => r.id === 7);
const SITE_FX = JSON.parse(readFileSync(join(here, '../../tests/fixtures/site-texts/rpc.json'), 'utf8'));
const SLUG = 'saunarituaali-ja-savusaunavuoro';
const norm = (s) => (s || '').replace(/\s+/g, ' ').trim();
const shopUrl = (lang, hash, qs = '') => `${PATH[lang].shop}?mock=1${qs}#${hash}`;
const TL = { fi: 'rituaali 20 min · savusauna 1 h 30 min', en: 'ritual 20 min · smoke sauna 1 h 30 min' };
const VOUCHER = { fi: ROW.voucher_note, en: ROW.voucher_note_en };
const DESC = { fi: ROW.description, en: ROW.description_en };
const ERR = (code, lang) => SITE_FX.texts.find((r) => r.key === `ui.checkout.error_${code}` && r.lang === lang).text;
const noNull = async (page, label) => { const tx = await page.locator('#booking-app').innerText(); expect(!/(^|\s)null(\s|$)|undefined|NaN|\{\{/.test(tx), `${label}: sivulla "null"/"undefined"/"NaN"/"{{"-teksti`); };
const shot = async (page, name, opts = {}) => { if (opts.fullPage) await page.evaluate(() => window.scrollTo(0, 0)); await page.screenshot({ path: join(SHOT, `${name}.png`), ...opts }); };   // koko sivu alusta (sticky-otsake ei jää kuvan keskelle)

// ======================= 1) TUOTESIVU: kentät kannasta, FI/EN × 390/1280 =======================
for (const lang of ['fi', 'en']) for (const w of [390, 1280]) {
  const label = `tuotesivu-${lang}-${w}`, page = await newPage(w, lang, label);
  await goto(page, shopUrl(lang, `/tuote/${SLUG}`)); await page.waitForSelector('button.bk-cell.free'); await page.waitForTimeout(300);
  const main = await page.locator('#booking-app').innerText();
  // lahjakorttihuomautus (voucher_note): oma huomautus, ei kuvauksessa
  const vn = page.locator('[data-testid=voucher-note]');
  expect(await vn.count() === 1 && await vn.isVisible(), `${label}: lahjakorttihuomautus näkyy omana huomautuksena`);
  expect(norm(await vn.innerText()) === norm(VOUCHER[lang]), `${label}: huomautuksen teksti = kannan voucher_note${lang === 'en' ? '_en' : ''}: ${norm(await vn.innerText())}`);
  const desc = norm(await page.locator('.bk-desc').first().innerText());
  expect(desc === norm(DESC[lang]), `${label}: kuvaus = kannan description${lang === 'en' ? '_en' : ''}: ${desc.slice(0, 80)}`);
  expect(!desc.includes('Elämyslahjat') && !desc.includes('Elämyslahjojen'), `${label}: kuvauksessa ei lahjakorttihuomautusta`);
  expect(lang === 'fi' ? /^Avoin saunarituaali/.test(desc) : /^Open sauna ritual/.test(desc), `${label}: kuvauksen kieli oikea: ${desc.slice(0, 40)}`);
  // aikajana kannan kentistä: ei taukoa
  expect(norm(await page.locator('[data-testid=timeline] .bk-tl-text').innerText()) === TL[lang], `${label}: aikajanateksti ${norm(await page.locator('[data-testid=timeline] .bk-tl-text').innerText())}`);
  expect(JSON.stringify(await page.$$eval('[data-testid=timeline] .bk-tl-seg', (e) => e.map((x) => x.className.replace('bk-tl-seg ', '')))) === '["ritual","smoke_sauna"]', `${label}: palkissa vain rituaali + savusauna (ei taukoa)`);
  expect(!/tauko|break/i.test(main), `${label}: sivulla ei sanaa tauko/break`);
  // varausikkuna: public_settings().public_treatment_horizon_days (14) – kalenterissa ei vapaita päiviä sen yli
  const free = []; for (let m = 0; m < 3; m++) { free.push(...await page.$$eval('button.bk-cell.free', (els) => els.map((e) => e.dataset.date))); const nx = page.locator('.bk-calnav button').last(); if (await nx.isDisabled()) break; await nx.click(); await settle(page); }
  expect(free.length > 0 && free.every((d) => d <= addDays(today, 14)), `${label}: vapaat päivät ≤ tänään + 14 (asetus public_treatment_horizon_days): viimeinen ${free.at(-1)}`);
  for (let i = 0; i < 3; i++) { const pv = page.locator('.bk-calnav button').first(); if (await pv.isDisabled()) break; await pv.click(); await settle(page); }
  await noNull(page, label);
  await layout(page, '#booking-app', label);
  await page.evaluate(() => window.scrollTo(0, 0)); await shot(page, `tuote7-${lang}-${w}-tuotesivu`, { fullPage: true });
  await page.ctx.close();
}

// ======================= 2) KASSA: pyyhe-lisäpalvelu (hinta palvelimelta), yhteenveto, tarkistus, virhe =======================
async function toCheckout(lang, w, name, persons = 2) {
  const page = await newPage(w, lang, name);
  await goto(page, shopUrl(lang, `/tuote/${SLUG}`)); await page.waitForSelector('button.bk-cell.free');
  for (let i = 1; i < persons; i++) await page.click('.bk-step >> nth=1');
  await page.waitForTimeout(700); await page.waitForSelector('button.bk-cell.free');
  const ds = await pickDay(page, 3); await page.waitForSelector('.bk-time-btn'); await page.click('.bk-time-btn >> nth=0'); await settle(page);
  await page.click('.bk-continue .btn'); await page.waitForSelector('.bk-checkout');
  return page;
}
const fill = async (page, email) => {
  const names = await page.$$eval('.bk-form input, .bk-form textarea', (els) => els.map((e) => `${e.name}|${e.id}|${e.type}`));
  const set = async (re, v) => { const n = names.find((x) => re.test(x)); if (n) { const [name, id] = n.split('|'); await page.fill(id ? `#${id}` : `[name="${name}"]`, v); } };
  await set(/^name\|/i, 'Testi Asiakas'); await set(/email/i, email); await set(/phone|tel/i, '+358401234567');
  await page.$$eval('.bk-form input[type=checkbox]', (els) => { const t = els.find((e) => /terms|ehdot/i.test(e.name + e.id)) || els[0]; if (t && !t.checked) t.click(); });
};
const totalOf = async (page) => (await page.locator('[data-testid=sum-total]').first().innerText()).replace(/[^\d]/g, '');
for (const [lang, w] of [['fi', 390], ['en', 1280], ['fi', 1280], ['en', 390]]) {
  const label = `kassa-${lang}-${w}`, page = await toCheckout(lang, w, label, 2);
  expect(await page.locator('[data-testid=addons]').isVisible(), `${label}: lisäpalvelut-osio näkyy`);
  const row = page.locator('[data-testid=addon-pyyhe]');
  expect(await row.count() === 1 && /5/.test(await row.innerText()) && /(Pyyhe|Towel)/.test(await row.innerText()), `${label}: pyyhe + hinta 5 € palvelimelta: ${norm(await row.innerText())}`);
  expect(await page.locator('[data-testid=addon-turvenaamio_jalkakylpy], [data-testid=addon-saunavihta]').count() === 0, `${label}: vain tuotteelle sallittu lisäpalvelu (pyyhe)`);
  expect(await totalOf(page) === '98', `${label}: ennen lisäpalvelua 2 × 49 = 98: ${await totalOf(page)}`);
  await page.locator('[data-testid=addon-qty-pyyhe]').fill('2'); await page.locator('[data-testid=addon-qty-pyyhe]').dispatchEvent('change'); await settle(page);
  expect(await totalOf(page) === '108', `${label}: 98 + 2 × 5 = 108: ${await totalOf(page)}`);
  expect(/^2 × /.test(norm(await page.locator('[data-testid=sum-addon-pyyhe]').innerText())) && /5/.test(await page.locator('[data-testid=sum-addon-pyyhe]').innerText()), `${label}: yhteenvedossa pyyherivi "2 × 5 €": ${norm(await page.locator('[data-testid=sum-addon-pyyhe]').innerText())}`);
  await page.locator('[data-testid=addon-qty-pyyhe]').scrollIntoViewIfNeeded(); await page.waitForTimeout(100);
  await layout(page, '#booking-app', label);
  await shot(page, `tuote7-${lang}-${w}-kassa-pyyhe`, { fullPage: true });
  await fill(page, 'testi@example.com'); await page.click('.bk-form button[type=submit]'); await settle(page); await page.waitForSelector('#tr-review-h');
  const rv = norm(await page.locator('.bk-review').innerText());
  expect(/pyyhe|towel/i.test(rv) && /2 ×/.test(rv) && rv.replace(/\u00a0/g, '').includes('108'), `${label}: tarkistuksessa pyyhe 2 × ja summa 108: ${rv.slice(0, 200)}`);
  await layout(page, '#booking-app', `${label}-tarkistus`);
  await shot(page, `tuote7-${lang}-${w}-tarkistus`, { fullPage: true });
  await page.click('[data-testid=review-submit]'); await page.waitForTimeout(800);
  const done = norm(await page.locator('#booking-app').innerText());
  expect(!/virhe|error/i.test(done.slice(0, 120)) && /108/.test(done.replace(/\u00a0/g, '')), `${label}: varaus luotu, vahvistuksessa summa 108 (98 + lisäpalvelut): ${done.slice(0, 160)}`);
  await noNull(page, label);
  await shot(page, `tuote7-${lang}-${w}-vahvistus`, { fullPage: true });
  await page.ctx.close();
}

// ---- virhe: palvelin hylkää lisäpalvelut → ystävällinen FI/EN-viesti site_textsistä (ui.checkout.error_<koodi>), valinta tyhjennetty/säilytetty ----
for (const [lang, w] of [['fi', 390], ['en', 1280]]) for (const code of ['addon_inactive', 'addon_quantity', 'addon_not_found', 'addon_not_allowed', 'invalid_addons']) {
  const label = `lisavirhe-${code}-${lang}-${w}`, page = await toCheckout(lang, w, label, 2);
  await page.locator('[data-testid=addon-qty-pyyhe]').fill('1'); await page.locator('[data-testid=addon-qty-pyyhe]').dispatchEvent('change'); await settle(page);
  await fill(page, `${code}@test.fi`); await page.click('.bk-form button[type=submit]'); await settle(page); await page.waitForSelector('#tr-review-h');
  await page.click('[data-testid=review-submit]'); await page.waitForSelector('[data-testid=addon-error]:not([hidden])', { timeout: 10000 });
  const msg = norm(await page.locator('[data-testid=addon-error]').innerText());
  expect(msg === norm(ERR(code, lang)), `${label}: virheteksti = kannan ui.checkout.error_${code} [${lang}]: "${msg}"`);
  expect(!/[a-z]+\.[a-z]+\.error_|^addon_|\{\{/.test(msg), `${label}: ei raakaa avainta`);
  expect(await page.locator('[data-testid=addons]').isVisible(), `${label}: lomake + lisäpalvelut näkyvissä virheen jälkeen`);
  const qtyAfter = await page.locator('[data-testid=addon-qty-pyyhe]').inputValue();
  expect(code === 'addon_quantity' ? qtyAfter === '1' : qtyAfter === '0', `${label}: valinta ${code === 'addon_quantity' ? 'säilyy (määrä korjattavissa)' : 'tyhjennetty'}: ${qtyAfter}`);
  if (['addon_inactive', 'addon_quantity'].includes(code)) { await layout(page, '#booking-app', label); await page.locator('[data-testid=addon-error]').scrollIntoViewIfNeeded(); await shot(page, `tuote7-${lang}-${w}-virhe-${code}`); }
  await page.ctx.close();
}

// ---- varakäyttäytyminen: tekstitiedosto puuttuu (site-texts.json 404) → virheviesti palvelimen message-kentästä, kassa toimii ----
{
  const label = 'ei-tekstitiedostoa', page = await newPage(390, 'fi', label);
  await page.route('**/booking/site-texts.json', (r) => r.fulfill({ status: 404, body: 'x' }));
  page.removeAllListeners('response'); page.on('response', (r) => { if (r.status() >= 400 && !/site-texts\.json/.test(r.url())) problems.push(`${label} HTTP ${r.status()}: ${r.url()}`); });
  page.removeAllListeners('console'); page.on('console', (m) => { if (['error', 'warning'].includes(m.type()) && !/404/.test(m.text())) problems.push(`${label} console.${m.type()}: ${m.text()}`); });
  await goto(page, shopUrl('fi', `/tuote/${SLUG}`)); await page.waitForSelector('button.bk-cell.free');
  await page.waitForTimeout(500); await page.waitForSelector('button.bk-cell.free');
  const ds = await pickDay(page, 3); await page.waitForSelector('.bk-time-btn'); await page.click('.bk-time-btn >> nth=0'); await settle(page); await page.click('.bk-continue .btn'); await page.waitForSelector('.bk-checkout');
  await page.locator('[data-testid=addon-qty-pyyhe]').fill('1'); await page.locator('[data-testid=addon-qty-pyyhe]').dispatchEvent('change');
  await fill(page, 'addon_inactive@test.fi'); await page.click('.bk-form button[type=submit]'); await settle(page); await page.waitForSelector('#tr-review-h');
  await page.click('[data-testid=review-submit]'); await page.waitForSelector('[data-testid=addon-error]:not([hidden])', { timeout: 10000 });
  expect(norm(await page.locator('[data-testid=addon-error]').innerText()) === 'Lisäpalvelut hylättiin', `${label}: avainta ei ole → palvelimen message-kenttä: ${norm(await page.locator('[data-testid=addon-error]').innerText())}`);
  expect(!/error_addon|\{\{/.test(await page.locator('[data-testid=addon-error]').innerText()), `${label}: ei raakaa avainta`);
  expect(await page.locator('[data-testid=voucher-note]').count() === 0, `${label}: (kassalla ei huomautusta)`);
  await page.ctx.close();
}

await browser.close(); server.close();
if (problems.length) { console.error(`EPÄONNISTUI (${problems.length} ongelmaa / ${checks} tarkistusta):\n- ${problems.join('\n- ')}`); process.exit(1); }
console.log(`OK: ${checks} tarkistusta, kuvat: ${SHOT}`);
