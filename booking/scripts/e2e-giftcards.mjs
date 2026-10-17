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

// ================= AJO =================
try {
  if (!ONLY || ONLY === 'admin') await adminSuite();
  if ((!ONLY || ONLY === 'shop') && typeof shopSuite === 'function') await shopSuite();
} catch (e) { console.log('KESKEYTYI: ' + e.message.split('\n')[0]); for (const p of problems) console.log(' - ' + p); await browser.close(); server.close(); process.exit(1); }
await browser.close(); server.close();
console.log(`e2e-giftcards: ${checks} tarkistusta, ${problems.length} ongelmaa`);
for (const p of problems) console.log(' - ' + p);
process.exit(problems.length ? 1 : 0);
