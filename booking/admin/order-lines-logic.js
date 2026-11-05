// Hallinnan tilausnäkymä: mitä tilauksella on ostettu. Varaukset näytetään omina riveinään (aika, henkilöt, lisäpalvelut);
// kaikki muut tilausrivit (lahjakortti, tuote, vapaa rivi, kulu, alennus, irrallinen lisäpalvelu) listataan erikseen, jotta
// esim. pelkän lahjakortin tilaus ei näytä tyhjältä. Puhdas moduuli: ei DOMia → node --test.
// Lähde: admin_get_order → items[] (id, parent_item_id, kind, name, quantity, unit_price, line_total, vat_rate) ja reservations[] (item_id, addons[]).
export const LINE_KINDS = ['reservation', 'gift_card', 'product', 'addon', 'custom', 'fee', 'discount'];

// Rivit, jotka varausrivi jo näyttää: varauksen oma tilausrivi ja sen alle kuuluvat lisäpalvelut (reservations[].addons).
export function coveredItemIds(o) {
  const resItems = new Set((o?.reservations || []).map((r) => r.item_id).filter((x) => x != null));
  const covered = new Set(resItems);
  for (const it of o?.items || []) if (it.kind === 'addon' && it.parent_item_id != null && resItems.has(it.parent_item_id)) covered.add(it.id);
  return covered;
}

// Muut kuin varausriveillä näkyvät tilausrivit, palvelimen järjestyksessä (id). Varausrivi, jonka varaus ei näy (esim. tuotu tai piilotettu), näkyy myös tässä.
export function orderExtraLines(o) {
  const covered = coveredItemIds(o);
  return (o?.items || []).filter((it) => !covered.has(it.id)).map((it) => ({
    id: it.id, kind: LINE_KINDS.includes(it.kind) ? it.kind : 'other', name: it.name || '', quantity: Number(it.quantity) || 1,
    unit_price: Number(it.unit_price) || 0, line_total: Number(it.line_total) || 0, vat_rate: Number(it.vat_rate) || 0, child: it.parent_item_id != null,
  }));
}

// Osion otsikon avain: pelkät varaukset → Varaukset, pelkät ostokset → Ostokset, molemmat → Varaukset ja ostokset.
export function orderContents(o) {
  const reservations = o?.reservations || [], lines = orderExtraLines(o);
  const titleKey = reservations.length && lines.length ? 'order.contentsBoth' : lines.length ? 'order.purchases' : 'order.reservations';
  const emptyKey = reservations.length || lines.length ? null : 'order.noContents';
  return { reservations, lines, titleKey, emptyKey };
}
