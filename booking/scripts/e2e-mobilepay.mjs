// E2E (Playwright + google-chrome): MOBILEPAY-MAKSU kaupassa (sopimus KOODARI_talous_A_D_fi.md §14) – tilaussivun "Maksa MobilePaylla" -painike, paluutilat (?pay=mobilepay) ja vahvistussivun painike.
// Ei tuotantokantaa eikä oikeaa MobilePayta: PostgREST-RPC:t ja edge-funktiot (mobilepay-start / mobilepay-notify) vastataan page.route:lla; virallinen painikekomponentti (CDN) korvataan tynkäkomponentilla (CDN=stub, oletus)
// tai haetaan oikeasti (CDN=real; screenshotit). Vahvistaa: painike vain kun public_payment_options sallii, testitilan tapa piiloon tuotantokonfiguraatiossa, POST {order_token} → redirect, paluutilat (maksettu / epäonnistui / odottaa / aika meni / ota yhteyttä / verkkovirhe),
// virheenkäsittely, FI+EN, ei vaakavieritystä (360/390/430/1280), kosketuskohteet >=44 px, kontrasti >=4,5:1, ei konsolivirheitä.
//   node booking/shop/build.mjs (SHOP_DIST=/tmp/shop-dist-mp, SITE_ENV=test) ensin; sitten PW_DIR=/workspace/node_modules node booking/scripts/e2e-mobilepay.mjs
// Ympäristö: SHOP_DIST (oletus /tmp/shop-dist-mp), SHOT_DIR (oletus /workspace/screenshots-mobilepay; SHOTS=0 ohittaa kuvat), CHROME (oletus /usr/bin/google-chrome), CDN=stub|real
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
const { createOrderMock } = await import(pathToFileURL(join(ROOT, 'booking/shop/src/order-mock.js')));
const SHOP = resolve(process.env.SHOP_DIST || '/tmp/shop-dist-mp'), SHOT = resolve(process.env.SHOT_DIR || '/workspace/screenshots-mobilepay');
const SHOTS = process.env.SHOTS !== '0', CDN = process.env.CDN || 'stub';
if (SHOTS) await mkdir(SHOT, { recursive: true });
const problems = []; let checks = 0;
const expect = (ok, msg) => { checks++; if (!ok) problems.push(msg); };
const TOKEN = '3f2b8c1e-5a7d-4e9f-8b6a-1c2d3e4f5a6b';
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.avif': 'image/avif', '.png': 'image/png', '.jpg': 'image/jpeg', '.woff2': 'font/woff2' };

// ---- staattinen palvelin ----
let ORIGIN = '', CFG = {};
const server = createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x'); const p = decodeURIComponent(u.pathname);
  if (p === '/booking/config.js') { res.writeHead(200, { 'content-type': 'text/javascript' }); return res.end(`window.BOOKING_CONFIG=${JSON.stringify({ url: ORIGIN, anonKey: 'anon-test', rest: '/rest/v1', auth: '/auth/v1', schema: 'booking', ...CFG })};`); }
  let file = join(SHOP, normalize(p));
  try { if ((await stat(file)).isDirectory()) file = join(file, 'index.html'); const buf = await readFile(file); res.writeHead(200, { 'content-type': types[extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' }); res.end(buf); }
  catch { res.writeHead(404, { 'content-type': 'text/plain' }); res.end('Not found'); }
});
await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
ORIGIN = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });

const STUB = `class B extends HTMLElement{connectedCallback(){const r=this.attachShadow({mode:'open'});r.innerHTML='<button type="button" part="b" style="display:block;width:100%;min-height:48px;background:#5a78ff;color:#fff;border:0;border-radius:24px;font:700 17px sans-serif">'+(this.getAttribute('language')==='en'?'Pay with MobilePay':'Maksa MobilePaylla')+'</button>';if(this._d)r.querySelector('button').disabled=true}set loading(v){}get loading(){return false}set disabled(v){this._d=!!v;const b=this.shadowRoot&&this.shadowRoot.querySelector('button');if(b)b.disabled=!!v}}customElements.define('vipps-mobilepay-button',B);`;
const FAKE_PAY = 'https://pay-test.example.invalid/mobilepay/abc123';

// ---- palvelimen tila (reaaliaikaiset RPC:t / edge-funktiot page.route:lla) ----
const base = createOrderMock({ scenario: 'mp' });
async function newState(over = {}) {
  const snap = await base.rpc('public_get_order', { p_token: TOKEN });
  return { snap, paid: false, opts: 'on', test: true, canPay: true, pending: false, start: 'ok', reconcile: 'pending', calls: [], startBody: null, locale: 'fi', ...over };
}
const json = (route, body, status = 200) => route.fulfill({ status, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' }, body: JSON.stringify(body) });
async function wire(ctx, st) {
  await ctx.route('**/rest/v1/rpc/*', async (route) => {
    const name = new URL(route.request().url()).pathname.split('/').pop(); st.calls.push(name);
    if (name === 'public_payment_options') {
      if (st.opts === 'missing') return json(route, { code: 'PGRST202', message: 'Could not find the function booking.public_payment_options in the schema cache' }, 404);
      if (st.opts === 'error') return json(route, { message: 'boom' }, 500);
      if (st.opts === 'off') return json(route, { ok: true, online_enabled: false, methods: [] });
      return json(route, { ok: true, online_enabled: true, methods: [{ code: 'mobilepay', provider: 'vipps_mobilepay', label: 'MobilePay', label_en: 'MobilePay', test: st.test, start: { function: 'mobilepay-start', method: 'POST', body: { order_token: TOKEN } } }],
        order: { order_no: 15321, status: st.paid ? 'confirmed' : 'pending', payment_status: st.paid ? 'paid' : 'unpaid', unpaid: st.paid ? 0 : 40, can_pay_online: st.canPay && !st.paid, mobilepay_pending: st.pending } });
    }
    if (name === 'public_get_order') {
      if (st.getOrder === 'abort') return route.abort('failed');
      const o = JSON.parse(JSON.stringify(st.snap)); o.locale = st.locale;
      if (st.paid) { o.status = 'confirmed'; o.payment_status = 'paid'; o.paid = o.total; o.unpaid = 0; o.payments = [{ status: 'paid', amount: o.total, paid_at: new Date().toISOString(), method_label: 'MobilePay' }]; }
      return json(route, o);
    }
    if (name === 'public_gift_card_packages') return json(route, { ok: true, sale_enabled: false, redeem_enabled: false, packages: [] });
    if (name === 'public_get_order_gift_cards') return json(route, { ok: true, cards: [] });
    if (name === 'public_get_booking') return json(route, { ok: true, order_no: 15321, status: 'confirmed', payment_status: 'unpaid', customer_kind: 'private', total: 40, can_change: false, change_hours_before: 48, change_deadline: null,
      items: [{ product_id: 1, product_name: 'Yleinen saunavuoro', starts_at: '2030-01-10T11:00:00Z', ends_at: '2030-01-10T12:30:00Z', persons: 2 }], addons: [] });
    return json(route, { code: 'PGRST202', message: `Could not find the function booking.${name} in the schema cache` }, 404);
  });
  await ctx.route('**/functions/v1/mobilepay-start', async (route) => {
    st.startBody = route.request().postDataJSON(); st.startHeaders = route.request().headers(); st.calls.push('mobilepay-start');
    if (st.start === 'abort') return route.abort('failed');
    if (st.start === 'slow') { await new Promise((ok) => setTimeout(ok, 1200)); }
    if (st.start === 'error') return json(route, { ok: false, code: 'provider_error', message: 'MobilePay-maksun aloitus epäonnistui, yritä hetken kuluttua uudelleen' }, 503);
    if (st.start === 'unknown') return json(route, { ok: false, code: 'jokin_uusi', message: 'Palvelimen oma viesti' }, 400);
    if (st.start === 'html') return route.fulfill({ status: 502, contentType: 'text/html', body: '<h1>Bad gateway</h1>' });
    if (st.start === 'insecure') return json(route, { ok: true, redirect_url: 'http://evil.example.invalid/x' });
    return json(route, { ok: true, reuse: false, redirect_url: FAKE_PAY, reference: 'sauna-o15321-p1-a1', payment_id: 1 });
  });
  await ctx.route('**/functions/v1/mobilepay-notify', async (route) => {
    st.calls.push('mobilepay-notify'); st.notifyBody = route.request().postDataJSON();
    if (st.reconcile === 'abort') return route.abort('failed');
    const r = st.reconcile, one = (outcome) => json(route, { ok: true, payment_status: st.paid ? 'paid' : 'unpaid', results: [{ outcome, state: 'X' }] });
    if (r === 'paid') { st.paid = true; return one('paid'); }
    if (r === 'review') { st.paid = true; return one('paid_needs_review'); }
    if (r === 'failed') return one('not_authorized');
    if (r === 'slotlost') return one('cancelled_slot_lost');
    if (r === 'contact') return one('capture_failed');
    if (r === 'none') return json(route, { ok: true, payment_status: 'unpaid', results: [] });
    if (r === 'ratelimit') return json(route, { ok: false, code: 'rate_limited' }, 429);
    return one('pending');
  });
  await ctx.route('https://pay-test.example.invalid/**', (route) => route.fulfill({ status: 200, contentType: 'text/html', body: '<!doctype html><title>MobilePay (testi)</title><p>MobilePay mock</p>' }));
  await ctx.route('https://cdn.vippsmobilepay.com/**', (route) => (st.cdn === 'abort' ? route.abort('failed') : CDN === 'real' ? route.continue() : route.fulfill({ status: 200, contentType: 'text/javascript', body: STUB })));
}
async function open({ viewport = { width: 390, height: 844 }, st, cfg = {}, lang = 'fi', url, mock = false } = {}) {
  CFG = { mobilepayTestUi: true, ...cfg };
  const ctx = await browser.newContext({ viewport, locale: lang === 'en' ? 'en-GB' : 'fi-FI' });
  const page = await ctx.newPage(); const errs = []; page.__errs = errs;
  page.on('console', (m) => { if (m.type() === 'error') errs.push(m.text()); }); page.on('pageerror', (e) => errs.push(`pageerror: ${e.message}`));
  if (st) await wire(ctx, st);
  else await ctx.route('https://cdn.vippsmobilepay.com/**', (route) => (CDN === 'real' ? route.continue() : route.fulfill({ status: 200, contentType: 'text/javascript', body: STUB })));
  const path = url || (lang === 'en' ? `/en/order/?t=${TOKEN}` : `/tilaus/?t=${TOKEN}`);
  await page.goto(ORIGIN + path);
  return { ctx, page };
}
const closeAll = async (...c) => { for (const x of c) await x.ctx.close(); };
const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1 && document.body.scrollWidth <= window.innerWidth + 1);
const shot = async (page, name, o = {}) => { if (SHOTS) await page.screenshot({ path: join(SHOT, `${name}.png`), fullPage: o.full !== false, ...(o.clip ? { clip: o.clip } : {}) }); };
const lum = ([r, g, b]) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }; return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b); };
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
const rgb = (s) => (s.match(/[\d.]+/g) || []).slice(0, 3).map(Number);
// kontrasti: elementin teksti vs. lähin ei-läpinäkyvä tausta
const contrastOf = (page, selector) => page.evaluate((sel) => {
  const el = document.querySelector(sel); if (!el) return null;
  const col = getComputedStyle(el).color; let n = el, bg = 'rgba(0, 0, 0, 0)';
  while (n) { const c = getComputedStyle(n).backgroundColor; if (c && !/rgba\(.*, 0\)$/.test(c) && c !== 'transparent') { bg = c; break; } n = n.parentElement; }
  return { col, bg };
}, selector).then((r) => (r ? ratio(rgb(r.col), rgb(r.bg.startsWith('rgba') && /, 0\)$/.test(r.bg) ? 'rgb(255,255,255)' : r.bg)) : null));
const btnBox = async (page) => (await page.locator('[data-testid=mp-button]').boundingBox());
const waitPanel = (page, state, timeout = 15000) => page.waitForSelector(`[data-testid=mp-result-panel][data-state="${state}"]`, { timeout });
const NEEDS_CDN_ERR = /Failed to load resource|net::ERR_FAILED|ERR_BLOCKED/;
const checkErrs = (page, where, allow = []) => { const bad = page.__errs.filter((e) => !NEEDS_CDN_ERR.test(e) && !allow.some((a) => a.test(e))); expect(!bad.length, `${where}: konsolivirheet ${JSON.stringify(bad)}`); };

// ============ 1) Painikkeen näyttöehdot (oikea rajapintatila, page.route) ============
{
  let st = await newState(); let s = await open({ st });
  await s.page.waitForSelector('[data-testid=order-page]');
  await s.page.waitForSelector('[data-testid=mp-button]');
  expect(await s.page.locator('[data-testid=mp-button]').getAttribute('data-kind') === 'official', 'painike: virallinen komponentti käytössä');
  expect((await s.page.locator('[data-testid=mp-button]').getAttribute('brand')) === 'mobilepay' && (await s.page.locator('[data-testid=mp-button]').getAttribute('verb')) === 'pay' && (await s.page.locator('[data-testid=mp-button]').getAttribute('language')) === 'fi', 'painike: brand=mobilepay, verb=pay, language=fi');
    expect(await s.page.locator('[data-testid=mp-test-note]').count() === 1, 'testitila: merkintä näkyy kun methods[].test=true (testiympäristö)');
  expect(await s.page.locator('[data-testid=pay-rest]').count() === 0, 'painike: vanha "Verkkomaksu ei ole vielä käytössä" -nappi pois kun MobilePay käytössä');
  expect(st.calls.includes('public_payment_options'), 'public_payment_options kutsuttu');
  const box = await btnBox(s.page); expect(box && box.height >= 44 && box.width >= 44, `painike: kosketuskohde >=44 px (${box?.width}x${box?.height})`);
  expect(await noHScroll(s.page), 'painike: ei vaakavieritystä'); checkErrs(s.page, 'painike'); await closeAll(s);

  // tuotantokonfiguraatio: testitilan tapa piiloon
  st = await newState(); s = await open({ st, cfg: { mobilepayTestUi: false } });
  await s.page.waitForSelector('[data-testid=order-page]'); await s.page.waitForTimeout(400);
  expect(await s.page.locator('[data-testid=mp-button], [data-testid=mp-block]').count() === 0, 'tuotanto + test=true: painiketta EI näytetä');
  expect(await s.page.locator('[data-testid=pay-rest]').count() === 1, 'tuotanto + test=true: vanha ohjeteksti säilyy'); await closeAll(s);
  // tuotanto + test=false (live): näytetään
  st = await newState({ test: false }); s = await open({ st, cfg: { mobilepayTestUi: false } });
  await s.page.waitForSelector('[data-testid=mp-button]');
  expect(await s.page.locator('[data-testid=mp-test-note]').count() === 0, 'live (test=false): ei testimerkintää'); await closeAll(s);
  // can_pay_online=false, methods tyhjä, RPC puuttuu / virhe
  for (const [name, over] of [['can_pay_online=false', { canPay: false }], ['methods=[] (off)', { opts: 'off' }], ['RPC puuttuu (404)', { opts: 'missing' }], ['RPC virhe (500)', { opts: 'error' }]]) {
    st = await newState(over); s = await open({ st }); await s.page.waitForSelector('[data-testid=order-page]'); await s.page.waitForTimeout(300);
    expect(await s.page.locator('[data-testid=mp-block]').count() === 0, `${name}: ei painiketta`);
    expect(await s.page.locator('[data-testid=bk-error], .bk-error').count() === 0, `${name}: ei virheilmoitusta asiakkaalle`); await closeAll(s);
  }
  // mobilepay_pending: vihje
  st = await newState({ pending: true }); s = await open({ st }); await s.page.waitForSelector('[data-testid=mp-pending-hint]'); expect(true, 'pending-vihje'); await closeAll(s);
}

// ============ 2) Klikkaus: POST {order_token} → redirect; virheet ============
{
  let st = await newState(); let s = await open({ st });
  await s.page.waitForSelector('[data-testid=mp-button]');
  await Promise.all([s.page.waitForURL(FAKE_PAY), s.page.locator('[data-testid=mp-button]').click()]);
  expect(JSON.stringify(st.startBody) === JSON.stringify({ order_token: TOKEN }), `start: body {order_token} (${JSON.stringify(st.startBody)})`);
  expect(st.startHeaders?.['content-type']?.includes('application/json') && st.startHeaders?.apikey === 'anon-test', 'start: JSON + apikey-otsikko');
  await closeAll(s);

  const errCase = async (name, over, re, code) => {
    st = await newState(over); s = await open({ st }); await s.page.waitForSelector('[data-testid=mp-button]');
    await s.page.locator('[data-testid=mp-button]').click();
    await s.page.waitForSelector('[data-testid=mp-error]');
    const txt = await s.page.locator('[data-testid=mp-error]').innerText();
    expect(re.test(txt), `${name}: virheteksti "${txt}"`);
    expect(!/^https?:\/\/pay/.test(s.page.url()), `${name}: ei ohjausta`);
    await s.page.waitForFunction(() => { const b = document.querySelector('[data-testid=mp-button]'); return b && !b.disabled && !b.hasAttribute('aria-busy'); }, null, { timeout: 3000 }).catch(() => expect(false, `${name}: painike ei vapautunut uudelleenyritykseen`));
    expect(await noHScroll(s.page), `${name}: ei vaakavieritystä`);
    if (code) expect((await s.page.locator('[data-testid=mp-error]').getAttribute('data-code')) === code, `${name}: data-code ${code}`);
    await closeAll(s);
  };
  await errCase('palvelinvirhe provider_error', { start: 'error' }, /MobilePay ei vastannut/, 'provider_error');
  await errCase('verkkovirhe', { start: 'abort' }, /Yhteys MobilePayhin ei onnistunut/, 'network');
  await errCase('tuntematon koodi → ui.shop.error_generic (palvelimen raaka viesti ei asiakkaalle)', { start: 'unknown' }, /^Jokin meni pieleen\. Yritä hetken kuluttua uudelleen tai ota yhteyttä meihin\.$/, 'jokin_uusi');
  await errCase('ei-JSON-vastaus (502) → ui.shop.error_generic', { start: 'html' }, /^Jokin meni pieleen\. Yritä hetken kuluttua uudelleen tai ota yhteyttä meihin\.$/, 'http_502');
  await errCase('http-ohjausosoite hylätään', { start: 'insecure' }, /Maksun aloitus epäonnistui/);
  // englanti: virheteksti englanniksi
  st = await newState({ start: 'error', locale: 'en' }); s = await open({ st, lang: 'en' }); await s.page.waitForSelector('[data-testid=mp-button]');
  expect((await s.page.locator('[data-testid=mp-button]').getAttribute('language')) === 'en', 'EN: komponentin language=en');
  await s.page.locator('[data-testid=mp-button]').click(); await s.page.waitForSelector('[data-testid=mp-error]');
  expect(/MobilePay did not respond/.test(await s.page.locator('[data-testid=mp-error]').innerText()), 'EN: virheteksti englanniksi'); await closeAll(s);
  // kaksoisklikkaus: vain yksi pyyntö
  st = await newState({ start: 'slow' }); s = await open({ st }); await s.page.waitForSelector('[data-testid=mp-button]');
  await s.page.locator('[data-testid=mp-button]').dblclick().catch(() => {}); await s.page.waitForURL(FAKE_PAY, { timeout: 5000 }).catch(() => {});
  expect(st.calls.filter((c) => c === 'mobilepay-start').length === 1, `kaksoisklikkaus: yksi start-kutsu (${st.calls.filter((c) => c === 'mobilepay-start').length})`); await closeAll(s);
}

// ============ 3) Varapainike kun virallinen komponentti ei lataudu ============
{
  const st = await newState({ cdn: 'abort' }); const s = await open({ st });
  await s.page.waitForSelector('[data-testid=mp-button][data-kind=fallback]', { timeout: 8000 });
  const box = await btnBox(s.page); expect(box.height >= 44 && box.width >= 44, `varapainike: >=44 px (${box.height})`);
  const cr = await contrastOf(s.page, '[data-testid=mp-button]'); expect(cr >= 4.5, `varapainike: kontrasti ${cr?.toFixed(2)} >= 4.5`);
  expect(/Maksa MobilePaylla/.test(await s.page.locator('[data-testid=mp-button]').innerText()), 'varapainike: teksti');
  await shot(s.page, 'button-fallback-390-fi');
  await Promise.all([s.page.waitForURL(FAKE_PAY), s.page.locator('[data-testid=mp-button]').click()]);
  expect(st.startBody?.order_token === TOKEN, 'varapainike: start toimii'); await closeAll(s);
  // config: mobilepayOfficialButton=false → ei ulkoista skriptiä
  const st2 = await newState(); const s2 = await open({ st: st2, cfg: { mobilepayOfficialButton: false } });
  await s2.page.waitForSelector('[data-testid=mp-button][data-kind=fallback]');
  expect(await s2.page.locator('script[data-mobilepay-button]').count() === 0, 'mobilepayOfficialButton=false: ulkoista skriptiä ei ladata'); await closeAll(s2);
}

// ============ 4) Paluutilat (oikea rajapintatila): maksettu, epäonnistui, aika meni, ota yhteyttä, ei yritystä, tarkistettavana, verkkovirhe ============
{
  const ret = async (name, over, state, titleRe, extra) => {
    const st = await newState({ ...over }); const s = await open({ st, url: `/tilaus/?t=${TOKEN}&pay=mobilepay` });
    await waitPanel(s.page, state, 20000);
    const title = await s.page.locator('[data-testid=mp-result-title]').innerText();
    expect(titleRe.test(title), `${name}: otsikko "${title}"`);
    expect(JSON.stringify(st.notifyBody) === JSON.stringify({ action: 'reconcile', order_token: TOKEN }), `${name}: reconcile-body ${JSON.stringify(st.notifyBody)}`);
    expect(await noHScroll(s.page), `${name}: ei vaakavieritystä`);
    const cr = await contrastOf(s.page, '[data-testid=mp-result-panel] p'); expect(cr >= 4.5, `${name}: kontrasti ${cr?.toFixed(2)}`);
    if (extra) await extra(s, st);
    checkErrs(s.page, name); await closeAll(s);
  };
  await ret('paluu: maksettu', { reconcile: 'paid' }, 'paid', /Maksu onnistui/, async (s) => {
    expect(!/pay=/.test(s.page.url()), 'maksettu: pay-parametri poistettu osoitteesta');
    expect(await s.page.locator('[data-testid=mp-block]').count() === 0, 'maksettu: ei maksupainiketta (tilaus maksettu)');
    expect(/Maksettu/.test(await s.page.locator('.ord-badge.pay-paid').innerText()), 'maksettu: tilaussivun tila päivittyi');
  });
  await ret('paluu: maksettu, tarkistettavana', { reconcile: 'review' }, 'review', /Maksu vastaanotettu/);
  await ret('paluu: epäonnistui', { reconcile: 'failed' }, 'failed', /Maksu keskeytyi/, async (s) => {
    expect(!/pay=/.test(s.page.url()), 'epäonnistui: pay-parametri poistettu');
    await s.page.waitForSelector('[data-testid=mp-button]'); expect(true, 'epäonnistui: painike uudelleen näkyvissä');
  });
  await ret('paluu: aika meni', { reconcile: 'slotlost' }, 'slot_lost', /Aika ehti mennä/, async (s) => { expect(await s.page.locator('[data-testid=mp-calendar]').count() === 1, 'aika meni: linkki kalenteriin'); });
  await ret('paluu: ota yhteyttä', { reconcile: 'contact' }, 'contact', /Maksua ei voitu vahvistaa/);
  await ret('paluu: ei yritystä', { reconcile: 'none' }, 'none', /Maksua ei löytynyt/);
}
// ============ 5) Mock-tila (?mock=1&scenario=mp): koko virta, odottava tila (aikakatkaisu), FI+EN, mitoitus ============
{
  for (const lang of ['fi', 'en']) {
    const path = (extra = '') => `${lang === 'en' ? '/en/order/' : '/tilaus/'}?t=${TOKEN}&mock=1&scenario=mp${extra}`;
    const s = await open({ lang, url: path('&mpinterval=300&mpmax=20000'), mock: true });
    await s.page.waitForSelector('[data-testid=mp-button]');
    expect(await s.page.locator('[data-testid=mp-test-note]').count() === 1, `mock ${lang}: testimerkintä`);
    await Promise.all([s.page.waitForURL(/pay=mobilepay/), s.page.locator('[data-testid=mp-button]').click()]);
    await waitPanel(s.page, 'checking', 10000);
    expect(await s.page.locator('[data-testid=mp-button]').count() === 0, `mock ${lang}: painike piilossa tarkistuksen aikana`);
    await waitPanel(s.page, 'paid', 20000);
    expect(new RegExp(lang === 'en' ? 'Payment successful' : 'Maksu onnistui').test(await s.page.locator('[data-testid=mp-result-title]').innerText()), `mock ${lang}: maksettu-otsikko`);
    await s.page.waitForSelector('[data-testid=receipts] li', { timeout: 10000 }).catch(() => {});   // sivu päivittyy paneelin jälkeen (mpinterval säilyy nyt mock-paluussa)
    expect(await s.page.locator('[data-testid=receipts] li').count() === 1, `mock ${lang}: kuitti ilmestyi tilaukseen`);
    expect(!/pay=/.test(s.page.url()), `mock ${lang}: pay poistettu`); checkErrs(s.page, `mock ${lang}`, [/PGRST202|404/]); await closeAll(s);
  }
  // odottaa → aikakatkaisu (wait) + Tarkista uudelleen
  let s = await open({ url: `/tilaus/?t=${TOKEN}&mock=1&scenario=mp&mpresult=pending&mpinterval=200&mpmax=1200&pay=mobilepay`, mock: true });
  await waitPanel(s.page, 'wait', 15000);
  expect(/Maksua ei ole vielä vahvistettu/.test(await s.page.locator('[data-testid=mp-result-title]').innerText()), 'odottaa: otsikko');
  expect(/pay=mobilepay/.test(s.page.url()), 'odottaa: pay säilyy');
  await s.page.locator('[data-testid=mp-recheck]').click(); await waitPanel(s.page, 'checking', 5000); await waitPanel(s.page, 'wait', 15000); expect(true, 'odottaa: uudelleentarkistus toimii'); await closeAll(s);
  // mock: epäonnistunut-virta ja start-virheet
  s = await open({ url: `/tilaus/?t=${TOKEN}&mock=1&scenario=mp&mpresult=starterror`, mock: true }); await s.page.waitForSelector('[data-testid=mp-button]');
  await s.page.locator('[data-testid=mp-button]').click(); await s.page.waitForSelector('[data-testid=mp-error]'); expect(true, 'mock: start-virhe näkyy'); await closeAll(s);
  s = await open({ url: `/tilaus/?t=${TOKEN}&mock=1&scenario=mp&mpresult=neterror`, mock: true }); await s.page.waitForSelector('[data-testid=mp-button]');
  await s.page.locator('[data-testid=mp-button]').click(); await s.page.waitForSelector('[data-testid=mp-error]'); expect(/Yhteys MobilePayhin/.test(await s.page.locator('[data-testid=mp-error]').innerText()), 'mock: verkkovirhe'); await closeAll(s);
  // verkko katkeaa kokonaan paluun jälkeen (reconcile + get_order): "Maksun tilaa ei voitu tarkistaa" + Tarkista uudelleen, pay säilyy
  s = await open({ url: `/tilaus/?t=${TOKEN}&mock=1&scenario=mp&mpresult=netfail&mpinterval=200&mpmax=1000&pay=mobilepay`, mock: true });
  await waitPanel(s.page, 'net', 15000);
  expect(/Maksun tilaa ei voitu tarkistaa/.test(await s.page.locator('[data-testid=mp-result-title]').innerText()), 'verkkovirhe: otsikko');
  expect(await s.page.locator('[data-testid=mp-recheck]').count() === 1 && /pay=mobilepay/.test(s.page.url()), 'verkkovirhe: Tarkista uudelleen + pay säilyy'); await closeAll(s);
  // mock-skenaariot ilman MobilePayta: ei painiketta (oletusmock ennallaan)
  s = await open({ url: `/tilaus/?t=${TOKEN}&mock=1`, mock: true }); await s.page.waitForSelector('[data-testid=order-page]'); await s.page.waitForTimeout(500);
  expect(await s.page.locator('[data-testid=mp-block]').count() === 0 && await s.page.locator('[data-testid=pay-rest]').count() === 1, 'oletusmock: ei MobilePay-painiketta, vanha näkymä'); await closeAll(s);
  s = await open({ url: `/tilaus/?t=${TOKEN}&mock=1&scenario=mp-off`, mock: true }); await s.page.waitForSelector('[data-testid=order-page]'); await s.page.waitForTimeout(500);
  expect(await s.page.locator('[data-testid=mp-block]').count() === 0, 'mp-off: ei painiketta'); await closeAll(s);
}

// ============ 6) Vahvistussivu (/varaa/vahvistus/#<token>): painike ============
{
  const st = await newState(); const s = await open({ st, url: `/varaa/vahvistus/#${TOKEN}` });
  await s.page.waitForSelector('[data-testid=mp-button]', { timeout: 10000 });
  expect(await s.page.locator('.bk-conf [data-testid=pay-choices] [data-testid=mp-block]').count() === 1, 'vahvistussivu: MobilePay-osio');
  expect(await noHScroll(s.page), 'vahvistussivu: ei vaakavieritystä');
  await shot(s.page, 'confirm-page-390-fi');
  await Promise.all([s.page.waitForURL(FAKE_PAY), s.page.locator('[data-testid=mp-button]').click()]); expect(st.startBody?.order_token === TOKEN, 'vahvistussivu: start {order_token}'); await closeAll(s);
  const st2 = await newState({ opts: 'off' }); const s2 = await open({ st: st2, url: `/varaa/vahvistus/#${TOKEN}` }); await s2.page.waitForSelector('.bk-conf'); await s2.page.waitForTimeout(400);
  expect(await s2.page.locator('[data-testid=mp-block]').count() === 0, 'vahvistussivu: ei painiketta kun methods=[]'); await closeAll(s2);
}

// ============ 7) Mitoitus ja kuvat: 360 / 390 / 430 / 1280, FI + EN ============
for (const w of [360, 390, 430, 1280]) {
  for (const lang of ['fi', 'en']) {
    const vp = { width: w, height: w >= 1000 ? 900 : 800 };
    // painike
    let st = await newState({ locale: lang }); let s = await open({ viewport: vp, st, lang });
    await s.page.waitForSelector('[data-testid=mp-button]');
    expect(await noHScroll(s.page), `${w}/${lang}: painike: ei vaakavieritystä`);
    const box = await btnBox(s.page); expect(box.height >= 44, `${w}/${lang}: painikkeen korkeus ${box.height}`);
    const cp = await contrastOf(s.page, '.mp-test'); expect(cp >= 4.5, `${w}/${lang}: testimerkinnän kontrasti ${cp?.toFixed(2)}`);
    const ct = await contrastOf(s.page, '.mp-amount'); expect(ct >= 4.5, `${w}/${lang}: summarivin kontrasti ${ct?.toFixed(2)}`);
    await s.page.locator('[data-testid=mp-block]').scrollIntoViewIfNeeded();
    if (lang === 'fi' || w === 360) await shot(s.page, `button-${w}-${lang}`, { full: false });
    if (lang === 'fi' && (w === 360 || w === 1280)) await shot(s.page, `order-with-button-${w}-${lang}`);
    await closeAll(s);
    // paluutilat
    for (const [state, over] of [['paid', { reconcile: 'paid' }], ['failed', { reconcile: 'failed' }], ['slot_lost', { reconcile: 'slotlost' }], ['contact', { reconcile: 'contact' }]]) {
      st = await newState({ ...over, locale: lang }); s = await open({ viewport: vp, st, lang, url: `${lang === 'en' ? '/en/order/' : '/tilaus/'}?t=${TOKEN}&pay=mobilepay` });
      await waitPanel(s.page, state, 20000);
      expect(await noHScroll(s.page), `${w}/${lang}: ${state}: ei vaakavieritystä`);
      const c = await contrastOf(s.page, '[data-testid=mp-result-panel] p'); expect(c >= 4.5, `${w}/${lang}: ${state}: kontrasti ${c?.toFixed(2)}`);
      const c2 = await contrastOf(s.page, '[data-testid=mp-result-panel] h3'); expect(c2 >= 4.5, `${w}/${lang}: ${state}: otsikon kontrasti ${c2?.toFixed(2)}`);
      for (const b of await s.page.locator('[data-testid=mp-result-panel] a.btn, [data-testid=mp-result-panel] button').all()) { const bb = await b.boundingBox(); expect(bb.height >= 44, `${w}/${lang}: ${state}: painike >=44 px`); }
      if (state === 'failed') await s.page.waitForSelector('[data-testid=mp-button]');
      await s.page.evaluate(() => window.scrollTo(0, 0));
      if (lang === 'fi' && (w === 360 || w === 1280)) await shot(s.page, `return-${state.replace('_', '')}-${w}`, { full: false });
      if (lang === 'en' && w === 360 && state === 'paid') await shot(s.page, 'return-paid-360-en', { full: false });
      if (lang === 'fi' && (w === 360 || w === 1280) && state === 'failed') { await s.page.locator('[data-testid=mp-block]').scrollIntoViewIfNeeded(); await shot(s.page, `return-failed-retry-button-${w}`, { full: false }); }
      await closeAll(s);
    }
    // odottaa + tarkistetaan (mock, aikaikkuna)
    s = await open({ viewport: vp, lang, url: `${lang === 'en' ? '/en/order/' : '/tilaus/'}?t=${TOKEN}&mock=1&scenario=mp&mpresult=pending&mpinterval=200&mpmax=60000&pay=mobilepay`, mock: true });
    await waitPanel(s.page, 'checking', 10000);
    expect(await noHScroll(s.page), `${w}/${lang}: tarkistetaan: ei vaakavieritystä`);
    if (lang === 'fi' && (w === 360 || w === 1280)) await shot(s.page, `return-checking-${w}`, { full: false });
    await closeAll(s);
    s = await open({ viewport: vp, lang, url: `${lang === 'en' ? '/en/order/' : '/tilaus/'}?t=${TOKEN}&mock=1&scenario=mp&mpresult=pending&mpinterval=200&mpmax=1000&pay=mobilepay`, mock: true });
    await waitPanel(s.page, 'wait', 15000);
    expect(await noHScroll(s.page), `${w}/${lang}: odottaa: ei vaakavieritystä`);
    const cw = await contrastOf(s.page, '[data-testid=mp-result-panel] p'); expect(cw >= 4.5, `${w}/${lang}: odottaa: kontrasti ${cw?.toFixed(2)}`);
    const rb = await s.page.locator('[data-testid=mp-recheck]').boundingBox(); expect(rb.height >= 44, `${w}/${lang}: Tarkista uudelleen >=44 px`);
    if (lang === 'fi' && (w === 360 || w === 1280)) await shot(s.page, `return-waiting-${w}`, { full: false });
    await closeAll(s);
  }
}

await browser.close(); server.close();
console.log(`e2e-mobilepay: ${checks} tarkistusta, ${problems.length} ongelmaa`);
if (problems.length) { for (const p of problems) console.log(' - ' + p); process.exit(1); }
console.log('OK');
