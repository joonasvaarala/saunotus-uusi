// Manuaalinen varaus (puhelin, paikan päällä, sähköposti): tuote → päivä → vuoro → henkilöt → asiakas → maksutapa/maksettu.
// Vuosikorttiasiakkaalle yleiseen vuoroon: "Vuosikorttivaraus" (ilmainen, 1 hlö, yksi tuleva varaus kerrallaan).
import { rpc } from '../sb.js';
import { customerForm, customerSearch } from './customerform.js';
import { warningBox, hasWarning, MISSING_TEXT } from './therapist.js';
import { addonPicker } from './addons.js';
import { h, field, toast, run, fmtTime, fmtDay, money, todayHel, empty } from '../ui.js';
import { typeSwitch, render as renderResource } from './resbooking.js';

const priceFor = (s, n) => (s.price_mode === 'per_person' ? s.unit_price * n : s.price_mode === 'fixed' ? s.base_price : s.base_price + Math.max(0, n - (s.included_persons || 0)) * (s.extra_person_price || 0));

export async function render({ ctx, refs, query }) {
  const kind = query.get('tyyppi');   // migraatio 17: resurssivaraus / vanha varaus omalla lomakkeellaan
  if (kind === 'resurssi' || kind === 'vanha') return renderResource({ ctx, refs, query, kind });
  const addons = await rpc('admin_list_addons').catch(() => []);
  const st = { date: /^\d{4}-\d\d-\d\d$/.test(query.get('d') || '') ? query.get('d') : todayHel(), session: null, customer: null, pre: query.get('r') && query.get('t') ? { r: query.get('r'), t: query.get('t') } : null };
  const root = h('div', { class: 'stack' });
  const sessionsBox = h('div', { class: 'stack' }); const formBox = h('div', {}); const result = h('div', {});
  const dateIn = h('input', { type: 'date', value: st.date, 'aria-label': 'Päivä', onchange: (e) => { st.date = e.target.value; st.session = null; loadSessions(); drawForm(); } });
  async function loadSessions() {
    sessionsBox.replaceChildren(h('p', { class: 'muted', text: 'Ladataan…' }));
    const v = await rpc('admin_day_view', { p_date: st.date });
    const list = (v.sessions || []).filter((s) => s.status !== 'closed');
    if (st.pre) { const m = list.find((s) => String(s.rule_id) === st.pre.r && s.starts_at === st.pre.t && s.status === 'available'); st.pre = null; if (m) st.session = m; }   // Vapaana-napista (päivänäkymä): esivalittu vuoro
    sessionsBox.replaceChildren(list.length ? h('div', { class: 'slotpick', role: 'radiogroup', 'aria-label': 'Vuoro' }, list.map((s) => {
      const ok = s.status === 'available';
      const b = h('button', { type: 'button', role: 'radio', 'aria-checked': st.session?.rule_id === s.rule_id ? 'true' : 'false', class: `slotbtn ${s.status}`, disabled: !ok || null, onclick: () => { st.session = s; sessionsBox.querySelectorAll('.slotbtn').forEach((x) => x.setAttribute('aria-checked', 'false')); b.setAttribute('aria-checked', 'true'); drawForm(true); } },
        h('strong', { text: `${fmtTime(s.starts_at)}–${fmtTime(s.ends_at)}` }), h('span', { text: refs.productById.get(s.product_id)?.name || s.label }), h('small', { text: ok ? (s.mode === 'exclusive' ? 'yksityisvuoro vapaa' : `${s.remaining} vapaana`) : s.status === 'full' ? 'täynnä' : 'ei varattavissa' }));
      return b;
    })) : empty('Ei vuoroja tälle päivälle.'));
  }
  // Vuoron valinnan (tai vaihdon) jälkeen näkymä vierittyy varauslomakkeeseen ja fokus siirretään lomakkeen otsikkoon: ei avaa mobiilinäppäimistöä,
  // ruudunlukija lukee valitun vuoron. Vieritys on pehmeä vain jos käyttäjä ei ole pyytänyt vähennettyä liikettä; sticky-yläpalkki huomioidaan (scroll-margin).
  function revealForm(f, tries = 0) {
    if (!f.isConnected) { if (tries < 20) setTimeout(() => revealForm(f, tries + 1), 60); return; }   // esivalinta: lomake liitetään sivulle vasta renderöinnin jälkeen
    const title = f.querySelector('h3'); title.tabIndex = -1;
    f.style.scrollMarginTop = `${(document.querySelector('.top')?.offsetHeight || 56) + 12}px`;
    const reduce = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
    f.scrollIntoView({ block: 'start', behavior: reduce ? 'auto' : 'smooth' });
    title.focus({ preventScroll: true });
  }
  function drawForm(reveal = false) {
    const s = st.session;
    if (!s) { formBox.replaceChildren(h('p', { class: 'muted', text: 'Valitse vuoro.' })); return; }
    const max = Math.min(s.max_persons || 50, s.remaining);
    const n = h('input', { type: 'number', name: 'n', min: s.min_persons, max, value: s.min_persons, required: true });
    const price = h('input', { type: 'number', step: '0.01', min: '0', name: 'price', placeholder: 'Automaattinen' });
    const auto = h('strong', { class: 'autoprice' });
    const picker = addonPicker(addons, { getPersons: () => +n.value || 0, getMode: () => s.mode, onChange: () => upd() });
    const upd = () => { const ad = picker.total(); auto.textContent = `Hinta ${money(priceFor(s, +n.value || 0))}${ad ? ` + lisäpalvelut ${money(ad)}` : ''}`; }; n.addEventListener('input', upd); upd();
    const invRef = h('input', { name: 'invref', maxlength: 100 });
    const cardChk = h('input', { type: 'checkbox', name: 'cardbooking' });
    const cardRow = h('label', { class: 'check', hidden: true }, cardChk, ' Vuosikorttivaraus (ilmainen, 1 hlö; yksi tuleva varaus kerrallaan)');
    const syncCard = () => { const ok = st.customer?.customer_type === 'annual_card' && s.mode === 'shared'; cardRow.hidden = !ok; if (!ok) cardChk.checked = false; if (cardChk.checked) picker.node.hidden = true; else picker.sync(); };
    cardChk.addEventListener('change', syncCard);
    const ui = {};
    const cf = customerForm({ id: 'nb', onKind: (k) => { if (ui.method && !st.customer) ui.method.value = k === 'company' && refs.methods.some((m) => m.active && m.code === 'invoice') ? 'invoice' : 'pay_later'; } });
    const cs = customerSearch({ cf, st, onChange: () => syncCard() });
    cf.elements.name.addEventListener('input', () => { if (st.customer) cs.reset(); });
    const method = h('select', { name: 'method' }, refs.methods.filter((m) => m.active).map((m) => h('option', { value: m.code, text: m.label, selected: m.code === 'pay_later' || null })));
    ui.method = method;
    const paid = h('input', { type: 'checkbox', name: 'paid' });
    const f = h('form', { class: 'stack card nbform', 'data-testid': 'booking-form', novalidate: true, onsubmit: (ev) => { ev.preventDefault(); run(f.querySelector('button[type=submit]'), async () => {
      const cust = st.customer ? { p_customer_id: st.customer.id } : { p_customer: cf.data() };
      const addonsSel = picker.node.hidden ? [] : picker.value();
      const r = cardChk.checked ? await rpc('admin_create_annual_card_booking', { p_customer_id: st.customer.id, p_rule_id: s.rule_id, p_date: st.date, p_note: f.elements.note.value || null })
        : await rpc('admin_create_booking', { p_rule_id: s.rule_id, p_date: st.date, p_persons: +n.value, ...cust, p_payment_method: method.value, p_paid: paid.checked, p_note: f.elements.note.value || null, p_price: price.value ? +price.value : null, p_addons: addonsSel.length ? addonsSel : null, p_invoice_reference: invRef.value.trim() || null });
      if (hasWarning(r)) toast(MISSING_TEXT, 'warn'); else toast(`Varaus luotu (tilaus #${r.order_no})`);
      result.replaceChildren(...[warningBox(r, { ctx, onDone: () => { result.replaceChildren(); } }), h('div', { class: 'card ok-box' }, h('h3', { text: `Varaus luotu – tilaus #${r.order_no}` }), h('p', { text: `${r.product_name}, ${fmtDay(r.starts_at)} ${fmtTime(r.starts_at)}–${fmtTime(r.ends_at)} · ${money(r.total)}` }),
        h('div', { class: 'row wrap' }, h('a', { class: 'btn', href: `#/?d=${st.date}`, text: 'Näytä päivänäkymä' }),
          (() => { const out = h('span', { class: 'muted' }); const b = h('button', { type: 'button', class: 'btn ghost', text: 'Luo maksulinkki (Visma Pay – tulossa)', onclick: () => run(b, async () => { const j = await rpc('admin_create_payment_link', { p_order_id: r.order_id }); out.textContent = j.link_url || j.link_path || j.message; }) }); return h('span', {}, b, ' ', out); })()))].filter(Boolean));
      formBox.replaceChildren(); st.session = null; loadSessions();
    }); } },
      h('h3', { text: `Vuoro: ${refs.productById.get(s.product_id)?.name || s.label}, ${fmtTime(s.starts_at)}–${fmtTime(s.ends_at)}` }),
      h('div', { class: 'row wrap' }, field('Henkilömäärä', n), auto, field('Hinta € (ohita automaattinen)', price)),
      h('h3', { text: 'Asiakas' }), cs.row, cs.found,
      cf.node, picker.node,
      field('Laskun viite / tilausnumero (valinnainen)', invRef),
      field('Sisäinen huomio', h('textarea', { name: 'note', rows: 2 })),
      cardRow,
      h('div', { class: 'row wrap' }, field('Maksutapa', method), h('label', { class: 'check' }, paid, ' Maksettu jo')),
      h('button', { class: 'btn primary', type: 'submit', text: 'Luo varaus' }));
    formBox.replaceChildren(f);
    if (reveal) revealForm(f);
  }
  root.append(h('div', { class: 'toolbar' }, h('label', { class: 'row' }, 'Päivä ', dateIn)), sessionsBox, formBox, result);
  await loadSessions(); drawForm(!!st.session);
  return [h('h1', { text: 'Uusi varaus' }), typeSwitch('', st.date), root];
}
