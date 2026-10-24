// Paketti 10 / booking_142: alennuskoodit ja vuosikortit. Puhdas logiikka (koodin muoto, alennuksen jako riveille kuten palvelimen _discount_split),
// tekstit (FI+EN, ei paikkamerkkejä, ei '<'), migraation ja rollbackin rakenne, käyttöliittymän kytkennät sekä hallinnan ja tilaussivun mockit.
// SQL-käyttäytyminen testataan PG17:ssä: booking/supabase/tests/discounts/t142_annual_cards_discount_codes.sql (CI:ssä ei Postgresia).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import {
  normalizeCode, validCodeFormat, generatedDiscountCode, generatedAnnualCardCode, NATURE_WORDS, DISCOUNT_ALPHABET,
  discountSplit, quoteSignature, isAnnualQuote, codeError, CODE_ERROR_CODES, isCodeError,
} from '../shop/src/discount-code-logic.js';
import { DISCOUNT_TEXTS } from '../shop/src/discount-texts.js';
import { T } from '../shop/src/i18n.js';
import { OT } from '../shop/src/order-texts.js';
import { createAdminMock } from '../admin/options-mock.js';
import { createOrderMock } from '../shop/src/order-mock.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const rd = (p) => readFileSync(resolve(root, p), 'utf8');
const SQL = rd('booking/supabase/migrations/20261024104958_booking_142_annual_cards_discount_codes.sql');
const RB = rd('booking/supabase/rollbacks/20261024104958_booking_142_ROLLBACK.sql');
const T142 = rd('booking/supabase/tests/discounts/t142_annual_cards_discount_codes.sql');
const SHOP = rd('booking/shop/src/shop.js'), ORDER = rd('booking/shop/src/order.js'), ADMIN = rd('booking/admin/admin.js');
const DISC = rd('booking/admin/views/discounts.js'), CUST = rd('booking/admin/views/customers.js'), CSS = rd('booking/shop/src/shop.css');

test('koodin normalisointi vastaa palvelimen _norm_code-funktiota (välilyönnit pois, isot kirjaimet)', () => {
  assert.equal(normalizeCode(' kesä 15 '), 'KESÄ15');
  assert.equal(normalizeCode(' norppa15\t'), 'NORPPA15');
  assert.equal(normalizeCode(null), '');
  assert.ok(validCodeFormat('kesa-15') && !validCodeFormat('AB') && !validCodeFormat('KESÄ15') && !validCodeFormat('A'.repeat(41)));
  assert.match(SQL, /function booking\._norm_code\(p_code text\)[\s\S]*?upper\(regexp_replace\(coalesce\(p_code, ''\), '\\s', '', 'g'\)\)/);
});

test('arvotut koodit: alennuskoodi 6 merkkiä ilman sekoittuvia merkkejä, vuosikorttikoodi = luontosana + 1–999', () => {
  for (let i = 0; i < 300; i++) {
    const c = generatedDiscountCode();
    assert.match(c, /^[A-HJ-NP-Z2-9]{6}$/);
    assert.ok([...c].every((x) => DISCOUNT_ALPHABET.includes(x)));
    const a = generatedAnnualCardCode(), w = NATURE_WORDS.find((x) => a.startsWith(x));
    assert.ok(w, a); const n = Number(a.slice(w.length)); assert.ok(Number.isInteger(n) && n >= 1 && n <= 999, a);
    assert.ok(validCodeFormat(a) && validCodeFormat(c));
  }
  assert.match(SQL, /'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'/);
  for (const w of NATURE_WORDS) assert.ok(SQL.includes(`'${w}'`), `luontosana ${w} puuttuu palvelimelta`);
});

test('alennuksen jako riveille: summa täsmää sentilleen, jokainen rivi ≤ oma hinta, kohdistus tuotteisiin', () => {
  const lines = [{ key: 'r1', product_id: 1, kind: 'reservation', gross: 36 }, { key: 'a1', product_id: 7, kind: 'addon', gross: 10 }, { key: 'a2', product_id: 8, kind: 'addon', gross: 5 }];
  const p = discountSplit({ kind: 'percent', value: 15 }, lines);
  assert.equal(p.eligible, 51); assert.equal(p.discount, 7.65);
  assert.equal(Math.round(p.shares.reduce((s, x) => s + x.amount, 0) * 100), 765);
  const f = discountSplit({ kind: 'fixed', value: 100 }, lines);   // euroalennus ei voi ylittää hintaa
  assert.equal(f.discount, 51); assert.deepEqual(f.shares.map((x) => x.amount), [36, 10, 5]);
  const t = discountSplit({ kind: 'fixed', value: 10, target_scope: 'product', product_ids: [1] }, lines);
  assert.deepEqual(t.shares, [{ key: 'r1', amount: 10 }]);
  assert.deepEqual(discountSplit({ kind: 'percent', value: 50, target_scope: 'product', product_ids: [99] }, lines), { eligible: 0, discount: 0, shares: [] });
  const odd = discountSplit({ kind: 'fixed', value: 10 }, [{ key: 1, kind: 'reservation', gross: 3.33 }, { key: 2, kind: 'reservation', gross: 3.33 }, { key: 3, kind: 'reservation', gross: 3.34 }]);
  assert.equal(Math.round(odd.shares.reduce((s, x) => s + x.amount, 0) * 100), 1000);
  assert.match(SQL, /function booking\._discount_split\(p_code booking\.discount_codes, p_lines jsonb\)/);
});

test('ALV: alennus pienentää rivin bruttoa, ALV lasketaan riviltä (order_items.line_vat on generoitu); hintoihin ja ALV-kantoihin ei kosketa', () => {
  assert.doesNotMatch(SQL, /update\s+kb\.products/i, 'tuotteiden hintoja ei muuteta');
  assert.doesNotMatch(SQL, /alter\s+table\s+kb\./i);
  assert.doesNotMatch(SQL, /vat_rate\s*=\s*[\d.]/i, 'ALV-kantaa ei aseteta kiinteästi');
  assert.equal((SQL.match(/insert into booking\.discount_codes\b/gi) || []).length, 1, 'ainoa insert on admin_save_discount_code (migraatio ei luo koodeja)');
  assert.doesNotMatch(SQL, /insert\s+into\s+kb\.products/i, 'migraatio ei luo tuotteita');
  assert.match(SQL, /line_total_gross/);
});

test('kassan tila: allekirjoitus sitoo koodin henkilömäärään ja lisäpalveluihin; vuosikortti tunnistetaan', () => {
  assert.equal(quoteSignature(2, [1, 0]), quoteSignature('2', ['1', null]));
  assert.notEqual(quoteSignature(2, [1]), quoteSignature(3, [1]));
  assert.ok(isAnnualQuote({ ok: true, type: 'annual_card' }) && isAnnualQuote({ ok: true, type: 'annual_code' }));
  assert.ok(!isAnnualQuote({ ok: true, type: 'discount' }) && !isAnnualQuote({ ok: false, type: 'annual_card' }) && !isAnnualQuote(null));
});

test('virhekoodit: jokaisella palvelimen _code_msg-koodilla on FI- ja EN-teksti; tuntematon → yleinen', () => {
  const server = [...SQL.matchAll(/when '([a-z_]+)' then '/g)].map((m) => m[1]);
  assert.ok(server.length >= 10, 'palvelimen koodit');
  for (const c of server) { assert.ok(isCodeError(c), `${c} puuttuu kaupasta`); assert.ok(DISCOUNT_TEXTS.fi.codeErrors[c] && DISCOUNT_TEXTS.en.codeErrors[c], c); }
  for (const c of CODE_ERROR_CODES) assert.ok(server.includes(c), `${c}: kaupassa mutta ei palvelimella`);
  assert.equal(codeError('en', { code: 'code_expired' }), DISCOUNT_TEXTS.en.codeErrors.code_expired);
  assert.equal(codeError('fi', { code: 'ei_tunnettu' }), DISCOUNT_TEXTS.fi.codeErrors.generic);
});

test('tekstit: FI ja EN samat avaimet, ei paikkamerkkejä, ei hintoja eikä <-merkkiä; kytketty T- ja OT-sanakirjoihin', () => {
  const flat = (o, p = '') => Object.entries(o).flatMap(([k, v]) => (typeof v === 'object' ? flat(v, `${p}${k}.`) : [[`${p}${k}`, v]]));
  const fi = flat(DISCOUNT_TEXTS.fi), en = flat(DISCOUNT_TEXTS.en);
  assert.deepEqual(fi.map((x) => x[0]), en.map((x) => x[0]));
  for (const [k, v] of [...fi, ...en]) { assert.ok(v && !/[<{}]/.test(v), k); assert.doesNotMatch(v, /\d+\s*(€|eur)/i, `${k}: ei hintaa tekstissä`); }
  assert.equal(T.fi.codeToggle, DISCOUNT_TEXTS.fi.codeToggle); assert.equal(T.en.codeErrors.invalid_code, DISCOUNT_TEXTS.en.codeErrors.invalid_code);
  for (const k of ['annualCodeTitle', 'annualCodeLead', 'annualCodeValid', 'annualCodePending', 'annualCodeBook']) assert.ok(OT.fi[k] && OT.en[k] && !/[<]/.test(OT.fi[k] + OT.en[k]), k);
});

test('sivutekstien tuontitiedosto 42: FI+EN, sama kuin koodin oletus, vain uudet avaimet', async () => {
  const rows = JSON.parse(rd('content/site-texts.pending-import-42.json'));
  const { collectDefaults } = await import('../shop/src/text-registry.js');
  const def = new Map(collectDefaults().map((r) => [`${r.key}|${r.lang}`, r.text]));
  assert.equal(rows.length, 90);
  for (const r of rows) {
    assert.match(r.key, /^ui\.(shop\.(code_|annual_)|order\.annual_code)/);
    assert.equal(r.text, def.get(`${r.key}|${r.lang}`), r.key);
    assert.ok(!r.text.includes('<') && r.text.length <= r.max_len && r.kind === 'plain' && r.placeholders.length === 0, r.key);
  }
  const keys = new Set(rows.map((r) => r.key));
  for (const k of keys) assert.ok(rows.some((r) => r.key === k && r.lang === 'fi') && rows.some((r) => r.key === k && r.lang === 'en'), k);
  const fb = JSON.parse(rd('content/site-texts.fallback.json')).texts;
  assert.ok(!fb.some((r) => keys.has(r.key)), 'avaimet eivät ole vielä tuotannossa');
});

test('migraatio: SECURITY DEFINER + search_path tyhjä, oikeudet rajattu, verkkomyynti oletuksena pois', () => {
  const fns = [...SQL.matchAll(/create or replace function (booking\.[a-z_]+)\(/g)].map((m) => m[1]);
  assert.ok(fns.length >= 30);
  for (const m of SQL.matchAll(/create or replace function booking\.[a-z_]+\([\s\S]*?as \$\$/g)) {
    if (!/language (sql|plpgsql) immutable/.test(m[0])) assert.match(m[0], /security definer/, m[0].slice(0, 80));   // puhtaat apufunktiot (immutable sql) ilman definer-oikeuksia
    assert.match(m[0], /set search_path = ''/, m[0].slice(0, 80));
  }
  for (const f of fns) assert.ok(SQL.includes(`'${f}(`), `${f}: oikeudet asetettu`);
  assert.match(SQL, /revoke all on function %s from public, anon, authenticated/);
  assert.match(SQL, /annual_card_sale_enabled/);
  assert.doesNotMatch(SQL, /insert into booking\.settings[\s\S]{0,200}annual_card_sale_enabled[\s\S]{0,40}true/i, 'myynti ei mene päälle migraatiossa');
  for (const f of ['public_check_code', 'public_create_booking_code', 'public_annual_card_offer', 'public_buy_annual_card', 'public_annual_card_purchase_code',
    'admin_list_discount_codes', 'admin_save_discount_code', 'admin_delete_discount_code', 'admin_list_annual_cards_details', 'admin_create_annual_card']) assert.ok(fns.includes(`booking.${f}`), f);
  assert.match(SQL, /_rate_limit|rate_limited/);
  assert.doesNotMatch(SQL, /\b(admin_save_message|admin_list_messages|messages_dispatch|_order_message_rows|_product_message_mail)\b/, 'ei kosketa paketin 09 (booking_141) funktioihin');
  assert.doesNotMatch(SQL, /\bpublic\.[a-z_]+/i, 'public-skeemaan ei kosketa');
});

test('rollback poistaa jokaisen migraation luoman funktion ja triggerin', () => {
  const fns = new Set([...SQL.matchAll(/create or replace function (booking\.[a-z_]+)\(/g)].map((m) => m[1]));
  for (const f of fns) assert.match(RB, new RegExp(`drop function if exists ${f.replace('.', '\\.')}\\(`), f);
  for (const m of SQL.matchAll(/create trigger ([a-z0-9_]+)/g)) assert.ok(RB.includes(`drop trigger if exists ${m[1]} `), m[1]);
  for (const c of ['code', 'purchase_order_id', 'target_scope', 'usage_type', 'is_annual_card_code']) assert.match(RB, new RegExp(`drop column if exists ${c}\\b`), c);
  assert.match(T142, /TESTRESULT/);
});

test('kauppa: koodikenttä kassalla, vuosikortti lukitsee henkilömäärän ja lisäpalvelut, varaus koodilla vain kun koodi annettu', () => {
  assert.match(SHOP, /'data-testid': 'checkout-code'/);
  assert.match(SHOP, /rpc\('public_check_code'/);
  assert.match(SHOP, /code\.value \? 'public_create_booking_code' : 'public_create_booking'|public_create_booking_code/);
  assert.match(SHOP, /isAnnualQuote/);
  assert.match(SHOP, /parts\[0\] === 'vuosikortti'/);
  assert.match(SHOP, /rpc\('public_annual_card_offer'\)/);
  assert.match(SHOP, /rpc\('public_buy_annual_card'/);
  assert.match(SHOP, /S\.audience === 'business'\) return null/, 'yritysasiakkaille ei vuosikorttimyyntiä');
  assert.match(CSS, /\.bk-code\b/); assert.match(CSS, /\.bk-annual\b/);
  assert.doesNotMatch(CSS.slice(CSS.indexOf('/* Alennus- ja vuosikorttikoodi')), /#(00f|0000ff|1e90ff|2563eb|3b82f6|1d4ed8|0070f3)|\bblue\b/i, 'ei sinistä');
});

test('tilaussivu: vuosikortin koodi näytetään public_annual_card_purchase_code-vastauksesta; mock-skenaario annual', async () => {
  assert.match(ORDER, /'public_annual_card_purchase_code'/);
  assert.match(ORDER, /'data-testid': 'annual-card-code'/);
  const m = createOrderMock({ scenario: 'annual', storage: null });
  const r = await m.rpc('public_annual_card_purchase_code', { p_token: 'x' });
  assert.equal(r.has_card, true); assert.ok(validCodeFormat(r.code));
  const p = await createOrderMock({ scenario: 'annualpending', storage: null }).rpc('public_annual_card_purchase_code', { p_token: 'x' });
  assert.equal(p.has_card, true); assert.equal(p.code, null);
  const n = await createOrderMock({ storage: null }).rpc('public_annual_card_purchase_code', { p_token: 'x' });
  assert.equal(n.has_card, false);
});

test('hallinta: Alennuskoodit-reitti (oikeus catalog.edit tai annual_cards.manage), arvo merkkijonona, vuosikortti asiakkaalle koodilla', async () => {
  assert.match(ADMIN, /path: 'alennuskoodit'.*any: \['catalog\.edit', 'annual_cards\.manage'\].*loadView\('discounts'\)/);
  assert.match(DISC, /value: sh \? '100' : v\.replace\(',', '\.'\)/);
  assert.match(DISC, /rpc\('admin_list_annual_cards_details'\)/);
  assert.match(CUST, /rpc\('admin_create_annual_card'/);
  const m = createAdminMock({ role: 'manager' });
  const list = await m.rpc('admin_list_discount_codes');
  assert.ok(list.length >= 1);
  const s = await m.rpc('admin_save_discount_code', { p_id: null, p_data: { code: ' syksy 10 ', kind: 'percent', value: '10', usage_type: 'single', target_scope: 'order' } });
  assert.equal(s.code, 'SYKSY10');
  await assert.rejects(m.rpc('admin_save_discount_code', { p_id: null, p_data: { code: 'SYKSY10', kind: 'percent', value: '10' } }), /käytössä/);
  await assert.rejects(m.rpc('admin_save_discount_code', { p_id: null, p_data: { code: 'X1Y2Z3', kind: 'percent', value: '12,5' } }), /määrä/, 'pilkku muunnetaan näkymässä, palvelin hyväksyy vain pisteen');
  const g = await m.rpc('admin_save_discount_code', { p_id: null, p_data: { code: '', kind: 'fixed', value: '5', usage_type: 'permanent' } });
  assert.match(g.code, /^[A-HJ-NP-Z2-9]{6}$/);
  const c = await m.rpc('admin_create_annual_card', { p_customer_id: 1, p_valid_from: '2026-11-01', p_valid_to: '2027-10-31', p_code: null, p_notes: null });
  assert.ok(NATURE_WORDS.some((w) => c.code.startsWith(w)));
  const staff = createAdminMock({ role: 'staff' });
  await assert.rejects(staff.rpc('admin_list_annual_cards_details'), /annual_cards\.manage/);
});

test('build-pages kopioi hallinnan tuomat koodimoduulit dist/shop/src:iin', () => {
  const b = readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), '../../scripts/build-pages.mjs'), 'utf8');
  for (const f of ['discount-code-logic.js', 'discount-texts.js']) assert.ok(b.includes(`cpSync('booking/shop/src/${f}', join(OUT, 'shop', 'src', '${f}'))`), f);
});
