// Yleiset asetukset (oikeus settings.edit: manager + admin). Käyttäjähallinta on omassa näkymässään (views/users.js, vain admin).
import { rpc, select } from '../sb.js';
import { h, field, toast, run } from '../ui.js';
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

export async function render({ ctx, reload }) {
  const isAdmin = ctx.can('settings.edit');
  await loadProcountorTexts(rpc);
  let procountor = null, procountorFailed = false;
  try { procountor = await rpc('admin_procountor_status'); } catch { procountorFailed = true; }
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
  return [h('h1', { text: 'Asetukset' }), isAdmin ? null : h('p', { class: 'muted', text: 'Näet asetukset; muokkaus vaatii ylläpitäjän (manager/admin) oikeudet.' }), procountorCard(procountor, procountorFailed), h('div', { class: 'stack' }, forms)];
}
