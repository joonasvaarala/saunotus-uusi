// E2E (playwright-core + google-chrome, 390 px mobiili): hyvityksen ja varauksen peruutuksen dialogit hallinnan kokeilutilassa (?mock=1). Ei verkkokutsuja eikä tuotantoa.
// Ajo: PW_DIR=<kansio jossa playwright-core> node booking/scripts/e2e-hyvitys-mobiili.mjs (SHOT_DIR oletus /tmp/hyvitys-mobiili, CHROME oletus /usr/bin/google-chrome)
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { join, extname } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { mkdir } from 'node:fs/promises';
const here = dirname(fileURLToPath(import.meta.url));
const pwPath = createRequire(import.meta.url).resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', here].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath)); const chromium = pw.chromium || pw.default.chromium;
const ROOT = resolve(here, '../..'), SHOT = resolve(process.env.SHOT_DIR || '/tmp/hyvitys-mobiili');
await mkdir(SHOT, { recursive: true });
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.svg': 'image/svg+xml', '.json': 'application/json' };
const server = createServer(async (req, res) => {
  const p = decodeURIComponent(new URL(req.url, 'http://x').pathname); let file;
  if (p === '/admin/config.js') { res.writeHead(200, { 'content-type': 'text/javascript' }); return res.end(`window.BOOKING_CONFIG={url:'http://127.0.0.1:9',anonKey:'x',rest:'/rest/v1',auth:'/auth/v1',functions:'/functions/v1',schema:'booking'};`); }
  if (p === '/admin/sb.js') file = join(ROOT, 'booking/shared/sb.js'); else if (p.startsWith('/admin/')) file = join(ROOT, 'booking/admin', p.slice(7) || 'index.html'); else file = join(ROOT, 'booking', p);
  try { if ((await stat(file)).isDirectory()) file = join(file, 'index.html'); res.writeHead(200, { 'content-type': types[extname(file)] || 'application/octet-stream' }); res.end(await readFile(file)); } catch { res.writeHead(404); res.end(); }
});
await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
const O = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const problems = []; let checks = 0; const expect = (ok, m) => { checks++; if (!ok) problems.push(m); };
async function page(role, hash) {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const pg = await ctx.newPage();
  pg.on('response', (r) => r.status() >= 400 && problems.push('404 ' + r.url())); pg.on('pageerror', (e) => problems.push(`${role} pageerror ${e.message}`));
  pg.on('console', (m) => m.type() === 'error' && problems.push(`${role} console ${m.text()}`));
  await pg.goto(`${O}/admin/?mock=1&role=${role}${hash}`); await pg.waitForTimeout(1500); return pg;
}
async function checkDialog(pg, name, btnSel) {
  const r = await pg.evaluate((btnSel) => {
    const d = [...document.querySelectorAll('dialog[open]')].pop();
    const de = document.documentElement;
    const over = d ? [...d.querySelectorAll('*')].filter((e) => { const b = e.getBoundingClientRect(); return b.width && (b.right > innerWidth + 0.5 || b.left < -0.5); }).map((e) => e.tagName + '.' + e.className).slice(0, 5) : [];
    const btns = d ? [...d.querySelectorAll(btnSel)].map((b) => { const x = b.getBoundingClientRect(); return { t: b.textContent.trim(), l: x.left, r: x.right, w: x.width, h: x.height }; }) : [];
    return { open: !!d, docSW: de.scrollWidth, docCW: de.clientWidth, dSW: d?.scrollWidth, dCW: d?.clientWidth, over, btns, iw: innerWidth };
  }, btnSel);
  console.log(name, JSON.stringify(r));
  expect(r.open, `${name}: dialogi ei auki`);
  expect(r.docSW <= r.docCW, `${name}: sivun vaakavieritys ${r.docSW}>${r.docCW}`);
  expect(r.dSW <= r.dCW, `${name}: dialogin vaakavieritys ${r.dSW}>${r.dCW}`);
  expect(!r.over.length, `${name}: yli reunan ${r.over}`);
  expect(r.btns.length >= 2 && r.btns.every((b) => b.w > 40 && b.h >= 32 && b.l >= 0 && b.r <= r.iw), `${name}: napit ${JSON.stringify(r.btns)}`);
}
// 1) Tilauksen hyvitys (manager): kysymys varausten perumisesta
{
  const pg = await page('manager', '#/talous?tab=orders');
  await pg.waitForSelector('[data-testid=orders-list] li', { timeout: 10000 });
  const heads = pg.locator('[data-testid=orders-list] [aria-expanded]');
  const n = await heads.count(); let ok = false;
  for (let i = 0; i < n && !ok; i++) {
    await heads.nth(i).evaluate((e) => e.click()); await pg.waitForTimeout(500);
    const b = pg.locator('[data-testid=btn-refund]:not([disabled])').first();
    if (await b.count()) { await b.evaluate((e) => e.click()); await pg.waitForTimeout(500); ok = (await pg.locator('dialog[open] [data-testid=refund-cancel-res]').count()) > 0; if (!ok) await pg.keyboard.press('Escape'); }
  }
  expect(ok, 'hyvitysdialogissa ei peruutuskysymystä');
  expect(await pg.locator('dialog[open] [data-testid=refund-cancel-res-no] input').isChecked(), 'oletus ei ole Ei');
  await checkDialog(pg, 'refund-order', 'button');
  await pg.locator('dialog[open]').last().screenshot({ path: `${SHOT}/hyvitys-tilaus-390.png` });
  await pg.locator('dialog[open] [data-testid=refund-cancel-res-yes]').evaluate((e) => e.click());
  await checkDialog(pg, 'refund-order-yes', 'button');
  await pg.screenshot({ path: `${SHOT}/hyvitys-tilaus-390-koko.png`, fullPage: false });
}
// 2) Varauksen peruutus (manager): kysymys hyvityksestä
for (const role of ['manager', 'staff']) {
  const pg = await page(role, '#/varaukset');
  await pg.waitForSelector('[data-testid=reservation-row]', { timeout: 10000 });
  const rows = pg.locator('[data-testid=reservation-row]'); const n = await rows.count(); let ok = false;
  for (let i = 0; i < n && !ok; i++) {
    await rows.nth(i).evaluate((e) => e.click()); await pg.waitForTimeout(400);
    const c = pg.locator('dialog[open] [data-testid=res-cancel]');
    if (await c.count()) { await c.evaluate((e) => e.click()); await pg.waitForSelector('[data-testid=rc-cancel]', { timeout: 5000 }); ok = true; }
    else await pg.keyboard.press('Escape');
  }
  expect(ok, `${role}: peruutusdialogi ei auennut`);
  const hasQ = await pg.locator('dialog[open] [data-testid=rc-refund]').count();
  expect(role === 'manager' ? hasQ > 0 : hasQ === 0, `${role}: hyvityskysymys näkyvyys väärin (${hasQ})`);
  if (role === 'manager') {
    const no = pg.locator('dialog[open] [data-testid=rc-refund-no] input');
    expect(await no.isChecked(), 'peruutus: oletus ei ole Ei');
  }
  await checkDialog(pg, `cancel-${role}`, '.rc-actions button');
  await pg.locator('dialog[open]').last().screenshot({ path: `${SHOT}/peruutus-${role}-390.png` });
  if (role === 'manager' && await pg.locator('dialog[open] [data-testid=rc-refund-yes] input:not([disabled])').count()) {
    await pg.locator('dialog[open] [data-testid=rc-refund-yes]').evaluate((e) => e.click()); await pg.waitForTimeout(200);
    await checkDialog(pg, 'cancel-manager-yes', '.rc-actions button');
    await pg.locator('dialog[open]').last().screenshot({ path: `${SHOT}/peruutus-manager-kylla-390.png` });
  }
}
await browser.close(); server.close();
console.log(`checks=${checks} problems=${problems.length}`); problems.forEach((p) => console.log(' -', p));
process.exit(problems.length ? 1 : 0);
