// Lisäpalveluvalitsin hoito-/pakettikassalle (booking_61, §18.11): sama rakenne ja tyylit kuin vuorokassalla (shop.js): nimi + hinta + kuvaus + määrävalitsin (− n +).
// Nimet, hinnat ja enimmäismäärät tulevat palvelimelta (public_addons); otsikko/ohje/määrän tekstit ovat kaupan olemassa olevia tekstejä (t.addonsTitle, t.addonsHint, t.addonQty).
// Ei uusia asiakasnäkyviä tekstejä tässä tiedostossa; virheviesti annetaan ulkoa (site_texts: ui.checkout.error_<koodi>).
import { addonLimit, addonsPayload, addonsSum } from './treatments.js';

let uid = 0;
/** { h, t, lang, money, addons[], persons, onChange() } → { node, qty:Map, sync(persons), clear(), setError(msg|null), payload(), total(), focus() } */
export function createAddonPicker({ h, t, lang, money, addons, persons, onChange }) {
  const id = `ad${++uid}`, qty = new Map(addons.map((a) => [a.id, 0]));
  let n = persons;
  const aname = (a) => (lang === 'en' && a.name_en) || a.name, adesc = (a) => (lang === 'en' && a.description_en) || a.description;
  const err = h('p', { class: 'bk-opt-err', role: 'alert', hidden: true, 'data-testid': 'addon-error' });
  const rows = addons.map((a) => {
    const q = h('input', { id: `${id}-${a.id}`, type: 'number', min: 0, inputmode: 'numeric', 'data-testid': `addon-qty-${a.code || a.id}`, 'aria-label': `${aname(a)}: ${t.addonQty}`, onchange: () => { set(a, Math.floor(+q.value) || 0); } });
    const dec = h('button', { type: 'button', class: 'bk-step', 'aria-label': `${aname(a)} −`, onclick: () => set(a, qty.get(a.id) - 1) }, '−');
    const inc = h('button', { type: 'button', class: 'bk-step', 'aria-label': `${aname(a)} +`, onclick: () => set(a, qty.get(a.id) + 1) }, '+');
    const sync = () => { const lim = addonLimit(a, n); q.max = lim; q.value = qty.get(a.id); dec.disabled = qty.get(a.id) <= 0; inc.disabled = qty.get(a.id) >= lim; };
    const node = h('li', { class: 'bk-addon', 'data-testid': `addon-${a.code || a.id}` }, h('div', { class: 'bk-addon-info' }, h('label', { for: q.id }, h('strong', { text: aname(a) }), ' ', h('span', { class: 'bk-addon-price', text: money(a.price) })), adesc(a) ? h('small', { text: adesc(a) }) : null),
      h('div', { class: 'bk-stepper' }, dec, q, inc));
    return { node, sync, a, q };
  });
  function set(a, v) { qty.set(a.id, Math.max(0, Math.min(v, addonLimit(a, n)))); setError(null); rows.forEach((r) => r.sync()); onChange?.(); }
  const node = h('fieldset', { class: 'bk-section bk-addons', 'data-testid': 'addons' }, h('legend', { text: t.addonsTitle }), h('p', { class: 'bk-hint', text: t.addonsHint }), h('ul', { class: 'bk-addonlist' }, rows.map((r) => r.node)), err);
  rows.forEach((r) => r.sync());
  function setError(msg) { err.hidden = !msg; err.textContent = msg || ''; }
  return {
    node, qty, setError,
    sync: (p) => { n = p; for (const a of addons) qty.set(a.id, Math.min(qty.get(a.id), addonLimit(a, n))); rows.forEach((r) => r.sync()); },
    clear: () => { for (const a of addons) qty.set(a.id, 0); rows.forEach((r) => r.sync()); onChange?.(); },
    payload: () => addonsPayload(addons, qty), total: () => addonsSum(addons, qty),
    focus: () => rows[0]?.q.focus(),
  };
}
