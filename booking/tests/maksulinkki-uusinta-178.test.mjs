// booking_178: peruttu tai keskeytetty Visma Pay -maksu EI kuluta maksulinkkiä. public_payment_link_info palauttaa silloin status open + last_attempt
// (cancelled | failed); /maksa/-sivu näyttää painikkeen ja kertoo, ettei veloitettu ja että samalla linkillä voi maksaa uudelleen (ui.paylink.info.retry,
// pending-import-74). Tietokantamuutos (vismapay_payment_apply, vismapay_attempts) tarkistetaan tässä staattisesti; toiminta testataan SQL-testissä t178.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, cpSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';

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

const tmp = mkdtempSync(join(tmpdir(), 'maksulinkki-uusinta-'));
cpSync(join(root, 'booking/shop/src'), tmp, { recursive: true });
cpSync(join(root, 'booking/shared/sb.js'), join(tmp, 'sb.js'));
writeFileSync(join(tmp, 'package.json'), '{"type":"module"}');
const imp = (f) => import(pathToFileURL(join(tmp, f)).href);
const { PLT } = await imp('pay-link-texts.js');
const { normLinkInfo, linkInfoView } = await imp('pay-link-logic.js');
const { payLinkView } = await imp('pay-link.js');
const TOK = 'c5e82850-2458-4f3e-abcd-1b52cb9e8c17';
const money = (n) => `${Number(n).toFixed(2).replace('.', ',')} €`;
const OPEN = { ok: true, status: 'open', reason: 'open', can_pay: true, amount: 30, amount_cents: 3000, currency: 'EUR', order_no: 15700, order_total: 30,
  expires_at: '2026-11-08T09:42:55+00:00', expires_date: '2026-11-08', expires_time: '11:42', paid_at: null, last_attempt: null,
  items: [{ kind: 'reservation', name: 'Yksityissauna 2 h', name_en: 'Private sauna 2 h', quantity: 1, date: '2026-11-13', start: '17:00', end: '19:00', end_date: '2026-11-13' }] };
const neverStart = { start: async () => assert.fail('maksua ei saa aloittaa ilman painallusta') };
const view = async (L, r, api = neverStart) => { const v = payLinkView({ L, token: TOK, api, loadInfo: async () => r, money, phone: '010 299 2866', phoneTel: '+358102992866' }); await v.ready; return v; };

test('logiikka: last_attempt vain open-tilassa ja vain cancelled/failed; retryKey vain silloin', () => {
  assert.equal(normLinkInfo(OPEN).last_attempt, null);
  assert.equal(normLinkInfo({ ...OPEN, last_attempt: 'cancelled' }).last_attempt, 'cancelled');
  assert.equal(normLinkInfo({ ...OPEN, last_attempt: 'failed' }).last_attempt, 'failed');
  for (const bad of ['paid', 'CREATED', '<b>', 1, true, {}]) assert.equal(normLinkInfo({ ...OPEN, last_attempt: bad }).last_attempt, null, JSON.stringify(bad));
  assert.equal(normLinkInfo({ ...OPEN, status: 'expired', reason: 'link_expired', can_pay: false, last_attempt: 'cancelled' }).last_attempt, null, 'ei open → ei uusintaa');
  const { last_attempt, ...noKey } = OPEN;   // booking_177-vastaus ilman avainta → kuten ennen
  assert.equal(normLinkInfo(noKey).last_attempt, null); assert.equal(linkInfoView(normLinkInfo(noKey)).retryKey, null);
  assert.equal(linkInfoView(normLinkInfo({ ...OPEN, last_attempt: 'cancelled' })).retryKey, 'info.retry');
  assert.equal(linkInfoView(normLinkInfo({ ...OPEN, last_attempt: 'cancelled' })).pay, true);
  assert.equal(linkInfoView(normLinkInfo({ ...OPEN, status: 'expired', reason: 'payment_cancelled', can_pay: false })).msgKey, 'info.cancelled', 'vanha peruttu linkki: viesti ennallaan');
  assert.equal(linkInfoView(null).retryKey, null);
});

test('näkymä: peruttu yritys → yhteenveto, uusintaviesti ja painike (FI+EN); painallus aloittaa uuden maksun', async () => {
  for (const [L, la, re] of [['fi', 'cancelled', /jäi kesken, eikä sinulta veloitettu mitään\. Voit maksaa uudelleen samalla linkillä\./], ['en', 'failed', /not completed and you were not charged\. You can pay again with this same link\./]]) {
    const v = await view(L, { ...OPEN, last_attempt: la });
    assert.equal(v.attrs['data-status'], 'open');
    const r = v.q('pl-retry'); assert.ok(r, 'uusintaviesti'); assert.match(r.textContent, re); assert.equal(r.attrs['data-code'], la); assert.equal(r.attrs.role, 'status');
    const order = v.children.map((c) => c.attrs?.['data-testid']).filter(Boolean);
    assert.ok(order.indexOf('pl-summary') < order.indexOf('pl-retry') && order.indexOf('pl-retry') < order.indexOf('pl-lead') && order.indexOf('pl-lead') < order.indexOf('pl-button'), `järjestys: ${order}`);
    assert.ok(v.q('pl-button') && !v.q('pl-button').disabled); assert.equal(v.q('pl-state'), null); assert.equal(v.q('pl-sum-amount').textContent, '30,00 €');
  }
  assert.equal((await view('fi', OPEN)).q('pl-retry'), null, 'ei aiempaa yritystä → ei viestiä');
  assert.equal((await view('fi', { ...OPEN, status: 'expired', reason: 'link_expired', can_pay: false, last_attempt: 'cancelled' })).q('pl-retry'), null);
  const nav = []; let started = 0;
  const v = payLinkView({ L: 'fi', token: TOK, api: { start: async () => { started++; return { ok: true, redirect_url: 'https://www.vismapay.com/pbwapi/token/uusi', amount: 30 }; } },
    loadInfo: async () => ({ ...OPEN, last_attempt: 'cancelled' }), money, navigate: (u) => nav.push(u) });
  await v.ready; assert.equal(started, 0); await v.q('pl-button').click(); assert.equal(started, 1); assert.deepEqual(nav, ['https://www.vismapay.com/pbwapi/token/uusi']);
});

test('tekstit: pending-import-74 = ui.paylink.info.retry FI+EN koodin oletuksista, ei <, ei päällekkäin muiden tiedostojen kanssa', async () => {
  const { readdirSync } = await import('node:fs');
  const R = await import(pathToFileURL(join(root, 'booking/shop/src/text-registry.js')).href);
  const def = new Map(R.collectDefaults().filter((r) => r.id === 'PLT').map((r) => [`${r.key}|${r.lang}`, r.text]));
  const rows = JSON.parse(rd('content/site-texts.pending-import-74.json'));
  assert.deepEqual(rows.map((r) => `${r.key}|${r.lang}`), ['ui.paylink.info.retry|fi', 'ui.paylink.info.retry|en']);
  for (const r of rows) {
    assert.equal(r.text, def.get(`${r.key}|${r.lang}`)); assert.equal(r.text, PLT[r.lang]['info.retry']);
    assert.ok(!r.text.includes('<') && r.max_len >= r.text.length && !/\p{Extended_Pictographic}/u.test(r.text) && r.placeholders.length === 0);
  }
  for (const f of readdirSync(join(root, 'content')).filter((f) => /^site-texts\.(pending-import|imported).*\.json$/.test(f) && f !== 'site-texts.pending-import-74.json')) {
    const rs = JSON.parse(rd(`content/${f}`)); if (Array.isArray(rs)) for (const r of rs) assert.notEqual(r?.key, 'ui.paylink.info.retry', `jo tiedostossa ${f}`);
  }
  for (const r of JSON.parse(rd('content/site-texts.fallback.json')).texts) assert.notEqual(r.key, 'ui.paylink.info.retry', 'jo tuotannossa');
});

test('migraatio booking_178: vartijat, uudelleenyritys vain linkeille, tuplamaksusuoja, oikeudet; rollback palauttaa täsmälleen; t178 sama md5', () => {
  const M = rd('booking/supabase/migrations/20261025120000_booking_178_paylink_retry.sql');
  const RB = rd('booking/supabase/rollbacks/20261025120000_booking_178_ROLLBACK.sql');
  const T = rd('booking/supabase/tests/checkout/t178_paylink_retry.sql');
  const orig = { vismapay_payment_apply: 'e5ae519184809a5bc47202a4cd6e787d', vismapay_payment_lookup: '413368e58d3f85eb437814ee836ccf1f', public_payment_link_info: '1fb6153b39daa6f1055c93cac7cb4563' };
  for (const [n, m] of Object.entries(orig)) {
    const nw = new RegExp(`booking\\.${n}\\([^)]*\\): ${m} -> ([0-9a-f]{32})`).exec(M)?.[1];
    assert.ok(nw, `${n}: otsikossa vanha → uusi md5`);
    assert.ok(M.includes(`v <> '${m}'`) && M.includes(`<> '${nw}'`), `${n}: vartija + tarkistus`);
    assert.ok(RB.includes(`v <> '${nw}'`) && RB.includes(`<> '${m}'`), `${n}: rollback vartija + palautuksen tarkistus`);
    assert.ok(T.includes(nw), `${n}: t178 tarkistaa saman md5:n`);
  }
  const trg = /_vismapay_attempt_trg\(\): ([0-9a-f]{32})/.exec(M)[1]; assert.ok(T.includes(trg) && RB.includes(trg));
  for (const dep of ['vismapay_payment_prepare(uuid,uuid)', 'vismapay_payment_event(', 'payment_mark_paid(', 'payment_mark_failed(', '_order_balance(bigint)', '_create_link_payment(', 'vismapay_order_refs(uuid)', 'is_staff()'])
    assert.ok(M.includes(`to_regprocedure('booking.${dep}`), `riippuvuusvartija ${dep}`);
  assert.match(M, /raise exception 'booking_178: tuotannon määrittelyt eivät vastaa odotettua:%\. Ei muutoksia\.'/);
  assert.doesNotMatch(M + RB, /\bpublic\.[a-z_]+/i, 'ei public-skeeman objekteja');
  assert.doesNotMatch(M + RB, /\b(drop|alter|truncate|delete from)\s+(table\s+)?booking\.(payments|orders)\b/i, 'ei muuta olemassa olevia tauluja');
  assert.match(M, /alter table booking\.vismapay_attempts enable row level security;/);
  assert.match(M, /revoke all on table booking\.vismapay_attempts from public, anon, authenticated;/);
  assert.match(M, /revoke all on function booking\.vismapay_payment_apply\(text,text,numeric,jsonb\) from public, anon, authenticated;\ngrant execute on function booking\.vismapay_payment_apply\(text,text,numeric,jsonb\) to service_role;/);
  const apply = M.slice(M.indexOf('CREATE OR REPLACE FUNCTION booking.vismapay_payment_apply'), M.indexOf('$function$;', M.indexOf('CREATE OR REPLACE FUNCTION booking.vismapay_payment_apply')));
  assert.match(apply, /SECURITY DEFINER\n SET search_path TO ''/);
  assert.match(apply, /interval '2 hours'/, 'linkki = voimassa yli 2 h (checkout 60 min ei)');
  assert.match(apply, /for update/i, 'maksurivi lukitaan');
  for (const a of ['VISMAPAY_LATE_PAID', 'VISMAPAY_DUPLICATE_PAID', 'duplicate_paid', 'TUPLAVELOITUS', "'retryable', true"]) assert.ok(apply.includes(a), a);
  assert.match(RB, /drop trigger payments_vismapay_attempt on booking\.payments;/); assert.match(RB, /drop table booking\.vismapay_attempts;/);
  assert.match(T, /^begin;/m); assert.match(T, /^rollback;/m); assert.match(T, /raise exception 'TESTRESULT pass=% fail=% skip=% %'/);
});

test('edge-funktiot ennallaan: vismapay-return/-notify kutsuvat samoja RPC:itä', () => {
  const flow = rd('booking/supabase/functions/_shared/vismapay_flow.ts');
  assert.match(flow, /vismapay_payment_apply/);
  for (const f of ['vismapay-return', 'vismapay-notify']) assert.match(rd(`booking/supabase/functions/${f}/handler.ts`), /vismapay_payment_lookup/);
});
