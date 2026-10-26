// Varausdialogi 04: yksi varauksen tietonäkymä kaikille viidelle avaustavalle.
import { rpc, fn, select as dbSelect } from '../sb.js';
import { createTalousApi, normOrder } from '../talous-api.js';
import { canAddPurchase, isFlowEnabledValue } from '../order-reservation-logic.js';
import { reservationActions, telHref, mailHref, createLatestGate } from '../reservation-dialog-logic.js';
import { loadOrderTexts, orderText as tx } from '../orders-texts.js';
import { loadRcTexts } from '../refund-cancel-texts.js';
import { cancelReservationDialog } from './refund-cancel.js';
import { openAddToOrder } from './order-add.js';
import { openOrderPaymentLink } from './order-add.js';
import { formDialog } from './talous-ui.js';
import { t } from '../talous-i18n.js';
import { addonPicker } from './addons.js';
import { reservationAddonLocks, addonReductionError } from '../addon-lock-logic.js';
import { alt } from '../addon-lock-texts.js';
import { nbt } from '../nb-texts.js';
import { memoText } from '../day-memos-texts.js';
import { stepper } from '../stepper.js';
import { icon } from '../icons.js';
import { h, dialog, toast, run, fmtDay, fmtTime, fmtDT, money, statusBadge, payBadge, sourceBadge, isJohku, field, badge, empty, errMsg } from '../ui.js';
import { legsList, resName, resourceBadges, hasLegs } from './legs.js';
import { missingOpen, grantButton } from './therapist.js';
import { optionBadge, optionOf, optionPicker, ot, optErr } from '../options.js';
import { orderVoucherBox } from './voucher-redeem.js';

let flowPromise;
function orderFlowEnabled() {
  if (!flowPromise) flowPromise = dbSelect('settings', { select: 'value', key: 'eq.admin_order_reservation_flow_enabled', limit: 1 })
    .then(isFlowEnabledValue).catch(() => false);
  return flowPromise;
}
const list = (...nodes) => nodes.flat(Infinity).filter((n) => n !== null && n !== undefined && n !== false);
const dd = (label, value) => value == null || value === '' ? [] : [h('dt', { text: label }), h('dd', { text: value })];

export function reservationDialog(r, { methods = [], onChange, refs, can = () => true, flow = null } = {}) {
  loadOrderTexts(rpc).catch(() => {});
  const api = createTalousApi({ rpc, io: { fn } });
  const ctx = { can, refs };
  const body = h('div', { class: 'stack rd-dialog' });
  const d = dialog(r.product_name || tx('ui.admin.res.order_no', { no: r.order_no }), body);
  let alive = true;
  const orderGate = createLatestGate();
  const dayGate = createLatestGate();
  d.addEventListener('close', () => { alive = false; });
  let rawOrder = null, order = null, flowEnabled = !!flow, currentExtras = [], reservation = null;
  const after = () => { d.close(); onChange?.(); };
  const act = (label, job, cls = 'btn', testid = null) => {
    const btn = h('button', { type: 'button', class: cls, 'data-testid': testid, text: label,
      onclick: () => run(btn, async () => { await job(); toast('Tallennettu'); after(); }) });
    return btn;
  };
  const status = (s) => rpc('admin_set_reservation_status', { p_reservation_id: r.reservation_id, p_status: s, p_reason: null });
  const summary = h('section', { class: 'rd-summary', 'data-testid': 'res-summary', 'aria-label': tx('ui.admin.res.summary_label') },
    h('strong', { class: 'rd-when', text: `${fmtDay(r.starts_at)}, ${fmtTime(r.starts_at)}–${fmtTime(r.ends_at)}` }),
    h('div', { class: 'muted rd-meta', text: [tx(r.mode === 'exclusive' ? 'ui.admin.res.persons_private' : 'ui.admin.res.persons_shared', { n: r.persons }), r.space_code ? resName(refs, r.space_code) : null, optionOf(r).name].filter(Boolean).join(' · ') }),
    h('div', { class: 'rd-badges' }, statusBadge(r.status), payBadge(r.payment_status),
      isJohku(r) ? sourceBadge(r) : null, r.annual_card_id ? badge('warn', 'Vuosikortti') : null,
      r.status === 'pending' && r.hold_expires_at ? h('small', { text: tx('ui.admin.res.hold_until', { time: fmtTime(r.hold_expires_at) }) }) : null),
    !can('payments.manage') ? h('small', { class: 'muted', text: tx('ui.admin.res.order_no', { no: r.order_no }) }) : null);
  const alerts = h('div', { class: 'rd-alerts', hidden: true }); summary.append(alerts);
  const customer = h('section', { class: 'rd-card rd-customer', 'data-testid': 'res-customer' },
    h('h3', { text: tx('ui.admin.res.customer') }));
  const contact = h('div', { class: 'rd-contact' });
  const renderCustomer = (o = {}) => {
    const phone = telHref(r.customer_phone);
    const email = mailHref(r.customer_email);
    contact.replaceChildren(...list(
      r.customer_name ? h('strong', { text: r.customer_name }) : null,
      o.customer_kind === 'company' && o.billing?.company ? h('strong', { text: o.billing.company }) : null,
      phone ? h('a', { href: phone, 'aria-label': tx('ui.admin.res.call', { phone: r.customer_phone }), text: r.customer_phone }) : null,
      email ? h('a', { href: email, 'aria-label': tx('ui.admin.res.email', { email: r.customer_email }), text: r.customer_email }) : null,
      o.customer_note ? h('div', {}, h('small', { class: 'muted', text: tx('ui.admin.res.customer_message') }), h('p', { text: o.customer_note })) : null));
  };
  customer.append(contact); renderCustomer();

  // Jokaisen päätoiminnon paikka on vakio: haku ei siirrä jo renderöityjä osioita.
  const primary = h('div', { class: 'tl-actions rd-actions', 'data-testid': 'res-primary-actions', hidden: true });
  const payment = h('section', { class: 'rd-card rd-payment', 'data-testid': 'res-payment', hidden: true },
    h('h3', { text: tx('ui.admin.res.payment_title') }));
  const sums = h('dl', { class: 'tl-sums' }); const voucher = h('div', { class: 'rd-voucher', hidden: true });
  const paymentActions = h('div', { class: 'rd-payment-actions' }); payment.append(sums, voucher, paymentActions);
  const contents = h('section', { class: 'rd-card rd-contents', 'data-testid': 'res-contents', hidden: true },
    h('h3', { text: tx('ui.admin.res.contents_title') }));
  const optBox = h('div', { class: 'opt-box', 'data-testid': 'option-box', hidden: true });
  const addonsBox = h('div', { class: 'addons-box' }); contents.append(optBox, addonsBox);
  const noteBox = h('section', { class: 'rd-card res-note-editor', 'data-testid': 'res-note-editor' });
  const storedNote = String(r.notes || '');
  const mayEditNote = can('bookings.manage') ? true : false;
  if (mayEditNote) {
    const notes = h('textarea', { name: 'reservation_note', rows: 2, maxlength: 1000, value: storedNote });
    const save = h('button', { type: 'button', class: 'btn sm', hidden: true, 'data-testid': 'res-note-save',
      text: memoText('ui.admin.day_memos.res_note_save'), onclick: () => run(save, async () => {
        const updated = await rpc('admin_set_reservation_note', { p_reservation_id: r.reservation_id, p_notes: notes.value });
        r.notes = updated?.notes ?? null; toast(memoText('ui.admin.day_memos.res_note_saved')); after();
      }) });
    notes.addEventListener('input', () => { save.hidden = notes.value === storedNote; });
    noteBox.append(field(memoText('ui.admin.day_memos.res_note_label'), notes), save);
  } else if (storedNote) {
    noteBox.append(h('h3', { text: memoText('ui.admin.day_memos.res_note_label') }), h('p', { text: storedNote }));
  } else noteBox.hidden = true;
  const secondary = h('div', { class: 'row wrap rd-secondary', 'data-testid': 'res-secondary-actions', 'aria-label': tx('ui.admin.res.other_actions'), hidden: true });
  const more = h('details', { class: 'rd-more', 'data-testid': 'res-more' },
    h('summary', { text: tx('ui.admin.res.more_details') }));
  const resBox = h('div', { class: 'resbox' });
  const moreDetails = h('dl', { class: 'kv' }); const billingBox = h('div', { class: 'rd-billing' });
  more.append(moreDetails, resBox, billingBox);
  const move = h('details', { class: 'rd-more rd-move', 'data-testid': 'res-move', hidden: true },
    h('summary', { text: tx('ui.admin.res.move_title') }));
  const moveBody = h('div', { class: 'moverow' }); move.append(moveBody);
  body.append(...list(summary, customer, primary, payment, contents, noteBox.hidden ? null : noteBox, secondary, more, move));

  function drawResources() {
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
        h('strong', { text: 'Puuttuu työvuorosta' }), grantButton(r, { ctx: { can }, onDone: after })) : null,
      r.option_missing ? h('p', { class: 'opt-warn', 'data-testid': 'option-missing-hint' }, optionBadge({ option_missing: true }), ' ', ot('missingHint')) : null));
    alerts.hidden = !alerts.childNodes.length;
  }
  drawResources();
  if (r.quota_exempt === undefined && r.reservation_id && (r.space_code || hasLegs(r))) {
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
        legs: item.legs?.length ? item.legs : r.legs });
      drawResources(); renderActions();
    }).catch(() => {});
  }

  function editAddons(ad, raw) {
    // booking_180: olemassa olevien lisäpalveluiden vähentäminen käyttää palvelimen lukitussääntöä.
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
        catch (e) { error.textContent = errMsg(e); error.hidden = false; error.focus(); }
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
    const editable = ['pending', 'confirmed'].includes(r.status) && can('bookings.manage');
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

  function drawOrder(token) {
    if (!rawOrder || !order || !alive || !orderGate.isCurrent(token)) return;
    payment.hidden = false; contents.hidden = false;
    const b = order.balance || {}; const s = (key, value, cls = '') => [h('dt', { text: t(key) }), h('dd', { class: cls, text: money(value) })];
    sums.replaceChildren(...list(s('order.total', b.total), s('order.paid', b.paid),
      Number(b.unpaid) > 0 ? s('order.unpaid', b.unpaid, 'due') : null,
      Number(b.pending_link) > 0 ? s('order.pendingLink', b.pending_link) : null));
    const actions = reservationActions(r, { can, order, rawOrder, flowEnabled });
    const paymentNodes = [];
    if (actions.payment.recordPayment) {
      const method = h('select', { name: 'method' }, methods.filter((m) => m.active && m.is_manual).map((m) => h('option', { value: m.code, text: m.label })));
      const amount = h('input', { type: 'number', step: '0.01', min: '0.01', value: Number(b.unpaid || r.total_gross) });
      paymentNodes.push(h('details', { class: 'rd-more', 'data-testid': 'res-record-payment' }, h('summary', { text: 'Kirjaa maksu' }),
        h('div', { class: 'stack' }, field('Maksutapa', method), field('Summa €', amount),
          act('Kirjaa maksu', () => {
            const unpaid = Number(b.unpaid || 0);
            const amt = Math.round(Number(amount.value) * 100) / 100;
            if (!(amt > 0) || amt > unpaid + 0.005) throw new Error(t('refund.badAmount'));
            return rpc('admin_record_payment', { p_order_id: r.order_id, p_method: method.value, p_amount: amt });
          }, 'btn primary'))));
    }
    if (actions.payment.openOrder) {
      paymentNodes.push(h('a', { class: 'order-link', 'data-testid': 'order-link',
        href: flow?.orderHref?.(r.order_no) || `#/talous?tab=orders&order=${encodeURIComponent(r.order_no)}`,
        text: flow?.orderLinkText?.(r.order_no) || nbt('nb.orderLink', { no: r.order_no }), onclick: () => d.close() }));
    }
    paymentActions.replaceChildren(...paymentNodes);
    reservation = (rawOrder.reservations || []).find((x) => String(x.id) === String(r.reservation_id)) || {};
    currentExtras = reservation.addons || [];
    drawOption(reservation);
    addonsBox.replaceChildren(...list(h('h4', {}, icon('leaf', 20), ' Lisäpalvelut'),
      currentExtras.length ? h('ul', { class: 'reslist' }, currentExtras.map((a) => h('li', { class: 'resrow' },
        h('span', { text: `${a.quantity} × ${a.name}` }), h('span', { class: 'meta', text: money(a.line_total) })))) : h('p', { class: 'muted', text: 'Ei lisäpalveluita.' }),
      actions.editAddons ? h('button', { type: 'button', class: 'btn sm', 'data-testid': 'res-edit-addons', text: 'Muokkaa lisäpalveluita', onclick: () => editAddons(currentExtras, rawOrder) }) : null));
    renderCustomer(rawOrder); drawResources();
    if (rawOrder.customer_kind === 'company' && rawOrder.billing) {
      const x = rawOrder.billing;
      billingBox.replaceChildren(h('h4', { text: 'Yritysasiakas – laskutustiedot' }), h('dl', { class: 'kv' }, ...list(
        dd('Yritys', x.company), dd('Y-tunnus', x.business_id),
        dd('Osoite', [x.street, [x.zip, x.city].filter(Boolean).join(' ')].filter(Boolean).join(', ')),
        dd('Verkkolasku', x.einvoice_address && [x.einvoice_address, x.einvoice_operator].filter(Boolean).join(' / ')),
        dd('Viite', rawOrder.invoice_reference),
        dd('Yhteyshenkilö', [x.contact_name, x.contact_email, x.contact_phone].filter(Boolean).join(' · ')))));
    }
    orderVoucherBox({ rpc, orderId: r.order_id, onChanged: () => { fetchOrder(); onChange?.(); } }).then((node) => {
      if (!alive || !orderGate.isCurrent(token)) return;
      voucher.replaceChildren(...list(node)); voucher.hidden = !node;
    }).catch(() => {});
  }

  async function doPurchase() {
    if (flow?.addPurchase) { d.close(); flow.addPurchase(order); return; }
    d.close(); await openAddToOrder({ api, ctx, order, reservationId: r.reservation_id, onDone: onChange });
  }
  function doLink() {
    if (flow?.createLink) { d.close(); flow.createLink(order); return; }
    d.close(); openOrderPaymentLink({ api, ctx, order, onDone: onChange });
  }
  function renderActions() {
    const options = reservationActions(r, { can, order, rawOrder, flowEnabled, now: new Date() });
    const actions = {
      confirm: () => act('Vahvista', () => status('confirmed'), 'btn primary', 'res-confirm'),
      addPurchase: () => h('button', { type: 'button', class: 'btn primary', 'data-testid': 'order-reservation-add', text: tx('ui.admin.res.add_purchase'), onclick: doPurchase }),
      createLink: () => h('button', { type: 'button', class: 'btn', 'data-testid': 'order-reservation-create-link', text: tx('ui.admin.res.payment_link'), onclick: doLink }),
      arrive: () => act('Merkitse saapuneeksi', () => status('completed'), 'btn', 'res-arrive'),
      change: () => h('button', { type: 'button', class: 'btn', 'data-testid': 'res-change', text: 'Muuta varausta', onclick: () => { d.close(); changeDialog(r, onChange); } }),
      noShow: () => h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'res-no-show', text: 'Ei saapunut', onclick: () => formDialog(tx('ui.admin.res.no_show_title'), [h('p', { text: tx('ui.admin.res.no_show_text') })], tx('ui.admin.res.no_show_submit'), async () => { await status('no_show'); after(); }) }),
      cancel: () => h('button', { type: 'button', class: 'btn danger rd-danger', 'data-testid': 'res-cancel', text: 'Peru varaus', onclick: async (event) => {
        const btn = event.currentTarget; btn.disabled = true;
        try { await loadRcTexts(rpc); await cancelReservationDialog(r, {
          rpc, canRefund: !!can('payments.refund'), online: createTalousApi({ rpc, io: { fn } }), onDone: after
        }); } finally { btn.disabled = false; }
      } })
    };
    primary.replaceChildren(...options.primary.map((key) => actions[key]())); primary.hidden = !options.primary.length;
    secondary.replaceChildren(...options.secondary.map((key) => actions[key]())); secondary.hidden = !options.secondary.length;
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
  renderActions();
  async function fetchOrder() {
    const token = orderGate.next();
    try {
      const raw = await rpc('admin_get_order', { p_order_id: r.order_id });
      if (!alive || !orderGate.isCurrent(token)) return;
      rawOrder = raw; order = normOrder(raw); drawOrder(token);
    } catch {
      if (!alive || !orderGate.isCurrent(token)) return;
      rawOrder = null; order = null;
    }
    if (alive && orderGate.isCurrent(token)) renderActions();
  }
  Promise.all([fetchOrder(), flow ? Promise.resolve(true) : orderFlowEnabled().then((value) => { flowEnabled = value; renderActions(); })]).catch(() => {});
  return d;
}

// Varauksen muutos hallinnasta: sama voimassa oleva RPC ja samat parametrit kuin ennen.
function changeDialog(r, onChange) {
  const day = (iso) => new Date(iso).toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
  const st = { date: day(r.starts_at), session: null };
  const loads = createLatestGate();
  let open = true;
  const sessionsBox = h('div', { class: 'stack' });
  const pst = stepper({ label: 'Henkilömäärä', value: r.persons, min: 1, max: 99, size: 'lg' }); const persons = pst.input;
  const dateIn = h('input', { type: 'date', value: st.date, onchange: (e) => { st.date = e.target.value; st.session = null; load(); } });
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
    const available = (v.sessions || []).filter((x) => x.product_id === r.product_id && x.status !== 'closed');
    sessionsBox.replaceChildren(available.length ? h('div', { class: 'slotpick', role: 'radiogroup', 'aria-label': 'Uusi vuoro' }, available.map((x) => {
      const same = x.starts_at === r.starts_at;
      const ok = x.status === 'available' || same;
      const b = h('button', { type: 'button', role: 'radio', 'aria-checked': 'false', class: `slotbtn ${x.status}`, disabled: !ok || null, onclick: () => { st.session = same ? null : x; sessionsBox.querySelectorAll('.slotbtn').forEach((y) => y.setAttribute('aria-checked', 'false')); b.setAttribute('aria-checked', 'true'); } },
        h('strong', { text: `${fmtTime(x.starts_at)}–${fmtTime(x.ends_at)}` }), h('small', { text: same ? 'nykyinen vuoro' : ok ? (x.mode === 'exclusive' ? 'vapaa' : `${x.remaining} vapaana`) : x.status === 'full' ? 'täynnä' : 'ei varattavissa' }));
      return b;
    })) : empty('Ei samantyyppisiä vuoroja tälle päivälle.'));
  }
  const f = h('form', { class: 'stack', onsubmit: (ev) => { ev.preventDefault(); run(f.querySelector('button[type=submit]'), async () => {
    const args = { p_reservation_id: r.reservation_id, p_persons: +persons.value !== r.persons ? +persons.value : null };
    if (st.session) { args.p_rule_id = st.session.rule_id; args.p_date = st.date; }
    if (args.p_persons == null && !st.session) throw new Error('Valitse uusi vuoro tai muuta henkilömäärää');
    await rpc('admin_change_booking', args);
    toast('Varaus muutettu'); d.close(); onChange?.();
  }); } },
    h('p', { class: 'muted', text: `Nykyinen: ${fmtDay(r.starts_at)}, ${fmtTime(r.starts_at)}–${fmtTime(r.ends_at)}, ${r.persons} hlö` }),
    h('div', { class: 'row wrap' }, field('Päivä', dateIn), h('div', { class: 'fld' }, h('span', { class: 'fld-lab', text: 'Henkilömäärä' }), pst.node)), sessionsBox,
    h('button', { class: 'btn primary', type: 'submit', text: 'Tallenna muutos' }));
  const d = dialog(`Muuta varausta #${r.order_no}`, f);
  d.addEventListener('close', () => { open = false; });
  load();
}
