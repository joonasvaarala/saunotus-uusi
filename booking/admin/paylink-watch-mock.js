// Kokeilutilan seurattavat maksut. Keksittyä dataa, ei verkkokutsua.
const H = 3600000;
const HANDLED_METHODS = new Set(['cash', 'gift_card', 'partner_voucher', 'pay_later', 'annual_card']);

export function seedPaylinkWatch(now = new Date()) {
  const iso = (hours) => new Date(now.getTime() + hours * H).toISOString();
  return [
    {
      payment_id: 9101, order_id: 8101, order_no: 15321, amount: 98.5, customer_name: 'Aino Asiakas',
      created_at: iso(-5 * 24), link_expires_at: iso(2 * 24), link_kind: 'prepaid', status: 'watching', needs_action: false,
      next_reminder_at: iso(20), paused_at: null,
      reservation: { product_name: 'Yleinen vuoro', starts_at: iso(9 * 24), count: 1 },
      reminders: [{ no: 1, at: iso(-2 * 24), kind: 'prepaid_unpaid' }],
      reminder_count: 1, last_reminder_at: iso(-2 * 24),
    },
    {
      payment_id: 9102, order_id: 8102, order_no: 15344, amount: 64, customer_name: 'Mikko Mäkinen',
      created_at: iso(-13 * 24), link_expires_at: null, link_kind: 'onsite', status: 'needs_action', needs_action: true,
      next_reminder_at: null, paused_at: null,
      reservation: { product_name: 'Yksityinen vuoro', starts_at: iso(-24), count: 1 },
      reminders: [1, 2, 3, 4].map((no) => ({ no, at: iso((-13 + no * 3) * 24), kind: 'onsite' })),
      reminder_count: 4, last_reminder_at: iso(-24),
    },
    {
      payment_id: 9103, order_id: 8103, order_no: 15350, amount: 42, customer_name: 'Sara Berg',
      created_at: iso(-4 * 24), link_expires_at: null, link_kind: 'onsite', status: 'paused', needs_action: false,
      next_reminder_at: null, paused_at: iso(-5),
      reservation: { product_name: 'Hieronta 60 min', starts_at: iso(3 * 24), count: 1 },
      reminders: [{ no: 1, at: iso(-24), kind: 'onsite' }],
      reminder_count: 1, last_reminder_at: iso(-24),
    },
  ];
}

function sync(row) {
  row.reminder_count = row.reminders.length;
  row.last_reminder_at = row.reminders.length ? row.reminders[row.reminders.length - 1].at : null;
  row.needs_action = row.status === 'needs_action';
}

export function paylinkWatchHandlers({ st, need, err, now = new Date() }) {
  const rows = () => {
    if (!st.paylinks) st.paylinks = seedPaylinkWatch(now);
    return st.paylinks;
  };
  const find = (id) => rows().find((r) => r.payment_id === id);
  return {
    admin_list_payment_link_watch: (a) => {
      need('payments.manage');
      const q = String(a.p_search || '').trim().toLowerCase();
      const status = a.p_status || null;
      let list = rows().filter((r) => !status || r.status === status);
      if (q) list = list.filter((r) => String(r.order_no).includes(q) || String(r.payment_id).includes(q) || String(r.customer_name).toLowerCase().includes(q));
      const offset = Math.max(0, Number(a.p_offset) || 0);
      const limit = Math.min(200, Math.max(1, Number(a.p_limit) || 50));
      return { total: list.length, rows: list.slice(offset, offset + limit) };
    },
    admin_payment_link_remind_now: (a) => {
      need('payments.manage');
      const row = find(a.p_payment_id);
      if (!row) throw err('link_closed', 'Maksulinkki ei ole enää avoinna');
      const no = row.reminders.length + 1;
      const at = new Date(now.getTime()).toISOString();
      row.reminders = [...row.reminders, { no, at, kind: row.link_kind === 'prepaid' ? 'prepaid_before_expiry' : 'manual' }];
      if (row.link_kind === 'onsite' && row.reminders.filter((x) => x.kind === 'onsite').length >= 4) row.status = 'needs_action';
      if (row.status === 'watching') row.next_reminder_at = new Date(now.getTime() + 72 * H).toISOString();
      sync(row);
      return { ok: true, queued: true, reminder_no: no };
    },
    admin_payment_link_pause_reminders: (a) => {
      need('payments.manage');
      const row = find(a.p_payment_id);
      if (!row) throw err('link_closed', 'Maksulinkki ei ole enää avoinna');
      if (row.status !== 'needs_action') row.status = 'paused';
      row.paused_at = row.paused_at || new Date().toISOString();
      row.next_reminder_at = null;
      sync(row);
      return { ok: true, paused_at: row.paused_at };
    },
    admin_payment_link_mark_handled: (a) => {
      need('payments.manage');
      if (!a.p_method || HANDLED_METHODS.has(a.p_method)) throw err('invalid_payment_method', 'Valitse maksutapa');
      const i = rows().findIndex((r) => r.payment_id === a.p_payment_id);
      if (i < 0) throw err('link_closed', 'Maksulinkki ei ole enää avoinna');
      rows().splice(i, 1);
      return { ok: true, handled: true, receipt_no: '2026-000901', payment_id: 9901 };
    },
  };
}
