// Yritysten tarjouspyynnöt (booking_72): lista + tila. Lukee admin_list_business_quotes, tallentaa admin_set_business_quote_status.
// Vain admin/manager (quotes.manage). Hallinnan tekstit ovat suomeksi (ei asiakkaan site_texts-tuontia).
import { rpc } from '../sb.js';
import { h, errMsg, empty, field, fmtDT } from '../ui.js';

const FILTERS = [['', 'Kaikki'], ['new', 'Uusi'], ['handled', 'Käsitelty'], ['offered', 'Tarjottu'], ['closed', 'Suljettu']];
const LABEL = Object.fromEntries(FILTERS.filter(([k]) => k));
const OFF = { ritual: 'Saunarituaali', forest_yoga: 'Metsäjoogaa', campfire_meal: 'Nuotioruokailu', sauna: 'Saunotus', vihta_workshop: 'Vihtatyöpaja', other: 'Muu' };

export async function render({ reload, query }) {
  const q0 = query || new URLSearchParams();
  const cur = FILTERS.some(([k]) => k === (q0.get('tila') || '')) ? (q0.get('tila') || '') : '';
  let rows;
  try { rows = await rpc('admin_list_business_quotes', { p_status: cur || null }); }
  catch (e) { return [h('h1', { text: 'Yritykset' }), h('p', { class: 'err', role: 'alert', text: errMsg(e) })]; }
  if (!Array.isArray(rows)) rows = [];

  const filters = h('div', { class: 'row wrap', role: 'navigation', 'aria-label': 'Tila' }, FILTERS.map(([v, label]) =>
    h('a', { href: `#/yritykset${v ? `?tila=${v}` : ''}`, 'aria-current': v === cur ? 'page' : null, class: `btn sm${v === cur ? ' primary' : ' ghost'}`, text: label })));

  const card = (q) => {
    const sel = h('select', { 'aria-label': `Tila, ${q.company_name}` }, FILTERS.filter(([k]) => k).map(([k, label]) => h('option', { value: k, text: label })));
    sel.value = LABEL[q.status] ? q.status : 'new';
    const note = h('textarea', { rows: 2, maxlength: 2000, value: q.admin_note || '', 'aria-label': `Muistiinpano, ${q.company_name}` });
    const msg = h('p', { role: 'status' });
    const save = h('button', { type: 'button', class: 'btn sm', text: 'Tallenna' });
    save.addEventListener('click', async () => {
      save.disabled = true; msg.textContent = ''; msg.className = '';
      try {
        await rpc('admin_set_business_quote_status', { p_id: q.id, p_status: sel.value, p_note: note.value });
        msg.textContent = 'Tallennettu'; msg.className = 'muted';
        reload();
      } catch (e) { msg.textContent = errMsg(e); msg.className = 'err'; }
      finally { save.disabled = false; }
    });
    const offs = (Array.isArray(q.offerings) ? q.offerings : []).map((c) => OFF[c] || c).join(', ');
    return h('article', { class: 'card' },
      h('h2', { text: q.company_name || '–' }),
      h('p', { text: [q.contact_name, q.email, q.phone].filter(Boolean).join(' · ') }),
      h('p', { text: `Ajankohta: ${q.preferred_when || '–'} · ${q.persons ?? '–'} henkilöä · ${LABEL[q.status] || q.status}` }),
      h('p', { text: `Sisällöt: ${offs || '–'}${q.offering_other ? ` (${q.offering_other})` : ''}` }),
      q.message ? h('p', { text: q.message }) : null,
      h('p', { class: 'muted', text: fmtDT(q.created_at) }),
      field('Tila', sel),
      field('Muistiinpano', note),
      h('div', { class: 'row wrap' }, save, msg));
  };

  return [
    h('h1', { text: 'Yritykset' }),
    h('p', { class: 'muted', text: 'Tarjouspyynnöt työntekijäpäivästä. Saunavuorojen varaukset näkyvät Varaukset-näkymässä.' }),
    filters,
    rows.length ? h('div', { class: 'stack' }, ...rows.map(card)) : empty('Ei tarjouspyyntöjä.'),
  ];
}
