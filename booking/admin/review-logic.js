// Tarkista-näkymän sulkukonfliktit: laskenta, syy, kuittauksen vaiheet. Ei DOM:ia.
// Saatavuus ei muutu kuittauksesta: tämä moduuli ei koske sulkuihin eikä varauksiin.

export const ATTENTION_KEYS = ['missing_therapist', 'therapist_conflicts', 'block_conflicts', 'overrides', 'orphan_addons'];

export function listCount(list, key) {
  return Array.isArray(list?.[key]) ? list[key].length : 0;
}

/** Avoimet tarkistettavat. Kuitatut sulkukonfliktit eivät kasvata lukua. */
export function reviewAttentionCount(list) {
  return ATTENTION_KEYS.reduce((n, k) => n + listCount(list, k), 0);
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
