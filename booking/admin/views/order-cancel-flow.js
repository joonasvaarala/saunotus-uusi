// Tilausnäkymä v3 (PR 1): peruutusdialogi vaiherakenteella 1 Mitä → 2 Hyvitys → 3 Viesti → 4 Vahvistus (luonnos dialogi-osaperuutus-monivaraus).
// Vain nykyiset RPC:t (ks. cancelPlan, ../order-view-logic.js):
//  * yksi varaus: admin_reservation_refund_preview + admin_cancel_reservation(p_refund true/false) – yksi transaktio.
//  * koko tilaus + hyvitys: admin_refund_order(p_cancel_reservations=true), kun hyvitettävä maksu on tasan yksi – yksi transaktio.
//  * koko tilaus ilman hyvitystä: admin_cancel_reservation jokaiselle voimassa olevalle varaukselle peräkkäin (EI atominen;
//    keskeytyessä kerrotaan montako peruttiin ja näkymä päivitetään).
// Osasumman kenttä on piilossa (PR 3). Viestivaihe näkyy yliviivattuna: henkilökunnan peruutusviesti tulee PR 2:ssa.
import { h, dialog, toast, money } from '../ui.js';
import { fmt } from '../talous-i18n.js';
import { friendly } from './talous-ui.js';
import { processOnlineRefunds } from './refund-cancel.js';
import { ov } from '../order-view-texts.js';
import { cancelPlan, cancelConfirmKey, paymentBox } from '../order-view-logic.js';

const resLine = (r) => `${r.product_name || ''} ${fmt.dt(r.starts_at)} · ${ov('order_view.persons', { n: r.persons })} · ${money(r.item_total + (r.addons || []).reduce((s, a) => s + (+a.line_total || 0), 0))}`;

export async function openCancelFlow({ model: m, reservationId = null, ctx, rpc, api = null, onDone }) {
  const can = ctx.can;
  const body = h('div', { class: 'ov-cx', 'data-testid': 'ov-cancel-flow' });
  const multi = (m.active || []).length > 1;
  const d = dialog(ov('order_cancel.title'), body, { wide: true });
  d.classList.add('ov-cx-dlg');
  const st = { scope: multi ? (reservationId ? 'one' : null) : 'one', target: reservationId || (m.active[0]?.id ?? null), refund: 'none', preview: null, previewFor: null };
  const reason = h('input', { name: 'refund_reason', maxlength: 200, 'data-testid': 'ov-cx-reason' });
  const submit = h('button', { type: 'button', class: 'btn danger', 'data-testid': 'ov-cx-submit' });
  const back = h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'ov-cx-back', text: ov('order_cancel.back'), onclick: () => d.close() });
  const err = h('p', { class: 'err', role: 'alert', hidden: true });
  const sub = h('p', { class: 'muted ov-small', text: ov('order_cancel.sub', { no: m.order_no, name: m.customer?.name || '', count: ov('order_view.meta_count', { n: m.reservations.length }) }) });
  const steps = h('ol', { class: 'ov-steps', 'aria-hidden': 'true' });
  const content = h('div', { class: 'ov-cx-body' });
  body.append(sub, steps, content, err, h('div', { class: 'ov-cx-foot' }, back, submit));

  async function ensurePreview() {
    if (st.scope !== 'one' || !st.target || !can('payments.refund') || m.locked) return;
    if (st.previewFor === st.target) return;
    st.previewFor = st.target; st.preview = null;
    try { st.preview = await rpc('admin_reservation_refund_preview', { p_reservation_id: st.target }); } catch { st.preview = null; }
  }
  const radio = (name, value, checked, label, hint, testid, disabled = false) => h('label', { class: `ov-opt${checked ? ' is-on' : ''}${disabled ? ' is-off' : ''}`, 'data-testid': testid },
    h('input', { type: 'radio', name, value, checked: checked || null, disabled: disabled || null }),
    h('span', {}, h('strong', { text: label }), hint ? h('small', { class: 'muted', text: hint }) : null));
  const num = (n, text, off = false) => h('h3', { class: `ov-cx-q${off ? ' is-off' : ''}` }, h('span', { class: 'ov-num', text: String(n) }), ' ', text);

  async function paint() {
    await ensurePreview();
    if (!d.open) return;
    const plan = cancelPlan(m, { reservationId: st.target, scope: st.scope, can, preview: st.preview });
    if (!plan.refund.show) st.refund = 'none';
    const box = paymentBox(m, { can });
    const offline = (st.preview?.payments || []).some((p) => p.online_off);
    steps.replaceChildren(...plan.steps.map((s, i) => h('li', { class: `${s.shown ? '' : 'is-off'}`, text: `${i + 1} ${ov(`order_cancel.step.${s.key}`)}` })));
    const parts = [];
    // 1 Mitä
    if (plan.multi) {
      const others = (m.active || []).filter((r) => String(r.id) !== String(st.target));
      parts.push(h('fieldset', { class: 'ov-cx-sec', 'data-testid': 'ov-cx-what' }, h('legend', {}, num(1, ov('order_cancel.q_what'))),
        ...(m.active || []).map((r) => radio('what', `one:${r.id}`, st.scope === 'one' && String(st.target) === String(r.id),
          ov('order_cancel.opt_one', { i: r.index, n: r.count, what: resLine(r) }),
          others.length && st.scope === 'one' && String(st.target) === String(r.id) ? ov('order_cancel.opt_one_rest') : null, `ov-cx-one-${r.id}`)),
        radio('what', 'all', st.scope === 'all', ov('order_cancel.opt_all', { no: m.order_no, count: ov('order_view.meta_count', { n: (m.active || []).length }), amount: money(m.balance.total) }), null, 'ov-cx-all')));
    } else {
      const r = plan.target;
      parts.push(h('div', { class: 'ov-cx-sec' }, num(1, ov('order_cancel.q_what')), r ? h('p', { class: 'ov-opt is-on' }, h('strong', { text: ov('order_cancel.opt_one', { i: r.index, n: r.count, what: resLine(r) }) })) : null));
    }
    // 2 Hyvitys
    const refundSec = h('fieldset', { class: 'ov-cx-sec', 'data-testid': 'ov-cx-refund' }, h('legend', {}, num(2, ov('order_cancel.q_refund'), !plan.refund.show)));
    if (plan.refund.show) {
      const label = plan.scope === 'all' ? ov('order_cancel.refund_full_order', { amount: money(plan.refund.amount) }) : ov('order_cancel.refund_full', { amount: money(plan.refund.amount) });
      refundSec.append(radio('refund', 'full', st.refund === 'full', label, null, 'ov-cx-refund-full', offline),
        radio('refund', 'none', st.refund === 'none', ov('order_cancel.refund_none'), null, 'ov-cx-refund-none'));
      if (offline) refundSec.append(h('p', { class: 'muted ov-small', text: ov('order_cancel.refund_online_off') }));
      if (plan.refund.unallocated) refundSec.append(h('p', { class: 'muted ov-small', text: ov('order_cancel.refund_unallocated') }));
      if (st.refund === 'full') refundSec.append(h('label', { class: 'fld' }, h('span', { text: ov('order_cancel.refund_reason') }), reason));
      if (box.giftCard > 0.004) refundSec.append(h('p', { class: 'muted ov-small', text: ov('order_cancel.gift_note') }));
    } else if (plan.refund.reason) {
      refundSec.append(h('p', { class: 'muted ov-small', 'data-testid': 'ov-cx-refund-why', text: ov(`order_cancel.refund_hidden.${plan.refund.reason}`) }));
    }
    if (box.partner > 0.004) refundSec.append(h('p', { class: 'muted ov-small', text: ov('order_cancel.partner_note') }));
    parts.push(refundSec);
    // 3 Viesti (PR 2)
    parts.push(h('div', { class: 'ov-cx-sec is-off', 'data-testid': 'ov-cx-message' }, num(3, ov('order_cancel.step.message'), true), h('p', { class: 'muted ov-small', text: ov('order_cancel.message_later') })));
    // 4 Yhteenveto
    const refunding = plan.refund.show && st.refund === 'full';
    const what = plan.scope === 'all' ? ov('order_cancel.sum_all', { count: ov('order_view.meta_count', { n: plan.targets.length }) })
      : plan.target ? ov('order_view.res_index', { i: plan.target.index, n: plan.target.count }) + ` · ${plan.target.product_name || ''} ${fmt.date(plan.target.starts_at)}` : '–';
    parts.push(h('div', { class: 'ov-cx-sec' }, num(4, ov('order_cancel.q_summary')),
      h('dl', { class: 'ov-kv ov-cx-sum', 'data-testid': 'ov-cx-summary' },
        h('dt', { text: ov('order_cancel.sum_what') }), h('dd', { text: what }),
        h('dt', { text: ov('order_cancel.sum_total') }), h('dd', { text: `${money(plan.totalBefore)} → ${money(plan.totalAfter)}` }),
        h('dt', { text: ov('order_cancel.sum_refund') }), h('dd', { text: refunding ? money(plan.refund.amount) : ov('order_cancel.sum_refund_none') }))));
    content.replaceChildren(...parts);
    submit.textContent = ov(`order_cancel.${cancelConfirmKey(plan, st.refund)}`, { amount: money(plan.refund.amount) });
    submit.disabled = !plan.ready;
    submit.onclick = () => go(plan);
  }
  content.addEventListener('change', (e) => {
    const t = e.target;
    if (t.name === 'what') { if (t.value === 'all') st.scope = 'all'; else { st.scope = 'one'; st.target = Number(t.value.slice(4)); } st.refund = 'none'; paint(); }
    if (t.name === 'refund') { st.refund = t.value; paint(); }
  });

  async function go(plan) {
    err.hidden = true;
    const refunding = plan.refund.show && st.refund === 'full';
    if (refunding && plan.scope === 'all' && reason.value.trim().length < 3) { err.textContent = ov('order_cancel.need_reason'); err.hidden = false; return; }
    submit.disabled = true;
    try {
      if (plan.scope === 'one') {
        const res = await rpc('admin_cancel_reservation', { p_reservation_id: plan.target.id, p_reason: 'henkilökunta', p_refund: refunding, p_refund_reason: refunding ? (reason.value.trim() || null) : null });
        await processOnlineRefunds(api, res?.refunds);
        toast(+res?.refunded_total > 0 ? ov('order_cancel.done_refunded', { amount: money(res.refunded_total) }) : ov('order_cancel.done'));
      } else if (refunding) {
        const res = await api.refundOrder({ paymentId: plan.refund.payment_id, amount: plan.refund.amount, reason: reason.value.trim(), cancelReservations: true });
        if (res?.status === 'requested') await processOnlineRefunds(api, [{ status: 'requested', provider: plan.refund.provider, refund_id: res.refund_id }]);
        toast(ov('order_cancel.done_refunded', { amount: money(plan.refund.amount) }));
      } else {
        let n = 0;
        for (const r of plan.targets) {
          try { await rpc('admin_cancel_reservation', { p_reservation_id: r.id, p_reason: 'henkilökunta', p_refund: false, p_refund_reason: null }); n += 1; }
          catch (e) {
            // Ei atominen (PR 1): tulos jää näkyviin dialogiin (ei vain ohimenevä ilmoitus), uusi yritys estetään ja näkymä päivitetään.
            const msg = ov('order_cancel.partial_fail', { done: n, total: plan.targets.length, error: friendly(e) });
            err.textContent = msg; err.hidden = false; err.dataset.testid = 'ov-cx-partial';
            submit.hidden = true; back.textContent = ov('order_cancel.close'); toast(msg, 'err'); onDone?.(); return;
          }
        }
        toast(ov('order_cancel.done'));
      }
      d.close(); onDone?.();
    } catch (e) { err.textContent = friendly(e); err.hidden = false; submit.disabled = false; }
  }
  await paint();
  return d;
}
