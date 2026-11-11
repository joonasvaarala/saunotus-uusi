// Pure session logic, shared by cards, print/export and tests. No network or sending.
import { csvText } from './csv.js';
export const TRAINING_SPACES = new Set(['savusauna', 'rauni', 'lovi', 'hoitosauna_rauni', 'hoitosauna_lovi']);
export function trainingGroup(product, statuses = []) {
  return statuses.find(x => (product.rules || []).some(r => r.id === x.rule_id))?.group_kind || (product.product_id === 121 ? 'trip' : 'training');
}
// The legacy list RPC predates training_segment_only: enrich without replacing it.
export function enrichTrainingProducts(products = [], statuses = []) {
  return products.map(p => ({...p, rules:(p.rules || []).map(r => ({...r,...statuses.find(s => s.rule_id === r.id)}))}));
}
export function trainingSessionRules(product, products) {
  const ids=new Set((product.rules||[]).flatMap(r=>[r.id,...(r.segment_ids||[])]));
  return products.flatMap(p=>p.rules||[]).filter(r=>ids.has(r.id)).sort((a,b)=>String(a.starts_at).localeCompare(String(b.starts_at))||a.id-b.id);
}
export function trainingCards(products, { group = 'training', includePast = false, today, statuses = [] } = {}) {
  return products.filter(p => p.category === 'training' && trainingGroup(p, statuses) === group)
    .flatMap(p => (p.rules || []).filter(r => !r.training_segment_only && !r.cancelled_at && (includePast || String(r.session_ends_at || r.ends_at || r.date).slice(0, 10) >= today)).map(r => ({ p, r, status: statuses.find(s => s.rule_id === r.id) || null })))
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

// Hallinnan Kalenteri: koulutukset ja niiden tilavaraukset päiväruutuihin (admin_event_list('training'), sama data kuin Koulutukset-työkalussa).
// Peruttu tai pois käytöstä oleva kerta ei näy. Saman tuotteen päällekkäiset kerrat (esim. aloitus + jatkoviikko) yhdistetään päivällä yhdeksi riviksi.
const SPACE_SHORT = { savusauna: 'Savusauna', rauni: 'Rauni', hoitosauna_rauni: 'Rauni', lovi: 'Lovi', hoitosauna_lovi: 'Lovi' };
export const trainingSpaceName = b => SPACE_SHORT[String(b?.resource_code || '').toLowerCase()] || b?.resource_name || b?.space_name || '';
export const isTrainingSpaceBlock = b => b && b.mode === 'exclusive' && (b.resource_kind === 'space' || TRAINING_SPACES.has(String(b.resource_code || '').toLowerCase()));
export function calendarTrainingDays(products, from, until, { lang = 'fi' } = {}) {
  const out = new Map();
  for (const p of products || []) {
    if (p.category && p.category !== 'training') continue;
    const name = lang === 'en' && p.name_en ? p.name_en : p.name;
    for (const r of p.rules || []) {
      if (r.cancelled_at || r.active === false || !r.starts_at || !r.ends_at) continue;
      const label = lang === 'en' && r.label_en ? r.label_en : r.label;
      const spaces = (r.blocks || []).filter(isTrainingSpaceBlock).filter(b => Date.parse(b.ends_at) > Date.parse(b.starts_at));
      const days = new Set(calendarSpaceDays([{ starts_at: r.starts_at, ends_at: r.ends_at }], from, until).keys());
      const blockDays = calendarSpaceDays(spaces, from, until);
      for (const d of blockDays.keys()) days.add(d);
      for (const day of days) {
        const list = out.get(day) || out.set(day, []).get(day);
        const daySpaces = (blockDays.get(day) || []).map(b => ({ id: b.id, resource_id: b.resource_id, code: b.resource_code || null, name: trainingSpaceName(b), starts_at: b.starts_at, ends_at: b.ends_at }));
        const same = list.find(x => x.product_id === p.product_id);
        if (same) {
          for (const s of daySpaces) if (!same.spaces.some(x => x.id === s.id)) same.spaces.push(s);
          if (!same.labels.includes(label)) same.labels.push(label);
          if (String(r.starts_at) < String(same.starts_at)) same.starts_at = r.starts_at;
          if (String(r.ends_at) > String(same.ends_at)) same.ends_at = r.ends_at;
          continue;
        }
        list.push({ product_id: p.product_id, rule_id: r.id, name, labels: label ? [label] : [], starts_at: r.starts_at, ends_at: r.ends_at, spaces: daySpaces,
          href: `#/koulutukset?${new URLSearchParams({ ...(trainingGroup(p) === 'trip' ? { ryhma: 'matkat' } : {}), tapahtuma: String(p.product_id), kerta: String(r.id) })}` });
      }
    }
  }
  for (const list of out.values()) {
    for (const t of list) { t.spaces.sort((a, b) => String(a.starts_at).localeCompare(String(b.starts_at)) || a.name.localeCompare(b.name)); t.space_names = [...new Set(t.spaces.map(s => s.name).filter(Boolean))]; }
    list.sort((a, b) => String(a.spaces[0]?.starts_at || a.starts_at).localeCompare(String(b.spaces[0]?.starts_at || b.starts_at)) || a.product_id - b.product_id);
  }
  return out;
}
// Koulutuksen tilavaraus näkyy koulutuksen alla, joten sama sulku (space_blocks.event_block_id) ei toistu Tilat-listassa.
export function withoutTrainingBlocks(blocks, products) {
  const keys = new Set();
  for (const p of products || []) for (const r of p.rules || []) for (const b of r.blocks || []) if (isTrainingSpaceBlock(b)) keys.add(`${b.resource_id}|${Date.parse(b.starts_at)}|${Date.parse(b.ends_at)}`);
  return (blocks || []).filter(b => !keys.has(`${b.space_id}|${Date.parse(b.starts_at)}|${Date.parse(b.ends_at)}`));
}
