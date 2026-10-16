// Päivänäkymä: vuorot kapasiteetteineen + varaukset vuoroittain + sulut.
import { rpc } from '../sb.js';
import { h, helsinkiIso, fmtDay, fmtTime, todayHel, addDays, dayStartIso, statusBadge, payBadge, sourceBadge, badge, toast, run, dialog, field, fmtDT, empty } from '../ui.js';
import { reservationDialog } from './shared.js';
import { icon } from '../icons.js';
import { legsList, resourceBadges, spaceBadge } from './legs.js';
import { blockList, blockDialog } from './blocks.js';

export async function render({ ctx, refs, reload, query }) {
  const date = /^\d{4}-\d\d-\d\d$/.test(query.get('d') || '') ? query.get('d') : todayHel();
  const [view, resv] = await Promise.all([
    rpc('admin_day_view', { p_date: date }),
    rpc('admin_list_reservations', { p_from: dayStartIso(date), p_to: dayStartIso(addDays(date, 1)), p_limit: 200 }),
  ]);
  const go = (d) => { location.hash = `#/?d=${d}`; };
  const toolbar = h('div', { class: 'toolbar' },
    h('button', { class: 'btn ghost', type: 'button', 'aria-label': 'Edellinen päivä', onclick: () => go(addDays(date, -1)) }, '‹'),
    h('input', { type: 'date', value: date, 'aria-label': 'Päivä', onchange: (e) => e.target.value && go(e.target.value) }),
    h('button', { class: 'btn ghost', type: 'button', 'aria-label': 'Seuraava päivä', onclick: () => go(addDays(date, 1)) }, '›'),
    h('button', { class: 'btn ghost sm', type: 'button', onclick: () => go(todayHel()) }, 'Tänään'),
    h('a', { class: 'btn primary sm', href: `#/uusi?d=${date}`, text: '+ Uusi varaus' }));
  const rows = resv || [];
  // Lisäpalvelut: varauskohtaiset (view.reservations), vuorokohtainen "valmistele" (view.prep) ja päivän summat (view.addon_totals)
  const dv = new Map((view.reservations || []).map((r) => [r.reservation_id, r]));
  const lc = (n) => (n ? n.charAt(0).toLowerCase() + n.slice(1) : n);
  const addonText = (items) => items.map((i) => `${i.quantity} × ${lc(i.name)}`).join(', ');
  const prepFor = (s) => (view.prep || []).find((p) => p.rule_id === s.rule_id && p.starts_at === s.starts_at);
  const active = rows.filter((r) => ['pending', 'confirmed', 'completed'].includes(r.status));
  const used = new Set();
  const sessions = (view.sessions || []).map((s) => {
    const mine = rows.filter((r) => r.product_id === s.product_id && r.starts_at === s.starts_at);
    mine.forEach((r) => used.add(r.reservation_id));
    return { s, mine };
  }).filter(({ s, mine }) => mine.length || s.status !== 'closed');
  const RES_KEYS = ['lifecycle', 'space_code', 'legs', 'quota_exempt', 'override_reason', 'claim_offset_min', 'claim_minutes', 'parent_reservation_id'];
  const merged = (r) => { const x = dv.get(r.reservation_id) || {}; const m = { ...r, source: r.source ?? x.source, external_id: r.external_id ?? x.external_id }; for (const k of RES_KEYS) if (x[k] !== undefined) m[k] = x[k]; return m; };
  const open = (r) => reservationDialog(merged(r), { methods: refs.methods, onChange: reload, refs, can: ctx.can });
  const resRow = (r) => { const x = dv.get(r.reservation_id) || {}; const ad = x.addons || []; const src = { source: r.source ?? x.source, external_id: r.external_id ?? x.external_id }; return h('li', { class: `resrow ${r.status}${ad.length ? ' has-addons' : ''}` },
    h('button', { type: 'button', class: 'link', onclick: () => open(r) }, h('strong', { text: r.customer_name || '–' }), ` · ${r.persons} hlö`, x.customer_kind === 'company' ? [' ', badge('warn', 'Yritys'), x.company ? ` ${x.company}` : ''] : null,
      ad.length ? h('span', { class: 'addon-mark' }, icon('leaf', 16), ` Lisäpalvelut: ${addonText(ad)}`) : null,
      (x.legs || []).length > 1 || (x.space_code && x.space_code !== 'savusauna') ? legsList(x.legs, refs) : null),
    h('span', { class: 'meta' }, spaceBadge(x, refs), resourceBadges(x), sourceBadge(src), statusBadge(r.status), payBadge(r.payment_status), r.hold_expires_at ? badge('muted', `pito ${fmtTime(r.hold_expires_at)}`) : null, ` #${r.order_no}`)); };
  const card = ({ s, mine }) => {
    const booked = mine.filter((r) => ['pending', 'confirmed', 'completed'].includes(r.status)).reduce((a, r) => a + r.persons, 0);
    const prod = refs.productById.get(s.product_id);
    const st = s.status === 'available' ? badge('ok', s.mode === 'exclusive' ? 'Vapaa' : `Vapaana ${s.remaining}`) : s.status === 'full' ? badge('err', 'Täynnä') : s.status === 'unavailable' ? badge('muted', 'Ei myynnissä (päällekkäisyys/sulku)') : badge('muted', 'Myynti päättynyt');
    return h('section', { class: `card session ${s.mode}` },
      h('header', {}, h('strong', { class: 'time', text: `${fmtTime(s.starts_at)}–${fmtTime(s.ends_at)}` }), h('span', { class: 'ttl', text: prod?.name || s.label }), st,
        h('span', { class: 'cnt', text: s.mode === 'exclusive' ? (mine.some((r) => ['pending', 'confirmed'].includes(r.status)) ? 'Yksityisvuoro varattu' : 'Yksityisvuoro') : `${booked} hlö varattu` })),
      prepFor(s) ? h('div', { class: 'prep', role: 'note' }, icon('leaf', 18), h('strong', { text: ' Valmistele: ' }), addonText(prepFor(s).items)) : null,
      mine.length ? h('ul', { class: 'reslist' }, mine.map(resRow)) : null);
  };
  const orphan = rows.filter((r) => !used.has(r.reservation_id));
  const blocks = h('section', { class: 'card', 'data-testid': 'day-blocks' }, h('h3', { text: 'Sulut' }), blockList(view.blocks, refs, reload, 'Ei sulkuja.'),
    h('button', { type: 'button', class: 'btn ghost sm', onclick: () => blockDialog(date, refs, reload) }, '+ Lisää sulku'));
  const prepAll = (view.prep || []).length ? h('section', { class: 'card prepday' }, h('h3', {}, icon('leaf', 20), ' Valmistele päivälle'),
    h('ul', { class: 'reslist' }, view.prep.map((p) => h('li', { class: 'resrow' }, h('span', {}, h('strong', { text: `${fmtTime(p.starts_at)}–${fmtTime(p.ends_at)}` }), ` ${p.product_name}: `, addonText(p.items))))),
    h('p', { class: 'muted' }, h('strong', { text: 'Yhteensä: ' }), addonText(view.addon_totals || []))) : null;
  return [h('h1', { text: fmtDay(`${date}T12:00:00Z`) }), toolbar, prepAll,
    h('div', { class: 'daygrid day-view' }, sessions.length ? sessions.map(card) : empty('Ei vuoroja tälle päivälle.'),
      orphan.length ? h('section', { class: 'card' }, h('h3', { text: 'Muut varaukset' }), h('ul', { class: 'reslist' }, orphan.map(resRow))) : null),
    h('p', { class: 'muted', text: `${active.length} aktiivista varausta, ${active.reduce((a, r) => a + r.persons, 0)} henkilöä yhteensä.` }), blocks];
}
