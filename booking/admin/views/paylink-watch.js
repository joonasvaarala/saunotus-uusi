// Kassa ja talous › Seurattavat maksut (booking_215). Oikeus payments.manage.
// UX-uudistus: kortit (summa isolla, yksi päänappi, muut ⋯-valikkoon) + suodatinsirut määrineen.
import { h, toast, errMsg, badge } from '../ui.js';
import { fmt, getLang, setLang, LANGS } from '../talous-i18n.js';
import { formDialog } from './talous-ui.js';
import { createPaylinkWatchApi } from '../paylink-watch-api.js';
import { pw, linkAge } from '../paylink-watch-texts.js';
import { rpc } from '../sb.js';

const SKIP_METHODS = new Set(['cash', 'gift_card', 'partner_voucher', 'pay_later', 'annual_card']);
const FILTERS = ['', 'needs_action', 'watching', 'paused'];

function manualMethods(refs) {
  return (refs?.methods || []).filter((m) => m.is_manual && m.active && !SKIP_METHODS.has(m.code));
}

export async function render({ ctx, refs, reload }) {
  const lang = getLang();
  const api = createPaylinkWatchApi({ rpc });
  const st = { search: '', status: '', rows: [], total: 0, counts: { '': 0, watching: 0, paused: 0, needs_action: 0 } };
  const root = h('section', { class: 'tl paylink-watch', 'data-testid': 'paylink-watch', lang });
  if (!ctx?.can?.('payments.manage')) {
    root.append(h('h1', { text: pw('ui.admin.paylink_watch.title') }), h('p', { class: 'err', role: 'alert', text: pw('ui.admin.paylink_watch.no_perm') }));
    return root;
  }
  const count = h('p', { class: 'muted', 'data-testid': 'paylink-count' });
  const list = h('div', { class: 'paylink-cards', 'data-testid': 'paylink-table' });
  const chips = h('div', { class: 'paylink-chips', role: 'group', 'aria-label': pw('ui.admin.paylink_watch.filter.all'), 'data-testid': 'paylink-filter' });
  const statusOf = (row) => (row.needs_action || row.status === 'needs_action' ? 'needs_action' : row.status === 'paused' ? 'paused' : 'watching');
  function reservationText(row) {
    const r = row.reservation;
    if (!r?.product_name && !r?.starts_at) return '';
    const when = r.starts_at ? fmt.dt(r.starts_at) : '';
    const more = Number(r.count) > 1 ? ` ${pw('ui.admin.paylink_watch.reservation_more', { n: Number(r.count) - 1 })}` : '';
    return `${r.product_name || ''}${when ? ` ${when}` : ''}${more}`;
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
  function moreMenu(row, status) {
    const items = [];
    if (status === 'watching') {
      items.push({ testid: 'paylink-pause', label: pw('ui.admin.paylink_watch.action.pause'), run: () => run(() => api.pause(row.payment_id), 'ui.admin.paylink_watch.paused_ok') });
      items.push({ testid: 'paylink-handled', label: pw('ui.admin.paylink_watch.action.handled'), run: () => handled(row) });
    } else if (status === 'needs_action') {
      items.push({ testid: 'paylink-pause', label: pw('ui.admin.paylink_watch.action.pause'), run: () => run(() => api.pause(row.payment_id), 'ui.admin.paylink_watch.paused_ok') });
      items.push({ testid: 'paylink-remind', label: pw('ui.admin.paylink_watch.action.remind_now'), run: () => run(() => api.remindNow(row.payment_id), 'ui.admin.paylink_watch.sent') });
    } else {
      items.push({ testid: 'paylink-remind', label: pw('ui.admin.paylink_watch.action.remind_now'), run: () => run(() => api.remindNow(row.payment_id), 'ui.admin.paylink_watch.sent') });
    }
    const menu = h('div', { class: 'paylink-more-menu', hidden: true, role: 'menu' });
    const btn = h('button', { type: 'button', class: 'btn ghost paylink-more-btn', 'aria-haspopup': 'true', 'aria-expanded': 'false', 'data-testid': 'paylink-more', 'aria-label': 'Lisää toimintoja', text: '⋯' });
    const close = () => { menu.hidden = true; btn.setAttribute('aria-expanded', 'false'); };
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const open = menu.hidden;
      root.querySelectorAll('.paylink-more-menu').forEach((m) => { m.hidden = true; });
      root.querySelectorAll('.paylink-more-btn').forEach((b) => b.setAttribute('aria-expanded', 'false'));
      menu.hidden = !open;
      btn.setAttribute('aria-expanded', String(open));
    });
    menu.append(...items.map((it) => h('button', { type: 'button', role: 'menuitem', class: 'paylink-more-item', 'data-testid': it.testid, onclick: () => { close(); it.run(); } }, it.label)));
    return h('div', { class: 'paylink-more' }, btn, menu);
  }
  function primaryAction(row, status) {
    if (status === 'needs_action' || status === 'paused') {
      return h('button', { type: 'button', class: 'btn primary', 'data-testid': 'paylink-handled', onclick: () => handled(row) }, pw('ui.admin.paylink_watch.action.handled'));
    }
    return h('button', { type: 'button', class: 'btn primary', 'data-testid': 'paylink-remind', onclick: () => run(() => api.remindNow(row.payment_id), 'ui.admin.paylink_watch.sent') }, pw('ui.admin.paylink_watch.action.remind_now'));
  }
  function paintChips() {
    chips.replaceChildren(...FILTERS.map((v) => {
      const n = st.counts[v] ?? 0;
      const label = pw(`ui.admin.paylink_watch.filter.${v || 'all'}`);
      const on = st.status === v;
      return h('button', {
        type: 'button', class: `btn sm paylink-chip${on ? ' on' : ''}`, 'aria-pressed': on ? 'true' : 'false',
        'data-testid': `paylink-chip-${v || 'all'}`,
        onclick: () => { st.status = v; paintChips(); draw(filtered()); },
      }, `${label} ${n}`);
    }));
  }
  function filtered() {
    if (!st.status) return st.rows;
    return st.rows.filter((r) => statusOf(r) === st.status);
  }
  function draw(rows) {
    count.textContent = pw('ui.admin.paylink_watch.count', { n: st.total });
    if (!rows.length) {
      list.replaceChildren(h('p', { class: 'empty', 'data-testid': 'paylink-empty', text: pw('ui.admin.paylink_watch.empty') }));
      return;
    }
    list.replaceChildren(...rows.map((row) => {
      const status = statusOf(row);
      const due = row.link_expires_at ? fmt.date(row.link_expires_at) : pw('ui.admin.paylink_watch.no_due');
      const next = row.next_reminder_at ? fmt.dt(row.next_reminder_at) : null;
      const mark = badge(status === 'needs_action' ? 'needs-action' : status === 'paused' ? 'warn' : 'ok', pw(`ui.admin.paylink_watch.status.${status}`));
      mark.dataset.testid = 'paylink-status';
      const meta = [
        due,
        remindersText(row),
        next ? `${pw('ui.admin.paylink_watch.col.next')}: ${next}` : null,
      ].filter(Boolean).join(' · ');
      return h('article', { class: `card paylink-card${status === 'needs_action' ? ' needs-action' : ''}`, 'data-testid': 'paylink-row', 'data-status': status, 'data-payment': String(row.payment_id) },
        h('div', { class: 'paylink-card-top' },
          h('div', { class: 'paylink-card-who' },
            h('strong', { text: row.customer_name || '–' }),
            h('a', { class: 'muted', href: `#/talous?tab=orders&order=${encodeURIComponent(row.order_no)}`, text: pw('ui.admin.paylink_watch.order_link', { no: row.order_no }) })),
          h('div', { class: 'paylink-card-amount' },
            h('strong', { text: fmt.money(row.amount) }),
            h('span', { class: 'muted', text: pw(`ui.admin.paylink_watch.kind.${row.link_kind === 'prepaid' ? 'prepaid' : 'onsite'}`) }))),
        h('p', { class: 'paylink-card-res muted', text: reservationText(row) || '–' }),
        h('div', { class: 'paylink-card-meta' }, mark, h('span', { class: 'muted', text: meta }), h('span', { class: 'muted', text: linkAge(row.created_at, lang) })),
        h('div', { class: 'paylink-card-actions' }, primaryAction(row, status), moreMenu(row, status)));
    }));
  }
  async function load() {
    list.replaceChildren(h('p', { class: 'muted', text: pw('ui.admin.paylink_watch.loading') }));
    try {
      const res = await api.list({ search: st.search, status: null, limit: 50, offset: 0 });
      st.rows = res?.rows || [];
      st.total = Number(res?.total ?? st.rows.length);
      st.counts = { '': st.total, watching: 0, paused: 0, needs_action: 0 };
      for (const r of st.rows) st.counts[statusOf(r)] = (st.counts[statusOf(r)] || 0) + 1;
      paintChips();
      draw(filtered());
    } catch (e) {
      st.rows = []; st.total = 0; count.textContent = '';
      list.replaceChildren(h('p', { class: 'err', role: 'alert', text: errMsg(e) }));
    }
  }
  let searchTimer = 0;
  const search = h('input', { type: 'search', 'data-testid': 'paylink-search', placeholder: pw('ui.admin.paylink_watch.search'), oninput: (e) => {
    st.search = e.target.value;
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => load(), 200);
  } });
  // Piilotettu select säilyttää vanhan testid-sopimuksen (suodatin = sirut).
  const filter = h('select', { hidden: true, 'data-testid': 'paylink-filter-select', onchange: (e) => { st.status = e.target.value; paintChips(); draw(filtered()); } },
    ...FILTERS.map((v) => h('option', { value: v, text: pw(`ui.admin.paylink_watch.filter.${v || 'all'}`) })));
  const langs = h('div', { class: 'tl-langs', role: 'group' }, LANGS.map((l) => h('button', {
    type: 'button', class: 'tl-lang', 'aria-pressed': String(lang === l), lang: l,
    onclick: () => { if (getLang() === l) return; setLang(l); reload?.(); },
  }, l.toUpperCase())));
  root.addEventListener('click', (e) => {
    if (e.target.closest?.('.paylink-more')) return;
    root.querySelectorAll('.paylink-more-menu').forEach((m) => { m.hidden = true; });
    root.querySelectorAll('.paylink-more-btn').forEach((b) => b.setAttribute('aria-expanded', 'false'));
  });
  root.append(
    h('div', { class: 'row between wrap' }, h('h1', { text: pw('ui.admin.paylink_watch.title') }), langs),
    h('p', { class: 'muted', text: pw('ui.admin.paylink_watch.intro') }),
    h('div', { class: 'paylink-tools' }, search, filter),
    chips, count, list);
  await load();
  return root;
}
