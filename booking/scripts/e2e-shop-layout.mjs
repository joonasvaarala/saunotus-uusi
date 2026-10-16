// Kaupan varauslomakkeen asettelutesti (v9): ei vaakavieritystä, osiot samassa linjassa, järjestys ja otsikot.
// Käyttö:  PW_DIR=/polku/node_modules node booking/scripts/e2e-shop-layout.mjs   (demo käynnissä, BASE_URL oletus http://localhost:4180)
// Ympäristö: OUT = kuvakaappauskansio (oletus: ei kuvia), CHROME (oletus /usr/bin/google-chrome)
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { mkdirSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';

const require = createRequire(import.meta.url);
const pwPath = require.resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', dirname(fileURLToPath(import.meta.url))].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath));
const chromium = pw.chromium || pw.default.chromium;
const BASE = process.env.BASE_URL || 'http://localhost:4180';
const OUT = process.env.OUT ? resolve(process.env.OUT) : null;
if (OUT) mkdirSync(OUT, { recursive: true });
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const problems = [];
let checks = 0;
const expect = (ok, msg) => { checks++; if (!ok) problems.push(msg); };

for (const lang of ['fi', 'en']) for (const width of [360, 390, 430, 1280]) for (const kind of ['private', 'company']) {
  const tag = `${lang}/${width}/${kind}`;
  const mobile = width < 600;
  const ctx = await browser.newContext({ viewport: { width, height: 844 }, isMobile: mobile, hasTouch: mobile, deviceScaleFactor: 1, locale: lang === 'en' ? 'en-GB' : 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => problems.push(`${tag} pageerror: ${e.message}`));
  await page.goto(`${BASE}${lang === 'en' ? '/en/book/' : '/varaa/'}#/tuote/yleinensauna`);
  await page.waitForSelector('.bk-grid button.bk-cell.free');
  await page.locator('.bk-grid button.bk-cell.free').last().click();
  await page.locator('.bk-slot.available a.btn').last().click();
  await page.waitForSelector('.bk-form .bk-addon');
  await page.locator('.bk-stepper .bk-step[aria-label="+"]').first().click();
  await page.locator('.bk-addon').nth(0).locator('.bk-step').last().click();
  await page.locator('.bk-addon').nth(1).locator('.bk-step').last().click();
  if (kind === 'company') { await page.check('input[name=kind][value=company]'); await page.waitForSelector('#bk-company:not([hidden])'); }
  await page.waitForTimeout(200);
  const r = await page.evaluate(() => {
    const box = (el) => { const b = el.getBoundingClientRect(); return { l: b.left, r: b.right, t: b.top + scrollY, b: b.bottom + scrollY }; };
    const form = document.querySelector('form.bk-form');
    const sections = [...form.querySelectorAll(':scope > fieldset.bk-section')];
    const cards = [...form.querySelectorAll('.bk-addon, .bk-company:not([hidden]), .bk-kinds, .bk-field, .bk-kindrow')];
    const legends = sections.map((s) => s.querySelector(':scope > legend').textContent.trim());
    const addons = form.querySelector('.bk-addons'), persons = sections[0], contact = form.querySelector('.bk-contact');
    return {
      sw: document.documentElement.scrollWidth, iw: innerWidth, form: box(form), legends,
      sections: sections.map(box), cards: cards.map((c) => ({ cls: c.className, ...box(c) })),
      gapPersonsToNext: box(sections[1]).t - box(persons.querySelector('.bk-stepper')).b,
      gapContactToAddons: box(addons).t - box(contact).b,
      addonLegend: box(addons.querySelector('legend')), contactBottom: box(contact).b,
      h2: document.querySelector('#booking-app h2').textContent.trim(),
      texts: [...form.querySelectorAll('legend,h3')].map((e) => e.textContent.trim()),
      order: [...form.children].map((e) => e.className || e.tagName).slice(0, 4),
    };
  });
  expect(r.sw <= r.iw, `${tag}: vaakavieritys (scrollWidth ${r.sw} > ${r.iw})`);
  for (const c of r.cards.filter((x) => x.r > x.l)) expect(c.l >= r.form.l - 0.5 && c.r <= r.form.r + 0.5, `${tag}: ${c.cls} ylittää lomakkeen reunat (${c.l.toFixed(1)}–${c.r.toFixed(1)} vs ${r.form.l.toFixed(1)}–${r.form.r.toFixed(1)})`);
  for (const s of r.sections) expect(Math.abs(s.l - r.form.l) < 0.5 && Math.abs(s.r - r.form.r) < 0.5, `${tag}: osio ei ole lomakkeen levyinen`);
  for (const a of r.cards.filter((c) => /bk-addon$|bk-addon /.test(c.cls))) expect(Math.abs(a.l - r.form.l) < 0.5 && Math.abs(a.r - r.form.r) < 0.5, `${tag}: lisäpalvelukortti ei ole lomakkeen levyinen`);
  expect(r.gapPersonsToNext >= 16, `${tag}: väli henkilömäärästä seuraavaan osioon liian pieni (${r.gapPersonsToNext})`);
  expect(r.gapContactToAddons >= 16, `${tag}: väli yhteystiedoista lisäpalveluihin liian pieni (${r.gapContactToAddons})`);
  expect(r.legends.length === 3, `${tag}: osioita pitää olla 3, oli ${r.legends.length}`);
  const [pn, cn, an] = lang === 'en' ? ['Guests', 'Your details', 'Add-ons'] : ['Henkilömäärä', 'Yhteystiedot', 'Lisäpalvelut'];
  expect(r.legends[0].toLowerCase().startsWith(pn.toLowerCase().slice(0, 5)) && r.legends[1] === cn && r.legends[2] === an, `${tag}: osioiden järjestys/otsikot väärin: ${r.legends.join(' | ')}`);
  expect(r.h2 !== cn, `${tag}: sivun otsikko toistaa osion otsikon "${cn}"`);
  expect(r.texts.filter((x) => x === cn).length === 1, `${tag}: "${cn}" esiintyy useammin kuin kerran lomakkeessa`);
  if (OUT) await page.addStyleTag({ content: 'header.site-header,.site-header,header[class*=head],.topbar{position:static!important}' });   // kiinteä yläpalkki ei peitä kokosivun kuvaa
  if (OUT && lang === 'fi' && width === 390) await page.screenshot({ path: join(OUT, `shop-mobile-390-lisapalvelut-${kind === 'company' ? 'yritys' : 'yksityinen'}.png`), fullPage: true });
  if (OUT && lang === 'en' && width === 390) await page.screenshot({ path: join(OUT, `shop-mobile-390-en-addons-${kind}.png`), fullPage: true });
  if (OUT && lang === 'fi' && width === 1280 && kind === 'company') await page.screenshot({ path: join(OUT, 'shop-desktop-1280-lisapalvelut-yritys.png'), fullPage: true });
  await ctx.close();
}

// ---- Selaa päivän mukaan (#/paiva/<pvm>): asettelu, kosketuskohteet, näppäimistö, kontrasti ----
for (const lang of ['fi', 'en']) for (const width of [360, 390, 430, 1280]) for (const empty of [false, true]) {
  const tag = `päivänäkymä ${lang}/${width}/${empty ? 'tyhjä' : 'vuoroja'}`;
  const mobile = width < 600;
  const ctx = await browser.newContext({ viewport: { width, height: 844 }, isMobile: mobile, hasTouch: mobile, deviceScaleFactor: 1, locale: lang === 'en' ? 'en-GB' : 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => problems.push(`${tag} pageerror: ${e.message}`));
  await page.goto(`${BASE}${lang === 'en' ? '/en/book/' : '/varaa/'}`);
  await page.waitForSelector('.bk-cards');
  await page.click('.bk-modes a:nth-child(2)');
  await page.waitForSelector('.bk-strip');
  if (empty) {   // tyhjä päivä: käydään päivät läpi kunnes ilmoitus löytyy
    for (let i = 0; i < 28 && (await page.locator('.bk-dayresults .bk-notice').count()) === 0; i++) {
      const d = new Date(Date.now() + i * 864e5).toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
      await page.evaluate((x) => { location.hash = `#/paiva/${x}`; }, d); await page.waitForTimeout(250);
    }
    expect((await page.locator('.bk-dayresults .bk-notice').count()) > 0, `${tag}: tyhjää päivää ei löytynyt`);
  } else {
    for (let i = 0; i < 4 && (await page.locator('.bk-sd.free').count()) === 0; i++) await page.click('.bk-weeknav a[aria-label]:last-child');
    await page.locator('.bk-sd.free').last().click(); await page.waitForSelector('.bk-dayresults .bk-slot');
  }
  await page.waitForTimeout(200);
  const r = await page.evaluate(() => {
    const box = (el) => { const b = el.getBoundingClientRect(); return { l: b.left, r: b.right, w: b.width, h: b.height }; };
    const app = box(document.getElementById('booking-app'));
    const rgb = (c) => (c.match(/[\d.]+/g) || []).slice(0, 3).map(Number);
    const lum = (c) => { const [r, g, b] = rgb(c).map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
    const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m); return (x + 0.05) / (y + 0.05); };
    const effBg = (e) => { for (let n = e; n; n = n.parentElement) { const c = getComputedStyle(n).backgroundColor; if (rgb(c).length && !/rgba\(.*,\s*0\)$/.test(c) && c !== 'transparent') return c; } return 'rgb(255,255,255)'; };   // lähin ei-läpinäkyvä tausta
    const cr = (sel) => [...document.querySelectorAll(sel)].map((e) => ({ sel, v: ratio(getComputedStyle(e).color, effBg(e)) }));
    const inside = (sel) => [...document.querySelectorAll(sel)].map((e) => ({ sel, ...box(e) })).filter((b) => b.w > 0);
    return {
      sw: document.documentElement.scrollWidth, iw: innerWidth, app,
      parts: [...inside('.bk-modes'), ...inside('.bk-daypick'), ...inside('.bk-strip'), ...inside('.bk-dayresults'), ...inside('.bk-slot'), ...inside('.bk-notice'), ...inside('.bk-daytools input')],
      strip: [...document.querySelectorAll('.bk-strip .bk-sd')].map(box), nav: [...document.querySelectorAll('.bk-weeknav .bk-navbtn:not(.off)')].map(box),
      btns: [...document.querySelectorAll('.bk-dayresults a.btn, .bk-modes a, .bk-today')].map(box),
      contrast: [...cr('.bk-modes a'), ...cr('.bk-sd.free'), ...cr('.bk-sd.sel'), ...cr('.bk-badge.free'), ...cr('.bk-slot .bk-time'), ...cr('.bk-dayresults a.btn'), ...cr('.bk-today')],
      names: { h2: document.querySelector('#booking-app h2')?.textContent, labelled: [...document.querySelectorAll('.bk-strip a')].every((a) => a.getAttribute('aria-label')), pickLabel: !!document.querySelector('label[for=bk-day-pick]'), current: document.querySelectorAll('.bk-strip [aria-current=date]').length },
    };
  });
  expect(r.sw <= r.iw, `${tag}: vaakavieritys (${r.sw} > ${r.iw})`);
  for (const b of r.parts) expect(b.l >= r.app.l - 0.5 && b.r <= r.app.r + 0.5, `${tag}: ${b.sel} ylittää sisältöalueen (${b.l.toFixed(1)}–${b.r.toFixed(1)} vs ${r.app.l.toFixed(1)}–${r.app.r.toFixed(1)})`);
  expect(r.strip.length === 7 && r.strip.every((b) => Math.abs(b.w - r.strip[0].w) < 1.5 && Math.abs(b.l + b.w - (r.strip[0].l + r.strip[0].w) - (r.strip.indexOf(b) * (r.strip[1].l - r.strip[0].l))) < 1.5 && b.w >= 34 && b.h >= 44), `${tag}: viikkoliuskan päivien pitää olla 7 samanlevyistä ≥34×44 px: ${JSON.stringify(r.strip.map((b) => [Math.round(b.w), Math.round(b.h)]))}`);
  expect(r.nav.every((b) => b.w >= 44 && b.h >= 44), `${tag}: viikkonuolten kosketuskohde < 44 px`);
  expect(r.btns.every((b) => b.h >= 40), `${tag}: painikkeiden korkeus < 40 px: ${JSON.stringify(r.btns.map((b) => Math.round(b.h)))}`);
  for (const c of r.contrast) expect(c.v >= 4.5, `${tag}: kontrasti ${c.sel} ${c.v.toFixed(2)} < 4.5`);
  expect(r.names.labelled && r.names.pickLabel && r.names.current === 1, `${tag}: saavutettavuus: aria-label/label/aria-current puuttuu (${JSON.stringify(r.names)})`);
  // näppäimistö: Tab saavuttaa päivälinkit ja Enter vaihtaa päivän
  if (!mobile && !empty) {
    let hit = false; await page.focus('.bk-modes a');
    for (let i = 0; i < 40 && !hit; i++) { await page.keyboard.press('Tab'); hit = await page.evaluate(() => document.activeElement?.classList.contains('bk-sd')); }
    expect(hit, `${tag}: Tab ei saavuta viikkoliuskan päiviä`);
    const target = await page.evaluate(() => document.activeElement.getAttribute('href'));
    await page.keyboard.press('Enter'); await page.waitForTimeout(500);
    expect(page.url().endsWith(target.slice(target.indexOf('#'))), `${tag}: Enter ei avannut päivää ${target} (${page.url()})`);
    expect(await page.evaluate(() => document.activeElement?.id === 'bk-day-h' || document.activeElement === document.body || !!document.activeElement), `${tag}: fokus hukkui`);
  }
  await ctx.close();
}
await browser.close();
if (problems.length) { console.error(problems.join('\n')); process.exit(1); }
console.log(`ok: kaupan lomakkeen ja päivänäkymän asettelu (${checks} tarkistusta; FI+EN, 360/390/430/1280 px)`);
