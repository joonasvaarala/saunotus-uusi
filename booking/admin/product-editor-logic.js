// HALL-TUOTTEET-01: tuote-editorin puhdas logiikka (ei DOM:ia, ei verkkoa). node --test ajaa tämän suoraan.
// Editori lukee lomakkeen tilan "kuvaksi" (snapshot), vertaa sitä tallennettuun kuvaan ja rakentaa tallennussuunnitelman:
// vain muuttuneet osat, yksi RPC-jono. Näkymä (views/product-editor.js) ajaa suunnitelman ja kertoo, mikä osa epäonnistui.

import { codesKey } from './sales-channels.js';

export const TAB_IDS = ['perustiedot', 'hinnat', 'myynti', 'kuva', 'valinnat', 'lisamyynti'];
// booking_316: shop_visible, pos_enabled ja fridge_sale ovat nyt myyntikanavia (snapshot.channels), eivät config-kenttiä.
// bookable (Varattavissa verkossa) ei ole enää lomakkeella (Joonas 15.11.): julkinen kanava asettaa sen kannassa.
export const CONFIG_FIELDS = ['audience', 'sort_order', 'min_persons', 'max_persons', 'pos_sort', 'age_restricted'];

/** Syöte → luku. Tyhjä → null, virheellinen → NaN. Pilkku kelpaa desimaalierottimena. */
export const numOrNull = (v) => {
  if (v == null) return null;
  const s = String(v).trim().replace(',', '.');
  if (s === '') return null;
  return /^-?\d+(\.\d+)?$/.test(s) ? Number(s) : NaN;
};

/** Sama muoto kuin palvelimen admin_product_create: "3,50 €". */
export const autoPriceText = (price) => {
  const n = numOrNull(price);
  return n == null || Number.isNaN(n) || n < 0 ? '' : `${n.toFixed(2).replace('.', ',')} €`;
};
/** Hintateksti on "automaattinen", jos se on tyhjä tai täsmälleen hinnasta johdettu teksti. Muuten se on käsin kirjoitettu. */
export const priceTextIsAuto = (text, price) => {
  const t = String(text ?? '').trim();
  return t === '' || t === autoPriceText(price);
};

/**
 * Tallennettu tuote (+ koulutuksen lisävalinnat, myyntikanavat) → editorin lähtökuva.
 * channels: tuotteen kanavakoodit admin_list_sales_channels-vastauksesta; null = kanavia ei saatu ladattua (kanavia ei voi muuttaa).
 */
export function baselineFromProduct(p, { offers = [], alcohol = false, channels = null } = {}) {
  const c = p?.config || null;
  const training = p?.category === 'training';
  const offerOf = (code) => (offers || []).find((o) => o.code === code) || null;
  const price = training ? (c?.deposit_amount ?? p.price) : p.price;
  return {
    product: {
      name: p.name ?? '', name_en: p.name_en ?? '', description: p.description ?? '', description_en: p.description_en ?? '',
      short_description: p.short_description ?? '', short_description_en: p.short_description_en ?? '',
      price: numOrNull(price), price_text: p.price_text ?? '', vat_rate: numOrNull(p.vat_rate), active: !!p.active,
    },
    config: c ? {
      ...('audience' in c ? { audience: c.audience === 'business' ? 'business' : 'consumer' } : {}),
      sort_order: numOrNull(c.sort_order), min_persons: numOrNull(c.min_persons), max_persons: numOrNull(c.max_persons),
      pos_sort: numOrNull(c.pos_sort ?? 100), age_restricted: !!c.age_restricted,
    } : null,
    // booking_316: myyntikanavat (monivalinta). Alkoholituote tai ikärajallinen: lomake näyttää QR-myynnin pois päältä,
    // ja tallennus poistaa sen myös kannasta (kuten ennen fridge_sale).
    channels: channels == null ? null : [...new Set(channels)].filter((x) => !(x === 'qr' && (alcohol || c?.age_restricted))).sort(),
    qrStored: !!channels?.includes('qr'),
    training: training ? {
      course_price: numOrNull(c?.course_price),
      addon_single: !!offerOf('single_room')?.active, addon_single_price: numOrNull(offerOf('single_room')?.price ?? 200),
      addon_intern: !!offerOf('internship')?.active, addon_intern_price: numOrNull(offerOf('internship')?.price ?? 500),
    } : null,
    variants: Object.fromEntries((p.variants || []).map((v) => [v.id, numOrNull(v.price)])),
    image: { alt: c?.image_alt || '', hasImage: !!c?.image_path, file: false, remove: false },
    suggestions: null,   // lisämyynnin tila kuvataan merkkijonona (näkymä täyttää); null = ei ladattu
  };
}

const same = (a, b) => a === b || (Number.isNaN(a) && Number.isNaN(b)) || (a == null && b == null);
const changedKeys = (a, b) => Object.keys(b || {}).filter((k) => !same(a?.[k], b[k]));

/** Mitkä osat poikkeavat lähtökuvasta. Palauttaa { product: [avaimet], config: [...], training: [...], variants: [id], image: bool, suggestions: bool }. */
export function diffSnapshots(base, cur) {
  const d = {
    product: changedKeys(base.product, cur.product),
    config: base.config && cur.config ? changedKeys(base.config, cur.config) : [],
    training: base.training && cur.training ? changedKeys(base.training, cur.training) : [],
    variants: Object.keys(cur.variants || {}).filter((id) => !same(base.variants?.[id], cur.variants[id])),
    image: !!(cur.image?.file || cur.image?.remove || (cur.image?.alt ?? '') !== (base.image?.alt ?? '')),
    suggestions: base.suggestions != null && cur.suggestions != null && base.suggestions !== cur.suggestions,
    channels: base.channels != null && cur.channels != null && codesKey(base.channels) !== codesKey(cur.channels),
  };
  // Alt-teksti ilman kuvaa ei ole muutos
  if (d.image && !cur.image.file && !base.image.hasImage) d.image = false;
  return d;
}
export const isDirty = (d) => !!(d.product.length || d.config.length || d.training.length || d.variants.length || d.image || d.suggestions || d.channels);

const PRICE_KEYS = new Set(['price', 'price_text', 'vat_rate']);
/** Välilehdet, joilla on tallentamattomia muutoksia. */
export function dirtyTabs(d) {
  const tabs = new Set();
  for (const k of d.product) tabs.add(PRICE_KEYS.has(k) ? 'hinnat' : k === 'active' ? 'myynti' : 'perustiedot');
  if (d.config.length || d.channels) tabs.add('myynti');
  for (const k of d.training) tabs.add(k === 'course_price' ? 'hinnat' : 'valinnat');
  if (d.variants.length) tabs.add('hinnat');
  if (d.image) tabs.add('kuva');
  if (d.suggestions) tabs.add('lisamyynti');
  return TAB_IDS.filter((t) => tabs.has(t));
}

/** Tarkistus ennen tallennusta. Palauttaa [{ tab, field, key }] (key = product-texts-avain virheviestille). */
export function validateSnapshot(cur, base = null) {
  const errs = [];
  if (!String(cur.product.name ?? '').trim()) errs.push({ tab: 'perustiedot', field: 'name', key: 'err_name' });
  const price = cur.product.price;
  if (price == null || Number.isNaN(price) || price < 0) errs.push({ tab: 'hinnat', field: 'price', key: 'err_price' });
  if (cur.product.vat_rate == null || Number.isNaN(cur.product.vat_rate)) errs.push({ tab: 'hinnat', field: 'vat_rate', key: 'err_vat' });
  const t = cur.training;
  if (t) {
    if (Number.isNaN(t.course_price) || (t.course_price != null && t.course_price < 0)) errs.push({ tab: 'hinnat', field: 'course_price', key: 'err_price' });
    for (const k of ['addon_single_price', 'addon_intern_price']) if (t[k] == null || Number.isNaN(t[k]) || t[k] < 0) errs.push({ tab: 'valinnat', field: k, key: 'err_price' });
  }
  for (const [id, v] of Object.entries(cur.variants || {})) if (v == null || Number.isNaN(v) || v < 0) errs.push({ tab: 'hinnat', field: `variant:${id}`, key: 'err_price' });
  const c = cur.config;
  if (c) {
    // Tyhjä luku on virhe vain, jos kentällä oli ennen arvo (vanhassa product_config-rivissä kenttä voi puuttua kokonaan).
    for (const k of ['sort_order', 'min_persons', 'pos_sort']) if (Number.isNaN(c[k]) || (c[k] == null && base?.config?.[k] != null)) errs.push({ tab: 'myynti', field: k, key: 'err_number' });
    if (Number.isNaN(c.max_persons)) errs.push({ tab: 'myynti', field: 'max_persons', key: 'err_number' });
  }
  return errs;
}

/**
 * Tallennussuunnitelma: vain muuttuneet osat, järjestyksessä tuote → koulutus → myynti → hintavariantit → kuva → lisämyynti.
 * Askel: { key, label, calls: [{ fn, args }] }. Kuva ja lisämyynti ovat näkymän omia askelia (custom: true, näkymä ajaa ne).
 * labels: { product, training, config, channels, image, suggestions, variant: (id) => teksti }.
 * booking_316: myyntikanavat tallennetaan omana askeleenaan (admin_set_product_sales_channels). Jos askel poistaa QR-myynnin,
 * se ajetaan ennen asetuksia (ikärajan lisäys ei onnistu, kun QR-myynti on päällä); muuten asetusten jälkeen.
 */
export function buildSavePlan({ productId, training = false, base, cur, labels }) {
  const d = diffSnapshots(base, cur);
  const steps = [];
  if (d.product.length) {
    const patch = {};
    for (const k of d.product) patch[k] = cur.product[k];
    // Tyhjä hintateksti täytetään hinnasta, kuten uutta tuotetta luotaessa.
    if ('price_text' in patch && !String(patch.price_text ?? '').trim()) patch.price_text = autoPriceText(cur.product.price);
    steps.push({ key: 'product', label: labels.product, calls: [{ fn: 'admin_update_product', args: { p_product_id: productId, p_patch: patch } }] });
  }
  if (training && cur.training) {
    const calls = [];
    const cfgPatch = {};
    if (d.product.includes('price')) cfgPatch.deposit_amount = cur.product.price;
    if (d.training.includes('course_price')) cfgPatch.course_price = cur.training.course_price;
    if (Object.keys(cfgPatch).length) calls.push({ fn: 'admin_update_product_config', args: { p_product_id: productId, p_patch: cfgPatch } });
    if (['addon_single', 'addon_single_price', 'addon_intern', 'addon_intern_price'].some((k) => d.training.includes(k))) {
      const rows = [];
      if (cur.training.addon_single) rows.push({ code: 'single_room', price: cur.training.addon_single_price, active: true });
      if (cur.training.addon_intern) rows.push({ code: 'internship', price: cur.training.addon_intern_price, active: true });
      calls.push({ fn: 'admin_training_addons_set', args: { p_product_id: productId, p_offers: rows } });
    }
    if (calls.length) steps.push({ key: 'training', label: labels.training, calls });
  }
  const configStep = base.config && cur.config && d.config.length ? (() => {
    const patch = {};
    for (const k of d.config) patch[k] = cur.config[k];
    return { key: 'config', label: labels.config, calls: [{ fn: 'admin_update_product_config', args: { p_product_id: productId, p_patch: patch } }] };
  })() : null;
  // Lomake näytti QR-myynnin pois (alkoholi/ikäraja), mutta kannassa se on päällä: se poistetaan, kun myynnin asetuksia tallennetaan (kuten ennen).
  const qrCleanup = cur.channels != null && base.qrStored && !cur.channels.includes('qr') && !!configStep;
  const channelsStep = cur.channels != null && (d.channels || qrCleanup)
    ? { key: 'channels', label: labels.channels ?? labels.config, calls: [{ fn: 'admin_set_product_sales_channels', args: { p_product_id: productId, p_codes: [...cur.channels].sort() } }] }
    : null;
  const removesQr = !!channelsStep && base.qrStored && !cur.channels.includes('qr');
  if (channelsStep && removesQr) steps.push(channelsStep);
  if (configStep) steps.push(configStep);
  if (channelsStep && !removesQr) steps.push(channelsStep);
  for (const id of d.variants) steps.push({ key: `variant:${id}`, label: labels.variant(id), calls: [{ fn: 'admin_update_price_variant', args: { p_variant_id: Number(id), p_patch: { price: cur.variants[id] } } }] });
  if (d.image) steps.push({ key: 'image', label: labels.image, custom: true, calls: [] });
  if (d.suggestions) steps.push({ key: 'suggestions', label: labels.suggestions, custom: true, calls: [] });
  return steps;
}

/** Aja askeleet peräkkäin. Yksi virhe ei estä muita; palauttaa { done: [avaimet], failed: [{ key, label, error }] }. */
export async function runPlan(steps, exec) {
  const done = [], failed = [];
  for (const s of steps) {
    try { await exec(s); done.push(s.key); } catch (error) { failed.push({ key: s.key, label: s.label, error }); }
  }
  return { done, failed };
}

/** Tallennetut askeleet → uusi lähtökuva: onnistuneet osat otetaan nykyisestä tilasta, epäonnistuneet jäävät muutoksiksi. */
export function rebase(base, cur, doneKeys) {
  const next = JSON.parse(JSON.stringify(base));
  const ok = new Set(doneKeys);
  if (ok.has('product')) next.product = { ...cur.product };
  if (ok.has('training') && cur.training) next.training = { ...cur.training };
  // Koulutuksen hinta (kuvassa product.price) kulkee kahden askeleen kautta: tuote-askel kuittaa sen, koulutus-askel kuittaa kurssihinnan ja lisävalinnat.
  if (ok.has('config') && cur.config) next.config = { ...cur.config };
  if (ok.has('channels') && cur.channels) { next.channels = [...cur.channels].sort(); next.qrStored = cur.channels.includes('qr'); }
  for (const id of Object.keys(cur.variants || {})) if (ok.has(`variant:${id}`)) next.variants[id] = cur.variants[id];
  if (ok.has('image')) next.image = { alt: cur.image.alt, hasImage: cur.image.remove ? false : (cur.image.file ? true : base.image.hasImage), file: false, remove: false };
  if (ok.has('suggestions')) next.suggestions = cur.suggestions;
  return next;
}

/** Tekstien paikkamerkit ovat muotoa {{var:nimi}} (kuten muissa hallinnan teksteissä). */
export const fmt = (s, vars) => String(s).replace(/\{\{var:(\w+)\}\}/g, (_, k) => vars[k] ?? '');
/** Tulosviesti: kaikki ok / osa ok / mikään ei onnistunut. t(key) = productText. errText(error) = virheen teksti. */
export function saveSummary(result, t, errText = (e) => e?.message || String(e)) {
  const okLabels = result.done.length;
  const failed = result.failed.map((f) => `${f.label}: ${errText(f.error)}`).join(' · ');
  if (!result.failed.length) return { kind: 'ok', text: t('saved_all') };
  if (!okLabels) return { kind: 'err', text: fmt(t('saved_none'), { failed }) };
  return { kind: 'warn', text: fmt(t('saved_part'), { failed, count: okLabels }) };
}

/** Kuvan polku/alt-teksti -askeleelle: mitä pitää tehdä. */
export function imageAction(cur, base) {
  if (cur.remove) return 'remove';
  if (cur.file) return 'replace';
  if ((cur.alt ?? '') !== (base.alt ?? '') && base.hasImage) return 'alt';
  return 'none';
}

/** Koulutustuote avautuu vasta kun tunnus on kokonaisluku; #/tuotteet/<id>. */
export const productIdFromRest = (rest) => (/^\d+$/.test(String(rest || '')) ? Number(rest) : null);
export const productHash = (id, queryString = '') => `#/tuotteet${id != null ? `/${id}` : ''}${queryString ? `?${queryString}` : ''}`;
