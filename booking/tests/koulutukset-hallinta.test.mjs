// Joonas 6.11.2026 (t1367u, t1370u): koulutukset omana hallinnan osionaan (#/koulutukset), koulutuksen tuotetekstit muokattavissa
// suoraan koulutuksen Tekstit-välilehdellä (kb.products, admin_update_product) ja "Verkossa"-merkki ei perustu Johku-kenttään booking_url.
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import test from 'node:test';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const read = (rel) => readFileSync(join(repo, rel), 'utf8');
const { createEventsMock, EVENT_MOCK_RESOURCES } = await import(pathToFileURL(join(root, 'admin/events-mock.js')).href);
const { resolveAdminPath } = await import(pathToFileURL(join(root, 'admin/admin-navigation.js')).href);
const { NAV_TEXTS } = await import(pathToFileURL(join(root, 'admin/nav-texts.js')).href);
const { COURSE_TEXTS } = await import(pathToFileURL(join(root, 'admin/events-texts.js')).href);
const { ICONS } = await import(pathToFileURL(join(root, 'admin/icons.js')).href);

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

const tmp = join(mkdtempSync(join(tmpdir(), 'koulutukset-')), 'admin');
cpSync(join(root, 'admin'), tmp, { recursive: true });
cpSync(join(root, 'shared/sb.js'), join(tmp, 'sb.js'));
const dom = installDom();
const sb = await import(pathToFileURL(join(tmp, 'sb.js')).href);
const { isOnline } = await import(pathToFileURL(join(tmp, 'views/products.js')).href);
const events = await import(pathToFileURL(join(tmp, 'views/events.js')).href);
const koulutukset = await import(pathToFileURL(join(tmp, 'views/koulutukset.js')).href);

// Tuotannon rivit 6.11.2026 (SELECT): koulutukset 114–120 channels ['link'], shop_visible false, booking_url NULL; 35–37 vanhat Johku-tuotteet.
const cfg = (o) => ({ bookable: true, shop_visible: true, lifecycle: 'current', channels: null, ...o });
test('Verkossa-merkki: koulutus suoralla linkillä on verkossa, booking_url ei vaikuta', () => {
  const intro = { id: 114, slug: 'intro-course-saunotus-ritual-foundations', category: 'training', active: true, booking_url: null, config: cfg({ shop_visible: false, channels: ['link'] }) };
  assert.equal(isOnline(intro), true);
  for (const id of [115, 116, 117, 118, 119, 120]) assert.equal(isOnline({ ...intro, id }), true, String(id));
  assert.equal(isOnline({ ...intro, booking_url: 'https://johku.example/x' }), true, 'booking_url ei muuta tulosta');
  assert.equal(isOnline({ ...intro, active: false }), false, 'piilotettu ei ole verkossa');
  assert.equal(isOnline({ ...intro, config: cfg({ shop_visible: false, channels: ['link'], bookable: false }) }), false);
  assert.equal(isOnline({ ...intro, config: cfg({ shop_visible: false, channels: ['link'], lifecycle: 'old' }) }), false);
  assert.equal(isOnline({ ...intro, config: cfg({ shop_visible: false, channels: null }) }), false, 'koulutuksen oletuskanava widget: ei kaupassa');
  // vanhat Johku-koulutukset 35/36/37: bookable false (37 myös inactive) → ei verkossa, vaikka booking_url on asetettu
  for (const [id, active, lifecycle] of [[35, true, 'old'], [36, true, 'current'], [37, false, 'old']]) {
    assert.equal(isOnline({ id, category: 'training', active, booking_url: 'https://johku.example/' + id, config: cfg({ bookable: false, shop_visible: false, lifecycle }) }), false, String(id));
  }
  // muut tuotteet ennallaan
  assert.equal(isOnline({ id: 1, category: 'public_sauna', active: true, config: cfg() }), true);
  assert.equal(isOnline({ id: 2, category: 'event', active: true, config: cfg({ shop_visible: false }) }), false);
  assert.equal(isOnline({ id: 3, category: 'event', active: true, config: cfg({ channels: ['link'] }) }), false, 'link-kanava vain koulutuksille');
  assert.equal(isOnline({ id: 4, category: 'public_sauna', active: true, config: null }), false);
  assert.doesNotMatch(read('booking/admin/views/products.js').split('export const isOnline')[1].split('\n};')[0], /booking_url/);
});

test('päänavigaatio: Koulutukset omana kohtana Tuotteiden jälkeen, tekstit FI+EN, oma ikoni', () => {
  const js = read('booking/admin/admin.js');
  const order = [...js.matchAll(/\{ path: '([^']*)', label:/g)].map((m) => m[1]);
  assert.ok(order.indexOf('koulutukset') === order.indexOf('tuotteet') + 1);
  assert.match(js, /path: 'koulutukset', label: 'Koulutukset', labelFn: \(\) => navText\('ui\.admin\.nav\.trainings'\), icon: 'school', mod: \(\) => loadView\('koulutukset'\)/);
  assert.deepEqual(resolveAdminPath('koulutukset'), { path: 'koulutukset', legacyReservations: false, groupId: null, tabId: null });
  assert.equal(NAV_TEXTS.fi['ui.admin.nav.trainings'], 'Koulutukset');
  assert.equal(NAV_TEXTS.en['ui.admin.nav.trainings'], 'Trainings');
  assert.ok(ICONS.school);
  assert.ok(read('scripts/build-pages.mjs').includes("'views/koulutukset.js'"));
});

function mockCtx() {
  const m = createEventsMock({ today: '2026-11-06', resources: EVENT_MOCK_RESOURCES });
  const calls = [];
  const products = m.state.events.map((p) => ({ id: p.product_id, slug: p.slug, name: p.name, category: p.category, short_description: p.category === 'training' ? '<p>Lyhyt</p>' : null, short_description_en: null, description: p.category === 'training' ? '<p>Kuvaus</p>' : null, description_en: '<p>Description</p>' }));
  sb.setRpcOverride(async (fn, args) => {
    calls.push([fn, args]);
    if (fn === 'public_get_site_texts') return { ok: true, texts: [] };
    if (fn === 'admin_update_product') return { ok: true, id: args.p_product_id };
    return m.handlers[fn](args);
  });
  const ctx = { can: () => true, refs: { resources: EVENT_MOCK_RESOURCES, products, productById: new Map(products.map((p) => [p.id, p])) }, role: 'admin' };
  return { ctx, calls };
}
const flat = (out) => { dom.body.replaceChildren(...[out].flat(Infinity)); return dom.body; };

test('#/koulutukset: vain koulutukset, oma otsikko, linkit pysyvät osiossa', async () => {
  const { ctx, calls } = mockCtx();
  globalThis.location.hash = '#/koulutukset';
  const host = flat(await koulutukset.render({ ctx, refs: ctx.refs, reload: () => {}, query: new URLSearchParams('') }));
  assert.deepEqual(calls.find(([fn]) => fn === 'admin_event_list')[1].p_category, 'training');
  assert.ok(host.textContent.includes('Koulutukset'));
  assert.ok(host.textContent.includes('Saunottajakoulutus'));
  assert.ok(!host.textContent.includes('Perinnesaunotusilta'), 'tapahtumat eivät näy koulutuksissa');
  const hrefs = host.all().map((e) => e.attrs.href).filter((x) => x && x.startsWith('#/'));
  assert.ok(hrefs.length && hrefs.every((x) => x.startsWith('#/koulutukset')), hrefs.join(' '));
  assert.equal(host.querySelectorAll('[data-testid="events-filter"]').length, 0);
});

test('#/tapahtumat: vain tapahtumat; vanha kategoria=training ohjautuu koulutuksiin', async () => {
  const { ctx, calls } = mockCtx();
  const host = flat(await events.render({ ctx, refs: ctx.refs, reload: () => {}, query: new URLSearchParams('') }));
  assert.equal(calls.find(([fn]) => fn === 'admin_event_list')[1].p_category, 'event');
  assert.ok(host.textContent.includes('Perinnesaunotusilta'));
  assert.ok(!host.textContent.includes('Saunottajakoulutus'));
  let replaced = null;
  globalThis.location.replace = (u) => { replaced = u; };
  const out = await events.render({ ctx, refs: ctx.refs, reload: () => {}, query: new URLSearchParams('kategoria=training&tapahtuma=33') });
  assert.deepEqual(out, []);
  assert.equal(replaced, '#/koulutukset?tapahtuma=33');
  delete globalThis.location.replace;
});

test('koulutuksen Tekstit-välilehti: kb.products-tekstit FI+EN, tallennus vain tekstikentät admin_update_productiin', async () => {
  const { ctx, calls } = mockCtx();
  let reloaded = 0;
  const host = flat(await koulutukset.render({ ctx, refs: ctx.refs, reload: () => { reloaded++; }, query: new URLSearchParams('tapahtuma=33&valilehti=tekstit') }));
  assert.ok(host.querySelector('[data-testid="event-tab-tekstit"]'), 'Tekstit-välilehti');
  const form = host.querySelector('[data-testid="training-texts-form"]');
  assert.ok(form);
  for (const id of ['training-short-fi', 'training-short-en', 'training-desc-fi', 'training-desc-en']) assert.ok(host.querySelector(`[data-testid="${id}"]`), id);
  assert.equal(host.querySelector('[data-testid="training-desc-fi"]').attrs.value ?? host.querySelector('[data-testid="training-desc-fi"]').value, '<p>Kuvaus</p>');
  // tapahtumalla ei Tekstit-välilehteä
  const ev = flat(await events.render({ ctx, refs: ctx.refs, reload: () => {}, query: new URLSearchParams('tapahtuma=31') }));
  assert.equal(ev.querySelector('[data-testid="event-tab-tekstit"]'), null);
  const view = read('booking/admin/views/events.js');
  const panel = view.slice(view.indexOf('function textsPanel'), view.indexOf('function directLinks'));
  assert.match(panel, /rpc\('admin_update_product', \{ p_product_id: p\.product_id, p_patch: patch \}\)/);
  assert.match(panel, /\['short_description', 'short_description_en', 'description', 'description_en'\]/);
  assert.doesNotMatch(panel, /price|vat_rate|slug:|booking_url|active:/, 'ei hintaa, ALV:tä, slugia eikä Johku-linkkiä');
  assert.match(panel, /syncRichFields\(f\)/);
  assert.match(panel, /ctx\.refs = null; reload\(\)/);
  void reloaded; void calls;
});

test('tekstit: COURSE_TEXTS FI+EN pending-import-126:ssa, ei kulmasulkeita', () => {
  const rows = JSON.parse(read('content/site-texts.pending-import-126.json'));
  for (const k of ['trainings_title', 'trainings_lead', 'tab_texts', 'texts_lead', 'texts_desc_fi', 'texts_desc_en', 'texts_save', 'texts_saved', 'texts_missing']) {
    for (const lang of ['fi', 'en']) {
      const r = rows.find((x) => x.key === `admin.events.${k}` && x.lang === lang);
      assert.ok(r, `${k} ${lang}`);
      assert.equal(r.text, COURSE_TEXTS[lang][`admin.events.${k}`]);
      assert.doesNotMatch(r.text, /[<>]/);
    }
  }
  assert.ok(rows.some((r) => r.key === 'ui.admin.nav.trainings' && r.lang === 'en' && r.text === 'Trainings'));
  assert.doesNotMatch(read('booking/admin/views/koulutukset.js') + read('booking/admin/views/events.js'), /\p{Extended_Pictographic}/u);
});

test.after(() => sb.setRpcOverride(null));
