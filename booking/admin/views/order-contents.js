// Hallinnan tilausnäkymän "mitä ostettiin" -osio: varaukset (aika, henkilöt, lisäpalvelut) ja muut tilausrivit
// (lahjakortti, tuote, vapaa rivi, kulu, alennus). Logiikka: ../order-lines-logic.js, tekstit: ../talous-texts.js (order.*, lineKind.*).
import { h } from '../ui.js';
import { t, fmt, getLang } from '../talous-i18n.js';
import { formatWhenRange, spansDays } from '../when-range.js';
import { orderContents } from '../order-lines-logic.js';

const emptyBox = (text) => h('p', { class: 'empty tl-empty', role: 'status', text });

export function reservationList(reservations) {
  return h('ul', { class: 'tl-sub', 'data-testid': 'order-reservations' }, reservations.map((r) => h('li', {},
    h('span', { class: 'tl-sub-main' }, h('strong', { text: r.product_name || '–' }), r.status === 'cancelled' ? h('span', { class: 'badge st-cancelled', text: t('cancelled') }) : null),
    h('span', { class: 'tl-sub-meta', text: `${spansDays(r.starts_at, r.ends_at) ? formatWhenRange(r.starts_at, r.ends_at, getLang()) : fmt.dt(r.starts_at)} · ${t('persons', { n: r.persons ?? 1 })}${r.addons?.length ? ' · ' + r.addons.map((a) => `${a.name} ×${a.quantity}`).join(', ') : ''}` }),
    h('span', { class: 'tl-sub-sum' }, h('strong', { text: fmt.money(r.item_total) })))));
}

export const lineMeta = (l) => [t(`lineKind.${l.kind}`), l.quantity === 1 ? t('order.qty', { n: fmt.int(l.quantity) }) : t('order.qtyUnit', { n: fmt.int(l.quantity), price: fmt.money(l.unit_price) })].join(' · ');

export function lineList(lines) {
  return h('ul', { class: 'tl-sub', 'data-testid': 'order-items' }, lines.map((l) => h('li', { 'data-kind': l.kind, 'data-item-id': l.id },
    h('span', { class: 'tl-sub-main' }, h('strong', { text: l.name || t(`lineKind.${l.kind}`) })),
    h('span', { class: 'tl-sub-meta', text: lineMeta(l) }),
    h('span', { class: 'tl-sub-sum' }, h('strong', { text: fmt.money(l.line_total) })))));
}

// sec(title, ...kids) on talous-orders.js:n osiorakentaja. Palauttaa aina osion (myös tyhjän tilauksen tyhjätilan).
export function orderContentsSection(o, sec) {
  const c = orderContents(o);
  const section = sec(t(c.titleKey), c.reservations.length ? reservationList(c.reservations) : null, c.lines.length ? lineList(c.lines) : null, c.emptyKey ? emptyBox(t(c.emptyKey)) : null);
  section.setAttribute('data-testid', 'order-contents');
  return section;
}
