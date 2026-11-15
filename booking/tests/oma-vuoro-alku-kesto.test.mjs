// Oman saunavuoron kaksivaiheinen valinta (alku → kesto): ryhmittely, näkymä (FI/EN), alkunapit aina näkyvissä, ei vapaita, varauslinkki, arkirivit. Ei verkkoa, ei kantaa, ei selainta (näennäis-DOM).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { groupSlotsByStart, startsWithFree, usesStartPicker, sharedIncluded, durationMinutes } from '../shop/src/slot-groups.js';
import { createSlotPicker } from '../shop/src/slot-start-ui.js';
import { T } from '../shop/src/i18n.js';
import { SLOT_START_TEXTS } from '../shop/src/slot-start-texts.js';
import { collectDefaults } from '../shop/src/text-registry.js';
import { fmtMinutes } from '../shop/src/site-texts-logic.js';
import { clockFromIso } from '../shop/src/clock.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const read = (rel) => readFileSync(join(root, rel), 'utf8');
const tmp = mkdtempSync(join(process.env.TMPDIR || tmpdir(), 'oma-vuoro-'));
cpSync(new URL('../shop/src/', import.meta.url), tmp, { recursive: true });
cpSync(new URL('../shared/sb.js', import.meta.url), join(tmp, 'sb.js'));
const { createShopMock } = await import(pathToFileURL(join(tmp, 'shop-mock.js')).href);

// ---- näennäis-DOM ----
class El {
  constructor(tag) { this.tag = tag; this.attrs = {}; this.kids = []; this.handlers = {}; }
  append(...c) { this.kids.push(...c.flat()); }
  replaceChildren(...c) { this.kids = c.flat().filter((x) => x != null); }
  focus() { El.focused = this; }
  setAttribute(k, v) { this.attrs[k] = v; }
  get text() { return this.kids.map((k) => (typeof k === 'string' ? k : k.text)).join(''); }
  all(f, acc = []) { for (const k of this.kids) if (k instanceof El) { if (f(k)) acc.push(k); k.all(f, acc); } return acc; }
  find(f) { return this.all(f)[0]; }
  click() { this.handlers.click(); }
}
const h = (tag, attrs, ...kids) => {
  const el = new El(tag);
  for (const [k, v] of Object.entries(attrs || {})) { if (v == null || v === false) continue; if (k === 'class') el.attrs.class = v; else if (k === 'text') el.kids.push(String(v)); else if (k.startsWith('on')) el.handlers[k.slice(2)] = v; else el.attrs[k] = v; }
  for (const c of kids.flat()) if (c != null && c !== false) el.kids.push(c);
  return el;
};

const money = (lang) => (n) => new Intl.NumberFormat(lang === 'fi' ? 'fi-FI' : 'en-FI', { style: 'currency', currency: 'EUR', minimumFractionDigits: 0 }).format(+n);
const price = { 1: 350, 2: 600, 3: 800, 4: 1000, 5: 1200, 6: 1400, 9: 1900 };
// la 9.1.2027 (Helsinki talviaika +2): 13.00 = 11:00Z
const slot = (hh, d, status = 'available', over = {}) => ({ rule_id: 25000 + hh * 100 + d, product_id: 25, mode: 'exclusive', session_date: '2027-01-09', starts_at: `2027-01-09T${String(hh - 2).padStart(2, '0')}:00:00Z`, ends_at: `2027-01-09T${String(hh - 2 + d).padStart(2, '0')}:00:00Z`,
  status, remaining: status === 'full' ? 0 : 20, price_mode: 'base_plus_extra', base_price: price[d], included_persons: 8, extra_person_price: 10, ...over });
const SAT = [...[1, 2, 3, 4, 5, 6, 9].map((d) => slot(13, d)), ...[1, 2, 3, 4, 5].map((d) => slot(14, d))];
const P = { id: 25, slug: 'oma-saunavuoro', category: 'private_sauna', sale_kind: 'private_shift' };

function picker(lang, rows, p = P, ds = '2027-01-09') {
  const t = T[lang];
  const legacy = [];
  const pk = createSlotPicker({ h, t, money: money(lang), hm: (iso) => clockFromIso(iso, lang), dur: fmtMinutes, href: (r, d) => `#/varaa/${r.rule_id}/${d}/${p.id}`,
    legacyItem: (r, d) => { legacy.push(r.rule_id); return h('li', { class: 'bk-slot full' }, h('a', { class: 'btn sm light bk-waitlist-link', href: `#/jono/${r.rule_id}/${d}/${p.id}` })); } });
  return { pk, t, box: pk.view(rows, ds, p), legacy };
}
const startBtns = (box) => box.all((e) => e.tag === 'button' && e.attrs['data-start']);
const links = (box) => box.all((e) => e.tag === 'a' && e.attrs.class?.includes('btn'));
const cards = (box) => box.all((e) => e.tag === 'li' && e.attrs.class?.startsWith('bk-slot '));

test('ryhmittely alun mukaan: kestot samalla alulla samaan ryhmään, järjestys alun ja keston mukaan', () => {
  const g = groupSlotsByStart([...SAT].reverse());
  assert.deepEqual(g.map((x) => x.slots.length), [7, 5]);
  assert.deepEqual(g[0].slots.map((s) => s.base_price), [350, 600, 800, 1000, 1200, 1400, 1900]);
  assert.equal(usesStartPicker(SAT, P), true);
});
test('osa täynnä: alku näkyy vain jos vähintään yksi vapaa kesto', () => {
  const rows = [slot(13, 1, 'full'), slot(13, 2, 'full'), slot(14, 1), slot(14, 2, 'full'), slot(15, 2, 'full')];
  const g = groupSlotsByStart(rows);
  assert.deepEqual(g.map((x) => x.hasFree), [false, true, false]);
  assert.deepEqual(startsWithFree(g).map((x) => x.free.length), [1]);
  const { box } = picker('fi', rows);
  assert.deepEqual(startBtns(box).map((b) => b.text), ['14.00']);
});
test('yksi kesto per alku → ei valitsinta (entinen lista); tapahtuma ja monipäiväinen eivät ryhmity', () => {
  const single = [slot(13, 2), slot(16, 2), slot(18, 3)];
  assert.equal(usesStartPicker(single, P), false);
  assert.equal(usesStartPicker(SAT, { ...P, category: 'event' }), false);
  const multi = [slot(13, 2, 'available', { ends_at: '2027-01-12T11:00:00Z' }), slot(13, 3, 'available', { ends_at: '2027-01-13T11:00:00Z' })];
  assert.equal(usesStartPicker(multi, P), false);
  assert.equal(usesStartPicker([], P), false);
});
const pressed = (box) => startBtns(box).map((b) => b.attrs['aria-pressed']);
const durTitle = (box) => box.find((e) => e.attrs['data-testid'] === 'slot-duration-title').text;
test('kaksivaiheinen näkymä FI: alkunapit ja ensimmäisen alun kestot heti yhdessä; sis. hlö -teksti kerran', () => {
  const { box } = picker('fi', SAT);
  assert.equal(box.find((e) => e.tag === 'h4').text, 'Valitse aloitusaika');
  assert.deepEqual(startBtns(box).map((b) => b.text), ['13.00', '14.00']);
  assert.deepEqual(pressed(box), ['true', 'false'], 'ensimmäinen vapaa alku esivalittu');
  assert.equal(durTitle(box), 'Valitse kesto – alkaa 13.00');
  assert.equal(cards(box).length, 7);
  const two = cards(box)[1];
  assert.equal(two.find((e) => e.attrs.class === 'bk-time').text, '2 h');
  assert.equal(two.find((e) => e.attrs.class === 'bk-sub').text, '13.00–15.00');
  assert.match(two.find((e) => e.attrs.class === 'bk-price').text.replace(/\s/g, ' '), /^600 €$/);
  const notes = box.all((e) => e.attrs['data-testid'] === 'slot-included');
  assert.equal(notes.length, 1);
  assert.equal(notes[0].text.replace(/\s/g, ' '), 'sis. 8 hlö, lisähenkilö +10 €');
  assert.equal(box.all((e) => e.attrs.class === 'bk-price' && /sis\./.test(e.text)).length, 0, 'ei riveillä');
  assert.equal(box.all((e) => e.attrs['data-testid'] === 'slot-change-start').length, 0, 'ei «Vaihda aloitusaika» -nappia');
  assert.equal(T.fi.slotChangeStart, undefined);
});
test('kaksivaiheinen näkymä EN', () => {
  const { box } = picker('en', SAT);
  assert.equal(box.find((e) => e.tag === 'h4').text, 'Choose a start time');
  assert.deepEqual(startBtns(box).map((b) => b.text), ['13:00', '14:00']);
  startBtns(box)[1].click();
  assert.equal(durTitle(box), 'Choose a duration – starts at 14:00');
  assert.equal(cards(box).length, 5);
  assert.equal(box.find((e) => e.attrs['data-testid'] === 'slot-included').text.replace(/\s/g, ' '), 'incl. 8 guests, extra guest +€10');
});
test('vain valitun alun vapaat kestot: täynnä-kesto ei näy', () => {
  const rows = [...SAT.filter((s) => s.rule_id !== 25000 + 13 * 100 + 5), slot(13, 5, 'full')];
  const { box } = picker('fi', rows);
  assert.equal(cards(box).length, 6);
  assert.equal(box.all((e) => e.attrs['data-rule'] === String(25000 + 13 * 100 + 5)).length, 0);
});
test('varauslinkki säilyy: /varaa/{rule_id}/{date}/{product_id}', () => {
  const { box } = picker('fi', SAT);
  const hrefs = links(box).map((a) => a.attrs.href);
  assert.equal(hrefs.length, 7);
  assert.equal(hrefs[1], `#/varaa/${25000 + 1300 + 2}/2027-01-09/25`);
  assert.equal(startBtns(box).length, 2, 'alkunapit näkyvät kestolistan kanssa');
});
test('alun vaihto yhdellä napautuksella: nappirivi pysyy (samat napit), korostus ja kestolista päivittyvät', () => {
  const { box } = picker('fi', SAT);
  const [b1, b2] = startBtns(box);
  b2.click();
  assert.deepEqual(startBtns(box), [b1, b2], 'samat nappielementit paikallaan');
  assert.deepEqual(pressed(box), ['false', 'true']);
  assert.equal(durTitle(box), 'Valitse kesto – alkaa 14.00');
  assert.equal(cards(box).length, 5);
  assert.equal(links(box)[0].attrs.href, `#/varaa/${25000 + 1400 + 1}/2027-01-09/25`);
  b1.click();
  assert.deepEqual(pressed(box), ['true', 'false']);
  assert.equal(cards(box).length, 7);
  assert.equal(b1.attrs['aria-controls'], box.find((e) => e.attrs['data-testid'] === 'slot-durations').attrs.id);
});
test('yksi vapaa alku: esivalittuna, napit + kestot näkyvät', () => {
  const rows = [slot(13, 1, 'full'), slot(13, 2, 'full'), slot(14, 1), slot(14, 2)];
  const { box } = picker('fi', rows);
  assert.deepEqual(startBtns(box).map((b) => b.text), ['14.00']);
  assert.deepEqual(pressed(box), ['true']);
  assert.equal(cards(box).length, 2);
});
// booking_319: arkisin alut 14.00 (2/5/7 h) ja 16.00 (3/5 h); ma–to-hinnat
const wk = (hh, d, p) => ({ ...slot(hh, d, 'available', { base_price: p, session_date: '2027-01-12' }), starts_at: `2027-01-12T${String(hh - 2).padStart(2, '0')}:00:00Z`, ends_at: `2027-01-12T${String(hh - 2 + d).padStart(2, '0')}:00:00Z` });
const WEEKDAY = [wk(14, 2, 250), wk(14, 5, 650), wk(14, 7, 820), wk(16, 3, 420), wk(16, 5, 600)];
test('arkirivit (ma–to): usesStartPicker tunnistaa usean keston alut, alkunapit 14.00 ja 16.00 näkyvät', () => {
  assert.equal(usesStartPicker(WEEKDAY, P), true);
  assert.deepEqual(groupSlotsByStart(WEEKDAY).map((g) => g.slots.length), [3, 2]);
  const { box } = picker('fi', WEEKDAY, P, '2027-01-12');
  assert.deepEqual(startBtns(box).map((b) => b.text), ['14.00', '16.00']);
  assert.deepEqual(cards(box).map((c) => c.find((e) => e.attrs.class === 'bk-time').text), ['2 h', '5 h', '7 h']);
  assert.deepEqual(cards(box).map((c) => c.find((e) => e.attrs.class === 'bk-price').text.replace(/\s/g, ' ').replace(/\s*\(.*/, '')), ['250 €', '650 €', '820 €']);
  startBtns(box)[1].click();
  assert.deepEqual(pressed(box), ['false', 'true']);
  assert.equal(startBtns(box).length, 2);
  assert.deepEqual(cards(box).map((c) => c.find((e) => e.attrs.class === 'bk-sub').text), ['16.00–19.00', '16.00–21.00']);
  assert.deepEqual(cards(box).map((c) => c.find((e) => e.attrs.class === 'bk-time').text), ['3 h', '5 h']);
  assert.equal(durTitle(box), 'Valitse kesto – alkaa 16.00');
});
test('päivän vaihto nollaa alkuvalinnan (esivalinta = ensimmäinen vapaa alku)', () => {
  const t = T.fi, pk = createSlotPicker({ h, t, money: money('fi'), hm: (i) => clockFromIso(i, 'fi'), dur: fmtMinutes, href: () => '#', legacyItem: () => null });
  let box = pk.view(SAT, '2027-01-09', P);
  startBtns(box)[1].click();
  box = pk.view(SAT, '2027-01-10', P);
  assert.deepEqual(pressed(box), ['true', 'false']);
  startBtns(box)[1].click();
  box = pk.view(SAT, '2027-01-10', P);   // sama päivä uudelleen: valinta säilyy
  assert.equal(durTitle(box), 'Valitse kesto – alkaa 14.00');
});
test('ei vapaita kestoja: lyhyt teksti, ei tyhjää alkulistaa; täynnä-vuorot jäävät jonolinkeiksi', () => {
  const rows = [slot(13, 1, 'full'), slot(13, 2, 'full')];
  const { box, legacy } = picker('fi', rows);
  assert.equal(startBtns(box).length, 0);
  assert.equal(box.find((e) => e.attrs['data-testid'] === 'slot-picker-none').text, 'Ei vapaita kestoja valitulle päivälle. Valitse toinen päivä.');
  assert.equal(legacy.length, 2);
  assert.equal(box.all((e) => e.tag === 'h4').length, 0);
});
test('sharedIncluded: yhteinen vain jos kaikilla sama; muuten rivikohtainen teksti', () => {
  assert.deepEqual(sharedIncluded(SAT.slice(0, 3)), { included: 8, extra: 10 });
  assert.equal(sharedIncluded([slot(13, 1), slot(13, 2, 'available', { extra_person_price: 15 })]), null);
  assert.equal(sharedIncluded([slot(13, 1, 'available', { price_mode: 'fixed' })]), null);
  const { box } = picker('fi', [slot(13, 1), slot(13, 2, 'available', { extra_person_price: 15 }), slot(14, 1)]);
  startBtns(box)[0].click();
  assert.equal(box.all((e) => e.attrs['data-testid'] === 'slot-included').length, 0);
  assert.match(box.all((e) => e.attrs.class === 'bk-price')[1].text.replace(/\s/g, ' '), /^600 € \(sis\. 8 hlö, lisähenkilö \+15 €\)$/);
});
test('tekstit: FI/EN samat avaimet, T sisältää ne, tuonti 177 vastaa rekisteriä', () => {
  assert.deepEqual(Object.keys(SLOT_START_TEXTS.fi).sort(), Object.keys(SLOT_START_TEXTS.en).sort());
  for (const lang of ['fi', 'en']) for (const [k, v] of Object.entries(SLOT_START_TEXTS[lang])) assert.equal(T[lang][k], v, k);
  const toVar = (s) => s.replace(/\{(\w+)\}/g, '{{var:$1}}');
  const reg = collectDefaults().filter((r) => r.key.startsWith('ui.shop.slot_'));
  assert.equal(reg.length, Object.keys(SLOT_START_TEXTS.fi).length * 2);
  assert.equal(reg.length, 8);
  const pend = JSON.parse(read('content/site-texts.pending-import-177.json'));
  assert.equal(pend.length, reg.length);
  const by = new Map(pend.map((r) => [`${r.key}|${r.lang}`, r]));
  for (const r of reg) { assert.equal(by.get(`${r.key}|${r.lang}`)?.text, toVar(r.text), r.key); assert.ok(!/\p{Extended_Pictographic}/u.test(r.text)); }
  for (const r of pend) assert.deepEqual(r.placeholders, r.text.match(/\{\{var:\w+\}\}/g) || [], r.key);
});
test('mock: tuotteet 25 ja 48 – la 13.00 kestot 1–6 + 9 h, 14.00 kestot 1–5 h; arki useita kestoja; hinnat ja sis. hlö riveiltä', async () => {
  const NOW = Date.parse('2026-11-15T10:00:00Z');
  const had = Object.getOwnPropertyDescriptor(globalThis, 'location');
  Object.defineProperty(globalThis, 'location', { value: { search: '?mock=1&priv=1' }, configurable: true, writable: true });
  try {
    const mock = createShopMock({ storage: null, now: () => NOW });
    for (const id of [25, 48]) {
      const sat = await mock.rpc('public_availability', { p_product_id: id, p_from: '2027-01-09', p_to: '2027-01-09' });
      const g = groupSlotsByStart(sat);
      assert.deepEqual(g.map((x) => x.slots.length), [7, 5]);
      assert.deepEqual(g.map((x) => clockFromIso(x.start, 'fi')), ['13.00', '14.00']);
      assert.ok(sat.every((r) => r.included_persons === 8 && r.extra_person_price === 10 && r.price_mode === 'base_plus_extra'));
      assert.equal(new Set(sat.map((r) => r.rule_id)).size, sat.length, 'rule_id yksilöi keston');
      const wk = await mock.rpc('public_availability', { p_product_id: id, p_from: '2027-01-12', p_to: '2027-01-12' });
      assert.ok(groupSlotsByStart(wk).length < g.length + 1 && groupSlotsByStart(wk).every((x) => x.slots.length >= 2));
      assert.equal(usesStartPicker(wk, P), true);
      assert.deepEqual(groupSlotsByStart(wk).map((x) => x.slots.map((r) => durationMinutes(r) / 60)), [[2, 5, 7], [3, 5]], 'ti 12.1.: alut 14.00 ja 16.00');
      assert.deepEqual(groupSlotsByStart(wk).map((x) => clockFromIso(x.start, 'fi')), ['14.00', '16.00']);
    }
    for (const [date, exp] of [['2027-01-12', [[250, 650, 820], [420, 600]]], ['2027-01-15', [[300, 720, 900], [420, 650]]]]) {
      const rows = await mock.rpc('public_availability', { p_product_id: 25, p_from: date, p_to: date });
      assert.deepEqual(groupSlotsByStart(rows).map((x) => x.slots.map((r) => r.base_price)), exp, date);
    }
    {
    }
    const all = await mock.rpc('public_availability_all', { p_from: '2027-01-09', p_to: '2027-01-09', p_audience: 'business' });
    assert.equal(all.filter((r) => r.product_id === 48).length, 12);
  } finally { if (had) Object.defineProperty(globalThis, 'location', had); else delete globalThis.location; }
});
test('shop.js: tuotesivu ja päivänäkymän tuotekortti käyttävät valitsinta vain usesStartPicker-ehdolla; yksikestoinen jää slotItemiin; muutto ennallaan', () => {
  const shop = read('booking/shop/src/shop.js');
  assert.match(shop, /usesStartPicker\(rows, p\) \? slotPicker\.view\(rows, sel, p\) : h\('ul', \{ class: 'bk-slotlist' \}, rows\.map\(\(r\) => slotItem\(r, sel, p\)\)\)/);
  assert.match(shop, /!treat && usesStartPicker\(rs, p\)/);
  assert.match(shop, /href: \(r, ds\) => bk\(`\/varaa\/\$\{r\.rule_id\}\/\$\{ds\}\/\$\{p\.id\}\$\{via\}`\)/);
  assert.match(shop, /bk\(`\/varaa\/\$\{r\.rule_id\}\/\$\{ds\}\/\$\{p\.id\}`\) \}, t\.choose/);
});

// Katselmointikorjaukset (Koodari, PR #394)
test('usesStartPicker: sama alku samalla kestolla (kaksi eri sääntöä) ei käynnistä valitsinta; eri kestot käynnistävät', () => {
  const P = { id: 25, category: 'private_sauna' };
  assert.equal(usesStartPicker([slot(13, 2), slot(13, 2, 'available', { rule_id: 99 })], P), false);
  assert.equal(usesStartPicker([slot(13, 2), slot(13, 3)], P), true);
});
test('alkunapit: role=group on div-säiliössä (ei ul+li), napit suoraan ryhmässä; hiljaisen ajan hinta-attribuutti saa tiedon yhteisestä sis. hlö -tekstistä', () => {
  const t = T.fi, seen = [];
  const pk = createSlotPicker({ h, t, money: money('fi'), hm: (i) => clockFromIso(i, 'fi'), dur: fmtMinutes, href: () => '#', legacyItem: () => null, priceAttrs: (r, shared) => { seen.push(shared); return {}; } });
  const box = pk.view(SAT, '2027-01-09', { id: 25 });
  const grp = box.find((e) => e.attrs['data-testid'] === 'slot-starts');
  assert.equal(grp.tag, 'div');
  assert.equal(grp.attrs.role, 'group');
  assert.ok(grp.kids.every((k) => k.tag === 'button'));
  assert.ok(seen.length > 0 && seen.every((x) => x === true));
  const shop = read('booking/shop/src/shop.js');
  assert.match(shop, /priceAttrs: \(r, shared\) => qAttrs\(true, p, r, shared \? 'dur' : 'slot'\)/);
  assert.match(shop, /m === 'fixed' \|\| kind === 'dur' \? money\(q\.now\)/);
});
