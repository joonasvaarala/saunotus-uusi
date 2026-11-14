// Asiakasrekisteri: lista + haku ja Lisää asiakas. Asiakas avautuu aina asiakasnäkymään #/asiakkaat/<id> (views/customer-view.js, kortit muokataan paikallaan);
// HALL-ASIAKKAAT-01: vanha asiakasmodaali (muokkauslomake, vuosikortin hallinta) on poistettu.
import { rpc } from '../sb.js';
import { customerForm } from './customerform.js';
import { h, fmtDate, dialog, field, toast, run, empty, badge, countText } from '../ui.js';

export async function render({ ctx, reload, query = new URLSearchParams(), rest = '' }) {
  const PAGE = 50; let offset = 0, search = query.get('q') || '';
  const list = h('div', { class: 'list' }), more = h('div', { class: 'row center' }), count = h('p', { class: 'muted' });
  async function load(reset) {
    if (reset) { offset = 0; list.replaceChildren(); }
    const rows = await rpc('admin_list_customers', { p_search: search || null, p_limit: PAGE, p_offset: offset });
    const total = rows[0]?.total_count ?? 0;
    if (reset && !rows.length) list.append(empty('Ei asiakkaita.'));
    for (const c of rows) list.append(h('button', { type: 'button', class: 'listrow', 'data-testid': 'customer-row', onclick: () => { location.hash = `#/asiakkaat/${c.id}`; } },
      h('span', { class: 'what' }, h('strong', { text: c.customer_kind === 'company' && c.company ? c.company : c.name }), h('small', { text: ` ${c.customer_kind === 'company' ? `${c.business_id || ''} · ${c.name} · ` : ''}${c.email || ''}${c.phone ? ' · ' + c.phone : ''}` })),
      h('span', { class: 'meta' }, c.customer_kind === 'company' ? badge('warn', 'Yritys') : badge('muted', 'Yksityinen'), c.customer_type === 'annual_card' ? badge('warn', 'Vuosikortti') : null, c.marketing_consent ? badge('ok', 'Markkinointi sallittu') : badge('muted', 'Ei markkinointia'), h('small', { text: `${c.orders_count} tilausta${c.last_visit ? ' · viimeksi ' + fmtDate(c.last_visit) : ''}` }))));
    offset += rows.length; count.textContent = `${Math.min(offset, total)} / ${countText(total, 'asiakas', 'asiakasta')}`;
    more.replaceChildren(offset < total ? h('button', { class: 'btn ghost', type: 'button', onclick: () => load(false) }, 'Näytä lisää') : '');
  }
  // Lisää asiakas: yksityis- tai yritysasiakas (yritykselle y-tunnus, laskutus- ja verkkolaskutiedot). Oikeus customers.manage.
  function addDialog() {
    const cf = customerForm({ id: 'addcust' });
    const notes = h('textarea', { name: 'notes', rows: 2 });
    const consent = h('input', { type: 'checkbox', name: 'marketing_consent' });
    const f = h('form', { class: 'stack', novalidate: true, onsubmit: (ev) => { ev.preventDefault(); run(f.querySelector('button[type=submit]'), async () => {
      const r = await rpc('admin_create_customer', { p_data: { ...cf.data(), notes: notes.value || null, marketing_consent: consent.checked } });
      toast('Asiakas lisätty'); d.close(); if (r?.id) { location.hash = `#/asiakkaat/${r.id}`; return; } load(true);
    }); } },
      cf.node, field('Muistiinpanot (sisäinen)', notes),
      h('label', { class: 'check' }, consent, ' Markkinointilupa (kirjataan aikaleimalla, lähde: admin)'),
      h('button', { class: 'btn primary', type: 'submit', text: 'Lisää asiakas' }));
    const d = dialog('Lisää asiakas', f);
  }
  // #/asiakkaat/<id> = asiakasnäkymä
  if (/^[1-9][0-9]{0,15}$/.test(String(rest || ''))) {
    const { renderCustomerView } = await import('./customer-view.js');
    return renderCustomerView({ ctx, rpc, id: Number(rest) });
  }
  let t; const q = h('input', { type: 'search', value: search, placeholder: 'Hae nimellä, sähköpostilla tai puhelimella', 'aria-label': 'Hae asiakkaita', oninput: (e) => { search = e.target.value; clearTimeout(t); t = setTimeout(() => load(true), 250); } });
  // Vanha osoite #/asiakkaat?id=<id> (kirjanmerkit) ohjataan asiakasnäkymään
  const directId = query.get('id');
  if (/^[1-9]\d{0,15}$/.test(directId || '')) { location.replace(`#/asiakkaat/${directId}`); return []; }
  await load(true);
  const canAdd = ctx.can('customers.manage');
  return [h('div', { class: 'row between wrap' }, h('h1', { text: 'Asiakkaat' }), canAdd ? h('button', { type: 'button', class: 'btn primary sm', onclick: addDialog }, 'Lisää asiakas') : null), h('div', { class: 'card' }, q), count, list, more];
}
