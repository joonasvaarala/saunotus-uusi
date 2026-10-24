// Vuosikorttikoodin näytön puhdas logiikka (booking_146): admin_annual_card_for_order-vastaus → näytettävä malli. Ei DOM:ia → node --test.
// Sähköpostin tila: email_outbox.status tai palvelimen 'no_email' (asiakkaalla ei osoitetta) / 'not_queued' (ei jonossa, esim. vanha kortti).
export const MAIL_STATUS = { sent: 'sent', pending: 'pending', sending: 'pending', dry_run: 'dry_run', skipped: 'skipped', failed: 'failed', dead: 'failed', no_email: 'no_email', not_queued: 'not_queued' };
export const MAIL_TONE = { sent: 'ok', pending: 'ok', dry_run: 'warn', skipped: 'warn', failed: 'err', no_email: 'warn', not_queued: 'warn' };

/** null = ei vuosikorttitilaus (ei näytetä mitään). state: 'card' | 'waiting' | 'no_customer' | 'missing'. */
export function annualCardModel(info) {
  if (!info || info.ok === false || !info.has_season_card) return null;
  const c = info.card;
  if (!c || !String(c.code ?? '').trim()) {
    const state = info.payment_status !== 'paid' ? 'waiting' : info.has_customer === false ? 'no_customer' : 'missing';
    return { state, noteKey: `ui.admin.annual_card.${state === 'waiting' ? 'waiting_payment' : state}` };
  }
  const status = MAIL_STATUS[info.email?.status] || 'not_queued';
  return {
    state: 'card', code: String(c.code).trim(), from: c.valid_from || null, to: c.valid_to || null,
    cardNoteKey: c.revoked === true ? 'ui.admin.annual_card.revoked' : c.active === false ? 'ui.admin.annual_card.inactive' : null,
    mail: { status, tone: MAIL_TONE[status], key: `ui.admin.annual_card.email_${status}`, to: info.email?.to || '' },
  };
}
