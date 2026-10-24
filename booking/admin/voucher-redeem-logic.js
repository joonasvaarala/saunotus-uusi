// booking_173: kumppanilahjakorttien lunastus hallinnassa (tilauksen laatikko + Tarkista-sivun "Lunastamatta"-osio). Puhdas logiikka, testattava ilman DOMia.
// Myyjät: Kokemuskauppa (koodi alkaa KK), Offerilla, Elämyslahjat. Kiitoskauppa on poistunut valinnoista (vanhat rivit näkyvät nimellään).
// Palvelin: admin_order_voucher_claims, admin_unredeemed_voucher_claims, admin_set_voucher_claim_source, admin_mark_voucher_claim_redeemed, admin_set_voucher_redeem_urls.
export const VCR_SELLERS = ['kokemuskauppa', 'offerilla', 'elamyslahjat'];
export const VCR_CHOICES = [...VCR_SELLERS, 'partner_other'];   // hallinnon valinnat: myös "muu kumppani"
export const VCR_OPEN = ['open', 'processing', 'problem'];
export const VCR_RPC = {
  order: 'admin_order_voucher_claims', unredeemed: 'admin_unredeemed_voucher_claims', setSource: 'admin_set_voucher_claim_source',
  markRedeemed: 'admin_mark_voucher_claim_redeemed', setUrls: 'admin_set_voucher_redeem_urls',
};
export const VCR_SOURCE_LABELS = { kokemuskauppa: 'Kokemuskauppa', offerilla: 'Offerilla', elamyslahjat: 'Elämyslahjat', kiitoskauppa: 'Kiitoskauppa', partner_other: 'Muu kumppani' };
export const VCR_URL_RE = /^https:\/\/[A-Za-z0-9.-]+(\/[^\s<>"]*)?$/;   // sama kuin palvelimen admin_set_voucher_redeem_urls
export const VCR_URL_MAX = 300;

/** Myyjän nimi: palvelimen nimi, muuten varaetiketti, muuten koodi; ei koskaan null/undefined. */
export const sellerLabel = (code, serverLabel) => String(serverLabel || VCR_SOURCE_LABELS[code] || code || '–');

/** Lunastussivun linkki vain https-osoitteelle (muuten null → nappia ei näytetä). */
export function safeRedeemUrl(url) {
  const s = String(url ?? '').trim();
  return s && s.length <= VCR_URL_MAX && VCR_URL_RE.test(s) ? s : null;
}

/** Tarkistaa asetuslomakkeen arvot ennen tallennusta: tyhjä = poista. Palauttaa { ok, value } tai { ok:false, bad:[avaimet] }. */
export function checkRedeemUrls(values) {
  const out = {}, bad = [];
  for (const k of VCR_SELLERS) {
    const v = String(values?.[k] ?? '').trim();
    if (!v) { out[k] = ''; continue; }
    if (!safeRedeemUrl(v)) bad.push(k); else out[k] = v;
  }
  return bad.length ? { ok: false, bad } : { ok: true, value: out };
}

/** Järjestelmän arvaus vs. asiakkaan valinta: eroaako (vain varma/keskitason arvaus lasketaan). */
export function guessDiffers(row) {
  const g = row?.source_suggested, c = row?.source;
  if (!g || !c || g === c) return false;
  if (c === 'partner_other') return false;
  return ['high', 'medium'].includes(row?.suggestion_confidence);
}

/** Ryhmittelee rivit myyjittäin (VCR_SELLERS-järjestys, sitten muut). */
export function groupBySource(claims) {
  const by = new Map();
  for (const c of Array.isArray(claims) ? claims : []) {
    const k = c?.source || 'partner_other';
    if (!by.has(k)) by.set(k, []);
    by.get(k).push(c);
  }
  const order = [...VCR_SELLERS, ...[...by.keys()].filter((k) => !VCR_SELLERS.includes(k)).sort()];
  return order.filter((k) => by.has(k)).map((k) => ({ source: k, claims: by.get(k) }));
}

/** Suodatin-napit: kaikki + myyjät, joilla on rivejä tai jotka ovat perusmyyjiä. counts = palvelimen {myyjä: n}. */
export function filterChips(counts, active) {
  const c = counts && typeof counts === 'object' ? counts : {};
  const total = Object.values(c).reduce((s, n) => s + (Number(n) || 0), 0);
  const extra = Object.keys(c).filter((k) => !VCR_SELLERS.includes(k) && Number(c[k]) > 0).sort();
  return [{ source: null, n: total, active: !active }, ...[...VCR_SELLERS, ...extra].map((k) => ({ source: k, n: Number(c[k]) || 0, active: active === k }))];
}

/** Tilauksen/varauksen linkki hallinnassa. */
export const orderHref = (orderNo) => (orderNo ? `#/tilaukset?order=${encodeURIComponent(orderNo)}` : null);
// Varauksen ikkuna suoraan (Tilaukset › Varaukset, ?id=); ilman varaus-id:tä päivänäkymä
export const reservationHref = (row) => (/^\d+$/.test(String(row?.reservation_id ?? '')) ? `#/tilaukset?tab=reservations&id=${row.reservation_id}` : dayHref(row?.starts_at));
export const dayHref = (iso) => (iso ? `#/?d=${new Date(iso).toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' })}` : null);

/** RPC-argumentit. */
export const setSourceArgs = (row, source) => ({ p_id: row.id, p_source: source });
export const markArgs = (row, { amount, ref, note } = {}) => {
  const a = { p_id: row.id };
  if (amount != null && amount !== '') a.p_amount = Number(amount);
  if (ref && String(ref).trim()) a.p_partner_ref = String(ref).trim().slice(0, 100);
  if (note && String(note).trim()) a.p_note = String(note).trim().slice(0, 500);
  return a;
};

/** booking_174: lahjakortin arvo käsin ennen hyväksyntää. input = kentän teksti ("50", "50,5", "50.50"), due = maksettava (row.unpaid).
 *  Palauttaa { ok, value, difference, error } (sentit kokonaislukuina → ei liukulukuvirheitä). Säännöt kuten palvelimella:
 *  arvo > 0 ja enintään 2 desimaalia (muuten invalid_amount), arvo ≤ maksettava (muuten voucher_exceeds_total). Erotus > 0 → maksulinkki asiakkaalle. */
export function voucherValueCheck(input, due) {
  const s = String(input ?? '').trim().replace(/\s|\u00a0/g, '').replace('€', '').replace(',', '.');
  const dueC = Math.round(Number(due) * 100);
  if (!/^\d+(\.\d{1,2})?$/.test(s)) return { ok: false, error: 'invalid_amount' };
  const c = Math.round(Number(s) * 100);
  if (!(c > 0)) return { ok: false, error: 'invalid_amount' };
  if (Number.isFinite(dueC) && c > dueC) return { ok: false, error: 'voucher_exceeds_total', value: c / 100 };
  const diff = Number.isFinite(dueC) ? dueC - c : 0;
  return { ok: true, value: c / 100, difference: diff / 100, partial: diff > 0 };
}

/** Kentän oletusarvo maksettavasta summasta (suomalainen desimaalipilkku, aina 2 desimaalia). */
export const voucherValueDefault = (due) => (due != null && Number.isFinite(Number(due)) ? Number(due).toFixed(2).replace('.', ',') : '');

/** Lunastuksen argumentit arvokentästä: arvo sama kuin maksettava → ei p_amount (koko summa, kuten ennen); muuten p_amount. */
export function markArgsWithValue(row, check, due) {
  if (!check?.ok || Math.round(check.value * 100) === Math.round(Number(due) * 100)) return markArgs(row);
  return markArgs(row, { amount: check.value });
}
