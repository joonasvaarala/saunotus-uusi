// Yritysverkkolaskun kentät: y-tunnuksen tarkiste ja OVT-muoto (0037 + y-tunnuksen numerot).
// Sama sääntö palvelimella: booking._business_id_ok ja booking._ovt_ok (vain kun require_einvoice).

export function normBusinessId(v) {
  const x = String(v ?? '').replace(/\s/g, '').toUpperCase().replace(/^FI(\d{8})$/, '$1');
  let m = x.match(/^(\d{7})-?(\d)$/);
  if (m) return `${m[1]}-${m[2]}`;
  m = x.match(/^(\d{6})-?(\d)$/);
  if (m) return `0${m[1]}-${m[2]}`;
  return x;
}

export function validBusinessId(v) {
  const m = normBusinessId(v).match(/^(\d{7})-(\d)$/);
  if (!m) return false;
  const rem = [...m[1]].reduce((a, c, i) => a + +c * [7, 9, 10, 5, 8, 4, 2][i], 0) % 11;
  return rem !== 1 && (rem === 0 ? 0 : 11 - rem) === +m[2];
}

export function normOvt(v) {
  return String(v ?? '').replace(/\s/g, '').toUpperCase();
}

export function validOperator(v) {
  return /^[A-Z0-9]{3,35}$/.test(normOvt(v));
}

/** OVT alkaa 0037 ja kahdeksan seuraavaa numeroa ovat y-tunnuksen numerot. */
export function validOvt(address, businessId) {
  const ovt = normOvt(address);
  if (!/^0037\d{8,13}$/.test(ovt)) return false;
  const digits = normBusinessId(businessId).replace(/\D/g, '');
  if (digits && ovt.slice(4, 12) !== digits) return false;
  return true;
}

/** Kansallinen viitenumero: painot 7, 3, 1 oikealta, tarkiste (10 - summa%10)%10. Pohja vähintään 3 numeroa. */
export function fiReference(base) {
  let s = String(base ?? '').replace(/\D/g, '');
  if (!s) s = '0';
  s = s.padStart(Math.max(s.length, 3), '0');
  if (s.length > 19) throw new Error('invalid_reference');
  const w = [7, 3, 1];
  let acc = 0;
  for (let i = 0; i < s.length; i++) acc += +s[s.length - 1 - i] * w[i % 3];
  return s + String((10 - (acc % 10)) % 10);
}
