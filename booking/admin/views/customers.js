// Asiakasrekisteri: lista + haku, asiakaskortti (tilaushistoria, markkinointisuostumus, vuosikortti), muokkaus.
import { rpc } from '../sb.js';
import { h, fmtDT, fmtDate, todayHel, addDays, money, dialog, field, toast, run, empty, payBadge, statusBadge, badge } from '../ui.js';

export async function render({ ctx, reload }) {
  const PAGE = 50; let offset = 0, search = '';
  const list = h('div', { class: 'list' }), more = h('div', { class: 'row center' }), count = h('p', { class: 'muted' });
  async function load(reset) {
    if (reset) { offset = 0; list.replaceChildren(); }
    const rows = await rpc('admin_list_customers', { p_search: search || null, p_limit: PAGE, p_offset: offset });
    const total = rows[0]?.total_count ?? 0;
    if (reset && !rows.length) list.append(empty('Ei asiakkaita.'));
    for (const c of rows) list.append(h('button', { type: 'button', class: 'listrow', onclick: () => card(c.id) },
      h('span', { class: 'what' }, h('strong', { text: c.name }), h('small', { text: ` ${c.email || ''}${c.phone ? ' · ' + c.phone : ''}` })),
      h('span', { class: 'meta' }, c.customer_type === 'annual_card' ? badge('warn', 'Vuosikortti') : null, c.marketing_consent ? badge('ok', 'Markkinointi sallittu') : badge('muted', 'Ei markkinointia'), h('small', { text: `${c.orders_count} tilausta${c.last_visit ? ' · viimeksi ' + fmtDate(c.last_visit) : ''}` }))));
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
    const d = dialog(c.name, h('div', { class: 'stack' }, f, cardsBox(c), h('h3', { text: 'Tilaushistoria' }),
      (c.orders || []).length ? h('ul', { class: 'reslist' }, c.orders.map((o) => h('li', { class: 'resrow' }, h('span', {}, h('strong', { text: `#${o.order_no}` }), ` ${fmtDT(o.created_at)} · ${money(o.total)} · ${o.channel}`, h('br'), (o.reservations || []).map((r) => `${r.product_name} ${fmtDT(r.starts_at)} (${r.persons} hlö)`).join('; ')), h('span', { class: 'meta' }, statusBadge(o.status), payBadge(o.payment_status))))) : empty('Ei tilauksia.')));
    f.addEventListener('submit', (ev) => { ev.preventDefault(); run(f.querySelector('button'), async () => {
      const fd = new FormData(f);
      await rpc('admin_update_customer', { p_id: id, p_patch: { name: fd.get('name'), email: fd.get('email') || null, phone: fd.get('phone') || null, company: fd.get('company') || null, notes: fd.get('notes') || null, marketing_consent: f.marketing_consent.checked } });
      toast('Tallennettu'); d.close(); load(true);
    }); });
  }
  // Vuosikortti: ilmaiset varaukset yleisille vuoroille (1 hlö, yksi tuleva varaus kerrallaan). Myöntö/peruutus: oikeus annual_cards.manage (manager + admin).
  function cardsBox(c) {
    const can = ctx.can('annual_cards.manage');
    const cards = c.annual_cards || [];
    const grant = h('form', { class: 'row wrap box' }, field('Alkaa', h('input', { type: 'date', name: 'vf', value: todayHel(), required: true })), field('Päättyy', h('input', { type: 'date', name: 'vt', value: addDays(todayHel(), 365), required: true })),
      field('Muistiinpano', h('input', { name: 'vn' })), h('button', { class: 'btn', type: 'submit', text: 'Myönnä vuosikortti' }));
    grant.addEventListener('submit', (ev) => { ev.preventDefault(); run(grant.querySelector('button'), async () => { await rpc('admin_grant_annual_card', { p_customer_id: c.id, p_valid_from: grant.vf.value, p_valid_to: grant.vt.value, p_notes: grant.vn.value || null }); toast('Vuosikortti myönnetty'); document.querySelector('dialog')?.close(); load(true); }); });
    return h('div', { class: 'stack' }, h('h3', { text: 'Vuosikortti' }),
      cards.length ? h('ul', { class: 'reslist' }, cards.map((a) => h('li', { class: 'resrow' }, h('span', {}, `${fmtDate(a.valid_from + 'T12:00:00Z')} – ${fmtDate(a.valid_to + 'T12:00:00Z')}${a.notes ? ' · ' + a.notes : ''}`),
        h('span', { class: 'meta' }, a.active ? badge('ok', 'Voimassa') : badge('muted', 'Peruttu'),
          can && a.active ? h('button', { type: 'button', class: 'btn danger sm', onclick: (e) => run(e.target, async () => {
            if (!confirm('Perutaanko vuosikortti?')) return;
            const cancelFuture = confirm('Perutaanko myös kortin tulevat varaukset? (OK = peru, Peruuta = säilytä)');
            const r = await rpc('admin_revoke_annual_card', { p_id: a.id, p_cancel_future: cancelFuture });
            toast(`Vuosikortti peruttu${r.cancelled ? `, ${r.cancelled} varausta peruttu` : ''}`); document.querySelector('dialog')?.close(); load(true); }) }, 'Peru kortti') : null)))) : empty('Ei vuosikorttia.'),
      can ? grant : null);
  }
  let t; const q = h('input', { type: 'search', placeholder: 'Hae nimellä, sähköpostilla tai puhelimella', 'aria-label': 'Hae asiakkaita', oninput: (e) => { search = e.target.value; clearTimeout(t); t = setTimeout(() => load(true), 250); } });
  await load(true);
  return [h('h1', { text: 'Asiakkaat' }), h('div', { class: 'card' }, q), count, list, more];
}
