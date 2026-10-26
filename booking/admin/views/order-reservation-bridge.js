// booking_182: lisäpolku nykyisten tilausten ja varausten näkymiin ilman muutoksia niiden vanhaan toteutukseen.
// Moduuli käynnistetään vain, kun booking.settings.admin_order_reservation_flow_enabled === true.
import { h, toast, errMsg } from '../ui.js';
import { reservationDialog } from './shared.js';
import { openAddToOrder, openOrderPaymentLink, openOrderRecordPayment } from './order-add.js';
import { canAddPurchase, orderDeepLink, reservationDeepLink } from '../order-reservation-logic.js';
import { orderText as tx } from '../orders-texts.js';

const text = (s) => String(s ?? '');

export function installOrderReservationBridge({ node, api, ctx, rpc, view }) {
  const loading = new WeakSet();
  const promises = new Map();
  // Yhdistetään vain samanaikaiset haut samalle tilaukselle. Valmista tulosta ei säilytetä,
  // koska vanhat dialogit (maksun kirjaus, hyvitys, linkki) muuttavat saldoa ilman tämän moduulin tietoa.
  const getOrder = (id) => {
    const k = String(id);
    if (!promises.has(k)) promises.set(k, api.getOrder(id).finally(() => promises.delete(k)));
    return promises.get(k);
  };
  const afterChange = (order) => {
    promises.delete(String(order.order_id));
    api.changed?.();
    // Haku hakee myös osittain maksetun tilauksen, vaikka oletussuodatin on maksetut.
    view.setSearch(String(order.order_no), { open: true });
  };
  async function addToOrder(orderId, reservationId = null) {
    try {
      const order = await getOrder(orderId);
      const allowed = canAddPurchase(order, ctx);
      if (!allowed.allowed) { toast(tx('ui.admin.orders.' + allowed.reason), 'warn'); return; }
      await openAddToOrder({ api, ctx, order, reservationId,
        onDone: () => afterChange(order) });
    } catch (e) { toast(errMsg(e), 'err'); }
  }
  async function createLink(orderId) {
    try {
      if (!ctx.can('payments.manage')) return;
      const order = await getOrder(orderId);
      openOrderPaymentLink({ api, ctx, order, onDone: () => afterChange(order) });
    } catch (e) { toast(errMsg(e), 'err'); }
  }
  async function openBooking(order, reservation, opener) {
    const fallback = () => { location.hash = reservationDeepLink(reservation.reservation_id); };
    let dlg;
    try {
      const data = await rpc('admin_list_reservations', {
        p_reservation_id: Number(reservation.reservation_id), p_limit: 1, p_offset: 0,
      });
      const rows = Array.isArray(data) ? data : Array.isArray(data?.rows) ? data.rows : [];
      const row = rows.find((r) => Number(r.reservation_id) === Number(reservation.reservation_id));
      if (!row) return fallback();
      dlg = reservationDialog(row, {
        methods: ctx.refs?.methods || [], refs: ctx.refs, can: ctx.can,
        onChange: () => afterChange(order),
      });
    } catch { toast(tx('ui.admin.orders.reservation_open_failed'), 'warn'); return fallback(); }
    if (!dlg) return fallback();
    dlg.addEventListener('close', () => {
      const next = node.querySelector(`[data-booking182-id="${reservation.reservation_id}"]`);
      (next || (opener.isConnected ? opener : null))?.focus();
    }, { once: true });
    // Jo olemassa olevan tilauslinkin navigaatio korjataan uudelle Tilaukset-reitille.
    const back = dlg.querySelector('[data-testid="order-link"]');
    if (back && ctx.can('payments.manage')) {
      back.href = orderDeepLink(order.order_no);
      back.textContent = tx('ui.admin.res.open_order', { no: order.order_no });
    }
    const body = dlg.querySelector('.dlg-body');
    if (!body) return;
    const check = canAddPurchase(order, ctx);
    const extra = h('div', { class: 'box stack', 'data-testid': 'order-reservation-purchase' },
      h('button', { type: 'button', class: 'btn primary',
        'data-testid': 'order-reservation-add',
        text: tx('ui.admin.res.add_purchase'),
        disabled: !check.allowed || null,
        onclick: () => { dlg.close(); addToOrder(order.order_id, reservation.reservation_id); },
      }),
      !check.allowed ? h('p', { class: 'muted', text: tx('ui.admin.orders.' + check.reason) }) : null);
    body.append(extra);
    // Vanha maksulinkki-placeholder poistetaan vain tämän ominaisuuden ollessa päällä.
    for (const el of body.querySelectorAll('.box')) {
      const heading = el.querySelector('strong');
      if (!heading || heading.textContent?.trim() !== 'Verkkomaksulinkki (Visma Pay)') continue;
      el.replaceChildren(...(ctx.can('payments.manage') ? [
        h('button', { type: 'button', class: 'btn', 'data-testid': 'order-reservation-create-link',
          text: tx('ui.admin.res.payment_link'), onclick: () => { dlg.close(); createLink(order.order_id); } }),
      ] : []));
    }
    // Vanha lisäpalveluiden muokkausdialogi voi palauttaa addon_paid / addon_link_open.
    // Tarjoa tällöin maksettua summaa rikkomatta lisäyspolku ja tilauksen hyvitys.
    const errorObserver = new MutationObserver(() => {
      for (const modal of document.querySelectorAll('dialog[open]')) {
        if (modal === dlg || modal.querySelector('[data-testid="booking182-addon-help"]')) continue;
        const visibleErrors = [...modal.querySelectorAll('[role="alert"]')].filter((el) => !el.hidden && /makset|maksulink|paid|payment link/i.test(el.textContent || ''));
        if (!visibleErrors.length) continue;
        const links = h('div', { class: 'row wrap', 'data-testid': 'booking182-addon-help' },
          check.allowed ? h('button', { type: 'button', class: 'btn sm', text: tx('ui.admin.res.paid_addon_purchase'),
            onclick: () => { modal.close(); dlg.close(); addToOrder(order.order_id, reservation.reservation_id); } }) : null,
          ctx.can('payments.refund') && ctx.can('payments.manage') ? h('a', {
            class: 'btn sm ghost', href: orderDeepLink(order.order_no),
            text: tx('ui.admin.res.open_refund'),
          }) : null);
        modal.querySelector('.dlg-body')?.append(links);
      }
    });
    errorObserver.observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true,
      attributeFilter: ['hidden'] });
    dlg.addEventListener('close', () => errorObserver.disconnect(), { once: true });
  }
  // Koristele alkuperäinen varauslista siten, että tuotteiden nimet pysyvät tekstisolmuina.
  async function decorate(list) {
    if (loading.has(list)) return;
    loading.add(list);
    try {
      const host = list.closest('[data-order-id]');
      const id = host?.dataset.orderId;
      if (!id) return;
      const order = await getOrder(id);
      if (!list.isConnected) return;
      [...list.children].forEach((li, index) => {
        const res = order.reservations?.[index];
        if (!res || li.querySelector('[data-testid="order-open-reservation"]')) return;
        const button = h('button', { type: 'button', class: 'btn sm ghost',
          'data-testid': 'order-open-reservation',
          'data-booking182-id': String(res.reservation_id),
          'aria-label': tx('ui.admin.orders.open_reservation_label', {
            product: res.product_name || '', time: text(res.starts_at),
          }),
          text: tx('ui.admin.orders.open_reservation'),
          onclick: () => openBooking(order, res, button),
        });
        li.append(button);
      });
    } catch (e) { toast(errMsg(e), 'err'); }
    finally { loading.delete(list); }
  }
  let queued = false;
  function refresh() {
    if (queued) return;
    queued = true;
    queueMicrotask(() => {
      queued = false;
      for (const el of node.querySelectorAll('[data-testid="order-reservations"]')) {
        if (!el.querySelector('[data-testid="order-open-reservation"]')) decorate(el);
      }
    });
  }
  // Korvaa vain kytkimen ollessa päällä vanhojen tilauspainikkeiden toiminta.
  node.addEventListener('click', async (event) => {
    const action = event.target.closest?.('[data-action="addToOrder"],[data-action="createPaymentLink"]');
    if (!action || action.disabled) return;
    const id = action.closest('[data-order-id]')?.dataset.orderId;
    if (!id) return;
    event.preventDefault(); event.stopImmediatePropagation();
    if (action.dataset.action === 'addToOrder') await addToOrder(id);
    else await createLink(id);
  }, true);
  const observer = new MutationObserver(refresh);
  observer.observe(node, { subtree: true, childList: true });
  refresh();
  return { disconnect: () => observer.disconnect() };
}
