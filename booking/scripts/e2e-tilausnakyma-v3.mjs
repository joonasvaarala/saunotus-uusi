// E2E-kuvat (playwright-core + google-chrome): tilausnäkymä v3 (PR 1) hallinnan kokeilutilassa (?mock=1) omalla mock-datalla.
// Ei verkkokutsuja eikä tuotantoa. Ajo: PW_DIR=<kansio jossa playwright-core> node booking/scripts/e2e-tilausnakyma-v3.mjs
// SHOT_DIR oletus /tmp/tilausnakyma-v3, CHROME oletus /usr/bin/google-chrome. Työpöytä 1440 px, mobiili 390 px.
import { createServer } from 'node:http';
import { readFile, stat, mkdir } from 'node:fs/promises';
import { join, extname, dirname, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const pwPath = createRequire(import.meta.url).resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', here].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath)); const chromium = pw.chromium || pw.default.chromium;
const ROOT = resolve(here, '../..'), SHOT = resolve(process.env.SHOT_DIR || '/tmp/tilausnakyma-v3');
await mkdir(SHOT, { recursive: true });
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.svg': 'image/svg+xml', '.json': 'application/json' };
const server = createServer(async (req, res) => {
  const p = decodeURIComponent(new URL(req.url, 'http://x').pathname); let file;
  if (p === '/admin/config.js') { res.writeHead(200, { 'content-type': 'text/javascript' }); return res.end(`window.BOOKING_CONFIG={url:'http://127.0.0.1:9',anonKey:'x',rest:'/rest/v1',auth:'/auth/v1',functions:'/functions/v1',schema:'booking'};`); }
  if (p === '/admin/talous-mock.js') { res.writeHead(200, { 'content-type': 'text/javascript' }); return res.end(`export * from './talous-mock.real.js'; import * as real from './talous-mock.real.js';
export function createMock(o) { const m = real.createMock(o); return { ...m, rpc: (n, a) => (window.__ovRpc ? window.__ovRpc(n, a, () => m.rpc(n, a)) : m.rpc(n, a)) }; }`); }
  if (p === '/admin/talous-mock.real.js') file = join(ROOT, 'booking/admin/talous-mock.js'); else if (p === '/admin/sb.js') file = join(ROOT, 'booking/shared/sb.js'); else if (p.startsWith('/admin/')) file = join(ROOT, 'booking/admin', p.slice(7) || 'index.html'); else file = join(ROOT, 'booking', p);
  try { if ((await stat(file)).isDirectory()) file = join(file, 'index.html'); res.writeHead(200, { 'content-type': types[extname(file)] || 'application/octet-stream' }); res.end(await readFile(file)); } catch { res.writeHead(404); res.end(); }
});
await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
const O = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const problems = []; let checks = 0; const expect = (ok, m) => { checks++; if (!ok) problems.push(m); };

// Mock-data selaimessa (ajetaan sivulla ennen sovellusta): päivät suhteessa nykyhetkeen, Helsingin aika.
function installFixtures() {
  const hel = (dayOffset, hhmm) => {
    const d = new Date(); const ds = new Date(d.getTime() + dayOffset * 864e5).toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
    const guess = new Date(`${ds}T${hhmm}:00Z`); const off = (new Date(guess.toLocaleString('en-US', { timeZone: 'Europe/Helsinki' })) - new Date(guess.toLocaleString('en-US', { timeZone: 'UTC' }))) / 6e4;
    return new Date(guess.getTime() - off * 6e4).toISOString();
  };
  const cust = (id, name, extra = {}) => ({ id, name, email: `${name.split(' ')[0].toLowerCase()}@example.com`, phone: '+358 40 000 0000', customer_kind: 'private', ...extra });
  const R = (id, d, from, to, o = {}) => ({ id, status: 'confirmed', product_name: 'Saunahoito', mode: 'exclusive', starts_at: hel(d, from), ends_at: hel(d, to), persons: 2, notes: null, item_total: 85, item_id: id * 10, product_id: 3, option: null, option_choices: [], option_missing: false, addons: [], ...o });
  const bal = (total, paid, extra = {}) => ({ total, paid, refunded: 0, pending_link: 0, unpaid: Math.max(0, total - paid), unpaid_unlinked: Math.max(0, total - paid), net_paid: paid, ...extra });
  const base = (o) => ({ status: 'confirmed', payment_status: 'unpaid', source_channel: 'web', is_native: true, staff_can_add: true, can_add: true, invoice_locked: false, invoice_no: null, locale: 'fi',
    items: [], payments: [], receipts: [], refunds: [], emails: [], requests: [], voucher_claims: [], reservation_meta: [], refundable_by_payment: [], customer_note: null, internal_note: null, public_token: 'tok', order_page_path: 'https://saunotus.fi/tilaus/?t=tok', ...o });
  const items = (rs) => rs.flatMap((r) => [{ id: r.item_id, parent_item_id: null, kind: 'reservation', name: `${r.product_name}, ${r.persons} hlö`, quantity: 1, unit_price: r.item_total, line_total: r.item_total, vat_rate: 25.5 },
    ...r.addons.map((a, i) => ({ id: r.item_id + i + 1, parent_item_id: r.item_id, kind: 'addon', name: a.name, quantity: a.quantity, unit_price: a.unit_price, line_total: a.line_total, vat_rate: 25.5 }))]);
  const r7001 = R(1, 8, '16:00', '17:30', { option: { code: 'hunaja', name: 'Hunajahoito' }, option_choices: [{ code: 'hunaja', name: 'Hunajahoito' }, { code: 'savi', name: 'Savihoito' }], notes: 'Toivoi pyyhkeet valmiiksi. Tulee polkupyörällä.', addons: [{ addon_id: 2, name: 'Saunavihta', quantity: 1, unit_price: 13, line_total: 13, vat_rate: 25.5 }] });
  const r7003 = R(3, 0, '19:00', '20:30', { option: { code: 'hunaja', name: 'Hunajahoito' }, option_choices: [{ code: 'hunaja', name: 'Hunajahoito' }], notes: 'Toivoi pyyhkeet valmiiksi. Tulee polkupyörällä.', addons: [{ addon_id: 2, name: 'Saunavihta', quantity: 1, unit_price: 13, line_total: 13, vat_rate: 25.5 }] });
  const r7004a = R(41, 0, '18:30', '20:00', { product_name: 'Rituaali 90 min', persons: 3, item_total: 174, notes: 'Yksi osallistuja tulee vasta 16.45, aloittakaa ilman.', addons: [{ addon_id: 5, name: 'Saunajuoma', quantity: 2, unit_price: 6, line_total: 12, vat_rate: 14 }] });
  const r7004b = R(42, 39, '16:00', '19:00', { product_name: 'Yleinen vuoro', mode: 'shared', persons: 2, item_total: 60 });
  const r7005 = R(51, 3, '17:00', '18:30', { product_name: 'Rituaali 90 min', item_total: 116 });
  const r7008a = R(81, 10, '16:00', '19:00', { product_name: 'Rituaali', persons: 2, item_total: 174 });
  const r7008b = R(82, 11, '16:00', '19:00', { product_name: 'Yleinen vuoro', mode: 'shared', persons: 2, item_total: 60 });
  const ORDERS = {
    7001: base({ order_id: 7001, order_no: 7001, created_at: hel(-2, '12:50'), customer: cust(5, 'Maija Esimerkki'), balance: bal(98, 0), reservations: [r7001], items: items([r7001]),
      reservation_meta: [{ id: 1, space_code: 'rauni', rule_id: 9 }], customer_note: 'Olemme ensimmäistä kertaa hunajahoidossa.', internal_note: `${hel(-2, '12:50').slice(0, 16).replace('T', ' ')} verkkokauppa: tilaus luotu`,
      emails: [{ kind: 'order_confirmation', status: 'sent', sent_at: hel(-2, '12:51'), created_at: hel(-2, '12:51') }] }),
    7003: base({ order_id: 7003, order_no: 7003, created_at: hel(-3, '09:00'), customer: cust(6, 'Maija Esimerkki'), balance: bal(98, 0, { pending_link: 98 }), reservations: [r7003], items: items([r7003]),
      reservation_meta: [{ id: 3, space_code: 'rauni', rule_id: 9 }], customer_note: 'Olemme ensimmäistä kertaa hunajahoidossa.',
      payments: [{ id: 31, method: 'montonio', provider: 'montonio', status: 'pending', amount: 98, refunded_amount: 0, link_path: 'https://saunotus.fi/maksa/?p=abc', created_at: hel(-1, '09:02'), lines: [], receipts: [], refunds: [] }],
      emails: [{ kind: 'order_confirmation', status: 'sent', sent_at: hel(-3, '09:01') }, { kind: 'payment_link', status: 'sent', sent_at: hel(-1, '09:02') }] }),
    7004: base({ order_id: 7004, order_no: 7004, created_at: hel(-9, '09:14'), source_channel: 'admin', payment_status: 'invoiced', customer: cust(7, 'Erkki Esimerkki', { customer_kind: 'company', company: 'Esimerkki Oy', business_id: '1234567-8' }),
      balance: bal(246, 0), reservations: [r7004a, r7004b], items: items([r7004a, r7004b]), invoice_locked: true, invoice_no: 'L-2026-0142', staff_can_add: false,
      invoice: { id: 142, invoice_no: 'L-2026-0142', status: 'sent', invoice_date: hel(-1, '12:00').slice(0, 10), due_date: hel(13, '12:00').slice(0, 10), sent_at: hel(-1, '14:02'), total: 246 },
      reservation_meta: [{ id: 41, space_code: 'savusauna', rule_id: 4 }, { id: 42, space_code: 'savusauna', rule_id: 5 }],
      emails: [{ kind: 'order_confirmation', status: 'sent', sent_at: hel(-9, '09:15') }] }),
    7005: base({ order_id: 7005, order_no: 7005, created_at: hel(-1, '10:00'), customer: cust(8, 'Pekka Testinen'), balance: bal(116, 0), reservations: [r7005], items: items([r7005]),
      voucher_claims: [{ id: 9, source: 'kokemuskauppa', status: 'problem', problem_code: 'already_used', code_masked: '…36G5', reservation_id: 51, needs_review: true }] }),
    7008: base({ order_id: 7008, order_no: 7008, created_at: hel(-5, '10:00'), payment_status: 'paid', customer: cust(9, 'Ville Kokeilu'), balance: bal(234, 234), reservations: [r7008a, r7008b], items: items([r7008a, r7008b]),
      payments: [{ id: 80, method: 'montonio', provider: 'montonio', status: 'paid', amount: 234, refunded_amount: 0, paid_at: hel(-5, '10:02'), created_at: hel(-5, '10:01'), lines: [], receipts: [{ id: 1, receipt_no: 'K-2026-0099', kind: 'receipt', issued_at: hel(-5, '10:02') }], refunds: [] }],
      receipts: [{ id: 1, receipt_no: 'K-2026-0099', kind: 'receipt', issued_at: hel(-5, '10:02'), total: 234, payment_id: 80 }],
      refundable_by_payment: [{ payment_id: 80, method: 'montonio', provider: 'montonio', refundable: 234 }] }),
  };
  const row = (o) => ({ order_id: o.order_id, order_no: o.order_no, created_at: o.created_at, status: o.status, payment_status: o.payment_status, source_channel: o.source_channel, is_native: true,
    total: o.balance.total, paid: o.balance.paid, refunded: 0, unpaid: o.balance.unpaid, customer_name: o.customer.name, customer_company: o.customer.company || null, customer_kind: o.customer.customer_kind,
    first_start: o.reservations[0].starts_at, reservation_count: o.reservations.length, payment_count: o.payments.length, receipt_count: o.receipts.length, invoice_no: o.invoice_no, invoice_id: o.invoice?.id ?? null, invoice_status: o.invoice?.status ?? null });
  const CUSTOMER = { id: 5, name: 'Maija Esimerkki', email: 'maija@example.com', phone: '+358 40 000 0000', customer_kind: 'private', language: 'fi', notes: 'Pitää hiljaisista vuoroista. Ei hunaja-allergiaa (tarkistettu 6/2026).',
    marketing_consent: true, marketing_consent_at: '2026-04-03T10:00:00Z', marketing_consent_source: 'verkkovaraus', created_at: '2025-03-01T10:00:00Z', annual_cards: [],
    orders: [
      { order_id: 7001, order_no: 7001, status: 'confirmed', payment_status: 'unpaid', total: 98, created_at: hel(-2, '12:50'), channel: 'web', reservations: [{ id: 1, starts_at: r7001.starts_at, persons: 2, status: 'confirmed', product_name: 'Saunahoito' }] },
      { order_id: 6620, order_no: 6620, status: 'completed', payment_status: 'paid', total: 116, created_at: '2026-09-01T10:00:00Z', channel: 'web', reservations: [{ id: 2, starts_at: '2026-09-12T13:30:00Z', persons: 2, status: 'completed', product_name: 'Rituaali 90 min' }] },
      { order_id: 6231, order_no: 6231, status: 'completed', payment_status: 'paid', total: 60, created_at: '2026-07-20T10:00:00Z', channel: 'web', reservations: [{ id: 3, starts_at: '2026-08-02T13:00:00Z', persons: 2, status: 'completed', product_name: 'Yleinen vuoro' }] },
      { order_id: 5870, order_no: 5870, status: 'completed', payment_status: 'paid', total: 85, created_at: '2026-05-20T10:00:00Z', channel: 'web', reservations: [{ id: 4, starts_at: '2026-06-04T14:00:00Z', persons: 1, status: 'completed', product_name: 'Saunahoito' }] },
      { order_id: 5102, order_no: 5102, status: 'completed', payment_status: 'paid', total: 30, created_at: '2026-03-01T10:00:00Z', channel: 'admin', reservations: [{ id: 5, starts_at: '2026-03-12T14:00:00Z', persons: 1, status: 'no_show', product_name: 'Yleinen vuoro' }] },
      { order_id: 4877, order_no: 4877, status: 'completed', payment_status: 'paid', total: 30, created_at: '2026-02-01T10:00:00Z', channel: 'web', reservations: [{ id: 6, starts_at: '2026-02-14T14:00:00Z', persons: 1, status: 'completed', product_name: 'Naisten sauna' }] },
    ],
    open_balance: 98, open_orders: 1, stats: { orders: 6, first_order_at: '2025-03-01T10:00:00Z', visits: 4, last_visit: '2026-09-12T13:30:00Z', upcoming: 1, next_at: r7001.starts_at, no_show: 1, last_no_show: '2026-03-12T14:00:00Z' },
    gift_cards: { bought: [{ id: 1, code_masked: '****-****-7Q2X', kind: 'value', initial_amount: 60, balance: 0, valid_to: '2027-12-24', status: 'used' }, { id: 2, code_masked: '****-****-K8M4', kind: 'value', initial_amount: 60, balance: 60, valid_to: '2027-12-24', status: 'active' }], bought_count: 2, bought_total: 120, redeemed_count: 1 } };
  const history = { order_id: 7001, limit: 200, events: [{ id: 1, at: hel(-1, '08:30'), action: 'UPDATE', table: 'reservations', row_id: 1, actor_kind: 'staff', actor_name: 'Joonas', changes: [{ field: 'persons', from: 1, to: 2 }] }] };
  window.__ovFixtures = { ORDERS, rows: Object.values(ORDERS).sort((a, b) => b.order_no - a.order_no).map(row), CUSTOMER, history };
}
async function page(width, hash, { mobile = false } = {}) {
  const ctx = await browser.newContext({ viewport: { width, height: mobile ? 844 : 900 }, deviceScaleFactor: mobile ? 2 : 1, isMobile: mobile, hasTouch: mobile, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const pg = await ctx.newPage();
  pg.on('pageerror', (e) => problems.push(`pageerror ${e.message}`));
  pg.on('console', (m) => m.type() === 'error' && !/Failed to load resource/.test(m.text()) && problems.push(`console ${m.text()}`));
  await pg.addInitScript(installFixtures);
  await pg.goto(`${O}/admin/?mock=1&role=admin#/`);
  await pg.waitForFunction(() => window.__adminMock, null, { timeout: 15000 });
  await pg.evaluate(async () => {
    const sb = await import('/admin/sb.js'); const F = window.__ovFixtures; const base = window.__adminMock;
    const clone = (x) => JSON.parse(JSON.stringify(x));
    const ov = async (fn, a, fallback) => {
      if (fn === 'admin_list_orders') return { total: F.rows.length, rows: clone(F.rows) };
      if (fn === 'admin_get_order' && F.ORDERS[a.p_order_id]) return clone(F.ORDERS[a.p_order_id]);
      if (fn === 'admin_order_lookup') { if (F.ORDERS[a.p_order_no]) return { order_id: a.p_order_no, order_no: a.p_order_no }; const e = new Error('Tilausta ei löydy'); e.code = 'not_found'; throw e; }
      if (fn === 'admin_order_history') return clone(F.history);
      if (fn === 'admin_get_customer' && Number(a.p_id) === 5) return clone(F.CUSTOMER);
      // PR 2 (booking_280/281): peruutuksen valinnat vain, kun kuva-ajo kytkee ne päälle (window.__pr2Opts); kutsujen parametrit talteen
      if (fn === 'admin_reservation_cancel_options' && window.__pr2Opts?.[a.p_reservation_id]) return clone(window.__pr2Opts[a.p_reservation_id]);
      if (fn === 'admin_cancel_reservation' && window.__pr2Opts) { (window.__pr2Calls ||= []).push(clone(a)); return { ok: true, cancelled: true, refunds: [], refunded_total: 0, notified: a.p_notify === true }; }
      if (fn === 'admin_reservation_refund_preview') return { total: a.p_reservation_id === 82 ? 60 : 174, unallocated: 0, payments: [{ payment_id: 80, provider: 'montonio', amount: 60 }] };
      return fallback(fn, a);
    };
    window.__ovRpc = ov;
    sb.setRpcOverride((fn, a) => ov(fn, a, (n, x) => base.rpc(n, x)));
  });
  await pg.evaluate((h) => { location.hash = h; }, hash);
  await pg.waitForTimeout(1200);
  return pg;
}
const noHScroll = async (pg, name) => { const r = await pg.evaluate(() => ({ sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth })); expect(r.sw <= r.cw, `${name}: vaakavieritys ${r.sw}>${r.cw}`); };
const shot = (pg, name, full = false) => pg.screenshot({ path: join(SHOT, `${name}.png`), fullPage: full });

// 1) Työpöytä: lista + yhteenvetopaneeli, ↑/↓ ja Esc
{
  const pg = await page(1440, '#/tilaukset?tab=orders');
  await pg.waitForSelector('[data-testid=orders-list] li[data-order-id]', { timeout: 10000 });
  await pg.locator('[data-testid=orders-list] li[data-order-id="7001"] .tl-head').click();
  await pg.waitForSelector('[data-testid=order-summary] [data-testid=ov-sum-open]', { timeout: 5000 });
  expect(await pg.locator('[data-testid=order-summary]').isVisible(), 'yhteenveto ei näy');
  expect((await pg.locator('[data-testid=ov-sum-open]').textContent()).includes('98'), 'avoinna 98');
  expect(await pg.locator('[data-testid=ov-sum-sendLink]').count() === 1 && await pg.locator('[data-testid=ov-sum-takePayment]').count() === 1, 'tulevalle Lähetä maksulinkki + Ota maksu');
  expect(await pg.locator('[data-testid=ov-sum-arrive]').count() === 0, 'tulevalle ei Saapunut');
  expect(await pg.locator('[data-testid=ov-sum-note]').count() === 1, 'muistiinpano yhteenvedossa');
  await noHScroll(pg, 'lista+yhteenveto');
  await shot(pg, 'desktop-lista-yhteenveto');
  await pg.locator('body').click({ position: { x: 5, y: 880 } }).catch(() => {});
  await pg.keyboard.press('ArrowUp'); await pg.waitForTimeout(500);
  const after = await pg.locator('[data-testid=order-summary]').getAttribute('data-order-id');
  expect(after === '7003', `↑ vaihtaa edelliseen tilaukseen (${after})`);
  await pg.keyboard.press('Escape'); await pg.waitForTimeout(200);
  expect(await pg.locator('[data-testid=order-summary]').isHidden(), 'Esc sulkee');
  await pg.locator('[data-testid=orders-list] li[data-order-id="7005"] .tl-head').click(); await pg.waitForTimeout(700);
  expect(await pg.locator('[data-testid=order-summary] [data-testid=ov-problem-badge]').count() === 1, 'Ongelma-merkki yhteenvedossa');
  await shot(pg, 'desktop-lista-ongelma');
  await pg.context().close();
}
// 2) Työpöytä: koko tilaus 7001 (tuleva, maksamatta) + muutoshistoria
{
  const pg = await page(1440, '#/tilaukset/7001');
  await pg.waitForSelector('[data-testid=order-view] [data-testid=ov-title]', { timeout: 10000 });
  expect(await pg.locator('[data-testid=ov-row-arrive]').count() === 0, 'tulevalle ei Saapunut-rivitoimintoa');
  expect(await pg.locator('[data-testid=ov-note-text]').count() === 1, 'varauksen muistiinpano näkyy');
  expect(await pg.locator('[data-testid=ov-system-note]').count() === 1, 'internal_note vain luku');
  expect(await pg.locator('[data-slot=order-delete]').count() === 1, 'poistolle paikka');
  await pg.locator('[data-testid=ov-history]').click(); await pg.waitForTimeout(400);
  await noHScroll(pg, 'koko');
  await shot(pg, 'desktop-koko', true);
  await pg.locator('[data-testid=ov-more] summary').click(); await pg.waitForTimeout(200);
  await shot(pg, 'desktop-koko-valikko');
  await pg.context().close();
}
// 3) Työpöytä: monivaraus + laskulukko (7004)
{
  const pg = await page(1440, '#/tilaukset/7004');
  await pg.waitForSelector('[data-testid=ov-res]', { timeout: 10000 });
  expect(await pg.locator('[data-testid=ov-res]').count() === 2, '2 varausta');
  expect(await pg.locator('[data-testid=ov-row-arrive]').count() === 1, 'Saapunut vain tämän päivän varaukselle');
  expect(await pg.locator('[data-testid=ov-pay-take], [data-testid=ov-pay-link], [data-testid=ov-pay-refund]').count() === 0, 'laskulukko piilottaa maksutoiminnot');
  expect(await pg.locator('[data-testid=ov-open-billing]').count() === 1, 'Laskutus-linkki');
  await noHScroll(pg, 'monivaraus');
  await shot(pg, 'desktop-monivaraus', true);
  await pg.context().close();
}
// 4) Peruutusdialogi monivaraukselle (7008): vain varaus 2/2 + hyvitys
{
  const pg = await page(1440, '#/tilaukset/7008');
  await pg.waitForSelector('[data-testid=ov-cancel]', { timeout: 10000 });
  await pg.locator('[data-testid=ov-cancel]').click();
  await pg.waitForSelector('[data-testid=ov-cancel-flow]', { timeout: 5000 });
  await pg.locator('[data-testid=ov-cx-one-82] input').check(); await pg.waitForTimeout(400);
  await pg.locator('[data-testid=ov-cx-refund-full] input').check(); await pg.waitForTimeout(300);
  expect((await pg.locator('[data-testid=ov-cx-submit]').textContent()).includes('60'), 'vahvistus kertoo summan');
  expect(await pg.locator('dialog[open] input[type=number]').count() === 0, 'osasumman kenttä piilossa');
  await shot(pg, 'dialogi-peruutus-monivaraus');
  await pg.context().close();
}
// 4b) PR 2: lahjakorttikysymys (pakollinen) + peruutusviesti yhdelle varaukselle; koko tilaus: lahjakortti kerran, ei viestiä
{
  const pg = await page(1440, '#/tilaukset/7008');
  await pg.evaluate(() => { window.__pr2Opts = {
    81: { ok: true, reservation_id: 81, gift_cards: [], gift_card_total: 0, gift_card_choice_required: false, partner_share: 0, voucher_redeemed: false, order_stays: false, money_share: 174, customer_email: true },
    82: { ok: true, reservation_id: 82, gift_cards: [{ payment_id: 90, gift_card_id: 9, amount: 60, code_last4: '4821', valid_to: '2027-06-30', card_status: 'active', keep_allowed: true }], gift_card_total: 60, gift_card_choice_required: true, partner_share: 0, voucher_redeemed: false, order_stays: false, money_share: 0, customer_email: true } }; });
  await pg.waitForSelector('[data-testid=ov-cancel]', { timeout: 10000 });
  await pg.locator('[data-testid=ov-cancel]').click();
  await pg.waitForSelector('[data-testid=ov-cancel-flow]', { timeout: 5000 });
  await pg.locator('[data-testid=ov-cx-one-82] input').check(); await pg.waitForTimeout(500);
  expect(await pg.locator('[data-testid=ov-cx-gift]').count() === 1, 'PR 2: lahjakorttikysymys');
  expect(await pg.locator('[data-testid=ov-cx-gift] input:checked').count() === 0, 'PR 2: lahjakorttikysymyksellä ei oletusta');
  expect(await pg.locator('[data-testid=ov-cx-refund-full]').count() === 0, 'PR 2: lahjakorttiosuutta ei tarjota rahahyvityksenä');
  expect(await pg.locator('[data-testid=ov-cx-notify-yes]').count() === 1, 'PR 2: viestikysymys');
  await pg.locator('[data-testid=ov-cx-submit]').click(); await pg.waitForTimeout(300);
  expect(await pg.locator('dialog[open] .err:not([hidden])').count() === 1, 'PR 2: vastaamatta → pakollisuusilmoitus');
  expect(!(await pg.evaluate(() => window.__pr2Calls?.length)), 'PR 2: ei kutsua ennen vastauksia');
  await shot(pg, 'pr2-peruutus-lahjakortti-pakollinen');
  await pg.locator('[data-testid=ov-cx-gift-keep] input').check(); await pg.waitForTimeout(400);
  await pg.locator('[data-testid=ov-cx-notify-yes] input').check(); await pg.waitForTimeout(400);
  expect(await pg.locator('dialog[open] .err:not([hidden])').count() === 0, 'PR 2: vastaus poistaa pakollisuusilmoituksen');
  expect(/hyvityskuitti/.test(await pg.locator('[data-testid=ov-cx-notify-hint]').textContent()), 'PR 2: arvo palautuu kortille → vihje mainitsee hyvityksen');
  await shot(pg, 'pr2-peruutus-lahjakortti-valittu');
  await pg.locator('[data-testid=ov-cx-submit]').click(); await pg.waitForTimeout(600);
  const calls = await pg.evaluate(() => window.__pr2Calls || []);
  expect(calls.length === 1 && calls[0].p_reservation_id === 82 && calls[0].p_gift_card_keep === true && calls[0].p_notify === true, `PR 2: parametrit ${JSON.stringify(calls)}`);
  await pg.context().close();
}
{
  const pg = await page(1440, '#/tilaukset/7008');
  await pg.evaluate(() => { window.__pr2Opts = {
    81: { ok: true, reservation_id: 81, gift_cards: [], gift_card_total: 0, gift_card_choice_required: false, partner_share: 0, money_share: 174, customer_email: true },
    82: { ok: true, reservation_id: 82, gift_cards: [{ amount: 60, code_last4: '4821', valid_to: '2027-06-30', keep_allowed: true }], gift_card_total: 60, gift_card_choice_required: true, partner_share: 0, money_share: 0, customer_email: true } }; });
  await pg.waitForSelector('[data-testid=ov-cancel]', { timeout: 10000 });
  await pg.locator('[data-testid=ov-cancel]').click();
  await pg.waitForSelector('[data-testid=ov-cancel-flow]', { timeout: 5000 });
  await pg.locator('[data-testid=ov-cx-one-81] input').check(); await pg.waitForTimeout(500);
  expect(await pg.locator('[data-testid=ov-cx-gift]').count() === 0, 'PR 2: rahamaksulla ei lahjakorttikysymystä');
  expect(/ei mainita hyvitystä/.test(await pg.locator('[data-testid=ov-cx-notify-hint]').textContent()), 'PR 2: ei hyvitystä → ei hyvitysmainintaa');
  await shot(pg, 'pr2-peruutus-ei-hyvitysta-viesti');
  await pg.locator('[data-testid=ov-cx-all] input').check(); await pg.waitForTimeout(600);
  expect(await pg.locator('[data-testid=ov-cx-gift]').count() === 1, 'PR 2: koko tilaus → lahjakorttikysymys kerran');
  expect(await pg.locator('[data-testid=ov-cx-notify-yes]').count() === 0, 'PR 2: koko tilaus → ei viestikysymystä');
  expect(await pg.locator('[data-testid=ov-cx-refund-full]').count() === 0, 'PR 2: koko tilaus + lahjakortti → ei admin_refund_order-hyvitystä');
  await shot(pg, 'pr2-peruutus-koko-tilaus');
  await pg.context().close();
}
// 5) Mobiili: lista → koko tilaus suoraan (tänään, maksamatta) + alapalkki
{
  const pg = await page(390, '#/tilaukset?tab=orders', { mobile: true });
  await pg.waitForSelector('[data-testid=orders-list] li[data-order-id="7003"]', { timeout: 10000 });
  await pg.locator('[data-testid=orders-list] li[data-order-id="7003"] .tl-head').click();
  await pg.waitForSelector('[data-testid=order-view] [data-testid=ov-title]', { timeout: 10000 });
  expect(/#\/tilaukset\/7003$/.test(await pg.evaluate(() => location.hash)), 'mobiili avaa koko tilauksen');
  const bar = pg.locator('[data-testid=ov-mobile-bar]');
  expect(await bar.isVisible(), 'alapalkki näkyy');
  expect(await bar.locator('button').count() === 2, 'alapalkissa 2 toimintoa');
  expect(await pg.locator('[data-testid=ov-mbar-arrive]').count() === 1 && await pg.locator('[data-testid=ov-mbar-takePayment]').count() === 1, 'Saapunut + Ota maksu');
  await noHScroll(pg, 'mobiili');
  await shot(pg, 'mobiili');
  await shot(pg, 'mobiili-koko', true);
  await pg.locator('[data-testid=ov-back]').click(); await pg.waitForTimeout(1200);
  expect((await pg.evaluate(() => location.hash)).startsWith('#/tilaukset'), 'takaisin listaan');
  expect(await pg.locator('[data-testid=orders-list] li[data-order-id]').count() > 0, 'lista palautui');
  await pg.context().close();
}
// 6) Asiakasnäkymä työpöytä + mobiili
for (const [w, name, mobile] of [[1440, 'asiakas-desktop', false], [390, 'asiakas-mobiili', true]]) {
  const pg = await page(w, '#/asiakkaat/5', { mobile });
  await pg.waitForSelector('[data-testid=customer-view] [data-testid=cv-stats]', { timeout: 10000 });
  expect(await pg.locator('[data-testid=cv-order]').count() === 6, `${name}: 1 tuleva + 5 mennyttä`);
  expect(await pg.locator('text=Yhdistä').count() === 0, `${name}: ei yhdistä/poista`);
  await noHScroll(pg, name);
  await shot(pg, name, true);
  await pg.context().close();
}
await browser.close(); server.close();
console.log(`${checks} tarkistusta, ${problems.length} ongelmaa`);
for (const p of problems) console.log(' -', p);
console.log('kuvat:', SHOT);
process.exit(problems.length ? 1 : 0);
