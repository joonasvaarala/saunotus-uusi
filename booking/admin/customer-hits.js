// booking_172: asiakashaun osumat (Uusi varaus / Asiakkaat): rekisterin asiakkaat + aiempien tilausten yritykset (source 'orders').
// Puhdas moduuli (ei DOMia eikä Supabase-asiakasta) → node --test (tests/yritysasiakashaku.test.mjs). rpcFn annetaan kutsujalta.
import { nbt } from './nb-texts.js';

export const isOrderCompany = (c) => c?.source === 'orders';
export async function searchCustomers(term, rpcFn) {
  try {
    const rows = await rpcFn('admin_search_customers', { p_search: term, p_limit: 8 });
    if (Array.isArray(rows)) return rows;
  } catch { /* booking_172 ei vielä ajettu tai haku epäonnistui → vanha haku */ }
  return rpcFn('admin_list_customers', { p_search: term, p_limit: 5, p_offset: 0 }).catch(() => []);
}
export function customerHitTitle(c) {
  return c.customer_kind === 'company' && c.company ? (c.name ? `${c.company} (${c.name})` : c.company) : (c.name || c.company || '');
}
export function customerHitMeta(c) {
  if (isOrderCompany(c)) return [c.business_id, c.email, nbt('cu.fromOrders')].filter(Boolean).join(' · ');
  return [c.customer_kind === 'company' ? c.business_id : null, c.email, c.phone].filter(Boolean).join(' · ');
}
