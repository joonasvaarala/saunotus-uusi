// Savusaunan musta viikko: luonnos (yläbanneri + etusivun kortti), oletuksena piilossa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const {
  MUSTA_VIIKKO_PACKAGE, MUSTA_VIIKKO_PACKAGE_YLEISET, MUSTA_VIIKKO_ENABLED, MUSTA_VIIKKO_PREVIEW, MUSTA_VIIKKO_STORAGE_KEY,
  MUSTA_VIIKKO_PRICE, MUSTA_VIIKKO_PRICE_YLEISET, MUSTA_VIIKKO_ENDS, MUSTA_VIIKKO_TEXTS, MUSTA_VIIKKO_IMAGE, MUSTA_VIIKKO_IMAGE_ALT, MUSTA_VIIKKO_IMAGE_SIZE,
  mustaViikkoActive, mustaViikkoEnvOn, mustaViikkoBuildIncludes, mustaViikkoHref, mustaViikkoPrice,
  mustaViikkoOfferHref, mustaViikkoBannerHtml, mustaViikkoCardHtml, mustaViikkoBootScript,
} = await import('../src/musta-viikko.mjs');
const { money, pageHref } = await import('../src/lib.mjs');
const { home, layout } = await import('../src/render.mjs');

test('oletuksena pois päältä; paketin koodi yhdessä vakiossa', () => {
  assert.equal(MUSTA_VIIKKO_ENABLED, false);
  assert.equal(MUSTA_VIIKKO_PACKAGE, 'bf_jalkiloylyt_mato');
  assert.equal(MUSTA_VIIKKO_PACKAGE_YLEISET, 'mv_yleiset_mato');
  assert.equal(MUSTA_VIIKKO_PREVIEW, 'musta-viikko');
  assert.equal(MUSTA_VIIKKO_PRICE, 130);
  assert.equal(MUSTA_VIIKKO_PRICE_YLEISET, 50);
  assert.equal(MUSTA_VIIKKO_IMAGE, 'mv-mainos');
  assert.deepEqual(MUSTA_VIIKKO_IMAGE_SIZE, { w: 1600, h: 700 });
  assert.equal(mustaViikkoEnvOn('test'), true);
  assert.equal(mustaViikkoEnvOn('prod'), true);
  assert.equal(mustaViikkoEnvOn(''), false);
  assert.equal(mustaViikkoBuildIncludes('prod'), true);
  assert.equal(mustaViikkoBuildIncludes('test'), true);
  assert.equal(mustaViikkoBuildIncludes(''), true);
  const src = read('src/musta-viikko.mjs');
  const others = [
    'src/render.mjs', 'src/home-front.mjs', 'src/styles.css',
    'content/site-texts.pending-import-183.json',
  ].map(read).join('\n');
  assert.equal([...src.matchAll(/MUSTA_VIIKKO_PACKAGE = '/g)].length, 1);
  assert.doesNotMatch(others, /bf_jalkiloylyt_mato/);
});

test('bannerin ja kortin linkki on kampanjasivu, FI ja EN', () => {
  assert.equal(mustaViikkoHref('fi'), '/musta-viikko/');
  assert.equal(mustaViikkoHref('en'), '/en/black-week/');
  assert.equal(mustaViikkoHref('fi'), pageHref('mustaViikko', 'fi'));
  assert.equal(mustaViikkoHref('en'), pageHref('mustaViikko', 'en'));
  assert.match(read('src/musta-viikko.mjs'), /pageHref\('mustaViikko'/);
});

test('hinta 130 € ja 50 € sivuston money-muodossa', () => {
  assert.equal(mustaViikkoPrice('fi'), money(130, 'fi'));
  assert.equal(mustaViikkoPrice('en'), money(130, 'en'));
  assert.equal(mustaViikkoPrice('fi'), '130 €');
  assert.equal(mustaViikkoPrice('en'), '€130');
  assert.equal(mustaViikkoPrice('fi', 50), '50 €');
  assert.equal(mustaViikkoPrice('en', 50), '€50');
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
    const ph = key === 'ui.site.mv_regular' ? ['{{var:price}}'] : [];
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
  for (const f of ['src/musta-viikko.mjs', 'src/styles.css', 'src/render.mjs', 'content/site-texts.pending-import-183.json', 'content/site-texts.pending-import-186.json', 'content/site-texts.pending-import-187.json']) {
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
    assert.ok(banner.includes(MUSTA_VIIKKO_TEXTS['ui.site.mv_banner_offers'][lang]));
    assert.ok(banner.includes(MUSTA_VIIKKO_TEXTS['ui.site.mv_see'][lang]));
    assert.match(banner, /class="mv-banner-sep"[^>]*>–/);
    assert.match(banner, /class="mv-banner-text"/);
    assert.match(banner, /class="mv-banner-cta"/);
    assert.doesNotMatch(banner, /class="mv-banner-text">–/);
    assert.match(banner, /data-mv-close/);
    assert.ok(banner.includes(MUSTA_VIIKKO_TEXTS['ui.site.mv_close'][lang]));
    assert.doesNotMatch(banner, /\?paketti=/);
    assert.ok(card.includes(MUSTA_VIIKKO_TEXTS['ui.site.mv_title'][lang]));
    assert.ok(card.includes(MUSTA_VIIKKO_TEXTS['ui.site.mv_product'][lang]));
    assert.ok(card.includes(MUSTA_VIIKKO_TEXTS['ui.site.mv_product_b'][lang]));
    assert.ok(card.includes(MUSTA_VIIKKO_TEXTS['ui.site.mv_card_text'][lang]));
    assert.ok(card.includes(price));
    assert.ok(card.includes(mustaViikkoPrice(lang, 50)));
    assert.ok(card.includes(mustaViikkoPrice(lang, 180)));
    assert.ok(card.includes(mustaViikkoPrice(lang, 58)));
    assert.match(card, /<del class="mv-price-was">/);
    assert.match(card, /Normaalihinta|Regular price/);
    assert.ok(card.includes(MUSTA_VIIKKO_TEXTS['ui.site.mv_see'][lang]));
    assert.match(card, /class="btn gold"/);
    assert.ok(card.includes(href));
    assert.doesNotMatch(card, /\?paketti=/);
    assert.match(card, /mv-mainos/);
    assert.match(card, /<img /);
    assert.ok(card.includes(MUSTA_VIIKKO_IMAGE_ALT[lang]));
    assert.match(card, /class="mv-ad"/);
    assert.match(card, /class="mv-ad-visual"/);
    assert.match(card, /class="mv-ad-media"/);
    assert.match(card, /class="mv-ad-body"/);
    assert.doesNotMatch(card, /mv-ad-in|mv-ad-shade/);
    assert.doesNotMatch(banner, /<[a-z][^>]*>[^<]*(?:javascript:|on\w+=)/i);
  }
  const boot = mustaViikkoBootScript();
  assert.ok(boot.includes('false'));
  assert.ok(boot.includes('preview'));
  const bootTest = mustaViikkoBootScript('test');
  assert.match(bootTest, /var on=true/);
  assert.match(mustaViikkoBootScript('prod'), /var on=true/);
  assert.match(mustaViikkoBannerHtml('fi', Date.now(), 'prod'), /data-mv-banner/);
  assert.match(mustaViikkoCardHtml('en', Date.now(), 'prod'), /data-mv-promo/);
  assert.equal(mustaViikkoBannerHtml('fi', Date.parse('2026-11-30T10:00:01+02:00'), 'prod'), '');
  assert.ok(boot.includes(MUSTA_VIIKKO_PREVIEW));
  assert.ok(boot.includes(MUSTA_VIIKKO_STORAGE_KEY));
  assert.ok(boot.includes(MUSTA_VIIKKO_ENDS));
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
  assert.ok(fi.includes('/musta-viikko/'));
  assert.ok(en.includes('/en/black-week/'));
  assert.doesNotMatch(fi.match(/data-mv-banner[\s\S]*?<\/div><header/)?.[0] || '', /\?paketti=/);
  assert.ok(fi.includes('jälkilöylyt ja yleiset vuorot lahjakorttina ma–to'));
  assert.ok(fi.includes('Katso tarjoukset →'));
  assert.ok(fi.includes('Jälkilöylylahjakortti'));
  assert.ok(fi.includes('Yleisten vuorojen lahjakortti 2 hengelle'));
  assert.ok(fi.includes('Voimassa 6 kk, ma–to'));
  assert.ok(fi.includes('130 €'));
  assert.ok(fi.includes('50 €'));
  assert.ok(fi.includes('180 €'));
  assert.ok(fi.includes('58 €'));
  assert.match(fi, /<del class="mv-price-was">/);
  assert.ok(fi.includes('Normaalihinta 180 €'));
  assert.ok(fi.includes('Normaalihinta 58 €'));
  assert.ok(en.includes('After Session and public session gift cards, Mon–Thu'));
  assert.ok(en.includes('See the offers →'));
  assert.ok(en.includes('After Session Sauna gift card'));
  assert.ok(en.includes('Public session gift card for 2 people'));
  assert.ok(en.includes('Valid 6 months, Mon–Thu'));
  assert.ok(en.includes('€130'));
  assert.ok(en.includes('€50'));
  assert.ok(en.includes('€180'));
  assert.ok(en.includes('€58'));
  assert.match(en, /<del class="mv-price-was">/);
  assert.ok(en.includes('Regular price €180'));
  assert.ok(en.includes('Regular price €58'));
  assert.doesNotMatch(fi + en, /\?paketti=/);
  assert.doesNotMatch(fi + en, /black\s*friday/i);
});

test('CSS: musta tausta, vaalea teksti, kulta-aksentti, ei tummanvihreää', () => {
  const css = read('src/styles.css');
  const start = css.indexOf('Savusaunan musta viikko: yläbanneri');
  const end = css.indexOf('Savusaunan musta viikko – kampanjasivu');
  const block = css.slice(start, end === -1 ? undefined : end);
  assert.match(block, /\.mv-banner\{[^}]*background:#161311/);
  assert.match(block, /\.mv-ad\{[^}]*background:#120D0A/);
  assert.match(block, /\.mv-ad-title\{[^}]*color:#F5F3EF/);
  assert.match(block, /\.mv-price\{[^}]*color:#D2B478/);
  assert.match(block, /\.mv-ad-cta/);
  assert.match(block, /\.mv-banner-cta/);
  assert.match(block, /\.mv-ad-visual\{[^}]*aspect-ratio:1600\/700/);
  assert.match(block, /\.mv-ad-media/);
  assert.match(block, /aspect-ratio:900\/1100/);
  assert.doesNotMatch(block, /mv-ad-shade/);
  assert.match(block, /\.mv-banner\{[^}]*color:var\(--bg\)/);
  assert.match(block, /var\(--accent\)/);
  assert.match(block, /var\(--head\)/);
  assert.match(block, /\.mv-banner-close\{[^}]*width:44px/);
  assert.doesNotMatch(block, /var\(--green\)/);
  assert.equal((block.match(/#161311/g) || []).length, 1);
  const allowed = ['#161311', '#1B1511', '#120D0A', '#F5F3EF', '#D2B478'];
  let rest = block;
  for (const c of allowed) rest = rest.replaceAll(c, '');
  assert.doesNotMatch(rest, /#[0-9a-fA-F]{3,8}/);
  assert.match(block, /@media \(max-width:640px\)/);
  assert.match(block, /@media \(max-width:700px\)/);
  assert.match(block, /\.mv-banner-link\{[^}]*flex-direction:column/);
  assert.match(block, /\.mv-banner-sep\{display:none\}/);
});

test('mainoskuvat: art direction, desktop 1x alle 250 kt', () => {
  const files = [
    'public/img/mv-mainos-desktop.jpg',
    'public/img/mv-mainos-desktop.webp',
    'public/img/mv-mainos-desktop@2x.jpg',
    'public/img/mv-mainos-desktop@2x.webp',
    'public/img/mv-mainos-mobiili.jpg',
    'public/img/mv-mainos-mobiili.webp',
    'public/img/mv-mainos-mobiili@2x.jpg',
    'public/img/mv-mainos-mobiili@2x.webp',
  ];
  for (const f of files) assert.ok(existsSync(join(root, f)), f);
  assert.ok(statSync(join(root, 'public/img/mv-mainos-desktop.jpg')).size < 250_000);
  assert.ok(!existsSync(join(root, 'public/img/mv-mainos-800.jpg')));
  assert.ok(!existsSync(join(root, 'public/img/mv-mainos-1200.jpg')));
  assert.match(MUSTA_VIIKKO_IMAGE_ALT.fi, /noen mustaamilla lauteilla/);
  assert.match(MUSTA_VIIKKO_IMAGE_ALT.en, /soot-blackened benches/i);
  assert.ok(statSync(join(root, 'public/img/mv-mainos-desktop.jpg')).size < 250_000);
  assert.ok(statSync(join(root, 'public/img/mv-mainos-mobiili.jpg')).size < 250_000);
});

test('aikaohjaus: banneri ja etusivun kortti eivät renderöidy 30.11.2026 klo 10 (Helsinki) jälkeen', () => {
  assert.equal(MUSTA_VIIKKO_ENDS, '2026-11-30T10:00:00+02:00');
  const before = Date.parse('2026-11-30T09:59:59+02:00');
  const at = Date.parse('2026-11-30T10:00:00+02:00');
  const after = Date.parse('2026-11-30T10:00:01+02:00');
  assert.equal(mustaViikkoActive(before), true);
  assert.equal(mustaViikkoActive(at), false);
  assert.equal(mustaViikkoActive(after), false);
  assert.match(mustaViikkoBannerHtml('fi', before), /data-mv-banner/);
  assert.match(mustaViikkoCardHtml('fi', before), /data-mv-promo/);
  assert.equal(mustaViikkoBannerHtml('fi', at), '');
  assert.equal(mustaViikkoCardHtml('en', at), '');
  assert.equal(mustaViikkoBannerHtml('en', after), '');
  assert.equal(mustaViikkoCardHtml('fi', after), '');
  const ended = home('fi', { now: at });
  assert.doesNotMatch(ended, /class="mv-banner"/);
  assert.doesNotMatch(ended, /class="mv-ad"/);
  assert.doesNotMatch(ended, /data-mv-banner hidden/);
  assert.doesNotMatch(ended, /data-mv-promo hidden/);
  assert.doesNotMatch(ended, /mustaViikkoBootScript|saunotus:musta-viikko:dismissed/);
  const live = home('fi', { now: before });
  assert.match(live, /data-mv-banner hidden/);
  assert.match(live, /data-mv-promo hidden/);
});

test('t1885u: normaalihinta yhdestä vakiosta, yliviivaus mainoksessa', async () => {
  const { MUSTA_VIIKKO_REGULAR_PRICE, regularListPrice } = await import('../booking/shop/src/gift-logic.js');
  assert.equal(regularListPrice('bf_jalkiloylyt_mato'), 180);
  assert.equal(regularListPrice('mv_yleiset_mato'), 58);
  assert.equal(regularListPrice('open'), null);
  assert.equal(MUSTA_VIIKKO_REGULAR_PRICE.bf_jalkiloylyt_mato, 180);
  const pending = JSON.parse(read('content/site-texts.pending-import-187.json'));
  assert.equal(pending.length, 2);
  for (const lang of ['fi', 'en']) {
    const row = pending.find((x) => x.key === 'ui.site.mv_regular' && x.lang === lang);
    assert.ok(row);
    assert.equal(row.text, MUSTA_VIIKKO_TEXTS['ui.site.mv_regular'][lang]);
    assert.deepEqual(row.placeholders, ['{{var:price}}']);
  }
  const css = read('src/styles.css');
  assert.match(css, /\.mv-price-was\{[^}]*text-decoration:line-through/);
  assert.match(read('booking/shop/src/shop.css'), /\.gc-price-was\{[^}]*text-decoration:line-through/);
  assert.match(read('booking/shop/src/gift.js'), /regularListPrice/);
});
