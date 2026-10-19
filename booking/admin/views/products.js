// Tuotteet: nimet, kuvaukset, hinnat ja ALV muokataan kb.products / kb.product_price_variants -tauluihin (oikeus catalog.edit: manager + admin).
// Peruskäyttäjä (staff) näkee tuotteet mutta ei voi muokata hintoja.
import { rpc, storageUrl, uploadObject, removeObject } from '../sb.js';
import { prepareImage, IMG_TYPES, IMG_MAX_INPUT } from './productimage.js';
import { addonsAdmin } from './addons.js';
import { productOptionsAdmin } from './productoptions.js';
import { h, dialog, field, toast, run, money, badge } from '../ui.js';
import { filterDrawer } from '../filter-drawer.js';
import { loadPosTexts, posText } from '../pos-texts.js';
import { loadProductTexts, productText } from '../product-texts.js';
import { settingsHref } from '../settings-tabs.js';
import { looksLikeAlcohol } from '../pos-logic.js';

const VAT_ACTIVE = [25.5, 13.5, 0];
const CATEGORY_ORDER = ['product_rental', 'add_on', 'public_sauna', 'private_sauna', 'corporate', 'treatment', 'ritual', 'ceremony', 'event', 'gift_card', 'season_card', 'training', 'other'];
function vatChoices(current) {
  const cur = current == null || current === '' ? null : +current;
  const list = [...VAT_ACTIVE];
  if (cur != null && Number.isFinite(cur) && !list.some((v) => v === cur)) list.push(cur);
  return list;
}
const vatLabel = (v) => `${String(v).replace('.', ',')} %`;

// "Verkossa" = tuote näkyy ja on varattavissa verkkokaupassa: sama ehto kuin public_catalog:ssa (product_config: bookable, shop_visible, lifecycle = 'current').
// Puuttuva kenttä ei estä (shop_visible/lifecycle voivat puuttua vanhemmasta kannasta); puuttuva product_config = ei verkossa.
export const isOnline = (p) => { const c = p?.config; return !!c && c.bookable === true && c.shop_visible !== false && c.lifecycle !== 'old'; };
export const CATEGORY_LABELS = { public_sauna: 'Yleiset saunavuorot', private_sauna: 'Yksityiset saunavuorot', corporate: 'Yritykset', treatment: 'Hoidot', ritual: 'Rituaalit', ceremony: 'Seremoniat', event: 'Tapahtumat', gift_card: 'Lahjakortit', season_card: 'Kausikortit', product_rental: 'Tuotteet ja vuokrat', training: 'Koulutukset', add_on: 'Lisäpalvelut', other: 'Muu' };
export const catLabel = (c) => (c === 'product_rental' ? productText('cat_rental') : c === 'other' ? productText('cat_other') : (CATEGORY_LABELS[c] || c || 'Ilman kategoriaa'));
export const VISIBILITY = [['', 'Kaikki'], ['online', 'Verkossa'], ['offline', 'Ei verkossa']];
const VIS_URL = { online: 'verkossa', offline: 'ei-verkossa' };
const norm = (x) => String(x ?? '').toLocaleLowerCase('fi');   // kirjainkoolla ei ole merkitystä

export async function render({ ctx, refs, reload, query }) {
  await loadPosTexts(rpc);
  await loadProductTexts(rpc);
  const isAdmin = ctx.can('catalog.edit');  // manager + admin
  const fresh = () => { ctx.refs = null; reload(); };   // tuotelista haetaan uudelleen (refs on välimuistissa; muuten uusi kuva/tiedot eivät näy listassa)
  const list = h('div', { class: 'list' });
  const rowOf = (p) => { const c = p.config;
    return h('button', { type: 'button', class: 'listrow', onclick: () => edit(p) },
      h('span', { class: 'what' }, c?.image_path ? h('img', { class: 'pthumb', src: storageUrl('product-images', c.image_path), alt: '', width: 40, height: 40, loading: 'lazy' }) : null, h('strong', { text: p.name }), h('small', { text: ` ${catLabel(p.category)}` })),
      h('span', { class: 'meta' }, isOnline(p) ? badge('ok', 'Verkossa') : badge('muted', 'Ei verkossa'), c?.pos_enabled ? badge('ok', posText('badge_pos')) : null, c?.fridge_sale ? badge('ok', posText('badge_qr')) : null, !p.active ? badge('err', 'Piilotettu') : null, h('strong', { text: money(p.price) }), h('small', { text: `ALV ${p.vat_rate} %` }))); };

  // ---- suodattimet (clientissä: lista on jo ladattu, ei uusia RPC-kutsuja); tila säilyy URL:ssa (#/tuotteet?nakyvyys=…&kategoria=…&haku=…) ----
  const all = refs.products;
  const catCodes = [...new Set(all.map((p) => p.category || ''))].sort((a, b) => catLabel(a).localeCompare(catLabel(b), 'fi'));
  const q0 = query || new URLSearchParams();
  const f = { vis: Object.keys(VIS_URL).find((k) => VIS_URL[k] === q0.get('nakyvyys')) || '', cat: catCodes.includes(q0.get('kategoria')) ? q0.get('kategoria') : '', search: (q0.get('haku') || '').slice(0, 80) };
  const matchSearch = (p) => !f.search.trim() || [p.name, p.name_en, p.slug].some((x) => norm(x).includes(norm(f.search.trim())));
  const matchVis = (p) => !f.vis || (f.vis === 'online') === isOnline(p);
  const matchCat = (p) => !f.cat || (p.category || '') === f.cat;
  const active = () => !!(f.vis || f.cat || f.search.trim());
  const count = h('p', { class: 'muted prodcount', role: 'status', 'aria-live': 'polite' });
  const clearBtn = h('button', { type: 'button', class: 'link', text: 'Tyhjennä suodattimet', onclick: () => { f.vis = ''; f.cat = ''; f.search = ''; searchInp.value = ''; catSel.value = ''; for (const r of filters.querySelectorAll('input[type=radio]')) r.checked = r.value === ''; draw(); } });
  const syncUrl = () => {
    const qs = new URLSearchParams(); if (f.vis) qs.set('nakyvyys', VIS_URL[f.vis]); if (f.cat) qs.set('kategoria', f.cat); if (f.search.trim()) qs.set('haku', f.search.trim());
    history.replaceState(null, '', `#/tuotteet${qs.toString() ? `?${qs}` : ''}`);   // ei hashchangea → ei uudelleenpiirtoa
  };
  const labels = new Map();   // radio-arvo → label-span (lukumäärät päivitetään suodatuksen mukaan: kunkin ryhmän luvut huomioivat muut suodattimet)
  const seg = (legend, name, opts, cur, onPick, testid) => h('fieldset', { class: 'srcset prodseg', 'data-testid': testid }, h('legend', { text: legend }),
    opts.map(([v, label]) => { const sp = h('span', { text: label }); labels.set(`${name}:${v}`, [sp, label]);
      return h('label', { class: 'srcopt' }, h('input', { type: 'radio', name, value: v, checked: v === cur || null, onchange: () => onPick(v) }), sp); }));
  const searchInp = h('input', { type: 'search', value: f.search, maxlength: 80, placeholder: 'Hae tuotteen nimellä', autocomplete: 'off', 'aria-label': 'Hae tuotteen nimellä', 'data-testid': 'products-search' });
  searchInp.addEventListener('input', () => { f.search = searchInp.value; draw(); });
  const visSet = seg('Näkyvyys', 'vis', VISIBILITY, f.vis, (v) => { f.vis = v; draw(); }, 'vis-filter');
  const catOpts = [['', 'Kaikki kategoriat'], ...catCodes.map((c) => [c, catLabel(c)])];
  const catSet = seg('Kategoria', 'cat', catOpts, f.cat, (v) => { f.cat = v; catSel.value = v; draw(); }, 'cat-filter');
  // kapealla näytöllä kategoria on pudotusvalikko (13 painiketta veisi koko ruudun); leveällä pikavalintapainikkeet. Molemmat ohjaavat samaa tilaa.
  const catSel = h('select', { class: 'prodcatsel', 'aria-label': 'Kategoria', 'data-testid': 'cat-select' }, catOpts.map(([v, label]) => h('option', { value: v, text: label })));
  catSel.value = f.cat;
  catSel.addEventListener('change', () => { f.cat = catSel.value; for (const r of catSet.querySelectorAll('input')) r.checked = r.value === f.cat; draw(); });
  catSet.classList.add('prodcatset');
  const catWrap = h('div', { class: 'prodcat' }, catSet, h('label', { class: 'fld prodcatsel-w' }, h('span', { text: 'Kategoria' }), catSel));
  const drawer = filterDrawer({
    className: 'filters card prodfilters',
    testid: 'products-filters',
    search: field('Haku', searchInp),
    activeCount: () => (f.vis ? 1 : 0) + (f.cat ? 1 : 0),
    filters: [h('div', { class: 'filter-groups' }, visSet, catWrap)],
  });
  const filters = drawer.node;
  const setLabel = (key, n) => { const [sp, base] = labels.get(key); sp.textContent = `${base} (${n})`; if (key.startsWith('cat:')) { const o = [...catSel.options].find((x) => x.value === key.slice(4)); if (o) o.textContent = `${base} (${n})`; } };
  function draw() {
    const shown = all.filter((p) => matchSearch(p) && matchVis(p) && matchCat(p));
    for (const [v] of VISIBILITY) setLabel(`vis:${v}`, all.filter((p) => matchSearch(p) && matchCat(p) && (!v || (v === 'online') === isOnline(p))).length);
    for (const [c] of catOpts) setLabel(`cat:${c}`, all.filter((p) => matchSearch(p) && matchVis(p) && (!c || (p.category || '') === c)).length);
    list.replaceChildren(...(shown.length ? shown.map(rowOf) : [h('div', { class: 'empty prodempty' }, h('p', { text: 'Ei tuotteita valituilla suodattimilla.' }), active() ? h('button', { type: 'button', class: 'btn ghost', text: 'Tyhjennä suodattimet', onclick: () => clearBtn.click() }) : null)]));
    count.replaceChildren(`${shown.length} / ${all.length} tuotetta`, active() ? ' · ' : '', active() ? clearBtn : '');
    syncUrl();
    drawer.refresh();
  }
  draw();
  function edit(p) {
    const inp = (name, v, { area, ...o } = {}) => h(area ? 'textarea' : 'input', { name, value: v ?? '', rows: area ? 5 : null, disabled: !isAdmin, ...o });
    const vat = h('select', { name: 'vat_rate', disabled: !isAdmin }, vatChoices(p.vat_rate).map((v) => h('option', { value: v, text: vatLabel(v), selected: +p.vat_rate === v || null })));
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
    const alcohol = looksLikeAlcohol([p.name, p.name_en, p.description, p.description_en].filter(Boolean).join(' '));
    const cfg = c ? h('form', { class: 'stack box' }, h('h3', { text: 'Verkkokaupan asetukset' }),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'bookable', disabled: !isAdmin }), ' Varattavissa verkossa'),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'shop_visible', disabled: !isAdmin }), ' Näkyy kaupan listassa'),
      'audience' in c ? field('Kalenteri', h('select', { name: 'audience', disabled: !isAdmin }, h('option', { value: 'consumer', text: 'Kuluttajien kalenteri' }), h('option', { value: 'business', text: 'Yrityksille' })), 'Yrityksille-valinta näyttää vuoron vain yritysten kalenterissa.') : null,
      h('div', { class: 'row wrap' }, field('Järjestys', h('input', { name: 'sort_order', type: 'number', value: c.sort_order, disabled: !isAdmin })), field('Min hlö', h('input', { name: 'min_persons', type: 'number', min: 1, value: c.min_persons, disabled: !isAdmin })), field('Max hlö', h('input', { name: 'max_persons', type: 'number', min: 1, value: c.max_persons ?? '', disabled: !isAdmin }))),
      h('h3', { text: posText('nav') }),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'pos_enabled', disabled: !isAdmin }), ' ' + posText('product_pos')),
      field(posText('product_pos_sort'), h('input', { name: 'pos_sort', type: 'number', min: 0, max: 10000, value: c.pos_sort ?? 100, disabled: !isAdmin })),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'fridge_sale', disabled: !isAdmin || alcohol || !!c.age_restricted }), ' ' + posText('qr_sale')),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'age_restricted', disabled: !isAdmin }), ' ' + posText('product_age')),
      h('p', { class: 'muted', text: posText('qr_sale_hint') }),
      alcohol ? h('p', { class: 'err', text: posText('alcohol_qr') }) : null,
      isAdmin ? h('button', { class: 'btn', type: 'submit', text: 'Tallenna asetukset' }) : null) : h('p', { class: 'muted', text: 'Tuotetta ei ole vielä otettu mukaan varausjärjestelmään (product_config puuttuu).' });
    if (c) { cfg.bookable.checked = !!c.bookable; cfg.shop_visible.checked = !!c.shop_visible; if (cfg.audience) cfg.audience.value = c.audience === 'business' ? 'business' : 'consumer'; cfg.pos_enabled.checked = !!c.pos_enabled; cfg.fridge_sale.checked = !!c.fridge_sale && !c.age_restricted && !alcohol; cfg.age_restricted.checked = !!c.age_restricted;
      cfg.age_restricted.addEventListener('change', () => { if (cfg.age_restricted.checked) { cfg.fridge_sale.checked = false; cfg.fridge_sale.disabled = true; } else if (isAdmin && !alcohol) cfg.fridge_sale.disabled = false; });
      cfg.addEventListener('submit', (ev) => { ev.preventDefault(); run(cfg.querySelector('button'), async () => {
      const patch = { bookable: cfg.bookable.checked, shop_visible: cfg.shop_visible.checked, sort_order: +cfg.sort_order.value, min_persons: +cfg.min_persons.value, max_persons: cfg.max_persons.value ? +cfg.max_persons.value : null, pos_enabled: cfg.pos_enabled.checked, pos_sort: +cfg.pos_sort.value, fridge_sale: cfg.fridge_sale.checked, age_restricted: cfg.age_restricted.checked };
      if (cfg.audience) patch.audience = cfg.audience.value;
      await rpc('admin_update_product_config', { p_product_id: p.id, p_patch: patch });
      toast('Tallennettu'); d.close(); fresh(); }); }); }
    // tuotekuva (Storage: product-images; polku talletetaan funktiolla admin_set_product_image)
    const img = c ? imageBox(p, c, isAdmin, () => { d.close(); fresh(); }) : null;
    // hintavariantit
    const vars = (p.variants || []).length ? h('div', { class: 'box stack' }, h('h3', { text: 'Hintavariantit' }), ...p.variants.map((v) => {
      const inpP = h('input', { type: 'number', step: '0.01', min: '0', value: v.price, disabled: !isAdmin, 'aria-label': `Hinta: ${v.label}` });
      return h('div', { class: 'row wrap varrow' }, h('span', { class: 'grow' }, h('strong', { text: v.label }), h('small', { text: ` ${v.valid_from || ''}${v.valid_to ? '–' + v.valid_to : ''}${v.included_persons ? ` · sis. ${v.included_persons} hlö` : ''}${v.extra_person_price ? ` · lisählö ${v.extra_person_price} €` : ''}` })), inpP,
        isAdmin ? h('button', { type: 'button', class: 'btn sm', text: 'Tallenna', onclick: (e) => run(e.target, async () => { await rpc('admin_update_price_variant', { p_variant_id: v.id, p_patch: { price: +inpP.value } }); toast('Hinta tallennettu'); fresh(); }) }) : null);
    })) : null;
    let d;
    const next = c && isAdmin ? h('div', { class: 'box stack prod-next', 'data-testid': 'product-next' },
      h('p', { text: productText('next') }),
      h('p', { class: 'muted', text: productText('pos_hint') }),
      h('a', { class: 'btn', href: '#/pikakassa', 'data-testid': 'product-open-pos', text: productText('link_pos'), onclick: () => d?.close() }),
      h('p', { class: 'muted', text: productText('qr_hint') }),
      h('a', { class: 'btn', href: settingsHref('qr'), 'data-testid': 'product-open-qr', text: productText('link_qr'), onclick: () => d?.close() })) : null;
    d = dialog(p.name, h('div', { class: 'stack' }, f, img, cfg, next, vars), { wide: true });
  }
  function createProduct() {
    const inp = (name, v, o = {}) => h(o.area ? 'textarea' : 'input', { name, value: v ?? '', rows: o.area ? 5 : null, ...o, area: null });
    const vat = h('select', { name: 'vat_rate', 'data-testid': 'product-create-vat' }, vatChoices(25.5).map((v) => h('option', { value: v, text: vatLabel(v), selected: v === 25.5 || null })));
    vat.value = '25.5';
    const cat = h('select', { name: 'category', 'data-testid': 'product-create-category' }, CATEGORY_ORDER.map((c) => h('option', { value: c, text: catLabel(c), selected: c === 'product_rental' || null })));
    cat.value = 'product_rental';
    const f = h('form', { class: 'stack', 'data-testid': 'product-create-form' },
      field(productText('name_fi'), inp('name', '', { required: true, maxlength: 200 })),
      field(productText('name_en'), inp('name_en', '', { maxlength: 200 }), productText('name_en_hint')),
      field('Kuvaus (FI)', inp('description', '', { area: true })), field('Kuvaus (EN)', inp('description_en', '', { area: true })),
      h('div', { class: 'row wrap' }, field(productText('price'), inp('price', '', { type: 'number', step: '0.01', min: '0', required: true, inputmode: 'decimal' })), field(productText('vat'), vat)),
      field(productText('price_text'), inp('price_text', '', { maxlength: 200 }), productText('price_text_hint')),
      field(productText('category'), cat),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'active' }), ' ' + productText('active')),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'age_restricted' }), ' ' + productText('age')),
      h('p', { class: 'muted', text: productText('sell_hint') }),
      h('p', { class: 'muted', text: productText('next') }),
      h('button', { class: 'btn primary', type: 'submit', 'data-testid': 'product-create-submit', text: productText('create') }));
    f.active.checked = true;
    f.age_restricted.checked = false;
    f.addEventListener('submit', (ev) => { ev.preventDefault(); run(f.querySelector('button'), async () => {
      const fd = new FormData(f);
      const res = await rpc('admin_product_create', { p_data: {
        name: fd.get('name'), name_en: fd.get('name_en'), description: fd.get('description'), description_en: fd.get('description_en'),
        price: fd.get('price'), price_text: fd.get('price_text'), vat_rate: fd.get('vat_rate'), category: fd.get('category'),
        active: f.active.checked, age_restricted: f.age_restricted.checked,
      } });
      toast(productText('created')); d.close();
      if (res?.product) edit(res.product);
      fresh();
    }); });
    const d = dialog(productText('new_title'), f, { wide: true });
  }
  const addonsSection = await addonsAdmin({ ctx });
  const optionsSection = await productOptionsAdmin({ ctx });   // tuotevalinnat (booking_50)
  const addBtn = isAdmin ? h('button', { type: 'button', class: 'btn primary prod-add', 'data-testid': 'product-add', text: productText('add'), onclick: () => createProduct() }) : null;
  return [h('div', { class: 'row between wrap prod-head' }, h('h1', { text: 'Tuotteet' }), addBtn), h('p', { class: 'muted', text: isAdmin ? 'Tuotetiedot tallentuvat kb-tauluihin (sivusto ja botti käyttävät samaa totuutta). Muutokset kirjataan audit-lokiin ja kb.change_logiin.' : 'Näet tuotteet; hintojen ja tuotteiden muokkaus vaatii ylläpitäjän (manager/admin) oikeudet.' }), filters, count, list, optionsSection, addonsSection];
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
