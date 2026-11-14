// Päivänäkymän osat: kapasiteettinappi (→ Uusi varaus esivalitulla vuorolla), saapunut-nappi (optimistinen), lisäpalveluikonit ja päivän työvuorot.
import { rpc } from '../sb.js';
import { icon } from '../icons.js';
import { h, toast, errMsg, dayStartIso, addDays } from '../ui.js';
import { roleLabel, shiftClass, NO_ASSIGNEE } from './calendar.js';
import { sessionFill } from '../day-logic.js';
import { dayText } from '../day-texts.js';
import { memoText } from '../day-memos-texts.js';
import { overflowMenu } from './overflow-menu.js';
import { confirmAsk } from '../confirm.js';
import { orderText } from '../orders-texts.js';
import { arrivalActionsAllowed } from '../reservation-dialog-logic.js';

// ---- vuorokortin otsikko: tyyppi tekstinä ja täyttöaste ----
// HALL-PAIVA-01: yleinen/yksityinen ei saa näkyä vain reunan värinä; yleisellä vuorolla "6/10" (varatut / enimmäishenkilömäärä, max_persons tulee admin_day_viewn sessions-riveiltä).
export { sessionFill };
export const sessionKindText = (mode) => dayText(mode === 'exclusive' ? 'ui.admin.day.kind_exclusive' : 'ui.admin.day.kind_shared');

// ---- kapasiteettinappi ----
// Vapaana-nappi vie suoraan Uusi varaus -lomakkeelle (päivä, vuoro ja alkamisaika esivalittuina: ?d=…&r=<rule_id>&t=<alkamisaika>).
// Täynnä / yksityisvuoro varattu = punainen, ei painike. Myymätön vuoro (päällekkäisyys, sulku) ei näytä nappia eikä "ei myynnissä" -tekstiä.
export const newBookingHref = (date, s) => `#/uusi?d=${date}&r=${s.rule_id}&t=${encodeURIComponent(s.starts_at)}`;
export function capacityButton(s, date, booked) {
  if (s.status === 'available') {
    const txt = s.mode === 'exclusive' ? 'Vapaa' : `Vapaana: ${s.remaining == null ? '' : Math.max(0, Number(s.remaining) || 0)}`;   // palvelimen poolilaskenta (sis. lahjakorttivaraukset); ei koskaan negatiivinen
    return h('a', { class: 'btn cap ok', href: newBookingHref(date, s), 'data-testid': 'cap-btn', 'aria-label': `${txt}. Uusi varaus klo ${new Date(s.starts_at).toLocaleTimeString('fi-FI', { timeZone: 'Europe/Helsinki', hour: '2-digit', minute: '2-digit' })}` }, txt);
  }
  if (s.status === 'full') return h('span', { class: 'btn cap full', role: 'status', 'data-testid': 'cap-full' }, s.mode === 'exclusive' ? 'Varattu' : 'Täynnä');
  if (s.mode === 'exclusive' && booked) return h('span', { class: 'btn cap full', role: 'status', 'data-testid': 'cap-full' }, 'Varattu');
  return null;
}

// ---- saapunut-nappi ----
// HALL-PAIVA-02: näkyvä "Saapui"-painike (rasti kun painettu), kiinteä aria-label + aria-pressed ("Saapunut, <nimi>, ei painettu"), tilamerkki "Saapunut".
// Käyttää admin_set_reservation_status: 'completed' = saapunut (asettaa checkin_at), takaisin 'confirmed'. Oikeus bookings.manage.
// "Ei saapunut" (no_show) on rivin ⋯-valikossa, sama vahvistus ja tekstit kuin tilausnäkymässä (HALL-TILAUS-01).
export const ARRIVE_STATES = ['pending', 'confirmed', 'completed'];
export const ARRIVE_LABEL = 'Saapui';
export const arriveAriaLabel = (r) => `Saapunut, ${r.customer_name || `#${r.order_no}`}`;
export function arrivalButton(r, { can, onState } = {}) {
  if (can && !can('bookings.manage')) return null;
  if (!ARRIVE_STATES.includes(r.status)) return null;
  const b = h('button', { type: 'button', class: 'arrive', 'data-testid': 'arrive', 'aria-label': arriveAriaLabel(r) }, h('span', { class: 'arrive-tick', 'aria-hidden': 'true' }, icon('tick', 18)), h('span', { class: 'arrive-txt', text: ARRIVE_LABEL }));
  const paint = () => { const on = r.status === 'completed'; b.setAttribute('aria-pressed', String(on)); b.title = on ? 'Saapunut (paina peruaksesi)' : 'Merkitse saapuneeksi'; b.classList.toggle('on', on); };
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

// Päivänäkymän saapumisalue: Saapui-painike + ⋯-valikko, jossa "Ei saapunut" (vahvistetulle varaukselle varauspäivästä alkaen).
export const NO_SHOW_LABEL = 'Ei saapunut…';
export function arrivalControls(r, { can, onState, now = new Date() } = {}) {
  const btn = arrivalButton(r, { can, onState: (st) => { renderMenu(); onState?.(st); } });
  if (!btn) return null;
  const wrap = h('div', { class: 'arrive-wrap', 'data-testid': 'arrive-wrap' }, btn);
  let menu = null;
  function renderMenu() {
    menu?.remove(); menu = null;
    if (!arrivalActionsAllowed(r, now)) return;
    menu = overflowMenu([['noShow', NO_SHOW_LABEL, async () => {
      if (!(await confirmAsk(orderText('ui.admin.res.no_show_text'), { title: orderText('ui.admin.res.no_show_title'), yes: orderText('ui.admin.res.no_show_submit') }))) return;
      try {
        await rpc('admin_set_reservation_status', { p_reservation_id: r.reservation_id, p_status: 'no_show', p_reason: null });
        r.status = 'no_show'; toast('Merkitty: ei saapunut'); onState?.(r.status); wrap.remove();   // tila ei ole enää saapumismerkittävä
      } catch (e) { toast(errMsg(e), 'err'); }
    }]], `Lisätoiminnot: ${r.customer_name || `#${r.order_no}`}`, 'arrive-more', { prefer: 'end' });
    wrap.append(menu);
  }
  renderMenu();
  return wrap;
}

// ---- lisäpalveluikonit ----
// Tunnistus: 1) koodi (a.code, jos admin_day_view antaa sen), 2) koodi lisäpalvelulistasta addon_id:n perusteella (codes: Map id → code, admin_list_addons), 3) nimi.
// Yhdistetty "Turvenaamio ja jalkakylpy" saa molemmat ikonit (naamio + jalkakylpy). Tuntematon lisäpalvelu = lehti.
const KINDS = [[/vihta/i, 'whisk', 'Saunavihta'], [/turvenaamio/i, 'mask', 'Turvenaamio'], [/jalkakylpy/i, 'foot', 'Jalkakylpy'], [/pyyhe|towel/i, 'towel', 'Pyyhe']];
export function addonKinds(a, codes) {
  const key = `${a.code || ''} ${(codes && codes.get(a.addon_id ?? a.id)) || ''} ${a.name || ''}`;
  const ks = KINDS.filter(([re]) => re.test(key)).map(([, ic, label]) => ({ icon: ic, label }));
  return ks.length ? ks : [{ icon: 'leaf', label: a.name || 'Lisäpalvelu' }];
}
export const addonKind = (a, codes) => addonKinds(a, codes)[0];
const lc = (n) => (n ? n.charAt(0).toLowerCase() + n.slice(1) : n);
export const addonItems = (items, codes) => h('span', { class: 'addon-items', 'data-testid': 'addon-items' }, items.map((i) => { const ks = addonKinds(i, codes);
  return h('span', { class: `addon-item k-${ks[0].icon}`, title: ks.map((k) => k.label).join(' + '), 'data-kind': ks.map((k) => k.icon).join(' ') }, ks.map((k) => icon(k.icon, 20)), ` ${i.quantity} × ${lc(i.name)}`); }));

// ---- Valmistelu: päivän yhteenvetokortti (oma osio varausten yläpuolella) ----
// totals = admin_day_view.addon_totals [{addon_id, name, quantity}], prep = admin_day_view.prep [{starts_at, ends_at, product_name, items}], persons = päivän aktiiviset henkilöt.
export function prepCard({ totals, prep, persons, bookings, codes }) {
  const tile = (iconNames, n, label, extra) => h('li', { class: `prep-tile ${extra || ''}` }, h('span', { class: 'pt-icons' }, iconNames.map((x) => icon(x, 28))), h('strong', { class: 'pt-n', text: String(n) }), h('span', { class: 'pt-l', text: label }));
  const tiles = [tile(['users'], persons, persons === 1 ? 'henkilö' : 'henkilöä', 'persons')];
  for (const t of totals || []) { const ks = addonKinds(t, codes); tiles.push(tile(ks.map((k) => k.icon), t.quantity, lc(t.name), `k-${ks[0].icon}`)); }
  const rows = (prep || []).map((p) => h('li', {}, h('strong', { text: `${hh(p.starts_at)}–${hh(p.ends_at)}` }), ` ${p.product_name}: `, (p.items || []).map((i) => `${i.quantity} × ${lc(i.name)}`).join(', ')));
  return h('section', { class: 'prepcard', 'aria-labelledby': 'prep-h', 'data-testid': 'prepcard' },
    h('h2', { id: 'prep-h' }, icon('leaf', 20), ' Valmistelu'),
    h('ul', { class: 'prep-tiles' }, tiles),
    (totals || []).length ? null : h('p', { class: 'muted prep-none' }, bookings ? 'Ei tilattuja lisäpalveluita tälle päivälle.' : 'Ei varauksia eikä valmisteltavaa.'),
    rows.length ? h('ul', { class: 'prep-rows', 'aria-label': 'Valmistelu aloitusajoittain' }, rows) : null);
}

// ---- päivän työvuorot ----
const hh = (iso) => { const p = new Intl.DateTimeFormat('fi-FI', { timeZone: 'Europe/Helsinki', hour: 'numeric', minute: '2-digit', hourCycle: 'h23' }).formatToParts(new Date(iso)); const H = p.find((x) => x.type === 'hour').value, M = p.find((x) => x.type === 'minute').value; return M === '00' ? H : `${H}:${M}`; };
export const shiftLine = (s) => `${roleLabel(s)} ${hh(s.starts_at)}–${hh(s.ends_at)} ${s.names.length ? s.names.join(', ') : NO_ASSIGNEE.toLowerCase()}`;
// Työvuorot: ensisijaisesti admin_day_shifts(p_date) (kaikille henkilöstöroolille, ei vaadi shifts.*-oikeutta; ks. docs/bottiavustus-pyynto-pyyhe.md kohta 8),
// muuten admin_upcoming_shifts (shifts.view_all = kaikki, shifts.view = vain omat). Jos kumpikaan ei onnistu, näytetään selitys (ei hiljaista katoamista).
let dayShiftsMissing = 0;   // aikaleima: funktiota ei ollut (ennen migraatiota 27) → ei kokeilla uudelleen minuuttiin (säästää 404-kutsut)
async function loadShifts(date, can) {
  const from = dayStartIso(date), to = dayStartIso(addDays(date, 1));
  if (Date.now() - dayShiftsMissing > 60000) { try { return { rows: await rpc('admin_day_shifts', { p_date: date }), scope: 'all' }; } catch { dayShiftsMissing = Date.now(); /* funktiota ei vielä ole → vanha polku */ } }
  if (!(can('shifts.view') || can('shifts.view_all'))) return { rows: null, why: 'Työvuorot eivät näy tällä tunnuksella (oikeus shifts.view puuttuu).' };
  try { return { rows: await rpc('admin_upcoming_shifts', { p_from: from, p_to: to }), scope: can('shifts.view_all') ? 'all' : 'own' }; }
  catch { return { rows: null, why: 'Työvuoroja ei saatu haettua.' }; }
}
export async function shiftsBar(date, can, preloaded = null) {
  // preloaded vain kun rivit ovat admin_day_shifts-tulosta (scope 'all', kuten loadShiftsin onnistunut polku).
  // Muuten haetaan itse: ilman admin_day_shifts-funktiota scope on shifts.view_all → all, shifts.view → own.
  const loaded = preloaded && Array.isArray(preloaded.rows) ? preloaded : await loadShifts(date, can);
  const { rows: loadedRows, scope, why } = loaded;
  if (!loadedRows) return h('p', { class: 'muted dayshifts-none', 'data-testid': 'dayshifts' }, why);
  const byId = new Map();
  for (const r of loadedRows) { const x = byId.get(r.shift_id) || { ...r, names: [] }; if (r.staff_name) x.names.push(r.staff_name); byId.set(r.shift_id, x); }
  const shifts = [...byId.values()].sort((a, c) => a.starts_at.localeCompare(c.starts_at));
  if (!shifts.length) return h('p', { class: 'muted dayshifts-none', 'data-testid': 'dayshifts' }, memoText('ui.admin.day_memos.shifts_none'));
  return h('section', { class: 'dayshifts', 'aria-label': 'Työvuorot', 'data-testid': 'dayshifts' },
    h('ul', {}, shifts.map((s) => h('li', { class: `dshift ${shiftClass(s)}`, 'data-testid': 'dayshift' }, h('strong', { text: roleLabel(s) }), ` ${hh(s.starts_at)}–${hh(s.ends_at)} `, h('span', { class: 'who', text: s.names.length ? s.names.join(', ') : NO_ASSIGNEE.toLowerCase() })))),
    scope === 'own' ? h('p', { class: 'muted dayshifts-note' }, 'Näytetään vain omat vuorosi (muiden vuorot vaativat oikeuden shifts.view_all).') : null);
}
