// Hyvitys ↔ peruutus (booking_136, booking_280 lahjakortti/kumppanikoodi, booking_281 peruutusviesti): kyllä/ei-valinnat ja varauksen peruutusdialogi.
// * yesNo: kaksi radiopainiketta, oletus aina "ei" (turvallinen: ei peruutusta / ei rahaliikettä).
// * cancelReservationDialog: varauksen peruutus. payments.refund-oikeudella dialogi hakee varauksen osuuden maksuista
//   (admin_reservation_refund_preview: varauksen rivi + lisäpalvelut, aiemmat hyvitykset vähennetty) ja kysyy, hyvitetäänkö.
//   Peruutus + hyvitys = admin_cancel_reservation (yksi transaktio, palvelin tarkistaa oikeudet). Verkkomaksun hyvitys
//   (status requested) käsitellään heti Edge-funktiolla käyttäjän JWT:llä, kuten Talous-näkymässä.
import { h, dialog, toast, money } from '../ui.js';
import { t } from '../talous-i18n.js';
import { friendly } from './talous-ui.js';
import { rcText } from '../refund-cancel-texts.js';
import { alt } from '../addon-lock-texts.js';
import { isMissingRpc } from '../talous-api.js';

let seq = 0;
export function yesNo({ name, legend, no, yes, hint = null, testid, disabled = false }) {
  const id = `rc${++seq}`;
  const opt = (value, label, checked) => h('label', { class: 'check big rc-opt', 'data-testid': `${testid}-${value}` },
    h('input', { type: 'radio', name, value, checked: checked || null, disabled: disabled && value === 'yes' ? true : null }), h('span', {}, h('strong', { text: label })));
  const node = h('fieldset', { class: 'rc-choice', 'data-testid': testid, 'aria-describedby': hint ? `${id}-hint` : null },
    h('legend', { text: legend }), hint ? h('p', { class: 'muted rc-hint', id: `${id}-hint`, text: hint }) : null,
    opt('no', no, true), opt('yes', yes, false));
  return { node, value: () => node.querySelector('input:checked')?.value === 'yes' };
}

/**
 * booking_280/281: pakollinen kyllä/ei-valinta ilman oletusta (lahjakorttikoodi, peruutusviesti). value() = true | false | null (ei valittu).
 * disabledYes: "Kyllä" ei valittavissa (esim. vanhentunut lahjakortti).
 */
export function requiredYesNo({ name, legend, no, yes, hint = null, testid, disabledYes = false }) {
  const id = `rc${++seq}`;
  const opt = (value, label) => h('label', { class: 'check big rc-opt', 'data-testid': `${testid}-${value}` },
    h('input', { type: 'radio', name, value, required: true, disabled: disabledYes && value === 'yes' ? true : null }), h('span', {}, h('strong', { text: label })));
  const node = h('fieldset', { class: 'rc-choice rc-required', 'data-testid': testid, 'aria-describedby': hint ? `${id}-hint` : null },
    h('legend', { text: legend }), hint ? h('p', { class: 'muted rc-hint', id: `${id}-hint`, text: hint }) : null,
    opt('yes', yes), opt('no', no));
  const value = () => { const v = node.querySelector('input:checked')?.value; return v === 'yes' ? true : v === 'no' ? false : null; };
  node.addEventListener('change', () => node.classList.remove('rc-missing'));
  return { node, value, missing: () => { const m = value() === null; node.classList.toggle('rc-missing', m); return m; } };
}

const MP_KINDS = { done: 'ok', failed: 'err', retry_later: 'warn', unverified: 'warn', db_error: 'warn', none: 'warn', off: 'warn', forbidden: 'err', error: 'warn' };
const VP_KINDS = { ...MP_KINDS, awaiting_customer: 'warn', not_settled: 'err', not_configured: 'warn' };
const MO_KINDS = { done: 'ok', pending: 'warn', awaiting_settlement: 'warn', failed: 'err', retry_later: 'warn', db_error: 'warn', not_configured: 'warn', none: 'warn', off: 'warn', forbidden: 'err', error: 'warn' };
/** Verkkomaksun hyvitysrivit (status requested) käsitellään heti: api = createTalousApi(...) (mobilepayRefund / vismapayRefund / montonioRefund). */
export async function processOnlineRefunds(api, refunds = []) {
  for (const x of refunds) {
    if (x?.status !== 'requested' || !api) continue;
    if (x.provider === 'mobilepay') { const m = await api.mobilepayRefund(x.refund_id); toast(t(MP_KINDS[m.result] ? `refund.mp.${m.result}` : 'refund.mp.error'), MP_KINDS[m.result] || 'warn'); }
    if (x.provider === 'visma_pay') { const m = await api.vismapayRefund(x.refund_id); toast(t(VP_KINDS[m.result] ? `refund.vp.${m.result}` : 'refund.vp.error'), VP_KINDS[m.result] || 'warn'); }
    if (x.provider === 'montonio') { const m = await api.montonioRefund(x.refund_id); toast(t(MO_KINDS[m.result] ? `refund.mo.${m.result}` : 'refund.mo.error'), MO_KINDS[m.result] || 'warn'); }
  }
}

/**
 * Varauksen peruutusdialogi. rpc = sb.js:n rpc (kokeilutilassa mock). canRefund = payments.refund (vain admin/manager);
 * ilman oikeutta hyvitysesikatselua ei edes haeta (palvelin kieltäisi). onDone(res) kutsutaan onnistuneen peruutuksen jälkeen.
 * booking_280: admin_reservation_cancel_options kertoo lahjakortti- ja kumppanikoodiosuudet. Lahjakortilla maksettu varaus vaatii
 *   valinnan (koodi voimaan / arvo menetetään), kumppanin maksua ei hyvitetä ja lunastettu tilaus jää voimaan.
 * booking_281: kysytään, lähetetäänkö asiakkaalle yksi peruutusviesti (peruutus + hyvityskuitti). Ei oletusta.
 * Kanta ilman booking_280:tä (valinnat-RPC puuttuu): dialogi toimii kuten ennen, uusia parametreja ei lähetetä.
 */
export async function cancelReservationDialog(r, { rpc, canRefund = false, online = null, onDone, invoiceLocked = false }) {
  const body = h('div', { class: 'stack rc-body', 'data-testid': 'rc-cancel' });
  const d = dialog(rcText('ui.admin.refund_cancel.cancel_title'), body);
  d.classList.add('rc-dlg');
  let plan = null, choice = null, opts = null, gcChoice = null, notifyChoice = null;
  const reason = h('input', { name: 'refund_reason', maxlength: 200, value: '', 'data-testid': 'rc-refund-reason' });
  const reasonFld = h('label', { class: 'fld', hidden: true }, h('span', { text: rcText('ui.admin.refund_cancel.refund_reason') }), reason);
  const notes = [];
  try { opts = await rpc('admin_reservation_cancel_options', { p_reservation_id: r.reservation_id }); } catch (e) { opts = null; if (!isMissingRpc(e)) notes.push(rcText('ui.admin.refund_cancel.options_unavailable')); }
  if (opts && opts.ok === false) opts = null;
  if (canRefund) {
    try { plan = await rpc('admin_reservation_refund_preview', { p_reservation_id: r.reservation_id }); } catch { plan = null; notes.push(rcText('ui.admin.refund_cancel.refund_unavailable')); }
  }
  const r2 = (x) => Math.round((+x || 0) * 100) / 100;
  // Rahahyvitys = varauksen osuus ilman lahjakortti- ja kumppanikoodiosuutta (booking_280: niitä ei hyvitetä rahana).
  const total = opts && opts.money_share !== null && opts.money_share !== undefined ? r2(opts.money_share) : r2(plan?.total);
  const offline = (plan?.payments || []).some((p) => p.online_off && !p.gift_card);
  if (plan && +plan.unallocated > 0) notes.push(rcText('ui.admin.refund_cancel.refund_unallocated'));
  if (invoiceLocked) notes.push(alt('cancel_invoiced_hint'));
  else if (plan && total > 0) {
    if (offline) notes.push(rcText('ui.admin.refund_cancel.refund_online_off'));
    choice = yesNo({ name: 'refund', testid: 'rc-refund', legend: rcText('ui.admin.refund_cancel.refund_question'),
      hint: `${rcText('ui.admin.refund_cancel.refund_share', { amount: money(total) })}. ${rcText('ui.admin.refund_cancel.refund_share_note')}`,
      no: rcText('ui.admin.refund_cancel.refund_no'), yes: rcText('ui.admin.refund_cancel.refund_yes', { amount: money(total) }), disabled: offline });
    choice.node.addEventListener('change', () => { reasonFld.hidden = !choice.value(); });
  } else if (plan && !(opts && (+opts.gift_card_total > 0 || +opts.partner_share > 0))) notes.push(rcText('ui.admin.refund_cancel.refund_none'));

  // ---- lahjakortti (booking_280) ----
  if (opts?.gift_card_choice_required && !invoiceLocked) {
    const gcs = opts.gift_cards || [];
    const expired = gcs.some((g) => !g.keep_allowed);
    const hint = gcs.map((g) => rcText('ui.admin.refund_cancel.gift_card_share', { amount: money(g.amount), code: g.code_last4 || '', date: g.valid_to ? fmtDate(g.valid_to) : '–' })).join(' ');
    gcChoice = requiredYesNo({ name: 'gift_card_keep', testid: 'rc-gift-card', legend: rcText('ui.admin.refund_cancel.gift_card_question'),
      hint: expired ? `${hint} ${rcText('ui.admin.refund_cancel.gift_card_expired')}` : hint,
      yes: rcText('ui.admin.refund_cancel.gift_card_keep', { amount: money(opts.gift_card_total) }), no: rcText('ui.admin.refund_cancel.gift_card_forfeit'), disabledYes: expired });
  }
  // ---- kumppanikoodi (booking_280) ----
  const partnerNotes = [];
  if (opts?.voucher_redeemed || +opts?.partner_share > 0) {
    if (+opts.partner_share > 0) partnerNotes.push(rcText('ui.admin.refund_cancel.partner_share', { amount: money(opts.partner_share) }));
    if (opts.order_stays || opts.voucher_redeemed) partnerNotes.push(rcText('ui.admin.refund_cancel.partner_order_stays'));
  }
  // ---- peruutusviesti (booking_281) ----
  // Ei hyvitystä → vihjeessäkään ei mainita hyvitystä (Joonas 11.11.2026 18.15).
  if (opts && opts.customer_email) {
    notifyChoice = requiredYesNo({ name: 'notify', testid: 'rc-notify', legend: rcText('ui.admin.refund_cancel.notify_question'),
      hint: rcText(total > 0 || +opts.gift_card_total > 0 ? 'ui.admin.refund_cancel.notify_hint' : 'ui.admin.refund_cancel.notify_hint_no_refund'), yes: rcText('ui.admin.refund_cancel.notify_yes'), no: rcText('ui.admin.refund_cancel.notify_no') });
  } else if (opts) notes.push(rcText('ui.admin.refund_cancel.notify_no_email'));

  const submit = h('button', { type: 'button', class: 'btn danger', 'data-testid': 'rc-submit', text: rcText('ui.admin.refund_cancel.submit') });
  const back = h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'rc-back', text: rcText('ui.admin.refund_cancel.back'), onclick: () => d.close() });
  const missingMsg = h('p', { class: 'due rc-missing-msg', role: 'alert', hidden: true, 'data-testid': 'rc-missing', text: rcText('ui.admin.refund_cancel.choose_required') });
  submit.onclick = async () => {
    const gcMissing = gcChoice?.missing() || false, ntMissing = notifyChoice?.missing() || false;
    missingMsg.hidden = !(gcMissing || ntMissing);
    if (gcMissing || ntMissing) return;
    submit.disabled = true;
    try {
      const refund = !!choice?.value();
      const args = { p_reservation_id: r.reservation_id, p_reason: 'henkilökunta', p_refund: refund, p_refund_reason: refund ? (reason.value.trim() || null) : null };
      if (opts) { args.p_gift_card_keep = gcChoice ? gcChoice.value() : null; args.p_notify = notifyChoice ? notifyChoice.value() : null; }
      let res;
      try { res = await rpc('admin_cancel_reservation', args); }
      catch (e) {   // kanta ilman booking_136:ta: pelkkä peruutus kuten ennen (hyvitystä ei voi valita, koska esikatselukaan ei vastaa)
        if (refund || opts || !isMissingRpc(e)) throw e;
        res = await rpc('admin_set_reservation_status', { p_reservation_id: r.reservation_id, p_status: 'cancelled', p_reason: 'henkilökunta' });
      }
      await processOnlineRefunds(online, res?.refunds);
      toast(doneText(res), 'ok');
      d.close(); onDone?.(res);
    } catch (e) { toast(friendly(e), 'err'); } finally { submit.disabled = false; }
  };
  // Node.append kirjoittaisi null-arvon tekstiksi "null" → vain olemassa olevat osat.
  body.append(...[h('p', { text: rcText('ui.admin.refund_cancel.cancel_confirm') }), ...notes.map((n) => h('p', { class: 'muted rc-note', text: n })),
    ...partnerNotes.map((n) => h('p', { class: 'tl-note rc-note', 'data-testid': 'rc-partner', text: n })),
    choice?.node, reasonFld, gcChoice?.node, notifyChoice?.node, missingMsg,
    h('div', { class: 'rc-actions' }, back, submit)].filter(Boolean));
  return d;
}

/** Onnistumisilmoitus: peruutus + hyvitys + lahjakortti + kumppanikoodi + viesti. */
export function doneText(res) {
  const parts = [+res?.refunded_total > 0 ? rcText('ui.admin.refund_cancel.done_refunded', { amount: money(res.refunded_total) }) : rcText('ui.admin.refund_cancel.done_cancelled')];
  const gc = Array.isArray(res?.gift_card) ? res.gift_card : [];
  const ret = gc.filter((g) => g.action === 'returned').reduce((s, g) => s + (+g.amount || 0), 0);
  const lost = gc.filter((g) => g.action === 'forfeited').reduce((s, g) => s + (+g.amount || 0), 0);
  if (ret > 0) parts.push(rcText('ui.admin.refund_cancel.done_gift_returned', { amount: money(ret) }));
  if (lost > 0) parts.push(rcText('ui.admin.refund_cancel.done_gift_forfeited', { amount: money(lost) }));
  if (res?.order_kept) parts.push(rcText('ui.admin.refund_cancel.done_order_kept'));
  if (res?.notified) parts.push(rcText('ui.admin.refund_cancel.done_notified'));
  return parts.join(' ');
}

function fmtDate(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso));
  return m ? `${+m[3]}.${+m[2]}.${m[1]}` : String(iso);
}
