// Jälkilöylyt ja hiljaisen ajan ale viikko-ohjelmassa (etusivu + saunavuorot, FI/EN): mockattu public_availability_all + public_quiet_offers.
// Ale-vuoro: −20 %, normaalihinta yliviivattuna, linkki oikeaan vuoroon; varattu jälkilöyly yliviivattuna; ilman tarjousta täysi hinta;
// oma saunavuoro "alk." halvin hinta; ei päällekkäisyyttä 360/390/430 px:ssä. Ei verkkoa.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startSite, weekMock, hit } from './week-browser-harness.mjs';

let site;
before(async () => { site = await startSite({ port: 4422, tag: 'jalkiloyly' }); });
after(async () => { await site?.stop(); });

const pages = [
  { path: '/', lang: 'fi', after: 'Jälkilöylyt', own: 'Oma saunavuoro', from: 'alk.', badge: '−20 %' },
  { path: '/en/', lang: 'en', after: 'After Session Sauna', own: 'Private sauna session', from: 'from', badge: '−20%' },
  { path: '/saunavuorot/', lang: 'fi', after: 'Jälkilöylyt', own: 'Oma saunavuoro', from: 'alk.', badge: '−20 %' },
  { path: '/en/sauna/', lang: 'en', after: 'After Session Sauna', own: 'Private sauna session', from: 'from', badge: '−20%' },
];
const norm = (s) => s.replace(/[\s ]+/g, ' ');
const day = (page, i) => page.locator(`.vk-day[data-vk-day="${i}"]`);
const parts = (page, sel) => page.evaluate((s) => [...document.querySelectorAll(s)].map((e) => { const r = e.getBoundingClientRect(); return { top: r.top, right: r.right, bottom: r.bottom, left: r.left, text: e.textContent.trim() }; }), sel);

for (const pg of pages) {
  test(`jälkilöylyt ${pg.path}: ale tänään, täysi hinta ilman tarjousta, varattu yliviivattu, oma sauna alk.; ei päällekkäisyyttä`, async () => {
    for (const width of [360, 390, 430]) {
      const page = await site.open(width, pg.path, weekMock());
      // maanantai (tänään): ale-vuoro
      const mon = day(page, 0);
      const q = mon.locator('a.vk-line.is-quiet');
      assert.equal(await q.count(), 1, `${width} alennettu rivi`);
      const text = norm(await q.innerText());
      assert.match(text, /19[.:]00–21[.:]00/);
      assert.match(text, /144 €|€144/);
      assert.match(text, /180 €|€180/);
      assert.ok(text.includes(pg.badge), `${pg.path} ale-merkki ${pg.badge}: ${text}`);
      assert.equal(await q.getAttribute('href'), '/varaa/#/varaa/22/2026-11-16/26');
      assert.match(await q.getAttribute('aria-label'), /144/);
      assert.match(norm(await mon.locator('.vk-oma').innerText()), new RegExp(`${pg.own} ${pg.from} (€|)250`), `${pg.path} oma saunavuoro alk.`);
      assert.ok((await mon.locator('.vk-grp .vk-gn').innerText()).toLowerCase().includes(pg.after.toLowerCase()), 'jälkilöylyjen otsikko');
      // tiistai: täysi hinta ilman ale-merkkiä
      await page.click('.vk-tab[data-vk-pick="1"]');
      const tue = day(page, 1).locator('a.vk-line');
      assert.equal(await tue.count(), 1);
      assert.equal(await day(page, 1).locator('.vk-sale').count(), 0, 'ei ale-merkkiä ilman tarjousta');
      assert.match(norm(await tue.innerText()), /180/);
      assert.equal(await tue.getAttribute('href'), '/varaa/#/varaa/22/2026-11-17/26');
      // keskiviikko: varattu jälkilöyly yliviivattuna ja linkki tuotesivulle
      await page.click('.vk-tab[data-vk-pick="2"]');
      const wed = day(page, 2).locator('a.vk-line.is-full');
      assert.equal(await wed.count(), 1);
      assert.equal(await wed.evaluate((e) => getComputedStyle(e.querySelector('.vk-lt')).textDecorationLine), 'line-through');
      assert.equal(await wed.getAttribute('href'), '/varaa/#/tuote/jalkiloylyt/2026-11-18');
      // perjantai: oma sauna 300 €, ei jälkilöylyjä
      await page.click('.vk-tab[data-vk-pick="4"]');
      assert.match(norm(await day(page, 4).locator('.vk-oma').innerText()), new RegExp(`${pg.from} (€|)300`));
      assert.equal(await day(page, 4).locator('.vk-line').count(), 0);
      // lauantai: täynnä-jälkilöyly, ei turvesaunaa eikä yritystuotteita
      await page.click('.vk-tab[data-vk-pick="5"]');
      const satText = await day(page, 5).innerText();
      assert.doesNotMatch(satText, /Turvesauna|Peat sauna|yrityksille|for businesses|Tunnin|Hour/i);
      // ei päällekkäisyyttä päivän osien välillä, ei ylivuotoa
      for (const i of [0, 1, 2, 5]) {
        await page.click(`.vk-tab[data-vk-pick="${i}"]`);
        const els = await parts(page, '.vk-day.is-on .vk-pub, .vk-day.is-on .vk-oma, .vk-day.is-on .vk-line, .vk-day.is-on .vk-cl');
        for (let a = 0; a < els.length; a++) for (let b = a + 1; b < els.length; b++) assert.ok(!hit(els[a], els[b]), `${width} ${pg.path} ${els[a].text} / ${els[b].text} päällekkäin`);
        for (const e of els) assert.ok(e.left >= 0 && e.right <= width + 0.5, `${pg.path} ${width} reunan yli: ${e.text}`);
      }
      assert.ok((await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)) <= 1, 'sivuttainen ylivuoto');
      await page.close();
    }
  });
}

test('ilman hiljaisen ajan tarjouksia jälkilöylyt näkyvät täydellä hinnalla; tarjoushaun virhe ei kaada viikkoa', async () => {
  const page = await site.open(390, '/', { ...weekMock(), offers: [], fail: ['public_quiet_offers'] });
  assert.equal(await page.locator('.vk .vk-sale').count(), 0);
  assert.equal(await page.locator('.vk a.vk-line.is-quiet').count(), 0);
  assert.match(norm(await day(page, 0).locator('a.vk-line').innerText()), /180/);
  assert.match(norm(await day(page, 0).locator('.vk-oma').innerText()), /alk\. 250/);
  await page.close();
});

test('viikonloppu 1280: hiljaisen ajan ale ja kaikki rivit mahtuvat sarakkeeseen', async () => {
  const page = await site.open(1280, '/', weekMock());
  const sat = await page.evaluate(() => { const d = document.querySelector('.vk-day[data-vk-day="5"]').getBoundingClientRect(); return { l: d.left, r: d.right }; });
  const items = await parts(page, '.vk-day[data-vk-day="5"] .vk-pub, .vk-day[data-vk-day="5"] .vk-oma, .vk-day[data-vk-day="5"] .vk-line, .vk-day[data-vk-day="5"] .vk-chip');
  assert.ok(items.length >= 5);
  for (const e of items) assert.ok(e.left >= sat.l - 0.5 && e.right <= sat.r + 0.5, `ylittää sarakkeen: ${e.text}`);
  await page.close();
});
