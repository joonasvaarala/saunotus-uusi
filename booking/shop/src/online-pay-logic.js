// Verkkomaksu: maksutavan valinta ja sallitut paluuosoitteet. Asiakkaalle ei näytetä välittäjän nimeä.
export const PAY_METHODS = ['paymentInitiation', 'cardPayments', 'applePay', 'googlePay', 'mobilePay'];
const HOSTS = new Set(['sandbox-stargate.montonio.com', 'stargate.montonio.com', 'sandbox-gateway.montonio.com', 'gateway.montonio.com', 'pay.montonio.com']);

/** public_payment_options / public_checkout_payment_options: code online, tai null. */
export function onlineMethod(methods) {
  return (Array.isArray(methods) ? methods : []).find((m) => m && m.code === 'online') || null;
}

/** Testitilan tapa vain testiympäristössä. Tuotannossa test=true piilotetaan. */
export function showOnline(method, env = {}) {
  if (!method || method.code !== 'online') return false;
  if (method.test === true && !env.testUi) return false;
  return true;
}

/** Viisi maksutapaa. Palvelimen choices, muuten kiinteä järjestys. */
export function onlineChoices(method) {
  const raw = Array.isArray(method?.choices) ? method.choices : [];
  const list = raw.filter((c) => c && PAY_METHODS.includes(c.method));
  const src = list.length ? list : PAY_METHODS.map((code) => ({ method: code }));
  return src.map((c) => ({ method: c.method, label: c.label || '', labelEn: c.label_en || c.label || '' }));
}

/** https-isännät, joilla maksusivu saa olla, ja saman sivuston mock-paluu (?mock=1&pay=online). */
export function safeOnlineRedirect(url, origin) {
  let u;
  try { u = new URL(String(url || '')); } catch { return null; }
  if (u.protocol === 'https:' && HOSTS.has(u.hostname)) return u.href;
  const here = origin || (typeof location !== 'undefined' ? location.origin : '');
  if (here && u.origin === here && u.searchParams.get('mock') === '1' && u.searchParams.get('pay') === 'online') return u.href;
  return null;
}
