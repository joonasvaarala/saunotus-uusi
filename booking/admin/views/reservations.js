// Varauslista: haku (nimi/sähköposti/puhelin/tilausnumero), suodattimet (tila, tuote, ajanjakso, lähde, hoito), sivutus.
// Ajanjakso (pikavalinta): Kaikki ajat (oletus; p_from/p_to = null, RPC sallii null) / Tulevat (tästä päivästä alkaen) / Menneet (ennen tätä päivää) / Tämä kuukausi / Oma ajanjakso (Alkaen/Päättyen näkyvät vain silloin).
// Lähdesuodatin → RPC:n p_source ('native' = Uudet, 'johku' = Johku; Kaikki = parametria ei lähetetä → null). Johku-varauksilla "Johku"-tunniste.
// Hoito valitsematta: ?filter=treatment_unassigned (päivänäkymän muistutus lisää myös period=upcoming). Palvelin: p_option_missing (booking_72).
// Ennen migraatiota rajaus tehdään option_missing-kentästä. Suodattimet ovat yhteisessä laatikossa (filter-drawer): haku jää näkyviin,
// muu paneeli on kiinni. Valitut suodattimet ja niiden Poista-painike ovat palkissa (status), joten ne näkyvät paneelin ollessa kiinni.
export const PERIODS = [['all', 'Kaikki ajat'], ['upcoming', 'Tulevat'], ['past', 'Menneet'], ['month', 'Tämä kuukausi'], ['custom', 'Oma ajanjakso']];
export const SOURCE_FILTERS = [['', 'Kaikki'], ['native', 'Uudet'], ['johku', 'Johku']];
import { rpc } from '../sb.js';
import { h, fmtDate, fmtTime, todayHel, addDays, dayStartIso, statusBadge, payBadge, sourceBadge, money, field, empty, errMsg, STATUS } from '../ui.js';
import { filterDrawer } from '../filter-drawer.js';
import { reservationDialog } from './shared.js';
import { resourceBadges, spaceBadge } from './legs.js';
import { optionBadge } from '../options.js';
import { loadOptionTexts, optionText } from '../options-texts.js';
import { TREATMENT_UNASSIGNED, reservationsHref, stateFromQuery, loadReservationPage } from '../reservation-query.js';
import { reviewAttentionCount } from '../review-logic.js';

export async function render({ ctx, refs, reload, query }) {
  const PAGE = 50;
  const init = stateFromQuery(query || '');
  const f = {
    search: init.search, status: STATUS[init.status] ? init.status : '', product: init.product, source: ['', 'native', 'johku'].includes(init.source) ? init.source : '',
    period: init.period, treatment: init.treatment, from: init.from || addDays(todayHel(), -7), to: init.to || addDays(todayHel(), 60),
  };
  await loadOptionTexts(rpc);
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
  const activeBar = h('div', { class: 'active-filters', 'data-testid': 'active-filters', hidden: true });
  const cache = { all: null };
  let offset = 0;
  const syncHash = () => {
    const next = reservationsHref(f);
    if (next !== location.hash) history.replaceState(null, '', next);   // ei hashchangea → ei uudelleenpiirtoa
  };
  let drawer;
  function paintActive() {
    const root = drawer?.node;
    const chips = [];
    const chip = (key, label, clear) => h('span', { class: 'chip', 'data-testid': `active-filter-${key}` }, h('span', { text: label }), h('button', { type: 'button', class: 'btn', 'data-testid': `clear-filter-${key}`, 'aria-label': `${optionText('ui.admin.options.filter_clear')}: ${label}`, onclick: clear }, optionText('ui.admin.options.filter_clear')));
    if (f.treatment === TREATMENT_UNASSIGNED) chips.push(chip('treatment', optionText('ui.admin.options.filter_unassigned'), () => setTreatment('')));
    if (f.period !== 'all') chips.push(chip('period', periodLabel(), () => setPeriod('all')));
    if (f.status) chips.push(chip('status', STATUS[f.status] || f.status, () => { f.status = ''; const sel = root?.querySelector('[data-testid=status-filter]'); if (sel) sel.value = ''; syncHash(); load(true); }));
    if (f.product) { const p = refs.products.find((x) => String(x.id) === String(f.product)); chips.push(chip('product', p?.name || f.product, () => { f.product = ''; const sel = root?.querySelector('[data-testid=product-filter]'); if (sel) sel.value = ''; syncHash(); load(true); })); }
    if (f.source) chips.push(chip('source', SOURCE_FILTERS.find(([k]) => k === f.source)?.[1] || f.source, () => setSource('')));
    if (f.search) chips.push(chip('search', f.search, () => { f.search = ''; const inp = root?.querySelector('[data-testid=reservations-search]'); if (inp) inp.value = ''; syncHash(); load(true); }));
    activeBar.hidden = chips.length === 0;
    activeBar.replaceChildren(...chips);
    drawer?.refresh();
  }
  async function load(reset) {
    if (reset) { offset = 0; cache.all = null; list.replaceChildren(); }
    const rg = range();
    const args = {
      p_from: rg.from ? dayStartIso(rg.from) : null, p_to: rg.toExcl ? dayStartIso(rg.toExcl) : null, p_search: f.search || null,
      p_status: f.status || null, p_product_id: f.product ? +f.product : null };
    if (f.source) args.p_source = f.source;   // Kaikki: ei parametria (toimii myös ennen migraatiota 12)
    let rows, total;
    try {
      ({ rows, total } = await loadReservationPage(rpc, args, { treatment: f.treatment, offset, limit: PAGE, cache }));
    } catch (e) {
      list.replaceChildren(h('p', { class: 'err', role: 'alert', text: `Varausten haku epäonnistui: ${errMsg(e)}${f.source ? ' (lähdesuodatin vaatii tietokantamigraation booking_12)' : ''}` })); more.replaceChildren(); count.textContent = ''; return;
    }
    if (reset && !rows.length) list.append(empty('Ei varauksia hakuehdoilla.'));
    // kortti: ylärivillä aika (vasen) + tilausnumero (oikea yläkulma), keskellä nimi + tuote, alarivillä merkit (vasen alakulma) + hinta (oikea alakulma)
    for (const r of rows) list.append(h('button', { type: 'button', class: 'listrow rescard', 'data-testid': 'reservation-row', 'data-reservation-id': r.reservation_id, 'data-option-missing': r.option_missing ? '1' : '0', onclick: () => reservationDialog(r, { methods: refs.methods, onChange: () => load(true), refs, can: ctx.can }) },
      h('span', { class: 'rc-when' }, h('strong', { text: fmtDate(r.starts_at) }), ` ${fmtTime(r.starts_at)}`),
      h('span', { class: 'rc-no', text: `#${r.order_no}`, title: 'Tilausnumero' }),
      h('span', { class: 'rc-what' }, h('strong', { text: r.customer_name || '–' }), h('small', { text: ` ${r.product_name} · ${r.persons} hlö` })),
      h('span', { class: 'meta rc-badges' }, optionBadge(r), spaceBadge(r, refs), resourceBadges(r), sourceBadge(r), statusBadge(r.status), payBadge(r.payment_status)),
      h('span', { class: 'rc-price', text: money(r.total_gross) })));
    offset += rows.length; count.textContent = `${Math.min(offset, total)} / ${total} varausta · ${periodLabel()}${f.treatment === TREATMENT_UNASSIGNED ? ` · ${optionText('ui.admin.options.filter_unassigned')}` : ''}`;
    more.replaceChildren(offset < total ? h('button', { type: 'button', class: 'btn ghost', onclick: () => load(false) }, 'Näytä lisää') : '');
    paintActive();
  }
  const bind = (el, key, ev = 'input') => { let t; el.addEventListener(ev, () => { f[key] = el.value; clearTimeout(t); t = setTimeout(() => { syncHash(); load(true); }, ev === 'input' ? 250 : 0); }); return el; };
  // pikavalintaryhmä (radiogroup: nuolinäppäimet vaihtavat valintaa)
  const seg = (legend, name, opts, cur, onPick, testid) => h('fieldset', { class: 'srcset', 'data-testid': testid }, h('legend', { text: legend }),
    opts.map(([v, label]) => h('label', { class: 'srcopt' }, h('input', { type: 'radio', name, value: v, checked: v === cur || null, onchange: () => onPick(v) }), h('span', { text: label }))));
  const mark = (set, value) => { for (const r of set.querySelectorAll('input')) r.checked = r.value === value; };
  const dates = h('div', { class: 'perdates', hidden: f.period !== 'custom' },
    field('Alkaen', bind(h('input', { type: 'date', value: f.from }), 'from', 'change')), field('Päättyen', bind(h('input', { type: 'date', value: f.to }), 'to', 'change')));
  let periodSet, sourceSet, treatmentSet;
  const setPeriod = (v) => { f.period = v; dates.hidden = v !== 'custom'; mark(periodSet, v); syncHash(); load(true); };
  const setSource = (v) => { f.source = v; mark(sourceSet, v); syncHash(); load(true); };
  const setTreatment = (v) => { f.treatment = v; mark(treatmentSet, v); syncHash(); load(true); };
  periodSet = seg('Ajanjakso', 'period', PERIODS, f.period, setPeriod, 'period-filter');
  sourceSet = seg('Lähde', 'source', SOURCE_FILTERS, f.source, setSource, 'source-filter');
  treatmentSet = seg(optionText('ui.admin.options.filter_legend'), 'treatment', [['', optionText('ui.admin.options.filter_all')], [TREATMENT_UNASSIGNED, optionText('ui.admin.options.filter_unassigned')]], f.treatment, setTreatment, 'treatment-filter');
  drawer = filterDrawer({
    className: 'filters card',
    testid: 'reservations-filters',
    search: field('Haku', bind(h('input', { type: 'search', value: f.search, placeholder: 'Nimi, sähköposti, puhelin tai tilausnumero', 'data-testid': 'reservations-search' }), 'search')),
    status: activeBar,
    activeCount: () => [f.status, f.product, f.source, f.treatment].filter(Boolean).length + (f.period !== 'all' ? 1 : 0),
    filters: [
      field('Tila', bind(h('select', { 'data-testid': 'status-filter' }, h('option', { value: '', text: 'Kaikki', selected: !f.status || null }), Object.entries(STATUS).map(([k, v]) => h('option', { value: k, text: v, selected: k === f.status || null }))), 'status', 'change')),
      field('Tuote', bind(h('select', { 'data-testid': 'product-filter' }, h('option', { value: '', text: 'Kaikki', selected: !f.product || null }), refs.products.filter((p) => p.config?.bookable).map((p) => h('option', { value: p.id, text: p.name, selected: String(p.id) === String(f.product) || null }))), 'product', 'change')),
      h('div', { class: 'filter-groups' }, periodSet, dates, sourceSet, treatmentSet),
    ],
  });
  syncHash();
  await load(true);
  // pikatoiminnot: vanhan varauksen kirjaus (admin_create_old_booking) ja Tarkista-lista (laskuri haetaan taustalla; virhe/puuttuva migraatio = ei laskuria)
  const reviewCount = h('span', { class: 'badge warn', hidden: true });
  rpc('admin_review_list').then((v) => { const n = reviewAttentionCount(v); if (n) { reviewCount.textContent = String(n); reviewCount.hidden = false; reviewCount.setAttribute('aria-label', `${n} tarkistettavaa`); } }).catch(() => {});
  const actions = h('div', { class: 'row wrap pageactions' },
    h('a', { class: 'btn', href: '#/uusi?tyyppi=vanha', text: 'Vanha varaus' }),
    h('a', { class: 'btn ghost', href: '#/tarkista' }, 'Tarkista ', reviewCount));
  return [h('h1', { text: 'Varaukset' }), actions, drawer.node, count, list, more];
}
