// Asiakasrekisteri: lista + haku, asiakaskortti (tilaushistoria, markkinointisuostumus), muokkaus.
import { rpc } from '../sb.js';
import { h, fmtDT, fmtDate, money, dialog, field, toast, run, empty, payBadge, statusBadge, badge } from '../ui.js';

export async function render({ reload }) {
  const PAGE = 50; let offset = 0, search = '';
  const list = h('div', { class: 'list' }), more = h('div', { class: 'row center' }), count = h('p', { class: 'muted' });
  async function load(reset) {
    if (reset) { offset = 0; list.replaceChildren(); }
    const rows = await rpc('admin_list_customers', { p_search: search || null, p_limit: PAGE, p_offset: offset });
    const total = rows[0]?.total_count ?? 0;
    if (reset && !rows.length) list.append(empty('Ei asiakkaita.'));
    for (const c of rows) list.append(h('button', { type: 'button', class: 'listrow', onclick: () => card(c.id) },
      h('span', { class: 'what' }, h('strong', { text: c.name }), h('small', { text: ` ${c.email || ''}${c.phone ? ' · ' + c.phone : ''}` })),
      h('span', { class: 'meta' }, c.marketing_consent ? badge('ok', 'Markkinointi sallittu') : badge('muted', 'Ei markkinointia'), h('small', { text: `${c.orders_count} tilausta${c.last_visit ? ' · viimeksi ' + fmtDate(c.last_visit) : ''}` }))));
    offset += rows.length; count.textContent = `${Math.min(offset, total)} / ${total} asiakasta`;
    more.replaceChildren(offset < total ? h('button', { class: 'btn ghost', type: 'button', onclick: () => load(false) }, 'Näytä lisää') : '');
  }
  async function card(id) {
    const c = await rpc('admin_get_customer', { p_id: id });
    const f = h('form', { class: 'stack' },
      field('Nimi', h('input', { name: 'name', value: c.name, required: true })), field('Sähköposti', h('input', { name: 'email', type: 'email', value: c.email || '' })),
      field('Puhelin', h('input', { name: 'phone', value: c.phone || '' })), field('Yritys', h('input', { name: 'company', value: c.company || '' })),
      field('Muistiinpanot (sisäinen)', h('textarea', { name: 'notes', rows: 3, value: c.notes || '' })),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'marketing_consent', checked: c.marketing_consent || null }), ' Markkinointilupa (kirjataan aikaleimalla, lähde: admin)'),
      h('p', { class: 'muted', text: c.marketing_consent_at ? `Lupa annettu ${fmtDT(c.marketing_consent_at)} (lähde: ${c.marketing_consent_source || '–'})` : 'Ei markkinointilupaa.' }),
      h('button', { class: 'btn primary', type: 'submit', text: 'Tallenna' }));
    f.marketing_consent.checked = !!c.marketing_consent;
    const d = dialog(c.name, h('div', { class: 'stack' }, f, h('h3', { text: 'Tilaushistoria' }),
      (c.orders || []).length ? h('ul', { class: 'reslist' }, c.orders.map((o) => h('li', { class: 'resrow' }, h('span', {}, h('strong', { text: `#${o.order_no}` }), ` ${fmtDT(o.created_at)} · ${money(o.total)} · ${o.channel}`, h('br'), (o.reservations || []).map((r) => `${r.product_name} ${fmtDT(r.starts_at)} (${r.persons} hlö)`).join('; ')), h('span', { class: 'meta' }, statusBadge(o.status), payBadge(o.payment_status))))) : empty('Ei tilauksia.')));
    f.addEventListener('submit', (ev) => { ev.preventDefault(); run(f.querySelector('button'), async () => {
      const fd = new FormData(f);
      await rpc('admin_update_customer', { p_id: id, p_patch: { name: fd.get('name'), email: fd.get('email') || null, phone: fd.get('phone') || null, company: fd.get('company') || null, notes: fd.get('notes') || null, marketing_consent: f.marketing_consent.checked } });
      toast('Tallennettu'); d.close(); load(true);
    }); });
  }
  let t; const q = h('input', { type: 'search', placeholder: 'Hae nimellä, sähköpostilla tai puhelimella', 'aria-label': 'Hae asiakkaita', oninput: (e) => { search = e.target.value; clearTimeout(t); t = setTimeout(() => load(true), 250); } });
  await load(true);
  return [h('h1', { text: 'Asiakkaat' }), h('div', { class: 'card' }, q), count, list, more];
}
