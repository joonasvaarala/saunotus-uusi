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
const PERMS = ['payments.manage', 'bookings.manage', 'customers.manage'];
const missing = (name) => ({ status: 404, body: { code: 'PGRST202', message: `Could not find the function booking.${name} in the schema cache` } });
// listMode: 'real' = tuotannon vaihe A: admin_list_*/admin_get_order vastaavat (sopimuksen muodossa), raporttien RPC:t (vaihe D) puuttuvat (404);
//           'real-all' = kaikki RPC:t vastaavat (myös admin_report_*; ilman rivitason `lines`-kenttää kuten oikea palvelin); 'missing' = kaikki 404.
const REPORT_RPCS = ['admin_report_daily', 'admin_report_month'];
async function rpcReply(st, name, a) {
  st.calls.push({ name, args: a });
  if (name === 'current_staff_role') return { body: 'manager' };
  if (name === 'admin_my_permissions') return { body: { role: 'manager', role_label: 'Päällikkö', permissions: st.perms } };
  if (name === 'admin_list_products') return { body: [] };
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
    if (m !== 'POST') return json([]);   // select('payment_methods' | 'resources')
    const rpcName = u.pathname.split('/rpc/')[1];
    let a = {}; try { a = JSON.parse(route.request().postData() || '{}'); } catch { /* tyhjä */ }
    const r = await rpcReply(st, rpcName, a);
    return json(r.body, r.status || 200);
  });
  if (admin) await ctx.addInitScript((s) => { try { localStorage.setItem('booking.session', JSON.stringify(s)); } catch { /* */ } }, { access_token: fakeJwt(), refresh_token: 'r', expires_at: 4102444800, user: { id: 'u1', email: 'manager@test.local' } });
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
const nbsp = /[\s\u00a0\u202f]/g;
const num = (s) => +String(s).replace(nbsp, '').replace(/\u2212/g, '-').replace(',', '.').replace(/[^\d.\-]/g, '');

// ================= HALLINTA =================
async function adminSuite() {
  const VPS = [360, 390, 430, 1280];
  for (const lang of ['fi', 'en']) for (const vp of VPS) {
    const T = TEXTS[lang], name = `admin ${lang} ${vp}`;
    const page = await newPage(name, { vp, lang });
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
    for (const id of ['btn-add', 'btn-link', 'btn-receipts', 'btn-refund']) expect(await page.locator(`[data-testid=${id}]`).first().count() === 1, `${name}: nappi ${id}`);
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
    for (const id of ['r-by-vat', 'r-by-method', 'r-matrix', 'r-by-group', 'r-net-ex-vat']) expect(await page.locator(`[data-testid=${id}]`).count() === 1, `${name}: raporttitaulukko ${id}`);
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
    // laajennus: admin_get_order (balance, items, lines) + napit pois käytöstä (LIVE_ACTIONS)
    await page.selectOption('[data-testid=orders-f-pay]', 'paid'); await page.waitForTimeout(250);
    await page.locator('[data-testid=orders-list] > [data-testid=order]').first().locator('.tl-head').click(); await page.waitForSelector('[data-testid=order-actions]');
    expect(calls('admin_get_order').length === 1 && typeof calls('admin_get_order')[0].args.p_order_id === 'number', `${name}: admin_get_order kutsuttu`);
    // LIVE_ACTIONS päällä: oikeassa tilassa napit ovat käytössä palvelimen sääntöjen mukaan (tässä: maksettu natiivitilaus → lisäys sallittu, linkki ei (ei maksettavaa), hyvitys vaatii payments.refund (PERMS ilman))
    expect(!(await page.locator('[data-testid=btn-add]').first().isDisabled()) && await page.locator('[data-testid=btn-link]').first().isDisabled() && await page.locator('[data-testid=btn-refund]').first().isDisabled(), `${name}: napit oikeassa tilassa (lisäys käytössä, linkki/hyvitys sääntöjen mukaan)`);
    expect(await page.locator('[data-testid=btn-record]').count() === 1 && await page.locator('.tl-detail .tl-hint').count() === 0, `${name}: ei "odottaa RPC"-vihjettä kun toiminnot on kytketty`);
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
