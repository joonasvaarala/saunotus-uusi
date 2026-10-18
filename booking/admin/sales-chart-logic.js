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
