// Hyvitys ↔ peruutus (booking_136): kyllä/ei-valinta ja varauksen peruutusdialogi.
// * yesNo: kaksi radiopainiketta, oletus aina "ei" (turvallinen: ei peruutusta / ei rahaliikettä).
// * cancelReservationDialog: varauksen peruutus. payments.refund-oikeudella dialogi hakee varauksen osuuden maksuista
//   (admin_reservation_refund_preview: varauksen rivi + lisäpalvelut, aiemmat hyvitykset vähennetty) ja kysyy, hyvitetäänkö.
//   Peruutus + hyvitys = admin_cancel_reservation (yksi transaktio, palvelin tarkistaa oikeudet). Verkkomaksun hyvitys
//   (status requested) käsitellään heti Edge-funktiolla käyttäjän JWT:llä, kuten Talous-näkymässä.
import { h, dialog, toast, money } from '../ui.js';
import { t } from '../talous-i18n.js';
import { friendly } from './talous-ui.js';
import { rcText } from '../refund-cancel-texts.js';
import { isMissingRpc } from '../talous-api.js';

let seq = 0;
export function yesNo({ name, legend, no, yes, hint = null, testid, disabled = false }) {
  const id = `rc${++seq}`;
  const opt = (value, label, checked) => h('label', { class: 'check big rc-opt', 'data-testid': `${testid}-${value}` },
    h('input', { type: 'radio', name, value, checked: checked || null, disabled: disabled && value === 'yes' ? true : null }), h('span', {}, h('strong', { text: label })));
  const node = h('fieldset', { class: 'rc-choice', 'data-testid': testid, 'aria-describedby': hint ? `${id}-hint` : null },
    h('legend', { text: legend }), hint ? h('p', { class: 'muted rc-hint', id: `${id}-hint`, text: hint }) : null,
    opt('no', no, true), opt('yes', yes, false));
  return { node, value: () => node.querySelector('input:checked')?.value === 'yes' };
}

const MP_KINDS = { done: 'ok', failed: 'err', retry_later: 'warn', unverified: 'warn', db_error: 'warn', none: 'warn', off: 'warn', forbidden: 'err', error: 'warn' };
const VP_KINDS = { ...MP_KINDS, awaiting_customer: 'warn', not_settled: 'err', not_configured: 'warn' };
/** Verkkomaksun hyvitysrivit (status requested) käsitellään heti: api = createTalousApi(...) (mobilepayRefund / vismapayRefund). */
export async function processOnlineRefunds(api, refunds = []) {
  for (const x of refunds) {
    if (x?.status !== 'requested' || !api) continue;
    if (x.provider === 'mobilepay') { const m = await api.mobilepayRefund(x.refund_id); toast(t(MP_KINDS[m.result] ? `refund.mp.${m.result}` : 'refund.mp.error'), MP_KINDS[m.result] || 'warn'); }
    if (x.provider === 'visma_pay') { const m = await api.vismapayRefund(x.refund_id); toast(t(VP_KINDS[m.result] ? `refund.vp.${m.result}` : 'refund.vp.error'), VP_KINDS[m.result] || 'warn'); }
  }
}

/**
 * Varauksen peruutusdialogi. rpc = sb.js:n rpc (kokeilutilassa mock). canRefund = payments.refund (vain admin/manager);
 * ilman oikeutta hyvitysesikatselua ei edes haeta (palvelin kieltäisi). onDone(res) kutsutaan onnistuneen peruutuksen jälkeen.
 */
export async function cancelReservationDialog(r, { rpc, canRefund = false, online = null, onDone }) {
  const body = h('div', { class: 'stack rc-body', 'data-testid': 'rc-cancel' });
  const d = dialog(rcText('ui.admin.refund_cancel.cancel_title'), body);
  d.classList.add('rc-dlg');
  let plan = null, choice = null;
  const reason = h('input', { name: 'refund_reason', maxlength: 200, value: '', 'data-testid': 'rc-refund-reason' });
  const reasonFld = h('label', { class: 'fld', hidden: true }, h('span', { text: rcText('ui.admin.refund_cancel.refund_reason') }), reason);
  const notes = [];
  if (canRefund) {
    try { plan = await rpc('admin_reservation_refund_preview', { p_reservation_id: r.reservation_id }); } catch { plan = null; notes.push(rcText('ui.admin.refund_cancel.refund_unavailable')); }
  }
  const total = Math.round((+plan?.total || 0) * 100) / 100;
  const offline = (plan?.payments || []).some((p) => p.online_off);
  if (plan && +plan.unallocated > 0) notes.push(rcText('ui.admin.refund_cancel.refund_unallocated'));
  if (plan && total > 0) {
    if (offline) notes.push(rcText('ui.admin.refund_cancel.refund_online_off'));
    choice = yesNo({ name: 'refund', testid: 'rc-refund', legend: rcText('ui.admin.refund_cancel.refund_question'),
      hint: `${rcText('ui.admin.refund_cancel.refund_share', { amount: money(total) })}. ${rcText('ui.admin.refund_cancel.refund_share_note')}`,
      no: rcText('ui.admin.refund_cancel.refund_no'), yes: rcText('ui.admin.refund_cancel.refund_yes', { amount: money(total) }), disabled: offline });
    choice.node.addEventListener('change', () => { reasonFld.hidden = !choice.value(); });
  } else if (plan) notes.push(rcText('ui.admin.refund_cancel.refund_none'));
  const submit = h('button', { type: 'button', class: 'btn danger', 'data-testid': 'rc-submit', text: rcText('ui.admin.refund_cancel.submit') });
  const back = h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'rc-back', text: rcText('ui.admin.refund_cancel.back'), onclick: () => d.close() });
  submit.onclick = async () => {
    submit.disabled = true;
    try {
      const refund = !!choice?.value();
      let res;
      try { res = await rpc('admin_cancel_reservation', { p_reservation_id: r.reservation_id, p_reason: 'henkilökunta', p_refund: refund, p_refund_reason: refund ? (reason.value.trim() || null) : null }); }
      catch (e) {   // kanta ilman booking_136:ta: pelkkä peruutus kuten ennen (hyvitystä ei voi valita, koska esikatselukaan ei vastaa)
        if (refund || !isMissingRpc(e)) throw e;
        res = await rpc('admin_set_reservation_status', { p_reservation_id: r.reservation_id, p_status: 'cancelled', p_reason: 'henkilökunta' });
      }
      await processOnlineRefunds(online, res?.refunds);
      toast(+res?.refunded_total > 0 ? rcText('ui.admin.refund_cancel.done_refunded', { amount: money(res.refunded_total) }) : rcText('ui.admin.refund_cancel.done_cancelled'));
      d.close(); onDone?.(res);
    } catch (e) { toast(friendly(e), 'err'); } finally { submit.disabled = false; }
  };
  body.append(h('p', { text: rcText('ui.admin.refund_cancel.cancel_confirm') }), ...notes.map((n) => h('p', { class: 'muted rc-note', text: n })),
    choice ? choice.node : null, reasonFld, h('div', { class: 'rc-actions' }, back, submit));
  return d;
}
