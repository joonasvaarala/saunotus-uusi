// Etusivun ja saunavuorot-sivun viikko-ohjelma: näkymä. Sama puu piirretään kahdella tavalla:
//  - toHtml: rakennusvaihe (src/week-grid.mjs), staattinen varaversio ilman JS:ää
//  - toDom: selain (week-grid.js), createElement + textContent, ei innerHTML:ää (kaikki tekstit tulevat RPC-vastauksista)
// Rakenne on päiväkohtainen: .vk-day-sarakkeessa on yleiset vuorot, oma sauna, hoidot ja rituaalit (tapahtumat tässä solussa).
// Työpöydällä päivät ovat sarakkeina ja palvelut riveinä (CSS subgrid), mobiilissa yksi päivä kerrallaan (päivänauha).
// Ei tunnin vuoroa, ei Saunotusrituaalia sellaisenaan, ei Yrityksille-riviä, ei tiivis/laaja-valitsinta. Rajaukset: week-grid-logic.js.
import { fillText } from './quiet-offers-logic.js';
import { nextOffering } from './week-grid-logic.js';

/** Virtuaalisolmu: { t: tagi, a: attribuutit, c: lapset }. Merkkijono = teksti. */
export const h = (t, a, ...c) => ({ t, a: a || {}, c: c.flat(Infinity).filter((x) => x != null && x !== false && x !== '') });

const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' };
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ESC[c]);
const attrs = (a) => Object.entries(a).filter(([, v]) => v != null && v !== false).map(([k, v]) => (v === true ? ` ${k}` : ` ${k}="${esc(v)}"`)).join('');

export function toHtml(n) {
  if (n == null || n === false) return '';
  if (typeof n === 'string' || typeof n === 'number') return esc(n);
  return `<${n.t}${attrs(n.a)}>${n.c.map(toHtml).join('')}</${n.t}>`;
}

export function toDom(doc, n) {
  if (typeof n === 'string' || typeof n === 'number') return doc.createTextNode(String(n));
  const el = doc.createElement(n.t);
  for (const [k, v] of Object.entries(n.a)) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else el.setAttribute(k, v === true ? '' : String(v));
  }
  for (const c of n.c) el.append(toDom(doc, c));
  return el;
}

const sr = (...c) => h('span', { class: 'sr' }, ...c);
const link = (cls, href, label, ...c) => h('a', { class: cls, href, target: '_blank', rel: 'noopener', ...(label ? { 'aria-label': label } : {}) }, ...c);
const nbsp = (s) => String(s).replace(/ /g, ' ');

/** Viikonpäivän lyhenne päivän omasta wd:stä (1 = ma … 7 = su), ei sarakkeen indeksistä. */
const dayShort = (T, wd) => String(T.daysLong[wd - 1]).slice(0, T.lang === 'en' ? 3 : 2);
const EN_MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
/** FI 16.11., EN 16 Nov. */
export const dayMonth = (ds, lang = 'fi') => (ds ? (lang === 'en' ? `${+ds.slice(8)} ${EN_MONTHS[+ds.slice(5, 7) - 1]}` : `${+ds.slice(8)}.${+ds.slice(5, 7)}.`) : '');

const leftText = (T, n) => (n === 1 ? T.leftOne : fillText(T.leftMany, { n }));

// Yksi korttimalli kaikille kolmelle palveluriville (yleiset vuorot, oma sauna ja jälkilöylyt, hoidot ja tapahtumat):
//   ylärivi: nimi ……………… hinta
//   alarivi: aika ja kesto … tila (Täynnä / n jäljellä), ale (−20 % ja yliviivattu hinta) tai Tapahtuma-merkki
// Rivin erottaa vain vasemman reunan väri (sama kuin päivänauhan merkissä) ja rivin otsikko; rakenne, koko ja typografia ovat samat.
// Ilman hrefiä (täysi aika tai alkuajat siruina) kortti on div, muuten koko kortti on linkki.
function card(cls, href, label, { name, price = null, times = [], dur = '', state = null, more = null }) {
  const detail = [...times.map((t) => h('span', { class: 'vk-t' }, t)), dur ? h('span', { class: 'vk-dur' }, nbsp(dur)) : null];
  const c = [h('span', { class: 'vk-n' }, name), price ? h('span', { class: 'vk-p' }, price) : null,
    detail.some(Boolean) ? h('span', { class: 'vk-d' }, detail) : null, state ? h('span', { class: 'vk-s' }, state) : null, more];
  return href ? link(`vk-card ${cls}`, href, label, ...c) : h('div', { class: `vk-card ${cls}` }, ...c);
}
/** Hinta: «alk. 250 €», «29 € / hlö» tai «144 €». */
const priceOf = (T, price, kind) => (price ? [kind === 'from' ? `${T.from} ` : '', h('b', {}, nbsp(price)), kind === 'per' ? ` ${T.per}` : ''] : null);
const fullWord = (T) => h('b', { class: 'vk-fullword' }, T.full);
/** Hiljaisen ajan ale: merkki + normaalihinta yliviivattuna (ruudunlukija saa saman linkin nimestä). */
const sale = (T, vars) => h('span', { class: 'vk-was', 'aria-hidden': 'true' }, h('span', { class: 'vk-sale' }, fillText(T.quietBadge, vars)), h('s', {}, nbsp(vars.was)));

function publicGroup(g, T, dayName) {
  const label = `${g.name}, ${dayName}`;
  const cls = `vk-pub${g.full ? ' is-full' : g.low != null ? ' is-low' : ''}`;
  const body = { name: g.name, price: priceOf(T, g.price, 'per'), times: [g.time], dur: g.dur, state: g.full ? fullWord(T) : g.low != null ? h('span', { class: 'vk-low' }, leftText(T, g.low)) : null };
  if (!g.chips.length) return card(cls, g.full ? null : g.href, `${g.time} ${label} ${T.newTab}`.trim(), body);
  // Useampi alkuaika: kortti ei ole linkki, sirut ovat
  return card(cls, null, null, { ...body, more: h('span', { class: 'vk-chips' }, g.chips.map((c) => {
    if (c.full) return h('span', { class: 'vk-chip is-full' }, c.label, sr(`, ${T.full}`));   // ei linkkiä täydelle ajalle
    return link(`vk-chip${c.low != null ? ' is-low' : ''}`, c.href, `${c.label}, ${label}${c.low != null ? `, ${leftText(T, c.low)}` : ''} ${T.newTab}`,
      c.label, c.low != null ? h('span', { class: 'vk-left' }, fillText(T.leftChip, { n: c.low })) : null);
  })) });
}

/** Tunnit tekstinä: 1, 7, 1,5 (FI pilkku). */
const hoursText = (min, lang) => { const s = String(+(min / 60).toFixed(2)); return lang === 'fi' ? s.replace('.', ',') : s; };
/** Oman vuoron kestohaarukka: «1–7 h» (useampi pituus) tai «2 h» (yksi pituus); tyhjä, jos pituuksia ei tiedetä. */
export function ownDuration(o, T) {
  if (!o || !(o.durMin > 0)) return '';
  const a = hoursText(o.durMin, T.lang);
  if (!(o.durMax > o.durMin)) return fillText(T.durOne, { n: a });
  return fillText(T.durRange, { a, b: hoursText(o.durMax, T.lang) });
}

function ownBlock(day, T, dayName) {
  const o = day.own, rows = day.after;
  if (!o && !rows.length) return null;
  const parts = [];
  if (o) {
    const dur = o.full ? '' : ownDuration(o, T);
    parts.push(card(`vk-oma${o.full ? ' is-full' : ''}`, o.full ? null : o.href, `${T.own}, ${dayName}${o.price ? `, ${T.from} ${o.price}${dur ? `, ${dur}` : ''}` : ''} ${T.newTab}`,
      { name: T.own, price: priceOf(T, o.price, 'from'), dur, state: o.full ? fullWord(T) : o.pct ? sale(T, { pct: o.pct, was: o.was }) : null }));
  }
  // Jälkilöylyt: jokainen aika on oma korttinsa (nimi + aika), kuten yleiset vuorot
  for (const r of rows) {
    const vars = { pct: r.pct, was: r.was, now: r.price };
    parts.push(card(`vk-line${r.full ? ' is-full' : ''}${r.pct ? ' is-quiet' : ''}`, r.full ? null : r.href,
      `${T.after}, ${dayName}, ${r.time}, ${r.pct ? fillText(T.quietSr, vars) : r.price} ${T.newTab}`,
      { name: T.after, price: priceOf(T, r.price), times: [r.time], state: r.full ? fullWord(T) : r.pct ? sale(T, vars) : null }));
  }
  return parts;
}

/** Tyhjän rivin teksti + (vain mobiilissa) painike seuraavaan päivään, jolla on kyseistä tarjontaa. Ikkunassa ei seuraavaa → pelkkä teksti. */
function emptyCell(text, jump, T, model) {
  const label = jump ? `${T.nextWith ? fillText(T.nextWith, { day: shortName(T, jump.wd), date: dayMonth(jump.date, T.lang) }) : ''}` : '';
  return [text, jump ? h('button', { type: 'button', class: 'vk-jump', 'data-vk-pick': jump.index }, label, h('span', { 'aria-hidden': 'true' }, ' →')) : null];
}
const shortName = (T, wd) => (T.lang === 'en' ? dayShort(T, wd) : dayShort(T, wd).toLowerCase());

// Tapahtumat näytetään aina (myös kun hoitoja ei ole tai jakso on hoitoikkunan ulkopuolella); «hoitojen ajat avautuvat» -teksti on vain tyhjässä solussa ja palvelurivin otsikossa.
function careBlock(day, T, dayName, jump) {
  const out = [];
  if (day.careErr && !day.care.length) out.push(h('p', { class: 'vk-care-err', role: 'status' }, T.careError));
  for (const c of day.care) {
    out.push(card('vk-cl', c.href, `${c.name}, ${dayName}${c.price ? `, ${c.priceKind === 'from' ? `${T.from} ` : ''}${c.price}${c.priceKind === 'per' ? ` ${T.per}` : ''}` : ''} ${T.newTab}`,
      { name: c.name, price: priceOf(T, c.price, c.priceKind) }));
  }
  for (const ev of day.events) {
    // Täysi tapahtuma pysyy linkkinä: tapahtuman sivulla on jonotus (booking_210); «Täynnä, jonoon» kerrotaan tekstinä.
    out.push(card(`vk-evt${ev.full ? ' is-full' : ''}`, ev.href, `${T.eventTag}: ${ev.name}, ${dayName}${ev.full ? `, ${T.full}, ${T.evFull}` : ''} ${T.newTab}`,
      { name: ev.name, price: priceOf(T, ev.price, 'per'), times: ev.times, state: [h('span', { class: 'vk-tag' }, T.eventTag), ev.full ? fullWord(T) : null] }));
  }
  if (out.length) return out;
  if (day.careLater) return h('p', { class: 'vk-none' }, T.careLater);
  // Ei viivaa: himmeä teksti (työpöydällä lyhyt, mobiilipaneelissa täysi lause + linkki seuraavaan päivään)
  return h('p', { class: 'vk-none' }, h('span', { class: 'vk-none-d' }, T.noneDay), h('span', { class: 'vk-none-m' }, emptyCell(T.noneCare, jump, T)));
}

const LANES = [
  { k: 'pub', dot: 'pub', name: 'laneP', note: 'noteP' },
  { k: 'priv', dot: 'priv', name: 'laneO', note: 'noteO' },
  { k: 'care', dot: 'treat', name: 'laneC', note: 'noteC' },
];

function dayColumn(day, i, T, model, sel) {
  const dayName = T.daysLong[day.wd - 1];
  const today = model.todayIdx === i;
  const none = (txt, kind) => h('p', { class: 'vk-none' }, emptyCell(txt, nextOffering(model.days, i, kind), T));
  const pubCell = day.public.length ? day.public.map((g) => publicGroup(g, T, dayName)) : (day.publicNone ? none(T.none, 'pub') : h('span', { class: 'vk-dash', 'aria-hidden': 'true' }, '–'));
  const own = ownBlock(day, T, dayName);
  const ownCell = own || (day.ownNone ? none(T.noneOwn, 'own') : h('span', { class: 'vk-dash', 'aria-hidden': 'true' }, '–'));
  // Staattisessa varaversiossa (ei päivämääriä) tyhjä hoitosolu on tyhjä teksti; elävässä näkymässä tila tulee mallista (careNone / careLater / careErr)
  const care = careBlock(day, T, dayName, nextOffering(model.days, i, 'care'));
  const cell = (k, label, dot, body, empty) => h('div', { class: `vk-cell vk-${k}c${empty ? ' empty' : ''}` }, h('h4', { class: 'vk-lh' }, h('i', { class: dot, 'aria-hidden': 'true' }), label), body);
  return h('li', { class: `vk-day${day.we ? ' we' : ''}${today ? ' is-today' : ''}${day.past ? ' is-past' : ''}${sel === i ? ' is-on' : ''}`, 'data-vk-day': i, ...(today ? { 'aria-current': 'date' } : {}) },
    h('h3', { class: 'vk-dh', tabindex: '-1' }, h('span', {}, dayName), day.date ? h('b', {}, dayMonth(day.date, T.lang)) : null, today ? h('em', { class: 'vk-today' }, T.today) : null),
    cell('pub', T.laneP, 'pub', pubCell, !day.public.length),
    cell('priv', T.laneO, 'priv', ownCell, !own),
    cell('care', T.laneC, 'treat', care, false));
}

/** Otsikko: aina perusotsikko («Tulevat päivät saunalla»); ikkuna on liukuva, joten viikkonumeroa ei näytetä. */
export const headingTitle = (model, T, hd) => hd.title;

/** Päivänauhan painikkeen ruudunlukijanimi: «Sunnuntai 15.11., tänään: Yleiset vuorot, Oma sauna». */
export function tabLabel(d, i, T, model) {
  const kinds = [d.public.length && T.laneP, (d.own || d.after.length) && T.laneO, (d.care.length || d.events.length) && T.laneC].filter(Boolean);
  const head = `${T.daysLong[d.wd - 1]} ${dayMonth(d.date, T.lang)}`.trim();
  return `${head}${model.todayIdx === i ? `, ${String(T.today).toLowerCase()}` : ''}: ${kinds.length ? kinds.join(', ') : T.tabNone}`;
}

/** Koko viikko-ohjelman sisältö (.vk-elementin lapset). opt: { heading, links:{training,all}|null, selected } */
export function weekGridTree(model, T, opt = {}) {
  const sel = Number.isInteger(opt.selected) ? opt.selected : (model.todayIdx >= 0 ? model.todayIdx : 0);
  const last = model.days.length - 1;
  // Päivämääräväli näkyy vain tässä, nuolten välissä
  const nav = h('nav', { class: 'vk-nav', 'aria-label': T.weekNav },
    h('button', { type: 'button', class: 'vk-arrow', 'data-vk-nav': 'prev', 'aria-label': model.nav.prev ? T.prev : T.prevOff, disabled: model.nav.prev ? null : true }, h('span', { 'aria-hidden': 'true' }, '‹')),
    h('span', { class: 'vk-wk', 'aria-live': 'polite' }, model.range),
    h('button', { type: 'button', class: 'vk-arrow', 'data-vk-nav': 'next', 'aria-label': model.nav.next ? T.next : T.nextOff, disabled: model.nav.next ? null : true }, h('span', { 'aria-hidden': 'true' }, '›')),
    model.nav.now ? h('button', { type: 'button', class: 'vk-now', 'data-vk-nav': 'now' }, T.now) : null);
  const hd = opt.heading;
  const head = h('div', { class: 'vk-head' }, hd ? h('header', {}, hd.kicker ? h('p', { class: 'kicker' }, hd.kicker) : null, h('h2', { class: 'sec-title' }, headingTitle(model, T, hd))) : null, nav);
  const strip = h('div', { class: 'vk-strip', role: 'group', 'aria-label': T.weekNav }, model.days.map((d, i) => h('button', {
    type: 'button', class: `vk-tab${i === sel ? ' is-on' : ''}${i === model.todayIdx ? ' is-today' : ''}`, 'data-vk-pick': i, disabled: d.past ? true : null, 'aria-pressed': i === sel ? 'true' : 'false',
    ...(i === model.todayIdx ? { 'aria-current': 'date' } : {}), 'aria-label': tabLabel(d, i, T, model),
  }, h('span', { 'aria-hidden': 'true' }, dayShort(T, d.wd)), h('b', { 'aria-hidden': 'true' }, d.date ? String(+d.date.slice(8)) : ''),
  h('i', { class: 'vk-dots', 'aria-hidden': 'true' }, [d.public.length && 'pub', (d.own || d.after.length) && 'priv', (d.care.length || d.events.length) && 'treat'].filter(Boolean).map((k) => h('em', { class: k }))))));
  // Nauhan selite (vain mobiili): sama kolmikko kuin pisteissä
  const stripKey = h('p', { class: 'vk-key' }, LANES.map((l) => h('span', {}, h('i', { class: l.dot, 'aria-hidden': 'true' }), T[l.name])));
  const lanes = h('div', { class: 'vk-lanes', 'aria-hidden': 'true' }, h('div', { class: 'vk-corner' }),
    LANES.map((l) => h('div', { class: `vk-lane vk-${l.k}h` }, h('i', { class: l.dot }), h('b', {}, T[l.name]), h('span', {}, model.careLater && l.k === 'care' ? T.careLater : T[l.note]))));
  const days = h('ol', { class: 'vk-days', 'data-vk-sel': sel }, h('li', { class: 'vk-lanes-li', 'aria-hidden': 'true' }, lanes), model.days.map((d, i) => dayColumn(d, i, T, model, sel)));
  // Selite ruudukon alle: Vapaa · Vähän jäljellä · Täynnä (muoto + teksti, ei pelkkä väri)
  const legend = h('ul', { class: 'vk-legend' }, h('li', {}, h('i', { class: 'vk-sw is-free', 'aria-hidden': 'true' }), T.legFree), h('li', {}, h('i', { class: 'vk-sw is-low', 'aria-hidden': 'true' }), T.legLow), h('li', {}, h('i', { class: 'vk-sw is-full', 'aria-hidden': 'true' }), T.full));
  // Paneelin alle (mobiili): edellinen / seuraava päivä
  const step = (dir, label, off) => h('button', { type: 'button', class: `vk-step vk-step-${dir < 0 ? 'prev' : 'next'}`, 'data-vk-step': dir, disabled: off ? true : null }, dir < 0 ? [h('span', { 'aria-hidden': 'true' }, '‹ '), label] : [label, h('span', { 'aria-hidden': 'true' }, ' ›')]);
  const daynav = h('div', { class: 'vk-daynav' }, step(-1, T.dayPrev, sel <= 0), step(1, T.dayNext, sel >= last));
  const foot = [];
  if (model.error) foot.push(h('p', { class: 'vk-error', role: 'status' }, T.error));
  const hint = model.hint.length && !model.hasEvents
    ? h('p', { class: 'vk-hint' }, h('b', {}, T.evLabel), ` ${T.evNone} ${T.evNext} `, model.hint.flatMap((x, i) => [i ? ` ${T.evAnd} ` : '', link('', x.href, `${x.name} ${x.when} ${T.newTab}`, `${x.name} ${x.when}`), x.full ? ` (${T.evFull})` : '']))
    : null;
  const links = opt.links ? h('div', { class: 'vk-foot-links' }, h('a', { class: 'btn light sm', href: opt.links.training, target: '_blank', rel: 'noopener' }, T.training, h('span', { class: 'vk-ext', 'aria-hidden': 'true' }, ' ↗'), T.newTab ? sr(` ${T.newTab}`) : null), opt.links.all ? h('a', { class: 'btn light sm', href: opt.links.all }, T.all) : null) : null;
  return [head, strip, stripKey, h('div', { class: 'vk-scroll' }, days), daynav, legend, h('div', { class: 'vk-foot' }, hint, links, foot)];
}
