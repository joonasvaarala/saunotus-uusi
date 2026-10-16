// Jaetut komponentit: varauksen tiedot -dialogi (tilamuutokset, maksun kirjaus, maksulinkki-placeholder).
import { rpc } from '../sb.js';
import { h, dialog, toast, run, fmtDay, fmtTime, fmtDT, money, statusBadge, payBadge, field } from '../ui.js';

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
      h('dt', { text: 'Summa' }), h('dd', { text: money(r.total_gross) }),
      h('dt', { text: 'Kanava' }), h('dd', { text: r.source_channel }),
      h('dt', { text: 'Luotu' }), h('dd', { text: fmtDT(r.created_at) }), r.notes ? [h('dt', { text: 'Huomio' }), h('dd', { text: r.notes })] : null),
    h('div', { class: 'row wrap' },
      ['pending', 'cancelled', 'expired'].includes(r.status) ? act('Vahvista', () => status('confirmed')) : null,
      r.status === 'confirmed' ? act('Merkitse saapuneeksi', () => status('completed')) : null,
      r.status === 'confirmed' ? act('Ei saapunut', () => status('no_show')) : null,
      ['pending', 'confirmed'].includes(r.status) ? act('Peru varaus', () => { if (!confirm('Perutaanko varaus?')) throw new Error('Peruutus keskeytetty'); return status('cancelled', 'henkilökunta'); }, 'btn danger') : null),
    r.payment_status !== 'paid' ? h('fieldset', { class: 'box' }, h('legend', { text: 'Kirjaa maksu (käteinen / kortti / lasku …)' }),
      h('div', { class: 'row wrap' }, field('Maksutapa', method), field('Summa €', amount),
        act('Kirjaa maksu', () => rpc('admin_record_payment', { p_order_id: r.order_id, p_method: method.value, p_amount: +amount.value }), 'btn primary'))) : null,
    h('div', { class: 'box' }, h('strong', { text: 'Verkkomaksulinkki (Visma Pay)' }),
      h('p', { class: 'muted', text: 'Ei vielä käytössä. Painike luo maksurivin ja näyttää, että linkki toteutetaan Visma Pay -integraation yhteydessä.' }),
      (() => { const out = h('p', { class: 'muted' }); const b = h('button', { type: 'button', class: 'btn', text: 'Luo maksulinkki', onclick: () => run(b, async () => { const j = await rpc('admin_create_payment_link', { p_order_id: r.order_id }); out.textContent = j.link_url || j.message; }) }); return h('div', {}, b, out); })()));
  return d;
}
