// booking_158 (käyttöliittymä): hallinnan Tapahtumat-näkymä, tuotteen/tapahtuman kopio, kaupan suljettu tapahtumasivu ja tekstit.
// Ei verkkoa eikä tietokantaa: puhdas logiikka (events-logic.js, event-sale.js), mock (events-mock.js) ja keinotekoinen DOM XSS-tarkistukseen.
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, mkdtempSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import test from 'node:test';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const read = (rel) => readFileSync(join(repo, rel), 'utf8');
const L = await import(pathToFileURL(join(root, 'admin/events-logic.js')).href);
const { createEventsMock, EVENT_MOCK_RESOURCES } = await import(pathToFileURL(join(root, 'admin/events-mock.js')).href);
const S = await import(pathToFileURL(join(root, 'shop/src/event-sale.js')).href);
const P57 = 'content/site-texts.pending-import-57.json';
const XSS = '<img src=x onerror="alert(1)">';

// ---------- kerrat: yksitellen tai monivalinta ----------
test('buildSeries: päivät × alkuajat, oletusnimi, FI-päivämuoto, rajat ja virheet', () => {
  const r = L.buildSeries({ dates: '14.11.2026, 2026-11-21', times: '16:00 18.30', duration_minutes: 180, max_persons: 10 });
  assert.equal(r.ok, true);
  assert.equal(r.patches.length, 4);
  assert.deepEqual(r.patches.map((p) => `${p.date} ${p.start_time}`), ['2026-11-14 16:00', '2026-11-14 18:30', '2026-11-21 16:00', '2026-11-21 18:30']);
  assert.equal(r.patches[0].duration_minutes, 180);
  assert.equal(r.patches[0].max_persons, 10);
  assert.equal(L.defaultLabel('2026-11-14', '16:00', 'fi'), '14.11.2026 klo 16.00');
  assert.equal(L.buildSeries({ dates: '31.2.2026', times: '16:00', duration_minutes: 60 }).error, 'bad_date');
  assert.equal(L.buildSeries({ dates: '2026-11-14', times: '25:00', duration_minutes: 60 }).error, 'bad_time');
  assert.equal(L.buildSeries({ dates: '', times: '16:00', duration_minutes: 60 }).error, 'no_dates');
  assert.equal(L.buildSeries({ dates: '2026-11-14', times: '16:00', duration_minutes: 60, max_persons: 2, min_persons: 5 }).error, 'min_over_max');
  const many = Array.from({ length: 61 }, (_, i) => L.addDays('2026-11-01', i)).join(',');
  assert.equal(L.buildSeries({ dates: many, times: '16:00', duration_minutes: 60 }).error, 'too_many');
});

// ---------- resurssivaraukset: suhteellinen / kellonaika + validointi ----------
test('resurssivaraukset: suhteellinen ja kellonaika → RPC-muoto, validointi ja varoitus kerran ulkopuolelta', () => {
  const occ = { starts_at: L.helsinkiIso('2026-11-14T16:00'), ends_at: L.helsinkiIso('2026-11-14T19:00') };
  assert.equal(occ.starts_at, '2026-11-14T14:00:00.000Z');
  const rel = { resource_id: 1, mode: 'exclusive', timing: 'relative', offset_min: 0, minutes: 120 };
  const clock = { resource_id: 3, mode: 'exclusive', timing: 'clock', start: '2026-11-14T18:00', end: '2026-11-14T19:00' };
  assert.deepEqual(L.validateBlock(occ, rel), { ok: true, warning: null });
  assert.equal(L.validateBlock(occ, clock).ok, true);
  const pay = L.blocksPayload([rel, clock]);
  assert.deepEqual(pay[0], { resource_id: 1, mode: 'exclusive', offset_min: 0, minutes: 120 });
  assert.equal(pay[1].starts_at, '2026-11-14T16:00:00.000Z');
  assert.equal(pay[1].ends_at, '2026-11-14T17:00:00.000Z');
  // kellonaikalohkot lähtevät aina poikkeaman kanssa (Z), joten palvelin ei tulkitse niitä istunnon aikavyöhykkeessä (booking._event_local_ts)
  for (const b of pay.filter((x) => x.starts_at)) { assert.match(b.starts_at, /Z$/); assert.match(b.ends_at, /Z$/); }
  assert.equal(L.blocksPayload([{ ...clock, start: '2027-07-01T09:00', end: '2027-07-01T10:00' }])[0].starts_at, '2027-07-01T06:00:00.000Z');
  assert.equal(L.validateBlock(occ, { ...rel, resource_id: null }).error, 'no_resource');
  assert.equal(L.validateBlock(occ, { ...rel, minutes: -10 }).error, 'end_before_start');
  assert.equal(L.validateBlock(occ, { ...clock, end: '2026-11-14T17:00' }).error, 'end_before_start');
  assert.equal(L.validateBlock(occ, { ...rel, offset_min: -2000, minutes: 10 }).error, 'too_far');
  assert.equal(L.validateBlock(occ, { ...rel, offset_min: -30, minutes: 240 }).warning, 'outside_occurrence');
  // palvelimen rivi → lomakerivi → takaisin samaksi
  const m = createEventsMock({ today: '2026-10-24' });
  const rule = m.handlers.admin_event_list({})[0].rules[0];
  const rows = rule.blocks.map((b) => L.blockToRow(b, rule));
  assert.deepEqual(rows.map((r) => r.timing), ['relative', 'clock', 'relative']);
  assert.deepEqual(L.blocksPayload(rows).map((b) => b.offset_min ?? b.starts_at), [0, rule.blocks[1].starts_at, -30]);
});

test('saunottajat ja tilat valittavissa, kapasiteettipoolit ja passiiviset piilossa; aikajana prosentteina', () => {
  const sel = L.selectableResources([...EVENT_MOCK_RESOURCES, { id: 99, code: 'x', name: 'Pois', kind: 'space', active: false }]);
  assert.deepEqual(sel.spaces.map((r) => r.name), ['Rauni', 'Lovi', 'Savusauna']);
  assert.equal(sel.persons.length, 2);
  assert.ok(![...sel.spaces, ...sel.persons].some((r) => r.kind === 'capacity_pool' || /^event_rule_/.test(r.code)));
  const occ = { starts_at: '2026-11-14T14:00:00.000Z', ends_at: '2026-11-14T17:00:00.000Z' };
  const tl = L.timeline(occ, [{ resource_id: 1, timing: 'relative', offset_min: -30, minutes: 120 }, { resource_id: 3, timing: 'clock', start: '2026-11-14T18:00', end: '2026-11-14T19:00' }, { resource_id: 2, timing: 'relative', offset_min: '', minutes: '' }]);
  assert.equal(tl.bars.length, 3);
  assert.equal(tl.bars[2], null, 'keskeneräinen rivi ei piirry');
  assert.equal(tl.bars[0].left, 0);
  for (const r of [tl.occ, tl.bars[0], tl.bars[1]]) { assert.ok(r.left >= 0 && r.left <= 100); assert.ok(r.width > 0 && r.left + r.width <= 100.0001); }
  assert.equal(tl.from, '2026-11-14T13:30:00.000Z');
});

// ---------- kopiointi ----------
test('kopio: nimi "Kopio: [nimi]", RPC-argumentit tuotteelle ja tapahtumalle, siirto rajattu', () => {
  assert.equal(L.copyName('Perinnesaunotusilta'), 'Kopio: Perinnesaunotusilta');
  assert.ok(L.copyName('x'.repeat(300)).length <= 200);
  assert.deepEqual(L.copyArgs({ product_id: 7 }), { ok: true, fn: 'admin_product_copy', args: { p_product_id: 7 } });
  assert.deepEqual(L.copyArgs({ product_id: 31, event: true, include_rules: true, shift_days: 7 }), { ok: true, fn: 'admin_event_copy', args: { p_product_id: 31, p_include_rules: true, p_shift_days: 7 } });
  assert.equal(L.copyArgs({ product_id: 31, event: true, include_rules: false, shift_days: 7 }).args.p_shift_days, 0);
  assert.equal(L.copyArgs({ product_id: 31, event: true, include_rules: true, shift_days: 9999 }).error, 'bad_shift');
  const products = [];
  const m = createEventsMock({ today: '2026-10-24', products });
  const out = m.handlers.admin_event_copy({ p_product_id: 31, p_include_rules: true, p_shift_days: 7 });
  const copy = m.handlers.admin_event_list({ p_include_past: true }).find((p) => p.product_id === out.product_id);
  assert.equal(copy.name, 'Kopio: Perinnesaunotusilta');
  assert.equal(copy.active, false);
  assert.ok(copy.rules.every((r) => r.active === false && r.sold_persons === 0));
  assert.equal(products[0].name, 'Kopio: Perinnesaunotusilta');
});

test('mock: konflikti palauttaa hint-JSONin (conflictsOf), monipäiväinen vain koulutukselle, myynti kiinni → public_events closed', () => {
  const m = createEventsMock({ today: '2026-10-24' });
  const [ev] = m.handlers.admin_event_list({});
  const [r1, r2] = ev.rules;
  m.handlers.admin_event_rule_upsert({ p_id: r2.id, p_patch: { date: r1.date } });
  let caught = null;
  try { m.handlers.admin_event_blocks_set({ p_rule_id: r2.id, p_blocks: [{ resource_id: 1, mode: 'exclusive', offset_min: 0, minutes: 60 }] }); } catch (e) { caught = e; }
  assert.equal(caught?.code, 'conflict');
  const c = L.conflictsOf(caught);
  assert.equal(c[0].resource_name, 'Rauni');
  assert.equal(c[0].reason, 'event_block');
  assert.throws(() => m.handlers.admin_event_rule_upsert({ p_product_id: 31, p_patch: { date: '2026-12-01', start_time: '10:00', duration_minutes: 2000 } }), (e) => e.code === 'multi_day_training_only');
  assert.throws(() => m.handlers.admin_event_blocks_set({ p_rule_id: r1.id, p_blocks: [{ resource_id: 90, offset_min: 0, minutes: 60 }] }), (e) => e.code === 'invalid_resource');
  const pub = m.handlers.public_events({ p_channel: 'shop' });
  assert.ok(pub.length && pub.every((p) => p.sale_open === false && p.occurrences.every((o) => o.status === 'closed')));
  assert.equal(S.saleState(pub[0]), 'closed');
});

// ---------- kauppa: suljettu myynti ----------
test('kauppa: suljettu tapahtuma näytetään ilman ostoa, monipäiväinen kerta alku–loppu, tekstit FI+EN', () => {
  const ev = { slug: 'k', sale_open: false, occurrences: [{ starts_at: '2026-11-28T07:00:00Z', ends_at: '2026-11-29T14:00:00Z', status: 'closed' }, { starts_at: '2020-01-01T10:00:00Z', ends_at: '2020-01-01T12:00:00Z', status: 'closed' }] };
  assert.equal(S.saleState(ev), 'closed');
  assert.equal(S.saleState({ ...ev, sale_open: true }), 'closed');
  assert.equal(S.saleState({ sale_open: true, occurrences: [{ status: 'available' }] }), 'open');
  assert.equal(S.saleState({ sale_open: true, occurrences: [{ status: 'full' }] }), 'full');
  assert.equal(S.upcoming(ev, Date.parse('2026-10-24T00:00:00Z')).length, 1);
  assert.equal(S.isMultiDay(ev.occurrences[0]), true);
  assert.match(S.occurrenceText(ev.occurrences[0], 'fi'), /28\.11\.2026 09:00 – .*29\.11\.2026 16:00/);
  assert.match(S.occurrenceText({ starts_at: '2026-11-14T14:00:00Z', ends_at: '2026-11-14T17:00:00Z' }, 'fi'), /14\.11\.2026 16:00–19:00$/);
  assert.equal(S.findEvent(null, 'x'), null);
  assert.equal(S.occurrenceLabel({ label: 'FI', label_en: 'EN' }, 'en'), 'EN');
  const shop = read('booking/shop/src/shop.js');
  const fn = shop.slice(shop.indexOf('function viewEventClosed'), shop.indexOf('// ---- jaetut lomakeosat'));
  assert.ok(fn.length > 200);
  assert.doesNotMatch(fn, /innerHTML|public_create_booking|bk-pick|\/varaus\//, 'suljetussa tilassa ei varausta eikä raakaa HTML:ää');
  assert.match(shop, /findEvent\(await publicEvents\(\), slug\)/);
  assert.match(shop, /\.catch\(\(\) => \[\]\)/, 'public_events-virhe → vanha käytös');
  assert.doesNotMatch(read('booking/shop/src/i18n.js'), /ui\.shop\.event\./, 'kaupan sanakirjaan (DICTS) ei lisätty avaimia');
});

// ---------- tekstit ----------
test('tekstit: kaikki uudet FI+EN pending-import-57:ssä, ei <-merkkiä, paikkamerkit täsmäävät, ei päällekkäisyyttä', async () => {
  globalThis.localStorage ??= { getItem: () => null, setItem() {}, removeItem() {} };
  const { EVENTS_TEXTS } = await import(pathToFileURL(join(root, 'admin/events-texts.js')).href);
  const rows = JSON.parse(read(P57));
  const rows97 = JSON.parse(read('content/site-texts.pending-import-97.json'));
  const keys97 = new Set(rows97.map((r) => r.key));
  const want = new Set([...Object.keys(EVENTS_TEXTS.fi), ...Object.keys(S.EVENT_SHOP_TEXTS.fi)]);
  const want57 = new Set([...want].filter((k) => !keys97.has(k)));
  const got = new Set(rows.map((r) => r.key));
  assert.deepEqual([...got].sort(), [...want57].sort());
  for (const k of want57) for (const lang of ['fi', 'en']) {
    const r = rows.find((x) => x.key === k && x.lang === lang);
    assert.ok(r && r.text.trim(), `${k} ${lang}`);
    const dict = k.startsWith('ui.shop.') ? S.EVENT_SHOP_TEXTS : EVENTS_TEXTS;
    assert.equal(r.text, dict[lang][k]);
    assert.ok(!r.text.includes('<'), k);
    assert.ok(r.text.length <= r.max_len, k);
    assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain');
    assert.deepEqual(r.placeholders, [...new Set(r.text.match(/\{\{var:[a-z_]+\}\}/g) || [])]);
    assert.match(r.reason, /^booking_158: /);
  }
  assert.equal(rows.length, want57.size * 2);
  // muut pending-tiedostot eivät määrittele 57:n avaimia. 97:n uudet avaimet ovat sanakirjassa, eivät 57:ssä.
  for (const f of readdirSync(join(repo, 'content')).filter((f) => /^site-texts\.pending-import-\d+\.json$/.test(f) && !f.endsWith('-57.json'))) {
    for (const r of JSON.parse(read(`content/${f}`))) {
      if (f.endsWith('-97.json')) assert.ok(keys97.has(r.key) && !want57.has(r.key), `${r.key} ei kuulu 97:ään`);
      else assert.ok(!want.has(r.key), `${r.key} myös ${f}`);
    }
  }
  // näkymän kirjaimelliset avaimet löytyvät sanakirjasta
  const view = read('booking/admin/views/events.js');
  for (const [, k] of view.matchAll(/\bT\('([a-z_]+)'/g)) assert.ok(EVENTS_TEXTS.fi[`ui.admin.events.${k}`], k);
  // ei emojeja, ei sinistä
  const all = JSON.stringify(rows) + read('booking/admin/views/events.js') + read('booking/shop/src/event-sale.js');
  assert.doesNotMatch(all, /\p{Extended_Pictographic}/u);
  const css = read('booking/admin/admin.css');
  const evCss = css.slice(css.indexOf('booking_158: Tapahtumat'));
  assert.doesNotMatch(evCss, /#[0-9a-f]{3,8}\b|rgb\(|hsl\(|blue/i);
});

// ---------- XSS: käyttäjän nimet tekstinä ----------
function installDom() {
  const html = [];
  class Text { constructor(d) { this.nodeType = 3; this.data = String(d); this.parent = null; } get textContent() { return this.data; } }
  class El {
    constructor(tag) { this.nodeType = 1; this.tagName = String(tag).toUpperCase(); this.attrs = {}; this.children = []; this.listeners = {}; this.style = {}; this.dataset = {}; this.className = ''; this.value = ''; this.parent = null;
      this.classList = { add: () => {}, remove: () => {}, toggle: () => {}, contains: () => false }; }
    set innerHTML(v) { html.push(String(v)); this.children = []; }
    get innerHTML() { return ''; }
    get textContent() { return this.children.map((c) => c.textContent).join(''); }
    set textContent(v) { this.children = [new Text(v)]; }
    get innerText() { return this.textContent; }
    setAttribute(k, v) { this.attrs[k] = String(v); if (k === 'class') this.className = String(v); }
    getAttribute(k) { return this.attrs[k] ?? null; }
    hasAttribute(k) { return k in this.attrs; }
    removeAttribute(k) { delete this.attrs[k]; }
    addEventListener(t, f) { (this.listeners[t] ||= []).push(f); }
    removeEventListener() {}
    append(...xs) { for (const x of xs) { if (x == null || x === false) continue; const n = x.nodeType ? x : new Text(x); n.parent = this; this.children.push(n); } }
    prepend(...xs) { this.append(...xs); }
    after() {} before() {}
    replaceChildren(...xs) { this.children = []; this.append(...xs); }
    remove() { if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this); }
    appendChild(n) { this.append(n); return n; }
    showModal() {} close() { for (const f of this.listeners.close || []) f({}); }
    focus() {} scrollIntoView() {} closest() { return null; }
    all() { return this.children.filter((c) => c.nodeType === 1).flatMap((c) => [c, ...c.all()]); }
    querySelectorAll(sel) { const m = sel.match(/^\[data-testid="?([^"\]]+)"?\]$/); return this.all().filter((e) => (m ? e.attrs['data-testid'] === m[1] : e.tagName === sel.toUpperCase())); }
    querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  }
  const body = new El('body');
  globalThis.document = { body, documentElement: new El('html'), createElement: (t) => new El(t), createElementNS: (_n, t) => new El(t), createTextNode: (t) => new Text(t), addEventListener() {}, querySelector: () => null, getElementById: () => null };
  globalThis.window = globalThis;
  globalThis.location = { hash: '#/tapahtumat', search: '?mock=1', pathname: '/hallinta/' };
  globalThis.localStorage ??= { getItem: () => null, setItem() {}, removeItem() {} };
  globalThis.matchMedia = () => ({ matches: false, addEventListener() {} });
  return { html, body };
}

test('XSS: tapahtuman, kerran ja resurssin nimet piirretään tekstinä (ei <img>-elementtiä, ei innerHTML:ää)', async () => {
  const dom = installDom();
  // hallinta tuo ../sb.js:n (buildissa booking/shared:sta) → väliaikainen kopio
  const tmp = join(mkdtempSync(join(tmpdir(), 'tapahtumat-ui-')), 'admin');
  cpSync(join(root, 'admin'), tmp, { recursive: true });
  cpSync(join(root, 'shared/sb.js'), join(tmp, 'sb.js'));
  const sb = await import(pathToFileURL(join(tmp, 'sb.js')).href);
  const view = await import(pathToFileURL(join(tmp, 'views/events.js')).href);
  const res = EVENT_MOCK_RESOURCES.map((r) => (r.id === 4 ? { ...r, name: XSS } : r));
  const m = createEventsMock({ today: '2026-10-24', resources: res });
  m.state.events[0].name = XSS;
  m.state.events[0].rules[0].label = XSS;
  sb.setRpcOverride(async (fn, args) => (fn === 'public_get_site_texts' ? [] : m.handlers[fn](args)));
  const ctx = { can: () => true, refs: { resources: res }, role: 'admin' };
  for (const query of [new URLSearchParams(''), new URLSearchParams('tapahtuma=31')]) {
    const out = await view.render({ ctx, refs: ctx.refs, reload: () => {}, query });
    const host = dom.body; host.replaceChildren(...[out].flat(Infinity));
    assert.ok(host.textContent.includes(XSS), 'nimi näkyy kirjaimellisesti');
    assert.equal(host.querySelectorAll('img').length, 0);
    assert.ok(!host.all().some((e) => 'onerror' in e.attrs));
    if (query.get('tapahtuma')) {
      host.querySelector('[data-testid="event-occ-blocks"]').listeners.click[0]({ target: {}, preventDefault() {} });
      await new Promise((r) => setTimeout(r, 20));
      assert.ok(host.textContent.includes(XSS), 'saunottajan nimi resurssilistassa tekstinä');
      assert.equal(host.querySelectorAll('img').length, 0);
    }
  }
  assert.ok(!dom.html.some((s) => s.includes('onerror')), 'innerHTML:ään ei päädy käyttäjän tekstiä');
  assert.doesNotMatch(read('booking/admin/views/events.js'), /innerHTML|insertAdjacentHTML|outerHTML/);
  assert.doesNotMatch(read('booking/shop/src/event-sale.js'), /innerHTML/);
  sb.setRpcOverride(null);
});

test('hallinta: reitti, kopio-nappi tuotteissa, mock kytketty, build-lista ja CI', () => {
  const admin = read('booking/admin/admin.js');
  assert.match(read('booking/admin/admin-navigation.js'), /id: 'tapahtumat', path: 'tapahtumat', labelKey: 'ui\.admin\.nav\.events', view: 'events'/);
  assert.match(admin, /groupId: 'products', mod: \(\) => loadView\('nav-group'\)/);
  const prod = read('booking/admin/views/products.js');
  assert.match(prod, /data-testid': 'product-copy'/);
  assert.match(prod, /copyArgs\(\{ product_id: p\.id \}\)/);
  assert.match(prod, /q0\.get\('muokkaa'\)/);
  const mock = read('booking/admin/options-mock.js');
  assert.match(mock, /createEventsMock\(\{ today, products: st\.products \}\)/);
  assert.match(mock, /admin_product_copy:/);
  const bp = read('scripts/build-pages.mjs');
  for (const f of ['views/events.js', 'events-logic.js', 'events-texts.js', 'events-mock.js']) assert.ok(bp.includes(`'${f}'`), f);
  const ci = read('.github/workflows/pages.yml');
  assert.match(ci, /booking\/tests\/tapahtumat-158-ui\.test\.mjs/);
  assert.match(ci, /booking\/tests\/tapahtumakortit\.test\.mjs/);
});
