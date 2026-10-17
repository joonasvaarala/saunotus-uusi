// Talous › Lahjakoodit (sopimus §13.12 / §13.12.1): muiden myyjien lahjakorttien lunastuspyynnöt. Lista (admin_list_voucher_claims), yhteenveto, tiedot (admin_get_voucher_claim: koko koodi + audit REVEAL)
// ja ratkaisu (admin_resolve_voucher_claim): lunastettu / ongelma / peruttu / palauta jonoon. Koodi on rahaa: listassa vain maskattu (…1234), koko koodi vain avatussa tiedossa. Ei aikarajaa: hold_until on aina null.
import { h, dialog, toast, badge } from '../ui.js';
import { icon } from '../icons.js';
import { t, fmt } from '../talous-i18n.js';
import { VC_STATUSES, VC_SORTS, VC_PROBLEM_CODES, VC_NOTE_MAX, VC_ACTIVE, fmtAge } from '../vouchers-api.js';
import { payLabel, loading, emptyBox, errorBox, pager, pageSizeSelect, selectFld, searchFld, expandRow, actionBtn, formDialog, friendly } from './talous-ui.js';

const fld = (label, ...kids) => h('label', { class: 'fld' }, h('span', { text: label }), ...kids);
const STATUS_BADGE = { open: 'pay-pending', processing: 'pay-pending', problem: 'err', redeemed: 'pay-paid', cancelled: 'muted', expired: 'pay-refunded' };
export const vcStatusLabel = (c) => t(`vcl.st.${c}`);
export const vcStatusBadge = (c) => { const b = badge(STATUS_BADGE[c] || 'muted', vcStatusLabel(c)); b.dataset.status = c; return b; };
export const vcAge = (hours) => fmtAge(hours, { lt: t('vcl.age.lt'), day: t('vcl.age.d'), hour: t('vcl.age.h') });
export const srcLabel = (c) => t(`vcl.src.${c}`);
const parseAmount = (v) => { const s = String(v ?? '').trim().replace(',', '.'); if (!s) return { empty: true }; const n = Number(s); return Number.isFinite(n) && n >= 0 && Math.abs(Math.round(n * 100) - n * 100) < 1e-6 ? { n } : { bad: true }; };
const doneToast = (api, rpc) => (api.isMock() ? toast(t('mock.done', { rpc }), 'warn') : toast(t('done', { rpc }), 'ok'));

export function createVouchersTab({ api, vouchers, ctx, onOpenOrder = () => {} }) {
  const st = { search: '', status: 'active', sort: 'oldest_open', limit: 25, offset: 0 };
  const canResolve = !!ctx.can('giftcards.manage');
  const list = h('ul', { class: 'tl-list vc', 'data-testid': 'vcl-list' }), count = h('p', { class: 'muted tl-count', role: 'status', 'data-testid': 'vcl-count' }), pagers = [h('div'), h('div')];
  const summary = h('ul', { class: 'vcl-sum', 'data-testid': 'vcl-summary', 'aria-label': t('vcl.title') });
  let seq = 0, reopen = null, remindH = 24;
  const afterChange = (id) => { reopen = id; api.changed?.(); load(); };

  async function loadSummary() {
    try {
      const s = await vouchers.summary(); remindH = s.remind_after_hours;
      const chip = (key, text, tone) => h('li', { class: `vcl-chip${tone ? ` ${tone}` : ''}`, 'data-testid': `vcl-sum-${key}`, text });
      summary.replaceChildren(...(s.active ? [chip('active', t('vcl.sum.active', { n: fmt.int(s.active) })), s.oldest ? chip('oldest', t('vcl.sum.oldest', { age: vcAge(s.oldest.age_hours) })) : null,
        s.problem ? chip('problem', t('vcl.sum.problem', { n: fmt.int(s.problem) }), 'bad') : null, s.stale ? chip('stale', t('vcl.sum.stale', { n: fmt.int(s.stale), h: s.remind_after_hours }), 'warn') : null,
        s.needs_review ? chip('review', t('vcl.sum.review', { n: fmt.int(s.needs_review) }), 'warn') : null].filter(Boolean) : [chip('none', t('vcl.sum.none'))]));
    } catch { summary.replaceChildren(); }   // yhteenveto on lisä: puuttuva RPC ei estä listaa
  }
  async function load() {
    const my = ++seq;
    list.replaceChildren(loading()); list.setAttribute('aria-busy', 'true');
    try {
      const r = await vouchers.list({ search: st.search, status: st.status, sort: st.sort, limit: st.limit, offset: st.offset });
      if (my !== seq) return;
      list.setAttribute('aria-busy', 'false');
      if (st.offset >= r.total && r.total > 0) { st.offset = Math.max(0, Math.floor((r.total - 1) / st.limit) * st.limit); return load(); }
      count.textContent = r.total ? t('vcl.count', { from: fmt.int(st.offset + 1), to: fmt.int(Math.min(st.offset + st.limit, r.total)), total: fmt.int(r.total) }) : '';
      list.replaceChildren(...(r.claims.length ? r.claims.map(claimRow) : [emptyBox(t('vcl.none'))]));
      const mk = () => (r.total > st.limit ? pager({ total: r.total, offset: st.offset, limit: st.limit, onPage: (o) => { st.offset = o; load(); } }) : h('span'));
      pagers[0].replaceChildren(mk()); pagers[1].replaceChildren(mk());
      if (reopen != null) { const row = list.querySelector(`[data-claim-id="${reopen}"] .tl-head`); reopen = null; row?.click(); }
    } catch (e) { if (my === seq) { list.replaceChildren(errorBox(e, load)); count.textContent = ''; pagers.forEach((p) => p.replaceChildren()); } }
  }
  const who = (c) => c.customer_name || c.customer_email || '–';
  function claimRow(c) {
    const stale = c.stale && c.active;
    const head = [
      h('span', { class: 'tl-c tl-main' }, h('strong', { class: 'gc-code', 'data-testid': 'vcl-code', text: c.code_masked }), ' ', h('span', { class: 'tl-name', text: `${c.source_label || srcLabel(c.source)} · ${who(c)}` })),
      h('span', { class: 'tl-c tl-date' }, h('small', { class: 'tl-lab', text: t('vcl.col.age') }), h('span', { 'data-testid': 'vcl-age', text: c.age_hours != null ? vcAge(c.age_hours) : '–' })),
      h('span', { class: 'tl-c tl-first' }, h('small', { class: 'tl-lab', text: t('vcl.col.order') }), h('span', { text: c.order_no ? t('vcl.orderNo', { no: c.order_no }) : '–' })),
      h('span', { class: 'tl-c tl-sum' }, h('small', { class: 'tl-lab', text: t('vcl.col.amount') }), h('strong', { text: c.status === 'redeemed' && c.amount ? fmt.money(c.amount) : '–' })),
      h('span', { class: 'tl-c tl-badges' }, vcStatusBadge(c.status), c.status === 'problem' && c.problem_code ? badge('err', t(`vcl.pc.${c.problem_code}`)) : null,
        stale ? Object.assign(badge('warn', t('vcl.stale')), { title: t('vcl.staleTitle', { h: remindH }) }) : null, c.needs_review ? badge('warn', t('vcl.review')) : null),
    ];
    const row = expandRow({ id: `vc${c.id}`, head, testid: 'vcl', build: () => detail(c.id) });
    row.dataset.claimId = String(c.id); row.dataset.status = c.status; if (stale) row.dataset.stale = '1';
    return row;
  }
  async function detail(id) {
    const d = await vouchers.get({ id }), c = d.claim;
    const dl = (rows) => h('dl', { class: 'gc-dl' }, rows.filter(Boolean).flatMap(([k, v]) => [h('dt', { text: k }), h('dd', { text: v })]));
    const copy = h('button', { type: 'button', class: 'btn tl-rc-btn', 'data-testid': 'vcl-copy', onclick: async () => { try { await navigator.clipboard.writeText(c.code); toast(t('vcl.d.copied'), 'ok'); } catch { /* leikepöytä ei käytössä */ } } }, icon('copy', 18), h('span', { text: t('vcl.d.copy') }));
    const gs = d.source_guess.source, mismatch = !!gs && gs !== c.source && c.source !== 'partner_other';
    const by = c.resolved_by ? (['bot', 'staff', 'customer', 'system'].includes(c.resolved_by) ? t(`vcl.by.${c.resolved_by}`) : c.resolved_by) : null;
    const info = h('section', { class: 'tl-sec' }, h('h3', { text: t('vcl.d.info') }),
      h('p', { class: 'gc-bigcode', 'data-testid': 'vcl-detail-code' }, h('strong', { text: c.code || c.code_masked }), c.code ? copy : null),
      h('p', { class: 'muted tl-hint', text: t('vcl.d.revealNote') }),
      dl([[t('vcl.d.source'), c.source_label || srcLabel(c.source)], [t('vcl.d.status'), vcStatusLabel(c.status)], c.problem_code && [t('vcl.d.problem'), t(`vcl.pc.${c.problem_code}`)],
        [t('vcl.d.customer'), c.customer_name || '–'], c.customer_email && [t('vcl.d.email'), c.customer_email], c.customer_phone && [t('vcl.d.phone'), c.customer_phone],
        c.order_no && [t('vcl.d.order'), `#${c.order_no}`], d.order && [t('vcl.d.orderState'), payLabel(d.order.payment_status)], d.order && [t('vcl.d.total'), fmt.money(d.order.total)], d.order && [t('vcl.d.unpaid'), fmt.money(d.order.balance.unpaid)],
        c.voucher_value != null && [t('vcl.d.value'), fmt.money(c.voucher_value)], c.amount != null && c.status === 'redeemed' && [t('vcl.d.amount'), fmt.money(c.amount)], c.partner_ref && [t('vcl.d.ref'), c.partner_ref],
        [t('vcl.d.attempts'), String(c.attempts)], c.last_checked_at && [t('vcl.d.checked'), fmt.dt(c.last_checked_at)], [t('vcl.d.created'), fmt.dt(c.created_at)], c.resolved_at && [t('vcl.d.resolved'), fmt.dt(c.resolved_at)], by && [t('vcl.d.by'), by]]),
      h('p', { class: 'tl-hint', 'data-testid': 'vcl-guess', text: gs ? t('vcl.d.guess', { source: srcLabel(gs) }) : t('vcl.d.noGuess') }),
      mismatch ? h('p', { class: 'tl-johku-note', role: 'note', 'data-testid': 'vcl-mismatch', text: t('vcl.d.mismatch') }) : null,
      c.needs_review ? h('p', { class: 'tl-johku-note', role: 'note', text: t('vcl.d.reviewNote') }) : null,
      c.order_no ? h('p', {}, h('button', { type: 'button', class: 'btn', 'data-testid': 'vcl-open-order', onclick: () => onOpenOrder(c.order_no) }, t('vcl.d.openOrder', { no: c.order_no }))) : null);
    const sub = (title, items, none, tid) => h('section', { class: 'tl-sec' }, h('h3', { text: title }), items.length ? h('ul', { class: 'tl-sub', 'data-testid': tid }, items) : emptyBox(none));
    const res = sub(t('vcl.d.reservations'), d.reservations.map((x) => h('li', {}, h('span', { class: 'tl-sub-main', text: x.product_name || `#${x.id}` }), h('span', { class: 'tl-sub-meta', text: [fmt.dt(x.starts_at), t('vcl.d.persons', { n: x.persons })].join(' · ') }), h('span', { class: 'tl-sub-sum' }))), t('vcl.d.noReservations'), 'vcl-reservations');
    const pay = sub(t('vcl.d.payment'), d.payment ? [h('li', {}, h('span', { class: 'tl-sub-main', text: t('method.partner_voucher') }), h('span', { class: 'tl-sub-meta', text: [d.payment.paid_at ? fmt.dt(d.payment.paid_at) : null, d.payment.note].filter(Boolean).join(' · ') }), h('span', { class: 'tl-sub-sum', text: fmt.money(d.payment.amount) }))] : [], t('vcl.d.noPayment'), 'vcl-payment');
    const notes = c.notes ? h('section', { class: 'tl-sec' }, h('h3', { text: t('vcl.d.notes') }), h('p', { class: 'vcl-notes', 'data-testid': 'vcl-notes', text: c.notes })) : null;
    const fin = !c.active, noRight = t('vcl.a.noRight'), off = !canResolve ? noRight : fin ? t('vcl.a.final') : null;
    const actions = h('div', { class: 'tl-actions', 'data-testid': 'vcl-actions' },
      actionBtn({ key: 'redeem', label: t('vcl.a.redeem'), ico: 'check', testid: 'vcl-btn-redeem', extraDisabled: off, onClick: () => redeemDialog(c, d) }),
      actionBtn({ key: 'problem', label: t('vcl.a.problem'), ico: 'lock', testid: 'vcl-btn-problem', extraDisabled: off, onClick: () => problemDialog(c) }),
      actionBtn({ key: 'cancel', label: t('vcl.a.cancel'), ico: 'close', testid: 'vcl-btn-cancel', extraDisabled: off, onClick: () => noteDialog(c, 'cancelled') }),
      actionBtn({ key: 'reopen', label: t('vcl.a.reopen'), ico: 'undo', testid: 'vcl-btn-reopen', extraDisabled: off || (c.status === 'open' ? t('vcl.a.alreadyOpen') : null), onClick: () => noteDialog(c, 'open') }));
    return h('div', { class: 'tl-detail', 'data-testid': 'vcl-detail' }, info, h('section', { class: 'tl-sec' }, h('h3', { text: t('vcl.a.title') }), h('p', { class: 'muted tl-hint', text: t('vcl.a.hint') }), actions), res, pay, notes);
  }
  const checkNote = (v) => { const n = String(v || '').trim(); if (n.length > VC_NOTE_MAX) throw new Error(t('vcl.badNote')); return n || undefined; };
  function redeemDialog(c, d) {
    const amount = h('input', { name: 'amount', type: 'text', inputmode: 'decimal', autocomplete: 'off', 'data-testid': 'vcl-r-amount', 'aria-describedby': 'vcl-r-amount-hint' });
    formDialog(t('vcl.r.title'), [h('p', { class: 'muted', text: t('vcl.r.text') }), h('p', { class: 'gc-bigcode' }, h('strong', { text: `${c.source_label || srcLabel(c.source)} ${c.code_masked}` })),
      fld(t('vcl.r.amount'), amount, h('small', { id: 'vcl-r-amount-hint', text: t('vcl.r.amountHint') })), fld(t('vcl.r.ref'), h('input', { name: 'ref', maxlength: 100, 'data-testid': 'vcl-r-ref' })),
      fld(t('vcl.r.note'), h('input', { name: 'note', maxlength: VC_NOTE_MAX, 'data-testid': 'vcl-r-note' })), h('p', { class: 'muted tl-hint', text: t('vcl.r.acct') })], t('vcl.r.submit'), async (fd) => {
      const a = parseAmount(fd.get('amount')); if (a.bad) throw new Error(t('vcl.badAmount'));
      const res = await vouchers.resolve({ id: c.id, status: 'redeemed', amount: a.empty ? undefined : a.n, partnerRef: String(fd.get('ref') || '').trim() || undefined, note: checkNote(fd.get('note')) });
      doneToast(vouchers, 'admin_resolve_voucher_claim');
      toast(res.payment_id ? t('vcl.r.done', { amount: fmt.money(res.amount), unpaid: fmt.money(res.balance?.unpaid ?? 0) }) : t('vcl.r.doneNone'), 'ok');
      afterChange(c.id);
    });
  }
  function problemDialog(c) {
    const sel = h('select', { name: 'problem_code', required: true, 'data-testid': 'vcl-p-code' }, VC_PROBLEM_CODES.map((x) => h('option', { value: x, text: t(`vcl.pc.${x}`) })));
    sel.value = c.problem_code || 'invalid_code';
    formDialog(t('vcl.p.title'), [h('p', { class: 'gc-bigcode' }, h('strong', { text: `${c.source_label || srcLabel(c.source)} ${c.code_masked}` })), fld(t('vcl.p.code'), sel), fld(t('vcl.p.note'), h('input', { name: 'note', maxlength: VC_NOTE_MAX, 'data-testid': 'vcl-p-note' })),
      h('p', { class: 'muted tl-hint', text: t('vcl.p.mail') })], t('vcl.p.submit'), async (fd) => {
      const res = await vouchers.resolve({ id: c.id, status: 'problem', problemCode: fd.get('problem_code'), note: checkNote(fd.get('note')) });
      doneToast(vouchers, 'admin_resolve_voucher_claim'); toast(res.problem_email_queued ? t('vcl.p.queued') : t('vcl.p.done'), 'ok'); afterChange(c.id);
    });
  }
  function noteDialog(c, status) {
    const k = status === 'cancelled' ? 'c' : 'o';
    formDialog(t(`vcl.${k}.title`), [h('p', { class: 'muted', text: t(`vcl.${k}.text`) }), h('p', { class: 'gc-bigcode' }, h('strong', { text: `${c.source_label || srcLabel(c.source)} ${c.code_masked}` })), fld(t(`vcl.${k}.note`), h('input', { name: 'note', maxlength: VC_NOTE_MAX, 'data-testid': 'vcl-n-note' }))], t(`vcl.${k}.submit`), async (fd) => {
      await vouchers.resolve({ id: c.id, status, note: checkNote(fd.get('note')) });
      doneToast(vouchers, 'admin_resolve_voucher_claim'); toast(t(`vcl.${k}.done`), 'ok'); afterChange(c.id);
    });
  }

  // ---- työkalupalkki ----
  let toolbar;
  const change = (patch) => { Object.assign(st, patch, { offset: 0 }); load(); };
  function buildToolbar() {
    const ss = searchFld(t('vcl.search'), 'vcl-search', (v) => change({ search: v })); ss.input.value = st.search;
    const sort = h('label', { class: 'fld' }, h('span', { text: t('vcl.f.sort') }), h('select', { 'data-testid': 'vcl-f-sort', onchange: (e) => change({ sort: e.target.value }) }, VC_SORTS.map((s) => h('option', { value: s, text: t(`vcl.sort.${s}`) }))));
    sort.querySelector('select').value = st.sort;
    const next = h('form', { class: 'tl-toolbar', role: 'search', onsubmit: (e) => e.preventDefault() }, ss.node,
      selectFld(t('vcl.f.status'), 'vcl-f-status', VC_STATUSES, vcStatusLabel, st.status, (v) => change({ status: v }), t('vcl.st.all')), sort, pageSizeSelect(st.limit, (n) => change({ limit: n })),
      h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'vcl-reset', onclick: () => { Object.assign(st, { search: '', status: 'active', sort: 'oldest_open', offset: 0 }); buildToolbar(); load(); } }, t('filters.reset')));
    if (toolbar?.isConnected) toolbar.replaceWith(next);
    toolbar = next; return next;
  }
  buildToolbar();
  const refresh = h('button', { type: 'button', class: 'btn', 'data-testid': 'vcl-refresh', onclick: () => { loadSummary(); load(); } }, h('span', { text: t('vcl.refresh') }));
  const cols = h('div', { class: 'tl-cols gc', 'aria-hidden': 'true' }, h('span', { text: t('vcl.col.source') }), h('span', { text: t('vcl.col.age') }), h('span', { text: t('vcl.col.order') }), h('span', { class: 'r', text: t('vcl.col.amount') }), h('span', { text: t('vcl.col.status') }), h('span'));
  const node = h('div', { class: 'tl-tab', 'data-testid': 'tab-vouchers' }, h('div', { class: 'row between wrap vcl-top' }, h('div', {}, h('h2', { class: 'vcl-h', text: t('vcl.title') }), h('p', { class: 'muted tl-hint', text: t('vcl.lead') })), refresh), summary, toolbar, count, pagers[0], cols, list, pagers[1]);
  return { node, load() { loadSummary(); return load(); }, setSearch(q) { st.search = q; st.status = ''; st.offset = 0; buildToolbar(); load(); } };
}
