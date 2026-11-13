// Tilausnäkymä v3 (PR 1): koko tilausnäkymä reitillä #/tilaukset/<tilausnro> (työpöytä 2 saraketta, mobiili koko näyttö + alapalkki).
// Data: admin_get_order (booking_278: invoice, overpaid, refundable_by_payment, voucher_claims, reservation_meta) ja laiskasti
// admin_order_history (muutoshistoria). Kaikki kirjoitukset nykyisillä RPC:illä; palvelin päättää oikeudet ja lukot, tämä vain näyttää.
// Logiikka: ../order-view-logic.js. Tekstit: ../order-view-texts.js (ui.admin.order_view.*). Peruutus: ./order-cancel-flow.js.
// Poisto (PR #334, order-card-delete.js) EI kuulu tähän: vaarallinen alue jättää sille paikan [data-slot=order-delete].
import { rpc as sbRpc, fn as sbFn, select as dbSelect, functionUrl, fnBlob } from '../sb.js';
import { h, dialog, toast, run, errMsg, field } from '../ui.js';
import { icon } from '../icons.js';
import { fmt, getLang, t as tt, has as hasText } from '../talous-i18n.js';
import { createTalousApi, normOrder, absLink } from '../talous-api.js';
import { telHref, mailHref, createLatestGate, moveTarget } from '../reservation-dialog-logic.js';
import { orderBreakdown, vatRateLabel } from '../order-card-logic.js';
import { reservationAddonLocks, addonReductionError } from '../addon-lock-logic.js';
import { alt } from '../addon-lock-texts.js';
import { invoiceHref } from '../invoice-link.js';
import { optionPicker, ot, optErr, optionOf } from '../options.js';
import { resName } from './legs.js';
import { addonPicker } from './addons.js';
import { showReceipt, resendDialog } from './talous-receipts.js';
import { openOrderPaymentLink, openOrderRecordPayment, openAddToOrder } from './order-add.js';
import { openCancelFlow } from './order-cancel-flow.js';
import { loadRefundInfo, openOverpaymentFlow, overpaymentButton } from './partial-refund-flow.js';
import { overpaymentView } from '../partial-refund-logic.js';
import { ov, loadOvTexts } from '../order-view-texts.js';
import { loadOrderTexts, orderText } from '../orders-texts.js';
import {
  orderModel, orderBadges, reservationRowActions, reservationBadge, reservationWhen, paymentBox, nextStep, primaryActions, refundTargets, refundSuggestion,
  moreMenu, collectNotes, buildTimeline, helDay, isWide, placeOverflowMenu,
} from '../order-view-logic.js';

const list = (...n) => n.flat(Infinity).filter((x) => x != null && x !== false);
const money = (n) => fmt.money(n);
const sec = (title, testid, ...kids) => h('section', { class: 'ov-card', 'data-testid': testid },
  title ? h('div', { class: 'ov-card-head' }, typeof title === 'string' ? h('h2', { class: 'ov-h', text: title }) : title) : null, ...kids);

/** Varauksen ajankohta: "Tänään ke 11.11. · 16:30–18:00" / "to 19.11.2026 · 16:00–17:30". */
export function whenText(r, now = new Date()) {
  if (!r?.starts_at) return '–';
  const lang = getLang() === 'en' ? 'en-GB' : 'fi-FI';
  const s = new Date(r.starts_at);
  const wd = new Intl.DateTimeFormat(lang, { timeZone: 'Europe/Helsinki', weekday: 'short' }).format(s);
  const today = reservationWhen(r, now) === 'today';
  const date = new Intl.DateTimeFormat(lang, { timeZone: 'Europe/Helsinki', day: 'numeric', month: 'numeric', ...(today ? {} : { year: 'numeric' }) }).format(s);
  const span = `${fmt.time(r.starts_at)}${r.ends_at ? `–${fmt.time(r.ends_at)}` : ''}`;
  return `${today ? `${ov('order_view.today_prefix')} ` : ''}${wd} ${date} · ${span}`;
}

export function badgeNodes(badges) {
  return badges.map((b) => h('span', { class: `badge ${b.kind}`, 'data-testid': b.problem ? 'ov-problem-badge' : null,
    text: ov(`order_view.${b.key}`, b.vars ? { ...b.vars, amount: b.vars.amount != null ? money(b.vars.amount) : undefined } : undefined) }));
}

// Kanavan nimi samoista teksteistä kuin tilauslistassa (talous-texts.js src.*), ei omaa kopiota.
const channelText = (m) => (m.source_channel && hasText(`src.${m.source_channel}`) ? tt(`src.${m.source_channel}`) : (m.source_channel || ''));
export { channelText };

const customerTitle = (m) => (m.customer_kind === 'company' || m.customer?.customer_kind === 'company') && m.customer?.company ? m.customer.company : (m.customer?.name || '–');

/** Yhteinen toimintojen suorittaja (koko näkymä, yhteenveto, mobiilipalkki). env = { ctx, rpc, api, dialogs, reload, refs }. */
export function createActionRunner(env) {
  const { ctx, rpc } = env;
  const order = (m) => normOrder(m.raw);
  const done = () => env.reload?.();
  const status = async (id, s) => { await rpc('admin_set_reservation_status', { p_reservation_id: id, p_status: s, p_reason: null }); };
  return {
    async arrive(m, a, btn) { await run(btn, async () => { await status(a.reservation_id, 'completed'); toast(ov('order_view.arrived_done')); done(); }); },
    async confirm(m, a, btn) { await run(btn, async () => { await status(a.reservation_id, 'confirmed'); toast(ov('order_view.confirmed_done')); done(); }); },
    takePayment(m) { const o = order(m); if (env.dialogs?.record) env.dialogs.record(o); else openOrderRecordPayment({ api: env.api, ctx, order: o, onDone: done }); },
    sendLink(m) { const o = order(m); if (env.dialogs?.link) env.dialogs.link(o); else openOrderPaymentLink({ api: env.api, ctx, order: o, onDone: done }); },
    resendLink(m) { this.sendLink(m); },
    openBilling(m) { location.hash = m.invoice?.id ? invoiceHref(m.invoice.id) : '#/laskut'; },
    async refund(m) {
      // booking_283 (PR 3): ylisuoritus + lippu partial_refunds_enabled → ylisuorituksen hyvitysdialogi (palvelin päättää summan ja maksun)
      if (m.overpaid > 0.004 && !m.locked && ctx.can('payments.refund')) {
        const info = await loadRefundInfo(rpc, m.order_id);
        if (overpaymentView(info).show) { openOverpaymentFlow({ model: m, ctx, rpc, api: env.api, onDone: done, info }); return; }
      }
      const o = order(m);
      // Vain hyvitettävissä olevat maksut (booking_278 refundable_by_payment: ei lahjakortti-, kumppani-, vuosikortti- eikä laskumaksuja).
      const refundable = refundTargets(m, o.payments, { can: ctx.can });
      if (env.dialogs?.refund && refundable.length) env.dialogs.refund(o, refundable, { suggest: (p) => refundSuggestion(m, p) });
      else toast(tt('btn.refundNone'), 'warn');   // ei hiljaista epäonnistumista
    },
    addPurchase(m, a = {}) {
      const o = order(m);
      if (env.dialogs?.add) env.dialogs.add(o);
      else openAddToOrder({ api: env.api, ctx, order: o, reservationId: a.reservation_id || null, onDone: done });
    },
    async copyLink(m, a) {
      const url = absLink(a.link_path, m.raw);
      try { await navigator.clipboard.writeText(url); toast(ov('order_view.link_copied')); }
      catch { toast(ov('order_view.copy_failed', { link: url }), 'warn'); }
    },
    receipt(m) {
      const all = [...(m.receipts || [])];
      const r = all[all.length - 1];
      if (!r) { toast(ov('order_view.no_receipt'), 'warn'); return; }
      showReceipt({ api: env.api, ctx, receipt: { ...r, kind: r.kind || 'receipt' } });
    },
    resendReceipt(m) {
      const r = [...(m.receipts || [])].pop();
      if (r) resendDialog({ api: env.api, receipt: r });
    },
    openCustomer(m) { if (m.customer?.id) location.hash = `#/asiakkaat/${m.customer.id}`; },
    cancel(m, a = {}) { openCancelFlow({ model: m, reservationId: a.reservation_id || null, ctx, rpc, api: env.api, onDone: done }); },
  };
}

/** Pääpainike (yhteenveto, seuraava askel, mobiilipalkki). */
export function actionButton(a, m, runner, { primary = false, testPrefix = 'ov-act' } = {}) {
  const labels = {
    arrive: () => ov('order_view.act.arrive'),
    takePayment: () => (a.amount ? ov('order_view.act.take_payment_amount', { amount: money(a.amount) }) : ov('order_view.act.take_payment')),
    sendLink: () => ov('order_view.act.send_link'),
    resendLink: () => ov('order_view.act.resend_link'),
    openBilling: () => ov('order_view.act.open_billing'),
  };
  const b = h('button', { type: 'button', class: `btn${primary ? ' primary' : ''}`, 'data-testid': `${testPrefix}-${a.key}`, 'data-action': a.key },
    a.key === 'arrive' ? icon('check', 18) : null, ' ', labels[a.key]?.() || a.key);
  b.addEventListener('click', () => runner[a.key]?.(m, a, b));
  return b;
}

/** Varausrivi (koko näkymä): aika, tuote, tila, rivin hinta, lisäostot ja tilan mukaiset rivitoiminnot. */
function reservationRow(r, m, env, runner, now) {
  const { ctx, refs } = env;
  const actions = reservationRowActions(r, m, { can: ctx.can, now });
  const b = reservationBadge(r);
  const today = reservationWhen(r, now) === 'today';
  const locks = m.locked ? null : reservationAddonLocks(m.raw, r.id);
  const meta = list(
    r.product_name ? h('strong', { text: r.product_name }) : null,
    optionOf(r)?.name ? [' · ', h('strong', { text: optionOf(r).name })] : null,
    r.persons ? ` · ${ov('order_view.persons', { n: r.persons })}` : null,
    r.space_code ? ` · ${resName(refs, r.space_code)}` : null);
  const addons = (r.addons || []).map((a) => {
    const locked = m.locked || (locks?.locks?.get(Number(a.addon_id))?.quantity > 0);
    return h('div', { class: 'ov-addon', 'data-testid': 'ov-addon' },
      h('span', {}, `${a.quantity} × ${a.name} `, h('small', { class: 'muted', text: `${ov('order_view.addon_tag')}${locked ? ` · ${ov('order_view.addon_locked')}` : ''}` })),
      h('span', { class: 'ov-amt', text: money(a.line_total) }));
  });
  const btn = (key, label, onclick, cls = 'btn sm') => h('button', { type: 'button', class: cls, 'data-testid': `ov-row-${key}`, text: label, onclick });
  const rowBtns = [];
  const extra = [];
  if (actions.includes('confirm')) rowBtns.push(btn('confirm', ov('order_view.act.confirm'), (e) => runner.confirm(m, { reservation_id: r.id }, e.currentTarget), 'btn sm primary'));
  if (actions.includes('change')) rowBtns.push(btn('change', ov('order_view.act.change'), () => openChange(r, m, env)));
  if (actions.includes('option')) (m.reservations.length > 1 ? extra : rowBtns).push(['option', ov('order_view.act.option'), () => openOption(r, env)]);
  if (actions.includes('addons')) (m.reservations.length > 1 ? extra : rowBtns).push(['addons', ov('order_view.act.addons'), () => openAddons(r, m, env)]);
  if (actions.includes('move')) extra.push(['move', ov('order_view.act.move', { space: resName(refs, moveTarget({ ...r, reservation_id: r.id }, ctx.can)) }), () => openMove(r, env)]);
  if (actions.includes('cancel') && m.reservations.length > 1) extra.push(['cancel', ov('order_view.act.cancel'), () => runner.cancel(m, { reservation_id: r.id })]);
  const fixed = rowBtns.map((x) => (Array.isArray(x) ? btn(x[0], x[1], x[2]) : x));
  const menu = extra.length ? overflowMenu(extra, ov('order_view.act.row_more'), 'ov-row-more', { prefer: 'start' }) : null;
  const arrive = actions.includes('arrive') ? (() => {
    const a = h('button', { type: 'button', class: 'btn primary sm', 'data-testid': 'ov-row-arrive' }, icon('check', 16), ' ', ov('order_view.act.arrive'));
    a.addEventListener('click', () => runner.arrive(m, { reservation_id: r.id }, a));
    return a;
  })() : null;
  return h('article', { class: `ov-res${today && ['pending', 'confirmed'].includes(r.status) ? ' is-today' : ''}${['cancelled', 'expired'].includes(r.status) ? ' is-off' : ''}`,
    'data-testid': 'ov-res', 'data-reservation-id': r.id, 'data-status': r.status },
  h('div', { class: 'ov-res-top' }, h('h3', { class: 'ov-res-when', text: whenText(r, now) }), b ? h('span', { class: `badge ${b.kind}`, text: ov(`order_view.${b.key}`) }) : null),
  h('p', { class: 'ov-res-meta' }, ...meta),
  h('div', { class: 'ov-res-price' }, h('small', { class: 'muted', text: ov('order_view.res_index', { i: r.index, n: r.count }) }), h('strong', { text: money(r.item_total) })),
  addons.length ? h('div', { class: 'ov-addons' }, addons) : null,
  fixed.length || menu || arrive ? h('div', { class: 'ov-res-actions' }, h('div', { class: 'row wrap' }, ...fixed, menu), arrive) : null);
}

/** Yksinkertainen ⋯-valikko (details/summary, näppäimistöllä käytettävä). items: [[key, label, onclick]].
 * prefer 'end' = oikeareuna nappiin (otsikko), 'start' = vasen reuna (varausrivi). Avoinna valikko kiinnitetään
 * ruutuun (position:fixed), jotta se ei jää sivupalkin alle eikä leikkaudu ruudun reunasta. */
export function overflowMenu(items, label, testid, { prefer = 'end' } = {}) {
  const list = h('div', { class: 'ov-menu-list', role: 'menu' }, items.map(([key, text, onclick]) => h('button', { type: 'button', role: 'menuitem', class: 'ov-menu-item', 'data-testid': `${testid}-${key}`, text,
    onclick: (e) => { d.open = false; onclick(e); } })));
  const d = h('details', { class: 'ov-menu', 'data-testid': testid },
    h('summary', { class: 'btn sm ov-menu-btn', 'aria-label': label, title: label }, '⋯'),
    list);
  const clear = () => { for (const p of ['position', 'left', 'right', 'top', 'max-width', 'width', 'z-index']) list.style.removeProperty(p); };
  const place = () => {
    if (!d.open) { clear(); return; }
    const btn = d.querySelector('summary');
    const placed = placeOverflowMenu(btn.getBoundingClientRect(), { width: list.offsetWidth, height: list.offsetHeight }, { width: window.innerWidth, height: window.innerHeight }, { prefer });
    list.style.position = 'fixed';
    list.style.left = `${placed.left}px`;
    list.style.right = 'auto';
    list.style.top = `${placed.top}px`;
    list.style.maxWidth = `${placed.maxWidth}px`;
    list.style.zIndex = '60';
  };
  const onWin = () => { if (d.open) place(); };
  d.addEventListener('toggle', () => {
    place();
    if (d.open) {
      window.addEventListener('resize', onWin);
      window.addEventListener('scroll', onWin, true);
    } else {
      window.removeEventListener('resize', onWin);
      window.removeEventListener('scroll', onWin, true);
    }
  });
  d.addEventListener('keydown', (e) => { if (e.key === 'Escape' && d.open) { e.stopPropagation(); d.open = false; d.querySelector('summary').focus(); } });
  return d;
}

// ---- rivitoiminnot nykyisillä RPC:illä ----
function openChange(r, m, env) {
  import('./order-card.js').then(({ changeDialog }) => changeDialog({ ...r, reservation_id: r.id, order_no: m.order_no }, () => env.reload?.(), normOrder(m.raw), env.ctx.can));
}
function openOption(r, env) {
  const choices = r.option_choices || [];
  const error = h('p', { class: 'err', role: 'alert', hidden: true });
  const notify = h('input', { type: 'checkbox', name: 'notify' });
  const picker = optionPicker({ choices, value: r.option?.code || '', label: ot('change'), name: `ovo-${r.id}` });
  const save = h('button', { type: 'submit', class: 'btn primary', text: ot('save') });
  const f = h('form', { class: 'stack', onsubmit: (e) => { e.preventDefault(); run(save, async () => {
    try { const v = await env.rpc('admin_set_reservation_option', { p_reservation_id: r.id, p_option_code: picker.value, p_notify: notify.checked });
      toast(v?.email_queued ? ot('savedMail') : ot('saved')); d.close(); env.reload?.(); }
    catch (err) { error.textContent = optErr(err); error.hidden = false; }
  }); } }, h('p', { class: 'muted', text: `${ot('current')}: ${optionOf(r).name || ot('none')}` }), picker.node, h('label', { class: 'check' }, notify, ` ${ot('notify')}`), error, save);
  const d = dialog(ov('order_view.act.option'), f);
}
function openAddons(r, m, env) {
  const state = reservationAddonLocks(m.raw, r.id);
  env.rpc('admin_list_addons').then((all) => {
    const picker = addonPicker(all, { getPersons: () => r.persons, getMode: () => r.mode, locks: state.locks });
    picker.set((r.addons || []).map((a) => ({ addon_id: a.addon_id, quantity: a.quantity })));
    const error = h('p', { class: 'err', role: 'alert', tabindex: '-1', hidden: state.complete, text: state.complete ? '' : alt('error_unknown') });
    const save = h('button', { class: 'btn primary', type: 'submit', text: ov('order_view.notes_save') });
    const f = h('form', { class: 'stack', onsubmit: (e) => { e.preventDefault(); run(save, async () => {
      const code = addonReductionError(state, picker.value());
      if (code) { error.textContent = alt(code === 'addon_paid' ? 'error_paid' : code === 'addon_link_open' ? 'error_link' : 'error_unknown'); error.hidden = false; error.focus(); return; }
      try { await env.rpc('admin_set_reservation_addons', { p_reservation_id: r.id, p_addons: picker.value() }); toast(ov('order_view.saved')); d.close(); env.reload?.(); }
      catch (err) { error.textContent = (err?.code === 'order_invoiced' || err?.details === 'order_invoiced') ? alt('error_invoiced') : errMsg(err); error.hidden = false; error.focus(); }
    }); } }, picker.node, error, save);
    const d = dialog(ov('order_view.act.addons'), f);
  }).catch((e) => toast(errMsg(e), 'err'));
}
function openMove(r, env) {
  const other = moveTarget({ ...r, reservation_id: r.id }, env.ctx.can);
  if (!other) return;
  const reason = h('input', { name: 'reason', maxlength: 200 });
  const go = h('button', { type: 'submit', class: 'btn primary', text: ov('order_view.act.move', { space: resName(env.refs, other) }) });
  const f = h('form', { class: 'stack', onsubmit: (e) => { e.preventDefault(); run(go, async () => {
    await env.rpc('admin_move_reservation_space', { p_reservation_id: r.id, p_space_code: other, p_reason: reason.value.trim() || null });
    toast(ov('order_view.saved')); d.close(); env.reload?.();
  }); } }, field(orderText('ui.admin.res.move_reason'), reason), go);
  const d = dialog(ov('order_view.act.move', { space: resName(env.refs, other) }), f);
}

// ---- muistiinpanot ----
function notesCard(m, env) {
  const n = collectNotes(m, { can: env.ctx.can });
  const blocks = n.reservations.map((x) => {
    const head = h('div', { class: 'ov-note-head' }, h('span', { class: 'ov-cap', text: ov('order_view.notes_res', { i: x.index, n: x.count, product: x.product_name, when: x.starts_at ? fmt.date(x.starts_at) : '' }) }));
    const body = h('div', { class: 'ov-note-body' });
    const paint = (editing) => {
      if (!editing) {
        body.replaceChildren(...list(x.notes ? h('p', { class: 'ov-note', 'data-testid': 'ov-note-text', text: x.notes })
          : (x.editable ? h('button', { type: 'button', class: 'ov-note-empty', 'data-testid': 'ov-note-add', text: ov('order_view.notes_add'), onclick: () => paint(true) }) : null)));
        return;
      }
      const ta = h('textarea', { rows: 3, maxlength: 2000, 'aria-label': ov('order_view.notes_label', { i: x.index, n: x.count }), 'data-testid': 'ov-note-input' });
      ta.value = x.notes;
      const save = h('button', { type: 'button', class: 'btn primary sm', text: ov('order_view.notes_save'), 'data-testid': 'ov-note-save' });
      save.addEventListener('click', () => run(save, async () => {
        await env.rpc('admin_set_reservation_note', { p_reservation_id: x.reservation_id, p_notes: ta.value });
        toast(ov('order_view.notes_saved')); env.reload?.();
      }));
      body.replaceChildren(ta, h('div', { class: 'row' }, save, h('button', { type: 'button', class: 'btn ghost sm', text: ov('order_view.notes_cancel'), onclick: () => paint(false) })));
      ta.focus();
    };
    if (x.editable && x.notes) head.append(h('button', { type: 'button', class: 'linkish ov-note-edit', 'data-testid': 'ov-note-edit', text: ov('order_view.notes_edit'), onclick: () => paint(true) }));
    paint(false);
    return h('div', { class: 'ov-note-block', 'data-testid': 'ov-note-block', 'data-reservation-id': x.reservation_id }, head, body);
  });
  return sec(ov('order_view.sec.notes'), 'ov-notes', ...blocks,
    n.customer_note ? h('div', { class: 'ov-note-block' }, h('span', { class: 'ov-cap', text: ov('order_view.notes_customer') }), h('p', { class: 'ov-quote', 'data-testid': 'ov-customer-note', text: `”${n.customer_note}”` })) : null,
    n.system_note ? h('div', { class: 'ov-note-block' }, h('span', { class: 'ov-cap', text: ov('order_view.notes_system') }), h('pre', { class: 'ov-sys', 'data-testid': 'ov-system-note', text: n.system_note })) : null);
}

// ---- maksu ----
/**
 * Summalaatikko (yhteenveto + koko tilaus): yksi iso luku ja sitä vastaava otsikko (order-view-logic.js amountSummary).
 * meta=false jättää pienet rivit pois (koko näkymässä samat tiedot ovat alla rivilistana).
 */
const AMT_ICON = { ok: 'tick', due: 'euro', info: 'receipt', warn: 'undo', muted: null };
export function amountBox(d, { meta = true, testid = 'ov-paybox', amountTestid = 'ov-paybox-value' } = {}) {
  if (!d) return null;
  const ico = d.state === 'refunded' || d.state === 'refund_pending' ? 'undo' : AMT_ICON[d.tone];
  const lines = meta ? d.lines.map((x) => ov(`order_view.amt.${x.key}`, x.amount != null ? { amount: money(x.amount) } : null)) : [];
  return h('div', { class: `ov-paybox tone-${d.tone}`, 'data-testid': testid, 'data-state': d.state },
    lines.length ? h('p', { class: 'ov-paybox-meta', 'data-testid': `${testid}-meta` }, lines.flatMap((t, i) => [i ? ' · ' : null, h('span', { text: t })]).filter(Boolean)) : null,
    h('div', { class: 'ov-paybox-main' },
      h('span', { class: 'ov-paybox-label', 'data-testid': `${testid}-label` }, ico ? icon(ico, 16) : null, ov(`order_view.${d.label}`)),
      d.amount != null ? h('strong', { class: 'ov-paybox-value', 'data-testid': amountTestid, text: money(d.amount) }) : null));
}

function paymentCard(m, env, runner) {
  const box = paymentBox(m, { can: env.ctx.can });
  const rows = [
    ['order_view.pay_total', money(box.total)],
    box.display?.state === 'none' && box.paid <= 0.004 ? null : ['order_view.pay_paid', money(box.paid)],   // 0 €:n tilaus: ei "Maksettu 0,00 €" -riviä
    box.refunded > 0.004 ? ['order_view.pay_refunded', money(box.refunded)] : null,
    box.pendingRefund > 0.004 ? ['order_view.amt.refund_pending', money(box.pendingRefund)] : null,   // keskeneräinen hyvitys (requested/processing)
    box.giftCard > 0.004 ? ['order_view.pay_gift', money(box.giftCard)] : null,
    box.partner > 0.004 ? ['order_view.pay_partner', money(box.partner)] : null,
    !box.locked ? ['order_view.pay_link', box.openLink ? (box.linkSentAt ? ov('order_view.pay_link_sent', { when: fmt.dt(box.linkSentAt) }) : ov('order_view.pay_link_open', { amount: money(box.openLink.amount) })) : (box.linkSentAt ? ov('order_view.pay_link_sent', { when: fmt.dt(box.linkSentAt) }) : ov('order_view.pay_link_none'))] : null,
    ['order_view.pay_invoice', box.invoice?.invoice_no || ov('order_view.pay_invoice_none')],
    box.invoice?.due_date ? ['order_view.pay_due', `${fmt.date(box.invoice.due_date)} · ${box.invoice.status ? ov(`order_view.inv_status.${box.invoice.status}`) : ''}`] : null].filter(Boolean);
  const btns = list(
    box.actions.openBilling ? h('a', { class: 'btn ov-wide', href: box.invoice?.id ? invoiceHref(box.invoice.id) : '#/laskut', 'data-testid': 'ov-open-billing', text: ov('order_view.act.open_billing') }) : null,
    !box.locked && box.actions.sendLink ? h('button', { type: 'button', class: 'btn ov-wide', 'data-testid': 'ov-pay-link', text: ov(box.openLink || box.linkSentAt ? 'order_view.act.resend_link' : 'order_view.act.send_link'), onclick: () => runner.sendLink(m) }) : null,
    !box.locked && box.actions.takePayment ? h('button', { type: 'button', class: 'btn ov-wide', 'data-testid': 'ov-pay-take', text: ov('order_view.act.take_payment'), onclick: () => runner.takePayment(m) }) : null,
    // Ylisuoritus jo kokonaan hyvityksessä: ei Hyvitä maksu -nappia kortilla (⋯-valikossa yleinen hyvitys säilyy).
    !box.locked && box.actions.refund && !(box.refundCovered > 0.004 && m.overpaid <= 0.004) ? h('button', { type: 'button', class: 'btn ghost ov-wide', 'data-testid': 'ov-pay-refund', text: ov('order_view.more_refund'), onclick: () => runner.refund(m) }) : null);
  return sec(ov('order_view.sec.payment'), 'ov-payment',
    amountBox(box.display, { meta: false, testid: 'ov-pay-box', amountTestid: 'ov-pay-amount' }),
    h('dl', { class: 'ov-kv' }, rows.map(([k, v]) => [h('dt', { text: ov(k) }), h('dd', { text: v })])),
    btns.length ? h('div', { class: 'ov-stack' }, btns) : null,
    h('div', { class: 'ov-stack', 'data-slot': 'ov-over', 'data-testid': 'ov-over-slot' }),   // PR 3: "Hyvitä ylisuoritus…" lisätään asynkronisesti, kun palvelin sallii
    box.locked ? h('p', { class: 'muted ov-small', 'data-testid': 'ov-pay-locked', text: ov('order_view.pay_locked_note') }) : null,
    !box.locked && box.actions.sendLink && (box.openLink || box.linkSentAt) ? h('p', { class: 'muted ov-small', text: ov('order_view.pay_link_hint') }) : null);
}

function customerCard(m, env) {
  const c = m.customer || {};
  if (!c.name && !c.email && !c.phone) return sec(ov('order_view.sec.customer'), 'ov-customer', h('p', { class: 'muted', text: ov('order_view.cust_none') }));
  const company = c.customer_kind === 'company' && c.company;
  return sec(h('div', { class: 'row between' }, h('h2', { class: 'ov-h', text: ov('order_view.sec.customer') }),
    c.id ? h('a', { class: 'ov-link', href: `#/asiakkaat/${c.id}`, 'data-testid': 'ov-customer-link', text: ov('order_view.customer_view') }) : null), 'ov-customer',
  h('p', { class: 'ov-cust-name' }, h('strong', { text: company ? c.company : c.name })),
  company ? h('p', { class: 'muted ov-small', text: [c.name, c.business_id ? ov('order_view.cust_business_id', { id: c.business_id }) : null].filter(Boolean).join(' · ') }) : null,
  contactButtons(c));
}

export function contactButtons(c, { big = false } = {}) {
  const tel = telHref(c?.phone), mail = mailHref(c?.email);
  return h('div', { class: `row wrap ov-contact${big ? ' big' : ''}` },
    tel ? h('a', { class: 'btn sm', href: tel, 'data-testid': 'ov-call' },  big ? ov('order_view.act.call') : c.phone) : null,
    mail ? h('a', { class: 'btn sm', href: mail, 'data-testid': 'ov-email' }, icon('mail', 16), ' ', big ? ov('order_view.act.email') : c.email) : null);
}

function breakdownCard(m) {
  const bd = orderBreakdown(normOrder(m.raw));
  if (!bd || bd.empty) return null;
  const vatTotal = bd.vatByRate.reduce((a, v) => a + v.vat, 0);
  const vat = bd.vatByRate.length ? h('details', { class: 'ov-vat' }, h('summary', { text: ov('order_view.bd_vat_toggle') }),
    h('dl', { class: 'ov-kv' }, bd.vatByRate.map((v) => [h('dt', { text: vatRateLabel(v.rate) }), h('dd', { text: money(v.vat) })]))) : null;
  return sec(h('div', { class: 'row between' }, h('h2', { class: 'ov-h', text: ov('order_view.sec.breakdown') }), vat), 'ov-breakdown',
    h('table', { class: 'ov-bd' }, h('tbody', {}, bd.rows.map((r) => h('tr', { class: `${r.child ? 'is-child' : ''}${r.cancelled ? ' is-off' : ''}` },
      h('td', { text: r.child ? `${r.quantity} × ${r.name}` : r.name }), h('td', { class: 'muted', text: r.vat_rate != null ? ov('order_view.bd_vat_rate', { rate: vatRateLabel(r.vat_rate) }) : '' }), h('td', { class: 'r', text: money(r.gross) })))),
    h('tfoot', {}, h('tr', {}, h('th', {}, ov('order_view.bd_total'), ' ', h('small', { class: 'muted', text: bd.vatByRate.length ? ov('order_view.bd_vat', { amount: money(vatTotal) }) : '' })), h('td'), h('th', { class: 'r', text: money(bd.total) })))));
}

function timelineCard(m, env) {
  const ul = h('ol', { class: 'ov-tl', 'data-testid': 'ov-timeline' });
  const paint = (history) => {
    const ev = buildTimeline(m, history);
    ul.replaceChildren(...(ev.length ? ev.map((e) => h('li', { class: `ov-tl-row k-${e.kind}`, 'data-source': e.source },
      h('time', { datetime: e.at, text: fmt.dt(e.at) }), h('span', { class: 'ov-dot', 'aria-hidden': 'true' }),
      h('span', {}, ov(`order_view.tl.${e.key}`, { ...e.vars, amount: e.vars.amount != null ? money(e.vars.amount) : undefined }), e.vars.who ? h('small', { class: 'muted', text: ` ${ov('order_view.tl_by', { who: e.vars.who })}` }) : null)))
      : [h('li', { class: 'muted', text: ov('order_view.tl_empty') })]));
  };
  paint(null);
  const more = h('button', { type: 'button', class: 'linkish ov-small', 'data-testid': 'ov-history', text: ov('order_view.tl_history') });
  const status = h('p', { class: 'muted ov-small', role: 'status', hidden: true });
  more.addEventListener('click', async () => {
    more.disabled = true; status.hidden = false; status.textContent = ov('order_view.tl_history_loading');
    try {
      const hist = await env.rpc('admin_order_history', { p_order_id: m.order_id, p_limit: 200 });
      paint(hist);
      status.textContent = (hist?.events || []).length ? '' : ov('order_view.tl_history_none');
      status.hidden = !status.textContent; more.hidden = true;
    } catch (e) { status.textContent = ov('order_view.tl_history_failed', { error: errMsg(e) }); more.disabled = false; }
  });
  return sec(ov('order_view.sec.timeline'), 'ov-timeline-card', ul, h('div', {}, more, status));
}

function dangerCard(m, env, runner) {
  const active = m.active || [];
  const canBook = env.ctx.can('bookings.manage');
  const slot = h('div', { 'data-slot': 'order-delete', 'data-testid': 'ov-delete-slot' });   // PR #334 (order-card-delete.js) kytkee poiston tähän
  const cancel = canBook && active.length ? h('button', { type: 'button', class: 'btn danger-ghost sm', 'data-testid': 'ov-cancel', text: ov(active.length > 1 ? 'order_view.danger_cancel_multi' : 'order_view.danger_cancel'), onclick: () => runner.cancel(m) }) : null;
  if (!cancel && !slot) return null;
  return h('section', { class: 'ov-card ov-danger', 'data-testid': 'ov-danger' }, h('h2', { class: 'ov-h', text: ov('order_view.sec.danger') }),
    h('div', { class: 'row wrap' }, cancel, slot),
    !active.length ? h('p', { class: 'muted ov-small', text: ov('order_view.danger_nothing') }) : null,
    m.locked ? h('p', { class: 'ov-small err', text: ov('order_view.danger_invoiced') }) : null);
}

function nextStepBar(m, env, runner, now) {
  const step = nextStep(m, { now });
  if (!step) return null;
  const acts = primaryActions(m, { can: env.ctx.can, now, limit: 2 }).filter((a) => a.key !== 'openBilling');
  if (step.kind === 'invoice_locked') {
    return h('div', { class: 'ov-next ov-next-invoice', role: 'status', 'data-testid': 'ov-next' }, icon('lock', 18),
      h('p', {}, ov('order_view.next.invoice_locked', { no: step.invoice?.invoice_no || '' }), ' ',
        h('a', { href: step.invoice?.id ? invoiceHref(step.invoice.id) : '#/laskut', 'data-testid': 'ov-next-billing', text: ov('order_view.open_billing') })));
  }
  if (step.kind === 'problem') {
    return h('div', { class: 'ov-next ov-next-problem', role: 'alert', 'data-testid': 'ov-next' },
      h('p', {}, h('strong', { text: ov(`order_view.problem.${step.problem.code === 'already_used' ? 'already_used' : 'other'}`) }), h('br'),
        ov(step.problem.code === 'already_used' ? 'order_view.problem_text' : 'order_view.problem_text_other', { code: step.problem.masked || '' }), ' ',
        h('a', { href: '#/tarkista', text: ov('order_view.problem_open') })));
  }
  let title = '', sub = '';
  if (step.kind === 'today') {
    title = step.open > 0.004 ? ov('order_view.next.today_unpaid', { time: fmt.time(step.reservation.starts_at), amount: money(step.open) }) : ov('order_view.next.today', { time: fmt.time(step.reservation.starts_at) });
  } else if (step.kind === 'pay_missing') {
    title = ov('order_view.next.pay_missing', { amount: money(step.amount) });
    const box = paymentBox(m, { can: env.ctx.can });
    if (step.reservation) sub = box.linkSentAt ? ov('order_view.next.pay_missing_sent', { when: whenText(step.reservation, now), sent: fmt.dt(box.linkSentAt) }) : ov('order_view.next.pay_missing_when', { when: whenText(step.reservation, now) });
  } else if (step.kind === 'overpaid') {
    title = ov('order_view.next.overpaid', { amount: money(step.amount) });
  } else if (step.kind === 'refund_pending') {
    title = ov('order_view.tl.refund_pending', { amount: money(step.amount) });   // neutraali tila, ei toimintoa
  }
  const btns = step.kind === 'refund_pending' ? [] : step.kind === 'overpaid'
    ? (paymentBox(m, { can: env.ctx.can }).actions.refund ? [h('button', { type: 'button', class: 'btn primary', 'data-testid': 'ov-next-refund', text: ov('order_view.more_refund'), onclick: () => runner.refund(m) })] : [])
    : acts.map((a, i) => actionButton(a, m, runner, { primary: i === 0, testPrefix: 'ov-next' }));
  return h('div', { class: `ov-next ov-next-${step.kind}`, 'data-testid': 'ov-next' },
    h('span', { class: 'ov-next-ico', 'aria-hidden': 'true', text: step.kind === 'today' ? '●' : (step.kind === 'refund_pending' ? '↺' : '€') }),
    h('div', { class: 'grow' }, h('strong', { text: title }), sub ? h('p', { class: 'muted ov-small', text: sub }) : null),
    btns.length ? h('div', { class: 'row wrap' }, btns) : null);
}

/** Otsikon ⋯-valikko: kuitti, kuitin uudelleenlähetys, maksulinkin kopiointi, hyvitys, lisäosto, asiakas. */
function headMenu(m, env, runner) {
  const items = moreMenu(m, { can: env.ctx.can }).map((x) => {
    if (x.key === 'receipt') return [['receipt', ov('order_view.more_receipt'), () => runner.receipt(m)], env.ctx.can('payments.manage') ? ['resend', ov('order_view.more_resend'), () => runner.resendReceipt(m)] : null];
    if (x.key === 'copyLink') return [['copyLink', ov('order_view.more_copy_link'), () => runner.copyLink(m, x)]];
    if (x.key === 'refund') return [['refund', ov('order_view.more_refund'), () => runner.refund(m)]];
    if (x.key === 'addPurchase') return [['addPurchase', ov('order_view.more_add'), () => runner.addPurchase(m)]];
    if (x.key === 'openCustomer') return [['openCustomer', ov('order_view.more_customer'), () => runner.openCustomer(m)]];
    return [];
  }).flat().filter(Boolean);
  return items.length ? overflowMenu(items, ov('order_view.more'), 'ov-more') : null;
}

/**
 * Koko tilausnäkymä. Palauttaa solmun, joka on valmis sivulle. Kytkentä: views/orders.js (rest = tilausnumero).
 * opts: { ctx, refs, rpc?, orderNo?, orderId?, dialogs?, onBack?, now? }
 */
export async function renderOrderView({ ctx, refs, rpc = sbRpc, orderNo = null, orderId = null, dialogs = null, onBack = null, now = null, api = null, back = null }) {
  await Promise.all([loadOvTexts(rpc), loadOrderTexts(rpc).catch(() => {})]);
  const talousApi = api || createTalousApi({ rpc, io: { select: dbSelect, functionUrl, fnBlob, fn: sbFn } });
  const root = h('div', { class: 'ov-page', 'data-testid': 'order-view' });
  const gate = createLatestGate();
  let id = orderId;
  const env = { ctx, refs: refs || ctx.refs, rpc, api: talousApi, dialogs, reload: () => load() };
  const runner = createActionRunner(env);
  if (dialogs?.bindReload) dialogs.bindReload(() => load());
  async function resolveId() {
    if (id) return id;
    try { const r = await rpc('admin_order_lookup', { p_order_no: Number(orderNo) }); if (r?.order_id) return (id = r.order_id); }
    catch (e) {
      if (!(e?.code === 'PGRST202' || /admin_order_lookup|function/i.test(e?.message || ''))) throw e;
      // vanha kanta (ennen booking_278): sama haku kuin listan syvälinkissä
      const r = await talousApi.listOrders({ search: String(orderNo), paymentFilters: ['all'], limit: 5, offset: 0, sortBy: 'created', sortDir: 'desc' });
      const hit = (r.rows || []).find((x) => String(x.order_no) === String(orderNo));
      if (hit) return (id = hit.order_id);
      const nf = new Error('not_found'); nf.code = 'not_found'; throw nf;
    }
    const nf = new Error('not_found'); nf.code = 'not_found'; throw nf;
  }
  async function load() {
    const token = gate.next();
    if (!root.childNodes.length) root.append(h('p', { class: 'muted pad', role: 'status', text: ov('order_view.loading') }));
    try {
      const oid = await resolveId();
      const raw = await rpc('admin_get_order', { p_order_id: oid });
      if (!gate.isCurrent(token)) return;
      paint(orderModel(raw));
    } catch (e) {
      if (!gate.isCurrent(token)) return;
      const nf = e?.code === 'not_found' || e?.details === 'not_found';
      root.replaceChildren(backLink(), h('div', { class: 'ov-card', role: 'alert' },
        h('p', { class: 'err', text: nf ? ov('order_view.not_found', { no: orderNo ?? orderId }) : ov('order_view.load_failed', { error: errMsg(e) }) }),
        nf ? null : h('button', { type: 'button', class: 'btn', text: ov('order_view.retry'), onclick: () => load() })));
    }
  }
  const backLink = (m = null) => h('nav', { class: 'ov-crumb', 'aria-label': ov('order_view.back_list') },
    h('a', { href: back?.href || '#/tilaukset', 'data-testid': 'ov-back', onclick: (e) => { if (onBack) { e.preventDefault(); onBack(); } } }, '← ', ov(back?.prev ? 'order_view.back_prev' : 'order_view.back_list')),
    m ? [' / ', h('span', { text: ov('order_view.crumb_order', { no: m.order_no }) })] : null);
  function paint(m) {
    const at = now ? new Date(now) : new Date();
    const title = customerTitle(m);
    const metaBits = list(ov('order_view.title_order', { no: m.order_no }), m.created_at ? ov('order_view.meta_created', { when: fmt.dt(m.created_at) }) : null, channelText(m),
      m.customer?.customer_kind === 'company' && m.customer?.company && m.customer?.name ? ov('order_view.meta_contact', { name: m.customer.name }) : null,
      m.reservations.length > 1 ? ov('order_view.meta_count', { n: m.reservations.length }) : null,
      m.locale ? ov('order_view.meta_lang', { lang: String(m.locale).toUpperCase() }) : null);
    const head = h('header', { class: 'ov-head' },
      h('div', { class: 'ov-head-main' },
        h('div', { class: 'ov-title' }, h('h1', { 'data-testid': 'ov-title', text: title }), h('span', { class: 'ov-badges', 'data-testid': 'ov-badges' }, badgeNodes(orderBadges(m)))),
        h('p', { class: 'muted ov-meta', text: metaBits.join(' · ') })),
      h('div', { class: 'ov-head-actions' },
        m.customer?.id ? h('a', { class: 'ov-link ov-hide-m', href: `#/asiakkaat/${m.customer.id}`, text: ov('order_view.open_customer') }) : null,
        (m.receipts || []).length ? h('button', { type: 'button', class: 'btn sm ov-hide-m', 'data-testid': 'ov-receipt', text: ov('order_view.receipt'), onclick: () => runner.receipt(m) }) : null,
        headMenu(m, env, runner)));
    const canAddRes = !m.locked && m.staff_can_add && ctx.can('bookings.manage') && m.is_native;
    const resHead = h('div', { class: 'row between' }, h('h2', { class: 'ov-h', text: m.reservations.length > 1 ? ov('order_view.sec.reservations', { n: m.reservations.length }) : ov('order_view.sec.reservation') }),
      canAddRes ? h('button', { type: 'button', class: 'linkish', 'data-testid': 'ov-add-purchase', text: ov('order_view.act.add_purchase'), onclick: () => runner.addPurchase(m) }) : null);
    const resCard = sec(resHead, 'ov-reservations', ...(m.reservations.length ? m.reservations.map((r) => reservationRow(r, m, env, runner, at)) : [h('p', { class: 'muted', text: ov('order_view.no_reservations') })]));
    const mainCol = h('div', { class: 'ov-main' }, nextStepBar(m, env, runner, at), resCard, m.reservations.length > 1 ? null : breakdownCard(m), timelineCard(m, env));
    const side = h('aside', { class: 'ov-side' }, paymentCard(m, env, runner), customerCard(m, env), notesCard(m, env), dangerCard(m, env, runner));
    const bar = mobileBar(m, env, runner, at);
    root.replaceChildren(...list(backLink(m), head, h('div', { class: 'ov-grid' }, mainCol, side), bar));
    root.classList.toggle('has-bar', !!bar);
    root.dataset.orderId = m.order_id; root.dataset.orderNo = m.order_no;
    hydrateOverpayment(m);
  }
  // booking_283 (PR 3): ylisuorituksen hyvitysnappi vain kun palvelimen lippu, oikeus ja ylisuoritus täsmäävät (muuten ei nappia, vanha hyvitys ennallaan)
  function hydrateOverpayment(m) {
    const slot = root.querySelector('[data-slot=ov-over]');
    if (!slot || m.overpaid <= 0.004 || m.locked || !ctx.can('payments.refund')) return;
    overpaymentButton({ model: m, ctx, rpc, api: talousApi, onDone: () => load() })
      .then((b) => { if (b && slot.isConnected && String(root.dataset.orderId) === String(m.order_id)) slot.append(b); }).catch(() => {});
  }
  await load();
  return root;
}

/** Mobiilin kiinteä alapalkki: 1–2 tilan mukaista päätoimintoa (piilotetaan työpöydällä CSS:llä). */
export function mobileBar(m, env, runner, now = new Date()) {
  const acts = primaryActions(m, { can: env.ctx.can, now, limit: 2 });
  if (!acts.length) return null;
  return h('div', { class: 'ov-mbar', role: 'toolbar', 'aria-label': ov('order_view.mobile_bar'), 'data-testid': 'ov-mobile-bar' },
    acts.map((a, i) => actionButton(a, m, runner, { primary: i === 0, testPrefix: 'ov-mbar' })));
}

/** Leveä näyttö → yhteenveto listan vieressä; kapea → koko näkymä suoraan. */
export const wideScreen = () => isWide(globalThis.innerWidth || 0);
export { helDay };
