// Oman saunavuoron kaksivaiheinen valinta: 1) aloitusaika, 2) kesto valitulle alulle. Kaikki rivit ovat jo olemassa olevia vuoroja (ei uutta hakua);
// varauslinkki on sama /varaa/{rule_id}/{date}/{product_id} kuin ennen. Tyylit: olemassa olevat .bk-times/.bk-time-btn, .bk-slotlist/.bk-slot, .btn.sm, .bk-note.
// Riippuvuudet annetaan sisään (h, t, money, hm, dur, …), jotta näkymää voi testata ilman selainta.
import { groupSlotsByStart, startsWithFree, sharedIncluded, durationMinutes } from './slot-groups.js';

const rowOf = (x) => x.r || x;

export function createSlotPicker({ h, t, money, hm, dur, href, badge = () => null, priceAttrs = () => ({}), legacyItem, idPrefix = 'bk-sp' }) {
  let cur = { ds: null, start: null };   // päivän vaihto nollaa alkuvalinnan
  let seq = 0;
  const priceText = (r, shared) => (r.price_mode === 'per_person' ? `${money(r.unit_price)} ${t.perPerson}` : r.price_mode === 'fixed' ? money(r.base_price)
    : shared ? money(r.base_price) : `${money(r.base_price)} (${t.included(r.included_persons)}, ${t.extra(money(r.extra_person_price))})`);

  /** Palauttaa säiliön; valinnat piirtävät sen sisällön uudelleen ja siirtävät kohdistuksen. */
  function view(rows, ds, p) {
    if (cur.ds !== ds) cur = { ds, start: null };
    const groups = groupSlotsByStart(rows), starts = startsWithFree(groups), id = `${idPrefix}-${++seq}`;
    const box = h('div', { class: 'bk-slotpick', 'data-testid': 'slot-picker' });
    const paint = (focus) => {
      const g = cur.start != null ? starts.find((x) => x.key === cur.start) : null;
      if (cur.start != null && !g) cur.start = null;
      const { nodes, focusEl } = g ? durationStep(g) : startStep();
      box.replaceChildren(...nodes);
      if (focus) (focus === 'heading' ? focusEl.heading : focusEl.start)?.focus?.();
    };
    function startStep() {
      if (!starts.length) {   // ei vapaita kestoja: selvä teksti; mahdolliset täynnä-vuorot jäävät entiseen jonolistaan (ei tyhjää listaa)
        const full = groups.flatMap((x) => x.slots);
        return { nodes: [h('p', { class: 'bk-note', role: 'status', 'data-testid': 'slot-picker-none', text: t.slotNoFreeDurations }), full.length ? h('ul', { class: 'bk-slotlist' }, full.map((x) => legacyItem(rowOf(x), ds))) : null], focusEl: {} };
      }
      const heading = h('h4', { id: `${id}-h`, text: t.slotStartTitle });
      let back = null;
      const btns = starts.map((x) => {
        const b = h('button', { type: 'button', class: 'bk-time-btn', 'data-start': hm(x.start), 'aria-pressed': 'false', onclick: () => { cur.start = x.key; paint('heading'); } }, hm(x.start));
        if (x.key === cur.backTo) back = b;
        return h('li', {}, b);
      });
      return { nodes: [heading, h('p', { class: 'bk-note', text: t.slotStartLead }), h('ul', { class: 'bk-times', role: 'group', 'aria-labelledby': `${id}-h`, 'data-testid': 'slot-starts' }, btns)], focusEl: { start: back } };
    }
    function durationStep(g) {
      const startTxt = hm(g.start), shared = sharedIncluded(g.free), heading = h('h4', { id: `${id}-h`, tabindex: '-1', 'data-testid': 'slot-duration-title', text: t.slotDurationTitle.replace('{start}', startTxt) });
      const items = g.free.map((x) => {
        const r = rowOf(x), time = `${hm(r.starts_at)}–${hm(r.ends_at)}`, d = dur(durationMinutes(r));
        return h('li', { class: `bk-slot ${r.status}`, 'data-rule': r.rule_id },
          h('div', { class: 'bk-slot-main' }, h('strong', { class: 'bk-time', text: d }), h('span', { class: 'bk-sub', text: time }), h('span', { class: 'bk-price', text: priceText(r, shared), ...priceAttrs(r) })),
          h('div', { class: 'bk-slot-side' }, badge(r), h('a', { class: 'btn sm', href: href(r, ds) }, t.choose, h('span', { class: 'sr', text: ` ${d}, ${time}` }))));
      });
      const back = h('button', { type: 'button', class: 'btn sm light', 'data-testid': 'slot-change-start', text: t.slotChangeStart, onclick: () => { cur.backTo = cur.start; cur.start = null; paint('start'); } });
      return { nodes: [heading, h('ul', { class: 'bk-slotlist', 'aria-labelledby': `${id}-h` }, items),
        shared ? h('p', { class: 'bk-note', 'data-testid': 'slot-included', text: `${t.included(shared.included)}, ${t.extra(money(shared.extra))}` }) : null, h('p', {}, back)], focusEl: { heading } };
    }
    paint(false);
    return box;
  }
  return { view };
}
