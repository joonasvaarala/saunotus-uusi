// Julkisen päivänäkymän yhdistetty kuukausihaku. Tuotekohtainen varapolku vain vanhalle kannalle.
import { groupMonthRuns } from './product-months.js';
const pending = new Map();
let unavailable = false;
const key = (id, y, m) => `${id}:${y}-${m}`;
const pad = (n) => String(n).padStart(2, '0');
const date = (y, m, day) => `${y}-${pad(m + 1)}-${pad(day)}`;
export const isMissingAvailabilityAll = (e) =>
  e?.code === 'PGRST202' || e?.code === '42883' || e?.status === 404 ||
  /could not find the function|function .* does not exist|schema cache/i.test(e?.message || '');

// Peräkkäiset puuttuvat kuukaudet haetaan yhdellä public_availability_all-kutsulla (enintään 92 pv, SQL:n raja); rivit jaetaan kuukausiin.
// Tulos (months-välimuisti) on sama kuin kuukausi kerrallaan haettuna: funktio on päiväkohtainen.
export async function ensureAllMonths({ pairs, catalog, months, rpc, fallback, audience = 'consumer' }) {
  const products = (catalog || []).map((p) => +p.id);
  const complete = (y, m) => products.every((id) => months.has(key(id, y, m)));
  const legacy = async (list) => {
    const jobs = list.flatMap(([y, m]) => products.filter((id) => !months.has(key(id, y, m))).map((id) => fallback(id, y, m)));
    const results = await Promise.allSettled(jobs);
    if (results.length && results.every((r) => r.status === 'rejected')) throw results[0].reason;
  };
  async function fetchRun(run) {
    if (unavailable) return legacy(run);
    const [y0, m0] = run[0], [y1, m1] = run[run.length - 1];
    let rows;
    try {
      rows = await rpc('public_availability_all', {
        p_from: date(y0, m0, 1), p_to: date(y1, m1, new Date(Date.UTC(y1, m1 + 1, 0)).getUTCDate()), p_audience: audience,
      });
      if (!Array.isArray(rows)) throw new TypeError('public_availability_all: expected array');
    } catch (e) {
      if (!isMissingAvailabilityAll(e)) throw e;
      unavailable = true;
      return legacy(run);
    }
    const byMonth = new Map(run.map(([y, m]) => [`${y}-${m}`, new Map(products.map((id) => [id, {}]))]));
    for (const r of rows) {
      if (!r.session_date) continue;
      const [yy, mm] = String(r.session_date).split('-');
      const byProduct = byMonth.get(`${+yy}-${+mm - 1}`);
      const byDay = byProduct?.get(+r.product_id);
      if (byDay) (byDay[r.session_date] ||= []).push(r);
    }
    for (const [mk, byProduct] of byMonth) {
      const [y, m] = mk.split('-').map(Number);
      for (const [id, byDay] of byProduct) {
        for (const d of Object.keys(byDay)) byDay[d].sort((a, b) => a.starts_at.localeCompare(b.starts_at));
        months.set(key(id, y, m), byDay);
      }
    }
  }
  const uniq = [...new Map(pairs.map(([y, m]) => [`${y}-${m}`, [y, m]])).values()].sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  const waits = [], todo = [];
  for (const [y, m] of uniq) {
    if (complete(y, m)) continue;
    const running = pending.get(`${y}-${m}-${audience}`);
    if (running) waits.push(running); else todo.push([y, m]);
  }
  for (const run of groupMonthRuns(todo)) {
    const task = fetchRun(run);
    const tags = run.map(([y, m]) => `${y}-${m}-${audience}`);
    for (const t of tags) pending.set(t, task);
    const done = () => { for (const t of tags) if (pending.get(t) === task) pending.delete(t); };
    task.then(done, done);
    for (let i = 0; i < run.length; i++) waits.push(task);
  }
  const results = await Promise.allSettled(waits);
  if (results.length && results.every((r) => r.status === 'rejected')) throw results[0].reason;
}
// Testien / uuden istunnon alustus; välimuistit eivät siirry istuntojen välillä.
export function resetMonthAvailabilityLoader() { pending.clear(); unavailable = false; }
