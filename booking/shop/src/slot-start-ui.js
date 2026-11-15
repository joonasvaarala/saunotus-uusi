// Oman saunavuoron kaksivaiheinen valinta: 1) aloitusaika (napit aina näkyvissä, ensimmäinen vapaa esivalittu), 2) kesto valitulle alulle. Kaikki rivit ovat jo olemassa olevia vuoroja (ei uutta hakua);
// varauslinkki on sama /varaa/{rule_id}/{date}/{product_id} kuin ennen. Tyylit: olemassa olevat .bk-times/.bk-time-btn, .bk-slotlist/.bk-slot, .btn.sm, .bk-note.
// Riippuvuudet annetaan sisään (h, t, money, hm, dur, …), jotta näkymää voi testata ilman selainta.
import { groupSlotsByStart, startsWithFree, sharedIncluded, durationMinutes } from './slot-groups.js';

const rowOf = (x) => x.r || x;

export function createSlotPicker({ h, t, money, hm, dur, href, badge = () => null, priceAttrs = () => ({}), legacyItem, idPrefix = 'bk-sp' }) {
  let cur = { ds: null, start: null };   // päivän vaihto nollaa alkuvalinnan
  let seq = 0;
  const priceText = (r, shared) => (r.price_mode === 'per_person' ? `${money(r.unit_price)} ${t.perPerson}` : r.price_mode === 'fixed' ? money(r.base_price)
    : shared ? money(r.base_price) : `${money(r.base_price)} (${t.included(r.included_persons)}, ${t.extra(money(r.extra_person_price))})`);

  /** Palauttaa säiliön: alkunapit näkyvät aina, niiden alla valitun alun kestolista. Alun vaihto = yksi napautus (nappirivi ja kohdistus pysyvät). */
  function view(rows, ds, p) {
    if (cur.ds !== ds) cur = { ds, start: null };
    const groups = groupSlotsByStart(rows), starts = startsWithFree(groups), id = `${idPrefix}-${++seq}`;
    const box = h('div', { class: 'bk-slotpick', 'data-testid': 'slot-picker' });
    if (!starts.length) {   // ei vapaita kestoja: selvä teksti; mahdolliset täynnä-vuorot jäävät entiseen jonolistaan (ei tyhjää listaa)
      const full = groups.flatMap((x) => x.slots);
      box.append(h('p', { class: 'bk-note', role: 'status', 'data-testid': 'slot-picker-none', text: t.slotNoFreeDurations }), full.length ? h('ul', { class: 'bk-slotlist' }, full.map((x) => legacyItem(rowOf(x), ds))) : null);
      return box;
    }
    if (!starts.some((x) => x.key === cur.start)) cur.start = starts[0].key;   // esivalinta: ensimmäinen vapaa alku
    const out = h('div', { id: `${id}-d`, 'data-testid': 'slot-durations', 'aria-live': 'polite' });
    const btns = starts.map((x) => h('button', { type: 'button', class: 'bk-time-btn', 'data-start': hm(x.start), 'aria-pressed': String(x.key === cur.start), 'aria-controls': `${id}-d`, onclick: () => select(x.key) }, hm(x.start)));
    function select(key) {
      cur.start = key;
      starts.forEach((x, i) => { btns[i].setAttribute('aria-pressed', String(x.key === key)); });
      paintDurations();
    }
    function paintDurations() { out.replaceChildren(...durationStep(starts.find((x) => x.key === cur.start))); }
    function durationStep(g) {
      const startTxt = hm(g.start), shared = sharedIncluded(g.free), heading = h('h4', { id: `${id}-h`, 'data-testid': 'slot-duration-title', text: t.slotDurationTitle.replace('{start}', startTxt) });
      const items = g.free.map((x) => {
        const r = rowOf(x), time = `${hm(r.starts_at)}–${hm(r.ends_at)}`, d = dur(durationMinutes(r));
        return h('li', { class: `bk-slot ${r.status}`, 'data-rule': r.rule_id },
          h('div', { class: 'bk-slot-main' }, h('strong', { class: 'bk-time', text: d }), h('span', { class: 'bk-sub', text: time }), h('span', { class: 'bk-price', text: priceText(r, shared), ...priceAttrs(r) })),
          h('div', { class: 'bk-slot-side' }, badge(r), h('a', { class: 'btn sm', href: href(r, ds) }, t.choose, h('span', { class: 'sr', text: ` ${d}, ${time}` }))));
      });
      return [heading, h('ul', { class: 'bk-slotlist', 'aria-labelledby': `${id}-h` }, items),
        shared ? h('p', { class: 'bk-note', 'data-testid': 'slot-included', text: `${t.included(shared.included)}, ${t.extra(money(shared.extra))}` }) : null];
    }
    const heading = h('h4', { id: `${id}-s`, text: t.slotStartTitle });
    box.append(heading, h('p', { class: 'bk-note', text: t.slotStartLead }), h('ul', { class: 'bk-times', role: 'group', 'aria-labelledby': `${id}-s`, 'data-testid': 'slot-starts' }, btns.map((b) => h('li', {}, b))), out);
    paintDurations();
    return box;
  }
  return { view };
}
