// booking_316: tuotteen myyntikanavat (monivalinta). Kanavat ovat dataa (booking.sales_channels), tuotteen valinnat
// liitostaulussa (booking.product_sales_channels). Hallinta lukee ne admin_list_sales_channels-RPC:llä ja tallentaa
// admin_set_product_sales_channels-RPC:llä. Tämä moduuli on puhdasta logiikkaa (ei DOM:ia, ei verkkoa): node --test ajaa sen suoraan.
// Siirtymän ajan kanta pitää vanhat kentät (shop_visible, channels, fridge_sale, pos_enabled) synkassa triggereillä;
// channelsFromConfig/applyChannelsToConfig ovat saman säännön peili kokeilutilaa (options-mock) ja testejä varten.

/** Kanavat, joilla on vastine vanhoissa product_config-kentissä (muut, esim. gift_shop, ovat vain liitostaulussa). */
export const MAPPED = ['shop', 'widget', 'link', 'qr', 'pos'];
const WEB = ['shop', 'widget', 'link'];
/** Kanavat, jotka vaativat varausjärjestelmän konfiguraation (product_config). */
export const NEEDS_CONFIG = MAPPED;

/** Sama kuin booking._channels_effective: null → koulutus {widget}, muut {shop}. */
export const effectiveChannels = (channels, category) => (Array.isArray(channels) ? channels : category === 'training' ? ['widget'] : ['shop']);

/** Vanhat kentät → kanavakoodit (sama sääntö kuin booking_316:n backfill ja synkkatriggeri). */
export function channelsFromConfig(category, c) {
  if (!c) return [];
  const eff = effectiveChannels(c.channels ?? null, category);
  const out = [];
  if (c.shop_visible && eff.includes('shop')) out.push('shop');
  if (eff.includes('widget')) out.push('widget');
  if (eff.includes('link')) out.push('link');
  if (c.fridge_sale) out.push('qr');
  if (c.pos_enabled) out.push('pos');
  return out;
}

/** Kanavakoodit → vanhat kentät (kuten booking._psc_to_config_trg; palauttaa uuden olion, ei muuta alkuperäistä). */
export function applyChannelsToConfig(category, c, codes) {
  if (!c) return c;
  const want = new Set(codes || []);
  const before = new Set(channelsFromConfig(category, c));
  const dflt = effectiveChannels(null, category);
  let channels = c.channels ?? null;
  let sv = !!c.shop_visible;
  for (const code of WEB) {
    const on = want.has(code);
    if (on === before.has(code)) continue;
    const eff = effectiveChannels(channels, category);
    let web = on ? [...eff, code] : eff.filter((x) => x !== code);
    web = WEB.filter((x) => web.includes(x));
    if (channels == null && web.length === dflt.length && web.every((x, i) => x === dflt[i])) web = null;
    channels = web;
    if (code === 'shop') sv = on;
  }
  return { ...c, channels, shop_visible: sv, fridge_sale: want.has('qr'), pos_enabled: want.has('pos') };
}

/** Järjestä koodit kanavalistan järjestykseen (sort_order); tuntemattomat loppuun aakkosjärjestyksessä. */
export function sortCodes(codes, channels = []) {
  const pos = new Map(channels.map((ch, i) => [ch.code, i]));
  return [...new Set(codes || [])].sort((a, b) => (pos.get(a) ?? 1e6) - (pos.get(b) ?? 1e6) || a.localeCompare(b));
}

/** Kanavan nimi käyttöliittymän kielellä (data: name / name_en). */
export const channelName = (ch, lang = 'fi') => (lang === 'en' ? ch?.name_en || ch?.name : ch?.name || ch?.name_en) || ch?.code || '';

/**
 * Miksi kanavaa ei voi valita (tekstiavain productTextille) tai null.
 * Jo valittua kanavaa ei estetä (sen voi aina poistaa); passiivista kanavaa ei voi lisätä.
 */
export function channelBlock(ch, { category, hasConfig = true, ageRestricted = false, alcohol = false, selected = false } = {}) {
  if (selected && ch.code !== 'qr') return null;
  if (!ch.active) return selected ? null : 'channels_inactive';
  if (NEEDS_CONFIG.includes(ch.code) && !hasConfig) return 'vis_why_no_config';
  if (ch.code === 'qr' && (ageRestricted || alcohol)) return 'channels_qr_blocked';
  if (ch.code === 'pos' && !selected && ['gift_card', 'season_card'].includes(category)) return 'channels_pos_blocked';
  return null;
}

/** Vertailtava muoto (järjestyksestä riippumaton). */
export const codesKey = (codes) => (codes == null ? null : [...new Set(codes)].sort().join(','));
