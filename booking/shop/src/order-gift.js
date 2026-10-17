// Tilaussivun lahjakorttiosat: "Käytä lahjakortti" (public_apply_gift_card), ostetut kortit (public_get_order_gift_cards) ja koodin näyttö (public_get_gift_card).
// Sopimus: KOODARI_talous_A_D_fi.md §13.2. Näytetään vain kun palvelin sallii (redeem_enabled / tilauksella kortteja); muuten ei mitään.
import { functionUrl } from './sb.js';
import { GT } from './gift-texts.js';
import { pdfHref } from './gift-api.js';
import { h, makeFmt, field } from './gift-ui.js';
import * as G from './gift-logic.js';

const badgeClass = (st) => (st === 'active' ? 'st-confirmed' : st === 'pending_payment' || st === 'pending_verification' ? 'st-pending' : st === 'cancelled' || st === 'expired' ? 'st-expired' : '');

// Yksi kenttä "Lahjakortin koodi" (sopimus §13.12): public_resolve_gift_code kertoo mikä koodi on.
//   oma kortti → nykyinen lunastus (public_apply_gift_card, summa valinnainen); tuntematon → lähdevalinta (Elämyslahjat / Kokemuskauppa / Kiitoskauppa / Offerilla, esivalinta suggested_source)
//   → public_submit_voucher_claim → selkeä vahvistusteksti. Näytetään kun redeem_enabled, maksamatonta on ja tilauksella ei ole lahjakorttirivejä (lahjakortilla ei osteta lahjakorttia).
// onApplied(text) = oma kortti käytetty; onClaimed({ text, extra }) = kumppanin lahjakortti lähetetty lunastettavaksi (tilaus + pyyntölista ladataan uudelleen).
export function redeemSection({ L, api, token, onApplied, onClaimed }) {
  const F = makeFmt(L), { tx, pick } = F;
  const has = (k) => GT[L][k] != null;
  const errText = (code) => (code === 'notReady' ? tx('notReady') : tx(G.errorKey(code, has)));
  const code = h('input', { type: 'text', autocomplete: 'off', autocapitalize: 'characters', spellcheck: 'false', maxlength: 40, 'data-testid': 'gc-code' });
  const fc = field({ label: tx('o.code'), control: code, hint: tx('o.codeHint'), name: 'rc' });
  const amt = h('input', { type: 'text', inputmode: 'decimal', autocomplete: 'off', 'data-testid': 'gc-amount' });
  const fa = field({ label: tx('o.amount'), control: amt, hint: tx('o.amountHint'), name: 'ra' });
  const msg = h('div', { class: 'ord-msg gc-msg', 'aria-live': 'polite', 'data-testid': 'gc-msg' });
  const btn = h('button', { type: 'submit', class: 'btn ord-btn', 'data-testid': 'gc-apply', text: tx('o.apply') });
  const choose = h('div', { class: 'vc-choose', hidden: true, 'data-testid': 'vc-choose' });
  const hideChoose = () => { choose.hidden = true; choose.replaceChildren(); };
  code.addEventListener('input', () => { fc.setError(''); msg.replaceChildren(); hideChoose(); });
  amt.addEventListener('input', () => fa.setError(''));
  const showError = (text) => msg.replaceChildren(h('p', { class: 'bk-error', role: 'alert', text }));

  // lähdevalinta (tuntematon koodi, kumppanilunastus päällä)
  function showChoose(out) {
    const sel = out.suggested;
    const radios = out.sources.map((s, i) => { const id = `vc-src-${i}`; return h('label', { class: 'gc-radio vc-opt', for: id }, h('input', { type: 'radio', name: 'vc-source', id, value: s.code, checked: s.code === sel ? true : null, 'data-testid': `vc-src-${s.code}` }), h('span', { text: pick(s, 'label') })); });
    const chosen = () => choose.querySelector('input[name=vc-source]:checked')?.value || '';
    const cmsg = h('div', { class: 'ord-msg', 'aria-live': 'polite', 'data-testid': 'vc-msg' });
    const go = h('button', { type: 'button', class: 'btn ord-btn', 'data-testid': 'vc-submit', text: tx('vc.submit'), onclick: async () => {
      cmsg.replaceChildren();
      const src = chosen(); if (!src) { cmsg.append(h('p', { class: 'bk-error', role: 'alert', text: tx('vc.err.invalid_source') })); return; }
      go.disabled = true; go.textContent = tx('vc.submitting');
      try {
        const r = await G.submitClaim({ api, token, code: code.value, source: src });
        if (r.type === 'claimed') {
          const extra = [tx('vc.doneRef', { source: r.sourceLabel, code: r.codeMasked }), r.mismatch ? tx('vc.mismatch') : ''].filter(Boolean).join(' ');
          return onClaimed({ text: tx('vc.done'), extra, claimNo: r.claimNo });
        }
        cmsg.append(h('p', { class: 'bk-error', role: 'alert', text: errText(r.code) }));
      } catch { cmsg.append(h('p', { class: 'bk-error', role: 'alert', text: tx('err.generic') })); }
      go.disabled = false; go.textContent = tx('vc.submit');
    } });
    const change = h('button', { type: 'button', class: 'btn light ord-btn', 'data-testid': 'vc-change', text: tx('vc.change'), onclick: () => { hideChoose(); code.focus(); } });
    const title = h('h4', { class: 'vc-ctitle', tabindex: '-1', text: tx('vc.chooseTitle') });
    choose.replaceChildren(title, h('p', { class: 'bk-note', text: tx('vc.chooseLead') }),
      h('p', { class: 'vc-code', 'data-testid': 'vc-codeis', text: tx('vc.codeIs', { code: G.normalizeCode(code.value) }) }),
      h('fieldset', { class: 'gc-dlv vc-src' }, h('legend', { text: tx('vc.sourceLegend') }), h('div', { class: 'gc-radios vc-radios' }, radios)),
      sel ? h('p', { class: 'bk-note', 'data-testid': 'vc-suggest', text: tx('vc.suggest', { source: pick(out.sources.find((x) => x.code === sel), 'label') }) }) : null,
      h('div', { class: 'vc-actions' }, go, change), cmsg);
    choose.hidden = false; title.focus({ preventScroll: false });
  }

  const form = h('form', { class: 'ord-form bk-form', novalidate: true, onsubmit: async (ev) => {
    ev.preventDefault(); if (btn.disabled) return; msg.replaceChildren(); hideChoose();
    if (!G.codeValid(code.value)) { fc.setError(tx('vc.err.invalid_code')); code.focus(); return; }
    let amount = null;
    if (amt.value.trim()) { amount = G.parseAmount(amt.value); if (amount == null || amount <= 0) { fa.setError(tx('o.amountErr')); amt.focus(); return; } }
    btn.disabled = true; btn.textContent = tx('o.applying');
    try {
      const out = await G.resolveCode({ api, token, code: code.value, amount });
      if (out.type === 'applied') {
        const r = out.result, left = r.gift_card?.balance ?? 0, money = F.money;
        const text = [left > 0 ? tx('o.done', { amount: money(r.amount), balance: money(left) }) : tx('o.doneEmpty', { amount: money(r.amount) }), r.balance && +r.balance.unpaid <= 0 ? tx('o.paidFull') : r.balance ? tx('o.restDue', { unpaid: money(r.balance.unpaid) }) : ''].filter(Boolean).join(' ');
        return onApplied(text);
      }
      if (out.type === 'choose_source') showChoose(out);
      else if (out.type === 'blocked') showError(has(`nr.${out.reason}`) ? tx(`nr.${out.reason}`) : tx('err.generic'));
      else if (out.type === 'not_found') showError(tx('err.invalid_code'));
      else showError(errText(out.code));
    } catch { showError(tx('err.generic')); }
    btn.disabled = false; btn.textContent = tx('o.apply');
  } }, fc.wrap, fa.wrap, btn, msg);
  return h('section', { class: 'ord-card', 'aria-labelledby': 'ord-gc', 'data-testid': 'gc-redeem' }, h('h3', { id: 'ord-gc', text: tx('o.useTitle') }), h('p', { class: 'bk-note', text: tx('o.useLead') }), form, choose);
}

// Tilaussivun lunastuspyynnöt (public_get_order_voucher_claims): tila, ongelmatekstit ja koodin korjaus (public_update_voucher_claim_code, kun can_update_code=true).
// Ei aikarajoja eikä "varaus pidetään … asti" -tekstejä (booking_48). notice = { ok, text, extra } näytetään kortin yläosassa (vahvistusteksti).
export function claimsSection({ S, L, api, token, claims, notice = null, onChanged }) {
  const F = makeFmt(L), { tx, money, pick } = F;
  const has = (k) => GT[L][k] != null;
  const errText = (code) => (code === 'notReady' ? tx('notReady') : tx(G.errorKey(code, has)));
  const badgeCls = { received: 'st-pending', redeemed: 'st-confirmed', problem: 'st-cancelled', cancelled: 'st-expired', expired: 'st-expired' };
  const SRC = G.CLAIM_SOURCES.map((c) => ({ code: c, label: G.SOURCE_LABELS[c] }));
  const items = claims.map((c, i) => {
    const v = G.claimView(c);
    const text = v.state === 'redeemed' && v.amount != null && v.amount > 0 ? tx('vc.st.redeemedAmt', { amount: money(v.amount) }) : tx(v.textKey);
    let fix = null;
    if (v.canUpdate) {
      const code = h('input', { type: 'text', autocomplete: 'off', autocapitalize: 'characters', spellcheck: 'false', maxlength: 40, 'data-testid': 'vc-fix-code' });
      const fcode = field({ label: tx('vc.fixLabel'), control: code, hint: tx('o.codeHint'), name: `vcf${i}` });
      const src = h('select', { 'data-testid': 'vc-fix-source' }, SRC.map((s) => h('option', { value: s.code, selected: s.code === v.source ? true : null, text: pick(s, 'label') })));
      const fsrc = field({ label: tx('vc.fixSource'), control: src, name: `vcs${i}` });
      const fmsg = h('div', { class: 'ord-msg', 'aria-live': 'polite', 'data-testid': 'vc-fix-msg' });
      const go = h('button', { type: 'submit', class: 'btn ord-btn', 'data-testid': 'vc-fix-submit', text: tx('vc.fixSubmit') });
      code.addEventListener('input', () => { fcode.setError(''); fmsg.replaceChildren(); });
      const form = h('form', { class: 'ord-form bk-form vc-fix', novalidate: true, onsubmit: async (ev) => {
        ev.preventDefault(); if (go.disabled) return; fmsg.replaceChildren();
        if (!G.codeValid(code.value)) { fcode.setError(tx('vc.err.invalid_code')); code.focus(); return; }
        go.disabled = true; go.textContent = tx('vc.fixing');
        try {
          const r = await G.updateClaimCode({ api, token, claimNo: v.claimNo, code: code.value, source: src.value });
          if (r.type === 'updated') return onChanged({ ok: true, text: tx('vc.updated'), extra: r.mismatch ? tx('vc.mismatch') : '' });
          fmsg.append(h('p', { class: 'bk-error', role: 'alert', text: errText(r.code) }));
        } catch { fmsg.append(h('p', { class: 'bk-error', role: 'alert', text: tx('err.generic') })); }
        go.disabled = false; go.textContent = tx('vc.fixSubmit');
      } }, fcode.wrap, fsrc.wrap, go, fmsg);
      // ongelmatilassa lomake on auki valmiiksi; vastaanotetulla pyynnöllä korjaus on napin takana
      fix = h('details', { class: 'vc-fixbox', open: v.state === 'problem' ? true : null, 'data-testid': 'vc-fixbox' }, h('summary', { text: tx('vc.fixSummary') }), form);
    }
    return h('li', { class: `vc-item vc-${v.state}`, 'data-testid': 'vc-claim', 'data-state': v.state, 'data-claim': String(v.claimNo) },
      h('div', { class: 'vc-head' }, h('strong', { text: v.sourceLabel }), v.codeMasked ? h('span', { class: 'vc-mask', text: v.codeMasked }) : null, h('span', { class: `ord-badge ${badgeCls[v.state]}`, text: tx(`vc.b.${v.state}`) })),
      h('p', { class: 'vc-text', 'data-testid': 'vc-text', role: v.state === 'problem' ? 'status' : null, text }),
      v.state === 'problem' && ['already_used', 'other'].includes(v.problemCode) ? phoneBox(S, tx) : null, fix);
  });
  const note = notice ? h('div', { class: `vc-notice ${notice.ok ? 'ok' : 'bad'}`, role: 'status', tabindex: '-1', 'data-testid': 'vc-notice' }, h('p', { class: 'vc-notice-main', text: notice.text }), notice.extra ? h('p', { class: 'vc-notice-extra', text: notice.extra }) : null) : null;
  return h('section', { class: 'ord-card', 'aria-labelledby': 'ord-vc', 'data-testid': 'vc-claims' }, h('h3', { id: 'ord-vc', text: tx('vc.title') }), note, h('p', { class: 'bk-note', text: tx('vc.lead') }), h('ul', { class: 'ord-lines vc-list' }, items));
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
