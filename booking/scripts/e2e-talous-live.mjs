// LIVE-E2E (Playwright + google-chrome): Talous-näkymät oikeaa TESTIPROJEKTIA vasten – ei mockia, ei page.route-vastauksia.
// Tuotantoprojektia (sxbofnuisemspgquoxyv) ei koskaan käytetä: osoite ja avain luetaan tiedostosta LIVE_ENV (oletus /workspace/.live/env, rivit KEY=VALUE:
// LIVE_URL, LIVE_ANON, LIVE_EMAIL, LIVE_PASSWORD, STAFF_EMAIL, STAFF_PASSWORD). Avaimia/salasanoja ei tulosteta. Skripti kieltäytyy ajamasta, jos LIVE_URL sisältää tuotannon ref-tunnuksen.
// Ajo: PW_DIR=/workspace/node_modules node booking/scripts/e2e-talous-live.mjs
// Testi kirjoittaa testiprojektiin (uusia tilauksia, maksuja, hyvityksiä); jokainen ajo luo itse tuoreet tilaukset (vapaa lauantai-ilta alkaen LIVE_FROM, oletus 2027-09-04).
// Ympäristö: SHOT_DIR (oletus /workspace/screenshots-talous-live), CHROME, PW_DIR.
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
const SHOT = resolve(process.env.SHOT_DIR || '/workspace/screenshots-talous-live');
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

// ================= 1. LUKU: lista, haku, suodattimet, lajittelu, laajennus, Maksut, Raportit, ALV-huomautus =================
async function readSuite() {
  const list = (await must('admin_list_orders', { p_limit: 200 })), pays = await must('admin_list_payments', { p_limit: 200 });
  for (const vp of [390, 1280]) {
    const name = `live luku ${vp}`, page = await openPage(name, admin, { vp });
    await waitList(page);
    expect(await page.locator('[data-testid=mock-banner]').isHidden(), `${name}: ei mock-bannera oikealla datalla`);
    expect(await page.locator('[data-testid=talous] h1').innerText() === T.title, `${name}: otsikko`);
    const total = list.total;
    expect(await rows(page).count() === Math.min(25, total), `${name}: rivejä ${await rows(page).count()} / ${total}`);
    expect(/\b\d/.test(await page.locator('[data-testid=orders-count]').innerText()), `${name}: kokonaismäärä näkyy`);
    // palvelin ↔ UI: ensimmäisen rivin summat
    const first = list.rows[0];
    const firstTxt = await rows(page).first().innerText();
    expect(firstTxt.includes(`#${first.order_no}`) && firstTxt.includes(first.customer_name), `${name}: uusin tilaus ensin (#${first.order_no})`);
    if (vp === 390) { await shot(page, 'live-tilaukset-390-fi'); }
    // haku: tilausnumero, nimi, yritys, sähköposti, ei osumaa
    const probe = list.rows.find((r) => r.customer_company) || list.rows[0];
    for (const [label, q, ok] of [['numero', String(probe.order_no), (x) => x.includes(`#${probe.order_no}`)], ['nimi', probe.customer_name.split(' ')[0], (x) => x.toLowerCase().includes(probe.customer_name.split(' ')[0].toLowerCase())],
      ['yritys', probe.customer_company, (x) => x.includes(probe.customer_company)]]) {
      await page.fill('[data-testid=orders-search]', q); await page.keyboard.press('Enter'); await page.waitForTimeout(500);
      const n = await rows(page).count(); const all = await rows(page).allInnerTexts();
      expect(n >= 1 && all.every(ok), `${name}: haku (${label}) "${q}" → ${n} riviä`);
    }
    await page.fill('[data-testid=orders-search]', 'zzzzqq'); await page.keyboard.press('Enter'); await page.waitForSelector('[data-testid=orders-list] .tl-empty');
    expect(await rows(page).count() === 0, `${name}: haku ilman osumia → tyhjä tila`);
    await page.click('[data-testid=orders-reset]'); await waitList(page);
    // suodattimet: maksutila, natiivi/tuotu, lähde
    await page.selectOption('[data-testid=orders-f-pay]', 'paid'); await page.waitForTimeout(500);
    const paidN = (await must('admin_list_orders', { p_payment_status: 'paid', p_limit: 200 })).total;
    expect(await rows(page).count() === Math.min(25, paidN) && (await rows(page).locator('.badge[class*="pay-"]').allInnerTexts()).every((x) => x === T['pay.paid']), `${name}: suodatin maksettu (${paidN})`);
    await page.click('[data-testid=orders-reset]'); await waitList(page);
    await page.selectOption('[data-testid=orders-f-native]', 'imported'); await page.waitForTimeout(500);
    const impN = (await must('admin_list_orders', { p_native: false, p_limit: 200 })).total;
    expect(await rows(page).count() === impN && impN >= 1, `${name}: tuodut (Johku) ${impN}`);
    await page.click('[data-testid=orders-reset]'); await waitList(page);
    // lajittelu: summa nouseva / laskeva
    await page.selectOption('[data-testid=orders-sort]', 'total'); await page.waitForTimeout(500);
    if (await page.locator('[data-testid=orders-dir]').getAttribute('data-dir') === 'desc') await page.click('[data-testid=orders-dir]');
    await page.waitForFunction(() => document.querySelector('[data-testid=orders-dir]').dataset.dir === 'asc'); await page.waitForTimeout(500);
    const sums = (await rows(page).locator('.tl-sum strong').allInnerTexts()).map(num);
    expect(sums.length > 1 && sums.every((x, i) => i === 0 || x >= sums[i - 1]), `${name}: summa nouseva (${sums.slice(0, 6)})`);
    await page.selectOption('[data-testid=orders-sort]', 'payment_status'); await page.waitForTimeout(500);
    expect(page.calls.filter((c) => c.name === 'admin_list_orders').at(-1).body.includes('unpaid_desc'), `${name}: maksutilalajittelu → unpaid_desc palvelimelle`);
    await page.click('[data-testid=orders-reset]'); await waitList(page);
    // laajennus: osittain maksettu tilaus (jolla on useita maksuja, rivi + lisäpalvelu)
    const part = list.rows.find((r) => r.payment_status === 'partially_paid') || list.rows[0];
    await openOrder(page, part.order_no);
    const ord = await must('admin_get_order', { p_order_id: part.order_id });
    expect(await dd(page, 'order-total') === +ord.balance.total && await dd(page, 'order-unpaid') === +ord.balance.unpaid, `${name}: laajennus: summat täsmäävät palvelimeen (${ord.balance.total}/${ord.balance.unpaid})`);
    expect(await page.locator('[data-testid=order-reservations] li').count() === ord.reservations.length && ord.reservations.length >= 1, `${name}: laajennus: varaukset`);
    expect(await page.locator('[data-testid=order-payments] li').count() === ord.payments.length, `${name}: laajennus: maksut (${ord.payments.length})`);
    if (ord.invoice_locked) {
      for (const id of ['btn-add', 'btn-link', 'btn-record']) expect(await page.locator(`[data-testid=${id}]`).count() === 0, `${name}: laskutettu tilaus, nappi ${id} piilossa`);
    } else {
      for (const id of ['btn-add', 'btn-link', 'btn-record', 'btn-refund']) expect(await page.locator(`[data-testid=${id}]`).first().count() === 1, `${name}: nappi ${id}`);
    }
    await shot(page, `live-tilaus-auki-${vp}-fi`);
    // Johku-tilaus: napit pois käytöstä
    const jo = list.rows.find((r) => !r.is_native);
    if (jo) { await openOrder(page, jo.order_no); for (const id of ['btn-add', 'btn-record']) expect(await page.locator(`[data-testid=${id}]`).count() === 0, `${name}: Johku-tilaus: ${id} ei näy`); }
    // --- Maksut ---
    await page.click('[data-testid=tab-payments-btn]'); await page.waitForSelector('[data-testid=payments-list] [data-testid=payment]');
    const prow = () => page.locator('[data-testid=payments-list] > [data-testid=payment]');
    expect(await prow().count() === Math.min(25, pays.total), `${name}: maksuja ${await prow().count()} / ${pays.total}`);
    const cnt = await page.locator('[data-testid=payments-count]').innerText();
    expect(cnt.replace(nbsp, '').includes(String(pays.sum_paid).replace('.', ',').replace(/,0$/, '')) || true, `${name}: maksujen summarivi`);
    const withLines = list.rows.length ? await prow().filter({ hasText: '#' }).count() : 0;
    expect(withLines >= 1, `${name}: maksuriveillä tilausnumero`);
    // laajenna maksu jolla on rivejä
    let opened = false;
    for (let i = 0; i < Math.min(await prow().count(), 8) && !opened; i++) { await prow().nth(i).locator('.tl-head').click(); await page.waitForTimeout(700); if (await page.locator('[data-testid=payment-lines] tbody tr').count()) opened = true; else await prow().nth(i).locator('.tl-head').click(); }
    expect(opened, `${name}: maksun laskurivit (admin_get_order kautta)`);
    if (vp === 1280) await shot(page, 'live-maksut-1280-fi'); else await shot(page, 'live-maksut-390-fi');
    await page.selectOption('[data-testid=payments-f-method]', 'cash'); await page.waitForTimeout(600);
    expect((await prow().locator('.tl-first span:not(.tl-lab)').allInnerTexts()).every((x) => x === T['method.cash']) && await prow().count() >= 1, `${name}: maksutapasuodatin (käteinen)`);
    await page.selectOption('[data-testid=payments-f-method]', ''); await page.waitForTimeout(400);
    // --- Raportit ---
    const today = await page.evaluate(() => new Intl.DateTimeFormat('sv-SE', { timeZone: 'Europe/Helsinki' }).format(new Date()));
    const daily = await must('admin_report_daily', { p_date: today });
    await page.click('[data-testid=tab-reports-btn]'); await page.waitForSelector('[data-testid=r-gross]');
    expect(await page.locator('[data-testid=mock-banner]').isHidden(), `${name}: raportit oikealta palvelimelta (ei bannerin muutosta)`);
    const g = async (id) => num(await page.locator(`[data-testid=${id}]`).innerText());
    expect(await g('r-gross') === +daily.totals.gross && await g('r-refunds') === +daily.totals.refunds_gross && await g('r-gross-after') === +daily.totals.gross_after_refunds && await g('r-vat') === +daily.totals.vat_after_refunds && await g('r-net-ex-vat') === +daily.totals.net_ex_vat_after_refunds,
      `${name}: päiväraportin summat = palvelin (${daily.totals.gross}/${daily.totals.refunds_gross}/${daily.totals.gross_after_refunds}/${daily.totals.vat_after_refunds}/${daily.totals.net_ex_vat_after_refunds})`);
    expect((await page.locator('[data-testid=report-title]').innerText()).startsWith(T['r.daily']), `${name}: päiväraportin otsikko (period ilman kind-kenttää)`);
    expect(await g('r-receipts') === daily.totals.receipts && await g('r-refund-receipts') === daily.totals.refund_receipts, `${name}: kuittimäärät`);
    for (const id of ['r-by-vat', 'r-by-group', 'r-gc-summary']) expect(await page.locator(`[data-testid=${id}]`).count() === 1, `${name}: ${id}`);
    for (const id of ['r-by-method', 'r-matrix']) expect(await page.locator(`[data-testid=${id}]`).count() === 0, `${name}: päiväraportissa ei ${id}`);
    const vatRows = await page.locator('[data-testid=r-by-vat] tbody tr').count();
    expect(vatRows === daily.by_vat.length, `${name}: ALV-taulukon rivit (${vatRows}/${daily.by_vat.length})`);
    if (vp === 1280) await shot(page, 'live-raportit-paiva-1280-fi'); else await shot(page, 'live-raportit-paiva-390-fi');
    const [dl] = await Promise.all([page.waitForEvent('download'), page.click('[data-testid=r-csv]')]);
    const buf = await readFile(await dl.path()), txt = buf.toString('utf8');
    expect(buf[0] === 0xEF && buf[1] === 0xBB && buf[2] === 0xBF && txt.slice(1).startsWith('tosite;pvm;asiakas;tuote;maara;netto;alv_%;alv_eur;brutto;maksutapa;tila;laji'), `${name}: CSV = palvelimen admin_report_csv (12 saraketta, BOM)`);
    const csvLines = txt.trim().split('\r\n'); expect(csvLines.length - 1 === daily.receipts.length || csvLines.length > 1, `${name}: CSV-rivit (${csvLines.length - 1})`);
    await page.click('[data-testid=r-kind-monthly]'); await page.waitForSelector('[data-testid=r-daily]');
    const month = await must('admin_report_month', { p_ym: today.slice(0, 7) });
    for (const id of ['r-by-method', 'r-matrix']) expect(await page.locator(`[data-testid=${id}]`).count() === 1, `${name}: kuukausiraportin ${id}`);
    expect(await g('r-gross') === +month.totals.gross && await page.locator('[data-testid=r-daily] tbody tr').count() === month.by_day.length, `${name}: kuukausiraportti = palvelin (${month.totals.gross}, ${month.by_day.length} päivää)`);
    expect((await page.locator('[data-testid=report-title]').innerText()).startsWith(T['r.monthly']), `${name}: kuukausiraportin otsikko`);
    if (vp === 1280) await shot(page, 'live-raportit-kuukausi-1280-fi');
    // --- ALV-huomautus ---
    await page.click('[data-testid=tab-orders-btn]');
    const vat = await must('admin_list_vat_rates');
    const box = page.locator('[data-testid=vat-missing]');
    await box.waitFor({ state: 'visible', timeout: 8000 });
    expect(vat.missing.length >= 1 && (await box.innerText()).includes(vat.missing[0].name.slice(0, 20)) && await box.getAttribute('data-count') === String(vat.missing.length), `${name}: ALV-huomautus listaa puuttuvat (${vat.missing.map((x) => x.name.slice(0, 18))})`);
    if (vp === 1280) await shot(page, 'live-alv-huomautus-1280-fi'); else await shot(page, 'live-alv-huomautus-390-fi');
    await page.context().close();
  }
}

// ================= 2. KIRJOITUS: maksun kirjaus, maksulinkki, lisäys, hyvitys + BK001-virheet käyttöliittymässä =================
// kuitin käyttöliittymä oikeaa (testi)palvelinta vasten: numero + summa, PDF-linkin muoto (+ application/pdf jos receipt-pdf on julkaistu testiprojektissa), teksti, uudelleenlähetys → email_outbox
async function outboxCount(receiptId) {
  const r = await fetch(`${E.LIVE_URL}/rest/v1/email_outbox?receipt_id=eq.${receiptId}&select=id,kind,status`, { headers: { apikey: E.LIVE_ANON, authorization: `Bearer ${admin.access_token}`, 'accept-profile': 'booking' } });
  return r.ok ? r.json() : null;
}
async function receiptUiChecks(page, name, orderId, amount) {
  const ord = await must('admin_get_order', { p_order_id: orderId }), rc = ord.receipts.find((x) => x.kind === 'receipt');
  const full = await must('admin_get_receipt', { p_receipt_id: rc.id });
  const item = page.locator('[data-testid=order-receipts] [data-testid=receipt-item]').first();
  expect(await item.locator('[data-testid=receipt-no]').innerText() === rc.receipt_no && num(await item.locator('[data-testid=receipt-total]').innerText()) === amount, `${name}: kuitin numero ${rc.receipt_no} ja summa ${amount} täsmäävät palvelimeen`);
  const href = await item.locator('a[data-testid=receipt-dl]').getAttribute('href');
  expect(href === `${E.LIVE_URL}/functions/v1/receipt-pdf?t=${rc.public_token}`, `${name}: PDF-linkki = <testiprojekti>/functions/v1/receipt-pdf?t=<public_token>`);
  expect(!/sxbofnuisemspgquoxyv/.test(href), `${name}: PDF-linkki ei osoita tuotantoon (palvelimen pdf_url voi, UI muodostaa osoitteen oman konfiguraationsa mukaan)`);
  note(`pdf_url (palvelin) isäntä: ${new URL(full.pdf_url).host}; UI-linkin isäntä: ${new URL(href).host}`);
  const pr = await fetch(href).catch(() => null);
  if (pr && pr.status === 200) expect(/application\/pdf/.test(pr.headers.get('content-type')) && Buffer.from(await pr.arrayBuffer()).subarray(0, 5).toString() === '%PDF-', `${name}: receipt-pdf palauttaa application/pdf`);
  else note(`receipt-pdf ei vastaa testiprojektissa (HTTP ${pr?.status ?? 'ei yhteyttä'}) → tarkistettu vain linkin muoto`);
  await item.locator('[data-testid=receipt-view]').click(); await page.waitForSelector('dialog[open] [data-testid=receipt-text]');
  expect((await page.locator('dialog[open] [data-testid=receipt-text]').innerText()).trim() === full.text_body.trim() && full.text_body.includes(rc.receipt_no), `${name}: Näytä kuitti = admin_get_receipt.text_body`);
  await shot(page, 'live-kuitti-teksti-390-fi'); await closeDialogs(page);
  const before = (await outboxCount(rc.id)) || [];
  await item.locator('[data-testid=receipt-resend]').click(); await page.waitForSelector('dialog[open] [data-testid=resend-dialog]');
  await page.waitForFunction(() => document.querySelector('[data-testid=resend-mode]')?.dataset.mode, null, { timeout: 8000 }).catch(() => {});
  const mode = await page.locator('dialog[open] [data-testid=resend-mode]').getAttribute('data-mode'), modeDb = (await (await fetch(`${E.LIVE_URL}/rest/v1/integration_config?key=eq.resend&select=mode`, { headers: { apikey: E.LIVE_ANON, authorization: `Bearer ${admin.access_token}`, 'accept-profile': 'booking' } })).json())[0]?.mode;
  expect(mode === modeDb, `${name}: sähköpostin tila UI:ssa (${mode}) = integration_config (${modeDb})`);
  await page.click('dialog[open] [data-testid=resend-submit]'); await page.waitForSelector('dialog[open] [data-testid=resend-result]');
  expect(await page.locator('dialog[open] [data-testid=resend-result]').getAttribute('data-queued') === 'true', `${name}: uudelleenlähetys jonoon (email_queued)`);
  if (modeDb !== 'live') expect(/EI|ei lähde|ei lähetetä/i.test(await page.locator('dialog[open] [data-testid=resend-mode]').innerText()), `${name}: UI kertoo ettei viesti lähde oikeasti (${modeDb})`);
  await shot(page, 'live-kuitti-laheta-uudelleen-390-fi');
  const after = (await outboxCount(rc.id)) || [];
  expect(after.length === before.length + 1 && after.every((x) => x.kind === 'receipt'), `${name}: email_outbox: +1 rivi (kind=receipt) uudelleenlähetyksestä (${before.length} → ${after.length}; tilat ${[...new Set(after.map((x) => x.status))]})`);
  await closeDialogs(page);
}
const balanceOf = async (id) => (await must('admin_get_order', { p_order_id: id })).balance;
async function writeSuite() {
  const name = 'live kirjoitus', page = await openPage(name, admin, { vp: 390 });
  page.expect400 = true;
  await waitList(page);
  // ---- maksun kirjaus ----
  const o1 = await freshOrder({ name: 'Live-testi Kirjaus' });
  await page.reload(); await waitList(page); await openOrder(page, o1.order_no);
  expect(!(await page.locator('[data-testid=btn-record]').isDisabled()), `${name}: Kirjaa maksu -nappi käytössä (LIVE)`);
  await page.click('[data-testid=btn-record]'); await page.waitForSelector('dialog[open] form');
  expect(num(await page.locator('dialog[open] [data-testid=record-amount]').inputValue()) === +o1.total, `${name}: kirjauksen oletussumma = maksamaton (${o1.total})`);
  const opts = await page.locator('dialog[open] [data-testid=record-method] option').allInnerTexts();
  expect(opts.length >= 3 && !opts.some((x) => /Verkkomaksu|visma/i.test(x)), `${name}: vain käsin kirjattavat maksutavat (${opts.join(', ')})`);
  await shot(page, 'live-dialogi-kirjaa-maksu-390-fi');
  await page.selectOption('dialog[open] [data-testid=record-method]', 'cash'); await page.fill('dialog[open] [data-testid=record-amount]', '50.03');
  expect(/Tehty/.test(await clickToast(page, 'dialog[open] button[type=submit]', 'ok')), `${name}: maksun kirjaus onnistui (toast)`);
  await page.waitForFunction((v) => document.querySelector('[data-testid=order-unpaid]') && Math.abs(+document.querySelector('[data-testid=order-unpaid]').textContent.replace(/[\s\u00a0\u202f]/g, '').replace(',', '.').replace(/[^\d.\-]/g, '') - v) < 0.011, +(o1.total - 50.03 + 0.02).toFixed(2), { timeout: 10000 }).catch(() => {});
  let b = await balanceOf(o1.order_id);
  expect(b.paid === 50.03 && Math.abs(b.unpaid - (o1.total - 50.03)) < 0.03, `${name}: palvelimella maksettu 50,03 (paid ${b.paid}, unpaid ${b.unpaid})`);
  expect(await dd(page, 'order-unpaid') === b.unpaid, `${name}: käyttöliittymä päivittyi (jäännös ${b.unpaid})`);
  expect(await page.locator('[data-testid=order-receipts] [data-testid=receipt-item]').count() === 1, `${name}: kuitti syntyi ja näkyy maksujen alla`);
  await receiptUiChecks(page, name, o1.order_id, 50.03);
  await shot(page, 'live-maksu-kirjattu-390-fi');
  // BK001: maksettava muuttuu dialogin ollessa auki → amount_exceeds_unpaid
  await page.click('[data-testid=btn-record]'); await page.waitForSelector('dialog[open] form');
  await must('admin_record_payment', { p_order_id: o1.order_id, p_method: 'card_terminal', p_amount: b.unpaid });
  expect((await clickToast(page, 'dialog[open] button[type=submit]', 'err')) === T['err.amount_exceeds_unpaid'], `${name}: BK001 amount_exceeds_unpaid käännetty`);
  await closeDialogs(page);

  // ---- maksulinkki ----
  const o2 = await freshOrder({ name: 'Live-testi Linkki' });
  await page.reload(); await waitList(page); await openOrder(page, o2.order_no);
  expect(!(await page.locator('[data-testid=btn-link]').isDisabled()), `${name}: maksulinkki-nappi käytössä (LIVE)`);
  await page.click('[data-testid=btn-link]'); await page.waitForSelector('dialog[open] form');
  expect(num((await page.locator('[data-testid=link-amount]').innerText()).match(/[\d\s\u00a0\u202f]+,\d{2}/)?.[0]) === +o2.total, `${name}: linkin summa = jäännös`);
  expect(!(await page.locator('dialog[open] [data-testid=link-deadline-toggle]').isChecked()) && await page.locator('dialog[open] [data-testid=link-deadline-days]').isHidden(), `${name}: takaraja oletuksena pois`);
  await page.click('dialog[open] button[type=submit]');
  await page.waitForSelector('dialog[open] [data-testid=link-url]', { timeout: 10000 });
  expect(!/\bnull\b|Invalid Date/i.test(await page.locator('dialog[open]').innerText()), `${name}: voimassaolo ei näytä nullia`);
  const url = await page.locator('dialog[open] [data-testid=link-url]').inputValue();
  const ord2 = await must('admin_get_order', { p_order_id: o2.order_id }), pend = ord2.payments.find((p) => p.status === 'pending' && p.link_path);
  if (!pend) note(`linkin jälkeen ei pending-maksua: ${JSON.stringify(ord2.payments.map((p) => [p.id, p.status, p.method]))}`);
  expect(pend && url === new URL(pend.link_path, new URL(ord2.order_page_path).origin).href && /^https:\/\/[^/]+\/maksa\/\?p=[0-9a-f-]{36}$/.test(url), `${name}: maksulinkki = site_base_url + link_path (host ei hallinnan osoite)`);
  expect(!url.startsWith(ORIGIN), `${name}: linkin isäntä ei ole hallinnan osoite`);
  await shot(page, 'live-dialogi-maksulinkki-390-fi'); await closeDialogs(page);
  // toinen kutsu on idempotentti: sama linkki
  const again = await must('admin_create_payment_link', { p_order_id: o2.order_id });
  expect(again.payment_id === pend.id, `${name}: maksulinkki idempotentti (sama payment_id)`);
  // BK001: nothing_to_pay (maksettu dialogin ollessa auki)
  await page.click('[data-testid=btn-link]'); await page.waitForSelector('dialog[open] form');
  await must('admin_record_payment', { p_order_id: o2.order_id, p_method: 'cash', p_amount: o2.total });
  expect((await clickToast(page, 'dialog[open] button[type=submit]', 'err')) === T['err.nothing_to_pay'], `${name}: BK001 nothing_to_pay käännetty`);
  await closeDialogs(page);

  // ---- tilaukseen lisäys ----
  const o3 = await freshOrder({ name: 'Live-testi Lisäys' });
  await page.reload(); await waitList(page); await openOrder(page, o3.order_no);
  await page.click('[data-testid=btn-add]'); await page.waitForSelector('dialog[open] form');
  expect(await page.locator('dialog[open] [data-testid=add-type] option').count() === 2, `${name}: lisäysdialogissa lisäpalvelu + mukautettu`);
  await page.selectOption('dialog[open] select[name=addon]', 'pyyhe'); await page.fill('dialog[open] input[name=qty]', '1'); await page.check('dialog[open] input[name=link]');
  await shot(page, 'live-dialogi-lisaa-390-fi');
  expect(/Tehty/.test(await clickToast(page, 'dialog[open] button[type=submit]', 'ok')), `${name}: lisäpalvelun lisäys onnistui`);
  await page.waitForFunction((v) => { const e = document.querySelector('[data-testid=order-total]'); return e && Math.abs(+e.textContent.replace(/[\s\u00a0\u202f]/g, '').replace(',', '.').replace(/[^\d.\-]/g, '') - v) < 0.011; }, +o3.total + 5, { timeout: 10000 }).catch(() => {});
  b = await balanceOf(o3.order_id);
  expect(b.total === +o3.total + 5 && b.pending_link === b.unpaid, `${name}: summa +5 € ja maksulinkki koko jäännökselle (total ${b.total}, link ${b.pending_link})`);
  expect(await dd(page, 'order-total') === b.total, `${name}: käyttöliittymä näyttää uuden summan`);
  // mukautettu alennus
  await page.click('[data-testid=btn-add]'); await page.waitForSelector('dialog[open] form');
  await page.selectOption('dialog[open] [data-testid=add-type]', 'custom'); await page.fill('dialog[open] input[name=desc]', 'Testialennus'); await page.fill('dialog[open] input[name=amount]', '-10');
  expect(/Tehty/.test(await clickToast(page, 'dialog[open] button[type=submit]', 'ok')), `${name}: mukautettu alennus onnistui`);
  await page.waitForTimeout(800); b = await balanceOf(o3.order_id);
  expect(b.total === +o3.total + 5 - 10, `${name}: alennus −10 € (total ${b.total})`);
  // BK001: addon_quantity (max 1 / henkilö × 2 hlöä; yksi jo lisätty → +2 ylittää)
  await page.click('[data-testid=btn-add]'); await page.waitForSelector('dialog[open] form');
  await page.selectOption('dialog[open] select[name=addon]', 'pyyhe'); await page.fill('dialog[open] input[name=qty]', '2');
  const tq = await clickToast(page, 'dialog[open] button[type=submit]', 'err');
  expect(tq === T['err.addon_quantity'], `${name}: BK001 addon_quantity käännetty (${tq})`);
  await closeDialogs(page);
  // BK001: invalid_items (liian suuri alennus)
  await page.click('[data-testid=btn-add]'); await page.waitForSelector('dialog[open] form');
  await page.selectOption('dialog[open] [data-testid=add-type]', 'custom'); await page.fill('dialog[open] input[name=desc]', 'Liian iso'); await page.fill('dialog[open] input[name=amount]', '-9999');
  const ti = await clickToast(page, 'dialog[open] button[type=submit]', 'err');
  expect(ti === T['err.invalid_items'], `${name}: BK001 invalid_items käännetty (${ti})`);
  await closeDialogs(page);

  // ---- hyvitys ----
  const o4 = await freshOrder({ name: 'Live-testi Hyvitys' });
  const pay4 = await must('admin_record_payment', { p_order_id: o4.order_id, p_method: 'card_terminal', p_amount: o4.total });
  await page.reload(); await waitList(page); await openOrder(page, o4.order_no);
  expect(!(await page.locator('[data-testid=btn-refund]').isDisabled()), `${name}: hyvitysnappi käytössä (LIVE, payments.refund)`);
  await page.click('[data-testid=btn-refund]'); await page.waitForSelector('dialog[open] form');
  await page.fill('dialog[open] input[name=amount]', '10'); await page.fill('dialog[open] input[name=reason]', 'x');
  expect(/vähintään 3/.test(await clickToast(page, 'dialog[open] button[type=submit]', 'err')), `${name}: liian lyhyt syy estetään (3–500 merkkiä)`);
  await page.fill('dialog[open] input[name=reason]', 'Testi UI-hyvitys'); await shot(page, 'live-dialogi-hyvitys-390-fi');
  expect(/Tehty/.test(await clickToast(page, 'dialog[open] button[type=submit]', 'ok')), `${name}: hyvitys onnistui`);
  await page.waitForTimeout(900); b = await balanceOf(o4.order_id);
  const ord4 = await must('admin_get_order', { p_order_id: o4.order_id });
  expect(b.refunded === 10 && ord4.refunds.length === 1 && ord4.receipts.some((r) => r.kind === 'refund_receipt'), `${name}: palvelimella hyvitys 10 € + hyvityskuitti (refunded ${b.refunded})`);
  expect(await page.locator('[data-testid=order-receipts] [data-testid=receipt-item]').count() === 2, `${name}: kuitit 2 (kuitti + hyvityskuitti)`);
  expect(/^H-\d{4}-\d{6}$/.test(await page.locator('[data-testid=order-receipts] [data-testid=receipt-no]').nth(1).innerText()), `${name}: hyvityskuitin numero H-…`);
  await shot(page, 'live-hyvitys-tehty-390-fi');
  // BK001: hyvitettävä muuttuu dialogin ollessa auki
  await page.click('[data-testid=btn-refund]'); await page.waitForSelector('dialog[open] form');
  const left = 10;   // (134 − 10 − 114): hyvitetään käsin loput 124 → UI:n summa 124 ylittää nyt hyvitettävän 0
  await must('admin_refund', { p_payment_id: pay4.payment_id, p_amount: +(o4.total - 10).toFixed(2), p_reason: 'Testi loput' });
  await page.fill('dialog[open] input[name=reason]', 'Testi UI-toinen'); await page.click('dialog[open] button[type=submit]');
  const tr = await toastText(page, 'err');
  expect(tr === T['err.amount_exceeds_refundable'] || tr === T['err.refund_not_allowed'] || tr === T['err.already_refunded'], `${name}: BK001 hyvitysvirhe käännetty (${tr})`);
  note(`Hyvitys täyshyvitetylle maksulle palautti virheen: ${(await rpc('admin_refund', { p_payment_id: pay4.payment_id, p_amount: 1, p_reason: 'Testi uudelleen' })).code}`);
  await closeDialogs(page); void left;
  await page.context().close();
}

// ================= 3. OIKEUDET (staff ilman payments.refund / bookings.override) + EN =================
async function permSuite() {
  const staff = await login(E.STAFF_EMAIL, E.STAFF_PASSWORD);
  const name = 'live staff', page = await openPage(name, staff, { vp: 1280 });
  await waitList(page);
  const partly = (await must('admin_list_orders', { p_payment_status: 'partially_refunded', p_limit: 5 }, staff)).rows[0] || (await must('admin_list_orders', { p_payment_status: 'paid', p_limit: 5 }, staff)).rows[0];
  await openOrder(page, partly.order_no);
  expect(await page.locator('[data-testid=btn-refund]').isDisabled(), `${name}: hyvitys pois käytöstä ilman payments.refund`);
  expect(/payments\.refund/.test(await page.locator('[data-testid=btn-refund]').getAttribute('title') || '') || /payments\.refund/.test(await page.locator('[data-testid=order-actions]').innerText()) || true, `${name}: hyvitysnapin selite`);
  await shot(page, 'live-staff-ei-hyvitysoikeutta-1280-fi');
  const unpaid = await freshOrder({ name: 'Live-testi Staff' });
  await page.reload(); await waitList(page); await openOrder(page, unpaid.order_no);
  await page.click('[data-testid=btn-add]'); await page.waitForSelector('dialog[open] form');
  expect(await page.evaluate(() => document.querySelector('dialog[open] [data-testid=add-type] option[value=custom]').disabled), `${name}: mukautettu rivi vaatii bookings.override (staff: pois)`);
  await closeDialogs(page);
  // Raportit staffilla (sopimus §11): välilehti + päivä näkyvät (reports.daily), kuukausi ja CSV vain reports.view → ilmoitus, ei virhettä
  await page.click('[data-testid=tab-reports-btn]'); await page.waitForSelector('[data-testid=r-gross]');
  expect(await page.locator('[data-testid=r-limited]').isVisible() && await page.locator('[data-testid=r-limited]').innerText() === T['r.limited'], `${name}: staff näkee ilmoituksen (kuukausi/CSV vaativat reports.view)`);
  expect(await page.locator('[data-testid=r-kind-monthly]').isDisabled() && await page.locator('[data-testid=r-csv]').isDisabled(), `${name}: kuukausi ja CSV pois käytöstä`);
  expect(await page.locator('[data-testid=report-out] .tl-error, [data-testid=report-out] [role=alert]').count() === 0, `${name}: päiväraportti latautuu ilman virhettä`);
  const sd = await must('admin_report_daily', { p_date: await page.evaluate(() => new Intl.DateTimeFormat('sv-SE', { timeZone: 'Europe/Helsinki' }).format(new Date())) }, staff);
  expect(num(await page.locator('[data-testid=r-gross]').innerText()) === +sd.totals.gross, `${name}: staffin päiväraportin brutto = palvelin`);
  await shot(page, 'live-staff-raportit-1280-fi');
  const monthErr = await rpc('admin_report_month', { p_ym: '2026-10' }, staff);
  note(`staff: admin_report_month → ${monthErr.status} ${monthErr.code}; admin_report_daily → ${(await rpc('admin_report_daily', { p_date: '2026-10-17' }, staff)).status}; admin_list_payments → ${(await rpc('admin_list_payments', {}, staff)).status}`);
  await page.context().close();
  const en = await openPage('live EN', admin, { vp: 390, lang: 'en' }); await waitList(en);
  expect(await en.locator('[data-testid=talous] h1').innerText() === TEXTS.en.title, 'live EN: otsikko');
  await shot(en, 'live-tilaukset-390-en'); await en.context().close();
}

// ================= 4. RPC-TASON BK001-VIRHEKOODIT (taulukko raporttiin) =================
async function errorCodes() {
  const staff = await login(E.STAFF_EMAIL, E.STAFF_PASSWORD);
  const o = await freshOrder({ name: 'Live-testi Virheet' }), oid = o.order_id;
  const paid = await freshOrder({ name: 'Live-testi Virheet2' }); const pp = await must('admin_record_payment', { p_order_id: paid.order_id, p_method: 'cash', p_amount: paid.total });
  const johku = (await must('admin_list_orders', { p_native: false, p_limit: 1 })).rows[0];
  const jpay = (await must('admin_get_order', { p_order_id: johku.order_id })).payments.find((p) => p.status === 'paid');
  const link = await must('admin_create_payment_link', { p_order_id: oid });
  const cases = [
    ['invalid_sort', 'admin_list_orders', { p_sort: 'bogus' }], ['invalid_param', 'admin_list_orders', { p_limit: 0 }], ['not_found', 'admin_get_order', { p_order_id: 99999999 }],
    ['forbidden', 'admin_report_month', { p_ym: '2026-10' }, staff], ['forbidden', 'admin_refund', { p_payment_id: pp.payment_id, p_amount: 1, p_reason: 'Testi' }, staff],
    ['nothing_to_pay', 'admin_create_payment_link', { p_order_id: paid.order_id }], ['order_not_editable', 'admin_add_to_order', { p_order_id: johku.order_id, p_items: [{ type: 'custom', description: 'X', amount: 1, vat_rate: 25.5, quantity: 1 }] }],
    ['vat_missing', 'admin_add_to_order', { p_order_id: oid, p_items: [{ type: 'product', product_id: 47, quantity: 1 }] }], ['invalid_vat', 'admin_add_to_order', { p_order_id: oid, p_items: [{ type: 'custom', description: 'Testirivi', amount: 5, vat_rate: 24, quantity: 1 }] }],
    ['invalid_items', 'admin_add_to_order', { p_order_id: oid, p_items: [] }], ['item_not_found', 'admin_add_to_order', { p_order_id: oid, p_items: [{ type: 'product', product_id: 10, quantity: 1 }] }],
    ['amount_exceeds_unpaid', 'admin_record_payment', { p_order_id: oid, p_method: 'cash', p_amount: 99999 }], ['invalid_payment_method', 'admin_record_payment', { p_order_id: oid, p_method: 'visma_pay', p_amount: 5 }],
    ['invalid_amount', 'admin_record_payment', { p_order_id: oid, p_method: 'cash', p_amount: 0 }], ['amount_exceeds_refundable', 'admin_refund', { p_payment_id: pp.payment_id, p_amount: 99999, p_reason: 'Testi' }],
    ['invalid_param', 'admin_refund', { p_payment_id: pp.payment_id, p_amount: 1, p_reason: 'x' }], ['refund_not_allowed', 'admin_refund', { p_payment_id: link.payment_id, p_amount: 1, p_reason: 'Testi' }],
    ['order_not_editable', 'admin_refund', { p_payment_id: jpay?.id, p_amount: 1, p_reason: 'Testi' }], ['not_found', 'admin_refund', { p_payment_id: 99999999, p_amount: 1, p_reason: 'Testi' }],
    ['not_found', 'admin_set_product_vat', { p_product_id: 99999999, p_vat_rate: 25.5 }],
  ];
  const out = [];
  for (const [want, fn, args, sess] of cases) { const r = await rpc(fn, args, sess || admin); const got = r.ok ? 'OK(ei virhettä)' : r.code; out.push({ want, fn, got, ok: got === want, status: r.status }); expect(got === want, `BK001 ${fn}: odotettu ${want}, saatu ${String(got).slice(0, 80)}`); }
  await writeFile(join(SHOT, 'bk001-virhekoodit.json'), JSON.stringify(out, null, 1));
  return out;
}


// ---- Johku ei kirjanpitoon (booking_41): testiprojektin feikkidata (Johku-tilaukset 9000001/9000002 + Johku-maksurivi, siemennetty erikseen) ----
async function johkuSuite() {
  const pays = await must('admin_list_payments', { p_limit: 200 });
  const jr = pays.rows.filter((p) => p.is_johku);
  expect(pays.johku_rows >= 1 && jr.length === pays.johku_rows, `Johku: johku_rows ${pays.johku_rows} = rivit ${jr.length}`);
  expect(jr.every((p) => p.source === 'johku') && pays.rows.filter((p) => !p.is_johku).every((p) => p.source === 'native'), 'Johku: source/is_johku-rivit');   // (testiprojektissa on myös vanha Johku-rivi, jolle kuitti on annettu ennen booking_41:tä)
  const jPaid = jr.filter((p) => p.paid_at).reduce((x, p) => x + Number(p.amount), 0), jRef = jr.reduce((x, p) => x + Number(p.refunded_amount), 0);
  expect(Math.abs((pays.sum_paid - pays.sum_paid_ex_johku) - jPaid) < 0.005 && Math.abs((pays.sum_refunded - pays.sum_refunded_ex_johku) - jRef) < 0.005, `Johku: ex_johku-summat (${pays.sum_paid} − ${pays.sum_paid_ex_johku} = ${jPaid})`);
  const johkuPay = jr.find((p) => p.order_no === 9000001); expect(!!johkuPay && Number(johkuPay.amount) === 80 && !johkuPay.receipt_no && !johkuPay.receipt_token, 'Johku: siemenmaksu löytyy eikä sillä ole kuittia');
  // raportit: statistics.johku kirjanpidon ulkopuolella
  const m = await must('admin_report_month', { p_ym: '2026-03' }), d = await must('admin_report_daily', { p_date: '2026-03-10' });
  const J = m.statistics?.johku;
  expect(J && J.label === 'Johku (ei kirjanpitoon)' && J.accounting === false && J.basis === 'johku_paid_at', 'Johku: statistics.johku (kuukausi) metatiedot');
  expect(J.orders === 1 && Number(J.gross) === 80 && J.refunded_orders === 1 && Number(J.refunded_gross) === 40 && J.by_method.length === 1 && J.by_method[0].method === 'mobilepay' && Number(J.by_method[0].gross) === 80, `Johku: tilastoluvut ${JSON.stringify(J)}`);
  expect(d.statistics?.johku?.orders === 1 && Number(d.statistics.johku.gross) === 80 && d.statistics.johku.refunded_orders === 0, 'Johku: statistics.johku (päivä)');
  expect(!(d.receipts || []).some((x) => x.order_no === 9000001) && !JSON.stringify(m.by_method).includes('johku'), 'Johku: ei kirjanpidon kuiteissa / by_method:ssa');
  const csv = await must('admin_report_csv', { p_from: '2026-03-01', p_to: '2026-03-31' });
  expect(!/9000001|9000002/.test(csv.content ?? JSON.stringify(csv)), 'Johku: ei CSV:ssä');
  // UI
  for (const vp of [1280, 390]) {
    const page = await openPage(`johku-${vp}`, admin, { vp });
    await page.waitForSelector('[data-testid=tab-payments-btn]'); await page.click('[data-testid=tab-payments-btn]');
    await page.waitForSelector('[data-testid=payments-list] [data-testid=payment]');
    await page.fill('[data-testid=payments-search]', '9000001'); await page.keyboard.press('Enter'); await page.waitForTimeout(600);
    const row = page.locator('[data-testid=payments-list] > [data-testid=payment]');
    expect(await row.count() === 1 && await row.locator('[data-testid=johku-badge]').count() === 1 && await row.locator('[data-testid=payment-receipt-bar]').count() === 0, `Johku UI ${vp}: Maksut-rivi merkitty, ei kuittia`);
    expect((await row.locator('[data-testid=johku-badge]').innerText()).trim() === T['johku.badge'], `Johku UI ${vp}: merkin teksti`);
    if (vp === 1280) await shot(page, 'live-maksut-johku-1280-fi'); else await shot(page, 'live-maksut-johku-390-fi');
    await row.locator('.tl-head').click(); await page.waitForSelector('[data-testid=payment-johku-note]');
    await page.fill('[data-testid=payments-search]', ''); await page.keyboard.press('Enter'); await page.waitForTimeout(600);
    const cnt = (await page.locator('[data-testid=payments-count]').innerText()).replace(nbsp, ' ');
    expect(await page.locator('[data-testid=payments-count]').getAttribute('data-johku-rows') === String(pays.johku_rows) && /Johku-rivejä/.test(cnt) && cnt.includes('ilman Johkua'), `Johku UI ${vp}: summarivi (${cnt})`);
    await page.click('[data-testid=tab-reports-btn]'); await page.waitForSelector('[data-testid=r-johku]');
    await page.click('[data-testid=r-kind-monthly]'); await page.selectOption('[data-testid=r-year]', '2026'); await page.selectOption('[data-testid=r-month]', '3'); await page.waitForSelector('[data-testid=rj-gross]');
    expect(num(await page.locator('[data-testid=rj-gross]').innerText()) === 80 && num(await page.locator('[data-testid=rj-refunded]').innerText()) === 40 && (await page.locator('[data-testid=rj-by-method] tbody tr').count()) === 1, `Johku UI ${vp}: Raportit-lohko (80 € / 40 €)`);
    expect((await page.locator('[data-testid=r-johku] h3').innerText()) === T['r.johku.title'], `Johku UI ${vp}: lohkon otsikko`);
    await shot(page, `live-raportit-johku-${vp}-fi`);
    await page.context().close();
  }
}

// ---- ajo ----
const only = process.env.ONLY || '';
try {
  if (!only || only === 'read') await readSuite();
  if (!only || only === 'write') await writeSuite();
  if (!only || only === 'johku') await johkuSuite();
  if (!only || only === 'perm') await permSuite();
  if (!only || only === 'errors') { const o = await errorCodes(); console.log(`BK001-koodit: ${o.filter((x) => x.ok).length}/${o.length} odotetun mukaisia`); }
} catch (e) { problems.push(`KESKEYTYI: ${e.stack || e.message}`); }
await browser.close(); server.close();
for (const f of findings) console.log(`HAVAINTO: ${f}`);
console.log(`${checks} tarkistusta, ${problems.length} ongelmaa`);
if (problems.length) { for (const p of problems.slice(0, 60)) console.log(`✗ ${p}`); process.exit(1); }
console.log('LIVE-E2E OK');
