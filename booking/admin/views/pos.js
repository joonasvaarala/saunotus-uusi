// Pikakassa: tuotepainikkeet, ostoskori, maksulinkki tai MobilePay (QR / pyyntö puhelimeen).
// Hintoja ei lähetetä palvelimelle. Korttipääte näkyy rekisterissä, mutta sitä ei voi valita.
import { rpc, fn } from '../sb.js';
import { h, toast, money, errMsg } from '../ui.js';
import { posText as tx } from '../pos-texts.js';
import { cartAdd, cartSetQty, cartTotal, checkoutItems, tendersFor, tenderAvailable, joinUrl } from '../pos-logic.js';
import { finnishMobileMsisdn } from '../phone-fi.js';
import { qrSvgElement } from '../qrsvg.js';

const MOCK = () => new URLSearchParams(location.search).get('mock') === '1';

export async function render({ ctx }) {
  const lang = 'fi';
  const t = (k) => tx(k, lang);
  const canEdit = ctx.can('catalog.edit');
  let catalog = [];
  let tenders = [];
  let modes = { mobilepay_mode: 'off', vismapay_mode: 'off', site_base_url: '' };
  let devices = [];
  let cart = [];
  let showLines = false;
  let tender = null;
  let mpFlow = 'QR';
  let phone = '';
  let order = null;
  let phase = 'cart';
  let payInfo = null;
  let pollTimer = null;

  const root = h('div', { class: 'pos', 'data-testid': 'pos' });

  function stopPoll() { if (pollTimer) clearInterval(pollTimer); pollTimer = null; }

  async function load() {
    const [cat, ten, dev] = await Promise.all([
      rpc('admin_pos_catalog'),
      rpc('admin_pos_tenders'),
      rpc('admin_list_cold_units').catch(() => []),
    ]);
    catalog = Array.isArray(cat) ? cat : [];
    modes = ten || modes;
    tenders = tendersFor(ten?.tenders || [], 'pos');
    devices = Array.isArray(dev) ? dev : [];
  }

  async function voidOpen() {
    if (!order || phase === 'paid') return;
    const id = order.order_id;
    order = null; phase = 'cart'; payInfo = null; stopPoll();
    try { await rpc('admin_pos_void', { p_order_id: id }); } catch (e) { toast(errMsg(e)); }
  }

  function watch(orderId, token) {
    stopPoll();
    const tick = async () => {
      try {
        if (!MOCK() && token) await fn('mobilepay-notify', { action: 'reconcile', order_token: token }).catch(() => {});
        const st = await rpc('admin_pos_status', { p_order_id: orderId });
        if (st?.payment_status === 'paid') {
          stopPoll();
          phase = 'paid';
          payInfo = { ...(payInfo || {}), receipt: st.receipts?.[0] || null, order_no: st.order_no };
          cart = [];
          draw();
        }
      } catch { /* seuraava kysely */ }
    };
    pollTimer = setInterval(tick, 2500);
    tick();
  }

  async function pay() {
    if (!cart.length) { toast(t('empty')); return; }
    if (!tender || !tenderAvailable(tenders.find((x) => x.code === tender), modes)) { showLines = true; draw(); toast(t('pick_method')); return; }
    const chosen = tenders.find((x) => x.code === tender);
    if (chosen.handler === 'mobilepay' && mpFlow === 'PUSH_MESSAGE' && !finnishMobileMsisdn(phone)) { toast(t('phone_invalid')); showLines = true; draw(); return; }
    const items = checkoutItems(cart);
    const res = await rpc('admin_pos_checkout', { p_items: items, p_locale: lang, p_email: null });
    order = res;
    phase = 'paying';
    if (chosen.handler === 'payment_link') {
      const link = await rpc('admin_create_payment_link', { p_order_id: res.order_id, p_send_email: false, p_expires_days: 1, p_note: 'pikakassa' });
      const url = joinUrl(modes.site_base_url, link.link_path);
      payInfo = { kind: 'link', url, amount: link.amount, online: link.online_payment_enabled };
      if (MOCK()) await rpc('admin_pos_mock_tender', { p_order_id: res.order_id });
      watch(res.order_id, res.public_token);
    } else if (chosen.handler === 'mobilepay') {
      if (MOCK()) {
        await rpc('admin_pos_mock_tender', { p_order_id: res.order_id });
        payInfo = { kind: 'mp', flow: mpFlow, qr: mpFlow === 'QR' ? 'https://pay.example.test/mock-qr' : null, pushed: mpFlow === 'PUSH_MESSAGE' };
      } else {
        const started = await fn('mobilepay-start', { order_token: res.public_token, user_flow: mpFlow, phone: mpFlow === 'PUSH_MESSAGE' ? finnishMobileMsisdn(phone) : undefined });
        payInfo = { kind: 'mp', flow: mpFlow, qr: started.qr_url || started.redirect_url || null, pushed: !!started.pushed };
      }
      watch(res.order_id, res.public_token);
    }
    draw();
  }

  function draw() {
    const total = cartTotal(cart);
    const grid = h('div', { class: 'pos-grid', 'data-testid': 'pos-grid' });
    if (!catalog.length) grid.append(h('p', { class: 'muted', text: t('no_products') }));
    for (const p of catalog) {
      grid.append(h('button', { type: 'button', class: 'pos-btn', 'data-testid': `pos-product-${p.product_id}`, onclick: () => { if (phase === 'paying') voidOpen().then(() => { cart = cartAdd(cart, p); draw(); }); else { cart = cartAdd(cart, p); draw(); } } },
        h('span', { class: 'pos-name', text: p.name }),
        p.age_restricted ? h('small', { class: 'pos-age', text: t('age') }) : null,
        h('strong', { class: 'pos-price', text: money(p.price) })));
    }
    grid.append(h('button', { type: 'button', class: 'pos-btn pos-lines-btn', 'data-testid': 'pos-lines', 'aria-expanded': showLines ? 'true' : 'false', onclick: () => { showLines = !showLines; draw(); } },
      h('span', { class: 'pos-name', text: t('lines') }),
      h('strong', { class: 'pos-price', text: String(cart.reduce((n, r) => n + r.quantity, 0)) })));

    const lines = h('div', { class: 'pos-panel', hidden: !showLines || null, 'data-testid': 'pos-panel' });
    if (!cart.length) lines.append(h('p', { class: 'muted', text: t('empty') }));
    for (const r of cart) {
      lines.append(h('div', { class: 'pos-line' },
        h('span', { class: 'grow', text: r.name }),
        h('button', { type: 'button', class: 'btn pos-step', 'aria-label': t('qty'), text: '−', onclick: () => { cart = cartSetQty(cart, r.product_id, r.quantity - 1); if (phase === 'paying') voidOpen(); draw(); } }),
        h('span', { class: 'pos-qty', text: String(r.quantity) }),
        h('button', { type: 'button', class: 'btn pos-step', 'aria-label': t('qty'), text: '+', onclick: () => { cart = cartSetQty(cart, r.product_id, r.quantity + 1); if (phase === 'paying') voidOpen(); draw(); } }),
        h('strong', { text: money(r.unit_price * r.quantity) }),
        h('button', { type: 'button', class: 'btn ghost', text: t('remove'), onclick: () => { cart = cartSetQty(cart, r.product_id, 0); if (phase === 'paying') voidOpen(); draw(); } })));
    }
    lines.append(h('h2', { text: t('method') }));
    const methodBox = h('div', { class: 'pos-methods', role: 'radiogroup', 'aria-label': t('method') });
    for (const m of tenders) {
      const on = tenderAvailable(m, modes);
      const label = m.handler === 'payment_link' ? t('method_link') : m.handler === 'mobilepay' ? t('method_mobilepay') : m.handler === 'terminal' ? t('method_terminal') : m.code;
      methodBox.append(h('label', { class: 'pos-method' + (on ? '' : ' is-off') },
        h('input', { type: 'radio', name: 'tender', value: m.code, disabled: !on || null, checked: tender === m.code || null, onchange: () => { tender = m.code; draw(); } }),
        h('span', { text: label }),
        !on && m.handler === 'terminal' ? h('small', { text: t('terminal_later') }) : null,
        !on && m.handler === 'mobilepay' ? h('small', { text: t('mp_off') }) : null));
    }
    lines.append(methodBox);
    if (tender === 'mobilepay') {
      lines.append(h('div', { class: 'pos-flows' },
        h('label', {}, h('input', { type: 'radio', name: 'mpflow', checked: mpFlow === 'QR' || null, onchange: () => { mpFlow = 'QR'; draw(); } }), ' ' + t('method_qr')),
        h('label', {}, h('input', { type: 'radio', name: 'mpflow', checked: mpFlow === 'PUSH_MESSAGE' || null, onchange: () => { mpFlow = 'PUSH_MESSAGE'; draw(); } }), ' ' + t('method_push'))));
      if (mpFlow === 'PUSH_MESSAGE') {
        const inp = h('input', { type: 'tel', inputmode: 'tel', autocomplete: 'tel', value: phone, 'aria-label': t('phone'), 'data-testid': 'pos-phone' });
        inp.addEventListener('input', () => { phone = inp.value; });
        lines.append(h('label', { class: 'fld' }, h('span', { text: t('phone') }), inp));
      }
    }
    lines.append(h('p', { class: 'muted pos-legal', text: t('pay_legal') }));

    const side = h('aside', { class: 'pos-side' },
      h('p', { class: 'pos-total-label', text: t('total') }),
      h('p', { class: 'pos-total', 'data-testid': 'pos-total', text: money(order && phase !== 'cart' ? order.total : total) }),
      phase === 'paid'
        ? h('div', { class: 'pos-paid', 'data-testid': 'pos-paid' }, h('p', { text: t('paid') }), payInfo?.receipt ? h('p', { text: payInfo.receipt.receipt_no || '' }) : null, h('button', { type: 'button', class: 'btn primary pos-pay', text: t('next'), onclick: () => { order = null; phase = 'cart'; payInfo = null; cart = []; draw(); } }))
        : h('button', { type: 'button', class: 'btn primary pos-pay', 'data-testid': 'pos-pay', disabled: phase === 'paying' || null, text: phase === 'paying' ? t('waiting') : t('pay'), onclick: () => pay().catch((e) => toast(errMsg(e))) }));

    if (phase === 'paying' && payInfo?.kind === 'link' && payInfo.url) {
      side.append(h('p', { class: 'muted', text: t('link_help') }), h('p', { class: 'pos-url', text: payInfo.url }), qrSvgElement(payInfo.url, { size: 220, label: t('method_link') }));
    }
    if (phase === 'paying' && payInfo?.kind === 'mp' && payInfo.flow === 'QR' && payInfo.qr) {
      side.append(h('p', { class: 'muted', text: t('qr_help') }), qrSvgElement(payInfo.qr, { size: 220, label: t('method_qr') }));
    }
    if (phase === 'paying' && payInfo?.pushed) side.append(h('p', { class: 'muted', text: t('push_help') }));

    const devBox = canEdit ? deviceBox() : null;
    root.replaceChildren(
      h('h1', { text: t('title') }),
      h('div', { class: 'pos-layout' }, h('div', {}, grid, lines), side),
      devBox);
  }

  function deviceBox() {
    const name = h('input', { name: 'name', maxlength: 80, 'aria-label': t('device_name') });
    const loc = h('input', { name: 'location', maxlength: 120, 'aria-label': t('device_location') });
    const list = h('div', { class: 'stack' });
    for (const d of devices) {
      list.append(h('div', { class: 'pos-line' },
        h('span', { class: 'grow' }, h('strong', { text: d.name }), h('small', { text: d.location ? ` · ${d.location}` : '' })),
        h('button', { type: 'button', class: 'btn', text: t('device_print'), onclick: () => printDevice(d) })));
    }
    const form = h('form', { class: 'row wrap' }, name, loc, h('button', { class: 'btn', type: 'submit', text: t('device_add') }));
    form.addEventListener('submit', (ev) => {
      ev.preventDefault();
      rpc('admin_upsert_cold_unit', { p_id: null, p_name: name.value, p_location: loc.value, p_active: true })
        .then(async () => { devices = await rpc('admin_list_cold_units'); name.value = ''; loc.value = ''; draw(); })
        .catch((e) => toast(errMsg(e)));
    });
    return h('section', { class: 'pos-devices card' }, h('h2', { text: t('devices') }), form, list);
  }

  function printDevice(d) {
    const url = d.print_url || d.path;
    const w = window.open('', '_blank', 'noopener');
    if (!w) return;
    const doc = w.document;
    doc.title = d.name;
    const style = doc.createElement('style');
    style.textContent = 'body{font-family:system-ui,sans-serif;text-align:center;margin:24px} h1{font-size:28px} p{font-size:18px}';
    doc.head.append(style);
    const h1 = doc.createElement('h1');
    h1.textContent = d.name;
    const p = doc.createElement('p');
    p.textContent = t('print_help');
    const where = doc.createElement('p');
    where.textContent = d.location || '';
    doc.body.append(h1, where, p, doc.importNode(qrSvgElement(url, { size: 420, label: d.name }), true));
    w.focus();
    w.print();
  }

  await load();
  draw();
  return root;
}
