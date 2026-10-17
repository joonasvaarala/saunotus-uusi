// Saunottaja puuttuu (migraatio 22): "Ei saunottajaa" -merkki, luontivastauksen varoitus ja poikkeuksen myöntö (admin_grant_therapist_exception).
// Varaus syntyy, vaikka vain saunottajatarkistus epäonnistuu; merkintä jää avoimeksi kunnes saunottaja liitetään tai ylläpitäjä myöntää poikkeuksen
// (oikeus bookings.override: admin, manager; perustelu pakollinen, vähintään 3 merkkiä).
import { rpc } from '../sb.js';
import { h, dialog, toast, run, errMsg, field, badge } from '../ui.js';

export const MISSING_TEXT = 'Varaus tehty, mutta saunottaja puuttuu työvuorosta';
// Avoin = merkitty puuttuvaksi eikä poikkeusta ole myönnetty. Päivänäkymä antaa therapist_missing_open; vanhemmat rivit voivat antaa vain therapist_missing.
export const missingOpen = (r) => (r?.therapist_missing_open !== undefined ? !!r.therapist_missing_open : !!r?.therapist_missing && !r?.therapist_exception_at);
export const missingBadge = (r) => (missingOpen(r) ? badge('warn tmiss', 'Ei saunottajaa') : r?.therapist_missing && r?.therapist_exception_at ? badge('muted tmiss-ok', 'Saunottaja sovittu') : null);

// Poikkeuksen myöntö: perustelu pakollinen (≥ 3 merkkiä; palvelin tarkistaa myös, note_required). onDone() kutsutaan onnistumisen jälkeen.
export function exceptionDialog(r, { onDone } = {}) {
  const note = h('textarea', { name: 'note', rows: 3, maxlength: 300, 'aria-required': 'true', placeholder: 'Esim. saunottaja sovittu erikseen puhelimessa' });
  const err = h('p', { class: 'err', role: 'alert', hidden: true });
  const go = h('button', { type: 'submit', class: 'btn primary', 'data-testid': 'grant-submit', text: 'Myönnä poikkeus' });
  const f = h('form', { class: 'stack', novalidate: true, 'data-testid': 'grant-form', onsubmit: (ev) => { ev.preventDefault(); run(go, async () => {
    err.hidden = true;
    if (note.value.trim().length < 3) { err.textContent = 'Anna perustelu (vähintään 3 merkkiä).'; err.hidden = false; note.focus(); return; }
    let v;
    try { v = await rpc('admin_grant_therapist_exception', { p_reservation_id: r.reservation_id, p_note: note.value.trim() }); } catch (e) { err.textContent = errMsg(e); err.hidden = false; return; }
    toast(v?.already ? 'Poikkeus oli jo myönnetty' : 'Poikkeus myönnetty – varaus ei enää näy Tarkista-listalla');
    d.close(); onDone?.();
  }); } },
    h('p', { text: `Varaus #${r.order_no ?? r.reservation_id}${r.product_name ? ` · ${r.product_name}` : ''} on tehty ilman saunottajaa. Poikkeus kirjataan varaukseen (myöntäjä, aika ja perustelu) eikä varaus enää näy Tarkista-listalla.` }),
    field('Perustelu (pakollinen)', note), err,
    h('div', { class: 'row wrap' }, go, h('button', { type: 'button', class: 'btn ghost', text: 'Peruuta', onclick: () => d.close() })));
  const d = dialog('Myönnä poikkeus: ei saunottajaa', f);
  note.focus();
  return d;
}
// Painike poikkeuksen myöntöön (vain oikeuden omaavalle; muuten null)
export const grantButton = (r, { ctx, onDone, small = true } = {}) => (ctx?.can?.('bookings.override') && missingOpen(r)
  ? h('button', { type: 'button', class: `btn${small ? ' sm' : ''}`, 'data-testid': 'grant-btn', text: 'Myönnä poikkeus', onclick: () => exceptionDialog(r, { onDone }) }) : null);

// Luontivastauksen varoitus: warning = 'therapist_missing' (tai therapist_missing = true) → selkeä banneri + pikalinkki Tarkista-listalle
export const hasWarning = (res) => res?.warning === 'therapist_missing' || res?.therapist_missing === true;
export function warningBox(res, { ctx, onDone } = {}) {
  if (!hasWarning(res)) return null;
  const r = { reservation_id: res.reservation_id, order_no: res.order_no, product_name: res.product_name, therapist_missing: true };
  return h('div', { class: 'warn-box', role: 'alert', 'data-testid': 'therapist-warning' },
    h('strong', { text: MISSING_TEXT }),
    h('p', { class: 'muted', text: 'Varaus on tallennettu. Lisää saunottaja työvuoroihin tai myönnä poikkeus; avoimet näkyvät Tarkista-listalla.' }),
    h('div', { class: 'row wrap' }, h('a', { class: 'btn ghost', href: '#/tarkista', text: 'Avaa Tarkista' }), grantButton(r, { ctx, onDone, small: false })));
}
