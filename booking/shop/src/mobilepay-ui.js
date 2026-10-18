// MobilePay-maksun käyttöliittymä (kauppa): "Maksa MobilePaylla" -painike ja paluutilan (?pay=mobilepay) näkymä. Käytössä tilaussivulla (order.js) ja varausvahvistussivulla (shop.js).
// Painike on Vipps MobilePayn virallinen web-komponentti <vipps-mobilepay-button> (brand=mobilepay, verb=pay, variant=primary), ladataan viralliselta CDN:ltä vasta kun painike näytetään.
// Jos komponentti ei lataudu (CDN estetty, offline) näytetään ohjeen mukainen varapainike (MobilePay-sininen, valkoinen teksti, ei omaa logoa).
import { h } from './gift-ui.js';
import { mt } from './mobilepay-texts.js';
import { pollPayment, safeRedirect, shouldShowButton, normOptions, POLL_INTERVAL_MS, POLL_MAX_MS } from './mobilepay-logic.js';

export const OFFICIAL_SRC = 'https://cdn.vippsmobilepay.com/js/button/button.js';
const TAG = 'vipps-mobilepay-button';

// Lataa virallisen painikekomponentin kerran. Resolve true = komponentti määritelty, false = ei saatu (virhe / aikakatkaisu).
export function loadOfficialButton({ timeoutMs = 5000, src = OFFICIAL_SRC } = {}) {
  if (typeof customElements === 'undefined') return Promise.resolve(false);
  if (customElements.get(TAG)) return Promise.resolve(true);
  if (!loadOfficialButton.p) {
    loadOfficialButton.p = new Promise((ok) => {
      const done = (v) => { clearTimeout(timer); ok(v); };
      const timer = setTimeout(() => done(!!customElements.get(TAG)), timeoutMs);
      const s = document.createElement('script');
      s.src = src; s.async = true; s.referrerPolicy = 'no-referrer'; s.dataset.mobilepayButton = '1';
      s.onload = () => { customElements.whenDefined(TAG).then(() => done(true)); };
      s.onerror = () => { loadOfficialButton.p = null; s.remove(); done(false); };
      document.head.append(s);
    });
  }
  return loadOfficialButton.p;
}

// Painike: official=true → virallinen komponentti (kun latautuu), muuten/varalla oma varapainike. Palauttaa { node, setBusy(b) }.
export function buttonNode({ L, onActivate, official = true, loadOfficial = loadOfficialButton }) {
  const tx = (k, v) => mt(L, k, v);
  const holder = h('div', { class: 'mp-btnwrap', 'data-testid': 'mp-btnwrap' });
  let el = null, busy = false;
  const setBusy = (b) => {
    busy = b;
    if (!el) return;
    if (el.dataset.kind === 'official') { el.loading = b; el.disabled = b; if (b) el.setAttribute('aria-busy', 'true'); else el.removeAttribute('aria-busy'); }
    else { el.disabled = b; el.textContent = b ? tx('payBusy') : tx('payBtn'); }
  };
  const activate = () => { if (!busy) onActivate(); };
  const useFallback = () => {
    el = h('button', { type: 'button', class: 'mp-fallback', 'data-testid': 'mp-button', 'data-kind': 'fallback', onclick: activate, text: tx('payBtn') });
    holder.replaceChildren(el); holder.dataset.kind = 'fallback'; setBusy(busy);
  };
  const useOfficial = () => {
    el = document.createElement(TAG);
    for (const [k, v] of Object.entries({ brand: 'mobilepay', language: L === 'en' ? 'en' : 'fi', verb: 'pay', variant: 'primary', rounded: 'true', stretched: 'true' })) el.setAttribute(k, v);
    el.setAttribute('data-testid', 'mp-button'); el.dataset.kind = 'official';
    el.addEventListener('click', activate);
    holder.replaceChildren(el); holder.dataset.kind = 'official'; setBusy(busy);
  };
  holder.setAttribute('aria-busy', 'true');
  (official ? loadOfficial() : Promise.resolve(false)).then((ok) => { holder.removeAttribute('aria-busy'); ok ? useOfficial() : useFallback(); }, () => { holder.removeAttribute('aria-busy'); useFallback(); });
  return { node: holder, setBusy };
}

// Maksuosio: otsikko, ohje, (testitilan merkintä), painike, virheilmoitus. opts = normOptions(public_payment_options).
export function payBlock({ S, L, api, opts, env = {}, amount = '', navigate = (u) => location.assign(u), showLead = true, onFail = null }) {
  const tx = (k, v) => mt(L, k, v);
  const msg = h('div', { class: 'ord-msg mp-msg', 'aria-live': 'polite', 'data-testid': 'mp-msg' });
  const hasKey = (k) => mt(L, k) !== k;
  const failMsg = (r) => (r?.code && hasKey(`err.${r.code}`) ? tx(`err.${r.code}`) : (L === 'fi' && r?.message && !['network', 'timeout'].includes(r.code) ? r.message : tx('err.generic')));
  let busy = false, btn = null;
  async function activate() {
    if (busy) return;
    busy = true; btn.setBusy(true); msg.replaceChildren();
    let r = null;
    try { r = await api.start(); } catch { r = { ok: false, code: 'network' }; }
    const url = r?.ok ? safeRedirect(r.redirect_url, { allowHttpLocal: !!env.mock }) : null;
    if (url) { navigate(url); return; }   // painike pysyy lukittuna kunnes sivu vaihtuu
    msg.replaceChildren(h('p', { class: 'bk-error', role: 'alert', 'data-testid': 'mp-error', 'data-code': r?.code || 'no_url', text: r?.ok ? tx('err.generic') : failMsg(r) }));
    busy = false; btn.setBusy(false);
    if (onFail && r?.code) { try { onFail(r.code); } catch { /* ei estä virheviestiä */ } }   // pito: order_expired / order_preliminary / payment_in_progress → sivu hakee tilan uudelleen
  }
  btn = buttonNode({ L, onActivate: activate, official: env.official !== false });
  if (typeof window !== 'undefined') window.addEventListener('pageshow', (e) => { if (e.persisted) { busy = false; btn.setBusy(false); } });   // paluu selaimen Takaisin-napilla (bfcache)
  return h('div', { class: 'mp-block', 'data-testid': 'mp-block' },
    h('h4', { class: 'mp-title', text: tx('payTitle') }),
    showLead ? h('p', { class: 'bk-note', text: tx('payLead') }) : null,
    amount ? h('p', { class: 'mp-amount', text: tx('payAmount', { amount }) }) : null,
    opts?.pending ? h('p', { class: 'bk-note', 'data-testid': 'mp-pending-hint', text: tx('pendingHint') }) : null,
    opts?.method?.test ? h('p', { class: 'mp-test', role: 'note', 'data-testid': 'mp-test-note', text: tx('testNote') }) : null,
    btn.node, msg);
}

// Paluutilan paneeli. state: checking | paid | review | failed | slot_lost | contact | wait | none | net
const PANEL = { checking: ['checking', 'checkingLead', 'info'], paid: ['paidTitle', 'paidLead', 'ok'], review: ['reviewTitle', 'reviewLead', 'ok'], failed: ['failedTitle', 'failedLead', 'err'], slot_lost: ['slotTitle', 'slotLead', 'err'],
  contact: ['contactTitle', 'contactLead', 'err'], wait: ['waitTitle', 'waitLead', 'info'], none: ['noneTitle', 'noneLead', 'info'], net: ['netTitle', 'netLead', 'err'] };
export function resultPanel({ S, L, state, orderNo, onRecheck }) {
  const tx = (k, v) => mt(L, k, v);
  const [title, lead, kind] = PANEL[state] || PANEL.net;
  const contact = ['review', 'contact', 'wait', 'net', 'slot_lost'].includes(state);
  return h('section', { class: `ord-card mp-result ${kind}`, 'data-testid': 'mp-result-panel', 'data-state': state, role: kind === 'err' ? 'alert' : 'status', 'aria-busy': state === 'checking' ? 'true' : null },
    state === 'checking' ? h('span', { class: 'mp-spin', 'aria-hidden': 'true' }) : null,
    h('h3', { 'data-testid': 'mp-result-title', text: tx(title) }), h('p', { text: tx(lead) }),
    orderNo ? h('p', { class: 'bk-meta' }, `${tx('orderNo')} #${orderNo}`) : null,
    state === 'wait' || state === 'net' ? h('button', { type: 'button', class: 'btn ord-btn', 'data-testid': 'mp-recheck', onclick: onRecheck, text: tx('recheck') }) : null,
    state === 'slot_lost' && S?.shopHref ? h('a', { class: 'btn ord-btn', href: S.shopHref, 'data-testid': 'mp-calendar', text: tx('openCalendar') }) : null,
    contact && S?.phoneTel ? h('p', { class: 'bk-contact' }, h('span', { text: `${tx('contact')} ` }), h('a', { href: `tel:${S.phoneTel}`, text: S.phone }), ' · ', h('a', { href: `mailto:${S.email}`, text: S.email })) : null);
}

export const stripPayParam = (loc = location, hist = history) => { try { const u = new URL(loc.href); if (!u.searchParams.has('pay')) return; u.searchParams.delete('pay'); hist.replaceState(hist.state, '', u.pathname + u.search + u.hash); } catch { /* ei merkitystä */ } };

// Paluutilan ajo: näyttää "Tarkistetaan…", kysyy tilaa (reconcile + public_get_order) ja näyttää lopputuloksen hostissa. Palauttaa { state, order }.
// deps: { mp (api), getOrder, host, S, L, orderNo, sleep, now, timing, strip, onState(state), onDone(res) }
export async function runReturn({ mp, getOrder, host, S, L, orderNo, sleep = (ms) => new Promise((ok) => setTimeout(ok, ms)), now = () => Date.now(), timing = {}, strip = stripPayParam, onState = () => {}, onDone = async () => {} }) {
  const show = (state) => { host.replaceChildren(resultPanel({ S, L, state, orderNo, onRecheck: () => { onState('checking'); runReturn({ mp, getOrder, host, S, L, orderNo, sleep, now, timing, strip, onState, onDone }); } })); host.dataset.state = state; };
  show('checking'); onState('checking');
  const res = await pollPayment({ reconcile: () => mp.reconcile(), getOrder, sleep, now }, { intervalMs: timing.intervalMs ?? POLL_INTERVAL_MS, maxMs: timing.maxMs ?? POLL_MAX_MS });
  show(res.state); onState(res.state, res.order);
  if (!['wait', 'net'].includes(res.state)) strip();
  await onDone(res);   // §14.3: pay-parametri pois onnistumisen/epäonnistumisen jälkeen (odottava tila säilyttää sen: sivun lataus tarkistaa uudelleen)
  return res;
}
export { normOptions, shouldShowButton };
