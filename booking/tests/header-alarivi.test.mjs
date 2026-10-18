// Yläpalkin alarivi ("SAUNOTUS" + "Sipoonjoen Perinnesauna", §18): teksti tekstitaulusta (nav.brand_tagline = {{setting:business_name}}),
// siirtymäajan varateksti, saavutettava nimi (ei aria-hidden), tuontitiedosto, tyylit (väri/kontrasti/koko, 68 px:n palkki → sticky-offsetit ennallaan). Ei verkkoa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const root = resolve(new URL('../..', import.meta.url).pathname);
delete process.env.SITE_ENV; process.env.SITE_URL = 'https://uusi.saunotus.com';
const R = await import('../../src/render.mjs');
const ST = await import('../../src/site-texts.mjs');
const L = await import('../../booking/shop/src/site-texts-logic.js');
const J = (f) => JSON.parse(readFileSync(resolve(root, f), 'utf8'));
const css = readFileSync(resolve(root, 'src/styles.css'), 'utf8');
const quiet = { warn() {}, log() {} };
const PENDING = J('content/site-texts.pending-import-3.json');
const FALLBACK = J('content/site-texts.fallback.json');

const stateWith = (rows, settings = { business_name: 'Sipoonjoen Perinnesauna' }) => ({ idx: L.indexTexts(rows), ctx: L.makeContext({ catalog: [], settings }) });
const render = (lang, state) => {
  ST.setSiteTexts(state);
  const w = console.warn; console.warn = () => {};
  try { return R.layout({ lang, key: 'home', meta: { title: 't', description: 'd' }, body: '<p>x</p>' }); } finally { console.warn = w; ST.setSiteTexts(null); }
};
const header = (html) => html.match(/<header class="site-header">[\s\S]*?<\/header>/)[0];
const brandLink = (html) => header(html).match(/<a class="brand"[\s\S]*?<\/a>/)[0];

test('tuontitiedosto pending-import-3: nav.brand_tagline FI+EN, paikkamerkki {{setting:business_name}}, §18.2-säännöt, ei tuotannossa jo', () => {
  assert.deepEqual(PENDING.map((r) => `${r.key}|${r.lang}`).sort(), ['nav.brand_tagline|en', 'nav.brand_tagline|fi']);
  const have = new Set(FALLBACK.texts.map((r) => `${r.key}|${r.lang}`));
  for (const r of PENDING) {
    assert.match(r.key, L.KEY_RE); assert.match(r.key, /^(ui|page|seo|email|nav)\./);
    assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain');
    assert.equal(r.text, '{{setting:business_name}}');
    assert.deepEqual(r.placeholders, L.tokensOf(r.text)); assert.match(r.placeholders[0], L.TOKEN_RE);
    assert.ok(Number.isInteger(r.max_len) && r.max_len >= r.text.length); assert.ok(r.reason && r.reason.length <= 300);
    assert.ok(!have.has(`${r.key}|${r.lang}`), `${r.key} [${r.lang}] on jo tuotannossa`);
  }
});

test('yläpalkin alarivi tulee tekstitaulusta ja asetuksesta business_name (iso P), FI ja EN', () => {
  const st = stateWith(PENDING.map((r) => ({ key: r.key, lang: r.lang, text: r.text, placeholders: r.placeholders })));
  for (const lang of ['fi', 'en']) {
    const a = brandLink(render(lang, st));
    assert.match(a, /<b>SAUNOTUS<\/b> <small>Sipoonjoen Perinnesauna<\/small>/, lang);
  }
  // asetuksen muutos näkyy alarivillä (ei kovakoodattu)
  assert.match(brandLink(render('fi', stateWith(PENDING, { business_name: 'Testinimi' }))), /<small>Testinimi<\/small>/);
});

test('avain puuttuu tietokannasta → siirtymäajan varateksti site.json:n brandTitle (iso P), ei tyhjää eikä raakaa avainta', () => {
  for (const lang of ['fi', 'en']) {
    const a = brandLink(render(lang, stateWith([])));
    assert.match(a, /<small>Sipoonjoen Perinnesauna<\/small>/); assert.doesNotMatch(a, /nav\.brand_tagline|\{\{/);
  }
  assert.match(brandLink(render('fi', null)), /<small>Sipoonjoen Perinnesauna<\/small>/);
});

test('saavutettavuus: alarivi on osa etusivulinkin nimeä (ei aria-hidden, ei display:none millään leveydellä), kuvake koristeena', () => {
  const a = brandLink(render('fi', stateWith([])));
  assert.doesNotMatch(a, /aria-hidden|aria-label/); assert.match(a, /<img [^>]*alt=""/);
  const txt = a.replace(/<img[^>]*>/, '').replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();
  assert.equal(txt, 'SAUNOTUS Sipoonjoen Perinnesauna');
  assert.doesNotMatch(css, /\.brand small\{[^}]*display:none/);
  assert.equal(header(render('fi', stateWith([]))).match(/<small>/g).length, 1);
});

test('tyylit: alarivi kullalla (#7A5530 hiekalla ≥ 4,5:1), versaali + harvennus, palkin korkeus 68 px ennallaan (sticky-offsetit 69/80/84/90 px)', () => {
  const lum = (h) => { const c = [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255).map((x) => (x <= .03928 ? x / 12.92 : ((x + .055) / 1.055) ** 2.4)); return .2126 * c[0] + .7152 * c[1] + .0722 * c[2]; };
  const cr = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + .05) / (y + .05); };
  const vars = Object.fromEntries([...css.matchAll(/--(gold|bg):(#[0-9A-Fa-f]{6})/g)].map((m) => [m[1], m[2]]));
  const small = css.match(/\.brand small\{([^}]*)\}/)[1];
  assert.match(small, /color:var\(--gold\)/); assert.match(small, /text-transform:uppercase/); assert.match(small, /letter-spacing:\.1\d*em/);
  assert.ok(cr(vars.gold, vars.bg) >= 4.5, `kontrasti ${cr(vars.gold, vars.bg)}`);
  assert.match(css, /\.hdr\{[^}]*min-height:68px/);
  assert.match(css, /\.brand-txt\{[^}]*flex-direction:column/);
  // kapeilla näytöillä alarivi rivittyy (ei vaakavieritystä) eikä koskaan piiloudu
  assert.match(css, /@media \(max-width:640px\)\{[^@]*\.brand small\{[^}]*white-space:normal/);
});
