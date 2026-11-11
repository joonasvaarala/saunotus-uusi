// booking_264: maksamattoman tilauksen poisto (arkistointi). Puhtaat apufunktiot näkymälle; päätös ja esteet ovat palvelimella
// (admin_order_delete_check / admin_delete_unpaid_order). Käyttöliittymä ei koskaan päätä poistettavuutta itse.

export const BLOCKER_CODES = ['provider_session_unresolved', 'payment_status', 'settled_payment', 'receipts', 'refunds', 'accounting', 'invoice', 'gift_card',
  'annual_card', 'voucher_claim', 'training', 'reservation_started', 'linked_reservations', 'external_order', 'external_payment', 'order_completed',
  'email_sending', 'email_claim_uncertain'];
/** Esteet, jotka selitetään käyttäjälle (muut esteet: osio piiloon, koska poisto ei kuulu tilaukselle lainkaan). */
export const EXPLAINED_CODES = ['provider_session_unresolved', 'email_sending', 'email_claim_uncertain'];

const codesOf = (check) => (Array.isArray(check?.blockers) ? check.blockers.map((b) => b?.code).filter(Boolean) : []);

/**
 * Mitä tilauksen kohdalla näytetään:
 *  'archived'  – tilaus on poistettu (merkintä, ei nappia)
 *  'delete'    – palvelin sanoo poistettavaksi ja käyttäjällä on oikeus → Poista-nappi
 *  'session'   – ainoa este on avattu verkkomaksu → selitys (+ Tarkista tila, jos tila on haettavissa)
 *  'blocked'   – esteinä vain selitettävät (lähetyksessä oleva sähköposti + mahdollinen verkkomaksu) → esteiden selitys
 *  null        – ei mitään (maksettu, lasku, ei oikeutta, tarkistus puuttuu tai epäonnistui)
 */
export function deletePanelMode(check) {
  if (!check || check.ok === false) return null;
  if (check.archived) return 'archived';
  if (!check.can_delete) return null;
  if (check.deletable === true && codesOf(check).length === 0) return 'delete';
  const codes = codesOf(check);
  if (codes.length && codes.every((c) => c === 'provider_session_unresolved')) return 'session';
  if (codes.length && codes.every((c) => EXPLAINED_CODES.includes(c))) return 'blocked';
  // Maksamaton tilaus, jonka poiston estää jokin muu palvelimen sääntö (esim. toteutunut/mennyt varaus): syy näkyviin selkokielisenä.
  // Maksetuille, laskutetuille ja kirjanpidossa oleville ei näytetä mitään (poisto ei kuulu niille lainkaan).
  if (codes.length && !codes.some((c) => NOT_UNPAID_CODES.includes(c))) return 'blocked';
  return null;
}

/** Esteet, jotka tarkoittavat, ettei tilaus ole maksamaton poistettava tilaus lainkaan → ei poisto-osiota. */
export const NOT_UNPAID_CODES = ['payment_status', 'settled_payment', 'receipts', 'refunds', 'accounting', 'invoice', 'not_found'];

/**
 * Poistokutsun virhe → tekstiavain (ui.admin.order_delete.*). Ei koskaan onnistumista.
 *  forbidden – ei oikeutta (42501 / forbidden / permission denied)
 *  busy      – tilausta käsitellään (palvelimen busy)
 *  blocked   – palvelin esti (blockers)
 *  failed    – muu virhe (tilaus ennallaan)
 */
export function deleteErrorKind(e) {
  const code = String(e?.code ?? e?.details?.code ?? '');
  const msg = String(e?.message ?? '');
  if (code === '42501' || code === 'forbidden' || code === 'permission_denied' || /permission denied|ei oikeutta/i.test(msg)) return 'forbidden';
  if (code === 'busy' || e?.details?.code === 'busy') return 'busy';
  if (Array.isArray(e?.details?.blockers) && e.details.blockers.length) return 'blocked';
  return 'failed';
}

/** Tilan voi hakea maksupalvelulta vain, kun palvelin antoi tilaustokenin (Montonio, nykyinen avoin yritys, tilaus luotu). */
export const canVerifySession = (check) => typeof check?.verify_order_token === 'string' && /^[0-9a-f-]{36}$/i.test(check.verify_order_token);

export function blockerKey(code) {
  return BLOCKER_CODES.includes(code) ? `blocker.${code}` : 'blocker.unknown';
}

/** Vahvistusdialogin vaikutusrivit: [avain, n] – vain nollaa suuremmat. */
export function effectLines(check) {
  const e = check?.effects || {};
  const out = [];
  if (e.order_status === 'cancelled' || e.order_status === 'expired') out.push(['effect_cancelled', 0]);
  if (+e.reservations > 0) out.push(['effect_reservations', +e.reservations]);
  if (+e.pending_payments > 0) out.push(['effect_payments', +e.pending_payments]);
  if (+e.queued_emails > 0) out.push(['effect_emails', +e.queued_emails]);
  return out;
}

/** montonio-notify reconcile -vastaus → yksi tila: paid | closed | pending | failed */
export function verifyOutcome(res) {
  if (!res || res.ok !== true) return 'failed';
  const outs = (Array.isArray(res.results) ? res.results : []).map((r) => r?.outcome);
  if (res.payment_status === 'paid' || outs.includes('paid')) return 'paid';
  if (outs.length && outs.every((o) => o === 'cancelled')) return 'closed';
  if (outs.some((o) => o === 'not_configured' || o === 'retry' || o === 'error')) return 'failed';
  return 'pending';
}

/** Listarivin merkintä: arkistoitu ja maksu saapui → varoitus; muuten arkistoitu → harmaa merkintä. */
export function archivedBadge(row) {
  if (!row?.archived_at) return null;
  return row.archived_late_paid ? 'late_paid' : 'archived';
}

/** Poistovirhe → Error, jonka viesti on selkokielinen (textOf(kind, e)). Ei aseta code-kenttää, jottei yleinen virhekäännös korvaa tekstiä. */
export function deleteFailure(e, textOf) {
  const kind = deleteErrorKind(e);
  return Object.assign(new Error(textOf(kind, e)), { kind, reason: e?.code ?? e?.details?.code ?? null, cause: e });
}

/**
 * Vahvistusdialogin lähetys: kutsuu palvelinta kerran. Palauttaa onnistuneen vastauksen tai heittää deleteFailure-virheen.
 * ok:false-vastaus (busy / esto) on aina virhe, ei koskaan onnistuminen.
 */
export async function submitUnpaidDelete(api, { orderId, reason }, textOf) {
  let res;
  try {
    res = await api.deleteUnpaidOrder({ orderId, reason: String(reason ?? '').trim() || null });
  } catch (e) {
    throw deleteFailure(e, textOf);
  }
  if (!res || res.ok === false) throw deleteFailure({ code: res?.code, details: res || {} }, textOf);
  return res;
}
