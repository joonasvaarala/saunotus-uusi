// Talous-näkymien MOCK-PALVELIN: deterministinen (siemennetty satunnaisgeneraattori) ~12 000 tilausta ja niiden maksut, jotta palvelinpuolinen sivutus,
// haku, lajittelu ja raportit voidaan kehittää ja testata ilman tuotantokantaa. Sisältää vain keksittyä dataa.
// createMock().rpc(nimi, parametrit) vastaa KOODARI_talous_A_D_fi.md -sopimuksen RPC:itä (nimet, p_-parametrit, palautusrakenteet) → talous-api.js käyttää
// samaa rpcBackend-koodia oikean PostgREST-kutsun ja mockin kanssa; vaihto = yksi `rpc`-funktio.
// Puhdas moduuli (ei DOM:ia) → node --test voi ajaa sen.
const rng = (seed) => { let a = seed >>> 0; return () => { a = (a + 0x6D2B79F5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; };
const pick = (r, arr) => arr[Math.floor(r() * arr.length)];
const weighted = (r, pairs) => { let x = r() * pairs.reduce((s, p) => s + p[1], 0); for (const [v, w] of pairs) { x -= w; if (x < 0) return v; } return pairs[0][0]; };
const pad = (n, w = 2) => String(n).padStart(w, '0');
const dayAdd = (ds, n) => { const d = new Date(`${ds}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const round2 = (n) => Math.round(n * 100) / 100;
const FIRST = ['Aino', 'Eero', 'Helmi', 'Ilmari', 'Kaisa', 'Lauri', 'Maija', 'Niko', 'Olli', 'Pirjo', 'Sanni', 'Tuomas', 'Venla', 'Elina', 'Jussi', 'Katja', 'Mikko', 'Noora', 'Risto', 'Sofia'];
const LAST = ['Aaltonen', 'Heikkinen', 'Jokinen', 'Korhonen', 'Lahtinen', 'Mäkelä', 'Nieminen', 'Ojala', 'Rantanen', 'Salo', 'Tuominen', 'Virtanen', 'Hakala', 'Koskinen', 'Laine'];
// tuotekatalogi: group = raportin tuoteryhmä; per = hinta henkilöä kohti
const CATALOG = [
  { name: 'Yleinen saunavuoro', group: 'public', price: 18, vat: 25.5, per: true, w: 40, dur: 90 },
  { name: 'Tunnin saunavuoro', group: 'public', price: 22, vat: 25.5, per: true, w: 12, dur: 60 },
  { name: 'Yksityinen savusauna 2 h', group: 'private', price: 190, vat: 25.5, per: false, w: 14, dur: 120 },
  { name: 'Savusaunahoito', group: 'treatment', price: 85, vat: 25.5, per: false, w: 12, dur: 60 },
  { name: 'Rituaali 90 min', group: 'treatment', price: 64, vat: 25.5, per: true, w: 7, dur: 90 },
  { name: 'Lahjakortti 50 €', group: 'giftcard', price: 50, vat: 0, per: false, w: 4, dur: 0 },
  { name: 'Kesäjuhla (lippu)', group: 'event', price: 35, vat: 13.5, per: true, w: 3, dur: 180 },
  { name: 'Kahvi ja pulla', group: 'other', price: 6, vat: 13.5, per: false, w: 2, dur: 0 },
];
const ADDONS = [{ name: 'Saunavihta', price: 5, vat: 25.5 }, { name: 'Pyyhe', price: 5, vat: 25.5 }, { name: 'Turvenaamio ja jalkakylpy', price: 12, vat: 25.5 }];
export const GROUPS = ['public', 'private', 'treatment', 'addon', 'giftcard', 'event', 'other'];
export const METHOD_LABELS = { card_terminal: 'Korttipääte', cash: 'Käteinen', mobilepay: 'MobilePay', visma_pay: 'Verkkomaksu (Visma Pay)', bank_transfer: 'Tilisiirto', invoice: 'Lasku', gift_card: 'Lahjakortti', partner_voucher: 'Kumppanin lahjakortti' };
const METHODS = [['card_terminal', 30], ['cash', 18], ['mobilepay', 22], ['visma_pay', 16], ['bank_transfer', 4], ['invoice', 5], ['gift_card', 3], ['partner_voucher', 2]];

function vatSplit(gross, rate) { const vat = round2(gross - gross / (1 + rate / 100)); return { vat, net: round2(gross - vat) }; }
// maksun rivit: tilauksen rivit skaalattuna maksun osuudella (viimeinen rivi vastaanottaa pyöristyserotuksen → summa = maksun summa)
function linesFor(items, share, amount) {
  const out = []; let left = Math.round(amount * 100);
  items.forEach((it, i) => {
    const g = i === items.length - 1 ? left : Math.round(it.gross * 100 * share); left -= g;
    const gross = g / 100, { vat, net } = vatSplit(gross, it.vat);
    out.push({ order_item_id: it.id ?? null, description: it.name, group: it.group, quantity: it.qty, amount_gross: gross, vat_rate: it.vat, line_vat: vat, line_net: net });
  });
  return out;
}

export function createMock({ n = 12000, seed = 20261017, today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' }), delay = 0 } = {}) {
  const r = rng(seed);
  const SPAN = 640, start = dayAdd(today, -SPAN);
  const orders = [], payments = [];
  let payId = 5000, resId = 900000, rcId = 70000;
  const receiptSeq = new Map();
  const nextReceipt = (date, kind = 'receipt') => { const y = date.slice(0, 4), key = `${kind}${y}`, k = (receiptSeq.get(key) || 0) + 1; receiptSeq.set(key, k); return `${kind === 'receipt' ? 'K' : 'H'}-${y}-${pad(k, 6)}`; };
  const mkReceipt = (no, kind, at, orderId) => ({ id: rcId++, receipt_no: no, kind, issued_at: at, public_token: `00000000-0000-4000-9000-${pad(rcId, 12)}`, sent_at: null, order_id: orderId });
  const iso = (ds, mins) => `${ds}T${pad(6 + Math.floor(mins / 60) % 13)}:${pad(mins % 60)}:00Z`;   // UTC 06–19 → Helsingin päivä pysyy samana kesä- ja talviaikana
  // luontiajat nousevassa järjestyksessä → tilausnumero kasvaa ajan mukana (kuten oikeassa järjestelmässä)
  const stamps = Array.from({ length: n }, (_, i) => ({ d: Math.floor((i / n) * (SPAN + 1)), m: Math.floor(r() * 780) })).sort((a, b) => a.d - b.d || a.m - b.m);
  for (let i = 0; i < n; i++) {
    const created = dayAdd(start, stamps[i].d);
    const createdMins = stamps[i].m, createdAt = iso(created, createdMins);
    const age = Math.round((new Date(`${today}T12:00:00Z`) - new Date(`${created}T12:00:00Z`)) / 864e5);
    const nJ = Math.floor(n * 0.3);
    const source = i < nJ ? 'johku_import' : weighted(r, [['web', 56], ['admin', 18], ['phone', 12], ['walk_in', 10], ['email', 4]]);
    const items = []; const nItems = weighted(r, [[1, 62], [2, 28], [3, 10]]);
    const cat = () => weighted(r, CATALOG.map((c) => [c, c.w]));
    for (let k = 0; k < nItems; k++) {
      const c = cat(), qty = c.per ? 1 + Math.floor(r() * 5) : 1;
      const parentIdx = items.length;
      items.push({ name: c.name, group: c.group, qty, unit: c.price, gross: round2(c.price * qty), vat: c.vat, dur: c.dur });
      if (c.group === 'public' || c.group === 'private') for (const a of ADDONS) if (r() < 0.22) { const q = 1 + Math.floor(r() * qty); items.push({ name: a.name, group: 'addon', qty: q, unit: a.price, gross: round2(a.price * q), vat: a.vat, dur: 0, parent: parentIdx }); }
    }
    items.forEach((x, k) => { x.id = (100000 + i) * 100 + k; });
    const total = round2(items.reduce((s, x) => s + x.gross, 0));
    let ps = source === 'johku_import' ? weighted(r, [['paid', 94], ['refunded', 3], ['partially_refunded', 3]])
      : age < 14 ? weighted(r, [['paid', 55], ['unpaid', 24], ['pending', 8], ['partially_paid', 6], ['failed', 4], ['refunded', 2], ['partially_refunded', 1]])
        : weighted(r, [['paid', 84], ['unpaid', 4], ['pending', 1], ['partially_paid', 3], ['failed', 2], ['refunded', 3], ['partially_refunded', 3]]);
    const first = dayAdd(created, 1 + Math.floor(r() * 35));
    const resItems = items.filter((x) => x.group !== 'addon' && x.group !== 'giftcard' && x.group !== 'other');
    const reservations = resItems.map((x, k) => {
      const sh = 13 + Math.floor(r() * 7), startsAt = `${dayAdd(first, k)}T${pad(sh - 3)}:00:00Z`, endsAt = `${dayAdd(first, k)}T${pad(sh - 3 + Math.max(1, Math.round(x.dur / 60)))}:00:00Z`;
      return { id: resId++, item_id: x.id, product_name: x.name, starts_at: startsAt, ends_at: endsAt, persons: x.qty, status: ['refunded'].includes(ps) ? 'cancelled' : 'confirmed', item_total: x.gross,
        addons: items.filter((a) => a.group === 'addon' && a.parent === items.indexOf(x)).map((a) => ({ addon_id: ADDONS.findIndex((z) => z.name === a.name) + 1, name: a.name, quantity: a.qty, unit_price: a.unit, line_total: a.gross, vat_rate: a.vat })) };
    });
    const isJ = source === 'johku_import';
    const o = { order_id: 100000 + i, order_no: isJ ? 2000 + i : 15000 + (i - nJ), johku_order_no: isJ ? 7000 + i : null, is_native: !isJ, company: i % 17 === 0 ? `${pick(r, LAST)} Oy` : null, created_at: createdAt, created_date: created, customer_name: `${pick(r, FIRST)} ${pick(r, LAST)}`, source_channel: source, payment_status: ps, total_gross: total,
      first_reservation_at: reservations.length ? reservations[0].starts_at : null, reservation_count: reservations.length, items, reservations, payments: [], receipts: [], paid_amount: 0, refunded_amount: 0 };
    o.email = `${o.customer_name.toLowerCase().replace(/[^a-zäö]+/g, '.').replace(/[äö]/g, (c) => (c === 'ä' ? 'a' : 'o'))}@example.test`;
    // maksut (Johku-tuonnilla ei maksurivejä)
    if (source !== 'johku_import' && ps !== 'unpaid') {
      const splits = ps === 'partially_paid' ? [0.4 + Math.floor(r() * 4) / 10] : r() < 0.1 && total > 30 ? [0.5, 0.5] : [1];
      splits.forEach((share, k) => {
        const amount = k === splits.length - 1 && splits.length > 1 ? round2(total - round2(total * splits[0])) : round2(total * share);
        const status = ps === 'pending' ? 'pending' : ps === 'failed' ? 'failed' : 'paid';   // maksurivin tila (hyvitetyt: ks. alla)
        const day = dayAdd(created, k === 0 ? 0 : Math.min(age, 2));
        const paidAt = status === 'paid' ? iso(day, day === created ? Math.min(779, createdMins + Math.floor(r() * 60)) : Math.floor(r() * 780)) : null;
        const p = { payment_id: payId++, order_id: o.order_id, order_no: o.order_no, customer_name: o.customer_name, method: status === 'pending' && r() < 0.7 ? 'visma_pay' : weighted(r, METHODS), status, amount, refunded_amount: 0, created_at: createdAt, paid_at: paidAt,
          paid_date: status === 'paid' ? day : null, provider_ref: null, lines: linesFor(items, amount / total, amount) };
        if (p.method === 'visma_pay') p.provider_ref = `H${o.order_no}-${p.payment_id}-1`;
        if (status === 'paid') {
          p.receipt_no = nextReceipt(day); p.receipt = mkReceipt(p.receipt_no, 'receipt', paidAt, o.order_id); o.receipts.push(p.receipt);
          if (ps === 'refunded' || ps === 'partially_refunded') {
            p.refunded_amount = ps === 'refunded' ? amount : round2(amount * 0.5);
            const rd = dayAdd(day, Math.min(Math.max(0, age - 2), 1 + Math.floor(r() * 4)));
            p.refund_date = rd; p.refund_receipt_no = nextReceipt(rd, 'refund_receipt'); p.refund_receipt = mkReceipt(p.refund_receipt_no, 'refund_receipt', iso(rd, 700), o.order_id); o.receipts.push(p.refund_receipt);
            p.status = ps === 'refunded' ? 'refunded' : 'partially_refunded';
          }
          o.paid_amount = round2(o.paid_amount + amount); o.refunded_amount = round2(o.refunded_amount + p.refunded_amount);
        }
        o.payments.push(p); payments.push(p);
      });
    } else if (source === 'johku_import' && ps !== 'unpaid') { o.paid_amount = total; o.refunded_amount = ps === 'refunded' ? total : ps === 'partially_refunded' ? round2(total / 2) : 0; }
    o.unpaid_amount = ['unpaid', 'pending', 'failed', 'partially_paid'].includes(ps) ? round2(Math.max(0, total - o.paid_amount)) : 0;
    orders.push(o);
  }
  orders.reverse();   // uusin ensin (ensisijainen järjestys)
  const byId = new Map(orders.map((o) => [o.order_id, o]));
  const payById = new Map(payments.map((p) => [p.payment_id, p]));
  // kuitit: viittaus maksuun + summa (hyvityskuitti negatiivinen); rcById = admin_get_receipt-haku
  const rcById = new Map();
  for (const p of payments) {
    if (p.receipt) { Object.assign(p.receipt, { payment_id: p.payment_id, total_gross: p.amount }); rcById.set(p.receipt.id, p.receipt); }
    if (p.refund_receipt) { Object.assign(p.refund_receipt, { payment_id: p.payment_id, total_gross: -p.refunded_amount }); rcById.set(p.refund_receipt.id, p.refund_receipt); }
  }
  payments.sort((a, b) => (b.paid_at || b.created_at).localeCompare(a.paid_at || a.created_at) || b.payment_id - a.payment_id);
  const wait = () => (delay ? new Promise((ok) => setTimeout(ok, delay)) : Promise.resolve());
  const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
  const dayOf = (s) => String(s).slice(0, 10);
  const fail = (code, message, status = 400) => Object.assign(new Error(message), { name: 'ApiError', code, status });
  const clamp = (v, d, lo, hi) => Math.min(hi, Math.max(lo, Number.isFinite(+v) && v != null ? Math.trunc(+v) : d));
  const orderStatus = (o) => (o.payment_status === 'refunded' ? 'cancelled' : ['pending', 'failed'].includes(o.payment_status) ? 'pending' : 'confirmed');
  const nullLast = (get, dir) => (a, b) => { const x = get(a), y = get(b); if (x == null || x === '') return y == null || y === '' ? 0 : 1; if (y == null || y === '') return -1; return dir * cmp(x, y); };

  // ---- admin_list_orders(p_search,p_status,p_payment_status,p_source,p_native,p_date_field,p_from,p_to,p_sort,p_limit,p_offset) → {total, rows[]} ----
  const ORDER_SORTS = { created: (o) => o.created_at, order_no: (o) => o.order_no, total: (o) => o.total_gross, start: (o) => o.first_reservation_at, paid: (o) => o.paid_amount, unpaid: (o) => o.unpaid_amount };
  function adminListOrders(a = {}) {
    const sort = a.p_sort || 'created_desc', m = /^(created|order_no|total|start|paid|unpaid)_(asc|desc)$/.exec(sort);
    if (!m || (m[1] === 'unpaid' && m[2] === 'asc')) throw fail('invalid_sort', `Virheellinen lajittelu: ${sort}`);
    let rows = orders;
    const q = String(a.p_search || '').trim().toLowerCase();
    if (q) { const num = q.replace(/^#/, ''); rows = /^\d+$/.test(num) ? rows.filter((o) => String(o.order_no) === num || String(o.johku_order_no) === num) : rows.filter((o) => o.customer_name.toLowerCase().includes(q) || o.email.includes(q) || (o.company || '').toLowerCase().includes(q)); }
    if (a.p_status) rows = rows.filter((o) => orderStatus(o) === a.p_status);
    if (a.p_payment_status) rows = rows.filter((o) => o.payment_status === a.p_payment_status);
    if (a.p_source) rows = rows.filter((o) => o.source_channel === a.p_source);
    if (a.p_native != null) rows = rows.filter((o) => o.is_native === !!a.p_native);
    const dateOf = a.p_date_field === 'start' ? (o) => (o.first_reservation_at ? dayOf(o.first_reservation_at) : null) : (o) => o.created_date;
    if (a.p_from) rows = rows.filter((o) => dateOf(o) && dateOf(o) >= a.p_from);
    if (a.p_to) rows = rows.filter((o) => dateOf(o) && dateOf(o) <= a.p_to);
    const dir = m[2] === 'asc' ? 1 : -1, get = ORDER_SORTS[m[1]];
    rows = rows.slice().sort((x, y) => nullLast(get, dir)(x, y) || -cmp(x.order_no, y.order_no));
    const limit = clamp(a.p_limit, 50, 1, 200), offset = clamp(a.p_offset, 0, 0, 1e9);
    return { total: rows.length, rows: rows.slice(offset, offset + limit).map((o) => ({
      order_id: o.order_id, order_no: o.order_no, johku_order_no: o.johku_order_no, created_at: o.created_at, status: orderStatus(o), payment_status: o.payment_status, source_channel: o.source_channel,
      is_native: o.is_native, total: o.total_gross, paid: o.paid_amount, refunded: o.refunded_amount, unpaid: o.unpaid_amount, customer_id: o.order_id % 5000, customer_name: o.customer_name,
      customer_company: o.company, customer_kind: o.company ? 'company' : 'private', first_start: o.first_reservation_at, last_end: o.reservations.length ? o.reservations[o.reservations.length - 1].ends_at : null,
      reservation_count: o.reservations.length, payment_count: o.payments.length, last_paid_at: o.payments.filter((p) => p.paid_at).map((p) => p.paid_at).sort().pop() || null, receipt_count: o.receipts.length })) };
  }

  // ---- admin_get_order(p_order_id) ----
  const balanceOf = (o) => { const pend = round2(o.payments.filter((p) => p.status === 'pending').reduce((s, p) => s + p.amount, 0)); return { total: o.total_gross, paid: o.paid_amount, refunded: o.refunded_amount, pending_link: pend, unpaid: o.unpaid_amount, unpaid_unlinked: round2(Math.max(0, o.unpaid_amount - pend)), net_paid: round2(o.paid_amount - o.refunded_amount) }; };
  function adminGetOrder(a = {}) {
    const o = byId.get(+a.p_order_id); if (!o) throw fail('not_found', 'Tilausta ei löydy', 404);
    const covered = new Map(); for (const p of o.payments) if (!['failed', 'cancelled'].includes(p.status)) for (const l of p.lines) covered.set(l.order_item_id, round2((covered.get(l.order_item_id) || 0) + l.amount_gross));
    const items = o.items.map((x) => { const { vat, net } = vatSplit(x.gross, x.vat); const cv = covered.get(x.id) || (o.is_native ? 0 : x.gross);
      return { id: x.id, parent_item_id: x.parent != null ? o.items[x.parent].id : null, kind: x.group === 'addon' ? 'addon' : x.group === 'giftcard' || x.group === 'other' ? 'product' : 'reservation', product_id: null, name: x.name, quantity: x.qty, unit_price: x.unit, line_total: x.gross, vat_rate: x.vat, line_vat: vat, line_net: net, covered: Math.min(cv, x.gross), remaining: round2(Math.max(0, x.gross - cv)) }; });
    const payments_ = o.payments.map((p) => ({ id: p.payment_id, method: p.method, method_label: METHOD_LABELS[p.method] || p.method, status: p.status, amount: p.amount, paid_at: p.paid_at, provider: p.method === 'visma_pay' ? 'visma_pay' : 'manual',
      provider_status: null, refunded_amount: p.refunded_amount, rounding: p.method === 'cash' ? round2(p.amount - Math.round(p.amount * 20) / 20) : 0, link_token: p.status === 'pending' && p.method === 'visma_pay' ? `00000000-0000-4000-a000-${pad(p.payment_id, 12)}` : null,
      link_path: p.status === 'pending' && p.method === 'visma_pay' ? `/maksa/?p=00000000-0000-4000-a000-${pad(p.payment_id, 12)}` : null, link_expires_at: null, note: null, created_at: p.created_at,
      lines: p.lines.map((l, k) => ({ id: p.payment_id * 10 + k, order_item_id: l.order_item_id, description: l.description, quantity: l.quantity, amount_gross: l.amount_gross, vat_rate: l.vat_rate })),
      receipts: [p.receipt, p.refund_receipt].filter(Boolean).map((x) => ({ id: x.id, receipt_no: x.receipt_no, kind: x.kind, issued_at: x.issued_at, public_token: x.public_token, sent_at: x.sent_at })),
      refunds: p.refunded_amount > 0 ? [{ id: p.payment_id * 10, amount: p.refunded_amount, status: 'done', reason: 'Mock-hyvitys', created_at: iso(p.refund_date, 700), done_at: iso(p.refund_date, 700) }] : [] }));
    const st = orderStatus(o), can = o.is_native && (st === 'confirmed' || st === 'completed');
    return { order_id: o.order_id, order_no: o.order_no, johku_order_no: o.johku_order_no, status: st, payment_status: o.payment_status, source_channel: o.source_channel, is_native: o.is_native, created_at: o.created_at, total: o.total_gross,
      customer_note: null, internal_note: o.order_id % 9 === 0 ? 'Mock-muistiinpano: asiakas toivoo ikkunapaikkaa.' : null,
      customer: { id: o.order_id % 5000, name: o.customer_name, email: o.email, phone: '+358 40 000 0000', company: o.company, customer_kind: o.company ? 'company' : 'private', business_id: o.company ? '1234567-8' : null },
      public_token: `00000000-0000-4000-8000-${pad(o.order_id, 12)}`, order_page_path: `/tilaus/?t=00000000-0000-4000-8000-${pad(o.order_id, 12)}`, balance: balanceOf(o), can_add: can, add_until: can ? `${today}T21:00:00Z` : null, staff_can_add: can,
      items, payments: payments_, receipts: o.receipts.map((x) => ({ id: x.id, receipt_no: x.receipt_no, kind: x.kind, issued_at: x.issued_at, public_token: x.public_token, sent_at: x.sent_at, total: x.total_gross, payment_id: x.payment_id ?? null, refund_id: null })),
      refunds: payments_.flatMap((p) => p.refunds), emails: [], requests: o.order_id % 11 === 0 && o.is_native ? [{ id: o.order_id, kind: 'cancel', status: 'open', reason: 'Mock-peruutuspyyntö', created_at: o.created_at }] : [],
      reservations: o.reservations.map((x) => ({ id: x.id, item_id: x.item_id, status: x.status, product_name: x.product_name, mode: 'shared', starts_at: x.starts_at, ends_at: x.ends_at, persons: x.persons, notes: null, item_total: x.item_total, addons: x.addons })) };
  }

  // ---- admin_list_payments(p_search,p_method,p_status,p_from,p_to,p_sort,p_include_placeholders,p_limit,p_offset) → {total, sum_paid, sum_refunded, rows[]} (EI rivejä) ----
  function adminListPayments(a = {}) {
    const sort = a.p_sort || 'paid_desc', m = /^(paid|amount|order_no)_(asc|desc)$/.exec(sort);
    if (!m) throw fail('invalid_sort', `Virheellinen lajittelu: ${sort}`);
    let rows = payments;
    const q = String(a.p_search || '').trim().toLowerCase();
    if (q) { const num = q.replace(/^#/, ''); rows = rows.filter((p) => (/^\d+$/.test(num) && (String(p.order_no) === num || String(p.payment_id) === num)) || p.customer_name.toLowerCase().includes(q) || (p.receipt_no || '').toLowerCase().includes(q) || (p.provider_ref || '').toLowerCase().includes(q)); }
    if (a.p_method) rows = rows.filter((p) => p.method === a.p_method);
    if (a.p_status) rows = rows.filter((p) => p.status === a.p_status);
    if (a.p_from) rows = rows.filter((p) => dayOf(p.paid_at || p.created_at) >= a.p_from);
    if (a.p_to) rows = rows.filter((p) => dayOf(p.paid_at || p.created_at) <= a.p_to);
    const get = { paid: (p) => p.paid_at || p.created_at, amount: (p) => p.amount, order_no: (p) => p.order_no }[m[1]], dir = m[2] === 'asc' ? 1 : -1;
    rows = rows.slice().sort((x, y) => dir * cmp(get(x), get(y)) || dir * cmp(x.payment_id, y.payment_id));
    const limit = clamp(a.p_limit, 50, 1, 200), offset = clamp(a.p_offset, 0, 0, 1e9), paid = rows.filter((p) => p.paid_at);
    return { total: rows.length, sum_paid: round2(paid.reduce((s, p) => s + p.amount, 0)), sum_refunded: round2(rows.reduce((s, p) => s + p.refunded_amount, 0)), rows: rows.slice(offset, offset + limit).map((p) => ({
      payment_id: p.payment_id, order_id: p.order_id, order_no: p.order_no, method: p.method, method_label: METHOD_LABELS[p.method] || p.method, provider: p.method === 'visma_pay' ? 'visma_pay' : 'manual', status: p.status,
      amount: p.amount, refunded_amount: p.refunded_amount, rounding: 0, paid_at: p.paid_at, created_at: p.created_at, customer_name: p.customer_name, line_count: p.lines.length, receipt_no: p.receipt_no || null, receipt_token: p.receipt?.public_token || null })) };
  }

  // ---- raportit: admin_report_daily(p_date) / admin_report_month(p_ym) → koosteet; rivitaso (`lines`) vain mockissa → asiakaspuolen CSV ----
  function linesBetween(from, to) {
    const out = [];
    for (const p of payments) {
      if (!p.paid_date) continue;
      const at = (d) => (d === p.paid_date ? p.paid_at : iso(d, 700));
      if (p.paid_date >= from && p.paid_date <= to) for (const l of p.lines) out.push({ date: p.paid_date, at: p.paid_at, receipt_no: p.receipt_no, kind: 'receipt', order_no: p.order_no, method: p.method, group: l.group, product: l.description, quantity: l.quantity,
        gross: l.amount_gross, vat_rate: l.vat_rate, vat: l.line_vat, net: l.line_net, refund: 0 });
      if (p.refund_date && p.refund_date >= from && p.refund_date <= to && p.refunded_amount > 0) for (const l of linesFor(p.lines.map((x) => ({ name: x.description, group: x.group, qty: x.quantity, gross: x.amount_gross, vat: x.vat_rate })), p.refunded_amount / p.amount, p.refunded_amount)) {
        out.push({ date: p.refund_date, at: at(p.refund_date), receipt_no: p.refund_receipt_no, kind: 'refund_receipt', order_no: p.order_no, method: p.method, group: l.group, product: l.description, quantity: l.quantity, gross: -l.amount_gross, vat_rate: l.vat_rate, vat: -l.line_vat, net: -l.line_net, refund: l.amount_gross });
      }
    }
    return out.sort((a, b) => a.date.localeCompare(b.date) || String(a.receipt_no).localeCompare(String(b.receipt_no)));
  }
  const GROUP_LABELS = { public: 'Yleiset vuorot', private: 'Yksityiset vuorot', treatment: 'Hoidot ja rituaalit', addon: 'Lisäpalvelut', giftcard: 'Lahjakortit', event: 'Tapahtumat', other: 'Muu' };
  function buildReport(from, to, period, { daily = false } = {}) {
    const lines = linesBetween(from, to), by = (rows, keyf, mk) => { const m = new Map(); for (const l of rows) { const k = keyf(l); m.set(k, mk(m.get(k), l)); } return [...m.values()]; };
    const sum = (a, k, b) => round2((a?.[k] || 0) + b[k]);
    const receiptsMap = new Map(); for (const l of lines) { const x = receiptsMap.get(l.receipt_no) || { receipt_no: l.receipt_no, kind: l.kind, issued_at: l.at, order_no: l.order_no, method: l.method, gross: 0, net: 0, vat: 0 }; x.gross = round2(x.gross + l.gross); x.net = round2(x.net + l.net); x.vat = round2(x.vat + l.vat); receiptsMap.set(l.receipt_no, x); }
    const receipts = [...receiptsMap.values()];
    const sales = lines.filter((l) => l.kind === 'receipt'), refunds = lines.filter((l) => l.kind === 'refund_receipt');
    const openO = orders.filter((o) => ['unpaid', 'partially_paid'].includes(o.payment_status) && o.is_native);
    const rep = {
      period: { from, to, kind: period }, generated_at: `${today}T12:00:00Z`,
      totals: { receipts: receipts.filter((x) => x.kind === 'receipt').length, refund_receipts: receipts.filter((x) => x.kind === 'refund_receipt').length, gross: round2(sales.reduce((s, l) => s + l.gross, 0)), net: round2(sales.reduce((s, l) => s + l.net, 0)), vat: round2(sales.reduce((s, l) => s + l.vat, 0)),
        refunds_gross: round2(refunds.reduce((s, l) => s + l.gross, 0)), gross_after_refunds: round2(lines.reduce((s, l) => s + l.gross, 0)), net_after_refunds: round2(lines.reduce((s, l) => s + l.gross, 0)) /* DEPRECATED, sama arvo kuin palvelimella */, vat_after_refunds: round2(lines.reduce((s, l) => s + l.vat, 0)), net_ex_vat_after_refunds: round2(lines.reduce((s, l) => s + l.net, 0)), rounding: 0 },
      by_method: by(lines, (l) => l.method, (a, l) => ({ method: l.method, label: METHOD_LABELS[l.method] || l.method, payments: 0, gross: round2((a?.gross || 0) + (l.kind === 'receipt' ? l.gross : 0)), refunds: round2((a?.refunds || 0) + (l.kind === 'refund_receipt' ? l.gross : 0)), rounding: 0 })),
      by_vat: by(lines, (l) => l.vat_rate, (a, l) => ({ rate: l.vat_rate, net: sum(a, 'net', l), vat: sum(a, 'vat', l), gross: sum(a, 'gross', l) })).sort((a, b) => b.rate - a.rate),
      by_method_vat: by(lines, (l) => `${l.method}|${l.vat_rate}`, (a, l) => ({ method: l.method, rate: l.vat_rate, net: sum(a, 'net', l), vat: sum(a, 'vat', l), gross: sum(a, 'gross', l) })),
      by_category: by(lines, (l) => `${l.group}|${l.vat_rate}`, (a, l) => ({ category: l.group, label: GROUP_LABELS[l.group] || l.group, rate: l.vat_rate, quantity: (a?.quantity || 0) + (l.kind === 'receipt' ? l.quantity : -l.quantity), gross: sum(a, 'gross', l), net: sum(a, 'net', l), vat: sum(a, 'vat', l) })),
      open: { orders: openO.length, unpaid: round2(openO.reduce((s, o) => s + o.unpaid_amount, 0)) },
      lines,   // vain mock: oikea palvelin ei (vielä) palauta rivejä → CSV tulee admin_report_csv:stä
    };
    for (const m of rep.by_method) m.payments = new Set(receipts.filter((x) => x.method === m.method && x.kind === 'receipt').map((x) => x.receipt_no)).size;
    if (daily) rep.receipts = receipts;
    else rep.by_day = by(receipts, (x) => dayOf(x.issued_at), (a, x) => ({ date: dayOf(x.issued_at), receipts: (a?.receipts || 0) + (x.kind === 'receipt' ? 1 : 0), gross: round2((a?.gross || 0) + (x.kind === 'receipt' ? x.gross : 0)), vat: round2((a?.vat || 0) + x.vat), refunds: round2((a?.refunds || 0) + (x.kind === 'refund_receipt' ? x.gross : 0)) })).sort((a, b) => a.date.localeCompare(b.date));
    return rep;
  }
  const monthEnd = (ym) => dayAdd(`${new Date(Date.UTC(+ym.slice(0, 4), +ym.slice(5, 7), 1)).toISOString().slice(0, 7)}-01`, -1);
  function adminReportDaily(a = {}) { if (!/^\d{4}-\d{2}-\d{2}$/.test(a.p_date || '')) throw fail('invalid_date', 'Virheellinen päivä'); return buildReport(a.p_date, a.p_date, 'day', { daily: true }); }
  function adminReportMonth(a = {}) { if (!/^\d{4}-\d{2}$/.test(a.p_ym || '')) throw fail('invalid_month', 'Virheellinen kuukausi'); return buildReport(`${a.p_ym}-01`, monthEnd(a.p_ym), 'month'); }
  // admin_report_csv(p_from,p_to,p_kind='lines') → {filename, mime, content} – kuten booking_34: 12 saraketta, pvm PP.KK.VVVV, hyvitys kyllä/ei, hyvitysrivin määrä negatiivinen
  function adminReportCsv(a = {}) {
    const q = (v) => (/[;"\r\n]/.test(String(v)) ? `"${String(v).replace(/"/g, '""')}"` : String(v)), d = (n) => (Math.round(n * 100) / 100).toFixed(2).replace('.', ','), r = (n) => String(Math.round(n * 100) / 100).replace('.', ',');
    const dmy = (iso10) => `${iso10.slice(8, 10)}.${iso10.slice(5, 7)}.${iso10.slice(0, 4)}`;
    const rows = linesBetween(a.p_from, a.p_to).map((l) => [dmy(l.date), l.receipt_no, l.order_no, METHOD_LABELS[l.method] || l.method, GROUP_LABELS[l.group] || l.group, l.product, l.kind === 'refund_receipt' ? -Math.abs(l.quantity) : l.quantity, d(l.gross), r(l.vat_rate), d(l.vat), d(l.net), l.kind === 'refund_receipt' ? 'kyllä' : 'ei'].map(q).join(';'));
    return { filename: `kuitit_lines_${a.p_from}_${a.p_to}.csv`, mime: 'text/csv;charset=utf-8', content: `\uFEFF${['pvm;kuitti_no;tilaus_no;maksutapa;tuoteryhmä;tuote;määrä;brutto;alv_%;alv_€;netto;hyvitys', ...rows].join('\r\n')}\r\n` };
  }

  // ---- admin_get_receipt(p_receipt_id) / admin_resend_receipt(p_receipt_id) (sopimus §3, §9.1) ----
  const money = (n) => `${Math.abs(n).toFixed(2).replace('.', ',')} €`.replace(/^/, n < 0 ? '-' : '');
  const SELLER = { name: 'Sipoonjoen perinnesauna', legal_name: 'Havuhattu Oy', business_id: '0000000-0', vat_id: 'FI00000000', address: 'Esimerkkitie 1', zip: '00000', city: 'Sipoo', email: 'esimerkki@example.test', phone: '000 000 0000', web: 'https://example.test', logo_url: null, footer: 'Kiitos käynnistä! (esimerkkikuitti)' };
  const helsinkiLocal = (iso) => { const q = Object.fromEntries(new Intl.DateTimeFormat('fi-FI', { timeZone: 'Europe/Helsinki', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(new Date(iso)).map((x) => [x.type, x.value])); return `${q.day}.${q.month}.${q.year} ${q.hour}:${q.minute}`; };
  function receiptOf(id) {
    const rc = rcById.get(+id); if (!rc) throw fail('receipt_not_found', 'Kuittia ei löydy', 404);
    const p = payById.get(rc.payment_id), refund = rc.kind === 'refund_receipt', sign = refund ? -1 : 1, share = refund ? (p.refunded_amount / p.amount) : 1;
    const lines = p.lines.map((l) => { const gross = round2(sign * l.amount_gross * share), vat = vatSplit(Math.abs(gross), l.vat_rate).vat * sign; return { description: l.description, quantity: l.quantity, unit_gross: round2(gross / l.quantity), unit_net: round2((gross - vat) / l.quantity), line_gross: gross, line_net: round2(gross - vat), vat_rate: l.vat_rate, kind: l.group === 'addon' ? 'addon' : 'product', starts_at: null, ends_at: null }; });
    const byRate = new Map(); for (const l of lines) byRate.set(l.vat_rate, round2((byRate.get(l.vat_rate) || 0) + l.line_gross));
    const vat = [...byRate].map(([rate, gross]) => { const v = round2(sign * vatSplit(Math.abs(gross), rate).vat); return { rate, net: round2(gross - v), vat: v, gross }; });
    const total = round2(lines.reduce((x, l) => x + l.line_gross, 0)), totalVat = round2(vat.reduce((x, v) => x + v.vat, 0));
    const o = byId.get(p.order_id), local = helsinkiLocal(rc.issued_at);
    const snapshot = { v: 1, document: rc.kind, receipt_no: rc.receipt_no, issued_at: rc.issued_at, issued_local: local, seller: SELLER, order_no: o.order_no, payment: { id: p.payment_id, method: p.method, method_label: METHOD_LABELS[p.method] || p.method, paid_at: p.paid_at },
      buyer: o.company ? { name: o.customer_name, company: o.company, business_id: '1234567-8', address: 'Mockkatu 2', zip: '00100', city: 'Helsinki', reference: null } : null, invoice_required: !!o.company && total > 400,
      lines, vat, total_gross: total, total_net: round2(total - totalVat), total_vat: totalVat, rounding: 0, total_paid: total, currency: 'EUR',
      original: refund ? { receipt_no: p.receipt_no, issued_at: p.paid_at } : null, reason: refund ? 'Mock-hyvitys' : null, locale: 'fi' };
    const t = [SELLER.name, `${SELLER.legal_name}, Y-tunnus ${SELLER.business_id}, ALV-tunnus ${SELLER.vat_id}`, `${SELLER.address}, ${SELLER.zip} ${SELLER.city}`, '',
      `${refund ? 'HYVITYSKUITTI' : snapshot.invoice_required ? 'KUITTI / LASKU' : 'KUITTI'} ${rc.receipt_no}`, `Päivämäärä: ${local.replace(' ', ' klo ')}`, `Tilaus: ${o.order_no}`, `Maksutapa: ${snapshot.payment.method_label}`];
    if (snapshot.buyer) t.push(`Ostaja: ${snapshot.buyer.company}, ${snapshot.buyer.name}`);
    if (refund) t.push(`Alkuperäinen kuitti: ${p.receipt_no}`, 'Hyvityksen syy: Mock-hyvitys');
    t.push('', ...lines.flatMap((l) => [l.description, `   ${l.quantity} kpl × ${money(l.unit_gross)} = ${money(l.line_gross)} (ALV ${String(l.vat_rate).replace('.', ',')} %)`]), '', 'ALV-erittely',
      ...vat.map((v) => `ALV ${String(v.rate).replace('.', ',')} %: veroton ${money(v.net)}, ALV ${money(v.vat)}, yhteensä ${money(v.gross)}`), '', `Yhteensä (sis. ALV) ${money(total)}`, `josta ALV ${money(totalVat)}, veroton ${money(total - totalVat)}`, `${refund ? 'Hyvitetty' : 'Maksettu'} ${money(total)}`, '', SELLER.footer);
    return { id: rc.id, receipt_no: rc.receipt_no, kind: rc.kind, issued_at: rc.issued_at, total_gross: total, snapshot, text_body: `${t.join('\n')}\n`, public_token: rc.public_token, pdf_url: `https://mock.invalid/functions/v1/receipt-pdf?t=${rc.public_token}`, sent_at: rc.sent_at, order_id: rc.order_id, payment_id: rc.payment_id, refund_id: null };
  }
  const adminGetReceipt = (a = {}) => receiptOf(a.p_receipt_id);
  function adminResendReceipt(a = {}) { receiptOf(a.p_receipt_id); return { ok: true, mock: true, email_queued: true }; }

  // ---- kirjoittavat RPC:t: vain kuittaus oikeilla vastausmuodoilla (mock ei muuta dataa) ----
  function adminAddToOrder(a = {}) {
    const o = byId.get(+a.p_order_id); if (!o) throw fail('not_found', 'Tilausta ei löydy', 404);
    const items = Array.isArray(a.p_items) ? a.p_items : []; if (!items.length || items.length > 20) throw fail('invalid_items', 'Rivejä 1–20');
    const added = items.map((x, k) => ({ item_id: 9e6 + k, name: x.type === 'custom' ? x.description : x.code || `Rivi ${k + 1}`, line_total: x.type === 'custom' ? round2(+x.amount * (+x.quantity || 1)) : round2(5 * (+x.quantity || 1)), reservation_id: x.reservation_id ?? null }));
    const addedTotal = round2(added.reduce((s, x) => s + x.line_total, 0)), b = balanceOf(o);
    return { ok: true, mock: true, order_id: o.order_id, added, added_total: addedTotal, balance: { ...b, total: round2(b.total + addedTotal), unpaid: round2(b.unpaid + addedTotal) },
      payment: a.p_create_link ? { payment_id: 9e6, link_token: '00000000-0000-4000-a000-000000000001', link_path: '/maksa/?p=00000000-0000-4000-a000-000000000001', amount: round2(b.unpaid + addedTotal), expires_at: `${dayAdd(today, 14)}T21:00:00Z` } : null, email_queued: false };
  }
  function adminCreatePaymentLink(a = {}) {
    const o = byId.get(+a.p_order_id); if (!o) throw fail('not_found', 'Tilausta ei löydy', 404);
    if (!(o.unpaid_amount > 0)) throw fail('nothing_to_pay', 'Ei maksettavaa');
    return { ok: true, mock: true, payment_id: 9e6, link_token: '00000000-0000-4000-a000-000000000001', link_path: '/maksa/?p=00000000-0000-4000-a000-000000000001', amount: o.unpaid_amount, expires_at: `${dayAdd(today, +a.p_expires_days || 14)}T21:00:00Z`,
      lines: o.items.map((x) => ({ order_item_id: x.id, description: x.name, amount_gross: x.gross })), online_payment_enabled: false, email_queued: false };
  }
  function adminRefund(a = {}) {
    const p = payById.get(+a.p_payment_id); if (!p) throw fail('not_found', 'Maksua ei löydy', 404);
    if (!['paid', 'partially_refunded'].includes(p.status)) throw fail('refund_not_allowed', 'Maksua ei voi hyvittää');
    if (!(a.p_amount > 0) || a.p_amount > round2(p.amount - p.refunded_amount)) throw fail('amount_exceeds_refundable', 'Summa ylittää hyvitettävän');
    return { ok: true, mock: true, refund_id: 9e6, status: 'done', balance: balanceOf(byId.get(p.order_id)), receipt_id: null, receipt_no: null };
  }
  function adminRecordPayment(a = {}) {
    const o = byId.get(+a.p_order_id); if (!o) throw fail('not_found', 'Tilausta ei löydy', 404);
    if (!o.is_native) throw fail('order_not_editable', 'Tilaukseen ei voi kirjata maksua');
    if (!['cash', 'card_terminal', 'mobilepay', 'bank_transfer', 'invoice', 'other'].includes(a.p_method)) throw fail('invalid_payment_method', 'Maksutapa ei ole käytössä / ei käsin kirjattava');
    if (!(a.p_amount > 0)) throw fail('invalid_amount', 'Summa pitää olla positiivinen');
    if (a.p_amount > o.unpaid_amount + 0.005) throw fail('amount_exceeds_unpaid', `Summa ylittää maksamattoman osuuden (${o.unpaid_amount} €)`);
    const b = balanceOf(o), paid = round2(b.paid + a.p_amount);
    return { ok: true, mock: true, payment_id: 9e6, receipt_id: 9e6, receipt_no: 'K-MOCK-000001', rounding: 0, balance: { ...b, paid, unpaid: round2(b.total - paid), net_paid: paid } };
  }
  function adminListVatRates() {
    return { rates: [{ rate: 25.5, label: 'ALV 25,5 % (yleinen)', active: true, products: 46, addons: 3 }, { rate: 13.5, label: 'ALV 13,5 %', active: true, products: 2, addons: 0 }, { rate: 0, label: 'ALV 0 %', active: true, products: 0, addons: 0 }],
      missing: [{ kind: 'product', id: 47, name: 'Tossujen tai saunatakin vuokra (paikan päällä)' }], quote_only: [{ id: 50, name: 'Työhyvinvointipäivät ja ryhmät (tarjouspyyntö)' }] };
  }
  const ADDON_LIST = [{ id: 1, code: 'saunavihta', name: 'Saunavihta', name_en: 'Sauna whisk (vihta)', price: 5, vat_rate: 25.5, max_per_person: 1, active: true }, { id: 2, code: 'pyyhe', name: 'Pyyhe', name_en: 'Towel', price: 5, vat_rate: 25.5, max_per_person: 1, active: true },
    { id: 3, code: 'turvenaamio_jalkakylpy', name: 'Turvenaamio ja jalkakylpy', name_en: 'Peat mask and foot bath', price: 12, vat_rate: 25.5, max_per_person: 1, active: true }];
  const HANDLERS = { admin_list_orders: adminListOrders, admin_get_order: adminGetOrder, admin_list_payments: adminListPayments, admin_list_addons: () => ADDON_LIST, admin_add_to_order: adminAddToOrder, admin_create_payment_link: adminCreatePaymentLink,
    admin_refund: adminRefund, admin_record_payment: adminRecordPayment, admin_list_vat_rates: adminListVatRates, admin_report_daily: adminReportDaily, admin_report_month: adminReportMonth, admin_report_csv: adminReportCsv, admin_get_receipt: adminGetReceipt, admin_resend_receipt: adminResendReceipt };
  // sama kutsutapa kuin sb.js:n rpc(): rpc(nimi, parametrit) → Promise. Tuntematon nimi = puuttuva RPC (404 / PGRST202) kuten PostgRESTissä.
  async function rpc(name, args = {}) {
    await wait();
    const h = HANDLERS[name]; if (!h) throw Object.assign(new Error(`Could not find the function booking.${name} in the schema cache`), { name: 'ApiError', status: 404, code: 'PGRST202' });
    return JSON.parse(JSON.stringify(h(args)));
  }
  return { rpc, orders, payments, today, supported: Object.keys(HANDLERS) };
}
