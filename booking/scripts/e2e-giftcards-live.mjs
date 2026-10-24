// LIVE-E2E (Playwright + google-chrome): LAHJAKORTIT oikeaa TESTIPROJEKTIA vasten – ei mockia, ei page.route-vastauksia. Vaatii migraatiot 43–46 ja kytkimet gift_cards.sale_enabled / redeem_enabled = true TESTIPROJEKTISSA.
// Tuotantoprojektia (sxbofnuisemspgquoxyv) ei koskaan käytetä: osoite ja avain luetaan tiedostosta LIVE_ENV (oletus /workspace/.live/env, rivit KEY=VALUE:
// LIVE_URL, LIVE_ANON, LIVE_EMAIL, LIVE_PASSWORD, STAFF_EMAIL, STAFF_PASSWORD). Avaimia/salasanoja ei tulosteta. Skripti kieltäytyy ajamasta, jos LIVE_URL sisältää tuotannon ref-tunnuksen.
// Ajo: PW_DIR=/workspace/node_modules node booking/scripts/e2e-giftcards-live.mjs
// Testi kirjoittaa testiprojektiin (uusia lahjakortteja, tilauksia, maksuja; kaikki feikkidataa, muistiinpano 'E2E-feikkidata'); jokainen ajo luo itse tuoreet tilaukset (vapaa lauantai-ilta alkaen LIVE_FROM, oletus 2027-09-04).
// Ympäristö: SHOT_DIR (oletus /workspace/screenshots-lahjakortti-live), CHROME, PW_DIR, SHOP_DIST (kauppa-dist: `SHOP_DIST=/tmp/shop-dist-lahjakortti-live node booking/shop/build.mjs` ensin; oletus sama polku; ONLY=admin|shop).
import { createServer } from 'node:http';
import { readFile, mkdir, stat, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { dirname, join, extname, resolve, normalize } from 'node:path';
const here = dirname(fileURLToPath(import.meta.url)), ROOT = resolve(here, '../..');
const require = createRequire(import.meta.url);
const pwPath = require.resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', here].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath));
const chromium = pw.chromium || pw.default.chromium;
const { TEXTS } = await import(pathToFileURL(join(ROOT, 'booking/admin/talous-texts.js')));
const T = TEXTS.fi;
const envText = await readFile(process.env.LIVE_ENV || '/workspace/.live/env', 'utf8');
const E = Object.fromEntries(envText.trim().split('\n').map((l) => { const i = l.indexOf('='); return [l.slice(0, i), l.slice(i + 1)]; }));
if (!E.LIVE_URL || !E.LIVE_ANON || /sxbofnuisemspgquoxyv/.test(E.LIVE_URL)) { console.error('LIVE_ENV puuttuu tai osoittaa tuotantoon – keskeytetään'); process.exit(2); }
const SHOP = resolve(process.env.SHOP_DIST || '/tmp/shop-dist-lahjakortti-live');
const ONLY = process.env.ONLY || '';
const SHOT = resolve(process.env.SHOT_DIR || '/workspace/screenshots-lahjakortti-live');
await mkdir(SHOT, { recursive: true });
const problems = [], findings = []; let checks = 0;
const expect = (ok, msg) => { checks++; if (!ok) problems.push(msg); };
const note = (m) => findings.push(m);
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.webp': 'image/webp' };
const nbsp = /[\s\u00a0\u202f]/g;
const num = (s) => +String(s).replace(nbsp, "").replace(/\u2212/g, "-").replace(",", ".").replace(/[^\d.\-]/g, "");
const money = (n) => new Intl.NumberFormat('fi-FI', { style: 'currency', currency: 'EUR' }).format(n).replace(nbsp, '');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- staattinen palvelin: hallinta = booking/admin (config.js generoidaan, ei tallenneta levylle) ----
let ORIGIN = '';
const server = createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x'); const p = decodeURIComponent(u.pathname); let file;
  if (p === '/booking/config.js') { res.writeHead(200, { 'content-type': 'text/javascript' }); return res.end(`window.BOOKING_CONFIG=${JSON.stringify({ url: E.LIVE_URL, anonKey: E.LIVE_ANON, rest: '/rest/v1', auth: '/auth/v1', functions: '/functions/v1', schema: 'booking', ...(globalThis.__cfgExtra || {}) })};`); }
  if (p === '/admin/config.js') { res.writeHead(200, { 'content-type': 'text/javascript' }); return res.end(`window.BOOKING_CONFIG=${JSON.stringify({ url: E.LIVE_URL, anonKey: E.LIVE_ANON, rest: '/rest/v1', auth: '/auth/v1', functions: '/functions/v1', schema: 'booking' })};`); }
  if (p === '/admin/sb.js') file = join(ROOT, 'booking/shared/sb.js');
  else if (p.startsWith('/admin/')) file = join(ROOT, 'booking/admin', p.slice(7) || 'index.html');
  else file = join(SHOP, normalize(p));
  try {
    if ((await stat(file)).isDirectory()) file = join(file, 'index.html');
    const buf = await readFile(file);
    res.writeHead(200, { 'content-type': types[extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' }); res.end(buf);
  } catch { res.writeHead(404); res.end('Not found'); }
});
await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
ORIGIN = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });

// ---- suora RPC (node) – tilausten luontiin ja tilan tarkistukseen ----
async function login(email, password) {
  const r = await fetch(`${E.LIVE_URL}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: E.LIVE_ANON, 'content-type': 'application/json' }, body: JSON.stringify({ email, password }) });
  const j = await r.json(); if (!r.ok) throw new Error(`kirjautuminen epäonnistui (${r.status})`);
  return { access_token: j.access_token, refresh_token: j.refresh_token, expires_at: Math.floor(Date.now() / 1000) + (j.expires_in || 3600), user: j.user };
}
const admin = await login(E.LIVE_EMAIL, E.LIVE_PASSWORD);
async function rpc(name, args = {}, sess = admin) {
  const r = await fetch(`${E.LIVE_URL}/rest/v1/rpc/${name}`, { method: 'POST', headers: { apikey: E.LIVE_ANON, authorization: `Bearer ${sess.access_token}`, 'content-type': 'application/json', 'accept-profile': 'booking', 'content-profile': 'booking' }, body: JSON.stringify(args) });
  const txt = await r.text(); let j; try { j = txt ? JSON.parse(txt) : null; } catch { j = txt; }
  return { status: r.status, body: j, ok: r.ok, code: j?.details || j?.code };
}
const must = async (name, args, sess) => { const r = await rpc(name, args, sess); if (!r.ok) throw new Error(`${name}: ${r.status} ${r.code}`); return r.body; };
let slot = new Date(`${process.env.LIVE_FROM || '2027-09-04'}T12:00:00Z`);
async function freshOrder({ name = 'Live-testi Asiakas', email = `live-${Date.now().toString(36)}${Math.floor(Math.random() * 1e4)}@example.invalid` } = {}) {
  for (let i = 0; i < 60; i++) {
    const day = slot.toISOString().slice(0, 10); slot = new Date(slot.getTime() + 7 * 864e5);
    const r = await rpc('admin_create_resource_booking', { p_product_id: 10, p_start: toHelsinki(`${day}T19:00:00`), p_persons: 2, p_customer: { name, email, phone: '+358400000099' }, p_payment_method: 'pay_later' }, admin);
    if (r.ok) return r.body;
    if (!/jo varattu|exclude|booked|time_window/i.test(JSON.stringify(r.body))) throw new Error(`admin_create_resource_booking: ${r.status} ${JSON.stringify(r.body).slice(0, 200)}`);
  }
  throw new Error('vapaata vuoroa ei löytynyt');
}
function toHelsinki(local) {   // 'YYYY-MM-DDTHH:MM:SS' Helsingin aikaa → ISO UTC
  const guess = new Date(`${local}Z`).getTime();
  for (const off of [3, 2]) { const d = new Date(guess - off * 3600e3); const h = new Intl.DateTimeFormat('sv-SE', { timeZone: 'Europe/Helsinki', hour12: false, hour: '2-digit', minute: '2-digit', day: '2-digit' }).format(d); if (h.endsWith(local.slice(11, 16))) return d.toISOString(); }
  return new Date(guess - 3 * 3600e3).toISOString();
}

// ---- selain ----
async function openPage(name, sess, { vp = 1280, lang = 'fi', hash = '#/talous', allow400 = false } = {}) {
  const ctx = await browser.newContext({ viewport: { width: vp, height: vp >= 900 ? 900 : 800 }, deviceScaleFactor: 1, isMobile: vp < 700, hasTouch: vp < 700, locale: lang === 'fi' ? 'fi-FI' : 'en-GB', timezoneId: 'Europe/Helsinki', acceptDownloads: true });
  await ctx.addInitScript((s) => { try { localStorage.setItem('booking.session', JSON.stringify(s)); } catch { /* */ } }, sess);
  const page = await ctx.newPage(); page.calls = [];
  page.on('pageerror', (e) => problems.push(`${name} pageerror: ${e.message}`));
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type()) && !(page.expect400 && /status of 4\d\d/.test(m.text()))) problems.push(`${name} console ${m.type()}: ${m.text()}`); });
  page.on('requestfailed', (r) => problems.push(`${name} requestfailed: ${r.url().replace(E.LIVE_URL, '<testiprojekti>')}`));
  page.on('request', (r) => { if (r.url().includes('/rest/v1/rpc/')) page.calls.push({ name: r.url().split('/rpc/')[1], body: r.postData() }); });
  page.on('response', (r) => { const u = r.url(); if (u.startsWith(ORIGIN) && r.status() >= 400) problems.push(`${name} HTTP ${r.status()} ${u}`); });
  await page.goto(`${ORIGIN}/admin/${hash}${hash.includes('?') ? '&' : '?'}lang=${lang}`);
  return page;
}
const shot = (page, n) => page.screenshot({ path: join(SHOT, `${n}.png`), fullPage: true });
const layoutLive = async (page, label) => expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), `${label}: ei vaakavieritystä`);
const rows = (page) => page.locator('[data-testid=orders-list] > [data-testid=order]');
const toastText = async (page, cls) => { await page.waitForSelector(`#toast.show.${cls}`, { timeout: 8000 }); return page.locator('#toast').innerText(); };
// napin painallus + uusi toast (vanha toast tyhjennetään ensin, ettei luettaisi edellisen toiminnon viestiä)
const clickToast = async (page, sel, cls) => { await page.evaluate(() => { const t = document.querySelector('#toast'); if (t) { t.classList.remove('show', 'ok', 'err', 'warn'); t.textContent = ''; } }); await page.click(sel); return toastText(page, cls); };
async function waitList(page) { await page.waitForSelector('[data-testid=orders-list] [data-testid=order]', { timeout: 15000 }); }
async function openOrder(page, no) {
  await page.click('[data-testid=orders-reset]'); await page.fill('[data-testid=orders-search]', String(no)); await page.keyboard.press('Enter');
  await page.waitForFunction((n) => { const r = [...document.querySelectorAll('[data-testid=orders-list] > [data-testid=order]')]; return r.length >= 1 && r.every((x) => x.textContent.includes(`#${n}`)); }, no, { timeout: 10000 });
  await rows(page).first().locator('.tl-head').click(); await page.waitForSelector('[data-testid=order-actions]', { timeout: 10000 });
}
const dd = async (page, id) => num(await page.locator(`[data-testid=${id}]`).first().innerText());
const closeDialogs = async (page) => { for (let i = 0; i < 3; i++) { if (await page.locator('dialog[open]').count()) await page.keyboard.press('Escape'); } };
const RUN = Date.now().toString(36);
const NOTE = `E2E-feikkidata ${RUN}`;
const gcRows = (page) => page.locator('[data-testid=gc-list] > [data-testid=gc]');
const gcOpen = async (page, code) => {
  await page.click('[data-testid=gc-reset]'); await page.fill('[data-testid=gc-search]', code); await page.keyboard.press('Enter');
  await page.waitForFunction(() => document.querySelectorAll('[data-testid=gc-list] > [data-testid=gc]').length === 1, null, { timeout: 10000 });
  await gcRows(page).first().locator('.tl-head').click(); await page.waitForSelector('[data-testid=gc-detail]', { timeout: 10000 });
};
const cardOf = async (code) => (await must('admin_get_gift_card', { p_code: code }));
const orderPays = async (orderId) => (await must('admin_get_order', { p_order_id: orderId })).payments;

async function adminGiftSuite() {
  // ---- lähtötila palvelimelta ----
  const pk = await must('admin_list_gift_card_packages');
  expect(pk.settings.sale_enabled === true && pk.settings.redeem_enabled === true && pk.settings.johku_cards_redeemable === false, `kytkimet testiprojektissa: ${JSON.stringify(pk.settings)} (sale/redeem pitää olla true, johku false)`);
  expect(pk.packages.length === 5, `5 pakettia (${pk.packages.length})`);
  const list0 = await must('admin_list_gift_cards', { p_limit: 1 });

  // ---- 1. välilehti, kytkimet, lista = palvelin ----
  let page = await openPage('live lahjakortit 1280', admin, { vp: 1280, hash: '#/talous?tab=giftcards' });
  await page.waitForSelector('[data-testid=gc-list]', { timeout: 15000 });
  await page.waitForFunction(() => document.querySelector('[data-testid=gc-count]')?.textContent || document.querySelector('[data-testid=gc-list] .tl-empty'), null, { timeout: 15000 });
  expect(await page.locator('[data-testid=mock-banner]').isHidden(), 'ei mock-bannera');
  expect(await page.locator('[data-testid=gc-sw-sale]').getAttribute('data-on') === 'true' && await page.locator('[data-testid=gc-sw-redeem]').getAttribute('data-on') === 'true' && await page.locator('[data-testid=gc-sw-johku]').getAttribute('data-on') === 'false', 'kytkimet UI:ssa = palvelin');
  expect(list0.total === 0 || num((await page.locator('[data-testid=gc-count]').innerText()).replace(/^.*\/\s*/, '')) === list0.total, `lista = palvelimen kokonaismäärä (${list0.total})`);
  await shot(page, 'live-lahjakortit-lista-1280-fi');

  // ---- 2. luonti käyttöliittymästä: maksuton myöntö ----
  await page.click('[data-testid=gc-new]'); await page.waitForSelector('dialog[open] [data-testid=gc-new-mode]');
  await page.fill('dialog[open] [data-testid=gc-new-amount]', '75'); await page.fill('dialog[open] [data-testid=gc-new-note]', `${NOTE}: ilmainen`); await page.fill('dialog[open] [data-testid=gc-new-rec-name]', 'Live Saaja');
  await page.fill('dialog[open] [data-testid=gc-new-greeting]', 'Hyvää joulua!'); await page.click('dialog[open] button[type=submit]'); await page.waitForSelector('[data-testid=gc-result]');
  const freeCode = await page.locator('[data-testid=gc-result-code]').first().innerText();
  let g = await cardOf(freeCode);
  expect(g.card.balance === 75 && g.card.initial_amount === 75 && g.card.status === 'active' && g.card.recipient_name === 'Live Saaja' && g.card.greeting === 'Hyvää joulua!' && g.ledger[0].reason === 'manual_issue' && g.ledger_consistent, `maksuton kortti palvelimella (${JSON.stringify(g.card).slice(0, 160)})`);
  await page.keyboard.press('Escape');

  // ---- 3. myynti käteisellä (tilaus + maksu + kuitti), pakettikortti ----
  await page.click('[data-testid=gc-new]'); await page.waitForSelector('dialog[open] [data-testid=gc-new-mode]');
  await page.selectOption('dialog[open] [data-testid=gc-new-mode]', 'cash'); await page.selectOption('dialog[open] [data-testid=gc-new-package]', 'entry_2');
  await page.fill('dialog[open] input[name=buyer_name]', 'Live Ostaja'); await page.fill('dialog[open] input[name=buyer_email]', `live-ostaja-${RUN}@example.invalid`);
  await page.fill('dialog[open] [data-testid=gc-new-note]', `${NOTE}: myynti`); await page.click('dialog[open] button[type=submit]'); await page.waitForSelector('[data-testid=gc-result]');
  const saleCode = await page.locator('[data-testid=gc-result-code]').first().innerText();
  g = await cardOf(saleCode);
  expect(g.card.status === 'active' && g.card.balance === 58 && g.card.package_code === 'entry_2' && g.purchase_order?.payment_status === 'paid' && g.purchase_order.total === 58, `käteismyynti: kortti aktiivinen, tilaus maksettu (${JSON.stringify(g.purchase_order)})`);
  const saleOrder = await must('admin_get_order', { p_order_id: g.purchase_order.order_id });
  expect(saleOrder.receipts.length >= 1, 'myynnistä syntyi kuitti');
  await page.keyboard.press('Escape');

  // ---- 4. myynti laskulla → odottaa maksua; aktivointi estetty ----
  await page.click('[data-testid=gc-new]'); await page.waitForSelector('dialog[open] [data-testid=gc-new-mode]');
  await page.selectOption('dialog[open] [data-testid=gc-new-mode]', 'invoice'); await page.selectOption('dialog[open] [data-testid=gc-new-package]', 'peat_mask_2');
  await page.fill('dialog[open] input[name=buyer_name]', 'Lasku Ostaja'); await page.fill('dialog[open] input[name=buyer_email]', `live-lasku-${RUN}@example.invalid`); await page.fill('dialog[open] [data-testid=gc-new-note]', `${NOTE}: lasku`);
  await page.click('dialog[open] button[type=submit]'); await page.waitForSelector('[data-testid=gc-result]');
  const invCode = await page.locator('[data-testid=gc-result-code]').first().innerText();
  g = await cardOf(invCode);
  expect(g.card.status === 'pending_payment' && g.card.balance === 0 && g.purchase_order.payment_status !== 'paid', `laskumyynti: odottaa maksua (${g.card.status})`);
  await page.keyboard.press('Escape');
  await gcOpen(page, invCode);
  expect(await page.locator('[data-testid=gc-btn-reactivate]').isDisabled(), 'maksamatonta ostoa ei voi aktivoida UI:ssa');
  expect(g.card.public_token && await page.locator('[data-testid=gc-pdf]').count() === 1 && await page.locator('button[data-testid=gc-pdf]').isDisabled(), 'maksamattomalla kortilla Avaa PDF on näkyvissä mutta pois käytöstä (PDF antaisi 409)');
  await shot(page, 'live-lahjakortit-maksamaton-1280-fi');

  // ---- 5. voimassaolo, saldokorjaus, mitätöinti, aktivointi UI:sta ----
  await gcOpen(page, freeCode);
  { // "Avaa PDF" (sopimus §13.9): linkki rakennetaan admin_get_gift_card().card.public_token:sta; ei haeta PDF:ää (testiprojektissa ei ole gift-card-pdf-funktiota / ei oikeaa dataa)
    const tok = (await cardOf(freeCode)).card.public_token, a = page.locator('a[data-testid=gc-pdf]');
    expect(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(tok || ''), 'admin_get_gift_card palauttaa card.public_token (UUID)');
    expect(await a.count() === 1 && await a.getAttribute('href') === `${E.LIVE_URL}/functions/v1/gift-card-pdf?t=${tok}&lang=fi` && await a.getAttribute('target') === '_blank', `Avaa PDF -linkin muoto (${await a.getAttribute('href').then((x) => String(x).replace(/t=[0-9a-f-]{36}/, 't=<token>'))})`);
    await shot(page, 'live-lahjakortit-avaa-pdf-1280-fi');
  }
  await page.click('[data-testid=gc-btn-expiry]'); await page.waitForSelector('dialog[open] [data-testid=gc-expiry-date]'); await page.fill('dialog[open] [data-testid=gc-expiry-date]', '2028-01-31'); await page.fill('dialog[open] input[name=note]', NOTE); await page.click('dialog[open] button[type=submit]');
  await page.waitForSelector('[data-testid=gc-expiry] li', { timeout: 10000 });
  g = await cardOf(freeCode); expect(g.card.valid_to === '2028-01-31' && g.expiry_log.length === 1 && g.ledger.some((x) => x.reason === 'expiry_change'), `voimassaolon muutos palvelimella (${g.card.valid_to})`);
  await page.click('[data-testid=gc-btn-adjust]'); await page.waitForSelector('dialog[open] [data-testid=gc-adj-delta]'); await page.fill('dialog[open] [data-testid=gc-adj-delta]', '-5'); await page.fill('dialog[open] [data-testid=gc-adj-reason]', `${NOTE} korjaus`); await page.click('dialog[open] button[type=submit]');
  await page.waitForFunction(() => document.querySelector('[data-testid=gc-detail]')?.textContent.includes('Saldokorjaus'), null, { timeout: 10000 });
  g = await cardOf(freeCode); expect(g.card.balance === 70 && g.ledger_consistent, `saldokorjaus palvelimella (${g.card.balance})`);
  await page.click('[data-testid=gc-btn-deactivate]'); await page.waitForSelector('dialog[open] [data-testid=gc-reason]'); await page.fill('dialog[open] [data-testid=gc-reason]', `${NOTE} mitätöinti`); await page.click('dialog[open] button[type=submit]');
  await page.waitForFunction(() => document.querySelector('[data-testid=gc]')?.dataset.status === 'cancelled', null, { timeout: 10000 });
  g = await cardOf(freeCode); expect(g.card.status === 'cancelled' && g.card.balance === 70, 'mitätöity, saldo säilyy');
  await page.waitForSelector('[data-testid=gc-btn-reactivate]:not([disabled])');
  await page.click('[data-testid=gc-btn-reactivate]'); await page.waitForSelector('dialog[open] [data-testid=gc-reason]'); await page.fill('dialog[open] [data-testid=gc-reason]', `${NOTE} aktivointi`); await page.click('dialog[open] button[type=submit]');
  await page.waitForFunction(() => document.querySelector('[data-testid=gc]')?.dataset.status === 'active', null, { timeout: 10000 });
  g = await cardOf(freeCode); expect(g.card.status === 'active', 'aktivoitu uudelleen');
  expect(g.ledger.map((x) => x.reason).join() === 'manual_issue,expiry_change,adjust,cancel,reactivate', `tapahtumahistoria järjestyksessä (${g.ledger.map((x) => x.reason)})`);
  await shot(page, 'live-lahjakortit-kortti-1280-fi');
  const ledTxt = await page.locator('[data-testid=gc-ledger]').innerText();
  expect(ledTxt.includes('Saldokorjaus') && ledTxt.includes('Mitätöinti') && ledTxt.includes('Uudelleenaktivointi'), 'tapahtumahistoria näkyy UI:ssa');
  expect(page.calls.every((c) => c.name !== 'admin_record_payment'), 'ei admin_record_payment-kutsuja');

  // ---- 6. Lisää maksu → Lahjakortti: osittainen lunastus (at_sale-kortti, 70 €) ----
  const o1 = await freshOrder(); const o1Id = o1.order_id; const o1no = o1.order_no;
  const o1Total = (await must('admin_get_order', { p_order_id: o1Id })).balance.total;
  const op = await openPage('live lunastus 1', admin, { vp: 390, hash: '#/talous?tab=orders' });
  await waitList(op); await openOrder(op, o1no);
  await op.click('[data-testid=btn-record]'); await op.waitForSelector('dialog[open] [data-testid=record-method]');
  await op.selectOption('dialog[open] [data-testid=record-method]', 'gift_card');
  await op.fill('dialog[open] [data-testid=redeem-code]', freeCode.toLowerCase().replace(/-/g, ' ')); await op.click('dialog[open] [data-testid=redeem-lookup]');
  await op.waitForFunction(() => /\d/.test(document.querySelector('dialog[open] [data-testid=redeem-info]').textContent), null, { timeout: 10000 });
  expect(await op.locator('dialog[open] [data-testid=redeem-code]').inputValue() === freeCode, 'koodi normalisoitu muotoon HHxx-xxxx-xxxx');
  const want = Math.min(o1Total, 70);
  await op.fill('dialog[open] [data-testid=record-amount]', '20'); await shot(op, 'live-lahjakortit-lisaa-maksu-390-fi');
  const t1 = await clickToast(op, 'dialog[open] button[type=submit]', 'ok');
  expect(/Lahjakortti lunastettu/.test(t1) && /ALV on kirjattu/.test(t1), `lunastuksen ilmoitus (${t1})`);
  let pays = await orderPays(o1Id); const gp = pays.find((p) => p.method === 'gift_card');
  expect(gp && gp.amount === 20 && gp.status === 'paid', `maksu method=gift_card, 20 € (${JSON.stringify(gp)?.slice(0, 120)})`);
  g = await cardOf(freeCode); expect(g.card.balance === 50 && g.ledger.at(-1).reason === 'redemption' && g.ledger.at(-1).delta === -20 && g.payments.length === 1 && g.payments[0].accounted === false && g.ledger_consistent, `kortin saldo 50 € ja maksurivi (${g.card.balance})`);
  expect((await must('admin_get_order', { p_order_id: o1Id })).balance.unpaid === Math.round((o1Total - 20) * 100) / 100, 'osittainen lunastus: jäännös jää maksettavaksi');
  expect(op.calls.every((c) => c.name !== 'admin_record_payment'), 'admin_record_payment ei kutsuttu lahjakortilla');
  // toinen lunastus: tyhjä summa → pienempi saldosta ja maksamattomasta
  await openOrder(op, o1no); await op.click('[data-testid=btn-record]'); await op.waitForSelector('dialog[open] [data-testid=record-method]');
  await op.selectOption('dialog[open] [data-testid=record-method]', 'gift_card'); await op.fill('dialog[open] [data-testid=redeem-code]', freeCode); await op.fill('dialog[open] [data-testid=record-amount]', '');
  await clickToast(op, 'dialog[open] button[type=submit]', 'ok');
  const unpaidLeft = o1Total - 20, second = Math.min(unpaidLeft, 50);
  g = await cardOf(freeCode); expect(Math.abs(g.card.balance - (50 - second)) < 0.006, `tyhjä summa = pienempi (saldo ${g.card.balance}, odotettu ${50 - second})`);

  // ---- 7. virheet: vanhentunut, tyhjä, väärä koodi, ylisuuri summa, avoin kortti → kuitti (at_redemption) ----
  const o2 = await freshOrder();
  const exp = (await must('admin_create_gift_card', { p_package: 'open', p_amount: 40, p_note: `${NOTE}: vanhenee` })).cards[0];
  await must('admin_set_gift_card_expiry', { p_id: exp.id, p_valid_to: '2020-01-01', p_note: NOTE });
  const op2 = await openPage('live lunastus 2', admin, { vp: 1280, hash: '#/talous?tab=orders' }); op2.expect400 = true;
  await waitList(op2); await openOrder(op2, o2.order_no);
  const tryRedeem = async (code, amount, cls = 'err') => {
    await op2.click('[data-testid=btn-record]'); await op2.waitForSelector('dialog[open] [data-testid=record-method]'); await op2.selectOption('dialog[open] [data-testid=record-method]', 'gift_card');
    await op2.fill('dialog[open] [data-testid=redeem-code]', code); await op2.fill('dialog[open] [data-testid=record-amount]', amount);
    const tx = await clickToast(op2, 'dialog[open] button[type=submit]', cls); if (cls === 'err') await closeDialogs(op2); return tx;
  };
  expect(/vanhentunut/i.test(await tryRedeem(exp.code, '')), 'vanhentunut kortti → "Lahjakortti on vanhentunut"');
  expect(/ei löydy/i.test(await tryRedeem('HHZZ-ZZZZ-ZZZZ', '')), 'tuntematon koodi → "Lahjakorttia ei löydy"');
  expect(/Anna lahjakortin koodi|12 merkkiä/i.test(await tryRedeem('abc', '')), 'liian lyhyt koodi → ohje');
  const small = (await must('admin_create_gift_card', { p_package: 'open', p_amount: 30, p_note: `${NOTE}: pieni`, p_vat_treatment: 'at_redemption' })).cards[0];
  expect(/riitä/i.test(await tryRedeem(small.code, '31')), 'ylisuuri summa → "saldo ei riitä"');
  const t3 = await tryRedeem(small.code, '30', 'ok');
  expect(/Lahjakortti lunastettu/.test(t3) && /Kuitti .* luotu/.test(t3) && !/ALV on kirjattu/.test(t3), `avoin kortti (at_redemption) → kuitti syntyy (${t3})`);
  g = await cardOf(small.code); expect(g.card.balance === 0 && g.card.status === 'used' && g.payments[0].accounted === true, 'kortti käytetty loppuun, maksu kirjanpidossa');
  expect(/tyhjä|nolla/i.test(await tryRedeem(small.code, '')), 'tyhjä kortti → "saldo on nolla"');
  const o2Pays = await orderPays(o2.order_id); expect(o2Pays.filter((p) => p.method === 'gift_card' && p.status === 'paid').length === 1, 'vain onnistunut lunastus kirjattu');

  // ---- 8. mobiili + EN + staff-oikeudet ----
  for (const [vp, lang] of [[390, 'fi'], [390, 'en'], [768, 'fi'], [360, 'fi']]) {
    const name = `live lahjakortit ${vp} ${lang}`, mp = await openPage(name, admin, { vp, lang, hash: '#/talous?tab=giftcards' });
    await mp.waitForSelector('[data-testid=gc-list] [data-testid=gc]', { timeout: 15000 });
    expect(await mp.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), `${name}: ei vaakavieritystä`);
    await gcOpen(mp, freeCode);
    expect(await mp.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1) && (await mp.locator('[data-testid=gc-ledger] li').count()) >= 5, `${name}: kortti + historia mahtuvat`);
    await shot(mp, `live-lahjakortit-kortti-${vp}-${lang}`);
  }
  if (E.STAFF_EMAIL) {
    const staff = await login(E.STAFF_EMAIL, E.STAFF_PASSWORD);
    const perms = (await rpc('admin_my_permissions', {}, staff)).body.permissions;
    const sp = await openPage('live staff', staff, { vp: 390, hash: '#/talous?tab=giftcards' });
    if (perms.includes('giftcards.manage')) {
      await sp.waitForSelector('[data-testid=gc-list] [data-testid=gc]', { timeout: 15000 });
      await gcOpen(sp, freeCode);
      expect(perms.includes('giftcards.admin') || (await sp.locator('[data-testid=gc-btn-adjust]').isDisabled() && await sp.locator('[data-testid=gc-btn-deactivate]').isDisabled()), 'staff: korjaus/mitätöinti estetty ilman giftcards.admin');
      note(`staff-oikeudet: ${perms.filter((p) => /gift|payments/.test(p)).join(', ')}`);
    } else note('staff-käyttäjällä ei giftcards.manage – välilehteä ei näytetä');
    const denied = await rpc('admin_adjust_gift_card', { p_id: g.card.id, p_delta: 1, p_reason: 'E2E oikeustesti' }, staff);
    expect(perms.includes('giftcards.admin') || (!denied.ok && denied.code === 'forbidden'), `staff: admin_adjust_gift_card estetty palvelimella (${denied.status} ${denied.code})`);
  }
}


// ================= KAUPPA (lahjakorttisivu, saldotarkistus, lunastus tilaussivulla) – oikea testiprojekti =================
async function openShop(name, path, { vp = 390, lang = 'fi', allow = null } = {}) {
  const ctx = await browser.newContext({ viewport: { width: vp, height: vp >= 900 ? 900 : 800 }, deviceScaleFactor: 1, isMobile: vp < 700, hasTouch: vp < 700, locale: lang === 'fi' ? 'fi-FI' : 'en-GB', timezoneId: 'Europe/Helsinki' });
  const page = await ctx.newPage(); page.calls = [];
  page.on('pageerror', (e) => problems.push(`${name} pageerror: ${e.message}`));
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type()) && !(allow && allow.test(m.text()))) problems.push(`${name} console ${m.type()}: ${m.text()}`); });
  page.on('requestfailed', (r) => !/ERR_ABORTED/.test(r.failure()?.errorText || '') && problems.push(`${name} requestfailed: ${r.url().replace(E.LIVE_URL, '<testiprojekti>')}`));
  page.on('request', (r) => { if (r.url().includes('/rest/v1/rpc/')) page.calls.push({ name: r.url().split('/rpc/')[1], body: r.postData() }); });
  page.on('response', (r) => { if (r.url().startsWith(ORIGIN) && r.status() >= 400) problems.push(`${name} HTTP ${r.status()} ${r.url()}`); });
  await page.goto(`${ORIGIN}${path}`);
  return page;
}
async function shopGiftSuite() {
  const pk = (await rpc('public_gift_card_packages', {}, { access_token: E.LIVE_ANON })).body;
  expect(pk.ok && pk.sale_enabled === true && pk.redeem_enabled === true, `kytkimet testiprojektissa päällä (sale ${pk.sale_enabled}, redeem ${pk.redeem_enabled})`);
  const buyerEmail = `live-gift-${RUN}@example.invalid`;
  // 1) myyntisivu FI: sisältö suoraan palvelimelta
  let order;
  {
    const name = 'live kauppa osto FI', page = await openShop(name, '/lahjakortti/', { vp: 390 });
    await page.waitForSelector('#gift-app .gc-tile', { timeout: 15000 });
    expect(await page.locator('section#avoin, section#paketit').count() === 0, `${name}: Johku-osiot korvattu`);
    const names = await page.locator('#paketit h3').allInnerTexts(), prices = (await page.locator('#paketit .gc-price').allInnerTexts()).map((t) => num(t.split('·')[0]));
    const fixed = pk.packages.filter((p) => !p.is_open);
    expect(names.join('|') === fixed.map((p) => p.name).join('|') && prices.join() === fixed.map((p) => p.price).join(), `${name}: nimet ja hinnat = RPC (${names.length} pakettia)`);
    expect(await page.locator('#avoin h3').innerText() === pk.packages.find((p) => p.is_open).name, `${name}: avoimen kortin nimi = RPC`);
    { // sisältölista = items[].label (FI); migraatio booking_45 → jokaisella rivillä myös label_en
      const lists = await page.locator('#paketit .gc-tile').evaluateAll((els) => els.map((e) => [...e.querySelectorAll('[data-testid=gc-items] li')].map((l) => l.textContent)));
      expect(JSON.stringify(lists) === JSON.stringify(fixed.map((p) => p.items.map((i) => i.label).filter(Boolean))), `${name}: sisältölistat = RPC items[].label`);
      expect(fixed.every((p) => p.items.length > 0 && p.items.every((i) => i.label && i.label_en)), 'public_gift_card_packages: jokaisella items-rivillä label ja label_en (booking_45 ajettu)');
    }
    await page.fill('#avoin input', '31,5'); await page.click('#avoin .gc-btn'); await page.waitForSelector('.gc-line');
    await page.locator('#paketit .gc-tile').nth(0).locator('.gc-btn').click();
    await page.locator('.gc-line').nth(0).locator('textarea').fill('Hyvää syntymäpäivää – E2E-feikkidata');
    await page.locator('.gc-line').nth(0).locator('input[type=text]').nth(1).fill('Saaja E2E');
    await page.fill('input[autocomplete=name]', 'Live Ostaja'); await page.fill('input[autocomplete=email]', buyerEmail); await page.fill('input[autocomplete=tel]', '+358400000099'); await page.check('#gc-terms');
    await page.click('.gc-submit'); await page.waitForSelector('.gc-done', { timeout: 20000 });
    const txt = await page.locator('.gc-done').innerText();
    const orderNo = +/#(\d+)/.exec(txt)?.[1];
    expect(orderNo > 0 && /Odottaa maksua/.test(txt) && Math.abs(num(txt.match(/Yhteensä\s*([\d\s.,]+)/)?.[1] ?? 'x') - 89.5) < 0.01 || /89,50/.test(txt.replace(nbsp, '')), `${name}: kuittaus, tilausnumero ${orderNo}, summa 89,50 (${txt.replace(/\n/g, ' ').slice(0, 100)})`);
    await shot(page, 'live-kauppa-osto-valmis-fi-390');
    const lst = await must('admin_list_gift_cards', { p_search: buyerEmail });
    expect(lst.total === 2 && lst.rows.every((r) => r.status === 'pending_payment' && r.buyer_name === 'Live Ostaja' && r.order_no === orderNo), `${name}: 2 korttia pending_payment, ostaja ja tilausnumero oikein`);
    const open = lst.rows.find((r) => r.package_code === 'open'), entry = lst.rows.find((r) => r.package_code === 'entry_2');
    expect(open && open.initial_amount === 31.5 && open.greeting === 'Hyvää syntymäpäivää – E2E-feikkidata' && open.recipient_name === 'Saaja E2E' && entry && entry.initial_amount === 58, `${name}: summat, tervehdys ja saaja tallentuivat`);
    await page.context().close();
    const full = await must('admin_get_order', { p_order_id: (await must('admin_list_orders', { p_search: String(orderNo) })).rows[0].order_id });
    order = { id: full.order_id, token: full.public_token, no: orderNo, open, entry };
  }
  // 2) tilaussivu ennen maksua: kortit, ei koodia, ei lunastuslomaketta
  {
    const name = 'live kauppa tilaus maksamatta', page = await openShop(name, `/tilaus/?t=${order.token}`);
    await page.waitForSelector('[data-testid=gc-cards]', { timeout: 15000 });
    expect(await page.locator('[data-testid=gc-card]').count() === 2 && await page.locator('[data-testid=gc-show]').count() === 0 && await page.locator('[data-testid=gc-redeem]').count() === 0, `${name}: 2 korttia, ei Näytä koodi -nappia eikä lunastuslomaketta`);
    expect(!(await page.locator('body').innerText()).includes(order.open.code), `${name}: koodia ei vuoda ennen maksua`);
    await shot(page, 'live-kauppa-tilaus-kortit-maksamatta-fi-390'); await page.context().close();
    const early = await rpc('public_get_gift_card', { p_public_token: order.open.public_token }, { access_token: E.LIVE_ANON });
    expect(early.body?.ok === false && early.body.code === 'not_ready', `public_get_gift_card maksamattomalle → not_ready (${early.body?.code})`);
  }
  // 3) maksu hallinnasta → kortit aktivoituvat; koodi näkyy tilaussivulla; PDF-nappi vain asetuksella
  await must('admin_record_payment', { p_order_id: order.id, p_method: 'cash', p_amount: 89.5, p_note: NOTE });
  const act = await must('admin_list_gift_cards', { p_search: buyerEmail });
  expect(act.rows.every((r) => r.status === 'active' && r.valid_to), `maksun jälkeen kortit active ja valid_to asetettu (${act.rows.map((r) => r.status)})`);
  const code = act.rows.find((r) => r.package_code === 'open').code, code2 = act.rows.find((r) => r.package_code === 'entry_2').code;
  for (const pdf of [false, true]) {
    globalThis.__cfgExtra = { giftCardPdf: pdf };
    const name = `live kauppa tilaus maksettu${pdf ? ' +pdf' : ' pdf pois'}`, page = await openShop(name, `/tilaus/?t=${order.token}`);
    await page.waitForFunction(() => document.querySelectorAll('[data-testid=gc-codetext]').length >= 2, null, { timeout: 15000 });
    expect(await page.locator('[data-testid=gc-show]').count() === 0, `${name}: koodi aukeaa ilman erillistä nappia`);
    const openCard = page.locator('[data-testid=gc-card]').filter({ hasText: 'Avoin' });
    expect(await openCard.locator('[data-testid=gc-codetext]').innerText() === code && /E2E-feikkidata/.test(await openCard.innerText()), `${name}: koodi ja tervehdys näkyvät`);
    expect(await page.locator('[data-testid=gc-pdf]').count() === (pdf ? 2 : 0), `${name}: PDF-nappi ${pdf ? 'näkyy' : 'ei näy'}`);
    if (pdf) { const a = page.locator('a[data-testid=gc-pdf]'), href = await a.getAttribute('href'); expect(href.startsWith(`${E.LIVE_URL}/functions/v1/gift-card-pdf?t=`) && /^[0-9a-f-]{36}&lang=fi$/.test(href.split('?t=')[1]) && await a.getAttribute('target') === '_blank', `${name}: PDF-linkin muoto (lang=fi, uusi välilehti)`); await shot(page, 'live-kauppa-tilaus-lataa-pdf-fi-390'); }
    expect(await page.locator('[data-testid=gc-redeem]').count() === 0, `${name}: lahjakorttitilauksella ei lunastuslomaketta`);
    if (!pdf) { await page.mouse.move(0, 0); await shot(page, 'live-kauppa-tilaus-kortit-koodi-fi-390'); }
    await page.context().close();
  }
  globalThis.__cfgExtra = {};
  // 4) saldotarkistus oikealla koodilla (kirjoitusasuja) ja virhetilat
  for (const lang of ['fi', 'en']) {
    const name = `live kauppa saldo ${lang}`, page = await openShop(name, lang === 'fi' ? '/lahjakortti/' : '/en/gift-card/', { lang });
    await page.waitForSelector('#gift-balance .gc-balform', { timeout: 15000 });
    await page.fill('#gift-balance input', code.toLowerCase().replace(/-/g, ' ')); await page.click('#gift-balance button[type=submit]'); await page.waitForSelector('#gift-balance .gc-result', { timeout: 15000 });
    const sent = JSON.parse(page.calls.filter((c) => c.name === 'public_check_gift_card').at(-1).body);
    expect(sent.p_code === code.replace(/-/g, ''), `${name}: p_code normalisoitu (${sent.p_code})`);
    const t = (await page.locator('#gift-balance .gc-result').innerText()).replace(nbsp, '');
    expect(t.includes(code) && /31[,.]5/.test(t), `${name}: koodi ja saldo 31,50 (${t.replace(/\n/g, ' ').slice(0, 80)})`);
    await page.fill('#gift-balance input', 'HHZZ-ZZZZ-ZZZZ'); await page.click('#gift-balance button[type=submit]'); await page.waitForSelector('#gift-balance .bk-error');
    expect(/Koodia ei löytynyt|Code not found/.test(await page.locator('#gift-balance .bk-error').innerText()), `${name}: tuntematon koodi → invalid_code`);
    if (lang === 'fi') await shot(page, 'live-kauppa-saldo-fi-390');
    await page.context().close();
  }
  // 5) lunastus verkkokaupassa: uusi tilaus (134 €), osittainen lunastus 31,50 € + loppu toisella kortilla (58 €)
  {
    const o = await freshOrder(); const full = await must('admin_get_order', { p_order_id: o.order_id ?? o.id });
    const token = full.public_token, orderId = full.order_id, total = full.total;
    const name = 'live kauppa lunastus', page = await openShop(name, `/tilaus/?t=${token}`);
    await page.waitForSelector('[data-testid=gc-redeem]', { timeout: 15000 });
    expect(Math.abs(num(await page.locator('[data-testid=order-unpaid]').innerText()) - total) < 0.01, `${name}: maksamatonta ${total} €`);
    // virheet oikealta palvelimelta
    await page.fill('[data-testid=gc-code]', 'HHZZ-ZZZZ-ZZZZ'); await page.click('[data-testid=gc-apply]'); await page.waitForSelector('[data-testid=gc-msg] .bk-error');
    expect(/Koodia ei löytynyt/.test(await page.locator('[data-testid=gc-msg]').innerText()), `${name}: invalid_code`);
    await page.fill('[data-testid=gc-code]', code.toLowerCase()); await page.fill('[data-testid=gc-amount]', '40'); await page.click('[data-testid=gc-apply]');
    await page.waitForFunction(() => /saldo ei riitä/.test(document.querySelector('[data-testid=gc-msg]')?.innerText || ''), null, { timeout: 15000 });
    expect(true, `${name}: insufficient_balance`);
    await page.fill('[data-testid=gc-amount]', ''); await page.click('[data-testid=gc-apply]');
    await page.waitForFunction(() => /Lahjakortilla maksettu/.test(document.querySelector('[data-testid=order-msg]')?.innerText || ''), null, { timeout: 15000 });
    let c1 = await cardOf(code), pays = await orderPays(orderId);
    expect(c1.card?.balance === 0 || c1.balance === 0 || JSON.stringify(c1).includes('"balance":0'), `${name}: kortin saldo 0 (osittainen lunastus koko saldolla)`);
    expect(pays.some((p) => p.method === 'gift_card' && Math.abs(p.amount - 31.5) < 0.01), `${name}: gift_card-maksu 31,50 € tilauksella`);
    expect(Math.abs(num(await page.locator('[data-testid=order-unpaid]').innerText()) - (total - 31.5)) < 0.01, `${name}: maksamatonta ${total - 31.5} € jäljellä`);
    await shot(page, 'live-kauppa-lunastus-osittain-fi-390');
    await page.fill('[data-testid=gc-code]', code2); await page.fill('[data-testid=gc-amount]', '20'); await page.click('[data-testid=gc-apply]');
    await page.waitForFunction((u) => Math.abs(+document.querySelector('[data-testid=order-unpaid]').innerText.replace(/[^\d,]/g, '').replace(',', '.') - u) < 0.01, +(total - 51.5).toFixed(2), { timeout: 15000 });
    const sent2 = JSON.parse(page.calls.filter((c) => c.name === 'public_apply_gift_card').at(-1).body);
    expect(sent2.p_amount === 20 && sent2.p_code === code2.replace(/-/g, '') && sent2.p_token === token, `${name}: p_amount 20, normalisoitu koodi, token`);
    const c2 = await cardOf(code2); expect(JSON.stringify(c2).includes('"balance":38'), `${name}: toisen kortin saldo 38 (58 − 20)`);
    note(`lunastus verkkokaupassa: tilaus ${full.order_no}, kortit ${code.slice(-4)}/${code2.slice(-4)}`);
    await page.context().close();
  }
  // 6) kuvat FI/EN kaikilla leveyksillä (live-data)
  for (const lang of ['fi', 'en']) for (const vp of [360, 390, 430, 768, 1280]) {
    const name = `live kauppa kuva ${lang} ${vp}`, page = await openShop(name, lang === 'fi' ? '/lahjakortti/' : '/en/gift-card/', { vp, lang });
    await page.waitForSelector('#gift-app .gc-tile', { timeout: 15000 });
    await page.locator('#paketit .gc-tile').nth(1).locator('.gc-btn').click();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), `${name}: ei vaakavieritystä`);
    await shot(page, `live-kauppa-lahjakortti-${lang}-${vp}`); await page.context().close();
  }
}

// ================= TOIMITUSVALINTA (sopimus §13.11, migraatio booking_46) =================
const helDate = (add = 0, months = 0) => { const d = new Date(Date.now() + add * 864e5); const s = d.toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' }); if (!months) return s; const x = new Date(`${s}T12:00:00Z`); x.setUTCMonth(x.getUTCMonth() + months); return x.toISOString().slice(0, 10); };
async function deliveryLiveSuite() {
  const anon = { access_token: E.LIVE_ANON };
  // A) palvelimen virhekoodit (oikea public_buy_gift_card, anon) = asiakkaan tarkistuksen koodit
  const G = await import(pathToFileURL(join(ROOT, 'booking/shop/src/gift-logic.js')));
  const base = { p_name: 'Live Toimitus', p_email: `live-dlv-${RUN}@example.invalid`, p_phone: '+358401234567', p_marketing_consent: false, p_locale: 'fi' };
  let seq = 0;   // yksilöllinen sähköposti joka kutsulle (sähköpostikohtainen rajoitus 4 / 10 min)
  const buy = (item, extra = {}) => rpc('public_buy_gift_card', { ...base, p_email: `live-dlv-${RUN}-${++seq}@example.invalid`, p_items: [{ package: 'entry_2', quantity: 1, ...item }], ...extra }, anon);
  const R = { delivery_to: 'recipient', recipient_email: 'saaja@example.invalid' };
  const cases = [[{ delivery_to: 'muu' }, 'invalid_delivery_to'], [{ delivery_to: 'recipient' }, 'recipient_email_required'], [{ recipient_email: 'ei-sahkoposti' }, 'invalid_email'], [{ greeting: 'x'.repeat(301) }, 'invalid_greeting'],
    [{ ...R, cover_message: 'x'.repeat(1001) }, 'invalid_cover_message'], [{ ...R, deliver_on: helDate(-1) }, 'deliver_on_past'], [{ ...R, deliver_on: helDate(0, 7) }, 'deliver_on_too_far'], [{ ...R, deliver_on: 'ei-pvm' }, 'invalid_deliver_on'],
    [{ ...R, deliver_time: '10:00' }, 'invalid_deliver_on'], [{ ...R, deliver_on: helDate(30), deliver_time: '25:00' }, 'invalid_deliver_time']];
  for (const [item, code] of cases) { const r = await buy(item); const got = r.body?.code; expect(r.body?.ok === false && got === code && r.body.message, `palvelin: ${code} (sai ${got})`); }
  // asiakaspuolen tarkistus antaa samat koodit kuin palvelin (resoluutio)
  const now = new Date();
  for (const [it, code] of cases.filter(([i, c]) => !['invalid_greeting', 'invalid_email'].includes(c))) {
    const c = G.resolveDelivery({ to: it.delivery_to, recipientEmail: it.recipient_email, cover: it.cover_message, on: it.deliver_on, time: it.deliver_time, months: 6, now });
    expect(c.ok === false && c.code === code, `asiakas = palvelin: ${code} (asiakas ${c.code ?? 'ok'})`);
  }
  // tänään ilman kellonaikaa = heti (deliver_on null), pelkkä päivä → 09:00 (deliver_time null), 'buyer' ohittaa roskakentät
  const okNow = await buy({ ...R, recipient_name: 'Heti Saaja', deliver_on: helDate(0), cover_message: `Terve ${NOTE}` });
  expect(okNow.body?.ok === true && okNow.body.cards[0].delivery_to === 'recipient' && okNow.body.cards[0].deliver_on == null && okNow.body.cards[0].deliver_time == null, `palvelin: tänään ilman kellonaikaa = heti (${JSON.stringify(okNow.body?.cards?.[0])})`);
  const okBuyer = await buy({ delivery_to: 'buyer', cover_message: 'x', deliver_on: 'roskaa' });
  expect(okBuyer.body?.ok === true && okBuyer.body.cards[0].delivery_to === 'buyer' && okBuyer.body.cards[0].deliver_on == null, 'palvelin: buyer ohittaa saate- ja ajastuskentät');

  // B) kauppa (oikea selain): saajalle ajastettuna + ostajalle; palvelimen tila; tilaussivu ei näytä koodia/PDF:ää saajalle menevästä
  const buyerEmail = `live-dlv-ui-${RUN}@example.invalid`, day = helDate(0, 1);
  let tok;
  for (const lang of ['fi', 'en']) {
    const fi = lang === 'fi', name = `live toimitusvalinta kauppa ${lang}`, page = await openShop(name, fi ? '/lahjakortti/' : '/en/gift-card/', { vp: 390, lang });
    await page.waitForSelector('#gift-app .gc-tile', { timeout: 15000 });
    await page.locator('#paketit .gc-tile').nth(0).locator('.gc-btn').click(); await page.locator('#paketit .gc-tile').nth(0).locator('.gc-btn').click();
    const L = (i) => page.locator('.gc-line').nth(i), tid = (i, id) => L(i).locator(`[data-testid=${id}]`);
    await tid(0, 'dlv-recipient').check(); await tid(0, 'recipient-name').fill('Sanna Saaja'); await tid(0, 'recipient-email').fill(`live-saaja-${RUN}-${lang}@example.invalid`);
    await tid(0, 'when-later').check(); await tid(0, 'deliver-on').fill(day); await tid(0, 'deliver-time').fill('18:30');
    await tid(0, 'greeting').fill(`Kortin tervehdys ${NOTE}`); await tid(0, 'cover-message').fill(`Saateteksti ${NOTE}`);
    await page.fill('input[autocomplete=name]', 'Live Toimitus'); await page.fill('input[autocomplete=email]', fi ? buyerEmail : `en-${buyerEmail}`); await page.fill('input[autocomplete=tel]', '+358401234567'); await page.check('#gc-terms');
    await layoutLive(page, `${name} täytetty`); await shot(page, `live-toimitus-kauppa-taytetty-${lang}-390`);
    await page.click('.gc-submit'); await page.waitForSelector('.gc-done', { timeout: 20000 });
    const notes = await page.locator('[data-testid=done-delivery]').allInnerTexts();
    expect(notes.length === 2 && (fi ? /saajalle .* klo 18:30/.test(notes[0]) && /sinulle/.test(notes[1]) : /to the recipient on .*18:30/.test(notes[0]) && /to you/.test(notes[1])), `${name}: vahvistus kertoo valinnat (${notes.join(' | ')})`);
    await shot(page, `live-toimitus-kauppa-valmis-${lang}-390`);
    if (fi) tok = new URL(await page.locator('.gc-done a.btn').getAttribute('href'), ORIGIN).searchParams.get('t');
    await page.context().close();
    // palvelimen tila
    const rows = (await must('admin_list_gift_cards', { p_search: fi ? buyerEmail : `en-${buyerEmail}` })).rows.sort((a, b) => a.id - b.id);
    const rc = rows.find((r) => r.delivery_to === 'recipient'), bc = rows.find((r) => r.delivery_to === 'buyer');
    expect(rows.length === 2 && rc && bc, `${name}: palvelimella 2 korttia (recipient + buyer) (${rows.map((r) => r.delivery_to)})`);
    expect(rc.deliver_on === day && rc.deliver_time === '18:30' && rc.cover_message === `Saateteksti ${NOTE}` && rc.greeting === `Kortin tervehdys ${NOTE}` && rc.delivered_at == null && rc.recipient_email === `live-saaja-${RUN}-${lang}@example.invalid`, `${name}: recipient-kortin kentät palvelimella (${JSON.stringify({ ...rc, cover_message: '…', code: undefined, greeting: '…' }).slice(0, 300)})`);
    expect(bc.cover_message == null && bc.deliver_on == null && bc.deliver_time == null && bc.delivered_at == null, `${name}: buyer-kortilla ei saatetta eikä ajankohtaa`);
  }
  // C) tilaussivu maksun jälkeen: saajalle menevän koodi/PDF piilossa, ostajan kortilla Näytä koodi
  { const ord = (await must('admin_list_gift_cards', { p_search: buyerEmail })).rows.find((r) => r.buyer_email === buyerEmail);
    await must('admin_record_payment', { p_order_id: (await cardOf(ord.code)).purchase_order.order_id, p_method: 'cash', p_amount: 58 + 58, p_note: NOTE });
    globalThis.__cfgExtra = { giftCardPdf: true };
    for (const [lang, path] of [['fi', '/tilaus/'], ['en', '/en/order/']]) {
      const name = `live toimitus tilaussivu ${lang}`, page = await openShop(name, `${path}?t=${tok}`, { vp: 390, lang });
      await page.waitForSelector('[data-testid=gc-cards]', { timeout: 15000 });
      const cards = page.locator('[data-testid=gc-card]'); expect(await cards.count() === 2, `${name}: 2 korttia`);
      const recCard = cards.filter({ hasText: 'Sanna Saaja' }), buyCard = cards.filter({ hasNotText: 'Sanna Saaja' });
      expect(await recCard.locator('[data-testid=gc-show], [data-testid=gc-pdf], a[href*="gift-card-pdf"]').count() === 0 && !(await recCard.innerText()).includes(ord.code.slice(0, 4) + '-') , `${name}: saajalle menevällä kortilla ei koodia eikä PDF-linkkiä`);
      expect(/18:30/.test(await recCard.locator('[data-testid=gc-delivery]').innerText()), `${name}: toimituksen ajankohta näkyy (${await recCard.locator('[data-testid=gc-delivery]').innerText()})`);
      await page.waitForSelector('[data-testid=gc-codetext]', { timeout: 15000 });
      expect(await buyCard.locator('[data-testid=gc-show]').count() === 0 && await buyCard.locator('[data-testid=gc-codetext]').count() === 1, `${name}: ostajalle menevän kortin koodi näkyy (${(await cards.allInnerTexts()).join(' || ').replace(/\n/g, ' ').slice(0, 400)})`);
      expect(await page.locator('a[data-testid=gc-pdf]').count() === 1, `${name}: ostajalle menevällä kortilla PDF-linkki`);
      await page.mouse.move(0, 0); await shot(page, `live-toimitus-tilaus-${lang}-390`); await page.context().close();
    }
    globalThis.__cfgExtra = {};
    const api = (await rpc('public_get_order_gift_cards', { p_token: tok }, anon)).body;
    expect(api?.ok && api.cards.every((c) => !('cover_message' in c)) && api.cards.some((c) => c.delivery_to === 'recipient' && c.deliver_on === day && c.deliver_time === '18:30' && c.delivered_at == null), 'public_get_order_gift_cards: delivery_to/deliver_on/deliver_time, ei cover_message-kenttää');
  }
  // D) hallinta (oikea selain): myynti saajalle ajastettuna lomakkeella; kortin tiedot + palvelimen virhe kentän alla
  { const name = 'live toimitusvalinta hallinta', page = await openPage(name, admin, { vp: 390, hash: '#/talous?tab=giftcards' });
    await page.waitForSelector('[data-testid=gc-list]', { timeout: 20000 });
    await page.click('[data-testid=gc-new]'); await page.waitForSelector('dialog[open] [data-testid=gc-new-mode]');
    const $ = (id) => page.locator(`dialog[open] [data-testid=${id}]`);
    await page.selectOption('dialog[open] [data-testid=gc-new-mode]', 'cash'); await page.selectOption('dialog[open] [data-testid=gc-new-package]', 'entry_2');
    await page.fill('dialog[open] input[name=buyer_name]', 'Live Hallinta'); await page.fill('dialog[open] input[name=buyer_email]', `live-adm-${RUN}@example.invalid`);
    await $('gc-new-dlv-recipient').check(); await page.click('dialog[open] button[type=submit]'); await page.waitForFunction(() => document.querySelector('dialog[open] [data-testid=gc-new-err-recipientEmail]')?.textContent);
    expect(await $('gc-new-err-recipientEmail').innerText() === T['err.recipient_email_required'], `${name}: recipient_email_required kentän alla`);
    await $('gc-new-rec-email').fill(`live-adm-saaja-${RUN}@example.invalid`); await $('gc-new-when-later').check(); await $('gc-new-deliver-on').fill(day); await $('gc-new-deliver-time').fill('07:15');
    await $('gc-new-cover').fill(`Hallinnan saate ${NOTE}`); await page.fill('dialog[open] [data-testid=gc-new-note]', `${NOTE}: toimitus`);
    await shot(page, 'live-toimitus-hallinta-lomake-390');
    await page.click('dialog[open] button[type=submit]'); await page.waitForSelector('[data-testid=gc-result]', { timeout: 20000 });
    const code = await page.locator('[data-testid=gc-result-code]').first().innerText(); await page.keyboard.press('Escape');
    const g = await cardOf(code);
    expect(g.card.delivery_to === 'recipient' && g.card.deliver_on === day && g.card.deliver_time === '07:15' && g.card.cover_message === `Hallinnan saate ${NOTE}` && g.card.delivered_at == null && g.card.status === 'active', `${name}: kortti palvelimella (${JSON.stringify({ ...g.card, code: undefined, cover_message: '…' }).slice(0, 260)})`);
    await gcOpen(page, code); const dt = await page.locator('[data-testid=gc-detail]').innerText();
    expect(dt.includes(T['gc.d.dlv.recipient']) && dt.includes(T['gc.d.scheduled'].split(' {')[0]) && dt.includes('klo 7:15') && dt.includes(`Hallinnan saate`) && await page.locator('a[data-testid=gc-pdf]').count() === 1, `${name}: kortin tiedoissa toimitus, ajastus, saate ja Avaa PDF (${dt.replace(/\n/g, ' ').slice(-220)})`);
    await shot(page, 'live-toimitus-hallinta-kortti-390');
    // admin RPC:n virhekoodit (BK001, detail = koodi)
    for (const [extra, c] of [[{ p_delivery_to: 'muu' }, 'invalid_delivery_to'], [{ p_delivery_to: 'recipient' }, 'recipient_email_required'], [{ p_delivery_to: 'recipient', p_recipient_email: 'a@b.fi', p_deliver_on: helDate(-1) }, 'deliver_on_past'], [{ p_delivery_to: 'recipient', p_recipient_email: 'a@b.fi', p_deliver_on: helDate(0, 7) }, 'deliver_on_too_far'], [{ p_delivery_to: 'recipient', p_recipient_email: 'a@b.fi', p_cover_message: 'x'.repeat(1001) }, 'invalid_cover_message']]) {
      const r = await rpc('admin_create_gift_card', { p_package: 'entry_2', p_note: `${NOTE}: virhe`, ...extra }); expect(!r.ok && r.code === c, `admin_create_gift_card: ${c} (sai ${r.code})`);
    }
    await page.context().close(); }
}

// ================= AJO =================
try { if (!ONLY || ONLY === 'admin') await adminGiftSuite(); if (!ONLY || ONLY === 'shop') await shopGiftSuite(); if (!ONLY || ONLY === 'delivery') await deliveryLiveSuite(); } catch (e) { problems.push(`KESKEYTYI: ${e.stack?.split('\n').slice(0, 3).join(' | ')}`); }
await browser.close(); server.close();
for (const f of findings) console.log(`HAVAINTO: ${f}`);
console.log(`${checks} tarkistusta, ${problems.length} ongelmaa`);
if (problems.length) { for (const p of problems.slice(0, 60)) console.log(`✗ ${p}`); process.exit(1); }
console.log('LIVE-E2E (lahjakortit) OK');
