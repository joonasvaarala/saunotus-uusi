// Varauskauppa: tuote → päivä/vuoro → henkilömäärä → yhteystiedot → vahvistus. Vaihtoehtoinen selaus: päivän mukaan (#/paiva/<pvm>) → kaikki päivän vuorot. Vanilla JS, ei riippuvuuksia, ei build-vaihetta.
// Data tulee vain julkisista RPC-funktioista (public_catalog / public_product_images / public_availability / public_create_booking / public_get_booking / public_change_booking).
// Asiakas ei voi itse perua vahvistettua varausta (peruutukset sähköpostilla henkilökunnalle); hän voi MUUTTAA varausta (toinen vuoro / henkilömäärä) asetuksen mukaan vähintään 48 h ennen vuoroa.
import { rpc, storageUrl, setRpcOverride } from './sb.js';
import { ensureAllMonths } from './availability-months.js';
import { runReturn } from './mobilepay-ui.js';
import { runOnlineReturn } from './online-pay-ui.js';
import { loadPayChoices, payChoicesSection, payNotice, onlineAvailable, onlineAtCheckout } from './pay-choices.js';
import { pt } from './pay-choices-texts.js';
import { T } from './i18n.js';
import { createWaitlistView } from './waitlist-ui.js';
import { visibleWaitlistSlots, fullyBooked, hasWaitlistSlots } from './waitlist-logic.js';
import { loadProducts as loadTreatmentProducts, splitCatalog, isListed as treatmentListed, isTreatmentBooking, loadAvailability as loadTreatmentSlots, horizonDays as treatmentHorizon, timeToken as treatmentTimeToken, isRetryable as treatmentRetryable } from './treatments.js';
import { pickCatalog } from './catalog-audience.js';
import { heroShort, cardShort, fallbackDesc } from './short-desc.js';
import { createTreatmentViews } from './treatment-ui.js';
import { cardMeta } from './card-meta.js';
import { kindOf, chipsFor, DAY_KIND_ORDER } from './catalog-kind.js';
import { createTexts, loadShopTexts, applyShopTexts } from './site-texts.js';
import { checkoutUpsellSection, orderUpsellSection, confirmationUpsellOrder } from './upsell-ui.js';
import { productImageElement, CARD_WIDTHS, THUMB_WIDTHS, HERO_WIDTHS, SIZES } from './product-image.js';
import { fmtMinutes } from './site-texts-logic.js';
import { OPT } from './options-texts.js';
import { optName, needsOption, findOption } from './options-logic.js';
import { ht, holdError, methodList } from './hold-texts.js';
import { normCheckout, isHoldView, holdModeOf, giftWasUsed } from './hold-logic.js';
import { holdPanel, additionHoldSection } from './hold-ui.js';
import { normBusinessId, validBusinessId, normOvt, validOvt, validOperator } from './invoice-validate.js';
import { isRichHtml } from './rich-text.js';
import { visibleText, richHost } from './rich-view.js';
import { softenSpaces } from './text-spaces.js';
import { revealForm, revealIfHidden } from './gift-ui.js';
import { normalizeCode, quoteSignature, isAnnualQuote, isCodeError } from './discount-code-logic.js';
import { createQuietOfferCache, indexOffers, findOffer, dayMaxPercent, productMaxPercent, quietPrices, quietCheckout, quietBase, pctText, fillText, quietWindow, offerKey } from './quiet-offers-logic.js';
import { normalizeOffer, ritualPrice, ritualMax, cardQty, reconcileCard, ritualAddonArg, ritualSig, splitItems, isRitualError } from './ritual-addon-logic.js';
import { RITUAL_TEXTS, RITUAL_ERRORS } from './ritual-addon-texts.js';
import { oneKey } from './plural.js';
import { eventText, occurrenceText, occurrenceLabel, findEvent, saleState, upcoming, isMultiDay } from './event-sale.js';
import { customerInvoiceLock } from './invoice-lock.js';
import { formPaysOnline, paysByInvoice } from './company-pay.js';
import { clockFromIso } from './clock.js';
import { cardAnchor } from './card-link.js';
import { bindLangLinks, restoreDraft } from './lang-switch.js';
import { confirmPageKind } from './confirm-heading.js';
import { includedPlain, swimwearPlain, swimwearKey } from './product-layout.js';

const S = window.BOOKING_SHOP;                   // build-aikainen konfiguraatio (kieli, polut, ei-verkossa-varattavat tuotteet)
const t = T[S.lang] || T.fi;
// booking_166: rituaalitekstit varalla suoraan oletuksista → puuttuva/vanha käännös ei koskaan näytä tyhjää otsikkoa tai nimiötä
// Yksikkö: {n} = 1 → <avain>One (esim. ritualSummaryOne "1 guest"); puuttuu → monikkoavain (plural.js).
const rtx = (k, v) => { const k1 = oneKey(k, S.lang, v, t, RITUAL_TEXTS[S.lang], RITUAL_TEXTS.fi); return fillText(t[k1] || RITUAL_TEXTS[S.lang]?.[k1] || RITUAL_TEXTS.fi[k1] || t[k] || RITUAL_TEXTS[S.lang]?.[k] || RITUAL_TEXTS.fi[k] || '', v || {}); };
const TZ = 'Europe/Helsinki';
const root = document.getElementById('booking-app');

// ---- apurit ----
const h = (tag, attrs, ...kids) => {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v; else if (k === 'text') el.textContent = v; else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (v === true) el.setAttribute(k, ''); else el.setAttribute(k, v);
  }
  for (const c of kids.flat()) if (c != null && c !== false) el.append(c.nodeType ? c : document.createTextNode(c));
  return el;
};
const money = (n) => new Intl.NumberFormat(S.lang === 'fi' ? 'fi-FI' : 'en-FI', { style: 'currency', currency: 'EUR', minimumFractionDigits: Number.isInteger(+n) ? 0 : 2 }).format(+n);
const fmt = (iso, o) => new Intl.DateTimeFormat(S.lang === 'fi' ? 'fi-FI' : 'en-GB', { timeZone: TZ, ...o }).format(new Date(iso));
const hm = (iso) => clockFromIso(iso, S.lang);
const dayLong = (iso) => fmt(iso, { weekday: 'long', day: 'numeric', month: 'long' });
const ymd = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const todayHel = () => new Date().toLocaleDateString('sv-SE', { timeZone: TZ });
const pad2 = (n) => String(n).padStart(2, '0');
const cleanLabel = (l) => (l || '').replace(/\(\s*\d+(?:[.,]\d+)?\s*h\s*\)/g, '').replace(/\b(ma|ti|ke|to|pe|la|su)(–(ma|ti|ke|to|pe|la|su))?\b/g, '').replace(/\d{1,2}(:\d{2})?(–\d{1,2}(:\d{2})?)?/g, '').replace(/\s{2,}/g, ' ').trim();
const priceFor = (s, n) => (s.price_mode === 'per_person' ? s.unit_price * n : s.price_mode === 'fixed' ? s.base_price : s.base_price + Math.max(0, n - (s.included_persons || 0)) * (s.extra_person_price || 0));
// lisäpalvelun enimmäismäärä: henkilömäärä × max/hlö, enintään 99 (sama kuin booking._addon_limit)
const addonLimit = (a, n) => Math.min((a.max_per_person ?? 99) * Math.max(1, n), 99);
const aname = (a) => (S.lang === 'en' && a.name_en) || a.name;
const adesc = (a) => (S.lang === 'en' && a.description_en) || a.description;
const pname = (p) => softenSpaces((S.lang === 'en' && p.name_en) || p.name);   // &nbsp; nimessä → rivittyy (text-spaces.js)
const pdesc = (p) => (S.lang === 'en' && p.description_en) || p.description;
// kesto (booking_147): EN-kesto kb.products.duration_text_en, puuttuu → suomenkielinen duration_text (sama malli kuin pname/pdesc)
const pdur = (p) => (S.lang === 'en' && p.duration_text_en) || p.duration_text;
// vuoron nimi (booking_151): EN schedule_rules.label_en (public_availability/_all.label_en), puuttuu → suomenkielinen label
const rlabel = (r) => (S.lang === 'en' && r.label_en) || r.label;
const priceText = (p) => {
  // Näytettävä hinta lasketaan aina hinnasta (price_text voi vanhentua hintamuutoksessa).
  const v = money(p.price);
  if (p.price_type === 'per_person') return `${v} ${t.perPerson}`;
  if (p.price_type === 'from' || p.price_type === 'variable') return `${t.from} ${v}`;
  return v;
};

// ---- hiljaisten aikojen ale (booking_162) ----
// public_quiet_offers palauttaa tyhjät vuorot alennettuina (palvelin päättää ja lukitsee hinnan varauksessa; pois päältä → []).
// Näkymät merkitsevät solmut data-q*-attribuuteilla ja quietDecorate() täydentää ne, kun tarjoukset on haettu (MutationObserver:
// myös myöhemmin piirretyt kalenterit ja vuorolistat). Ei tarjouksia tai virhe → näkymä pysyy täsmälleen ennallaan.
const quietCache = createQuietOfferCache({ rpc, audience: S.audience === 'business' ? 'business' : 'consumer' });
const quietIdx = async () => { const from = todayHel(); return indexOffers(await quietCache.load(from, quietWindow(from))); };
const qPct = (pct) => fillText(t.quietBadge, { pct: pctText(pct, S.lang) });
const qBadge = (pct) => h('span', { class: 'bk-quiet-badge', 'aria-hidden': 'true', text: qPct(pct) });
const qAttrs = (ok, p, r, kind) => (ok && r.rule_id != null && r.starts_at ? { 'data-qk': offerKey(p.id, r.rule_id, r.starts_at), 'data-qkind': kind } : {});
function quietPriceNode(el, o, kind) {
  const q = quietPrices(o), m = o.price_mode;
  const sr = h('span', { class: 'sr', text: fillText(t.quietSr, { pct: pctText(q.pct, S.lang), was: money(q.was), now: money(q.now) }) });
  el.classList.add('bk-quiet');
  if (m === 'per_person') { el.append(' ', qBadge(q.pct), sr); return; }   // henkilöhinta: vain merkki (palvelin laskee summan)
  const now = m === 'fixed' ? money(q.now) : kind === 'day' ? `${t.from} ${money(q.now)}`
    : `${money(q.now)}${o.included_persons != null && q.extraNow != null ? ` (${t.included(o.included_persons)}, ${t.extra(money(q.extraNow))})` : ''}`;
  el.replaceChildren(qBadge(q.pct), ' ', h('del', { 'aria-hidden': 'true', text: money(q.was) }), ' ', h('span', { class: 'bk-quiet-now', 'aria-hidden': 'true', text: now }), sr);
}
async function quietDecorate() {
  const nodes = [...root.querySelectorAll('[data-qk]:not([data-qdone]), [data-qmark]:not([data-qdone])')];
  if (!nodes.length) return;
  const idx = await quietIdx();
  if (!idx.byKey.size) return;
  let marked = false;
  for (const el of nodes) {
    if (!el.isConnected || el.dataset.qdone) continue;
    el.dataset.qdone = '1';
    if (el.dataset.qk) { const o = idx.byKey.get(el.dataset.qk); if (o) quietPriceNode(el, o, el.dataset.qkind); continue; }
    const mark = el.dataset.qmark;
    const pct = mark === 'list' ? productMaxPercent(idx, el.dataset.qp) : dayMaxPercent(idx, el.dataset.qday, el.dataset.qp ?? null);
    if (!(pct > 0)) continue;
    const label = `${t.quietDay} ${qPct(pct)}`;
    if (mark === 'strip' || mark === 'cal') {
      el.classList.add('quiet'); marked = true;
      if (el.getAttribute('aria-label')) el.setAttribute('aria-label', `${el.getAttribute('aria-label')}, ${label}`);
      if (mark === 'strip') el.append(qBadge(pct));
    } else if (mark === 'card') el.append(qBadge(pct), h('span', { class: 'sr', text: ` ${label}` }));
    else if (mark === 'list') { el.replaceChildren(qBadge(pct), ' ', t.quietList); el.hidden = false; }
  }
  if (marked) root.querySelectorAll('[data-qlegend]').forEach((x) => { x.hidden = false; });
}
const qLegend = () => h('span', { class: 'bk-qlegend', hidden: true, 'data-qlegend': '' }, ' ', h('span', { class: 'bk-quiet-dot', 'aria-hidden': 'true' }), t.quietDay);
// ?mock=1: kokeilutila (EI palvelinta): kaikki RPC-kutsut vastataan selaimessa (shop-mock.js; ei tallenna mitään palvelimelle). Lippu säilytetään linkeissä.
const MOCK = new URLSearchParams(location.search).get('mock') === '1';
let MOCK_FETCH;   // ?mock=1&scenario=pay: mobilepay-start / mobilepay-notify -funktioiden mock (fetch-yhteensopiva)
if (MOCK) { const sm = (await import('./shop-mock.js')).createShopMock({ fail: new URLSearchParams(location.search).get('fail'), scenario: new URLSearchParams(location.search).get('scenario') || '', mpResult: new URLSearchParams(location.search).get('mpresult') || '' }); setRpcOverride(sm.rpc); MOCK_FETCH = sm.mpFetch; }
// Mock-tilan parametrit säilyvät linkeissä ja ohjauksissa (scenario=hold… toimii koko kulun läpi kassalta vahvistussivulle)
const mockQs = () => { if (!MOCK) return ''; const cur = new URLSearchParams(location.search), q = new URLSearchParams({ mock: '1' }); for (const k of ['scenario', 'mpresult', 'mpinterval', 'mpmax', 'holdsec', 'fail', 'ritual']) if (cur.has(k)) q.set(k, cur.get(k)); return `?${q}`; };
const bk = (hash) => `${S.shopHref}${mockQs()}#${hash}`;
// Kassan pitotila ja maksutavat yhdestä paikasta (vuoro- ja hoitokassa): palvelin (public_checkout_payment_options) päättää, ei kovakoodata. Virhe → vanha käytös.
const holdInfo = () => loadPayChoices({ rpc, fetchImpl: MOCK_FETCH }).then((m) => {
  const hv = holdModeOf(m.checkout, state.settings);
  const onlineOk = !!(m.opts?.online && (m.opts.online.test !== true || m.env.testUi));
  const legacyOk = !!(m.opts?.method && (m.opts.method.test !== true || m.env.testUi));
  const codes = [onlineOk ? 'online' : null, m.redeem ? 'gift_card' : null].filter(Boolean);
  return { on: hv.on, minutes: hv.minutes, legacyHold: !!hv.legacy, codes, unavailable: !!(m.checkout?.ok && !onlineOk && !legacyOk && !m.redeem), onlineSite: onlineAtCheckout(m),
    extra: (L) => [codes.length ? h('p', { class: 'bk-note', 'data-testid': 'checkout-methods', text: ht(L, 'checkout.methods', { methods: methodList(L, codes) }) }) : null,
      m.checkout?.ok && !m.checkout.method && !m.redeem ? h('p', { class: 'bk-notice', role: 'status', 'data-testid': 'checkout-unavailable', text: ht(L, 'err.online_payment_unavailable') }) : null].filter(Boolean) };
}).catch(() => { const hv = holdModeOf(null, state.settings); return { on: hv.on, minutes: hv.minutes, legacyHold: !!hv.legacy, codes: [], unavailable: false, onlineSite: false, extra: () => [] }; });
let holdCtl = null;   // käynnissä oleva pitopaneeli (laskuri/kyselyt): pysäytetään kun näkymä vaihtuu
const stopHold = () => { if (holdCtl) { holdCtl.stop(); holdCtl = null; } };

// Sivutekstit tietokannasta (§18; build → booking/site-texts.json, paikkamerkit täytetään tässä ajoajan katalogista). tx(key) → teksti tai null (kutsuja päättää varatekstin).
const texts = createTexts({ lang: S.lang, format: { price: (n) => money(n), duration: (m) => fmtMinutes(m) } });
const state = { catalog: null, settings: null, images: new Map(), treatments: [], months: new Map(), busy: false, annualOffer: null };
// tyhjät (null/false) lapset ohitetaan: replaceChildren(null) kirjoittaisi sivulle tekstin "null" (esim. tuotesivu ilman hoitovalitsinta)
const mount = (...nodes) => { root.replaceChildren(...nodes.flat().filter((n) => n != null && n !== false)); root.setAttribute('aria-busy', 'false'); };
const focusTop = () => { const el = [...root.querySelectorAll('h2,h1')].find((n) => !n.closest('.bk-rich')) || document.querySelector('main .hero.page h1'); if (el) { el.setAttribute('tabindex', '-1'); el.focus({ preventScroll: false }); } };
const spinner = () => mount(h('p', { class: 'bk-loading', role: 'status', text: t.loading }));
const errorBox = (msg) => h('p', { class: 'bk-error', role: 'alert', text: msg });
const phoneBox = () => h('p', { class: 'bk-contact' }, h('a', { href: `tel:${S.phoneTel}`, text: S.phone }), ' · ', h('a', { href: `mailto:${S.email}`, text: S.email }));

// Hoito- ja rituaalituotteet (adapteri treatments.js): public_catalog()-rivit joilla booking_kind = 'slots'. Rivi täydennetään build-aikaisella kb-datalla (static-products.json).
// Piilotetut tuotteet eivät ole katalogissa → ne näytetään "ota yhteyttä" -sivuna (viewProduct). Vahvistussivu hakee katalogin itse (ensureTreatments).
let staticById = null;
async function loadStatic() {
  staticById ||= fetch(S.staticProductsUrl).then((r) => r.json()).catch(() => ({})).then((st) => new Map(Object.entries(st).map(([slug, o]) => [o.id, { ...o, slug }])));
  return staticById;
}
let treatmentsReady = null;
function ensureTreatments() {
  treatmentsReady ||= (async () => { state.treatments = await loadTreatmentProducts(await loadStatic()).catch(() => []); })();
  return treatmentsReady;
}
async function loadBase() {
  if (state.catalog) return;
  // Tuotekuvat: public_product_images voi puuttua (migraatio 14 ajamatta) tai epäonnistua → kauppa toimii ilman kuvia
  // Yritysten kalenteri (BOOKING_SHOP.audience = business) käyttää public_catalog_for; vanha kanta → public_catalog + pickCatalog.
  const audience = S.audience === 'business' ? 'business' : 'consumer';
  const catalogPromise = rpc('public_catalog_for', { p_audience: audience }).catch(() => rpc('public_catalog'));
  const [catalogRaw, settings, imgs, stat, siteTexts] = await Promise.all([catalogPromise, rpc('public_settings'), rpc('public_product_images').catch(() => []), loadStatic(), loadShopTexts(S.siteTextsUrl)]);
  const catalog = pickCatalog(catalogRaw, audience);
  texts.setRows(siteTexts); texts.setData({ catalog, settings: settings || {} });
  await applyShopTexts(S, { rows: siteTexts, data: { catalog, settings: settings || {}, format: { price: (n) => money(n), duration: (m) => fmtMinutes(m) } } });   // osa 3: sanakirjat DB-tekstein (puuttuva avain → repon oletus)
  const split = splitCatalog(catalog, stat);   // vuoropohjaiset tuotteet (rules) ja hoito-/rituaalituotteet (slots) erikseen
  state.catalog = split.rules; state.treatments = audience === 'business' ? [] : split.treatments; treatmentsReady = Promise.resolve(); state.settings = settings || {};
  // ?mock=1&rich=1 ja window.BOOKING_RICH_SAMPLE: paikallinen kuvakaappaus. Ei tallenna, ei koske muita tuotteita.
  const richDemo = MOCK && new URLSearchParams(location.search).get('rich') === '1' && typeof window.BOOKING_RICH_SAMPLE === 'string' ? window.BOOKING_RICH_SAMPLE : '';
  if (richDemo) { const sample = [...state.catalog, ...state.treatments][0]; if (sample) { sample.description = richDemo; sample.description_en = richDemo; } }
  for (const i of Array.isArray(imgs) ? imgs : []) if (i?.path) state.images.set(+i.product_id, { url: storageUrl('product-images', i.path), alt: i.alt || '' });
}
// Tuotekuva: kiinteä kuvasuhde (varaa tilan → ei layout-hyppyä), lazy-lataus alle taitteen, alt = ylläpidon alt-teksti tai tuotteen nimi.
// alt=false → koriste (nimi on jo vieressä tekstinä). Rikkinäinen kuva poistetaan kokonaan (ei rikkinäistä kuvaketta).
// Kortti ~350 px: srcset 600/900. Pikkukuva 72–88 px: 320 px. Supabase-muunnos tai alkuperäinen (product-image.js).
// Palauttaa null jos tuotteella ei ole kuvaa.
const IMG_PRESET = { 'card-img': { widths: CARD_WIDTHS, sizes: SIZES.shop }, 'pc-img': { widths: THUMB_WIDTHS, sizes: SIZES.thumb }, 'pick-img': { widths: THUMB_WIDTHS, sizes: SIZES.thumb } };
const pimg = (p, cls, { alt = true, eager = false, w = 600, hgt = 400 } = {}) => {
  const i = state.images.get(p.id); if (!i) return null;
  const node = productImageElement(h, i.url, { ...(IMG_PRESET[cls] || IMG_PRESET['card-img']), alt: alt ? (i.alt || pname(p)) : '', width: w, height: hgt, lazy: !eager });
  const im = node.querySelector('img');
  const box = h('span', { class: `bk-img ${cls}` }, node);
  im.addEventListener('error', () => box.remove(), { once: true });
  return box;
};
async function loadMonth(productId, year, month) {   // month: 0–11
  const key = `${productId}:${year}-${month}`;
  if (state.months.has(key)) return state.months.get(key);
  const from = new Date(year, month, 1), to = new Date(year, month + 1, 0);
  const rows = await rpc('public_availability', { p_product_id: productId, p_from: ymd(from), p_to: ymd(to) });
  const byDay = {};
  for (const r of rows || []) (byDay[r.session_date] ||= []).push(r);
  for (const k in byDay) byDay[k].sort((a, b) => a.starts_at.localeCompare(b.starts_at));
  state.months.set(key, byDay);
  return byDay;
}
const dayState = (rows) => (!rows?.length ? 'none' : rows.some((r) => r.status === 'available') ? 'free' : rows.some((r) => r.status === 'full') ? 'full' : 'unavail');

// ---- sivun yläbanneri (hero): tuotesivulla ja varauslomakkeella tuotteen kuva taustana + otsikko = tuotteen nimi + tiivis kuvaus ----
// Sivun oma hero (<section class="hero page">) on build-aikaista HTML:ää: oletus palautetaan kaikissa muissa näkymissä. Ei erillistä hero-kenttää: sama tuotekuva (object-fit: cover, keskitetty).
// Lyhyt kuvaus (booking_156): tuotteen oma short_description(_en) korvaa johdetun otteen; tyhjä → ensimmäinen virke kuvauksesta (heroShort, short-desc.js). Pitkä kuvaus pysyy sisältöosassa.
const hero = { def: null };
function setHero(p) {
  const el = document.querySelector('main .hero.page'); document.documentElement.classList.remove('bk-hero-wait');
  if (!el) return;
  const h1 = el.querySelector('h1'), sub = el.querySelector('.in p'), cur = el.querySelector('picture');
  if (!hero.def) hero.def = { h1: h1.textContent, sub: sub?.textContent || '', pic: cur };
  const i = p && state.images.get(p.id);
  let next = hero.def.pic;
  if (i) {
    next = productImageElement(h, i.url, { widths: HERO_WIDTHS, sizes: SIZES.hero, alt: i.alt || '', width: 1600, height: 1000, lazy: false, pictureClass: 'prod-pic' });
    const im = next.querySelector('img');
    im.addEventListener('error', () => { if (next.isConnected) { next.replaceWith(hero.def.pic); el.classList.remove('has-prod'); } }, { once: true });
  }
  if (cur !== next) cur.replaceWith(next);
  el.classList.toggle('has-prod', !!i);
  h1.textContent = p ? pname(p) : hero.def.h1;
  el.querySelector('.bk-hero-short')?.remove();
  if (sub) {
    const hs = p ? heroShort(h, p, S.lang, pdesc(p)) : { node: null, text: hero.def.sub };
    sub.textContent = hs.text; sub.hidden = !sub.textContent;
    if (hs.node) sub.after(hs.node);   // rikas lyhyt kuvaus: puhdistettu <div class="bk-hero-short bk-rich"> (ei <p>:n sisään)
  }
}

// Kortin kuvaus (booking_156): lyhyt kuvaus puhdistettuna, tyhjä → johdettu ote 170 merkkiä (short-desc.js).
const cardExcerpt = (p) => cardShort(h, p, S.lang, pdesc(p));
// ---- näkymä 1: tuotelista ----
function viewList(query) {
  const cat = [...state.catalog, ...state.treatments.filter(treatmentListed)];   // lisätuotteet (LISTING_HIDDEN_SLUGS) eivät näy listalla; tuotesivu toimii
  const kinds = chipsFor(cat);   // tyhjä kategoria ei saa chippiä; tapahtuma omassa chipissä (catalog-kind.js)
  const k = kinds.includes(query.get('k')) ? query.get('k') : 'all';
  const list = cat.filter((p) => k === 'all' || kindOf(p) === k);
  const tabs = h('nav', { class: 'bk-tabs', 'aria-label': t.title }, kinds.map((x) => h('a', { href: bk(`/?k=${x}`), 'aria-current': x === k ? 'true' : null, text: t['k_' + x] || t[x] || x })));
  const cards = h('ul', { class: 'bk-cards' }, list.map((p) => p.treatment ? tv.card(p) : h('li', { class: 'bk-card' },
    cardAnchor(h, bk(`/tuote/${p.slug}`),
      pimg(p, 'card-img'),
      h('h3', { text: pname(p) }),
      cardExcerpt(p),
      cardMeta(h, priceText(p), pdur(p)),   // ajankohta omalla rivillään hinnan yläpuolella (card-meta.js)
      h('p', { class: 'bk-quiet-line', hidden: true, 'data-qp': p.id, 'data-qmark': 'list' }),   // booking_162: täyttyy vain, jos tuotteella on hiljaisen ajan ale
      h('span', { class: 'btn sm' }, t.choose, h('span', { class: 'sr', text: ' – ' + pname(p) }))))));
  const annual = annualPromo();
  // Sivun hero toistaa saman otsikon ja ingressin. Listalla jätetään yksi.
  mount(modeSwitch('cat'), tabs, cards, annual);
}

// Vuosikortti (booking_142): myynti näkyy vain, kun palvelin sanoo available (asetus annual_card_sale_enabled, oletus pois);
// hinta tulee tuotteesta (kb.products), ei koodista. Virhe tai vanha backend ilman RPC:tä → ei mitään.
const annualOffer = () => (state.annualOffer ||= rpc('public_annual_card_offer').catch(() => null));
function annualPromo() {
  if (S.audience === 'business') return null;
  const host = h('div', { class: 'bk-annual-host' });
  annualOffer().then((o) => {
    if (!o?.available || !host.isConnected) return;
    host.replaceChildren(h('section', { class: 'bk-annual', 'aria-labelledby': 'bk-annual-h', 'data-testid': 'annual-promo' },
      h('div', { class: 'bk-annual-main' }, h('h3', { id: 'bk-annual-h', text: t.annualTitle }), h('p', { text: t.annualLead }),
        h('p', { class: 'bk-meta' }, `${t.annualPrice} `, h('strong', { text: money(o.price) }), ` ${t.vatIncl}`)),
      h('a', { class: 'btn sm', href: bk('/vuosikortti'), text: t.annualBuy })));
  });
  return host;
}
async function viewAnnualPurchase() {
  const o = await annualOffer();
  const back = h('p', {}, h('a', { href: bk('/'), text: t.annualBack }));
  if (!o?.available) { mount(back, h('h2', { text: t.annualBuyTitle }), h('div', { class: 'bk-notice' }, h('p', { text: t.annualUnavailable }), phoneBox())); focusTop(); return; }
  const msg = h('div', { id: 'bk-msg' });
  const fld = (name, label, type, auto) => h('div', { class: 'bk-field' }, h('label', { for: `bk-ac-${name}`, text: `${label} *` }), h('input', { id: `bk-ac-${name}`, name, type, autocomplete: auto, required: true, maxlength: name === 'name' ? 120 : 160 }));
  const legal = legalFields();
  const submit = h('button', { type: 'submit', class: 'btn gold', 'data-testid': 'annual-submit', text: t.annualBuySubmit });
  const form = h('form', { class: 'bk-form', novalidate: true, onsubmit: async (ev) => {
    ev.preventDefault(); msg.replaceChildren();
    const f = new FormData(form), val = (k) => String(f.get(k) || '').trim();
    const need = ['name', 'email', 'phone'].filter((k) => !val(k));
    if (need.length || !form.email.checkValidity()) { msg.append(errorBox(t.required)); form[need[0] || 'email'].focus(); return; }
    if (!legal.terms.checked) { msg.append(errorBox(t.acceptTermsErr)); legal.terms.focus(); return; }
    submit.disabled = true; submit.textContent = t.annualBuying;
    try {
      const r = await rpc('public_buy_annual_card', { p_name: val('name'), p_email: val('email'), p_phone: val('phone'), p_marketing_consent: legal.consent.checked, p_locale: S.lang });
      if (!r?.ok) throw Object.assign(new Error((r?.code === 'sale_disabled' ? t.annualUnavailable : t.codeErrors[r?.code] || t.errors[r?.code]) || t.errorGeneric), { mapped: true });
      const orderHref = S.orderHref?.[S.lang] || (S.lang === 'en' ? '/en/order/' : '/tilaus/');
      location.assign(`${orderHref}?t=${encodeURIComponent(r.token)}${MOCK ? '&mock=1&scenario=annual' : ''}`);
    } catch (e) {
      submit.disabled = false; submit.textContent = t.annualBuySubmit;
      msg.replaceChildren(errorBox(e.mapped ? e.message : t.errorGeneric)); revealIfHidden(msg);
    }
  } },
    fld('name', t.name, 'text', 'name'), fld('email', t.email, 'email', 'email'), fld('phone', t.phone, 'tel', 'tel'),
    legal.nodes.slice(1), msg, submit);
  mount(back, h('h2', { text: t.annualBuyTitle }), h('p', { class: 'lead', text: t.annualBuyLead }),
    h('div', { class: 'bk-checkout' }, form,
      h('aside', { class: 'bk-aside', 'aria-label': t.summary }, h('h3', { text: t.summary }),
        h('dl', { class: 'bk-sum' }, h('dt', { text: t.what }), h('dd', { text: S.lang === 'en' && o.name_en ? o.name_en : o.name })),
        h('p', { class: 'bk-totalrow' }, t.total + ': ', h('strong', { class: 'bk-total', text: money(o.price) }), ' ', h('small', { text: t.vatIncl })))));
  focusTop();
}

// ---- näkymä 1b: selaa päivän mukaan (#/paiva/<YYYY-MM-DD>) ----
// Tiedot: public_availability(tuote, kk:n 1.–viim.) kutsutaan kaikille tuotteille rinnakkain (1 kutsu / tuote / kuukausi) ja tulokset välimuistitetaan
// (sama välimuisti kuin tuotenäkymässä). Viikkoliuska, päivän vuorot ja "seuraava vapaa päivä" luetaan välimuistista → päivän vaihto samassa kuukaudessa ei kutsu palvelinta.
const addDays = (ds, n) => { const d = new Date(`${ds}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const dowMon = (ds) => (new Date(`${ds}T12:00:00Z`).getUTCDay() + 6) % 7;                 // ma = 0
const monthOf = (ds) => { const [y, m] = ds.split('-').map(Number); return [y, m - 1]; };
function modeSwitch(active, ds) {
  return h('nav', { class: 'bk-modes', 'aria-label': t.modeLabel },
    h('a', { href: bk('/'), 'aria-current': active === 'cat' ? 'page' : null, text: t.modeCat }),
    h('a', { href: bk(`/paiva/${ds || state.lastDay || todayHel()}`), 'aria-current': active === 'day' ? 'page' : null, text: t.modeDay }));
}
async function ensureMonths(pairs) { // yksi public_availability_all-kutsu / kuukausi, kaikille tuotteille
  return ensureAllMonths({ pairs, catalog: state.catalog, months: state.months, rpc,
    fallback: loadMonth, audience: S.audience === 'business' ? 'business' : 'consumer' });
}
const dayRows = (ds) => {
  const [y, m] = monthOf(ds);
  return state.catalog.flatMap((p) => (state.months.get(`${p.id}:${y}-${m}`)?.[ds] || []).map((r) => ({ r, p })))
    .sort((a, b) => a.r.starts_at.localeCompare(b.r.starts_at) || state.catalog.indexOf(a.p) - state.catalog.indexOf(b.p));
};
const freeCount = (ds) => dayRows(ds).filter((x) => x.r.status === 'available').length;
async function findNextFree(ds, maxDs) {   // seuraava päivä, jolla on vapaita vuoroja (enintään 3 seuraavaa kuukautta, korkeintaan varausikkunan loppuun)
  let [y, m] = monthOf(ds);
  for (let i = 0; i < 4; i++) {
    await ensureMonths([[y, m]]).catch(() => {});
    const days = new Date(y, m + 1, 0).getDate();
    for (let d = 1; d <= days; d++) {
      const x = `${y}-${pad2(m + 1)}-${pad2(d)}`;
      if (x > ds && x <= maxDs && freeCount(x) > 0) return x;
    }
    if (`${y}-${pad2(m + 1)}-31` >= maxDs) break;
    m++; if (m > 11) { m = 0; y++; }
  }
  return null;
}
function dayItem({ r, p }, ds, withName = false) {
  const ok = r.status === 'available';
  const title = `${hm(r.starts_at)}–${hm(r.ends_at)}`;
  const cl = cleanLabel(rlabel(r)), sub = cl && !pname(p).toLowerCase().includes(cl.toLowerCase()) ? cl : '';   // ei toisteta tuotteen nimeä
  const price = r.price_mode === 'per_person' ? `${money(r.unit_price)} ${t.perPerson}` : r.price_mode === 'fixed' ? money(r.base_price) : `${t.from} ${money(r.base_price)}`;
  return h('li', { class: `bk-slot ${r.status}` },
    h('div', { class: 'bk-slot-main' }, h('strong', { class: 'bk-time', text: title }),
      withName ? h('span', { class: 'bk-prodname' }, h('a', { href: bk(`/tuote/${p.slug}/${ds}`), text: pname(p) })) : null, sub ? h('span', { class: 'bk-sub', text: sub }) : null, h('span', { class: 'bk-price', text: price, ...qAttrs(ok, p, r, 'day') })),
    h('div', { class: 'bk-slot-side' },
      ok ? h('span', { class: 'bk-badge free', text: t.freeSpots(r.remaining) }) : h('span', { class: 'bk-badge full', text: t.waitlistSessionSoldOut }),
      ok ? h('a', { class: 'btn sm', href: bk(`/varaa/${r.rule_id}/${ds}/${p.id}?via=day`) }, t.choose, h('span', { class: 'sr', text: ` ${title}, ${pname(p)}` })) : h('a', { class: 'btn sm light bk-waitlist-link', href: bk(`/jono/${r.rule_id}/${ds}/${p.id}?via=day`), text: t.waitlistJoinShort })));
}
// hoito-/rituaaliajan rivi päivänäkymässä: valinta vie hoitovarausvirtaan (tuotesivu) esivalitulla päivällä ja ajalla (henkilömäärä 1, vaihdettavissa)
function treatItem({ r, p }, ds) {
  const title = r.ends_at ? `${hm(r.starts_at)}–${hm(r.ends_at)}` : hm(r.starts_at);
  return h('li', { class: 'bk-slot available' },
    h('div', { class: 'bk-slot-main' }, h('strong', { class: 'bk-time', text: title }), h('span', { class: 'bk-price', text: priceText(p) })),
    h('div', { class: 'bk-slot-side' }, h('a', { class: 'btn sm', href: bk(`/tuote/${p.slug}?n=1&d=${ds}&t=${treatmentTimeToken(r.time)}`) }, t.choose, h('span', { class: 'sr', text: ` ${title}, ${pname(p)}` }))));
}
// Hoidot päivänäkymässä: vain tuotteet joilla on vapaita aikoja valittuna päivänä (public_treatment_availability, 1 hlö; yksi haku / tuote valitun päivän 14 pv ikkunalle,
// enintään kaksi hakua kerrallaan, ei pollausta). Kortit lisätään sitä mukaa kun haku valmistuu, mutta aina tuotejärjestyksessä; ajat näytetään vasta kun kortti avataan.
let treatDayToken = 0;
async function fillTreatments(box, results, ds, today, tmax, openSlug, onToggle, rulesFree) {
  const token = ++treatDayToken, list = box.querySelector('ul'), status = box.querySelector('.bk-treat-status');
  let shown = 0, failed = null;
  // Valitun päivän 14 pv ikkuna, ei koko 120 pv varausjaksoa joka tuotteelle.
  const from = ds < today ? today : ds;
  const end = addDays(ds, 13);
  const until = end < tmax ? end : tmax;
  await Promise.all(state.treatments.filter(treatmentListed).map(async (p, ord) => {
    let by;
    try { by = await loadTreatmentSlots(p, 1, from, until); } catch (e) { failed = failed || e; return; }
    if (token !== treatDayToken || !box.isConnected) return;
    const slots = by.get(ds) || [];
    if (!slots.length) return;
    const rs = slots.map((s) => ({ r: { status: 'available', starts_at: s.start, ends_at: s.end, time: s.time }, p }));
    const li = prodCard(p, rs, ds, p.slug === openSlug, onToggle, true);
    li.dataset.ord = String(ord);   // rinnakkaiset haut valmistuvat satunnaisessa järjestyksessä → kortti oikealle paikalleen
    list.insertBefore(li, [...list.children].find((x) => +x.dataset.ord > ord) || null); shown++;
    if (!rulesFree) results.querySelector('.bk-notice')?.remove();
    if (p.slug === openSlug) li.scrollIntoView({ block: 'nearest' });
  }));
  if (token !== treatDayToken || !box.isConnected) return;
  status.remove();
  if (!shown && !failed) box.remove();
  else if (!shown) box.append(errorBox(treatmentRetryable(failed?.code) ? t.tr.errors.busy : t.loadError), h('p', {}, h('button', { type: 'button', class: 'btn sm light', text: t.tr.retry, onclick: () => route(true) })));
}
// tuotekortti (accordion): otsikkopainike → vain saatavilla olevat tuotteet; ajat näytetään vasta kun kortti avataan (yksi auki kerrallaan, tila URL:ssa ?tuote=<slug>)
function prodCard(p, rs, ds, open, onToggle, treat = false) {
  const avail = rs.filter((x) => x.r.status === 'available'), fullOnly = !treat && fullyBooked(rs), id = `bk-pc-${p.id}`;
  const rawDesc = pdesc(p) || '', desc = (isRichHtml(rawDesc) ? visibleText(rawDesc) : rawDesc).replace(/\s+/g, ' ').trim(), short = desc.length > 90 ? `${desc.slice(0, 90).replace(/\s+\S*$/, '')}…` : desc;
  const panel = h('div', { id: `${id}-panel`, class: 'bk-pc-panel', role: 'region', 'aria-labelledby': `${id}-btn`, hidden: open ? null : true },
    treat && tv.timelineText(p) ? h('p', { class: 'bk-note bk-pc-tl', text: tv.timelineText(p) }) : null,
    h('ul', { class: 'bk-slotlist' }, (treat ? rs : visibleWaitlistSlots(rs)).map((x) => (treat ? treatItem(x, ds) : dayItem(x, ds)))),
    h('p', { class: 'bk-pc-more' }, h('a', { href: treat ? bk(`/tuote/${p.slug}?n=1&d=${ds}`) : bk(`/tuote/${p.slug}/${ds}`), text: t.productInfo })));
  const btn = h('button', { type: 'button', id: `${id}-btn`, class: 'bk-pc-head', 'aria-expanded': open ? 'true' : 'false', 'aria-controls': `${id}-panel`, onclick: () => onToggle(p, li) },
    pimg(p, 'pc-img', { alt: false, w: 160, hgt: 160 }),
    h('span', { class: 'bk-pc-main' }, h('strong', { class: 'bk-pc-name', text: pname(p) }), short ? h('span', { class: 'bk-pc-desc', text: short }) : null,
      h('span', { class: 'bk-pc-meta', ...(treat || !avail.length ? {} : { 'data-qp': p.id, 'data-qday': ds, 'data-qmark': 'card' }) }, h('span', { class: 'bk-price', text: priceText(p) }), fullOnly ? h('span', { class: 'bk-badge full', text: t.waitlistSoldOut }) : h('span', { class: 'bk-badge free', text: `${t.timesFree(avail.length)}${avail.length ? ` · ${t.firstAt} ${hm(avail[0].r.starts_at)}` : ''}` }))),
    h('span', { class: 'bk-pc-chev', 'aria-hidden': 'true' }));
  const li = h('li', { class: `bk-pc${fullOnly ? ' full' : ''}${open ? ' open' : ''}`, 'data-slug': p.slug }, btn, panel);
  return li;
}
async function viewDay(dateStr, keep, openSlug) {
  const today = todayHel(), horizon = state.settings.booking_horizon_days || 120, maxDs = addDays(today, horizon);
  let ds = /^\d{4}-\d\d-\d\d$/.test(dateStr || '') ? dateStr : today;
  if (Number.isNaN(Date.parse(`${ds}T12:00:00Z`))) ds = today;
  ds = ds < today ? today : ds > maxDs ? maxDs : ds;
  state.lastDay = ds;
  const ws = addDays(ds, -dowMon(ds)), we = addDays(ws, 6);
  const pairs = [...new Map([monthOf(ds), monthOf(ws), monthOf(we)].map((x) => [x.join('-'), x])).values()];
  await ensureMonths(pairs);
  const rows = dayRows(ds), free = rows.filter((x) => x.r.status === 'available');
  const go = (x) => { location.hash = `#/paiva/${x}`; };
  const longDate = dayLong(`${ds}T12:00:00Z`);
  const weekLabel = `${fmt(`${ws}T12:00:00Z`, { day: 'numeric', month: 'numeric' })}–${fmt(`${we}T12:00:00Z`, { day: 'numeric', month: 'numeric', year: 'numeric' })}`;
  const strip = h('ol', { class: 'bk-strip' }, Array.from({ length: 7 }, (_, i) => {
    const x = addDays(ws, i), inRange = x >= today && x <= maxDs;
    const rs = inRange ? dayRows(x) : [], n = rs.filter((q) => q.r.status === 'available').length;
    const st = !inRange ? 'off' : n ? 'free' : rs.some((q) => q.r.status === 'full') ? 'full' : rs.length ? 'unavail' : 'none';
    const long = dayLong(`${x}T12:00:00Z`);
    const label = st === 'free' ? `${long}, ${t.daySessions(n)}` : st === 'full' ? `${long}, ${t.full}` : st === 'unavail' ? `${long}, ${t.unavailable}` : st === 'none' ? `${long}, ${t.noSessions}` : long;
    const inner = [h('span', { class: 'bk-sd-wd', 'aria-hidden': 'true', text: fmt(`${x}T12:00:00Z`, { weekday: 'short' }) }), h('span', { class: 'bk-sd-n', 'aria-hidden': 'true', text: String(+x.slice(8)) }), h('span', { class: `dot ${st}`, 'aria-hidden': 'true' })];
    return h('li', {}, !inRange ? h('span', { class: 'bk-sd off', 'aria-label': long }, inner)
      : h('a', { class: `bk-sd ${st}${x === today ? ' today' : ''}${x === ds ? ' sel' : ''}`, href: bk(`/paiva/${x}`), 'aria-label': label, 'aria-current': x === ds ? 'date' : null, ...(st === 'free' ? { 'data-qday': x, 'data-qmark': 'strip' } : {}) }, inner));
  }));
  const picker = h('input', { type: 'date', id: 'bk-day-pick', value: ds, min: today, max: maxDs, onchange: (e) => { if (e.target.value) go(e.target.value); } });
  const prevOk = addDays(ws, -1) >= today, nextOk = addDays(we, 1) <= maxDs;
  const wkBtn = (ok, target, label, ch) => (ok ? h('a', { class: 'bk-navbtn', href: bk(`/paiva/${target}`), 'aria-label': label, text: ch }) : h('span', { class: 'bk-navbtn off', 'aria-hidden': 'true', text: ch }));
  const nav = h('div', { class: 'bk-weeknav' },
    wkBtn(prevOk, addDays(ds, -7) < today ? today : addDays(ds, -7), t.prevWeek, '‹'),
    h('strong', { 'aria-live': 'polite', text: weekLabel }),
    wkBtn(nextOk, addDays(ds, 7) > maxDs ? maxDs : addDays(ds, 7), t.nextWeek, '›'));
  const tools = h('div', { class: 'bk-daytools' },
    h('a', { class: 'btn sm bk-today', href: bk(`/paiva/${today}`), text: t.today }),
    h('label', { for: 'bk-day-pick', text: t.pickDay }), picker);
  let results;
  const toggle = (p, li) => {
    const wasOpen = li.classList.contains('open');
    for (const el of results.querySelectorAll('.bk-pc')) { el.classList.remove('open'); el.querySelector('.bk-pc-head').setAttribute('aria-expanded', 'false'); el.querySelector('.bk-pc-panel').hidden = true; }
    if (!wasOpen) { li.classList.add('open'); li.querySelector('.bk-pc-head').setAttribute('aria-expanded', 'true'); li.querySelector('.bk-pc-panel').hidden = false; revealForm(li, li.querySelector('.bk-pc-head')); }
    history.replaceState(null, '', bk(`/paiva/${ds}${wasOpen ? '' : `?tuote=${p.slug}`}`)); last = location.hash;   // tila URL:ssa, ei uudelleenpiirtoa
  };
  const heading = h('h3', { id: 'bk-day-h', text: `${t.slotsFor} – ${longDate}`, tabindex: '-1' });
  let notice = null;
  if (!free.length) {
    const nextDs = await findNextFree(ds, maxDs);
    notice = h('div', { class: 'bk-notice', role: 'status' }, h('p', { text: t.noSlotsDay }),
      nextDs ? h('p', {}, t.nextFree + ' ', h('a', { class: 'btn sm', href: bk(`/paiva/${nextDs}`), text: dayLong(`${nextDs}T12:00:00Z`) })) : h('p', { text: t.noNextFree }));
  }
  // Näytetään myös kokonaan loppuunmyydyt tuotteet; "unavailable" on aina piilossa.
  const prods = state.catalog.map((p) => [p, rows.filter((x) => x.p.id === p.id)])
    .filter(([, rs]) => hasWaitlistSlots(rs))
    .sort((a, b) => Number(fullyBooked(a[1])) - Number(fullyBooked(b[1])));
  const bySlug = new Map(prods.map(([p]) => [p.slug, p]));
  const openId = prods.length === 1 ? prods[0][0].id : bySlug.get(openSlug)?.id ?? null;
  // järjestys: yksityisvuorot → yleiset vuorot → tapahtumat → muut; hoidot ja rituaalit (treatBox) aina viimeisenä
  const groups = DAY_KIND_ORDER.map((k) => [k, prods.filter(([p]) => kindOf(p) === k)])
    .filter(([, g]) => g.length);
  results = h('div', { class: 'bk-dayresults', 'data-date': ds }, heading, notice,
    prods.length ? h('p', { class: 'bk-note bk-pickhint', text: t.pickProduct }) : null,
    groups.flatMap(([k, g]) => [h('h4', { class: 'bk-kindh', text: t['k_' + k] }),
      h('ul', { class: 'bk-prods' }, g.map(([p, rs]) => prodCard(p, rs, ds, p.id === openId, toggle)))]));
  const tmax = addDays(today, treatmentHorizon(state.settings)) < maxDs ? addDays(today, treatmentHorizon(state.settings)) : maxDs;
  const treatBox = state.treatments.some(treatmentListed) && ds <= tmax ? h('section', { class: 'bk-treat-day', 'aria-label': t.k_hoito }, h('h4', { class: 'bk-kindh', text: t.k_hoito }), h('p', { class: 'bk-loading bk-treat-status', role: 'status', text: t.loading }), h('ul', { class: 'bk-prods' })) : null;
  if (treatBox) results.append(treatBox);
  mount(h('header', { class: 'bk-head' }, h('h2', { text: t.dayTitle }), h('p', { class: 'lead', text: t.dayLead })), modeSwitch('day', ds),
    h('section', { class: 'bk-daypick', 'aria-label': t.pickDay }, nav, strip,
      h('p', { class: 'bk-legend' }, h('span', { class: 'dot free' }), t.free, ' ', h('span', { class: 'dot full' }), t.full, ' ', h('span', { class: 'dot unavail' }), t.unavailable, qLegend()), tools),
    h('div', { class: 'bk-slots', 'aria-live': 'polite' }, results));
  if (keep) { const el = document.getElementById('bk-day-h'); if (el) { revealIfHidden(el); el.focus({ preventScroll: true }); } } else focusTop();
  if (!keep && openSlug) document.querySelector('.bk-pc.open')?.scrollIntoView({ block: 'start' });   // Takaisin lomakkeelta → sama tuote auki ja näkyvissä
  if (treatBox) fillTreatments(treatBox, results, ds, today, tmax, openSlug, toggle, free.length > 0);
}

// ---- näkymä 2: tuote → kalenteri → vuorot ----
async function viewProduct(slug, dateStr, query) {
  const tp = !state.catalog.some((x) => x.slug === slug) && state.treatments.find((x) => x.slug === slug);
  if (tp) return tv.viewTreatment(tp, query || new URLSearchParams());   // hoito-/rituaalituote: oma kulku (treatment-ui.js)
  const p = state.catalog.find((x) => x.slug === slug);
  setHero(p || null);
  if (!p) {
    // booking_158: tapahtuma/koulutus, jonka myynti on suljettu (public_catalog ei näytä sitä): tiedot ja ajankohdat public_eventsistä, ei ostoa
    const ev = findEvent(await publicEvents(), slug);
    if (ev) { viewEventClosed(ev); return; }
    const st = (await fetch(S.staticProductsUrl).then((r) => r.json()).catch(() => ({})))[slug];
    mount(h('p', {}, h('a', { href: bk('/'), text: t.backList })),
      h('h2', { text: st ? st.name : t.unknownProduct }), st ? fallbackDesc(h, st, S.lang) : null,   // kuvaus voi olla rikasta: puhdistettuna (rich-view.js), ei raakana tekstinä
      st ? h('div', { class: 'bk-notice' }, h('p', { text: t.contactUs }), phoneBox()) : null);
    focusTop(); return;
  }
  const today = todayHel();
  const horizon = state.settings.booking_horizon_days || 120;
  let [y, m] = (dateStr || today).split('-').map(Number); m -= 1;
  let sel = dateStr || null;
  const wrap = h('div', { class: 'bk-prod' });
  const draw = async () => {
    const calBox = h('div', { class: 'bk-cal' }), slotBox = h('div', { class: 'bk-slots', 'aria-live': 'polite' });
    const desc = pdesc(p) || '';
    const inc = includedPlain(desc), swim = swimwearPlain(desc);
    wrap.replaceChildren(
      h('p', {}, h('a', { href: bk('/'), text: t.backList })),
      h('div', { class: 'bk-prod-layout' },
        h('div', { class: 'bk-facts' },
          h('p', { class: 'bk-meta' }, h('strong', { text: priceText(p) }), pdur(p) ? ` · ${pdur(p)}` : ''),
          inc ? h('p', { class: 'bk-included', 'data-testid': 'included', text: inc }) : null,
          swim ? h('p', { class: 'bk-note bk-swim', 'data-testid': 'swimwear', text: swim }) : null,
          S.cancelRule ? h('p', { class: 'bk-note bk-cancel-rule', 'data-testid': 'product-cancel', text: S.cancelRule }) : null,
          h('a', { class: 'bk-jump', href: '#valitse-aika', text: t.pickTime })),
        h('div', { class: 'bk-prod-cal', id: 'valitse-aika' }, h('h3', { text: t.pickDate }), calBox, slotBox),
        desc ? h('details', { class: 'bk-more' }, h('summary', { text: t.moreInfo }), richHost(h, desc, 'bk-desc')) : null));
    let byDay = {};
    try { byDay = await loadMonth(p.id, y, m); } catch (e) { calBox.append(errorBox(t.loadError)); return; }
    const first = new Date(y, m, 1), days = new Date(y, m + 1, 0).getDate(), lead = (first.getDay() + 6) % 7;
    const monthName = fmt(new Date(Date.UTC(y, m, 1, 12)).toISOString(), { month: 'long', year: 'numeric', timeZone: 'UTC' });
    const maxDate = new Date(Date.now() + horizon * 864e5);
    const prevOk = new Date(y, m, 0) >= new Date(today), nextOk = new Date(y, m + 1, 1) <= maxDate;
    const nav = h('div', { class: 'bk-calnav' },
      h('button', { type: 'button', 'aria-label': t.prevMonth, disabled: !prevOk, onclick: () => { m--; if (m < 0) { m = 11; y--; } draw(); } }, '‹'),
      h('strong', { 'aria-live': 'polite', text: monthName }),
      h('button', { type: 'button', 'aria-label': t.nextMonth, disabled: !nextOk, onclick: () => { m++; if (m > 11) { m = 0; y++; } draw(); } }, '›'));
    const wd = Array.from({ length: 7 }, (_, i) => h('span', { class: 'bk-wd', 'aria-hidden': 'true', text: fmt(new Date(Date.UTC(2024, 0, 1 + i)).toISOString(), { weekday: 'short', timeZone: 'UTC' }) }));
    const cells = Array.from({ length: lead }, () => h('span', { class: 'bk-cell empty' }));
    let any = false;
    for (let d = 1; d <= days; d++) {
      const ds = `${y}-${pad2(m + 1)}-${pad2(d)}`, st = ds < today ? 'none' : dayState(byDay[ds]);
      if (st === 'free') any = true;
      const free = (byDay[ds] || []).filter((r) => r.status === 'available').length;
      const long = dayLong(`${ds}T12:00:00Z`);
      const label = st === 'free' ? `${long}, ${free}` : st === 'full' ? `${long}, ${t.full}` : st === 'unavail' ? `${long}, ${t.unavailable}` : null;
      cells.push(st === 'none'
        ? h('span', { class: 'bk-cell off', 'aria-hidden': 'true', text: d })
        : h('button', { type: 'button', class: `bk-cell ${st}${ds === today ? ' today' : ''}${ds === sel ? ' sel' : ''}`, 'aria-pressed': ds === sel ? 'true' : 'false', 'aria-label': label, ...(st === 'free' ? { 'data-qday': ds, 'data-qp': p.id, 'data-qmark': 'cal' } : {}), onclick: () => { sel = ds; history.replaceState(null, '', bk(`/tuote/${slug}/${ds}`)); drawSlots(); markSel(); revealForm(slotBox, slotBox.querySelector('h3')); } }, d));
    }
    calBox.append(nav, h('div', { class: 'bk-grid', role: 'group', 'aria-label': monthName }, wd, cells),
      h('p', { class: 'bk-legend' }, h('span', { class: 'dot free' }), t.free, ' ', h('span', { class: 'dot full' }), t.full, ' ', h('span', { class: 'dot unavail' }), t.unavailable, qLegend()),
      ...(any ? [] : [h('p', { class: 'bk-note', text: t.noSlotsMonth })]));
    const markSel = () => calBox.querySelectorAll('.bk-cell[aria-pressed]').forEach((b) => { const on = b.textContent === String(+sel?.slice(8)) && sel?.startsWith(`${y}-${pad2(m + 1)}`); b.classList.toggle('sel', on); b.setAttribute('aria-pressed', on ? 'true' : 'false'); });
    const drawSlots = () => {
      if (!sel) { slotBox.replaceChildren(); return; }
      const rows = visibleWaitlistSlots(byDay[sel] || []);   // alkamisajan mukaan; loppuunmyyty jää harmaana paikalleen
      slotBox.replaceChildren(h('h3', { text: `${t.pickSlot} – ${dayLong(`${sel}T12:00:00Z`)}` }),
        rows.length ? h('ul', { class: 'bk-slotlist' }, rows.map((r) => slotItem(r, sel, p))) : h('p', { text: t.noSlots }));
    };
    drawSlots();
  };
  mount(wrap); await draw(); if (!dateStr) focusTop();
}
function slotItem(r, ds, p) {
  const ok = r.status === 'available';
  // monipäiväinen kerta (koulutus, booking_158): alku- ja loppupäivä näkyviin
  const title = isMultiDay(r) ? occurrenceText(r, S.lang) : `${hm(r.starts_at)}–${hm(r.ends_at)}`;
  const sub = cleanLabel(rlabel(r));
  const price = r.price_mode === 'per_person' ? `${money(r.unit_price)} ${t.perPerson}` : r.price_mode === 'fixed' ? money(r.base_price)
    : `${money(r.base_price)} (${t.included(r.included_persons)}, ${t.extra(money(r.extra_person_price))})`;
  return h('li', { class: `bk-slot ${r.status}` },
    h('div', { class: 'bk-slot-main' }, h('strong', { class: 'bk-time', text: title }), sub ? h('span', { class: 'bk-sub', text: sub }) : null, h('span', { class: 'bk-price', text: price, ...qAttrs(ok, p, r, 'slot') })),
    h('div', { class: 'bk-slot-side' },
      ok ? h('span', { class: 'bk-badge free', text: t.freeSpots(r.remaining) }) : h('span', { class: 'bk-badge full', text: t.waitlistSessionSoldOut }),
      ok ? h('a', { class: 'btn sm', href: bk(`/varaa/${r.rule_id}/${ds}/${p.id}`) }, t.choose, h('span', { class: 'sr', text: ` ${title}` })) : h('a', { class: 'btn sm light bk-waitlist-link', href: bk(`/jono/${r.rule_id}/${ds}/${p.id}`), text: t.waitlistJoinShort })));
}

// booking_158: tapahtumat (public_events, kanava shop). Virhe tai vanha kanta ilman RPC:tä → [] (vanha käytös).
let eventsCache = null;
const publicEvents = () => (eventsCache ||= rpc('public_events', { p_from: todayHel(), p_channel: 'shop' }).then((r) => (Array.isArray(r) ? r : [])).catch(() => []));
// Suljettu myynti: tapahtuman nimi, lyhyt kuvaus, hinta ja tulevat ajankohdat ilman varauspainiketta + yhteystiedot. Kaikki nimet textContentina.
function viewEventClosed(ev) {
  const L = S.lang, tx = (k) => eventText(k, L, texts.tx);
  const occ = upcoming(ev), state = saleState(ev);
  const desc = (L === 'en' && ev.description_short_en) || ev.description_short || '';
  const price = ev.price != null ? money(ev.price) : null;
  mount(h('p', {}, h('a', { href: bk('/'), text: t.backList })),
    h('h2', { text: (L === 'en' && ev.name_en) || ev.name }),
    desc ? richHost(h, desc, 'bk-desc') : null,
    price ? h('p', { class: 'bk-meta' }, h('strong', { text: price })) : null,
    h('div', { class: 'bk-notice', role: 'status', 'data-testid': 'event-sale-closed' }, h('p', {}, h('strong', { text: tx(state === 'full' ? 'ui.shop.event.status_full' : 'ui.shop.event.sale_closed_title') })), h('p', { text: tx('ui.shop.event.sale_closed_text') }), phoneBox()),
    h('h3', { text: tx('ui.shop.event.dates') }),
    occ.length ? h('ul', { class: 'bk-slotlist', 'data-testid': 'event-dates' }, occ.map((o) => h('li', { class: `bk-slot ${o.status === 'full' ? 'full' : 'unavailable'}` },
      h('div', { class: 'bk-slot-main' }, h('strong', { class: 'bk-time', text: occurrenceText(o, L) }), occurrenceLabel(o, L) ? h('span', { class: 'bk-sub', text: occurrenceLabel(o, L) }) : null),
      h('div', { class: 'bk-slot-side' }, h('span', { class: `bk-badge ${o.status === 'full' ? 'full' : 'unavailable'}`, text: tx(o.status === 'full' ? 'ui.shop.event.status_full' : 'ui.shop.event.status_closed') })))))
      : h('p', { text: tx('ui.shop.event.no_dates') }));
  focusTop();
}

// ---- jaetut lomakeosat (vuorovaraus + hoitovaraus) ----
const field = (id, label, { hint, ...attrs } = {}) => h('div', { class: 'bk-field' }, h('label', { for: id, text: label }), h('input', { id, name: id, required: true, 'aria-describedby': hint ? `${id}-hint` : null, ...attrs }), hint ? h('small', { class: 'bk-hint', id: `${id}-hint`, text: hint }) : null);
const opt = (id, label, attrs) => field(id, label, { required: false, ...attrs });
// Asiakastiedot: yksityinen / yritys + nimi, sähköposti, puhelin. read(form, msg) validoi (virhe → msg + fokus, palauttaa null) ja palauttaa { kind, name, email, phone, company }.
function customerFields({ onChange } = {}) {
  let kind = 'private';
  let invoiceMethod = 'einvoice';   // booking_175/187: verkkolasku (oletus), PDF-lasku tai Maksa verkossa; OVT vain verkkolaskulla
  const kindInputs = [['private', t.kindPrivate], ['company', t.kindCompany]].map(([k, label]) => h('label', { class: 'bk-kind' }, h('input', { type: 'radio', name: 'kind', value: k, checked: k === 'private' || null, onchange: () => setKind(k) }), ' ', label));
  const nameLabel = h('label', { for: 'name', text: t.name });
  const einvoiceBox = h('div', { class: 'bk-einvoice', id: 'bk-einvoice-fields', 'data-testid': 'einvoice-fields' },
    h('h4', { text: t.einvoiceDetailsTitle }),
    field('einvoice_address', t.einvoiceAddress, { maxlength: 40 }), field('einvoice_operator', t.einvoiceOperator, { maxlength: 40, hint: t.einvoiceDetailsHint }));
  const methodInputs = [['einvoice', t.invoiceMethodEinvoice], ['pdf', t.invoiceMethodPdf], ['online', t.invoiceMethodOnline]].map(([m, label]) =>
    h('label', { class: 'bk-kind' }, h('input', { type: 'radio', name: 'invoice_method', value: m, checked: m === 'einvoice' || null, 'data-testid': `invoice-method-${m}`, onchange: () => setInvoiceMethod(m) }), ' ', label));
  const companyBox = h('fieldset', { class: 'bk-company', id: 'bk-company', hidden: true },
    h('legend', { text: t.companyTitle }),
    field('company_name', t.companyName, { maxlength: 200, autocomplete: 'organization' }), field('business_id', t.businessId, { maxlength: 20, inputmode: 'numeric', placeholder: '1234567-8', hint: t.businessIdHint }),
    field('street', t.street, { maxlength: 200, autocomplete: 'street-address' }),
    h('div', { class: 'bk-row2' }, field('zip', t.zip, { maxlength: 5, inputmode: 'numeric', autocomplete: 'postal-code' }), field('city', t.city, { maxlength: 100, autocomplete: 'address-level2' })),
    h('fieldset', { class: 'bk-kinds bk-invoice-method' }, h('legend', { text: t.invoiceMethodLabel }), h('div', { class: 'bk-kindrow' }, methodInputs)),
    einvoiceBox,
    opt('reference', t.buyerReference, { maxlength: 100 }),
    h('p', { class: 'bk-note', 'data-testid': 'company-method-note', text: t.companyInvoiceMethodNote }));
  const methodNote = companyBox.querySelector('[data-testid="company-method-note"]');
  function setInvoiceMethod(m) {
    invoiceMethod = m === 'pdf' ? 'pdf' : m === 'online' ? 'online' : 'einvoice'; einvoiceBox.hidden = invoiceMethod !== 'einvoice';
    if (methodNote) methodNote.textContent = invoiceMethod === 'online' ? t.companyOnlineNote : t.companyInvoiceMethodNote;
    for (const id of ['einvoice_address', 'einvoice_operator']) { const el = document.getElementById(id); if (el) el.required = kind === 'company' && invoiceMethod === 'einvoice'; }
    if (onChange) onChange();
  }
  function setKind(k) {
    kind = k; companyBox.hidden = k !== 'company'; if (k === 'company') revealIfHidden(companyBox); nameLabel.textContent = k === 'company' ? t.contactName : t.name;
    for (const id of ['company_name', 'business_id', 'street', 'zip', 'city']) { const el = document.getElementById(id); if (el) el.required = k === 'company'; }
    setInvoiceMethod(invoiceMethod);
  }
  const node = h('fieldset', { class: 'bk-section bk-contact' }, h('legend', { text: t.details }),
    h('fieldset', { class: 'bk-kinds' }, h('legend', { text: t.kindTitle }), h('div', { class: 'bk-kindrow' }, kindInputs)),
    companyBox,
    h('div', { class: 'bk-field' }, nameLabel, h('input', { id: 'name', name: 'name', required: true, autocomplete: 'name', maxlength: 120 })), field('email', t.email, { type: 'email', autocomplete: 'email', maxlength: 254 }),
    field('phone', t.phone, { type: 'tel', autocomplete: 'tel', maxlength: 30 }));
  const read = (form, msg) => {
    const f = new FormData(form), val = (k) => String(f.get(k) || '').trim();
    const need = ['name', 'email', 'phone'].filter((k) => !val(k));
    if (need.length || !form.email.checkValidity()) { msg.append(errorBox(t.required)); form[need[0] || 'email'].focus(); return null; }
    let company = null;
    if (kind === 'company') {
      const needC = ['company_name', 'business_id', 'street', 'zip', 'city'].filter((k) => !val(k));
      if (needC.length) { msg.append(errorBox(t.required)); form[needC[0]].focus(); return null; }
      if (!validBusinessId(val('business_id'))) { msg.append(errorBox(t.invalidBusinessId)); form.business_id.focus(); return null; }
      if (!/^\d{5}$/.test(val('zip'))) { msg.append(errorBox(t.invalidZip)); form.zip.focus(); return null; }
      const ei = invoiceMethod === 'einvoice';
      if (ei) {
        if (!val('einvoice_address') || !val('einvoice_operator')) { msg.append(errorBox(t.einvoiceDetailsRequired)); form[val('einvoice_address') ? 'einvoice_operator' : 'einvoice_address'].focus(); return null; }
        if (!validOvt(val('einvoice_address'), val('business_id'))) { msg.append(errorBox(t.invalidOvt)); form.einvoice_address.focus(); return null; }
        if (!validOperator(val('einvoice_operator'))) { msg.append(errorBox(t.einvoiceDetailsRequired)); form.einvoice_operator.focus(); return null; }
      }
      company = { company_name: val('company_name'), business_id: normBusinessId(val('business_id')), street: val('street'), zip: val('zip'), city: val('city'),
        invoice_method: invoiceMethod, einvoice_address: ei ? normOvt(val('einvoice_address')) : null, einvoice_operator: ei ? normOvt(val('einvoice_operator')) : null,
        reference: val('reference') || null, require_einvoice: ei };
    }
    return { kind, name: val('name'), email: val('email'), phone: val('phone'), company };
  };
  return { node, read, kind: () => kind, invoiceMethod: () => invoiceMethod };
}
// Lisätiedot, ehdot ja markkinointisuostumus (nodes: lomakkeeseen järjestyksessä; terms/consent: valintaruudut)
function legalFields({ showCancel = false } = {}) {
  const terms = h('input', { type: 'checkbox', id: 'bk-terms', required: true });
  const consent = h('input', { type: 'checkbox', id: 'bk-consent' });
  const nodes = [h('div', { class: 'bk-field' }, h('label', { for: 'note', text: t.note }), h('textarea', { id: 'note', name: 'note', rows: 3, maxlength: 1000 })),
    showCancel && S.cancelRule ? h('p', { class: 'bk-note bk-cancel-rule', 'data-testid': 'checkout-cancel-rule', text: S.cancelRule }) : null,
    h('div', { class: 'bk-check' }, terms, h('label', { for: 'bk-terms' }, t.acceptTerms + ' ', h('a', { href: S.termsHref, target: '_blank', rel: 'noopener', text: t.termsLink }), ' *')),
    h('div', { class: 'bk-check' }, consent, h('label', { for: 'bk-consent', text: t.consentMarketing }))].filter((n) => n != null);
  return { nodes, terms, consent };
}

// ---- näkymä 3: henkilömäärä + yhteystiedot ----
async function viewCheckout(ruleId, ds, productId, via) {
  // Haetaan vuoro tuotteen kuukausidatasta (tuote-id tulee linkissä; ilman sitä käydään tuotteet läpi)
  let s = null, p = null;
  const order = [...state.catalog].sort((a, b) => (b.id === +productId) - (a.id === +productId));
  for (const prod of order) {
    const [y, m] = ds.split('-').map(Number);
    const byDay = await loadMonth(prod.id, y, m - 1).catch(() => ({}));
    const f = (byDay[ds] || []).find((r) => r.rule_id === +ruleId);
    if (f) { s = f; p = prod; break; }
    if (+productId === prod.id) break;
  }
  setHero(p);
  if (!s) { mount(h('p', {}, h('a', { href: bk('/'), text: t.backList })), errorBox(t.noSlots)); focusTop(); return; }
  let max = Math.max(s.min_persons, Math.min(s.max_persons || 50, s.remaining));
  const qs = new URLSearchParams(location.hash.split('?')[1] || '');
  let n = Math.min(Math.max(+qs.get('n') || s.min_persons, s.min_persons), max);
  // Jonotuslinkki (?wl=token, booking_134): lunastus vain, jos paikkoja on yhä jonovarauksen henkilömäärälle; määrä lukitaan siihen.
  // Virheellinen tai vanhentunut linkki → ilmoitus ja tavallinen varaus. RPC-virhe (esim. vanha backend) → tavallinen varaus.
  let wlLock = false, wlNote = null;
  const wl = qs.get('wl');
  if (wl && /^[0-9a-f-]{36}$/i.test(wl)) {
    const c = await rpc('public_waitlist_claim', { p_token: wl }).catch(() => null);
    // booking_139: pidon aikana pidetyt paikat eivät näy julkisessa haussa (kuukausidata); haltijalle lunastus palauttaa
    // remaining-arvon, jossa oma pito on mukana → raja nostetaan siihen (vanha backend ilman remaining-kenttää → ennallaan).
    if (c?.ok && +c.rule_id === s.rule_id && c.session_date === ds && c.enough && !c.hold_expired && c.remaining != null && Number.isFinite(+c.remaining)) max = Math.max(max, Math.min(s.max_persons || 50, +c.remaining));
    // booking_137: ilmoituksen pito (120 min, kun vuoroon oli ≥ 48 h) päättyi → oma teksti (offer_expired).
    if (c && (!c.ok || +c.rule_id !== s.rule_id || c.session_date !== ds)) wlNote = h('p', { class: 'bk-note', role: 'status', text: c.code === 'offer_expired' ? t.waitlistClaimExpired : t.waitlistClaimInvalid });
    // booking_139: pito vanheni (hold_expired) → sama teksti, mutta tavallinen varaus ilman lukitusta tai estoa.
    else if (c?.ok && c.hold_expired) wlNote = h('p', { class: 'bk-note', role: 'status', text: t.waitlistClaimExpired });
    // booking_148: yksityisvuorossa (kind 'private' / mode 'exclusive') jonovarauksella ei ole henkilömäärää → ei lukitusta, vain vapaus ratkaisee.
    else if (c?.ok && (c.kind === 'private' || s.mode === 'exclusive')) {
      if (!c.enough) {
        mount(h('h2', { text: t.bookTitle }), errorBox(t.waitlistClaimNotEnough),
          h('p', {}, h('a', { href: via === 'day' ? bk(`/paiva/${ds}?tuote=${p.slug}`) : bk(`/tuote/${p.slug}/${ds}`), text: t.waitlistBack })));
        focusTop(); return;
      }
    } else if (c?.ok && (!c.enough || +c.persons > max || +c.persons < s.min_persons)) {
      mount(h('h2', { text: t.bookTitle }), errorBox(t.waitlistClaimNotEnough),
        h('p', {}, h('a', { href: via === 'day' ? bk(`/paiva/${ds}?tuote=${p.slug}`) : bk(`/tuote/${p.slug}/${ds}`), text: t.waitlistBack })));
      focusTop(); return;
    } else if (c?.ok) { n = +c.persons; wlLock = true; }
  }
  const total = h('strong', { class: 'bk-total', 'aria-live': 'polite' });
  const sumList = h('dl', { class: 'bk-sum' });
  // lisäpalvelut (public_addons): vain tämän vuorotyypin lisäpalvelut; virhe tai puuttuva funktio → ei lisäpalveluita
  const addons = ((await rpc('public_addons').catch(() => [])) || []).filter((a) => (a.applies_modes || []).includes(s.mode));
  const qty = new Map(addons.map((a) => [a.id, 0]));
  // booking_162: hiljaisen ajan ale tälle vuorolle (arvio näyttöön; palvelin laskee ja lukitsee hinnan varauksessa). Virhe → ei alea.
  const qOffer = findOffer(await quietIdx().catch(() => null), p.id, s.rule_id, s.starts_at);
  const qNote = h('p', { class: 'bk-note bk-quiet-note', 'data-testid': 'checkout-quiet-note', hidden: true, text: t.quietNote });
  const addonsSum = () => addons.reduce((x, a) => x + qty.get(a.id) * +a.price, 0);
  // booking_166: saunarituaali lisäpalvelukorttina LISÄPALVELUT-osiossa (vain yleinen vuoro; Joonas 24.10.2026: samaan osioon ja samaan
  // muotoon kuin muut lisäpalvelut). Määrä 0 = ei rituaalia; määrä ≥ 1 → kortissa alasvetovalikko "Valitse kellonaika" (pakollinen).
  // Ajat, vapaat paikat ja hinnat palvelimelta (public_ritual_addon); ei aikoja / vanha backend / virhe → kortti piilossa.
  // Valinta = { key: alkuaika ISO (UTC) tai null, qty }; palvelin lukitsee ajan, osallistujat ja hinnan varauksessa (p_addons).
  const rit = { offer: null, sel: { key: null, qty: 0 }, seq: 0, timer: null, n, ui: null, sync: null };
  const ritCard = h('li', { class: 'bk-addon bk-addon-ritual', 'data-testid': 'checkout-ritual', hidden: true, style: 'display:none' });
  const ritMsg = h('p', { class: 'bk-note bk-ritual-msg', role: 'status', 'aria-live': 'polite', 'data-testid': 'ritual-msg' });
  const ritWant = () => !!rit.offer && rit.sel.qty > 0 && !annualOn();
  const ritOn = () => ritWant() && !!rit.sel.key;
  const ritualSum = () => (ritWant() ? ritualPrice(rit.offer, rit.sel.qty) : 0);
  const rtm = (iso) => clockFromIso(iso, S.lang);
  const ritName = () => (S.lang === 'en' && rit.offer?.name_en) || rit.offer?.name || rtx('ritualTitle');
  const ritErr = (text) => { if (!rit.ui) return; rit.ui.err.textContent = text || ''; rit.ui.err.hidden = !text; rit.ui.sel.setAttribute('aria-invalid', text ? 'true' : 'false'); };
  async function loadRitual() {
    if (s.mode !== 'shared') return;
    const my = ++rit.seq; rit.n = n;
    let r = null;
    try { r = await rpc('public_ritual_addon', { p_rule_id: s.rule_id, p_date: ds, p_persons: n }); } catch { r = null; }
    if (my !== rit.seq) return;
    const offer = normalizeOffer(r), rc = reconcileCard(rit.sel, offer, n);
    rit.offer = offer; rit.sel = { key: rc.key, qty: rc.qty };
    ritMsg.textContent = rc.lost && !offer ? rtx('ritualLost') : '';
    renderRitual(); upd();
    if (rc.lost && offer) ritErr(rtx('ritualLost'));
  }
  function renderRitual() {
    const o = rit.offer;
    ritCard.hidden = !o; ritCard.style.display = o ? '' : 'none';
    if (addonsBox) addonsBox.hidden = !o && !addonRows.length && !ritMsg.textContent;
    if (!o) { ritCard.replaceChildren(); rit.ui = null; rit.sync = null; return; }
    const name = ritName();
    const pos = { before: rtx('ritualBefore'), start: rtx('ritualStart'), during: rtx('ritualDuring'), end: rtx('ritualEnd') };
    const setQty = (v) => { const hi = annualOn() ? 0 : ritualMax(o, rit.sel.key, n); rit.sel.qty = Math.max(0, Math.min(Math.floor(+v) || 0, hi)); if (!rit.sel.qty) rit.sel.key = null; ritErr(''); upd(); };
    const q = h('input', { id: 'bk-rit-n', type: 'number', min: 0, inputmode: 'numeric', 'data-testid': 'ritual-qty', 'aria-label': `${name}: ${t.addonQty}`, onchange: () => setQty(q.value) });
    const dec = h('button', { type: 'button', class: 'bk-step', 'data-testid': 'ritual-dec', 'aria-label': `${name} −`, onclick: () => setQty(rit.sel.qty - 1) }, '−');
    const inc = h('button', { type: 'button', class: 'bk-step', 'data-testid': 'ritual-inc', 'aria-label': `${name} +`, onclick: () => setQty(rit.sel.qty + 1) }, '+');
    const sel = h('select', { id: 'bk-rit-time', name: 'ritual_time', class: 'bk-rit-select', 'data-testid': 'ritual-time', 'aria-describedby': 'bk-rit-err', 'aria-required': 'true',
      onchange: () => { rit.sel.key = sel.value || null; if (rit.sel.key) rit.sel.qty = cardQty(rit.sel.qty, o, rit.sel.key, n); ritErr(''); upd(); } });   // ajan vaihto → määrä rajataan ajan vapaisiin paikkoihin
    const err = h('p', { id: 'bk-rit-err', class: 'bk-rit-err', role: 'alert', 'data-testid': 'ritual-err', hidden: true });
    const timeBox = h('div', { class: 'bk-rit-time', 'data-testid': 'ritual-timebox', hidden: true }, h('label', { for: 'bk-rit-time', text: rtx('ritualTimeLabel') }), h('div', { class: 'bk-rit-selectwrap' }, sel), err);
    const annualNote = h('small', { class: 'bk-rit-annual', 'data-testid': 'ritual-annual', hidden: true, text: rtx('ritualAnnual') });
    rit.ui = { sel, err, card: ritCard };
    rit.sync = () => {
      const lock = annualOn(), hi = lock ? 0 : ritualMax(o, rit.sel.key, n), all = ritualMax(o, null, n);
      q.max = hi; q.value = rit.sel.qty; q.disabled = lock; dec.disabled = lock || rit.sel.qty <= 0; inc.disabled = lock || rit.sel.qty >= hi;
      annualNote.hidden = !lock; timeBox.hidden = !(rit.sel.qty > 0) || lock;
      sel.replaceChildren(h('option', { value: '', text: rtx('ritualChoose') }),
        ...o.times.map((x) => h('option', { value: x.key, text: [`${rtm(x.starts_at)}`, pos[x.position || ''] || '', x.max < all ? `(${rtx('ritualSpots', { n: x.max })})` : ''].filter(Boolean).join(' · ').replace(' · (', ' (') })));
      sel.value = rit.sel.key || '';
      sel.classList.toggle('is-empty', !rit.sel.key);
    };
    ritCard.replaceChildren(
      h('div', { class: 'bk-addon-info' }, h('label', { for: 'bk-rit-n' }, h('strong', { text: name }), ' ', h('span', { class: 'bk-addon-price', 'data-testid': 'ritual-price', text: rtx('ritualPrice', { price: money(o.unit_price ?? ritualPrice(o, 1)) }) })),
        h('small', { text: rtx('ritualLead', { min: o.duration_minutes || 20 }) }), annualNote),
      h('div', { class: 'bk-stepper' }, dec, q, inc),
      timeBox);
    rit.sync();
  }
  // Alennus- / vuosikorttikoodi (booking_142): palvelin laskee hinnan (public_check_code); quote = viimeisin hyväksytty vastaus
  // ja sig = henkilömäärä + lisäpalvelut, joille se laskettiin. Vuosikortti lukitsee henkilömäärän ja poistaa lisäpalvelut.
  const code = { value: '', quote: null, sig: '', timer: null };
  const sig = () => `${quoteSignature(n, addons.map((a) => qty.get(a.id)))}|${ritualSig(ritOn() ? rit.sel : null)}`;
  const chosenAddons = () => { const c = addons.filter((a) => qty.get(a.id) > 0).map((a) => ({ id: a.id, quantity: qty.get(a.id) })), ra = ritualAddonArg(ritOn() ? rit.sel : null); if (ra) c.push(ra); return c; };
  const annualOn = () => isAnnualQuote(code.quote);
  const locked = () => wlLock || annualOn();
  // booking_179: lisähoidon hinta tulee vasta valinnan jälkeen (ei esivalintaa). Paikkamerkki, kunnes osio on luotu.
  let upsellUI = { total: () => 0, items: () => [], hasSuggestedAddon: () => false, session: '', text: () => '', node: null, reset() {} };
  const upd = () => {
    if (annualOn()) { n = +code.quote.persons || 1; for (const a of addons) qty.set(a.id, 0); }
    for (const a of addons) qty.set(a.id, Math.min(qty.get(a.id), addonLimit(a, n)));
    if (annualOn()) rit.sel = { key: null, qty: 0 };   // vuosikortti: ei lisäpalveluita (annual_card_no_addons)
    else if (rit.sel.qty > 0) { rit.sel.qty = cardQty(rit.sel.qty, rit.offer, rit.sel.key, n); if (!rit.sel.qty) rit.sel.key = null; }
    if (s.mode === 'shared' && rit.n !== n) { rit.n = n; clearTimeout(rit.timer); rit.timer = setTimeout(loadRitual, 350); }   // henkilömäärä muuttui → vapaat ajat uudelleen
    if (code.quote && !annualOn() && code.sig !== sig()) recheckCode();
    const fresh = code.quote && code.sig === sig();
    const qv = quietCheckout({ quote: fresh ? code.quote : null, offer: annualOn() || (code.quote && !fresh) ? null : qOffer, sessionTotal: priceFor(s, n), discountBase: quietBase(s, n) });
    total.textContent = money((fresh ? +code.quote.total : priceFor(s, n) - (qv.source === 'quiet' ? qv.amount : 0) + addonsSum() + ritualSum()) + upsellUI.total());
    qNote.hidden = qv.source !== 'quiet';
    sumList.replaceChildren(h('dt', { text: t.what }), h('dd', { text: pname(p) }), h('dt', { text: t.when }), h('dd', { text: `${dayLong(s.starts_at)}, ${hm(s.starts_at)}–${hm(s.ends_at)}` }), h('dt', { text: t.persons }), h('dd', { text: String(n) }),
      ...addons.filter((a) => qty.get(a.id) > 0).flatMap((a) => [h('dt', { text: aname(a) }), h('dd', { text: `${qty.get(a.id)} × ${money(a.price)}` })]),
      ...(ritWant() ? [h('dt', { text: ritName() }), h('dd', { 'data-testid': 'checkout-ritual-sum', text: rit.sel.key ? `${rtx('ritualSummary', { time: rtm(rit.sel.key), n: rit.sel.qty })} · ${money(ritualSum())}` : `${rit.sel.qty} × ${money(rit.offer.unit_price ?? ritualPrice(rit.offer, 1))}` })] : []),
      ...(qv.source === 'quiet' ? [h('dt', { text: fillText(t.quietCheckout, { pct: pctText(qv.percent, S.lang) }) }), h('dd', { 'data-testid': 'checkout-quiet', text: `−${money(qv.amount)}` })] : []),
      ...(fresh && qv.source === 'code' && +code.quote.discount > 0 ? [h('dt', { text: annualOn() ? t.annualTitle : t.codeDiscountRow }), h('dd', { 'data-testid': 'checkout-discount', text: `${code.quote.code} · −${money(code.quote.discount)}` })] : []),
      ...(upsellUI.total() > 0 ? [h('dt', { text: upsellUI.text('checkout_title') }), h('dd', { 'data-testid': 'checkout-upsell', text: money(upsellUI.total()) })] : []));
    num.value = n; minus.disabled = wlLock || annualOn() || n <= s.min_persons; plus.disabled = wlLock || annualOn() || n >= max; num.readOnly = wlLock || annualOn();
    for (const r of addonRows) r.sync();
    rit.sync?.();
    syncPay();
  };
  const num = h('input', { id: 'bk-n', type: 'number', min: s.min_persons, max, inputmode: 'numeric', 'aria-label': t.persons, onchange: () => { if (locked()) { upd(); return; } n = Math.min(Math.max(+num.value || s.min_persons, s.min_persons), max); upd(); } });
  const minus = h('button', { type: 'button', class: 'bk-step', 'aria-label': '−', onclick: () => { n--; upd(); } }, '−');
  const plus = h('button', { type: 'button', class: 'bk-step', 'aria-label': '+', onclick: () => { n++; upd(); } }, '+');
  let syncPay = () => {};
  const cf = customerFields({ onChange: () => syncPay() });
  // lisäpalvelurivi: nimi, hinta, kuvaus + määrävalitsin (− n +)
  const addonRows = addons.map((a) => {
    const q = h('input', { id: `bk-a-${a.id}`, type: 'number', min: 0, inputmode: 'numeric', 'aria-label': `${aname(a)}: ${t.addonQty}`, onchange: () => { qty.set(a.id, Math.max(0, Math.min(Math.floor(+q.value) || 0, addonLimit(a, n)))); upd(); } });
    const dec = h('button', { type: 'button', class: 'bk-step', 'aria-label': `${aname(a)} −`, onclick: () => { qty.set(a.id, qty.get(a.id) - 1); upd(); } }, '−');
    const inc = h('button', { type: 'button', class: 'bk-step', 'aria-label': `${aname(a)} +`, onclick: () => { qty.set(a.id, qty.get(a.id) + 1); upd(); } }, '+');
    const sync = () => { const lim = annualOn() ? 0 : addonLimit(a, n); q.max = lim; q.value = qty.get(a.id); q.disabled = annualOn(); dec.disabled = qty.get(a.id) <= 0; inc.disabled = qty.get(a.id) >= lim; };
    const node = h('li', { class: 'bk-addon' }, h('div', { class: 'bk-addon-info' }, h('label', { for: `bk-a-${a.id}` }, h('strong', { text: aname(a) }), ' ', h('span', { class: 'bk-addon-price', text: money(a.price) })), adesc(a) ? h('small', { text: adesc(a) }) : null),
      h('div', { class: 'bk-stepper' }, dec, q, inc));
    return { node, sync, a };
  });
  // LISÄPALVELUT: rituaalikortti ensimmäisenä, sitten muut lisäpalvelut. Osio näkyy, kun on lisäpalveluita tai rituaali tarjolla.
  const addonsBox = h('fieldset', { class: 'bk-section bk-addons', 'data-testid': 'checkout-addons', hidden: !addonRows.length }, h('legend', { text: t.addonsTitle }), h('p', { class: 'bk-hint', text: t.addonsHint }),
    h('ul', { class: 'bk-addonlist' }, ritCard, addonRows.map((r) => r.node)), ritMsg);
  // booking_179: ei esivalintaa eikä erillistä maksuvirtaa. Lisähoito liittyy samaan tilaukseen varauksen jälkeen.
  upsellUI = checkoutUpsellSection({ S, L: S.lang, productId: p.id, date: ds, visitStart: s.starts_at, persons: n, rpc, addons, onChange: upd,
    details: (id) => {
      const row = [...(state.catalog || []), ...(state.treatments || [])].find((x) => +x.id === +id) || null;
      const img = state.images.get(+id);
      if (!row && !img) return null;
      return { ...(row || {}), image_url: img?.url || '', image_alt: img?.alt || '', min_persons: row?.min_persons ?? row?.capacity_min ?? null, max_persons: row?.max_persons ?? row?.capacity_max ?? null };
    } });
  const msg = h('div', { id: 'bk-msg' });
  const hm0 = holdModeOf(null, state.settings);   // oletus asetuksesta (vain luku); palvelimen public_checkout_payment_options päivittää alla
  const hmode = { on: false, minutes: hm0.minutes };   // uusi pitotila vain kun palvelin sanoo (hold_until_paid); asetus ohjaa vain vanhaa ohjetekstiä
  const submit = h('button', { type: 'submit', class: 'btn gold', 'data-testid': 'checkout-submit', text: hmode.on ? ht(S.lang, 'checkout.button') : t.book });
  const legal = legalFields({ showCancel: true }), { terms, consent } = legal;
  // Ilmainen (vuosikortti tai 100 % koodi) → "Vahvista varaus"; muuten ennallaan.
  const free = () => !!code.quote && code.sig === sig() && +code.quote.total === 0;
  // cf.kind on funktio. formPaysOnline vertaa kindiä merkkijonoon, joten olio pitää avata.
  const paysOnline = () => formPaysOnline({ kind: cf.kind(), invoiceMethod: cf.invoiceMethod });
  const submitLabel = () => { if (!submit.disabled) submit.textContent = free() ? t.codeConfirm : paysOnline() && hmode.on ? ht(S.lang, 'checkout.button') : t.book; };
  const codeInput = h('input', { id: 'bk-code', name: 'discount_code', maxlength: 40, autocomplete: 'off', autocapitalize: 'characters', spellcheck: 'false', 'aria-describedby': 'bk-code-status',
    oninput: (e) => { const v = normalizeCode(e.target.value); if (v !== e.target.value) e.target.value = v; },
    onkeydown: (e) => { if (e.key === 'Enter') { e.preventDefault(); if (!codeInput.readOnly) applyCode(normalizeCode(codeInput.value)); } } });
  const codeStatus = h('p', { id: 'bk-code-status', class: 'bk-code-status', role: 'status', 'aria-live': 'polite' });
  const codeApply = h('button', { type: 'button', class: 'btn sm', 'data-testid': 'code-apply', text: t.codeApply, onclick: () => applyCode(normalizeCode(codeInput.value)) });
  const codeRemove = h('button', { type: 'button', class: 'bk-code-remove', 'data-testid': 'code-remove', hidden: true, text: t.codeRemove, onclick: () => clearCode(true) });
  const codeBox = h('details', { class: 'bk-section bk-code', 'data-testid': 'checkout-code' }, h('summary', { text: t.codeToggle }),
    h('div', { class: 'bk-code-body' }, h('label', { for: 'bk-code', text: t.codeLabel }), h('div', { class: 'bk-code-row' }, codeInput, codeApply), codeStatus, codeRemove));
  const setStatus = (text, ok) => { codeStatus.textContent = text || ''; codeStatus.classList.toggle('ok', !!ok); codeStatus.classList.toggle('err', !!text && !ok); };
  function clearCode(focus) {
    code.value = ''; code.quote = null; code.sig = ''; clearTimeout(code.timer);
    codeInput.readOnly = false; codeApply.hidden = false; codeRemove.hidden = true; setStatus('');
    upd(); if (focus) codeInput.focus();
  }
  async function applyCode(v, quiet = false) {
    if (!v) { setStatus(t.codeEmpty, false); codeInput.focus(); return; }
    codeApply.disabled = true; if (!quiet) setStatus(t.codeChecking, true);
    const fd = new FormData(form);
    const chosen = chosenAddons();
    let r = null;
    try {
      r = await rpc('public_check_code', { p_code: v, p_rule_id: s.rule_id, p_date: ds, p_persons: n, p_addons: chosen.length ? chosen : null,
        p_email: String(fd.get('email') || '').trim() || null, p_phone: String(fd.get('phone') || '').trim() || null });
    } catch { r = { ok: false, code: 'generic' }; }
    codeApply.disabled = false;
    if (!r?.ok) { code.value = ''; code.quote = null; code.sig = ''; codeInput.readOnly = false; codeApply.hidden = false; codeRemove.hidden = true; setStatus(t.codeErrors[r?.code] || t.codeErrors.generic, false); upd(); return; }
    code.value = v; code.quote = r;
    if (isAnnualQuote(r)) { n = +r.persons || 1; for (const a of addons) qty.set(a.id, 0); rit.sel = { key: null, qty: 0 }; }
    code.sig = sig();
    codeInput.readOnly = true; codeApply.hidden = true; codeRemove.hidden = false;
    if (r.discount_source === 'quiet') setStatus(t.quietCodeNote, true);   // booking_162: ale on edullisempi → koodia ei käytetä (etuja ei yhdistetä)
    else setStatus(isAnnualQuote(r) ? `${t.codeAnnualApplied} ${t.codeAnnualLocked}${r.type === 'annual_card' ? ' ' + t.codeAnnualOwner : ''}` : `${t.codeApplied}: ${r.code} · −${money(r.discount)}`, true);
    upd();
  }
  // Henkilömäärä tai lisäpalvelut muuttuivat → sama koodi tarkistetaan uudelleen palvelimella (viive: ei kutsua joka napautuksesta).
  function recheckCode() {
    clearTimeout(code.timer); setStatus(t.codeRecheck, true);
    code.timer = setTimeout(() => { if (code.value && code.sig !== sig()) applyCode(code.value, true); }, 600);
  }
  const form = h('form', { class: 'bk-form', novalidate: true, onsubmit: async (ev) => {
    ev.preventDefault(); msg.replaceChildren();
    const f = new FormData(form), cust = cf.read(form, msg); if (!cust) { revealIfHidden(msg); return; }
    if (ritWant() && !rit.sel.key && rit.ui) {   // määrä ≥ 1 mutta aikaa ei valittu → selkeä ilmoitus kortissa, vieritys ja fokus valikkoon
      ritErr(rtx('ritualTimeRequired')); rit.ui.card.scrollIntoView({ block: 'center', behavior: 'smooth' }); rit.ui.sel.focus({ preventScroll: true }); return;
    }
    if (!terms.checked) { msg.append(errorBox(t.acceptTermsErr)); revealIfHidden(msg); terms.focus({ preventScroll: true }); return; }
    const wasFree = free();
    submit.disabled = true; submit.textContent = wasFree ? t.codeConfirming : paysOnline() && hmode.on ? ht(S.lang, 'checkout.creating') : t.booking;
    try {
      const chosen = chosenAddons();
      const args = { p_rule_id: s.rule_id, p_date: ds, p_persons: n, p_name: cust.name, p_email: cust.email, p_phone: cust.phone, p_marketing_consent: consent.checked, p_locale: S.lang, p_note: (f.get('note') || '').trim() || null,
        p_customer_kind: cust.kind, p_company: cust.company, p_addons: chosen.length ? chosen : null };
      const extras = upsellUI.items();
      // Alennus- tai vuosikorttikoodi säilyttää oman RPC:nsä. Lisähoitoa ei lähetetä sen kanssa (palvelin hylkää myös).
      if (code.value && extras.length) throw Object.assign(new Error(upsellUI.text('code_conflict') || t.errorGeneric), { mapped: true });
      // Koodi vain kun se on hyväksytty: muuten sama public_create_booking kuin ennen (booking_142 ei muuta sitä).
      const r = code.value ? await rpc('public_create_booking_code', { ...args, p_code: code.value }) : await rpc('public_create_booking', args);
      if (!r.ok) throw Object.assign(new Error((isCodeError(r.code) && t.codeErrors[r.code]) || holdError(S.lang, r.code) || t.errors[r.code] || RITUAL_ERRORS[S.lang]?.[r.code] || t.errorGeneric), { code: r.code, mapped: true });
      state.months.clear();
      if (extras.length || upsellUI.hasSuggestedAddon(chosen)) {
        const attached = await rpc('public_upsell_checkout_attach', { p_token: r.token, p_upsell: extras, p_session_id: upsellUI.session }).catch(() => null);
        if (!attached?.ok) {
          submit.textContent = wasFree ? t.codeConfirm : paysOnline() && hmode.on ? ht(S.lang, 'checkout.button') : t.book;
          const href = `${S.confirmHref}${mockQs()}#${r.token}`;
          msg.replaceChildren(errorBox(upsellUI.text('attach_failed') || t.errorGeneric),
            h('p', {}, h('a', { href, text: upsellUI.text('open_order') || href })));
          revealIfHidden(msg);
          return; // perusvaraus on jo olemassa: ei toista public_create_booking-kutsua
        }
      }
      location.assign(`${S.confirmHref}${mockQs()}#${r.token}`);
    } catch (e) {
      submit.disabled = false; submitLabel();
      msg.replaceChildren(errorBox(e.mapped ? e.message : t.errorGeneric));   // palvelimen raaka message ei koskaan asiakkaalle (ui.shop.error_generic)
      if (['capacity_exceeded', 'private_booked', 'public_shift_booked', 'space_closed'].includes(e.code)) state.months.clear();
      if (isRitualError(e.code)) loadRitual();   // booking_166: rituaaliaika ehti täyttyä → vapaat ajat uudelleen
      msg.firstChild.setAttribute('tabindex', '-1'); revealIfHidden(msg); msg.firstChild.focus({ preventScroll: true });
    }
  } },
    h('fieldset', { class: 'bk-section' }, h('legend', { text: t.persons }), h('div', { class: 'bk-stepper' }, minus, num, plus)),
    // Järjestys: henkilömäärä → asiakastyyppi ja yhteystiedot → lisäpalvelut → lisätiedot, ehdot ja varaus
    cf.node,
    upsellUI.node,
    addonsBox,
    codeBox, legal.nodes,
    msg, submit);
  form.addEventListener('input', () => msg.replaceChildren());   // vanha virheilmoitus pois kun käyttäjä korjaa tietoja
  // Lyhyt yhteenveto otsikon alla (tuote, päivä, kellonaika) + linkki takaisin valintaan (korvaa erillisen "Takaisin"-linkin):
  // päivänäkymästä tultaessa (?via=day) päivään ja avoimeen tuotteeseen, muuten tuotesivulle samalle päivälle. Tiedot samasta vuorodatasta kuin lomake.
  const tm = (iso) => fmt(iso, { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).replace('.', ':');
  const dayShort = (iso) => fmt(iso, S.lang === 'fi' ? { weekday: 'short', day: 'numeric', month: 'numeric', year: 'numeric' } : { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' });
  const pick = h('section', { class: 'bk-pick', 'aria-label': t.pickedSlot },
    h('div', { class: 'bk-pick-main' }, h('strong', { class: 'bk-pick-name', text: pname(p) }),
      h('span', { class: 'bk-pick-when', text: `${dayShort(s.starts_at)}${S.lang === 'fi' ? ', klo ' : ' · '}${tm(s.starts_at)}${s.ends_at ? `–${tm(s.ends_at)}` : ''}` })),
    h('a', { class: 'bk-pick-change', href: via === 'day' ? bk(`/paiva/${ds}?tuote=${p.slug}`) : bk(`/tuote/${p.slug}/${ds}`), text: t.changeSlot }));
  // Maksuohje: tulee asetuksesta (public_payment_mode) ja palvelimen maksutavoista (MobilePay / lahjakortti) – ei oleteta pay_later-tilaa. Oletusteksti ensin, päivitys kun maksutavat on haettu.
  const payNote = h('p', { class: 'bk-pay', 'data-testid': 'checkout-paynote', text: hm0.legacy ? t.payHold(hmode.minutes) : t.payLater });
  const payExtra = h('div', { 'data-testid': 'checkout-hold-extra' });
  let holdSnap = null;
  syncPay = () => {
    submitLabel();
    if (free()) { payNote.hidden = payExtra.hidden = true; return; }   // maksuton varaus: ei maksuohjetta
    payNote.hidden = false;
    if (!paysOnline()) {   // booking_187 K4: laskulla maksettava yritys ei näe pitotilan nappia eikä ohjetta
      payNote.textContent = t.companyInvoiceMethodNote;
      payExtra.hidden = true;
      return;
    }
    payExtra.hidden = false;
    const hi = holdSnap;
    if (hi?.on) {
      payNote.textContent = ht(S.lang, 'checkout.lead', { minutes: hi.minutes });
      payExtra.replaceChildren(...hi.extra(S.lang));
      return;
    }
    payExtra.replaceChildren();
    if (hi?.onlineSite) payNote.textContent = hi.legacyHold ? `${t.payHold(hi.minutes)} ${pt(S.lang, 'checkoutHoldOnlinePay')}` : pt(S.lang, 'checkoutOnlinePaySite');
    else payNote.textContent = (hi?.legacyHold || hm0.legacy) ? t.payHold((hi && hi.minutes) || hmode.minutes) : t.payLater;
  };
  holdInfo().then((hi) => {
    holdSnap = hi; hmode.on = hi.on; hmode.minutes = hi.minutes;
    syncPay();
  });
  mount(h('h2', { text: t.bookTitle }), pick, wlNote,
    h('div', { class: 'bk-checkout' }, form,
      h('aside', { class: 'bk-aside', 'aria-label': t.summary }, h('h3', { text: t.summary }), sumList,
        h('p', { class: 'bk-totalrow' }, t.total + ': ', total, ' ', h('small', { text: t.vatIncl })), qNote,
        payNote, payExtra)));
  upd(); focusTop();
  loadRitual();
}

function retryBookingHref(b, it, stMap) {
  const slug = stMap?.get(+it?.product_id)?.slug;
  if (!slug || !it?.starts_at) return bk('/');
  const ds = new Date(it.starts_at).toLocaleDateString('sv-SE', { timeZone: TZ });
  if (isTreatmentBooking(b)) {
    const parts = new Intl.DateTimeFormat('en-GB', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(new Date(it.starts_at));
    const hh = parts.find((p) => p.type === 'hour')?.value || '00';
    const mm = parts.find((p) => p.type === 'minute')?.value || '00';
    return bk(`/tuote/${slug}?n=${it.persons || 1}&d=${ds}&t=${hh}${mm}`);
  }
  return bk(`/tuote/${slug}/${ds}`);
}
// ---- vahvistussivu ----
const ics = (b) => {
  const { main, ritual } = splitItems(b.items), z = (iso) => new Date(iso).toISOString().replace(/[-:]|\.\d{3}/g, '');
  // booking_166: vuoron mukana varattu saunarituaali omana tapahtumanaan (UID-pääte -r1 …), vuoro ensin
  const ev = (it, uid) => ['BEGIN:VEVENT', `UID:${uid}@saunotus.fi`, `DTSTAMP:${z(new Date().toISOString())}`, `DTSTART:${z(it.starts_at)}`, `DTEND:${z(it.ends_at)}`, `SUMMARY:${it.product_name}`, 'LOCATION:Hindsbyntie 124\\, 04130 Sipoo', 'END:VEVENT'];
  return ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Sipoonjoen Perinnesauna//Varaus//FI', ...ev(main, b.order_no), ...ritual.flatMap((it, i) => ev(it, `${b.order_no}-r${i + 1}`)), 'END:VCALENDAR'].join('\r\n');
};
// Vahvistussivu. refresh = päivitys maksun/lahjakortin jälkeen (ei spinneriä, ei fokuksen hyppyä); notice = ilmoitus maksusta; host = paluutilan paneeli (säilyy päivityksessä); noReturn = älä käynnistä ?pay=mobilepay-paluuta uudelleen.
async function viewConfirmation({ refresh = false, notice = null, host = null, noReturn = false } = {}) {
  const [token, sub] = location.hash.slice(1).split('?')[0].split('/');
  if (!/^[0-9a-f-]{36}$/i.test(token)) { mount(errorBox(t.notFound)); return; }
  stopHold();
  if (!refresh) spinner();
  let b; try { b = await rpc('public_get_booking', { p_token: token }); } catch { mount(errorBox(t.loadError), phoneBox()); return; }
  if (!b?.ok) { mount(errorBox(t.notFound), phoneBox()); return; }
  if (sub === 'muuta' && b.can_change) return isTreatmentBooking(b) ? viewTreatmentChange(token, b) : viewChange(token, b);
  const { main: it, ritual: ritItems } = splitItems(b.items);   // booking_166: vuoron rivi ensin, rituaali omana rivinään
  const stMap = await loadStatic(), ritEn = new Map(ritItems.map((x) => [+x.product_id, stMap.get(+x.product_id)?.name_en || null]));
  const sp = stMap.get(+it.product_id), prodName = (S.lang === 'en' && sp?.name_en) || it.product_name;   // englanniksi kb-nimi (palvelin palauttaa suomenkielisen)
  const co = normCheckout(b);   // §17: null = vanha backend / ei pitotilaa → vanha näkymä muuttumattomana
  const holdV = isHoldView(co);
  const head = holdV ? ht(S.lang, { awaiting_payment: 'status.awaiting', processing_payment: 'status.processing', preliminary: 'status.preliminary', expired: 'status.expired' }[co.state]) : { confirmed: t.confConfirmed, pending: t.confPending, cancelled: t.confCancelled, expired: t.confExpired }[b.status] || b.status;
  // Maksutavat (MobilePay, lahjakortti) samoista moduuleista kuin tilaussivulla; virhe / puuttuva RPC → null (ei maksuosiota, vanha näkymä). Paluu MobilePaysta (?pay=mobilepay) tarvitsee mp-rajapinnan aina.
  const canPay = ['confirmed', 'pending'].includes(b.status) && b.payment_status !== 'paid' && !(co && (co.preliminary || co.expired || co.cancelled));   // alustavaa/vanhentunutta varausta ei makseta (order_preliminary / order_expired)
  const L = S.lang === 'en' ? 'en' : 'fi';
  const payQ = new URLSearchParams(location.search).get('pay');
  const retPay = ['online', 'mobilepay', 'vismapay'].includes(payQ) && !noReturn;
  const model = canPay || retPay ? await loadPayChoices({ rpc, token, fetchImpl: MOCK_FETCH }).catch(() => null) : null;
  const online = !!model && canPay && onlineAvailable(model);   // verkkomaksutapa tarjolla → ei oleteta "maksu paikan päällä"
  const pay = { paid: t.paid, unpaid: online ? pt(L, 'unpaidOnline') : t.unpaid, pending: t.pending, partially_paid: pt(L, 'partlyPaid') }[b.payment_status] || b.payment_status;
  const out = h('div', { id: 'bk-cancel-msg', 'aria-live': 'polite' });
  const holdHost = h('div', { 'data-testid': 'hold-host' });
  const mpHost = host || h('div', { 'data-testid': 'mp-result', 'aria-live': 'polite' });
  // Valittu hoito (booking_50): items[].option {code,name,name_en}; null + tuote vaatii valinnan (vanha varaus) → "valitsematta" + ohje muuttaa varausta
  const ox = OPT[S.lang] || OPT.fi;
  let optRow = null, optNote = null;
  if (it.option) optRow = optName(it.option, S.lang);
  else if (isTreatmentBooking(b)) {
    await ensureTreatments();
    const tp = state.treatments.find((x) => x.id === +it.product_id);
    if (tp && needsOption(tp)) { optRow = ox.notChosen; optNote = ox.notChosenConfirm; }
  }
  const pageKind = confirmPageKind(b, co, paysByInvoice(b));
  const pageTitle = { finish: t.finishTitle, cancelled: t.confCancelled, expired: t.confExpired, preliminary: ht(S.lang, 'status.preliminary') }[pageKind];
  if (pageTitle) {
    const h1 = document.querySelector('main .hero.page h1');
    if (h1) h1.textContent = pageTitle;
    const rest = document.title.includes(' | ') ? document.title.split(' | ').slice(1).join(' | ') : 'Sipoonjoen Perinnesauna';
    document.title = `${pageTitle} | ${rest}`;
    document.querySelector('meta[property="og:title"]')?.setAttribute('content', document.title);
  }
  const swimKey = (b.status === 'confirmed' || co?.confirmed) ? swimwearKey(sp?.slug) : null;
  const unpaidEnd = ['cancelled', 'expired'].includes(b.status) && !['paid', 'refunded', 'partially_refunded'].includes(b.payment_status) && !paysByInvoice(b);
  const dl = h('dl', { class: 'bk-sum' },
    h('dt', { text: t.order }), h('dd', { text: String(b.order_no) }), h('dt', { text: t.what }), h('dd', { text: prodName }),
    optRow ? [h('dt', { text: ox.what }), h('dd', { 'data-testid': 'conf-option', class: it.option ? '' : 'bk-opt-missing', text: optRow })] : null,
    h('dt', { text: t.when }), h('dd', { text: `${dayLong(it.starts_at)}, ${hm(it.starts_at)}–${hm(it.ends_at)}` }), h('dt', { text: t.persons }), h('dd', { text: String(it.persons) }),
    (b.addons || []).flatMap((a) => [h('dt', { text: (S.lang === 'en' && a.name_en) || a.name }), h('dd', { text: `${a.quantity} × ${money(a.unit_price)}` })]),
    ritItems.flatMap((x) => [h('dt', { text: (S.lang === 'en' && (x.name_en || ritEn.get(+x.product_id))) || x.product_name }), h('dd', { 'data-testid': 'conf-ritual', text: `${dayLong(x.starts_at)}, ${rtx('ritualSummary', { time: fmt(x.starts_at, { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).replace('.', ':'), n: x.persons })} · ${money(x.line_total)}` })]),
    h('dt', { text: t.total }), h('dd', { text: `${money(b.total)} (${t.vatIncl})` }), h('dt', { text: t.payStatus }), h('dd', { text: pay }),
    holdV && co.awaiting && co.remaining > 0 ? [h('dt', { text: ht(S.lang, 'summary.remaining') }), h('dd', { 'data-testid': 'conf-remaining', text: money(co.remaining) })] : null);   // pitotilassa: maksettavaa jäljellä (lahjakorttiosuuden jälkeen)
  dl.dataset.testid = 'conf-summary';
  const actions = h('div', { class: 'bk-actions' });
  if (b.status !== 'cancelled' && b.status !== 'expired' && !holdV) {   // kalenterilisäys vasta vahvistetusta varauksesta
    const url = URL.createObjectURL(new Blob([ics(b)], { type: 'text/calendar' }));
    actions.append(h('a', { class: 'btn light', href: url, download: `varaus-${b.order_no}.ics`, text: t.addCal }));
  }
  const inv = customerInvoiceLock(b);
  if (b.status === 'confirmed' && b.can_change) actions.append(h('a', { class: 'btn gold', href: `#${token}/muuta`, text: t.changeBooking }));
  if (b.status === 'pending' && inv.showPendingCancel) actions.append(h('button', { type: 'button', class: 'btn light', onclick: async () => {
    if (!confirm(t.cancelConfirm)) return;
    const r = await rpc('public_cancel_booking', { p_token: token });
    out.replaceChildren(r.ok ? h('p', { class: 'bk-ok', text: t.cancelled }) : errorBox(t.errors[r.code] || t.cancelFail));
    if (r.ok) setTimeout(() => location.reload(), 800);
  } }, t.cancelBooking));
  if (b.status === 'pending' && inv.locked) actions.append(h('p', { class: 'bk-note', role: 'status', 'data-testid': 'invoiced-cancel-note', text: t.invoicedCancelNote }, ' ', h('a', { href: `mailto:${S.email}`, text: S.email })));
  mount(h('div', { class: `bk-conf ${b.status}` }, h('h2', { 'data-testid': 'conf-title', text: b.status === 'cancelled' ? t.confCancelled : b.status === 'expired' ? t.confExpired : b.status === 'pending' || (co && co.awaiting) ? ht(S.lang, 'h2.awaiting') : t.confTitle }), h('p', { class: 'bk-status', role: 'status', 'data-testid': 'conf-status', text: head }), holdHost, mpHost, dl,   // pitotilassa: otsikko + tilabadge → pitopaneeli → tiivis tilausyhteenveto → maksuosio (secEl lisätään yhteenvedon jälkeen)
    swimKey ? h('p', { class: 'bk-note bk-swim', 'data-testid': 'conf-swim', text: t[swimKey] }) : null,
    b.status === 'confirmed' && paysByInvoice(b) && b.payment_status !== 'paid' ? h('p', { class: 'bk-pay', text: t.companyInvoiceMethodNote }) : null,
    b.status === 'confirmed' && b.payment_status !== 'paid' && b.payment_status !== 'invoiced' && !paysByInvoice(b) && !isTreatmentBooking(b) && !online ? h('p', { class: 'bk-pay', text: t.payLater }) : null, optNote && b.status === 'confirmed' ? h('p', { class: 'bk-note', 'data-testid': 'conf-option-note', text: optNote }) : null, actions, out,
    b.status === 'confirmed' && (b.has_ritual_addon || ritItems.length) ? h('p', { class: 'bk-note', 'data-testid': 'conf-ritual-note', text: rtx('ritualConfNote') }, ' ', h('a', { href: `mailto:${S.email}`, text: S.email }))
      : b.status === 'confirmed' ? h('p', { class: 'bk-note', text: b.can_change ? t.changeInfo(b.change_hours_before, fmt(b.change_deadline, { day: 'numeric', month: 'numeric', hour: 'numeric', minute: '2-digit', hourCycle: 'h23' })) : t.changeLocked(b.change_hours_before) }, ' ', h('a', { href: `mailto:${S.email}`, text: S.email })) : null,
    unpaidEnd ? h('p', { class: 'bk-note', 'data-testid': 'conf-unpaid', text: t.unpaidCancel }) : null,
    unpaidEnd ? h('p', { class: 'bk-actions' }, h('a', { class: 'btn', 'data-testid': 'conf-retry', href: retryBookingHref(b, it, stMap), text: t.tryAgain })) : null,
    h('p', {}, h('a', { href: S.infoHref, text: t.directions }))));
  if (b.status === 'confirmed' && !inv.locked) {
    const holdMinutes = holdModeOf(model?.checkout, state.settings).minutes || 15;
    const pendingAdds = additionHoldSection({
      L, items: b.pending_additions || [], minutes: holdMinutes,
      text: { title: t.additionTitle, hold: t[oneKey('additionHold', L, { minutes: holdMinutes }, t)], expired: t.additionExpired, cancel: t.cancelAddition },
      onCancel: async (item, btn) => {
        if (btn) btn.disabled = true;
        const r = await rpc('public_cancel_addition', { p_token: token, p_item_id: item.item_id }).catch(() => null);
        if (r?.ok) { out.replaceChildren(h('p', { class: 'bk-ok', role: 'status', text: t.additionCancelDone })); viewConfirmation({ refresh: true, host: mpHost, noReturn: true }); }
        else { if (btn) btn.disabled = false; out.replaceChildren(errorBox(t.errors[r?.code] || t.cancelFail)); }
      },
    });
    if (pendingAdds) root.querySelector('.bk-conf')?.append(pendingAdds);
    root.querySelector('.bk-conf')?.append(orderUpsellSection({
      S, L, token, order: confirmationUpsellOrder(b), rpc,
      onAdded: () => viewConfirmation({ refresh: true, host: mpHost, noReturn: true }),
    }));
  }
  // Maksuosio (MobilePay + lahjakortti) toimintojen alle; ei näytetä kun paluu MobilePaysta on kesken (tulos näkyy sivun yläosassa)
  const again = (n) => viewConfirmation({ refresh: true, notice: n, host: mpHost, noReturn: true });
  let secEl = null;
  if (holdV && !(retPay && co.processing)) {   // paluu MobilePaysta + käsittely kesken: runReturn näyttää tilan itse (ei kahta viestiä)
    const gk = `bk-gift-${token}`;
    const minutes = holdModeOf(model?.checkout, state.settings).minutes;
    holdCtl = holdPanel({ L, co, minutes, giftUsed: giftWasUsed(b, (() => { try { return sessionStorage.getItem(gk) === '1'; } catch { return false; } })()), newHref: bk(''),
      fmtDate: (ms) => fmt(new Date(ms).toISOString(), { day: 'numeric', month: 'numeric', year: 'numeric' }),
      refresh: co.awaiting ? async () => { const n = await rpc('public_get_booking', { p_token: token }); return n?.ok ? normCheckout(n) : null; } : null,
      onChange: () => viewConfirmation({ refresh: true, host: mpHost, noReturn: true, notice }) });
    holdHost.append(holdCtl.node);
  }
  if (model && canPay && !retPay && !co?.processing) {
    secEl = payChoicesSection({ S, L, token, model, booking: b, notice, hold: !!co?.awaiting, onHoldError: () => holdCtl?.poll(true),
      onPayLater: () => again({ kind: 'paylater', title: t.confConfirmed, text: ht(L, 'payLater.done') }),   // booking_57: vahvistettu maksamatta → sivu latautuu uudelleen (confirmed_unpaid)
      onApplied: (text) => { try { if (co?.awaiting) sessionStorage.setItem(`bk-gift-${token}`, '1'); } catch { /* ei sessionStorage */ } again({ kind: 'gift', text }); }, onClaimed: (n) => again({ kind: 'claim', ...n }), onChanged: (n) => again({ kind: 'claim', ...n }) });
  }
  if (!secEl && notice && (notice.kind === 'gift' || notice.kind === 'paylater')) secEl = payNotice(L, notice);   // kokonaan maksettu: maksuosio poistuu, mutta ilmoitus jää
  if (secEl) { if (holdV) dl.after(secEl); else root.firstElementChild.querySelector('.bk-actions')?.before(secEl); }   // pitotilassa maksuvalinta yhteenvedon alla
  if (refresh) { const el = root.querySelector('[data-testid=pc-notice],[data-testid=vc-notice]'); if (el) { el.scrollIntoView({ block: 'center' }); el.focus({ preventScroll: true }); } else if (holdV && !retPay) holdHost.querySelector('h3')?.focus(); } else focusTop();   // pitotilan vaihtuessa fokus tilaotsikkoon
  if (retPay && model) {   // paluu maksusivulta: tilaus kysytään uudelleen; kesken oleva MobilePay/Visma täsmäytetään vielä (runReturn jää tuotuna)
    const num = (k) => { const v = +new URLSearchParams(location.search).get(k); return Number.isFinite(v) && v > 0 ? v : undefined; };
    const intervalMs = MOCK ? (num('mpinterval') || 2500) : 2500;
    const rounds = MOCK && num('mpmax') ? Math.max(1, Math.round(num('mpmax') / intervalMs)) : 8;
    if (payQ === 'mobilepay') void runReturn;
    const reconcile = payQ === 'mobilepay' ? () => model.mp.reconcile() : payQ === 'vismapay' && model.vp ? () => model.vp.reconcile() : null;
    runOnlineReturn({ host: mpHost, L, reconcile, intervalMs, rounds,
      getOrder: async () => { const n = await rpc('public_get_booking', { p_token: token }); return n?.ok ? n : null; },
      onDone: async () => { await viewConfirmation({ refresh: true, host: mpHost, noReturn: true }); } }).catch(() => {});
  }
}

async function viewTreatmentChange(token, b) {   // hoitovarauksen muutos: tuote haetaan adapterin kautta (vahvistussivulla ei ole ladattu kauppaa)
  await ensureTreatments();
  const p = state.treatments.find((x) => x.id === +b.items[0].product_id);
  if (!p) { mount(h('p', {}, h('a', { href: `#${token}`, text: t.back })), h('div', { class: 'bk-notice' }, h('p', { text: t.tr.errors.too_late }), phoneBox())); focusTop(); return; }
  return tv.viewChange(token, b, p);
}

// ---- näkymä 5: varauksen muutos (toinen vapaa vuoro samalle tuotteelle ja/tai henkilömäärä; vähintään N h ennen alkua) ----
async function viewChange(token, b) {
  const it = b.items[0];
  const hours = b.change_hours_before ?? 48;
  const minStart = Date.now() + hours * 36e5;
  const today = todayHel();
  const curDate = new Date(it.starts_at).toLocaleDateString('sv-SE', { timeZone: TZ });
  const st = { date: curDate, session: null, rows: [] };
  let n = it.persons;
  const msg = h('div', { id: 'bk-msg', 'aria-live': 'polite' });
  const sessionsBox = h('div', { class: 'bk-slots', 'aria-live': 'polite' });
  const summary = h('p', { class: 'bk-meta' });
  const inv = customerInvoiceLock(b);
  const num = h('input', { id: 'bk-n', type: 'number', min: 1, inputmode: 'numeric', 'aria-label': t.persons, disabled: inv.personsDisabled || null, onchange: () => { if (inv.personsDisabled) { n = it.persons; upd(); return; } n = +num.value || 1; clamp(); upd(); } });
  const minus = h('button', { type: 'button', class: 'bk-step', 'aria-label': '−', disabled: inv.personsDisabled || null, onclick: () => { if (inv.personsDisabled) return; n--; upd(); } }, '−');
  const plus = h('button', { type: 'button', class: 'bk-step', 'aria-label': '+', disabled: inv.personsDisabled || null, onclick: () => { if (inv.personsDisabled) return; n++; upd(); } }, '+');
  const submit = h('button', { type: 'submit', class: 'btn gold', text: t.saveChange });
  const isCur = (r) => r.rule_id === it.rule_id && r.session_date === curDate;
  const target = () => st.session || st.rows.find(isCur) || null;     // valittu vuoro tai nykyinen (jos samalla päivällä)
  const limits = () => {
    const s = target();
    if (!s) return { min: 1, max: it.persons };
    const own = isCur(s) ? it.persons : 0;
    return { min: s.min_persons, max: Math.max(s.min_persons, Math.min(s.max_persons || 50, s.remaining + own)) };
  };
  function clamp() { const { min, max } = limits(); n = Math.min(Math.max(n, min), max); }
  function upd() {
    if (inv.personsDisabled) n = it.persons;
    else clamp();
    const { min, max } = limits(); const s = target();
    num.min = min; num.max = max; num.value = n; minus.disabled = inv.personsDisabled || n <= min; plus.disabled = inv.personsDisabled || n >= max;
    if (inv.personsDisabled) num.disabled = true;
    const addonsNew = (b.addons || []).reduce((x, a) => x + Math.min(a.quantity, addonLimit(a, n)) * +a.unit_price, 0);
    const newTotal = !inv.showPriceEstimate && s ? null : (s ? priceFor(s, n) + addonsNew : null);
    const changed = !!st.session || (!inv.personsDisabled && n !== it.persons);
    summary.textContent = s ? `${dayLong(s.starts_at)}, ${hm(s.starts_at)}–${hm(s.ends_at)} · ${n} ${t.person}${inv.showPriceEstimate && newTotal != null ? ` · ${money(newTotal)}` : ''}` : '';
    const priceBlocked = inv.showPriceEstimate && b.payment_status === 'paid' && newTotal != null && Math.abs(newTotal - b.total) > 0.005;
    msg.replaceChildren(...(priceBlocked ? [h('p', { class: 'bk-note', text: t.changePaidPrice })] : []));
    submit.disabled = !changed || priceBlocked;
  }
  async function loadSessions() {
    sessionsBox.replaceChildren(h('p', { class: 'bk-loading', role: 'status', text: t.loading }));
    let rows = [];
    try { rows = (await rpc('public_availability', { p_product_id: it.product_id, p_from: st.date, p_to: st.date })) || []; } catch { sessionsBox.replaceChildren(errorBox(t.loadError)); return; }
    st.rows = rows.sort((a, c) => a.starts_at.localeCompare(c.starts_at));
    const visibleRows = st.rows.filter((r) => isCur(r) || (r.status === 'available' && new Date(r.starts_at).getTime() >= minStart));   // täynnä olevia ja myöhästyneitä ei näytetä
    sessionsBox.replaceChildren(h('h3', { text: `${t.pickSlot} – ${dayLong(`${st.date}T12:00:00Z`)}` }),
      visibleRows.length ? h('ul', { class: 'bk-slotlist', role: 'radiogroup', 'aria-label': t.pickSlot }, visibleRows.map((r) => {
        const cur = isCur(r);
        const late = new Date(r.starts_at).getTime() < minStart;
        const ok = !late && (r.status === 'available' || cur);
        const title = `${hm(r.starts_at)}–${hm(r.ends_at)}`;
        const btn = h('button', { type: 'button', role: 'radio', class: 'btn sm', 'aria-checked': (st.session ? st.session === r : cur) ? 'true' : 'false', disabled: !ok || null, onclick: () => {
          st.session = cur ? null : r; sessionsBox.querySelectorAll('[role=radio]').forEach((x) => x.setAttribute('aria-checked', 'false')); btn.setAttribute('aria-checked', 'true'); upd(); } }, cur ? t.currentSlot : t.choose, h('span', { class: 'sr', text: ` ${title}` }));
        return h('li', { class: `bk-slot ${ok ? 'available' : r.status}` }, h('div', { class: 'bk-slot-main' }, h('strong', { class: 'bk-time', text: title }), cleanLabel(rlabel(r)) ? h('span', { class: 'bk-sub', text: cleanLabel(rlabel(r)) }) : null),
          h('div', { class: 'bk-slot-side' }, h('span', { class: `bk-badge ${ok ? 'free' : late ? 'unavail' : r.status}`, text: late ? t.tooLate(hours) : ok ? t.freeSpots(cur ? r.remaining + it.persons : r.remaining) : r.status === 'full' ? t.full : t.unavailable }), btn));
      })) : h('p', { text: t.noSlots }));
    upd();
  }
  const horizon = state.settings?.booking_horizon_days || 120;
  const maxDate = new Date(Date.now() + horizon * 864e5).toLocaleDateString('sv-SE', { timeZone: TZ });
  const dateIn = h('input', { id: 'bk-date', type: 'date', value: st.date, min: today, max: maxDate, onchange: async (e) => { if (!e.target.value) return; st.date = e.target.value; st.session = null; await loadSessions(); revealForm(sessionsBox, sessionsBox.querySelector('h3') || sessionsBox); } });
  const form = h('form', { class: 'bk-form', novalidate: true, onsubmit: async (ev) => {
    ev.preventDefault(); msg.replaceChildren(); submit.disabled = true; submit.textContent = t.saving;
    try {
      const args = { p_token: token };
      if (st.session) { args.p_rule_id = st.session.rule_id; args.p_date = st.date; }
      if (!inv.personsDisabled && n !== it.persons) args.p_persons = n;
      const r = await rpc('public_change_booking', args);
      if (!r.ok) throw Object.assign(new Error((r.code === 'order_invoiced' ? t.errors.order_invoiced_persons : t.errors[r.code]) || t.errorGeneric), { code: r.code, mapped: true });
      state.months.clear();
      location.hash = token; window.scrollTo({ top: 0 });
    } catch (e) {
      submit.textContent = t.saveChange; upd();
      msg.replaceChildren(errorBox(e.mapped ? e.message : t.errorGeneric)); msg.firstChild.setAttribute('tabindex', '-1'); revealIfHidden(msg); msg.firstChild.focus({ preventScroll: true });
      if (['capacity_exceeded', 'private_booked', 'public_shift_booked', 'space_closed'].includes(e.code)) loadSessions();
    }
  } }, h('fieldset', {}, h('legend', { text: t.persons }), h('div', { class: 'bk-stepper' }, minus, num, plus),
    inv.personsDisabled ? h('p', { class: 'bk-note', 'data-testid': 'invoiced-persons-note', text: t.invoicedPersonsNote }) : null), summary,
    inv.locked ? h('p', { class: 'bk-note', 'data-testid': 'invoiced-sum-note', text: t.invoicedSumNote }) : null, msg, submit);
  mount(h('p', {}, h('a', { href: `#${token}`, text: t.back })), h('h2', { text: t.changeTitle }),
    h('p', { class: 'bk-note', text: t.changeInfo(hours, fmt(b.change_deadline, { day: 'numeric', month: 'numeric', hour: 'numeric', minute: '2-digit', hourCycle: 'h23' })) }),
    h('dl', { class: 'bk-sum' }, h('dt', { text: t.what }), h('dd', { text: it.product_name }), h('dt', { text: t.when }), h('dd', { text: `${dayLong(it.starts_at)}, ${hm(it.starts_at)}–${hm(it.ends_at)}` }), h('dt', { text: t.persons }), h('dd', { text: String(it.persons) })),
    h('div', { class: 'bk-field' }, h('label', { for: 'bk-date', text: t.pickDate }), dateIn), sessionsBox, form);
  await loadSessions(); focusTop();
}

// ---- hoito- ja rituaalivaraukset: käyttöliittymä saa tarvitsemansa apurit täältä (luodaan vasta kun kaikki on määritelty) ----
const tv = createTreatmentViews({ h, t, S, state, money, fmt, hm, dayLong, pad2, todayHel, addDays, pname, pdesc, pimg, setHero, mount, focusTop, errorBox, phoneBox, bk, customerFields, legalFields, setLast: () => { last = location.hash; }, holdInfo, tx: texts.tx, confirmUrl: (token) => `${S.confirmHref}${mockQs()}#${token}` });

const wv = createWaitlistView({ h, t, S, state, loadMonth, setHero, mount, focusTop, errorBox, phoneBox, bk, rpc, pname, dayLong, hm });

// ---- reititin ----
async function route(keep = false) {
  stopHold();
  root.setAttribute('aria-busy', 'true');
  try {
    if (S.page === 'confirm') return await viewConfirmation();
    if (!keep) spinner();
    await loadBase();
    // Jonotuslistalta poistuminen sähköpostin linkistä (?poistu_jonosta=<token>). Ajetaan loadBase:n jälkeen,
    // jotta sivutekstit ovat käytössä; parametri poistetaan osoitteesta, ettei poisto toistu seuraavilla reiteillä.
    const sp = new URLSearchParams(location.search), leaveToken = sp.get('poistu_jonosta');
    if (leaveToken !== null) {
      sp.delete('poistu_jonosta');
      history.replaceState(null, '', `${location.pathname}${sp.toString() ? `?${sp}` : ''}${location.hash}`);
      if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(leaveToken)) {
        try {
          const ans = await rpc('public_leave_waitlist', { p_token: leaveToken });
          mount(h('div', { class: ans?.ok ? 'bk-ok' : 'bk-error', role: 'status', text: ans?.ok ? t.waitlistLeft : t.errorGeneric }),
            h('p', {}, h('a', { href: bk('/'), text: t.waitlistBack })));
        } catch { mount(errorBox(t.errorGeneric)); }
        focusTop(); last = location.hash; return;
      }
    }
    if (state.settings.public_booking_enabled === false) { mount(h('div', { class: 'bk-notice' }, h('p', { text: t.disabled }), phoneBox())); return; }
    const [path, qs] = location.hash.slice(1).split('?');
    const parts = path.split('/').filter(Boolean);
    const q = new URLSearchParams(qs || '');
    if (!(parts[0] === 'tuote' && parts[1]) && !(parts[0] === 'varaa' && parts[1] && parts[2]) && !(parts[0] === 'hoito' && parts[1])) setHero(null);   // tuote- ja lomakenäkymä asettavat heron itse
    if (parts[0] === 'vuosikortti') await viewAnnualPurchase();
    else if (parts[0] === 'paiva') await viewDay(parts[1], keep, q.get('tuote'));
    else if (parts[0] === 'tuote' && parts[1]) await viewProduct(parts[1], /^\d{4}-\d\d-\d\d$/.test(parts[2] || '') ? parts[2] : null, q);
    else if (parts[0] === 'hoito' && parts[1]) { const tp = state.treatments.find((x) => x.slug === parts[1]); if (tp) await tv.viewCheckout(tp, parts[2], parts[3], q); else await viewProduct(parts[1], null, q); }
    else if (parts[0] === 'varaa' && parts[1] && parts[2]) await viewCheckout(parts[1], parts[2], parts[3], q.get('via'));
    else if (parts[0] === 'jono' && parts[1] && parts[2] && parts[3]) await wv.viewWaitlist(parts[1], parts[2], parts[3], q.get('via'));
    else { viewList(q); focusTop(); }
  } catch (e) {
    console.warn('booking route error', e);
    mount(errorBox(t.loadError), phoneBox());
  } finally { document.documentElement.classList.remove('bk-hero-wait'); restoreDraft(root); }
}
if (S.otherHref) bindLangLinks(S.otherHref);
let last = '';
window.addEventListener('hashchange', () => {
  // päivän valinta kalenterissa vaihtaa hashin ilman uudelleenpiirtoa (replaceState ei laukaise tapahtumaa); muut siirtymät piirretään uudelleen
  if (location.hash !== last) {
    const keep = /^#\/paiva\b/.test(last) && /^#\/paiva\b/.test(location.hash);   // päivänvaihto päivänäkymässä: ei hypätä sivun alkuun
    last = location.hash; route(keep); if (!keep) window.scrollTo({ top: 0 });
  }
});
last = location.hash;
// booking_162: hiljaisten aikojen ale -merkinnät jokaisen piirron jälkeen (ks. quietDecorate). Ei tarjouksia → ei muutoksia.
let quietTimer = null;
if (root && typeof MutationObserver === 'function') new MutationObserver(() => { clearTimeout(quietTimer); quietTimer = setTimeout(() => { quietDecorate().catch(() => {}); }, 0); }).observe(root, { childList: true, subtree: true });
route();
