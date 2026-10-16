// Resurssit: tila + kapasiteettipoolit (muokkaus vain admin), vuorosäännöt (luku; muutos migraatiolla/SQL:llä, ks. README) ja sulut.
import { rpc, select } from '../sb.js';
import { h, helsinkiIso, dialog, field, toast, run, fmtDT, badge, money } from '../ui.js';

const WD = ['ma', 'ti', 'ke', 'to', 'pe', 'la', 'su'];
export async function render({ ctx, refs, reload }) {
  const isAdmin = ctx.role === 'admin';
  const [rules, blocks] = await Promise.all([
    select('schedule_rules', { select: '*', order: 'sort_order.asc,id.asc' }),
    select('space_blocks', { select: '*', active: 'eq.true', ends_at: `gte.${new Date().toISOString()}`, order: 'starts_at.asc' }),
  ]);
  const res = refs.resources.map((r) => {
    const cap = h('input', { type: 'number', min: 1, value: r.capacity ?? '', disabled: !isAdmin || r.kind === 'space', 'aria-label': `Kapasiteetti: ${r.name}` });
    return h('div', { class: 'card resource' }, h('div', { class: 'grow' }, h('strong', { text: r.name }), h('small', { text: ` ${r.kind === 'space' ? 'tila' : 'kapasiteettipooli'} · ${r.code}` })),
      r.kind === 'capacity_pool' ? h('label', { class: 'row' }, 'Henkilöä yhtä aikaa ', cap) : null,
      isAdmin && r.kind === 'capacity_pool' ? h('button', { class: 'btn sm', type: 'button', text: 'Tallenna', onclick: (e) => run(e.target, async () => { await rpc('admin_update_resource', { p_id: r.id, p_patch: { capacity: +cap.value } }); toast('Tallennettu'); reload(true); }) }) : null);
  });
  const pn = (id) => refs.productById.get(id)?.name || id;
  const ruleRows = rules.map((r) => h('tr', { class: r.active ? '' : 'off' },
    h('td', { text: pn(r.product_id) }), h('td', { text: r.weekdays.map((d) => WD[d - 1]).join(' ') }), h('td', { text: `${r.start_time.slice(0, 5)} (${r.duration_minutes} min)` }),
    h('td', {}, badge(r.mode === 'exclusive' ? 'warn' : 'ok', r.mode === 'exclusive' ? 'yksityinen' : 'yleinen')), h('td', { text: r.max_persons ?? '' }),
    h('td', { text: r.price_mode === 'per_person' ? '€/hlö' : r.price_mode === 'fixed' ? 'kiinteä' : `kiinteä + lisä (${r.included_persons ?? ''} sis.)` }),
    h('td', { text: [r.valid_from, r.valid_to].filter(Boolean).join(' – ') }), h('td', { text: r.active ? '' : 'pois' })));
  const blockList = blocks.length ? h('ul', { class: 'reslist' }, blocks.map((b) => h('li', { class: 'resrow' }, h('span', { text: `${fmtDT(b.starts_at)} – ${fmtDT(b.ends_at)} · ${b.reason || ''}` }),
    h('button', { type: 'button', class: 'btn danger sm', onclick: (e) => run(e.target, async () => { await rpc('admin_delete_block', { p_id: b.id }); toast('Sulku poistettu'); reload(); }) }, 'Poista')))) : h('p', { class: 'muted', text: 'Ei tulevia sulkuja.' });
  const space = refs.resources.find((r) => r.kind === 'space');
  const addBlock = () => {
    const f = h('form', { class: 'stack' }, field('Alkaa', h('input', { type: 'datetime-local', name: 's', required: true })), field('Päättyy', h('input', { type: 'datetime-local', name: 'e', required: true })), field('Syy', h('input', { name: 'r' })), h('button', { class: 'btn primary', type: 'submit', text: 'Lisää sulku' }));
    const d = dialog('Lisää sulku', f);
    f.addEventListener('submit', (ev) => { ev.preventDefault(); run(f.querySelector('button'), async () => { await rpc('admin_create_block', { p_space_id: space.id, p_starts_at: helsinkiIso(f.s.value), p_ends_at: helsinkiIso(f.e.value), p_reason: f.r.value || null }); toast('Sulku lisätty'); d.close(); reload(); }); });
  };
  return [h('h1', { text: 'Resurssit' }), h('div', { class: 'stack' }, res),
    h('h2', { text: 'Vuorosäännöt' }), h('p', { class: 'muted', text: 'Säännöt ovat dataa (booking.schedule_rules). Uusi vuoro tai aikataulumuutos tehdään SQL-migraatiolla – ks. README "Sääntöjen muuttaminen".' }),
    h('div', { class: 'tablewrap' }, h('table', { class: 'tbl' }, h('thead', {}, h('tr', {}, ['Tuote', 'Päivät', 'Alkaa', 'Tyyppi', 'Max hlö', 'Hinnoittelu', 'Voimassa', ''].map((x) => h('th', { text: x })))), h('tbody', {}, ruleRows))),
    h('h2', { text: 'Sulut' }), blockList, h('button', { type: 'button', class: 'btn ghost', onclick: addBlock }, '+ Lisää sulku')];
}
