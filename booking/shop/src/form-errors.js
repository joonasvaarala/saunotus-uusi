// KAUPPA-KASSA-02: yksi virhemalli kaikille kaupan lomakkeille (vuoro, hoito, jono, kurssi, vuosikortti, lahjakortti).
//   - kenttäkohtainen virheteksti kentän alle (aria-describedby + aria-invalid)
//   - virhekoonti lomakkeen alkuun, jossa linkki jokaiseen virheelliseen kenttään
//   - ensimmäinen virheellinen kenttä saa fokuksen; koonti ja kenttä viedään ruudulle (mobiilissa virhe ei jää napin viereen ruudun ulkopuolelle)
//   - virhe poistuu kun kenttää korjataan
// Tarkistukset (validateCustomer ym.) ovat puhtaita funktioita ilman DOMia, jotta ne voi testata Nodella.
import { validBusinessId, validOvt, validOperator } from './invoice-validate.js';

export const emailOk = (v) => /^[^\s@]+@[^\s@.]+(\.[^\s@.]+)+$/.test(String(v ?? '').trim());
/** Puhelin: numeroita, +, välilyöntejä, yhdysmerkkejä ja sulkeita; 6–15 numeroa. Ei vaadi suomalaista muotoa (ulkomaiset numerot kelpaavat). */
export function phoneOk(v) {
  const s = String(v ?? '').trim();
  if (!/^[+(]?\d[\d\s().\-/]*$/.test(s)) return false;
  const n = s.replace(/\D/g, '').length;
  return n >= 6 && n <= 15;
}

/**
 * Asiakastietojen tarkistus. vals: kenttien arvot (trimmattu), opts: { kind: 'private'|'company', invoiceMethod: 'einvoice'|'pdf'|'online' }.
 * Palauttaa virheet [{ field, key }]: field = kentän id/name, key = tekstiavain kaupan sanakirjassa (T). Tyhjä lista = kunnossa.
 */
export function validateCustomer(vals, { kind = 'private', invoiceMethod = 'einvoice' } = {}) {
  const v = (k) => String(vals[k] ?? '').trim();
  const errs = [];
  const add = (field, key) => errs.push({ field, key });
  if (kind === 'company') {
    if (!v('company_name')) add('company_name', 'reqCompanyName');
    if (!v('business_id')) add('business_id', 'reqBusinessId'); else if (!validBusinessId(v('business_id'))) add('business_id', 'invalidBusinessId');
    if (!v('street')) add('street', 'reqStreet');
    if (!v('zip')) add('zip', 'reqZip'); else if (!/^\d{5}$/.test(v('zip'))) add('zip', 'invalidZip');
    if (!v('city')) add('city', 'reqCity');
    if (invoiceMethod === 'einvoice') {
      if (!v('einvoice_address')) add('einvoice_address', 'reqOvt'); else if (!validOvt(v('einvoice_address'), v('business_id'))) add('einvoice_address', 'invalidOvt');
      if (!v('einvoice_operator')) add('einvoice_operator', 'reqOperator'); else if (!validOperator(v('einvoice_operator'))) add('einvoice_operator', 'invalidOperator');
    }
  }
  if (!v('name')) add('name', 'reqName');
  if (!v('email')) add('email', 'reqEmail'); else if (!emailOk(v('email'))) add('email', 'invalidEmail');
  if (!v('phone')) add('phone', 'reqPhone'); else if (!phoneOk(v('phone'))) add('phone', 'invalidPhone');
  return errs;
}

/** Kentän näkyvä nimi koontia varten: label-teksti ilman pakollisuusmerkkiä. */
export const labelText = (el, doc = globalThis.document) => {
  const lab = el?.id && doc?.querySelector ? doc.querySelector(`label[for="${el.id}"]`) : null;
  return (lab?.textContent || '').replace(/\s*\*\s*$/, '').trim();
};

const byDomOrder = (a, b) => (a.el === b.el ? 0 : (a.el.compareDocumentPosition(b.el) & 4 /* FOLLOWING */ ? -1 : 1));

/**
 * Virhekoonti ja kenttäkohtaiset virheet yhdelle lomakkeelle.
 * ctx: { h, title: koonnin otsikko, win? }. Palauttaa { show(items), clear(), clearField(el) }.
 * items: [{ el, msg, label?, inline? }]; el = virheellinen kenttä (tarvitsee id:n); inline = kentällä on jo oma virheteksti (vain koontirivi). Näyttö korvaa aiemmat virheet ja palauttaa ensimmäisen virheellisen kentän.
 */
export function createFormErrors(form, { h, title, win = globalThis }) {
  let summary = null;
  const entries = new Map();   // el -> { err, li, host, describedBy }

  const dropEntry = (el) => {
    const e = entries.get(el); if (!e) return;
    e.li.remove();
    if (e.err) {
      e.err.remove(); e.host?.classList?.remove('bad');
      el.removeAttribute('aria-invalid');
      if (e.describedBy) el.setAttribute('aria-describedby', e.describedBy); else el.removeAttribute('aria-describedby');
    }
    el.removeEventListener('input', e.onFix); el.removeEventListener('change', e.onFix);
    entries.delete(el);
  };
  const clearField = (el) => {
    dropEntry(el);
    if (summary && !entries.size) { summary.remove(); summary = null; }
  };
  const clear = () => { for (const el of [...entries.keys()]) dropEntry(el); summary?.remove(); summary = null; };

  function show(items) {
    clear();
    const list = items.filter((i) => i?.el).sort(byDomOrder);
    if (!list.length) return null;
    const ul = h('ul', { class: 'bk-errsum-list' });
    for (const { el, msg, label, inline } of list) {
      let err = null, host = null, describedBy = null;
      if (!inline) {   // inline: kentällä on jo oma virhetekstinsä (esim. rituaaliaika) → vain koontirivi
        host = el.closest?.('.bk-field, .bk-check, .gc-field') || el.parentElement;
        const id = `${el.id || 'f'}-err`;
        err = h('p', { class: 'bk-fielderr', id, 'data-testid': 'field-error', text: msg });
        host.append(err); host.classList?.add('bad');
        describedBy = el.getAttribute('aria-describedby');
        el.setAttribute('aria-invalid', 'true');
        el.setAttribute('aria-describedby', [describedBy, id].filter(Boolean).join(' '));
      }
      const a = h('a', { href: `#${el.id}`, text: label ? `${label}: ${msg}` : msg, onclick: (ev) => { ev.preventDefault(); focusField(el, win); } });
      const li = h('li', {}, a); ul.append(li);
      const onFix = () => clearField(el);
      el.addEventListener('input', onFix); el.addEventListener('change', onFix);
      entries.set(el, { err, li, host, describedBy, onFix });
    }
    summary = h('div', { class: 'bk-errsum', role: 'group', tabindex: '-1', 'aria-labelledby': 'bk-errsum-h', 'data-testid': 'error-summary' },
      h('h3', { id: 'bk-errsum-h', text: title }), ul);
    form.prepend(summary);
    reveal(summary, list[0].el, win);
    return list[0].el;
  }
  return { show, clear, clearField };
}

/** Fokus kentälle ja kenttä näkyviin sticky-yläpalkin (scroll-margin-top) alle. */
export function focusField(el, win = globalThis) {
  el.focus({ preventScroll: true });
  el.scrollIntoView?.({ block: 'center', behavior: prefersReduced(win) ? 'auto' : 'smooth' });
}
const prefersReduced = (win) => !!win?.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches;

/**
 * Vie koonnin ruudulle ja fokuksen ensimmäiseen virheelliseen kenttään. Jos koonti ja kenttä mahtuvat yhdessä ruudulle (koonti ylhäällä), pysytään koonnissa;
 * muuten kenttä keskitetään (kentän oma virheteksti on aina kentän alla, joten se tulee samalla ruudulle).
 */
export function reveal(summary, first, win = globalThis) {
  const behavior = prefersReduced(win) ? 'auto' : 'smooth';
  summary.scrollIntoView?.({ block: 'start', behavior });
  first.focus({ preventScroll: true });
  const vh = win?.innerHeight || 0;
  if (!vh || !first.getBoundingClientRect) return;
  const s = summary.getBoundingClientRect(), f = first.getBoundingClientRect();
  const fits = f.bottom - s.top < vh - 96;   // koonnin yläreuna ja kentän alareuna samassa ruudussa (pieni tila virheelle kentän alla)
  if (!fits) first.scrollIntoView?.({ block: 'center', behavior });
}
