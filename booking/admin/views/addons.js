// Lisäpalvelut: (1) valitsin varauslomakkeille (määrä per lisäpalvelu, enintään henkilömäärä × max/henkilö, korkeintaan 99),
// (2) ylläpito (nimi, kuvaus, hinta, ALV, vuorotyypit, aktiivisuus; oikeus catalog.edit kuten tuotetiedoissa).
import { rpc } from '../sb.js';
import { h, dialog, field, toast, run, money, badge, empty } from '../ui.js';
import { icon } from '../icons.js';

export const addonLimit = (a, persons) => Math.min((a.max_per_person ?? 99) * Math.max(0, persons || 0), 99);
export const MODE_LABEL = { shared: 'Yleinen vuoro', exclusive: 'Yksityisvuoro' };
const VAT = [25.5, 24, 14, 13.5, 10, 0];

// Valitsin: addons = aktiiviset (admin_list_addons), getPersons() = nykyinen henkilömäärä, getMode() = 'shared'|'exclusive'.
export function addonPicker(addons, { getPersons, getMode, onChange }) {
  const box = h('fieldset', { class: 'box addon-picker' }, h('legend', {}, icon('leaf', 18), ' Lisäpalvelut'));
  const rows = [];
  const total = h('strong', { class: 'addon-total' });
  for (const a of addons.filter((x) => x.active)) {
    const q = h('input', { type: 'number', min: 0, max: 0, value: 0, inputmode: 'numeric', 'aria-label': `${a.name}, määrä`, oninput: () => { sync(); onChange?.(); } });
    const row = h('div', { class: 'row wrap addonrow' }, h('span', { class: 'grow' }, h('strong', { text: a.name }), h('small', { text: ` ${money(a.price)} / kpl${a.description ? ' · ' + a.description : ''}` })), q);
    rows.push({ a, q, row });
    box.append(row);
  }
  box.append(h('p', { class: 'muted' }, 'Lisäpalvelut yhteensä: ', total));
  function sync() {
    const mode = getMode(); const n = getPersons();
    let sum = 0, any = false;
    for (const { a, q, row } of rows) {
      const ok = (a.applies_modes || []).includes(mode); row.hidden = !ok;
      const lim = ok ? addonLimit(a, n) : 0; q.max = lim;
      if (+q.value > lim) q.value = lim;
      if (+q.value < 0 || !Number.isInteger(+q.value)) q.value = Math.max(0, Math.floor(+q.value) || 0);
      if (ok) any = true; sum += ok ? +q.value * a.price : 0;
    }
    box.hidden = !any; total.textContent = money(sum);
    return sum;
  }
  sync();
  return {
    node: box, sync,
    // Esitäyttö: [{ addon_id | id, quantity }]
    set(list) { for (const { a, q } of rows) q.value = (list || []).find((x) => (x.addon_id ?? x.id) === a.id)?.quantity ?? 0; sync(); onChange?.(); },
    // [{ id, quantity }] – vain määrät > 0
    value: () => rows.filter(({ q, a, row }) => !row.hidden && +q.value > 0).map(({ a, q }) => ({ id: a.id, quantity: +q.value })),
    total: () => sync(),
  };
}

// Ylläpitonäkymä (Tuotteet-sivun alaosa)
export async function addonsAdmin({ ctx }) {
  const can = ctx.can('catalog.edit');
  const wrap = h('section', { class: 'stack', 'aria-labelledby': 'addons-h' });
  async function draw() {
    const rows = await rpc('admin_list_addons');
    const list = h('div', { class: 'list' }, rows.length ? rows.map((a) => h('button', { type: 'button', class: 'listrow', onclick: () => edit(a) },
      h('span', { class: 'what' }, h('strong', { text: a.name }), h('small', { text: ` ${(a.applies_modes || []).map((m) => MODE_LABEL[m]).join(', ')} · max ${a.max_per_person} / hlö` })),
      h('span', { class: 'meta' }, a.active ? badge('ok', 'Käytössä') : badge('muted', 'Piilotettu'), h('strong', { text: money(a.price) }), h('small', { text: `ALV ${a.vat_rate} %` })))) : [empty('Ei lisäpalveluita.')]);
    wrap.replaceChildren(h('div', { class: 'row between' }, h('h2', { id: 'addons-h' }, icon('leaf', 22), ' Lisäpalvelut'), can ? h('button', { type: 'button', class: 'btn sm', onclick: () => edit(null) }, 'Lisää lisäpalvelu') : null),
      h('p', { class: 'muted', text: can ? 'Lisäpalvelut näkyvät varauslomakkeilla (verkkokauppa ja hallinta) ja päivänäkymän valmisteluyhteenvedossa. Hinnat sisältävät ALV:n; hinnan muutos koskee vain uusia tilauksia.' : 'Näet lisäpalvelut; muokkaus vaatii ylläpitäjän (manager/admin) oikeudet.' }), list);
  }
  function edit(a) {
    const isNew = !a;
    const inp = (name, v, o = {}) => h(o.area ? 'textarea' : 'input', { name, value: v ?? '', rows: o.area ? 3 : null, disabled: !can, ...o, area: null });
    const vat = h('select', { name: 'vat_rate', disabled: !can }, VAT.map((v) => h('option', { value: v, text: `${v} %`, selected: +(a?.vat_rate ?? 25.5) === v || null })));
    const modes = ['shared', 'exclusive'].map((m) => h('label', { class: 'check' }, h('input', { type: 'checkbox', name: `mode_${m}`, checked: (a?.applies_modes || ['shared', 'exclusive']).includes(m) || null, disabled: !can }), ` ${MODE_LABEL[m]}`));
    const f = h('form', { class: 'stack' },
      isNew ? field('Tunnus (pienet kirjaimet, numerot, alaviiva)', inp('code', '', { required: true, pattern: '[a-z][a-z0-9_]{1,40}' })) : null,
      field('Nimi (FI)', inp('name', a?.name, { required: true })), field('Nimi (EN)', inp('name_en', a?.name_en)),
      field('Kuvaus (FI)', inp('description', a?.description, { area: true })), field('Kuvaus (EN)', inp('description_en', a?.description_en, { area: true })),
      h('div', { class: 'row wrap' }, field('Hinta € (sis. ALV)', inp('price', a?.price, { type: 'number', step: '0.01', min: '0', required: true })), field('ALV', vat),
        field('Enintään / henkilö', inp('max_per_person', a?.max_per_person ?? 1, { type: 'number', min: 1, max: 20, required: true }), 'Kaupassa enimmäismäärä = henkilömäärä × tämä (enintään 99).'), field('Järjestys', inp('sort_order', a?.sort_order ?? 100, { type: 'number' }))),
      h('fieldset', { class: 'kindset' }, h('legend', { text: 'Myydään vuorotyypeille' }), h('div', { class: 'row wrap' }, modes)),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'active', checked: (a?.active ?? true) || null, disabled: !can }), ' Käytössä (näkyy varauslomakkeilla)'),
      can ? h('button', { class: 'btn primary', type: 'submit', text: isNew ? 'Lisää lisäpalvelu' : 'Tallenna' }) : h('p', { class: 'muted', text: 'Muokkaus vaatii oikeuden catalog.edit.' }));
    const d = dialog(isNew ? 'Uusi lisäpalvelu' : a.name, f);
    f.addEventListener('submit', (ev) => { ev.preventDefault(); run(f.querySelector('button[type=submit]'), async () => {
      const fd = new FormData(f);
      const am = ['shared', 'exclusive'].filter((m) => f.elements[`mode_${m}`].checked);
      if (!am.length) throw new Error('Valitse vähintään yksi vuorotyyppi');
      const body = { name: fd.get('name'), name_en: fd.get('name_en') || null, description: fd.get('description') || null, description_en: fd.get('description_en') || null,
        price: String(fd.get('price')), vat_rate: +fd.get('vat_rate'), max_per_person: +fd.get('max_per_person'), sort_order: +fd.get('sort_order'), applies_modes: am, active: f.elements.active.checked };
      if (isNew) await rpc('admin_create_addon', { p_data: { code: fd.get('code'), ...body } }); else await rpc('admin_update_addon', { p_id: a.id, p_patch: body });
      toast('Lisäpalvelu tallennettu'); d.close(); draw();
    }); });
  }
  await draw();
  return wrap;
}
