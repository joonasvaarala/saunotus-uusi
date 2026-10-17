// Plus/miinus-stepper ("− [ 3 ] +"): jaettu määräsyöte (lisäpalvelut, henkilömäärä). Kenttä on edelleen suoraan muokattava näppäimistöllä
// (type=text + inputmode=numeric, jotta mobiilinäppäimistö on numeerinen eikä selain lisää omia nuolia); arvo validoidaan kokonaisluvuksi 0..max.
// Puhdas logiikka (clampQty, nextQty, parseQty) on erikseen → node --test. DOM-osa käyttää vain h() ja icon().
import { h } from './ui.js';
import { icon } from './icons.js';
import { nbt } from './nb-texts.js';

// Merkkijono/luku → kokonaisluku. Tyhjä, ei-numeerinen ja negatiivinen → min; desimaalit katkaistaan alaspäin ("2,7" → 2).
export function parseQty(v, min = 0) {
  const t = String(v ?? '').trim().replace(',', '.');
  if (!/^-?\d*\.?\d*$/.test(t) || t === '' || t === '-' || t === '.') return min;
  const n = Math.floor(+t);
  return Number.isFinite(n) ? n : min;
}
// Rajaa kokonaisluvun välille min..max (max < min → min).
export const clampQty = (v, min = 0, max = 99) => Math.max(min, Math.min(Math.max(min, Math.floor(+max) || 0), parseQty(v, min)));
// Plus/miinus-napin tulos rajojen sisällä.
export const nextQty = (cur, dir, min = 0, max = 99) => clampQty(clampQty(cur, min, max) + (dir < 0 ? -1 : 1), min, max);

// stepper({ name, label, value, min, max, onChange(n), inputName }) → { node, input, get(), set(n), setRange(min, max), plus, minus }
// name = näkyvä nimi aria-labeleihin ("Pyyhe" → "Vähennä: Pyyhe", "Lisää: Pyyhe", "Pyyhe, määrä").
export function stepper({ label, value = 0, min = 0, max = 99, onChange, inputName, size = 'md' } = {}) {
  let lo = min, hi = max, cur = clampQty(value, lo, hi);
  const input = h('input', { type: 'text', class: 'stp-in', inputmode: 'numeric', pattern: '[0-9]*', autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false', maxlength: 3, name: inputName, value: String(cur), 'aria-label': nbt('step.qty', { name: label }) });
  const minus = h('button', { type: 'button', class: 'stp-btn', 'aria-label': nbt('step.dec', { name: label }), 'data-dir': '-1' }, icon('minus', 20));
  const plus = h('button', { type: 'button', class: 'stp-btn', 'aria-label': nbt('step.inc', { name: label }), 'data-dir': '1' }, icon('add', 20));
  const node = h('span', { class: `stepper ${size}`, role: 'group', 'aria-label': label }, minus, input, plus);
  const paint = () => { input.value = String(cur); input.setAttribute('aria-valuenow', String(cur)); minus.disabled = cur <= lo; plus.disabled = cur >= hi; node.classList.toggle('stp-zero', cur === 0); };
  // Kirjoitettaessa sallitaan vain numerot; tyhjä kenttä sallitaan väliaikaisesti (arvo = min), lopullinen arvo rajataan change/blur-tapahtumassa.
  const commit = (v, emit = true) => { const n = clampQty(v, lo, hi); const changed = n !== cur; cur = n; paint(); if (changed && emit) onChange?.(cur); return cur; };
  input.addEventListener('input', () => {
    const digits = input.value.replace(/\D/g, '').slice(0, 3);
    if (digits !== input.value) input.value = digits;
    const n = clampQty(digits === '' ? lo : digits, lo, hi);
    if (n !== cur) { cur = n; minus.disabled = cur <= lo; plus.disabled = cur >= hi; node.classList.toggle('stp-zero', cur === 0); onChange?.(cur); }
    if (digits !== '' && String(n) !== digits) input.value = String(n);   // yli maksimin → rajataan heti
  });
  input.addEventListener('change', () => commit(input.value));
  input.addEventListener('blur', () => commit(input.value));
  input.addEventListener('focus', () => { try { input.select(); } catch { /* */ } });
  // Napit ja nuolinäppäimet: arvo rajojen sisällä + 'input'-tapahtuma kentälle (ulkoiset kuuntelijat toimivat kuten tavallisella syötteellä)
  const bump = (dir) => { commit(nextQty(input.value, dir, lo, hi)); input.dispatchEvent(new Event('input', { bubbles: true })); };
  input.addEventListener('keydown', (ev) => { if (ev.key === 'ArrowUp' || ev.key === 'ArrowDown') { ev.preventDefault(); bump(ev.key === 'ArrowUp' ? 1 : -1); } });
  for (const b of [minus, plus]) b.addEventListener('click', () => bump(+b.dataset.dir));
  paint();
  return {
    node, input, plus, minus, get: () => cur,
    set(v, emit = false) { commit(v, emit); },
    // Uudet rajat (esim. henkilömäärä muuttuu → lisäpalvelun maksimi); nykyinen arvo rajataan. Palauttaa true, jos arvo muuttui.
    setRange(nmin, nmax) { lo = nmin; hi = Math.max(nmin, nmax); const before = cur; cur = clampQty(cur, lo, hi); paint(); return cur !== before; },
    range: () => ({ min: lo, max: hi }),
  };
}
