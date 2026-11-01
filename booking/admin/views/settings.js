// Asetukset: etusivu ja kortit. Tallennus on korttikohtainen (admin_save_settings).
// Maksun live-tila, Procountor ja sähköpostin vastaanottajarajaus ovat vain tilaa.
// QR-tulostus: pos.use tai settings.edit. Tekninen välilehti vain roolille admin.
import { rpc } from '../sb.js';
import { h, field, toast, run, badge, todayHel } from '../ui.js';
import { loadProcountorTexts, procountorText } from '../procountor-texts.js';
import { loadCalendarExportTexts } from '../calendar-export-texts.js';
import { loadSettingsTexts, settingsText as st } from '../settings-texts.js';
import { visibleSettingTabs, settingsHref, tabFromHash } from '../settings-tabs.js';
import { renderQrPanel } from '../qr-panel.js';
import { loadVcrTexts, vcrText } from '../voucher-redeem-texts.js';
import { VCR_SELLERS, VCR_RPC, VCR_URL_MAX, sellerLabel, checkRedeemUrls } from '../voucher-redeem-logic.js';
import { renderCalendarExport } from './calendar-export.js';
import { TECHNICAL_LIMITS, modeBadgeKind, modeTextKey, overviewNotices, splitFrom, validateSection } from '../settings-logic.js';
import { feeRulesCard } from './fee-rules-panel.js';

const tx = (key) => st(`ui.admin.settings.${key}`);
const MANUAL = ['pay_later', 'card_terminal', 'bank_transfer', 'invoice', 'partner_voucher', 'other'];
const LIMIT_FIELDS = [
  ['rl_ip_per_10min', 'lim_ip'],
  ['rl_email_per_10min', 'lim_email'],
  ['rl_change_per_10min', 'lim_change'],
  ['rl_avail_per_10min', 'lim_avail'],
  ['rl_order_get_per_10min', 'lim_get'],
  ['rl_order_add_per_10min', 'lim_add'],
  ['rl_order_req_per_10min', 'lim_req'],
  ['public_treatment_global_per_hour', 'lim_hour'],
  ['public_treatment_max_open_per_email', 'lim_open'],
  ['gift_cards.rl_check_fail_per_10min', 'lim_gc_check'],
  ['gift_cards.rl_global_fail_per_10min', 'lim_gc_global'],
  ['gift_cards.rl_buy_per_10min', 'lim_gc_buy'],
  ['business_quote_rl_ip_per_10min', 'lim_quote_ip'],
  ['business_quote_rl_email_per_hour', 'lim_quote_email'],
  ['texts_max_proposals_per_day', 'lim_texts'],
  ['texts_bot_max_approvals_per_day', 'lim_approvals'],
  ['voucher_claims.max_attempts', 'lim_attempts'],
];

function modeBadge(mode) {
  return badge(modeBadgeKind(mode), tx(modeTextKey(mode)));
}
function onOff(on) {
  return badge(on ? 'ok' : '', on ? tx('on') : tx('off'));
}
function stat(label, value) {
  return h('div', { class: 'stat' }, h('span', { text: label }), value);
}
function saveBar(section, collect, reload, testid) {
  return h('div', { class: 'set-save' }, h('button', {
    class: 'btn primary', type: 'button', text: tx('save'), 'data-testid': testid,
    onclick: (e) => run(e.target, async () => {
      const check = validateSection(section, collect());
      if (!check.ok) throw Object.assign(new Error(check.message), { code: check.code });
      await rpc('admin_save_settings', { p_section: section, p: check.value });
      toast(tx('saved'));
      if (reload) await reload();
    }),
  }));
}
function toggle(label, help, checked, { testid, confirmOff, confirmOn, disabled } = {}) {
  const input = h('input', { type: 'checkbox', disabled: disabled || null, 'data-testid': testid || null });
  input.checked = !!checked;
  if (confirmOff) input.addEventListener('change', () => { if (!input.checked && !window.confirm(confirmOff)) input.checked = true; });
  if (confirmOn) input.addEventListener('change', () => { if (input.checked && !window.confirm(confirmOn)) input.checked = false; });
  const row = h('div', { class: 'switch-row' },
    h('div', {}, h('b', { text: label }), help ? h('p', { class: 'muted', text: help }) : null),
    h('label', { class: 'switch' }, input, h('i'), h('span', { class: 'sr', text: label })));
  return { input, row };
}
function num(label, value, unit, min, max, testid) {
  const input = h('input', { type: 'number', inputmode: 'numeric', min: String(min), max: String(max), step: '1', value: value == null ? '' : String(value), 'data-testid': testid || null });
  return { input, node: h('label', { class: 'fld' }, h('span', { text: label }), h('div', { class: 'unit' }, input, h('span', { text: unit }))) };
}
function textField(label, value, help, { type = 'text', testid } = {}) {
  const input = h('input', { type, value: value ?? '', autocomplete: 'off', 'data-testid': testid || null });
  return { input, node: field(label, input, help) };
}
function card(title, help, ...kids) {
  return h('section', { class: 'card' }, h('h2', { text: title }), help ? h('p', { class: 'muted', text: help }) : null, ...kids);
}
function read(label, value) {
  return stat(label, h('b', { text: value || '–' }));
}

function procountorCard(state, failed) {
  if (failed || !state) {
    return h('section', { class: 'card', 'data-testid': 'procountor-status' },
      h('h2', { text: procountorText('ui.admin.procountor.title') }),
      h('p', { class: 'err', 'data-testid': 'procountor-error', text: procountorText('ui.admin.procountor.unavailable') }));
  }
  const modeKey = state.mode === 'live' ? 'mode_live' : state.mode === 'dry_run' ? 'mode_dry_run' : 'mode_off';
  const envKey = state.environment === 'prod' ? 'env_prod' : 'env_pts';
  const statusKey = 'status_' + (state.last?.status || '');
  const statusLabel = state.last ? procountorText('ui.admin.procountor.' + statusKey) : '';
  const last = state.last
    ? `${procountorText('ui.admin.procountor.last')}: ${state.last.business_date || state.last.kind || ''} · ${statusLabel} · ${procountorText('ui.admin.procountor.attempts')} ${state.last.attempts ?? 0}`
    : procountorText('ui.admin.procountor.last_none');
  const errors = Array.isArray(state.errors) && state.errors.length
    ? state.errors.map((e) => h('li', { text: [e.business_date, e.kind, e.status, e.last_error].filter(Boolean).join(' · ') }))
    : [h('li', { text: procountorText('ui.admin.procountor.errors_none') })];
  return h('section', { class: 'card', 'data-testid': 'procountor-status' },
    h('h2', { text: procountorText('ui.admin.procountor.title') }),
    h('p', { class: 'muted', text: tx('readonly_note') }),
    h('p', { 'data-testid': 'procountor-mode', text: `${procountorText('ui.admin.procountor.mode')}: ${procountorText('ui.admin.procountor.' + modeKey)} · ${procountorText('ui.admin.procountor.env')}: ${procountorText('ui.admin.procountor.' + envKey)}` }),
    h('p', { text: `${procountorText('ui.admin.procountor.daily')}: ${state.daily_enabled ? procountorText('ui.admin.procountor.daily_on') : procountorText('ui.admin.procountor.daily_off')}` }),
    h('p', { text: state.accounts_configured ? procountorText('ui.admin.procountor.accounts_ok') : procountorText('ui.admin.procountor.accounts_missing') }),
    h('p', { text: state.bank_account_configured ? procountorText('ui.admin.procountor.bank_ok') : procountorText('ui.admin.procountor.bank_missing') }),
    h('p', { 'data-testid': 'procountor-last', text: last }),
    h('p', { text: procountorText('ui.admin.procountor.errors') }),
    h('ul', { 'data-testid': 'procountor-error' }, errors));
}

const SALES = [['25.5', 'sales_25_5'], ['13.5', 'sales_13_5'], ['0', 'sales_0'], ['14', 'sales_14'], ['24', 'sales_24'], ['10', 'sales_10']];
const METHODS = [['cash', 'method_cash'], ['card_terminal', 'method_card_terminal'], ['mobilepay', 'method_mobilepay'], ['bank_transfer', 'method_bank_transfer'], ['invoice', 'method_invoice'], ['gift_card', 'method_gift_card'], ['partner_voucher_kokemuskauppa', 'method_partner_voucher_kokemuskauppa'], ['partner_voucher_offerilla', 'method_partner_voucher_offerilla'], ['partner_voucher_elamyslahjat', 'method_partner_voucher_elamyslahjat'], ['partner_voucher', 'method_partner_voucher_fallback'], ['visma_pay', 'method_visma_pay'], ['montonio', 'method_montonio'], ['annual_card', 'method_annual_card'], ['pay_later', 'method_pay_later'], ['other', 'method_other']];

function procountorForm(cfg, isAdmin, reload) {
  if (!cfg) {
    return h('section', { class: 'card', 'data-testid': 'procountor-settings' },
      h('h2', { text: procountorText('ui.admin.procountor.edit_title') }),
      h('p', { class: 'muted', text: procountorText('ui.admin.procountor.unavailable') }));
  }
  const s = cfg.accounts || {};
  const sales = s.sales_by_vat || {};
  const methods = s.clearing_by_method || {};
  const approved = h('input', { type: 'text', value: cfg.approved_by || '', disabled: !isAdmin, 'data-testid': 'procountor-approved' });
  const vat = h('input', { type: 'text', value: cfg.vat_status || '', disabled: !isAdmin, 'data-testid': 'procountor-vat-status' });
  const prefix = h('input', { type: 'text', value: cfg.api_prefix || '/supported/api', disabled: !isAdmin, 'data-testid': 'procountor-prefix' });
  const bank = h('input', { type: 'text', value: cfg.bank_account || '', disabled: !isAdmin, 'data-testid': 'procountor-bank', autocomplete: 'off' });
  const rounding = h('input', { type: 'text', value: s.rounding || '', disabled: !isAdmin, 'data-testid': 'procountor-rounding' });
  const salesInputs = Object.fromEntries(SALES.map(([rate]) => [rate, h('input', { type: 'text', value: sales[rate] || '', disabled: !isAdmin, 'data-testid': `procountor-sales-${rate}` })]));
  const methodInputs = Object.fromEntries(METHODS.map(([code]) => [code, h('input', { type: 'text', value: methods[code] || '', disabled: !isAdmin, 'data-testid': `procountor-method-${code}` })]));
  const previewDate = h('input', { type: 'date', value: todayHel(), 'data-testid': 'procountor-preview-date' });
  const previewOut = h('p', { 'data-testid': 'procountor-preview-result' });
  const collect = () => ({
    mode: cfg.mode || 'off',
    environment: cfg.environment || 'pts',
    daily_enabled: cfg.daily_enabled === true,
    approved_by: approved.value.trim(),
    vat_status: vat.value.trim(),
    api_prefix: prefix.value.trim(),
    bank_account: bank.value.trim(),
    accounts: {
      rounding: rounding.value.trim(),
      sales_by_vat: Object.fromEntries(SALES.map(([rate]) => [rate, salesInputs[rate].value.trim()])),
      clearing_by_method: Object.fromEntries(METHODS.map(([code]) => [code, methodInputs[code].value.trim()])),
    },
  });
  const save = h('button', { class: 'btn primary', type: 'button', text: procountorText('ui.admin.procountor.save'), 'data-testid': 'procountor-save', disabled: !isAdmin || null, onclick: (e) => run(e.target, async () => {
    await rpc('admin_set_procountor_settings', { p: collect() });
    toast(procountorText('ui.admin.procountor.saved'));
    if (reload) await reload();
  }) });
  const preview = h('button', { class: 'btn', type: 'button', text: procountorText('ui.admin.procountor.preview'), 'data-testid': 'procountor-preview', onclick: (e) => run(e.target, async () => {
    const res = await rpc('admin_procountor_preview_daily', { p_date: previewDate.value });
    const missing = Array.isArray(res.missing) ? res.missing.join(', ') : '';
    previewOut.textContent = `${procountorText('ui.admin.procountor.preview_receipts')} ${res.receipts ?? 0}. ${procountorText('ui.admin.procountor.preview_not_sent')}${missing ? ` ${procountorText('ui.admin.procountor.missing')}: ${missing}` : ''}`;
  }) });
  return h('section', { class: 'card', 'data-testid': 'procountor-settings' },
    h('h2', { text: procountorText('ui.admin.procountor.edit_title') }),
    h('p', { class: 'muted', text: procountorText('ui.admin.procountor.edit_lead') }),
    h('div', { class: 'stack' },
      field(procountorText('ui.admin.procountor.approved_by'), approved, procountorText('ui.admin.procountor.approved_by_hint')),
      field(procountorText('ui.admin.procountor.vat_status'), vat),
      field(procountorText('ui.admin.procountor.api_prefix'), prefix),
      field(procountorText('ui.admin.procountor.bank_account'), bank, procountorText('ui.admin.procountor.bank_keep')),
      field(procountorText('ui.admin.procountor.rounding'), rounding)),
    h('h3', { text: procountorText('ui.admin.procountor.sales_title') }),
    h('div', { class: 'stack' }, SALES.map(([rate, key]) => field(procountorText(`ui.admin.procountor.${key}`), salesInputs[rate]))),
    h('h3', { text: procountorText('ui.admin.procountor.methods_title') }),
    h('p', { class: 'muted', 'data-testid': 'procountor-partner-hint', text: procountorText('ui.admin.procountor.methods_partner_hint') }),
    h('div', { class: 'stack' }, METHODS.map(([code, key]) => field(procountorText(`ui.admin.procountor.${key}`), methodInputs[code]))),
    isAdmin ? save : null,
    h('div', { class: 'row wrap' }, field(procountorText('ui.admin.procountor.preview_date'), previewDate), preview),
    previewOut);
}

function homePanel(bundle, ctx) {
  const s = bundle.settings || {};
  const seller = s.seller && typeof s.seller === 'object' ? s.seller : {};
  const pause = toggle(tx('pause_label'), tx('pause_help'), s.public_booking_enabled === true, { testid: 'pause-enabled', confirmOff: tx('pause_confirm') });
  const notes = overviewNotices(bundle);
  const summary = [seller.legal_name, seller.business_id ? `Y-tunnus ${seller.business_id}` : '', [seller.street, [seller.postal_code, seller.city].filter(Boolean).join(' ')].filter(Boolean).join(', '), [seller.phone, seller.email].filter(Boolean).join(' · ')].filter(Boolean);
  return h('div', { class: 'stack', 'data-testid': 'panel-etusivu' },
    notes.length ? h('div', { class: 'warnbox', role: 'status', 'data-testid': 'settings-warn' }, notes.map((key) => h('p', { text: tx(key) }))) : null,
    card(tx('pause_title'), null, pause.row, saveBar('pause', () => ({ public_booking_enabled: pause.input.checked }), ctx.reload, 'save-pause')),
    card(tx('company_title'), null,
      h('p', { class: 'summary', text: summary.join('\n') }),
      h('p', {}, h('a', { href: settingsHref('yritys'), text: tx('company_edit') }))),
    card(tx('links_title'), tx('links_help'),
      stat('Montonio', modeBadge(bundle.montonio?.mode)),
      stat(tx('mail_mode'), modeBadge(bundle.resend?.mode)),
      stat('Procountor', modeBadge(bundle.procountor?.mode)),
      stat(tx('conn_calendar'), modeBadge(bundle.booking_calendar?.mode)),
      stat('Saunabot', badge('', tx('mode_off'))),
      h('p', {}, h('a', { href: settingsHref('yhteydet'), text: tx('links_open') }))),
    card(tx('role_title'), tx('role_help'),
      h('p', { class: 'summary', text: ctx.roleLabel || ctx.role || '' }),
      ctx.can('staff.manage') ? h('p', {}, h('a', { href: '#/kayttajat', text: tx('role_open') })) : null),
    card(tx('qr_open'), tx('qr_help'),
      h('p', {}, h('a', { class: 'linkrow', href: settingsHref('qr'), text: tx('qr_open') }))));
}

function businessPanel(bundle, reload) {
  const s = bundle.settings || {};
  const seller = s.seller && typeof s.seller === 'object' ? s.seller : {};
  const shop = textField(tx('biz_shop'), s.business_name, tx('biz_shop_help'), { testid: 'biz-shop' });
  const name = textField(tx('biz_receipt'), seller.name);
  const legal = textField(tx('biz_legal'), seller.legal_name);
  const trade = textField(tx('biz_trade'), seller.trade_name);
  const id = textField(tx('biz_id'), seller.business_id, null, { testid: 'biz-id' });
  const vat = textField(tx('biz_vat'), seller.vat_id, tx('biz_vat_help'));
  const street = textField(tx('biz_street'), seller.street);
  const post = textField(tx('biz_post'), seller.postal_code);
  const city = textField(tx('biz_city'), seller.city);
  const country = textField(tx('biz_country'), seller.country);
  const phone = textField(tx('biz_phone'), seller.phone, null, { type: 'tel' });
  const email = textField(tx('biz_email'), seller.email, null, { type: 'email' });
  const web = textField(tx('biz_web'), seller.website, null, { type: 'url' });
  const footer = textField(tx('biz_footer'), seller.footer);
  const logo = String(seller.logo_url || '').trim();
  return h('div', { class: 'stack', 'data-testid': 'panel-yritys' },
    card(tx('company_title'), tx('biz_lead'),
      shop.node, name.node, legal.node, trade.node, id.node, vat.node, street.node, post.node, city.node, country.node, phone.node, email.node, web.node, footer.node,
      h('p', { class: 'muted', text: logo ? tx('biz_logo_yes') : tx('biz_logo_no') }),
      saveBar('business', () => ({
        business_name: shop.input.value,
        seller: {
          name: name.input.value, legal_name: legal.input.value, trade_name: trade.input.value,
          business_id: id.input.value, vat_id: vat.input.value, street: street.input.value,
          postal_code: post.input.value, city: city.input.value, country: country.input.value,
          phone: phone.input.value, email: email.input.value, website: web.input.value, footer: footer.input.value,
        },
      }), reload, 'save-business')));
}

function bookingPanel(bundle, reload, calendarExport, calendarExportFailed, isAdmin) {
  const s = bundle.settings || {};
  const horizon = num(tx('win_sauna'), s.booking_horizon_days, tx('unit_days'), 1, 730, 'horizon-days');
  const treat = num(tx('win_treat'), s.public_treatment_horizon_days, tx('unit_days'), 1, 180);
  const lead = num(tx('dead_lead'), s.public_treatment_min_lead_minutes, tx('unit_minutes'), 0, 1440);
  const change = num(tx('dead_change'), s.customer_change_hours_before, tx('unit_hours'), 0, 720);
  const group = num(tx('group_n'), s.checkout_group_threshold_persons, tx('unit_persons'), 0, 100, 'group-threshold');
  const days = num(tx('group_days'), s.checkout_group_hold_days, tx('unit_days'), 1, 60);
  const annual = num(tx('annual'), s.annual_card_max_persons, tx('unit_persons'), 1, 20);
  const daysWrap = h('div', {}, days.node);
  const sync = () => { daysWrap.hidden = Number(group.input.value) === 0; };
  group.input.addEventListener('input', sync);
  sync();
  return h('div', { class: 'stack', 'data-testid': 'panel-varaukset' },
    card(tx('win_title'), tx('win_help'), horizon.node, treat.node, saveBar('booking_window', () => ({
      booking_horizon_days: Number(horizon.input.value), public_treatment_horizon_days: Number(treat.input.value),
    }), reload, 'save-window')),
    card(tx('dead_title'), tx('dead_help'), lead.node, change.node, saveBar('booking_deadlines', () => ({
      public_treatment_min_lead_minutes: Number(lead.input.value), customer_change_hours_before: Number(change.input.value),
    }), reload, 'save-deadlines')),
    card(tx('group_title'), tx('group_help'), group.node, daysWrap, annual.node,
      h('p', { class: 'muted', text: tx('annual_help') }),
      saveBar('booking_group', () => ({
        checkout_group_threshold_persons: Number(group.input.value),
        checkout_group_hold_days: Number(days.input.value),
        annual_card_max_persons: Number(annual.input.value),
      }), reload, 'save-group')),
    isAdmin ? renderCalendarExport({ state: calendarExport, failed: calendarExportFailed, isAdmin, reload }) : null);
}

function paymentsPanel(bundle, reload) {
  const s = bundle.settings || {};
  const hold = num(tx('hold_min'), s.checkout_hold_minutes, tx('unit_minutes'), 5, 60);
  const grace = num(tx('hold_extra'), s.checkout_mobilepay_grace_minutes, tx('unit_minutes'), 0, 60);
  const wait = num(tx('hold_cap'), s.checkout_mobilepay_max_wait_minutes, tx('unit_minutes'), 0, 120);
  const company = toggle(tx('inv_co_label'), tx('inv_co_help'), s.checkout_company_invoice_enabled === true, { testid: 'company-invoice' });
  const methods = new Map((bundle.payment_methods || []).map((m) => [m.code, m]));
  const toggles = MANUAL.filter((code) => methods.has(code)).map((code) => {
    const row = methods.get(code);
    const ui = toggle(row.label, null, row.active === true, { testid: `method-${code}` });
    return { code, ui };
  });
  const cash = toggle(methods.get('cash')?.label || 'Käteinen', tx('cash_locked'), false, { testid: 'cash-locked', disabled: true });
  return h('div', { class: 'stack', 'data-testid': 'panel-maksut' },
    card(tx('pay_status_title'), tx('pay_status_help'),
      stat(tx('pay_mode'), h('b', { text: s.public_payment_mode === 'hold_until_paid' ? tx('mode_hold') : tx('mode_pay_later') })),
      stat('Montonio', modeBadge(bundle.montonio?.mode)),
      stat(tx('pay_later_test'), onOff(s.pay_later_test_enabled === true))),
    card(tx('hold_title'), tx('hold_help'), hold.node, grace.node, wait.node, saveBar('payment_hold', () => ({
      checkout_hold_minutes: Number(hold.input.value),
      checkout_mobilepay_grace_minutes: Number(grace.input.value),
      checkout_mobilepay_max_wait_minutes: Number(wait.input.value),
    }), reload, 'save-hold')),
    card(tx('inv_co_title'), null, company.row, saveBar('company_invoice', () => ({ checkout_company_invoice_enabled: company.input.checked }), reload, 'save-company')),
    card(tx('methods_title'), tx('methods_lead'),
      ...toggles.map((t) => t.ui.row),
      cash.row,
      saveBar('payment_methods', () => ({ methods: Object.fromEntries(toggles.map((t) => [t.code, t.ui.input.checked])) }), reload, 'save-methods')),
    feeRulesCard());
}

function mailPanel(bundle, reload) {
  const s = bundle.settings || {};
  const from = splitFrom(bundle.resend?.from) || { name: '', email: '' };
  const name = textField(tx('mail_from'), from.name, null, { testid: 'from-name' });
  const reply = textField(tx('mail_reply'), bundle.resend?.reply_to, null, { type: 'email', testid: 'reply-to' });
  const quoteEmail = textField(tx('quote_email'), s.business_quote_notify_email, null, { type: 'email' });
  const quoteName = textField(tx('quote_name'), s.business_quote_notify_name);
  const timed = s['messages.timed_enabled'] === true;
  return h('div', { class: 'stack', 'data-testid': 'panel-sahkoposti' },
    card(tx('mail_status_title'), tx('mail_status_help'),
      stat(tx('mail_mode'), modeBadge(bundle.resend?.mode)),
      stat(tx('mail_allow'), badge(bundle.resend?.allowlist_on ? 'warn' : '', bundle.resend?.allowlist_on ? tx('allowlist_on') : tx('allowlist_off'))),
      read(tx('mail_allow_count'), bundle.resend?.allowlist_on ? String(bundle.resend.allowlist_count ?? 0) : '0')),
    card(tx('mail_from_title'), null,
      name.node,
      read(tx('mail_from_locked'), from.email),
      reply.node,
      saveBar('email_sender', () => ({ from_name: name.input.value, reply_to: reply.input.value }), reload, 'save-sender')),
    card(tx('sign_title'), tx('sign_help'), h('p', { class: 'summary', text: 'Tapio' })),
    card(tx('quote_title'), tx('quote_help'), quoteEmail.node, quoteName.node, saveBar('email_staff', () => ({
      business_quote_notify_email: quoteEmail.input.value, business_quote_notify_name: quoteName.input.value,
    }), reload, 'save-quote')),
    card(tx('timed_title'), timed ? tx('timed_on') : tx('timed_off'),
      h('p', {}, h('a', { href: '#/viestit', text: tx('timed_open') }))));
}

function giftPanel(bundle, reload) {
  const s = bundle.settings || {};
  const sale = toggle(tx('gift_sale'), null, s['gift_cards.sale_enabled'] === true, { testid: 'gift-sale', confirmOn: tx('gift_confirm_sale') });
  const redeem = toggle(tx('gift_redeem'), null, s['gift_cards.redeem_enabled'] === true, { testid: 'gift-redeem', confirmOn: tx('gift_confirm_redeem') });
  const max = num(tx('gift_max'), s['gift_cards.max_cards_per_order'], tx('unit_cards'), 1, 30);
  const per = num(tx('partner_max'), s['voucher_claims.max_per_order'], tx('unit_cards'), 1, 30);
  const remind = num(tx('partner_remind'), s['voucher_claims.remind_after_hours'], tx('unit_hours'), 1, 720);
  const packs = Array.isArray(bundle.gift_packages) ? bundle.gift_packages : [];
  return h('div', { class: 'stack', 'data-testid': 'panel-lahjakortit' },
    card(tx('gift_title'), tx('gift_help'), sale.row, redeem.row, max.node, saveBar('gift_own', () => ({
      sale_enabled: sale.input.checked, redeem_enabled: redeem.input.checked, max_cards_per_order: Number(max.input.value),
    }), reload, 'save-gift')),
    card(tx('gift_valid_title'), tx('gift_valid_help'),
      packs.length ? h('div', {}, packs.map((p) => stat(p.name, h('b', { text: `${p.valid_months} ${tx('unit_months')}` })))) : h('p', { class: 'muted', text: '–' })),
    card(tx('gift_flags_title'), tx('readonly_note'),
      stat(tx('gift_johku'), onOff(s['gift_cards.johku_cards_redeemable'] === true)),
      stat(tx('gift_partner'), onOff(s['voucher_claims.enabled'] === true)),
      stat(tx('gift_problem'), onOff(s['voucher_claims.problem_emails_enabled'] === true)),
      stat(tx('gift_accounted'), onOff(s['voucher_claims.partner_voucher_accounted'] === true))),
    card(tx('partner_title'), null, per.node, remind.node, saveBar('gift_partner', () => ({
      max_per_order: Number(per.input.value), remind_after_hours: Number(remind.input.value),
    }), reload, 'save-partner')),
    redeemUrlsCard());
}

// booking_173: kumppanien lunastussivut (asetus voucher_claims.redeem_urls; admin_set_voucher_redeem_urls, settings.edit). Arvot luetaan Tarkista-listan rajapinnasta.
function redeemUrlsCard() {
  const inputs = Object.fromEntries(VCR_SELLERS.map((k) => [k, h('input', { type: 'url', inputmode: 'url', autocomplete: 'off', maxlength: String(VCR_URL_MAX), placeholder: 'https://', 'data-testid': `redeem-url-${k}` })]));
  const err = h('p', { class: 'err', role: 'alert', hidden: true, 'data-testid': 'redeem-urls-err' });
  const save = h('button', { type: 'button', class: 'btn primary', 'data-testid': 'save-redeem-urls', text: vcrText('ui.admin.vcr.urls_save') });
  save.addEventListener('click', () => run(save, async () => {
    const chk = checkRedeemUrls(Object.fromEntries(VCR_SELLERS.map((k) => [k, inputs[k].value])));
    if (!chk.ok) { err.textContent = vcrText('ui.admin.vcr.urls_bad', { sources: chk.bad.map((k) => sellerLabel(k)).join(', ') }); err.hidden = false; return; }
    err.hidden = true;
    const res = await rpc(VCR_RPC.setUrls, { p: chk.value });
    for (const k of VCR_SELLERS) inputs[k].value = res?.redeem_urls?.[k] || '';
    toast(vcrText('ui.admin.vcr.urls_saved'));
  }));
  const node = card(vcrText('ui.admin.vcr.urls_title'), vcrText('ui.admin.vcr.urls_lead'),
    h('div', { class: 'stack', 'data-testid': 'redeem-urls' }, VCR_SELLERS.map((k) => field(sellerLabel(k), inputs[k]))), err, save);
  rpc(VCR_RPC.unredeemed, { p_limit: 1 }).then((v) => { for (const k of VCR_SELLERS) if (!inputs[k].value) inputs[k].value = v?.redeem_urls?.[k] || ''; }).catch(() => { /* vanha tietokanta: kentät tyhjinä */ });
  return node;
}

function invoicePanel(bundle, reload) {
  const s = bundle.settings || {};
  const bank = s.invoice_bank && typeof s.invoice_bank === 'object' ? s.invoice_bank : {};
  const series = s.receipt_series && typeof s.receipt_series === 'object' ? s.receipt_series : {};
  const due = num(tx('bill_due'), s.invoice_due_days, tx('unit_days'), 1, 90);
  const iban = textField(tx('bill_iban'), bank.iban, null, { testid: 'invoice-iban' });
  const bic = textField(tx('bill_bic'), bank.bic);
  const name = textField(tx('bill_bank'), bank.name);
  return h('div', { class: 'stack', 'data-testid': 'panel-laskut' },
    card(tx('bill_title'), tx('bill_help'), due.node, iban.node, bic.node, name.node, saveBar('invoice', () => ({
      invoice_due_days: Number(due.input.value), iban: iban.input.value, bic: bic.input.value, name: name.input.value,
    }), reload, 'save-invoice')),
    card(tx('bill_dispatch'), tx('readonly_note'), stat(tx('bill_dispatch'), modeBadge(s.invoice_dispatch_mode === 'live' ? 'live' : s.invoice_dispatch_mode === 'off' ? 'off' : 'dry_run'))),
    card(tx('series_title'), tx('series_help'),
      read(tx('series_receipt'), series.receipt),
      read(tx('series_refund'), series.refund_receipt),
      read(tx('series_gift'), series.giftcard_info)));
}

function connectionsPanel(bundle, procountor, procountorFailed, editor, isAdmin, reload) {
  const s = bundle.settings || {};
  return h('div', { class: 'stack', 'data-testid': 'panel-yhteydet' },
    h('p', { class: 'muted', text: tx('conn_lead') }),
    card('Montonio', tx('readonly_note'), stat('Montonio', modeBadge(bundle.montonio?.mode))),
    card(tx('mail_status_title'), tx('mail_status_help'),
      stat(tx('mail_mode'), modeBadge(bundle.resend?.mode)),
      stat(tx('mail_allow'), badge(bundle.resend?.allowlist_on ? 'warn' : '', bundle.resend?.allowlist_on ? tx('allowlist_on') : tx('allowlist_off')))),
    procountorCard(procountor, procountorFailed),
    isAdmin ? procountorForm(editor, isAdmin, reload) : null,
    card(tx('conn_calendar'), tx('readonly_note'),
      stat(tx('conn_calendar'), modeBadge(bundle.booking_calendar?.mode)),
      h('p', { text: bundle.booking_calendar?.configured ? tx('conn_calendar_id') : tx('conn_calendar_missing') })),
    card(tx('links_title'), null,
      h('p', { text: tx('conn_closure') }),
      h('p', { text: tx('conn_bot') }),
      h('p', { text: tx('conn_reviews') }),
      read(tx('conn_site'), s.site_base_url)));
}

function technicalPanel(bundle, reload) {
  const s = bundle.settings || {};
  const fields = LIMIT_FIELDS.filter(([key]) => TECHNICAL_LIMITS[key]).map(([key, label]) => {
    const [min, max] = TECHNICAL_LIMITS[key];
    return { key, ...num(tx(label), s[key], '', min, max) };
  });
  const articles = [s.articles_label_fi, s.articles_path_fi, s.articles_label_en, s.articles_path_en].filter(Boolean).join(' · ');
  return h('div', { class: 'stack', 'data-testid': 'panel-tekninen' },
    h('div', { class: 'warnbox', role: 'status' }, h('p', { text: tx('tech_help') })),
    card(tx('tech_title'), null,
      ...fields.map((f) => f.node),
      saveBar('technical', () => ({ limits: Object.fromEntries(fields.map((f) => [f.key, Number(f.input.value)])) }), reload, 'save-technical')),
    card(tx('tech_paths'), tx('tech_paths_help'),
      read(tx('tech_zone'), s.timezone),
      read(tx('tech_hold'), s.hold_minutes == null ? '' : String(s.hold_minutes)),
      h('p', { class: 'muted', text: tx('tech_hold_help') }),
      read(tx('tech_consent'), s.marketing_consent_text_version),
      read(tx('tech_site'), s.site_base_url),
      read(tx('tech_functions'), s.functions_base_url),
      read(tx('tech_order'), s.order_page_path),
      read(tx('tech_pay'), s.payment_link_path),
      read(tx('tech_articles'), articles)));
}

export async function render({ ctx, rest, reload }) {
  await loadSettingsTexts(rpc);
  const seeSettings = ctx.can('settings.edit');
  const isAdmin = ctx.role === 'admin';
  const tabs = visibleSettingTabs({ can: (p) => ctx.can(p), role: ctx.role });
  const tab = tabFromHash(location.hash || `#/asetukset/${rest || ''}`, tabs);
  if (tab && location.hash !== settingsHref(tab)) history.replaceState(null, '', settingsHref(tab));

  let bundle = null;
  let bundleFailed = false;
  if (seeSettings || ctx.can('pos.use')) {
    try { bundle = await rpc('admin_settings_bundle'); } catch { bundleFailed = true; }
  }
  let procountor = null;
  let procountorFailed = false;
  let editor = null;
  if (seeSettings && tab === 'yhteydet') {
    await loadProcountorTexts(rpc);
    try { procountor = await rpc('admin_procountor_status'); } catch { procountorFailed = true; }
    if (isAdmin) {
      try { editor = await rpc('admin_get_procountor_settings'); } catch { editor = null; }
    }
  }
  let calendarExport = null;
  let calendarExportFailed = false;
  if (isAdmin && tab === 'varaukset') {
    await loadCalendarExportTexts(rpc);
    try { calendarExport = await rpc('admin_get_booking_calendar'); } catch { calendarExportFailed = true; }
  }

  const ctxReload = { role: ctx.role, roleLabel: ctx.roleLabel, can: (p) => ctx.can(p), reload };
  let panel = null;
  if (!seeSettings || bundle?.qr_only) panel = tab === 'qr' ? await renderQrPanel() : null;
  else if (bundleFailed || !bundle) panel = h('p', { class: 'err', role: 'alert', text: tx('load_failed') });
  else if (tab === 'qr') panel = await renderQrPanel();
  else if (tab === 'etusivu') panel = homePanel(bundle, ctxReload);
  else if (tab === 'yritys') panel = businessPanel(bundle, reload);
  else if (tab === 'varaukset') panel = bookingPanel(bundle, reload, calendarExport, calendarExportFailed, isAdmin);
  else if (tab === 'maksut') panel = paymentsPanel(bundle, reload);
  else if (tab === 'sahkoposti') panel = mailPanel(bundle, reload);
  else if (tab === 'lahjakortit') { await loadVcrTexts(rpc); panel = giftPanel(bundle, reload); }
  else if (tab === 'laskut') panel = invoicePanel(bundle, reload);
  else if (tab === 'yhteydet') panel = connectionsPanel(bundle, procountor, procountorFailed, editor, isAdmin, reload);
  else if (tab === 'tekninen') panel = technicalPanel(bundle, reload);

  const tablist = h('div', { class: 'set-tabs set-noprint', role: 'tablist', 'aria-label': tx('tabs'), 'data-testid': 'settings-tabs' },
    ...tabs.map((id) => h('a', {
      href: settingsHref(id), role: 'tab', class: 'set-tab', 'data-testid': `tab-${id}`,
      'aria-selected': id === tab ? 'true' : 'false', id: `set-tab-${id}`,
    }, tx(`tab_${id}`))));

  return h('div', { class: 'set-page' },
    h('h1', { class: 'set-noprint', text: tx('title') }),
    seeSettings || tabs.every((id) => id === 'qr') ? null : h('p', { class: 'muted set-noprint', text: tx('readonly') }),
    tablist,
    h('div', { role: 'tabpanel', 'aria-labelledby': `set-tab-${tab}`, 'data-testid': 'settings-panel' }, panel));
}
