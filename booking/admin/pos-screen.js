// Pikakassa: pikapainikkeet ensin, maksurivit ja yhteensä niiden alla, muokkaus sivun lopussa.
// Maksutapa, summa ja vahvistus avautuvat erilliseen ikkunaan. Hintoja ei lähetetä palvelimelle.
import { h, toast, money, errMsg } from './ui.js';
import { icon } from './icons.js';
import { loadPosTexts, posText as tx } from './pos-texts.js';
import { cartAdd, cartSetQty, cartTotal, checkoutItems, tendersFor, tenderAvailable, joinUrl, posCandidates, filterProducts, tillEditorOpen, moveSort, validEmail } from './pos-logic.js';
import { finnishMobileMsisdn } from './phone-fi.js';
import { qrSvgElement } from './qrsvg.js';

const MOCK = () => new URLSearchParams(location.search).get('mock') === '1';

export async function renderPos({ ctx, rpc, fn }) {
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
  let email = '';
  let mail = null;
  let mailError = '';
  let order = null;
  let phase = 'cart';
  let payInfo = null;
  let pollTimer = null;
  let payOpen = false;
  let busy = false;
  let payError = '';
  let returnFocus = null;
  let modalWasOpen = false;
  let keyHandler = null;

  const root = h('div', { class: 'pos', 'data-testid': 'pos' });

  function stopPoll() { if (pollTimer) clearInterval(pollTimer); pollTimer = null; }

  function unbindKey() {
    if (!keyHandler) return;
    document.removeEventListener('keydown', keyHandler);
    keyHandler = null;
  }

  function lockScroll() {
    const body = document.body;
    const html = document.documentElement;
    if (!body || body.classList.contains('pos-modal-open')) return;
    body.dataset.posOverflow = body.style.overflow || '';
    if (html) html.dataset.posOverflow = html.style.overflow || '';
    body.style.overflow = 'hidden';
    if (html) html.style.overflow = 'hidden';
    body.classList.add('pos-modal-open');
    if (html) html.classList.add('pos-modal-open');
  }

  function releaseScroll() {
    const body = document.body;
    const html = document.documentElement;
    if (!body || !body.classList.contains('pos-modal-open')) return;
    body.style.overflow = body.dataset.posOverflow || '';
    if (html) html.style.overflow = html.dataset.posOverflow || '';
    body.classList.remove('pos-modal-open');
    if (html) html.classList.remove('pos-modal-open');
  }

  function teardown() {
    payOpen = false;
    modalWasOpen = false;
    unbindKey();
    releaseScroll();
    document.getElementById('pos-pay-overlay')?.remove();
    stopPoll();
  }

  function focusables(dlg) {
    if (!dlg?.querySelectorAll) return [];
    return [...dlg.querySelectorAll('button, input, select, textarea, [href]')].filter((el) => {
      if (el.disabled || el.getAttribute('disabled') != null) return false;
      if (el.getAttribute('hidden') != null || el.hidden) return false;
      if (el.closest && el.closest('[hidden]')) return false;
      return true;
    });
  }

  function onModalKey(e) {
    if (!root.isConnected) { teardown(); return; }
    if (e.key === 'Escape') { e.preventDefault?.(); closePay(); return; }
    if (e.key !== 'Tab') return;
    const dlg = document.getElementById('pos-pay-dialog');
    if (!dlg) return;
    const items = focusables(dlg);
    if (!items.length) { e.preventDefault?.(); return; }
    const first = items[0];
    const last = items[items.length - 1];
    const active = document.activeElement;
    const inside = dlg.contains ? dlg.contains(active) : false;
    if (e.shiftKey) {
      if (!inside || active === first || active === dlg) { e.preventDefault?.(); last.focus?.(); }
    } else if (!inside || active === last || active === dlg) {
      e.preventDefault?.();
      first.focus?.();
    }
  }

  function closePay() {
    if (!payOpen) return;
    payOpen = false;
    const back = returnFocus;
    returnFocus = null;
    modalWasOpen = false;
    draw();
    const restore = () => {
      if (!root.isConnected) return;
      const trigger = back && back.isConnected && root.contains(back) ? back : null;
      const live = trigger || root.querySelector('[data-testid="pos-pay"], [data-testid="pos-next"]');
      if (live && live !== document.body) live.focus();
    };
    restore();
    setTimeout(restore, 0);
    setTimeout(restore, 40);
  }

  function openPay() {
    if (busy) return;
    if (phase === 'paying') {
      if (!returnFocus || !returnFocus.isConnected) returnFocus = document.activeElement;
      payOpen = true;
      draw();
      return;
    }
    if (!cart.length) { toast(t('empty')); return; }
    returnFocus = document.activeElement;
    payOpen = true;
    draw();
  }

  function syncModal() {
    document.getElementById('pos-pay-overlay')?.remove();
    unbindKey();
    if (!payOpen) { releaseScroll(); modalWasOpen = false; return; }
    document.body.append(payDialog());
    lockScroll();
    keyHandler = onModalKey;
    document.addEventListener('keydown', keyHandler);
    if (!modalWasOpen) {
      modalWasOpen = true;
      document.getElementById('pos-pay-dialog')?.focus?.();
    }
  }

  async function load() {
    await loadPosTexts(rpc);
    const [cat, ten, products] = await Promise.all([
      rpc('admin_pos_catalog'),
      rpc('admin_pos_tenders'),
      canEdit ? rpc('admin_list_products').catch(() => []) : Promise.resolve([]),
    ]);
    catalog = Array.isArray(cat) ? cat : [];
    modes = ten || modes;
    try {
      const st = await rpc('admin_get_montonio_status');
      if (st && st.mode) modes = { ...modes, montonio_mode: st.mode };
    } catch { /* pos.use ilman settings.edit: maksulinkki käyttää vismapay_mode-varaa */ }
    tenders = tendersFor(ten?.tenders || [], 'pos');
    allProducts = Array.isArray(products) ? products : [];
    editing = tillEditorOpen(catalog.length, editing);
  }

  async function voidOpen() {
    if (!order || phase === 'paid') return;
    const id = order.order_id;
    order = null; phase = 'cart'; payInfo = null; mail = null; stopPoll();
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
      if (payInfo?.kind === 'link' && phase === 'paying') {
        try {
          const em = await rpc('admin_pos_email_status', { p_order_id: orderId });
          const changed = ['status', 'attempts', 'sent_at', 'last_error', 'masked_to'].some((k) => (mail?.[k] ?? null) !== (em?.[k] ?? null));
          mail = em;
          if (changed) draw();
        } catch { /* seuraava kysely */ }
      }
    };
    pollTimer = setInterval(tick, 2500);
    tick();
  }

  function showPayError(e) {
    payError = errMsg(e);
    payOpen = true;
    toast(payError, 'err');
  }

  async function pay() {
    if (busy) return;
    busy = true;
    try {
      if (!cart.length) { toast(t('empty')); return; }
      if (!tender || !tenderAvailable(tenders.find((x) => x.code === tender), modes)) { payOpen = true; toast(t('choose_method')); return; }
      const chosen = tenders.find((x) => x.code === tender);
      if (chosen.handler === 'mobilepay' && mpFlow === 'PUSH_MESSAGE' && !finnishMobileMsisdn(phone)) { toast(t('phone_invalid')); payOpen = true; return; }
      let mailTo = null;
      if (chosen.handler === 'payment_link') {
        mailTo = String(email || '').trim();
        if (!mailTo) { payError = t('email_required'); payOpen = true; toast(payError, 'err'); return; }
        if (!validEmail(mailTo)) { payError = t('email_invalid'); payOpen = true; toast(payError, 'err'); return; }
      }
      payError = '';
      draw();
      const items = checkoutItems(cart);
      const res = await rpc('admin_pos_checkout', { p_items: items, p_locale: lang, p_email: mailTo });
      order = res;
      phase = 'paying';
      try {
        if (chosen.handler === 'payment_link') {
          const link = await rpc('admin_pos_send_link', { p_order_id: res.order_id, p_email: mailTo });
          const url = joinUrl(modes.site_base_url, link.link_path);
          payInfo = { kind: 'link', url, amount: link.amount };
          mail = { status: link.outbox_status || 'pending', masked_to: link.masked_to || null, attempts: null, max_attempts: null, sent_at: null, last_error: null };
          mailError = '';
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
        payOpen = true;
      } catch (e) {
        await voidOpen();
        phase = 'cart';
        payInfo = null;
        order = null;
        stopPoll();
        showPayError(e);
      }
    } catch (e) {
      showPayError(e);
    } finally {
      busy = false;
      draw();
    }
  }

  function nextCustomer() {
    order = null; phase = 'cart'; payInfo = null; cart = [];
    email = ''; mail = null; mailError = '';
    payOpen = false; returnFocus = null; modalWasOpen = false;
    stopPoll();
    draw();
  }

  async function resend() {
    if (busy || !order || phase !== 'paying') return;
    busy = true;
    mailError = '';
    draw();
    try {
      const link = await rpc('admin_pos_send_link', { p_order_id: order.order_id, p_email: String(email || '').trim(), p_resend: true });
      mail = { ...(mail || {}), status: link.outbox_status || 'pending', masked_to: link.masked_to || mail?.masked_to || null };
    } catch (e) {
      mailError = errMsg(e);
      toast(mailError, 'err');
    } finally {
      busy = false;
      draw();
    }
  }

  function mailLabel(status) {
    if (status === 'sent') return t('mail_sent');
    if (status === 'dry_run') return t('mail_dry_run');
    if (status === 'failed' || status === 'dead') return t('mail_failed');
    if (status === 'skipped') return t('mail_off');
    return t('mail_pending');
  }

  function methodBox() {
    const box = h('div', { class: 'pos-methods', role: 'radiogroup', 'aria-label': t('method'), 'data-testid': 'pos-methods' });
    for (const m of tenders) {
      const available = tenderAvailable(m, modes);
      const on = available && phase === 'cart';
      const label = m.handler === 'payment_link' ? t('method_link') : m.handler === 'mobilepay' ? t('method_mobilepay') : m.handler === 'terminal' ? t('method_terminal') : m.code;
      box.append(h('label', { class: 'pos-method' + (available ? '' : ' is-off') },
        h('input', { type: 'radio', name: 'tender', value: m.code, disabled: !on || null, checked: tender === m.code || null, onchange: () => { tender = m.code; draw(); } }),
        h('span', { text: label }),
        !available && m.handler === 'terminal' ? h('small', { text: t('terminal_later') }) : null,
        !available && m.handler === 'mobilepay' ? h('small', { text: t('mp_off') }) : null,
        !available && m.handler === 'visma_pay' ? h('small', { text: t('visma_off') }) : null,
        !available && m.handler === 'payment_link' ? h('small', { text: t('vismapay_off'), 'data-testid': 'pos-vismapay-off' }) : null));
    }
    return box;
  }

  function flowBox() {
    if (tender !== 'mobilepay' || phase === 'paid') return null;
    const box = h('div', { class: 'pos-flows', 'data-testid': 'pos-flows' });
    box.append(h('label', {}, h('input', { type: 'radio', name: 'mpflow', checked: mpFlow === 'QR' || null, disabled: phase !== 'cart' || null, onchange: () => { mpFlow = 'QR'; draw(); } }), h('span', { text: t('method_qr') })));
    box.append(h('label', {}, h('input', { type: 'radio', name: 'mpflow', checked: mpFlow === 'PUSH_MESSAGE' || null, disabled: phase !== 'cart' || null, onchange: () => { mpFlow = 'PUSH_MESSAGE'; draw(); } }), h('span', { text: t('method_push') })));
    if (mpFlow === 'PUSH_MESSAGE' && phase === 'cart') {
      const inp = h('input', { type: 'tel', inputmode: 'tel', autocomplete: 'tel', value: phone, 'aria-label': t('phone'), 'data-testid': 'pos-phone' });
      inp.addEventListener('input', () => { phone = inp.value; });
      box.append(h('label', { class: 'fld' }, h('span', { text: t('phone') }), inp));
    }
    return box;
  }

  function emailBox() {
    if (tender !== 'payment_link' || phase !== 'cart') return null;
    const inp = h('input', { type: 'email', inputmode: 'email', autocomplete: 'email', value: email, 'aria-label': t('email'), 'data-testid': 'pos-email' });
    inp.addEventListener('input', () => { email = inp.value; });
    return h('label', { class: 'fld' }, h('span', { text: t('email') }), inp, h('small', { class: 'muted', text: t('email_help') }));
  }

  function statusBlock() {
    const box = h('div', { class: 'pos-status', 'data-testid': 'pos-status' });
    if (phase === 'paying' && payInfo?.kind === 'link') {
      box.append(h('p', { 'data-testid': 'pos-mail', text: mailLabel(mail?.status) }));
      if (mail?.masked_to) box.append(h('p', { 'data-testid': 'pos-mail-to', text: `${t('link_sent_to')} ${mail.masked_to}` }));
      if (mailError) box.append(h('p', { role: 'alert', class: 'err', 'data-testid': 'pos-mail-error', text: mailError }));
      if (['failed', 'dead', 'skipped'].includes(mail?.status)) {
        box.append(h('button', {
          type: 'button', class: 'btn', 'data-testid': 'pos-mail-resend',
          text: t('mail_resend'), disabled: busy || null, onclick: () => resend(),
        }));
      }
      if (payInfo.url) box.append(h('p', { class: 'muted', text: t('link_help') }), h('p', { class: 'pos-url', text: payInfo.url }), qrSvgElement(payInfo.url, { size: 220, label: t('method_link') }));
    }
    if (phase === 'paying' && payInfo?.kind === 'mp' && payInfo.flow === 'QR' && payInfo.qr) {
      box.append(h('p', { class: 'muted', text: t('qr_help') }), qrSvgElement(payInfo.qr, { size: 220, label: t('method_qr') }));
    }
    if (phase === 'paying' && payInfo?.pushed) box.append(h('p', { class: 'muted', text: t('push_help') }));
    if (phase === 'paying') box.append(h('p', { text: t('waiting') }));
    if (phase === 'paid') {
      box.append(h('div', { class: 'pos-paid', 'data-testid': 'pos-paid-dialog' },
        h('p', { text: t('paid') }),
        payInfo?.receipt ? h('p', { text: payInfo.receipt.receipt_no || '' }) : null,
        h('button', { type: 'button', class: 'btn primary pos-pay', 'data-testid': 'pos-next-dialog', text: t('next'), onclick: () => nextCustomer() })));
    }
    return box;
  }

  function payDialog() {
    const total = cartTotal(cart);
    const shown = money(order && phase !== 'cart' ? order.total : total);
    const dialog = h('div', {
      id: 'pos-pay-dialog',
      class: 'pos-dialog',
      role: 'dialog',
      'aria-modal': 'true',
      'aria-labelledby': 'pos-pay-title',
      tabindex: '-1',
      'data-testid': 'pos-pay-dialog',
    },
      h('div', { class: 'pos-dialog-head' },
        h('h2', { id: 'pos-pay-title', text: t('pay_title') }),
        h('button', { type: 'button', class: 'icon-btn', 'aria-label': t('close'), 'data-testid': 'pos-pay-close', onclick: () => closePay() }, icon('close', 22))),
      h('p', { class: 'pos-total-label', text: t('amount') }),
      h('p', { class: 'pos-amount', 'data-testid': 'pos-amount', text: shown }));
    if (phase !== 'paid') {
      dialog.append(h('h2', { text: t('method') }));
      dialog.append(methodBox());
      const flows = flowBox();
      if (flows) dialog.append(flows);
      const mailField = emailBox();
      if (mailField) dialog.append(mailField);
    }
    if (phase === 'cart') {
      dialog.append(h('p', { class: 'muted pos-legal', text: t('pay_legal') }));
      if (payError) dialog.append(h('p', { role: 'alert', class: 'err', 'data-testid': 'pos-pay-error', text: payError }));
      dialog.append(h('button', {
        type: 'button', class: 'btn primary pos-pay', 'data-testid': 'pos-confirm',
        text: busy ? t('wait') : t('confirm'),
        disabled: busy || null,
        onclick: () => pay().catch((e) => toast(errMsg(e), 'err')),
      }));
    } else dialog.append(statusBlock());
    const overlay = h('div', { id: 'pos-pay-overlay', class: 'pos-overlay', 'data-testid': 'pos-pay-overlay' }, dialog);
    overlay.addEventListener('click', (e) => { if (e.target === overlay) closePay(); });
    return overlay;
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

    const lines = h('div', { class: 'pos-panel', 'data-testid': 'pos-panel' });
    const lineQty = cart.reduce((n, r) => n + r.quantity, 0);
    lines.append(h('button', {
      type: 'button', class: 'pos-lines-btn', 'data-testid': 'pos-lines',
      'aria-expanded': showLines ? 'true' : 'false',
      'aria-label': `${t('lines')} ${lineQty}`,
      onclick: () => { showLines = !showLines; draw(); },
    },
      h('span', { class: 'pos-lines-label', text: t('lines') }),
      h('span', { class: 'pos-lines-count', text: String(lineQty) })));
    if (showLines) {
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
    }

    const side = h('aside', { class: 'pos-side', 'data-testid': 'pos-side' },
      h('p', { class: 'pos-total-label', text: t('total') }),
      h('p', { class: 'pos-total', 'data-testid': 'pos-total', text: money(order && phase !== 'cart' ? order.total : total) }));
    if (phase === 'paid') {
      side.append(h('div', { class: 'pos-paid', 'data-testid': 'pos-paid' },
        h('p', { text: t('paid') }),
        payInfo?.receipt ? h('p', { text: payInfo.receipt.receipt_no || '' }) : null,
        h('button', { type: 'button', class: 'btn primary pos-pay', 'data-testid': 'pos-next', text: t('next'), onclick: () => nextCustomer() })));
    } else {
      side.append(h('button', {
        type: 'button', class: 'btn primary pos-pay', 'data-testid': 'pos-pay',
        text: busy ? t('wait') : (phase === 'paying' ? t('waiting') : t('pay')),
        disabled: busy || null,
        onclick: () => openPay(),
      }));
    }

    const editBtn = canEdit ? h('button', {
      type: 'button', class: 'pos-edit-link', 'data-testid': 'pos-edit',
      'aria-expanded': editing ? 'true' : 'false', 'aria-controls': 'pos-editor',
      text: editing ? t('done') : t('edit'),
      onclick: () => { editing = !editing; draw(); },
    }) : null;
    const tools = canEdit ? h('div', { class: 'pos-tools', 'data-testid': 'pos-tools' }, editBtn, editing ? editor() : null) : null;

    const kids = [
      h('h1', { text: t('title') }),
      h('div', { class: 'pos-layout', 'data-testid': 'pos-layout' }, h('div', { class: 'pos-main' }, grid, lines), side),
    ];
    if (tools) kids.push(tools);
    root.replaceChildren(...kids);
    syncModal();
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
    const orderBox = h('div', { class: 'stack', 'data-testid': 'pos-order' });
    for (const p of catalog) {
      orderBox.append(h('div', { class: 'pos-line' },
        h('span', { class: 'grow', text: p.name }),
        h('button', { type: 'button', class: 'btn pos-step', 'aria-label': t('up'), text: '↑', onclick: () => reorder(p.product_id, -1) }),
        h('button', { type: 'button', class: 'btn pos-step', 'aria-label': t('down'), text: '↓', onclick: () => reorder(p.product_id, 1) })));
    }
    return h('section', { id: 'pos-editor', class: 'pos-editor card', 'data-testid': 'pos-editor' },
      h('h2', { text: t('edit') }),
      h('label', { class: 'fld' }, h('span', { text: t('search') }), search),
      hits,
      orderBox);
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
  // Tarkkailija vasta kun näkymä on kiinnitetty. load()in aikana root ei ole vielä sivulla,
  // ja irtoaminen silloin purkaisi kuuntelijan ennen kuin näkymä ehtii näkyviin.
  queueMicrotask(() => queueMicrotask(() => {
    if (!root.isConnected || typeof MutationObserver !== 'function') return;
    const mo = new MutationObserver(() => {
      if (!root.isConnected) { mo.disconnect(); teardown(); }
    });
    mo.observe(document.body, { childList: true, subtree: true });
  }));
  return root;
}
