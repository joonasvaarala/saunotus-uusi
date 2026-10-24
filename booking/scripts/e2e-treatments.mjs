// E2E: hoito- ja rituaalivaraukset kaupassa (kb 10, 11, 12 ja rituaali kb 8). Vaatii käynnissä olevan demon (kehityspalvelin + shop build, ks. booking/README.md).
// Käyttö:  PW_DIR=/polku/node_modules OUT=/polku/kuvat node booking/scripts/e2e-treatments.mjs
// TREATMENTS=off: tuotanto ennen lippuja (kehityspalvelin TREATMENT_MOCK=0 → katalogissa ei ole slots-tuotteita) → kauppa näyttää hoidoille "ota yhteyttä".
// Oletus (on): mock-rajapinta (shop/src/treatment-mock.js, vastaa KOODARI_public_treatment_fi.md:tä). Palvelimen muistissa olevat mock-varaukset kuluttavat aikoja → käynnistä palvelin uudelleen ennen ajoa.
// Epäonnistuu (exit 1), jos konsolissa on virheitä, pyyntö epäonnistuu (paitsi odotetut) tai jokin tarkistus ei täyty.
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { mkdirSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';

const require = createRequire(import.meta.url);
const pwPath = require.resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', dirname(fileURLToPath(import.meta.url))].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath));
const chromium = pw.chromium || pw.default.chromium;
const BASE = process.env.BASE_URL || 'http://localhost:4180';
const OFF = process.env.TREATMENTS === 'off';
const OUT = process.env.OUT ? resolve(process.env.OUT) : null;
if (OUT) mkdirSync(OUT, { recursive: true });
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const problems = [];
let checks = 0;
const expect = (ok, msg) => { checks++; if (!ok) problems.push(msg); };
const TZ = 'Europe/Helsinki';
const today = new Date().toLocaleDateString('sv-SE', { timeZone: TZ });
const addDays = (ds, n) => { const d = new Date(`${ds}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const dow = (ds) => new Date(`${ds}T12:00:00Z`).getUTCDay();
const HERO = { 'saunahoito-2': 'Saunahoito', 'saunotus-2': 'Saunotus', syvasaunotus: 'Syväsaunotus', saunotusrituaali: 'Saunotusrituaali', 'saunarituaali-ja-savusaunavuoro': 'Saunarituaali ja savusaunavuoro (la & su)' };
const MAXP = { 'saunahoito-2': 4, 'saunotus-2': 2, syvasaunotus: 2, saunotusrituaali: 6, 'saunarituaali-ja-savusaunavuoro': 6 };
const RITUAL_SLUGS = ['saunotusrituaali', 'saunarituaali-ja-savusaunavuoro'];   // vain la–su, alkuajat 16:00/16:30/17:00 (kb 8 ja paketti kb 7)

const watch = (page, name, allow = []) => {
  const ok = (s) => allow.some((re) => re.test(s));
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type()) && !ok(m.text()) && !ok(m.location().url || '')) problems.push(`${name} console.${m.type()}: ${m.text()} ${m.location().url || ''}`); });
  page.on('pageerror', (e) => problems.push(`${name} pageerror: ${e.message}`));
  page.on('requestfailed', (r) => { if (!(/ERR_ABORTED/.test(r.failure()?.errorText || '')) && !ok(r.url())) problems.push(`${name} requestfailed: ${r.url()} ${r.failure()?.errorText}`); });
  page.on('response', (r) => { if (r.status() >= 400 && !ok(r.url())) problems.push(`${name} HTTP ${r.status()}: ${r.url()}`); });
};
const newPage = async (vp, { lang = 'fi', allow = [] } = {}, name = 'p') => {
  const mobile = vp.width < 600;
  const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height || 844 }, isMobile: mobile, hasTouch: mobile, deviceScaleFactor: 1, locale: lang === 'en' ? 'en-GB' : 'fi-FI', timezoneId: TZ });
  const page = await ctx.newPage(); watch(page, name, allow); page.ctx = ctx; return page;
};
const shop = (lang) => `${BASE}${lang === 'en' ? '/en/book/' : '/varaa/'}`;
const shot = async (page, file) => { if (!OUT) return; await page.evaluate(() => window.scrollTo(0, 0)); await page.waitForTimeout(150); await page.screenshot({ path: join(OUT, file), fullPage: true }); };
const fresh = async (page, url, idle = true) => { await page.goto(`${BASE}/varaa/vahvistus/`); await page.goto(url); if (idle) await page.waitForLoadState('networkidle').catch(() => {}); };   // tuore lataus (ei aiemman sivun välimuistia / keskeytyviä hakuja)
const hscroll = async (page, tag) => expect(!(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)), `${tag}: vaakavieritys`);
const hp = (page) => new URLSearchParams(page.url().split('#')[1]?.split('?')[1] || '');
const hms = (s) => { const m = s.match(/(\d\d:\d\d)\D*(\d\d:\d\d)?/); return m ? [m[1], m[2] || null] : [null, null]; };

// suhteellinen luminanssi / kontrasti sivun sisällä (tausta = lähin peittävä taustaväri)
async function contrast(page, sel, nth = 0) {
  return page.evaluate(([sel, nth]) => {
    const el = document.querySelectorAll(sel)[nth]; if (!el) return null;
    const parse = (c) => { const m = c.match(/rgba?\(([^)]+)\)/); const [r, g, b, a = 1] = m[1].split(',').map(Number); return { r, g, b, a }; };
    const lin = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; };
    const L = ({ r, g, b }) => 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
    let bg = { r: 244, g: 239, b: 231 }, chain = [];
    for (let n = el; n; n = n.parentElement) { const c = parse(getComputedStyle(n).backgroundColor); if (c.a > 0) chain.push(c); if (c.a >= 1) break; }
    for (const c of chain.reverse()) bg = { r: c.r * c.a + bg.r * (1 - c.a), g: c.g * c.a + bg.g * (1 - c.a), b: c.b * c.a + bg.b * (1 - c.a) };
    const fg = parse(getComputedStyle(el).color), l1 = L(fg), l2 = L(bg);
    return +((Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05)).toFixed(2);
  }, [sel, nth]);
}
const box = async (page, sel, nth = 0) => page.locator(sel).nth(nth).boundingBox();

// valitse vapaa päivä (vähintään minAhead päivää tulevaisuudessa); palauttaa päivän tai null
async function pickDay(page, minAhead = 0, skip = 0) {
  const min = addDays(today, minAhead);
  for (let month = 0; month < 3; month++) {
    await page.waitForSelector('.bk-cal-tr .bk-grid');
    const n = await page.locator('.bk-cell.free').count();
    for (let i = 0; i < n; i++) {
      const d = await page.locator('.bk-cell.free').nth(i).getAttribute('data-date');
      if (d < min) continue;
      await page.locator('.bk-cell.free').nth(i).click(); await page.waitForSelector('.bk-times');
      if (skip-- <= 0) return d;
    }
    const next = page.locator('.bk-calnav button').last();
    if (await next.isDisabled()) return null;
    const label = await page.locator('.bk-calnav strong').innerText(); await next.click();
    await page.waitForFunction((l) => document.querySelector('.bk-calnav strong')?.innerText !== l, label);
  }
  return null;
}
const fillForm = async (page, { name = 'Testi Asiakas', email = 'testi@example.com', phone = '0401234567', company = false, note = '' } = {}) => {
  if (company) {
    await page.locator('input[name=kind][value=company]').check();
    await page.fill('#company_name', 'Testi Oy'); await page.fill('#business_id', '0112038-9'); await page.fill('#street', 'Testikatu 1'); await page.fill('#zip', '00100'); await page.fill('#city', 'Helsinki');
  }
  await page.fill('#name', name); await page.fill('#email', email); await page.fill('#phone', phone); if (note) await page.fill('#note', note);
  await page.check('#bk-terms');
};
// koko kulku käyttöliittymän kautta; palauttaa { token, d, time, persons }. stopAt: 'review' → ei vahvisteta
async function book(page, { lang = 'fi', slug = 'saunotus-2', n = 1, minAhead = 0, skip = 0, shots, ...form } = {}) {
  await fresh(page, `${shop(lang)}#/tuote/${slug}`);
  await page.waitForSelector('.bk-picker .bk-grid');
  for (let i = 1; i < n; i++) await page.locator('.bk-step').last().click();
  await page.waitForSelector('.bk-cal-tr .bk-grid');
  const d = await pickDay(page, minAhead, skip);
  if (!d) return null;
  const time = (await page.locator('.bk-time-btn').first().innerText()).match(/\d\d:\d\d/)[0];
  await page.locator('.bk-time-btn').first().click();
  if (shots?.product) await shot(page, shots.product);
  await page.locator('.bk-continue .btn').click(); await page.waitForSelector('.bk-form');
  if (shots?.form) await shot(page, shots.form);
  await fillForm(page, form);
  await page.locator('.bk-form button[type=submit]').click(); await page.waitForSelector('.bk-review');
  if (shots?.review) await shot(page, shots.review);
  if (form.stopAt === 'review') return { d, time };
  await page.locator('.bk-review .bk-actions .btn:not(.light)').click();
  await Promise.race([page.waitForURL(/(vahvistus|confirmation)\/#/), page.waitForSelector('#bk-rmsg .bk-error')]);
  if (!/#[0-9a-f-]{36}/.test(page.url())) return { d, time, failed: true };
  await page.waitForSelector('.bk-conf');
  return { token: page.url().split('#')[1], d, time };
}

if (OFF) {
  // ===== Tuotanto ennen lippuja: ei hoitotuotteita katalogissa → "ota yhteyttä", ei virheitä =====
  const page = await newPage({ width: 390 }, {}, 'off');
  await fresh(page, shop('fi')); await page.waitForSelector('.bk-cards');
  expect((await page.locator('.bk-tabs a').allInnerTexts()).every((x) => !/hoidot/i.test(x)), 'off: Hoidot-välilehti näkyy vaikka tuotteet ovat piilossa');
  for (const hash of ['#/tuote/saunotus-2', '#/hoito/saunotus-2/2026-10-24/1700?n=1', '#/tuote/saunotusrituaali']) {
    await page.goto(`${shop('fi')}${hash}`);
    await page.waitForSelector('.bk-notice');
    expect(await page.locator('.bk-notice a[href^="tel:"]').count() === 1, `off ${hash}: puhelinlinkki puuttuu ("ota yhteyttä")`);
    expect((await page.locator('#booking-app .bk-picker, #booking-app .bk-form').count()) === 0, `off ${hash}: varauskulku näkyy piilotetulle tuotteelle`);
    expect((await page.locator('h1').first().innerText()).length > 0, `off ${hash}: otsikko puuttuu`);
  }
  { let n = 0; page.on('request', (r) => { if (/public_treatment/.test(r.url())) n++; });
    await fresh(page, `${shop('fi')}#/paiva/${addDays(today, 2)}`); await page.waitForSelector('.bk-dayresults');
    expect((await page.locator('.bk-treat-day').count()) === 0 && n === 0, `off: päivänäkymässä hoito-osio tai hoitohaku (${n})`); }
  await shot(page, 'shop-mobile-9i-hoito-ota-yhteytta.png');
  await page.ctx.close();
} else {
  // ===== 1) Tuotelista + tuotesivut + säännöt (päivät, ajat, henkilömäärät) =====
  for (const [name, vp] of [['mobile', { width: 390, height: 844 }], ['desktop', { width: 1280, height: 900 }]]) {
    const page = await newPage(vp, {}, `hoito-${name}`);
    await fresh(page, `${shop('fi')}#/?k=hoito`); await page.waitForSelector('.bk-cards');
    const tabs = await page.locator('.bk-tabs a').allInnerTexts();
    expect(tabs.some((x) => /hoidot ja rituaalit/i.test(x)), `${name}: Hoidot ja rituaalit -välilehti puuttuu (${tabs})`);
    const names = await page.locator('.bk-card h3').allInnerTexts();
    // Saunotusrituaali (kb 8) ei ole listalla (booking_159: vain lisätuote); tuotesivu #/tuote/saunotusrituaali toimii (alla HERO-silmukka)
    expect(names.join('|') === 'Saunahoito|Saunotus|Syväsaunotus|Saunarituaali ja savusaunavuoro (la & su)', `${name}: hoitokortit ${names}`);
    expect(names.length === 4, `${name}: hoitokortteja pitää olla 4 (3 + paketti kb 7), nyt ${names.length}`);
    await page.evaluate(async () => { for (const i of document.querySelectorAll('.bk-card img')) { i.scrollIntoView(); if (!i.complete) await new Promise((r) => { i.onload = i.onerror = r; }); } window.scrollTo(0, 0); });
    expect((await page.locator('.bk-card .card-img img').evaluateAll((els) => els.filter((e) => e.complete && e.naturalWidth > 0).length)) === 3, `${name}: hoitokorttien kuvat (3 kuvallista; paketilla ei kuvaa) eivät ole kaikki ladattu`);
    await hscroll(page, `${name} hoitolista`);
    await shot(page, `shop-${name}-9-hoidot-lista.png`);
    // kategorialistan "Kaikki" sisältää myös hoidot ja vanhat vuorotuotteet säilyvät
    await fresh(page, `${shop('fi')}#/?k=all`); await page.waitForSelector('.bk-cards');
    expect((await page.locator('.bk-card').count()) > 4 && (await page.locator('.bk-card h3', { hasText: 'Syväsaunotus' }).count()) === 1 && (await page.locator('.bk-card h3', { hasText: 'Saunotusrituaali' }).count()) === 0, `${name}: Kaikki-listalla pitää olla vuorotuotteet ja hoidot (ei Saunotusrituaalia, booking_159)`);

    for (const slug of Object.keys(HERO)) {
      await fresh(page, `${shop('fi')}#/tuote/${slug}`);
      await page.waitForSelector('.bk-picker');
      expect((await page.locator('main .hero.page h1').innerText()) === HERO[slug], `${name} ${slug}: hero-otsikko ei ole tuotteen nimi`);
      expect(await page.locator('main .hero.page.has-prod').count() === (slug === 'saunarituaali-ja-savusaunavuoro' ? 0 : 1), `${name} ${slug}: tuotekuva herona (paketilla ei kuvaa → oletushero)`);
      expect((await page.locator('.bk-picker h3').allInnerTexts()).map((x) => x.replace(/^\d\s*/, '').trim()).join('|').startsWith('Henkilömäärä|Valitse päivä|Valitse kellonaika'), `${name} ${slug}: vaiheotsikot`);
      { const bt = await page.locator('#booking-app').innerText(); expect((await page.locator('.bk-tr-info').count()) === 0 && !/ei perjantaisin|not on Fridays|Visma Pay|14 päivän|up to 14 days|viimeistään klo|Maksu paikan päällä|Payment on site|vain viikonloppuisin|weekends only/i.test(bt), `${name} ${slug}: tuotesivulla on poistettu infoteksti (tai maksuohje)`); }   // säännöt toimivat koodissa (alla), mutta infolaatikkoa ei näytetä
      // henkilömäärä: yläraja = max
      let n = 1; const plus = page.locator('.bk-step').last();
      while (!(await plus.isDisabled()) && n < 10) { await plus.click(); n++; }
      expect(n === MAXP[slug] && (await page.locator('#tr-n').inputValue()) === String(MAXP[slug]), `${name} ${slug}: henkilömäärän yläraja ${n} (odotettu ${MAXP[slug]})`);
      while (n > 1) { await page.locator('.bk-step').first().click(); n--; }
      await page.waitForSelector('.bk-cal-tr .bk-grid');
      // säännöt kaikille vapaille päiville ja ajoille
      let days = 0;
      for (let month = 0; month < 2; month++) {
        const cnt = await page.locator('.bk-cell.free').count();
        for (let i = 0; i < cnt; i++) {
          const d = await page.locator('.bk-cell.free').nth(i).getAttribute('data-date'); await page.locator('.bk-cell.free').nth(i).click(); await page.waitForSelector('.bk-times'); days++;
          expect(d >= today && d <= addDays(today, 14), `${name} ${slug} ${d}: päivä varausikkunan (14 pv) ulkopuolella`);
          expect(dow(d) !== 5, `${name} ${slug} ${d}: perjantaille tarjotaan aikoja`);
          const we = [0, 6].includes(dow(d));
          if (RITUAL_SLUGS.includes(slug)) expect(we, `${name} ${slug} ${d}: arkipäivälle tarjotaan rituaalia/pakettia`);
          for (const tx of await page.locator('.bk-time-btn').allInnerTexts()) {
            const [s, e] = hms(tx);
            expect(s >= (we ? '13:00' : '16:00'), `${name} ${slug} ${d}: alkuaika ${s} ikkunan ulkopuolella`);
            expect(!e || e <= '20:30', `${name} ${slug} ${d}: loppu ${e} yli 20:30`);
            if (RITUAL_SLUGS.includes(slug)) expect(['16:00', '16:30', '17:00'].includes(s), `${name} ${slug} ${d}: alkuaika ${s}`);
          }
        }
        const next = page.locator('.bk-calnav button').last(); if (await next.isDisabled()) break;
        const label = await page.locator('.bk-calnav strong').innerText(); await next.click(); await page.waitForFunction((l) => document.querySelector('.bk-calnav strong')?.innerText !== l, label);
      }
      expect(days > 0 || RITUAL_SLUGS.includes(slug), `${name} ${slug}: ei yhtään vapaata päivää (14 pv)`);
    }
    await page.ctx.close();
  }

  // ===== 2) Koko kulku: mobiili 390 + desktop 1280 (FI) =====
  const flows = {};
  for (const [name, vp] of [['mobile', { width: 390, height: 844 }], ['desktop', { width: 1280, height: 900 }]]) {
    const page = await newPage(vp, {}, `kulku-${name}`);
    // lataus näkyy (hidastettu saatavuushaku) + välimuisti: sama henkilömäärä/jakso ei hae uudelleen; ei pollausta
    let avail = 0;
    await page.route('**/rpc/public_treatment_availability', async (r) => { avail++; await new Promise((x) => setTimeout(x, 700)); r.continue(); });
    await fresh(page, `${shop('fi')}#/tuote/saunotus-2`, false);
    await page.waitForSelector('.bk-cal-tr .bk-loading', { timeout: 3000 }).then(() => expect(true, ''), () => expect(false, `${name}: latausindikaattori puuttuu saatavuushaun aikana`));
    await page.waitForSelector('.bk-cal-tr .bk-grid');
    const a1 = avail;
    await page.locator('.bk-step').last().click(); await page.waitForSelector('.bk-cal-tr .bk-grid'); const a2 = avail;
    await page.locator('.bk-step').first().click(); await page.waitForSelector('.bk-cal-tr .bk-grid'); const a3 = avail;
    expect(a2 > a1 && a3 === a2, `${name}: saatavuuden välimuisti (haut ${a1}/${a2}/${a3}; henkilömäärän palautus ei saa hakea uudelleen)`);
    await page.waitForTimeout(2500); expect(avail === a3, `${name}: saatavuutta pollataan (${avail} vs ${a3})`);
    await page.unroute('**/rpc/public_treatment_availability');

    // vaihe 1–3 + saavutettavuus/mitat
    const d0 = await pickDay(page, 3);
    expect(!!d0, `${name}: ei vapaata päivää ≥ 3 pv päässä`);
    expect(await page.locator('.bk-continue .btn').isDisabled(), `${name}: Jatka-painike aktiivinen ennen kellonajan valintaa`);
    await page.locator('.bk-time-btn').first().click();
    expect(await page.locator('.bk-time-btn[aria-pressed=true]').count() === 1 && !(await page.locator('.bk-continue .btn').isDisabled()), `${name}: kellonajan valinta (aria-pressed / Jatka)`);
    expect(/Valittu:/.test(await page.locator('.bk-pick-sum').innerText()) && /210/.test(await page.locator('.bk-pick-sum').innerText()), `${name}: valintayhteenveto/hinta`);
    expect(await page.locator('.bk-cell.sel[aria-pressed=true]').count() === 1, `${name}: valittu päivä ei merkitty`);
    for (const [sel, label] of [['.bk-cell.free', 'päivä'], ['.bk-time-btn', 'kellonaika'], ['.bk-step', 'henkilömäärä +/−'], ['.bk-calnav button', 'kuukausinuoli'], ['.bk-continue .btn', 'Jatka']]) {
      const b = await box(page, sel); expect(b && b.width >= 44 && b.height >= 44, `${name}: ${label} tap-alue < 44 px (${b?.width}×${b?.height})`);
    }
    for (const [sel, nth, min, label] of [['.bk-time-btn', 0, 4.5, 'kellonaika (valittu)'], ['.bk-time-btn', 1, 4.5, 'kellonaika'], ['.bk-stepn', 0, 4.5, 'vaiheen numero'], ['.bk-cell.free', 0, 4.5, 'vapaa päivä'], ['.bk-cell.sel', 0, 4.5, 'valittu päivä'], ['.bk-note', 0, 4.5, 'muistiinpano'], ['.bk-hint', 0, 4.5, 'vihje'], ['.bk-pick-sum', 0, 4.5, 'valintayhteenveto'], ['.bk-continue .btn', 0, 4.5, 'Jatka']]) {
      const c = await contrast(page, sel, nth); if (c != null) expect(c >= min, `${name}: kontrasti ${label} ${c}:1 < ${min}`);
    }
    await page.keyboard.press('Shift+Tab'); for (let i = 0; i < 60 && !(await page.evaluate(() => document.activeElement?.classList.contains('bk-time-btn'))); i++) await page.keyboard.press('Tab');   // näppäimistöllä → focus-visible
    const outline = await page.evaluate(() => { const s = getComputedStyle(document.activeElement); return { w: parseFloat(s.outlineWidth), st: s.outlineStyle }; });
    expect(outline.w >= 2 && outline.st !== 'none', `${name}: fokus ei näy kellonaikapainikkeessa`);
    expect(await page.locator('.bk-times').evaluate((e) => e.closest('[aria-live]') != null), `${name}: aikalista ei ole aria-live-alueessa`);
    await hscroll(page, `${name} tuotesivu`);
    const sel = hp(page); expect(sel.get('n') === '1' && sel.get('d') === d0 && /^\d{4}$/.test(sel.get('t') || ''), `${name}: valinta ei tallennu URL:iin (${page.url()})`);
    await shot(page, `shop-${name}-9b-hoito-tuotesivu.png`);
    // tuotesivulle palaus (URL:n valinta palautuu)
    await page.waitForLoadState('networkidle'); await page.reload(); await page.waitForSelector('.bk-time-btn[aria-pressed=true]');

    // lomake
    await page.locator('.bk-continue .btn').click(); await page.waitForSelector('.bk-form');
    expect(/Valittu aika/.test(await page.locator('.bk-pick').getAttribute('aria-label')) && (await page.locator('.bk-pick-name').innerText()) === 'Saunotus', `${name}: lomakkeen valintapalkki`);
    expect((await page.locator('.bk-pick .bk-img img').count()) === 1, `${name}: tuotekuva puuttuu valintapalkista`);
    expect((await page.locator('.bk-sum').first().innerText()).replace(/\s+/g, ' ').toLowerCase().includes('henkilömäärä 1'), `${name}: yhteenveto (henkilömäärä)`);
    await hscroll(page, `${name} lomake`);
    await shot(page, `shop-${name}-9c-hoito-lomake.png`);
    await page.locator('.bk-form button[type=submit]').click();
    expect(/Täytä kaikki pakolliset kentät/.test(await page.locator('#bk-msg').innerText()) && (await page.locator('#bk-msg .bk-error[role=alert]').count()) === 1, `${name}: tyhjän lomakkeen virheilmoitus`);
    await page.fill('#name', 'Testi Asiakas'); await page.fill('#email', 'testi@example.com'); await page.fill('#phone', '0401234567');
    await page.locator('.bk-form button[type=submit]').click();
    expect(/Hyväksy ehdot/.test(await page.locator('#bk-msg').innerText()), `${name}: ehtojen hyväksymättä jättö`);
    await page.locator('input[name=kind][value=company]').check();
    expect(await page.locator('#bk-company').isVisible(), `${name}: yritystiedot eivät avaudu`);
    await page.locator('input[name=kind][value=private]').check();
    await page.check('#bk-terms'); await page.fill('#note', 'Allergia: pähkinä');
    await page.locator('.bk-form button[type=submit]').click(); await page.waitForSelector('.bk-review');
    const rv = (await page.locator('.bk-review').innerText()).replace(/\s+/g, ' ').toLowerCase();
    for (const needle of ['Saunotus', 'Henkilömäärä 1', 'Testi Asiakas', 'testi@example.com', '0401234567', 'Allergia: pähkinä', '210']) expect(rv.includes(needle.toLowerCase()), `${name}: vahvistusvaiheesta puuttuu "${needle}"`);
    expect(!/visma pay|maksu paikan päällä\./i.test(rv), `${name}: vahvistusvaiheessa on poistettu maksuohje`);
    expect(!/saunottaja|therapist/i.test(rv), `${name}: saunottajatieto näkyy asiakkaalle`);
    expect(await page.locator('.bk-tr-top').isHidden() && (await page.locator('#tr-review-h').evaluate((e) => e === document.activeElement)), `${name}: vahvistusvaiheen otsikko/fokus`);
    await hscroll(page, `${name} vahvistusvaihe`);
    await shot(page, `shop-${name}-9d-hoito-vahvistus.png`);
    await page.getByRole('button', { name: 'Muokkaa tietoja' }).click();
    expect((await page.inputValue('#name')) === 'Testi Asiakas' && await page.locator('#bk-terms').isChecked(), `${name}: Muokkaa tietoja ei säilytä tietoja`);
    await page.locator('.bk-form button[type=submit]').click(); await page.waitForSelector('.bk-review');
    await page.getByRole('button', { name: 'Vahvista varaus' }).click();
    await page.waitForURL(/vahvistus\/#/); await page.waitForSelector('.bk-conf');
    const token = page.url().split('#')[1];
    // vahvistussivu
    const cf = (await page.locator('.bk-conf').innerText()).replace(/\s+/g, ' ');
    const cfl = cf.toLowerCase();
    for (const needle of ['Saunotus', 'Henkilömäärä', 'Muuta varausta']) expect(cfl.includes(needle.toLowerCase()) || (await page.getByRole('link', { name: needle }).count()) > 0, `${name}: vahvistussivulta puuttuu "${needle}"`);
    expect(!/visma pay|maksu paikan päällä\./i.test(cf), `${name}: vahvistussivulla on poistettu maksuohje`);
    expect(/9\d{3}/.test(cf), `${name}: varaustunnus puuttuu vahvistussivulta`);
    expect((await page.getByRole('button', { name: /peru/i }).count()) === 0 && (await page.getByRole('link', { name: /peru/i }).count()) === 0, `${name}: asiakas voi perua itse`);
    expect(/48/.test(cf) && /peruutus|ota yhteyttä sähköpostilla|Varauksen peruutus/i.test(cf), `${name}: muutos-/peruutusohje puuttuu`);
    await hscroll(page, `${name} vahvistussivu`);
    await shot(page, `shop-${name}-9e-hoito-vahvistussivu.png`);
    flows[name] = { token, d: d0 };
    // muutos (≥ 48 h): toinen aika, tallenna, vahvistussivu päivittyy
    const before = (await page.locator('.bk-conf .bk-sum dd').nth(2).innerText()).replace(/\s+/g, ' ');
    await page.getByRole('link', { name: 'Muuta varausta' }).click(); await page.waitForSelector('.bk-picker .bk-grid');
    expect(await page.locator('.bk-picker .bk-step-box').count() === 3 && /Muuta varausta/.test(await page.locator('#booking-app h2').first().innerText()), `${name}: muutosnäkymä`);
    expect(await page.locator('#booking-app .bk-continue .btn').isDisabled(), `${name}: Tallenna muutos aktiivinen ennen muutosta`);
    const dChange = await pickDay(page, 3, 1);
    expect(!!dChange, `${name}: muutokselle ei löytynyt päivää`);
    // muutoksessa ei tarjota aikoja alle 48 h päässä
    expect(!dChange || dChange >= addDays(today, 2), `${name}: muutoksessa tarjotaan alle 48 h päässä oleva päivä ${dChange}`);
    await page.locator('.bk-time-btn').first().click();
    await hscroll(page, `${name} muutosnäkymä`);
    await shot(page, `shop-${name}-9f-hoito-muutos.png`);
    await page.locator('#booking-app .bk-continue .btn').click();
    await page.waitForSelector('.bk-conf .bk-sum');
    const after = (await page.locator('.bk-conf .bk-sum dd').nth(2).innerText()).replace(/\s+/g, ' ');
    expect(before !== after, `${name}: muutos ei päivittänyt aikaa (${before} → ${after})`);
    await page.ctx.close();
  }

  // ===== 2b) Saatavuushaut: yksi kerrallaan (oikea palvelin vastaa rinnakkaisiin 'busy'), väli ≤ 14 pv, nopea +/+ ei tee turhia hakuja =====
  {
    const page = await newPage({ width: 390, height: 844 }, {}, 'haut');
    let inflight = 0, maxIn = 0; const bodies = [];
    await page.route('**/rpc/public_treatment_availability', async (r) => { inflight++; maxIn = Math.max(maxIn, inflight); bodies.push(r.request().postDataJSON()); await new Promise((x) => setTimeout(x, 300)); inflight--; r.continue(); });
    await fresh(page, `${shop('fi')}#/tuote/saunahoito-2`); await page.waitForSelector('.bk-cal-tr .bk-grid');
    const n0 = bodies.length;
    expect(n0 === 1, `haut: tuotesivun avaus tekee ${n0} saatavuushakua (odotettu 1)`);
    for (let i = 0; i < 3; i++) await page.locator('.bk-step').last().click();   // nopea 1→4
    await page.waitForSelector('.bk-cal-tr .bk-grid'); await page.waitForTimeout(800);
    expect(bodies.length === n0 + 1 && bodies.at(-1).p_persons === 4, `haut: nopea +/+ → ${bodies.length - n0} hakua (odotettu 1, p_persons 4)`);
    expect(maxIn <= 1, `haut: rinnakkaisia hakuja ${maxIn}`);
    expect(bodies.every((b) => (new Date(b.p_to) - new Date(b.p_from)) / 864e5 <= 14), `haut: väli yli 14 pv ${JSON.stringify(bodies)}`);
    expect(await page.locator('.bk-cal-tr .bk-error').count() === 0, 'haut: virhe nopean +/+ jälkeen');
    await page.ctx.close();
  }

  // ===== 2c) Päivänäkymä (#/paiva/<pvm>): hoidot ja rituaali mukana, vain sinä päivänä vapaat tuotteet; haut välimuistista; FI+EN; asettelu =====
  for (const [lang, w] of [['fi', 390], ['en', 360], ['fi', 430], ['fi', 1280]]) {
    const page = await newPage({ width: w, height: 844 }, { lang }, `paiva-${lang}-${w}`);
    let avail = 0; await page.route('**/rpc/public_treatment_availability', (r) => { avail++; r.continue(); });
    const dayUrl = (d) => `${shop(lang)}#/paiva/${d}`;
    const settle = async () => { await page.waitForSelector('.bk-dayresults'); await page.waitForFunction(() => !document.querySelector('.bk-treat-status')); };
    await fresh(page, dayUrl(today)); await settle();
    const seen = {};   // slug → päivät
    for (let i = 0; i <= 14; i++) {
      const d = addDays(today, i);
      if (i > 0) { await page.evaluate((x) => { location.hash = `#/paiva/${x}`; }, d); await page.waitForSelector(`.bk-dayresults[data-date="${d}"]`); await settle(); }
      const slugs = await page.locator('.bk-treat-day .bk-pc').evaluateAll((e) => e.map((x) => x.dataset.slug));
      for (const s of slugs) (seen[s] ||= []).push(d);
      expect(!slugs.includes('saunotusrituaali'), `päivä ${lang} ${w} ${d}: Saunotusrituaali päivänäkymän hoitolistalla (booking_159: vain lisätuote)`);
      expect(dow(d) !== 5 || slugs.length === 0, `päivä ${lang} ${w} ${d}: perjantaille tarjotaan hoitoja (${slugs})`);
      if (RITUAL_SLUGS.some((x) => slugs.includes(x))) expect([0, 6].includes(dow(d)), `päivä ${d}: rituaali/paketti arkipäivänä`);
      if (slugs.length) {
        expect(await page.locator('.bk-treat-day .bk-pc.open').count() === 0 && (await page.locator('.bk-treat-day .bk-slotlist:visible').count()) === 0, `päivä ${d}: hoitokortit pitää olla oletuksena suljettuja (ensin tuote, sitten ajat)`);
        expect(await page.locator('.bk-treat-day .bk-pc-head').first().getAttribute('aria-expanded') === 'false', `päivä ${d}: aria-expanded`);
      } else expect(await page.locator('.bk-treat-day').count() === 0, `päivä ${d}: tyhjä hoito-osio näkyy`);
    }
    expect(Object.keys(seen).length >= 3, `päivänäkymä ${lang} ${w}: hoitotuotteita löytyi vain ${Object.keys(seen)}`);
    if (lang === 'fi' && w === 390) {
      // vastaa tuotesivun saatavuutta (henkilömäärä 1) ja käyttää samaa välimuistia
      const before = avail;
      for (const [slug, days] of Object.entries(seen)) {
        await page.evaluate((s) => { location.hash = `#/tuote/${s}`; }, slug); await page.waitForSelector('.bk-cal-tr .bk-grid');
        const cells = new Set(); for (let m = 0; m < 2; m++) { for (const x of await page.locator('.bk-cell.free').evaluateAll((el) => el.map((q) => q.dataset.date))) cells.add(x); const nx = page.locator('.bk-calnav button').last(); if (await nx.isDisabled()) break; const lb = await page.locator('.bk-calnav strong').innerText(); await nx.click(); await page.waitForFunction((l) => document.querySelector('.bk-calnav strong')?.innerText !== l, lb); }
        expect([...cells].sort().join() === days.slice().sort().join(), `${slug}: päivänäkymän päivät ${days} ≠ tuotesivun vapaat päivät ${[...cells].sort()}`);
      }
      expect(avail - before === 0, `haut: tuotesivut hakivat uudelleen päivänäkymän jälkeen (${avail - before} hakua; välimuisti kattaa)`);
    }
    expect(avail <= 5, `päivänäkymä ${lang} ${w}: ${avail} saatavuushakua koko 15 päivän selauksessa (odotettu ≤ 5, yksi / tuote)`);
    // kortin avaus → ajat → Valitse vie hoitovarausvirtaan esivalitulla päivällä ja ajalla
    const d1 = Object.values(seen)[0][0], s1 = Object.keys(seen)[0];
    await page.goto('about:blank').catch(() => {}); await fresh(page, dayUrl(d1)); await settle();
    const card = page.locator(`.bk-treat-day .bk-pc[data-slug="${s1}"]`);
    await card.locator('.bk-pc-head').click();
    expect(await card.locator('.bk-slotlist').isVisible() && (await card.locator('.bk-pc-head').getAttribute('aria-expanded')) === 'true' && page.url().includes(`?tuote=${s1}`), `päivä ${lang} ${w}: kortin avaus (${page.url()})`);
    const tTok = (await card.locator('.bk-slot .btn').first().getAttribute('href')).match(/[?&]t=(\d{4})/)[1], firstTime = `${tTok.slice(0, 2)}:${tTok.slice(2)}`;   // Valitse-linkin aika (näyttö: 13–14 / 13:30–14:30)
    expect(new RegExp(`^${+tTok.slice(0, 2)}(?:[:.]${tTok.slice(2)})?\\D`).test((await card.locator('.bk-time').first().innerText()).trim() + ' ') || tTok.slice(2) !== '00' || /^\d+[–-]/.test((await card.locator('.bk-time').first().innerText()).trim()), `päivä ${lang} ${w}: aikarivi ei vastaa linkkiä`);
    for (const [sel, label] of [['.bk-treat-day .bk-pc-head', 'korttipainike'], ['.bk-treat-day .bk-slot .btn', 'Valitse']]) { const b = await box(page, sel); expect(b && b.height >= 44 && b.width >= 44, `päivä ${lang} ${w}: ${label} tap-alue ${b?.width}×${b?.height}`); }
    for (const [sel, label] of [['.bk-treat-day .bk-pc-name', 'nimi'], ['.bk-treat-day .bk-pc-desc', 'kuvaus'], ['.bk-treat-day .bk-time', 'kellonaika'], ['.bk-treat-day .bk-price', 'hinta'], ['.bk-treat-day .bk-kindh', 'otsikko'], ['.bk-treat-day .bk-slot .btn', 'Valitse-painike']]) { const c = await contrast(page, sel); if (c != null) expect(c >= 4.5, `päivä ${lang} ${w}: kontrasti ${label} ${c}:1`); }
    await hscroll(page, `päivänäkymä ${lang} ${w}`);
    if (lang === 'en') expect(/^treatments and rituals$/i.test(await page.locator('.bk-treat-day .bk-kindh').innerText()) && /choose|select/i.test(await card.locator('.bk-slot .btn').first().innerText()), 'päivä en: otsikko/painike');
    await shot(page, `paiva-${lang}-${w}-hoidot.png`);
    await card.locator('.bk-slot .btn').first().click();
    await page.waitForSelector('.bk-picker .bk-time-btn[aria-pressed=true]');
    const q = hp(page);
    expect(q.get('d') === d1 && q.get('t') === firstTime.replace(':', '') && q.get('n') === '1', `päivä ${lang} ${w}: Valitse ei vie esivalittuun päivään/aikaan (${page.url()})`);
    expect(!(await page.locator('.bk-continue .btn').isDisabled()) && (await page.locator('.bk-time-btn[aria-pressed=true]').innerText()).includes(firstTime), `päivä ${lang} ${w}: esivalinta tuotesivulla (${firstTime})`);
    await hscroll(page, `päivä→tuotesivu ${lang} ${w}`);
    await page.ctx.close();
  }
  {   // latausindikaattori, virhe + uudelleenyritys, hoitokortin syväosoite
    const page = await newPage({ width: 390, height: 844 }, { allow: [/public_treatment_availability/, /status of 4\d\d/] }, 'paiva-tila');
    await page.route('**/rpc/public_treatment_availability', async (r) => { await new Promise((x) => setTimeout(x, 700)); r.continue(); });
    await fresh(page, `${shop('fi')}#/paiva/${addDays(today, 1)}`, false);
    await page.waitForSelector('.bk-treat-status', { timeout: 5000 }).then(() => expect(true, ''), () => expect(false, 'päivä: hoitohaun latausindikaattori puuttuu'));
    expect(/Haetaan|Ladataan/.test(await page.locator('.bk-treat-status').innerText().catch(() => 'Ladataan')), 'päivä: latausteksti');
    await page.waitForFunction(() => !document.querySelector('.bk-treat-status'), null, { timeout: 20000 });
    await page.unroute('**/rpc/public_treatment_availability');
    await page.route('**/rpc/public_treatment_availability', (r) => r.fulfill({ status: 400, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' }, body: JSON.stringify({ code: 'BK001', message: 'x', details: 'rate_limited', hint: null }) }));
    await fresh(page, `${shop('fi')}#/paiva/${addDays(today, 2)}`); await page.waitForSelector('.bk-dayresults'); await page.waitForFunction(() => !document.querySelector('.bk-treat-status'));
    expect(/kiireinen|Yritä/i.test(await page.locator('.bk-treat-day').innerText()) && (await page.locator('.bk-treat-day button').count()) === 1, 'päivä: virheilmoitus + Yritä uudelleen puuttuu hoito-osiosta');
    await page.unroute('**/rpc/public_treatment_availability');
    await page.locator('.bk-treat-day button').click(); await page.waitForFunction(() => !document.querySelector('.bk-treat-status'));
    await page.ctx.close();
  }

  // ===== 3) Virhetilanteet, yritysasiakas, lukittu muutos, lataus/uudelleenyritys =====
  {
    const page = await newPage({ width: 390, height: 844 }, { allow: [/public_treatment_availability/] }, 'virheet');
    // aika ehti mennä (slot_unavailable) → viesti + "Valitse toinen aika" → takaisin valintaan samalla henkilömäärällä
    const r1 = await book(page, { slug: 'saunahoito-2', email: 'taken@test.fi', minAhead: 1 });
    expect(r1?.failed && /ei ole enää vapaana/.test(await page.locator('#bk-rmsg').innerText()), 'virhe: slot_unavailable-viesti puuttuu');
    await shot(page, 'shop-mobile-9h-hoito-aika-varattu.png');
    await page.locator('#bk-rmsg a.btn').click(); await page.waitForSelector('.bk-picker .bk-grid');
    expect(/^\/?#\/tuote\/saunahoito-2/.test(new URL(page.url()).hash.replace('#', '#/').replace('#//', '#/')) || /#\/tuote\/saunahoito-2/.test(page.url()), `virhe: paluulinkki ${page.url()}`);
    // aikaikkunavirhe palvelimelta
    const r2 = await book(page, { slug: 'saunahoito-2', email: 'time_window@test.fi', minAhead: 1 });
    expect(r2?.failed && /varausaikojen sisällä/.test(await page.locator('#bk-rmsg').innerText()), 'virhe: time_window-viesti puuttuu');
    expect(!/null|undefined/.test(await page.locator('#bk-rmsg').innerText()), 'virhe: virheviestin perässä teksti "null"');
    // saatavuushaun virhe (rate_limited / busy) → viesti + Yritä uudelleen
    await page.route('**/rpc/public_treatment_availability', (r) => r.fulfill({ status: 400, contentType: 'application/json', body: JSON.stringify({ code: 'BK001', message: 'Liian kiireinen', details: 'busy', hint: null }) }));
    await fresh(page, `${shop('fi')}#/tuote/saunotus-2`);
    await page.waitForSelector('.bk-cal-tr .bk-error');
    expect(/kiireinen/.test(await page.locator('.bk-cal-tr .bk-error').innerText()), 'virhe: busy-viesti');
    await page.unroute('**/rpc/public_treatment_availability');
    await page.getByRole('button', { name: 'Yritä uudelleen' }).click(); await page.waitForSelector('.bk-cal-tr .bk-grid');
    expect(await page.locator('.bk-cell.free').count() > 0, 'virhe: uudelleenyritys ei lataa kalenteria');
    // vahvistamaton/virheellinen varauslinkki
    await fresh(page, `${BASE}/varaa/vahvistus/#00000000-0000-4000-8000-000000000000`); await page.waitForSelector('.bk-error');
    await page.ctx.close();

    // yritysasiakas desktopilla
    const pd = await newPage({ width: 1280, height: 900 }, {}, 'yritys');
    const c = await book(pd, { slug: 'syvasaunotus', company: true, email: 'yritys@example.com', minAhead: 3, n: 2 });
    expect(c?.token && /(laskutetaan|Yritysasiakkaalle|invoice|lasku)/i.test(await pd.locator('.bk-conf').innerText()), 'yritys: laskutusohje puuttuu vahvistussivulta');
    expect(/2/.test(await pd.locator('.bk-conf .bk-sum').innerText()) && /(290|350|360)/.test(await pd.locator('.bk-conf').innerText()), 'yritys: henkilömäärä/hinta (2 hlö)');
    await pd.ctx.close();

    // alle 48 h → muutosta ei tarjota
    const pl = await newPage({ width: 390, height: 844 }, {}, 'lukittu');
    const l = await book(pl, { slug: 'saunahoito-2', email: 'locked@test.fi', minAhead: 0 });
    expect(l?.token && (await pl.getByRole('link', { name: 'Muuta varausta' }).count()) === 0 && /ei voi enää muuttaa verkossa/.test(await pl.locator('.bk-conf').innerText()), 'lukittu: muutos tarjolla alle 48 h varaukselle');
    await fresh(pl, `${BASE}/varaa/vahvistus/#${l.token}/muuta`); await pl.waitForSelector('.bk-conf');
    expect(await pl.locator('.bk-picker').count() === 0, 'lukittu: muutosnäkymä aukeaa vaikka muutos ei ole sallittu');
    await pl.ctx.close();
  }

  // ===== 4) EN =====
  {
    const page = await newPage({ width: 390, height: 844 }, { lang: 'en' }, 'en');
    await page.goto(`${shop('en')}#/?k=hoito`); await page.waitForSelector('.bk-cards');
    expect((await page.locator('.bk-tabs a').allInnerTexts()).some((x) => /treatments and rituals/i.test(x)), 'en: välilehti Treatments and rituals puuttuu');
    expect((await page.locator('.bk-card h3').allInnerTexts()).includes('Sauna treatment'), 'en: tuotteen englanninkielinen nimi puuttuu');
    const b = await book(page, { lang: 'en', slug: 'saunahoito-2', minAhead: 3, n: 2, shots: { product: 'shop-mobile-en-9b-hoito-tuotesivu.png', review: 'shop-mobile-en-9d-hoito-vahvistus.png' } });
    expect(b?.token, 'en: varaus ei onnistunut');
    const tx = (await page.locator('.bk-conf').innerText()).replace(/\s+/g, ' ');
    expect(!/Visma Pay|Payment on site/.test(tx) && /Sauna treatment/.test(tx) && /Booking confirmation|Thank you|confirmed/i.test(tx), `en: vahvistussivun tekstit (${tx.slice(0, 120)})`);
    expect(!/(henkilömäärä|maksu paikan|varaus)/i.test(tx), 'en: vahvistussivulla suomenkielistä tekstiä');
    await shot(page, 'shop-mobile-en-9e-hoito-vahvistussivu.png');
    // EN-tuotesivun vaiheet
    await fresh(page, `${shop('en')}#/tuote/saunotusrituaali`); await page.waitForSelector('.bk-picker');
    expect((await page.locator('.bk-picker h3').allInnerTexts()).map((x) => x.replace(/^\d\s*/, '').trim()).join('|') === 'Guests|Pick a date|Pick a time', 'en: vaiheotsikot');
    expect((await page.locator('.bk-tr-info').count()) === 0 && !/Visma Pay|Treatments are available|weekends only/.test(await page.locator('#booking-app').innerText()), 'en: infolaatikko poistettu');
    await page.ctx.close();
  }

  // ===== 5) Asettelu: ei vaakavieritystä 360/390/430/1280 (tuotesivu, lomake, vahvistus, vahvistussivu, muutos) =====
  for (const width of [360, 390, 430, 1280]) {
    const page = await newPage({ width, height: 844 }, {}, `asettelu-${width}`);
    const r = await book(page, { slug: 'saunotus-2', minAhead: 3, stopAt: 'review', company: width === 360 });
    expect(!!r, `asettelu ${width}: kulkua ei voitu viedä vahvistusvaiheeseen`);
    await hscroll(page, `asettelu ${width} vahvistusvaihe`);
    await page.getByRole('button', { name: 'Muokkaa tietoja' }).click(); await hscroll(page, `asettelu ${width} lomake`);
    const widest = await page.evaluate(() => [...document.querySelectorAll('#booking-app *')].filter((e) => e.getBoundingClientRect().right > innerWidth + 1).map((e) => e.className || e.tagName).slice(0, 3));
    expect(widest.length === 0, `asettelu ${width}: elementit ylittävät näkymän ${widest}`);
    await fresh(page, `${shop('fi')}#/tuote/saunotus-2`); await page.waitForSelector('.bk-cal-tr .bk-grid'); await hscroll(page, `asettelu ${width} tuotesivu`);
    for (const f of Object.values(flows)) {
      await fresh(page, `${BASE}/varaa/vahvistus/#${f.token}`); await page.waitForSelector('.bk-conf'); await hscroll(page, `asettelu ${width} vahvistussivu`);
      await fresh(page, `${BASE}/varaa/vahvistus/#${f.token}/muuta`); await page.waitForSelector('.bk-picker .bk-grid'); await hscroll(page, `asettelu ${width} muutos`);
      break;
    }
    await page.ctx.close();
  }
}

await browser.close();
if (problems.length) { console.error(`E2E (hoitovaraus${OFF ? ', off' : ''}) epäonnistui (${problems.length}/${checks + problems.length}):\n- ${[...new Set(problems)].join('\n- ')}`); process.exit(1); }
console.log(`ok: hoito- ja rituaalivaraukset${OFF ? ' (ei lippuja: ota yhteyttä)' : ''} – ${checks} tarkistusta${OUT ? `, kuvat → ${OUT}` : ''}`);
