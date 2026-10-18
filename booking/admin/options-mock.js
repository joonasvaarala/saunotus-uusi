// Hallinnan kokeilutila (?mock=1) ja testien mock: vastaa selaimessa Päivä-, Varaukset-, Uusi varaus (resurssi)- ja Tuotevalinnat-näkymien RPC:ihin (nimet ja p_-parametrit
// sopimuksen §14/§15 mukaan, rivit samassa muodossa kuin migraatiossa booking_50). KEKSITTYÄ DATAA: mikään ei mene verkkoon eikä tallennu (tila on vain muistissa).
// Puhdas moduuli (ei DOM:ia) → node --test voi ajaa sen. Tuntematon RPC → virhe (ei koskaan verkkokutsua).
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
const SECRET_KEYS = new Set(['client_id', 'client_secret', 'api_key', 'password', 'token', 'refresh_token', 'access_token', 'secret', 'private_key', 'authorization', 'redirect_uri']);
const SALES_RATES = ['25.5', '13.5', '0', '14', '24', '10'];
const METHODS = ['cash', 'card_terminal', 'mobilepay', 'bank_transfer', 'invoice', 'gift_card', 'partner_voucher', 'visma_pay', 'annual_card', 'pay_later', 'other'];
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
const PERMS = ['bookings.manage', 'bookings.override', 'customers.manage', 'catalog.edit', 'payments.manage', 'reports.view', 'settings.edit', 'pos.use'];
const CODE_RE = /^[a-z0-9_]{1,40}$/;

export function createAdminMock({ now = new Date(), delay = 0, perms = PERMS, role = 'manager' } = {}) {
  const today = todayHel(now);
  const st = {
    calls: [], perms: [...perms],
    generalSettings: [
      { key: 'business_name', value: 'Havuhattu Oy', is_public: true },
      { key: 'timezone', value: 'Europe/Helsinki', is_public: false },
    ],
    procountor: {
      mode: 'off', environment: 'pts', daily_enabled: false, api_prefix: '/supported/api', vat_status: '', approved_by: '', bank_account: '',
      accounts: { rounding: '', sales_by_vat: {}, clearing_by_method: {} },
    },
    products: [
      { id: 10, name: 'Saunahoito', name_en: 'Sauna treatment', price: 85, vat_rate: 25.5, active: true, category: 'treatment', description: 'Hoitosauna Rauni', config: { resource_class: 'resourced', lifecycle: 'current', sale_kind: 'other', duration_minutes: 90, min_persons: 1, max_persons: 4, bookable: true, shop_visible: true, public_slots: true, time_window_class: 'therapy', required_skill: 'treatment', audience: 'consumer' } },
      { id: 8, name: 'Rituaali 90 min', price: 64, vat_rate: 25.5, active: true, category: 'ritual', config: { resource_class: 'resourced', lifecycle: 'current', sale_kind: 'other', duration_minutes: 90, min_persons: 1, max_persons: 6, bookable: true, shop_visible: true, public_slots: true, public_weekdays: [6, 7], time_window_class: 'ritual', audience: 'consumer' } },
      { id: 7, name: 'Saunarituaali ja savusaunavuoro (la & su)', name_en: 'Sauna Ritual & Smoke Sauna Session', price: 49, price_type: 'per_person', vat_rate: 25.5, active: true, category: 'ritual', config: { resource_class: 'resourced', lifecycle: 'current', sale_kind: 'other', duration_minutes: 120, min_persons: 1, max_persons: 6, bookable: true, shop_visible: true, public_slots: true, public_weekdays: [6, 7], time_window_class: 'ritual', required_skill: 'yleinen', audience: 'consumer' } },
      { id: 3, name: 'Yleinen saunavuoro', price: 18, vat_rate: 25.5, active: true, category: 'public_sauna', config: { resource_class: 'shift', lifecycle: 'current', sale_kind: 'slots', bookable: true, shop_visible: true, audience: 'consumer' } },
      { id: 101, name: 'Vichy', name_en: 'Vichy', price: 3, vat_rate: 13.5, active: true, category: 'other', config: { sale_kind: 'other', pos_enabled: true, pos_sort: 10, fridge_sale: true, age_restricted: false, bookable: false, shop_visible: false, audience: 'consumer' } },
      { id: 102, name: 'Sipsit', name_en: 'Crisps', price: 3, vat_rate: 13.5, active: true, category: 'other', config: { sale_kind: 'other', pos_enabled: true, pos_sort: 20, fridge_sale: false, age_restricted: false, bookable: false, shop_visible: false, audience: 'consumer' } },
      { id: 103, name: 'Pyyhevuokra', name_en: 'Towel rental', price: 5, vat_rate: 25.5, active: true, category: 'product_rental', config: { sale_kind: 'other', pos_enabled: true, pos_sort: 30, fridge_sale: false, age_restricted: false, bookable: false, shop_visible: false, audience: 'consumer' } },
      { id: 104, name: 'Lahjakortti', price: 58, vat_rate: 0, active: true, category: 'gift_card', config: { sale_kind: 'other', pos_enabled: false, fridge_sale: false, age_restricted: false, bookable: false, shop_visible: false, audience: 'consumer' } },
    ],
    options: [   // product_options (10 = Saunahoito)
      { id: 1, product_id: 10, code: 'hunajahoito', name: 'Hunajahoito', name_en: 'Honey treatment', sort_order: 10, active: true, description: null, description_en: null },
      { id: 2, product_id: 10, code: 'vihtahoito', name: 'Vihtahoito', name_en: 'Birch whisk treatment', sort_order: 20, active: true, description: null, description_en: null },
      { id: 3, product_id: 10, code: 'suolahoito', name: 'Suolahoito', name_en: 'Salt treatment', sort_order: 30, active: true, description: null, description_en: null },
      { id: 4, product_id: 10, code: 'turvehoito', name: 'Turvehoito', name_en: 'Peat treatment', sort_order: 40, active: true, description: null, description_en: null },
    ],
    settings: { 10: { option_required: true, option_label: 'Valitse hoito', option_label_en: 'Choose your treatment' } },
    customers: [{ id: 1, name: 'Aino Testaaja', email: 'aino@example.com', phone: '+358401110001' }, { id: 2, name: 'Eero Esimerkki', email: 'eero@example.com', phone: '+358401110002' }, { id: 3, name: 'Helmi Hiljainen', email: 'helmi@example.com', phone: '+358401110003' }, { id: 4, name: 'Ilmari Iltavuoro', email: 'ilmari@example.com', phone: '+358401110004' }],
    reservations: [], seq: { res: 900, order: 7000 },
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
    coldUnits: [{ id: 1, code: 'pukuhuone-abcdef1234', name: 'Pukuhuone, jääkaappi 1', location: 'Pukuhuone', active: true, path: '/juomat/?laite=pukuhuone-abcdef1234', path_en: '/en/drinks/?laite=pukuhuone-abcdef1234', print_url: 'https://uusi.saunotus.com/juomat/?laite=pukuhuone-abcdef1234' }],
  };
  if (role === 'staff') st.perms = st.perms.filter((p) => p !== 'settings.edit');
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
  const inRange = (r, a) => (!a.p_from || r.starts_at >= a.p_from) && (!a.p_to || r.starts_at < a.p_to);
  const handlers = {
    current_staff_role: () => role,
    admin_my_permissions: () => ({ role, role_label: role === 'staff' ? 'Työntekijä (esimerkki)' : role === 'admin' ? 'Pääkäyttäjä (esimerkki)' : 'Päällikkö (esimerkki)', permissions: st.perms }),
    admin_list_products: () => st.products.map((p) => ({ ...p })),
    'select:payment_methods': () => [{ code: 'pay_later', label: 'Maksu myöhemmin', is_manual: true, active: true }, { code: 'cash', label: 'Käteinen', is_manual: true, active: true }, { code: 'card_terminal', label: 'Korttipääte', is_manual: true, active: true }],
    'select:resources': () => [{ id: 1, code: 'rauni', name: 'Rauni', active: true }, { id: 2, code: 'lovi', name: 'Lovi', active: true }],
    'select:product_space_rules': () => [10, 8, 7].map((pid) => ({ product_id: pid, leg_no: 1, priority: 1, space_id: 1, mode: 'exclusive', min_persons: 1, max_persons: 6, selection: 'auto', active: true })),
    admin_list_addons: () => [],
    admin_list_customers: (a) => st.customers.filter((c) => !a.p_search || `${c.name} ${c.email} ${c.phone}`.toLowerCase().includes(String(a.p_search).toLowerCase())).slice(0, a.p_limit || 5),
    admin_day_shifts: () => [], admin_upcoming_shifts: () => [],
    admin_list_reservations: (a) => {
      let rows = st.reservations.filter((r) => inRange(r, a));
      if (a.p_status === 'active') rows = rows.filter((r) => ['pending', 'confirmed'].includes(r.status)); else if (a.p_status) rows = rows.filter((r) => r.status === a.p_status);
      if (a.p_product_id) rows = rows.filter((r) => r.product_id === a.p_product_id);
      if (a.p_source) rows = rows.filter((r) => r.source === a.p_source);
      if (a.p_option_missing === true) rows = rows.filter((r) => missing(r));   // booking_72: vain hoito valitsematta (option_missing)
      if (a.p_search) { const q = String(a.p_search).toLowerCase(); rows = rows.filter((r) => `${r.customer_name} ${r.customer_email} ${r.customer_phone} ${r.order_no}`.toLowerCase().includes(q)); }
      rows = rows.sort((x, y) => x.starts_at.localeCompare(y.starts_at));
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
    admin_set_setting: (a) => {
      need('settings.edit');
      const row = st.generalSettings.find((s) => s.key === a.p_key);
      if (row) row.value = a.p_value;
      return { ok: true };
    },
    'select:settings': () => st.generalSettings.map((s) => ({ ...s })),
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
    admin_day_view: (a) => {
      const rs = st.reservations.filter((r) => r.starts_at >= helIso(a.p_date, '00:00') && r.starts_at < helIso(addDays(a.p_date, 1), '00:00'));
      return { date: a.p_date, sessions: [], blocks: [], prep: [], addon_totals: [],
        reservations: rs.map((r) => ({ reservation_id: r.reservation_id, order_id: r.order_id, order_no: r.order_no, status: r.status, payment_status: r.payment_status, product_name: r.product_name, mode: r.mode, starts_at: r.starts_at, ends_at: r.ends_at, persons: r.persons,
          customer_name: r.customer_name, customer_phone: r.customer_phone, source: 'native', external_id: null, customer_kind: 'private', company: null, space_code: r.space_code, lifecycle: r.lifecycle, quota_exempt: false, override_reason: null,
          therapist_missing: false, therapist_missing_open: false, legs: r.legs, addons: [], option: optJson(r.option_id), option_missing: missing(r) })) };
    },
    admin_get_order: (a) => {
      const r = st.reservations.find((x) => x.order_id === a.p_order_id); if (!r) throw err('not_found', 'Tilausta ei löydy');
      return { order_id: r.order_id, order_no: r.order_no, status: r.order_status, payment_status: r.payment_status, total: r.total_gross, source_channel: 'web', created_at: r.created_at, customer_kind: 'private', billing: null, invoice_reference: null,
        customer: { id: r.customer_id, name: r.customer_name, email: r.customer_email, phone: r.customer_phone },
        reservations: [{ id: r.reservation_id, status: r.status, product_name: r.product_name, mode: r.mode, starts_at: r.starts_at, ends_at: r.ends_at, persons: r.persons, notes: null, item_total: r.total_gross, product_id: r.product_id,
          option: optJson(r.option_id), option_choices: choicesJson(r.product_id), option_missing: missing(r), addons: [] }], items: [], payments: [], balance: 0, is_native: true };
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
      return { mobilepay_mode: 'test', vismapay_mode: 'dry_run', site_base_url: 'https://uusi.saunotus.com', drinks_path: '/juomat/', drinks_path_en: '/en/drinks/', tenders: [
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
      const id = ++st.seq.order;
      const row = { order_id: id, order_no: id, public_token: `00000000-0000-4000-8000-${String(id).padStart(12, '0')}`, total, status: 'pending', payment_status: 'unpaid', source_channel: 'pikakassa', lines, receipts: [], polls: 0, arm: false };
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
      return { ok: true, payment_id: 1, link_path: '/maksa/?p=11111111-2222-4333-8444-555555555555', amount: o?.total ?? 0, online_payment_enabled: false };
    },
    admin_list_cold_units: () => {
      if (!st.perms.includes('pos.use') && !st.perms.includes('catalog.edit')) throw err('forbidden', 'Ei oikeutta');
      return st.coldUnits.map((d) => ({ ...d }));
    },
    admin_upsert_cold_unit: (a) => {
      need('catalog.edit');
      const name = String(a.p_name || '').trim();
      if (!name) throw err('invalid_param', 'Nimi puuttuu');
      if (a.p_id) {
        const d = st.coldUnits.find((x) => x.id === a.p_id);
        if (!d) throw err('not_found', 'Laitetta ei löydy');
        d.name = name; d.location = a.p_location || null; d.active = a.p_active !== false;
        return { ...d };
      }
      const code = 'laite-' + Math.random().toString(16).slice(2, 12);
      const d = { id: st.coldUnits.length + 1, code, name, location: a.p_location || null, active: a.p_active !== false, path: `/juomat/?laite=${code}`, path_en: `/en/drinks/?laite=${code}`, print_url: `https://uusi.saunotus.com/juomat/?laite=${code}` };
      st.coldUnits.push(d);
      return { ...d };
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
  };
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
