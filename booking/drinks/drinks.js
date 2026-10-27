// Julkinen kylmälaite-sivu. Ei kirjautumista. Hinta tulee palvelimelta.
import { drinksText as tx, loadDrinksTexts } from './drinks-texts.js';
import { checkoutItems, cartTotal, drinksCartAdd, drinksCartSet, productLabel, deviceFromSearch, placeLabel } from './drinks-logic.js';
import { createDrinksMock } from './drinks-mock.js';

const lang = document.documentElement.lang === 'en' ? 'en' : 'fi';
const t = (k) => tx(k, lang);
const params = new URLSearchParams(location.search);
const mockMode = params.get('mock') === '1';
const deviceCode = deviceFromSearch(location.search);
const cfg = () => window.BOOKING_CONFIG || {};

function headers() {
  const key = cfg().anonKey || '';
  const bearer = key && key.split('.').length === 3 ? { Authorization: `Bearer ${key}` } : {};
  return { apikey: key, ...bearer, 'Content-Type': 'application/json', 'Accept-Profile': cfg().schema || 'booking', 'Content-Profile': cfg().schema || 'booking' };
}

async function liveRpc(name, args) {
  const r = await fetch(`${String(cfg().url || '').replace(/\/$/, '')}${cfg().rest || '/rest/v1'}/rpc/${name}`, { method: 'POST', headers: headers(), body: JSON.stringify(args) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) return { ok: false, code: j.code || j.details || 'http', message: j.message };
  return j;
}

async function liveFn(name, body) {
  const key = cfg().anonKey || '';
  const r = await fetch(`${String(cfg().url || '').replace(/\/$/, '')}${cfg().functions || '/functions/v1'}/${name}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', apikey: key }, body: JSON.stringify(body),
  });
  const j = await r.json().catch(() => ({}));
  return j && typeof j === 'object' ? j : { ok: false, code: 'bad_response' };
}

const mock = mockMode ? createDrinksMock() : null;
const rpc = (name, args) => (mock ? mock.rpc(name, args) : liveRpc(name, args));
const callFn = (name, body) => (mock ? Promise.resolve({ ok: true, dry_run: true, redirect_url: null, message: 'mock' }) : liveFn(name, body));

const app = document.getElementById('app');
let products = [];
let cart = [];
let device = null;
const PAY_METHODS = [
  ['paymentInitiation', 'Verkkopankki', 'Online bank'],
  ['cardPayments', 'Kortti', 'Card'],
  ['applePay', 'Apple Pay', 'Apple Pay'],
  ['googlePay', 'Google Pay', 'Google Pay'],
  ['mobilePay', 'MobilePay', 'MobilePay'],
];
let method = 'paymentInitiation';
let email = '';
let phase = 'shop';
let note = '';
let order = null;
let poll = null;

function el(tag, attrs, ...kids) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') n.className = v;
    else if (k === 'text') n.textContent = v;
    else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
    else if (v === true) n.setAttribute(k, '');
    else n.setAttribute(k, v);
  }
  for (const c of kids.flat()) if (c) n.append(c.nodeType ? c : document.createTextNode(c));
  return n;
}
const money = (n) => new Intl.NumberFormat(lang === 'en' ? 'en-GB' : 'fi-FI', { style: 'currency', currency: 'EUR' }).format(Number(n) || 0);

function draw() {
  document.title = products.length === 1 ? productLabel(products[0], lang) : t('title');
  const main = el('main');
  main.append(el('h1', { text: t('title') }), el('p', { class: 'lead', text: t('lead') }));
  const place = placeLabel(device?.label);
  if (place) main.append(el('p', { class: 'device', 'data-testid': 'drinks-place', text: place }));
  if (device && device.active === false) main.append(el('p', { class: 'err', text: t('qr_missing') }));
  if (device?.unknown || !deviceCode) main.append(el('p', { class: 'err', 'data-testid': 'drinks-missing', text: t('qr_missing') }));
  if (phase === 'paid') {
    main.append(el('div', { class: 'paid', 'data-testid': 'drinks-paid' }, el('h2', { text: t('paid') }), el('p', { text: money(order?.total) })));
    app.replaceChildren(main);
    return;
  }
  const list = el('div', { class: 'list', 'data-testid': 'drinks-list' });
  if (!products.length) list.append(el('p', { 'data-testid': 'drinks-empty', text: deviceCode && device && !device.unknown && device.active !== false ? t('empty') : '' }));
  for (const p of products) {
    const qty = cart.find((r) => r.product_id === p.product_id)?.quantity || 0;
    list.append(el('article', { class: 'drink' },
      el('div', {}, el('strong', { text: productLabel(p, lang) }), el('div', { text: money(p.price) })),
      el('div', { class: 'stepper' },
        el('button', { type: 'button', 'aria-label': t('remove'), text: '−', onclick: () => { cart = drinksCartSet(cart, p.product_id, qty - 1); draw(); } }),
        el('span', { text: String(qty) }),
        el('button', { type: 'button', 'aria-label': t('add'), 'data-testid': `add-${p.product_id}`, text: '+', onclick: () => { cart = drinksCartAdd(cart, p); draw(); } }))));
  }
  main.append(list);
  const emailInp = el('input', { type: 'email', autocomplete: 'email', value: email, 'aria-label': t('email'), 'data-testid': 'drinks-email' });
  emailInp.addEventListener('input', () => { email = emailInp.value; });
  const bar = el('div', { class: 'bar' },
    el('p', { class: 'total', 'data-testid': 'drinks-total', text: money(cartTotal(cart)) }),
    el('div', { class: 'methods', 'data-testid': 'drinks-methods' },
      ...PAY_METHODS.map(([code, fi, en]) => el('button', { type: 'button', 'aria-pressed': method === code ? 'true' : 'false', 'data-testid': `drinks-${code}`, text: lang === 'en' ? en : fi, onclick: () => { method = code; draw(); } }))),
    el('label', { class: 'email' }, t('email'), el('span', { class: 'note', text: t('email_hint') }), emailInp),
    note ? el('p', { class: 'note', 'data-testid': 'drinks-note', text: note }) : null,
    el('p', { class: 'legal', text: t('pay_legal') }),
    el('button', { type: 'button', class: 'pay', 'data-testid': 'drinks-pay', text: phase === 'paying' ? t('waiting') : t('pay'), onclick: () => pay() }));
  app.replaceChildren(main, bar);
}

async function pay() {
  if (!cart.length || phase === 'paying') return;
  if (!deviceCode || device?.active === false || device?.unknown) { note = t('qr_missing'); draw(); return; }
  if (email.trim() && !/^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/.test(email.trim())) { note = t('invalid_email'); draw(); return; }
  note = '';
  const res = await rpc('public_drinks_checkout', { p_device: deviceCode, p_items: checkoutItems(cart), p_email: email.trim() || null, p_locale: lang });
  if (!res?.ok) { note = res?.message || res?.code || t('empty'); draw(); return; }
  order = res;
  phase = 'paying';
  const started = mock
    ? { ok: true, redirect_url: null, dry_run: true }
    : await callFn('montonio-start', { order_token: res.public_token, method });
  if (mock) mock.arm(res.public_token);
  const back = safeOnline(started?.redirect_url);
  if (back) { location.href = back; return; }
  if (started?.code === 'online_off' || started?.code === 'not_configured') note = t('visma_off');
  else if (started?.dry_run || mock) note = t('visma_dry');
  else if (started?.ok === false) note = t('visma_off');
  draw();
  watch(res.public_token);
}

function safeOnline(url) {
  try {
    const u = new URL(String(url || ''));
    const hosts = ['sandbox-stargate.montonio.com', 'stargate.montonio.com', 'gateway.montonio.com', 'pay.montonio.com'];
    if (u.protocol !== 'https:' || !hosts.includes(u.hostname)) return null;
    return u.href;
  } catch { return null; }
}

function watch(token) {
  if (poll) clearInterval(poll);
  const tick = async () => {
    if (!mock) await callFn('montonio-notify', { action: 'reconcile', order_token: token }).catch(() => {});
    const st = await rpc('public_drinks_status', { p_token: token });
    if (st?.payment_status === 'paid') {
      clearInterval(poll); phase = 'paid'; order = { ...order, ...st }; cart = []; draw();
    }
  };
  poll = setInterval(tick, 2500);
  tick();
}

await loadDrinksTexts(rpc);
const cat = await rpc('public_drinks_catalog', { p_device: deviceCode || null });
products = cat?.products || [];
device = cat?.device || null;
draw();
