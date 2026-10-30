// Hallinnan kokeilutila (?mock=1) ja testien mock: vastaa selaimessa Päivä-, Varaukset-, Uusi varaus (resurssi)- ja Tuotevalinnat-näkymien RPC:ihin (nimet ja p_-parametrit
// sopimuksen §14/§15 mukaan, rivit samassa muodossa kuin migraatiossa booking_50). KEKSITTYÄ DATAA: mikään ei mene verkkoon eikä tallennu (tila on vain muistissa).
// Puhdas moduuli (ei DOM:ia) → node --test voi ajaa sen. Tuntematon RPC → virhe (ei koskaan verkkokutsua).
import { quietMockHandlers } from './quiet-mock.js';
import { voucherRedeemMockHandlers } from './voucher-redeem-mock.js';
import { fiReference, validBusinessId, validOvt, validOperator, normBusinessId, normOvt } from '../shop/src/invoice-validate.js';
import { storedLineFromInput } from './invoice-lines.js';
import { calendarIdError } from './calendar-export-logic.js';
import { validateMessage } from './messages-logic.js';
import { applySection, exampleBundle } from './settings-logic.js';
import { analyticsMock } from './analytics-mock.js';
import { createEventsMock, EVENT_MOCK_RESOURCES } from './events-mock.js';
import { generatedAnnualCardCode, generatedDiscountCode, normalizeCode } from '../shop/src/discount-code-logic.js';
import { paylinkWatchHandlers } from './paylink-watch-mock.js';
const TZ = 'Europe/Helsinki';
const todayHel = (now = new Date()) => now.toLocaleDateString('sv-SE', { timeZone: TZ });
const addDays = (ds, n) => { const d = new Date(`${ds}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
// "YYYY-MM-DD" + "HH:MM" Helsingin aikaa → ISO (UTC); vastaa ui.js:n helsinkiIso-funktiota
export function helIso(ds, hhmm) {
  const [y, m, d] = ds.split('-').map(Number), [hh, mm] = hhmm.split(':').map(Number);
  let t = Date.UTC(y, m - 1, d, hh, mm);
  for (let i = 0; i < 2; i++) {
    const p = new Intl.DateTimeFormat('sv-SE', { timeZone: TZ, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }).format(new Date(t)).replace(' ', 'T');
    t += Date.UTC(y, m - 1, d, hh, mm) - Date.parse(`${p}:00Z`);
  }
  return new Date(t).toISOString();
}
const err = (code, message) => Object.assign(new Error(message || code), { name: 'ApiError', code, status: 400 });
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/;
function maskEmail(raw) {
  const email = String(raw || '').trim().toLowerCase();
  const at = email.indexOf('@');
  if (at < 1 || !EMAIL_RE.test(email)) return null;
  const local = email.slice(0, at);
  const dom = email.slice(at + 1);
  const dot = dom.lastIndexOf('.');
  const tld = dot >= 0 ? dom.slice(dot) : '';
  return `${local.slice(0, 1)}***@${dom.slice(0, 1)}***${tld}`;
}
const SECRET_KEYS = new Set(['client_id', 'client_secret', 'api_key', 'password', 'token', 'refresh_token', 'access_token', 'secret', 'private_key', 'authorization', 'redirect_uri']);
const SALES_RATES = ['25.5', '13.5', '0', '14', '24', '10'];
const METHODS = ['cash', 'card_terminal', 'mobilepay', 'bank_transfer', 'invoice', 'gift_card', 'partner_voucher_kokemuskauppa', 'partner_voucher_offerilla', 'partner_voucher_elamyslahjat', 'partner_voucher', 'visma_pay', 'annual_card', 'pay_later', 'other'];
const hasSecret = (p) => {
  if (p == null || typeof p !== 'object') return false;
  if (Array.isArray(p)) return p.some(hasSecret);
  return Object.entries(p).some(([k, v]) => SECRET_KEYS.has(String(k).toLowerCase()) || hasSecret(v));
};
const kept = (raw, key, prev, map) => (Object.prototype.hasOwnProperty.call(raw, key) ? map(raw[key]) : (prev ?? ''));
function normalizeProcountor(raw, prev) {
  if (raw == null || typeof raw !== 'object' || Array.isArray(raw)) throw err('invalid_setting', 'Asetusten pitää olla objekti');
  if (hasSecret(raw)) throw err('secrets_not_allowed', 'Salaisuuksia ei tallenneta asetuksiin');
  const mode = String(raw.mode ?? prev.mode ?? 'off');
  if (!['off', 'dry_run', 'live'].includes(mode)) throw err('invalid_setting', 'Tila on off, dry_run tai live');
  let environment = String(raw.environment ?? prev.environment ?? 'pts').toLowerCase();
  if (environment === 'sandbox') environment = 'pts';
  if (environment !== 'pts' && environment !== 'prod') throw err('invalid_setting', 'Ympäristö on pts tai prod');
  const approved = kept(raw, 'approved_by', prev.approved_by, (v) => String(v ?? '').trim());
  if (approved && (approved.length < 3 || approved.length > 80 || approved.startsWith('eyJ'))) throw err('invalid_setting', 'approved_by on nimi ja päivä');
  if (mode === 'live' && !approved) throw err('approval_required', 'live vaatii approved_by');
  const vat = kept(raw, 'vat_status', prev.vat_status, (v) => String(v ?? '').trim());
  if (vat && !/^[0-9]{1,4}$/.test(vat)) throw err('invalid_setting', 'ALV-tila on 1–4 numeroa');
  const prefix = String(raw.api_prefix ?? prev.api_prefix ?? '/supported/api').trim() || '/supported/api';
  if (!/^\/api$|^\/latest\/api$|^\/supported\/api$|^\/v[0-9]{4}\/api$/.test(prefix)) throw err('invalid_setting', 'API-etuliite ei kelpaa');
  const bank = kept(raw, 'bank_account', prev.bank_account, (v) => String(v ?? '').replace(/\s/g, '').toUpperCase());
  if (bank && !/^[A-Z]{2}[0-9]{2}[A-Z0-9]{10,30}$/.test(bank)) throw err('invalid_setting', 'Tilinumero on IBAN tai tyhjä');
  const accounts = raw.accounts || {};
  const rounding = String(accounts.rounding ?? '').trim();
  if (rounding && !/^[0-9A-Za-z]{1,20}$/.test(rounding)) throw err('invalid_setting', 'Tilinumero ei kelpaa');
  const sales = {};
  for (const [k, v] of Object.entries(accounts.sales_by_vat || {})) {
    if (!SALES_RATES.includes(k)) throw err('invalid_setting', 'Tuntematon ALV-kanta');
    const code = String(v ?? '').trim();
    if (code && !/^[0-9A-Za-z]{1,20}$/.test(code)) throw err('invalid_setting', 'Tilinumero ei kelpaa');
    if (code) sales[k] = code;
  }
  const clearing = {};
  for (const [k, v] of Object.entries(accounts.clearing_by_method || {})) {
    if (!METHODS.includes(k)) throw err('invalid_setting', 'Tuntematon maksutapa');
    const code = String(v ?? '').trim();
    if (code && !/^[0-9A-Za-z]{1,20}$/.test(code)) throw err('invalid_setting', 'Tilinumero ei kelpaa');
    if (code) clearing[k] = code;
  }
  if (mode === 'live' && (!/^[0-9]{1,4}$/.test(vat) || Object.keys(sales).length === 0 || Object.keys(clearing).length === 0)) {
    throw err('live_incomplete', 'live vaatii ALV-tilan, myyntitilin ja maksutavan tilin');
  }
  return {
    mode, environment, daily_enabled: raw.daily_enabled === true, api_prefix: prefix, vat_status: vat, approved_by: approved, bank_account: bank,
    accounts: { rounding, sales_by_vat: sales, clearing_by_method: clearing },
  };
}
function procountorStatus(cfg) {
  const sales = Object.values(cfg.accounts?.sales_by_vat || {}).some((v) => String(v).trim());
  const clearing = Object.values(cfg.accounts?.clearing_by_method || {}).some((v) => String(v).trim());
  return {
    ok: true, mode: cfg.mode, environment: cfg.environment, daily_enabled: cfg.daily_enabled === true, api_prefix: cfg.api_prefix,
    accounts_configured: /^[0-9]{1,4}$/.test(cfg.vat_status || '') && sales && clearing,
    bank_account_configured: Boolean(cfg.bank_account), last: null, errors: [],
  };
}
const PERMS = ['bookings.manage', 'bookings.override', 'customers.manage', 'catalog.edit', 'payments.manage', 'payments.refund', 'reports.view', 'settings.edit', 'pos.use', 'invoices.manage', 'giftcards.manage', 'messages.edit'];
const CODE_RE = /^[a-z0-9_]{1,40}$/;

export function createAdminMock({ now = new Date(), delay = 0, perms = PERMS, role = 'manager' } = {}) {
  const today = todayHel(now);
  const st = {
    calls: [], perms: [...perms],
    dayNotes: [], dayBulletins: [], dayMemoSeq: 1, dayBulletinSeq: 1, ownShifts: [], staffShifts: [],
    messagesTimed: false,
    feeRules: [],
    messageSeq: 2,
    messages: [{
      id: 1, name: '[ESIMERKKI EI KÄYTÖSSÄ] Ohje', category: 'instruction', delivery_mode: 'scheduled', active: false,
      subject_fi: '[ESIMERKKI] Ohje', subject_en: '[EXAMPLE] Instructions',
      short_fi: 'Esimerkkipohja, ei käytössä.', short_en: 'Example template, not in use.',
      body_fi: 'Esimerkkipohja, ei käytössä. Täysi ohje.', body_en: 'Example template, not in use.',
      link_url: null, send_amount: 2, send_unit: 'days', send_direction: 'before', send_anchor: 'arrival', product_ids: [],
    }],
    generalSettings: [
      { key: 'business_name', value: 'Havuhattu Oy', is_public: true },
      { key: 'timezone', value: 'Europe/Helsinki', is_public: false },
      { key: 'public_booking_enabled', value: true, is_public: true },
      { key: 'public_payment_mode', value: 'pay_later', is_public: true },
      { key: 'hold_minutes', value: 15, is_public: true },
      { key: 'customer_change_hours_before', value: 48, is_public: true },
      { key: 'business_quote_notify_name', value: 'Joonas', is_public: false },
      { key: 'checkout_company_invoice_enabled', value: true, is_public: false },
      { key: 'gift_cards.redeem_enabled', value: false, is_public: false },
      { key: 'rl_ip_per_10min', value: 12, is_public: false },
      { key: 'public_treatment_horizon_days', value: 14, is_public: false },
      { key: 'invoice_bank', value: '', is_public: false },
      { key: 'invoice_due_days', value: 14, is_public: false },
      { key: 'seller', value: 'Havuhattu', is_public: false },
      { key: 'admin_order_reservation_flow_enabled', value: true, is_public: false },
    ],
    procountor: {
      mode: 'off', environment: 'pts', daily_enabled: false, api_prefix: '/supported/api', vat_status: '', approved_by: '', bank_account: '',
      accounts: { rounding: '', sales_by_vat: {}, clearing_by_method: {} },
    },
    closureCalendarIds: ['sulku-test@group.calendar.google.com'],
    bookingCalendar: {
      mode: 'off', timezone: 'Europe/Helsinki', window_back_days: 7, window_forward_days: 180,
      admin_base_url: '', shared_calendar_id: '', fast_nudge: false, last: null,
      resources: [
        { code: 'savusauna', name: 'Savusauna', calendar_id: '' },
        { code: 'rauni', name: 'Hoitosauna Rauni', calendar_id: '' },
        { code: 'lovi', name: 'Lovi', calendar_id: '' },
      ],
    },
    products: [
      { id: 10, name: 'Saunahoito', name_en: 'Sauna treatment', price: 85, vat_rate: 25.5, active: true, category: 'treatment', description: 'Hoitosauna Rauni', config: { resource_class: 'resourced', lifecycle: 'current', sale_kind: 'other', duration_minutes: 90, min_persons: 1, max_persons: 4, bookable: true, shop_visible: true, public_slots: true, time_window_class: 'therapy', required_skill: 'treatment', audience: 'consumer' } },
      { id: 8, name: 'Rituaali 90 min', price: 64, vat_rate: 25.5, active: true, category: 'ritual', config: { resource_class: 'resourced', lifecycle: 'current', sale_kind: 'other', duration_minutes: 90, min_persons: 1, max_persons: 6, bookable: true, shop_visible: true, public_slots: true, public_weekdays: [6, 7], time_window_class: 'ritual', audience: 'consumer' } },
      { id: 7, name: 'Saunarituaali ja savusaunavuoro (la & su)', name_en: 'Sauna Ritual & Smoke Sauna Session', price: 49, price_type: 'per_person', vat_rate: 25.5, active: true, category: 'ritual', config: { resource_class: 'resourced', lifecycle: 'current', sale_kind: 'other', duration_minutes: 120, min_persons: 1, max_persons: 6, bookable: true, shop_visible: true, public_slots: true, public_weekdays: [6, 7], time_window_class: 'ritual', required_skill: 'yleinen', audience: 'consumer' } },
      { id: 3, name: 'Yleinen saunavuoro', price: 18, vat_rate: 25.5, active: true, category: 'public_sauna', config: { resource_class: 'shift', lifecycle: 'current', sale_kind: 'slots', bookable: true, shop_visible: true, audience: 'consumer' } },
      { id: 31, slug: 'perinnesaunotusilta', name: 'Perinnesaunotusilta', name_en: 'Traditional sauna evening', price: 69, vat_rate: 25.5, active: true, category: 'event', config: { resource_class: 'shift', lifecycle: 'current', sale_kind: 'other', duration_minutes: 180, min_persons: 1, max_persons: 10, bookable: true, shop_visible: true, audience: 'consumer' } },
      { id: 32, slug: 'naisten-joulusauna', name: 'Naisten joulusauna', name_en: 'Women’s Christmas sauna', price: 59, vat_rate: 25.5, active: true, category: 'event', config: { resource_class: 'shift', lifecycle: 'current', sale_kind: 'other', duration_minutes: 150, min_persons: 1, max_persons: 12, bookable: true, shop_visible: true, audience: 'consumer' } },
      { id: 33, slug: 'saunottajakoulutus', name: 'Saunottajakoulutus', name_en: 'Sauna host training', price: 390, vat_rate: 25.5, active: true, category: 'training', config: { resource_class: 'shift', lifecycle: 'current', sale_kind: 'other', duration_minutes: 1980, min_persons: 1, max_persons: 8, bookable: true, shop_visible: false, audience: 'consumer' } },
      { id: 101, name: 'Vichy', name_en: 'Vichy', price: 3, vat_rate: 13.5, active: true, category: 'other', config: { sale_kind: 'other', pos_enabled: true, pos_sort: 10, fridge_sale: true, age_restricted: false, bookable: false, shop_visible: false, audience: 'consumer' } },
      { id: 102, name: 'Sipsit', name_en: 'Crisps', price: 3, vat_rate: 13.5, active: true, category: 'other', config: { sale_kind: 'other', pos_enabled: true, pos_sort: 20, fridge_sale: false, age_restricted: false, bookable: false, shop_visible: false, audience: 'consumer' } },
      { id: 103, name: 'Pyyhevuokra', name_en: 'Towel rental', price: 5, vat_rate: 25.5, active: true, category: 'product_rental', config: { sale_kind: 'other', pos_enabled: true, pos_sort: 30, fridge_sale: false, age_restricted: false, bookable: false, shop_visible: false, audience: 'consumer' } },
      { id: 104, name: 'Lahjakortti', price: 58, vat_rate: 0, active: true, category: 'gift_card', config: { sale_kind: 'other', pos_enabled: false, fridge_sale: false, age_restricted: false, bookable: false, shop_visible: false, audience: 'consumer' } },
      { id: 105, name: 'Käsipyyhe', name_en: 'Hand towel', price: 4, vat_rate: 25.5, active: true, category: 'other', config: { sale_kind: 'other', pos_enabled: false, pos_sort: 40, fridge_sale: false, age_restricted: false, bookable: false, shop_visible: false, audience: 'consumer' } },
      { id: 106, name: 'Olut', name_en: 'Beer', price: 6, vat_rate: 25.5, active: true, category: 'other', config: { sale_kind: 'other', pos_enabled: false, fridge_sale: false, age_restricted: true, bookable: false, shop_visible: false, audience: 'consumer' } },
    ],
    options: [   // product_options (10 = Saunahoito)
      { id: 1, product_id: 10, code: 'hunajahoito', name: 'Hunajahoito', name_en: 'Honey treatment', sort_order: 10, active: true, description: null, description_en: null },
      { id: 2, product_id: 10, code: 'vihtahoito', name: 'Vihtahoito', name_en: 'Birch whisk treatment', sort_order: 20, active: true, description: null, description_en: null },
      { id: 3, product_id: 10, code: 'suolahoito', name: 'Suolahoito', name_en: 'Salt treatment', sort_order: 30, active: true, description: null, description_en: null },
      { id: 4, product_id: 10, code: 'turvehoito', name: 'Turvehoito', name_en: 'Peat treatment', sort_order: 40, active: true, description: null, description_en: null },
    ],
    settings: { 10: { option_required: true, option_label: 'Valitse hoito', option_label_en: 'Choose your treatment' } },
    customers: [{ id: 1, name: 'Aino Testaaja', email: 'aino@example.com', phone: '+358401110001' }, { id: 2, name: 'Eero Esimerkki', email: 'eero@example.com', phone: '+358401110002' }, { id: 3, name: 'Helmi Hiljainen', email: 'helmi@example.com', phone: '+358401110003' }, { id: 4, name: 'Ilmari Iltavuoro', email: 'ilmari@example.com', phone: '+358401110004' }, { id: 5, name: 'Liisa Lasku', email: 'liisa@t112.test', phone: '0401234567', company: 'Koivutesti Oy', customer_kind: 'company', business_id: '1000000-4', address: 'Koivukuja 2', zip: '01300', city: 'Vantaa', marketing_consent: true }],
    // booking_172: Johku-tyyppinen yritystilaus (yhteyshenkilö rekisterissä yksityisenä, yritys vain tilauksen laskutustiedoissa; feikki)
    companyOrders: [
      { customer_id: 2, created_at: '2026-09-01T10:00:00Z', billing: { company: 'Saunaseura Testi Oy', business_id: '1234560-4', name: 'Eero Esimerkki', email: 'laskut@saunaseura.example.test', address: 'Uusi katu 5', zip: '00210', city: 'Helsinki', country: 'FI', einvoice_address: '003712345604', einvoice_operator: 'E204503' } },
      { customer_id: 3, created_at: '2026-08-01T10:00:00Z', billing: { company: 'Nimetön Kioski Ky', name: 'Helmi Hiljainen', address: 'Torikatu 3', zip: '33100', city: 'Tampere', country: 'FI' } },
    ],
    reservations: [], seq: { res: 900, order: 7000, pay: 4000, disc: 10, card: 10 },
    // booking_142: keksityt esimerkkikoodit ja -vuosikortti (vain muistissa)
    discountCodes: [
      { id: 1, code: 'KESA15', description: 'Esimerkki: kesäkampanja', kind: 'percent', value: 15, valid_from: null, valid_to: addDays(today, 60), max_uses: null, used_count: 3, product_ids: null, active: true, target_scope: 'order', usage_type: 'permanent', is_annual_card_code: false, state: 'active' },
      { id: 2, code: 'X7KQ2M', description: 'Esimerkki: hyvitys asiakkaalle', kind: 'fixed', value: 10, valid_from: null, valid_to: null, max_uses: 1, used_count: 0, product_ids: [1], active: true, target_scope: 'product', usage_type: 'single', is_annual_card_code: false, state: 'active' },
      { id: 3, code: 'KUMPPANI-VK', description: 'Esimerkki: yhteinen vuosikorttikoodi', kind: 'percent', value: 100, valid_from: null, valid_to: addDays(today, 200), max_uses: null, used_count: 12, product_ids: [1], active: true, target_scope: 'product', usage_type: 'permanent', is_annual_card_code: true, state: 'active' }],
    annualCards: [{ id: 1, code: 'HONKA417', customer_id: 2, customer_name: 'Eero Esimerkki', customer_email: 'eero@example.com', valid_from: addDays(today, -30), valid_to: addDays(today, 334), active: true, revoked_at: null, notes: null, purchase_order_no: 7001, future_bookings: 1, reservations_count: 1, deletable: false },
      { id: 2, code: 'TS5DSYAH2X', customer_id: 3, customer_name: 'Helmi Hiljainen', customer_email: 'helmi@example.com', valid_from: today, valid_to: addDays(today, 364), active: true, revoked_at: null, notes: 'Esimerkki: myönnetty hallinnasta, käyttämätön', purchase_order_no: null, future_bookings: 0, reservations_count: 0, deletable: true }],
    // Sulkukonflikti (booking_73). Kuittaus ei koske availabilityBlocked-lippua.
    availabilityBlocked: true,
    blockConflicts: [{
      reservation_id: 8801, leg_id: 1, resource_id: 1, block_id: 501, closure_event_id: 90,
      starts_at: helIso(addDays(today, 4), '16:00'), ends_at: helIso(addDays(today, 4), '18:00'),
      block_reason: 'Kalenteri (1 savusauna kiinni): Perinnesaunotusilta',
      closure_reason: 'Perinnesaunotusilta', calendar_name: '1 savusauna kiinni',
    }],
    blockAcks: [],
    posOrders: [],
    posMail: [],
    posCustomers: [],
    posModes: { mobilepay_mode: 'test', vismapay_mode: 'dry_run' },
    resendMode: 'dry_run',
    productQr: [],
    invCustomers: [],
    invoices: [],
    invLog: [],
    invSeq: 0,
    vatRates: [{ rate: 0, label: '0 %', active: true }, { rate: 13.5, label: '13,5 %', active: true }, { rate: 25.5, label: '25,5 %', active: true }, { rate: 24, label: '24 %', active: false }],
    businessId: 1,
  };
  if (role === 'staff') st.perms = st.perms.filter((p) => p !== 'settings.edit');
  if (role === 'admin' && !st.perms.includes('staff.manage')) st.perms.push('staff.manage');
  // booking_140: manager/admin näkevät kaikki vuorot ja hallitsevat tiedotteita (kuten tuotannon role_permissions); staff ei.
  if (perms === PERMS && role !== 'staff' && !st.perms.includes('shifts.view_all')) st.perms.push('shifts.view_all');
  if (perms === PERMS && role !== 'staff' && !st.perms.includes('annual_cards.manage')) st.perms.push('annual_cards.manage');   // booking_142: kuten tuotannon manager/admin
  st.settingsUi = exampleBundle();
  const optJson = (id) => { const o = st.options.find((x) => x.id === id); return o ? { id: o.id, code: o.code, name: o.name, name_en: o.name_en } : null; };
  const activeOpts = (pid) => st.options.filter((o) => o.product_id === pid && o.active).sort((a, b) => a.sort_order - b.sort_order || a.id - b.id);
  const required = (pid) => !!st.settings[pid]?.option_required && activeOpts(pid).length > 0;
  const missing = (r) => r.option_id == null && activeOpts(r.product_id).length > 0;
  const product = (id) => st.products.find((p) => p.id === id);
  const addRes = ({ pid, date, at, persons, status = 'confirmed', cust, optId = null, pay = 'paid', min = 90 }) => {
    const id = ++st.seq.res, orderNo = ++st.seq.order, c = st.customers.find((x) => x.id === cust) || st.customers[0];
    const [hh, mm] = at.split(':').map(Number), endMin = hh * 60 + mm + min, end = `${String(Math.floor(endMin / 60) % 24).padStart(2, '0')}:${String(endMin % 60).padStart(2, '0')}`;
    const p = product(pid);
    const r = { reservation_id: id, order_id: id + 5000, order_no: orderNo, status, order_status: 'confirmed', payment_status: pay, product_id: pid, product_name: p.name, mode: 'exclusive', starts_at: helIso(date, at), ends_at: helIso(date, end),
      persons, total_gross: p.price, customer_id: c.id, customer_name: c.name, customer_email: c.email, customer_phone: c.phone, source_channel: 'web', created_at: now.toISOString(), hold_expires_at: null, notes: null, annual_card_id: null,
      source: 'native', external_id: null, lifecycle: 'current', space_code: 'rauni', parent_reservation_id: null, option_id: optId };
    r.legs = [{ leg_id: id, role: 'space', resource_code: 'rauni', starts_at: r.starts_at, ends_at: r.ends_at, persons, skill: null }];
    st.reservations.push(r); return r;
  };
  addRes({ pid: 10, date: today, at: '16:00', persons: 2, cust: 1, optId: 1 });
  addRes({ pid: 10, date: today, at: '18:00', persons: 1, cust: 2, optId: null, pay: 'unpaid' });   // vanha varaus: valintaa ei ole → "valitsematta"
  addRes({ pid: 8, date: today, at: '17:00', persons: 3, cust: 3, optId: null });
  addRes({ pid: 10, date: addDays(today, 1), at: '16:30', persons: 1, cust: 4, optId: 3 });
  addRes({ pid: 10, date: addDays(today, 2), at: '17:30', persons: 2, cust: 1, optId: null, status: 'pending', pay: 'unpaid' });

  const view = (r) => {   // admin_list_reservations-rivi (booking_50: option_*-sarakkeet)
    const o = st.options.find((x) => x.id === r.option_id);
    return { ...r, total_count: 0, option_id: r.option_id ?? null, option_code: o?.code ?? null, option_name: o?.name ?? null, option_name_en: o?.name_en ?? null, option_missing: missing(r) };
  };
  const choicesJson = (pid) => activeOpts(pid).map((o) => ({ id: o.id, code: o.code, name: o.name, name_en: o.name_en, sort_order: o.sort_order, description: o.description, description_en: o.description_en, active: true }));
  // option_code-käsittely kuten palvelimella: lower(btrim()), pakollisuus vain jos option_required JA ≥ 1 aktiivinen vaihtoehto
  const resolveOption = (pid, code) => {
    const c = code == null ? '' : String(code).trim().toLowerCase();
    const opts = activeOpts(pid);
    if (!c) { if (required(pid)) throw err('option_required', st.settings[pid]?.option_label || 'Tee valinta'); return null; }
    const o = opts.find((x) => x.code === c);
    if (!o) throw err('invalid_option', 'Tuntematon tai passiivinen vaihtoehto');
    return o.id;
  };
  const staffOnly = () => {};
  const need = (perm) => { if (!st.perms.includes(perm)) throw err('forbidden', `Ei oikeutta tähän toimintoon (${perm})`); };
  const needAny = (...perms) => { if (!perms.some((p) => st.perms.includes(p))) throw err('forbidden', 'Ei oikeutta'); };
  const qrJson = (row) => {
    const p = product(row.product_id);
    return {
      id: row.id, code: row.code, product_id: row.product_id, name: p?.name || '', price: p?.price ?? null,
      label: row.label, active: row.active,
      path: `/juomat/?laite=${row.code}`, path_en: `/en/drinks/?laite=${row.code}`,
      print_url: `https://saunotus.fi/juomat/?laite=${row.code}`,
    };
  };
  const inRange = (r, a) => (!a.p_from || r.starts_at >= a.p_from) && (!a.p_to || r.starts_at < a.p_to);
  // booking_172: yritykset tilausten laskutustiedoista (peilaa booking._order_company_hits; yksi rivi / y-tunnus tai nimi, uusin tilaus)
  function mockOrderCompanyHits(q, lim) {
    const digits = q.replace(/\D/g, '');
    const byKey = new Map();
    for (const o of [...st.companyOrders].sort((x, y) => String(y.created_at).localeCompare(String(x.created_at)))) {
      const b = o.billing || {}; const cust = st.customers.find((c) => c.id === o.customer_id);
      if (!cust || cust.anonymized_at || String(b.company || '').trim().length < 2) continue;
      const bid = b.business_id && validBusinessId(normBusinessId(b.business_id)) ? normBusinessId(b.business_id) : null;
      const key = bid || `n:${b.company.trim().toLowerCase()}`;
      const blob = [b.company, b.business_id, b.contact_name, b.name, cust.name, b.contact_email, b.email, cust.email].filter(Boolean).join(' ').toLowerCase();
      const hit = blob.includes(q) || (digits.length >= 2 && String(bid || '').replace(/\D/g, '').includes(digits));
      const prev = byKey.get(key);
      if (prev) { prev.orders_count += 1; prev.hit ||= hit; continue; }
      byKey.set(key, { hit, company_key: key, customer_id: o.customer_id, company: b.company.trim(), business_id: bid || b.business_id || null,
        contact_name: b.contact_name || b.name || cust.name || null, email: b.contact_email || b.email || cust.email || null, phone: b.contact_phone || cust.phone || null,
        street: b.street || b.address || null, zip: b.zip || null, city: b.city || null, country: b.country || null,
        einvoice_address: b.einvoice_address || null, einvoice_operator: b.einvoice_operator || null, orders_count: 1, last_order_at: o.created_at });
    }
    return [...byKey.values()].filter((h) => h.hit).slice(0, lim).map(({ hit, ...h }) => h);
  }
  const handlers = {
    current_staff_role: () => role,
    admin_analytics_summary: (a) => { needAny('reports.view', 'reports.daily'); return analyticsMock(a.p_from || today, a.p_to || today); },   // Paketti 11 / booking_144
    // booking_142: alennuskoodit ja vuosikortit (samat tarkistukset pääpiirteissään kuin palvelimella)
    ...quietMockHandlers({ st, need, needAny, err, today }),   // booking_162: Hiljaiset ajat
    ...voucherRedeemMockHandlers({ st, need, err, now }),   // booking_173: kumppanilahjakorttien lunastus
    admin_list_discount_codes: () => { needAny('catalog.edit', 'annual_cards.manage'); return st.discountCodes.map((d) => ({ ...d })); },
    admin_save_discount_code: (a) => {
      need('catalog.edit');
      const p = a.p_data || {}, old = a.p_id != null ? st.discountCodes.find((d) => d.id === a.p_id) : null;
      if (a.p_id != null && !old) throw err('not_found', 'Koodia ei löydy');
      const annual = !!p.is_annual_card_code;
      if (annual || old?.is_annual_card_code) need('annual_cards.manage');
      const code = normalizeCode(p.code) || generatedDiscountCode();
      if (!/^[A-Z0-9-]{3,40}$/.test(code)) throw err('invalid_code', 'Koodissa saa olla 3–40 merkkiä: kirjaimia A–Z, numeroita ja väliviivoja');
      if (!/^\d{1,6}(\.\d{1,2})?$/.test(String(p.value ?? ''))) throw err('invalid_value', 'Tarkista alennuksen määrä');
      if (st.discountCodes.some((d) => d.code === code && d.id !== a.p_id)) throw err('code_exists', 'Koodi on jo käytössä');
      const usage = annual ? 'permanent' : p.usage_type || 'single';
      const row = { ...(old || { id: ++st.seq.disc, used_count: 0 }), code, description: p.description || null, kind: annual ? 'percent' : p.kind || 'percent', value: annual ? 100 : +p.value,
        valid_from: p.valid_from || null, valid_to: p.valid_to || null, usage_type: usage, max_uses: usage === 'single' ? 1 : usage === 'multi' ? +p.max_uses : null,
        target_scope: annual ? 'product' : p.target_scope || 'order', product_ids: annual ? [1] : p.target_scope === 'product' ? p.product_ids || [] : null, active: p.active !== false, is_annual_card_code: annual };
      row.state = !row.active ? 'inactive' : row.valid_to && row.valid_to < today ? 'expired' : row.valid_from && row.valid_from > today ? 'not_started' : row.max_uses && row.used_count >= row.max_uses ? 'used_up' : 'active';
      if (old) Object.assign(old, row); else st.discountCodes.push(row);
      return { ok: true, id: row.id, code };
    },
    admin_delete_discount_code: (a) => {
      need('catalog.edit');
      const d = st.discountCodes.find((x) => x.id === a.p_id); if (!d) throw err('not_found', 'Koodia ei löydy');
      if (d.is_annual_card_code) need('annual_cards.manage');
      if (d.used_count > 0) { d.active = false; d.state = 'inactive'; return { ok: true, deactivated: true }; }
      st.discountCodes = st.discountCodes.filter((x) => x !== d); return { ok: true, deleted: true };
    },
    admin_list_annual_cards_details: () => { need('annual_cards.manage'); return st.annualCards.map((c) => ({ ...c })); },
    admin_create_annual_card: (a) => {
      need('annual_cards.manage');
      const c = st.customers.find((x) => x.id === a.p_customer_id); if (!c) throw err('customer_not_found', 'Asiakasta ei löydy');
      if (!a.p_valid_from || !a.p_valid_to || a.p_valid_to < a.p_valid_from) throw err('invalid_dates', 'Virheellinen voimassaoloaika');
      const code = normalizeCode(a.p_code) || generatedAnnualCardCode();
      if (st.annualCards.some((x) => x.code === code) || st.discountCodes.some((x) => x.code === code)) throw err('code_exists', 'Koodi on jo käytössä');
      const row = { id: ++st.seq.card, code, customer_id: c.id, customer_name: c.name, customer_email: c.email, valid_from: a.p_valid_from, valid_to: a.p_valid_to, active: true, revoked_at: null, notes: a.p_notes || null, purchase_order_no: null, future_bookings: 0, reservations_count: 0, deletable: true };
      st.annualCards.push(row);
      // booking_154: 6-parametrinen kutsu (p_send_email) palauttaa sähköpostin tilan kuten palvelin; 5-parametrinen ennallaan
      if (a.p_send_email === undefined) return { ok: true, id: row.id, code };
      const status = a.p_send_email === false ? 'not_requested' : (/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(c.email || '') ? 'pending' : 'no_email');
      if (status === 'pending') st.annualEmails = [...(st.annualEmails || []), { dedupe_key: `annual_card_code:${row.id}`, card_id: row.id, source: 'admin' }];
      return { ok: true, id: row.id, code, email: { status } };
    },
    // booking_152: peruminen (kuten admin_revoke_annual_card) ja poisto vain käyttämättömälle hallinnasta myönnetylle kortille (kuten admin_delete_annual_card)
    admin_revoke_annual_card: (a) => {
      need('annual_cards.manage');
      const c = st.annualCards.find((x) => x.id === +a.p_id); if (!c) throw err('not_found', 'Vuosikorttia ei löydy');
      const cancelled = a.p_cancel_future ? c.future_bookings || 0 : 0;
      Object.assign(c, { active: false, revoked_at: c.revoked_at || new Date().toISOString(), future_bookings: a.p_cancel_future ? 0 : c.future_bookings });
      return { ok: true, future_reservations: cancelled || c.future_bookings || 0, cancelled };
    },
    admin_delete_annual_card: (a) => {
      need('annual_cards.manage');
      const c = st.annualCards.find((x) => x.id === +a.p_id); if (!c) throw err('not_found', 'Vuosikorttia ei löydy');
      if (c.purchase_order_no) throw err('annual_card_purchased', 'Kortti on ostettu tilauksella, joten sitä ei voi poistaa. Peru kortti poistamisen sijaan.');
      if (c.reservations_count > 0) throw err('annual_card_used', 'Kortilla on varauksia, joten sitä ei voi poistaa. Peru kortti poistamisen sijaan.');
      st.annualCards = st.annualCards.filter((x) => x !== c); return { ok: true, deleted: true, id: c.id, customer_id: c.customer_id, code: c.code };
    },
    // booking_136: varauksen osuus maksuista + peruutus (valinnainen hyvitys). Kokeilutila: maksettu varaus = koko summa hyvitettävissä.
    admin_reservation_refund_preview: (a) => {
      need('payments.refund');
      const r = st.reservations.find((x) => x.reservation_id === +a.p_reservation_id); if (!r) throw err('not_found', 'Varausta ei löydy');
      const amt = r.payment_status === 'paid' && !r.refunded ? +r.total_gross : 0;
      return { ok: true, reservation_id: r.reservation_id, order_id: r.order_id, status: r.status, total: amt, unallocated: 0,
        payments: amt > 0 ? [{ payment_id: r.reservation_id + 7000, provider: 'manual', method: 'card_terminal', gift_card: false, online_off: false, amount: amt, lines: [] }] : [] };
    },
    admin_cancel_reservation: (a) => {
      need('bookings.manage'); if (a.p_refund === true) need('payments.refund');
      const r = st.reservations.find((x) => x.reservation_id === +a.p_reservation_id); if (!r) throw err('not_found', 'Varausta ei löydy');
      if (!['pending', 'confirmed'].includes(r.status)) throw err('invalid_status', 'Vain voimassa olevan varauksen voi perua');
      const pv = a.p_refund === true ? handlers.admin_reservation_refund_preview(a) : { payments: [], total: 0 };
      r.status = 'cancelled'; if (pv.total > 0) r.refunded = true;
      return { ok: true, cancelled: true, order_id: r.order_id, refunds: pv.payments.map((p) => ({ payment_id: p.payment_id, provider: p.provider, amount: p.amount, refund_id: 9e6, status: 'done' })), refunded_total: pv.total };
    },
    admin_my_permissions: () => ({ role, role_label: role === 'staff' ? 'Työntekijä (esimerkki)' : role === 'admin' ? 'Pääkäyttäjä (esimerkki)' : 'Päällikkö (esimerkki)', permissions: st.perms }),
    admin_list_products: () => st.products.map((p) => ({ ...p })),
    'select:payment_methods': () => [{ code: 'pay_later', label: 'Maksu myöhemmin', is_manual: true, active: true }, { code: 'cash', label: 'Käteinen', is_manual: false, active: false }, { code: 'card_terminal', label: 'Korttipääte', is_manual: true, active: true }],
    'select:resources': () => EVENT_MOCK_RESOURCES.map((r) => ({ ...r })),   // booking_158: kind (space/person/capacity_pool) Tapahtumat-näkymän resurssivalintaan
    'select:product_space_rules': () => [10, 8, 7].map((pid) => ({ product_id: pid, leg_no: 1, priority: 1, space_id: 1, mode: 'exclusive', min_persons: 1, max_persons: 6, selection: 'auto', active: true })),
    admin_list_addons: () => [],
    admin_list_customers: (a) => st.customers.filter((c) => !a.p_search || `${c.name} ${c.email} ${c.phone}`.toLowerCase().includes(String(a.p_search).toLowerCase())).slice(0, a.p_limit || 5),
    admin_day_shifts: (a) => { const ownToday = st.ownShifts.some((s) => s.date === a.p_date && s.status !== 'cancelled');
      if (role === 'staff' && !st.perms.includes('shifts.view_all') && !ownToday) return [];
      return (st.staffShifts.length ? st.staffShifts : st.ownShifts).filter((s) => s.date === a.p_date && s.status !== 'cancelled'); },
    admin_upcoming_shifts: () => st.ownShifts,
    admin_next_own_shift_date: (a) => st.ownShifts.filter((s) => s.date >= (a.p_from_date || today) && s.status !== 'cancelled').map((s) => s.date).sort()[0] || null,
    admin_list_day_notes: (a) => ({
      day_notes: st.dayNotes.filter((n) => n.note_date === a.p_date),
      bulletins: st.dayBulletins.filter((b) => b.active && a.p_date >= b.start_date && a.p_date <= b.end_date),
    }),
    admin_save_day_note: (a) => {
      const body = String(a.p_body || '').trim();
      if (!a.p_date || !body || body.length > 2000) throw err('invalid_note');
      let note = st.dayNotes.find((n) => n.id === a.p_id);
      if (a.p_id && !note) throw err('not_found');
      if (note) { note.body = body; note.updated_at = now.toISOString(); }
      else { note = { id: st.dayMemoSeq++, note_date: a.p_date, body, author_name: 'Kokeilukäyttäjä', created_by: 'mock-user', created_at: now.toISOString(), updated_at: now.toISOString() }; st.dayNotes.push(note); }
      return { ok: true, note };
    },
    admin_delete_day_note: (a) => { const i = st.dayNotes.findIndex((n) => n.id === a.p_id); if (i < 0) throw err('not_found'); st.dayNotes.splice(i, 1); return { ok: true, id: a.p_id }; },
    admin_save_bulletin: (a) => {
      need('shifts.view_all');
      const body = String(a.p_body || '').trim();
      if (!body || body.length > 4000 || !a.p_start_date || !a.p_end_date || a.p_end_date < a.p_start_date) throw err('invalid_bulletin');
      let bulletin = st.dayBulletins.find((b) => b.id === a.p_id);
      if (a.p_id && !bulletin) throw err('not_found');
      if (bulletin) Object.assign(bulletin, { start_date: a.p_start_date, end_date: a.p_end_date, body, active: a.p_active !== false, updated_at: now.toISOString() });
      else { bulletin = { id: st.dayBulletinSeq++, start_date: a.p_start_date, end_date: a.p_end_date, body, active: a.p_active !== false, author_name: 'Kokeilukäyttäjä', created_by: 'mock-user', created_at: now.toISOString(), updated_at: now.toISOString() }; st.dayBulletins.push(bulletin); }
      return { ok: true, bulletin };
    },
    admin_delete_bulletin: (a) => { need('shifts.view_all'); const i = st.dayBulletins.findIndex((b) => b.id === a.p_id); if (i < 0) throw err('not_found'); st.dayBulletins.splice(i, 1); return { ok: true, id: a.p_id }; },
    admin_set_reservation_note: (a) => { const r = st.reservations.find((x) => x.reservation_id === a.p_reservation_id); if (!r) throw err('not_found'); const note = String(a.p_notes || '').trim(); if (note.length > 1000) throw err('invalid_note'); r.notes = note || null; return { ok: true, reservation_id: r.reservation_id, notes: r.notes }; },
    admin_list_reservations: (a) => {
      let rows = st.reservations.filter((r) => inRange(r, a));
      if (a.p_status === 'active') rows = rows.filter((r) => ['pending', 'confirmed'].includes(r.status)); else if (a.p_status) rows = rows.filter((r) => r.status === a.p_status);
      if (a.p_product_id) rows = rows.filter((r) => r.product_id === a.p_product_id);
      if (a.p_source) rows = rows.filter((r) => r.source === a.p_source);
      if (a.p_option_missing === true) rows = rows.filter((r) => missing(r));   // booking_72: vain hoito valitsematta (option_missing)
      if (a.p_reservation_id != null) rows = rows.filter((r) => String(r.reservation_id) === String(a.p_reservation_id));
      if (a.p_search) { const q = String(a.p_search).toLowerCase(); rows = rows.filter((r) => `${r.customer_name} ${r.customer_email} ${r.customer_phone} ${r.order_no}`.toLowerCase().includes(q)); }
      rows = rows.sort((x, y) => {
        if (a.p_sort === 'created_desc') return y.created_at.localeCompare(x.created_at) || y.reservation_id - x.reservation_id;
        if (a.p_sort === 'created_asc') return x.created_at.localeCompare(y.created_at) || x.reservation_id - y.reservation_id;
        if (a.p_sort === 'start_asc') return x.starts_at.localeCompare(y.starts_at) || x.reservation_id - y.reservation_id;
        return x.starts_at.localeCompare(y.starts_at) || x.reservation_id - y.reservation_id;
      });
      const total = rows.length; rows = rows.slice(a.p_offset || 0, (a.p_offset || 0) + (a.p_limit || 50));
      return rows.map((r) => ({ ...view(r), total_count: total }));
    },
    admin_procountor_status: () => { need('settings.edit'); return procountorStatus(st.procountor); },
    admin_get_procountor_settings: () => {
      need('settings.edit');
      return { ok: true, ...structuredClone(st.procountor) };
    },
    admin_set_procountor_settings: (a) => {
      need('settings.edit');
      st.procountor = normalizeProcountor(a.p || {}, st.procountor);
      return { ok: true, ...structuredClone(st.procountor) };
    },
    admin_procountor_preview_daily: (a) => {
      need('settings.edit');
      return { ok: true, date: a.p_date, sent: false, receipts: 0, refund_receipts: 0, ready: false, missing: ['vat_status'] };
    },
    admin_get_booking_calendar: () => {
      need('settings.edit');
      return { ok: true, ...structuredClone(st.bookingCalendar) };
    },
    admin_set_booking_calendar: (a) => {
      need('settings.edit');
      const p = a.p || {};
      const secret = ['api_key', 'token', 'secret', 'private_key', 'client_secret', 'password'].find((k) => Object.prototype.hasOwnProperty.call(p, k));
      if (secret) throw err('secrets_not_allowed', 'Salaisuuksia ei tallenneta asetuksiin');
      const mode = p.mode == null || p.mode === '' ? st.bookingCalendar.mode : p.mode;
      if (!['off', 'dry_run', 'live'].includes(mode)) throw err('invalid_setting', 'Tila on off, dry_run tai live');
      const shared = p.shared_calendar_id == null ? st.bookingCalendar.shared_calendar_id : String(p.shared_calendar_id).trim();
      if (calendarIdError(shared)) throw err('invalid_calendar', 'Kalenterin tunnus ei kelpaa');
      if (shared && st.closureCalendarIds.includes(shared)) throw err('closure_calendar', 'Sulkukalenteria ei käytetä varauksille');
      const src = p.resource_calendars == null ? Object.fromEntries(st.bookingCalendar.resources.map((r) => [r.code, r.calendar_id])) : p.resource_calendars;
      if (src == null || typeof src !== 'object' || Array.isArray(src)) throw err('invalid_setting', 'Resurssikalenterit ovat objekti');
      const known = new Map(st.bookingCalendar.resources.map((r) => [r.code, r]));
      const next = new Map();
      for (const [code, raw] of Object.entries(src)) {
        const id = String(raw ?? '').trim();
        if (!known.has(code)) throw err('unknown_resource', 'Tuntematon resurssi');
        if (id && calendarIdError(id)) throw err('invalid_calendar', 'Kalenterin tunnus ei kelpaa');
        if (id && st.closureCalendarIds.includes(id)) throw err('closure_calendar', 'Sulkukalenteria ei käytetä varauksille');
        next.set(code, id);
      }
      for (const [code, id] of next) known.get(code).calendar_id = id;
      st.bookingCalendar.mode = mode;
      st.bookingCalendar.shared_calendar_id = shared;
      if (p.timezone != null && String(p.timezone).trim()) st.bookingCalendar.timezone = String(p.timezone).trim();
      if (p.window_back_days != null) st.bookingCalendar.window_back_days = Number(p.window_back_days);
      if (p.window_forward_days != null) st.bookingCalendar.window_forward_days = Number(p.window_forward_days);
      if (p.admin_base_url != null) st.bookingCalendar.admin_base_url = String(p.admin_base_url).trim();
      if (p.fast_nudge != null) st.bookingCalendar.fast_nudge = p.fast_nudge === true;
      return { ok: true, ...structuredClone(st.bookingCalendar) };
    },
    admin_booking_calendar_preview: () => {
      need('settings.edit');
      return { ok: true, sent: false, private_events: 1, day_bars: st.bookingCalendar.shared_calendar_id ? 1 : 0, unconfigured: st.bookingCalendar.shared_calendar_id ? 0 : 1 };
    },
    admin_set_setting: (a) => {
      need('settings.edit');
      const row = st.generalSettings.find((s) => s.key === a.p_key);
      if (row) row.value = a.p_value;
      return { ok: true };
    },
    admin_settings_bundle: () => {
      if (!st.perms.includes('settings.edit')) {
        if (!st.perms.includes('pos.use')) throw err('forbidden', 'Ei oikeutta');
        return { ok: true, role, qr_only: true };
      }
      return { ok: true, role, qr_only: false, ...st.settingsUi };
    },
    admin_save_settings: (a) => {
      need('settings.edit');
      if (a.p_section === 'technical' && role !== 'admin') throw err('forbidden', 'Tekniset rajat vain pääkäyttäjälle');
      try { applySection(st.settingsUi, a.p_section, a.p || {}); }
      catch (e) { throw err(e.code || 'invalid_value', e.message); }
      return { ok: true };
    },
    admin_list_payment_fee_rules: () => {
      need('settings.edit');
      return { ok: true, rows: st.feeRules.map((r) => ({ ...r, provider_label: ({ montonio: 'Montonio', visma_pay: 'Visma Pay', mobilepay: 'MobilePay', manual: 'Käsin', johku: 'Johku' })[r.provider] || r.provider })) };
    },
    admin_upsert_payment_fee_rule: (a) => {
      need('settings.edit');
      const p = a.p || {};
      const provider = String(p.provider || '');
      const method = String(p.method || '*');
      const fixed = Number(p.fixed_eur);
      const percent = Number(p.percent);
      if (!/^[a-z][a-z0-9_]{0,39}$/.test(provider) || !/^(\*|[a-z][a-z0-9_]{0,39})$/.test(method) || !Number.isFinite(fixed) || fixed < 0 || fixed > 1000 || !Number.isFinite(percent) || percent < 0 || percent > 100) throw err('invalid_value', 'Tarkista provisiosääntö');
      let row = st.feeRules.find((r) => r.provider === provider && r.method === method);
      if (!row) { row = { id: st.feeRules.reduce((m, r) => Math.max(m, r.id), 0) + 1, provider, method }; st.feeRules.push(row); }
      row.fixed_eur = Math.round(fixed * 10000) / 10000;
      row.percent = Math.round(percent * 10000) / 10000;
      row.active = p.active !== false;
      return { ok: true, rule: { ...row } };
    },
    admin_delete_payment_fee_rule: (a) => {
      need('settings.edit');
      const i = st.feeRules.findIndex((r) => r.id === Number(a.p_id));
      if (i < 0) throw err('not_found', 'Sääntöä ei löydy');
      st.feeRules.splice(i, 1);
      return { ok: true };
    },
    'select:settings': (q = {}) => {
      let rows = st.generalSettings.map((s) => ({ ...s }));
      if (typeof q.key === 'string' && q.key.startsWith('eq.')) rows = rows.filter((s) => s.key === q.key.slice(3));
      if (q.limit != null) rows = rows.slice(0, Number(q.limit) || 0);
      return rows;
    },
    public_get_site_texts: () => ({ ok: true, texts: [
      { key: 'ui.admin.day.revenue_title', lang: 'fi', text: 'Päivän tuotto' },
      { key: 'ui.admin.day.revenue_title', lang: 'en', text: "Day's revenue" },
      { key: 'ui.admin.day.revenue_vat', lang: 'fi', text: 'sis. alv' },
      { key: 'ui.admin.day.revenue_vat', lang: 'en', text: 'incl. VAT' },
      { key: 'ui.admin.day.revenue_unavailable', lang: 'fi', text: 'Päivän tuotto ja tapahtumat eivät ole vielä käytettävissä.' },
      { key: 'ui.admin.day.revenue_unavailable', lang: 'en', text: "The day's revenue and events are not available yet." },
      { key: 'ui.admin.day.event_badge', lang: 'fi', text: 'Tapahtuma' },
      { key: 'ui.admin.day.event_badge', lang: 'en', text: 'Event' },
      { key: 'ui.admin.day.event_all_day', lang: 'fi', text: 'Koko päivä' },
      { key: 'ui.admin.day.event_all_day', lang: 'en', text: 'All day' },
    ] }),
    admin_day_revenue: (a) => {
      if (role !== 'admin' && role !== 'manager') throw err('forbidden', 'Päivän tuotto näkyy vain ylläpitäjälle');
      return { date: a.p_date, tz: 'Europe/Helsinki', revenue_rows: [],
        revenue: { basis: 'visit_start', vat_basis: 'gross_incl_vat', currency: 'EUR', gross: 0, vat: 0, net: 0, count: 0, pending_gross: 0, pending_count: 0, unpaid_gross: 0, unpaid_count: 0 } };
    },
    admin_day_extras: (a) => ({ date: a.p_date, tz: 'Europe/Helsinki', events: [],
      revenue_rows: role === 'admin' || role === 'manager' ? [] : null,
      revenue: role === 'admin' || role === 'manager' ? { basis: 'visit_start', vat_basis: 'gross_incl_vat', currency: 'EUR', gross: 0, vat: 0, net: 0, count: 0, pending_gross: 0, pending_count: 0, unpaid_gross: 0, unpaid_count: 0 } : null }),
    admin_day_bundle: (a) => {
      const from = helIso(a.p_date, '00:00'), to = helIso(addDays(a.p_date, 1), '00:00');
      return { date: a.p_date, role, permissions: handlers.admin_my_permissions(),
        products: handlers.admin_list_products(), payment_methods: handlers['select:payment_methods'](),
        resources: handlers['select:resources'](), view: handlers.admin_day_view(a),
        reservations: handlers.admin_list_reservations({ p_from: from, p_to: to, p_limit: 200 }),
        shifts: handlers.admin_day_shifts(a), addons: handlers.admin_list_addons(),
        options: handlers.admin_list_product_options({}), extras: handlers.admin_day_extras(a),
        site_texts: handlers.public_get_site_texts(), notes_bundle: handlers.admin_list_day_notes(a) };
    },
    admin_day_view: (a) => {
      const rs = st.reservations.filter((r) => r.starts_at >= helIso(a.p_date, '00:00') && r.starts_at < helIso(addDays(a.p_date, 1), '00:00'));
      return { date: a.p_date, sessions: [], blocks: [], prep: [], addon_totals: [],
        reservations: rs.map((r) => ({ reservation_id: r.reservation_id, order_id: r.order_id, order_no: r.order_no, status: r.status, payment_status: r.payment_status, product_name: r.product_name, mode: r.mode, starts_at: r.starts_at, ends_at: r.ends_at, persons: r.persons,
          customer_name: r.customer_name, customer_phone: r.customer_phone, source: 'native', external_id: null, customer_kind: 'private', company: null, space_code: r.space_code, lifecycle: r.lifecycle, quota_exempt: false, override_reason: null,
          therapist_missing: false, therapist_missing_open: false, notes: r.notes, legs: r.legs, addons: [], option: optJson(r.option_id), option_missing: missing(r) })) };
    },
    admin_get_order: (a) => {
      const r = st.reservations.find((x) => x.order_id === a.p_order_id); if (!r) throw err('not_found', 'Tilausta ei löydy');
      const total = Number(r.total_gross) || 0;
      const paid = r.payment_status === 'paid' ? total : 0;
      const unpaid = r.payment_status === 'paid' ? 0 : total;
      return { order_id: r.order_id, order_no: r.order_no, status: r.order_status, payment_status: r.payment_status, total, source_channel: 'web', created_at: r.created_at, customer_kind: 'private', billing: null, invoice_reference: null,
        customer: { id: r.customer_id, name: r.customer_name, email: r.customer_email, phone: r.customer_phone },
        reservations: [{ id: r.reservation_id, status: r.status, product_name: r.product_name, mode: r.mode, starts_at: r.starts_at, ends_at: r.ends_at, persons: r.persons, notes: r.notes, item_total: total, product_id: r.product_id,
          option: optJson(r.option_id), option_choices: choicesJson(r.product_id), option_missing: missing(r), addons: [] }], items: [], payments: [],
        balance: { total, paid, refunded: 0, pending_link: 0, unpaid, unpaid_unlinked: unpaid, net_paid: paid },
        is_native: r.source !== 'johku', staff_can_add: r.source !== 'johku' && ['confirmed', 'completed'].includes(r.order_status) };
    },
    admin_set_reservation_option: (a) => {
      need('bookings.manage');
      const r = st.reservations.find((x) => x.reservation_id === a.p_reservation_id); if (!r) throw err('not_found', 'Varausta ei löydy');
      const prev = optJson(r.option_id), id = resolveOption(r.product_id, a.p_option_code);
      r.option_id = id;
      return { ok: true, reservation_id: r.reservation_id, option: optJson(id), previous: prev, email_queued: !!a.p_notify };
    },
    admin_treatment_availability: (a) => {   // vastaa tuotannon admin_treatment_availability-funktiota: kesto = product_config.duration_minutes; public_weekdays (isodow) rajaa päivät; ritual-luokka: alkuajat 16:00/16:30/17:00
      need('bookings.manage');
      const p = product(a.p_product_id), c = p?.config, rows = [];
      if (!c || c.lifecycle !== 'current') return rows;
      const dur = c.duration_minutes || 60, ritual = c.time_window_class === 'ritual';
      for (let i = 0; i < 14; i++) {
        const d = addDays(a.p_from, i), isodow = (new Date(`${d}T12:00:00Z`).getUTCDay() + 6) % 7 + 1;
        if (c.public_weekdays && !c.public_weekdays.includes(isodow)) continue;
        for (const at of ritual ? ['16:00', '16:30', '17:00'] : ['16:00', '17:30']) {
          const s0 = helIso(d, at);
          rows.push({ product_id: p.id, session_date: d, starts_at: s0, ends_at: new Date(new Date(s0).getTime() + dur * 60e3).toISOString(), duration_minutes: dur, status: 'available', persons: a.p_persons || 1,
            total: p.price_type === 'per_person' ? p.price * (a.p_persons || 1) : p.price ?? null, therapist_missing: false, needs_override: false });
        }
      }
      return rows;
    },
    admin_create_resource_booking: (a) => {
      need('bookings.manage');
      const p = product(a.p_product_id); if (!p) throw err('product_not_found', 'Tuotetta ei löydy');
      const optId = resolveOption(p.id, a.p_option_code);   // virhe ennen sivuvaikutuksia
      const start = new Date(a.p_start); const day = start.toLocaleDateString('sv-SE', { timeZone: TZ }), hhmm = start.toLocaleTimeString('sv-SE', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
      const r = addRes({ pid: p.id, date: day, at: hhmm, persons: a.p_persons || 1, cust: a.p_customer_id || 1, optId, pay: a.p_paid ? 'paid' : 'unpaid', min: p.config.duration_minutes || 90 });
      return { ok: true, reservation_id: r.reservation_id, order_id: r.order_id, order_no: r.order_no, product_name: r.product_name, starts_at: r.starts_at, ends_at: r.ends_at, total: r.total_gross, legs: 0, option: optJson(optId) };
    },
    admin_list_product_options: (a) => {
      const pids = [...new Set(st.options.map((o) => o.product_id))].filter((id) => !a?.p_product_id || id === a.p_product_id);
      return pids.map((pid) => ({ product_id: pid, product_name: product(pid)?.name, option_required: !!st.settings[pid]?.option_required, option_label: st.settings[pid]?.option_label ?? null, option_label_en: st.settings[pid]?.option_label_en ?? null,
        options: st.options.filter((o) => o.product_id === pid).sort((x, y) => x.sort_order - y.sort_order || x.id - y.id).map((o) => ({ ...o })),
        reservations_without_option: st.reservations.filter((r) => r.product_id === pid && r.option_id == null && ['pending', 'confirmed'].includes(r.status) && r.ends_at > now.toISOString()).length }));
    },
    admin_upsert_product_option: (a) => {
      need('catalog.edit');
      if (!product(a.p_product_id)) throw err('product_not_found', 'Tuotetta ei löydy');
      const code = String(a.p_code ?? '').trim().toLowerCase(); if (!CODE_RE.test(code)) throw err('invalid_param', 'Virheellinen koodi'); if (!String(a.p_name ?? '').trim()) throw err('invalid_param', 'Nimi puuttuu');
      let o = st.options.find((x) => x.product_id === a.p_product_id && x.code === code);
      const v = { name: String(a.p_name).trim(), name_en: a.p_name_en || null, sort_order: a.p_sort_order ?? 100, active: a.p_active ?? true, description: a.p_description ?? null, description_en: a.p_description_en ?? null };
      if (o) Object.assign(o, v); else { o = { id: Math.max(0, ...st.options.map((x) => x.id)) + 1, product_id: a.p_product_id, code, ...v }; st.options.push(o); }
      return { ok: true, option: { ...o } };
    },
    admin_review_list: () => {
      const ackedIds = new Set(st.blockAcks.map((a) => `${a.reservation_id}:${a.block_id}`));
      const open = st.blockConflicts.filter((b) => !ackedIds.has(`${b.reservation_id}:${b.block_id}`));
      const acked = st.blockConflicts.filter((b) => ackedIds.has(`${b.reservation_id}:${b.block_id}`)).map((b) => {
        const a = st.blockAcks.find((x) => x.reservation_id === b.reservation_id && x.block_id === b.block_id);
        return { ...b, ack_id: a.id, ack_reason: a.ack_reason, acked_by_label: a.acked_by_label, acked_at: a.acked_at };
      });
      return { missing_therapist: [], therapist_conflicts: [], block_conflicts: open, acked_block_conflicts: acked, overrides: [], orphan_addons: [] };
    },
    admin_ack_block_conflict: (a) => {
      if (!st.perms.includes('blocks.manage') && !st.perms.includes('bookings.override')) throw err('forbidden', 'Ei oikeutta tähän toimintoon (blocks.manage tai bookings.override)');
      const note = String(a.p_note ?? '').trim();
      if (note.length < 3) throw err('note_required', 'Kuittaus vaatii perustelun (vähintään 3 merkkiä)');
      const hit = st.blockConflicts.find((b) => b.reservation_id === a.p_reservation_id && b.block_id === a.p_block_id);
      if (!hit) throw err('no_conflict', 'Sulkukonfliktia ei ole tälle varaukselle ja sululle');
      const prev = st.blockAcks.find((x) => x.reservation_id === hit.reservation_id && x.block_id === hit.block_id);
      if (prev) return { ok: true, already: true, id: prev.id, reservation_id: hit.reservation_id, block_id: hit.block_id };
      const row = { id: st.blockAcks.length + 1, reservation_id: hit.reservation_id, block_id: hit.block_id, ack_reason: note.slice(0, 300), acked_by_label: String(a.p_label ?? '').trim() || null, acked_at: now.toISOString() };
      st.blockAcks.push(row);
      return { ok: true, already: false, id: row.id, reservation_id: row.reservation_id, block_id: row.block_id };
    },
    admin_unack_block_conflict: (a) => {
      if (!st.perms.includes('blocks.manage') && !st.perms.includes('bookings.override')) throw err('forbidden', 'Ei oikeutta tähän toimintoon (blocks.manage tai bookings.override)');
      const i = st.blockAcks.findIndex((x) => x.reservation_id === a.p_reservation_id && x.block_id === a.p_block_id);
      if (i < 0) return { ok: true, already: true, revoked: false, reservation_id: a.p_reservation_id, block_id: a.p_block_id };
      const [row] = st.blockAcks.splice(i, 1);
      return { ok: true, already: false, revoked: true, id: row.id, reservation_id: row.reservation_id, block_id: row.block_id };
    },
    admin_pos_catalog: () => {
      need('pos.use');
      return st.products.filter((p) => p.active && p.config?.pos_enabled && !['gift_card', 'season_card'].includes(p.category) && p.price != null)
        .sort((a, b) => (a.config.pos_sort ?? 100) - (b.config.pos_sort ?? 100) || a.name.localeCompare(b.name, 'fi'))
        .map((p) => ({ product_id: p.id, name: p.name, name_en: p.name_en || null, price: p.price, vat_rate: p.vat_rate, category: p.category, age_restricted: !!p.config.age_restricted, pos_sort: p.config.pos_sort ?? 100 }));
    },
    admin_pos_tenders: () => {
      need('pos.use');
      return { mobilepay_mode: st.posModes.mobilepay_mode, vismapay_mode: st.posModes.vismapay_mode, site_base_url: 'https://saunotus.fi', drinks_path: '/juomat/', drinks_path_en: '/en/drinks/', tenders: [
        { code: 'payment_link', handler: 'payment_link', channels: ['pos'], active: true, sort_order: 10, unavailable_reason: null },
        { code: 'mobilepay', handler: 'mobilepay', channels: ['pos', 'drinks'], active: true, sort_order: 20, unavailable_reason: null },
        { code: 'visma_pay', handler: 'visma_pay', channels: ['drinks'], active: true, sort_order: 30, unavailable_reason: null },
        { code: 'card_terminal', handler: 'terminal', channels: ['pos'], active: false, sort_order: 40, unavailable_reason: 'not_implemented' },
      ] };
    },
    admin_pos_checkout: (a) => {
      need('pos.use');
      const items = Array.isArray(a.p_items) ? a.p_items : [];
      if (items.some((r) => Object.keys(r).some((k) => k !== 'product_id' && k !== 'quantity'))) throw err('price_locked', 'Hintaa ei voi antaa');
      const lines = [];
      let total = 0;
      for (const r of items) {
        const p = product(r.product_id);
        if (!p || !p.config?.pos_enabled || ['gift_card', 'season_card'].includes(p.category)) throw err('not_counter_product', 'Tuote ei ole pikakassassa');
        const line = Math.round(p.price * r.quantity * 100) / 100;
        total += line;
        lines.push({ product_id: p.id, name: p.name, quantity: r.quantity, unit_price: p.price, vat_rate: p.vat_rate, line_total: line });
      }
      const raw = a.p_email == null ? '' : String(a.p_email).trim().toLowerCase();
      if (raw && (raw.length > 254 || !EMAIL_RE.test(raw))) throw err('invalid_email', 'Sähköposti ei ole kelvollinen');
      let customerId = null;
      if (raw) {
        let cust = [...st.posCustomers].reverse().find((c) => c.email === raw);
        if (!cust) {
          cust = { id: st.posCustomers.length + 1, email: raw };
          st.posCustomers.push(cust);
        }
        customerId = cust.id;
      }
      const id = ++st.seq.order;
      const row = { order_id: id, order_no: id, public_token: `00000000-0000-4000-8000-${String(id).padStart(12, '0')}`, total, status: 'pending', payment_status: 'unpaid', source_channel: 'pikakassa', customer_id: customerId, customer_email: raw || null, lines, receipts: [], polls: 0, arm: false };
      st.posOrders.push(row);
      return { ok: true, ...row };
    },
    admin_pos_status: (a) => {
      need('pos.use');
      const o = st.posOrders.find((x) => x.order_id === a.p_order_id);
      if (!o) throw err('not_found', 'Kassatilausta ei löydy');
      o.polls += 1;
      if (o.arm && o.polls >= 1) { o.payment_status = 'paid'; o.status = 'confirmed'; o.receipts = [{ receipt_no: 'R-' + o.order_no, token: o.public_token, total: o.total }]; }
      return { ok: true, order_id: o.order_id, order_no: o.order_no, public_token: o.public_token, status: o.status, payment_status: o.payment_status, total: o.total, source_channel: 'pikakassa', lines: o.lines, receipts: o.receipts };
    },
    admin_pos_void: (a) => {
      need('pos.use');
      const o = st.posOrders.find((x) => x.order_id === a.p_order_id);
      if (!o) throw err('not_found', 'Kassatilausta ei löydy');
      if (o.payment_status === 'paid') throw err('already_paid', 'Maksettua tilausta ei voi perua kassalla');
      o.status = 'cancelled';
      return { ok: true, order_id: o.order_id, status: 'cancelled' };
    },
    admin_pos_mock_tender: (a) => {
      const o = st.posOrders.find((x) => x.order_id === a.p_order_id);
      if (o) o.arm = true;
      return { ok: true };
    },
    admin_create_payment_link: (a) => {
      need('payments.manage');
      const o = st.posOrders.find((x) => x.order_id === a.p_order_id);
      return { ok: true, payment_id: 1, link_path: '/maksa/?p=11111111-2222-4333-8444-555555555555', amount: o?.total ?? 0, expires_at: a.p_expires_days == null ? null : new Date(Date.now() + a.p_expires_days * 864e5).toISOString(), online_payment_enabled: false };
    },
    admin_pos_send_link: (a) => {
      needAny('pos.use', 'settings.edit');
      const o = st.posOrders.find((x) => x.order_id === a.p_order_id && x.source_channel === 'pikakassa');
      if (!o) throw err('not_found', 'Kassatilausta ei löydy');
      if (o.status !== 'pending' || !['unpaid', 'pending'].includes(o.payment_status)) throw err('order_not_editable', 'Tilaukselle ei voi lähettää maksulinkkiä');
      const email = String(a.p_email || '').trim().toLowerCase();
      if (!email || email.length > 254 || !EMAIL_RE.test(email)) throw err('invalid_email', 'Sähköposti ei ole kelvollinen');
      const current = st.posCustomers.find((c) => c.id === o.customer_id);
      if (!o.customer_id || current?.email !== email) {
        let cust = [...st.posCustomers].reverse().find((c) => c.email === email);
        if (!cust) {
          cust = { id: st.posCustomers.length + 1, email };
          st.posCustomers.push(cust);
        }
        o.customer_id = cust.id;
        o.customer_email = email;
      }
      if (!o.payment_id) o.payment_id = ++st.seq.pay;
      const rows = st.posMail.filter((m) => m.payment_id === o.payment_id && m.dedupe.startsWith(`pos_link:${o.payment_id}:`));
      let n;
      if (a.p_resend) {
        if (rows.length >= 3) throw err('rate_limited', 'Maksulinkki on lähetetty jo kolme kertaa');
        const latest = rows.reduce((m, r) => Math.max(m, r.created), 0);
        if (latest && Date.now() - latest < 60000) throw err('rate_limited', 'Odota hetki ennen uutta lähetystä');
        n = rows.length;
      } else n = 0;
      const dedupe = `pos_link:${o.payment_id}:${n}`;
      let row = st.posMail.find((m) => m.dedupe === dedupe);
      let queued = false;
      if (!row) {
        row = {
          id: st.posMail.length + 1, order_id: o.order_id, payment_id: o.payment_id, kind: 'payment_link', dedupe,
          status: st.resendMode === 'off' ? 'skipped' : 'pending', attempts: 0, max_attempts: 6, sent_at: null, last_error: null, created: Date.now(),
        };
        st.posMail.push(row);
        queued = true;
      }
      o.payment_status = 'pending';
      return { ok: true, payment_id: o.payment_id, link_path: '/maksa/?p=11111111-2222-4333-8444-555555555555', amount: o.total, email_queued: queued, outbox_status: row.status, masked_to: maskEmail(email) };
    },
    admin_pos_email_status: (a) => {
      needAny('pos.use', 'settings.edit');
      const o = st.posOrders.find((x) => x.order_id === a.p_order_id && x.source_channel === 'pikakassa');
      if (!o) throw err('not_found', 'Kassatilausta ei löydy');
      const row = [...st.posMail].reverse().find((m) => m.order_id === o.order_id && m.kind === 'payment_link');
      return {
        ok: true,
        status: row?.status ?? null,
        attempts: row?.attempts ?? null,
        max_attempts: row?.max_attempts ?? null,
        sent_at: row?.sent_at ?? null,
        last_error: row?.last_error ? String(row.last_error).slice(0, 120) : null,
        masked_to: maskEmail(o.customer_email),
      };
    },
    admin_set_pos_product: (a) => {
      needAny('pos.use', 'settings.edit');
      const p = product(a.p_product_id);
      if (!p?.config || !p.active || p.price == null || ['gift_card', 'season_card'].includes(p.category)) throw err('not_counter_product', 'Tuotetta ei voi lisätä pikakassaan');
      if (a.p_sort != null && (a.p_sort < 0 || a.p_sort > 10000)) throw err('invalid_param', 'Järjestys');
      p.config.pos_enabled = !!a.p_enabled;
      if (a.p_sort != null) p.config.pos_sort = a.p_sort;
      return { ok: true, product_id: p.id, pos_enabled: p.config.pos_enabled, pos_sort: p.config.pos_sort };
    },
    admin_list_product_qr: () => {
      needAny('pos.use', 'settings.edit');
      return st.productQr.map(qrJson);
    },
    admin_create_product_qr: (a) => {
      needAny('pos.use', 'settings.edit');
      const p = product(a.p_product_id);
      if (!p?.config || !p.active || p.price == null) throw err('not_found', 'Tuotetta ei löydy');
      if (['gift_card', 'season_card'].includes(p.category)) throw err('not_counter_product', 'Lahjakortti ei kelpaa');
      if (p.config.age_restricted || /(^|[^\p{L}])(olut|beer)([^\p{L}]|$)/iu.test(`${p.name} ${p.name_en || ''}`)) throw err('age_restricted', 'Ikärajallista tuotetta ei voi myydä QR-linkillä');
      p.config.fridge_sale = true;
      const code = [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, '0')).join('');
      const row = { id: st.productQr.length + 1, code, product_id: p.id, label: a.p_label ? String(a.p_label).trim() : null, active: true };
      st.productQr.push(row);
      return qrJson(row);
    },
    admin_delete_product_qr: (a) => {
      needAny('pos.use', 'settings.edit');
      const i = st.productQr.findIndex((x) => x.id === a.p_id);
      if (i < 0) throw err('not_found', 'Koodia ei löydy');
      st.productQr.splice(i, 1);
      return { ok: true };
    },
    admin_product_create: (a) => {
      need('catalog.edit');
      const d = a.p_data || {};
      const allowed = new Set(['name', 'name_en', 'description', 'description_en', 'short_description', 'short_description_en', 'price', 'price_text', 'vat_rate', 'category', 'active', 'age_restricted']);
      for (const k of Object.keys(d)) if (!allowed.has(k)) throw err('unknown_field', 'Kenttää ei saa muokata: ' + k);
      const name = String(d.name ?? '').trim();
      if (!name || name.length > 200) throw err('invalid_name', 'Nimi ei voi olla tyhjä');
      let nameEn = String(d.name_en ?? '').trim();
      if (!nameEn) nameEn = name;
      if (nameEn.length > 200) throw err('invalid_name', 'Englanninkielinen nimi on liian pitkä');
      const priceRaw = String(d.price ?? '').trim().replace(',', '.');
      if (!/^\d{1,6}(\.\d{1,2})?$/.test(priceRaw)) throw err('invalid_price', 'Virheellinen hinta');
      const price = Number(priceRaw);
      if (price < 0 || price > 100000) throw err('invalid_price', 'Virheellinen hinta');
      const vatRaw = String(d.vat_rate ?? '').trim().replace(',', '.');
      if (!/^\d{1,2}(\.\d{1,2})?$/.test(vatRaw)) throw err('invalid_vat', 'ALV-kanta ei ole sallittu');
      const vat = Number(vatRaw);
      if (!st.vatRates.some((r) => r.active && r.rate === vat)) throw err('invalid_vat', 'ALV-kanta ei ole sallittu');
      const cats = ['public_sauna', 'treatment', 'ritual', 'private_sauna', 'ceremony', 'event', 'training', 'gift_card', 'season_card', 'add_on', 'product_rental', 'corporate', 'other'];
      const category = String(d.category || 'product_rental');
      if (!cats.includes(category)) throw err('invalid_category', 'Kategoria ei kelpaa');
      const active = d.active == null ? true : !!d.active;
      const age = d.age_restricted == null ? false : !!d.age_restricted;
      if (st.businessId == null) throw err('no_business', 'Yritystä ei löydy');
      if (active && st.products.some((p) => p.active && String(p.name).trim().toLowerCase() === name.toLowerCase())) {
        throw err('duplicate_name', 'Samanniminen aktiivinen tuote on jo olemassa');
      }
      const id = Math.max(0, ...st.products.map((p) => p.id)) + 1;
      const priceText = String(d.price_text || '').trim() || `${price.toFixed(2).replace('.', ',')} €`;
      let slug = name.toLowerCase().replace(/[äå]/g, 'a').replace(/ö/g, 'o').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'tuote';
      const base = slug;
      let n = 2;
      while (st.products.some((p) => p.slug === slug)) slug = `${base}-${n++}`;
      const sort = Math.max(100, ...st.products.map((p) => p.config?.sort_order || 0)) + 10;
      const row = {
        id, business_id: st.businessId, slug, name, name_en: nameEn,
        description: String(d.description || '').trim() || null,
        description_en: String(d.description_en || '').trim() || null,
        short_description: String(d.short_description || '').trim() || null,   // booking_156 (mock ei tarkista allowlistia; kanta tarkistaa)
        short_description_en: String(d.short_description_en || '').trim() || null,
        category, price, price_type: 'per_unit', price_text: priceText, vat_rate: vat, active,
        external_system: null, external_id: null,
        config: {
          product_id: id, sale_kind: 'other', bookable: false, shop_visible: false, sort_order: sort,
          min_persons: 1, max_persons: null, lifecycle: 'current', resource_class: 'none',
          audience: 'consumer', pos_enabled: false, pos_sort: 100, fridge_sale: false, age_restricted: age,
          public_slots: false,
        },
        variants: [],
      };
      st.products.push(row);
      return { ok: true, id, product: row };
    },
    admin_update_product_config: (a) => {
      need('catalog.edit');
      const p = product(a.p_product_id);
      if (!p?.config) throw err('not_found', 'Tuotteella ei ole varauskonfiguraatiota');
      const patch = a.p_patch || {};
      if (patch.price != null || patch.vat_rate != null) throw err('unknown_field', 'Kenttää ei saa muokata');
      if (patch.age_restricted && patch.fridge_sale) throw err('age_restricted', 'Ikärajallista tuotetta ei voi myydä kylmälaitteessa');
      if (patch.age_restricted && patch.fridge_sale == null) patch.fridge_sale = false;
      Object.assign(p.config, patch);
      return { ok: true };
    },
    admin_set_product_option_settings: (a) => {
      need('catalog.edit');
      if (!product(a.p_product_id)) throw err('product_not_found', 'Tuotetta ei löydy');
      if (a.p_required && !activeOpts(a.p_product_id).length) throw err('no_options', 'Pakollinen valinta vaatii vähintään yhden aktiivisen vaihtoehdon');
      st.settings[a.p_product_id] = { option_required: !!a.p_required, option_label: a.p_label ?? null, option_label_en: a.p_label_en ?? null };
      return { ok: true, product_id: a.p_product_id, option_required: !!a.p_required };
    },
    admin_list_vat_rates: () => ({ rates: st.vatRates.map((r) => ({ ...r, products: 0, addons: 0 })), missing: [], quote_only: [] }),
    // booking_172: peilaa booking._order_company_hits + admin_search_customers (rekisteri + tilausten yritykset)
    admin_search_customers: (a) => {
      const q = String(a.p_search || '').trim().toLowerCase();
      if (q.length < 2) return [];
      const lim = Math.min(Math.max(Number(a.p_limit) || 8, 1), 20);
      const digits = q.replace(/\D/g, '');
      const match = (blob, bid) => String(blob).toLowerCase().includes(q) || (digits.length >= 2 && String(bid || '').replace(/\D/g, '').includes(digits));
      const cust = st.customers.filter((c) => !c.anonymized_at && match(`${c.name || ''} ${c.email || ''} ${c.phone || ''} ${c.company || ''} ${c.business_id || ''}`, c.business_id)).slice(0, lim)
        .map((c) => ({ source: 'customer', id: c.id, customer_id: c.id, name: c.name, email: c.email || null, phone: c.phone || null, company: c.company || null, business_id: c.business_id || null, customer_kind: c.customer_kind || 'private', customer_type: c.customer_type || 'customer', street: c.address || null, zip: c.zip || null, city: c.city || null, einvoice_address: c.einvoice_address || null, einvoice_operator: c.einvoice_operator || null }));
      const taken = (h) => cust.some((x) => (h.business_id && x.business_id && normBusinessId(x.business_id) === normBusinessId(h.business_id)) || (x.company && x.company.toLowerCase() === h.company.toLowerCase()));
      const comp = mockOrderCompanyHits(q, lim).filter((h) => !taken(h)).map((h) => ({ source: 'orders', id: null, customer_kind: 'company', customer_type: null, name: h.contact_name, ...h }));
      return [...cust, ...comp];
    },
    admin_list_invoice_customers: (a) => {
      need('invoices.manage');
      const q = String(a.p_search || '').toLowerCase();
      return st.invCustomers.filter((c) => !q || `${c.company_name} ${c.contact_name || ''} ${c.email} ${c.business_id}`.toLowerCase().includes(q));
    },
    admin_search_invoice_customers: (a) => {
      need('invoices.manage');
      const q = String(a.p_search || '').trim().toLowerCase();
      if (q.length < 2) return [];
      const lim = Math.min(Math.max(Number(a.p_limit) || 10, 1), 20);
      const digits = q.replace(/\D/g, '');
      const match = (blob, businessId) => {
        if (String(blob).toLowerCase().includes(q)) return true;
        return digits.length >= 2 && String(businessId || '').replace(/\D/g, '').includes(digits);
      };
      const invoice = st.invCustomers.filter((c) => match(`${c.company_name || ''} ${c.contact_name || ''} ${c.email || ''} ${c.business_id || ''}`, c.business_id)).slice(0, lim).map((c) => ({ ...c, source: 'invoice' }));
      const takenIds = new Set(invoice.map((c) => c.customer_id).filter(Boolean));
      const takenBids = new Set(invoice.map((c) => (c.business_id ? normBusinessId(c.business_id) : '')).filter(Boolean));
      const booking = st.customers.filter((c) => !c.anonymized_at && match(`${c.name || ''} ${c.email || ''} ${c.phone || ''} ${c.company || ''} ${c.business_id || ''}`, c.business_id))
        .filter((c) => !takenIds.has(c.id) && !(c.business_id && takenBids.has(normBusinessId(c.business_id))))
        .slice(0, Math.max(lim - invoice.length, 0))
        .map((c) => {
          const company = String(c.company || '').trim();
          const name = String(c.name || '').trim();
          return { source: 'booking', id: null, customer_id: c.id, company_name: company || name, contact_name: company ? name : null, business_id: c.business_id || null, email: c.email || null, phone: c.phone || null, street: c.address || null, zip: c.zip || null, city: c.city || null, einvoice_address: c.einvoice_address || null, einvoice_operator: c.einvoice_operator || null, buyer_reference: c.invoice_reference || null };
        });
      const bookingAll = booking;
      const ord = mockOrderCompanyHits(q, lim)
        .filter((h) => !invoice.some((c) => (h.business_id && c.business_id && normBusinessId(c.business_id) === normBusinessId(h.business_id)) || String(c.company_name || '').toLowerCase() === h.company.toLowerCase()))
        .filter((h) => !bookingAll.some((c) => c.contact_name && ((h.business_id && c.business_id && normBusinessId(c.business_id) === normBusinessId(h.business_id)) || c.company_name.toLowerCase() === h.company.toLowerCase())))
        .slice(0, Math.max(lim - invoice.length, 0))
        .map((h) => ({ source: 'booking', origin: 'orders', id: null, customer_id: h.customer_id, company_name: h.company, contact_name: h.contact_name, business_id: h.business_id, email: h.email, phone: h.phone, street: h.street, zip: h.zip, city: h.city, country: h.country, einvoice_address: h.einvoice_address, einvoice_operator: h.einvoice_operator, buyer_reference: null }));
      return [...invoice, ...ord, ...booking.slice(0, Math.max(lim - invoice.length - ord.length, 0))];
    },
    admin_save_invoice_customer: (a) => {
      need('invoices.manage');
      const p = a.p || {};
      const name = String(p.company_name || p.name || '').trim();
      if (name.length < 2) throw err('invalid_company_name', 'Anna yrityksen nimi');
      const bid = p.business_id ? normBusinessId(p.business_id) : null;
      if (bid && !validBusinessId(bid)) throw err('invalid_business_id', 'Tarkista y-tunnus');
      const ei = p.einvoice_address ? normOvt(p.einvoice_address) : null;
      const op = p.einvoice_operator ? normOvt(p.einvoice_operator) : null;
      if (!!ei !== !!op) throw err('einvoice_incomplete', 'Anna sekä verkkolaskuosoite että välittäjätunnus');
      if (ei && !validOvt(ei, bid)) throw err('invalid_einvoice_address', 'Tarkista verkkolaskuosoite');
      if (op && !validOperator(op)) throw err('invalid_einvoice_operator', 'Tarkista välittäjätunnus');
      const email = p.email ? String(p.email).trim().toLowerCase() : null;
      const clash = (id) => st.invCustomers.find((c) => c.id !== id && bid && c.business_id && normBusinessId(c.business_id) === bid);
      const row = { id: a.p_id || st.invCustomers.length + 1, company_name: name, name, contact_name: p.contact_name || null, business_id: bid, vat_id: bid ? `FI${bid.replace(/\D/g, '')}` : null, email, phone: p.phone || null, street: p.street || null, zip: p.zip || null, city: p.city || null, country: 'FI', einvoice_address: ei, einvoice_operator: op, buyer_reference: p.buyer_reference || null, address: [p.street, [p.zip, p.city].filter(Boolean).join(' ')].filter(Boolean).join(', '), source: 'invoice' };
      if (p.customer_id) row.customer_id = p.customer_id;
      else if (!a.p_id) row.customer_id = null;
      if (a.p_id) {
        const i = st.invCustomers.findIndex((c) => c.id === a.p_id);
        if (i < 0) throw err('not_found', 'Asiakasta ei löydy');
        const other = clash(a.p_id);
        if (other) throw Object.assign(err('customer_exists', 'Yritys on jo rekisterissä'), { details: { hint: JSON.stringify(other), details: 'customer_exists' } });
        st.invCustomers[i] = { ...st.invCustomers[i], ...row, id: a.p_id };
        return st.invCustomers[i];
      }
      const other = clash(null);
      if (other) throw Object.assign(err('customer_exists', 'Yritys on jo rekisterissä'), { details: { hint: JSON.stringify(other), details: 'customer_exists' } });
      if (!bid && email && p.ack_name_email !== true) {
        const same = st.invCustomers.find((c) => !c.business_id && String(c.company_name || '').trim().toLowerCase() === name.toLowerCase() && String(c.email || '').toLowerCase() === email);
        if (same) throw Object.assign(err('name_email_match', 'Samanniminen asiakas samalla sähköpostilla on jo rekisterissä'), { details: { hint: JSON.stringify(same), details: 'name_email_match' } });
      }
      st.invCustomers.push(row);
      return row;
    },
    admin_save_invoice: (a) => {
      need('invoices.manage');
      const p = a.p || {};
      const customer = st.invCustomers.find((c) => c.id === p.customer_id);
      if (!customer) throw err('invalid_customer', 'Valitse laskutusasiakas');
      const lines = (p.lines || []).map((l, i) => {
        const rate = Number(l.vat_rate);
        if (!st.vatRates.some((r) => r.active && r.rate === rate)) throw err('invalid_vat', 'ALV-kanta ei ole käytössä');
        const calc = storedLineFromInput({ quantity: l.quantity, unitPriceNet: l.unit_price_net, unitPriceGross: l.unit_price_gross, vatRate: l.vat_rate, priceBasis: l.price_basis === 'gross' ? 'gross' : 'net' });
        if (!calc) throw err('invalid_lines', 'Tarkista rivit');
        return { line_no: i + 1, description: l.description, unit: l.unit || 'kpl', ...calc };
      });
      if (!lines.length) throw err('invalid_lines', 'Laskulla pitää olla rivejä');
      const today = todayHel(now);
      const sum = (k) => Math.round(lines.reduce((s, l) => s + l[k], 0) * 100) / 100;
      const locked = p.snapshot_mode === 'invoice';
      const view = locked ? { ...customer, ...(p.customer_override || {}), id: customer.id } : { ...customer };
      const base = { customer_id: customer.id, customer: view, customer_snapshot: view, customer_snapshot_locked: locked, lines, invoice_date: p.invoice_date || today, due_date: p.due_date || today, buyer_reference: p.buyer_reference || null, notes: p.notes || null, locale: 'fi', seller_snapshot: { name: 'Sipoonjoen Perinnesauna', legal_name: 'Havuhattu Oy', business_id: '0112038-9', vat_id: 'FI01120389', iban: '', bic: '', bank_name: '' }, total_net: sum('line_net'), total_vat: sum('line_vat'), total_gross: sum('line_gross'), dispatch_status: 'none', dispatch_error: null, kind: 'debit', status: 'draft', invoice_no: null, reference_no: null, public_token: `00000000-0000-4000-8000-${String(st.invoices.length + 1).padStart(12, '0')}` };
      if (a.p_id) {
        const inv = st.invoices.find((x) => x.id === a.p_id);
        if (!inv || inv.status !== 'draft') throw err('invoice_locked', 'Vain luonnosta voi muokata');
        Object.assign(inv, base, { id: inv.id, public_token: inv.public_token });
        return inv;
      }
      const inv = { id: st.invoices.length + 1, ...base };
      st.invoices.push(inv);
      return inv;
    },
    admin_list_invoices: (a) => {
      need('invoices.manage');
      const q = String(a.p_search || '').toLowerCase();
      const rows = st.invoices.filter((i) => (!a.p_status || i.status === a.p_status) && (!a.p_kind || i.kind === a.p_kind) && (!q || `${i.invoice_no} ${i.customer?.company_name} ${i.customer?.business_id}`.toLowerCase().includes(q)));
      return { total: rows.length, rows };
    },
    admin_get_invoice: (a) => { need('invoices.manage'); const inv = st.invoices.find((i) => i.id === a.p_id); if (!inv) throw err('not_found', 'Laskua ei löydy'); return inv; },
    admin_send_invoice: (a) => {
      need('invoices.manage');
      const inv = st.invoices.find((i) => i.id === a.p_id);
      if (!inv) throw err('not_found', 'Laskua ei löydy');
      if (inv.status === 'draft') {
        st.invSeq += 1;
        inv.invoice_no = `L${String(st.invSeq).padStart(6, '0')}`;
        inv.reference_no = fiReference(`7310${st.invSeq}`);   // booking_175: etuliite (settings.invoice_reference_prefix, oletus 7310) + numero + 7-3-1
        inv.status = 'sent';
      }
      if (a.p_einvoice) {
        if (!inv.customer?.einvoice_address) throw err('einvoice_incomplete', 'Verkkolasku tarvitsee OVT-tunnuksen');
        inv.dispatch_status = 'dry_run';
        inv.dispatch_error = 'dry_run';
        st.invLog.push({ invoice_id: inv.id, status: 'dry_run', error: 'dry_run', attempt: st.invLog.length + 1 });
      }
      return inv;
    },
    admin_mark_invoice_paid: (a) => { need('invoices.manage'); const inv = st.invoices.find((i) => i.id === a.p_id); if (!inv || inv.kind === 'credit' || !['sent', 'overdue'].includes(inv.status)) throw err('invalid_status', 'Vain lähetetty veloituslasku'); inv.status = 'paid'; return inv; },
    admin_void_invoice: (a) => { need('invoices.manage'); const inv = st.invoices.find((i) => i.id === a.p_id); if (!inv || inv.status !== 'draft') throw err('invalid_status', 'Vain luonnos'); inv.status = 'voided'; return inv; },
    admin_credit_invoice: (a) => {
      need('invoices.manage');
      const inv = st.invoices.find((i) => i.id === a.p_id);
      if (!inv || inv.kind !== 'debit' || !['sent', 'paid', 'overdue'].includes(inv.status)) throw err('invalid_status', 'Hyvitys tehdään lähetetystä laskusta');
      const credit = { ...inv, id: st.invoices.length + 1, kind: 'credit', status: 'draft', invoice_no: null, reference_no: null, credit_of_id: inv.id, lines: inv.lines.map((l) => ({ ...l, quantity: l.quantity, unit_price_net: l.unit_price_net == null ? null : -l.unit_price_net, unit_price_gross: l.unit_price_gross == null ? null : -l.unit_price_gross, line_net: -l.line_net, line_vat: -l.line_vat, line_gross: -l.line_gross })), total_gross: -inv.total_gross, dispatch_status: 'none' };
      st.invoices.push(credit);
      return credit;
    },
    admin_retry_invoice_dispatch: (a) => { need('invoices.manage'); const inv = st.invoices.find((i) => i.id === a.p_id); if (!inv) throw err('not_found', 'Laskua ei löydy'); inv.dispatch_status = 'dry_run'; return inv; },
    admin_list_invoice_dispatch: (a) => { need('invoices.manage'); return st.invLog.filter((d) => d.invoice_id === a.p_invoice_id); },
    admin_list_messages: () => {
      need('messages.edit');
      return { timed_enabled: st.messagesTimed === true, messages: st.messages.map((m) => ({ ...m, delivery_mode: m.delivery_mode || 'scheduled', product_ids: [...m.product_ids] })) };
    },
    admin_set_messages_timed: (a) => {
      need('messages.edit');
      if (typeof a.p_enabled !== 'boolean') throw err('invalid_timing', 'Kytkin puuttuu');
      st.messagesTimed = a.p_enabled;
      return { ok: true, timed_enabled: st.messagesTimed };
    },
    admin_save_message: (a) => {
      need('messages.edit');
      // booking_141: puuttuva delivery_mode → olemassa oleva viesti säilyttää tapansa (kuten tietokanta).
      const prev = a.p_id ? st.messages.find((m) => m.id === a.p_id) : null;
      const data = { ...(a.p_data || {}) };
      if (prev && data.delivery_mode == null) data.delivery_mode = prev.delivery_mode || 'scheduled';
      const v = validateMessage(data);
      if (!v.ok) throw err(v.code, v.code);
      const known = new Set(st.products.map((p) => p.id));
      if (v.value.product_ids.some((id) => !known.has(id))) throw err('invalid_product', 'Tuntematon tuote');
      if (a.p_id) {
        const row = st.messages.find((m) => m.id === a.p_id);
        if (!row) throw err('not_found', 'Viestiä ei löydy');
        Object.assign(row, v.value);
        return { ok: true, id: row.id, message: { ...row, product_ids: [...row.product_ids] } };
      }
      const row = { id: st.messageSeq++, ...v.value };
      st.messages.push(row);
      return { ok: true, id: row.id, message: { ...row, product_ids: [...row.product_ids] } };
    },
    admin_create_invoice_from_order: (a) => {
      need('invoices.manage');
      const res = st.reservations.find((r) => r.order_id === a.p_order_id || r.order_no === a.p_order_id);
      if (!res) throw err('not_found', 'Tilausta ei löydy');
      const customer = st.invCustomers[0] || { id: 1, company_name: res.customer_name, name: res.customer_name, email: res.customer_email, business_id: null, einvoice_address: null, einvoice_operator: null };
      if (!st.invCustomers.length) st.invCustomers.push(customer);
      const rate = 25.5;
      const gross = Number(res.total_gross) || 0;
      const vat = Math.round(gross * rate / (100 + rate) * 100) / 100;
      const net = Math.round((gross - vat) * 100) / 100;
      const inv = { id: st.invoices.length + 1, customer_id: customer.id, customer, status: 'draft', kind: 'debit', invoice_no: null, reference_no: null, due_date: todayHel(now), invoice_date: todayHel(now), order_id: res.order_id, dispatch_status: 'none', seller_snapshot: { legal_name: 'Havuhattu Oy', business_id: '0112038-9', vat_id: 'FI01120389' }, lines: [{ description: res.product_name, quantity: 1, unit: 'kpl', vat_rate: rate, line_gross: gross, line_net: net, line_vat: vat }], total_gross: gross, total_net: net, total_vat: vat, public_token: '11111111-1111-4111-8111-111111111111' };
      st.invoices.push(inv);
      return inv;
    },
  };
  Object.assign(handlers, paylinkWatchHandlers({ st, need, err, now }));
  // booking_158: tapahtumat ja koulutukset (events-mock.js) + tuotteen kopio (admin_product_copy: 'Kopio: nimi', piilotettu, ei myynnissä)
  const eventsMock = createEventsMock({ today, products: st.products });
  Object.assign(handlers, eventsMock.handlers, {
    admin_product_copy: (a) => {
      const src = st.products.find((p) => p.id === +a.p_product_id);
      if (!src) throw err('not_found', 'Tuotetta ei löydy');
      const id = Math.max(...st.products.map((p) => p.id), 700) + 1;
      st.products.push({ ...structuredClone(src), id, name: `Kopio: ${src.name}`.slice(0, 200), slug: `${src.slug || 'tuote'}-kopio-${id}`, active: false, config: src.config ? { ...structuredClone(src.config), bookable: false, shop_visible: false } : src.config });
      return { product_id: id, slug: `${src.slug || 'tuote'}-kopio-${id}` };
    },
  });
  st.events = eventsMock.state;
  async function rpc(name, args = {}) {
    st.calls.push({ name, args });
    if (delay) await new Promise((r) => setTimeout(r, delay));
    const f = handlers[name];
    if (!f) throw err('mock_unsupported', `Kokeilutila: toimintoa ${name} ei ole mockattu (ei verkkokutsua).`);
    staffOnly();
    return structuredClone(f(args || {}));
  }
  return { rpc, state: st, today };
}
