// Varauslista: haku (nimi/sähköposti/puhelin/tilausnumero), suodattimet (tila, tuote, ajanjakso, lähde Kaikki/Uudet/Johku), sivutus.
// Ajanjakso (pikavalinta): Kaikki ajat (oletus; p_from/p_to = null, RPC sallii null) / Tulevat (tästä päivästä alkaen) / Menneet (ennen tätä päivää) / Tämä kuukausi / Oma ajanjakso (Alkaen/Päättyen näkyvät vain silloin).
// Lähdesuodatin → RPC:n p_source ('native' = Uudet, 'johku' = Johku; Kaikki = parametria ei lähetetä → null). Johku-varauksilla "Johku"-tunniste.
export const PERIODS = [['all', 'Kaikki ajat'], ['upcoming', 'Tulevat'], ['past', 'Menneet'], ['month', 'Tämä kuukausi'], ['custom', 'Oma ajanjakso']];
export const SOURCE_FILTERS = [['', 'Kaikki'], ['native', 'Uudet'], ['johku', 'Johku']];
import { rpc } from '../sb.js';
import { h, fmtDate, fmtTime, todayHel, addDays, dayStartIso, statusBadge, payBadge, sourceBadge, money, field, empty, errMsg, STATUS } from '../ui.js';
import { reservationDialog } from './shared.js';
import { resourceBadges, spaceBadge } from './legs.js';

export async function render({ ctx, refs, reload }) {
  const PAGE = 50;
  const f = { search: '', status: '', product: '', source: '', period: 'all', from: addDays(todayHel(), -7), to: addDays(todayHel(), 60) };
  // valittu ajanjakso → { from: alkupäivä | null, toExcl: päättymispäivän jälkeinen päivä | null } (null = ei rajaa)
  const range = () => {
    const today = todayHel();
    if (f.period === 'upcoming') return { from: today, toExcl: null };
    if (f.period === 'past') return { from: null, toExcl: today };
    if (f.period === 'month') { const first = `${today.slice(0, 8)}01`; return { from: first, toExcl: `${addDays(first, 32).slice(0, 8)}01` }; }
    if (f.period === 'custom') return { from: f.from || null, toExcl: f.to ? addDays(f.to, 1) : null };
    return { from: null, toExcl: null };
  };
  const fd = (d) => d.split('-').reverse().map(Number).join('.');
  const periodLabel = () => { const r = range(); if (f.period !== 'custom') return PERIODS.find(([k]) => k === f.period)[1]; return !r.from && !r.toExcl ? 'Kaikki ajat' : r.from && r.toExcl ? `${fd(r.from)}–${fd(addDays(r.toExcl, -1))}` : r.from ? `alkaen ${fd(r.from)}` : `asti ${fd(addDays(r.toExcl, -1))}`; };
  const list = h('div', { class: 'list' }); const more = h('div', { class: 'row center' }); const count = h('p', { class: 'muted' });
  let offset = 0;
  async function load(reset) {
    if (reset) { offset = 0; list.replaceChildren(); }
    const rg = range();
    const args = {
      p_from: rg.from ? dayStartIso(rg.from) : null, p_to: rg.toExcl ? dayStartIso(rg.toExcl) : null, p_search: f.search || null,
      p_status: f.status || null, p_product_id: f.product ? +f.product : null, p_limit: PAGE, p_offset: offset };
    if (f.source) args.p_source = f.source;   // Kaikki: ei parametria (toimii myös ennen migraatiota 12)
    let rows;
    try { rows = await rpc('admin_list_reservations', args); } catch (e) {
      list.replaceChildren(h('p', { class: 'err', role: 'alert', text: `Varausten haku epäonnistui: ${errMsg(e)}${f.source ? ' (lähdesuodatin vaatii tietokantamigraation booking_12)' : ''}` })); more.replaceChildren(); count.textContent = ''; return;
    }
    const total = rows[0]?.total_count ?? 0;
    if (reset && !rows.length) list.append(empty('Ei varauksia hakuehdoilla.'));
    // kortti: ylärivillä aika (vasen) + tilausnumero (oikea yläkulma), keskellä nimi + tuote, alarivillä merkit (vasen alakulma) + hinta (oikea alakulma)
    for (const r of rows) list.append(h('button', { type: 'button', class: 'listrow rescard', onclick: () => reservationDialog(r, { methods: refs.methods, onChange: () => load(true), refs, can: ctx.can }) },
      h('span', { class: 'rc-when' }, h('strong', { text: fmtDate(r.starts_at) }), ` ${fmtTime(r.starts_at)}`),
      h('span', { class: 'rc-no', text: `#${r.order_no}`, title: 'Tilausnumero' }),
      h('span', { class: 'rc-what' }, h('strong', { text: r.customer_name || '–' }), h('small', { text: ` ${r.product_name} · ${r.persons} hlö` })),
      h('span', { class: 'meta rc-badges' }, spaceBadge(r, refs), resourceBadges(r), sourceBadge(r), statusBadge(r.status), payBadge(r.payment_status)),
      h('span', { class: 'rc-price', text: money(r.total_gross) })));
    offset += rows.length; count.textContent = `${Math.min(offset, total)} / ${total} varausta · ${periodLabel()}`;
    more.replaceChildren(offset < total ? h('button', { type: 'button', class: 'btn ghost', onclick: () => load(false) }, 'Näytä lisää') : '');
  }
  const bind = (el, key, ev = 'input') => { let t; el.addEventListener(ev, () => { f[key] = el.value; clearTimeout(t); t = setTimeout(() => load(true), ev === 'input' ? 250 : 0); }); return el; };
  // pikavalintaryhmä (radiogroup: nuolinäppäimet vaihtavat valintaa)
  const seg = (legend, name, opts, cur, onPick, testid) => h('fieldset', { class: 'srcset', 'data-testid': testid }, h('legend', { text: legend }),
    opts.map(([v, label]) => h('label', { class: 'srcopt' }, h('input', { type: 'radio', name, value: v, checked: v === cur || null, onchange: () => onPick(v) }), h('span', { text: label }))));
  const dates = h('div', { class: 'perdates', hidden: true },
    field('Alkaen', bind(h('input', { type: 'date', value: f.from }), 'from', 'change')), field('Päättyen', bind(h('input', { type: 'date', value: f.to }), 'to', 'change')));
  const periodSet = seg('Ajanjakso', 'period', PERIODS, f.period, (v) => { f.period = v; dates.hidden = v !== 'custom'; load(true); }, 'period-filter');
  const sourceSet = seg('Lähde', 'source', SOURCE_FILTERS, f.source, (v) => { f.source = v; load(true); }, 'source-filter');
  const filters = h('div', { class: 'filters card' },
    field('Haku', bind(h('input', { type: 'search', placeholder: 'Nimi, sähköposti, puhelin tai tilausnumero' }), 'search')),
    field('Tila', bind(h('select', {}, h('option', { value: '', text: 'Kaikki' }), Object.entries(STATUS).map(([k, v]) => h('option', { value: k, text: v }))), 'status', 'change')),
    field('Tuote', bind(h('select', {}, h('option', { value: '', text: 'Kaikki' }), refs.products.filter((p) => p.config?.bookable).map((p) => h('option', { value: p.id, text: p.name }))), 'product', 'change')),
    h('div', { class: 'filter-groups' }, periodSet, dates, sourceSet));
  await load(true);
  // pikatoiminnot: vanhan varauksen kirjaus (admin_create_old_booking) ja Tarkista-lista (laskuri haetaan taustalla; virhe/puuttuva migraatio = ei laskuria)
  const reviewCount = h('span', { class: 'badge warn', hidden: true });
  rpc('admin_review_list').then((v) => { const n = ['therapist_conflicts', 'block_conflicts', 'overrides', 'orphan_addons'].reduce((a, k) => a + (Array.isArray(v?.[k]) ? v[k].length : 0), 0); if (n) { reviewCount.textContent = String(n); reviewCount.hidden = false; reviewCount.setAttribute('aria-label', `${n} tarkistettavaa`); } }).catch(() => {});
  const actions = h('div', { class: 'row wrap pageactions' },
    h('a', { class: 'btn', href: '#/uusi?tyyppi=vanha', text: 'Vanha varaus' }),
    h('a', { class: 'btn ghost', href: '#/tarkista' }, 'Tarkista ', reviewCount));
  return [h('h1', { text: 'Varaukset' }), actions, filters, count, list, more];
}
