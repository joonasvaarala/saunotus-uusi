// Päivänäkymän osat: kapasiteettinappi (→ Uusi varaus esivalitulla vuorolla), saapunut-nappi (optimistinen), lisäpalveluikonit ja päivän työvuorot.
import { rpc } from '../sb.js';
import { icon } from '../icons.js';
import { h, toast, errMsg, dayStartIso, addDays } from '../ui.js';
import { roleLabel, shiftClass, NO_ASSIGNEE } from './calendar.js';

// ---- kapasiteettinappi ----
// Vapaana-nappi vie suoraan Uusi varaus -lomakkeelle (päivä, vuoro ja alkamisaika esivalittuina: ?d=…&r=<rule_id>&t=<alkamisaika>).
// Täynnä / yksityisvuoro varattu = punainen, ei painike. Myymätön vuoro (päällekkäisyys, sulku) ei näytä nappia eikä "ei myynnissä" -tekstiä.
export const newBookingHref = (date, s) => `#/uusi?d=${date}&r=${s.rule_id}&t=${encodeURIComponent(s.starts_at)}`;
export function capacityButton(s, date, booked) {
  if (s.status === 'available') {
    const txt = s.mode === 'exclusive' ? 'Vapaa' : `Vapaana: ${s.remaining}`;
    return h('a', { class: 'btn cap ok', href: newBookingHref(date, s), 'data-testid': 'cap-btn', 'aria-label': `${txt}. Uusi varaus klo ${new Date(s.starts_at).toLocaleTimeString('fi-FI', { timeZone: 'Europe/Helsinki', hour: '2-digit', minute: '2-digit' })}` }, txt);
  }
  if (s.status === 'full') return h('span', { class: 'btn cap full', role: 'status', 'data-testid': 'cap-full' }, s.mode === 'exclusive' ? 'Varattu' : 'Täynnä');
  if (s.mode === 'exclusive' && booked) return h('span', { class: 'btn cap full', role: 'status', 'data-testid': 'cap-full' }, 'Varattu');
  return null;
}

// ---- saapunut-nappi ----
// Käyttää admin_set_reservation_status: 'completed' = saapunut (asettaa checkin_at), takaisin 'confirmed'. Oikeus bookings.manage.
export const ARRIVE_STATES = ['pending', 'confirmed', 'completed'];
export function arrivalButton(r, { can, onState } = {}) {
  if (can && !can('bookings.manage')) return null;
  if (!ARRIVE_STATES.includes(r.status)) return null;
  const name = r.customer_name || `#${r.order_no}`;
  const b = h('button', { type: 'button', class: 'arrive', 'data-testid': 'arrive' }, icon('tick', 22));
  const paint = () => { const on = r.status === 'completed'; b.setAttribute('aria-pressed', String(on)); b.setAttribute('aria-label', on ? `Saapunut: ${name}` : `Merkitse saapuneeksi: ${name}`); b.title = on ? 'Saapunut (paina peruaksesi)' : 'Merkitse saapuneeksi'; b.classList.toggle('on', on); };
  paint();
  let busy = false;
  b.addEventListener('click', async () => {
    if (busy) return; busy = true; b.setAttribute('aria-busy', 'true');
    const prev = r.status; r.status = prev === 'completed' ? 'confirmed' : 'completed'; paint(); onState?.(r.status);   // optimistinen päivitys
    try { await rpc('admin_set_reservation_status', { p_reservation_id: r.reservation_id, p_status: r.status, p_reason: null }); }
    catch (e) { r.status = prev; paint(); onState?.(r.status); toast(`Saapumisen kirjaus epäonnistui: ${errMsg(e)}`, 'err'); }
    finally { busy = false; b.removeAttribute('aria-busy'); }
  });
  return b;
}

// ---- lisäpalveluikonit ----
// Tunnistus koodista (jos admin_day_view antaa sen) tai nimestä: saunavihta, turvenaamio (myös "Turvenaamio ja jalkakylpy"), pyyhe; muut = lehti.
const KINDS = [[/vihta/i, 'whisk', 'Saunavihta'], [/turvenaamio/i, 'mask', 'Turvenaamio'], [/pyyhe|towel/i, 'towel', 'Pyyhe']];
export function addonKind(a) { const k = KINDS.find(([re]) => re.test(`${a.code || ''} ${a.name || ''}`)); return k ? { icon: k[1], label: k[2] } : { icon: 'leaf', label: a.name || 'Lisäpalvelu' }; }
const lc = (n) => (n ? n.charAt(0).toLowerCase() + n.slice(1) : n);
export const addonItems = (items) => h('span', { class: 'addon-items', 'data-testid': 'addon-items' }, items.map((i) => { const k = addonKind(i); return h('span', { class: `addon-item k-${k.icon}`, title: k.label, 'data-kind': k.icon }, icon(k.icon, 18), ` ${i.quantity} × ${lc(i.name)}`); }));

// ---- päivän työvuorot ----
const hh = (iso) => { const p = new Intl.DateTimeFormat('fi-FI', { timeZone: 'Europe/Helsinki', hour: 'numeric', minute: '2-digit', hourCycle: 'h23' }).formatToParts(new Date(iso)); const H = p.find((x) => x.type === 'hour').value, M = p.find((x) => x.type === 'minute').value; return M === '00' ? H : `${H}:${M}`; };
export const shiftLine = (s) => `${roleLabel(s)} ${hh(s.starts_at)}–${hh(s.ends_at)} ${s.names.length ? s.names.join(', ') : NO_ASSIGNEE.toLowerCase()}`;
export async function shiftsBar(date, can) {
  if (!(can('shifts.view') || can('shifts.view_all'))) return null;
  let rows;
  try { rows = await rpc('admin_upcoming_shifts', { p_from: dayStartIso(date), p_to: dayStartIso(addDays(date, 1)) }); } catch { return null; }   // tieto puuttuu tai ei oikeutta → ei palkkia (varaukset näytetään silti)
  const byId = new Map();
  for (const r of rows || []) { const x = byId.get(r.shift_id) || { ...r, names: [] }; if (r.staff_name) x.names.push(r.staff_name); byId.set(r.shift_id, x); }
  const shifts = [...byId.values()].sort((a, c) => a.starts_at.localeCompare(c.starts_at));
  if (!shifts.length) return h('p', { class: 'muted dayshifts-none', 'data-testid': 'dayshifts' }, 'Ei työvuoroja.');
  return h('section', { class: 'dayshifts', 'aria-label': 'Työvuorot', 'data-testid': 'dayshifts' },
    h('ul', {}, shifts.map((s) => h('li', { class: `dshift ${shiftClass(s)}`, 'data-testid': 'dayshift' }, h('strong', { text: roleLabel(s) }), ` ${hh(s.starts_at)}–${hh(s.ends_at)} `, h('span', { class: 'who', text: s.names.length ? s.names.join(', ') : NO_ASSIGNEE.toLowerCase() })))));
}
