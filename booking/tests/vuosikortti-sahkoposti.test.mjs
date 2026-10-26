// booking_146: vuosikortin koodi sähköpostiin ja näkyviin kassalla. Migraation ja rollbackin rakenne, sähköpostipohja (annual_card_code),
// hallinnan koodinäkymän logiikka, tekstit (pending-import-46: FI+EN, ei '<', täsmää koodin oletuksiin), mock ja käyttöliittymän kytkennät.
// SQL-käyttäytyminen testataan PG17:ssä: booking/supabase/tests/discounts/t146_annual_card_email.sql (CI:ssä ei Postgresia).
// TypeScript-pohjan osat ajetaan vain Node 22.18+:lla (CI ajaa tämän tiedoston Node 22:lla); Node 20 ohittaa ne.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import { annualCardModel, MAIL_STATUS, MAIL_TONE } from '../admin/annual-card-logic.js';
import { ANNUAL_CARD_TEXTS, acText, loadAcTexts, clearAcTextCache, fillAcText } from '../admin/annual-card-texts.js';
import { createMock } from '../admin/talous-mock.js';
import { createTalousApi } from '../admin/talous-api.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const rd = (p) => readFileSync(resolve(root, p), 'utf8');
const MIG = 'booking/supabase/migrations/20261024124037_booking_146_annual_card_email.sql';
const RB = 'booking/supabase/rollbacks/20261024124037_booking_146_ROLLBACK.sql';
const SQLT = 'booking/supabase/tests/discounts/t146_annual_card_email.sql';
const P46 = 'content/site-texts.pending-import-46.json';
let TPL = null, ET = null;
try { TPL = await import('../supabase/functions/send-emails/templates.ts'); ET = TPL.EMAIL_TEXTS; } catch (e) { if (!/ERR_UNKNOWN_FILE_EXTENSION|Unknown file extension/.test(String(e?.code || e))) throw e; }
const tsSkip = TPL ? false : 'Node ei tue .ts-tuontia (tarvitaan Node >= 22.18)';

test('numerointi: booking_146 ja pending-import-46; booking_144/145-tiedostoihin ei kosketa', () => {
  for (const f of [MIG, RB, SQLT, P46]) assert.ok(existsSync(resolve(root, f)), f);
  const mine = readdirSync(resolve(root, 'booking/supabase/migrations')).filter((f) => /booking_146/.test(f));
  assert.deepEqual(mine, ['20261024124037_booking_146_annual_card_email.sql']);
  for (const f of readdirSync(resolve(root, 'booking/supabase/migrations')).filter((x) => /booking_14[45]/.test(x))) assert.doesNotMatch(rd(`booking/supabase/migrations/${f}`), /annual_card_code/, `${f}: ei tämän paketin muutoksia`);
});

test('migraatio: uusi kind, jonotus kerran per kortti, claim-wrapper, kassan RPC, oikeudet ja search_path', () => {
  const m = rd(MIG);
  assert.match(m, /set local lock_timeout = '5s';/);
  assert.match(m, /'waitlist_spot_freed', 'annual_card_code'\)\)/);
  assert.match(m, /create trigger annual_cards_email after insert on booking\.annual_cards/);
  assert.match(m, /if new\.purchase_order_id is null then return new; end if;/, 'käsin luotu kortti ei ole myynti → ei viestiä');
  assert.match(m, /'annual_card_code:' \|\| new\.id::text/, 'dedupe per kortti');
  assert.match(m, /exception when others then/, 'jonotuksen virhe ei kaada maksua');
  assert.match(m, /'annual_card_email_failed'/);
  assert.match(m, /email_outbox_claim_base_146/);
  assert.match(m, /'\/varaa\/'/); assert.match(m, /'\/en\/book\/'/);
  assert.match(m, /booking\.has_permission\('payments\.manage'\)/); assert.match(m, /booking\.has_permission\('annual_cards\.manage'\)/);
  assert.match(m, /grant execute on function booking\.email_outbox_claim\(integer\) to service_role;/);
  assert.match(m, /grant execute on function booking\.admin_annual_card_for_order\(bigint\) to authenticated, service_role;/);
  for (const fn of m.matchAll(/create or replace function (booking\.[a-z0-9_]+)\([^)]*\)[^$]*?as \$\$/g)) assert.match(fn[0], /security definer set search_path = ''|set search_path = ''/, `${fn[1]}: search_path`);
  assert.doesNotMatch(m, /\bpublic\.[a-z_]+/i, 'ei public-skeemaa');
  assert.doesNotMatch(m, /whatsapp/i);
  assert.doesNotMatch(m, /update booking\.(products|vat_rates|settings)\b|price\s*=/i, 'ei hintoja, ALV:tä eikä asetuksia');
  assert.doesNotMatch(m, /_annual_card_from_order\(\) returns/, 'kortin myöntäminen (booking_142/143) ennallaan');
});

test('rollback: trigger, funktiot ja kind pois, booking_132:n claim palautuu, uudelleenajettava', () => {
  const r = rd(RB);
  assert.match(r, /drop trigger if exists annual_cards_email on booking\.annual_cards;/);
  assert.match(r, /drop function if exists booking\.admin_annual_card_for_order\(bigint\);/);
  assert.match(r, /drop function if exists booking\._annual_card_mail\(bigint\);/);
  assert.match(r, /to_regprocedure\('booking\.email_outbox_claim_base_146\(integer\)'\) is not null/);
  assert.match(r, /rename to email_outbox_claim;/);
  assert.match(r, /delete from booking\.email_outbox where kind = 'annual_card_code';/);
  assert.match(r, /'waitlist_spot_freed'\)\);/);
  assert.doesNotMatch(r, /annual_card_code'\)\)/);
});

test('SQL-testi t146 kattaa verkko- ja kassamyynnin, kerran per kortti, ei sähköpostia, pois-tilan, käsin luodun kortin ja oikeudet', () => {
  const t = rd(SQLT);
  for (const s of ['public_buy_annual_card', 'admin_record_payment', 'admin_annual_card_for_order', 'email_outbox_claim', 'no_email', 'skipped', 'dry_run', 'admin_create_annual_card', 'annual_card_email_failed', '/en/book/']) assert.ok(t.includes(s), s);
});

test('sähköpostipohja: index.ts ohittaa perutun / puuttuvan kortin ennen renderöintiä; ei WhatsAppia', () => {
  const idx = rd('booking/supabase/functions/send-emails/index.ts');
  assert.match(idx, /import \{[^}]*annualCardBlock[^}]*\} from "\.\/templates\.ts"/);
  assert.match(idx, /const acBlock = annualCardBlock\(r\);\n\s*if \(acBlock\) \{ await bk\.rpc\("email_outbox_mark", \{ p_id: r\.id, p_result: "skipped", p_error: acBlock \}\)/);
  assert.ok(idx.indexOf('annualCardBlock(r)') < idx.indexOf('render(r.kind as Kind, r, r.locale, t)'));
  const tpl = rd('booking/supabase/functions/send-emails/templates.ts');
  assert.match(tpl, /\| "annual_card_code";/);
  assert.match(tpl, /case "annual_card_code": \{/);
  assert.doesNotMatch(tpl.slice(tpl.indexOf('case "annual_card_code"'), tpl.indexOf('case "waitlist_spot_freed"')), /whatsapp/i);
});

test('sähköposti: koodi, voimassaolo, kalenterilinkki, ohjeet (1 hlö, koodi kassalla) ja Tapion allekirjoitus FI + EN', { skip: tsSkip }, () => {
  const row = (locale) => ({ kind: 'annual_card_code', locale, to_name: 'Aada Testi', annual_card: { code: 'K7QX9MZ3TA', valid_from: '2026-10-24', valid_to: '2027-10-23', active: true, revoked: false, booking_url: `https://saunotus.fi${locale === 'en' ? '/en/book/' : '/varaa/'}` } });
  const fi = TPL.render('annual_card_code', row('fi'), 'fi'), en = TPL.render('annual_card_code', row('en'), 'en');
  for (const [m, l] of [[fi, 'fi'], [en, 'en']]) {
    assert.match(m.text, /K7QX9MZ3TA/); assert.match(m.html, />K7QX9MZ3TA</);
    assert.match(m.text, l === 'fi' ? /Voimassa 24\.10\.2026–23\.10\.2027/ : /Valid 24\/10\/2026–23\/10\/2027/);
    assert.match(m.text, l === 'fi' ? /yhdelle hengelle/ : /one person/);
    assert.match(m.text, l === 'fi' ? /Alennus- tai vuosikorttikoodi/ : /Discount or annual card code/);
    assert.match(m.html, l === 'fi' ? /href="https:\/\/saunotus\.fi\/varaa\/"/ : /href="https:\/\/saunotus\.fi\/en\/book\/"/);
    assert.match(m.text, /\nTapio\nSipoonjoen Perinnesauna\n$/);
    assert.match(m.text, /010 299 2866|\+358 10 299 2866/);
  }
});

test('tekstit: email.annual_card.* ja ui.admin.annual_card.* FI+EN, pending-import-46 täsmää koodiin, ei < eikä emojeja, ei päällekkäin', { skip: tsSkip }, () => {
  const rows = JSON.parse(rd(P46));
  const keys = new Set(rows.map((r) => r.key));
  assert.equal(rows.length, keys.size * 2, 'jokaisella avaimella FI + EN');
  const emailKeys = Object.keys(ET).filter((k) => k.startsWith('email.annual_card.'));
  assert.deepEqual([...keys].filter((k) => k.startsWith('email.')).sort(), emailKeys.sort());
  assert.deepEqual([...keys].filter((k) => k.startsWith('ui.')).sort(), Object.keys(ANNUAL_CARD_TEXTS.fi).sort());
  assert.ok([...keys].every((k) => /^(email\.annual_card|ui\.admin\.annual_card)\.[a-z0-9_]+$/.test(k)));
  for (const r of rows) {
    const want = r.key.startsWith('email.') ? ET[r.key][r.lang] : ANNUAL_CARD_TEXTS[r.lang][r.key];
    assert.equal(r.text, want, `${r.key} [${r.lang}]`);
    assert.equal(r.kind, 'plain'); assert.ok(['normal', 'protected'].includes(r.class));
    assert.ok(r.max_len >= r.text.length);
    assert.deepEqual(r.placeholders, [...new Set([...r.text.matchAll(/\{\{[^{}]+\}\}/g)].map((m) => m[0]))]);
    assert.doesNotMatch(r.text, /</); assert.doesNotMatch(r.text, /\p{Extended_Pictographic}/u); assert.doesNotMatch(r.text, /whatsapp/i);
    if (r.lang === 'en') assert.doesNotMatch(r.text, /\b(Kiitos|Hei|Vuosikortti|koodi)\b/);
  }
  assert.equal(ET['email.annual_card.sign_name'].fi, 'Tapio');
  for (const f of readdirSync(resolve(root, 'content')).filter((x) => /^site-texts\..*\.json$/.test(x) && x !== 'site-texts.pending-import-46.json')) {
    const raw = rd(`content/${f}`); for (const k of keys) assert.ok(!raw.includes(`"${k}"`), `${k} myös tiedostossa ${f}`);
  }
});

test('kassan näkymän malli: koodi, voimassaolo ja sähköpostin tila; ei korttia → selkeä huomautus', () => {
  assert.equal(annualCardModel(null), null);
  assert.equal(annualCardModel({ ok: true, has_season_card: false, card: null }), null);
  assert.equal(annualCardModel({ ok: true, has_season_card: true, payment_status: 'unpaid', card: null }).noteKey, 'ui.admin.annual_card.waiting_payment');
  assert.equal(annualCardModel({ ok: true, has_season_card: true, payment_status: 'paid', has_customer: false, card: null }).noteKey, 'ui.admin.annual_card.no_customer');
  assert.equal(annualCardModel({ ok: true, has_season_card: true, payment_status: 'paid', has_customer: true, card: null }).noteKey, 'ui.admin.annual_card.missing');
  const card = (status, to = 'a@example.test', extra = {}) => annualCardModel({ ok: true, has_season_card: true, payment_status: 'paid', has_customer: true, card: { id: 1, code: ' K7QX9MZ3TA ', valid_from: '2026-10-24', valid_to: '2027-10-23', active: true, revoked: false, ...extra }, email: status ? { status, to } : undefined });
  const m = card('sent'); assert.equal(m.state, 'card'); assert.equal(m.code, 'K7QX9MZ3TA'); assert.equal(m.from, '2026-10-24'); assert.equal(m.mail.key, 'ui.admin.annual_card.email_sent'); assert.equal(m.mail.tone, 'ok');
  assert.equal(card('no_email', null).mail.key, 'ui.admin.annual_card.email_no_email');
  assert.equal(card('no_email', null).mail.tone, 'warn');
  assert.equal(card('sending').mail.status, 'pending'); assert.equal(card('dead').mail.status, 'failed'); assert.equal(card('failed').mail.tone, 'err');
  assert.equal(card(undefined).mail.status, 'not_queued'); assert.equal(card('outo').mail.status, 'not_queued');
  assert.equal(card('sent', 'a@x', { revoked: true }).cardNoteKey, 'ui.admin.annual_card.revoked');
  for (const s of new Set(Object.values(MAIL_STATUS))) { assert.ok(MAIL_TONE[s], s); assert.ok(ANNUAL_CARD_TEXTS.fi[`ui.admin.annual_card.email_${s}`], s); assert.ok(ANNUAL_CARD_TEXTS.en[`ui.admin.annual_card.email_${s}`], s); }
});

test('hallinnan tekstit: sanakirja varalla, tietokannan rivi voittaa, rikkinäinen paikkamerkki → sanakirja', async () => {
  clearAcTextCache();
  assert.equal(acText('ui.admin.annual_card.copy', null, 'fi'), 'Kopioi koodi');
  assert.equal(acText('ui.admin.annual_card.copy', null, 'en'), 'Copy code');
  assert.equal(acText('ui.admin.annual_card.valid', { from: '1.1.2027', to: '31.12.2027' }, 'fi'), 'Voimassa 1.1.2027–31.12.2027');
  await loadAcTexts(null, [{ key: 'ui.admin.annual_card.copy', lang: 'fi', text: 'Kopioi' }, { key: 'ui.admin.annual_card.email_sent', lang: 'fi', text: 'Lähetetty {{var:eiole}}' }, { key: 'ui.muu', lang: 'fi', text: 'x' }]);
  assert.equal(acText('ui.admin.annual_card.copy', null, 'fi'), 'Kopioi');
  assert.equal(acText('ui.admin.annual_card.email_sent', { to: 'a@x' }, 'fi'), 'Koodi lähetetty sähköpostiin a@x.');
  clearAcTextCache();
  assert.equal(fillAcText('A {{var:x}} B', {}), 'A  B');
  for (const lang of ['fi', 'en']) for (const v of Object.values(ANNUAL_CARD_TEXTS[lang])) { assert.doesNotMatch(v, /</); assert.doesNotMatch(v, /\p{Extended_Pictographic}/u); }
  assert.deepEqual(Object.keys(ANNUAL_CARD_TEXTS.fi).sort(), Object.keys(ANNUAL_CARD_TEXTS.en).sort());
});

test('mock + API: vuosikorttitilaus näyttää koodin vasta maksun jälkeen; oikeassa tilassa puuttuva RPC → null (ei keksittyä koodia)', async () => {
  const mock = createMock({ n: 400, today: '2026-10-24' });
  const R = (n, a) => mock.rpc(n, a);
  const season = mock.orders.filter((o) => o.is_native && o.order_id % 25 === 0);
  const unpaid = season.find((o) => o.payment_status !== 'paid' && o.unpaid_amount > 0);
  assert.ok(unpaid, 'mockissa maksamaton vuosikorttitilaus');
  assert.equal((await R('admin_annual_card_for_order', { p_order_id: unpaid.order_id })).card, null);
  await R('admin_record_payment', { p_order_id: unpaid.order_id, p_method: 'card_terminal', p_amount: unpaid.unpaid_amount });
  const after = await R('admin_annual_card_for_order', { p_order_id: unpaid.order_id });
  assert.match(after.card.code, /^[ABCDEFGHJKMNPQRSTUVWXYZ2-9]{10}$/); assert.equal(after.card.valid_from, '2026-10-24'); assert.equal(after.card.valid_to, '2027-10-23');
  const other = mock.orders.find((o) => o.order_id % 25 !== 0);
  assert.equal((await R('admin_annual_card_for_order', { p_order_id: other.order_id })).has_season_card, false);
  const calls = []; const real = createTalousApi({ rpc: async (n, a) => { calls.push([n, a]); throw Object.assign(new Error('Could not find the function booking.admin_annual_card_for_order in the schema cache'), { status: 404, code: 'PGRST202' }); }, mock: false });
  assert.equal(await real.annualCardForOrder(5), null);
  assert.deepEqual(calls, [['admin_annual_card_for_order', { p_order_id: 5 }]]);
  assert.equal(await real.annualCardForOrder(5), null); assert.equal(calls.length, 1, 'puuttuva RPC muistetaan');
  const ok = createTalousApi({ rpc: async () => ({ ok: true, has_season_card: true, card: null, payment_status: 'unpaid' }), mock: false });
  assert.equal((await ok.annualCardForOrder(7)).has_season_card, true);
});

test('käyttöliittymä: tilauksen tiedot + maksun kirjauksen jälkeinen dialogi, iso koodi, kopiointi, teeman värit, build-lista ja CI', () => {
  const to = rd('booking/admin/views/talous-orders.js');
  assert.match(to, /api\.annualCardForOrder\(id\)\.catch\(\(\) => null\)/);
  assert.match(to, /sums, annualSec\(annual, sec\),\s*sec\(t\('order\.reservations'\), reservations\)/);   // tilausnäkymä 03: vuosikortti summien jälkeen, sitten varaukset
  assert.match(to, /doneToast\(res, RPC\.recordPayment\); afterChange\(res, o\.order_id\);\n.*\n\s*if \(api\.annualCardForOrder\) api\.annualCardForOrder\(o\.order_id\)\.then\(\(ac\) => showAnnualCardDialog\(ac\)\)/);
  const panel = rd('booking/admin/views/annual-card-panel.js');
  assert.match(panel, /navigator\.clipboard\?\.writeText/);
  assert.match(panel, /'data-testid': 'annual-card-code'/); assert.match(panel, /'data-testid': 'annual-card-copy'/); assert.match(panel, /'aria-live': 'polite'/);
  assert.doesNotMatch(panel, /\p{Extended_Pictographic}/u);
  assert.match(rd('booking/admin/views/talous.js'), /await loadAcTexts\(rpc\);/);
  const css = rd('booking/admin/admin.css'); const block = css.slice(css.indexOf('/* vuosikorttikoodi kassalla (booking_146)')).replace(/\/\*[\s\S]*?\*\//g, '');
  assert.ok(block.length > 300); assert.doesNotMatch(block, /#[0-9a-f]{3,8}\b|rgb\(|hsl\(|blue/i);
  assert.match(block, /\.ac-code\{[^}]*font:700 30px/);
  assert.match(rd('scripts/build-pages.mjs'), /'annual-card-texts\.js', 'annual-card-logic\.js', 'views\/annual-card-panel\.js'/);
  assert.match(rd('.github/workflows/pages.yml'), /node --test booking\/tests\/vuosikortti-sahkoposti\.test\.mjs/);
  assert.match(rd('booking/tests/sivutekstit-funktiot.test.mjs'), /pending-import-46\.json/);
});
