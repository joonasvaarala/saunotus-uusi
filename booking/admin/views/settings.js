// Asetukset (HALL-ASETUKSET-01): neljä välilehteä (Yleiset, Varaukset, Maksut ja laskutus, Järjestelmä) ja yksi tallennuspalkki per välilehti.
// Tallennus: admin_save_settings osioittain, vain muuttuneet osiot (settings-savebar.js). Procountor-tilit, kalenterivienti ja provisiosäännöt tallentuvat omilla kutsuillaan.
// Sähköpostin lähettäjä asuu Viesteissä, lahjakorttiasetukset Lahjakorteissa ja QR-tulostus Tuotteissa (settings-cards.js, qr-panel.js).
// Järjestelmä-välilehti vain roolille admin; sen osiot ovat oletuksena kiinni.
import { rpc } from '../sb.js';
import { h, field, toast, run, todayHel, tabs as tabList } from '../ui.js';
import { loadProcountorTexts, procountorText } from '../procountor-texts.js';
import { loadCalendarExportTexts } from '../calendar-export-texts.js';
import { loadSettingsTexts } from '../settings-texts.js';
import { visibleSettingTabs, settingsHref, tabFromHash, legacyTarget } from '../settings-tabs.js';
import { renderCalendarExport } from './calendar-export.js';
import { TECHNICAL_LIMITS, overviewNotices } from '../settings-logic.js';
import { createSaveBar } from '../settings-savebar.js';
import { tx, modeBadge, onOff, stat, toggle, num, textField, card, fold, read, group } from '../settings-widgets.js';
import { feeRulesCard } from './fee-rules-panel.js';
import { sumupSettingsCard } from './sumup-settings.js';

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
const sellerOf = (s) => (s.seller && typeof s.seller === 'object' ? s.seller : {});

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
  const vatRounding = h('input', { type: 'text', value: s.vat_rounding || '', disabled: !isAdmin, 'data-testid': 'procountor-vat-rounding' });   // booking_347 (K5)
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
      vat_rounding: vatRounding.value.trim(),
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
      field(procountorText('ui.admin.procountor.rounding'), rounding),
      field(procountorText('ui.admin.procountor.vat_rounding'), vatRounding, procountorText('ui.admin.procountor.vat_rounding_hint'))),
    h('h3', { text: procountorText('ui.admin.procountor.sales_title') }),
    h('div', { class: 'stack' }, SALES.map(([rate, key]) => field(procountorText(`ui.admin.procountor.${key}`), salesInputs[rate]))),
    h('h3', { text: procountorText('ui.admin.procountor.methods_title') }),
    h('p', { class: 'muted', 'data-testid': 'procountor-partner-hint', text: procountorText('ui.admin.procountor.methods_partner_hint') }),
    h('div', { class: 'stack' }, METHODS.map(([code, key]) => field(procountorText(`ui.admin.procountor.${key}`), methodInputs[code]))),
    isAdmin ? save : null,
    h('div', { class: 'row wrap' }, field(procountorText('ui.admin.procountor.preview_date'), previewDate), preview),
    previewOut);
}

function generalPanel(bundle, bar) {
  const s = bundle.settings || {};
  const seller = sellerOf(s);
  const pause = toggle(tx('pause_label'), tx('pause_help'), s.public_booking_enabled === true, { testid: 'pause-enabled', confirmOff: tx('pause_confirm') });
  const notes = overviewNotices(bundle);
  const shop = textField(tx('biz_shop'), s.business_name, tx('biz_shop_help'), { testid: 'biz-shop' });
  const name = textField(tx('biz_receipt'), seller.name);
  const phone = textField(tx('biz_phone'), seller.phone, null, { type: 'tel' });
  const email = textField(tx('biz_email'), seller.email, null, { type: 'email' });
  const web = textField(tx('biz_web'), seller.website, null, { type: 'url' });
  const footer = textField(tx('biz_footer'), seller.footer);
  const legal = textField(tx('biz_legal'), seller.legal_name);
  const trade = textField(tx('biz_trade'), seller.trade_name);
  const id = textField(tx('biz_id'), seller.business_id, null, { testid: 'biz-id' });
  const vat = textField(tx('biz_vat'), seller.vat_id, tx('biz_vat_help'));
  const street = textField(tx('biz_street'), seller.street);
  const post = textField(tx('biz_post'), seller.postal_code);
  const city = textField(tx('biz_city'), seller.city);
  const country = textField(tx('biz_country'), seller.country);
  const logo = String(seller.logo_url || '').trim();
  bar.section('pause', () => ({ public_booking_enabled: pause.input.checked }));
  bar.section('business', () => ({
    business_name: shop.input.value,
    seller: {
      name: name.input.value, legal_name: legal.input.value, trade_name: trade.input.value,
      business_id: id.input.value, vat_id: vat.input.value, street: street.input.value,
      postal_code: post.input.value, city: city.input.value, country: country.input.value,
      phone: phone.input.value, email: email.input.value, website: web.input.value, footer: footer.input.value,
    },
  }));
  return h('div', { class: 'stack', 'data-testid': 'panel-yleiset' },
    notes.length ? h('div', { class: 'warnbox', role: 'status', 'data-testid': 'settings-warn' }, notes.map((key) => h('p', { text: tx(key) }))) : null,
    card(tx('pause_title'), null, pause.row),
    card(tx('company_title'), tx('biz_lead'),
      group(tx('biz_group_public'), shop.node, name.node, phone.node, email.node, web.node, footer.node,
        h('p', { class: 'muted', text: logo ? tx('biz_logo_yes') : tx('biz_logo_no') })),
      group(tx('biz_group_official'), legal.node, trade.node, id.node, vat.node, street.node, post.node, city.node, country.node)));
}

function bookingPanel(bundle, bar) {
  const s = bundle.settings || {};
  const horizon = num(tx('win_sauna'), s.booking_horizon_days, tx('unit_days'), 1, 730, 'horizon-days');
  const treat = num(tx('win_treat'), s.public_treatment_horizon_days, tx('unit_days'), 1, 180);
  const lead = num(tx('dead_lead'), s.public_treatment_min_lead_minutes, tx('unit_minutes'), 0, 1440);
  const change = num(tx('dead_change'), s.customer_change_hours_before, tx('unit_hours'), 0, 720);
  const grp = num(tx('group_n'), s.checkout_group_threshold_persons, tx('unit_persons'), 0, 100, 'group-threshold');
  const days = num(tx('group_days'), s.checkout_group_hold_days, tx('unit_days'), 1, 60);
  const annual = num(tx('annual'), s.annual_card_max_persons, tx('unit_persons'), 1, 20);
  const daysWrap = h('div', {}, days.node);
  const sync = () => { daysWrap.hidden = Number(grp.input.value) === 0; };
  grp.input.addEventListener('input', sync);
  sync();
  bar.section('booking_window', () => ({ booking_horizon_days: Number(horizon.input.value), public_treatment_horizon_days: Number(treat.input.value) }));
  bar.section('booking_deadlines', () => ({ public_treatment_min_lead_minutes: Number(lead.input.value), customer_change_hours_before: Number(change.input.value) }));
  bar.section('booking_group', () => ({
    checkout_group_threshold_persons: Number(grp.input.value),
    checkout_group_hold_days: Number(days.input.value),
    annual_card_max_persons: Number(annual.input.value),
  }));
  return h('div', { class: 'stack', 'data-testid': 'panel-varaukset' },
    card(tx('win_title'), tx('win_help'), horizon.node, treat.node),
    card(tx('dead_title'), tx('dead_help'), lead.node, change.node),
    card(tx('group_title'), tx('group_help'), grp.node, daysWrap, annual.node, h('p', { class: 'muted', text: tx('annual_help') })));
}

function paymentsPanel(bundle, bar, ctx) {
  const s = bundle.settings || {};
  const holdMode = s.public_payment_mode === 'hold_until_paid';
  const company = toggle(tx('inv_co_label'), tx('inv_co_help'), s.checkout_company_invoice_enabled === true, { testid: 'company-invoice' });
  const methods = new Map((bundle.payment_methods || []).map((m) => [m.code, m]));
  const toggles = MANUAL.filter((code) => methods.has(code)).map((code) => ({ code, ui: toggle(methods.get(code).label, null, methods.get(code).active === true, { testid: `method-${code}` }) }));
  const cash = toggle(methods.get('cash')?.label || 'Käteinen', tx('cash_locked'), false, { testid: 'cash-locked', disabled: true });
  const bank = s.invoice_bank && typeof s.invoice_bank === 'object' ? s.invoice_bank : {};
  const due = num(tx('bill_due'), s.invoice_due_days, tx('unit_days'), 1, 90);
  const iban = textField(tx('bill_iban'), bank.iban, null, { testid: 'invoice-iban' });
  const bic = textField(tx('bill_bic'), bank.bic);
  const bankName = textField(tx('bill_bank'), bank.name);
  const hold = num(tx('hold_min'), s.checkout_hold_minutes, tx('unit_minutes'), 5, 60);
  const grace = num(tx('hold_extra'), s.checkout_mobilepay_grace_minutes, tx('unit_minutes'), 0, 60);
  const wait = num(tx('hold_cap'), s.checkout_mobilepay_max_wait_minutes, tx('unit_minutes'), 0, 120);
  bar.section('company_invoice', () => ({ checkout_company_invoice_enabled: company.input.checked }));
  bar.section('payment_methods', () => ({ methods: Object.fromEntries(toggles.map((t) => [t.code, t.ui.input.checked])) }));
  bar.section('invoice', () => ({ invoice_due_days: Number(due.input.value), iban: iban.input.value, bic: bic.input.value, name: bankName.input.value }));
  // Pitoajat vaikuttavat vain tilassa "pidä kunnes maksettu" (checkout_hold_minutes jne.): muuten niitä ei näytetä eikä tallenneta.
  if (holdMode) {
    bar.section('payment_hold', () => ({
      checkout_hold_minutes: Number(hold.input.value),
      checkout_mobilepay_grace_minutes: Number(grace.input.value),
      checkout_mobilepay_max_wait_minutes: Number(wait.input.value),
    }));
  }
  return h('div', { class: 'stack', 'data-testid': 'panel-maksut' },
    card(tx('methods_title'), tx('methods_lead'), ...toggles.map((t) => t.ui.row), cash.row),
    card(tx('inv_co_title'), null, company.row),
    card(tx('bill_title'), tx('bill_help'), due.node, iban.node, bic.node, bankName.node),
    holdMode
      ? card(tx('hold_title'), tx('hold_help'), hold.node, grace.node, wait.node)
      : h('p', { class: 'muted', 'data-testid': 'hold-hidden-note', text: tx('hold_hidden_note') }),
    sumupSettingsCard({ ctx }),
    feeRulesCard());
}

function systemPanel(bundle, bar, { procountor, procountorFailed, editor, calendarExport, calendarExportFailed, reload }) {
  const s = bundle.settings || {};
  const series = s.receipt_series && typeof s.receipt_series === 'object' ? s.receipt_series : {};
  const fields = LIMIT_FIELDS.filter(([key]) => TECHNICAL_LIMITS[key]).map(([key, label]) => {
    const [min, max] = TECHNICAL_LIMITS[key];
    return { key, ...num(tx(label), s[key], '', min, max) };
  });
  const articles = [s.articles_label_fi, s.articles_path_fi, s.articles_label_en, s.articles_path_en].filter(Boolean).join(' · ');
  bar.section('technical', () => ({ limits: Object.fromEntries(fields.map((f) => [f.key, Number(f.input.value)])) }));
  return h('div', { class: 'stack', 'data-testid': 'panel-jarjestelma' },
    h('div', { class: 'warnbox', role: 'status' }, h('p', { text: tx('sys_lead') })),
    fold(tx('sys_status_title'), tx('readonly_note'), { testid: 'sys-status' },
      stat('Montonio', modeBadge(bundle.montonio?.mode)),
      stat(tx('mail_mode'), modeBadge(bundle.resend?.mode)),
      stat(tx('mail_allow'), onOff(bundle.resend?.allowlist_on === true)),
      read(tx('mail_allow_count'), bundle.resend?.allowlist_on ? String(bundle.resend.allowlist_count ?? 0) : '0'),
      stat('Procountor', modeBadge(bundle.procountor?.mode)),
      stat(tx('conn_calendar'), modeBadge(bundle.booking_calendar?.mode)),
      stat(tx('pay_mode'), h('b', { text: s.public_payment_mode === 'hold_until_paid' ? tx('mode_hold') : tx('mode_pay_later') })),
      stat(tx('pay_later_test'), onOff(s.pay_later_test_enabled === true)),
      stat(tx('bill_dispatch'), modeBadge(s.invoice_dispatch_mode === 'live' ? 'live' : s.invoice_dispatch_mode === 'off' ? 'off' : 'dry_run')),
      stat(tx('gift_johku'), onOff(s['gift_cards.johku_cards_redeemable'] === true)),
      stat(tx('gift_partner'), onOff(s['voucher_claims.enabled'] === true)),
      stat(tx('gift_problem'), onOff(s['voucher_claims.problem_emails_enabled'] === true)),
      stat(tx('gift_accounted'), onOff(s['voucher_claims.partner_voucher_accounted'] === true)),
      h('p', { text: tx('conn_closure') }), h('p', { text: tx('conn_reviews') })),
    fold(procountorText('ui.admin.procountor.title'), null, { testid: 'sys-procountor' },
      procountorCard(procountor, procountorFailed), procountorForm(editor, true, reload)),
    fold(tx('sys_calendar_title'), null, { testid: 'sys-calendar' },
      renderCalendarExport({ state: calendarExport, failed: calendarExportFailed, isAdmin: true, reload })),
    fold(tx('tech_title'), tx('tech_help'), { testid: 'sys-limits' }, ...fields.map((f) => f.node)),
    fold(tx('tech_paths'), tx('tech_paths_help'), { testid: 'sys-paths' },
      read(tx('tech_zone'), s.timezone),
      read(tx('tech_hold'), s.hold_minutes == null ? '' : String(s.hold_minutes)),
      h('p', { class: 'muted', text: tx('tech_hold_help') }),
      read(tx('tech_consent'), s.marketing_consent_text_version),
      read(tx('tech_site'), s.site_base_url),
      read(tx('tech_functions'), s.functions_base_url),
      read(tx('tech_order'), s.order_page_path),
      read(tx('tech_pay'), s.payment_link_path),
      read(tx('tech_articles'), articles),
      read(tx('series_receipt'), series.receipt),
      read(tx('series_refund'), series.refund_receipt),
      read(tx('series_gift'), series.giftcard_info)));
}

export async function render({ ctx, rest, reload }) {
  await loadSettingsTexts(rpc);
  const seeSettings = ctx.can('settings.edit');
  const isAdmin = ctx.role === 'admin';
  const tabs = visibleSettingTabs({ can: (p) => ctx.can(p), role: ctx.role });
  const hash = location.hash || `#/asetukset/${rest || ''}`;
  const moved = legacyTarget(hash);
  if (moved?.href) { location.replace(moved.href); return h('p', { class: 'muted', text: tx('moved') }); }
  const tab = tabFromHash(hash, tabs);
  if (tab && location.hash !== settingsHref(tab)) history.replaceState(null, '', settingsHref(tab));

  let bundle = null;
  let bundleFailed = false;
  if (seeSettings) {
    try { bundle = await rpc('admin_settings_bundle'); } catch { bundleFailed = true; }
  }
  const sys = { reload };
  if (seeSettings && isAdmin && tab === 'jarjestelma') {
    await Promise.all([loadProcountorTexts(rpc), loadCalendarExportTexts(rpc)]);
    try { sys.procountor = await rpc('admin_procountor_status'); } catch { sys.procountorFailed = true; }
    try { sys.editor = await rpc('admin_get_procountor_settings'); } catch { sys.editor = null; }
    try { sys.calendarExport = await rpc('admin_get_booking_calendar'); } catch { sys.calendarExportFailed = true; }
  }

  const bar = createSaveBar({ reload });
  let panel = null;
  if (!seeSettings) panel = h('p', { class: 'muted', text: tx('readonly') });
  else if (bundleFailed || !bundle) panel = h('p', { class: 'err', role: 'alert', text: tx('load_failed') });
  else if (tab === 'yleiset') panel = generalPanel(bundle, bar);
  else if (tab === 'varaukset') panel = bookingPanel(bundle, bar);
  else if (tab === 'maksut') panel = paymentsPanel(bundle, bar, ctx);
  else if (tab === 'jarjestelma') panel = systemPanel(bundle, bar, sys);
  const content = h('div', { role: 'tabpanel', id: 'settings-panel', 'aria-labelledby': `set-tab-${tab}`, 'data-testid': 'settings-panel' }, panel, bar.node);
  bar.watch(content);

  const tablist = tabList({ label: tx('tabs'), cls: 'set-noprint', testid: 'settings-tabs', idPrefix: 'set-tab', selected: tab,
    items: tabs.map((id) => ({ id, text: tx(`tab_${id}`), href: settingsHref(id), controls: 'settings-panel', testid: `tab-${id}` })) });
  return h('div', { class: 'set-page' }, h('h1', { class: 'set-noprint', text: tx('title') }), tabs.length ? tablist : null, content);
}
