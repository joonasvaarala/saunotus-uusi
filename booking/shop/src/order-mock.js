// Asiakkaan tilaussivun MOCK-PALVELIN (vaihe A): keksitty tilaus muistissa; ei tallenna mitään palvelimelle. Käytössä vain kun osoitteessa on ?mock=1.
// createOrderMock().rpc(nimi, parametrit) vastaa KOODARI_talous_A_D_fi.md -sopimuksen public_*-RPC:itä (nimet, p_-parametrit, vastausrakenteet, virheet {ok:false, code, message}).
import { createGiftMock } from './gift-mock.js';
import { createHoldEngine, isHoldScenario, HOLD_ERRORS, PAY_LATER_METHOD } from './hold-mock.js';
export function createOrderMock({ delay = 0, scenario = '', mpResult = '', giftSettings = {}, holdSeconds = 900, serverSkew = 0, procSeconds = 10, payLaterTest = false, payLaterFail = '', storage = globalThis.sessionStorage, locale = 'fi', today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' }) } = {}) {
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
    upsell: { addons: ADDONS, treatments: [{ product_id: 10, name: 'Saunahoito', name_en: 'Sauna treatment' }] },
    instructions: [],
  };
  const sync = () => { o.total = r2(o.items.reduce((s, i) => s + i.line_total, 0)); o.unpaid = r2(Math.max(0, o.total - o.paid)); o.payment_status = o.unpaid === 0 ? 'paid' : o.paid > 0 ? 'partially_paid' : scenario === 'invoiced' ? 'invoiced' : 'unpaid'; };   // booking_175: ?scenario=invoiced = yrityksen laskulla maksettava tilaus (Laskutettu)
  // Skenaariot lahjakorttinäkymille (?mock=1&scenario=gift|cards|cardspaid|cardsdelivery): gift = maksamatonta jäljellä (Käytä lahjakortti), cards = lahjakorttitilaus maksamatta, cardspaid = maksettu, cardsdelivery = maksettu + toimitusvalinnat (ostajalle / saajalle ajastettu / saajalle lähetetty)
  if (scenario === 'invoiced') { o.customer_kind = 'company'; o.invoice_method = 'einvoice'; o.paid = 0; o.payments = []; o.receipts = []; }
  if (scenario === 'invoice_locked') {
    o.invoice_locked = true; o.can_add = false; o.status = 'pending';
    o.payments.push({ status: 'pending', amount: 999, provider: 'visma_pay', method_label: 'Visma Pay', link_token: '00000000-0000-4000-a000-000000000185', link_path: '/maksa/?p=00000000-0000-4000-a000-000000000185', link_stale: true });
  }
  const giftCards = [];
  if (scenario === 'gift' || scenario === 'claims' || scenario === 'claimsoff' || scenario === 'claimproblem') { o.items = [{ id: 1, name: 'Yleinen saunavuoro', name_en: 'Public sauna session', quantity: 2, line_total: 72, vat_rate: 25.5 }, { id: 2, name: 'Pyyhe', name_en: 'Towel', quantity: 2, line_total: 10, vat_rate: 25.5 }]; o.paid = 20; o.payments[0].amount = 20; o.receipts = []; }
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
  // pay | pay-prod | pay-off = sama maksamaton 40 € tilaus vahvistussivun maksuvalintaa varten (shop-mock.js): MobilePay (mp-skenaarion mukaan) + lahjakortti (HH3A-7CEF-HJKL, saldo 100 €)
  const mpScenario = isHoldScenario(scenario) ? (scenario === 'hold-unavailable' ? 'mp-off' : 'mp-prod') : /^mp(-prod|-off)?$/.test(scenario) ? scenario : /^pay(-prod|-off)?$/.test(scenario) ? scenario.replace('pay', 'mp') : '';
  if (mpScenario) {
    o.items = [{ id: 1, name: 'Yleinen saunavuoro', name_en: 'Public sauna session', quantity: 2, line_total: 40, vat_rate: 25.5 }];
    o.reservations = [o.reservations[0]]; o.reservations[0].addons = []; o.status = 'pending'; o.paid = 0; o.payments = []; o.receipts = []; o.online_payment_enabled = true;
  }
  // Hoitovalinta (booking_50, sopimus §15), skenaariot ?mock=1&scenario=hoito | hoito-valitsematta | hoito-lukittu: Saunahoito-varaus (kb 10). hoito = valittu vihtahoito; hoito-valitsematta = vanha varaus ilman valintaa (option null,
  // option_choices täynnä → "valitsematta" + pyyntö valita); hoito-lukittu = muutosaika umpeutunut (can_change=false). public_change_order_time vaihtaa vain hoitoa (muut parametrit null).
  const OPTION_LABELS = { option_label: 'Valitse hoito', option_label_fi: 'Valitse hoito', option_label_en: 'Choose your treatment' };   // booking_52: public_get_order reservations[].option_label(_fi/_en)
  const OPTION_CHOICES = [{ id: 1, code: 'hunajahoito', name: 'Hunajahoito', name_en: 'Honey treatment', sort_order: 10, description: null, description_en: null, active: true },
    { id: 2, code: 'vihtahoito', name: 'Vihtahoito', name_en: 'Birch whisk treatment', sort_order: 20, description: null, description_en: null, active: true },
    { id: 3, code: 'suolahoito', name: 'Suolahoito', name_en: 'Salt treatment', sort_order: 30, description: null, description_en: null, active: true },
    { id: 4, code: 'turvehoito', name: 'Turvehoito', name_en: 'Peat treatment', sort_order: 40, description: null, description_en: null, active: true }];
  const optJson = (c) => (c ? { id: c.id, code: c.code, name: c.name, name_en: c.name_en } : null);
  const hoito = /^hoito(-valitsematta|-lukittu)?$/.test(scenario) ? scenario : '';
  if (hoito) {
    o.items = [{ id: 1, name: 'Saunahoito', name_en: 'Sauna treatment', quantity: 1, line_total: 99, vat_rate: 25.5 }];
    o.reservations = [{ reservation_id: 601, product_id: 10, product_name: 'Saunahoito', starts_at: `${day(5)}T13:00:00Z`, ends_at: `${day(5)}T14:00:00Z`, persons: 1, status: 'confirmed', addons: [],
      option: hoito === 'hoito-valitsematta' ? null : optJson(OPTION_CHOICES[1]), option_choices: OPTION_CHOICES, ...OPTION_LABELS }];
    o.paid = 0; o.payments = []; o.receipts = []; o.add_until = `${day(5)}T14:00:00Z`; o.change_deadline = `${day(3)}T13:00:00Z`; o.change_hours_before = 48;
    if (hoito === 'hoito-lukittu') { o.can_change = false; o.change_deadline = `${day(-1)}T13:00:00Z`; }
  }
  if (o.reservations.length) {
    o.instructions = [{ id: 1, title: locale === 'en' ? 'Before your visit' : 'Ennen käyntiä',
      short_text: locale === 'en' ? 'Bring a towel.' : 'Ota mukaan pyyhe.', short_rich: false,
      body: locale === 'en' ? 'Sample instruction on the trial page. This is not a real customer message.' : 'Esimerkkiohje kokeilusivulla. Tämä ei ole oikea asiakasviesti.',
      rich: false, delivery_mode: 'order_only', link_url: null }];
  }
  const payOnLoad = (() => { try { return new URLSearchParams(globalThis.location?.search || '').get('pay') || ''; } catch { return ''; } })();
  const mp = { started: false, returning: ['online', 'mobilepay', 'vismapay'].includes(payOnLoad), polls: 0, settled: false };
  const mpMarkPaid = () => {
    const amt = o.unpaid; o.paid = r2(o.paid + amt); o.payments.push({ status: 'paid', amount: amt, paid_at: new Date().toISOString(), method_label: 'Maksa verkossa', link_token: null, link_path: null });
    o.receipts.push({ receipt_no: 'K-2026-000777', kind: 'receipt', issued_at: new Date().toISOString(), token: '9a8b7c6d-1111-4222-8333-444455556677', total: amt }); o.status = 'confirmed'; sync(); mp.settled = true;
  };
  sync();
  // Kassan paikanpito (§17): hold* -skenaariot (hold-mock.js) lisäävät checkout_state-kentät vastauksiin
  const hold = isHoldScenario(scenario) ? createHoldEngine({ scenario, holdSeconds, skew: serverSkew, procSeconds, storage, ctx: { o, sync, mp, mpMarkPaid, r2 } }) : null;
  // booking_149: asiakkaan peruutuspyynnön takaraja kuten palvelimella (aikaisin tuleva vahvistettu varaus − 48 h). ?scenario=peruutus-suljettu = vuoroon alle 48 h (30 h).
  const CANCEL_H = 48;
  if (scenario === 'peruutus-suljettu') {
    const st = Date.now() + 30 * 36e5, len = Date.parse(o.reservations[0].ends_at) - Date.parse(o.reservations[0].starts_at);
    o.reservations = o.reservations.slice(0, 1).map((r) => ({ ...r, starts_at: new Date(st).toISOString(), ends_at: new Date(st + len).toISOString() }));
    o.can_change = false; o.change_deadline = new Date(st - CANCEL_H * 36e5).toISOString(); o.change_hours_before = CANCEL_H;
  }
  const cancelState = () => {
    const act = o.reservations.filter((r) => r.status !== 'cancelled' && Date.parse(r.ends_at) > Date.now());
    const first = act.length ? Math.min(...act.map((r) => Date.parse(r.starts_at))) : null;
    const dl = first == null ? null : first - CANCEL_H * 36e5;
    const open = o.status === 'confirmed' && !o.cancel_request && act.length > 0;
    return { can_request_cancel: open && dl >= Date.now(), cancel_deadline: dl == null ? null : new Date(dl).toISOString(), cancel_hours_before: CANCEL_H, cancel_closed: open && dl < Date.now() };
  };
  const snap = () => { hold?.tick(); return JSON.parse(JSON.stringify({ ok: true, ...o, ...cancelState(), ...(hold ? hold.json() : {}) })); };
  const bad = (code, message) => ({ ok: false, code, message });
  const plOffered = () => !!hold && payLaterTest && hold.json().checkout_state === 'awaiting_payment';
  const withPayLater = (r) => (plOffered() ? { ...r, methods: [...(r.methods || []), PAY_LATER_METHOD] } : r);
  let plFailLeft = payLaterFail;   // plfail=<koodi>: ensimmäinen vahvistus epäonnistuu tällä koodilla (esim. order_expired)
  const PL_MSG = { pay_later_unavailable: 'Maksa myöhemmin -vaihtoehto ei ole käytössä', payment_in_progress: 'Maksu on kesken – odota hetki ja yritä uudelleen', order_expired: 'Varauksen pito on päättynyt', order_cancelled: 'Varaus on peruttu', not_found: 'Tilausta ei löytynyt', rate_limited: 'Liian monta yritystä' };
  function confirmPayLater(token) {   // public_confirm_pay_later (booking_57): sama virhekoodijärjestys kuin palvelimella
    if (!hold || !payLaterTest) return bad('pay_later_unavailable', PL_MSG.pay_later_unavailable);
    if (!token) return bad('not_found', PL_MSG.not_found);
    if (plFailLeft) { const c = plFailLeft; plFailLeft = ''; return bad(c, PL_MSG[c] || 'Virhe'); }
    const st = hold.json().checkout_state;
    if (st === 'confirmed' || st === 'confirmed_unpaid') return { ok: true, pay_later: st === 'confirmed_unpaid', idempotent: true, order_id: 15321, order_no: o.order_no, status: o.status, payment_status: o.payment_status, ...hold.json() };
    if (st === 'processing_payment' || st === 'preliminary') return { ...bad('payment_in_progress', PL_MSG.payment_in_progress), ...hold.json() };
    if (st === 'expired') return { ...bad('order_expired', PL_MSG.order_expired), ...hold.json() };
    if (st === 'cancelled') return { ...bad('order_cancelled', PL_MSG.order_cancelled), ...hold.json() };
    o.status = 'confirmed'; sync();   // pito poistuu, paikka säilyy, maksamatta
    return { ...hold.json(), ok: true, pay_later: true, idempotent: false, order_id: 15321, order_no: o.order_no, status: o.status, payment_status: o.payment_status };
  }
  // Vuosikortti (booking_142), skenaariot ?mock=1&scenario=annual | annualpending: vuosikortin ostotilaus; annual = maksettu ja koodi myönnetty, annualpending = maksamatta (koodi näkyy maksun jälkeen)
  const annualSc = /^annual(pending)?$/.test(scenario) ? scenario : '';
  if (annualSc) {
    const paid = annualSc === 'annual';
    o.items = [{ id: 1, name: 'Vuosikortti', name_en: 'Annual card', quantity: 1, line_total: 290, vat_rate: 25.5 }];
    o.reservations = []; o.can_add = false; o.can_change = false; o.change_deadline = null; o.add_until = null; o.upsell = { addons: [], treatments: [] };
    o.paid = paid ? 290 : 0; o.payments = paid ? [{ status: 'paid', amount: 290, paid_at: `${day(-1)}T10:00:00Z`, method_label: 'Korttimaksu', link_token: null, link_path: null }] : [];
    o.receipts = paid ? [{ receipt_no: 'K-2026-000142', kind: 'receipt', issued_at: `${day(-1)}T10:00:00Z`, token: '9a8b7c6d-1111-4222-8333-444455550142', total: 290 }] : [];
  }
  const onlinePayMethod = (token, test) => ({ code: 'online', kind: 'online', provider: 'montonio', label: 'Maksa verkossa', label_en: 'Pay online', test,
    choices: [
      { method: 'paymentInitiation', label: 'Verkkopankki', label_en: 'Online bank' },
      { method: 'cardPayments', label: 'Kortti', label_en: 'Card' },
      { method: 'applePay', label: 'Apple Pay', label_en: 'Apple Pay' },
      { method: 'googlePay', label: 'Google Pay', label_en: 'Google Pay' },
      { method: 'mobilePay', label: 'MobilePay', label_en: 'MobilePay' }],
    start: { function: 'montonio-start', method: 'POST', body: { order_token: token } } });
  const handlers = {
    public_annual_card_purchase_code: () => !annualSc ? { ok: true, has_card: false, code: null }
      : annualSc === 'annual' ? { ok: true, has_card: true, code: 'KUUSI482', valid_from: day(-1), valid_to: day(363), active: true } : { ok: true, has_card: true, code: null },
    public_get_order: ({ p_token }) => {
      if (mp.returning && mpResult === 'netfail') throw new TypeError('Failed to fetch');
      if (mp.returning && !mp.settled && ['paid', 'review'].includes(mpResult || 'paid') && ++mp.polls >= 3) mpMarkPaid();
      const row = p_token === TOKEN || p_token ? snap() : bad('not_found', 'Tilausta ei löytynyt');
      if (row?.ok && mp.returning && mpResult === 'failed' && !mp.settled) row.payment_status = 'failed';
      return row;
    },
    // booking_57: pay_later (testi) vain pitoskenaarioissa, kun testui != 0 ja tilaus odottaa maksua (kuten palvelin: lippu päällä + awaiting_payment)
    public_payment_options: ({ p_token }) => withPayLater(mpScenario && mpScenario !== 'mp-off'
      ? { ok: true, online_enabled: true, methods: [onlinePayMethod(p_token, mpScenario !== 'mp-prod')],
        order: { order_no: o.order_no, status: o.status, payment_status: o.payment_status, unpaid: o.unpaid, can_pay_online: o.unpaid > 0 && ['pending', 'confirmed'].includes(o.status), mobilepay_pending: mp.started && o.unpaid > 0 } }
      : { ok: true, online_enabled: false, methods: [] }),
    public_confirm_pay_later: ({ p_order_token }) => confirmPayLater(p_order_token),
    // §14.7 (booking_52): kassan maksutavat ilman tokenia; MobilePay mp-skenaarion mukaan, lahjakortti gift-mockin redeem_enabled-asetuksesta
    public_checkout_payment_options: () => {
      const mpOn = !!mpScenario && mpScenario !== 'mp-off', gc = !!gm.handlers.public_gift_card_packages().redeem_enabled;
      return { ok: true, mobilepay_enabled: false, online_enabled: mpOn, gift_card_redeem_enabled: gc, ...(hold ? { hold_until_paid: true, hold_minutes: 15, group_threshold_persons: 0, group_hold_days: 7 } : {}), methods: [
        ...(mpOn ? [onlinePayMethod('<tilauksen public_token>', mpScenario !== 'mp-prod')] : []),
        ...(gc ? [{ code: 'gift_card', kind: 'redeem', provider: 'gift_card', label: 'Lahjakortti', label_en: 'Gift card', test: false, check_rpc: 'public_check_gift_card', apply_rpc: 'public_apply_gift_card' }] : [])] };
    },
    // public_get_booking (vain pitotilassa; vahvistussivu käyttää shop-mock.js:n omaa): pidon tila + payment_methods (myös perutut maksut → lahjakortti käytetty)
    ...(hold ? { public_get_booking: () => ({ ...snap(), payment_methods: hold.methods() }) } : {}),
    public_add_to_order: ({ p_items }) => {
      if (o.invoice_locked) return bad('order_invoiced', 'Tilaus on laskutettu, eikä sen rivejä voi enää muuttaa verkossa. Ota yhteyttä henkilökuntaan.');
      if (!o.can_add) return bad('order_closed', 'Lisäysaika on päättynyt');
      if (!Array.isArray(p_items) || !p_items.length) return bad('invalid_items', 'Ei rivejä');
      let added = 0;
      for (const it of p_items) {
        if (it.type === 'reservation') {   // varausrivin lisäys (§15): Saunahoito vaatii option_code:n; virheet kuten palvelimella
          if (+it.product_id !== 10) return bad('item_not_found', 'Tuotetta ei löytynyt');
          const code = String(it.option_code ?? '').trim().toLowerCase(), c = OPTION_CHOICES.find((x) => x.code === code);
          if (!code) return bad('option_required', 'Valitse hoito');
          if (!c) return bad('invalid_option', 'Valittu hoito ei kelpaa');
          o.items.push({ id: 100 + o.items.length, name: 'Saunahoito', name_en: 'Sauna treatment', quantity: 1, line_total: 99, vat_rate: 25.5 });
          o.reservations.push({ ...OPTION_LABELS, reservation_id: 700 + o.reservations.length, product_id: 10, product_name: 'Saunahoito', starts_at: it.start, ends_at: new Date(Date.parse(it.start) + 36e5).toISOString(), persons: +it.persons || 1, status: 'confirmed', addons: [], option: optJson(c), option_choices: OPTION_CHOICES });
          added += 99; continue;
        }
        const a = ADDONS.find((x) => x.id === it.addon_id || x.code === it.code); if (it.type !== 'addon' || !a) return bad('item_not_found', 'Lisäpalvelua ei löytynyt');
        const q = Math.max(1, Math.trunc(+it.quantity) || 1); if (q > a.max) return bad('invalid_items', `Enintään ${a.max}`);
        const line = r2(a.price * q); added += line; o.items.push({ id: 100 + o.items.length, name: a.name, name_en: a.name_en, quantity: q, line_total: line, vat_rate: 25.5 });
        const res = o.reservations.find((x) => x.reservation_id === it.reservation_id) || o.reservations[0]; res?.addons.push({ name: a.name, name_en: a.name_en, quantity: q });
      }
      sync();
      return { ok: true, mock: true, added_total: r2(added), balance: { total: o.total, paid: o.paid, unpaid: o.unpaid }, payment: null, online_payment_enabled: false };
    },
    public_change_order_time: ({ p_reservation_id, p_start, p_rule_id, p_date, p_persons, p_option_code }) => {
      if (!o.can_change) return bad('change_too_late', 'Muutosaika on päättynyt');
      const res = o.reservations.find((x) => x.reservation_id === p_reservation_id); if (!res) return bad('not_found', 'Varausta ei löytynyt');
      if (o.invoice_locked && p_persons != null && +p_persons !== res.persons) return bad('order_invoiced', 'Tilaus on laskutettu, eikä sen rivejä voi enää muuttaa verkossa. Ota yhteyttä henkilökuntaan.');
      const code = String(p_option_code ?? '').trim().toLowerCase();
      if (!code && p_start == null && p_rule_id == null && p_date == null && p_persons == null) return bad('invalid_change', 'Ei muutettavaa');
      if (p_start != null || p_rule_id != null || p_date != null || p_persons != null) return bad('invalid_change', 'Mock tukee vain hoidon vaihtoa');
      const c = OPTION_CHOICES.find((x) => x.code === code);
      if (!res.option_choices?.length) return bad('invalid_option', 'Tällä tuotteella ei ole vaihtoehtoja');
      if (!c) return bad('invalid_option', 'Valittu hoito ei kelpaa');
      res.option = optJson(c);
      return { ok: true, mock: true, order_no: o.order_no, starts_at: res.starts_at, ends_at: res.ends_at, persons: res.persons, total: o.total, price_diff: 0, payment: null, balance: { total: o.total, paid: o.paid, unpaid: o.unpaid }, online_payment_enabled: false, option: res.option };
    },
    public_request_cancel: ({ p_reason }) => { if (o.cancel_request) return bad('request_exists', 'Peruutuspyyntö on jo lähetetty'); if (cancelState().cancel_closed) return bad('cancel_too_late', `Peruutus ei ole enää mahdollinen, koska vuoron alkuun on alle ${CANCEL_H} tuntia.`); o.cancel_request = { status: 'open', created_at: new Date().toISOString(), reason: p_reason || null }; return { ok: true, mock: true }; },
    public_get_receipt: ({ p_order_token, p_receipt_no }) => {
      const r = o.receipts.find((x) => x.receipt_no === p_receipt_no); if (!r) return bad('receipt_not_found', 'Kuittia ei löytynyt');
      return { ok: true, mock: true, id: 1, receipt_no: r.receipt_no, kind: r.kind, issued_at: r.issued_at, total_gross: r.total, snapshot: null, public_token: r.token, pdf_url: null, sent_at: r.issued_at,
        text_body: `ESIMERKKIKUITTI (mock)\nKuitti ${r.receipt_no}\nTilaus #${o.order_no}\nYhteensä ${r.total} €\n` };
    },
  };
  // Lahjakorttien julkiset RPC:t samalla tilauksella (public_apply_gift_card muuttaa tilausta)
  // Skenaariot kumppanilahjakorteille (?mock=1&scenario=…): claims = kolme pyyntöä (vastaanotettu, ongelma invalid_code, lunastettu), claimproblem = yksi ongelmapyyntö, claimsoff = kumppanilunastus pois päältä (voucher_claims.enabled=false)
  const claimSeed = scenario === 'claims' ? [{ source: 'kokemuskauppa', status: 'open', code: 'KK12345ABCDEF' }, { source: 'elamyslahjat', status: 'problem', problem_code: 'invalid_code', code: 'ZXQW98765432' }, { source: 'offerilla', status: 'redeemed', amount: 40, code: 'OK19123ABC' }]
    : scenario === 'claimproblem' ? [{ source: 'elamyslahjat', status: 'problem', problem_code: 'invalid_code', code: 'ZXQW98765432' }] : [];
  const gm = createGiftMock({ today, settings: { ...(scenario === 'claimsoff' ? { claims_enabled: false } : {}), ...(scenario === 'hold-unavailable' ? { redeem_enabled: false } : {}), ...(claimSeed.length ? { claims_seed: claimSeed } : {}), ...giftSettings }, order: {
    hasGiftCards: () => giftCards.length > 0, unpaid: () => o.unpaid, status: () => o.status, orderNo: o.order_no, paymentStatus: () => o.payment_status,
    pay: (amt, c) => { o.paid = r2(o.paid + amt); o.payments.push({ status: 'paid', amount: amt, paid_at: new Date().toISOString(), method_label: 'Lahjakortti', link_token: null, link_path: null }); sync(); if (o.unpaid === 0 && o.status === 'pending') o.status = 'confirmed'; void c; return { total: o.total, paid: o.paid, unpaid: o.unpaid }; },
    giftCardList: () => giftCards.map(({ code, balance, greeting, ...c }) => c), cardByToken: (t) => { const c = giftCards.find((x) => x.token === t); return c ? { ...c, public_token: c.token } : null; },
  } });
  for (const k of ['public_gift_card_packages', 'public_check_gift_card', 'public_apply_gift_card', 'public_get_order_gift_cards', 'public_get_gift_card', 'public_resolve_gift_code', 'public_submit_voucher_claim', 'public_get_order_voucher_claims', 'public_update_voucher_claim_code']) handlers[k] = gm.handlers[k];
  async function rpc(name, args = {}) {
    await wait(); hold?.tick();
    if (hold && name === 'public_apply_gift_card' && hold.guard()) { const c = hold.guard(); return bad(c, HOLD_ERRORS[c]); }
    const h = handlers[name]; if (!h) throw Object.assign(new Error(`Could not find the function booking.${name} in the schema cache`), { status: 404, code: 'PGRST202' });
    return h(args);
  }
  // Edge-funktioiden mock (fetch-yhteensopiva): mobilepay-start → redirect_url (takaisin tälle sivulle ?pay=mobilepay), mobilepay-notify {action:'reconcile'} → results[]
  const res = (status, body) => ({ ok: status < 400, status, text: async () => JSON.stringify(body) });
  async function mpFetch(url, init = {}) {
    await wait();
    const name = String(url).split('?')[0].split('/').pop(); let body = {}; try { body = JSON.parse(init.body || '{}'); } catch { /* tyhjä */ }
    if (name === 'montonio-start' || name === 'mobilepay-start') {
      const payFlag = name === 'montonio-start' ? 'online' : 'mobilepay';
      if (mpResult === 'neterror') throw new TypeError('Failed to fetch');
      if (mpResult === 'starterror') return res(503, bad('provider_error', 'MobilePay-maksun aloitus epäonnistui, yritä hetken kuluttua uudelleen'));
      hold?.tick(); if (hold?.guard()) { const c = hold.guard(); return res(409, bad(c, HOLD_ERRORS[c])); }
      if (o.unpaid <= 0) return res(409, bad('already_paid', 'Tilaus on jo maksettu'));
      mp.started = true;
      const here = new URL(typeof location !== 'undefined' ? location.href : 'http://localhost/tilaus/'); const back = new URL(here.href);
      const keep = {}; for (const k of ['mpinterval', 'mpmax']) if (here.searchParams.has(k)) keep[k] = here.searchParams.get(k);
      back.search = new URLSearchParams({ t: body.order_token || body.link_token || TOKEN, mock: '1', scenario, ...(mpResult ? { mpresult: mpResult } : {}), ...keep, pay: payFlag }).toString();
      /* Vahvistussivulla token on hashissa: säilytä se (tilaussivulla hash on tyhjä). */
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
  return { rpc, mpFetch, token: TOKEN, giftMock: gm, hold };
}
