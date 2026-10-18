// E2E (Playwright + google-chrome): hoitovalitsin (booking_50) kaupassa ja tilaussivulla – KOKEILUTILASSA (?mock=1): kaikki RPC:t vastataan selaimessa, EI yhteyttä palvelimeen.
//   SHOP_DIST=/tmp/shop-hoito node booking/shop/build.mjs   (ensin)
//   PW_DIR=/workspace/node_modules SHOP_DIST=/tmp/shop-hoito SHOT_DIR=/workspace/screenshots-hoitovalitsin node booking/scripts/e2e-hoitovalitsin.mjs
// Tarkistaa: pakollinen valinta (ei jatkoa ilman), valinta näkyy kassalla/tarkistuksessa/vahvistussivulla, muutos vahvistussivulla ja tilaussivulla, palvelinvirheet FI+EN,
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
const SHOP = resolve(process.env.SHOP_DIST || '/tmp/shop-hoito'), SHOT = resolve(process.env.SHOT_DIR || '/workspace/screenshots-hoitovalitsin');
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

async function newPage(width, lang = 'fi', name = 'p') {
  const mobile = width < 600;
  const ctx = await browser.newContext({ viewport: { width, height: mobile ? 844 : 900 }, isMobile: mobile, hasTouch: mobile, locale: lang === 'en' ? 'en-GB' : 'fi-FI', timezoneId: TZ });
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

// ======================= 1) KAUPPA: tuotesivu ja valitsin (FI + EN, 4 leveyttä) =======================
for (const lang of ['fi', 'en']) for (const w of WIDTHS) {
  const page = await newPage(w, lang, `kauppa-${lang}-${w}`);
  await goto(page, `${PATH[lang].shop}?mock=1#/tuote/saunahoito-2`);
  await page.waitForSelector('[data-testid=option-picker]');
  await page.waitForSelector('button.bk-cell.free');
  const radios = await page.$$('[data-testid=option-picker] input[type=radio]');
  expect(radios.length === 4, `${lang}/${w}: 4 vaihtoehtoa, löytyi ${radios.length}`);
  expect((await page.$$('[data-testid=option-picker] input:checked')).length === 0, `${lang}/${w}: ei esivalintaa`);
  const names = await page.$$eval('.bk-opt-name', (e) => e.map((x) => x.textContent));
  expect(JSON.stringify(names) === JSON.stringify(lang === 'fi' ? ['Hunajahoito', 'Vihtahoito', 'Suolahoito', 'Turvehoito'] : ['Honey treatment', 'Birch whisk treatment', 'Salt treatment', 'Peat treatment']), `${lang}/${w}: nimet ${names}`);
  expect((await page.textContent('.bk-opt legend')).includes(lang === 'fi' ? 'Valitse hoito' : 'Choose your treatment'), `${lang}/${w}: otsikko`);
  expect((await page.textContent('.bk-opt legend')).includes(lang === 'fi' ? 'Pakollinen' : 'Required'), `${lang}/${w}: pakollinen-merkki`);
  // ei jatkoa ilman valintaa, vaikka aika valittu
  await pickDay(page); await page.click('.bk-time-btn'); await settle(page);
  expect(await page.isDisabled('.bk-continue .btn'), `${lang}/${w}: jatka-painike pois käytöstä ilman valintaa`);
  expect((await page.textContent('.bk-pick-sum')).includes(lang === 'fi' ? 'Valitse hoito jatkaaksesi' : 'Choose a treatment to continue'), `${lang}/${w}: ohjeteksti`);
  await layout(page, '#booking-app', `kauppa ${lang} ${w} (ei valintaa)`);
  if (lang === 'fi' && (w === 390 || w === 1280)) await page.screenshot({ path: join(SHOT, `kauppa-${w}-tuotesivu-valitsematta.png`), fullPage: true });
  if (lang === 'en' && w === 390) await page.screenshot({ path: join(SHOT, `kauppa-${w}-en-tuotesivu.png`), fullPage: true });
  await page.click('label[for$="-vihtahoito"]'); await settle(page);
  expect(!(await page.isDisabled('.bk-continue .btn')), `${lang}/${w}: jatka sallittu valinnan jälkeen`);
  expect((await page.getAttribute('label[for$="-vihtahoito"]', 'class')).includes('on'), `${lang}/${w}: valittu kortti korostettu`);
  expect(page.url().includes('o=vihtahoito'), `${lang}/${w}: valinta URL:ssä`);
  await layout(page, '#booking-app', `kauppa ${lang} ${w} (valittu)`);
  if (lang === 'fi' && (w === 390 || w === 1280)) await page.screenshot({ path: join(SHOT, `kauppa-${w}-tuotesivu-valittu.png`), fullPage: true });
  await page.ctx.close();
}

// ======================= 2) KULKU: tuotesivu → kassa → tarkistus → vahvistus → muutos (FI, 390) ja EN =======================
async function flow(lang, w) {
  const page = await newPage(w, lang, `kulku-${lang}-${w}`);
  const T = lang === 'fi' ? { honey: 'Hunajahoito', salt: 'Suolahoito', birch: 'Vihtahoito', notChosen: 'valitsematta' } : { honey: 'Honey treatment', salt: 'Salt treatment', birch: 'Birch whisk treatment', notChosen: 'not chosen' };
  await goto(page, `${PATH[lang].shop}?mock=1#/tuote/saunahoito-2`);
  await page.waitForSelector('button.bk-cell.free');
  const ds = await pickDay(page); await page.click('.bk-time-btn'); await settle(page);
  await page.click('label[for$="-hunajahoito"]'); await settle(page);
  await page.click('.bk-continue .btn'); await page.waitForSelector('.bk-checkout');
  expect(page.url().includes('mock=1') && page.url().includes('o=hunajahoito'), `${lang}: kassan URL säilyttää mock ja valinnan: ${page.url()}`);
  expect((await page.textContent('[data-testid=sum-option]')) === T.honey, `${lang}: kassan yhteenvedossa valittu hoito`);
  expect((await page.$$('.bk-checkout [data-testid=option-picker] input[type=radio]:checked')).length === 1, `${lang}: kassan valitsin esivalittu`);
  await layout(page, '#booking-app', `kassa ${lang} ${w}`);
  if (lang === 'fi') await page.screenshot({ path: join(SHOT, `kauppa-${w}-kassa.png`), fullPage: true });
  // vaihto kassalla päivittää yhteenvedon
  await page.click('label[for$="-suolahoito"]'); await settle(page);
  expect((await page.textContent('[data-testid=sum-option]')) === T.salt, `${lang}: yhteenveto päivittyy valinnasta`);
  await page.fill('input[name=name], #bk-name', 'Testi Asiakas').catch(() => {});
  return { page, ds, T };
}
async function fillAndReview(page, lang) {
  const names = await page.$$eval('.bk-form input, .bk-form textarea', (els) => els.map((e) => `${e.name}|${e.id}|${e.type}`));
  const set = async (re, v) => { const n = names.find((x) => re.test(x)); if (n) { const [name, id] = n.split('|'); await page.fill(id ? `#${id}` : `[name="${name}"]`, v); } };
  await set(/^name\|/i, 'Testi Asiakas'); await set(/email/i, 'testi@example.com'); await set(/phone|tel/i, '+358401234567');
  await page.$$eval('.bk-form input[type=checkbox]', (els) => { const t = els.find((e) => /terms|ehdot/i.test(e.name + e.id)) || els[0]; if (t && !t.checked) t.click(); });
  await page.click('.bk-form button[type=submit]'); await settle(page);
}
{
  const { page, T } = await flow('fi', 390);
  await fillAndReview(page, 'fi');
  await page.waitForSelector('[data-testid=review-option]');
  expect((await page.textContent('[data-testid=review-option]')) === T.salt, 'fi: tarkistuksessa valittu hoito');
  await page.screenshot({ path: join(SHOT, 'kauppa-390-tarkistus.png'), fullPage: true });
  await page.click('.bk-review .bk-actions .btn:not(.light)'); await page.waitForSelector('[data-testid=conf-option]');
  expect(page.url().includes('mock=1'), 'fi: vahvistussivu säilyttää mock-tilan');
  expect((await page.textContent('[data-testid=conf-option]')) === T.salt, 'fi: vahvistussivulla valittu hoito');
  await layout(page, '#booking-app', 'vahvistus fi 390');
  await page.screenshot({ path: join(SHOT, 'kauppa-390-vahvistus.png'), fullPage: true });
  // muutos: vaihda hoito (pelkkä hoito, ei aikaa)
  await page.click('a[href$="/muuta"]'); await page.waitForSelector('[data-testid=option-picker]');
  expect((await page.textContent('[data-testid=change-current-option]')) === T.salt, 'fi: muutosnäkymä näyttää nykyisen valinnan');
  expect((await page.textContent('[data-testid=option-picker] legend')).includes('Valitse hoito'), 'fi: muutosnäkymän otsikko = items[].option_label (booking_52)');
  expect(await page.isDisabled('.bk-continue .btn'), 'fi: tallenna pois käytöstä ennen muutosta');
  await page.click('label[for$="-turvehoito"]'); await settle(page);
  expect(!(await page.isDisabled('.bk-continue .btn')), 'fi: tallenna sallittu pelkällä hoidon vaihdolla');
  await layout(page, '#booking-app', 'muutos fi 390');
  await page.screenshot({ path: join(SHOT, 'kauppa-390-muuta-hoitoa.png'), fullPage: true });
  await page.click('.bk-continue .btn'); await page.waitForSelector('[data-testid=conf-option]');
  expect((await page.textContent('[data-testid=conf-option]')) === 'Turvehoito', 'fi: hoito vaihtui vahvistussivulla: ' + await page.textContent('[data-testid=conf-option]'));
  await page.ctx.close();
}
{
  const { page, T } = await flow('en', 1280);
  await fillAndReview(page, 'en');
  await page.waitForSelector('[data-testid=review-option]');
  await page.click('.bk-review .bk-actions .btn:not(.light)'); await page.waitForSelector('[data-testid=conf-option]');
  expect((await page.textContent('[data-testid=conf-option]')) === T.salt, 'en: vahvistussivulla valittu hoito (EN-nimi)');
  await layout(page, '#booking-app', 'vahvistus en 1280');
  await page.screenshot({ path: join(SHOT, 'kauppa-1280-en-vahvistus.png'), fullPage: true });
  await page.ctx.close();
}

// ======================= 3) Kassa ilman valintaa (suora linkki) → ei voi jatkaa; palvelinvirheet FI+EN =======================
for (const lang of ['fi', 'en']) {
  const page = await newPage(390, lang, `kassa-${lang}`);
  const msg = { fi: { req: 'Valitse hoito ennen kuin jatkat.', inv: 'Valittua hoitoa ei voi varata. Valitse hoito uudelleen.' }, en: { req: 'Please choose a treatment before you continue.', inv: 'The selected treatment cannot be booked. Please choose again.' } }[lang];
  await goto(page, `${PATH[lang].shop}?mock=1#/tuote/saunahoito-2`);
  await page.waitForSelector('button.bk-cell.free'); const ds = await pickDay(page); await page.click('.bk-time-btn'); await settle(page);
  await page.click('label[for$="-vihtahoito"]'); await settle(page);
  const hash = new URL(page.url()).hash;   // #/tuote/saunahoito-2?n=1&d=…&t=…&o=vihtahoito
  const q = new URLSearchParams(hash.split('?')[1]); const tok = q.get('t');
  await goto(page, `${PATH[lang].shop}?mock=1#/hoito/saunahoito-2/${ds}/${tok}?n=1`);   // ilman o-parametria
  await page.reload(); await page.waitForSelector('.bk-checkout');
  expect((await page.textContent('[data-testid=sum-option]')) === (lang === 'fi' ? 'valitsematta' : 'not chosen'), `${lang}: kassa ilman valintaa näyttää "valitsematta"`);
  await fillAndReview(page, lang);
  expect(await page.isVisible('.bk-opt-err'), `${lang}: virheilmoitus näkyy ilman valintaa`);
  expect((await page.textContent('.bk-opt-err')) === msg.req, `${lang}: virheteksti: ${await page.textContent('.bk-opt-err')}`);
  expect((await page.$('[data-testid=review-option]')) === null, `${lang}: ei edetty tarkistukseen ilman valintaa`);
  expect(await page.evaluate(() => document.activeElement?.matches('input[type=radio]')), `${lang}: fokus valitsimeen`);
  await layout(page, '#booking-app', `kassa-virhe ${lang} 390`);
  if (lang === 'fi') await page.screenshot({ path: join(SHOT, 'kauppa-390-kassa-valinta-puuttuu.png'), fullPage: true });
  await page.ctx.close();
  // palvelimen virheet (?fail=): option_required ja invalid_option varauksen vahvistuksessa
  for (const code of ['option_required', 'invalid_option']) {
    const pg = await newPage(390, lang, `fail-${code}-${lang}`);
    await goto(pg, `${PATH[lang].shop}?mock=1&fail=${code}#/tuote/saunahoito-2`);
    await pg.waitForSelector('button.bk-cell.free'); const d2 = await pickDay(pg); await pg.click('.bk-time-btn'); await settle(pg);
    await pg.click('label[for$="-vihtahoito"]'); await settle(pg); await pg.click('.bk-continue .btn'); await pg.waitForSelector('.bk-checkout');
    await fillAndReview(pg, lang); await pg.waitForSelector('[data-testid=review-option]');
    await pg.click('.bk-review .bk-actions .btn:not(.light)'); await pg.waitForSelector('.bk-opt-err:not([hidden])');
    expect((await pg.textContent('.bk-opt-err')) === (code === 'option_required' ? msg.req : msg.inv), `${lang}/${code}: palvelinvirheen teksti: ${await pg.textContent('.bk-opt-err')}`);
    expect(await pg.isVisible('.bk-checkout'), `${lang}/${code}: palattu lomakkeelle`);
    const checked = (await pg.$$('.bk-checkout [data-testid=option-picker] input[type=radio]:checked')).length;
    expect(checked === (code === 'invalid_option' ? 0 : 1), `${lang}/${code}: valinnan tila virheen jälkeen (${checked})`);
    if (lang === 'fi') await pg.screenshot({ path: join(SHOT, `kauppa-390-virhe-${code}.png`), fullPage: true });
    void d2; await pg.ctx.close();
  }
}

// ======================= 4) TILAUSSIVU: valittu hoito, "valitsematta", vaihto, lukittu =======================
for (const lang of ['fi', 'en']) for (const w of WIDTHS) {
  const page = await newPage(w, lang, `tilaus-${lang}-${w}`);
  const T = lang === 'fi' ? { cur: 'Vihtahoito', new: 'Turvehoito', done: 'Hoito vaihdettu.' } : { cur: 'Birch whisk treatment', new: 'Peat treatment', done: 'Treatment changed.' };
  await goto(page, `${PATH[lang].order}?t=${TOKEN}&mock=1&scenario=hoito`);
  await page.waitForSelector('[data-testid=order-reservations]');
  expect((await page.textContent('[data-testid=res-option]')).includes(T.cur), `tilaus ${lang}/${w}: varausrivillä valittu hoito`);
  const pk = '[data-testid=option-picker-601]';
  expect((await page.$$(`${pk} input[type=radio]`)).length === 4, `tilaus ${lang}/${w}: 4 vaihtoehtoa`);
  expect((await page.textContent(`${pk} legend`)).includes(lang === 'fi' ? 'Valitse hoito' : 'Choose your treatment'), `tilaus ${lang}/${w}: valitsimen otsikko = reservations[].option_label (booking_52)`);
  expect(await page.isDisabled('[data-testid=option-save-601]'), `tilaus ${lang}/${w}: tallenna pois käytöstä ennen muutosta`);
  await layout(page, '#order-app', `tilaus ${lang} ${w}`);
  if (lang === 'fi' && [390, 1280].includes(w)) await page.screenshot({ path: join(SHOT, `tilaussivu-${w}-valittu.png`), fullPage: true });
  await page.click(`${pk} label[for$="-turvehoito"]`); await settle(page);
  expect(!(await page.isDisabled('[data-testid=option-save-601]')), `tilaus ${lang}/${w}: tallenna sallittu`);
  if (w === 390) {
    await page.click('[data-testid=option-save-601]'); await page.waitForSelector('[data-testid=order-msg] .bk-ok');
    expect((await page.textContent('[data-testid=order-msg]')).includes(T.done), `tilaus ${lang}: vahvistus: ${await page.textContent('[data-testid=order-msg]')}`);
    expect((await page.textContent('[data-testid=res-option]')).includes(T.new), `tilaus ${lang}: rivi päivittyi`);
    if (lang === 'fi') await page.screenshot({ path: join(SHOT, 'tilaussivu-390-vaihdettu.png'), fullPage: true });
  }
  await page.ctx.close();
}
for (const lang of ['fi', 'en']) {
  const page = await newPage(390, lang, `tilaus-missing-${lang}`);
  await goto(page, `${PATH[lang].order}?t=${TOKEN}&mock=1&scenario=hoito-valitsematta`);
  await page.waitForSelector('[data-testid=res-option-missing]');
  expect((await page.textContent('[data-testid=res-option-missing]')).includes(lang === 'fi' ? 'valitsematta' : 'not chosen'), `tilaus ${lang}: valitsematta-merkki`);
  expect(await page.isDisabled('[data-testid=option-save-601]'), `tilaus ${lang}: tallenna pois ennen valintaa`);
  await layout(page, '#order-app', `tilaus-valitsematta ${lang} 390`);
  if (lang === 'fi') await page.screenshot({ path: join(SHOT, 'tilaussivu-390-valitsematta.png'), fullPage: true });
  await page.click('[data-testid=option-picker-601] label[for$="-hunajahoito"]'); await page.click('[data-testid=option-save-601]');
  await page.waitForSelector('[data-testid=order-msg] .bk-ok'); expect((await page.$('[data-testid=res-option-missing]')) === null, `tilaus ${lang}: valitsematta poistui tallennuksen jälkeen`);
  await page.ctx.close();
  const pl = await newPage(390, lang, `tilaus-lukittu-${lang}`);
  await goto(pl, `${PATH[lang].order}?t=${TOKEN}&mock=1&scenario=hoito-lukittu`);
  await pl.waitForSelector('[data-testid=option-section]');
  expect((await pl.$('[data-testid=option-save-601]')) === null && (await pl.$('[data-testid=option-current]')) !== null, `tilaus ${lang}: lukittu: ei muutosvalitsinta, nykyinen valinta näkyy`);
  await pl.ctx.close();
}

await browser.close(); server.close();
if (problems.length) { console.error(`EPÄONNISTUI (${problems.length} ongelmaa, ${checks} tarkistusta):\n- ` + [...new Set(problems)].join('\n- ')); process.exit(1); }
console.log(`OK: ${checks} tarkistusta, kuvat: ${SHOT}`);
