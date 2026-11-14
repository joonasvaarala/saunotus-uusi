// HALL-LAHJAKORTIT-01: lahjakortin myynnin puhdas logiikka (ei DOMia, testattu booking/tests/giftcards-sale.test.mjs).
// Maksutapa "Maksulinkki sähköpostiin" = kaksi kutsua ilman migraatiota: admin_create_gift_card(p_payment_method='pay_later', p_locale) ja heti perään
// admin_create_payment_link(sendEmail). Jos linkin luonti epäonnistuu, kortti ja tilaus ovat jo olemassa: linkki luodaan uudelleen vain tilaukselle (ei uutta korttia).

export const GC_MODE_LINK = 'payment_link';   // vain käyttöliittymän valinta; palvelimelle menee 'pay_later'
export const GC_LOCALES = ['fi', 'en'];
export const gcLocale = (v) => (GC_LOCALES.includes(v) ? v : 'fi');

/** Käyttöliittymän maksuvalinta → luontikutsun maksutapa ja tieto siitä, luodaanko maksulinkki heti. */
export function saleMode(mode) {
  if (mode === 'free') return { paymentMethod: undefined, sendLink: false };
  if (mode === GC_MODE_LINK) return { paymentMethod: 'pay_later', sendLink: true };
  return { paymentMethod: mode, sendLink: false };
}

/** Kutsun virheen lyhyt koodi talteen (ei koko virhettä, jotta tulos on sarjallistettava). */
const errInfo = (e) => ({ code: e?.code || null, message: String(e?.message || e || '') });

/**
 * Luo kortti ja (maksulinkkitavassa) heti perään maksulinkki sähköpostiin.
 * create() heittää → ei korttia, virhe menee kutsujalle. createLink() heittää → kortti säilyy, palautetaan linkError.
 * Tulos: { res, link, linkError, orderId }
 */
export async function createCardAndLink({ mode, create, createLink }) {
  const m = saleMode(mode);
  const res = await create(m.paymentMethod);
  if (!m.sendLink) return { res, link: null, linkError: null, orderId: res?.order_id ?? null, wantsLink: false };
  return { res, ...(await tryLink(res?.order_id, createLink)), wantsLink: true };
}

/** Maksulinkin (uudelleen)luonti jo olemassa olevalle tilaukselle. Ei heitä: palauttaa { link, linkError, orderId }. */
export async function tryLink(orderId, createLink) {
  if (orderId == null) return { link: null, linkError: { code: 'no_order', message: 'Tilausta ei saatu vastauksessa' }, orderId: null };
  try { return { link: await createLink(orderId), linkError: null, orderId }; } catch (e) { return { link: null, linkError: errInfo(e), orderId }; }
}

/** Linkin tulos tulosdialogille: 'sent' (sähköposti jonossa), 'created' (linkki ilman viestiä, esim. kokeilutila), 'failed' (ei linkkiä), 'none' (ei maksulinkkitapaa). */
export function linkState(out) {
  if (!out?.wantsLink) return 'none';
  if (out.linkError || !out.link) return 'failed';
  if (out.link.mock) return 'created';
  return out.link.email_queued ? 'sent' : 'created';
}

/** Vaihe 1 (kortti ja maksu) -tarkistus; palauttaa virheavaimen tai null. */
export function step1Error({ pkg, amount, free, buyerName, buyerEmail, centsOk }) {
  if (pkg?.is_open && (!(amount >= pkg.min_amount && amount <= pkg.max_amount) || !centsOk)) return 'amount';
  if (!free && (!String(buyerName || '').trim() || !String(buyerEmail || '').trim())) return 'buyer';
  return null;
}
