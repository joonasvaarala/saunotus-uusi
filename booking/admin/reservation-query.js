// Varauslistan osoite ja "Hoito valitsematta" -suodatin. Puhdas moduuli (ei DOM:ia) → node --test.
// Linkki päivänäkymästä: #/varaukset?filter=treatment_unassigned&period=upcoming
// Palvelin (booking_72, p_option_missing) suodattaa sivutuksen kanssa. Ennen migraatiota selain rajaa option_missing-kentästä.

export const TREATMENT_UNASSIGNED = 'treatment_unassigned';
export const PERIODS = ['all', 'upcoming', 'past', 'month', 'custom'];
const DAY = /^\d{4}-\d\d-\d\d$/;

export function normalizeHash(hash) {
  const h = String(hash || '');
  if (!h || h === '#') return '#/';
  return h.startsWith('#') ? h : `#${h}`;
}

/** Sama fragmentti ei laukaise hashchange-tapahtumaa, joten näkymä pitää piirtää käsin. */
export function needsManualRoute(currentHash, href) {
  return normalizeHash(currentHash) === normalizeHash(href);
}

export function parseAdminHash(hash) {
  const raw = normalizeHash(hash).replace(/^#\/?/, '');
  const qIdx = raw.indexOf('?');
  const pathPart = qIdx >= 0 ? raw.slice(0, qIdx) : raw;
  const query = qIdx >= 0 ? raw.slice(qIdx + 1) : '';
  return { path: pathPart.split('/')[0] || '', query: new URLSearchParams(query) };
}

export function reservationSearch({ treatment = '', period = 'all', status = '', product = '', source = '', search = '', from = '', to = '' } = {}) {
  const q = new URLSearchParams();
  if (treatment === TREATMENT_UNASSIGNED) q.set('filter', TREATMENT_UNASSIGNED);
  if (PERIODS.includes(period) && period !== 'all') q.set('period', period);
  if (status) q.set('status', status);
  if (product) q.set('product', String(product));
  if (source) q.set('source', source);
  if (search) q.set('q', search);
  if (period === 'custom') {
    if (DAY.test(from)) q.set('from', from);
    if (DAY.test(to)) q.set('to', to);
  }
  return q;
}

export function reservationsHref(state) {
  const s = reservationSearch(state).toString();
  return `#/varaukset${s ? `?${s}` : ''}`;
}

export const UNASSIGNED_HREF = reservationsHref({ treatment: TREATMENT_UNASSIGNED, period: 'upcoming' });

export function stateFromQuery(params) {
  const q = params instanceof URLSearchParams ? params : new URLSearchParams(params || '');
  const periodRaw = q.get('period') || '';
  return {
    treatment: q.get('filter') === TREATMENT_UNASSIGNED ? TREATMENT_UNASSIGNED : '',
    period: PERIODS.includes(periodRaw) ? periodRaw : 'all',
    status: q.get('status') || '',
    product: q.get('product') || '',
    source: q.get('source') || '',
    search: q.get('q') || '',
    from: DAY.test(q.get('from') || '') ? q.get('from') : '',
    to: DAY.test(q.get('to') || '') ? q.get('to') : '',
  };
}

export function isTreatmentUnassigned(row) {
  return row?.option_missing === true;
}

/** PostgREST ei löydä p_option_missing-parametria (migraatio booking_72 ei ole vielä kannassa). */
export function isUnassignedFilterUnsupported(e) {
  const msg = `${e?.status || ''} ${e?.code || ''} ${e?.message || ''}`;
  return e?.status === 404 || /PGRST202|PGRST203|could not find the function|schema cache/i.test(msg);
}

/** Käy palvelimen sivut läpi ja pitää vain option_missing-rivit. total_count on suodattamaton, joten sivutus tehdään vasta rajauksen jälkeen. */
export async function collectUnassigned(rpc, base) {
  const out = [];
  let off = 0, total = Infinity;
  for (let guard = 0; guard < 40 && off < total; guard++) {
    const batch = await rpc('admin_list_reservations', { ...base, p_limit: 100, p_offset: off });
    if (!batch?.length) break;
    total = Number(batch[0].total_count ?? off + batch.length);
    for (const r of batch) if (isTreatmentUnassigned(r)) out.push(r);
    off += batch.length;
  }
  return out;
}

/**
 * Yksi sivu varauslistaa. treatment=treatment_unassigned → p_option_missing, ja jos funktio ei tunne parametria, selaimen rajaus.
 * cache.all säilyttää selainrajauksen "Näytä lisää" -napille (load(true) nollaa sen).
 */
export async function loadReservationPage(rpc, base, { treatment, offset, limit, cache }) {
  if (treatment !== TREATMENT_UNASSIGNED) {
    const rows = await rpc('admin_list_reservations', { ...base, p_limit: limit, p_offset: offset });
    return { rows, total: Number(rows[0]?.total_count ?? 0), mode: 'server' };
  }
  if (cache?.all) return { rows: cache.all.slice(offset, offset + limit), total: cache.all.length, mode: 'client' };
  try {
    const rows = await rpc('admin_list_reservations', { ...base, p_option_missing: true, p_limit: limit, p_offset: offset });
    return { rows, total: Number(rows[0]?.total_count ?? 0), mode: 'server' };
  } catch (e) {
    if (!isUnassignedFilterUnsupported(e)) throw e;
    const all = await collectUnassigned(rpc, base);
    if (cache) cache.all = all;
    return { rows: all.slice(offset, offset + limit), total: all.length, mode: 'client' };
  }
}
