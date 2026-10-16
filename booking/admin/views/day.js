// Päivänäkymä: vuorot kapasiteetteineen + varaukset vuoroittain + sulut.
import { rpc } from '../sb.js';
import { h, helsinkiIso, fmtDay, fmtTime, todayHel, addDays, dayStartIso, statusBadge, payBadge, badge, toast, run, dialog, field, fmtDT, empty } from '../ui.js';
import { reservationDialog } from './shared.js';

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
  const active = rows.filter((r) => ['pending', 'confirmed', 'completed'].includes(r.status));
  const used = new Set();
  const sessions = (view.sessions || []).map((s) => {
    const mine = rows.filter((r) => r.product_id === s.product_id && r.starts_at === s.starts_at);
    mine.forEach((r) => used.add(r.reservation_id));
    return { s, mine };
  }).filter(({ s, mine }) => mine.length || s.status !== 'closed');
  const open = (r) => reservationDialog(r, { methods: refs.methods, onChange: reload });
  const resRow = (r) => h('li', { class: `resrow ${r.status}` },
    h('button', { type: 'button', class: 'link', onclick: () => open(r) }, h('strong', { text: r.customer_name || '–' }), ` · ${r.persons} hlö`),
    h('span', { class: 'meta' }, statusBadge(r.status), payBadge(r.payment_status), r.hold_expires_at ? badge('muted', `pito ${fmtTime(r.hold_expires_at)}`) : null, ` #${r.order_no}`));
  const card = ({ s, mine }) => {
    const booked = mine.filter((r) => ['pending', 'confirmed', 'completed'].includes(r.status)).reduce((a, r) => a + r.persons, 0);
    const prod = refs.productById.get(s.product_id);
    const st = s.status === 'available' ? badge('ok', s.mode === 'exclusive' ? 'Vapaa' : `Vapaana ${s.remaining}`) : s.status === 'full' ? badge('err', 'Täynnä') : s.status === 'unavailable' ? badge('muted', 'Ei myynnissä (päällekkäisyys/sulku)') : badge('muted', 'Myynti päättynyt');
    return h('section', { class: `card session ${s.mode}` },
      h('header', {}, h('strong', { class: 'time', text: `${fmtTime(s.starts_at)}–${fmtTime(s.ends_at)}` }), h('span', { class: 'ttl', text: prod?.name || s.label }), st,
        h('span', { class: 'cnt', text: s.mode === 'exclusive' ? (mine.some((r) => ['pending', 'confirmed'].includes(r.status)) ? 'Yksityisvuoro varattu' : 'Yksityisvuoro') : `${booked} hlö varattu` })),
      mine.length ? h('ul', { class: 'reslist' }, mine.map(resRow)) : null);
  };
  const orphan = rows.filter((r) => !used.has(r.reservation_id));
  const blocks = h('section', { class: 'card' }, h('h3', { text: 'Sulut' }),
    (view.blocks || []).length ? h('ul', { class: 'reslist' }, view.blocks.map((b) => h('li', { class: 'resrow' }, h('span', {}, `${fmtDT(b.starts_at)} – ${fmtDT(b.ends_at)} · ${b.reason || ''}`),
      h('button', { type: 'button', class: 'btn danger sm', onclick: (e) => run(e.target, async () => { await rpc('admin_delete_block', { p_id: b.id }); toast('Sulku poistettu'); reload(); }) }, 'Poista')))) : h('p', { class: 'muted', text: 'Ei sulkuja.' }),
    h('button', { type: 'button', class: 'btn ghost sm', onclick: () => blockDialog(date, refs, reload) }, '+ Lisää sulku'));
  return [h('h1', { text: fmtDay(`${date}T12:00:00Z`) }), toolbar,
    h('div', { class: 'daygrid day-view' }, sessions.length ? sessions.map(card) : empty('Ei vuoroja tälle päivälle.'),
      orphan.length ? h('section', { class: 'card' }, h('h3', { text: 'Muut varaukset' }), h('ul', { class: 'reslist' }, orphan.map(resRow))) : null),
    h('p', { class: 'muted', text: `${active.length} aktiivista varausta, ${active.reduce((a, r) => a + r.persons, 0)} henkilöä yhteensä.` }), blocks];
}

function blockDialog(date, refs, reload) {
  const space = refs.resources.find((r) => r.kind === 'space');
  const f = h('form', { class: 'stack' },
    field('Alkaa', h('input', { type: 'datetime-local', name: 's', value: `${date}T08:00`, required: true })),
    field('Päättyy', h('input', { type: 'datetime-local', name: 'e', value: `${date}T22:00`, required: true })),
    field('Syy', h('input', { name: 'r', placeholder: 'esim. huolto, yksityistilaisuus', maxlength: 200 })),
    h('button', { class: 'btn primary', type: 'submit', text: 'Lisää sulku' }));
  const d = dialog('Lisää sulku (savusauna)', f);
  f.addEventListener('submit', (ev) => { ev.preventDefault(); run(f.querySelector('button'), async () => {
    await rpc('admin_create_block', { p_space_id: space.id, p_starts_at: helsinkiIso(f.s.value), p_ends_at: helsinkiIso(f.e.value), p_reason: f.r.value || null });
    toast('Sulku lisätty'); d.close(); reload();
  }); });
}
