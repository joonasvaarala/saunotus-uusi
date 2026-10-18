// ?mock=1: ei verkkokutsuja. Hinta tulee mock-katalogista, ei pyynnön rungosta.
const PRODUCTS = [
  { product_id: 201, name: 'Vichy', name_en: 'Vichy', price: 3, vat_rate: 13.5 },
  { product_id: 202, name: 'Lähdevesi', name_en: 'Spring water', price: 2.5, vat_rate: 13.5 },
];

export function createDrinksMock() {
  const orders = new Map();
  let seq = 8000;
  return {
    async rpc(name, args = {}) {
      if (name === 'public_drinks_catalog') {
        const device = args.p_device
          ? { code: args.p_device, name: 'Pukuhuone, jääkaappi 1', location: 'Pukuhuone', active: args.p_device !== 'pois' }
          : null;
        return { ok: true, device, products: PRODUCTS.slice(), paths: { fi: '/juomat/', en: '/en/drinks/' } };
      }
      if (name === 'public_drinks_checkout') {
        if (!args.p_device || args.p_device === 'pois') return { ok: false, code: 'unknown_device' };
        const items = args.p_items || [];
        if (items.some((r) => r.price != null || r.unit_price != null || r.vat_rate != null)) return { ok: false, code: 'price_locked' };
        let total = 0;
        const lines = [];
        for (const r of items) {
          const p = PRODUCTS.find((x) => x.product_id === r.product_id);
          if (!p) return { ok: false, code: 'not_counter_product' };
          const line = Math.round(p.price * r.quantity * 100) / 100;
          total += line;
          lines.push({ product_id: p.product_id, name: p.name, quantity: r.quantity, unit_price: p.price, vat_rate: p.vat_rate, line_total: line });
        }
        const id = ++seq;
        const token = `00000000-0000-4000-8000-${String(id).padStart(12, '0')}`;
        orders.set(token, { order_no: id, status: 'pending', payment_status: 'unpaid', total, sale_ref: args.p_device, lines, polls: 0 });
        return { ok: true, order_id: id, order_no: id, public_token: token, total, lines, source_channel: 'kylmalaite', sale_ref: args.p_device };
      }
      if (name === 'public_drinks_status') {
        const o = orders.get(args.p_token);
        if (!o) return { ok: false, code: 'not_found' };
        o.polls += 1;
        if (o.polls >= 2 && o.arm) { o.payment_status = 'paid'; o.status = 'confirmed'; }
        return { ok: true, ...o };
      }
      return { ok: false, code: 'mock_unsupported' };
    },
    arm(token) {
      const o = orders.get(token);
      if (o) o.arm = true;
    },
  };
}
