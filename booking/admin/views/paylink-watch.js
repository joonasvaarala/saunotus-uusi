// Kassa ja talous › Seurattavat maksut (booking_215). Oikeus payments.manage.
import { h, toast, errMsg, badge } from '../ui.js';
import { fmt, getLang, setLang, LANGS } from '../talous-i18n.js';
import { formDialog } from './talous-ui.js';
import { createPaylinkWatchApi } from '../paylink-watch-api.js';
import { pw, linkAge } from '../paylink-watch-texts.js';
import { rpc } from '../sb.js';

const SKIP_METHODS = new Set(['cash', 'gift_card', 'partner_voucher', 'pay_later', 'annual_card']);

function manualMethods(refs) {
  return (refs?.methods || []).filter((m) => m.is_manual && m.active && !SKIP_METHODS.has(m.code));
}

export async function render({ ctx, refs, reload }) {
  const lang = getLang();
  const api = createPaylinkWatchApi({ rpc });
  const st = { search: '', status: '', rows: [], total: 0 };
  const root = h('section', { class: 'tl paylink-watch', 'data-testid': 'paylink-watch', lang });
  if (!ctx?.can?.('payments.manage')) {
    root.append(h('h1', { text: pw('ui.admin.paylink_watch.title') }), h('p', { class: 'err', role: 'alert', text: pw('ui.admin.paylink_watch.no_perm') }));
    return root;
  }
  const count = h('p', { class: 'muted', 'data-testid': 'paylink-count' });
  const body = h('tbody');
  const table = h('table', { class: 'tl-table paylink-table', 'data-testid': 'paylink-table' },
    h('thead', {}, h('tr', {},
      ['amount', 'customer', 'order', 'age', 'due', 'reminders', 'next', 'status', 'actions'].map((k) => h('th', { scope: 'col', text: pw(`ui.admin.paylink_watch.col.${k}`) })))),
    body);
  const statusOf = (row) => (row.needs_action || row.status === 'needs_action' ? 'needs_action' : row.status === 'paused' ? 'paused' : 'watching');
  function reservationText(row) {
    const r = row.reservation;
    if (!r?.product_name && !r?.starts_at) return pw('ui.admin.paylink_watch.order_link', { no: row.order_no });
    const when = r.starts_at ? fmt.dt(r.starts_at) : '';
    const more = Number(r.count) > 1 ? ` ${pw('ui.admin.paylink_watch.reservation_more', { n: Number(r.count) - 1 })}` : '';
    return `${r.product_name || ''}${when ? ` · ${when}` : ''}${more}`;
  }
  function remindersText(row) {
    const n = Number(row.reminder_count ?? row.reminders?.length ?? 0);
    if (!n) return pw('ui.admin.paylink_watch.reminders_none');
    return pw('ui.admin.paylink_watch.reminders_n', { n, when: fmt.dt(row.last_reminder_at || row.reminders?.[n - 1]?.at) });
  }
  async function run(fn, okKey) {
    try { await fn(); if (okKey) toast(pw(okKey), 'ok'); await load(); }
    catch (e) { toast(errMsg(e), 'err'); }
  }
  function handled(row) {
    const methods = manualMethods(refs);
    const select = h('select', { name: 'method', required: true, 'data-testid': 'paylink-method' },
      h('option', { value: '', text: '–' }),
      ...methods.map((m) => h('option', { value: m.code, text: m.label || m.code })));
    formDialog(pw('ui.admin.paylink_watch.handled_title'), [
      h('p', { text: pw('ui.admin.paylink_watch.handled_body', { amount: fmt.money(row.amount) }) }),
      h('label', { class: 'fld' }, pw('ui.admin.paylink_watch.method'), select),
      h('label', { class: 'fld' }, pw('ui.admin.paylink_watch.note'), h('input', { name: 'note', type: 'text', maxlength: '500' })),
    ], pw('ui.admin.paylink_watch.confirm_handled'), async (fd) => {
      const method = String(fd.get('method') || '');
      if (!method) throw Object.assign(new Error(pw('ui.admin.paylink_watch.method')), { handled: false });
      const res = await api.markHandled(row.payment_id, method, String(fd.get('note') || ''));
      const receipt = res?.receipt_no ? pw('ui.admin.paylink_watch.receipt_bit', { no: res.receipt_no }) : '';
      toast(pw('ui.admin.paylink_watch.handled_ok', { receipt }), 'ok');
      await load();
    });
  }
  function draw(rows) {
    count.textContent = pw('ui.admin.paylink_watch.count', { n: st.total });
    if (!rows.length) {
      body.replaceChildren(h('tr', {}, h('td', { colspan: '9', text: pw('ui.admin.paylink_watch.empty') })));
      return;
    }
    body.replaceChildren(...rows.map((row) => {
      const status = statusOf(row);
      const due = row.link_expires_at ? fmt.date(row.link_expires_at) : pw('ui.admin.paylink_watch.no_due');
      const next = row.next_reminder_at ? fmt.dt(row.next_reminder_at) : pw('ui.admin.paylink_watch.next_none');
      const mark = badge(status === 'needs_action' ? 'needs-action' : status === 'paused' ? 'warn' : 'ok', pw(`ui.admin.paylink_watch.status.${status}`));
      mark.dataset.testid = 'paylink-status';
      return h('tr', { 'data-testid': 'paylink-row', 'data-status': status, 'data-payment': String(row.payment_id), class: status === 'needs_action' ? 'needs-action' : '' },
        h('td', { 'data-label': pw('ui.admin.paylink_watch.col.amount') }, h('strong', { text: fmt.money(row.amount) }), h('div', { class: 'muted', text: pw(`ui.admin.paylink_watch.kind.${row.link_kind === 'prepaid' ? 'prepaid' : 'onsite'}`) })),
        h('td', { 'data-label': pw('ui.admin.paylink_watch.col.customer'), text: row.customer_name || '–' }),
        h('td', { 'data-label': pw('ui.admin.paylink_watch.col.order') },
          h('a', { href: `#/talous?tab=orders&order=${encodeURIComponent(row.order_no)}`, text: pw('ui.admin.paylink_watch.order_link', { no: row.order_no }) }),
          h('div', { class: 'muted', text: reservationText(row) })),
        h('td', { 'data-label': pw('ui.admin.paylink_watch.col.age'), text: linkAge(row.created_at, lang) }),
        h('td', { 'data-label': pw('ui.admin.paylink_watch.col.due'), text: due }),
        h('td', { 'data-label': pw('ui.admin.paylink_watch.col.reminders'), text: remindersText(row) }),
        h('td', { 'data-label': pw('ui.admin.paylink_watch.col.next'), text: next }),
        h('td', { 'data-label': pw('ui.admin.paylink_watch.col.status') }, mark),
        h('td', { 'data-label': pw('ui.admin.paylink_watch.col.actions') }, h('div', { class: 'paylink-actions' },
          h('button', { type: 'button', class: 'btn', 'data-testid': 'paylink-remind', onclick: () => run(() => api.remindNow(row.payment_id), 'ui.admin.paylink_watch.sent') }, pw('ui.admin.paylink_watch.action.remind_now')),
          status === 'paused' ? null : h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'paylink-pause', onclick: () => run(() => api.pause(row.payment_id), 'ui.admin.paylink_watch.paused_ok') }, pw('ui.admin.paylink_watch.action.pause')),
          h('button', { type: 'button', class: 'btn', 'data-testid': 'paylink-handled', onclick: () => handled(row) }, pw('ui.admin.paylink_watch.action.handled')))));
    }));
  }
  async function load() {
    body.replaceChildren(h('tr', {}, h('td', { colspan: '9', text: pw('ui.admin.paylink_watch.loading') })));
    try {
      const res = await api.list({ search: st.search, status: st.status || null, limit: 50, offset: 0 });
      st.rows = res?.rows || [];
      st.total = Number(res?.total ?? st.rows.length);
      draw(st.rows);
    } catch (e) {
      st.rows = []; st.total = 0; count.textContent = '';
      body.replaceChildren(h('tr', {}, h('td', { colspan: '9', class: 'err', text: errMsg(e) })));
    }
  }
  const search = h('input', { type: 'search', 'data-testid': 'paylink-search', placeholder: pw('ui.admin.paylink_watch.search'), oninput: (e) => { st.search = e.target.value; load(); } });
  const filter = h('select', { 'data-testid': 'paylink-filter', onchange: (e) => { st.status = e.target.value; load(); } },
    ...['', 'watching', 'paused', 'needs_action'].map((v) => h('option', { value: v, text: pw(`ui.admin.paylink_watch.filter.${v || 'all'}`) })));
  const langs = h('div', { class: 'tl-langs', role: 'group' }, LANGS.map((l) => h('button', {
    type: 'button', class: 'tl-lang', 'aria-pressed': String(lang === l), lang: l,
    onclick: () => { if (getLang() === l) return; setLang(l); reload?.(); },
  }, l.toUpperCase())));
  root.append(
    h('div', { class: 'row between wrap' }, h('h1', { text: pw('ui.admin.paylink_watch.title') }), langs),
    h('p', { class: 'muted', text: pw('ui.admin.paylink_watch.intro') }),
    h('div', { class: 'paylink-tools' }, search, filter),
    count, table);
  await load();
  return root;
}
