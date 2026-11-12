// Tilausnäkymä v3 PR 3 (booking_282–284): osahyvityksen dialogit samalla vaiherakenteella kuin peruutusdialogi (2 Hyvitys → 3 Viesti → 4 Vahvistus).
//  * openOverpaymentFlow: "Hyvitä ylisuoritus…" (admin_refund_overpayment), ilman vaihetta 1.
//  * changeRefundStep: muutosdialogin hyvitysvaihe (admin_change_booking_preview → p_refund_amount/p_notify admin_change_bookingille).
// Kaikki näkyy vain, kun palvelimen lippu partial_refunds_enabled on päällä (info/esikatselu kertoo) ja käyttäjällä on payments.refund; muuten ei dialogia.
// Palvelin päättää summat ja oikeudet. Hyvityksen valinta ei ole oletuksena päällä "Älä hyvitä" -vaihtoehtoa vastaan: käyttäjä valitsee aina.
import { h, dialog, toast, money } from '../ui.js';
import { fmt } from '../talous-i18n.js';
import { isMissingRpc } from '../talous-api.js';
import { prText, loadPrTexts } from '../partial-refund-texts.js';
import { processOnlineRefunds } from './refund-cancel.js';
import { overpaymentView, checkAmount, changeRefundView, changeArgs, errorKey, round2 } from '../partial-refund-logic.js';

export const prErr = (e) => { const k = errorKey(e); return k ? prText(k) : (e?.message || String(e)); };

/** admin_order_refund_info; puuttuva RPC (booking_283 ajamatta) tai virhe → null (ominaisuus piiloon). */
export async function loadRefundInfo(rpc, orderId) {
  try { const r = await rpc('admin_order_refund_info', { p_order_id: orderId }); return r && r.ok !== false ? r : null; }
  catch (e) { if (isMissingRpc(e)) return null; return null; }
}

const radio = (name, value, checked, label, hint, testid, disabled = false) => h('label', { class: `ov-opt${checked ? ' is-on' : ''}${disabled ? ' is-off' : ''}`, 'data-testid': testid },
  h('input', { type: 'radio', name, value, checked: checked || null, disabled: disabled || null }),
  h('span', {}, h('strong', { text: label }), hint ? h('small', { class: 'muted', text: hint }) : null));
const num = (n, text) => h('h3', { class: 'ov-cx-q' }, h('span', { class: 'ov-num', text: String(n) }), ' ', text);

/** Maksu-kortin "Hyvitä ylisuoritus…" -nappi: palauttaa solmun vain kun palvelin sallii (lippu + oikeus + ylisuoritus). Muuten null. */
export async function overpaymentButton({ model: m, ctx, rpc, api, onDone }) {
  if (!ctx.can('payments.refund')) return null;
  await loadPrTexts(rpc).catch(() => false);
  const info = await loadRefundInfo(rpc, m.order_id);
  const view = overpaymentView(info);
  if (!view.show) return null;
  return h('button', { type: 'button', class: 'btn ghost ov-wide', 'data-testid': 'ov-pay-refund-over', text: prText('over.button'),
    onclick: () => openOverpaymentFlow({ model: m, ctx, rpc, api, onDone, info }) });
}

export async function openOverpaymentFlow({ model: m, ctx, rpc, api = null, onDone, info = null }) {
  await loadPrTexts(rpc).catch(() => false);
  info = info || await loadRefundInfo(rpc, m.order_id);
  const view = overpaymentView(info);
  const body = h('div', { class: 'ov-cx', 'data-testid': 'ov-over-flow' });
  const d = dialog(prText('over.title'), body, { wide: true });
  d.classList.add('ov-cx-dlg');
  const err = h('p', { class: 'err', role: 'alert', hidden: true });
  const submit = h('button', { type: 'button', class: 'btn primary', 'data-testid': 'ov-over-submit' });
  const back = h('button', { type: 'button', class: 'btn ghost', text: prText('confirm.back'), onclick: () => d.close() });
  if (!view.show) {
    body.append(h('p', { class: 'muted', 'data-testid': 'ov-over-why', text: prText(view.reason === 'invoice_locked' ? 'refund.invoice_locked' : view.reason === 'no_permission' ? 'refund.no_permission' : view.reason === 'disabled' ? 'errors.partial_refunds_disabled' : 'over.nothing') }), h('div', { class: 'ov-cx-foot' }, back));
    return d;
  }
  const hasEmail = !!m.customer?.email;
  const st = { amount: String(view.max).replace('.', ','), payment: '', notify: hasEmail ? null : 'no' };
  const amountIn = h('input', { name: 'over_amount', inputmode: 'decimal', value: st.amount, 'data-testid': 'ov-over-amount', 'aria-label': prText('over.amount') });
  const reason = h('input', { name: 'over_reason', maxlength: 200, value: prText('over.reason_default'), 'data-testid': 'ov-over-reason' });
  const paySel = h('select', { name: 'over_payment', 'data-testid': 'ov-over-payment' },
    h('option', { value: '', text: prText('over.payment_auto') }),
    ...view.payments.map((p) => h('option', { value: String(p.payment_id), text: `${p.method}${p.online ? ' (verkko)' : ''} · ${money(p.cap)}` })));
  const msgBox = h('div', {});
  const sumBox = h('p', { class: 'muted ov-small', 'data-testid': 'ov-over-summary' });
  function maxFor() { const p = view.payments.find((x) => String(x.payment_id) === st.payment); return p ? Math.min(view.max, p.cap) : view.max; }
  function paint() {
    const chk = checkAmount(amountIn.value, maxFor());
    msgBox.replaceChildren(hasEmail
      ? h('fieldset', { class: 'ov-cx-sec', 'data-testid': 'ov-over-message' }, h('legend', {}, num(3, prText('message.question'))),
          radio('over_notify', 'yes', st.notify === 'yes', prText('message.yes_receipt'), null, 'ov-over-notify-yes'),
          radio('over_notify', 'no', st.notify === 'no', prText('message.no'), null, 'ov-over-notify-no'))
      : h('p', { class: 'muted ov-small', text: prText('message.no_email') }));
    const online = view.payments.some((p) => p.online && (st.payment === '' || String(p.payment_id) === st.payment));
    sumBox.textContent = chk.ok ? prText('confirm.refund_overpaid', { amount: money(chk.amount) }) : prText('refund.amount_invalid', { max: money(maxFor()) });
    submit.textContent = chk.ok ? prText('confirm.refund_overpaid', { amount: money(chk.amount) }) : prText('confirm.refund_overpaid', { amount: '…' });
    submit.disabled = !chk.ok || st.notify == null;
    montNote.hidden = !online;
  }
  const montNote = h('p', { class: 'muted ov-small', text: prText('refund.montonio_note') });
  body.append(
    h('p', { class: 'muted ov-small', text: prText('over.sub', { no: m.order_no, over: money(view.overpaid ?? view.max) }) }),
    h('fieldset', { class: 'ov-cx-sec', 'data-testid': 'ov-over-refund' }, h('legend', {}, num(2, prText('steps.refund').replace(/^\d\s*/, ''))),
      h('label', { class: 'fld' }, h('span', { text: `${prText('over.amount')} (${prText('refund.max', { amount: money(view.max) })})` }), amountIn),
      h('label', { class: 'fld' }, h('span', { text: prText('over.payment') }), paySel),
      h('label', { class: 'fld' }, h('span', { text: prText('refund.reason') }), reason),
      view.nonRefundable > 0.004 ? h('p', { class: 'muted ov-small', text: prText('over.non_refundable', { amount: money(view.nonRefundable) }) }) : null, montNote),
    msgBox, h('div', { class: 'ov-cx-sec' }, num(4, prText('steps.confirm').replace(/^\d\s*/, '')), sumBox), err, h('div', { class: 'ov-cx-foot' }, back, submit));
  body.addEventListener('input', (e) => { if (e.target === amountIn) { err.hidden = true; paint(); } });
  body.addEventListener('change', (e) => {
    if (e.target === paySel) st.payment = paySel.value;
    if (e.target.name === 'over_notify') st.notify = e.target.value;
    err.hidden = true; paint();
  });
  submit.onclick = async () => {
    const chk = checkAmount(amountIn.value, maxFor());
    if (!chk.ok || st.notify == null) { err.textContent = prText('message.choose'); err.hidden = false; return; }
    submit.disabled = true;
    try {
      const res = await rpc('admin_refund_overpayment', { p_order_id: m.order_id, p_amount: chk.amount, p_payment_id: st.payment ? Number(st.payment) : null, p_reason: reason.value.trim() || prText('over.reason_default'), p_notify: st.notify === 'yes' });
      await processOnlineRefunds(api, res?.refunds);
      toast(prText('over.done', { amount: money(res?.refunded_total ?? chk.amount) }));
      d.close(); onDone?.();
    } catch (e) { err.textContent = prErr(e); err.hidden = false; submit.disabled = false; }
  };
  paint();
  return d;
}

/**
 * Muutosdialogin hyvitysvaihe. Kutsutaan ennen admin_change_booking-kutsua. Palauttaa:
 *   { skip: true, args: {}, hint?: 'price_up'|'disabled' }   ei hyvitysvaihetta (ei ylisuoritusta, lippu pois, ei oikeutta, esikatselu puuttuu)
 *   { cancelled: true }                                         käyttäjä perui
 *   { args: { p_refund_amount?, p_refund_reason?, p_notify } } valinta
 * Esikatselua ei vaadita: puuttuva RPC → ei hyvitysvaihetta, muutos toimii kuten ennen.
 */
export async function changeRefundStep({ rpc, previewArgs, hasEmail = false }) {
  await loadPrTexts(rpc).catch(() => false);
  let prev = null;
  try { prev = await rpc('admin_change_booking_preview', previewArgs); } catch (e) { return { skip: true, args: {}, hint: isMissingRpc(e) ? null : 'preview_failed', error: e }; }
  const view = changeRefundView(prev);
  if (!view.show) return { skip: true, args: {}, hint: view.reason === 'price_up' ? 'price_up' : view.reason === 'disabled' ? 'disabled' : null, view };
  return new Promise((resolve) => {
    const st = { refund: null, amount: String(view.max).replace('.', ','), notify: hasEmail ? null : 'no' };
    const body = h('div', { class: 'ov-cx', 'data-testid': 'ov-change-refund' });
    const d = dialog(prText('change.title'), body, { wide: true });
    d.classList.add('ov-cx-dlg');
    let settled = false;
    const finish = (v) => { if (settled) return; settled = true; resolve(v); d.close(); };
    d.addEventListener('close', () => { if (!settled) { settled = true; resolve({ cancelled: true }); } });
    const err = h('p', { class: 'err', role: 'alert', hidden: true });
    const amountIn = h('input', { name: 'chg_amount', inputmode: 'decimal', value: st.amount, 'data-testid': 'ov-chg-amount', 'aria-label': prText('refund.partial_amount') });
    const reason = h('input', { name: 'chg_reason', maxlength: 200, value: '', 'data-testid': 'ov-chg-reason', 'aria-label': prText('refund.reason') });
    const submit = h('button', { type: 'button', class: 'btn primary', 'data-testid': 'ov-chg-submit' });
    const cancel = h('button', { type: 'button', class: 'btn ghost', text: prText('confirm.back'), onclick: () => finish({ cancelled: true }) });
    const content = h('div', {});
    const nonRef = view.nonRefundable > 0.004 ? h('p', { class: 'muted ov-small', text: prText('refund.gift_excluded', { amount: money(view.max) }) }) : null;
    function paint() {
      const chk = st.refund === 'partial' ? checkAmount(amountIn.value, view.max) : { ok: true, amount: view.max };
      content.replaceChildren(
        h('p', { 'data-testid': 'ov-chg-prices' }, h('strong', { text: prText('change.new_price', { old: money(view.oldTotal), new: money(view.newTotal) }) }), ' · ', prText('change.diff', { diff: money(view.diff) })),
        h('p', { class: 'muted ov-small', text: prText('change.overpaid', { over: money(view.overpaid ?? view.max) }) }),
        h('fieldset', { class: 'ov-cx-sec', 'data-testid': 'ov-chg-refund' }, h('legend', {}, num(2, prText('refund.question'))),
          radio('chg_refund', 'diff', st.refund === 'diff', prText('change.refund_diff', { amount: money(view.max) }), null, 'ov-chg-diff'),
          radio('chg_refund', 'partial', st.refund === 'partial', prText('refund.partial'), prText('refund.max', { amount: money(view.max) }), 'ov-chg-partial'),
          st.refund === 'partial' ? h('label', { class: 'fld' }, h('span', { text: prText('refund.partial_amount') }), amountIn) : null,
          radio('chg_refund', 'none', st.refund === 'none', prText('change.keep_overpaid'), null, 'ov-chg-none'),
          st.refund === 'diff' || st.refund === 'partial' ? h('label', { class: 'fld' }, h('span', { text: prText('refund.reason') }), reason) : null,
          nonRef, h('p', { class: 'muted ov-small', text: prText('refund.montonio_note') })),
        hasEmail ? h('fieldset', { class: 'ov-cx-sec', 'data-testid': 'ov-chg-message' }, h('legend', {}, num(3, prText('message.question'))),
          radio('chg_notify', 'yes', st.notify === 'yes', prText('message.yes_change_with_receipt'), null, 'ov-chg-notify-yes'),
          radio('chg_notify', 'no', st.notify === 'no', prText('message.no'), null, 'ov-chg-notify-no')) : h('p', { class: 'muted ov-small', text: prText('message.no_email') }));
      const refunding = st.refund === 'diff' || st.refund === 'partial';
      submit.textContent = refunding && chk.ok ? prText('confirm.change_refund', { amount: money(chk.amount) }) : prText('confirm.change_only');
      submit.disabled = st.refund == null || st.notify == null || (st.refund === 'partial' && !chk.ok);
    }
    body.append(content, err, h('div', { class: 'ov-cx-foot' }, cancel, submit));
    body.addEventListener('change', (e) => {
      if (e.target.name === 'chg_refund') st.refund = e.target.value;
      if (e.target.name === 'chg_notify') st.notify = e.target.value;
      err.hidden = true; paint();
    });
    body.addEventListener('input', (e) => { if (e.target === amountIn) { st.amount = amountIn.value; paint(); } });
    submit.onclick = () => {
      const chk = st.refund === 'partial' ? checkAmount(amountIn.value, view.max) : { ok: true, amount: view.max };
      if (st.refund == null || st.notify == null || !chk.ok) { err.textContent = st.notify == null ? prText('message.choose') : prText('refund.amount_invalid', { max: money(view.max) }); err.hidden = false; return; }
      finish({ args: changeArgs({ refund: st.refund, amount: chk.amount, notify: st.notify, reason: reason.value.trim() || null }, view), view });
    };
    paint();
  });
}
