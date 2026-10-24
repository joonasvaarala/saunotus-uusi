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

/** Vuoron hintateksti alennettuna, sama rakenne kuin kaupan alkuperäinen (hinta / alk. hinta / sis. n hlö + lisähenkilö). */
export function quietPrices(offer) {
  const pct = +offer.percent;
  return {
    pct, was: +offer.base_price, now: +offer.discounted_price,
    extraNow: offer.extra_person_price != null ? discountPrice(offer.extra_person_price, pct) : null,
  };
}

/**
 * Kassan tila: mikä etu näytetään. quote = public_check_code-vastaus (tuore) tai null; offer = tämän vuoron tarjous tai null.
 * Palvelimen vastaus menee aina paikallisen arvion edelle: discount_source 'quiet' → hiljaisen ajan ale (koodia ei käytetä),
 * 'code' / vuosikortti → koodi. Ilman koodia: tarjous, alennus lasketaan vuoron hinnasta (ilman lisäpalveluita, kuten palvelimella).
 */
export function quietCheckout({ quote = null, offer = null, sessionTotal = 0 } = {}) {
  if (quote) {
    if (quote.discount_source === 'quiet') {
      const pct = +(quote.quiet?.percent ?? offer?.percent ?? 0);
      const amount = +(quote.quiet?.amount ?? quote.discount ?? 0);
      return pct > 0 && amount > 0 ? { source: 'quiet', percent: pct, amount, codeNotUsed: true } : { source: 'none' };
    }
    return { source: 'code' };
  }
  if (!validOffer(offer)) return { source: 'none' };
  const amount = quietAmount(sessionTotal, offer.percent);
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
