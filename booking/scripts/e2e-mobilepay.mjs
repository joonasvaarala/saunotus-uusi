// E2E (Playwright + google-chrome): tilaussivun verkkomaksu (?mock=1&scenario=mp) – "Maksa verkossa", viisi tapaa, paluu ?pay=online.
// Ei MobilePay-otsikkoa, ei Vipps-CDN:ää, ei tuotantokantaa. Paluun ajoitus mockissa: mpinterval/mpmax.
//   SHOP_DIST=/tmp/shop-dist node booking/shop/build.mjs
//   PW_DIR=/workspace/node_modules node booking/scripts/e2e-mobilepay.mjs
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { dirname, join, extname, resolve, normalize } from 'node:path';
const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const pwPath = require.resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', here].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath));
const chromium = pw.chromium || pw.default.chromium;
const SHOP = resolve(process.env.SHOP_DIST || '/tmp/shop-dist');
const problems = []; let checks = 0;
const expect = (ok, msg) => { checks++; if (!ok) problems.push(msg); };
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.png': 'image/png', '.woff2': 'font/woff2' };
const server = createServer(async (req, res) => {
  const p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  let file = join(SHOP, normalize(p));
  try { if ((await stat(file)).isDirectory()) file = join(file, 'index.html'); const buf = await readFile(file); res.writeHead(200, { 'content-type': types[extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' }); res.end(buf); }
  catch { res.writeHead(404, { 'content-type': 'text/plain' }); res.end('Not found'); }
});
await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
const ORIGIN = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const TOKEN = '3f2b8c1e-5a7d-4e9f-8b6a-1c2d3e4f5a6b';
const BANK = '[data-testid=ord-method-paymentInitiation]';
const orderUrl = (lang, q) => `${ORIGIN}${lang === 'en' ? '/en/order/' : '/tilaus/'}?t=${TOKEN}&mock=1&${q}`;

async function open(lang, q) {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, locale: lang === 'en' ? 'en-GB' : 'fi-FI', isMobile: true, hasTouch: true });
  const page = await ctx.newPage();
  const urls = [];
  page.on('framenavigated', (f) => { if (f === page.mainFrame()) urls.push(f.url()); });
  page.__urls = urls;
  await page.goto(orderUrl(lang, q));
  return { ctx, page };
}

for (const lang of ['fi', 'en']) {
  const s = await open(lang, 'scenario=mp&mpinterval=150&mpmax=600');
  const { page } = s;
  const name = `tilaus/${lang}`;
  await page.waitForSelector(BANK);
  const title = (await page.locator('#ord-p').innerText()).replace(/\s+/g, ' ').trim();
  expect(title === (lang === 'en' ? 'Payment status' : 'Maksutila'), `${name}: otsikko ${title}`);
  expect(await page.locator('[data-testid^=ord-method-]').count() === 5, `${name}: viisi tapaa`);
  expect((await page.locator(BANK).innerText()).trim() === (lang === 'en' ? 'Online bank' : 'Verkkopankki'), `${name}: verkkopankki`);
  const body = await page.locator('[data-testid=order-pay]').innerText();
  expect(!/Maksa MobilePaylla|Pay with MobilePay|Montonio/i.test(body), `${name}: ei MobilePay-otsikkoa eikä välittäjän nimeä`);
  expect(await page.locator('[data-testid=op-test]').count() === 1, `${name}: testihuomautus`);
  expect((await page.locator('[data-testid=ord-pay-amount]').innerText()).includes('40'), `${name}: summa`);
  expect((await page.locator('[data-testid=ord-pay-lead]').innerText()).length > 8, `${name}: johdanto`);
  await page.click(BANK);
  await page.waitForSelector('[data-testid=op-return][data-state=paid]', { timeout: 8000 }).catch(() => {});
  const hopped = page.__urls.some((u) => { try { const q = new URL(u).searchParams; return q.get('pay') === 'online' && q.get('t') === TOKEN; } catch { return false; } });
  expect(hopped, `${name}: paluuosoite pay=online ja tilauksen token`);
  expect((await page.locator('[data-testid=op-return]').getAttribute('data-state')) === 'paid', `${name}: paluu paid`);
  expect(!(new URL(page.url()).searchParams.has('pay')), `${name}: pay-parametri poistettu`);
  expect(!/Maksa MobilePaylla/.test(await page.locator('body').innerText()), `${name}: sivulla ei MobilePay-otsikkoa`);
  await s.ctx.close();
}

{
  const s = await open('fi', 'scenario=mp&mpresult=failed&mpinterval=100&mpmax=400');
  await s.page.waitForSelector(BANK);
  await s.page.click(BANK);
  await s.page.waitForSelector('[data-testid=op-return][data-state=failed]', { timeout: 8000 });
  expect((await s.page.locator('[data-testid=op-return] h3').innerText()).includes('Maksu ei onnistunut'), 'failed: otsikko');
  await s.ctx.close();
}
{
  const s = await open('fi', 'scenario=mp&mpresult=pending&mpinterval=80&mpmax=160');
  await s.page.waitForSelector(BANK);
  await s.page.click(BANK);
  await s.page.waitForSelector('[data-testid=op-return][data-state=wait]', { timeout: 8000 });
  expect(new URL(s.page.url()).searchParams.get('pay') === 'online', 'wait: pay=online säilyy');
  await s.ctx.close();
}
{
  const s = await open('en', 'scenario=mp&mpresult=starterror');
  await s.page.waitForSelector(BANK);
  await s.page.click(BANK);
  await s.page.waitForSelector('[data-testid=op-error]');
  const err = await s.page.locator('[data-testid=op-error]').innerText();
  expect(/could not be started/i.test(err) && !/MobilePay/i.test(err), `EN start-virhe: ${err}`);
  await s.ctx.close();
}
{
  const s = await open('fi', 'scenario=mp&mpresult=neterror');
  await s.page.waitForSelector(BANK);
  await s.page.click(BANK);
  await s.page.waitForSelector('[data-testid=op-error]');
  const err = await s.page.locator('[data-testid=op-error]').innerText();
  expect(/Yhteys ei onnistunut/.test(err), `verkkovirhe: ${err}`);
  await s.ctx.close();
}
{
  const s = await open('fi', 'scenario=mp-off');
  await s.page.waitForSelector('[data-testid=order-pay]');
  expect(await s.page.locator(BANK).count() === 0, 'mp-off: ei verkkomaksunappeja');
  expect(!/Maksa MobilePaylla/.test(await s.page.locator('body').innerText()), 'mp-off: ei MobilePay-otsikkoa');
  await s.ctx.close();
}

await browser.close(); server.close();
if (problems.length) { console.error(`ONGELMIA (${problems.length}/${checks}):\n` + problems.join('\n')); process.exit(1); }
console.log(`ok: tilaussivun verkkomaksu, ${checks} tarkistusta`);
