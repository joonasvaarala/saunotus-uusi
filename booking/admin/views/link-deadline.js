// Varausdialogi 04: maksulinkin takarajakytkin. Oletuksena pois. Ei sb.js-riippuvuutta.
import { h } from '../ui.js';
import { orderText as tx } from '../orders-texts.js';
import { LINK_DEADLINE, linkExpiresDays } from '../payment-link-logic.js';

const fld = (name, ...nodes) => h('label', { class: 'fld' }, h('span', { text: name }), ...nodes);

export function linkDeadlineControl() {
  const checked = h('input', { type: 'checkbox', name: 'deadline', 'data-testid': 'link-deadline-toggle' });
  const days = h('input', { type: 'number', name: 'days', 'data-testid': 'link-deadline-days',
    min: LINK_DEADLINE.min, max: LINK_DEADLINE.max, value: LINK_DEADLINE.initial, inputmode: 'numeric', disabled: true });
  const field = fld(tx('ui.admin.orders.link_deadline_days'), days);
  field.classList.add('pl-days'); field.hidden = true;
  checked.addEventListener('change', () => { field.hidden = !checked.checked; days.disabled = !checked.checked; });
  const nodes = h('div', { class: 'pl-deadline' },
    h('label', { class: 'pl-toggle' }, checked, h('span', { text: tx('ui.admin.orders.link_set_deadline') })),
    h('p', { class: 'muted', text: tx('ui.admin.orders.link_deadline_help') }), field);
  return {
    nodes,
    read(fd) {
      const result = linkExpiresDays({ enabled: fd.has('deadline'), days: fd.get('days') });
      if (!result.ok) throw new Error(tx('ui.admin.orders.link_deadline_bad', LINK_DEADLINE));
      return result.expiresDays;
    },
  };
}
