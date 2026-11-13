// Yhteinen varaus- ja tilauskortti: maksutila ja pääpainike ilman DOM-riippuvuuksia.
// Maksutila lasketaan tilauksen saldosta, ei varauksen mahdollisesti vanhentuneesta payment_status-kentästä.
import { reservationActions, arrivalActionsAllowed } from './reservation-dialog-logic.js';
import { visibleOrderActions } from './order-actions-logic.js';
import { orderInvoiceLocked } from './addon-lock-logic.js';
import { orderContents } from './order-lines-logic.js';

const EPS = 0.005;
const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };

/**
 * Yksi maksutila kortin yläosaan. Jos tilauksen saldo on saatavilla, se voittaa
 * varauksen payment_status-arvon (korjaa "Maksettu" + "Maksamatta 85 €" -ristiriidan).
 */
export function cardPaymentStatus(order = null, reservation = null) {
  const b = order?.balance;
  const hasBalance = !!(b && (b.total != null || b.unpaid != null || b.paid != null));
  if (hasBalance) {
    const unpaid = num(b.unpaid);
    const paid = num(b.paid);
    const refunded = num(b.refunded);
    const total = num(b.total);
    const pending = num(b.pending_link);
    const invoiced = !!(orderInvoiceLocked(order) || order?.payment_status === 'invoiced');
    if (unpaid > EPS) {
      return {
        kind: paid > EPS ? 'partial' : (invoiced ? 'invoiced_unpaid' : 'unpaid'),
        amount: unpaid, paid, refunded, total, pending,
        badgeClass: 'err', label: 'unpaid',
      };
    }
    if (refunded > EPS && paid <= EPS) {
      return { kind: 'refunded', amount: refunded, paid, refunded, total, pending, badgeClass: 'pay-refunded', label: 'refunded' };
    }
    if (refunded > EPS) {
      return { kind: 'partially_refunded', amount: paid, paid, refunded, total, pending, badgeClass: 'pay-partially_refunded', label: 'paid' };
    }
    if (invoiced) {
      return { kind: 'invoiced', amount: total || paid, paid, refunded, total, pending, badgeClass: 'pay-invoiced', label: 'invoiced' };
    }
    if (pending > EPS && paid <= EPS) {
      return { kind: 'pending', amount: pending, paid, refunded, total, pending, badgeClass: 'warn', label: 'pending' };
    }
    // 0 €:n tilaus (esim. yleinen vuoro vuosikortilla): ei "Maksettu 0,00 €" vaan "Ei maksettavaa" (Joonas 11.11.2026)
    if (total <= EPS && paid <= EPS) return { kind: 'free', amount: 0, paid, refunded, total, pending, badgeClass: 'muted', label: 'free' };
    return { kind: 'paid', amount: paid || total, paid, refunded, total, pending, badgeClass: 'ok', label: 'paid' };
  }
  const ps = order?.payment_status || reservation?.payment_status || null;
  const map = {
    unpaid: { kind: 'unpaid', badgeClass: 'err', label: 'unpaid' },
    pending: { kind: 'pending', badgeClass: 'warn', label: 'pending' },
    partially_paid: { kind: 'partial', badgeClass: 'warn', label: 'unpaid' },
    paid: { kind: 'paid', badgeClass: 'ok', label: 'paid' },
    refunded: { kind: 'refunded', badgeClass: 'pay-refunded', label: 'refunded' },
    partially_refunded: { kind: 'partially_refunded', badgeClass: 'pay-partially_refunded', label: 'paid' },
    failed: { kind: 'failed', badgeClass: 'err', label: 'failed' },
    invoiced: { kind: 'invoiced', badgeClass: 'pay-invoiced', label: 'invoiced' },
  };
  const row = map[ps] || { kind: ps || 'unknown', badgeClass: 'pay-unpaid', label: ps || 'unpaid' };
  const amount = reservation?.total_gross != null ? num(reservation.total_gross) : (order?.total != null ? num(order.total) : 0);
  if (row.kind === 'paid' && amount <= EPS) return { kind: 'free', badgeClass: 'muted', label: 'free', amount: 0, paid: 0, refunded: 0, total: 0, pending: 0 };
  return { ...row, amount, paid: 0, refunded: 0, total: amount, pending: 0 };
}

/**
 * Yksi tilanteen mukainen pääpainike. Muut toiminnot ovat toissijaisia tai vaarallisia.
 * Ei poista olemassa olevia toimintoja: ne siirtyvät secondary- tai danger-listaan.
 *
 * Ensisijaisuus:
 *  1) odottava varaus → Vahvista
 *  2) maksamatta → Lähetä maksulinkki (Ota maksu toissijaisena)
 *  3) ennen saapumista (varauspäivä alkanut, vahvistettu, ei vielä saapunut) → Merkitse saapuneeksi
 *  4) saapunut+maksettu tai pelkkä verkkokauppatilaus → ei tummaa päätoimintoa
 */
export function cardActions(reservation, {
  can = () => true, order = null, rawOrder = null, flowEnabled = false, now = new Date(),
} = {}) {
  const base = reservation
    ? reservationActions(reservation, { can, order, rawOrder, flowEnabled, now })
    : emptyReservationActions(order, { can });
  const pay = cardPaymentStatus(order, reservation);
  const unpaid = pay.kind === 'unpaid' || pay.kind === 'partial' || pay.kind === 'invoiced_unpaid';
  const linkOk = !!base.payment?.createLink;
  const arriving = !!(reservation && arrivalActionsAllowed(reservation, now) && can('bookings.manage'));
  const pending = reservation?.status === 'pending' && can('bookings.manage');

  let primary = [];
  if (pending) primary = ['confirm'];
  else if (unpaid && linkOk) primary = ['createLink'];
  else if (arriving) primary = ['arrive'];

  const used = new Set(primary);
  const secondary = [];
  const push = (key) => { if (key && !used.has(key)) { used.add(key); secondary.push(key); } };

  if (unpaid && (base.payment?.recordPayment || (!reservation && visibleOrderActions(order || {}, { canRefund: false, canAdd: false }).includes('recordPayment')))) {
    push('recordPayment');
  }
  // reservationActions laittoi nämä primaryyn: siirrä jäljelle jäävät toissijaisiksi
  for (const key of base.primary || []) push(key);
  for (const key of base.secondary || []) {
    if (key === 'cancel') continue;
    push(key);
  }
  const danger = [];
  if ((base.secondary || []).includes('cancel')) danger.push('cancel');
  if (!reservation && order) {
    const vis = visibleOrderActions(order, {
      canRefund: typeof can === 'function' ? !!can('payments.refund') : false,
      canAdd: typeof can === 'function' ? !!can('bookings.manage') : false,
    });
    if (vis.includes('addToOrder')) push('addPurchase');
    if (vis.includes('refund')) danger.push('refund');
  }

  return {
    ...base,
    primary,
    secondary,
    danger,
    payment: base.payment,
    pay,
  };
}

function emptyReservationActions(order, { can }) {
  const vis = visibleOrderActions(order || {}, {
    canRefund: !!can('payments.refund'),
    canAdd: !!can('bookings.manage'),
  });
  const unpaid = num(order?.balance?.unpaid) > EPS;
  return {
    primary: [],
    secondary: [],
    payment: {
      show: !!order,
      rows: order?.balance || null,
      createLink: vis.includes('createPaymentLink'),
      recordPayment: vis.includes('recordPayment'),
      openOrder: !!can('payments.manage'),
    },
    editAddons: false,
    note: null,
    move: null,
    unpaid,
  };
}

/** Osioiden yhden rivin yhteenvedot (avaimet täytetään näkymässä). */
export function cardSectionSummaries(order, reservation = null) {
  const c = order ? orderContents(order) : { reservations: reservation ? [reservation] : [], lines: [], emptyKey: null };
  const addonQty = (c.reservations || []).reduce((n, r) => n + (r.addons || []).reduce((s, a) => s + Math.max(0, Number(a.quantity) || 0), 0), 0);
  const addonSum = (c.reservations || []).reduce((n, r) => n + (r.addons || []).reduce((s, a) => s + num(a.line_total), 0), 0);
  const lineCount = (c.lines || []).length;
  const lineSum = (c.lines || []).reduce((s, l) => s + num(l.line_total), 0);
  const pay = cardPaymentStatus(order, reservation);
  const receipts = order?.receipts || [];
  const sent = receipts.filter((x) => x.sent_at);
  const note = reservation?.notes || order?.internal_note || '';
  return {
    addons: {
      kind: reservation ? 'addons' : 'items',
      count: addonQty + lineCount,
      amount: addonSum + lineSum,
      empty: addonQty + lineCount === 0,
    },
    payments: { kind: pay.label, amount: pay.amount, pending: pay.pending },
    messages: { count: sent.length, empty: sent.length === 0 },
    history: { createdAt: order?.created_at || reservation?.created_at || null, source: order?.source_channel || reservation?.source_channel || reservation?.source || null },
    notes: { text: String(note || '').trim(), empty: !String(note || '').trim() },
  };
}

const round2 = (v) => Math.round((Number(v) + Number.EPSILON) * 100) / 100;

/**
 * Kortin yläosan lisäostorivi varausrivin alle, esim. "1 × Saunavihta · 2 × Pyyhe".
 * Tyhjä merkkijono, jos lisäostoja ei ole (rivi jätetään pois).
 */
export function cardAddonLine(addons = []) {
  return (addons || [])
    .filter((a) => a && String(a.name || '').trim() && Number(a.quantity) > 0)
    .map((a) => `${Number(a.quantity)} × ${String(a.name).trim()}`)
    .join(' · ');
}

/**
 * Tilauserittely tilausriveistä (admin_get_order → items[]): rivi jokaiselle tuotteelle
 * (pääpalvelu ja sen lisäostot heti sen alla, sitten muut rivit), ALV-kanta ja -euromäärä
 * sekä ALV-erittely kannoittain. Hinnat ja ALV tulevat sellaisinaan tilausriviltä
 * (unit_price_gross, line_total_gross, vat_rate, line_vat, line_net); mitään ei lasketa uudelleen
 * paitsi jos rivin line_vat puuttuu, jolloin ALV johdetaan rivin omasta kannasta (sama kaava kuin
 * maksuriveillä). Rivi, jolta ALV-kanta puuttuu (vat_known === false), jää ALV-erittelyn ulkopuolelle.
 */
export function orderBreakdown(order) {
  let items = (order?.items || []).filter(Boolean);
  // Varalla: tilaus, jolla on varaus mutta ei tilausrivejä (tuotannossa harvinainen). Varausriviltä ei tule ALV-kantaa.
  if (!items.length && (order?.reservations || []).length) {
    items = [];
    (order.reservations || []).forEach((x, i) => {
      const pid = x.item_id ?? `r${i}`;
      items.push({ id: pid, parent_item_id: null, kind: 'reservation', name: x.product_name, quantity: 1, unit_price: num(x.item_total), line_total: num(x.item_total), vat_rate: null, vat_known: false });
      (x.addons || []).forEach((a, k) => items.push({ id: `${pid}-${k}`, parent_item_id: pid, kind: 'addon', name: a.name, quantity: a.quantity, unit_price: a.unit_price, line_total: a.line_total,
        vat_rate: a.vat_known === false ? null : (a.vat_rate ?? null), vat_known: a.vat_known !== false && a.vat_rate != null }));
    });
  }
  const cancelled = new Set((order?.reservations || []).filter((x) => x.status === 'cancelled' && x.item_id != null).map((x) => x.item_id));
  const ids = new Set(items.map((x) => x.id));
  const byId = (a, b) => (Number(a.id) || 0) - (Number(b.id) || 0);
  const top = items.filter((x) => x.parent_item_id == null || !ids.has(x.parent_item_id)).sort(byId);
  const ordered = [];
  for (const it of top) {
    ordered.push({ it, child: false });
    for (const c of items.filter((x) => x.parent_item_id === it.id && x !== it).sort(byId)) ordered.push({ it: c, child: true });
  }
  const rows = ordered.map(({ it, child }) => {
    const gross = num(it.line_total);
    const known = it.vat_known !== false && it.vat_rate != null;
    const rate = known ? num(it.vat_rate) : null;
    const vat = !known ? null : (it.line_vat != null ? num(it.line_vat) : round2(gross - gross / (1 + rate / 100)));
    const net = !known ? null : (it.line_net != null ? num(it.line_net) : round2(gross - vat));
    return {
      id: it.id ?? null, kind: it.kind || 'other', name: it.name || '', child,
      cancelled: cancelled.has(it.id) || (child && cancelled.has(it.parent_item_id)),
      quantity: num(it.quantity) || 1, unit_price: num(it.unit_price), gross, vat_rate: rate, vat, net,
    };
  });
  const rates = new Map();
  let unknownVat = 0;
  for (const row of rows) {
    if (row.vat_rate == null) { unknownVat += 1; continue; }
    const k = row.vat_rate;
    const cur = rates.get(k) || { rate: k, gross: 0, vat: 0, net: 0 };
    cur.gross = round2(cur.gross + row.gross); cur.vat = round2(cur.vat + row.vat); cur.net = round2(cur.net + row.net);
    rates.set(k, cur);
  }
  const sum = round2(rows.reduce((s, x) => s + x.gross, 0));
  const b = order?.balance;
  const total = b && b.total != null ? num(b.total) : sum;
  return {
    rows,
    total,
    rowsTotal: sum,
    vatByRate: [...rates.values()].sort((a, b2) => b2.rate - a.rate),
    unknownVat,
    empty: rows.length === 0,
  };
}

/** ALV-kanta suomalaisittain: 25.5 → "25,5 %", 0 → "0 %". */
export function vatRateLabel(rate) {
  if (rate == null || !Number.isFinite(Number(rate))) return '';
  return `${String(round2(rate)).replace('.', ',')} %`;
}
