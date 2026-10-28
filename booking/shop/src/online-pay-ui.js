// Yksi verkkomaksuosio: viisi tapaa (pankki, kortti, Apple Pay, Google Pay, MobilePay), paluu ilman välittäjän nimeä.
// Maksutapapainikkeet (paymentMethodList) ovat sama komponentti tilaussivulla, vahvistuksessa, kassalla, maksulinkissä, lahjakortin ja vuosikortin maksussa (tilaussivu) ja juomasivulla.
import { h } from './gift-ui.js';
import { pt } from './pay-choices-texts.js';
import { onlineChoices, safeOnlineRedirect } from './online-pay-logic.js';

const ERR = { network: 'errNetwork', timeout: 'errNetwork', rate_limited: 'errRate', online_off: 'errOff', vismapay_off: 'errOff', not_configured: 'errOff', maintenance: 'errOff', payment_in_progress: 'errBusy', already_paid: 'errPaid' };
const SVG = 'http://www.w3.org/2000/svg';
const STROKE = { fill: 'none', stroke: 'currentColor', 'stroke-width': '1.6', 'stroke-linecap': 'round', 'stroke-linejoin': 'round' };

export function methodLabelKey(method) {
  return { paymentInitiation: 'methodBank', cardPayments: 'methodCard', applePay: 'methodApple', googlePay: 'methodGoogle', mobilePay: 'methodWallet' }[method] || 'methodBank';
}

/** Vaihtaa vain nappitekstin, jotta kuvake säilyy. */
export function setMethodLabel(btn, text) {
  if (btn?._opLabel) btn._opLabel.textContent = text;
  else if (btn) btn.textContent = text;
}

export function setBusyState(el, on) {
  if (!el?.setAttribute) return;
  if (on) el.setAttribute('aria-busy', 'true');
  else if (typeof el.removeAttribute === 'function') el.removeAttribute('aria-busy');
  else if (el.attrs) delete el.attrs['aria-busy'];
}

function svgEl(tag, attrs) {
  const el = typeof document.createElementNS === 'function' ? document.createElementNS(SVG, tag) : document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  return el;
}
function iconSvg(parts) {
  const s = svgEl('svg', { viewBox: '0 0 24 24', 'aria-hidden': 'true', focusable: 'false' });
  for (const [tag, attrs] of parts) s.append(svgEl(tag, attrs));
  return s;
}

// Omat viivakuvakkeet (ei tavaramerkkilogot). Nimet tulevat tekstistä.
const MARKS = {
  paymentInitiation: [
    ['path', { ...STROKE, d: 'M4 10.2 12 4.5l8 5.7' }],
    ['path', { ...STROKE, d: 'M6.5 10.2V19M12 10.2V19M17.5 10.2V19M4 19.5h16' }],
  ],
  cardPayments: [
    ['rect', { ...STROKE, x: '3', y: '5.5', width: '18', height: '13', rx: '2.2' }],
    ['path', { ...STROKE, d: 'M3 9.5h18' }],
    ['rect', { x: '6', y: '12.2', width: '3.4', height: '2.5', rx: '.4', fill: 'currentColor' }],
  ],
  applePay: [
    ['rect', { ...STROKE, x: '8', y: '2.8', width: '8', height: '18.4', rx: '2' }],
    ['path', { ...STROKE, d: 'M11 5.3h2' }],
    ['circle', { cx: '12', cy: '18.2', r: '.85', fill: 'currentColor' }],
  ],
  googlePay: [
    ['path', { ...STROKE, d: 'M7 7.2V6.2A2.2 2.2 0 0 1 9.2 4h5.6A2.2 2.2 0 0 1 17 6.2v1' }],
    ['rect', { ...STROKE, x: '3', y: '7.2', width: '18', height: '12.3', rx: '2' }],
    ['path', { ...STROKE, d: 'M3 11.2h18' }],
    ['circle', { cx: '16.2', cy: '14.6', r: '1', fill: 'currentColor' }],
  ],
  mobilePay: [
    ['rect', { ...STROKE, x: '4.5', y: '3.5', width: '9', height: '17', rx: '1.8' }],
    ['path', { ...STROKE, d: 'M16.2 9.2a3.6 3.6 0 0 1 0 5.2M18.5 7a6.4 6.4 0 0 1 0 9.6' }],
  ],
  gift: [
    ['rect', { ...STROKE, x: '3.5', y: '10', width: '17', height: '9.5', rx: '1.6' }],
    ['path', { ...STROKE, d: 'M3.5 14.2h17M12 10v9.5' }],
    ['path', { ...STROKE, d: 'M12 10c-1.4-2.6-4.6-2.5-4.6.1 0 1.5 2.2 2.2 4.6-.1 2.4 2.3 4.6 1.6 4.6.1 0-2.6-3.2-2.7-4.6-.1Z' }],
  ],
  chevron: [['path', { ...STROKE, d: 'M9 6.5 15 12l-6 5.5' }]],
};

// Viralliset merkit (Apple Pay, Google Pay, MobilePay): sama tiedosto kuin alatunnisteessa (public/img/pay/).
// Ei värjätä eikä kehystetä vihreään laattaan: merkin omat värit ja tyhjä tila säilyvät.
const BRAND_FILE = { applePay: 'apple-pay.svg', googlePay: 'google-pay.svg', mobilePay: 'mobilepay.svg' };
function payMarkSrc(file) {
  const cfg = typeof window !== 'undefined' ? window.BOOKING_CONFIG : null;
  const shop = typeof window !== 'undefined' ? window.BOOKING_SHOP : null;
  const base = (cfg && cfg.payMarks) || (shop?.links?.base != null ? `${shop.links.base}/img/pay/` : '/img/pay/');
  return `${String(base).replace(/\/?$/, '/')}${file}`;
}
export function payMark(kind) {
  if (BRAND_FILE[kind]) {
    const wrap = h('span', { class: 'op-method-mark', 'aria-hidden': 'true' });
    wrap.append(h('img', { src: payMarkSrc(BRAND_FILE[kind]), alt: '', width: 54, height: 22, decoding: 'async' }));
    return wrap;
  }
  const wrap = h('span', { class: kind === 'gift' ? 'op-gift-ico' : 'op-method-ico', 'aria-hidden': 'true' });
  wrap.append(iconSvg(MARKS[kind] || MARKS.cardPayments));
  return wrap;
}

/**
 * Sama maksutaparivi kaikkialla. choices: [{method, label}]. onSelect(choice, button, label).
 * Ei aloita maksua itse.
 */
export function paymentMethodList({ choices, onSelect, testId, groupTestId = 'op-methods', selected = null }) {
  const buttons = [];
  const nodes = choices.map((c) => {
    const on = selected != null && c.method === selected;
    const lab = h('span', { class: 'op-method-label', text: c.label });
    const go = h('span', { class: 'op-method-go', 'aria-hidden': 'true' });
    go.append(iconSvg(MARKS.chevron));
    const btn = h('button', {
      type: 'button', class: on ? 'op-method is-on' : 'op-method', 'data-testid': testId(c),
      ...(selected != null ? { 'aria-pressed': on ? 'true' : 'false' } : {}),
      onclick: () => onSelect(c, btn, c.label),
    }, payMark(c.method), lab, go);
    btn._opLabel = lab;
    buttons.push(btn);
    return btn;
  });
  return { root: h('div', { class: 'op-methods', 'data-testid': groupTestId }, ...nodes), buttons };
}

export function onlinePayBlock({ L, api, method, env = {}, amount = '', navigate = (u) => location.assign(u), showTest = true, testid = 'op-method', onFail = null }) {
  const tx = (k, v) => pt(L, k, v);
  const msg = h('div', { class: 'ord-msg', 'aria-live': 'polite', 'data-testid': 'op-msg' });
  const choices = onlineChoices(method).map((c) => ({ method: c.method, label: L === 'en' ? (c.labelEn || tx(methodLabelKey(c.method))) : (c.label || tx(methodLabelKey(c.method))) }));
  let busy = false;
  let buttons = [];
  function restore(btn, label) {
    busy = false;
    setBusyState(btn, false);
    for (const b of buttons) b.disabled = false;
    setMethodLabel(btn, label);
  }
  async function go(code, btn, label) {
    if (busy) return;
    busy = true;
    for (const b of buttons) b.disabled = true;
    setBusyState(btn, true);
    setMethodLabel(btn, tx('payBusyOnline'));
    msg.replaceChildren();
    let r = null;
    try { r = await api.start(code); } catch { r = { ok: false, code: 'network' }; }
    const url = r?.ok ? safeOnlineRedirect(r.redirect_url) : null;
    if (url) { navigate(url); return; }
    if (r?.ok && (r.dry_run || r.mode === 'dry_run')) {
      msg.replaceChildren(h('p', { class: 'bk-note', role: 'status', 'data-testid': 'op-dryrun', text: tx('payTestOnline') }));
      restore(btn, label);
      return;
    }
    const key = ERR[r?.code] || 'errGeneric';
    msg.replaceChildren(h('p', { class: 'bk-error', role: 'alert', 'data-testid': 'op-error', 'data-code': r?.code || 'generic', text: tx(key) }));
    restore(btn, label);
    if (onFail) onFail(r?.code);
  }
  const list = paymentMethodList({ choices, testId: (c) => `${testid}-${c.method}`, onSelect: (c, btn, label) => go(c.method, btn, label) });
  buttons = list.buttons;
  return h('div', { class: 'op-block', 'data-testid': 'op-block' },
    showTest && method?.test === true ? h('p', { class: 'bk-note op-testnote', 'data-testid': 'op-test', text: tx('payTestOnline') }) : null,
    amount ? h('p', { class: 'mp-amount', 'data-testid': 'op-amount', text: tx('amountDue', { amount }) }) : null,
    list.root,
    msg);
}

/** Paluu maksusivulta. reconcile (vanha kesken oleva yritys) on valinnainen; näyttö ei nimeä välittäjää. */
export async function runOnlineReturn({ host, L, getOrder, reconcile = null, onDone, intervalMs = 2500, rounds = 8 }) {
  const tx = (k) => pt(L, k);
  const show = (state) => {
    const key = state === 'paid' ? 'returnPaid' : state === 'review' ? 'returnReview' : state === 'failed' ? 'returnFailed' : 'returnWait';
    host.replaceChildren(h('section', { class: 'ord-card', role: 'status', 'data-testid': 'op-return', 'data-state': state },
      h('h3', { text: tx(key) }), h('p', { text: tx(key + 'Lead') })));
  };
  host.replaceChildren(h('section', { class: 'ord-card', role: 'status', 'data-testid': 'op-return', 'data-state': 'checking' },
    h('h3', { text: tx('returnChecking') }), h('p', { text: tx('returnCheckingLead') })));
  let state = 'wait';
  for (let i = 0; i < rounds; i++) {
    if (reconcile) { try { const r = await reconcile(); if (r?.payment_status === 'paid') { state = 'paid'; break; } } catch { /* jatketaan tilauksen kyselyyn */ } }
    try {
      const o = await getOrder();
      if (o?.payment_status === 'paid') { state = 'paid'; break; }
      if (o?.payment_status === 'failed') { state = 'failed'; break; }
    } catch { /* jatketaan */ }
    if (i < rounds - 1) await new Promise((ok) => setTimeout(ok, intervalMs));
  }
  show(state);
  if (state === 'paid' || state === 'failed' || state === 'review') stripPayParam();
  if (onDone) await onDone(state);
}

/** Lopputilan jälkeen pay-parametri pois, jotta sivun lataus ei käynnistä tarkistusta uudelleen. Odottava tila säilyttää sen. */
function stripPayParam() {
  try {
    const u = new URL(location.href);
    if (!u.searchParams.has('pay')) return;
    u.searchParams.delete('pay');
    history.replaceState(history.state, '', u.pathname + u.search + u.hash);
  } catch { /* osoitetta ei voi muuttaa */ }
}
