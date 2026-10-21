// Hallinnan päivänäkymä: lahjakortilla tehty varaus (Johku "… - Lahjakorttivaraus") listataan tavallisen vuoron alle.
// Puhdas logiikka (day-logic.js), ei verkkoa eikä tietokantaa. Data on keksittyä; muoto kuten tuotannon admin_day_view / admin_list_reservations.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { assignDayCards, clockIso, isGiftCardReservation, cleanProductName, dayGroupKey, slotTitle, sumPersons } from '../admin/day-logic.js';
import { DAY_TEXTS, dayText, clearDayTextCache } from '../admin/day-texts.js';

const read = (rel) => readFileSync(new URL(rel, import.meta.url), 'utf8');
const GIFT = 'Yleinen vuoro - Lahjakorttivaraus';
const PLAIN = 'Yleinen vuoro (to, la-su)';
const res = (over) => ({ status: 'confirmed', persons: 2, source: 'johku', product_id: 1, product_name: PLAIN, ...over });
const ids = (list) => list.map((r) => r.reservation_id);

test('tunnistus ja nimen siivous', () => {
  assert.equal(isGiftCardReservation({ product_name: GIFT }), true);
  assert.equal(isGiftCardReservation({ product_name: 'Yleinen sauna (la-su) - Lahjakorttivaraus' }), true);
  assert.equal(isGiftCardReservation({ product_name: 'Yleinen vuoro – lahjakorttivaraus ' }), true);
  assert.equal(isGiftCardReservation({ product_name: PLAIN }), false);
  assert.equal(isGiftCardReservation({ product_name: 'Avoin lahjakortti' }), false, 'lahjakortin osto ei ole varaus');
  assert.equal(isGiftCardReservation(null), false);
  assert.equal(cleanProductName(GIFT), 'Yleinen vuoro');
  assert.equal(cleanProductName(PLAIN), PLAIN);
});

test('normalisoitu avain: päivä + alku + loppu + tuote, aikaleiman muoto ei vaikuta', () => {
  const day = '2026-10-29';
  const a = { starts_at: clockIso(day, 17, 0), ends_at: clockIso(day, 17, 30), product_id: 1 };
  const b = { starts_at: a.starts_at.replace('.000Z', '+00:00'), ends_at: a.ends_at.replace('Z', '+00:00'), product_id: '1' };
  assert.equal(dayGroupKey(a), dayGroupKey(b));
  assert.notEqual(dayGroupKey(a), dayGroupKey({ ...a, ends_at: clockIso(day, 19, 0) }), 'eri loppu = eri ryhmä');
  assert.notEqual(dayGroupKey(a), dayGroupKey({ ...a, product_id: 3 }), 'eri tuote = eri ryhmä');
  assert.match(dayGroupKey(a), /^2026-10-29\|/);
});

test('sama tuote ja aika: lahjakorttivaraus menee tavallisen vuoron alle, henkilömäärä sisältää sen, Johku säilyy', () => {
  const day = '2026-10-29';   // to: Yleinen vuoro 17–19 (rule 5)
  const session = { rule_id: 5, product_id: 1, label: 'Yleinen vuoro to 17–19', mode: 'shared', status: 'available', remaining: 9, max_persons: 16,
    starts_at: clockIso(day, 17, 0), ends_at: clockIso(day, 19, 0) };
  const end30 = clockIso(day, 17, 30);
  const reservations = [
    res({ reservation_id: 10296, persons: 2, starts_at: session.starts_at, ends_at: end30 }),
    res({ reservation_id: 10298, persons: 3, starts_at: session.starts_at.replace('.000Z', '+00:00'), ends_at: end30 }),
    res({ reservation_id: 10299, persons: 2, starts_at: session.starts_at, ends_at: end30, product_name: GIFT }),
    res({ reservation_id: 10781, persons: 2, starts_at: session.starts_at, ends_at: session.ends_at, status: 'cancelled', rule_id: 5 }),
  ];
  const plan = assignDayCards({ sessions: [session], reservations, events: [], date: day });
  assert.equal(plan.sessions.length, 1);
  assert.deepEqual(ids(plan.sessions[0].reservations), [10296, 10298, 10299]);
  assert.equal(plan.slots.length, 0, 'ei omaa "Lahjakorttivaraus"-ryhmää');
  assert.equal(sumPersons(plan.sessions[0].reservations), 7, 'varatut sisältävät lahjakorttivarauksen, peruttu ei');
  assert.equal(plan.sessions[0].session.remaining, 9, 'Vapaana tulee palvelimelta sellaisenaan (ei vähennetä uudelleen)');
  const gift = plan.sessions[0].reservations.find((r) => r.reservation_id === 10299);
  assert.equal(gift.source, 'johku', 'Johku-lähde säilyy (Johku-merkki)');
  assert.equal(isGiftCardReservation(gift), true, 'Lahjakortti-merkki');
});

test('la–su sama tuote ja koko vuoro: yksi kortti', () => {
  const day = '2026-10-24';
  const s = { rule_id: 6, product_id: 1, mode: 'shared', status: 'available', remaining: 2, starts_at: clockIso(day, 17, 0), ends_at: clockIso(day, 19, 0) };
  const other = { rule_id: 12, product_id: 6, mode: 'shared', status: 'available', remaining: 10, starts_at: s.starts_at, ends_at: clockIso(day, 18, 0) };
  const plan = assignDayCards({ sessions: [s, other], events: [], date: day, reservations: [
    res({ reservation_id: 1, persons: 2, starts_at: s.starts_at, ends_at: s.ends_at }),
    res({ reservation_id: 2, persons: 2, starts_at: s.starts_at, ends_at: s.ends_at, product_name: GIFT }),
  ] });
  const card = plan.sessions.find((c) => c.session.rule_id === 6);
  assert.deepEqual(ids(card.reservations), [1, 2]);
  assert.equal(plan.sessions.find((c) => c.session.rule_id === 12).reservations.length, 0, 'ei mene toisen tuotteen vuoroon, kun oma vuoro on');
  assert.equal(plan.slots.length, 0);
});

test('ei saman tuotteen vuoroa (esim. ti): lahjakorttivaraus samaan aikaan alkavan tavallisen yhteisvuoron alle', () => {
  const day = '2026-11-03';   // ti: Naisten sauna 16–19 (tuote 3); Johku-tuonti kirjasi lahjakorttivarauksen tuotteelle 1, sama kapasiteettipooli
  const s = { rule_id: 2, product_id: 3, label: 'Naisten sauna ti 16–19', mode: 'shared', status: 'available', remaining: 4, max_persons: 16,
    starts_at: clockIso(day, 16, 0), ends_at: clockIso(day, 19, 0) };
  const priv = { rule_id: 99, product_id: 25, mode: 'exclusive', status: 'available', starts_at: s.starts_at, ends_at: clockIso(day, 18, 0) };
  const plan = assignDayCards({ sessions: [priv, s], events: [], date: day, reservations: [
    res({ reservation_id: 10315, product_id: 3, product_name: 'Naisten sauna (ti)', persons: 10, starts_at: s.starts_at, ends_at: s.ends_at }),
    res({ reservation_id: 10316, persons: 2, starts_at: s.starts_at, ends_at: clockIso(day, 16, 30), product_name: GIFT }),
    res({ reservation_id: 10317, product_id: 23, product_name: 'Perinnesaunotus yhdelle', persons: 1, starts_at: clockIso(day, 16, 15), ends_at: clockIso(day, 17, 45) }),
  ] });
  const card = plan.sessions.find((c) => c.session.rule_id === 2);
  assert.deepEqual(ids(card.reservations), [10315, 10316]);
  assert.equal(sumPersons(card.reservations), 12);
  assert.equal(plan.sessions.some((c) => c.session.rule_id === 99 && c.reservations.length), false, 'ei yksityisvuoroon');
  assert.deepEqual(plan.slots.map(ids), [[10317]], 'muut varaukset ennallaan');
  // Tavallinen (ei lahjakortti) toisen tuotteen varaus ei siirry vieraaseen vuoroon.
  const plain = assignDayCards({ sessions: [s], events: [], date: day, reservations: [res({ reservation_id: 5, starts_at: s.starts_at, ends_at: clockIso(day, 16, 30) })] });
  assert.equal(plain.sessions[0].reservations.length, 0);
  assert.equal(plain.slots.length, 1);
});

test('ei vastaavaa vuoroa: oma ryhmä tuotteen oikealla nimellä, sama ryhmä kuin saman ajan tavallinen varaus', () => {
  const day = '2026-12-17';
  const start = clockIso(day, 17, 0);
  const end = clockIso(day, 17, 30);
  const gift = res({ reservation_id: 10368, starts_at: start, ends_at: end, product_name: GIFT });
  const plain = res({ reservation_id: 10369, persons: 3, starts_at: start.replace('.000Z', '+00:00'), ends_at: end });
  const only = assignDayCards({ sessions: [], events: [], date: day, reservations: [gift] });
  assert.equal(only.slots.length, 1);
  assert.equal(slotTitle(only.slots[0], PLAIN), PLAIN, 'kb-tuotteen nimi');
  assert.equal(slotTitle(only.slots[0]), 'Yleinen vuoro', 'ilman kb-nimeä: liite poistettu');
  assert.doesNotMatch(slotTitle(only.slots[0]), /lahjakortti/i);
  const both = assignDayCards({ sessions: [], events: [], date: day, reservations: [gift, plain] });
  assert.equal(both.slots.length, 1, 'yksi ryhmä, ei erillistä lahjakorttiryhmää');
  assert.deepEqual(ids(both.slots[0]), [10369, 10368], 'tavallinen ensin');
  assert.equal(slotTitle(both.slots[0]), PLAIN);
  assert.equal(sumPersons(both.slots[0]), 5);
});

test('ei tuplalaskentaa eikä negatiivista: sama varaus kahdesti, perutut pois, kortti kerran', () => {
  const day = '2026-10-29';
  const s = { rule_id: 5, product_id: 1, mode: 'shared', status: 'full', remaining: 0, starts_at: clockIso(day, 17, 0), ends_at: clockIso(day, 19, 0) };
  const g = res({ reservation_id: 7, starts_at: s.starts_at, ends_at: clockIso(day, 17, 30), product_name: GIFT });
  const plan = assignDayCards({ sessions: [s], events: [], date: day, reservations: [g, { ...g }, res({ reservation_id: 8, status: 'cancelled', starts_at: s.starts_at, ends_at: s.ends_at, product_name: GIFT })] });
  assert.deepEqual(ids(plan.sessions[0].reservations), [7]);
  assert.equal(plan.slots.length, 0);
  assert.equal(sumPersons(plan.sessions[0].reservations), 2);
  assert.equal(sumPersons([{ persons: -3 }, { persons: null }, { persons: '2' }]), 2);
  const parts = read('../admin/views/dayparts.js');
  assert.match(parts, /Vapaana: \$\{s\.remaining == null \? '' : Math\.max\(0, Number\(s\.remaining\) \|\| 0\)\}/, 'Vapaana-luku ei ole koskaan negatiivinen');
  assert.match(parts, /newBookingHref\(date, s\)/, 'Vapaana-nappi avaa uuden varauksen kuten ennen');
});

test('näkymä: Lahjakortti-merkki tekstitaulusta, Johku-merkki ennallaan, otsikko ilman liitettä', () => {
  const ui = read('../admin/views/day.js');
  assert.match(ui, /sourceBadge\(src\), giftBadge\(r, x\)/, 'Johku-merkki ja sen jälkeen Lahjakortti-merkki');
  assert.match(ui, /dayText\('ui\.admin\.day\.gift_card_badge'\)/);
  assert.match(ui, /slotTitle\(list, refs\.productById\.get\(r0\.product_id\)\?\.name\)/);
  assert.doesNotMatch(ui, /r0\.product_name \|\|/, 'otsikko ei käytä raakaa tilausrivin nimeä');
  assert.doesNotMatch(ui, /Lahjakortti'/, 'ei kovakoodattua tekstiä näkymässä');
  const ui2 = read('../admin/ui.js');
  assert.match(ui2, /class: 'badge src-johku'.*text: 'Johku'/);
});

test('teksti: ui.admin.day.gift_card_badge FI+EN, pending-import-32, ei päällekkäistä avainta', () => {
  clearDayTextCache();
  assert.equal(DAY_TEXTS.fi['ui.admin.day.gift_card_badge'], 'Lahjakortti');
  assert.equal(DAY_TEXTS.en['ui.admin.day.gift_card_badge'], 'Gift card');
  assert.equal(dayText('ui.admin.day.gift_card_badge', null, 'fi'), 'Lahjakortti');
  const rows = JSON.parse(read('../../content/site-texts.pending-import-32.json'));
  assert.deepEqual(rows.map((r) => `${r.key}|${r.lang}`).sort(), ['ui.admin.day.gift_card_badge|en', 'ui.admin.day.gift_card_badge|fi']);
  for (const r of rows) {
    assert.equal(r.text, DAY_TEXTS[r.lang][r.key]);
    assert.equal(r.class, 'normal');
    assert.equal(r.kind, 'plain');
    assert.deepEqual(r.placeholders, []);
    assert.ok(r.max_len >= r.text.length);
    assert.doesNotMatch(r.text, /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u, 'ei emojeja');
  }
  const dir = new URL('../../content/', import.meta.url);
  for (const f of readdirSync(dir)) {
    if (!/^site-texts\.(pending-import|imported)/.test(f) || f === 'site-texts.pending-import-32.json' || !f.endsWith('.json')) continue;
    for (const r of JSON.parse(readFileSync(new URL(f, dir), 'utf8'))) assert.notEqual(r.key, 'ui.admin.day.gift_card_badge', f);
  }
});

test('tyyli: monokromi merkki, kontrasti ≥ 4,5:1', () => {
  const css = read('../admin/calendar.css');
  const m = css.match(/\.badge\.gift\{background:(#[0-9A-Fa-f]{6});color:(#[0-9A-Fa-f]{6})/);
  assert.ok(m, '.badge.gift');
  const lum = (hex) => {
    const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((x) => (x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4));
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  };
  const [hi, lo] = [lum(m[1]), lum(m[2])].sort((a, b) => b - a);
  assert.ok((hi + 0.05) / (lo + 0.05) >= 4.5);
  assert.equal(m[2].toUpperCase(), '#7A5530', 'kulta');
});
