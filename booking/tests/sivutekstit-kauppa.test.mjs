// Sivutekstit osa 3 / PR 1 (sopimus §18): kaupan kovakoodatut tekstit avaimiksi + tuontitiedosto + DB-peitto repon oletuksilla.
//  * content/site-texts.imported-pr61.json noudattaa admin_texts_import-sääntöjä (booking_62) ja §18.2-nimeämistä; ei sisällä tuotannossa jo olevia avaimia; vastaa koodin oletuksia (generoitu koodista)
//  * peitto (applySiteTexts): DB-teksti kun saman kielen rivi on, muuten repon oletus (ei fi→en-ristiin), paikkamerkit {{var:…}}, {{price:ID}}, aliakset, funktiolehdet (monikko)
//  * kierros: tuontitiedosto peittona → kaikki sanakirjat täsmälleen ennallaan (ulkoasu ei muutu)
// Ei verkkoa eikä tietokantaa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const root = resolve(new URL('../..', import.meta.url).pathname);
const rd = (p) => readFileSync(join(root, p), 'utf8');
const J = (p) => JSON.parse(rd(p));
const imp = (p) => import(pathToFileURL(join(root, p)));
const work = mkdtempSync(join(tmpdir(), 'sivutekstit-kauppa-'));
test.after(() => rmSync(work, { recursive: true, force: true }));

const L = await imp('booking/shop/src/site-texts-logic.js');
const R = await imp('booking/shop/src/text-registry.js');
const PG = await imp('booking/shop/src/shop-page-texts.js');
const B = await imp('src/site-texts.mjs');
const { T } = await imp('booking/shop/src/i18n.js');
const { OT } = await imp('booking/shop/src/order-texts.js');
const { GT, gtText } = await imp('booking/shop/src/gift-texts.js');
const { HT, ht } = await imp('booking/shop/src/hold-texts.js');
const { MT, mt } = await imp('booking/shop/src/mobilepay-texts.js');
const { PT } = await imp('booking/shop/src/pay-choices-texts.js');
const { OPT } = await imp('booking/shop/src/options-texts.js');
const DICTS = { T, OT, GT, HT, PT, MT, OPT };

const PENDING = J('content/site-texts.imported-pr61.json');
const FALLBACK = J('content/site-texts.fallback.json');      // tietokannan julkaistut tekstit (public_get_site_texts)
const IMPORTED = J('content/site-texts.imported.json');
const PHONE = '010 299 2866';
const quiet = () => {};

// pistemäinen kopio alkuperäisistä merkkijonolehdistä + funktioista (ennen mitään peittoa)
const flat = (o, p = '') => Object.entries(o).flatMap(([k, v]) => (v && typeof v === 'object' ? flat(v, `${p}${k}.`) : [[`${p}${k}`, v]]));
const ORIG = Object.fromEntries(Object.entries(DICTS).map(([n, d]) => [n, Object.fromEntries(['fi', 'en'].map((l) => [l, Object.fromEntries(flat(d[l]))]))]));
const snapshotStrings = () => JSON.stringify(Object.entries(DICTS).map(([n, d]) => [n, ['fi', 'en'].map((l) => flat(d[l]).map(([k, v]) => [k, typeof v === 'function' ? 'fn' : v]))]));
const BASE_SNAP = snapshotStrings();

// ================= tuontitiedosto =================
test('tuontitiedosto: rivit noudattavat admin_texts_import-sääntöjä (avain, kieli, luokka, kind, max_len, paikkamerkit) ja §18.2-nimeämistä', () => {
  assert.ok(Array.isArray(PENDING) && PENDING.length > 1000, `rivejä ${PENDING.length}`);
  const seen = new Set();
  for (const r of PENDING) {
    const w = `${r.key} [${r.lang}]`;
    assert.match(r.key, L.KEY_RE, w); assert.ok(r.key.length <= 120, `${w}: avain liian pitkä`);
    assert.match(r.key, /^(ui|page|seo|email|nav)\./, `${w}: vapaa avainetuliite`);
    assert.ok(['fi', 'en'].includes(r.lang), w);
    assert.ok(['normal', 'protected'].includes(r.class), `${w}: luokka ${r.class}`);   // locked = hinnat/ALV/URL: ei kovakoodatuissa teksteissä
    assert.equal(r.kind, 'plain', w);
    assert.ok(Number.isInteger(r.max_len) && r.max_len >= r.text.length && r.max_len <= 100000, `${w}: max_len ${r.max_len} < ${r.text.length}`);
    assert.ok(typeof r.text === 'string' && r.text.trim() === r.text && r.text.length > 0, `${w}: tyhjä tai reunoilla tyhjää`);
    assert.doesNotMatch(r.text, /[<>]|https?:\/\/|www\.|[\u0000-\u0008\u000b-\u001f]/, `${w}: HTML/linkki/ohjausmerkki plain-kentässä`);
    assert.deepEqual([...r.placeholders].sort(), [...L.tokensOf(r.text)].sort(), `${w}: placeholders ≠ tekstin merkinnät`);
    for (const tok of L.tokensOf(r.text)) { assert.match(tok, L.TOKEN_RE, `${w}: ${tok}`); assert.ok(L.KINDS.includes(tok.slice(2, -2).split(':')[0]), `${w}: tuntematon lajike ${tok}`); }
    assert.doesNotMatch(r.text.replace(/\{\{[^{}]*\}\}/g, ''), /[{}]/, `${w}: yksittäinen aaltosulku (käytä {{var:nimi}})`);
    assert.ok(r.reason && r.reason.length <= 300, `${w}: perustelu`);
    assert.ok(!seen.has(`${r.key}|${r.lang}`), `${w}: kaksoiskappale`); seen.add(`${r.key}|${r.lang}`);
  }
  for (const k of new Set(PENDING.map((r) => r.key))) assert.ok(seen.has(`${k}|fi`) && seen.has(`${k}|en`), `${k}: FI+EN molemmat (§18.9 kohta 2)`);
});
test('PR 1:n tuontitiedosto on tuotu (#61): jokainen rivi on varatekstissä (tuotanto) samalla tekstillä, ja varateksti sisältää ui.shop.error_generic', () => {
  const have = new Map(FALLBACK.texts.map((r) => [`${r.key}|${r.lang}`, r.text]));
  // Tuotannossa tekstejä on voitu muokata tuonnin jälkeen (versio ≥ 2, esim. Perinnesauna-kirjoitusasu): DB on totuus, repon oletus ei ylikirjoita. Versio 1 = täsmälleen tuotu teksti.
  const ver = new Map(FALLBACK.texts.map((r) => [`${r.key}|${r.lang}`, r.version]));
  const pending94 = new Set(J('content/site-texts.pending-import-94.json').map((r) => `${r.key}|${r.lang}`));
  const diff = PENDING.filter((r) => !pending94.has(`${r.key}|${r.lang}`) && have.get(`${r.key}|${r.lang}`) !== r.text && !(ver.get(`${r.key}|${r.lang}`) > 1)).map((r) => `${r.key} [${r.lang}]`);
  assert.deepEqual(diff, [], 'tuotanto poikkeaa tuodusta tiedostosta ilman muokkausversiota');
  assert.ok(PENDING.every((r) => have.has(`${r.key}|${r.lang}`)), 'jokainen tuotu rivi on tuotannossa');
  assert.ok(have.has('ui.shop.error_generic|fi') && have.has('ui.shop.error_generic|en'));
});
test('tuontitiedosto: yksi tuontikutsu enintään 500 riviä → jaettavissa erin; koko ≤ 3 erää', () => {
  assert.ok(Math.ceil(PENDING.length / 500) <= 3, `${PENDING.length} riviä`);
});
test('tuontitiedosto on generoitu koodista: scripts/site-texts-extract-shop.mjs tuottaa pr61-rivit (imported-pr71 on jo tuotannossa, joten se ei tule mukaan)', () => {
  const prod = join(work, 'prod.json'), out = join(work, 'out.json');
  const extra = new Set([
    ...J('content/site-texts.imported-pr71.json').map((r) => `${r.key}|${r.lang}`),
    ...J('content/site-texts.pending-import-28.json').filter((r) => r.key.startsWith('ui.vismapay.')).map((r) => `${r.key}|${r.lang}`),
    ...J('content/site-texts.pending-import-29.json').filter((r) => r.key.startsWith('ui.order.')).map((r) => `${r.key}|${r.lang}`),
    ...J('content/site-texts.pending-import-33.json').map((r) => `${r.key}|${r.lang}`),
    ...J('content/site-texts.pending-import-34.json').filter((r) => r.key.startsWith('ui.shop.')).map((r) => `${r.key}|${r.lang}`),
    ...J('content/site-texts.pending-import-36.json').map((r) => `${r.key}|${r.lang}`),
    ...J('content/site-texts.pending-import-39.json').map((r) => `${r.key}|${r.lang}`),
    ...J('content/site-texts.pending-import-42.json').map((r) => `${r.key}|${r.lang}`),
    ...J('content/site-texts.pending-import-48.json').filter((r) => r.key.startsWith('ui.shop.')).map((r) => `${r.key}|${r.lang}`),
    ...J('content/site-texts.pending-import-49.json').map((r) => `${r.key}|${r.lang}`),
    ...J('content/site-texts.pending-import-59.json').filter((r) => r.key.startsWith('ui.shop.')).map((r) => `${r.key}|${r.lang}`),   // booking_162
    ...J('content/site-texts.pending-import-62.json').map((r) => `${r.key}|${r.lang}`),   // booking_166
    ...J('content/site-texts.pending-import-63.json').map((r) => `${r.key}|${r.lang}`),   // booking_166 korjaus: rituaalikortti
    ...J('content/site-texts.pending-import-64.json').map((r) => `${r.key}|${r.lang}`),   // monikkokorjaus: yksikköavaimet *_one
    ...J('content/site-texts.pending-import-68.json').filter((r) => r.key.startsWith('ui.gift.')).map((r) => `${r.key}|${r.lang}`),   // booking_173: lahjakortin myyjät
    ...J('content/site-texts.pending-import-70.json').map((r) => `${r.key}|${r.lang}`),   // booking_175: laskutustapa + Laskutettu
    ...J('content/site-texts.pending-import-72.json').map((r) => `${r.key}|${r.lang}`),   // booking_177: maksulinkkisivu
    ...J('content/site-texts.pending-import-73.json').map((r) => `${r.key}|${r.lang}`),   // booking_177b: maksulinkin yhteenveto
    ...J('content/site-texts.pending-import-74.json').map((r) => `${r.key}|${r.lang}`),   // booking_178: maksulinkin uusinta
    ...J('content/site-texts.pending-import-80.json').filter((r) => r.key.startsWith('ui.shop.') || r.key.startsWith('ui.order.')).map((r) => `${r.key}|${r.lang}`),   // booking_185: laskutuslukko
    ...J('content/site-texts.pending-import-83.json').filter((r) => r.key.startsWith('ui.shop.')).map((r) => `${r.key}|${r.lang}`),   // booking_187: yrityksen verkkomaksu
    ...J('content/site-texts.pending-import-84.json').filter((r) => r.key.startsWith('ui.paychoice.') || r.key.startsWith('ui.order.') || r.key.startsWith('ui.hold.') || r.key.startsWith('ui.paylink.')).map((r) => `${r.key}|${r.lang}`),   // booking_188: verkkomaksu
    ...J('content/site-texts.pending-import-86.json').filter((r) => r.key.startsWith('ui.')).map((r) => `${r.key}|${r.lang}`),   // booking_190: lisäyksen pito
    ...J('content/site-texts.pending-import-1028.json').filter((r) => r.key.startsWith('ui.shop.') || r.key.startsWith('ui.treatment.') || r.key.startsWith('ui.gift.')).map((r) => `${r.key}|${r.lang}`),
    ...J('content/site-texts.pending-import-91.json').map((r) => `${r.key}|${r.lang}`),   // tapahtumat-chippi
    ...J('content/site-texts.pending-import-92.json').filter((r) => r.key.startsWith('ui.shop.') || r.key.startsWith('ui.gift.')).map((r) => `${r.key}|${r.lang}`),
    ...J('content/site-texts.pending-import-94.json').filter((r) => r.key.startsWith('ui.') && !FALLBACK.texts.some((x) => x.key === r.key && x.lang === r.lang)).map((r) => `${r.key}|${r.lang}`),   // audit 28.10: uudet ui-avaimet (lead on jo varatekstissä)
    ...J('content/site-texts.pending-import-99.json').filter((r) => r.key.startsWith('ui.shop.')).map((r) => `${r.key}|${r.lang}`),   // booking_210: tapahtuman jono
  ]);
  const imp = new Set(PENDING.map((r) => r.key));
  writeFileSync(prod, JSON.stringify({ ok: true, texts: FALLBACK.texts.filter((r) => !imp.has(r.key)) }));   // tuotanto ennen #61:n tuontia
  const r = spawnSync('node', [join(root, 'scripts/site-texts-extract-shop.mjs'), '--prod', prod, '--out', out], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  const got = JSON.parse(readFileSync(out, 'utf8'));
  const base = got.filter((row) => !extra.has(`${row.key}|${row.lang}`));
  assert.equal(JSON.stringify(base, null, 1) + '\n', rd('content/site-texts.imported-pr61.json'));
});
test('generaattori ei lisää riviä jos avain on jo tuotannossa (vain uudet avaimet)', () => {
  const prod = join(work, 'prod2.json'), out = join(work, 'out2.json');
  const extraRows = J('content/site-texts.imported-pr71.json');
  const have = PENDING.filter((r) => r.key.startsWith('ui.order.') || r.key === 'ui.shop.title');
  const haveKeys = new Set(have.map((r) => r.key));
  writeFileSync(prod, JSON.stringify({ ok: true, texts: [...FALLBACK.texts.filter((r) => !PENDING.some((p) => p.key === r.key)), ...have.map((r) => ({ key: r.key, lang: r.lang, text: 'tuotannon teksti', version: 1, placeholders: [] }))] }));
  const r = spawnSync('node', [join(root, 'scripts/site-texts-extract-shop.mjs'), '--prod', prod, '--out', out], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  const rows = JSON.parse(readFileSync(out, 'utf8'));
  const vismaRows = R.collectDefaults().filter((r) => r.id === 'VT');
  const msgOrder = J('content/site-texts.pending-import-29.json').filter((r) => r.key.startsWith('ui.order.'));
  const payUi = J('content/site-texts.pending-import-33.json');
  const waitUi = J('content/site-texts.pending-import-34.json').filter((r) => r.key.startsWith('ui.shop.'));
  const waitParty = J('content/site-texts.pending-import-36.json');
  const waitOffer = J('content/site-texts.pending-import-39.json');
  const codeUi = J('content/site-texts.pending-import-42.json');
  const partyType = J('content/site-texts.pending-import-48.json').filter((r) => r.key.startsWith('ui.shop.'));
  const cancelUi = J('content/site-texts.pending-import-49.json');
  const quietUi = J('content/site-texts.pending-import-59.json').filter((r) => r.key.startsWith('ui.shop.'));   // booking_162
  const ritualUi = J('content/site-texts.pending-import-62.json');   // booking_166
  const ritualCard = J('content/site-texts.pending-import-63.json');   // booking_166 korjaus: rituaalikortti
  const oneUi = J('content/site-texts.pending-import-64.json');   // monikkokorjaus
  const sellersUi = J('content/site-texts.pending-import-68.json').filter((r) => r.key.startsWith('ui.gift.'));   // booking_173
  const invoiceUi = J('content/site-texts.pending-import-70.json');   // booking_175: laskutustapa + Laskutettu
  const payLinkUi = J('content/site-texts.pending-import-72.json');   // booking_177: maksulinkkisivu
  const payLinkInfoUi = J('content/site-texts.pending-import-73.json');   // booking_177b: maksulinkin yhteenveto
  const payLinkRetryUi = J('content/site-texts.pending-import-74.json');   // booking_178: maksulinkin uusinta
  const invoiceLockUi = J('content/site-texts.pending-import-80.json').filter((r) => r.key.startsWith('ui.shop.') || r.key.startsWith('ui.order.'));   // booking_185: laskutuslukko
  const companyPayUi = J('content/site-texts.pending-import-83.json').filter((r) => r.key.startsWith('ui.shop.'));   // booking_187: yrityksen verkkomaksu
  const onlinePayUi = J('content/site-texts.pending-import-84.json').filter((r) => r.key.startsWith('ui.paychoice.') || r.key.startsWith('ui.order.') || r.key.startsWith('ui.hold.') || r.key.startsWith('ui.paylink.'));   // booking_188: verkkomaksu
  const additionHoldUi = J('content/site-texts.pending-import-86.json').filter((r) => r.key.startsWith('ui.'));   // booking_190: lisäyksen pito
  const uxShopUi = J('content/site-texts.pending-import-1028.json').filter((r) => r.key.startsWith('ui.shop.') || r.key.startsWith('ui.treatment.') || r.key.startsWith('ui.gift.'));
  const eventChipUi = J('content/site-texts.pending-import-91.json');
  const giftPersonsUi = J('content/site-texts.pending-import-92.json').filter((r) => r.key.startsWith('ui.shop.') || r.key.startsWith('ui.gift.'));
  const audit94Ui = J('content/site-texts.pending-import-94.json').filter((r) => r.key.startsWith('ui.') && !FALLBACK.texts.some((x) => x.key === r.key && x.lang === r.lang));
  const eventQueueUi = J('content/site-texts.pending-import-99.json').filter((r) => r.key.startsWith('ui.shop.'));   // booking_210
  assert.equal(rows.length, PENDING.length - have.length + vismaRows.length + msgOrder.length + payUi.length + waitUi.length + waitParty.length + waitOffer.length + codeUi.length + partyType.length + cancelUi.length + quietUi.length + ritualUi.length + ritualCard.length + oneUi.length + sellersUi.length + invoiceUi.length + payLinkUi.length + payLinkInfoUi.length + payLinkRetryUi.length + invoiceLockUi.length + companyPayUi.length + onlinePayUi.length + additionHoldUi.length + uxShopUi.length + eventChipUi.length + giftPersonsUi.length + audit94Ui.length + eventQueueUi.length);
  assert.ok(!rows.some((x) => haveKeys.has(x.key)));
  for (const e of extraRows) assert.ok(!rows.some((x) => x.key === e.key), `${e.key}: jo tuotannossa, generaattori ei lisää`);
  const bad = spawnSync('node', [join(root, 'scripts/site-texts-extract-shop.mjs'), '--prod', join(work, 'ei-ole.json')], { encoding: 'utf8' });
  assert.notEqual(bad.status, 0);
});

test('imported-pr71: tilaussivun peruutusviestit FI+EN, sama teksti kuin koodin oletus ja varateksti (tuotu tuotantoon)', () => {
  const EXTRA = J('content/site-texts.imported-pr71.json');
  const defaults = new Map(R.collectDefaults().map((r) => [`${r.key}|${r.lang}`, r.text]));
  const have = new Map(FALLBACK.texts.map((r) => [`${r.key}|${r.lang}`, r.text]));
  const seen = new Set();
  assert.equal(EXTRA.length, 8);
  for (const r of EXTRA) {
    const w = `${r.key} [${r.lang}]`;
    assert.match(r.key, /^ui\.order\.closed_(hold_expired|hold_expired_gift|cancelled|new_booking)$/, w);
    assert.ok(['fi', 'en'].includes(r.lang), w);
    assert.equal(r.class, 'normal', w);
    assert.equal(r.kind, 'plain', w);
    assert.equal(defaults.get(`${r.key}|${r.lang}`), r.text, w);
    assert.equal(have.get(`${r.key}|${r.lang}`), r.text, `${w}: varateksti`);
    assert.ok(r.max_len >= r.text.length && r.max_len <= 100000, w);
    assert.deepEqual([...r.placeholders].sort(), [...L.tokensOf(r.text)].sort(), w);
    assert.doesNotMatch(r.text, /[<>]|https?:\/\/|www\./, w);
    assert.ok(!PENDING.some((p) => p.key === r.key), `${w}: päällekkäinen pr61`);
    assert.ok(!seen.has(`${r.key}|${r.lang}`)); seen.add(`${r.key}|${r.lang}`);
  }
  for (const k of new Set(EXTRA.map((r) => r.key))) assert.ok(seen.has(`${k}|fi`) && seen.has(`${k}|en`), k);
  assert.ok(EXTRA.find((r) => r.key === 'ui.order.closed_hold_expired' && r.lang === 'fi').text.includes('Sipoonjoen Perinnesauna'));
  assert.deepEqual(EXTRA.find((r) => r.key === 'ui.order.closed_hold_expired' && r.lang === 'fi').placeholders, ['{{var:minutes}}']);
});

test('pending-import-33: tilaussivun maksutilan uudet tekstit FI+EN, sama teksti kuin koodin oletus, ei vielä varatekstissä', () => {
  const rows = J('content/site-texts.pending-import-33.json');
  const defaults = new Map(R.collectDefaults().map((r) => [`${r.key}|${r.lang}`, r.text]));
  const have = new Map(FALLBACK.texts.map((r) => [`${r.key}|${r.lang}`, r.text]));
  const want = ['ui.mobilepay.method_title', 'ui.order.pay_lead_both', 'ui.order.pay_test_both'];
  const seen = new Set();
  assert.equal(rows.length, want.length * 2);
  for (const r of rows) {
    const w = `${r.key} [${r.lang}]`;
    assert.ok(want.includes(r.key), w);
    assert.ok(['fi', 'en'].includes(r.lang), w);
    assert.equal(r.class, 'normal', w);
    assert.equal(r.kind, 'plain', w);
    assert.equal(r.text, defaults.get(`${r.key}|${r.lang}`), w);
    assert.equal(r.class, R.classFor(r.key, defaults.get(`${r.key}|fi`)), w);
    assert.equal(have.has(`${r.key}|${r.lang}`), false, `${w}: ei vielä tuotannossa`);
    assert.ok(r.max_len >= r.text.length && r.max_len <= 100000, w);
    assert.deepEqual(r.placeholders, [], w);
    assert.doesNotMatch(r.text, /[<>]|https?:\/\/|www\./, w);
    assert.ok(!seen.has(`${r.key}|${r.lang}`)); seen.add(`${r.key}|${r.lang}`);
  }
  for (const k of want) assert.ok(seen.has(`${k}|fi`) && seen.has(`${k}|en`), k);
  assert.equal(defaults.get('ui.mobilepay.pay_title|fi'), 'Maksa verkossa', 'julkaistu otsikko jää ennalleen; uusi otsikko on method_title');
});

// ================= avaimet =================
test('avaimet: yksilölliset, FI+EN pariksi, kaikki kaupan sanakirjat mukana (lukuun ottamatta teknistä URL-polkua)', () => {
  const d = R.collectDefaults();
  const ids = d.map((r) => `${r.key}|${r.lang}`); assert.equal(new Set(ids).size, ids.length, 'kaksoisavain');
  for (const k of R.allKeys()) assert.ok(ids.includes(`${k}|fi`) && ids.includes(`${k}|en`), `${k}: kieli puuttuu`);
  // jokainen merkkijonolehti (paitsi aliakset ja poikkeukset) on jollakin avaimella; funktiolehdet laajennettu malleiksi
  const leaves = Object.entries(ORIG).flatMap(([n, o]) => Object.keys(o.fi).map((k) => `${n}:${k}`)).filter((x) => !R.EXCLUDED.has(x));
  const covered = new Set(d.filter((r) => r.lang === 'fi').map((r) => `${r.id}:${r.path}`));
  const aliases = leaves.filter((x) => !covered.has(x));
  for (const a of aliases) assert.match(a, /^(GT|MT):/, `${a}: ei avainta eikä aliasta`);
  assert.ok(aliases.length >= 5 && aliases.length <= 14, `aliaksia ${aliases.length}: ${aliases}`);
  assert.ok(R.allKeys().length > 600);
  assert.deepEqual([...R.EXCLUDED], ['T:directionsUrl']);
});
test('avainnimeäminen: tr.errors.<koodi> → ui.checkout.error_<koodi>, errors.<koodi> → ui.shop.error_<koodi>, tr.* → ui.treatment.*, camelCase → snake_case', () => {
  const k = new Set(R.allKeys());
  for (const x of ['ui.checkout.error_generic', 'ui.checkout.error_time_window', 'ui.shop.error_rate_limited', 'ui.treatment.max_persons', 'ui.shop.day_sessions.one', 'ui.shop.day_sessions.other', 'ui.shop.free_spots', 'ui.hold.err.order_expired', 'ui.order.title', 'ui.gift.buy_lead', 'ui.mobilepay.test_note', 'ui.paychoice.title', 'ui.option.not_chosen']) assert.ok(k.has(x), `${x} puuttuu`);
  assert.ok(![...k].some((x) => /[A-Z]/.test(x)));
  // oletusvirheelle yleisteksti (§18.9 kohta 4)
  assert.ok(k.has('ui.checkout.error_generic'));
});
test('funktiolehdet: jokaisella mallipohjalla on FI+EN ja malli tuottaa saman tekstin kuin alkuperäinen funktio (monikon molemmat haarat)', () => {
  const sample = { n: [1, 2, 7], m: [1, 15], p: ['5 €'], h: [1, 48], dl: ['pe 10.10. klo 12.00'], when: ['ma 5.10. klo 18.00'], price: ['49 €'] };
  const render = (tpl, names, args) => tpl.replace(/\{\{var:(\w+)\}\}/g, (_, k) => String(args[names.indexOf(k)]));
  const cases = Object.entries(R.FN_SPECS);
  assert.equal(cases.length, 11);
  for (const [id, spec] of cases) {
    const [dn, ...pp] = id.split(':'); const path = pp.join(':');
    for (const lang of ['fi', 'en']) {
      const fn = ORIG[dn][lang][path]; assert.equal(typeof fn, 'function', `${id} ${lang}`);
      const grid = spec.args.map((a) => sample[a] || ['x']);
      const combos = grid.reduce((acc, vs) => acc.flatMap((c) => vs.map((v) => [...c, v])), [[]]);
      for (const args of combos) {
        const one = spec.one && +args[spec.args.indexOf(spec.one.arg)] === 1;
        const tpl = one ? spec.one[lang] : spec.plural ? spec[lang][+args[0] === 1 ? 'one' : 'other'] : spec[lang];
        assert.equal(render(tpl, spec.args, args), fn(...args), `${id} ${lang} ${JSON.stringify(args)}`);
      }
    }
  }
});
test('luokat (§18.6): puhelinnumeroa, suostumusta, ehtoja ja peruutus-/muutosehtoja sisältävät avaimet ovat protected; muut normal', () => {
  const cls = new Map(PENDING.map((r) => [r.key, r.class]));
  for (const k of ['ui.shop.load_error', 'ui.shop.disabled', 'ui.checkout.error_generic', 'ui.checkout.error_disabled', 'ui.checkout.error_too_many_open', 'ui.shop.consent_marketing', 'ui.shop.accept_terms', 'ui.shop.terms_link', 'ui.shop.change_info', 'ui.shop.change_locked', 'ui.gift.marketing', 'ui.gift.terms_link', 'ui.gift.buy_lead', 'ui.order.cancel_lead']) assert.equal(cls.get(k), 'protected', k);
  for (const k of ['ui.shop.title', 'ui.shop.loading', 'ui.order.title']) assert.equal(cls.get(k), 'normal', k);
  for (const r of PENDING) if (/\{\{var:phone\}\}/.test(r.text)) assert.equal(r.class, 'protected', r.key);
  const prot = new Set(PENDING.filter((r) => r.class === 'protected').map((r) => r.key));
  assert.ok(prot.size >= 20 && prot.size <= 40, `protected ${prot.size}`);
});
test('puhelinnumero ei ole tuontitekstissä kovakoodattuna: {{var:phone}} (sivuston yhteystiedoista)', () => {
  assert.ok(!PENDING.some((r) => r.text.includes(PHONE)));
  assert.equal(PENDING.filter((r) => r.text.includes('{{var:phone}}')).map((r) => r.key).filter((k, i, a) => a.indexOf(k) === i).length, 5);
});

// ================= sivutekstit build.mjs (page.* / seo.*) =================
test('varaus-/tilaussivujen tekstit: page.*/seo.*-avaimet FI+EN tuontitiedostossa ja oletukset = nykyiset otsikot', () => {
  assert.equal(PG.SHOP_PAGE_TEXTS.length, 11);
  for (const p of PG.SHOP_PAGE_TEXTS) {
    assert.match(p.key, /^(page|seo)\./); assert.ok(p.fi && p.en);
    for (const lang of ['fi', 'en']) { const r = PENDING.find((x) => x.key === p.key && x.lang === lang); assert.ok(r, `${p.key} [${lang}] puuttuu tuonnista`); assert.equal(r.text, p[lang]); assert.equal(PG.pageDefault(p.key, lang), p[lang]); }
  }
  assert.throws(() => PG.pageDefault('page.ei.ole', 'fi'));
  // build.mjs lukee ne tx():llä eikä sisällä enää kovakoodattuja otsikoita
  const b = rd('booking/shop/build.mjs');
  assert.doesNotMatch(b, /Varaa saunaelämys|Tilauksesi|Your order|Booking confirmation|Varauskalenteri vaatii/);
});
test('build: {{var:…}} paikkamerkki – validointi hyväksyy muodon, tx() vaatii arvon (puuttuva arvo kaataa) eikä raaka merkintä päädy tekstiin', async () => {
  const rows = [{ key: 'ui.test.n', lang: 'fi', text: '{{var:n}} paikkaa', placeholders: ['{{var:n}}'] }];
  assert.deepEqual(L.validateTexts(rows, L.makeContext({ vars: true })), []);
  assert.equal(L.validateTexts(rows, L.makeContext({}))[0].problem.includes('arvoa ei löydy'), true);
  const rpc = async () => ({ ok: true, texts: rows, generated_at: 'x' });
  const st = await B.loadSiteTexts({ env: { SITE_TEXTS_FIXTURE: '' }, rpc, log: { log() {}, warn() {} }, cacheDir: join(work, 'c1') });   // ei kaadu varsta
  assert.equal(st.rows.length, 1);
  assert.equal(B.tx('ui.test.n', 'fi', { state: st, vars: { n: 3 } }), '3 paikkaa');
  assert.throws(() => B.tx('ui.test.n', 'fi', { state: st, fallback: 'oletus', log: quiet }), (e) => e instanceof L.PlaceholderError);
  assert.throws(() => B.tx('ui.test.n', 'fi', { state: st, vars: {}, log: quiet }), (e) => e instanceof L.PlaceholderError);
  assert.throws(() => L.fillPlaceholders('{{foo:bar}}', L.makeContext({ vars: true })), (e) => e instanceof L.PlaceholderError);
});

// ================= peitto =================
const dbRows = (o) => Object.entries(o).flatMap(([k, [fi, en]]) => [fi != null && { key: k, lang: 'fi', text: fi }, en != null && { key: k, lang: 'en', text: en }].filter(Boolean));
test.afterEach(() => R.resetSiteTexts());
test('peitto: kierros – tuontitiedosto DB-rivinä (puhelin sivun yhteystiedoista) → kaikki sanakirjat täsmälleen ennallaan, funktiot samat', () => {
  const res = R.applySiteTexts(PENDING.filter((r) => !r.key.startsWith('page.') && !r.key.startsWith('seo.')).map((r) => ({ key: r.key, lang: r.lang, text: r.text })), { vars: { phone: PHONE, email: 'x@example.test' }, log: quiet });
  assert.deepEqual(res.skipped, []);
  assert.ok(res.applied.length > 1300, `peitettiin ${res.applied.length}`);
  assert.equal(snapshotStrings(), BASE_SNAP);
  // funktiot: täsmälleen samat tulokset kuin alkuperäiset
  for (const lang of ['fi', 'en']) for (const [id] of Object.entries(R.FN_SPECS)) {
    const [dn, ...pp] = id.split(':'); const path = pp.join(':'); const o = path.split('.').reduce((a, k) => a[k], DICTS[dn][lang]);
    for (const args of [[1, 'a', 'b'], [2, 'c', 'd'], [5, 'x', 'y']]) assert.equal(o(...args), ORIG[dn][lang][path](...args), `${id} ${lang}`);
  }
  // aliakset seuraavat pitotekstiä ja ovat samat kuin ennen
  for (const l of ['fi', 'en']) assert.equal(GT[l]['err.order_expired'], HT[l]['err.order_expired']);
});
test('peitto: DB-teksti voittaa saman kielen oletuksen; puuttuva rivi → oletus; en puuttuu → en-oletus (ei fi-tekstiä en-sivulle)', () => {
  R.applySiteTexts(dbRows({ 'ui.shop.title': ['Varaa elämys (DB)', null], 'ui.shop.lead': [null, 'EN lead from DB'], 'ui.order.title': ['Tilaus (DB)', 'Order (DB)'] }), { log: quiet });
  assert.equal(T.fi.title, 'Varaa elämys (DB)'); assert.equal(T.en.title, ORIG.T.en.title);
  assert.equal(T.en.lead, 'EN lead from DB'); assert.equal(T.fi.lead, ORIG.T.fi.lead);
  assert.equal(OT.fi.title, 'Tilaus (DB)'); assert.equal(OT.en.title, 'Order (DB)');
  assert.equal(T.fi.loading, ORIG.T.fi.loading);
});
test('peitto: idempotentti ja palautuva – uusi kutsu alkaa oletuksista (poistettu rivi → oletus takaisin)', () => {
  R.applySiteTexts(dbRows({ 'ui.shop.title': ['A', 'B'] }), { log: quiet }); R.applySiteTexts(dbRows({ 'ui.shop.title': ['A2', 'B2'] }), { log: quiet });
  assert.deepEqual([T.fi.title, T.en.title], ['A2', 'B2']);
  R.applySiteTexts([], { log: quiet });
  assert.equal(snapshotStrings(), BASE_SNAP);
});
test('peitto: tyhjä teksti, virheellinen avain tai tuntematon/täyttymätön paikkamerkki → oletus (ei tyhjää, ei raakaa {{…}}), ohitus raportoidaan', () => {
  const logs = [];
  const res = R.applySiteTexts([{ key: 'ui.shop.title', lang: 'fi', text: '   ' }, { key: 'ui.shop.lead', lang: 'fi', text: 'Hinta {{price:99}}' }, { key: 'ui.shop.pick_day', lang: 'fi', text: 'Päivä {{foo:1}}' }, { key: 'ui.shop.loading', lang: 'fi', text: 'Lataus {{var:' }, { key: 'Bad Key', lang: 'fi', text: 'x' }], { log: (m) => logs.push(m) });
  assert.equal(snapshotStrings(), BASE_SNAP);
  assert.equal(res.skipped.length, 3); assert.ok(logs.length === 3);
  for (const [, v] of Object.entries(DICTS).flatMap(([, d]) => ['fi', 'en'].flatMap((l) => flat(d[l])))) if (typeof v === 'string') { assert.ok(v.trim()); assert.doesNotMatch(v, /\{\{|\}\}/); }
});
test('peitto: {{price:ID}}, {{duration:ID}}, {{setting:avain}} täytetään ajoajan datasta; {{var:phone}} sivuston yhteystiedoista; muut {{var:x}} → {x} (kutsuhetken arvo)', () => {
  R.applySiteTexts(dbRows({ 'ui.shop.lead': ['Alkaen {{price:7}}, {{duration:7}}, varaus {{setting:hold_minutes}} min, soita {{var:phone}}', 'From {{price:7}}'], 'ui.order.title': ['{{var:n}} kpl', null] }),
    { vars: { phone: '09 123 4567' }, data: { catalog: [{ id: 7, price: 49, duration_minutes: 120 }], settings: { hold_minutes: 15 } }, log: quiet });
  assert.equal(T.fi.lead, 'Alkaen 49 €, 2 h, varaus 15 min, soita 09 123 4567'); assert.equal(T.en.lead, 'From €49');
  assert.equal(OT.fi.title, '{n} kpl');       // koodi täyttää {n} kuten ennenkin
  // ilman dataa teksti jää oletukseksi
  R.applySiteTexts(dbRows({ 'ui.shop.lead': ['Alkaen {{price:7}}', null] }), { log: quiet });
  assert.equal(T.fi.lead, ORIG.T.fi.lead);
});
test('peitto: alias – pitotekstin (HT) muutos näkyy lahjakortti- ja MobilePay-teksteissä jotka kopioivat sen', () => {
  R.applySiteTexts(dbRows({ 'ui.hold.err.order_expired': ['Vanhentunut (DB)', 'Expired (DB)'] }), { log: quiet });
  assert.equal(HT.fi['err.order_expired'], 'Vanhentunut (DB)'); assert.equal(GT.fi['err.order_expired'], 'Vanhentunut (DB)'); assert.equal(MT.en['err.order_expired'], 'Expired (DB)');
  assert.equal(ht('en', 'err.order_expired'), 'Expired (DB)'); assert.equal(gtText('fi', 'err.order_expired'), 'Vanhentunut (DB)'); assert.equal(mt('fi', 'err.order_expired'), 'Vanhentunut (DB)');
  assert.ok(!R.allKeys().includes('ui.gift.err.order_expired'), 'aliaksella ei omaa avainta');
});
test('peitto: funktiolehdet käyttävät DB-mallia (monikko one/other), argumentit {{var:…}} → arvot; puuttuva muoto → alkuperäinen funktio', () => {
  R.applySiteTexts(dbRows({ 'ui.shop.day_sessions.one': ['Yksi paikka (DB)', null], 'ui.shop.day_sessions.other': ['{{var:n}} paikkaa (DB)', '{{var:n}} spots (DB)'], 'ui.shop.pay_hold': ['Pidossa {{var:m}} min (DB)', null], 'ui.treatment.selected': ['{{var:when}}/{{var:n}}/{{var:price}}', null] }), { log: quiet });
  assert.equal(T.fi.daySessions(1), 'Yksi paikka (DB)'); assert.equal(T.fi.daySessions(4), '4 paikkaa (DB)');
  assert.equal(T.en.daySessions(1), ORIG.T.en.daySessions(1)); assert.equal(T.en.daySessions(3), '3 spots (DB)');   // en.one puuttuu → alkuperäinen funktio
  assert.equal(T.fi.payHold(15), 'Pidossa 15 min (DB)'); assert.equal(T.en.payHold(15), ORIG.T.en.payHold(15));
  assert.equal(T.fi.tr.selected('ma', 2, '98 €'), 'ma/2/98 €');
  assert.equal(T.fi.tr.maxPersons(6), ORIG.T.fi['tr.maxPersons'](6));
});
test('peitto: i18n-rakenne säilyy – tr/errors-objektit samat viitteet (koodin vakiot t = T[lang] näkevät muutokset), ei uusia haaroja', () => {
  const t = T.fi, tr = T.fi.tr, errs = T.fi.tr.errors;
  R.applySiteTexts(dbRows({ 'ui.checkout.error_generic': ['Yleisvirhe (DB)', null], 'ui.treatment.date': ['Pvm (DB)', null], 'ui.shop.error_rate_limited': ['Liikaa (DB)', null] }), { log: quiet });
  assert.equal(t.tr, tr); assert.equal(tr.errors, errs);
  assert.equal(errs.generic, 'Yleisvirhe (DB)'); assert.equal(tr.date, 'Pvm (DB)'); assert.equal(t.errors.rate_limited, 'Liikaa (DB)');
});
test('vartija: kaikki kaupan kielisanakirjat (export const X = { fi: {…}, en: {…} }) on rekisteröity text-registry.js:ssä – uusi sanakirja ilman avaimia kaataa testin', async () => {
  const { readdirSync } = await import('node:fs');
  const dir = join(root, 'booking/shop/src');
  const dictFiles = readdirSync(dir).filter((f) => f.endsWith('.js') && /^export const [A-Za-z]+ = \{\s*\n\s*fi: \{/m.test(readFileSync(join(dir, f), 'utf8')));
  assert.deepEqual(dictFiles.sort(), ['gift-texts.js', 'hold-texts.js', 'i18n.js', 'mobilepay-texts.js', 'options-texts.js', 'order-texts.js', 'pay-choices-texts.js', 'pay-link-texts.js', 'vismapay-texts.js']);
  const reg = rd('booking/shop/src/text-registry.js');
  for (const f of dictFiles) assert.ok(reg.includes(`./${f}`), `${f} puuttuu text-registry.js:stä`);
  // tunnetut poikkeukset (raportoitu): ICS-tiedoston osoite (shop.js) ja SOURCE_LABELS (gift-logic.js; palvelin antaa nimet)
  assert.match(rd('booking/shop/src/shop.js'), /LOCATION:Hindsbyntie 124/);
});

test('pending-import-34: jonotuslistan tekstit (kauppa ui.shop.waitlist_* + sähköposti email.waitlist.*) FI+EN, sama kuin koodin oletus, ei vielä tuotannossa', async () => {
  const rows = J('content/site-texts.pending-import-34.json');
  const { EMAIL_TEXTS } = await import(new URL('../supabase/functions/send-emails/texts.ts', import.meta.url).href).catch(() => ({ EMAIL_TEXTS: null }));
  const defaults = new Map(R.collectDefaults().map((r) => [`${r.key}|${r.lang}`, r.text]));
  const have = new Set(FALLBACK.texts.map((r) => `${r.key}|${r.lang}`));
  const seen = new Set();
  for (const r of rows) {
    const w = `${r.key} [${r.lang}]`;
    assert.ok(/^ui\.shop\.waitlist_|^email\.waitlist\./.test(r.key), w);
    assert.ok(['fi', 'en'].includes(r.lang), w);
    assert.equal(r.kind, 'plain', w);
    if (r.key.startsWith('ui.shop.')) assert.equal(r.text, defaults.get(`${r.key}|${r.lang}`), w);
    else if (EMAIL_TEXTS) assert.equal(r.text, EMAIL_TEXTS[r.key][r.lang], w);
    assert.equal(have.has(`${r.key}|${r.lang}`), false, `${w}: ei vielä tuotannossa`);
    assert.ok(r.max_len >= r.text.length, w);
    assert.doesNotMatch(r.text, /[<>]|https?:\/\/|www\./, w);
    assert.doesNotMatch(r.text, /Sipoonjoen Perinnesauna/, `${w}: yritysnimi paikkamerkillä`);
    assert.ok(!seen.has(`${r.key}|${r.lang}`), w); seen.add(`${r.key}|${r.lang}`);
  }
  const keys = new Set(rows.map((r) => r.key));
  for (const k of keys) assert.ok(seen.has(`${k}|fi`) && seen.has(`${k}|en`), `${k}: FI+EN`);
  assert.ok(keys.has('ui.shop.waitlist_errors.not_full') && keys.has('email.waitlist.subject'));
});

test('pending-import-36: jonotuslistan henkilömäärä (booking_134) FI+EN, sama kuin koodin oletus, ei vielä tuotannossa, ei <-merkkiä', () => {
  const rows = J('content/site-texts.pending-import-36.json');
  const defaults = new Map(R.collectDefaults().map((r) => [`${r.key}|${r.lang}`, r.text]));
  const have = new Set(FALLBACK.texts.map((r) => `${r.key}|${r.lang}`));
  const seen = new Set();
  for (const r of rows) {
    const w = `${r.key} [${r.lang}]`;
    assert.ok(/^ui\.shop\.waitlist_/.test(r.key), w);
    assert.ok(['fi', 'en'].includes(r.lang), w);
    assert.equal(r.kind, 'plain', w);
    assert.equal(r.class, 'normal', w);
    assert.equal(r.text, defaults.get(`${r.key}|${r.lang}`), w);
    assert.equal(have.has(`${r.key}|${r.lang}`), false, `${w}: ei vielä tuotannossa`);
    assert.ok(r.max_len >= r.text.length, w);
    assert.doesNotMatch(r.text, /[<>]|https?:\/\/|www\./, w);
    assert.ok(!seen.has(`${r.key}|${r.lang}`), w); seen.add(`${r.key}|${r.lang}`);
  }
  const keys = new Set(rows.map((r) => r.key));
  for (const k of keys) assert.ok(seen.has(`${k}|fi`) && seen.has(`${k}|en`), `${k}: FI+EN`);
  assert.deepEqual([...keys].sort(), ['ui.shop.waitlist_claim_invalid', 'ui.shop.waitlist_claim_not_enough', 'ui.shop.waitlist_errors.invalid_persons', 'ui.shop.waitlist_persons_hint']);
  const p34 = new Set(J('content/site-texts.pending-import-34.json').map((r) => r.key));
  for (const k of keys) assert.ok(!p34.has(k), `${k}: ei päällekkäin pending-import-34:n kanssa`);
});

test('pending-import-48: jonotuslistan henkilömäärä palvelutyypin mukaan (booking_148) FI+EN, sama kuin koodin oletus, ei vielä tuotannossa, ei <-merkkiä', () => {
  const rows = J('content/site-texts.pending-import-48.json');
  const defaults = new Map(R.collectDefaults().map((r) => [`${r.key}|${r.lang}`, r.text]));
  const have = new Set(FALLBACK.texts.map((r) => `${r.key}|${r.lang}`));
  const seen = new Set();
  for (const r of rows) {
    const w = `${r.key} [${r.lang}]`;
    assert.ok(['fi', 'en'].includes(r.lang), w);
    assert.equal(r.kind, 'plain', w);
    assert.equal(r.class, 'normal', w);
    assert.equal(have.has(`${r.key}|${r.lang}`), false, `${w}: ei vielä tuotannossa`);
    assert.ok(r.max_len >= r.text.length, w);
    assert.doesNotMatch(r.text, /[<>]|https?:\/\/|www\./, w);
    assert.ok(!seen.has(`${r.key}|${r.lang}`), w); seen.add(`${r.key}|${r.lang}`);
    if (r.key.startsWith('ui.shop.')) {
      assert.equal(r.text, defaults.get(`${r.key}|${r.lang}`), w);
      assert.deepEqual(r.placeholders, [], w);
    } else {
      assert.equal(r.key, 'email.waitlist.session_private', w);   // sähköpostirivi: sivutekstit-funktiot.test.mjs vertaa texts.ts:ään
      assert.deepEqual(r.placeholders, ['{{var:what}}', '{{var:when}}'], w);
    }
  }
  assert.deepEqual([...seen].sort(), ['email.waitlist.session_private|en', 'email.waitlist.session_private|fi', 'ui.shop.waitlist_invalid_persons_event|en', 'ui.shop.waitlist_invalid_persons_event|fi', 'ui.shop.waitlist_persons_hint_event|en', 'ui.shop.waitlist_persons_hint_event|fi', 'ui.shop.waitlist_private_note|en', 'ui.shop.waitlist_private_note|fi']);
  for (const f of ['34', '36', '39', '42']) {
    const other = new Set(J(`content/site-texts.pending-import-${f}.json`).map((r) => r.key));
    for (const k of new Set(rows.map((r) => r.key))) assert.ok(!other.has(k), `${k}: ei päällekkäin pending-import-${f}:n kanssa`);
  }
});
test('pending-import-39: jonotusilmoituksen tarjousaika päättyi (booking_137) FI+EN, sama kuin koodin oletus, ei vielä tuotannossa, ei <-merkkiä', () => {
  const rows = J('content/site-texts.pending-import-39.json');
  const defaults = new Map(R.collectDefaults().map((r) => [`${r.key}|${r.lang}`, r.text]));
  const have = new Set(FALLBACK.texts.map((r) => `${r.key}|${r.lang}`));
  const seen = new Set();
  for (const r of rows) {
    const w = `${r.key} [${r.lang}]`;
    assert.ok(['fi', 'en'].includes(r.lang), w);
    assert.equal(r.kind, 'plain', w);
    assert.equal(r.class, 'normal', w);
    assert.equal(r.text, defaults.get(`${r.key}|${r.lang}`), w);
    assert.equal(have.has(`${r.key}|${r.lang}`), false, `${w}: ei vielä tuotannossa`);
    assert.ok(r.max_len >= r.text.length, w);
    assert.deepEqual(r.placeholders, [], w);
    assert.doesNotMatch(r.text, /[<>]|https?:\/\/|www\./, w);
    assert.ok(!seen.has(`${r.key}|${r.lang}`), w); seen.add(`${r.key}|${r.lang}`);
  }
  assert.deepEqual([...seen].sort(), ['ui.shop.waitlist_claim_expired|en', 'ui.shop.waitlist_claim_expired|fi']);
  for (const f of ['34', '36']) {
    const other = new Set(J(`content/site-texts.pending-import-${f}.json`).map((r) => r.key));
    assert.ok(!other.has('ui.shop.waitlist_claim_expired'), `ei päällekkäin pending-import-${f}:n kanssa`);
  }
});
