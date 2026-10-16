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
  // ---- Selaa päivän mukaan (v13): FI + EN, päivä jolla on useita vuoroja, tyhjä päivä, siirtymä lomakkeelle ja takaisin ----
  for (const lang of ['fi', 'en']) {
    const L = lang === 'fi'
      ? { base: `${BASE}/varaa/`, modeCat: 'Selaa kategorioittain', modeDay: 'Selaa päivän mukaan', empty: 'Ei vapaita vuoroja valitulle päivälle', next: 'Seuraava päivä, jolla on vapaita vuoroja', file: '' }
      : { base: `${BASE}/en/book/`, modeCat: 'Browse by category', modeDay: 'Browse by date', empty: 'No available sessions for the selected date', next: 'Next day with available sessions', file: 'en-' };
    if (lang === 'en') await page.goto(L.base);   // FI: ollaan jo tuotelistassa
    await page.waitForSelector('.bk-cards');
    if ((await page.locator('.bk-modes a[aria-current]').innerText()).trim().toLowerCase() !== L.modeCat.toLowerCase()) problems.push(`shop-${name}-${lang}: oletustilan pitää olla "${L.modeCat}"`);
    await page.click(`.bk-modes a:has-text("${L.modeDay}")`);
    await page.waitForSelector('.bk-strip');
    if (!/#\/paiva\/\d{4}-\d\d-\d\d$/.test(page.url())) problems.push(`shop-${name}-${lang}: päivänäkymän reitin pitää olla #/paiva/<pvm>: ${page.url()}`);
    for (let i = 0; i < 4 && (await page.locator('.bk-sd.free').count()) === 0; i++) await page.click('.bk-weeknav a[aria-label]:last-child');
    await page.locator('.bk-sd.free').last().click();
    await page.waitForSelector('.bk-dayresults .bk-pc');
    // v14: ensin vain saatavilla olevat tuotteet (kortit suljettuina), ajat vasta kun tuote avataan
    const cards = await page.locator('.bk-dayresults .bk-pc').count();
    if (cards < 2) problems.push(`shop-${name}-${lang}: valitulla päivällä pitäisi olla useita tuotteita, nyt ${cards}`);
    if ((await page.locator('.bk-dayresults .bk-slot:visible').count()) !== 0) problems.push(`shop-${name}-${lang}: vuorot eivät saa näkyä ennen kuin tuote avataan`);
    if ((await page.locator('.bk-pc-head[aria-expanded=true]').count()) !== 0) problems.push(`shop-${name}-${lang}: kaikkien korttien pitää olla oletuksena suljettuina`);
    const summaries = await page.locator('.bk-pc-head').allInnerTexts();
    if (summaries.some((x) => !/\d/.test(x) || x.includes('[object'))) problems.push(`shop-${name}-${lang}: tuotekortin tiivistelmä (vapaita aikoja) puuttuu: ${summaries.join(' | ')}`);
    if ((await page.locator('.bk-pc-head[aria-controls]').evaluateAll((els) => els.every((e) => document.getElementById(e.getAttribute('aria-controls'))))) !== true) problems.push(`shop-${name}-${lang}: aria-controls ei osoita paneeliin`);
    await page.addStyleTag({ content: '.site-header{position:static!important}' });
    await page.locator('#booking-app').screenshot({ path: join(OUT, `shop-${name}-${L.file}8-paiva-vuorot.png`) });
    // avaa tuote → ajat näkyviin, tila URL:ssa
    await page.locator('.bk-pc-head').first().click();
    await page.waitForSelector('.bk-pc.open .bk-slot:visible');
    if ((await page.locator('.bk-pc-head').first().getAttribute('aria-expanded')) !== 'true' || !/[?]tuote=[a-z0-9-]+$/.test(page.url())) problems.push(`shop-${name}-${lang}: avattu tila ei näy aria-expanded/URL:ssa (${page.url()})`);
    if ((await page.locator('.bk-pc.open').count()) !== 1) problems.push(`shop-${name}-${lang}: vain yhden kortin pitää olla auki`);
    const times = await page.locator('.bk-pc.open .bk-slot .bk-time').allInnerTexts();
    const startMin = (x) => { const m = x.match(/(\d{1,2})(?::(\d\d))?/); return +m[1] * 60 + +(m[2] || 0); };
    if (times.some((x, i) => i && startMin(x) < startMin(times[i - 1]))) problems.push(`shop-${name}-${lang}: vuorojen pitää olla aikajärjestyksessä: ${times.join(', ')}`);
    if ((await page.locator('.bk-dayresults').innerText()).includes('[object')) problems.push(`shop-${name}-${lang}: päivänäkymän sisältö virheellinen`);
    await page.locator('#booking-app').screenshot({ path: join(OUT, `shop-${name}-${L.file}8c-paiva-tuote-auki.png`) });
    // Valitse → lomake (sama reitti kuin tuotteen päivänäkymästä) → Takaisin palauttaa saman tilan (sama tuote auki)
    const dayUrl = page.url();
    const openSlug = await page.locator('.bk-pc.open').getAttribute('data-slug');
    await page.locator('.bk-pc.open .bk-slot.available a.btn').first().click();
    await page.waitForSelector('form.bk-form');
    if (!/#\/varaa\/\d+\/\d{4}-\d\d-\d\d\/\d+/.test(page.url())) problems.push(`shop-${name}-${lang}: Valitse vei väärälle reitille: ${page.url()}`);
    // v16: lyhyt yhteenveto otsikon alla (tuote, päivä, kellonaika) ja yksi "Vaihda päivää tai aikaa" -linkki (ei erillistä Takaisin-linkkiä)
    {
      const pk = await page.evaluate(() => { const h2 = document.querySelector('#booking-app h2'), pk = document.querySelector('#booking-app .bk-pick'); return { h2next: h2?.nextElementSibling === pk, name: pk?.querySelector('.bk-pick-name')?.textContent, when: pk?.querySelector('.bk-pick-when')?.textContent, link: pk?.querySelector('a.bk-pick-change')?.textContent, links: document.querySelectorAll('#booking-app > p a, #booking-app .bk-pick a').length, first: document.querySelector('#booking-app').firstElementChild.tagName }; });
      const whenRe = lang === 'fi' ? /^(ma|ti|ke|to|pe|la|su) \d{1,2}\.\d{1,2}\.\d{4}, klo \d{2}:\d{2}–\d{2}:\d{2}$/ : /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun),? \d{1,2} [A-Z][a-z]{2} \d{4} · \d{2}:\d{2}–\d{2}:\d{2}$/;
      if (!pk.h2next || pk.first !== 'H2') problems.push(`shop-${name}-${lang}: yhteenvetolaatikon pitää olla heti otsikon (h2) alla: ${JSON.stringify(pk)}`);
      if (!pk.name || !whenRe.test(pk.when || '')) problems.push(`shop-${name}-${lang}: yhteenvetorivin sisältö väärä (tuote "${pk.name}", aika "${pk.when}")`);
      if (pk.link !== (lang === 'fi' ? 'Vaihda päivää tai aikaa' : 'Change date or time') || pk.links !== 1) problems.push(`shop-${name}-${lang}: linkki "Vaihda päivää tai aikaa" puuttuu tai linkkejä on useita: ${JSON.stringify(pk)}`);
      await page.locator('#booking-app').screenshot({ path: join(OUT, `shop-${name}-${L.file}8d-lomake-yhteenveto.png`) });
    }
    await page.click('#booking-app .bk-pick a.bk-pick-change');
    await page.waitForSelector('.bk-strip');
    if (page.url() !== dayUrl || (await page.locator('.bk-pc.open').getAttribute('data-slug').catch(() => null)) !== openSlug) problems.push(`shop-${name}-${lang}: "Vaihda päivää tai aikaa" -linkin pitää palauttaa päivä ja avattu tuote (${page.url()} ≠ ${dayUrl})`);
    await page.locator('.bk-pc-head[aria-expanded=true]').click();   // sulje: tuote-parametri pois URL:sta
    if (/tuote=/.test(page.url())) problems.push(`shop-${name}-${lang}: sulkeminen ei poistanut ?tuote-parametria`);
    // tyhjä päivä: ilmoitus + ehdotus seuraavasta vapaasta päivästä
    let emptyShown = false;
    for (let i = 0; i < 28 && !emptyShown; i++) {
      const d = new Date(Date.now() + i * 864e5).toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
      await page.evaluate((x) => { location.hash = `#/paiva/${x}`; }, d);
      await page.waitForSelector(`.bk-strip a[aria-current=date][href$="${d}"], .bk-strip a[aria-current=date]`);
      await page.waitForTimeout(150);
      emptyShown = (await page.locator('.bk-dayresults .bk-notice').count()) > 0;
    }
    if (!emptyShown) problems.push(`shop-${name}-${lang}: tyhjää päivää ei löytynyt demodatasta`);
    else {
      const txt = await page.locator('.bk-dayresults .bk-notice').innerText();
      if (!txt.includes(L.empty)) problems.push(`shop-${name}-${lang}: tyhjän päivän ilmoitus puuttuu: ${txt}`);
      if (!txt.includes(L.next) || (await page.locator('.bk-dayresults .bk-notice a').count()) !== 1) problems.push(`shop-${name}-${lang}: seuraavan vapaan päivän ehdotus puuttuu`);
      await page.locator('#booking-app').screenshot({ path: join(OUT, `shop-${name}-${L.file}8b-paiva-tyhja.png`) });
      await page.click('.bk-dayresults .bk-notice a');
      await page.waitForSelector('.bk-dayresults .bk-pc');
    }
  }
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
  // ---- yritysasiakas + lisäpalvelut (migraatio 11) ----
  const pickSlot = async (url) => {
    await page.goto(url);
    await page.waitForSelector('.bk-grid button.bk-cell.free');
    await page.locator('.bk-grid button.bk-cell.free').last().click();
    await page.locator('.bk-slot.available a.btn').last().click();   // eri vuoro kuin perusvarauksessa (vuoron kapasiteetti 6)
    await page.waitForSelector('.bk-form .bk-addon');
  };
  await pickSlot(`${BASE}/varaa/#/tuote/yleinensauna`);
  await page.locator('.bk-stepper .bk-step[aria-label="+"]').first().click();   // 2 henkilöä
  const addonRows = page.locator('.bk-addon');
  if ((await addonRows.count()) < 2) problems.push(`shop-${name}: lisäpalvelut puuttuvat kassalta`);
  await addonRows.nth(0).locator('.bk-step').last().click();                                              // 1 × Turvenaamio
  for (let i = 0; i < 2; i++) await addonRows.nth(1).locator('.bk-step').last().click();                  // 2 × Saunavihta (max = 2 hlö × 1)
  if ((await addonRows.nth(1).locator('.bk-step').last().isDisabled()) !== true) problems.push(`shop-${name}: lisäpalvelun määrä ei rajoitu henkilömäärään`);
  await page.check('input[name=kind][value=company]');
  await page.waitForSelector('#bk-company:not([hidden])');
  if ((await page.locator('label[for=name]').innerText()) !== 'Yhteyshenkilön nimi') problems.push(`shop-${name}: yritysasiakkaan nimikenttä pitää olla "Yhteyshenkilön nimi"`);
  await page.fill('#company_name', 'Testi Oy'); await page.fill('#street', 'Yrityskatu 1'); await page.fill('#zip', '00100'); await page.fill('#city', 'Helsinki');
  await page.fill('#einvoice_address', '003701120389'); await page.fill('#einvoice_operator', '003723327487'); await page.fill('#reference', 'PO-4711');
  await page.fill('#name', `Yritys Yhteys ${name}`); await page.fill('#email', `yritys-${name}-${Date.now()}@example.com`); await page.fill('#phone', '0401234567');
  await page.check('#bk-terms');
  await page.fill('#business_id', '0112038-8');                                                           // väärä tarkistenumero → virhe, ei lähetystä
  await page.click('button[type=submit]');
  await page.waitForSelector('#bk-msg [role=alert], #bk-msg .bk-error, #bk-msg *');
  if (!/y-tunnus/i.test(await page.locator('#bk-msg').innerText())) problems.push(`shop-${name}: virheellisestä y-tunnuksesta ei tullut virheilmoitusta`);
  await page.fill('#business_id', '01120389');
  const aside = await page.locator('.bk-aside').innerText();
  if (/\[object/.test(aside) || !/Saunavihta/i.test(aside) || !/Turvenaamio/i.test(aside)) problems.push(`shop-${name}: yhteenvedossa pitää näkyä valitut lisäpalvelut (ei [object …])`);
  await shot(page, `shop-${name}-4b-yritys-lisapalvelut.png`);
  await page.click('button[type=submit]');
  await page.waitForURL(/vahvistus/);
  await page.waitForSelector('.bk-conf dl');
  const confText = await page.locator('.bk-conf').innerText();
  if (/\[object/.test(confText) || !/Saunavihta/i.test(confText) || !/Turvenaamio/i.test(confText)) problems.push(`shop-${name}: vahvistussivulta puuttuvat lisäpalvelut`);
  if (!/laskutetaan/i.test(confText)) problems.push(`shop-${name}: yritysasiakkaan vahvistussivulla pitäisi olla laskutushuomautus`);
  await shot(page, `shop-${name}-5b-vahvistus-yritys.png`);
  if (name === 'desktop') {   // englanninkielinen kauppa: asiakastyyppi ja lisäpalvelut
    await pickSlot(`${BASE}/en/book/#/tuote/yleinensauna`);
    for (const txt of ['Business customer', 'Private customer', 'Add-ons']) if ((await page.locator(`text=${txt}`).count()) === 0) problems.push(`shop-en: teksti puuttuu: ${txt}`);
    await page.check('input[name=kind][value=company]');
    await shot(page, 'shop-desktop-en-4b-company-addons.png');
  }
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
  // lisäpalvelut päivänäkymässä: "Valmistele"-yhteenveto + varauskohtaiset merkinnät + yritysasiakkaan merkintä
  await page.waitForSelector('.prepday');
  if ((await page.locator('.session .prep').count()) === 0) problems.push(`admin-${name}: vuorokortilla pitää olla "Valmistele"-rivi`);
  if ((await page.locator('.addon-mark').count()) === 0) problems.push(`admin-${name}: varauksilla pitää olla lisäpalvelumerkintä`);
  if ((await page.locator('.badge:has-text("Yritys")').count()) === 0) problems.push(`admin-${name}: yritysasiakkaan merkintä puuttuu päivänäkymästä`);
  await shot(page, `admin-${name}-1c-paivanakyma-lisapalvelut.png`, true);
  await page.locator('button.link:has-text("Kaisa Yhteys")').first().click();
  await page.waitForSelector('dialog[open] .order-extra .box');
  if (!/Demo Yritys Oy[\s\S]*0112038-9/.test(await page.locator('dialog[open]').innerText())) problems.push(`admin-${name}: varausdialogin laskutustiedot puuttuvat`);
  await shot(page, `admin-${name}-1d-varaus-yritys-dialogi.png`, false);
  await page.keyboard.press('Escape');
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
    await page.waitForSelector('.addon-picker:not([hidden]) .addonrow input');
    await page.locator('.addon-picker .addonrow:not([hidden]) input').first().fill('1');
    await page.locator('.addon-picker .addonrow:not([hidden]) input').nth(1).fill('1');
    await shot(page, 'admin-desktop-7b-uusi-varaus-lomake.png');
    await page.click('#view form button[type=submit]');
    await page.waitForSelector('.ok-box');
    if (!/\d/.test(await page.locator('.ok-box').innerText())) problems.push('admin: varausvahvistus puuttuu');
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
      // työvuorojen rooli ja miehitys suomeksi (ei role_type-koodeja, ei "Hoitaja"): päivä, jolla on lämmitys, saunottaja ja vastaanotto
      await page.locator('.cal-day:has(.chip.shift[title="4 työvuoroa"]) .cal-dnum').first().click();
      await page.waitForSelector('.cal-detail .cal-item.shift');
      const shiftText = await page.locator('.cal-detail .cal-item.shift').allInnerTexts();
      const all = shiftText.join('\n');
      if (shiftText.length !== 4) problems.push(`admin-${name}: päivällä pitäisi olla 4 työvuoroa, nyt ${shiftText.length}`);
      for (const w of ['Lämmitykset', 'Vastaanotto', 'Saunottaja', 'Ei nimettyä tekijää']) if (!all.includes(w)) problems.push(`admin-${name}: työvuoroista puuttuu "${w}"`);
      if (/heater|reception|therapist|assigned|hoitaja/i.test(all.replace(/unassigned/gi, '')) || /\b(assigned|unassigned|open|full)\b/i.test(all)) problems.push(`admin-${name}: työvuoroissa näkyy englanninkielinen koodi: ${all.replace(/\n/g, ' | ')}`);
      // miehitysmerkki vain nimeämättömällä vuorolla: nimetty → ei merkkiä (ei "Miehitetty"), nimeämätön → "Ei nimettyä tekijää"
      const notice = await page.evaluate(() => [...document.querySelectorAll('.cal-detail .cal-item.shift')].map((li) => ({ named: !!li.querySelector('.cal-txt > span'), badge: li.querySelector('.badge')?.textContent ?? null })));
      if (!notice.some((x) => x.named) || !notice.some((x) => !x.named)) problems.push(`admin-${name}: päivällä pitää olla sekä nimetty että nimeämätön vuoro: ${JSON.stringify(notice)}`);
      for (const x of notice) if (x.named ? x.badge !== null : x.badge !== 'Ei nimettyä tekijää') problems.push(`admin-${name}: miehitysmerkki väärin (nimetty=${x.named}, merkki=${x.badge})`);
      if (/miehitetty|osittain|avoin/i.test(all)) problems.push(`admin-${name}: työvuorokortissa ei saa näkyä Miehitetty/Osittain/Avoin: ${all.replace(/\n/g, ' | ')}`);
      // värit: hillityt, ei sinistä (b-kanava ei dominoi), kolmella roolilla eri väri, teksti-/taustakontrasti ≥ 4,5:1 (WCAG AA)
      const colors = await page.evaluate(() => {
        const rgb = (c) => (c.match(/[\d.]+/g) || []).slice(0, 3).map(Number);
        const lum = (c) => { const [r, g, b] = rgb(c).map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
        const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m); return (x + 0.05) / (y + 0.05); };
        const cards = [...document.querySelectorAll('.cal-detail .cal-item.shift')].map((li) => {
          const cs = getComputedStyle(li), bg = cs.backgroundColor;
          const texts = [...li.querySelectorAll('.cal-time, .cal-txt strong, .cal-txt > span')].map((e) => ratio(getComputedStyle(e).color, bg));
          const badge = li.querySelector('.badge'), bcs = badge && getComputedStyle(badge);
          return { cls: li.className, role: li.querySelector('strong').textContent, bg, bar: cs.borderLeftColor, minText: Math.min(...texts), badge: badge ? ratio(bcs.color, bcs.backgroundColor) : 99 };
        });
        const h3 = getComputedStyle(document.querySelector('.cal-detail .shift-h')).color;
        const chip = [...document.querySelectorAll('.chip.shift')].map((e) => ({ c: getComputedStyle(e).color, bg: getComputedStyle(e).backgroundColor, b: getComputedStyle(e).borderTopColor }));
        return { cards, h3, chip, };
      });
      const notBlue = (c) => { const [r, g, b] = (c.match(/[\d.]+/g) || []).map(Number); return !(b > r + 8 && b >= g); };   // b-kanava ei dominoi
      for (const c of colors.cards) {
        if (!notBlue(c.bg) || !notBlue(c.bar)) problems.push(`admin-${name}: työvuorokortti (${c.role}) on sininen: ${c.bg} / ${c.bar}`);
        if (c.minText < 4.5 || c.badge < 4.5) problems.push(`admin-${name}: työvuorokortin (${c.role}) kontrasti liian pieni: teksti ${c.minText.toFixed(2)}, merkki ${c.badge.toFixed(2)}`);
      }
      const byRole = new Map(colors.cards.map((c) => [c.role, c]));   // sama rooli = sama väri; eri rooleilla eri tausta- ja reunaväri
      if (new Set([...byRole.values()].map((c) => c.bg)).size !== byRole.size || new Set([...byRole.values()].map((c) => c.bar)).size !== byRole.size) problems.push(`admin-${name}: eri rooleilla pitää olla eri taustaväri ja reunaväri: ${JSON.stringify([...byRole.values()].map((c) => [c.role, c.bg, c.bar]))}`);
      if (colors.cards.some((c) => c.bg !== byRole.get(c.role).bg)) problems.push(`admin-${name}: saman roolin korttien värin pitää olla sama`);
      for (const [cls, role] of [['shift-heater', 'Lämmitykset'], ['shift-reception', 'Vastaanotto'], ['shift-therapist', 'Saunottaja']]) if (!colors.cards.some((c) => c.cls.includes(cls) && c.role === role)) problems.push(`admin-${name}: luokka ${cls} puuttuu roolilta ${role}`);
      if (!notBlue(colors.h3) || colors.chip.some((c) => !notBlue(c.c) || !notBlue(c.bg) || !notBlue(c.b))) problems.push(`admin-${name}: Työvuorot-otsikko tai -merkki on sininen`);
      await page.evaluate(() => { const d = document.querySelector('.cal-detail'); window.scrollTo(0, d.getBoundingClientRect().top + scrollY - 70); });
      await page.waitForTimeout(200);
      await shot(page, `admin-${name}-10d-kalenteri-tyovuorot-roolit.png`, false);   // näkymän kokoinen kuva: kiinteä alavalikko ei peitä sisältöä
    }
  }
    // ---- Asiakkaat: Lisää asiakas (yksityinen / yritys) ----
  await page.evaluate(() => { location.hash = '#/asiakkaat'; });
  await page.waitForSelector('.listrow');
  await page.click('button:has-text("Lisää asiakas")');
  await page.waitForSelector('dialog[open] .kindset');
  await shot(page, `admin-${name}-3b-lisaa-asiakas-yksityinen.png`, false);
  await page.check('dialog input[value=company]');
  await page.waitForSelector('dialog .company-box:not([hidden])');
  const stamp = Date.now();
  await page.fill('dialog [name=company_name]', `Lisätty Oy ${stamp}`); await page.fill('dialog [name=business_id]', '2336509-5');
  await page.fill('dialog [name=street]', 'Tehdaskatu 2'); await page.fill('dialog [name=zip]', '33100'); await page.fill('dialog [name=city]', 'Tampere');
  await page.fill('dialog [name=einvoice_address]', '003723365096'); await page.fill('dialog [name=einvoice_operator]', 'BAWCFI22'); await page.fill('dialog [name=reference]', 'OSTO-1');
  await page.fill('dialog [name=cname]', 'Liisa Laskutus'); await page.fill('dialog [name=cemail]', `liisa-${stamp}@example.com`); await page.fill('dialog [name=cphone]', '0409998888');
  await page.setViewportSize({ width: vp.width, height: 1900 });
  await shot(page, `admin-${name}-3c-lisaa-asiakas-yritys.png`, false);
  await page.setViewportSize({ width: vp.width, height: vp.height });
  await page.click('dialog button[type=submit]:has-text("Lisää asiakas")');
  await page.waitForSelector('#toast.err.show');                                      // väärä y-tunnus (tarkistenumero) → virhe, asiakasta ei luotu
  if (!/y-tunnus/i.test(await page.locator('#toast').innerText())) problems.push(`admin-${name}: virheellisestä y-tunnuksesta ei tullut virheilmoitusta`);
  await page.fill('dialog [name=business_id]', '2336509-6');
  await page.click('dialog button[type=submit]:has-text("Lisää asiakas")');
  await page.waitForSelector(`dialog[open] h2:has-text("Liisa Laskutus")`);          // luonnin jälkeen avautuu asiakaskortti
  await page.keyboard.press('Escape');
  await page.fill('input[type=search]', '2336509-6');
  await page.waitForSelector(`.listrow:has-text("Lisätty Oy ${stamp}")`);
  if ((await page.locator('.listrow .badge:has-text("Yritys")').count()) === 0) problems.push(`admin-${name}: asiakaslistalla pitää näkyä Yritys-merkintä`);
  await shot(page, `admin-${name}-3d-asiakaslista-yritys.png`, false);
  // lisäpalveluiden ylläpito Tuotteet-sivulla
  await page.evaluate(() => { location.hash = '#/tuotteet'; });
  await page.waitForSelector('#addons-h');
  await page.locator('.listrow:has-text("Saunavihta"):has-text("hlö"):has-text("ALV")').filter({ hasText: 'max' }).click();
  await page.waitForSelector('dialog[open] form [name=price]');
  await shot(page, `admin-${name}-4c-lisapalvelun-muokkaus.png`, false);
  await page.keyboard.press('Escape');
  await ctx.close();
}
// ---------- HALLINTA: Johku-tunniste ja lähdesuodatin (Kaikki / Uudet / Johku → p_source) ----------
// Vaatii migraation booking_12 (admin_list_reservations.p_source/source/external_id, admin_day_view.source) demokannassa ja demosiemenen Johku-varaukset (dev/seed_demo.sql).
if (process.env.ONLY !== 'shop') {
  const login = async (page) => { await page.goto(`${BASE}/admin/`); await page.fill('#email', 'admin@demo.local'); await page.fill('#password', 'demo'); await page.click('form#login button[type=submit]'); await page.waitForSelector('#view .day-view, #view .daygrid'); };
  const nextMon = (() => { const d = new Date(); d.setUTCDate(d.getUTCDate() + ((8 - d.getUTCDay()) % 7 || 7)); return d.toISOString().slice(0, 10); })();
  const overflow = (page) => page.evaluate(() => { const d = document.querySelector('dialog[open]'); return { page: document.documentElement.scrollWidth - document.documentElement.clientWidth, dlg: d ? d.scrollWidth - d.clientWidth : 0 }; });
  const rpcArgs = [];
  const listReload = async (page, action) => { const [resp] = await Promise.all([page.waitForResponse((r) => r.url().includes('/rpc/admin_list_reservations')), action()]); await resp.finished(); await page.waitForTimeout(150); };
  const rowsInfo = (page) => page.evaluate(() => [...document.querySelectorAll('#view .listrow')].map((li) => ({ johku: !!li.querySelector('.badge.src-johku'), text: li.innerText })));
  for (const [name, vp] of [['mobile', { width: 390, height: 844, isMobile: true, hasTouch: true }], ['desktop', { width: 1280, height: 900 }]]) {
    const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, isMobile: vp.isMobile, hasTouch: vp.hasTouch, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
    const page = await ctx.newPage(); watch(page, `johku-${name}`);
    page.on('request', (r) => { if (r.url().includes('/rpc/admin_list_reservations')) rpcArgs.push(JSON.parse(r.postData() || '{}')); });
    await login(page);
    // --- varauslista: tunniste + suodatin ---
    await page.evaluate(() => { location.hash = '#/varaukset'; });
    await page.waitForSelector('#view .listrow');
    const grp = page.getByRole('group', { name: 'Lähde' });
    if ((await grp.getByRole('radio').count()) !== 3) problems.push(`johku-${name}: lähdesuodattimessa pitää olla 3 vaihtoehtoa (Kaikki/Uudet/Johku)`);
    for (const l of ['Kaikki', 'Uudet', 'Johku']) if ((await grp.getByRole('radio', { name: l }).count()) !== 1) problems.push(`johku-${name}: suodatinvaihtoehto puuttuu: ${l}`);
    if (!(await grp.getByRole('radio', { name: 'Kaikki' }).isChecked())) problems.push(`johku-${name}: oletussuodatin pitää olla Kaikki`);
    const all = await rowsInfo(page);
    const nJ = all.filter((x) => x.johku).length;
    if (nJ < 3 || nJ === all.length) problems.push(`johku-${name}: Kaikki-listalla pitää olla sekä Johku- (≥3) että uusia varauksia, nyt ${nJ}/${all.length}`);
    if (!all.filter((x) => x.johku).every((x) => /Johku/.test(x.text))) problems.push(`johku-${name}: Johku-tunnisteen pitää olla tekstinä`);
    if (rpcArgs.length && rpcArgs.at(-1).p_source != null) problems.push(`johku-${name}: Kaikki ei saa lähettää p_source-arvoa: ${JSON.stringify(rpcArgs.at(-1))}`);
    await shot(page, `admin-${name}-20-varauslista-kaikki-johku-tunniste.png`, true);
    await listReload(page, () => grp.getByRole('radio', { name: 'Johku' }).check());
    if (rpcArgs.at(-1).p_source !== 'johku') problems.push(`johku-${name}: Johku-suodatin pitää lähettää p_source='johku': ${JSON.stringify(rpcArgs.at(-1))}`);
    const onlyJ = await rowsInfo(page);
    if (onlyJ.length !== nJ || !onlyJ.every((x) => x.johku)) problems.push(`johku-${name}: Johku-suodatin: pitäisi näkyä vain ${nJ} Johku-varausta, nyt ${onlyJ.length} (Johku ${onlyJ.filter((x) => x.johku).length})`);
    if (!(await grp.getByRole('radio', { name: 'Johku' }).isChecked())) problems.push(`johku-${name}: valittu suodatin ei ole merkitty (checked)`);
    await shot(page, `admin-${name}-21-varauslista-suodatin-johku.png`, false);
    await listReload(page, () => grp.getByRole('radio', { name: 'Uudet' }).check());
    if (rpcArgs.at(-1).p_source !== 'native') problems.push(`johku-${name}: Uudet-suodatin pitää lähettää p_source='native': ${JSON.stringify(rpcArgs.at(-1))}`);
    const onlyN = await rowsInfo(page);
    if (!onlyN.length || onlyN.some((x) => x.johku) || onlyN.length !== all.length - nJ) problems.push(`johku-${name}: Uudet-suodatin: pitäisi näkyä ${all.length - nJ} ei-Johku-varausta, nyt ${onlyN.length} (Johku ${onlyN.filter((x) => x.johku).length})`);
    await shot(page, `admin-${name}-22-varauslista-suodatin-uudet.png`, false);
    await listReload(page, () => grp.getByRole('radio', { name: 'Kaikki' }).check());
    if (rpcArgs.at(-1).p_source != null || (await rowsInfo(page)).length !== all.length) problems.push(`johku-${name}: paluu Kaikki-suodattimeen ei palauttanut koko listaa`);
    // suodatin toimii yhdessä haun kanssa ja näppäimistöllä (nuolinäppäin siirtää valintaa)
    await grp.getByRole('radio', { name: 'Kaikki' }).focus();
    await listReload(page, () => page.keyboard.press('ArrowRight'));
    if (rpcArgs.at(-1).p_source !== 'native') problems.push(`johku-${name}: nuolinäppäin ei vaihtanut suodatinta (Uudet)`);
    await listReload(page, () => grp.getByRole('radio', { name: 'Kaikki' }).check());
    // --- tunnisteen väri: hiekka + tummanvihreä, ei sinistä, kontrasti ≥ 4,5:1, ei pelkkä väri (teksti) ---
    const col = await page.evaluate(() => {
      const el = document.querySelector('#view .badge.src-johku'); const cs = getComputedStyle(el);
      const rgb = (c) => (c.match(/[\d.]+/g) || []).slice(0, 3).map(Number);
      const lum = (c) => { const [r, g, b] = rgb(c).map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
      const [x, y] = [lum(cs.color), lum(cs.backgroundColor)].sort((m, n) => n - m);
      return { fg: cs.color, bg: cs.backgroundColor, border: cs.borderTopColor, ratio: (x + 0.05) / (y + 0.05), text: el.textContent, size: el.getBoundingClientRect().height };
    });
    const notBlue = (c) => { const [r, g, b] = (c.match(/[\d.]+/g) || []).map(Number); return !(b > r + 8 && b >= g); };
    if (col.text !== 'Johku' || col.ratio < 4.5 || ![col.fg, col.bg, col.border].every(notBlue)) problems.push(`johku-${name}: tunnisteen ulkoasu: ${JSON.stringify(col)}`);
    // --- päivänäkymä: tunniste Johku-varauksella, ei natiivilla ---
    await page.evaluate((m) => { location.hash = `#/?d=${m}`; }, nextMon);
    await page.waitForSelector('.session .reslist .badge.src-johku');
    const dayJ = await page.locator('.resrow:has(.badge.src-johku)').count(), dayN = await page.locator('.resrow:not(:has(.badge.src-johku))').count();
    if (dayJ < 1 || dayN < 1) problems.push(`johku-${name}: päivänäkymässä pitää olla sekä Johku- (${dayJ}) että uusia varauksia (${dayN})`);
    await page.locator('.resrow:has(.badge.src-johku)').first().evaluate((el) => el.scrollIntoView({ block: 'center' }));
    await page.waitForTimeout(200);
    await shot(page, `admin-${name}-23-paivanakyma-johku.png`, false);
    // --- varauksen tiedot: Johku-tunnus; uudella varauksella ei ---
    await page.locator('.resrow:has(.badge.src-johku) button.link').first().click();
    await page.waitForSelector('dialog[open] .kv');
    const dj = await page.locator('dialog[open]').innerText();
    if (!/Lähde\s*Johku/.test(dj) || !/Johku-tunnus\s*DEMO-R-\d+/.test(dj)) problems.push(`johku-${name}: Johku-varauksen tiedoissa pitää olla Lähde: Johku ja Johku-tunnus: ${dj.slice(0, 200).replace(/\n/g, ' | ')}`);
    await shot(page, `admin-${name}-24-varauksen-tiedot-johku.png`, false);
    await page.keyboard.press('Escape');
    await page.locator('.resrow:not(:has(.badge.src-johku)) button.link').first().click();
    await page.waitForSelector('dialog[open] .kv');
    if (/Johku/.test(await page.locator('dialog[open]').innerText())) problems.push(`johku-${name}: uuden varauksen tiedoissa ei saa olla Johku-tunnistetta`);
    await page.keyboard.press('Escape');
    // varauslistalta avattu Johku-varaus näyttää myös tunnuksen
    await page.evaluate(() => { location.hash = '#/varaukset'; });
    await page.waitForSelector('#view .listrow .badge.src-johku');
    await page.locator('#view .listrow:has(.badge.src-johku)').first().click();
    await page.waitForSelector('dialog[open] .kv');
    if (!/Johku-tunnus\s*DEMO-R-\d+/.test(await page.locator('dialog[open]').innerText())) problems.push(`johku-${name}: varauslistalta avatun Johku-varauksen tiedoista puuttuu Johku-tunnus`);
    await page.keyboard.press('Escape');
    await ctx.close();
  }
  // --- ei vaakavieritystä (360/390/430/1280) varauslistassa, päivänäkymässä ja varauksen tiedoissa ---
  for (const w of [360, 390, 430, 1280]) {
    const ctx = await browser.newContext({ viewport: { width: w, height: 800 }, isMobile: w < 700, hasTouch: w < 700, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
    const page = await ctx.newPage(); watch(page, `johku-w${w}`);
    await login(page);
    await page.evaluate(() => { location.hash = '#/varaukset'; });
    await page.waitForSelector('#view .listrow .badge.src-johku');
    let o = await overflow(page); if (o.page > 0) problems.push(`johku-w${w}: varauslista vaakavierittyy (${o.page}px)`);
    await page.getByRole('group', { name: 'Lähde' }).getByRole('radio', { name: 'Johku' }).check();
    await page.waitForTimeout(400);
    o = await overflow(page); if (o.page > 0) problems.push(`johku-w${w}: suodatettu varauslista vaakavierittyy (${o.page}px)`);
    const sz = await page.evaluate(() => [...document.querySelectorAll('.srcopt span')].map((e) => Math.round(e.getBoundingClientRect().height)));
    if (sz.some((x) => x < 44)) problems.push(`johku-w${w}: suodatinpainikkeiden kosketuskohde alle 44 px: ${sz}`);
    await page.evaluate((m) => { location.hash = `#/?d=${m}`; }, nextMon);
    await page.waitForSelector('.session .reslist .badge.src-johku');
    o = await overflow(page); if (o.page > 0) problems.push(`johku-w${w}: päivänäkymä vaakavierittyy (${o.page}px)`);
    await page.locator('.resrow:has(.badge.src-johku) button.link').first().click();
    await page.waitForSelector('dialog[open] .kv');
    o = await overflow(page); if (o.page > 0 || o.dlg > 0) problems.push(`johku-w${w}: varauksen tiedot vaakavierittyvät (sivu ${o.page}px, dialogi ${o.dlg}px)`);
    await ctx.close();
  }
  // --- defensiivisyys: vanha kanta (ei source/external_id-kenttiä) → ei tunnistetta eikä virheitä; p_source ilman migraatiota → selkeä virheilmoitus ---
  {
    const ctx = await browser.newContext({ viewport: { width: 390, height: 844, isMobile: true }, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
    const page = await ctx.newPage(); page.on('pageerror', (e) => problems.push(`johku-legacy pageerror: ${e.message}`));   // ei watch(): odotettu 404 (PGRST202) ei ole virhe
    const strip = (rows) => rows.map(({ source, external_id, ...r }) => r);
    await page.route('**/rpc/admin_list_reservations', async (route) => {
      const body = JSON.parse(route.request().postData() || '{}');
      if (body.p_source) return route.fulfill({ status: 404, contentType: 'application/json', body: JSON.stringify({ code: 'PGRST202', message: 'Could not find the function booking.admin_list_reservations(p_source) in the schema cache' }) });
      const resp = await route.fetch(); route.fulfill({ response: resp, json: strip(await resp.json()) });
    });
    await page.route('**/rpc/admin_day_view', async (route) => { const resp = await route.fetch(); const j = await resp.json(); j.reservations = strip(j.reservations || []); route.fulfill({ response: resp, json: j }); });
    await login(page);
    await page.evaluate(() => { location.hash = '#/varaukset'; });
    await page.waitForSelector('#view .listrow');
    if ((await page.locator('.badge.src-johku').count()) !== 0) problems.push('johku-legacy: ilman source-kenttää ei saa olla Johku-tunnistetta (varauslista)');
    await page.getByRole('group', { name: 'Lähde' }).getByRole('radio', { name: 'Johku' }).check();
    await page.waitForSelector('#view p.err[role=alert]');
    if (!/booking_12/.test(await page.locator('#view p.err').innerText())) problems.push('johku-legacy: puuttuvasta p_source-tuesta pitää tulla selkeä virheilmoitus (booking_12)');
    await page.getByRole('group', { name: 'Lähde' }).getByRole('radio', { name: 'Kaikki' }).check();
    await page.waitForSelector('#view .listrow');
    await page.evaluate((m) => { location.hash = `#/?d=${m}`; }, nextMon);
    await page.waitForSelector('.session .reslist');
    if ((await page.locator('.badge.src-johku').count()) !== 0) problems.push('johku-legacy: ilman source-kenttää ei saa olla Johku-tunnistetta (päivänäkymä)');
    await page.locator('.resrow button.link').first().click();
    await page.waitForSelector('dialog[open] .kv');
    if (/Johku/.test(await page.locator('dialog[open]').innerText())) problems.push('johku-legacy: ilman source-kenttää varauksen tiedoissa ei saa olla Johku-tietoja');
    await ctx.close();
  }
}
// ---------- HALLINTA: varauslistan Ajanjakso-pikavalinta (Kaikki ajat / Tulevat / Menneet / Tämä kuukausi / Oma ajanjakso) + varauskortin asettelu ----------
if (process.env.ONLY !== 'shop') {
  const login = async (page) => { await page.goto(`${BASE}/admin/`); await page.fill('#email', 'admin@demo.local'); await page.fill('#password', 'demo'); await page.click('form#login button[type=submit]'); await page.waitForSelector('#view .day-view, #view .daygrid'); };
  const rpcArgs = [];
  const reload = async (page, action) => { const [resp] = await Promise.all([page.waitForResponse((r) => r.url().includes('/rpc/admin_list_reservations')), action()]); await resp.finished(); await page.waitForTimeout(150); };
  const nRows = (page) => page.locator('#view .listrow').count();
  const resultLine = (page) => page.locator('#view > p.muted').first().innerText();
  const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
  for (const [name, vp] of [['mobile', { width: 390, height: 844, isMobile: true, hasTouch: true }], ['desktop', { width: 1280, height: 900 }]]) {
    const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, isMobile: vp.isMobile, hasTouch: vp.hasTouch, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
    const page = await ctx.newPage(); watch(page, `period-${name}`);
    page.on('request', (r) => { if (r.url().includes('/rpc/admin_list_reservations')) rpcArgs.push(JSON.parse(r.postData() || '{}')); });
    await login(page);
    await page.evaluate(() => { location.hash = '#/varaukset'; });
    await page.waitForSelector('#view .listrow');
    const grp = page.getByRole('group', { name: 'Ajanjakso' });
    const labels = ['Kaikki ajat', 'Tulevat', 'Menneet', 'Tämä kuukausi', 'Oma ajanjakso'];
    for (const l of labels) if ((await grp.getByRole('radio', { name: l }).count()) !== 1) problems.push(`period-${name}: ajanjaksovalinta puuttuu: ${l}`);
    if (!(await grp.getByRole('radio', { name: 'Kaikki ajat' }).isChecked())) problems.push(`period-${name}: oletusvalinnan pitää olla Kaikki ajat`);
    if (rpcArgs.at(-1).p_from !== null || rpcArgs.at(-1).p_to !== null) problems.push(`period-${name}: Kaikki ajat → p_from/p_to pitää olla null: ${JSON.stringify(rpcArgs.at(-1))}`);
    if (await page.locator('.perdates').isVisible()) problems.push(`period-${name}: Alkaen/Päättyen-kenttien ei pitäisi näkyä ennen Oma ajanjakso -valintaa`);
    const nAll = await nRows(page);
    if (!/^\d+ \/ \d+ varausta · Kaikki ajat$/.test(await resultLine(page))) problems.push(`period-${name}: tulosrivi väärä: ${await resultLine(page)}`);
    await shot(page, `admin-${name}-30-varauslista-kaikki-ajat.png`, false);
    // Tulevat / Menneet / Tämä kuukausi → p_from/p_to
    await reload(page, () => grp.getByRole('radio', { name: 'Tulevat' }).check());
    let a = rpcArgs.at(-1); const nUp = await nRows(page);
    if (!a.p_from || a.p_to !== null) problems.push(`period-${name}: Tulevat → p_from asetettu, p_to null odotettiin: ${JSON.stringify(a)}`);
    await reload(page, () => grp.getByRole('radio', { name: 'Menneet' }).check());
    a = rpcArgs.at(-1); const nPast = await nRows(page);
    if (a.p_from !== null || !a.p_to) problems.push(`period-${name}: Menneet → p_from null, p_to asetettu odotettiin: ${JSON.stringify(a)}`);
    if (nUp + nPast !== nAll) problems.push(`period-${name}: Tulevat (${nUp}) + Menneet (${nPast}) pitää olla = Kaikki ajat (${nAll})`);
    await reload(page, () => grp.getByRole('radio', { name: 'Tämä kuukausi' }).check());
    a = rpcArgs.at(-1);
    const d1 = new Date(a.p_from), d2 = new Date(a.p_to);
    if (!a.p_from || !a.p_to || d2 - d1 < 27 * 864e5 || d2 - d1 > 32 * 864e5 || !/^Tämä kuukausi$/.test((await resultLine(page)).split(' · ')[1])) problems.push(`period-${name}: Tämä kuukausi → välin pitää olla 28–31 pv: ${JSON.stringify(a)}`);
    // Oma ajanjakso: kentät näkyvät vain valittaessa
    await reload(page, () => grp.getByRole('radio', { name: 'Oma ajanjakso' }).check());
    if (!(await page.locator('.perdates').isVisible())) problems.push(`period-${name}: Oma ajanjakso → Alkaen/Päättyen-kenttien pitää näkyä`);
    if (!(await page.getByLabel('Alkaen').isVisible()) || !(await page.getByLabel('Päättyen').isVisible())) problems.push(`period-${name}: Alkaen/Päättyen-kentät puuttuvat`);
    await page.evaluate(() => { document.querySelector('.perdates').scrollIntoView({ block: 'center' }); });
    await shot(page, `admin-${name}-31-oma-ajanjakso-auki.png`, false);
    await reload(page, () => page.getByLabel('Alkaen').fill('2000-01-01'));
    await reload(page, () => page.getByLabel('Päättyen').fill('2099-12-31'));
    if ((await nRows(page)) !== nAll || !/ · 1\.1\.2000–31\.12\.2099$/.test(await resultLine(page))) problems.push(`period-${name}: Oma ajanjakso 2000–2099 pitää näyttää kaikki (${await nRows(page)} / ${nAll}) ja ajanjakso tulosrivillä: ${await resultLine(page)}`);
    await reload(page, () => page.getByLabel('Alkaen').fill(`${today.slice(0, 4)}-${today.slice(5, 7)}-01`));
    await reload(page, () => page.getByLabel('Alkaen').fill('2099-01-01'));
    if ((await nRows(page)) !== 0) problems.push(`period-${name}: Oma ajanjakso 2099→ ei pitäisi löytyä varauksia`);
    await reload(page, () => page.getByLabel('Alkaen').fill(''));
    await reload(page, () => page.getByLabel('Päättyen').fill(''));
    if ((await nRows(page)) !== nAll || rpcArgs.at(-1).p_from !== null || rpcArgs.at(-1).p_to !== null) problems.push('period-' + name + ': tyhjät päivämääräkentät → ei rajausta (p_from/p_to null)');
    // paluu Kaikki ajat piilottaa kentät; näppäimistö: nuoli vaihtaa valintaa
    await reload(page, () => grp.getByRole('radio', { name: 'Kaikki ajat' }).check());
    if (await page.locator('.perdates').isVisible()) problems.push(`period-${name}: Kaikki ajat → päivämääräkenttien pitää piiloutua`);
    await grp.getByRole('radio', { name: 'Kaikki ajat' }).focus();
    await reload(page, () => page.keyboard.press('ArrowRight'));
    if (!(await grp.getByRole('radio', { name: 'Tulevat' }).isChecked()) || !rpcArgs.at(-1).p_from) problems.push(`period-${name}: nuolinäppäin ei vaihtanut ajanjaksoa`);
    // yhdistelmä: ajanjakso + lähde
    await reload(page, () => grp.getByRole('radio', { name: 'Kaikki ajat' }).check());
    await reload(page, () => page.getByRole('group', { name: 'Lähde' }).getByRole('radio', { name: 'Johku' }).check());
    if (rpcArgs.at(-1).p_source !== 'johku' || rpcArgs.at(-1).p_from !== null) problems.push(`period-${name}: lähde + ajanjakso yhdessä: ${JSON.stringify(rpcArgs.at(-1))}`);
    await reload(page, () => page.getByRole('group', { name: 'Lähde' }).getByRole('radio', { name: 'Kaikki' }).check());
    // kortin asettelu: tilausnumero oikeaan yläkulmaan (aikarivin kanssa), hinta oikeaan alakulmaan, merkit vasempaan alakulmaan, nimi + tuote keskellä
    const cards = await page.evaluate(() => [...document.querySelectorAll('#view .rescard')].map((c) => {
      const r = (s) => { const b = c.querySelector(s).getBoundingClientRect(); return { l: b.left, r: b.right, t: b.top, b: b.bottom }; };
      const cb = c.getBoundingClientRect(); const cs = getComputedStyle(c);
      return { card: { l: cb.left, r: cb.right, t: cb.top, b: cb.bottom }, pad: [parseFloat(cs.paddingLeft), parseFloat(cs.paddingRight), parseFloat(cs.paddingTop), parseFloat(cs.paddingBottom)], when: r('.rc-when'), no: r('.rc-no'), what: r('.rc-what'), badges: r('.rc-badges'), price: r('.rc-price'), noText: c.querySelector('.rc-no').textContent, priceText: c.querySelector('.rc-price').textContent };
    }));
    if (!cards.length) problems.push(`period-${name}: varauskortteja ei löytynyt`);
    cards.forEach((k, i) => {
      const tag = `period-${name} kortti ${i}`;
      if (!/^#\d+$/.test(k.noText) || !/€/.test(k.priceText)) problems.push(`${tag}: tilausnumero/hinta puuttuu (${k.noText} / ${k.priceText})`);
      if (Math.abs(k.no.r - (k.card.r - k.pad[1])) > 2 || Math.abs(k.no.t - k.when.t) > 8 || k.no.t > k.card.t + k.pad[2] + 10) problems.push(`${tag}: tilausnumero ei ole oikeassa yläkulmassa aikarivillä`);
      if (Math.abs(k.price.r - (k.card.r - k.pad[1])) > 2 || Math.abs(k.price.b - (k.card.b - k.pad[3])) > 6) problems.push(`${tag}: hinta ei ole oikeassa alakulmassa`);
      if (k.badges.l > k.card.l + k.pad[0] + 2 || k.badges.r > k.price.l + 0.5 && k.badges.b > k.price.t + 1) problems.push(`${tag}: merkit eivät ole vasemmassa alakulmassa tai menevät hinnan päälle`);
      if (!(k.what.t >= k.when.b - 1 && k.what.b <= k.badges.t + 1)) problems.push(`${tag}: nimi/tuote ei ole aikarivin ja merkkien välissä`);
      if (k.no.l < k.when.r - 0.5) problems.push(`${tag}: tilausnumero menee ajan päälle`);
    });
    await page.locator('#view .rescard').nth(2).evaluate((el) => el.scrollIntoView({ block: 'center' }));
    await page.waitForTimeout(150);
    await shot(page, `admin-${name}-32-varauskortit-uusi-asettelu.png`, false);
    await ctx.close();
  }
  // --- ei vaakavieritystä, kosketuskohteet ≥ 44 px ja kontrasti ≥ 4,5:1 (360/390/430/1280) ---
  for (const w of [360, 390, 430, 1280]) {
    const ctx = await browser.newContext({ viewport: { width: w, height: 800 }, isMobile: w < 700, hasTouch: w < 700, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
    const page = await ctx.newPage(); watch(page, `period-w${w}`);
    await login(page);
    await page.evaluate(() => { location.hash = '#/varaukset'; });
    await page.waitForSelector('#view .rescard');
    for (const step of ['oletus', 'oma ajanjakso']) {
      if (step === 'oma ajanjakso') { await page.getByRole('group', { name: 'Ajanjakso' }).getByRole('radio', { name: 'Oma ajanjakso' }).check(); await page.waitForTimeout(400); }
      const m = await page.evaluate(() => {
        const rgb = (c) => (c.match(/[\d.]+/g) || []).slice(0, 3).map(Number);
        const lum = (c) => { const [r, g, b] = rgb(c).map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
        const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
        const segs = [...document.querySelectorAll('.srcopt span')].map((e) => Math.round(e.getBoundingClientRect().height));
        const k = document.querySelector('#view .rescard'), bg = getComputedStyle(k).backgroundColor;
        const cr = ['.rc-no', '.rc-price', '.rc-when', '.rc-what strong'].map((s) => ratio(getComputedStyle(k.querySelector(s)).color, bg));
        const chk = document.querySelector('.srcopt input:checked + span'); const sel = ratio(getComputedStyle(chk).color, getComputedStyle(chk).backgroundColor);
        const unchk = document.querySelector('.srcopt input:not(:checked) + span'); const un = ratio(getComputedStyle(unchk).color, getComputedStyle(unchk).backgroundColor);
        return { sw: document.documentElement.scrollWidth - document.documentElement.clientWidth, segs, cr, sel, un };
      });
      if (m.sw > 0) problems.push(`period-w${w} (${step}): vaakavieritys ${m.sw}px`);
      if (m.segs.some((x) => x < 44)) problems.push(`period-w${w} (${step}): pikavalinnan kosketuskohde < 44 px: ${m.segs}`);
      if (m.cr.some((x) => x < 4.5) || m.sel < 4.5 || m.un < 4.5) problems.push(`period-w${w} (${step}): kontrasti < 4,5: ${m.cr.map((x) => x.toFixed(2))} / valittu ${m.sel.toFixed(2)} / valitsematon ${m.un.toFixed(2)}`);
    }
    const ov = await page.evaluate(() => [...document.querySelectorAll('#view .rescard')].some((c) => c.scrollWidth > c.clientWidth + 1));
    if (ov) problems.push(`period-w${w}: varauskortin sisältö ylittää kortin leveyden`);
    await ctx.close();
  }
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
