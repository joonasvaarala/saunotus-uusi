// Pikakassa: pikapainikkeet ensin, maksurivit ja yhteensä niiden alla, muokkaus sivun lopussa.
// Maksutapa, summa ja vahvistus avautuvat erilliseen ikkunaan. Hintoja ei lähetetä palvelimelle.
import { h, toast, money, errMsg } from './ui.js';
import { icon } from './icons.js';
import { loadPosTexts, posText as tx } from './pos-texts.js';
import { getLang } from './talous-i18n.js';
import { searchSaleProducts, saleOptions, moveHi, enterTarget, isBookableProduct, cartAddUnbooked } from './pos-logic.js';
import { stepper } from './stepper.js';
import { cartAdd, cartAddCustom, cartLineKey, cartSetQty, cartTotal, cartVatBreakdown, checkoutItems, parseEuroInput, validateCustomLine, posSheetTenders, tenderAvailable, joinUrl, posCandidates, filterProducts, tillEditorOpen, moveSort, validEmail, posCustomerHits } from './pos-logic.js';
import { searchCustomers } from './customer-hits.js';
import { qrSvgElement } from './qrsvg.js';
import { cxEnabled, readTerminal, saveTerminal, pickTerminal, savePending, readPending, clearPending, openAppLink, cxStateOf, cxErrorKey, CX_REGISTER_TTL_MS } from './checkoutx-pos.js';

const MOCK = () => new URLSearchParams(location.search).get('mock') === '1';

export async function renderPos({ ctx, rpc, fn }) {
  const store = (() => { try { return globalThis.localStorage || null; } catch { return null; } })();
  // HALL-KASSA-01: kieli yhteisestä valinnasta (FI/EN-kytkin), luetaan joka haulla.
  const t = (k) => tx(k, getLang());
  // HALL-KASSA-01: ≥ 800 px kori on aina näkyvissä sivupaneelina.
  const wideMq = (() => { try { return typeof globalThis.matchMedia === 'function' ? globalThis.matchMedia('(min-width:800px)') : null; } catch { return null; } })();
  const isWide = () => !!wideMq?.matches;
  const canEdit = ctx.can('pos.use') || ctx.can('catalog.edit') || ctx.can('settings.edit');
  let catalog = [];
  let allProducts = [];
  let channelData = null;
  // t1808u: myynnin hakukenttä (tila säilyy uudelleenpiirrossa). t1809u: varattavan tuotteen varauspaneeli.
  const sale = { q: '', hi: -1, opts: [], focus: false };
  let bk = null;
  let tenders = [];
  let modes = { mobilepay_mode: 'off', vismapay_mode: 'off', site_base_url: '' };
  let editing = false;
  let find = '';
  let cart = [];
  let showLines = false;
  let customOpen = false;
  let customForm = { description: '', quantity: '1', price: '', vat_rate: '' };
  let customError = '';
  let vatRates = [];
  let tender = null;
  let email = '';
  const suggest = { items: [], hi: -1, gen: 0, req: 0, timer: null };
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
  // booking_286: kortti puhelimella (CheckoutX). Näkyy vain, kun palvelin kertoo tilan test.
  const cx = { terminals: [], terminal: null, state: null, failure: null, reg: null, regTimer: null, regLabel: '', configureLink: null, simulated: false };
  let visHandler = null;

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

  function stopSuggest() {
    suggest.gen += 1;
    suggest.req += 1;
    suggest.items = [];
    suggest.hi = -1;
    clearTimeout(suggest.timer);
    suggest.timer = null;
  }

  function customerListOpen() {
    const list = document.getElementById('pos-customer-list');
    return !!(list && !list.hidden && list.getAttribute('hidden') == null && list.querySelector('[role="option"]'));
  }

  function closeCustomerList() {
    const open = customerListOpen();
    suggest.items = [];
    suggest.hi = -1;
    const list = document.getElementById('pos-customer-list');
    if (list) {
      list.hidden = true;
      list.setAttribute('hidden', '');
      list.replaceChildren();
    }
    const inp = document.getElementById('pos-customer-input');
    if (inp) {
      inp.setAttribute('aria-expanded', 'false');
      inp.removeAttribute('aria-activedescendant');
    }
    return open;
  }

  function teardown() {
    payOpen = false;
    modalWasOpen = false;
    stopSuggest();
    unbindKey();
    releaseScroll();
    document.getElementById('pos-pay-overlay')?.remove();
    stopPoll();
    stopRegister();
    if (visHandler) { document.removeEventListener?.('visibilitychange', visHandler); visHandler = null; }
  }

  function stopRegister() { if (cx.regTimer) clearInterval(cx.regTimer); cx.regTimer = null; }

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
    if (e.key === 'Escape') {
      if (closeCustomerList()) { e.preventDefault?.(); return; }
      e.preventDefault?.(); closePay(); return;
    }
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
    const [cat, ten, products, vatRes, chans] = await Promise.all([
      rpc('admin_pos_catalog'),
      rpc('admin_pos_tenders'),
      rpc('admin_list_products').catch(() => []),
      rpc('admin_list_vat_rates').catch(() => null),
      rpc('admin_list_sales_channels').catch(() => null),
    ]);
    catalog = Array.isArray(cat) ? cat : [];
    modes = ten || modes;
    const rates = Array.isArray(vatRes?.rates) ? vatRes.rates.filter((r) => r && r.active) : [];
    vatRates = rates.map((r) => Number(r.rate)).filter((n) => Number.isFinite(n));
    if (!customForm.vat_rate && vatRates.length) {
      customForm = { ...customForm, vat_rate: String(vatRates.includes(25.5) ? 25.5 : vatRates[vatRates.length - 1]) };
    }
    try {
      const st = await rpc('admin_get_montonio_status');
      if (st && st.mode) modes = { ...modes, montonio_mode: st.mode };
    } catch { /* pos.use ilman settings.edit: maksulinkki käyttää vismapay_mode-varaa */ }
    tenders = posSheetTenders(ten?.tenders || []);
    if (cxEnabled(modes)) {
      try {
        const st = await rpc('admin_get_checkoutx_status');
        cx.terminals = Array.isArray(st?.terminals) ? st.terminals : [];
        cx.simulated = st?.simulated === true;
      } catch { cx.terminals = []; }
      cx.terminal = pickTerminal(readTerminal(store), cx.terminals);
    }
    allProducts = Array.isArray(products) ? products : [];
    channelData = chans && chans.ok !== false && chans.products ? chans : null;
    editing = tillEditorOpen(catalog.length, editing);
  }

  async function voidOpen() {
    if (!order || phase === 'paid') return;
    const id = order.order_id;
    if (payInfo?.kind === 'checkoutx' && payInfo.payment_id && cx.state !== 'failed' && cx.state !== 'cancelled') {
      // Surfboardin tilaus perutaan ensin. Jos asiakas ehti maksaa, kassatilausta ei peruta.
      try {
        const r = await fn('checkoutx-pos', { action: 'cancel', payment_id: payInfo.payment_id });
        if (cxStateOf(r) === 'paid') { toast(t('cx_already_paid')); watch(id); return; }
      } catch (e) { toast(errMsg(e), 'err'); }
    }
    cx.state = null; cx.failure = null;
    clearPending(store);
    order = null; phase = 'cart'; payInfo = null; mail = null; stopPoll();
    try { await rpc('admin_pos_void', { p_order_id: id }); } catch (e) { toast(errMsg(e)); }
  }

  function watch(orderId) {
    stopPoll();
    const tick = async () => {
      if (payInfo?.kind === 'checkoutx' && phase === 'paying' && payInfo.payment_id && !cx.state) {
        try {
          const r = await fn('checkoutx-pos', { action: 'status', payment_id: payInfo.payment_id });
          const s = cxStateOf(r);
          if (s === 'failed' || s === 'cancelled') {
            cx.state = s; cx.failure = r?.failure_reason || null;
            stopPoll(); payOpen = true; draw();
            return;
          }
        } catch { /* seuraava kysely */ }
      }
      try {
        const st = await rpc('admin_pos_status', { p_order_id: orderId });
        if (st?.payment_status === 'paid') {
          stopPoll();
          clearPending(store);
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
    if (payInfo?.kind === 'checkoutx' && !visHandler && document.addEventListener) {
      // CheckoutX tuo selaimen takaisin samaan välilehteen: näkyviin tulo = tarkista heti (Surfboardin ohje).
      visHandler = () => { if (!document.hidden && pollTimer && root.isConnected) tick(); };
      document.addEventListener('visibilitychange', visHandler);
    }
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
      if (!chosen || (chosen.handler !== 'payment_link' && chosen.handler !== 'checkoutx')) { payOpen = true; toast(t('choose_method')); return; }
      if (chosen.handler === 'checkoutx' && !cx.terminal) { payError = t('cx_no_terminal'); payOpen = true; toast(payError, 'err'); return; }
      let mailTo = null;
      if (chosen.handler === 'payment_link') {
        mailTo = String(email || '').trim();
        if (!mailTo) { payError = t('email_required'); payOpen = true; toast(payError, 'err'); return; }
        if (!validEmail(mailTo)) { payError = t('email_invalid'); payOpen = true; toast(payError, 'err'); return; }
      }
      payError = '';
      draw();
      const items = checkoutItems(cart);
      // Asiakkaalle lähtevä viesti pysyy suomenkielisenä riippumatta hallinnan kielestä (maksuvirta ennallaan).
      const res = await rpc('admin_pos_checkout', { p_items: items, p_locale: 'fi', p_email: mailTo });
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
          watch(res.order_id);
        } else if (chosen.handler === 'checkoutx') {
          await startCheckoutx(res.order_id);
        }
        payOpen = true;
      } catch (e) {
        if (chosen.handler === 'checkoutx') { cx.configureLink = e?.details?.configure_link || null; if (e?.code) e.message = t(cxErrorKey(e.code)); payInfo = null; }
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

  async function startCheckoutx(orderId) {
    cx.state = null; cx.failure = null;
    const r = await fn('checkoutx-pos', { action: 'start', order_id: orderId, terminal_id: cx.terminal.terminal_id, return: 'chrome' });
    payInfo = { kind: 'checkoutx', payment_id: r.payment_id, deep_link: r.deep_link, configure_link: r.configure_link || null, amount: r.amount, simulated: r.simulated === true };
    cx.configureLink = r.configure_link || null;
    savePending(store, { order_id: orderId, payment_id: r.payment_id });
    openAppLink(r.deep_link);
    watch(orderId);
  }

  async function retryCheckoutx() {
    if (busy || !order || phase !== 'paying') return;
    busy = true; payError = ''; draw();
    try { await startCheckoutx(order.order_id); }
    catch (e) { payError = e?.code ? t(cxErrorKey(e.code)) : errMsg(e); cx.configureLink = e?.details?.configure_link || cx.configureLink; toast(payError, 'err'); }
    finally { busy = false; draw(); }
  }

  async function registerPhone() {
    if (busy) return;
    busy = true; payError = ''; draw();
    try {
      const r = await fn('checkoutx-pos', { action: 'register_start', return: 'chrome' });
      cx.reg = { code: r.registration_code, until: Date.now() + CX_REGISTER_TTL_MS };
      openAppLink(r.deep_link);
      stopRegister();
      const check = async () => {
        if (!cx.reg || !root.isConnected) { stopRegister(); return; }
        if (Date.now() > cx.reg.until) { stopRegister(); cx.reg = null; payError = t('cx_register_expired'); draw(); return; }
        try {
          const c = await fn('checkoutx-pos', { action: 'register_check', registration_code: cx.reg.code, label: cx.regLabel || t('cx_phone') });
          if (c?.registered) {
            stopRegister(); cx.reg = null;
            cx.terminal = saveTerminal(store, { terminal_id: c.terminal_id, label: c.label || cx.regLabel });
            try { const st = await rpc('admin_get_checkoutx_status'); cx.terminals = Array.isArray(st?.terminals) ? st.terminals : cx.terminals; } catch { /* lista päivittyy seuraavalla latauksella */ }
            toast(t('cx_register_done'));
            draw();
          }
        } catch { /* seuraava kysely */ }
      };
      cx.regTimer = setInterval(check, 3000);
    } catch (e) {
      payError = e?.code ? t(cxErrorKey(e.code)) : errMsg(e);
      toast(payError, 'err');
    } finally { busy = false; draw(); }
  }

  function checkoutxBox() {
    if (tender !== 'checkoutx' || phase !== 'cart') return null;
    const box = h('div', { class: 'fld pos-cx', 'data-testid': 'pos-cx' });
    box.append(h('p', { class: 'muted', 'data-testid': 'pos-cx-test-note', text: t(cx.simulated ? 'cx_simulated' : 'cx_test_note') }));
    if (cx.terminals.length) {
      const sel = h('select', {
        'data-testid': 'pos-cx-terminal', 'aria-label': t('cx_pick'),
        onchange: (e) => {
          const row = cx.terminals.find((x) => x.terminal_id === e.target.value);
          cx.terminal = row ? saveTerminal(store, row) : null;
          draw();
        },
      }, h('option', { value: '', text: t('cx_pick') }),
      ...cx.terminals.map((x) => h('option', { value: x.terminal_id, text: x.label || x.terminal_id, selected: cx.terminal?.terminal_id === x.terminal_id || null })));
      box.append(h('label', { class: 'fld' }, h('span', { text: t('cx_phone') }), sel));
    }
    if (!cx.terminal) box.append(h('p', { 'data-testid': 'pos-cx-no-terminal', text: t('cx_no_terminal') }));
    if (ctx.can('settings.edit')) {
      if (cx.reg) box.append(h('p', { role: 'status', 'data-testid': 'pos-cx-register-wait', text: t('cx_register_wait') }));
      const label = h('input', { type: 'text', maxlength: '60', value: cx.regLabel, 'data-testid': 'pos-cx-label' });
      label.addEventListener('input', () => { cx.regLabel = String(label.value || ''); });
      box.append(h('label', { class: 'fld' }, h('span', { text: t('cx_register_label') }), label),
        h('button', { type: 'button', class: 'btn', 'data-testid': 'pos-cx-register', text: t('cx_register'), disabled: busy || null, onclick: () => registerPhone() }));
    } else if (!cx.terminal) {
      box.append(h('p', { class: 'muted', text: t('cx_register_admin') }));
    }
    if (cx.configureLink) {
      box.append(h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'pos-cx-configure', text: t('cx_configure'), onclick: () => openAppLink(cx.configureLink) }));
    }
    return box;
  }

  // Selain saattoi pudottaa välilehden CheckoutX:n ollessa edessä: kesken jäänyt maksu jatkuu (Surfboardin ohje).
  async function restoreCheckoutx() {
    if (!cxEnabled(modes)) return;
    const p = readPending(store);
    if (!p) return;
    try {
      const st = await rpc('admin_pos_status', { p_order_id: p.order_id });
      if (st?.status !== 'pending' || !['unpaid', 'pending'].includes(st?.payment_status)) { clearPending(store); return; }
      order = { order_id: st.order_id, order_no: st.order_no, total: st.total };
      phase = 'paying';
      payInfo = { kind: 'checkoutx', payment_id: p.payment_id, deep_link: null };
      payOpen = true;
      watch(st.order_id);
    } catch { clearPending(store); }
  }

  function nextCustomer() {
    cx.state = null; cx.failure = null; clearPending(store);
    order = null; phase = 'cart'; payInfo = null; cart = [];
    email = ''; mail = null; mailError = '';
    stopSuggest();
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
      const label = m.handler === 'payment_link' ? t('method_link') : m.handler === 'terminal' ? t('method_terminal') : m.handler === 'checkoutx' ? t('method_checkoutx') : m.code;
      box.append(h('label', { class: 'pos-method' + (available ? '' : ' is-off') },
        h('input', { type: 'radio', name: 'tender', value: m.code, disabled: !on || null, checked: tender === m.code || null, onchange: () => { tender = m.code; draw(); } }),
        h('span', { text: label }),
        !available && m.handler === 'terminal' ? h('small', { text: t('terminal_later') }) : null,
        !available && m.handler === 'payment_link' ? h('small', { text: t('vismapay_off'), 'data-testid': 'pos-vismapay-off' }) : null));
    }
    return box;
  }

  function emailBox() {
    if (tender !== 'payment_link' || phase !== 'cart') return null;
    const gen = ++suggest.gen;
    clearTimeout(suggest.timer);
    suggest.timer = null;
    suggest.items = [];
    suggest.hi = -1;
    const list = h('ul', {
      id: 'pos-customer-list', class: 'pos-suggest', role: 'listbox', hidden: true,
      'aria-label': t('customer_list'),
    });
    const inp = h('input', {
      id: 'pos-customer-input', type: 'text', autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false',
      role: 'combobox', 'aria-autocomplete': 'list', 'aria-expanded': 'false', 'aria-controls': 'pos-customer-list',
      'aria-labelledby': 'pos-customer-label', 'aria-describedby': 'pos-customer-hint',
      value: email, 'data-testid': 'pos-email',
    });

    function paint(hits) {
      suggest.items = hits;
      suggest.hi = -1;
      if (!hits.length) { closeCustomerList(); return; }
      list.hidden = false;
      list.removeAttribute('hidden');
      inp.setAttribute('aria-expanded', 'true');
      inp.removeAttribute('aria-activedescendant');
      list.replaceChildren(...hits.map((hit, i) => {
        const id = `pos-cust-opt-${i}`;
        const label = hit.name ? `${hit.name}, ${hit.email}` : hit.email;
        return h('li', { role: 'presentation' }, h('button', {
          type: 'button', id, role: 'option', class: 'pos-hit', 'aria-selected': 'false', 'aria-label': label,
          'data-testid': 'pos-customer-hit',
          onmousedown: (e) => { e.preventDefault(); choose(hit); },
          onclick: () => choose(hit),
        }, h('span', { text: hit.name || hit.email }), hit.name ? h('small', { text: hit.email }) : null));
      }));
    }

    function mark() {
      const buttons = [...list.querySelectorAll('[role="option"]')];
      buttons.forEach((b, i) => {
        const on = i === suggest.hi;
        b.setAttribute('aria-selected', on ? 'true' : 'false');
        if (on) inp.setAttribute('aria-activedescendant', b.id || b.getAttribute('id'));
      });
      if (suggest.hi < 0) inp.removeAttribute('aria-activedescendant');
      if (suggest.hi >= 0 && buttons[suggest.hi]?.scrollIntoView) buttons[suggest.hi].scrollIntoView({ block: 'nearest' });
    }

    function choose(hit) {
      email = hit.email;
      inp.value = hit.email;
      closeCustomerList();
    }

    async function load(q, my) {
      let rows = [];
      try { rows = await searchCustomers(q, rpc); } catch { rows = []; }
      if (!Array.isArray(rows)) rows = [];
      if (my !== suggest.req || gen !== suggest.gen || !list.isConnected) return;
      if (String(inp.value || '').trim() !== q) return;
      paint(posCustomerHits(rows, 8));
    }

    function schedule() {
      const q = String(inp.value || '').trim();
      clearTimeout(suggest.timer);
      const my = ++suggest.req;
      if (q.length < 2) { closeCustomerList(); return; }
      suggest.timer = setTimeout(() => { void load(q, my); }, 250);
    }

    inp.addEventListener('input', () => { email = String(inp.value || ''); schedule(); });
    inp.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        if (!customerListOpen()) {
          if (e.key === 'ArrowDown') schedule();
          return;
        }
        e.preventDefault?.();
        const n = suggest.items.length;
        if (!n) return;
        suggest.hi = e.key === 'ArrowDown' ? (suggest.hi + 1) % n : (suggest.hi <= 0 ? n - 1 : suggest.hi - 1);
        mark();
        return;
      }
      if (e.key === 'Enter' && customerListOpen() && suggest.hi >= 0 && suggest.items[suggest.hi]) {
        e.preventDefault?.();
        choose(suggest.items[suggest.hi]);
        return;
      }
      if (e.key === 'Escape' && customerListOpen()) {
        e.preventDefault?.();
        e.stopPropagation?.();
        closeCustomerList();
      }
    });
    inp.addEventListener('blur', () => {
      setTimeout(() => {
        if (!list.isConnected) return;
        const active = document.activeElement;
        if (active && list.contains(active)) return;
        if (customerListOpen()) closeCustomerList();
      }, 200);
    });

    return h('div', { class: 'fld pos-customer', 'data-testid': 'pos-customer' },
      h('label', { id: 'pos-customer-label', for: 'pos-customer-input', text: t('customer') }),
      inp,
      list,
      h('small', { id: 'pos-customer-hint', class: 'muted', text: t('customer_help') }));
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
    if (phase === 'paying' && payInfo?.kind === 'checkoutx') {
      if (cx.state === 'failed' || cx.state === 'cancelled') {
        box.append(h('p', { role: 'alert', class: 'err', 'data-testid': 'pos-cx-failed', text: t(cx.state === 'failed' ? 'cx_failed' : 'cx_cancelled') + (cx.failure ? ` (${cx.failure})` : '') }));
        if (payError) box.append(h('p', { role: 'alert', class: 'err', 'data-testid': 'pos-pay-error', text: payError }));
        box.append(
          h('button', { type: 'button', class: 'btn primary', 'data-testid': 'pos-cx-retry', text: busy ? t('wait') : t('cx_retry'), disabled: busy || null, onclick: () => retryCheckoutx() }),
          h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'pos-cx-cancel', text: t('cx_cancel'), disabled: busy || null, onclick: () => voidOpen().then(() => { payOpen = true; draw(); }) }));
        if (cx.configureLink) box.append(h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'pos-cx-configure', text: t('cx_configure'), onclick: () => openAppLink(cx.configureLink) }));
        return box;
      }
      if (payInfo.simulated) box.append(h('p', { class: 'muted', 'data-testid': 'pos-cx-simulated', text: t('cx_simulated') }));
      box.append(h('p', { class: 'muted', 'data-testid': 'pos-cx-help', text: t('cx_waiting_help') }),
        payInfo.deep_link ? h('button', { type: 'button', class: 'btn primary', 'data-testid': 'pos-cx-open', text: t('cx_open'), onclick: () => openAppLink(payInfo.deep_link) }) : null,
        h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'pos-cx-cancel', text: t('cx_cancel'), disabled: busy || null, onclick: () => voidOpen().then(() => { payOpen = true; draw(); }) }));
    }
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
      const mailField = emailBox();
      if (mailField) dialog.append(mailField);
      const cxField = checkoutxBox();
      if (cxField) dialog.append(cxField);
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

  // ---- t1808u: myynnin haku ----
  function addProduct(p) {
    const row = { ...p, name: p.name_fi || p.name };
    const go = () => { cart = cartAdd(cart, row); draw(); };
    if (phase === 'paying') voidOpen().then(go); else go();
  }

  function itemFromCatalog(p) {
    const full = allProducts.find((x) => Number(x.id) === Number(p.product_id)) || null;
    return { product_id: p.product_id, name: p.name, name_fi: p.name, name_en: p.name_en || null, price: Number(p.price), vat_rate: p.vat_rate, age_restricted: !!p.age_restricted, bookable: full ? isBookableProduct(full) : false, pos: true, product: full };
  }

  // Ruudukon painike: varattava tuote avaa varauspaneelin, muut menevät suoraan koriin.
  function pickCatalog(p) {
    const it = itemFromCatalog(p);
    if (it.bookable) openBooking(it); else addProduct(it);
  }

  function clearSale() { sale.q = ''; sale.hi = -1; sale.opts = []; }

  function openCustom(text) {
    clearSale();
    customOpen = true;
    customError = '';
    customForm = { ...customForm, description: String(text || '') };
    draw();
    queueMicrotask(() => {
      const el = document.getElementById(text ? 'pos-custom-price' : 'pos-custom-description');
      el?.scrollIntoView?.({ block: 'center' });
      el?.focus?.();
    });
  }

  function chooseSale(opt, { keyboard = false } = {}) {
    if (!opt) return;
    if (opt.type === 'custom') { openCustom(opt.text); return; }
    const it = opt.item;
    clearSale();
    sale.focus = keyboard;
    if (it.bookable) openBooking(it); else addProduct(it);
  }

  function saleBox() {
    const results = () => searchSaleProducts({ products: allProducts, catalog, channelData, lang: getLang() }, sale.q);
    const list = h('ul', { id: 'pos-sale-list', class: 'pos-suggest pos-sale-list', role: 'listbox', 'aria-label': t('sale_results'), 'data-testid': 'pos-sale-list', hidden: true });
    const inp = h('input', {
      id: 'pos-sale-input', type: 'text', inputmode: 'search', class: 'pos-sale-input', autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false', enterkeyhint: 'search',
      role: 'combobox', 'aria-autocomplete': 'list', 'aria-expanded': 'false', 'aria-controls': 'pos-sale-list', 'aria-label': t('sale_search'),
      placeholder: t('sale_placeholder'), value: sale.q, 'data-testid': 'pos-sale-input',
    });
    const clear = h('button', { type: 'button', class: 'btn ghost pos-sale-clear', 'aria-label': t('sale_clear'), 'data-testid': 'pos-sale-clear', hidden: true,
      onclick: () => { clearSale(); paint(); inp.value = ''; inp.focus?.(); } }, icon('close', 20));

    function mark() {
      const buttons = [...list.querySelectorAll('[role="option"]')];
      buttons.forEach((b, i) => b.setAttribute('aria-selected', i === sale.hi ? 'true' : 'false'));
      if (sale.hi >= 0 && buttons[sale.hi]) { inp.setAttribute('aria-activedescendant', buttons[sale.hi].id || buttons[sale.hi].getAttribute('id')); buttons[sale.hi].scrollIntoView?.({ block: 'nearest' }); }
      else inp.removeAttribute('aria-activedescendant');
    }

    function paint() {
      sale.opts = saleOptions(results(), sale.q);
      clear.hidden = !sale.q;
      if (!sale.q) clear.setAttribute('hidden', ''); else clear.removeAttribute('hidden');
      if (!sale.opts.length) {
        list.hidden = true; list.setAttribute('hidden', ''); list.replaceChildren();
        inp.setAttribute('aria-expanded', 'false'); inp.removeAttribute('aria-activedescendant');
        return;
      }
      list.hidden = false; list.removeAttribute('hidden');
      inp.setAttribute('aria-expanded', 'true');
      const nProducts = sale.opts.filter((o) => o.type === 'product').length;
      list.replaceChildren(...sale.opts.map((o, i) => {
        const id = `pos-sale-opt-${i}`;
        if (o.type === 'custom') {
          return h('li', { role: 'presentation' }, h('button', {
            type: 'button', id, role: 'option', class: 'pos-hit pos-sale-hit pos-sale-custom', 'aria-selected': 'false', 'data-testid': 'pos-sale-custom',
            onclick: () => chooseSale(o),
          }, h('span', { class: 'pos-sale-name' }, h('strong', { text: t('sale_custom') }), ' ', h('span', { text: `”${o.text}”` })),
          !nProducts ? h('small', { class: 'muted', text: t('sale_none') }) : null));
        }
        const it = o.item;
        return h('li', { role: 'presentation' }, h('button', {
          type: 'button', id, role: 'option', class: 'pos-hit pos-sale-hit', 'aria-selected': 'false', 'data-testid': 'pos-sale-hit', 'data-product': String(it.product_id),
          onclick: () => chooseSale(o),
        }, h('span', { class: 'pos-sale-name' }, h('span', { text: it.name }), it.code ? h('small', { class: 'muted', text: ` ${it.code}` }) : null,
          it.bookable ? h('small', { class: 'pos-sale-badge', text: t('sale_bookable') }) : null,
          it.age_restricted ? h('small', { class: 'pos-age', text: t('age') }) : null),
        h('strong', { class: 'pos-sale-price', text: money(it.price) })));
      }));
      mark();
    }

    inp.addEventListener('input', () => { sale.q = String(inp.value || ''); sale.hi = -1; paint(); });
    inp.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        if (!sale.opts.length) return;
        e.preventDefault?.();
        sale.hi = moveHi(sale.hi, e.key === 'ArrowDown' ? 1 : -1, sale.opts.length);
        mark();
        return;
      }
      if (e.key === 'Enter') {
        const target = enterTarget(sale.opts, sale.hi);
        if (!target) return;
        e.preventDefault?.();
        chooseSale(target, { keyboard: true });
        return;
      }
      if (e.key === 'Escape' && sale.q) {
        e.preventDefault?.();
        e.stopPropagation?.();
        clearSale(); inp.value = ''; paint();
      }
    });
    paint();
    return h('div', { class: 'fld pos-sale', 'data-testid': 'pos-sale' },
      h('label', { for: 'pos-sale-input', text: t('sale_search') }),
      h('div', { class: 'pos-sale-row' }, inp, clear),
      list,
      h('small', { class: 'muted pos-sale-help', text: t('sale_help') }));
  }

  // ---- t1812u: varattava tuote vain maksuksi (ei varausta). Kevyt paneeli, kori säilyy. ----
  function openBooking(it) {
    bk = { item: it, qty: 1, node: null };
    draw();
    queueMicrotask(() => { bk?.node?.scrollIntoView?.({ block: 'nearest' }); document.getElementById('pos-book-note')?.focus?.(); });
  }

  function closeBooking() { bk = null; draw(); }

  function addUnbooked() {
    const b = bk;
    if (!b) return;
    const note = String(document.getElementById('pos-book-note')?.value || '');
    const date = String(document.getElementById('pos-book-date')?.value || '');
    bk = null;
    const go = () => { cart = cartAddUnbooked(cart, b.item, { quantity: b.qty, note, date }); showLines = true; draw(); };
    if (phase === 'paying') voidOpen().then(go); else go();
  }

  // Luodaan kerran (ei piirretä joka näppäilyllä), jotta kenttien kohdistus säilyy.
  function bookPanel() {
    if (!bk) return null;
    const b = bk;
    const it = b.item;
    const perPerson = it.product?.price_type === 'per_person';
    const qtyLabel = perPerson ? t('book_persons') : t('book_qty');
    const qty = stepper({ label: qtyLabel, value: b.qty, min: 1, max: 20, inputName: 'pos-book-qty', size: 'lg', onChange: (n) => { b.qty = n; } });
    const node = h('section', { class: 'card pos-book', role: 'group', 'aria-labelledby': 'pos-book-title', 'data-testid': 'pos-book' },
      h('div', { class: 'pos-book-head' },
        h('h2', { id: 'pos-book-title', text: `${t('book_title')}: ${it.name}` }),
        h('button', { type: 'button', class: 'icon-btn', 'aria-label': t('book_cancel'), 'data-testid': 'pos-book-close', onclick: () => closeBooking() }, icon('close', 22))),
      h('p', { class: 'muted pos-book-price', text: money(it.price) }),
      h('p', { class: 'muted', 'data-testid': 'pos-book-help', text: t('book_help') }),
      h('div', { class: 'fld', 'data-testid': 'pos-book-qty' }, h('span', { class: 'fld-lab', text: qtyLabel }), qty.node),
      h('div', { class: 'fld' }, h('label', { class: 'fld-lab', for: 'pos-book-date', text: t('book_day_opt') }),
        h('input', { type: 'date', id: 'pos-book-date', 'data-testid': 'pos-book-date', value: '' })),
      h('div', { class: 'fld' }, h('label', { class: 'fld-lab', for: 'pos-book-note', text: t('book_note') }),
        h('input', { type: 'text', id: 'pos-book-note', 'data-testid': 'pos-book-note', maxlength: 200, autocomplete: 'off', placeholder: t('book_note_ph'), value: '' })),
      h('div', { class: 'pos-book-actions' },
        h('button', { type: 'button', class: 'btn primary', 'data-testid': 'pos-book-add', text: t('book_add'), onclick: () => addUnbooked() }),
        h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'pos-book-cancel', text: t('book_cancel'), onclick: () => closeBooking() })));
    node.addEventListener('keydown', (e) => { if (e.key === 'Escape') { e.preventDefault?.(); closeBooking(); } });
    b.node = node;
    return node;
  }

  function draw() {
    const hadSaleFocus = sale.focus || document.activeElement?.id === 'pos-sale-input';
    sale.focus = false;
    const total = cartTotal(cart);
    const grid = h('div', { class: 'pos-grid', 'data-testid': 'pos-grid' });
    if (!catalog.length) {
      grid.append(h('div', { class: 'pos-empty', 'data-testid': 'pos-empty' },
        h('p', { text: t('no_products') }),
        h('p', { class: 'muted', text: t('empty_help') }),
        canEdit ? h('button', { type: 'button', class: 'btn primary lg pos-edit', 'data-testid': 'pos-add', text: t('add'), onclick: () => { editing = true; draw(); } }) : null));
    }
    for (const p of catalog) {
      grid.append(h('button', { type: 'button', class: 'pos-btn', 'data-testid': `pos-product-${p.product_id}`, onclick: () => pickCatalog(p) },
        h('span', { class: 'pos-name', text: p.name }),
        p.age_restricted ? h('small', { class: 'pos-age', text: t('age') }) : null,
        h('strong', { class: 'pos-price', text: money(p.price) })));
    }

    const wide = isWide();
    const lines = h('div', { class: 'pos-panel', 'data-testid': 'pos-panel' });
    const lineQty = cart.reduce((n, r) => n + r.quantity, 0);
    if (!wide) lines.append(h('button', {
      type: 'button', class: 'pos-lines-btn', 'data-testid': 'pos-lines',
      'aria-expanded': showLines ? 'true' : 'false',
      'aria-label': `${t('cart')} ${lineQty}`,
      onclick: () => { showLines = !showLines; draw(); },
    },
      h('span', { class: 'pos-lines-label', text: t('cart') }),
      h('span', { class: 'pos-lines-count', text: String(lineQty) })));
    if (showLines || wide) {
      if (!cart.length) lines.append(h('p', { class: 'muted', text: t('empty') }));
      for (const r of cart) {
        const key = cartLineKey(r);
        lines.append(h('div', { class: 'pos-line', 'data-testid': r.kind === 'custom' ? 'pos-custom-line' : 'pos-product-line' },
          h('span', { class: 'grow' }, r.unbooked ? `${r.name} (${t('unbooked')})` : r.name,
            r.unbooked && (r.date || r.note) ? h('small', { class: 'muted pos-line-note', 'data-testid': 'pos-line-note', text: [r.date ? r.date.split('-').reverse().map(Number).join('.') : '', r.note || ''].filter(Boolean).join(' · ') }) : null),
          h('button', { type: 'button', class: 'btn pos-step', 'aria-label': t('qty_less'), text: '−', onclick: () => { cart = cartSetQty(cart, key, r.quantity - 1); if (phase === 'paying') voidOpen(); draw(); } }),
          h('span', { class: 'pos-qty', text: String(r.quantity) }),
          h('button', { type: 'button', class: 'btn pos-step', 'aria-label': t('qty_more'), text: '+', onclick: () => { cart = cartSetQty(cart, key, r.quantity + 1); if (phase === 'paying') voidOpen(); draw(); } }),
          h('strong', { text: money(r.unit_price * r.quantity) }),
          h('button', { type: 'button', class: 'btn ghost', text: t('remove'), onclick: () => { cart = cartSetQty(cart, key, 0); if (phase === 'paying') voidOpen(); draw(); } })));
      }
      const vatRows = cartVatBreakdown(cart);
      if (vatRows.length) {
        const box = h('div', { class: 'pos-vat', 'data-testid': 'pos-vat-breakdown', 'aria-label': t('vat_breakdown') });
        for (const v of vatRows) {
          box.append(h('p', { class: 'muted pos-vat-row', text: `${t('custom_vat')} ${String(v.vat_rate).replace('.', ',')} %: ${money(v.vat)}` }));
        }
        lines.append(box);
      }
    }


    function submitCustom() {
      const parsedPrice = parseEuroInput(customForm.price);
      const qty = Number.parseInt(String(customForm.quantity || '1'), 10);
      const check = validateCustomLine({
        description: customForm.description,
        quantity: qty,
        unit_price: parsedPrice,
        vat_rate: customForm.vat_rate,
      }, vatRates);
      if (!check.ok) { customError = t(check.error); draw(); return; }
      customError = '';
      if (phase === 'paying') voidOpen();
      cart = cartAddCustom(cart, check);
      showLines = true;
      customOpen = false;
      customForm = { description: '', quantity: '1', price: '', vat_rate: customForm.vat_rate || (vatRates.includes(25.5) ? '25.5' : String(vatRates[0] || '')) };
      draw();
    }

    const customBox = h('div', { class: 'pos-custom', 'data-testid': 'pos-custom' });
    if (!customOpen) {
      customBox.append(h('button', {
        type: 'button', class: 'btn ghost pos-custom-toggle', 'data-testid': 'pos-custom-add',
        text: t('custom_add'),
        onclick: () => { customOpen = true; customError = ''; draw(); queueMicrotask(() => document.getElementById('pos-custom-description')?.focus?.()); },
      }));
    } else {
      const vatSelect = h('select', {
        id: 'pos-custom-vat', 'data-testid': 'pos-custom-vat', 'aria-label': t('custom_vat'),
        onchange: (e) => { customForm = { ...customForm, vat_rate: e.target.value }; },
      });
      for (const rate of vatRates) {
        const opt = h('option', { value: String(rate), text: `${String(rate).replace('.', ',')} %` });
        if (String(rate) === String(customForm.vat_rate)) opt.selected = true;
        vatSelect.append(opt);
      }
      customBox.append(
        h('h2', { class: 'pos-custom-title', text: t('custom_title') }),
        h('label', { class: 'fld', for: 'pos-custom-description' }, h('span', { text: t('custom_description') }),
          h('input', {
            id: 'pos-custom-description', type: 'text', maxlength: '200', autocomplete: 'off',
            'data-testid': 'pos-custom-description', 'aria-label': t('custom_description'),
            value: customForm.description,
            oninput: (e) => { customForm = { ...customForm, description: e.target.value }; },
          })),
        h('div', { class: 'pos-custom-row' },
          h('label', { class: 'fld', for: 'pos-custom-qty' }, h('span', { text: t('custom_qty') }),
            h('input', {
              id: 'pos-custom-qty', type: 'number', min: '1', max: '20', step: '1', inputmode: 'numeric',
              'data-testid': 'pos-custom-qty', 'aria-label': t('custom_qty'), value: customForm.quantity,
              oninput: (e) => { customForm = { ...customForm, quantity: e.target.value }; },
            })),
          h('label', { class: 'fld', for: 'pos-custom-price' }, h('span', { text: t('custom_price') }),
            h('input', {
              id: 'pos-custom-price', type: 'text', inputmode: 'decimal', autocomplete: 'off',
              'data-testid': 'pos-custom-price', 'aria-label': t('custom_price'), value: customForm.price,
              oninput: (e) => { customForm = { ...customForm, price: e.target.value }; },
            })),
          h('label', { class: 'fld', for: 'pos-custom-vat' }, h('span', { text: t('custom_vat') }), vatSelect)),
        customError ? h('p', { role: 'alert', class: 'err', 'data-testid': 'pos-custom-error', text: customError }) : '',
        h('div', { class: 'pos-custom-actions' },
          h('button', { type: 'button', class: 'btn primary', 'data-testid': 'pos-custom-save', text: t('custom_save'), onclick: () => submitCustom() }),
          h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'pos-custom-cancel', text: t('custom_cancel'),
            onclick: () => { customOpen = false; customError = ''; draw(); } })),
      );
    }
    if (!wide) lines.append(customBox);

    const side = h('aside', { class: 'pos-side', 'data-testid': 'pos-side' });
    if (wide) side.append(h('h2', { class: 'pos-cart-title', text: t('cart') }), lines);
    side.append(
      h('p', { class: 'pos-total-label', text: t('total') }),
      h('p', { class: 'pos-total', 'data-testid': 'pos-total', 'aria-live': 'polite', 'aria-atomic': 'true', text: money(order && phase !== 'cart' ? order.total : total) }));
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
      h('div', { class: 'pos-layout', 'data-testid': 'pos-layout' }, h('div', { class: 'pos-main' }, saleBox(), bookPanel(), grid, wide ? customBox : lines), side),
    ];
    if (tools) kids.push(tools);
    root.replaceChildren(...kids);
    syncModal();
    if (hadSaleFocus && !payOpen) document.getElementById('pos-sale-input')?.focus?.();
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
  await restoreCheckoutx();
  draw();
  // Leveys ylittää 800 px tai alittaa sen (tabletin kääntö): piirretään uudelleen, ei kesken maksun.
  if (wideMq?.addEventListener) {
    let lastWide = isWide();
    wideMq.addEventListener('change', () => {
      if (!root.isConnected || lastWide === isWide()) return;
      lastWide = isWide();
      if (!payOpen) draw();
    });
  }
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
