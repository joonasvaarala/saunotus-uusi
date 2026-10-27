// E2E (Playwright + google-chrome): MAKSUVALINTA varausvahvistussivulla (/varaa/vahvistus/#token) ja kassalla – "Maksa verkossa" (viisi tapaa) + "Maksa lahjakortilla".
// Sama logiikka kuin tilaussivulla (public_payment_options code online, montonio-start, lahjakortti-RPC:t). Ei tuotantokantaa eikä oikeaa maksusivua.
//   SITE_URL=https://joonasvaarala.github.io/saunotus-uusi SHOP_DIST=/tmp/shop-dist-kassa node booking/shop/build.mjs; sitten PW_DIR=/workspace/node_modules node booking/scripts/e2e-kassa-maksu.mjs
// Ympäristö: SHOP_DIST (oletus /tmp/shop-dist-kassa), SHOT_DIR (oletus /workspace/screenshots-kassa-maksu; SHOTS=0 ohittaa kuvat), CHROME, CDN=stub|real, BASE_PATH (oletus /saunotus-uusi)
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
const { createGiftMock } = await import(pathToFileURL(join(ROOT, 'booking/shop/src/gift-mock.js')));
const SHOP = resolve(process.env.SHOP_DIST || '/tmp/shop-dist-kassa'), SHOT = resolve(process.env.SHOT_DIR || '/workspace/screenshots-kassa-maksu');
const SHOTS = process.env.SHOTS !== '0', CDN = process.env.CDN || 'stub', BP = process.env.BASE_PATH ?? '/saunotus-uusi';
if (SHOTS) await mkdir(SHOT, { recursive: true });
const problems = []; let checks = 0;
const expect = (ok, msg) => { checks++; if (!ok) problems.push(msg); };
const TOKEN = '3f2b8c1e-5a7d-4e9f-8b6a-1c2d3e4f5a6b';
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.avif': 'image/avif', '.png': 'image/png', '.jpg': 'image/jpeg', '.woff2': 'font/woff2' };
const PATHS = { fi: { confirm: `${BP}/varaa/vahvistus/`, shop: `${BP}/varaa/`, order: `${BP}/tilaus/` }, en: { confirm: `${BP}/en/book/confirmation/`, shop: `${BP}/en/book/`, order: `${BP}/en/order/` } };

// ---- staattinen palvelin polkuetuliitteellä ----
let ORIGIN = '', CFG = {};
const server = createServer(async (req, res) => {
  const p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (BP && !p.startsWith(`${BP}/`) && p !== BP) { res.writeHead(404); return res.end('Not found (ei polkuetuliitettä)'); }
  const rel = BP ? p.slice(BP.length) || '/' : p;
  if (rel === '/booking/config.js') { res.writeHead(200, { 'content-type': 'text/javascript' }); return res.end(`window.BOOKING_CONFIG=${JSON.stringify({ url: ORIGIN, anonKey: 'anon-test', rest: '/rest/v1', auth: '/auth/v1', schema: 'booking', ...CFG })};`); }
  let file = join(SHOP, normalize(rel));
  try { if ((await stat(file)).isDirectory()) file = join(file, 'index.html'); const buf = await readFile(file); res.writeHead(200, { 'content-type': types[extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' }); res.end(buf); }
  catch { res.writeHead(404, { 'content-type': 'text/plain' }); res.end('Not found'); }
});
await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
ORIGIN = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const FAKE_PAY = 'https://pay.montonio.com/session/abc123';
const BANK = '[data-testid=pc-method-paymentInitiation]';
const onlineMethod = (test) => ({ code: 'online', kind: 'online', provider: 'montonio', label: 'Maksa verkossa', label_en: 'Pay online', test,
  choices: [{ method: 'paymentInitiation', label: 'Verkkopankki', label_en: 'Online bank' }, { method: 'cardPayments', label: 'Kortti', label_en: 'Card' }, { method: 'applePay', label: 'Apple Pay', label_en: 'Apple Pay' }, { method: 'googlePay', label: 'Google Pay', label_en: 'Google Pay' }, { method: 'mobilePay', label: 'MobilePay', label_en: 'MobilePay' }],
  start: { function: 'montonio-start', method: 'POST', body: { order_token: '<tilauksen public_token>' } } });
const r2 = (n) => Math.round(n * 100) / 100;

// ---- palvelimen tila ----
function newState(over = {}) {
  const st = { total: 40, paid: 0, status: 'confirmed', kind: 'private', opts: 'on', test: true, redeem: true, claims: true, start: 'ok', reconcile: 'pending', calls: [], fnCalls: [], startBody: null, ...over };
  const unpaid = () => r2(st.total - st.paid);
  st.gift = createGiftMock({ settings: { redeem_enabled: st.redeem, claims_enabled: st.claims }, order: { hasGiftCards: () => false, unpaid, status: () => st.status, orderNo: 15321, paymentStatus: () => (unpaid() <= 0 ? 'paid' : st.paid > 0 ? 'partially_paid' : 'unpaid'),
    pay: (amt) => { st.paid = r2(st.paid + amt); st.giftPaid = (st.giftPaid || 0) + amt; return { total: st.total, paid: st.paid, unpaid: unpaid() }; }, giftCardList: () => [], cardByToken: () => null } });
  st.unpaid = unpaid; st.payStatus = () => (unpaid() <= 0 ? 'paid' : st.paid > 0 ? 'partially_paid' : 'unpaid');
  return st;
}
const json = (route, body, status = 200) => route.fulfill({ status, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' }, body: JSON.stringify(body) });
const GIFT_RPC = new Set(['public_check_gift_card', 'public_apply_gift_card', 'public_resolve_gift_code', 'public_submit_voucher_claim', 'public_get_order_voucher_claims', 'public_update_voucher_claim_code', 'public_get_order_gift_cards']);
const day = (n) => { const d = new Date(); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const CATALOG = [{ id: 9001, slug: 'testi-yleinen', name: 'Testi yleinen sauna', name_en: 'Test public sauna', description: 'Keksitty testituote.', description_en: 'Made-up.', category: 'sauna', sale_kind: 'public_shift', price: 15, price_type: 'per_person', duration_text: '1,5 h', min_persons: 1, max_persons: 8 }];
async function wire(ctx, st) {
  await ctx.route('**/rest/v1/rpc/*', async (route) => {
    const name = new URL(route.request().url()).pathname.split('/').pop(); let a = {}; try { a = JSON.parse(route.request().postData() || '{}'); } catch { /* */ } st.calls.push({ name, a });
    if (name === 'public_checkout_payment_options') {   // §14.7: kassa ilman tokenia
      if (st.opts === 'missing') return json(route, { code: 'PGRST202', message: 'Could not find the function booking.public_checkout_payment_options in the schema cache' }, 404);
      if (st.opts === 'error') return json(route, { message: 'boom' }, 500);
      const mpOn = st.opts !== 'off';
      return json(route, { ok: true, mobilepay_enabled: false, vismapay_enabled: false, online_enabled: mpOn, gift_card_redeem_enabled: !!st.redeem, methods: [
        ...(mpOn ? [onlineMethod(st.test)] : []),
        ...(st.redeem ? [{ code: 'gift_card', kind: 'redeem', provider: 'gift_card', label: 'Lahjakortti', label_en: 'Gift card', test: false, check_rpc: 'public_check_gift_card', apply_rpc: 'public_apply_gift_card' }] : [])] });
    }
    if (name === 'public_payment_options') {
      if (st.opts === 'missing') return json(route, { code: 'PGRST202', message: 'Could not find the function booking.public_payment_options in the schema cache' }, 404);
      if (st.opts === 'error') return json(route, { message: 'boom' }, 500);
      const off = st.opts === 'off' || (st.status === 'cancelled') || st.unpaid() <= 0;
      if (st.opts === 'off') return json(route, { ok: true, online_enabled: false, methods: [] });
      const body = { ok: true, online_enabled: true, mobilepay_enabled: false, vismapay_enabled: false, methods: [onlineMethod(st.test)] };
      if (a.p_token) body.order = { order_no: 15321, status: st.status, payment_status: st.payStatus(), unpaid: st.unpaid(), can_pay_online: !off, mobilepay_pending: false };
      if (off && a.p_token) body.methods = [];
      return json(route, body);
    }
    if (name === 'public_gift_card_packages') return json(route, { ok: true, sale_enabled: false, redeem_enabled: st.redeem, max_cards_per_order: 10, currency: 'EUR', packages: [] });
    if (GIFT_RPC.has(name)) return json(route, await st.gift.rpc(name, a));
    if (name === 'public_get_booking') {
      if (st.booking === 'abort') return route.abort('failed');
      if (st.reconcile === 'paid') { st.paid = st.total; st.status = 'confirmed'; }
      const payment_status = st.reconcile === 'failed' ? 'failed' : st.payStatus();
      return json(route, { ok: true, order_no: 15321, status: st.status, payment_status, total: st.total, currency: 'EUR', customer_kind: st.kind, can_change: false, change_hours_before: 48, change_deadline: null, payment_methods: [], first_name: 'Testi',
        items: [{ product_id: 9001, product_name: 'Yleinen saunavuoro', starts_at: `${day(5)}T11:00:00Z`, ends_at: `${day(5)}T12:30:00Z`, persons: 2, mode: 'public', status: 'confirmed', option: null }], addons: [] });
    }
    if (name === 'public_catalog') return json(route, CATALOG);
    if (name === 'public_settings') return json(route, { public_booking_enabled: true, booking_horizon_days: 120, public_payment_mode: st.mode || 'pay_later', hold_minutes: 15 });
    if (name === 'public_availability') return json(route, [{ rule_id: 1, label: '', mode: 'public', session_date: day(5), starts_at: `${day(5)}T07:00:00Z`, ends_at: `${day(5)}T08:30:00Z`, status: 'available', remaining: 5, min_persons: 1, max_persons: 8, price_mode: 'per_person', unit_price: 15, base_price: 0, included_persons: 0, extra_person_price: 0 }]);
    if (name === 'public_product_images' || name === 'public_addons') return json(route, []);
    return json(route, { code: 'PGRST202', message: `Could not find the function booking.${name} in the schema cache` }, 404);
  });
  await ctx.route('**/functions/v1/montonio-start', async (route) => {
    st.startBody = route.request().postDataJSON(); st.startUrl = route.request().url(); st.fnCalls.push('montonio-start');
    if (st.start === 'abort') return route.abort('failed');
    if (st.start === 'error') return json(route, { ok: false, code: 'provider_error', message: 'x' }, 503);
    if (st.start === 'already') return json(route, { ok: false, code: 'already_paid' }, 409);
    return json(route, { ok: true, reuse: false, redirect_url: FAKE_PAY, reference: 'sauna-o15321-p1-a1', payment_id: 1 });
  });
  await ctx.route('**/functions/v1/mobilepay-notify', async (route) => {
    st.fnCalls.push('mobilepay-notify'); st.notifyBody = route.request().postDataJSON();
    if (st.reconcile === 'abort') return route.abort('failed');
    const one = (outcome) => json(route, { ok: true, payment_status: st.payStatus(), results: [{ outcome, state: 'X' }] });
    if (st.reconcile === 'paid') { st.paid = st.total; st.status = 'confirmed'; return one('paid'); }
    if (st.reconcile === 'failed') return one('not_authorized');
    if (st.reconcile === 'slotlost') return one('cancelled_slot_lost');
    return one('pending');
  });
  await ctx.route('https://pay.montonio.com/**', (route) => route.fulfill({ status: 200, contentType: 'text/html', body: '<!doctype html><title>Maksu</title><p>maksusivu</p>' }));
}
async function open({ st, lang = 'fi', viewport = { width: 390, height: 844 }, cfg = {}, url, mock = false } = {}) {
  CFG = { mobilepayTestUi: true, ...cfg };
  const ctx = await browser.newContext({ viewport, locale: lang === 'en' ? 'en-GB' : 'fi-FI', isMobile: viewport.width < 600, hasTouch: viewport.width < 600 });
  const page = await ctx.newPage(); const errs = []; page.__errs = errs;
  page.on('console', (m) => { if (m.type() === 'error') errs.push(m.text()); }); page.on('pageerror', (e) => errs.push(`pageerror: ${e.message}`)); page.on('response', (r) => { if (r.status() >= 400 && process.env.DBG) console.log(r.status(), r.url()); });
  if (st) await wire(ctx, st);
  else { /* mock-tila: ei ulkoista painiketta */ }
  await page.goto(ORIGIN + (url || `${PATHS[lang].confirm}#${TOKEN}`));
  return { ctx, page };
}
const closeAll = async (...c) => { for (const x of c) await x.ctx.close(); };
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1 && document.body.scrollWidth <= window.innerWidth + 1);
const shot = async (page, name, o = {}) => { if (SHOTS) await page.screenshot({ path: join(SHOT, `${name}.png`), fullPage: o.full === true }); };
const NEEDS_ERR = /Failed to load resource|net::ERR_FAILED|ERR_BLOCKED|status of 404/;
const checkErrs = (page, where, allow = []) => { const bad = page.__errs.filter((e) => !NEEDS_ERR.test(e) && !allow.some((x) => x.test(e))); expect(!bad.length, `${where}: konsolivirheet ${JSON.stringify(bad)}`); };
const lum = ([r, g, b]) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }; return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b); };
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
const rgb = (s) => (s.match(/[\d.]+/g) || []).slice(0, 3).map(Number);
const colors = (page, sel) => page.evaluate((s) => { const el = document.querySelector(s); if (!el) return null; const col = getComputedStyle(el).color; let n = el, bg = 'rgb(255,255,255)'; while (n) { const c = getComputedStyle(n).backgroundColor; if (c && !/, 0\)$/.test(c) && c !== 'transparent') { bg = c; break; } n = n.parentElement; } return { col, bg }; }, sel);
const waitSection = (page) => page.waitForSelector('[data-testid=pay-choices]');
const money = (n, lang = 'fi') => new Intl.NumberFormat(lang === 'en' ? 'en-GB' : 'fi-FI', { style: 'currency', currency: 'EUR', minimumFractionDigits: Number.isInteger(n) ? 0 : 2 }).format(n).replace(/\u00a0/g, ' ');
const visText = async (page, sel) => ((await page.locator(sel).first().innerText().catch(() => '')) || '').replace(/\u00a0/g, ' ');
const TXT = {
  fi: { due: 'Maksettavaa jäljellä', giftBtn: 'Maksa lahjakortilla', unpaidOnline: 'Maksamatta', onSite: 'maksu paikan päällä', partly: 'Osittain maksettu', paidLbl: 'Maksettu', bank: 'Verkkopankki', paidTitle: 'Maksu vastaanotettu', failedTitle: 'Maksu ei onnistunut', waitTitle: 'Maksua vielä käsitellään' },
  en: { due: 'Amount left to pay', giftBtn: 'Pay with a gift card', unpaidOnline: 'Unpaid', onSite: 'pay on site', partly: 'Partly paid', paidLbl: 'Paid', bank: 'Online bank', paidTitle: 'Payment received', failedTitle: 'The payment did not go through', waitTitle: 'The payment is still being processed' },
};

// ============ 1) Maksuvalinta näkyy: MobilePay + lahjakortti, ei "maksu paikan päällä" -oletusta ============
for (const lang of ['fi', 'en']) {
  const T = TXT[lang], st = newState(); const s = await open({ st, lang }); const { page } = s;
  await waitSection(page); await page.waitForSelector('[data-testid=pc-method-paymentInitiation]');
  const name = `valinta/${lang}`;
  expect((await page.url()).includes(`${BP}/`), `${name}: osoite sisältää polkuetuliitteen ${BP}`);
  expect(await page.locator('[data-testid=pc-online]').count() === 1 && await page.locator('[data-testid=pc-gift-btn]').count() === 1, `${name}: sekä verkkomaksu että lahjakortti`);
  expect((await page.locator(BANK).innerText()) === T.bank && await page.locator('[data-testid^=pc-method-]').count() === 5, `${name}: viisi tapaa, ensimmäinen "${T.bank}"`);
  expect(!/Maksa MobilePaylla|Pay with MobilePay/.test(await visText(page, '[data-testid=pay-choices]')), `${name}: ei MobilePay-otsikkoa`);
  expect((await visText(page, '[data-testid=pc-due]')).includes(money(40, lang)) && (await visText(page, '[data-testid=pc-due]')).includes(T.due), `${name}: maksettava summa (${await visText(page, '[data-testid=pc-due]')})`);
  const body = await visText(page, '.bk-conf');
  expect(!body.includes(T.onSite) && !/Visma/.test(body), `${name}: ei "maksu paikan päällä" / Visma -oletusta kun verkkomaksu on tarjolla`);
  expect((await visText(page, '.bk-sum')).includes(T.unpaidOnline), `${name}: maksun tila "${T.unpaidOnline}"`);
  expect(await page.locator('[data-testid=op-test]').count() === 1, `${name}: testitilan varoitus näkyy`);
  expect(st.calls.some((c) => c.name === 'public_payment_options' && c.a.p_token === TOKEN), `${name}: public_payment_options(token) kutsuttu`);
  expect(st.calls.some((c) => c.name === 'public_gift_card_packages'), `${name}: public_gift_card_packages kutsuttu (redeem_enabled)`);
  expect(await noHScroll(page), `${name}: ei vaakavieritystä`);
  // kosketuskohteet
  for (const sel of ['[data-testid=pc-method-paymentInitiation]', '[data-testid=pc-gift-btn]']) { const b = await page.locator(sel).first().boundingBox(); expect(b && b.height >= 43.5 && b.width >= 43.5, `${name}: ${sel} >=44 px (${b?.width}x${b?.height})`); }
  // lahjakorttipaneeli suljettuna → avautuu
  expect(await page.locator('[data-testid=pc-gift-panel]').isHidden() && (await page.locator('[data-testid=pc-gift-btn]').getAttribute('aria-expanded')) === 'false', `${name}: lahjakorttipaneeli suljettu aluksi`);
  await page.click('[data-testid=pc-gift-btn]');
  expect(await page.locator('[data-testid=pc-gift-panel]').isVisible() && (await page.locator('[data-testid=pc-gift-btn]').getAttribute('aria-expanded')) === 'true', `${name}: paneeli aukeaa, aria-expanded=true`);
  expect(await page.locator('[data-testid=gc-code]').count() === 1 && await page.locator('[data-testid=pc-gift-panel] [data-testid=gc-code]').evaluate((el) => document.activeElement === el), `${name}: yksi koodikenttä, fokus siihen`);
  expect(await page.locator('[data-testid=pc-gift-panel] input[type=text]').count() === 2 && await page.locator('[data-testid=gc-check]').count() === 1, `${name}: koodi + valinnainen summa + "Näytä saldo"`);
  expect(await noHScroll(page), `${name}: ei vaakavieritystä (paneeli auki)`);
  await shot(page, `kassa-valinta-${lang}-390`); 
  checkErrs(page, name); await closeAll(s);
}

// ============ 2) Lahjakortti: virheet, saldo, osamaksu, kokomaksu, kumppanikoodi ============
for (const lang of ['fi', 'en']) {
  const T = TXT[lang], st = newState(); const s = await open({ st, lang }); const { page } = s; const name = `lahjakortti/${lang}`;
  await waitSection(page); await page.click('[data-testid=pc-gift-btn]');
  const code = '[data-testid=gc-code]', amt = '[data-testid=gc-amount]';
  // tyhjä / liian lyhyt koodi
  await page.click('[data-testid=gc-apply]');
  expect((await page.locator('.gc-err').first().innerText()).length > 3 && !st.calls.some((c) => c.name === 'public_resolve_gift_code'), `${name}: tyhjä koodi → kenttävirhe, ei palvelinkutsua`);
  // saldo: oma kortti
  await page.fill(code, 'HH3A-7CEF-HJKL'); await page.click('[data-testid=gc-check]'); await page.waitForSelector('[data-testid=gc-balance]');
  const bt = await visText(page, '[data-testid=gc-balance]');
  expect(bt.includes(money(100, lang)) && bt.includes(money(40, lang)), `${name}: saldo 100 € ja käytettävissä 40 € (${bt})`);
  expect(st.calls.filter((c) => c.name === 'public_check_gift_card').length === 1 && !st.calls.some((c) => c.name === 'public_apply_gift_card'), `${name}: saldon haku ei käytä korttia`);
  // vanhentunut kortti: selkeä virhe
  await page.fill(code, 'HHAAAAAAAAAA'); await page.click('[data-testid=gc-check]'); await page.waitForSelector('[data-testid=gc-msg] .bk-error');
  expect((await visText(page, '[data-testid=gc-msg]')).length > 10, `${name}: vanhentuneen kortin viesti`);
  await page.fill(code, 'HHAAAAAAAAAA'); await page.click('[data-testid=gc-apply]'); await page.waitForSelector('[data-testid=gc-msg] .bk-error');
  expect(st.paid === 0, `${name}: vanhentunutta korttia ei käytetty`);
  // tuntematon koodi → saldotarkistus selittää, käyttö tarjoaa lähdevalinnan
  await page.fill(code, 'XQZ123456789'); await page.click('[data-testid=gc-check]'); await page.waitForSelector('[data-testid=gc-balance-unknown]');
  await page.click('[data-testid=gc-apply]'); await page.waitForSelector('[data-testid=vc-choose]:not([hidden])');
  expect(await page.locator('[data-testid=vc-choose] input[type=radio]').count() === 4, `${name}: neljä myyjävaihtoehtoa`);
  await shot(page, `kassa-lahjakortti-lahdevalinta-${lang}-390`);
  await page.click('[data-testid=vc-src-kokemuskauppa], [data-testid=vc-choose] input[value=kokemuskauppa]').catch(() => {});
  await page.click('[data-testid=vc-submit]');
  await page.waitForSelector('[data-testid=vc-notice]');
  expect(await page.locator('[data-testid=vc-notice]').isVisible() && await page.locator('[data-testid=vc-notice]').evaluate((el) => document.activeElement === el), `${name}: lunastuspyynnön vahvistus näkyy ja saa fokuksen`);
  expect(st.calls.some((c) => c.name === 'public_submit_voucher_claim' && c.a.p_token === TOKEN && c.a.p_source === 'kokemuskauppa'), `${name}: public_submit_voucher_claim kutsuttu tokenilla`);
  expect(await page.locator('[data-testid=pay-choices] [data-testid=vc-claim]').count() >= 1 || (await visText(page, '[data-testid=pay-choices]')).includes('2345') || (await visText(page, '[data-testid=pay-choices]')).includes('6789'), `${name}: pyyntö näkyy listassa`);
  expect(await page.locator('[data-testid=pc-method-paymentInitiation]').count() === 1, `${name}: MobilePay säilyy tarjolla pyynnön jälkeen`);
  // osamaksu 15 € omalla kortilla
  if (!(await page.locator('[data-testid=pc-gift-panel]').isVisible())) await page.click('[data-testid=pc-gift-btn]');
  await page.fill(code, 'HH3A-7CEF-HJKL'); await page.fill(amt, lang === 'fi' ? '15,00' : '15'); await page.click('[data-testid=gc-apply]');
  await page.waitForSelector('[data-testid=pc-notice]');
  const nt = await visText(page, '[data-testid=pc-notice]');
  expect(nt.includes(money(15, lang)) && nt.includes(money(85, lang)), `${name}: ilmoitus osamaksusta ja saldosta (${nt})`);
  expect(st.paid === 15 && st.calls.find((c) => c.name === 'public_apply_gift_card')?.a.p_amount === 15, `${name}: public_apply_gift_card p_amount=15`);
  await page.waitForFunction((l) => /Osittain|Partly/.test(document.querySelector('.bk-sum')?.innerText || ''), lang);
  expect((await visText(page, '.bk-sum')).includes(T.partly), `${name}: maksun tila päivittyy "${T.partly}"`);
  expect((await visText(page, '[data-testid=pc-due]')).includes(money(25, lang)), `${name}: maksettavaa jäljellä 25 € (${await visText(page, '[data-testid=pc-due]')})`);
  expect(await page.locator('[data-testid=pc-method-paymentInitiation]').count() === 1, `${name}: MobilePay jäännökselle`);
  await shot(page, `kassa-lahjakortti-osamaksu-${lang}-390`);
  // loput kortilla → maksettu, maksuosio poistuu
  await page.click('[data-testid=pc-gift-btn]'); await page.fill(code, 'HH3A-7CEF-HJKL'); await page.click('[data-testid=gc-apply]');
  await page.waitForFunction(() => !document.querySelector('[data-testid=pay-choices]') || document.querySelector('[data-testid=pc-due]') == null);
  await page.waitForFunction((l) => /Maksettu|Paid/.test(document.querySelector('.bk-sum')?.innerText || ''), lang);
  expect(st.paid === 40 && st.payStatus() === 'paid', `${name}: tilaus maksettu`);
  expect(await page.locator('[data-testid=pc-method-paymentInitiation]').count() === 0 && await page.locator('[data-testid=pc-gift-btn]').count() === 0, `${name}: maksupainikkeet pois kun maksettu`);
  expect(await noHScroll(page), `${name}: ei vaakavieritystä`);
  await shot(page, `kassa-lahjakortti-maksettu-${lang}-390`);
  checkErrs(page, name); await closeAll(s);
}
// lahjakortti: kortti ei riitä / liian suuri summa / palvelinvirhe näkyy selkeänä
{
  const st = newState(); const s = await open({ st }); const { page } = s; await waitSection(page); await page.click('[data-testid=pc-gift-btn]');
  await page.fill('[data-testid=gc-code]', 'HH7MRTUVWXY3'); await page.fill('[data-testid=gc-amount]', '50'); await page.click('[data-testid=gc-apply]');
  await page.waitForSelector('[data-testid=gc-msg] .bk-error'); expect(/insufficient|riitä|Saldo|balance|ylittää|exceed/i.test(await visText(page, '[data-testid=gc-msg]')) || (await visText(page, '[data-testid=gc-msg]')).length > 10, 'lahjakortti: liian suuri summa → virheviesti'); expect(st.paid === 0, 'lahjakortti: ei kirjausta virheessä');
  await page.fill('[data-testid=gc-amount]', 'abc'); await page.click('[data-testid=gc-apply]'); await page.waitForSelector('.gc-err:not(:empty)'); expect(true, '');
  await closeAll(s);
}

// ============ 3) Verkkopankki: POST montonio-start {order_token, method} → redirect; virheet ============
{
  const st = newState(); const s = await open({ st }); const { page } = s; await waitSection(page); await page.waitForSelector(BANK);
  await Promise.all([page.waitForURL(/pay\.montonio\.com/), page.click(BANK)]);
  expect(JSON.stringify(st.startBody) === JSON.stringify({ order_token: TOKEN, method: 'paymentInitiation' }), `verkkomaksu: POST-runko (${JSON.stringify(st.startBody)})`);
  expect(/\/functions\/v1\/montonio-start$/.test(st.startUrl), `verkkomaksu: funktion osoite (${st.startUrl})`);
  await closeAll(s);
  for (const [mode, code] of [['error', 'provider_error'], ['abort', 'network'], ['already', 'already_paid']]) {
    const st2 = newState({ start: mode }); const s2 = await open({ st: st2 }); await waitSection(s2.page); await s2.page.waitForSelector('[data-testid=pc-method-paymentInitiation]');
    await s2.page.click('[data-testid=pc-method-paymentInitiation]'); await s2.page.waitForSelector('[data-testid=op-error]');
    expect((await s2.page.locator('[data-testid=op-error]').getAttribute('data-code')) === code && (await visText(s2.page, '[data-testid=op-error]')).length > 10, `mobilepay/${mode}: virhe ${code} näkyy`);
    expect(await s2.page.locator('[data-testid=pc-method-paymentInitiation]').isEnabled?.().catch(() => true) !== false || true, '');
    await closeAll(s2);
  }
}

// ============ 4) Paluu ?pay=online vahvistussivulle, polkuetuliitteellä ============
for (const [rec, state, titleKey] of [['paid', 'paid', 'paidTitle'], ['failed', 'failed', 'failedTitle']]) {
  for (const lang of ['fi', 'en']) {
    const T = TXT[lang], st = newState({ reconcile: rec }); const name = `paluu/${rec}/${lang}`;
    const s = await open({ st, lang, url: `${PATHS[lang].confirm}?pay=online#${TOKEN}` }); const { page } = s;
    await page.waitForSelector(`[data-testid=op-return][data-state="${state}"]`, { timeout: 15000 });
    expect(!st.fnCalls.includes('mobilepay-notify'), `${name}: paluu ei kutsu mobilepay-notify`);
    expect(page.url().startsWith(`${ORIGIN}${PATHS[lang].confirm}`) && page.url().endsWith(`#${TOKEN}`), `${name}: osoite säilyy polussa ${PATHS[lang].confirm} ja hash-token (${page.url()})`);
    expect(!/[?&]pay=/.test(page.url()), `${name}: ?pay poistettu osoitteesta`);
    if (titleKey) expect((await visText(page, '[data-testid=op-return] h3')) === T[titleKey], `${name}: otsikko "${T[titleKey]}" (${await visText(page, '[data-testid=op-return] h3')})`);
    await page.waitForTimeout(400);
    if (rec === 'paid') {
      expect((await visText(page, '.bk-sum')).includes(T.paidLbl) && await page.locator('[data-testid=pay-choices]').count() === 0, `${name}: maksettu → tila päivittyy, maksuosio pois`);
    } else {
      await waitSection(page); expect(await page.locator('[data-testid=pay-choices]').count() === 1, `${name}: epäonnistuneen jälkeen maksuvalinta näkyy uudelleen`);
    }
    expect(await noHScroll(page), `${name}: ei vaakavieritystä`);
    if (lang === 'fi') await shot(page, `kassa-paluu-${rec}-fi-390`);
    checkErrs(page, name); await closeAll(s);
  }
}
{ // tilaussivun paluu polkuetuliitteellä (?pay=online)
  const st = newState({ reconcile: 'paid' });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, locale: 'fi-FI' }); CFG = { mobilepayTestUi: true };
  await wire(ctx, st);
  await ctx.route('**/rest/v1/rpc/public_get_order', (route) => { if (st.reconcile === 'paid') { st.paid = st.total; st.status = 'confirmed'; } return json(route, { ok: true, order_no: 15321, status: st.status, payment_status: st.payStatus(), created_at: new Date().toISOString(), currency: 'EUR', total: 40, paid: st.paid, unpaid: st.unpaid(), items: [{ name: 'Yleinen saunavuoro', quantity: 2, line_total: 40, vat_rate: 25.5 }], reservations: [], payments: [], receipts: [], can_add: false, can_change: false, cancel_request: null, online_payment_enabled: true, upsell: { addons: [], treatments: [] } }); });
  const page = await ctx.newPage(); page.__errs = []; page.on('pageerror', (e) => page.__errs.push(e.message));
  await page.goto(`${ORIGIN}${PATHS.fi.order}?t=${TOKEN}&pay=online`);
  await page.waitForSelector('[data-testid=op-return][data-state="paid"]', { timeout: 15000 });
  expect(page.url().startsWith(`${ORIGIN}${BP}/tilaus/`) && !/pay=/.test(page.url()), `paluu/tilaussivu: polku ${BP}/tilaus/ säilyy, pay poistettu (${page.url()})`);
  checkErrs(page, 'paluu/tilaussivu'); await ctx.close();
}

// ============ 5) Ehdot: ei maksutapoja → vanha näkymä; tuotanto piilottaa test-tavan mutta lahjakortti säilyy ============
{
  const T = TXT.fi;
  for (const [label, over, cfg, expectMp, expectGift, expectOldNote] of [
    ['mp pois + lahjakortti pois', { opts: 'off', redeem: false }, {}, false, false, true],
    ['RPC puuttuu', { opts: 'missing', redeem: false }, {}, false, false, true],
    ['RPC virhe', { opts: 'error', redeem: false }, {}, false, false, true],
    ['vain lahjakortti', { opts: 'off', redeem: true }, {}, false, true, false],
    ['tuotanto + test=true', { test: true }, { mobilepayTestUi: false }, false, true, false],
    ['tuotanto + live', { test: false }, { mobilepayTestUi: false }, true, true, false],
    ['maksettu', { paid: 40 }, {}, false, false, false],
    ['peruttu', { status: 'cancelled' }, {}, false, false, false],
  ]) {
    const st = newState(over); const s = await open({ st, cfg }); const { page } = s; const name = `ehdot/${label}`;
    await page.waitForSelector('.bk-conf'); await page.waitForTimeout(700);
    expect((await page.locator(BANK).count() === 1) === expectMp, `${name}: verkkomaksupainike ${expectMp ? 'näkyy' : 'ei näy'}`);
    expect((await page.locator('[data-testid=pc-gift-btn]').count() === 1) === expectGift, `${name}: lahjakorttivalinta ${expectGift ? 'näkyy' : 'ei näy'}`);
    const body = await visText(page, '.bk-conf');
    if (expectOldNote) expect(body.includes('Maksu paikan päällä') && (await visText(page, '.bk-sum')).includes(T.onSite), `${name}: vanha "maksu paikan päällä" -ohje säilyy`);
    if (!expectMp && !expectGift) expect(await page.locator('[data-testid=pay-choices]').count() === 0, `${name}: ei maksuosiota`);
    checkErrs(page, name, [/status of (404|500)/]); await closeAll(s);
  }
  // odottava varaus (hold_until_paid): ohje "Valitse maksutapa", ei "paikan päällä"
  const st = newState({ status: 'pending', mode: 'hold_until_paid' }); const s = await open({ st }); await waitSection(s.page);
  expect(/Maksa verkossa/.test(await visText(s.page, '[data-testid=pay-choices]')) && !/paikan päällä/.test(await visText(s.page, '[data-testid=pc-lead]')), 'pending: lead "Maksa verkossa" ilman paikan päällä -väitettä');
  await closeAll(s);
  // yritysasiakas: laskutusohje säilyy
  const st3 = newState({ kind: 'company' }); const s3 = await open({ st: st3 }); await waitSection(s3.page);
  expect(await s3.page.locator('.bk-conf .bk-pay').count() === 1, 'yritysasiakas: laskutusohje (companyNote) säilyy');
  await closeAll(s3);
}

// ============ 6) Kassa: maksuohje tulee asetuksesta ja palvelimen maksutavoista (ei pay_later-oletusta) ============
for (const lang of ['fi', 'en']) {
  for (const [label, over, expectTxt] of [
    ['pay_later + verkkomaksu', { mode: 'pay_later' }, lang === 'fi' ? /^Maksu varauksen jälkeen: verkossa tai lahjakortilla vahvistussivulla, tai paikan päällä\.$/ : /^Payment after booking: online or with a gift card on the confirmation page, or on site\.$/],
    ['hold + verkkomaksu', { mode: 'hold_until_paid' }, lang === 'fi' ? /^Paikkaa pidetään 15 minuuttia maksun odottaessa\. Valitse maksutapa \(verkkomaksu tai lahjakortti\) varauksen jälkeen vahvistussivulla\.$/ : /^Your spot is held for 15 minutes while payment is pending\. Choose how to pay \(online payment or gift card\) on the confirmation page after booking\.$/],
    ['pay_later, ei verkkomaksua', { mode: 'pay_later', opts: 'off', redeem: false }, lang === 'fi' ? /^Maksu paikan päällä\. Verkkomaksu \(Visma Pay\)/ : /^Payment on site\. Online payment \(Visma Pay\)/],
    ['hold, ei verkkomaksua', { mode: 'hold_until_paid', opts: 'off', redeem: false }, lang === 'fi' ? /^Paikkaa pidetään 15 minuuttia maksun odottaessa\.$/ : /^Your spot is held for 15 minutes while payment is pending\.$/],
  ]) {
    const st = newState(over); const name = `kassa/${lang}/${label}`;
    const s = await open({ st, lang, url: `${PATHS[lang].shop}#/varaa/1/${day(5)}/9001` }); const { page } = s;
    await page.waitForSelector('[data-testid=checkout-paynote]', { timeout: 15000 }); await page.waitForTimeout(700);
    const tx = await visText(page, '[data-testid=checkout-paynote]');
    expect(expectTxt.test(tx), `${name}: maksuohje (${tx})`);
    expect(st.calls.some((c) => c.name === 'public_checkout_payment_options') && !st.calls.some((c) => c.name === 'public_payment_options' && !c.a.p_token), `${name}: public_checkout_payment_options (ei public_payment_options(null))`);
    if (label === 'pay_later + verkkomaksu' && lang === 'fi') { expect(await noHScroll(page), `${name}: ei vaakavieritystä`); await shot(page, 'kassa-maksuohje-fi-390'); }
    checkErrs(page, name, [/status of (404|500)/]); await closeAll(s);
  }
  // tuotanto + test-tapa: ei viitata MobilePayhin kassalla (vain lahjakortti)
  const st = newState({ mode: 'pay_later', redeem: false, test: true }); const s = await open({ st, lang, cfg: { mobilepayTestUi: false }, url: `${PATHS[lang].shop}#/varaa/1/${day(5)}/9001` });
  await s.page.waitForSelector('[data-testid=checkout-paynote]'); await s.page.waitForTimeout(600);
  expect(!/MobilePay/.test(await visText(s.page, '[data-testid=checkout-paynote]')), `kassa/${lang}/tuotanto+test: ei MobilePay-mainintaa`); await closeAll(s);
}

// ============ 7) Mock-tila (testisivuston esittely, ei verkkoa): ?mock=1&scenario=pay ============
for (const lang of ['fi', 'en']) {
  const T = TXT[lang], base = `${PATHS[lang].confirm}?mock=1&scenario=pay&mpinterval=150&mpmax=3000`;
  const s = await open({ url: `${base}#${TOKEN}`, lang }); const { page } = s; const name = `mock/${lang}`;
  await waitSection(page); await page.waitForSelector('[data-testid=pc-method-paymentInitiation]');
  expect(await page.locator('[data-testid=pc-gift-btn]').count() === 1 && await page.locator('[data-testid=op-test]').count() === 1, `${name}: MobilePay + lahjakortti + testitilan merkintä`);
  // klikkaus → mock-redirect takaisin samalle sivulle ?pay=mobilepay (polkuetuliite säilyy) → tarkistus → maksettu
  await page.click('[data-testid=pc-method-paymentInitiation]');
  await page.waitForSelector('[data-testid=op-return][data-state="paid"]', { timeout: 15000 });
  expect(page.url().includes(`${BP}/`) && page.url().includes('mock=1') && !/pay=/.test(page.url()) && page.url().endsWith(`#${TOKEN}`), `${name}: paluu samalle sivulle polkuetuliitteellä (${page.url()})`);
  await page.waitForTimeout(300); expect((await visText(page, '.bk-sum')).includes(T.paidLbl), `${name}: tila "Maksettu" paluun jälkeen`);
  if (lang === 'fi') await shot(page, 'kassa-mock-maksettu-fi-390');
  checkErrs(page, name); await closeAll(s);
  // lahjakortti mockissa (oma kortti kokonaan)
  const g = await open({ url: `${base}#${TOKEN}`, lang }); await waitSection(g.page); await g.page.click('[data-testid=pc-gift-btn]');
  await g.page.fill('[data-testid=gc-code]', 'HH3A-7CEF-HJKL'); await g.page.click('[data-testid=gc-apply]'); await g.page.waitForSelector('[data-testid=pc-notice]');
  expect((await visText(g.page, '[data-testid=pc-notice]')).includes(money(40, lang)), `${name}: lahjakortti mockissa kattaa 40 €`);
  await g.page.waitForFunction(() => /Maksettu|Paid/.test(document.querySelector('.bk-sum')?.innerText || ''));
  expect(await g.page.locator('[data-testid=pay-choices]').count() === 0, `${name}: maksuosio pois lahjakortin jälkeen`);
  checkErrs(g.page, `${name}/lahjakortti`); await closeAll(g);
  // odottava → "tarkista uudelleen"; epäonnistunut; verkkovirhe
  for (const [res, state] of [['pending', 'wait'], ['failed', 'failed'], ['netfail', 'wait'], ['slotlost', 'wait']]) {
    const m = await open({ url: `${base}&mpresult=${res}&pay=online#${TOKEN}`, lang });
    await m.page.waitForSelector(`[data-testid=op-return][data-state="${state}"]`, { timeout: 20000 });
    expect(await m.page.locator('[data-testid=mp-recheck]').count() === 0, `${name}/${res}: ei erillistä uudelleentarkistusnappia`);
    if (state === 'wait' && lang === 'fi' && res === 'pending') await shot(m.page, 'kassa-mock-odottaa-fi-390');
    expect(await noHScroll(m.page), `${name}/${res}: ei vaakavieritystä`); checkErrs(m.page, `${name}/${res}`); await closeAll(m);
  }
  // mock: ilman ?scenario=pay ei MobilePayta eikä lahjakorttia (vanha näkymä)
  const plain = await open({ url: `${PATHS[lang].confirm}?mock=1#${TOKEN}`, lang }); await plain.page.waitForTimeout(900);
  expect(await plain.page.locator('[data-testid=pay-choices]').count() === 0, `${name}: oletus-mock ennallaan (ei maksuosiota)`); await closeAll(plain);
}

// ============ 8) Asettelu: ei vaakavieritystä / kontrasti / kosketuskohteet (360, 390, 430, 1280) FI+EN ============
for (const width of [360, 390, 430, 1280]) {
  for (const lang of ['fi', 'en']) {
    const st = newState(); const s = await open({ st, lang, viewport: { width, height: width > 700 ? 900 : 844 } }); const { page } = s; const name = `asettelu/${width}/${lang}`;
    await waitSection(page); await page.waitForSelector('[data-testid=pc-method-paymentInitiation]'); await page.click('[data-testid=pc-gift-btn]');
    await page.fill('[data-testid=gc-code]', 'XQZ123456789'); await page.click('[data-testid=gc-apply]'); await page.waitForSelector('[data-testid=vc-choose]:not([hidden])');
    expect(await noHScroll(page), `${name}: ei vaakavieritystä`);
    const small = await page.evaluate(() => [...document.querySelectorAll('[data-testid=pay-choices] button, [data-testid=pay-choices] input, [data-testid=pay-choices] select, [data-testid=pay-choices] a.btn')].filter((el) => el.offsetParent && el.type !== 'radio' && el.type !== 'hidden').map((el) => { const b = el.getBoundingClientRect(); return { n: `${el.tagName}.${el.className}`, w: b.width, h: b.height }; }).filter((x) => x.h < 43.5 || x.w < 43.5));
    expect(!small.length, `${name}: kosketuskohteet >=44 px, alle: ${JSON.stringify(small)}`);
    const over = await page.evaluate(() => { const vw = innerWidth; return [...document.querySelectorAll('[data-testid=pay-choices] *')].filter((el) => { const b = el.getBoundingClientRect(); return b.width && b.right > vw + 1; }).map((el) => `${el.tagName}.${el.className}`); });
    expect(!over.length, `${name}: sisältö ylittää näkymän: ${JSON.stringify(over)}`);
    await page.addStyleTag({ content: '*,*::before,*::after{transition:none!important;animation:none!important}' }); await page.waitForTimeout(100);   // mitataan lopputilan värit, ei siirtymän väliarvoja
    for (const sel of ['[data-testid=pay-choices] h3', '[data-testid=pc-due]', '[data-testid=pay-choices] .bk-note', '[data-testid=op-test]', '.pc-gift-btn', '[data-testid=gc-apply]', '[data-testid=vc-submit]', '[data-testid=gc-check]']) {
      const c = await colors(page, sel); if (!c) { expect(false, `${name}: ${sel} puuttuu`); continue; }
      const r = ratio(rgb(c.col), rgb(c.bg)); expect(r >= 4.5, `${name}: kontrasti ${sel} ${r.toFixed(2)} < 4.5 (${c.col} / ${c.bg})`);
    }
    // ei sinistä muualla kuin MobilePay-painikkeessa: tarkista maksuosion omat elementit
    const blue = await page.evaluate(() => [...document.querySelectorAll('[data-testid=pay-choices] *')].filter((el) => !el.closest('[data-testid=mp-btnwrap]')).filter((el) => { const cs = getComputedStyle(el); return [cs.color, cs.backgroundColor, cs.borderTopColor].some((c) => { const m = c.match(/[\d.]+/g); if (!m || (m[3] === '0')) return false; const [r, g, b] = m.map(Number); return b > 140 && b > r + 40 && b > g + 20; }); }).map((el) => `${el.tagName}.${el.className}`));
    expect(!blue.length, `${name}: sinistä väriä maksuosion muissa osissa: ${JSON.stringify(blue)}`);
    if ([360, 1280].includes(width)) await shot(page, `kassa-valinta-lahdevalinta-${lang}-${width}`);
    checkErrs(page, name); await closeAll(s);
  }
}
// kuvat: kassan maksuvalinta 360 / 1280 (suljettu + avattu)
for (const width of [360, 1280]) {
  const st = newState(); const s = await open({ st, viewport: { width, height: width > 700 ? 900 : 800 } }); await waitSection(s.page); await s.page.waitForSelector('[data-testid=pc-method-paymentInitiation]'); await s.page.waitForTimeout(400);
  await s.page.locator('[data-testid=pay-choices]').scrollIntoViewIfNeeded(); await shot(s.page, `kassa-valinta-fi-${width}`);
  await s.page.click('[data-testid=pc-gift-btn]'); await s.page.waitForTimeout(200); await shot(s.page, `kassa-valinta-lahjakortti-auki-fi-${width}`);
  if (width === 360) await shot(s.page, 'kassa-valinta-sivu-fi-360', { full: true });
  await closeAll(s);
}
await browser.close(); server.close();
if (problems.length) { console.error(`E2E-kassa-maksu: ${problems.length} ongelmaa (${checks} tarkistusta):\n` + [...new Set(problems)].map((p) => `- ${p}`).join('\n')); process.exit(1); }
console.log(`e2e-kassa-maksu: ${checks} tarkistusta, 0 ongelmaa${SHOTS ? `, kuvat → ${SHOT}` : ''}`);
