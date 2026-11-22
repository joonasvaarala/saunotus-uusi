// booking_336: informational only. No changes to the report's accounting totals.
import { h, toast, errMsg } from '../ui.js';
import { t, fmt, getLang } from '../talous-i18n.js';

const text = (key) => t(`r.johkuRefunds.${key}`);
const fields = ['refund_date', 'johku_order_no', 'order_no', 'customer_name', 'amount', 'original_payment_method', 'refund_method', 'note', 'created_by', 'created_at', 'id', 'order_id'];
const timestamp = (v) => {
  if (!v || !Number.isFinite(new Date(v).getTime())) return '–';
  return new Intl.DateTimeFormat(getLang() === 'en' ? 'en-GB' : 'fi-FI', { dateStyle: 'short', timeStyle: 'short', timeZone: 'Europe/Helsinki' }).format(new Date(v));
};
function table(id, cols, rows) {
  return h('div', { class: 'tl-johku-refunds-scroll' }, h('table', { class: 'tl-table', 'data-testid': id },
    h('thead', {}, h('tr', {}, cols.map((c) => h('th', { scope: 'col', text: c })))),
    h('tbody', {}, rows.map((row) => h('tr', {}, row.map((v, i) => h(i ? 'td' : 'th', { ...(i ? { 'data-label': cols[i] } : { scope: 'row' }), text: v })))))));
}
export function renderJohkuRefunds(j, { canExport = false, onCsv } = {}) {
  if (!j || typeof j !== 'object') return null;
  const rows = Array.isArray(j.rows) ? j.rows : [], methods = Array.isArray(j.by_refund_method) ? j.by_refund_method : [];
  const button = canExport && onCsv ? h('button', { type: 'button', class: 'btn tl-noprint', 'data-testid': 'r-johku-refunds-csv', text: text('csv'), onclick: async () => {
    button.disabled = true;
    try { await onCsv(); } catch (e) { toast(errMsg(e), 'err'); } finally { button.disabled = false; }
  } }) : null;
  const cell = (x, k) => k === 'amount' ? fmt.money(x[k] || 0) : k === 'refund_date' ? (x[k] ? fmt.date(x[k]) : '–') : k === 'created_at' ? timestamp(x[k]) : String(x[k] ?? '–');
  return h('section', { class: 'tl-sec tl-johku-block tl-johku-refunds', 'data-testid': 'r-johku-refunds', 'data-accounting': 'false' },
    h('h3', { text: text('title') }),
    h('p', { class: 'muted tl-johku-note', 'data-testid': 'r-johku-refunds-info', text: getLang() === 'fi' && j.info ? j.info : text('info') }),
    h('p', { class: 'muted', text: text('basis') }), button,
    h('h4', { text: text('rows') }),
    rows.length ? table('r-johku-refunds-rows', fields.map(text), rows.map((x) => fields.map((k) => cell(x, k)))) : h('p', { text: text('none') }),
    h('h4', { text: text('byMethod') }),
    methods.length ? table('r-johku-refunds-methods', [text('refund_method'), text('count'), text('amount')], methods.map((x) => [x.refund_method, fmt.int(x.count || 0), fmt.money(x.total || 0)])) : null,
    h('p', { 'data-testid': 'r-johku-refunds-count', text: `${text('count')}: ${fmt.int(j.count || 0)}` }),
    h('p', {}, h('strong', { 'data-testid': 'r-johku-refunds-total', text: `${text('total')}: ${fmt.money(j.total || 0)}` })));
}
