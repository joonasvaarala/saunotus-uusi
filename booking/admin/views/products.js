// Tuotteet: nimet, kuvaukset, hinnat ja ALV muokataan kb.products / kb.product_price_variants -tauluihin (oikeus catalog.edit: manager + admin).
// Peruskäyttäjä (staff) näkee tuotteet mutta ei voi muokata hintoja.
import { rpc, storageUrl } from '../sb.js';
import { addonsAdmin } from './addons.js';
import { productEditor } from './product-editor.js';
import { productIdFromRest, productHash } from '../product-editor-logic.js';
import { productOptionsAdmin } from './productoptions.js';
import { h, dialog, field, toast, run, money, badge, vatText, countText } from '../ui.js';
import { filterDrawer } from '../filter-drawer.js';
import { loadPosTexts, posText } from '../pos-texts.js';
import { loadProductTexts, productText } from '../product-texts.js';
import { loadRichTexts, richText } from '../rich-texts.js';
import { mountRichFields, syncRichFields } from '../rich-editor.js';
import { renderQrPanel } from '../qr-panel.js';
import { loadSettingsTexts, settingsText } from '../settings-texts.js';
import { loadEventsTexts, evText } from '../events-texts.js';
import { copyArgs, copyName } from '../events-logic.js';
import { effectiveChannels, isOnline } from '../product-visibility.js';

const VAT_ACTIVE = [25.5, 13.5, 0];
const CATEGORY_ORDER = ['product_rental', 'add_on', 'public_sauna', 'private_sauna', 'corporate', 'treatment', 'ritual', 'ceremony', 'event', 'gift_card', 'season_card', 'training', 'other'];
function vatChoices(current) {
  const cur = current == null || current === '' ? null : +current;
  const list = [...VAT_ACTIVE];
  if (cur != null && Number.isFinite(cur) && !list.some((v) => v === cur)) list.push(cur);
  return list;
}
const vatLabel = (v) => `${String(v).replace('.', ',')} %`;

// "Verkossa" = tuote on myynnissä uudessa verkkokaupassa (Joonas 6.11.2026, t1367u). Sama ehto kuin palvelimella:
//  - kauppalistalla (public_catalog): aktiivinen, bookable, shop_visible, lifecycle ei 'old', kanava 'shop';
//  - TAI koulutus suoralla linkillä (public_product_by_slug, /varaa/#/tuote/<slug> ja /en/book/#/tuote/<slug>): aktiivinen, bookable,
//    lifecycle ei 'old', kanava 'link' (shop_visible = false on koulutuksella normaali).
// EI perustu vanhaan Johku-kenttään booking_url. Kanavat: product_config.channels; puuttuu → training: widget, muut: shop (booking._channels_effective).
// Puuttuva kenttä ei estä (shop_visible/lifecycle voivat puuttua vanhemmasta kannasta); puuttuva product_config = ei verkossa.
export { effectiveChannels, isOnline };   // HALL-TUOTTEET-02: siirretty product-visibility.js:ään (testattavuus; sama ehto)
export const CATEGORY_LABELS = { public_sauna: 'Yleiset saunavuorot', private_sauna: 'Yksityiset saunavuorot', corporate: 'Yritykset', treatment: 'Hoidot', ritual: 'Rituaalit', ceremony: 'Seremoniat', event: 'Tapahtumat', gift_card: 'Lahjakortit', season_card: 'Kausikortit', product_rental: 'Tuotteet ja vuokrat', training: 'Koulutukset', add_on: 'Lisäpalvelut', other: 'Muu' };
export const catLabel = (c) => (c === 'product_rental' ? productText('cat_rental') : c === 'other' ? productText('cat_other') : (CATEGORY_LABELS[c] || c || 'Ilman kategoriaa'));
export const VISIBILITY = [['', 'Kaikki'], ['online', 'Verkossa'], ['offline', 'Ei verkossa']];
const VIS_URL = { online: 'verkossa', offline: 'ei-verkossa' };
const norm = (x) => String(x ?? '').toLocaleLowerCase('fi');   // kirjainkoolla ei ole merkitystä

export async function render({ ctx, refs, reload, query, rest }) {
  // booking_158: Kopioi-tekstit (ui.admin.product.copy*) tulevat events-teksteistä. Kaikki jaetusta välimuistista rinnakkain.
  await Promise.all([loadPosTexts(rpc), loadProductTexts(rpc), loadRichTexts(rpc), loadEventsTexts(rpc)]);
  const isAdmin = ctx.can('catalog.edit');  // manager + admin
  const fresh = () => { ctx.refs = null; reload(); };   // tuotelista haetaan uudelleen (refs on välimuistissa; muuten uusi kuva/tiedot eivät näy listassa)
  const list = h('div', { class: 'list' });
  const rowOf = (p) => { const c = p.config;
    return h('a', { class: 'listrow', href: productHash(p.id, filterQuery()), 'aria-current': p.id === openId ? 'true' : null, 'data-testid': `product-row-${p.id}` },
      h('span', { class: 'what' }, c?.image_path ? h('img', { class: 'pthumb', src: storageUrl('product-images', c.image_path), alt: '', width: 40, height: 40, loading: 'lazy' }) : null, h('strong', { text: p.name }), h('small', { text: ` ${catLabel(p.category)}` })),
      h('span', { class: 'meta' }, isOnline(p) ? badge('ok', 'Verkossa') : badge('muted', 'Ei verkossa'), c?.pos_enabled ? badge('ok', posText('badge_pos')) : null, c?.fridge_sale ? badge('ok', posText('badge_qr')) : null, !p.active ? badge('err', 'Piilotettu') : null, h('strong', { text: money(p.price) }), h('small', { text: `ALV ${vatText(p.vat_rate)}` }))); };

  // ---- suodattimet (clientissä: lista on jo ladattu, ei uusia RPC-kutsuja); tila säilyy URL:ssa (#/tuotteet?nakyvyys=…&kategoria=…&haku=…) ----
  const all = refs.products;
  const catCodes = [...new Set(all.map((p) => p.category || ''))].sort((a, b) => catLabel(a).localeCompare(catLabel(b), 'fi'));
  const q0 = query || new URLSearchParams();
  // HALL-TUOTTEET-01: #/tuotteet/<id> avaa tuotteen editorin (työpöydällä listan viereen). Vanha #/tuotteet?muokkaa=<id> ohjataan uuteen osoitteeseen.
  const legacyId = Number(q0.get('muokkaa')) || null;
  const openId = productIdFromRest(rest) ?? legacyId;
  const openProduct = openId ? all.find((x) => x.id === openId) || null : null;
  const f = { vis: Object.keys(VIS_URL).find((k) => VIS_URL[k] === q0.get('nakyvyys')) || '', cat: catCodes.includes(q0.get('kategoria')) ? q0.get('kategoria') : '', search: (q0.get('haku') || '').slice(0, 80) };
  const matchSearch = (p) => !f.search.trim() || [p.name, p.name_en, p.slug].some((x) => norm(x).includes(norm(f.search.trim())));
  const matchVis = (p) => !f.vis || (f.vis === 'online') === isOnline(p);
  const matchCat = (p) => !f.cat || (p.category || '') === f.cat;
  const active = () => !!(f.vis || f.cat || f.search.trim());
  const count = h('p', { class: 'muted prodcount', role: 'status', 'aria-live': 'polite' });
  const clearBtn = h('button', { type: 'button', class: 'link', text: 'Tyhjennä suodattimet', onclick: () => { f.vis = ''; f.cat = ''; f.search = ''; searchInp.value = ''; catSel.value = ''; for (const r of filters.querySelectorAll('input[type=radio]')) r.checked = r.value === ''; draw(); } });
  const filterQuery = () => { const qs = new URLSearchParams(); if (f.vis) qs.set('nakyvyys', VIS_URL[f.vis]); if (f.cat) qs.set('kategoria', f.cat); if (f.search.trim()) qs.set('haku', f.search.trim()); return qs.toString(); };
  const syncUrl = () => {
    const qs = new URLSearchParams(filterQuery());
    history.replaceState(null, '', productHash(openId, qs.toString()));   // ei hashchangea → ei uudelleenpiirtoa
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
    count.replaceChildren(`${shown.length} / ${countText(all.length, 'tuote', 'tuotetta')}`, active() ? ' · ' : '', active() ? clearBtn : '');
    syncUrl();
    drawer.refresh();
  }
  draw();
  function copyProduct(p) {
    const a = copyArgs({ product_id: p.id });
    const f = h('form', { class: 'stack', 'data-testid': 'product-copy-form' }, h('p', { text: evText('ui.admin.product.copy_confirm', { name: copyName(p.name) }) }),
      h('button', { type: 'submit', class: 'btn primary', 'data-testid': 'product-copy-submit', text: evText('ui.admin.product.copy_submit') }));
    const cd = dialog(evText('ui.admin.product.copy_title'), f);
    f.addEventListener('submit', (ev) => { ev.preventDefault(); if (!a.ok) return; run(f.querySelector('button'), async () => {
      const out = await rpc(a.fn, a.args);
      toast(evText('ui.admin.product.copied')); cd.close(); ctx.refs = null;
      if (out?.product_id) location.hash = productHash(out.product_id); else fresh();
    }); });
  }
  async function createProduct() {
    const inp = (name, v, o = {}) => h(o.area ? 'textarea' : 'input', { name, value: v ?? '', rows: o.area ? 5 : null, ...o, area: null });
    const vat = h('select', { name: 'vat_rate', 'data-testid': 'product-create-vat' }, vatChoices(25.5).map((v) => h('option', { value: v, text: vatLabel(v), selected: v === 25.5 || null })));
    vat.value = '25.5';
    const cat = h('select', { name: 'category', 'data-testid': 'product-create-category' }, CATEGORY_ORDER.map((c) => h('option', { value: c, text: catLabel(c), selected: c === 'product_rental' || null })));
    cat.value = 'product_rental';
    const f = h('form', { class: 'stack', 'data-testid': 'product-create-form' },
      field(productText('name_fi'), inp('name', '', { required: true, maxlength: 200 })),
      field(productText('name_en'), inp('name_en', '', { maxlength: 200 }), productText('name_en_hint')),
      field(productText('desc_fi'), inp('description', '', { area: true, 'data-rich': '1' }), richText('hint')), field(productText('desc_en'), inp('description_en', '', { area: true, 'data-rich': '1' }), richText('hint')),
      field(productText('short_fi'), inp('short_description', '', { area: true, 'data-rich': '1', 'data-testid': 'product-create-short-fi' }), productText('short_hint')), field(productText('short_en'), inp('short_description_en', '', { area: true, 'data-rich': '1', 'data-testid': 'product-create-short-en' }), productText('short_hint')),
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
      syncRichFields(f);
      const fd = new FormData(f);
      const res = await rpc('admin_product_create', { p_data: {
        name: fd.get('name'), name_en: fd.get('name_en'), description: fd.get('description'), description_en: fd.get('description_en'),
        short_description: fd.get('short_description'), short_description_en: fd.get('short_description_en'),
        price: fd.get('price'), price_text: fd.get('price_text'), vat_rate: fd.get('vat_rate'), category: fd.get('category'),
        active: f.active.checked, age_restricted: f.age_restricted.checked,
      } });
      toast(productText('created')); d.close(); ctx.refs = null;
      if (res?.product?.id != null) location.hash = productHash(res.product.id);   // luonnin jälkeen avataan heti muokkaus
      else fresh();
    }); });
    const d = dialog(productText('new_title'), f, { wide: true });
    try { await mountRichFields(f); } catch (e) { console.error(e); }
  }
  if (legacyId && !productIdFromRest(rest)) { const qs = new URLSearchParams(q0); qs.delete('muokkaa'); history.replaceState(null, '', productHash(legacyId, qs.toString())); }
  const panelHost = h('div', { class: 'prodpanel-host' });
  const mountPanel = async () => {
    const ed = await productEditor({ p: openProduct, all, ctx, isAdmin, deps: { vatChoices, vatLabel, isOnline, catLabel }, backHash: productHash(null, filterQuery()), onSaved: () => draw(), onReset: () => mountPanel(), onCopy: copyProduct });
    panelHost.replaceChildren(ed.node);
    void ed.mount();   // rikas teksti alustetaan, kun paneeli on sivulla
  };
  if (openProduct) await mountPanel();
  else if (openId) panelHost.append(h('p', { class: 'err', role: 'alert', text: 'Tuotetta ei löydy.' }), h('a', { class: 'btn', href: productHash(null, filterQuery()), text: productText('back') }));
  const addonsSection = await addonsAdmin({ ctx });
  // HALL-ASETUKSET-01: QR-tulostus on tuotteen ominaisuus, ei asetus. Osio avautuu osoitteesta #/tuotteet?qr=1 ja latautuu vasta avattaessa.
  const qrSection = await qrPrintSection({ openNow: query?.get?.('qr') === '1' });
  const optionsSection = await productOptionsAdmin({ ctx });   // tuotevalinnat (booking_50)
  const addBtn = isAdmin ? h('button', { type: 'button', class: 'btn primary prod-add', 'data-testid': 'product-add', text: productText('add'), onclick: () => createProduct() }) : null;
  return [h('div', { class: 'row between wrap prod-head' }, h('h1', { text: 'Tuotteet' }), addBtn), h('p', { class: 'muted', text: isAdmin ? 'Tuotetiedot tallentuvat yhteiseen luetteloon (sivusto ja botti käyttävät samaa totuutta). Muutokset kirjataan lokiin.' : 'Näet tuotteet; hintojen ja tuotteiden muokkaus vaatii ylläpitäjän (manager/admin) oikeudet.' }), h('div', { class: `prodlayout${openId ? ' editing' : ''}` }, h('div', { class: 'prodlist-col' }, filters, count, list), openId ? panelHost : null), h('div', { class: 'prodextras' }, qrSection, optionsSection, addonsSection)];
}

async function qrPrintSection({ openNow }) {
  await loadSettingsTexts(rpc);
  const body = h('div', { class: 'stack', 'data-testid': 'qr-print-body' });
  const box = h('details', { class: 'card set-fold', id: 'qr-print', 'data-testid': 'qr-print', open: openNow || null },
    h('summary', {}, h('h2', { text: settingsText('ui.admin.qr.section_title') })),
    h('p', { class: 'muted', text: settingsText('ui.admin.qr.section_help') }), body);
  let loaded = false;
  const load = async () => {
    if (loaded) return;
    loaded = true;
    try { body.replaceChildren(await renderQrPanel()); } catch { loaded = false; body.replaceChildren(h('p', { class: 'err', role: 'alert', text: settingsText('ui.admin.settings.load_failed') })); }
  };
  box.addEventListener('toggle', () => { if (box.open) load(); });
  if (openNow) { load(); setTimeout(() => box.scrollIntoView?.({ block: 'start' }), 0); }
  return box;
}
