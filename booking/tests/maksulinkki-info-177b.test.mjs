// booking_177b: maksulinkkisivun yhteenveto ENNEN maksua. Sivu kutsuu latauksessa vain luku -RPC:tä public_payment_link_info(p_token) ja näyttää
// summan, tilausnumeron, rivit (pvm, klo) ja voimassaolon tai selkeän tilan (maksettu / vanhentunut / korvattu / ei löydy) ilman painiketta.
// Jos RPC puuttuu (404/PGRST202) tai verkko pettää, sivu toimii kuten booking_177:ssä (yleinen kortti + painike).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, cpSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
const rd = (p) => readFileSync(join(root, p), 'utf8');

class Text { constructor(t) { this.nodeType = 3; this.data = String(t); this.parent = null; } get textContent() { return this.data; } }
class El {
  constructor(tag) { this.nodeType = 1; this.tagName = tag.toUpperCase(); this.children = []; this.attrs = {}; this.listeners = {}; this.parent = null; this.className = ''; this.disabled = false; }
  append(...k) { for (const x of k) { const n = x && x.nodeType ? x : new Text(x); n.parent = this; this.children.push(n); } }
  replaceChildren(...k) { this.children = []; this.append(...k); }
  before(...k) { const p = this.parent; const i = p.children.indexOf(this); const ns = k.map((x) => (x && x.nodeType ? x : new Text(x))); ns.forEach((n) => { n.parent = p; }); p.children.splice(i, 0, ...ns); }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this); this.parent = null; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return this.attrs[k] ?? null; }
  addEventListener(t, f) { (this.listeners[t] ||= []).push(f); }
  async click() { for (const f of this.listeners.click || []) await f({ target: this }); }
  set textContent(v) { this.children = [new Text(v)]; }
  get textContent() { return this.children.map((c) => c.textContent).join(''); }
  all() { return this.children.flatMap((c) => (c.nodeType === 1 ? [c, ...c.all()] : [])); }
  q(id) { return this.all().find((e) => e.attrs['data-testid'] === id) || null; }
  qa(id) { return this.all().filter((e) => e.attrs['data-testid'] === id); }
}
globalThis.document = { createElement: (t) => new El(t), createTextNode: (t) => new Text(t), getElementById: () => null };

const tmp = mkdtempSync(join(tmpdir(), 'maksulinkki-info-'));
cpSync(join(root, 'booking/shop/src'), tmp, { recursive: true });
cpSync(join(root, 'booking/shared/sb.js'), join(tmp, 'sb.js'));
writeFileSync(join(tmp, 'package.json'), '{"type":"module"}');
const imp = (f) => import(pathToFileURL(join(tmp, f)).href);
const { PLT } = await imp('pay-link-texts.js');
const { normLinkInfo, linkInfoView, fmtDate } = await imp('pay-link-logic.js');
const { payLinkView } = await imp('pay-link.js');
const TOK = 'c5e82850-2458-4f3e-abcd-1b52cb9e8c17';
const money = (n) => `${Number(n).toFixed(2).replace('.', ',')} €`;
const OPEN = { ok: true, status: 'open', reason: 'open', can_pay: true, amount: 4, amount_cents: 400, currency: 'EUR', order_no: 15655, order_total: 29,
  expires_at: '2026-11-08T09:42:55+00:00', expires_date: '2026-11-08', expires_time: '11:42', paid_at: null,
  items: [{ kind: 'reservation', name: 'Yksityissauna 2 h', name_en: 'Private sauna 2 h', quantity: 1, date: '2026-11-13', start: '17:00', end: '19:00', end_date: '2026-11-13' },
    { kind: 'addon', name: 'Pyyhe', name_en: null, quantity: 2, date: null, start: null, end: null, end_date: null }] };
const neverStart = { start: async () => assert.fail('maksua ei saa aloittaa ilman painallusta') };
const view = async (L, r, api = neverStart) => { const v = payLinkView({ L, token: TOK, api, loadInfo: async () => (r instanceof Error ? Promise.reject(r) : r), money, phone: '010 299 2866', phoneTel: '+358102992866' }); await v.ready; return v; };

test('logiikka: normLinkInfo hyväksyy vain ok-vastauksen tunnetulla tilalla; linkInfoView → painike/viesti', () => {
  for (const bad of [null, undefined, 'x', { ok: false, code: 'rate_limited' }, { ok: true, status: 'outo' }, { ok: true }]) assert.equal(normLinkInfo(bad), null, JSON.stringify(bad));
  const n = normLinkInfo(OPEN);
  assert.equal(n.status, 'open'); assert.equal(n.amount, 4); assert.equal(n.order_no, 15655); assert.equal(n.items.length, 2); assert.equal(n.items[0].start, '17:00');
  assert.equal(normLinkInfo({ ...OPEN, items: [{ name: 'x', date: '13.11.2026', start: '5pm' }] }).items[0].date, null, 'vain YYYY-MM-DD / HH:MI kelpaa');
  assert.deepEqual(linkInfoView(null), { pay: true, msgKey: null, amountKey: null, showSummary: false, validKey: null, retryKey: null }, 'RPC puuttuu → kuten ennen');
  assert.equal(linkInfoView(n).pay, true); assert.equal(linkInfoView(n).validKey, 'sum.valid');
  const cases = [['paid', 'link_paid', 'info.paid', 'sum.paid'], ['paid', 'order_paid', 'info.order_paid', 'sum.link'], ['expired', 'link_expired', 'info.expired', 'sum.link'],
    ['expired', 'payment_cancelled', 'info.cancelled'], ['expired', 'payment_not_pending', 'info.expired'], ['replaced', 'replaced', 'info.replaced'], ['replaced', 'link_stale', 'info.stale'],
    ['not_payable', 'other_provider_started', 'err.other'], ['not_payable', 'order_not_payable', 'err.not_payable'], ['not_payable', 'vismapay_off', 'err.off'], ['not_found', 'not_found', 'err.not_found'],
    ['expired', 'tuntematon', 'info.expired']];
  for (const [status, reason, key, amountKey] of cases) {
    const v = linkInfoView(normLinkInfo({ ...OPEN, status, reason, can_pay: false }));
    assert.equal(v.pay, false, reason); assert.equal(v.msgKey, key, reason); assert.ok(PLT.fi[key] && PLT.en[key], key);
    if (amountKey) assert.equal(v.amountKey, amountKey, reason);
  }
  assert.equal(linkInfoView(normLinkInfo({ ok: true, status: 'not_found', reason: 'not_found', can_pay: false })).showSummary, false);
  assert.equal(linkInfoView(normLinkInfo({ ...OPEN, status: 'expired', reason: 'link_expired' })).validKey, 'sum.expiredAt');
  assert.equal(fmtDate('fi', '2026-11-13'), 'pe 13.11.2026'); assert.equal(fmtDate('en', '2026-11-13'), 'Fri 13 Nov 2026'); assert.equal(fmtDate('fi', 'x'), '');
});

test('näkymä open: summa, tilausnumero, rivit pvm/klo, voimassaolo ennen painiketta; maksua ei aloiteta latauksessa', async () => {
  let v = await view('fi', OPEN);
  assert.equal(v.attrs['data-status'], 'open'); assert.equal(v.attrs['aria-busy'], 'false');
  const order = v.children.map((c) => c.attrs?.['data-testid']).filter(Boolean);
  assert.ok(order.indexOf('pl-summary') < order.indexOf('pl-button'), `yhteenveto ennen painiketta: ${order}`);
  assert.equal(v.q('pl-sum-amount').textContent, '4,00 €');
  assert.match(v.q('pl-order').textContent, /Tilausnumero 15655/);
  const items = v.qa('pl-item');
  assert.equal(items.length, 2); assert.match(items[0].textContent, /Yksityissauna 2 h/); assert.equal(items[0].q('pl-item-when').textContent, 'pe 13.11.2026 klo 17:00–19:00');
  assert.match(items[1].textContent, /Pyyhe · 2 kpl/); assert.equal(items[1].q('pl-item-when'), null);
  assert.equal(v.q('pl-valid').textContent, 'Linkki on voimassa su 8.11.2026 klo 11:42 asti.');
  assert.ok(v.q('pl-button') && !v.q('pl-button').disabled); assert.match(v.q('pl-lead').textContent, /Tarkista tiedot/);
  v = await view('en', OPEN);
  assert.match(v.q('pl-order').textContent, /Order number 15655/); assert.equal(v.qa('pl-item')[0].q('pl-item-when').textContent, 'Fri 13 Nov 2026, 17:00–19:00');
  assert.match(v.qa('pl-item')[0].textContent, /Private sauna 2 h/); assert.match(v.qa('pl-item')[1].textContent, /Pyyhe · 2 pcs/, 'name_en puuttuu → suomenkielinen nimi');
  assert.equal(v.q('pl-valid').textContent, 'The link is valid until Sun 8 Nov 2026 at 11:42.');
  // painallus käynnistää maksun vasta nyt
  const nav = []; let started = 0;
  v = payLinkView({ L: 'fi', token: TOK, api: { start: async () => { started++; return { ok: true, redirect_url: 'https://pay.montonio.com/session/x', amount: 4 }; } }, loadInfo: async () => OPEN, money, navigate: (u) => nav.push(u) });
  assert.equal(v.q('pl-button').disabled, true, 'odottaa yhteenvetoa'); await v.ready; assert.equal(started, 0);
  await v.q('pl-button').click(); assert.equal(started, 1); assert.equal(nav.length, 1);
});

test('näkymä: maksettu / vanhentunut / korvattu / ei löydy → selkeä viesti, ei painiketta (FI+EN)', async () => {
  const cases = [
    ['fi', { status: 'paid', reason: 'link_paid', paid_at: '2026-10-25T10:00:00Z' }, /jo maksettu/, 'Maksettu'],
    ['en', { status: 'paid', reason: 'order_paid' }, /already been paid in full/, 'Link amount'],
    ['fi', { status: 'expired', reason: 'link_expired' }, /vanhentunut/, 'Linkin summa'],
    ['en', { status: 'expired', reason: 'payment_cancelled' }, /was cancelled/, 'Link amount'],
    ['fi', { status: 'replaced', reason: 'replaced' }, /korvattu uudella/, 'Linkin summa'],
    ['en', { status: 'replaced', reason: 'link_stale' }, /amount due on the order has changed/, 'Link amount'],
    ['fi', { status: 'not_payable', reason: 'order_not_payable' }, /ei voi maksaa verkossa/, 'Linkin summa'],
  ];
  for (const [L, over, re, label] of cases) {
    const v = await view(L, { ...OPEN, can_pay: false, ...over });
    assert.equal(v.q('pl-button'), null, `${over.reason}: painike pois`); assert.equal(v.q('pl-lead'), null);
    const st = v.q('pl-state'); assert.equal(st.attrs['data-code'], over.reason); assert.equal(st.attrs['data-status'], over.status); assert.match(st.textContent, re);
    assert.equal(v.q('pl-sum-amount').textContent, '4,00 €'); assert.equal(v.q('pl-summary').children[0].textContent, label);
    const ids = v.all().map((e) => e.attrs['data-testid']).filter(Boolean);
    assert.ok(ids.indexOf('pl-state') < ids.indexOf('pl-summary'), 'tila ennen yhteenvetoa'); assert.ok(!v.q('pl-summary').textContent.includes(PLT[L]['sum.items']), 'ei "Mitä maksat" -otsikkoa');
    assert.ok(v.q('pl-summary').textContent.includes(PLT[L]['sum.itemsOf']));
    assert.ok(v.q('pl-contact').textContent.includes('010 299 2866'));
  }
  let v = await view('fi', { ...OPEN, status: 'expired', reason: 'link_expired', can_pay: false });
  assert.equal(v.q('pl-valid').textContent, 'Linkki vanheni su 8.11.2026 klo 11:42.');
  v = await view('en', { ok: true, status: 'not_found', reason: 'not_found', can_pay: false });
  assert.equal(v.q('pl-button'), null); assert.equal(v.q('pl-summary'), null); assert.match(v.q('pl-state').textContent, /not found/);
});

test('näkymä: RPC puuttuu (404/PGRST202), verkkovirhe, nopeusraja tai outo vastaus → yleinen kortti + painike kuten ennen', async () => {
  const e404 = Object.assign(new Error('Could not find the function booking.public_payment_link_info(p_token) in the schema cache'), { status: 404, code: 'PGRST202' });
  for (const r of [e404, new TypeError('Failed to fetch'), { ok: false, code: 'rate_limited' }, null, { foo: 1 }]) {
    const v = await view('fi', r);
    assert.ok(v.q('pl-button') && !v.q('pl-button').disabled, String(r?.message || JSON.stringify(r)));
    assert.equal(v.q('pl-summary'), null); assert.equal(v.q('pl-state'), null); assert.equal(v.q('pl-lead').textContent, PLT.fi.leadOnline);
    assert.equal(v.attrs['data-status'], undefined);
  }
  // ilman tokenia ei kutsuta RPC:tä
  const v = payLinkView({ L: 'fi', token: null, api: neverStart, loadInfo: async () => assert.fail('ei RPC:tä ilman tokenia') });
  await v.ready; assert.equal(v.q('pl-button'), null); assert.equal(v.q('pl-error').attrs['data-code'], 'invalid_param');
});

test('lähde: latauksessa vain public_payment_link_info (vain luku); maksun aloitus vain painikkeesta; tyylit värit #2B3A30/#F4EFE7/#7A5530', () => {
  const s = rd('booking/shop/src/pay-link.js');
  assert.match(s, /rpc\('public_payment_link_info', \{ p_token: token \}\)/);
  assert.equal((s.match(/api\.start\(/g) || []).length, 1, 'maksun aloitus vain painikkeen käsittelijässä');
  const css = rd('booking/shop/src/shop.css'); const i0 = css.indexOf('/* booking_177b'); const pl = css.slice(i0, css.indexOf('/* booking_', i0 + 5));
  for (const c of pl.match(/#[0-9a-f]{3,6}\b/gi) || []) assert.ok(['#2B3A30', '#F4EFE7', '#7A5530'].includes(c.toUpperCase()), `väri ${c}`);
  assert.doesNotMatch(pl, /blue|#00f|#1d6fd8/i);
  assert.match(pl, /\.pl-card\{max-width:640px;overflow-wrap:anywhere\}/);
});

test('tekstit: pending-import-73 = uudet ui.paylink.* -avaimet FI+EN koodin oletuksista, ei <, ei päällekkäin muiden tiedostojen kanssa', async () => {
  const { readdirSync } = await import('node:fs');
  const R = await import(pathToFileURL(join(root, 'booking/shop/src/text-registry.js')).href);
  const def = new Map(R.collectDefaults().filter((r) => r.id === 'PLT').map((r) => [`${r.key}|${r.lang}`, r.text]));
  const rows = JSON.parse(rd('content/site-texts.pending-import-73.json'));
  assert.equal(rows.length, 36);
  for (const r of rows) {
    assert.ok(r.key.startsWith('ui.paylink.') && ['fi', 'en'].includes(r.lang)); assert.equal(r.text, def.get(`${r.key}|${r.lang}`), `${r.key} ${r.lang}`);
    assert.ok(!r.text.includes('<') && r.max_len >= r.text.length && !/\p{Extended_Pictographic}/u.test(r.text));
  }
  assert.equal(new Set(rows.map((r) => `${r.key}|${r.lang}`)).size, 36);
  for (const k of new Set(rows.map((r) => r.key))) assert.equal(rows.filter((r) => r.key === k).length, 2, `${k}: FI+EN`);
  const keys = new Set(rows.map((r) => r.key));
  for (const f of readdirSync(join(root, 'content')).filter((f) => /^site-texts\.(pending-import|imported).*\.json$/.test(f) && f !== 'site-texts.pending-import-73.json')) {
    const rs = JSON.parse(rd(`content/${f}`)); if (Array.isArray(rs)) for (const r of rs) assert.ok(!keys.has(r?.key), `${r?.key} jo tiedostossa ${f}`);
  }
  assert.equal(rows.find((r) => r.key === 'ui.paylink.sum.when' && r.lang === 'fi').text, '{{var:date}} klo {{var:start}}–{{var:end}}');
});

test('migraatio booking_177: SECURITY DEFINER, search_path, vain anon/authenticated/service_role, ei henkilötietoja, vartijat; rollback poistaa', () => {
  const M = rd('booking/supabase/migrations/20261025104331_booking_177_paylink_info.sql');
  const RB = rd('booking/supabase/rollbacks/20261025104331_booking_177_ROLLBACK.sql');
  const T = rd('booking/supabase/tests/checkout/t177_payment_link_info.sql');
  const fn = M.slice(M.indexOf('create function booking.public_payment_link_info'), M.indexOf('end $function$;'));
  assert.match(fn, /security definer\nset search_path to ''/);
  assert.match(M, /revoke all on function booking\.public_payment_link_info\(uuid\) from public;\ngrant execute on function booking\.public_payment_link_info\(uuid\) to anon, authenticated, service_role;/);
  for (const col of ['email', 'phone', 'address', 'customer_id', 'notes', 'first_name', 'public_token', 'provider_ref\'', 'raw']) assert.ok(!new RegExp(`'${col.replace("'", '')}'`).test(fn.slice(fn.indexOf('return jsonb_build_object(\n'))), `ei ${col} palautuksessa`);
  assert.doesNotMatch(fn, /booking\.customers/, 'ei asiakastaulua');
  assert.match(fn, /booking\._order_rl\('pli', p_token/);
  const md5 = /public_payment_link_info\(uuid\): ([0-9a-f]{32})/.exec(M)[1];
  assert.ok(M.includes(`<> '${md5}'`) && RB.includes(md5) && T.includes(md5), 'sama funktion md5 migraatiossa, rollbackissa ja testissä');
  for (const m of ['703c03c301f5a3008192cdbe65e559e2', '533ac9af831c0c11e1f504e377a17827', 'ec6bf13a3694e5bf9034a80123857246', 'a6b31f93559de53d75a52d8a285f1170', '6d7d56a83470d01e954a78e8767e8366']) assert.ok(M.includes(m), m);
  assert.match(RB, /drop function if exists booking\.public_payment_link_info\(uuid\);/); assert.match(RB, /revoke all on function booking\.public_payment_link_info\(uuid\) from public, anon, authenticated, service_role;/);
  assert.match(T, /^begin;/m); assert.match(T, /^rollback;/m); assert.match(T, /TESTRESULT/);
  assert.equal(createHash('md5').update(M).digest('hex').length, 32);
});
