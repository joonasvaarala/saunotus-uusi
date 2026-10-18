// E2E (Playwright + google-chrome), KOKEILUTILA (?mock=1): lahjakoodin lähdevalinta ("Mistä lahjakortti on ostettu?", §13.12) vieritetään näkyviin kun se avautuu.
//   SHOP_DIST=/tmp/shop-lk node booking/shop/build.mjs   (ensin)
//   PW_DIR=/workspace/pw SHOP_DIST=/tmp/shop-lk SHOT_DIR=/workspace/screenshots-lahjakoodi-vieritys SHOT_PREFIX=jalkeen node booking/scripts/e2e-lahjakoodi-vieritys.mjs
// Tarkistaa 360/390/430/1280 px, kassan vahvistussivu (?scenario=pay) ja tilaussivu (?scenario=gift): heti napin painalluksen jälkeen otsikko + lähdevalinnat + "Lähetä"-painike ovat ruudulla
// (ei sticky-yläpalkin alla), fokus otsikossa, scrollIntoView kutsutaan tasan kerran, ei vieritystä kirjoittaessa, reduced-motion → behavior 'auto', tunnistamaton koodi (claimsoff) → virheviesti näkyvissä.
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
const SHOP = resolve(process.env.SHOP_DIST || '/tmp/shop-lk'), SHOT = resolve(process.env.SHOT_DIR || '/workspace/screenshots-lahjakoodi-vieritys'), PFX = process.env.SHOT_PREFIX || 'jalkeen';
await mkdir(SHOT, { recursive: true });
const problems = []; let checks = 0;
const expect = (ok, msg) => { checks++; if (!ok) problems.push(msg); };
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.avif': 'image/avif', '.png': 'image/png', '.jpg': 'image/jpeg', '.woff2': 'font/woff2' };
const server = createServer(async (req, res) => {
  const p = decodeURIComponent(new URL(req.url, 'http://x').pathname); let f = join(SHOP, normalize(p));
  try { if ((await stat(f)).isDirectory()) f = join(f, 'index.html'); const b = await readFile(f); res.writeHead(200, { 'content-type': types[extname(f)] || 'application/octet-stream', 'cache-control': 'no-store' }); res.end(b); } catch { res.writeHead(404); res.end('Not found'); }
});
await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
const ORIGIN = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const TOKEN = '3f2b8c1e-5a7d-4e9f-8b6a-1c2d3e4f5a6b';
const VIEWS = {
  kassa: { fi: `/varaa/vahvistus/?mock=1&scenario=pay#${TOKEN}`, en: `/en/book/confirmation/?mock=1&scenario=pay#${TOKEN}` },
  tilaus: { fi: `/tilaus/?t=${TOKEN}&mock=1&scenario=gift`, en: `/en/order/?t=${TOKEN}&mock=1&scenario=gift` },
};
const OFF = { tilaus: (l) => VIEWS.tilaus[l].replace('scenario=gift', 'scenario=claimsoff') };
async function open(view, lang, width, { url, reduce = false } = {}) {
  const mobile = width < 600;
  const ctx = await browser.newContext({ viewport: { width, height: mobile ? 844 : 900 }, isMobile: mobile, hasTouch: mobile, locale: lang === 'en' ? 'en-GB' : 'fi-FI', timezoneId: 'Europe/Helsinki', reducedMotion: reduce ? 'reduce' : 'no-preference' });
  await ctx.route('https://cdn.vippsmobilepay.com/**', (r) => r.fulfill({ status: 200, contentType: 'text/javascript', body: '' }));
  // laskuri: kaikki scrollIntoView-kutsut asetuksineen
  await ctx.addInitScript(() => { window.__sc = []; const o = Element.prototype.scrollIntoView; Element.prototype.scrollIntoView = function (a) { window.__sc.push({ cls: this.className || this.tagName, tid: this.getAttribute('data-testid'), arg: a === undefined ? null : JSON.parse(JSON.stringify(a)) }); return o.call(this, a); }; });
  const page = await ctx.newPage(); page.ctx = ctx;
  const name = `${view}/${lang}/${width}`;
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type())) problems.push(`${name} console.${m.type()}: ${m.text()}`); });
  page.on('pageerror', (e) => problems.push(`${name} pageerror: ${e.message}`));
  page.on('request', (r) => { if (!r.url().startsWith(ORIGIN) && !r.url().startsWith('data:') && !r.url().startsWith('https://cdn.vippsmobilepay.com/')) problems.push(`${name} ulkoinen pyyntö: ${r.url()}`); });
  await page.goto(ORIGIN + (url || VIEWS[view][lang]));
  if (view === 'kassa') { await page.waitForSelector('[data-testid=pc-gift-btn]'); await page.click('[data-testid=pc-gift-btn]'); } else await page.waitForSelector('[data-testid=gc-code]');
  return page;
}
const settled = async (page) => { let last = -1; for (let i = 0; i < 40; i++) { const y = await page.evaluate(() => Math.round(scrollY)); if (y === last) return y; last = y; await page.waitForTimeout(120); } return last; };
const geom = (page) => page.evaluate(() => {
  const r = (s) => document.querySelector(s)?.getBoundingClientRect(), hd = document.querySelector('.site-header'), hb = hd ? hd.getBoundingClientRect().bottom : 0;
  const c = r('[data-testid=vc-choose]'), t = r('.vc-ctitle'), rad = r('.vc-choose input[type=radio]') || r('.vc-opt'), sub = r('[data-testid=vc-submit]');
  return { vh: innerHeight, hb: Math.round(hb), chooseTop: c && Math.round(c.top), titleTop: t && Math.round(t.top), titleBottom: t && Math.round(t.bottom), radioBottom: rad && Math.round(rad.bottom), subBottom: sub && Math.round(sub.bottom), chooseH: c && Math.round(c.height), active: document.activeElement?.className, scrollY: Math.round(scrollY), sc: window.__sc.slice() };
});
for (const view of ['kassa', 'tilaus']) for (const lang of ['fi', 'en']) for (const width of [360, 390, 430, 1280]) {
  const name = `${view}/${lang}/${width}`, page = await open(view, lang, width);
  await page.fill('[data-testid=gc-code]', 'XQZ123456789');
  const y0 = await page.evaluate(() => scrollY);
  await page.click('[data-testid=gc-apply]');
  await page.waitForSelector('[data-testid=vc-choose]:not([hidden])');
  await settled(page);
  const g = await geom(page), sc = g.sc.filter((s) => s.tid === 'vc-choose');
  expect(sc.length === 1 && g.sc.length === 1, `${name}: scrollIntoView tasan kerran (kutsut: ${JSON.stringify(g.sc)})`);
  expect(sc[0]?.arg?.block === 'start' && sc[0]?.arg?.behavior === 'smooth', `${name}: block start + smooth (${JSON.stringify(sc[0]?.arg)})`);
  expect(g.titleTop >= g.hb - 1 && g.titleBottom <= g.vh, `${name}: otsikko ruudulla yläpalkin alla (otsikko ${g.titleTop}–${g.titleBottom}, palkki ${g.hb}, ruutu ${g.vh})`);
  expect(g.radioBottom <= g.vh, `${name}: ensimmäinen valinta ruudulla (${g.radioBottom} ≤ ${g.vh})`);
  const fits = g.chooseH <= g.vh - g.hb - 20;
  if (fits) expect(g.subBottom <= g.vh, `${name}: koko lomake mahtuu ruudulle, "Lähetä"-painike näkyy (${g.subBottom} ≤ ${g.vh})`);
  expect(/vc-ctitle/.test(g.active || ''), `${name}: fokus lomakkeen otsikossa (${g.active})`);
  expect(g.scrollY > y0 || y0 > 0 && g.scrollY >= 0, `${name}: sivu vieritti`);
  const label = await page.evaluate(() => { const c = document.querySelector('[data-testid=vc-choose]'); return document.getElementById(c.getAttribute('aria-labelledby'))?.textContent; });
  expect(!!label && label === await page.locator('.vc-ctitle').textContent(), `${name}: lomake nimetty otsikolla (aria-labelledby)`);
  await page.screenshot({ path: `${SHOT}/${PFX}-${view}-${lang === 'en' ? 'en-' : ''}${width}.png` });
  // kirjoittaminen lomakkeen auki ollessa: ei vieritystä (lomake sulkeutuu, kun koodia muokataan) – scrollIntoView-kutsujen määrä ei kasva
  await page.fill('[data-testid=gc-code]', 'XQZ1234567890');
  const g2 = await geom(page); expect(g2.sc.length === 1, `${name}: kirjoittaminen ei vieritä (kutsuja ${g2.sc.length})`);
  // uusi painallus → lomake ilmestyy uudelleen → uusi vieritys (yksi lisää)
  await page.click('[data-testid=gc-apply]'); await page.waitForSelector('[data-testid=vc-choose]:not([hidden])'); await settled(page);
  const g3 = await geom(page); expect(g3.sc.length === 2 && g3.titleTop >= g3.hb - 1 && g3.titleBottom <= g3.vh, `${name}: uusi tulos vieritetään näkyviin kerran (kutsuja ${g3.sc.length}, otsikko ${g3.titleTop})`);
  await page.ctx.close();
}
// reduced-motion: behavior 'auto'
for (const view of ['kassa', 'tilaus']) {
  const page = await open(view, 'fi', 390, { reduce: true });
  await page.fill('[data-testid=gc-code]', 'XQZ123456789'); await page.click('[data-testid=gc-apply]'); await page.waitForSelector('[data-testid=vc-choose]:not([hidden])'); await settled(page);
  const g = await geom(page); const a = g.sc.find((s) => s.tid === 'vc-choose')?.arg;
  expect(g.sc.length === 1 && a?.behavior === 'auto' && a?.block === 'start', `reduced-motion/${view}: behavior auto (${JSON.stringify(g.sc)})`);
  expect(g.titleTop >= g.hb - 1 && g.titleBottom <= g.vh, `reduced-motion/${view}: otsikko ruudulla`);
  await page.ctx.close();
}
// omaa korttia (applied) ja virheellistä koodia ei vieritetä lähdevalintaan; liian lyhyt koodi → kenttävirhe, ei lähdevalintaa
{
  const page = await open('tilaus', 'fi', 390);
  await page.fill('[data-testid=gc-code]', 'AB'); await page.click('[data-testid=gc-apply]'); await page.waitForTimeout(300);
  const g = await geom(page); expect(!g.sc.some((s) => s.tid === 'vc-choose') && await page.locator('[data-testid=vc-choose]:not([hidden])').count() === 0, 'virheellinen koodi: ei lähdevalintaa eikä sen vieritystä');
  await page.ctx.close();
}
// tunnistamaton koodi, kun kumppanilunastus ei ole käytössä (claimsoff → not_found): virheviesti nappien alla näkyy ruudulla
for (const view of ['kassa', 'tilaus']) for (const width of [360, 390, 430, 1280]) {
  const name = `virhe/${view}/${width}`;
  const page = await open(view, 'fi', width, { url: view === 'tilaus' ? OFF.tilaus('fi') : undefined });
  // kassan mockissa kumppanilunastus on päällä → virhe tulee Johku-kortista (JK…, ei enää lunastettavissa)
  await page.fill('[data-testid=gc-code]', view === 'kassa' ? 'JK1234567890' : 'XQZ123456789');
  await page.click('[data-testid=gc-apply]');
  await page.waitForSelector('[data-testid=gc-msg] [role=alert]'); await settled(page);
  const v = await page.evaluate(() => { const m = document.querySelector('[data-testid=gc-msg]').getBoundingClientRect(), hd = document.querySelector('.site-header')?.getBoundingClientRect().bottom || 0; return { top: Math.round(m.top), bottom: Math.round(m.bottom), vh: innerHeight, hb: Math.round(hd), text: document.querySelector('[data-testid=gc-msg]').textContent.slice(0, 60) }; });
  expect(v.top >= v.hb - 1 && v.bottom <= v.vh, `${name}: virheviesti ruudulla (${JSON.stringify(v)})`);
  await page.screenshot({ path: `${SHOT}/${PFX}-virhe-${view}-${width}.png` });
  await page.ctx.close();
}
// kassan 15 min paikanpito (scenario=hold): sama kysely pitotilan vahvistussivulla
for (const width of [360, 390]) {
  const name = `hold/${width}`, page = await open('kassa', 'fi', width, { url: `/varaa/vahvistus/?mock=1&scenario=hold#${TOKEN}` });
  await page.fill('[data-testid=gc-code]', 'XQZ123456789'); await page.click('[data-testid=gc-apply]'); await page.waitForSelector('[data-testid=vc-choose]:not([hidden])'); await settled(page);
  const g = await geom(page); expect(g.sc.length === 1 && g.titleTop >= g.hb - 1 && g.titleBottom <= g.vh && g.radioBottom <= g.vh && /vc-ctitle/.test(g.active || ''), `${name}: lomake ruudulla, kerran vieritetty, fokus otsikossa (${JSON.stringify({ ...g, sc: g.sc.length })})`);
  await page.screenshot({ path: `${SHOT}/${PFX}-kassa-pito-${width}.png` });
  await page.ctx.close();
}
await browser.close(); server.close();
console.log(`lahjakoodi-vieritys e2e: ${checks} tarkistusta, ${problems.length} ongelmaa`);
if (problems.length) { console.log(problems.join('\n')); process.exit(1); }
