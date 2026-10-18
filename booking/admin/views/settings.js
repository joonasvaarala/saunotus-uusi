// Yleiset asetukset (oikeus settings.edit: manager + admin). Käyttäjähallinta on omassa näkymässään (views/users.js, vain admin).
import { rpc, select } from '../sb.js';
import { h, field, toast, run, todayHel } from '../ui.js';
import { loadProcountorTexts, procountorText as pc } from '../procountor-texts.js';

const META = {
  public_booking_enabled: ['Verkkovaraus käytössä', 'bool'],
  public_payment_mode: ['Verkkovarauksen maksutila', ['pay_later', 'hold_until_paid'], 'pay_later = varaus vahvistuu heti, maksu paikan päällä. hold_until_paid = 15 min pito, vahvistuu maksettaessa (Visma Pay, myöhemmin).'],
  hold_minutes: ['Maksamattoman pidon kesto (min)', 'number'], booking_horizon_days: ['Kuinka pitkälle eteenpäin voi varata (pv)', 'number'],
  business_name: ['Yrityksen nimi', 'text'], timezone: ['Aikavyöhyke', 'text'],
  rl_ip_per_10min: ['Rate limit: yritystä / IP / 10 min', 'number'], rl_email_per_10min: ['Rate limit: yritystä / sähköposti / 10 min', 'number'],
  customer_change_hours_before: ['Asiakas voi muuttaa varaustaan viimeistään (h ennen vuoron alkua)', 'number', 'Asiakas voi siirtää varauksen toiselle vuorolle tai muuttaa henkilömäärää tämän ajan sisällä alkavaan vuoroon asti. Peruutukset: sähköpostilla henkilökunnalle.'],
  annual_card_max_persons: ['Vuosikorttivarauksen max henkilömäärä', 'number', 'Vuosikortilla varataan ilmaiseksi yleisiä vuoroja, yksi tuleva varaus kerrallaan.'],
  rl_change_per_10min: ['Rate limit: muutosyritystä / varaustunnus / 10 min', 'number'],
  marketing_consent_text_version: ['Markkinointisuostumustekstin versio', 'text'],
};
function procountorCard(state, failed) {
  if (failed || !state) {
    return h('section', { class: 'card', 'data-testid': 'procountor-status' },
      h('h2', { text: pc('ui.admin.procountor.title') }),
      h('p', { class: 'err', 'data-testid': 'procountor-error', text: pc('ui.admin.procountor.unavailable') }));
  }
  const modeKey = state.mode === 'live' ? 'mode_live' : state.mode === 'dry_run' ? 'mode_dry_run' : 'mode_off';
  const envKey = state.environment === 'prod' ? 'env_prod' : 'env_pts';
  const statusKey = 'status_' + (state.last?.status || '');
  const statusLabel = state.last ? pc('ui.admin.procountor.' + statusKey) : '';
  const last = state.last
    ? `${pc('ui.admin.procountor.last')}: ${state.last.business_date || state.last.kind || ''} · ${statusLabel} · ${pc('ui.admin.procountor.attempts')} ${state.last.attempts ?? 0}`
    : pc('ui.admin.procountor.last_none');
  const errors = Array.isArray(state.errors) && state.errors.length
    ? state.errors.map((e) => h('li', { text: [e.business_date, e.kind, e.status, e.last_error].filter(Boolean).join(' · ') }))
    : [h('li', { text: pc('ui.admin.procountor.errors_none') })];
  return h('section', { class: 'card', 'data-testid': 'procountor-status' },
    h('h2', { text: pc('ui.admin.procountor.title') }),
    h('p', { class: 'muted', text: pc('ui.admin.procountor.lead') }),
    h('p', { 'data-testid': 'procountor-mode', text: `${pc('ui.admin.procountor.mode')}: ${pc('ui.admin.procountor.' + modeKey)} · ${pc('ui.admin.procountor.env')}: ${pc('ui.admin.procountor.' + envKey)}` }),
    h('p', { text: `${pc('ui.admin.procountor.daily')}: ${state.daily_enabled ? pc('ui.admin.procountor.daily_on') : pc('ui.admin.procountor.daily_off')}` }),
    h('p', { text: state.accounts_configured ? pc('ui.admin.procountor.accounts_ok') : pc('ui.admin.procountor.accounts_missing') }),
    h('p', { text: state.bank_account_configured ? pc('ui.admin.procountor.bank_ok') : pc('ui.admin.procountor.bank_missing') }),
    h('p', { 'data-testid': 'procountor-last', text: last }),
    h('p', { text: pc('ui.admin.procountor.errors') }),
    h('ul', { 'data-testid': 'procountor-error' }, errors));
}

const SALES = [['25.5', 'sales_25_5'], ['13.5', 'sales_13_5'], ['0', 'sales_0'], ['14', 'sales_14'], ['24', 'sales_24'], ['10', 'sales_10']];
const METHODS = [['cash', 'method_cash'], ['card_terminal', 'method_card_terminal'], ['mobilepay', 'method_mobilepay'], ['bank_transfer', 'method_bank_transfer'], ['invoice', 'method_invoice'], ['gift_card', 'method_gift_card'], ['partner_voucher', 'method_partner_voucher'], ['visma_pay', 'method_visma_pay'], ['annual_card', 'method_annual_card'], ['pay_later', 'method_pay_later'], ['other', 'method_other']];
const choice = (value, label, current) => h('option', { value, text: label, selected: current === value || null });

function procountorForm(cfg, isAdmin, reload) {
  if (!cfg) {
    return h('section', { class: 'card', 'data-testid': 'procountor-settings' },
      h('h2', { text: pc('ui.admin.procountor.edit_title') }),
      h('p', { class: 'muted', text: pc('ui.admin.procountor.unavailable') }));
  }
  const s = cfg.accounts || {};
  const sales = s.sales_by_vat || {};
  const methods = s.clearing_by_method || {};
  const mode = h('select', { disabled: !isAdmin, 'data-testid': 'procountor-edit-mode' }, [
    choice('off', pc('ui.admin.procountor.mode_off'), cfg.mode || 'off'),
    choice('dry_run', pc('ui.admin.procountor.mode_dry_run'), cfg.mode),
    choice('live', pc('ui.admin.procountor.mode_live'), cfg.mode),
  ]);
  const environment = h('select', { disabled: !isAdmin, 'data-testid': 'procountor-edit-env' }, [
    choice('pts', pc('ui.admin.procountor.env_pts'), cfg.environment || 'pts'),
    choice('prod', pc('ui.admin.procountor.env_prod'), cfg.environment),
  ]);
  const daily = h('input', { type: 'checkbox', disabled: !isAdmin, 'data-testid': 'procountor-daily' });
  daily.checked = cfg.daily_enabled === true;
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
    mode: mode.value,
    environment: environment.value,
    daily_enabled: daily.checked,
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
  const save = h('button', { class: 'btn primary', type: 'button', text: pc('ui.admin.procountor.save'), 'data-testid': 'procountor-save', disabled: !isAdmin || null, onclick: (e) => run(e.target, async () => {
    await rpc('admin_set_procountor_settings', { p: collect() });
    toast(pc('ui.admin.procountor.saved'));
    if (reload) await reload();
  }) });
  const preview = h('button', { class: 'btn', type: 'button', text: pc('ui.admin.procountor.preview'), 'data-testid': 'procountor-preview', onclick: (e) => run(e.target, async () => {
    const res = await rpc('admin_procountor_preview_daily', { p_date: previewDate.value });
    const missing = Array.isArray(res.missing) ? res.missing.join(', ') : '';
    previewOut.textContent = `${pc('ui.admin.procountor.preview_receipts')} ${res.receipts ?? 0}. ${pc('ui.admin.procountor.preview_not_sent')}${missing ? ` ${pc('ui.admin.procountor.missing')}: ${missing}` : ''}`;
  }) });
  return h('section', { class: 'card', 'data-testid': 'procountor-settings' },
    h('h2', { text: pc('ui.admin.procountor.edit_title') }),
    h('p', { class: 'muted', text: pc('ui.admin.procountor.edit_lead') }),
    h('div', { class: 'stack' },
      field(pc('ui.admin.procountor.mode'), mode),
      field(pc('ui.admin.procountor.env'), environment),
      field(pc('ui.admin.procountor.daily'), daily),
      field(pc('ui.admin.procountor.approved_by'), approved, pc('ui.admin.procountor.approved_by_hint')),
      field(pc('ui.admin.procountor.vat_status'), vat),
      field(pc('ui.admin.procountor.api_prefix'), prefix),
      field(pc('ui.admin.procountor.bank_account'), bank, pc('ui.admin.procountor.bank_keep')),
      field(pc('ui.admin.procountor.rounding'), rounding)),
    h('h3', { text: pc('ui.admin.procountor.sales_title') }),
    h('div', { class: 'stack' }, SALES.map(([rate, key]) => field(pc(`ui.admin.procountor.${key}`), salesInputs[rate]))),
    h('h3', { text: pc('ui.admin.procountor.methods_title') }),
    h('div', { class: 'stack' }, METHODS.map(([code, key]) => field(pc(`ui.admin.procountor.${key}`), methodInputs[code]))),
    isAdmin ? save : null,
    h('div', { class: 'row wrap' }, field(pc('ui.admin.procountor.preview_date'), previewDate), preview),
    previewOut);
}

export async function render({ ctx, reload }) {
  const isAdmin = ctx.can('settings.edit');
  await loadProcountorTexts(rpc);
  let procountor = null, procountorFailed = false;
  try { procountor = await rpc('admin_procountor_status'); } catch { procountorFailed = true; }
  let editor = null;
  try { editor = await rpc('admin_get_procountor_settings'); } catch { editor = null; }
  const settings = await select('settings', { select: 'key,value,is_public', order: 'key.asc' });
  const forms = settings.map((s) => {
    const [label, type, hint] = META[s.key] || [s.key, 'text'];
    let input;
    if (type === 'bool') { input = h('input', { type: 'checkbox', disabled: !isAdmin }); input.checked = s.value === true; }
    else if (Array.isArray(type)) input = h('select', { disabled: !isAdmin }, type.map((o) => h('option', { value: o, text: o, selected: s.value === o || null })));
    else input = h('input', { type: type === 'number' ? 'number' : 'text', value: s.value, disabled: !isAdmin });
    const val = () => (type === 'bool' ? input.checked : type === 'number' ? +input.value : input.value);
    return h('div', { class: 'card setting' }, field(label, input, hint), isAdmin ? h('button', { class: 'btn sm', type: 'button', text: 'Tallenna', onclick: (e) => run(e.target, async () => { await rpc('admin_set_setting', { p_key: s.key, p_value: val() }); toast('Tallennettu'); }) }) : null);
  });
  return [h('h1', { text: 'Asetukset' }), isAdmin ? null : h('p', { class: 'muted', text: 'Näet asetukset; muokkaus vaatii ylläpitäjän (manager/admin) oikeudet.' }), procountorCard(procountor, procountorFailed), procountorForm(editor, isAdmin, reload), h('div', { class: 'stack' }, forms)];
}
