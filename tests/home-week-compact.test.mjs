// Viikko-ohjelman asettelu selaimessa (etusivu + saunavuorot, FI/EN): mobiilissa päivänauha ja yksi päivä kerrallaan (ei koko viikkoa allekkain),
// työpöydällä 7 päiväsaraketta ja kolme palvelurivit samoilla korkeuksilla, viikkonavigointi nuolilla, tapahtumat Hoidot ja rituaalit -solussa,
// ei tiivis/laaja-nappia, ei sivuttaista ylivuotoa eikä päällekkäisyyttä 360/390/430 px:ssä. Data on mockattu (tests/week-browser-harness.mjs).
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startSite, weekMock, hit, ut } from './week-browser-harness.mjs';

let site;
before(async () => { site = await startSite({ port: 4421, tag: 'week-compact' }); });
after(async () => { await site?.stop(); });

const boxes = (page, sel) => page.evaluate((s) => [...document.querySelectorAll(s)].filter((e) => getComputedStyle(e).display !== 'none' && e.getClientRects().length).map((e) => { const r = e.getBoundingClientRect(); return { top: r.top, right: r.right, bottom: r.bottom, left: r.left, width: r.width, height: r.height, text: e.textContent.trim().slice(0, 40) }; }), sel);
const visibleDays = (page) => page.evaluate(() => [...document.querySelectorAll('.vk .vk-day')].filter((d) => getComputedStyle(d).display !== 'none').map((d) => +d.dataset.vkDay));
const overflow = (page) => page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);

for (const path of ['/', '/en/', '/saunavuorot/']) {
  test(`mobiili 360/390/430 ${path}: päivänauha, yksi päivä kerrallaan, ei ylivuotoa eikä päällekkäisyyttä`, async () => {
    for (const width of [360, 390, 430]) {
      const page = await site.open(width, path, weekMock());
      assert.equal((await page.locator('.vk .vk-tab').count()), 7, 'päivänauhassa 7 päivää');
      assert.deepEqual(await visibleDays(page), [0], `${width} vain kuluva päivä näkyy`);
      assert.equal((await boxes(page, '.vk .vk-strip')).length, 1, 'päivänauha näkyy');
      assert.equal((await boxes(page, '.vk .vk-lanes-li')).length, 0, 'desktopin palvelurivien otsikot piilossa');
      assert.equal(await page.locator('.vk details, .vk [aria-expanded], .week-more, .week-soon').count(), 0, 'ei tiivis/laaja-nappia');
      assert.doesNotMatch(await page.locator('.vk').innerText(), /Näytä kaikki tiedot|Näytä vähemmän|Show all|Show less|Näytä koko viikko/);
      // lauantai: chips, ei tunnin vuoroa, ei turvesaunaa
      await page.click('.vk-tab[data-vk-pick="5"]');
      assert.deepEqual(await visibleDays(page), [5]);
      assert.equal(await page.locator('.vk-tab.is-on').getAttribute('data-vk-pick'), '5');
      const text = await page.locator('.vk-day.is-on').innerText();
      assert.doesNotMatch(text, /Tunnin|Hour|Turvesauna|Peat sauna|Yrityksille|For business|Saunotusrituaali/);
      assert.match(text, /14[.:]00/);
      const chips = await boxes(page, '.vk-day.is-on .vk-chip');
      assert.ok(chips.length >= 3, `${width} ${path} chips ${chips.length}`);
      for (let i = 0; i < chips.length; i++) for (let j = i + 1; j < chips.length; j++) assert.ok(!hit(chips[i], chips[j]), `chip ${i}/${j} päällekkäin`);
      for (const c of chips) assert.ok(c.height >= 32 && c.left >= 0 && c.right <= width, 'chip kokonaan näkyvissä ja riittävän iso');
      const cards = await boxes(page, '.vk-day.is-on .vk-pub, .vk-day.is-on .vk-oma, .vk-day.is-on .vk-line, .vk-day.is-on .vk-cl');
      for (const c of cards) assert.ok(c.left >= 0 && c.right <= width + 0.5, `kortti ylittää reunan ${c.text}`);
      assert.ok((await overflow(page)) <= 1, `${width} ${path} sivuttainen ylivuoto`);
      // menneitä päiviä ei ole maanantaina; sunnuntai ja nauhan nuoli
      await page.click('.vk-tab[data-vk-pick="6"]');
      assert.deepEqual(await visibleDays(page), [6]);
      await page.close();
    }
  });
}

test('työpöytä 1280: 7 saraketta, kolme palveluriviä samoilla korkeuksilla, ei päivänauhaa eikä tapahtumakaistaa', async () => {
  const page = await site.open(1280, '/', weekMock({ example: true }));
  assert.deepEqual(await visibleDays(page), [0, 1, 2, 3, 4, 5, 6]);
  assert.equal((await boxes(page, '.vk .vk-strip')).length, 0, 'päivänauha piilossa');
  const heads = await boxes(page, '.vk .vk-dh');
  assert.equal(heads.length, 7);
  assert.ok(heads.every((b) => Math.abs(b.top - heads[0].top) < 1), 'päiväotsikot samalla rivillä');
  for (const lane of ['pubc', 'privc', 'carec']) {
    const cells = await boxes(page, `.vk .vk-${lane}`);
    assert.equal(cells.length, 7, lane);
    assert.ok(cells.every((b) => Math.abs(b.top - cells[0].top) < 1 && Math.abs(b.height - cells[0].height) < 1), `${lane}: rivin solut samassa linjassa`);
    assert.ok(cells.every((b) => Math.abs(b.width - cells[0].width) < 2), `${lane}: sarakkeet saman levyisiä`);
  }
  assert.equal((await boxes(page, '.vk .vk-lane')).length, 3, 'kolme palveluriviä');
  const laneText = await page.locator('.vk .vk-lanes').evaluate((e) => e.textContent);
  assert.doesNotMatch(laneText, /Tapahtumat|Yrityksille/);
  // tapahtuma perjantain Hoidot ja rituaalit -solussa, kortti ei ylitä solua
  const cell = (await boxes(page, '.vk .vk-carec'))[4];
  const evt = await boxes(page, '.vk .vk-evt');
  assert.equal(evt.length, 1);
  assert.ok(evt[0].left >= cell.left - 0.5 && evt[0].right <= cell.right + 0.5 && evt[0].bottom <= cell.bottom + 0.5, 'tapahtumakortti pysyy solussa');
  assert.match(await page.locator('.vk .vk-carec').nth(4).innerText(), /Perinnesaunotusilta[\s\S]*59\s?€/);
  assert.match(await page.locator('.vk .vk-carec').nth(4).innerText(), /17\.00–18\.30[\s\S]*19\.00–20\.30/);
  // kortit ja chips pysyvät sarakkeessaan
  for (const sel of ['.vk-pub', '.vk-oma', '.vk-line', '.vk-chip', '.vk-evt']) {
    const days = await boxes(page, '.vk .vk-day');
    for (const d of days) {
      const inner = await page.evaluate(({ sel, i }) => [...document.querySelectorAll(`.vk .vk-day[data-vk-day="${i}"] ${sel}`)].map((e) => { const r = e.getBoundingClientRect(); return { left: r.left, right: r.right }; }), { sel, i: days.indexOf(d) });
      for (const b of inner) assert.ok(b.left >= d.left - 0.5 && b.right <= d.right + 0.5, `${sel} ylittää sarakkeen`);
    }
  }
  assert.ok((await overflow(page)) <= 1);
  await page.close();
});

test('viikkonavigointi: nuolet, Tämä viikko, ei menneisiin viikkoihin, hoidot vain varausikkunassa', async () => {
  const page = await site.open(1280, '/saunavuorot/', { ...weekMock(), settings: { public_treatment_horizon_days: 14 } });
  const label = () => page.locator('.vk .vk-wk').innerText();
  assert.equal((await label()).trim(), '16.–22.11.', 'väli vain nuolten välissä, ei viikkonumeroa');
  assert.ok(await page.locator('[data-vk-nav="prev"]').isDisabled(), 'ei edelliseen viikkoon');
  assert.equal(await page.locator('[data-vk-nav="now"]').count(), 0, 'Tänään-linkki vain, kun jakso ei ala tänään');
  await page.click('[data-vk-nav="next"]');
  await page.waitForFunction(() => /23\.–29\.11\./.test(document.querySelector('.vk .vk-wk')?.textContent || ''));
  assert.equal((await label()).trim(), '23.–29.11.');
  assert.ok(await page.locator('[data-vk-nav="now"]').isVisible());
  assert.ok(!(await page.locator('[data-vk-nav="prev"]').isDisabled()));
  assert.match(await page.locator('.vk-day[data-vk-day="0"]').innerText(), /23\.11\./);
  assert.match(await page.locator('.vk-day[data-vk-day="0"] .vk-privc').innerText(), /alk\.\s*250/);
  assert.match(await page.locator('.vk-day[data-vk-day="3"] .vk-pubc').innerText(), /16\.00–19\.00[\s\S]*29\s?€/);
  const calls = await page.evaluate(() => globalThis.__RPC.filter((c) => c.name === 'public_availability_all').map((c) => [c.args.p_from, c.args.p_to]));
  assert.deepEqual(calls, [['2026-11-16', '2026-11-22'], ['2026-11-23', '2026-11-29']]);
  // seuraava viikko: public_settings antaa ikkunaksi 14 pv → viikko 49 ylittää sen: ei hoitohakuja, selite
  await page.click('[data-vk-nav="next"]');
  await page.waitForFunction(() => /30\.11\.–6\.12\./.test(document.querySelector('.vk .vk-wk')?.textContent || ''));
  assert.match(await page.locator('.vk .vk-careh').innerText(), /avautuvat lähempänä/);
  assert.match(await page.locator('.vk-day[data-vk-day="4"] .vk-carec').innerText(), /Perinnesaunotusilta/, 'tapahtuma näkyy, vaikka hoitoikkuna on ohitettu');
  const treatCalls = await page.evaluate(() => globalThis.__RPC.filter((c) => c.name === 'public_treatment_availability').map((c) => c.args.p_from));
  assert.ok(treatCalls.every((f) => f < '2026-11-30'), `hoitohaku ikkunan ulkopuolelle: ${treatCalls}`);
  await page.click('[data-vk-nav="now"]');
  await page.waitForFunction(() => /16\.–22\.11\./.test(document.querySelector('.vk .vk-wk')?.textContent || ''));
  assert.equal(await page.locator('[data-vk-nav="now"]').count(), 0);
  assert.ok(await page.locator('[data-vk-nav="prev"]').isDisabled());
  await page.close();
});

test('hoitoikkuna 90 pv (public_settings): viikko 30.11.–6.12. näyttää hoidot ja tapahtuman samassa solussa', async () => {
  const m = weekMock();
  const D = (n) => `2026-12-${String(n).padStart(2, '0')}`;
  m.treat.push({ product_id: 10, session_date: D(1), starts_at: ut(D(1), '16:00'), ends_at: ut(D(1), '17:00'), status: 'available', total: 99 });
  m.treat.push({ product_id: 10, session_date: D(4), starts_at: ut(D(4), '16:00'), ends_at: ut(D(4), '17:00'), status: 'available', total: 99 });
  m.settings = { public_treatment_horizon_days: 90 };
  const page = await site.open(1280, '/saunavuorot/', m);
  await page.click('[data-vk-nav="next"]');
  await page.waitForFunction(() => /23\.–29\.11\./.test(document.querySelector('.vk .vk-wk')?.textContent || ''));
  await page.click('[data-vk-nav="next"]');
  await page.waitForFunction(() => /30\.11\.–6\.12\./.test(document.querySelector('.vk .vk-wk')?.textContent || ''));
  assert.doesNotMatch(await page.locator('.vk .vk-careh').innerText(), /avautuvat lähempänä/);
  assert.match(await page.locator('.vk-day[data-vk-day="1"] .vk-carec').innerText(), /Saunahoito/);
  const fri = await page.locator('.vk-day[data-vk-day="4"] .vk-carec').innerText();
  assert.match(fri, /Saunahoito/);
  assert.match(fri, /Perinnesaunotusilta/);
  assert.equal(await page.locator('.vk .vk-sec-title, .vk h2.sec-title').count(), 0, 'saunavuorot-sivulla ei otsikkoa');
  await page.close();
  const home = await site.open(1280, '/', m);
  assert.match(await home.locator('.vk h2.sec-title').innerText(), /Tulevat päivät saunalla/);
  await home.click('[data-vk-nav="next"]');
  await home.waitForFunction(() => /23\.–29\.11\./.test(document.querySelector('.vk .vk-wk')?.textContent || ''));
  assert.match(await home.locator('.vk h2.sec-title').innerText(), /Tulevat päivät saunalla/, 'otsikko ei vaihdu viikkonumeroksi');
  await home.click('[data-vk-nav="now"]');
  await home.waitForFunction(() => /16\.–22\.11\./.test(document.querySelector('.vk .vk-wk')?.textContent || ''));
  const rpcs = await home.evaluate(() => globalThis.__RPC.map((c) => c.name));
  assert.equal(rpcs.filter((n) => n === 'public_catalog').length, 1, 'katalogi haetaan kerran');
  assert.equal(rpcs.filter((n) => n === 'public_events').length, 1, 'tapahtumat haetaan kerran');
  await home.close();
});

test('EN: viikkoväli englanniksi, Sauna training -linkki saunahealer.com', async () => {
  const en = await site.open(1280, '/en/', weekMock());
  assert.match(await en.locator('.vk .vk-wk').innerText(), /^16–22 Nov$/i);
  assert.equal(await en.locator('.vk a[href="https://saunahealer.com"]').count(), 1);
  assert.equal(await en.locator('.vk a[href="https://saunakoulutus.fi"]').count(), 0);
  assert.match(await en.locator('.vk a[href="https://saunahealer.com"]').innerText(), /Sauna training/i);
  await en.click('[data-vk-nav="next"]');
  await en.waitForFunction(() => /23–29 Nov/.test(document.querySelector('.vk .vk-wk')?.textContent || ''));
  await en.click('[data-vk-nav="next"]');
  await en.waitForFunction(() => /30 Nov–6 Dec/.test(document.querySelector('.vk .vk-wk')?.textContent || ''));
  assert.match(await en.locator('.vk .vk-wk').innerText(), /^30 Nov–6 Dec$/i);
  assert.match(await en.locator('.vk h2.sec-title').innerText(), /Upcoming days at the sauna/);
  await en.close();
});

test('viikon tapahtumavihje: ei tapahtumia → seuraavat tapahtumat alareunassa, ei erillistä tapahtumariviä', async () => {
  const page = await site.open(390, '/', weekMock());
  const hint = await page.locator('.vk .vk-hint').innerText();
  assert.match(hint, /Tapahtumat:[\s\S]*ei näinä päivinä/);
  assert.match(hint, /Perinnesaunotusilta 4\.12\./);
  assert.match(hint, /Sipoonjoen joulusauna 19\.12\./);
  assert.equal(await page.locator('.vk .vk-evt').count(), 0);
  assert.equal(await page.locator('.vk a[href="https://saunakoulutus.fi"]').count(), 1, 'yksi Koulutukset-linkki');
  assert.equal(await page.locator('.vk .vk-day:has-text("Koulutus")').count(), 0, 'koulutuksia ei kalenterissa');
  await page.close();
  const ex = await site.open(390, '/', weekMock({ example: true }));
  assert.equal(await ex.locator('.vk .vk-hint').count(), 0, 'viikolla on tapahtuma → ei vihjettä');
  await ex.click('.vk-tab[data-vk-pick="4"]');
  assert.match(await ex.locator('.vk-day.is-on .vk-carec').innerText(), /Tapahtuma[\s\S]*Perinnesaunotusilta/i);
  await ex.close();
});

test('hakuvirhe: ensimmäinen haku kaatuu → staattinen varaversio jää, myöhempi virhe näytetään', async () => {
  const mock = { ...weekMock(), fail: ['public_availability_all'] };
  const page = await site.open(1280, '/', mock, { live: false });
  await page.addScriptTag({ type: 'module', url: '/booking/quiet-week.js' });
  await page.waitForSelector('.vk.is-js', { timeout: 8000 });
  assert.equal(await page.locator('.vk[data-vk-live]').count(), 0);
  assert.equal(await page.locator('.vk .vk-day').count(), 7, 'staattinen viikko säilyy');
  assert.match(await page.locator('.vk .vk-pubc').first().innerText(), /16\.00–19\.00/);
  await page.close();
});

// ---- luonnos B (t1829u): liukuva ikkuna, mobiilin päänavigaatio ja ylätunniste ----
const SUN_NOW = '2026-11-15T08:00:00+02:00';   // sunnuntai: ikkuna su 15.11. … la 21.11.

test('liukuva ikkuna 1280 (tänään su): sarakkeet su…la, su ja la viikonloppuvärillä, selite ja ei viivaa hoitosolussa', async () => {
  const page = await site.open(1280, '/', weekMock({ example: true }), { now: SUN_NOW });
  assert.equal((await page.locator('.vk .vk-wk').innerText()).trim(), '15.–21.11.');
  const names = await page.locator('.vk .vk-dh > span:first-child').allTextContents();
  assert.deepEqual(names, ['Sunnuntai', 'Maanantai', 'Tiistai', 'Keskiviikko', 'Torstai', 'Perjantai', 'Lauantai']);
  const we = await page.locator('.vk .vk-day').evaluateAll((els) => els.map((e) => e.classList.contains('we')));
  assert.deepEqual(we, [true, false, false, false, false, false, true], 'viikonloppuvärit päivämäärästä, ei sarakkeen järjestyksestä');
  assert.equal(await page.locator('.vk .vk-day.is-today').count(), 1);
  assert.equal(await page.locator('.vk .vk-day.is-today').getAttribute('data-vk-day'), '0');
  assert.ok(await page.locator('[data-vk-nav="prev"]').isDisabled(), 'taaksepäin pois, jakso alkaa tänään');
  assert.match(await page.locator('[data-vk-nav="prev"]').getAttribute('aria-label'), /alkaa tänään/);
  assert.equal(await page.locator('.vk .vk-carec .vk-dash').count(), 0, 'ei viivaa hoitosolussa');
  assert.match(await page.locator('.vk .vk-carec').first().innerText(), /Ei tänä päivänä/);
  assert.match(await page.locator('.vk .vk-legend').innerText(), /Vapaa[\s\S]*Vähän jäljellä[\s\S]*Täynnä/i);
  assert.equal((await boxes(page, '.vk .vk-legend')).length, 1, 'selite ruudukon alla');
  // täysi aika: ei linkkiä
  assert.equal(await page.locator('.vk a.is-full:not(.vk-evt), .vk a.vk-chip.is-full').count(), 0, 'täysi aika ei ole linkki');
  assert.match(await page.locator('.vk .vk-line.is-full').first().innerText(), /Täynnä/);
  // 7 päivän loikka eteenpäin: su 22.11. …
  await page.click('[data-vk-nav="next"]');
  await page.waitForFunction(() => /22\.–28\.11\./.test(document.querySelector('.vk .vk-wk')?.textContent || ''));
  assert.deepEqual((await page.locator('.vk .vk-dh > span:first-child').allTextContents())[0], 'Sunnuntai');
  assert.ok(!(await page.locator('[data-vk-nav="prev"]').isDisabled()));
  await page.close();
});

test('mobiili 390 (tänään su): tänään merkitty valitsemattomanakin, kolme riviä, linkki seuraavaan päivään, Varaa ≥ 44 px, edellinen/seuraava päivä', async () => {
  const page = await site.open(390, '/', weekMock(), { now: SUN_NOW });
  assert.equal(await page.locator('.vk-tab.is-on').getAttribute('data-vk-pick'), '0', 'oletus: tänään valittu');
  // selite nauhan alla ja nimessä palvelut
  assert.equal((await boxes(page, '.vk .vk-key')).length, 1);
  assert.match(await page.locator('.vk .vk-key').innerText(), /Yleiset vuorot[\s\S]*Oma sauna[\s\S]*Hoidot ja rituaalit/);
  assert.match(await page.locator('.vk-tab[data-vk-pick="2"]').getAttribute('aria-label'), /^Tiistai 17\.11\.: .*Hoidot ja rituaalit/);
  // valitse ti: tänään (su) pysyy merkittynä
  await page.click('.vk-tab[data-vk-pick="2"]');
  const today = page.locator('.vk-tab[data-vk-pick="0"]');
  assert.equal(await today.evaluate((e) => e.classList.contains('is-today') && !e.classList.contains('is-on')), true);
  assert.match(await today.evaluate((e) => getComputedStyle(e).boxShadow), /rgb\(196, 154, 108\)/, 'tänään-merkki näkyy myös valitsemattomana');
  const on = page.locator('.vk-tab[data-vk-pick="2"]');
  assert.equal(await on.evaluate((e) => e.classList.contains('is-on') && !e.classList.contains('is-today')), true);
  // kolme riviä samassa järjestyksessä
  const cells = await page.locator('.vk-day.is-on .vk-cell').evaluateAll((els) => els.map((e) => e.className.match(/vk-(pub|priv|care)c/)[1]));
  assert.deepEqual(cells, ['pub', 'priv', 'care']);
  assert.equal((await boxes(page, '.vk-day.is-on .vk-cell')).length, 3, 'kaikki kolme riviä näkyvät');
  // ti: yleisiä ei ole → «Ei yleisiä vuoroja» + linkki seuraavaan päivään (ke ei, to 19.11.)
  const pub = await page.locator('.vk-day.is-on .vk-pubc').innerText();
  assert.match(pub, /Ei yleisiä vuoroja/);
  assert.match(pub, /Seuraava to 19\.11\.\s*→/);
  await page.click('.vk-day.is-on .vk-pubc .vk-jump');
  assert.equal(await page.locator('.vk-tab.is-on').getAttribute('data-vk-pick'), '4', 'linkki valitsee seuraavan päivän, jolla on yleisiä vuoroja');
  assert.match(await page.locator('.vk-day.is-on .vk-dh').innerText(), /Torstai/i);
  // oma sauna: koko kortti on linkki kuten muut rivit, ei erillistä Varaa-painiketta (t1845u); kosketuspinta ≥ 44 px
  await page.click('.vk-tab[data-vk-pick="6"]');
  assert.equal((await boxes(page, '.vk .vk-book')).length, 0, 'ei Varaa-painiketta mobiilissa');
  const oma = page.locator('.vk-day.is-on a.vk-oma');
  assert.equal(await oma.count(), 1);
  assert.ok(await oma.getAttribute('href'), 'oma sauna -kortti on linkki');
  const card = (await boxes(page, '.vk-day.is-on a.vk-oma'))[0];
  assert.ok(card.height >= 44 && card.height < 90, `kortin korkeus ${card.height}`);
  assert.doesNotMatch(await oma.innerText(), /Varaa/i);
  // edellinen/seuraava päivä
  const prev = page.locator('.vk-step-prev'), next = page.locator('.vk-step-next');
  assert.equal((await boxes(page, '.vk-daynav')).length, 1);
  assert.ok(await next.isDisabled(), 'ikkunan viimeinen päivä: seuraava pois');
  assert.ok(!(await prev.isDisabled()));
  await prev.click();
  assert.equal(await page.locator('.vk-tab.is-on').getAttribute('data-vk-pick'), '5');
  assert.ok(!(await next.isDisabled()));
  for (let i = 0; i < 5; i++) await prev.click();
  assert.equal(await page.locator('.vk-tab.is-on').getAttribute('data-vk-pick'), '0');
  assert.ok(await prev.isDisabled(), 'ikkunan ensimmäinen päivä: edellinen pois');
  // näppäimistö: painike on fokusoitavissa ja Enter vaihtaa päivää
  await next.focus();
  await page.keyboard.press('Enter');
  assert.equal(await page.locator('.vk-tab.is-on').getAttribute('data-vk-pick'), '1');
  assert.ok((await overflow(page)) <= 1);
  // desktopin Varaa-nappi ei näy kortissa
  await page.close();
  const desk = await site.open(1280, '/', weekMock(), { now: SUN_NOW });
  assert.equal((await boxes(desk, '.vk .vk-book')).length, 0, 'ei Varaa-painiketta desktopissa');
  assert.equal((await boxes(desk, '.vk .vk-daynav, .vk .vk-key')).length, 0, 'päivänavigointi ja nauhan selite vain mobiilissa');
  await desk.close();
});

for (const [path, label] of [['/', 'Varaa'], ['/en/', 'Book']]) {
  test(`ylätunniste ${path}: Varaa-painike näkyy mobiilissa (360/390/430), mahtuu ja kosketuspinta ≥ 44 px; desktop ehjä`, async () => {
    for (const width of [360, 390, 430, 768]) {
      const page = await site.open(width, path, weekMock(), { live: false });
      await page.addStyleTag({ content: '.test-env-banner{display:none}' });
      const btn = await boxes(page, '.hdr > a.btn.sm');
      assert.equal(btn.length, 1, `${width} Varaa näkyy`);
      assert.equal(btn[0].text.trim().toLowerCase(), label.toLowerCase());
      assert.ok(btn[0].height >= 44, `${width} korkeus ${btn[0].height}`);
      const parts = [...(await boxes(page, '.hdr > .brand .brand-txt b')), ...(await boxes(page, '.hdr > .brand img')), ...(await boxes(page, '.hdr > .lang')), ...btn, ...(await boxes(page, '.hdr > .nav-mob > summary'))];
      assert.equal(parts.length, 5, `${width} brändin nimi + kuvake, kieli, Varaa, Valikko`);
      assert.ok(await page.locator('.hdr > .brand .brand-txt b').evaluate((e) => e.scrollWidth <= e.clientWidth + 1 && getComputedStyle(e.closest('.brand')).overflow !== 'hidden'), `${width} brändin teksti ei leikkaudu`);
      for (let i = 0; i < parts.length; i++) {
        assert.ok(parts[i].left >= 0 && parts[i].right <= width + 0.5, `${width} ${i} reunan yli`);
        for (let j = i + 1; j < parts.length; j++) assert.ok(!hit(parts[i], parts[j]), `${width} ylätunnisteen osat ${i}/${j} päällekkäin`);
      }
      assert.ok((await overflow(page)) <= 1, `${width} sivuttainen ylivuoto`);
      assert.equal((await boxes(page, '.hdr > .nav-desk')).length, 0, `${width} desktop-valikko piilossa`);
      await page.close();
    }
    const d = await site.open(1280, path, weekMock(), { live: false });
    assert.equal((await boxes(d, '.hdr > .nav-desk')).length, 1, '1280 desktop-valikko näkyy');
    assert.equal((await boxes(d, '.hdr > .btn.sm')).length, 1, '1280 Varaa näkyy');
    assert.equal((await boxes(d, '.hdr > .nav-mob')).length, 0, '1280 mobiilivalikko piilossa');
    const h = await boxes(d, '.hdr > .brand, .hdr > .nav-desk, .hdr > .lang, .hdr > .btn.sm');
    for (let i = 0; i < h.length; i++) for (let j = i + 1; j < h.length; j++) assert.ok(!hit(h[i], h[j]), `1280 ylätunniste ${i}/${j} päällekkäin`);
    assert.ok((await overflow(d)) <= 1);
    await d.close();
  });
}
