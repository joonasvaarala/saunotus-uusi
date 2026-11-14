// Vahvistussivun otsikon laji. "Varausvahvistus" vain kun varaus on oikeasti vahvistettu
// (myös lasku ja maksu paikan päällä). Maksua odottava sivu on "Viimeistele varaus".

export function confirmPageKind(b, co, paysInvoice) {
  if (!b || b.ok === false) return 'missing';
  if (b.status === 'cancelled' || co?.cancelled) return 'cancelled';
  if (b.status === 'expired' || co?.expired) return 'expired';
  if (co?.preliminary) return 'preliminary';
  if (co?.awaiting || co?.processing) return 'finish';
  if (co?.confirmed || b.status === 'confirmed' || b.payment_status === 'paid' || b.payment_status === 'invoiced' || paysInvoice) return 'confirmed';
  if (b.status === 'pending') return 'finish';
  return 'confirmed';
}

// KAUPPA-VAHVISTUS-01: yksi otsikko (sivun H1), yksi tilamerkki ja yksi päätoiminto jokaisessa tilassa.
// Toinen otsikko (H2 "Kiitos varauksesta!") vain vahvistetussa tilassa; muissa tiloissa H1 ja tilamerkki sanovat jo saman.
export const showsThanksHeading = (kind) => kind === 'confirmed';

// Päätoiminto tilan mukaan: finish = maksu (maksuosion painikkeet), confirmed/preliminary = Hallitse varausta (tilaussivu),
// expired/cancelled = Yritä uudelleen (sama tuote ja aika) tai Tee uusi varaus. missing = ei toimintoa.
export function primaryAction(kind, { hasRetry = false } = {}) {
  if (kind === 'finish') return 'pay';
  if (kind === 'confirmed' || kind === 'preliminary') return 'manage';
  if (kind === 'expired' || kind === 'cancelled') return hasRetry ? 'retry' : 'new';
  return null;
}

// Tilaussivun osoite: sama token kuin vahvistussivulla (public_get_booking ja public_get_order käyttävät orders.public_token-avainta).
// orderHref = sivuston asetus { fi, en }; mock = kokeilutila (?mock=1 säilyy).
export function orderPageHref({ token, lang = 'fi', orderHref = null, mock = false } = {}) {
  const base = orderHref?.[lang] || (lang === 'en' ? '/en/order/' : '/tilaus/');
  return `${base}?t=${encodeURIComponent(token)}${mock ? '&mock=1' : ''}`;
}
