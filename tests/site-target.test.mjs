// Testi- ja tuotantobuild eivät saa sekoittua. Ei verkkoa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { assertBuildTarget, chatbotWidgetSrc, DEV_SUPABASE_URL, productStorageBase, PROD_SITE, PROD_SUPABASE_URL } from '../src/site-target.mjs';
import { refreshProductImages, productImageFor, productImageUrl } from '../src/product-images.mjs';
import { shiftOfferApi as vuoroApi } from '../booking/vuoro/vuoro.js';
import { shiftOfferApi as omaApi } from '../booking/vuoro/oma/oma.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const KEY = 'sb_publishable_testiavain';

test('tuotantobuild vaatii tuotantoprojektin ja saunotus.fi:n', () => {
  assert.doesNotThrow(() => assertBuildTarget({ siteEnv: 'prod', siteUrl: 'https://saunotus.fi', supabaseUrl: PROD_SUPABASE_URL }));
  assert.doesNotThrow(() => assertBuildTarget({ siteEnv: 'prod', siteUrl: 'https://saunotus.fi/', supabaseUrl: PROD_SUPABASE_URL + '/' }));
  assert.throws(() => assertBuildTarget({ siteEnv: 'prod', siteUrl: 'https://saunotus.fi', supabaseUrl: DEV_SUPABASE_URL }), /tuotantobuild vaatii Supabase/);
  assert.throws(() => assertBuildTarget({ siteEnv: 'prod', siteUrl: 'https://example.test', supabaseUrl: PROD_SUPABASE_URL }), /SITE_URL/);
  assert.throws(() => assertBuildTarget({ siteEnv: 'prod', siteUrl: 'https://www.saunotus.fi', supabaseUrl: PROD_SUPABASE_URL }), /SITE_URL/);
  assert.throws(() => assertBuildTarget({ siteEnv: 'prod', siteUrl: 'https://joonasvaarala.github.io/saunotus-uusi', supabaseUrl: PROD_SUPABASE_URL }), /SITE_URL/);
});

test('testibuild kieltäytyy tuotantoprojektista ja saunotus.fi:stä', () => {
  const gh = 'https://joonasvaarala.github.io/saunotus-uusi';
  assert.doesNotThrow(() => assertBuildTarget({ siteEnv: 'test', siteUrl: gh, supabaseUrl: DEV_SUPABASE_URL }));
  assert.doesNotThrow(() => assertBuildTarget({ siteEnv: 'test', siteUrl: 'http://localhost:4173', supabaseUrl: 'http://localhost:4181' }));
  assert.throws(() => assertBuildTarget({ siteEnv: 'test', siteUrl: gh, supabaseUrl: PROD_SUPABASE_URL }), /tuotannon Supabase/);
  assert.throws(() => assertBuildTarget({ siteEnv: 'test', siteUrl: PROD_SITE, supabaseUrl: DEV_SUPABASE_URL }), /saunotus\.fi/);
  assert.throws(() => assertBuildTarget({ siteEnv: 'test', siteUrl: 'https://www.saunotus.fi/hallinta/', supabaseUrl: DEV_SUPABASE_URL }), /saunotus\.fi/);
  assert.throws(() => assertBuildTarget({ siteEnv: 'test', siteUrl: gh, supabaseUrl: 'https://evil.example/sxbofnuisemspgquoxyv' }), /tuotannon Supabase/);
  assert.throws(() => assertBuildTarget({ siteEnv: '', siteUrl: gh, supabaseUrl: DEV_SUPABASE_URL }), /SITE_ENV/);
});

test('build-pages keskeytyy ennen koonnia, jos ympäristöt sekoittuvat', () => {
  const run = (env) => spawnSync(process.execPath, ['scripts/build-pages.mjs'], {
    cwd: root, encoding: 'utf8', env: { PATH: process.env.PATH, ...env },
  });
  const prodOnTest = run({ SITE_ENV: 'test', SITE_URL: 'https://joonasvaarala.github.io/saunotus-uusi', BOOKING_SUPABASE_URL: PROD_SUPABASE_URL, BOOKING_ANON_KEY: KEY });
  assert.equal(prodOnTest.status, 2);
  assert.match(prodOnTest.stderr, /tuotannon Supabase/);
  assert.doesNotMatch(prodOnTest.stderr + prodOnTest.stdout, /build-pages ok/);
  const testOnProd = run({ SITE_ENV: 'prod', SITE_URL: 'https://saunotus.fi', BOOKING_SUPABASE_URL: DEV_SUPABASE_URL, BOOKING_ANON_KEY: KEY });
  assert.equal(testOnProd.status, 2);
  assert.match(testOnProd.stderr, /tuotantobuild vaatii Supabase/);
  const wrongSite = run({ SITE_ENV: 'prod', SITE_URL: 'https://example.test', BOOKING_SUPABASE_URL: PROD_SUPABASE_URL, BOOKING_ANON_KEY: KEY });
  assert.equal(wrongSite.status, 2);
  assert.match(wrongSite.stderr, /SITE_URL=https:\/\/saunotus\.fi/);
});

test('ympäristötiedostot ja Pages-työnkulku eivät sekoita projekteja', () => {
  const testEnv = read('config/env/test.env');
  const prodEnv = read('config/env/prod.env');
  const yml = read('.github/workflows/pages.yml');
  assert.match(testEnv, /^IMAGE_TRANSFORMS=off$/m);
  assert.doesNotMatch(prodEnv, /^IMAGE_TRANSFORMS=/m);
  assert.match(testEnv, /^SITE_ENV=test$/m);
  assert.match(testEnv, new RegExp(`^SITE_URL=https://joonasvaarala\\.github\\.io/saunotus-uusi$`, 'm'));
  assert.match(testEnv, new RegExp(`^BOOKING_SUPABASE_URL=${DEV_SUPABASE_URL.replace(/[.]/g, '\\.')}$`, 'm'));
  assert.doesNotMatch(testEnv, /sxbofnuisemspgquoxyv|saunotus\.fi|sb_secret_|service_role/);
  assert.match(prodEnv, /^SITE_ENV=prod$/m);
  assert.match(prodEnv, /^SITE_URL=https:\/\/saunotus\.fi$/m);
  assert.match(prodEnv, new RegExp(`^BOOKING_SUPABASE_URL=${PROD_SUPABASE_URL.replace(/[.]/g, '\\.')}$`, 'm'));
  assert.doesNotMatch(prodEnv, /aoejjmfzulhkhxbehphs|github\.io|sb_secret_|service_role/);
  assert.match(yml, /config\/env\/test\.env/);
  assert.match(yml, /site-texts-test-/);
  assert.match(yml, /articles-test-/);
  assert.doesNotMatch(yml, /sxbofnuisemspgquoxyv|sb_publishable_LZFhBH9b/);
  assert.match(read('package.json'), /"build:prod": "bash scripts\/build-site\.sh prod"/);
  assert.match(read('package.json'), /"build:test": "bash scripts\/build-site\.sh test"/);
  const backup = read('.github/workflows/db-backup.yml');
  assert.doesNotMatch(backup, /aoejjmfzulhkhxbehphs/);
  const printed = spawnSync('bash', ['scripts/build-site.sh', '--print-env', 'test'], { cwd: root, encoding: 'utf8' });
  assert.equal(printed.status, 0);
  assert.match(printed.stdout, new RegExp(`BOOKING_SUPABASE_URL=${DEV_SUPABASE_URL}`));
  assert.match(printed.stdout, /^IMAGE_TRANSFORMS=off$/m);
  assert.doesNotMatch(printed.stdout, /sxbofnuisemspgquoxyv/);
  const printedProd = spawnSync('bash', ['scripts/build-site.sh', '--print-env', 'prod'], { cwd: root, encoding: 'utf8' });
  assert.equal(printedProd.status, 0);
  assert.doesNotMatch(printedProd.stdout, /IMAGE_TRANSFORMS/);
  assert.match(printedProd.stdout, new RegExp(`BOOKING_SUPABASE_URL=${PROD_SUPABASE_URL}`));
});

test('chatbot, tuotekuvan varapolku ja vuorosivu seuraavat buildin Supabase-osoitetta', async () => {
  assert.equal(chatbotWidgetSrc(''), '');
  assert.equal(chatbotWidgetSrc(DEV_SUPABASE_URL), `${DEV_SUPABASE_URL}/functions/v1/saunabot/widget.js`);
  assert.equal(productStorageBase(DEV_SUPABASE_URL), `${DEV_SUPABASE_URL}/storage/v1/object/public/product-images`);
  assert.doesNotMatch(read('content/site.json'), /sxbofnuisemspgquoxyv/);
  assert.doesNotMatch(read('booking/vuoro/vuoro.js') + read('booking/vuoro/oma/oma.js'), /sxbofnuisemspgquoxyv/);
  assert.equal(vuoroApi({ url: DEV_SUPABASE_URL }), `${DEV_SUPABASE_URL}/functions/v1/shift-offer-engine`);
  assert.equal(omaApi({ url: PROD_SUPABASE_URL }), `${PROD_SUPABASE_URL}/functions/v1/shift-offer-engine`);
  assert.equal(vuoroApi({}), '');
  const warn = [];
  const failed = await refreshProductImages({
    env: { BOOKING_SUPABASE_URL: DEV_SUPABASE_URL, BOOKING_ANON_KEY: KEY },
    rpc: async () => { throw new Error('406'); },
    log: { warn: (m) => warn.push(m) },
  });
  assert.equal(failed.source, 'file');
  const row = productImageFor('saunahoito-2');
  assert.match(productImageUrl(row), new RegExp(`^${DEV_SUPABASE_URL.replace(/[.]/g, '\\.')}/storage/v1/object/public/product-images/products/10-ifj3bf\\.webp$`));
  assert.doesNotMatch(productImageUrl(row), /sxbofnuisemspgquoxyv/);
  await refreshProductImages({
    env: { BOOKING_SUPABASE_URL: PROD_SUPABASE_URL, BOOKING_ANON_KEY: KEY },
    rpc: async () => { throw new Error('palautus'); },
    log: { warn() {} },
  });
});
