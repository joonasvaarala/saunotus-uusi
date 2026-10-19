// Laskurivin rahat samaan senttiin kuin booking._invoice_put_lines.
// price_basis gross: line_gross = round(määrä × verollinen á-hinta, 2),
//   line_vat = round(line_gross × kanta / (100 + kanta), 2), line_net = line_gross − line_vat,
//   unit_price_net = round(line_net / määrä, 4).
// price_basis net (myös kun perustetta ei ole): line_net = round(määrä × veroton á-hinta, 2),
//   line_vat = round(line_net × kanta / 100, 2), line_gross = line_net + line_vat.
// Pyöristys on half away from zero (PostgreSQL numeric). Tuoteluettelon hinta on kuluttajahinta (sis. alv).

export const UNITS = ['kpl', 'h', 'pv', 'hlö', 'krt', 'erä'];

export function parseScaled(raw, scale) {
  if (raw == null) return null;
  let s = String(raw).trim().replace(/\s/g, '').replace(',', '.');
  if (!/^[+-]?\d+(\.\d+)?$/.test(s)) return null;
  const neg = s.startsWith('-');
  if (s[0] === '+' || s[0] === '-') s = s.slice(1);
  const [a, b = ''] = s.split('.');
  if (b.length > scale) return null;
  const digits = `${a}${b.padEnd(scale, '0')}`.replace(/^0+(?=\d)/, '');
  if (digits.length > 15) return null;
  const v = BigInt(digits);
  return neg ? -v : v;
}

export function divRoundAway(num, den) {
  if (den === 0n) throw new Error('div0');
  if (den < 0n) return divRoundAway(-num, -den);
  const neg = num < 0n;
  const a = neg ? -num : num;
  const q = a / den;
  const r = a % den;
  const up = r * 2n >= den ? q + 1n : q;
  return neg ? -up : up;
}

export function rateTenthsOf(vatRate) {
  if (vatRate == null || vatRate === '') return null;
  return parseScaled(String(vatRate).trim(), 1);
}

export function lineAmountsFromScaled({ qtyMilli, price10000, rateTenths }) {
  const netCents = divRoundAway(qtyMilli * price10000, 100000n);
  const vatCents = divRoundAway(netCents * rateTenths, 1000n);
  return { netCents, vatCents, grossCents: netCents + vatCents };
}

export function grossToNet10000(gross10000, rateTenths) {
  if (rateTenths === 0n) return gross10000;
  return divRoundAway(gross10000 * 1000n, 1000n + rateTenths);
}

export function netToGross10000(net10000, rateTenths) {
  if (rateTenths === 0n) return net10000;
  return divRoundAway(net10000 * (1000n + rateTenths), 1000n);
}

function formatDot(value, scale) {
  const neg = value < 0n;
  const digits = (neg ? -value : value).toString().padStart(scale + 1, '0');
  return `${neg ? '-' : ''}${digits.slice(0, -scale)}.${digits.slice(-scale)}`;
}

export function formatFiScaled(value, scale, minFrac = 0) {
  const neg = value < 0n;
  const digits = (neg ? -value : value).toString().padStart(scale + 1, '0');
  const intPart = digits.slice(0, -scale);
  let frac = digits.slice(-scale);
  let keep = frac.length;
  while (keep > minFrac && frac[keep - 1] === '0') keep -= 1;
  frac = frac.slice(0, keep);
  return `${neg ? '-' : ''}${frac ? `${intPart},${frac}` : intPart}`;
}

export function formatRateFi(tenths) {
  const n = Number(tenths);
  const neg = n < 0;
  const a = Math.abs(n);
  const whole = Math.trunc(a / 10);
  const frac = a % 10;
  return `${neg ? '-' : ''}${frac ? `${whole},${frac}` : String(whole)} %`;
}

/** JSON-luku, jonka teksti on täsmälleen skaalattu desimaali (RPC:n ::numeric). */
export function jsonDecimal(scaled, scale) {
  const text = formatDot(scaled, scale).replace(/(\.\d*?)0+$/, '$1').replace(/\.$/, '');
  const n = Number(text);
  return JSON.stringify(n) === text ? n : text;
}

function grossAmounts({ qtyMilli, gross10000, rateTenths }) {
  const grossCents = divRoundAway(qtyMilli * gross10000, 100000n);
  const vatCents = rateTenths === 0n ? 0n : divRoundAway(grossCents * rateTenths, 1000n + rateTenths);
  const netCents = grossCents - vatCents;
  const net10000 = divRoundAway(netCents * 100000n, qtyMilli);
  return { netCents, vatCents, grossCents, net10000, gross10000 };
}

export function amountsForLine({ quantity, priceNet, priceGross, vatRate, basis }) {
  const qty = parseScaled(quantity, 3);
  const tenths = rateTenthsOf(vatRate);
  if (qty == null || tenths == null || qty === 0n) return null;
  if (basis === 'net') {
    const net = parseScaled(priceNet, 4);
    if (net == null) return null;
    const a = lineAmountsFromScaled({ qtyMilli: qty, price10000: net, rateTenths: tenths });
    return { ...a, rateTenths: tenths, net10000: net, gross10000: netToGross10000(net, tenths), basis: 'net' };
  }
  const gross = parseScaled(priceGross, 4);
  if (gross == null) return null;
  return { ...grossAmounts({ qtyMilli: qty, gross10000: gross, rateTenths: tenths }), rateTenths: tenths, basis: 'gross' };
}

export function validateLine({ description, quantity, priceNet, priceGross, vatRate, rates, basis }) {
  const errors = {};
  const desc = String(description ?? '').trim();
  if (!desc || desc.length > 300) errors.description = 'desc';
  const qty = parseScaled(quantity, 3);
  if (qty == null || qty === 0n) errors.quantity = 'qty';
  const netOk = parseScaled(priceNet, 4) != null;
  const grossOk = parseScaled(priceGross, 4) != null;
  if (basis === 'net' ? !netOk : !grossOk) {
    if (basis !== 'net' && !grossOk) errors.price_gross = 'price';
    if (!netOk) errors.price_net = 'price';
    if (basis === 'net' && !grossOk) errors.price_gross = 'price';
  }
  const tenths = rateTenthsOf(vatRate);
  const known = (rates || []).some((r) => r && r.active !== false && rateTenthsOf(r.rate) === tenths);
  if (tenths == null || !known) errors.vat = 'vat';
  return errors;
}

export function lineToPayload(line) {
  const basis = line.basis === 'net' ? 'net' : 'gross';
  const a = amountsForLine({ quantity: line.quantity, priceNet: line.price_net, priceGross: line.price_gross, vatRate: line.vat_rate, basis });
  const qty = parseScaled(line.quantity, 3);
  if (!a || qty == null) return null;
  return {
    description: String(line.description ?? '').trim(),
    quantity: jsonDecimal(qty, 3),
    unit: UNITS.includes(line.unit) ? line.unit : 'kpl',
    price_basis: a.basis,
    unit_price_net: jsonDecimal(a.net10000, 4),
    unit_price_gross: jsonDecimal(a.gross10000, 4),
    vat_rate: jsonDecimal(a.rateTenths, 1),
  };
}

export function convertPriceString(price, vatRate, fromGross, toGross) {
  if (fromGross === toGross) return price;
  const entered = parseScaled(price, 4);
  const tenths = rateTenthsOf(vatRate);
  if (entered == null || tenths == null) return price;
  const net = fromGross ? grossToNet10000(entered, tenths) : entered;
  const shown = toGross ? netToGross10000(net, tenths) : net;
  return formatFiScaled(shown, 4, 2);
}

/** Tuoteluettelon hinta on verollinen kuluttajahinta. */
export function catalogPriceString(gross) {
  const g = parseScaled(gross, 4);
  if (g == null) return '';
  return formatFiScaled(g, 4, 2);
}

/** Hakuehdotukset eivät pakota valintaa: viimeinen rivi on kirjoitettu teksti sellaisenaan. */
export function suggestLines(products, query, limit = 8) {
  const freeText = String(query ?? '').trim();
  if (!freeText) return { products: [], freeText: null };
  return { products: filterProducts(products, freeText, limit), freeText };
}

export function filterProducts(products, query, limit = 8) {
  const q = String(query || '').trim().toLowerCase();
  if (!q) return [];
  const rows = [];
  for (const p of products || []) {
    if (!p || p.active === false || !p.name) continue;
    const name = String(p.name).toLowerCase();
    const en = String(p.name_en || '').toLowerCase();
    const ni = name.indexOf(q);
    const ei = en.indexOf(q);
    if (ni < 0 && ei < 0) continue;
    rows.push({ p, rank: ni === 0 || ei === 0 ? 0 : 1, name: String(p.name) });
  }
  rows.sort((a, b) => a.rank - b.rank || a.name.localeCompare(b.name, 'fi'));
  return rows.slice(0, limit).map((r) => r.p);
}

export function summarize(amountRows) {
  let netCents = 0n, vatCents = 0n, grossCents = 0n;
  const map = new Map();
  for (const r of amountRows) {
    if (!r) continue;
    netCents += r.netCents;
    vatCents += r.vatCents;
    grossCents += r.grossCents;
    map.set(r.rateTenths, (map.get(r.rateTenths) || 0n) + r.vatCents);
  }
  const vatByRate = [...map.entries()]
    .sort((a, b) => (a[0] < b[0] ? 1 : a[0] > b[0] ? -1 : 0))
    .map(([tenths, cents]) => ({ rateTenths: tenths, vatCents: cents }));
  return { netCents, vatCents, grossCents, vatByRate };
}

/** Mockin ja testien polku: määrä, veroton hinta ja kanta → rivin sentit (net-kaava). */
export function invoiceLineAmounts(quantity, unitPriceNet, vatRate) {
  const qty = parseScaled(quantity, 3);
  const price = parseScaled(unitPriceNet, 4);
  const tenths = rateTenthsOf(vatRate);
  if (qty == null || price == null || tenths == null || qty === 0n) return null;
  const a = lineAmountsFromScaled({ qtyMilli: qty, price10000: price, rateTenths: tenths });
  return {
    quantity: jsonDecimal(qty, 3),
    unit_price_net: jsonDecimal(price, 4),
    vat_rate: jsonDecimal(tenths, 1),
    line_net: jsonDecimal(a.netCents, 2),
    line_vat: jsonDecimal(a.vatCents, 2),
    line_gross: jsonDecimal(a.grossCents, 2),
  };
}

/** Tallennuspolku: price_basis gross käyttää verollista kaavaa, muuten verotonta. */
export function storedLineFromInput({ quantity, unitPriceNet, unitPriceGross, vatRate, priceBasis }) {
  const basis = priceBasis === 'gross' ? 'gross' : 'net';
  const a = amountsForLine({
    quantity,
    priceNet: unitPriceNet,
    priceGross: unitPriceGross,
    vatRate,
    basis,
  });
  const qty = parseScaled(quantity, 3);
  if (!a || qty == null) return null;
  return {
    price_basis: basis,
    quantity: jsonDecimal(qty, 3),
    unit_price_net: jsonDecimal(a.net10000, 4),
    unit_price_gross: jsonDecimal(a.gross10000, 4),
    vat_rate: jsonDecimal(a.rateTenths, 1),
    line_net: jsonDecimal(a.netCents, 2),
    line_vat: jsonDecimal(a.vatCents, 2),
    line_gross: jsonDecimal(a.grossCents, 2),
  };
}
