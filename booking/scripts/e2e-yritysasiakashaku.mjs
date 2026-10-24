// E2E (playwright-core + google-chrome): yritysasiakkaat löytyvät hallinnan asiakashausta (booking_172).
// Kokeilutila (?mock=1): ei verkkokutsuja eikä tuotantoa. Mock peilaa booking_172:n admin_search_customers / admin_search_invoice_customers:
// Johku-tyyppinen yritys on vain tilauksen laskutustiedoissa (yhteyshenkilö rekisterissä yksityisenä).
// A Uusi varaus: haku yrityksen nimellä, y-tunnuksella (ilman väliviivaa), yhteyshenkilöllä; valinta täyttää yritystiedot ja varaus lähtee
//   uutena yritysasiakkaana (p_customer.kind = company, company_details), ei yhteyshenkilön yksityisasiakas-id:llä.
// B Uusi lasku: haku nimellä ja y-tunnuksella; valinta täyttää yrityksen nimen, y-tunnuksen, osoitteen ja verkkolaskutiedot.
// C Vanha haku (funktio puuttuu → admin_list_customers) toimii edelleen.
// Ajo: PW_DIR=<kansio jossa playwright-core> node booking/scripts/e2e-yritysasiakashaku.mjs (SHOT_DIR oletus /tmp/yritysasiakashaku)
import { createServer } from 'node:http';
import { readFile, stat, mkdir } from 'node:fs/promises';
import { join, extname, dirname, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const pwPath = createRequire(import.meta.url).resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', here].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath)); const chromium = pw.chromium || pw.default.chromium;
const ROOT = resolve(here, '../..'), SHOT = resolve(process.env.SHOT_DIR || '/tmp/yritysasiakashaku');
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

// Mockin päivänäkymässä ei ole vuoroja → lisätään yksi vapaa vuoro Uusi varaus -lomaketta varten (vain tämä testi)
async function openNewBooking(pg) {
  await pg.evaluate(() => {
    const m = window.__adminMock; const orig = m.rpc; const p = m.state.products.find((x) => x.active !== false) || m.state.products[0];
    m.rpc = async (n, a) => {
      const r = await orig(n, a);
      if (n !== 'admin_day_view') return r;
      const st = new Date(`${a.p_date}T15:00:00Z`), en = new Date(`${a.p_date}T17:00:00Z`);
      return { ...r, sessions: [{ rule_id: 9901, product_id: p.id, label: 'Testivuoro', starts_at: st.toISOString(), ends_at: en.toISOString(), status: 'available', mode: 'shared', remaining: 10, capacity: 10, min_persons: 1, max_persons: 10, price_mode: 'per_person', base_price: 20, price: 20 }] };
    };
    location.hash = '#/uusi';
  });
  await pg.waitForSelector('.slotbtn:not([disabled])', { timeout: 15000 });
  await pg.locator('.slotbtn:not([disabled])').first().click();
  await pg.waitForSelector('form[data-testid=booking-form]');
}
async function page(name, hash, { width = 460, dropNewRpc = false } = {}) {
  const ctx = await browser.newContext({ viewport: { width, height: 900 }, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const pg = await ctx.newPage();
  pg.on('pageerror', (e) => problems.push(`${name} pageerror ${e.message}`));
  pg.on('console', (m) => m.type() === 'error' && !/mock_unsupported|admin_create_booking|ei ole mockattu/.test(m.text()) && problems.push(`${name} console ${m.text()}`));
  await pg.goto(`${O}/admin/?mock=1&role=admin${hash}`);
  await pg.waitForFunction(() => !!window.__adminMock);
  if (dropNewRpc) await pg.evaluate(() => { const m = window.__adminMock; const orig = m.rpc; m.rpc = (n, a) => (n === 'admin_search_customers' ? Promise.reject(Object.assign(new Error('Could not find the function'), { code: 'PGRST202' })) : orig(n, a)); });
  return pg;
}
const hits = (pg) => pg.locator('.found .listrow').allInnerTexts();
async function search(pg, scope, term) {
  const inp = pg.locator(`${scope} input[name=csearch]`);
  await inp.fill(term);
  await inp.press('Enter');
  await pg.waitForTimeout(450);
  return (await hits(pg)).map((t) => t.replace(/\s+/g, ' ').trim());
}

// ===== A Uusi varaus
{
  const pg = await page('A', '#/laskut');
  await openNewBooking(pg);
  const F = 'form[data-testid=booking-form]';
  let h = await search(pg, F, 'saunaseura');
  expect(h.length === 1 && /Saunaseura Testi Oy/.test(h[0]) && /1234560-4/.test(h[0]) && /aiempi tilaus/.test(h[0]), `A1 nimihaku: ${JSON.stringify(h)}`);
  h = await search(pg, F, '12345604');
  expect(h.length === 1 && /Saunaseura Testi Oy/.test(h[0]), `A2 y-tunnus ilman väliviivaa: ${JSON.stringify(h)}`);
  h = await search(pg, F, 'Eero');
  expect(h.length === 2 && /Eero Esimerkki/.test(h[0]) && /Saunaseura Testi Oy \(Eero Esimerkki\)/.test(h[1]), `A3 yhteyshenkilö → henkilö + yritys: ${JSON.stringify(h)}`);
  await pg.locator('.found .listrow').nth(1).click();
  const v = await pg.evaluate((F) => { const f = document.querySelector(F); const g = (n) => f.querySelector(`[name=${n}]`)?.value; return { kind: f.querySelector('input[type=radio][value=company]')?.checked, company: g('company_name'), bid: g('business_id'), street: g('street'), zip: g('zip'), city: g('city'), ei: g('einvoice_address'), op: g('einvoice_operator'), name: g('cname'), email: g('cemail'), existing: f.querySelector('.cf')?.classList.contains('existing'), boxHidden: f.querySelector('.company-box')?.hidden, inv: !f.querySelector('[data-testid=invref-field]')?.hidden, method: g('method') }; }, F);
  expect(v.kind && v.company === 'Saunaseura Testi Oy' && v.bid === '1234560-4' && v.street === 'Uusi katu 5' && v.zip === '00210' && v.city === 'Helsinki', `A4 yritystiedot täytetty: ${JSON.stringify(v)}`);
  expect(v.ei === '003712345604' && v.op === 'E204503' && v.name === 'Eero Esimerkki' && v.email === 'laskut@saunaseura.example.test', `A5 verkkolasku + yhteyshenkilö: ${JSON.stringify(v)}`);
  expect(!v.existing && !v.boxHidden && v.inv, `A6 lomake näkyvissä tarkistettavaksi, laskun viite -kenttä esillä (mockissa ei laskumaksutapaa): ${JSON.stringify(v)}`);
  expect(/aiemmalta tilaukselta/.test(await pg.locator('[data-testid=customer-picked]').innerText()), 'A7 valinnan selite');
  await pg.screenshot({ path: join(SHOT, 'a-uusi-varaus-yritys.png'), fullPage: true });
  await pg.click(`${F} button[type=submit]`);
  await pg.waitForTimeout(600);
  const call = await pg.evaluate(() => window.__adminMock.state.calls.filter((c) => c.name === 'admin_create_booking').pop()?.args || null);
  expect(call && !call.p_customer_id && call.p_customer?.kind === 'company' && call.p_customer.company_details?.business_id === '1234560-4'
    && call.p_customer.company_details.company_name === 'Saunaseura Testi Oy' && call.p_customer.company_details.einvoice_operator === 'E204503' && call.p_customer.name === 'Eero Esimerkki',
    `A8 varaus yritysasiakkaana: ${JSON.stringify(call)}`);
  // rekisterin yritysasiakas valitaan kuten ennen (p_customer_id)
  h = await search(pg, F, 'koivutesti');
  expect(h.length === 1 && /Koivutesti Oy \(Liisa Lasku\)/.test(h[0]) && /1000000-4/.test(h[0]), `A9 rekisterin yritys: ${JSON.stringify(h)}`);
  await pg.locator('.found .listrow').first().click();
  expect(await pg.evaluate((F) => document.querySelector(F).querySelector('.cf').classList.contains('existing'), F), 'A10 rekisterin yritys valitaan olemassa olevana');
  await pg.context().close();
}

// ===== B Uusi lasku
{
  const pg = await page('B', '#/laskut');
  await pg.getByRole('button', { name: 'Uusi lasku' }).first().click();
  await pg.waitForSelector('[data-testid=invoice-new-form]');
  const D = 'dialog[open]';
  let h = await search(pg, D, 'saunaseura');
  expect(h.length === 1 && /Saunaseura Testi Oy/.test(h[0]) && /Aiempi tilaus/.test(h[0]), `B1 laskun haku nimellä: ${JSON.stringify(h)}`);
  h = await search(pg, D, '1234560-4');
  expect(h.length === 1 && /1234560-4/.test(h[0]), `B2 laskun haku y-tunnuksella: ${JSON.stringify(h)}`);
  await pg.locator(`${D} .found .listrow`).first().click();
  const v = await pg.evaluate(() => { const f = document.querySelector('[data-testid=invoice-new-form]'); const g = (n) => f.querySelector(`[name=${n}]`)?.value; return { company: g('company_name'), bid: g('business_id'), ei: g('einvoice_address'), op: g('einvoice_operator'), street: g('street'), zip: g('zip'), city: g('city'), contact: g('contact_name'), email: g('email') }; });
  expect(v.company === 'Saunaseura Testi Oy' && v.bid === '1234560-4' && v.ei === '003712345604' && v.op === 'E204503', `B3 yritys, y-tunnus, verkkolasku: ${JSON.stringify(v)}`);
  expect(v.street === 'Uusi katu 5' && v.zip === '00210' && v.city === 'Helsinki' && v.contact === 'Eero Esimerkki', `B4 osoite ja yhteyshenkilö: ${JSON.stringify(v)}`);
  await pg.screenshot({ path: join(SHOT, 'b-uusi-lasku-yritys.png'), fullPage: true });
  h = await search(pg, D, 'kioski');
  expect(h.length >= 1 && /Nimetön Kioski Ky/.test(h[0]), `B5 y-tunnukseton yritys: ${JSON.stringify(h)}`);
  await pg.context().close();
}

// ===== C ennen migraatiota: admin_search_customers puuttuu → vanha haku
{
  const pg = await page('C', '#/laskut', { dropNewRpc: true });
  await openNewBooking(pg);
  const h = await search(pg, 'form[data-testid=booking-form]', 'Aino');
  expect(h.length === 1 && /Aino Testaaja/.test(h[0]), `C1 vanha haku toimii: ${JSON.stringify(h)}`);
  await pg.context().close();
}

await browser.close(); server.close();
console.log(`checks=${checks} problems=${problems.length}`);
for (const p of problems) console.log(` - ${p}`);
process.exit(problems.length ? 1 : 0);
