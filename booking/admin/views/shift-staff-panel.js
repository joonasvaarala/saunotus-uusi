// booking_153: Käyttäjät-näkymän osio "Vuorotarjousten omat sivut" (vain staff.manage).
// Pysyvä henkilökohtainen linkki (sama token-malli kuin vastaussivulla): luo/näytä, uusi (vanha lakkaa), peru.
// WhatsApp-suostumus: jos henkilö on itse kirjoittanut Tapion numeroon, näytetään ehdotus ottaa WhatsApp käyttöön.
// whatsapp_enabled-kenttää EI muuteta täältä (public.staff kuuluu Työvuoro-Tapiolle).
import { rpc } from '../sb.js';
import { h, toast, run, badge, fmtDT, errMsg } from '../ui.js';
import { ssText, loadSsTexts } from '../shift-staff-texts.js';

const T = (k, vars) => ssText('ui.admin.shift_staff.' + k, vars);

export async function renderShiftStaffPanel({ reload, rpcFn = rpc } = {}) {
  await loadSsTexts(rpcFn);
  let rows;
  try { rows = await rpcFn('admin_shift_staff_overview'); } catch (e) {
    return h('section', { class: 'stack shift-staff' }, h('h2', { text: T('title') }), h('p', { class: 'notice', role: 'status', text: `${T('unavailable')} (${errMsg(e)})` }));
  }
  const list = Array.isArray(rows) ? rows : [];
  const linkBox = (url) => h('input', { readonly: true, value: url, 'aria-label': T('link_label'), onfocus: (e) => e.target.select() });
  const cards = list.map((s) => {
    const out = h('div', { class: 'shift-staff-link' });
    const act = async (btn, action) => run(btn, async () => {
      if (action === 'renew' && s.link_status === 'active' && !confirm(T('renew_confirm', { name: s.name }))) return;
      if (action === 'revoke' && !confirm(T('revoke_confirm', { name: s.name }))) return;
      const res = await rpcFn('admin_shift_staff_link', { p_staff: s.staff_id, p_action: action });
      if (action === 'revoke') { toast(T('revoked')); reload?.(); return; }
      if (action === 'dismiss_suggestion') { reload?.(); return; }
      if (res?.url) {
        out.replaceChildren(linkBox(res.url));
        try { await navigator.clipboard?.writeText(res.url); toast(T('copied')); } catch { /* kopiointi ei pakollinen */ }
      }
    });
    const status = s.link_status === 'active' ? badge('ok', T('link_active')) : s.link_status === 'revoked' ? badge('err', T('link_revoked')) : badge('muted', T('link_none'));
    const suggest = s.suggest_whatsapp
      ? h('p', { class: 'notice', role: 'status' }, T('suggest_whatsapp', { name: s.name, when: fmtDT(s.consent_at) }), ' ',
          h('button', { class: 'btn sm', type: 'button', text: T('dismiss'), onclick: (e) => act(e.target, 'dismiss_suggestion') }))
      : null;
    return h('div', { class: 'card', 'data-shift-staff': s.staff_id },
      h('div', { class: 'row wrap' }, h('div', { class: 'grow' }, h('strong', { text: s.name })), status,
        s.link_last_used_at ? h('small', { class: 'muted', text: T('last_used', { when: fmtDT(s.link_last_used_at) }) }) : null),
      h('div', { class: 'row wrap' },
        h('button', { class: 'btn sm', type: 'button', text: s.link_status === 'active' ? T('link_label') : T('create'), onclick: (e) => act(e.target, s.link_status === 'none' ? 'renew' : 'issue') }),
        s.link_status !== 'none' ? h('button', { class: 'btn sm', type: 'button', text: T('renew'), onclick: (e) => act(e.target, 'renew') }) : null,
        s.link_status === 'active' ? h('button', { class: 'btn sm danger', type: 'button', text: T('revoke'), onclick: (e) => act(e.target, 'revoke') }) : null),
      out, suggest);
  });
  return h('section', { class: 'stack shift-staff' }, h('h2', { text: T('title') }), h('p', { class: 'muted', text: T('intro') }),
    ...(cards.length ? cards : [h('p', { class: 'empty', text: T('empty') })]));
}
