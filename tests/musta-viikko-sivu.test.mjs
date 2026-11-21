// Savusaunan musta viikko – kampanjasivu /musta-viikko/ ja /en/black-week/.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

delete process.env.SITE_ENV;
process.env.SITE_URL = 'https://saunotus.fi';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const {
  MUSTA_VIIKKO_ENDS, MUSTA_VIIKKO_OFFERS, MUSTA_VIIKKO_PAGE_TEXTS,
  mustaViikkoActive, mustaViikkoOfferHref, mustaViikkoBody, mustaViikkoMeta, mustaViikkoBootScript, mvpText,
} = await import('../src/musta-viikko-sivu.mjs');
const { money, pagePath, pageHref } = await import('../src/lib.mjs');
const { mustaViikko, home, gift } = await import('../src/render.mjs');

const BEFORE = '2026-11-30T09:59:59+02:00';
const AT = '2026-11-30T10:00:00+02:00';

test('polut, pakettikoodit ja päättymishetki', () => {
  assert.equal(pagePath('mustaViikko', 'fi'), '/musta-viikko/');
  assert.equal(pagePath('mustaViikko', 'en'), '/en/black-week/');
  assert.equal(pageHref('mustaViikko', 'fi'), '/musta-viikko/');
  assert.equal(pageHref('mustaViikko', 'en'), '/en/black-week/');
  assert.equal(MUSTA_VIIKKO_ENDS, '2026-11-30T10:00:00+02:00');
  assert.equal(mustaViikkoActive(BEFORE), true);
  assert.equal(mustaViikkoActive(AT), false);
  assert.deepEqual(MUSTA_VIIKKO_OFFERS.map((o) => [o.code, o.price]), [
    ['bf_jalkiloylyt_mato', 130],
    ['mv_yleiset_mato', 50],
  ]);
  assert.equal(mustaViikkoOfferHref('bf_jalkiloylyt_mato', 'fi'), '/lahjakortti/?paketti=bf_jalkiloylyt_mato');
  assert.equal(mustaViikkoOfferHref('mv_yleiset_mato', 'en'), '/en/gift-card/?paketti=mv_yleiset_mato');
});

test('kampanja-aikana kaksi tarjousta, kannan ehtosanamuodot, hinnat ja ostolinkit', () => {
  const fi = mustaViikko('fi', { now: BEFORE });
  const en = mustaViikko('en', { now: BEFORE });
  assert.match(fi, /<h1>Savusaunan musta viikko<\/h1>/);
  assert.match(en, /<h1>Smoke Sauna Black Week<\/h1>/);
  assert.match(fi, /Jälkilöylylahjakortti/);
  assert.match(en, /After Session Sauna gift card/);
  assert.match(fi, /Yleisten vuorojen lahjakortti 2 hengelle/);
  assert.match(en, /Public session gift card for 2 people/);
  assert.match(fi, /Voimassa 6 kk, ma–to\. Ei voimassa 24\.–30\.12\./);
  assert.match(en, /Valid 6 months, Mon–Thu\. Not valid 24–30 Dec\./);
  assert.match(fi, /Voimassa 6 kk, ma–to\. 2 henkeä, voi käyttää kahdessa osassa\. Ei voimassa 24\.–30\.12\. Turvetorstaina maksetaan erotus\./);
  assert.match(en, /On Peat Thursday the difference is paid/);
  assert.match(fi, />130 €</);
  assert.match(en, />€130</);
  assert.match(fi, />50 €</);
  assert.match(en, />€50</);
  assert.match(fi, /href="\/lahjakortti\/\?paketti=bf_jalkiloylyt_mato"/);
  assert.match(fi, /href="\/lahjakortti\/\?paketti=mv_yleiset_mato"/);
  assert.match(en, /href="\/en\/gift-card\/\?paketti=bf_jalkiloylyt_mato"/);
  assert.match(en, /href="\/en\/gift-card\/\?paketti=mv_yleiset_mato"/);
  assert.match(fi, /data-mvp-offers/);
  assert.match(fi, /data-mvp-ended hidden/);
  assert.match(fi, /Date\.now\(\)<Date\.parse\("2026-11-30T10:00:00\+02:00"\)/);
});

test('päättymisen jälkeen ei tarjouskortteja eikä ostolinkkejä; päättynyt-tila ja linkit etusivulle sekä lahjakortteihin', () => {
  const fi = mustaViikko('fi', { now: AT });
  const en = mustaViikko('en', { now: AT });
  assert.match(fi, /Musta viikko on päättynyt/);
  assert.match(en, /Black Week has ended/);
  assert.doesNotMatch(fi, /data-mvp-offers/);
  assert.doesNotMatch(en, /data-mvp-offers/);
  assert.doesNotMatch(fi, /paketti=/);
  assert.doesNotMatch(en, /paketti=/);
  assert.doesNotMatch(fi, /Osta lahjakortti/);
  assert.match(fi, /href="\/"/);
  assert.match(fi, /href="\/lahjakortti\/"/);
  assert.match(en, /href="\/en\/"/);
  assert.match(en, /href="\/en\/gift-card\/"/);
  assert.doesNotMatch(fi, /data-mvp-ended hidden/);
  assert.ok(!fi.includes('data-mvp-offers') && !fi.includes(mustaViikkoBootScript()));
});

test('noindex,nofollow, ei JSON-LD:tä, hreflang FI↔EN', () => {
  const fi = mustaViikko('fi', { now: BEFORE });
  const en = mustaViikko('en', { now: BEFORE });
  assert.match(fi, /<meta name="robots" content="noindex,nofollow">/);
  assert.match(en, /<meta name="robots" content="noindex,nofollow">/);
  assert.doesNotMatch(fi, /application\/ld\+json/);
  assert.doesNotMatch(en, /application\/ld\+json/);
  assert.match(fi, /rel="canonical" href="https:\/\/saunotus\.fi\/musta-viikko\/"/);
  assert.match(en, /rel="canonical" href="https:\/\/saunotus\.fi\/en\/black-week\/"/);
  assert.match(fi, /rel="alternate" hreflang="en" href="https:\/\/saunotus\.fi\/en\/black-week\/"/);
  assert.match(en, /rel="alternate" hreflang="fi" href="https:\/\/saunotus\.fi\/musta-viikko\/"/);
});

test('etusivu, lahjakorttisivu ja valikko eivät linkitä kampanjasivulle', () => {
  const h = home('fi');
  const g = gift('fi');
  const hen = home('en');
  for (const [name, html] of [['home-fi', h], ['home-en', hen], ['gift-fi', g]]) {
    assert.doesNotMatch(html, /\/musta-viikko\//, name);
    assert.doesNotMatch(html, /\/en\/black-week\//, name);
  }
  const nav = h.slice(h.indexOf('<nav'), h.indexOf('</nav>'));
  assert.doesNotMatch(nav, /musta-viikko|black-week/);
});

test('ei Black Friday -sanaa teksteissä eikä lähteissä', () => {
  for (const key of Object.keys(MUSTA_VIIKKO_PAGE_TEXTS)) for (const lang of ['fi', 'en']) {
    assert.doesNotMatch(MUSTA_VIIKKO_PAGE_TEXTS[key][lang], /black\s*friday/i, `${key} ${lang}`);
  }
  for (const f of [
    'src/musta-viikko-sivu.mjs', 'src/styles.css', 'src/render.mjs', 'scripts/build.mjs',
    'content/site.json', 'content/site-texts.pending-import-185.json',
  ]) {
    assert.doesNotMatch(read(f), /black\s*friday/i, f);
  }
  assert.doesNotMatch(mustaViikko('fi', { now: BEFORE }), /black\s*friday/i);
  assert.doesNotMatch(mustaViikko('en', { now: BEFORE }), /black\s*friday/i);
});

test('pending-import-185 vastaa varatekstejä, FI+EN, ei HTML:ää', () => {
  const pending = JSON.parse(read('content/site-texts.pending-import-185.json'));
  const keys = Object.keys(MUSTA_VIIKKO_PAGE_TEXTS);
  assert.equal(pending.length, keys.length * 2);
  for (const key of keys) for (const lang of ['fi', 'en']) {
    const row = pending.find((x) => x.key === key && x.lang === lang);
    assert.ok(row, `${key} ${lang}`);
    assert.equal(row.text, MUSTA_VIIKKO_PAGE_TEXTS[key][lang]);
    assert.equal(row.class, 'normal');
    assert.equal(row.kind, 'plain');
    assert.deepEqual(row.placeholders, []);
    assert.ok(!row.text.includes('<'));
    assert.ok(row.max_len >= row.text.length);
    assert.ok(row.reason.includes('t1871u'));
  }
});

test('CSS: musta tausta, vaalea teksti, kulta-aksentti, ei tummanvihreää', () => {
  const css = read('src/styles.css');
  const start = css.indexOf('/* Savusaunan musta viikko – kampanjasivu');
  assert.ok(start >= 0);
  const block = css.slice(start);
  assert.match(block, /\.mvp\{[^}]*background:#161311/);
  assert.match(block, /color:var\(--bg\)/);
  assert.match(block, /color:var\(--accent\)/);
  assert.match(block, /font-family:var\(--head\)|font:[^;]*var\(--head\)/);
  assert.doesNotMatch(block, /--green/);
  assert.equal((block.match(/#161311/g) || []).length, 1);
  assert.doesNotMatch(block.replaceAll('#161311', ''), /#[0-9a-fA-F]{3,8}/);
});

test('build jättää kampanjasivun pois sivukartasta; sivu syntyy noindexilla', () => {
  const dist = mkdtempSync(join(tmpdir(), 'mvp-build-'));
  const env = {
    ...process.env,
    SITE_TEXTS_FIXTURE: '1',
    ARTICLES_FIXTURE: '1',
    SITE_ENV: 'prod',
    SITE_URL: 'https://saunotus.fi',
    DIST: dist,
  };
  const r = spawnSync('node', ['scripts/build.mjs'], { cwd: root, env, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr || r.stdout);
  const fi = readFileSync(join(dist, 'musta-viikko/index.html'), 'utf8');
  const en = readFileSync(join(dist, 'en/black-week/index.html'), 'utf8');
  const sm = readFileSync(join(dist, 'sitemap.xml'), 'utf8');
  const homeFi = readFileSync(join(dist, 'index.html'), 'utf8');
  assert.match(fi, /noindex,nofollow/);
  assert.match(en, /noindex,nofollow/);
  assert.doesNotMatch(fi, /application\/ld\+json/);
  assert.doesNotMatch(sm, /musta-viikko|black-week/);
  assert.doesNotMatch(homeFi, /\/musta-viikko\/|\/en\/black-week\//);
  rmSync(dist, { recursive: true, force: true });
});
