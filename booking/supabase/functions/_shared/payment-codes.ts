// Maksukoodien puhdas muodostus. Ei muuta laskun summia, viitettä tai eräpäivää:
// arvot vain validoidaan ja esitetään Finanssiala ry:n pankkiviivakoodioppaan v5.3
// sekä EPC069-12 SCT QR -suosituksen mukaisesti.

export interface PaymentCodeInput {
  iban: unknown;
  amount: unknown;
  reference: unknown;
  dueDate: unknown;
}

export interface VirtualBarcode {
  version: "4" | "5";
  value: string;
}

const compact = (v: unknown) => String(v ?? "").replace(/\s+/g, "").toUpperCase();

const mod97 = (value: string): number => {
  let rem = 0;
  for (const ch of value) {
    const part = ch >= "A" && ch <= "Z" ? String(ch.charCodeAt(0) - 55) : ch;
    if (!/^\d{1,2}$/.test(part)) return -1;
    for (const d of part) rem = (rem * 10 + Number(d)) % 97;
  }
  return rem;
};

export const normalizeIban = (value: unknown): string => compact(value);

export function isValidIban(value: unknown): boolean {
  const iban = normalizeIban(value);
  if (!/^[A-Z]{2}\d{2}[A-Z0-9]{11,30}$/.test(iban)) return false;
  return mod97(iban.slice(4) + iban.slice(0, 4)) === 1;
}

export function isValidBic(value: unknown): boolean {
  return /^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$/.test(compact(value));
}

export function isValidFinnishReference(value: unknown): boolean {
  const ref = compact(value);
  if (!/^\d{4,20}$/.test(ref)) return false;
  const body = ref.slice(0, -1);
  const weights = [7, 3, 1];
  let sum = 0;
  for (let i = 0; i < body.length; i++) sum += Number(body[body.length - 1 - i]) * weights[i % 3];
  return Number(ref.at(-1)) === (10 - sum % 10) % 10;
}

export function isValidRfReference(value: unknown): boolean {
  const ref = compact(value);
  return /^RF\d{2}[A-Z0-9]{1,21}$/.test(ref) && mod97(ref.slice(4) + ref.slice(0, 4)) === 1;
}

const amountField = (amount: unknown): string | null => {
  const n = Number(amount);
  if (!Number.isFinite(n) || n <= 0) return null;
  const cents = Math.round(n * 100);
  return cents <= 99_999_999 ? String(cents).padStart(8, "0") : null;
};

const dateField = (value: unknown): string | null => {
  const iso = String(value ?? "");
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!m) return null;
  const date = new Date(`${iso}T00:00:00Z`);
  if (
    Number.isNaN(date.valueOf()) ||
    date.getUTCFullYear() !== Number(m[1]) ||
    date.getUTCMonth() + 1 !== Number(m[2]) ||
    date.getUTCDate() !== Number(m[3])
  ) return null;
  return `${m[1].slice(2)}${m[2]}${m[3]}`;
};

/** Finanssiala v5.3: 54-numeroinen virtuaaliviivakoodi, versio 4 tai 5. */
export function buildVirtualBarcode(input: PaymentCodeInput): VirtualBarcode | null {
  const iban = normalizeIban(input.iban);
  const amount = amountField(input.amount);
  const due = dateField(input.dueDate);
  const ref = compact(input.reference);
  if (!/^FI\d{16}$/.test(iban) || !isValidIban(iban) || !amount || !due) return null;

  if (isValidFinnishReference(ref)) {
    const value = `4${iban.slice(2)}${amount}000${ref.padStart(20, "0")}${due}`;
    return value.length === 54 ? { version: "4", value } : null;
  }
  if (isValidRfReference(ref) && /^RF\d+$/.test(ref)) {
    const digits = ref.slice(2);
    if (digits.length > 23) return null;
    const rfField = digits.slice(0, 2) + digits.slice(2).padStart(21, "0");
    const value = `5${iban.slice(2)}${amount}${rfField}${due}`;
    return value.length === 54 ? { version: "5", value } : null;
  }
  return null;
}

/** EPC069-12 v002 SCT QR -sisältö. BIC vaaditaan tässä laskupohjassa omistajan pyynnön mukaisesti. */
export function buildEpcQrPayload(input: {
  bic: unknown;
  beneficiary: unknown;
  iban: unknown;
  amount: unknown;
  reference?: unknown;
  fallbackRemittance?: unknown;
}): string | null {
  const bic = compact(input.bic);
  const iban = normalizeIban(input.iban);
  const beneficiary = String(input.beneficiary ?? "").replace(/[\r\n]+/g, " ").trim().slice(0, 70);
  const amount = Number(input.amount);
  if (!isValidBic(bic) || !isValidIban(iban) || !beneficiary || !Number.isFinite(amount) || amount <= 0 || amount > 999_999_999.99) return null;

  const reference = compact(input.reference);
  const structured = isValidRfReference(reference) ? reference : "";
  const remittance = structured
    ? ""
    : (isValidFinnishReference(reference) ? reference : String(input.fallbackRemittance ?? "").replace(/[\r\n]+/g, " ").trim()).slice(0, 140);
  return ["BCD", "002", "1", "SCT", bic, beneficiary, iban, `EUR${amount.toFixed(2)}`, "", structured, remittance].join("\n");
}

// ISO/IEC 15417 Code 128 -symbolien vuorottelevat palkki-/välileveydet.
export const CODE128_PATTERNS = [
  "212222", "222122", "222221", "121223", "121322", "131222", "122213", "122312", "132212", "221213", "221312", "231212",
  "112232", "122132", "122231", "113222", "123122", "123221", "223211", "221132", "221231", "213212", "223112", "312131",
  "311222", "321122", "321221", "312212", "322112", "322211", "212123", "212321", "232121", "111323", "131123", "131321",
  "112313", "132113", "132311", "211313", "231113", "231311", "112133", "112331", "132131", "113123", "113321", "133121",
  "313121", "211331", "231131", "213113", "213311", "213131", "311123", "311321", "331121", "312113", "312311", "332111",
  "314111", "221411", "431111", "111224", "111422", "121124", "121421", "141122", "141221", "112214", "112412", "122114",
  "122411", "142112", "142211", "241211", "221114", "413111", "241112", "134111", "111242", "121142", "121241", "114212",
  "124112", "124211", "411212", "421112", "421211", "212141", "214121", "412121", "111143", "111341", "131141", "114113",
  "114311", "411113", "411311", "113141", "114131", "311141", "411131", "211412", "211214", "211232", "2331112",
] as const;

/** Code 128 C:n arvot: START C, numeroparit, modulo 103 -tarkiste, STOP. */
export function code128CValues(value: string): number[] | null {
  if (!/^\d+$/.test(value) || value.length % 2 !== 0) return null;
  const data = value.match(/\d{2}/g)!.map(Number);
  let weighted = 105;
  data.forEach((v, i) => { weighted += v * (i + 1); });
  return [105, ...data, weighted % 103, 106];
}

export function code128CChecksum(value: string): number | null {
  const values = code128CValues(value);
  return values ? values.at(-2)! : null;
}
