// Savusaunan musta viikko: luonnos (yläbanneri + etusivun kortti), oletuksena piilossa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const {
  MUSTA_VIIKKO_PACKAGE, MUSTA_VIIKKO_ENABLED, MUSTA_VIIKKO_PREVIEW, MUSTA_VIIKKO_STORAGE_KEY,
  MUSTA_VIIKKO_PRICE, MUSTA_VIIKKO_TEXTS, mustaViikkoHref, mustaViikkoPrice,
  mustaViikkoBannerHtml, mustaViikkoCardHtml, mustaViikkoBootScript,
} = await import('../src/musta-viikko.mjs');
const { money } = await import('../src/lib.mjs');
const { home, layout } = await import('../src/render.mjs');

test('oletuksena pois päältä; paketin koodi yhdessä vakiossa', () => {
  assert.equal(MUSTA_VIIKKO_ENABLED, false);
  assert.equal(MUSTA_VIIKKO_PACKAGE, 'bf_jalkiloylyt_mato');
  assert.equal(MUSTA_VIIKKO_PREVIEW, 'musta-viikko');
  assert.equal(MUSTA_VIIKKO_PRICE, 130);
  const src = read('src/musta-viikko.mjs');
  const others = [
    'src/render.mjs', 'src/home-front.mjs', 'src/styles.css',
    'content/site-texts.pending-import-183.json',
  ].map(read).join('\n');
  assert.equal([...src.matchAll(/MUSTA_VIIKKO_PACKAGE = '/g)].length, 1);
  assert.doesNotMatch(others, /bf_jalkiloylyt_mato/);
});

test('tuotelinkki on lahjakorttisivu + ?paketti=, FI ja EN', () => {
  assert.equal(mustaViikkoHref('fi'), '/lahjakortti/?paketti=bf_jalkiloylyt_mato');
  assert.equal(mustaViikkoHref('en'), '/en/gift-card/?paketti=bf_jalkiloylyt_mato');
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
    const ph = key === 'ui.site.mv_banner_text' ? ['{{var:price}}'] : [];
    assert.deepEqual(row.placeholders, ph);
    assert.ok(!row.text.includes('<'));
    assert.ok(row.reason.includes('t1867u'));
    assert.ok(row.reason.includes('t1870u'));
  }
});

test('ei Black Friday -sanaa teksteissä eikä lähteissä', () => {
  for (const lang of ['fi', 'en']) {
    for (const key of Object.keys(MUSTA_VIIKKO_TEXTS)) {
      assert.doesNotMatch(MUSTA_VIIKKO_TEXTS[key][lang], /black\s*friday/i, `${key} ${lang}`);
    }
    assert.doesNotMatch(mustaViikkoBannerHtml(lang), /black\s*friday/i);
    assert.doesNotMatch(mustaViikkoCardHtml(lang), /black\s*friday/i);
  }
  for (const f of ['src/musta-viikko.mjs', 'src/styles.css', 'src/render.mjs', 'content/site-texts.pending-import-183.json']) {
    assert.doesNotMatch(read(f), /black\s*friday/i, f);
  }
});

test('banneri ja kortti ovat piilossa, sisältävät linkin, hinnan ja voimassaolon; sulku localStorage-avaimella', () => {
  for (const lang of ['fi', 'en']) {
    const banner = mustaViikkoBannerHtml(lang);
    const card = mustaViikkoCardHtml(lang);
    const href = mustaViikkoHref(lang);
    const price = mustaViikkoPrice(lang);
    assert.match(banner, /data-mv-banner hidden/);
    assert.match(card, /data-mv-promo hidden/);
    assert.ok(banner.includes(href));
    assert.ok(card.includes(href));
    assert.ok(banner.includes(MUSTA_VIIKKO_TEXTS['ui.site.mv_title'][lang]));
    assert.ok(banner.includes(MUSTA_VIIKKO_TEXTS['ui.site.mv_product'][lang]));
    assert.ok(banner.includes(price));
    assert.ok(banner.includes('– '));
    assert.match(banner, /data-mv-close/);
    assert.ok(banner.includes(MUSTA_VIIKKO_TEXTS['ui.site.mv_close'][lang]));
    assert.ok(card.includes(MUSTA_VIIKKO_TEXTS['ui.site.mv_title'][lang]));
    assert.ok(card.includes(MUSTA_VIIKKO_TEXTS['ui.site.mv_product'][lang]));
    assert.ok(card.includes(MUSTA_VIIKKO_TEXTS['ui.site.mv_card_text'][lang]));
    assert.ok(card.includes(price));
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
  assert.ok(fi.includes('/lahjakortti/?paketti=bf_jalkiloylyt_mato'));
  assert.ok(en.includes('/en/gift-card/?paketti=bf_jalkiloylyt_mato'));
  assert.ok(fi.includes('Jälkilöylylahjakortti'));
  assert.ok(fi.includes('Voimassa 6 kk, ma–to'));
  assert.ok(en.includes('After Session Sauna gift card'));
  assert.ok(en.includes('Valid 6 months, Mon–Thu'));
  assert.doesNotMatch(fi + en, /black\s*friday/i);
});

test('CSS: musta tausta, vaalea teksti, kulta-aksentti, ei tummanvihreää', () => {
  const css = read('src/styles.css');
  const block = css.slice(css.indexOf('Savusaunan musta viikko'));
  assert.match(block, /\.mv-banner\{[^}]*background:#161311/);
  assert.match(block, /\.mv-card\{[^}]*background:#161311/);
  assert.match(block, /\.mv-banner\{[^}]*color:var\(--bg\)/);
  assert.match(block, /var\(--accent\)/);
  assert.match(block, /var\(--head\)/);
  assert.match(block, /\.mv-banner-close\{[^}]*width:44px/);
  assert.doesNotMatch(block, /var\(--green\)/);
  assert.equal((block.match(/#161311/g) || []).length, 2);
  assert.doesNotMatch(block.replaceAll('#161311', ''), /#[0-9a-fA-F]{3,8}/);
});
