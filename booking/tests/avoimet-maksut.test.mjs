// HALL-AVOIMET-01: Tilaukset › Avoimet maksut, määrät palvelimelta, Tarkista-merkki, mobiilikorttien kenttäotsikot.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  refundNeedsAction, refundAttentionCount, paylinkChipCounts, openPaymentsAttention, canSeeOpenPayments,
  paylinkTotals, loadOpenPaymentCounts, notifyOpenPaymentsChanged, OPEN_PAYMENTS_EVENT,
} from '../admin/open-payments-logic.js';
import { OP_TEXTS, op } from '../admin/open-payments-texts.js';
import { resolveAdminPath, initialOrdersTab, navGroupById, visibleGroupTabs } from '../admin/admin-navigation.js';
import { reviewAttentionCount } from '../admin/review-logic.js';
import { createAdminMock } from '../admin/options-mock.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = (p) => readFileSync(join(root, p), 'utf8');
const H = 3600000;

function manyLinks(n, { needs = 0, paused = 0 } = {}) {
  const now = Date.now();
  return Array.from({ length: n }, (_, i) => {
    const status = i < needs ? 'needs_action' : i < needs + paused ? 'paused' : 'watching';
    return {
      payment_id: 50000 + i, order_id: 60000 + i, order_no: 70000 + i, amount: 10 + i, customer_name: `Esimerkki ${i}`,
      created_at: new Date(now - (i + 1) * H).toISOString(), link_expires_at: null, link_kind: 'onsite', status, needs_action: status === 'needs_action',
      next_reminder_at: null, paused_at: null, reservation: { product_name: 'Yleinen vuoro', starts_at: new Date(now + 24 * H).toISOString(), count: 1 },
      reminders: [], reminder_count: 0, last_reminder_at: null,
    };
  });
}

test('määrät: sirut ja Tarkista-luku tulevat koko joukosta, ei ensimmäisistä 50 rivistä', async () => {
  const mock = createAdminMock({ delay: 0 });
  mock.state.paylinks = manyLinks(130, { needs: 61, paused: 9 });
  const first = await mock.rpc('admin_list_payment_link_watch', { p_limit: 50 });
  assert.equal(first.rows.length, 50);                 // sivu on 50 riviä...
  const totals = await paylinkTotals(mock.rpc);
  assert.deepEqual(totals, { needs_action: 61, watching: 60, paused: 9 });   // ...mutta määrät ovat koko joukosta
  assert.deepEqual(paylinkChipCounts(totals), { '': 130, needs_action: 61, watching: 60, paused: 9 });
  const counts = await loadOpenPaymentCounts(mock.rpc, (p) => mock.state.perms.includes(p), 'manager');
  assert.equal(counts.links, 61);
  assert.equal(counts.refunds, 2);                      // mockin epäonnistunut + yli 24 h
  assert.equal(counts.total, 63);
  assert.equal(reviewAttentionCount({}, counts.total), 63);
});

test('määrät: haku rajaa myös sirujen määrät, tyhjä ja virheellinen syöte → 0', async () => {
  const mock = createAdminMock({ delay: 0 });
  mock.state.paylinks = manyLinks(80, { needs: 5 });
  assert.deepEqual(await paylinkTotals(mock.rpc, '70003'), { needs_action: 1, watching: 0, paused: 0 });
  assert.deepEqual(paylinkChipCounts(), { '': 0, needs_action: 0, watching: 0, paused: 0 });
  assert.deepEqual(paylinkChipCounts({ needs_action: 'x', watching: -2, paused: 3.9 }), { '': 3, needs_action: 0, watching: 0, paused: 3 });
  assert.equal(openPaymentsAttention({ links: 2, refunds: 3 }), 5);
  assert.equal(openPaymentsAttention(null), 0);
});

test('hyvitykset: toimenpidettä vaatii epäonnistunut tai yli 24 h odottanut; muut eivät', () => {
  assert.equal(refundNeedsAction({ status: 'failed' }), true);
  assert.equal(refundNeedsAction({ status: 'processing', aging: true }), true);
  assert.equal(refundNeedsAction({ status: 'requested', aging: false }), false);
  assert.equal(refundNeedsAction({ needs_action: false, status: 'failed' }), false);   // palvelimen arvo voittaa
  assert.equal(refundAttentionCount({ rows: [{ status: 'failed' }, { aging: true }, { status: 'requested' }] }), 2);
  assert.equal(refundAttentionCount(null), 0);
});

test('oikeudet: vain oman osan määrä lasketaan; virhe yhdessä osassa ei kaada toista', async () => {
  const linksOnly = createAdminMock({ delay: 0, perms: ['payments.manage'] });
  const a = await loadOpenPaymentCounts(linksOnly.rpc, (p) => linksOnly.state.perms.includes(p), 'manager');
  assert.deepEqual([a.links, a.refunds], [1, 0]);
  assert.ok(linksOnly.state.calls.every((c) => c.name !== 'admin_list_open_refunds'));
  const refundsOnly = createAdminMock({ delay: 0, perms: ['bookings.manage'] });
  const b = await loadOpenPaymentCounts(refundsOnly.rpc, (p) => refundsOnly.state.perms.includes(p), 'manager');
  assert.deepEqual([b.links, b.refunds], [0, 2]);
  const none = await loadOpenPaymentCounts(async () => { throw new Error('ei'); }, () => true, 'admin');
  assert.deepEqual(none, { links: 0, refunds: 0, total: 0 });
  assert.equal(canSeeOpenPayments(() => false, 'manager'), false);
  assert.equal(canSeeOpenPayments(() => false, 'admin'), true);
});

test('toimenpiteen jälkeen tapahtuma päivittää merkin', () => {
  const seen = [];
  class Win { dispatchEvent(e) { seen.push(e.type); return true; } }
  Win.prototype.CustomEvent = class { constructor(t) { this.type = t; } };
  const win = new Win();
  notifyOpenPaymentsChanged(win);
  assert.deepEqual(seen, [OPEN_PAYMENTS_EVENT]);
  assert.doesNotThrow(() => notifyOpenPaymentsChanged(null));
  assert.match(src('admin/admin.js'), /OPEN_PAYMENTS_EVENT, \(\) => \{ void refreshReviewBadge\(\)/);
  for (const f of ['paylink-watch', 'refund-watch']) assert.match(src(`admin/views/${f}.js`), /notifyOpenPaymentsChanged\(\)/);
});

test('navigaatio: vanhat osoitteet avaavat Tilaukset › Avoimet maksut, Talous-ryhmässä ei enää erillisiä välilehtiä', () => {
  for (const p of ['seurattavat-maksut', 'hyvitysten-seuranta']) {
    assert.deepEqual(resolveAdminPath(p), { path: 'tilaukset', legacyReservations: false, groupId: null, tabId: 'open-payments' });
  }
  const cash = navGroupById('cash');
  const all = (p) => ['payments.manage', 'bookings.manage', 'invoices.manage', 'giftcards.manage'].includes(p);
  assert.deepEqual(visibleGroupTabs(cash, all).map((t) => t.id), ['talous', 'laskut']);
  assert.equal(initialOrdersTab({ canOpenPayments: true, tabId: 'open-payments' }), 'open-payments');
  assert.equal(initialOrdersTab({ canOpenPayments: true, query: new URLSearchParams('tab=open-payments') }), 'open-payments');
  assert.equal(initialOrdersTab({ canOpenPayments: false, tabId: 'open-payments' }), 'orders');   // ei oikeutta: ei välilehteä
  assert.equal(initialOrdersTab({ canOpenPayments: true, canOrders: false, tabId: 'open-payments' }), 'open-payments');
  assert.equal(initialOrdersTab({ canOpenPayments: true }), 'orders');
  assert.equal(initialOrdersTab({ legacyReservations: true, canOpenPayments: true, tabId: 'open-payments' }), 'reservations');
});

test('näkymät: välilehti, kaksi osiota, palvelinsuodatus, näytä lisää, kenttäotsikot ja nimetyt kentät', () => {
  const orders = src('admin/views/orders.js');
  assert.match(orders, /OPEN_PAYMENTS_TAB/);
  assert.match(orders, /open-payments-count/);
  assert.match(src('admin/views/open-payments.js'), /embedded: true/);
  const pw = src('admin/views/paylink-watch.js');
  assert.match(pw, /paylinkTotals\(rpc, st\.search\)/);
  assert.match(pw, /status: st\.status \|\| null/);       // suodatus palvelimella
  assert.match(pw, /paylink-load-more/);
  assert.match(pw, /'aria-label': pw\('ui\.admin\.paylink_watch\.search'\)/);   // hakukentällä oma nimi
  assert.doesNotMatch(pw, /'aria-label': 'Lisää toimintoja'/);                   // ⋯-valikon nimi tekstistä
  assert.match(pw, /op\('ui\.admin\.open_payments\.more_actions'\)/);
  const rw = src('admin/views/refund-watch.js');
  for (const k of ['amount', 'customer', 'order', 'status', 'age', 'provider', 'actions']) assert.match(rw, new RegExp(`'data-label': L\\('${k}'\\)`));
  const rv = src('admin/views/review.js');
  assert.match(rv, /review-open_payments/);
  assert.match(rv, /#\/tilaukset\?tab=open-payments/);
});

test('tekstit: pending-import-169 vastaa OP_TEXTS:ää, FI+EN, ei päällekkäin muiden tuontien kanssa', () => {
  const rows = JSON.parse(src('../content/site-texts.pending-import-169.json'));
  assert.deepEqual(Object.keys(OP_TEXTS.fi).sort(), Object.keys(OP_TEXTS.en).sort());
  assert.equal(rows.length, Object.keys(OP_TEXTS.fi).length * 2);
  const seen = new Set();
  for (const r of rows) {
    assert.equal(seen.has(`${r.key}|${r.lang}`), false, r.key); seen.add(`${r.key}|${r.lang}`);
    assert.equal(r.text, OP_TEXTS[r.lang][r.key], r.key);
    assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain');
    assert.ok(r.max_len >= r.text.length, r.key);
    assert.deepEqual(r.placeholders, [...r.text.matchAll(/\{\{var:[a-z0-9_]+\}\}/g)].map((m) => m[0]), r.key);
    assert.ok(r.reason.startsWith('HALL-AVOIMET-01'));
  }
  for (const f of readdirSync(join(root, '../content'))) {
    if (!/^site-texts\.(pending-import-|pending-propose-|imported)/.test(f) || f === 'site-texts.pending-import-169.json' || !f.endsWith('.json')) continue;
    const j = JSON.parse(readFileSync(join(root, '../content', f), 'utf8'));
    for (const r of Array.isArray(j) ? j : j.texts || []) assert.equal(seen.has(`${r.key}|${r.lang}`), false, `${r.key} on jo tiedostossa ${f}`);
  }
  assert.equal(op('ui.admin.open_payments.load_more', { n: 7 }, 'fi'), 'Näytä lisää (7 jäljellä)');
  assert.equal(op('ui.admin.open_payments.load_more', { n: 7 }, 'en'), 'Show more (7 left)');
  for (const t of Object.values(OP_TEXTS.fi).concat(Object.values(OP_TEXTS.en))) assert.doesNotMatch(t, /<|https?:|[\u{1F300}-\u{1FAFF}]/u);
});
