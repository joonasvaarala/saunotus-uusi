// Hiljaisten aikojen ale (booking_162): puhdas, DOM-riippumaton logiikka kaupalle ja sivuston viikko-ohjelmalle.
// Palvelin päättää alennuksesta ja lukitsee hinnan (public_quiet_offers / public_create_booking*); tässä vain näyttö.
// Pohja: GPT-paketin quiet-offers-logic.js (offerKey, cache, quoteQuietChoice), sovitettu: avain aikaleimasta millisekunteina
// (PostgREST- ja jsonb-muotoilu voivat erota), ikkuna 14 pv kuten palvelimella (bad_range > 14), tyhjä vastaus kun pois päältä.
export const QUIET_WINDOW_DAYS = 14;

export const offerKey = (productId, ruleId, startsAt) => `${Number(productId)}|${Number(ruleId)}|${Date.parse(startsAt)}`;
export const roundMoney = (value) => Math.round((Number(value) + Number.EPSILON) * 100) / 100;
export const discountPrice = (base, pct) => roundMoney(Number(base) - roundMoney(Number(base) * Number(pct) / 100));
/** Alennuksen määrä samalla pyöristyksellä kuin palvelin (_quiet_apply: round(line * pct / 100, 2)). */
export const quietAmount = (total, pct) => (Number(pct) > 0 ? roundMoney(Number(total) * Number(pct) / 100) : 0);
/** Prosentti ilman turhia desimaaleja: 20 → "20", 12.5 → "12,5" (fi) / "12.5" (en). */
export const pctText = (pct, lang = 'fi') => { const s = String(+Number(pct).toFixed(2)); return lang === 'fi' ? s.replace('.', ',') : s; };
/** {nimi}-paikkamerkit (kaupan tekstit; sivuteksteistä tuleva {{var:nimi}} on jo muunnettu muotoon {nimi}). */
export const fillText = (tpl, vars = {}) => String(tpl ?? '').replace(/\{(\w+)\}/g, (m, k) => (vars[k] != null ? String(vars[k]) : m));

export const addDaysIso = (ds, n) => { const d = new Date(`${ds}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
export const quietWindow = (from, days = QUIET_WINDOW_DAYS) => (/^\d{4}-\d\d-\d\d$/.test(from || '') ? addDaysIso(from, Math.min(QUIET_WINDOW_DAYS, Math.max(0, days))) : null);

/** Kelvollinen tarjous: prosentti > 0 ja hinnat lukuja. Muut rivit ohitetaan (vanha/virheellinen vastaus ei riko näkymää). */
export const validOffer = (o) => !!o && +o.percent > 0 && Number.isFinite(+o.base_price) && Number.isFinite(+o.discounted_price) && Number.isFinite(Date.parse(o.starts_at));

export function indexOffers(offers) {
  const byKey = new Map(), byDay = new Map();
  for (const o of offers || []) {
    if (!validOffer(o)) continue;
    byKey.set(offerKey(o.product_id, o.rule_id, o.starts_at), o);
    for (const k of [`${o.session_date}`, `${o.session_date}|${Number(o.product_id)}`]) { const list = byDay.get(k) || []; list.push(o); byDay.set(k, list); }
  }
  return { byKey, byDay };
}
export const findOffer = (idx, productId, ruleId, startsAt) => idx?.byKey.get(offerKey(productId, ruleId, startsAt)) || null;
/** Päivän suurin prosentti (kaikki tuotteet tai yksi tuote); ei tarjousta → 0. */
export const dayMaxPercent = (idx, ds, productId = null) => Math.max(0, ...(idx?.byDay.get(productId == null ? ds : `${ds}|${Number(productId)}`) || []).map((o) => +o.percent));
export const productMaxPercent = (idx, productId) => Math.max(0, ...[...(idx?.byKey.values() || [])].filter((o) => +o.product_id === +productId).map((o) => +o.percent));

/**
 * Vuoron hintateksti alennettuna, sama rakenne kuin kaupan alkuperäinen (hinta / alk. hinta / sis. n hlö + lisähenkilö).
 * Ale koskee vain vuoron perushintaa (discounted_price palvelimelta); lisähenkilö on aina täyshintainen (esim. kb 26: +10 €, ei +8 €).
 */
export function quietPrices(offer) {
  const pct = +offer.percent;
  return {
    pct, was: +offer.base_price, now: +offer.discounted_price,
    extraNow: offer.extra_person_price != null && Number.isFinite(+offer.extra_person_price) ? +offer.extra_person_price : null,
  };
}

/**
 * Alennettava osa vuoron hinnasta: perushinta ilman lisähenkilöitä (fixed_plus_extra), kiinteä hinta (fixed) tai
 * henkilöhinta × henkilöt (per_person). Lisähenkilöt ja lisäpalvelut eivät alennu. s = kaupan vuoro (_sessions-rivi), n = henkilöt.
 */
export function quietBase(s, n) {
  if (!s) return 0;
  if (s.price_mode === 'per_person') return roundMoney((+s.unit_price || 0) * (+n || 0));
  const base = +s.base_price || 0;
  if (s.price_mode === 'fixed') return base;
  const total = base + Math.max(0, (+n || 0) - (+s.included_persons || 0)) * (+s.extra_person_price || 0);
  return Math.min(base, total);
}

/**
 * Kassan tila: mikä etu näytetään. quote = public_check_code-vastaus (tuore) tai null; offer = tämän vuoron tarjous tai null.
 * Palvelimen vastaus menee aina paikallisen arvion edelle: discount_source 'quiet' → hiljaisen ajan ale (koodia ei käytetä),
 * 'code' / vuosikortti → koodi. Ilman koodia: tarjous, alennus lasketaan vuoron perushinnasta (discountBase: ilman lisähenkilöitä ja
 * lisäpalveluita; lisähenkilö aina täyshintainen).
 */
export function quietCheckout({ quote = null, offer = null, sessionTotal = 0, discountBase = null } = {}) {
  if (quote) {
    if (quote.discount_source === 'quiet') {
      const pct = +(quote.quiet?.percent ?? offer?.percent ?? 0);
      const amount = +(quote.quiet?.amount ?? quote.discount ?? 0);
      return pct > 0 && amount > 0 ? { source: 'quiet', percent: pct, amount, codeNotUsed: true } : { source: 'none' };
    }
    return { source: 'code' };
  }
  if (!validOffer(offer)) return { source: 'none' };
  // ale lasketaan vain perushinnasta (discountBase, ks. quietBase); ilman sitä koko vuoron hinnasta (vanha kutsu)
  const amount = quietAmount(Math.min(+sessionTotal || 0, discountBase == null ? Infinity : +discountBase || 0), offer.percent);
  return amount > 0 ? { source: 'quiet', percent: +offer.percent, amount, codeNotUsed: false } : { source: 'none' };
}

/**
 * Välimuisti: yksi public_quiet_offers-kutsu / ikkuna. Vanhenee 60 s kuluttua tai heti kun jokin vuoro siirtyy seuraavaan portaaseen
 * (next_change_at). Virhe (esim. vanha backend ilman funktiota, PGRST202) → tyhjä lista 10 s ajan, näkymä ei muutu.
 */
export function createQuietOfferCache({ rpc, now = () => Date.now(), audience = 'consumer' }) {
  const cache = new Map();
  let requests = new Map();
  return {
    async load(from, to) {
      if (!/^\d{4}-\d\d-\d\d$/.test(from || '') || !/^\d{4}-\d\d-\d\d$/.test(to || '') || from > to || to > quietWindow(from)) return [];
      const key = `${audience}|${from}|${to}`, old = cache.get(key);
      if (old && now() < old.expires) return old.rows;
      if (requests.has(key)) return requests.get(key);
      const pending = Promise.resolve().then(() => rpc('public_quiet_offers', { p_from: from, p_to: to, p_audience: audience }))
        .then((rows) => {
          const list = (Array.isArray(rows) ? rows : []).filter(validOffer);
          const next = list.map((o) => Date.parse(o.next_change_at)).filter((x) => Number.isFinite(x) && x > now());
          cache.set(key, { rows: list, expires: Math.min(now() + 60000, ...next) });
          return list;
        }).catch(() => { cache.set(key, { rows: [], expires: now() + 10000 }); return []; })
        .finally(() => requests.delete(key));
      requests.set(key, pending);
      return pending;
    },
    clear() { cache.clear(); requests = new Map(); },
  };
}

// ---- sivuston viikko-ohjelma (etusivu + saunavuorot) ----
/** Savusaunan jälkilöylyt (kb 26). Viikko-ohjelma näyttää vain tämän tuotteen vapaat vuorot. */
export const JALKIL_ID = 26;

/**
 * Vapaat jälkilöylyt näkyville päiville (tänään + 6). Julkinen lähde on public_availability(26):
 * vain status available ja alku tulevaisuudessa. Varatut (full/unavailable), suljetut ja menneet jäävät pois.
 * Rivillä ei tarvitse olla product_id:tä (public_availability ei palauta sitä); puuttuva tulkitaan productId:ksi.
 */
export function bookablePrivateSlots(rows, { today, now, productId = JALKIL_ID } = {}) {
  if (!/^\d{4}-\d\d-\d\d$/.test(today || '') || !Number.isFinite(+now)) return [];
  const last = addDaysIso(today, 6);
  return (rows || []).filter((r) => {
    const id = r?.product_id == null ? +productId : +r.product_id;
    if (id !== +productId || r.status !== 'available') return false;
    if (!/^\d{4}-\d\d-\d\d$/.test(r.session_date || '') || r.session_date < today || r.session_date > last) return false;
    const start = Date.parse(r.starts_at);
    return Number.isFinite(start) && start > +now && Number.isFinite(+r.rule_id) && Number.isFinite(+r.base_price);
  }).map((r) => ({ ...r, product_id: r.product_id == null ? +productId : +r.product_id }))
    .sort((a, b) => Date.parse(a.starts_at) - Date.parse(b.starts_at) || +a.rule_id - +b.rule_id);
}

/** Saman vuoron hiljaisen ajan tarjous, jos palvelin sellaisen antoi. */
export function offerForSlot(offers, slot) {
  return (offers || []).find((o) => validOffer(o) && +o.product_id === +slot.product_id && +o.rule_id === +slot.rule_id && o.session_date === slot.session_date) || null;
}

export const weekdayIso = (ds) => { if (!/^\d{4}-\d\d-\d\d$/.test(ds || '')) return null; const d = new Date(`${ds}T12:00:00Z`); return Number.isNaN(+d) ? null : (d.getUTCDay() || 7); };
/** Seuraavat 7 päivää (tänään + 6) viikonpäivittäin: viikko-ohjelmassa on yksi rivi kullekin viikonpäivälle, joten sama viikonpäivä ei toistu. */
export function quietByWeekday(offers, today) {
  const out = new Map(), last = addDaysIso(today, 6);
  for (const o of [...(offers || [])].filter(validOffer).sort((a, b) => Date.parse(a.starts_at) - Date.parse(b.starts_at))) {
    if (o.session_date < today || o.session_date > last) continue;
    const d = weekdayIso(o.session_date);
    if (!d) continue;
    const list = out.get(d) || []; list.push(o); out.set(d, list);
  }
  return out;
}
