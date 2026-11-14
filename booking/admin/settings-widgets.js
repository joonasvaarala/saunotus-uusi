// Asetuskortit ja -kentät (HALL-ASETUKSET-01). Yhteiset asetussivulle sekä Viestit- ja Lahjakortit-näkymien asetuskorteille.
import { h, field, badge } from './ui.js';
import { settingsText as st } from './settings-texts.js';
import { modeBadgeKind, modeTextKey } from './settings-logic.js';

export const tx = (key) => st(`ui.admin.settings.${key}`);

export function modeBadge(mode) {
  return badge(modeBadgeKind(mode), tx(modeTextKey(mode)));
}
export function onOff(on) {
  return badge(on ? 'ok' : '', on ? tx('on') : tx('off'));
}
export function stat(label, value) {
  return h('div', { class: 'stat' }, h('span', { text: label }), value);
}
export function toggle(label, help, checked, { testid, confirmOff, confirmOn, disabled } = {}) {
  const input = h('input', { type: 'checkbox', disabled: disabled || null, 'data-testid': testid || null });
  input.checked = !!checked;
  if (confirmOff) input.addEventListener('change', () => { if (!input.checked && !window.confirm(confirmOff)) input.checked = true; });
  if (confirmOn) input.addEventListener('change', () => { if (input.checked && !window.confirm(confirmOn)) input.checked = false; });
  const row = h('div', { class: 'switch-row' },
    h('div', {}, h('b', { text: label }), help ? h('p', { class: 'muted', text: help }) : null),
    h('label', { class: 'switch' }, input, h('i'), h('span', { class: 'sr', text: label })));
  return { input, row };
}
export function num(label, value, unit, min, max, testid) {
  const input = h('input', { type: 'number', inputmode: 'numeric', min: String(min), max: String(max), step: '1', value: value == null ? '' : String(value), 'data-testid': testid || null });
  return { input, node: h('label', { class: 'fld' }, h('span', { text: label }), h('div', { class: 'unit' }, input, h('span', { text: unit }))) };
}
export function textField(label, value, help, { type = 'text', testid } = {}) {
  const input = h('input', { type, value: value ?? '', autocomplete: 'off', 'data-testid': testid || null });
  return { input, node: field(label, input, help) };
}
export function card(title, help, ...kids) {
  return h('section', { class: 'card' }, h('h2', { text: title }), help ? h('p', { class: 'muted', text: help }) : null, ...kids);
}
/** Kortti, joka on oletuksena kiinni (Järjestelmä-välilehden osiot). */
export function fold(title, help, { testid, open = false } = {}, ...kids) {
  return h('details', { class: 'card set-fold', open: open || null, 'data-testid': testid || null },
    h('summary', {}, h('h2', { text: title })), help ? h('p', { class: 'muted', text: help }) : null, ...kids);
}
export function read(label, value) {
  return stat(label, h('b', { text: value || '–' }));
}
export function group(title, ...kids) {
  return h('div', { class: 'set-group' }, h('h3', { text: title }), ...kids);
}
