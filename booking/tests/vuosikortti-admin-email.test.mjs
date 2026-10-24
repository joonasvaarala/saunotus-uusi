// booking_154: hallinnasta myönnetyn vuosikortin koodi sähköpostiin. Migraation ja rollbackin rakenne (ei takautuvaa lähetystä,
// ostetun kortin polku ennallaan, AFTER INSERT -trigger, tilaukseton outbox-rivi dedupe-avaimella annual_card_code:<id>),
// claim (vastaanottaja kortin asiakkaalta), sähköpostipohja (oma johdanto source 'admin'), Myönnä-dialogin valinta
// "Lähetä koodi asiakkaalle", tekstit (pending-import-54: FI+EN, ei '<'), mock ja CI.
// SQL-käyttäytyminen testataan PG17:ssä: booking/supabase/tests/discounts/t154_annual_card_admin_email.sql
// (pre154_existing_cards.sql ennen migraatiota). CI:ssä ei Postgresia. TypeScript-pohjan osat vain Node 22.18+:lla.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import { ANNUAL_MANAGE_TEXTS, amCreatedMessage, clearAmTextCache } from '../admin/annual-manage-texts.js';
import { createAdminMock } from '../admin/options-mock.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const rd = (p) => readFileSync(resolve(root, p), 'utf8');
const MIG = 'booking/supabase/migrations/20261024134645_booking_154_annual_card_admin_email.sql';
const RB = 'booking/supabase/rollbacks/20261024134645_booking_154_ROLLBACK.sql';
const M146 = 'booking/supabase/migrations/20261024124037_booking_146_annual_card_email.sql';
const SQLT = 'booking/supabase/tests/discounts/t154_annual_card_admin_email.sql';
const PRE = 'booking/supabase/tests/discounts/pre154_existing_cards.sql';
const P54 = 'content/site-texts.pending-import-54.json';
let TPL = null;
try { TPL = await import('../supabase/functions/send-emails/templates.ts'); } catch (e) { if (!/ERR_UNKNOWN_FILE_EXTENSION|Unknown file extension/.test(String(e?.code || e))) throw e; }
const tsSkip = TPL ? false : 'Node ei tue .ts-tuontia (tarvitaan Node >= 22.18)';
const SQL = rd(MIG), ROLL = rd(RB), S146 = rd(M146);
const strip = (s) => s.split('\n').filter((l) => !/^\s*--/.test(l)).join('\n');
const fnNames = (s) => [...s.matchAll(/create or replace function booking\.(\w+)\(/gi)].map((m) => m[1]);
const block = (s, start) => { const i = s.indexOf(start); assert.ok(i >= 0, start); const j = s.indexOf('$$;', i); return s.slice(i, j + 3); };

test('numerointi: yksi booking_154-migraatio, rollback, SQL-testit ja pending-import-54 olemassa', () => {
  for (const f of [MIG, RB, SQLT, PRE, P54]) assert.ok(existsSync(resolve(root, f)), f);
  assert.deepEqual(readdirSync(resolve(root, 'booking/supabase/migrations')).filter((f) => /booking_154/.test(f)), [MIG.split('/').at(-1)]);
});

test('migraatio: vain vuosikortin sähköpostin funktiot, ei public-skeemaa, ei takautuvia rivejä', () => {
  assert.deepEqual(fnNames(SQL), ['_annual_card_email_trg', '_annual_card_mail', '_annual_card_admin_to', 'email_outbox_claim', 'admin_create_annual_card']);
  const code = strip(SQL);
  assert.doesNotMatch(code, /\bpublic\.\w+/i, 'ei public-skeemaa');
  assert.equal((code.match(/insert into booking\.email_outbox/gi) || []).length, 1, 'yksi outbox-insert, triggerin sisällä');
  const trg = block(code, 'create or replace function booking._annual_card_email_trg()');
  assert.ok(trg.includes('insert into booking.email_outbox'), 'insert vain triggerissä (uudet kortit)');
  assert.doesNotMatch(code.replace(trg, ''), /insert into|update booking\.email_outbox|from booking\.annual_cards\s+a?\s*where[^;]*email_outbox/i, 'ei rivejä olemassa oleville korteille');
  assert.match(code, /set local lock_timeout = '5s';/);
  // 5-parametrinen myöntö, _enqueue_email ja kassan näkymä ennallaan
  assert.doesNotMatch(code, /function booking\.admin_create_annual_card\(p_customer_id bigint, p_valid_from date, p_valid_to date, p_code text default/i);
  assert.ok(!fnNames(SQL).includes('_enqueue_email') && !fnNames(SQL).includes('admin_annual_card_for_order') && !fnNames(SQL).includes('admin_grant_annual_card'));
});

test('trigger: ostettu kortti täsmälleen booking_146:n polulla; hallinnan kortti vain käytössä, ei peruttu, koodillinen, ohitettavissa', () => {
  const trg = block(strip(SQL), 'create or replace function booking._annual_card_email_trg()');
  const old = block(S146, 'create or replace function booking._annual_card_email_trg()');
  const oldCall = old.slice(old.indexOf('perform booking._enqueue_email'), old.indexOf('exception when others'));
  assert.ok(trg.replace(/\s+/g, ' ').includes(oldCall.replace(/\s+/g, ' ')), 'ostetun kortin kutsu sama kuin booking_146');
  assert.match(trg, /if new\.purchase_order_id is not null then[\s\S]*?_enqueue_email\('annual_card_code', new\.purchase_order_id, null, null,\s*'annual_card_code:' \|\| new\.id::text, jsonb_build_object\('card_id', new\.id\)\);[\s\S]*?return new;\n  end if;/);
  assert.match(trg, /current_setting\('booking\.annual_card_email', true\), ''\) = 'skip' then return new;/);
  assert.match(trg, /new\.active is distinct from true or new\.revoked_at is not null or btrim\(coalesce\(new\.code, ''\)\) = '' then return new;/);
  assert.match(trg, /booking\._valid_email\(v_email\)/);
  assert.match(trg, /c\.anonymized_at is null/);
  assert.match(trg, /values \('annual_card_code', null, null, null,/, 'order_id null');
  assert.match(trg, /'annual_card_code:' \|\| new\.id::text, case when coalesce\(v_mode, 'off'\) = 'off' then 'skipped' else 'pending' end/);
  assert.match(trg, /jsonb_build_object\('card_id', new\.id, 'source', 'admin'\)\)\s*on conflict \(dedupe_key\) do nothing;/);
  assert.doesNotMatch(trg.slice(trg.indexOf('-- booking_154')), /'to'|email', v_email|'code'/, 'payloadissa ei henkilötietoja eikä koodia');
  assert.match(trg, /'annual_card_email_failed'/);
  assert.match(SQL, /drop trigger if exists annual_cards_email on booking\.annual_cards;\ncreate trigger annual_cards_email after insert on booking\.annual_cards\n  for each row execute function booking\._annual_card_email_trg\(\);/);
  assert.doesNotMatch(SQL, /annual_cards_email (after|before) [^;]*update/i, 'ei UPDATE-triggeriä → uudelleenaktivointi / koodin vaihto ei lähetä');
});

test('claim: source-kenttä ja vastaanottaja vain tilauksettomalle hallinnan kortin riville; allowlist ja annualCardBlock ennallaan', () => {
  const mail = block(SQL, 'create or replace function booking._annual_card_mail(');
  assert.match(mail, /'source', case when a\.purchase_order_id is null then 'admin' else 'purchase' end/);
  const to = block(SQL, 'create or replace function booking._annual_card_admin_to(');
  assert.match(to, /e\.order_id is null and a\.purchase_order_id is null/);
  assert.match(to, /'to', case when booking\._valid_email\(c\.email\) then c\.email end, 'to_name', c\.name/);
  const claim = block(SQL, 'create or replace function booking.email_outbox_claim(');
  assert.match(claim, /\|\| coalesce\(booking\._annual_card_admin_to\(\(z\.item->>'id'\)::bigint\), '\{\}'::jsonb\)/);
  assert.match(claim, /booking\.email_outbox_claim_base_146\(p_limit\)/);
  assert.match(SQL, /revoke all on function booking\._annual_card_admin_to\(bigint\) from public, anon, authenticated;/);
  assert.match(SQL, /revoke all on function booking\.email_outbox_claim\(integer\) from public, anon, authenticated;/);
  const idx = rd('booking/supabase/functions/send-emails/index.ts');
  assert.match(idx, /const blocked = outboxAllowlistBlock\(mode, r, testRecipients\);/);
  assert.match(idx, /const acBlock = annualCardBlock\(r\);/);
  const tpl = rd('booking/supabase/functions/send-emails/templates.ts');
  assert.match(tpl, /if \(c\.revoked === true\) return "vuosikortti on peruttu";\n  if \(c\.active === false\) return "vuosikortti ei ole käytössä";\n  if \(!String\(c\.code \?\? ""\)\.trim\(\)\) return "vuosikortin koodi puuttuu";/);
});

test('myöntö p_send_email: uusi ylikuormitus ilman oletuksia, kutsuu 5-parametrista, nollaa ohituksen, oikeudet', () => {
  const f = SQL.slice(SQL.indexOf('create or replace function booking.admin_create_annual_card('));
  assert.match(f, /^create or replace function booking\.admin_create_annual_card\(p_customer_id bigint, p_valid_from date, p_valid_to date,\s*p_code text, p_notes text, p_send_email boolean\) returns jsonb/);
  assert.doesNotMatch(f.slice(0, f.indexOf('returns')), /default/i, 'ei oletuksia → 5-parametrinen kutsu ohjautuu vanhaan funktioon');
  assert.match(f, /perform booking\._require_permission\('annual_cards\.manage'\);/);
  assert.match(f, /set_config\('booking\.annual_card_email', case when v_send then '' else 'skip' end, true\);\n  r := booking\.admin_create_annual_card\(p_customer_id, p_valid_from, p_valid_to, p_code, p_notes\);\n  perform set_config\('booking\.annual_card_email', '', true\);/);
  for (const s of ['not_requested', 'no_email', 'not_queued']) assert.ok(f.includes(`'${s}'`), s);
  assert.match(SQL, /revoke all on function booking\.admin_create_annual_card\(bigint, date, date, text, text, boolean\) from public, anon;/);
  assert.match(SQL, /grant execute on function booking\.admin_create_annual_card\(bigint, date, date, text, text, boolean\) to authenticated, service_role;/);
  assert.match(f, /security definer set search_path = ''/);
});

test('rollback: palauttaa booking_146:n määritelmät tavu tavulta, triggerin WHEN-ehdon, poistaa ylikuormituksen ja apufunktion', () => {
  for (const start of ['create or replace function booking._annual_card_email_trg()', 'create or replace function booking._annual_card_mail(', 'create or replace function booking.email_outbox_claim('])
    assert.equal(block(ROLL, start), block(S146, start), start);
  assert.match(ROLL, /create trigger annual_cards_email after insert on booking\.annual_cards\n  for each row when \(new\.purchase_order_id is not null\) execute function booking\._annual_card_email_trg\(\);/);
  assert.match(ROLL, /drop function if exists booking\.admin_create_annual_card\(bigint, date, date, text, text, boolean\);/);
  assert.match(ROLL, /drop function if exists booking\._annual_card_admin_to\(bigint\);/);
  assert.doesNotMatch(strip(ROLL), /delete from|admin_create_annual_card\(p_customer_id/i);
  for (const m of ['a93b1f1180257ee8647c54b420df5749', '270c3d03eff0b36c8f1992129d965b5a', '1eb05f67aecff0034f9178eb0e2160eb']) assert.ok(ROLL.includes(m), m);
});

test('SQL-testi t154 kattaa: yksi rivi, toistuva päivitys, peruttu / ei käytössä / kooditon, ostettu kortti, olemassa olevat kortit', () => {
  const t = rd(SQLT);
  for (const s of ['A1:', 'A4:', 'A5:', 'A6:', 'N1:', 'N3:', 'N4:', 'N5:', 'N6:', 'N7:', 'N8:', 'N9:', 'O1:', 'B1:', 'B2:', 'P1:', 'P2:', 'P3:', 'R2:', 'TESTRESULT', 'pre154']) assert.ok(t.includes(s), s);
  assert.match(rd(PRE), /'pre154'/);
  assert.doesNotMatch(rd(PRE), /email_outbox/);
  assert.match(rd('booking/supabase/tests/discounts/t146_annual_card_email.sql'), /booking_154 muutti tämän/);
});

test('sähköposti: hallinnan kortti (source admin) → oma johdanto ja ohje ilman ostoa; ostettu kortti ennallaan', { skip: tsSkip }, () => {
  const row = (locale, source) => ({ kind: 'annual_card_code', locale, to_name: 'Aada Testi', annual_card: { code: 'K7QX9MZ3TA', valid_from: '2026-10-24', valid_to: '2027-10-23', active: true, revoked: false, source, booking_url: 'https://uusi.saunotus.com/varaa/' } });
  const ET = TPL.EMAIL_TEXTS;
  for (const l of ['fi', 'en']) {
    const g = TPL.render('annual_card_code', row(l, 'admin'), l), p = TPL.render('annual_card_code', row(l, 'purchase'), l), old = TPL.render('annual_card_code', row(l, undefined), l);
    assert.ok(g.text.includes(ET['email.annual_card_granted.intro'][l]) && g.text.includes(ET['email.annual_card_granted.how_3'][l]), `${l}: hallinnan kortin johdanto`);
    assert.ok(!g.text.includes(ET['email.annual_card.intro'][l]) && !g.text.includes(ET['email.annual_card.how_3'][l]));
    assert.doesNotMatch(g.text + g.html, l === 'fi' ? /ostosta|ostossa/ : /buying|bought/);
    assert.match(g.text, /K7QX9MZ3TA/);
    assert.deepEqual(p, old, `${l}: ostetun kortin viesti ennallaan`);
    assert.ok(p.text.includes(ET['email.annual_card.intro'][l]));
    assert.equal(g.subject, p.subject);
  }
});

test('tekstit: pending-import-54 FI+EN, ei < eikä emojeja, email-rivit = texts.ts, UI-rivit = sanakirja, ei päällekkäin', () => {
  const rows = JSON.parse(rd(P54));
  const keys = [...new Set(rows.map((r) => r.key))];
  assert.equal(rows.length, keys.length * 2);
  const ui = keys.filter((k) => k.startsWith('ui.'));
  assert.deepEqual(keys.filter((k) => k.startsWith('email.')).sort(), ['email.annual_card_granted.how_3', 'email.annual_card_granted.intro']);
  assert.ok(ui.every((k) => k.startsWith('ui.admin.annual_manage.')));
  const p52 = new Set(JSON.parse(rd('content/site-texts.pending-import-52.json')).map((r) => r.key));
  assert.deepEqual(ui.sort(), Object.keys(ANNUAL_MANAGE_TEXTS.fi).filter((k) => !p52.has(k)).sort());
  const ts = rd('booking/supabase/functions/send-emails/texts.ts');
  for (const r of rows) {
    const w = `${r.key} [${r.lang}]`;
    assert.ok(['fi', 'en'].includes(r.lang), w);
    if (r.key.startsWith('ui.')) assert.equal(r.text, ANNUAL_MANAGE_TEXTS[r.lang][r.key], w);
    else assert.ok(ts.includes(`${r.lang}: ${JSON.stringify(r.text)}`), w);
    assert.equal(r.kind, 'plain', w); assert.ok(r.max_len >= r.text.length, w);
    assert.deepEqual(r.placeholders, [...new Set([...r.text.matchAll(/\{\{[^{}]+\}\}/g)].map((m) => m[0]))], w);
    assert.doesNotMatch(r.text, /[<>]|https?:\/\/|www\./, w);
    assert.doesNotMatch(r.text, /\p{Extended_Pictographic}/u, w);
    if (r.lang === 'en') assert.doesNotMatch(r.text, /\b(Kiitos|Hei|Vuosikortti|koodi|asiakkaalle)\b/, w);
    assert.ok(r.reason, w);
  }
  assert.doesNotMatch(rd(P54), /</);
  for (const f of readdirSync(resolve(root, 'content')).filter((x) => /^site-texts\..*\.json$/.test(x) && x !== 'site-texts.pending-import-54.json')) {
    const raw = rd(`content/${f}`); for (const k of keys) assert.ok(!raw.includes(`"${k}"`), `${k} myös tiedostossa ${f}`);
  }
});

test('käyttöliittymä: Myönnä-dialogin "Lähetä koodi asiakkaalle" oletuksena päällä, p_send_email, ilmoitus sähköpostin tilasta', () => {
  const disc = rd('booking/admin/views/discounts.js'), cust = rd('booking/admin/views/customers.js');
  assert.match(disc, /h\('input', \{ type: 'checkbox', name: 'send_email', checked: true, 'data-testid': 'annual-send-email' \}\)/);
  assert.match(disc, /amText\('ui\.admin\.annual_manage\.send_email'\)/);
  assert.match(disc, /p_send_email: send\.checked \}\);\n\s*toast\(amCreatedMessage\(r\)\);/);
  assert.match(cust, /h\('input', \{ type: 'checkbox', name: 'vsend', checked: true \}\)/);
  assert.match(cust, /p_send_email: grant\.vsend\.checked \}\); toast\(amCreatedMessage\(created\)\);/);
  for (const s of [disc, cust]) { assert.doesNotMatch(s, /#[0-9a-f]{3,6}\b.*send_email/i); assert.doesNotMatch(s, /\p{Extended_Pictographic}/u); }
  clearAmTextCache();
  assert.equal(amCreatedMessage({ code: 'ABC123', email: { status: 'pending' } }), 'Vuosikortti myönnetty. Koodi: ABC123. Koodi lähetetään asiakkaan sähköpostiin.');
  assert.match(amCreatedMessage({ code: 'ABC123', email: { status: 'no_email' } }), /ei ole sähköpostiosoitetta/);
  assert.match(amCreatedMessage({ code: 'ABC123', email: { status: 'not_requested' } }), /ei lähetetty asiakkaalle/);
  assert.match(amCreatedMessage({ code: 'ABC123', email: { status: 'skipped' } }), /pois päältä/);
  assert.equal(amCreatedMessage({ code: 'ABC123' }), 'Vuosikortti myönnetty. Koodi: ABC123');
});

test('mock: p_send_email true → pending, false → not_requested, ilman → vastaus ennallaan; oikeus annual_cards.manage', async () => {
  const m = createAdminMock();
  const base = { p_valid_from: '2026-11-01', p_valid_to: '2027-10-31', p_code: null, p_notes: null };
  assert.equal((await m.rpc('admin_create_annual_card', { ...base, p_customer_id: 1, p_send_email: true })).email.status, 'pending');
  assert.equal((await m.rpc('admin_create_annual_card', { ...base, p_customer_id: 3, p_send_email: false })).email.status, 'not_requested');
  const old = await m.rpc('admin_create_annual_card', { ...base, p_customer_id: 4 });
  assert.ok(old.ok && old.code && !('email' in old));
  await assert.rejects(createAdminMock({ role: 'staff' }).rpc('admin_create_annual_card', { ...base, p_customer_id: 1, p_send_email: true }), /annual_cards\.manage/);
});

test('CI: pages.yml ajaa tämän testin', () => {
  assert.match(rd('.github/workflows/pages.yml'), /- run: node --test booking\/tests\/vuosikortti-admin-email\.test\.mjs/);
});
