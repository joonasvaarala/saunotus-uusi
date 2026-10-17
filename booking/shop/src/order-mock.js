// Asiakkaan tilaussivun MOCK-PALVELIN (vaihe A): keksitty tilaus muistissa; ei tallenna mitään palvelimelle. Käytössä vain kun osoitteessa on ?mock=1.
// createOrderMock().rpc(nimi, parametrit) vastaa KOODARI_talous_A_D_fi.md -sopimuksen public_*-RPC:itä (nimet, p_-parametrit, vastausrakenteet, virheet {ok:false, code, message}).
import { createGiftMock } from './gift-mock.js';
export function createOrderMock({ delay = 0, scenario = '', mpResult = '', giftSettings = {}, locale = 'fi', today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' }) } = {}) {
  const day = (n) => { const d = new Date(`${today}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
  const wait = () => (delay ? new Promise((ok) => setTimeout(ok, delay)) : Promise.resolve());
  const r2 = (n) => Math.round(n * 100) / 100;
  const ADDONS = [{ id: 1, code: 'saunavihta', name: 'Saunavihta', name_en: 'Sauna whisk (vihta)', price: 5, max: 4 }, { id: 2, code: 'pyyhe', name: 'Pyyhe', name_en: 'Towel', price: 5, max: 4 },
    { id: 3, code: 'turvenaamio_jalkakylpy', name: 'Turvenaamio ja jalkakylpy', name_en: 'Peat mask and foot bath', price: 12, max: 2 }];
  const TOKEN = '3f2b8c1e-5a7d-4e9f-8b6a-1c2d3e4f5a6b';
  const o = {
    order_no: 15321, status: 'confirmed', created_at: `${day(-2)}T09:30:00Z`, currency: 'EUR', locale, first_name: 'Esimerkki', customer_kind: 'private',
    items: [{ id: 1, name: 'Yleinen saunavuoro', name_en: 'Public sauna session', quantity: 2, line_total: 36, vat_rate: 25.5 }, { id: 2, name: 'Pyyhe', name_en: 'Towel', quantity: 2, line_total: 10, vat_rate: 25.5 }, { id: 3, name: 'Savusaunahoito', name_en: 'Smoke sauna treatment', quantity: 1, line_total: 85, vat_rate: 25.5 }],
    reservations: [
      { reservation_id: 501, product_id: 1, product_name: 'Yleinen saunavuoro', starts_at: `${day(3)}T11:00:00Z`, ends_at: `${day(3)}T12:30:00Z`, persons: 2, status: 'confirmed', addons: [{ name: 'Pyyhe', quantity: 2 }] },
      { reservation_id: 502, product_id: 4, product_name: 'Savusaunahoito', starts_at: `${day(3)}T13:00:00Z`, ends_at: `${day(3)}T14:00:00Z`, persons: 1, status: 'confirmed', addons: [] }],
    paid: 60, payments: [{ status: 'paid', amount: 60, paid_at: `${day(-2)}T09:40:00Z`, method_label: 'Korttimaksu', link_token: null, link_path: null }],
    receipts: [{ receipt_no: 'K-2026-000321', kind: 'receipt', issued_at: `${day(-2)}T09:40:00Z`, token: '9a8b7c6d-1111-4222-8333-444455556666', total: 60 }],
    can_add: true, add_until: `${day(3)}T14:00:00Z`, can_change: true, change_deadline: `${day(2)}T11:00:00Z`, change_hours_before: 24, cancel_request: null, online_payment_enabled: false,
    upsell: { addons: ADDONS, treatments: [] },
  };
  const sync = () => { o.total = r2(o.items.reduce((s, i) => s + i.line_total, 0)); o.unpaid = r2(Math.max(0, o.total - o.paid)); o.payment_status = o.unpaid === 0 ? 'paid' : o.paid > 0 ? 'partially_paid' : 'unpaid'; };
  // Skenaariot lahjakorttinäkymille (?mock=1&scenario=gift|cards|cardspaid|cardsdelivery): gift = maksamatonta jäljellä (Käytä lahjakortti), cards = lahjakorttitilaus maksamatta, cardspaid = maksettu, cardsdelivery = maksettu + toimitusvalinnat (ostajalle / saajalle ajastettu / saajalle lähetetty)
  const giftCards = [];
  if (scenario === 'gift') { o.items = [{ id: 1, name: 'Yleinen saunavuoro', name_en: 'Public sauna session', quantity: 2, line_total: 72, vat_rate: 25.5 }, { id: 2, name: 'Pyyhe', name_en: 'Towel', quantity: 2, line_total: 10, vat_rate: 25.5 }]; o.paid = 20; o.payments[0].amount = 20; o.receipts = []; }
  if (scenario === 'cards' || scenario === 'cardspaid' || scenario === 'cardsdelivery') {
    const paid = scenario !== 'cards';
    o.items = [{ id: 1, name: 'Avoin lahjakortti', name_en: 'Open gift card', quantity: 1, line_total: 75, vat_rate: 25.5 }, { id: 2, name: 'Saunahoito kahdelle', name_en: 'Sauna treatment for two', quantity: 1, line_total: 192, vat_rate: 25.5 }];
    o.reservations = []; o.receipts = []; o.can_add = false; o.can_change = false; o.change_deadline = null; o.add_until = null; o.upsell = { addons: [], treatments: [] };
    o.paid = paid ? 267 : 0; o.payments = paid ? [{ status: 'paid', amount: 267, paid_at: `${day(-1)}T10:00:00Z`, method_label: 'Käteinen', link_token: null, link_path: null }] : [];
    giftCards.push({ token: '00000000-0000-4000-8000-000000000001', package_code: 'open', package_name: 'Avoin lahjakortti', amount: 75, status: paid ? 'active' : 'pending_payment', valid_to: paid ? day(180) : null, recipient_name: 'Mikko Mallikas', ready: paid, code: 'HH3A7CEFHJKL', balance: 75, greeting: 'Hyvää syntymäpäivää! Nauti saunasta.', delivery_to: 'buyer', deliver_on: null, deliver_time: null, delivered_at: null },
      { token: '00000000-0000-4000-8000-000000000002', package_code: 'sauna_treatment_2', package_name: 'Saunahoito kahdelle', amount: 192, status: paid ? 'active' : 'pending_payment', valid_to: paid ? day(180) : null, recipient_name: null, ready: paid, code: 'HH7MRTUVWXY3', balance: 192, greeting: null, delivery_to: 'buyer', deliver_on: null, deliver_time: null, delivered_at: null });
    if (scenario === 'cardsdelivery') {
      o.items.push({ id: 3, name: 'Avoin lahjakortti', name_en: 'Open gift card', quantity: 2, line_total: 100, vat_rate: 25.5 }); o.paid = 367; o.payments[0].amount = 367;
      giftCards.push({ token: '00000000-0000-4000-8000-000000000003', package_code: 'open', package_name: 'Avoin lahjakortti', amount: 50, status: 'active', valid_to: day(180), recipient_name: 'Sanna Saaja', ready: true, code: 'HH5KLMNPQRST', balance: 50, greeting: 'Hauskaa joulua!', delivery_to: 'recipient', deliver_on: day(30), deliver_time: '18:30', delivered_at: null },
        { token: '00000000-0000-4000-8000-000000000004', package_code: 'open', package_name: 'Avoin lahjakortti', amount: 50, status: 'active', valid_to: day(180), recipient_name: 'Pekka Saaja', ready: true, code: 'HH6UVWXYZ234', balance: 50, greeting: null, delivery_to: 'recipient', deliver_on: null, deliver_time: null, delivered_at: `${day(-1)}T10:05:00Z` });
    }
  }
  // MobilePay (§14), skenaariot ?mock=1&scenario=mp|mp-prod|mp-off: maksamaton tilaus (40 €), public_payment_options antaa MobilePay-tavan (mp: test=true, mp-prod: test=false, mp-off: ei tapaa).
  // Paluutulos (?mpresult=paid|review|failed|pending|slotlost|contact|netfail; oletus paid): mpFetch vastaa mobilepay-start / mobilepay-notify (reconcile) -funktioiden muodoilla; maksu kirjautuu 3. public_get_order-kyselyllä paluun jälkeen (kuten webhook).
  const mpScenario = /^mp(-prod|-off)?$/.test(scenario) ? scenario : '';
  if (mpScenario) {
    o.items = [{ id: 1, name: 'Yleinen saunavuoro', name_en: 'Public sauna session', quantity: 2, line_total: 40, vat_rate: 25.5 }];
    o.reservations = [o.reservations[0]]; o.reservations[0].addons = []; o.status = 'pending'; o.paid = 0; o.payments = []; o.receipts = []; o.online_payment_enabled = true;
  }
  const mp = { started: false, returning: false, polls: 0, settled: false };
  const mpMarkPaid = () => {
    const amt = o.unpaid; o.paid = r2(o.paid + amt); o.payments.push({ status: 'paid', amount: amt, paid_at: new Date().toISOString(), method_label: 'MobilePay', link_token: null, link_path: null });
    o.receipts.push({ receipt_no: 'K-2026-000777', kind: 'receipt', issued_at: new Date().toISOString(), token: '9a8b7c6d-1111-4222-8333-444455556677', total: amt }); o.status = 'confirmed'; sync(); mp.settled = true;
  };
  sync();
  const snap = () => JSON.parse(JSON.stringify({ ok: true, ...o }));
  const bad = (code, message) => ({ ok: false, code, message });
  const handlers = {
    public_get_order: ({ p_token }) => {
      if (mp.returning && mpResult === 'netfail') throw new TypeError('Failed to fetch');
      if (mp.returning && !mp.settled && ['paid', 'review'].includes(mpResult || 'paid') && ++mp.polls >= 3) mpMarkPaid();
      return p_token === TOKEN || p_token ? snap() : bad('not_found', 'Tilausta ei löytynyt');
    },
    public_payment_options: ({ p_token }) => (mpScenario && mpScenario !== 'mp-off'
      ? { ok: true, online_enabled: true, methods: [{ code: 'mobilepay', provider: 'vipps_mobilepay', label: 'MobilePay', label_en: 'MobilePay', test: mpScenario !== 'mp-prod', start: { function: 'mobilepay-start', method: 'POST', body: { order_token: p_token } } }],
        order: { order_no: o.order_no, status: o.status, payment_status: o.payment_status, unpaid: o.unpaid, can_pay_online: o.unpaid > 0 && ['pending', 'confirmed'].includes(o.status), mobilepay_pending: mp.started && o.unpaid > 0 } }
      : { ok: true, online_enabled: false, methods: [] }),
    public_add_to_order: ({ p_items }) => {
      if (!o.can_add) return bad('order_closed', 'Lisäysaika on päättynyt');
      if (!Array.isArray(p_items) || !p_items.length) return bad('invalid_items', 'Ei rivejä');
      let added = 0;
      for (const it of p_items) {
        const a = ADDONS.find((x) => x.id === it.addon_id || x.code === it.code); if (it.type !== 'addon' || !a) return bad('item_not_found', 'Lisäpalvelua ei löytynyt');
        const q = Math.max(1, Math.trunc(+it.quantity) || 1); if (q > a.max) return bad('invalid_items', `Enintään ${a.max}`);
        const line = r2(a.price * q); added += line; o.items.push({ id: 100 + o.items.length, name: a.name, name_en: a.name_en, quantity: q, line_total: line, vat_rate: 25.5 });
        const res = o.reservations.find((x) => x.reservation_id === it.reservation_id) || o.reservations[0]; res?.addons.push({ name: a.name, name_en: a.name_en, quantity: q });
      }
      sync();
      return { ok: true, mock: true, added_total: r2(added), balance: { total: o.total, paid: o.paid, unpaid: o.unpaid }, payment: null, online_payment_enabled: false };
    },
    public_request_cancel: ({ p_reason }) => { if (o.cancel_request) return bad('request_exists', 'Peruutuspyyntö on jo lähetetty'); o.cancel_request = { status: 'open', created_at: new Date().toISOString(), reason: p_reason || null }; return { ok: true, mock: true }; },
    public_get_receipt: ({ p_order_token, p_receipt_no }) => {
      const r = o.receipts.find((x) => x.receipt_no === p_receipt_no); if (!r) return bad('receipt_not_found', 'Kuittia ei löytynyt');
      return { ok: true, mock: true, id: 1, receipt_no: r.receipt_no, kind: r.kind, issued_at: r.issued_at, total_gross: r.total, snapshot: null, public_token: r.token, pdf_url: null, sent_at: r.issued_at,
        text_body: `ESIMERKKIKUITTI (mock)\nKuitti ${r.receipt_no}\nTilaus #${o.order_no}\nYhteensä ${r.total} €\n` };
    },
  };
  // Lahjakorttien julkiset RPC:t samalla tilauksella (public_apply_gift_card muuttaa tilausta)
  const gm = createGiftMock({ today, settings: giftSettings, order: {
    hasGiftCards: () => giftCards.length > 0, unpaid: () => o.unpaid, orderNo: o.order_no, paymentStatus: () => o.payment_status,
    pay: (amt, c) => { o.paid = r2(o.paid + amt); o.payments.push({ status: 'paid', amount: amt, paid_at: new Date().toISOString(), method_label: 'Lahjakortti', link_token: null, link_path: null }); sync(); if (o.unpaid === 0 && o.status === 'pending') o.status = 'confirmed'; void c; return { total: o.total, paid: o.paid, unpaid: o.unpaid }; },
    giftCardList: () => giftCards.map(({ code, balance, greeting, ...c }) => c), cardByToken: (t) => { const c = giftCards.find((x) => x.token === t); return c ? { ...c, public_token: c.token } : null; },
  } });
  for (const k of ['public_gift_card_packages', 'public_check_gift_card', 'public_apply_gift_card', 'public_get_order_gift_cards', 'public_get_gift_card']) handlers[k] = gm.handlers[k];
  async function rpc(name, args = {}) {
    await wait();
    const h = handlers[name]; if (!h) throw Object.assign(new Error(`Could not find the function booking.${name} in the schema cache`), { status: 404, code: 'PGRST202' });
    return h(args);
  }
  // Edge-funktioiden mock (fetch-yhteensopiva): mobilepay-start → redirect_url (takaisin tälle sivulle ?pay=mobilepay), mobilepay-notify {action:'reconcile'} → results[]
  const res = (status, body) => ({ ok: status < 400, status, text: async () => JSON.stringify(body) });
  async function mpFetch(url, init = {}) {
    await wait();
    const name = String(url).split('?')[0].split('/').pop(); let body = {}; try { body = JSON.parse(init.body || '{}'); } catch { /* tyhjä */ }
    if (name === 'mobilepay-start') {
      if (mpResult === 'neterror') throw new TypeError('Failed to fetch');
      if (mpResult === 'starterror') return res(503, bad('provider_error', 'MobilePay-maksun aloitus epäonnistui, yritä hetken kuluttua uudelleen'));
      if (o.unpaid <= 0) return res(409, bad('already_paid', 'Tilaus on jo maksettu'));
      mp.started = true;
      const back = new URL(typeof location !== 'undefined' ? location.href : 'http://localhost/tilaus/'); back.search = new URLSearchParams({ t: body.order_token || TOKEN, mock: '1', scenario, ...(mpResult ? { mpresult: mpResult } : {}), pay: 'mobilepay' }).toString(); back.hash = '';
      return res(200, { ok: true, reuse: false, redirect_url: back.href, reference: 'sauna-o15321-p1-a1', payment_id: 1 });
    }
    if (name === 'mobilepay-notify' && body.action === 'reconcile') {
      mp.returning = true;
      if (mpResult === 'netfail') throw new TypeError('Failed to fetch');
      const r = mpResult || 'paid', one = (outcome, state) => res(200, { ok: true, payment_status: o.payment_status, results: [{ outcome, state }] });
      if (o.payment_status === 'paid') return one(r === 'review' ? 'paid_needs_review' : 'paid', 'CAPTURED');
      if (r === 'failed') return one('not_authorized', 'ABORTED');
      if (r === 'slotlost') return one('cancelled_slot_lost', 'AUTHORIZED');
      if (r === 'contact') return one('capture_failed', 'AUTHORIZED');
      return one('pending', 'CREATED');   // paid/review/pending: asiakas ei ole vielä hyväksynyt / webhook vielä tulossa
    }
    return res(400, bad('invalid_param', 'Virheellinen pyyntö'));
  }
  return { rpc, mpFetch, token: TOKEN, giftMock: gm };
}
