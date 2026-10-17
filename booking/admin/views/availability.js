// Hoitojen ja rituaalin saatavuus Uusi varaus -lomakkeella (admin_treatment_availability, koodarin ohje booking_25 §6).
// Näyttää saman tarjonnan kuin verkkosivu: päivät ja alkuajat. Vaatii bookings.manage; ylitys (p_override) vain bookings.override + perustelu ≥ 3 merkkiä.
// Haku on raskas (~0,3–1,7 s / 14 pv): ei pollausta; haetaan kun tuote, päivä, henkilömäärä tai ylitys vaihtuu; tulokset välimuistissa 3 min.
// Varaus tehdään lomakkeen kautta admin_create_resource_booking-funktiolla.
import { rpc } from '../sb.js';
import { h, errMsg, fmtTime, money, addDays, badge } from '../ui.js';

export const SLOT_PRODUCT_IDS = [8, 10, 11, 12];   // kb: rituaali 8, hoidot 10–12 (booking_kind = 'slots')
export const isSlotProduct = (p) => !!p && SLOT_PRODUCT_IDS.includes(p.id) && p.config?.lifecycle === 'current';
export const SPAN_DAYS = 14;
const TTL_MS = 3 * 60 * 1000;
const cache = new Map();   // avain → { at, rows }
export const clearAvailabilityCache = () => cache.clear();

const dayChip = (ds) => new Intl.DateTimeFormat('fi-FI', { weekday: 'short', day: 'numeric', month: 'numeric', timeZone: 'UTC' }).format(new Date(`${ds}T12:00:00Z`));
const dayLong = (ds) => new Intl.DateTimeFormat('fi-FI', { weekday: 'long', day: 'numeric', month: 'long', timeZone: 'UTC' }).format(new Date(`${ds}T12:00:00Z`));

// getQuery() → { productId, from (YYYY-MM-DD), persons, override, reason } tai null; onPick(slot | null) kertoo valinnan lomakkeelle.
export function availabilityPanel({ getQuery, onPick }) {
  const status = h('p', { class: 'muted', role: 'status', 'data-testid': 'avail-status' });
  const err = h('p', { class: 'avail-err', role: 'alert', hidden: true, 'data-testid': 'avail-error' });
  const days = h('div', { class: 'daychips', role: 'group', 'aria-label': 'Päivä' });
  const slots = h('div', { class: 'slotgrid', role: 'group', 'aria-label': 'Alkuajat', 'data-testid': 'slot-list' });
  const picked = h('p', { class: 'slot-picked', 'data-testid': 'slot-picked', hidden: true });
  const refreshBtn = h('button', { type: 'button', class: 'btn sm ghost', text: 'Päivitä', 'data-testid': 'avail-refresh', onclick: () => load(true) });
  const node = h('section', { class: 'box avail', 'data-testid': 'availability', 'aria-label': 'Vapaat ajat' },
    h('div', { class: 'row wrap avail-head' }, h('h3', { text: 'Vapaat ajat' }), refreshBtn),
    h('p', { class: 'muted', text: `Sama saatavuus kuin verkkosivulla (${SPAN_DAYS} pv valitusta päivästä). Valitse aika, niin päivä ja kellonaika täyttyvät lomakkeelle.` }),
    status, err, days, slots, picked);
  const st = { rows: [], day: null, sel: null, seq: 0 };

  function renderSlots() {
    const byDay = new Map();
    for (const r of st.rows) { if (!byDay.has(r.session_date)) byDay.set(r.session_date, []); byDay.get(r.session_date).push(r); }
    if (!byDay.has(st.day)) st.day = [...byDay.keys()][0] || null;
    days.replaceChildren(...[...byDay.keys()].map((d) => h('button', { type: 'button', class: 'btn daychip', 'aria-pressed': String(d === st.day), 'data-testid': 'day-chip', 'data-day': d, onclick: () => { st.day = d; renderSlots(); } },
      dayChip(d), h('span', { class: 'cnt', text: `\u00a0· ${byDay.get(d).length}` }))));
    slots.replaceChildren(...(byDay.get(st.day) || []).map((r) => {
      const on = st.sel === r.starts_at;
      return h('button', { type: 'button', class: `btn slot${r.needs_override ? ' needs-ovr' : ''}`, 'aria-pressed': String(on), 'data-testid': 'slot', 'data-start': r.starts_at,
        'aria-label': `${fmtTime(r.starts_at)}${r.therapist_missing ? ', ei saunottajaa' : ''}${r.needs_override ? ', vaatii ylityksen' : ''}`, onclick: () => pick(r) },
        h('strong', { text: fmtTime(r.starts_at) }), r.therapist_missing ? h('small', { class: 'sflag tm', text: 'Ei saunottajaa' }) : null, r.needs_override ? h('small', { class: 'sflag ov', text: 'Ylitys' }) : null);
    }));
    const r = st.rows.find((x) => x.starts_at === st.sel);
    picked.hidden = !r;
    if (r) picked.replaceChildren(...[h('strong', { text: `Valittu: ${dayLong(r.session_date)} klo ${fmtTime(r.starts_at)}–${fmtTime(r.ends_at)}` }), ` · ${r.persons} hlö${r.total != null ? ` · ${money(r.total)}` : ''}`,
      r.therapist_missing ? ' ' : null, r.therapist_missing ? badge('warn tmiss', 'Ei saunottajaa') : null, r.needs_override ? ' ' : null, r.needs_override ? badge('warn', 'Vaatii ylityksen') : null].filter(Boolean));
  }
  function pick(r) { st.sel = r.starts_at; onPick?.(r); renderSlots(); }
  const clearSelection = () => { if (st.sel) { st.sel = null; renderSlots(); } };

  async function load(force = false) {
    const q = getQuery();
    err.hidden = true;
    if (!q) { st.rows = []; days.replaceChildren(); slots.replaceChildren(); status.textContent = ''; picked.hidden = true; return; }
    const useOvr = !!q.override && (q.reason || '').trim().length >= 3;
    const from = q.from, to = addDays(from, SPAN_DAYS - 1);
    const args = { p_product_id: q.productId, p_from: from, p_to: to, p_persons: q.persons || 1, p_override: useOvr, p_override_reason: useOvr ? q.reason.trim() : null };
    const key = JSON.stringify(args); const my = ++st.seq;
    const hit = !force && cache.get(key);
    let rows;
    if (hit && Date.now() - hit.at < TTL_MS) rows = hit.rows;
    else {
      node.setAttribute('aria-busy', 'true'); refreshBtn.disabled = true; status.textContent = 'Haetaan vapaita aikoja…';
      try { rows = await rpc('admin_treatment_availability', args); cache.set(key, { at: Date.now(), rows }); }
      catch (e) { if (my !== st.seq) return; node.removeAttribute('aria-busy'); refreshBtn.disabled = false; st.rows = []; days.replaceChildren(); slots.replaceChildren(); picked.hidden = true; status.textContent = ''; err.textContent = `Saatavuutta ei saatu: ${errMsg(e).replace(/\.?$/, '.')} Voit silti syöttää ajan käsin alla.`; err.hidden = false; return; }
    }
    if (my !== st.seq) return;   // uudempi haku ehti mukaan
    node.removeAttribute('aria-busy'); refreshBtn.disabled = false;
    st.rows = (rows || []).filter((r) => r.status === 'available' || r.status == null);
    if (st.sel && !st.rows.some((r) => r.starts_at === st.sel)) st.sel = null;
    const ovrHint = q.override && !useOvr ? ' Ylitysajat haetaan kun perustelu (vähintään 3 merkkiä) on annettu.' : '';
    status.textContent = st.rows.length ? `${st.rows.length} aikaa, ${new Set(st.rows.map((r) => r.session_date)).size} päivänä${useOvr ? ' (ylitysajat mukana)' : ''}.${ovrHint}` : `Ei vapaita aikoja valitulla jaksolla (${dayChip(from)} – ${dayChip(to)}). Kokeile myöhempää päivää${useOvr ? '' : ' tai ylitystä'}.${ovrHint}`;
    st.day = st.rows.find((r) => r.session_date >= from)?.session_date || st.day;
    renderSlots();
  }
  return { node, load, clearSelection, get selected() { return st.rows.find((r) => r.starts_at === st.sel) || null; } };
}
