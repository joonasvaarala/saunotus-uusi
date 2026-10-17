// LIVE-E2E (Playwright + google-chrome): LAHJAKORTIT oikeaa TESTIPROJEKTIA vasten – ei mockia, ei page.route-vastauksia. Vaatii migraatiot 43–44 ja kytkimet gift_cards.sale_enabled / redeem_enabled = true TESTIPROJEKTISSA.
// Tuotantoprojektia (sxbofnuisemspgquoxyv) ei koskaan käytetä: osoite ja avain luetaan tiedostosta LIVE_ENV (oletus /workspace/.live/env, rivit KEY=VALUE:
// LIVE_URL, LIVE_ANON, LIVE_EMAIL, LIVE_PASSWORD, STAFF_EMAIL, STAFF_PASSWORD). Avaimia/salasanoja ei tulosteta. Skripti kieltäytyy ajamasta, jos LIVE_URL sisältää tuotannon ref-tunnuksen.
// Ajo: PW_DIR=/workspace/node_modules node booking/scripts/e2e-giftcards-live.mjs
// Testi kirjoittaa testiprojektiin (uusia lahjakortteja, tilauksia, maksuja; kaikki feikkidataa, muistiinpano 'E2E-feikkidata'); jokainen ajo luo itse tuoreet tilaukset (vapaa lauantai-ilta alkaen LIVE_FROM, oletus 2027-09-04).
// Ympäristö: SHOT_DIR (oletus /workspace/screenshots-lahjakortti-live), CHROME, PW_DIR.
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
  if (p === '/admin/config.js') { res.writeHead(200, { 'content-type': 'text/javascript' }); return res.end(`window.BOOKING_CONFIG=${JSON.stringify({ url: E.LIVE_URL, anonKey: E.LIVE_ANON, rest: '/rest/v1', auth: '/auth/v1', functions: '/functions/v1', schema: 'booking' })};`); }
  if (p === '/admin/sb.js') file = join(ROOT, 'booking/shared/sb.js');
  else if (p.startsWith('/admin/')) file = join(ROOT, 'booking/admin', p.slice(7) || 'index.html');
  else { res.writeHead(404); return res.end('Not found'); }
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
  await shot(page, 'live-lahjakortit-maksamaton-1280-fi');

  // ---- 5. voimassaolo, saldokorjaus, mitätöinti, aktivointi UI:sta ----
  await gcOpen(page, freeCode);
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

// ================= AJO =================
try { await adminGiftSuite(); if (typeof shopGiftSuite === 'function') await shopGiftSuite(); } catch (e) { problems.push(`KESKEYTYI: ${e.stack?.split('\n').slice(0, 3).join(' | ')}`); }
await browser.close(); server.close();
for (const f of findings) console.log(`HAVAINTO: ${f}`);
console.log(`${checks} tarkistusta, ${problems.length} ongelmaa`);
if (problems.length) { for (const p of problems.slice(0, 60)) console.log(`✗ ${p}`); process.exit(1); }
console.log('LIVE-E2E (lahjakortit) OK');
