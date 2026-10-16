// Jaetut komponentit: varauksen tiedot -dialogi (tilamuutokset, varauksen muutos, maksun kirjaus, maksulinkki-placeholder).
import { rpc } from '../sb.js';
import { h, dialog, toast, run, fmtDay, fmtTime, fmtDT, money, statusBadge, payBadge, field, badge, empty } from '../ui.js';

export function reservationDialog(r, { methods, onChange }) {
  const body = h('div', { class: 'stack' });
  const d = dialog(`Tilaus #${r.order_no}`, body);
  const act = (label, fn, cls = 'btn') => { const b = h('button', { type: 'button', class: cls, text: label, onclick: () => run(b, async () => { await fn(); toast('Tallennettu'); d.close(); onChange?.(); }) }); return b; };
  const status = (s, reason) => rpc('admin_set_reservation_status', { p_reservation_id: r.reservation_id, p_status: s, p_reason: reason ?? null });
  const method = h('select', { id: 'pm' }, methods.filter((m) => m.active && m.is_manual).map((m) => h('option', { value: m.code, text: m.label })));
  const amount = h('input', { type: 'number', step: '0.01', min: '0', value: r.total_gross, id: 'pa' });
  body.append(
    h('dl', { class: 'kv' },
      h('dt', { text: 'Asiakas' }), h('dd', {}, h('strong', { text: r.customer_name || '–' }), h('br'), r.customer_email || '', r.customer_phone ? ` · ${r.customer_phone}` : ''),
      h('dt', { text: 'Palvelu' }), h('dd', { text: r.product_name }),
      h('dt', { text: 'Aika' }), h('dd', { text: `${fmtDay(r.starts_at)}, ${fmtTime(r.starts_at)}–${fmtTime(r.ends_at)}` }),
      h('dt', { text: 'Henkilöt' }), h('dd', { text: `${r.persons} · ${r.mode === 'exclusive' ? 'yksityisvuoro' : 'yleinen vuoro'}` }),
      h('dt', { text: 'Tila' }), h('dd', {}, statusBadge(r.status), ' ', payBadge(r.payment_status), r.hold_expires_at ? ` (pito päättyy ${fmtTime(r.hold_expires_at)})` : ''),
      h('dt', { text: 'Summa' }), h('dd', {}, money(r.total_gross), r.annual_card_id ? [' ', badge('warn', 'Vuosikortti')] : null),
      h('dt', { text: 'Kanava' }), h('dd', { text: r.source_channel }),
      h('dt', { text: 'Luotu' }), h('dd', { text: fmtDT(r.created_at) }), r.notes ? [h('dt', { text: 'Huomio' }), h('dd', { text: r.notes })] : null),
    h('div', { class: 'row wrap' },
      ['pending', 'cancelled', 'expired'].includes(r.status) ? act('Vahvista', () => status('confirmed')) : null,
      r.status === 'confirmed' ? act('Merkitse saapuneeksi', () => status('completed')) : null,
      r.status === 'confirmed' ? act('Ei saapunut', () => status('no_show')) : null,
      ['pending', 'confirmed'].includes(r.status) ? h('button', { type: 'button', class: 'btn', onclick: () => { d.close(); changeDialog(r, onChange); } }, 'Muuta varausta') : null,
      ['pending', 'confirmed'].includes(r.status) ? act('Peru varaus', () => { if (!confirm('Perutaanko varaus?')) throw new Error('Peruutus keskeytetty'); return status('cancelled', 'henkilökunta'); }, 'btn danger') : null),
    r.payment_status !== 'paid' ? h('fieldset', { class: 'box' }, h('legend', { text: 'Kirjaa maksu (käteinen / kortti / lasku …)' }),
      h('div', { class: 'row wrap' }, field('Maksutapa', method), field('Summa €', amount),
        act('Kirjaa maksu', () => rpc('admin_record_payment', { p_order_id: r.order_id, p_method: method.value, p_amount: +amount.value }), 'btn primary'))) : null,
    h('div', { class: 'box' }, h('strong', { text: 'Verkkomaksulinkki (Visma Pay)' }),
      h('p', { class: 'muted', text: 'Ei vielä käytössä. Painike luo maksurivin ja näyttää, että linkki toteutetaan Visma Pay -integraation yhteydessä.' }),
      (() => { const out = h('p', { class: 'muted' }); const b = h('button', { type: 'button', class: 'btn', text: 'Luo maksulinkki', onclick: () => run(b, async () => { const j = await rpc('admin_create_payment_link', { p_order_id: r.order_id }); out.textContent = j.link_url || j.message; }) }); return h('div', {}, b, out); })()));
  return d;
}

// Varauksen muutos hallinnasta: toinen vapaa vuoro samalle tuotteelle ja/tai henkilömäärä (admin_change_booking).
// Samat lukot ja säännöt kuin uudessa varauksessa; ei 48 h rajoitusta (se koskee vain asiakasta). Hinta ei muutu maksetulla tilauksella ilman uutta kirjausta.
function changeDialog(r, onChange) {
  const day = (iso) => new Date(iso).toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
  const st = { date: day(r.starts_at), session: null };
  const sessionsBox = h('div', { class: 'stack' });
  const persons = h('input', { type: 'number', min: 1, value: r.persons, required: true });
  const dateIn = h('input', { type: 'date', value: st.date, onchange: (e) => { st.date = e.target.value; st.session = null; load(); } });
  async function load() {
    sessionsBox.replaceChildren(h('p', { class: 'muted', text: 'Ladataan…' }));
    const v = await rpc('admin_day_view', { p_date: st.date });
    const list = (v.sessions || []).filter((x) => x.product_id === r.product_id && x.status !== 'closed');
    sessionsBox.replaceChildren(list.length ? h('div', { class: 'slotpick', role: 'radiogroup', 'aria-label': 'Uusi vuoro' }, list.map((x) => {
      const same = x.starts_at === r.starts_at;
      const ok = x.status === 'available' || same;
      const b = h('button', { type: 'button', role: 'radio', 'aria-checked': 'false', class: `slotbtn ${x.status}`, disabled: !ok || null, onclick: () => { st.session = same ? null : x; sessionsBox.querySelectorAll('.slotbtn').forEach((y) => y.setAttribute('aria-checked', 'false')); b.setAttribute('aria-checked', 'true'); } },
        h('strong', { text: `${fmtTime(x.starts_at)}–${fmtTime(x.ends_at)}` }), h('small', { text: same ? 'nykyinen vuoro' : ok ? (x.mode === 'exclusive' ? 'vapaa' : `${x.remaining} vapaana`) : x.status === 'full' ? 'täynnä' : 'ei varattavissa' }));
      return b;
    })) : empty('Ei samantyyppisiä vuoroja tälle päivälle.'));
  }
  const f = h('form', { class: 'stack', onsubmit: (ev) => { ev.preventDefault(); run(f.querySelector('button[type=submit]'), async () => {
    const args = { p_reservation_id: r.reservation_id, p_persons: +persons.value !== r.persons ? +persons.value : null };
    if (st.session) { args.p_rule_id = st.session.rule_id; args.p_date = st.date; }
    if (args.p_persons == null && !st.session) throw new Error('Valitse uusi vuoro tai muuta henkilömäärää');
    await rpc('admin_change_booking', args);
    toast('Varaus muutettu'); d.close(); onChange?.();
  }); } },
    h('p', { class: 'muted', text: `Nykyinen: ${fmtDay(r.starts_at)}, ${fmtTime(r.starts_at)}–${fmtTime(r.ends_at)}, ${r.persons} hlö` }),
    h('div', { class: 'row wrap' }, field('Päivä', dateIn), field('Henkilömäärä', persons)), sessionsBox,
    h('button', { class: 'btn primary', type: 'submit', text: 'Tallenna muutos' }));
  const d = dialog(`Muuta varausta #${r.order_no}`, f);
  load();
}
