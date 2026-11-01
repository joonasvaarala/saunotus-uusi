// Hallinnan pikahaku: nykyiset staff-RPC:t, ei erillistä indeksiä eikä ulkoisia riippuvuuksia.
import { h } from './ui.js';
import { normalizeGiftCode, createGiftApi } from './giftcards-api.js';
import { createTalousApi, wantsMock } from './talous-api.js';
import { navText } from './nav-texts.js';

export const cleanSearch = (value) => String(value || '').trim().replace(/^#(?=\d)/, '');
// Lahjakorttikoodi (esim. ABCD-1234-EFGH) normalisoidaan; nimihaku (välilyönnit, ääkköset) lähtee sellaisenaan.
export const giftSearchTerm = (q) => (/^[A-Za-z0-9 -]+$/.test(q) && /\d/.test(q) ? normalizeGiftCode(q) : q);
export function resultHref(kind, row) {
  if (kind === 'order') return `#/tilaukset?order=${encodeURIComponent(row.order_no)}`;
  if (kind === 'reservation') return `#/varaukset?id=${encodeURIComponent(row.reservation_id)}&q=${encodeURIComponent(row.order_no)}&period=all`;
  if (kind === 'customer') return `#/asiakkaat?id=${encodeURIComponent(row.id)}`;
  if (kind === 'giftcard') return `#/lahjakortit?tab=omat&code=${encodeURIComponent(row.code)}`;
  return '#/';
}

export async function findQuickResults(rpc, ctx, text) {
  const q = cleanSearch(text);
  if (q.length < 2) return [];
  const tasks = [
    ['customer', () => rpc('admin_list_customers', { p_search: q, p_limit: 6, p_offset: 0 })],
    ['reservation', () => rpc('admin_list_reservations', { p_search: q, p_limit: 8, p_offset: 0 })],
  ];
  if (ctx.can('payments.manage')) tasks.push(['order', () => wantsMock()
    ? createTalousApi({ rpc }).listOrders({ search: q, paymentFilter: 'all', sortBy: 'created', sortDir: 'desc', limit: 8, offset: 0 })
    : rpc('admin_list_orders', { p_search: q, p_payment_filter: 'all', p_limit: 8, p_offset: 0 })]);
  if (ctx.can('giftcards.manage')) tasks.push(['giftcard', () => wantsMock()
    ? createGiftApi({ rpc }).list({ search: giftSearchTerm(q), limit: 6, offset: 0 })
    : rpc('admin_list_gift_cards', { p_search: giftSearchTerm(q), p_limit: 6, p_offset: 0 })]);
  const settled = await Promise.allSettled(tasks.map(([, run]) => run()));
  const results = [];
  for (let i = 0; i < tasks.length; i++) {
    if (settled[i].status !== 'fulfilled') continue; // puuttuva RPC ei estä muiden kohteiden hakua
    const kind = tasks[i][0], raw = settled[i].value;
    const rows = Array.isArray(raw) ? raw : Array.isArray(raw?.rows) ? raw.rows : [];
    for (const row of rows) {
      const prefix = navText(`ui.admin.nav.kind_${kind}`);
      const label = kind === 'customer' ? `${row.name || prefix} · ${row.email || row.phone || ''}`
        : kind === 'reservation' ? `${row.customer_name || prefix} · #${row.order_no} · ${row.product_name || ''}`
        : kind === 'order' ? `#${row.order_no} · ${row.customer_name || prefix}`
        : `${row.code || prefix} · ${row.customer_name || row.recipient_name || ''}`;
      if (resultHref(kind, row) !== '#/') results.push({ href: resultHref(kind, row), label: `${prefix}: ${label}` });
    }
  }
  return results.slice(0, 24);
}

// Napautuksen kohde on usein ikoni (svg/span) eikä itse button. Juuri kattaa molemmat ja hakukentän.
export function isQuickSearchInside(target, root) {
  const el = target?.nodeType === 1 ? target : target?.parentElement;
  return !!(el && root && (el === root || root.contains?.(el)));
}
export function setupQuickSearch({ input, panel, toggle, box, ctx, rpc }) {
  let timer, seq = 0;
  const root = toggle.closest?.('.quick-search') || toggle.parentElement;
  const clear = () => { panel.hidden = true; panel.replaceChildren(); };
  const close = () => { clear(); box.classList.remove('mobile-open'); toggle.setAttribute('aria-expanded', 'false'); };
  const open = () => { box.classList.add('mobile-open'); toggle.setAttribute('aria-expanded', 'true'); input.focus({ preventScroll: true }); };
  toggle.addEventListener('click', () => box.classList.contains('mobile-open') ? close() : open());
  input.addEventListener('input', () => {
    clearTimeout(timer);
    const value = input.value, my = ++seq;
    if (cleanSearch(value).length < 2) { clear(); return; }
    timer = setTimeout(async () => {
      panel.hidden = false;
      panel.replaceChildren(h('p', { class: 'muted', role: 'status', text: navText('ui.admin.nav.searching') }));
      const found = await findQuickResults(rpc, ctx, value);
      if (my !== seq) return;
      panel.replaceChildren(...(found.length ? found.map((x) => h('a', { href: x.href, class: 'quick-result', onclick: () => close() }, x.label))
        : [h('p', { class: 'muted', role: 'status', text: navText('ui.admin.nav.no_results') })]));
    }, 240);
  });
  input.addEventListener('keydown', (ev) => {
    if (ev.key === 'Escape') { close(); toggle.focus(); }
    if (ev.key === 'Enter') { const first = panel.querySelector('a[href]'); if (first) { ev.preventDefault(); first.click(); } }
  });
  document.addEventListener('click', (ev) => { if (!isQuickSearchInside(ev.target, root)) close(); });
  return { close, open };
}
