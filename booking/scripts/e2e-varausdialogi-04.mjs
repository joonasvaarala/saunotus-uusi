// Varausdialogi 04: kokeilutila, ei verkkoa. Leveydet 390 ja 1280.
//   node booking/scripts/e2e-varausdialogi-04.mjs
import { createServer } from 'node:http';
import { readFile, stat, mkdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { dirname, join, extname, resolve, normalize } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(here, '../..');
const require = createRequire(import.meta.url);
const pwPath = require.resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', here].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath));
const chromium = pw.chromium || pw.default.chromium;
const SHOT = resolve(process.env.SHOT_DIR || '/opt/cursor/artifacts/varausdialogi-04');
await mkdir(SHOT, { recursive: true });
const problems = [];
let checks = 0;
const expect = (ok, msg) => { checks++; if (!ok) problems.push(msg); };
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png' };
let ORIGIN = '';
const server = createServer(async (req, res) => {
  const p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  let file;
  if (p === '/favicon.ico') { res.writeHead(204); return res.end(); }
  if (p === '/admin/config.js') { res.writeHead(200, { 'content-type': 'text/javascript' }); return res.end(`window.BOOKING_CONFIG=${JSON.stringify({ url: ORIGIN, anonKey: 'anon-test' })};`); }
  if (p === '/admin/sb.js') file = join(ROOT, 'booking/shared/sb.js');
  else if (p.startsWith('/shop/')) file = join(ROOT, 'booking/shop', normalize(p.slice(6)));
  else if (p === '/pay-null.html') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    return res.end(`<!doctype html><meta charset="utf-8"><body><p data-testid="pay-null"></p><script type="module">
import { normLinkInfo, linkInfoView, fmtDate } from '/shop/src/pay-link-logic.js';
const info = normLinkInfo({ ok: true, status: 'open', reason: 'open', can_pay: true, amount: 12, currency: 'EUR', expires_date: null, expires_time: null, items: [{ kind: 'reservation', name: 'Saunahoito', quantity: 1 }] });
const view = linkInfoView(info);
const date = fmtDate('fi', info.expires_date);
const host = document.querySelector('[data-testid=pay-null]');
host.dataset.valid = view.validKey == null ? '' : String(view.validKey);
host.dataset.date = date;
host.dataset.expires = info.expires_date == null ? '' : String(info.expires_date);
host.textContent = view.validKey ? date : 'Saunahoito';
</script>`);
  }   else if (p.startsWith('/admin/')) file = join(ROOT, 'booking/admin', normalize(p.slice(7) || 'index.html'));
  else { res.writeHead(404); return res.end('Not found'); }
  try {
    if ((await stat(file)).isDirectory()) file = join(file, 'index.html');
    const buf = await readFile(file);
    res.writeHead(200, { 'content-type': types[extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' });
    res.end(buf);
  } catch { res.writeHead(404, { 'content-type': 'text/plain' }); res.end('Not found'); }
});
await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
ORIGIN = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });

function newPage(width, lang) {
  const mobile = width < 600;
  return browser.newContext({ viewport: { width, height: mobile ? 844 : 900 }, isMobile: mobile, hasTouch: mobile, locale: lang === 'en' ? 'en-GB' : 'fi-FI', timezoneId: 'Europe/Helsinki' }).then(async (ctx) => {
    const page = await ctx.newPage();
    page.ctx = ctx;
    const tag = `${lang}-${width}`;
    page.on('pageerror', (e) => problems.push(`${tag} pageerror: ${e.message}`));
    page.on('console', (m) => { if (m.type() === 'error') problems.push(`${tag} console.error: ${m.text()}`); });
    page.on('request', (r) => { if (!r.url().startsWith(ORIGIN) && !r.url().startsWith('data:')) problems.push(`${tag} ulkoinen pyyntö: ${r.url()}`); });
    return page;
  });
}
const shot = (page, name) => page.screenshot({ path: join(SHOT, name) });
const noNull = async (page, label) => {
  const text = await page.locator('dialog[open]').innerText().catch(() => '');
  expect(!/\bnull\b|\bundefined\b|Invalid Date/i.test(text), `${label}: dialogissa null/undefined/Invalid Date (${text.slice(0, 180)})`);
};
const scroll = (page) => page.evaluate(() => {
  const d = document.querySelector('dialog[open]');
  return { page: document.documentElement.scrollWidth - document.documentElement.clientWidth, dlg: d ? d.scrollWidth - d.clientWidth : 0 };
});
const palette = (page, label) => page.evaluate(() => {
  const out = [];
  const parse = (s) => { const m = String(s || '').match(/rgba?\(([^)]+)\)/); if (!m) return null; const p = m[1].split(',').map((x) => parseFloat(x)); return { rgb: p.slice(0, 3), a: p[3] ?? 1 }; };
  const lum = (c) => { const [r, g, b] = c.map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
  const ratio = (a, b) => { const A = lum(a), B = lum(b); return (Math.max(A, B) + 0.05) / (Math.min(A, B) + 0.05); };
  const isBlue = (c) => { if (!c || c.a === 0) return false; const [r, g, b] = c.rgb.map((v) => v / 255); const mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn; if (d < 0.12) return false; const s = d / mx; let h = mx === b ? 4 + (r - g) / d : mx === g ? 2 + (b - r) / d : (g - b) / d % 6; h = ((h * 60) + 360) % 360; return h >= 190 && h <= 260 && s > 0.25; };
  const root = document.querySelector('dialog[open] .rd-dialog') || document.querySelector('dialog[open]');
  if (!root) return ['dialogi puuttuu'];
  for (const el of root.querySelectorAll('.rd-when, .rd-contact a, .pl-toggle, .rd-actions .btn, .muted')) {
    if (!el.getClientRects().length || el.hidden) continue;
    const cs = getComputedStyle(el);
    const fg = parse(cs.color); if (!fg) continue;
    let bgEl = el; let bg = null;
    while (bgEl) { const c = parse(getComputedStyle(bgEl).backgroundColor); if (c && c.a > 0.9) { bg = c.rgb; break; } bgEl = bgEl.parentElement; }
    if (!bg) bg = [244, 239, 231];
    const cr = ratio(fg.rgb, bg);
    if (cr < 4.5) out.push(`kontrasti ${cr.toFixed(2)} < 4.5 (${el.className})`);
    for (const k of ['color', 'backgroundColor', 'borderTopColor']) if (isBlue(parse(cs[k]))) out.push(`sininen ${k} (${el.className})`);
  }
  return out;
}).then((rows) => rows.forEach((m) => expect(false, `${label}: ${m}`)));

async function openReservation(page, name, lang = 'fi') {
  const q = lang === 'en' ? 'mock=1&lang=en' : 'mock=1';
  await page.goto(`${ORIGIN}/admin/?${q}#/`, { waitUntil: 'load' });
  await page.waitForSelector('#view .resrow');
  await page.locator('#view .resrow', { hasText: name }).locator('button.link').first().click();
  await page.waitForSelector('dialog[open] [data-testid=res-summary]');
  await page.waitForFunction(() => {
    const pay = document.querySelector('[data-testid=res-payment]');
    return pay && !pay.hidden;
  }, null, { timeout: 8000 });
}

async function openLink(page) {
  await page.locator('dialog[open] [data-testid=order-reservation-create-link]').click();
  await page.waitForSelector('dialog[open] [data-testid=link-deadline-toggle]');
}

for (const width of [390, 1280]) {
  const page = await newPage(width, 'fi');
  const tag = `fi-${width}`;
  await page.goto(`${ORIGIN}/admin/?mock=1#/`, { waitUntil: 'load' });
  await page.waitForSelector('#view .resrow');
  const dayScroll = await scroll(page);
  expect(dayScroll.page <= 1, `${tag}: päivänäkymä vaakavieritys ${dayScroll.page}`);
  await shot(page, `day-${width}.png`);
  await page.goto(`${ORIGIN}/admin/?mock=1#/kalenteri`, { waitUntil: 'load' });
  await page.waitForSelector('#view .cal, #view .daygrid, #view .cal-body', { timeout: 8000 }).catch(() => {});
  expect((await page.locator('#view').innerText()).length > 20, `${tag}: kalenteri tyhjä`);
  const calScroll = await scroll(page);
  expect(calScroll.page <= 1, `${tag}: kalenteri vaakavieritys ${calScroll.page}`);
  await shot(page, `calendar-${width}.png`);
  await page.goto(`${ORIGIN}/admin/?mock=1#/varaukset`, { waitUntil: 'load' });
  await page.waitForSelector('#view .rescard, #view .listrow');
  const listScroll = await scroll(page);
  expect(listScroll.page <= 1, `${tag}: varauslista vaakavieritys ${listScroll.page}`);
  await shot(page, `list-${width}.png`);

  await openReservation(page, 'Aino Testaaja');
  expect(await page.locator('dialog[open] [data-testid=order-reservation-create-link]').count() === 0, `${tag}: maksetulla ei maksulinkkiä`);
  await noNull(page, `${tag} maksettu`);
  const paidScroll = await scroll(page);
  expect(paidScroll.dlg <= 1 && paidScroll.page <= 1, `${tag}: maksettu dialogi vaakavieritys ${JSON.stringify(paidScroll)}`);
  await shot(page, `dialog-paid-${width}.png`);
  await page.keyboard.press('Escape');

  await openReservation(page, 'Eero Esimerkki');
  expect(await page.locator('dialog[open] [data-testid=order-reservation-create-link]').count() === 1, `${tag}: maksamattomalla maksulinkki`);
  expect(/Muuta varausta|Merkitse saapuneeksi|Peru varaus/.test(await page.locator('dialog[open]').innerText()), `${tag}: vanhat suomenkieliset napit säilyvät`);
  await noNull(page, `${tag} maksamaton`);
  await palette(page, `${tag} maksamaton`);
  const unpaidScroll = await scroll(page);
  expect(unpaidScroll.dlg <= 1 && unpaidScroll.page <= 1, `${tag}: maksamaton dialogi vaakavieritys ${JSON.stringify(unpaidScroll)}`);
  await shot(page, `dialog-unpaid-${width}.png`);

  await openLink(page);
  expect(!(await page.locator('dialog[open] [data-testid=link-deadline-toggle]').isChecked()), `${tag}: takaraja pois`);
  expect(await page.locator('dialog[open] [data-testid=link-deadline-days]').isHidden(), `${tag}: päiväkenttä piilossa`);
  await shot(page, `deadline-off-${width}.png`);
  await page.locator('dialog[open] [data-testid=link-deadline-toggle]').check();
  expect(await page.locator('dialog[open] [data-testid=link-deadline-days]').isVisible(), `${tag}: päiväkenttä näkyy`);
  expect(await page.locator('dialog[open] [data-testid=link-deadline-days]').inputValue() === '14', `${tag}: oletus 14`);
  await shot(page, `deadline-on-${width}.png`);
  for (const bad of ['0', '61', '', '1.5']) {
    await page.locator('dialog[open] [data-testid=link-deadline-days]').fill(bad);
    await page.locator('dialog[open] button[type=submit]').click();
    await page.waitForSelector('#toast.show.err', { timeout: 4000 }).catch(() => {});
    expect(await page.locator('dialog[open] [data-testid=link-deadline-days]').count() === 1, `${tag}: hylätty arvo ${JSON.stringify(bad)} ei sulkenut dialogia`);
  }
  await page.locator('dialog[open] [data-testid=link-deadline-days]').fill('1');
  await page.locator('dialog[open] button[type=submit]').click();
  await page.waitForSelector('dialog[open] [data-testid=order-flow-link-url]');
  const one = await page.locator('dialog[open]').innerText();
  expect(/Linkki on voimassa/.test(one) && !/null|Invalid Date/i.test(one), `${tag}: 1 päivä näyttää päivämäärän (${one.slice(0, 160)})`);
  await page.keyboard.press('Escape');

  await openReservation(page, 'Eero Esimerkki');
  await openLink(page);
  await page.locator('dialog[open] button[type=submit]').click();
  await page.waitForSelector('dialog[open] [data-testid=order-flow-link-url]');
  const none = await page.locator('dialog[open]').innerText();
  expect(/Linkillä ei ole takarajaa/.test(none) && !/\bnull\b|Invalid Date/i.test(none), `${tag}: pois päältä ei takarajaa`);
  expect(/\/maksa\/\?p=/.test(await page.locator('dialog[open] [data-testid=order-flow-link-url]').inputValue()), `${tag}: linkin osoite`);
  await page.keyboard.press('Escape');

  await openReservation(page, 'Eero Esimerkki');
  await openLink(page);
  await page.locator('dialog[open] [data-testid=link-deadline-toggle]').check();
  await page.locator('dialog[open] [data-testid=link-deadline-days]').fill('60');
  await page.locator('dialog[open] button[type=submit]').click();
  await page.waitForSelector('dialog[open] [data-testid=order-flow-link-url]');
  expect(/Linkki on voimassa/.test(await page.locator('dialog[open]').innerText()), `${tag}: 60 päivää hyväksytään`);
  await page.keyboard.press('Escape');

  await openReservation(page, 'Eero Esimerkki');
  await openLink(page);
  await page.evaluate(() => {
    const form = document.querySelector('dialog[open] form');
    form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
  });
  await page.waitForSelector('dialog[open] [data-testid=order-flow-link-url]');
  await page.waitForTimeout(400);
  expect(await page.locator('[data-testid=order-flow-link-url]').count() === 1, `${tag}: kaksoislähetys teki yhden linkin`);
  await page.keyboard.press('Escape');

  await page.evaluate(() => {
    const mock = window.__adminMock;
    const orig = mock.rpc.bind(mock);
    mock.rpc = async (name, args) => {
      if (name === 'admin_get_order') await new Promise((r) => setTimeout(r, 700));
      return orig(name, args);
    };
  });
  await page.locator('#view .resrow', { hasText: 'Eero Esimerkki' }).locator('button.link').first().click();
  await page.waitForSelector('dialog[open]');
  await page.keyboard.press('Escape');
  await page.waitForTimeout(900);
  expect(await page.locator('dialog[open]').count() === 0, `${tag}: suljettu dialogi ei jää auki vanhan vastauksen jälkeen`);

  await page.goto(`${ORIGIN}/admin/?mock=1#/tilaukset`, { waitUntil: 'load' });
  await page.waitForSelector('[data-testid=orders-list]');
  await page.locator('[data-testid=orders-filters-toggle]').click();
  await page.selectOption('[data-testid=orders-f-pay]', 'unpaid');
  await page.waitForTimeout(400);
  await page.locator('[data-testid=orders-list] [data-testid=order] .tl-head').first().click();
  await page.waitForSelector('[data-testid=btn-link]');
  await page.locator('[data-testid=btn-link]').click();
  await page.waitForSelector('dialog[open] [data-testid=link-deadline-toggle]');
  expect(!(await page.locator('dialog[open] [data-testid=link-deadline-toggle]').isChecked()), `${tag}: tilauksen takaraja pois`);
  await page.locator('dialog[open] button[type=submit]').click();
  await page.waitForSelector('dialog[open] [data-testid=order-flow-link-url]');
  expect(/Linkillä ei ole takarajaa/.test(await page.locator('dialog[open]').innerText()), `${tag}: tilauksen linkillä ei takarajaa`);
  const ordersScroll = await scroll(page);
  expect(ordersScroll.page <= 1, `${tag}: tilaukset vaakavieritys ${ordersScroll.page}`);
  await shot(page, `orders-unpaid-link-${width}.png`);
  await page.ctx.close();
}

{
  const page = await newPage(390, 'en');
  await openReservation(page, 'Eero Esimerkki', 'en');
  await openLink(page);
  const en = await page.locator('dialog[open]').innerText();
  expect(/Set a deadline/.test(en), `en: Set a deadline (${en.slice(0, 200)})`);
  await page.locator('dialog[open] button[type=submit]').click();
  await page.waitForSelector('dialog[open] [data-testid=order-flow-link-url]');
  expect(/The link has no deadline/.test(await page.locator('dialog[open]').innerText()), 'en: no deadline');
  await shot(page, 'dialog-unpaid-en-390.png');
  await page.ctx.close();
}
{
  const page = await newPage(390, 'fi');
  await page.goto(`${ORIGIN}/pay-null.html`, { waitUntil: 'load' });
  await page.waitForFunction(() => document.querySelector('[data-testid=pay-null]')?.textContent?.includes('Saunahoito'));
  const host = page.locator('[data-testid=pay-null]');
  const data = await host.evaluate((el) => ({ valid: el.dataset.valid, date: el.dataset.date, expires: el.dataset.expires, text: el.textContent }));
  expect(data.valid === '' && data.date === '' && data.expires === '' && data.text === 'Saunahoito', `asiakkaan maksusivu null-voimassaolo: ${JSON.stringify(data)}`);
  expect(!/null|Invalid Date/i.test(data.text), `asiakkaan maksusivu ei tulosta null-sanaa: ${data.text}`);
  await page.ctx.close();
}

await browser.close();
server.close();
console.log(`e2e-varausdialogi-04: ${checks} tarkistusta, ${problems.length} ongelmaa`);
for (const p of problems) console.log(' -', p);
process.exit(problems.length ? 1 : 0);
