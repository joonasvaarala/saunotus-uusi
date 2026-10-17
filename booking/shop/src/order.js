// Asiakkaan tilaussivu: /tilaus/?t=<token> (sopimus: settings.order_page_path; EN-sivu /en/order/?t=<token>, tilauksen locale ohjaa oikeaan kieleen). Token on vain URL-parametrina (ei hashissa/polussa → ei Referer-vuotoa; sivulla meta referrer=no-referrer).
// Näyttää tilauksen rivit, maksutilan, kuitit sekä ohjauksen lisäykseen ja peruutuspyyntöön. Data: order-api.js (mock kun ?mock=1; puuttuva RPC → "ei vielä käytössä").
import { rpc } from './sb.js';
import { OT } from './order-texts.js';
import { createOrderApi, validToken } from './order-api.js';
import { createGiftApi } from './gift-api.js';
import { redeemSection, cardsSection, claimsSection } from './order-gift.js';

const S = window.BOOKING_SHOP;
const L = OT[S.lang] ? S.lang : 'fi', t = OT[L];
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

async function main() {
  const token = new URLSearchParams(location.search).get('t');
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
  await loadGift();
  let notice = null;   // vahvistusteksti lunastuspyynnön jälkeen (näytetään pyyntölistan yläosassa, kerran)
  draw(o);
  async function reloadAfterGift(text) {
    try { const n = await api.get(); if (n?.ok) { await loadGift(); draw(n); } } catch { /* näkymä jää ennalleen */ }
    flash(true, text);
  }
  // kumppanin lahjakortti lähetetty lunastettavaksi / koodi korjattu: lataa tilaus + pyynnöt uudelleen ja vie vahvistusteksti näkyviin
  async function reloadAfterClaim(n) {
    notice = { ok: true, ...n };
    try { const fresh = await api.get(); if (fresh?.ok) { await loadGift(); draw(fresh); } else draw(o); } catch { draw(o); }
    const el = root.querySelector('[data-testid=vc-notice]'); if (el) { el.scrollIntoView({ block: 'center' }); el.focus({ preventScroll: true }); }
  }

  function draw(o) {
    const stKey = o.cancel_request?.status === 'open' ? 'cancel_requested' : o.status;
    const unpaid = o.unpaid;
    const head = h('section', { class: 'ord-card', 'aria-labelledby': 'ord-h' },
      h('h2', { id: 'ord-h', 'data-testid': 'order-title', text: `${t.order} #${o.order_no}` }),
      h('div', { class: 'ord-badges' }, badge(`st-${stKey}`, t[`st.${stKey}`] || stKey), badge(`pay-${o.payment_status}`, t[`pay.${o.payment_status}`] || o.payment_status)),
      o.created_at ? h('p', { class: 'bk-meta', text: `${t.created}: ${dt(o.created_at)}` }) : null);
    const resv = o.reservations.length ? h('section', { class: 'ord-card', 'aria-labelledby': 'ord-rv' }, h('h3', { id: 'ord-rv', text: t.reservationsTitle }),
      h('ul', { class: 'ord-lines', 'data-testid': 'order-reservations' }, o.reservations.map((r) => h('li', {},
        h('span', { class: 'ord-l-main' }, h('strong', { text: r.product_name }), r.status === 'cancelled' ? ' ' : null, r.status === 'cancelled' ? badge('st-cancelled', t.cancelledRow) : null),
        h('span', { class: 'ord-l-meta', text: `${dt(r.starts_at)}–${hm(r.ends_at)} · ${t.persons.replace('{n}', r.persons)}${r.addons.length ? ' · ' + r.addons.map((a) => `${nm(a)} × ${a.quantity}`).join(', ') : ''}` }))))) : null;
    const lines = h('section', { class: 'ord-card', 'aria-labelledby': 'ord-l' }, h('h3', { id: 'ord-l', text: t.linesTitle }),
      h('ul', { class: 'ord-lines', 'data-testid': 'order-lines' }, o.items.map((i) => h('li', {},
        h('span', { class: 'ord-l-main' }, h('strong', { text: i.quantity > 1 ? `${nm(i)} × ${i.quantity}` : nm(i) })),
        h('span', { class: 'ord-l-sum', text: money(i.line_total) })))),
      h('dl', { class: 'ord-sums' }, h('div', {}, h('dt', { text: `${t.total} (${t.vatIncl})` }), h('dd', { 'data-testid': 'order-total', text: money(o.total) })), h('div', {}, h('dt', { text: t.paid }), h('dd', { text: money(o.paid) })),
        h('div', { class: unpaid > 0 ? 'due' : '' }, h('dt', { text: t.unpaid }), h('dd', { 'data-testid': 'order-unpaid', text: money(unpaid) }))));
    // maksulinkki: avoin (pending) maksu + verkkomaksu käytössä → linkki; muuten maksu paikan päällä
    const link = o.online_payment_enabled ? o.payments.find((p) => p.status === 'pending' && p.link_path) : null;
    const pay = unpaid > 0 ? h('section', { class: 'ord-card', 'aria-labelledby': 'ord-p' }, h('h3', { id: 'ord-p', text: t.paymentTitle }),
      link ? h('a', { class: 'btn ord-btn', 'data-testid': 'pay-link', href: S.base ? S.base + link.link_path : link.link_path, text: `${t.payRest} (${money(unpaid)})` })
        : h('button', { type: 'button', class: 'btn light ord-btn', disabled: true, 'data-testid': 'pay-rest', text: `${t.payRest} (${money(unpaid)})` }),
      link ? null : h('p', { class: 'bk-note', text: t.payRestSoon })) : null;
    const giftCards = gift.cards.length ? cardsSection({ S, L, api: gapi, cards: gift.cards }) : null;
    const giftUse = gift.redeem && unpaid > 0 && !gift.cards.length && ['confirmed', 'pending'].includes(o.status) ? redeemSection({ L, api: gapi, token, onApplied: reloadAfterGift, onClaimed: reloadAfterClaim }) : null;
    const claimBox = gift.claims.length ? claimsSection({ S, L, api: gapi, token, claims: gift.claims, notice, onChanged: reloadAfterClaim }) : null;
    notice = null;
    const receipts = h('section', { class: 'ord-card', 'aria-labelledby': 'ord-r' }, h('h3', { id: 'ord-r', text: t.receiptsTitle }),
      o.receipts.length ? h('ul', { class: 'ord-lines', 'data-testid': 'receipts' }, o.receipts.map((r) => h('li', {},
        h('span', { class: 'ord-l-main' }, h('strong', { text: r.receipt_no }), ' ', badge('', t[r.kind] || r.kind)), h('span', { class: 'ord-l-meta', text: `${r.issued_at ? dt(r.issued_at) : ''}${r.total ? ' · ' + money(r.total) : ''}` }),
        h('span', { class: 'ord-l-sum' }, h('button', { type: 'button', class: 'btn light ord-btn', 'data-testid': 'receipt-dl', onclick: (ev) => download(ev.currentTarget, r.receipt_no), text: t.download }))))) : h('p', { class: 'bk-note', text: t.noReceipts }));
    const msg = h('div', { 'aria-live': 'polite', class: 'ord-msg', 'data-testid': 'order-msg' });
    const note = o.change_deadline ? h('p', { class: 'bk-note', 'data-testid': 'change-note', text: o.can_change ? t.changeNote.replace('{date}', dt(o.change_deadline)) : t.changeClosed }) : null;
    const add = h('section', { class: 'ord-card', 'aria-labelledby': 'ord-a' }, h('h3', { id: 'ord-a', text: t.addTitle }), o.can_add && o.upsell_addons.length ? addForm(o) : h('p', { class: 'bk-note', text: t.addClosed }),
      h('p', { class: 'bk-note' }, `${t.addNewBooking} `, h('a', { href: S.shopHref, text: t.addNewBookingLink })));
    const cancel = h('section', { class: 'ord-card', 'aria-labelledby': 'ord-c' }, h('h3', { id: 'ord-c', text: t.cancelTitle }), note,
      o.cancel_request ? h('p', { class: 'bk-ok', role: 'status', 'data-testid': 'cancel-pending', text: t[`cancel.${o.cancel_request.status}`] || t['cancel.open'] }) : cancelForm());
    mount(api.mock ? h('p', { class: 'ord-mock', role: 'status', 'data-testid': 'mock-banner', text: t.mockBanner }) : null, h('div', { class: 'ord', 'data-testid': 'order-page' }, head, resv, lines, giftCards, claimBox, pay, giftUse, receipts, add, cancel, msg, phoneBox()));
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
  const flash = (ok, text) => { const m = root.querySelector('[data-testid=order-msg]'); if (m) m.replaceChildren(h('p', { class: ok ? 'bk-ok' : 'bk-error', role: ok ? 'status' : 'alert', text })); };
  // palvelimen virhe {ok:false, code, message}: tunnetut koodit omilla teksteillään, muuten palvelimen (suomenkielinen) viesti
  const failText = (r) => (r?.code && t[`err.${r.code}`]) || (L === 'fi' && r?.message) || t.error;
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
        const fresh = await api.get(); if (!fresh?.ok) throw new Error('get'); draw(fresh); flash(true, t.addDone);
      } catch { flash(false, t.error); btn.disabled = false; }
    } }, h('p', { class: 'bk-note', text: t.addLead }),
    resSel ? h('div', { class: 'bk-field' }, h('label', { for: 'ord-res', text: t.addReservation }), resSel) : null,
    h('div', { class: 'bk-field' }, h('label', { for: 'ord-addon', text: t.addAddon }), sel), h('div', { class: 'bk-field' }, h('label', { for: 'ord-qty', text: t.addQty }), qty), btn);
    return f;
  }
  function cancelForm() {
    const reason = h('textarea', { id: 'ord-reason', rows: 3, maxlength: 500, 'data-testid': 'cancel-reason' });
    const btn = h('button', { type: 'submit', class: 'btn light ord-btn', 'data-testid': 'cancel-submit', text: t.cancelSubmit });
    return h('form', { class: 'ord-form', onsubmit: async (ev) => {
      ev.preventDefault(); if (!confirm(t.cancelConfirm)) return; btn.disabled = true;
      try {
        const r = await api.requestCancel({ reason: reason.value.trim() });
        if (r?.notReady) throw new Error('cancel');
        if (r?.ok === false && r.code !== 'request_exists') { flash(false, failText(r)); btn.disabled = false; return; }
        const fresh = await api.get(); if (!fresh?.ok) throw new Error('get'); draw(fresh); flash(true, r?.ok === false ? t['cancel.open'] : t.cancelDone);
      } catch { flash(false, t.error); btn.disabled = false; }
    } }, h('p', { class: 'bk-note', text: t.cancelLead }), h('div', { class: 'bk-field' }, h('label', { for: 'ord-reason', text: t.cancelReason }), reason), btn);
  }
}
main();
