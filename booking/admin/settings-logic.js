// Asetussivun kortit: tarkistus selaimessa ja mockissa. Palvelin (admin_save_settings) tarkistaa uudelleen.
// Ei uusia booking.settings-avaimia. Live-tilat, Procountor ja vastaanottajarajaus eivät ole tässä.
import { normBusinessId, validBusinessId } from '../shop/src/invoice-validate.js';
import { PHONE_DISPLAY_FI } from '../shop/src/phone.js';

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const MANUAL_METHODS = ['pay_later', 'card_terminal', 'bank_transfer', 'invoice', 'partner_voucher', 'other'];

export const TECHNICAL_LIMITS = {
  rl_ip_per_10min: [1, 200],
  rl_email_per_10min: [1, 100],
  rl_change_per_10min: [1, 200],
  rl_avail_per_10min: [1, 500],
  rl_order_get_per_10min: [1, 500],
  rl_order_add_per_10min: [1, 200],
  rl_order_req_per_10min: [1, 60],
  public_treatment_global_per_hour: [1, 500],
  public_treatment_max_open_per_email: [1, 50],
  'gift_cards.rl_check_fail_per_10min': [1, 100],
  'gift_cards.rl_global_fail_per_10min': [1, 2000],
  'gift_cards.rl_buy_per_10min': [1, 50],
  business_quote_rl_ip_per_10min: [1, 50],
  business_quote_rl_email_per_hour: [1, 30],
  texts_max_proposals_per_day: [1, 2000],
  texts_bot_max_approvals_per_day: [1, 1000],
  'voucher_claims.max_attempts': [1, 30],
};

const SELLER_FIELDS = ['name', 'legal_name', 'trade_name', 'business_id', 'vat_id', 'street', 'postal_code', 'city', 'country', 'phone', 'email', 'website', 'footer'];

function fail(code, message) {
  return { ok: false, code, message };
}

function only(obj, keys) {
  if (obj == null || typeof obj !== 'object' || Array.isArray(obj)) return fail('invalid_value', 'Tallennus on tyhjä');
  const extra = Object.keys(obj).filter((k) => !keys.includes(k));
  if (extra.length) return fail('invalid_value', 'Kenttää ei voi tallentaa tältä sivulta');
  return null;
}

function text(raw, min, max, message) {
  if (typeof raw !== 'string') return null;
  const v = raw.trim();
  if ([...v].length < min || [...v].length > max) return null;
  return v;
}

function integer(raw, min, max) {
  if (typeof raw === 'boolean' || raw == null || raw === '') return null;
  const n = typeof raw === 'number' ? raw : Number(String(raw).trim());
  if (!Number.isInteger(n) || n < min || n > max) return null;
  return n;
}

function bool(raw) {
  return raw === true || raw === false ? raw : null;
}

export function emailOk(raw, { allowEmpty = false } = {}) {
  const v = String(raw ?? '').trim().toLowerCase();
  if (!v) return allowEmpty ? '' : null;
  return EMAIL_RE.test(v) ? v : null;
}

export function ibanOk(raw) {
  const s = String(raw ?? '').replace(/\s+/g, '').toUpperCase();
  if (!s) return '';
  if (!/^FI\d{16}$/.test(s)) return null;
  const moved = s.slice(4) + s.slice(0, 4);
  let digits = '';
  for (const ch of moved) digits += ch >= 'A' && ch <= 'Z' ? String(ch.charCodeAt(0) - 55) : ch;
  let rem = 0;
  for (const ch of digits) rem = (rem * 10 + Number(ch)) % 97;
  return rem === 1 ? s : null;
}

export function bicOk(raw) {
  const s = String(raw ?? '').replace(/\s+/g, '').toUpperCase();
  if (!s) return '';
  return /^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$/.test(s) ? s : null;
}

export function splitFrom(raw) {
  const m = String(raw ?? '').match(/^\s*(.*?)\s*<([^<>\s]+)>\s*$/);
  if (!m || !EMAIL_RE.test(m[2].trim())) return null;
  return { name: m[1].trim(), email: m[2].trim().toLowerCase() };
}

export function joinFrom(name, email) {
  return `${name} <${email}>`;
}

export function modeTextKey(mode) {
  if (mode === 'live') return 'mode_live';
  if (mode === 'test') return 'mode_test';
  if (mode === 'dry_run') return 'mode_dry';
  return 'mode_off';
}

export function modeBadgeKind(mode) {
  if (mode === 'live') return 'ok';
  if (mode === 'test' || mode === 'dry_run') return 'warn';
  return '';
}

export function overviewNotices(bundle) {
  const notes = [];
  const vp = bundle?.vismapay?.mode;
  const mp = bundle?.mobilepay?.mode;
  const mo = bundle?.montonio?.mode;
  const em = bundle?.resend?.mode;
  if (vp === 'test' || mp === 'test' || mo === 'test') notes.push('warn_pay_test');
  if (vp === 'live' || mp === 'live' || mo === 'live') notes.push('warn_pay_live');
  if (em === 'live' && !bundle?.resend?.allowlist_on) notes.push('warn_allowlist_open');
  else if (em !== 'live') notes.push('warn_email_not_live');
  return notes;
}

function sellerValue(raw) {
  const bad = only(raw, SELLER_FIELDS);
  if (bad) return bad;
  const name = text(raw.name, 2, 120, '');
  const legal = text(raw.legal_name, 2, 120, '');
  const trade = text(raw.trade_name, 2, 120, '');
  const businessId = validBusinessId(raw.business_id) ? normBusinessId(raw.business_id) : null;
  const vat = typeof raw.vat_id === 'string' ? raw.vat_id.replace(/\s/g, '').toUpperCase() : '';
  const street = text(raw.street, 1, 120, '');
  const postal = typeof raw.postal_code === 'string' && /^\d{5}$/.test(raw.postal_code.trim()) ? raw.postal_code.trim() : null;
  const city = text(raw.city, 1, 80, '');
  const country = typeof raw.country === 'string' && /^[a-zA-Z]{2}$/.test(raw.country.trim()) ? raw.country.trim().toUpperCase() : null;
  const phone = typeof raw.phone === 'string' ? raw.phone.trim() : '';
  const phoneOk = /^[0-9][0-9 +()-]{4,29}$/.test(phone) && phone.replace(/\D/g, '').length >= 5;
  const email = emailOk(raw.email);
  const website = typeof raw.website === 'string' && /^https:\/\/\S{3,180}$/.test(raw.website.trim()) ? raw.website.trim() : null;
  const footer = text(raw.footer ?? '', 0, 160, '');
  if (!name || !legal || !trade || !businessId || !/^FI\d{8}$/.test(vat) || !street || !postal || !city || !country || !phoneOk || !email || !website || footer == null) {
    return fail('invalid_value', 'Tarkista yrityksen tiedot: nimi, y-tunnus, ALV-tunnus, osoite, puhelin, sähköposti ja verkkosivu.');
  }
  return {
    ok: true,
    value: {
      name, legal_name: legal, trade_name: trade, business_id: businessId, vat_id: vat,
      street, postal_code: postal, city, country, phone, email, website, footer,
    },
  };
}

export function validateSection(section, raw) {
  const body = raw && typeof raw === 'object' ? raw : {};
  switch (section) {
    case 'pause': {
      const bad = only(body, ['public_booking_enabled']);
      if (bad) return bad;
      const on = bool(body.public_booking_enabled);
      if (on == null) return fail('invalid_value', 'Verkkovaraus on joko päällä tai pois.');
      return { ok: true, value: { public_booking_enabled: on } };
    }
    case 'business': {
      const bad = only(body, ['business_name', 'seller']);
      if (bad) return bad;
      const businessName = text(body.business_name, 2, 80, '');
      if (!businessName) return fail('invalid_value', 'Kaupan nimi on 2–80 merkkiä.');
      const seller = sellerValue(body.seller);
      if (!seller.ok) return seller;
      return { ok: true, value: { business_name: businessName, seller: seller.value } };
    }
    case 'booking_window': {
      const bad = only(body, ['booking_horizon_days', 'public_treatment_horizon_days']);
      if (bad) return bad;
      const horizon = integer(body.booking_horizon_days, 1, 730);
      const treat = integer(body.public_treatment_horizon_days, 1, 180);
      if (horizon == null || treat == null) return fail('invalid_value', 'Varausikkuna: savusauna 1–730 päivää, hoidot 1–180 päivää.');
      return { ok: true, value: { booking_horizon_days: horizon, public_treatment_horizon_days: treat } };
    }
    case 'booking_deadlines': {
      const bad = only(body, ['public_treatment_min_lead_minutes', 'customer_change_hours_before']);
      if (bad) return bad;
      const lead = integer(body.public_treatment_min_lead_minutes, 0, 1440);
      const change = integer(body.customer_change_hours_before, 0, 720);
      if (lead == null || change == null) return fail('invalid_value', 'Hoidon varoaika on 0–1440 minuuttia ja muutosaika 0–720 tuntia.');
      return { ok: true, value: { public_treatment_min_lead_minutes: lead, customer_change_hours_before: change } };
    }
    case 'booking_group': {
      const bad = only(body, ['checkout_group_threshold_persons', 'checkout_group_hold_days', 'annual_card_max_persons']);
      if (bad) return bad;
      const threshold = integer(body.checkout_group_threshold_persons, 0, 100);
      const days = integer(body.checkout_group_hold_days, 1, 60);
      const annual = integer(body.annual_card_max_persons, 1, 20);
      if (threshold == null || days == null || annual == null) return fail('invalid_value', 'Ryhmän kynnys on 0–100, pito 1–60 päivää ja vuosikortti 1–20 henkilöä.');
      return { ok: true, value: { checkout_group_threshold_persons: threshold, checkout_group_hold_days: days, annual_card_max_persons: annual } };
    }
    case 'payment_hold': {
      const bad = only(body, ['checkout_hold_minutes', 'checkout_mobilepay_grace_minutes', 'checkout_mobilepay_max_wait_minutes']);
      if (bad) return bad;
      const hold = integer(body.checkout_hold_minutes, 5, 60);
      const grace = integer(body.checkout_mobilepay_grace_minutes, 0, 60);
      const wait = integer(body.checkout_mobilepay_max_wait_minutes, 0, 120);
      if (hold == null || grace == null || wait == null) return fail('invalid_value', 'Pito on 5–60 min, MobilePayn lisäaika 0–60 min ja katto 0–120 min.');
      return { ok: true, value: { checkout_hold_minutes: hold, checkout_mobilepay_grace_minutes: grace, checkout_mobilepay_max_wait_minutes: wait } };
    }
    case 'company_invoice': {
      const bad = only(body, ['checkout_company_invoice_enabled']);
      if (bad) return bad;
      const on = bool(body.checkout_company_invoice_enabled);
      if (on == null) return fail('invalid_value', 'Yrityslasku on joko päällä tai pois.');
      return { ok: true, value: { checkout_company_invoice_enabled: on } };
    }
    case 'payment_methods': {
      const bad = only(body, ['methods']);
      if (bad) return bad;
      const methods = body.methods;
      const inner = only(methods, [...MANUAL_METHODS, 'cash']);
      if (inner) return inner;
      if (methods.cash === true) return fail('cash_not_accepted', 'Käteistä ei oteta vastaan.');
      const next = {};
      for (const code of MANUAL_METHODS) {
        if (!(code in methods)) continue;
        const on = bool(methods[code]);
        if (on == null) return fail('invalid_value', 'Maksutapa on joko käytössä tai pois.');
        next[code] = on;
      }
      if (!Object.keys(next).length) return fail('invalid_value', 'Valitse maksutavat, jotka tallennetaan.');
      return { ok: true, value: { methods: next } };
    }
    case 'email_sender': {
      const bad = only(body, ['from_name', 'reply_to']);
      if (bad) return bad;
      const fromName = text(body.from_name, 2, 80, '');
      if (!fromName || /[<>]/.test(fromName)) return fail('invalid_value', 'Lähettäjän nimi on 2–80 merkkiä.');
      const reply = emailOk(body.reply_to);
      if (!reply) return fail('invalid_value', 'Vastausosoite ei kelpaa.');
      return { ok: true, value: { from_name: fromName, reply_to: reply } };
    }
    case 'email_staff': {
      const bad = only(body, ['business_quote_notify_email', 'business_quote_notify_name']);
      if (bad) return bad;
      const email = emailOk(body.business_quote_notify_email, { allowEmpty: true });
      const name = text(body.business_quote_notify_name, 1, 80, '');
      if (email == null || !name) return fail('invalid_value', 'Tarjouspyynnön osoite on tyhjä tai kelvollinen, ja nimi on 1–80 merkkiä.');
      return { ok: true, value: { business_quote_notify_email: email, business_quote_notify_name: name } };
    }
    case 'gift_own': {
      const bad = only(body, ['sale_enabled', 'redeem_enabled', 'max_cards_per_order']);
      if (bad) return bad;
      const sale = bool(body.sale_enabled);
      const redeem = bool(body.redeem_enabled);
      const max = integer(body.max_cards_per_order, 1, 30);
      if (sale == null || redeem == null || max == null) return fail('invalid_value', 'Kortteja yhdessä ostossa on 1–30.');
      return { ok: true, value: { sale_enabled: sale, redeem_enabled: redeem, max_cards_per_order: max } };
    }
    case 'gift_partner': {
      const bad = only(body, ['max_per_order', 'remind_after_hours']);
      if (bad) return bad;
      const max = integer(body.max_per_order, 1, 30);
      const hours = integer(body.remind_after_hours, 1, 720);
      if (max == null || hours == null) return fail('invalid_value', 'Pyyntöjä on 1–30 ja muistutus 1–720 tuntia.');
      return { ok: true, value: { max_per_order: max, remind_after_hours: hours } };
    }
    case 'invoice': {
      const bad = only(body, ['invoice_due_days', 'iban', 'bic', 'name']);
      if (bad) return bad;
      const due = integer(body.invoice_due_days, 1, 90);
      const iban = ibanOk(body.iban);
      const bic = bicOk(body.bic);
      const name = text(typeof body.name === 'string' ? body.name : '', 0, 80, '');
      if (due == null || iban == null || bic == null || name == null) return fail('invalid_value', 'Eräpäivä on 1–90 päivää. IBAN on suomalainen tai tyhjä, BIC on 8 tai 11 merkkiä tai tyhjä.');
      return { ok: true, value: { invoice_due_days: due, iban, bic, name } };
    }
    case 'technical': {
      const bad = only(body, ['limits']);
      if (bad) return bad;
      const limits = body.limits;
      const known = Object.keys(TECHNICAL_LIMITS);
      const inner = only(limits, known);
      if (inner) return inner;
      const next = {};
      for (const key of Object.keys(limits)) {
        const [min, max] = TECHNICAL_LIMITS[key];
        const n = integer(limits[key], min, max);
        if (n == null) return fail('invalid_value', 'Tekninen raja on sallitun vaihteluvälin ulkopuolella.');
        next[key] = n;
      }
      if (!Object.keys(next).length) return fail('invalid_value', 'Ei tallennettavia rajoja.');
      return { ok: true, value: { limits: next } };
    }
    default:
      return fail('unknown_section', 'Tätä osiota ei voi tallentaa.');
  }
}

export function applySection(state, section, raw) {
  const check = validateSection(section, raw);
  if (!check.ok) {
    const error = new Error(check.message);
    error.code = check.code;
    throw error;
  }
  const v = check.value;
  const s = state.settings;
  switch (section) {
    case 'pause':
      s.public_booking_enabled = v.public_booking_enabled;
      break;
    case 'business':
      s.business_name = v.business_name;
      s.seller = { ...(s.seller && typeof s.seller === 'object' ? s.seller : {}), ...v.seller };
      break;
    case 'booking_window':
      s.booking_horizon_days = v.booking_horizon_days;
      s.public_treatment_horizon_days = v.public_treatment_horizon_days;
      break;
    case 'booking_deadlines':
      s.public_treatment_min_lead_minutes = v.public_treatment_min_lead_minutes;
      s.customer_change_hours_before = v.customer_change_hours_before;
      break;
    case 'booking_group':
      s.checkout_group_threshold_persons = v.checkout_group_threshold_persons;
      s.checkout_group_hold_days = v.checkout_group_hold_days;
      s.annual_card_max_persons = v.annual_card_max_persons;
      break;
    case 'payment_hold':
      s.checkout_hold_minutes = v.checkout_hold_minutes;
      s.hold_minutes = v.checkout_hold_minutes;
      s.checkout_mobilepay_grace_minutes = v.checkout_mobilepay_grace_minutes;
      s.checkout_mobilepay_max_wait_minutes = v.checkout_mobilepay_max_wait_minutes;
      break;
    case 'company_invoice':
      s.checkout_company_invoice_enabled = v.checkout_company_invoice_enabled;
      break;
    case 'payment_methods':
      for (const [code, active] of Object.entries(v.methods)) {
        const row = state.payment_methods.find((m) => m.code === code);
        if (row) row.active = active;
      }
      break;
    case 'email_sender': {
      const parsed = splitFrom(state.resend.from);
      if (!parsed) {
        const error = new Error('Lähettävä osoite on lukittu.');
        error.code = 'invalid_value';
        throw error;
      }
      state.resend.from = joinFrom(v.from_name, parsed.email);
      state.resend.reply_to = v.reply_to;
      break;
    }
    case 'email_staff':
      s.business_quote_notify_email = v.business_quote_notify_email;
      s.business_quote_notify_name = v.business_quote_notify_name;
      break;
    case 'gift_own':
      s['gift_cards.sale_enabled'] = v.sale_enabled;
      s['gift_cards.redeem_enabled'] = v.redeem_enabled;
      s['gift_cards.max_cards_per_order'] = v.max_cards_per_order;
      break;
    case 'gift_partner':
      s['voucher_claims.max_per_order'] = v.max_per_order;
      s['voucher_claims.remind_after_hours'] = v.remind_after_hours;
      break;
    case 'invoice':
      s.invoice_due_days = v.invoice_due_days;
      s.invoice_bank = { ...(s.invoice_bank && typeof s.invoice_bank === 'object' ? s.invoice_bank : {}), iban: v.iban, bic: v.bic, name: v.name };
      break;
    case 'technical':
      for (const [key, n] of Object.entries(v.limits)) s[key] = n;
      break;
    default:
      break;
  }
  return { ok: true };
}

export function exampleBundle() {
  return {
    settings: {
      public_booking_enabled: true,
      business_name: 'Sipoonjoen Perinnesauna',
      seller: {
        name: 'Havuhattu Oy / Sipoonjoen Perinnesauna',
        legal_name: 'Havuhattu Oy',
        trade_name: 'Sipoonjoen Perinnesauna',
        business_id: '3018112-1',
        vat_id: 'FI30181121',
        street: 'Hindsbyntie 124',
        postal_code: '04130',
        city: 'Sipoo',
        country: 'FI',
        phone: PHONE_DISPLAY_FI,
        email: 'savusauna@saunotus.fi',
        website: 'https://saunotus.fi',
        logo_url: '',
        footer: 'Kiitos käynnistä!',
      },
      booking_horizon_days: 120,
      public_treatment_horizon_days: 14,
      public_treatment_min_lead_minutes: 120,
      customer_change_hours_before: 48,
      annual_card_max_persons: 1,
      checkout_group_threshold_persons: 0,
      checkout_group_hold_days: 7,
      public_payment_mode: 'pay_later',
      pay_later_test_enabled: false,
      hold_minutes: 15,
      checkout_hold_minutes: 15,
      checkout_mobilepay_grace_minutes: 15,
      checkout_mobilepay_max_wait_minutes: 30,
      checkout_company_invoice_enabled: true,
      'gift_cards.sale_enabled': false,
      'gift_cards.redeem_enabled': false,
      'gift_cards.max_cards_per_order': 10,
      'gift_cards.johku_cards_redeemable': false,
      'voucher_claims.enabled': false,
      'voucher_claims.problem_emails_enabled': false,
      'voucher_claims.partner_voucher_accounted': false,
      'voucher_claims.max_per_order': 10,
      'voucher_claims.remind_after_hours': 24,
      'voucher_claims.max_attempts': 6,
      invoice_due_days: 14,
      invoice_bank: { iban: '', bic: '', name: '' },
      invoice_dispatch_mode: 'dry_run',
      receipt_series: { receipt: 'K', refund_receipt: 'H', giftcard_info: 'G' },
      business_quote_notify_email: 'savusauna@saunotus.fi',
      business_quote_notify_name: 'Joonas',
      'messages.timed_enabled': false,
      timezone: 'Europe/Helsinki',
      marketing_consent_text_version: 'v1',
      site_base_url: 'https://saunotus.fi',
      functions_base_url: 'https://example.supabase.co/functions/v1',
      order_page_path: '/tilaus/',
      payment_link_path: '/maksa/',
      articles_path_fi: '/saunatietoa/',
      articles_path_en: '/en/sauna-knowledge/',
      articles_label_fi: 'Saunatietoa',
      articles_label_en: 'Sauna knowledge',
      rl_ip_per_10min: 12,
      rl_email_per_10min: 5,
      rl_change_per_10min: 10,
      rl_avail_per_10min: 60,
      rl_order_get_per_10min: 60,
      rl_order_add_per_10min: 20,
      rl_order_req_per_10min: 6,
      public_treatment_global_per_hour: 30,
      public_treatment_max_open_per_email: 5,
      'gift_cards.rl_check_fail_per_10min': 10,
      'gift_cards.rl_global_fail_per_10min': 200,
      'gift_cards.rl_buy_per_10min': 6,
      business_quote_rl_ip_per_10min: 5,
      business_quote_rl_email_per_hour: 3,
      texts_max_proposals_per_day: 200,
      texts_bot_max_approvals_per_day: 100,
    },
    payment_methods: [
      { code: 'pay_later', label: 'Maksetaan paikan päällä', is_manual: true, active: true },
      { code: 'cash', label: 'Käteinen', is_manual: false, active: false },
      { code: 'card_terminal', label: 'Korttipääte', is_manual: true, active: true },
      { code: 'mobilepay', label: 'MobilePay', is_manual: true, active: true },
      { code: 'bank_transfer', label: 'Tilisiirto', is_manual: true, active: true },
      { code: 'invoice', label: 'Lasku', is_manual: true, active: true },
      { code: 'gift_card', label: 'Lahjakortti', is_manual: false, active: true },
      { code: 'partner_voucher', label: 'Kumppanin lahjakortti', is_manual: true, active: true },
      { code: 'partner_voucher_kokemuskauppa', label: 'Lahjakortti – Kokemuskauppa', is_manual: true, active: true },
      { code: 'partner_voucher_offerilla', label: 'Lahjakortti – Offerilla', is_manual: true, active: true },
      { code: 'partner_voucher_elamyslahjat', label: 'Lahjakortti – Elämyslahjat', is_manual: true, active: true },
      { code: 'visma_pay', label: 'Visma Pay', is_manual: false, active: false },
      { code: 'montonio', label: 'Maksa verkossa', is_manual: false, active: true },
      { code: 'annual_card', label: 'Vuosikortti', is_manual: false, active: false },
      { code: 'other', label: 'Muu', is_manual: true, active: true },
    ],
    resend: { mode: 'dry_run', from: 'Sipoonjoen Perinnesauna <savusauna@saunotus.fi>', reply_to: 'savusauna@saunotus.fi', allowlist_on: true, allowlist_count: 2 },
    vismapay: { mode: 'test' },
    mobilepay: { mode: 'test' },
    procountor: { mode: 'off', environment: 'pts', daily_enabled: false, accounts_configured: false, bank_account_configured: false },
    booking_calendar: { mode: 'off', configured: false },
    gift_packages: [{ code: 'open', name: 'Avoin lahjakortti', valid_months: 6 }],
  };
}
