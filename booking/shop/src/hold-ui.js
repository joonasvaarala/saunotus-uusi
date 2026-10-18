// Pitopaneeli (§17): laskuri + ohjeteksti + tilaviestit. Käytetään vahvistussivulla ja tilaussivulla (sama komponentti).
// Saavutettavuus: näkyvä laskuri on role="timer" aria-live="off" (ei lue joka sekunti); erillinen piilotettu role="status" ilmoittaa vain portaissa (5 min, 2 min, 1 min, 30 s) ja tilanmuutoksissa.
// Ei vilkkuvaa/animoitua; alle minuutin tila näkyy väri- + lihavointimuutoksena. Laskuri ei estä maksua: processing_payment-tilassa ei ole vanhenemista lainkaan, vain viesti ja kyselyt.
import { h } from './gift-ui.js';
import { ht, HT } from './hold-texts.js';
import { createHoldClock, clockText, createAnnouncer, spoken, nextPollIn, changed, POLL } from './hold-logic.js';

let seq = 0;
// opts: { L, co (normCheckout), minutes, giftUsed, newHref, refresh(): Promise<co|null> | null, onChange(co), fmtDate(ms), mono, timers }
// → { node, stop() }. refresh = null → ei kyselyitä (esim. MobilePay-paluun pollaus hoitaa tilan).
export function holdPanel({ L = 'fi', co, minutes = 15, giftUsed = false, newHref = '#', refresh = null, onChange = () => {}, fmtDate = (t) => new Date(t).toLocaleDateString(L === 'en' ? 'en-GB' : 'fi-FI'), mono, timers = { setTimeout: (f, ms) => setTimeout(f, ms), clearTimeout: (id) => clearTimeout(id), setInterval: (f, ms) => setInterval(f, ms), clearInterval: (id) => clearInterval(id) } } = {}) {
  const tx = (k, v) => ht(L, k, v), id = `hold-${++seq}`;
  const kind = co.expired ? 'expired' : co.preliminary ? 'preliminary' : co.processing ? 'processing' : 'awaiting';
  let cur = co, stopped = false, pollT = null, tickT = null, longShown = false;
  const t0 = mono ? mono() : (typeof performance !== 'undefined' ? performance.now() : Date.now());
  const monoNow = mono || (() => (typeof performance !== 'undefined' ? performance.now() : Date.now()));
  const clock = createHoldClock(co, mono);
  const ann = createAnnouncer();
  const kids = [h('h3', { id: `${id}-t`, tabindex: '-1', class: kind === 'awaiting' ? 'sr-only' : '', text: tx(`title.${kind}`) })];   // awaiting: otsikko vain ruudunlukijalle (sivun h2 + tilabadge sanovat saman) → kompakti banneri; muut tilat: näkyvä pieni otsikko   // tabindex -1: tilan vaihtuessa fokus siirretään otsikkoon (ruudunlukija lukee uuden tilan)
  let timeEl = null, labelEl = null, announce = null, msgEl = null, recheckBtn = null;
  if (kind === 'awaiting') {
    kids.push(h('p', { class: 'bk-hold-must', 'data-testid': 'hold-must', text: tx('mustPay', { minutes }) }));   // selkeä 15 min -ohje (mustPay); ei toistavaa lead-tekstiä (poistettu)
    labelEl = h('span', { class: 'bk-hold-label', id: `${id}-l`, text: tx('timerLabel') });
    timeEl = h('span', { class: 'bk-hold-time', role: 'timer', 'aria-live': 'off', 'aria-labelledby': `${id}-l`, 'data-testid': 'hold-timer', text: clockText(clock.left()) });
    announce = h('p', { class: 'sr-only', role: 'status', 'aria-live': 'polite', 'aria-atomic': 'true', 'data-testid': 'hold-announce' });
    kids.push(h('p', { class: 'bk-hold-clock' }, labelEl, ' ', timeEl), announce);
  } else if (kind === 'processing') {
    msgEl = h('p', { class: 'bk-hold-msg', role: 'status', 'data-testid': 'hold-msg', text: tx('processing') });
    recheckBtn = h('button', { type: 'button', class: 'btn light ord-btn', hidden: true, 'data-testid': 'hold-recheck', onclick: () => poll(true), text: tx('recheck') });
    kids.push(msgEl, recheckBtn);
  } else if (kind === 'preliminary') {
    kids.push(h('p', { class: 'bk-hold-msg', 'data-testid': 'hold-msg', text: co.expiresAt != null ? tx('preliminary', { date: fmtDate(co.expiresAt) }) : tx('preliminaryNoDate') }));
  } else {
    kids.push(h('p', { class: 'bk-hold-msg', 'data-testid': 'hold-msg', text: tx('expired', { minutes }) }));
    if (giftUsed) kids.push(h('p', { class: 'bk-hold-msg', 'data-testid': 'hold-gift-returned', text: tx('expiredGift') }));
    kids.push(h('p', { class: 'bk-actions' }, h('a', { class: 'btn gold', href: newHref, 'data-testid': 'hold-new', text: tx('newBooking') })));
  }
  const node = h('section', { class: `ord-card bk-hold bk-hold-${kind}`, 'aria-labelledby': `${id}-t`, 'data-testid': 'hold-panel', 'data-state': co.state }, kids);

  function render() {
    if (kind !== 'awaiting' || !timeEl) return;
    const left = clock.left(), txt = clockText(left);
    if (timeEl.textContent !== txt) timeEl.textContent = txt;
    node.classList.toggle('low', left > 0 && left <= 60000);
    const zero = left <= 0;
    if (zero && labelEl.textContent !== tx('timerChecking')) labelEl.textContent = tx('timerChecking');
    if (!zero && labelEl.textContent !== tx('timerLabel')) labelEl.textContent = tx('timerLabel');
    const step = ann.next(left);
    if (step != null) announce.textContent = tx('announce.minutes', { time: spoken(L, step, ht) });
  }
  async function poll(manual = false) {
    if (stopped || !refresh) return;
    clearTimer();
    let next = null; try { next = await refresh(); } catch { next = null; }
    if (stopped) return;
    if (next) {
      if (changed(cur, next)) { stop(); onChange(next); return; }
      cur = next; if (kind === 'awaiting') clock.sync(next);
    }
    schedule();
  }
  function clearTimer() { if (pollT != null) { timers.clearTimeout(pollT); pollT = null; } }
  function schedule() {
    if (stopped || !refresh) return;
    clearTimer();
    const elapsed = monoNow() - t0;
    if (kind === 'processing' && elapsed >= POLL.processingLongAfterMs && !longShown) { longShown = true; msgEl.textContent = tx('processingLong'); recheckBtn.hidden = false; }
    const wait = nextPollIn(cur, { leftMs: clock.left(), processingElapsed: elapsed });
    if (wait != null) pollT = timers.setTimeout(() => poll(), wait);
  }
  function onVisible() { if (typeof document !== 'undefined' && document.visibilityState === 'visible') poll(); }
  function stop() { stopped = true; clearTimer(); if (tickT != null) timers.clearInterval(tickT); tickT = null; if (typeof document !== 'undefined') document.removeEventListener('visibilitychange', onVisible); }

  if (kind === 'awaiting' || kind === 'processing') {
    if (kind === 'awaiting') { tickT = timers.setInterval(() => { render(); if (clock.left() <= 0 && refresh && pollT == null) schedule(); }, 1000); render(); }
    if (typeof document !== 'undefined') document.addEventListener('visibilitychange', onVisible);
    schedule();
  }
  return { node, stop, clock, poll };
}
