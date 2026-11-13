// Yksi sisäänkäynti tilaukseen (Joonas 11.11.2026): päivänäkymä, kalenteri, varauslista, asiakas ja uusi varaus avaavat saman
// tilausnäkymän v3 (#/tilaukset/<nro>, views/order-view.js) eikä vanhaa tilauskorttimodaalia (views/order-card.js).
// Vanha kortti jää vain varalle, jos rivillä ei ole tilausnumeroa. "← Takaisin" palaa näkymään, josta tilaus avattiin.
const NO = /^[1-9][0-9]{0,11}$/;
let ret = null;

export const isOrderNo = (no) => NO.test(String(no ?? ''));
export const orderViewHash = (no) => `#/tilaukset/${encodeURIComponent(String(no))}`;

/** Avaa tilausnäkymän. replace=true (syvälinkki) ei jätä välivaihetta historiaan. Palauttaa false, jos tilausnumeroa ei ole. */
export function openOrderView(no, { replace = false, loc = globalThis.location } = {}) {
  if (!isOrderNo(no) || !loc) return false;
  const target = orderViewHash(no);
  ret = { from: loc.hash || '#/', orderNo: String(no), replace: !!replace };
  if (replace && typeof loc.replace === 'function') loc.replace(`${loc.pathname || ''}${loc.search || ''}${target}`);
  else loc.hash = target;
  return true;
}

/** Paluukohde tilausnäkymästä: lähtönäkymä (ei tilauslista), jos tilaus avattiin openOrderView:llä historiaan. */
export function orderReturn(no) {
  if (!ret || ret.orderNo !== String(no) || ret.replace) return null;
  // Tilauslistalta paluu hoidetaan listan resume-tilalla; Varaukset-välilehti (tab=reservations) palaa tänne
  if (/^#\/tilaukset(?:\/|$)/.test(ret.from) || (/^#\/tilaukset\?/.test(ret.from) && !/[?&]tab=reservations(?:&|$)/.test(ret.from))) return null;
  return { from: ret.from };
}
export function clearOrderReturn() { ret = null; }
