// Tuotteet: nimet, kuvaukset, hinnat ja ALV muokataan kb.products / kb.product_price_variants -tauluihin (oikeus catalog.edit: manager + admin).
// Peruskäyttäjä (staff) näkee tuotteet mutta ei voi muokata hintoja.
import { rpc, storageUrl, uploadObject, removeObject } from '../sb.js';
import { prepareImage, IMG_TYPES, IMG_MAX_INPUT } from './productimage.js';
import { addonsAdmin } from './addons.js';
import { h, dialog, field, toast, run, money, badge } from '../ui.js';

const VAT = [25.5, 24, 14, 13.5, 10, 0];
export async function render({ ctx, refs, reload }) {
  const isAdmin = ctx.can('catalog.edit');  // manager + admin
  const fresh = () => { ctx.refs = null; reload(); };   // tuotelista haetaan uudelleen (refs on välimuistissa; muuten uusi kuva/tiedot eivät näy listassa)
  const list = h('div', { class: 'list' });
  for (const p of refs.products) {
    const c = p.config;
    list.append(h('button', { type: 'button', class: 'listrow', onclick: () => edit(p) },
      h('span', { class: 'what' }, c?.image_path ? h('img', { class: 'pthumb', src: storageUrl('product-images', c.image_path), alt: '', width: 40, height: 40, loading: 'lazy' }) : null, h('strong', { text: p.name }), h('small', { text: ` ${p.category || ''}` })),
      h('span', { class: 'meta' }, c?.bookable ? badge('ok', 'Verkkovarattavissa') : badge('muted', 'Ei verkossa'), !p.active ? badge('err', 'Piilotettu') : null, h('strong', { text: money(p.price) }), h('small', { text: `ALV ${p.vat_rate} %` }))));
  }
  function edit(p) {
    const inp = (name, v, { area, ...o } = {}) => h(area ? 'textarea' : 'input', { name, value: v ?? '', rows: area ? 5 : null, disabled: !isAdmin, ...o });
    const vat = h('select', { name: 'vat_rate', disabled: !isAdmin }, VAT.map((v) => h('option', { value: v, text: `${v} %`, selected: +p.vat_rate === v || null })));
    const f = h('form', { class: 'stack' },
      field('Nimi (FI)', inp('name', p.name, { required: true })), field('Nimi (EN)', inp('name_en', p.name_en)),
      field('Kuvaus (FI)', inp('description', p.description, { area: true })), field('Kuvaus (EN)', inp('description_en', p.description_en, { area: true })),
      h('div', { class: 'row wrap' }, field('Hinta € (sis. ALV)', inp('price', p.price, { type: 'number', step: '0.01', min: '0' })), field('ALV', vat)),
      field('Hintateksti', inp('price_text', p.price_text), 'Näytetään kb:ssä; verkkokauppa laskee näytettävän hinnan hinta-kentästä. Päivitä teksti kun muutat hintaa.'),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'active', disabled: !isAdmin }), ' Aktiivinen (näkyy kb:ssä)'),
      isAdmin ? h('button', { class: 'btn primary', type: 'submit', text: 'Tallenna tuote' }) : h('p', { class: 'muted', text: 'Tuotteiden, hintojen ja kuvausten muokkaus vaatii ylläpitäjän (manager/admin) oikeudet.' }));
    f.active.checked = !!p.active;
    f.addEventListener('submit', (ev) => { ev.preventDefault(); run(f.querySelector('button'), async () => {
      const fd = new FormData(f);
      await rpc('admin_update_product', { p_product_id: p.id, p_patch: { name: fd.get('name'), name_en: fd.get('name_en'), description: fd.get('description'), description_en: fd.get('description_en'), price: +fd.get('price'), price_text: fd.get('price_text'), vat_rate: +fd.get('vat_rate'), active: f.active.checked } });
      toast('Tuote tallennettu'); d.close(); fresh();
    }); });
    // verkkokaupan asetukset
    const c = p.config;
    const cfg = c ? h('form', { class: 'stack box' }, h('h3', { text: 'Verkkokaupan asetukset' }),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'bookable', disabled: !isAdmin }), ' Varattavissa verkossa'),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'shop_visible', disabled: !isAdmin }), ' Näkyy kaupan listassa'),
      h('div', { class: 'row wrap' }, field('Järjestys', h('input', { name: 'sort_order', type: 'number', value: c.sort_order, disabled: !isAdmin })), field('Min hlö', h('input', { name: 'min_persons', type: 'number', min: 1, value: c.min_persons, disabled: !isAdmin })), field('Max hlö', h('input', { name: 'max_persons', type: 'number', min: 1, value: c.max_persons ?? '', disabled: !isAdmin }))),
      isAdmin ? h('button', { class: 'btn', type: 'submit', text: 'Tallenna asetukset' }) : null) : h('p', { class: 'muted', text: 'Tuotetta ei ole vielä otettu mukaan varausjärjestelmään (product_config puuttuu).' });
    if (c) { cfg.bookable.checked = !!c.bookable; cfg.shop_visible.checked = !!c.shop_visible; cfg.addEventListener('submit', (ev) => { ev.preventDefault(); run(cfg.querySelector('button'), async () => {
      await rpc('admin_update_product_config', { p_product_id: p.id, p_patch: { bookable: cfg.bookable.checked, shop_visible: cfg.shop_visible.checked, sort_order: +cfg.sort_order.value, min_persons: +cfg.min_persons.value, max_persons: cfg.max_persons.value ? +cfg.max_persons.value : null } });
      toast('Tallennettu'); d.close(); fresh(); }); }); }
    // tuotekuva (Storage: product-images; polku talletetaan funktiolla admin_set_product_image)
    const img = c ? imageBox(p, c, isAdmin, () => { d.close(); fresh(); }) : null;
    // hintavariantit
    const vars = (p.variants || []).length ? h('div', { class: 'box stack' }, h('h3', { text: 'Hintavariantit' }), ...p.variants.map((v) => {
      const inpP = h('input', { type: 'number', step: '0.01', min: '0', value: v.price, disabled: !isAdmin, 'aria-label': `Hinta: ${v.label}` });
      return h('div', { class: 'row wrap varrow' }, h('span', { class: 'grow' }, h('strong', { text: v.label }), h('small', { text: ` ${v.valid_from || ''}${v.valid_to ? '–' + v.valid_to : ''}${v.included_persons ? ` · sis. ${v.included_persons} hlö` : ''}${v.extra_person_price ? ` · lisählö ${v.extra_person_price} €` : ''}` })), inpP,
        isAdmin ? h('button', { type: 'button', class: 'btn sm', text: 'Tallenna', onclick: (e) => run(e.target, async () => { await rpc('admin_update_price_variant', { p_variant_id: v.id, p_patch: { price: +inpP.value } }); toast('Hinta tallennettu'); fresh(); }) }) : null);
    })) : null;
    const d = dialog(p.name, h('div', { class: 'stack' }, f, img, cfg, vars), { wide: true });
  }
  const addonsSection = await addonsAdmin({ ctx });
  return [h('h1', { text: 'Tuotteet' }), h('p', { class: 'muted', text: isAdmin ? 'Tuotetiedot tallentuvat kb-tauluihin (sivusto ja botti käyttävät samaa totuutta). Muutokset kirjataan audit-lokiin ja kb.change_logiin.' : 'Näet tuotteet; hintojen ja tuotteiden muokkaus vaatii ylläpitäjän (manager/admin) oikeudet.' }), list, addonsSection];
}

// ---- tuotekuva: esikatselu, lataus, alt-teksti, poisto ----
const newPath = (id, ext) => `products/${id}-${[...crypto.getRandomValues(new Uint8Array(6))].map((b) => (b % 36).toString(36)).join('')}.${ext}`;
function imageBox(p, c, canEdit, done) {
  const cur = c.image_path ? storageUrl('product-images', c.image_path) : null;
  let file = null;                       // valittu, valmisteltu (skaalattu) kuva { blob, ext, url }
  const preview = h('div', { class: 'imgprev', role: 'img', 'aria-label': 'Tuotekuvan esikatselu' });
  const status = h('p', { class: 'muted', role: 'status', 'aria-live': 'polite' });
  const alt = h('input', { name: 'image_alt', maxlength: 200, value: c.image_alt || '', disabled: !canEdit, placeholder: p.name });
  const input = h('input', { type: 'file', accept: IMG_TYPES.join(','), class: 'sr', id: `img-file-${p.id}`, 'aria-label': 'Valitse kuvatiedosto', tabindex: -1, disabled: !canEdit });
  const show = (url) => { preview.replaceChildren(url ? h('img', { src: url, alt: '' }) : h('span', { class: 'muted', text: 'Ei kuvaa' })); preview.classList.toggle('has', !!url); };
  show(file?.url || cur);
  const save = h('button', { type: 'button', class: 'btn', text: 'Tallenna kuva', disabled: true });
  const del = h('button', { type: 'button', class: 'btn danger', text: 'Poista kuva', disabled: !c.image_path });
  const pick = h('button', { type: 'button', class: 'btn', text: c.image_path ? 'Vaihda kuva' : 'Valitse kuva', onclick: () => input.click() });
  alt.addEventListener('input', () => { save.disabled = !(file || c.image_path); });
  input.addEventListener('change', async () => {
    const f = input.files[0]; input.value = ''; if (!f) return;
    status.textContent = 'Käsitellään kuvaa…'; status.className = 'muted';
    try {
      file = await prepareImage(f);
      show(file.url); save.disabled = false;
      status.textContent = `Valittu: ${f.name} → ${(file.blob.size / 1024).toFixed(0)} kt (${file.w}×${file.h}). Paina "Tallenna kuva".`;
    } catch (e) { status.textContent = e.message; status.className = 'err'; save.disabled = !(file || c.image_path) && true; }
  });
  save.addEventListener('click', () => run(save, async () => {
    let path = c.image_path;
    if (file) { path = newPath(p.id, file.ext); await uploadObject('product-images', path, file.blob); }
    const r = await rpc('admin_set_product_image', { p_product_id: p.id, p_image_path: path, p_image_alt: alt.value.trim() || null });
    if (file && r?.previous_path && r.previous_path !== path) await removeObject('product-images', r.previous_path).catch(() => {});   // siivotaan vanha tiedosto (virhe ei haittaa)
    toast('Kuva tallennettu'); done();
  }));
  del.addEventListener('click', () => { if (!confirm('Poistetaanko tuotteen kuva?')) return; run(del, async () => {
    const r = await rpc('admin_set_product_image', { p_product_id: p.id, p_image_path: null, p_image_alt: null });
    if (r?.previous_path) await removeObject('product-images', r.previous_path).catch(() => {});
    toast('Kuva poistettu'); done();
  }); });
  return h('div', { class: 'stack box', id: `img-box-${p.id}` }, h('h3', { text: 'Tuotekuva' }), preview,
    canEdit ? [h('div', { class: 'row wrap' }, pick, input, save, del),
      field('Kuvan alt-teksti (valinnainen)', alt, 'Kuvaus ruudunlukijalle; jos tyhjä, käytetään tuotteen nimeä.'),
      h('p', { class: 'muted', text: `JPEG, PNG tai WebP, enintään ${IMG_MAX_INPUT / 1048576} Mt. Kuva pienennetään automaattisesti (enintään 1600 px) ja tallennetaan julkiseen kuvakansioon.` })] : h('p', { class: 'muted', text: 'Kuvan vaihto vaatii ylläpitäjän (manager/admin) oikeudet.' }),
    status);
}
