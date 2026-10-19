// ?mock=1: ei verkkokutsuja. Hinta tulee mock-katalogista, ei pyynnön rungosta.
// Yksi QR-koodi vastaa yhtä tuotetta. Ilman koodia tai vieraalla koodilla listaa ei palauteta.
export const DRINKS_QR = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

const BY_CODE = {
  [DRINKS_QR]: { product_id: 201, name: 'Vichy', name_en: 'Vichy', price: 3, label: 'Pukuhuoneen jääkaappi' },
};

const PATHS = { fi: '/juomat/', en: '/en/drinks/' };

export function createDrinksMock() {
  const orders = new Map();
  let seq = 8000;
  return {
    async rpc(name, args = {}) {
      if (name === 'public_drinks_catalog') {
        const code = args.p_device || '';
        const row = BY_CODE[code];
        if (!row) return { ok: true, device: { unknown: true }, products: [], paths: PATHS };
        if (code === 'pois') return { ok: true, device: { active: false }, products: [], paths: PATHS };
        return { ok: true, device: { label: row.label, active: true }, products: [{ product_id: row.product_id, name: row.name, name_en: row.name_en, price: row.price }], paths: PATHS };
      }
      if (name === 'public_drinks_checkout') {
        const row = BY_CODE[args.p_device];
        if (!row || args.p_device === 'pois') return { ok: false, code: 'unknown_device' };
        const items = args.p_items || [];
        if (items.some((r) => r.price != null || r.unit_price != null || r.vat_rate != null)) return { ok: false, code: 'price_locked' };
        if (items.some((r) => r.product_id !== row.product_id)) return { ok: false, code: 'not_counter_product' };
        let total = 0;
        const lines = [];
        for (const r of items) {
          const line = Math.round(row.price * r.quantity * 100) / 100;
          total += line;
          lines.push({ product_id: row.product_id, name: row.name, quantity: r.quantity, unit_price: row.price, line_total: line });
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
