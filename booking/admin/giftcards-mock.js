// Lahjakortti-mock (hallinta): deterministinen, vain keksittyä dataa. Vastaa sopimuksen §13 admin-RPC:itä samoilla nimillä, p_-parametreilla ja vastausrakenteilla,
// joten giftcards-api.js ajaa sekä mockia että oikeaa palvelinta samalla koodilla. Puhdas moduuli (ei DOM:ia) → node --test voi ajaa sen.
import { resolveDelivery } from './giftcards-delivery.js';
const CHARS = '3479ACEFHJKLMNPRTUVWXY';
const pad = (n, w = 2) => String(n).padStart(w, '0');
const round2 = (n) => Math.round((+n + Number.EPSILON) * 100) / 100;
const dayAdd = (ds, n) => { const d = new Date(`${ds}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const monthsAdd = (ds, m) => { const d = new Date(`${ds}T12:00:00Z`); d.setUTCMonth(d.getUTCMonth() + m); return d.toISOString().slice(0, 10); };
const fmtCode = (n) => `${n.slice(0, 4)}-${n.slice(4, 8)}-${n.slice(8)}`;
const norm = (s) => String(s ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
export const MOCK_PACKAGES = [
  { code: 'open', kind: 'value', name: 'Avoin lahjakortti', name_en: 'Open gift card', description: 'Vapaa summa; käy kaikkiin palveluihin.', description_en: 'Any amount; valid for all services.', is_open: true, price: null, min_amount: 29, max_amount: 500, persons: null, vat_rate: 25.5, vat_treatment: 'at_redemption', valid_months: 6, active: true, sort_order: 1, items: [] },
  { code: 'entry_2', kind: 'product', name: 'Sisäänpääsy kahdelle', name_en: 'Admission for two', description: 'Savusaunavuoro kahdelle hengelle.', description_en: 'Smoke sauna session for two.', is_open: false, price: 58, min_amount: null, max_amount: null, persons: 2, vat_rate: 25.5, vat_treatment: 'at_sale', valid_months: 6, active: true, sort_order: 2, items: [] },
  { code: 'peat_mask_2', kind: 'product', name: 'Savusaunaelämys turvenaamiolla ja jalkakylvyllä kahdelle', name_en: 'Smoke sauna experience with peat mask and foot bath for two', description: '', description_en: '', is_open: false, price: 88, min_amount: null, max_amount: null, persons: 2, vat_rate: 25.5, vat_treatment: 'at_sale', valid_months: 6, active: true, sort_order: 3, items: [] },
  { code: 'sauna_treatment_2', kind: 'product', name: 'Savusaunaelämys ja saunahoito kahdelle', name_en: 'Smoke sauna experience and sauna treatment for two', description: '', description_en: '', is_open: false, price: 192, min_amount: null, max_amount: null, persons: 2, vat_rate: 25.5, vat_treatment: 'at_sale', valid_months: 6, active: true, sort_order: 4, items: [] },
  { code: 'saunotus_2', kind: 'product', name: 'Savusaunaelämys ja saunotus kahdelle', name_en: 'Smoke sauna experience and ritual sauna bathing for two', description: '', description_en: '', is_open: false, price: 328, min_amount: null, max_amount: null, persons: 2, vat_rate: 25.5, vat_treatment: 'at_sale', valid_months: 6, active: true, sort_order: 5, items: [] },
];
const NAMES = [['Aino Virtanen', 'Eero Korhonen'], ['Helmi Laine', 'Ilmari Salo'], ['Kaisa Heikkinen', 'Lauri Mäkelä'], ['Maija Nieminen', 'Niko Ojala'], ['Olli Rantanen', 'Pirjo Hakala'], ['Sanni Koskinen', 'Tuomas Aaltonen']];

export function createGiftMock({ today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' }), delay = 0, settings = {} } = {}) {
  const sett = { sale_enabled: false, redeem_enabled: true, johku_cards_redeemable: false, ...settings };
  let seq = 0, ledgerId = 1, orderNo = 15100;
  const cards = [], ledgers = new Map(), expiryLogs = new Map(), payments = new Map();
  const mkCode = () => { seq += 1; let x = seq * 2654435761 >>> 0, s = 'HH'; for (let i = 0; i < 10; i++) { s += CHARS[x % CHARS.length]; x = (Math.imul(x, 1103515245) + 12345 + i) >>> 0; } return s; };
  const log = (id, e) => { const l = ledgers.get(id) || []; l.push({ id: ledgerId++, at: `${today}T09:00:00Z`, meta: null, note: null, order_id: null, order_no: null, payment_id: null, old_valid_to: null, new_valid_to: null, created_by: null, ...e }); ledgers.set(id, l); };
  function add(o) {
    const id = cards.length + 1, pkg = MOCK_PACKAGES.find((p) => p.code === (o.package_code || 'open')), n = norm(o.rawCode || mkCode());
    const c = { id, code: fmtCode(n), code_last4: n.slice(-4), source: 'native', issuer: 'own', kind: pkg.kind, package_code: pkg.code, package_name: pkg.name, product_id: null, initial_amount: o.initial, balance: o.balance ?? o.initial,
      currency: 'EUR', status: 'active', valid_from: o.valid_from || today, valid_to: o.valid_to || monthsAdd(today, 6), balance_verified: true, balance_source: 'native', vat_treatment: pkg.vat_treatment || 'at_sale', sale_vat_rate: 25.5, accounting_origin: 'native',
      single_order: false, buyer_customer_id: null, buyer_name: null, buyer_email: null, recipient_name: null, recipient_email: null, greeting: null, locale: 'fi', purchase_order_id: null, order_no: null,
      delivery_to: 'buyer', cover_message: null, deliver_on: null, deliver_time: null, delivered_at: null,   // §13.11
      public_token: `00000000-0000-4000-8000-${pad(id, 12)}`, created_at: `${o.created || today}T08:00:00Z`, activated_at: `${o.created || today}T08:00:00Z`, last_used_at: null, note: null, ...o.over };
    cards.push(c); if (o.ledger !== false) log(id, { delta: o.initial, reason: c.source === 'johku' ? 'johku_purchase' : 'purchase', balance_after: o.initial, at: c.created_at });
    return c;
  }
  // siemendata (deterministinen)
  NAMES.forEach(([r, b], i) => {
    const pk = MOCK_PACKAGES[1 + (i % 4)], c = add({ package_code: pk.code, initial: pk.price, created: dayAdd(today, -20 - i * 9), over: { recipient_name: r, buyer_name: b, buyer_email: `ostaja${i + 1}@example.invalid`, greeting: i % 2 ? 'Rentouttavia hetkiä!' : null, order_no: 14990 + i, purchase_order_id: 7000 + i } });
    if (i === 1) Object.assign(c, { delivery_to: 'recipient', recipient_email: 'saaja2@example.invalid', cover_message: 'Hyvää syntymäpäivää! Tässä lahjasi.', delivered_at: `${dayAdd(today, -19)}T07:00:00Z` });   // toimitettu saajalle
    if (i === 2) Object.assign(c, { delivery_to: 'recipient', recipient_email: 'saaja3@example.invalid', cover_message: 'Avaa sitten kun on aika rentoutua.', deliver_on: dayAdd(today, 20), deliver_time: null, delivered_at: null });   // ajastettu
    if (i % 3 === 0) { c.balance = 0; c.status = 'used'; c.last_used_at = `${dayAdd(today, -3)}T10:00:00Z`; log(c.id, { delta: -pk.price, reason: 'redemption', balance_after: 0, order_id: 8000 + i, order_no: 15000 + i, payment_id: 900 + i }); payments.set(c.id, [{ payment_id: 900 + i, order_id: 8000 + i, order_no: 15000 + i, amount: pk.price, refunded_amount: 0, status: 'paid', paid_at: `${dayAdd(today, -3)}T10:00:00Z`, accounted: false }]); }
  });
  [50, 75, 120, 200].forEach((a, i) => { const c = add({ package_code: 'open', initial: a, created: dayAdd(today, -40 - i * 11), over: { recipient_name: NAMES[i][0], buyer_name: NAMES[i][1], buyer_email: `avoin${i + 1}@example.invalid`, vat_treatment: 'at_redemption' } }); if (i === 1) { c.balance = 45; log(c.id, { delta: -30, reason: 'redemption', balance_after: 45, order_id: 8100, order_no: 15050, payment_id: 950 }); payments.set(c.id, [{ payment_id: 950, order_id: 8100, order_no: 15050, amount: 30, refunded_amount: 0, status: 'paid', paid_at: `${dayAdd(today, -5)}T11:00:00Z`, accounted: true }]); } });
  add({ package_code: 'open', initial: 60, created: dayAdd(today, -200), valid_to: dayAdd(today, -15), over: { status: 'active', recipient_name: 'Vanhentunut Esimerkki' } });
  add({ package_code: 'entry_2', initial: 58, created: dayAdd(today, -170), valid_to: dayAdd(today, 12), over: { recipient_name: 'Pian Vanhenevat' } });
  add({ package_code: 'open', initial: 100, balance: 100, created: dayAdd(today, -2), over: { status: 'cancelled', recipient_name: 'Mitätöity Esimerkki', note: 'Mitätöity: väärä summa' } });
  add({ package_code: 'saunotus_2', initial: 328, balance: 0, created: dayAdd(today, -1), ledger: false, over: { status: 'pending_payment', activated_at: null, valid_to: null, buyer_name: 'Maksuton Ostaja', buyer_email: 'odottaa@example.invalid', recipient_name: 'Odottava Saaja', order_no: 15099, purchase_order_id: 7099 } });
  for (let i = 0; i < 18; i++) {
    const init = [25, 40, 60, 80, 100, 150][i % 6], bal = [init, init, Math.round(init / 2), 0][i % 4];
    const c = add({ rawCode: `JK${String(100000000 + i * 7919).slice(0, 10)}`, package_code: 'open', initial: init, balance: bal, created: dayAdd(today, -300 + i * 9), valid_to: dayAdd(today, 30 + i * 11),
      over: { source: 'johku', issuer: 'johku', accounting_origin: 'johku', vat_treatment: 'at_sale', balance_source: 'johku_api', buyer_name: NAMES[i % 6][1], buyer_email: `johku${i + 1}@example.invalid`, single_order: i % 9 === 4, balance_verified: i % 7 !== 3, status: bal === 0 ? 'used' : i % 7 === 3 ? 'pending_verification' : 'active' } });
    if (bal < init) log(c.id, { delta: bal - init, reason: 'johku_usage', balance_after: bal });
  }
  const err = (code, message) => Object.assign(new Error(message || code), { code, status: 400 });
  const eff = (c) => (c.status === 'active' && c.valid_to && c.valid_to < today ? 'expired' : c.status);
  const view = (c) => ({ ...c, effective_status: eff(c) });
  const find = (a) => { const c = a.p_id != null ? cards.find((x) => x.id === +a.p_id) : cards.find((x) => norm(x.code) === norm(a.p_code)); if (!c) throw err('gift_card_not_found', 'Lahjakorttia ei löydy'); return c; };
  const ledgerSum = (id) => round2((ledgers.get(id) || []).reduce((s, x) => s + x.delta, 0));
  const SORTS = { created_desc: (a, b) => b.id - a.id, created_asc: (a, b) => a.id - b.id, valid_to_asc: (a, b) => String(a.valid_to || '9999').localeCompare(String(b.valid_to || '9999')) || b.id - a.id, valid_to_desc: (a, b) => String(b.valid_to || '').localeCompare(String(a.valid_to || '')) || b.id - a.id,
    balance_desc: (a, b) => b.balance - a.balance || b.id - a.id, balance_asc: (a, b) => a.balance - b.balance || b.id - a.id, initial_desc: (a, b) => b.initial_amount - a.initial_amount || b.id - a.id, initial_asc: (a, b) => a.initial_amount - b.initial_amount || b.id - a.id };
  const handlers = {
    admin_list_gift_card_packages: () => ({ packages: MOCK_PACKAGES.map((p) => ({ ...p, updated_at: `${today}T00:00:00Z`, kb_product_id: null })), settings: { redeem_enabled: sett.redeem_enabled, johku_cards_redeemable: sett.johku_cards_redeemable, sale_enabled: sett.sale_enabled } }),
    admin_list_gift_cards: (a) => {
      const sort = a.p_sort || 'created_desc'; if (!SORTS[sort]) throw err('invalid_sort', 'Tuntematon lajittelu');
      const s = String(a.p_search || '').trim().toLowerCase(), ns = norm(s);
      let rows = cards.filter((c) => !s || (ns.length >= 4 && norm(c.code).includes(ns)) || [c.buyer_name, c.buyer_email, c.recipient_name, c.recipient_email].some((v) => v && v.toLowerCase().includes(s)) || (/^\d{1,10}$/.test(s) && String(c.order_no) === s));
      if (a.p_status) rows = rows.filter((c) => (a.p_status === 'expired' ? eff(c) === 'expired' : a.p_status === 'active' ? eff(c) === 'active' : c.status === a.p_status));
      if (a.p_source) rows = rows.filter((c) => c.source === a.p_source); if (a.p_kind) rows = rows.filter((c) => c.kind === a.p_kind); if (a.p_package) rows = rows.filter((c) => c.package_code === a.p_package);
      if (a.p_unverified != null) rows = rows.filter((c) => c.balance_verified === !a.p_unverified);
      if (a.p_expiring_days != null) rows = rows.filter((c) => c.status === 'active' && c.valid_to && c.valid_to >= today && c.valid_to <= dayAdd(today, +a.p_expiring_days));
      if (a.p_has_balance != null) rows = rows.filter((c) => (c.balance > 0) === !!a.p_has_balance);
      rows = [...rows].sort(SORTS[sort]);
      const lim = Math.min(Math.max(+a.p_limit || 50, 1), 200), off = Math.max(+a.p_offset || 0, 0);
      return { total: rows.length, sum_balance: round2(rows.reduce((x, c) => x + c.balance, 0)), sum_initial: round2(rows.reduce((x, c) => x + c.initial_amount, 0)),
        sum_balance_redeemable: round2(rows.filter((c) => eff(c) === 'active').reduce((x, c) => x + c.balance, 0)), rows: rows.slice(off, off + lim).map(view) };
    },
    admin_get_gift_card: (a) => { const c = find(a); return { ok: true, card: view(c), ledger: [...(ledgers.get(c.id) || [])].sort((x, y) => x.id - y.id), payments: payments.get(c.id) || [], expiry_log: expiryLogs.get(c.id) || [],
      purchase_order: c.purchase_order_id ? { order_id: c.purchase_order_id, order_no: c.order_no, johku_order_no: null, status: 'confirmed', payment_status: c.status === 'pending_payment' ? 'unpaid' : 'paid', total: c.initial_amount } : null, ledger_consistent: ledgerSum(c.id) === c.balance }; },
    admin_create_gift_card: (a) => {
      const pkg = MOCK_PACKAGES.find((p) => p.code === a.p_package); if (!pkg) throw err('invalid_package', 'Tuntematon lahjakorttipaketti');
      const q = a.p_quantity ?? 1; if (!Number.isInteger(q) || q < 1 || q > 10) throw err('invalid_quantity', 'Määrä 1–10');
      let amount = pkg.price;
      if (pkg.is_open) { if (a.p_amount == null || round2(a.p_amount) !== +a.p_amount || a.p_amount < pkg.min_amount || a.p_amount > pkg.max_amount) throw err('invalid_amount', `Summa ${pkg.min_amount}–${pkg.max_amount} €`); amount = +a.p_amount; }
      else if (a.p_amount != null && +a.p_amount !== pkg.price) throw err('invalid_amount', 'Paketin hinta on kiinteä');
      if (a.p_greeting && String(a.p_greeting).length > 300) throw err('invalid_greeting', 'Tervehdys on liian pitkä (max 300 merkkiä)');
      // toimitusvalinta: sama järjestys kuin palvelimella (_gc_sell): sähköposti (invalid_email) → tervehdys → _gc_delivery_resolve
      if (a.p_recipient_email && !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(String(a.p_recipient_email).trim())) throw err('invalid_email', 'Tarkista saajan sähköpostiosoite');
      const dv = resolveDelivery({ to: a.p_delivery_to, recipientEmail: a.p_recipient_email, cover: a.p_cover_message, on: a.p_deliver_on, time: a.p_deliver_time, months: Math.min(12, a.p_valid_months || pkg.valid_months || 6), now: new Date() });
      if (!dv.ok) throw err(dv.code, `Toimitusvalinta virheellinen (${dv.code})`);
      const paid = !!a.p_payment_method && !['pay_later', 'invoice'].includes(a.p_payment_method), sale = !!a.p_payment_method;
      if (!sale && String(a.p_note || '').trim().length < 3) throw err('invalid_param', 'Anna maksuttoman kortin syy (p_note)');
      const out = [], on = sale ? ++orderNo : null;
      for (let i = 0; i < q; i++) {
        const c = add({ package_code: pkg.code, initial: sale && !paid ? amount : amount, balance: sale && !paid ? 0 : amount, ledger: sale ? false : true, over: { buyer_name: a.p_buyer?.name || null, buyer_email: a.p_buyer?.email || null, recipient_name: a.p_recipient_name || null, recipient_email: a.p_recipient_email || null,
          greeting: a.p_greeting || null, ...dv.value, vat_treatment: a.p_vat_treatment || (sale ? pkg.vat_treatment : 'at_sale'), locale: a.p_locale || 'fi', note: a.p_note || null, order_no: on, purchase_order_id: on ? on - 15100 + 9000 : null,
          status: sale && !paid ? 'pending_payment' : 'active', activated_at: sale && !paid ? null : `${today}T08:00:00Z`, valid_to: sale && !paid ? null : monthsAdd(today, a.p_valid_months || pkg.valid_months) } });
        if (sale && paid) log(c.id, { delta: amount, reason: 'purchase', balance_after: amount, order_no: on });
        if (!sale) { const l = ledgers.get(c.id); l[0].reason = 'manual_issue'; l[0].note = a.p_note; }
        out.push(view(c));
      }
      return { ok: true, order_id: on ? on - 15100 + 9000 : null, order_no: on, total: sale ? round2(amount * q) : 0, cards: out, payment: paid ? { payment_id: 990, status: 'paid' } : null, paid, complimentary: !sale };
    },
    admin_set_gift_card_expiry: (a) => { const c = find(a); if (!/^\d{4}-\d{2}-\d{2}$/.test(String(a.p_valid_to))) throw err('invalid_date', 'Virheellinen päivämäärä'); const old = c.valid_to; c.valid_to = a.p_valid_to;
      if (c.status === 'active' || c.status === 'expired') c.status = c.valid_to < today ? 'expired' : (c.balance > 0 ? 'active' : 'used');
      log(c.id, { delta: 0, reason: 'expiry_change', balance_after: c.balance, old_valid_to: old, new_valid_to: c.valid_to, note: a.p_note || null });
      expiryLogs.set(c.id, [...(expiryLogs.get(c.id) || []), { at: `${today}T09:00:00Z`, old_valid_to: old, new_valid_to: c.valid_to, note: a.p_note || null, by: 'Mock Admin' }]); return { ok: true, card: view(c) }; },
    admin_adjust_gift_card: (a) => { const c = find(a); const r = String(a.p_reason || '').trim(); if (r.length < 3 || r.length > 500) throw err('invalid_param', 'Syy 3–500 merkkiä'); if (!a.p_delta || !Number.isFinite(+a.p_delta)) throw err('invalid_amount', 'Virheellinen summa');
      const nb = round2(c.balance + +a.p_delta); if (nb < 0) throw err('balance_below_zero', 'Saldo ei voi mennä alle nollan'); c.balance = nb;
      if (a.p_mark_verified) { c.balance_verified = true; if (c.status === 'pending_verification') c.status = nb === 0 ? 'used' : c.valid_to && c.valid_to < today ? 'expired' : 'active'; } else if (c.status === 'used' && nb > 0) c.status = 'active'; else if (c.status === 'active' && nb === 0) c.status = 'used';
      log(c.id, { delta: +a.p_delta, reason: 'adjust', balance_after: nb, note: r }); return { ok: true, card: view(c) }; },
    admin_deactivate_gift_card: (a) => { const c = find(a); const r = String(a.p_reason || '').trim(); if (r.length < 3) throw err('invalid_param', 'Syy 3–500 merkkiä'); c.status = 'cancelled'; log(c.id, { delta: 0, reason: 'cancel', balance_after: c.balance, note: r }); return { ok: true, card: view(c) }; },
    admin_reactivate_gift_card: (a) => { const c = find(a); const r = String(a.p_reason || '').trim(); if (r.length < 3) throw err('invalid_param', 'Syy 3–500 merkkiä'); if (!c.activated_at) throw err('gift_card_not_paid', 'Maksamatonta ostoa ei voi aktivoida');
      c.status = c.balance <= 0 ? 'used' : c.valid_to && c.valid_to < today ? 'expired' : 'active'; log(c.id, { delta: 0, reason: 'reactivate', balance_after: c.balance, note: r }); return { ok: true, card: view(c) }; },
    // §13.12: koodin luokitus. Mock peilaa palvelinta: oma kortti (ei peruttu / maksamaton) → own; muuten unknown + ehdotus koodin muodosta (_vc_guess).
    public_resolve_gift_code: (a) => {
      const n = norm(a.p_code); if (n.length < 6 || n.length > 24) throw err('invalid_code', 'Tarkista koodi');
      if (cards.some((c) => norm(c.code) === n && c.status !== 'cancelled' && c.status !== 'pending_payment')) return { ok: true, kind: 'own' };
      const g = /^KK[0-9]{5}[A-Z]{6}$/.test(n) ? ['kokemuskauppa', 'high'] : /^OK[0-9]{5}[A-Z]{3}$/.test(n) ? ['offerilla', 'high'] : /^[A-Z0-9]{12}$/.test(n) && /[^3479ACEFHJKLMNPRTUVWXY]/.test(n) ? ['elamyslahjat', 'medium'] : [null, null];
      return { ok: true, kind: 'unknown', partner_claims_enabled: sett.claims_enabled !== false, suggested_source: g[0], suggestion_confidence: g[1], sources: ['elamyslahjat', 'kokemuskauppa', 'kiitoskauppa', 'offerilla'].map((code) => ({ code, label: code, label_en: code })) };
    },
    admin_redeem_gift_card: (a) => {
      if (!sett.redeem_enabled) throw err('redeem_disabled', 'Lunastus ei ole käytössä'); const c = cards.find((x) => norm(x.code) === norm(a.p_code)); if (!c) throw err('gift_card_not_found', 'Lahjakorttia ei löydy');
      if (c.source === 'johku' && !sett.johku_cards_redeemable) throw err('johku_cards_closed', 'Johku-korttien lunastus on suljettu');
      if (c.status === 'cancelled' || c.status === 'pending_payment' || c.status === 'pending_verification') throw err('gift_card_inactive', 'Kortti ei ole käytettävissä');
      if (eff(c) === 'expired') throw err('gift_card_expired', 'Kortti on vanhentunut'); if (c.balance <= 0) throw err('gift_card_empty', 'Saldo on nolla');
      const amt = a.p_amount == null ? c.balance : round2(a.p_amount); if (!(amt > 0)) throw err('invalid_amount', 'Virheellinen summa'); if (amt > c.balance + 0.005) throw err('insufficient_balance', 'Saldo ei riitä');
      c.balance = round2(c.balance - amt); if (c.balance === 0) c.status = 'used'; c.last_used_at = `${today}T12:00:00Z`; const pid = 1000 + ledgerId;
      log(c.id, { delta: -amt, reason: 'redemption', balance_after: c.balance, order_id: +a.p_order_id, payment_id: pid, note: a.p_note || null });
      const accounted = c.accounting_origin !== 'johku' && c.vat_treatment === 'at_redemption';
      return { ok: true, payment_id: pid, amount: amt, order_id: +a.p_order_id, balance: { unpaid: 0 }, gift_card: { id: c.id, code_last4: c.code_last4, balance: c.balance, status: c.status, valid_to: c.valid_to }, receipt_id: accounted ? 1 : null, receipt_no: accounted ? 'K2026-9001' : null, accounted };
    },
  };
  const rpc = async (name, args = {}) => {
    if (delay) await new Promise((r) => setTimeout(r, delay));
    const f = handlers[name]; if (!f) throw Object.assign(new Error(`Could not find the function booking.${name}`), { status: 404, code: 'PGRST202' });
    return f(args);
  };
  return { rpc, today, supported: Object.keys(handlers), state: { cards, ledgers, settings: sett } };
}
