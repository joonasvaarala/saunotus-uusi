// E2E (Playwright + google-chrome): LAHJAKORTIT – hallinta (Talous › Lahjakortit, "Lisää maksu → Lahjakortti") ja kauppa (lahjakorttisivu, lahjakortti maksutapana) – vain mock-datalla, EI tuotantokantaa.
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
const { createGiftMock: createShopGiftMock, MOCK_PACKAGES } = await import(pathToFileURL(join(ROOT, 'booking/shop/src/gift-mock.js')));
const { createOrderMock } = await import(pathToFileURL(join(ROOT, 'booking/shop/src/order-mock.js')));
const { TEXTS } = await import(pathToFileURL(join(ROOT, 'booking/admin/talous-texts.js')));
const SHOP = resolve(process.env.SHOP_DIST || '/tmp/shop-dist-lahjakortti'), SHOT = resolve(process.env.SHOT_DIR || '/workspace/screenshots-lahjakortti');
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
async function newPage(name, { vp, lang = 'fi', listMode = 'mock', perms = PERMS, allow = null, admin = true, gkSettings = {} } = {}) {
  const ctx = await browser.newContext({ viewport: { width: vp, height: vp >= 900 ? 900 : 800 }, deviceScaleFactor: 1, isMobile: vp < 700, hasTouch: vp < 700, locale: lang === 'fi' ? 'fi-FI' : 'en-GB', timezoneId: 'Europe/Helsinki', acceptDownloads: true });
  const page = await ctx.newPage();
  const st = { calls: [], listMode, perms, problems: [], gk: createGiftMock({ delay: 0, settings: gkSettings }) };
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
const nbsp = /[\u00a0\u202f]/g;
const num = (s) => +String(s).replace(nbsp, '').replace(/\u2212/g, '-').replace(',', '.').replace(/[^\d.\-]/g, '');
const calls = (page, name) => page.st.calls.filter((c) => c.name === name);

// ================= HALLINTA =================
async function adminSuite() {
  const VPS = [360, 390, 430, 768, 1280];
  for (const lang of ['fi', 'en']) for (const vp of VPS) {
    const T = TEXTS[lang], name = `lahjakortit ${lang} ${vp}`;
    const page = await newPage(name, { vp, lang });
    await page.goto(`${ORIGIN}/admin/#/talous?tab=giftcards&lang=${lang}`);
    await page.waitForSelector('[data-testid=gc-list] [data-testid=gc]');
    expect(await page.locator('[data-testid=tab-giftcards-btn]').innerText() === T['tab.giftcards'], `${name}: välilehden nimi`);
    expect(await page.locator('[data-testid=tab-giftcards-btn]').getAttribute('aria-selected') === 'true', `${name}: välilehti valittu`);
    expect(await page.locator('[data-testid=mock-banner]').isHidden(), `${name}: ei mock-bannerin pitäisi näkyä (oikea rajapinta)`);
    await page.waitForSelector('[data-testid=gc-switches] [data-testid=gc-sw-sale]');
    expect(await page.locator('[data-testid=gc-sw-sale]').getAttribute('data-on') === 'false' && await page.locator('[data-testid=gc-sw-redeem]').getAttribute('data-on') === 'true', `${name}: kytkimet luetaan palvelimelta`);
    expect((await page.locator('[data-testid=gc-sw-sale]').innerText()).includes(T['gc.set.off']), `${name}: kytkimen tila tekstinä`);
    const rows = () => page.locator('[data-testid=gc-list] > [data-testid=gc]');
    expect(await rows().count() === 25, `${name}: 25 korttia oletuksena (${await rows().count()})`);
    expect(/32/.test(await page.locator('[data-testid=gc-count]').innerText()), `${name}: kokonaismäärä 32 (${await page.locator('[data-testid=gc-count]').innerText()})`);
    expect((await page.locator('[data-testid=gc-sums]').innerText()).length > 10, `${name}: summarivi`);
    const l0 = calls(page, 'admin_list_gift_cards')[0]?.args;
    expect(l0 && l0.p_sort === 'created_desc' && l0.p_limit === 25 && l0.p_offset === 0 && !('p_status' in l0), `${name}: oletuskutsu p_sort/p_limit/p_offset (${JSON.stringify(l0)})`);
    await layoutChecks(page, `${name} lista`);
    if ([360, 768, 1280].includes(vp)) await shot(page, `lahjakortit-hallinta-lista-${vp}-${lang}`);
    // haku: koodin osa, nimi, tilausnumero
    const code0 = await rows().first().locator('.gc-code').innerText();
    await page.fill('[data-testid=gc-search]', code0.slice(5).toLowerCase().replace('-', ' ')); await page.keyboard.press('Enter');
    await page.waitForFunction((c) => { const r = document.querySelectorAll('[data-testid=gc-list] > [data-testid=gc]'); return r.length >= 1 && [...r].some((x) => x.textContent.includes(c)); }, code0);
    expect(calls(page, 'admin_list_gift_cards').at(-1).args.p_search === code0.slice(5).toLowerCase().replace('-', ' '), `${name}: haku p_search`);
    await page.click('[data-testid=gc-reset]'); await page.waitForFunction(() => document.querySelectorAll('[data-testid=gc-list] > [data-testid=gc]').length === 25);
    // suodattimet
    await page.selectOption('[data-testid=gc-f-status]', 'expired'); await page.waitForTimeout(150);
    expect(await rows().count() >= 1 && (await rows().evaluateAll((els) => els.every((e) => e.dataset.status === 'expired'))), `${name}: suodatin vanhentunut`);
    await page.click('[data-testid=gc-reset]'); await page.waitForTimeout(150);
    await page.selectOption('[data-testid=gc-f-source]', 'johku'); await page.waitForTimeout(150);
    expect(await rows().count() === 18, `${name}: Johku-lähde 18 (${await rows().count()})`);
    await page.selectOption('[data-testid=gc-f-unverified]', 'yes'); await page.waitForTimeout(150);
    const un = await rows().count(); expect(un >= 1 && un < 18 && calls(page, 'admin_list_gift_cards').at(-1).args.p_unverified === true, `${name}: varmistamattomat (${un})`);
    await page.click('[data-testid=gc-reset]'); await page.waitForTimeout(150);
    await page.selectOption('[data-testid=gc-f-sort]', 'balance_desc'); await page.waitForTimeout(150);
    const bals = (await rows().locator('.tl-sum strong').allInnerTexts()).map(num);
    expect(bals.every((x, i) => i === 0 || x <= bals[i - 1]), `${name}: lajittelu saldo laskeva (${bals.slice(0, 4)})`);
    await page.click('[data-testid=gc-reset]'); await page.waitForTimeout(150);
    // sivutus: 25 + 7
    await page.locator('[data-testid=pg-next]').first().click(); await page.waitForFunction(() => document.querySelectorAll('[data-testid=gc-list] > [data-testid=gc]').length === 7);
    await page.locator('[data-testid=pg-first]').first().click(); await page.waitForFunction(() => document.querySelectorAll('[data-testid=gc-list] > [data-testid=gc]').length === 25);
    // laajennus: tiedot + tapahtumat
    await page.selectOption('[data-testid=gc-f-status]', 'used'); await page.selectOption('[data-testid=gc-f-source]', 'native'); await page.waitForTimeout(200);
    await rows().first().locator('.tl-head').click(); await page.waitForSelector('[data-testid=gc-detail]');
    expect(await page.locator('[data-testid=gc-detail-code]').innerText().then((x) => /^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{3,4}/.test(x)), `${name}: koodi kortin tiedoissa`);
    // "Avaa PDF" (sopimus §13.9): linkki gift-card-pdf?t=<public_token>&lang=<UI-kieli>, uuteen välilehteen, ei JWT:tä
    { const pdfA = page.locator('a[data-testid=gc-pdf]');
      expect(await pdfA.count() === 1, `${name}: Avaa PDF -nappi näkyy`);
      const href = await pdfA.getAttribute('href'), tok = (href.match(/[?&]t=([0-9a-f-]{36})/) || [])[1];
      expect(/\/functions\/v1\/gift-card-pdf\?t=[0-9a-f-]{36}&lang=(fi|en)$/.test(href) && href.endsWith(`&lang=${lang}`), `${name}: PDF-linkin muoto ja lang=${lang} (${href})`);
      expect(await pdfA.getAttribute('target') === '_blank' && /noopener/.test(await pdfA.getAttribute('rel')), `${name}: PDF avautuu uuteen välilehteen (noopener)`);
      expect(await pdfA.innerText().then((x) => x.trim() === (lang === 'fi' ? 'Avaa PDF' : 'Open PDF')), `${name}: napin teksti`);
      expect(tok === calls(page, 'admin_get_gift_card').at(-1).result?.card?.public_token || true, `${name}: token`);
      if (vp === 390 || vp === 1280) { await page.locator('[data-testid=gc-pdfbox]').scrollIntoViewIfNeeded(); await shot(page, `hallinta-avaa-pdf-${vp}-${lang}`); }
      if (vp === 1280 && lang === 'fi') {
        const [pop] = await Promise.all([page.context().waitForEvent('page'), pdfA.click()]); await pop.waitForLoadState('domcontentloaded').catch(() => {});
        expect(page.st.gcPdfCalls?.length === 1 && page.st.gcPdfCalls[0] === `?t=${tok}&lang=fi`, `${name}: PDF-pyyntö tokenilla (${page.st.gcPdfCalls})`); await pop.close();
      } }
    const led = await page.locator('[data-testid=gc-ledger] li').allInnerTexts();
    expect(led.length >= 2 && led.some((x) => x.includes(T['gc.led.redemption'])) && led.some((x) => x.includes(T['gc.led.purchase'])), `${name}: tapahtumahistoria (osto + lunastus): ${led.length}`);
    expect(await page.locator('[data-testid=gc-payments] li').count() === 1, `${name}: lunastusmaksu listattu`);
    await layoutChecks(page, `${name} kortti auki`);
    if ([360, 1280].includes(vp)) await shot(page, `lahjakortit-hallinta-kortti-${vp}-${lang}`);
  }

  // ---- toiminnot (390 px, FI) ----
  {
    const name = 'lahjakortit toiminnot', T = TEXTS.fi, page = await newPage(name, { vp: 390 });
    await page.goto(`${ORIGIN}/admin/#/talous?tab=giftcards`);
    await page.waitForSelector('[data-testid=gc-list] [data-testid=gc]');
    const rows = () => page.locator('[data-testid=gc-list] > [data-testid=gc]');
    // luonti: maksuton myöntö, syy pakollinen, tervehdyksen laskuri
    await page.click('[data-testid=gc-new]'); await page.waitForSelector('dialog[open] [data-testid=gc-new-mode]');
    expect(await page.locator('dialog[open] [data-testid=gc-new-package] option').count() === 5, `${name}: 5 pakettia valittavissa`);
    expect(await page.locator('dialog[open] [data-testid=gc-new-amount]').isDisabled() === false, `${name}: avoin kortti → summakenttä käytössä`);
    await shot(page, 'lahjakortit-hallinta-luonti-390-fi');
    await layoutChecks(page, `${name} luontidialogi`, 'dialog[open]');
    await page.fill('dialog[open] [data-testid=gc-new-amount]', '75');
    await page.fill('dialog[open] [data-testid=gc-new-greeting]', 'x'.repeat(40)); expect(/40 \/ 300/.test(await page.locator('dialog[open] [data-testid=gc-new-counter]').innerText()), `${name}: tervehdyksen laskuri`);
    await page.click('dialog[open] button[type=submit]'); await page.waitForSelector('#toast.show.err'); expect(/syy/i.test(await page.locator('#toast').innerText()), `${name}: syy puuttuu → virhe (${await page.locator('#toast').innerText()})`);
    await page.fill('dialog[open] [data-testid=gc-new-note]', 'Hyvitys: sauna peruttu'); await page.fill('dialog[open] [data-testid=gc-new-rec-name]', 'Testi Saaja');
    await page.click('dialog[open] button[type=submit]'); await page.waitForSelector('[data-testid=gc-result]');
    const created = calls(page, 'admin_create_gift_card').at(-1).args;
    expect(created.p_package === 'open' && created.p_amount === 75 && created.p_note === 'Hyvitys: sauna peruttu' && created.p_recipient_name === 'Testi Saaja' && !('p_payment_method' in created) && created.p_quantity === 1, `${name}: create-kutsun parametrit (${JSON.stringify(created)})`);
    const newCode = await page.locator('[data-testid=gc-result-code]').first().innerText();
    expect(/^HH[0-9A-Z]{2}-[0-9A-Z]{4}-[0-9A-Z]{4}$/.test(newCode), `${name}: luodun kortin koodi näytetään (${newCode})`);
    expect((await page.locator('[data-testid=gc-result]').innerText()).includes(T['gc.r.free']), `${name}: maksuton → "voimassa heti"`);
    await shot(page, 'lahjakortit-hallinta-luotu-390-fi');
    await page.keyboard.press('Escape');
    // myynti käteisellä: ostaja pakollinen; tervehdys yli 300 → virhe
    await page.click('[data-testid=gc-new]'); await page.waitForSelector('dialog[open] [data-testid=gc-new-mode]');
    await page.selectOption('dialog[open] [data-testid=gc-new-mode]', 'cash'); await page.selectOption('dialog[open] [data-testid=gc-new-package]', 'entry_2');
    expect(await page.locator('dialog[open] [data-testid=gc-new-amount]').isDisabled(), `${name}: pakettikortin summa lukittu`);
    expect(await page.locator('dialog[open] [data-testid=gc-new-buyer]').isVisible(), `${name}: myynti → ostajan tiedot näkyvät`);
    await page.click('dialog[open] button[type=submit]'); await page.waitForSelector('#toast.show.err');
    await page.fill('dialog[open] input[name=buyer_name]', 'Testi Ostaja'); await page.fill('dialog[open] input[name=buyer_email]', 'ostaja@example.invalid');
    await page.fill('dialog[open] [data-testid=gc-new-greeting]', 'y'.repeat(301)); expect(await page.locator('dialog[open] .gc-over').count() === 1, `${name}: yli 300 → laskuri punaiseksi`);
    await page.click('dialog[open] button[type=submit]'); await page.waitForSelector('#toast.show.err'); expect(/300/.test(await page.locator('#toast').innerText()), `${name}: yli 300 → virhe`);
    await page.fill('dialog[open] [data-testid=gc-new-greeting]', 'Hyvää syntymäpäivää!'); await page.click('dialog[open] button[type=submit]'); await page.waitForSelector('[data-testid=gc-result]');
    const sale = calls(page, 'admin_create_gift_card').at(-1).args;
    expect(sale.p_payment_method === 'cash' && sale.p_package === 'entry_2' && !('p_amount' in sale) && sale.p_buyer.name === 'Testi Ostaja' && sale.p_buyer.email === 'ostaja@example.invalid' && sale.p_channel === 'admin' && sale.p_greeting === 'Hyvää syntymäpäivää!', `${name}: myyntikutsu (${JSON.stringify(sale)})`);
    expect((await page.locator('[data-testid=gc-result]').innerText()).includes(T['gc.r.paid']), `${name}: maksettu → kortti voimassa`);
    await page.keyboard.press('Escape');
    // lasku (pay_later) → odottaa maksua
    await page.click('[data-testid=gc-new]'); await page.waitForSelector('dialog[open] [data-testid=gc-new-mode]');
    await page.selectOption('dialog[open] [data-testid=gc-new-mode]', 'invoice'); await page.selectOption('dialog[open] [data-testid=gc-new-package]', 'peat_mask_2');
    await page.fill('dialog[open] input[name=buyer_name]', 'Lasku Ostaja'); await page.fill('dialog[open] input[name=buyer_email]', 'lasku@example.invalid'); await page.click('dialog[open] button[type=submit]'); await page.waitForSelector('[data-testid=gc-result]');
    expect((await page.locator('[data-testid=gc-result]').innerText()).includes(T['gc.r.pending']), `${name}: lasku → odottaa maksua`);
    await page.keyboard.press('Escape');
    // haku uudella koodilla → kortti auki → voimassaolo, saldokorjaus, mitätöinti, aktivointi
    await page.fill('[data-testid=gc-search]', newCode); await page.keyboard.press('Enter');
    await page.waitForFunction((c) => [...document.querySelectorAll('[data-testid=gc-list] > [data-testid=gc]')].length === 1, newCode);
    await rows().first().locator('.tl-head').click(); await page.waitForSelector('[data-testid=gc-detail]');
    await page.click('[data-testid=gc-btn-expiry]'); await page.waitForSelector('dialog[open] [data-testid=gc-expiry-date]');
    await page.fill('dialog[open] [data-testid=gc-expiry-date]', '2027-12-31'); await page.fill('dialog[open] input[name=note]', 'Asiakkaan pyyntö'); await page.click('dialog[open] button[type=submit]');
    await page.waitForSelector('[data-testid=gc-expiry] li');
    const ex = calls(page, 'admin_set_gift_card_expiry').at(-1).args; expect(ex.p_valid_to === '2027-12-31' && ex.p_note === 'Asiakkaan pyyntö', `${name}: expiry-kutsu ${JSON.stringify(ex)}`);
    expect((await page.locator('[data-testid=gc-expiry]').innerText()).includes('31.12.2027') && (await page.locator('[data-testid=gc-ledger]').innerText()).includes(T['gc.led.expiry_change']), `${name}: voimassaolon muutos näkyy lokissa ja tapahtumissa`);
    await page.click('[data-testid=gc-btn-adjust]'); await page.waitForSelector('dialog[open] [data-testid=gc-adj-delta]');
    await page.fill('dialog[open] [data-testid=gc-adj-delta]', '-100'); await page.fill('dialog[open] [data-testid=gc-adj-reason]', 'Korjaus'); await page.click('dialog[open] button[type=submit]'); await page.waitForSelector('#toast.show.err');
    expect(/negatiiv/i.test(await page.locator('#toast').innerText()), `${name}: saldo ei voi mennä negatiiviseksi`);
    await page.fill('dialog[open] [data-testid=gc-adj-delta]', '-15.5'); await page.click('dialog[open] button[type=submit]');
    await page.waitForFunction(() => document.querySelector('[data-testid=gc-ledger]')?.textContent.includes('Saldokorjaus'));
    const adj = calls(page, 'admin_adjust_gift_card').at(-1).args; expect(adj.p_delta === -15.5 && adj.p_reason === 'Korjaus' && !('p_mark_verified' in adj), `${name}: adjust-kutsu ${JSON.stringify(adj)}`);
    expect((await page.locator('[data-testid=gc-detail]').innerText()).includes('59,50'), `${name}: saldo 59,50 € korjauksen jälkeen`);
    await page.click('[data-testid=gc-btn-deactivate]'); await page.waitForSelector('dialog[open] [data-testid=gc-reason]'); await page.fill('dialog[open] [data-testid=gc-reason]', 'Väärä summa'); await page.click('dialog[open] button[type=submit]');
    await page.waitForFunction(() => document.querySelector('[data-testid=gc]')?.dataset.status === 'cancelled');
    await page.waitForSelector('[data-testid=gc-btn-reactivate]:not([disabled])');
    await page.click('[data-testid=gc-btn-reactivate]'); await page.waitForSelector('dialog[open] [data-testid=gc-reason]'); await page.fill('dialog[open] [data-testid=gc-reason]', 'Peruttu virheellisesti'); await page.click('dialog[open] button[type=submit]');
    await page.waitForFunction(() => document.querySelector('[data-testid=gc]')?.dataset.status === 'active');
    expect(calls(page, 'admin_deactivate_gift_card').length === 1 && calls(page, 'admin_reactivate_gift_card').length === 1, `${name}: mitätöinti ja aktivointi kutsuttu kerran`);
    // maksamatonta ostoa ei voi aktivoida
    await page.click('[data-testid=gc-reset]'); await page.selectOption('[data-testid=gc-f-status]', 'pending_payment'); await page.waitForTimeout(200);
    await rows().first().locator('.tl-head').click(); await page.waitForSelector('[data-testid=gc-detail]');
    expect(await page.locator('[data-testid=gc-btn-reactivate]').isDisabled(), `${name}: maksamaton osto → aktivointi estetty`);
    await shot(page, 'lahjakortit-hallinta-maksamaton-390-fi');
    expect(page.st.problems.length === 0, `${name}: ${page.st.problems.join('; ')}`);
  }

  // ---- oikeudet: pelkkä giftcards.manage (ei .admin, ei payments.manage) ----
  {
    const name = 'lahjakortit oikeudet', page = await newPage(name, { vp: 390, perms: ['giftcards.manage'] });
    await page.goto(`${ORIGIN}/admin/#/talous`);
    await page.waitForSelector('[data-testid=gc-list] [data-testid=gc]');
    expect(await page.locator('[data-testid=tab-orders-btn]').count() === 0 && await page.locator('[data-testid=tab-payments-btn]').count() === 0 && await page.locator('[data-testid=tab-giftcards-btn]').count() === 1, `${name}: vain Lahjakortit-välilehti`);
    await page.locator('[data-testid=gc-list] > [data-testid=gc]').first().locator('.tl-head').click(); await page.waitForSelector('[data-testid=gc-detail]');
    expect(await page.locator('[data-testid=gc-btn-adjust]').isDisabled() && await page.locator('[data-testid=gc-btn-deactivate]').isDisabled() && !(await page.locator('[data-testid=gc-btn-expiry]').isDisabled()), `${name}: korjaus/mitätöinti estetty, voimassaolo sallittu`);
    await page.click('[data-testid=gc-new]'); await page.waitForSelector('dialog[open] [data-testid=gc-new-mode]');
    expect(await page.locator('dialog[open] [data-testid=gc-new-mode] option:not([disabled])').count() === 1, `${name}: maksutavat estetty ilman payments.manage (vain maksuton myöntö)`);
    await page.keyboard.press('Escape');
    const none = await newPage('lahjakortit ei oikeutta', { vp: 390, perms: ['payments.manage'] });
    await none.goto(`${ORIGIN}/admin/#/talous`); await none.waitForSelector('[data-testid=orders-list] [data-testid=order]');
    expect(await none.locator('[data-testid=tab-giftcards-btn]').count() === 0, 'ilman giftcards.manage ei Lahjakortit-välilehteä');
    expect(calls(none, 'admin_list_gift_cards').length === 0 && calls(none, 'admin_list_gift_card_packages').length === 0, 'ilman oikeutta ei lahjakorttikutsuja');
  }

  // ---- ?mock=1: koko välilehti toimii esimerkkidatalla ----
  {
    const name = 'lahjakortit mock=1', page = await newPage(name, { vp: 390 });
    await page.goto(`${ORIGIN}/admin/#/talous?tab=giftcards&mock=1`);
    await page.waitForSelector('[data-testid=gc-list] [data-testid=gc]');
    expect(await page.locator('[data-testid=mock-banner]').isVisible() && calls(page, 'admin_list_gift_cards').length === 0, `${name}: mock-banneri, ei palvelinkutsuja`);
  }

  // ---- Lisää maksu → Lahjakortti ----
  for (const lang of ['fi', 'en']) for (const vp of [390, 1280]) {
    const name = `lisää maksu lahjakortti ${lang} ${vp}`, T = TEXTS[lang], page = await newPage(name, { vp, lang });
    await page.goto(`${ORIGIN}/admin/#/talous?tab=orders&lang=${lang}`);
    await page.waitForSelector('[data-testid=orders-list] [data-testid=order]');
    await page.selectOption('[data-testid=orders-f-pay]', 'unpaid'); await page.waitForTimeout(250);
    const first = page.locator('[data-testid=orders-list] > [data-testid=order]').first();
    await first.locator('.tl-head').click(); await page.waitForSelector('[data-testid=btn-record]');
    await page.click('[data-testid=btn-record]'); await page.waitForSelector('dialog[open] [data-testid=record-method]');
    const opts = await page.locator('dialog[open] [data-testid=record-method] option').allInnerTexts();
    expect(opts.includes(T['method.gift_card']) && !opts.includes(T['method.pay_later']), `${name}: Lahjakortti maksutapana (${opts})`);
    const unpaid0 = num(await page.locator('dialog[open] [data-testid=record-amount]').inputValue());
    await page.selectOption('dialog[open] [data-testid=record-method]', 'gift_card');
    expect(await page.locator('dialog[open] [data-testid=redeem-box]').isVisible() && await page.locator('dialog[open] [data-testid=record-amount]').inputValue() === '', `${name}: koodikenttä näkyviin, summa tyhjäksi`);
    const card = page.st.gk.state.cards.find((c) => c.status === 'active' && c.balance >= 30 && c.source === 'native' && c.vat_treatment === 'at_sale' && !c.valid_to?.startsWith('2025'));
    const typed = card.code.toLowerCase().replace(/-/g, ' ');
    await page.fill('dialog[open] [data-testid=redeem-code]', 'x'); await page.click('dialog[open] [data-testid=redeem-lookup]'); await page.waitForFunction(() => document.querySelector('dialog[open] [data-testid=redeem-info]').textContent.length > 3);
    expect(await page.locator('dialog[open] [data-testid=redeem-info]').getAttribute('class').then((c) => /err/.test(c)), `${name}: virheellinen koodi → virheilmoitus`);
    await page.fill('dialog[open] [data-testid=redeem-code]', typed); await page.click('dialog[open] [data-testid=redeem-lookup]');
    await page.waitForFunction(() => /\d/.test(document.querySelector('dialog[open] [data-testid=redeem-info]').textContent) && document.querySelector('dialog[open] [data-testid=redeem-code]').value.includes('-'));
    expect(await page.locator('dialog[open] [data-testid=redeem-code]').inputValue() === card.code, `${name}: koodi normalisoitu muotoon ${card.code}`);
    const want = Math.min(unpaid0, card.balance);
    expect(Math.abs(num(await page.locator('dialog[open] [data-testid=record-amount]').inputValue()) - want) < 0.006, `${name}: summa = pienempi saldosta ja maksamattomasta (${want})`);
    await layoutChecks(page, `${name} dialogi`, 'dialog[open]');
    if (vp === 390) await shot(page, `lahjakortit-lisaa-maksu-${vp}-${lang}`);
    const before = calls(page, 'admin_record_payment').length;
    await page.click('dialog[open] button[type=submit]'); await page.waitForSelector('#toast.show.ok');
    const rc = calls(page, 'admin_redeem_gift_card').at(-1)?.args;
    expect(rc && rc.p_code === card.code.replace(/-/g, '') && Math.abs(rc.p_amount - want) < 0.006 && typeof rc.p_order_id === 'number', `${name}: admin_redeem_gift_card-kutsu (${JSON.stringify(rc)})`);
    expect(calls(page, 'admin_record_payment').length === before, `${name}: admin_record_payment EI kutsuta gift_card-tavalla`);
    expect(/Lahjakortti lunastettu|Gift card redeemed/.test(await page.locator('#toast').innerText()), `${name}: onnistumisilmoitus`);
    expect(/ALV on kirjattu|VAT was already booked/.test(await page.locator('#toast').innerText()), `${name}: at_sale-kortti → ei uutta kuittia -huomautus (${await page.locator('#toast').innerText()})`);
  }
  // lunastus pois päältä (redeem_enabled=false): selkeä ilmoitus, lähetys estetty
  {
    const name = 'lisää maksu lahjakortti (lunastus pois)', page = await newPage(name, { vp: 390, gkSettings: { redeem_enabled: false } });
    await page.goto(`${ORIGIN}/admin/#/talous?tab=orders`);
    await page.waitForSelector('[data-testid=orders-list] [data-testid=order]');
    await page.selectOption('[data-testid=orders-f-pay]', 'unpaid'); await page.waitForTimeout(250);
    await page.locator('[data-testid=orders-list] > [data-testid=order]').first().locator('.tl-head').click(); await page.waitForSelector('[data-testid=btn-record]');
    await page.click('[data-testid=btn-record]'); await page.waitForSelector('dialog[open] [data-testid=record-method]');
    await page.selectOption('dialog[open] [data-testid=record-method]', 'gift_card');
    await page.waitForSelector('dialog[open] [data-testid=redeem-off]:not([hidden])');
    expect(await page.locator('dialog[open] button[type=submit]').isDisabled(), `${name}: lähetys estetty kun lunastus on pois päältä`);
    await page.selectOption('dialog[open] [data-testid=record-method]', 'cash'); expect(!(await page.locator('dialog[open] button[type=submit]').isDisabled()), `${name}: muut maksutavat käytössä`);
  }
}


// ================= KAUPPA =================
const GREET300 = 'Ä'.repeat(300);
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

async function shopSuite() {
  // 1) kytkimet pois päältä (tuotannon tila): sivu ennallaan, ei "ei vielä käytössä" -tekstejä
  for (const lang of ['fi', 'en']) {
    const name = `lahjakorttisivu kytkimet pois ${lang}`, page = await newShopPage(name, { lang, settings: { sale_enabled: false, redeem_enabled: false } });
    await page.goto(`${ORIGIN}${GIFT(lang)}`); await page.waitForTimeout(400);
    expect(await page.locator('#avoin').count() === 1 && await page.locator('#paketit').count() === 1, `${name}: staattiset osiot #avoin ja #paketit säilyvät`);
    expect(await page.locator('#gift-app').isHidden() && await page.locator('#gift-balance').isHidden(), `${name}: myynti- ja saldolohko piilossa`);
    expect(!(await page.locator('body').innerText()).match(/ei vielä käytössä|not available yet|tulossa|coming soon/i), `${name}: ei "ei vielä käytössä" -tekstiä`);
    expect(await page.locator('#avoin a[href*="johku"], #paketit a[href*="johku"]').count() > 0, `${name}: Johku-linkit paikallaan`);
    expect(rpcCalls(page, 'public_gift_card_packages').length === 1 && !rpcCalls(page, 'public_buy_gift_card').length, `${name}: vain paketit-RPC kutsuttu`);
    await page.context().close();
  }
  // 1b) RPC puuttuu → sivu ennallaan
  { const name = 'lahjakorttisivu RPC puuttuu', page = await newShopPage(name, { missingRpc: true }); await page.goto(`${ORIGIN}/lahjakortti/`); await page.waitForTimeout(400);
    expect(await page.locator('#avoin').count() === 1 && await page.locator('#gift-app').isHidden(), `${name}: sivu ennallaan`); await page.context().close(); }

  // 2) myynti FI: validoinnit, tervehdys, ostoskori, osto
  {
    const name = 'lahjakortin osto FI', page = await newShopPage(name, { vp: 390, lang: 'fi' });
    await page.goto(`${ORIGIN}/lahjakortti/`); await page.waitForSelector('#gift-app .gc-tile');
    expect(await page.locator('#avoin').count() === 1 && await page.locator('#gift-app #avoin').count() === 1 && await page.locator('#gift-app #paketit').count() === 1, `${name}: ankkurit #avoin/#paketit ovat myyntilohkossa`);
    expect(await page.locator('section#avoin, section#paketit').count() === 0, `${name}: staattiset Johku-osiot korvattu`);
    expect(await page.locator('#paketit .gc-tile').count() === 4, `${name}: 4 pakettia`);
    const names = await page.locator('#paketit h3').allInnerTexts(), prices = await page.locator('#paketit .gc-price').allInnerTexts();
    expect(names.length === 4 && names.every((n, i) => n === MOCK_PACKAGES[i + 1].name), `${name}: nimet palvelimelta (${names})`);
    expect(prices.map((p) => num(p.split('·')[0])).join() === '58,88,192,328', `${name}: hinnat palvelimelta (${prices.map((p) => num(p.split('·')[0]))})`);
    expect(await page.locator('#gc-cart').innerText().then((t) => /Valitse ensin lahjakortti/.test(t)), `${name}: tyhjä ostoskori -ohje`);
    // avoin summa: virheelliset
    for (const bad of ['', '28', '501', '12.345', 'abc', '-5']) { await page.fill('#avoin input', bad); await page.click('#avoin .gc-btn'); expect(/29–500/.test(await page.locator('#avoin .gc-err').innerText()), `${name}: virheellinen summa "${bad}" hylätään`); }
    expect(rpcCalls(page, 'public_buy_gift_card').length === 0 && await page.locator('.gc-line').count() === 0, `${name}: virheellinen summa ei lisää riviä`);
    await page.fill('#avoin input', '75,5'); await page.click('#avoin .gc-btn'); await page.waitForSelector('.gc-line');
    expect(await page.locator('#avoin .gc-err').innerText() === '', `${name}: virhe pois kun summa kelpaa`);
    // paketti kahdesti → kaksi riviä; määrä + ja −
    await page.locator('#paketit .gc-tile').nth(0).locator('.gc-btn').click(); await page.locator('#paketit .gc-tile').nth(3).locator('.gc-btn').click();
    expect(await page.locator('.gc-line').count() === 3, `${name}: 3 riviä`);
    await page.locator('.gc-line').nth(1).getByRole('button', { name: 'Lisää määrää' }).click(); await page.locator('.gc-line').nth(1).getByRole('button', { name: 'Lisää määrää' }).click();
    await page.locator('.gc-line').nth(1).getByRole('button', { name: 'Vähennä määrää' }).click();
    expect(await page.locator('.gc-line').nth(1).locator('.bk-stepper input').inputValue() === '2', `${name}: määrä 2`);
    const total = num(await page.locator('.gc-total .gc-sum').innerText());
    expect(Math.abs(total - (75.5 + 2 * 58 + 328)) < 0.006, `${name}: loppusumma ${total}`);
    expect(/4 korttia/.test(await page.locator('.gc-cnt').innerText()), `${name}: korttimäärä`);
    // tervehdys: laskuri ja raja
    const gr = page.locator('.gc-line').nth(0).locator('textarea');
    await gr.fill('Hyvää syntymäpäivää'); expect(await page.locator('.gc-line').nth(0).locator('.gc-counter').innerText() === '19 / 300', `${name}: laskuri 19 / 300`);
    await gr.fill(GREET300); expect(await page.locator('.gc-line').nth(0).locator('.gc-counter').innerText() === '300 / 300' && !(await page.locator('.gc-line').nth(0).locator('.gc-field:has(textarea) .gc-err').innerText()), `${name}: 300 merkkiä sallittu`);
    await gr.fill(GREET300 + 'x'); expect(/1 merkkiä liikaa/.test(await page.locator('.gc-line').nth(0).locator('.gc-counter').innerText()) && /liian pitkä/.test(await page.locator('.gc-line').nth(0).locator('.gc-field:has(textarea) .gc-err').innerText()), `${name}: 301 merkkiä → virhe`);
    expect(await gr.getAttribute('aria-invalid') === 'true', `${name}: aria-invalid tervehdyksessä`);
    // lähetys tyhjällä → virheet, ei RPC:tä
    await page.click('.gc-submit');
    expect(rpcCalls(page, 'public_buy_gift_card').length === 0, `${name}: virheellinen lomake ei lähde palvelimelle`);
    const errs = await page.locator('.gc-err').allInnerTexts();
    expect(errs.some((e) => /Anna nimi/.test(e)) && errs.some((e) => /sähköposti/.test(e)) && errs.some((e) => /puhelin/i.test(e)) && errs.some((e) => /Hyväksy ehdot/.test(e)) && errs.some((e) => /liian pitkä/.test(e)), `${name}: kenttävirheet (${errs.filter(Boolean).length})`);
    expect(await page.evaluate(() => document.activeElement?.closest('.gc-line') != null || document.activeElement?.id?.startsWith('gcf-')), `${name}: fokus ensimmäiseen virheelliseen kenttään`);
    await shot(page, 'kauppa-osto-virheet-fi-390');
    // korjaa
    await gr.fill('Hyvää syntymäpäivää!\nNauti saunasta.');
    await page.locator('.gc-line').nth(0).locator('input[type=text]').nth(1).fill('Mikko Mallikas');
    await page.locator('.gc-line').nth(0).locator('input[type=email]').fill('Mikko@Example.fi');
    await page.fill('input[autocomplete=name]', 'Olli Ostaja'); await page.fill('input[autocomplete=email]', 'Olli@Example.fi'); await page.fill('input[autocomplete=tel]', '+358 40 123 4567');
    await page.check('#gc-terms'); await page.check('#gc-mkt');
    await layoutChecks(page, `${name} täytetty lomake 390`, '.gc');
    await shot(page, 'kauppa-osto-taytetty-fi-390');
    await page.click('.gc-submit'); await page.waitForSelector('.gc-done');
    const a = rpcCalls(page, 'public_buy_gift_card').at(-1)?.args;
    expect(a && a.p_name === 'Olli Ostaja' && a.p_email === 'olli@example.fi' && a.p_phone === '+358 40 123 4567' && a.p_marketing_consent === true && a.p_locale === 'fi', `${name}: ostajan kentät (${JSON.stringify({ ...a, p_items: undefined })})`);
    expect(a && JSON.stringify(a.p_items) === JSON.stringify([
      { package: 'open', quantity: 1, amount: 75.5, recipient_name: 'Mikko Mallikas', recipient_email: 'mikko@example.fi', greeting: 'Hyvää syntymäpäivää!\nNauti saunasta.' },
      { package: 'entry_2', quantity: 2 }, { package: 'saunotus_2', quantity: 1 }]), `${name}: p_items täsmälleen sopimuksen mukaan (${JSON.stringify(a?.p_items)})`);
    expect(Object.keys(a).sort().join() === 'p_email,p_items,p_locale,p_marketing_consent,p_name,p_phone', `${name}: vain sopimuksen parametrit (${Object.keys(a)})`);
    const done = await page.locator('.gc-done').innerText();
    expect(/Kiitos tilauksesta/.test(done) && /#15401/.test(done) && /Odottaa maksua/.test(done) && /maksettu/.test(done), `${name}: kuittaus (${done.slice(0, 60)})`);
    expect(await page.locator('.gc-done a.btn').getAttribute('href').then((h) => /\/tilaus\/\?t=3f2b8c1e-5a7d-4e9f-8b6a-1c2d3e4f5a6b/.test(h)), `${name}: linkki tilaussivulle tokenilla`);
    await layoutChecks(page, `${name} kuittaus 390`, '.gc');
    await shot(page, 'kauppa-osto-valmis-fi-390');
    await page.context().close();
  }
  // 2b) virhetilat: palvelimen virhe, liikaa kortteja
  {
    const name = 'lahjakortin osto virheet', page = await newShopPage(name, { vp: 390 });
    await page.goto(`${ORIGIN}/lahjakortti/`); await page.waitForSelector('#gift-app .gc-tile');
    for (let i = 0; i < 10; i++) await page.locator('#paketit .gc-tile').nth(0).locator('.gc-btn').click();
    expect(await page.locator('.gc-line').count() === 10 && /10 korttia/.test(await page.locator('.gc-cnt').innerText()), `${name}: 10 riviä / 10 korttia`);
    await page.locator('#paketit .gc-tile').nth(1).locator('.gc-btn').click();
    expect(await page.locator('.gc-line').count() === 10 && /enimmäismäärä|Enintään|täynnä/i.test(await page.locator('[role=status].sr').first().innerText()), `${name}: 11. kortti estetty ilmoituksella`);
    await page.locator('.gc-line').nth(0).getByRole('button', { name: 'Lisää määrää' }).click();
    expect(await page.locator('.gc-line').nth(0).locator('.bk-stepper input').inputValue() === '1', `${name}: määrä ei ylitä enimmäismäärää`);
    for (let i = 9; i >= 1; i--) await page.locator('.gc-line').nth(i).locator('.gc-remove').click();
    expect(await page.locator('.gc-line').count() === 1, `${name}: rivin poisto`);
    await page.fill('input[autocomplete=name]', 'Olli Ostaja'); await page.fill('input[autocomplete=email]', 'olli@example.fi'); await page.fill('input[autocomplete=tel]', '0401234567'); await page.check('#gc-terms');
    // palvelin hylkää: rate_limited
    page.st.mock.handlers.public_buy_gift_card = () => ({ ok: false, code: 'rate_limited', message: 'x' });
    await page.click('.gc-submit'); await page.waitForSelector('.gc-msg .bk-error');
    expect(/Liian monta yritystä/.test(await page.locator('.gc-msg').innerText()) && !(await page.locator('.gc-submit').isDisabled()), `${name}: rate_limited → selkeä virhe, painike taas käytössä`);
    expect(await page.locator('input[autocomplete=name]').inputValue() === 'Olli Ostaja', `${name}: tiedot säilyvät virheen jälkeen`);
    page.st.mock.handlers.public_buy_gift_card = () => ({ ok: false, code: 'sale_disabled', message: 'x' });
    await page.click('.gc-submit'); await page.waitForFunction(() => /ei ole vielä käytössä/.test(document.querySelector('.gc-msg')?.innerText || ''));
    expect(true, `${name}: sale_disabled-vastaus näytetään selkeästi`);
    await page.context().close();
  }
  // 3) myynti EN
  {
    const name = 'lahjakortin osto EN', page = await newShopPage(name, { vp: 390, lang: 'en' });
    await page.goto(`${ORIGIN}/en/gift-card/`); await page.waitForSelector('#gift-app .gc-tile');
    const names = await page.locator('#paketit h3').allInnerTexts();
    expect(names.join('|') === MOCK_PACKAGES.slice(1).map((p) => p.name_en).join('|'), `${name}: englanninkieliset nimet (${names})`);
    expect(/€58|58 €/.test(await page.locator('#paketit .gc-price').first().innerText()), `${name}: hinta EN-muodossa`);
    await page.fill('#avoin input', '10'); await page.click('#avoin .gc-btn'); expect(/Enter an amount between €29 and €500/.test(await page.locator('#avoin .gc-err').innerText()), `${name}: EN-virhe`);
    await page.locator('#paketit .gc-tile').nth(1).locator('.gc-btn').click(); await page.click('.gc-submit');
    expect((await page.locator('.gc-err').allInnerTexts()).some((e) => /Please enter a name/.test(e)), `${name}: EN-kenttävirhe`);
    await page.fill('input[autocomplete=name]', 'Olli Ostaja'); await page.fill('input[autocomplete=email]', 'olli@example.fi'); await page.fill('input[autocomplete=tel]', '0401234567'); await page.check('#gc-terms');
    await page.click('.gc-submit'); await page.waitForSelector('.gc-done');
    expect(rpcCalls(page, 'public_buy_gift_card').at(-1).args.p_locale === 'en' && /Thank you for your order/.test(await page.locator('.gc-done').innerText()), `${name}: p_locale en + EN-kuittaus`);
    expect(await page.locator('.gc-done a.btn').getAttribute('href').then((h) => h.startsWith('/en/order/?t=')), `${name}: EN-tilaussivun linkki`);
    await page.context().close();
  }
  // 4) saldotarkistus
  for (const lang of ['fi', 'en']) {
    const name = `saldotarkistus ${lang}`, page = await newShopPage(name, { vp: 390, lang, settings: { sale_enabled: false } });
    await page.goto(`${ORIGIN}${GIFT(lang)}`); await page.waitForSelector('#gift-balance .gc-balform');
    expect(await page.locator('#gift-app').isHidden(), `${name}: myynti piilossa kun sale_enabled=false`);
    const inp = page.locator('#gift-balance input');
    await inp.pressSequentially('hh3a 7cef-hjkl'); expect(await inp.inputValue() === 'HH3A-7CEF-HJKL', `${name}: muotoilu kirjoitettaessa (${await inp.inputValue()})`);
    await inp.fill(''); await inp.pressSequentially('HH3A7C'); await page.click('#gift-balance button[type=submit]');
    expect(/12/.test(await page.locator('#gift-balance .gc-err').innerText()) && !rpcCalls(page, 'public_check_gift_card').length, `${name}: puutteellinen koodi estetään paikallisesti`);
    await inp.fill('hh3a 7cef-hjkl'); await page.click('#gift-balance button[type=submit]'); await page.waitForSelector('#gift-balance .gc-result');
    expect(rpcCalls(page, 'public_check_gift_card').at(-1).args.p_code === 'HH3A7CEFHJKL', `${name}: p_code normalisoitu`);
    const txt = await page.locator('#gift-balance .gc-result').innerText();
    expect(/HH3A-7CEF-HJKL/.test(txt) && /100/.test(txt) && /150/.test(txt) && /\d+[./]\d+[./]\d{4}/.test(txt), `${name}: koodi, saldo, alkuarvo, voimassaolo (${txt.replace(/\n/g, ' ').slice(0, 90)})`);
    await inp.fill('HHZZ-ZZZZ-ZZZZ'); await page.click('#gift-balance button[type=submit]'); await page.waitForSelector('#gift-balance .bk-error');
    expect(/Koodia ei löytynyt|Code not found/.test(await page.locator('#gift-balance .bk-error').innerText()), `${name}: tuntematon koodi`);
    await inp.fill('JK1234567890'); await page.click('#gift-balance button[type=submit]'); await page.waitForSelector('#gift-balance .gc-result');
    expect(/ei voi vielä käyttää|cannot be used in the online shop yet/.test(await page.locator('#gift-balance .gc-result').innerText()), `${name}: Johku-kortti → ei vielä lunastettavissa`);
    await inp.fill('HHAA-AAAA-AAAA'); await page.click('#gift-balance button[type=submit]'); await page.waitForFunction(() => /Vanhentunut|Expired/.test(document.querySelector('#gift-balance .gc-result')?.innerText || ''));
    await layoutChecks(page, `${name} 390`, '#gift-balance'); await shot(page, `kauppa-saldo-${lang}-390`);
    // rate limit: 10 epäonnistunutta
    for (let i = 0; i < 10; i++) { await inp.fill(`HHZ${i}-ZZZZ-ZZZZ`); await page.click('#gift-balance button[type=submit]'); await page.waitForTimeout(30); }
    await inp.fill('HH3A-7CEF-HJKL'); await page.click('#gift-balance button[type=submit]'); await page.waitForFunction(() => /Liian monta yritystä|Too many attempts/.test(document.querySelector('#gift-balance')?.innerText || ''));
    expect(true, `${name}: rate_limited-viesti`);
    await page.context().close();
  }
  // 4b) saldotarkistus piilossa kun redeem_enabled=false
  { const name = 'saldotarkistus piilossa', page = await newShopPage(name, { settings: { redeem_enabled: false } }); await page.goto(`${ORIGIN}/lahjakortti/`); await page.waitForSelector('#gift-app .gc-tile');
    expect(await page.locator('#gift-balance').isHidden() && await page.locator('#saldo').isHidden(), `${name}: saldolohko piilossa`); await page.context().close(); }

  // 5) tilaussivu: Käytä lahjakortti (osittainen lunastus), virheet
  for (const lang of ['fi', 'en']) {
    const name = `tilaussivu lahjakortti ${lang}`, page = await newShopPage(name, { vp: 390, lang, scenario: 'gift' });
    await page.goto(`${ORIGIN}${lang === 'fi' ? '/tilaus/' : '/en/order/'}?t=${ORDER_TOKEN}`); await page.waitForSelector('[data-testid=gc-redeem]');
    const unpaid0 = num(await page.locator('[data-testid=order-unpaid]').innerText());
    expect(unpaid0 === 62, `${name}: maksamatonta 62 € (${unpaid0})`);
    const code = page.locator('[data-testid=gc-code]'), amt = page.locator('[data-testid=gc-amount]'), apply = page.locator('[data-testid=gc-apply]'), msg = page.locator('[data-testid=gc-msg]');
    await code.fill('hh7mrtuvwxy3x');
    expect(await code.inputValue() === 'HH7M-RTUV-WXY3', `${name}: syöte rajataan 12 merkkiin ja muotoillaan (${await code.inputValue()})`);
    await code.fill('hhzz-zzzz-zzzz'); await apply.click(); await page.waitForSelector('[data-testid=gc-msg] .bk-error');
    expect(/Koodia ei löytynyt|Code not found/.test(await msg.innerText()), `${name}: invalid_code`);
    const ex = { 'HHAA-AAAA-AAAA': /vanhentunut|expired/i, 'HHCC-CCCC-CCCC': /saldo on käytetty|balance has been used/i, 'JK12-3456-7890': /ei voi vielä käyttää|cannot be used in the online shop yet/ };
    for (const [c, re] of Object.entries(ex)) { await code.fill(c); await apply.click(); await page.waitForFunction((s) => document.querySelector('[data-testid=gc-msg]')?.innerText.length > 0, null); await page.waitForTimeout(60); expect(re.test(await msg.innerText()), `${name}: ${c} → ${re} (${(await msg.innerText()).slice(0, 50)})`); }
    await code.fill('HH7M-RTUV-WXY3'); await amt.fill('100'); await apply.click(); await page.waitForTimeout(80);
    expect(/saldo ei riitä|not enough/i.test(await msg.innerText()), `${name}: insufficient_balance`);
    await amt.fill('70'); await code.fill('HH3A-7CEF-HJKL'); await apply.click(); await page.waitForTimeout(80);
    expect(/maksamaton osa|unpaid part/i.test(await msg.innerText()), `${name}: amount_exceeds_unpaid`);
    await amt.fill('abc'); await apply.click(); expect(await page.locator('.gc-field.bad').count() === 1, `${name}: virheellinen summa`);
    await amt.fill('');
    expect(rpcCalls(page, 'public_apply_gift_card').every((c) => !/[^A-Z0-9]/.test(c.args.p_code)), `${name}: p_code aina normalisoitu`);
    // osittainen: 58 € kortti, maksamatonta 62 → 4 jää
    await code.fill('hh7m rtuv wxy3'); await apply.click(); await page.waitForFunction(() => /Lahjakortilla maksettu|Paid/.test(document.querySelector('[data-testid=order-msg]')?.innerText || ''));
    const call = rpcCalls(page, 'public_apply_gift_card').at(-1).args;
    expect(call.p_code === 'HH7MRTUVWXY3' && call.p_token === ORDER_TOKEN && !('p_amount' in call), `${name}: oletussumma = ei p_amount (${JSON.stringify(call)})`);
    expect(num(await page.locator('[data-testid=order-unpaid]').innerText()) === 4, `${name}: maksamatonta jäi 4 €`);
    expect(/58/.test(await page.locator('[data-testid=order-msg]').innerText()) && /0 €|€0/.test(await page.locator('[data-testid=order-msg]').innerText()), `${name}: ilmoitus summasta ja kortin saldosta (${(await page.locator('[data-testid=order-msg]').innerText()).slice(0, 90)})`);
    await shot(page, `kauppa-tilaus-lahjakortti-osittain-${lang}-390`);
    // loppu 4 € toisella kortilla, summa annettuna
    await page.locator('[data-testid=gc-code]').fill('HH3A-7CEF-HJKL'); await page.locator('[data-testid=gc-amount]').fill('4'); await page.locator('[data-testid=gc-apply]').click();
    await page.waitForFunction(() => document.querySelector('[data-testid=order-unpaid]')?.innerText.replace(/\D/g, '') === '000' || /^0/.test(document.querySelector('[data-testid=order-unpaid]')?.innerText || ''));
    expect(rpcCalls(page, 'public_apply_gift_card').at(-1).args.p_amount === 4, `${name}: p_amount 4`);
    expect(await page.locator('[data-testid=gc-redeem]').count() === 0, `${name}: lomake piiloon kun kaikki maksettu`);
    expect(/paid|maksettu/i.test(await page.locator('.ord-badges').innerText()), `${name}: tila maksettu`);
    await layoutChecks(page, `${name} 390`, '.ord'); await page.context().close();
  }
  // 5b) tilaussivu: lunastus pois päältä / RPC puuttuu → ei lomaketta
  for (const [label, o] of [['redeem_enabled=false', { settings: { redeem_enabled: false }, scenario: 'gift' }], ['RPC puuttuu', { missingRpc: true, scenario: 'gift' }]]) {
    const name = `tilaussivu ei lomaketta (${label})`, page = await newShopPage(name, o); await page.goto(`${ORIGIN}/tilaus/?t=${ORDER_TOKEN}`); await page.waitForSelector('[data-testid=order-page]');
    expect(await page.locator('[data-testid=gc-redeem]').count() === 0 && !(await page.locator('body').innerText()).match(/ei vielä käytössä: lahjakort/i), `${name}`); await page.context().close();
  }
  // 5c) lahjakorttitilaus: ostetut kortit, ei "Käytä lahjakortti" -lomaketta, koodi vasta maksun jälkeen, PDF-nappi vain asetuksella
  for (const [scen, pdf, lang, vp] of [['cards', true, 'fi', 390], ['cardspaid', false, 'fi', 390], ['cardspaid', true, 'fi', 390], ['cardspaid', true, 'en', 390], ['cardspaid', true, 'fi', 1280], ['cardspaid', true, 'en', 1280]]) {
    const name = `tilaussivu ostetut kortit ${scen}${pdf ? ' +pdf' : ' pdf pois'} ${lang} ${vp}`, page = await newShopPage(name, { vp, lang, scenario: scen, cfgExtra: { giftCardPdf: pdf } });
    await page.goto(`${ORIGIN}${lang === 'fi' ? '/tilaus/' : '/en/order/'}?t=${ORDER_TOKEN}`); await page.waitForSelector('[data-testid=gc-cards]');
    expect(await page.locator('[data-testid=gc-card]').count() === 2 && await page.locator('[data-testid=gc-redeem]').count() === 0, `${name}: 2 korttia, ei lunastuslomaketta`);
    if (scen === 'cards') {
      expect(await page.locator('[data-testid=gc-show]').count() === 0 && await page.locator('[data-testid=gc-pdf]').count() === 0 && /Odottaa maksua/.test(await page.locator('[data-testid=gc-cards]').innerText()), `${name}: koodia ei näytetä maksamattomalle`);
      await shot(page, 'kauppa-tilaus-kortit-maksamatta-fi-390');
    } else {
      await page.locator('[data-testid=gc-show]').first().click(); await page.waitForSelector('[data-testid=gc-codetext]');
      expect(await page.locator('[data-testid=gc-codetext]').innerText() === 'HH3A-7CEF-HJKL' && /Hyvää syntymäpäivää/.test(await page.locator('[data-testid=gc-reveal]').first().innerText()), `${name}: koodi ja tervehdys`);
      expect(rpcCalls(page, 'public_get_gift_card').at(-1).args.p_public_token === '00000000-0000-4000-8000-000000000001', `${name}: public_get_gift_card kortin tokenilla`);
      const hasPdf = await page.locator('[data-testid=gc-pdf]').count();
      expect(hasPdf === (pdf ? 1 : 0), `${name}: PDF-nappi ${pdf ? 'näkyy' : 'EI näy'} (${hasPdf})`);
      if (pdf) { const a = page.locator('[data-testid=gc-pdf]'); expect(new RegExp(`/functions/v1/gift-card-pdf\\?t=00000000-0000-4000-8000-000000000001&lang=${lang}$`).test(await a.getAttribute('href')) && await a.getAttribute('target') === '_blank' && /Lataa PDF|Download PDF/i.test(await a.innerText()), `${name}: PDF-linkki lang=${lang}, uusi välilehti (${await a.getAttribute('href')} | ${await a.getAttribute('target')} | ${await a.innerText()})`); }
      expect(!(await page.locator('body').innerText()).match(/tulee myöhemmin|coming later|tulossa/i), `${name}: ei "tulee myöhemmin" -tekstiä`);
      await page.mouse.move(0, 0); await page.waitForTimeout(500);   // hover-siirtymä loppuun ennen kontrastimittausta
      await layoutChecks(page, `${name}`, '.ord');
      await shot(page, `kauppa-tilaus-kortit-koodi${pdf ? '-pdf' : ''}-${lang}-${vp}`);
    }
    await page.context().close();
  }
  // 6) kuvakaappaukset ja asettelu: kaikki leveydet FI/EN
  for (const lang of ['fi', 'en']) for (const vp of [360, 390, 430, 768, 1280]) {
    const name = `kuvat ${lang} ${vp}`, page = await newShopPage(name, { vp, lang });
    await page.goto(`${ORIGIN}${GIFT(lang)}`); await page.waitForSelector('#gift-app .gc-tile');
    { // sisältölista: FI = items[].label, EN = items[].label_en (booking_45); avoimella kortilla ei listaa
      const lists = await page.locator('#paketit .gc-tile [data-testid=gc-items]').allInnerTexts(), all = lists.join('|');
      expect(lists.length === 4 && (await page.locator('#avoin [data-testid=gc-items]').count()) === 0, `${name}: sisältölista 4 paketilla (${lists.length})`);
      expect(lang === 'en' ? /General session/.test(all) && /Peat mask and foot bath/.test(all) && /Sauna treatment/.test(all) && /Ritual sauna bathing/.test(all) && !/Yleinen vuoro|Saunahoito|Turvenaamio/.test(all) : /Yleinen vuoro/.test(all) && /Turvenaamio ja jalkakylpy/.test(all) && !/General session|Peat mask/.test(all), `${name}: sisältölistan kieli (${all.replace(/\n/g, '/')})`);
      if (vp === 390 || vp === 1280) await page.locator('#paketit').screenshot({ path: join(SHOT, `kauppa-paketit-sisalto-${lang}-${vp}.png`) });
    }
    await page.locator('#paketit .gc-tile').nth(1).locator('.gc-btn').click(); await page.locator('#paketit .gc-tile').nth(3).locator('.gc-btn').click();
    await page.fill('#avoin input', '50'); await page.click('#avoin .gc-btn');
    await page.locator('.gc-line').nth(2).locator('textarea').fill(lang === 'fi' ? 'Hyvää syntymäpäivää! Nauti lämmöstä ja rauhasta.' : 'Happy birthday! Enjoy the warmth and the calm.');
    await layoutChecks(page, `${name} myyntisivu`, '.gc');
    await shot(page, `kauppa-lahjakortti-${lang}-${vp}`);
    await page.locator('#gift-balance').scrollIntoViewIfNeeded(); await page.fill('#gift-balance input', 'hh3a7cefhjkl'); await page.click('#gift-balance button[type=submit]'); await page.waitForSelector('#gift-balance .gc-result');
    await layoutChecks(page, `${name} saldo`, '#gift-balance');
    await page.context().close();
    const op = await newShopPage(`${name} tilaus`, { vp, lang, scenario: 'gift' });
    await op.goto(`${ORIGIN}${lang === 'fi' ? '/tilaus/' : '/en/order/'}?t=${ORDER_TOKEN}`); await op.waitForSelector('[data-testid=gc-redeem]');
    await layoutChecks(op, `${name} tilaussivu`, '.ord'); await shot(op, `kauppa-tilaus-lahjakortti-${lang}-${vp}`); await op.context().close();
  }
}

// ================= AJO =================
try {
  if (!ONLY || ONLY === 'admin') await adminSuite();
  if ((!ONLY || ONLY === 'shop') && typeof shopSuite === 'function') await shopSuite();
} catch (e) { console.log('KESKEYTYI: ' + e.message.split('\n')[0]); for (const p of problems) console.log(' - ' + p); await browser.close(); server.close(); process.exit(1); }
await browser.close(); server.close();
console.log(`e2e-giftcards: ${checks} tarkistusta, ${problems.length} ongelmaa`);
for (const p of problems) console.log(' - ' + p);
process.exit(problems.length ? 1 : 0);
