// Asiakastyyppi (yksityis- / yritysasiakas) + yritystiedot: jaettu lomake-komponentti (Asiakkaat → Lisää asiakas, Uusi varaus).
// Yritysasiakkaalla: yrityksen nimi, y-tunnus (muoto 1234567-8 + tarkistenumero), laskutusosoite, verkkolaskutiedot (OVT/osoite + välittäjä) ja
// valinnainen viite/tilausnumero sekä yhteyshenkilön nimi, puhelin ja sähköposti. Palvelin validoi samat säännöt (migraatio 11).
import { rpc } from '../sb.js';
import { h } from '../ui.js';
import { icon } from '../icons.js';
import { nbt } from '../nb-texts.js';

export const KINDS = [['private', 'cu.private'], ['company', 'cu.company']];   // [arvo, tekstiavain] (nb-texts.js; FI/EN)

// y-tunnus: normalisointi + tarkistenumero (painot 7,9,10,5,8,4,2; jäännös 0 → 0, 1 → virhe, muuten 11 − jäännös). Peilaa booking._business_id_ok.
export function normBusinessId(s) {
  const t = String(s ?? '').replace(/\s/g, '').toUpperCase().replace(/^FI(\d{8})$/, '$1');
  let m = t.match(/^(\d{7})-?(\d)$/); if (m) return `${m[1]}-${m[2]}`;
  m = t.match(/^(\d{6})-?(\d)$/); if (m) return `0${m[1]}-${m[2]}`;
  return t;
}
export function validBusinessId(s) {
  const m = normBusinessId(s).match(/^(\d{7})-(\d)$/);
  if (!m) return false;
  const w = [7, 9, 10, 5, 8, 4, 2];
  const rem = [...m[1]].reduce((a, c, i) => a + +c * w[i], 0) % 11;
  if (rem === 1) return false;
  return (rem === 0 ? 0 : 11 - rem) === +m[2];
}
export const validEmail = (s) => /^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/.test(String(s).trim());

// Kenttä + selite + virheviesti kentän vieressä (aria-describedby, aria-invalid). Virhe tyhjenee, kun kenttää muokataan.
function cfield(label, input, { hint, optional, cls = '' } = {}) {
  const err = h('small', { class: 'fld-err', role: 'status', hidden: true });
  const id = `${input.name || 'f'}-${Math.random().toString(36).slice(2, 7)}`;
  err.id = `${id}-e`; const ids = [err.id];
  const hintEl = hint ? h('small', { class: 'fld-hint', id: `${id}-h`, text: hint }) : null; if (hintEl) ids.push(hintEl.id);
  input.setAttribute('aria-describedby', ids.join(' '));
  input.addEventListener('input', () => { err.hidden = true; input.removeAttribute('aria-invalid'); });
  const node = h('label', { class: `fld ${cls}` }, h('span', { class: 'fld-lab' }, label, optional ? h('span', { class: 'opt', text: ` (${optional})` }) : null), input, hintEl, err);
  return { node, err, input };
}
const showErr = (f, msg) => { f.err.textContent = msg; f.err.hidden = false; f.input.setAttribute('aria-invalid', 'true'); };

// Palauttaa { node, kind(), data(), validate(), setKind(k), fill(c) }.
// data() heittää Error(suomenkielinen viesti), jos tiedot ovat virheellisiä (näytetään ilmoituksena run()-kääreessä).
// validate({ focus }) näyttää KAIKKI virheet kunkin kentän vieressä ja palauttaa ensimmäisen virheellisen kentän (tai null).
// Asetukset: contact (nimi/sähköposti/puhelin), reference (yrityksen oma viite -kenttä; Uusi varaus -lomakkeella piilossa, koska laskun viite kysytään erikseen).
// Asiakkaan tiedot ovat toisen henkilön tietoja → autocomplete=off (selain ei täytä hallinnoijan omia tietoja).
export function customerForm({ initialKind = 'private', contact = true, id = 'cf', onKind, reference = true } = {}) {
  let kind = initialKind;
  const inp = (name, o = {}) => h('input', { name, autocomplete: 'off', ...o });
  const name = inp('cname', { required: contact || null, 'aria-required': contact ? 'true' : null, autocapitalize: 'words' });
  const email = inp('cemail', { type: 'email', inputmode: 'email', autocapitalize: 'off', spellcheck: 'false' });
  const phone = inp('cphone', { type: 'tel', inputmode: 'tel' });
  const company = inp('company_name', { autocapitalize: 'words' }); const bid = inp('business_id', { placeholder: '1234567-8', inputmode: 'numeric', autocapitalize: 'off' });
  const street = inp('street', { autocapitalize: 'words' }); const zip = inp('zip', { inputmode: 'numeric', maxlength: 5 }); const city = inp('city', { autocapitalize: 'words' });
  const ei = inp('einvoice_address', { placeholder: nbt('cu.ovtPh'), inputmode: 'numeric' }); const op = inp('einvoice_operator', { placeholder: nbt('cu.opPh'), autocapitalize: 'characters' });
  const ref = inp('reference');
  const bidMsg = () => { bid.setCustomValidity(!bid.value.trim() || validBusinessId(bid.value) ? '' : nbt('cu.eBid')); };
  bid.addEventListener('input', bidMsg);
  bid.addEventListener('blur', () => { if (bid.value.trim() && validBusinessId(bid.value)) bid.value = normBusinessId(bid.value); });
  const nameLabel = h('span', { text: nbt('cu.name') });
  const F = {
    name: cfield(nameLabel, name), email: cfield(nbt('cu.email'), email), phone: cfield(nbt('cu.phone'), phone),
    company: cfield(nbt('cu.cName'), company), bid: cfield(nbt('cu.bid'), bid, { hint: nbt('cu.bidHint') }),
    street: cfield(nbt('cu.street'), street), zip: cfield(nbt('cu.zip'), zip, { cls: 'zip' }), city: cfield(nbt('cu.city'), city),
    ei: cfield(nbt('cu.ovt'), ei, { optional: null }), op: cfield(nbt('cu.op'), op, { hint: nbt('cu.opHint') }), ref: cfield(nbt('cu.ref'), ref),
  };
  const kindBtns = KINDS.map(([k, key]) => h('label', { class: 'kindopt' }, h('input', { type: 'radio', name: `${id}-kind`, value: k, checked: k === kind || null, onchange: () => setKind(k) }), h('span', { text: nbt(key) })));
  const companyBox = h('div', { class: 'stack box company-box', hidden: kind !== 'company' || null },
    h('h3', { text: nbt('cu.cInfo') }),
    F.company.node, F.bid.node, F.street.node, h('div', { class: 'cf-addr' }, F.zip.node, F.city.node),
    h('h3', { text: nbt('cu.einv') }),
    F.ei.node, F.op.node,
    reference ? F.ref.node : null);
  function setKind(k) {
    kind = k; companyBox.hidden = k !== 'company';
    nameLabel.textContent = k === 'company' ? nbt('cu.contactName') : nbt('cu.name');
    kindBtns.forEach((l) => { l.querySelector('input').checked = l.querySelector('input').value === k; });
    for (const x of [company, bid, street, zip, city]) x.required = k === 'company';
    bidMsg(); onKind?.(k);
  }
  const reachHint = h('small', { class: 'fld-hint cf-reach', text: nbt('cu.reachHint') });
  const node = h('div', { class: 'stack cf' },
    h('fieldset', { class: 'kindset' }, h('legend', { text: nbt('cu.kind') }), h('div', { class: 'seg', role: 'presentation' }, kindBtns)),
    companyBox,
    contact ? h('div', { class: 'stack cf-contact' }, F.name.node, h('div', { class: 'cf-pair' }, F.email.node, F.phone.node), reachHint) : null);
  setKind(kind);
  // Kaikki virheet [{ el, field, msg }] kenttäjärjestyksessä; sama sääntö kuin palvelimella (migraatio 11)
  function problems() {
    const out = []; const add = (f, el, msg) => out.push({ f, el, msg });
    if (kind === 'company') {
      if (!company.value.trim()) add(F.company, company, nbt('cu.eCompany'));
      if (!validBusinessId(bid.value)) add(F.bid, bid, nbt('cu.eBid'));
      if (!street.value.trim()) add(F.street, street, nbt('cu.eStreet'));
      if (!/^\d{5}$/.test(zip.value.trim())) add(F.zip, zip, nbt('cu.eZip'));
      if (!city.value.trim()) add(F.city, city, nbt('cu.eCity'));
      if (!!ei.value.trim() !== !!op.value.trim()) add(ei.value.trim() ? F.op : F.ei, ei.value.trim() ? op : ei, nbt('cu.eEinv'));
    }
    if (contact) {
      const n = name.value.trim(), e = email.value.trim(), ph = phone.value.trim();
      if (n.length < 2) add(F.name, name, kind === 'company' ? nbt('cu.eContactName') : nbt('cu.eName'));
      if (!e && !ph) add(F.email, email, nbt('cu.eReach'));
      else if (e && !validEmail(e)) add(F.email, email, nbt('cu.eEmail'));
    }
    // DOM-järjestys (ylhäältä alas), jotta ensimmäinen virhe on se, jonka käyttäjä näkee ensin
    const all = [...node.querySelectorAll('input')];
    return out.sort((x, y) => all.indexOf(x.el) - all.indexOf(y.el));
  }
  return {
    node, kind: () => kind, setKind,
    // Olemassa oleva asiakas valittu: yritystiedot ja syöttökentät piilotetaan (tiedot haetaan asiakasrekisteristä)
    existing: (on) => node.classList.toggle('existing', !!on),
    elements: { name, email, phone },
    problems,
    validate({ focus = true } = {}) {
      for (const f of Object.values(F)) { f.err.hidden = true; f.input.removeAttribute('aria-invalid'); }
      const list = problems(); for (const p of list) showErr(p.f, p.msg);
      if (list[0] && focus) list[0].el.focus();
      return list[0]?.el || null;
    },
    // Kerää tiedot rajapinnan muotoon; { kind, name, email, phone, company_details }
    data() {
      const out = { kind, name: name.value.trim(), email: email.value.trim(), phone: phone.value.trim() };
      const list = problems(); if (list.length) throw new Error(list[0].msg.replace(/\.$/, ''));
      if (kind === 'company') {
        out.company_details = { company_name: company.value.trim(), business_id: normBusinessId(bid.value), street: street.value.trim(), zip: zip.value.trim(), city: city.value.trim(),
          einvoice_address: ei.value.trim() || null, einvoice_operator: op.value.trim() || null, reference: reference ? ref.value.trim() || null : null };
      }
      return out;
    },
    // Esitäyttö hakusanasta, kun haku ei löytänyt asiakasta: sähköpostiosoite → Sähköposti, puhelinnumero → Puhelin, muu → Nimi
    // (yritysasiakkaalla Yrityksen nimi). Ei ylikirjoita jo täytettyä kenttää. Palauttaa { field, filled } ja siirtää fokuksen seuraavaan täyttämättömään kenttään.
    prefill(term) {
      const t = String(term ?? '').trim().replace(/\s+/g, ' ');
      const isMail = validEmail(t), isPhone = !isMail && /^\+?[\d\s()-]{6,}$/.test(t) && !/[A-Za-zÅÄÖåäö]/.test(t);
      const [field, el] = isMail ? ['email', email] : isPhone ? ['phone', phone] : kind === 'company' ? ['company', company] : ['name', name];
      const filled = !!t && !el.value.trim();
      if (filled) { el.value = t; el.dispatchEvent(new Event('input', { bubbles: true })); }
      const order = [...(kind === 'company' ? [company, bid, street, zip, city] : []), name, email, phone];
      (order.find((x) => !x.value.trim() && x !== el) || order.find((x) => !x.value.trim()))?.focus();
      return { field, filled };
    },
    // Esitäyttö valitusta asiakkaasta (Uusi varaus: haku)
    fill(c) {
      name.value = c.name || ''; email.value = c.email || ''; phone.value = c.phone || '';
      setKind(c.customer_kind === 'company' ? 'company' : 'private');
      company.value = c.company || ''; bid.value = c.business_id || '';
    },
  };
}

// Yhteinen haku (Uusi varaus ja Uusi lasku): kirjoittaessa osumat (viive); Hae / Enter hakee heti.
// Jos osumia ei ole ja haku on tahallinen, onExplicitMiss(term) palauttaa näytettävän solmun (esim. nimi siirretään kenttään).
// Palauttaa { row, found, reset(), input, pick(row) }.
export function lookupSearch({
  placeholder, ariaLabel, buttonLabel, buttonTestId = 'customer-search-btn', search,
  hitTitle, hitMeta = () => '', onPick, pickedTitle, pickedMeta = () => '', newLabel, onReset, onExplicitMiss,
  pickedTestId = 'customer-picked',
} = {}) {
  const found = h('div', { class: 'found', 'aria-live': 'polite' });
  const input = h('input', { type: 'search', placeholder, 'aria-label': ariaLabel, enterkeyhint: 'search', autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false', name: 'csearch' });
  let timer, seq = 0;
  const reset = () => { onReset?.(); found.replaceChildren(); };
  const pick = (row) => {
    onPick?.(row);
    found.replaceChildren(h('div', { class: 'picked-cust', 'data-testid': pickedTestId }, h('span', { class: 'pc-ico' }, icon('check', 22)),
      h('div', { class: 'pc-txt' }, h('strong', { text: pickedTitle(row) }), h('small', { text: pickedMeta(row) })),
      h('button', { type: 'button', class: 'btn ghost', onclick: reset }, newLabel)));
  };
  async function doSearch(explicit) {
    clearTimeout(timer); const term = input.value.trim(), my = ++seq;
    if (term.length < 2) { found.replaceChildren(); return; }
    let rows = [];
    try { rows = await search(term); } catch { rows = []; }
    if (my !== seq) return;
    if (!Array.isArray(rows)) rows = [];
    if (!rows.length) {
      if (explicit && onExplicitMiss) {
        const node = onExplicitMiss(term);
        if (node) found.replaceChildren(node); else found.replaceChildren();
      } else {
        // Tyhjä kirjoitushaku tyhjentää vain osumalistan. "Ei löydy" / YTJ jää näkyviin.
        const kids = [...found.children];
        if (kids.length && kids.every((el) => el.classList?.contains('listrow'))) found.replaceChildren();
      }
      return;
    }
    found.replaceChildren(...rows.map((row) => h('button', { type: 'button', class: 'listrow', onclick: () => pick(row) }, h('strong', { text: hitTitle(row) }), h('small', { text: ` ${hitMeta(row)}` }))));
  }
  input.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(() => doSearch(false), 250); });
  input.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { ev.preventDefault(); doSearch(true); } });
  const row = h('div', { class: 'nbsearch' }, input, h('button', { type: 'button', class: 'btn', 'data-testid': buttonTestId, onclick: () => doSearch(true) }, buttonLabel));
  return { row, found, reset, input, pick };
}

// Asiakashaku (Uusi varaus + resurssi-/vanha varaus -lomake). Sama ulkoasu kuin lookupSearch.
// st.customer = valittu asiakas; onChange() kutsutaan valinnan/nollauksen jälkeen.
export function customerSearch({ cf, st, onChange = () => {} }) {
  return lookupSearch({
    placeholder: nbt('cu.searchPh'), ariaLabel: nbt('cu.searchAria'), buttonLabel: nbt('cu.searchBtn'),
    search: (term) => rpc('admin_list_customers', { p_search: term, p_limit: 5, p_offset: 0 }).catch(() => []),
    hitTitle: (c) => (c.customer_kind === 'company' && c.company ? `${c.company} (${c.name})` : c.name),
    hitMeta: (c) => `${c.email || ''} ${c.phone || ''}`,
    onPick: (c) => { st.customer = c; cf.fill(c); cf.existing(true); onChange(); },
    pickedTitle: (c) => (c.customer_kind === 'company' ? `${c.company || c.name} (${c.business_id || nbt('cu.company')}), ${nbt('cu.contact')} ${c.name}` : c.name),
    pickedMeta: (c) => [c.email, c.phone].filter(Boolean).join(' · ') || nbt('cu.selectedNote'),
    newLabel: nbt('cu.new'),
    onReset: () => { st.customer = null; cf.existing(false); onChange(); },
    onExplicitMiss: (term) => {
      if (st.customer) return h('p', { class: 'muted', role: 'status', 'data-testid': 'customer-notfound', text: nbt('cu.notFoundKept') });
      const r = cf.prefill(term);
      const what = nbt(`cu.what.${r.field}`);
      return h('p', { class: 'notfound', role: 'status', 'data-testid': 'customer-notfound' }, h('strong', { text: nbt('cu.notFound') }), h('small', { text: ` ${r.filled ? nbt('cu.prefilled', { what }) : nbt('cu.notOverwritten', { what })}` }));
    },
  });
}
