// Myyntikäyrän laskenta (booking.admin_sales_chart / mock). Puhdas moduuli: ei DOM:ia, ei verkkoa.
// Sama pyöristys kuin kuiteissa: sentti = round(brutto * kanta / (100 + kanta), 2).
// Johku: brutto on external_meta.johku.amount (muuten tilauksen brutto). ALV skaalataan rivien
// line_vat / line_total_gross -suhteella, jotta net + ALV = brutto. Jos rivejä ei ole tai rivien
// brutto ei ole positiivinen, kantaa ei keksitä: summa jää unsplit_gross-kenttään.

export const round2 = (n) => Math.round((+n + Number.EPSILON) * 100) / 100;

export function lineVat(gross, rate) {
  return round2((+gross || 0) * (+rate || 0) / (100 + (+rate || 0)));
}

/** signed = mukaan laskettava Johku-brutto. Kokonaan hyvitetty tilaus jätetään kutsumatta (nettovaikutus 0). accounted = tilauksella on kuitti, joka ei ole kirjanpidosta pois → älä laske uudestaan. */
export function splitSignedGross(signed, lineGross, lineVatSum) {
  const g = +signed || 0;
  if (!(+lineGross > 0)) return { net: 0, vat: 0, split: 0, unsplit: g };
  const vat = round2(g * (+lineVatSum || 0) / +lineGross);
  return { net: round2(g - vat), vat, split: g, unsplit: 0 };
}

const z = () => ({ native_net: 0, native_vat: 0, native_gross: 0, johku_net: 0, johku_vat: 0, johku_gross: 0, unsplit_gross: 0 });

export function createAccumulator(year) {
  const raw = Array.from({ length: 12 }, (_, i) => ({ month: i + 1, ...z() }));
  return {
    addNative(month, net, vat, gross) {
      const m = raw[month - 1]; if (!m) return;
      m.native_net += +net || 0; m.native_vat += +vat || 0; m.native_gross += +gross || 0;
    },
    addJohku(month, { signed, lineGross, lineVat, accounted }) {
      if (accounted) return;
      const m = raw[month - 1]; if (!m) return;
      const s = splitSignedGross(signed, lineGross, lineVat);
      m.johku_net += s.net; m.johku_vat += s.vat; m.johku_gross += s.split; m.unsplit_gross += s.unsplit;
    },
    finish(years = []) {
      const months = raw.map((m) => {
        const o = { month: m.month };
        for (const k of Object.keys(z())) o[k] = round2(m[k]);
        o.net = round2(o.native_net + o.johku_net);
        o.vat = round2(o.native_vat + o.johku_vat);
        o.gross = round2(o.native_gross + o.johku_gross + o.unsplit_gross);
        return o;
      });
      const totals = { month: 0, ...z(), net: 0, vat: 0, gross: 0 };
      for (const m of months) for (const k of [...Object.keys(z()), 'net', 'vat', 'gross']) totals[k] = round2(totals[k] + m[k]);
      const ys = [...new Set([+year, ...years.map((y) => +y)])].filter((y) => y >= 2000 && y <= 2100).sort((a, b) => a - b);
      return {
        year: +year, tz: 'Europe/Helsinki', basis: 'cash_receipt_issued_at', johku_basis: 'johku_paid_at', vat_method: 'order_item_rates_proportional',
        months, totals, years: ys,
      };
    },
  };
}

// Pystyakselin siisti yläraja. Jakoviivoja on 3–5, tasavälein, ja askel on 1, 2, 2,5 tai 5 × kymmenen potenssi.
const STEP_FRACS = [1, 2, 2.5, 5];
const tidy = (n) => {
  const r = Math.round((+n + Number.EPSILON) * 100) / 100;
  return Object.is(r, -0) ? 0 : r;
};
const lexLess = (a, b) => {
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return a[i] < b[i];
  return false;
};

export function salesAxis(peak) {
  const value = Number(peak);
  if (!Number.isFinite(value) || value <= 0) return { max: 1000, step: 500, ticks: [0, 500, 1000] };
  const mag = 10 ** Math.floor(Math.log10(value));
  let best = null;
  for (let e = -2; e <= 3; e++) {
    const pow = mag * 10 ** e;
    if (!Number.isFinite(pow) || pow <= 0) continue;
    for (const frac of STEP_FRACS) {
      const step = frac * pow;
      if (!(step > 0) || !Number.isFinite(step)) continue;
      for (let intervals = 2; intervals <= 4; intervals++) {
        const max = step * intervals;
        if (max + 1e-8 < value) continue;
        const rel = (max - value) / value;
        const nTicks = intervals + 1;
        const score = [rel > 2 ? 1 : 0, Math.round(rel * 1e6), Math.abs(nTicks - 4), frac === 2.5 ? 1 : 0, intervals];
        const ticks = Array.from({ length: nTicks }, (_, i) => tidy(step * i));
        const cand = { max: ticks[nTicks - 1], step: tidy(ticks[1] - ticks[0]), ticks, score };
        if (cand.max + 1e-8 < value) continue;
        if (!best || lexLess(score, best.score)) best = cand;
      }
    }
  }
  if (!best) {
    const step = tidy(value);
    return { max: step, step: tidy(step / 2), ticks: [0, tidy(step / 2), step] };
  }
  return { max: best.max, step: best.step, ticks: best.ticks };
}

/** Akselin luku suomeksi: "10 000 €" (ryhmittelyväli, ei senttejä tasaluvussa). */
export function formatAxisEuro(n) {
  const v = Number(n);
  const x = Number.isFinite(v) ? tidy(v) : 0;
  const body = new Intl.NumberFormat('fi-FI', { minimumFractionDigits: 0, maximumFractionDigits: 2 }).format(Object.is(x, -0) ? 0 : x);
  return `${body}\u00A0€`;
}

/** Kuukausien brutto (ja pylvään näkyvä pino) → akseli. Negatiivinen osa saa oman siistin alarajan, jotta euro/pikseli pysyy samana. */
export function chartScale(months) {
  let peak = 0, floor = 0;
  for (const m of Array.isArray(months) ? months : []) {
    const net = +m?.net || 0, vat = +m?.vat || 0, unsplit = +m?.unsplit_gross || 0;
    peak = Math.max(peak, +m?.gross || 0, Math.max(0, net) + Math.max(0, vat) + Math.max(0, unsplit));
    floor = Math.min(floor, Math.min(0, net) + Math.min(0, vat) + Math.min(0, unsplit));
  }
  const axis = salesAxis(peak);
  if (!(floor < 0)) return { max: axis.max, min: 0, step: axis.step, ticks: axis.ticks };
  const down = salesAxis(-floor);
  const neg = down.ticks.filter((t) => t > 0).map((t) => tidy(-t)).reverse();
  return { max: axis.max, min: tidy(-down.max), step: axis.step, ticks: [...neg, ...axis.ticks] };
}

/** ParentNode.replaceChildren stringifioi null- ja undefined-arvon tekstiksi "null" / "undefined". */
export function visibleNodes(nodes) {
  const out = [];
  for (const n of (Array.isArray(nodes) ? nodes : [nodes]).flat(Infinity)) if (n != null && n !== false) out.push(n);
  return out;
}
