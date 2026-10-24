// Paketti 04 / booking_140: päivän työvuororajaus, seuraava oma vuoro, varauksen muistiinpano,
// päivän muistiinpanot ja ajastetut henkilöstötiedotteet. Tekstit ui.admin.day_memos.* (pending-import-41).
// SQL-käyttäytyminen: booking/supabase/tests/day/t140_day_notes_bulletins.sql (paikallinen PG17).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const MIG = 'booking/supabase/migrations/20261024084144_booking_140_day_notes_bulletins.sql';
const RB = 'booking/supabase/rollbacks/20261024084144_booking_140_ROLLBACK.sql';
const migration = read(MIG);
const rollback = read(RB);
const { firstSentence } = await import(pathToFileURL(join(root, 'booking/admin/day-memos-logic.js')).href);
const texts = await import(pathToFileURL(join(root, 'booking/admin/day-memos-texts.js')).href);
const { DAY_MEMO_TEXTS, PREFIX, memoText, primeMemoTexts, clearMemoTextCache, loadMemoTexts } = texts;

// day-memos.js ilman DOM-riippuvuutta: importit korvataan pienillä tynkillä, oikea toteutus testataan.
const rpcCalls = [];
globalThis.__day140Calls = rpcCalls;
globalThis.confirm = () => true;
const mockUi = `
const rpc = async (name, args) => { globalThis.__day140Calls.push({ name, args }); return { ok: true }; };
const h = (tag, props = {}, ...children) => ({ tag, props, children: children.flat(Infinity).filter((x) => x != null), hidden: !!props.hidden,
  value: props.value, attributes: {}, setAttribute(k, v) { this.attributes[k] = v; }, classList: { toggle() {} } });
const field = (label, input) => h('label', { text: label }, input);
const dialog = (title, body) => ({ title, body, close() {} });
const toast = () => {};
const run = async (_node, fn) => fn();
const fmtDT = (iso) => String(iso);
const fmtDate = (iso) => String(iso).slice(8, 10) + '.' + String(iso).slice(5, 7) + '.';
const icon = (name) => ({ tag: 'svg', props: { 'data-icon': name }, children: [] });
const t = (key, vars) => (globalThis.__memoText)(key, vars, 'fi');
`;
globalThis.__memoText = memoText;
const rawView = read('booking/admin/views/day-memos.js');
const rawNoImports = rawView.replace(/^import [^\n]+;\r?\n/gm, '');
const viewMod = await import(`data:text/javascript;base64,${Buffer.from(mockUi + `const firstSentence = ${firstSentence.toString()};\n` + rawNoImports).toString('base64')}`);
const fnBody = (s, name) => { const i = s.indexOf(`create or replace function booking.${name}(`); assert.ok(i >= 0, name); const m = /\nend \$[a-z]*\$;/.exec(s.slice(i)); return s.slice(i, i + m.index + m[0].length); };
const walk = (node, pred) => (!node || typeof node !== 'object') ? [] : [...(pred(node) ? [node] : []), ...(node.children || []).flatMap((c) => walk(c, pred))];
const byTestId = (node, key) => walk(node, (x) => x.props?.['data-testid'] === key);
const allText = (node) => walk(node, (x) => typeof x.props?.text === 'string').map((x) => x.props.text).concat(walk(node, () => true).flatMap((x) => x.children.filter((c) => typeof c === 'string'))).join(' | ');

test('numerointi: vain booking_140 + pending-import-41, ei 139:ää eikä pending-import-40:tä tästä paketista', () => {
  const migs = readdirSync(join(root, 'booking/supabase/migrations'));
  assert.deepEqual(migs.filter((f) => f.includes('booking_140')), ['20261024084144_booking_140_day_notes_bulletins.sql']);
  assert.deepEqual(readdirSync(join(root, 'booking/supabase/rollbacks')).filter((f) => f.includes('booking_140')), ['20261024084144_booking_140_ROLLBACK.sql']);
  for (const f of migs.filter((x) => x.includes('booking_139'))) assert.doesNotMatch(read(`booking/supabase/migrations/${f}`), /day_notes|staff_bulletins/);
  assert.doesNotMatch(migration, /booking_128/);
});

test('firstSentence: yksi lause, monta lausetta, rivinvaihto ja pituus', () => {
  assert.equal(firstSentence('Yksi lause.'), 'Yksi lause.');
  assert.equal(firstSentence('Ensimmäinen lause. Toinen lause.'), 'Ensimmäinen lause.');
  assert.equal(firstSentence('Tärkeää! Jatkoa'), 'Tärkeää!');
  assert.equal(firstSentence('Ensimmäinen rivi\nToinen rivi'), 'Ensimmäinen rivi');
  assert.ok(firstSentence('a'.repeat(140)).length <= 120);
  assert.equal(firstSentence('  '), '');
});

test('tiedote: suppea esikatselu, bulletin-toggle avaa ja sulkee (aria-expanded)', () => {
  const card = viewMod.bulletinCard({ date: '2026-10-24', can: () => false,
    bulletins: [{ id: 1, active: true, start_date: '2026-10-23', end_date: '2026-10-25', body: 'Ensimmäinen lause.\nToinen lause.' }] });
  assert.equal(byTestId(card, 'day-bulletins').length, 1);
  const [toggle] = byTestId(card, 'bulletin-toggle');
  assert.equal(toggle.props.text, 'Ensimmäinen lause.');
  assert.equal(toggle.props['aria-expanded'], 'false');
  const [full] = walk(card, (n) => n.props?.class === 'bulletin-full');
  assert.equal(full.hidden, true);
  toggle.props.onclick(); assert.equal(full.hidden, false); assert.equal(toggle.attributes['aria-expanded'], 'true');
  toggle.props.onclick(); assert.equal(full.hidden, true); assert.equal(toggle.attributes['aria-expanded'], 'false');
  assert.equal(byTestId(card, 'bulletin-add').length + byTestId(card, 'bulletin-edit').length + byTestId(card, 'bulletin-delete').length, 0, 'ei hallintaa perustyöntekijälle');
  assert.equal(walk(card, (n) => n.props?.class?.includes('bulletin-period')).length, 0);
});

test('tiedote: päivärajat, ei-aktiivinen piiloon, manager (shifts.view_all) saa lisätä, muokata ja poistaa', async () => {
  const b = { id: 7, active: true, start_date: '2026-10-23', end_date: '2026-10-25', body: 'Ohje.' };
  assert.equal(viewMod.bulletinCard({ date: '2026-10-26', bulletins: [b] }), null);
  assert.equal(viewMod.bulletinCard({ date: '2026-10-24', bulletins: [{ ...b, active: false }] }), null);
  const mgr = viewMod.bulletinCard({ date: '2026-10-24', bulletins: [b], can: (p) => p === 'shifts.view_all' });
  for (const id of ['bulletin-add', 'bulletin-edit', 'bulletin-delete']) assert.equal(byTestId(mgr, id).length, 1, id);
  assert.match(allText(mgr), /Voimassa 23\.10\.–25\.10\./);
  const empty = viewMod.bulletinCard({ date: '2026-10-24', bulletins: [], can: (p) => p === 'shifts.view_all' });
  assert.match(allText(empty), /Ei voimassa olevia tiedotteita\./);
  byTestId(mgr, 'bulletin-delete')[0].props.onclick();
  await new Promise((r) => setImmediate(r));
  assert.deepEqual(rpcCalls.at(-1), { name: 'admin_delete_bulletin', args: { p_id: 7 } });
});

test('päivän muistiinpanot: renderöinti, tallennus oikealle päivälle, poisto vain shifts.view_all', async () => {
  const notes = [{ id: 3, body: 'Lämmitys tehty', author_name: null, created_at: '2026-10-24T06:00:00Z' }];
  const card = viewMod.dayNotesCard({ date: '2026-10-24', dayNotes: notes });
  assert.equal(byTestId(card, 'day-notes').length, 1);
  assert.equal(byTestId(card, 'day-note').length, 1);
  assert.match(allText(card), /Lämmitys tehty/);
  assert.match(allText(card), /Henkilöstö · 2026-10-24T06:00:00Z/);
  assert.equal(byTestId(card, 'day-note-delete').length, 0);
  const textarea = walk(card, (n) => n.tag === 'textarea')[0];
  assert.equal(textarea.props.maxlength, 2000);
  const form = walk(card, (n) => n.tag === 'form')[0];
  textarea.value = '  Puita täydennettävä ';
  await form.props.onsubmit({ preventDefault() {} });
  assert.deepEqual(rpcCalls.at(-1), { name: 'admin_save_day_note', args: { p_date: '2026-10-24', p_body: 'Puita täydennettävä', p_id: null } });
  const mgr = viewMod.dayNotesCard({ date: '2026-10-24', dayNotes: notes, can: (p) => p === 'shifts.view_all' });
  assert.equal(byTestId(mgr, 'day-note-delete').length, 1);
  assert.equal(viewMod.dayNotesCard({ date: '2026-10-24', dayNotes: [] }).children.some((c) => c.props?.text === 'Ei muistiinpanoja tälle päivälle.'), true);
});

test('loadDayMemos: nipun notes_bundle käytetään sellaisenaan', async () => {
  const pre = { day_notes: [{ id: 1 }], bulletins: [] };
  assert.equal(await viewMod.loadDayMemos('2026-10-24', pre), pre);
  const n = rpcCalls.length;
  await viewMod.loadDayMemos('2026-10-24', null);
  assert.deepEqual(rpcCalls.at(-1), { name: 'admin_list_day_notes', args: { p_date: '2026-10-24' } });
  assert.equal(rpcCalls.length, n + 1);
});

test('tekstit: ui.admin.day_memos.* FI+EN, pending-import-41 täsmää, ei päällekkäin, ei < eikä emojeja', () => {
  const rows = JSON.parse(read('content/site-texts.pending-import-41.json'));
  assert.deepEqual(Object.keys(DAY_MEMO_TEXTS.fi).sort(), Object.keys(DAY_MEMO_TEXTS.en).sort());
  assert.equal(Object.keys(DAY_MEMO_TEXTS.fi).length, 34);
  assert.equal(rows.length, 68);
  const seen = new Set();
  for (const r of rows) {
    assert.ok(r.key.startsWith(PREFIX), r.key);
    assert.equal(r.text, DAY_MEMO_TEXTS[r.lang][r.key], r.key);
    assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain');
    assert.ok(r.max_len >= r.text.length && r.max_len >= 80, r.key);
    assert.deepEqual(r.placeholders, [...r.text.matchAll(/\{\{var:[a-z0-9_]+\}\}/g)].map((m) => m[0]), r.key);
    assert.doesNotMatch(r.text, /[<>]/, r.key);
    assert.doesNotMatch(r.text, /\p{Extended_Pictographic}/u, r.key);
    assert.match(r.reason, /booking_140/);
    assert.equal(seen.has(`${r.key}|${r.lang}`), false); seen.add(`${r.key}|${r.lang}`);
  }
  const taken = new Set();
  for (const f of readdirSync(join(root, 'content'))) {
    if (!/^site-texts\.(pending-import-(?!41\.)|imported|fallback)/.test(f) || !f.endsWith('.json')) continue;
    const j = JSON.parse(read(`content/${f}`));
    for (const r of Array.isArray(j) ? j : j.texts || []) taken.add(`${r.key}|${r.lang}`);
  }
  for (const r of rows) assert.equal(taken.has(`${r.key}|${r.lang}`), false, `${r.key} on jo toisessa tuonnissa`);
});

test('tekstit: kannan rivi peittää oletuksen, puuttuva paikkamerkki → oletus, rpc-virhe ei kaada', async () => {
  primeMemoTexts([{ key: 'ui.admin.day_memos.notes_title', lang: 'fi', text: 'Muistiinpanot (kanta)' },
    { key: 'ui.admin.day_memos.bulletin_period', lang: 'fi', text: 'Voimassa {{var:x}}' },
    { key: 'ui.admin.nav.orders', lang: 'fi', text: 'ei kuulu tähän' }]);
  assert.equal(memoText('ui.admin.day_memos.notes_title', null, 'fi'), 'Muistiinpanot (kanta)');
  assert.equal(memoText('ui.admin.day_memos.bulletin_period', { start: '1.1.', end: '2.1.' }, 'fi'), 'Voimassa 1.1.–2.1.');
  clearMemoTextCache();
  assert.equal(memoText('ui.admin.day_memos.notes_title', null, 'en'), 'Notes for the day');
  assert.equal(await loadMemoTexts(async () => { throw new Error('verkko'); }), false);
  assert.equal(memoText('ui.admin.day_memos.note_add', null, 'fi'), DAY_MEMO_TEXTS.fi['ui.admin.day_memos.note_add']);
  clearMemoTextCache();
});

test('näkymät eivät kovakoodaa uusia lauseita, kytkennät day.js/shared.js/dayparts.js', () => {
  const view = read('booking/admin/views/day-memos.js');
  assert.doesNotMatch(view, /text: '[A-ZÄÖ][^']*'/, 'day-memos.js käyttää t()-avaimia');
  const day = read('booking/admin/views/day.js'), shared = read('booking/admin/views/shared.js'), parts = read('booking/admin/views/dayparts.js');
  assert.match(day, /bulletinCard\(/); assert.match(day, /dayNotesCard\(/);
  assert.match(day, /loadDayMemos\(date, bundle\?\.notes_bundle \|\| null\)/);
  assert.match(day, /'data-testid': 'next-own-shift'/);
  assert.match(day, /admin_next_own_shift_date', \{ p_from_date: todayHel\(\) \}/);
  assert.match(day, /'data-testid': 'res-note'/);
  assert.match(shared, /can\('bookings\.manage'\) \?/);
  assert.match(shared, /admin_set_reservation_note', \{ p_reservation_id: r\.reservation_id, p_notes: notes\.value \}/);
  assert.match(shared, /maxlength: 1000/);
  assert.match(parts, /memoText\('ui\.admin\.day_memos\.shifts_none'\)/);
  assert.match(read('scripts/build-pages.mjs'), /'day-memos-texts\.js', 'day-memos-logic\.js', 'views\/day-memos\.js'/);
  const mock = read('booking/admin/options-mock.js');
  for (const fn of ['admin_list_day_notes', 'admin_save_day_note', 'admin_delete_day_note', 'admin_save_bulletin', 'admin_delete_bulletin', 'admin_next_own_shift_date', 'admin_set_reservation_note']) assert.ok(mock.includes(fn), fn);
});

test('ulkoasu: vain teeman muuttujat, ei sinistä, ei emojeja, SVG-ikonit', () => {
  const css = read('booking/admin/admin.css');
  const block = css.slice(css.indexOf('/* Päivän muistiinpanot ja henkilöstötiedotteet (paketti 04')).replace(/\/\*[\s\S]*?\*\//g, '');
  assert.ok(block.length > 100);
  assert.doesNotMatch(block, /#[0-9a-f]{3,8}\b|rgb\(|hsl\(|blue/i);
  for (const f of ['booking/admin/views/day-memos.js', 'booking/admin/day-memos-texts.js']) assert.doesNotMatch(read(f), /\p{Extended_Pictographic}/u, f);
  assert.match(read('booking/admin/views/day-memos.js'), /icon\('chev', 18\)/);
  assert.match(read('booking/admin/views/day-memos.js'), /icon\('trash', 18\)/);
});

test('SQL booking_140: rajaus, oikeudet, taulut, RLS, audit, uudelleenajettavuus', () => {
  assert.match(migration, /if not booking\.has_permission\('shifts\.view_all'\) then/);
  assert.match(migration, /a\.status in \('assigned', 'confirmed'\)/);
  assert.match(migration, /admin_next_own_shift_date\(p_from_date date default null\)/);
  assert.match(migration, /coalesce\(p_from_date, \(now\(\) at time zone 'Europe\/Helsinki'\)::date\)/);
  assert.match(migration, /booking\.admin_set_reservation_note\(p_reservation_id bigint, p_notes text\)/);
  assert.match(migration, /_require_permission\('bookings\.manage'\)/);
  assert.doesNotMatch(migration, /settings\.manage/);
  assert.match(migration, /create table if not exists booking\.day_notes/);
  assert.match(migration, /create table if not exists booking\.staff_bulletins/);
  assert.match(migration, /references auth\.users\(id\) on delete set null/);
  for (const t of ['day_notes', 'staff_bulletins']) {
    assert.match(migration, new RegExp(`alter table booking\\.${t} enable row level security`));
    assert.match(migration, new RegExp(`revoke all on booking\\.${t} from public, anon, authenticated`));
    assert.match(migration, new RegExp(`booking\\._add_audit\\('booking\\.${t}'`));
  }
  assert.doesNotMatch(migration, /^\s*(insert into|update|delete from|alter table|create table|drop table)\s+public\./im, 'public-skeemaan ei kirjoiteta');
});

test('SQL booking_140: admin_day_bundle = booking_133 + notes_bundle, 9 argumentin admin_list_reservations', () => {
  const m133 = read('booking/supabase/migrations/' + readdirSync(join(root, 'booking/supabase/migrations')).find((f) => f.includes('booking_133_')));
  const body = (s) => fnBody(s, 'admin_day_bundle');
  const b133 = body(m133), b140 = body(migration);
  assert.ok(b133.length > 500 && b140.length > 500);
  const call = b133.match(/booking\.admin_list_reservations\([^;]*?\)\)/s)?.[0] || b133.match(/booking\.admin_list_reservations\([^)]*\)/)[0];
  assert.ok(b140.includes(call), '9 argumentin kutsu ennallaan');
  for (const k of [...b133.matchAll(/'([a-z_]+)',\s/g)].map((m) => m[1])) assert.ok(b140.includes(`'${k}',`), k);
  assert.match(b140, /'notes_bundle', booking\.admin_list_day_notes\(p_date\)/);
  assert.equal(b140.replace(/,?\s*'notes_bundle', booking\.admin_list_day_notes\(p_date\)/, '').replace(/\s+/g, ' ').length <= b133.replace(/\s+/g, ' ').length + 40, true);
});

test('rollback: palauttaa booking_133:n admin_day_bundlen ja booking_27:n admin_day_shiftsin sanatarkasti, poistaa uudet', () => {
  const migs = readdirSync(join(root, 'booking/supabase/migrations'));
  const m133 = read('booking/supabase/migrations/' + migs.find((f) => f.includes('booking_133_')));
  const fn = fnBody;
  assert.ok(rollback.includes(fn(m133, 'admin_day_bundle')), '133:n admin_day_bundle sanatarkasti');
  const m27 = read('booking/supabase/migrations/' + migs.find((f) => f.includes('booking_27_')));
  assert.ok(rollback.includes(fn(m27, 'admin_day_shifts')), '27:n admin_day_shifts sanatarkasti');
  for (const f of ['admin_next_own_shift_date(date)', 'admin_set_reservation_note(bigint, text)', 'admin_list_day_notes(date)', 'admin_save_day_note(date, text, bigint)', 'admin_delete_day_note(bigint)', 'admin_delete_bulletin(bigint)'])
    assert.ok(rollback.includes(`drop function if exists booking.${f}`), f);
  assert.match(rollback, /drop function if exists booking\.admin_save_bulletin\(/);
  assert.match(rollback, /drop table if exists booking\.day_notes/);
  assert.match(rollback, /drop table if exists booking\.staff_bulletins/);
  assert.ok(rollback.indexOf('admin_day_bundle') < rollback.indexOf('drop function if exists booking.admin_list_day_notes'), 'nippu palautetaan ennen kuin sen käyttämä funktio poistetaan');
  assert.match(read('booking/supabase/tests/day/t140_day_notes_bulletins.sql'), /TESTRESULT pass=% fail=%/);
});
