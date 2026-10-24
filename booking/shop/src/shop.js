// Varauskauppa: tuote → päivä/vuoro → henkilömäärä → yhteystiedot → vahvistus. Vaihtoehtoinen selaus: päivän mukaan (#/paiva/<pvm>) → kaikki päivän vuorot. Vanilla JS, ei riippuvuuksia, ei build-vaihetta.
// Data tulee vain julkisista RPC-funktioista (public_catalog / public_product_images / public_availability / public_create_booking / public_get_booking / public_change_booking).
// Asiakas ei voi itse perua vahvistettua varausta (peruutukset sähköpostilla henkilökunnalle); hän voi MUUTTAA varausta (toinen vuoro / henkilömäärä) asetuksen mukaan vähintään 48 h ennen vuoroa.
import { rpc, storageUrl, setRpcOverride } from './sb.js';
import { ensureAllMonths } from './availability-months.js';
import { runReturn } from './mobilepay-ui.js';
import { loadPayChoices, payChoicesSection, payNotice, onlineAvailable, onlineAtCheckout } from './pay-choices.js';
import { pt } from './pay-choices-texts.js';
import { T } from './i18n.js';
import { createWaitlistView } from './waitlist-ui.js';
import { visibleWaitlistSlots, fullyBooked, hasWaitlistSlots } from './waitlist-logic.js';
import { loadProducts as loadTreatmentProducts, splitCatalog, isListed as treatmentListed, isTreatmentBooking, loadAvailability as loadTreatmentSlots, horizonDays as treatmentHorizon, timeToken as treatmentTimeToken, isRetryable as treatmentRetryable } from './treatments.js';
import { pickCatalog } from './catalog-audience.js';
import { heroShort, cardShort, fallbackDesc } from './short-desc.js';
import { createTreatmentViews } from './treatment-ui.js';
import { createTexts, loadShopTexts, applyShopTexts } from './site-texts.js';
import { fmtMinutes } from './site-texts-logic.js';
import { OPT } from './options-texts.js';
import { optName, needsOption, findOption } from './options-logic.js';
import { ht, holdError, methodList } from './hold-texts.js';
import { normCheckout, isHoldView, holdModeOf, giftWasUsed } from './hold-logic.js';
import { holdPanel } from './hold-ui.js';
import { normBusinessId, validBusinessId, normOvt, validOvt, validOperator } from './invoice-validate.js';
import { isRichHtml } from './rich-text.js';
import { visibleText, richHost } from './rich-view.js';
import { revealForm, revealIfHidden } from './gift-ui.js';
import { normalizeCode, quoteSignature, isAnnualQuote, isCodeError } from './discount-code-logic.js';

const S = window.BOOKING_SHOP;                   // build-aikainen konfiguraatio (kieli, polut, ei-verkossa-varattavat tuotteet)
const t = T[S.lang] || T.fi;
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
const hm = (iso) => fmt(iso, { hour: 'numeric', minute: '2-digit', hourCycle: 'h23' }).replace('.', ':').replace(/:00$/, '');
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
const pname = (p) => (S.lang === 'en' && p.name_en) || p.name;
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
const kindOf = (p) => (p.treatment ? 'hoito' : p.sale_kind === 'public_shift' ? 'yleinen' : p.sale_kind === 'private_shift' ? 'yksityinen' : 'muut');
// ?mock=1: kokeilutila (EI palvelinta): kaikki RPC-kutsut vastataan selaimessa (shop-mock.js; ei tallenna mitään palvelimelle). Lippu säilytetään linkeissä.
const MOCK = new URLSearchParams(location.search).get('mock') === '1';
let MOCK_FETCH;   // ?mock=1&scenario=pay: mobilepay-start / mobilepay-notify -funktioiden mock (fetch-yhteensopiva)
if (MOCK) { const sm = (await import('./shop-mock.js')).createShopMock({ fail: new URLSearchParams(location.search).get('fail'), scenario: new URLSearchParams(location.search).get('scenario') || '', mpResult: new URLSearchParams(location.search).get('mpresult') || '' }); setRpcOverride(sm.rpc); MOCK_FETCH = sm.mpFetch; }
// Mock-tilan parametrit säilyvät linkeissä ja ohjauksissa (scenario=hold… toimii koko kulun läpi kassalta vahvistussivulle)
const mockQs = () => { if (!MOCK) return ''; const cur = new URLSearchParams(location.search), q = new URLSearchParams({ mock: '1' }); for (const k of ['scenario', 'mpresult', 'mpinterval', 'mpmax', 'holdsec', 'fail']) if (cur.has(k)) q.set(k, cur.get(k)); return `?${q}`; };
const bk = (hash) => `${S.shopHref}${mockQs()}#${hash}`;
// Kassan pitotila ja maksutavat yhdestä paikasta (vuoro- ja hoitokassa): palvelin (public_checkout_payment_options) päättää, ei kovakoodata. Virhe → vanha käytös.
const holdInfo = () => loadPayChoices({ rpc, fetchImpl: MOCK_FETCH }).then((m) => {
  const hv = holdModeOf(m.checkout, state.settings);
  const codes = [m.opts?.method && (m.opts.method.test !== true || m.env.testUi) ? 'mobilepay' : null, m.redeem ? 'gift_card' : null].filter(Boolean);
  return { on: hv.on, minutes: hv.minutes, legacyHold: !!hv.legacy, codes, unavailable: !!(m.checkout?.ok && !m.checkout.method && !m.redeem), onlineSite: onlineAtCheckout(m),
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
// Tuotekuva: kiinteä kuvasuhde (varaa tilan → ei layout-hyppyä), lazy-lataus, alt = ylläpidon alt-teksti tai tuotteen nimi.
// alt=false → koriste (nimi on jo vieressä tekstinä). Rikkinäinen kuva poistetaan kokonaan (ei rikkinäistä kuvaketta).
// Palauttaa null jos tuotteella ei ole kuvaa.
const pimg = (p, cls, { alt = true, eager = false, w = 600, hgt = 400 } = {}) => {
  const i = state.images.get(p.id); if (!i) return null;
  const im = h('img', { src: i.url, alt: alt ? (i.alt || pname(p)) : '', width: w, height: hgt, loading: eager ? 'eager' : 'lazy', decoding: 'async' });
  const box = h('span', { class: `bk-img ${cls}` }, im);
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
    const im = h('img', { src: i.url, alt: i.alt || '', width: 1600, height: 1000, fetchpriority: 'high', decoding: 'async' });
    next = h('picture', { class: 'prod-pic' }, im);
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
  const kinds = ['all', ...new Set(cat.map(kindOf))];
  const k = kinds.includes(query.get('k')) ? query.get('k') : 'all';
  const list = cat.filter((p) => k === 'all' || kindOf(p) === k);
  const tabs = h('nav', { class: 'bk-tabs', 'aria-label': t.title }, kinds.map((x) => h('a', { href: bk(`/?k=${x}`), 'aria-current': x === k ? 'true' : null, text: t['k_' + x] || t[x] || x })));
  const cards = h('ul', { class: 'bk-cards' }, list.map((p) => p.treatment ? tv.card(p) : h('li', { class: 'bk-card' },
    pimg(p, 'card-img'),
    h('h3', {}, h('a', { href: bk(`/tuote/${p.slug}`), text: pname(p) })),
    cardExcerpt(p),
    h('p', { class: 'bk-meta' }, h('strong', { text: priceText(p) }), pdur(p) ? ` · ${pdur(p)}` : ''),
    h('a', { class: 'btn sm', href: bk(`/tuote/${p.slug}`) }, t.choose, h('span', { class: 'sr', text: ' – ' + pname(p) })))));
  const annual = annualPromo();
  mount(h('header', { class: 'bk-head' }, h('h2', { text: t.title }), h('p', { class: 'lead', text: t.lead })), modeSwitch('cat'), tabs, cards, annual);
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
      withName ? h('span', { class: 'bk-prodname' }, h('a', { href: bk(`/tuote/${p.slug}/${ds}`), text: pname(p) })) : null, sub ? h('span', { class: 'bk-sub', text: sub }) : null, h('span', { class: 'bk-price', text: price })),
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
      h('span', { class: 'bk-pc-meta' }, h('span', { class: 'bk-price', text: priceText(p) }), fullOnly ? h('span', { class: 'bk-badge full', text: t.waitlistSoldOut }) : h('span', { class: 'bk-badge free', text: `${t.timesFree(avail.length)}${avail.length ? ` · ${t.firstAt} ${hm(avail[0].r.starts_at)}` : ''}` }))),
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
      : h('a', { class: `bk-sd ${st}${x === today ? ' today' : ''}${x === ds ? ' sel' : ''}`, href: bk(`/paiva/${x}`), 'aria-label': label, 'aria-current': x === ds ? 'date' : null }, inner));
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
  const groups = ['yleinen', 'yksityinen', 'muut'].map((k) => [k, prods.filter(([p]) => kindOf(p) === k)])
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
      h('p', { class: 'bk-legend' }, h('span', { class: 'dot free' }), t.free, ' ', h('span', { class: 'dot full' }), t.full, ' ', h('span', { class: 'dot unavail' }), t.unavailable), tools),
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
    wrap.replaceChildren(
      h('p', {}, h('a', { href: bk('/'), text: t.backList })),
      richHost(h, pdesc(p) || '', 'bk-desc'),
      h('p', { class: 'bk-meta' }, h('strong', { text: priceText(p) }), pdur(p) ? ` · ${pdur(p)}` : ''),
      h('h3', { text: t.pickDate }), calBox, slotBox);
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
        : h('button', { type: 'button', class: `bk-cell ${st}${ds === today ? ' today' : ''}${ds === sel ? ' sel' : ''}`, 'aria-pressed': ds === sel ? 'true' : 'false', 'aria-label': label, onclick: () => { sel = ds; history.replaceState(null, '', bk(`/tuote/${slug}/${ds}`)); drawSlots(); markSel(); revealForm(slotBox, slotBox.querySelector('h3')); } }, d));
    }
    calBox.append(nav, h('div', { class: 'bk-grid', role: 'group', 'aria-label': monthName }, wd, cells),
      h('p', { class: 'bk-legend' }, h('span', { class: 'dot free' }), t.free, ' ', h('span', { class: 'dot full' }), t.full, ' ', h('span', { class: 'dot unavail' }), t.unavailable),
      ...(any ? [] : [h('p', { class: 'bk-note', text: t.noSlotsMonth })]));
    const markSel = () => calBox.querySelectorAll('.bk-cell[aria-pressed]').forEach((b) => { const on = b.textContent === String(+sel?.slice(8)) && sel?.startsWith(`${y}-${pad2(m + 1)}`); b.classList.toggle('sel', on); b.setAttribute('aria-pressed', on ? 'true' : 'false'); });
    const drawSlots = () => {
      if (!sel) { slotBox.replaceChildren(); return; }
      const rows = visibleWaitlistSlots(byDay[sel] || []);   // vapaat ensin, loppuunmyydyt lopuksi
      slotBox.replaceChildren(h('h3', { text: `${t.pickSlot} – ${dayLong(`${sel}T12:00:00Z`)}` }),
        rows.length ? h('ul', { class: 'bk-slotlist' }, rows.map((r) => slotItem(r, sel, p))) : h('p', { text: t.noSlots }));
    };
    drawSlots();
  };
  mount(wrap); await draw(); if (!dateStr) focusTop();
}
function slotItem(r, ds, p) {
  const ok = r.status === 'available';
  const title = `${hm(r.starts_at)}–${hm(r.ends_at)}`;
  const sub = cleanLabel(rlabel(r));
  const price = r.price_mode === 'per_person' ? `${money(r.unit_price)} ${t.perPerson}` : r.price_mode === 'fixed' ? money(r.base_price)
    : `${money(r.base_price)} (${t.included(r.included_persons)}, ${t.extra(money(r.extra_person_price))})`;
  return h('li', { class: `bk-slot ${r.status}` },
    h('div', { class: 'bk-slot-main' }, h('strong', { class: 'bk-time', text: title }), sub ? h('span', { class: 'bk-sub', text: sub }) : null, h('span', { class: 'bk-price', text: price })),
    h('div', { class: 'bk-slot-side' },
      ok ? h('span', { class: 'bk-badge free', text: t.freeSpots(r.remaining) }) : h('span', { class: 'bk-badge full', text: t.waitlistSessionSoldOut }),
      ok ? h('a', { class: 'btn sm', href: bk(`/varaa/${r.rule_id}/${ds}/${p.id}`) }, t.choose, h('span', { class: 'sr', text: ` ${title}` })) : h('a', { class: 'btn sm light bk-waitlist-link', href: bk(`/jono/${r.rule_id}/${ds}/${p.id}`), text: t.waitlistJoinShort })));
}

// ---- jaetut lomakeosat (vuorovaraus + hoitovaraus) ----
const field = (id, label, { hint, ...attrs } = {}) => h('div', { class: 'bk-field' }, h('label', { for: id, text: label }), h('input', { id, name: id, required: true, 'aria-describedby': hint ? `${id}-hint` : null, ...attrs }), hint ? h('small', { class: 'bk-hint', id: `${id}-hint`, text: hint }) : null);
const opt = (id, label, attrs) => field(id, label, { required: false, ...attrs });
// Asiakastiedot: yksityinen / yritys + nimi, sähköposti, puhelin. read(form, msg) validoi (virhe → msg + fokus, palauttaa null) ja palauttaa { kind, name, email, phone, company }.
function customerFields() {
  let kind = 'private';
  const kindInputs = [['private', t.kindPrivate], ['company', t.kindCompany]].map(([k, label]) => h('label', { class: 'bk-kind' }, h('input', { type: 'radio', name: 'kind', value: k, checked: k === 'private' || null, onchange: () => setKind(k) }), ' ', label));
  const nameLabel = h('label', { for: 'name', text: t.name });
  const companyBox = h('fieldset', { class: 'bk-company', id: 'bk-company', hidden: true },
    h('legend', { text: t.companyTitle }),
    field('company_name', t.companyName, { maxlength: 200, autocomplete: 'organization' }), field('business_id', t.businessId, { maxlength: 20, inputmode: 'numeric', placeholder: '1234567-8', hint: t.businessIdHint }),
    field('street', t.street, { maxlength: 200, autocomplete: 'street-address' }),
    h('div', { class: 'bk-row2' }, field('zip', t.zip, { maxlength: 5, inputmode: 'numeric', autocomplete: 'postal-code' }), field('city', t.city, { maxlength: 100, autocomplete: 'address-level2' })),
    h('h4', { text: t.einvoiceTitleRequired }),
    field('einvoice_address', t.einvoiceAddress, { maxlength: 40 }), field('einvoice_operator', t.einvoiceOperator, { maxlength: 40, hint: t.einvoiceHintRequired }),
    opt('reference', t.buyerReference, { maxlength: 100 }),
    h('p', { class: 'bk-note', text: t.companyInvoiceNote }));
  function setKind(k) {
    kind = k; companyBox.hidden = k !== 'company'; if (k === 'company') revealIfHidden(companyBox); nameLabel.textContent = k === 'company' ? t.contactName : t.name;
    for (const id of ['company_name', 'business_id', 'street', 'zip', 'city', 'einvoice_address', 'einvoice_operator']) { const el = document.getElementById(id); if (el) el.required = k === 'company'; }
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
      if (!val('einvoice_address') || !val('einvoice_operator')) { msg.append(errorBox(t.einvoiceBoth)); form.einvoice_address.focus(); return null; }
      if (!validOvt(val('einvoice_address'), val('business_id'))) { msg.append(errorBox(t.invalidOvt)); form.einvoice_address.focus(); return null; }
      if (!validOperator(val('einvoice_operator'))) { msg.append(errorBox(t.einvoiceBoth)); form.einvoice_operator.focus(); return null; }
      company = { company_name: val('company_name'), business_id: normBusinessId(val('business_id')), street: val('street'), zip: val('zip'), city: val('city'),
        einvoice_address: normOvt(val('einvoice_address')), einvoice_operator: normOvt(val('einvoice_operator')), reference: val('reference') || null, require_einvoice: true };
    }
    return { kind, name: val('name'), email: val('email'), phone: val('phone'), company };
  };
  return { node, read, kind: () => kind };
}
// Lisätiedot, ehdot ja markkinointisuostumus (nodes: lomakkeeseen järjestyksessä; terms/consent: valintaruudut)
function legalFields() {
  const terms = h('input', { type: 'checkbox', id: 'bk-terms', required: true });
  const consent = h('input', { type: 'checkbox', id: 'bk-consent' });
  const nodes = [h('div', { class: 'bk-field' }, h('label', { for: 'note', text: t.note }), h('textarea', { id: 'note', name: 'note', rows: 3, maxlength: 1000 })),
    h('div', { class: 'bk-check' }, terms, h('label', { for: 'bk-terms' }, t.acceptTerms + ' ', h('a', { href: S.termsHref, target: '_blank', rel: 'noopener', text: t.termsLink }), ' *')),
    h('div', { class: 'bk-check' }, consent, h('label', { for: 'bk-consent', text: t.consentMarketing }))];
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
  const addonsSum = () => addons.reduce((x, a) => x + qty.get(a.id) * +a.price, 0);
  // Alennus- / vuosikorttikoodi (booking_142): palvelin laskee hinnan (public_check_code); quote = viimeisin hyväksytty vastaus
  // ja sig = henkilömäärä + lisäpalvelut, joille se laskettiin. Vuosikortti lukitsee henkilömäärän ja poistaa lisäpalvelut.
  const code = { value: '', quote: null, sig: '', timer: null };
  const sig = () => quoteSignature(n, addons.map((a) => qty.get(a.id)));
  const annualOn = () => isAnnualQuote(code.quote);
  const locked = () => wlLock || annualOn();
  const upd = () => {
    if (annualOn()) { n = +code.quote.persons || 1; for (const a of addons) qty.set(a.id, 0); }
    for (const a of addons) qty.set(a.id, Math.min(qty.get(a.id), addonLimit(a, n)));
    if (code.quote && !annualOn() && code.sig !== sig()) recheckCode();
    const fresh = code.quote && code.sig === sig();
    total.textContent = money(fresh ? +code.quote.total : priceFor(s, n) + addonsSum());
    sumList.replaceChildren(h('dt', { text: t.what }), h('dd', { text: pname(p) }), h('dt', { text: t.when }), h('dd', { text: `${dayLong(s.starts_at)}, ${hm(s.starts_at)}–${hm(s.ends_at)}` }), h('dt', { text: t.persons }), h('dd', { text: String(n) }),
      ...addons.filter((a) => qty.get(a.id) > 0).flatMap((a) => [h('dt', { text: aname(a) }), h('dd', { text: `${qty.get(a.id)} × ${money(a.price)}` })]),
      ...(fresh && +code.quote.discount > 0 ? [h('dt', { text: annualOn() ? t.annualTitle : t.codeDiscountRow }), h('dd', { 'data-testid': 'checkout-discount', text: `${code.quote.code} · −${money(code.quote.discount)}` })] : []));
    num.value = n; minus.disabled = wlLock || annualOn() || n <= s.min_persons; plus.disabled = wlLock || annualOn() || n >= max; num.readOnly = wlLock || annualOn();
    for (const r of addonRows) r.sync();
    submitLabel();
    payNote.hidden = payExtra.hidden = free();   // maksuton varaus: ei maksuohjetta
  };
  const num = h('input', { id: 'bk-n', type: 'number', min: s.min_persons, max, inputmode: 'numeric', 'aria-label': t.persons, onchange: () => { if (locked()) { upd(); return; } n = Math.min(Math.max(+num.value || s.min_persons, s.min_persons), max); upd(); } });
  const minus = h('button', { type: 'button', class: 'bk-step', 'aria-label': '−', onclick: () => { n--; upd(); } }, '−');
  const plus = h('button', { type: 'button', class: 'bk-step', 'aria-label': '+', onclick: () => { n++; upd(); } }, '+');
  const cf = customerFields();
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
  const msg = h('div', { id: 'bk-msg' });
  const hm0 = holdModeOf(null, state.settings);   // oletus asetuksesta (vain luku); palvelimen public_checkout_payment_options päivittää alla
  const hmode = { on: false, minutes: hm0.minutes };   // uusi pitotila vain kun palvelin sanoo (hold_until_paid); asetus ohjaa vain vanhaa ohjetekstiä
  const submit = h('button', { type: 'submit', class: 'btn gold', 'data-testid': 'checkout-submit', text: hmode.on ? ht(S.lang, 'checkout.button') : t.book });
  const legal = legalFields(), { terms, consent } = legal;
  // Ilmainen (vuosikortti tai 100 % koodi) → "Vahvista varaus"; muuten ennallaan.
  const free = () => !!code.quote && code.sig === sig() && +code.quote.total === 0;
  const submitLabel = () => { if (!submit.disabled) submit.textContent = free() ? t.codeConfirm : hmode.on ? ht(S.lang, 'checkout.button') : t.book; };
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
    const chosen = addons.filter((a) => qty.get(a.id) > 0).map((a) => ({ id: a.id, quantity: qty.get(a.id) }));
    let r = null;
    try {
      r = await rpc('public_check_code', { p_code: v, p_rule_id: s.rule_id, p_date: ds, p_persons: n, p_addons: chosen.length ? chosen : null,
        p_email: String(fd.get('email') || '').trim() || null, p_phone: String(fd.get('phone') || '').trim() || null });
    } catch { r = { ok: false, code: 'generic' }; }
    codeApply.disabled = false;
    if (!r?.ok) { code.value = ''; code.quote = null; code.sig = ''; codeInput.readOnly = false; codeApply.hidden = false; codeRemove.hidden = true; setStatus(t.codeErrors[r?.code] || t.codeErrors.generic, false); upd(); return; }
    code.value = v; code.quote = r;
    if (isAnnualQuote(r)) { n = +r.persons || 1; for (const a of addons) qty.set(a.id, 0); }
    code.sig = sig();
    codeInput.readOnly = true; codeApply.hidden = true; codeRemove.hidden = false;
    setStatus(isAnnualQuote(r) ? `${t.codeAnnualApplied} ${t.codeAnnualLocked}${r.type === 'annual_card' ? ' ' + t.codeAnnualOwner : ''}` : `${t.codeApplied}: ${r.code} · −${money(r.discount)}`, true);
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
    if (!terms.checked) { msg.append(errorBox(t.acceptTermsErr)); revealIfHidden(msg); terms.focus({ preventScroll: true }); return; }
    const wasFree = free();
    submit.disabled = true; submit.textContent = wasFree ? t.codeConfirming : hmode.on ? ht(S.lang, 'checkout.creating') : t.booking;
    try {
      const chosen = addons.filter((a) => qty.get(a.id) > 0).map((a) => ({ id: a.id, quantity: qty.get(a.id) }));
      const args = { p_rule_id: s.rule_id, p_date: ds, p_persons: n, p_name: cust.name, p_email: cust.email, p_phone: cust.phone, p_marketing_consent: consent.checked, p_locale: S.lang, p_note: (f.get('note') || '').trim() || null,
        p_customer_kind: cust.kind, p_company: cust.company, p_addons: chosen.length ? chosen : null };
      // Koodi vain kun se on hyväksytty: muuten sama public_create_booking kuin ennen (booking_142 ei muuta sitä).
      const r = code.value ? await rpc('public_create_booking_code', { ...args, p_code: code.value }) : await rpc('public_create_booking', args);
      if (!r.ok) throw Object.assign(new Error((isCodeError(r.code) && t.codeErrors[r.code]) || holdError(S.lang, r.code) || t.errors[r.code] || t.errorGeneric), { code: r.code, mapped: true });
      state.months.clear();
      location.assign(`${S.confirmHref}${mockQs()}#${r.token}`);
    } catch (e) {
      submit.disabled = false; submitLabel();
      msg.replaceChildren(errorBox(e.mapped ? e.message : t.errorGeneric));   // palvelimen raaka message ei koskaan asiakkaalle (ui.shop.error_generic)
      if (['capacity_exceeded', 'private_booked', 'public_shift_booked', 'space_closed'].includes(e.code)) state.months.clear();
      msg.firstChild.setAttribute('tabindex', '-1'); revealIfHidden(msg); msg.firstChild.focus({ preventScroll: true });
    }
  } },
    h('fieldset', { class: 'bk-section' }, h('legend', { text: t.persons }), h('div', { class: 'bk-stepper' }, minus, num, plus)),
    // Järjestys: henkilömäärä → asiakastyyppi ja yhteystiedot → lisäpalvelut → lisätiedot, ehdot ja varaus
    cf.node,
    addonRows.length ? h('fieldset', { class: 'bk-section bk-addons' }, h('legend', { text: t.addonsTitle }), h('p', { class: 'bk-hint', text: t.addonsHint }), h('ul', { class: 'bk-addonlist' }, addonRows.map((r) => r.node))) : null,
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
  holdInfo().then((hi) => {
    hmode.on = hi.on; hmode.minutes = hi.minutes;
    if (hi.on) {   // pitotila (§17): paikanpito, maksutapa valitaan seuraavassa vaiheessa, varaus vahvistuu vasta maksun jälkeen
      submitLabel();
      payNote.textContent = ht(S.lang, 'checkout.lead', { minutes: hi.minutes });
      payExtra.replaceChildren(...hi.extra(S.lang));
      return;
    }
    if (hi.onlineSite) payNote.textContent = hi.legacyHold ? `${t.payHold(hi.minutes)} ${pt(S.lang, 'checkoutHoldOnline')}` : pt(S.lang, 'checkoutOnlineSite');   // vanha käytös ennallaan
  });
  mount(h('h2', { text: t.bookTitle }), pick, wlNote,
    h('div', { class: 'bk-checkout' }, form,
      h('aside', { class: 'bk-aside', 'aria-label': t.summary }, h('h3', { text: t.summary }), sumList,
        h('p', { class: 'bk-totalrow' }, t.total + ': ', total, ' ', h('small', { text: t.vatIncl })),
        payNote, payExtra)));
  upd(); focusTop();
}

// ---- vahvistussivu ----
const ics = (b) => {
  const it = b.items[0], z = (iso) => new Date(iso).toISOString().replace(/[-:]|\.\d{3}/g, '');
  return ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Sipoonjoen Perinnesauna//Varaus//FI', 'BEGIN:VEVENT', `UID:${b.order_no}@saunotus.fi`, `DTSTAMP:${z(new Date().toISOString())}`,
    `DTSTART:${z(it.starts_at)}`, `DTEND:${z(it.ends_at)}`, `SUMMARY:${it.product_name}`, 'LOCATION:Hindsbyntie 124\\, 04130 Sipoo', 'END:VEVENT', 'END:VCALENDAR'].join('\r\n');
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
  const it = b.items[0];
  const sp = (await loadStatic()).get(+it.product_id), prodName = (S.lang === 'en' && sp?.name_en) || it.product_name;   // englanniksi kb-nimi (palvelin palauttaa suomenkielisen)
  const co = normCheckout(b);   // §17: null = vanha backend / ei pitotilaa → vanha näkymä muuttumattomana
  const holdV = isHoldView(co);
  const head = holdV ? ht(S.lang, { awaiting_payment: 'status.awaiting', processing_payment: 'status.processing', preliminary: 'status.preliminary', expired: 'status.expired' }[co.state]) : { confirmed: t.confConfirmed, pending: t.confPending, cancelled: t.confCancelled, expired: t.confExpired }[b.status] || b.status;
  // Maksutavat (MobilePay, lahjakortti) samoista moduuleista kuin tilaussivulla; virhe / puuttuva RPC → null (ei maksuosiota, vanha näkymä). Paluu MobilePaysta (?pay=mobilepay) tarvitsee mp-rajapinnan aina.
  const canPay = ['confirmed', 'pending'].includes(b.status) && b.payment_status !== 'paid' && !(co && (co.preliminary || co.expired || co.cancelled));   // alustavaa/vanhentunutta varausta ei makseta (order_preliminary / order_expired)
  const L = S.lang === 'en' ? 'en' : 'fi';
  const retPay = new URLSearchParams(location.search).get('pay') === 'mobilepay' && !noReturn;
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
  const dl = h('dl', { class: 'bk-sum' },
    h('dt', { text: t.order }), h('dd', { text: String(b.order_no) }), h('dt', { text: t.what }), h('dd', { text: prodName }),
    optRow ? [h('dt', { text: ox.what }), h('dd', { 'data-testid': 'conf-option', class: it.option ? '' : 'bk-opt-missing', text: optRow })] : null,
    h('dt', { text: t.when }), h('dd', { text: `${dayLong(it.starts_at)}, ${hm(it.starts_at)}–${hm(it.ends_at)}` }), h('dt', { text: t.persons }), h('dd', { text: String(it.persons) }),
    (b.addons || []).flatMap((a) => [h('dt', { text: (S.lang === 'en' && a.name_en) || a.name }), h('dd', { text: `${a.quantity} × ${money(a.unit_price)}` })]),
    h('dt', { text: t.total }), h('dd', { text: `${money(b.total)} (${t.vatIncl})` }), h('dt', { text: t.payStatus }), h('dd', { text: pay }),
    holdV && co.awaiting && co.remaining > 0 ? [h('dt', { text: ht(S.lang, 'summary.remaining') }), h('dd', { 'data-testid': 'conf-remaining', text: money(co.remaining) })] : null);   // pitotilassa: maksettavaa jäljellä (lahjakorttiosuuden jälkeen)
  dl.dataset.testid = 'conf-summary';
  const actions = h('div', { class: 'bk-actions' });
  if (b.status !== 'cancelled' && b.status !== 'expired' && !holdV) {   // kalenterilisäys vasta vahvistetusta varauksesta
    const url = URL.createObjectURL(new Blob([ics(b)], { type: 'text/calendar' }));
    actions.append(h('a', { class: 'btn light', href: url, download: `varaus-${b.order_no}.ics`, text: t.addCal }));
  }
  if (b.status === 'confirmed' && b.can_change) actions.append(h('a', { class: 'btn gold', href: `#${token}/muuta`, text: t.changeBooking }));
  if (b.status === 'pending') actions.append(h('button', { type: 'button', class: 'btn light', onclick: async () => {
    if (!confirm(t.cancelConfirm)) return;
    const r = await rpc('public_cancel_booking', { p_token: token });
    out.replaceChildren(r.ok ? h('p', { class: 'bk-ok', text: t.cancelled }) : errorBox(t.errors[r.code] || t.cancelFail));
    if (r.ok) setTimeout(() => location.reload(), 800);
  } }, t.cancelBooking));
  mount(h('div', { class: `bk-conf ${b.status}` }, h('h2', { 'data-testid': 'conf-title', text: b.status === 'cancelled' ? t.confCancelled : b.status === 'expired' ? t.confExpired : b.status === 'pending' || (co && co.awaiting) ? ht(S.lang, 'h2.awaiting') : t.confTitle }), h('p', { class: 'bk-status', role: 'status', 'data-testid': 'conf-status', text: head }), holdHost, mpHost, dl,   // pitotilassa: otsikko + tilabadge → pitopaneeli → tiivis tilausyhteenveto → maksuosio (secEl lisätään yhteenvedon jälkeen)
    b.status === 'confirmed' && b.customer_kind === 'company' && b.payment_status !== 'paid' ? h('p', { class: 'bk-pay', text: t.companyInvoiceNote }) : null,
    b.status === 'confirmed' && b.payment_status !== 'paid' && b.payment_status !== 'invoiced' && b.customer_kind !== 'company' && !isTreatmentBooking(b) && !online ? h('p', { class: 'bk-pay', text: t.payLater }) : null, optNote && b.status === 'confirmed' ? h('p', { class: 'bk-note', 'data-testid': 'conf-option-note', text: optNote }) : null, actions, out,
    b.status === 'confirmed' ? h('p', { class: 'bk-note', text: b.can_change ? t.changeInfo(b.change_hours_before, fmt(b.change_deadline, { day: 'numeric', month: 'numeric', hour: 'numeric', minute: '2-digit', hourCycle: 'h23' })) : t.changeLocked(b.change_hours_before) }, ' ', h('a', { href: `mailto:${S.email}`, text: S.email })) : null,
    h('p', { class: 'bk-note', text: t.emailNote }), h('p', {}, h('a', { href: S.infoHref, text: t.directions }))));
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
  if (retPay && model) {   // paluu MobilePaysta: reconcile + public_get_booking-polling → tulos (maksettu / epäonnistui / odottaa), sivu päivittyy lopuksi
    const num = (k) => { const v = +new URLSearchParams(location.search).get(k); return Number.isFinite(v) && v > 0 ? v : undefined; };
    runReturn({ mp: model.mp, host: mpHost, S, L, orderNo: b.order_no, timing: MOCK ? { intervalMs: num('mpinterval'), maxMs: num('mpmax') } : {},
      getOrder: async () => { const n = await rpc('public_get_booking', { p_token: token }); return n?.ok ? n : null; },
      onDone: async (res) => { if (res?.state === 'net') return;   /* verkkovirhe: jätä tarkista-uudelleen -paneeli näkyviin äläkä lataa sivua uudelleen */
        await viewConfirmation({ refresh: true, host: mpHost, noReturn: true }); } }).catch(() => {});
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
  const num = h('input', { id: 'bk-n', type: 'number', min: 1, inputmode: 'numeric', 'aria-label': t.persons, onchange: () => { n = +num.value || 1; clamp(); upd(); } });
  const minus = h('button', { type: 'button', class: 'bk-step', 'aria-label': '−', onclick: () => { n--; upd(); } }, '−');
  const plus = h('button', { type: 'button', class: 'bk-step', 'aria-label': '+', onclick: () => { n++; upd(); } }, '+');
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
    clamp(); const { min, max } = limits(); const s = target();
    num.min = min; num.max = max; num.value = n; minus.disabled = n <= min; plus.disabled = n >= max;
    // lisäpalvelut säilyvät; määrät rajataan uuteen henkilömäärään (sama kuin palvelimella)
    const addonsNew = (b.addons || []).reduce((x, a) => x + Math.min(a.quantity, addonLimit(a, n)) * +a.unit_price, 0);
    const newTotal = s ? priceFor(s, n) + addonsNew : null;
    const changed = !!st.session || n !== it.persons;
    summary.textContent = s ? `${dayLong(s.starts_at)}, ${hm(s.starts_at)}–${hm(s.ends_at)} · ${n} ${t.person} · ${money(newTotal)}` : '';
    const priceBlocked = b.payment_status === 'paid' && newTotal != null && Math.abs(newTotal - b.total) > 0.005;
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
      if (n !== it.persons) args.p_persons = n;
      const r = await rpc('public_change_booking', args);
      if (!r.ok) throw Object.assign(new Error(t.errors[r.code] || t.errorGeneric), { code: r.code, mapped: true });
      state.months.clear();
      location.hash = token; window.scrollTo({ top: 0 });
    } catch (e) {
      submit.textContent = t.saveChange; upd();
      msg.replaceChildren(errorBox(e.mapped ? e.message : t.errorGeneric)); msg.firstChild.setAttribute('tabindex', '-1'); revealIfHidden(msg); msg.firstChild.focus({ preventScroll: true });
      if (['capacity_exceeded', 'private_booked', 'public_shift_booked', 'space_closed'].includes(e.code)) loadSessions();
    }
  } }, h('fieldset', {}, h('legend', { text: t.persons }), h('div', { class: 'bk-stepper' }, minus, num, plus)), summary, msg, submit);
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
  } finally { document.documentElement.classList.remove('bk-hero-wait'); }
}
let last = '';
window.addEventListener('hashchange', () => {
  // päivän valinta kalenterissa vaihtaa hashin ilman uudelleenpiirtoa (replaceState ei laukaise tapahtumaa); muut siirtymät piirretään uudelleen
  if (location.hash !== last) {
    const keep = /^#\/paiva\b/.test(last) && /^#\/paiva\b/.test(location.hash);   // päivänvaihto päivänäkymässä: ei hypätä sivun alkuun
    last = location.hash; route(keep); if (!keep) window.scrollTo({ top: 0 });
  }
});
last = location.hash;
route();
