// Hallinnan julkaisutunnus: version.json vs. muistissa oleva ASSET_VER.
// Uusi tunnus lataa sivun uudelleen. Tallentamaton lomake saa palkin ja latautuu seuraavassa siirtymässä.
// Kahdesti epäonnistunut näkymä latautuu heti, jos tunnus on vaihtunut.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import {
  VERSION_TEXT, versionText, versionRequest, normalizeAssetVer, parseVersionPayload, versionsDiffer,
  shouldFetchVersion, reasonForVisibility, decideUpdate, hasAuthFragment, eventMarksUnsaved, markUnsavedTarget,
  isUnsavedForm, passwordSetupOpen, pageHasUnsavedWork, fetchDeployedVersion, ROUTE_CHECK_INTERVAL_MS,
  RELOAD_SUPPRESS_MS, SW_EVENT_DEDUPE_MS, createVersionController, resetVersionState, planControllerChange,
  applyServiceWorkerUpdate, showVersionBanner, startHallintaVersionWatch, noteReload, setVersionStorage,
  getVersionController,
} from '../admin/version-check.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const read = (p) => readFileSync(join(root, p), 'utf8');

function memoryStorage() {
  const m = new Map();
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => { m.set(k, String(v)); } };
}

function field({ type = 'text', parent = null, disabled = false, readOnly = false, id = '', className = '', attrs = {} } = {}) {
  const node = {
    tagName: type === 'area' ? 'DIV' : 'INPUT', type, parent, disabled, readOnly, id, className, attrs,
    isConnected: true, userEdited: false,
    setAttribute(k, v) { this.attrs[k] = String(v); },
    matches(sel) { return selectorHits(this, sel); },
    closest(sel) {
      let n = this;
      while (n) { if (selectorHits(n, sel)) return n; n = n.parent; }
      return null;
    },
  };
  return node;
}

function selectorHits(node, sel) {
  return String(sel).split(',').some((part) => oneSelector(node, part.trim()));
}
function oneSelector(node, sel) {
  if (!sel || sel.includes(' ')) return false;
  const bits = sel.match(/^[a-z-]+|\.[_a-zA-Z0-9-]+|#[_a-zA-Z0-9-]+|\[[^\]]+\]/g) || [];
  if (!bits.length) return false;
  return bits.every((bit) => {
    if (bit.startsWith('#')) return node.id === bit.slice(1);
    if (bit.startsWith('.')) return String(node.className || '').split(/\s+/).includes(bit.slice(1));
    if (bit.startsWith('[')) {
      const body = bit.slice(1, -1);
      const eq = body.indexOf('=');
      if (eq < 0) return node.attrs?.[body] != null;
      const key = body.slice(0, eq);
      const val = body.slice(eq + 1).replace(/^"|"$/g, '');
      return String(node.attrs?.[key] ?? '') === val;
    }
    return String(node.tagName || '').toLowerCase() === bit;
  });
}

test('tunnus normalisoituu ja tyhjä kehitysversio ei eroa', () => {
  assert.equal(normalizeAssetVer(null), '');
  assert.equal(normalizeAssetVer(''), '');
  assert.equal(normalizeAssetVer('  '), '');
  assert.equal(normalizeAssetVer('?v='), '');
  assert.equal(normalizeAssetVer('?v=ab12cd34ef'), 'ab12cd34ef');
  assert.equal(normalizeAssetVer('v=ab12cd34ef'), 'ab12cd34ef');
  assert.equal(normalizeAssetVer('?v=ab12cd34ef&r=1'), 'ab12cd34ef');
  assert.equal(normalizeAssetVer('  ?v=ab12cd34ef  '), 'ab12cd34ef');
  assert.equal(normalizeAssetVer('ab12cd34ef'), 'ab12cd34ef');
  assert.equal(parseVersionPayload('{"assetVer":"?v=abc"}'), 'abc');
  assert.equal(parseVersionPayload({ assetVer: '?v=abc' }), 'abc');
  assert.equal(parseVersionPayload({ version: 'abc' }), 'abc');
  assert.equal(parseVersionPayload('ei-json'), '');
  assert.equal(parseVersionPayload({}), '');
  assert.equal(parseVersionPayload(null), '');
  assert.equal(versionsDiffer('', '?v=uusi'), false);
  assert.equal(versionsDiffer('?v=vanha', ''), false);
  assert.equal(versionsDiffer('?v=sama', 'sama'), false);
  assert.equal(versionsDiffer('?v=sama', '?v=sama'), false);
  assert.equal(versionsDiffer('?v=vanha', '?v=uusi'), true);
  assert.equal(VERSION_TEXT.fi.banner, 'Uusi versio saatavilla – päivitä');
  assert.equal(VERSION_TEXT.fi.button, 'Päivitä');
  assert.equal(versionText('en').button, 'Update');
  assert.equal(versionText('fi').banner, VERSION_TEXT.fi.banner);
  const req = versionRequest(42);
  assert.equal(req.url, './version.json?ts=42');
  assert.equal(req.init.cache, 'no-store');
});

test('päätös: heti uudelleen, palkki lomakkeen keskellä, näkymän kaksoisvirhe pakottaa', () => {
  const base = { running: '?v=vanha', remote: '?v=uusi' };
  assert.equal(decideUpdate({ ...base, unsaved: false, reason: 'focus' }), 'reload');
  assert.equal(decideUpdate({ ...base, unsaved: false, reason: 'visibility' }), 'reload');
  assert.equal(decideUpdate({ ...base, unsaved: false, reason: 'route' }), 'reload');
  assert.equal(decideUpdate({ ...base, unsaved: true, reason: 'focus' }), 'banner');
  assert.equal(decideUpdate({ ...base, unsaved: true, reason: 'visibility' }), 'banner');
  assert.equal(decideUpdate({ ...base, unsaved: true, reason: 'route' }), 'banner');
  assert.equal(decideUpdate({ ...base, unsaved: true, reason: 'load-fail' }), 'reload');
  assert.equal(decideUpdate({ ...base, unsaved: false, reason: 'load-fail' }), 'reload');
  assert.equal(decideUpdate({ running: '?v=sama', remote: '?v=sama', unsaved: false, reason: 'load-fail' }), 'none');
  assert.equal(decideUpdate({ running: '', remote: '?v=uusi', unsaved: false, reason: 'load-fail' }), 'none');
  assert.equal(decideUpdate({ running: '?v=vanha', remote: '', unsaved: true, reason: 'focus' }), 'none');
});

test('reittitarkistus korkeintaan muutaman minuutin välein, fokus ja virhe aina', () => {
  const running = '?v=abc';
  for (const reason of ['focus', 'visibility', 'load-fail']) {
    assert.equal(shouldFetchVersion({ reason, now: 0, lastCheckedAt: 0, running }), true);
  }
  assert.equal(shouldFetchVersion({ reason: 'route', now: 5_000, lastCheckedAt: null, running }), true);
  assert.equal(shouldFetchVersion({ reason: 'route', now: 5_000, lastCheckedAt: 5_000, running }), false);
  assert.equal(shouldFetchVersion({ reason: 'route', now: 5_000 + ROUTE_CHECK_INTERVAL_MS - 1, lastCheckedAt: 5_000, running }), false);
  assert.equal(shouldFetchVersion({ reason: 'route', now: 5_000 + ROUTE_CHECK_INTERVAL_MS, lastCheckedAt: 5_000, running }), true);
  assert.equal(shouldFetchVersion({ reason: 'focus', now: 5_000, lastCheckedAt: 5_000, running: '' }), false);
  assert.equal(shouldFetchVersion({ reason: 'load-fail', now: 5_000, lastCheckedAt: null, running: '' }), false);
  assert.equal(shouldFetchVersion({ reason: 'muu', now: 0, lastCheckedAt: null, running }), false);
  assert.equal(reasonForVisibility('visible'), 'visibility');
  assert.equal(reasonForVisibility('hidden'), null);
  assert.equal(ROUTE_CHECK_INTERVAL_MS >= 2 * 60 * 1000 && ROUTE_CHECK_INTERVAL_MS <= 5 * 60 * 1000, true);
});

test('controlleri: fokus lataa, lomake näyttää palkin, seuraava siirtymä lataa, virhe ohittaa lomakkeen', async () => {
  resetVersionState();
  const events = [];
  let remote = '?v=uusi';
  let unsaved = false;
  let now = 10_000;
  let fetches = 0;
  const ctrl = createVersionController({
    running: '?v=vanha',
    fetchRemote: async () => { fetches++; return remote; },
    unsaved: () => unsaved,
    now: () => now,
    onReload() { events.push('reload'); },
    onBanner() { events.push('banner'); },
  });
  assert.equal(await ctrl.check('focus'), 'reload');
  assert.deepEqual(events, ['reload']);
  assert.equal(fetches, 1);

  resetVersionState();
  events.length = 0; fetches = 0; unsaved = true;
  const held = createVersionController({
    running: '?v=vanha',
    fetchRemote: async () => { fetches++; return remote; },
    unsaved: () => unsaved,
    now: () => now,
    onReload() { events.push('reload'); },
    onBanner() { events.push('banner'); },
  });
  assert.equal(await held.check('visibility'), 'banner');
  assert.equal(held.armed, true);
  assert.equal(held.onNavigate(), true);
  assert.deepEqual(events, ['banner', 'reload']);
  assert.equal(held.onNavigate(), true);
  assert.deepEqual(events, ['banner', 'reload']);

  resetVersionState();
  events.length = 0; fetches = 0; unsaved = true;
  const failed = createVersionController({
    running: '?v=vanha',
    fetchRemote: async () => { fetches++; return remote; },
    unsaved: () => unsaved,
    now: () => now,
    onReload() { events.push('reload'); },
    onBanner() { events.push('banner'); },
  });
  assert.equal(await failed.check('load-fail'), 'reload');
  assert.deepEqual(events, ['reload']);
  assert.equal(fetches, 1);

  resetVersionState();
  fetches = 0; remote = '?v=vanha';
  const same = createVersionController({
    running: '?v=vanha', fetchRemote: async () => { fetches++; return remote; }, now: () => now,
    onReload() { throw new Error('ei uudelleen'); }, onBanner() { throw new Error('ei palkkia'); },
  });
  assert.equal(await same.check('route'), 'none');
  now += ROUTE_CHECK_INTERVAL_MS - 1;
  assert.equal(await same.check('route'), 'skipped');
  assert.equal(fetches, 1);
  now += 1;
  assert.equal(await same.check('focus'), 'none');
  assert.equal(fetches, 2);
  assert.equal(await same.check('route'), 'skipped');
  assert.equal(fetches, 2);

  resetVersionState();
  const dev = createVersionController({
    running: '',
    fetchRemote: async () => { fetches++; return '?v=uusi'; },
    onReload() { throw new Error('kehitys ei lataudu uudelleen'); },
  });
  fetches = 0;
  assert.equal(await dev.check('focus'), 'skipped');
  assert.equal(await dev.check('load-fail'), 'skipped');
  assert.equal(await dev.check('route'), 'skipped');
  assert.equal(fetches, 0);
});

test('kesken oleva reittitarkistus muuttuu pakkolataukseksi, jos näkymä ehtii epäonnistua', async () => {
  resetVersionState();
  let release;
  const pending = new Promise((resolve) => { release = resolve; });
  let fetches = 0;
  const events = [];
  const ctrl = createVersionController({
    running: '?v=vanha',
    fetchRemote: () => { fetches++; return pending; },
    unsaved: () => true,
    now: () => 1,
    timeoutMs: 5000,
    onReload() { events.push('reload'); },
    onBanner() { events.push('banner'); },
  });
  const routeP = ctrl.check('route');
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(fetches, 1);
  const failP = ctrl.check('load-fail');
  release('?v=uusi');
  assert.equal(await failP, 'reload');
  assert.equal(await routeP, 'reload');
  assert.deepEqual(events, ['reload']);
});

test('verkkovirhe ja hidas version.json eivät lataa sivua uudelleen', async () => {
  resetVersionState();
  const broken = createVersionController({
    running: '?v=vanha',
    fetchRemote: async () => { throw new Error('offline'); },
    now: () => 1,
    onReload() { throw new Error('ei uudelleen'); },
  });
  assert.equal(await broken.check('focus'), 'none');

  resetVersionState();
  let fetches = 0;
  const slow = createVersionController({
    running: '?v=vanha',
    fetchRemote: () => { fetches++; return new Promise(() => {}); },
    now: () => 1,
    timeoutMs: 20,
    onReload() { throw new Error('ei uudelleen'); },
    onBanner() { throw new Error('ei palkkia'); },
  });
  assert.equal(await slow.check('load-fail'), 'none');
  assert.equal(fetches, 1);
});

test('version.json haetaan ilman välimuistia', async () => {
  const seen = [];
  const tag = await fetchDeployedVersion(async (url, init) => {
    seen.push({ url, init });
    return { ok: true, text: async () => JSON.stringify({ assetVer: '?v=abc' }) };
  }, 7);
  assert.equal(tag, 'abc');
  assert.equal(seen[0].url, './version.json?ts=7');
  assert.equal(seen[0].init.cache, 'no-store');
  assert.equal(seen[0].init.credentials, 'same-origin');
  assert.equal(await fetchDeployedVersion(async () => ({ ok: false, text: async () => '{"assetVer":"?v=x"}' })), '');
  assert.equal(await fetchDeployedVersion(async () => { throw new Error('verkko'); }).catch((e) => e.message), 'verkko');
});

test('lomake on tallentamaton vain käyttäjän muokkauksesta, ei hausta', () => {
  const form = field({ type: 'area' });
  form.tagName = 'FORM';
  const input = field({ parent: form });
  assert.equal(eventMarksUnsaved(input), true);
  assert.equal(markUnsavedTarget(input), true);
  assert.equal(input.attrs['data-user-edited'], '1');

  const searchForm = field({ type: 'area', attrs: { role: 'search' } });
  searchForm.tagName = 'FORM';
  const search = field({ type: 'search', parent: searchForm });
  assert.equal(eventMarksUnsaved(search), false);

  const toolbar = field({ type: 'area', className: 'tl-toolbar' });
  const filter = field({ parent: toolbar });
  assert.equal(eventMarksUnsaved(filter), false);

  const quick = field({ type: 'area', id: 'quick-search' });
  const qInput = field({ parent: quick });
  assert.equal(eventMarksUnsaved(qInput), false);

  const bare = field();
  assert.equal(eventMarksUnsaved(bare), false);
  const dialog = field({ type: 'area' });
  dialog.tagName = 'DIALOG';
  const inDialog = field({ parent: dialog });
  assert.equal(markUnsavedTarget(inDialog), true);

  const doc = {
    querySelectorAll() { return [input, search]; },
    getElementById(id) { return id === 'setpw-screen' ? { hidden: false } : null; },
  };
  assert.equal(isUnsavedForm(doc), true);
  assert.equal(passwordSetupOpen(doc), true);
  assert.equal(hasAuthFragment('#access_token=secret&type=invite'), true);
  assert.equal(hasAuthFragment('#/talous'), false);
  assert.equal(pageHasUnsavedWork(doc, '#/'), true);
  assert.equal(pageHasUnsavedWork({ querySelectorAll() { return []; }, getElementById() { return { hidden: true }; } }, ''), false);
});

test('palkki on kerran, teksti on täsmälleen pyydetty ja nappi lataa', () => {
  const byId = {};
  const mk = (tag) => {
    const node = {
      tag, className: '', textContent: '', type: '', children: [], attrs: {},
      setAttribute(k, v) { this.attrs[k] = v; },
      append(...kids) { this.children.push(...kids); },
      prepend(kid) { this.children.unshift(kid); },
      addEventListener(type, fn) { this['on' + type] = fn; },
    };
    let id = '';
    Object.defineProperty(node, 'id', { get() { return id; }, set(v) { id = v; byId[v] = node; } });
    return node;
  };
  const doc = { body: mk('body'), getElementById: (id) => byId[id] || null, createElement: mk };
  let clicks = 0;
  assert.equal(showVersionBanner(doc, { onUpdate: () => { clicks++; } }), true);
  const bar = doc.getElementById('version-banner');
  assert.equal(bar.children[0].textContent, 'Uusi versio saatavilla – päivitä');
  assert.equal(bar.children[1].textContent, 'Päivitä');
  assert.equal(bar.attrs.role, 'status');
  bar.children[1].onclick();
  assert.equal(clicks, 1);
  assert.equal(showVersionBanner(doc, { onUpdate() {} }), false);
});

test('service workerin vaihto: ensimmäinen asennus ei lataa, päivitys lataa kerran, lomake pitää palkin', () => {
  resetVersionState();
  const events = [];
  const acks = [];
  const ctrl = createVersionController({
    running: '?v=vanha', fetchRemote: async () => '?v=vanha', now: () => 100,
    onReload() { events.push('reload'); }, onBanner() { events.push('own-banner'); },
  });
  assert.deepEqual(planControllerChange({ hadController: false, unsaved: true }), { action: 'ack', hold: false });
  assert.deepEqual(planControllerChange({ hadController: true, unsaved: true }), { action: 'banner', hold: true });
  assert.deepEqual(planControllerChange({ hadController: true, unsaved: false }), { action: 'reload', hold: false });
  assert.equal(applyServiceWorkerUpdate({ hadController: false, unsaved: () => true, now: 100, ack: (d) => acks.push(d) }), 'ack');
  assert.deepEqual(events, []);
  assert.equal(applyServiceWorkerUpdate({ hadController: true, unsaved: () => false, now: 100 + SW_EVENT_DEDUPE_MS, ack: (d) => acks.push(d) }), 'reload');
  assert.deepEqual(events, ['reload']);
  assert.equal(applyServiceWorkerUpdate({ hadController: true, unsaved: () => false, now: 100 + SW_EVENT_DEDUPE_MS + 10, ack: (d) => acks.push(d) }), 'ignore');
  assert.deepEqual(events, ['reload']);

  resetVersionState();
  events.length = 0;
  const held = createVersionController({
    running: '?v=vanha', fetchRemote: async () => '?v=vanha', now: () => 50,
    onReload() { events.push('reload'); },
  });
  let banners = 0;
  assert.equal(applyServiceWorkerUpdate({
    hadController: true, unsaved: () => true, now: 50,
    showBanner() { banners++; }, ack: (d) => acks.push(d),
  }), 'banner');
  assert.equal(banners, 1);
  assert.equal(held.armed, true);
  assert.equal(held.onNavigate(), true);
  assert.deepEqual(events, ['reload']);

  resetVersionState();
  setVersionStorage(memoryStorage());
  noteReload(1_000);
  events.length = 0;
  createVersionController({
    running: '?v=vanha', fetchRemote: async () => '?v=uusi', now: () => 2_000,
    onReload() { events.push('reload'); },
  });
  const fresh = [];
  assert.equal(applyServiceWorkerUpdate({ hadController: true, unsaved: () => false, now: 1_000 + RELOAD_SUPPRESS_MS - 1, ack: (d) => fresh.push(d) }), 'ignore');
  assert.deepEqual(fresh, [{ hold: false, fresh: true }]);
  assert.deepEqual(events, []);
  assert.equal(getVersionController().reloading, false);
});

test('fokus, näkyvyys ja muokkaus kytketään sivun tapahtumiin', async () => {
  resetVersionState();
  const listeners = {};
  const doc = {
    visibilityState: 'hidden',
    body: { append() {} },
    addEventListener(type, fn, cap) { (listeners[type] ||= []).push({ fn, cap }); },
    getElementById() { return null; },
    createElement() {
      return { setAttribute() {}, append() {}, prepend() {}, addEventListener() {}, children: [] };
    },
    querySelectorAll() { return []; },
  };
  let reloads = 0;
  const win = {
    location: { hash: '', reload() { reloads++; } },
    addEventListener(type, fn) { (listeners['win:' + type] ||= []).push({ fn }); },
  };
  let fetches = 0;
  startHallintaVersionWatch({
    running: '?v=vanha',
    document: doc,
    window: win,
    now: () => 5,
    fetchImpl: async (url, init) => {
      fetches++;
      assert.match(url, /version\.json\?ts=/);
      assert.equal(init.cache, 'no-store');
      return { ok: true, text: async () => JSON.stringify({ assetVer: '?v=uusi' }) };
    },
  });
  listeners.visibilitychange[0].fn();
  await new Promise((r) => setImmediate(r));
  assert.equal(fetches, 0);
  doc.visibilityState = 'visible';
  listeners.visibilitychange[0].fn();
  await new Promise((r) => setImmediate(r));
  assert.equal(fetches, 1);
  assert.equal(reloads, 1);
  assert.equal(listeners.input[0].cap, true);
  assert.equal(listeners.change[0].cap, true);
  const form = field({ type: 'area' });
  form.tagName = 'FORM';
  const input = field({ parent: form });
  listeners.input[0].fn({ target: input });
  assert.equal(input.attrs['data-user-edited'], '1');
  assert.equal(typeof listeners['win:focus'][0].fn, 'function');
});

test('admin.js tarkistaa version fokuksessa, siirtymässä ja näkymän kaksoisvirheessä', () => {
  const admin = read('booking/admin/admin.js');
  const watch = read('booking/admin/version-check.js');
  const build = read('scripts/build-pages.mjs');
  const yml = read('.github/workflows/pages.yml');
  assert.match(admin, /const ASSET_VER = '';/);
  assert.match(admin, /startHallintaVersionWatch\(\{ running: ASSET_VER \}\)/);
  assert.match(admin, /version\?\.onNavigate\(\)/);
  assert.match(admin, /check\('route'\)/);
  assert.match(admin, /check\('load-fail'\)/);
  assert.match(watch, /addEventListener\('visibilitychange'/);
  assert.match(watch, /addEventListener\('focus'/);
  assert.match(watch, /Uusi versio saatavilla – päivitä/);
  assert.match(build, /writeFileSync\(join\(A, 'version\.json'\)/);
  assert.match(build, /assetVer: VER/);
  assert.match(yml, /booking\/tests\/hallinta-version\.test\.mjs/);
  assert.doesNotMatch(read('booking/admin/sw.js'), /version\.json[\s\S]{0,80}cache\.put/);
});
