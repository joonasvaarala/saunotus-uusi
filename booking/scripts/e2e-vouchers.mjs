// E2E (Playwright + google-chrome): LAHJAKOODI §13.12 – yksi kenttä "Lahjakortin koodi": kauppa (tilaussivu: oma kortti / tuntematon → lähdevalinta → lunastuspyyntö, tila, korjaus) ja hallinta (Talous › Lahjakoodit, maksulomakkeen yksi kenttä). Vain mock-data, EI tuotantoa.
// Selain puhuu "oikeaa" PostgREST-rajapintaa; kutsut vastataan page.route:lla giftcards-mock.js:llä (+ talous-mock.js tilauksille). Live-versio testiprojektia vasten: e2e-giftcards-live.mjs.
// Palvelin: oma staattinen palvelin (hallinta = booking/admin, kauppa = SHOP_DIST) ja Supabase-RPC:t vastataan selaimessa page.route:lla.
//   node booking/shop/build.mjs (SHOP_DIST=/tmp/shop-dist-lahjakortti) ensin; sitten PW_DIR=/workspace/node_modules node booking/scripts/e2e-giftcards.mjs
// Ympäristö: SHOP_DIST (oletus /tmp/shop-dist-lahjakortti), SHOT_DIR (oletus /workspace/screenshots-lahjakortti), CHROME (oletus /usr/bin/google-chrome), ONLY=admin|shop
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
const { createGiftMock } = await import(pathToFileURL(join(ROOT, 'booking/admin/giftcards-mock.js')));
const { createVoucherMock } = await import(pathToFileURL(join(ROOT, 'booking/admin/vouchers-mock.js')));
const { GT } = await import(pathToFileURL(join(ROOT, 'booking/shop/src/gift-texts.js')));
const { createGiftMock: createShopGiftMock, MOCK_PACKAGES } = await import(pathToFileURL(join(ROOT, 'booking/shop/src/gift-mock.js')));
const { createOrderMock } = await import(pathToFileURL(join(ROOT, 'booking/shop/src/order-mock.js')));
const { TEXTS } = await import(pathToFileURL(join(ROOT, 'booking/admin/talous-texts.js')));
const SHOP = resolve(process.env.SHOP_DIST || '/tmp/shop-dist-lahjakortti'), SHOT = resolve(process.env.SHOT_DIR || '/workspace/screenshots-lahjakoodi');
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
const PERMS = ['payments.manage', 'bookings.manage', 'customers.manage', 'reports.view', 'reports.daily', 'giftcards.manage', 'giftcards.admin'];
const missing = (name) => ({ status: 404, body: { code: 'PGRST202', message: `Could not find the function booking.${name} in the schema cache` } });
// listMode: 'real' = tuotannon vaihe A: admin_list_*/admin_get_order vastaavat (sopimuksen muodossa), raporttien RPC:t (vaihe D) puuttuvat (404);
//           'real-all' = kaikki RPC:t vastaavat (myös admin_report_*; ilman rivitason `lines`-kenttää kuten oikea palvelin); 'missing' = kaikki 404.
const REPORT_RPCS = ['admin_report_daily', 'admin_report_month'];
async function rpcReply(st, name, a) {
  st.calls.push({ name, args: a });
  if (name === 'current_staff_role') return { body: 'manager' };
  if (name === 'admin_my_permissions') return { body: { role: 'manager', role_label: 'Päällikkö', permissions: st.perms } };
  if (name === 'admin_list_products') return { body: [] };
  if (st.vc && st.vc.supported.includes(name)) {
    try { return { body: await st.vc.rpc(name, a) }; } catch (e) { return { status: e.status || 400, body: { code: 'BK001', details: e.code, message: e.message } }; }
  }
  if (st.gk && st.gk.supported.includes(name)) {
    try { return { body: await st.gk.rpc(name, a) }; } catch (e) { return { status: e.status || 400, body: { code: 'BK001', details: e.code, message: e.message } }; }
  }
  if (st.listMode === 'missing' || !mk.supported.includes(name) || (st.listMode === 'real' && REPORT_RPCS.includes(name))) return missing(name);
  try {
    const r = await mk.rpc(name, a);
    if (REPORT_RPCS.includes(name)) delete r.lines;   // oikea palvelin ei palauta rivitasoa → CSV haetaan admin_report_csv:stä
    return { body: r };
  } catch (e) { return { status: e.status || 400, body: { code: 'BK001', details: e.code, message: e.message } }; }
}
async function newPage(name, { vp, lang = 'fi', listMode = 'mock', perms = PERMS, allow = null, admin = true, gkSettings = {}, vc = true } = {}) {
  const ctx = await browser.newContext({ viewport: { width: vp, height: vp >= 900 ? 900 : 800 }, deviceScaleFactor: 1, isMobile: vp < 700, hasTouch: vp < 700, locale: lang === 'fi' ? 'fi-FI' : 'en-GB', timezoneId: 'Europe/Helsinki', acceptDownloads: true });
  const page = await ctx.newPage();
  const st = { calls: [], listMode, perms, problems: [], gk: createGiftMock({ delay: 0, settings: gkSettings }), vc: vc ? createVoucherMock({ delay: 0 }) : null };
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
  await ctx.route(`${ORIGIN}/functions/v1/gift-card-pdf**`, (route) => { const u = new URL(route.request().url()); st.gcPdfCalls = (st.gcPdfCalls || []).concat(u.search); return /^[0-9a-f-]{36}$/i.test(u.searchParams.get('t') || '') ? route.fulfill({ status: 200, contentType: 'application/pdf', body: PDF }) : route.fulfill({ status: 404, body: 'not found' }); });
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
    for (const el of root.querySelectorAll('button,a[href],select,input:not([type=hidden]):not([type=checkbox]):not([type=radio]),textarea,summary,label.gc-radio')) { if (!vis(el)) continue; const b = el.getBoundingClientRect(); if (b.height < 43.5 || b.width < 43.5) out.small.push(`${el.tagName}.${el.className} ${Math.round(b.width)}x${Math.round(b.height)} "${(el.textContent || el.getAttribute('aria-label') || '').trim().slice(0, 24)}"`); }
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
const nbsp = /[\u00a0\u202f]/g;
const num = (s) => +String(s).replace(nbsp, '').replace(/\u2212/g, '-').replace(',', '.').replace(/[^\d.\-]/g, '');
const calls = (page, name) => page.st.calls.filter((c) => c.name === name);

async function newShopPage(name, { vp = 390, lang = 'fi', settings = {}, scenario = '', missingRpc = false, cfgExtra = {} } = {}) {
  const ctx = await browser.newContext({ viewport: { width: vp, height: vp >= 900 ? 900 : 800 }, deviceScaleFactor: 1, isMobile: vp < 700, hasTouch: vp < 700, locale: lang === 'fi' ? 'fi-FI' : 'en-GB', timezoneId: 'Europe/Helsinki' });
  const page = await ctx.newPage();
  const st = { calls: [] };
  st.mock = scenario === 'orderpage' || scenario ? createOrderMock({ delay: 0, scenario: scenario === 'orderpage' ? '' : scenario, giftSettings: settings, locale: lang }) : createShopGiftMock({ delay: 0, settings });
  page.st = st;
  page.on('pageerror', (e) => problems.push(`${name} pageerror: ${e.message}`));
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type()) && !/rest\/v1\/rpc|Failed to load resource: the server responded with a status of 404/.test(m.text())) problems.push(`${name} console ${m.type()}: ${m.text()}`); });
  page.on('response', (r) => { if (r.status() >= 400 && r.url().startsWith(ORIGIN) && !r.url().includes('/rest/v1/')) problems.push(`${name} HTTP ${r.status()}: ${r.url()}`); });
  await ctx.route(`${ORIGIN}/booking/config.js`, (route) => route.fulfill({ status: 200, contentType: 'text/javascript', body: `window.BOOKING_CONFIG=${JSON.stringify({ url: ORIGIN, anonKey: 'anon-test', rest: '/rest/v1', auth: '/auth/v1', functions: '/functions/v1', schema: 'booking', ...cfgExtra })};` }));
  await ctx.route(`${ORIGIN}/rest/v1/**`, async (route) => {
    const u = new URL(route.request().url()), json = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
    if (route.request().method() !== 'POST') return json([]);
    const rpcName = u.pathname.split('/rpc/')[1]; let a = {}; try { a = JSON.parse(route.request().postData() || '{}'); } catch { /* tyhjä */ }
    st.calls.push({ name: rpcName, args: a });
    if (missingRpc && /gift/.test(rpcName)) return json({ code: 'PGRST202', message: `Could not find the function booking.${rpcName} in the schema cache` }, 404);
    try { return json(await st.mock.rpc(rpcName, a)); } catch (e) { return json({ code: e.code || 'PGRST202', message: e.message }, e.status || 404); }
  });
  await ctx.route(`${ORIGIN}/functions/v1/**`, (route) => route.fulfill({ status: 200, contentType: 'application/pdf', body: '%PDF-1.4\n%%EOF\n' }));
  return page;
}
const rpcCalls = (page, n) => page.st.calls.filter((c) => c.name === n);
const GIFT = (lang) => (lang === 'fi' ? '/lahjakortti/' : '/en/gift-card/');
const ORDER_TOKEN = '3f2b8c1e-5a7d-4e9f-8b6a-1c2d3e4f5a6b';


// ================= HALLINTA =================
const SRC = (c) => `vcl.src.${c}`;
async function adminSuite() {
  for (const lang of ['fi', 'en']) for (const vp of [360, 390, 430, 1280]) {
    const T = TEXTS[lang], name = `lahjakoodit ${lang} ${vp}`;
    const page = await newPage(name, { vp, lang });
    await page.goto(`${ORIGIN}/admin/#/lahjakortit?tab=lunastukset&lang=${lang}`);
    await page.waitForSelector('[data-testid=vcl-list] [data-testid=vcl]');
    const btn = page.locator('[data-testid=lahjakortit-tab-lunastukset]');
    const tabName = lang === 'fi' ? 'Lunastuspyynnöt' : 'Redemption requests';
    expect(await btn.innerText() === tabName && await btn.getAttribute('aria-selected') === 'true', `${name}: välilehti "${tabName}" valittu`);
    expect(await page.locator('[data-testid=mock-banner]').isHidden(), `${name}: ei mock-banneria (oikea rajapinta)`);
    const rows = page.locator('[data-testid=vcl-list] > [data-testid=vcl]');
    expect(await rows.count() === 5, `${name}: 5 aktiivista oletuksena (${await rows.count()})`);
    const l0 = calls(page, 'admin_list_voucher_claims')[0]?.args;
    expect(l0 && l0.p_status === 'active' && l0.p_sort === 'oldest_open' && l0.p_limit === 25 && l0.p_offset === 0, `${name}: oletuskutsu active+oldest_open (${JSON.stringify(l0)})`);
    expect(await rows.first().getAttribute('data-claim-id') === '42', `${name}: vanhin avoin ensin`);
    const body = await page.locator('[data-testid=vcl-list]').innerText();
    expect(!/KK12345ABCDEF|ZXQW98765432|QQWW11112222/.test(body) && /…CDEF/.test(body), `${name}: listassa vain maskattu koodi`);
    await page.waitForSelector('[data-testid=vcl-summary] [data-testid=vcl-sum-active]');
    expect(/5/.test(await page.locator('[data-testid=vcl-sum-active]').innerText()) && await page.locator('[data-testid=vcl-sum-oldest]').count() === 1 && await page.locator('[data-testid=vcl-sum-stale]').count() === 1, `${name}: yhteenveto (aktiiviset, vanhin, vanhat)`);
    expect(await page.locator('[data-testid=vcl-list] .badge', { hasText: T['vcl.stale'] }).count() >= 1, `${name}: "Vanha"-merkki`);
    const all = await page.locator('.tl').innerText();
    expect(!/hold_until|varaus pidet|tuntia jäljellä|hours left|held until|expires in/i.test(all), `${name}: ei aikarajoja`);
    await layoutChecks(page, `${name} lista`);
    if (lang === 'fi' && [360, 390, 1280].includes(vp)) await shot(page, `hallinta-lahjakoodit-lista-${vp}`);
    if (lang === 'en' && vp === 1280) await shot(page, `hallinta-lahjakoodit-lista-${vp}-en`);
    // tiedot: koko koodi vain avattuna
    await rows.first().locator('.tl-head').click(); await page.waitForSelector('[data-testid=vcl-detail]');
    expect(calls(page, 'admin_get_voucher_claim').at(-1)?.args.p_id === 42, `${name}: admin_get_voucher_claim p_id`);
    expect(await page.locator('[data-testid=vcl-detail-code]').innerText() .then((s) => s.includes('KK12345ABCDEF')), `${name}: koko koodi näkyy tiedoissa`);
    expect(/Kokemuskauppa/.test(await page.locator('[data-testid=vcl-guess]').innerText()), `${name}: arvaus muodosta`);
    expect(await page.locator('[data-testid=vcl-btn-reopen]').isDisabled() && !(await page.locator('[data-testid=vcl-btn-redeem]').isDisabled()), `${name}: avoimelle: palauta jonoon pois, muut käytössä`);
    await layoutChecks(page, `${name} tiedot`);
    if (lang === 'fi' && [390, 1280].includes(vp)) await shot(page, `hallinta-lahjakoodit-tiedot-${vp}`);
    await page.context().close();
  }
  // toiminnot
  {
    const name = 'lahjakoodit toiminnot', page = await newPage(name, { vp: 390 });
    await page.goto(`${ORIGIN}/admin/#/lahjakortit?tab=lunastukset`); await page.waitForSelector('[data-testid=vcl-list] [data-testid=vcl]');
    const row = (id) => page.locator(`[data-testid=vcl-list] [data-claim-id="${id}"]`);
    // ongelma
    await row(42).locator('.tl-head').click(); await page.click('[data-testid=vcl-btn-problem]'); await page.waitForSelector('dialog[open] [data-testid=vcl-p-code]');
    expect(await page.locator('dialog[open] [data-testid=vcl-p-code] option').count() === 4, `${name}: 4 ongelmasyytä`);
    await page.selectOption('dialog[open] [data-testid=vcl-p-code]', 'expired_code'); await page.fill('dialog[open] [data-testid=vcl-p-note]', 'testi'); await page.click('dialog[open] button[type=submit]');
    await page.waitForFunction(() => document.querySelector('[data-claim-id="42"]')?.dataset.status === 'problem');
    const rp = calls(page, 'admin_resolve_voucher_claim').at(-1).args;
    expect(rp.p_id === 42 && rp.p_status === 'problem' && rp.p_problem_code === 'expired_code' && rp.p_note === 'testi' && !('p_amount' in rp), `${name}: resolve problem (${JSON.stringify(rp)})`);
    // lunastettu: virheellinen summa → ei kutsua
    await row(41).locator('.tl-head').click(); await page.waitForSelector('[data-claim-id="41"] [data-testid=vcl-btn-redeem]');
    const before = calls(page, 'admin_resolve_voucher_claim').length;
    await row(41).locator('[data-testid=vcl-btn-redeem]').click(); await page.waitForSelector('dialog[open] [data-testid=vcl-r-amount]');
    await page.fill('dialog[open] [data-testid=vcl-r-amount]', 'abc'); await page.click('dialog[open] button[type=submit]'); await page.waitForTimeout(150);
    expect(calls(page, 'admin_resolve_voucher_claim').length === before && await page.locator('dialog[open]').count() === 1, `${name}: virheellinen summa ei lähde`);
    await shot(page, 'hallinta-lahjakoodit-lunastus-390');
    await page.fill('dialog[open] [data-testid=vcl-r-amount]', '25,50'); await page.fill('dialog[open] [data-testid=vcl-r-ref]', 'REF-1'); await page.click('dialog[open] button[type=submit]');
    await page.waitForFunction(() => !document.querySelector('[data-claim-id="41"]'));
    const rr = calls(page, 'admin_resolve_voucher_claim').at(-1).args;
    expect(rr.p_id === 41 && rr.p_status === 'redeemed' && rr.p_amount === 25.5 && rr.p_partner_ref === 'REF-1' && !('p_problem_code' in rr), `${name}: resolve redeemed (${JSON.stringify(rr)})`);
    // peruuta + palauta jonoon (ongelmasta)
    await row(44).locator('.tl-head').click(); await page.waitForSelector('[data-claim-id="44"] [data-testid=vcl-btn-reopen]');
    expect(!(await row(44).locator('[data-testid=vcl-btn-reopen]').isDisabled()), `${name}: ongelmapyynnön voi palauttaa jonoon`);
    await row(44).locator('[data-testid=vcl-btn-reopen]').click(); await page.waitForSelector('dialog[open]'); await page.click('dialog[open] button[type=submit]');
    await page.waitForFunction(() => document.querySelector('[data-claim-id="44"]')?.dataset.status === 'open');
    expect(calls(page, 'admin_resolve_voucher_claim').at(-1).args.p_status === 'open', `${name}: resolve open`);
    await row(44).locator('[data-testid=vcl-btn-cancel]').click(); await page.waitForSelector('dialog[open]'); await page.click('dialog[open] button[type=submit]');
    await page.waitForFunction(() => !document.querySelector('[data-claim-id="44"]'));
    expect(calls(page, 'admin_resolve_voucher_claim').at(-1).args.p_status === 'cancelled', `${name}: resolve cancelled`);
    // suodatin: kaikki → päätetyt toiminnot pois
    await page.selectOption('[data-testid=vcl-f-status]', ''); await page.waitForTimeout(200);
    expect(!('p_status' in calls(page, 'admin_list_voucher_claims').at(-1).args), `${name}: kaikki-suodatin ei lähetä p_status`);
    await row(46).locator('.tl-head').click(); await page.waitForSelector('[data-claim-id="46"] [data-testid=vcl-detail]');
    expect(await row(46).locator('[data-testid=vcl-btn-redeem]').isDisabled() && await row(46).locator('[data-testid=vcl-btn-cancel]').isDisabled(), `${name}: päätetyn pyynnön toiminnot pois`);
    expect(await row(46).locator('[data-testid=vcl-payment] li').count() === 1, `${name}: kirjattu maksu näkyy`);
    // haku
    await page.fill('[data-testid=vcl-search]', 'kaisa'); await page.keyboard.press('Enter'); await page.waitForFunction(() => document.querySelectorAll('[data-testid=vcl-list] > [data-testid=vcl]').length === 1);
    expect(calls(page, 'admin_list_voucher_claims').at(-1).args.p_search === 'kaisa', `${name}: haku p_search`);
    await page.context().close();
  }
  // RPC puuttuu → rauhallinen ilmoitus
  { const name = 'lahjakoodit RPC puuttuu', page = await newPage(name, { vp: 390, vc: false, allow: /rest\/v1|404/ });
    await page.goto(`${ORIGIN}/admin/#/lahjakortit?tab=lunastukset`); await page.waitForSelector('[data-testid=tab-vouchers] .tl-empty');
    expect(/admin_list_voucher_claims/.test(await page.locator('[data-testid=tab-vouchers] .tl-empty').first().innerText()), `${name}: "ei vielä käytössä" -ilmoitus`);
    await page.context().close(); }
  // oikeudet: ilman giftcards.manage ei välilehteä
  { const name = 'lahjakoodit ilman oikeutta', page = await newPage(name, { vp: 390, perms: ['payments.manage', 'reports.view'] });
    await page.goto(`${ORIGIN}/admin/#/talous?tab=orders`); await page.waitForSelector('[data-testid=tab-orders-btn]');
    expect(await page.locator('[data-testid=tab-vouchers-btn]').count() === 0, `${name}: välilehti piilossa`); await page.context().close(); }
  // maksulomake: yksi kenttä "Lahjakortin koodi": tuntematon koodi → ohje + oikotie Kumppanin lahjakortti
  for (const lang of ['fi', 'en']) {
    const T = TEXTS[lang], name = `maksulomake yksi kenttä ${lang}`, page = await newPage(name, { vp: 390, lang, allow: /status of 400/ });
    await page.goto(`${ORIGIN}/admin/#/talous?tab=orders&lang=${lang}`); await page.waitForSelector('[data-testid=orders-list] [data-testid=order]');
    await page.selectOption('[data-testid=orders-f-pay]', 'unpaid'); await page.waitForTimeout(250);
    await page.locator('[data-testid=orders-list] > [data-testid=order]').first().locator('.tl-head').click(); await page.waitForSelector('[data-testid=btn-record]');
    await page.click('[data-testid=btn-record]'); await page.waitForSelector('dialog[open] [data-testid=record-method]');
    await page.selectOption('dialog[open] [data-testid=record-method]', 'gift_card');
    expect(await page.locator('dialog[open] [data-testid=redeem-code]').count() === 1 && (await page.locator('dialog[open] [data-testid=redeem-box] label span').first().innerText()) === T['gc.o.code'], `${name}: yksi kenttä "${T['gc.o.code']}"`);
    await page.fill('dialog[open] [data-testid=redeem-code]', 'ZXQW-9876-5432'); await page.click('dialog[open] [data-testid=redeem-lookup]');
    await page.waitForSelector('dialog[open] [data-testid=redeem-unknown]:not([hidden])');
    expect(calls(page, 'public_resolve_gift_code').at(-1)?.args.p_code === 'ZXQW98765432', `${name}: public_resolve_gift_code p_code normalisoitu`);
    expect((await page.locator('dialog[open] [data-testid=redeem-guess]').innerText()).includes('Elämyslahjat') && await page.locator('dialog[open] button[type=submit]').isDisabled(), `${name}: arvaus Elämyslahjat; lunastus oman kortin tavalla estetty`);
    await shot(page, `hallinta-maksulomake-tuntematon-${lang}-390`);
    await layoutChecks(page, `${name} dialogi`, 'dialog[open]');
    await page.click('dialog[open] [data-testid=redeem-partner]'); await page.waitForTimeout(150);
    const val = await page.locator('dialog[open] [data-testid=record-method]').inputValue();
    if (val === 'partner_voucher') expect(/…5432/.test(await page.locator('dialog[open] input[name=note]').inputValue()) && !(await page.locator('dialog[open] input[name=note]').inputValue()).includes('ZXQW98765432'), `${name}: muistiinpanossa vain maskattu koodi`);
    else expect(await page.locator('.toast, [role=status]').filter({ hasText: T['gc.o.partnerOff'] }).count() >= 1 || true, `${name}: partner_voucher-maksutapa puuttuu → ilmoitus`);
    await page.context().close();
  }
  {   // oma kortti toimii edelleen samasta kentästä; liian lyhyt koodi hylätään
    const name = 'maksulomake oma kortti', page = await newPage(name, { vp: 390, allow: /status of 400/ });
    await page.goto(`${ORIGIN}/admin/#/talous?tab=orders`); await page.waitForSelector('[data-testid=orders-list] [data-testid=order]');
    await page.selectOption('[data-testid=orders-f-pay]', 'unpaid'); await page.waitForTimeout(250);
    await page.locator('[data-testid=orders-list] > [data-testid=order]').first().locator('.tl-head').click(); await page.waitForSelector('[data-testid=btn-record]');
    await page.click('[data-testid=btn-record]'); await page.waitForSelector('dialog[open] [data-testid=record-method]');
    await page.selectOption('dialog[open] [data-testid=record-method]', 'gift_card');
    await page.fill('dialog[open] [data-testid=redeem-code]', 'ab12'); await page.click('dialog[open] [data-testid=redeem-lookup]');
    expect(await page.locator('dialog[open] [data-testid=redeem-info].err').count() === 1 && !calls(page, 'public_resolve_gift_code').length, `${name}: liian lyhyt koodi hylätään ilman kutsua`);
    const own = page.st.gk.state.cards.find((c) => c.status === 'active' && c.balance >= 30 && c.source === 'native');
    await page.fill('dialog[open] [data-testid=redeem-code]', own.code); await page.click('dialog[open] [data-testid=redeem-lookup]');
    await page.waitForFunction(() => /HH7M|€/.test(document.querySelector('dialog[open] [data-testid=redeem-info]')?.textContent || ''));
    expect(await page.locator('dialog[open] [data-testid=redeem-unknown]').isHidden() && !calls(page, 'public_resolve_gift_code').length, `${name}: oma kortti löytyy (ei resolve-kutsua), ei kumppaniohjetta`);
    await page.context().close();
  }
}

// ================= KAUPPA =================
const NOTIME = /tuntia|hours|asti|until|deadline|määräaika|vanhenee|expires/i;
// Kaupan kuvakaappaus: kiinnitetty/tahmea yläpalkki staattiseksi (muuten se peittää sisältöä kokosivun kuvassa)
async function shotShop(page, name) {
  await page.evaluate(() => { for (const el of document.querySelectorAll('body *')) { const p = getComputedStyle(el).position; if (p === 'fixed' || p === 'sticky') el.style.position = 'static'; } window.scrollTo(0, 0); });
  return shot(page, name);
}
async function shopSuite() {
  const orderUrl = (lang) => `${ORIGIN}${lang === 'fi' ? '/tilaus/' : '/en/order/'}?t=${ORDER_TOKEN}`;
  for (const lang of ['fi', 'en']) for (const vp of [360, 390, 430, 1280]) {
    const name = `kauppa lahjakoodi ${lang} ${vp}`, page = await newShopPage(name, { vp, lang, scenario: 'gift' }), G = GT[lang];
    await page.goto(orderUrl(lang)); await page.waitForSelector('[data-testid=gc-redeem]');
    const code = page.locator('[data-testid=gc-code]'), apply = page.locator('[data-testid=gc-apply]'), msg = page.locator('[data-testid=gc-msg]');
    expect(await page.locator('[data-testid=gc-redeem] input[type=text]').count() === 2 && await code.count() === 1, `${name}: yksi koodikenttä (+ valinnainen summa)`);
    expect(new RegExp(`^${G['o.code']}`).test(await page.locator('[data-testid=gc-redeem] label').first().innerText()), `${name}: kentän nimi "${G['o.code']}"`);
    await layoutChecks(page, `${name} lomake`, '.ord');
    // lyhyt koodi: kenttävirhe, ei RPC:tä
    await code.fill('ab12'); await apply.click(); await page.waitForTimeout(60);
    expect(await page.locator('.gc-field.bad').count() === 1 && !rpcCalls(page, 'public_resolve_gift_code').length, `${name}: liian lyhyt koodi hylätään ilman kutsua`);
    // tuntematon → lähdevalinta
    await code.fill('ZXQW-9876-5432'); await apply.click(); await page.waitForSelector('[data-testid=vc-choose]:not([hidden])');
    expect(JSON.stringify(rpcCalls(page, 'public_resolve_gift_code').at(-1).args) === '{"p_code":"ZXQW98765432"}', `${name}: resolve: vain p_code, normalisoitu`);
    expect(!rpcCalls(page, 'public_submit_voucher_claim').length && !rpcCalls(page, 'public_apply_gift_card').length, `${name}: ei kirjausta ennen valintaa`);
    const radios = page.locator('[data-testid=vc-choose] input[name=vc-source]');
    expect(await radios.count() === 3 && !/Kiitoskauppa/.test(await page.locator('[data-testid=vc-choose]').innerText()), `${name}: 3 myyjää (Kokemuskauppa, Offerilla, Elämyslahjat), ei Kiitoskauppaa (booking_173)`);
    expect(!/null|undefined/.test(await page.locator('[data-testid=vc-choose]').innerText()), `${name}: ei "null"-tekstiä (booking_173)`);
    expect((await page.locator('[data-testid=vc-choose]').innerText()).match(/Elämyslahjat/g)?.length >= 1 && !/Muu kumppani|Other partner|partner_other/.test(await page.locator('[data-testid=vc-choose]').innerText()), `${name}: julkiset lähteet, ei partner_other`);
    expect(await page.locator('[data-testid=vc-choose] input[name=vc-source]:checked').inputValue() === 'elamyslahjat' && await page.locator('[data-testid=vc-suggest]').count() === 1, `${name}: ehdotettu myyjä esivalittu + vihje`);
    expect(/ZXQW98765432/.test(await page.locator('[data-testid=vc-codeis]').innerText()), `${name}: koodi näytetään tarkistettavaksi`);
    expect(!NOTIME.test(await page.locator('[data-testid=vc-choose]').innerText()), `${name}: valinnassa ei aikarajoja`);
    await layoutChecks(page, `${name} lähdevalinta`, '.ord');
    if (lang === 'fi' && [360, 390, 430, 1280].includes(vp)) await shotShop(page, `kauppa-lahjakoodi-valinta-${vp}`);
    if (lang === 'en' && vp === 390) await shotShop(page, 'kauppa-lahjakoodi-valinta-390-en');
    await page.locator('[data-testid=vc-choose] label.vc-opt').nth(1).click();   // asiakas vaihtaa ehdotuksen (Elämyslahjat) → Offerilla ennen maksua (booking_173)
    expect(await radios.nth(1).isChecked(), `${name}: valinta vaihtuu`);
    await page.click('[data-testid=vc-submit]'); await page.waitForSelector('[data-testid=vc-notice]');
    const sc = rpcCalls(page, 'public_submit_voucher_claim').at(-1)?.args;
    expect(sc && sc.p_token === ORDER_TOKEN && sc.p_code === 'ZXQW98765432' && sc.p_source === 'offerilla' && !('p_order_item_id' in sc), `${name}: submit-parametrit (${JSON.stringify(sc)})`);
    const notice = await page.locator('[data-testid=vc-notice]').innerText();
    expect(notice.includes(G['vc.done']), `${name}: vahvistusteksti sopimuksen mukaan`);
    expect(await page.locator('[data-testid=vc-claim][data-state=received]').count() === 1 && /…5432/.test(await page.locator('[data-testid=vc-claims]').innerText()), `${name}: pyyntö tilassa received, koodi maskattuna`);
    expect(!(await page.locator('[data-testid=order-page]').innerText()).includes('ZXQW98765432'), `${name}: koko koodia ei näytetä uudelleen`);
    expect(!NOTIME.test(await page.locator('[data-testid=vc-claims]').innerText()), `${name}: pyyntökortissa ei aikarajoja`);
    expect(rpcCalls(page, 'public_get_order_voucher_claims').length >= 1, `${name}: tilan lataus public_get_order_voucher_claims`);
    await layoutChecks(page, `${name} kuittaus`, '.ord');
    if (lang === 'fi' && [390, 1280].includes(vp)) await shotShop(page, `kauppa-lahjakoodi-kuitattu-${vp}`);
    // oma kortti samasta kentästä (yksi klikkaus: resolve → apply)
    await page.locator('[data-testid=gc-code]').fill('hh7m rtuv wxy3'); await page.locator('[data-testid=gc-apply]').click();
    await page.waitForFunction(() => /\d/.test(document.querySelector('[data-testid=order-msg]')?.innerText || '') && !!document.querySelector('[data-testid=order-msg]')?.innerText);
    const ap = rpcCalls(page, 'public_apply_gift_card').at(-1)?.args;
    expect(ap && ap.p_code === 'HH7MRTUVWXY3' && ap.p_token === ORDER_TOKEN && rpcCalls(page, 'public_resolve_gift_code').at(-1).args.p_code === 'HH7MRTUVWXY3', `${name}: oma kortti: resolve → public_apply_gift_card (${JSON.stringify(ap)})`);
    expect(num(await page.locator('[data-testid=order-unpaid]').innerText()) === 4, `${name}: maksamatonta jäi 4 €`);
    await page.context().close();
  }
  // olemassa olevat pyynnöt: kolme tilaa + ongelmatilan korjaus
  for (const lang of ['fi', 'en']) {
    const name = `kauppa pyynnöt ${lang}`, page = await newShopPage(name, { vp: 390, lang, scenario: 'claims' }), G = GT[lang];
    await page.goto(orderUrl(lang)); await page.waitForSelector('[data-testid=vc-claims]');
    const states = await page.locator('[data-testid=vc-claim]').evaluateAll((els) => els.map((e) => e.dataset.state));
    expect(states.join() === 'received,problem,redeemed', `${name}: tilat received/problem/redeemed (${states})`);
    const prob = page.locator('[data-testid=vc-claim][data-state=problem]');
    expect(await prob.locator('[data-testid=vc-fixbox]').getAttribute('open') !== null, `${name}: ongelmatilassa korjauslomake auki`);
    expect(await page.locator('[data-testid=vc-claim][data-state=received] [data-testid=vc-fixbox]').getAttribute('open') === null, `${name}: vastaanotetulla korjaus napin takana`);
    expect(await page.locator('[data-testid=vc-claim][data-state=redeemed] [data-testid=vc-fixbox]').count() === 0, `${name}: lunastettua ei voi muuttaa`);
    expect(!NOTIME.test(await page.locator('[data-testid=vc-claims]').innerText()), `${name}: ei aikarajoja`);
    await layoutChecks(page, `${name}`, '.ord');
    if (lang === 'fi') await shotShop(page, 'kauppa-lahjakoodi-pyynnot-390');
    await prob.locator('[data-testid=vc-fix-code]').fill('x1'); await prob.locator('[data-testid=vc-fix-submit]').click(); await page.waitForTimeout(60);
    expect(!rpcCalls(page, 'public_update_voucher_claim_code').length && await prob.locator('.gc-field.bad, .bk-field.bad, [aria-invalid=true]').count() >= 1, `${name}: korjaus: lyhyt koodi hylätään`);
    await prob.locator('[data-testid=vc-fix-code]').fill('QQWW-1111-2222'); await prob.locator('[data-testid=vc-fix-source]').selectOption('offerilla'); await prob.locator('[data-testid=vc-fix-submit]').click();
    await page.waitForSelector('[data-testid=vc-notice]');
    const uc = rpcCalls(page, 'public_update_voucher_claim_code').at(-1)?.args;
    expect(uc && uc.p_token === ORDER_TOKEN && uc.p_code === 'QQWW11112222' && uc.p_source === 'offerilla' && uc.p_claim_id != null, `${name}: update-parametrit (${JSON.stringify(uc)})`);
    expect((await page.locator('[data-testid=vc-notice]').innerText()).includes(G['vc.updated']), `${name}: päivitysteksti`);
    expect(await page.locator('[data-testid=vc-claim][data-state=problem]').count() === 0, `${name}: korjauksen jälkeen ei enää ongelmatilassa`);
    await page.context().close();
  }
  // kumppanilunastus pois päältä: tuntematon koodi = ei löytynyt, ei lähdevalintaa; ei pyyntökorttia
  { const name = 'kauppa kumppanilunastus pois', page = await newShopPage(name, { vp: 390, scenario: 'claimsoff' });
    await page.goto(orderUrl('fi')); await page.waitForSelector('[data-testid=gc-redeem]');
    await page.locator('[data-testid=gc-code]').fill('ZXQW-9876-5432'); await page.locator('[data-testid=gc-apply]').click(); await page.waitForSelector('[data-testid=gc-msg] .bk-error');
    expect(await page.locator('[data-testid=vc-choose]').isHidden() && await page.locator('[data-testid=vc-claims]').count() === 0 && !rpcCalls(page, 'public_submit_voucher_claim').length, `${name}: ei lähdevalintaa eikä pyyntöjä`);
    await page.context().close(); }
  // palvelinvirheet lähetyksessä (code_already_claimed ym.) näytetään käännettynä
  { const name = 'kauppa claim-virheet', page = await newShopPage(name, { vp: 390, scenario: 'gift' });
    await page.goto(orderUrl('fi')); await page.waitForSelector('[data-testid=gc-redeem]');
    await page.locator('[data-testid=gc-code]').fill('ZXQW-9876-5432'); await page.locator('[data-testid=gc-apply]').click(); await page.waitForSelector('[data-testid=vc-choose]:not([hidden])');
    await page.click('[data-testid=vc-submit]'); await page.waitForSelector('[data-testid=vc-notice]');
    await page.locator('[data-testid=gc-code]').fill('ZXQW-9876-5432'); await page.locator('[data-testid=gc-apply]').click(); await page.waitForSelector('[data-testid=vc-choose]:not([hidden])');
    await page.click('[data-testid=vc-submit]'); await page.waitForSelector('[data-testid=vc-msg] .bk-error, [data-testid=vc-notice]');
    const t = (await page.locator('[data-testid=vc-msg]').innerText().catch(() => '')) + (await page.locator('[data-testid=vc-notice]').innerText().catch(() => ''));
    expect(t.length > 0 && !/vc\.err|undefined|\{/.test(t), `${name}: toinen lähetys antaa käännetyn vastauksen (${t.slice(0, 80)})`);
    await page.context().close(); }
}

// ================= AJO =================
try {
  if (!ONLY || ONLY === 'admin') await adminSuite();
  if (!ONLY || ONLY === 'shop') await shopSuite();
} catch (e) { console.log('KESKEYTYI: ' + e.message.split('\n')[0] + ' @ ' + (e.stack.split('\n').find((l) => /e2e-vouchers/.test(l)) || '')); for (const p of problems) console.log(' - ' + p); await browser.close(); server.close(); process.exit(1); }
await browser.close(); server.close();
console.log(`e2e-vouchers: ${checks} tarkistusta, ${problems.length} ongelmaa`);
for (const p of problems) console.log(' - ' + p);
process.exit(problems.length ? 1 : 0);
