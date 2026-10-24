// Hiljaisten aikojen ale (booking_162) kokeilutilassa: ?mock=1&quiet=1. Tarjoukset johdetaan mockin omasta saatavuudesta
// (yksityisvuorot, mode 'exclusive', vapaa): ≤ 36 h → 30 %, ≤ 72 h → 20 % (sama porrastus kuin tuotannon oletussäännöissä).
// Ilman quiet=1 mock vastaa kuten tuotanto pois päältä: tyhjä lista. Ei oikeita asiakastietoja.
import { discountPrice, roundMoney } from './quiet-offers-logic.js';

export const MOCK_TIERS = [{ hours: 36, percent: 30 }, { hours: 72, percent: 20 }];
export function mockQuietOffers(rows, nowMs = Date.now()) {
  const out = [];
  for (const r of rows || []) {
    if (r.status !== 'available' || r.mode !== 'exclusive' || r.price_mode === 'per_person') continue;
    const start = Date.parse(r.starts_at), hours = (start - nowMs) / 3600000;
    if (!(hours > 0)) continue;
    const tier = MOCK_TIERS.find((x) => hours <= x.hours);
    if (!tier) continue;
    const base = +r.base_price;
    out.push({ product_id: +r.product_id, rule_id: +r.rule_id, session_date: r.session_date || new Date(start).toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' }),
      starts_at: r.starts_at, ends_at: r.ends_at, label: r.label, label_en: r.label_en ?? null, percent: tier.percent, base_price: base,
      discount_amount: roundMoney(base - discountPrice(base, tier.percent)), discounted_price: discountPrice(base, tier.percent), price_mode: r.price_mode,
      included_persons: r.included_persons ?? null, extra_person_price: r.extra_person_price ?? null,
      next_change_at: tier.percent === 30 ? null : new Date(start - 36 * 3600000).toISOString() });
  }
  return out;
}
