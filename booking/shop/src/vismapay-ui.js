// Visma Pay -painike ja paluu (?pay=vismapay). Testihuomio näkyy kun palvelin merkitsee tavan testiksi.
import { h } from './gift-ui.js';
import { vt } from './vismapay-texts.js';
import { classifyVisma, safeVismaRedirect } from './vismapay-logic.js';

export function vismaPayBlock({ L, api, opts, amount = '', navigate = (u) => location.assign(u), showLead = true, showAmount = true, showTest = true }) {
  const tx = (k, v) => vt(L, k, v);
  const msg = h('div', { class: 'ord-msg', 'aria-live': 'polite', 'data-testid': 'vp-msg' });
  let busy = false;
  const btn = h('button', { type: 'button', class: 'btn ord-btn', 'data-testid': 'vp-button', text: tx('payBtn'), onclick: async () => {
    if (busy) return;
    busy = true; btn.disabled = true; btn.textContent = tx('payBusy'); msg.replaceChildren();
    let r = null;
    try { r = await api.start(); } catch { r = { ok: false, code: 'network' }; }
    const url = r?.ok ? safeVismaRedirect(r.redirect_url) : null;
    if (url) { navigate(url); return; }
    const code = r?.code || 'generic';
    const key = vt(L, `err.${code}`) !== `err.${code}` ? `err.${code}` : (code === 'network' || code === 'timeout' ? 'err.network' : 'err.generic');
    msg.replaceChildren(h('p', { class: 'bk-error', role: 'alert', 'data-testid': 'vp-error', 'data-code': code, text: tx(key) }));
    busy = false; btn.disabled = false; btn.textContent = tx('payBtn');
  } });
  return h('div', { class: 'vp-block', 'data-testid': 'vp-block' },
    h('h4', { class: 'mp-title ord-method-title', text: tx('payTitle') }),
    showLead ? h('p', { class: 'bk-note', text: tx('payLead') }) : null,
    showAmount && amount ? h('p', { class: 'mp-amount', 'data-testid': 'vp-amount', text: tx('payAmount', { amount }) }) : null,
    showTest && opts?.method?.test === true ? h('p', { class: 'bk-note', 'data-testid': 'vp-test', text: tx('testNote') }) : null,
    btn, msg);
}

export async function runVismaReturn({ api, host, L, getOrder, onDone }) {
  host.replaceChildren(h('section', { class: 'ord-card', role: 'status', 'data-testid': 'vp-return' },
    h('h3', { class: 'ord-card-title', text: vt(L, 'checking') }), h('p', { text: vt(L, 'checkingLead') })));
  let state = 'wait';
  for (let i = 0; i < 8; i++) {
    let r = null;
    try { r = await api.reconcile(); } catch { r = { ok: false, code: 'network' }; }
    state = classifyVisma(r);
    if (state === 'paid' || state === 'review' || state === 'failed') break;
    try {
      const o = await getOrder();
      if (o?.payment_status === 'paid') { state = 'paid'; break; }
    } catch { /* jatketaan */ }
    await new Promise((ok) => setTimeout(ok, 2500));
  }
  const key = state === 'paid' ? 'paid' : state === 'review' ? 'review' : state === 'failed' ? 'failed' : state === 'none' ? 'none' : state === 'net' ? 'net' : 'wait';
  host.replaceChildren(h('section', { class: 'ord-card', role: 'status', 'data-testid': 'vp-return', 'data-state': state },
    h('h3', { class: 'ord-card-title', text: vt(L, key + 'Title') }), h('p', { text: vt(L, key + 'Lead') })));
  if (onDone) await onDone(state);
}
