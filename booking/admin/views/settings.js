// Yleiset asetukset (oikeus settings.edit: manager + admin) + henkilökunta ja roolit (oikeus staff.manage: vain admin).
import { rpc, select } from '../sb.js';
import { h, field, toast, run, badge, dialog } from '../ui.js';

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
  const canStaff = ctx.can('staff.manage');
  const staff = canStaff ? await rpc('admin_list_staff').catch(() => null) : null;
  const roles = canStaff ? (await rpc('admin_list_roles')).filter((r) => r.is_staff) : [];
  const staffBox = staff ? h('div', { class: 'stack' }, h('h2', { text: 'Henkilökunta' }),
    h('p', { class: 'muted', text: 'Käyttäjä luodaan ensin Supabase Authissa (Dashboard → Authentication → Add user), sitten tässä annetaan käyttäjätunnuksen UUID ja rooli. admin = kaikki oikeudet; manager (ylläpitäjä) = lisäksi hinnat, kuvaukset, tuoteasetukset, asetukset, resurssit ja vuorosäännöt; staff (peruskäyttäjä) = varaukset, asiakkaat, maksujen kirjaus, sulut. Uusia rooleja: ks. docs/roolit-ja-kb.md.' }),
    ...staff.map((s) => h('div', { class: 'card row wrap' }, h('div', { class: 'grow' }, h('strong', { text: s.name }), h('small', { text: ` ${s.email || s.user_id}` })), h('select', { 'aria-label': `Rooli: ${s.name}`, onchange: (e) => run(e.target, async () => { await rpc('admin_upsert_staff', { p_user_id: s.user_id, p_name: s.name, p_role: e.target.value, p_active: s.active }); toast('Rooli päivitetty'); reload(); }) }, roles.map((r) => h('option', { value: r.code, text: r.label, selected: r.code === s.role || null }))), s.active ? null : badge('err', 'ei aktiivinen'),
      h('button', { class: 'btn sm', type: 'button', text: s.active ? 'Poista käytöstä' : 'Aktivoi', onclick: (e) => run(e.target, async () => { await rpc('admin_upsert_staff', { p_user_id: s.user_id, p_name: s.name, p_role: s.role, p_active: !s.active }); toast('Tallennettu'); reload(); }) }))),
    h('button', { class: 'btn ghost', type: 'button', onclick: () => addStaff(reload, roles) }, '+ Lisää henkilö')) : null;
  return [h('h1', { text: 'Asetukset' }), isAdmin ? null : h('p', { class: 'muted', text: 'Näet asetukset; muokkaus vaatii ylläpitäjän (manager/admin) oikeudet.' }), h('div', { class: 'stack' }, forms), staffBox];
}
function addStaff(reload, roles) {
  const f = h('form', { class: 'stack' }, field('Käyttäjän UUID (Supabase Auth)', h('input', { name: 'id', required: true, pattern: '[0-9a-fA-F-]{36}' })), field('Nimi', h('input', { name: 'name', required: true })),
    field('Rooli', h('select', { name: 'role' }, roles.map((r) => h('option', { value: r.code, text: r.label, selected: r.code === 'staff' || null }))), 'Rooli määrää oikeudet (booking.role_permissions).'), h('button', { class: 'btn primary', type: 'submit', text: 'Lisää' }));
  const d = dialog('Lisää henkilö', f);
  f.addEventListener('submit', (ev) => { ev.preventDefault(); run(f.querySelector('button'), async () => { await rpc('admin_upsert_staff', { p_user_id: f.elements.id.value.trim(), p_name: f.elements.name.value.trim(), p_role: f.elements.role.value, p_active: true }); toast('Lisätty'); d.close(); reload(); }); });
}
