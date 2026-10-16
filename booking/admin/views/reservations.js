// Varauslista: haku (nimi/sähköposti/puhelin/tilausnumero), suodattimet (tila, tuote, aikaväli, lähde Kaikki/Uudet/Johku), sivutus.
// Lähdesuodatin → RPC:n p_source ('native' = Uudet, 'johku' = Johku; Kaikki = parametria ei lähetetä → null). Johku-varauksilla "Johku"-tunniste.
export const SOURCE_FILTERS = [['', 'Kaikki'], ['native', 'Uudet'], ['johku', 'Johku']];
import { rpc } from '../sb.js';
import { h, fmtDate, fmtTime, todayHel, addDays, dayStartIso, statusBadge, payBadge, sourceBadge, money, field, empty, errMsg, STATUS } from '../ui.js';
import { reservationDialog } from './shared.js';

export async function render({ refs, reload }) {
  const PAGE = 50;
  const f = { search: '', status: '', product: '', source: '', from: addDays(todayHel(), -7), to: addDays(todayHel(), 60) };
  const list = h('div', { class: 'list' }); const more = h('div', { class: 'row center' }); const count = h('p', { class: 'muted' });
  let offset = 0;
  async function load(reset) {
    if (reset) { offset = 0; list.replaceChildren(); }
    const args = {
      p_from: f.from ? dayStartIso(f.from) : null, p_to: f.to ? dayStartIso(addDays(f.to, 1)) : null, p_search: f.search || null,
      p_status: f.status || null, p_product_id: f.product ? +f.product : null, p_limit: PAGE, p_offset: offset };
    if (f.source) args.p_source = f.source;   // Kaikki: ei parametria (toimii myös ennen migraatiota 12)
    let rows;
    try { rows = await rpc('admin_list_reservations', args); } catch (e) {
      list.replaceChildren(h('p', { class: 'err', role: 'alert', text: `Varausten haku epäonnistui: ${errMsg(e)}${f.source ? ' (lähdesuodatin vaatii tietokantamigraation booking_12)' : ''}` })); more.replaceChildren(); count.textContent = ''; return;
    }
    const total = rows[0]?.total_count ?? 0;
    if (reset && !rows.length) list.append(empty('Ei varauksia hakuehdoilla.'));
    for (const r of rows) list.append(h('button', { type: 'button', class: 'listrow', onclick: () => reservationDialog(r, { methods: refs.methods, onChange: () => load(true) }) },
      h('span', { class: 'when' }, h('strong', { text: fmtDate(r.starts_at) }), ` ${fmtTime(r.starts_at)}`),
      h('span', { class: 'what' }, h('strong', { text: r.customer_name || '–' }), h('small', { text: ` ${r.product_name} · ${r.persons} hlö` })),
      h('span', { class: 'meta' }, sourceBadge(r), statusBadge(r.status), payBadge(r.payment_status), h('span', { text: money(r.total_gross) }), h('small', { text: `#${r.order_no}` }))));
    offset += rows.length; count.textContent = `${Math.min(offset, total)} / ${total} varausta`;
    more.replaceChildren(offset < total ? h('button', { type: 'button', class: 'btn ghost', onclick: () => load(false) }, 'Näytä lisää') : '');
  }
  const bind = (el, key, ev = 'input') => { let t; el.addEventListener(ev, () => { f[key] = el.value; clearTimeout(t); t = setTimeout(() => load(true), ev === 'input' ? 250 : 0); }); return el; };
  const sourceSet = h('fieldset', { class: 'srcset', 'data-testid': 'source-filter' }, h('legend', { text: 'Lähde' }),
    SOURCE_FILTERS.map(([v, label]) => h('label', { class: 'srcopt' }, h('input', { type: 'radio', name: 'source', value: v, checked: v === f.source || null, onchange: () => { f.source = v; load(true); } }), h('span', { text: label }))));
  const filters = h('div', { class: 'filters card' },
    field('Haku', bind(h('input', { type: 'search', placeholder: 'Nimi, sähköposti, puhelin tai tilausnumero' }), 'search')),
    field('Tila', bind(h('select', {}, h('option', { value: '', text: 'Kaikki' }), Object.entries(STATUS).map(([k, v]) => h('option', { value: k, text: v }))), 'status', 'change')),
    field('Tuote', bind(h('select', {}, h('option', { value: '', text: 'Kaikki' }), refs.products.filter((p) => p.config?.bookable).map((p) => h('option', { value: p.id, text: p.name }))), 'product', 'change')),
    field('Alkaen', bind(h('input', { type: 'date', value: f.from }), 'from', 'change')), field('Päättyen', bind(h('input', { type: 'date', value: f.to }), 'to', 'change')), sourceSet);
  await load(true);
  return [h('h1', { text: 'Varaukset' }), filters, count, list, more];
}
