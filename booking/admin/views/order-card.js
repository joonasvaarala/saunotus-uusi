// Yhteinen varaus- ja tilauskortti: sama näkymä varaukselle ja tilaukselle.
import { rpc, fn, select as dbSelect } from '../sb.js';
import { createTalousApi, normOrder } from '../talous-api.js';
import { canAddPurchase, isFlowEnabledValue } from '../order-reservation-logic.js';
import { telHref, mailHref, createLatestGate } from '../reservation-dialog-logic.js';
import { cardActions, cardPaymentStatus, cardSectionSummaries } from '../order-card-logic.js';
import { loadOrderTexts, orderText as tx } from '../orders-texts.js';
import { loadRcTexts } from '../refund-cancel-texts.js';
import { cancelReservationDialog } from './refund-cancel.js';
import { openAddToOrder, openOrderPaymentLink, openOrderRecordPayment } from './order-add.js';
import { formDialog } from './talous-ui.js';
import { t } from '../talous-i18n.js';
import { addonPicker } from './addons.js';
import { reservationAddonLocks, addonReductionError, orderInvoiceLocked, invoiceLockReason, staffInvoiceChange, linkStaleNote } from '../addon-lock-logic.js';
import { alt } from '../addon-lock-texts.js';
import { nbt } from '../nb-texts.js';
import { staffPersonsMax, bookingNotices, bookingAction, isPrivateConflict, slotBookable } from '../nb-logic.js';
import { loadBookingTexts, bookingText, noticeText } from '../booking-texts.js';
import { confirmDialog } from '../confirm.js';
import { helsinkiIso } from '../ui.js';
import { memoText } from '../day-memos-texts.js';
import { stepper } from '../stepper.js';
import { icon } from '../icons.js';
import { h, dialog, toast, run, fmtDay, fmtTime, fmtDT, money, statusBadge, payBadge, sourceBadge, isJohku, field, badge, empty, errMsg } from '../ui.js';
import { formatWhenRange, spansDays } from '../when-range.js';
import { legsList, resName, resourceBadges, hasLegs } from './legs.js';
import { missingOpen, grantButton } from './therapist.js';
import { optionBadge, optionOf, optionPicker, ot, optErr } from '../options.js';
import { orderVoucherBox } from './voucher-redeem.js';
import { billingMethodText } from '../billing-method-texts.js';
import { receiptsList } from './talous-receipts.js';
import { annualCardPanel, showAnnualCardDialog } from './annual-card-panel.js';
import { acText } from '../annual-card-texts.js';
import { orderContents } from '../order-lines-logic.js';
import { methodLabel, pstatBadge, johkuBadge } from './talous-ui.js';
import { orderInvoiceCaption } from '../order-invoice-label.js';

let flowPromise;
function orderFlowEnabled() {
  if (!flowPromise) flowPromise = dbSelect('settings', { select: 'value', key: 'eq.admin_order_reservation_flow_enabled', limit: 1 })
    .then(isFlowEnabledValue).catch(() => false);
  return flowPromise;
}
const list = (...nodes) => nodes.flat(Infinity).filter((n) => n !== null && n !== undefined && n !== false);
const dd = (label, value) => value == null || value === '' ? [] : [h('dt', { text: label }), h('dd', { text: value })];

function cardWhen(starts, ends) {
  if (!starts) return '';
  const at = new Date(starts);
  if (Number.isNaN(at.getTime())) return '';
  const weekday = new Intl.DateTimeFormat('fi-FI', { timeZone: 'Europe/Helsinki', weekday: 'short' }).format(at).replace(/\.$/, '');
  const date = new Intl.DateTimeFormat('fi-FI', { timeZone: 'Europe/Helsinki', day: 'numeric', month: 'numeric', year: 'numeric' }).format(at);
  if (!ends) return `${weekday} ${date} klo ${fmtTime(starts)}`;
  if (spansDays(starts, ends)) return formatWhenRange(starts, ends, 'fi');
  return `${weekday} ${date} klo ${fmtTime(starts)}–${fmtTime(ends)}`;
}

function payLabel(pay) {
  const amount = money(pay.amount);
  const key = {
    unpaid: 'ui.admin.res.pay_unpaid_amount',
    paid: 'ui.admin.res.pay_paid_amount',
    invoiced: 'ui.admin.res.pay_invoiced_amount',
    refunded: 'ui.admin.res.pay_refunded_amount',
    pending: 'ui.admin.res.pay_pending_amount',
    failed: 'ui.admin.res.pay_unpaid_amount',
  }[pay.label] || 'ui.admin.res.pay_unpaid_amount';
  return tx(key, { amount });
}

function section(id, title, summary, testid) {
  const el = h('details', { class: 'oc-sec', 'data-testid': testid, id: `oc-sec-${id}` },
    h('summary', {},
      h('span', { text: title }),
      h('span', { class: 'oc-sum', 'data-testid': `${testid}-sum`, text: summary || '' }),
      icon('chev', 20)));
  el.querySelector('summary .icon')?.classList.add('oc-chev');
  const body = h('div', { class: 'oc-sec-body' });
  el.append(body);
  return { el, body, setSum(text) { el.querySelector('.oc-sum').textContent = text || ''; } };
}

export function reservationDialog(r, opts = {}) {
  return openOrderCard({ reservation: r, orderId: r.order_id, ...opts });
}

export function openOrderCard({
  reservation = null, orderId = null, methods = [], onChange, refs, can = () => true, flow = null, role = null,
} = {}) {
  loadOrderTexts(rpc).catch(() => {});
  const api = createTalousApi({ rpc, io: { fn } });
  const ctx = { can, refs };
  const body = h('div', { class: 'stack rd-dialog' });
  const titleSeed = reservation?.product_name || tx('ui.admin.res.order_title');
  const d = dialog(titleSeed, body);
  let alive = true;
  const orderGate = createLatestGate();
  const dayGate = createLatestGate();
  d.addEventListener('close', () => { alive = false; });
  let rawOrder = null, order = null, flowEnabled = !!flow, currentExtras = [], orderReservation = null;
  let r = reservation ? { ...reservation } : null;
  const after = () => { d.close(); onChange?.(); };
  const act = (label, job, cls = 'btn', testid = null) => {
    const btn = h('button', { type: 'button', class: cls, 'data-testid': testid, text: label,
      onclick: () => run(btn, async () => { await job(); toast('Tallennettu'); after(); }) });
    return btn;
  };
  const status = (s) => rpc('admin_set_reservation_status', { p_reservation_id: r.reservation_id, p_status: s, p_reason: null });

  const hero = h('section', { class: 'oc-hero rd-summary', 'data-testid': 'res-summary', 'aria-label': tx('ui.admin.res.summary_label') },
    h('h3', { class: 'oc-name', 'data-testid': 'res-customer', text: reservation?.customer_name || reservation?.customer?.name || '' }));
  const alerts = h('div', { class: 'rd-alerts', hidden: true });
  const primary = h('div', { class: 'oc-actions tl-actions rd-actions', 'data-testid': 'res-primary-actions', hidden: true });
  const addonsSec = section('addons', tx('ui.admin.res.section_addons'), '', 'res-contents');
  const paySec = section('payments', tx('ui.admin.res.section_payments'), '', 'res-payment');
  const msgSec = section('messages', tx('ui.admin.res.section_messages'), tx('ui.admin.res.sum_no_messages'), 'res-messages');
  const histSec = section('history', tx('ui.admin.res.section_history'), '', 'res-history');
  const noteSec = section('notes', tx('ui.admin.res.section_notes'), tx('ui.admin.res.sum_add_note'), 'res-note-editor');
  const sections = h('div', { class: 'oc-sections' }, addonsSec.el, paySec.el, msgSec.el, histSec.el, noteSec.el);
  const secondary = h('div', { class: 'row wrap rd-secondary', 'data-testid': 'res-secondary-actions', 'aria-label': tx('ui.admin.res.other_actions'), hidden: true });
  const more = h('details', { class: 'rd-more oc-sec', 'data-testid': 'res-more' },
    h('summary', { text: tx('ui.admin.res.more_details') }));
  const resBox = h('div', { class: 'resbox' });
  const moreDetails = h('dl', { class: 'kv' }); const billingBox = h('div', { class: 'rd-billing' });
  more.append(moreDetails, resBox, billingBox);
  const move = h('details', { class: 'rd-more rd-move oc-sec', 'data-testid': 'res-move', hidden: true },
    h('summary', { text: tx('ui.admin.res.move_title') }));
  const moveBody = h('div', { class: 'moverow' }); move.append(moveBody);
  const footer = h('div', { class: 'oc-footer', 'data-testid': 'res-danger', hidden: true });
  body.append(hero, alerts, primary, sections, secondary, more, move, footer);

  const optBox = h('div', { class: 'opt-box', 'data-testid': 'option-box', hidden: true });
  const addonsBox = h('div', { class: 'addons-box' });
  const itemsBox = h('div', { class: 'oc-items' });
  addonsSec.body.append(optBox, addonsBox, itemsBox);

  const sums = h('dl', { class: 'tl-sums' });
  const payList = h('div', { class: 'oc-pays' });
  const voucher = h('div', { class: 'rd-voucher', hidden: true });
  const paymentActions = h('div', { class: 'rd-payment-actions' });
  const receiptsBox = h('div', { class: 'oc-receipts' });
  const annualBox = h('div', { class: 'oc-annual' });
  paySec.body.append(sums, payList, voucher, annualBox, receiptsBox, paymentActions);

  function dialogTitle() {
    if (r?.product_name) return r.product_name;
    const items = order?.items || rawOrder?.items || [];
    if (items.length && items.every((x) => x.kind === 'gift_card' || x.category === 'gift_card')) return tx('ui.admin.res.gift_title');
    if (!r && order) return tx('ui.admin.res.order_title');
    return tx('ui.admin.res.order_title');
  }

  function drawHero() {
    const titleEl = d.querySelector('.dlg-head h2');
    if (titleEl) titleEl.textContent = dialogTitle();
    const pay = cardPaymentStatus(order, r);
    const name = r?.customer_name || order?.customer_name || order?.customer?.name || '–';
    const oid = (r?.order_no || order?.order_no) ? tx('ui.admin.res.order_no', { no: r?.order_no || order.order_no }) : '';
    const when = r?.starts_at
      ? cardWhen(r.starts_at, r.ends_at)
      : (order?.created_at ? tx('ui.admin.res.ordered_at', { when: cardWhen(order.created_at) }) : '');
    const space = r?.space_code ? resName(refs, r.space_code) : null;
    const opt = r ? optionOf(r).name : null;
    const persons = r ? tx(r.mode === 'exclusive' ? 'ui.admin.res.persons_private' : 'ui.admin.res.persons_shared', { n: r.persons }) : tx('ui.admin.res.no_booking');
    const meta = r ? [persons, space, opt].filter(Boolean).join(' · ') : [tx('ui.admin.res.no_booking')].join(' · ');
    const stBadge = r
      ? (r.status === 'completed' ? badge('ok', tx('ui.admin.res.arrived')) : statusBadge(r.status))
      : null;
    const pBadge = badge(pay.badgeClass, payLabel(pay));
    const phone = telHref(r?.customer_phone || order?.customer?.phone);
    const email = mailHref(r?.customer_email || order?.customer?.email);
    const phoneTxt = r?.customer_phone || order?.customer?.phone;
    const emailTxt = r?.customer_email || order?.customer?.email;
    const company = (rawOrder?.customer_kind === 'company' && rawOrder?.billing?.company) ? rawOrder.billing.company : null;
    hero.replaceChildren(
      h('div', { class: 'oc-hero-top' },
        h('h3', { class: 'oc-name', 'data-testid': 'res-customer', text: name }),
        oid ? h('span', { class: 'oc-oid', text: oid }) : null),
      when ? h('p', { class: 'oc-when', text: when }) : null,
      h('p', { class: 'oc-meta', text: meta }),
      h('div', { class: 'oc-badges rd-badges' }, ...list(
        stBadge, pBadge,
        r?.option_missing ? badge('warn', tx('ui.admin.res.option_missing')) : null,
        r && isJohku(r) ? sourceBadge(r) : null,
        (order?.source_channel === 'web' || order?.source_channel === 'verkkokauppa') && !r ? badge('src', tx('ui.admin.res.webshop')) : null,
        r?.annual_card_id || order?.annual_card_id ? badge('warn', 'Vuosikortti') : null,
        r?.status === 'pending' && r?.hold_expires_at ? h('small', { text: tx('ui.admin.res.hold_until', { time: fmtTime(r.hold_expires_at) }) }) : null,
        orderInvoiceCaption(order || {}) ? badge('pay-invoiced', orderInvoiceCaption(order)) : null,
      )),
      h('div', { class: 'oc-contact rd-contact' }, ...list(
        company ? h('strong', { text: company }) : null,
        phone ? h('a', { href: phone, 'aria-label': tx('ui.admin.res.call', { phone: phoneTxt }), text: phoneTxt }) : (phoneTxt ? h('span', { text: phoneTxt }) : null),
        email ? h('a', { href: email, 'aria-label': tx('ui.admin.res.email', { email: emailTxt }), text: emailTxt }) : (emailTxt ? h('span', { text: emailTxt }) : null),
        (rawOrder?.customer_note || order?.customer_note) ? h('div', {}, h('small', { class: 'muted', text: tx('ui.admin.res.customer_message') }), h('p', { text: rawOrder?.customer_note || order.customer_note })) : null,
      )),
    );
  }

  function drawResources() {
    if (!r) { resBox.replaceChildren(); alerts.replaceChildren(); alerts.hidden = true; return; }
    if (!r.space_code && !hasLegs(r) && !r.lifecycle && !r.therapist_missing) { resBox.replaceChildren(); alerts.replaceChildren(); alerts.hidden = true; return; }
    moreDetails.replaceChildren(...list(
      dd('Kanava', r.source_channel), dd('Luotu', r.created_at ? fmtDT(r.created_at) : ''),
      isJohku(r) ? [h('dt', { text: 'Lähde' }), h('dd', {}, sourceBadge(r), ' tuotu Johku-järjestelmästä')] : null,
      isJohku(r) ? dd('Johku-tunnus', r.external_id) : null));
    const claim = (r.claim_offset_min > 0 || r.claim_minutes) ? `alkaa +${r.claim_offset_min || 0} min${r.claim_minutes ? `, kesto ${r.claim_minutes} min` : ''}` : null;
    resBox.replaceChildren(...list(
      h('dl', { class: 'kv' }, ...list(
        r.space_code ? [h('dt', { text: 'Tila' }), h('dd', {}, h('strong', { text: resName(refs, r.space_code) }), ...resourceBadges(r))] : null,
        r.lifecycle ? dd('Tuote', r.lifecycle === 'old' ? 'Vanha tuote (vanha varaus)' : 'Nykyinen tuote') : null,
        dd('Ylitys', r.override_reason), r.quota_exempt ? dd('Kiintiö', 'Kiintiövapaa') : null,
        dd('Tilan käyttö', claim), r.parent_reservation_id ? dd('Vanhempi varaus', `varaus #${r.parent_reservation_id}`) : null,
        r.therapist_exception_at ? dd('Saunottaja', `Poikkeus myönnetty ${fmtDT(r.therapist_exception_at)} ${r.therapist_exception_note || ''}`) : null)),
      legsList(r.legs, refs)));
    alerts.replaceChildren(...list(
      missingOpen(r) ? h('div', { class: 'rd-alert', 'data-testid': 'therapist-state' },
        h('strong', { text: 'Puuttuu työvuorosta' }), grantButton(r, { ctx: { can }, onDone: after })) : null));
    alerts.hidden = !alerts.childNodes.length;
  }

  function editAddons(ad, raw) {
    const state = reservationAddonLocks(raw, r.reservation_id);
    return rpc('admin_list_addons').then((all) => {
      const picker = addonPicker(all, { getPersons: () => r.persons, getMode: () => r.mode, locks: state.locks });
      picker.set(ad);
      const error = h('p', { class: 'err', role: 'alert', tabindex: '-1', hidden: state.complete, text: state.complete ? '' : alt('error_unknown') });
      const f = h('form', { class: 'stack', onsubmit: (event) => { event.preventDefault(); run(f.querySelector('button[type=submit]'), async () => {
        const code = addonReductionError(state, picker.value());
        if (code) { error.textContent = alt(code === 'addon_paid' ? 'error_paid' : code === 'addon_link_open' ? 'error_link' : 'error_unknown'); error.hidden = false; error.focus(); return; }
        try { await rpc('admin_set_reservation_addons', { p_reservation_id: r.reservation_id, p_addons: picker.value() });
          toast('Lisäpalvelut tallennettu'); ddialog.close(); after(); }
        catch (e) { error.textContent = (e?.code === 'order_invoiced' || e?.details === 'order_invoiced') ? alt('error_invoiced') : errMsg(e); error.hidden = false; error.focus(); }
      }); } },
        h('p', { class: 'muted', text: `Enimmäismäärä = henkilömäärä (${r.persons}) × lisäpalvelun enimmäismäärä / hlö.` }),
        picker.node, error,
        h('button', { class: 'btn primary', type: 'submit', text: 'Tallenna lisäpalvelut' }));
      const ddialog = dialog(`Lisäpalvelut – tilaus #${r.order_no}`, f);
    }).catch((e) => toast(errMsg(e), 'err'));
  }
  function drawOption(x) {
    const choices = x.option_choices || [], cur = x.option || null;
    if (!choices.length && !cur && !x.option_missing) { optBox.hidden = true; return; }
    const editable = r && ['pending', 'confirmed'].includes(r.status) && can('bookings.manage');
    const error = h('p', { class: 'err', role: 'alert', hidden: true, 'data-testid': 'option-error' });
    const notify = h('input', { type: 'checkbox', name: 'notify', 'data-testid': 'option-notify' });
    const picker = optionPicker({ choices, value: cur?.code || '', label: ot('change'), name: `ro-${r.reservation_id}` });
    const save = h('button', { type: 'button', class: 'btn primary', hidden: true, 'data-testid': 'option-save', text: ot('save'), onclick: () => run(save, async () => {
      try { const v = await rpc('admin_set_reservation_option', { p_reservation_id: r.reservation_id, p_option_code: picker.value, p_notify: notify.checked });
        toast(v?.email_queued ? ot('savedMail') : ot('saved')); after(); }
      catch (e) { error.textContent = optErr(e); error.hidden = false; }
    }) });
    if (picker.node) picker.node.addEventListener('change', () => { save.hidden = !picker.value || picker.value === (cur?.code || ''); });
    optBox.replaceChildren(...list(
      h('h4', { text: ot('label') }),
      h('p', { class: 'muted' }, `${ot('current')}: `, h('span', { 'data-testid': 'res-option' }, h('strong', { 'data-testid': 'option-current', text: optionOf(x).name || ot('none') }))),
      editable && choices.length ? [picker.node, h('label', { class: 'check' }, notify, ` ${ot('notify')}`), error, save] : null));
    optBox.hidden = false;
  }

  function drawSections() {
    const sumsData = cardSectionSummaries(order, r);
    const isShop = !r || !(order?.reservations || []).length && (order?.items || []).length;
    addonsSec.el.querySelector('summary span').textContent = isShop && !r ? tx('ui.admin.res.section_items') : tx('ui.admin.res.section_addons');
    if (sumsData.addons.empty) addonsSec.setSum(tx('ui.admin.res.sum_no_addons'));
    else addonsSec.setSum(tx(isShop && !r ? 'ui.admin.res.sum_items' : 'ui.admin.res.sum_addons', { n: sumsData.addons.count, amount: money(sumsData.addons.amount) }));
    const payKey = sumsData.payments.kind === 'invoiced' ? 'ui.admin.res.sum_invoiced' : (sumsData.payments.kind === 'unpaid' ? 'ui.admin.res.sum_unpaid' : 'ui.admin.res.sum_paid');
    paySec.setSum(tx(payKey, { amount: money(sumsData.payments.amount) }));
    msgSec.setSum(sumsData.messages.empty ? tx('ui.admin.res.sum_no_messages') : tx('ui.admin.res.sum_messages', { n: sumsData.messages.count }));
    const created = sumsData.history.createdAt ? fmtDT(sumsData.history.createdAt) : '';
    histSec.setSum(created ? tx('ui.admin.res.history_created', { when: created }) : '');
    noteSec.setSum(sumsData.notes.empty ? tx('ui.admin.res.sum_add_note') : sumsData.notes.text);
  }


  const MP_KINDS = { done: 'ok', failed: 'err', retry_later: 'warn', unverified: 'warn', db_error: 'warn', none: 'warn', off: 'warn', forbidden: 'err', error: 'warn' };
  const VP_KINDS = { done: 'ok', failed: 'err', retry_later: 'warn', awaiting_customer: 'warn', unverified: 'warn', db_error: 'warn', none: 'warn', off: 'warn', forbidden: 'err', error: 'warn', not_settled: 'err', not_configured: 'warn' };
  const MO_KINDS = { done: 'ok', pending: 'warn', awaiting_settlement: 'warn', failed: 'err', retry_later: 'warn', db_error: 'warn', not_configured: 'warn', none: 'warn', off: 'warn', forbidden: 'err', error: 'warn' };
  async function processMobilepayRefund(refundId) {
    const m = await api.mobilepayRefund(refundId);
    toast(t(MP_KINDS[m.result] ? `refund.mp.${m.result}` : 'refund.mp.error'), MP_KINDS[m.result] || 'warn');
    return m;
  }
  async function processVismaRefund(refundId) {
    const m = await api.vismapayRefund(refundId);
    toast(t(VP_KINDS[m.result] ? `refund.vp.${m.result}` : 'refund.vp.error'), VP_KINDS[m.result] || 'warn');
    return m;
  }
  async function processMontonioRefund(refundId) {
    const m = await api.montonioRefund(refundId);
    toast(t(MO_KINDS[m.result] ? `refund.mo.${m.result}` : 'refund.mo.error'), MO_KINDS[m.result] || 'warn');
    return m;
  }
  function openRefunds(p) {
    const rows = (p.refunds || []).filter((x) => ['requested', 'processing', 'failed'].includes(x.status));
    if (!rows.length) return null;
    const canRetry = (p.provider === 'mobilepay' || p.provider === 'visma_pay' || p.provider === 'montonio') && !api.isMock?.('refund') && can('payments.refund');
    return h('ul', { class: 'tl-refunds', 'data-testid': 'order-open-refunds' }, rows.map((rf) => h('li', { 'data-testid': 'open-refund', 'data-status': rf.status },
      h('span', { class: `badge ${rf.status === 'failed' ? 'st-cancelled' : 'st-pending'}`, text: t(rf.status === 'failed' ? 'refund.failed' : 'refund.pending') }), ' ',
      h('span', { text: `${money(rf.amount)}${rf.reason ? ' · ' + rf.reason : ''}` }),
      canRetry && rf.status !== 'failed' ? h('button', { type: 'button', class: 'btn sm', 'data-testid': 'btn-refund-retry', text: t('refund.retry'), onclick: () => run(null, async () => {
        if (p.provider === 'visma_pay') await processVismaRefund(rf.id);
        else if (p.provider === 'montonio') await processMontonioRefund(rf.id);
        else await processMobilepayRefund(rf.id);
        await fetchOrder(); onChange?.();
      }) }) : null)));
  }

  function drawOrder(token) {
    if (!alive || (token != null && !orderGate.isCurrent(token))) return;
    drawHero();
    drawSections();
    if (!rawOrder || !order) return;
    const b = order.balance || {};
    const s = (key, value, cls = '') => [h('dt', { text: t(key) }), h('dd', { class: cls, text: money(value) })];
    sums.replaceChildren(...list(s('order.total', b.total), s('order.paid', b.paid),
      Number(b.refunded) > 0 ? s('order.refunded', b.refunded) : null,
      Number(b.unpaid) > 0 ? s('order.unpaid', b.unpaid, 'due') : null,
      Number(b.pending_link) > 0 ? s('order.pendingLink', b.pending_link) : null));
    const totalLine = h('div', { class: 'oc-line total' },
      h('span', {}, Number(b.unpaid) > 0 ? t('order.unpaid') : t('order.paid'), ' ', h('span', { class: 'vat', text: tx('ui.admin.res.incl_vat') })),
      h('span', { class: 'pr', text: money(Number(b.unpaid) > 0 ? b.unpaid : (b.paid || b.total)) }));
    sums.append(totalLine);
    payList.replaceChildren(...list(
      (order.payments || []).length
        ? (order.payments || []).map((p) => h('div', { class: 'oc-payrow' },
          h('span', { class: 'how' }, methodLabel(p.method, p.method_label) || p.method || '', ' ', pstatBadge(p.status), !order.is_native ? johkuBadge() : null),
          h('span', { class: 'amt', text: money(p.amount) }),
          h('span', { class: 'when', text: [p.paid_at || p.created_at ? fmtDT(p.paid_at || p.created_at) : null, p.receipt_no ? `${t('receipt')} ${p.receipt_no}` : null].filter(Boolean).join(' · ') }),
          linkStaleNote(p, order, alt) ? h('p', { class: 'muted', 'data-testid': 'link-stale-note', text: linkStaleNote(p, order, alt) }) : null))
        : h('p', { class: 'muted', text: t(order.is_native ? 'order.noPayments' : 'order.noPaymentsJohku') }),
      (order.payments || []).map((p) => openRefunds(p)),
      h('p', { class: 'muted', text: tx('ui.admin.res.no_open_invoices') }),
    ));
    const actions = cardActions(r, { can, order, rawOrder, flowEnabled });
    const paymentNodes = [];
    if (actions.payment.openOrder && r && flow?.orderHref) {
      paymentNodes.push(h('a', { class: 'order-link', 'data-testid': 'order-link',
        href: flow.orderHref(r.order_no) || `#/talous?tab=orders&order=${encodeURIComponent(r.order_no)}`,
        text: flow.orderLinkText?.(r.order_no) || nbt('nb.orderLink', { no: r.order_no }), onclick: () => d.close() }));
    }
    paymentActions.replaceChildren(...paymentNodes);
    if (r) {
      orderReservation = (rawOrder.reservations || []).find((x) => String(x.id) === String(r.reservation_id) || String(x.reservation_id) === String(r.reservation_id)) || {};
      currentExtras = orderReservation.addons || [];
      if (orderReservation.option_missing != null) r.option_missing = orderReservation.option_missing;
      if (orderReservation.option) r.option = orderReservation.option;
      drawOption(orderReservation);
      const invoiced = orderInvoiceLocked(order);
      addonsBox.replaceChildren(...list(h('h4', {}, icon('leaf', 20), ' Lisäpalvelut'),
        invoiced ? h('p', { class: 'muted', role: 'status', 'data-testid': 'invoice-addon-lock', text: alt('invoiced_rows', { no: order.invoice_no || '–' }) }) : null,
        currentExtras.length ? h('ul', { class: 'reslist' }, currentExtras.map((a) => h('li', { class: 'resrow' },
          h('span', { text: `${a.quantity} × ${a.name}` }), h('span', { class: 'meta', text: money(a.line_total) })))) : h('p', { class: 'muted', text: 'Ei lisäpalveluita.' }),
        actions.editAddons ? h('button', { type: 'button', class: 'btn sm', 'data-testid': 'res-edit-addons', text: 'Muokkaa lisäpalveluita', onclick: () => editAddons(currentExtras, rawOrder) }) : null,
        canAddPurchase(order, { can }).allowed && !invoiced ? h('button', { type: 'button', class: 'btn', 'data-testid': 'order-reservation-add-section', text: tx('ui.admin.res.add_purchase'), onclick: doPurchase }) : null));
    } else {
      optBox.hidden = true;
      addonsBox.replaceChildren();
    }
    const contents = orderContents(order);
    const lines = [];
    for (const res of contents.reservations || []) {
      lines.push(h('div', { class: 'oc-line' },
        h('span', { class: 'nm', text: `${res.product_name || '–'}${res.status === 'cancelled' ? ' (peruttu)' : ''}` }),
        h('span', { class: 'pr', text: money(res.item_total) })));
      for (const a of res.addons || []) {
        lines.push(h('div', { class: 'oc-line' }, h('span', { class: 'nm', text: `${a.quantity} × ${a.name}` }), h('span', { class: 'pr', text: money(a.line_total) })));
      }
    }
    for (const l of contents.lines || []) {
      lines.push(h('div', { class: 'oc-line' }, h('span', { class: 'nm', text: l.name || l.kind }), h('span', { class: 'pr', text: money(l.line_total) })));
    }
    if (lines.length) {
      lines.push(h('div', { class: 'oc-line total' }, h('span', {}, 'Yhteensä ', h('span', { class: 'vat', text: tx('ui.admin.res.incl_vat') })), h('span', { class: 'pr', text: money(b.total) })));
    }
    itemsBox.replaceChildren(...lines);
    drawHero();
    if (rawOrder.customer_kind === 'company' && rawOrder.billing) {
      const x = rawOrder.billing;
      const method = x.invoice_method || rawOrder.billing_method || null;
      const online = method === 'online';
      billingBox.replaceChildren(h('h4', { text: online ? billingMethodText('company_details') : 'Yritysasiakas – laskutustiedot' }), h('dl', { class: 'kv' }, ...list(
        dd('Yritys', x.company), dd('Y-tunnus', x.business_id),
        dd('Osoite', [x.street, [x.zip, x.city].filter(Boolean).join(' ')].filter(Boolean).join(', ')),
        method ? [h('dt', { text: billingMethodText('label') }), h('dd', { 'data-testid': 'res-billing-method', text: billingMethodText(method) })] : [],
        online ? [] : dd('Verkkolasku', x.einvoice_address && [x.einvoice_address, x.einvoice_operator].filter(Boolean).join(' / ')),
        dd('Viite', rawOrder.invoice_reference),
        dd('Yhteyshenkilö', [x.contact_name, x.contact_email, x.contact_phone].filter(Boolean).join(' · ')))));
    }
    const invoiced = orderInvoiceLocked(order);
    if (invoiced) { voucher.replaceChildren(); voucher.hidden = true; }
    else orderVoucherBox({ rpc, orderId: order.order_id || r?.order_id, onChanged: () => { fetchOrder(); onChange?.(); } }).then((node) => {
      if (!alive || (token != null && !orderGate.isCurrent(token))) return;
      voucher.replaceChildren(...list(node)); voucher.hidden = !node;
    }).catch(() => {});
    if (order.receipts?.length) {
      receiptsBox.replaceChildren(h('h4', { text: `${t('receipts.title')} (${order.receipts.length})` }), receiptsList({ api, ctx, receipts: order.receipts }));
    } else receiptsBox.replaceChildren();
    drawMessages();
    drawHistory();
    drawNotes();
    drawResources();
    renderActions();
  }

  function drawMessages() {
    const receipts = (order?.receipts || []).filter((x) => x.sent_at || x.kind);
    if (!receipts.length) {
      msgSec.body.replaceChildren(h('p', { class: 'muted', text: tx('ui.admin.res.sum_no_messages') }));
      return;
    }
    msgSec.body.replaceChildren(...receipts.map((x) => h('div', { class: 'msg' },
      h('strong', { text: x.kind === 'receipt' ? t('receipt') : (x.kind || 'Viesti') }),
      h('span', { class: 'muted', text: x.sent_at || x.issued_at ? fmtDT(x.sent_at || x.issued_at) : '' }))));
  }
  function drawHistory() {
    const rows = [];
    if (r?.status === 'completed') rows.push(h('li', {}, h('span', { class: 't', text: '' }), 'Merkitty saapuneeksi.'));
    for (const p of order?.payments || []) {
      rows.push(h('li', {}, h('span', { class: 't', text: p.paid_at || p.created_at ? fmtDT(p.paid_at || p.created_at) : '' }),
        `${methodLabel(p.method, p.method_label) || p.method || 'Maksu'} ${money(p.amount)}.`));
    }
    const created = order?.created_at || r?.created_at;
    const src = order?.source_channel || r?.source_channel || r?.source;
    if (created) rows.push(h('li', {}, h('span', { class: 't', text: fmtDT(created) }),
      src === 'web' ? 'Tilaus luotu verkkokaupassa.' : 'Luotu hallinnasta.'));
    histSec.body.replaceChildren(rows.length ? h('ol', { class: 'oc-log' }, ...rows) : h('p', { class: 'muted', text: '' }));
  }
  function drawNotes() {
    const storedNote = String(r?.notes || '');
    const notes = h('textarea', { name: 'reservation_note', rows: 2, maxlength: 1000, value: storedNote });
    const save = h('button', { type: 'button', class: 'btn sm', hidden: true, 'data-testid': 'res-note-save',
      text: memoText('ui.admin.day_memos.res_note_save'), onclick: () => run(save, async () => {
        const updated = await rpc('admin_set_reservation_note', { p_reservation_id: r.reservation_id, p_notes: notes.value });
        r.notes = updated?.notes ?? null; toast(memoText('ui.admin.day_memos.res_note_saved')); after();
      }) });
    notes.addEventListener('input', () => { save.hidden = notes.value === storedNote; });
    const requestNote = (order?.requests || []).some((x) => x.status === 'open')
      ? h('p', { class: 'tl-note', 'data-testid': 'order-cancel-request', text: t('order.cancelRequest') }) : null;
    const lockNote = order && orderInvoiceLocked(order)
      ? h('p', { class: 'tl-note', role: 'status', 'data-testid': 'order-invoice-lock', text: invoiceLockReason(order, alt) }) : null;
    noteSec.body.replaceChildren(...list(
      r && can('bookings.manage') ? [field(memoText('ui.admin.day_memos.res_note_label'), notes), save] : (storedNote ? h('p', { class: 'note', text: storedNote }) : null),
      order?.internal_note ? h('p', { class: 'tl-note', 'data-testid': 'order-note', text: `${t('order.note')}: ${order.internal_note}` }) : null,
      requestNote, lockNote,
      !storedNote && !(r && can('bookings.manage')) && !order?.internal_note ? h('p', { class: 'muted', text: tx('ui.admin.res.sum_add_note') }) : null,
    ));
  }

  async function doPurchase() {
    if (orderInvoiceLocked(order)) { toast(invoiceLockReason(order, alt), 'warn'); return; }
    if (flow?.addPurchase) { d.close(); flow.addPurchase(order); return; }
    d.close(); await openAddToOrder({ api, ctx, order, reservationId: r?.reservation_id, onDone: onChange });
  }
  function doLink() {
    if (orderInvoiceLocked(order)) { toast(invoiceLockReason(order, alt), 'warn'); return; }
    if (flow?.createLink) { d.close(); flow.createLink(order); return; }
    d.close(); openOrderPaymentLink({ api, ctx, order, onDone: onChange });
  }
  function doRecord() {
    if (orderInvoiceLocked(order)) { toast(invoiceLockReason(order, alt), 'warn'); return; }
    if (flow?.recordPayment) { d.close(); flow.recordPayment(order); return; }
    d.close(); openOrderRecordPayment({ api, ctx, order, onDone: onChange });
  }
  function doRefund() {
    if (flow?.refund) { d.close(); flow.refund(order); return; }
    const no = order?.order_no || r?.order_no;
    if (no) location.hash = `#/tilaukset?order=${encodeURIComponent(no)}`;
  }

  function renderActions() {
    const options = cardActions(r, { can, order, rawOrder, flowEnabled, now: new Date() });
    const actions = {
      confirm: () => act('Vahvista', () => status('confirmed'), 'btn primary', 'res-confirm'),
      addPurchase: () => h('button', { type: 'button', class: 'btn', 'data-testid': 'order-reservation-add', text: tx('ui.admin.res.add_purchase'), onclick: doPurchase }),
      createLink: () => h('button', { type: 'button', class: 'btn primary', 'data-testid': 'order-reservation-create-link', text: tx('ui.admin.res.send_pay_link'), onclick: doLink }),
      recordPayment: () => h('button', { type: 'button', class: 'btn', 'data-testid': 'order-reservation-record', text: tx('ui.admin.res.take_payment'), onclick: doRecord }),
      arrive: () => act('Merkitse saapuneeksi', () => status('completed'), 'btn primary', 'res-arrive'),
      change: () => r ? h('button', { type: 'button', class: 'btn', 'data-testid': 'res-change', text: 'Muuta varausta', onclick: () => { d.close(); changeDialog(r, onChange, order, can); } }) : null,
      noShow: () => r ? h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'res-no-show', text: 'Ei saapunut', onclick: () => formDialog(tx('ui.admin.res.no_show_title'), [h('p', { text: tx('ui.admin.res.no_show_text') })], tx('ui.admin.res.no_show_submit'), async () => { await status('no_show'); after(); }) }) : null,
      cancel: () => r ? h('button', { type: 'button', class: 'linkish', 'data-testid': 'res-cancel', text: 'Peru varaus', onclick: async (event) => {
        const btn = event.currentTarget; btn.disabled = true;
        try { await loadRcTexts(rpc); await cancelReservationDialog(r, {
          rpc, canRefund: !!can('payments.refund'), online: createTalousApi({ rpc, io: { fn } }), onDone: after,
          invoiceLocked: orderInvoiceLocked(order),
        }); } finally { btn.disabled = false; }
      } }) : null,
      refund: () => h('button', { type: 'button', class: 'linkish', 'data-testid': 'order-refund', text: tx('ui.admin.res.refund_order'), onclick: doRefund }),
    };
    const primaryBtns = options.primary.map((key) => actions[key]?.()).filter(Boolean);
    const secondaryBtns = options.secondary.map((key) => {
      const node = actions[key]?.();
      if (!node) return null;
      node.classList.remove('primary');
      return node;
    }).filter(Boolean);
    primary.replaceChildren(...primaryBtns, ...secondaryBtns);
    primary.hidden = !primaryBtns.length && !secondaryBtns.length;
    primary.classList.toggle('no-primary', !primaryBtns.length);
    secondary.replaceChildren();
    secondary.hidden = true;
    const dangerBtns = (options.danger || []).map((key) => actions[key]?.()).filter(Boolean);
    footer.replaceChildren(...dangerBtns);
    footer.hidden = !dangerBtns.length;
    if (options.move?.show) { move.hidden = false; if (!move.isConnected) body.append(move); }
    if (!options.move?.show && move.isConnected) move.remove();
    moveBody.replaceChildren();
    if (options.move?.show) {
      const other = options.move.to;
      const reason = h('input', { name: 'reason', maxlength: 200, placeholder: tx('ui.admin.res.move_reason'), 'aria-label': tx('ui.admin.res.move_reason') });
      const error = h('p', { class: 'err', role: 'alert', hidden: true });
      const go = h('button', { type: 'button', class: 'btn sm', text: tx('ui.admin.res.move_button', { space: resName(refs, other) }) });
      go.addEventListener('click', () => run(go, async () => {
        error.hidden = true;
        try { await rpc('admin_move_reservation_space', { p_reservation_id: r.reservation_id, p_space_code: other, p_reason: reason.value.trim() || null }); }
        catch (e) { error.textContent = errMsg(e); error.hidden = false; return; }
        toast(`Varaus siirretty tilaan ${resName(refs, other)}`); after();
      }));
      moveBody.append(field(tx('ui.admin.res.move_reason'), reason), go, error, h('p', { class: 'muted', text: tx('ui.admin.res.move_help') }));
    }
  }

  drawHero();
  drawResources();
  renderActions();

  if (r?.quota_exempt === undefined && r?.reservation_id && (r.space_code || hasLegs(r))) {
    const day = new Date(r.starts_at).toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
    const dayToken = dayGate.next();
    rpc('admin_day_view', { p_date: day }).then((v) => {
      if (!alive || !dayGate.isCurrent(dayToken)) return;
      const item = (v?.reservations || []).find((x) => x.reservation_id === r.reservation_id);
      if (!item) return;
      Object.assign(r, { quota_exempt: item.quota_exempt, override_reason: item.override_reason,
        claim_offset_min: item.claim_offset_min, claim_minutes: item.claim_minutes,
        therapist_missing: item.therapist_missing, therapist_missing_open: item.therapist_missing_open,
        therapist_exception_at: item.therapist_exception_at, therapist_exception_note: item.therapist_exception_note,
        legs: item.legs?.length ? item.legs : r.legs, option_missing: item.option_missing ?? r.option_missing, option: item.option || r.option });
      drawResources(); drawHero(); renderActions();
    }).catch(() => {});
  }

  async function fetchOrder() {
    const id = orderId || r?.order_id;
    if (!id) { renderActions(); return; }
    const token = orderGate.next();
    const pid = Number(id) || id;
    try {
      let raw;
      try {
        raw = await rpc('admin_get_order', { p_order_id: pid });
      } catch (e) {
        // Kokeilutilassa päivänäkymän ja Tilaukset-listan mock-aineistot ovat erilliset.
        if (!api.getOrder) throw e;
        raw = await api.getOrder(pid);
      }
      if (!alive || !orderGate.isCurrent(token)) return;
      rawOrder = raw; order = normOrder(raw);
      if (!r && (order.reservations || []).length === 1) {
        const only = order.reservations[0];
        r = {
          reservation_id: only.reservation_id || only.id,
          order_id: order.order_id, order_no: order.order_no,
          status: only.status, product_name: only.product_name, product_id: only.product_id,
          mode: only.mode, starts_at: only.starts_at, ends_at: only.ends_at, persons: only.persons,
          notes: only.notes, customer_name: order.customer_name || order.customer?.name,
          customer_phone: order.customer?.phone, customer_email: order.customer?.email,
          payment_status: order.payment_status, option: only.option, option_missing: only.option_missing,
        };
      }
      drawOrder(token);
      if (r?.reservation_id && r.space_code == null) {
        rpc('admin_list_reservations', { p_reservation_id: Number(r.reservation_id), p_limit: 1, p_offset: 0 }).then((data) => {
          if (!alive || !orderGate.isCurrent(token)) return;
          const rows = Array.isArray(data) ? data : (Array.isArray(data?.rows) ? data.rows : []);
          const row = rows.find((x) => Number(x.reservation_id) === Number(r.reservation_id));
          if (!row) return;
          Object.assign(r, row);
          drawHero(); drawResources(); renderActions();
        }).catch(() => {});
      }
    } catch {
      if (!alive || !orderGate.isCurrent(token)) return;
      rawOrder = null; order = null;
    }
    if (alive && orderGate.isCurrent(token)) renderActions();
  }
  if (api.annualCardForOrder && (orderId || r?.order_id)) {
    paySec.el.addEventListener('toggle', () => {
      if (!paySec.el.open || annualBox.dataset.loaded) return;
      annualBox.dataset.loaded = '1';
      api.annualCardForOrder(orderId || r.order_id).then((info) => {
        if (!alive || !info) return;
        const panel = annualCardPanel(info);
        if (panel) annualBox.replaceChildren(h('div', { 'data-testid': 'order-annual-card' }, h('h4', { text: acText('ui.admin.annual_card.title') }), panel));
      }).catch(() => {});
    });
  }
  Promise.all([fetchOrder(), flow ? Promise.resolve(true) : orderFlowEnabled().then((value) => { flowEnabled = value; renderActions(); })]).catch(() => {});
  return d;
}


// Varauksen muutos hallinnasta: sama voimassa oleva RPC ja samat parametrit kuin ennen.
function changeDialog(r, onChange, order = null, can = () => false) {
  const isAdmin = !!can('bookings.override');
  loadBookingTexts(rpc).catch(() => {});
  const day = (iso) => new Date(iso).toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
  const st = { date: day(r.starts_at), session: null, blocks: [] };
  const loads = createLatestGate();
  let open = true;
  const sessionsBox = h('div', { class: 'stack' });
  const warnBox = h('div', { class: 'nb-warn', role: 'status', hidden: true, 'data-testid': 'move-warning' });
  const pst = stepper({ label: 'Henkilömäärä', value: r.persons, min: 1, max: staffPersonsMax({ min_persons: 1 }), size: 'lg', onChange: () => paintMove() }); const persons = pst.input;
  const timeIn = h('input', { type: 'time', step: '300', value: fmtTime(r.starts_at), 'data-testid': 'move-time', 'aria-label': bookingText('off_time') });
  const dateIn = h('input', { type: 'date', value: st.date, onchange: (e) => { st.date = e.target.value; st.session = null; load(); } });
  function paintMove() {
    const base = st.session || (st.slots && !st.slots.length ? { status: 'off_schedule', off_schedule: true, off_code: 'no_session', mode: r.mode, blocked: (st.blocks || []).some((b) => b.starts_at < `${st.date}T23:59` && b.ends_at > `${st.date}T00:00`) } : null);
    const notices = base ? bookingNotices(base, +persons.value || r.persons) : [];
    if (base?.off_schedule && timeIn.value && timeIn.value !== fmtTime(r.starts_at)) notices.push({ kind: 'off', code: 'outside_hours' });
    const seen = new Set();
    const uniq = notices.filter((n) => { const k = n.kind + n.code; if (seen.has(k)) return false; seen.add(k); return true; });
    const shown = bookingAction(uniq, isAdmin).shown;
    warnBox.hidden = !shown.length;
    warnBox.replaceChildren(...shown.map((n) => h('p', { text: noticeText(n) })));
    return uniq;
  }
  async function load() {
    const token = loads.next();
    sessionsBox.replaceChildren(h('p', { class: 'muted', text: 'Ladataan…' }));
    let v;
    try { v = await rpc('admin_day_view', { p_date: st.date }); }
    catch (e) {
      if (open && loads.isCurrent(token)) sessionsBox.replaceChildren(h('p', { class: 'err', text: errMsg(e) }));
      return;
    }
    if (!open || !loads.isCurrent(token)) return;
    st.blocks = v.blocks || [];
    const available = (v.sessions || []).filter((x) => x.product_id === r.product_id && x.status !== 'closed');
    st.slots = available;
    sessionsBox.replaceChildren(available.length ? h('div', { class: 'slotpick', role: 'radiogroup', 'aria-label': 'Uusi vuoro' }, available.map((x) => {
      const same = x.starts_at === r.starts_at;
      const conflict = isPrivateConflict(x) && !same;
      const ok = same || slotBookable(x);
      const caption = same ? 'nykyinen vuoro' : conflict ? bookingText('slot_taken') : x.status === 'available' ? (x.mode === 'exclusive' ? 'vapaa' : `${x.remaining} vapaana`) : x.status === 'full' ? bookingText(isAdmin ? 'slot_full' : 'slot_full_staff') : bookingText('slot_closed');
      const b = h('button', { type: 'button', role: 'radio', 'aria-checked': 'false', class: `slotbtn ${x.status}${conflict ? ' private' : ''}`, 'data-state': conflict ? 'private' : (x.status || ''), disabled: !ok || null, onclick: () => { st.session = same ? null : x; sessionsBox.querySelectorAll('.slotbtn').forEach((y) => y.setAttribute('aria-checked', 'false')); b.setAttribute('aria-checked', 'true'); paintMove(); } },
        h('strong', { text: `${fmtTime(x.starts_at)}–${fmtTime(x.ends_at)}` }), h('small', { text: caption }));
      return b;
    })) : empty(bookingText('off_no_rule')));
    paintMove();
  }
  const changeUi = staffInvoiceChange(order);
  timeIn.addEventListener('input', () => paintMove());
  const f = h('form', { class: 'stack', onsubmit: (ev) => { ev.preventDefault(); run(f.querySelector('button[type=submit]'), async () => {
    const notices = paintMove();
    const custom = !st.session && timeIn.value && (st.date !== day(r.starts_at) || timeIn.value !== fmtTime(r.starts_at));
    const args = { p_reservation_id: r.reservation_id, p_persons: +persons.value !== r.persons ? +persons.value : null };
    if (st.session) { args.p_rule_id = st.session.rule_id; args.p_date = st.date; }
    else if (custom && r.rule_id) {
      const start = helsinkiIso(`${st.date}T${timeIn.value}`);
      const dur = Math.max(0, new Date(r.ends_at) - new Date(r.starts_at)) || 90 * 60000;
      args.p_rule_id = r.rule_id; args.p_date = st.date; args.p_start = start; args.p_end = new Date(new Date(start).getTime() + dur).toISOString();
    }
    if (args.p_persons == null && !st.session && !custom) throw new Error(bookingText('change_need'));
    let previewNotes = [];
    try {
      const prev = await rpc('admin_preview_booking_limits', { p_kind: 'shift', p_rule_id: args.p_rule_id || r.rule_id, p_date: args.p_date || st.date, p_persons: +persons.value, p_start: args.p_start || null, p_end: args.p_end || null, p_exclude_reservation: r.reservation_id });
      previewNotes = (prev?.overbook || []).map((x) => ({ kind: 'overbook', code: x.code, used: x.used, capacity: x.capacity, persons: x.persons, max: x.max }))
        .concat((prev?.off_schedule || []).map((x) => ({ kind: 'off', code: x.code })))
        .concat((prev?.conflict || []).map((x) => ({ kind: 'conflict', code: x.code })));
    } catch { /* varoitus jää paikalliseksi, jos esikatselua ei vielä ole */ }
    const action = bookingAction([...notices, ...previewNotes], isAdmin);
    if (action.blocked.length) throw new Error(action.blocked.map(noticeText).join(' '));
    const over = action.allowOverbook;
    const off = action.allowOff || !!st.session?.blocked || !!args.p_start || (!st.slots?.length && !!args.p_date);
    if (over || off) {
      const yes = await confirmDialog({
        title: over && off ? bookingText('both_title') : over ? bookingText('over_title') : bookingText('off_title'),
        body: [...action.shown.map(noticeText), over ? bookingText('over_ask') : null, off ? bookingText('off_ask') : null],
        yes: bookingText('confirm_yes'), no: bookingText('confirm_no'), testid: 'move-confirm',
      });
      if (!yes) return;
    }
    args.p_allow_overbook = over;
    args.p_allow_off_schedule = off;
    await rpc('admin_change_booking', args);
    toast('Varaus muutettu'); d.close(); onChange?.();
  }); } },
    h('p', { class: 'muted', text: `Nykyinen: ${spansDays(r.starts_at, r.ends_at) ? formatWhenRange(r.starts_at, r.ends_at, 'fi') : `${fmtDay(r.starts_at)}, ${fmtTime(r.starts_at)}–${fmtTime(r.ends_at)}`}, ${r.persons} hlö` }),
    changeUi.locked ? h('p', { class: 'muted', role: 'status', 'data-testid': 'invoice-change-hint', text: alt('invoiced_hint') }) : null,
    changeUi.locked ? h('p', { class: 'muted', 'data-testid': 'invoice-persons-hint', text: alt('persons_invoiced_hint') }) : null,
    h('div', { class: 'row wrap' }, field('Päivä', dateIn), field(bookingText('off_time'), timeIn), h('div', { class: 'fld' }, h('span', { class: 'fld-lab', text: 'Henkilömäärä' }), pst.node)),
    sessionsBox, warnBox,
    h('button', { class: 'btn primary', type: 'submit', text: 'Tallenna muutos' }));
  const d = dialog(`Muuta varausta #${r.order_no}`, f);
  d.addEventListener('close', () => { open = false; });
  load();
}
