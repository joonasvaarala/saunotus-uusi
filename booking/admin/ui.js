// Pienet UI-apurit: DOM-rakentaja, muotoilut, ilmoitukset, dialogit. Ei riippuvuuksia.
import { icon } from './icons.js';
export const h = (tag, attrs, ...kids) => {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v; else if (k === 'text') el.textContent = v; else if (k === 'value') el.value = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v); else if (v === true) el.setAttribute(k, ''); else el.setAttribute(k, v);
  }
  for (const c of kids.flat(Infinity)) if (c != null && c !== false) el.append(c.nodeType ? c : document.createTextNode(c));
  return el;
};
const TZ = 'Europe/Helsinki';
const dtf = (o) => new Intl.DateTimeFormat('fi-FI', { timeZone: TZ, ...o });
export const fmtDate = (iso) => dtf({ weekday: 'short', day: 'numeric', month: 'numeric', year: 'numeric' }).format(new Date(iso));
export const fmtDay = (iso) => dtf({ weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }).format(new Date(iso));
export const fmtTime = (iso) => dtf({ hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(iso)).replace('.', ':');
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
export const PAY = { unpaid: 'Maksamatta', pending: 'Maksu kesken', paid: 'Maksettu', partially_paid: 'Osittain maksettu', refunded: 'Palautettu', partially_refunded: 'Osittain palautettu', failed: 'Epäonnistui', invoiced: 'Laskutettu' };
export const badge = (kind, text) => h('span', { class: `badge ${kind}`, text });
export const statusBadge = (s) => badge(`st-${s}`, STATUS[s] || s);
export const payBadge = (s) => badge(`pay-${s}`, PAY[s] || s);
// Johku-tunniste: vain lähteelle 'johku' (admin_list_reservations / admin_day_view: source). Puuttuva tai 'native' → ei tunnistetta (defensiivinen: vanha kanta ei palauta kenttää).
export const isJohku = (r) => r?.source === 'johku';
export const sourceBadge = (r) => (isJohku(r) ? h('span', { class: 'badge src-johku', title: 'Tuotu Johku-varausjärjestelmästä', text: 'Johku' }) : null);

let toastTimer;
export function toast(msg, kind = 'ok') {
  let el = document.getElementById('toast');
  if (!el) { el = h('div', { id: 'toast', role: 'status', 'aria-live': 'polite' }); document.body.append(el); }
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
  wrong_lifecycle: 'Väärän tyyppinen tuote: vanhat tuotteet kirjataan "Vanha varaus" -lomakkeella, nykyiset resurssivarauksena.',
  space_not_allowed: 'Tuote tai henkilömäärä ei sovi valittuun tilaan.',
  no_space: 'Tuotteelle ei ole sääntöä valitulle tilalle.',
  no_pool_for_start: 'Alkuajalle ei ole kapasiteettipoolia. Valitse tuotteen mukainen alkamisaika.',
  no_primary_leg: 'Tuotteelta puuttuu ensisijainen tila (tuotteen tilasäännöt).',
  bad_rule: 'Tuotteen tilasääntö on virheellinen (yksityisvarauksen pitää kattaa koko aika). Ota yhteys ylläpitoon.',
  skill_unknown: 'Tuotteen vaatimaa saunottajan taitoa ei tunneta. Ota yhteys ylläpitoon.',
  not_resourced: 'Tuotteella ei ole resurssisääntöjä, joten sitä ei voi varata tällä lomakkeella.',
  capacity_exceeded: 'Ei tarpeeksi vapaita paikkoja tälle ajalle.',
  space_closed: 'Aika ei ole varattavissa (tila suljettu).',
  private_booked: 'Ajalle on yksityisvuoro – yleistä vuoroa ei voi varata.',
  public_shift_booked: 'Ajalle on jo varauksia yleisille vuoroille – yksityisvuoroa ei voi varata.',
  bad_pool: 'Kapasiteettipooli ei kuulu tähän tilaan.',
  has_reservations: 'Ajalla on varauksia – peru ne ensin.',
  forbidden: 'Ei oikeuksia tähän toimintoon.',
  duplicate_name: 'Samanniminen aktiivinen tuote on jo olemassa',
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
};
export const errMsg = (e) => {
  const t = e?.code && ERR_FI[e.code];
  if (!t) return e?.message || String(e);
  const perm = e.code === 'forbidden' && /\(([a-z_.]+)\)/.exec(e.message || '');   // "Ei oikeutta tähän toimintoon (bookings.override)"
  return perm ? `${t.replace(/\.$/, '')} (${perm[1]}).` : t;
};
// Kääri asynkroninen toiminto: nappi pois käytöstä, virhe näytetään ilmoituksena
export async function run(btn, fn) {
  if (btn) btn.disabled = true;
  try { return await fn(); } catch (e) { toast(errMsg(e), 'err'); } finally { if (btn) btn.disabled = false; }
}
export function dialog(title, content, { wide = false } = {}) {
  const d = h('dialog', { class: `dlg${wide ? ' wide' : ''}`, 'aria-labelledby': 'dlg-title' },
    h('div', { class: 'dlg-head' }, h('h2', { id: 'dlg-title', text: title }), h('button', { type: 'button', class: 'icon-btn', 'aria-label': 'Sulje', onclick: () => d.close() }, icon('close', 22))),
    h('div', { class: 'dlg-body' }, content));
  d.addEventListener('close', () => d.remove());
  document.body.append(d); d.showModal();
  return d;
}
export const field = (label, input, hint) => h('label', { class: 'fld' }, h('span', { text: label }), input, hint ? h('small', { text: hint }) : null);
export const empty = (text) => h('p', { class: 'empty', text });
