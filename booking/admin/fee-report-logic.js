// Maksuvälittäjän provisio: sama poimintajärjestys kuin booking._extract_provider_fee (booking_216).
// Ensimmäinen tunnistettu kenttä voittaa. Juuren amount/grandTotal on maksun summa, ei provisio.
// Sisäkkäinen fees/settlement/pricing saa käyttää amount/total/value -kenttiä.
import { csvText, fiMoney } from './csv.js';

export const EURO_KEYS = ['provider_fee', 'providerFee', 'merchantFee', 'merchant_fee', 'feeAmount', 'fee_amount', 'commissionAmount', 'commission_amount', 'commission', 'provision', 'serviceFee', 'service_fee', 'paymentFee', 'payment_fee', 'fee'];
export const CENT_KEYS = ['feeCents', 'fee_cents', 'merchantFeeCents', 'merchant_fee_cents', 'commissionCents', 'commission_cents'];
export const NEST_KEYS = ['fees', 'settlement', 'pricing', 'merchantFees', 'merchant_fees'];
const NEST_EURO = [...EURO_KEYS, 'amount', 'total', 'value'];
const NEST_CENT = [...CENT_KEYS, 'amount_cents', 'amountCents'];

export const FEE_CSV_HEADER = 'palvelu;maksutapa;laji;lahde;kpl;brutto;provisio;netto';

const PROVIDER_LABELS = { montonio: 'Montonio', visma_pay: 'Visma Pay', mobilepay: 'MobilePay', manual: 'Käsin', johku: 'Johku' };

export function providerAdminLabel(code, label) {
  if (label) return String(label);
  return PROVIDER_LABELS[code] || String(code || '');
}

function numOf(v) {
  if (v == null || v === '') return null;
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  if (typeof v === 'string') {
    const t = v.trim().replace(',', '.');
    if (/^-?\d+(\.\d+)?$/.test(t)) return Number(t);
  }
  return null;
}
function round4(n) { return Math.round((n + Number.EPSILON) * 10000) / 10000; }
export function round2(n) { return Math.round((n + Number.EPSILON) * 100) / 100; }

export function extractProviderFee(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  for (const k of EURO_KEYS) {
    const v = numOf(raw[k]);
    if (v != null) return round4(v);
  }
  for (const k of CENT_KEYS) {
    const v = numOf(raw[k]);
    if (v != null) return round4(v / 100);
  }
  for (const n of NEST_KEYS) {
    const obj = raw[n];
    if (!obj || typeof obj !== 'object' || Array.isArray(obj)) continue;
    for (const k of NEST_EURO) {
      const v = numOf(obj[k]);
      if (v != null) return round4(v);
    }
    for (const k of NEST_CENT) {
      const v = numOf(obj[k]);
      if (v != null) return round4(v / 100);
    }
  }
  return null;
}

export function parseFeeAmount(raw, max) {
  const t = String(raw ?? '').trim().replace(/\s/g, '').replace(',', '.');
  if (!/^\d+(\.\d{1,4})?$/.test(t)) return null;
  const n = Number(t);
  if (!Number.isFinite(n) || n < 0 || n > max) return null;
  return round4(n);
}

export function quoteFee(amount, rule) {
  return round2(Number(rule.fixed_eur) + Number(amount) * Number(rule.percent) / 100);
}

export function pickFeeRule(rules, provider, method) {
  const hits = (rules || []).filter((r) => r.active !== false && r.provider === provider && (r.method === method || r.method === '*'));
  hits.sort((a, b) => (a.method === method ? 0 : 1) - (b.method === method ? 0 : 1) || (a.id || 0) - (b.id || 0));
  return hits[0] || null;
}

export function lineFee(row, rules) {
  if (row.provider_fee != null && row.provider_fee !== '') return { basis: 'actual', fee: round2(row.provider_fee) };
  const parsed = extractProviderFee(row.raw);
  if (parsed != null) return { basis: 'actual', fee: round2(parsed) };
  const rule = pickFeeRule(rules, row.provider, row.method);
  if (!rule) return { basis: 'missing', fee: null };
  return { basis: 'estimated', fee: quoteFee(row.gross, rule) };
}

export function settledNet(direction, gross, fee) {
  if (fee == null) return null;
  const g = round2(gross);
  const f = round2(fee);
  return direction === 'refund' ? round2(-(g + f)) : round2(g - f);
}

const basisFi = (b) => (b === 'actual' ? 'toteutunut' : b === 'estimated' ? 'arvio' : 'puuttuu');

export function feesToCsv(report) {
  const lines = [FEE_CSV_HEADER];
  for (const r of report?.rows || []) {
    lines.push([
      csvText(r.provider_label || r.provider || ''),
      csvText(r.method_label || r.method || ''),
      r.direction === 'refund' ? 'hyvitys' : 'maksu',
      basisFi(r.basis),
      String(r.count ?? 0),
      fiMoney(r.gross),
      r.fee == null ? '' : fiMoney(r.fee),
      r.net == null ? '' : fiMoney(r.net),
    ].join(';'));
  }
  return `\uFEFF${lines.join('\r\n')}\r\n`;
}
