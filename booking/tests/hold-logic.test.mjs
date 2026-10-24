import test from 'node:test';
import assert from 'node:assert/strict';
import { normCheckout, isHoldView, nextPollIn, POLL, leftFromServer, createHoldClock, clockText, createAnnouncer } from '../shop/src/hold-logic.js';

const now = '2026-10-24T09:00:00Z';
const in15 = '2026-10-24T09:15:00Z';

test('varaukseton lahjakortti: awaiting_payment ilman paikkavarausta, laskuria tai nollapollausta', () => {
  const co = normCheckout({ checkout_state: 'awaiting_payment', hold_expires_at: null, seconds_left: null, server_now: now, remaining_amount: 100 });
  assert.equal(co.state, 'awaiting_payment');
  assert.equal(co.expiresAt, null);
  assert.equal(co.secondsLeft, null);
  assert.equal(co.remaining, 100);
  assert.equal(isHoldView(co), false);
  assert.equal(leftFromServer(co), null);
  assert.equal(nextPollIn(co, { leftMs: 0 }), null);
});

test('ajanvarauksellinen tilaus: 15 minuutin paikkavaraus näkyy ja päivittyy', () => {
  const co = normCheckout({ checkout_state: 'awaiting_payment', hold_expires_at: in15, server_now: now, seconds_left: 900, remaining_amount: 29 });
  assert.equal(isHoldView(co), true);
  assert.equal(leftFromServer(co), 900_000);
  assert.equal(nextPollIn(co, { leftMs: 900_000 }), POLL.awaitingMs);
  let elapsed = 0;
  const clock = createHoldClock(co, () => elapsed);
  assert.equal(clockText(clock.left()), '15:00');
  elapsed = 2000;
  assert.equal(clockText(clock.left()), '14:58');
  assert.equal(nextPollIn(co, { leftMs: 0 }), POLL.zeroRetryMs);
});

test('sekuntipohjainen pidon määräaika näyttää laskurin myös ilman päivämääräleimaa', () => {
  const co = normCheckout({ checkout_state: 'awaiting_payment', hold_expires_at: null, seconds_left: 600 });
  assert.equal(co.expiresAt, null);
  assert.equal(isHoldView(co), true);
  assert.equal(leftFromServer(co), 600_000);
});

test('preliminary-kumppanilahjakortti säilyttää oman avoimen pitonäkymänsä', () => {
  const co = normCheckout({ checkout_state: 'preliminary', hold_kind: 'preliminary', hold_expires_at: in15, server_now: now });
  assert.equal(co.preliminary, true);
  assert.equal(isHoldView(co), true);
  assert.equal(nextPollIn(co), null);
});

test('payment processing ja päättyneet varaukset käyttävät edelleen alkuperäisiä pollausvälejä', () => {
  const co = normCheckout({ checkout_state: 'processing_payment', payment_in_progress: true });
  assert.equal(isHoldView(co), true);
  assert.equal(nextPollIn(co), POLL.processingMs);
  assert.equal(nextPollIn(co, { processingElapsed: POLL.processingLongAfterMs }), POLL.processingSlowMs);
  assert.equal(isHoldView(normCheckout({ checkout_state: 'expired' })), true);
  assert.equal(isHoldView(normCheckout({ checkout_state: 'confirmed' })), false);
  assert.equal(isHoldView(null), false);
});

test('ruudunlukijan porrastetut ilmoitukset ovat ennallaan', () => {
  const a = createAnnouncer();
  assert.equal(a.next(4 * 60_000), 300_000);
  assert.equal(a.next(4 * 60_000), null);
  assert.equal(a.next(55_000), 60_000);
  assert.equal(a.next(25_000), 30_000);
});
