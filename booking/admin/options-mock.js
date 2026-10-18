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
const PERMS = ['bookings.manage', 'bookings.override', 'customers.manage', 'catalog.edit', 'payments.manage', 'reports.view', 'quotes.manage'];
const CODE_RE = /^[a-z0-9_]{1,40}$/;

export function createAdminMock({ now = new Date(), delay = 0, perms = PERMS, role = 'manager' } = {}) {
  const today = todayHel(now);
  const st = {
    calls: [], perms: [...perms],
    products: [
      { id: 10, name: 'Saunahoito', name_en: 'Sauna treatment', price: 85, vat_rate: 25.5, active: true, category: 'treatment', description: 'Hoitosauna Rauni', config: { resource_class: 'resourced', lifecycle: 'current', sale_kind: 'other', duration_minutes: 90, min_persons: 1, max_persons: 4, bookable: true, shop_visible: true, public_slots: true, time_window_class: 'therapy', required_skill: 'treatment' } },
      { id: 8, name: 'Rituaali 90 min', price: 64, vat_rate: 25.5, active: true, category: 'ritual', config: { resource_class: 'resourced', lifecycle: 'current', sale_kind: 'other', duration_minutes: 90, min_persons: 1, max_persons: 6, bookable: true, shop_visible: true, public_slots: true, public_weekdays: [6, 7], time_window_class: 'ritual' } },
      { id: 7, name: 'Saunarituaali ja savusaunavuoro (la & su)', name_en: 'Sauna Ritual & Smoke Sauna Session', price: 49, price_type: 'per_person', vat_rate: 25.5, active: true, category: 'ritual', config: { resource_class: 'resourced', lifecycle: 'current', sale_kind: 'other', duration_minutes: 120, min_persons: 1, max_persons: 6, bookable: true, shop_visible: true, public_slots: true, public_weekdays: [6, 7], time_window_class: 'ritual', required_skill: 'yleinen' } },
      { id: 3, name: 'Yleinen saunavuoro', price: 18, vat_rate: 25.5, active: true, category: 'public_sauna', config: { resource_class: 'shift', lifecycle: 'current', sale_kind: 'slots', bookable: true, shop_visible: true } },
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
    quotes: [{ id: 1, status: 'new', company_name: 'Esimerkki Oy', contact_name: 'Maija Meikäläinen', email: 'maija@example.test', phone: '0401234567', preferred_when: 'ensi viikon perjantai', persons: 12, offerings: ['sauna', 'ritual'], offering_other: null, message: 'toive metsäkävelystä', locale: 'fi', created_at: now.toISOString(), handled_at: null, admin_note: null }],
  };
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
      if (a.p_search) { const q = String(a.p_search).toLowerCase(); rows = rows.filter((r) => `${r.customer_name} ${r.customer_email} ${r.customer_phone} ${r.order_no}`.toLowerCase().includes(q)); }
      rows = rows.sort((x, y) => x.starts_at.localeCompare(y.starts_at));
      const total = rows.length; rows = rows.slice(a.p_offset || 0, (a.p_offset || 0) + (a.p_limit || 50));
      return rows.map((r) => ({ ...view(r), total_count: total }));
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
    admin_list_business_quotes: (a) => {
      need('quotes.manage');
      const stt = a?.p_status ? String(a.p_status) : '';
      if (stt && !['new', 'handled', 'offered', 'closed'].includes(stt)) throw err('invalid_status', 'Tila on new, handled, offered tai closed');
      return st.quotes.filter((q) => !stt || q.status === stt);
    },
    admin_set_business_quote_status: (a) => {
      need('quotes.manage');
      const s = String(a?.p_status ?? '');
      if (!['new', 'handled', 'offered', 'closed'].includes(s)) throw err('invalid_status', 'Tila on new, handled, offered tai closed');
      if (a?.p_note != null && String(a.p_note).trim().length > 2000) throw err('invalid_note', 'Muistiinpano on liian pitkä');
      const q = st.quotes.find((x) => x.id === a.p_id); if (!q) throw err('not_found', 'Tarjouspyyntöä ei löydy');
      q.status = s;
      if (a.p_note != null) q.admin_note = String(a.p_note).trim() || null;
      q.handled_at = now.toISOString();
      return { ok: true, id: q.id, status: s };
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
