// Varauskauppa: tuote → päivä/vuoro → henkilömäärä → yhteystiedot → vahvistus. Vaihtoehtoinen selaus: päivän mukaan (#/paiva/<pvm>) → kaikki päivän vuorot. Vanilla JS, ei riippuvuuksia, ei build-vaihetta.
// Data tulee vain julkisista RPC-funktioista (public_catalog / public_product_images / public_availability / public_create_booking / public_get_booking / public_change_booking).
// Asiakas ei voi itse perua vahvistettua varausta (peruutukset sähköpostilla henkilökunnalle); hän voi MUUTTAA varausta (toinen vuoro / henkilömäärä) asetuksen mukaan vähintään 48 h ennen vuoroa.
import { rpc, storageUrl, functionUrl, setRpcOverride } from './sb.js';
import { createMobilepayApi } from './mobilepay-api.js';
import { normOptions, shouldShowButton, testUiEnabled } from './mobilepay-logic.js';
import { payBlock } from './mobilepay-ui.js';
import { T } from './i18n.js';
import { loadProducts as loadTreatmentProducts, splitCatalog, isTreatmentBooking, loadAvailability as loadTreatmentSlots, horizonDays as treatmentHorizon, timeToken as treatmentTimeToken, isRetryable as treatmentRetryable } from './treatments.js';
import { createTreatmentViews } from './treatment-ui.js';
import { OPT } from './options-texts.js';
import { optName, needsOption, findOption } from './options-logic.js';

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
// y-tunnus: muoto 1234567-8 + tarkistenumero (painot 7,9,10,5,8,4,2). Palvelin tarkistaa saman säännön (booking._business_id_ok); tämä on vain nopea palaute.
const normBid = (v) => {
  const x = String(v ?? '').replace(/\s/g, '').toUpperCase().replace(/^FI(\d{8})$/, '$1');
  let m = x.match(/^(\d{7})-?(\d)$/); if (m) return `${m[1]}-${m[2]}`;
  m = x.match(/^(\d{6})-?(\d)$/); if (m) return `0${m[1]}-${m[2]}`;
  return x;
};
const validBid = (v) => {
  const m = normBid(v).match(/^(\d{7})-(\d)$/); if (!m) return false;
  const rem = [...m[1]].reduce((a, c, i) => a + +c * [7, 9, 10, 5, 8, 4, 2][i], 0) % 11;
  return rem !== 1 && (rem === 0 ? 0 : 11 - rem) === +m[2];
};
// lisäpalvelun enimmäismäärä: henkilömäärä × max/hlö, enintään 99 (sama kuin booking._addon_limit)
const addonLimit = (a, n) => Math.min((a.max_per_person ?? 99) * Math.max(1, n), 99);
const aname = (a) => (S.lang === 'en' && a.name_en) || a.name;
const adesc = (a) => (S.lang === 'en' && a.description_en) || a.description;
const pname = (p) => (S.lang === 'en' && p.name_en) || p.name;
const pdesc = (p) => (S.lang === 'en' && p.description_en) || p.description;
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
if (MOCK) setRpcOverride((await import('./shop-mock.js')).createShopMock({ fail: new URLSearchParams(location.search).get('fail') }).rpc);
const bk = (hash) => `${S.shopHref}${MOCK ? '?mock=1' : ''}#${hash}`;

const state = { catalog: null, settings: null, images: new Map(), treatments: [], months: new Map(), busy: false };
const mount = (...nodes) => { root.replaceChildren(...nodes); root.setAttribute('aria-busy', 'false'); };
const focusTop = () => { const el = root.querySelector('h2,h1') || document.querySelector('main .hero.page h1'); if (el) { el.setAttribute('tabindex', '-1'); el.focus({ preventScroll: false }); } };
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
  const [catalog, settings, imgs, stat] = await Promise.all([rpc('public_catalog'), rpc('public_settings'), rpc('public_product_images').catch(() => []), loadStatic()]);
  const split = splitCatalog(catalog, stat);   // vuoropohjaiset tuotteet (rules) ja hoito-/rituaalituotteet (slots) erikseen
  state.catalog = split.rules; state.treatments = split.treatments; treatmentsReady = Promise.resolve(); state.settings = settings || {};
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
// Lyhyt kuvaus: ensimmäinen virke (ei katkaista kellonaikojen pisteistä "16.30"), enintään ~130 merkkiä sanarajalta. Pitkä kuvaus pysyy sisältöosassa.
const shortDesc = (p) => {
  const d = (pdesc(p) || '').replace(/\s+/g, ' ').trim(); if (!d) return '';
  const m = d.match(/^.{20,}?[.!?](?=\s+[A-ZÅÄÖ])/u); let x = m ? m[0] : d;
  if (x.length > 130) x = `${x.slice(0, 130).replace(/\s+\S*$/, '')}…`;
  return x;
};
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
  if (sub) { sub.textContent = p ? shortDesc(p) : hero.def.sub; sub.hidden = !sub.textContent; }
}

// ---- näkymä 1: tuotelista ----
function viewList(query) {
  const cat = [...state.catalog, ...state.treatments];
  const kinds = ['all', ...new Set(cat.map(kindOf))];
  const k = kinds.includes(query.get('k')) ? query.get('k') : 'all';
  const list = cat.filter((p) => k === 'all' || kindOf(p) === k);
  const tabs = h('nav', { class: 'bk-tabs', 'aria-label': t.title }, kinds.map((x) => h('a', { href: bk(`/?k=${x}`), 'aria-current': x === k ? 'true' : null, text: t['k_' + x] || t[x] || x })));
  const cards = h('ul', { class: 'bk-cards' }, list.map((p) => p.treatment ? tv.card(p) : h('li', { class: 'bk-card' },
    pimg(p, 'card-img'),
    h('h3', {}, h('a', { href: bk(`/tuote/${p.slug}`), text: pname(p) })),
    h('p', { class: 'bk-desc', text: (pdesc(p) || '').slice(0, 170) + ((pdesc(p) || '').length > 170 ? '…' : '') }),
    h('p', { class: 'bk-meta' }, h('strong', { text: priceText(p) }), p.duration_text ? ` · ${p.duration_text}` : ''),
    h('a', { class: 'btn sm', href: bk(`/tuote/${p.slug}`) }, t.choose, h('span', { class: 'sr', text: ' – ' + pname(p) })))));
  mount(h('header', { class: 'bk-head' }, h('h2', { text: t.title }), h('p', { class: 'lead', text: t.lead })), modeSwitch('cat'), tabs, cards);
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
async function ensureMonths(pairs) {   // pairs: [[y, m0], …] → kaikki tuotteet rinnakkain; epäonnistuneet tuotteet jätetään pois (ei välimuistiin)
  const jobs = [];
  for (const [y, m] of pairs) for (const p of state.catalog) jobs.push(loadMonth(p.id, y, m));
  const res = await Promise.allSettled(jobs);
  if (jobs.length && res.every((x) => x.status === 'rejected')) throw res[0].reason;
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
  const cl = cleanLabel(r.label), sub = cl && !pname(p).toLowerCase().includes(cl.toLowerCase()) ? cl : '';   // ei toisteta tuotteen nimeä
  const price = r.price_mode === 'per_person' ? `${money(r.unit_price)} ${t.perPerson}` : r.price_mode === 'fixed' ? money(r.base_price) : `${t.from} ${money(r.base_price)}`;
  return h('li', { class: `bk-slot ${r.status}` },
    h('div', { class: 'bk-slot-main' }, h('strong', { class: 'bk-time', text: title }),
      withName ? h('span', { class: 'bk-prodname' }, h('a', { href: bk(`/tuote/${p.slug}/${ds}`), text: pname(p) })) : null, sub ? h('span', { class: 'bk-sub', text: sub }) : null, h('span', { class: 'bk-price', text: price })),
    h('div', { class: 'bk-slot-side' },
      ok ? h('span', { class: 'bk-badge free', text: t.freeSpots(r.remaining) }) : h('span', { class: `bk-badge ${r.status}`, text: r.status === 'full' ? t.full : t.unavailable, title: r.status === 'unavailable' ? t.unavailableHint : null }),
      ok ? h('a', { class: 'btn sm', href: bk(`/varaa/${r.rule_id}/${ds}/${p.id}?via=day`) }, t.choose, h('span', { class: 'sr', text: ` ${title}, ${pname(p)}` })) : null));
}
// hoito-/rituaaliajan rivi päivänäkymässä: valinta vie hoitovarausvirtaan (tuotesivu) esivalitulla päivällä ja ajalla (henkilömäärä 1, vaihdettavissa)
function treatItem({ r, p }, ds) {
  const title = r.ends_at ? `${hm(r.starts_at)}–${hm(r.ends_at)}` : hm(r.starts_at);
  return h('li', { class: 'bk-slot available' },
    h('div', { class: 'bk-slot-main' }, h('strong', { class: 'bk-time', text: title }), h('span', { class: 'bk-price', text: priceText(p) })),
    h('div', { class: 'bk-slot-side' }, h('a', { class: 'btn sm', href: bk(`/tuote/${p.slug}?n=1&d=${ds}&t=${treatmentTimeToken(r.time)}`) }, t.choose, h('span', { class: 'sr', text: ` ${title}, ${pname(p)}` }))));
}
// Hoidot päivänäkymässä: vain tuotteet joilla on vapaita aikoja valittuna päivänä (public_treatment_availability, 1 hlö; yksi haku / tuote koko varausikkunalle = välimuistista kaikille päiville,
// haut jonossa, ei pollausta). Kortit lisätään sitä mukaa kun haku valmistuu; ajat näytetään vasta kun kortti avataan (kuten yleisillä vuoroilla).
let treatDayToken = 0;
async function fillTreatments(box, results, ds, today, tmax, openSlug, onToggle, rulesFree) {
  const token = ++treatDayToken, list = box.querySelector('ul'), status = box.querySelector('.bk-treat-status');
  let shown = 0, failed = null;
  for (const p of state.treatments) {
    let by;
    try { by = await loadTreatmentSlots(p, 1, today, tmax); } catch (e) { failed = failed || e; continue; }
    if (token !== treatDayToken || !box.isConnected) return;
    const slots = by.get(ds) || [];
    if (!slots.length) continue;
    const rs = slots.map((s) => ({ r: { status: 'available', starts_at: s.start, ends_at: s.end, time: s.time }, p }));
    const li = prodCard(p, rs, ds, p.slug === openSlug, onToggle, true);
    list.append(li); shown++;
    if (!rulesFree) results.querySelector('.bk-notice')?.remove();
    if (p.slug === openSlug) li.scrollIntoView({ block: 'nearest' });
  }
  if (token !== treatDayToken || !box.isConnected) return;
  status.remove();
  if (!shown && !failed) box.remove();
  else if (!shown) box.append(errorBox(treatmentRetryable(failed?.code) ? t.tr.errors.busy : t.loadError), h('p', {}, h('button', { type: 'button', class: 'btn sm light', text: t.tr.retry, onclick: () => route(true) })));
}
// tuotekortti (accordion): otsikkopainike → vain saatavilla olevat tuotteet; ajat näytetään vasta kun kortti avataan (yksi auki kerrallaan, tila URL:ssa ?tuote=<slug>)
function prodCard(p, rs, ds, open, onToggle, treat = false) {
  const avail = rs.filter((x) => x.r.status === 'available'), id = `bk-pc-${p.id}`;
  const desc = (pdesc(p) || '').replace(/\s+/g, ' ').trim(), short = desc.length > 90 ? `${desc.slice(0, 90).replace(/\s+\S*$/, '')}…` : desc;
  const panel = h('div', { id: `${id}-panel`, class: 'bk-pc-panel', role: 'region', 'aria-labelledby': `${id}-btn`, hidden: open ? null : true },
    h('ul', { class: 'bk-slotlist' }, rs.filter((x) => treat || x.r.status === 'available').map((x) => (treat ? treatItem(x, ds) : dayItem(x, ds)))),
    h('p', { class: 'bk-pc-more' }, h('a', { href: treat ? bk(`/tuote/${p.slug}?n=1&d=${ds}`) : bk(`/tuote/${p.slug}/${ds}`), text: t.productInfo })));
  const btn = h('button', { type: 'button', id: `${id}-btn`, class: 'bk-pc-head', 'aria-expanded': open ? 'true' : 'false', 'aria-controls': `${id}-panel`, onclick: () => onToggle(p, li) },
    pimg(p, 'pc-img', { alt: false, w: 160, hgt: 160 }),
    h('span', { class: 'bk-pc-main' }, h('strong', { class: 'bk-pc-name', text: pname(p) }), short ? h('span', { class: 'bk-pc-desc', text: short }) : null,
      h('span', { class: 'bk-pc-meta' }, h('span', { class: 'bk-price', text: priceText(p) }), h('span', { class: 'bk-badge free', text: `${t.timesFree(avail.length)} · ${t.firstAt} ${hm(avail[0].r.starts_at)}` }))),
    h('span', { class: 'bk-pc-chev', 'aria-hidden': 'true' }));
  const li = h('li', { class: `bk-pc${open ? ' open' : ''}`, 'data-slug': p.slug }, btn, panel);
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
    if (!wasOpen) { li.classList.add('open'); li.querySelector('.bk-pc-head').setAttribute('aria-expanded', 'true'); li.querySelector('.bk-pc-panel').hidden = false; li.scrollIntoView({ block: 'nearest', behavior: 'smooth' }); }
    history.replaceState(null, '', bk(`/paiva/${ds}${wasOpen ? '' : `?tuote=${p.slug}`}`)); last = location.hash;   // tila URL:ssa, ei uudelleenpiirtoa
  };
  const heading = h('h3', { id: 'bk-day-h', text: `${t.slotsFor} – ${longDate}`, tabindex: '-1' });
  if (!free.length) {   // ei yhtään saatavilla olevaa tuotetta: tyhjän päivän viesti + ehdotus seuraavasta vapaasta päivästä
    const nextDs = await findNextFree(ds, maxDs);
    results = h('div', { class: 'bk-dayresults', 'data-date': ds }, heading,
      h('div', { class: 'bk-notice', role: 'status' }, h('p', { text: t.noSlotsDay }),
        nextDs ? h('p', {}, t.nextFree + ' ', h('a', { class: 'btn sm', href: bk(`/paiva/${nextDs}`), text: dayLong(`${nextDs}T12:00:00Z`) })) : h('p', { text: t.noNextFree })));
  } else {
    // vain tuotteet, joilla on vähintään yksi varattavissa oleva vuoro (täynnä / ei varattavissa olevat tuotteet jätetään pois)
    const prods = state.catalog.map((p) => [p, rows.filter((x) => x.p.id === p.id)]).filter(([, rs]) => rs.some((x) => x.r.status === 'available'));
    const bySlug = new Map(prods.map(([p]) => [p.slug, p]));
    let openId = prods.length === 1 ? prods[0][0].id : bySlug.get(openSlug)?.id ?? null;   // yksi tuote → valmiiksi auki
    const groups = ['yleinen', 'yksityinen', 'muut'].map((k) => [k, prods.filter(([p]) => kindOf(p) === k)]).filter(([, g]) => g.length);
    results = h('div', { class: 'bk-dayresults', 'data-date': ds }, heading, h('p', { class: 'bk-note bk-pickhint', text: t.pickProduct }),
      groups.flatMap(([k, g]) => [h('h4', { class: 'bk-kindh', text: t['k_' + k] }), h('ul', { class: 'bk-prods' }, g.map(([p, rs]) => prodCard(p, rs, ds, p.id === openId, toggle)))]));
  }
  const tmax = addDays(today, treatmentHorizon(state.settings)) < maxDs ? addDays(today, treatmentHorizon(state.settings)) : maxDs;
  const treatBox = state.treatments.length && ds <= tmax ? h('section', { class: 'bk-treat-day', 'aria-label': t.k_hoito }, h('h4', { class: 'bk-kindh', text: t.k_hoito }), h('p', { class: 'bk-loading bk-treat-status', role: 'status', text: t.loading }), h('ul', { class: 'bk-prods' })) : null;
  if (treatBox) results.append(treatBox);
  mount(h('header', { class: 'bk-head' }, h('h2', { text: t.dayTitle }), h('p', { class: 'lead', text: t.dayLead })), modeSwitch('day', ds),
    h('section', { class: 'bk-daypick', 'aria-label': t.pickDay }, nav, strip,
      h('p', { class: 'bk-legend' }, h('span', { class: 'dot free' }), t.free, ' ', h('span', { class: 'dot full' }), t.full, ' ', h('span', { class: 'dot unavail' }), t.unavailable), tools),
    h('div', { class: 'bk-slots', 'aria-live': 'polite' }, results));
  if (keep) { const el = document.getElementById('bk-day-h'); if (el) el.focus({ preventScroll: true }); } else focusTop();
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
      h('h2', { text: st ? st.name : t.unknownProduct }), st ? h('p', { text: st.description || '' }) : null,
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
      h('p', { class: 'bk-desc', text: pdesc(p) || '' }),
      h('p', { class: 'bk-meta' }, h('strong', { text: priceText(p) }), p.duration_text ? ` · ${p.duration_text}` : ''),
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
        : h('button', { type: 'button', class: `bk-cell ${st}${ds === today ? ' today' : ''}${ds === sel ? ' sel' : ''}`, 'aria-pressed': ds === sel ? 'true' : 'false', 'aria-label': label, onclick: () => { sel = ds; history.replaceState(null, '', bk(`/tuote/${slug}/${ds}`)); drawSlots(); markSel(); } }, d));
    }
    calBox.append(nav, h('div', { class: 'bk-grid', role: 'group', 'aria-label': monthName }, wd, cells),
      h('p', { class: 'bk-legend' }, h('span', { class: 'dot free' }), t.free, ' ', h('span', { class: 'dot full' }), t.full, ' ', h('span', { class: 'dot unavail' }), t.unavailable),
      ...(any ? [] : [h('p', { class: 'bk-note', text: t.noSlotsMonth })]));
    const markSel = () => calBox.querySelectorAll('.bk-cell[aria-pressed]').forEach((b) => { const on = b.textContent === String(+sel?.slice(8)) && sel?.startsWith(`${y}-${pad2(m + 1)}`); b.classList.toggle('sel', on); b.setAttribute('aria-pressed', on ? 'true' : 'false'); });
    const drawSlots = () => {
      if (!sel) { slotBox.replaceChildren(); return; }
      const rows = (byDay[sel] || []).filter((r) => r.status === 'available');   // vain vapaat vuorot asiakkaalle
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
  const sub = cleanLabel(r.label);
  const price = r.price_mode === 'per_person' ? `${money(r.unit_price)} ${t.perPerson}` : r.price_mode === 'fixed' ? money(r.base_price)
    : `${money(r.base_price)} (${t.included(r.included_persons)}, ${t.extra(money(r.extra_person_price))})`;
  return h('li', { class: `bk-slot ${r.status}` },
    h('div', { class: 'bk-slot-main' }, h('strong', { class: 'bk-time', text: title }), sub ? h('span', { class: 'bk-sub', text: sub }) : null, h('span', { class: 'bk-price', text: price })),
    h('div', { class: 'bk-slot-side' },
      ok ? h('span', { class: 'bk-badge free', text: t.freeSpots(r.remaining) }) : h('span', { class: `bk-badge ${r.status}`, text: r.status === 'full' ? t.full : t.unavailable, title: r.status === 'unavailable' ? t.unavailableHint : null }),
      ok ? h('a', { class: 'btn sm', href: bk(`/varaa/${r.rule_id}/${ds}/${p.id}`) }, t.choose, h('span', { class: 'sr', text: ` ${title}` })) : null));
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
    h('h4', { text: t.einvoiceTitle }),
    opt('einvoice_address', t.einvoiceAddress, { maxlength: 40 }), opt('einvoice_operator', t.einvoiceOperator, { maxlength: 40, hint: t.einvoiceHint }),
    opt('reference', t.reference, { maxlength: 100 }),
    h('p', { class: 'bk-note', text: t.companyNote }));
  function setKind(k) {
    kind = k; companyBox.hidden = k !== 'company'; nameLabel.textContent = k === 'company' ? t.contactName : t.name;
    for (const id of ['company_name', 'business_id', 'street', 'zip', 'city']) { const el = document.getElementById(id); if (el) el.required = k === 'company'; }
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
      if (!validBid(val('business_id'))) { msg.append(errorBox(t.invalidBusinessId)); form.business_id.focus(); return null; }
      if (!/^\d{5}$/.test(val('zip'))) { msg.append(errorBox(t.invalidZip)); form.zip.focus(); return null; }
      if (!!val('einvoice_address') !== !!val('einvoice_operator')) { msg.append(errorBox(t.einvoiceBoth)); form.einvoice_address.focus(); return null; }
      company = { company_name: val('company_name'), business_id: normBid(val('business_id')), street: val('street'), zip: val('zip'), city: val('city'),
        einvoice_address: val('einvoice_address') || null, einvoice_operator: val('einvoice_operator') || null, reference: val('reference') || null };
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
  const max = Math.max(s.min_persons, Math.min(s.max_persons || 50, s.remaining));
  let n = Math.min(Math.max(+new URLSearchParams(location.hash.split('?')[1] || '').get('n') || s.min_persons, s.min_persons), max);
  const total = h('strong', { class: 'bk-total', 'aria-live': 'polite' });
  const sumList = h('dl', { class: 'bk-sum' });
  // lisäpalvelut (public_addons): vain tämän vuorotyypin lisäpalvelut; virhe tai puuttuva funktio → ei lisäpalveluita
  const addons = ((await rpc('public_addons').catch(() => [])) || []).filter((a) => (a.applies_modes || []).includes(s.mode));
  const qty = new Map(addons.map((a) => [a.id, 0]));
  const addonsSum = () => addons.reduce((x, a) => x + qty.get(a.id) * +a.price, 0);
  const upd = () => {
    for (const a of addons) qty.set(a.id, Math.min(qty.get(a.id), addonLimit(a, n)));
    total.textContent = money(priceFor(s, n) + addonsSum());
    sumList.replaceChildren(h('dt', { text: t.what }), h('dd', { text: pname(p) }), h('dt', { text: t.when }), h('dd', { text: `${dayLong(s.starts_at)}, ${hm(s.starts_at)}–${hm(s.ends_at)}` }), h('dt', { text: t.persons }), h('dd', { text: String(n) }),
      ...addons.filter((a) => qty.get(a.id) > 0).flatMap((a) => [h('dt', { text: aname(a) }), h('dd', { text: `${qty.get(a.id)} × ${money(a.price)}` })]));
    num.value = n; minus.disabled = n <= s.min_persons; plus.disabled = n >= max;
    for (const r of addonRows) r.sync();
  };
  const num = h('input', { id: 'bk-n', type: 'number', min: s.min_persons, max, inputmode: 'numeric', 'aria-label': t.persons, onchange: () => { n = Math.min(Math.max(+num.value || s.min_persons, s.min_persons), max); upd(); } });
  const minus = h('button', { type: 'button', class: 'bk-step', 'aria-label': '−', onclick: () => { n--; upd(); } }, '−');
  const plus = h('button', { type: 'button', class: 'bk-step', 'aria-label': '+', onclick: () => { n++; upd(); } }, '+');
  const cf = customerFields();
  // lisäpalvelurivi: nimi, hinta, kuvaus + määrävalitsin (− n +)
  const addonRows = addons.map((a) => {
    const q = h('input', { id: `bk-a-${a.id}`, type: 'number', min: 0, inputmode: 'numeric', 'aria-label': `${aname(a)}: ${t.addonQty}`, onchange: () => { qty.set(a.id, Math.max(0, Math.min(Math.floor(+q.value) || 0, addonLimit(a, n)))); upd(); } });
    const dec = h('button', { type: 'button', class: 'bk-step', 'aria-label': `${aname(a)} −`, onclick: () => { qty.set(a.id, qty.get(a.id) - 1); upd(); } }, '−');
    const inc = h('button', { type: 'button', class: 'bk-step', 'aria-label': `${aname(a)} +`, onclick: () => { qty.set(a.id, qty.get(a.id) + 1); upd(); } }, '+');
    const sync = () => { const lim = addonLimit(a, n); q.max = lim; q.value = qty.get(a.id); dec.disabled = qty.get(a.id) <= 0; inc.disabled = qty.get(a.id) >= lim; };
    const node = h('li', { class: 'bk-addon' }, h('div', { class: 'bk-addon-info' }, h('label', { for: `bk-a-${a.id}` }, h('strong', { text: aname(a) }), ' ', h('span', { class: 'bk-addon-price', text: money(a.price) })), adesc(a) ? h('small', { text: adesc(a) }) : null),
      h('div', { class: 'bk-stepper' }, dec, q, inc));
    return { node, sync, a };
  });
  const msg = h('div', { id: 'bk-msg' });
  const submit = h('button', { type: 'submit', class: 'btn gold', text: t.book });
  const legal = legalFields(), { terms, consent } = legal;
  const hold = state.settings.public_payment_mode === 'hold_until_paid';
  const form = h('form', { class: 'bk-form', novalidate: true, onsubmit: async (ev) => {
    ev.preventDefault(); msg.replaceChildren();
    const f = new FormData(form), cust = cf.read(form, msg); if (!cust) return;
    if (!terms.checked) { msg.append(errorBox(t.acceptTermsErr)); terms.focus(); return; }
    submit.disabled = true; submit.textContent = t.booking;
    try {
      const chosen = addons.filter((a) => qty.get(a.id) > 0).map((a) => ({ id: a.id, quantity: qty.get(a.id) }));
      const r = await rpc('public_create_booking', { p_rule_id: s.rule_id, p_date: ds, p_persons: n, p_name: cust.name, p_email: cust.email, p_phone: cust.phone, p_marketing_consent: consent.checked, p_locale: S.lang, p_note: (f.get('note') || '').trim() || null,
        p_customer_kind: cust.kind, p_company: cust.company, p_addons: chosen.length ? chosen : null });
      if (!r.ok) throw Object.assign(new Error(t.errors[r.code] || r.message), { code: r.code });
      state.months.clear();
      location.assign(`${S.confirmHref}#${r.token}`);
    } catch (e) {
      submit.disabled = false; submit.textContent = t.book;
      msg.replaceChildren(errorBox(e.message || t.loadError));
      if (['capacity_exceeded', 'private_booked', 'public_shift_booked', 'space_closed'].includes(e.code)) state.months.clear();
      msg.firstChild.setAttribute('tabindex', '-1'); msg.firstChild.focus();
    }
  } },
    h('fieldset', { class: 'bk-section' }, h('legend', { text: t.persons }), h('div', { class: 'bk-stepper' }, minus, num, plus)),
    // Järjestys: henkilömäärä → asiakastyyppi ja yhteystiedot → lisäpalvelut → lisätiedot, ehdot ja varaus
    cf.node,
    addonRows.length ? h('fieldset', { class: 'bk-section bk-addons' }, h('legend', { text: t.addonsTitle }), h('p', { class: 'bk-hint', text: t.addonsHint }), h('ul', { class: 'bk-addonlist' }, addonRows.map((r) => r.node))) : null,
    legal.nodes,
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
  mount(h('h2', { text: t.bookTitle }), pick,
    h('div', { class: 'bk-checkout' }, form,
      h('aside', { class: 'bk-aside', 'aria-label': t.summary }, h('h3', { text: t.summary }), sumList,
        h('p', { class: 'bk-totalrow' }, t.total + ': ', total, ' ', h('small', { text: t.vatIncl })),
        h('p', { class: 'bk-pay', text: hold ? t.payHold(state.settings.hold_minutes || 15) : t.payLater }))));
  upd(); focusTop();
}

// ---- vahvistussivu ----
const ics = (b) => {
  const it = b.items[0], z = (iso) => new Date(iso).toISOString().replace(/[-:]|\.\d{3}/g, '');
  return ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Sipoonjoen Perinnesauna//Varaus//FI', 'BEGIN:VEVENT', `UID:${b.order_no}@saunotus.fi`, `DTSTAMP:${z(new Date().toISOString())}`,
    `DTSTART:${z(it.starts_at)}`, `DTEND:${z(it.ends_at)}`, `SUMMARY:${it.product_name}`, 'LOCATION:Hindsbyntie 124\\, 04130 Sipoo', 'END:VEVENT', 'END:VCALENDAR'].join('\r\n');
};
async function viewConfirmation() {
  const [token, sub] = location.hash.slice(1).split('?')[0].split('/');
  if (!/^[0-9a-f-]{36}$/i.test(token)) { mount(errorBox(t.notFound)); return; }
  spinner();
  let b; try { b = await rpc('public_get_booking', { p_token: token }); } catch { mount(errorBox(t.loadError), phoneBox()); return; }
  if (!b?.ok) { mount(errorBox(t.notFound), phoneBox()); return; }
  if (sub === 'muuta' && b.can_change) return isTreatmentBooking(b) ? viewTreatmentChange(token, b) : viewChange(token, b);
  const it = b.items[0];
  const sp = (await loadStatic()).get(+it.product_id), prodName = (S.lang === 'en' && sp?.name_en) || it.product_name;   // englanniksi kb-nimi (palvelin palauttaa suomenkielisen)
  const head = { confirmed: t.confConfirmed, pending: t.confPending, cancelled: t.confCancelled, expired: t.confExpired }[b.status] || b.status;
  const pay = { paid: t.paid, unpaid: t.unpaid, pending: t.pending }[b.payment_status] || b.payment_status;
  const out = h('div', { id: 'bk-cancel-msg', 'aria-live': 'polite' });
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
    h('dt', { text: t.total }), h('dd', { text: `${money(b.total)} (${t.vatIncl})` }), h('dt', { text: t.payStatus }), h('dd', { text: pay }));
  const actions = h('div', { class: 'bk-actions' });
  if (b.status !== 'cancelled' && b.status !== 'expired') {
    const url = URL.createObjectURL(new Blob([ics(b)], { type: 'text/calendar' }));
    actions.append(h('a', { class: 'btn light', href: url, download: `varaus-${b.order_no}.ics`, text: t.addCal }));
  }
  if (b.status === 'confirmed' && b.can_change) actions.append(h('a', { class: 'btn gold', href: `#${token}/muuta`, text: t.changeBooking }));
  if (b.status === 'pending') actions.append(h('button', { type: 'button', class: 'btn light', onclick: async () => {
    if (!confirm(t.cancelConfirm)) return;
    const r = await rpc('public_cancel_booking', { p_token: token });
    out.replaceChildren(r.ok ? h('p', { class: 'bk-ok', text: t.cancelled }) : errorBox(r.message || t.cancelFail));
    if (r.ok) setTimeout(() => location.reload(), 800);
  } }, t.cancelBooking));
  mount(h('div', { class: `bk-conf ${b.status}` }, h('h2', { text: b.status === 'cancelled' ? t.confCancelled : t.confTitle }), h('p', { class: 'bk-status', role: 'status', text: head }), dl,
    b.status === 'confirmed' && b.payment_status !== 'paid' && (b.customer_kind === 'company' || !isTreatmentBooking(b)) ?  /* hoitovarauksella ei maksuohjetta (vain yritysasiakkaan laskutusohje) */ h('p', { class: 'bk-pay', text: b.customer_kind === 'company' ? t.companyNote : t.payLater }) : null, optNote && b.status === 'confirmed' ? h('p', { class: 'bk-note', 'data-testid': 'conf-option-note', text: optNote }) : null, actions, out,
    b.status === 'confirmed' ? h('p', { class: 'bk-note', text: b.can_change ? t.changeInfo(b.change_hours_before, fmt(b.change_deadline, { day: 'numeric', month: 'numeric', hour: 'numeric', minute: '2-digit', hourCycle: 'h23' })) : t.changeLocked(b.change_hours_before) }, ' ', h('a', { href: `mailto:${S.email}`, text: S.email })) : null,
    h('p', { class: 'bk-note', text: t.emailNote }), h('p', {}, h('a', { href: S.infoHref, text: t.directions }))));
  focusTop();
  if (['confirmed', 'pending'].includes(b.status) && b.payment_status !== 'paid') attachMobilepay(token, root.firstElementChild);
}
// "Maksa MobilePaylla" vahvistussivulla (§14.5): vain kun public_payment_options sallii; testitilan tapa vain testiympäristössä. Virhe / puuttuva RPC → ei mitään. Paluu maksun jälkeen tilaussivulle (?pay=mobilepay).
async function attachMobilepay(token, box) {
  try {
    const cfg = window.BOOKING_CONFIG || {}, env = { testUi: testUiEnabled(cfg, location.search), mock: false, official: cfg.mobilepayOfficialButton !== false };
    const mp = createMobilepayApi({ rpc, token, functionUrl, anonKey: cfg.anonKey });
    const opts = normOptions(await mp.options());
    if (!box || root.firstElementChild !== box || !shouldShowButton(opts, env)) return;
    const sec = h('section', { class: 'bk-mp', 'data-testid': 'mp-section' }, payBlock({ S, L: S.lang === 'en' ? 'en' : 'fi', api: mp, opts, env, amount: opts.unpaid != null ? money(opts.unpaid) : '' }));
    const anchor = box.querySelector('.bk-actions');
    anchor ? anchor.before(sec) : box.append(sec);
  } catch { /* ei painiketta */ }
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
        return h('li', { class: `bk-slot ${ok ? 'available' : r.status}` }, h('div', { class: 'bk-slot-main' }, h('strong', { class: 'bk-time', text: title }), cleanLabel(r.label) ? h('span', { class: 'bk-sub', text: cleanLabel(r.label) }) : null),
          h('div', { class: 'bk-slot-side' }, h('span', { class: `bk-badge ${ok ? 'free' : late ? 'unavail' : r.status}`, text: late ? t.tooLate(hours) : ok ? t.freeSpots(cur ? r.remaining + it.persons : r.remaining) : r.status === 'full' ? t.full : t.unavailable }), btn));
      })) : h('p', { text: t.noSlots }));
    upd();
  }
  const horizon = state.settings?.booking_horizon_days || 120;
  const maxDate = new Date(Date.now() + horizon * 864e5).toLocaleDateString('sv-SE', { timeZone: TZ });
  const dateIn = h('input', { id: 'bk-date', type: 'date', value: st.date, min: today, max: maxDate, onchange: (e) => { if (!e.target.value) return; st.date = e.target.value; st.session = null; loadSessions(); } });
  const form = h('form', { class: 'bk-form', novalidate: true, onsubmit: async (ev) => {
    ev.preventDefault(); msg.replaceChildren(); submit.disabled = true; submit.textContent = t.saving;
    try {
      const args = { p_token: token };
      if (st.session) { args.p_rule_id = st.session.rule_id; args.p_date = st.date; }
      if (n !== it.persons) args.p_persons = n;
      const r = await rpc('public_change_booking', args);
      if (!r.ok) throw Object.assign(new Error(t.errors[r.code] || r.message), { code: r.code });
      state.months.clear();
      location.hash = token; window.scrollTo({ top: 0 });
    } catch (e) {
      submit.textContent = t.saveChange; upd();
      msg.replaceChildren(errorBox(e.message || t.loadError)); msg.firstChild.setAttribute('tabindex', '-1'); msg.firstChild.focus();
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
const tv = createTreatmentViews({ h, t, S, state, money, fmt, hm, dayLong, pad2, todayHel, addDays, pname, pdesc, pimg, setHero, mount, focusTop, errorBox, phoneBox, bk, customerFields, legalFields, setLast: () => { last = location.hash; } });

// ---- reititin ----
async function route(keep = false) {
  root.setAttribute('aria-busy', 'true');
  try {
    if (S.page === 'confirm') return await viewConfirmation();
    if (!keep) spinner();
    await loadBase();
    if (state.settings.public_booking_enabled === false) { mount(h('div', { class: 'bk-notice' }, h('p', { text: t.disabled }), phoneBox())); return; }
    const [path, qs] = location.hash.slice(1).split('?');
    const parts = path.split('/').filter(Boolean);
    const q = new URLSearchParams(qs || '');
    if (!(parts[0] === 'tuote' && parts[1]) && !(parts[0] === 'varaa' && parts[1] && parts[2]) && !(parts[0] === 'hoito' && parts[1])) setHero(null);   // tuote- ja lomakenäkymä asettavat heron itse
    if (parts[0] === 'paiva') await viewDay(parts[1], keep, q.get('tuote'));
    else if (parts[0] === 'tuote' && parts[1]) await viewProduct(parts[1], /^\d{4}-\d\d-\d\d$/.test(parts[2] || '') ? parts[2] : null, q);
    else if (parts[0] === 'hoito' && parts[1]) { const tp = state.treatments.find((x) => x.slug === parts[1]); if (tp) await tv.viewCheckout(tp, parts[2], parts[3], q); else await viewProduct(parts[1], null, q); }
    else if (parts[0] === 'varaa' && parts[1] && parts[2]) await viewCheckout(parts[1], parts[2], parts[3], q.get('via'));
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
