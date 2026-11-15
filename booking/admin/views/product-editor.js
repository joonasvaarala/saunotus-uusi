// HALL-TUOTTEET-01: tuote-editori omana näkymänä (#/tuotteet/<id>; työpöydällä listan vieressä sivupaneelina).
// Välilehdet: Perustiedot · Hinnat · Myynti ja näkyvyys · Kuva · Valinnat ja lisäpalvelut · Lisämyynti.
// Yksi kiinnitetty "Tallenna muutokset" -palkki ajaa tarvittavat RPC:t peräkkäin (vain muuttuneet osat) ja kertoo, mikä osa epäonnistui.
// Tallennus ei sulje näkymää. Tallentamattomista muutoksista varoitetaan Escillä, siirtymällä ja välilehden sulkemisella (ui.js setLeaveGuard).
import { rpc, storageUrl, uploadObject, removeObject } from '../sb.js';
import { prepareImage, IMG_TYPES, IMG_MAX_INPUT } from './productimage.js';
import { productSuggestionsEditor } from './product-suggestions.js';
import { h, field, toast, errMsg, badge, tabs, setLeaveGuard } from '../ui.js';
import { richText } from '../rich-texts.js';
import { mountRichFields, syncRichFields } from '../rich-editor.js';
import { productText } from '../product-texts.js';
import { posText } from '../pos-texts.js';
import { looksLikeAlcohol } from '../pos-logic.js';
import { evText } from '../events-texts.js';
import { confirmAsk as confirmDialogAsk } from '../confirm.js';
import {
  baselineFromProduct, diffSnapshots, isDirty, dirtyTabs, validateSnapshot, buildSavePlan, runPlan, rebase, saveSummary, fmt,
  numOrNull, autoPriceText, priceTextIsAuto, imageAction, TAB_IDS,
} from '../product-editor-logic.js';

// Hylkäävä kysymys: oletuspainike on turvallinen vaihtoehto (Jatka muokkausta / Peruuta), ei hylkäys.
const askSafe = (...a) => { const r = confirmDialogAsk(...a); queueMicrotask(() => globalThis.document?.querySelector?.('dialog[open] [data-testid=confirm-no]')?.focus?.()); return r; };
const RICH = ['description', 'description_en', 'short_description', 'short_description_en'];
const newPath = (id, ext) => `products/${id}-${[...crypto.getRandomValues(new Uint8Array(6))].map((b) => (b % 36).toString(36)).join('')}.${ext}`;
const TAB_TEXT = { perustiedot: 'tab_basic', hinnat: 'tab_prices', myynti: 'tab_sales', kuva: 'tab_image', valinnat: 'tab_options', lisamyynti: 'tab_upsell' };

/**
 * Palauttaa { node, dirty(), close() }. Näkymä lisää noden sivupaneeliksi ja rekisteröi poistumisvahdin.
 * deps: { vatChoices, vatLabel, isOnline, catLabel }; onSaved(): tuotelista piirretään uudelleen (p on päivitetty paikallaan);
 * onReset(): paneeli piirretään uudelleen tallennetuista tiedoista (Hylkää muutokset).
 */
export async function productEditor({ p, all, ctx, isAdmin, deps, backHash, onSaved, onReset, onCopy }) {
  const T = productText;
  const training = p.category === 'training';
  const offers = training ? await rpc('admin_training_addons_get', { p_product_id: p.id }).catch(() => []) : [];
  const alcohol = looksLikeAlcohol([p.name, p.name_en, p.description, p.description_en].filter(Boolean).join(' '));
  let base = baselineFromProduct(p, { offers, alcohol });
  const dis = !isAdmin;
  const ctl = {};   // kenttien viitteet nimen mukaan
  const errs = new Map();   // kenttä → virheviesti-elementti

  const inp = (name, v, { area, ...o } = {}) => (ctl[name] = h(area ? 'textarea' : 'input', { name, value: v ?? '', rows: area ? 5 : null, disabled: dis, ...o }));
  const chk = (name, label, checked, disabled = dis) => { const i = (ctl[name] = h('input', { type: 'checkbox', name, disabled })); i.checked = !!checked; return h('label', { class: 'check' }, i, ' ' + label); };
  const errFor = (name) => { const e = h('small', { class: 'err', role: 'alert', hidden: true, 'data-err-for': name }); errs.set(name, e); return e; };
  const fld = (name, label, input, hint) => { const f = field(label, input, hint); f.append(errFor(name)); return f; };

  // ---- Perustiedot ----
  const basic = h('div', { class: 'stack', 'data-testid': 'product-tab-basic' },
    fld('name', T('name_fi'), inp('name', p.name, { required: true, maxlength: 200 })), fld('name_en', T('name_en'), inp('name_en', p.name_en, { maxlength: 200 })),
    field(T('desc_fi'), inp('description', p.description, { area: true, 'data-rich': '1' }), richText('hint')), field(T('desc_en'), inp('description_en', p.description_en, { area: true, 'data-rich': '1' }), richText('hint')),
    // booking_156: lyhyt kuvaus (rikas teksti, sama allowlist kuin kuvauksella) → tuotekortti ja tuotesivun yläosa; tyhjä → ote kuvauksesta
    field(T('short_fi'), inp('short_description', p.short_description, { area: true, 'data-rich': '1', 'data-testid': 'product-short-fi' }), T('short_hint')), field(T('short_en'), inp('short_description_en', p.short_description_en, { area: true, 'data-rich': '1', 'data-testid': 'product-short-en' }), T('short_hint')),
    h('p', { class: 'muted', text: `${T('category')}: ${deps.catLabel(p.category)}` }));

  // ---- Hinnat ----
  const vat = (ctl.vat_rate = h('select', { name: 'vat_rate', disabled: dis }, deps.vatChoices(p.vat_rate).map((v) => h('option', { value: v, text: deps.vatLabel(v), selected: +p.vat_rate === v || null }))));
  vat.value = String(base.product.vat_rate);
  const priceHint = h('small', { 'data-testid': 'price-text-hint', 'aria-live': 'polite' });
  const priceWarn = h('small', { class: 'err', role: 'status', hidden: true, 'data-testid': 'price-text-stale' });
  const priceReset = h('button', { type: 'button', class: 'btn sm ghost', hidden: true, 'data-testid': 'price-text-reset', text: T('price_text_reset'), disabled: dis });
  const priceTextFld = h('label', { class: 'fld' }, h('span', { text: T('price_text') }), inp('price_text', p.price_text, { maxlength: 200 }), priceHint, priceWarn);
  const variantInputs = new Map();
  const vars = (p.variants || []).length ? h('div', { class: 'box stack', 'data-testid': 'product-variants' }, h('h3', { text: 'Hintavariantit' }), ...p.variants.map((v) => {
    const i = h('input', { type: 'number', step: '0.01', min: '0', value: v.price, disabled: dis, 'aria-label': `Hinta: ${v.label}`, name: `variant_${v.id}` });
    variantInputs.set(String(v.id), i);
    return h('div', { class: 'row wrap varrow' }, h('span', { class: 'grow' }, h('strong', { text: v.label }), h('small', { text: ` ${v.valid_from || ''}${v.valid_to ? '–' + v.valid_to : ''}${v.included_persons ? ` · sis. ${v.included_persons} hlö` : ''}${v.extra_person_price ? ` · lisählö ${v.extra_person_price} €` : ''}` })), i, errFor(`variant:${v.id}`));
  })) : null;
  const prices = h('div', { class: 'stack', 'data-testid': 'product-tab-prices' },
    h('div', { class: 'row wrap' }, fld('price', training ? 'Varausmaksu € (maksetaan verkossa)' : T('price'), inp('price', base.product.price, { type: 'number', step: '0.01', min: '0', inputmode: 'decimal', 'data-testid': 'product-deposit' })), field(T('vat'), vat), errFor('vat_rate')),
    training ? h('div', { class: 'row wrap', 'data-testid': 'product-training-prices' }, fld('course_price', 'Kurssin hinta € (loppusumma, laskutetaan myöhemmin)', inp('course_price', base.training?.course_price ?? '', { type: 'number', step: '0.01', min: '0', 'data-testid': 'product-course-price' }))) : null,
    priceTextFld, priceReset, vars);
  let priceAuto = priceTextIsAuto(base.product.price_text, base.product.price);
  const syncPriceText = () => {
    const price = numOrNull(ctl.price.value);
    priceHint.textContent = priceAuto ? T('price_text_auto') : T('price_text_manual');
    priceReset.hidden = priceAuto || dis;
    priceWarn.hidden = !(!priceAuto && !Object.is(price, base.product.price) && ctl.price_text.value === base.product.price_text);
    priceWarn.textContent = priceWarn.hidden ? '' : T('price_text_stale');
  };
  priceReset.addEventListener('click', () => { ctl.price_text.value = autoPriceText(ctl.price.value); priceAuto = true; refresh(); });

  // ---- Myynti ja näkyvyys ----
  const c = p.config;
  const bc = base.config;
  const sales = h('div', { class: 'stack', 'data-testid': 'product-tab-sales' },
    chk('active', 'Aktiivinen (näkyy kb:ssä)', base.product.active),
    c ? h('div', { class: 'stack box' }, h('h3', { text: 'Verkkokaupan asetukset' }),
      chk('bookable', 'Varattavissa verkossa', bc.bookable), chk('shop_visible', 'Näkyy kaupan listassa', bc.shop_visible),
      'audience' in c ? field('Kalenteri', (ctl.audience = h('select', { name: 'audience', disabled: dis }, h('option', { value: 'consumer', text: 'Kuluttajien kalenteri' }), h('option', { value: 'business', text: 'Yrityksille' }))), 'Yrityksille-valinta näyttää vuoron vain yritysten kalenterissa.') : null,
      h('div', { class: 'row wrap' }, field('Järjestys', inp('sort_order', c.sort_order, { type: 'number' })), field('Min hlö', inp('min_persons', c.min_persons, { type: 'number', min: 1 })), field('Max hlö', inp('max_persons', c.max_persons ?? '', { type: 'number', min: 1 })), errFor('sort_order'), errFor('min_persons'), errFor('max_persons')),
      h('h3', { text: posText('nav') }),
      chk('pos_enabled', posText('product_pos'), bc.pos_enabled),
      field(posText('product_pos_sort'), inp('pos_sort', c.pos_sort ?? 100, { type: 'number', min: 0, max: 10000 })), errFor('pos_sort'),
      chk('fridge_sale', posText('qr_sale'), bc.fridge_sale, dis || alcohol || !!c.age_restricted),
      chk('age_restricted', posText('product_age'), bc.age_restricted),
      h('p', { class: 'muted', text: posText('qr_sale_hint') }),
      alcohol ? h('p', { class: 'err', text: posText('alcohol_qr') }) : null)
      : h('p', { class: 'muted', text: 'Tuotetta ei ole vielä otettu mukaan varausjärjestelmään (product_config puuttuu).' }),
    c && isAdmin ? h('div', { class: 'box stack prod-next', 'data-testid': 'product-next' },
      h('p', { text: T('next') }), h('p', { class: 'muted', text: T('pos_hint') }),
      h('a', { class: 'btn', href: '#/pikakassa', 'data-testid': 'product-open-pos', text: T('link_pos') }),
      h('p', { class: 'muted', text: T('qr_hint') }),
      h('a', { class: 'btn', href: '#/tuotteet?qr=1', 'data-testid': 'product-open-qr', text: T('link_qr') })) : null);
  if (c && ctl.audience) ctl.audience.value = bc.audience;
  if (c) ctl.age_restricted.addEventListener('change', () => { if (ctl.age_restricted.checked) { ctl.fridge_sale.checked = false; ctl.fridge_sale.disabled = true; } else if (isAdmin && !alcohol) ctl.fridge_sale.disabled = false; });

  // ---- Kuva ----
  const img = { file: null, remove: false };
  const imgNote = h('p', { class: 'muted', role: 'status', 'aria-live': 'polite' });
  const preview = h('div', { class: 'imgprev', role: 'img', 'aria-label': 'Tuotekuvan esikatselu' });
  const showImg = () => {
    const path = p.config?.image_path;
    const url = img.remove ? null : (img.file?.url || (path ? storageUrl('product-images', path) : null));
    preview.replaceChildren(url ? h('img', { src: url, alt: '' }) : h('span', { class: 'muted', text: 'Ei kuvaa' })); preview.classList.toggle('has', !!url);
  };
  let imageBox = null, imageUi = null;
  if (c) {
    const fileIn = h('input', { type: 'file', accept: IMG_TYPES.join(','), class: 'sr', id: `img-file-${p.id}`, 'aria-label': 'Valitse kuvatiedosto', tabindex: -1, disabled: dis });
    const pick = h('button', { type: 'button', class: 'btn', text: c.image_path ? 'Vaihda kuva' : 'Valitse kuva', disabled: dis, onclick: () => fileIn.click() });
    const del = h('button', { type: 'button', class: 'btn danger', text: 'Poista kuva', disabled: dis || !c.image_path, 'data-testid': 'product-image-remove' });
    const undo = h('button', { type: 'button', class: 'btn ghost', hidden: true, text: T('image_undo') });
    const altIn = inp('image_alt', c.image_alt || '', { maxlength: 200, placeholder: p.name });
    const status = () => {
      del.hidden = img.remove; undo.hidden = !img.remove;
      imgNote.className = 'muted'; imgNote.textContent = img.remove ? T('image_remove_pending') : img.file ? T('image_pending') : '';
    };
    fileIn.addEventListener('change', async () => {
      const f = fileIn.files[0]; fileIn.value = ''; if (!f) return;
      imgNote.textContent = 'Käsitellään kuvaa…'; imgNote.className = 'muted';
      try { img.file = await prepareImage(f); img.remove = false; showImg(); status(); imgNote.textContent = `Valittu: ${f.name} → ${(img.file.blob.size / 1024).toFixed(0)} kt (${img.file.w}×${img.file.h}). ${T('image_pending')}`; refresh(); }
      catch (e) { imgNote.textContent = e.message; imgNote.className = 'err'; }
    });
    del.addEventListener('click', async () => { if (!(await askSafe('Poistetaanko tuotteen kuva?', { yes: 'Poista kuva' }))) return; img.remove = true; img.file = null; showImg(); status(); refresh(); });
    undo.addEventListener('click', () => { img.remove = false; showImg(); status(); refresh(); });
    imageUi = () => { del.disabled = dis || !p.config?.image_path; pick.textContent = p.config?.image_path ? 'Vaihda kuva' : 'Valitse kuva'; status(); };
    showImg();
    imageBox = h('div', { class: 'stack', 'data-testid': 'product-tab-image' }, preview,
      isAdmin ? [h('div', { class: 'row wrap' }, pick, fileIn, del, undo), field('Kuvan alt-teksti (valinnainen)', altIn, 'Kuvaus ruudunlukijalle; jos tyhjä, käytetään tuotteen nimeä.'),
        h('p', { class: 'muted', text: `JPEG, PNG tai WebP, enintään ${IMG_MAX_INPUT / 1048576} Mt. Kuva pienennetään automaattisesti (enintään 1600 px) ja tallennetaan julkiseen kuvakansioon.` })] : h('p', { class: 'muted', text: 'Kuvan vaihto vaatii ylläpitäjän (manager/admin) oikeudet.' }),
      imgNote);
    status();
  } else imageBox = h('p', { class: 'muted', text: 'Tuotetta ei ole vielä otettu mukaan varausjärjestelmään (product_config puuttuu).' });

  // ---- Valinnat ja lisäpalvelut ----
  const options = h('div', { class: 'stack', 'data-testid': 'product-tab-options' },
    training ? h('fieldset', { class: 'stack box', 'data-testid': 'product-training-addons' }, h('legend', { text: 'Lisävalinnat (eivät veloitu verkossa)' }),
      chk('addon_single', 'Yhden hengen huone', base.training.addon_single), fld('addon_single_price', 'Hinta €', inp('addon_single_price', base.training.addon_single_price, { type: 'number', step: '0.01', min: '0' })),
      chk('addon_intern', 'Harjoittelujakso', base.training.addon_intern), fld('addon_intern_price', 'Hinta €', inp('addon_intern_price', base.training.addon_intern_price, { type: 'number', step: '0.01', min: '0' }))) : null,
    h('p', { class: 'muted', text: T('options_note') }));

  // ---- Lisämyynti ----
  const suggested = await productSuggestionsEditor({ product: p, all, canEdit: isAdmin && ctx.role === 'admin', embedded: true });
  const api = suggested?.editorApi || null;
  if (api) base.suggestions = api.snapshot();
  const upsell = h('div', { class: 'stack', 'data-testid': 'product-tab-upsell' }, suggested || h('p', { class: 'muted', text: T('upsell_missing') }));

  // ---- välilehdet ----
  const panels = { perustiedot: basic, hinnat: prices, myynti: sales, kuva: imageBox, valinnat: options, lisamyynti: upsell };
  let current = 'perustiedot';
  const tabList = tabs({
    label: T('tabs_label'), idPrefix: 'prodtab', testid: 'product-tabs', selected: current,
    items: TAB_IDS.map((id) => ({ id, text: T(TAB_TEXT[id]), controls: `prodpanel-${id}`, testid: `product-tab-${id}` })),
    onSelect: (id) => showTab(id),
  });
  const panelHost = h('div', { class: 'prodtabpanels' }, TAB_IDS.map((id) => h('section', { role: 'tabpanel', id: `prodpanel-${id}`, 'aria-labelledby': `prodtab-${id}`, hidden: id !== current || null, class: 'prodtabpanel' }, panels[id])));
  function showTab(id) { current = id; tabList.select(id); TAB_IDS.forEach((t, i) => { panelHost.children[i].hidden = t !== id; }); }

  // ---- tila ----
  const val = (name) => {
    const hid = RICH.includes(name) ? root.querySelector(`input[type="hidden"][name="${name}"]`) : null;
    return (hid || ctl[name]).value;
  };
  function read() {
    syncRichFields(root);
    const cur = {
      product: { name: val('name'), name_en: val('name_en'), description: val('description'), description_en: val('description_en'), short_description: val('short_description'), short_description_en: val('short_description_en'),
        price: numOrNull(ctl.price.value), price_text: ctl.price_text.value, vat_rate: numOrNull(vat.value), active: ctl.active.checked },
      config: c ? { bookable: ctl.bookable.checked, shop_visible: ctl.shop_visible.checked, ...(ctl.audience ? { audience: ctl.audience.value } : {}),
        sort_order: numOrNull(ctl.sort_order.value), min_persons: numOrNull(ctl.min_persons.value), max_persons: numOrNull(ctl.max_persons.value),
        pos_enabled: ctl.pos_enabled.checked, pos_sort: numOrNull(ctl.pos_sort.value), fridge_sale: ctl.fridge_sale.checked, age_restricted: ctl.age_restricted.checked } : null,
      training: training ? { course_price: numOrNull(ctl.course_price.value), addon_single: ctl.addon_single.checked, addon_single_price: numOrNull(ctl.addon_single_price.value), addon_intern: ctl.addon_intern.checked, addon_intern_price: numOrNull(ctl.addon_intern_price.value) } : null,
      variants: Object.fromEntries([...variantInputs].map(([id, i]) => [id, numOrNull(i.value)])),
      image: { alt: (ctl.image_alt?.value || '').trim(), hasImage: base.image.hasImage, file: !!img.file, remove: img.remove },
      suggestions: api ? api.snapshot() : null,
    };
    return cur;
  }
  const diffNow = () => diffSnapshots(base, read());
  const dirty = () => isDirty(diffNow());

  // ---- tallennuspalkki ----
  const status = h('p', { class: 'grow prodsave-status', role: 'status', 'aria-live': 'polite', 'data-testid': 'product-save-status' });
  const result = h('p', { class: 'prodsave-result', role: 'status', 'aria-live': 'polite', hidden: true, 'data-testid': 'product-save-result' });
  const saveBtn = h('button', { type: 'button', class: 'btn primary', 'data-testid': 'product-save-all', text: T('save'), disabled: true });
  const discardBtn = h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'product-discard', text: T('discard'), disabled: true });
  const bar = isAdmin ? h('div', { class: 'prodsavebar', 'data-testid': 'product-savebar' }, result, h('div', { class: 'row wrap' }, status, discardBtn, saveBtn)) : null;
  let saving = false;
  function refresh() {
    const d = diffNow();
    const tabsDirty = dirtyTabs(d);
    for (const t of TAB_IDS) { const b = tabList.button(t); b.setAttribute('data-dirty', String(tabsDirty.includes(t))); }
    syncPriceText();
    const dirtyNow = isDirty(d);
    status.textContent = dirtyNow ? fmt(T('dirty'), { tabs: tabsDirty.map((t) => T(TAB_TEXT[t])).join(', ') }) : T('clean');
    status.classList.toggle('is-dirty', dirtyNow);
    if (bar) { saveBtn.disabled = saving || !dirtyNow; discardBtn.disabled = saving || !dirtyNow; }
    return dirtyNow;
  }
  function showErrors(list) {
    for (const [name, el] of errs) { el.hidden = true; el.textContent = ''; ctl[name]?.setAttribute?.('aria-invalid', 'false'); }
    for (const e of list) { const el = errs.get(e.field); if (el) { el.hidden = false; el.textContent = T(e.key); } (ctl[e.field] || variantInputs.get(e.field.replace('variant:', '')))?.setAttribute?.('aria-invalid', 'true'); }
  }
  async function save() {
    if (saving || !isAdmin) return;
    const cur = read();
    const invalid = validateSnapshot(cur, base);
    showErrors(invalid);
    if (invalid.length) {
      showTab(invalid[0].tab); (ctl[invalid[0].field] || variantInputs.get(invalid[0].field.replace('variant:', '')))?.focus?.();
      toast(T('save_invalid'), 'err'); return;
    }
    const vlabel = new Map((p.variants || []).map((v) => [String(v.id), v.label]));
    const labels = { product: T('step_product'), training: T('step_training'), config: T('step_config'), image: T('step_image'), suggestions: T('step_upsell'), variant: (id) => fmt(T('step_variant'), { name: vlabel.get(String(id)) || id }) };
    const steps = buildSavePlan({ productId: p.id, training, base, cur, labels });
    if (!steps.length) return;
    saving = true; saveBtn.disabled = true; discardBtn.disabled = true; saveBtn.textContent = T('saving');
    const imgNow = { ...cur.image };
    const res = await runPlan(steps, async (s) => {
      if (s.key === 'image') return saveImage(imgNow);
      if (s.key === 'suggestions') return api.save();
      for (const call of s.calls) await rpc(call.fn, call.args);
    });
    saving = false; saveBtn.textContent = T('save');
    const sum = saveSummary(res, T, errMsg);
    result.hidden = false; result.className = `prodsave-result ${sum.kind}`; result.textContent = sum.text;
    toast(sum.text, sum.kind === 'ok' ? 'ok' : sum.kind === 'warn' ? 'warn' : 'err');
    if (res.done.length) {
      base = rebase(base, cur, res.done);
      if (res.done.includes('suggestions')) api.rebase();
      if (res.done.includes('image')) { img.file = null; img.remove = false; showImg(); }
      try { await refreshProduct(); } catch (e) { console.warn(e); }
      title.textContent = p.name;
      imageUi?.();
      onSaved?.();
    }
    refresh();
    if (res.failed.length) { const bad = dirtyTabs(diffNow()); if (bad.length && !bad.includes(current)) showTab(bad[0]); }   // epäonnistunut osa jää muutokseksi: näytetään sen välilehti
  }
  async function saveImage(ci) {
    const cfg = p.config;
    const action = imageAction(ci, base.image);
    if (action === 'remove') {
      const r = await rpc('admin_set_product_image', { p_product_id: p.id, p_image_path: null, p_image_alt: null });
      if (r?.previous_path) await removeObject('product-images', r.previous_path).catch(() => {});
      return;
    }
    let path = cfg.image_path;
    if (img.file) { path = newPath(p.id, img.file.ext); await uploadObject('product-images', path, img.file.blob); }
    const r = await rpc('admin_set_product_image', { p_product_id: p.id, p_image_path: path, p_image_alt: ci.alt || null });
    if (img.file && r?.previous_path && r.previous_path !== path) await removeObject('product-images', r.previous_path).catch(() => {});   // vanha tiedosto siivotaan (virhe ei haittaa)
  }
  // Tallennuksen jälkeen haetaan tuore tuote ja päivitetään paikallinen olio paikallaan (lista ja muut näkymät käyttävät samaa oliota).
  async function refreshProduct() {
    const list = await rpc('admin_list_products');
    const fresh = (Array.isArray(list) ? list : []).find((x) => x.id === p.id);
    if (!fresh) return;
    for (const k of Object.keys(p)) delete p[k];
    Object.assign(p, fresh);
    if (ctx.refs?.productById) ctx.refs.productById.set(p.id, p);
  }
  saveBtn.addEventListener('click', save);
  discardBtn.addEventListener('click', async () => { if (dirty() && await askSafe(T('leave_body'), { title: T('discard'), yes: T('discard'), no: T('leave_no') })) { setLeaveGuard(null); onReset?.(); } });

  // ---- kokoaminen ----
  const title = h('h2', { class: 'grow', text: p.name, 'data-testid': 'product-editor-title' });
  const head = h('div', { class: 'prodpanel-head row wrap' },
    h('a', { class: 'btn ghost', href: backHash, 'data-testid': 'product-back', text: T('back') }),
    title,
    deps.isOnline(p) ? badge('ok', 'Verkossa') : badge('muted', 'Ei verkossa'),
    isAdmin ? h('button', { type: 'button', class: 'btn', 'data-testid': 'product-copy', text: evText('ui.admin.product.copy'), onclick: () => onCopy?.(p) }) : null);
  const root = h('section', { class: 'prodpanel card', 'data-testid': 'product-editor', 'aria-label': p.name },
    head, isAdmin ? null : h('p', { class: 'muted', text: 'Tuotteiden, hintojen ja kuvausten muokkaus vaatii ylläpitäjän (manager/admin) oikeudet.' }),
    tabList, panelHost, bar);
  // Hintateksti seuraa hintaa, kunnes sitä muokataan käsin (tai se palautetaan hinnasta).
  root.addEventListener('input', (e) => {
    if (e.target === ctl.price && priceAuto) ctl.price_text.value = autoPriceText(ctl.price.value);
    else if (e.target === ctl.price_text) priceAuto = priceTextIsAuto(ctl.price_text.value, ctl.price.value);
  });
  for (const ev of ['input', 'change', 'keyup', 'click', 'focusout']) root.addEventListener(ev, () => { refresh(); });
  // Esc: sulje paneeli (kysyy, jos tallentamatta); ei kun Esc kuuluu valikolle tai dialogille.
  root.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !e.defaultPrevented && e.target?.tagName !== 'SELECT' && !e.target?.closest?.('[role=dialog],dialog')) { e.preventDefault(); location.hash = backHash; } });
  const guard = {
    dirty,
    ask: (next) => (String(next || '').replace(/\?.*/, '') === `#/tuotteet/${p.id}` ? true
      : askSafe(T('leave_body'), { title: T('leave_title'), yes: T('leave_yes'), no: T('leave_no'), testid: 'leave-confirm' })),
  };
  setLeaveGuard(guard);
  refresh();
  return {
    node: root, dirty, guard,
    // Quill muuttaa tallennetun tekstin HTML:ksi: otetaan se lähtökuvaksi, ettei muokkaamaton kenttä näytä muuttuneelta.
    async mount() {
      for (let i = 0; root.isConnected === false && i < 50; i++) await new Promise((r) => setTimeout(r, 20));   // reititin liittää näkymän sivulle vasta renderöinnin jälkeen
      try { await mountRichFields(root); } catch (e) { console.error(e); }
      const cur = read();
      for (const k of RICH) base.product[k] = cur.product[k];
      refresh();
    },
  };
}
