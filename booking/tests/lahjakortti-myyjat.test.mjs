// booking_173: lahjakortin myyjän vahvistus kaupassa ("Mistä lahjakortti on ostettu?"). Kevyt valedomi, jonka replaceChildren/append muuttaa
// ei-solmut tekstiksi kuten oikea selain (null → "null") → testi kaatuisi vanhaan virheeseen (omistajan kuvakaappaus: "null" myyjävalintojen alla).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, cpSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
// order-gift.js tuo ./sb.js:n (kopioidaan rakennuksessa booking/shared/sb.js:stä) → sama koonti väliaikaishakemistoon
const dir = mkdtempSync(join(tmpdir(), 'vc173-'));
for (const f of readdirSync(join(here, '../shop/src'))) if (f.endsWith('.js')) cpSync(join(here, '../shop/src', f), join(dir, f));
cpSync(join(here, '../shared/sb.js'), join(dir, 'sb.js'));

class Text { constructor(t) { this.nodeType = 3; this.data = String(t); this.parentNode = null; } get textContent() { return this.data; } }
class El {
  constructor(tag) { this.nodeType = 1; this.tagName = tag.toUpperCase(); this.children = []; this.attrs = {}; this.listeners = {}; this.hidden = false; this.className = ''; this.parentNode = null; this.checked = false; this.value = ''; this.disabled = false;
    this.classList = { toggle() {}, add() {}, remove() {}, contains: () => false }; }
  get childNodes() { return this.children; }
  _norm(k) { return k && k.nodeType ? k : new Text(k); }   // oikea DOM: append(null) → tekstisolmu "null"
  append(...k) { for (const x of k) { const n = this._norm(x); n.parentNode = this; this.children.push(n); } }
  replaceChildren(...k) { this.children = []; this.append(...k); }
  setAttribute(k, v) { this.attrs[k] = String(v); if (k === 'checked') this.checked = true; if (k === 'value') this.value = String(v); if (k === 'hidden') this.hidden = true; }
  getAttribute(k) { return this.attrs[k] ?? null; }
  removeAttribute(k) { delete this.attrs[k]; }
  addEventListener(t, f) { (this.listeners[t] ||= []).push(f); }
  dispatch(t, ev = {}) { let n = this; while (n) { for (const f of n.listeners?.[t] || []) f({ target: this, preventDefault() {}, ...ev }); n = n.parentNode; } }
  set textContent(v) { this.children = [new Text(v)]; }
  get textContent() { return this.children.map((c) => c.textContent).join(''); }
  focus() {} scrollIntoView() {} matches() { return false; }
  get id() { return this.attrs.id; } set id(v) { this.attrs.id = v; }
  all() { return this.children.flatMap((c) => (c.nodeType === 1 ? [c, ...c.all()] : [])); }
  querySelector(sel) {
    if (sel === 'input[name=vc-source]:checked') return this.all().find((e) => e.tagName === 'INPUT' && e.attrs.name === 'vc-source' && e.checked) || null;
    const m = /^\[data-testid=([\w-]+)\]$/.exec(sel); if (m) return this.all().find((e) => e.attrs['data-testid'] === m[1]) || null;
    throw new Error('selector ' + sel);
  }
}
globalThis.document = { createElement: (t) => new El(t), createTextNode: (t) => new Text(t) };
globalThis.window = globalThis.window || { BOOKING_CONFIG: {} };
globalThis.localStorage = { getItem: () => null, setItem() {}, removeItem() {} };
globalThis.matchMedia = () => ({ matches: true });

const { redeemSection } = await import(pathToFileURL(join(dir, 'order-gift.js')).href);
const { GT } = await import(pathToFileURL(join(dir, 'gift-texts.js')).href);
const SOURCES = [{ code: 'kokemuskauppa', label: 'Kokemuskauppa', label_en: 'Kokemuskauppa' }, { code: 'offerilla', label: 'Offerilla', label_en: 'Offerilla' }, { code: 'elamyslahjat', label: 'Elämyslahjat', label_en: 'Elämyslahjat' }];
const fakeApi = (resolve, sent = []) => ({ resolve: async () => resolve, submitClaim: async (a) => { sent.push(a); return { ok: true, claim_no: 7, source: a.source, source_label: SOURCES.find((s) => s.code === a.source)?.label, code_masked: '…36G5', payment_method: `partner_voucher_${a.source}`, payment_method_label: 'x' }; } });

async function openChoose({ L = 'fi', code = 'KK534536G5', resolve }) {
  const sent = [], claimed = [];
  const root = redeemSection({ L, api: fakeApi(resolve, sent), token: 't', onApplied() {}, onClaimed: (x) => claimed.push(x) });
  const input = root.querySelector('[data-testid=gc-code]'); input.value = code;
  const form = root.all().find((e) => e.tagName === 'FORM');
  for (const f of form.listeners.submit) await f({ preventDefault() {} });
  return { root, choose: root.querySelector('[data-testid=vc-choose]'), sent, claimed };
}
const visible = (n) => n.textContent;

for (const L of ['fi', 'en']) {
  test(`myyjän vahvistus (${L}): KK534536G5 tunnistetaan, ei "null"/"undefined" missään`, async () => {
    const { choose } = await openChoose({ L, resolve: { ok: true, kind: 'unknown', partner_claims_enabled: true, sources: SOURCES, suggested_source: 'kokemuskauppa', suggestion_confidence: 'high' } });
    assert.equal(choose.hidden, false);
    const t = visible(choose);
    assert.ok(!/\bnull\b|\bundefined\b|\{\w+\}/.test(t), `ei null/undefined/paikkamerkkejä: ${t}`);
    assert.ok(t.includes('Kokemuskauppa'));
    assert.ok(choose.querySelector('[data-testid=vc-src-kokemuskauppa]').checked, 'Kokemuskauppa esivalittu');
    assert.ok(!choose.querySelector('[data-testid=vc-src-kiitoskauppa]'), 'Kiitoskauppa ei valinnoissa');
    assert.equal(choose.querySelector('[data-testid=vc-method]').textContent, L === 'fi' ? 'Maksutapa: Lahjakortti – Kokemuskauppa' : 'Payment method: Gift card – Kokemuskauppa');
    assert.equal(choose.querySelector('[data-testid=vc-suggest]').textContent, GT[L]['vc.detected'].replace('{source}', 'Kokemuskauppa'));
  });
  test(`myyjän vahvistus (${L}): ei ehdotusta → ei tyhjää/null-riviä, maksutapa-rivillä ohje`, async () => {
    const { choose } = await openChoose({ L, code: 'ABCDEFGH', resolve: { ok: true, kind: 'unknown', partner_claims_enabled: true, sources: SOURCES, suggested_source: null, suggestion_confidence: null } });
    const t = visible(choose);
    assert.ok(!/\bnull\b|\bundefined\b/.test(t), t);
    assert.equal(choose.querySelector('[data-testid=vc-suggest]'), null, 'ei ehdotusriviä');
    assert.equal(choose.querySelector('[data-testid=vc-method]').textContent, GT[L]['vc.noGuess']);
    assert.ok(choose.all().every((e) => e.children.every((c) => c.nodeType === 1 || (c.data !== 'null' && c.data !== 'undefined'))), 'ei null-tekstisolmuja');
  });
}

test('asiakas vaihtaa myyjän ennen lähetystä: maksutapa päivittyy ja lähetys käyttää valintaa', async () => {
  const { choose, sent, claimed } = await openChoose({ resolve: { ok: true, kind: 'unknown', partner_claims_enabled: true, sources: SOURCES, suggested_source: 'offerilla', suggestion_confidence: 'low' } });
  assert.equal(choose.querySelector('[data-testid=vc-suggest]').textContent, GT.fi['vc.detectedLow'].replace('{source}', 'Offerilla'), 'heikko ehdotus kerrotaan ehdotuksena');
  choose.querySelector('[data-testid=vc-src-offerilla]').checked = false;
  const el = choose.querySelector('[data-testid=vc-src-elamyslahjat]'); el.checked = true; el.dispatch('change');
  assert.equal(choose.querySelector('[data-testid=vc-method]').textContent, 'Maksutapa: Lahjakortti – Elämyslahjat');
  const btn = choose.querySelector('[data-testid=vc-submit]');
  assert.equal(btn.textContent, GT.fi['vc.confirmSubmit']);
  for (const f of btn.listeners.click) await f({});
  assert.deepEqual(sent.map((s) => s.source), ['elamyslahjat']);
  assert.equal(claimed.length, 1); assert.ok(claimed[0].extra.includes('Maksutapa: Lahjakortti – Elämyslahjat'));
});

test('uudet tekstit FI/EN: ei "<", ei emojeita, ei Kiitoskauppaa ohjeessa', () => {
  for (const k of ['vc.detected', 'vc.detectedLow', 'vc.noGuess', 'vc.selected', 'vc.method', 'vc.confirmSubmit', 'vc.fixSourceHint', 'o.useLeadSellers']) for (const L of ['fi', 'en']) {
    const v = GT[L][k]; assert.ok(v && !v.includes('<') && !/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u.test(v), `${L} ${k}`);
  }
  assert.ok(!/Kiitoskauppa/.test(GT.fi['o.useLeadSellers'] + GT.en['o.useLeadSellers']));
});
