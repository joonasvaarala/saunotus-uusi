// Lunastuspyyntö-mock (hallinta): deterministinen, vain keksittyä dataa (ei oikeita koodeja). Vastaa §13.12:n admin-RPC:itä samoilla nimillä, p_-parametreilla ja vastausrakenteilla,
// joten vouchers-api.js ajaa sekä mockia että oikeaa palvelinta samalla koodilla. Puhdas moduuli (ei DOM:ia) → node --test voi ajaa sen.
const round2 = (n) => Math.round((+n + Number.EPSILON) * 100) / 100;
const LABEL = { elamyslahjat: 'Elämyslahjat', kokemuskauppa: 'Kokemuskauppa', kiitoskauppa: 'Kiitoskauppa', offerilla: 'Offerilla', partner_other: 'Muu kumppani' };
const ACTIVE = ['open', 'processing', 'problem'];
const norm = (s) => String(s ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
const mask = (c) => `…${String(c).slice(-4)}`;
export function guess(n) {
  return /^KK[0-9]{5}[A-Z]{6}$/.test(n) ? { source: 'kokemuskauppa', confidence: 'high' } : /^OK[0-9]{5}[A-Z]{3}$/.test(n) ? { source: 'offerilla', confidence: 'high' }
    : /^[A-Z0-9]{12}$/.test(n) && /[^3479ACEFHJKLMNPRTUVWXY]/.test(n) ? { source: 'elamyslahjat', confidence: 'medium' } : { source: null, confidence: null };
}
export function createVoucherMock({ now = new Date(), delay = 0, remindHours = 24, orderUnpaid = 62 } = {}) {
  const ago = (h) => new Date(now.getTime() - h * 3600000).toISOString();
  const seed = [
    { source: 'elamyslahjat', code: 'ZXQW98765432', status: 'open', cust: ['Aino Virtanen', 'aino@example.invalid', '+358 40 000 0001'], age: 5, order_no: 15401 },
    { source: 'kokemuskauppa', code: 'KK12345ABCDEF', status: 'open', cust: ['Eero Korhonen', 'eero@example.invalid', '+358 40 000 0002'], age: 75, order_no: 15388 },
    { source: 'offerilla', code: 'OK19123ABC', status: 'processing', cust: ['Helmi Laine', 'helmi@example.invalid', null], age: 1.5, order_no: 15402 },
    { source: 'elamyslahjat', code: 'QQWW11112222', status: 'problem', problem_code: 'invalid_code', cust: ['Ilmari Salo', 'ilmari@example.invalid', '+358 40 000 0004'], age: 52, order_no: 15390, notes: '2026-10-16 12:00 bot: ongelma invalid_code' },
    { source: 'kiitoskauppa', code: 'KIITOS2026ABC', status: 'problem', problem_code: 'already_used', cust: ['Kaisa Heikkinen', 'kaisa@example.invalid', null], age: 30, order_no: 15395, needs_review: true },
    { source: 'offerilla', code: 'OK19456DEF', status: 'redeemed', amount: 40, voucher_value: 40, partner_ref: 'OK-884412', cust: ['Lauri Mäkelä', 'lauri@example.invalid', '+358 40 000 0006'], age: 100, order_no: 15380, payment_id: 9101 },
    { source: 'kiitoskauppa', code: 'KIITOS2026XYZ', status: 'cancelled', cust: ['Maija Nieminen', 'maija@example.invalid', null], age: 200, order_no: 15370 },
    { source: 'elamyslahjat', code: 'ASDF67890123', status: 'redeemed', amount: 0, voucher_value: null, cust: ['Niko Ojala', 'niko@example.invalid', null], age: 120, order_no: 15377, needs_review: true, notes: 'tilauksella ei ollut maksettavaa: kumppanilahjakortti lunastettu ilman maksukirjausta' },
  ];
  const claims = seed.map((s, i) => ({ id: 41 + i, order_id: 7000 + i, order_no: s.order_no, reservation_id: 8000 + i, order_item_id: null, source: s.source, source_suggested: guess(s.code).source, code: s.code, status: s.status, problem_code: s.problem_code ?? null,
    customer_name: s.cust[0], customer_email: s.cust[1], customer_phone: s.cust[2], locale: 'fi', voucher_value: s.voucher_value ?? null, amount: s.amount ?? null, payment_id: s.payment_id ?? null, partner_ref: s.partner_ref ?? null,
    attempts: s.status === 'processing' ? 1 : s.status === 'problem' ? 2 : 0, last_checked_at: s.status === 'open' ? null : ago(Math.max(0, s.age - 1)), problem_notified_at: null, needs_review: !!s.needs_review, notes: s.notes ?? null,
    resolved_at: ['redeemed', 'problem', 'cancelled'].includes(s.status) ? ago(Math.max(0, s.age - 2)) : null, resolved_by: s.status === 'redeemed' ? 'bot' : s.status === 'problem' ? 'bot' : s.status === 'cancelled' ? 'customer' : null,
    created_at: ago(s.age), updated_at: ago(Math.max(0, s.age - 1)) }));
  const err = (code, message) => Object.assign(new Error(message || code), { code, status: 400 });
  const json = (c, full = false) => ({ id: c.id, order_id: c.order_id, order_no: c.order_no, reservation_id: c.reservation_id, order_item_id: c.order_item_id, source: c.source, source_label: LABEL[c.source], source_suggested: c.source_suggested,
    code_masked: mask(c.code), code: full ? c.code : null, status: c.status, problem_code: c.problem_code, customer_name: c.customer_name, customer_email: c.customer_email, customer_phone: c.customer_phone, locale: c.locale,
    hold_until: null, hours_left: null, voucher_value: c.voucher_value, amount: c.amount, payment_id: c.payment_id, partner_ref: c.partner_ref, attempts: c.attempts, last_checked_at: c.last_checked_at,
    problem_notified_at: c.problem_notified_at, needs_review: c.needs_review, notes: c.notes, resolved_at: c.resolved_at, resolved_by: c.resolved_by, created_at: c.created_at, updated_at: c.updated_at,
    age_hours: round2((now.getTime() - new Date(c.created_at).getTime()) / 3600000), stale: ACTIVE.includes(c.status) && (now.getTime() - new Date(c.created_at).getTime()) / 3600000 >= remindHours, active: ACTIVE.includes(c.status), status_since: c.resolved_at || c.created_at,
    booking_product: 'Yleinen saunavuoro', booking_starts_at: new Date(now.getTime() + 3 * 86400000).toISOString(), booking_reservation_id: c.reservation_id, value_card: false });
  const find = (id) => { const c = claims.find((x) => x.id === +id); if (!c) throw err('not_found', 'Lunastuspyyntöä ei löydy'); return c; };
  const handlers = {
    admin_list_voucher_claims: (a = {}) => {
      const st = a.p_status ?? null, sort = a.p_sort || 'oldest_open', s = String(a.p_search || '').trim().toLowerCase(), n = norm(s);
      if (st && !['open', 'processing', 'redeemed', 'problem', 'cancelled', 'expired', 'active', 'needs_review'].includes(st)) throw err('invalid_status', 'Tuntematon tila');
      if (!['oldest_open', 'newest'].includes(sort)) throw err('invalid_sort', 'Järjestys: oldest_open tai newest');
      let rows = claims.filter((c) => (!st || (st === 'active' ? ACTIVE.includes(c.status) : st === 'needs_review' ? c.needs_review : c.status === st))
        && (!s || [c.customer_name, c.customer_email].some((v) => v && v.toLowerCase().includes(s)) || String(c.order_no) === s || String(c.id) === s || (n.length >= 4 && norm(c.code).includes(n))));
      const act = (c) => (ACTIVE.includes(c.status) ? 1 : 0), t = (c) => new Date(c.created_at).getTime();
      rows = rows.sort((x, y) => act(y) - act(x) || (sort === 'oldest_open' && act(x) ? t(x) - t(y) : t(y) - t(x)) || y.id - x.id);
      const total = rows.length, off = Math.max(0, +a.p_offset || 0), lm = Math.min(500, Math.max(1, +a.p_limit || 100));
      return { ok: true, total, sort, claims: rows.slice(off, off + lm).map((c) => json(c)) };
    },
    admin_get_voucher_claim: ({ p_id }) => {
      const c = find(p_id);
      return { ok: true, claim: json(c, true), order: { order_no: c.order_no, status: 'confirmed', payment_status: c.status === 'redeemed' && c.amount > 0 ? 'paid' : 'unpaid', total: 82, balance: { total: 82, net_paid: 20, unpaid: c.status === 'redeemed' && c.amount > 0 ? 82 - 20 - c.amount : orderUnpaid } },
        reservations: [{ id: c.reservation_id, starts_at: new Date(now.getTime() + 3 * 86400000).toISOString(), ends_at: new Date(now.getTime() + 3 * 86400000 + 5400000).toISOString(), persons: 2, status: 'confirmed', hold_expires_at: null, product_name: 'Yleinen saunavuoro' }],
        payment: c.payment_id ? { id: c.payment_id, method: ['kokemuskauppa', 'offerilla', 'elamyslahjat'].includes(c.source) ? `partner_voucher_${c.source}` : 'partner_voucher', status: 'paid', amount: c.amount, paid_at: c.resolved_at, note: `Kumppanin lahjakortti (${LABEL[c.source]}) ${mask(c.code)} | pyyntö #${c.id}` } : null,
        source_guess: guess(c.code), sources: Object.keys(LABEL).filter((k) => k !== 'partner_other').map((code) => ({ code, label: LABEL[code], label_en: LABEL[code] })) };
    },
    admin_resolve_voucher_claim: ({ p_id, p_status, p_problem_code = null, p_note = null, p_amount = null, p_partner_ref = null }) => {
      if (!['redeemed', 'problem', 'cancelled', 'open'].includes(p_status)) throw err('invalid_status', 'Tila ei kelpaa (redeemed, problem, cancelled, open)');
      if (p_status === 'problem' && !['invalid_code', 'expired_code', 'already_used', 'other'].includes(p_problem_code || '')) throw err('invalid_problem_code', 'problem_code: invalid_code, expired_code, already_used tai other');
      if (p_note != null && String(p_note).length > 1000) throw err('invalid_note', 'Muistiinpano enintään 1000 merkkiä');
      const c = find(p_id);
      if (!ACTIVE.includes(c.status)) throw err('invalid_state', `Pyyntöä ei voi enää muuttaa (tila ${c.status})`);
      if (p_amount != null && (+p_amount < 0 || +p_amount !== round2(p_amount))) throw err('invalid_amount', 'Virheellinen summa');
      const note = String(p_note ?? '').trim() || null, stamp = 'staff';
      let pay = null;
      if (p_status === 'redeemed') {
        const amt = round2(Math.min(p_amount == null ? orderUnpaid : +p_amount, orderUnpaid));
        pay = { payment_id: amt > 0 ? 9200 + c.id : null, amount: amt > 0 ? amt : 0 };
        Object.assign(c, { status: 'redeemed', problem_code: null, voucher_value: p_amount == null ? c.voucher_value : +p_amount, amount: pay.amount, payment_id: pay.payment_id, partner_ref: String(p_partner_ref ?? '').trim() || c.partner_ref, needs_review: !pay.payment_id });
      } else if (p_status === 'problem') Object.assign(c, { status: 'problem', problem_code: p_problem_code, problem_notified_at: null });
      else if (p_status === 'cancelled') Object.assign(c, { status: 'cancelled' });
      else Object.assign(c, { status: 'open', problem_code: null, problem_notified_at: null, resolved_at: null, resolved_by: null });
      if (p_status !== 'open') Object.assign(c, { resolved_at: now.toISOString(), resolved_by: stamp });
      c.notes = [c.notes, `${stamp}: ${p_status}${note ? ` – ${note}` : ''}`].filter(Boolean).join('\n'); c.updated_at = now.toISOString();
      return { ok: true, claim: json(c), payment_id: c.payment_id, amount: c.amount, problem_email_queued: false, balance: p_status === 'redeemed' ? { total: 82, net_paid: 20 + (pay?.amount || 0), unpaid: Math.max(0, orderUnpaid - (pay?.amount || 0)) } : null };
    },
    admin_voucher_claim_summary: () => {
      const act = claims.filter((c) => ACTIVE.includes(c.status)).sort((x, y) => new Date(x.created_at) - new Date(y.created_at)), o = act[0], j = o && json(o);
      return { ok: true, remind_after_hours: remindHours, active: act.length, open: act.filter((c) => c.status !== 'problem').length, problem: act.filter((c) => c.status === 'problem').length, needs_review: claims.filter((c) => c.needs_review).length,
        stale: act.filter((c) => json(c).stale).length, oldest: o ? { id: o.id, order_no: o.order_no, status: o.status, source_label: LABEL[o.source], code_masked: mask(o.code), created_at: o.created_at, age_hours: j.age_hours } : null };
    },
  };
  const rpc = async (name, args = {}) => {
    if (delay) await new Promise((r) => setTimeout(r, delay));
    const f = handlers[name]; if (!f) throw Object.assign(new Error(`Could not find the function booking.${name}`), { status: 404, code: 'PGRST202' });
    return f(args);
  };
  return { rpc, supported: Object.keys(handlers), state: { claims } };
}
