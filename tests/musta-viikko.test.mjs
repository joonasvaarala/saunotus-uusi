// Savusaunan musta viikko: luonnos (yläbanneri + etusivun kortti), oletuksena piilossa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const {
  MUSTA_VIIKKO_SLUG, MUSTA_VIIKKO_ENABLED, MUSTA_VIIKKO_PREVIEW, MUSTA_VIIKKO_STORAGE_KEY,
  MUSTA_VIIKKO_PRICE, MUSTA_VIIKKO_TEXTS, mustaViikkoHref, mustaViikkoPrice,
  mustaViikkoBannerHtml, mustaViikkoCardHtml, mustaViikkoBootScript,
} = await import('../src/musta-viikko.mjs');
const { money } = await import('../src/lib.mjs');
const { home, layout } = await import('../src/render.mjs');

test('oletuksena pois päältä; slug yhdessä vakiossa', () => {
  assert.equal(MUSTA_VIIKKO_ENABLED, false);
  assert.equal(MUSTA_VIIKKO_SLUG, 'savusaunan-musta-viikko');
  assert.equal(MUSTA_VIIKKO_PREVIEW, 'musta-viikko');
  assert.equal(MUSTA_VIIKKO_PRICE, 130);
  const src = read('src/musta-viikko.mjs');
  const others = [
    'src/render.mjs', 'src/home-front.mjs', 'src/styles.css',
    'content/site-texts.pending-import-183.json',
  ].map(read).join('\n');
  assert.equal([...src.matchAll(/MUSTA_VIIKKO_SLUG = '/g)].length, 1);
  assert.doesNotMatch(others, /savusaunan-musta-viikko/);
});

test('tuotelinkki on kaupan URL-muoto + slug, FI ja EN', () => {
  assert.equal(mustaViikkoHref('fi'), '/varaa/#/tuote/savusaunan-musta-viikko');
  assert.equal(mustaViikkoHref('en'), '/en/book/#/tuote/savusaunan-musta-viikko');
});

test('hinta 130 € sivuston money-muodossa', () => {
  assert.equal(mustaViikkoPrice('fi'), money(130, 'fi'));
  assert.equal(mustaViikkoPrice('en'), money(130, 'en'));
  assert.equal(mustaViikkoPrice('fi'), '130 €');
  assert.equal(mustaViikkoPrice('en'), '€130');
});

test('pending-import-183 vastaa varatekstejä, FI+EN, ei HTML:ää', () => {
  const pending = JSON.parse(read('content/site-texts.pending-import-183.json'));
  const keys = Object.keys(MUSTA_VIIKKO_TEXTS);
  assert.equal(pending.length, keys.length * 2);
  for (const key of keys) for (const lang of ['fi', 'en']) {
    const row = pending.find((x) => x.key === key && x.lang === lang);
    assert.ok(row, `${key} ${lang}`);
    assert.equal(row.text, MUSTA_VIIKKO_TEXTS[key][lang]);
    assert.equal(row.class, 'normal');
    assert.equal(row.kind, 'plain');
    assert.deepEqual(row.placeholders, []);
    assert.ok(!row.text.includes('<'));
    assert.ok(row.reason.includes('t1867u'));
  }
});

test('banneri ja kortti ovat piilossa, sisältävät linkin, hinnan ja jälkilöylyt; sulku localStorage-avaimella', () => {
  for (const lang of ['fi', 'en']) {
    const banner = mustaViikkoBannerHtml(lang);
    const card = mustaViikkoCardHtml(lang);
    const href = mustaViikkoHref(lang);
    assert.match(banner, /data-mv-banner hidden/);
    assert.match(card, /data-mv-promo hidden/);
    assert.ok(banner.includes(href));
    assert.ok(card.includes(href));
    assert.ok(banner.includes(MUSTA_VIIKKO_TEXTS['ui.site.mv_title'][lang]));
    assert.ok(banner.includes(MUSTA_VIIKKO_TEXTS['ui.site.mv_banner_text'][lang]));
    assert.ok(banner.includes(mustaViikkoPrice(lang)));
    assert.match(banner, /data-mv-close/);
    assert.ok(banner.includes(MUSTA_VIIKKO_TEXTS['ui.site.mv_close'][lang]));
    assert.ok(card.includes(MUSTA_VIIKKO_TEXTS['ui.site.mv_card_text'][lang]));
    assert.ok(card.includes(mustaViikkoPrice(lang)));
    assert.ok(card.includes(MUSTA_VIIKKO_TEXTS['ui.site.mv_cta'][lang]));
    assert.doesNotMatch(banner, /<[a-z][^>]*>[^<]*(?:javascript:|on\w+=)/i);
  }
  const boot = mustaViikkoBootScript();
  assert.ok(boot.includes('false'));
  assert.ok(boot.includes('preview'));
  assert.ok(boot.includes(MUSTA_VIIKKO_PREVIEW));
  assert.ok(boot.includes(MUSTA_VIIKKO_STORAGE_KEY));
  assert.ok(boot.includes('localStorage'));
});

test('etusivu: kortti viikko-ohjelman jälkeen, banneri ylälaidassa, molemmat hidden ilman esikatselua', () => {
  const fi = home('fi');
  const en = home('en');
  for (const html of [fi, en]) {
    assert.match(html, /data-mv-banner hidden/);
    assert.match(html, /data-mv-promo hidden/);
    assert.ok(html.includes('?preview=musta-viikko') || html.includes("preview") && html.includes(MUSTA_VIIKKO_PREVIEW));
    const vk = html.indexOf('class="vk"');
    const promo = html.indexOf('data-mv-promo');
    const trad = html.indexOf('class="tradition"');
    assert.ok(vk !== -1 && promo !== -1 && trad !== -1);
    assert.ok(vk < promo && promo < trad, 'kortti viikko-ohjelman ja rituaaliosion välissä');
  }
  assert.ok(fi.includes('/varaa/#/tuote/savusaunan-musta-viikko'));
  assert.ok(en.includes('/en/book/#/tuote/savusaunan-musta-viikko'));
  assert.ok(fi.includes('Jälkilöylyt ma–to'));
  assert.ok(en.includes('After Session Sauna Mon–Thu'));
});

test('CSS käyttää sivuston tokeneita, ei erillistä heksaväriä bannerissa', () => {
  const css = read('src/styles.css');
  const block = css.slice(css.indexOf('Savusaunan musta viikko'));
  assert.match(block, /\.mv-banner\{[^}]*background:var\(--green\)/);
  assert.match(block, /var\(--bg\)/);
  assert.match(block, /var\(--gold\)/);
  assert.match(block, /var\(--head\)/);
  assert.match(block, /\.mv-banner-close\{[^}]*width:44px/);
  assert.doesNotMatch(block, /#[0-9a-fA-F]{3,8}/);
});
