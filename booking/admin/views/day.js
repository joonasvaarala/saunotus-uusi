// Päivänäkymä: vuorot kapasiteetteineen + varaukset vuoroittain + sulut.
import { rpc } from '../sb.js';
import { h, helsinkiIso, fmtDay, fmtTime, todayHel, addDays, dayStartIso, statusBadge, payBadge, sourceBadge, badge, toast, run, dialog, field, fmtDT, empty } from '../ui.js';
import { reservationDialog } from './shared.js';
import { icon } from '../icons.js';
import { capacityButton, arrivalButton, addonItems, shiftsBar, prepCard } from './dayparts.js';
import { legsList, resourceBadges, spaceBadge } from './legs.js';
import { optionBadge, optionReminder } from '../options.js';
import { blockList, blockDialog } from './blocks.js';

export async function render({ ctx, refs, reload, query }) {
  const date = /^\d{4}-\d\d-\d\d$/.test(query.get('d') || '') ? query.get('d') : todayHel();
  const [view, resv, shifts, addonList, optNote] = await Promise.all([
    rpc('admin_day_view', { p_date: date }),
    rpc('admin_list_reservations', { p_from: dayStartIso(date), p_to: dayStartIso(addDays(date, 1)), p_limit: 200 }),
    shiftsBar(date, ctx.can),   // työvuorot (admin_day_shifts tai admin_upcoming_shifts, vain luku); ei koskaan heitä: puuttuva tieto/oikeus → selitysteksti
    rpc('admin_list_addons').catch(() => []),   // lisäpalvelun koodi addon_id:llä (ikonin tunnistus, jos admin_day_view ei anna code-kenttää)
    optionReminder(),   // muistutus: tulevat hoitovaraukset ilman valittua hoitoa (booking_50); null jos ei muistutettavaa
  ]);
  const codes = new Map((addonList || []).map((a) => [a.id, a.code]));
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
  const ACTIVE = ['pending', 'confirmed', 'completed'];
  const active = rows.filter((r) => ACTIVE.includes(r.status));
  const used = new Set();
  const sessions = (view.sessions || []).map((s) => {
    const mine = active.filter((r) => r.product_id === s.product_id && r.starts_at === s.starts_at);
    mine.forEach((r) => used.add(r.reservation_id));
    return { s, mine };
  }).filter(({ s, mine }) => mine.length || ['available', 'full'].includes(s.status));   // myymätön (päällekkäisyys, sulku, myynti päättynyt) tyhjä vuoro piiloon; vuoro jolla on varauksia näytetään ilman "ei myynnissä" -tekstiä
  const RES_KEYS = ['lifecycle', 'space_code', 'legs', 'quota_exempt', 'override_reason', 'claim_offset_min', 'claim_minutes', 'parent_reservation_id', 'therapist_missing', 'therapist_missing_open', 'therapist_exception_at', 'therapist_exception_note', 'option', 'option_missing'];
  const merged = (r) => { const x = dv.get(r.reservation_id) || {}; const m = { ...r, source: r.source ?? x.source, external_id: r.external_id ?? x.external_id }; for (const k of RES_KEYS) if (x[k] !== undefined) m[k] = x[k]; return m; };
  const open = (r) => reservationDialog(merged(r), { methods: refs.methods, onChange: reload, refs, can: ctx.can });
  const resRow = (r) => { const x = dv.get(r.reservation_id) || {}; const ad = x.addons || []; const src = { source: r.source ?? x.source, external_id: r.external_id ?? x.external_id };
    let stBadge = statusBadge(r.status);
    const arrive = arrivalButton(r, { can: ctx.can, onState: (st) => { const nb = statusBadge(st); stBadge.replaceWith(nb); stBadge = nb; } });
    return h('li', { class: `resrow ${r.status}${ad.length ? ' has-addons' : ''}${arrive ? ' has-arrive' : ''}` },
    h('div', { class: 'resmain' }, h('button', { type: 'button', class: 'link', onclick: () => open(r) }, h('strong', { text: r.customer_name || '–' }), ` · ${r.persons} hlö`, x.customer_kind === 'company' ? [' ', badge('warn', 'Yritys'), x.company ? ` ${x.company}` : ''] : null,
      (x.legs || []).length > 1 || (x.space_code && x.space_code !== 'savusauna') ? legsList(x.legs, refs) : null),
    ad.length ? h('div', { class: 'addon-mark' }, addonItems(ad, codes)) : null,
    h('span', { class: 'meta' }, optionBadge(x.option !== undefined ? x : r), spaceBadge(x, refs), resourceBadges(x), sourceBadge(src), stBadge, payBadge(r.payment_status), r.hold_expires_at ? badge('muted', `pito ${fmtTime(r.hold_expires_at)}`) : null, ` #${r.order_no}`)),
    arrive); };
  const sumPersons = (list) => list.reduce((a, r) => a + r.persons, 0);
  const card = ({ s, mine }) => {
    const booked = sumPersons(mine);
    const prod = refs.productById.get(s.product_id);
    const cap = capacityButton(s, date, mine.length > 0);
    return h('section', { class: `card session ${s.mode}`, 'data-testid': 'session', 'data-start': s.starts_at },
      h('header', {}, h('strong', { class: 'time', text: `${fmtTime(s.starts_at)}–${fmtTime(s.ends_at)}` }), h('span', { class: 'ttl', text: prod?.name || s.label }),
        h('span', { class: 'hdr-right' }, h('span', { class: 'cnt', 'data-testid': 'session-persons', text: s.mode === 'exclusive' && !booked ? '' : `${booked} hlö` }), cap)),
      mine.length ? h('ul', { class: 'reslist' }, mine.map(resRow)) : null);
  };
  // Muut aktiiviset varaukset (hoito, saunotus, rituaali, tapahtuma: ei vuorosääntöä) ryhmitellään aloitusajan ja tuotteen mukaan samaan aikajärjestykseen vuorojen kanssa.
  const slotMap = new Map();
  for (const r of active.filter((x) => !used.has(x.reservation_id))) { const k = `${r.starts_at}|${r.product_id}`; (slotMap.get(k) || slotMap.set(k, []).get(k)).push(r); }
  const slotCard = (list) => { const r0 = list[0];
    return h('section', { class: 'card session slot', 'data-testid': 'slot', 'data-start': r0.starts_at },
      h('header', {}, h('strong', { class: 'time', text: `${fmtTime(r0.starts_at)}–${fmtTime(r0.ends_at)}` }), h('span', { class: 'ttl', text: r0.product_name || refs.productById.get(r0.product_id)?.name || 'Varaus' }),
        h('span', { class: 'hdr-right' }, h('span', { class: 'cnt', 'data-testid': 'session-persons', text: `${sumPersons(list)} hlö` }))),
      h('ul', { class: 'reslist' }, list.map(resRow))); };
  const timeline = [...sessions.map((x) => ({ at: x.s.starts_at, end: x.s.ends_at, node: card(x) })), ...[...slotMap.values()].map((l) => ({ at: l[0].starts_at, end: l[0].ends_at, node: slotCard(l) }))]
    .sort((a, b) => a.at.localeCompare(b.at) || a.end.localeCompare(b.end)).map((x) => x.node);
  const inactive = rows.filter((r) => !ACTIVE.includes(r.status));
  const blocks = h('section', { class: 'card', 'data-testid': 'day-blocks' }, h('h3', { text: 'Sulut' }), blockList(view.blocks, refs, reload, 'Ei sulkuja.'),
    h('button', { type: 'button', class: 'btn ghost sm', onclick: () => blockDialog(date, refs, reload) }, '+ Lisää sulku'));
  const prepBox = prepCard({ totals: view.addon_totals, prep: view.prep, persons: sumPersons(active), bookings: active.length, codes });
  return [h('h1', { text: fmtDay(`${date}T12:00:00Z`) }), shifts, optNote, toolbar, prepBox,
    h('div', { class: 'daygrid day-view' }, timeline.length ? timeline : empty('Ei vuoroja tälle päivälle.')),
    inactive.length ? h('details', { class: 'card inactive-res', 'data-testid': 'inactive-res' }, h('summary', { text: `Peruutetut ja päättyneet varaukset (${inactive.length})` }), h('ul', { class: 'reslist' }, inactive.map(resRow))) : null,
    h('p', { class: 'muted', text: `${active.length} aktiivista varausta, ${sumPersons(active)} henkilöä yhteensä.` }), blocks];
}
