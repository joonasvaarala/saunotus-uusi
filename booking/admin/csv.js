// Raportin CSV-vienti (oma toteutus, ei kirjastoa): RFC 4180 (CRLF-rivinvaihto, kentät lainausmerkkeihin kun sisältävät erottimen, lainausmerkin tai rivinvaihdon,
// lainausmerkki kahdennetaan), UTF-8 BOM (Excel tunnistaa merkistön), erotin ; ja desimaalipilkku (suomalainen Excel/Procountor).
// Puhdas moduuli (ei DOM:ia) → testattavissa node --test:llä. Lataus selaimessa: downloadCsv().
export const CSV_COLUMNS = ['pvm', 'kuitti_no', 'tilaus_no', 'maksutapa', 'tuoteryhmä', 'tuote', 'määrä', 'brutto', 'alv_%', 'alv_€', 'netto', 'hyvitys'];
export const SEP = ';';
const round2 = (n) => Math.round((+n + Number.EPSILON) * 100) / 100;
// Rahasumma: 2 desimaalia, pilkku, ei tuhaterotinta ("1234,50"); tyhjä/virheellinen → "0,00"
export const fiMoney = (n) => { const v = round2(Number.isFinite(+n) ? +n : 0); return (Object.is(v, -0) ? 0 : v).toFixed(2).replace('.', ','); };
// Lukumäärä / prosentti: ei turhia nollia (25,5; 0; 13,5; 2)
export const fiNum = (n) => { const v = Number.isFinite(+n) ? +n : 0; return String(round2(v)).replace('.', ','); };
// Tekstikenttä: kaavainjektion esto (Excel tulkitsee =, +, -, @ alun kaavaksi) → eteen heittomerkki; sitten RFC 4180 -lainaus
export function csvText(v) {
  let s = v == null ? '' : String(v);
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
  return csvQuote(s);
}
export function csvQuote(s) { return /[";\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; }
const TEXT_COLS = new Set(['pvm', 'kuitti_no', 'tilaus_no', 'maksutapa', 'tuoteryhmä', 'tuote']);
// rivi (raporttirivi RPC:ltä) → CSV-sarakkeet. Hyvitys: hyvitetty summa (positiivinen); hyvitysrivillä brutto/alv/netto ovat negatiivisia.
export function lineToRow(l, methodLabel = (c) => c) {
  return {
    pvm: l.date, kuitti_no: l.receipt_no || '', tilaus_no: l.order_no ?? '', maksutapa: methodLabel(l.method), tuoteryhmä: l.group_label || l.group || '', tuote: l.product || '',
    määrä: fiNum(l.quantity ?? 1), brutto: fiMoney(l.gross), 'alv_%': fiNum(l.vat_rate), 'alv_€': fiMoney(l.vat), netto: fiMoney(l.net), hyvitys: fiMoney(l.refund || 0),
  };
}
export function toCsv(lines, { methodLabel, bom = true } = {}) {
  const out = [CSV_COLUMNS.join(SEP)];
  for (const l of lines) { const r = lineToRow(l, methodLabel); out.push(CSV_COLUMNS.map((c) => (TEXT_COLS.has(c) ? csvText(r[c]) : r[c])).join(SEP)); }
  return (bom ? '\uFEFF' : '') + out.join('\r\n') + '\r\n';
}
export function downloadCsv(filename, text) {
  const url = URL.createObjectURL(new Blob([text], { type: 'text/csv;charset=utf-8' }));
  const a = document.createElement('a'); a.href = url; a.download = filename; document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 4000);
}
