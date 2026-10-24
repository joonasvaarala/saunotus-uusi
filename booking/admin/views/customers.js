// Asiakasrekisteri: lista + haku, asiakaskortti (tilaushistoria, markkinointisuostumus, vuosikortti), muokkaus.
import { rpc } from '../sb.js';
import { customerForm, validBusinessId, normBusinessId } from './customerform.js';
import { navText } from '../nav-texts.js';
import { normalizeCode } from '../../shop/src/discount-code-logic.js';
import { amText, loadAmTexts } from '../annual-manage-texts.js';
import { h, fmtDT, fmtDate, todayHel, addDays, money, dialog, field, toast, run, empty, payBadge, statusBadge, badge } from '../ui.js';

export async function render({ ctx, reload, query = new URLSearchParams() }) {
  const PAGE = 50; let offset = 0, search = query.get('q') || '';
  const list = h('div', { class: 'list' }), more = h('div', { class: 'row center' }), count = h('p', { class: 'muted' });
  async function load(reset) {
    if (reset) { offset = 0; list.replaceChildren(); }
    const rows = await rpc('admin_list_customers', { p_search: search || null, p_limit: PAGE, p_offset: offset });
    const total = rows[0]?.total_count ?? 0;
    if (reset && !rows.length) list.append(empty('Ei asiakkaita.'));
    for (const c of rows) list.append(h('button', { type: 'button', class: 'listrow', onclick: () => card(c.id) },
      h('span', { class: 'what' }, h('strong', { text: c.customer_kind === 'company' && c.company ? c.company : c.name }), h('small', { text: ` ${c.customer_kind === 'company' ? `${c.business_id || ''} · ${c.name} · ` : ''}${c.email || ''}${c.phone ? ' · ' + c.phone : ''}` })),
      h('span', { class: 'meta' }, c.customer_kind === 'company' ? badge('warn', 'Yritys') : badge('muted', 'Yksityinen'), c.customer_type === 'annual_card' ? badge('warn', 'Vuosikortti') : null, c.marketing_consent ? badge('ok', 'Markkinointi sallittu') : badge('muted', 'Ei markkinointia'), h('small', { text: `${c.orders_count} tilausta${c.last_visit ? ' · viimeksi ' + fmtDate(c.last_visit) : ''}` }))));
    offset += rows.length; count.textContent = `${Math.min(offset, total)} / ${total} asiakasta`;
    more.replaceChildren(offset < total ? h('button', { class: 'btn ghost', type: 'button', onclick: () => load(false) }, 'Näytä lisää') : '');
  }
  async function card(id) {
    const c = await rpc('admin_get_customer', { p_id: id });
    const f = h('form', { class: 'stack' },
      field('Nimi', h('input', { name: 'name', value: c.name, required: true })), field('Sähköposti', h('input', { name: 'email', type: 'email', value: c.email || '' })),
      field('Puhelin', h('input', { name: 'phone', value: c.phone || '' })),
      h('p', { class: 'muted' }, 'Asiakastyyppi: ', c.customer_kind === 'company' ? badge('warn', 'Yritysasiakas') : badge('muted', 'Yksityisasiakas')),
      field(c.customer_kind === 'company' ? 'Yrityksen nimi' : 'Yritys (valinnainen)', h('input', { name: 'company', value: c.company || '', required: c.customer_kind === 'company' || null })),
      c.customer_kind === 'company' ? h('div', { class: 'stack box' },
        field('Y-tunnus', h('input', { name: 'business_id', value: c.business_id || '', required: true, placeholder: '1234567-8' }), 'Muoto 1234567-8; tarkistenumero tarkistetaan.'),
        field('Katuosoite', h('input', { name: 'address', value: c.address || '' })), h('div', { class: 'row wrap' }, field('Postinumero', h('input', { name: 'zip', value: c.zip || '', maxlength: 5 })), field('Postitoimipaikka', h('input', { name: 'city', value: c.city || '' }))),
        field('Verkkolaskuosoite (OVT)', h('input', { name: 'einvoice_address', value: c.einvoice_address || '' })), field('Verkkolaskuoperaattori (välittäjätunnus)', h('input', { name: 'einvoice_operator', value: c.einvoice_operator || '' }), 'Osoite ja välittäjä yhdessä tai molemmat tyhjiksi.'),
        field('Viite / tilausnumero (oletus uusille tilauksille)', h('input', { name: 'invoice_reference', value: c.invoice_reference || '' }))) : null,
      field('Muistiinpanot (sisäinen)', h('textarea', { name: 'notes', rows: 3, value: c.notes || '' })),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'marketing_consent', checked: c.marketing_consent || null }), ' Markkinointilupa (kirjataan aikaleimalla, lähde: admin)'),
      h('p', { class: 'muted', text: c.marketing_consent_at ? `Lupa annettu ${fmtDT(c.marketing_consent_at)} (lähde: ${c.marketing_consent_source || '–'})` : 'Ei markkinointilupaa.' }),
      h('button', { class: 'btn primary', type: 'submit', text: 'Tallenna' }));
    f.marketing_consent.checked = !!c.marketing_consent;
    const d = dialog(c.name, h('div', { class: 'stack' }, f, cardsBox(c), h('h3', { text: 'Tilaushistoria' }),
      (c.orders || []).length ? h('ul', { class: 'reslist' }, c.orders.map((o) => h('li', { class: 'resrow' }, h('span', {}, h('strong', { text: `#${o.order_no}` }), ` ${fmtDT(o.created_at)} · ${money(o.total)} · ${o.channel}`, h('br'), (o.reservations || []).map((r) => `${r.product_name} ${fmtDT(r.starts_at)} (${r.persons} hlö)`).join('; ')), h('span', { class: 'meta' }, statusBadge(o.status), payBadge(o.payment_status))))) : empty('Ei tilauksia.')));
    f.addEventListener('submit', (ev) => { ev.preventDefault(); run(f.querySelector('button'), async () => {
      const fd = new FormData(f);
      const patch = { name: fd.get('name'), email: fd.get('email') || null, phone: fd.get('phone') || null, company: fd.get('company') || null, notes: fd.get('notes') || null, marketing_consent: f.marketing_consent.checked };
      if (c.customer_kind === 'company') {
        if (!validBusinessId(fd.get('business_id'))) throw new Error('Tarkista y-tunnus (muoto 1234567-8, tarkistenumero ei täsmää)');
        if (!!String(fd.get('einvoice_address')).trim() !== !!String(fd.get('einvoice_operator')).trim()) throw new Error('Anna verkkolaskuosoite ja välittäjätunnus yhdessä tai jätä molemmat tyhjiksi');
        Object.assign(patch, { business_id: normBusinessId(fd.get('business_id')), address: fd.get('address') || null, zip: fd.get('zip') || null, city: fd.get('city') || null,
          einvoice_address: fd.get('einvoice_address') || null, einvoice_operator: fd.get('einvoice_operator') || null, invoice_reference: fd.get('invoice_reference') || null });
      }
      await rpc('admin_update_customer', { p_id: id, p_patch: patch });
      toast('Tallennettu'); d.close(); load(true);
    }); });
  }
  // Lisää asiakas: yksityis- tai yritysasiakas (yritykselle y-tunnus, laskutus- ja verkkolaskutiedot). Oikeus customers.manage.
  function addDialog() {
    const cf = customerForm({ id: 'addcust' });
    const notes = h('textarea', { name: 'notes', rows: 2 });
    const consent = h('input', { type: 'checkbox', name: 'marketing_consent' });
    const f = h('form', { class: 'stack', novalidate: true, onsubmit: (ev) => { ev.preventDefault(); run(f.querySelector('button[type=submit]'), async () => {
      const r = await rpc('admin_create_customer', { p_data: { ...cf.data(), notes: notes.value || null, marketing_consent: consent.checked } });
      toast('Asiakas lisätty'); d.close(); load(true); if (r?.id) card(r.id);
    }); } },
      cf.node, field('Muistiinpanot (sisäinen)', notes),
      h('label', { class: 'check' }, consent, ' Markkinointilupa (kirjataan aikaleimalla, lähde: admin)'),
      h('button', { class: 'btn primary', type: 'submit', text: 'Lisää asiakas' }));
    const d = dialog('Lisää asiakas', f);
  }
  // Vuosikortti: ilmaiset varaukset yleisille vuoroille (1 hlö, yksi tuleva varaus kerrallaan). Myöntö/peruutus: oikeus annual_cards.manage (manager + admin).
  function cardsBox(c) {
    const can = ctx.can('annual_cards.manage');
    const cards = c.annual_cards || [];
    const grant = h('form', { class: 'row wrap box' }, field('Alkaa', h('input', { type: 'date', name: 'vf', value: todayHel(), required: true })), field('Päättyy', h('input', { type: 'date', name: 'vt', value: addDays(todayHel(), 365), required: true })),
      field('Muistiinpano', h('input', { name: 'vn' })), field(amText('ui.admin.annual_manage.code_label_optional'), h('input', { name: 'vcode', maxlength: 40, autocomplete: 'off', oninput: (e) => { e.target.value = normalizeCode(e.target.value); } }), amText('ui.admin.annual_manage.code_hint')), h('button', { class: 'btn', type: 'submit', text: 'Myönnä vuosikortti' }));
    grant.addEventListener('submit', (ev) => { ev.preventDefault(); run(grant.querySelector('button'), async () => { const created = await rpc('admin_create_annual_card', { p_customer_id: c.id, p_valid_from: grant.vf.value, p_valid_to: grant.vt.value || null, p_code: normalizeCode(grant.vcode.value) || null, p_notes: grant.vn.value || null }); toast(`Vuosikortti myönnetty. Koodi: ${created.code}`); document.querySelector('dialog')?.close(); load(true); }); });
    return h('div', { class: 'stack' }, h('h3', { text: 'Vuosikortti' }),
      cards.length ? h('ul', { class: 'reslist' }, cards.map((a) => h('li', { class: 'resrow' }, h('span', {}, `${a.code ? a.code + ' · ' : ''}${fmtDate(a.valid_from + 'T12:00:00Z')} – ${fmtDate(a.valid_to + 'T12:00:00Z')}${a.notes ? ' · ' + a.notes : ''}`),
        h('span', { class: 'meta' }, a.active ? badge('ok', 'Voimassa') : badge('muted', 'Peruttu'),
          can && a.active ? h('button', { type: 'button', class: 'btn danger sm', onclick: (e) => run(e.target, async () => {
            if (!confirm('Perutaanko vuosikortti?')) return;
            const cancelFuture = confirm('Perutaanko myös kortin tulevat varaukset? (OK = peru, Peruuta = säilytä)');
            const r = await rpc('admin_revoke_annual_card', { p_id: a.id, p_cancel_future: cancelFuture });
            toast(`Vuosikortti peruttu${r.cancelled ? `, ${r.cancelled} varausta peruttu` : ''}`); document.querySelector('dialog')?.close(); load(true); }) }, 'Peru kortti') : null)))) : empty('Ei vuosikorttia.'),
      can ? grant : null);
  }
  let t; const q = h('input', { type: 'search', value: search, placeholder: 'Hae nimellä, sähköpostilla tai puhelimella', 'aria-label': 'Hae asiakkaita', oninput: (e) => { search = e.target.value; clearTimeout(t); t = setTimeout(() => load(true), 250); } });
  await Promise.all([load(true), ctx.can('annual_cards.manage') ? loadAmTexts(rpc) : null]);   // booking_152: koodivihje (ui.admin.annual_manage.*)
  const directId = query.get('id');
  if (/^\d+$/.test(directId || '')) card(Number(directId)).catch((e) => toast(e?.message || navText('ui.admin.nav.customer_not_found'), 'err'));
  const canAdd = ctx.can('customers.manage');
  return [h('div', { class: 'row between wrap' }, h('h1', { text: 'Asiakkaat' }), canAdd ? h('button', { type: 'button', class: 'btn primary sm', onclick: addDialog }, 'Lisää asiakas') : null), h('div', { class: 'card' }, q), count, list, more];
}
