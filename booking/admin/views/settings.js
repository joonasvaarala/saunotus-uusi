// Yleiset asetukset (vain admin muokkaa) + henkilökunta ja roolit.
import { rpc, select } from '../sb.js';
import { h, field, toast, run, badge, dialog } from '../ui.js';

const META = {
  public_booking_enabled: ['Verkkovaraus käytössä', 'bool'],
  public_payment_mode: ['Verkkovarauksen maksutila', ['pay_later', 'hold_until_paid'], 'pay_later = varaus vahvistuu heti, maksu paikan päällä. hold_until_paid = 15 min pito, vahvistuu maksettaessa (Visma Pay, myöhemmin).'],
  hold_minutes: ['Maksamattoman pidon kesto (min)', 'number'], booking_horizon_days: ['Kuinka pitkälle eteenpäin voi varata (pv)', 'number'],
  business_name: ['Yrityksen nimi', 'text'], timezone: ['Aikavyöhyke', 'text'],
  rl_ip_per_10min: ['Rate limit: yritystä / IP / 10 min', 'number'], rl_email_per_10min: ['Rate limit: yritystä / sähköposti / 10 min', 'number'],
  marketing_consent_text_version: ['Markkinointisuostumustekstin versio', 'text'],
};
export async function render({ ctx, reload }) {
  const isAdmin = ctx.role === 'admin';
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
  const staff = await rpc('admin_list_staff').catch(() => null);
  const staffBox = staff ? h('div', { class: 'stack' }, h('h2', { text: 'Henkilökunta' }),
    h('p', { class: 'muted', text: 'Käyttäjä luodaan ensin Supabase Authissa (Dashboard → Authentication → Add user), sitten tässä annetaan käyttäjätunnuksen UUID ja rooli. admin = kaikki; staff = varaukset, asiakkaat, maksujen kirjaus, sulut (ei hintoja/asetuksia).' }),
    ...staff.map((s) => h('div', { class: 'card row wrap' }, h('div', { class: 'grow' }, h('strong', { text: s.name }), h('small', { text: ` ${s.email || s.user_id}` })), badge(s.role === 'admin' ? 'warn' : 'ok', s.role), s.active ? null : badge('err', 'ei aktiivinen'),
      h('button', { class: 'btn sm', type: 'button', text: s.active ? 'Poista käytöstä' : 'Aktivoi', onclick: (e) => run(e.target, async () => { await rpc('admin_upsert_staff', { p_user_id: s.user_id, p_name: s.name, p_role: s.role, p_active: !s.active }); toast('Tallennettu'); reload(); }) }))),
    h('button', { class: 'btn ghost', type: 'button', onclick: () => addStaff(reload) }, '+ Lisää henkilö')) : null;
  return [h('h1', { text: 'Asetukset' }), isAdmin ? null : h('p', { class: 'muted', text: 'Näet asetukset; muokkaus vain ylläpitäjälle.' }), h('div', { class: 'stack' }, forms), staffBox];
}
function addStaff(reload) {
  const f = h('form', { class: 'stack' }, field('Käyttäjän UUID (Supabase Auth)', h('input', { name: 'id', required: true, pattern: '[0-9a-fA-F-]{36}' })), field('Nimi', h('input', { name: 'name', required: true })),
    field('Rooli', h('select', { name: 'role' }, h('option', { value: 'staff', text: 'staff (henkilökunta)' }), h('option', { value: 'admin', text: 'admin (ylläpitäjä)' }))), h('button', { class: 'btn primary', type: 'submit', text: 'Lisää' }));
  const d = dialog('Lisää henkilö', f);
  f.addEventListener('submit', (ev) => { ev.preventDefault(); run(f.querySelector('button'), async () => { await rpc('admin_upsert_staff', { p_user_id: f.elements.id.value.trim(), p_name: f.elements.name.value.trim(), p_role: f.elements.role.value, p_active: true }); toast('Lisätty'); d.close(); reload(); }); });
}
