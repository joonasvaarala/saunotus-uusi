// Raportin CSV-vienti (oma toteutus, ei kirjastoa): RFC 4180 (CRLF-rivinvaihto, kentät lainausmerkkeihin kun sisältävät erottimen, lainausmerkin tai rivinvaihdon,
// lainausmerkki kahdennetaan), UTF-8 BOM (Excel tunnistaa merkistön), erotin ; ja desimaalipilkku (suomalainen Excel/Procountor).
// Puhdas moduuli (ei DOM:ia) → testattavissa node --test:llä. Lataus selaimessa: downloadCsv().
export const CSV_COLUMNS = ['tosite', 'pvm', 'asiakas', 'tuote', 'maara', 'netto', 'alv_%', 'alv_eur', 'brutto', 'maksutapa', 'tila', 'laji'];
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
const TEXT_COLS = new Set(['tosite', 'pvm', 'asiakas', 'tuote', 'maksutapa', 'tila', 'laji']);
const statusFi = (l) => (l.status === 'open' || l.status === 'avoin' ? 'avoin' : 'maksettu');
const kindFi = (l) => (l.kind === 'refund' || l.kind === 'refund_receipt' || l.kind === 'hyvitys' ? 'hyvitys' : l.kind === 'redemption' || l.kind === 'lunastus' ? 'lunastus' : 'myynti');
// Tapahtumaraportin rivi. Hyvitysrivin määrä, netto, ALV ja brutto ovat etumerkillisiä kuten kuitissa.
export function lineToRow(l, methodLabel = (c) => c) {
  const qty = l.kind === 'refund_receipt' ? -Math.abs(l.quantity ?? 1) : (l.quantity ?? 1);
  return {
    tosite: l.voucher || l.receipt_no || '', pvm: l.date, asiakas: l.customer || '', tuote: l.product || '',
    maara: fiNum(qty), netto: fiMoney(l.net), 'alv_%': fiNum(l.vat_rate), alv_eur: fiMoney(l.vat), brutto: fiMoney(l.gross),
    maksutapa: l.method ? methodLabel(l.method) : '', tila: statusFi(l), laji: kindFi(l),
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
