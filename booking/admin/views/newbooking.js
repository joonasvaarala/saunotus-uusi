// Manuaalinen varaus (puhelin, paikan päällä, sähköposti): tuote → päivä → vuoro → henkilöt → asiakas → maksutapa/maksettu.
// Vuosikorttiasiakkaalle yleiseen vuoroon: "Vuosikorttivaraus" (ilmainen, 1 hlö, yksi tuleva varaus kerrallaan).
import { rpc } from '../sb.js';
import { h, field, toast, run, fmtTime, fmtDay, money, todayHel, empty } from '../ui.js';

const priceFor = (s, n) => (s.price_mode === 'per_person' ? s.unit_price * n : s.price_mode === 'fixed' ? s.base_price : s.base_price + Math.max(0, n - (s.included_persons || 0)) * (s.extra_person_price || 0));

export async function render({ refs, query }) {
  const st = { date: /^\d{4}-\d\d-\d\d$/.test(query.get('d') || '') ? query.get('d') : todayHel(), session: null, customer: null };
  const root = h('div', { class: 'stack' });
  const sessionsBox = h('div', { class: 'stack' }); const formBox = h('div', {}); const result = h('div', {});
  const dateIn = h('input', { type: 'date', value: st.date, 'aria-label': 'Päivä', onchange: (e) => { st.date = e.target.value; st.session = null; loadSessions(); drawForm(); } });
  async function loadSessions() {
    sessionsBox.replaceChildren(h('p', { class: 'muted', text: 'Ladataan…' }));
    const v = await rpc('admin_day_view', { p_date: st.date });
    const list = (v.sessions || []).filter((s) => s.status !== 'closed');
    sessionsBox.replaceChildren(list.length ? h('div', { class: 'slotpick', role: 'radiogroup', 'aria-label': 'Vuoro' }, list.map((s) => {
      const ok = s.status === 'available';
      const b = h('button', { type: 'button', role: 'radio', 'aria-checked': st.session?.rule_id === s.rule_id ? 'true' : 'false', class: `slotbtn ${s.status}`, disabled: !ok || null, onclick: () => { st.session = s; sessionsBox.querySelectorAll('.slotbtn').forEach((x) => x.setAttribute('aria-checked', 'false')); b.setAttribute('aria-checked', 'true'); drawForm(); } },
        h('strong', { text: `${fmtTime(s.starts_at)}–${fmtTime(s.ends_at)}` }), h('span', { text: refs.productById.get(s.product_id)?.name || s.label }), h('small', { text: ok ? (s.mode === 'exclusive' ? 'yksityisvuoro vapaa' : `${s.remaining} vapaana`) : s.status === 'full' ? 'täynnä' : 'ei varattavissa' }));
      return b;
    })) : empty('Ei vuoroja tälle päivälle.'));
  }
  function drawForm() {
    const s = st.session;
    if (!s) { formBox.replaceChildren(h('p', { class: 'muted', text: 'Valitse vuoro.' })); return; }
    const max = Math.min(s.max_persons || 50, s.remaining);
    const n = h('input', { type: 'number', name: 'n', min: s.min_persons, max, value: s.min_persons, required: true });
    const price = h('input', { type: 'number', step: '0.01', min: '0', name: 'price', placeholder: 'Automaattinen' });
    const auto = h('strong', { class: 'autoprice' });
    const upd = () => { auto.textContent = `Hinta ${money(priceFor(s, +n.value || 0))}`; }; n.addEventListener('input', upd); upd();
    const found = h('div', { class: 'found' });
    const cardChk = h('input', { type: 'checkbox', name: 'cardbooking' });
    const cardRow = h('label', { class: 'check', hidden: true }, cardChk, ' Vuosikorttivaraus (ilmainen, 1 hlö; yksi tuleva varaus kerrallaan)');
    const syncCard = () => { const ok = st.customer?.customer_type === 'annual_card' && s.mode === 'shared'; cardRow.hidden = !ok; if (!ok) cardChk.checked = false; };
    const search = h('input', { type: 'search', placeholder: 'Hae olemassa olevaa asiakasta (nimi/sähköposti/puhelin)', 'aria-label': 'Hae asiakas' });
    let timer; search.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(async () => {
      if (search.value.trim().length < 2) { found.replaceChildren(); return; }
      const rows = await rpc('admin_list_customers', { p_search: search.value, p_limit: 5, p_offset: 0 });
      found.replaceChildren(...rows.map((c) => h('button', { type: 'button', class: 'listrow', onclick: () => { st.customer = c; syncCard(); f.elements.cname.value = c.name; f.elements.cemail.value = c.email || ''; f.elements.cphone.value = c.phone || ''; found.replaceChildren(h('p', { class: 'muted', text: `Valittu asiakas: ${c.name}` })); } }, h('strong', { text: c.name }), h('small', { text: ` ${c.email || ''} ${c.phone || ''}` }))));
    }, 250); });
    const method = h('select', { name: 'method' }, refs.methods.filter((m) => m.active).map((m) => h('option', { value: m.code, text: m.label, selected: m.code === 'pay_later' || null })));
    const paid = h('input', { type: 'checkbox', name: 'paid' });
    const f = h('form', { class: 'stack card', onsubmit: (ev) => { ev.preventDefault(); run(f.querySelector('button[type=submit]'), async () => {
      const cust = st.customer ? { p_customer_id: st.customer.id } : { p_customer: { name: f.elements.cname.value.trim(), email: f.elements.cemail.value.trim(), phone: f.elements.cphone.value.trim() } };
      const r = cardChk.checked ? await rpc('admin_create_annual_card_booking', { p_customer_id: st.customer.id, p_rule_id: s.rule_id, p_date: st.date, p_note: f.elements.note.value || null })
        : await rpc('admin_create_booking', { p_rule_id: s.rule_id, p_date: st.date, p_persons: +n.value, ...cust, p_payment_method: method.value, p_paid: paid.checked, p_note: f.elements.note.value || null, p_price: price.value ? +price.value : null });
      toast(`Varaus luotu (tilaus #${r.order_no})`);
      result.replaceChildren(h('div', { class: 'card ok-box' }, h('h3', { text: `Varaus luotu – tilaus #${r.order_no}` }), h('p', { text: `${r.product_name}, ${fmtDay(r.starts_at)} ${fmtTime(r.starts_at)}–${fmtTime(r.ends_at)} · ${money(r.total)}` }),
        h('div', { class: 'row wrap' }, h('a', { class: 'btn', href: `#/?d=${st.date}`, text: 'Näytä päivänäkymä' }),
          (() => { const out = h('span', { class: 'muted' }); const b = h('button', { type: 'button', class: 'btn ghost', text: 'Luo maksulinkki (Visma Pay – tulossa)', onclick: () => run(b, async () => { const j = await rpc('admin_create_payment_link', { p_order_id: r.order_id }); out.textContent = j.link_url || j.message; }) }); return h('span', {}, b, ' ', out); })())));
      formBox.replaceChildren(); st.session = null; loadSessions();
    }); } },
      h('h3', { text: `Vuoro: ${refs.productById.get(s.product_id)?.name || s.label}, ${fmtTime(s.starts_at)}–${fmtTime(s.ends_at)}` }),
      h('div', { class: 'row wrap' }, field('Henkilömäärä', n), auto, field('Hinta € (ohita automaattinen)', price)),
      h('h3', { text: 'Asiakas' }), search, found,
      h('div', { class: 'row wrap' }, field('Nimi', h('input', { name: 'cname', required: true, oninput: () => { st.customer = null; syncCard(); } })), field('Sähköposti', h('input', { name: 'cemail', type: 'email', required: true })), field('Puhelin', h('input', { name: 'cphone', required: true }))),
      field('Sisäinen huomio', h('textarea', { name: 'note', rows: 2 })),
      cardRow,
      h('div', { class: 'row wrap' }, field('Maksutapa', method), h('label', { class: 'check' }, paid, ' Maksettu jo')),
      h('button', { class: 'btn primary', type: 'submit', text: 'Luo varaus' }));
    formBox.replaceChildren(f);
  }
  root.append(h('div', { class: 'toolbar' }, h('label', { class: 'row' }, 'Päivä ', dateIn)), sessionsBox, formBox, result);
  await loadSessions(); drawForm();
  return [h('h1', { text: 'Uusi varaus' }), root];
}
