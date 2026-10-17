// Hoitovalitsin: selkeä radiovalinta korttinappeina (oikeat <input type=radio>: näppäimistö nuolilla, ruudunlukija lukee ryhmän; kortti ≥ 56 px korkea, koko kortti on napautuskohde).
// Käytetään tuotesivulla, kassalla, vahvistussivun muutosnäkymässä ja tilaussivulla. Väriteema: tummanvihreä valinta, hiekka-/korttitausta, ei sinistä.
import { optName, optDesc, optLabel } from './options-logic.js';
import { OPT } from './options-texts.js';

let uid = 0;
// { h, lang, product?, options, label?, value?, required?, hint?, step? (vaiheen numero, koriste), onChange(code) }
export function createOptionPicker({ h, lang, product = null, options, label, value = null, required = true, hint, step = null, onChange, testid = 'option-picker' }) {
  const L = OPT[lang] ? lang : 'fi', tx = OPT[L], id = `opt${++uid}`, name = `${id}-r`;
  let cur = value && options.some((o) => o.code === value) ? value : null;
  const err = h('p', { class: 'bk-opt-err', id: `${id}-err`, role: 'alert', hidden: true });
  const inputs = [];
  const cards = options.map((o) => {
    const desc = optDesc(o, L);
    const input = h('input', { type: 'radio', class: 'bk-opt-input', name, value: o.code, id: `${id}-${o.code}`, checked: o.code === cur || null, 'data-testid': `option-${o.code}`, 'aria-describedby': desc ? `${id}-${o.code}-d` : null });
    const card = h('label', { class: `bk-opt-card${o.code === cur ? ' on' : ''}`, for: input.id }, input,
      h('span', { class: 'bk-opt-body' }, h('span', { class: 'bk-opt-name', text: optName(o, L) }), desc ? h('span', { class: 'bk-opt-desc', id: `${id}-${o.code}-d`, text: desc }) : null),
      h('span', { class: 'bk-opt-mark', 'aria-hidden': 'true' }));
    input.addEventListener('change', () => { if (input.checked) { cur = o.code; mark(); setError(null); onChange?.(cur); } });
    inputs.push(input);
    return card;
  });
  const mark = () => cards.forEach((c, i) => c.classList.toggle('on', options[i].code === cur));
  const title = (product ? optLabel(product, L, tx.defaultLabel) : label) || tx.defaultLabel;
  const node = h('fieldset', { class: 'bk-opt', 'data-testid': testid, 'aria-describedby': `${id}-hint` },
    h('legend', {}, step ? h('span', { class: 'bk-stepn', 'aria-hidden': 'true', text: step }) : null, h('span', { class: 'bk-opt-title', text: title }), ' ', required === null ? null : h('span', { class: `bk-opt-req${required ? '' : ' opt'}`, text: required ? tx.required : tx.optional })),
    h('div', { class: 'bk-opt-grid' }, cards),
    h('p', { class: 'bk-opt-hint', id: `${id}-hint`, text: hint ?? (required === false ? tx.hintChange : tx.hint) }), err);
  function setError(msg) { err.hidden = !msg; err.textContent = msg || ''; node.classList.toggle('invalid', !!msg); inputs.forEach((i) => (msg ? i.setAttribute('aria-invalid', 'true') : i.removeAttribute('aria-invalid'))); }
  return {
    node, get: () => cur, setError,
    set: (code) => { cur = code && options.some((o) => o.code === code) ? code : null; inputs.forEach((i) => { i.checked = i.value === cur; }); mark(); if (cur) setError(null); },
    focus: () => (inputs.find((i) => i.checked) || inputs[0])?.focus(),
  };
}
