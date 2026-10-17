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
// admin_treatment_availability (booking_25) mockataan, koska funktiota ei ole vielä repon migraatioissa/paikallisessa kannassa. Palauttaa kutsulistan.
function mockAvailability(page) {
  const helIso = (d, hhmm) => { for (const off of [3, 2]) { const t = new Date(`${d}T${hhmm}:00+0${off}:00`); if (new Intl.DateTimeFormat('fi-FI', { timeZone: 'Europe/Helsinki', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(t).replace('.', ':') === hhmm) return t.toISOString(); } return null; };
  const addIso = (d, n) => new Date(new Date(`${d}T12:00:00Z`).getTime() + n * 864e5).toISOString().slice(0, 10);
  const calls = [];
  page.route('**/rpc/admin_treatment_availability', (r) => {
    const a = r.request().postDataJSON(); calls.push(a); const rows = [];
    for (let d = a.p_from; d <= a.p_to; d = addIso(d, 1)) {
      const dow = new Date(`${d}T12:00:00Z`).getUTCDay();
      const ts = [[1, 2, 3, 4].includes(dow) ? ['16:00', '17:00', '18:30'] : [0, 6].includes(dow) ? ['13:00', '13:30', '15:00'] : [], a.p_override && dow === 5 ? ['17:00', '18:00'] : []].flat();
      for (const t of ts) { const st0 = helIso(d, t); rows.push({ product_id: a.p_product_id, session_date: d, starts_at: st0, ends_at: new Date(new Date(st0).getTime() + 36e5).toISOString(), duration_minutes: 60, status: 'available', persons: a.p_persons, total: 99 + 35 * Math.max(a.p_persons - 1, 0), price_type: 'base', therapist_missing: [1, 2].includes(dow) && t === '17:00', needs_override: dow === 5 }); }
    }
    return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(rows) });
  });
  return calls;
}
const watch = (page, name) => {
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type())) problems.push(`${name} console.${m.type()}: ${m.text()}`); });
  page.on('pageerror', (e) => problems.push(`${name} pageerror: ${e.message}`));
  page.on('requestfailed', (r) => !(/\/storage\/v1\/object\/public\//.test(r.url()) && /ERR_ABORTED/.test(r.failure()?.errorText || '')) && problems.push(`${name} requestfailed: ${r.url()} ${r.failure()?.errorText}`));
  page.on('response', (r) => { if (r.status() >= 400) problems.push(`${name} HTTP ${r.status()}: ${r.url()}`); });
  mockAvailability(page);
};
// v15b: hero-bannerin tekstin kontrasti kuvan päällä: piilotetaan teksti, kuvataan hero ja haetaan kirkkain kohta tekstialueen takaa (huonoin tapaus) → valkoisen tekstin kontrasti
async function heroContrast(page) {
  await page.evaluate(() => window.scrollTo(0, 0));
  // tekstilaatikot dokumentin koordinaateissa → kuvataan vain ne (teksti piilotettuna): huonoin tapaus = kirkkain pikseli tekstin takana
  const r = await page.evaluate(() => { const b = [...document.querySelectorAll('main .hero.page h1, main .hero.page .in p')].map((e) => e.getBoundingClientRect()); const x0 = Math.min(...b.map((q) => q.left)), y0 = Math.min(...b.map((q) => q.top)); return { x: Math.max(0, x0), y: y0 + scrollY, w: Math.max(...b.map((q) => q.right)) - Math.max(0, x0), h: Math.max(...b.map((q) => q.bottom)) - y0 }; });
  await page.addStyleTag({ content: '.hero.page h1,.hero.page .in p{visibility:hidden!important;text-shadow:none!important}' });
  const png = (await page.screenshot({ fullPage: true, clip: { x: r.x, y: r.y, width: r.w, height: r.h } })).toString('base64');
  const worst = await page.evaluate(async (b64) => {
    const im = new Image(); im.src = `data:image/png;base64,${b64}`; await im.decode();
    const cv = document.createElement('canvas'); cv.width = im.width; cv.height = im.height; const c = cv.getContext('2d'); c.drawImage(im, 0, 0);
    const d = c.getImageData(0, 0, cv.width, cv.height).data; let max = 0;
    const lin = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; };
    for (let i = 0; i < d.length; i += 4) max = Math.max(max, 0.2126 * lin(d[i]) + 0.7152 * lin(d[i + 1]) + 0.0722 * lin(d[i + 2]));
    return max;
  }, png);
  await page.addStyleTag({ content: '.hero.page h1,.hero.page .in p{visibility:visible!important}' });
  return +((1.05) / (worst + 0.05)).toFixed(2);   // valkoinen teksti (L=1; p-teksti #f3ece2 on hieman tummempi) vs kirkkain taustapikseli
}
const shot = async (page, file, full = true) => {   // ilmoitus (#toast) ei saa peittää kuvaa: odota että katoaa, piilota vielä varmuudeksi kuvan ajaksi
  await page.waitForFunction(() => !document.querySelector('#toast.show'), null, { timeout: 4000 }).catch(() => {});
  await page.evaluate(() => { document.getElementById('toast')?.style.setProperty('display', 'none'); });
  try { return await page.screenshot({ path: join(OUT, file), fullPage: full }); } finally { await page.evaluate(() => { document.getElementById('toast')?.style.removeProperty('display'); }).catch(() => {}); }
};

// ---------- KAUPPA ----------
if (process.env.ONLY !== 'admin') for (const [name, vp] of [['mobile', { width: 390, height: 844, deviceScaleFactor: 1, isMobile: true, hasTouch: true }], ['desktop', { width: 1280, height: 900 }]]) {
  const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, deviceScaleFactor: vp.deviceScaleFactor || 1, isMobile: vp.isMobile, hasTouch: vp.hasTouch, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const page = await ctx.newPage(); watch(page, `shop-${name}`);
  await page.goto(`${BASE}/varaa/`);
  await page.waitForSelector('.bk-cards');
  // v15b: tuotekuvat tuotelistassa (demo: 4 tuotteella kuva, muilla ei) – ladattu, lazy, mitat, alt, ei vaakavieritystä
  await page.waitForSelector('.bk-card .card-img img');
  await page.evaluate(async () => { for (const i of document.querySelectorAll('.bk-card img')) { i.scrollIntoView(); if (!i.complete) await new Promise((r) => { i.onload = i.onerror = r; }); } window.scrollTo(0, 0); });   // lazy: ladataan vierittämällä
  const listImgs = await page.locator('.bk-card .card-img img').evaluateAll((els) => els.map((e) => ({ ok: e.complete && e.naturalWidth > 0, lazy: e.loading, w: e.getAttribute('width'), h: e.getAttribute('height'), alt: e.alt, ratio: +(e.parentElement.getBoundingClientRect().width / e.parentElement.getBoundingClientRect().height).toFixed(2) })));
  if (listImgs.length !== 4) problems.push(`shop-${name}: tuotelistassa pitäisi olla 4 tuotekuvaa, nyt ${listImgs.length}`);
  if (listImgs.some((i) => !i.ok || i.lazy !== 'lazy' || !i.w || !i.h || !i.alt || Math.abs(i.ratio - 1.5) > 0.02)) problems.push(`shop-${name}: tuotekuvien lataus/lazy/mitat/alt/kuvasuhde virheellinen: ${JSON.stringify(listImgs)}`);
  if (!listImgs.some((i) => i.alt === 'Savusaunan lauteet ja kiuas')) problems.push(`shop-${name}: ylläpidon alt-teksti puuttuu kuvasta`);
  if ((await page.locator('.bk-card').count()) <= listImgs.length) problems.push(`shop-${name}: listalla pitää olla myös kuvattomia tuotteita (kuvaton tila)`);
  if (await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)) problems.push(`shop-${name}: tuotelista vierittyy vaakasuunnassa`);
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
    // v15b: kuvalliset tuotekortit näyttävät pikkukuvan (koriste, nimi on tekstinä), kuvattomat eivät jätä tyhjää tilaa
    const thumbs = await page.locator('.bk-pc-head .pc-img img').evaluateAll((els) => els.map((e) => ({ ok: e.complete && e.naturalWidth > 0, alt: e.alt, w: e.parentElement.getBoundingClientRect().width, h: e.parentElement.getBoundingClientRect().height })));
    if (!thumbs.length || thumbs.some((i) => !i.ok || i.alt !== '' || Math.abs(i.w - i.h) > 1 || i.w < 60)) problems.push(`shop-${name}-${lang}: päivänäkymän tuotekorttien kuvat virheelliset: ${JSON.stringify(thumbs)}`);
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
  // v15b: tuotesivun hero = tuotteen kuva taustana + otsikko (h1) = tuotteen nimi + tiivis kuvaus; pitkä kuvaus sisältöosassa
  const hero = await page.evaluate(() => { const el = document.querySelector('main .hero.page'), im = el.querySelector('picture img'); return {
    cls: el.className, h1: [...document.querySelectorAll('h1')].map((x) => x.textContent), sub: el.querySelector('.in p')?.textContent || '', ok: im.complete && im.naturalWidth > 0, fit: getComputedStyle(im).objectFit, alt: im.alt,
    heroH: el.getBoundingClientRect().height, long: document.querySelector('.bk-prod .bk-desc')?.textContent || '', dupH2: [...document.querySelectorAll('#booking-app h2')].map((x) => x.textContent), src: im.src }; });
  if (!/has-prod/.test(hero.cls) || !/product-images|storage/.test(hero.src) || !hero.ok || hero.fit !== 'cover') problems.push(`shop-${name}: tuotesivun heron pitää käyttää tuotteen kuvaa (cover): ${JSON.stringify(hero)}`);
  if (hero.h1.length !== 1 || !/^Yleinen vuoro/.test(hero.h1[0])) problems.push(`shop-${name}: heron h1 pitää olla tuotteen nimi (ja vain yksi h1): ${hero.h1}`);
  if (!hero.sub || hero.sub.length > 135 || hero.sub === hero.long || !hero.long.startsWith(hero.sub.replace(/…$/, ''))) problems.push(`shop-${name}: heron alla pitää olla tiivis kuvaus (ei koko pitkää): "${hero.sub}"`);
  if (hero.dupH2.some((x) => x === hero.h1[0])) problems.push(`shop-${name}: tuotteen nimi toistuu h2-otsikkona heron h1:n lisäksi`);
  if (hero.alt !== 'Savusaunan lauteet ja kiuas') problems.push(`shop-${name}: heron kuvan alt-teksti väärin: "${hero.alt}"`);
  const hc = await heroContrast(page);
  if (hc < 4.5) problems.push(`shop-${name}: heron tekstin kontrasti kuvan päällä ${hc}:1 < 4.5:1`);
  console.log(`shop-${name}: hero-kontrasti (huonoin kohta) ${hc}:1, korkeus ${Math.round(hero.heroH)} px`);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: join(OUT, `shop-${name}-2b-tuotesivu-hero.png`), fullPage: false });
  await shot(page, `shop-${name}-2-kalenteri-vuorot.png`);
  // kuvaton tuote (hiljainen sauna): oletushero-kuva säilyy, otsikko silti tuotteen nimi
  await page.goto(`${BASE}/varaa/#/tuote/hiljainen-sauna`);
  await page.waitForSelector('.bk-prod');
  const hn = await page.evaluate(() => ({ cls: document.querySelector('main .hero.page').className, h1: document.querySelector('main .hero.page h1').textContent, src: document.querySelector('main .hero.page picture img').getAttribute('src') }));
  if (/has-prod/.test(hn.cls) || !/ovi-kaiverrus/.test(hn.src) || !/^Hiljainen sauna/.test(hn.h1)) problems.push(`shop-${name}: kuvattomalla tuotteella pitää säilyä oletushero ja otsikko = tuotteen nimi: ${JSON.stringify(hn)}`);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: join(OUT, `shop-${name}-2c-tuotesivu-ilman-kuvaa.png`), fullPage: false });
  await page.goto(`${BASE}/varaa/`);
  await page.waitForSelector('.bk-cards');
  if ((await page.locator('main .hero.page h1').innerText()).trim() !== 'Varaa saunaelämys' || (await page.locator('main .hero.page.has-prod').count()) !== 0) problems.push(`shop-${name}: tuotelistan heron pitää olla oletus (Varaa saunaelämys)`);
  // layout-hyppy (CLS) suoralla latauksella tuotesivulle
  const cp = await ctx.newPage();
  await cp.addInitScript(() => { window.__cls = 0; new PerformanceObserver((l) => { for (const e of l.getEntries()) if (!e.hadRecentInput) window.__cls += e.value; }).observe({ type: 'layout-shift', buffered: true }); });
  await cp.goto(`${BASE}/varaa/#/tuote/yleinensauna`);
  await cp.waitForSelector('.bk-prod .bk-grid button.bk-cell');
  await cp.waitForTimeout(800);
  const cls = await cp.evaluate(() => window.__cls);
  console.log(`shop-${name}: CLS tuotesivun suoralla latauksella ${cls.toFixed(3)}`);
  if (cls > 0.1) problems.push(`shop-${name}: tuotesivun layout-hyppy liian suuri (CLS ${cls.toFixed(3)} > 0.1)`);
  await cp.close();
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
  if (!(await page.locator('main .hero.page.has-prod picture img').evaluate((e) => e.complete && e.naturalWidth > 0)) || !/^Yleinen vuoro/.test(await page.locator('main .hero.page h1').innerText())) problems.push(`shop-${name}: varauslomakkeen heron pitää näyttää tuotteen kuva ja nimi`);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: join(OUT, `shop-${name}-4c-lomake-hero.png`), fullPage: false });
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
  {   // yläpalkin haalea logo (korvaa tekstin "Sauna hallinta"): latautuu, 34–36 px korkea, alt-teksti, kontrasti ≥ 4,5:1 tummanvihreää vasten, ei vaakavieritystä (myös 360 px)
    const img = page.locator('header.top .brand img');
    await img.waitFor();
    const m = await img.evaluate(async (el) => {
      const svg = await (await fetch(el.src)).text(), fill = (svg.match(/fill="(#[0-9a-fA-F]{6})"/) || [])[1];
      const lum = (hex) => { const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4)); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
      const bg = getComputedStyle(document.querySelector('header.top')).backgroundColor.match(/\d+/g).slice(0, 3).map(Number), bgHex = '#' + bg.map((v) => v.toString(16).padStart(2, '0')).join('');
      const [a, b] = [lum(fill), lum(bgHex)].sort((x, y) => y - x);
      return { ok: el.complete && el.naturalWidth > 0, h: Math.round(el.getBoundingClientRect().height), alt: el.alt, fill, ratio: (a + 0.05) / (b + 0.05), brandText: document.querySelector('header.top .brand').textContent.trim(), sw: document.documentElement.scrollWidth - document.documentElement.clientWidth, tap: Math.round(el.closest('a').getBoundingClientRect().height) };
    });
    if (!m.ok) problems.push(`logo-${name}: yläpalkin kuva ei latautunut`);
    if (m.h < 34 || m.h > 36) problems.push(`logo-${name}: kuvan korkeus ${m.h} px (odotettiin 34–36)`);
    if (m.alt !== 'Sauna hallinta' || m.brandText) problems.push(`logo-${name}: alt-teksti "${m.alt}" / näkyvää tekstiä "${m.brandText}"`);
    if (m.ratio < 4.5) problems.push(`logo-${name}: kontrasti ${m.ratio.toFixed(2)} < 4,5 (${m.fill})`);
    if (m.sw > 0 || m.tap < 44) problems.push(`logo-${name}: vaakavieritys ${m.sw} px tai linkin korkeus ${m.tap} < 44`);
    if (name === 'mobile') { await page.setViewportSize({ width: 360, height: 800 }); if ((await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)) > 0) problems.push('logo-360: vaakavieritys 360 px leveydellä'); await page.setViewportSize({ width: 390, height: 844 }); }
    await page.locator('header.top').screenshot({ path: join(OUT, `admin-${name}-80-ylapalkki-logo.png`) });
  }
  // päivänäkymä päivälle, jolla on demovarauksia (seuraava maanantai)
  const mon = (() => { const d = new Date(); d.setUTCDate(d.getUTCDate() + ((8 - d.getUTCDay()) % 7 || 7)); return d.toISOString().slice(0, 10); })();
  await page.evaluate((m) => { location.hash = `#/?d=${m}`; }, mon);
  await page.waitForSelector('.session .reslist');
  await page.waitForTimeout(300);
  await shot(page, `admin-${name}-1-paivanakyma.png`, false);
  // lisäpalvelut päivänäkymässä: "Valmistelu"-kortti + varauskohtaiset merkinnät + yritysasiakkaan merkintä
  await page.waitForSelector('[data-testid=prepcard]');
  if ((await page.locator('[data-testid=prepcard] .prep-tile').count()) < 3) problems.push(`admin-${name}: Valmistelu-kortilla pitää olla luvut (henkilöt + lisäpalvelut)`);
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
  // tuotekuva (v15b): virheelliset tiedostot hylätään, lataus + alt + tallennus, näkyy kaupassa, poisto palauttaa kuvattoman tilan
  const rowH = page.locator('#view .listrow:has-text("Hiljainen sauna")');
  await rowH.click();
  await page.waitForSelector('dialog[open] .imgprev');
  if ((await page.locator('dialog[open] .imgprev img').count()) !== 0 || (await page.locator('dialog[open] button:has-text("Poista kuva")').isEnabled())) problems.push(`admin-${name}: hiljaisella saunalla ei pitäisi olla kuvaa ennen latausta`);
  const fin = page.locator('dialog[open] input[type=file]'), stat = page.locator('dialog[open] #img-box-4 [role=status]');
  await fin.setInputFiles({ name: 'x.gif', mimeType: 'image/gif', buffer: Buffer.from('GIF89a') });
  await page.waitForFunction(() => /Sallitut kuvatyypit/.test(document.querySelector('dialog[open] [role=status]').textContent));
  await fin.setInputFiles({ name: 'rikki.png', mimeType: 'image/png', buffer: Buffer.from('tämä ei ole kuva') });
  await page.waitForFunction(() => /ei voi lukea/.test(document.querySelector('dialog[open] [role=status]').textContent));
  await fin.setInputFiles({ name: 'iso.png', mimeType: 'image/png', buffer: Buffer.alloc(16 * 1048576) });
  await page.waitForFunction(() => /liian suuri/.test(document.querySelector('dialog[open] [role=status]').textContent));
  if (await page.locator('dialog[open] button:has-text("Tallenna kuva")').isEnabled()) problems.push(`admin-${name}: virheellisillä tiedostoilla Tallenna kuva ei saa aueta`);
  await fin.setInputFiles(join(dirname(fileURLToPath(import.meta.url)), '../../public/img/og-palju.jpg'));
  await page.waitForSelector('dialog[open] .imgprev img');
  await page.waitForFunction(() => /Valittu/.test(document.querySelector('dialog[open] [role=status]').textContent));
  await page.fill('dialog[open] input[name=image_alt]', 'Hiljaisen saunan tunnelma');
  await page.locator('dialog[open] .imgprev').scrollIntoViewIfNeeded();
  await shot(page, `admin-${name}-4d-tuotekuva-muokkaus.png`, false);
  await page.click('dialog[open] button:has-text("Tallenna kuva")');
  await page.waitForSelector('#toast.show:has-text("Kuva tallennettu")');
  await page.waitForSelector('#view .listrow:has-text("Hiljainen sauna") img.pthumb');
  await shot(page, `admin-${name}-4e-tuotelista-kuvilla.png`, false);
  const sp = await ctx.newPage(); watch(sp, `admin-${name}-shop`);
  await sp.goto(`${BASE}/varaa/#/tuote/hiljainen-sauna`);
  await sp.waitForSelector('main .hero.page.has-prod picture img');
  await sp.evaluate(() => Promise.all([...document.images].map((i) => (i.complete ? 0 : new Promise((r) => { i.onload = i.onerror = r; })))));
  if (!(await sp.locator('main .hero.page.has-prod picture img').evaluate((e) => e.complete && e.naturalWidth > 0 && e.alt === 'Hiljaisen saunan tunnelma'))) problems.push(`admin-${name}: ladattu kuva ei näy kaupan tuotesivun herossa oikealla alt-tekstillä`);
  await sp.close();
  await rowH.click(); await page.waitForSelector('dialog[open] .imgprev img');
  page.once('dialog', (d) => d.accept());
  await page.click('dialog[open] button:has-text("Poista kuva")');
  await page.waitForSelector('#toast.show:has-text("Kuva poistettu")');
  await page.waitForFunction(() => !document.querySelector('#view .listrow img.pthumb') || ![...document.querySelectorAll('#view .listrow')].find((r) => /Hiljainen sauna/.test(r.textContent))?.querySelector('img.pthumb'));
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
// ---------- HALLINTA: resurssivaraukset (migraatio 17): tila/legit/ylitys näkyviin, Tarkista-lista, Rauni↔Lovi-siirto, Resurssivaraus + Vanha varaus, virheilmoitukset ----------
// Vaatii demosiemenen resurssivaraukset (dev/seed_demo.sql: hoitoja la, vanha varaus su, ylitys tiistaina mon+15). Testi siivoaa omat varauksensa (peruu) ja palauttaa siirron.
if (process.env.ONLY !== 'shop') {
  const loginAs = async (page, email = 'admin@demo.local') => { await page.goto(`${BASE}/admin/`); await page.fill('#email', email); await page.fill('#password', 'demo'); await page.click('form#login button[type=submit]'); await page.waitForSelector('#nav a'); await page.waitForTimeout(300); };
  const d0 = new Date(Date.now() + 3 * 864e5); const sat = (() => { const d = new Date(d0); d.setUTCDate(d.getUTCDate() + ((6 - d.getUTCDay() + 7) % 7)); return d.toISOString().slice(0, 10); })();
  const monNext = (() => { const d = new Date(); d.setUTCDate(d.getUTCDate() + ((8 - d.getUTCDay()) % 7 || 7)); return d; })();
  const iso = (d, n = 0) => { const x = new Date(d); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };
  const tueFree = iso(monNext, 1);   // tiistai: demossa ei saunottajavuoroja
  const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  for (const [name, vp] of [['mobile', { width: 390, height: 844, isMobile: true, hasTouch: true }], ['desktop', { width: 1280, height: 900 }]]) {
    const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, isMobile: vp.isMobile, hasTouch: vp.hasTouch, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
    const page = await ctx.newPage();   // odotettu 400 (BK001) resurssivarauksen virhetestissä ei ole virhe; muut virheet ovat
    page.on('console', (m) => { if (['error', 'warning'].includes(m.type()) && !/Failed to load resource.*400/.test(m.text())) problems.push(`resurssi-${name} console.${m.type()}: ${m.text()}`); });
    page.on('pageerror', (e) => problems.push(`resurssi-${name} pageerror: ${e.message}`));
    page.on('response', (r) => { if (r.status() >= 400 && !/admin_create_resource_booking/.test(r.url())) problems.push(`resurssi-${name} HTTP ${r.status()}: ${r.url()}`); });
    page.on('dialog', (dlg) => dlg.accept()); mockAvailability(page);
    await loginAs(page);
    // --- varauslista: pikatoiminnot + tila-/elinkaarimerkit ---
    await page.evaluate(() => { location.hash = '#/varaukset'; });
    await page.waitForSelector('#view .rescard');
    if ((await page.locator('#view .pageactions a:has-text("Vanha varaus")').count()) !== 1 || (await page.locator('#view .pageactions a:has-text("Tarkista")').count()) !== 1) problems.push(`resurssi-${name}: Varaukset-sivulla pitää olla Vanha varaus- ja Tarkista-painike`);
    await page.waitForSelector('#view .pageactions .badge:not([hidden])', { timeout: 5000 }).catch(() => problems.push(`resurssi-${name}: Tarkista-painikkeen laskuri puuttuu (demossa on ylitys)`));
    if ((await page.locator('#view .rescard .badge.space:has-text("Rauni")').count()) < 1 || (await page.locator('#view .rescard .badge.lc-old').count()) < 1) problems.push(`resurssi-${name}: varauslistassa pitää näkyä tilamerkki (Rauni) ja Vanha tuote -merkki`);
    await shot(page, `admin-${name}-50-varaukset-resurssimerkit.png`, false);
    // --- päivänäkymä: tila, legit ---
    await page.evaluate((d) => { location.hash = `#/?d=${d}`; }, sat);
    await page.waitForSelector('#view .resrow');
    const dayTxt = await page.locator('#view').innerText();
    if (!/Hoitosauna Rauni/.test(dayTxt) || (await page.locator('#view .legs .leg-therapist').count()) < 1 || !/Saunottaja \(yleinen\)/.test(dayTxt)) problems.push(`resurssi-${name}: päivänäkymässä pitää näkyä Rauni ja saunottajaleg (Saunottaja (yleinen))`);
    await shot(page, `admin-${name}-51-paivanakyma-legit.png`, true);
    // --- varauksen tiedot: Resurssit-laatikko + siirto Rauni → Lovi → takaisin ---
    await page.evaluate(() => { const b = [...document.querySelectorAll('#view .resrow button.link')].find((x) => x.querySelector(':scope > strong')?.nextSibling?.textContent.trim() === '· 1 hlö' && x.closest('.resrow').querySelector('.badge.space')); b.click(); });   // 1 hlö: Lovi-siirto mahdollinen
    await page.waitForSelector('dialog[open] .resbox .kv');
    const dlgTxt = await page.locator('dialog[open]').innerText();
    if (!/Resurssit/.test(dlgTxt) || !/Hoitosauna Rauni/.test(dlgTxt) || (await page.locator('dialog[open] .resbox .leg').count()) < 1) problems.push(`resurssi-${name}: varauksen tiedoissa pitää näkyä Resurssit (tila + saunottajaleg)`);
    await shot(page, `admin-${name}-52-varauksen-tiedot-resurssit.png`, false);
    if ((await noHScroll(page)) > 0 || (await page.evaluate(() => { const d = document.querySelector('dialog[open]'); return d.scrollWidth - d.clientWidth; })) > 0) problems.push(`resurssi-${name}: vaakavieritys varauksen tiedoissa`);
    await page.fill('dialog[open] input[name=reason]', 'Testisiirto (e2e)');
    await page.locator('dialog[open] .moverow button:has-text("Siirrä tilaan")').click();
    await page.waitForSelector('dialog[open]', { state: 'detached', timeout: 8000 }).catch(() => problems.push(`resurssi-${name}: siirto Raunista Loviin ei onnistunut`));
    await page.waitForTimeout(500);
    if ((await page.locator('#view .resrow .badge.space:has-text("Lovi")').count()) !== 1) problems.push(`resurssi-${name}: siirron jälkeen yhdellä varauksella pitää olla Lovi-merkki`);
    await page.locator('#view .resrow:has(.badge.space:has-text("Lovi")) button.link').first().click();
    await page.waitForSelector('dialog[open] .moverow');
    await page.locator('dialog[open] .moverow button:has-text("Siirrä tilaan")').click();   // takaisin Rauniin
    await page.waitForSelector('dialog[open]', { state: 'detached', timeout: 8000 }).catch(() => problems.push(`resurssi-${name}: siirto takaisin Rauniin ei onnistunut`));
    // --- Tarkista-lista ---
    await page.evaluate(() => { location.hash = '#/tarkista'; });
    await page.waitForSelector('[data-testid=review-overrides]');
    const rv = await page.evaluate(() => Object.fromEntries([...document.querySelectorAll('.review-sec')].map((e) => [e.dataset.testid, e.querySelectorAll('li.resrow').length])));
    if (rv['review-overrides'] < 1 || Object.keys(rv).length !== 5) problems.push(`resurssi-${name}: Tarkista-listalla pitää olla 5 osiota (Ei saunottajaa + 4) ja ylitys demosta: ${JSON.stringify(rv)}`);
    if (!/Syy: Demo: ylitys/.test(await page.locator('[data-testid=review-overrides]').innerText())) problems.push(`resurssi-${name}: ylityksen syy puuttuu Tarkista-listalta`);
    if (!(await page.locator('#nav a[href="#/tarkista"]').count())) problems.push(`resurssi-${name}: Tarkista puuttuu valikosta`);
    await shot(page, `admin-${name}-53-tarkista.png`, true);
    // --- Uusi varaus: varaustyypin valinta (radiogroup) ---
    await page.evaluate(() => { location.hash = '#/uusi'; });
    await page.waitForSelector('[data-testid=booking-type]');
    const bt = page.getByRole('group', { name: 'Varaustyyppi' });
    if ((await bt.getByRole('radio').count()) !== 3 || !(await bt.getByRole('radio', { name: 'Vuoro' }).isChecked())) problems.push(`resurssi-${name}: Varaustyyppi: 3 vaihtoehtoa, oletuksena Vuoro`);
    await bt.getByRole('radio', { name: 'Resurssivaraus' }).check();
    await page.waitForSelector('[data-testid=resource-booking-form]');
    if (!/tyyppi=resurssi/.test(page.url())) problems.push(`resurssi-${name}: tyyppi ei URL:ssa`);
    const opts = await page.locator('select[name=product] option').allInnerTexts();
    if (!opts.some((t) => /Saunahoito/.test(t)) || opts.some((t) => /Vihtahoito|Perinnesaunotus yhdelle/.test(t))) problems.push(`resurssi-${name}: Resurssivaraus-lomakkeella vain nykyiset tuotteet (oli: ${opts.slice(0, 6)})`);
    await shot(page, `admin-${name}-54-resurssivaraus-lomake.png`, true);
    // 1) virhe ilman ylitystä: tiistaina klo 12 on hoitojen aikaikkunan (ma–pe 16–20:30, migraatio 23) ulkopuolella → suomenkielinen virheilmoitus
    await page.selectOption('select[name=product]', { label: 'Saunahoito (60 min)' });
    await page.fill('input[name=date]', tueFree); await page.fill('input[name=time]', '12:00');
    await page.fill('input[name=cname]', `Resurssi Testi ${Date.now()}`);
    await page.fill('input[name=cemail]', `resurssi-${Date.now()}@example.com`); await page.fill('input[name=cphone]', '0401112233');
    await page.click('form[data-testid=resource-booking-form] button[type=submit]');
    await page.waitForSelector('form[data-testid=resource-booking-form] .err:not([hidden])');
    const errTxt = await page.locator('form[data-testid=resource-booking-form] .err').innerText();
    if (!/aikaikkunan ulkopuolella/i.test(errTxt) || /BK001|time_window|no_therapist|therapist_closed/.test(errTxt)) problems.push(`resurssi-${name}: virheilmoituksen pitää olla suomeksi ja kertoa aikaikkunasta (oli: ${errTxt})`);
    await shot(page, `admin-${name}-55-resurssivaraus-virhe.png`, false);
    // 2) ylitys vaatii perustelun (asiakaspuolen tarkistus), sitten onnistuu
    await page.check('[data-testid=override-box] input[name=override]');
    await page.click('form[data-testid=resource-booking-form] button[type=submit]');
    if (!/Ylitys vaatii perustelun/.test(await page.locator('form[data-testid=resource-booking-form] .err').innerText())) problems.push(`resurssi-${name}: ylityksen perustelu pitää vaatia`);
    await page.fill('textarea[name=override_reason]', 'E2E-testi: sovittu erikseen');
    await shot(page, `admin-${name}-56-resurssivaraus-ylitys.png`, false);
    await page.click('form[data-testid=resource-booking-form] button[type=submit]');
    await page.waitForSelector('.ok-box');
    const okTxt = await page.locator('.ok-box').innerText();
    if (!/Varaus luotu/.test(okTxt) || !/Saunahoito/.test(okTxt)) problems.push(`resurssi-${name}: onnistumisviesti puuttuu (${okTxt})`);
    // siivous: peru luotu varaus päivänäkymästä (ylitys + Peru varaus)
    await page.evaluate((d) => { location.hash = `#/?d=${d}`; }, tueFree);
    await page.waitForSelector('#view .resrow');
    if ((await page.locator('#view .resrow .badge.ovr').count()) < 1) problems.push(`resurssi-${name}: päivänäkymässä pitää näkyä Ylitys-merkki`);
    for (let i = 0, n = await page.locator('#view .resrow:has-text("E2E"), #view .resrow:has(.badge.ovr)').count(); i < n; i++) {
      await page.locator('#view .resrow:has(.badge.ovr)').first().locator('button.link').click();
      await page.waitForSelector('dialog[open] .resbox');
      if (!/E2E-testi|Demo: ylitys/.test(await page.locator('dialog[open] .resbox').innerText())) problems.push(`resurssi-${name}: ylityksen syy puuttuu varauksen tiedoista`);
      await page.locator('dialog[open] button:has-text("Peru varaus")').click(); await page.waitForTimeout(600);
      if ((await page.locator('dialog[open]').count()) === 0 && (await page.locator('#view .resrow:has(.badge.ovr):not(.cancelled)').count()) === 0) break;
    }
    // --- Vanha varaus ---
    await page.evaluate(() => { location.hash = '#/varaukset'; });
    await page.waitForSelector('#view .pageactions');
    await page.click('#view .pageactions a:has-text("Vanha varaus")');
    await page.waitForSelector('[data-testid=old-booking-form]');
    const oopts = await page.locator('select[name=product] option').allInnerTexts();
    if (!oopts.some((t) => /Vihtahoito/.test(t)) || oopts.some((t) => /^Saunahoito \(/.test(t))) problems.push(`resurssi-${name}: Vanha varaus -lomakkeella vain vanhat tuotteet (oli: ${oopts.slice(0, 6)})`);
    await shot(page, `admin-${name}-57-vanha-varaus-lomake.png`, true);
    await page.selectOption('select[name=product]', { label: oopts.find((t) => /^Vihtahoito \(/.test(t)) });
    await page.fill('input[name=date]', tueFree); await page.fill('input[name=time]', '17:30');
    await page.fill('input[name=cname]', `Vanha Testi ${Date.now()}`);
    await page.fill('input[name=cemail]', `vanha-${Date.now()}@example.com`); await page.fill('input[name=cphone]', '0401112244');
    await page.click('form[data-testid=old-booking-form] button[type=submit]');
    await page.waitForSelector('.ok-box, form[data-testid=old-booking-form] .err:not([hidden])');
    if ((await page.locator('.ok-box').count()) !== 1) problems.push(`resurssi-${name}: vanha varaus ei onnistunut: ${await page.locator('form[data-testid=old-booking-form] .err').innerText().catch(() => '?')}`);
    await shot(page, `admin-${name}-58-vanha-varaus-luotu.png`, false);
    await page.evaluate((d) => { location.hash = `#/?d=${d}`; }, tueFree);
    await page.waitForSelector('#view .resrow');
    const mine = page.locator('#view .resrow:has-text("Vanha Testi")');
    if ((await mine.count()) < 1 || (await mine.first().locator('.badge.lc-old').count()) !== 1) problems.push(`resurssi-${name}: luotu vanha varaus ei näy päivänäkymässä Vanha tuote -merkillä`);
    await mine.first().locator('button.link').click(); await page.waitForSelector('dialog[open] .resbox');
    await page.locator('dialog[open] button:has-text("Peru varaus")').click(); await page.waitForTimeout(600);
    await ctx.close();
  }
  // --- vanha varaus väärälle (nykyiselle) tuotteelle → wrong_lifecycle suomeksi; oikeudet: staff ei näe ylitystä, manager näkee ---
  {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
    const page = await ctx.newPage(); page.on('pageerror', (e) => problems.push(`resurssi-oikeudet pageerror: ${e.message}`));
    await loginAs(page, 'staff@demo.local');
    await page.evaluate(() => { location.hash = '#/uusi?tyyppi=resurssi'; });
    await page.waitForSelector('[data-testid=resource-booking-form]');
    if ((await page.locator('[data-testid=override-box]').count()) !== 0) problems.push('resurssi-oikeudet: staff ei saa nähdä ylitysvalintaa');
    await ctx.close();
    const ctx2 = await browser.newContext({ viewport: { width: 1280, height: 900 }, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
    const p2 = await ctx2.newPage(); p2.on('pageerror', (e) => problems.push(`resurssi-oikeudet pageerror: ${e.message}`));
    await loginAs(p2, 'manager@demo.local');
    await p2.evaluate(() => { location.hash = '#/uusi?tyyppi=resurssi'; });
    await p2.waitForSelector('[data-testid=resource-booking-form]');
    if ((await p2.locator('[data-testid=override-box]').count()) !== 1) problems.push('resurssi-oikeudet: manager (bookings.override) näkee ylitysvalinnan');
    await ctx2.close();
  }
  // --- ei vaakavieritystä, kosketuskohteet ≥ 44 px ja kontrasti ≥ 4,5:1 (360/390/430/1280) ---
  for (const w of [360, 390, 430, 1280]) {
    const ctx = await browser.newContext({ viewport: { width: w, height: 800 }, isMobile: w < 700, hasTouch: w < 700, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
    const page = await ctx.newPage(); watch(page, `resurssi-w${w}`);
    await loginAs(page);
    for (const [hash, sel] of [['#/varaukset', '#view .pageactions'], [`#/?d=${sat}`, '#view .legs'], ['#/tarkista', '.review-sec'], ['#/uusi?tyyppi=resurssi', '[data-testid=resource-booking-form]'], ['#/uusi?tyyppi=vanha', '[data-testid=old-booking-form]'], ['#/uusi', '[data-testid=booking-type]']]) {
      await page.evaluate((x) => { location.hash = x; }, hash);
      await page.waitForSelector(sel); await page.waitForTimeout(300);
      const m = await page.evaluate(() => {
        const rgb = (c) => (c.match(/[\d.]+/g) || []).slice(0, 3).map(Number);
        const lum = (c) => { const [r, g, b] = rgb(c).map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
        const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
        const tap = [...document.querySelectorAll('#view .pageactions a, #view .typeset .srcopt span, #view form[data-testid] button[type=submit], #view .rv-link')].map((e) => Math.round(e.getBoundingClientRect().height)).filter((x) => x > 0);
        const bad = [...document.querySelectorAll('#view .badge, #view .legs .leg, #view .rv-link')].map((e) => ratio(getComputedStyle(e).color, (() => { let n = e; while (n && (rgb(getComputedStyle(n).backgroundColor).length < 3 || getComputedStyle(n).backgroundColor === 'rgba(0, 0, 0, 0)')) n = n.parentElement; return n ? getComputedStyle(n).backgroundColor : 'rgb(255,255,255)'; })())).filter((x) => x < 4.5);
        const blue = [...document.querySelectorAll('#view *')].some((e) => { const c = rgb(getComputedStyle(e).backgroundColor); return c.length === 3 && c[2] > c[0] + 40 && c[2] > c[1] + 40; });
        return { sw: document.documentElement.scrollWidth - document.documentElement.clientWidth, tap, bad, blue };
      });
      const tag = `resurssi-w${w} (${hash})`;
      if (m.sw > 0) problems.push(`${tag}: vaakavieritys ${m.sw}px`);
      if (w < 700 && m.tap.some((x) => x < 44)) problems.push(`${tag}: kosketuskohde < 44 px: ${m.tap}`);
      if (m.bad.length) problems.push(`${tag}: kontrasti < 4,5: ${m.bad.map((x) => x.toFixed(2))}`);
      if (m.blue) problems.push(`${tag}: sinistä taustaa`);
    }
    await ctx.close();
  }
}
// ---------- HALLINTA: kalenterisulut (migraatio 18): closure_event_id päivänäkymässä (vain luettava), Laura-sulku käsin, Kalenterisulut-näkymä, ohitus ----------
// Vaatii demosiemenen (dev/seed_demo.sql): hoidot + savusauna käytössä, tapahtumat mon+3 / +5…+20, konflikti ylitysvaraukseen mon+15, Laura-sulku mon+22. Testi palauttaa omat ohituksensa ja poistaa oman Laura-sulkunsa.
if (process.env.ONLY !== 'shop') {
  const loginAs = async (page, email = 'admin@demo.local') => { await page.goto(`${BASE}/admin/`); await page.fill('#email', email); await page.fill('#password', 'demo'); await page.click('form#login button[type=submit]'); await page.waitForSelector('#shell:not([hidden]) #nav a'); };
  const monNext = (() => { const d = new Date(); d.setUTCDate(d.getUTCDate() + ((8 - d.getUTCDay()) % 7 || 7)); return d; })();
  const iso = (d, n = 0) => { const x = new Date(d); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };
  const noHScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  const cnt = (page, sel) => page.locator(sel).count();
  for (const [name, vp] of [['mobile', { width: 390, height: 844, isMobile: true, hasTouch: true }], ['desktop', { width: 1280, height: 900 }]]) {
    const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, isMobile: vp.isMobile, hasTouch: vp.hasTouch, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
    const page = await ctx.newPage();
    page.on('console', (m) => { if (['error', 'warning'].includes(m.type()) && !/Failed to load resource.*400/.test(m.text())) problems.push(`kalenterisulut-${name} console.${m.type()}: ${m.text()}`); });
    page.on('pageerror', (e) => problems.push(`kalenterisulut-${name} pageerror: ${e.message}`));
    page.on('response', (r) => { if (r.status() >= 400 && !/admin_delete_block/.test(r.url())) problems.push(`kalenterisulut-${name} HTTP ${r.status()}: ${r.url()}`); });
    page.on('dialog', (dlg) => dlg.accept());
    await loginAs(page);
    const tag = `kalenterisulut-${name}`;
    // --- päivänäkymä: kalenterisulku vain luettava, merkki Kalenterisulku ---
    const thu = iso(monNext, 3);
    await page.evaluate((d) => { location.hash = `#/?d=${d}`; }, thu);
    await page.waitForSelector('[data-testid=day-blocks] [data-testid=calendar-block]');
    const cb = page.locator('[data-testid=calendar-block]').first();
    if (!/Kalenterisulku/.test(await cb.innerText()) || (await cb.locator('button').count()) !== 0) problems.push(`${tag}: kalenterisululla pitää olla Kalenterisulku-merkki eikä muokkaus-/poistonappeja`);
    if (!/Kalenteri \(1 savusauna kiinni\): Huolto/.test(await cb.innerText())) problems.push(`${tag}: kalenterisulun syy (Kalenteri (…): Huolto) puuttuu: ${await cb.innerText()}`);
    await shot(page, `admin-${name}-60-paivanakyma-kalenterisulku.png`, true);
    // palvelin estää: poisto RPC:llä → closure_managed → suomenkielinen viesti (errMsg)
    const msg = await page.evaluate(async () => {
      const mods = performance.getEntriesByType('resource').map((e) => e.name);
      const sb = await import(mods.find((u) => /\/sb\.js/.test(u))), ui = await import(mods.find((u) => /\/ui\.js/.test(u)));
      const b = (await sb.rpc('admin_day_view', { p_date: new URLSearchParams(location.hash.split('?')[1]).get('d') })).blocks.find((x) => x.closure_event_id);
      try { await sb.rpc('admin_delete_block', { p_id: b.id }); return 'EI VIRHETTÄ'; } catch (e) { return `${e.code}|${ui.errMsg(e)}`; }
    });
    if (!/^closure_managed\|Tämä sulku tulee sulkukalenterista/.test(msg)) problems.push(`${tag}: closure_managed pitää näkyä suomeksi: ${msg}`);
    // --- Laura-sulku käsin: demossa (mon+22) muokattava; lisää uusi dialogilla ja poista ---
    const lauraDay = iso(monNext, 22);
    await page.evaluate((d) => { location.hash = `#/?d=${d}`; }, lauraDay);
    await page.waitForSelector('[data-testid=manual-block]');
    const mb = page.locator('[data-testid=manual-block]').first();
    if (!/Laura/.test(await mb.innerText()) || !/Koulutus \(käsin tehty\)/.test(await mb.innerText()) || (await mb.locator('button:has-text("Poista")').count()) !== 1 || /Kalenterisulku/.test(await mb.innerText())) problems.push(`${tag}: käsin tehdyllä Laura-sululla pitää olla Laura-merkki ja Poista, ei Kalenterisulku-merkkiä: ${await mb.innerText()}`);
    const lauraNew = iso(monNext, 23);
    await page.evaluate((d) => { location.hash = `#/?d=${d}`; }, lauraNew);
    await page.waitForSelector('[data-testid=day-blocks]');
    await page.click('[data-testid=day-blocks] button:has-text("Lisää sulku")');
    await page.waitForSelector('dialog[open] select[name=t]');
    const targets = await page.locator('dialog[open] select[name=t] option').allInnerTexts();
    if (!targets.some((t) => /Laura/.test(t)) || !targets.some((t) => /Savusauna/i.test(t))) problems.push(`${tag}: sulun kohteina pitää olla tilat ja Laura: ${targets}`);
    await page.selectOption('dialog[open] select[name=t]', { label: 'Laura (koulutus, poissaolo)' });
    if (!(await page.locator('dialog[open] small:has-text("Koulutus-kalenteritapahtumat eivät sulje mitään")').isVisible())) problems.push(`${tag}: Laura-valinnan ohje puuttuu`);
    await page.fill('dialog[open] input[name=r]', 'Koulutus (e2e)');
    await shot(page, `admin-${name}-61-laura-sulku-lomake.png`, false);
    await page.click('dialog[open] button[type=submit]');
    await page.waitForSelector('[data-testid=manual-block]:has-text("Koulutus (e2e)")');
    await shot(page, `admin-${name}-62-laura-sulku-lisatty.png`, false);
    await page.locator('[data-testid=manual-block]:has-text("Koulutus (e2e)") button:has-text("Poista")').click();
    await page.waitForFunction(() => !document.body.innerText.includes('Koulutus (e2e)'), null, { timeout: 8000 }).catch(() => problems.push(`${tag}: Laura-sulun poisto ei onnistunut`));
    // --- Kalenterisulut-näkymä ---
    if ((await cnt(page, '#nav a[href="#/sulkukalenterit"]')) !== 1) problems.push(`${tag}: Kalenterisulut puuttuu valikosta`);
    await page.evaluate(() => { location.hash = '#/sulkukalenterit'; });
    await page.waitForSelector('[data-testid=closure-events] [data-testid=closure-event]');
    const calTxt = await page.locator('[data-testid=closure-calendar]').allInnerTexts();
    if (calTxt.length !== 4 || calTxt.filter((t) => /Ei käytössä/.test(t)).length !== 2 || calTxt.filter((t) => /Käytössä/.test(t) && !/Ei käytössä/.test(t)).length !== 2) problems.push(`${tag}: 4 kalenteria, joista 2 käytössä ja 2 ei käytössä: ${calTxt.map((t) => t.split('\n')[0])}`);
    if ((await cnt(page, '[data-testid=sync-off]')) !== 0) problems.push(`${tag}: "Synkronointi ei ole käynnissä" ei saa näkyä kun kalenteri on käytössä`);
    if ((await cnt(page, '[data-testid=closure-event]')) !== 5) problems.push(`${tag}: 60 pv:n tapahtumia pitää olla 5 (demo): ${await cnt(page, '[data-testid=closure-event]')}`);
    if ((await cnt(page, '[data-testid=closure-conflicts] li.resrow')) !== 1) problems.push(`${tag}: konflikteja pitää olla 1 (ylitysvaraus hoidot-sulussa)`);
    if ((await cnt(page, '[data-testid=closure-runs] li.resrow')) !== 3) problems.push(`${tag}: ajoja pitää olla 3 (demo)`);
    const evTxt = await page.locator('[data-testid=closure-events]').innerText();
    if (!/Karkea jakso/.test(evTxt) || !/Ohitettu/.test(evTxt) || !/Muistiinpano: Hoitaja löytyi/.test(evTxt) || !/Sulkee/.test(evTxt) || !/Ei sulje/.test(evTxt)) problems.push(`${tag}: tapahtumalistalta puuttuu Karkea jakso / Ohitettu / muistiinpano / Sulkee / Ei sulje`);
    await shot(page, `admin-${name}-63-kalenterisulut.png`, true);
    // ohitus: Ohita hoidot-sulku (h1) → konflikti poistuu; Palauta automaattinen → konflikti palaa
    const h1 = () => page.locator('[data-testid=closure-event]:has-text("Hoidot kiinni"):not(:has-text("(ilta)"))');
    await h1().locator('button[data-act=ignore]').click();
    await page.waitForSelector('dialog[open] textarea[name=note]');
    await page.fill('dialog[open] textarea[name=note]', 'Testi (e2e): hoitaja löytyi');
    await shot(page, `admin-${name}-64-ohitus-dialogi.png`, false);
    await page.click('dialog[open] button[type=submit]');
    await page.waitForSelector('dialog[open]', { state: 'detached', timeout: 8000 });
    await page.waitForFunction(() => document.querySelector('[data-testid=closure-conflicts]')?.querySelectorAll('li.resrow').length === 0, null, { timeout: 8000 }).catch(() => problems.push(`${tag}: Ohita ei poistanut konfliktia`));
    if (!/Ohitettu/.test(await h1().innerText()) || !/Testi \(e2e\)/.test(await h1().innerText()) || (await h1().locator('button[data-act=reset]').count()) !== 1) problems.push(`${tag}: ohitetulla tapahtumalla pitää olla Ohitettu, muistiinpano ja Palauta automaattinen`);
    await shot(page, `admin-${name}-65-ohitettu.png`, true);
    await h1().locator('button[data-act=reset]').click();
    await page.waitForSelector('dialog[open] textarea[name=note]');
    await page.click('dialog[open] button[type=submit]');
    await page.waitForSelector('dialog[open]', { state: 'detached', timeout: 8000 });
    await page.waitForFunction(() => document.querySelector('[data-testid=closure-conflicts]')?.querySelectorAll('li.resrow').length === 1, null, { timeout: 8000 }).catch(() => problems.push(`${tag}: Palauta automaattinen ei palauttanut konfliktia`));
    // karkea jakso: Estä → sulkee; palauta
    const rough = () => page.locator('[data-testid=closure-event]:has-text("Pitkä huoltojakso")');
    await rough().locator('button[data-act=block]').click();
    await page.waitForSelector('dialog[open] textarea[name=note]'); await page.click('dialog[open] button[type=submit]');
    await page.waitForSelector('dialog[open]', { state: 'detached', timeout: 8000 });
    await page.waitForFunction(() => /Pakotettu estoksi/.test(document.querySelector('[data-testid=closure-events]')?.innerText || ''), null, { timeout: 8000 }).catch(() => problems.push(`${tag}: Estä ei asettanut Pakotettu estoksi -merkkiä`));
    await rough().locator('button[data-act=reset]').click();
    await page.waitForSelector('dialog[open] textarea[name=note]'); await page.click('dialog[open] button[type=submit]');
    await page.waitForSelector('dialog[open]', { state: 'detached', timeout: 8000 });
    await page.waitForFunction(() => !/Pakotettu estoksi/.test(document.querySelector('[data-testid=closure-events]')?.innerText || ''), null, { timeout: 8000 }).catch(() => problems.push(`${tag}: Palauta automaattinen ei poistanut Pakotettu estoksi -merkkiä`));
    // jaksovalinta (radiogroup) → URL
    const per = page.getByRole('group', { name: 'Näytä tapahtumat' });
    if ((await per.getByRole('radio').count()) !== 4 || !(await per.getByRole('radio', { name: '60 pv' }).isChecked())) problems.push(`${tag}: jaksovalinnassa pitää olla 4 vaihtoehtoa, oletus 60 pv`);
    await per.getByRole('radio', { name: '30 pv' }).check();
    await page.waitForFunction(() => location.hash.includes('days=30'));
    await page.waitForSelector('[data-testid=closure-events]');
    await page.waitForTimeout(300);
    if ((await cnt(page, '[data-testid=closure-event]')) !== 5) problems.push(`${tag}: 30 pv:n tapahtumia pitää olla 5 (demo: kaikki alkavat 30 pv sisällä)`);
    await ctx.close();
  }
  // --- ei vaakavieritystä, kosketuskohteet ≥ 44 px (mobiili), kontrasti ≥ 4,5:1, ei sinistä (360/390/430/1280) ---
  for (const w of [360, 390, 430, 1280]) {
    const ctx = await browser.newContext({ viewport: { width: w, height: 800 }, isMobile: w < 700, hasTouch: w < 700, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
    const page = await ctx.newPage(); watch(page, `kalenterisulut-w${w}`);
    await loginAs(page);
    for (const [hash, sel] of [['#/sulkukalenterit', '[data-testid=closure-event]'], [`#/?d=${iso(monNext, 3)}`, '[data-testid=calendar-block]'], [`#/?d=${iso(monNext, 22)}`, '[data-testid=manual-block]'], ['#/resurssit', '.blocklist']]) {
      await page.evaluate((x) => { location.hash = x; }, hash);
      await page.waitForSelector(sel); await page.waitForTimeout(300);
      const m = await page.evaluate(() => {
        const rgb = (c) => (c.match(/[\d.]+/g) || []).slice(0, 3).map(Number);
        const lum = (c) => { const [r, g, b] = rgb(c).map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
        const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
        const bgOf = (e) => { let n = e; while (n && (rgb(getComputedStyle(n).backgroundColor).length < 3 || getComputedStyle(n).backgroundColor === 'rgba(0, 0, 0, 0)')) n = n.parentElement; return n ? getComputedStyle(n).backgroundColor : 'rgb(255,255,255)'; };
        const tap = [...document.querySelectorAll('#view .evact .btn, #view .typeset .srcopt span, #view .blocklist .btn, #view .blk a')].map((e) => Math.round(e.getBoundingClientRect().height)).filter((x) => x > 0);
        const bad = [...document.querySelectorAll('#view .badge, #view .blk-reason, #view .blk-time, #view .evmain, #view .calcard p, #view .notice')].map((e) => ratio(getComputedStyle(e).color, bgOf(e))).filter((r) => r < 4.5);
        const blue = [...document.querySelectorAll('#view *')].some((e) => { const c = rgb(getComputedStyle(e).backgroundColor); return c.length === 3 && c[2] > c[0] + 40 && c[2] > c[1] + 40; });
        return { sw: document.documentElement.scrollWidth - document.documentElement.clientWidth, tap, bad, blue };
      });
      const t = `kalenterisulut-w${w} (${hash.split('?')[0]})`;
      if (m.sw > 0) problems.push(`${t}: vaakavieritys ${m.sw}px`);
      if (w < 700 && m.tap.some((x) => x < 44 && x !== 0)) problems.push(`${t}: kosketuskohde < 44 px: ${m.tap}`);
      if (m.bad.length) problems.push(`${t}: kontrasti < 4,5: ${m.bad.map((x) => x.toFixed(2))}`);
      if (m.blue) problems.push(`${t}: sinistä taustaa`);
    }
    await ctx.close();
  }
}
// ---------- HALLINTA: Uusi varaus – vuoron valinnan jälkeen näkymä vierittyy varauslomakkeeseen (v22) ----------
// Mobiili 390 ja desktop 1280, myös vähennetty liike. Lomakkeen otsikon pitää olla näkyvissä sticky-yläpalkin alla ja (mobiilissa) alapalkin yllä; fokus otsikkoon (ei kenttään → ei näppäimistöä).
if (process.env.ONLY !== 'shop') {
  const login = async (page) => { await page.goto(`${BASE}/admin/`); await page.fill('#email', 'admin@demo.local'); await page.fill('#password', 'demo'); await page.click('form#login button[type=submit]'); await page.waitForSelector('#view .day-view, #view .daygrid'); };
  const satD = (() => { const d = new Date(Date.now() + 3 * 864e5); d.setUTCDate(d.getUTCDate() + ((6 - d.getUTCDay() + 7) % 7)); return d.toISOString().slice(0, 10); })();   // lauantai: monta vuoroa → lomake on aluksi ruudun alapuolella
  for (const [name, vp, reduce] of [['mobile', { width: 390, height: 844, isMobile: true, hasTouch: true }, false], ['desktop', { width: 1280, height: 700 }, false], ['mobile-reduced', { width: 390, height: 844, isMobile: true, hasTouch: true }, true]]) {
    const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, isMobile: vp.isMobile, hasTouch: vp.hasTouch, reducedMotion: reduce ? 'reduce' : 'no-preference', locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
    const page = await ctx.newPage(); watch(page, `uusivaraus-${name}`);
    await login(page);
    await page.evaluate((d) => { location.hash = `#/uusi?d=${d}`; }, satD);
    await page.waitForSelector('.slotbtn:not([disabled])');
    const tag = `uusivaraus-${name}`;
    const settle = () => page.evaluate(() => new Promise((res) => { let last = -1, n = 0; const t = () => { const y = Math.round(scrollY * 10); n = y === last ? n + 1 : 0; last = y; n >= 8 ? res() : requestAnimationFrame(t); }; t(); }));   // vieritys pysähtynyt (~8 kuvaa samassa kohdassa)
    const state = () => page.evaluate(() => {
      const f = document.querySelector('[data-testid=booking-form]'), t = f?.querySelector('h3'), top = document.querySelector('.top').getBoundingClientRect().bottom;
      const nav = document.getElementById('nav').getBoundingClientRect(), bottomBar = nav.top > innerHeight / 2, limit = bottomBar ? nav.top : innerHeight;
      const r = t?.getBoundingClientRect(), a = document.activeElement;
      return { has: !!f, title: t?.textContent || '', tTop: r && Math.round(r.top), tBottom: r && Math.round(r.bottom), top: Math.round(top), limit: Math.round(limit), focus: a?.tagName + (a === t ? '(otsikko)' : ''), kbd: ['INPUT', 'TEXTAREA', 'SELECT'].includes(a?.tagName), sw: document.documentElement.scrollWidth - document.documentElement.clientWidth, y: Math.round(scrollY) };
    });
    const inView = (s) => s.has && s.tTop >= s.top - 1 && s.tBottom <= s.limit;
    const slots = page.locator('.slotbtn:not([disabled])');
    if ((await slots.count()) < 3) problems.push(`${tag}: lauantaina pitää olla vähintään 3 valittavaa vuoroa`);
    await page.evaluate(() => scrollTo({ top: 0, behavior: 'instant' }));
    const before = await state();
    if (before.has) problems.push(`${tag}: lomakkeen ei pitäisi olla ennen vuoron valintaa`);
    await slots.nth(0).click(); await settle();
    const s1 = await state();
    if (!inView(s1)) problems.push(`${tag}: lomakkeen otsikon pitää olla näkyvissä vuoron valinnan jälkeen (yläpalkki ${s1.top}, alaraja ${s1.limit}): ${JSON.stringify(s1)}`);
    if (name !== 'desktop' && s1.y < 100) problems.push(`${tag}: näkymän pitäisi olla vieritetty lomakkeeseen (scrollY ${s1.y})`);
    if (s1.focus !== 'H3(otsikko)' || s1.kbd) problems.push(`${tag}: fokuksen pitää olla lomakkeen otsikossa eikä kentässä (näppäimistö): ${s1.focus}`);
    if (!/^Vuoro: /.test(s1.title) || s1.sw > 0) problems.push(`${tag}: otsikko "Vuoro: …" ja ei vaakavieritystä: ${JSON.stringify(s1)}`);
    await shot(page, `admin-${name}-70-uusi-varaus-valinnan-jalkeen.png`, false);
    // vaihto toiseen vuoroon: ylös, uusi valinta → lomake vaihtuu ja pysyy näkyvissä
    await page.evaluate(() => scrollTo({ top: 0, behavior: 'instant' }));
    await slots.nth(2).click(); await settle();
    const s2 = await state();
    if (!inView(s2) || s2.title === s1.title) problems.push(`${tag}: vuoron vaihdon jälkeen lomakkeen pitää päivittyä ja olla näkyvissä: ${JSON.stringify(s2)}`);
    if ((await page.locator('.slotbtn[aria-checked=true]').count()) !== 1) problems.push(`${tag}: täsmälleen yksi vuoro pitää olla valittuna`);
    // lomakkeen kentät ovat käytettävissä heti: Tab otsikosta siirtyy ensimmäiseen kenttään (henkilömäärä)
    await page.keyboard.press('Tab');
    if ((await page.evaluate(() => document.activeElement?.name)) !== 'n') problems.push(`${tag}: Tab otsikosta pitää siirtää Henkilömäärä-kenttään`);
    // asiakashaku: ei osumia + Hae/Enter → hakusana esitäytetään uuden asiakkaan lomakkeelle (nimi / sähköposti), ei ylikirjoita, fokus seuraavaan tyhjään kenttään
    if (!reduce) {
      const sIn = page.getByLabel('Hae asiakas'), val = (n) => page.locator(`[data-testid=booking-form] [name=${n}]`).inputValue(), act = () => page.evaluate(() => document.activeElement?.name || document.activeElement?.tagName);
      const nf = page.locator('[data-testid=customer-notfound]');
      const results = () => page.locator('.ok-box').count();
      await sIn.fill('Ei Löydy Testaaja'); await page.locator('[data-testid=customer-search-btn]').click(); await nf.waitFor();
      if (!/Ei löytynyt – luo uusi asiakas/.test(await nf.innerText())) problems.push(`${tag}: viesti "Ei löytynyt – luo uusi asiakas" puuttuu`);
      if ((await val('cname')) !== 'Ei Löydy Testaaja' || (await val('cemail')) !== '' || (await act()) !== 'cemail') problems.push(`${tag}: nimi pitää esitäyttyä ja fokus siirtyä sähköpostiin: nimi=${await val('cname')}, fokus=${await act()}`);
      await nf.evaluate((el) => scrollBy(0, el.getBoundingClientRect().top - 150));   // viesti ja täytetyt kentät samaan kuvaan
      await shot(page, `admin-${name}-71-asiakashaku-ei-loytynyt-nimi.png`, false);
      await sIn.fill('uusi.asiakas@example.com'); await sIn.press('Enter'); await page.waitForFunction(() => document.querySelector('[name=cemail]')?.value);
      if ((await val('cemail')) !== 'uusi.asiakas@example.com' || (await val('cname')) !== 'Ei Löydy Testaaja' || (await act()) !== 'cphone') problems.push(`${tag}: sähköposti pitää mennä sähköpostikenttään, nimi säilyä ja fokus puhelimeen: ${await val('cemail')} / ${await val('cname')} / ${await act()}`);
      if ((await results()) !== 0) problems.push(`${tag}: Enter hakukentässä ei saa lähettää varauslomaketta`);
      await nf.evaluate((el) => scrollBy(0, el.getBoundingClientRect().top - 150));   // viesti ja täytetyt kentät samaan kuvaan
      await shot(page, `admin-${name}-72-asiakashaku-ei-loytynyt-sahkoposti.png`, false);
      await sIn.fill('toinen@example.com'); await sIn.press('Enter');
      await page.waitForFunction(() => /ei ylikirjoitettu/.test(document.querySelector('[data-testid=customer-notfound]')?.textContent || ''));
      if ((await val('cemail')) !== 'uusi.asiakas@example.com') problems.push(`${tag}: täytettyä sähköpostikenttää ei saa ylikirjoittaa`);
      await page.locator('[data-testid=booking-form] [name=cname]').fill(''); await page.locator('[data-testid=booking-form] [name=cemail]').fill('');
      await page.check('input[value=company]'); await sIn.fill('Firma Testi Oy'); await sIn.press('Enter');
      await page.waitForFunction(() => document.querySelector('[name=company_name]')?.value);
      if ((await val('company_name')) !== 'Firma Testi Oy' || (await val('cname')) !== '' || (await act()) !== 'business_id') problems.push(`${tag}: yritysasiakkaalla nimi pitää mennä yrityksen nimeen ja fokus y-tunnukseen: ${await val('company_name')} / ${await val('cname')} / ${await act()}`);
      await page.check('input[value=private]');
      // osuma → ei esitäyttöä, lista näkyy
      await sIn.fill('vuosikortti@example.com'); await sIn.press('Enter'); await page.waitForSelector('.found .listrow');
      if (await nf.count()) problems.push(`${tag}: osumalla ei saa näkyä "Ei löytynyt" -viestiä`);
      if ((await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)) > 0) problems.push(`${tag}: vaakavieritys asiakashaun jälkeen`);
    }
    // Varaustyyppi-valitsin: resurssivaraus- ja vanha varaus -lomakkeilla sama asiakashaku + esitäyttö; takaisin Vuoro-lomakkeeseen vieritys toimii edelleen
    if (!reduce) {
      for (const [kind, tid] of [['resurssi', 'resource-booking-form'], ['vanha', 'old-booking-form']]) {
        await page.evaluate((k) => { location.hash = `#/uusi?tyyppi=${k}`; }, kind);
        const rf = page.locator(`[data-testid=${tid}]`);
        if (!(await rf.waitFor({ timeout: 5000 }).then(() => true, () => false))) { problems.push(`${tag}: ${tid} ei aukea (tyyppi=${kind})`); continue; }
        const rin = rf.getByLabel('Hae asiakas'), rv = (n) => rf.locator(`[name=${n}]`).inputValue(), ract = () => page.evaluate(() => document.activeElement?.name || document.activeElement?.tagName);
        await rin.fill('Resurssi Asiakas'); await rin.press('Enter'); await page.locator('[data-testid=customer-notfound]').waitFor();
        if ((await rv('cname')) !== 'Resurssi Asiakas' || (await ract()) !== 'cemail') problems.push(`${tag}/${kind}: nimen esitäyttö + fokus sähköpostiin puuttuu: ${await rv('cname')} / ${await ract()}`);
        await rin.fill('resurssi@example.com'); await rin.press('Enter'); await page.waitForFunction(() => document.querySelector('[name=cemail]')?.value);
        if ((await rv('cemail')) !== 'resurssi@example.com' || (await rv('cname')) !== 'Resurssi Asiakas') problems.push(`${tag}/${kind}: sähköpostin esitäyttö puuttuu tai nimi ylikirjoitettiin`);
        if ((await page.locator('.ok-box').count()) !== 0) problems.push(`${tag}/${kind}: Enter hakukentässä ei saa lähettää lomaketta`);
        if (kind === 'resurssi') { await rf.locator('[data-testid=customer-notfound]').evaluate((el) => scrollBy(0, el.getBoundingClientRect().top - 150)); await shot(page, `admin-${name}-73-asiakashaku-resurssivaraus.png`, false); }
      }
      await page.evaluate((d) => { location.hash = `#/uusi?d=${d}`; }, satD);
      await page.waitForSelector('.slotbtn:not([disabled])'); await page.evaluate(() => scrollTo({ top: 0, behavior: 'instant' }));
      await page.locator('.slotbtn:not([disabled])').nth(1).click(); await settle();
      const s3 = await state();
      if (!inView(s3) || s3.focus !== 'H3(otsikko)') problems.push(`${tag}: Varaustyyppi-vaihdon jälkeen vuoron valinnan pitää vierittää lomakkeeseen: ${JSON.stringify(s3)}`);
    }
    // päivän vaihto ei vieritä lomakkeelle (vain käyttäjän vuorovalinta)
    await ctx.close();
  }
}
// ---------- HALLINTA: tuotelistan suodattimet (Näkyvyys: Kaikki / Verkossa / Ei verkossa; Kategoria; nimihaku; client-side, tila URL:ssa) ----------
if (process.env.ONLY !== 'shop') {
  const login = async (page) => { await page.goto(`${BASE}/admin/`); await page.fill('#email', 'admin@demo.local'); await page.fill('#password', 'demo'); await page.click('form#login button[type=submit]'); await page.waitForSelector('#view .day-view, #view .daygrid'); };
  const rows = (page) => page.locator('#view .prodcount + .list .listrow');
  const line = (page) => page.locator('#view .prodcount').innerText();
  const grp = (page, name) => page.getByRole('group', { name });
  const num = (t) => +(/\((\d+)\)/.exec(t)?.[1] ?? NaN);
  const catLabelOf = async (page, re) => ((await page.locator('.prodcatsel option').allInnerTexts()).find((t) => re.test(t)) || '');   // kategorialuku luetaan aina pudotusvalikon vaihtoehdoista (sama teksti kuin painikkeissa)
  const pickCat = async (page, mobile, re) => { if (mobile) await page.selectOption('.prodcatsel', { label: await catLabelOf(page, re) }); else await grp(page, 'Kategoria').getByRole('radio', { name: re }).check(); };
  const catChecked = async (page, mobile, re) => (mobile ? (await page.locator('.prodcatsel').evaluate((e) => e.options[e.selectedIndex].textContent)).match(re) !== null : grp(page, 'Kategoria').getByRole('radio', { name: re }).isChecked());
  for (const [name, vp] of [['mobile', { width: 390, height: 844, isMobile: true, hasTouch: true }], ['desktop', { width: 1280, height: 900 }]]) {
    const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, isMobile: vp.isMobile, hasTouch: vp.hasTouch, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
    const page = await ctx.newPage(); watch(page, `prodfilter-${name}`);
    await login(page);
    await page.evaluate(() => { location.hash = '#/tuotteet'; });
    await page.waitForSelector('.prodfilters');
    await page.waitForTimeout(300);
    const total = await rows(page).count();
    const rpcCalls = []; page.on('request', (r) => { if (/\/rpc\//.test(r.url())) rpcCalls.push(r.url()); });
    if (!total || !new RegExp(`^${total} / ${total} tuotetta$`).test((await line(page)).trim())) problems.push(`tuotesuodatin-${name}: oletuksena kaikki tuotteet ja tulosrivi "${total} / ${total} tuotetta" (oli: ${await line(page)})`);
    await shot(page, `admin-${name}-40-tuotteet-oletus.png`, false);
    // Näkyvyys: Ei verkossa
    const vis = grp(page, 'Näkyvyys');
    const cnt = { all: num(await vis.locator('label', { hasText: 'Kaikki' }).innerText()), on: num(await vis.locator('label', { hasText: /^Verkossa/ }).innerText()), off: num(await vis.locator('label', { hasText: 'Ei verkossa' }).innerText()) };
    if (cnt.all !== total || cnt.on + cnt.off !== total || !cnt.on || !cnt.off) problems.push(`tuotesuodatin-${name}: näkyvyyslukumäärät ${JSON.stringify(cnt)} / ${total}`);
    await vis.getByRole('radio', { name: /^Ei verkossa/ }).check();
    await page.waitForTimeout(100);
    if ((await rows(page).count()) !== cnt.off || !(await line(page)).includes(`${cnt.off} / ${total} tuotetta`)) problems.push(`tuotesuodatin-${name}: "Ei verkossa" rivejä ${await rows(page).count()} (pitäisi ${cnt.off}); ${await line(page)}`);
    if ((await rows(page).locator('.badge:text-is("Verkossa")').count()) !== 0 || (await rows(page).locator('.badge:text-is("Ei verkossa")').count()) !== cnt.off) problems.push(`tuotesuodatin-${name}: "Ei verkossa" -tulos sisältää verkossa olevia tuotteita`);
    if (!/nakyvyys=ei-verkossa/.test(page.url())) problems.push(`tuotesuodatin-${name}: valinta ei tallentunut URL:iin (${page.url()})`);
    await shot(page, `admin-${name}-41-tuotteet-ei-verkossa.png`, false);
    // Verkossa: kaikki rivit verkossa-merkillä
    await vis.getByRole('radio', { name: /^Verkossa/ }).check();
    if ((await rows(page).count()) !== cnt.on || (await rows(page).locator('.badge:text-is("Verkossa")').count()) !== cnt.on) problems.push(`tuotesuodatin-${name}: "Verkossa" -tulos väärin (${await rows(page).count()} / ${cnt.on})`);
    {   // tuotekuvat + suodattimet yhdessä: pikkukuvat näkyvät suodatetussa listassa, latautuvat eivätkä riko riviä
      const th = await rows(page).locator('img.pthumb').evaluateAll((els) => els.map((e) => [e.complete && e.naturalWidth > 0, Math.round(e.getBoundingClientRect().width), Math.round(e.getBoundingClientRect().height)]));
      if (!th.length || th.some(([ok, w, h]) => !ok || w !== 40 || h !== 40)) problems.push(`tuotesuodatin-${name}: pikkukuvien pitää näkyä (40×40, ladattu) suodatetussa listassa: ${JSON.stringify(th)}`);
      if ((await rows(page).locator('img.pthumb').count()) !== (await rows(page).filter({ has: page.locator('img.pthumb') }).count())) problems.push(`tuotesuodatin-${name}: yhdellä rivillä saa olla enintään yksi pikkukuva`);
      if ((await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)) > 0) problems.push(`tuotesuodatin-${name}: vaakavieritys pikkukuvien kanssa`);
      await shot(page, `admin-${name}-42-tuotteet-verkossa-pikkukuvat.png`, false);
    }
    // Kategoria (yhdistettynä Kaikki-näkyvyyteen): Hoidot
    await vis.getByRole('radio', { name: /^Kaikki/ }).check();
    const mob = !!vp.isMobile;
    const hoidotN = num(await catLabelOf(page, /^Hoidot/));
    await pickCat(page, mob, /^Hoidot/);
    if (!hoidotN || (await rows(page).count()) !== hoidotN || (await rows(page).locator('.what small:has-text("Hoidot")').count()) !== hoidotN) problems.push(`tuotesuodatin-${name}: kategoria Hoidot: rivejä ${await rows(page).count()} / lukumäärä ${hoidotN}`);
    if (!/kategoria=treatment/.test(page.url())) problems.push(`tuotesuodatin-${name}: kategoria ei URL:ssa (${page.url()})`);
    await shot(page, `admin-${name}-42-tuotteet-kategoria.png`, false);
    // yhdistelmä + latauksen jälkeen tila säilyy URL:sta
    await vis.getByRole('radio', { name: /^Ei verkossa/ }).check();
    const comb = await rows(page).count();
    if (rpcCalls.length) problems.push(`tuotesuodatin-${name}: suodatus teki RPC-kutsuja (${rpcCalls.length}) – pitää olla client-side`);
    await page.reload(); await page.waitForSelector('.prodfilters'); await page.waitForTimeout(300); rpcCalls.length = 0;   // lataus tekee omat kutsunsa
    if (!(await grp(page, 'Näkyvyys').getByRole('radio', { name: /^Ei verkossa/ }).isChecked()) || !(await catChecked(page, mob, /^Hoidot/)) || (await rows(page).count()) !== comb) problems.push(`tuotesuodatin-${name}: suodattimet eivät palautuneet URL:sta`);
    // nuolinäppäimet (radiogroup): Näkyvyys Kaikki → oikea nuoli → Verkossa
    await vis.getByRole('radio', { name: /^Kaikki/ }).check(); await vis.getByRole('radio', { name: /^Kaikki/ }).focus();
    await page.keyboard.press('ArrowRight');
    if (!(await vis.getByRole('radio', { name: /^Verkossa/ }).isChecked())) problems.push(`tuotesuodatin-${name}: nuolinäppäin ei vaihtanut valintaa`);
    // nimihaku + tyhjä tulos + Tyhjennä suodattimet
    await page.fill('.prodfilters input[type=search]', 'zzzeituotetta');
    await page.waitForSelector('.prodempty');
    if ((await rows(page).count()) !== 0 || !(await page.locator('.prodempty').innerText()).includes('Ei tuotteita valituilla suodattimilla')) problems.push(`tuotesuodatin-${name}: tyhjän tuloksen viesti puuttuu`);
    await shot(page, `admin-${name}-43-tuotteet-tyhja-tulos.png`, false);
    await page.locator('#view .prodcount button', { hasText: 'Tyhjennä suodattimet' }).click();
    await page.waitForTimeout(100);
    if ((await rows(page).count()) !== total || /nakyvyys|kategoria|haku/.test(page.url()) || (await page.inputValue('.prodfilters input[type=search]')) !== '' || !(await catChecked(page, mob, /^Kaikki kategoriat/))) problems.push(`tuotesuodatin-${name}: Tyhjennä suodattimet ei palauttanut kaikkia (${await rows(page).count()} / ${total}; ${page.url()})`);
    // haku nimellä: osuma löytyy
    await page.fill('.prodfilters input[type=search]', 'yleinen');
    await page.waitForTimeout(100);
    if ((await rows(page).count()) < 1 || /nakyvyys/.test(page.url()) || !/haku=yleinen/.test(page.url())) problems.push(`tuotesuodatin-${name}: nimihaku "yleinen" ei löytänyt tai URL puuttuu (${page.url()})`);
    if (rpcCalls.length) problems.push(`tuotesuodatin-${name}: suodatus teki RPC-kutsuja (${rpcCalls.length}) – pitää olla client-side`);
    // tuotteen muokkausdialogi aukeaa suodatetusta listasta ja lista pysyy suodatettuna tallennuksen/sulkemisen jälkeen
    await rows(page).first().click(); await page.waitForSelector('dialog[open]'); await page.keyboard.press('Escape');
    await ctx.close();
  }
  // --- ei vaakavieritystä, kosketuskohteet ≥ 44 px ja kontrasti ≥ 4,5:1 (360/390/430/1280) ---
  for (const w of [360, 390, 430, 1280]) {
    const ctx = await browser.newContext({ viewport: { width: w, height: 800 }, isMobile: w < 700, hasTouch: w < 700, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
    const page = await ctx.newPage(); watch(page, `prodfilter-w${w}`);
    await login(page);
    for (const step of ['oletus', 'ei-verkossa', 'tyhja']) {
      await page.evaluate((q) => { location.hash = `#/tuotteet${q}`; }, step === 'oletus' ? '' : step === 'ei-verkossa' ? '?nakyvyys=ei-verkossa&kategoria=treatment' : '?haku=zzzeituotetta');
      await page.waitForSelector('.prodfilters'); await page.waitForTimeout(250);
      const m = await page.evaluate(() => {
        const rgb = (c) => (c.match(/[\d.]+/g) || []).slice(0, 3).map(Number);
        const lum = (c) => { const [r, g, b] = rgb(c).map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
        const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
        const segs = [...document.querySelectorAll('.prodfilters .srcopt span'), ...document.querySelectorAll('.prodfilters .prodcatsel')].map((e) => Math.round(e.getBoundingClientRect().height)).filter((x) => x > 0);   // piilotettu kategoriaryhmä (kapea/leveä) ohitetaan
        const chk = document.querySelector('.prodfilters .srcopt input:checked + span'); const sel = ratio(getComputedStyle(chk).color, getComputedStyle(chk).backgroundColor);
        const unchk = document.querySelector('.prodfilters .srcopt input:not(:checked) + span'); const un = ratio(getComputedStyle(unchk).color, getComputedStyle(unchk).backgroundColor);
        const clr = document.querySelector('.prodcount button'); const clrH = clr ? Math.round(clr.getBoundingClientRect().height) : 44; const clrC = clr ? ratio(getComputedStyle(clr).color, getComputedStyle(document.body).backgroundColor) : 21;
        const search = document.querySelector('.prodfilters input[type=search]').getBoundingClientRect().height;
        const blue = [...document.querySelectorAll('.prodfilters *')].some((e) => { const c = rgb(getComputedStyle(e).backgroundColor); return c.length === 3 && c[2] > c[0] + 40 && c[2] > c[1] + 40; });
        return { sw: document.documentElement.scrollWidth - document.documentElement.clientWidth, segs, sel, un, clrH, clrC, search, blue, rowsOver: [...document.querySelectorAll('.prodcount + .list .listrow')].some((c) => c.scrollWidth > c.clientWidth + 1) };
      });
      const tag = `prodfilter-w${w} (${step})`;
      if (m.sw > 0) problems.push(`${tag}: vaakavieritys ${m.sw}px`);
      if (!m.segs.length || m.segs.some((x) => x < 44) || m.clrH < 44 || m.search < 44) problems.push(`${tag}: kosketuskohde < 44 px: ${m.segs} / tyhjennä ${m.clrH} / haku ${m.search}`);
      if (m.sel < 4.5 || m.un < 4.5 || m.clrC < 4.5) problems.push(`${tag}: kontrasti < 4,5: valittu ${m.sel.toFixed(2)} / valitsematon ${m.un.toFixed(2)} / tyhjennä ${m.clrC.toFixed(2)}`);
      if (m.blue) problems.push(`${tag}: sinistä taustaa suodattimissa`);
      if (m.rowsOver) problems.push(`${tag}: tuoterivin sisältö ylittää rivin leveyden`);
    }
    await ctx.close();
  }
}
// ---------- HALLINTA: saunottaja puuttuu (migraatio 22) + aikaikkuna (migraatio 23): merkki, Tarkista, poikkeus, varoitus luonnin jälkeen, virheilmoitukset ----------
if (process.env.ONLY !== 'shop') for (const [name, vp] of [['mobile', { width: 390, height: 844, deviceScaleFactor: 1, isMobile: true, hasTouch: true }], ['desktop', { width: 1280, height: 900 }]]) {
  const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, deviceScaleFactor: vp.deviceScaleFactor || 1, isMobile: vp.isMobile, hasTouch: vp.hasTouch, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const page = await ctx.newPage();   // odotettu 400 (BK001: time_window, ritual_start) resurssivarauksen virhetestissä ei ole virhe; muut virheet ovat
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type()) && !/Failed to load resource.*400/.test(m.text())) problems.push(`saunottaja-${name} console.${m.type()}: ${m.text()}`); });
  page.on('pageerror', (e) => problems.push(`saunottaja-${name} pageerror: ${e.message}`));
  page.on('requestfailed', (r) => problems.push(`saunottaja-${name} requestfailed: ${r.url()} ${r.failure()?.errorText}`));
  page.on('response', (r) => { if (r.status() >= 400 && !/admin_create_resource_booking/.test(r.url())) problems.push(`saunottaja-${name} HTTP ${r.status()}: ${r.url()}`); });
  const login = async (email = 'admin@demo.local') => { await page.goto(`${BASE}/admin/`); await page.fill('#email', email); await page.fill('#password', 'demo'); await page.click('form#login button[type=submit]'); await page.waitForSelector('#nav a'); };
  const hHel = (n) => { const t = new Date(); t.setUTCDate(t.getUTCDate() + n); return t.toISOString().slice(0, 10); };
  const mon = (() => { const d = new Date(); d.setUTCDate(d.getUTCDate() + ((8 - d.getUTCDay()) % 7 || 7)); return d; })();
  const dayOf = (k) => { const d = new Date(mon); d.setUTCDate(d.getUTCDate() + k); return d.toISOString().slice(0, 10); };
  const noH = () => page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  const tag = `saunottaja-${name}`;
  await login();
  // --- Tarkista: Ei saunottajaa -osio (demo: 1 avoin + 1 poikkeus myönnetty → vain avoin listalla) ---
  await page.evaluate(() => { location.hash = '#/tarkista'; });
  await page.waitForSelector('[data-testid=review-missing_therapist]');
  const sec = page.locator('[data-testid=review-missing_therapist]');
  const secTxt = await sec.innerText();
  if (!/Ei saunottajaa/.test(secTxt) || (await sec.locator('li.resrow').count()) < 1 || !(await sec.locator('[data-testid=grant-btn]').count())) problems.push(`${tag}: Tarkista-listalla pitää olla Ei saunottajaa -osio, rivi ja Myönnä poikkeus -painike`);
  const tapH = await sec.locator('[data-testid=grant-btn]').first().evaluate((e) => Math.round(e.getBoundingClientRect().height));
  if (tapH < 44 || (await noH()) > 0) problems.push(`${tag}: Myönnä poikkeus -painikkeen korkeus ${tapH} < 44 tai vaakavieritys`);
  if (/Poikkeus myönnetty/.test(secTxt)) problems.push(`${tag}: poikkeuksen saanut varaus ei saa olla Tarkista-listalla`);
  await shot(page, `admin-${name}-90-tarkista-ei-saunottajaa.png`, true);
  // --- Päivänäkymä: merkki "Ei saunottajaa" (mon+7) ja "Saunottaja sovittu" (mon+8) ---
  await page.evaluate((d) => { location.hash = `#/?d=${d}`; }, dayOf(7));
  await page.waitForSelector('#view .resrow');
  if ((await page.locator('#view .resrow .badge.tmiss:has-text("Ei saunottajaa")').count()) < 1) problems.push(`${tag}: päivänäkymän varauksella pitää olla Ei saunottajaa -merkki`);
  await shot(page, `admin-${name}-91-paivanakyma-ei-saunottajaa.png`, false);
  await page.locator('#view .resrow:has(.badge.tmiss) button.link').first().click();
  await page.waitForSelector('dialog[open] [data-testid=therapist-state]');
  const st = await page.locator('dialog[open] [data-testid=therapist-state]').innerText();
  if (!/Puuttuu työvuorosta/.test(st) || !(await page.locator('dialog[open] [data-testid=grant-btn]').count())) problems.push(`${tag}: varauksen tiedoissa pitää näkyä "Puuttuu työvuorosta" ja Myönnä poikkeus: ${st}`);
  await shot(page, `admin-${name}-92-varauksen-tiedot-ei-saunottajaa.png`, false);
  await page.keyboard.press('Escape');
  await page.evaluate((d) => { location.hash = `#/?d=${d}`; }, dayOf(8));
  await page.waitForSelector('#view .resrow');
  if ((await page.locator('#view .resrow .badge.tmiss-ok:has-text("Saunottaja sovittu")').count()) < 1 || (await page.locator('#view .resrow .badge.tmiss:has-text("Ei saunottajaa")').count()) !== 0) problems.push(`${tag}: poikkeuksen saaneella varauksella pitää olla "Saunottaja sovittu" eikä "Ei saunottajaa"`);
  // --- Uusi resurssivaraus ilman saunottajaa (maanantai/tiistai ilman vuoroja): varoitus + poikkeus ---
  const fresh = (() => { const w = 4 + Math.floor(Math.random() * 14), d = new Date(mon); d.setUTCDate(d.getUTCDate() + 7 * w + Math.floor(Math.random() * 2)); return d.toISOString().slice(0, 10); })();
  const availCalls = mockAvailability(page);   // admin_treatment_availability (booking_25): mockattu; varaus tehdään oikealla admin_create_resource_booking-funktiolla
  const pickSlot = async () => { await page.waitForSelector('[data-testid=slot]', { timeout: 8000 }); await page.locator('[data-testid=slot]:has-text("17:00")').first().click(); };
  await page.evaluate((d) => { location.hash = `#/uusi?tyyppi=resurssi&d=${d}`; }, fresh);
  const form = page.locator('[data-testid=resource-booking-form]'); await form.waitFor();
  await form.locator('[name=product]').selectOption('10');
  if (!/16:00–20:30/.test(await form.locator('[data-testid=window-hint]').innerText())) problems.push(`${tag}: aikaikkunan vihje puuttuu hoitotuotteella`);
  await form.locator('[name=date]').fill(fresh); await form.locator('[name=time]').fill('12:00');
  await form.locator('[name=cname]').fill('Saunottajaton Testi'); await form.locator('[name=cemail]').fill(`saunottajaton-${Date.now()}@example.com`);
  await form.locator('button[type=submit]').click();
  await form.locator('[data-testid=window-hint]').waitFor();
  await page.waitForFunction(() => /aikaikkunan ulkopuolella/.test(document.querySelector('[data-testid=resource-booking-form] .err:not([hidden])')?.textContent || ''), null, { timeout: 8000 }).catch(() => problems.push(`${tag}: time_window-virhe pitää näkyä suomeksi lomakkeella`));
  await shot(page, `admin-${name}-93-aikaikkuna-virhe.png`, false);
  await form.locator('[name=product]').selectOption('8'); await form.locator('[name=time]').fill('15:30');
  await form.locator('button[type=submit]').click();
  await page.waitForFunction(() => /16:00, 16:30 tai 17:00/.test(document.querySelector('[data-testid=resource-booking-form] .err:not([hidden])')?.textContent || ''), null, { timeout: 8000 }).catch(() => problems.push(`${tag}: ritual_start-virhe pitää näkyä suomeksi lomakkeella`));
  const sel10 = async () => { await form.locator('[name=product]').selectOption('10'); await page.waitForSelector('[data-testid=slot]', { timeout: 8000 }); };
  await sel10();
  const sizes = await page.evaluate(() => [...document.querySelectorAll('[data-testid=availability] button')].map((e) => Math.round(e.getBoundingClientRect().height)));
  if (!sizes.length || Math.min(...sizes) < 44 || (await noH()) > 0) problems.push(`${tag}: vapaat ajat -painikkeiden korkeus ${Math.min(...sizes)} < 44 tai vaakavieritys`);
  if (!(await page.locator('[data-testid=slot]:has-text("Ei saunottajaa")').count()) || (await page.locator('[data-testid=slot] small.ov').count())) problems.push(`${tag}: vapaat ajat: "Ei saunottajaa" pitää näkyä, "Ylitys" ei ilman ylitystä`);
  await page.locator('[data-testid=availability]').scrollIntoViewIfNeeded(); await shot(page, `admin-${name}-96-vapaat-ajat.png`, false);
  // ylitysajat (admin): perustelu → haku p_override=true → ylitysajat merkittyinä
  await page.check('[data-testid=override-box] input[name=override]');
  await page.fill('[data-testid=override-box] [name=override_reason]', 'Sovittu erikseen (e2e)'); await page.locator('[data-testid=override-box] [name=override_reason]').blur();
  await page.waitForFunction(() => /ylitysajat mukana/.test(document.querySelector('[data-testid=avail-status]')?.textContent || ''), null, { timeout: 8000 }).catch(() => problems.push(`${tag}: ylitysaikojen haku ei onnistunut`));
  if (availCalls.at(-1)?.p_override !== true || availCalls.at(-1)?.p_override_reason !== 'Sovittu erikseen (e2e)') problems.push(`${tag}: ylityshaun argumentit väärin: ${JSON.stringify(availCalls.at(-1))}`);
  await page.locator('[data-testid=day-chip]:has-text("pe ")').first().click(); await page.locator('[data-testid=slot]').first().click();
  if (!(await page.locator('[data-testid=slot] small.ov').count()) || !/Vaatii ylityksen/.test(await page.locator('[data-testid=slot-picked]').innerText())) problems.push(`${tag}: ylitysaika pitää olla merkitty ja näkyä yhteenvedossa`);
  await page.locator('[data-testid=availability]').scrollIntoViewIfNeeded(); await shot(page, `admin-${name}-97-vapaat-ajat-ylitys.png`, false);
  await page.uncheck('[data-testid=override-box] input[name=override]'); await page.waitForTimeout(700);
  await sel10(); await pickSlot();
  if (!/Ei saunottajaa/.test(await page.locator('[data-testid=slot-picked]').innerText()) || (await form.locator('[name=time]').inputValue()) !== '17:00') problems.push(`${tag}: valittu aika ei täyttänyt lomaketta`);
  await page.locator('[data-testid=availability]').scrollIntoViewIfNeeded(); await shot(page, `admin-${name}-98-vapaat-ajat-valittu.png`, false);
  const warn = page.locator('[data-testid=therapist-warning]');
  for (let k = 0; k < 6; k++) {   // aiemmat ajot jättävät varauksia: jos tila on varattu tai päivällä on vuoro, kokeile toista päivää
    await form.locator('button[type=submit]').click();
    if (await warn.waitFor({ timeout: 4000 }).then(() => true, () => false)) break;
    const d = new Date(`${fresh}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + 7 * (k + 3) + (k % 2)); await page.evaluate((x) => { location.hash = `#/uusi?tyyppi=resurssi&d=${x}`; }, d.toISOString().slice(0, 10));
    await form.waitFor(); await sel10(); await pickSlot();
    await form.locator('[name=cname]').fill('Saunottajaton Testi'); await form.locator('[name=cemail]').fill(`saunottajaton-${Date.now()}@example.com`);
  }
  await warn.waitFor({ timeout: 10000 });
  if (!/Varaus tehty, mutta saunottaja puuttuu työvuorosta/.test(await warn.innerText()) || !/Varaus luotu/.test(await page.locator('#view .ok-box').innerText())) problems.push(`${tag}: luonnin jälkeen pitää näkyä varoitus "Varaus tehty, mutta saunottaja puuttuu työvuorosta" ja varaus luotu -ruutu`);
  const wh = await warn.locator('[data-testid=grant-btn]').evaluate((e) => Math.round(e.getBoundingClientRect().height));
  if (wh < 44 || (await noH()) > 0) problems.push(`${tag}: varoituksen painike ${wh} < 44 tai vaakavieritys`);
  await warn.scrollIntoViewIfNeeded(); await shot(page, `admin-${name}-94-varoitus-saunottaja-puuttuu.png`, false);
  await warn.locator('[data-testid=grant-btn]').click();
  await page.waitForSelector('dialog[open] [data-testid=grant-form]');
  await page.locator('dialog[open] [data-testid=grant-submit]').click();   // tyhjä perustelu → virhe, ei kutsua
  await page.waitForSelector('dialog[open] .err:not([hidden])');
  if (!/Anna perustelu/.test(await page.locator('dialog[open] .err').innerText())) problems.push(`${tag}: tyhjä perustelu pitää estää viestillä`);
  await shot(page, `admin-${name}-95-poikkeus-perustelu-puuttuu.png`, false);
  await page.fill('dialog[open] textarea[name=note]', 'Sovittu erikseen (e2e)');
  await page.locator('dialog[open] [data-testid=grant-submit]').click();
  await page.waitForSelector('dialog[open]', { state: 'detached', timeout: 8000 }).catch(() => problems.push(`${tag}: poikkeuksen myöntö ei onnistunut`));
  await page.waitForFunction(() => /Poikkeus myönnetty/.test(document.getElementById('toast')?.textContent || ''), null, { timeout: 5000 }).catch(() => problems.push(`${tag}: ilmoitus "Poikkeus myönnetty" puuttuu`));
  if (await warn.count()) problems.push(`${tag}: varoitus pitää poistua poikeuksen myöntämisen jälkeen`);
  // --- peruskäyttäjä (ei bookings.override): ei Myönnä poikkeus -painikkeita ---
  await ctx.clearCookies(); await page.evaluate(() => { localStorage.clear(); sessionStorage.clear(); });
  await login('staff@demo.local');
  await page.evaluate(() => { location.hash = '#/tarkista'; });
  if (await page.locator('[data-testid=review-missing_therapist]').count().then(async (n) => n || (await page.waitForSelector('[data-testid=review-missing_therapist], #view .err', { timeout: 5000 }).then(() => page.locator('[data-testid=review-missing_therapist]').count(), () => 0)))) {
    if (await page.locator('[data-testid=grant-btn]').count()) problems.push(`${tag}: peruskäyttäjälle ei saa näkyä Myönnä poikkeus -painiketta`);
  }
  await ctx.close();
}
// ---------- HALLINTA: päivänäkymä (v25): työvuorot, hlö + kapasiteettinappi, saapunut-nappi, lisäpalveluikonit, resurssilomakkeen lisäpalvelut ----------
if (process.env.ONLY !== 'shop') for (const [name, vp] of [['mobile', { width: 390, height: 844, isMobile: true, hasTouch: true }], ['desktop', { width: 1280, height: 900 }]]) {
  const tag = `paivanakyma-${name}`;
  const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, isMobile: vp.isMobile, hasTouch: vp.hasTouch, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const page = await ctx.newPage(); watch(page, tag);
  const noH = () => page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  const dayD = (() => { const d = new Date(); d.setUTCDate(d.getUTCDate() + ((8 - d.getUTCDay()) % 7 || 7)); return d.toISOString().slice(0, 10); })();   // seuraava maanantai: demossa lämmitys-/saunottaja-/vastaanottovuorot, Miesten sauna ja lisäpalveluvaraus
  await page.goto(`${BASE}/admin/`); await page.fill('#email', 'admin@demo.local'); await page.fill('#password', 'demo'); await page.click('form#login button[type=submit]');
  await page.waitForSelector('#view .day-view, #view .daygrid');
  const satD = (() => { const d = new Date(); d.setUTCDate(d.getUTCDate() + ((6 - d.getUTCDay() + 7) % 7 || 7)); return d.toISOString().slice(0, 10); })();   // seuraava lauantai: demossa Lämmitykset-, Saunottaja- ja Vastaanotto-vuorot
  await page.evaluate((d) => { location.hash = `#/?d=${d}`; }, satD);
  await page.waitForSelector('[data-testid=dayshift]'); await page.waitForSelector('[data-testid=session]');
  const roles = await page.locator('[data-testid=dayshift]').allInnerTexts();
  if (!roles.length || !roles.every((t) => /^(Lämmitykset|Saunottaja|Vastaanotto)\s+\d/.test(t.replace(/\s+/g, ' ').trim()))) problems.push(`${tag}: työvuorot pitää näyttää muodossa "Rooli 14–20 Nimi" suomeksi: ${JSON.stringify(roles)}`);
  if ((await page.locator('.dshift.shift-heater').count()) < 1 || (await page.locator('.dshift.shift-therapist').count()) < 1 || (await page.locator('.dshift.shift-reception').count()) < 1) problems.push(`${tag}: kaikki kolme roolia (Lämmitykset, Saunottaja, Vastaanotto) pitää näkyä omilla väreillään`);
  if ((await noH()) > 0) problems.push(`${tag}: vaakavieritys`);
  if (/ei myynniss|myynti päättynyt/i.test(await page.locator('#view').innerText())) problems.push(`${tag}: "ei myynnissä" -tekstiä ei saa näkyä`);
  await shot(page, `admin-${name}-100-paivanakyma-tyovuorot.png`, false);
  await page.evaluate((d) => { location.hash = `#/?d=${d}`; }, dayD);   // maanantai: Miesten sauna, lisäpalveluvaraukset
  await page.waitForSelector('[data-testid=session] .reslist'); await page.waitForTimeout(500);
  const hdr = await page.locator('[data-testid=session] header').first().evaluate((e) => { const c = e.querySelector('.hdr-right'), r = e.getBoundingClientRect(), q = c.getBoundingClientRect(); return { rightGap: Math.round(r.right - q.right), n: e.querySelectorAll('.cap').length }; });
  if (hdr.rightGap > 20) problems.push(`${tag}: hlö ja kapasiteettinappi pitää olla otsikkorivin oikeassa reunassa (väli ${hdr.rightGap})`);
  const sizes = await page.evaluate(() => [...document.querySelectorAll('.btn.cap, .arrive')].map((e) => Math.round(e.getBoundingClientRect().height)));
  if (!sizes.length || Math.min(...sizes) < 44) problems.push(`${tag}: kapasiteetti-/saapunut-nappien korkeus ${Math.min(...sizes)} < 44 px`);
  const kinds = await page.locator('.addon-item').evaluateAll((els) => els.map((e) => e.dataset.kind));
  if (!kinds.includes('whisk')) problems.push(`${tag}: saunavihta-ikoni puuttuu lisäpalvelurivistä (löytyi: ${kinds})`);
  await page.locator('.addon-item').first().scrollIntoViewIfNeeded(); await page.evaluate(() => window.scrollBy(0, -140));
  await shot(page, `admin-${name}-101-paivanakyma-lisapalvelut.png`, false);
  // saapunut-nappi (oikea RPC): merkitään saapuneeksi, näkyy latauksen jälkeen, perutaan takaisin
  const row = page.locator('[data-testid=session] .resrow:has([data-testid=arrive])').first();
  const nm = (await row.locator('button.link strong').innerText()).trim();
  const ar = row.locator('[data-testid=arrive]');
  const wasOn = (await ar.getAttribute('aria-pressed')) === 'true';
  await ar.click();
  await page.waitForTimeout(700);
  await shot(page, `admin-${name}-102-saapunut.png`, false);
  await page.reload(); await page.waitForSelector('[data-testid=session] .reslist');
  const ar2 = page.locator(`[data-testid=session] .resrow:has(button.link strong:text-is("${nm}")) [data-testid=arrive]`).first();
  if ((await ar2.getAttribute('aria-pressed')) !== String(!wasOn)) problems.push(`${tag}: saapunut-tila ei tallentunut (${nm})`);
  await ar2.click(); await page.waitForTimeout(700);   // palautus
  // Vapaana-nappi → Uusi varaus esivalittuna ja vierityksellä lomakkeeseen
  const cap = page.locator('[data-testid=cap-btn]').first();
  await cap.scrollIntoViewIfNeeded(); await cap.click();
  await page.waitForSelector('[data-testid=booking-form]'); await page.waitForTimeout(1200);
  if (!/[?&]r=\d+&t=/.test(page.url()) || (await page.locator('.slotbtn[aria-checked=true]').count()) !== 1) problems.push(`${tag}: Vapaana-napin pitää avata Uusi varaus esivalitulla vuorolla (${page.url()})`);
  if (!(await page.locator('[data-testid=booking-form] h3').first().evaluate((e) => { const r = e.getBoundingClientRect(); return r.top >= 0 && r.top < window.innerHeight; }))) problems.push(`${tag}: lomakkeen pitää vierittyä näkyviin`);
  await shot(page, `admin-${name}-103-vapaana-uusi-varaus.png`, false);
  // hoito-/saunotuslomake: saunavihta, turvenaamio ja jalkakylpy eivät kuulu hoitoon/saunotukseen (ei pyyhettä paikallisessa kannassa → valitsin piilossa)
  await page.evaluate(() => { location.hash = '#/uusi?tyyppi=resurssi'; }); await page.waitForSelector('[data-testid=resource-booking-form]'); await page.waitForTimeout(500);
  const resAdd = await page.locator('[data-testid=resource-booking-form] .addon-picker .addonrow:not([hidden]) strong').allInnerTexts().catch(() => []);
  if (resAdd.some((t) => /vihta|turvenaamio|jalkakylpy/i.test(t))) problems.push(`${tag}: hoito-/saunotuslomakkeella ei saa tarjota vihtaa tai turvenaamiota: ${resAdd}`);
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
  const canImg = (await page.locator('dialog[open] button:has-text("Tallenna kuva")').count()) > 0;
  if (role === 'staff' && canImg) problems.push('admin-staff: kuvan hallinta ei saa näkyä peruskäyttäjälle');
  if (role === 'manager' && !canImg) problems.push('admin-manager: kuvan hallinnan pitäisi näkyä ylläpitäjälle');
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
// admin_day_shifts (migraatio 27) puuttuu kannasta (jos demo on rakennettu ilman sitä): hallinta putoaa admin_upcoming_shifts-kutsuun; odotettu 404 + selaimen konsoliviesti ei ole ongelma
{ const pages = new Set(problems.filter((x) => /HTTP 404: \S*admin_day_shifts/.test(x)).map((x) => x.split(' ')[0]));
  for (let i = problems.length - 1; i >= 0; i--) if (/HTTP 404: \S*admin_day_shifts/.test(problems[i]) || (/console\.error: Failed to load resource: .*404/.test(problems[i]) && pages.has(problems[i].split(' ')[0]))) problems.splice(i, 1); }
if (problems.length) { console.error('ONGELMIA:\n' + [...new Set(problems)].join('\n')); process.exit(1); }
console.log(`ok: kuvakaappaukset → ${OUT}; ei konsolivirheitä`);
