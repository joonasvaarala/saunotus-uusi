// Paketti "Saunarituaali ja savusaunavuoro (la & su)" (kb 7, migraatio booking_58, sopimus KOODARI_talous_A_D_fi.md §17.11) kaupassa: katalogirivi → hoitopolku (slots, ruudukko 30 min),
// järjestys, ei hoitovalitsinta (ei p_option_code), aikajana + loppuaika (alku + 2 h), saatavuus (tuotannon lukufunktioiden oikeat vastaukset fixturena), mock (la/su, 16:00/16:30/17:00,
// yhteinen rituaalipooli ja Rauni-puskuri), FI/EN-tekstit, "Ei vapaita aikoja". Ei verkkoa, ei tietokantaa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, cpSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { treatmentRpc, resetBookings, catalogEntries, PRODUCTS, IMAGES } from '../shop/src/treatment-mock.js';

const tmp = mkdtempSync(join(tmpdir(), 'saunarituaali-'));
cpSync(new URL('../shop/src/', import.meta.url), tmp, { recursive: true });
cpSync(new URL('../shared/sb.js', import.meta.url), join(tmp, 'sb.js'));
const A = await import(pathToFileURL(join(tmp, 'treatments.js')));
const SB = await import(pathToFileURL(join(tmp, 'sb.js')));
const { T } = await import(pathToFileURL(join(tmp, 'i18n.js')));
const FX = JSON.parse(readFileSync(new URL('./fixtures/prod-package-7.json', import.meta.url), 'utf8'));   // tuotannon public_catalog() / public_treatment_availability(7,…) (vain luku); katalogirivi ENNEN booking_61:tä (ei timeline-kenttiä)
const FX61 = JSON.parse(readFileSync(new URL('./fixtures/prod-catalog-61.json', import.meta.url), 'utf8'));   // tuotannon public_catalog() / public_addons() / public_settings() booking_61:n jälkeen (vain luku)
const P7 = () => A.splitCatalog(FX61.catalog, new Map()).treatments.find((x) => x.id === 7);   // tuote 7 kentin (timeline, timeline_text, voucher_note, description_en)
const row = (id) => FX.catalog.find((r) => r.id === id);
const norm = (s) => String(s).replace(/\s+/g, ' ').trim();
const STATIC = new Map([[7, { id: 7, slug: 'saunarituaali-ja-savusaunavuoro', name: 'x', duration_text: 'rituaali 20 min + savusauna 1 h 40 min (verkkokauppa)', description: 'kb-kuvaus' }]]);   // vanhentunut kb-snapshot

test('katalogirivi tuotannosta → hoitotuote: slots, 49 €/hlö, 1–6 hlö, kesto 120, ei valitsinta', () => {
  const { rules, treatments } = A.splitCatalog(FX.catalog, STATIC);
  assert.deepEqual(rules.map((r) => r.id), [1], 'vuoropohjainen tuote jää rules-listaan');
  const p = treatments.find((x) => x.id === 7);
  assert.ok(p, 'tuote 7 on hoitotuote (booking_kind slots)');
  assert.equal(p.slug, 'saunarituaali-ja-savusaunavuoro'); assert.equal(p.price, 49); assert.equal(p.price_type, 'per_person');
  assert.equal(A.minPersons(p), 1); assert.equal(A.maxPersons(p), 6); assert.equal(p.duration_minutes, 120);
  assert.equal(p.name, 'Saunarituaali ja savusaunavuoro (la & su)'); assert.equal(p.name_en, 'Sauna Ritual & Smoke Sauna Session');
  assert.equal(p.category, 'ritual');
  assert.deepEqual(p.options, []); assert.equal(p.option_required, false, 'ei hoitovalitsinta');
  assert.match(p.duration_text, /yhteensä 2 h/, 'katalogin duration_text voittaa vanhentuneen kb-snapshotin (1 h 40 min)');
  assert.equal(p.description_en, undefined, 'description_en puuttuu tuotannosta (EN-teksti tulossa) → kauppa putoaa suomeen');
  assert.equal(A.priceFor(p, 3), 147); assert.equal(A.priceFor(p, 6), 294);
});
test('järjestys: paketti hoitojen ja rituaalin jälkeen; tuntematon uusi slots-tuote loppuun (ei alkuun)', () => {
  const rows = [...FX.catalog, { id: 99, slug: 'uusi', name: 'Uusi', booking_kind: 'slots', price: 1, price_type: 'per_person' }];
  const ids = A.splitCatalog(rows, new Map()).treatments.map((x) => x.id);
  assert.deepEqual(ids, [10, 8, 7, 99]);
  assert.equal(ids.at(-1), 99); assert.ok(ids.indexOf(7) > ids.indexOf(8));
  assert.deepEqual(A.KB_IDS, [10, 11, 12, 8, 7]);
});
test('piilotettu tuote (ei katalogissa) → ei hoitotuotetta (kauppa näyttää "ota yhteyttä")', () => {
  assert.deepEqual(A.splitCatalog(FX.catalog.filter((r) => r.id !== 7), STATIC).treatments.map((x) => x.id), [10, 8]);
});
test('RPC-argumentit: saatavuus (7, väli, henkilömäärä); varaus ILMAN p_option_code', () => {
  const p = { id: 7 };
  assert.deepEqual(A.args.availability(p, 2, '2026-10-25', '2026-11-01'), { p_product_id: 7, p_from: '2026-10-25', p_to: '2026-11-01', p_persons: 2 });
  const c = A.args.create(p, { start: '2026-10-25T14:00:00.000Z', persons: 3, name: 'A B', email: 'a@b.fi', phone: '+358401234567', marketing: false, locale: 'fi', note: '', kind: 'private', company: null, option: null });
  assert.equal(c.p_product_id, 7); assert.equal(c.p_persons, 3); assert.equal(c.p_start, '2026-10-25T14:00:00.000Z');
  assert.ok(!('p_option_code' in c), 'p_option_code ei lähde paketille (ei hoitovalitsinta)');
  assert.ok(!('p_option_code' in A.args.create(p, { start: 's', persons: 1, option: undefined })));
  assert.equal(A.RPC.availability, 'public_treatment_availability'); assert.equal(A.RPC.create, 'public_create_treatment_booking');
});

// ---- saatavuus: tuotannon oikeat vastaukset ----
async function avail(rows, persons = 1, from = '2026-10-18', to = '2026-11-01', p = { id: 7, duration_minutes: 120 }) {
  const calls = [];
  SB.setRpcOverride(async (name, args) => { calls.push({ name, args }); return typeof rows === 'function' ? rows(args) : rows; });
  A.clearCache();
  try { return { by: await A.loadAvailability(p, persons, from, to), calls }; } finally { SB.setRpcOverride(null); }
}
test('loadAvailability: tuotannon vastaus → päivittäiset alkuajat, loppuaika = alku + 2 h, hinta/hlö', async () => {
  const { by, calls } = await avail(FX.availability_1);
  assert.equal(calls.length, 1, 'väli 18.10.–1.11. = 14 pv → yksi haku'); assert.equal(calls[0].name, 'public_treatment_availability');
  assert.deepEqual([...by.keys()], ['2026-10-18', '2026-10-25']);
  const d1 = by.get('2026-10-18'), d2 = by.get('2026-10-25');
  assert.deepEqual(d1.map((s) => s.time), ['16:00', '16:30']); assert.deepEqual(d2.map((s) => s.time), ['16:00', '16:30', '17:00'], 'EET-päivä (25.10. kellot siirtyvät): UTC 14:00 = 16:00');
  for (const s of [...d1, ...d2]) { assert.equal(new Date(s.end) - new Date(s.start), 120 * 60e3, `${s.start}: loppu = alku + 2 h`); assert.equal(s.total, 49); }
  assert.equal(by.get('2026-10-25')[2].end, '2026-10-25T17:00:00+00:00', 'palvelimen ends_at sellaisenaan');
  const { by: b6 } = await avail(FX.availability_6, 6);
  assert.equal(b6.get('2026-10-25')[0].total, 294, '6 hlö = 294 €');
});
test('loppuaika puuttuu palvelimelta → alku + kesto (120 min); ei kestoa → null', async () => {
  const rows = [{ starts_at: '2026-10-25T14:00:00+00:00', session_date: '2026-10-25', status: 'available', total: 49 }];
  const { by } = await avail(rows);
  assert.equal(by.get('2026-10-25')[0].end, '2026-10-25T16:00:00.000Z');
  const { by: b2 } = await avail(rows, 1, '2026-10-18', '2026-11-01', { id: 7 });
  assert.equal(b2.get('2026-10-25')[0].end, null);
});
test('ei vapaita aikoja: tyhjä vastaus → tyhjä kartta; ei-vapaat rivit suodatetaan; yli 14 pv pilkotaan', async () => {
  assert.equal((await avail([])).by.size, 0);
  assert.equal((await avail([{ starts_at: '2026-10-25T14:00:00+00:00', status: 'full' }])).by.size, 0);
  const { calls } = await avail([], 1, '2026-10-18', '2026-11-20');
  assert.ok(calls.length >= 3 && calls.every((c) => (new Date(c.args.p_to) - new Date(c.args.p_from)) / 864e5 <= 14), `kutsut ≤ 14 pv: ${calls.map((c) => `${c.args.p_from}..${c.args.p_to}`)}`);
});
test('saatavuusvirhe (busy / bad_range) heitetään ApiErrorina; ei hiljaa tyhjää', async () => {
  SB.setRpcOverride(async () => { throw new SB.ApiError('x', { status: 400, code: 'BK001', details: { code: 'bad_range' } }); });
  A.clearCache();
  await assert.rejects(() => A.loadAvailability({ id: 7 }, 1, '2026-10-18', '2026-10-19'));
  SB.setRpcOverride(null);
});

// ---- aikajana (booking_61: public_catalog().timeline / timeline_text; ei kovakoodattua PACKAGE_TIMELINES) ----
test('aikajana kannasta: rituaali 20 (alku 0) · savusauna 90 (alku 30) = 120 min, sisäinen tauko ei asiakkaalle; vain tuote jolla kenttä on', () => {
  const p = P7();
  assert.deepEqual(A.timelineOf(p).map((x) => [x.key, x.start, x.min]), [['ritual', 0, 20], ['smoke_sauna', 30, 90]]);
  assert.ok(!A.timelineOf(p).some((x) => x.key === 'break'), 'taukoa ei ole asiakkaalle näkyvänä jaksona');
  assert.deepEqual(A.timelineOf(p).map((x) => [x.label, x.label_en]), [['rituaali', 'ritual'], ['savusauna', 'smoke sauna']], 'jaksojen nimet kannasta (FI + EN)');
  assert.equal(A.timelineOf(p).reduce((a, x) => a + x.min, 0), 110, 'näkyvät jaksot 20 + 90 (väli 10 min on sisäinen)');
  assert.equal(A.timelineMinutes(p), 120); assert.equal(A.isPackage(p), true);
  assert.equal(A.PACKAGE_TIMELINES, undefined, 'kovakoodattu PACKAGE_TIMELINES poistettu');
  for (const id of [8, 10, 11, 12]) { const q = { id }; assert.equal(A.isPackage(q), false); assert.equal(A.timelineOf(q), null); assert.deepEqual(A.timelineSlots(q, '2026-10-25T14:00:00Z'), []); }
  assert.equal(A.isPackage({ id: 7 }), false, 'id yksin ei riitä: aikajana tulee vain kentästä');
});
test('varakäyttäytyminen: kenttiä ei ole (vanha kanta) / virheellinen aikajana → tavallinen aikavaraustuote, ei aikajanaa eikä virhettä', () => {
  const old = A.splitCatalog(FX.catalog, STATIC).treatments.find((x) => x.id === 7);   // katalogirivi ennen booking_61:tä
  assert.equal(A.timelineOf(old), null); assert.equal(A.isPackage(old), false); assert.equal(A.timelineText(old, 'fi'), ''); assert.deepEqual(A.timelineSlots(old, '2026-10-25T14:00:00Z'), []);
  assert.equal(old.voucher_note, undefined); assert.equal(old.timeline, undefined);
  const base = { id: 7, duration_minutes: 120, timeline: [{ seq: 1, kind: 'ritual', label: 'a', minutes: 20, start_min: 0, end_min: 20 }] };
  assert.equal(A.timelineOf(base), null, 'summa 20 ≠ kesto 120 → aikajanaa ei näytetä (§18.11)');
  assert.equal(A.timelineOf({ id: 7, timeline: [] }), null); assert.equal(A.timelineOf({ id: 7, timeline: 'x' }), null);
  assert.equal(A.timelineOf({ id: 7, timeline: [{ kind: 'ritual', minutes: 0, start_min: 0 }] }), null, 'virheellinen jakso');
  assert.equal(A.timelineOf({ id: 7, duration_minutes: 30, timeline: [{ seq: 1, kind: 'break', label: 'tauko', minutes: 30, start_min: 0, end_min: 30 }] }), null, 'vain sisäisiä jaksoja → ei näytettävää');
});
test('timelineSlots: kellonajat Helsingin ajassa (kesä- ja talviaika), jaksojen nimet kannasta', () => {
  const p = P7(), f = (iso) => A.timelineSlots(p, iso).map((x) => `${x.label} ${x.from}–${x.to}`);
  // savusauna alkaa alku + 30 min (kuten backend) ja päättyy alku + 2 h; rituaali päättyy alku + 20 min; väliä ei näytetä rivinä
  assert.deepEqual(f('2026-10-18T13:30:00Z'), ['rituaali 16:30–16:50', 'savusauna 17:00–18:30'], 'EEST (UTC+3)');
  assert.deepEqual(f('2026-10-25T14:00:00Z'), ['rituaali 16:00–16:20', 'savusauna 16:30–18:00'], 'EET (UTC+2)');
  assert.deepEqual(f('2026-10-25T15:00:00Z'), ['rituaali 17:00–17:20', 'savusauna 17:30–19:00']);
  assert.deepEqual(A.timelineSlots(p, null), []);
  assert.equal(A.timelineSlots(p, '2026-10-25T14:00:00Z').at(-1).to, '18:00', 'viimeinen jakso päättyy alku + 2 h');
  assert.equal(A.timelineLabel(A.timelineOf(p)[1], 'en'), 'smoke sauna'); assert.equal(A.timelineLabel(A.timelineOf(p)[1], 'fi'), 'savusauna');
  assert.equal(A.timelineLabel({ label: 'x', label_en: '' }, 'en'), 'x', 'EN-nimi puuttuu → fi');
});
test('timelineText: kannan timeline_text(_en) ilman sisäistä taukoa; puuttuessa jaksojen labelit + kestot; NBSP jakson sisällä', () => {
  const p = P7(), nb = (x) => x.replace(/\u00a0/g, ' ');
  assert.equal(nb(A.timelineText(p, 'fi')), 'rituaali 20 min · savusauna 1 h 30 min');
  assert.equal(nb(A.timelineText(p, 'en')), 'ritual 20 min · smoke sauna 1 h 30 min');
  assert.ok(!/tauko|break/i.test(A.timelineText(p, 'fi') + A.timelineText(p, 'en')), 'ei taukoa');
  assert.match(A.timelineText(p, 'fi'), /savusauna\u00a01\u00a0h\u00a030\u00a0min/, 'jakso ei katkea rivinvaihtoon');
  const noText = { ...p, timeline_text: undefined, timeline_text_en: undefined };
  assert.equal(nb(A.timelineText(noText, 'fi')), 'rituaali 20 min · savusauna 1 h 30 min', 'timeline_text puuttuu → johdetaan jaksoista');
  assert.equal(nb(A.timelineText(noText, 'en')), 'ritual 20 min · smoke sauna 1 h 30 min');
  assert.equal(nb(A.timelineText({ ...p, timeline_text_en: undefined }, 'en')), 'ritual 20 min · smoke sauna 1 h 30 min', 'EN-teksti puuttuu → EN-labelit (ei suomea)');
  assert.equal(A.timelineText({ id: 10 }, 'fi'), '');
});

// ---- tekstit ----
test('FI/EN-tekstit: ei kovakoodattuja jaksojen nimiä (kannasta), "Ei vapaita aikoja" / "No available times", pariteetti', () => {
  const ui = readFileSync(new URL('../shop/src/treatment-ui.js', import.meta.url), 'utf8');
  assert.match(ui, /A\.timelineLabel\(x, S\.lang\)/); assert.ok(!/tr\.tl\[/.test(ui), 'jaksojen nimiä ei haeta i18n:stä');
  assert.equal(T.fi.tr.tl, undefined); assert.equal(T.en.tr.tl, undefined);
  assert.equal(T.fi.tr.noTimes, 'Ei vapaita aikoja'); assert.equal(T.en.tr.noTimes, 'No available times');
  for (const k of ['tlTitle', 'noTimesHint', 'tlDuration', 'ends']) { assert.ok(T.fi.tr[k] && T.en.tr[k] && T.fi.tr[k] !== T.en.tr[k], `tr.${k} FI ≠ EN`); }
});
test('käyttöliittymä: ei kovakoodattuja tuote-id:itä paketille (aikajana tulee kannan kentistä), ei option-polkua, tyhjät mount-lapset ohitetaan', () => {
  const ui = readFileSync(new URL('../shop/src/treatment-ui.js', import.meta.url), 'utf8'), shop = readFileSync(new URL('../shop/src/shop.js', import.meta.url), 'utf8');
  assert.ok(!/p\.id\s*===\s*7|id\s*===\s*7\b/.test(ui + shop), 'ei id === 7 -ehtoja UI:ssa');
  assert.match(shop, /nodes\.flat\(\)\.filter\(\(n\) => n != null && n !== false\)/, 'mount ei kirjoita "null"-tekstiä');
  assert.match(ui, /A\.isPackage\(p\)/);
  assert.ok(existsSync(new URL('../scripts/e2e-saunarituaali.mjs', import.meta.url)));
});

// ---- mock (kaupan ?mock=1 ja kehityspalvelin) ----
const NOW = Date.parse('2026-11-02T08:00:00Z');   // ma 2.11.2026 10:00 Helsinki (talviaika, UTC+2); päivät su 15.11. ja la 7.11. ovat mockissa täysin vapaita
const ISO = (ds, hm) => { const [H, M] = hm.split(':').map(Number); const off = 2; /* marraskuu = talviaika */ return new Date(Date.UTC(+ds.slice(0, 4), +ds.slice(5, 7) - 1, +ds.slice(8, 10), H - off, M)).toISOString(); };
const av = (id, n, from, to) => treatmentRpc('public_treatment_availability', { p_product_id: id, p_from: from, p_to: to, p_persons: n }, NOW).body;
const hhmm = (rows) => rows.map((r) => `${r.session_date} ${new Date(r.starts_at).toLocaleTimeString('en-GB', { timeZone: 'Europe/Helsinki', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })}`);
const mk = (id, ds, hm, n, email = 'a@b.fi', extra = {}) => treatmentRpc('public_create_treatment_booking', { p_product_id: id, p_start: ISO(ds, hm), p_persons: n, p_name: 'Testi Asiakas', p_email: email, p_phone: '+358401234567', p_customer_kind: 'private', ...extra }, NOW).body;
// päivät, joilla mockin deterministiset sulut/varaukset eivät häiritse: la ja su, joilla paketilla on kaikki 3 alkuaikaa (erilliset päivät)
const clean = (() => { const o = {}; for (let i = 1; i <= 14; i++) { const ds = new Date(Date.UTC(2026, 10, 2 + i, 12)).toISOString().slice(0, 10), dw = new Date(`${ds}T12:00:00Z`).getUTCDay(); if (av(7, 1, ds, ds).length === 3) { if (dw === 6) o.sa ||= ds; if (dw === 0) o.su ||= ds; } } return o.sa && o.su ? o : null; })();

test('mock: katalogirivi vastaa tuotantoa (slots, 49 €/hlö, 1–6, 120 min, ei valitsinta, ei kuvaa)', () => {
  const e = catalogEntries().find((x) => x.id === 7);
  assert.equal(e.slug, 'saunarituaali-ja-savusaunavuoro'); assert.equal(e.booking_kind, 'slots'); assert.equal(e.slot_grid_minutes, 30);
  assert.equal(e.price, 49); assert.equal(e.price_type, 'per_person'); assert.equal(e.min_persons, 1); assert.equal(e.max_persons, 6); assert.equal(e.duration_minutes, 120);
  assert.deepEqual(e.options, []); assert.equal(e.option_required, false); assert.equal(e.category, 'ritual'); assert.equal(e.name_en, 'Sauna Ritual & Smoke Sauna Session');
  assert.equal(e.duration_text, row(7).duration_text);
  assert.equal(IMAGES.some(([id]) => id === 7), false, 'mockissa ei kuvaa → "ei kuvaa" -tila testattavissa');
  assert.deepEqual(Object.keys(row(7)).filter((k) => !(k in e) && !['description', 'description_en', 'price_text'].includes(k)), [], 'mock sisältää kaikki tuotannon katalogikentät (paitsi kuvaukset: ne tulevat kb-snapshotista)');
});
test('mock: saatavuus vain la/su, alkuajat 16:00/16:30/17:00, loppu = alku + 2 h, 7 hlö → ei aikoja', () => {
  assert.ok(clean, 'testipäiviä löytyi');
  const fri = '2026-11-06', wk = av(7, 1, '2026-11-02', '2026-11-16');
  for (const r of wk) { const dow = new Date(`${r.session_date}T12:00:00Z`).getUTCDay(); assert.ok([0, 6].includes(dow), `${r.session_date} ei la/su`); assert.equal(new Date(r.ends_at) - new Date(r.starts_at), 120 * 60e3); assert.equal(r.duration_minutes, 120); assert.equal(r.total, 49); }
  assert.deepEqual(hhmm(av(7, 1, clean.sa, clean.sa)).map((x) => x.slice(-5)), ['16:00', '16:30', '17:00']);
  assert.equal(av(7, 1, fri, fri).length, 0, 'perjantai: ei aikoja');
  assert.equal(av(7, 7, clean.sa, clean.sa).length, 0, '7 hlö: ei aikoja'); assert.equal(av(7, 6, clean.sa, clean.sa)[0].total, 294);
  assert.equal(av(7, 0, clean.sa, clean.sa).length, 0);
});
test('mock: varaus ilman p_option_code onnistuu (98 €, 16:00–18:00); p_option_code → invalid_option (palvelin ei tunne valintoja paketille)', () => {
  resetBookings();
  const r = mk(7, clean.sa, '16:00', 2);
  assert.equal(r.ok, true); assert.equal(r.total, 98); assert.equal(r.product_name, 'Saunarituaali ja savusaunavuoro (la & su)'); assert.equal(r.option, null);
  assert.equal(new Date(r.ends_at) - new Date(r.starts_at), 120 * 60e3);
  const g = treatmentRpc('public_get_booking', { p_token: r.token }, NOW).body;
  assert.equal(g.items[0].product_id, 7); assert.equal(g.items[0].option, null); assert.equal(g.items[0].option_label, null); assert.equal(g.booking_kind, 'slots');
  const bad = mk(7, clean.sa, '16:30', 1, 'b@b.fi', { p_option_code: 'hunajahoito' });
  assert.equal(bad.ok, false); assert.equal(bad.code, 'invalid_option');
});
test('mock: virhekoodit kuten muilla slot-tuotteilla (slot_unavailable, time_window, invalid_persons, invalid_name, ei-la/su-alkuaika)', () => {
  resetBookings();
  assert.equal(mk(7, clean.sa, '16:00', 1, 'taken@test.fi').code, 'slot_unavailable');
  assert.equal(mk(7, clean.sa, '16:00', 1, 'time_window@test.fi').code, 'time_window');
  assert.equal(mk(7, clean.sa, '16:00', 7).code, 'invalid_persons');
  assert.equal(mk(7, clean.sa, '18:00', 1).code, 'slot_unavailable', 'alkuaika ruudukon/rituaalin ulkopuolella');
  assert.equal(mk(7, clean.sa, '16:00', 1, 'a@b.fi', { p_name: ' ' }).code, 'invalid_name');
});
test('mock: yhteinen rituaalipooli (paketti + saunotusrituaali, yht. max 6 hlö samaan alkuun)', () => {
  resetBookings();
  assert.equal(mk(8, clean.su, '17:00', 4).ok, true);
  const at17 = (n) => hhmm(av(7, n, clean.su, clean.su)).some((x) => x.endsWith('17:00'));
  assert.equal(at17(2), true, '4 + 2 = 6 mahtuu'); assert.equal(at17(3), false, '4 + 3 > 6 ei mahdu');
  assert.equal(mk(7, clean.su, '17:00', 3).ok, false); assert.equal(mk(7, clean.su, '17:00', 2).ok, true);
  assert.equal(hhmm(av(8, 1, clean.su, clean.su)).some((x) => x.endsWith('17:00')), false, '17:00 täynnä myös rituaalille');
  assert.equal(hhmm(av(7, 1, clean.su, clean.su)).some((x) => x.endsWith('16:00')), true, 'muut alkuajat vapaana');
});
test('mock: Rauni-puskuri: Saunahoito 17:00–18:00 estää paketin 16:30 ja 17:00 (rituaali 16:30–16:50), 16:00 käy; hoidon peruminen ei tarvita', () => {
  resetBookings();
  assert.equal(mk(10, clean.sa, '17:00', 1, 'h@b.fi', { p_option_code: 'hunajahoito' }).ok, true);
  assert.deepEqual(hhmm(av(7, 2, clean.sa, clean.sa)).map((x) => x.slice(-5)), ['16:00']);
  assert.equal(mk(7, clean.sa, '16:30', 2).ok, false);
});
test('mock: kehityspalvelin/kauppa-mock listaa paketin; build kopioi tarvittavat tiedostot', () => {
  const b = readFileSync(new URL('../shop/build.mjs', import.meta.url), 'utf8');
  for (const f of ['treatments.js', 'treatment-ui.js', 'treatment-mock.js', 'i18n.js']) assert.ok(b.includes(`'${f}'`), `build kopioi ${f}`);
  assert.equal(PRODUCTS[7].max, 6); assert.equal(PRODUCTS[7].minutes, 120);
});
test('shop-mock: ?mock=1&fail=notimes → saatavuus tyhjä; muuten paketti tarjolla', async () => {
  const { createShopMock } = await import(pathToFileURL(join(tmp, 'shop-mock.js')));
  const m = createShopMock({ storage: null, now: () => NOW, fail: 'notimes' });
  assert.deepEqual(await m.rpc('public_treatment_availability', { p_product_id: 7, p_from: '2026-10-18', p_to: '2026-11-01', p_persons: 1 }), []);
  const ok = createShopMock({ storage: null, now: () => NOW });
  assert.ok((await ok.rpc('public_treatment_availability', { p_product_id: 7, p_from: '2026-11-02', p_to: '2026-11-16', p_persons: 1 })).length > 0);
  assert.ok((await ok.rpc('public_catalog')).some((r) => r.id === 7));
});
