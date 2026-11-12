// Tuotteen kuukausisaatavuus (public_availability) välimuistilla.
// - Samaan kuukauteen kohdistuvat rinnakkaiset haut jakavat yhden RPC-kutsun (ennen: yksi kutsu / kutsuja).
// - loadSpan hakee peräkkäiset puuttuvat kuukaudet yhdellä kutsulla (enintään 92 pv, SQL:n raja) ja jakaa rivit kuukausiin.
//   Rivit ja niiden järjestys ovat samat kuin kuukausi kerrallaan haettuna: public_availability on päiväkohtainen.
// - Välimuistin tyhjennys (months.clear) kasvattaa sukupolvea: ennen tyhjennystä alkanutta hakua ei jaeta uusille
//   eikä sen tulosta kirjoiteta välimuistiin (vanha data ei palaa varauksen jälkeen).
const pad = (n) => String(n).padStart(2, '0');
const dateStr = (y, m, day) => `${y}-${pad(m + 1)}-${pad(day)}`;   // m: 0–11
const lastDay = (y, m) => new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
export const MAX_RANGE_DAYS = 92;   // public_availability: p_to - p_from <= 92

export class MonthCache extends Map {
  gen = 0;
  clear() { this.gen += 1; super.clear(); }
}

// Peräkkäiset kuukaudet [[y, m], …] (aikajärjestyksessä) ryhmiksi, joiden p_to - p_from <= 92.
export function groupMonthRuns(list) {
  const runs = [];
  const idx = ([y, m]) => y * 12 + m;
  const dayNo = (y, m, d) => Math.floor(Date.UTC(y, m, d) / 864e5);
  for (const ym of list) {
    const run = runs[runs.length - 1];
    const prev = run?.[run.length - 1];
    if (run && idx(ym) === idx(prev) + 1 && dayNo(ym[0], ym[1], lastDay(ym[0], ym[1])) - dayNo(run[0][0], run[0][1], 1) <= MAX_RANGE_DAYS) run.push(ym);
    else runs.push([ym]);
  }
  return runs;
}

export function createProductMonthLoader({ months, rpc }) {
  const pending = new Map();   // `${gen}:${avain}` → lupaus, jonka arvo on Map(avain → päivittäiset rivit)
  const key = (id, y, m) => `${id}:${y}-${m}`;

  async function fetchRun(productId, run) {
    const [y0, m0] = run[0], [y1, m1] = run[run.length - 1];
    const gen = months.gen;
    const rows = await rpc('public_availability', { p_product_id: productId, p_from: dateStr(y0, m0, 1), p_to: dateStr(y1, m1, lastDay(y1, m1)) });
    const out = new Map(run.map(([y, m]) => [key(productId, y, m), {}]));
    for (const r of rows || []) {
      const [yy, mm] = String(r.session_date).split('-');
      const byDay = out.get(key(productId, +yy, +mm - 1));
      if (byDay) (byDay[r.session_date] ||= []).push(r);
    }
    for (const byDay of out.values()) for (const k in byDay) byDay[k].sort((a, b) => a.starts_at.localeCompare(b.starts_at));
    if (months.gen === gen) for (const [k, v] of out) months.set(k, v);
    return out;
  }

  // Hakee puuttuvat kuukaudet ([[y, m], …] aikajärjestyksessä); palauttaa Map(avain → byDay).
  async function loadMonths(productId, list) {
    const gen = months.gen;
    const result = new Map(), waits = [], todo = [];
    for (const ym of list) {
      const k = key(productId, ym[0], ym[1]);
      if (months.has(k)) { result.set(k, months.get(k)); continue; }
      const p = pending.get(`${gen}:${k}`);
      if (p) waits.push(p); else todo.push(ym);
    }
    for (const run of groupMonthRuns(todo)) {
      const task = fetchRun(productId, run);
      const tag = run.map(([y, m]) => `${gen}:${key(productId, y, m)}`);
      for (const t of tag) pending.set(t, task);
      const cleanup = () => { for (const t of tag) if (pending.get(t) === task) pending.delete(t); };
      task.then(cleanup, cleanup);
      waits.push(task);
    }
    for (const out of await Promise.all(waits)) for (const [k, v] of out) result.set(k, v);
    return result;
  }

  async function loadMonth(productId, year, month) {   // month: 0–11
    const k = key(productId, year, month);
    return (await loadMonths(productId, [[year, month]])).get(k);
  }

  // fromDs / toDs: 'YYYY-MM-DD'; palauttaa { päivä: rivit } rajattuna välille (enintään 16 kuukautta kuten ennen).
  async function loadSpan(productId, fromDs, toDs) {
    const list = [];
    let [y, m] = fromDs.split('-').map(Number);
    m -= 1;
    const end = toDs.slice(0, 7);
    for (let i = 0; i < 16; i++) {
      list.push([y, m]);
      if (`${y}-${pad(m + 1)}` >= end) break;
      m += 1;
      if (m > 11) { m = 0; y += 1; }
    }
    const got = await loadMonths(productId, list);
    const byDay = {};
    for (const [yy, mm] of list) for (const [d, rows] of Object.entries(got.get(key(productId, yy, mm)) || {})) if (d >= fromDs && d <= toDs) byDay[d] = rows;
    return byDay;
  }

  return { loadMonth, loadSpan };
}
