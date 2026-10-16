// Jaetut komponentit: varauksen tiedot -dialogi (tilamuutokset, varauksen muutos, maksun kirjaus, maksulinkki-placeholder).
import { rpc } from '../sb.js';
import { addonPicker } from './addons.js';
import { icon } from '../icons.js';
import { h, dialog, toast, run, fmtDay, fmtTime, fmtDT, money, statusBadge, payBadge, sourceBadge, isJohku, field, badge, empty, errMsg } from '../ui.js';
import { legsList, resName, resourceBadges, hasLegs } from './legs.js';

export function reservationDialog(r, { methods, onChange, refs, can = () => true }) {
  const body = h('div', { class: 'stack' });
  const d = dialog(`Tilaus #${r.order_no}`, body);
  const act = (label, fn, cls = 'btn') => { const b = h('button', { type: 'button', class: cls, text: label, onclick: () => run(b, async () => { await fn(); toast('Tallennettu'); d.close(); onChange?.(); }) }); return b; };
  const status = (s, reason) => rpc('admin_set_reservation_status', { p_reservation_id: r.reservation_id, p_status: s, p_reason: reason ?? null });
  const method = h('select', { id: 'pm' }, methods.filter((m) => m.active && m.is_manual).map((m) => h('option', { value: m.code, text: m.label })));
  const amount = h('input', { type: 'number', step: '0.01', min: '0', value: r.total_gross, id: 'pa' });
  const orderBox = h('div', { class: 'stack order-extra' });
  const resBox = h('div', { class: 'resbox' });   // resurssit: tila, legit, ylitys, siirto Rauni ↔ Lovi (migraatio 17)
  body.append(
    h('dl', { class: 'kv' },
      isJohku(r) ? [h('dt', { text: 'Lähde' }), h('dd', {}, sourceBadge(r), ' tuotu Johku-järjestelmästä'), h('dt', { text: 'Johku-tunnus' }), h('dd', { class: 'ext-id', text: r.external_id || '–' })] : null,
      h('dt', { text: 'Asiakas' }), h('dd', {}, h('strong', { text: r.customer_name || '–' }), h('br'), r.customer_email || '', r.customer_phone ? ` · ${r.customer_phone}` : ''),
      h('dt', { text: 'Palvelu' }), h('dd', { text: r.product_name }),
      h('dt', { text: 'Aika' }), h('dd', { text: `${fmtDay(r.starts_at)}, ${fmtTime(r.starts_at)}–${fmtTime(r.ends_at)}` }),
      h('dt', { text: 'Henkilöt' }), h('dd', { text: `${r.persons} · ${r.mode === 'exclusive' ? 'yksityisvuoro' : 'yleinen vuoro'}` }),
      h('dt', { text: 'Tila' }), h('dd', {}, statusBadge(r.status), ' ', payBadge(r.payment_status), r.hold_expires_at ? ` (pito päättyy ${fmtTime(r.hold_expires_at)})` : ''),
      h('dt', { text: 'Summa' }), h('dd', {}, money(r.total_gross), r.annual_card_id ? [' ', badge('warn', 'Vuosikortti')] : null),
      h('dt', { text: 'Kanava' }), h('dd', { text: r.source_channel }),
      h('dt', { text: 'Luotu' }), h('dd', { text: fmtDT(r.created_at) }), r.notes ? [h('dt', { text: 'Huomio' }), h('dd', { text: r.notes })] : null),
    resBox,
    orderBox,
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
  // Resurssit (migraatio 17): tila, elinkaari, ylitys, claim-ikkuna, vanhempi varaus, legit. Päivänäkymän RPC antaa täydet tiedot (ylitys, kiintiö, claim, leg_id);
  // varauslistan rivillä ne puuttuvat, joten ne haetaan kerran päivänäkymästä. Kaikki kentät valinnaisia.
  const drawResources = () => {
    const x = r;
    if (!x.space_code && !hasLegs(x) && !x.lifecycle) { resBox.replaceChildren(); return; }
    const other = x.space_code === 'rauni' ? 'lovi' : x.space_code === 'lovi' ? 'rauni' : null;
    const claim = (x.claim_offset_min > 0 || x.claim_minutes) ? `alkaa +${x.claim_offset_min || 0} min${x.claim_minutes ? `, kesto ${x.claim_minutes} min` : ''}` : null;
    const kids = [h('h3', { text: 'Resurssit' }), h('dl', { class: 'kv' },
      x.space_code ? [h('dt', { text: 'Tila' }), h('dd', {}, h('strong', { text: resName(refs, x.space_code) }), ' ', resourceBadges(x))] : null,
      x.lifecycle ? [h('dt', { text: 'Tuote' }), h('dd', { text: x.lifecycle === 'old' ? 'Vanha tuote (vanha varaus)' : 'Nykyinen tuote' })] : null,
      x.override_reason ? [h('dt', { text: 'Ylitys' }), h('dd', { text: x.override_reason })] : null,
      x.quota_exempt ? [h('dt', { text: 'Kiintiö' }), h('dd', { text: 'Kiintiövapaa (esim. lahjakortti): ei kuluta myyntikiintiötä' })] : null,
      claim ? [h('dt', { text: 'Tilan käyttö' }), h('dd', { text: claim })] : null,
      x.parent_reservation_id ? [h('dt', { text: 'Vanhempi varaus' }), h('dd', { text: `varaus #${x.parent_reservation_id}` })] : null),
      legsList(x.legs, refs)];
    if (other === 'lovi' && x.persons > 1 && x.status === 'confirmed') kids.push(h('p', { class: 'muted', text: 'Loviin mahtuu vain 1 henkilö, joten siirtoa Raunista Loviin ei tarjota.' }));
    else if (other && x.status === 'confirmed' && can('bookings.manage')) {
      const reason = h('input', { name: 'reason', maxlength: 200, placeholder: 'Syy (valinnainen)', 'aria-label': 'Siirron syy' });
      const err = h('p', { class: 'err', role: 'alert', hidden: true });
      const go = h('button', { type: 'button', class: 'btn sm', text: `Siirrä tilaan: ${resName(refs, other)}` });
      go.addEventListener('click', () => run(go, async () => {
        err.hidden = true;
        try { await rpc('admin_move_reservation_space', { p_reservation_id: r.reservation_id, p_space_code: other, p_reason: reason.value.trim() || null }); } catch (e) { err.textContent = errMsg(e); err.hidden = false; return; }
        toast(`Varaus siirretty tilaan ${resName(refs, other)}`); d.close(); onChange?.();
      }));
      kids.push(h('div', { class: 'moverow' }, h('div', { class: 'row wrap' }, field('Siirto Rauni ↔ Lovi', reason), go), err,
        h('p', { class: 'muted', text: 'Siirto onnistuu vain, jos tuotteella on sääntö kohdetilaan (Lovi: 1 hlö) eikä tila ole varattu tai suljettu.' })));
    }
    resBox.replaceChildren(...kids);
  };
  drawResources();
  if (r.quota_exempt === undefined && r.reservation_id && (r.space_code || hasLegs(r))) {   // täydennä päivänäkymästä (ylitys, kiintiö, claim, leg_id)
    const day = new Date(r.starts_at).toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
    rpc('admin_day_view', { p_date: day }).then((v) => { const m = (v?.reservations || []).find((y) => y.reservation_id === r.reservation_id); if (m) { Object.assign(r, { quota_exempt: m.quota_exempt, override_reason: m.override_reason, claim_offset_min: m.claim_offset_min, claim_minutes: m.claim_minutes, legs: m.legs?.length ? m.legs : r.legs }); drawResources(); } }).catch(() => {});
  }
  // Tilauksen lisätiedot: laskutustiedot (yritysasiakas), lisäpalvelut (+ muokkaus)
  const drawOrder = async () => {
    let o; try { o = await rpc('admin_get_order', { p_order_id: r.order_id }); } catch { return; }
    const res = (o.reservations || []).find((x) => x.id === r.reservation_id) || {};
    const ad = res.addons || [];
    const b = o.billing;
    const kids = [];
    if (o.customer_kind === 'company' && b) {
      kids.push(h('div', { class: 'box' }, h('h3', {}, 'Yritysasiakas – laskutustiedot'), h('dl', { class: 'kv' },
        h('dt', { text: 'Yritys' }), h('dd', { text: b.company || '–' }), h('dt', { text: 'Y-tunnus' }), h('dd', { text: b.business_id || '–' }),
        h('dt', { text: 'Osoite' }), h('dd', { text: [b.street, [b.zip, b.city].filter(Boolean).join(' ')].filter(Boolean).join(', ') || '–' }),
        b.einvoice_address ? [h('dt', { text: 'Verkkolasku' }), h('dd', { text: `${b.einvoice_address} / ${b.einvoice_operator || '–'}` })] : null,
        o.invoice_reference ? [h('dt', { text: 'Viite' }), h('dd', { text: o.invoice_reference })] : null,
        h('dt', { text: 'Yhteyshenkilö' }), h('dd', { text: [b.contact_name, b.contact_email, b.contact_phone].filter(Boolean).join(' · ') || '–' }))));
    }
    const editable = ['pending', 'confirmed'].includes(r.status);
    kids.push(h('div', { class: 'box addons-box' }, h('h3', {}, icon('leaf', 20), ' Lisäpalvelut'),
      ad.length ? h('ul', { class: 'reslist' }, ad.map((a) => h('li', { class: 'resrow' }, h('span', { text: `${a.quantity} × ${a.name}` }), h('span', { class: 'meta', text: money(a.line_total) })))) : h('p', { class: 'muted', text: 'Ei lisäpalveluita.' }),
      editable ? h('button', { type: 'button', class: 'btn sm', text: 'Muokkaa lisäpalveluita', onclick: () => editAddons(ad) }) : null));
    orderBox.replaceChildren(...kids);
  };
  const editAddons = async (current) => {
    const all = await rpc('admin_list_addons');
    const picker = addonPicker(all, { getPersons: () => r.persons, getMode: () => r.mode });
    picker.set(current);
    const f = h('form', { class: 'stack', onsubmit: (ev) => { ev.preventDefault(); run(f.querySelector('button[type=submit]'), async () => {
      await rpc('admin_set_reservation_addons', { p_reservation_id: r.reservation_id, p_addons: picker.value() });
      toast('Lisäpalvelut tallennettu'); dd.close(); d.close(); onChange?.();
    }); } }, h('p', { class: 'muted', text: `Enimmäismäärä = henkilömäärä (${r.persons}) × lisäpalvelun enimmäismäärä / hlö. Tilauksen summa päivittyy; odottava maksu päivitetään.` }), picker.node, h('button', { class: 'btn primary', type: 'submit', text: 'Tallenna lisäpalvelut' }));
    const dd = dialog(`Lisäpalvelut – tilaus #${r.order_no}`, f);
  };
  drawOrder();
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
