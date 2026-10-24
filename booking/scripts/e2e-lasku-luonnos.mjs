// E2E (playwright-core + google-chrome): Hallinta › Laskut › Uusi lasku › "Tallenna luonnos" ei koskaan jää hiljaiseksi.
// Kokeilutila (?mock=1): ei verkkokutsuja eikä tuotantoa. Tarkistaa kenttävirheet, fokuksen, näkyvän ilmoituksen modaalin päällä,
// palvelinvirheen viestin, tallennuksen aikaisen tilan ja onnistuneen tallennuksen (modaali sulkeutuu, luonnos listassa).
// Ajo: PW_DIR=<kansio jossa playwright-core> node booking/scripts/e2e-lasku-luonnos.mjs (SHOT_DIR oletus /tmp/lasku-luonnos, CHROME oletus /usr/bin/google-chrome)
import { createServer } from 'node:http';
import { readFile, stat, mkdir } from 'node:fs/promises';
import { join, extname, dirname, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const pwPath = createRequire(import.meta.url).resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', here].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath)); const chromium = pw.chromium || pw.default.chromium;
const ROOT = resolve(here, '../..'), SHOT = resolve(process.env.SHOT_DIR || '/tmp/lasku-luonnos');
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

async function open(name, width = 460) {
  const ctx = await browser.newContext({ viewport: { width, height: 900 }, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const pg = await ctx.newPage();
  pg.on('pageerror', (e) => problems.push(`${name} pageerror ${e.message}`));
  pg.on('console', (m) => m.type() === 'error' && problems.push(`${name} console ${m.text()}`));
  await pg.goto(`${O}/admin/?mock=1&role=admin#/laskut`);
  await pg.getByRole('button', { name: 'Uusi lasku' }).first().click();
  await pg.waitForSelector('[data-testid=invoice-new-form]');
  return pg;
}
// Joonaksen kuvakaappauksen rivit: Pyyhe vuokralle 15 kpl á 5,00 (sis. alv) ja Oma savusauna 1 kpl á 250,00, ALV 25,5 %.
async function fillLines(pg) {
  const lines = pg.locator('[data-testid=invoice-line]');
  await lines.nth(0).locator('[data-testid=invoice-line-desc]').fill('Pyyhe vuokralle');
  await lines.nth(0).locator('[data-testid=invoice-line-qty]').fill('15');
  await lines.nth(0).locator('[data-testid=invoice-line-price-gross]').fill('5,00');
  await pg.click('[data-testid=invoice-add-line]');
  await lines.nth(1).locator('[data-testid=invoice-line-desc]').fill('Oma savusauna');
  await lines.nth(1).locator('[data-testid=invoice-line-price-gross]').fill('250,00');
  await pg.locator('.dlg-head h2').click();
  await pg.locator('.dlg-body').evaluate((b) => { b.scrollTop = b.scrollHeight; });
}
const state = (pg) => pg.evaluate(() => {
  const t = document.getElementById('toast');
  const b = t?.getBoundingClientRect();
  // .toast on pointer-events:none, joten elementFromPoint ei osu siihen. Näkyvyys: avoimen modaalin päällä ilmoituksen pitää olla
  // päällimmäisen modaalin sisällä (selaimen ylin taso); ilman modaalia bodyssa. Lisäksi kokonaan näkymässä.
  const modals = [...document.querySelectorAll('dialog[open]')];
  const host = modals.length ? modals[modals.length - 1] : document.body;
  const hit = b && t.classList.contains('show') && t.parentNode === host && b.top >= 0 && b.bottom <= innerHeight && b.width > 0 ? t : null;
  const err = document.querySelector('[data-testid=invoice-save-error]');
  const er = err?.getBoundingClientRect();
  const ae = document.activeElement;
  const ar = ae?.getBoundingClientRect();
  const body = document.querySelector('.dlg-body')?.getBoundingClientRect();
  return {
    toast: t?.textContent || '', toastVisible: !!hit,
    saveErr: err && !err.hidden ? err.textContent : '', saveErrInView: !!(er && er.height > 0 && er.top >= 0 && er.bottom <= innerHeight), dialogOpen: !!document.querySelector('dialog[open]'),
    active: ae?.name || ae?.dataset?.testid || ae?.tagName,
    activeInView: !!(ar && body && ar.top >= body.top - 1 && ar.bottom <= body.bottom + 1),
    fieldErrs: Object.fromEntries([...document.querySelectorAll('[data-testid^=invoice-err-]')].filter((e) => e.textContent).map((e) => [e.dataset.testid.slice(12), e.textContent])),
    btnDisabled: document.querySelector('[data-testid=invoice-save]')?.disabled, btnBusy: document.querySelector('[data-testid=invoice-save]')?.getAttribute('aria-busy'),
    rows: document.querySelectorAll('[data-testid=invoice-row]').length, preview: !!document.querySelector('[data-testid=invoice-preview]'),
  };
});

// A: yritys puuttuu (kenttä on vieritetty pois näkyvistä) → virhe kentän alla, fokus ja vieritys kenttään, näkyvä ilmoitus.
{
  const pg = await open('A');
  await fillLines(pg);
  await pg.click('[data-testid=invoice-save]'); await pg.waitForTimeout(500);
  const s = await state(pg);
  expect(s.fieldErrs.company_name === 'Anna yrityksen nimi.', `A kenttävirhe ${JSON.stringify(s.fieldErrs)}`);
  expect(s.active === 'company_name' && s.activeInView, `A fokus ${s.active} ${s.activeInView}`);
  expect(/Tarkista merkityt kentät/.test(s.saveErr), `A yhteenveto ${s.saveErr}`);
  expect(s.saveErrInView, 'A virheviesti näkyy napin yläpuolella');
  expect(s.dialogOpen && !s.btnDisabled, 'A modaali auki, nappi käytössä');
  await pg.screenshot({ path: join(SHOT, 'a-yritys-puuttuu.png') });
  await pg.fill('input[name=company_name]', 'T');
  expect(!(await state(pg)).fieldErrs.company_name, 'A virhe poistuu kirjoitettaessa');
  await pg.context().close();
}
// B: OVT ilman välittäjätunnusta ja virheellinen sähköposti → kaksi kenttävirhettä, fokus ensimmäiseen.
{
  const pg = await open('B');
  await pg.fill('input[name=company_name]', 'Testi Oy');
  await pg.fill('input[name=email]', 'testi@');
  await pg.fill('input[name=einvoice_address]', '003701120389');
  await fillLines(pg);
  await pg.click('[data-testid=invoice-save]'); await pg.waitForTimeout(500);
  const s = await state(pg);
  expect(s.fieldErrs.email && s.fieldErrs.einvoice_operator, `B kenttävirheet ${JSON.stringify(s.fieldErrs)}`);
  expect(s.active === 'email' && s.activeInView, `B fokus ${s.active}`);
  expect(s.saveErrInView, 'B virheviesti näkyy');
  await pg.screenshot({ path: join(SHOT, 'b-kenttavirheet.png') });
  await pg.context().close();
}
// C: palvelin hylkää tallennuksen → palvelimen viesti näkyy napin yläpuolella ja ilmoituksena, modaali pysyy auki, nappi palautuu.
{
  const pg = await open('C');
  await pg.evaluate(async () => {
    const sb = await import('/admin/sb.js'); const { createAdminMock } = await import('/admin/options-mock.js');
    const mock = createAdminMock({ role: 'admin' });
    sb.setRpcOverride(async (fn, args) => {
      if (fn === 'admin_save_invoice') { await new Promise((r) => setTimeout(r, 300)); throw new sb.ApiError('Ei oikeutta tähän toimintoon (invoices.manage)', { code: 'forbidden', status: 400 }); }
      return mock.rpc(fn, args);
    });
  });
  await pg.fill('input[name=company_name]', 'Testi Oy');
  await fillLines(pg);
  await pg.click('[data-testid=invoice-save]'); await pg.waitForTimeout(100);
  const busy = await state(pg);
  expect(busy.btnDisabled && busy.btnBusy === 'true', `C nappi ei ole tallennustilassa ${JSON.stringify(busy)}`);
  await pg.screenshot({ path: join(SHOT, 'c-tallennetaan.png') });
  await pg.waitForTimeout(600);
  const s = await state(pg);
  expect(/Tallennus epäonnistui/.test(s.saveErr) && /invoices\.manage/.test(s.saveErr), `C palvelimen viesti ${s.saveErr}`);
  expect(s.saveErrInView, 'C virheviesti näkyy');
  expect(s.dialogOpen && !s.btnDisabled && !s.btnBusy, 'C modaali auki ja nappi palautui');
  await pg.screenshot({ path: join(SHOT, 'c-palvelinvirhe.png') });
  // Yleinen korjaus (ui.js): ilmoitus avoimen modaalin aikana menee modaalin sisään eikä jää sen alle.
  await pg.evaluate(async () => (await import('/admin/ui.js')).toast('Testi-ilmoitus', 'err'));
  expect((await state(pg)).toastVisible, 'C ilmoitus näkyy modaalin päällä');
  await pg.context().close();
}
// D: onnistuu → modaali sulkeutuu, ilmoitus, luonnos listassa ja esikatselu auki (325,00 €).
{
  const pg = await open('D', 900);
  await pg.fill('input[name=company_name]', 'Testi Oy');
  await fillLines(pg);
  await pg.click('[data-testid=invoice-save]'); await pg.waitForTimeout(900);
  const s = await state(pg);
  expect(!s.dialogOpen, 'D modaali sulkeutui');
  expect(s.toast === 'Luonnos tallennettu' && s.toastVisible, `D ilmoitus ${s.toast}`);
  expect(s.rows === 1 && s.preview, `D lista ${s.rows} esikatselu ${s.preview}`);
  const txt = await pg.locator('[data-testid=invoice-preview]').innerText();
  expect(/325,00/.test(txt) && /Pyyhe vuokralle/.test(txt), 'D esikatselussa rivit ja summa');
  await pg.screenshot({ path: join(SHOT, 'd-tallennettu.png'), fullPage: true });
  await pg.context().close();
}
await browser.close(); server.close();
console.log(`${checks} tarkistusta, ${problems.length} ongelmaa`);
for (const p of problems) console.log('  ✗', p);
process.exit(problems.length ? 1 : 0);
