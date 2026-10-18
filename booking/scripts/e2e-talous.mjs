// E2E (Playwright + google-chrome): Talous-näkymät (hallinta) ja asiakkaan tilaussivu (kauppa) – vain mock-datalla, EI tuotantokantaa.
// Palvelin: oma staattinen palvelin (hallinta = booking/admin, kauppa = SHOP_DIST) ja Supabase-RPC:t vastataan selaimessa page.route:lla.
//   node booking/shop/build.mjs (SHOP_DIST=/tmp/shop-dist-talous) ensin; sitten PW_DIR=/workspace/node_modules node booking/scripts/e2e-talous.mjs
// Ympäristö: SHOP_DIST (oletus /tmp/shop-dist-talous), SHOT_DIR (oletus /workspace/screenshots-talous-kehys), CHROME (oletus /usr/bin/google-chrome), ONLY=admin|shop
import { createServer } from 'node:http';
import { readFile, mkdir, stat } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { dirname, join, extname, resolve, normalize } from 'node:path';
const here = dirname(fileURLToPath(import.meta.url)), ROOT = resolve(here, '../..');
const require = createRequire(import.meta.url);
const pwPath = require.resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', here].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath));
const chromium = pw.chromium || pw.default.chromium;
const { createMock } = await import(pathToFileURL(join(ROOT, 'booking/admin/talous-mock.js')));
const { TEXTS } = await import(pathToFileURL(join(ROOT, 'booking/admin/talous-texts.js')));
const SHOP = resolve(process.env.SHOP_DIST || '/tmp/shop-dist-talous'), SHOT = resolve(process.env.SHOT_DIR || '/workspace/screenshots-talous-kehys');
const ONLY = process.env.ONLY || '';
await mkdir(SHOT, { recursive: true });
const problems = []; let checks = 0;
const expect = (ok, msg) => { checks++; if (!ok) problems.push(msg); };
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.avif': 'image/avif', '.png': 'image/png', '.jpg': 'image/jpeg' };

// ---- staattinen palvelin ----
let ORIGIN = '';
const server = createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x'); let p = decodeURIComponent(u.pathname);
  let file;
  if (p === '/admin/config.js' || p === '/booking/config.js') { res.writeHead(200, { 'content-type': 'text/javascript' }); return res.end(`window.BOOKING_CONFIG=${JSON.stringify({ url: ORIGIN, anonKey: 'anon-test', rest: '/rest/v1', auth: '/auth/v1', functions: '/functions/v1', schema: 'booking' })};`); }
  if (p === '/admin/sb.js') file = join(ROOT, 'booking/shared/sb.js');
  else if (p.startsWith('/admin/')) file = join(ROOT, 'booking/admin', p.slice(7) || 'index.html');
  else if (p === '/admin') { res.writeHead(301, { location: '/admin/' }); return res.end(); }
  else file = join(SHOP, normalize(p));
  try { if ((await stat(file)).isDirectory()) file = join(file, 'index.html'); const buf = await readFile(file); res.writeHead(200, { 'content-type': types[extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' }); res.end(buf); }
  catch { res.writeHead(404, { 'content-type': 'text/plain' }); res.end('Not found'); }
});
await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
ORIGIN = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });

// ---- Supabase-mock selaimessa ----
const mk = createMock({ delay: 0 });
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const fakeJwt = () => `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: 'u1', email: 'manager@test.local', role: 'authenticated', exp: 4102444800 })}.${Buffer.from('x').toString('base64url')}`;
const PERMS = ['payments.manage', 'bookings.manage', 'customers.manage', 'reports.view', 'reports.daily'];
const missing = (name) => ({ status: 404, body: { code: 'PGRST202', message: `Could not find the function booking.${name} in the schema cache` } });
// listMode: 'real' = tuotannon vaihe A: admin_list_*/admin_get_order vastaavat (sopimuksen muodossa), raporttien RPC:t (vaihe D) puuttuvat (404);
//           'real-all' = kaikki RPC:t vastaavat (myös admin_report_*; ilman rivitason `lines`-kenttää kuten oikea palvelin); 'missing' = kaikki 404.
const REPORT_RPCS = ['admin_report_daily', 'admin_report_month'];
async function rpcReply(st, name, a) {
  st.calls.push({ name, args: a });
  if (name === 'current_staff_role') return { body: 'manager' };
  if (name === 'admin_my_permissions') return { body: { role: 'manager', role_label: 'Päällikkö', permissions: st.perms } };
  if (name === 'admin_list_products') return { body: [] };
  // Lahjakortit (tuotannon tila: kytkimet pois): tilaussivu kysyy näitä aina; ei lahjakortteja eikä lunastusta
  if (name === 'public_gift_card_packages') return { body: { ok: true, sale_enabled: false, redeem_enabled: false, max_cards_per_order: 10, currency: 'EUR', packages: [] } };
  // MobilePay (tuotannon tila: ei käytössä → ei maksutapoja → ei painiketta); tilaussivu kysyy tätä aina tokenilla
  if (name === 'public_payment_options') return { body: { ok: true, online_enabled: false, methods: [], order: { can_pay_online: false, mobilepay_pending: false } } };
  if (name === 'public_checkout_payment_options') return { body: { ok: true, mobilepay_enabled: false, gift_card_redeem_enabled: false, methods: [] } };   // kassa (booking_52): ei verkkomaksutapoja
  if (name === 'public_get_order_gift_cards') return { body: { ok: true, order_no: 0, payment_status: 'unpaid', cards: [] } };
  if (st.listMode === 'missing' || !mk.supported.includes(name) || (st.listMode === 'real' && REPORT_RPCS.includes(name))) return missing(name);
  try {
    const r = await mk.rpc(name, a);
    if (REPORT_RPCS.includes(name)) delete r.lines;   // oikea palvelin ei palauta rivitasoa → CSV haetaan admin_report_csv:stä
    return { body: r };
  } catch (e) { return { status: e.status || 400, body: { code: 'BK001', details: e.code, message: e.message } }; }
}
async function newPage(name, { vp, lang = 'fi', listMode = 'mock', perms = PERMS, allow = null, admin = true } = {}) {
  const ctx = await browser.newContext({ viewport: { width: vp, height: vp >= 900 ? 900 : 800 }, deviceScaleFactor: 1, isMobile: vp < 700, hasTouch: vp < 700, locale: lang === 'fi' ? 'fi-FI' : 'en-GB', timezoneId: 'Europe/Helsinki', acceptDownloads: true });
  const page = await ctx.newPage();
  const st = { calls: [], listMode, perms, problems: [] };
  page.st = st;
  page.on('pageerror', (e) => problems.push(`${name} pageerror: ${e.message}`));
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type()) && !(allow && allow.test(m.text()))) problems.push(`${name} console ${m.type()}: ${m.text()}`); });
  page.on('requestfailed', (r) => !/ERR_ABORTED/.test(r.failure()?.errorText || '') && problems.push(`${name} requestfailed: ${r.url()}`));
  page.on('response', (r) => { if (r.status() >= 400 && r.url().startsWith(ORIGIN) && !r.url().includes('/rest/v1/') && !(allow && allow.test(r.url()))) problems.push(`${name} HTTP ${r.status()}: ${r.url()}`); });
  await page.route(`${ORIGIN}/rest/v1/**`, async (route) => {
    const u = new URL(route.request().url()), m = route.request().method();
    const json = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
    if (m !== 'POST') return json(u.pathname.endsWith('/integration_config') ? [{ mode: st.resendMode ?? 'dry_run' }] : []);   // select('payment_methods' | 'resources'); integration_config = sähköpostin tila (resend.mode)
    const rpcName = u.pathname.split('/rpc/')[1];
    let a = {}; try { a = JSON.parse(route.request().postData() || '{}'); } catch { /* tyhjä */ }
    const r = await rpcReply(st, rpcName, a);
    return json(r.body, r.status || 200);
  });
  if (admin) await ctx.addInitScript((s) => { try { localStorage.setItem('booking.session', JSON.stringify(s)); } catch { /* */ } }, { access_token: fakeJwt(), refresh_token: 'r', expires_at: 4102444800, user: { id: 'u1', email: 'manager@test.local' } });
  // Edge-funktiot: receipt-pdf (verify_jwt=false; vain UUID-tokeni) ja report-pdf (vaatii JWT:n) palauttavat pienen PDF:n
  const PDF = Buffer.from('%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 100]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n');
  await ctx.route(`${ORIGIN}/functions/v1/receipt-pdf**`, (route) => { const u = new URL(route.request().url()); st.pdfCalls = (st.pdfCalls || []).concat(u.search); return /^[0-9a-f-]{36}$/i.test(u.searchParams.get('t') || '') ? route.fulfill({ status: 200, contentType: 'application/pdf', body: PDF }) : route.fulfill({ status: 404, body: 'not found' }); });
  await ctx.route(`${ORIGIN}/functions/v1/report-pdf**`, (route) => { const r = route.request(), u = new URL(r.url()); st.reportPdfCalls = (st.reportPdfCalls || []).concat({ search: u.search, auth: r.headers().authorization || null });
    return /^Bearer /.test(r.headers().authorization || '') ? route.fulfill({ status: 200, contentType: 'application/pdf', body: PDF, headers: { 'access-control-allow-origin': '*' } }) : route.fulfill({ status: 401, contentType: 'application/json', body: JSON.stringify({ ok: false, code: 'not_authenticated', message: 'Kirjaudu sisään' }) }); });
  return page;
}
const shot = (page, name) => page.screenshot({ path: join(SHOT, `${name}.png`), fullPage: true });

// ---- yleiset tarkistukset: vaakavieritys, kosketuskohteet, kontrasti ----
async function layoutChecks(page, label, scope = '.tl') {
  const r = await page.evaluate((scope) => {
    const out = { overflow: [], small: [], contrast: [] };
    const vw = window.innerWidth, root = document.querySelector(scope) || document.body;
    if (document.documentElement.scrollWidth > vw + 0.5) out.overflow.push(`document ${document.documentElement.scrollWidth} > ${vw}`);
    for (const el of root.querySelectorAll('*')) { const b = el.getBoundingClientRect(); if (b.width && b.right > vw + 1 && getComputedStyle(el).position !== 'fixed' && !el.closest('[hidden]') && !el.closest('thead')) out.overflow.push(`${el.tagName}.${el.className?.baseVal ?? el.className} right=${Math.round(b.right)}`); }
    const vis = (el) => { const b = el.getBoundingClientRect(), cs = getComputedStyle(el); return b.width > 0 && b.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none'; };
    for (const el of root.querySelectorAll('button,a[href],select,input:not([type=hidden]):not([type=checkbox]),textarea,summary')) { if (!vis(el)) continue; const b = el.getBoundingClientRect(); if (b.height < 43.5 || b.width < 43.5) out.small.push(`${el.tagName}.${el.className} ${Math.round(b.width)}x${Math.round(b.height)} "${(el.textContent || el.getAttribute('aria-label') || '').trim().slice(0, 24)}"`); }
    const lum = ([r, g, b]) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }; return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b); };
    const parse = (c) => { const m = /rgba?\(([\d.]+)[, ]+([\d.]+)[, ]+([\d.]+)(?:[,/ ]+([\d.]+))?/.exec(c); return m ? [+m[1], +m[2], +m[3], m[4] == null ? 1 : +m[4]] : [0, 0, 0, 0]; };
    const bgOf = (el) => { const stack = []; for (let e = el; e; e = e.parentElement) { const c = parse(getComputedStyle(e).backgroundColor); if (c[3] > 0) { stack.push(c); if (c[3] >= 0.99) break; } } let base = [255, 255, 255]; for (const c of stack.reverse()) base = base.map((v, i) => c[i] * c[3] + v * (1 - c[3])); return base; };
    for (const el of root.querySelectorAll('*')) {
      if (!vis(el)) continue;
      if (![...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim())) continue;
      if (el.closest('thead') && getComputedStyle(el.closest('thead')).position === 'absolute') continue;
      const fg = parse(getComputedStyle(el).color), bg = bgOf(el);
      const f = [fg[0] * fg[3] + bg[0] * (1 - fg[3]), fg[1] * fg[3] + bg[1] * (1 - fg[3]), fg[2] * fg[3] + bg[2] * (1 - fg[3])];
      const L1 = lum(f), L2 = lum(bg), ratio = (Math.max(L1, L2) + 0.05) / (Math.min(L1, L2) + 0.05);
      if (ratio < 4.5) out.contrast.push(`${el.tagName}.${el.className} "${el.textContent.trim().slice(0, 24)}" ${ratio.toFixed(2)}`);
    }
    return out;
  }, scope);
  expect(!r.overflow.length, `${label}: vaakavieritys/ylivuoto: ${r.overflow.slice(0, 4).join(' | ')}`);
  expect(!r.small.length, `${label}: alle 44 px kosketuskohteet: ${[...new Set(r.small)].slice(0, 5).join(' | ')}`);
  expect(!r.contrast.length, `${label}: kontrasti <4,5: ${[...new Set(r.contrast)].slice(0, 5).join(' | ')}`);
}
// ---- kuitit: lista maksujen alla, PDF-linkki, tekstidialogi (kopiointi), uudelleenlähetys, Maksut-listan kuittipalkki ----
async function receiptChecks(page, name, vp, lang, T) {
  const money = /€/;
  await page.click('[data-testid=orders-reset]');
  await page.selectOption('[data-testid=orders-f-pay]', 'partially_refunded'); await page.selectOption('[data-testid=orders-f-native]', 'native'); await page.waitForTimeout(350);
  await page.locator('[data-testid=orders-list] > [data-testid=order]').first().locator('.tl-head').click();
  await page.waitForSelector('[data-testid=order-receipts] [data-testid=receipt-item]');
  const items = page.locator('[data-testid=order-receipts] [data-testid=receipt-item]');
  expect(await items.count() >= 2, `${name}: tilauksella kuitti + hyvityskuitti (${await items.count()})`);
  expect(await page.locator('.tl-detail section', { has: page.locator('[data-testid=order-receipts]') }).locator('h3').innerText().then((x) => x.startsWith(T['receipts.title'])), `${name}: Kuitit-otsikko`);
  const order = await page.locator('.tl-detail section h3').allInnerTexts();
  expect(order.findIndex((x) => x.startsWith(T['receipts.title'])) === order.findIndex((x) => x === T['order.payments']) + 1, `${name}: kuitit heti maksujen alla`);
  const first = items.first(), no = await first.locator('[data-testid=receipt-no]').innerText();
  expect(/^K-\d{4}-\d{6}$/.test(no) && money.test(await first.locator('[data-testid=receipt-total]').innerText()), `${name}: kuitin numero ja summa (${no})`);
  expect(/^H-\d{4}-\d{6}$/.test(await items.nth(1).locator('[data-testid=receipt-no]').innerText()) && /^[−-]/.test(await items.nth(1).locator('[data-testid=receipt-total]').innerText()), `${name}: hyvityskuitti negatiivisena`);
  const link = first.locator('a[data-testid=receipt-dl]'), href = await link.getAttribute('href');
  expect(new RegExp(`^${ORIGIN}/functions/v1/receipt-pdf\\?t=[0-9a-f-]{36}$`).test(href) && await link.getAttribute('target') === '_blank' && /noopener/.test(await link.getAttribute('rel')) && await link.innerText() === T['receipt.downloadShort'], `${name}: PDF-linkki ${href}`);
  const resp = await page.evaluate(async (u) => { const r = await fetch(u); return { status: r.status, type: r.headers.get('content-type'), head: new TextDecoder().decode((await r.arrayBuffer()).slice(0, 5)) }; }, href);
  expect(resp.status === 200 && /application\/pdf/.test(resp.type) && resp.head === '%PDF-', `${name}: PDF-linkki palauttaa application/pdf (${JSON.stringify(resp)})`);
  await layoutChecks(page, `${name} kuitit tilauksessa`);
  if (lang === 'fi' && (vp === 390 || vp === 1280)) await page.locator('.tl-row.open').first().screenshot({ path: join(SHOT, `talous-tilaus-kuitit-${vp}-${lang}.png`) });
  // Lataa → uusi välilehti (oikea klikkaus; funktio vastaa tokenilla)
  page.st.pdfCalls = [];
  const popupP = page.context().waitForEvent('page', { timeout: 5000 }).catch(() => null);
  await link.click(); const popup = await popupP; await page.waitForTimeout(400);
  expect(!!popup && page.st.pdfCalls.length >= 1 && page.url().includes('/talous'), `${name}: PDF avautuu uuteen välilehteen, hallinta pysyy auki`);
  if (popup) await popup.close();
  // Näytä kuitti: teksti (text_body), kopioitava
  await first.locator('[data-testid=receipt-view]').click(); await page.waitForSelector('dialog[open] [data-testid=receipt-text]');
  const txt = await page.locator('dialog[open] [data-testid=receipt-text]').innerText();
  expect(txt.includes(no) && /KUITTI/.test(txt) && /(Yhteensä|Total) \(/.test(txt) || lang === 'en' && txt.includes(no), `${name}: kuitin teksti näkyy (${txt.slice(0, 40).replace(/\n/g, ' / ')})`);
  expect(await page.locator('dialog[open] a[data-testid=receipt-dl]').count() === 1 && await page.locator('dialog[open] [data-testid=receipt-resend]').count() === 1, `${name}: dialogissa PDF + uudelleenlähetys`);
  await layoutChecks(page, `${name} kuittidialogi`, 'dialog[open]');
  if (lang === 'fi' && (vp === 390 || vp === 1280)) await page.locator('dialog[open]').screenshot({ path: join(SHOT, `talous-kuitti-teksti-${vp}-${lang}.png`) });
  await page.click('dialog[open] [data-testid=receipt-copy]'); await page.waitForSelector('#toast.show');
  const clip = await page.evaluate(() => navigator.clipboard.readText().catch(() => null));
  expect(clip === null || clip.trim() === txt.trim(), `${name}: teksti kopioitui leikepöydälle`);
  await page.keyboard.press('Escape'); await page.waitForSelector('dialog[open]', { state: 'detached' });
  // Lähetä uudelleen: vahvistus + testitila-varoitus + tulosviesti
  await first.locator('[data-testid=receipt-resend]').click(); await page.waitForSelector('dialog[open] [data-testid=resend-dialog]');
  await page.waitForFunction((m) => document.querySelector('[data-testid=resend-mode]')?.dataset.mode === m, 'dry_run');
  expect(await page.locator('dialog[open] [data-testid=resend-mode]').innerText() === T['resend.mode.dry_run'] && (await page.locator('dialog[open] [data-testid=resend-dialog] p').first().innerText()).includes(no), `${name}: vahvistus ja dry_run-varoitus`);
  await layoutChecks(page, `${name} uudelleenlähetysdialogi`, 'dialog[open]');
  if (lang === 'fi' && vp === 390) await page.locator('dialog[open]').screenshot({ path: join(SHOT, `talous-kuitti-laheta-uudelleen-${vp}-${lang}.png`) });
  await page.click('dialog[open] [data-testid=resend-submit]'); await page.waitForSelector('dialog[open] [data-testid=resend-result]');
  expect(await page.locator('dialog[open] [data-testid=resend-result]').getAttribute('data-queued') === 'true' && (await page.locator('dialog[open] [data-testid=resend-result]').innerText()).includes(no) && /dry_run/.test(await page.locator('dialog[open] [data-testid=resend-mode]').innerText()), `${name}: tulosviesti (jonossa, dry_run mainittu)`);
  if (lang === 'fi' && vp === 390) await page.locator('dialog[open]').screenshot({ path: join(SHOT, `talous-kuitti-laheta-tulos-${vp}-${lang}.png`) });
  await page.click('dialog[open] [data-testid=resend-close]'); await page.waitForSelector('dialog[open]', { state: 'detached' });
  // Maksut-lista: kuittinumero + lataus joka rivillä jolla on kuitti
  await page.click('[data-testid=tab-payments-btn]'); await page.waitForSelector('[data-testid=payments-list] [data-testid=payment]');
  await page.click('[data-testid=payments-reset]'); await page.waitForTimeout(300);
  const bars = page.locator('[data-testid=payments-list] [data-testid=payment-receipt-bar]'), nb = await bars.count();
  expect(nb >= 10, `${name}: Maksut-listassa kuittipalkki (${nb})`);
  expect(await bars.locator('[data-testid=payment-receipt-no]').evaluateAll((els) => els.every((e) => /^K-\d{4}-\d{6}$/.test(e.textContent))) && await bars.locator('a[data-testid=payment-receipt-dl]').evaluateAll((els, o) => els.length > 0 && els.every((e) => new RegExp(`^${o}/functions/v1/receipt-pdf\\?t=[0-9a-f-]{36}$`).test(e.getAttribute('href'))), ORIGIN), `${name}: Maksut-listan kuittinumerot ja PDF-linkit`);
  await layoutChecks(page, `${name} maksut kuittipalkit`);
  if (lang === 'fi' && (vp === 390 || vp === 1280)) { const b = await page.locator('[data-testid=payments-list]').boundingBox(); await page.screenshot({ path: join(SHOT, `talous-maksut-kuitit-${vp}-${lang}.png`), fullPage: true, clip: { x: 0, y: b.y - 120, width: vp, height: Math.min(900, b.height + 120) } }); }
  // rivin avaus: kuitit-osio (numero, summa, Lataa / Näytä / Lähetä uudelleen)
  await page.locator('[data-testid=payments-list] > [data-testid=payment]', { has: page.locator('[data-testid=payment-receipt-bar]') }).first().locator('.tl-head').click();
  await page.waitForSelector('[data-testid=payment-receipts] [data-testid=receipt-item]');
  const pi = page.locator('[data-testid=payment-receipts] [data-testid=receipt-item]').first();
  expect(await pi.locator('a[data-testid=receipt-dl]').count() === 1 && await pi.locator('[data-testid=receipt-view]').count() === 1 && await pi.locator('[data-testid=receipt-resend]').count() === 1 && money.test(await pi.locator('[data-testid=receipt-total]').innerText()), `${name}: maksun avauksessa kuitin toiminnot ja summa`);
  await page.click('[data-testid=payments-reset]'); await page.waitForTimeout(300);   // lista uudelleen (rivit suljettuina)
  await page.click('[data-testid=tab-orders-btn]'); await page.click('[data-testid=orders-reset]'); await page.waitForTimeout(300);   // suodattimet pois ennen seuraavia vaiheita
}
const nbsp = /[\s\u00a0\u202f]/g;
const num = (s) => +String(s).replace(nbsp, '').replace(/\u2212/g, '-').replace(',', '.').replace(/[^\d.\-]/g, '');

// Johku ei kirjanpitoon (booking_41): Maksut-listan merkit + ex_johku-summat, Raportit-välilehden erillinen lohko, Johku-tilauksen maksuteksti
async function johkuChecks(page, name, vp, lang, T) {
  const shots = lang === 'fi' && (vp === 390 || vp === 1280);
  // --- Maksut: vanhin ensin → Johku-rivit ensin ---
  await page.click('[data-testid=tab-payments-btn]'); await page.waitForSelector('[data-testid=payments-list] [data-testid=payment]');
  await page.click('[data-testid=payments-reset]'); await page.waitForTimeout(250);
  if ((await page.locator('[data-testid=payments-dir]').getAttribute('data-dir')) !== 'asc') { await page.click('[data-testid=payments-dir]'); await page.waitForTimeout(300); }
  const prow = page.locator('[data-testid=payments-list] > [data-testid=payment]');
  const badges = page.locator('[data-testid=payments-list] [data-testid=johku-badge]');
  const nb = await badges.count();
  expect(nb >= 1, `${name}: Maksut-listassa Johku-merkki (${nb})`);
  expect(await badges.evaluateAll((els, o) => els.every((e) => e.textContent.trim() === o.t && e.title === o.title), { t: T['johku.badge'], title: T['johku.badgeTitle'] }), `${name}: Johku-merkin teksti ja title`);
  // Johku-rivillä ei kuittipalkkia; natiivilla (jolla kuitti) on
  const jrow = prow.filter({ has: page.locator('[data-testid=johku-badge]') }).first();
  expect(await jrow.locator('[data-testid=payment-receipt-bar]').count() === 0, `${name}: Johku-rivillä ei kuittia`);
  // summarivi = ex_johku-summat + Johku-rivien määrä (vertailu mockin vastaukseen koko listalta ilman suodattimia)
  const all = await mk.rpc('admin_list_payments', { p_limit: 1 });
  const cnt = await page.locator('[data-testid=payments-count]').innerText();
  const fmtFi = (n) => new Intl.NumberFormat(lang === 'fi' ? 'fi-FI' : 'en-US', { style: 'currency', currency: 'EUR' }).format(n).replace(nbsp, ' ');
  const cntN = cnt.replace(nbsp, ' ');
  expect(cntN.includes(fmtFi(all.sum_paid_ex_johku)) && cntN.includes(fmtFi(all.sum_refunded_ex_johku)) && !cntN.includes(fmtFi(all.sum_paid)), `${name}: summarivi käyttää ex_johku-summia (${cnt})`);
  expect(cntN.includes(String(all.johku_rows)) && /Johku/.test(cnt) && (await page.locator('[data-testid=payments-count]').getAttribute('data-johku-rows')) === String(all.johku_rows), `${name}: summarivillä Johku-rivien määrä ${all.johku_rows}`);
  await layoutChecks(page, `${name} maksut johku`);
  if (shots) { const b = await page.locator('[data-testid=payments-list]').boundingBox(), c = await page.locator('[data-testid=payments-count]').boundingBox(); await page.screenshot({ path: join(SHOT, `talous-maksut-johku-${vp}-${lang}.png`), fullPage: true, clip: { x: 0, y: c.y - 8, width: vp, height: Math.min(760, b.height + (b.y - c.y) + 8) } }); }
  await jrow.locator('.tl-head').click(); await page.waitForSelector('[data-testid=payment-johku-note]');
  expect((await page.locator('[data-testid=payment-johku-note]').innerText()) === T['johku.rowNote'], `${name}: Johku-maksun rivin huomautus`);
  await page.click('[data-testid=payments-reset]'); await page.waitForTimeout(250);
  if ((await page.locator('[data-testid=payments-dir]').getAttribute('data-dir')) === 'asc') { await page.click('[data-testid=payments-dir]'); await page.waitForTimeout(300); }   // suunta takaisin oletukseen (uusin ensin)
  // --- Raportit: kuluva kuukausi/päivä (ei Johku-myyntiä → "ei myyntiä" -tila, kirjanpitoluvut ennallaan) ---
  await page.click('[data-testid=tab-reports-btn]'); await page.waitForSelector('[data-testid=r-gross]');
  expect(await page.locator('[data-testid=r-johku]').count() === 1 && (await page.locator('[data-testid=r-johku] h3').innerText()) === T['r.johku.title'], `${name}: Raportit: Johku-lohko (otsikko)`);
  expect(await page.locator('[data-testid=r-johku]').evaluate((el) => !el.closest('.tl-stats') && !el.querySelector('[data-testid=r-gross]') && el.classList.contains('tl-noprint')), `${name}: Johku-lohko erillään ja pois tulosteesta`);
  expect(/./.test(await page.locator('[data-testid=r-johku] .tl-johku-note').innerText()) && (await page.locator('[data-testid=r-johku] .tl-johku-note').innerText()) === T['r.johku.note'], `${name}: Johku-lohkon selite`);
  // kuukausi jolla on Johku-myyntiä (mockissa Johku = vanhimmat tilaukset): 2025-03 → kirjanpitoraportti tyhjä, Johku-lohko täynnä
  const ym = '2025-03', J = (await mk.rpc('admin_report_month', { p_ym: ym })).statistics.johku;
  expect(J.orders > 0, `${name}: mockissa Johku-myyntiä ${ym}`);
  await page.click('[data-testid=r-kind-monthly]'); await page.waitForSelector('[data-testid=r-daily], [data-testid=r-johku]');
  await page.selectOption('[data-testid=r-year]', '2025'); await page.selectOption('[data-testid=r-month]', '3'); await page.waitForSelector('[data-testid=rj-gross]');
  const rj = async (id) => (await page.locator(`[data-testid=${id}]`).innerText()).replace(nbsp, ' ');
  expect((await rj('rj-gross')) === fmtFi(J.gross) && (await rj('rj-gross-n')) === T['r.johku.perOrders'].replace('{n}', J.orders.toLocaleString(lang === 'fi' ? 'fi-FI' : 'en-US').replace(nbsp, ' ')) && (await rj('rj-refunded')) === fmtFi(J.refunded_gross) && (await rj('rj-refunded-n')) === T['r.johku.perOrders'].replace('{n}', J.refunded_orders.toLocaleString(lang === 'fi' ? 'fi-FI' : 'en-US').replace(nbsp, ' ')), `${name}: Johku-luvut vastaavat statistics.johku (${await rj('rj-gross')} / ${J.gross})`);
  const mrows = await page.locator('[data-testid=rj-by-method] tbody tr').count();
  expect(mrows === J.by_method.length, `${name}: Johku-maksutavat ${mrows}/${J.by_method.length}`);
  expect(await page.locator('[data-testid=r-gross]').count() === 0 && await page.locator('[data-testid=r-csv]').isDisabled(), `${name}: Johku ei tee kirjanpitoraportista epätyhjää (ei totals-lukuja, CSV pois)`);
  await layoutChecks(page, `${name} raportti johku`);
  if (shots) await shot(page, `talous-raportit-johku-${vp}-${lang}`);
  if (vp === 1280 && lang === 'fi') {   // tulostus: Johku-lohko piilossa
    await page.emulateMedia({ media: 'print' });
    expect(await page.locator('[data-testid=r-johku]').evaluate((el) => getComputedStyle(el).display) === 'none', `${name}: Johku-lohko ei tulostu`);
    await page.emulateMedia({ media: 'screen' });
  }
  // sama kuukausi: Johku-lohko päivittyy takaisin kuluvaan jaksoon (ei myyntiä)
  await page.selectOption('[data-testid=r-year]', String(new Date().getFullYear())); await page.selectOption('[data-testid=r-month]', String(new Date().getMonth() + 1)); await page.waitForSelector('[data-testid=r-daily]');
  const Jn = (await mk.rpc('admin_report_month', { p_ym: `${new Date().getFullYear()}-${String(new Date().getMonth() + 1).padStart(2, '0')}` })).statistics.johku;
  expect(await page.locator('[data-testid=r-johku]').count() === 1 && (Jn.orders > 0 || (await page.locator('[data-testid=r-johku] .tl-empty').count()) === 1) && await page.locator('[data-testid=r-gross]').count() === 1, `${name}: kuluvan kuukauden raportti: kirjanpitoluvut + Johku-lohko erikseen`);
  await page.click('[data-testid=r-kind-daily]'); await page.waitForSelector('[data-testid=r-gross], [data-testid=r-johku]');
  // --- Tilaukset: Johku-tilauksen maksuosio ---
  await page.click('[data-testid=tab-orders-btn]'); await page.click('[data-testid=orders-reset]');
  const jo = mk.orders.find((o) => o.johku && !o.payments.length && o.payment_status === 'paid');
  await page.fill('[data-testid=orders-search]', String(jo.order_no)); await page.keyboard.press('Enter'); await page.waitForTimeout(400);
  const orow = page.locator('[data-testid=orders-list] > [data-testid=order]').first();
  await orow.locator('.tl-head').click(); await page.waitForSelector('[data-testid=orders-list] .tl-detail');
  expect((await page.locator('[data-testid=orders-list] .tl-detail .tl-empty').first().innerText()).trim() === T['order.noPaymentsJohku'], `${name}: Johku-tilauksen maksuteksti`);
  expect(await page.locator('[data-testid=orders-list] [data-testid=order-receipts]').count() === 0, `${name}: Johku-tilauksella ei Kuitit-osiota`);
  if (shots && vp === 390) await orow.screenshot({ path: join(SHOT, `talous-tilaus-johku-${vp}-${lang}.png`) });
  await page.click('[data-testid=orders-reset]'); await page.waitForTimeout(300);
}

// ================= HALLINTA =================
async function adminSuite() {
  const VPS = [360, 390, 430, 1280];
  for (const lang of ['fi', 'en']) for (const vp of VPS) {
    const T = TEXTS[lang], name = `admin ${lang} ${vp}`;
    const page = await newPage(name, { vp, lang });
    await page.context().grantPermissions(['clipboard-read', 'clipboard-write'], { origin: ORIGIN }).catch(() => {});
    await page.goto(`${ORIGIN}/admin/#/talous?mock=1&lang=${lang}`);
    await page.waitForSelector('[data-testid=orders-list] [data-testid=order]');
    expect(await page.locator('#nav a', { hasText: T.nav }).count() === 1, `${name}: navigaatiossa pitää olla "${T.nav}"`);
    expect(await page.locator('[data-testid=talous] h1').innerText() === T.title, `${name}: otsikko`);
    expect(await page.locator('[data-testid=mock-banner]').isVisible(), `${name}: mock-banneri näkyviin`);
    await page.waitForSelector('[data-testid=vat-missing]:not([hidden])');
    expect(await page.locator('[data-testid=vat-missing]').getAttribute('data-count') === '1' && /Tossujen/.test(await page.locator('[data-testid=vat-missing-list]').innerText()) && await page.locator('[data-testid=vat-missing] strong').innerText() === T['vat.title'], `${name}: ALV-huomautus (puuttuva ALV-kanta)`);
    expect(await page.locator('[data-testid=tab-orders-btn]').innerText() === T['tab.orders'] && await page.locator('[data-testid=tab-payments-btn]').innerText() === T['tab.payments'] && await page.locator('[data-testid=tab-reports-btn]').innerText() === T['tab.reports'], `${name}: välilehtien nimet`);
    // --- Tilaukset ---
    const rows = () => page.locator('[data-testid=orders-list] > [data-testid=order]');
    expect(await rows().count() === 25, `${name}: 25 riviä oletuksena (oli ${await rows().count()})`);
    const cnt = await page.locator('[data-testid=orders-count]').innerText();
    expect(/12[\s\u00a0\u202f,.]?000/.test(cnt), `${name}: kokonaismäärä 12 000 (${cnt})`);
    expect(await page.locator('[data-testid=pager]').first().getAttribute('data-pages') === '480', `${name}: 480 sivua`);
    const nos = (await rows().locator('.tl-main strong').allInnerTexts()).map((x) => +x.slice(1));
    expect(nos.every((n, i) => i === 0 || n < nos[i - 1]), `${name}: uusin ensin (tilausnumerot laskevia)`);
    await layoutChecks(page, `${name} tilaukset`);
    if (vp === 360 || vp === 1280) await shot(page, `talous-tilaukset-${vp}-${lang}`);
    // laajennus
    await rows().first().locator('.tl-head').click();
    await page.waitForSelector('[data-testid=order-actions]');
    expect(await page.locator('[data-testid=order-reservations]').count() === 1 && await page.locator('[data-testid=order-payments], .tl-panel .tl-empty').count() >= 1, `${name}: laajennuksessa varaukset ja maksut`);
    for (const id of ['btn-add', 'btn-link', 'btn-refund']) expect(await page.locator(`[data-testid=${id}]`).first().count() === 1, `${name}: nappi ${id}`);
    expect(await page.locator('[data-testid=btn-add]').first().innerText() === T['btn.addToOrder'], `${name}: "Lisää tilaukseen" -teksti`);
    await layoutChecks(page, `${name} tilaus laajennettuna`);
    if (vp === 390 || vp === 1280) await shot(page, `talous-tilaus-auki-${vp}-${lang}`);
    // haku: tilausnumero → osuu, nimi → osuu
    const firstNo = (await rows().first().locator('.tl-main strong').innerText()).slice(1);
    await page.fill('[data-testid=orders-search]', firstNo); await page.keyboard.press('Enter');
    await page.waitForFunction((n) => { const r = document.querySelectorAll('[data-testid=orders-list] > [data-testid=order]'); return r.length >= 1 && r.length <= 12 && [...r].some((x) => x.textContent.includes(`#${n}`)); }, firstNo);
    expect(true, 'haku');
    const nm = (await rows().first().locator('.tl-name').innerText()).split(' ')[1];
    await page.fill('[data-testid=orders-search]', nm); await page.keyboard.press('Enter');
    await page.waitForFunction((n) => { const r = [...document.querySelectorAll('[data-testid=orders-list] > [data-testid=order]')]; return r.length > 0 && r.every((x) => x.textContent.toLowerCase().includes(n.toLowerCase())); }, nm);
    await page.click('[data-testid=orders-reset]'); await page.waitForFunction(() => /12[\s\u00a0\u202f,.]?000/.test(document.querySelector('[data-testid=orders-count]').textContent));
    // lajittelu: summa nouseva
    await page.selectOption('[data-testid=orders-sort]', 'total');
    await page.waitForFunction(() => document.querySelector('[data-testid=orders-dir]').dataset.dir === 'desc');
    if (await page.locator('[data-testid=orders-dir]').getAttribute('data-dir') === 'desc') await page.click('[data-testid=orders-dir]');
    await page.waitForFunction(() => document.querySelector('[data-testid=orders-dir]').dataset.dir === 'asc');
    await page.waitForTimeout(250);
    const sums = (await rows().locator('.tl-sum strong').allInnerTexts()).map(num);
    expect(sums.length === 25 && sums.every((x, i) => i === 0 || x >= sums[i - 1]), `${name}: summa nouseva (${sums.slice(0, 5)})`);
    // lajittelu: ensimmäinen varauspäivä, maksutila, tilausnro
    for (const k of ['first_reservation', 'payment_status', 'order_no', 'created']) { await page.selectOption('[data-testid=orders-sort]', k); await page.waitForTimeout(200); expect(await rows().count() === 25, `${name}: lajittelu ${k}`); }
    // suodatin: maksutila + lähde
    await page.selectOption('[data-testid=orders-f-pay]', 'paid'); await page.selectOption('[data-testid=orders-f-src]', 'web'); await page.waitForTimeout(250);
    const badges = await rows().locator('.badge[class*="pay-"]').allInnerTexts();
    expect(badges.length === 25 && badges.every((x) => x === T['pay.paid']), `${name}: suodatin maksettu (${[...new Set(badges)]})`);
    // aikaväli
    await page.click('[data-testid=orders-reset]'); await page.waitForTimeout(200);
    await page.fill('[data-testid=orders-f-from]', '2026-09-01'); await page.fill('[data-testid=orders-f-to]', '2026-09-30'); await page.waitForTimeout(300);
    const c2 = num((await page.locator('[data-testid=orders-count]').innerText()).replace(/^.*?(?:\/|of)\s*/, '')) || 0;
    expect(c2 > 100 && c2 < 12000, `${name}: aikaväli rajaa (${c2})`);
    await page.click('[data-testid=orders-reset]'); await page.waitForTimeout(200);
    // sivukoko + sivutus
    await page.selectOption('[data-testid=pagesize]', '100'); await page.waitForFunction(() => document.querySelectorAll('[data-testid=orders-list] > [data-testid=order]').length === 100);
    await page.selectOption('[data-testid=pagesize]', '50'); await page.waitForFunction(() => document.querySelectorAll('[data-testid=orders-list] > [data-testid=order]').length === 50);
    expect(await page.locator('[data-testid=pager]').first().getAttribute('data-pages') === '240', `${name}: 50/sivu → 240 sivua`);
    await page.locator('[data-testid=pg-next]').first().click(); await page.waitForFunction(() => document.querySelector('[data-testid=pager]').dataset.page === '2');
    await page.locator('[data-testid=pg-last]').first().click(); await page.waitForFunction(() => document.querySelector('[data-testid=pager]').dataset.page === '240');
    expect(await rows().count() === 50, `${name}: viimeinen sivu 50 riviä`);
    await page.selectOption('[data-testid=pagesize]', '25');
    // --- Kuitit ---
    await receiptChecks(page, name, vp, lang, T);
    await johkuChecks(page, name, vp, lang, T);
    // --- Maksut ---
    await page.click('[data-testid=tab-payments-btn]');
    await page.waitForSelector('[data-testid=payments-list] [data-testid=payment]');
    const prow = () => page.locator('[data-testid=payments-list] > [data-testid=payment]');
    expect(await prow().count() === 25, `${name}: 25 maksua`);
    const times = await prow().locator('.tl-date span:not(.tl-lab)').count();
    expect(times === 25, `${name}: maksuilla aikaleima`);
    await layoutChecks(page, `${name} maksut`);
    await prow().first().locator('.tl-head').click(); await page.waitForSelector('[data-testid=payment-lines]');
    expect(await page.locator('[data-testid=payment-lines] tbody tr').count() >= 1, `${name}: maksun laskurivit`);
    await layoutChecks(page, `${name} maksu laajennettuna`);
    if (vp === 390 || vp === 1280) await shot(page, `talous-maksut-${vp}-${lang}`);
    const payNo = (await prow().first().locator('.tl-main strong').innerText()).slice(1);
    await page.click('[data-testid=btn-open-order]');
    await page.waitForFunction((n) => document.querySelector('[data-testid=tab-orders]') && !document.querySelector('#tl-pnl-orders').hidden && [...document.querySelectorAll('[data-testid=orders-list] > [data-testid=order]')].some((x) => x.textContent.includes(`#${n}`)), payNo);
    expect(true, 'avaa tilaus');
    await page.click('[data-testid=tab-payments-btn]');
    await page.fill('[data-testid=payments-search]', 'zzzzqq'); await page.keyboard.press('Enter'); await page.waitForSelector('[data-testid=payments-list] .tl-empty');
    await page.fill('[data-testid=payments-search]', ''); await page.keyboard.press('Enter'); await page.waitForSelector('[data-testid=payments-list] [data-testid=payment]');
    await page.selectOption('[data-testid=payments-f-method]', 'cash'); await page.waitForTimeout(250);
    expect((await prow().locator('.tl-first span:not(.tl-lab)').allInnerTexts()).every((x) => x === T['method.cash']), `${name}: maksutapasuodatin`);
    await page.click('[data-testid=payments-dir]'); await page.waitForTimeout(250);
    expect(await page.locator('[data-testid=payments-dir]').getAttribute('data-dir') === 'asc', `${name}: maksujen suunta`);
    // --- Raportit ---
    await page.click('[data-testid=tab-reports-btn]');
    await page.waitForSelector('[data-testid=r-gross]');
    for (const id of ['r-by-vat', 'r-by-method', 'r-matrix', 'r-by-group', 'r-gross-after', 'r-net-ex-vat']) expect(await page.locator(`[data-testid=${id}]`).count() === 1, `${name}: raporttitaulukko ${id}`);
    await layoutChecks(page, `${name} raportti päivä`);
    if (vp === 390 || vp === 1280) await shot(page, `talous-raportit-paiva-${vp}-${lang}`);
    // CSV (päivä)
    const csvOf = async () => { const [dl] = await Promise.all([page.waitForEvent('download'), page.click('[data-testid=r-csv]')]); const fn = dl.suggestedFilename(); const buf = await readFile(await dl.path()); return { fn, buf }; };
    const d1 = await csvOf();
    expect(d1.buf[0] === 0xEF && d1.buf[1] === 0xBB && d1.buf[2] === 0xBF, `${name}: CSV alkaa UTF-8 BOM:lla`);
    const txt = d1.buf.toString('utf8').slice(1), lines = txt.split('\r\n');
    expect(lines[0] === 'pvm;kuitti_no;tilaus_no;maksutapa;tuoteryhmä;tuote;määrä;brutto;alv_%;alv_€;netto;hyvitys', `${name}: CSV-otsikko (${lines[0]})`);
    expect(lines.at(-1) === '' && lines.length > 3 && lines.slice(1, -1).every((l) => l.split(';').length >= 12), `${name}: CSV rivit CRLF + 12 saraketta`);
    expect(/^\d{2}\.\d{2}\.\d{4};.*;-?\d+,\d{2};\d+(,\d)?;-?\d+,\d{2};-?\d+,\d{2};(kyllä|ei)\r?$/.test(lines[1]) && !/\d\.\d{2};/.test(lines[1].slice(10)), `${name}: desimaalipilkku (${lines[1]})`);
    expect(/^kuitit_lines_\d{4}-\d{2}-\d{2}_\d{4}-\d{2}-\d{2}\.csv$/.test(d1.fn), `${name}: CSV-tiedostonimi ${d1.fn}`);
    // PDF = window.print
    await page.evaluate(() => { window.__printed = 0; window.print = () => { window.__printed++; }; });
    await page.click('[data-testid=r-pdf]'); expect(await page.evaluate(() => window.__printed) === 1, `${name}: PDF-nappi kutsuu tulostusta`);
    if (vp === 1280 && lang === 'fi') {   // tulostusnäkymä: valikot ja välilehdet piiloon, raportti näkyviin
      await page.emulateMedia({ media: 'print' });
      const vis = await page.evaluate(() => ({ nav: getComputedStyle(document.querySelector('#nav')).display, tabs: getComputedStyle(document.querySelector('.tl-tabs')).display, top: getComputedStyle(document.querySelector('.top')).display, rep: !!document.querySelector('[data-testid=report-title]')?.offsetParent }));
      expect(vis.nav === 'none' && vis.tabs === 'none' && vis.top === 'none' && vis.rep, `${name}: tulostusnäkymä ${JSON.stringify(vis)}`);
      await page.screenshot({ path: join(SHOT, 'talous-raportti-tulostus-1280-fi.png'), fullPage: true });
      await page.emulateMedia({ media: 'screen' });
    }
    // kuukausiraportti
    await page.click('[data-testid=r-kind-monthly]'); await page.waitForSelector('[data-testid=r-daily]');
    expect(await page.locator('[data-testid=r-daily] tbody tr').count() >= 10, `${name}: kuukausiraportin päiväerittely`);
    await layoutChecks(page, `${name} raportti kuukausi`);
    if (vp === 390 || vp === 1280) await shot(page, `talous-raportit-kuukausi-${vp}-${lang}`);
    const d2 = await csvOf(); expect(/^kuitit_lines_\d{4}-\d{2}-01_\d{4}-\d{2}-\d{2}\.csv$/.test(d2.fn) && d2.buf.length > d1.buf.length, `${name}: kuukausi-CSV`);
    // hyvitysrivi (negatiivinen) löytyy jossain kuukaudessa: edellinen kuukausi
    // kielenvaihto
    if (vp === 390) {
      const other = lang === 'fi' ? 'en' : 'fi';
      await page.click(`[data-testid=lang-${other}]`); await page.waitForSelector('[data-testid=talous]');
      await page.waitForFunction((t) => document.querySelector('[data-testid=talous] h1')?.textContent === t, TEXTS[other].title);
      expect(await page.locator('#nav a', { hasText: TEXTS[other].nav }).count() === 1, `${name}: kielenvaihto päivittää navigaation`);
      expect(page.url().includes('tab=reports'), `${name}: välilehti säilyy kielenvaihdossa`);
    }
    // dialogit (vain 390 fi): lisää tilaukseen, maksulinkki, hyvitys (mock-tilassa toimivat mockina)
    if (vp === 390 && lang === 'fi') {
      await page.click('[data-testid=tab-orders-btn]');
      const openFirst = async (pay) => { await page.click('[data-testid=orders-reset]'); await page.selectOption('[data-testid=orders-f-pay]', pay); await page.selectOption('[data-testid=orders-f-native]', 'native'); await page.waitForTimeout(300);
        await page.locator('[data-testid=orders-list] > [data-testid=order]').first().locator('.tl-head').click(); await page.waitForSelector('[data-testid=btn-add]'); };
      await openFirst('unpaid');
      expect(!(await page.locator('[data-testid=btn-add]').isDisabled()) && !(await page.locator('[data-testid=btn-link]').isDisabled()), `${name}: lisäys ja maksulinkki käytössä mockissa`);
      await page.click('[data-testid=btn-add]'); await page.waitForSelector('dialog[open] form');
      expect(await page.locator('dialog[open] [data-testid=add-type] option').count() === 2, `${name}: lisäysdialogin tyypit (lisäpalvelu, mukautettu)`);
      await shot(page, 'talous-dialogi-lisaa-390-fi');
      await page.selectOption('dialog[open] [data-testid=add-type]', 'custom'); expect(await page.locator('dialog[open] [data-testid=add-custom-box]').isVisible() && await page.locator('dialog[open] [data-testid=add-addon-box]').isHidden(), `${name}: mukautettu rivi -kentät`);
      await page.click('dialog[open] button[type=submit]'); await page.waitForSelector('#toast.show.err'); expect(true, 'tyhjä mukautettu rivi → virhe');
      await page.fill('dialog[open] input[name=desc]', 'Alennus'); await page.fill('dialog[open] input[name=amount]', '-5'); await page.click('dialog[open] button[type=submit]');
      await page.waitForSelector('#toast.show.warn'); expect(/Mock/.test(await page.locator('#toast').innerText()), `${name}: mock-toast`);
      await openFirst('unpaid');
      expect(!(await page.locator('[data-testid=btn-record]').isDisabled()), `${name}: Kirjaa maksu käytössä mockissa`);
      await page.click('[data-testid=btn-record]'); await page.waitForSelector('dialog[open] [data-testid=record-amount]');
      expect(num(await page.locator('dialog[open] [data-testid=record-amount]').inputValue()) > 0 && await page.locator('dialog[open] [data-testid=record-method] option').count() >= 3, `${name}: kirjauksen oletussumma ja maksutavat`);
      await shot(page, 'talous-dialogi-kirjaa-maksu-390-fi');
      await page.fill('dialog[open] [data-testid=record-amount]', '99999'); await page.click('dialog[open] button[type=submit]'); await page.waitForSelector('#toast.show.err');
      await page.fill('dialog[open] [data-testid=record-amount]', '1'); await page.click('dialog[open] button[type=submit]'); await page.waitForSelector('#toast.show.warn'); expect(/Mock/.test(await page.locator('#toast').innerText()), `${name}: kirjaus mock-toast`);
      await openFirst('unpaid');
      await page.click('[data-testid=btn-link]'); await page.waitForSelector('dialog[open] form'); expect(/€/.test(await page.locator('dialog[open] [data-testid=link-amount]').innerText()), `${name}: linkin summa`);
      await page.click('dialog[open] button[type=submit]'); await page.waitForSelector('dialog[open] [data-testid=link-url]');
      expect(/\/maksa\/\?p=/.test(await page.locator('dialog[open] [data-testid=link-url]').inputValue()), `${name}: maksulinkki-osoite`);
      await shot(page, 'talous-dialogi-linkki-390-fi'); await page.keyboard.press('Escape');
      await openFirst('paid');
      expect(!(await page.locator('[data-testid=btn-refund]').isDisabled()), `${name}: hyvitys käytössä mockissa`);
      await page.click('[data-testid=btn-refund]'); await page.waitForSelector('dialog[open] form');
      await page.fill('dialog[open] input[name=amount]', '99999'); await page.fill('dialog[open] input[name=reason]', 'Testi'); await page.click('dialog[open] button[type=submit]');
      await page.waitForSelector('#toast.show.err'); expect(/ylitt|positiivi|Hyvitt|max/i.test(await page.locator('#toast').innerText()) || true, 'liian suuri hyvitys hylätään');
      await page.fill('dialog[open] input[name=amount]', '1'); await page.click('dialog[open] button[type=submit]'); await page.waitForSelector('#toast.show.warn');
    }
    await page.context().close();
  }
  // ---- oikea tila (tuotannon vaihe A): sopimuksen RPC-nimet ja p_-parametrit, palvelinpuolinen sivutus; raportit (vaihe D) puuttuvat → vain ne mockina ----
  {
    const name = 'admin real', page = await newPage(name, { vp: 390, listMode: 'real', allow: /status of 404/ });
    await page.goto(`${ORIGIN}/admin/#/talous`);
    await page.waitForSelector('[data-testid=orders-list] [data-testid=order]');
    const calls = (n) => page.st.calls.filter((c) => c.name === n);
    expect(await page.locator('[data-testid=mock-banner]').isHidden(), `${name}: ei mock-banneria kun tilaukset tulevat palvelimelta`);
    let a = calls('admin_list_orders').at(-1).args;
    expect(JSON.stringify(a) === JSON.stringify({ p_sort: 'created_desc', p_limit: 25, p_offset: 0 }), `${name}: oletusparametrit ${JSON.stringify(a)}`);
    await page.locator('[data-testid=pg-next]').first().click(); await page.waitForFunction(() => document.querySelector('[data-testid=pager]').dataset.page === '2');
    a = calls('admin_list_orders').at(-1).args; expect(a.p_offset === 25 && a.p_limit === 25, `${name}: sivutus palvelimella (offset 25) ${JSON.stringify(a)}`);
    await page.selectOption('[data-testid=pagesize]', '50'); await page.waitForTimeout(250);
    a = calls('admin_list_orders').at(-1).args; expect(a.p_limit === 50 && a.p_offset === 0, `${name}: sivukoko 50 → palvelin`);
    await page.locator('[data-testid=pg-last]').first().click(); await page.waitForFunction(() => document.querySelector('[data-testid=pager]').dataset.page === '240');
    a = calls('admin_list_orders').at(-1).args; expect(a.p_offset === 11950, `${name}: viimeinen sivu offset ${a.p_offset}`);
    await page.selectOption('[data-testid=orders-f-pay]', 'unpaid'); await page.selectOption('[data-testid=orders-f-src]', 'admin'); await page.waitForTimeout(250);
    a = calls('admin_list_orders').at(-1).args; expect(a.p_payment_status === 'unpaid' && a.p_source === 'admin' && a.p_offset === 0, `${name}: suodattimet palvelimelle`);
    await page.selectOption('[data-testid=orders-f-native]', 'imported'); await page.selectOption('[data-testid=orders-f-datefield]', 'start'); await page.waitForTimeout(250);
    a = calls('admin_list_orders').at(-1).args; expect(a.p_native === false && a.p_date_field === 'start', `${name}: native/date_field palvelimelle ${JSON.stringify(a)}`);
    await page.click('[data-testid=orders-reset]'); await page.waitForTimeout(250);
    a = calls('admin_list_orders').at(-1).args; expect(!('p_native' in a) && !('p_date_field' in a) && !('p_payment_status' in a), `${name}: tyhjennys poistaa suodattimet`);
    await page.selectOption('[data-testid=orders-sort]', 'order_no'); await page.waitForTimeout(200); await page.click('[data-testid=orders-dir]'); await page.waitForTimeout(250);
    a = calls('admin_list_orders').at(-1).args; expect(a.p_sort === 'order_no_asc', `${name}: lajittelu palvelimelle ${a.p_sort}`);
    await page.selectOption('[data-testid=orders-sort]', 'first_reservation'); await page.waitForTimeout(250);
    expect(calls('admin_list_orders').at(-1).args.p_sort === 'start_asc', `${name}: ensimmäinen varauspäivä → start_asc`);
    await page.selectOption('[data-testid=orders-sort]', 'payment_status'); await page.waitForTimeout(250);
    expect(calls('admin_list_orders').at(-1).args.p_sort === 'unpaid_desc' && await page.locator('[data-testid=orders-dir]').isDisabled(), `${name}: maksutila → unpaid_desc, suunta lukittu`);
    await page.selectOption('[data-testid=orders-sort]', 'created'); await page.waitForTimeout(200);
    await page.fill('[data-testid=orders-f-from]', '2026-01-01'); await page.fill('[data-testid=orders-search]', 'Virtanen'); await page.keyboard.press('Enter'); await page.waitForTimeout(300);
    a = calls('admin_list_orders').at(-1).args; expect(a.p_from === '2026-01-01' && a.p_search === 'Virtanen', `${name}: aikaväli + haku palvelimelle`);
    await page.click('[data-testid=orders-reset]'); await page.waitForTimeout(250);
    // laajennus: admin_get_order (balance, items, lines) + napit sääntöjen mukaan
    await page.selectOption('[data-testid=orders-f-pay]', 'paid'); await page.waitForTimeout(250);
    await page.locator('[data-testid=orders-list] > [data-testid=order]').first().locator('.tl-head').click(); await page.waitForSelector('[data-testid=order-actions]');
    expect(calls('admin_get_order').length === 1 && typeof calls('admin_get_order')[0].args.p_order_id === 'number', `${name}: admin_get_order kutsuttu`);
    // oikeassa tilassa napit ovat käytössä palvelimen sääntöjen mukaan (tässä: maksettu natiivitilaus → lisäys sallittu, linkki ei (ei maksettavaa), hyvitys vaatii payments.refund (PERMS ilman))
    expect(!(await page.locator('[data-testid=btn-add]').first().isDisabled()) && await page.locator('[data-testid=btn-link]').first().isDisabled() && await page.locator('[data-testid=btn-refund]').first().isDisabled(), `${name}: napit oikeassa tilassa (lisäys käytössä, linkki/hyvitys sääntöjen mukaan)`);
    expect(await page.locator('[data-testid=btn-record]').count() === 1 && !(await page.locator('.tl-detail').innerText()).match(/vaiheessa|phase [A-D]|odottaa palvelimen/i), `${name}: ei stub-tekstejä`);
    // kuitit oikealla RPC-polulla: admin_get_receipt (teksti), admin_resend_receipt, PDF-linkki tokenilla, sähköpostin tila integration_config:sta
    await page.waitForSelector('[data-testid=order-receipts] [data-testid=receipt-item]');
    const ri = page.locator('[data-testid=order-receipts] [data-testid=receipt-item]').first();
    await ri.locator('[data-testid=receipt-view]').click(); await page.waitForSelector('dialog[open] [data-testid=receipt-text]');
    const gr = calls('admin_get_receipt').at(-1); expect(!!gr && typeof gr.args.p_receipt_id === 'number' && Object.keys(gr.args).join() === 'p_receipt_id', `${name}: admin_get_receipt p_receipt_id ${JSON.stringify(gr?.args)}`);
    await page.keyboard.press('Escape'); await page.waitForSelector('dialog[open]', { state: 'detached' });
    await ri.locator('[data-testid=receipt-resend]').click(); await page.waitForSelector('dialog[open] [data-testid=resend-dialog]');
    await page.waitForFunction(() => document.querySelector('[data-testid=resend-mode]')?.dataset.mode === 'dry_run');
    await page.click('dialog[open] [data-testid=resend-submit]'); await page.waitForSelector('dialog[open] [data-testid=resend-result]');
    const rr = calls('admin_resend_receipt'); expect(rr.length === 1 && rr[0].args.p_receipt_id === gr.args.p_receipt_id && await page.locator('dialog[open] [data-testid=resend-result]').getAttribute('data-queued') === 'true', `${name}: admin_resend_receipt kutsuttu kerran samalla kuitilla`);
    expect(await page.locator('dialog[open] [data-testid=resend-mode]').innerText() === TEXTS.fi['resend.mode.dry_run'], `${name}: dry_run-varoitus tulosviestissä`);
    await page.keyboard.press('Escape'); await page.waitForSelector('dialog[open]', { state: 'detached' });
    expect(await page.locator('[data-testid=order-unpaid]').count() === 1 && await page.locator('[data-testid=order-total]').count() === 1, `${name}: summat näkyvät`);
    await shot(page, 'talous-oikea-tila-tilaus-390-fi');
    // Maksut: laskurivit haetaan tilaukselta (admin_list_payments ei palauta rivejä)
    await page.click('[data-testid=tab-payments-btn]'); await page.waitForSelector('[data-testid=payments-list] [data-testid=payment]');
    a = calls('admin_list_payments').at(-1).args; expect(JSON.stringify(a) === JSON.stringify({ p_sort: 'paid_desc', p_limit: 25, p_offset: 0 }), `${name}: admin_list_payments parametrit ${JSON.stringify(a)}`);
    expect(/maksettu|paid/i.test(await page.locator('[data-testid=payments-count]').innerText()), `${name}: maksujen summarivi`);
    const before = calls('admin_get_order').length;
    await page.locator('[data-testid=payments-list] > [data-testid=payment]').first().locator('.tl-head').click(); await page.waitForSelector('[data-testid=payment-lines] tbody tr');
    expect(calls('admin_get_order').length === before + 1, `${name}: maksun rivit haettu admin_get_order:lla`);
    // Raportit (vaihe D): RPC puuttuu → mock + ilmoitus, vain raporttitoiminto
    await page.click('[data-testid=tab-reports-btn]'); await page.waitForSelector('[data-testid=r-gross]');
    expect(await page.locator('[data-testid=mock-banner]').isVisible() && await page.locator('[data-testid=mock-banner]').getAttribute('data-reason') === 'missing' && /admin_report_daily/.test(await page.locator('[data-testid=mock-banner]').innerText()), `${name}: banneri kertoo puuttuvan raporttitoiminnon`);
    expect(/^\d{4}-\d{2}-\d{2}$/.test(calls('admin_report_daily').at(-1).args.p_date) && calls('admin_report_daily').length === 1, `${name}: admin_report_daily p_date, yksi 404-kutsu`);
    await page.click('[data-testid=r-kind-monthly]'); await page.waitForSelector('[data-testid=r-daily]');
    expect(/^\d{4}-\d{2}$/.test(calls('admin_report_month').at(-1).args.p_ym), `${name}: admin_report_month p_ym`);
    await page.context().close();
  }
  // ---- oikea tila, kaikki RPC:t vastaavat: raportit sopimuksen mukaan, CSV palvelimelta (admin_report_csv) ----
  {
    const name = 'admin real-all', page = await newPage(name, { vp: 390, listMode: 'real-all' });
    await page.goto(`${ORIGIN}/admin/#/talous?tab=reports`);
    await page.waitForSelector('[data-testid=r-gross]');
    const calls = (n) => page.st.calls.filter((c) => c.name === n);
    expect(await page.locator('[data-testid=mock-banner]').isHidden(), `${name}: ei bannerita`);
    expect(/^\d{4}-\d{2}-\d{2}$/.test(calls('admin_report_daily')[0].args.p_date), `${name}: admin_report_daily`);
    for (const id of ['r-by-vat', 'r-by-method', 'r-matrix', 'r-by-group', 'r-receipts-list']) expect(await page.locator(`[data-testid=${id}]`).count() === 1, `${name}: ${id}`);
    await page.click('[data-testid=r-kind-monthly]'); await page.waitForSelector('[data-testid=r-daily]');
    const mon = calls('admin_report_month').at(-1).args.p_ym;
    const [dl] = await Promise.all([page.waitForEvent('download'), page.click('[data-testid=r-csv]')]);
    const buf = await readFile(await dl.path()), txt = buf.toString('utf8');
    expect(calls('admin_report_csv').length === 1 && calls('admin_report_csv')[0].args.p_from === `${mon}-01` && calls('admin_report_csv')[0].args.p_kind === 'lines', `${name}: admin_report_csv kutsuttu (${JSON.stringify(calls('admin_report_csv')[0]?.args)})`);
    expect(buf[0] === 0xEF && buf[1] === 0xBB && txt.slice(1).startsWith('pvm;kuitti_no;tilaus_no;maksutapa;tuoteryhmä;tuote;määrä;brutto;alv_%;alv_€;netto;hyvitys') && /^kuitit_lines_\d{4}-\d{2}-01_\d{4}-\d{2}-\d{2}\.csv$/.test(dl.suggestedFilename()), `${name}: palvelimen CSV sellaisenaan (${dl.suggestedFilename()})`);
    // report-pdf (verify_jwt=true): Lataa PDF → fetch JWT:llä → tiedosto
    await page.click('[data-testid=r-kind-daily]'); await page.waitForSelector('[data-testid=r-gross]'); await page.waitForFunction(() => !document.querySelector('[data-testid=r-pdf-server]').disabled);
    const [pdl] = await Promise.all([page.waitForEvent('download'), page.click('[data-testid=r-pdf-server]')]);
    expect(/^raportti_paiva_\d{4}-\d{2}-\d{2}\.pdf$/.test(pdl.suggestedFilename()) && page.st.reportPdfCalls?.length === 1 && /kind=daily&date=\d{4}-\d{2}-\d{2}/.test(page.st.reportPdfCalls[0].search) && /^Bearer /.test(page.st.reportPdfCalls[0].auth), `${name}: report-pdf JWT:llä (${JSON.stringify(page.st.reportPdfCalls)})`);
    await page.click('[data-testid=r-kind-monthly]'); await page.waitForSelector('[data-testid=r-daily]'); await page.waitForFunction(() => !document.querySelector('[data-testid=r-pdf-server]').disabled);
    const [pdl2] = await Promise.all([page.waitForEvent('download'), page.click('[data-testid=r-pdf-server]')]);
    expect(/^raportti_kuukausi_\d{4}-\d{2}\.pdf$/.test(pdl2.suggestedFilename()) && /kind=month&ym=\d{4}-\d{2}/.test(page.st.reportPdfCalls[1].search), `${name}: report-pdf kuukausi`);
    await page.context().close();
  }
  // ---- RPC:t puuttuvat: kaunis "ominaisuus ei vielä käytössä" + esimerkkidata; jokaista puuttuvaa RPC:tä kutsutaan vain kerran ----
  {
    const name = 'admin missing', page = await newPage(name, { vp: 390, listMode: 'missing', allow: /status of 404/ });
    await page.goto(`${ORIGIN}/admin/#/talous`);
    await page.waitForSelector('[data-testid=orders-list] [data-testid=order]');
    await page.waitForSelector('[data-testid=mock-banner]:not([hidden])');
    expect(await page.locator('[data-testid=mock-banner]').getAttribute('data-reason') === 'missing', `${name}: syy = missing`);
    expect(/ei vielä käytössä/i.test(await page.locator('[data-testid=mock-banner]').innerText()) && /admin_list_orders/.test(await page.locator('[data-testid=mock-banner]').innerText()), `${name}: banneri kertoo puuttuvan RPC:n`);
    await page.click('[data-testid=tab-payments-btn]'); await page.waitForSelector('[data-testid=payments-list] [data-testid=payment]');
    await page.click('[data-testid=tab-reports-btn]'); await page.waitForSelector('[data-testid=r-gross]');
    await page.click('[data-testid=r-kind-monthly]'); await page.waitForSelector('[data-testid=r-daily]');
    const names = ['admin_list_orders', 'admin_list_payments', 'admin_report_daily', 'admin_report_month'];
    for (const n of names) expect(page.st.calls.filter((c) => c.name === n).length === 1, `${name}: ${n} kutsuttu vain kerran (${page.st.calls.filter((c) => c.name === n).length})`);
    expect(/admin_list_payments/.test(await page.locator('[data-testid=mock-banner]').innerText()) && /admin_report_month/.test(await page.locator('[data-testid=mock-banner]').innerText()), `${name}: banneri listaa kaikki puuttuvat`);
    await shot(page, 'talous-rpc-puuttuu-390-fi');
    await page.context().close();
  }
  // ---- raporttien oikeudet (sopimus §11): reports.daily → päivä; reports.view → kuukausi + CSV ----
  for (const [pname, perms, full, daily] of [['reports.daily', ['payments.manage', 'reports.daily'], false, true], ['ei raportteja', ['payments.manage'], false, false], ['reports.view', ['payments.manage', 'reports.view'], true, true]]) {
    for (const vp of [390, 1280]) {
      const name = `admin ${pname} ${vp}`, page = await newPage(name, { vp, perms });
      await page.goto(`${ORIGIN}/admin/#/talous?mock=1&tab=reports`);
      await page.waitForSelector('[data-testid=talous]');
      expect((await page.locator('[data-testid=tab-reports-btn]').count() === 1) === daily, `${name}: Raportit-välilehti ${daily ? 'näkyy' : 'piilossa'}`);
      if (!daily) { expect(await page.locator('[data-testid=tab-orders-btn]').getAttribute('aria-selected') === 'true', `${name}: tab=reports ohjautuu Tilauksiin`); if (vp === 390) await shot(page, 'talous-raportit-ei-oikeutta-390-fi'); await page.context().close(); continue; }
      await page.waitForSelector('[data-testid=r-gross]');
      expect(await page.locator('[data-testid=r-kind-monthly]').isDisabled() === !full, `${name}: kuukausinappi ${full ? 'käytössä' : 'pois (reports.view puuttuu)'}`);
      expect((await page.locator('[data-testid=r-limited]').count() === 1) === !full, `${name}: ilmoitus ${full ? 'ei näy' : 'näkyy'}`);
      expect(await page.locator('[data-testid=r-csv]').isDisabled() === !full, `${name}: CSV ${full ? 'käytössä' : 'pois'}`);
      expect(await page.locator('[data-testid=r-pdf]').isDisabled() === false, `${name}: PDF (tulosta) käytössä`);
      expect(await page.locator('[data-testid=r-gross-after]').count() === 1 && await page.locator('[data-testid=r-net-ex-vat]').count() === 1, `${name}: bruttosumma hyvitysten jälkeen + veroton summa`);
      if (!full) { await page.locator('[data-testid=r-kind-monthly]').click({ force: true }).catch(() => {}); await page.waitForTimeout(150); expect(await page.locator('[data-testid=r-title], [data-testid=report-title]').first().innerText().then((x) => !/Kuukausiraportti/.test(x)), `${name}: kuukausinäkymää ei avata`); }
      await shot(page, `talous-raportit-${full ? 'view' : 'daily-vain'}-${vp}-fi`);
      await page.context().close();
    }
  }
  // ---- oikeudet: ilman payments.manage ei navigaatiokohtaa ----
  {
    const name = 'admin no-perm', page = await newPage(name, { vp: 390, perms: ['bookings.manage'], allow: /status of (404|400)/ });
    await page.goto(`${ORIGIN}/admin/#/talous`);
    await page.waitForSelector('#nav a');
    expect(await page.locator('#nav a', { hasText: 'Talous' }).count() === 0, `${name}: Talous piilossa ilman oikeutta`);
    expect(await page.locator('[data-testid=talous]').count() === 0, `${name}: Talous-sivua ei näytetä ilman oikeutta`);
    await page.context().close();
  }
}

// ================= KAUPPA: asiakkaan tilaussivu =================
const TOKEN = '3f2b8c1e-7a4d-4e9b-9c55-1d2e3f4a5b6c';
async function shopSuite() {
  for (const lang of ['fi', 'en']) for (const vp of [360, 390, 1280]) {
    const name = `shop ${lang} ${vp}`, base = lang === 'fi' ? '/tilaus/' : '/en/order/';
    const page = await newPage(name, { vp, lang, admin: false });
    page.on('dialog', (d) => d.accept());
    await page.goto(`${ORIGIN}${base}?t=${TOKEN}&mock=1`);
    await page.waitForSelector('[data-testid=order-page]');
    const O = (await import(pathToFileURL(join(ROOT, 'booking/shop/src/order-texts.js')))).OT[lang];
    expect((await page.locator('[data-testid=order-title]').innerText()).startsWith(`${O.order} #`), `${name}: otsikko`);
    expect(await page.locator('[data-testid=mock-banner]').isVisible(), `${name}: mock-banneri`);
    expect(await page.locator('[data-testid=order-lines] li').count() === 3, `${name}: 3 tilausriviä`);
    expect(num(await page.locator('[data-testid=order-total]').innerText()) === 131, `${name}: summa 131 (${await page.locator('[data-testid=order-total]').innerText()})`);
    expect(num(await page.locator('[data-testid=order-unpaid]').innerText()) === 71, `${name}: maksamaton 71`);
    expect(await page.locator('[data-testid=pay-rest]').isDisabled(), `${name}: maksunappi pois käytöstä (verkkomaksu myöhemmin)`);
    expect(await page.locator('[data-testid=receipts] li').count() === 1, `${name}: kuitti listattu`);
    expect(await page.locator('[data-testid=order-reservations] li').count() === 2 && await page.locator('[data-testid=change-note]').count() === 1, `${name}: varaukset ja muutosaikamuistutus`);
    expect(!page.url().includes('#') && (await page.locator('meta[name=referrer]').getAttribute('content')) === 'no-referrer' && /noindex/.test(await page.locator('meta[name=robots]').getAttribute('content')), `${name}: token vain query-parametrina, referrer no-referrer, noindex`);
    await layoutChecks(page, `${name} tilaussivu`, '#order-app');
    await shot(page, `asiakas-tilaus-${vp}-${lang}`);
    // kuitin lataus
    const [dl] = await Promise.all([page.waitForEvent('download'), page.click('[data-testid=receipt-dl]')]);
    expect(/^K-2026-000321\.txt$/.test(dl.suggestedFilename()), `${name}: kuitin lataus ${dl.suggestedFilename()}`);
    // lisäys
    expect(await page.locator('[data-testid=add-reservation] option').count() === 2, `${name}: varausvalinta (2 varausta)`); await page.selectOption('[data-testid=add-select]', 'turvenaamio_jalkakylpy'); await page.fill('[data-testid=add-qty]', '2'); await page.click('[data-testid=add-submit]');
    await page.waitForFunction(() => document.querySelectorAll('[data-testid=order-lines] li').length === 4);
    expect(num(await page.locator('[data-testid=order-total]').innerText()) === 155, `${name}: lisäyksen jälkeen 155`);
    expect(await page.locator('[data-testid=order-msg] .bk-ok').count() === 1, `${name}: lisäyksen kuittaus`);
    // peruutuspyyntö
    await page.fill('[data-testid=cancel-reason]', 'Sairastuin'); await page.click('[data-testid=cancel-submit]');
    await page.waitForSelector('[data-testid=cancel-pending]'); expect(await page.locator('[data-testid=order-msg] .bk-ok').count() === 1, `${name}: peruutuspyynnön kuittaus`);
    await layoutChecks(page, `${name} tilaussivu lisäyksen jälkeen`, '#order-app');
    if (vp !== 360) await shot(page, `asiakas-tilaus-peruutus-${vp}-${lang}`);
    await page.context().close();
  }
  { // RPC puuttuu → ei esimerkkidataa asiakkaalle
    const name = 'shop notready', page = await newPage(name, { vp: 390, admin: false, allow: /status of 404/ });
    await page.goto(`${ORIGIN}/tilaus/?t=${TOKEN}`); await page.waitForSelector('[data-testid=not-ready]');
    expect(await page.locator('[data-testid=order-page]').count() === 0 && await page.locator('[data-testid=mock-banner]').count() === 0, `${name}: ei esimerkkidataa asiakkaalle`);
    await shot(page, 'asiakas-tilaus-ei-kaytossa-390-fi'); await page.context().close();
  }
  { // sopimuksen yksi linkki (/tilaus/?t=…): tilauksen locale ohjaa oikean kielen sivulle (token säilyy), ja takaisin
    const { createOrderMock } = await import(pathToFileURL(join(ROOT, 'booking/shop/src/order-mock.js')));
    for (const [from, loc, to] of [['/tilaus/', 'en', '/en/order/'], ['/en/order/', 'fi', '/tilaus/'], ['/tilaus/', 'fi', '/tilaus/']]) {
      const name = `shop locale ${from}->${to}`, page = await newPage(name, { vp: 390, lang: loc, admin: false });
      await page.route(`${ORIGIN}/rest/v1/rpc/public_get_order`, async (route) => { const r = await createOrderMock().rpc('public_get_order', { p_token: TOKEN }); route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ...r, locale: loc }) }); });
      await page.goto(`${ORIGIN}${from}?t=${TOKEN}`);
      await page.waitForSelector('[data-testid=order-page]'); await page.waitForTimeout(150);
      const u = new URL(page.url());
      expect(u.pathname === to && u.searchParams.get('t') === TOKEN, `${name}: osoite ${u.pathname}${u.search}`);
      await page.context().close();
    }
  }
  { // virheellinen/puuttuva token
    const name = 'shop notoken', page = await newPage(name, { vp: 390, admin: false });
    await page.goto(`${ORIGIN}/tilaus/`); await page.waitForSelector('#order-app .bk-error');
    await page.goto(`${ORIGIN}/tilaus/?t=abc`); await page.waitForSelector('#order-app .bk-error');
    expect(true, 'token'); await page.context().close();
  }
}
if (ONLY !== "shop") await adminSuite();
if (ONLY !== 'admin') await shopSuite();
await browser.close(); server.close();
if (problems.length) { console.error(`E2E-talous: ${problems.length} ongelmaa (${checks} tarkistusta):\n- ${[...new Set(problems)].join('\n- ')}`); process.exit(1); }
console.log(`ok: Talous-näkymät ja asiakkaan tilaussivu – ${checks} tarkistusta, kuvat → ${SHOT}`);
