// E2E (Playwright + google-chrome): hallinnan hoitovalinta (booking_50) KOKEILUTILASSA (/admin/?mock=1): RPC:t vastataan selaimessa (admin/options-mock.js), EI yhteyttä palvelimeen.
//   PW_DIR=/workspace/node_modules SHOT_DIR=/workspace/screenshots-hoitovalitsin node booking/scripts/e2e-hoitovalitsin-admin.mjs
// Tarkistaa: hoito näkyy päivänäkymässä, varauslistalla ja varauksen tiedoissa; "valitsematta" vanhalla varauksella; vaihto (admin_set_reservation_option, ilmoitus asiakkaalle);
// uuden varauksen valitsin (pakollinen, p_option_code); vaihtoehtojen hallinta (kun toteutettu); FI+EN; asettelu 360/390/430/1280, kosketuskohteet, kontrasti, ei sinistä; ei pyyntöjä backendille.
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
const SHOT = resolve(process.env.SHOT_DIR || '/workspace/screenshots-hoitovalitsin');
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
const WIDTHS = [360, 390, 430, 1280];

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
  for (const el of root.querySelectorAll('label.srcopt, label.bk-opt-card, button, a.btn, select, input[type=text],input[type=email],input[type=tel]')) {
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

const T = { fi: { notChosen: 'valitsematta', honey: 'Hunajahoito', birch: 'Vihtahoito', salt: 'Suolahoito', req: 'Valitse hoito.' }, en: { notChosen: 'not chosen', honey: 'Honey treatment', birch: 'Birch whisk treatment', salt: 'Salt treatment', req: 'Choose a treatment.' } };

// ======================= 1) Päivänäkymä ja varauslista: hoito näkyy, "valitsematta" vanhalla varauksella =======================
for (const lang of ['fi', 'en']) for (const w of WIDTHS) {
  const page = await newPage(w, lang, `paiva-${lang}-${w}`);
  await goto(page, `/admin/?mock=1&lang=${lang}#/`);
  await page.waitForSelector('[data-testid=slot] [data-testid=opt-badge]');
  const texts = await page.$$eval('[data-testid=slot] [data-testid=opt-badge]', (els) => els.map((e) => e.textContent));
  expect(texts.includes(T[lang].honey), `päivä ${lang} ${w}: hunajahoito näkyy (${texts})`);
  expect(texts.includes(T[lang].notChosen), `päivä ${lang} ${w}: valitsematta näkyy (${texts})`);
  expect(texts.length === 2, `päivä ${lang} ${w}: vain hoitovarauksilla merkki (${texts.length}; rituaalilla ei)`);
  await layout(page, '[data-testid=slot]', `päivä ${lang} ${w}`);
  if (lang === 'fi' && (w === 390 || w === 1280)) await page.screenshot({ path: join(SHOT, `admin-${w}-paivanakyma.png`), fullPage: true });
  await goto(page, `/admin/?mock=1&lang=${lang}#/varaukset`);
  await page.waitForSelector('.rescard [data-testid=opt-badge]');
  const lt = await page.$$eval('.rescard [data-testid=opt-badge]', (els) => els.map((e) => e.textContent));
  expect(lt.length === 4 && lt.includes(T[lang].notChosen) && lt.includes(T[lang].salt), `varaukset ${lang} ${w}: merkit (${lt})`);
  await layout(page, '#view', `varaukset ${lang} ${w}`);
  if (lang === 'fi' && (w === 390 || w === 1280)) await page.screenshot({ path: join(SHOT, `admin-${w}-varaukset.png`), fullPage: true });
  await page.ctx.close();
}

// ======================= 2) Varauksen tiedot: näytä, vaihda, ilmoita asiakkaalle =======================
for (const lang of ['fi', 'en']) {
  const w = lang === 'fi' ? 390 : 1280;
  const page = await newPage(w, lang, `tiedot-${lang}`);
  await goto(page, `/admin/?mock=1&lang=${lang}#/varaukset`);
  await page.waitForSelector('.rescard');
  // vanha varaus ilman valintaa (Eero, 18:00)
  const card = page.locator('.rescard', { hasText: 'Eero Esimerkki' }); await card.click();
  await page.waitForSelector('[data-testid=option-box]:not([hidden]) [data-testid=admin-option-picker]');
  expect((await page.textContent('[data-testid=res-option]')).includes(T[lang].notChosen), `tiedot ${lang}: kenttä näyttää valitsematta`);
  expect(await page.isVisible('[data-testid=option-missing-hint]'), `tiedot ${lang}: kehote valita hoito`);
  expect(await page.locator('[data-testid=option-save]').isHidden(), `tiedot ${lang}: tallennus piilossa ennen valintaa`);
  await layout(page, '[data-testid=option-box]', `tiedot ${lang} ${w}`);
  if (lang === 'fi') await page.screenshot({ path: join(SHOT, `admin-${w}-varauksen-tiedot-valitsematta.png`), fullPage: false });
  await page.click(`[data-testid=admin-option-picker] label.srcopt:has-text("${T[lang].birch}")`); await settle(page);
  expect(await page.locator('[data-testid=option-save]').isVisible(), `tiedot ${lang}: tallennus näkyy valinnan jälkeen`);
  await page.check('[data-testid=option-notify]');
  await page.click('[data-testid=option-save]'); await settle(page); await page.waitForSelector('dialog', { state: 'detached' });
  const sc = await calls(page, 'admin_set_reservation_option');
  expect(sc.length === 1 && sc[0].p_option_code === 'vihtahoito' && sc[0].p_notify === true && typeof sc[0].p_reservation_id === 'number', `tiedot ${lang}: admin_set_reservation_option args ${JSON.stringify(sc)}`);
  await page.waitForSelector('.rescard [data-testid=opt-badge]'); await settle(page);
  const lt = await page.$$eval('.rescard [data-testid=opt-badge]', (els) => els.map((e) => e.textContent));
  expect(lt.includes(T[lang].birch) && lt.filter((x) => x === T[lang].notChosen).length === 1, `tiedot ${lang}: lista päivittyi (${lt})`);
  // olemassa oleva valinta: nykyinen näkyy, vaihto Suolahoitoon ilman ilmoitusta
  await page.locator('.rescard', { hasText: 'Aino Testaaja' }).first().click();
  await page.waitForSelector('[data-testid=option-current]');
  expect((await page.textContent('[data-testid=option-current]')) === T[lang].honey, `tiedot ${lang}: nykyinen valinta`);
  await page.click(`[data-testid=admin-option-picker] label.srcopt:has-text("${T[lang].salt}")`); await page.click('[data-testid=option-save]'); await page.waitForSelector('dialog', { state: 'detached' });
  const sc2 = await calls(page, 'admin_set_reservation_option');
  expect(sc2.length === 2 && sc2[1].p_option_code === 'suolahoito' && sc2[1].p_notify === false, `tiedot ${lang}: toinen vaihto ilman ilmoitusta ${JSON.stringify(sc2)}`);
  // rituaalilla ei valintaa
  await page.locator('.rescard', { hasText: 'Helmi Hiljainen' }).click(); await page.waitForSelector('dialog .kv');
  expect((await page.$('[data-testid=option-box]:not([hidden])')) === null, `tiedot ${lang}: rituaalilla ei hoitovalintaa`);
  await page.ctx.close();
}

// ======================= 3) Uusi varaus (resurssivaraus): valitsin pakollinen, p_option_code mukaan =======================
for (const lang of ['fi', 'en']) {
  const w = lang === 'fi' ? 390 : 1280;
  const page = await newPage(w, lang, `uusi-${lang}`);
  await goto(page, `/admin/?mock=1&lang=${lang}#/uusi?tyyppi=resurssi`);
  await page.waitForSelector('[data-testid=resource-booking-form]');
  await page.selectOption('select[name=product]', '10'); await settle(page);
  expect(await page.isVisible('[data-testid=booking-option] [data-testid=admin-option-picker]'), `uusi ${lang}: valitsin näkyy Saunahoidolle`);
  expect((await page.textContent('[data-testid=booking-option] legend')).includes('*'), `uusi ${lang}: pakollisuus merkitty`);
  expect((await page.$$('[data-testid=booking-option] input[type=radio]')).length === 4 && (await page.$$('[data-testid=booking-option] input:checked')).length === 0, `uusi ${lang}: 4 vaihtoehtoa, ei esivalintaa`);
  await page.fill('input[name=cname]', 'Testi Asiakas'); await page.fill('input[name=cemail]', 'testi@example.com');
  await page.fill('input[name=time]', '19:00'); await page.fill('input[name=date]', new Date(Date.now() + 5 * 864e5).toLocaleDateString('sv-SE', { timeZone: TZ }));
  await layout(page, '[data-testid=booking-option]', `uusi ${lang} ${w}`);
  if (lang === 'fi') await page.screenshot({ path: join(SHOT, `admin-${w}-uusi-varaus-valitsin.png`), fullPage: true });
  await page.click('[data-testid=resource-booking-form] button[type=submit]'); await settle(page);
  expect((await page.textContent('.err[role=alert]:not([hidden])')) === T[lang].req, `uusi ${lang}: pakollinen valinta estää luonnin: ${await page.textContent('.nbform .err').catch(() => '')}`);
  expect((await calls(page, 'admin_create_resource_booking')).length === 0, `uusi ${lang}: RPC:tä ei kutsuttu ilman valintaa`);
  await page.click(`[data-testid=booking-option] label.srcopt:has-text("${T[lang].birch}")`); await page.click('[data-testid=resource-booking-form] button[type=submit]'); await page.waitForSelector('.ok-box');
  const cb = await calls(page, 'admin_create_resource_booking');
  expect(cb.length === 1 && cb[0].p_option_code === 'vihtahoito' && cb[0].p_product_id === 10, `uusi ${lang}: p_option_code ${JSON.stringify(cb.map((x) => x.p_option_code))}`);
  expect((await page.textContent('.ok-box')).includes(T[lang].birch), `uusi ${lang}: luotu varaus näyttää hoidon`);
  // toinen tuote ilman vaihtoehtoja: valitsin piiloon, p_option_code ei mukaan
  await page.selectOption('select[name=product]', '8'); await settle(page);
  expect(!(await page.isVisible('[data-testid=booking-option]')), `uusi ${lang}: rituaalilla ei valitsinta`);
  await page.ctx.close();
}

// ======================= 4) Tuotevalinnat (Tuotteet-sivu): hallinta + muistutus päivänäkymässä =======================
for (const lang of ['fi', 'en']) {
  const w = lang === 'fi' ? 390 : 1280;
  const page = await newPage(w, lang, `hallinta-${lang}`);
  await goto(page, `/admin/?mock=1&lang=${lang}#/`);
  await page.waitForSelector('[data-testid=opt-reminder]');
  expect(/[1-9]/.test(await page.textContent('[data-testid=opt-reminder]')), `muistutus ${lang}: varauksia ilman valintaa: ${await page.textContent('[data-testid=opt-reminder]')}`);
  await layout(page, '[data-testid=opt-reminder]', `muistutus ${lang} ${w}`);
  await goto(page, `/admin/?mock=1&lang=${lang}#/tuotteet`);
  await page.waitForSelector('[data-testid=option-product]');
  expect((await page.$$('[data-testid=option-product] .optitem')).length === 4, `hallinta ${lang}: 4 vaihtoehtoa`);
  await layout(page, '[data-testid=product-options]', `hallinta ${lang} ${w}`);
  if (lang === 'fi') await page.screenshot({ path: join(SHOT, `admin-${w}-tuotevalinnat.png`), fullPage: true });
  // virheellinen koodi estetään ennen RPC:tä
  await page.click('[data-testid=option-add]'); await page.waitForSelector('[data-testid=option-form]');
  await page.fill('[data-testid=option-form] input[name=code]', 'Väärä koodi'); await page.fill('[data-testid=option-form] input[name=name]', 'Kivihoito');
  await page.click('[data-testid=option-form] button[type=submit]'); await settle(page);
  expect(await page.isVisible('[data-testid=option-form-error]'), `hallinta ${lang}: virheellinen koodi estetään`);
  expect((await calls(page, 'admin_upsert_product_option')).length === 0, `hallinta ${lang}: RPC:tä ei kutsuttu virheellisellä koodilla`);
  await layout(page, 'dialog.dlg', `lomake ${lang} ${w}`);
  if (lang === 'fi') await page.screenshot({ path: join(SHOT, `admin-${w}-tuotevalinnat-lomake.png`) });
  await page.fill('[data-testid=option-form] input[name=code]', 'kivihoito'); await page.fill('[data-testid=option-form] input[name=name_en]', 'Stone treatment');
  await page.click('[data-testid=option-form] button[type=submit]'); await page.waitForSelector('dialog', { state: 'detached' }); await settle(page);
  const up = await calls(page, 'admin_upsert_product_option');
  expect(up.length === 1 && up[0].p_code === 'kivihoito' && up[0].p_name === 'Kivihoito' && up[0].p_product_id === 10 && up[0].p_active === true, `hallinta ${lang}: upsert args ${JSON.stringify(up)}`);
  expect((await page.$$('[data-testid=option-product] .optitem')).length === 5, `hallinta ${lang}: uusi vaihtoehto listalla`);
  // passivointi
  await page.click('.optitem[data-code=turvehoito]'); await page.waitForSelector('[data-testid=option-form]');
  expect(await page.isDisabled('[data-testid=option-form] input[name=code]'), `hallinta ${lang}: koodia ei voi vaihtaa`);
  await page.uncheck('[data-testid=option-form] input[name=active]'); await page.click('[data-testid=option-form] button[type=submit]'); await page.waitForSelector('dialog', { state: 'detached' }); await settle(page);
  expect((await page.getAttribute('.optitem[data-code=turvehoito]', 'class')).includes('off'), `hallinta ${lang}: passivoitu näkyy`);
  // asetukset: pakollisuus pois
  await page.click('[data-testid=option-settings]'); await page.waitForSelector('[data-testid=option-settings-form]');
  await page.uncheck('[data-testid=option-settings-form] input[name=required]'); await page.click('[data-testid=option-settings-form] button[type=submit]'); await page.waitForSelector('dialog', { state: 'detached' }); await settle(page);
  const se = await calls(page, 'admin_set_product_option_settings');
  expect(se.length === 1 && se[0].p_required === false && se[0].p_product_id === 10, `hallinta ${lang}: asetukset ${JSON.stringify(se)}`);
  // ilman catalog.edit -oikeutta vain luku
  await page.ctx.close();
}

await browser.close(); server.close();
if (problems.length) { console.error(`EPÄONNISTUI (${problems.length} ongelmaa, ${checks} tarkistusta):\n- ` + [...new Set(problems)].join('\n- ')); process.exit(1); }
console.log(`OK: ${checks} tarkistusta, kuvat: ${SHOT}`);
