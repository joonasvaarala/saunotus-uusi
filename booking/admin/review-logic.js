// Tarkista-näkymän sulkukonfliktit: laskenta, syy, kuittauksen vaiheet. Ei DOM:ia.
// Saatavuus ei muutu kuittauksesta: tämä moduuli ei koske sulkuihin eikä varauksiin.

export const ATTENTION_KEYS = ['missing_therapist', 'therapist_conflicts', 'block_conflicts', 'overrides', 'orphan_addons', 'archived_late_payments'];

export const ATTENTION_LABELS_FI = {
  archived_late_payments: 'Maksu poistetulle tilaukselle',
  missing_therapist: 'Ei saunottajaa',
  therapist_conflicts: 'Saunottajakonfliktit',
  block_conflicts: 'Sulku osuu varaukseen',
  overrides: 'Poikkeukset',
  orphan_addons: 'Orvot lisäpalvelut',
  unredeemed_vouchers: 'Kumppanilahjakortit lunastamatta',
};

export function listCount(list, key) {
  return Array.isArray(list?.[key]) ? list[key].length : 0;
}

/** Avoimet tarkistettavat. Kuitatut sulkukonfliktit eivät kasvata lukua. */
export function reviewAttentionCount(list, extra = 0) {
  const base = ATTENTION_KEYS.reduce((n, k) => n + listCount(list, k), 0);
  return base + (Number(extra) > 0 ? Number(extra) : 0);
}

/** Avaimet, joissa on avoimia rivejä. */
export function attentionKeysWithItems(list) {
  return ATTENTION_KEYS.filter((k) => listCount(list, k) > 0);
}

/** Avaimet, joissa ei ole avoimia rivejä (Kunnossa-riville). */
export function attentionKeysEmpty(list) {
  return ATTENTION_KEYS.filter((k) => listCount(list, k) === 0);
}

/** Yläpalkin / yhteenvedon määrä: osiot joissa on tekemistä (+ valinnainen lisämäärä, esim. lunastamattomat). */
export function reviewAttentionSections(list, extraCount = 0) {
  const n = attentionKeysWithItems(list).length + (Number(extraCount) > 0 ? 1 : 0);
  return n;
}

export function canAckBlockConflict(can) {
  return typeof can === 'function' && (!!can('blocks.manage') || !!can('bookings.override'));
}

/** Sulun nimi/syy riville: kalenterin nimi + tapahtuman otsikko, muuten sulun reason. */
export function conflictReason(row) {
  const closure = String(row?.closure_reason || '').trim();
  const block = String(row?.block_reason || '').trim();
  const cal = String(row?.calendar_name || '').trim();
  if (closure) return cal ? `${cal}: ${closure}` : closure;
  return block;
}

export function ackNoteOk(note) {
  return String(note ?? '').trim().length >= 3;
}

/** Ensimmäinen klikkaus pyytää vahvistuksen, toinen lähettää. Lyhyt perustelu ei etene. */
export function nextAckStep(phase, note) {
  if (!ackNoteOk(note)) return { phase: 'edit', error: 'note_required', submit: false };
  if (phase !== 'confirm') return { phase: 'confirm', error: null, submit: false };
  return { phase: 'confirm', error: null, submit: true };
}

export function nextUnackStep(phase) {
  if (phase !== 'confirm') return { phase: 'confirm', submit: false };
  return { phase: 'confirm', submit: true };
}

export function ackArgs(row, note, label) {
  const l = String(label ?? '').trim();
  return {
    p_reservation_id: row?.reservation_id,
    p_block_id: row?.block_id,
    p_note: String(note ?? '').trim(),
    p_label: l || null,
  };
}

export function unackArgs(row) {
  return { p_reservation_id: row?.reservation_id, p_block_id: row?.block_id };
}

// booking_279: acknowledgment never records/refunds money or sends a message.
export const latePaymentAckNoteOk = (note) => {
  const n = String(note ?? '').trim().length;
  return n >= 3 && n <= 1000;
};
export const latePaymentAckArgs = (row, note) => ({ p_payment_id: row?.payment_id, p_note: String(note ?? '').trim() });
