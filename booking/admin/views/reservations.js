// Varauslista: haku (nimi/sähköposti/puhelin/tilausnumero), suodattimet (tila, tuote, aikaväli), sivutus.
import { rpc } from '../sb.js';
import { h, fmtDate, fmtTime, todayHel, addDays, dayStartIso, statusBadge, payBadge, money, field, empty, STATUS } from '../ui.js';
import { reservationDialog } from './shared.js';

export async function render({ refs, reload }) {
  const PAGE = 50;
  const f = { search: '', status: '', product: '', from: addDays(todayHel(), -7), to: addDays(todayHel(), 60) };
  const list = h('div', { class: 'list' }); const more = h('div', { class: 'row center' }); const count = h('p', { class: 'muted' });
  let offset = 0;
  async function load(reset) {
    if (reset) { offset = 0; list.replaceChildren(); }
    const rows = await rpc('admin_list_reservations', {
      p_from: f.from ? dayStartIso(f.from) : null, p_to: f.to ? dayStartIso(addDays(f.to, 1)) : null, p_search: f.search || null,
      p_status: f.status || null, p_product_id: f.product ? +f.product : null, p_limit: PAGE, p_offset: offset });
    const total = rows[0]?.total_count ?? 0;
    if (reset && !rows.length) list.append(empty('Ei varauksia hakuehdoilla.'));
    for (const r of rows) list.append(h('button', { type: 'button', class: 'listrow', onclick: () => reservationDialog(r, { methods: refs.methods, onChange: () => load(true) }) },
      h('span', { class: 'when' }, h('strong', { text: fmtDate(r.starts_at) }), ` ${fmtTime(r.starts_at)}`),
      h('span', { class: 'what' }, h('strong', { text: r.customer_name || '–' }), h('small', { text: ` ${r.product_name} · ${r.persons} hlö` })),
      h('span', { class: 'meta' }, statusBadge(r.status), payBadge(r.payment_status), h('span', { text: money(r.total_gross) }), h('small', { text: `#${r.order_no}` }))));
    offset += rows.length; count.textContent = `${Math.min(offset, total)} / ${total} varausta`;
    more.replaceChildren(offset < total ? h('button', { type: 'button', class: 'btn ghost', onclick: () => load(false) }, 'Näytä lisää') : '');
  }
  const bind = (el, key, ev = 'input') => { let t; el.addEventListener(ev, () => { f[key] = el.value; clearTimeout(t); t = setTimeout(() => load(true), ev === 'input' ? 250 : 0); }); return el; };
  const filters = h('div', { class: 'filters card' },
    field('Haku', bind(h('input', { type: 'search', placeholder: 'Nimi, sähköposti, puhelin tai tilausnumero' }), 'search')),
    field('Tila', bind(h('select', {}, h('option', { value: '', text: 'Kaikki' }), Object.entries(STATUS).map(([k, v]) => h('option', { value: k, text: v }))), 'status', 'change')),
    field('Tuote', bind(h('select', {}, h('option', { value: '', text: 'Kaikki' }), refs.products.filter((p) => p.config?.bookable).map((p) => h('option', { value: p.id, text: p.name }))), 'product', 'change')),
    field('Alkaen', bind(h('input', { type: 'date', value: f.from }), 'from', 'change')), field('Päättyen', bind(h('input', { type: 'date', value: f.to }), 'to', 'change')));
  await load(true);
  return [h('h1', { text: 'Varaukset' }), filters, count, list, more];
}
