// Julkisen päivänäkymän yhdistetty kuukausihaku. Tuotekohtainen varapolku vain vanhalle kannalle.
const pending = new Map();
let unavailable = false;
const key = (id, y, m) => `${id}:${y}-${m}`;
const pad = (n) => String(n).padStart(2, '0');
const date = (y, m, day) => `${y}-${pad(m + 1)}-${pad(day)}`;
export const isMissingAvailabilityAll = (e) =>
  e?.code === 'PGRST202' || e?.code === '42883' || e?.status === 404 ||
  /could not find the function|function .* does not exist|schema cache/i.test(e?.message || '');

export async function ensureAllMonths({ pairs, catalog, months, rpc, fallback, audience = 'consumer' }) {
  const products = (catalog || []).map((p) => +p.id);
  async function fill(y, m) {
    if (products.every((id) => months.has(key(id, y, m)))) return;
    const mk = `${y}-${m}-${audience}`;
    if (pending.has(mk)) return pending.get(mk);
    const task = (async () => {
      const legacy = async () => {
        const jobs = products.filter((id) => !months.has(key(id, y, m))).map((id) => fallback(id, y, m));
        const results = await Promise.allSettled(jobs);
        if (results.length && results.every((r) => r.status === 'rejected')) throw results[0].reason;
      };
      if (unavailable) return legacy();
      let rows;
      try {
        rows = await rpc('public_availability_all', {
          p_from: date(y, m, 1), p_to: date(y, m, new Date(Date.UTC(y, m + 1, 0)).getUTCDate()), p_audience: audience,
        });
        if (!Array.isArray(rows)) throw new TypeError('public_availability_all: expected array');
      } catch (e) {
        if (!isMissingAvailabilityAll(e)) throw e;
        unavailable = true;
        return legacy();
      }
      const byProduct = new Map(products.map((id) => [id, {}]));
      for (const r of rows) {
        const byDay = byProduct.get(+r.product_id);
        if (!byDay || !r.session_date) continue;
        (byDay[r.session_date] ||= []).push(r);
      }
      for (const [id, byDay] of byProduct) {
        for (const d of Object.keys(byDay)) byDay[d].sort((a, b) => a.starts_at.localeCompare(b.starts_at));
        months.set(key(id, y, m), byDay);
      }
    })();
    pending.set(mk, task);
    try { await task; } finally { if (pending.get(mk) === task) pending.delete(mk); }
  }
  const results = await Promise.allSettled(pairs.map(([y, m]) => fill(y, m)));
  if (results.length && results.every((r) => r.status === 'rejected')) throw results[0].reason;
}
// Testien / uuden istunnon alustus; välimuistit eivät siirry istuntojen välillä.
export function resetMonthAvailabilityLoader() { pending.clear(); unavailable = false; }
