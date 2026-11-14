// Etusivun ja saunavuorot-sivun viikko-ohjelma: näkymä. Sama puu piirretään kahdella tavalla:
//  - toHtml: rakennusvaihe (src/week-grid.mjs), staattinen varaversio ilman JS:ää
//  - toDom: selain (week-grid.js), createElement + textContent, ei innerHTML:ää (kaikki tekstit tulevat RPC-vastauksista)
// Rakenne on päiväkohtainen: .vk-day-sarakkeessa on yleiset vuorot, oma sauna, hoidot ja rituaalit (tapahtumat tässä solussa).
// Työpöydällä päivät ovat sarakkeina ja palvelut riveinä (CSS subgrid), mobiilissa yksi päivä kerrallaan (päivänauha).
// Ei tunnin vuoroa, ei Saunotusrituaalia sellaisenaan, ei Yrityksille-riviä, ei tiivis/laaja-valitsinta. Rajaukset: week-grid-logic.js.
import { fillText } from './quiet-offers-logic.js';

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

const dayShort = (T, i) => String(T.daysLong[i]).slice(0, T.lang === 'en' ? 3 : 2);
const dayMonth = (ds) => (ds ? `${+ds.slice(8)}.${+ds.slice(5, 7)}.` : '');

function publicGroup(g, T, dayName) {
  const meta = [g.price ? [h('b', {}, nbsp(g.price)), ` ${T.per}`] : '', g.dur ? `${g.price ? ' · ' : ''}${g.dur}` : '', g.low != null ? [' · ', h('span', { class: 'vk-low' }, g.low === 1 ? T.leftOne : fillText(T.leftMany, { n: g.low }))] : '', g.full ? ` · ${T.full}` : ''];
  const label = `${g.name}, ${dayName}`;
  const cls = `vk-pub${g.full ? ' is-full' : ''}`;
  if (!g.chips.length) {
    return link(cls, g.href, `${g.time} ${label}${g.full ? `, ${T.full}` : ''} ${T.newTab}`.trim(),
      h('span', { class: 'vk-t' }, g.time), h('span', { class: 'vk-n' }, g.name), h('span', { class: 'vk-m' }, meta));
  }
  return h('div', { class: cls },
    h('span', { class: 'vk-t' }, g.time), h('span', { class: 'vk-n' }, g.name), h('span', { class: 'vk-m' }, meta),
    h('span', { class: 'vk-chips' }, g.chips.map((c) => link(`vk-chip${c.full ? ' is-full' : c.low ? ' is-low' : ''}`, c.href,
      `${c.label}, ${label}${c.full ? `, ${T.full}` : c.low != null ? `, ${c.low === 1 ? T.leftOne : fillText(T.leftMany, { n: c.low })}` : ''} ${T.newTab}`, c.label))));
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
    const price = o.full ? T.full : o.price ? [`${T.from} `, h('b', {}, nbsp(o.price)), dur ? ` · ${nbsp(dur)}` : ''] : null;
    parts.push(link(`vk-oma${o.full ? ' is-full' : ''}`, o.href, `${T.own}, ${dayName}${o.full ? `, ${T.full}` : o.price ? `, ${T.from} ${o.price}${dur ? `, ${dur}` : ''}` : ''} ${T.newTab}`,
      h('span', { class: 'vk-n' }, T.own), h('span', { class: 'vk-m' }, price),
      o.pct ? h('span', { class: 'vk-was', 'aria-hidden': 'true' }, h('span', { class: 'vk-sale' }, fillText(T.quietBadge, { pct: o.pct })), h('s', {}, nbsp(o.was))) : null));
  }
  if (rows.length) {
    parts.push(h('div', { class: 'vk-grp' }, h('span', { class: 'vk-gn' }, T.after), rows.map((r) => {
      const vars = { pct: r.pct, was: r.was, now: r.price };
      return link(`vk-line${r.full ? ' is-full' : ''}${r.pct ? ' is-quiet' : ''}`, r.href,
        `${T.after}, ${dayName}, ${r.time}, ${r.full ? T.full : r.pct ? fillText(T.quietSr, vars) : r.price} ${T.newTab}`,
        h('span', { class: 'vk-lt' }, r.time), h('span', { class: 'vk-lp' }, h('b', {}, nbsp(r.price))),
        r.full ? h('span', { class: 'vk-lf' }, T.full) : null,
        r.pct && !r.full ? h('span', { class: 'vk-was', 'aria-hidden': 'true' }, h('span', { class: 'vk-sale' }, fillText(T.quietBadge, vars)), h('s', {}, nbsp(r.was))) : null);
    })));
  }
  return parts;
}

// Tapahtumat näytetään aina (myös kun hoitoja ei ole tai viikko on hoitoikkunan ulkopuolella); «hoitojen ajat avautuvat» -teksti on vain palvelurivin otsikossa.
function careBlock(day, T, dayName) {
  const out = [];
  if (day.care.length) {
    out.push(h('ul', { class: 'vk-care' }, day.care.map((c) => h('li', {}, link('vk-cl', c.href, `${c.name}, ${dayName} ${T.newTab}`, c.name)))));
  }
  for (const ev of day.events) {
    out.push(link(`vk-evt${ev.full ? ' is-full' : ''}`, ev.href, `${T.eventTag}: ${ev.name}, ${dayName}${ev.full ? `, ${T.full}` : ''} ${T.newTab}`,
      h('span', { class: 'vk-tag' }, T.eventTag), h('span', { class: 'vk-n' }, ev.name),
      ev.price ? h('span', { class: 'vk-m' }, h('b', {}, nbsp(ev.price)), ` ${T.per}`, ev.full ? ` · ${T.full}` : '') : (ev.full ? h('span', { class: 'vk-m' }, T.full) : null),
      ev.times.length ? h('span', { class: 'vk-etimes' }, ev.times.map((t) => h('span', { class: 'vk-et' }, t))) : null));
  }
  return out.length ? out : h('span', { class: 'vk-dash', 'aria-hidden': 'true' }, '–');
}

const LANES = [
  { k: 'pub', dot: 'pub', name: 'laneP', note: 'noteP' },
  { k: 'priv', dot: 'priv', name: 'laneO', note: 'noteO' },
  { k: 'care', dot: 'treat', name: 'laneC', note: 'noteC' },
];

function dayColumn(day, i, T, model, sel) {
  const dayName = T.daysLong[i];
  const today = model.todayIdx === i;
  const pubCell = day.public.length ? day.public.map((g) => publicGroup(g, T, dayName)) : (day.publicNone ? h('p', { class: 'vk-none' }, T.none) : h('span', { class: 'vk-dash', 'aria-hidden': 'true' }, '–'));
  const own = ownBlock(day, T, dayName);
  const care = careBlock(day, T, dayName);
  const cell = (k, label, dot, body, empty) => h('div', { class: `vk-cell vk-${k}c${empty ? ' empty' : ''}` }, h('h4', { class: 'vk-lh' }, h('i', { class: dot, 'aria-hidden': 'true' }), label), body);
  return h('li', { class: `vk-day${i >= 5 ? ' we' : ''}${today ? ' is-today' : ''}${day.past ? ' is-past' : ''}${sel === i ? ' is-on' : ''}`, 'data-vk-day': i, ...(today ? { 'aria-current': 'date' } : {}) },
    h('h3', { class: 'vk-dh' }, h('span', {}, T.daysLong[i]), day.date ? h('b', {}, dayMonth(day.date)) : null, today ? h('em', { class: 'vk-today' }, T.today) : null),
    cell('pub', T.laneP, 'pub', pubCell, !day.public.length),
    cell('priv', T.laneO, 'priv', own || h('span', { class: 'vk-dash', 'aria-hidden': 'true' }, '–'), !own),
    cell('care', T.laneC, 'treat', care, !day.care.length && !day.events.length));
}

/** Otsikko: kuluvalla viikolla (ja staattisessa varaversiossa) perusotsikko, muilla viikoilla viikkonumero. */
export const headingTitle = (model, T, hd) => (model.week && model.nav?.now && T.titleWeek ? fillText(T.titleWeek, { n: model.week }) : hd.title);

/** Koko viikko-ohjelman sisältö (.vk-elementin lapset). opt: { heading, links:{training,all}|null, selected } */
export function weekGridTree(model, T, opt = {}) {
  const sel = Number.isInteger(opt.selected) ? opt.selected : (model.todayIdx >= 0 ? model.todayIdx : 0);
  const nav = h('nav', { class: 'vk-nav', 'aria-label': T.weekNav },
    h('button', { type: 'button', class: 'vk-arrow', 'data-vk-nav': 'prev', 'aria-label': T.prev, disabled: model.nav.prev ? null : true }, '‹'),
    h('span', { class: 'vk-wk', 'aria-live': 'polite' }, model.week ? [h('b', {}, `${T.week} ${model.week}`), ` ${model.range}`] : ''),
    h('button', { type: 'button', class: 'vk-arrow', 'data-vk-nav': 'next', 'aria-label': T.next, disabled: model.nav.next ? null : true }, '›'),
    model.nav.now ? h('button', { type: 'button', class: 'vk-now', 'data-vk-nav': 'now' }, T.now) : null);
  const hd = opt.heading;
  const head = h('div', { class: 'vk-head' }, hd ? h('header', {}, hd.kicker ? h('p', { class: 'kicker' }, hd.kicker) : null, h('h2', { class: 'sec-title' }, headingTitle(model, T, hd))) : null, nav);
  const strip = h('div', { class: 'vk-strip', role: 'group', 'aria-label': T.weekNav }, model.days.map((d, i) => h('button', {
    type: 'button', class: `vk-tab${i === sel ? ' is-on' : ''}${i === model.todayIdx ? ' is-today' : ''}`, 'data-vk-pick': i, disabled: d.past ? true : null, 'aria-pressed': i === sel ? 'true' : 'false',
    'aria-label': `${T.daysLong[i]} ${dayMonth(d.date)}`.trim(),
  }, h('span', { 'aria-hidden': 'true' }, dayShort(T, i)), h('b', { 'aria-hidden': 'true' }, d.date ? String(+d.date.slice(8)) : ''),
  h('i', { class: 'vk-dots', 'aria-hidden': 'true' }, [d.public.length && 'pub', (d.own || d.after.length) && 'priv', (d.care.length || d.events.length) && 'treat'].filter(Boolean).map((k) => h('em', { class: k }))))));
  const lanes = h('div', { class: 'vk-lanes', 'aria-hidden': 'true' }, h('div', { class: 'vk-corner' }),
    LANES.map((l) => h('div', { class: `vk-lane vk-${l.k}h` }, h('i', { class: l.dot }), h('b', {}, T[l.name]), h('span', {}, model.careLater && l.k === 'care' ? T.careLater : T[l.note]))));
  const days = h('ol', { class: 'vk-days', 'data-vk-sel': sel }, h('li', { class: 'vk-lanes-li', 'aria-hidden': 'true' }, lanes), model.days.map((d, i) => dayColumn(d, i, T, model, sel)));
  const foot = [];
  if (model.error) foot.push(h('p', { class: 'vk-error', role: 'status' }, T.error));
  const hint = model.hint.length && !model.hasEvents
    ? h('p', { class: 'vk-hint' }, h('b', {}, T.evLabel), ` ${T.evNone} ${T.evNext} `, model.hint.flatMap((x, i) => [i ? ` ${T.evAnd} ` : '', link('', x.href, `${x.name} ${x.when} ${T.newTab}`, `${x.name} ${x.when}`), x.full ? ` (${T.evFull})` : '']))
    : null;
  const links = opt.links ? h('div', { class: 'vk-foot-links' }, h('a', { class: 'btn light sm', href: opt.links.training, rel: 'noopener' }, T.training, ' →'), opt.links.all ? h('a', { class: 'btn light sm', href: opt.links.all }, T.all) : null) : null;
  return [head, strip, h('div', { class: 'vk-scroll' }, days), h('div', { class: 'vk-foot' }, hint, links, foot)];
}
