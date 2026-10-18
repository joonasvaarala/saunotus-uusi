// E2E (Playwright + google-chrome): hallinnan "Vapaat ajat" -paneeli KOKEILUTILASSA (/admin/?mock=1; RPC:t admin/options-mock.js:stä, EI yhteyttä palvelimeen).
//   PW_DIR=/workspace/node_modules SHOT_DIR=/workspace/screenshots-admin-vapaat-ajat node booking/scripts/e2e-admin-vapaat-ajat.mjs
// Tarkistaa: tuote kb 7 (Saunarituaali ja savusaunavuoro, 120 min) näyttää paneelin ilman kovakoodattua id-listaa (config.public_slots), haku (p_product_id 7, henkilömäärä),
// päivät vain la/su, alkuajat 16:00/16:30/17:00, valinta täyttää lomakkeen, pituus 2 h ja pakettiaikajana, varaus (admin_create_resource_booking), kb 10 ennallaan (ei aikajanaa);
// asettelu 360/390/1280 (ei vaakavieritystä, kosketuskohteet >= 44 px), ei pyyntöjä backendille.
import { createServer } from 'node:http';
import { readFile, stat, mkdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { dirname, join, extname, resolve, normalize } from 'node:path';
const here = dirname(fileURLToPath(import.meta.url)), ROOT = resolve(here, '../..');
const require = createRequire(import.meta.url);
const pwPath = require.resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', here].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath));
const chromium = pw.chromium || pw.default.chromium;
const SHOT = resolve(process.env.SHOT_DIR || '/workspace/screenshots-admin-vapaat-ajat');
await mkdir(SHOT, { recursive: true });
const problems = []; let checks = 0;
const expect = (ok, msg) => { checks++; if (!ok) problems.push(msg); };
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png' };
let ORIGIN = '';
const server = createServer(async (req, res) => {
  const p = decodeURIComponent(new URL(req.url, 'http://x').pathname); let file;
  if (p === '/admin/config.js') { res.writeHead(200, { 'content-type': 'text/javascript' }); return res.end(`window.BOOKING_CONFIG=${JSON.stringify({ url: ORIGIN, anonKey: 'anon-test' })};`); }
  if (p === '/admin/sb.js') file = join(ROOT, 'booking/shared/sb.js');
  else if (p.startsWith('/admin/')) file = join(ROOT, 'booking/admin', normalize(p.slice(7) || 'index.html'));
  else { res.writeHead(404); return res.end('Not found'); }
  try { if ((await stat(file)).isDirectory()) file = join(file, 'index.html'); const buf = await readFile(file); res.writeHead(200, { 'content-type': types[extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' }); res.end(buf); }
  catch { res.writeHead(404, { 'content-type': 'text/plain' }); res.end('Not found'); }
});
await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
ORIGIN = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const TZ = 'Europe/Helsinki';
const WIDTHS = [360, 390, 1280];

async function newPage(width, lang = 'fi', name = 'p') {
  const mobile = width < 600;
  const ctx = await browser.newContext({ viewport: { width, height: mobile ? 844 : 900 }, isMobile: mobile, hasTouch: mobile, locale: lang === 'en' ? 'en-GB' : 'fi-FI', timezoneId: TZ });
  const page = await ctx.newPage(); page.ctx = ctx;
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type())) problems.push(`${name} console.${m.type()}: ${m.text()} ${m.location().url || ''}`); });
  page.on('pageerror', (e) => problems.push(`${name} pageerror: ${e.message}`));
  page.on('requestfailed', (r) => { if (!/ERR_ABORTED/.test(r.failure()?.errorText || '')) problems.push(`${name} requestfailed: ${r.url()}`); });
  page.on('response', (r) => { if (r.status() >= 400) problems.push(`${name} HTTP ${r.status()}: ${r.url()}`); });
  page.on('request', (r) => { if (!r.url().startsWith(ORIGIN) && !r.url().startsWith('data:')) problems.push(`${name} ulkoinen pyyntö: ${r.url()}`); if (/\/rest\/v1\/|\/functions\/v1\/|\/auth\/v1\//.test(r.url())) problems.push(`${name} PYYNTÖ BACKENDILLE: ${r.url()}`); });
  return page;
}
const settle = (page) => page.waitForTimeout(200);
const goto = async (page, url) => { await page.goto(ORIGIN + url, { waitUntil: 'load' }); };
const calls = (page, name) => page.evaluate((n) => window.__adminMock.state.calls.filter((c) => c.name === n).map((c) => c.args), name);
const layout = (page, label) => page.evaluate((label) => {
  const out = []; const doc = document.documentElement;
  if (doc.scrollWidth > window.innerWidth + 1) out.push(`${label}: vaakavieritys (${doc.scrollWidth} > ${window.innerWidth})`);
  for (const el of document.querySelectorAll('[data-testid=availability] button')) { const r = el.getBoundingClientRect(); if (r.height && r.height < 43.5) out.push(`${label}: painike ${Math.round(r.width)}x${Math.round(r.height)} "${el.textContent.trim().slice(0, 20)}"`); if (r.right > window.innerWidth + 1) out.push(`${label}: painike ulkona`); }
  const t = document.querySelector('[data-testid=slot-timeline]:not([hidden])'); if (t && t.scrollWidth > t.clientWidth + 1) out.push(`${label}: aikajana leikkautuu`);
  return out;
}, label).then((o) => o.forEach((m) => expect(false, m)));
const slotTexts = (page) => page.$$eval('[data-testid=slot] strong', (els) => els.map((e) => e.textContent));
const availCalls = (page) => calls(page, 'admin_treatment_availability');
const mutedText = (page) => page.locator('form small.muted').allInnerTexts().then((a) => a.join('|'));
const norm = (s) => s.replace(/\u00a0/g, ' ');
const shot = async (page, file) => { await page.locator('[data-testid=availability]').scrollIntoViewIfNeeded(); await page.screenshot({ path: join(SHOT, file), fullPage: false }); };

for (const w of WIDTHS) {
  const page = await newPage(w, 'fi', `vapaat-${w}`);
  await goto(page, '/admin/?mock=1#/uusi?tyyppi=resurssi');
  const form = page.locator('[data-testid=resource-booking-form]'); await form.waitFor();
  const opts = await form.locator('[name=product] option').allTextContents();
  expect(opts.some((o) => /Saunarituaali ja savusaunavuoro \(la & su\) \(120 min\)/.test(o)), `${w}: kb 7 puuttuu tuotevalinnasta (${opts})`);
  expect(!opts.some((o) => /Yleinen saunavuoro/.test(o)), `${w}: vuorotuote ei kuulu resurssilomakkeelle`);

  // --- kb 7 ---
  await form.locator('[name=product]').selectOption('7');
  await page.waitForSelector('[data-testid=availability]:not([hidden]) [data-testid=slot]:has-text("17:00")');
  const last = (await availCalls(page)).at(-1);
  expect(last.p_product_id === 7 && last.p_persons === 1 && last.p_override === false && /^\d{4}-\d\d-\d\d$/.test(last.p_from), `${w}: haun argumentit ${JSON.stringify(last)}`);
  const chips = await page.$$eval('[data-testid=day-chip]', (els) => els.map((e) => e.dataset.day));
  expect(chips.length >= 2 && chips.every((d) => [0, 6].includes(new Date(`${d}T12:00:00Z`).getUTCDay())), `${w}: päivät vain la/su (${chips})`);
  expect((await slotTexts(page)).join() === '16:00,16:30,17:00', `${w}: alkuajat (${await slotTexts(page)})`);
  expect(/Oletuskesto 120 min/.test(await mutedText(page)), `${w}: oletuskesto 120 min`);
  expect(!(await page.isVisible('[data-testid=slot-picked]')) && !(await page.isVisible('[data-testid=slot-timeline]')), `${w}: ei valintaa ennen klikkausta`);
  await page.locator('[data-testid=slot]:has-text("16:30")').click();
  const picked = norm(await page.locator('[data-testid=slot-picked]').innerText()); const tl = await page.locator('[data-testid=slot-timeline]').innerText();
  expect(/klo 16:30–18:30 \(2 h\) · 1 hlö · 49,00/.test(picked), `${w}: valinnan yhteenveto (${picked})`);
  expect(/Aikajana: Rituaali 16:30–16:50 · Tauko 16:50–17:00 · Savusauna 17:00–18:30/.test(tl), `${w}: aikajana (${tl})`);
  expect((await form.locator('[name=time]').inputValue()) === '16:30', `${w}: aika täyttyi lomakkeelle`);
  expect(/päättyy 18:30/.test(await mutedText(page)), `${w}: päättymisvihje 18:30`);
  await layout(page, `kb7 ${w}`);
  await shot(page, `admin-vapaat-ajat-kb7-${w}-valittu.png`);

  // henkilömäärä 3 -> uusi haku, hinta 147 €
  await page.locator('input[name=n]').fill('3'); await page.locator('input[name=n]').dispatchEvent('input');
  await page.waitForFunction(() => window.__adminMock.state.calls.filter((c) => c.name === 'admin_treatment_availability').some((c) => c.args.p_persons === 3), null, { timeout: 5000 });
  await page.waitForSelector('[data-testid=slot]'); await settle(page);
  await page.locator('[data-testid=slot]:has-text("17:00")').click();
  const picked3 = norm(await page.locator('[data-testid=slot-picked]').innerText());
  expect(/klo 17:00–19:00 \(2 h\) · 3 hlö · 147,00/.test(picked3), `${w}: 3 hlö yhteenveto (${picked3})`);
  expect(/Savusauna 17:30–19:00/.test(await page.locator('[data-testid=slot-timeline]').innerText()), `${w}: aikajana 17:00-alkuiselle`);
  await layout(page, `kb7 3hlö ${w}`);
  if (w === 1280) await shot(page, `admin-vapaat-ajat-kb7-${w}-3hlo.png`);

  // luo varaus
  await form.locator('[name=cname]').fill('Testi Pakettiasiakas'); await form.locator('[name=cemail]').fill('paketti@example.com');
  await form.locator('button[type=submit]').click();
  await page.waitForFunction(() => window.__adminMock.state.calls.some((c) => c.name === 'admin_create_resource_booking'), null, { timeout: 5000 });
  const cr = (await calls(page, 'admin_create_resource_booking')).at(-1);
  expect(cr.p_product_id === 7 && cr.p_persons === 3 && /T1[45]:00:00/.test(cr.p_start) && cr.p_end == null, `${w}: varauksen argumentit ${JSON.stringify(cr)}`);
  await page.waitForSelector('#view .ok-box'); await settle(page);
  expect(/Varaus luotu/.test(await page.locator('#view .ok-box').innerText()), `${w}: varaus luotu -ruutu`);

  // --- kb 10 ennallaan: ei aikajanaa, 90 min ---
  await goto(page, '/admin/?mock=1#/uusi?tyyppi=resurssi'); await form.waitFor();
  await form.locator('[name=product]').selectOption('10');
  await page.waitForSelector('[data-testid=availability]:not([hidden]) [data-testid=slot]:has-text("17:30")');
  expect((await availCalls(page)).at(-1).p_product_id === 10, `${w}: kb 10 haku`);
  await page.locator('[data-testid=slot]').first().click();
  const p10 = norm(await page.locator('[data-testid=slot-picked]').innerText());
  expect(/\(1 h 30 min\)/.test(p10) && !(await page.isVisible('[data-testid=slot-timeline]')), `${w}: kb 10: pituus 1 h 30 min eikä aikajanaa (${p10})`);
  if (w === 1280) await shot(page, `admin-vapaat-ajat-kb10-${w}-ei-aikajanaa.png`);
  // vaihto kb 7:ään: aikajana ei jää näkyviin ennen uutta valintaa
  await form.locator('[name=product]').selectOption('7'); await page.waitForSelector('[data-testid=slot]:has-text("16:30")'); await settle(page);
  expect(!(await page.isVisible('[data-testid=slot-timeline]')) && !(await page.isVisible('[data-testid=slot-picked]')), `${w}: aikajana piilossa kunnes uusi aika valitaan`);
  await page.ctx.close();
}

await browser.close(); server.close();
console.log(`${checks} tarkistusta`);
if (problems.length) { console.error(`\nEPÄONNISTUI (${problems.length}):\n- ${[...new Set(problems)].join('\n- ')}`); process.exit(1); }
console.log('OK: hallinnan Vapaat ajat -paneeli (kb 7 + muut) toimii; kuvat: ' + SHOT);
