// E2E-savutesti + kuvakaappaukset Chromiumilla (Playwright). Vaatii käynnissä olevan demon (booking/README.md → "Paikallinen demo").
// Käyttö:  PW_DIR=/polku/jossa/node_modules/playwright-core  node booking/scripts/e2e-screenshots.mjs
// Ympäristö: BASE_URL (oletus http://localhost:4180), CHROME (oletus system google-chrome), OUT (oletus booking/docs/screenshots)
// Epäonnistuu (exit 1), jos selaimen konsolissa on virheitä tai sivun pyyntö epäonnistuu.
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { mkdirSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';

const require = createRequire(import.meta.url);
const pwPath = require.resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', dirname(fileURLToPath(import.meta.url))].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath));
const chromium = pw.chromium || pw.default.chromium;
const BASE = process.env.BASE_URL || 'http://localhost:4180';
const OUT = resolve(process.env.OUT || join(dirname(fileURLToPath(import.meta.url)), '../docs/screenshots'));
mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const problems = [];
const watch = (page, name) => {
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type())) problems.push(`${name} console.${m.type()}: ${m.text()}`); });
  page.on('pageerror', (e) => problems.push(`${name} pageerror: ${e.message}`));
  page.on('requestfailed', (r) => problems.push(`${name} requestfailed: ${r.url()} ${r.failure()?.errorText}`));
  page.on('response', (r) => { if (r.status() >= 400) problems.push(`${name} HTTP ${r.status()}: ${r.url()}`); });
};
const shot = (page, file, full = true) => page.screenshot({ path: join(OUT, file), fullPage: full });

// ---------- KAUPPA ----------
if (process.env.ONLY !== 'admin') for (const [name, vp] of [['mobile', { width: 390, height: 844, deviceScaleFactor: 1, isMobile: true, hasTouch: true }], ['desktop', { width: 1280, height: 900 }]]) {
  const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, deviceScaleFactor: vp.deviceScaleFactor || 1, isMobile: vp.isMobile, hasTouch: vp.hasTouch, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const page = await ctx.newPage(); watch(page, `shop-${name}`);
  await page.goto(`${BASE}/varaa/`);
  await page.waitForSelector('.bk-cards');
  await shot(page, `shop-${name}-1-tuotteet.png`);
  // yleinen vuoro → kalenteri
  await page.goto(`${BASE}/varaa/#/tuote/yleinensauna`);
  await page.waitForSelector('.bk-grid button.bk-cell');
  const day = page.locator('.bk-grid button.bk-cell.free').first();
  await day.click();
  await page.waitForSelector('.bk-slotlist');
  await shot(page, `shop-${name}-2-kalenteri-vuorot.png`);
  // yksityisvuoron vaikutus: tuote 25 (Oma savusaunavuoro)
  await page.goto(`${BASE}/varaa/#/tuote/oma-saunavuoro`);
  await page.waitForSelector('.bk-grid button.bk-cell');
  await shot(page, `shop-${name}-3-yksityisvuoro-kalenteri.png`);
  // varaus loppuun
  await page.goto(`${BASE}/varaa/#/tuote/yleinensauna`);
  await page.waitForSelector('.bk-grid button.bk-cell.free');
  await page.locator('.bk-grid button.bk-cell.free').last().click();
  await page.locator('.bk-slot.available a.btn').first().click();
  await page.waitForSelector('.bk-form');
  await page.fill('#name', `Playwright Testaaja ${name}`);
  await page.fill('#email', `pw-${name}-${Date.now()}@example.com`);
  await page.fill('#phone', '0401234567');
  await shot(page, `shop-${name}-4-tiedot.png`);
  await page.check('#bk-terms');
  await page.click('button[type=submit]');
  await page.waitForURL(/vahvistus/);
  await page.waitForSelector('.bk-conf dl');
  await shot(page, `shop-${name}-5-vahvistus.png`);
  // asiakas ei voi perua vahvistettua varausta (ei peruutuspainiketta), mutta voi muuttaa sitä (≥ 48 h ennen alkua)
  if ((await page.locator('.bk-actions button:has-text("Peru")').count()) !== 0) problems.push(`shop-${name}: vahvistetulla varauksella ei saa olla peruutuspainiketta`);
  await page.click('.bk-actions a:has-text("Muuta varausta")');
  await page.waitForSelector('.bk-slotlist [role=radio]');
  await page.waitForTimeout(300);
  await shot(page, `shop-${name}-6-muuta-varausta.png`);
  await page.locator('.bk-step[aria-label="+"]').click().catch(() => {});
  await page.click('form.bk-form button[type=submit]');
  await page.waitForSelector('.bk-conf dl');
  await shot(page, `shop-${name}-7-muutettu.png`);
  await ctx.close();
}

// ---------- HALLINTA ----------
if (process.env.ONLY !== 'shop') for (const [name, vp] of [['mobile', { width: 390, height: 844, deviceScaleFactor: 1, isMobile: true, hasTouch: true }], ['desktop', { width: 1280, height: 900 }]]) {
  const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, deviceScaleFactor: vp.deviceScaleFactor || 1, isMobile: vp.isMobile, hasTouch: vp.hasTouch, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const page = await ctx.newPage(); watch(page, `admin-${name}`);
  await page.goto(`${BASE}/admin/`);
  await page.waitForSelector('form#login');
  await shot(page, `admin-${name}-0-kirjautuminen.png`, false);
  await page.fill('#email', 'admin@demo.local'); await page.fill('#password', 'demo');
  await page.click('form#login button[type=submit]');
  await page.waitForSelector('#view .day-view, #view .daygrid');
  // päivänäkymä päivälle, jolla on demovarauksia (seuraava maanantai)
  const mon = (() => { const d = new Date(); d.setUTCDate(d.getUTCDate() + ((8 - d.getUTCDay()) % 7 || 7)); return d.toISOString().slice(0, 10); })();
  await page.evaluate((m) => { location.hash = `#/?d=${m}`; }, mon);
  await page.waitForSelector('.session .reslist');
  await page.waitForTimeout(300);
  await shot(page, `admin-${name}-1-paivanakyma.png`, false);
  if (name === 'desktop') {
    await page.locator('.session .reslist button.link').first().click();
    await page.waitForSelector('dialog[open]');
    await shot(page, 'admin-desktop-1b-varaus-dialogi.png', false);
    await page.keyboard.press('Escape');
    // manuaalinen varaus loppuun asti
    const tue = (() => { const d = new Date(mon); d.setUTCDate(d.getUTCDate() + 8); return d.toISOString().slice(0, 10); })();
    await page.evaluate((m) => { location.hash = `#/uusi?d=${m}`; }, tue);
    await page.waitForSelector('.slotbtn:not([disabled])');
    await page.locator('.slotbtn:not([disabled])').nth(2).click();
    await page.fill('input[name=cname]', 'Puhelin Testi'); await page.fill('input[name=cemail]', `puhelin-${Date.now()}@example.com`); await page.fill('input[name=cphone]', '0401112222');
    await page.check('input[name=paid]');
    await shot(page, 'admin-desktop-7b-uusi-varaus-lomake.png');
    await page.click('#view form button[type=submit]');
    await page.waitForSelector('.ok-box');
    await shot(page, 'admin-desktop-7c-varaus-luotu.png', false);
  }
  for (const [hash, file] of [['varaukset', '2-varauslista'], ['asiakkaat', '3-asiakkaat'], ['tuotteet', '4-tuotteet'], ['resurssit', '5-resurssit'], ['asetukset', '6-asetukset'], ['uusi', '7-uusi-varaus'], ['kalenteri', '10-kalenteri-kuukausi'], ['kayttajat', '11-kayttajat']]) {
    await page.evaluate((h) => { location.hash = `#/${h}`; }, hash);
    await page.waitForTimeout(600);
    if (hash === 'kalenteri') {
      await page.waitForSelector('.cal-grid .cal-day');
      if ((await page.locator('.cal-day .chip.shift').count()) === 0 || (await page.locator('.cal-day .chip.booking').count()) === 0) problems.push(`admin-${name}: kalenterissa pitäisi näkyä sekä työvuoroja että varauksia`);
    }
    if (hash === 'kayttajat') await page.waitForSelector('.user');
    await shot(page, `admin-${name}-${file}.png`, hash !== 'kalenteri');
    if (hash === 'kalenteri') {   // viikkonäkymä + päivän tiedot
      await page.click('.cal-mode button[data-mode=week]');
      await page.waitForSelector('.cal-grid.week .cal-item.shift');
      await shot(page, `admin-${name}-10b-kalenteri-viikko.png`);
      await page.click('.cal-mode button[data-mode=month]');
      await page.waitForSelector('.cal-grid.month');
      await page.locator('.cal-day:has(.chip.shift):has(.chip.booking) .cal-dnum').first().click();
      await page.waitForSelector('.cal-detail .cal-item.booking');
      await shot(page, `admin-${name}-10c-kalenteri-paiva.png`);
    }
  }
  await ctx.close();
}
// ---------- HALLINTA: kalenteri toimii vaikka vuorotietoja ei saada (public-skeema tyhjä / ei oikeutta) ----------
if (process.env.ONLY !== 'shop') {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844, isMobile: true }, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const page = await ctx.newPage();   // ei watch(): odotettu 403 ei ole virhe
  await page.route('**/rpc/admin_upcoming_shifts', (r) => r.fulfill({ status: 403, contentType: 'application/json', body: JSON.stringify({ message: 'permission denied for table work_shifts' }) }));
  await page.goto(`${BASE}/admin/`);
  await page.fill('#email', 'admin@demo.local'); await page.fill('#password', 'demo');
  await page.click('form#login button[type=submit]');
  await page.waitForSelector('#nav a[href="#/kalenteri"]');
  await page.evaluate(() => { location.hash = '#/kalenteri'; });
  await page.waitForSelector('.notice');
  if ((await page.locator('.cal-day .chip.booking').count()) === 0) problems.push('kalenteri: varausten pitää näkyä vaikka vuorotietojen haku epäonnistuu');
  if ((await page.locator('.cal-day .chip.shift').count()) !== 0) problems.push('kalenteri: vuoroja ei pitäisi näkyä kun haku epäonnistuu');
  await shot(page, 'admin-mobile-13-kalenteri-ilman-vuoroja.png', false);
  await ctx.close();
}
// ---------- HALLINTA: kutsu → salasanan asetus → kirjautuminen (kehityspalvelimen mock-Edge Function) ----------
if (process.env.ONLY !== 'shop') {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const page = await ctx.newPage(); watch(page, 'admin-kutsu');
  await page.goto(`${BASE}/admin/`);
  await page.waitForSelector('form#login');
  await page.fill('#email', 'admin@demo.local'); await page.fill('#password', 'demo');
  await page.click('form#login button[type=submit]');
  await page.waitForSelector('#view');
  await page.evaluate(() => { location.hash = '#/kayttajat'; });
  await page.waitForSelector('.user');
  await page.click('button:has-text("+ Kutsu käyttäjä")');
  const email = `kutsuttu-${Date.now()}@example.com`;
  await page.fill('dialog input[name=email]', email); await page.fill('dialog input[name=name]', 'Kutsuttu Kalle');
  await shot(page, 'admin-desktop-12-kutsu-dialogi.png', false);
  await page.click('dialog button[type=submit]');
  await page.waitForSelector('dialog input[aria-label="Kutsulinkki"]');
  const link = await page.inputValue('dialog input[aria-label="Kutsulinkki"]');
  await page.keyboard.press('Escape');
  await page.reload(); await page.waitForSelector('.user');
  // roolin vaihto ja linkitys
  const card = page.locator(`.user[data-user="${email}"]`);
  await card.waitFor();
  await card.locator('select').first().selectOption('manager');
  await page.waitForTimeout(500);
  await page.reload(); await page.waitForSelector('.user');
  if ((await page.locator(`.user[data-user="${email}"] select`).first().inputValue()) !== 'manager') problems.push('admin-kutsu: roolin vaihto ei tallentunut');
  const taken = await page.locator('.user select[aria-label^="Työntekijä"]').evaluateAll((els) => els.map((e) => e.value).filter(Boolean));
  const freeVal = await card.locator('select').nth(1).evaluate((el, t) => [...el.options].map((o) => o.value).find((v) => v && !t.includes(v)), taken);
  await card.locator('select').nth(1).selectOption(freeVal);
  await page.waitForTimeout(500);
  await page.reload(); await page.waitForSelector('.user');
  if ((await page.locator(`.user[data-user="${email}"] select`).nth(1).inputValue()) !== freeVal) problems.push('admin-kutsu: linkitys ei tallentunut');
  // omaa riviä ei voi muokata
  const own = page.locator('.user[data-user="admin@demo.local"]');
  if (!(await own.locator('select').first().isDisabled()) || !(await own.locator('button:has-text("Poista käytöstä")').isDisabled())) problems.push('admin-kutsu: oman rivin rooli/deaktivointi pitää olla lukittu');
  await shot(page, 'admin-desktop-13-kayttajat-kutsuttu.png');
  await page.locator(`.user[data-user="${email}"] select`).nth(1).selectOption('');   // siivous: linkki pois, jotta demo pysyy toistettavana
  await page.waitForTimeout(400);
  // kutsulinkki toisessa istunnossa
  const ctx2 = await browser.newContext({ viewport: { width: 390, height: 844, isMobile: true }, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const p2 = await ctx2.newPage(); watch(p2, 'admin-kutsuttu');
  await p2.goto(link);
  await p2.waitForSelector('form#setpw:not([hidden]), #setpw-screen:not([hidden])');
  await shot(p2, 'admin-mobile-12-aseta-salasana.png', false);
  await p2.fill('#pw1', 'lyhyt'); await p2.fill('#pw2', 'lyhyt'); await p2.click('#setpw button[type=submit]');
  await p2.waitForSelector('#setpw-err:not([hidden])');
  await p2.fill('#pw1', 'pitkasalasana1'); await p2.fill('#pw2', 'pitkasalasana1'); await p2.click('#setpw button[type=submit]');
  await p2.waitForSelector('#shell:not([hidden]) #nav a');
  if (p2.url().includes('access_token')) problems.push('admin-kutsuttu: tokenit jäivät osoiteriville');
  if ((await p2.locator('#nav a[href="#/kayttajat"]').count()) !== 0) problems.push('admin-kutsuttu: manager ei saa nähdä Käyttäjät-valikkoa');
  await ctx2.close();
  // deaktivointi estää kirjautumisen, aktivointi palauttaa
  const login = (pw) => page.request.post(`${BASE}/auth/v1/token?grant_type=password`, { data: { email, password: pw } });
  if (!(await login('pitkasalasana1')).ok()) problems.push('admin-kutsu: kutsuttu käyttäjä ei pääse kirjautumaan salasanan asetuksen jälkeen');
  page.once('dialog', (d) => d.accept());
  await page.locator(`.user[data-user="${email}"] button:has-text("Poista käytöstä")`).click();
  await page.waitForSelector(`.user.inactive[data-user="${email}"]`);
  if ((await login('pitkasalasana1')).ok()) problems.push('admin-kutsu: deaktivoitu käyttäjä pääsi kirjautumaan');
  await page.locator(`.user[data-user="${email}"] button:has-text("Aktivoi")`).click();
  await page.waitForSelector(`.user:not(.inactive)[data-user="${email}"]`);
  if (!(await login('pitkasalasana1')).ok()) problems.push('admin-kutsu: aktivoitu käyttäjä ei pääse kirjautumaan');
  await ctx.close();
}
// ---------- HALLINTA: roolit (staff = peruskäyttäjä, manager = ylläpitäjä) ----------
if (process.env.ONLY !== 'shop') for (const [who, role] of [['staff', 'staff'], ['manager', 'manager']]) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const page = await ctx.newPage(); watch(page, `admin-${role}`);
  await page.goto(`${BASE}/admin/`);
  await page.waitForSelector('form#login');
  await page.fill('#email', `${who}@demo.local`); await page.fill('#password', 'demo');
  await page.click('form#login button[type=submit]');
  await page.waitForSelector('#view .day-view, #view .daygrid');
  const hasSettings = (await page.locator('#nav a[href="#/asetukset"]').count()) > 0;
  if (role === 'staff' && hasSettings) problems.push('admin-staff: Asetukset-valikon ei pitäisi näkyä peruskäyttäjälle');
  if (role === 'manager' && !hasSettings) problems.push('admin-manager: Asetukset-valikon pitäisi näkyä ylläpitäjälle');
  if ((await page.locator('#nav a[href="#/kayttajat"]').count()) !== 0) problems.push(`admin-${role}: Käyttäjät-valikon ei pitäisi näkyä (staff.manage vain admin)`);
  if ((await page.locator('#nav a[href="#/kalenteri"]').count()) !== 1) problems.push(`admin-${role}: Kalenteri-valikon pitäisi näkyä`);
  await page.evaluate(() => { location.hash = '#/kalenteri'; });
  await page.waitForSelector('.cal-grid .cal-day');
  await page.click('.cal-mode button[data-mode=week]');
  await page.waitForSelector('.cal-grid.week .cal-item.shift');
  const names = [...new Set(await page.locator('.cal-grid.week .cal-item.shift .cal-txt > span').allTextContents())];
  if (role === 'staff' && (names.length !== 1 || names[0] !== 'Demo Peruskäyttäjä')) problems.push(`admin-staff: peruskäyttäjän pitäisi nähdä vain omat vuoronsa, nyt: ${names.join(' / ')}`);
  if (role === 'manager' && names.length < 2) problems.push('admin-manager: ylläpitäjän pitäisi nähdä muidenkin vuorot');
  await shot(page, `admin-desktop-10-${role}-kalenteri-viikko.png`);
  await page.evaluate(() => { location.hash = '#/kayttajat'; });
  await page.waitForTimeout(400);
  if ((await page.locator('.user').count()) !== 0) problems.push(`admin-${role}: käyttäjälistaa ei saa näkyä`);
  await page.evaluate(() => { location.hash = '#/tuotteet'; });
  await page.waitForSelector('#view .listrow');
  await page.locator('#view .listrow').first().click();
  await page.waitForSelector('dialog[open]');
  const priceDisabled = await page.locator('dialog input[name=price]').isDisabled();
  if (role === 'staff' && !priceDisabled) problems.push('admin-staff: hintakentän pitäisi olla lukittu peruskäyttäjälle');
  if (role === 'manager' && priceDisabled) problems.push('admin-manager: hintakentän pitäisi olla muokattavissa ylläpitäjälle');
  await shot(page, `admin-desktop-8-${role}-tuote.png`, false);
  await page.keyboard.press('Escape');
  if (role === 'manager') {
    await page.evaluate(() => { location.hash = '#/resurssit'; });
    await page.waitForTimeout(700);
    await shot(page, 'admin-desktop-9-manager-resurssit.png');
  }
  await ctx.close();
}
await browser.close();
if (problems.length) { console.error('ONGELMIA:\n' + [...new Set(problems)].join('\n')); process.exit(1); }
console.log(`ok: kuvakaappaukset → ${OUT}; ei konsolivirheitä`);
