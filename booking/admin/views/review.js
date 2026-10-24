// Tarkista-lista (admin_review_list): ei saunottajaa (migraatio 22; poikkeuksen myöntö oikeudella bookings.override),
// saunottajakonfliktit, sulkukonfliktit (kuittaus booking_73: blocks.manage tai bookings.override, ei muuta saatavuutta),
// kuitatut sulkukonfliktit, ylitykset ja orvot lisäpalvelut.
// booking_173: lunastamattomat kumppanilahjakortit (admin_unredeemed_voucher_claims; views/voucher-redeem.js).
// Tyhjä lista on hyvä uutinen; rivistä pääsee päivänäkymään tai varauksen tietoihin.
import { rpc } from '../sb.js';
import { h, fmtDay, fmtTime, errMsg, empty, badge, sourceBadge, toast, run } from '../ui.js';
import { resName, SKILL_FI } from './legs.js';
import { grantButton } from './therapist.js';
import { loadReviewTexts, reviewText as rt } from '../review-texts.js';
import { unredeemedSection } from './voucher-redeem.js';
import { canAckBlockConflict, conflictReason, nextAckStep, nextUnackStep, ackArgs, unackArgs, reviewAttentionCount } from '../review-logic.js';

const day = (iso) => new Date(iso).toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
const when = (iso) => `${fmtDay(iso)} ${fmtTime(iso)}`;

export async function render({ ctx, refs, reload }) {
  await loadReviewTexts(rpc);
  let v;
  try { v = await rpc('admin_review_list'); } catch (e) {
    return [h('h1', { text: 'Tarkista' }), h('p', { class: 'err', role: 'alert', text: `Tarkista-listaa ei saatu haettua: ${errMsg(e)}` })];
  }
  v = v && !Array.isArray(v) ? v : {};
  const link = (id, iso, label) => h('a', { class: 'rv-link', href: `#/?d=${day(iso)}` }, h('strong', { text: `varaus #${id}` }), ` · ${label || when(iso)}`);
  const days = (n) => (n === 0 ? 'tänään' : n === 1 ? 'huomenna' : n > 1 ? `${n} pv päästä` : n < 0 ? 'käynnissä/mennyt' : '');
  const resourceBit = (x) => (x.resource_id ? ` · ${resName(refs, refs?.resources?.find((r) => r.id === x.resource_id)?.code)}` : '');
  const reasonBit = (x) => {
    const reason = conflictReason(x);
    return reason ? h('span', { class: 'review-block-reason', 'data-testid': 'block-reason', text: rt('ui.admin.review.block_reason', { reason }) }) : null;
  };
  const ackForm = (x) => {
    if (!canAckBlockConflict(ctx?.can)) return null;
    const note = h('input', { type: 'text', maxlength: '300', value: rt('ui.admin.review.ack_note_default'), 'data-testid': 'ack-note', 'aria-label': rt('ui.admin.review.ack_note_label') });
    const label = h('input', { type: 'text', maxlength: '200', placeholder: rt('ui.admin.review.ack_label_placeholder'), 'data-testid': 'ack-label', 'aria-label': rt('ui.admin.review.ack_label_label') });
    const err = h('p', { class: 'err', role: 'alert', hidden: true, 'data-testid': 'ack-err' });
    const confirm = h('p', { class: 'muted', hidden: true, 'data-testid': 'ack-confirm', text: rt('ui.admin.review.ack_confirm') });
    const btn = h('button', { type: 'button', class: 'btn', 'data-testid': 'ack-btn', text: rt('ui.admin.review.ack_button') });
    const cancel = h('button', { type: 'button', class: 'btn ghost', hidden: true, 'data-testid': 'ack-cancel', text: rt('ui.admin.review.ack_cancel') });
    let phase = 'edit';
    const sync = () => {
      const on = phase === 'confirm';
      btn.textContent = on ? rt('ui.admin.review.ack_confirm_button') : rt('ui.admin.review.ack_button');
      btn.dataset.phase = phase;
      confirm.hidden = !on;
      cancel.hidden = !on;
    };
    note.addEventListener('input', () => { phase = 'edit'; err.hidden = true; sync(); });
    cancel.addEventListener('click', () => { phase = 'edit'; err.hidden = true; sync(); });
    btn.addEventListener('click', () => {
      const step = nextAckStep(phase, note.value);
      if (step.error) {
        err.textContent = rt('ui.admin.review.ack_note_required');
        err.hidden = false;
        phase = 'edit';
        sync();
        note.focus();
        return;
      }
      if (!step.submit) { phase = 'confirm'; err.hidden = true; sync(); btn.focus(); return; }
      run(btn, async () => {
        const out = await rpc('admin_ack_block_conflict', ackArgs(x, note.value, label.value));
        toast(out?.already ? rt('ui.admin.review.ack_already') : rt('ui.admin.review.ack_done'));
        reload();
      });
    });
    return h('div', { class: 'review-ack' },
      h('div', { class: 'row wrap' }, h('label', { class: 'fld' }, h('span', { text: rt('ui.admin.review.ack_note_label') }), note), h('label', { class: 'fld' }, h('span', { text: rt('ui.admin.review.ack_label_label') }), label)),
      confirm, err, h('div', { class: 'row wrap' }, btn, cancel));
  };
  const unackForm = (x) => {
    if (!canAckBlockConflict(ctx?.can)) return null;
    const confirm = h('p', { class: 'muted', hidden: true, 'data-testid': 'unack-confirm', text: rt('ui.admin.review.unack_confirm') });
    const btn = h('button', { type: 'button', class: 'btn', 'data-testid': 'unack-btn', text: rt('ui.admin.review.unack_button') });
    const cancel = h('button', { type: 'button', class: 'btn ghost', hidden: true, 'data-testid': 'unack-cancel', text: rt('ui.admin.review.ack_cancel') });
    let phase = 'edit';
    const sync = () => {
      const on = phase === 'confirm';
      btn.textContent = on ? rt('ui.admin.review.unack_confirm_button') : rt('ui.admin.review.unack_button');
      btn.dataset.phase = phase;
      confirm.hidden = !on;
      cancel.hidden = !on;
    };
    cancel.addEventListener('click', () => { phase = 'edit'; sync(); });
    btn.addEventListener('click', () => {
      const step = nextUnackStep(phase);
      if (!step.submit) { phase = 'confirm'; sync(); btn.focus(); return; }
      run(btn, async () => {
        await rpc('admin_unack_block_conflict', unackArgs(x));
        toast(rt('ui.admin.review.unack_done'));
        reload();
      });
    });
    return h('div', { class: 'review-ack' }, confirm, h('div', { class: 'row wrap' }, btn, cancel));
  };
  const ackedMeta = (x) => h('small', { text: rt('ui.admin.review.acked_meta', { by: x.acked_by_label ? ` (${x.acked_by_label})` : '', reason: x.ack_reason || '' }) });
  const SECTIONS = [
    ['missing_therapist', 'Ei saunottajaa', 'Varaus on tehty, mutta työvuoroissa ei ole vapaata saunottajaa. Lisää saunottaja työvuoroon (merkintä purkautuu tuonnissa) tai myönnä poikkeus perustelulla.',
      (x) => [link(x.reservation_id, x.starts_at), ` · ${x.product_name || ''}${x.persons ? ` · ${x.persons} hlö` : ''}${x.order_no ? ` · tilaus #${x.order_no}` : ''}`, sourceBadge(x) ? [' ', sourceBadge(x)] : null,
        x.days_to_start != null ? [' ', badge(x.days_to_start <= 2 ? 'warn' : 'muted', days(x.days_to_start))] : null, ' ',
        grantButton({ ...x, therapist_missing: true }, { ctx, onDone: () => reload() })]],
    ['therapist_conflicts', 'Saunottajakonfliktit', 'Varaus tarvitsee saunottajan, mutta vuoroja tai taitoa ei ole riittävästi (esim. vuoro muuttui varauksen jälkeen).',
      (x) => [link(x.reservation_id, x.starts_at), x.skill ? ` · taito: ${SKILL_FI[x.skill] || x.skill}` : '']],
    ['block_conflicts', 'Sulkukonfliktit', rt('ui.admin.review.block_hint'),
      (x) => [link(x.reservation_id, x.starts_at), resourceBit(x), ' ', reasonBit(x)], { extra: ackForm }],
    ['acked_block_conflicts', rt('ui.admin.review.acked_title'), rt('ui.admin.review.acked_hint'),
      (x) => [link(x.reservation_id, x.starts_at), resourceBit(x), ' ', reasonBit(x), ' ', ackedMeta(x)],
      { extra: unackForm, empty: rt('ui.admin.review.acked_empty'), acked: true, badge: (n) => (n ? 'muted' : 'ok') }],
    ['overrides', 'Ylitykset', 'Varaukset, jotka on tehty ohittamalla sulku- tai saunottajatarkistus (oikeus bookings.override).',
      (x) => [link(x.reservation_id, x.starts_at), h('br'), h('small', { text: `Syy: ${x.reason || '–'}` })]],
    ['orphan_addons', 'Orvot lisäpalvelut', 'Lisäpalvelun vanhempi (jälkilöyly / yksityisvuoro) on peruttu tai puuttuu.',
      (x) => [link(x.reservation_id, x.starts_at)]],
  ];
  const total = reviewAttentionCount(v);
  let vouchers = null;
  try { vouchers = await unredeemedSection({ rpc }); } catch { vouchers = null; }   // rajapinta puuttuu (vanha tietokanta) → osio jää pois
  const sec = ([k, title, hint, row, opt = {}]) => {
    const rows = Array.isArray(v[k]) ? v[k] : [];
    const kind = opt.badge ? opt.badge(rows.length) : (rows.length ? 'warn' : 'ok');
    return h('section', { class: `card review-sec${rows.length ? ' has' : ''}${opt.acked ? ' acked' : ''}`, 'data-testid': `review-${k}`, 'data-count': String(rows.length) },
      h('h2', {}, title, ' ', badge(kind, String(rows.length))), h('p', { class: 'muted', text: hint }),
      rows.length ? h('ul', { class: 'reslist' }, rows.map((x) => h('li', { class: 'resrow' }, h('span', {}, ...[].concat(row(x))), opt.extra ? opt.extra(x) : null))) : empty(opt.empty || 'Ei tarkistettavaa.'));
  };
  return [h('h1', { text: 'Tarkista' }),
    h('p', { class: 'muted', role: 'status', 'data-testid': 'review-total', text: total ? `${total} tarkistettavaa. Lista päivittyy tietokannasta joka kerta kun avaat sivun.` : 'Ei tarkistettavaa – kaikki tulevat varaukset ovat kunnossa.' }),
    h('button', { type: 'button', class: 'btn ghost sm', text: 'Päivitä', onclick: () => reload() }),
    vouchers,   // booking_173: lunastamattomat kumppanilahjakortit (Kokemuskauppa, Offerilla, Elämyslahjat)
    ...SECTIONS.map(sec)];
}
