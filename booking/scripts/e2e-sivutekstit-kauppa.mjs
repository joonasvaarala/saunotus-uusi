// E2E (Playwright + google-chrome): kaupan tekstit TIETOKANNASTA (sopimus §18, osa 3 PR 1) – KOKEILUTILASSA (?mock=1): EI yhteyttä palvelimeen eikä tuotantoon.
//   node booking/scripts/e2e-sivutekstit-kauppa.mjs     (rakentaa itse fixture-dist:n: SITE_TEXTS_FIXTURE = tuotannon tekstit + tuontitiedosto, muutama teksti merkitty "(DB)")
//   PW_DIR=/workspace/pw/node_modules SHOT_DIR=/workspace/screenshots-sivutekstit-kauppa node booking/scripts/e2e-sivutekstit-kauppa.mjs
// Tarkistaa FI/EN × 390/1280:
//  A) tietokannan teksti näkyy: build-aikaiset otsikot (page.book.title, page.order.title, <title> seo.book.title), kaupan ajoaikaiset tekstit (ui.shop.lead + {{var:phone}} sivuston puhelimesta,
//     funktiolehti ui.shop.times_free.one/other monikkomallina {{var:n}} päivänäkymässä), tilaussivun teksti (ui.order.lines_title, mock)
//  B) puuttuvat avaimet: site-texts.json ilman rivejä / virheellinen JSON / vain FI-rivit → repon oletusteksti samalla kielellä (en-sivulle ei fi-tekstiä), ei tyhjää, ei raakaa {{…}}/{n}
//  C) ei konsolivirheitä, ei pyyntöjä backendille, ei vaakavieritystä. Kuvat: SHOT_DIR.
import { createServer } from 'node:http';
import { readFile, mkdir, stat, writeFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { dirname, join, extname, resolve, normalize } from 'node:path';
import { spawnSync } from 'node:child_process';
const here = dirname(fileURLToPath(import.meta.url)), root = resolve(here, '../..');
const require = createRequire(import.meta.url);
const pwPath = require.resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', here].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath));
const chromium = pw.chromium || pw.default.chromium;
const SHOT = resolve(process.env.SHOT_DIR || '/workspace/screenshots-sivutekstit-kauppa'), WORK = resolve(process.env.WORK_DIR || '/tmp/e2e-sivutekstit-kauppa');
await mkdir(SHOT, { recursive: true }); await mkdir(WORK, { recursive: true });
const problems = []; let checks = 0;
const expect = (ok, msg) => { checks++; if (!ok) problems.push(msg); };

// ---- fixture + build ----
const J = (p) => JSON.parse(readFileSync(join(root, p), 'utf8'));
const base = J('tests/fixtures/site-texts/rpc.json'), pending = J('content/site-texts.imported-pr61.json');
const OVR = {
  'page.book.title': ['Varaa saunaelämys (DB)', 'Book a sauna experience (DB)'], 'seo.book.title': ['Varaa verkossa (DB) | Sipoonjoen Perinnesauna', 'Book online (DB) | Sipoonjoen Perinnesauna'],
  'page.order.title': ['Tilauksesi (DB)', 'Your order (DB)'], 'ui.shop.lead': ['Valitse kokemus (DB). Soita {{var:phone}}.', 'Choose an experience (DB). Call {{var:phone}}.'],
  'ui.shop.times_free.one': ['1 aika (DB)', '1 time (DB)'], 'ui.shop.times_free.other': ['{{var:n}} aikaa (DB)', '{{var:n}} times (DB)'], 'ui.order.lines_title': ['Tilauksen rivit (DB)', 'Order lines (DB)'],
};
const toks = (t) => [...new Set(t.match(/\{\{[^{}]*\}\}/g) || [])];
const rows = pending.map((r) => { const text = OVR[r.key] ? OVR[r.key][r.lang === 'fi' ? 0 : 1] : r.text; return { key: r.key, lang: r.lang, text, version: 1, placeholders: toks(text) }; });
const fx = { ...base, texts: [...base.texts, ...rows] };
await writeFile(join(WORK, 'fixture.json'), JSON.stringify(fx));
const DIST = join(WORK, 'dist');
const b = spawnSync('node', [join(root, 'booking/shop/build.mjs')], { cwd: root, encoding: 'utf8', env: { ...process.env, SITE_URL: 'http://localhost:4180', SITE_ENV: 'test', SITE_TEXTS_FIXTURE: join(WORK, 'fixture.json'), SHOP_DIST: DIST } });
if (b.status !== 0) { console.error(b.stdout.slice(-2000), b.stderr.slice(-2000)); process.exit(1); }
expect(!/käyttää repon varatekstiä/.test(b.stdout), 'buildin pitäisi löytää kaikki page.*/seo.*-avaimet fixturesta');
const { phoneDisplay } = await import(pathToFileURL(join(root, 'booking/shop/src/phone.js')));   // yksi vakio, kielikohtainen näkyvä muoto (fi 010 299 2866, en +358 10 299 2866)
const PHONES = { fi: phoneDisplay('fi'), en: phoneDisplay('en') };
expect(PHONES.fi === '010 299 2866' && PHONES.en === '+358 10 299 2866', 'puhelinvakio');

const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.avif': 'image/avif', '.png': 'image/png', '.jpg': 'image/jpeg', '.woff2': 'font/woff2', '.ico': 'image/x-icon' };
const server = createServer(async (req, res) => {
  const p = decodeURIComponent(new URL(req.url, 'http://x').pathname); let file = join(DIST, normalize(p));
  try { if ((await stat(file)).isDirectory()) file = join(file, 'index.html'); const buf = await readFile(file); res.writeHead(200, { 'content-type': types[extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' }); res.end(buf); }
  catch { res.writeHead(404, { 'content-type': 'text/plain' }); res.end('Not found'); }
});
await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
const ORIGIN = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const TZ = 'Europe/Helsinki', TOKEN = '3f2b8c1e-5a7d-4e9f-8b6a-1c2d3e4f5a6b';
const PATH = { fi: { shop: '/varaa/', order: '/tilaus/' }, en: { shop: '/en/book/', order: '/en/order/' } };
const SLUG = 'saunarituaali-ja-savusaunavuoro';

async function newPage(width, lang, name, textsRoute = null, allowWarn = null) {
  const mobile = width < 600;
  const ctx = await browser.newContext({ viewport: { width, height: mobile ? 844 : 900 }, isMobile: mobile, hasTouch: mobile, locale: lang === 'en' ? 'en-GB' : 'fi-FI', timezoneId: TZ });
  if (textsRoute) await ctx.route('**/booking/site-texts.json', textsRoute);
  const page = await ctx.newPage(); page.ctx = ctx;
  page.on('console', (m) => { if (allowWarn && allowWarn.test(m.text())) return; if (['error', 'warning'].includes(m.type())) problems.push(`${name} console.${m.type()}: ${m.text()} ${m.location().url || ''}`); });
  page.on('pageerror', (e) => problems.push(`${name} pageerror: ${e.message}`));
  page.on('response', (r) => { if (r.status() >= 400) problems.push(`${name} HTTP ${r.status()}: ${r.url()}`); });
  page.on('request', (r) => { if (!r.url().startsWith(ORIGIN) && !r.url().startsWith('data:')) problems.push(`${name} ulkoinen pyyntö: ${r.url()}`); if (/\/rest\/v1\/|supabase\.co/.test(r.url())) problems.push(`${name} backend-pyyntö: ${r.url()}`); });
  return page;
}
const go = async (page, url, sel) => { await page.goto(ORIGIN + url, { waitUntil: 'load' }); if (sel) await page.waitForSelector(sel, { timeout: 20000 }); await page.waitForTimeout(250); };
const body = (page) => page.locator('main').innerText();
const noRaw = (txt, label) => expect(!/\{\{|\}\}|\{[a-z]+\}|(^|\s)(null|undefined|NaN)(\s|$)/.test(txt), `${label}: raaka paikkamerkki / null / undefined sivulla`);
const hscroll = async (page, label) => expect(!(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1)), `${label}: vaakavieritys`);
const shot = (page, name) => page.screenshot({ path: join(SHOT, `${name}.png`), fullPage: false });
const DEFAULTS = { fi: { title: 'Varaa saunaelämys', lead: 'Valitse kokemus, päivä ja vuoro. Varaus vahvistuu maksun jälkeen.' }, en: {} };
const T = (await import(pathToFileURL(join(root, 'booking/shop/src/i18n.js')))).T, OT = (await import(pathToFileURL(join(root, 'booking/shop/src/order-texts.js')))).OT;

// ================= A) tietokannan teksti näkyy =================
for (const lang of ['fi', 'en']) for (const w of [390, 1280]) {
  const li = lang === 'fi' ? 0 : 1, label = `A-kauppa-${lang}-${w}`, page = await newPage(w, lang, label);
  await go(page, `${PATH[lang].shop}?mock=1`, '#booking-app .bk-card, #booking-app .bk-pc, #booking-app [class*=bk-]');
  await page.waitForTimeout(500);
  const h1 = await page.locator('main h1').first().innerText(), title = await page.title(), txt = await body(page);
  expect(h1 === OVR['page.book.title'][li], `${label}: h1 "${h1}" ≠ DB-teksti (build page.book.title)`);
  expect(title.includes('(DB)'), `${label}: <title> ei käytä seo.book.title-tekstiä: ${title}`);
  expect(txt.includes(OVR['ui.shop.lead'][li].replace('{{var:phone}}', PHONES[lang])), `${label}: ui.shop.lead (DB) + puhelin "${PHONES[lang]}" puuttuu sivulta`);
  noRaw(txt, label); await hscroll(page, label); await shot(page, label);
  // funktiolehti (times_free, monikko one/other): päivänäkymä – seuraavan 10 päivän ensimmäinen päivä, jolla on vapaita aikoja
  let spots = [];
  for (let i = 0; i < 10 && !spots.length; i++) { const d = new Date(Date.now() + i * 864e5).toLocaleDateString('sv-SE', { timeZone: TZ }); await go(page, `${PATH[lang].shop}?mock=1#/paiva/${d}`); await page.waitForTimeout(500); spots = await page.locator('.bk-badge.free').allInnerTexts(); }
  expect(spots.length > 0, `${label}: päivänäkymässä ei vapaita aikoja`);
  if (spots.length) expect(spots.every((s) => /\(DB\)/.test(s) && /^\d+ /.test(s)), `${label}: times_free-malli (DB) ei näy: ${JSON.stringify(spots.slice(0, 4))}`);
  if (spots.length) await shot(page, `${label}-paivanakyma`);
  await page.ctx.close();
}
for (const lang of ['fi', 'en']) for (const w of [390, 1280]) {
  const li = lang === 'fi' ? 0 : 1, label = `A-tilaus-${lang}-${w}`, page = await newPage(w, lang, label);
  await go(page, `${PATH[lang].order}?mock=1&t=${TOKEN}`, '#order-app .ord-card, #order-app .ord-lines, #order-app p');
  await page.waitForTimeout(500);
  const h1 = await page.locator('main h1').first().innerText(), txt = await body(page);
  expect(h1 === OVR['page.order.title'][li], `${label}: h1 "${h1}" ≠ DB-teksti`);
  expect(txt.includes(OVR['ui.order.lines_title'][li]), `${label}: ui.order.lines_title (DB) puuttuu`);
  noRaw(txt, label); await hscroll(page, label); await shot(page, label);
  await page.ctx.close();
}

// ================= B) puuttuvat / viallisat tekstit → repon oletus samalla kielellä =================
const variants = {
  'tyhja': (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ texts: [] }) }),
  'virheellinen-json': (route) => route.fulfill({ status: 200, contentType: 'application/json', body: 'tämä ei ole JSON' }),
  'vain-fi': async (route) => { const r = await route.fetch(); const j = await r.json(); route.fulfill({ response: r, json: { ...j, texts: j.texts.filter((x) => x.lang === 'fi') } }); },
  'rikkinäinen-paikkamerkki': async (route) => { const r = await route.fetch(); const j = await r.json(); route.fulfill({ response: r, json: { ...j, texts: j.texts.map((x) => (x.key === 'ui.shop.lead' ? { ...x, text: 'Rikki {{price:999}} {{foo:1}}' } : x)) } }); },
};
for (const [name, handler] of Object.entries(variants)) for (const lang of ['fi', 'en']) {
  const label = `B-${name}-${lang}`, page = await newPage(390, lang, label, handler, name === 'rikkinäinen-paikkamerkki' ? /site-texts: ui\.shop\.lead \[(fi|en)\] ohitettu/ : null);
  await go(page, `${PATH[lang].shop}?mock=1`, '#booking-app [class*=bk-]'); await page.waitForTimeout(500);
  const txt = await body(page), L0 = T[lang].lead;
  if (name === 'vain-fi' && lang === 'fi') expect(txt.includes(OVR['ui.shop.lead'][0].replace('{{var:phone}}', PHONES.fi)), `${label}: fi-rivit pitäisi käyttää`);
  else expect(txt.includes(L0), `${label}: repon oletus "${L0}" puuttuu`);
  if (lang === 'en') expect(!txt.includes(DEFAULTS.fi.lead) && !/Valitse kokemus/.test(txt), `${label}: en-sivulla suomenkielistä tekstiä`);
  if (!(name === 'vain-fi' && lang === 'fi')) expect(!/Valitse kokemus \(DB\)|Choose an experience \(DB\)/.test(txt), `${label}: ui.shop.lead (DB) näkyy vaikka riviä ei pitäisi käyttää`);
  noRaw(txt, label);
  await page.ctx.close();
}
await browser.close(); server.close();
if (problems.length) { console.error(`ONGELMIA (${problems.length}) / ${checks} tarkistusta:\n - ${problems.join('\n - ')}`); process.exit(1); }
console.log(`OK: ${checks} tarkistusta; DB-tekstit (build + ajoaika), puuttuvien avainten oletukset FI/EN; kuvat: ${SHOT}`);
