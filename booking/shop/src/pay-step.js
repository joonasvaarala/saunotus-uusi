// Kassan jälkeinen askel: maksu heti oston jälkeen, tilaussivu myöhempää paluuta varten.
// Ei muuta hintoja, tilauksen tilaa eikä maksun kirjausta. Päätös on vain siitä, mitä asiakkaalle näytetään.

export const freshPayKey = (token) => `bk-pay-now-${String(token || '').toLowerCase()}`;

export function markFreshPay(token, storage = typeof sessionStorage !== 'undefined' ? sessionStorage : null) {
  try { storage?.setItem(freshPayKey(token), '1'); } catch { /* yksityinen tila */ }
}

/** Kerran: true vain heti oston jälkeen. Myöhempi avaus (sähköpostilinkki, päivitys) on tilaussivu. */
export function takeFreshPay(token, storage = typeof sessionStorage !== 'undefined' ? sessionStorage : null) {
  const key = freshPayKey(token);
  try {
    if (!storage || storage.getItem(key) !== '1') return false;
    storage.removeItem(key);
    return true;
  } catch { return false; }
}

/**
 * redirect: yksi verkkomaksutapa, ei lahjakorttivaihtoehtoa → maksusivulle heti.
 * redirect-link: verkkomaksutapoja ei ole, mutta avoin maksulinkki → se on maksusivu.
 * finish: maksutapa pitää valita (useita tapoja tai lahjakortti) → lyhyt "Viimeistele tilaus", ei tilauksen tilasivu.
 * status: myöhempi käynti, paluu maksusta, tai ei maksettavaa.
 */
export function payStepKind({ fresh = false, returning = false, payable = false, onlineCount = 0, gift = false, link = false } = {}) {
  if (!payable || returning || !fresh) return 'status';
  const n = onlineCount | 0;
  if (n === 1 && !gift) return 'redirect';
  if (n > 1 || gift) return 'finish';
  if (link) return 'redirect-link';
  return 'status';
}

/** Lahjakortilla ei makseta lahjakorttitilausta (tilauksella on jo kortteja). */
export function giftPayOffered({ locked = false, redeem = false, unpaid = 0, hidden = false, hasCards = false, status = '' } = {}) {
  return !locked && !!redeem && unpaid > 0 && !hidden && !hasCards && (status === 'confirmed' || status === 'pending');
}

/**
 * Yksi asiakkaan merkki. Avoin maksu ei saa kahta sisäistä merkkiä (Odottaa maksua + Maksu kesken).
 * hold: expired | processing | preliminary | awaiting | null.
 */
export function customerBadges({ status = '', paymentStatus = '', paid = 0, unpaid = 0, online = false, hold = null, texts = {} } = {}) {
  const one = (kind, text) => (text ? [{ kind, text }] : []);
  if (status === 'cancel_requested') return one('st-cancel_requested', texts.cancel);
  if (hold === 'expired' || status === 'expired') return one('st-expired', texts.expired);
  if (status === 'cancelled' || hold === 'cancelled') return one('st-cancelled', texts.cancelled);
  if (hold === 'processing') return one('pay-pending', texts.processing);
  if (hold === 'preliminary') return one('st-pending', texts.preliminary);
  if (paymentStatus === 'invoiced') return one('pay-invoiced', texts.invoiced);
  if (paymentStatus === 'refunded') return one('pay-refunded', texts.refunded);
  if (paymentStatus === 'partially_refunded') return one('pay-partially_refunded', texts.partialRefund);
  if (paymentStatus === 'paid' || (unpaid <= 0 && paid > 0)) return one('pay-paid', texts.paid);
  if (paymentStatus === 'failed') return one('pay-failed', texts.failed);
  if (paid > 0.004 && unpaid > 0.004) return one('pay-partially_paid', texts.partial);
  const open = unpaid > 0.004 && (online || status === 'pending' || hold === 'awaiting' || paymentStatus === 'pending');
  if (open) return one('pay-pending', texts.open);
  if (status === 'confirmed') return one('st-confirmed', texts.confirmed);
  return one(`st-${status}`, texts.other || status);
}

/** Osasuoritus (lahjakortti kävi) saa "maksamaton osa" -sanan. Pelkkä avoin tilaus ei. */
export function duePresentation({ paid = 0, unpaid = 0 } = {}) {
  const partial = paid > 0.004 && unpaid > 0.004;
  return { partial, cta: partial ? 'rest' : 'continue', dueKey: partial ? 'unpaid' : 'dueNow', alarm: partial };
}
