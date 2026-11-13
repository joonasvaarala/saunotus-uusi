// Tilausnäkymä v3 (PR 1): peruutusdialogi vaiherakenteella 1 Mitä → 2 Hyvitys → 3 Viesti → 4 Vahvistus (luonnos dialogi-osaperuutus-monivaraus).
// Vain nykyiset RPC:t (ks. cancelPlan, ../order-view-logic.js):
//  * yksi varaus: admin_reservation_refund_preview + admin_cancel_reservation(p_refund true/false) – yksi transaktio.
//  * koko tilaus + hyvitys: admin_refund_order(p_cancel_reservations=true), kun hyvitettävä maksu on tasan yksi – yksi transaktio.
//  * koko tilaus ilman hyvitystä: admin_cancel_reservation jokaiselle voimassa olevalle varaukselle peräkkäin (EI atominen;
//    keskeytyessä kerrotaan montako peruttiin ja näkymä päivitetään).
// Osasumman kenttä on piilossa (PR 3).
// PR 2 (booking_280/281): admin_reservation_cancel_options → lahjakorttikysymys (pakollinen, ei oletusta), kumppanikoodin huomautukset ja
// yksittäisen varauksen peruutusviesti (pakollinen kysymys, kun asiakkaalla on sähköposti). Rahahyvityksen osuus = money_share (ilman
// lahjakortti- ja kumppaniosuutta). Kanta ilman 280:tä (valinnat-RPC puuttuu): toiminta kuten PR 1:ssä, uusia parametreja ei lähetetä.
// Koko tilauksen peruutuksesta ei lähetetä viestiä tästä dialogista (yksi viesti per kutsu → useita viestejä; avoin kysymys).
import { h, dialog, toast, money } from '../ui.js';
import { fmt } from '../talous-i18n.js';
import { friendly } from './talous-ui.js';
import { processOnlineRefunds } from './refund-cancel.js';
import { rcText, loadRcTexts } from '../refund-cancel-texts.js';
import { isMissingRpc } from '../talous-api.js';
import { cancelFlowExtras } from '../order-view-logic.js';
import { ov } from '../order-view-texts.js';
import { prText, loadPrTexts } from '../partial-refund-texts.js';
import { loadRefundInfo } from './partial-refund-flow.js';
import { partialEnabled, checkAmount, allocateCancelRefund, cancelAllRefundView, syntheticCancelOptions, cancelOrderArgs, round2, errorKey } from '../partial-refund-logic.js';
import { cancelPlan, cancelConfirmKey, paymentBox } from '../order-view-logic.js';

const resLine = (r) => `${r.product_name || ''} ${fmt.dt(r.starts_at)} · ${ov('order_view.persons', { n: r.persons })} · ${money(r.item_total + (r.addons || []).reduce((s, a) => s + (+a.line_total || 0), 0))}`;

export async function openCancelFlow({ model: m, reservationId = null, ctx, rpc, api = null, onDone }) {
  const can = ctx.can;
  const body = h('div', { class: 'ov-cx', 'data-testid': 'ov-cancel-flow' });
  const multi = (m.active || []).length > 1;
  const d = dialog(ov('order_cancel.title'), body, { wide: true });
  d.classList.add('ov-cx-dlg');
  const st = { scope: multi ? (reservationId ? 'one' : null) : 'one', target: reservationId || (m.active[0]?.id ?? null), refund: 'none', preview: null, previewFor: null, opts: new Map(), optsMissing: false, gift: null, notify: null, info: null, partialAmt: '' };
  const reason = h('input', { name: 'refund_reason', maxlength: 200, 'data-testid': 'ov-cx-reason' });
  const partialIn = h('input', { name: 'refund_partial_amount', inputmode: 'decimal', 'data-testid': 'ov-cx-partial-amount', 'aria-label': prText('refund.partial_amount') });
  const submit = h('button', { type: 'button', class: 'btn danger', 'data-testid': 'ov-cx-submit' });
  const back = h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'ov-cx-back', text: ov('order_cancel.back'), onclick: () => d.close() });
  const err = h('p', { class: 'err', role: 'alert', hidden: true });
  const sub = h('p', { class: 'muted ov-small', text: ov('order_cancel.sub', { no: m.order_no, name: m.customer?.name || '', count: ov('order_view.meta_count', { n: m.reservations.length }) }) });
  const steps = h('ol', { class: 'ov-steps', 'aria-hidden': 'true' });
  const content = h('div', { class: 'ov-cx-body' });
  body.append(sub, steps, content, err, h('div', { class: 'ov-cx-foot' }, back, submit));

  // booking_280: peruutuksen valinnat varauskohtaisesti (välimuisti). Puuttuva RPC → vanha toiminta.
  async function ensureOptions(ids) {
    if (st.optsMissing) return;
    for (const id of ids) {
      if (st.opts.has(String(id))) continue;
      try { const o = await rpc('admin_reservation_cancel_options', { p_reservation_id: id }); st.opts.set(String(id), o && o.ok !== false ? o : null); }
      catch (e) { if (isMissingRpc(e)) { st.optsMissing = true; st.opts.clear(); return; } st.opts.set(String(id), null); }
    }
  }
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
    const planIds = cancelPlan(m, { reservationId: st.target, scope: st.scope, can, preview: st.preview }).targets.map((r) => r.id);
    await ensureOptions(planIds);
    if (!d.open) return;
    // booking_283 (PR 3): lippu päällä → koko tilauksen peruutus on atominen (admin_cancel_order) ja "Hyvitä osa" on käytössä
    const atomic = st.scope === 'all' && partialEnabled(st.info) && !st.info.gift_card_sale;
    const optsFor = atomic ? [syntheticCancelOptions(st.info, { firstReservationId: planIds[0], hasEmail: !!m.customer?.email })]
      : (st.optsMissing ? null : planIds.map((id) => st.opts.get(String(id)) ?? null));
    const ex = cancelFlowExtras({ scope: atomic ? 'one' : st.scope, locked: !!m.locked, options: optsFor, gift: st.gift, notify: st.notify, refunding: st.refund !== 'none' });
    // Rahahyvitys yhdelle varaukselle = money_share (lahjakortti- ja kumppaniosuus eivät ole rahahyvitystä, booking_280)
    const preview = ex.moneyShare != null && st.preview ? { ...st.preview, total: ex.moneyShare } : st.preview;
    const plan = cancelPlan(m, { reservationId: st.target, scope: st.scope, can, preview });
    // Koko tilaus + lahjakorttivalinta: admin_refund_order ei tunne lahjakorttivalintaa → peruutus ilman rahahyvitystä, raha erikseen.
    if (atomic) {
      const used = (m.reservations || []).some((r) => ['completed', 'no_show'].includes(r.status) || (r.checkin_at && r.status !== 'cancelled'));
      const av = cancelAllRefundView(st.info, { used });
      plan.refund = av.show ? { show: true, reason: null, options: ['full', 'partial', 'none'], amount: av.max } : { show: false, reason: ['invoice_locked', 'no_permission', 'partly_used'].includes(av.reason) ? av.reason : 'nothing', options: [], amount: 0 };
    } else if (plan.scope === 'all' && ex.gift.show && plan.refund.show) plan.refund = { show: false, reason: null, rcReason: 'all_gift_refund_separately', options: [], amount: 0 };
    else if (plan.scope === 'one' && plan.refund.show && partialEnabled(st.info)) plan.refund.options = ['full', 'partial', 'none'];
    plan.steps = plan.steps.map((s) => (s.key === 'message' ? { ...s, shown: ex.notify.show } : s));
    if (!plan.refund.show) st.refund = 'none';
    st.refundMax = plan.refund.amount;
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
        ...(plan.refund.options.includes('partial') ? [radio('refund', 'partial', st.refund === 'partial', prText('refund.partial'), prText('refund.max', { amount: money(plan.refund.amount) }), 'ov-cx-refund-partial', offline)] : []),
        radio('refund', 'none', st.refund === 'none', ov('order_cancel.refund_none'), null, 'ov-cx-refund-none'));
      if (st.refund === 'partial') refundSec.append(h('label', { class: 'fld' }, h('span', { text: prText('refund.partial_amount') }), partialIn));
      if (offline) refundSec.append(h('p', { class: 'muted ov-small', text: ov('order_cancel.refund_online_off') }));
      if (plan.refund.unallocated) refundSec.append(h('p', { class: 'muted ov-small', text: ov('order_cancel.refund_unallocated') }));
      if (st.refund === 'full' || st.refund === 'partial') refundSec.append(h('label', { class: 'fld' }, h('span', { text: ov('order_cancel.refund_reason') }), reason));
      if (atomic) refundSec.append(h('p', { class: 'muted ov-small', 'data-testid': 'ov-cx-atomic', text: prText('cancel.atomic_note') }));
      if (box.giftCard > 0.004 && !ex.active) refundSec.append(h('p', { class: 'muted ov-small', text: ov('order_cancel.gift_note') }));
    } else if (plan.refund.rcReason) {
      refundSec.append(h('p', { class: 'muted ov-small', 'data-testid': 'ov-cx-refund-why', text: rcText(`ui.admin.refund_cancel.${plan.refund.rcReason}`) }));
    } else if (plan.refund.reason) {
      refundSec.append(h('p', { class: 'muted ov-small', 'data-testid': 'ov-cx-refund-why', text: ov(`order_cancel.refund_hidden.${plan.refund.reason}`) }));
    }
    if (box.partner > 0.004 && !ex.partnerNotes.length) refundSec.append(h('p', { class: 'muted ov-small', text: ov('order_cancel.partner_note') }));
    // booking_280: lahjakorttikoodi voimaan? (pakollinen, ei oletusta; vanhentuneelle vain "Ei")
    if (ex.gift.show) {
      refundSec.append(h('div', { class: 'ov-cx-sub', 'data-testid': 'ov-cx-gift' },
        h('p', {}, h('strong', { text: rcText('ui.admin.refund_cancel.gift_card_question') })),
        ...ex.gift.cards.map((g) => h('p', { class: 'muted ov-small', text: rcText('ui.admin.refund_cancel.gift_card_share', { amount: money(g.amount), code: g.code_last4 || '', date: g.valid_to ? fmt.date(g.valid_to) : '–' }) })),
        ex.gift.expired ? h('p', { class: 'muted ov-small', text: rcText('ui.admin.refund_cancel.gift_card_expired') }) : null,
        radio('gift', 'keep', st.gift === 'keep', rcText('ui.admin.refund_cancel.gift_card_keep', { amount: money(ex.gift.total) }), null, 'ov-cx-gift-keep', ex.gift.expired),
        radio('gift', 'forfeit', st.gift === 'forfeit', rcText('ui.admin.refund_cancel.gift_card_forfeit'), null, 'ov-cx-gift-forfeit')));
    }
    for (const k of ex.partnerNotes) refundSec.append(h('p', { class: 'tl-note ov-small', 'data-testid': 'ov-cx-partner', text: rcText(`ui.admin.refund_cancel.${k.key}`, k.vars ? { amount: money(k.vars.amount) } : undefined) }));
    parts.push(refundSec);
    // 3 Viesti (booking_281): yksi peruutusviesti heti; hyvitysteksti tilan mukaan, ei hyvitystä → ei mainintaa
    if (ex.notify.show) {
      parts.push(h('fieldset', { class: 'ov-cx-sec', 'data-testid': 'ov-cx-message' }, h('legend', {}, num(3, rcText('ui.admin.refund_cancel.notify_question'))),
        h('p', { class: 'muted ov-small', 'data-testid': 'ov-cx-notify-hint', text: rcText(`ui.admin.refund_cancel.${ex.notify.hintKey}`) }),
        radio('notify', 'yes', st.notify === 'yes', rcText('ui.admin.refund_cancel.notify_yes'), null, 'ov-cx-notify-yes'),
        radio('notify', 'no', st.notify === 'no', rcText('ui.admin.refund_cancel.notify_no'), null, 'ov-cx-notify-no')));
    } else {
      const why = ex.notify.reason ? rcText(`ui.admin.refund_cancel.${ex.notify.reason}`) : ov('order_cancel.message_later');
      parts.push(h('div', { class: 'ov-cx-sec is-off', 'data-testid': 'ov-cx-message' }, num(3, ov('order_cancel.step.message'), true), h('p', { class: 'muted ov-small', text: why })));
    }
    // 4 Yhteenveto
    const refunding = plan.refund.show && st.refund !== 'none';
    const refundAmt = st.refund === 'partial' ? round2(String(partialIn.value).replace(',', '.')) : plan.refund.amount;
    const what = plan.scope === 'all' ? ov('order_cancel.sum_all', { count: ov('order_view.meta_count', { n: plan.targets.length }) })
      : plan.target ? ov('order_view.res_index', { i: plan.target.index, n: plan.target.count }) + ` · ${plan.target.product_name || ''} ${fmt.date(plan.target.starts_at)}` : '–';
    parts.push(h('div', { class: 'ov-cx-sec' }, num(4, ov('order_cancel.q_summary')),
      h('dl', { class: 'ov-kv ov-cx-sum', 'data-testid': 'ov-cx-summary' },
        h('dt', { text: ov('order_cancel.sum_what') }), h('dd', { text: what }),
        h('dt', { text: ov('order_cancel.sum_total') }), h('dd', { text: `${money(plan.totalBefore)} → ${money(plan.totalAfter)}` }),
        h('dt', { text: ov('order_cancel.sum_refund') }), h('dd', { text: refunding ? money(refundAmt) : ov('order_cancel.sum_refund_none') }))));
    content.replaceChildren(...parts);
    submit.textContent = st.refund === 'partial' && plan.refund.show ? prText(plan.scope === 'all' ? 'confirm.cancel_all_refund_partial' : 'confirm.cancel_refund_partial', { amount: money(refundAmt) })
      : ov(`order_cancel.${cancelConfirmKey(plan, st.refund)}`, { amount: money(plan.refund.amount) });
    submit.disabled = !plan.ready;
    submit.onclick = () => go(plan, ex);
  }
  content.addEventListener('change', (e) => {
    const t = e.target;
    if (t.name === 'what') { if (t.value === 'all') st.scope = 'all'; else { st.scope = 'one'; st.target = Number(t.value.slice(4)); } st.refund = 'none'; paint(); }
    if (t.name === 'refund') { st.refund = t.value; if (t.value === 'partial' && !partialIn.value) partialIn.value = String(round2(st.refundMax || 0)).replace('.', ','); paint(); }
    if (t.name === 'gift' || t.name === 'notify') { st[t.name] = t.value; err.hidden = true; paint(); }
  });

  content.addEventListener('input', (e) => { if (e.target === partialIn) { err.hidden = true; paint(); } });

  async function go(plan, ex) {
    err.hidden = true;
    if (ex.missing.length) { err.textContent = rcText('ui.admin.refund_cancel.choose_required'); err.hidden = false; return; }
    const refunding = plan.refund.show && st.refund !== 'none';
    const partialChk = st.refund === 'partial' && plan.refund.show ? checkAmount(partialIn.value, plan.refund.amount) : null;
    if (partialChk && !partialChk.ok) { err.textContent = prText('refund.amount_invalid', { max: money(plan.refund.amount) }); err.hidden = false; return; }
    const atomicGo = plan.scope === 'all' && partialEnabled(st.info) && !st.info.gift_card_sale;
    if (refunding && plan.scope === 'all' && reason.value.trim().length < 3) { err.textContent = ov('order_cancel.need_reason'); err.hidden = false; return; }
    submit.disabled = true;
    try {
      if (atomicGo) {
        // booking_283: yksi atominen kutsu (yksi hyvitys / maksu, lahjakorttivalinta, yksi viesti); ks. admin_cancel_order
        const alloc = allocateCancelRefund(st.info, st.refund === 'full' ? 'full' : st.refund === 'partial' ? 'partial' : 'none', partialChk?.amount || 0);
        if (refunding && !alloc.length) { err.textContent = prText('refund.amount_invalid', { max: money(plan.refund.amount) }); err.hidden = false; submit.disabled = false; return; }
        const res = await rpc('admin_cancel_order', cancelOrderArgs({ orderId: m.order_id, reason: refunding ? reason.value.trim() : null, refund: alloc,
          notify: ex.notify.show ? st.notify === 'yes' : null, giftKeep: ex.gift.show ? st.gift === 'keep' : null }));
        await processOnlineRefunds(api, res?.refunds);
        toast(+res?.refunded_total > 0 ? ov('order_cancel.done_refunded', { amount: money(res.refunded_total) }) : ov('order_cancel.done'));
      } else if (plan.scope === 'one') {
        const res = await rpc('admin_cancel_reservation', { p_reservation_id: plan.target.id, p_reason: 'henkilökunta', p_refund: st.refund === 'full', p_refund_reason: refunding ? (reason.value.trim() || null) : null, ...(partialChk ? { p_refund_amount: partialChk.amount } : {}), ...ex.argsFor(plan.target.id) });
        await processOnlineRefunds(api, res?.refunds);
        toast(+res?.refunded_total > 0 ? ov('order_cancel.done_refunded', { amount: money(res.refunded_total) }) : ov('order_cancel.done'));
      } else if (refunding) {
        const res = await api.refundOrder({ paymentId: plan.refund.payment_id, amount: plan.refund.amount, reason: reason.value.trim(), cancelReservations: true });
        if (res?.status === 'requested') await processOnlineRefunds(api, [{ status: 'requested', provider: plan.refund.provider, refund_id: res.refund_id }]);
        toast(ov('order_cancel.done_refunded', { amount: money(plan.refund.amount) }));
      } else {
        let n = 0;
        for (const r of plan.targets) {
          try { await rpc('admin_cancel_reservation', { p_reservation_id: r.id, p_reason: 'henkilökunta', p_refund: false, p_refund_reason: null, ...ex.argsFor(r.id) }); n += 1; }
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
    } catch (e) { const k = errorKey(e); err.textContent = k ? prText(k) : friendly(e); err.hidden = false; submit.disabled = false; }
  }
  await Promise.all([loadRcTexts(rpc).catch(() => false), loadPrTexts(rpc).catch(() => false)]);
  st.info = await loadRefundInfo(rpc, m.order_id);   // null (RPC puuttuu / virhe) → PR 1–2 -toiminta ennallaan
  await paint();
  return d;
}
