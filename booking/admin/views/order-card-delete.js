// booking_279: maksamattoman tilauksen poisto (arkistointi) yhteisessä varaus-/tilauskortissa.
// Palvelin päättää aina: admin_order_delete_check kertoo, voiko poistaa ja miksi ei; admin_delete_unpaid_order tekee poiston.
// Puuttuva RPC tai virhe esitarkistuksessa → ei poisto-osiota. Virhe poistossa → selkokielinen virhe, ei onnistumisviestiä.
import { h, toast, run, fmtDT } from '../ui.js';
import { formDialog } from './talous-ui.js';
import { deletePanelMode, canVerifySession, blockerKey, effectLines, verifyOutcome, submitUnpaidDelete, primaryBlocker, canNotify, hasFutureReservations } from '../order-delete-logic.js';
import { requiredYesNo } from './refund-cancel.js';
import { deleteText } from '../order-delete-texts.js';

export function blockersText(blockers) {
  return (blockers || []).map((b) => deleteText(blockerKey(b?.code))).filter((x, i, a) => a.indexOf(x) === i).join(' ');
}

/** Poistokutsun virhetyyppi → käyttäjälle näytettävä teksti (ei koskaan onnistumista). */
/** [279] Yksi selkokielinen syy (pääsyy), ei luetteloa. */
export function primaryBlockerText(checkOrRes) {
  const code = primaryBlocker(checkOrRes);
  return code ? deleteText(blockerKey(code)) : '';
}

export function deleteErrorText(kind, e) {
  if (kind === 'blocked') return `${deleteText('blocked_title')}: ${primaryBlockerText({ primary_blocker: e?.details?.code, blockers: e?.details?.blockers }) || blockersText(e?.details?.blockers)}`;
  return deleteText(kind);
}

/**
 * Vahvistusdialogi. submit(reason) kutsuu palvelinta; onnistuessa onDone(res).
 * Virhe heitetään formDialogille (dialogi jää auki, punainen ilmoitus, ei onnistumistoastia).
 */
export function openDeleteDialog({ api, order, check, onDone }) {
  const no = order?.order_no ?? check?.order_no;
  const lines = effectLines(check).map(([k, n]) => h('li', { text: deleteText(k, { n }) }));
  const reason = h('input', { name: 'reason', maxlength: 500, autocomplete: 'off', 'data-testid': 'order-delete-reason' });
  // [279] Tuleva varaus + asiakkaan sähköposti → pakollinen kysymys peruutusviestistä (ei oletusta).
  const notify = canNotify(check) ? requiredYesNo({ name: 'notify', testid: 'order-delete-notify', legend: deleteText('notify_question'),
    hint: deleteText('notify_hint'), yes: deleteText('notify_yes'), no: deleteText('notify_no') }) : null;
  const d = formDialog(deleteText('title', { no }), [
    h('p', { text: deleteText(notify ? 'intro_notify' : 'intro') }),
    lines.length ? h('ul', { class: 'stack', 'data-testid': 'order-delete-effects' }, ...lines) : null,
    hasFutureReservations(check) ? h('p', { class: 'muted', text: deleteText('waitlist') }) : null,   // menneen ajan vapautuminen ei koske jonottajia
    h('p', { class: 'muted', text: deleteText('late_payment') }),
    notify ? notify.node : null,
    h('label', { class: 'fld' }, h('span', { text: deleteText('reason') }), reason),
  ], deleteText('confirm'), async (fd) => {
    if (notify?.missing()) throw new Error(deleteText('notify_required'));
    const res = await submitUnpaidDelete(api, { orderId: order?.order_id ?? check?.order_id, reason: fd.get('reason'), notify: notify ? notify.value() : undefined }, deleteErrorText);
    onDone?.(res);
    // Ilmoitus vasta kun vahvistusdialogi ja kortti ovat sulkeutuneet (muuten se jäisi suljetun dialogin sisään).
    setTimeout(() => toast(res.already ? deleteText('already') : `${deleteText('done', { no })}${res.notified ? ` ${deleteText('done_notified')}` : ''}`, res.mock ? 'warn' : 'ok'), 0);
  });
  const submit = d.querySelector('button[type=submit]');
  if (submit) { submit.className = 'btn danger'; submit.dataset.testid = 'order-delete-confirm'; }
  d.dataset.testid = 'order-delete-dialog';
  return d;
}

/**
 * Kortin poisto-osio check-vastauksen perusteella, tai null.
 * onDeleted(res): poisto tehty → kortti sulkee itsensä ja listat päivittyvät. onRecheck(): verkkomaksun tila haettu → hae check uudelleen.
 */
export function orderDeleteBlock({ api, order, check, onDeleted, onRecheck }) {
  const mode = deletePanelMode(check);
  if (!mode) return null;
  if (mode === 'archived') {
    return h('div', { class: 'tl-note oc-delete-note', role: 'status', 'data-testid': 'order-archived' },
      h('p', { text: deleteText('archived', { date: fmtDT(check.archived_at) }) }),
      check.archive_reason ? h('p', { class: 'muted', text: deleteText('archived_reason', { reason: check.archive_reason }) }) : null,
      check.late_paid ? h('p', { class: 'due', 'data-testid': 'order-archived-late-paid', text: `${deleteText('archived_late_paid')}. ${deleteText('archived_late_paid_help')}` }) : null);
  }
  if (mode === 'delete') {
    const btn = h('button', { type: 'button', class: 'btn danger oc-delete-btn', 'data-testid': 'btn-delete-order', text: deleteText('button'),
      onclick: () => openDeleteDialog({ api, order, check, onDone: onDeleted }) });
    return h('div', { class: 'oc-delete', 'data-testid': 'order-delete', 'aria-label': deleteText('danger_label') }, btn);
  }
  if (mode === 'session') {
    const verifiable = canVerifySession(check);
    const status = h('p', { class: 'muted', role: 'status', 'data-testid': 'order-delete-verify-status' });
    const verify = verifiable ? h('button', { type: 'button', class: 'btn sm', 'data-testid': 'btn-delete-verify', text: deleteText('check'), onclick: () => run(verify, async () => {
      const out = verifyOutcome(await api.montonioVerify(check.verify_order_token));
      status.textContent = deleteText(`check_${out}`);
      toast(deleteText(`check_${out}`), out === 'closed' ? 'ok' : out === 'failed' ? 'err' : 'warn');
      if (out === 'closed' || out === 'paid') onRecheck?.();
    }) }) : null;
    return h('section', { class: 'oc-delete oc-delete-info', 'data-testid': 'order-delete-session' },
      h('h4', { text: deleteText('session_title') }),
      h('p', { text: deleteText('session_text') }),
      h('p', { class: 'muted', text: deleteText(verifiable ? 'session_check_help' : 'session_wait_help') }),
      verify, status);
  }
  // blocked: miksi poisto ei ole mahdollinen (ei nappia)
  return h('section', { class: 'oc-delete oc-delete-info', 'data-testid': 'order-delete-blocked' },
    h('h4', { text: deleteText('blocked_title') }),
    h('p', { 'data-testid': 'order-delete-reasons', text: primaryBlockerText(check) || blockersText(check.blockers) }),
    h('p', { class: 'muted', text: deleteText('blocked_help') }));
}
