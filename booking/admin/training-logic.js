// Pure session logic, shared by cards, print/export and tests. No network or sending.
import { csvText } from './csv.js';
export const TRAINING_SPACES = new Set(['savusauna', 'rauni', 'lovi', 'hoitosauna_rauni', 'hoitosauna_lovi']);
export function trainingGroup(product, statuses = []) {
  return statuses.find(x => (product.rules || []).some(r => r.id === x.rule_id))?.group_kind || (product.product_id === 121 ? 'trip' : 'training');
}
export function trainingCards(products, { group = 'training', includePast = false, today, statuses = [] } = {}) {
  return products.filter(p => p.category === 'training' && trainingGroup(p, statuses) === group)
    .flatMap(p => (p.rules || []).filter(r => !r.training_segment_only && !r.cancelled_at && (includePast || String(r.ends_at || r.date).slice(0, 10) >= today)).map(r => ({ p, r, status: statuses.find(s => s.rule_id === r.id) || null })))
    .sort((a, b) => String(a.r.starts_at).localeCompare(String(b.r.starts_at)) || a.r.id - b.r.id);
}
export function paymentState(person) {
  const paid = Number(person.paid_actual) || 0;
  return Number(person.due_actual) <= 0.004 ? 'paid' : paid > 0.004 ? 'partial' : 'unpaid';
}
export function validSpaceTime(date, start, end) {
  return /^\d{4}-\d{2}-\d{2}$/.test(date || '') && /^\d{2}:\d{2}$/.test(start || '') && /^\d{2}:\d{2}$/.test(end || '') && end > start;
}
export function nextTrainingStep({ blocks = [], people = [], messages = [], work = {} }) {
  if (!blocks.length) return 'spaces';
  if (people.some(p => Number(p.due_actual) > 0.004)) return 'payments';
  if (!messages.some(m => m.queued_count > 0)) return 'messages';
  return work.materials_shared ? 'people' : 'materials';
}
export function trainingExport(people, headers) {
  const keys = ['name','email','phone','persons','diet','accommodation','arrival','language','present','paid_actual','due_actual'];
  return '\uFEFF' + [headers, ...people.map(p => keys.map(k => k === 'present' ? (p[k] ? '1' : '') : p[k] ?? ''))]
    .map(row => row.map(csvText).join(';')).join('\r\n') + '\r\n';
}
// Any edit invalidates the preview; send uses only the server's immutable preview id.
export function messagePreviewGate() {
  let preview = null, revision = 0;
  return {
    invalidate() { revision++; preview = null; },
    revision: () => revision,
    accept(value, atRevision) { if (atRevision !== revision) return false; preview = value; return true; },
    read: () => preview,
  };
}
export function orderedWaiters(rows) { return [...rows].sort((a, b) => String(a.created_at).localeCompare(String(b.created_at)) || a.id - b.id); }

// Half-open ranges: a block ending at midnight does not paint the following day.
export function calendarSpaceDays(blocks, from, until) {
  const result = new Map();
  const helDay = d => d.toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
  for (const block of blocks || []) {
    const start = Date.parse(block.starts_at), end = Date.parse(block.ends_at);
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) continue;
    const first = helDay(new Date(start)), last = helDay(new Date(end - 1));
    const date = new Date(`${first < from ? from : first}T12:00:00Z`);
    for (let n = 0; n < 94; n++, date.setUTCDate(date.getUTCDate() + 1)) {
      const day = date.toISOString().slice(0, 10);
      if (day > last || day >= until) break;
      if (!result.has(day)) result.set(day, []);
      result.get(day).push(block);
    }
  }
  return result;
}
