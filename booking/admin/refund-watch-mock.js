// Kokeilutilan avoimet hyvitykset. Keksittyä dataa, ei verkkokutsua.
const H = 3600000;

export function seedOpenRefunds(now = new Date()) {
  const iso = (hours) => new Date(now.getTime() + hours * H).toISOString();
  return [
    {
      refund_id: 60, payment_id: 501, order_id: 16194, order_no: 16194, customer_name: 'Aino Asiakas',
      amount: 29, reason: 'Peruttu vuoro', status: 'failed', provider: 'montonio',
      provider_refund_id: null, provider_status: 'failed', method: 'montonio',
      paid_at: iso(-72), created_at: iso(-50), updated_at: iso(-48),
      age_hours: 48, aging: false, needs_action: true, can_retry: true,
    },
    {
      refund_id: 61, payment_id: 502, order_id: 16201, order_no: 16201, customer_name: 'Mikko Mäkinen',
      amount: 58, reason: 'Odottaa välittäjää', status: 'processing', provider: 'montonio',
      provider_refund_id: 'rf-pending', provider_status: 'PENDING', method: 'montonio',
      paid_at: iso(-30), created_at: iso(-26), updated_at: iso(-26),
      age_hours: 26, aging: true, needs_action: true, can_retry: true,
    },
    {
      refund_id: 62, payment_id: 503, order_id: 16210, order_no: 16210, customer_name: 'Sara Berg',
      amount: 18, reason: 'Juuri jonossa', status: 'requested', provider: 'manual',
      provider_refund_id: null, provider_status: null, method: 'card_terminal',
      paid_at: iso(-2), created_at: iso(-1), updated_at: iso(-1),
      age_hours: 1, aging: false, needs_action: false, can_retry: false,
    },
  ];
}

export function refundWatchHandlers({ st, err, role = 'manager', now = new Date() }) {
  const rows = () => {
    if (!st.openRefunds) st.openRefunds = seedOpenRefunds(now);
    return st.openRefunds;
  };
  const find = (id) => rows().find((r) => r.refund_id === id);
  const gate = () => { if (!(st.perms.includes('bookings.manage') || role === 'admin')) throw err('forbidden', 'Ei oikeutta tähän toimintoon (bookings.manage tai admin)'); };
  return {
    admin_list_open_refunds: (a) => {
      gate();
      const q = String(a.p_search || '').trim().toLowerCase();
      const list = rows().filter((r) => ['requested', 'processing', 'failed'].includes(r.status))
        .filter((r) => !q || String(r.order_no).includes(q) || String(r.customer_name).toLowerCase().includes(q) || String(r.provider_refund_id || '').toLowerCase().includes(q));
      return { rows: list, total: list.length, aging_count: list.filter((r) => r.aging).length };
    },
    admin_retry_provider_refund: (a) => {
      gate();
      const row = find(a.p_refund_id);
      if (!row) throw err('not_found', 'Hyvitystä ei löydy');
      if (!row.can_retry) throw err('provider_no_retry', 'Tätä hyvitystä ei voi lähettää automaattisesti. Kirjaa se käsin.');
      row.status = 'requested';
      row.provider_status = 'retry';
      row.aging = false;
      row.needs_action = false;
      row.age_hours = 0;
      return { ok: true, refund_id: row.refund_id, status: 'requested', provider: row.provider, amount: row.amount };
    },
    admin_record_manual_refund: (a) => {
      gate();
      const row = find(a.p_refund_id);
      if (!row) throw err('not_found', 'Hyvitystä ei löydy');
      if (!(Number(a.p_amount) > 0) || Number(a.p_amount) > row.amount + 0.001) throw err('amount_exceeds_refundable', 'Summa ylittää avoimen hyvityksen');
      if (!a.p_refunded_on) throw err('invalid_param', 'Hyvityspäivä puuttuu');
      if (!String(a.p_provider_ref || '').trim()) throw err('invalid_param', 'Anna välittäjän viite');
      if (String(a.p_note || '').trim().length < 3) throw err('invalid_param', 'Anna huomautus');
      row.status = 'done';
      row.provider_status = 'manual_done';
      row.provider_refund_id = String(a.p_provider_ref).trim();
      row.amount = Number(a.p_amount);
      row.needs_action = false;
      row.aging = false;
      return { ok: true, refund_id: row.refund_id, status: 'done', amount: row.amount, receipt_no: 'H-2026-000001', provider_ref: row.provider_refund_id };
    },
  };
}
