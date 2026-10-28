// Päivänäkymä: vuorot kapasiteetteineen + varaukset vuoroittain + tapahtumat osallistujineen + päivän tuotto + sulut.
import { rpc } from '../sb.js';
import { h, fmtDay, fmtTime, todayHel, addDays, dayStartIso, statusBadge, payBadge, sourceBadge, badge, toast, run, dialog, field, fmtDT, empty, money } from '../ui.js';
import { reservationDialog } from './shared.js';
import { icon } from '../icons.js';
import { capacityButton, arrivalButton, addonItems, shiftsBar, prepCard } from './dayparts.js';
import { legsList, resourceBadges, spaceBadge } from './legs.js';
import { optionBadge, optionReminder } from '../options.js';
import { blockList, blockDialog } from './blocks.js';
import { assignDayCards, canSeeDayRevenue, eventSortIso, eventTimeLabel, revenueView, isGiftCardReservation, slotTitle, sumPersons } from '../day-logic.js';
import { dayLang, dayText, loadDayTexts } from '../day-texts.js';
import { bulletinCard, dayNotesCard, loadDayMemos } from './day-memos.js';
import { loadMemoTexts, memoText } from '../day-memos-texts.js';
import { cachedDayBundle, seedDayBundle, clearDayBundles } from '../day-bundle-cache.js';

// Tiedotteet ja päivän muistiinpanot: toistaiseksi pois päivänäkymästä.
// Palauta käyttöön vaihtamalla false → true (yksi tai molemmat). Kortteja ei piirretä eikä
// admin_list_day_notes-kutsua tehdä, kun lippu on false. Koodi, taulut ja RPC:t säilyvät.
export const DAY_VIEW_SHOW_ANNOUNCEMENTS = false;
export const DAY_VIEW_SHOW_DAY_NOTES = false;

// Vanha kanta / väärällä allekirjoituksella julkaistu bundle: 42883, PGRST202 -> varapolku 60 s.
let bundleMissing = 0;
function rpcMissing(e) {
  const msg = `${e?.status || ''} ${e?.code || ''} ${e?.message || ''}`;
  return e?.status === 404 || /42883|PGRST202|could not find the function|function .* does not exist|schema cache/i.test(msg);
}
async function loadBundle(date) {
  if (Date.now() - bundleMissing < 60000) return null;
  try {
    const bundle = await cachedDayBundle(date, (d) => rpc('admin_day_bundle', { p_date: d }));
    return bundle && typeof bundle === 'object' ? bundle : null;
  } catch (e) {
    if (rpcMissing(e)) bundleMissing = Date.now();
    return null;
  }
}
export const primeDayBundle = (date, bundle) => seedDayBundle(date, bundle);
export const rememberDayBundleError = (e) => { if (rpcMissing(e)) bundleMissing = Date.now(); };
export const clearDayBundleCache = () => { clearDayBundles(); bundleMissing = 0; };
export const prefetchAdjacentDay = (date) => {
  if (Date.now() - bundleMissing < 60000) return;
  for (const d of [addDays(date, -1), addDays(date, 1)]) {
    void loadBundle(d);  // errors swallowed by loadBundle; no forced redraw
  }
};
// admin_day_extras puuttuu kunnes migraatio booking_68 on ajettu: näytä selite, älä kaada päivänäkymää. 404:ää ei toisteta minuuttiin.
let extrasMissing = 0;
async function loadExtras(date) {
  if (Date.now() - extrasMissing < 60000) return null;
  try { return await rpc('admin_day_extras', { p_date: date }); }
  catch (e) { if (rpcMissing(e)) extrasMissing = Date.now(); return null; }
}
// Tuotto on erillinen pyyntö (booking_69). Sitä ei kutsuta eikä korttia piirretä muille kuin adminille ja managerille.
// 404: funktiota ei ole vielä ajettu → ylläpitäjä voi käyttää booking_68:n lukuja extras-vastauksesta, kunnes migraatio on kannassa.
let revenueMissing = 0;
async function loadRevenue(date) {
  if (Date.now() - revenueMissing < 60000) return undefined;
  try { return await rpc('admin_day_revenue', { p_date: date }); }
  catch (e) {
    if (rpcMissing(e)) { revenueMissing = Date.now(); return undefined; }
    return null;
  }
}

export async function render({ ctx, refs, reload, query }) {
  const date = /^\d{4}-\d\d-\d\d$/.test(query.get('d') || '') ? query.get('d') : todayHel();
  const seeMoney = canSeeDayRevenue(ctx.role);
  const bundle = await loadBundle(date);
  let view, resv, addonList, optNote, extras, revenueRpc;
  if (bundle) {
    view = bundle.view || { sessions: [], reservations: [], blocks: [], addon_totals: [], prep: [] };
    resv = bundle.reservations || [];
    addonList = bundle.addons || [];   // lisäpalvelun koodi addon_id:llä (ikonin tunnistus, jos admin_day_view ei anna code-kenttää)
    optNote = await optionReminder(Array.isArray(bundle.options) ? bundle.options : null, bundle.site_texts?.texts || []);
    extras = bundle.extras;   // tapahtumat + tuotto (admin/manager; muilla revenue = null)
    revenueRpc = undefined;   // extras sisältää tuoton; erillistä admin_day_revenue-kutsua ei tarvita
    await loadDayTexts(rpc, Array.isArray(bundle.site_texts?.texts) ? bundle.site_texts.texts : null);
    await loadMemoTexts(rpc, Array.isArray(bundle.site_texts?.texts) ? bundle.site_texts.texts : null);
  } else {
    [view, resv, addonList, optNote, extras, revenueRpc] = await Promise.all([
      rpc('admin_day_view', { p_date: date }),
      rpc('admin_list_reservations', { p_from: dayStartIso(date), p_to: dayStartIso(addDays(date, 1)), p_limit: 200 }),
      rpc('admin_list_addons').catch(() => []),
      optionReminder(),
      loadExtras(date),   // tapahtumat (ja booking_68:ssa myös tuotto); null jos funktiota ei vielä ole
      seeMoney ? loadRevenue(date) : null,   // tuottoluvut vain admin/manager; muille ei pyyntöä
      loadDayTexts(rpc),  // ui.admin.day.* site_texts; epäonnistuminen jättää sanakirjan
      loadMemoTexts(rpc),  // ui.admin.day_memos.* (booking_140)
    ]);
  }
  // Nipun työvuorot tulevat admin_day_shifts-funktiosta (kaikille henkilöstölle, scope all).
  // Ilman nippua shiftsBar hakee itse: admin_day_shifts tai oikeuden mukainen admin_upcoming_shifts (own/all).
  const shifts = await shiftsBar(date, ctx.can, bundle && Array.isArray(bundle.shifts) ? { rows: bundle.shifts, scope: 'all', why: null } : null);
  // booking_140: nippu tuo notes_bundle-kentän; vanha nippu (ilman kenttää) → erillinen admin_list_day_notes.
  // Molemmat liput pois → ei kortteja eikä erillistä hakua (nipun notes_bundle jätetään käyttämättä).
  const memos = (DAY_VIEW_SHOW_ANNOUNCEMENTS || DAY_VIEW_SHOW_DAY_NOTES)
    ? await loadDayMemos(date, bundle?.notes_bundle || null)
    : null;
  const codes = new Map((addonList || []).map((a) => [a.id, a.code]));
  const go = (d) => { location.hash = `#/?d=${d}`; };
  const toolbar = h('div', { class: 'toolbar' },
    h('button', { class: 'btn ghost', type: 'button', 'aria-label': 'Edellinen päivä', onclick: () => go(addDays(date, -1)) }, '‹'),
    h('input', { type: 'date', value: date, 'aria-label': 'Päivä', onchange: (e) => e.target.value && go(e.target.value) }),
    h('button', { class: 'btn ghost', type: 'button', 'aria-label': 'Seuraava päivä', onclick: () => go(addDays(date, 1)) }, '›'),
    h('button', { class: 'btn ghost sm', type: 'button', onclick: () => go(todayHel()) }, 'Tänään'),
    h('button', { class: 'btn ghost sm', type: 'button', 'data-testid': 'next-own-shift', text: memoText('ui.admin.day_memos.next_own_shift'), onclick: async (ev) => {
      const b = ev.currentTarget; b.disabled = true;
      try { const next = await rpc('admin_next_own_shift_date', { p_from_date: todayHel() });
        if (next) go(next); else toast(memoText('ui.admin.day_memos.next_own_shift_none'));
      } catch { toast(memoText('ui.admin.day_memos.next_own_shift_failed'), 'err'); } finally { b.disabled = false; }
    } }),
    h('a', { class: 'btn primary sm', href: `#/uusi?d=${date}`, text: '+ Uusi varaus' }));
  const rows = resv || [];
  // Lisäpalvelut: varauskohtaiset (view.reservations), vuorokohtainen "valmistele" (view.prep) ja päivän summat (view.addon_totals)
  const dv = new Map((view.reservations || []).map((r) => [r.reservation_id, r]));
  const lc = (n) => (n ? n.charAt(0).toLowerCase() + n.slice(1) : n);
  const addonText = (items) => items.map((i) => `${i.quantity} × ${lc(i.name)}`).join(', ');
  const ACTIVE = ['pending', 'confirmed', 'completed'];
  const active = rows.filter((r) => ACTIVE.includes(r.status));
  const RES_KEYS = ['notes', 'lifecycle', 'space_code', 'legs', 'quota_exempt', 'override_reason', 'claim_offset_min', 'claim_minutes', 'parent_reservation_id', 'therapist_missing', 'therapist_missing_open', 'therapist_exception_at', 'therapist_exception_note', 'option', 'option_missing'];
  const merged = (r) => { const x = dv.get(r.reservation_id) || {}; const m = { ...r, source: r.source ?? x.source, external_id: r.external_id ?? x.external_id }; for (const k of RES_KEYS) if (x[k] !== undefined) m[k] = x[k]; return m; };
  // Lahjakorttivaraus listataan tavallisen vuoron alle; pieni "Lahjakortti"-merkki (ui.admin.day.gift_card_badge, §18). Johku-merkki ennallaan.
  const giftBadge = (r, x) => (isGiftCardReservation(r) || isGiftCardReservation(x) ? h('span', { class: 'badge gift', 'data-testid': 'gift-badge', text: dayText('ui.admin.day.gift_card_badge') }) : null);
  const open = (r) => reservationDialog(merged(r), { methods: refs.methods, onChange: reload, refs, can: ctx.can, role: ctx.role });
  const resRow = (r) => { const x = dv.get(r.reservation_id) || {}; const ad = (x.addons && x.addons.length) ? x.addons : (r.addons || []); const src = { source: r.source ?? x.source, external_id: r.external_id ?? x.external_id };
    const kind = x.customer_kind || r.customer_kind; const company = x.company || r.company; const legs = (x.legs && x.legs.length) ? x.legs : (r.legs || []); const space = x.space_code || r.space_code;
    let stBadge = statusBadge(r.status);
    const arrive = arrivalButton(r, { can: ctx.can, onState: (st) => { clearDayBundleCache(); const nb = statusBadge(st); stBadge.replaceWith(nb); stBadge = nb; } });
    return h('li', { class: `resrow ${r.status}${ad.length ? ' has-addons' : ''}${arrive ? ' has-arrive' : ''}` },
    h('div', { class: 'resmain' }, h('button', { type: 'button', class: 'link', onclick: () => open(r) }, h('strong', { text: r.customer_name || '–' }), ` · ${r.persons} hlö`, kind === 'company' ? [' ', badge('warn', 'Yritys'), company ? ` ${company}` : ''] : null,
      (legs.length > 1 || (space && space !== 'savusauna')) ? legsList(legs, refs) : null),
    (r.notes || x.notes) ? h('div', { class: 'res-note', 'data-testid': 'res-note', text: r.notes || x.notes }) : null,
    ad.length ? h('div', { class: 'addon-mark' }, addonItems(ad, codes)) : null,
    h('span', { class: 'meta' }, optionBadge(x.option !== undefined ? x : r), spaceBadge(x, refs), resourceBadges(x), sourceBadge(src), giftBadge(r, x), stBadge, payBadge(r.payment_status), r.hold_expires_at ? badge('muted', `pito ${fmtTime(r.hold_expires_at)}`) : null, ` #${r.order_no}`)),
    arrive); };
  const card = ({ s, mine }) => {
    const booked = sumPersons(mine);
    const prod = refs.productById.get(s.product_id);
    const cap = capacityButton(s, date, mine.length > 0);
    return h('section', { class: `card session ${s.mode}`, 'data-testid': 'session', 'data-start': s.starts_at },
      h('header', {}, h('strong', { class: 'time', text: `${fmtTime(s.starts_at)}–${fmtTime(s.ends_at)}` }), h('span', { class: 'ttl', text: prod?.name || s.label }),
        h('span', { class: 'hdr-right' }, h('span', { class: 'cnt', 'data-testid': 'session-persons', text: s.mode === 'exclusive' && !booked ? '' : `${booked} hlö` }), cap)),
      mine.length ? h('ul', { class: 'reslist' }, mine.map(resRow)) : null);
  };
  const slotCard = (list) => { const r0 = list[0];
    return h('section', { class: 'card session slot', 'data-testid': 'slot', 'data-start': r0.starts_at },
      h('header', {}, h('strong', { class: 'time', text: `${fmtTime(r0.starts_at)}–${fmtTime(r0.ends_at)}` }), h('span', { class: 'ttl', text: slotTitle(list, refs.productById.get(r0.product_id)?.name) || 'Varaus' }),
        h('span', { class: 'hdr-right' }, h('span', { class: 'cnt', 'data-testid': 'session-persons', text: `${sumPersons(list)} hlö` }))),
      h('ul', { class: 'reslist' }, list.map(resRow))); };
  // Tapahtumat (kb.event_dates) samalla kortilla kuin vuorot. Osallistuja ei toistu slotissa. Ilman kelloa kortti menee päivän loppuun.
  const eventCard = (ev, mine) => {
    const label = eventTimeLabel(ev);
    const time = label.kind === 'text' ? label.text : label.kind === 'range' ? `${fmtTime(label.start)}–${fmtTime(label.end)}` : dayText('ui.admin.day.event_all_day');
    const prod = refs.productById.get(ev.product_id);
    const name = (dayLang() === 'en' && (ev.name_en || prod?.name_en)) || ev.name || prod?.name || dayText('ui.admin.day.event_badge');
    return h('section', { class: 'card session event', 'data-testid': 'event', 'data-event-id': ev.event_id ?? '', 'data-product': String(ev.product_id ?? '') },
      h('header', {}, h('strong', { class: 'time', text: time }), h('span', { class: 'ttl', text: name }),
        h('span', { class: 'hdr-right' }, badge('ev', dayText('ui.admin.day.event_badge')), h('span', { class: 'cnt', 'data-testid': 'session-persons', text: `${sumPersons(mine)} hlö` }))),
      mine.length ? h('ul', { class: 'reslist' }, mine.map(resRow)) : null);
  };
  // Lista ei tuo rule_id:tä; päivänäkymän varausrivi tuo. Ilman sitä samaan aikaan alkavat säännöt jakaisivat varauksen.
  const cardRows = rows.map((r) => {
    if (r.rule_id != null) return r;
    const ruleId = dv.get(r.reservation_id)?.rule_id;
    return ruleId == null ? r : { ...r, rule_id: ruleId };
  });
  const plan = assignDayCards({ sessions: view.sessions || [], reservations: cardRows, events: extras?.events || [], date });
  const timeline = [
    ...plan.sessions.map((x) => ({ at: x.session.starts_at, end: x.session.ends_at, node: card({ s: x.session, mine: x.reservations }) })),
    ...plan.slots.map((l) => ({ at: l[0].starts_at, end: l[0].ends_at, node: slotCard(l) })),
    ...plan.events.map((x) => { const at = eventSortIso(x.event, date) || '9999-12-31T23:59:59.000Z'; return { at, end: at, node: eventCard(x.event, x.participants) }; }),
  ].sort((a, b) => a.at.localeCompare(b.at) || a.end.localeCompare(b.end)).map((x) => x.node);
  const rev = seeMoney ? revenueView(revenueRpc === undefined ? extras : revenueRpc, date) : null;
  const revenue = rev && h('section', { class: 'dayrev', 'data-testid': 'day-revenue', 'data-gross': rev.available ? String(rev.gross) : '' },
    h('h2', { text: dayText('ui.admin.day.revenue_title') }),
    rev.available
      ? h('p', { class: 'dayrev-sum' }, h('strong', { 'data-testid': 'day-revenue-gross', text: money(rev.gross) }), ' ', h('span', { class: 'muted', text: dayText('ui.admin.day.revenue_vat') }))
      : h('p', { class: 'muted', text: dayText('ui.admin.day.revenue_unavailable') }),
    rev.showPending ? h('p', { class: 'muted dayrev-note', 'data-testid': 'day-revenue-pending', text: dayText('ui.admin.day.revenue_pending', { amount: money(rev.pending_gross) }) }) : null,
    rev.showUnpaid ? h('p', { class: 'muted dayrev-note', 'data-testid': 'day-revenue-unpaid', text: dayText('ui.admin.day.revenue_unpaid', { amount: money(rev.unpaid_gross) }) }) : null);
  const inactive = rows.filter((r) => !ACTIVE.includes(r.status));
  const blocks = h('section', { class: 'card', 'data-testid': 'day-blocks' }, h('h3', { text: 'Sulut' }), blockList(view.blocks, refs, reload, 'Ei sulkuja.'),
    h('button', { type: 'button', class: 'btn ghost sm', onclick: () => blockDialog(date, refs, reload) }, '+ Lisää sulku'));
  const prepBox = prepCard({ totals: view.addon_totals, prep: view.prep, persons: sumPersons(active), bookings: active.length, codes });
  return [h('h1', { text: fmtDay(`${date}T12:00:00Z`) }),
    DAY_VIEW_SHOW_ANNOUNCEMENTS ? bulletinCard({ date, bulletins: memos?.bulletins || [], can: ctx.can, reload }) : null,
    revenue, shifts, optNote, toolbar,
    DAY_VIEW_SHOW_DAY_NOTES ? dayNotesCard({ date, dayNotes: memos?.day_notes || [], can: ctx.can, reload }) : null, prepBox,
    h('div', { class: 'daygrid day-view' }, timeline.length ? timeline : empty('Ei vuoroja tälle päivälle.')),
    inactive.length ? h('details', { class: 'card inactive-res', 'data-testid': 'inactive-res' }, h('summary', { text: `Peruutetut ja päättyneet varaukset (${inactive.length})` }), h('ul', { class: 'reslist' }, inactive.map(resRow))) : null,
    h('p', { class: 'muted', text: `${active.length} aktiivista varausta, ${sumPersons(active)} henkilöä yhteensä.` }), blocks];
}
