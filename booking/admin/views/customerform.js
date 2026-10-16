// Asiakastyyppi (yksityis- / yritysasiakas) + yritystiedot: jaettu lomake-komponentti (Asiakkaat → Lisää asiakas, Uusi varaus).
// Yritysasiakkaalla: yrityksen nimi, y-tunnus (muoto 1234567-8 + tarkistenumero), laskutusosoite, verkkolaskutiedot (OVT/osoite + välittäjä) ja
// valinnainen viite/tilausnumero sekä yhteyshenkilön nimi, puhelin ja sähköposti. Palvelin validoi samat säännöt (migraatio 11).
import { rpc } from '../sb.js';
import { h, field } from '../ui.js';

export const KINDS = [['private', 'Yksityisasiakas'], ['company', 'Yritysasiakas']];

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

// Palauttaa { node, kind(), data(), setKind(k), fill(c) }.
// data() heittää Error(suomenkielinen viesti), jos tiedot ovat virheellisiä (näytetään ilmoituksena run()-kääreessä).
export function customerForm({ initialKind = 'private', contact = true, id = 'cf', onKind } = {}) {
  let kind = initialKind;
  const inp = (name, o = {}) => h('input', { name, autocomplete: 'off', ...o });
  const name = inp('cname', { required: contact || null, autocomplete: 'name' });
  const email = inp('cemail', { type: 'email', autocomplete: 'email' });
  const phone = inp('cphone', { type: 'tel', autocomplete: 'tel' });
  const company = inp('company_name'); const bid = inp('business_id', { placeholder: '1234567-8', inputmode: 'numeric' });
  const street = inp('street'); const zip = inp('zip', { inputmode: 'numeric', maxlength: 5 }); const city = inp('city');
  const ei = inp('einvoice_address', { placeholder: 'esim. 003712345678' }); const op = inp('einvoice_operator', { placeholder: 'esim. 003723327487 tai BAWCFI22' });
  const ref = inp('reference');
  const bidMsg = () => { bid.setCustomValidity(!bid.value.trim() || validBusinessId(bid.value) ? '' : 'Tarkista y-tunnus (muoto 1234567-8, tarkistenumero ei täsmää)'); };
  bid.addEventListener('input', bidMsg);
  bid.addEventListener('blur', () => { if (bid.value.trim() && validBusinessId(bid.value)) bid.value = normBusinessId(bid.value); });
  const nameLabel = h('span', { text: 'Nimi' });
  const kindBtns = KINDS.map(([k, label]) => h('label', { class: 'kindopt' }, h('input', { type: 'radio', name: `${id}-kind`, value: k, checked: k === kind || null, onchange: () => setKind(k) }), ' ', label));
  const companyBox = h('div', { class: 'stack box company-box', hidden: kind !== 'company' || null },
    h('h3', { text: 'Yrityksen tiedot' }),
    field('Yrityksen nimi', company), field('Y-tunnus', bid, 'Muoto 1234567-8. Tarkistenumero tarkistetaan.'),
    field('Katuosoite', street), h('div', { class: 'row wrap' }, field('Postinumero', zip), field('Postitoimipaikka', city)),
    h('h3', { text: 'Verkkolaskutus (valinnainen)' }),
    field('Verkkolaskuosoite (OVT-tunnus)', ei), field('Verkkolaskuoperaattori (välittäjätunnus)', op, 'Anna osoite ja välittäjä yhdessä tai jätä molemmat tyhjiksi.'),
    field('Viite / tilausnumero (valinnainen)', ref));
  function setKind(k) {
    kind = k; companyBox.hidden = k !== 'company';
    nameLabel.textContent = k === 'company' ? 'Yhteyshenkilön nimi' : 'Nimi';
    kindBtns.forEach((l) => { l.querySelector('input').checked = l.querySelector('input').value === k; });
    for (const x of [company, bid, street, zip, city]) x.required = k === 'company';
    bidMsg(); onKind?.(k);
  }
  const node = h('div', { class: 'stack' },
    h('fieldset', { class: 'kindset' }, h('legend', { text: 'Asiakastyyppi' }), h('div', { class: 'row wrap' }, kindBtns)),
    companyBox,
    contact ? h('div', { class: 'row wrap' }, h('label', { class: 'fld' }, nameLabel, name), field('Sähköposti', email), field('Puhelin', phone)) : null);
  setKind(kind);
  return {
    node, kind: () => kind, setKind,
    // Olemassa oleva asiakas valittu: yritystiedot piilotetaan (tiedot haetaan asiakasrekisteristä)
    existing: (on) => node.classList.toggle('existing', !!on),
    elements: { name, email, phone },
    // Kerää tiedot rajapinnan muotoon; { kind, name, email, phone, company_details }
    data() {
      const out = { kind, name: name.value.trim(), email: email.value.trim(), phone: phone.value.trim() };
      if (contact) {
        if (out.name.length < 2) throw new Error(kind === 'company' ? 'Anna yhteyshenkilön nimi' : 'Anna nimi');
        if (!out.email && !out.phone) throw new Error('Anna sähköposti tai puhelinnumero');
        if (out.email && !validEmail(out.email)) throw new Error('Tarkista sähköpostiosoite');
      }
      if (kind === 'company') {
        if (!company.value.trim()) throw new Error('Anna yrityksen nimi');
        if (!validBusinessId(bid.value)) throw new Error('Tarkista y-tunnus (muoto 1234567-8, tarkistenumero ei täsmää)');
        if (!street.value.trim() || !/^\d{5}$/.test(zip.value.trim()) || !city.value.trim()) throw new Error('Anna laskutusosoite (katuosoite, 5-numeroinen postinumero ja postitoimipaikka)');
        if (!!ei.value.trim() !== !!op.value.trim()) throw new Error('Anna verkkolaskuosoite ja välittäjätunnus yhdessä tai jätä molemmat tyhjiksi');
        out.company_details = { company_name: company.value.trim(), business_id: normBusinessId(bid.value), street: street.value.trim(), zip: zip.value.trim(), city: city.value.trim(),
          einvoice_address: ei.value.trim() || null, einvoice_operator: op.value.trim() || null, reference: ref.value.trim() || null };
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

// Asiakashaku (Uusi varaus + resurssi-/vanha varaus -lomake): kirjoittaessa osumat (viive); Hae-painike / Enter hakee heti, ja jos osumia ei ole,
// hakusana esitäytetään uuden asiakkaan lomakkeelle (cf.prefill). st.customer = valittu asiakas; onChange() kutsutaan valinnan/nollauksen jälkeen.
// Palauttaa { row (hakukenttä + Hae-painike), found (tulosalue), reset() }.
export function customerSearch({ cf, st, onChange = () => {} }) {
  const found = h('div', { class: 'found' });
  const search = h('input', { type: 'search', placeholder: 'Hae olemassa olevaa asiakasta (nimi/sähköposti/puhelin)', 'aria-label': 'Hae asiakas', enterkeyhint: 'search' });
  let timer, seq = 0;
  const reset = () => { st.customer = null; cf.existing(false); found.replaceChildren(); onChange(); };
  const pick = (c) => {
    st.customer = c; cf.fill(c); cf.existing(true); onChange();
    found.replaceChildren(h('p', { class: 'muted', text: `Valittu asiakas: ${c.customer_kind === 'company' ? `${c.company || c.name} (${c.business_id || 'yritys'}), yhteyshenkilö ${c.name}` : c.name}. Muuta tietoja Asiakkaat-näkymässä.` }),
      h('button', { type: 'button', class: 'btn ghost sm', onclick: reset }, 'Uusi asiakas'));
  };
  async function doSearch(explicit) {
    clearTimeout(timer); const term = search.value.trim(), my = ++seq;
    if (term.length < 2) { found.replaceChildren(); return; }
    const rows = await rpc('admin_list_customers', { p_search: term, p_limit: 5, p_offset: 0 }).catch(() => []);
    if (my !== seq) return;   // vanhentunut haku
    if (!rows.length && explicit) {
      if (st.customer) { found.replaceChildren(h('p', { class: 'muted', role: 'status', 'data-testid': 'customer-notfound', text: 'Ei löytynyt. Valittu asiakas säilyy – paina "Uusi asiakas" luodaksesi uuden.' })); return; }
      const r = cf.prefill(term);
      const what = { email: 'sähköposti', phone: 'puhelin', name: 'nimi', company: 'yrityksen nimi' }[r.field];
      found.replaceChildren(h('p', { class: 'notfound', role: 'status', 'data-testid': 'customer-notfound' }, h('strong', { text: 'Ei löytynyt – luo uusi asiakas' }), h('small', { text: r.filled ? ` Hakusana siirrettiin kenttään: ${what}.` : ` Kenttä "${what}" oli jo täytetty, sitä ei ylikirjoitettu.` })));
      return;
    }
    found.replaceChildren(...rows.map((c) => h('button', { type: 'button', class: 'listrow', onclick: () => pick(c) }, h('strong', { text: c.customer_kind === 'company' && c.company ? `${c.company} (${c.name})` : c.name }), h('small', { text: ` ${c.email || ''} ${c.phone || ''}` }))));
  }
  search.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(() => doSearch(false), 250); });
  search.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { ev.preventDefault(); doSearch(true); } });   // Enter ei saa lähettää varauslomaketta
  const row = h('div', { class: 'nbsearch' }, search, h('button', { type: 'button', class: 'btn', 'data-testid': 'customer-search-btn', onclick: () => doSearch(true) }, 'Hae'));
  return { row, found, reset };
}
