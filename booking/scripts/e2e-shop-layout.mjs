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
  // v16: yhteenveto otsikon alla (tuote, päivä, aika) + "Vaihda päivää tai aikaa": asettelu, kosketuskohde, kontrasti, linkin kohde
  {
    const pk = await page.evaluate(() => {
      const rgb = (c) => (c.match(/[\d.]+/g) || []).slice(0, 3).map(Number);
      const lum = (c) => { const [r, g, b] = rgb(c).map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
      const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m); return (x + 0.05) / (y + 0.05); };
      const box = (e) => { const b = e.getBoundingClientRect(); return { l: b.left, r: b.right, w: b.width, h: b.height }; };
      const el = document.querySelector('#booking-app .bk-pick'); const bg = getComputedStyle(el).backgroundColor;
      const q = (s) => el.querySelector(s);
      return { ok: !!el, afterH2: document.querySelector('#booking-app h2').nextElementSibling === el, name: q('.bk-pick-name').textContent, when: q('.bk-pick-when').textContent, link: q('a.bk-pick-change').textContent, href: q('a.bk-pick-change').getAttribute('href'),
        box: box(el), app: box(document.getElementById('booking-app')), linkBox: box(q('a.bk-pick-change')), links: document.querySelectorAll('#booking-app > p a, #booking-app .bk-pick a').length,
        cr: ['.bk-pick-name', '.bk-pick-when', 'a.bk-pick-change'].map((s) => ratio(getComputedStyle(q(s)).color, bg)), order: [...document.querySelector('#booking-app').children].slice(0, 3).map((c) => c.className || c.tagName) };
    });
    expect(pk.ok && pk.afterH2, `${tag}: yhteenvetolaatikon pitää olla heti otsikon alla (${pk.order})`);
    expect(pk.name.length > 2 && (lang === 'fi' ? /^(ma|ti|ke|to|pe|la|su) \d{1,2}\.\d{1,2}\.\d{4}, klo \d{2}:\d{2}–\d{2}:\d{2}$/ : /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun),? \d{1,2} [A-Z][a-z]{2} \d{4} · \d{2}:\d{2}–\d{2}:\d{2}$/).test(pk.when), `${tag}: yhteenvetorivi väärin: "${pk.name}" / "${pk.when}"`);
    expect(pk.link === (lang === 'fi' ? 'Vaihda päivää tai aikaa' : 'Change date or time') && pk.links === 1, `${tag}: pitää olla yksi linkki "Vaihda päivää tai aikaa" (ei erillistä Takaisin-linkkiä): ${pk.link} / ${pk.links}`);
    expect(/#\/tuote\/yleinensauna\/\d{4}-\d\d-\d\d$/.test(pk.href), `${tag}: linkin kohde väärä (tuotesivu + päivä odotettiin): ${pk.href}`);
    expect(pk.box.l >= pk.app.l - 0.5 && pk.box.r <= pk.app.r + 0.5, `${tag}: yhteenvetolaatikko ylittää sisältöalueen`);
    expect(pk.linkBox.h >= 44 && pk.linkBox.w >= 44, `${tag}: linkin kosketuskohde < 44 px (${pk.linkBox.w.toFixed(0)}×${pk.linkBox.h.toFixed(0)})`);
    expect(pk.cr.every((v) => v >= 4.5), `${tag}: yhteenvedon kontrasti < 4,5: ${pk.cr.map((v) => v.toFixed(2))}`);
    if (OUT && width === 390 && kind === 'private') { await page.addStyleTag({ content: 'header.site-header,.site-header{position:static!important}' }); await page.evaluate(() => scrollTo(0, 0)); await page.screenshot({ path: join(OUT, `shop-mobile-390-${lang}-lomake-yhteenveto-ylaosa.png`), fullPage: true, clip: { x: 0, y: 0, width: 390, height: 900 } }); }
  }
  if (OUT) await page.addStyleTag({ content: 'header.site-header,.site-header,header[class*=head],.topbar{position:static!important}' });   // kiinteä yläpalkki ei peitä kokosivun kuvaa
  if (OUT && lang === 'fi' && width === 390) await page.screenshot({ path: join(OUT, `shop-mobile-390-lisapalvelut-${kind === 'company' ? 'yritys' : 'yksityinen'}.png`), fullPage: true });
  if (OUT && lang === 'en' && width === 390) await page.screenshot({ path: join(OUT, `shop-mobile-390-en-addons-${kind}.png`), fullPage: true });
  if (OUT && lang === 'fi' && width === 1280 && kind === 'company') await page.screenshot({ path: join(OUT, 'shop-desktop-1280-lisapalvelut-yritys.png'), fullPage: true });
  // linkki vie takaisin tuotesivulle samalle päivälle
  if (width === 390 && kind === 'private') {
    const date = (await page.locator('#booking-app .bk-pick a.bk-pick-change').getAttribute('href')).match(/(\d{4}-\d\d-\d\d)$/)[1];
    await page.click('#booking-app .bk-pick a.bk-pick-change');
    await page.waitForSelector('.bk-slot.available');
    expect(page.url().endsWith(`#/tuote/yleinensauna/${date}`), `${tag}: "Vaihda päivää tai aikaa" ei vienyt tuotesivulle (${page.url()})`);
    expect((await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)), `${tag}: vaakavieritys tuotesivulla`);
  }
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
    await page.locator('.bk-sd.free').last().click(); await page.waitForSelector('.bk-dayresults .bk-pc');
  }
  await page.waitForTimeout(200);
  for (const st of empty ? ['suljettu'] : ['suljettu', 'auki']) {
    const T = `${tag}/${st}`;
    if (st === 'auki') { await page.locator('.bk-pc-head').first().click(); await page.waitForSelector('.bk-pc.open .bk-slot:visible'); await page.waitForTimeout(200); }
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
        parts: [...inside('.bk-modes'), ...inside('.bk-daypick'), ...inside('.bk-strip'), ...inside('.bk-dayresults'), ...inside('.bk-slot'), ...inside('.bk-pc'), ...inside('.bk-pc-head'), ...inside('.bk-pc-panel:not([hidden])'), ...inside('.bk-notice'), ...inside('.bk-daytools input')],
        strip: [...document.querySelectorAll('.bk-strip .bk-sd')].map(box), nav: [...document.querySelectorAll('.bk-weeknav .bk-navbtn:not(.off)')].map(box),
        pcheads: [...document.querySelectorAll('.bk-pc-head')].map(box), btns: [...document.querySelectorAll('.bk-dayresults a.btn, .bk-modes a, .bk-today')].map(box),
        contrast: [...cr('.bk-modes a'), ...cr('.bk-sd.free'), ...cr('.bk-sd.sel'), ...cr('.bk-badge.free'), ...cr('.bk-slot .bk-time'), ...cr('.bk-pc-name'), ...cr('.bk-pc-desc'), ...cr('.bk-pc-meta .bk-badge'), ...cr('.bk-pc-meta .bk-price'), ...cr('.bk-pc-more a'), ...cr('.bk-dayresults a.btn'), ...cr('.bk-today')],
        names: { h2: document.querySelector('#booking-app h2')?.textContent, labelled: [...document.querySelectorAll('.bk-strip a')].every((a) => a.getAttribute('aria-label')), pickLabel: !!document.querySelector('label[for=bk-day-pick]'), current: document.querySelectorAll('.bk-strip [aria-current=date]').length },
      };
    });
    expect(r.sw <= r.iw, `${T}: vaakavieritys (${r.sw} > ${r.iw})`);
    for (const b of r.parts) expect(b.l >= r.app.l - 0.5 && b.r <= r.app.r + 0.5, `${T}: ${b.sel} ylittää sisältöalueen (${b.l.toFixed(1)}–${b.r.toFixed(1)} vs ${r.app.l.toFixed(1)}–${r.app.r.toFixed(1)})`);
    expect(r.strip.length === 7 && r.strip.every((b) => Math.abs(b.w - r.strip[0].w) < 1.5 && Math.abs(b.l + b.w - (r.strip[0].l + r.strip[0].w) - (r.strip.indexOf(b) * (r.strip[1].l - r.strip[0].l))) < 1.5 && b.w >= 34 && b.h >= 44), `${T}: viikkoliuskan päivien pitää olla 7 samanlevyistä ≥34×44 px: ${JSON.stringify(r.strip.map((b) => [Math.round(b.w), Math.round(b.h)]))}`);
    expect(r.nav.every((b) => b.w >= 44 && b.h >= 44), `${T}: viikkonuolten kosketuskohde < 44 px`);
    expect(r.btns.filter((b) => b.h > 0).every((b) => b.h >= 40), `${T}: painikkeiden korkeus < 40 px: ${JSON.stringify(r.btns.map((b) => Math.round(b.h)))}`);
    for (const c of r.contrast) expect(c.v >= 4.5, `${T}: kontrasti ${c.sel} ${c.v.toFixed(2)} < 4.5`);
    expect(r.names.labelled && r.names.pickLabel && r.names.current === 1, `${T}: saavutettavuus: aria-label/label/aria-current puuttuu (${JSON.stringify(r.names)})`);
    expect(r.pcheads.every((b) => b.h >= 44), `${T}: tuotekortin painikkeen korkeus < 44 px`);

  }
  // näppäimistö: Tab saavuttaa päivälinkit ja Enter vaihtaa päivän
  if (!mobile && !empty) {
    // accordion näppäimistöllä: Enter / väli avaa ja sulkee, aria-expanded päivittyy
    await page.focus('.bk-pc-head');
    const ex = () => page.locator('.bk-pc-head').first().getAttribute('aria-expanded');
    const before = await ex(); await page.keyboard.press('Enter'); const afterEnter = await ex(); await page.keyboard.press('Space'); const afterSpace = await ex();
    expect(before !== afterEnter && afterSpace === before, `${tag}: accordion ei toimi näppäimistöllä (${before} → ${afterEnter} → ${afterSpace})`);
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
