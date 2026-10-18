// E2E (Playwright + google-chrome): KASSAN 15 MIN PAIKANPITO (§17) – KOKEILUTILASSA (?mock=1&scenario=hold…): kaikki RPC:t vastataan selaimessa, EI yhteyttä palvelimeen eikä tuotantoon.
//   SHOP_DIST=/tmp/shop-pito node booking/shop/build.mjs   (ensin)
//   PW_DIR=/workspace/node_modules SHOP_DIST=/tmp/shop-pito SHOT_DIR=/workspace/screenshots-kassa-pito node booking/scripts/e2e-kassa-pito.mjs
// Tarkistaa: pitopaneeli (teksti, laskuri role=timer aria-live=off, ilmoitusalue), palvelinaika (serverskew + väärä laitteen kello), vanheneminen → "tee uusi varaus", lahjakorttisana VAIN kun osuus oli käytetty,
// tilat kaikissa näkymissä (vahvistussivu + tilaussivu), käsittely (ei laskuria, ei toista maksua), alustava, kassan virheet FI+EN, vanha käytös ennallaan (scenario=pay), asettelu 360/390/430/1280.
// asettelu 360/390/430/1280 (ei vaakavieritystä), kosketuskohteet ≥ 44 px, kontrasti ≥ 4,5:1, ei sinistä (kehys/täyttö), ei konsolivirheitä, ei pyyntöjä backendille.
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
const SHOP = resolve(process.env.SHOP_DIST || '/tmp/shop-pito'), SHOT = resolve(process.env.SHOT_DIR || '/workspace/screenshots-kassa-pito');
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

const STUB = `class B extends HTMLElement{connectedCallback(){const r=this.attachShadow({mode:'open'});r.innerHTML='<button type="button" part="b" style="display:block;width:100%;min-height:48px;background:#5a78ff;color:#fff;border:0;border-radius:24px;font:700 17px sans-serif">'+(this.getAttribute('language')==='en'?'Pay with MobilePay':'Maksa MobilePaylla')+'</button>';r.querySelector('button').addEventListener('click',()=>this.dispatchEvent(new Event('click',{bubbles:true})));}}customElements.get('vipps-mobilepay-button')||customElements.define('vipps-mobilepay-button',B);`;
async function newPage(width, lang = 'fi', name = 'p', { deviceSkewMs = 0 } = {}) {
  const mobile = width < 600;
  const ctx = await browser.newContext({ viewport: { width, height: mobile ? 844 : 900 }, isMobile: mobile, hasTouch: mobile, locale: lang === 'en' ? 'en-GB' : 'fi-FI', timezoneId: TZ });
  await ctx.route('https://cdn.vippsmobilepay.com/**', (route) => route.fulfill({ status: 200, contentType: 'text/javascript', body: STUB }));   // MobilePayn virallinen painike: tynkä (ei verkkoa)
  if (deviceSkewMs) await ctx.addInitScript((skew) => { const R = Date.now.bind(Date); Date.now = () => R() + skew; const O = Date; globalThis.Date = class extends O { constructor(...a) { if (a.length) super(...a); else super(R() + skew); } static now() { return R() + skew; } }; }, deviceSkewMs);   // laitteen kello väärässä
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

// ---- odotetut tekstit (kirjaimellisesti: testi huomaa jos teksti muuttuu) ----
const X = {
  fi: { expired: 'Paikkavaraus vanheni, koska maksua ei saatu 15 minuutin kuluessa. Mitään ei ole veloitettu. Voit tehdä uuden varauksen.', gift: 'Lahjakortin käytetty osuus on palautettu kortille.',
    unavailable: 'Verkkomaksu ei ole tilapäisesti käytettävissä, joten varausta ei voi tehdä juuri nyt. Yritä myöhemmin uudelleen tai ota yhteyttä meihin.', tooMany: 'Sinulla on jo useita maksamattomia varauksia. Maksa ne tai odota, että ne vanhenevat.',
    expiredErr: 'Paikkavaraus on vanhentunut. Tee uusi varaus.', prelimErr: 'Alustavaa varausta ei makseta ennen kuin olemme vahvistaneet sen. Vahvistamme sen sähköpostitse.', progressErr: 'Maksusi on kesken. Odota hetki ja yritä uudelleen.',
    cont: 'Jatka maksamaan', newBooking: 'Tee uusi varaus', must: 'Varaus täytyy maksaa 15 minuutin sisään, muuten se peruuntuu ja paikka vapautuu.', h2: 'Varauksesi odottaa maksua' },
  en: { expired: 'Your spot hold expired because payment was not received within 15 minutes. You have not been charged. You can make a new booking.', gift: 'Any gift card amount you applied has been returned to the card.',
    unavailable: 'Online payment is temporarily unavailable, so we can’t take bookings right now. Please try again later or contact us.', tooMany: 'You already have several unpaid bookings. Please pay for them or wait for them to expire.',
    expiredErr: 'This hold has expired. Please make a new booking.', prelimErr: 'A provisional booking cannot be paid before we have confirmed it. We will confirm it by email.', progressErr: 'Your payment is in progress. Please wait a moment and try again.',
    cont: 'Continue to payment', newBooking: 'Make a new booking', must: 'The booking must be paid within 15 minutes, otherwise it is cancelled and your spot is released.', h2: 'Your booking is awaiting payment' },
};
const text = async (page, sel) => ((await page.textContent(sel)) || '').replace(/\s+/g, ' ').trim();
const has = async (page, sel) => (await page.$(sel)) !== null;
const secs = async (page) => { const m = (await text(page, '[data-testid=hold-timer]')).match(/^(\d\d):(\d\d)$/); return m ? +m[1] * 60 + +m[2] : null; };
const conf = (lang, sc, extra = '') => `${PATH[lang].confirm}?mock=1&scenario=${sc}${extra}#${TOKEN}`;
const ord = (lang, sc, extra = '') => `${PATH[lang].order}?t=${TOKEN}&mock=1&scenario=${sc}${extra}`;
const waitHold = (page, state, timeout = 20000) => page.waitForSelector(`[data-testid=hold-panel][data-state=${state}]`, { timeout });
const view = (page, kind) => (kind === 'confirm' ? '#booking-app' : '#order-app');

// ======================= 1) odottaa maksua: teksti, laskuri, saavutettavuus, maksuvalinta ennen vahvistusta =======================
for (const lang of ['fi', 'en']) {
  const page = await newPage(390, lang, `hold-${lang}`);
  await goto(page, conf(lang, 'hold')); await waitHold(page, 'awaiting_payment');
  expect(!(await has(page, '[data-testid=hold-lead]')) && !/voimassa 15 minuuttia|held for 15 minutes/.test(await text(page, '[data-testid=hold-panel]')), `${lang}: toistava "Paikkavaraus on voimassa…" -teksti on poistettu paneelista`);
  expect((await text(page, '[data-testid=hold-must]')) === X[lang].must, `${lang}: 15 min -maksuohje kirjaimellisesti (Joonaksen teksti)`);
  expect((await text(page, '[data-testid=conf-title]')) === X[lang].h2, `${lang}: otsikko "${X[lang].h2}" (ei "Kiitos varauksesta!")`);
  expect(await page.evaluate(() => { const st = document.querySelector('[data-testid=conf-status]'), m = document.querySelector('[data-testid=hold-must]'), p = document.querySelector('[data-testid=pc-mobilepay]'); return !!(st.compareDocumentPosition(m) & 4) && !!(m.compareDocumentPosition(p) & 4); }), `${lang}: maksuohje tilan jälkeen ja maksuosion yläpuolella`);
  expect(await has(page, 'button[data-testid=pc-paylater-btn]') && /test|testi/i.test(await text(page, '[data-testid=pc-paylater-btn]')), `${lang}: testivaihtoehto-nappi (pay_later) näkyy kun palvelin tarjoaa sen ja on merkitty testiksi`);
  const t1 = await secs(page); expect(t1 != null && t1 >= 895 && t1 <= 900, `${lang}: laskuri alkaa ~15:00 (${t1})`);
  expect((await page.getAttribute('[data-testid=hold-timer]', 'role')) === 'timer' && (await page.getAttribute('[data-testid=hold-timer]', 'aria-live')) === 'off', `${lang}: laskuri role=timer, aria-live=off (ei joka sekunti)`);
  expect((await page.getAttribute('[data-testid=hold-timer]', 'aria-labelledby')) !== null, `${lang}: laskurilla on nimi`);
  expect((await page.getAttribute('[data-testid=hold-announce]', 'role')) === 'status' && (await page.getAttribute('[data-testid=hold-announce]', 'aria-live')) === 'polite', `${lang}: erillinen ilmoitusalue (status/polite)`);
  expect(((await page.textContent('[data-testid=hold-announce]')) || '') === '', `${lang}: ilmoitusalue on alussa tyhjä (ei puheliasta)`);
  expect(await has(page, '[data-testid=pc-mobilepay]') && await has(page, '[data-testid=pc-gift-btn]'), `${lang}: maksuvalinta (MobilePay + lahjakortti) näkyy ennen vahvistusta`);
  expect(!/paikan päällä|on site/i.test(await text(page, '[data-testid=pc-lead]')), `${lang}: ei "maksu paikan päällä" -ohjetta pitotilassa`);
  expect(!(await has(page, 'a[download]')), `${lang}: ei kalenterilisäystä ennen vahvistusta`);
  expect((await text(page, '[data-testid=conf-status]')).length > 0 && !/vahvistettu|confirmed/i.test(await text(page, '[data-testid=conf-status]')), `${lang}: tilarivi ei väitä varausta vahvistetuksi`);
  const order = await page.evaluate(() => { const p = document.querySelector('[data-testid=hold-panel]'), s = document.querySelector('[data-testid=pc-mobilepay]'), d = document.querySelector('dl.bk-sum'); return p.compareDocumentPosition(d) & 4 && d.compareDocumentPosition(s) & 4; });
  expect(!!order, `${lang}: järjestys: tilabadge → pitopaneeli/laskuri → yhteenveto → maksuvalinta (yhteenveto ei enää maksuosion alla)`);
  { const sum = await text(page, '[data-testid=conf-summary]'); expect(/\d/.test(sum) && (await page.locator('dl.bk-sum').count()) === 1 && await has(page, '[data-testid=conf-remaining]'), `${lang}: tiivis yhteenveto (tilausnro, palvelu, aika, henkilömäärä, yhteensä, maksun tila, maksettavaa jäljellä) vain kerran`); }
  await page.waitForTimeout(2300); const t2 = await secs(page); expect(t2 != null && t1 - t2 >= 1 && t1 - t2 <= 4, `${lang}: laskuri etenee (${t1} → ${t2})`);
  expect(((await page.textContent('[data-testid=hold-announce]')) || '') === '', `${lang}: ei ilmoituksia ilman porrasylitystä`);
  await page.reload({ waitUntil: 'load' }); await waitHold(page, 'awaiting_payment'); const t3 = await secs(page); expect(t3 != null && t3 <= t2 && t2 - t3 <= 5, `${lang}: päivitys ei nollaa laskuria (${t2} → ${t3})`);
  await layout(page, view(page, 'confirm'), `hold confirm ${lang} 390`);
  await page.screenshot({ path: join(SHOT, `vahvistus-${lang}-390-odottaa.png`), fullPage: true });
  await page.ctx.close();
}

{
  const page = await newPage(390, 'fi', 'testui-off');
  await goto(page, conf('fi', 'hold', '&testui=0')); await waitHold(page, 'awaiting_payment');
  expect(!(await has(page, '[data-testid=pc-paylater]')) && !(await has(page, '[data-testid=pc-paylater-btn]')), 'tuotantotila (testui=0): palvelin ei tarjoa pay_later-tapaa → nappia ei näytetä pitotilassa');
  await page.ctx.close();
}

// ======================= 2) palvelinaika: palvelimen kello +1 h / laitteen kello +2 h → laskuri silti oikein =======================
{
  const page = await newPage(390, 'fi', 'skew-server');
  await goto(page, conf('fi', 'hold', '&serverskew=3600')); await waitHold(page, 'awaiting_payment');
  const a = await secs(page); expect(a != null && a >= 895 && a <= 900, `palvelimen kello +1 h: laskuri ~15:00 eikä laitteen kellosta johdettu (${a})`);
  await page.ctx.close();
  const p2 = await newPage(390, 'fi', 'skew-device', { deviceSkewMs: 2 * 3600 * 1000 });
  await goto(p2, conf('fi', 'hold')); await waitHold(p2, 'awaiting_payment');
  const b = await secs(p2); expect(b != null && b >= 895 && b <= 900, `laitteen kello +2 h: laskuri ~15:00 (${b})`);
  const devNow = await p2.evaluate(() => Date.now() - performance.timeOrigin - performance.now()); expect(devNow > 3600 * 1000, 'testin laitekello oli oikeasti väärässä');
  await p2.waitForTimeout(2100); const b2 = await secs(p2); expect(b2 != null && b - b2 >= 1 && b - b2 <= 4, `laskuri etenee monotonisella kellolla (${b} → ${b2})`);
  await p2.ctx.close();
}

// ======================= 3) vanheneminen: holdsec=6 → laskuri nollaan → vanhentunut-paneeli; EI lahjakorttilausetta ilman lahjakorttiosuutta =======================
for (const lang of ['fi', 'en']) {
  const page = await newPage(390, lang, `expire-${lang}`);
  await goto(page, conf(lang, 'hold', '&holdsec=6')); await waitHold(page, 'awaiting_payment');
  await waitHold(page, 'expired', 25000);
  expect((await text(page, '[data-testid=hold-msg]')) === X[lang].expired, `${lang}: vanhentunut-teksti kirjaimellisesti (Joonaksen teksti)`);
  expect(!(await has(page, '[data-testid=hold-gift-returned]')) && !/lahjakort|gift card/i.test(await text(page, '[data-testid=hold-panel]')), `${lang}: EI lahjakorttilausetta kun lahjakorttia ei käytetty`);
  expect(await page.evaluate(() => document.activeElement?.matches('[data-testid=hold-panel] h3')), `${lang}: tilan vaihtuessa fokus siirtyy tilaotsikkoon (ruudunlukija)`);
  expect(await has(page, '[data-testid=hold-new]') && (await text(page, '[data-testid=hold-new]')) === X[lang].newBooking, `${lang}: "aloita alusta" -linkki`);
  expect(!(await has(page, '[data-testid=pc-mobilepay]')) && !(await has(page, '[data-testid=pc-gift-btn]')), `${lang}: maksuvalinta poistuu vanhentuneelta`);
  expect(!(await has(page, '[data-testid=hold-timer]')), `${lang}: laskuri poistuu vanhentuneelta`);
  const href = await page.getAttribute('[data-testid=hold-new]', 'href'); expect(href.startsWith(PATH[lang].shop) && href.includes('mock=1'), `${lang}: uusi varaus -linkki vie kauppaan (säilyttää mock): ${href}`);
  await layout(page, view(page, 'confirm'), `expired confirm ${lang} 390`);
  await page.screenshot({ path: join(SHOT, `vahvistus-${lang}-390-vanhentunut.png`), fullPage: true });
  await page.click('[data-testid=hold-new]'); await page.waitForSelector('.bk-tabs, .bk-card, h2', { timeout: 8000 });
  expect(page.url().startsWith(ORIGIN + PATH[lang].shop), `${lang}: linkki avasi kaupan (${page.url()})`);
  await page.ctx.close();
}

// ======================= 4) lahjakorttiosuus + vanheneminen: lause VAIN silloin =======================
for (const lang of ['fi', 'en']) {
  const page = await newPage(390, lang, `partial-${lang}`);
  await goto(page, conf(lang, 'hold-partial', '&holdsec=6')); await waitHold(page, 'awaiting_payment');
  expect(await has(page, '[data-testid=pc-mobilepay]'), `${lang}: osamaksun jälkeen loppuosan maksutapa näkyy (MobilePay)`);
  expect(/20/.test(await text(page, '[data-testid=pc-due]')), `${lang}: jäljellä oleva summa näkyy (${await text(page, '[data-testid=pc-due]')})`);
  await waitHold(page, 'expired', 25000);
  expect((await text(page, '[data-testid=hold-msg]')) === X[lang].expired, `${lang}: vanhentunut-teksti (lahjakorttiosuus)`);
  expect(await has(page, '[data-testid=hold-gift-returned]') && (await text(page, '[data-testid=hold-gift-returned]')) === X[lang].gift, `${lang}: lahjakortin palautuslause näkyy kun osuus oli käytetty`);
  await page.screenshot({ path: join(SHOT, `vahvistus-${lang}-390-vanhentunut-lahjakortti.png`), fullPage: true });
  await page.ctx.close();
  for (const [sc, gift] of [['hold-expired', false], ['hold-expired-gift', true]]) {
    const p = await newPage(390, lang, `${sc}-${lang}`);
    await goto(p, conf(lang, sc)); await waitHold(p, 'expired');
    expect((await has(p, '[data-testid=hold-gift-returned]')) === gift, `${lang} ${sc}: lahjakorttilause ${gift ? 'näkyy' : 'ei näy'}`);
    expect((await text(p, '[data-testid=hold-msg]')) === X[lang].expired, `${lang} ${sc}: perusteksti`);
    await p.ctx.close();
    const o = await newPage(390, lang, `order-${sc}-${lang}`);
    await goto(o, ord(lang, sc)); await waitHold(o, 'expired');
    expect((await has(o, '[data-testid=hold-gift-returned]')) === gift, `tilaus ${lang} ${sc}: lahjakorttilause ${gift ? 'näkyy' : 'ei näy'}`);
    expect(!(await has(o, '[data-testid=pay-rest], [data-testid=mp-block], [data-testid=add-submit], [data-testid=cancel-submit]')), `tilaus ${lang} ${sc}: ei maksu-/lisäys-/peruutustoimintoja vanhentuneella`);
    await o.ctx.close();
  }
}

// ======================= 5) käsittely: ei laskuria, ei toista maksua, valmistuu → vahvistettu =======================
for (const lang of ['fi', 'en']) {
  const page = await newPage(390, lang, `proc-${lang}`);
  await goto(page, conf(lang, 'hold-processing', '&procsec=4')); await waitHold(page, 'processing_payment');
  expect(!(await has(page, '[data-testid=hold-timer]')), `${lang}: käsittelyn aikana ei vanhenemislaskuria (ajastin ei estä maksua)`);
  expect(!(await has(page, '[data-testid=pc-mobilepay]')) && !(await has(page, '[data-testid=pc-gift-btn]')), `${lang}: käsittelyn aikana ei toista maksua`);
  expect((await page.getAttribute('[data-testid=hold-msg]', 'role')) === 'status', `${lang}: käsittelyviesti role=status`);
  await page.screenshot({ path: join(SHOT, `vahvistus-${lang}-390-kasittely.png`), fullPage: true });
  await page.waitForFunction(() => !document.querySelector('[data-testid=hold-panel]'), null, { timeout: 25000 });
  expect(!(await has(page, '[data-testid=hold-panel]')) && /vahvistettu|confirmed/i.test(await text(page, '[data-testid=conf-status]')), `${lang}: käsittely valmistui → vahvistettu (ei jäänyt jumiin)`);
  await page.ctx.close();
  const o = await newPage(390, lang, `order-proc-${lang}`);
  await goto(o, ord(lang, 'hold-processing', '&procsec=4')); await waitHold(o, 'processing_payment');
  expect(!(await has(o, '[data-testid=hold-timer]')) && !(await has(o, '[data-testid=mp-block]')) && !(await has(o, '[data-testid=pay-rest]')), `tilaus ${lang}: käsittelyssä ei laskuria eikä maksua`);
  await o.waitForFunction(() => !document.querySelector('[data-testid=hold-panel]'), null, { timeout: 25000 });
  expect((await text(o, '.ord-badges')).length > 0 && !(await has(o, '[data-testid=hold-panel]')), `tilaus ${lang}: käsittely valmistui → paneeli poistui`);
  await o.ctx.close();
}

// ======================= 6) alustava (ryhmä), vahvistettu, vahvistettu maksamatta, peruttu: vahvistussivu + tilaussivu =======================
for (const lang of ['fi', 'en']) {
  let page = await newPage(390, lang, `prelim-${lang}`);
  await goto(page, conf(lang, 'hold-preliminary')); await waitHold(page, 'preliminary');
  expect(!(await has(page, '[data-testid=hold-timer]')) && !(await has(page, '[data-testid=pc-mobilepay]')) && !(await has(page, '[data-testid=pc-gift-btn]')), `${lang}: alustava: ei laskuria eikä maksua`);
  expect(/\d+[./]\d+[./]\d{4}/.test(await text(page, '[data-testid=hold-msg]')), `${lang}: alustava: viesti kertoo päivän (${await text(page, '[data-testid=hold-msg]')})`);
  await page.screenshot({ path: join(SHOT, `vahvistus-${lang}-390-alustava.png`), fullPage: true }); await page.ctx.close();
  page = await newPage(390, lang, `order-prelim-${lang}`);
  await goto(page, ord(lang, 'hold-preliminary')); await waitHold(page, 'preliminary');
  expect(!(await has(page, '[data-testid=mp-block]')) && !(await has(page, '[data-testid=pay-rest]')) && !(await has(page, '[data-testid=pc-gift]')), `tilaus ${lang}: alustava: ei maksutoimintoja`); await page.ctx.close();
  page = await newPage(390, lang, `confirmed-${lang}`);
  await goto(page, conf(lang, 'hold-confirmed')); await page.waitForSelector('[data-testid=conf-status]');
  expect(!(await has(page, '[data-testid=hold-panel]')) && !(await has(page, '[data-testid=pc-mobilepay]')) && /vahvistettu|confirmed/i.test(await text(page, '[data-testid=conf-status]')), `${lang}: vahvistettu: ei pitopaneelia, ei maksuvalintaa`); await page.ctx.close();
  page = await newPage(390, lang, `unpaid-${lang}`);
  await goto(page, conf(lang, 'hold-unpaid')); await page.waitForSelector('[data-testid=conf-status]');
  expect(!(await has(page, '[data-testid=hold-panel]')) && await has(page, '[data-testid=pc-mobilepay]') && /vahvistettu|confirmed/i.test(await text(page, '[data-testid=conf-status]')), `${lang}: vahvistettu maksamatta: maksuvalinta jää tarjolle, ei pitopaneelia`); await page.ctx.close();
  page = await newPage(390, lang, `cancelled-${lang}`);
  await goto(page, conf(lang, 'hold-cancelled')); await page.waitForSelector('[data-testid=conf-status]');
  expect(!(await has(page, '[data-testid=hold-panel]')) && !(await has(page, '[data-testid=pc-mobilepay]')) && /peruttu|cancel/i.test(await text(page, '[data-testid=conf-status]')), `${lang}: peruttu: ei maksua`); await page.ctx.close();
  for (const sc of ['hold-confirmed', 'hold-unpaid', 'hold-cancelled']) {
    const o = await newPage(390, lang, `order-${sc}-${lang}`);
    await goto(o, ord(lang, sc)); await o.waitForSelector('[data-testid=order-title]');
    expect(!(await has(o, '[data-testid=hold-panel]')), `tilaus ${lang} ${sc}: ei pitopaneelia`);
    if (sc === 'hold-cancelled') expect(!(await has(o, '[data-testid=add-submit]')) && !(await has(o, '[data-testid=cancel-submit]')), `tilaus ${lang}: peruttu: ei lisäystä/peruutusta`);
    await o.ctx.close();
  }
}

// ======================= 7) tilaussivu: odottaa maksua + laskuri + vanheneminen =======================
for (const lang of ['fi', 'en']) {
  const o = await newPage(390, lang, `order-hold-${lang}`);
  await goto(o, ord(lang, 'hold')); await waitHold(o, 'awaiting_payment');
  expect((await text(o, '[data-testid=hold-must]')) === X[lang].must && !(await has(o, '[data-testid=hold-lead]')) && (await secs(o)) > 890, `tilaus ${lang}: 15 min -ohje (ei toistoa) + laskuri`);
  expect(await has(o, '[data-testid=mp-block]') && await has(o, '[data-testid=ord-hold-choose]'), `tilaus ${lang}: maksuvalinta näkyy`);
  await layout(o, '#order-app', `hold order ${lang} 390`);
  await o.screenshot({ path: join(SHOT, `tilaus-${lang}-390-odottaa.png`), fullPage: true });
  await o.ctx.close();
  const e = await newPage(390, lang, `order-exp-${lang}`);
  await goto(e, ord(lang, 'hold', '&holdsec=6')); await waitHold(e, 'awaiting_payment'); await waitHold(e, 'expired', 25000);
  expect((await text(e, '[data-testid=hold-msg]')) === X[lang].expired && !(await has(e, '[data-testid=hold-gift-returned]')), `tilaus ${lang}: vanheni automaattisesti, ei lahjakorttilausetta`);
  await e.screenshot({ path: join(SHOT, `tilaus-${lang}-390-vanhentunut.png`), fullPage: true });
  await e.ctx.close();
}

// ======================= 8) MobilePay-maksu pitotilassa: paluu → käsittely → vahvistettu =======================
for (const lang of ['fi', 'en']) {
  const page = await newPage(390, lang, `mp-${lang}`);
  await goto(page, conf(lang, 'hold', '&mpinterval=300')); await waitHold(page, 'awaiting_payment');
  await page.click('[data-testid=mp-button]');
  await page.waitForFunction(() => /confirmed|vahvistettu/i.test(document.querySelector('[data-testid=conf-status]')?.textContent || ''), null, { timeout: 25000 });
  expect(!(await has(page, '[data-testid=hold-panel]')), `${lang}: MobilePay-maksun jälkeen vahvistettu, pitopaneeli pois`);
  expect(page.url().includes('mock=1') && page.url().includes('scenario=hold'), `${lang}: paluu säilyttää mock-parametrit (${page.url()})`);
  await page.ctx.close();
}

// ======================= 9) kassa (hoito): "Jatka maksamaan", ohjeteksti, virheet; vanha käytös ennallaan kun pitotila pois =======================
async function fillAndReview(page, lang) {
  const names = await page.$$eval('.bk-form input, .bk-form textarea', (els) => els.map((e) => `${e.name}|${e.id}|${e.type}`));
  const set = async (re, v) => { const n = names.find((x) => re.test(x)); if (n) { const [name, id] = n.split('|'); await page.fill(id ? `#${id}` : `[name="${name}"]`, v); } };
  await set(/^name\|/i, 'Testi Asiakas'); await set(/email/i, 'testi@example.com'); await set(/phone|tel/i, '+358401234567');
  await page.$$eval('.bk-form input[type=checkbox]', (els) => { const t = els.find((e) => /terms|ehdot/i.test(e.name + e.id)) || els[0]; if (t && !t.checked) t.click(); });
  await page.click('.bk-form button[type=submit]'); await settle(page);
}
async function toCheckout(page, lang, query) {   // tuotesivu → päivä → aika → hoito → kassa (hoitovarauksen kulku, mock)
  await goto(page, `${PATH[lang].shop}?mock=1${query}#/tuote/saunahoito-2`);
  await page.waitForSelector('button.bk-cell.free');
  await pickDay(page); await page.click('.bk-time-btn'); await settle(page);
  await page.click('label[for$="-hunajahoito"]'); await settle(page);
  await page.click('.bk-continue .btn'); await page.waitForSelector('.bk-checkout');
  expect(page.url().includes('mock=1') && (!query || page.url().includes(query.split('&').filter(Boolean)[0])), `kassa ${lang}: URL säilyttää mock-parametrit (${page.url()})`);
}
for (const lang of ['fi', 'en']) {
  for (const [sc, hold] of [['hold', true], ['pay', false]]) {
    const page = await newPage(390, lang, `checkout-${sc}-${lang}`);
    await toCheckout(page, lang, `&scenario=${sc}`); const ds = true;
    if (ds) {
      await fillAndReview(page, lang);
      await page.waitForSelector('[data-testid=review-submit]', { timeout: 8000 }).catch(() => {});
      expect(await has(page, '[data-testid=review-submit]'), `kassa ${lang} ${sc}: päästiin tarkistusvaiheeseen`);
      const btn = await text(page, '[data-testid=review-submit]');
      await page.waitForTimeout(400);
      const btn2 = await text(page, '[data-testid=review-submit]');
      expect(hold ? btn2 === X[lang].cont : btn2 !== X[lang].cont, `kassa ${lang} ${sc}: painike ${hold ? '"Jatka maksamaan"' : 'vanha (ei pitotilaa)'} (${btn2})`);
      const lead = await text(page, '[data-testid=review-lead]');
      expect(hold ? /15/.test(lead) && !/paikan päällä|on site/i.test(lead) : !/15 (minuuttia|minutes)/.test(lead), `kassa ${lang} ${sc}: tarkistusteksti (${lead})`);
      if (hold) {
        expect(await has(page, '[data-testid=checkout-methods]') || (await text(page, '[data-testid=review-hold-extra]')).length > 0, `kassa ${lang}: maksutavat mainitaan ennen vahvistusta`);
        await layout(page, '#booking-app', `checkout review ${lang} 390`);
        await page.screenshot({ path: join(SHOT, `kassa-${lang}-390-tarkistus.png`), fullPage: true });
        await page.click('[data-testid=review-submit]'); await waitHold(page, 'awaiting_payment', 15000);
        expect(page.url().includes('scenario=hold') && page.url().includes('mock=1'), `kassa ${lang}: ohjaus vahvistussivulle säilyttää mock-parametrit (${page.url()})`);
        const t = await secs(page); expect(t != null && t >= 890 && t <= 900, `kassa ${lang}: pito alkoi luonnista (${t})`);
      } else {
        await page.click('[data-testid=review-submit]'); await page.waitForSelector('[data-testid=conf-status]', { timeout: 15000 });
        expect(!(await has(page, '[data-testid=hold-panel]')), `kassa ${lang} pay: vanha käytös: vahvistussivulla ei pitopaneelia`);
      }
    } else expect(false, `kassa ${lang} ${sc}: ei vapaata päivää`);
    await page.ctx.close();
  }
  for (const [code, msg] of [['online_payment_unavailable', X[lang].unavailable], ['too_many_pending', X[lang].tooMany]]) {
    const page = await newPage(390, lang, `checkout-fail-${code}-${lang}`);
    await toCheckout(page, lang, `&scenario=hold&fail=${code}`);
    await fillAndReview(page, lang); await page.waitForSelector('[data-testid=review-submit]'); await page.waitForTimeout(300);
    await page.click('[data-testid=review-submit]'); await page.waitForSelector('#bk-rmsg .bk-error', { timeout: 8000 });
    expect((await text(page, '#bk-rmsg .bk-error')) === msg, `kassa ${lang}: virhe ${code}: selkeä viesti (${await text(page, '#bk-rmsg .bk-error')})`);
    expect(!(await page.$eval('[data-testid=review-submit]', (b) => b.disabled)), `kassa ${lang}: virheen jälkeen voi yrittää uudelleen`);
    await page.screenshot({ path: join(SHOT, `kassa-${lang}-390-virhe-${code}.png`), fullPage: true });
    await page.ctx.close();
  }
}

// ======================= 10) virhekoodit maksupainikkeesta (order_expired / order_preliminary / payment_in_progress): FI + EN + onFail =======================
for (const lang of ['fi', 'en']) {
  const page = await newPage(390, lang, `errors-${lang}`);
  await goto(page, conf(lang, 'hold')); await waitHold(page, 'awaiting_payment');
  const res = await page.evaluate(async ({ lang }) => {
    const { payBlock } = await import('/booking/mobilepay-ui.js');
    const out = {};
    for (const code of ['order_expired', 'order_preliminary', 'payment_in_progress', 'online_payment_unavailable']) {
      let failed = null;
      const node = payBlock({ S: {}, L: lang, api: { start: async () => ({ ok: false, code, message: 'x' }) }, opts: { method: { code: 'mobilepay' } }, env: { mock: true, official: false }, onFail: (c) => { failed = c; } });
      document.body.append(node); for (let i = 0; i < 40 && !node.querySelector('[data-testid=mp-button]'); i++) await new Promise((r) => setTimeout(r, 25)); node.querySelector('[data-testid=mp-button]').click(); await new Promise((r) => setTimeout(r, 80));
      out[code] = { text: node.querySelector('[data-testid=mp-error]')?.textContent, failed }; node.remove();
    }
    return out;
  }, { lang });
  expect(res.order_expired?.text === X[lang].expiredErr && res.order_expired.failed === 'order_expired', `${lang}: order_expired: viesti + onFail (${JSON.stringify(res.order_expired)})`);
  expect(res.order_preliminary?.text === X[lang].prelimErr, `${lang}: order_preliminary viesti (${res.order_preliminary?.text})`);
  expect(res.payment_in_progress?.text === X[lang].progressErr, `${lang}: payment_in_progress viesti (${res.payment_in_progress?.text})`);
  expect(res.online_payment_unavailable?.text === X[lang].unavailable, `${lang}: online_payment_unavailable viesti (${res.online_payment_unavailable?.text})`);
  await page.ctx.close();
}

// ======================= 11) vanha käytös ennallaan (scenario=pay, ei pitotilaa) =======================
for (const lang of ['fi', 'en']) {
  const page = await newPage(390, lang, `legacy-${lang}`);
  await goto(page, conf(lang, 'pay')); await page.waitForSelector('[data-testid=pc-mobilepay]');
  expect(!(await has(page, '[data-testid=hold-panel]')) && !(await has(page, '[data-testid=hold-timer]')) && !(await has(page, '[data-testid=pc-paylater]')), `${lang}: vanha tila: ei pitopaneelia eikä testivaihtoehtoa`);
  expect((await text(page, '[data-testid=conf-title]')) === X[lang].h2, `${lang}: vanha tila: maksamattoman otsikko "${X[lang].h2}"`);
  expect(await has(page, 'a[download]'), `${lang}: vanha tila: kalenterilisäys säilyy`);
  expect(/paikan päällä|on site|Maksettavaa|due/i.test(await text(page, '[data-testid=pc-lead]')) || (await text(page, '[data-testid=pc-lead]')).length > 0, `${lang}: vanha tila: vanha maksuohje (${await text(page, '[data-testid=pc-lead]')})`);
  await page.ctx.close();
  const o = await newPage(390, lang, `legacy-order-${lang}`);
  await goto(o, ord(lang, 'pay')); await o.waitForSelector('[data-testid=order-page]');
  expect(!(await has(o, '[data-testid=hold-panel]')) && await has(o, '[data-testid=mp-block]'), `tilaus ${lang}: vanha tila: ei pitopaneelia, MobilePay näkyy`);
  await o.ctx.close();
}

// ======================= 12) asettelu: kaikki tilat 360/390/430/1280 FI + EN (ei vaakavieritystä, ≥44 px, kontrasti, ei sinistä) + kuvat =======================
for (const lang of ['fi', 'en']) for (const w of WIDTHS) {
  for (const [sc, tag] of [['hold', 'odottaa'], ['hold-processing', 'kasittely'], ['hold-preliminary', 'alustava'], ['hold-expired', 'vanhentunut'], ['hold-expired-gift', 'vanhentunut-lahjakortti'], ['hold-unpaid', 'vahvistettu-maksamatta'], ['hold-confirmed', 'vahvistettu']]) {
    const page = await newPage(w, lang, `layout-${sc}-${lang}-${w}`);
    await goto(page, conf(lang, sc, sc === 'hold-processing' ? '&procsec=600' : '')); await page.waitForSelector('[data-testid=conf-status]'); await page.waitForTimeout(250);
    await layout(page, '#booking-app', `confirm ${sc} ${lang} ${w}`);
    if ([360, 1280].includes(w) || (w === 390 && !['hold', 'hold-expired'].includes(sc))) await page.screenshot({ path: join(SHOT, `vahvistus-${lang}-${w}-${tag}.png`), fullPage: true });
    await page.ctx.close();
  }
  for (const [sc, tag] of [['hold', 'odottaa'], ['hold-expired-gift', 'vanhentunut-lahjakortti'], ['hold-preliminary', 'alustava']]) {
    const page = await newPage(w, lang, `layout-order-${sc}-${lang}-${w}`);
    await goto(page, ord(lang, sc)); await page.waitForSelector('[data-testid=order-page]'); await page.waitForTimeout(250);
    await layout(page, '#order-app', `order ${sc} ${lang} ${w}`);
    if ([360, 1280].includes(w)) await page.screenshot({ path: join(SHOT, `tilaus-${lang}-${w}-${tag}.png`), fullPage: true });
    await page.ctx.close();
  }
}

await browser.close(); server.close();
if (problems.length) { console.error(`EPÄONNISTUI (${problems.length} ongelmaa, ${checks} tarkistusta):\n- ` + [...new Set(problems)].join('\n- ')); process.exit(1); }
console.log(`OK: ${checks} tarkistusta, kuvat: ${SHOT}`);
