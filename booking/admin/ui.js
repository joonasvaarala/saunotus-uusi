// Pienet UI-apurit: DOM-rakentaja, muotoilut, ilmoitukset, dialogit. Ei riippuvuuksia.
import { icon } from './icons.js';
export const h = (tag, attrs, ...kids) => {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v; else if (k === 'text') el.textContent = v; else if (k === 'value') el.value = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v); else if (v === true) el.setAttribute(k, ''); else el.setAttribute(k, v);
  }
  // null, undefined ja false jätetään pois. Element.append muuttaisi ne tekstiksi "null", "undefined" tai "false".
  for (const c of kids.flat(Infinity)) {
    if (c == null || c === false) continue;
    el.append(c.nodeType ? c : document.createTextNode(c));
  }
  return el;
};
const TZ = 'Europe/Helsinki';
const dtf = (o) => new Intl.DateTimeFormat('fi-FI', { timeZone: TZ, ...o });
export const fmtDate = (iso) => dtf({ weekday: 'short', day: 'numeric', month: 'numeric', year: 'numeric' }).format(new Date(iso));
export const fmtDay = (iso) => dtf({ weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }).format(new Date(iso));
// YHT-05: sama kellonaikamuoto kuin kaupassa ja sivustolla (booking/shop/src/clock.js clockFromIso, FI "16.00", "9.30"). Ei tuoda kaupan moduulia,
// jottei hallinnan ensilataus riipu /shop/src/-tiedostosta; booking/tests/muodot-sanasto.test.mjs vartioi, että tulos on sama.
// <input type="time"> -arvo ja vertailu: aina "HH:MM" (Helsingin aika), ei näyttömuoto.
export const timeValue = (iso) => dtf({ hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(iso)).replace('.', ':');
export const fmtTime = (iso) => { const p = dtf({ hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(new Date(iso)); return `${Number(p.find((x) => x.type === 'hour').value)}.${p.find((x) => x.type === 'minute').value}`; };
// YHT-05: ALV-prosentti suomalaisittain (25,5 %), rahat Intl-muodossa (money)
export const vatText = (rate) => (rate == null || rate === '' ? '–' : `${new Intl.NumberFormat('fi-FI', { maximumFractionDigits: 2 }).format(+rate)} %`);
// YHT-04: lukumäärä ja oikea muoto (1 varaus / 2 varausta)
const FI_PLURAL = new Intl.PluralRules('fi-FI');
export const countText = (n, one, other) => `${n} ${FI_PLURAL.select(Number(n)) === 'one' ? one : other}`;
export const fmtDT = (iso) => (iso ? `${dtf({ day: 'numeric', month: 'numeric', year: 'numeric' }).format(new Date(iso))} ${fmtTime(iso)}` : '–');
export const money = (n) => (n == null ? '–' : new Intl.NumberFormat('fi-FI', { style: 'currency', currency: 'EUR' }).format(+n));
export const todayHel = () => new Date().toLocaleDateString('sv-SE', { timeZone: TZ });
export const addDays = (ds, n) => { const d = new Date(ds + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
// 'YYYY-MM-DDTHH:MM' (Helsingin aika) → UTC ISO-aikaleima
export function helsinkiIso(local) {
  const [d, t] = local.split('T');
  const base = new Date(`${d}T${t || '00:00'}:00Z`).getTime();
  const off = new Date(new Date(base).toLocaleString('en-US', { timeZone: TZ })) - new Date(new Date(base).toLocaleString('en-US', { timeZone: 'UTC' }));
  return new Date(base - off).toISOString();
}
export const dayStartIso = (ds) => helsinkiIso(`${ds}T00:00`);

export const STATUS = { confirmed: 'Vahvistettu', pending: 'Odottaa', cancelled: 'Peruttu', expired: 'Vanhentunut', completed: 'Toteutunut', no_show: 'Ei saapunut', draft: 'Luonnos' };
export const PAY = { unpaid: 'Maksamatta', pending: 'Maksu kesken', paid: 'Maksettu', partially_paid: 'Osittain maksettu', refunded: 'Hyvitetty', partially_refunded: 'Osittain hyvitetty', failed: 'Epäonnistui', invoiced: 'Laskutettu' };
export const badge = (kind, text) => h('span', { class: `badge ${kind}`, text });
export const statusBadge = (s) => badge(`st-${s}`, STATUS[s] || s);
export const payBadge = (s) => badge(`pay-${s}`, PAY[s] || s);
// Johku-tunniste: vain lähteelle 'johku' (admin_list_reservations / admin_day_view: source). Puuttuva tai 'native' → ei tunnistetta (defensiivinen: vanha kanta ei palauta kenttää).
export const isJohku = (r) => r?.source === 'johku';
export const sourceBadge = (r) => (isJohku(r) ? h('span', { class: 'badge src-johku', title: 'Tuotu Johku-varausjärjestelmästä', text: 'Johku' }) : null);

let toastTimer;
// Avoin modaali-dialogi (showModal) on selaimen ylimmällä tasolla: body-elementissä oleva ilmoitus jäisi sen alle näkymättömiin.
// Siksi ilmoitus siirretään päällimmäisen avoimen dialogin sisään (ja takaisin bodyyn, kun dialogia ei ole).
export function toastHost(doc = globalThis.document) {
  const isModal = (d) => { try { return !d.matches || d.matches(':modal'); } catch { return true; } };
  const open = [...(doc?.querySelectorAll?.('dialog[open]') || [])].filter(isModal);
  return open.length ? open[open.length - 1] : doc?.body;
}
export function toast(msg, kind = 'ok') {
  let el = document.getElementById('toast');
  if (!el) el = h('div', { id: 'toast' });
  const host = toastHost(document);
  if (host && el.parentNode !== host) host.append(el);
  el.setAttribute('role', kind === 'err' ? 'alert' : 'status');
  el.setAttribute('aria-live', kind === 'err' ? 'assertive' : 'polite');
  el.className = `toast ${kind} show`; el.textContent = msg;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => el.classList.remove('show'), kind === 'err' ? 6000 : kind === 'warn' ? 7000 : 2800);
}
// Virhekoodit (SQLSTATE BK001; koodi DETAIL-kentässä → ApiError.code) suomeksi. Tuntemattomalle koodille näytetään palvelimen oma (suomenkielinen) viesti.
export const ERR_FI = {
  option_required: 'Valitse hoito.', invalid_option: 'Valittu hoito ei kelpaa tälle tuotteelle.', no_options: 'Pakollinen valinta vaatii vähintään yhden aktiivisen hoidon.',   // booking_50
  space_busy: 'Tila on jo varattu tälle ajalle tai sen puskuriaikaan (Raunin istuntojen väli ≥ 15 min).',
  no_therapist: 'Ei vapaata saunottajaa tälle ajalle (vuoro tai vaadittu taito puuttuu).',
  therapist_closed: 'Saunottajat eivät ole saatavilla tälle ajalle (hoidot kiinni).',
  parent_required: 'Lisäpalvelu vaatii jälkilöyly- tai yksityisvuorovarauksen samalle ajalle. Valitse vanhempi varaus tai luo se ensin.',
  bad_range: 'Hakujakso on virheellinen (enintään 31 päivää).',
  busy: 'Palvelin on kiireinen – yritä hetken päästä uudelleen.',
  rate_limited: 'Liian monta hakua – yritä hetken päästä uudelleen.',
  override_reason_required: 'Ylitys vaatii perustelun (vähintään 3 merkkiä).',
  wrong_lifecycle: 'Väärän tyyppinen tuote: vanhat tuotteet kirjataan Jälkikirjaus-lomakkeella, nykyiset Hoito tai tila -lomakkeella.',
  space_not_allowed: 'Tuote tai henkilömäärä ei sovi valittuun tilaan.',
  no_space: 'Tuotteelle ei ole sääntöä valitulle tilalle.',
  no_pool_for_start: 'Alkuajalle ei ole kapasiteettipoolia. Valitse tuotteen mukainen alkamisaika.',
  no_primary_leg: 'Tuotteelta puuttuu ensisijainen tila (tuotteen tilasäännöt).',
  bad_rule: 'Tuotteen tilasääntö on virheellinen (yksityisvarauksen pitää kattaa koko aika). Ota yhteys ylläpitoon.',
  skill_unknown: 'Tuotteen vaatimaa saunottajan taitoa ei tunneta. Ota yhteys ylläpitoon.',
  not_resourced: 'Tuotteella ei ole resurssisääntöjä, joten sitä ei voi varata tällä lomakkeella.',
  capacity_exceeded: 'Ei tarpeeksi vapaita paikkoja tälle ajalle.',
  space_closed: 'Aika ei ole varattavissa (tila suljettu).',
  private_booked: 'Ajalle on jo yksityinen varaus – päällekkäistä varausta ei voi tehdä.',
  public_shift_booked: 'Tälle ajalle on jo varaus – yksityisvuoroa ei voi varata päällekkäin.',
  overbook_admin_only: 'Vain admin voi ylibuukata.',
  bad_pool: 'Kapasiteettipooli ei kuulu tähän tilaan.',
  has_reservations: 'Ajalla on varauksia – peru ne ensin.',
  forbidden: 'Ei oikeuksia tähän toimintoon.',
  duplicate_name: 'Samanniminen aktiivinen tuote on jo olemassa',
  no_business: 'Yritystä ei löydy.',
  invalid_category: 'Kategoria ei kelpaa.',
  invalid_name: 'Nimi ei voi olla tyhjä.',
  invalid_vat: 'ALV-kanta ei ole sallittu.',
  invalid_price: 'Virheellinen hinta.',
  unknown_field: 'Kenttää ei saa muokata.',
  // migraatio 18 (sulkukalenterit)
  closure_managed: 'Tämä sulku tulee sulkukalenterista, eikä sitä voi muokata tai poistaa hallinnassa. Muuta tai poista tapahtuma kalenterissa tai ohita tapahtuma Kalenterisulut-sivulla.',
  bad_override: 'Virheellinen ohitus (sallitut: Ohita, Estä, Palauta automaattinen).',
  not_found: 'Tapahtumaa ei löydy (se on voinut poistua kalenterista). Päivitä sivu.',
  calendar_not_found: 'Sulkukalenteria ei löydy.',
  // migraatiot 22–23 (saunottaja puuttuu, aikaikkuna)
  time_window: 'Aika on hoitojen ja saunotusten aikaikkunan ulkopuolella: ma–pe 16:00–20:30, la–su 13:00–20:30 (päättyminen viimeistään 20:30). Valitse sallittu aika; ylitys vaatii oikeuden ja perustelun.',
  ritual_start: 'Rituaalin tai paketin alkuaika voi olla vain 16:00, 16:30 tai 17:00.',
  note_required: 'Perustelu vaaditaan (vähintään 3 merkkiä).',
  no_conflict: 'Sulkukonfliktia ei ole tälle varaukselle ja sululle.',
  not_missing: 'Varaukselta ei puutu saunottajaa (tai poikkeus on jo myönnetty), joten poikkeusta ei tarvita.',
  therapist_present: 'Varauksella on jo saunottaja, joten poikkeusta ei tarvita.',
  secrets_not_allowed: 'Salaisuuksia ei tallenneta asetuksiin. Ne annetaan myöhemmin suojatulla lomakkeella.',
  approval_required: 'Yhdistetty tila vaatii hyväksyjän nimen ja päivän.',
  live_incomplete: 'Yhdistetty tila vaatii ALV-tilan, vähintään yhden myyntitilin ja maksutavan tilin.',
  invalid_setting: 'Asetus ei kelpaa. Tarkista tilit, ALV-tila ja maksuehto.',
  invalid_calendar: 'Kalenterin tunnus ei kelpaa.',
  closure_calendar: 'Sulkukalenteria ei käytetä varauksille.',
  unknown_resource: 'Tuntematon resurssi.',
  gift_card_required: 'Lahjakorttimaksu tarvitsee lahjakortin koodin.',
  gift_card_code_required: 'Anna lahjakortin koodi.',
};
const TECHNICAL_GIFT = /admin_redeem_gift_card|public_apply_gift_card/;
export const errMsg = (e) => {
  const raw = e?.message || '';
  if (TECHNICAL_GIFT.test(raw) || TECHNICAL_GIFT.test(e?.code || '')) return ERR_FI.gift_card_required;
  const t = e?.code && ERR_FI[e.code];
  if (!t) return raw || String(e);
  const perm = e.code === 'forbidden' && /\(([a-z_.]+)\)/.exec(e.message || '');   // "Ei oikeutta tähän toimintoon (bookings.override)"
  return perm ? `${t.replace(/\.$/, '')} (${perm[1]}).` : t;
};
// Kääri asynkroninen toiminto: nappi pois käytöstä, virhe näytetään ilmoituksena
export async function run(btn, fn) {
  if (btn) btn.disabled = true;
  try { return await fn(); } catch (e) { toast(errMsg(e), 'err'); } finally { if (btn) btn.disabled = false; }
}
// YHT-06: jokaisella dialogilla oma otsikon id (aria-labelledby). Jos dialogin lomakkeeseen on kirjoitettu, Esc ja sulkurasti kysyvät ensin
// (palkki dialogin alareunassa: Hylkää muutokset / Jatka muokkausta); ohjelman oma d.close() (esim. tallennuksen jälkeen) sulkee aina.
let dlgSeq = 0;
export function dialog(title, content, { wide = false } = {}) {
  const tid = `dlg-title-${++dlgSeq}`;
  let dirty = false;
  const keep = h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'dlg-keep', text: 'Jatka muokkausta', onclick: () => { bar.hidden = true; } });
  const bar = h('div', { class: 'dlg-unsaved row wrap', role: 'alert', hidden: true, 'data-testid': 'dlg-unsaved' },
    h('span', { class: 'grow', text: 'Muutokset eivät ole tallessa.' }), keep,
    h('button', { type: 'button', class: 'btn danger', 'data-testid': 'dlg-discard', text: 'Hylkää muutokset', onclick: () => d.close() }));
  const ask = () => { if (!dirty) { d.close(); return; } bar.hidden = false; keep.focus(); };
  const d = h('dialog', { class: `dlg${wide ? ' wide' : ''}`, 'aria-labelledby': tid },
    h('div', { class: 'dlg-head' }, h('h2', { id: tid, text: title }), h('button', { type: 'button', class: 'icon-btn', 'aria-label': 'Sulje', onclick: ask }, icon('close', 22))),
    h('div', { class: 'dlg-body' }, content), bar);
  d.addEventListener('input', (e) => { if (e.target?.closest?.('form') && !e.target.closest('.dlg-unsaved')) dirty = true; });
  d.addEventListener('cancel', (e) => { if (dirty) { e.preventDefault(); ask(); } });
  d.addEventListener('close', () => d.remove());
  document.body.append(d); d.showModal();
  return d;
}
/** YHT-06: reitinvaihto sulkee auki jääneet dialogit (admin.js route). */
export const closeDialogs = (doc = globalThis.document) => { for (const d of doc?.querySelectorAll?.('dialog[open]') || []) d.close(); };
export const field = (label, input, hint) => h('label', { class: 'fld' }, h('span', { text: label }), input, hint ? h('small', { text: hint }) : null);
export const empty = (text) => h('p', { class: 'empty', text });

// YHT-02: yhteiset perusosat; uudet ja muutettavat näkymät käyttävät näitä omien luokkien sijaan (luokat booking/shared/ui.css, ux-*).
/** Tyhjä tila: teksti ja valinnainen toiminto (esim. "Uusi koodi"). */
export const emptyState = (text, action = null) => h('div', { class: 'ux-empty', 'data-testid': 'empty-state' }, h('p', { text }), action);
/** Latausrunko tekstin "Ladataan…" sijaan; ruudunlukija kuulee tekstin. */
export const skeleton = (label = 'Ladataan…', lines = 3) => h('div', { class: 'skel stack', role: 'status', 'aria-busy': 'true', 'data-testid': 'skeleton' },
  h('span', { class: 'sr-only', text: label }), ...Array.from({ length: lines }, () => h('span', { class: 'ux-skeleton', 'aria-hidden': 'true' })));
/** Ilmoituslaatikko: kind = ok | warn | danger | info. */
export const alertBox = (kind, ...kids) => h('div', { class: `ux-alert ux-alert--${kind}`, role: kind === 'danger' ? 'alert' : 'status' }, ...kids);
/** Sivun otsikkorivi: H1 ja oikealle tasatut toiminnot. */
export const pageHead = (title, ...actions) => h('div', { class: 'ux-page-head' }, h('h1', { text: title }), actions.length ? h('div', { class: 'row wrap' }, ...actions) : null);
/** Suodatinsiru (aria-pressed). */
export const chip = (text, { on = false, onclick, testid } = {}) => h('button', { type: 'button', class: 'ux-chip', 'aria-pressed': String(!!on), 'data-testid': testid, onclick }, text);

/**
 * YHT-03: yksi välilehtikomponentti (role=tablist, nuolinäppäimet, aria-controls). Kohde on joko painike (onSelect) tai linkki (href, reititys).
 * items: [{ id, text, href?, testid?, controls? }]. Palauttaa listan; list.select(id) päivittää valinnan ilman uudelleenpiirtoa.
 */
export function tabs({ label, items, selected, onSelect, idPrefix = 'tab', testid, cls = '', hidden = false }) {
  const list = h('div', { class: `tl-tabs${cls ? ` ${cls}` : ''}`, role: 'tablist', 'aria-label': label, 'data-testid': testid, hidden: hidden || null });
  const nodes = new Map();
  const choose = (it, focus) => { if (it.href) { if (location.hash !== it.href) location.hash = it.href; } else onSelect?.(it.id, focus); };
  items.forEach((it, i) => {
    const attrs = { role: 'tab', class: 'tl-tabbtn', id: `${idPrefix}-${it.id}`, 'aria-controls': it.controls || null, 'data-testid': it.testid || null,
      onkeydown: (e) => {
        const j = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: items.length - 1 }[e.key];
        if (j == null) return;
        e.preventDefault();
        const next = items[(j + items.length) % items.length];
        nodes.get(next.id)?.focus();
        choose(next, true);
      } };
    const node = it.href ? h('a', { ...attrs, href: it.href }, it.text) : h('button', { ...attrs, type: 'button', onclick: () => choose(it, false) }, it.text);
    nodes.set(it.id, node); list.append(node);
  });
  list.select = (id) => { for (const [k, n] of nodes) { n.setAttribute('aria-selected', String(k === id)); n.tabIndex = k === id ? 0 : -1; } };
  list.button = (id) => nodes.get(id);
  list.select(selected);
  return list;
}

// Vaiheiden, onnistumis- ja virheilmoitusten hallittu vieritys.
export const prefersReducedMotion = (win = globalThis) => !!win?.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches;
export function revealSection(el, focusEl = el, win = globalThis) {
  if (!el) return false;
  el.scrollIntoView?.({ block: 'start', behavior: prefersReducedMotion(win) ? 'auto' : 'smooth' });
  const interactive = !!focusEl?.matches?.('a[href],button,input,select,textarea,summary');
  if (focusEl && !interactive && !focusEl.matches?.('[tabindex]')) focusEl.setAttribute?.('tabindex', '-1');
  focusEl?.focus?.({ preventScroll: true, ...(interactive ? {} : { focusVisible: false }) });
  return true;
}
export function revealIfHidden(el, win = globalThis) {
  if (!el?.getBoundingClientRect || !el.scrollIntoView) return false;
  const r = el.getBoundingClientRect(), height = win.innerHeight || win.document?.documentElement?.clientHeight || 0;
  if (r.top >= 80 && r.bottom <= height) return false;
  el.scrollIntoView({ block: 'nearest', behavior: prefersReducedMotion(win) ? 'auto' : 'smooth' });
  return true;
}
