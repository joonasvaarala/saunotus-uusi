// Käyttäjät (vain staff.manage = admin): lista, kutsu sähköpostilla (Edge Function admin-users), roolin vaihto, käyttöönotto/poisto käytöstä, linkitys työntekijään (työvuorot).
import { rpc, fn, getSession } from '../sb.js';
import { h, field, toast, run, badge, dialog, empty, errMsg } from '../ui.js';
import { renderShiftStaffPanel } from './shift-staff-panel.js';

const INVITE_ROLES = ['admin', 'manager', 'staff'];   // sama sallittulista kuin Edge Functionissa; asiakasrooleja ei voi kutsua
const ROLE_HELP = 'admin = kaikki, myös käyttäjähallinta; manager (ylläpitäjä) = varaukset, hinnat, asetukset, resurssit ja sulut + kaikkien työvuorot, ei käyttäjähallintaa; staff (peruskäyttäjä) = varaukset, asiakkaat, maksujen kirjaus ja omat työvuorot.';

export async function render({ ctx, reload }) {
  const me = getSession()?.user?.id;
  const [staff, rolesAll] = await Promise.all([rpc('admin_list_staff'), rpc('admin_list_roles')]);
  const roles = rolesAll.filter((r) => r.is_staff);
  // public.staff-lista voi puuttua (public-skeema tyhjä tai ei oikeutta): linkitys on silloin pois käytöstä, muu toimii
  let pub = null, pubErr = null;
  try { pub = await rpc('admin_list_public_staff'); } catch (e) { pubErr = errMsg(e); }

  const rows = staff.map((s) => {
    const self = s.user_id === me;
    const roleSel = h('select', { 'aria-label': `Rooli: ${s.name}`, disabled: self || !s.active || null, title: self ? 'Omaa roolia ei voi vaihtaa' : null,
      onchange: (e) => run(e.target, async () => { try { await rpc('admin_set_staff_role', { p_user_id: s.user_id, p_role: e.target.value }); toast('Rooli päivitetty'); reload(); } catch (err) { e.target.value = s.role; throw err; } }) },
      roles.map((r) => h('option', { value: r.code, text: r.label, selected: r.code === s.role || null })));
    const linkSel = pub ? h('select', { 'aria-label': `Työntekijä (vuorotiedot): ${s.name}`, onchange: (e) => run(e.target, async () => { try { await rpc('admin_link_public_staff', { p_user_id: s.user_id, p_public_staff_id: e.target.value || null }); toast(e.target.value ? 'Linkitetty työntekijään' : 'Linkitys poistettu'); reload(); } catch (err) { e.target.value = s.public_staff_id || ''; throw err; } }) },
      h('option', { value: '', text: '– ei linkitetty –' }), pub.filter((p) => p.active || p.id === s.public_staff_id).map((p) => h('option', { value: p.id, text: p.name + (p.active ? '' : ' (ei aktiivinen)'), selected: p.id === s.public_staff_id || null })))
      : h('span', { class: 'muted', text: s.public_staff_id ? 'linkitetty' : 'ei linkitetty' });
    return h('div', { class: `card user${s.active ? '' : ' inactive'}`, 'data-user': s.email || s.user_id },
      h('div', { class: 'row wrap' }, h('div', { class: 'grow' }, h('strong', { text: s.name }), ' ', h('small', { text: s.email || s.user_id })), self ? badge('muted', 'sinä') : null, s.active ? null : badge('err', 'ei aktiivinen')),
      h('div', { class: 'user-grid' }, field('Rooli', roleSel), field('Työntekijä (työvuorot)', linkSel),
        h('div', { class: 'user-act' }, h('button', { class: `btn sm${s.active ? ' danger' : ''}`, type: 'button', disabled: self || null, title: self ? 'Et voi poistaa omaa tunnustasi käytöstä' : null, text: s.active ? 'Poista käytöstä' : 'Aktivoi',
          onclick: (e) => run(e.target, async () => {
            if (s.active && !confirm(`Poistetaanko ${s.name} käytöstä? Kirjautuminen estetään.`)) return;
            await fn('admin-users', { action: s.active ? 'deactivate' : 'reactivate', user_id: s.user_id }); toast(s.active ? 'Poistettu käytöstä' : 'Aktivoitu'); reload();
          }) }))));
  });
  return [h('h1', { text: 'Käyttäjät' }),
    h('p', { class: 'muted', text: ROLE_HELP }),
    pubErr ? h('p', { class: 'notice', role: 'status', text: 'Työntekijälistaa (public-skeema) ei voitu lukea, joten linkitys työvuoroihin on pois käytöstä. Muu käyttäjähallinta toimii.' }) : null,
    h('div', { class: 'toolbar' }, h('button', { class: 'btn primary', type: 'button', onclick: () => invite(reload, roles) }, '+ Kutsu käyttäjä')),
    h('div', { class: 'stack' }, rows.length ? rows : empty('Ei käyttäjiä.')),
    await renderShiftStaffPanel({ reload })];   // booking_153: vuorotarjousten omat sivut (ei kaada näkymää, jos RPC puuttuu)
}

function invite(reload, roles) {
  const opts = roles.filter((r) => INVITE_ROLES.includes(r.code));
  const f = h('form', { class: 'stack' },
    field('Sähköposti', h('input', { name: 'email', type: 'email', required: true, autocomplete: 'off', inputmode: 'email' }), 'Käyttäjä saa sähköpostiin linkin, jolla hän asettaa salasanan.'),
    field('Nimi', h('input', { name: 'name', required: true, maxlength: 100 })),
    field('Rooli', h('select', { name: 'role' }, opts.map((r) => h('option', { value: r.code, text: r.label, selected: r.code === 'staff' || null }))), ROLE_HELP),
    h('button', { class: 'btn primary', type: 'submit', text: 'Lähetä kutsu' }));
  const d = dialog('Kutsu käyttäjä', f);
  f.addEventListener('submit', (ev) => {
    ev.preventDefault();
    run(f.querySelector('button'), async () => {
      const res = await fn('admin-users', { action: 'invite', email: f.elements.email.value.trim(), name: f.elements.name.value.trim(), role: f.elements.role.value });
      if (res.dev_invite_link) {   // vain paikallinen kehityspalvelin palauttaa linkin; oikea Supabase lähettää sen sähköpostilla
        f.replaceChildren(h('p', { text: 'Kehitystila: kutsulinkki (tuotannossa lähtee sähköpostilla):' }), h('input', { readonly: true, value: res.dev_invite_link, 'aria-label': 'Kutsulinkki', onfocus: (e) => e.target.select() }),
          h('button', { class: 'btn', type: 'button', text: 'Sulje', onclick: () => { d.close(); reload(); } }));
        return;
      }
      toast(res.existing_user ? 'Käyttäjällä oli jo tunnus: rooli annettu' : 'Kutsu lähetetty'); d.close(); reload();
    });
  });
}
