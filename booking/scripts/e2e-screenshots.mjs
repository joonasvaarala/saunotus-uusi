// E2E-savutesti + kuvakaappaukset Chromiumilla (Playwright). Vaatii käynnissä olevan demon (booking/README.md → "Paikallinen demo").
// Käyttö:  PW_DIR=/polku/jossa/node_modules/playwright-core  node booking/scripts/e2e-screenshots.mjs
// Ympäristö: BASE_URL (oletus http://localhost:4180), CHROME (oletus system google-chrome), OUT (oletus booking/docs/screenshots)
// Epäonnistuu (exit 1), jos selaimen konsolissa on virheitä tai sivun pyyntö epäonnistuu.
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { mkdirSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';

const require = createRequire(import.meta.url);
const pwPath = require.resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', dirname(fileURLToPath(import.meta.url))].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath));
const chromium = pw.chromium || pw.default.chromium;
const BASE = process.env.BASE_URL || 'http://localhost:4180';
const OUT = resolve(process.env.OUT || join(dirname(fileURLToPath(import.meta.url)), '../docs/screenshots'));
mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const problems = [];
const watch = (page, name) => {
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type())) problems.push(`${name} console.${m.type()}: ${m.text()}`); });
  page.on('pageerror', (e) => problems.push(`${name} pageerror: ${e.message}`));
  page.on('requestfailed', (r) => problems.push(`${name} requestfailed: ${r.url()} ${r.failure()?.errorText}`));
  page.on('response', (r) => { if (r.status() >= 400) problems.push(`${name} HTTP ${r.status()}: ${r.url()}`); });
};
const shot = (page, file, full = true) => page.screenshot({ path: join(OUT, file), fullPage: full });

// ---------- KAUPPA ----------
if (process.env.ONLY !== 'admin') for (const [name, vp] of [['mobile', { width: 390, height: 844, deviceScaleFactor: 1, isMobile: true, hasTouch: true }], ['desktop', { width: 1280, height: 900 }]]) {
  const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, deviceScaleFactor: vp.deviceScaleFactor || 1, isMobile: vp.isMobile, hasTouch: vp.hasTouch, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const page = await ctx.newPage(); watch(page, `shop-${name}`);
  await page.goto(`${BASE}/varaa/`);
  await page.waitForSelector('.bk-cards');
  await shot(page, `shop-${name}-1-tuotteet.png`);
  // yleinen vuoro → kalenteri
  await page.goto(`${BASE}/varaa/#/tuote/yleinensauna`);
  await page.waitForSelector('.bk-grid button.bk-cell');
  const day = page.locator('.bk-grid button.bk-cell.free').first();
  await day.click();
  await page.waitForSelector('.bk-slotlist');
  await shot(page, `shop-${name}-2-kalenteri-vuorot.png`);
  // yksityisvuoron vaikutus: tuote 25 (Oma savusaunavuoro)
  await page.goto(`${BASE}/varaa/#/tuote/oma-saunavuoro`);
  await page.waitForSelector('.bk-grid button.bk-cell');
  await shot(page, `shop-${name}-3-yksityisvuoro-kalenteri.png`);
  // varaus loppuun
  await page.goto(`${BASE}/varaa/#/tuote/yleinensauna`);
  await page.waitForSelector('.bk-grid button.bk-cell.free');
  await page.locator('.bk-grid button.bk-cell.free').last().click();
  await page.locator('.bk-slot.available a.btn').first().click();
  await page.waitForSelector('.bk-form');
  await page.fill('#name', `Playwright Testaaja ${name}`);
  await page.fill('#email', `pw-${name}-${Date.now()}@example.com`);
  await page.fill('#phone', '0401234567');
  await shot(page, `shop-${name}-4-tiedot.png`);
  await page.check('#bk-terms');
  await page.click('button[type=submit]');
  await page.waitForURL(/vahvistus/);
  await page.waitForSelector('.bk-conf dl');
  await shot(page, `shop-${name}-5-vahvistus.png`);
  await ctx.close();
}

// ---------- HALLINTA ----------
if (process.env.ONLY !== 'shop') for (const [name, vp] of [['mobile', { width: 390, height: 844, deviceScaleFactor: 1, isMobile: true, hasTouch: true }], ['desktop', { width: 1280, height: 900 }]]) {
  const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, deviceScaleFactor: vp.deviceScaleFactor || 1, isMobile: vp.isMobile, hasTouch: vp.hasTouch, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const page = await ctx.newPage(); watch(page, `admin-${name}`);
  await page.goto(`${BASE}/admin/`);
  await page.waitForSelector('form#login');
  await shot(page, `admin-${name}-0-kirjautuminen.png`, false);
  await page.fill('#email', 'admin@demo.local'); await page.fill('#password', 'demo');
  await page.click('form#login button[type=submit]');
  await page.waitForSelector('#view .day-view, #view .daygrid');
  // päivänäkymä päivälle, jolla on demovarauksia (seuraava maanantai)
  const mon = (() => { const d = new Date(); d.setUTCDate(d.getUTCDate() + ((8 - d.getUTCDay()) % 7 || 7)); return d.toISOString().slice(0, 10); })();
  await page.evaluate((m) => { location.hash = `#/?d=${m}`; }, mon);
  await page.waitForSelector('.session .reslist');
  await page.waitForTimeout(300);
  await shot(page, `admin-${name}-1-paivanakyma.png`, false);
  if (name === 'desktop') {
    await page.locator('.session .reslist button.link').first().click();
    await page.waitForSelector('dialog[open]');
    await shot(page, 'admin-desktop-1b-varaus-dialogi.png', false);
    await page.keyboard.press('Escape');
    // manuaalinen varaus loppuun asti
    const tue = (() => { const d = new Date(mon); d.setUTCDate(d.getUTCDate() + 8); return d.toISOString().slice(0, 10); })();
    await page.evaluate((m) => { location.hash = `#/uusi?d=${m}`; }, tue);
    await page.waitForSelector('.slotbtn:not([disabled])');
    await page.locator('.slotbtn:not([disabled])').nth(2).click();
    await page.fill('input[name=cname]', 'Puhelin Testi'); await page.fill('input[name=cemail]', `puhelin-${Date.now()}@example.com`); await page.fill('input[name=cphone]', '0401112222');
    await page.check('input[name=paid]');
    await shot(page, 'admin-desktop-7b-uusi-varaus-lomake.png');
    await page.click('#view form button[type=submit]');
    await page.waitForSelector('.ok-box');
    await shot(page, 'admin-desktop-7c-varaus-luotu.png', false);
  }
  for (const [hash, file] of [['varaukset', '2-varauslista'], ['asiakkaat', '3-asiakkaat'], ['tuotteet', '4-tuotteet'], ['resurssit', '5-resurssit'], ['asetukset', '6-asetukset'], ['uusi', '7-uusi-varaus']]) {
    await page.evaluate((h) => { location.hash = `#/${h}`; }, hash);
    await page.waitForTimeout(600);
    await shot(page, `admin-${name}-${file}.png`, false);
  }
  await ctx.close();
}
await browser.close();
if (problems.length) { console.error('ONGELMIA:\n' + [...new Set(problems)].join('\n')); process.exit(1); }
console.log(`ok: kuvakaappaukset → ${OUT}; ei konsolivirheitä`);
