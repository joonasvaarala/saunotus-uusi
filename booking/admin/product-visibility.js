// HALL-TUOTTEET-02: tuotteen näkyvyys yhtenä valintana. Kolme tilaa korvaa päällekkäiset asetukset (Aktiivinen, Varattavissa, Näkyy listassa):
//   online   = "Myynnissä verkossa"           (aktiivinen + varattavissa + kaupan lista + kanava: kauppa, koulutuksella suora linkki)
//   internal = "Vain kassalla ja hallinnassa" (Joonas 15.11.2026: poistuu KAIKISTA myyntikanavista, näkyy vain kassalla ja hallinnassa)
//   hidden   = "Piilotettu"                   (ei aktiivinen: ei myynnissä missään, ei kassalla eikä tuotevalinnoissa)
//
// Myyntikanavat ja kentät, joilla ne suljetaan (palvelimen ehdot tarkistettu tuotannon funktioista 15.11.2026):
//   verkkokauppa, yrityskalenteri, saatavuus, hiljaiset tarjoukset, hoitojen verkkovaraus, lisämyynti maksussa ja tilaussivulla
//                     → product_config.shop_visible = false (public_catalog, public_catalog_for, public_availability(_all), public_quiet_offers,
//                       _treatment_slot_check, _treatment_availability_core, _upsell_options, _add_to_order, public_get_order)
//   upotus (widget), suora linkki (link), tapahtumien ja koulutusten kauppa
//                     → product_config.channels = {} (public_catalog, public_events, public_training_checkout, public_product_by_slug)
//   QR-itsepalvelumyynti (kylmälaite)  → product_config.fridge_sale = false (public_drinks_catalog)
//   lahjakorttikauppa → lahjakorttipaketit, joiden rivillä tai paketilla on tämä tuote, pois myynnistä (gift_card_packages.active = false;
//                       public_gift_card_packages ei katso tuotteen asetuksia)
//   Varattavuus (bookable) jää päälle: hallinnan ja kassan varaukset tarvitsevat sen (booking._resolve_session).
// Ei tietokantamuutosta: tallennus olemassa olevilla funktioilla admin_update_product (active), admin_update_product_config
// (shop_visible, bookable, fridge_sale), admin_event_set_channels (kanavat) ja admin_update_gift_card_package (active). Peräkkäin, ei yhtenä transaktiona.
// Puhdas logiikka (ei DOM-riippuvuutta), jotta sitä voi testata. "Toteutuuko valittu tila" selitetään koodeilla.
import { CHANNELS } from './events-logic.js';

export const MODES = ['online', 'internal', 'hidden'];
const normCh = (list) => CHANNELS.filter((c) => (list || []).includes(c));

/** Lahjakorttipaketit, joissa tuote on myytävänä (paketin oma tuote tai paketin rivi). null = paketteja ei ladattu. */
export function packagesFor(productId, packages) {
  if (!Array.isArray(packages)) return null;
  const id = Number(productId);
  return packages.filter((pk) => Number(pk?.kb_product_id) === id || (Array.isArray(pk?.items) && pk.items.some((it) => Number(it?.kb_product_id) === id)))
    .map((pk) => ({ code: pk.code, name: pk.name || pk.code, active: pk.active !== false }));
}

/** Tuotteen tosiasiat yhteen muotoon. Tuotelistan rivi (config sisäkkäin) tai tapahtumalistan rivi (kentät päällä). */
export function factsFromProduct(p, { packages } = {}) {
  const c = p?.config || null;
  return {
    hasConfig: !!c, active: p?.active !== false, category: p?.category || '',
    bookable: c?.bookable === true, shop_visible: c ? c.shop_visible !== false : false, lifecycle: c?.lifecycle || 'current',
    channels: Array.isArray(c?.channels) ? c.channels : null,
    fridge_sale: c?.fridge_sale === true, pos_enabled: c ? c.pos_enabled === true : null,
    resource_class: c?.resource_class ?? null, sale_kind: c?.sale_kind ?? null, duration_minutes: c?.duration_minutes ?? null,
    image_path: c?.image_path || null, saleClosed: false, upcoming: null,
    packages: packagesFor(p?.id, packages),
  };
}
export function factsFromEvent(e) {
  return {
    hasConfig: true, active: e?.active !== false, category: e?.category || '',
    bookable: e?.bookable === true, shop_visible: e?.shop_visible !== false, lifecycle: e?.lifecycle || 'current',
    channels: Array.isArray(e?.channels) ? e.channels : null,
    fridge_sale: e?.fridge_sale === true, pos_enabled: null,
    resource_class: null, sale_kind: null, duration_minutes: e?.duration_minutes ?? null,
    image_path: e?.image_path || null, saleClosed: e?.sale_enabled === false, upcoming: Number.isInteger(e?.upcoming) ? e.upcoming : null,
    packages: null,
  };
}

/** Tehollinen kanavalista: puuttuu → koulutus widget, muut shop (kuten palvelimella booking._channels_effective). */
export const channelsFor = (f) => (Array.isArray(f.channels) ? normCh(f.channels) : (f.category === 'training' ? ['widget'] : ['shop']));

// "Verkossa"-merkki (tuotelistan merkki ja suodatin; siirretty products.js:stä). Sama ehto kuin palvelimella, ks. products.js:n kommentti.
export const effectiveChannels = (p) => (Array.isArray(p?.config?.channels) ? p.config.channels : (p?.category === 'training' ? ['widget'] : ['shop']));
export const isOnline = (p) => {
  const c = p?.config;
  if (!c || p?.active === false || c.bookable !== true || c.lifecycle === 'old') return false;
  const ch = effectiveChannels(p);
  return (c.shop_visible !== false && ch.includes('shop')) || (p.category === 'training' && ch.includes('link'));
};

/** Valittu tila tallennetuista arvoista. */
export function modeOf(f) {
  if (f.active === false) return 'hidden';
  if (!f.hasConfig || f.bookable !== true) return 'internal';
  const ch = channelsFor(f);
  if (f.category === 'training') return ch.includes('link') || (ch.includes('shop') && f.shop_visible) ? 'online' : 'internal';
  return f.shop_visible ? 'online' : 'internal';
}

/** Missä myyntikanavissa tuote on vielä myynnissä (vain tallennetuista arvoista). Koodit: shop, widget, link, listed, fridge, gift_shop. */
export function openChannels(f) {
  if (!f.hasConfig) return [];
  const ch = channelsFor(f);
  const ev = f.category === 'event' || f.category === 'training';
  // Kauppa: tavallinen tuote vaatii myös kaupan listan (public_catalog); tapahtumien ja koulutusten listaus (public_events) katsoo vain kanavaa.
  const out = [];
  if (ch.includes('shop') && (f.shop_visible || ev)) out.push('shop');
  else if (f.shop_visible) out.push('listed');   // kaupan lista ilman kauppakanavaa: lisämyynti ja hoitojen verkkovaraus katsovat vain sitä
  out.push(...ch.filter((c) => c !== 'shop'));
  if (f.fridge_sale) out.push('fridge');
  if ((f.packages || []).some((pk) => pk.active)) out.push('gift_shop');
  return out;
}

/**
 * Selitykset: miksi tila ei toteudu (level 'block') tai mitä kannattaa huomata (level 'warn'). Tyhjä lista = tila toteutuu sellaisenaan.
 * Oletuksena tilalle `mode` olettaen, että tallennus on tehty (suunnitelma sovellettu), jotta valinnan voi tarkistaa ennen tallennusta.
 * saved = true: arvioidaan tallennettu tila sellaisenaan (esim. kanava puuttuu vaikka asetukset on päällä).
 * Kohta voi sisältää vars-arvot tekstin paikkamerkeille ({{var:names}}).
 */
export function explain(f, mode, { saved = false } = {}) {
  const pl = saved ? null : visibilityPlan(f, mode);
  const g = saved ? f : applyPlan(f, pl);
  const out = [];
  if (mode === 'online') {
    if (!f.hasConfig) out.push({ code: 'no_config', level: 'block' });
    if (g.lifecycle === 'old') out.push({ code: 'lifecycle_old', level: 'block' });
    if (saved && g.category !== 'training' && !channelsFor(g).includes('shop')) out.push({ code: 'channel_missing', level: 'block' });
    if (g.saleClosed) out.push({ code: 'sale_closed', level: 'block' });
    if (g.upcoming === 0 && (g.category === 'event' || g.category === 'training')) out.push({ code: 'no_occurrences', level: 'block' });
    if (g.resource_class && g.resource_class !== 'none' && g.sale_kind !== 'slots' && !(g.duration_minutes > 0)) out.push({ code: 'duration', level: 'block' });
    if (!g.image_path) out.push({ code: 'no_image', level: 'warn' });
    const off = (g.packages || []).filter((pk) => !pk.active);
    if (off.length) out.push({ code: 'packages_inactive', level: 'warn', vars: { names: off.map((pk) => pk.name).join(', ') } });
    return out;
  }
  // internal / hidden: ei missään myyntikanavassa
  if (saved) {
    // Piilotettu (ei aktiivinen) tuote ei näy palvelimen myyntifunktioissa; vain lahjakorttipaketit eivät katso tuotteen tilaa.
    const still = openChannels(g).filter((c) => g.active !== false || c === 'gift_shop');
    if (still.length) out.push({ code: 'still_on_sale', level: 'block', channels: still });
  } else {
    const closing = (f.packages || []).filter((pk) => pk.active && (pl.packages || []).includes(pk.code));
    if (closing.length) out.push({ code: 'packages_off', level: 'warn', vars: { names: closing.map((pk) => pk.name).join(', ') } });
    if (pl.config?.fridge_sale === false) out.push({ code: 'fridge_off', level: 'warn' });
  }
  if (mode === 'internal' && g.hasConfig && g.pos_enabled === false) out.push({ code: 'pos_off', level: 'warn' });
  return out;
}

/**
 * Tallennettavat muutokset valitulle tilalle; vain kentät, jotka eroavat nykyisestä.
 * { product, config, channels, packages } (null = ei muutosta; packages = pois myynnistä otettavien lahjakorttipakettien koodit).
 */
export function visibilityPlan(f, mode) {
  if (!MODES.includes(mode)) throw new Error(`Tuntematon näkyvyystila: ${mode}`);
  const training = f.category === 'training';
  const wantActive = mode !== 'hidden';
  const config = {};
  let channels = null, packages = null;
  const cur = channelsFor(f);
  if (f.hasConfig) {
    if (mode === 'online') {
      if (!f.bookable) config.bookable = true;
      if (!training && !f.shop_visible) config.shop_visible = true;
      const want = normCh([...cur, training ? 'link' : 'shop']);
      if (want.join() !== cur.join()) channels = want;
    } else {
      // Kaikki myyntikanavat pois (myös koulutuksen kaupan lista, koska lisämyynti katsoo vain sitä). Varattavuus jää hallinnan varauksia varten.
      if (f.shop_visible) config.shop_visible = false;
      if (f.fridge_sale) config.fridge_sale = false;
      if (cur.length) channels = [];
    }
  }
  if (mode !== 'online') {
    const on = (f.packages || []).filter((pk) => pk.active).map((pk) => pk.code);
    if (on.length) packages = on;
  }
  return { product: f.active === wantActive ? null : { active: wantActive }, config: Object.keys(config).length ? config : null, channels, packages };
}
export const planIsEmpty = (pl) => !pl.product && !pl.config && !pl.channels && !pl.packages;

/** Suunnitelma sovellettuna tosiasioihin (ennakkotarkistus ja testit). */
export function applyPlan(f, pl) {
  const g = { ...f };
  if (pl.product) g.active = pl.product.active;
  if (pl.config) Object.assign(g, pl.config);
  if (pl.channels) g.channels = pl.channels;
  if (pl.packages && g.packages) g.packages = g.packages.map((pk) => (pl.packages.includes(pk.code) ? { ...pk, active: false } : pk));
  return g;
}

/**
 * Tallennus olemassa olevilla funktioilla. Näkyväksi tekeminen viimeisenä (ei hetkeä, jolloin tuote on näkyvissä keskeneräisillä asetuksilla),
 * piilotus ensin. Virheessä heitetään virhe, jonka `step` kertoo mikä vaihe epäonnistui (product | config | channels | packages).
 */
export async function saveVisibility(rpc, productId, f, mode) {
  const pl = visibilityPlan(f, mode);
  const steps = [
    ['config', pl.config, () => rpc('admin_update_product_config', { p_product_id: productId, p_patch: pl.config })],
    ['channels', pl.channels, () => rpc('admin_event_set_channels', { p_product_id: productId, p_channels: pl.channels })],
    ['packages', pl.packages, async () => { for (const code of pl.packages) await rpc('admin_update_gift_card_package', { p_code: code, p_changes: { active: false } }); }],
  ];
  const product = ['product', pl.product, () => rpc('admin_update_product', { p_product_id: productId, p_patch: pl.product })];
  const order = mode === 'online' ? [...steps, product] : [product, ...steps];
  const done = [];
  for (const [step, need, call] of order) {
    if (!need) continue;
    try { await call(); done.push(step); } catch (e) { e.step = step; e.done = done; throw e; }
  }
  return { plan: pl, done };
}
