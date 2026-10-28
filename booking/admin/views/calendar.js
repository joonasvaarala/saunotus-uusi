// Kalenteri: kuukausi- ja viikkonäkymä, jossa työvuorot (admin_upcoming_shifts, vain luku) ja varaukset (admin_list_reservations) eri väreillä.
// Näkyvyys määräytyy oikeuksista tietokannassa: admin/manager (shifts.view_all) näkevät kaikki vuorot, staff (shifts.view) vain omansa (linkitys työntekijään).
// Jos vuorotietoja ei saada (public-skeema tyhjä / ei oikeutta), varaukset näytetään silti ja näytetään ystävällinen huomautus.
import { rpc } from '../sb.js';
import { h, fmtTime, todayHel, addDays, dayStartIso, errMsg, statusBadge, badge, empty } from '../ui.js';
import { reservationDialog } from './shared.js';

const TZ = 'Europe/Helsinki';
const dayKey = (iso) => new Date(iso).toLocaleDateString('sv-SE', { timeZone: TZ });
const dowMon = (ds) => (new Date(`${ds}T12:00:00Z`).getUTCDay() + 6) % 7;          // ma = 0
const fmtLong = (ds) => new Intl.DateTimeFormat('fi-FI', { timeZone: 'UTC', weekday: 'long', day: 'numeric', month: 'long' }).format(new Date(`${ds}T12:00:00Z`));
const WD = ['Ma', 'Ti', 'Ke', 'To', 'Pe', 'La', 'Su'];
// Työvuoron rooli ja miehitys näytetään aina suomeksi: kiinteä kartoitus tietokannan koodeista (role_type, staffing_status).
// Tuntematon role_type → kalenterin nimi (calendar_name) tai koodi sellaisenaan. "Hoitaja" yhtenäistetään saunottajaksi.
const ROLE_FI = { heater: 'Lämmitykset', reception: 'Vastaanotto', therapist: 'Saunottaja', saunottaja: 'Saunottaja', hoitaja: 'Saunottaja' };
const fixRole = (x) => String(x).replace(/\bhoitaja(t)?\b/gi, (_, pl) => (pl ? 'Saunottajat' : 'Saunottaja'));
export const roleLabel = (s) => ROLE_FI[String(s.role_type || '').toLowerCase()] || fixRole(s.calendar_name || s.role_type || 'Työvuoro');
// Työvuorokortin väriluokka roolin mukaan (värit: calendar.css)
const KIND_CLASS = { heater: 'shift-heater', therapist: 'shift-therapist', saunottaja: 'shift-therapist', hoitaja: 'shift-therapist', reception: 'shift-reception' };
const NAME_CLASS = [[/lämmit/i, 'shift-heater'], [/saunottaja|hoitaja/i, 'shift-therapist'], [/vastaanot/i, 'shift-reception']];   // tuntematon koodi → kalenterin nimestä
export const shiftClass = (s) => KIND_CLASS[String(s.role_type || '').toLowerCase()] || (NAME_CLASS.find(([re]) => re.test(s.calendar_name || '')) || [])[1] || 'shift-other';
// Miehitysmerkki: näytetään AINOASTAAN jos vuorolle ei ole nimetty ketään. Ensisijaisesti nimettyjen henkilöiden perusteella (staff_name / names);
// staffing_status (assigned/full/partial/open/unassigned) ei tuota merkkiä, jos nimettyjä on – data ei kerro tarvittua määrää, joten ei nimettyjä = ilmoitus, muuten ei mitään.
export const NO_ASSIGNEE = 'Ei nimettyä tekijää';
export const needsNotice = (s) => !(s.names && s.names.length);
function isoWeek(ds) { const d = new Date(`${ds}T12:00:00Z`); const day = (d.getUTCDay() + 6) % 7; d.setUTCDate(d.getUTCDate() - day + 3); const y = d.getUTCFullYear(); const j = new Date(Date.UTC(y, 0, 4)); return 1 + Math.round(((d - j) / 864e5 - 3 + ((j.getUTCDay() + 6) % 7)) / 7); }

export async function render({ ctx, refs, reload }) {
  const canShifts = ctx.can('shifts.view') || ctx.can('shifts.view_all');
  const allShifts = ctx.can('shifts.view_all');
  const state = { mode: 'month', date: todayHel(), sel: todayHel() };
  const root = h('div', { class: 'cal' });
  const body = h('div', { class: 'cal-body' });

  const rangeOf = () => {
    if (state.mode === 'week') { const s = addDays(state.date, -dowMon(state.date)); return { start: s, days: 7 }; }
    const first = `${state.date.slice(0, 7)}-01`; return { start: addDays(first, -dowMon(first)), days: 42 };
  };
  async function load({ start, days }) {
    const from = dayStartIso(start), to = dayStartIso(addDays(start, days));
    const out = { bookings: [], shifts: [], notice: null };
    const bk = (async () => { let all = [], off = 0; for (;;) { const rows = await rpc('admin_list_reservations', { p_from: from, p_to: to, p_status: 'active', p_limit: 500, p_offset: off }); all = all.concat(rows || []); if (!rows || rows.length < 500 || off >= 1000) break; off += 500; } return all; })();
    const sh = canShifts ? rpc('admin_upcoming_shifts', { p_from: from, p_to: to }).catch((e) => { out.notice = `Työvuorotietoja ei saatu haettua (${errMsg(e)}). Varaukset näytetään silti.`; return []; }) : Promise.resolve([]);
    if (!canShifts) out.notice = 'Sinulla ei ole oikeutta nähdä työvuoroja; näytetään vain varaukset.';
    const [b, s] = await Promise.all([bk, sh]);
    out.bookings = b;
    const byId = new Map();   // admin_upcoming_shifts palauttaa rivin per työntekijä → yhdistetään vuoroksi
    for (const r of s) { const x = byId.get(r.shift_id) || { ...r, names: [] }; if (r.staff_name) x.names.push(r.staff_name); byId.set(r.shift_id, x); }
    out.shifts = [...byId.values()].sort((a, c) => a.starts_at.localeCompare(c.starts_at));
    return out;
  }
  const group = (rows, key) => { const m = new Map(); for (const r of rows) { const k = dayKey(r[key]); (m.get(k) || m.set(k, []).get(k)).push(r); } return m; };

  const shiftItem = (s) => h('li', { class: `cal-item shift ${shiftClass(s)}`, 'data-kind': 'shift' },
    h('span', { class: 'cal-time', text: `${fmtTime(s.starts_at)}–${fmtTime(s.ends_at)}` }),
    h('span', { class: 'cal-txt' }, h('strong', { text: roleLabel(s) }),
      s.names.length ? [h('br'), h('span', { text: s.names.join(', ') })] : null),
    needsNotice(s) ? badge('warn', NO_ASSIGNEE) : null);
  const bookingItem = (r) => h('li', { class: 'cal-item booking', 'data-kind': 'booking' },
    h('span', { class: 'cal-time', text: fmtTime(r.starts_at) }),
    h('button', { type: 'button', class: 'link cal-txt', onclick: () => reservationDialog(r, { methods: refs.methods, onChange: () => draw(), refs, can: ctx?.can, role: ctx?.role }) }, h('strong', { text: r.customer_name || '–' }), ` · ${r.persons} hlö`, h('br'), h('small', { text: r.product_name || '' })),
    statusBadge(r.status));

  async function draw() {
    const rg = rangeOf();
    body.replaceChildren(h('p', { class: 'muted pad', text: 'Ladataan…' }));
    let data;
    try { data = await load(rg); } catch (e) { body.replaceChildren(h('p', { class: 'err pad', role: 'alert', text: errMsg(e) })); return; }
    const sh = group(data.shifts, 'starts_at'), bk = group(data.bookings, 'starts_at');
    const today = todayHel();
    const dayCell = (ds, inMonth) => {
      const ns = (sh.get(ds) || []).length, nb = (bk.get(ds) || []);
      const persons = nb.reduce((a, r) => a + (r.persons || 0), 0);
      const items = state.mode === 'week'
        ? h('ul', { class: 'cal-list' }, ...(sh.get(ds) || []).map(shiftItem), ...nb.slice().sort((a, c) => a.starts_at.localeCompare(c.starts_at)).map(bookingItem))
        : h('span', { class: 'cal-chips' }, ns ? h('span', { class: 'chip shift', title: `${ns} työvuoroa` }, h('b', { text: String(ns) }), h('span', { class: 'lbl', text: ' vuoroa' })) : null, nb.length ? h('span', { class: 'chip booking', title: `${nb.length} varausta, ${persons} henkilöä` }, h('b', { text: String(nb.length) }), h('span', { class: 'lbl', text: ` var. · ${persons} hlö` })) : null);
      return h('div', { class: `cal-day${inMonth ? '' : ' out'}${ds === today ? ' today' : ''}${ds === state.sel ? ' sel' : ''}`, 'data-date': ds },
        h('button', { type: 'button', class: 'cal-dnum', 'aria-label': `${fmtLong(ds)}: ${ns} työvuoroa, ${nb.length} varausta`, 'aria-pressed': ds === state.sel ? 'true' : 'false', onclick: () => { state.sel = ds; draw(); } },
          h('span', { class: 'wd', text: WD[dowMon(ds)] }), h('span', { class: 'n', text: String(+ds.slice(8)) })), items);
    };
    const cells = Array.from({ length: rg.days }, (_, i) => addDays(rg.start, i));
    const grid = h('div', { class: `cal-grid ${state.mode}` },
      state.mode === 'month' ? WD.map((w) => h('div', { class: 'cal-head', text: w })) : null,
      cells.map((ds) => dayCell(ds, state.mode === 'week' || ds.slice(0, 7) === state.date.slice(0, 7))));
    const selShifts = sh.get(state.sel) || [], selBk = (bk.get(state.sel) || []).slice().sort((a, c) => a.starts_at.localeCompare(c.starts_at));
    const detail = h('section', { class: 'cal-detail card', 'aria-live': 'polite' }, h('h2', { text: fmtLong(state.sel) }),
      h('h3', { class: 'shift-h', text: `Työvuorot (${selShifts.length})` }), selShifts.length ? h('ul', { class: 'cal-list' }, selShifts.map(shiftItem)) : empty(canShifts && !data.notice ? 'Ei työvuoroja tänä päivänä.' : 'Ei työvuorotietoja.'),
      h('h3', { class: 'booking-h', text: `Varaukset (${selBk.length})` }), selBk.length ? h('ul', { class: 'cal-list' }, selBk.map(bookingItem)) : empty('Ei varauksia tänä päivänä.'));
    body.replaceChildren(...[data.notice ? h('p', { class: 'notice', role: 'status', text: data.notice }) : null, grid, detail].filter(Boolean));
    titleEl.textContent = state.mode === 'month'
      ? new Intl.DateTimeFormat('fi-FI', { timeZone: 'UTC', month: 'long', year: 'numeric' }).format(new Date(`${state.date.slice(0, 7)}-01T12:00:00Z`))
      : `Viikko ${isoWeek(rg.start)} · ${fmtLong(rg.start)} – ${fmtLong(addDays(rg.start, 6))}`;
    root.querySelectorAll('.cal-mode button').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.mode === state.mode)));
  }
  const shift = (n) => {
    if (state.mode === 'week') state.date = addDays(state.date, 7 * n);
    else { const d = new Date(`${state.date.slice(0, 7)}-01T12:00:00Z`); d.setUTCMonth(d.getUTCMonth() + n); state.date = d.toISOString().slice(0, 10); }
    state.sel = state.date; draw();
  };
  const titleEl = h('strong', { class: 'cal-title', 'aria-live': 'polite' });
  root.append(h('h1', { text: 'Kalenteri' }),
    h('div', { class: 'toolbar cal-bar' },
      h('button', { class: 'btn ghost', type: 'button', 'aria-label': 'Edellinen', onclick: () => shift(-1) }, '‹'), titleEl,
      h('button', { class: 'btn ghost', type: 'button', 'aria-label': 'Seuraava', onclick: () => shift(1) }, '›'),
      h('button', { class: 'btn ghost sm', type: 'button', onclick: () => { state.date = state.sel = todayHel(); draw(); } }, 'Tänään'),
      h('span', { class: 'cal-mode', role: 'group', 'aria-label': 'Näkymä' }, [['month', 'Kuukausi'], ['week', 'Viikko']].map(([m, l]) => h('button', { class: 'btn sm', type: 'button', 'data-mode': m, onclick: () => { state.mode = m; draw(); } }, l)))),
    h('p', { class: 'cal-legend' }, h('span', { class: 'chip shift', text: allShifts ? 'Työvuorot (kaikki)' : 'Työvuorot (omat)' }), ' ', h('span', { class: 'chip booking', text: 'Varaukset' })),
    body);
  await draw();
  return root;
}
