// E2E (Playwright + google-chrome): pakettituote "Saunarituaali ja savusaunavuoro (la & su)" (kb 7, booking_58, sopimus §17.11) kaupassa – KOKEILUTILASSA (?mock=1): kaikki RPC:t vastataan selaimessa,
// EI yhteyttä palvelimeen eikä tuotantoon.
//   SHOP_DIST=/tmp/shop-saunarituaali node booking/shop/build.mjs   (ensin)
//   PW_DIR=/workspace/pw/node_modules SHOP_DIST=/tmp/shop-saunarituaali SHOT_DIR=/workspace/screenshots-saunarituaali node booking/scripts/e2e-saunarituaali.mjs
// Tarkistaa: tuote tuotelistassa (kortti: hinta 49 €/hlö, kesto, aikajana FI+EN, ei kuvaa → siisti tyhjätila), tuotesivu (aikajana, henkilömäärä 1–6, vain la/su, alkuajat 16:00/16:30/17:00, loppuaika = alku + 2 h,
// ei hoitovalitsinta, ei "null"-tekstiä), päivänäkymä (vain la/su), kassa (loppuaika + aikataulu), tarkistus, vahvistus (+ pito-paneeli), virheet, "Ei vapaita aikoja" / "No available times",
// asettelu 360/390/430/1280 (ei vaakavieritystä), kosketuskohteet ≥ 44 px, kontrasti ≥ 4,5:1, ei sinistä, ei konsolivirheitä, ei pyyntöjä backendille.
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
const SHOP = resolve(process.env.SHOP_DIST || '/tmp/shop-saunarituaali'), SHOT = resolve(process.env.SHOT_DIR || '/workspace/screenshots-saunarituaali');
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


const SLUG = 'saunarituaali-ja-savusaunavuoro';
const TL = { fi: 'rituaali 20 min · tauko 10 min · savusauna 1 h 30 min', en: 'ritual 20 min · break 10 min · smoke sauna 1 h 30 min' };
const NAME = { fi: 'Saunarituaali ja savusaunavuoro (la & su)', en: 'Sauna Ritual & Smoke Sauna Session' };
const NOTIMES = { fi: 'Ei vapaita aikoja', en: 'No available times' };
const norm = (s) => (s || '').replace(/\s+/g, ' ').trim();
const dow = (ds) => new Date(`${ds}T12:00:00Z`).getUTCDay();
const plus2h = (hhmm) => `${String((+hhmm.slice(0, 2) + 2) % 24).padStart(2, '0')}${hhmm.slice(2)}`;
const noNull = async (page, label) => { const tx = await page.locator('#booking-app').innerText(); expect(!/(^|\s)null(\s|$)|undefined|NaN/.test(tx), `${label}: sivulla "null"/"undefined"/"NaN"-teksti`); };
const card = (page) => page.locator('.bk-card', { has: page.locator(`a[href*="${SLUG}"]`) }).first();
const shopUrl = (lang, hash, qs = '') => `${PATH[lang].shop}?mock=1${qs}#${hash}`;
// kaikki vapaat päivät varausikkunassa (kuukausinäkymä + seuraava kuukausi) → [{ ds, times:[HH:MM] }]
async function collectDays(page) {
  const out = new Map();
  for (let m = 0; m < 3; m++) {
    const cells = await page.$$eval('button.bk-cell.free', (els) => els.map((e) => e.dataset.date));
    for (const ds of cells) { if (out.has(ds)) continue; await page.click(`button.bk-cell.free[data-date="${ds}"]`); await page.waitForSelector('.bk-times .bk-time-btn'); out.set(ds, await page.$$eval('.bk-time-btn', (b) => b.map((x) => ({ t: x.querySelector('strong').textContent, end: x.querySelector('.bk-time-end')?.textContent || '' })))); }
    const next = page.locator('.bk-calnav button').last(); if (await next.isDisabled()) break; await next.click(); await settle(page);
  }
  for (let i = 0; i < 4; i++) { const prev = page.locator('.bk-calnav button').first(); if (await prev.isDisabled()) break; await prev.click(); await settle(page); }   // takaisin ensimmäiseen kuukauteen
  await page.waitForSelector('.bk-cal-tr .bk-grid');
  return out;
}

// ======================= 1) TUOTELISTA: kortti (FI + EN, 4 leveyttä) =======================
for (const lang of ['fi', 'en']) for (const w of WIDTHS) {
  const page = await newPage(w, lang, `lista-${lang}-${w}`);
  await goto(page, shopUrl(lang, '/?k=hoito')); await page.waitForSelector('.bk-cards'); await page.waitForTimeout(300);
  const names = await page.$$eval('.bk-card h3', (e) => e.map((x) => x.textContent));
  expect(names.length === 5 && names[4] === NAME[lang], `${lang}/${w}: hoitolistalla 5 korttia, paketti viimeisenä: ${names}`);
  const c = card(page);
  expect(norm(await c.locator('h3').innerText()) === NAME[lang], `${lang}/${w}: kortin nimi`);
  expect(/49/.test(await c.locator('.bk-meta strong').innerText()) && /hlö|person/.test(await c.locator('.bk-meta strong').innerText()), `${lang}/${w}: hinta 49 €/hlö: ${await c.locator('.bk-meta strong').innerText()}`);
  expect(norm(await c.locator('.bk-meta').innerText()).endsWith('2 h'), `${lang}/${w}: kesto 2 h: ${norm(await c.locator('.bk-meta').innerText())}`);
  expect(norm(await c.locator('[data-testid=timeline] .bk-tl-text').innerText()) === TL[lang], `${lang}/${w}: aikajanateksti: ${norm(await c.locator('[data-testid=timeline] .bk-tl-text').innerText())}`);
  expect((await c.locator('.bk-meta').innerText()).indexOf('yhteensä') < 0 && !/rituaali 20 min \+/.test(await c.locator('.bk-meta').innerText()), `${lang}/${w}: palvelimen pitkä duration_text ei toistu hintarivillä`);
  expect((await c.locator('.bk-img').count()) === 0, `${lang}/${w}: ei kuvaa → ei tyhjää kuvalaatikkoa`);
  const box = await c.boundingBox(); const btn = await c.locator('a.btn').boundingBox();
  expect(btn.y + btn.height <= box.y + box.height + 1, `${lang}/${w}: painike kortin sisällä`);
  await noNull(page, `lista ${lang}/${w}`);
  await layout(page, '#booking-app', `lista ${lang} ${w}`);
  if (lang === 'fi' && [360, 390, 1280].includes(w)) await c.screenshot({ path: join(SHOT, `lista-${w}-kortti-fi.png`) });
  if (lang === 'en' && [390, 1280].includes(w)) await c.screenshot({ path: join(SHOT, `lista-${w}-kortti-en.png`) });
  if (w === 390) await page.screenshot({ path: join(SHOT, `lista-390-${lang}-hoidot.png`), fullPage: true });
  await goto(page, shopUrl(lang, '/?k=all')); await page.waitForSelector('.bk-cards');
  expect((await card(page).count()) === 1, `${lang}/${w}: paketti myös "Kaikki"-listalla`);
  await page.ctx.close();
}

// ======================= 2) TUOTESIVU: aikajana, henkilömäärä, la/su, alkuajat, loppuaika (FI + EN, 4 leveyttä) =======================
let weekendDay = null;
for (const lang of ['fi', 'en']) for (const w of WIDTHS) {
  const page = await newPage(w, lang, `tuote-${lang}-${w}`);
  await goto(page, shopUrl(lang, `/tuote/${SLUG}`)); await page.waitForSelector('.bk-picker'); await page.waitForSelector('.bk-cal-tr .bk-grid');
  expect(norm(await page.locator('main .hero.page h1').innerText()) === NAME[lang], `${lang}/${w}: hero-otsikko = tuotteen nimi`);
  expect((await page.locator('main .hero.page.has-prod').count()) === 0, `${lang}/${w}: ei tuotekuvaa → oletushero (ei rikkinäistä kuvaa)`);
  expect(norm(await page.locator('#booking-app [data-testid=timeline] .bk-tl-text').innerText()) === TL[lang], `${lang}/${w}: tuotesivun aikajanateksti`);
  expect((await page.locator('#booking-app .bk-tl-seg').count()) === 3, `${lang}/${w}: aikajanakaista 3 jaksoa`);
  expect((await page.locator('[data-testid=option-picker], .bk-opt, .bk-step-opt').count()) === 0, `${lang}/${w}: ei hoitovalitsinta`);
  expect(/49/.test(await page.locator('#booking-app > .bk-meta strong').innerText()), `${lang}/${w}: hinta 49 €/hlö`);
  const heads = (await page.locator('.bk-picker h3').allInnerTexts()).map((x) => x.replace(/^\d\s*/, '').trim());
  expect(heads.length === 3 && heads[0].length > 0, `${lang}/${w}: vaiheet 1–3 (ei valitsinvaihetta): ${heads}`);
  // henkilömäärä 1–6
  const plus = page.locator('.bk-step').last(), minus = page.locator('.bk-step').first();
  expect(await minus.isDisabled() && (await page.inputValue('#tr-n')) === '1', `${lang}/${w}: alku 1 hlö, vähennä pois käytöstä`);
  let n = 1; while (!(await plus.isDisabled()) && n < 10) { await plus.click(); n++; }
  expect(n === 6 && (await page.inputValue('#tr-n')) === '6', `${lang}/${w}: henkilömäärän yläraja ${n} (odotettu 6)`);
  while (n > 1) { await minus.click(); n--; }
  await page.waitForSelector('button.bk-cell.free');
  // päivät ja ajat
  const days = await collectDays(page);
  expect(days.size > 0, `${lang}/${w}: ei yhtään vapaata päivää varausikkunassa`);
  for (const [ds, times] of days) {
    expect([0, 6].includes(dow(ds)), `${lang}/${w} ${ds}: tarjolla muuna kuin la/su (dow ${dow(ds)})`);
    for (const x of times) {
      expect(['16:00', '16:30', '17:00'].includes(x.t), `${lang}/${w} ${ds}: alkuaika ${x.t}`);
      expect(x.end === `–${plus2h(x.t)}`, `${lang}/${w} ${ds} ${x.t}: loppuaika ${x.end} (odotettu –${plus2h(x.t)} = alku + 2 h)`);
    }
  }
  weekendDay ||= [...days.keys()][0];
  await noNull(page, `tuote ${lang}/${w}`);
  await layout(page, '#booking-app', `tuote ${lang} ${w}`);
  if (lang === 'fi' && [360, 390, 1280].includes(w)) await page.screenshot({ path: join(SHOT, `tuotesivu-${w}-fi.png`), fullPage: true });
  if (lang === 'en' && [390, 1280].includes(w)) await page.screenshot({ path: join(SHOT, `tuotesivu-${w}-en.png`), fullPage: true });
  // valitse päivä + aika → yhteenveto, jatka
  await page.click(`button.bk-cell.free[data-date="${[...days.keys()][0]}"]`); await page.waitForSelector('.bk-time-btn'); await page.click('.bk-time-btn'); await settle(page);
  expect(!(await page.isDisabled('.bk-continue .btn')), `${lang}/${w}: jatka sallittu ilman hoitovalintaa`);
  expect(/49/.test(await page.textContent('.bk-pick-sum')) && !/null/.test(await page.textContent('.bk-pick-sum')), `${lang}/${w}: valinnan yhteenveto: ${await page.textContent('.bk-pick-sum')}`);
  expect(!/[?&]o=/.test(page.url()), `${lang}/${w}: URL:ssa ei hoitovalintaa (${page.url()})`);
  await layout(page, '#booking-app', `tuote-valittu ${lang} ${w}`);
  if (lang === 'fi' && w === 390) await page.screenshot({ path: join(SHOT, 'tuotesivu-390-fi-aika-valittu.png'), fullPage: true });
  await page.ctx.close();
}

// ======================= 3) KULKU: tuote → kassa → tarkistus → vahvistus (FI 390, EN 1280; 3 hlö, 147 €) =======================
async function toCheckout(lang, w, qs = '', persons = 3, name = `kulku-${lang}-${w}`) {
  const page = await newPage(w, lang, name);
  await goto(page, shopUrl(lang, `/tuote/${SLUG}`, qs)); await page.waitForSelector('button.bk-cell.free');
  for (let i = 1; i < persons; i++) await page.click('.bk-step >> nth=1');
  await page.waitForTimeout(700); await page.waitForSelector('button.bk-cell.free');
  const ds = await pickDay(page, 3); await page.waitForSelector('.bk-time-btn'); await page.click('.bk-time-btn >> nth=0'); await settle(page);
  const start = (await page.textContent('.bk-time-btn[aria-pressed=true] strong')).trim();
  await page.click('.bk-continue .btn'); await page.waitForSelector('.bk-checkout');
  return { page, ds, start };
}
const fillAndReview = async (page) => {
  const names = await page.$$eval('.bk-form input, .bk-form textarea', (els) => els.map((e) => `${e.name}|${e.id}|${e.type}`));
  const set = async (re, v) => { const n = names.find((x) => re.test(x)); if (n) { const [name, id] = n.split('|'); await page.fill(id ? `#${id}` : `[name="${name}"]`, v); } };
  await set(/^name\|/i, 'Testi Asiakas'); await set(/email/i, EMAIL.v); await set(/phone|tel/i, '+358401234567');
  await page.$$eval('.bk-form input[type=checkbox]', (els) => { const t = els.find((e) => /terms|ehdot/i.test(e.name + e.id)) || els[0]; if (t && !t.checked) t.click(); });
  await page.click('.bk-form button[type=submit]'); await settle(page);
};
const EMAIL = { v: 'testi@example.com' };
for (const [lang, w] of [['fi', 390], ['en', 1280], ['fi', 360], ['en', 430]]) {
  EMAIL.v = 'testi@example.com';
  const { page, ds, start } = await toCheckout(lang, w);
  const end = plus2h(start.replace(':', '')).replace(/^(\d\d)/, '$1:');
  const endHm = `${String((+start.slice(0, 2) + 2) % 24).padStart(2, '0')}:${start.slice(3)}`;
  expect(page.url().includes('mock=1') && !/[?&]o=/.test(page.url()), `${lang}/${w}: kassan URL säilyttää mock, ei valintaa: ${page.url()}`);
  const sumTxt = norm(await page.locator('aside.bk-aside').innerText());
  expect(sumTxt.includes(`${start}–${endHm}`), `${lang}/${w}: kassan yhteenvedossa loppuaika ${start}–${endHm}: ${sumTxt}`);
  expect(/147/.test(await page.textContent('.bk-total')), `${lang}/${w}: summa 3 × 49 = 147: ${await page.textContent('.bk-total')}`);
  expect(norm(await page.locator('.bk-pick-when').innerText()).includes(`${start}–${endHm}`), `${lang}/${w}: valintapalkissa loppuaika`);
  const sch = (await page.locator('aside [data-testid=schedule] .bk-sched-line').allInnerTexts()).map(norm);
  const add = (hhmm, m) => { const [H, M] = hhmm.split(':').map(Number), t = H * 60 + M + m; return `${String(Math.floor(t / 60) % 24).padStart(2, '0')}:${String(t % 60).padStart(2, '0')}`; };
  const L = lang === 'fi' ? ['rituaali', 'tauko', 'savusauna'] : ['ritual', 'break', 'smoke sauna'];
  expect(JSON.stringify(sch) === JSON.stringify([`${L[0]} ${start}–${add(start, 20)}`, `${L[1]} ${add(start, 20)}–${add(start, 30)}`, `${L[2]} ${add(start, 30)}–${add(start, 120)}`]), `${lang}/${w}: aikataulu ${JSON.stringify(sch)}`);
  expect((await page.locator('.bk-checkout [data-testid=option-picker], .bk-opt').count()) === 0 && (await page.locator('[data-testid=sum-option]').count()) === 0, `${lang}/${w}: kassalla ei hoitovalitsinta`);
  await noNull(page, `kassa ${lang}/${w}`);
  await layout(page, '#booking-app', `kassa ${lang} ${w}`);
  if (lang === 'fi' && [360, 390].includes(w)) await page.screenshot({ path: join(SHOT, `kassa-${w}-fi.png`), fullPage: true });
  if (lang === 'en' && w === 1280) await page.screenshot({ path: join(SHOT, 'kassa-1280-en.png'), fullPage: true });
  await fillAndReview(page);
  await page.waitForSelector('#tr-review-h');
  const rev = norm(await page.locator('.bk-review').innerText());
  expect(rev.includes(`${start}–${endHm}`) && rev.includes(NAME[lang]) && !/null/.test(rev), `${lang}/${w}: tarkistuksessa nimi + loppuaika`);
  expect((await page.locator('.bk-review [data-testid=schedule] .bk-sched-line').count()) === 3, `${lang}/${w}: tarkistuksessa aikataulu`);
  expect((await page.locator('[data-testid=review-option]').count()) === 0, `${lang}/${w}: tarkistuksessa ei hoitovalintariviä`);
  await layout(page, '#booking-app', `tarkistus ${lang} ${w}`);
  if (lang === 'fi' && w === 390) await page.screenshot({ path: join(SHOT, 'tarkistus-390-fi.png'), fullPage: true });
  await page.click('.bk-review .bk-actions .btn:not(.light)'); await page.waitForSelector('[data-testid=conf-summary]');   // luonti ILMAN p_option_code (mock palauttaisi invalid_option)
  const conf = norm(await page.locator('[data-testid=conf-summary]').innerText());
  expect(conf.includes(NAME[lang]) && new RegExp(`${start.slice(0,2)}(:${start.slice(3)})?–${endHm.slice(0,2)}(:${endHm.slice(3)})?`).test(conf) && /147/.test(conf), `${lang}/${w}: vahvistussivulla nimi, aika ${start}–${endHm}, 147 €: ${conf}`);
  expect((await page.locator('[data-testid=conf-option]').count()) === 0, `${lang}/${w}: vahvistussivulla ei hoitovalintariviä`);
  await layout(page, '#booking-app', `vahvistus ${lang} ${w}`);
  if (lang === 'fi' && w === 390) await page.screenshot({ path: join(SHOT, 'vahvistus-390-fi.png'), fullPage: true });
  if (lang === 'en' && w === 1280) await page.screenshot({ path: join(SHOT, 'vahvistus-1280-en.png'), fullPage: true });
  await page.ctx.close();
  void ds;
}

// ======================= 4) PITO (§17): scenario=hold → vahvistussivulla pito-paneeli ja 15 min laskuri kuten muilla tuotteilla =======================
for (const lang of ['fi', 'en']) {
  const { page } = await toCheckout(lang, 390, '&scenario=hold', 2, `pito-${lang}`);
  await fillAndReview(page); await page.waitForSelector('#tr-review-h');
  expect(/pito|hold|vahvista|confirm|varaa|book|maksa|pay/i.test(await page.textContent('[data-testid=review-submit]')), `${lang}: pitokassan painike`);
  await page.click('[data-testid=review-submit]'); await page.waitForSelector('[data-testid=hold-panel]', { timeout: 20000 });
  expect(page.url().includes('scenario=hold') && page.url().includes('mock=1'), `${lang}: ohjaus säilyttää mock-parametrit`);
  const state = await page.getAttribute('[data-testid=hold-panel]', 'data-state');
  const tm = (await page.textContent('[data-testid=hold-timer]')).match(/^(\d\d):(\d\d)$/);
  expect(state === 'awaiting_payment' && tm && +tm[1] === 14 && +tm[2] >= 40 || (tm && +tm[1] === 15), `${lang}: hold-paneeli awaiting_payment, laskuri ~15 min (${state} ${tm && tm[0]})`);
  expect((await page.textContent('[data-testid=conf-summary]')).includes(NAME[lang]), `${lang}: pitosivun yhteenvedossa tuotteen nimi`);
  expect((await page.locator('[data-testid=hold-panel] >> text=/null|undefined/').count()) === 0, `${lang}: hold-paneelissa ei null`);
  await layout(page, '#booking-app', `pito ${lang} 390`);
  if (lang === 'fi') await page.screenshot({ path: join(SHOT, 'pito-390-fi.png'), fullPage: true });
  await page.ctx.close();
}

// ======================= 5) VIRHEET: aika varattu (taken@test.fi) ja aikaikkuna; "Ei vapaita aikoja" =======================
for (const lang of ['fi', 'en']) {
  EMAIL.v = 'taken@test.fi';
  const { page } = await toCheckout(lang, 390, '', 1, `virhe-${lang}`);
  await fillAndReview(page); await page.waitForSelector('#tr-review-h');
  await page.click('[data-testid=review-submit]'); await page.waitForSelector('#bk-rmsg .bk-error, .bk-error', { timeout: 10000 });
  const e = norm(await page.locator('.bk-error').first().innerText());
  expect(e.length > 10 && !/null|undefined|slot_unavailable/.test(e), `${lang}: "aika ei vapaana" -virhe asiakkaan kielellä: ${e}`);
  await layout(page, '#booking-app', `virhe ${lang} 390`);
  if (lang === 'fi') await page.screenshot({ path: join(SHOT, 'virhe-390-fi-aika-varattu.png'), fullPage: true });
  await page.ctx.close();
  EMAIL.v = 'testi@example.com';
  const pg = await newPage(lang === 'fi' ? 390 : 360, lang, `eiaikoja-${lang}`);
  await goto(pg, shopUrl(lang, `/tuote/${SLUG}`, '&fail=notimes')); await pg.waitForSelector('[data-testid=no-times]', { timeout: 15000 });
  expect(norm(await pg.locator('[data-testid=no-times] strong').innerText()) === NOTIMES[lang], `${lang}: "${NOTIMES[lang]}": ${await pg.textContent('[data-testid=no-times]')}`);
  expect((await pg.locator('button.bk-cell.free').count()) === 0 && (await pg.locator('[data-testid=timeline]').count()) === 1, `${lang}: ei vapaita päiviä, aikajana näkyy silti`);
  await layout(pg, '#booking-app', `eiaikoja ${lang}`);
  await pg.screenshot({ path: join(SHOT, `ei-vapaita-aikoja-${lang === 'fi' ? '390-fi' : '360-en'}.png`), fullPage: true });
  await pg.ctx.close();
}

// ======================= 6) PÄIVÄNÄKYMÄ: paketti vain la/su =======================
{
  const lang = 'fi';
  // la/su-päivä jolla aikoja (weekendDay) ja arkipäivä (ma–to, sama viikko tai seuraava) jolla on muita hoitoja
  const page = await newPage(390, lang, 'paiva');
  const wk = []; for (let i = 1; i <= 13; i++) wk.push(addDays(today, i));
  const seenPkg = {};
  for (const ds of wk) {
    await goto(page, shopUrl(lang, `/paiva/${ds}`)); await page.waitForSelector('.bk-dayresults', { timeout: 15000 });
    await page.waitForFunction(() => !document.querySelector('.bk-treat-status'), null, { timeout: 15000 });
    seenPkg[ds] = (await page.locator(`.bk-pc[data-slug="${SLUG}"]`).count()) === 1;
  }
  for (const [ds, has] of Object.entries(seenPkg)) if (has) expect([0, 6].includes(dow(ds)), `päivänäkymä ${ds}: paketti tarjolla muuna kuin la/su`);
  const anyWeekend = Object.entries(seenPkg).some(([ds, has]) => has && [0, 6].includes(dow(ds)));
  expect(anyWeekend, `päivänäkymässä paketti näkyy ainakin yhtenä la/su-päivänä (${JSON.stringify(seenPkg)})`);
  const wkday = wk.find((d) => ![0, 6].includes(dow(d)) && dow(d) !== 5); const wkdayRes = await (async () => { await goto(page, shopUrl(lang, `/paiva/${wkday}`)); await page.waitForSelector('.bk-dayresults'); await page.waitForFunction(() => !document.querySelector('.bk-treat-status'), null, { timeout: 15000 }); return page.locator('.bk-pc').count(); })();
  expect(seenPkg[wkday] === false, `päivänäkymä ${wkday} (arki): paketti ei saa näkyä (muita tuotteita ${wkdayRes})`);
  const we = Object.entries(seenPkg).find(([ds, has]) => has && [0, 6].includes(dow(ds)))?.[0];
  if (we) {
    await goto(page, shopUrl(lang, `/paiva/${we}?tuote=${SLUG}`)); await page.waitForSelector(`.bk-pc.open[data-slug="${SLUG}"]`, { timeout: 15000 });
    const li = page.locator(`.bk-pc[data-slug="${SLUG}"]`);
    expect(norm(await li.locator('.bk-pc-tl').innerText()) === TL.fi, `päivänäkymä: aikajanateksti avatussa kortissa: ${norm(await li.locator('.bk-pc-tl').innerText())}`);
    const rows = await li.locator('.bk-slotlist li .bk-time').allInnerTexts();
    expect(rows.length > 0 && rows.every((x) => /^1[67](:(00|30))?[–-]1[89](:(00|30))?$/.test(norm(x).replace(/\s/g, ''))), `päivänäkymän ajat alku–loppu (+2 h): ${rows}`);
    await layout(page, '#booking-app', 'päivänäkymä fi 390');
    await page.screenshot({ path: join(SHOT, 'paivanakyma-390-fi-la-su.png'), fullPage: true });
  }
  await page.setViewportSize({ width: 1280, height: 900 }); await goto(page, shopUrl(lang, `/paiva/${wkday}`)); await page.waitForSelector('.bk-dayresults');
  await page.screenshot({ path: join(SHOT, 'paivanakyma-1280-fi-arki-ei-pakettia.png'), fullPage: true });
  await page.ctx.close();
}

// ======================= 7) LINKKI ETUSIVUN RITUAALIKORTISTA + ei hoitovalitsin muilla tuotteilla muuttunut =======================
{
  const page = await newPage(390, 'fi', 'linkki');
  await goto(page, `${PATH.fi.shop}?mock=1#/tuote/saunahoito-2`); await page.waitForSelector('[data-testid=option-picker]');
  expect((await page.locator('[data-testid=option-picker]').count()) === 1, 'Saunahoito: hoitovalitsin ennallaan');
  await goto(page, `${PATH.fi.shop}?mock=1#/tuote/saunotusrituaali`); await page.waitForSelector('.bk-picker');
  expect((await page.locator('[data-testid=option-picker]').count()) === 0, 'Saunotusrituaali: ei valitsinta');
  await noNull(page, 'saunotusrituaali');
  await page.ctx.close();
}

await browser.close(); server.close();
if (problems.length) { console.error(`EPÄONNISTUI (${problems.length} ongelmaa / ${checks} tarkistusta):\n- ${problems.join('\n- ')}`); process.exit(1); }
console.log(`OK: ${checks} tarkistusta, kuvat: ${SHOT}`);
