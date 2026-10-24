// booking_159 (Joonas 24.10.2026): 1) Saunotusrituaali (kb 8, 20 €/hlö, 20 min, slug saunotusrituaali) pois hoito- ja rituaalilistoilta (staattinen Hoidot ja rituaalit -sivu
// FI+EN, kaupan tuotelista ja päivänäkymän hoidot); tuote, hinta, slug ja tuotesivu ennallaan, ja se jää lisätuotteeksi. Paketti kb 7 pysyy listalla.
// 2) "Saunarituaali-ilta" → "Saunarituaali ja savusaunavuoro" / "Sauna ritual and smoke sauna session" tuotannon sivuteksteissä (migraatio booking_159). Ei verkkoa, ei tietokantaa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = resolve(new URL('../..', import.meta.url).pathname);
const read = (f) => readFileSync(resolve(root, f), 'utf8');
const tmp = mkdtempSync(join(tmpdir(), 'rituaali-lista-'));
cpSync(new URL('../shop/src/', import.meta.url), tmp, { recursive: true });
cpSync(new URL('../shared/sb.js', import.meta.url), join(tmp, 'sb.js'));
const A = await import(pathToFileURL(join(tmp, 'treatments.js')));
const FX61 = JSON.parse(readFileSync(new URL('./fixtures/prod-catalog-61.json', import.meta.url), 'utf8'));
delete process.env.SITE_ENV; process.env.SITE_URL = 'https://saunotus.fi';
const R = await import('../../src/render.mjs');
const MIG = read('booking/supabase/migrations/20261024171947_booking_159_rituaali_lista.sql');
const RB = read('booking/supabase/rollbacks/20261024171947_booking_159_ROLLBACK.sql');
const sqlCode = (s) => s.split('\n').filter((l) => !l.trimStart().startsWith('--')).join('\n');

test('kauppa: Saunotusrituaali piilotetaan vain listoilta (isListed), tuote 8 säilyy hoitotuotteena (tuotesivu ja varaus toimivat)', () => {
  assert.deepEqual(A.LISTING_HIDDEN_SLUGS, ['saunotusrituaali']);
  const { treatments } = A.splitCatalog(FX61.catalog, new Map());
  const p8 = treatments.find((x) => x.id === 8), p7 = treatments.find((x) => x.id === 7);
  assert.ok(p8, 'tuote 8 on yhä hoitotuote → #/tuote/saunotusrituaali löytää sen');
  assert.equal(p8.slug, 'saunotusrituaali'); assert.equal(p8.price, 20);
  assert.equal(A.isListed(p8), false, 'ei listoilla');
  assert.equal(A.isListed(p7), true, 'paketti kb 7 pysyy listalla');
  assert.deepEqual(treatments.filter(A.isListed).map((x) => x.id), treatments.map((x) => x.id).filter((id) => id !== 8));
  assert.ok(A.KB_IDS.includes(8), 'KB_IDS ennallaan (tuotesivu, järjestys)');
});

test('kauppa: tuotelista, päivänäkymän hoitohaku ja hoito-osion näkyvyys käyttävät suodatinta; tuotesivu ja tilaussivun lisätuotteet eivät', () => {
  const s = read('booking/shop/src/shop.js');
  assert.match(s, /isListed as treatmentListed/);
  assert.match(s, /\.\.\.state\.treatments\.filter\(treatmentListed\)/, 'tuotelista (viewList)');
  assert.match(s, /state\.treatments\.filter\(treatmentListed\)\.map\(/, 'päivänäkymän hoitohaku (fillTreatments)');
  assert.match(s, /state\.treatments\.some\(treatmentListed\)/, 'päivänäkymän hoito-osio');
  assert.equal((s.match(/treatmentListed/g) || []).length, 4, 'ei muita käyttöjä (tuotesivu #/tuote/<slug> ennallaan)');
  assert.doesNotMatch(read('booking/shop/src/order.js'), /isListed|LISTING_HIDDEN/, 'tilaussivun lisätuotteet (upsell) ennallaan');
});

test('Hoidot ja rituaalit -sivu FI+EN: ei Saunotusrituaali-korttia; muut rituaalikortit ja paketin kortti ennallaan', () => {
  for (const lang of ['fi', 'en']) {
    const w = console.warn; console.warn = () => {};
    let html; try { html = R.treatments(lang); } finally { console.warn = w; }
    assert.doesNotMatch(html, /#\/tuote\/saunotusrituaali"/, `${lang}: kortti poistettu`);
    assert.doesNotMatch(html, /#tuote-8"/, `${lang}: ei JSON-LD-tuotetta 8`);
    for (const id of ['avoin-rituaali', 'turvetorstai', 'perinnesaunotusilta']) assert.ok(R.C(`treatments.${id}`), id);
    assert.match(html, /#tuote-7"/, `${lang}: paketti (kb 7) listalla`);
  }
  assert.ok(R.C('treatments.rituaali-lisa'), 'kortin data säilyy (cards.json, tekstiavaimet ui.card.treatments.rituaali_lisa.*)');
});

test('migraatio booking_159: 8 tekstiriviä propose → approve, vanha → uusi, ei hintoja/slugeja/public-skeemaa, ei <-merkkejä', () => {
  const code = sqlCode(MIG);
  const rows = [...code.matchAll(/\(\d, '([a-z0-9_.]+)',\s+'(fi|en)', '([^']+)',\s+'([^']+)'\)/g)].map((m) => m.slice(1));
  assert.equal(rows.length, 8);
  assert.deepEqual([...new Set(rows.map((r) => r[0]))], ['page.front.ritual.title', 'ui.session.ritual', 'hours.9.session_name', 'hours.10.session_name']);
  for (const [, lang, from, to] of rows) {
    assert.equal(from, lang === 'fi' ? 'Saunarituaali-ilta' : 'Sauna ritual evening');
    assert.equal(to, lang === 'fi' ? 'Saunarituaali ja savusaunavuoro' : 'Sauna ritual and smoke sauna session');
  }
  assert.match(code, /booking\.texts_propose\(/); assert.match(code, /booking\.admin_texts_approve\(/);
  assert.doesNotMatch(code, /\bpublic\.|price|vat|slug|alter |create table|drop /i);
  assert.doesNotMatch(code, /update kb\./i, 'lähdetaulu päivittyy vain _text_publishin kautta');
  assert.ok(!MIG.includes('<') && !RB.includes('<'));
});

test('rollback booking_159: samat 8 riviä uusi → vanha, needs_translation tuotannon arvoihin', () => {
  const code = sqlCode(RB);
  const rows = [...code.matchAll(/\(\d, '([a-z0-9_.]+)',\s+'(fi|en)', '([^']+)',\s+'([^']+)',\s+(true|false)\)/g)].map((m) => m.slice(1));
  assert.equal(rows.length, 8);
  for (const [key, lang, from, to] of rows) {
    assert.equal(to, lang === 'fi' ? 'Saunarituaali-ilta' : 'Sauna ritual evening', key);
    assert.equal(from, lang === 'fi' ? 'Saunarituaali ja savusaunavuoro' : 'Sauna ritual and smoke sauna session', key);
  }
  assert.doesNotMatch(code, /\bpublic\.|alter |drop /i);
});
