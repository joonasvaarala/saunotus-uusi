// Yleiset asetukset (oikeus settings.edit: manager + admin). Käyttäjähallinta on omassa näkymässään (views/users.js, vain admin).
import { rpc, select } from '../sb.js';
import { h, field, toast, run } from '../ui.js';

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
export async function render({ ctx, reload }) {
  const isAdmin = ctx.can('settings.edit');
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
  return [h('h1', { text: 'Asetukset' }), isAdmin ? null : h('p', { class: 'muted', text: 'Näet asetukset; muokkaus vaatii ylläpitäjän (manager/admin) oikeudet.' }), h('div', { class: 'stack' }, forms)];
}
