// Viikko-ohjelman malli: julkisten RPC-vastausten (public_availability_all, public_treatment_availability, public_events,
// public_catalog, public_quiet_offers) muunnos viikon päiväsarakkeiksi. Puhdas logiikka, ei DOMia, ei verkkoa.
// Sisältösäännöt (Joonas t1768u / t1769u):
//  - Yleiset vuorot: public_sauna. Tunnin vuoroa (tunnin-vuoro) EI näytetä. Turvetorstai kuuluu yleisiin.
//  - Oma sauna: "Oma saunavuoro alk. [päivän halvin vapaa hinta]" + jälkilöylyt (hiljaisen ajan ale, booking_162). Ei aloitusaikoja.
//  - Hoidot ja rituaalit: vain nimet, ei kellonaikoja. Saunotusrituaali (saunotusrituaali) EI sellaisenaan. Tapahtumat samassa solussa.
//  - Ei Yrityksille-riviä (corporate-tuotteet jäävät pois), ei koulutuksia.
import { addDaysIso, weekdayIso, offerForSlot, JALKIL_ID } from './quiet-offers-logic.js';
import { rangeLabel, ymdHel, asEventList, cardDates, eventIsFull, eventDisplayName, homeEventCards } from './week-live.js';
import { catalogDisplayName } from './catalog-names.js';

export const HIDDEN_PUBLIC_SLUGS = Object.freeze(['tunnin-vuoro']);
export const HIDDEN_CARE_SLUGS = Object.freeze(['saunotusrituaali']);
export const OWN_SLUG = 'oma-saunavuoro';
export const JALKIL_SLUG = 'jalkiloylyt';
/** Ikkunan pituus päivinä: tänään + 6 päivää (liukuva ikkuna, ei kalenteriviikkoa). */
export const WINDOW_DAYS = 7;
/** Jaksoja (7 pv) eteenpäin, joille voi selata (varausikkuna on selvästi tätä pidempi). Nimi on historiallinen. */
export const MAX_WEEKS_AHEAD = 8;
/** Hoitojen varausikkuna päivinä VARALLA (sama kuin treatments.js POLICY.horizonDays). Oikea ikkuna tulee public_settings.public_treatment_horizon_days -arvosta (horizonDays(settings)); sen jälkeisille päiville hoitoja ei haeta. */
export const CARE_HORIZON_DAYS = 14;

/** Ikkunan ensimmäinen päivä: aina tänään (liukuva ikkuna). Ei maanantaita. */
export const weekStartOf = (today) => today;
export function isoWeekNumber(ds) {
  const d = new Date(`${ds}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + 4 - (d.getUTCDay() || 7));
  return Math.ceil(((d - Date.UTC(d.getUTCFullYear(), 0, 1)) / 864e5 + 1) / 7);
}
const EN_MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
/** FI: 15.–21.11. (sama kuukausi) tai 30.11.–6.12. EN: 15–21 Nov tai 30 Nov–6 Dec. Alku = ikkunan ensimmäinen päivä (ei välttämättä maanantai). */
export function weekRange(start, lang = 'fi') {
  const end = addDaysIso(start, WINDOW_DAYS - 1);
  if (lang === 'en') {
    const m = (ds) => EN_MONTHS[+ds.slice(5, 7) - 1];
    return start.slice(5, 7) === end.slice(5, 7) ? `${+start.slice(8)}–${+end.slice(8)} ${m(end)}` : `${+start.slice(8)} ${m(start)}–${+end.slice(8)} ${m(end)}`;
  }
  const a = `${+start.slice(8)}.${+start.slice(5, 7)}.`, b = `${+end.slice(8)}.${+end.slice(5, 7)}.`;
  return start.slice(5, 7) === end.slice(5, 7) ? `${+start.slice(8)}.–${b}` : `${a}–${b}`;
}
/** Navigoinnin rajat: ikkuna alkaa aikaisintaan tänään ja enintään MAX_WEEKS_AHEAD × 7 päivää tästä päivästä. */
export function clampWeek(start, today) {
  const max = addDaysIso(today, WINDOW_DAYS * MAX_WEEKS_AHEAD);
  return start < today ? today : start > max ? max : start;
}
/** Viikonpäivä (1 = ma … 7 = su) ja viikonloppu päivämäärästä, ei sarakkeen järjestyksestä. */
export const dayInfo = (date) => { const wd = weekdayIso(date); return { wd, we: wd >= 6 }; };

/** Hoidon hinta katalogista: per_person → «49 € / hlö»; vaihteleva (from, lisähenkilöt, valinnat) → «alk. 99 €»; muuten kiinteä. kind: per | from | fixed. */
export function carePrice(c, lang = 'fi') {
  if (!c || c.price == null || c.price === '' || !Number.isFinite(+c.price) || +c.price <= 0) return { text: '', kind: '' };
  const text = money(c.price, lang);
  if (c.price_type === 'per_person') return { text, kind: 'per' };
  const extra = Number.isFinite(+c.extra_person_price) && +c.extra_person_price > 0 && c.included_persons != null && c.included_persons !== '';
  const varies = c.price_type === 'from' || /extra|base_plus/.test(String(c.price_type || '')) || extra;
  return { text, kind: varies ? 'from' : 'fixed' };
}

/** Päivän tarjonta (varattavissa): pub = yleinen vuoro, own = oma sauna tai jälkilöyly, care = hoito tai tapahtuma. Täydet eivät ole tarjontaa. */
export const hasOffering = (d, kind) => kind === 'pub' ? d.public.some((g) => !g.full)
  : kind === 'own' ? !!((d.own && !d.own.full) || d.after.some((r) => !r.full))
    : d.care.length > 0 || d.events.some((e) => !e.full);
/** Seuraava päivä i:n jälkeen, jolla on kyseistä tarjontaa → { index, date, wd } tai null (ei harhaanjohtavaa linkkiä, jos ikkunassa ei ole). */
export function nextOffering(days, i, kind) {
  for (let j = i + 1; j < days.length; j++) if (days[j].date && hasOffering(days[j], kind)) return { index: j, date: days[j].date, wd: days[j].wd };
  return null;
}

export const money = (n, lang = 'fi') => (n == null || n === '' || !Number.isFinite(+n) ? '' : new Intl.NumberFormat(lang === 'fi' ? 'fi-FI' : 'en-FI', { style: 'currency', currency: 'EUR', minimumFractionDigits: Number.isInteger(+n) ? 0 : 2 }).format(+n));
const durLabel = (a, b) => {
  const min = Math.round((Date.parse(b) - Date.parse(a)) / 6e4);
  if (!Number.isFinite(min) || min <= 0) return '';
  const hh = Math.floor(min / 60), mm = min % 60;
  return [hh ? `${hh} h` : '', mm ? `${mm} min` : ''].filter(Boolean).join(' ');
};

/** Tuotteen slug/kategoria riviltä; public_availability_all antaa ne, mutta varalla katalogi product_id:llä. */
function resolver(catalog) {
  const byId = new Map((Array.isArray(catalog) ? catalog : []).filter((p) => p && p.id != null).map((p) => [+p.id, p]));
  return (r) => {
    const c = byId.get(+r.product_id);
    return { slug: r.slug || c?.slug || '', category: r.category || c?.category || '', cat: c || null };
  };
}

/**
 * Viikon malli. input:
 *  start        ikkunan ensimmäinen päivä (YYYY-MM-DD), yleensä tänään; 7 peräkkäistä päivää
 *  today, now   Helsingin päivä ja ms
 *  rows         public_availability_all (null = ei haettu)
 *  catalog      public_catalog
 *  care         [{ id, slug, name, name_en, days: Set<YYYY-MM-DD> }] hoitotuotteet vapaine päivineen (null = ei haettu)
 *  events       public_events
 *  offers       public_quiet_offers
 *  hrefs        { product(slug, date), care(slug, date), own, after(rule, date), event(slug, date), eventOpen(slug) }
 */
export function buildWeek({ start, today, now, rows = null, catalog = null, care = null, events = null, offers = null, lang = 'fi', hrefs, careHorizon = CARE_HORIZON_DAYS } = {}) {
  const dates = Array.from({ length: 7 }, (_, i) => addDaysIso(start, i));
  const horizonEnd = addDaysIso(today, careHorizon - 1);
  const resolve = resolver(catalog);
  const name = (r, info) => catalogDisplayName(info.cat, lang) || (lang === 'en' && r.name_en) || r.name || info.slug;
  const list = Array.isArray(rows) ? rows : [];
  const live = (r) => r && /^\d{4}-\d\d-\d\d$/.test(r.session_date || '') && Date.parse(r.ends_at || r.starts_at) > now;
  const days = dates.map((date) => {
    const mine = list.filter((r) => live(r) && r.session_date === date && (r.status === 'available' || r.status === 'full')).map((r) => ({ r, info: resolve(r) }));

    // Yleiset vuorot: vuoroittain (tuote), useampi alkuaika → chips
    const bySlug = new Map();
    for (const x of mine) if (x.info.category === 'public_sauna' && x.info.slug && !HIDDEN_PUBLIC_SLUGS.includes(x.info.slug)) (bySlug.get(x.info.slug) || bySlug.set(x.info.slug, []).get(x.info.slug)).push(x);
    const pub = [...bySlug.entries()].map(([slug, xs]) => {
      xs.sort((a, b) => Date.parse(a.r.starts_at) - Date.parse(b.r.starts_at));
      const first = xs[0].r, last = xs.reduce((m, x) => (Date.parse(x.r.ends_at) > Date.parse(m) ? x.r.ends_at : m), first.ends_at);
      const free = xs.filter((x) => x.r.status === 'available');
      const low = (x) => (x.r.status === 'available' && Number.isFinite(+x.r.remaining) && +x.r.remaining <= 3 ? +x.r.remaining : null);
      const href = hrefs.product(slug, date);
      const g = {
        slug, name: careName(name(first, xs[0].info)), href,
        time: rangeLabel(first.starts_at, last, lang), price: money(first.unit_price ?? first.base_price, lang),
        dur: '', low: null, full: !free.length, chips: [],
      };
      if (xs.length === 1) g.low = low(xs[0]);
      else {
        g.dur = durLabel(first.starts_at, first.ends_at);
        g.chips = xs.map((x) => ({ label: rangeLabel(x.r.starts_at, null, lang), href, full: x.r.status !== 'available', low: low(x) }));
      }
      return { g, t: Date.parse(first.starts_at) };
    }).sort((a, b) => a.t - b.t || a.g.slug.localeCompare(b.g.slug)).map((x) => x.g);

    // Oma saunavuoro: päivän halvin vapaa hinta (hiljaisen ajan ale huomioiden)
    const ownRows = mine.filter((x) => x.info.slug === OWN_SLUG);
    let own = null;
    const ownFree = ownRows.filter((x) => x.r.status === 'available' && Number.isFinite(+x.r.base_price));
    // Oman vuoron kestohaarukka (minuutteina): päivän varattavat oma-saunavuoro-rivit + varattava tunnin vuoro (1 h omana vuorona). Yleisten vuorojen riville tunnin vuoroa ei tuoda.
    const mins = (r) => Math.round((Date.parse(r.ends_at) - Date.parse(r.starts_at)) / 6e4);
    const ownLens = [...ownFree, ...mine.filter((x) => x.info.slug === 'tunnin-vuoro' && x.r.status === 'available')].map((x) => mins(x.r)).filter((n) => Number.isFinite(n) && n > 0);
    if (ownFree.length) {
      const cand = ownFree.map((x) => { const o = offerForSlot(offers, { ...x.r, product_id: x.r.product_id }); return { eff: o ? +o.discounted_price : +x.r.base_price, o, base: +x.r.base_price }; }).sort((a, b) => a.eff - b.eff)[0];
      own = { href: hrefs.product(OWN_SLUG, date), price: money(cand.eff, lang), was: cand.o ? money(cand.base, lang) : '', pct: cand.o ? pctOf(cand.o.percent, lang) : '', full: false, durMin: ownLens.length ? Math.min(...ownLens) : null, durMax: ownLens.length ? Math.max(...ownLens) : null };
    } else if (ownRows.length) own = { href: hrefs.product(OWN_SLUG, date), price: '', was: '', pct: '', full: true, durMin: null, durMax: null };

    // Jälkilöylyt
    const after = mine.filter((x) => +x.r.product_id === JALKIL_ID || x.info.slug === JALKIL_SLUG).sort((a, b) => Date.parse(a.r.starts_at) - Date.parse(b.r.starts_at) || +a.r.rule_id - +b.r.rule_id)
      .map(({ r }) => {
        const full = r.status !== 'available';
        const o = full ? null : offerForSlot(offers, { ...r, product_id: JALKIL_ID });
        return {
          time: rangeLabel(r.starts_at, r.ends_at, lang), price: money(o ? o.discounted_price : r.base_price, lang), was: o ? money(o.base_price, lang) : '', pct: o ? pctOf(o.percent, lang) : '', full,
          href: !full && Number.isFinite(+r.rule_id) ? hrefs.after(r.rule_id, date) : hrefs.product(JALKIL_SLUG, date),
        };
      });

    const careList = (Array.isArray(care) ? care : []).filter((c) => c && c.days?.has(date) && !HIDDEN_CARE_SLUGS.includes(c.slug))
      .map((c) => { const pr = carePrice(c, lang); return { name: careName(catalogDisplayName(c, lang) || c.name), href: hrefs.care(c.slug, date), price: pr.text, priceKind: pr.kind }; });
    const careErr = care == null && date >= today && date <= horizonEnd;   // hoitohaku epäonnistui: solussa lyhyt teksti viivojen sijaan
    return { ...dayInfo(date), date, past: date < today, public: pub, publicNone: Array.isArray(rows) && !pub.length && date >= today, own, ownNone: Array.isArray(rows) && !own && !after.length && date >= today, after, care: careList, careErr, careLater: care != null && date > horizonEnd && !careList.length, events: [] };
  });

  // Tapahtumat samaan soluun kuin hoidot
  const end = dates[WINDOW_DAYS - 1];
  let hasEvents = false;
  for (const ev of asEventList(events)) {
    if (!ev || ev.category !== 'event' || typeof ev.slug !== 'string' || !ev.slug || !ev.name) continue;
    const byDate = new Map();
    for (const o of Array.isArray(ev.occurrences) ? ev.occurrences : []) {
      if (!o || (o.status !== 'available' && o.status !== 'full') || !o.starts_at) continue;
      if (Date.parse(o.ends_at || o.starts_at) <= now) continue;
      const date = ymdHel(o.starts_at);
      if (!date || date < start || date > end) continue;
      (byDate.get(date) || byDate.set(date, []).get(date)).push(o);
    }
    for (const [date, os] of byDate) {
      os.sort((a, b) => String(a.starts_at).localeCompare(String(b.starts_at)));
      const d = days.find((x) => x.date === date);
      const allFull = os.every((o) => o.status === 'full');
      const price = ev.price != null && Number.isFinite(+ev.price) ? money(ev.price, lang) : '';
      d.events.push({
        name: careName(eventDisplayName({ slug: ev.slug, productId: ev.product_id, name: ev.name, nameEn: ev.name_en }, catalog, lang)), price, full: allFull,
        times: os.map((o) => rangeLabel(o.starts_at, o.ends_at, lang, now)).filter(Boolean), href: hrefs.event(ev.slug, date),
      });
      hasEvents = true;
    }
  }
  for (const d of days) d.events.sort((a, b) => a.times[0]?.localeCompare(b.times[0] || '', 'fi') || a.name.localeCompare(b.name, 'fi'));

  // Tyhjä hoitosolu: «Ei tänä päivänä» (ei viivaa), paitsi kun haku epäonnistui tai päivä on hoitoikkunan ulkopuolella
  for (const d of days) d.careNone = !d.careErr && !d.careLater && !d.care.length && !d.events.length && d.date >= today;

  const todayIdx = dates.indexOf(today);
  const cur = weekStartOf(today);
  return {
    start, end, week: isoWeekNumber(start), range: weekRange(start, lang), todayIdx, days, hasEvents,
    careLater: care != null && start > horizonEnd,
    nav: { prev: start > cur, next: start < addDaysIso(cur, WINDOW_DAYS * MAX_WEEKS_AHEAD), now: start !== cur },
    hint: eventHint(events, { after: end, now, lang, hrefs, catalog }), error: false,
  };
}

/** Päiväsolussa tuotenimen lopun sulkuselite ((la & su)) on turha. */
export const careName = (n) => String(n || '').replace(/\s*\([^)]*\)\s*$/, '').trim() || String(n || '');
const pctOf = (p, lang) => { const s = String(+Number(p).toFixed(2)); return lang === 'fi' ? s.replace('.', ',') : s; };

/** Seuraavat (enintään 2) tapahtumaa viikon jälkeen: vihje alareunassa, jos viikolla ei ole tapahtumia. */
export function eventHint(events, { after, now, lang = 'fi', hrefs, catalog = null, limit = 2 } = {}) {
  const out = [];
  for (const ev of homeEventCards(asEventList(events))) {
    if (!ev || ev.category !== 'event' || typeof ev.slug !== 'string' || !ev.slug || !ev.name) continue;
    const occ = (Array.isArray(ev.occurrences) ? ev.occurrences : []).filter((o) => o && (o.status === 'available' || o.status === 'full') && o.starts_at && ymdHel(o.starts_at) > after && Date.parse(o.ends_at || o.starts_at) > now)
      .sort((a, b) => String(a.starts_at).localeCompare(String(b.starts_at)));
    if (!occ.length) continue;
    out.push({
      at: occ[0].starts_at, name: careName(eventDisplayName({ slug: ev.slug, productId: ev.product_id, name: ev.name, nameEn: ev.name_en }, catalog, lang)),
      when: cardDates(occ[0], lang, now), href: hrefs.eventOpen(ev.slug), full: eventIsFull({ occurrences: occ }),
    });
  }
  return out.sort((a, b) => a.at.localeCompare(b.at)).slice(0, limit).map(({ at, ...x }) => x);
}

/** Hoitotuote → { id, slug, name, name_en, price, price_type, …, days } treatments.js:n loadAvailability-vastauksesta (Map<päivä, ajat[]>). */
export const careEntry = (p, byDay) => ({ id: p.id, slug: p.slug, name: p.name, name_en: p.name_en, price: p.price, price_type: p.price_type, included_persons: p.included_persons, extra_person_price: p.extra_person_price, days: new Set(byDay ? [...byDay.keys()].filter((d) => byDay.get(d)?.length) : []) });
