// Yksi verkkomaksuosio: viisi tapaa, paluu ilman välittäjän nimeä.
import { h } from './gift-ui.js';
import { pt } from './pay-choices-texts.js';
import { onlineChoices, safeOnlineRedirect } from './online-pay-logic.js';

const ERR = { network: 'errNetwork', timeout: 'errNetwork', rate_limited: 'errRate', online_off: 'errOff', vismapay_off: 'errOff', not_configured: 'errOff', maintenance: 'errOff', payment_in_progress: 'errBusy', already_paid: 'errPaid' };

export function onlinePayBlock({ L, api, method, env = {}, amount = '', navigate = (u) => location.assign(u), showTest = true, testid = 'op-method', onFail = null }) {
  const tx = (k, v) => pt(L, k, v);
  const msg = h('div', { class: 'ord-msg', 'aria-live': 'polite', 'data-testid': 'op-msg' });
  const choices = onlineChoices(method);
  let busy = false;
  const buttons = choices.map((c) => {
    const label = L === 'en' ? (c.labelEn || tx(labelKey(c.method))) : (c.label || tx(labelKey(c.method)));
    const btn = h('button', { type: 'button', class: 'btn ord-btn', 'data-testid': `${testid}-${c.method}`, text: label, onclick: () => go(c.method, btn, label) });
    return btn;
  });
  async function go(code, btn, label) {
    if (busy) return;
    busy = true;
    for (const b of buttons) { b.disabled = true; }
    btn.textContent = tx('payBusyOnline');
    msg.replaceChildren();
    let r = null;
    try { r = await api.start(code); } catch { r = { ok: false, code: 'network' }; }
    const url = r?.ok ? safeOnlineRedirect(r.redirect_url) : null;
    if (url) { navigate(url); return; }
    if (r?.ok && (r.dry_run || r.mode === 'dry_run')) {
      msg.replaceChildren(h('p', { class: 'bk-note', role: 'status', 'data-testid': 'op-dryrun', text: tx('payTestOnline') }));
      busy = false; for (const b of buttons) { b.disabled = false; } btn.textContent = label;
      return;
    }
    const key = ERR[r?.code] || 'errGeneric';
    msg.replaceChildren(h('p', { class: 'bk-error', role: 'alert', 'data-testid': 'op-error', 'data-code': r?.code || 'generic', text: tx(key) }));
    busy = false; for (const b of buttons) { b.disabled = false; } btn.textContent = label;
    if (onFail) onFail(r?.code);
  }
  return h('div', { class: 'op-block', 'data-testid': 'op-block' },
    showTest && method?.test === true ? h('p', { class: 'bk-note', 'data-testid': 'op-test', text: tx('payTestOnline') }) : null,
    amount ? h('p', { class: 'mp-amount', 'data-testid': 'op-amount', text: tx('amountDue', { amount }) }) : null,
    h('div', { class: 'op-methods', 'data-testid': 'op-methods' }, ...buttons),
    msg);
}

function labelKey(method) {
  return { paymentInitiation: 'methodBank', cardPayments: 'methodCard', applePay: 'methodApple', googlePay: 'methodGoogle', mobilePay: 'methodWallet' }[method] || 'methodBank';
}

/** Paluu maksusivulta. reconcile (vanha kesken oleva yritys) on valinnainen; näyttö ei nimeä välittäjää. */
export async function runOnlineReturn({ host, L, getOrder, reconcile = null, onDone, intervalMs = 2500, rounds = 8 }) {
  const tx = (k) => pt(L, k);
  const show = (state) => {
    const key = state === 'paid' ? 'returnPaid' : state === 'review' ? 'returnReview' : state === 'failed' ? 'returnFailed' : 'returnWait';
    host.replaceChildren(h('section', { class: 'ord-card', role: 'status', 'data-testid': 'op-return', 'data-state': state },
      h('h3', { text: tx(key) }), h('p', { text: tx(key + 'Lead') })));
  };
  host.replaceChildren(h('section', { class: 'ord-card', role: 'status', 'data-testid': 'op-return', 'data-state': 'checking' },
    h('h3', { text: tx('returnChecking') }), h('p', { text: tx('returnCheckingLead') })));
  let state = 'wait';
  for (let i = 0; i < rounds; i++) {
    if (reconcile) { try { const r = await reconcile(); if (r?.payment_status === 'paid') { state = 'paid'; break; } } catch { /* jatketaan tilauksen kyselyyn */ } }
    try {
      const o = await getOrder();
      if (o?.payment_status === 'paid') { state = 'paid'; break; }
      if (o?.payment_status === 'failed') { state = 'failed'; break; }
    } catch { /* jatketaan */ }
    if (i < rounds - 1) await new Promise((ok) => setTimeout(ok, intervalMs));
  }
  show(state);
  if (state === 'paid' || state === 'failed' || state === 'review') stripPayParam();
  if (onDone) await onDone(state);
}

/** Lopputilan jälkeen pay-parametri pois, jotta sivun lataus ei käynnistä tarkistusta uudelleen. Odottava tila säilyttää sen. */
function stripPayParam() {
  try {
    const u = new URL(location.href);
    if (!u.searchParams.has('pay')) return;
    u.searchParams.delete('pay');
    history.replaceState(history.state, '', u.pathname + u.search + u.hash);
  } catch { /* osoitetta ei voi muuttaa */ }
}
