// Tilaussivun lahjakorttiosat: "Käytä lahjakortti" (public_apply_gift_card), ostetut kortit (public_get_order_gift_cards) ja koodin näyttö (public_get_gift_card).
// Sopimus: KOODARI_talous_A_D_fi.md §13.2. Näytetään vain kun palvelin sallii (redeem_enabled / tilauksella kortteja); muuten ei mitään.
import { functionUrl } from './sb.js';
import { GT } from './gift-texts.js';
import { pdfHref } from './gift-api.js';
import { h, makeFmt, field } from './gift-ui.js';
import * as G from './gift-logic.js';

const badgeClass = (st) => (st === 'active' ? 'st-confirmed' : st === 'pending_payment' || st === 'pending_verification' ? 'st-pending' : st === 'cancelled' || st === 'expired' ? 'st-expired' : '');

// Käytä lahjakortti: näytetään kun redeem_enabled, maksamatonta on ja tilauksella ei ole lahjakorttirivejä (lahjakortilla ei osteta lahjakorttia)
export function redeemSection({ L, api, token, onApplied }) {
  const F = makeFmt(L), { tx, money } = F;
  const code = h('input', { type: 'text', autocomplete: 'off', autocapitalize: 'characters', spellcheck: 'false', maxlength: 24, placeholder: 'HHXX-XXXX-XXXX', 'data-testid': 'gc-code' });
  const fc = field({ label: tx('o.code'), control: code, hint: tx('balHint'), name: 'rc' });
  const amt = h('input', { type: 'text', inputmode: 'decimal', autocomplete: 'off', 'data-testid': 'gc-amount' });
  const fa = field({ label: tx('o.amount'), control: amt, hint: tx('o.amountHint'), name: 'ra' });
  code.addEventListener('input', () => { const v = G.formatCodeTyping(code.value); if (v !== code.value) { code.value = v; try { code.setSelectionRange(v.length, v.length); } catch { /* ei tarvita */ } } fc.setError(''); });
  amt.addEventListener('input', () => fa.setError(''));
  const msg = h('div', { class: 'ord-msg gc-msg', 'aria-live': 'polite', 'data-testid': 'gc-msg' });
  const btn = h('button', { type: 'submit', class: 'btn ord-btn', 'data-testid': 'gc-apply', text: tx('o.apply') });
  const form = h('form', { class: 'ord-form bk-form', novalidate: true, onsubmit: async (ev) => {
    ev.preventDefault(); if (btn.disabled) return; msg.replaceChildren();
    if (!G.codeComplete(code.value)) { fc.setError(tx('err.code_incomplete')); code.focus(); return; }
    let amount = null;
    if (amt.value.trim()) { amount = G.parseAmount(amt.value); if (amount == null || amount <= 0) { fa.setError(tx('o.amountErr')); amt.focus(); return; } }
    btn.disabled = true; btn.textContent = tx('o.applying');
    try {
      const r = await api.apply({ token, code: code.value, amount });
      if (r?.ok) {
        const left = r.gift_card?.balance ?? 0;
        const text = [left > 0 ? tx('o.done', { amount: money(r.amount), balance: money(left) }) : tx('o.doneEmpty', { amount: money(r.amount) }), r.balance && +r.balance.unpaid <= 0 ? tx('o.paidFull') : r.balance ? tx('o.restDue', { unpaid: money(r.balance.unpaid) }) : ''].filter(Boolean).join(' ');
        return onApplied(text);
      }
      msg.append(h('p', { class: 'bk-error', role: 'alert', text: r?.notReady ? tx('notReady') : (GT[L][`err.${r?.code}`] ? tx(`err.${r.code}`) : tx('err.generic')) }));
    } catch { msg.append(h('p', { class: 'bk-error', role: 'alert', text: tx('err.generic') })); }
    btn.disabled = false; btn.textContent = tx('o.apply');
  } }, fc.wrap, fa.wrap, btn, msg);
  return h('section', { class: 'ord-card', 'aria-labelledby': 'ord-gc', 'data-testid': 'gc-redeem' }, h('h3', { id: 'ord-gc', text: tx('o.useTitle') }), h('p', { class: 'bk-note', text: tx('o.useLead') }), form);
}

// Ostetut kortit + koodin näyttö
export function cardsSection({ S, L, api, cards }) {
  const F = makeFmt(L), { tx, money, date } = F;
  const items = cards.map((c) => {
    const panel = h('div', { class: 'gc-reveal', hidden: true, 'data-testid': 'gc-reveal' });
    const status = GT[L][`cst.${c.status}`] ? tx(`cst.${c.status}`) : c.status;
    // Toimitusvalinta (sopimus §13.11): suoraan saajalle toimitettavan kortin koodia ja PDF-linkkiä ei näytetä ostajalle (yllätyslahja)
    const rec = c.delivery_to === 'recipient', hhmm = (t) => String(t || '09:00').replace(/^0/, '');
    const dlvNote = rec ? (c.delivered_at ? tx('o.dlvRecipientSent', { date: date(G.helsinkiNow(new Date(c.delivered_at)).date) }) : c.deliver_on ? tx('o.dlvRecipientAt', { date: date(c.deliver_on), time: hhmm(c.deliver_time) }) : tx('o.dlvRecipientNow'))
      : (c.delivered_at ? tx('o.dlvBuyerSent', { date: date(G.helsinkiNow(new Date(c.delivered_at)).date) }) : !c.ready ? tx('o.dlvBuyer') : '');
    const btn = h('button', { type: 'button', class: 'btn light ord-btn', 'data-testid': 'gc-show', text: tx('o.showCode'), 'aria-expanded': 'false', onclick: async () => {
      if (!panel.hidden) { panel.hidden = true; btn.textContent = tx('o.showCode'); btn.setAttribute('aria-expanded', 'false'); return; }
      btn.disabled = true;
      try {
        const r = await api.card(c.token);
        if (!r?.ok) { panel.replaceChildren(h('p', { class: r?.code === 'not_ready' ? 'bk-note' : 'bk-error', role: 'alert', text: r?.code === 'not_ready' ? tx('o.codeNotReady') : tx('o.codeError') })); }
        else {
          const pdf = pdfHref(S, c.token, functionUrl, L);
          panel.replaceChildren(h('p', { class: 'gc-code', 'data-testid': 'gc-codetext', text: r.code }), h('dl', { class: 'bk-sum' }, h('dt', { text: tx('o.codeBalance') }), h('dd', { text: money(r.balance) }), r.greeting ? [h('dt', { text: tx('o.codeGreeting') }), h('dd', { class: 'gc-greet', text: r.greeting })] : []),
            h('div', { class: 'bk-actions' }, h('button', { type: 'button', class: 'btn light ord-btn', text: tx('o.copy'), onclick: async (ev) => { try { await navigator.clipboard.writeText(r.code); ev.currentTarget.textContent = tx('o.copied'); } catch { /* leikepöytä ei käytettävissä: koodi on näkyvissä */ } } }),
              pdf ? h('a', { class: 'btn ord-btn', 'data-testid': 'gc-pdf', href: pdf, target: '_blank', rel: 'noopener', text: tx('o.pdf') }) : null));
        }
        panel.hidden = false; btn.textContent = tx('o.hideCode'); btn.setAttribute('aria-expanded', 'true');
      } catch { panel.replaceChildren(h('p', { class: 'bk-error', role: 'alert', text: tx('o.codeError') })); panel.hidden = false; }
      finally { btn.disabled = false; }
    } });
    return h('li', { class: 'gc-ocard', 'data-testid': 'gc-card' },
      h('span', { class: 'ord-l-main' }, h('strong', { text: c.package_name || c.package_code }), ' ', h('span', { class: `ord-badge ${badgeClass(c.status)}`, text: status })),
      h('span', { class: 'ord-l-sum', text: money(c.amount) }),
      h('span', { class: 'ord-l-meta', text: [c.recipient_name ? `${tx('o.cardTo')}: ${c.recipient_name}` : '', c.valid_to ? `${tx('o.cardValidTo')}: ${date(c.valid_to)}` : tx('o.cardNotReady')].filter(Boolean).join(' · ') }),
      dlvNote ? h('span', { class: 'ord-l-meta gc-dlvnote', 'data-testid': 'gc-delivery', text: dlvNote }) : null,
      rec ? (c.ready ? h('span', { class: 'ord-l-meta gc-dlvnote', text: tx('o.dlvSurprise') }) : null) : (c.ready ? h('div', { class: 'gc-oact' }, btn, panel) : null));
  });
  return h('section', { class: 'ord-card', 'aria-labelledby': 'ord-gcs', 'data-testid': 'gc-cards' }, h('h3', { id: 'ord-gcs', text: tx('o.cardsTitle') }), h('p', { class: 'bk-note', text: tx('o.cardsLead') }), h('ul', { class: 'ord-lines gc-olist' }, items));
}
