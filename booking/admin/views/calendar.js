// Kalenteri: kuukausi- ja viikkonäkymä, jossa työvuorot (admin_upcoming_shifts, vain luku) ja varaukset (admin_list_reservations) eri väreillä.
// Näkyvyys määräytyy oikeuksista tietokannassa: admin/manager (shifts.view_all) näkevät kaikki vuorot, staff (shifts.view) vain omansa (linkitys työntekijään).
// Jos vuorotietoja ei saada (public-skeema tyhjä / ei oikeutta), varaukset näytetään silti ja näytetään ystävällinen huomautus.
// Koulutukset ja niiden tilavaraukset: admin_event_list('training', menneet mukana) kerran näkymää kohden (sama data kuin Koulutukset-työkalussa).
// Jos haku epäonnistuu, muu kalenteri näytetään ja koulutuksista kerrotaan huomautuksella. Suodattimet: Työvuorot, Varaukset, Koulutukset (oletuksena kaikki päällä).
import { rpc } from '../sb.js';
import { h, fmtTime, todayHel, addDays, dayStartIso, errMsg, statusBadge, badge, empty } from '../ui.js';
import { reservationDialog } from './shared.js';
import { openOrderView } from '../order-open.js';
import { loadTrainingTexts, trainingText as T } from '../training-texts.js';
import { calendarSpaceDays, calendarTrainingDays, withoutTrainingBlocks } from '../training-logic.js';
import { getLang } from '../talous-i18n.js';

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
  await loadTrainingTexts(rpc);
  const canShifts = ctx.can('shifts.view') || ctx.can('shifts.view_all');
  const allShifts = ctx.can('shifts.view_all');
  const state = { mode: 'month', date: todayHel(), sel: todayHel(), show: { shift: true, booking: true, training: true } };
  let trainingsP = null;   // välimuisti: koulutuslista ei riipu näytetystä aikavälistä
  const loadTrainings = () => (trainingsP ||= rpc('admin_event_list', { p_category: 'training', p_include_past: true })
    .then((rows) => ({ rows: Array.isArray(rows) ? rows : [], failed: false }))
    .catch(() => { trainingsP = null; return { rows: [], failed: true }; }));
  const root = h('div', { class: 'cal' });
  const body = h('div', { class: 'cal-body' });

  const rangeOf = () => {
    if (state.mode === 'week') { const s = addDays(state.date, -dowMon(state.date)); return { start: s, days: 7 }; }
    const first = `${state.date.slice(0, 7)}-01`; return { start: addDays(first, -dowMon(first)), days: 42 };
  };
  async function load({ start, days }) {
    const from = dayStartIso(start), to = dayStartIso(addDays(start, days));
    const out = { bookings: [], shifts: [], blocks: [], trainings: [], notice: null };
    const bk = (async () => { let all = [], off = 0; for (;;) { const rows = await rpc('admin_list_reservations', { p_from: from, p_to: to, p_status: 'active', p_limit: 500, p_offset: off }); all = all.concat(rows || []); if (!rows || rows.length < 500 || off >= 1000) break; off += 500; } return all; })();
    const sh = canShifts ? rpc('admin_upcoming_shifts', { p_from: from, p_to: to }).catch((e) => { out.notice = `Työvuorotietoja ei saatu haettua (${errMsg(e)}). Varaukset näytetään silti.`; return []; }) : Promise.resolve([]);
    if (!canShifts) out.notice = 'Sinulla ei ole oikeutta nähdä työvuoroja; näytetään vain varaukset.';
    const bl = rpc('admin_calendar_space_blocks', { p_from: from, p_to: to }).catch(() => { out.notice = [out.notice, T('unavailable')].filter(Boolean).join(' '); return []; });
    const tr = state.show.training ? loadTrainings() : Promise.resolve({ rows: [], failed: false });
    const [b, s, blocks, trs] = await Promise.all([bk, sh, bl, tr]);
    out.trainings = trs.rows;
    if (trs.failed) out.notice = [out.notice, T('cal_unavailable')].filter(Boolean).join(' ');
    out.blocks = state.show.training ? withoutTrainingBlocks(blocks || [], out.trainings) : (blocks || []);
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
    h('button', { type: 'button', class: 'link cal-txt', onclick: () => openOrderView(r.order_no) || reservationDialog(r, { methods: refs.methods, onChange: () => draw(), refs, can: ctx?.can, role: ctx?.role }) }, h('strong', { text: r.customer_name || '–' }), ` · ${r.persons} hlö`, h('br'), h('small', { text: r.product_name || '' })),
    statusBadge(r.status));

  const spanTxt = (t) => `${fmtTime(t.starts_at)}–${fmtTime(t.ends_at)}`;
  const trainingSpacesTxt = (t) => t.space_names.join(', ');
  const spaceMini = (n) => (n === 'Savusauna' ? 'Savu' : n);   // kapea kuukausiruutu (mobiili)
  // Viikkonäkymän ja päivän yksityiskohtien rivi: nimi, tila(t) kellonaikoineen, linkki Koulutukset-työkaluun (vain yksityiskohdissa).
  const trainingItem = (t, { detail = false } = {}) => h('li', { class: 'cal-item training', 'data-kind': 'training' },
    h('span', { class: 'cal-time', text: t.spaces.length ? spanTxt(t.spaces[0]) : '' }),
    h('span', { class: 'cal-txt' }, h('strong', { text: t.name }),
      detail && t.labels.length ? [h('br'), h('small', { text: `${T('cal_session')}: ${t.labels.join(' · ')}` })] : null,
      detail
        ? h('ul', { class: 'cal-train-spaces' }, t.spaces.length ? t.spaces.map((sp) => h('li', { text: `${spanTxt(sp)} · ${sp.name}` })) : h('li', { class: 'muted', text: T('cal_no_space') }))
        : (t.spaces.length ? [h('br'), h('span', { text: t.spaces.length === 1 ? t.spaces[0].name : t.spaces.map((sp) => `${sp.name} ${spanTxt(sp)}`).join(', ') })] : null),
      detail ? [h('br'), h('a', { class: 'btn sm ghost cal-train-link', href: t.href, text: T('cal_open') })] : null));
  const blockItem = b => h('li', { class: 'cal-item training-cal-block', 'data-kind': 'space-block' }, h('strong', { text: b.space_name }), h('span', { text: `${fmtTime(b.starts_at)}–${fmtTime(b.ends_at)} · ${b.reason || T('spaces_ok')}` }));

  async function draw() {
    const rg = rangeOf();
    body.replaceChildren(h('p', { class: 'muted pad', text: 'Ladataan…' }));
    let data;
    try { data = await load(rg); } catch (e) { body.replaceChildren(h('p', { class: 'err pad', role: 'alert', text: errMsg(e) })); return; }
    const sh = state.show.shift ? group(data.shifts, 'starts_at') : new Map(), bk = state.show.booking ? group(data.bookings, 'starts_at') : new Map();
    const tdays = state.show.training ? calendarTrainingDays(data.trainings, rg.start, addDays(rg.start, rg.days), { lang: getLang() }) : new Map();
    const blocked = calendarSpaceDays(data.blocks, rg.start, addDays(rg.start, rg.days));
    const today = todayHel();
    // Koko päiväruutu avaa saman päivän kuin päivänumeron painike. Painike peittää ruudun (näppäimistö, Enter/Space, aria-label).
    // Viikon varauslinkki on ruudun päällä ja tekee vain oman toimintonsa: se ei vaihda valittua päivää.
    const openDay = (ds) => { state.sel = ds; draw(); };
    const hitControl = (ev) => {
      const raw = ev.target?.nodeType === 1 ? ev.target : (ev.target?.parentElement || ev.target?.parent);
      return raw?.closest?.('a, button, input, select, textarea, summary') || null;
    };
    const dayCell = (ds, inMonth) => {
      const ns = (sh.get(ds) || []).length, nb = (bk.get(ds) || []), nt = tdays.get(ds) || [];
      const persons = nb.reduce((a, r) => a + (r.persons || 0), 0);
      const items = state.mode === 'week'
        ? h('ul', { class: 'cal-list' }, ...nt.map((t) => trainingItem(t)), ...(sh.get(ds) || []).map(shiftItem), ...nb.slice().sort((a, c) => a.starts_at.localeCompare(c.starts_at)).map(bookingItem), ...(blocked.get(ds) || []).map(blockItem))
        : h('span', { class: 'cal-chips' }, ns ? h('span', { class: 'chip shift', title: `${ns} työvuoroa` }, h('b', { text: String(ns) }), h('span', { class: 'lbl', text: ' vuoroa' })) : null, nb.length ? h('span', { class: 'chip booking', title: `${nb.length} varausta, ${persons} henkilöä` }, h('b', { text: String(nb.length) }), h('span', { class: 'lbl', text: ` var. · ${persons} hlö` })) : null);
      if (state.mode === 'month') for (const t of nt) items.append(h('span', { class: 'chip training', title: [t.name, trainingSpacesTxt(t)].filter(Boolean).join(' · ') }, h('span', { class: `tn${t.space_names.length ? ' has-space' : ''}`, text: t.name }), t.space_names.length ? [h('span', { class: 'ts', text: trainingSpacesTxt(t) }), h('span', { class: 'tsm', 'aria-hidden': 'true', text: t.space_names.map(spaceMini).join(' ') })] : null));
      const blockCount = (blocked.get(ds) || []).length;
      if (blockCount && state.mode === 'month') items.append(h('span', { class: 'chip training-cal-block', text: `${T('spaces')}: ${blockCount}` }));
      const label = `${fmtLong(ds)}: ${ns} työvuoroa, ${nb.length} varausta, ${T('spaces')}: ${blockCount}${nt.length ? `, ${T('cal_heading')}: ${nt.map((t) => [t.name, trainingSpacesTxt(t)].filter(Boolean).join(' – ')).join('; ')}` : ''}`;
      const opener = h('button', {
        type: 'button', class: 'cal-dnum', 'aria-label': label, 'aria-pressed': ds === state.sel ? 'true' : 'false',
        onclick: (ev) => { ev.stopPropagation(); openDay(ds); },
        onkeydown: (ev) => {
          if (ev.key !== 'Enter' && ev.key !== ' ' && ev.key !== 'Spacebar') return;
          ev.preventDefault();
          ev.stopPropagation();
          openDay(ds);
        },
      });
      return h('div', {
        class: `cal-day${inMonth ? '' : ' out'}${ds === today ? ' today' : ''}${ds === state.sel ? ' sel' : ''}`,
        'data-date': ds,
        onclick: (ev) => { if (hitControl(ev)) return; openDay(ds); },
      }, opener, h('div', { class: 'cal-day-face' },
        h('span', { class: 'cal-num', 'aria-hidden': 'true' }, h('span', { class: 'wd', text: WD[dowMon(ds)] }), h('span', { class: 'n', text: String(+ds.slice(8)) })),
        items));
    };
    const cells = Array.from({ length: rg.days }, (_, i) => addDays(rg.start, i));
    const grid = h('div', { class: `cal-grid ${state.mode}` },
      state.mode === 'month' ? WD.map((w) => h('div', { class: 'cal-head', text: w })) : null,
      cells.map((ds) => dayCell(ds, state.mode === 'week' || ds.slice(0, 7) === state.date.slice(0, 7))));
    const selShifts = sh.get(state.sel) || [], selBk = (bk.get(state.sel) || []).slice().sort((a, c) => a.starts_at.localeCompare(c.starts_at));
    const selTr = tdays.get(state.sel) || [];
    const detail = h('section', { class: 'cal-detail card', 'aria-live': 'polite' }, h('h2', { text: fmtLong(state.sel) }),
      state.show.training ? [h('h3', { class: 'training-h', text: `${T('cal_heading')} (${selTr.length})` }), selTr.length ? h('ul', { class: 'cal-list', 'data-testid': 'calendar-trainings' }, selTr.map((t) => trainingItem(t, { detail: true }))) : empty(T('cal_none'))] : null,
      state.show.shift ? [h('h3', { class: 'shift-h', text: `Työvuorot (${selShifts.length})` }), selShifts.length ? h('ul', { class: 'cal-list' }, selShifts.map(shiftItem)) : empty(canShifts && !data.notice ? 'Ei työvuoroja tänä päivänä.' : 'Ei työvuorotietoja.')] : null,
      state.show.booking ? [h('h3', { class: 'booking-h', text: `Varaukset (${selBk.length})` }), selBk.length ? h('ul', { class: 'cal-list' }, selBk.map(bookingItem)) : empty('Ei varauksia tänä päivänä.')] : null,
      h('h3', { text: T('spaces') }), (blocked.get(state.sel) || []).length ? h('ul', { class: 'cal-list', 'data-testid': 'calendar-space-blocks' }, blocked.get(state.sel).map(blockItem)) : empty(T('none_spaces')));
    body.replaceChildren(...[data.notice ? h('p', { class: 'notice', role: 'status', text: data.notice }) : null, grid, detail].filter(Boolean));
    titleEl.textContent = state.mode === 'month'
      ? new Intl.DateTimeFormat('fi-FI', { timeZone: 'UTC', month: 'long', year: 'numeric' }).format(new Date(`${state.date.slice(0, 7)}-01T12:00:00Z`))
      : `Viikko ${isoWeek(rg.start)} · ${fmtLong(rg.start)} – ${fmtLong(addDays(rg.start, 6))}`;
    root.querySelectorAll('.cal-mode button').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.mode === state.mode)));
    root.querySelectorAll('.cal-legend button[data-filter]').forEach((b) => b.setAttribute('aria-pressed', String(!!state.show[b.dataset.filter])));
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
    h('p', { class: 'cal-legend', role: 'group', 'aria-label': T('cal_filters') }, [['shift', allShifts ? 'Työvuorot (kaikki)' : 'Työvuorot (omat)'], ['booking', 'Varaukset'], ['training', T('cal_filter')]].map(([k, l]) =>
      [h('button', { type: 'button', class: `chip ${k} cal-filter`, 'data-filter': k, 'aria-pressed': 'true', text: l, onclick: () => { state.show[k] = !state.show[k]; draw(); } }), ' '])),
    body);
  await draw();
  return root;
}
