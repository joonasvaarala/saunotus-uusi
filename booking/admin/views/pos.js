// Pikakassa: tuotepainikkeet, ostoskori, maksulinkki tai MobilePay (QR / pyyntö puhelimeen).
// Tuotteet valitaan tässä näkymässä (myös verkkokaupan ulkopuoliset). Hintoja ei lähetetä palvelimelle.
// Korttipääte näkyy rekisterissä, mutta sitä ei voi valita. QR-tulostus on Asetuksissa.
import { rpc, fn } from '../sb.js';
import { h, toast, money, errMsg } from '../ui.js';
import { loadPosTexts, posText as tx } from '../pos-texts.js';
import { cartAdd, cartSetQty, cartTotal, checkoutItems, tendersFor, tenderAvailable, joinUrl, posCandidates, filterProducts, tillEditorOpen, moveSort } from '../pos-logic.js';
import { finnishMobileMsisdn } from '../phone-fi.js';
import { qrSvgElement } from '../qrsvg.js';

const MOCK = () => new URLSearchParams(location.search).get('mock') === '1';

export async function render({ ctx }) {
  const lang = 'fi';
  const t = (k) => tx(k, lang);
  const canEdit = ctx.can('pos.use') || ctx.can('catalog.edit') || ctx.can('settings.edit');
  let catalog = [];
  let allProducts = [];
  let tenders = [];
  let modes = { mobilepay_mode: 'off', vismapay_mode: 'off', site_base_url: '' };
  let editing = false;
  let find = '';
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
    await loadPosTexts(rpc);
    const [cat, ten, products] = await Promise.all([
      rpc('admin_pos_catalog'),
      rpc('admin_pos_tenders'),
      canEdit ? rpc('admin_list_products').catch(() => []) : Promise.resolve([]),
    ]);
    catalog = Array.isArray(cat) ? cat : [];
    modes = ten || modes;
    tenders = tendersFor(ten?.tenders || [], 'pos');
    allProducts = Array.isArray(products) ? products : [];
    editing = tillEditorOpen(catalog.length, editing);
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
    if (!catalog.length) {
      grid.append(h('div', { class: 'pos-empty', 'data-testid': 'pos-empty' },
        h('p', { text: t('no_products') }),
        h('p', { class: 'muted', text: t('empty_help') }),
        canEdit ? h('button', { type: 'button', class: 'btn primary lg pos-edit', 'data-testid': 'pos-add', text: t('add'), onclick: () => { editing = true; draw(); } }) : null));
    }
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

    const editBtn = canEdit ? h('button', { type: 'button', class: 'btn lg pos-edit', 'data-testid': 'pos-edit', 'aria-expanded': editing ? 'true' : 'false', text: editing ? t('done') : t('edit'), onclick: () => { editing = !editing; draw(); } }) : null;
    root.replaceChildren(
      h('h1', { text: t('title') }),
      editBtn,
      editing && canEdit ? editor() : null,
      h('div', { class: 'pos-layout' }, h('div', {}, grid, lines), side));
  }

  function editor() {
    const onTill = new Set(catalog.map((p) => p.product_id));
    const search = h('input', { type: 'search', value: find, 'aria-label': t('search'), 'data-testid': 'pos-search' });
    const hits = h('div', { class: 'stack', 'data-testid': 'pos-picker' });
    const paintHits = () => {
      const candidates = filterProducts(posCandidates(allProducts), find);
      hits.replaceChildren(...candidates.map((p) => {
        const inTill = onTill.has(p.id);
        return h('div', { class: 'pos-line' },
          h('span', { class: 'grow' }, h('strong', { text: p.name }), h('small', { text: ` ${money(p.price)}` }), p.config?.shop_visible === false ? h('small', { text: ` · ${t('not_shop')}` }) : null),
          inTill
            ? h('button', { type: 'button', class: 'btn danger', 'data-testid': `pos-remove-${p.id}`, text: t('remove'), onclick: () => setPos(p.id, false, p.config?.pos_sort ?? 100, 'removed_pos') })
            : h('button', { type: 'button', class: 'btn primary', 'data-testid': `pos-add-${p.id}`, text: t('add'), onclick: () => setPos(p.id, true, (catalog.length + 1) * 10, 'added') }));
      }));
    };
    search.addEventListener('input', () => { find = search.value; paintHits(); });
    paintHits();
    const order = h('div', { class: 'stack' });
    for (const p of catalog) {
      order.append(h('div', { class: 'pos-line' },
        h('span', { class: 'grow', text: p.name }),
        h('button', { type: 'button', class: 'btn pos-step', 'aria-label': t('up'), text: '↑', onclick: () => reorder(p.product_id, -1) }),
        h('button', { type: 'button', class: 'btn pos-step', 'aria-label': t('down'), text: '↓', onclick: () => reorder(p.product_id, 1) })));
    }
    return h('section', { class: 'pos-editor card', 'data-testid': 'pos-editor' },
      h('h2', { text: t('edit') }),
      h('label', { class: 'fld' }, h('span', { text: t('search') }), search),
      hits,
      order);
  }

  function setPos(productId, enabled, sort, toastKey) {
    rpc('admin_set_pos_product', { p_product_id: productId, p_enabled: enabled, p_sort: sort })
      .then(async () => { toast(t(toastKey)); await load(); draw(); })
      .catch((e) => toast(errMsg(e)));
  }

  function reorder(productId, dir) {
    const next = moveSort(catalog, productId, dir);
    Promise.all(next.map((r) => rpc('admin_set_pos_product', { p_product_id: r.product_id, p_enabled: true, p_sort: r.pos_sort })))
      .then(async () => { await load(); draw(); })
      .catch((e) => toast(errMsg(e)));
  }

  await load();
  draw();
  return root;
}
