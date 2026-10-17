// Talous › Lahjakortit (sopimus §13): lista + haku + suodattimet, kortin tiedot ja tapahtumahistoria, luonti/myynti, voimassaolon muutos, saldokorjaus, mitätöinti/uudelleenaktivointi.
// + "Lisää maksu → Lahjakortti" (redeemFields/redeemSubmit, käytössä talous-orders.js:ssä) → admin_redeem_gift_card. Datakerros: ../giftcards-api.js (mock kun ?mock=1).
// Oikeudet: välilehti giftcards.manage; saldokorjaus/mitätöinti/aktivointi giftcards.admin; maksulla myynti ja lunastus payments.manage.
import { h, dialog, toast, badge } from '../ui.js';
import { icon } from '../icons.js';
import { t, fmt } from '../talous-i18n.js';
import { GC_STATUSES, GC_SORTS, GC_PAY_METHODS, GC_GREETING_MAX, normalizeGiftCode, formatGiftCode } from '../giftcards-api.js';
import { loading, emptyBox, errorBox, pager, pageSizeSelect, selectFld, searchFld, expandRow, actionBtn, formDialog, friendly, methodLabel } from './talous-ui.js';

const fld = (label, ...kids) => h('label', { class: 'fld' }, h('span', { text: label }), ...kids);
const STATUS_BADGE = { active: 'pay-paid', used: 'muted', expired: 'pay-refunded', cancelled: 'pay-failed', pending_verification: 'pay-pending', pending_payment: 'pay-pending' };
export const gcStatusLabel = (c) => t(`gcst.${c}`);
export const gcStatusBadge = (c) => { const b = badge(STATUS_BADGE[c] || 'muted', gcStatusLabel(c)); b.dataset.status = c; return b; };
const fmtDay = (d) => (d ? fmt.date(d) : '–');
const centsOk = (n) => Math.abs(Math.round(n * 100) - n * 100) < 1e-6;
const doneToast = (api, rpc) => (api.isMock() ? toast(t('mock.done', { rpc }), 'warn') : toast(t('done', { rpc }), 'ok'));

// ---- "Lisää maksu → Lahjakortti" (tilauksen maksulomake) ----
// Palauttaa { node, submit(order) , hint } – node = koodikenttä + haku + yhteenveto; summa ja muistiinpano ovat maksulomakkeen omat kentät.
export function redeemFields({ gift, order, amountInput, onCard }) {
  const code = h('input', { name: 'gc_code', autocomplete: 'off', autocapitalize: 'characters', spellcheck: 'false', maxlength: 24, placeholder: 'HHXX-XXXX-XXXX', 'data-testid': 'redeem-code', 'aria-describedby': 'gc-code-hint' });
  const info = h('p', { class: 'tl-hint', role: 'status', 'data-testid': 'redeem-info' });
  const off = h('p', { class: 'tl-banner', role: 'status', hidden: true, 'data-testid': 'redeem-off', text: t('gc.o.off') });
  let card = null;
  const lookup = async () => {
    const n = normalizeGiftCode(code.value);
    card = null; info.textContent = ''; info.classList.remove('err');
    if (n.length !== 12) { info.textContent = t('gc.o.badCode'); info.classList.add('err'); return null; }
    try {
      const d = await gift.get({ code: n });
      card = d.card; code.value = formatGiftCode(n);
      info.textContent = t('gc.o.cardInfo', { balance: fmt.money(card.balance), valid: card.valid_to ? fmtDay(card.valid_to) : t('gc.noValid'), status: gcStatusLabel(card.effective_status) });
      const unpaid = +order.balance?.unpaid || 0, want = Math.round(Math.min(unpaid, card.balance) * 100) / 100;
      if (amountInput && want > 0) { amountInput.value = want; }
      onCard?.(card);
    } catch (e) { info.textContent = friendly(e); info.classList.add('err'); }
    return card;
  };
  const btn = h('button', { type: 'button', class: 'btn', 'data-testid': 'redeem-lookup', onclick: lookup }, icon('eye', 18), h('span', { text: t('gc.o.lookup') }));
  gift.settings().then((s) => { if (s && !s.redeem_enabled) { off.hidden = false; node.dataset.redeemOff = '1'; node.dispatchEvent(new CustomEvent('redeem-off', { bubbles: true })); } });
  const node = h('div', { class: 'stack', 'data-testid': 'redeem-box' }, fld(t('gc.o.code'), code, h('small', { id: 'gc-code-hint', text: t('gc.o.codeHint') })), btn, info, h('p', { class: 'muted tl-hint', text: t('gc.o.amountHint') }), off);
  code.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); lookup(); } });
  return { node, lookup, isOff: () => !off.hidden, code: () => normalizeGiftCode(code.value) };
}
export async function redeemSubmit({ gift, order, code, amount, note }) {
  if (code.length !== 12) throw Object.assign(new Error(t('gc.o.badCode')), { code: undefined });
  const res = await gift.redeem({ orderId: order.order_id, code, amount, note });
  doneToast(gift, 'admin_redeem_gift_card');
  const lines = [t('gc.o.done', { amount: fmt.money(res.amount), balance: fmt.money(res.gift_card?.balance) })];
  if (res.accounted === false) lines.push(t('gc.o.notAccounted'));
  else if (res.receipt_no) lines.push(t('gc.o.receipt', { no: res.receipt_no }));
  toast(lines.join(' '), 'ok');
  return res;
}

// ---- välilehti ----
export function createGiftcardsTab({ api, gift, ctx, onOpenOrder = () => {} }) {
  const st = { search: '', status: '', source: '', package: '', sort: 'created_desc', balance: '', expiring: '', unverified: '', limit: 25, offset: 0 };
  const canAdmin = !!ctx.can('giftcards.admin'), canPay = !!ctx.can('payments.manage');
  const list = h('ul', { class: 'tl-list gc', 'data-testid': 'gc-list' }), count = h('p', { class: 'muted tl-count', role: 'status', 'data-testid': 'gc-count' }), pagers = [h('div'), h('div')];
  const sums = h('p', { class: 'muted tl-count', 'data-testid': 'gc-sums' }), switches = h('div', { class: 'gc-switches', 'data-testid': 'gc-switches' });
  let seq = 0, packages = [], reopen = null;
  const afterChange = (id) => { reopen = id; api.changed?.(); load(); };

  async function loadSettings() {
    try {
      const r = await gift.packages(); packages = r.packages;
      const pill = (key, on) => h('li', { class: `gc-sw ${on ? 'on' : 'off'}`, 'data-testid': `gc-sw-${key}`, 'data-on': String(on) }, h('span', { class: 'gc-sw-dot', 'aria-hidden': 'true' }), h('span', { text: `${t(`gc.set.${key}`)}: ${t(on ? 'gc.set.on' : 'gc.set.off')}` }));
      switches.replaceChildren(h('ul', { class: 'gc-sw-list', 'aria-label': t('gc.set.title') }, pill('sale', r.settings.sale_enabled), pill('redeem', r.settings.redeem_enabled), pill('johku', r.settings.johku_cards_redeemable)), h('p', { class: 'muted tl-hint', text: t('gc.set.hint') }));
      pkgSel?.replaceWith(buildPkgSel());
    } catch (e) { switches.replaceChildren(errorBox(e)); }
  }
  async function load() {
    const my = ++seq;
    list.replaceChildren(loading()); list.setAttribute('aria-busy', 'true');
    try {
      const r = await gift.list({ search: st.search, status: st.status, source: st.source, package: st.package, sort: st.sort, limit: st.limit, offset: st.offset,
        hasBalance: st.balance === 'yes' ? true : st.balance === 'no' ? false : undefined, expiringDays: st.expiring, unverified: st.unverified === 'yes' });
      if (my !== seq) return;
      list.setAttribute('aria-busy', 'false');
      if (st.offset >= r.total && r.total > 0) { st.offset = Math.max(0, Math.floor((r.total - 1) / st.limit) * st.limit); return load(); }
      count.textContent = r.total ? t('gc.count', { from: fmt.int(st.offset + 1), to: fmt.int(Math.min(st.offset + st.limit, r.total)), total: fmt.int(r.total) }) : '';
      sums.textContent = r.total ? t('gc.sums', { balance: fmt.money(r.sum_balance), redeemable: fmt.money(r.sum_balance_redeemable), initial: fmt.money(r.sum_initial) }) : '';
      list.replaceChildren(...(r.rows.length ? r.rows.map(cardRow) : [emptyBox(t('gc.none'))]));
      const mk = () => (r.total > st.limit ? pager({ total: r.total, offset: st.offset, limit: st.limit, onPage: (o) => { st.offset = o; load(); } }) : h('span'));
      pagers[0].replaceChildren(mk()); pagers[1].replaceChildren(mk());
      if (reopen != null) { const row = list.querySelector(`[data-card-id="${reopen}"] .tl-head`); reopen = null; row?.click(); }
    } catch (e) { if (my === seq) { list.replaceChildren(errorBox(e, load)); count.textContent = ''; sums.textContent = ''; pagers.forEach((p) => p.replaceChildren()); } }
  }
  const who = (c) => c.recipient_name || c.buyer_name || t('gc.noName');
  function cardRow(c) {
    const st2 = c.effective_status;
    const head = [
      h('span', { class: 'tl-c tl-main' }, h('strong', { class: 'gc-code', text: c.code }), ' ', h('span', { class: 'tl-name', text: who(c) })),
      h('span', { class: 'tl-c tl-date' }, h('small', { class: 'tl-lab', text: t('gc.col.valid') }), h('span', { text: c.valid_to ? t('gc.validTo', { date: fmtDay(c.valid_to) }) : t('gc.noValid') })),
      h('span', { class: 'tl-c tl-first' }, h('small', { class: 'tl-lab', text: t('gc.f.package') }), h('span', { text: c.package_name || '–' })),
      h('span', { class: 'tl-c tl-sum' }, h('strong', { text: fmt.money(c.balance) }), h('small', { class: 'muted', text: `/ ${fmt.money(c.initial_amount)}` })),
      h('span', { class: 'tl-c tl-badges' }, gcStatusBadge(st2), c.source === 'johku' ? badge('src-johku', t('gcsrc.johku')) : null, !c.balance_verified ? badge('pay-pending', t('gc.verified.no')) : null),
    ];
    const row = expandRow({ id: `gc${c.id}`, head, testid: 'gc', build: () => detail(c.id) });
    row.dataset.cardId = String(c.id); row.dataset.status = st2;
    return row;
  }
  async function detail(id) {
    const d = await gift.get({ id }), c = d.card;
    const dl = (rows) => h('dl', { class: 'gc-dl' }, rows.filter(Boolean).flatMap(([k, v]) => [h('dt', { text: k }), h('dd', { text: v })]));
    const codeBtn = h('button', { type: 'button', class: 'btn tl-rc-btn', 'data-testid': 'gc-copy', onclick: async () => { try { await navigator.clipboard.writeText(c.code); toast(t('gc.d.copied'), 'ok'); } catch { /* leikepöytä ei käytössä */ } } }, icon('copy', 18), h('span', { text: t('gc.d.copy') }));
    const buyer = [c.buyer_name, c.buyer_email].filter(Boolean).join(' · '), rec = [c.recipient_name, c.recipient_email].filter(Boolean).join(' · ');
    const info = h('section', { class: 'tl-sec' }, h('h3', { text: t('gc.d.info') }),
      h('p', { class: 'gc-bigcode', 'data-testid': 'gc-detail-code' }, h('strong', { text: c.code }), codeBtn),
      dl([[t('gc.d.balance'), `${fmt.money(c.balance)} / ${fmt.money(c.initial_amount)}`], [t('gc.d.package'), c.package_name || '–'], [t('gc.d.kind'), t(`gc.kind.${c.kind}`)], [t('gc.d.valid'), c.valid_from || c.valid_to ? `${fmtDay(c.valid_from)} – ${fmtDay(c.valid_to)}` : '–'],
        buyer && [t('gc.d.buyer'), buyer], rec && [t('gc.d.recipient'), rec], c.greeting && [t('gc.d.greeting'), c.greeting], c.note && [t('gc.d.note'), c.note],
        [t('gc.d.vat'), t(`gc.vat.${c.vat_treatment || 'at_sale'}`)], [t('gc.d.origin'), t(`gcsrc.${c.source}`)], c.single_order && [t('gc.single'), '✓'],
        [t('gc.d.created'), fmt.dt(c.created_at)], c.activated_at && [t('gc.d.activated'), fmt.dt(c.activated_at)], c.last_used_at && [t('gc.d.lastUsed'), fmt.dt(c.last_used_at)]]),
      !c.balance_verified ? h('p', { class: 'tl-johku-note', role: 'note', text: t('gc.verified.no') }) : null,
      d.purchase_order?.order_no ? h('p', {}, h('button', { type: 'button', class: 'btn', 'data-testid': 'gc-open-order', onclick: () => onOpenOrder(d.purchase_order.order_no) }, t('gc.d.openOrder', { no: d.purchase_order.order_no }))) : null);
    const sub = (title, items, none, tid) => h('section', { class: 'tl-sec' }, h('h3', { text: title }), items.length ? h('ul', { class: 'tl-sub', 'data-testid': tid }, items) : emptyBox(none));
    const ledger = sub(t('gc.d.ledger'), [...d.ledger].reverse().map((x) => h('li', {},
      h('span', { class: 'tl-sub-main' }, h('strong', { text: t(`gc.led.${x.reason}`) }), x.order_no ? ` · #${x.order_no}` : ''),
      h('span', { class: 'tl-sub-meta', text: [fmt.dt(x.at), x.reason === 'expiry_change' ? t('gc.d.expiryRow', { from: fmtDay(x.old_valid_to), to: fmtDay(x.new_valid_to) }) : t('gc.d.balanceAfter', { balance: fmt.money(x.balance_after) }), x.note].filter(Boolean).join(' · ') }),
      h('span', { class: `tl-sub-sum${x.delta < 0 ? ' tl-refund' : ''}`, text: x.reason === 'expiry_change' ? '' : `${x.delta > 0 ? '+' : ''}${fmt.money(x.delta)}` }))), t('gc.d.noLedger'), 'gc-ledger');
    const expiry = sub(t('gc.d.expiry'), d.expiry_log.map((x) => h('li', {}, h('span', { class: 'tl-sub-main', text: t('gc.d.expiryRow', { from: fmtDay(x.old_valid_to), to: fmtDay(x.new_valid_to) }) }),
      h('span', { class: 'tl-sub-meta', text: [fmt.dt(x.at), x.by, x.note].filter(Boolean).join(' · ') }), h('span', { class: 'tl-sub-sum' }))), t('gc.d.noExpiry'), 'gc-expiry');
    const pays = sub(t('gc.d.payments'), d.payments.map((p) => h('li', {}, h('span', { class: 'tl-sub-main' }, h('button', { type: 'button', class: 'btn ghost gc-link', onclick: () => onOpenOrder(p.order_no) }, `#${p.order_no}`)),
      h('span', { class: 'tl-sub-meta', text: [fmt.dt(p.paid_at), p.accounted === false ? t('gc.d.notAccounted') : t('gc.d.accounted'), p.refunded_amount ? `−${fmt.money(p.refunded_amount)}` : null].filter(Boolean).join(' · ') }), h('span', { class: 'tl-sub-sum', text: fmt.money(p.amount) }))), t('gc.d.noPayments'), 'gc-payments');
    const noRight = t('gc.a.noRight');
    const actions = h('div', { class: 'tl-actions', 'data-testid': 'gc-actions' },
      actionBtn({ key: 'expiry', label: t('gc.a.expiry'), ico: 'calendar', testid: 'gc-btn-expiry', onClick: () => expiryDialog(c) }),
      actionBtn({ key: 'adjust', label: t('gc.a.adjust'), ico: 'euro', testid: 'gc-btn-adjust', extraDisabled: canAdmin ? null : noRight, onClick: () => adjustDialog(c) }),
      c.status === 'cancelled' ? null : actionBtn({ key: 'deactivate', label: t('gc.a.deactivate'), ico: 'lock', testid: 'gc-btn-deactivate', extraDisabled: canAdmin ? null : noRight, onClick: () => reasonDialog(c, 'deactivate') }),
      actionBtn({ key: 'reactivate', label: t('gc.a.reactivate'), ico: 'undo', testid: 'gc-btn-reactivate', extraDisabled: !canAdmin ? noRight : c.status === 'pending_payment' ? t('gc.a.unpaidNoReact') : c.status === 'cancelled' || c.status === 'used' || c.status === 'expired' ? null : t('gc.a.noneNeeded'), onClick: () => reasonDialog(c, 'reactivate') }));
    return h('div', { class: 'tl-detail', 'data-testid': 'gc-detail' }, info, d.ledger_consistent ? null : h('p', { class: 'tl-error', role: 'alert', text: t('gc.d.ledgerBad') }), actions, ledger, expiry, pays);
  }

  // ---- dialogit ----
  function expiryDialog(c) {
    const date = h('input', { type: 'date', name: 'valid_to', value: c.valid_to || '', required: true, 'data-testid': 'gc-expiry-date' });
    formDialog(t('gc.expiry.title'), [h('p', { class: 'muted tl-hint', text: t('gc.expiry.past') }), fld(t('gc.expiry.date'), date), fld(t('gc.expiry.note'), h('input', { name: 'note', maxlength: 200 }))], t('gc.expiry.submit'), async (fd) => {
      if (!fd.get('valid_to')) throw new Error(t('gc.expiry.bad'));
      await gift.setExpiry({ id: c.id, validTo: fd.get('valid_to'), note: String(fd.get('note') || '').trim() || undefined });
      doneToast(gift, 'admin_set_gift_card_expiry'); afterChange(c.id);
    });
  }
  function adjustDialog(c) {
    formDialog(t('gc.adj.title'), [fld(t('gc.adj.delta'), h('input', { name: 'delta', type: 'number', step: '0.01', inputmode: 'decimal', required: true, 'data-testid': 'gc-adj-delta' })),
      fld(t('gc.adj.reason'), h('input', { name: 'reason', maxlength: 500, required: true, 'data-testid': 'gc-adj-reason' })),
      c.source === 'johku' || !c.balance_verified ? h('label', { class: 'chk' }, h('input', { type: 'checkbox', name: 'verified', checked: !c.balance_verified ? true : null }), h('span', { text: t('gc.adj.verify') })) : null], t('gc.adj.submit'), async (fd) => {
      const delta = Math.round(+fd.get('delta') * 100) / 100, reason = String(fd.get('reason') || '').trim();
      if (!delta || reason.length < 3) throw new Error(t('gc.adj.bad'));
      if (c.balance + delta < -0.005) throw new Error(t('gc.adj.below'));
      await gift.adjust({ id: c.id, delta, reason, markVerified: fd.get('verified') === 'on' });
      doneToast(gift, 'admin_adjust_gift_card'); afterChange(c.id);
    });
  }
  function reasonDialog(c, kind) {
    formDialog(t(kind === 'deactivate' ? 'gc.deact.title' : 'gc.react.title'), [h('p', { class: 'muted', text: t(kind === 'deactivate' ? 'gc.deact.text' : 'gc.react.text') }), fld(t('gc.reason'), h('input', { name: 'reason', maxlength: 500, required: true, 'data-testid': 'gc-reason' }))],
      t(kind === 'deactivate' ? 'gc.deact.submit' : 'gc.react.submit'), async (fd) => {
      const reason = String(fd.get('reason') || '').trim(); if (reason.length < 3) throw new Error(t('gc.reason.bad'));
      await gift[kind]({ id: c.id, reason }); doneToast(gift, kind === 'deactivate' ? 'admin_deactivate_gift_card' : 'admin_reactivate_gift_card'); afterChange(c.id);
    });
  }
  // Uusi lahjakortti: maksuton myöntö (syy pakollinen) tai myynti maksutavalla (payments.manage)
  async function createDialog() {
    if (!packages.length) { try { packages = (await gift.packages()).packages; } catch (e) { toast(friendly(e), 'err'); return; } }
    const pk = (code) => packages.find((p) => p.code === code);
    const mode = h('select', { name: 'mode', 'data-testid': 'gc-new-mode' }, h('option', { value: 'free', text: t('gc.n.free') }), ...GC_PAY_METHODS.map((m) => h('option', { value: m, text: methodLabel(m), disabled: canPay ? null : true })));
    const pkgs = packages.filter((p) => p.active !== false);
    const pkg = h('select', { name: 'package', 'data-testid': 'gc-new-package' }, pkgs.map((p) => h('option', { value: p.code, text: p.is_open ? p.name : `${p.name} · ${fmt.money(p.price)}` })));
    const amount = h('input', { name: 'amount', type: 'number', step: '0.01', inputmode: 'decimal', 'data-testid': 'gc-new-amount' }), amountHint = h('small', {});
    const qty = h('input', { name: 'quantity', type: 'number', min: 1, max: 10, value: 1, inputmode: 'numeric', 'data-testid': 'gc-new-qty' });
    const note = h('input', { name: 'note', maxlength: 200, 'data-testid': 'gc-new-note' }), noteLab = h('span', {});
    const greeting = h('textarea', { name: 'greeting', rows: 3, maxlength: GC_GREETING_MAX + 50, 'data-testid': 'gc-new-greeting' }), counter = h('small', { 'data-testid': 'gc-new-counter', text: t('gc.n.counter', { n: 0 }) });
    greeting.addEventListener('input', () => { counter.textContent = t('gc.n.counter', { n: [...greeting.value].length }); counter.classList.toggle('gc-over', [...greeting.value].length > GC_GREETING_MAX); });
    const buyerBox = h('div', { class: 'stack', 'data-testid': 'gc-new-buyer', hidden: true }, fld(t('gc.n.buyerName'), h('input', { name: 'buyer_name', maxlength: 120, autocomplete: 'off' })), fld(t('gc.n.buyerEmail'), h('input', { name: 'buyer_email', type: 'email', autocomplete: 'off' })), fld(t('gc.n.buyerPhone'), h('input', { name: 'buyer_phone', type: 'tel', autocomplete: 'off' })));
    const hint = h('p', { class: 'muted tl-hint', 'data-testid': 'gc-new-hint' });
    const vat = h('select', { name: 'vat' }, h('option', { value: '', text: t('gc.n.vatDefault') }), h('option', { value: 'at_sale', text: t('gc.vat.at_sale') }), h('option', { value: 'at_redemption', text: t('gc.vat.at_redemption') }));
    const channel = h('select', { name: 'channel' }, ['admin', 'phone', 'email', 'walk_in', 'other'].map((c) => h('option', { value: c, text: t(`gc.n.ch.${c}`) })));
    const sync = () => {
      const p = pk(pkg.value), free = mode.value === 'free';
      amount.disabled = !p?.is_open; amount.required = !!p?.is_open; if (!p?.is_open) amount.value = '';
      amountHint.textContent = !p ? '' : p.is_open ? t('gc.n.range', { min: p.min_amount, max: p.max_amount }) : t('gc.n.fixed', { price: fmt.money(p.price) });
      noteLab.textContent = free ? t('gc.n.noteFree') : t('gc.n.note'); note.required = free; buyerBox.hidden = free; channel.closest('label').hidden = free;
      hint.textContent = t(free ? 'gc.n.freeHint' : 'gc.n.payHint') + (canPay ? '' : ` ${t('gc.n.needPay')}`);
    };
    mode.addEventListener('change', sync); pkg.addEventListener('change', sync);
    const d = formDialog(t('gc.n.title'), [fld(t('gc.n.mode'), mode), fld(t('gc.n.package'), pkg), h('label', { class: 'fld' }, h('span', { text: t('gc.n.amount') }), amount, amountHint), fld(t('gc.n.qty'), qty),
      buyerBox, fld(t('gc.n.recName'), h('input', { name: 'recipient_name', maxlength: 120, 'data-testid': 'gc-new-rec-name' })), fld(t('gc.n.recEmail'), h('input', { name: 'recipient_email', type: 'email' })),
      h('label', { class: 'fld' }, h('span', { text: t('gc.n.greeting') }), greeting, counter), fld(t('gc.n.vat'), vat), fld(t('gc.n.months'), h('input', { name: 'months', type: 'number', min: 1, max: 36, inputmode: 'numeric' })),
      h('label', { class: 'fld' }, noteLab, note), fld(t('gc.n.channel'), channel), hint], t('gc.n.submit'), async (fd) => {
      const p = pk(fd.get('package')), free = fd.get('mode') === 'free', amt = p?.is_open ? Math.round(+fd.get('amount') * 100) / 100 : undefined;
      if (p?.is_open && (!(amt >= p.min_amount && amt <= p.max_amount) || !centsOk(+fd.get('amount')))) throw new Error(t('gc.n.bad.amount', { min: p.min_amount, max: p.max_amount }));
      const note2 = String(fd.get('note') || '').trim();
      if (free && note2.length < 3) throw new Error(t('gc.n.bad.note'));
      const bn = String(fd.get('buyer_name') || '').trim(), be = String(fd.get('buyer_email') || '').trim();
      if (!free && (!bn || !be)) throw new Error(t('gc.n.bad.buyer'));
      const gr = String(fd.get('greeting') || '').trim(); if ([...gr].length > GC_GREETING_MAX) throw new Error(t('gc.n.bad.greeting'));
      const res = await gift.create({ package: p.code, amount: amt, quantity: Math.max(1, Math.trunc(+fd.get('quantity')) || 1), buyer: free ? undefined : { name: bn, email: be, phone: String(fd.get('buyer_phone') || '').trim() },
        recipientName: String(fd.get('recipient_name') || '').trim(), recipientEmail: String(fd.get('recipient_email') || '').trim(), greeting: gr, paymentMethod: free ? undefined : fd.get('mode'),
        vatTreatment: fd.get('vat') || undefined, validMonths: fd.get('months') ? Math.trunc(+fd.get('months')) : undefined, locale: 'fi', note: note2 || undefined, channel: free ? undefined : fd.get('channel') });
      doneToast(gift, 'admin_create_gift_card'); load(); resultDialog(res);
    });
    sync(); return d;
  }
  function resultDialog(res) {
    const cards = res.cards || [], one = cards.length === 1;
    const status = res.complimentary ? t('gc.r.free') : res.paid ? t('gc.r.paid') : t('gc.r.pending');
    dialog(t(one ? 'gc.r.title' : 'gc.r.titleN', { n: cards.length }), h('div', { class: 'stack', 'data-testid': 'gc-result' }, h('p', { text: status }), res.order_no ? h('p', { class: 'muted', text: t('gc.r.order', { no: res.order_no }) }) : null,
      h('ul', { class: 'tl-sub' }, cards.map((c) => h('li', {}, h('span', { class: 'tl-sub-main' }, h('strong', { class: 'gc-code', 'data-testid': 'gc-result-code', text: c.code })), h('span', { class: 'tl-sub-meta', text: [c.package_name, c.recipient_name].filter(Boolean).join(' · ') }), h('span', { class: 'tl-sub-sum', text: fmt.money(c.initial_amount) })))),
      h('p', { class: 'muted tl-hint', text: t('gc.r.codes') })));
  }

  // ---- työkalupalkki ----
  let toolbar, pkgSel;
  const change = (patch) => { Object.assign(st, patch, { offset: 0 }); load(); };
  const buildPkgSel = () => { const el = selectFld(t('gc.f.package'), 'gc-f-package', packages.map((p) => p.code), (c) => packages.find((p) => p.code === c)?.name || c, st.package, (v) => change({ package: v })); pkgSel = el; return el; };
  const simple = (label, testid, opts, key) => { const el = h('label', { class: 'fld' }, h('span', { text: label }), h('select', { 'data-testid': testid, onchange: (e) => change({ [key]: e.target.value }) }, opts.map(([v, tx]) => h('option', { value: v, text: tx })))); el.querySelector('select').value = st[key] || ''; return el; };
  function buildToolbar() {
    const ss = searchFld(t('gc.search'), 'gc-search', (v) => change({ search: v })); ss.input.value = st.search;
    const sort = h('label', { class: 'fld' }, h('span', { text: t('gc.f.sort') }), h('select', { 'data-testid': 'gc-f-sort', onchange: (e) => change({ sort: e.target.value }) }, GC_SORTS.map((s) => h('option', { value: s, text: t(`gcsort.${s}`) }))));
    sort.querySelector('select').value = st.sort;
    const next = h('form', { class: 'tl-toolbar', role: 'search', onsubmit: (e) => e.preventDefault() }, ss.node,
      selectFld(t('gc.f.status'), 'gc-f-status', GC_STATUSES, gcStatusLabel, st.status, (v) => change({ status: v })),
      selectFld(t('gc.f.source'), 'gc-f-source', ['native', 'johku'], (c) => t(`gcsrc.${c}`), st.source, (v) => change({ source: v })), buildPkgSel(), sort,
      simple(t('gc.f.balance'), 'gc-f-balance', [['', t('gc.f.balance.any')], ['yes', t('gc.f.balance.yes')], ['no', t('gc.f.balance.no')]], 'balance'),
      simple(t('gc.f.expiring'), 'gc-f-expiring', [['', t('gc.f.expiring.any')], ['30', t('gc.f.expiring.30')], ['90', t('gc.f.expiring.90')]], 'expiring'),
      simple(t('gc.f.unverified'), 'gc-f-unverified', [['', t('gc.f.unverified.any')], ['yes', t('gc.f.unverified.yes')]], 'unverified'),
      pageSizeSelect(st.limit, (n) => change({ limit: n })),
      h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'gc-reset', onclick: () => { Object.assign(st, { search: '', status: '', source: '', package: '', sort: 'created_desc', balance: '', expiring: '', unverified: '' }); buildToolbar(); load(); } }, t('filters.reset')));
    if (toolbar?.isConnected) toolbar.replaceWith(next);
    toolbar = next; return next;
  }
  buildToolbar();
  const newBtn = h('button', { type: 'button', class: 'btn primary gc-new', 'data-testid': 'gc-new', onclick: () => createDialog().catch((e) => toast(friendly(e), 'err')) }, icon('gift', 20), h('span', { text: t('gc.new') }));
  const cols = h('div', { class: 'tl-cols gc', 'aria-hidden': 'true' }, h('span', { text: t('gc.col.code') }), h('span', { text: t('gc.col.valid') }), h('span', { text: t('gc.f.package') }), h('span', { class: 'r', text: t('gc.col.balance') }), h('span', { text: t('gc.col.status') }), h('span'));
  const node = h('div', { class: 'tl-tab', 'data-testid': 'tab-giftcards' }, h('div', { class: 'row between wrap gc-top' }, switches, newBtn), toolbar, count, sums, pagers[0], cols, list, pagers[1]);
  return { node, load() { loadSettings(); return load(); }, setSearch(q) { st.search = q; st.offset = 0; buildToolbar(); load(); } };
}
