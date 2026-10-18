// Lahjakorttien kauppanäkymien yhteiset DOM-apurit (gift.js, order-gift.js). Ei ulkoisia riippuvuuksia.
import { gtText } from './gift-texts.js';
export const h = (tag, attrs, ...kids) => {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v; else if (k === 'text') el.textContent = v; else if (k.startsWith('on')) el.addEventListener(k.slice(2), v); else if (v === true) el.setAttribute(k, ''); else el.setAttribute(k, v);
  }
  for (const c of kids.flat(Infinity)) if (c != null && c !== false) el.append(c.nodeType ? c : document.createTextNode(c));
  return el;
};
export function makeFmt(lang) {
  const loc = lang === 'en' ? 'en-GB' : 'fi-FI';
  const money = (n) => { const v = +n || 0; return new Intl.NumberFormat(loc, { style: 'currency', currency: 'EUR', minimumFractionDigits: Number.isInteger(Math.round(v * 100) / 100) ? 0 : 2, maximumFractionDigits: 2 }).format(v); };
  const date = (d) => (d ? new Intl.DateTimeFormat(loc, { timeZone: 'Europe/Helsinki', day: 'numeric', month: 'numeric', year: 'numeric' }).format(new Date(`${String(d).slice(0, 10)}T12:00:00Z`)) : '');
  const tx = (key, v) => gtText(lang, key, v);
  const pick = (o, k) => (lang === 'en' && o[`${k}_en`]) || o[k];
  return { loc, money, date, tx, pick };
}
export const phoneBox = (S, tx) => h('p', { class: 'bk-contact' }, h('span', { text: `${tx('contact')} ` }), h('a', { href: `tel:${S.phoneTel}`, text: S.phone }), ' · ', h('a', { href: `mailto:${S.email}`, text: S.email }));
// Lomakekenttä: label + kenttä + virheteksti (aria-describedby / aria-invalid)
let uid = 0;
export function field({ label, control, hint, name }) {
  const id = `gcf-${name || 'f'}-${++uid}`, err = h('p', { class: 'gc-err', id: `${id}-e`, role: 'alert' }), hintEl = hint ? h('p', { class: 'bk-note gc-hint', id: `${id}-h` }, hint) : null;
  control.id = id;
  control.setAttribute('aria-describedby', [hintEl && `${id}-h`, `${id}-e`].filter(Boolean).join(' '));
  const wrap = h('div', { class: 'bk-field gc-field' }, h('label', { for: id, text: label }), control, hintEl, err);
  return { wrap, control, setError(msg) { err.textContent = msg || ''; if (msg) control.setAttribute('aria-invalid', 'true'); else control.removeAttribute('aria-invalid'); wrap.classList.toggle('bad', !!msg); } };
}

// Vieritys + fokus kun lomake/viesti ilmestyy (lahjakoodin lähdevalinta, §13.12). Pieni ja puhdas: win on injektoitavissa testejä varten.
// revealForm: vie lomakkeen alkuun (block:'start'; sticky-yläpalkki huomioitu CSS:n scroll-margin-top:ssa), siirtää fokuksen otsikkoon ilman toista vieritystä (preventScroll)
// ja kunnioittaa prefers-reduced-motionia (behavior:'auto' = ei animaatiota). Kutsutaan vain kun lomake juuri avautuu, ei renderöinnillä eikä kirjoittaessa.
export const prefersReducedMotion = (win = globalThis) => !!win?.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches;
export function revealForm(el, focusEl = el, win = globalThis) {
  if (!el) return false;
  el.scrollIntoView?.({ block: 'start', behavior: prefersReducedMotion(win) ? 'auto' : 'smooth' });
  focusEl?.focus?.({ preventScroll: true });
  return true;
}
// revealIfHidden: virhe-/tulosviesti vieritetään näkyviin vain jos se ei ole kokonaan ruudulla (block:'nearest', ei turhaa liikettä).
export function revealIfHidden(el, win = globalThis) {
  if (!el?.getBoundingClientRect || !el.scrollIntoView) return false;
  const r = el.getBoundingClientRect(), vh = win.innerHeight || win.document?.documentElement?.clientHeight || 0;
  if (r.top >= 80 && r.bottom <= vh) return false;   // 80 px = sticky-yläpalkki (69 px) + väli
  el.scrollIntoView({ block: 'nearest', behavior: prefersReducedMotion(win) ? 'auto' : 'smooth' });
  return true;
}
