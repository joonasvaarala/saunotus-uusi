// E2E (Playwright + google-chrome): staattisten sivujen tekstit TIETOKANNASTA (sopimus §18, osa 3 PR 2) – ei yhteyttä palvelimeen eikä tuotantoon (staattinen dist + fixture).
//   node booking/scripts/e2e-sivutekstit-sivut.mjs     (rakentaa itse fixture-distit: SITE_TEXTS_FIXTURE = tuotannon tekstit + pending-import-2, valitut tekstit merkitty "(DB)")
//   PW_DIR=/workspace/pw/node_modules SHOT_DIR=/workspace/screenshots-sivutekstit-sivut node booking/scripts/e2e-sivutekstit-sivut.mjs
// Tarkistaa FI/EN × 390/1280:
//  A) tietokannan teksti näkyy: etusivun h1 + <title> (seo), päävalikko (nav.main), alatunniste (ui.footer, Reittiohje/Y-tunnus), arvostelut, kortit (sauna), alt-teksti, info-sivun **lihavointi** → <strong>,
//     paikkamerkki {{price:48}} täyttyy hinnaksi; sama valikko/alatunniste kaupan sivulla (/varaa/)
//  B) ilman muokkauksia (pelkkä tuontitiedosto) sivu on täsmälleen sama kuin ilman rivejä (ulkoasu ei muutu); vain FI-rivit → en-sivu käyttää repon EN-oletuksia (ei fi-tekstiä)
//  C) ei konsolivirheitä, ei ulkoisia pyyntöjä, ei vaakavieritystä, ei raakaa {{…}}/{n}. Kuvat: SHOT_DIR.
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
const SHOT = resolve(process.env.SHOT_DIR || '/workspace/screenshots-sivutekstit-sivut'), WORK = resolve(process.env.WORK_DIR || '/tmp/e2e-sivutekstit-sivut');
await mkdir(SHOT, { recursive: true }); await mkdir(WORK, { recursive: true });
const problems = []; let checks = 0;
const expect = (ok, msg) => { checks++; if (!ok) problems.push(msg); };

const J = (p) => JSON.parse(readFileSync(join(root, p), 'utf8'));
const base = J('content/site-texts.fallback.json'), pending = J('content/site-texts.pending-import-2.json');
// [fi, en] – korvaavat tekstit (täytyy säilyttää paikkamerkit)
const OVR = {
  'page.front.hero.title': ['Etusivun otsikko (DB)', 'Front headline (DB)'], 'seo.front.title': ['Etusivu (DB) | Sipoonjoen Perinnesauna', 'Home (DB) | Sipoonjoen Perinnesauna'],
  'nav.main.sauna': ['Saunavuorot (DB)', 'Sauna sessions (DB)'], 'ui.footer.contact': ['Yhteystiedot (DB)', 'Contact (DB)'], 'ui.site.directions': ['Reittiohje (DB)', 'Directions (DB)'], 'ui.site.business_id': ['Y-tunnus (DB)', 'Business ID (DB)'],
  'ui.reviews.title': ['Kokemuksia (DB)', 'Experiences (DB)'], 'ui.card.sauna.yleinen.title': ['Yleinen vuoro (DB)', 'Public session (DB)'], 'ui.alt.hero_ovi_uusi': ['Sauna-alueen ovi (DB)', 'Sauna door (DB)'],
  'page.info.sections.2.blocks.3.p': ['**Saavu ajoissa (DB).**', '**Arrive on time (DB).**'],
  'ui.card.corporate.vuoro.list.1': ['Ma–to klo 14–16 (2 h): {{price:48}} (DB)', 'Mon–Thu 2–4 pm (2 h): {{price:48}} (DB)'],
};
const toks = (t) => [...new Set(t.match(/\{\{[^{}]*\}\}/g) || [])];
const mkRows = (over, langs = ['fi', 'en']) => pending.filter((r) => langs.includes(r.lang)).map((r) => { const text = over && OVR[r.key] ? OVR[r.key][r.lang === 'fi' ? 0 : 1] : r.text; return { key: r.key, lang: r.lang, text, version: 1, placeholders: toks(text) }; });
async function build(name, rows) {
  const f = join(WORK, `${name}.json`), dist = join(WORK, name);
  await writeFile(f, JSON.stringify({ ...base, texts: [...base.texts, ...rows] }));
  const b = spawnSync('node', [join(root, 'booking/shop/build.mjs')], { cwd: root, encoding: 'utf8', env: { ...process.env, SITE_URL: 'http://localhost:4180', SITE_ENV: 'test', SITE_TEXTS_FIXTURE: f, SHOP_DIST: dist, ARTICLES_IMAGES: '0', ARTICLES_STATE_FILE: join(WORK, `state-${name}.json`) } });
  if (b.status !== 0) { console.error(b.stdout.slice(-2000), b.stderr.slice(-2000)); process.exit(1); }
  return { dist, log: b.stdout };
}
const A = await build('db', mkRows(true)), P = await build('plain', mkRows(false)), N = await build('none', []), F = await build('fionly', mkRows(true, ['fi']));
expect(/staattiset sivut: \d+ tekstiä tietokannasta, 0 repon oletuksella/.test(A.log) && /staattiset sivut: 0 tekstiä tietokannasta/.test(N.log), 'build-lokin yhteenveto (käytetyt / oletuksella)');

const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.avif': 'image/avif', '.png': 'image/png', '.jpg': 'image/jpeg', '.woff2': 'font/woff2', '.xml': 'application/xml', '.txt': 'text/plain' };
const serve = async (DIST) => {
  const server = createServer(async (req, res) => {
    const p = decodeURIComponent(new URL(req.url, 'http://x').pathname); let file = join(DIST, normalize(p));
    try { if ((await stat(file)).isDirectory()) file = join(file, 'index.html'); const buf = await readFile(file); res.writeHead(200, { 'content-type': types[extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' }); res.end(buf); }
    catch { res.writeHead(404, { 'content-type': 'text/plain' }); res.end('Not found'); }
  });
  await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
  return { server, origin: `http://127.0.0.1:${server.address().port}` };
};
const S = { db: await serve(A.dist), plain: await serve(P.dist), none: await serve(N.dist), fionly: await serve(F.dist) };
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const PATHS = { front: { fi: '/', en: '/en/' }, sauna: { fi: '/saunavuorot/', en: '/en/sauna/' }, info: { fi: '/info/', en: '/en/info/' }, companies: { fi: '/yritykset/', en: '/en/companies/' }, shop: { fi: '/varaa/', en: '/en/book/' } };

async function open(which, width, lang, page_, name) {
  const mobile = width < 600, ORIGIN = S[which].origin;
  const ctx = await browser.newContext({ viewport: { width, height: mobile ? 844 : 900 }, isMobile: mobile, hasTouch: mobile, locale: lang === 'en' ? 'en-GB' : 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const page = await ctx.newPage(); page.ctx = ctx;
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type())) problems.push(`${name} console.${m.type()}: ${m.text()} ${m.location().url || ''}`); });
  page.on('pageerror', (e) => problems.push(`${name} pageerror: ${e.message}`));
  page.on('response', (r) => { if (r.status() >= 400) problems.push(`${name} HTTP ${r.status()}: ${r.url()}`); });
  page.on('request', (r) => { if (!r.url().startsWith(ORIGIN) && !r.url().startsWith('data:')) problems.push(`${name} ulkoinen pyyntö: ${r.url()}`); if (/\/rest\/v1\/|supabase\.co/.test(r.url())) problems.push(`${name} backend-pyyntö: ${r.url()}`); });
  await page.goto(ORIGIN + PATHS[page_][lang] + (page_ === 'shop' ? '?mock=1' : ''), { waitUntil: 'load' }); await page.waitForTimeout(300);
  return page;
}
const noRaw = (txt, label) => expect(!/\{\{|\}\}|\{[a-z]+\}|(^|\s)(null|undefined|NaN)(\s|$)/.test(txt), `${label}: raaka paikkamerkki / null / undefined sivulla`);
const hscroll = async (page, label) => expect(!(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1)), `${label}: vaakavieritys`);
const shot = (page, name) => page.screenshot({ path: join(SHOT, `${name}.png`), fullPage: false });
const PRICE = (lang) => (lang === 'fi' ? '350 €' : '€350');

// ================= A) tietokannan teksti näkyy =================
for (const lang of ['fi', 'en']) for (const w of [390, 1280]) {
  const li = lang === 'fi' ? 0 : 1;
  // etusivu
  let label = `A-etusivu-${lang}-${w}`, page = await open('db', w, lang, 'front', label);
  expect((await page.locator('main h1').first().innerText()) === OVR['page.front.hero.title'][li], `${label}: h1 ≠ DB-teksti`);
  expect((await page.title()) === OVR['seo.front.title'][li], `${label}: <title> ≠ seo.front.title`);
  let html = await page.content(), txt = await page.locator('body').innerText(), low = txt.toLowerCase();
  expect(html.includes(`>${OVR['nav.main.sauna'][li]}</a>`), `${label}: päävalikon teksti (DB) puuttuu`);
  expect(['ui.footer.contact', 'ui.site.directions', 'ui.site.business_id'].every((k) => low.includes(OVR[k][li].toLowerCase())), `${label}: alatunniste (DB) puuttuu`);
  expect(txt.includes(OVR['ui.reviews.title'][li]), `${label}: arvostelujen otsikko (DB) puuttuu`);
  expect(html.includes(`alt="${OVR['ui.alt.hero_ovi_uusi'][li]}"`), `${label}: alt-teksti (DB) puuttuu`);
  noRaw(txt, label); await hscroll(page, label); await shot(page, label); await page.ctx.close();
  // sauna: kortin otsikko
  label = `A-sauna-${lang}-${w}`; page = await open('db', w, lang, 'sauna', label);
  txt = await page.locator('main').innerText(); expect(txt.includes(OVR['ui.card.sauna.yleinen.title'][li]), `${label}: kortin otsikko (DB) puuttuu`);
  noRaw(txt, label); await hscroll(page, label); await shot(page, label); await page.ctx.close();
  // info: **lihavointi** → <strong>, ei kirjaimellisia tähtiä
  label = `A-info-${lang}-${w}`; page = await open('db', w, lang, 'info', label);
  const strong = await page.locator('main strong').allInnerTexts(); html = await page.locator('main').innerHTML();
  expect(strong.some((s) => s.includes(lang === 'fi' ? 'Saavu ajoissa (DB)' : 'Arrive on time (DB)')), `${label}: <strong> (DB) puuttuu: ${JSON.stringify(strong)}`);
  expect(!(await page.locator('main').innerText()).includes('**'), `${label}: **-merkit näkyvät sivulla`);
  noRaw(await page.locator('main').innerText(), label); await hscroll(page, label); await shot(page, label); await page.ctx.close();
  // yritykset: kortin lista, hinta täyttyy paikkamerkistä
  label = `A-yritykset-${lang}-${w}`; page = await open('db', w, lang, 'companies', label);
  txt = await page.locator('main').innerText(); expect(txt.includes(`${PRICE(lang)} (DB)`), `${label}: {{price:48}} ei täyttynyt hinnaksi (${PRICE(lang)})`);
  noRaw(txt, label); await hscroll(page, label); await page.ctx.close();
  // kaupan sivu (oma kehys): valikko + alatunniste samoista teksteistä
  label = `A-kauppa-${lang}-${w}`; page = await open('db', w, lang, 'shop', label);
  html = await page.content(); txt = await page.locator('body').innerText();
  expect(html.includes(`>${OVR['nav.main.sauna'][li]}</a>`), `${label}: kaupan sivun valikko (DB) puuttuu`);
  expect(txt.toLowerCase().includes(OVR['ui.footer.contact'][li].toLowerCase()), `${label}: kaupan sivun alatunniste (DB) puuttuu`);
  noRaw(txt, label); await hscroll(page, label); await shot(page, label); await page.ctx.close();
}

// ================= B) ulkoasu ei muutu ilman muokkauksia; puuttuva kieli → repon oletus =================
const readDist = (d, f) => readFileSync(join(d, f), 'utf8');
for (const f of ['index.html', 'en/index.html', 'saunavuorot/index.html', 'en/sauna/index.html', 'info/index.html', 'en/info/index.html', 'yritykset/index.html', 'lahjakortti/index.html', 'hoidot-rituaalit/index.html', 'ehdot/index.html', 'tietosuoja/index.html', 'varaa/index.html', 'en/book/index.html', '404.html']) {
  expect(readDist(P.dist, f) === readDist(N.dist, f), `B: ${f} muuttui kun tuontitiedosto on "tietokannassa" ilman muokkauksia`);
}
for (const w of [390, 1280]) {
  const label = `B-vain-fi-en-${w}`, page = await open('fionly', w, 'en', 'front', label);
  const txt = await page.locator('body').innerText();
  expect(!/\(DB\)/.test(txt), `${label}: FI-rivi vuoti en-sivulle`);
  expect(txt.toLowerCase().includes(J('content/site.json').ui.en.footerContact.toLowerCase()) && (await page.locator('main h1').first().innerText()) === J('content/pages/home.json').en.hero.title, `${label}: EN-oletus puuttuu`);
  noRaw(txt, label); await page.ctx.close();
  const fi = await open('fionly', w, 'fi', 'front', `B-vain-fi-fi-${w}`); expect((await fi.locator('main h1').first().innerText()) === OVR['page.front.hero.title'][0], 'B: fi-rivit pitää käyttää'); await fi.ctx.close();
}
await browser.close(); for (const s of Object.values(S)) s.server.close();
if (problems.length) { console.error(`E2E EPÄONNISTUI (${problems.length}/${checks}):\n- ${problems.slice(0, 60).join('\n- ')}`); process.exit(1); }
console.log(`E2E OK: ${checks} tarkistusta; kuvat ${SHOT}`);
