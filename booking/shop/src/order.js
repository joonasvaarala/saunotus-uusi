// Asiakkaan tilaussivu: /tilaus/?t=<token> (sopimus: settings.order_page_path; EN-sivu /en/order/?t=<token>, tilauksen locale ohjaa oikeaan kieleen). Token on vain URL-parametrina (ei hashissa/polussa → ei Referer-vuotoa; sivulla meta referrer=no-referrer).
// Näyttää tilauksen rivit, maksutilan, kuitit sekä ohjauksen lisäykseen ja peruutuspyyntöön. Data: order-api.js (mock kun ?mock=1; puuttuva RPC → "ei vielä käytössä").
import { rpc, functionUrl } from './sb.js';
import { richHost } from './rich-view.js';
import { OT } from './order-texts.js';
import { oneKey } from './plural.js';   // yksikkö: {hours}/{minutes} = 1 → <avain>One
import { T } from './i18n.js';
import { createOrderApi, validToken, wantsMock } from './order-api.js';
import { createGiftApi } from './gift-api.js';
import { redeemSection, cardsSection, claimsSection } from './order-gift.js';
import { revealForm, revealIfHidden } from './gift-ui.js';
import { createMobilepayApi } from './mobilepay-api.js';
import { normOptions, shouldShowButton, testUiEnabled } from './mobilepay-logic.js';
import { payBlock, runReturn } from './mobilepay-ui.js';
import { mt } from './mobilepay-texts.js';
import { createVismapayApi } from './vismapay-api.js';
import { normVisma, shouldShowVisma } from './vismapay-logic.js';
import { vismaPayBlock, runVismaReturn } from './vismapay-ui.js';
import { vt } from './vismapay-texts.js';
import { OPT } from './options-texts.js';
import { optName, optionMissingOnOrder, optionChanged, rowLabel } from './options-logic.js';
import { createOptionPicker } from './options-ui.js';
import { ht, holdError } from './hold-texts.js';
import { applyShopTexts } from './site-texts.js';
import { isHoldView, giftWasUsed } from './hold-logic.js';
import { holdPanel } from './hold-ui.js';
import { normCheckoutOptions } from './mobilepay-logic.js';

const S = window.BOOKING_SHOP;
const L = OT[S.lang] ? S.lang : 'fi', t = OT[L], ox = OPT[L];   // ox: tuotevalinnan tekstit (booking_50)
const TZ = 'Europe/Helsinki';
const root = document.getElementById('order-app');
const h = (tag, attrs, ...kids) => {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v; else if (k === 'text') el.textContent = v; else if (k.startsWith('on')) el.addEventListener(k.slice(2), v); else if (v === true) el.setAttribute(k, ''); else el.setAttribute(k, v);
  }
  for (const c of kids.flat(Infinity)) if (c != null && c !== false) el.append(c.nodeType ? c : document.createTextNode(c));
  return el;
};
const money = (n) => new Intl.NumberFormat(L === 'fi' ? 'fi-FI' : 'en-GB', { style: 'currency', currency: 'EUR' }).format(+n || 0);
const df = (o) => new Intl.DateTimeFormat(L === 'fi' ? 'fi-FI' : 'en-GB', { timeZone: TZ, ...o });
const dt = (iso) => `${df({ weekday: 'short', day: 'numeric', month: 'numeric', year: 'numeric' }).format(new Date(iso))} ${df({ hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(iso)).replace('.', ':')}`;
const hm = (iso) => df({ hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(iso)).replace('.', ':');
const nm = (x) => (L === 'en' && x.name_en) || x.name;
const phoneBox = () => h('p', { class: 'bk-contact' }, h('span', { text: `${t.contact} ` }), h('a', { href: `tel:${S.phoneTel}`, text: S.phone }), ' · ', h('a', { href: `mailto:${S.email}`, text: S.email }));
const mount = (...nodes) => { root.replaceChildren(...nodes.flat().filter(Boolean)); root.setAttribute('aria-busy', 'false'); };
const badge = (kind, text) => h('span', { class: `ord-badge ${kind}`, text });
function safeHttps(u) {
  try { const x = new URL(String(u || '')); return x.protocol === 'https:' ? x.href : ''; } catch { return ''; }
}
function instructionsSection(list) {
  if (!list?.length) return null;
  // Otsikko ja lyhyt ohje ovat aina näkyvissä; vain pitkä ohje avataan napista.
  const previews = h('div', { class: 'ord-guide-previews', 'data-testid': 'guide-previews' });
  const panel = h('div', { hidden: true, 'data-testid': 'guide-body' });
  for (const g of list) {
    const short = String(g.short_text ?? '').trim();
    previews.append(h('article', { class: 'ord-guide', 'data-testid': 'guide-preview' },
      g.title ? h('h4', { text: g.title }) : null,
      short ? richHost(h, short, 'ord-guide-short', g.short_rich === true) : null));
    const link = safeHttps(g.link_url);
    panel.append(h('article', { class: 'ord-guide', 'data-testid': 'guide-item' },
      g.title ? h('h4', { text: g.title }) : null,
      richHost(h, g.body, 'ord-guide-text', g.rich),
      link ? h('p', {}, h('a', { href: link, target: '_blank', rel: 'noopener noreferrer', text: t.guideLink })) : null));
  }
  const btn = h('button', { type: 'button', class: 'btn light ord-btn', 'data-testid': 'guide-toggle', 'aria-expanded': 'false', text: t.guideShow, onclick: () => {
    const open = panel.hidden;
    panel.hidden = !open;
    btn.setAttribute('aria-expanded', open ? 'true' : 'false');
    btn.textContent = open ? t.guideHide : t.guideShow;
    if (open) revealIfHidden(panel);
  } });
  return h('section', { class: 'ord-card', 'aria-labelledby': 'ord-g', 'data-testid': 'order-guides' },
    h('h3', { id: 'ord-g', text: t.guideTitle }), h('p', { class: 'bk-note', text: t.guideLead }), previews, btn, panel);
}

async function unsubscribe(token) {
  root.replaceChildren(h('p', { class: 'bk-loading', role: 'status', text: t.loading }));
  let state = 'error';
  if (wantsMock()) state = 'done';
  else {
    try {
      const r = await rpc('public_marketing_unsubscribe', { p_token: token });
      state = r?.ok ? 'done' : 'missing';
    } catch { state = 'error'; }
  }
  const text = state === 'done' ? t.unsubDone : state === 'missing' ? t.unsubMissing : t.unsubError;
  mount(h('section', { class: 'ord-card', role: 'status', 'data-testid': 'unsub-result', 'data-state': state },
    h('h2', { text: t.unsubTitle }), h('p', { text }), phoneBox()));
}
async function main() {
  await applyShopTexts(S);   // sivutekstit tietokannasta (osa 3): puuttuva avain/tiedosto → repon oletus
  const params = new URLSearchParams(location.search);
  const unsub = params.get('u');
  if (validToken(unsub) && !validToken(params.get('t'))) return unsubscribe(unsub);
  const token = params.get('t');
  if (!validToken(token)) return mount(h('p', { class: 'bk-error', role: 'alert', text: t.noToken }), phoneBox());
  const api = createOrderApi({ rpc, token });
  root.replaceChildren(h('p', { class: 'bk-loading', role: 'status', text: t.loading }));
  let o;
  try { o = await api.get(); } catch { return mount(h('p', { class: 'bk-error', role: 'alert', text: t.loadError }), phoneBox()); }
  if (o?.notReady) return mount(h('div', { class: 'bk-notice', role: 'status', 'data-testid': 'not-ready' }, h('p', { text: t.notReady }), phoneBox()));
  if (!o?.ok) return mount(h('p', { class: 'bk-error', role: 'alert', text: t.notFound }), phoneBox());
  // sopimuksen linkki on yksi (/tilaus/?t=…): jos tilauksen kieli (locale) on toinen kuin sivun, siirrytään saman tilauksen toiskieliseen sivuun (token säilyy)
  const want = ['fi', 'en'].includes(o.locale) ? o.locale : L;
  if (want !== L && S.orderHref?.[want] && !new URLSearchParams(location.search).has('mock')) { location.replace(`${S.orderHref[want]}${location.search}`); return; }
  // Lahjakortit (§13): "Käytä lahjakortti" vain kun redeem_enabled; ostetut kortit vain jos tilauksella on niitä. Puuttuva RPC / virhe → ei mitään näkyviin.
  const gapi = createGiftApi({ rpc: api.mock ? api.rpc : rpc, mock: false });
  const gift = { redeem: false, cards: [], claims: [] };
  async function loadGift() {
    const [pk, oc] = await Promise.all([gapi.packages().catch(() => null), gapi.orderCards(token).catch(() => null)]);
    gift.redeem = !!(pk?.ok && pk.redeem_enabled);
    const vc = gift.redeem ? await gapi.orderClaims(token).catch(() => null) : null;   // pyyntöjä haetaan vain kun lunastus on käytössä (muuten ei ylimääräistä RPC-kutsua)
    gift.cards = oc?.ok && Array.isArray(oc.cards) ? oc.cards : [];
    gift.claims = vc?.ok && Array.isArray(vc.claims) ? vc.claims : [];   // kumppanilahjakortit (§13.12): puuttuva RPC / virhe → ei osiota
  }
  // MobilePay (§14): painike vain kun public_payment_options sallii (methods sisältää mobilepayn + order.can_pay_online); testitilan tapa vain testiympäristössä. Puuttuva RPC / virhe → ei painiketta.
  const cfg = window.BOOKING_CONFIG || {}, search = new URLSearchParams(location.search);
  const mpEnv = { testUi: testUiEnabled(cfg, location.search), mock: api.mock, official: cfg.mobilepayOfficialButton !== false };
  const mp = createMobilepayApi({ rpc: api.mock ? api.rpc : rpc, token, functionUrl, anonKey: cfg.anonKey, fetchImpl: api.mock ? api.mpFetch : undefined });
  const vp = createVismapayApi({ token, functionUrl, anonKey: cfg.anonKey, fetchImpl: api.mock ? api.mpFetch : undefined });
  const mpState = { opts: normOptions(null), show: false, checking: false };
  const vpState = { opts: normVisma(null), show: false, checking: false };
  const mpHost = h('div', { 'data-testid': 'mp-result', 'aria-live': 'polite' });
  const num = (k) => { const v = +search.get(k); return Number.isFinite(v) && v > 0 ? v : undefined; };
  const mpTiming = api.mock ? { intervalMs: num('mpinterval'), maxMs: num('mpmax') } : {};   // vain mock-tilassa säädettävissä (testit/esittely)
  async function loadMp() {
    let raw = null;
    try { raw = await mp.options(); } catch { raw = null; }
    mpState.opts = normOptions(raw); mpState.show = shouldShowButton(mpState.opts, mpEnv);
    vpState.opts = normVisma(raw); vpState.show = shouldShowVisma(vpState.opts);
  }
  // Vuosikortin osto (booking_142): koodi näkyy vasta kun kortti on myönnetty (tilaus maksettu). Puuttuva RPC / virhe → ei osiota.
  let annual = null;
  const loadAnnual = async () => { const r = await (api.mock ? api.rpc : rpc)('public_annual_card_purchase_code', { p_token: token }).catch(() => null); annual = r?.ok && r.has_card ? r : null; };
  await Promise.all([loadGift(), loadMp(), loadAnnual()]);
  // Pitotila (§17): pidon pituus (public_checkout_payment_options) ja lahjakortin käyttö (public_get_booking.payment_methods, myös perutut) haetaan vain kun tarvitaan
  const holdX = { minutes: 15, gift: false };
  const giftKey = `bk-gift-${token}`;
  const flagGift = () => { try { return sessionStorage.getItem(giftKey) === '1'; } catch { return false; } };
  async function loadHold(o) {
    const co = o.checkout; if (!co) return;
    const closed = co.expired || (co.cancelled && co.cancelReason === 'hold_expired');
    if ((co.awaiting && !co.processing) || closed) { try { const c = normCheckoutOptions(await mp.checkoutOptions()); if (c.ok && c.holdMinutes) holdX.minutes = c.holdMinutes; } catch { /* oletus 15 */ } }
    if (closed) { let b = null; try { b = await (api.mock ? api.rpc : rpc)('public_get_booking', { p_token: token }); } catch { /* ei tietoa */ } holdX.gift = giftWasUsed(b, flagGift()); }
  }
  let holdCtl = null;
  const stopHold = () => { if (holdCtl) { holdCtl.stop(); holdCtl = null; } };
  await loadHold(o);
  let notice = null;   // vahvistusteksti lunastuspyynnön jälkeen (näytetään pyyntölistan yläosassa, kerran)
  let cur = o;
  const payableStatus = ['unpaid', 'pending', 'partially_paid', 'paid', 'failed'].includes(o.payment_status);
  if (search.get('pay') === 'vismapay' && payableStatus) vpState.checking = true;
  draw(o);
  const redraw = async (n) => { await Promise.all([loadMp(), loadAnnual()]); await loadHold(n); draw(n); };
  async function reloadAfterGift(text) {
    try { if (cur.checkout?.awaiting) sessionStorage.setItem(giftKey, '1'); } catch { /* ei sessionStorage */ }
    try { const n = await api.get(); if (n?.ok) { await loadGift(); await redraw(n); } } catch { /* näkymä jää ennalleen */ }
    flash(true, text);
  }
  // kumppanin lahjakortti lähetetty lunastettavaksi / koodi korjattu: lataa tilaus + pyynnöt uudelleen ja vie vahvistusteksti näkyviin
  async function reloadAfterClaim(n) {
    notice = { ok: true, ...n };
    try { const fresh = await api.get(); if (fresh?.ok) { await loadGift(); await redraw(fresh); } else draw(cur); } catch { draw(cur); }
    const el = root.querySelector('[data-testid=vc-notice]'); if (el) revealForm(el);
  }
  // Paluu MobilePaysta (?pay=mobilepay): reconcile + public_get_order 2,5 s välein enintään ~60 s, lopputulos näkyy sivun yläreunassa (§14.3)
  const returning = () => runReturn({ mp, host: mpHost, S, L, orderNo: o.order_no, timing: mpTiming,
    getOrder: async () => { const n = await api.get(); return n?.ok ? n : null; },
    onState: (st) => { if (st === 'checking') { mpState.checking = true; draw(cur); } },
    onDone: async () => { mpState.checking = false; try { const f = await api.get(); if (f?.ok) cur = f; } catch { /* vanha näkymä */ } await loadMp(); draw(cur); } });
  if (search.get('pay') === 'vismapay' && payableStatus) {
    runVismaReturn({ api: vp, host: mpHost, L,
      getOrder: async () => { const n = await api.get(); return n?.ok ? n : null; },
      onDone: async () => { vpState.checking = false; try { const f = await api.get(); if (f?.ok) cur = f; } catch { /* vanha näkymä */ } await loadMp(); draw(cur); } });
  } else if (search.get('pay') === 'mobilepay' && payableStatus) returning();

  function draw(o) {
    cur = o; stopHold();
    const co = o.checkout, holdV = isHoldView(co), closedHold = !!co && (co.expired || co.cancelled);   // closedHold: vanhentunutta/peruttua tilausta ei lisätä eikä peruta   // co = null → vanha näkymä muuttumattomana
    const stKey = o.cancel_request?.status === 'open' ? 'cancel_requested' : o.status;
    const unpaid = o.unpaid;
    const head = h('section', { class: 'ord-card', 'aria-labelledby': 'ord-h' },
      h('h2', { id: 'ord-h', 'data-testid': 'order-title', text: `${t.order} #${o.order_no}` }),
      h('div', { class: 'ord-badges' }, badge(`st-${stKey}`, holdV ? ht(L, { awaiting_payment: 'status.awaiting', processing_payment: 'status.processing', preliminary: 'status.preliminary', expired: 'status.expired' }[co.state]) : t[`st.${stKey}`] || stKey), badge(`pay-${o.payment_status}`, t[`pay.${o.payment_status}`] || o.payment_status)),
      o.created_at ? h('p', { class: 'bk-meta', text: `${t.created}: ${dt(o.created_at)}` }) : null);
    const dOnly = (ds) => df({ day: 'numeric', month: 'numeric', year: 'numeric' }).format(new Date(`${ds}T12:00:00Z`));
    const annualEl = annual ? h('section', { class: 'ord-card ord-annual', 'aria-labelledby': 'ord-ac', 'data-testid': 'annual-card-code' }, h('h3', { id: 'ord-ac', text: t.annualCodeTitle }),
      annual.code ? [h('p', { class: 'ord-annual-code', text: annual.code }),
        annual.valid_from && annual.valid_to ? h('p', { class: 'bk-meta', text: `${t.annualCodeValid}: ${dOnly(annual.valid_from)} – ${dOnly(annual.valid_to)}` }) : null,
        h('p', { text: t.annualCodeLead }), S.shopHref ? h('p', {}, h('a', { href: S.shopHref, text: t.annualCodeBook })) : null]
        : h('p', { class: 'bk-note', text: t.annualCodePending })) : null;
    const resv = o.reservations.length ? h('section', { class: 'ord-card', 'aria-labelledby': 'ord-rv' }, h('h3', { id: 'ord-rv', text: t.reservationsTitle }),
      h('ul', { class: 'ord-lines', 'data-testid': 'order-reservations' }, o.reservations.map((r) => h('li', {},
        h('span', { class: 'ord-l-main' }, h('strong', { text: r.product_name }), r.status === 'cancelled' ? ' ' : null, r.status === 'cancelled' ? badge('st-cancelled', t.cancelledRow) : null,
          r.option ? h('span', { class: 'ord-l-opt', 'data-testid': 'res-option' }, ` – ${ox.what}: `, h('strong', { text: optName(r.option, L) })) : optionMissingOnOrder(r) && r.status !== 'cancelled' ? [' ', h('span', { class: 'ord-badge opt-missing', 'data-testid': 'res-option-missing', text: `${ox.what}: ${ox.notChosen}` })] : null),
        h('span', { class: 'ord-l-meta', text: `${dt(r.starts_at)}–${hm(r.ends_at)} · ${t.persons.replace('{n}', r.persons)}${r.addons.length ? ' · ' + r.addons.map((a) => `${nm(a)} × ${a.quantity}`).join(', ') : ''}` }))))) : null;
    const optSec = co && (co.expired || co.cancelled) ? null : optionSection(o);
    let holdEl = null;
    if (holdV && !co.expired) {
      holdCtl = holdPanel({ L, co, minutes: holdX.minutes, giftUsed: holdX.gift, newHref: `${S.shopHref}${api.mock ? '?mock=1' : ''}`,
        fmtDate: (ms) => df({ day: 'numeric', month: 'numeric', year: 'numeric' }).format(new Date(ms)),
        refresh: co.awaiting ? async () => { const n = await api.get(); if (n?.ok) cur = n; return n?.ok ? n.checkout : null; } : null,
        onChange: async () => { try { const n = await api.get(); if (n?.ok) { await redraw(n); root.querySelector('[data-testid=hold-panel] h3')?.focus(); return; } } catch { /* vanha näkymä */ } draw(cur); } });   // fokus uuden tilan otsikkoon
      holdEl = holdCtl.node;
    }
    let closedEl = null;
    if (co && (co.expired || co.cancelled)) {
      const holdExp = !!(co.expired || co.cancelReason === 'hold_expired');
      const newHref = `${S.shopHref}${api.mock ? '?mock=1' : ''}`;
      closedEl = h('section', { class: 'ord-card', role: 'status', 'data-testid': 'order-closed', 'data-reason': holdExp ? 'hold_expired' : 'cancelled' },
        h('p', { 'data-testid': 'order-closed-msg', text: holdExp ? t[oneKey('closedHoldExpired', L, { minutes: holdX.minutes }, t)].replace('{minutes}', String(holdX.minutes)) : t.closedCancelled }),
        holdExp && holdX.gift ? h('p', { 'data-testid': 'order-closed-gift', text: t.closedHoldExpiredGift }) : null,
        h('p', { class: 'bk-actions' }, h('a', { class: 'btn gold', href: newHref, 'data-testid': 'order-closed-new', text: t.closedNewBooking })));
    }
    const lines = h('section', { class: 'ord-card', 'aria-labelledby': 'ord-l' }, h('h3', { id: 'ord-l', text: t.linesTitle }),
      h('ul', { class: 'ord-lines', 'data-testid': 'order-lines' }, o.items.map((i) => h('li', {},
        h('span', { class: 'ord-l-main' }, h('strong', { text: i.quantity > 1 ? `${nm(i)} × ${i.quantity}` : nm(i) })),
        h('span', { class: 'ord-l-sum', text: money(i.line_total) })))),
      h('dl', { class: 'ord-sums' }, h('div', {}, h('dt', { text: `${t.total} (${t.vatIncl})` }), h('dd', { 'data-testid': 'order-total', text: money(o.total) })), h('div', {}, h('dt', { text: t.paid }), h('dd', { text: money(o.paid) })),
        h('div', { class: unpaid > 0 ? 'due' : '' }, h('dt', { text: t.unpaid }), h('dd', { 'data-testid': 'order-unpaid', text: money(unpaid) }))));
    // maksulinkki: avoin (pending) maksu + verkkomaksu käytössä → linkki; muuten maksu paikan päällä
    const link = o.online_payment_enabled && !vpState.show ? o.payments.find((p) => p.status === 'pending' && p.link_path) : null;
    const payHidden = !!co && (co.preliminary || co.expired || co.cancelled || co.processing);   // alustavaa/vanhentunutta ei makseta; käsittelyn aikana ei toista maksua
    const checking = mpState.checking || vpState.checking;
    const mpOn = mpState.show && !checking && unpaid > 0;
    const vpOn = vpState.show && !checking && unpaid > 0;
    const mpBlock = mpOn ? payBlock({ S, L, api: mp, opts: mpState.opts, env: mpEnv, showLead: false, showAmount: false, showTest: false, onFail: (code) => { if (['order_expired', 'order_preliminary', 'payment_in_progress'].includes(code)) holdCtl?.poll(true); } }) : null;
    const vpBlock = vpOn ? vismaPayBlock({ L, api: vp, opts: vpState.opts, showLead: false, showAmount: false, showTest: false }) : null;
    const due = money(unpaid);
    const payLead = mpOn && vpOn ? t.payLeadBoth : mpOn ? mt(L, 'payLead') : vpOn ? vt(L, 'payLead') : '';
    const payAmount = mpOn || vpOn ? (mpOn ? mt(L, 'payAmount', { amount: due }) : vt(L, 'payAmount', { amount: due })) : '';
    const mpTest = mpOn && !!mpState.opts?.method?.test;
    const vpTest = vpOn && vpState.opts?.method?.test === true;
    const payTest = mpTest && vpTest ? t.payTestBoth : mpTest ? mt(L, 'testNote') : vpTest ? vt(L, 'testNote') : '';
    const pay = unpaid > 0 && !payHidden ? h('section', { class: 'ord-card ord-pay', 'aria-labelledby': 'ord-p', 'data-testid': 'order-pay' },
      h('h3', { id: 'ord-p', class: 'mp-title', text: t.paymentTitle }),
      payLead ? h('p', { class: 'bk-note', 'data-testid': 'ord-pay-lead', text: payLead }) : null,
      payAmount ? h('p', { class: 'mp-amount', 'data-testid': 'ord-pay-amount', text: payAmount }) : null,
      payTest ? h('p', { class: 'mp-test', role: 'note', 'data-testid': mpTest && vpTest ? 'ord-pay-test' : mpTest ? 'mp-test-note' : 'vp-test', text: payTest }) : null,
      co?.awaiting ? h('p', { class: 'bk-note', 'data-testid': 'ord-hold-choose', text: ht(L, 'choose') }) : null,
      vpBlock || mpBlock ? h('div', { class: 'ord-pay-methods', 'data-testid': 'ord-pay-methods' }, vpBlock, mpBlock) : null,
      checking || vpState.show ? null : link ? h('a', { class: 'btn ord-btn', 'data-testid': 'pay-link', href: S.base ? S.base + link.link_path : link.link_path, text: `${t.payRest} (${money(unpaid)})` })
        : mpBlock ? null : h('button', { type: 'button', class: 'btn light ord-btn', disabled: true, 'data-testid': 'pay-rest', text: `${t.payRest} (${money(unpaid)})` }),
      link || mpBlock || vpBlock || checking || vpState.show ? null : h('p', { class: 'bk-note', text: t.payRestSoon })) : null;
    const giftCards = gift.cards.length ? cardsSection({ S, L, api: gapi, cards: gift.cards }) : null;
    const giftUse = gift.redeem && unpaid > 0 && !payHidden && !gift.cards.length && ['confirmed', 'pending'].includes(o.status) ? redeemSection({ L, api: gapi, token, onApplied: reloadAfterGift, onClaimed: reloadAfterClaim, onFail: (code) => { if (['order_expired', 'order_preliminary', 'payment_in_progress'].includes(code)) holdCtl?.poll(true); } }) : null;
    const claimBox = gift.claims.length ? claimsSection({ S, L, api: gapi, token, claims: gift.claims, notice, onChanged: reloadAfterClaim }) : null;
    notice = null;
    const receipts = h('section', { class: 'ord-card', 'aria-labelledby': 'ord-r' }, h('h3', { id: 'ord-r', text: t.receiptsTitle }),
      o.receipts.length ? h('ul', { class: 'ord-lines', 'data-testid': 'receipts' }, o.receipts.map((r) => h('li', {},
        h('span', { class: 'ord-l-main' }, h('strong', { text: r.receipt_no }), ' ', badge('', t[r.kind] || r.kind)), h('span', { class: 'ord-l-meta', text: `${r.issued_at ? dt(r.issued_at) : ''}${r.total ? ' · ' + money(r.total) : ''}` }),
        h('span', { class: 'ord-l-sum' }, h('button', { type: 'button', class: 'btn light ord-btn', 'data-testid': 'receipt-dl', onclick: (ev) => download(ev.currentTarget, r.receipt_no), text: t.download }))))) : h('p', { class: 'bk-note', text: t.noReceipts }));
    const msg = h('div', { 'aria-live': 'polite', class: 'ord-msg', 'data-testid': 'order-msg' });
    const note = o.change_deadline ? h('p', { class: 'bk-note', 'data-testid': 'change-note', text: o.can_change ? t.changeNote.replace('{date}', dt(o.change_deadline)) : t.changeClosed }) : null;
    const guides = instructionsSection(o.instructions);
    const treats = (o.upsell_treatments || []).length ? h('div', { 'data-testid': 'upsell-treatments' }, h('p', { class: 'bk-note', text: t.treatLead }), h('ul', { class: 'ord-lines' }, o.upsell_treatments.map((x) => h('li', { text: nm(x) })))) : null;
    const add = closedHold || o.reservations.length === 0 ? null : h('section', { class: 'ord-card', 'aria-labelledby': 'ord-a' }, h('h3', { id: 'ord-a', text: t.addTitle }), o.can_add && o.upsell_addons.length ? addForm(o) : h('p', { class: 'bk-note', text: t.addClosed }), treats,
      h('p', { class: 'bk-note' }, `${t.addNewBooking} `, h('a', { href: S.shopHref, text: t.addNewBookingLink })));
    const extra = guides || add ? h('div', { class: 'ord-extra', 'data-testid': 'order-extra' }, guides, add) : null;
    const cancel = closedHold || o.reservations.length === 0 ? null : h('section', { class: 'ord-card', 'aria-labelledby': 'ord-c', 'data-testid': 'cancel-section' }, h('h3', { id: 'ord-c', text: t.cancelTitle }), ...cancelBody(o, note));
    mount(api.mock ? h('p', { class: 'ord-mock', role: 'status', 'data-testid': 'mock-banner', text: t.mockBanner }) : null, h('div', { class: 'ord', 'data-testid': 'order-page' }, mpHost, head, holdEl, closedEl, resv, optSec, lines, pay, giftCards, claimBox, annualEl, giftUse, receipts, extra, cancel, msg, phoneBox()));
  }
  async function download(btn, receiptNo) {
    btn.disabled = true;
    try {
      const r = await api.getReceipt({ receiptNo });
      if (r?.notReady || !r?.ok) throw new Error('receipt');
      const url = r.pdf_url || URL.createObjectURL(new Blob([r.text_body || ''], { type: 'text/plain;charset=utf-8' }));
      const a = h('a', { href: url, download: r.pdf_url ? null : `${receiptNo}.txt`, target: r.pdf_url ? '_blank' : null, rel: 'noopener' }); document.body.append(a); a.click(); a.remove();
    } catch { flash(false, t.error); } finally { btn.disabled = false; }
  }
  const flash = (ok, text) => { const m = root.querySelector('[data-testid=order-msg]'); if (m) { m.replaceChildren(h('p', { class: ok ? 'bk-ok' : 'bk-error', role: ok ? 'status' : 'alert', text })); revealIfHidden(m); } };
  // palvelimen virhe {ok:false, code, message}: tunnetut koodit omilla teksteillään, muuten palvelimen (suomenkielinen) viesti
  const failText = (r) => (r?.code && (t[`err.${r.code}`] || holdError(L, r.code))) || (T[L] || T.fi).errorGeneric;   // palvelimen raaka message ei asiakkaalle (ui.shop.error_generic)
  function addForm(o) {
    const sel = h('select', { id: 'ord-addon', 'data-testid': 'add-select' }, o.upsell_addons.map((x) => h('option', { value: x.code, text: `${nm(x)} (${money(x.price)})` })));
    const res = o.reservations.filter((r) => r.status !== 'cancelled');
    const resSel = res.length > 1 ? h('select', { id: 'ord-res', 'data-testid': 'add-reservation' }, res.map((r) => h('option', { value: r.reservation_id, text: `${r.product_name} · ${dt(r.starts_at)}` }))) : null;
    const qty = h('input', { id: 'ord-qty', type: 'number', min: 1, max: 20, value: 1, inputmode: 'numeric', 'data-testid': 'add-qty' });
    const syncMax = () => { const a = o.upsell_addons.find((x) => x.code === sel.value); qty.max = a?.max || 20; if (+qty.value > +qty.max) qty.value = qty.max; };
    sel.addEventListener('change', syncMax); syncMax();
    const btn = h('button', { type: 'submit', class: 'btn ord-btn', 'data-testid': 'add-submit', text: t.addSubmit });
    const f = h('form', { class: 'ord-form', onsubmit: async (ev) => {
      ev.preventDefault(); btn.disabled = true;
      try {
        const item = { type: 'addon', code: sel.value, quantity: Math.min(+qty.max, Math.max(1, Math.trunc(+qty.value) || 1)) };
        const rid = resSel ? +resSel.value : res[0]?.reservation_id; if (rid) item.reservation_id = rid;
        const r = await api.addToOrder({ items: [item] });
        if (r?.notReady) throw new Error('add');
        if (r?.ok === false) { flash(false, failText(r)); btn.disabled = false; return; }
        const fresh = await api.get(); if (!fresh?.ok) throw new Error('get'); await redraw(fresh); flash(true, t.addDone);
      } catch { flash(false, t.error); btn.disabled = false; }
    } }, h('p', { class: 'bk-note', text: t.addLead }),
    resSel ? h('div', { class: 'bk-field' }, h('label', { for: 'ord-res', text: t.addReservation }), resSel) : null,
    h('div', { class: 'bk-field' }, h('label', { for: 'ord-addon', text: t.addAddon }), sel), h('div', { class: 'bk-field' }, h('label', { for: 'ord-qty', text: t.addQty }), qty), btn);
    return f;
  }
  // Hoidon valinta/vaihto (booking_50): varaukset, joilla on option_choices; vaihto public_change_order_time (vain p_option_code), vain kun can_change. Null (vanha varaus) → "valitsematta" + pyyntö valita (ei pakollinen).
  function optionSection(o) {
    const list = o.reservations.filter((r) => r.status !== 'cancelled' && r.option_choices.length);
    if (!list.length) return null;
    return h('section', { class: 'ord-card', 'aria-labelledby': 'ord-o', 'data-testid': 'option-section' }, h('h3', { id: 'ord-o', text: ox.changeTitle }),
      o.change_deadline ? h('p', { class: 'bk-note', text: o.can_change ? ox.changeLead.replace('{date}', dt(o.change_deadline)) : ox.changeClosed }) : null,
      list.map((r, i) => {
        const missing = !r.option;
        const head = list.length > 1 ? h('h4', { text: `${r.product_name} · ${dt(r.starts_at)}` }) : null;
        if (!o.can_change) return h('div', { class: 'ord-opt-sec' }, head, h('p', { 'data-testid': 'option-current' }, `${ox.current}: `, h('strong', { text: missing ? ox.notChosen : optName(r.option, L) })));
        const pk = createOptionPicker({ h, lang: L, options: r.option_choices, value: r.option?.code ?? null, required: null, label: rowLabel(r, L) || (missing ? ox.defaultLabel : ox.changeLabel), hint: missing ? `${ox.notChosenNote} ${ox.hintChange}` : ox.hintChange, step: null, testid: `option-picker-${r.reservation_id}`,
          onChange: () => { btn.disabled = !optionChanged(r, pk.get()); } });
        const btn = h('button', { type: 'button', class: 'btn ord-btn', disabled: true, 'data-testid': `option-save-${r.reservation_id}`, text: ox.changeSave });
        btn.addEventListener('click', async () => {
          const code = pk.get(); if (!optionChanged(r, code)) { pk.setError(ox['err.option_required']); return; }
          btn.disabled = true; btn.textContent = ox.changeSaving;
          try {
            const res = await api.changeOrderTime({ reservationId: r.reservation_id, optionCode: code });
            if (res?.notReady) throw new Error('change');
            if (res?.ok === false) { btn.textContent = ox.changeSave; btn.disabled = false; if (['option_required', 'invalid_option'].includes(res.code)) { pk.setError(ox[`err.${res.code}`]); pk.focus(); } else flash(false, failText(res)); return; }
            const fresh = await api.get(); if (!fresh?.ok) throw new Error('get'); await redraw(fresh); flash(true, ox.changeDone);
          } catch { btn.textContent = ox.changeSave; btn.disabled = false; flash(false, t.error); }
        });
        return h('div', { class: 'ord-opt-sec' }, head, h('div', { class: 'ord-opt' }, pk.node, btn));
      }));
  }
  // booking_149: palvelin kertoo, saako asiakas vielä pyytää peruutusta (vähintään cancel_hours_before h ennen vuoron alkua). Rajan jälkeen lomaketta ei näytetä,
  // vaan teksti + puhelinnumero (tel-linkki). Vanha backend (can_request_cancel puuttuu) → kuten ennen: muutosnote + lomake.
  function cancelBody(o, note) {
    if (o.cancel_request) return [note, h('p', { class: 'bk-ok', role: 'status', 'data-testid': 'cancel-pending', text: t[`cancel.${o.cancel_request.status}`] || t['cancel.open'] })];
    if (o.can_request_cancel == null) return [note, cancelForm()];
    const hours = String(o.cancel_hours_before ?? 48);
    if (o.cancel_closed) return [phoneText(t[oneKey('cancelClosed', L, { hours }, t)].split('{hours}').join(hours), { class: 'bk-note ord-cancel-closed', role: 'status', 'data-testid': 'cancel-closed' })];
    if (!o.can_request_cancel) return [note];
    const rule = o.cancel_deadline ? h('p', { class: 'bk-note', 'data-testid': 'cancel-rule', text: t[oneKey('cancelRule', L, { hours }, t)].split('{hours}').join(hours).replace('{date}', dt(o.cancel_deadline)) }) : note;
    return [rule, cancelForm()];
  }
  // {phone} (repon oletus) tai jo täytetty numero (sivuteksti {{var:phone}} → S.phone) → tel-linkki
  function phoneText(text, attrs) {
    const mark = text.includes('{phone}') ? '{phone}' : S.phone && text.includes(S.phone) ? S.phone : null;
    if (!mark) return h('p', attrs, text, ' ', h('a', { href: `tel:${S.phoneTel}`, text: S.phone }));
    const [a, ...rest] = text.split(mark);
    return h('p', attrs, a, h('a', { href: `tel:${S.phoneTel}`, 'data-testid': 'cancel-phone', text: S.phone }), rest.join(mark));
  }
  function cancelForm() {
    const reason = h('textarea', { id: 'ord-reason', rows: 3, maxlength: 500, 'data-testid': 'cancel-reason' });
    const btn = h('button', { type: 'submit', class: 'btn light ord-btn', 'data-testid': 'cancel-submit', text: t.cancelSubmit });
    return h('form', { class: 'ord-form', onsubmit: async (ev) => {
      ev.preventDefault(); if (!confirm(t.cancelConfirm)) return; btn.disabled = true;
      try {
        const r = await api.requestCancel({ reason: reason.value.trim() });
        if (r?.notReady) throw new Error('cancel');
        if (r?.ok === false && r.code === 'cancel_too_late') { const fresh = await api.get(); if (fresh?.ok) await redraw(fresh); flash(false, failText(r)); return; }   // booking_149: raja ylittyi sivun ollessa auki
        if (r?.ok === false && r.code !== 'request_exists') { flash(false, failText(r)); btn.disabled = false; return; }
        const fresh = await api.get(); if (!fresh?.ok) throw new Error('get'); await redraw(fresh); flash(true, r?.ok === false ? t['cancel.open'] : t.cancelDone);
      } catch { flash(false, t.error); btn.disabled = false; }
    } }, h('p', { class: 'bk-note', text: t.cancelLead }), h('div', { class: 'bk-field' }, h('label', { for: 'ord-reason', text: t.cancelReason }), reason), btn);
  }
}
main();
