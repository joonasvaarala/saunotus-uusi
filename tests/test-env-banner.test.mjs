// Testiympäristön banneri tulee buildin lipusta (TEST_ENV_BANNER), ei selaimen osoitteesta.
// Tuotantobuild keskeytyy, jos lippu on päällä, eikä distiin saa jäädä banneria.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DEV_SUPABASE_URL, PROD_SUPABASE_URL } from '../src/site-target.mjs';
import {
  TEST_BANNER_BG, TEST_BANNER_COPY, TEST_BANNER_FG, assertTestBannerFlag, bannerCss, injectTestBanner,
  testBannerEnabled, testBannerHtml, testBannerProblems,
} from '../src/test-env-banner.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const KEY = 'sb_publishable_testiavain';
const GH = 'https://joonasvaarala.github.io/saunotus-uusi';

function contrast(hex, other) {
  const lin = (h) => {
    const c = [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255).map((x) => (x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4));
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  };
  const [a, b] = [lin(hex), lin(other)].sort((p, q) => q - p);
  return (a + 0.05) / (b + 0.05);
}

test('lippu seuraa buildin ympäristöä eikä päästä tuotantoon', () => {
  assert.equal(testBannerEnabled({ SITE_ENV: 'test', TEST_ENV_BANNER: 'on' }), true);
  assert.equal(testBannerEnabled({ SITE_ENV: 'prod', TEST_ENV_BANNER: 'off' }), false);
  assert.equal(testBannerEnabled({ SITE_ENV: 'prod', TEST_ENV_BANNER: 'on' }), false);
  assert.equal(testBannerEnabled({ SITE_ENV: 'prod' }), false);
  assert.equal(testBannerEnabled({ SITE_ENV: 'test' }), true);
  assert.equal(testBannerEnabled({ SITE_ENV: 'test', TEST_ENV_BANNER: 'off' }), false);
  assert.equal(testBannerEnabled({}), false);
  assert.equal(assertTestBannerFlag({ SITE_ENV: 'test', TEST_ENV_BANNER: 'on' }), true);
  assert.equal(assertTestBannerFlag({ SITE_ENV: 'prod', TEST_ENV_BANNER: 'off' }), false);
  assert.throws(() => assertTestBannerFlag({ SITE_ENV: 'prod', TEST_ENV_BANNER: 'on' }), /TEST_ENV_BANNER=off/);
  assert.throws(() => assertTestBannerFlag({ SITE_ENV: 'test', TEST_ENV_BANNER: 'off' }), /TEST_ENV_BANNER=on/);
  assert.throws(() => assertTestBannerFlag({ SITE_ENV: 'prod', TEST_ENV_BANNER: 'kyllä' }), /on tai off/);
});

test('teksti on kovakoodattu suomeksi ja englanniksi, kontrasti riittää', () => {
  const fi = testBannerHtml('fi');
  const en = testBannerHtml('en');
  assert.match(fi, /id="test-env-banner"/);
  assert.match(fi, /<strong>Testiympäristö<\/strong>/);
  assert.match(fi, new RegExp(TEST_BANNER_COPY.fi.text.replace(/[.]/g, '\\.')));
  assert.match(en, /<strong>Test environment<\/strong>/);
  assert.match(en, /This is a test version/);
  assert.doesNotMatch(fi + en, /location\.hostname|github\.io|saunotus\.fi/);
  assert.ok(contrast(TEST_BANNER_FG, TEST_BANNER_BG) >= 4.5, `kontrasti ${contrast(TEST_BANNER_FG, TEST_BANNER_BG)}`);
  assert.match(bannerCss('hallinta'), new RegExp(TEST_BANNER_BG));
  assert.match(bannerCss('hallinta'), /position:sticky/);
  assert.match(bannerCss('hallinta'), /safe-area-inset-top/);
  assert.match(bannerCss('public'), /\.site-sticky\{position:sticky/);
});

test('hallinnan lähde ei sisällä banneria: build lisää sen vain testiin', () => {
  for (const p of ['booking/admin/index.html', 'booking/admin/offline.html', 'booking/admin/admin.css', 'booking/admin/admin.js']) {
    assert.doesNotMatch(read(p), /test-env-banner|TEST_ENV_BANNER|Testiympäristö/);
  }
  assert.doesNotMatch(read('booking/admin/admin.js') + read('src/render.mjs'), /location\.hostname|location\.host/);
  assert.match(read('scripts/build-pages.mjs'), /assertTestBannerFlag\(\)/);
  assert.match(read('scripts/build-pages.mjs'), /testBannerProblems\(OUT/);
  assert.match(read('scripts/build-site.sh'), /tuotanto vaatii TEST_ENV_BANNER=off/);
  assert.match(read('src/render.mjs'), /testBannerEnabled\(\)/);
  assert.doesNotMatch(read('src/render.mjs'), /class="testbar"/);
});

test('injektio on sivun kärjessä eikä peitä kirjautumista tai salasanan asetusta', () => {
  const src = read('booking/admin/index.html');
  const html = injectTestBanner(src, { lang: 'fi', kind: 'hallinta' });
  const banner = html.indexOf('id="test-env-banner"');
  assert.ok(banner > 0);
  assert.ok(banner < html.indexOf('id="app"'));
  assert.ok(banner < html.indexOf('id="login-screen"'));
  assert.ok(banner < html.indexOf('id="setpw-screen"'));
  assert.match(html, /viewport-fit=cover/);
  assert.match(html, /--test-banner-h/);
  assert.equal(injectTestBanner(html, { lang: 'fi', kind: 'hallinta' }).match(/id="test-env-banner"/g).length, 1);
  const offline = injectTestBanner(read('booking/admin/offline.html'), { lang: 'fi', kind: 'offline' });
  assert.match(offline, /id="test-env-banner"/);
  assert.match(offline, /padding:0/);
  assert.ok(offline.indexOf('id="test-env-banner"') < offline.indexOf('<main>'));
});

test('build-pages keskeytyy ennen koonnia, jos tuotantoon yritetään banneria', () => {
  const run = (env) => spawnSync(process.execPath, ['scripts/build-pages.mjs'], {
    cwd: root, encoding: 'utf8', env: { PATH: process.env.PATH, ...env },
  });
  const prodOn = run({
    SITE_ENV: 'prod', SITE_URL: 'https://saunotus.fi', BOOKING_SUPABASE_URL: PROD_SUPABASE_URL,
    BOOKING_ANON_KEY: KEY, TEST_ENV_BANNER: 'on',
  });
  assert.equal(prodOn.status, 2);
  assert.match(prodOn.stderr, /TEST_ENV_BANNER=off/);
  assert.doesNotMatch(prodOn.stderr + prodOn.stdout, /build-pages ok|booking\/shop\/build/);
  const testOff = run({
    SITE_ENV: 'test', SITE_URL: GH, BOOKING_SUPABASE_URL: DEV_SUPABASE_URL,
    BOOKING_ANON_KEY: KEY, TEST_ENV_BANNER: 'off',
  });
  assert.equal(testOff.status, 2);
  assert.match(testOff.stderr, /testibuild vaatii TEST_ENV_BANNER=on/);
});

function fakeDist(enabled) {
  const dir = mkdtempSync(join(tmpdir(), 'banner-'));
  const files = {
    'hallinta/config.js': `window.BOOKING_CONFIG=${JSON.stringify({ testBanner: enabled }, null, 2)};\n`,
    'hallinta/index.html': enabled
      ? `<body>\n${testBannerHtml('fi')}<div id="app"><section id="login-screen"></section><section id="setpw-screen"></section></div>`
      : '<body><div id="app"></div>',
    'hallinta/offline.html': enabled ? `<body>${testBannerHtml('fi')}` : '<body><p>offline</p>',
    'index.html': enabled ? testBannerHtml('fi') : '<p>etusivu</p>',
    'en/index.html': enabled ? testBannerHtml('en') : '<p>home</p>',
    'varaa/index.html': enabled ? testBannerHtml('fi') : '<p>varaa</p>',
    'en/book/index.html': enabled ? testBannerHtml('en') : '<p>book</p>',
    'juomat/index.html': enabled ? testBannerHtml('fi') : '<p>juomat</p>',
    'en/drinks/index.html': enabled ? testBannerHtml('en') : '<p>drinks</p>',
    'vuoro/index.html': enabled ? testBannerHtml('fi') : '<p>vuoro</p>',
    'vuoro/oma/index.html': enabled ? testBannerHtml('fi') : '<p>oma</p>',
    'booking/site-texts.json': JSON.stringify({ texts: [{ key: 'ui.site.site_test_note', text: 'Testiympäristö – ei julkinen julkaisu.' }] }),
  };
  for (const [rel, body] of Object.entries(files)) {
    const path = join(dir, rel);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, body);
  }
  return dir;
}

test('dist-tarkistus hylkää tuotantotulosteen, jossa banneri on päällä', () => {
  const prod = fakeDist(false);
  const testDist = fakeDist(true);
  try {
    assert.deepEqual(testBannerProblems(prod, { enabled: false }), []);
    assert.deepEqual(testBannerProblems(testDist, { enabled: true }), []);
    writeFileSync(join(prod, 'hallinta/index.html'), `<body>${testBannerHtml('fi')}<div id="app"></div>`);
    const bad = testBannerProblems(prod, { enabled: false });
    assert.ok(bad.some((m) => /hallinta\/index.html/.test(m) && /tuotantotulosteessa/.test(m)));
    writeFileSync(join(prod, 'hallinta/index.html'), '<body><div id="app"></div>');
    writeFileSync(join(prod, 'hallinta/config.js'), 'window.BOOKING_CONFIG={"testBanner": true};\n');
    assert.ok(testBannerProblems(prod, { enabled: false }).some((m) => /config\.js/.test(m)));
  } finally {
    rmSync(prod, { recursive: true, force: true });
    rmSync(testDist, { recursive: true, force: true });
  }
});

test('julkinen sivupohja lisää bannerin vain testibuildissa', () => {
  const run = (siteEnv, flag) => spawnSync(process.execPath, ['--input-type=module', '-e', `
    import { layout } from './src/render.mjs';
    const html = layout({ lang: 'fi', key: 'home', meta: { title: 't', description: 'd' }, body: '<p>x</p>' });
    const en = layout({ lang: 'en', key: 'home', meta: { title: 't', description: 'd' }, body: '<p>x</p>' });
    if (!html.includes('<header class="site-header">')) process.exit(4);
    process.stdout.write(JSON.stringify({
      fi: html.includes('id="test-env-banner"'),
      en: en.includes('id="test-env-banner"') && en.includes('Test environment'),
      sentence: html.includes(${JSON.stringify(TEST_BANNER_COPY.fi.text)}),
      sticky: html.includes('class="site-sticky"'),
    }));
  `], {
    cwd: root, encoding: 'utf8',
    env: {
      PATH: process.env.PATH, SITE_ENV: siteEnv, TEST_ENV_BANNER: flag,
      SITE_URL: siteEnv === 'prod' ? 'https://saunotus.fi' : 'https://example.test',
      IMAGE_TRANSFORMS: 'on',
    },
  });
  const on = run('test', 'on');
  assert.equal(on.status, 0, on.stderr);
  assert.deepEqual(JSON.parse(on.stdout), { fi: true, en: true, sentence: true, sticky: true });
  const off = run('prod', 'off');
  assert.equal(off.status, 0, off.stderr);
  assert.deepEqual(JSON.parse(off.stdout), { fi: false, en: false, sentence: false, sticky: false });
  assert.doesNotMatch(off.stdout, /Testiympäristö|test-env-banner/);
});
