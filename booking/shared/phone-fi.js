// Suomalainen matkapuhelinnumero Vipps MobilePay ePayment -kenttään customer.phoneNumber (MSISDN, ei plus-merkkiä).
// Hyväksyy välilyönnit, yhdysmerkit, alkunollan ja maatunnuksen. Kiinteä liittymä ei kelpaa.

export function finnishMobileMsisdn(input) {
  let s = String(input ?? '').trim().replace(/[\s\-().]/g, '');
  if (!s) return null;
  if (s.startsWith('+')) s = s.slice(1);
  else if (s.startsWith('00')) s = s.slice(2);
  if (!/^\d+$/.test(s)) return null;
  if (s.startsWith('0')) s = '358' + s.slice(1);
  if (!s.startsWith('358')) return null;
  const national = s.slice(3);
  if (national.length < 6 || national.length > 12) return null;
  if (!(national.startsWith('4') || national.startsWith('50'))) return null;
  return s;
}
