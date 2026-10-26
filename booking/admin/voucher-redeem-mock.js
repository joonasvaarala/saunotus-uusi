// booking_173: kokeilutilan (?mock=1) käsittelijät kumppanilahjakorttien lunastukselle. Vastaa palvelimen muotoa (booking._vc_admin_row):
// admin_order_voucher_claims, admin_unredeemed_voucher_claims, admin_set_voucher_claim_source, admin_mark_voucher_claim_redeemed, admin_set_voucher_redeem_urls.
// Ei verkkokutsuja. Arvaus samalla säännöllä kuin palvelin booking._vc_guess (ja shop/src/gift-logic.js guessSource): KK… = Kokemuskauppa (varma).
import { VCR_SOURCE_LABELS, VCR_URL_RE, VCR_URL_MAX } from './voucher-redeem-logic.js';

export function guessSource(code) {
  const n = String(code ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
  if (!n) return { source: null, confidence: null };
  if (/^KK/.test(n)) return { source: 'kokemuskauppa', confidence: 'high' };
  if (/^OK[0-9]{5}[A-Z]{3}$/.test(n)) return { source: 'offerilla', confidence: 'high' };
  if (/^[A-Z0-9]{12}$/.test(n) && /[^3479ACEFHJKLMNPRTUVWXY]/.test(n)) return { source: 'elamyslahjat', confidence: 'medium' };
  return { source: 'offerilla', confidence: 'low' };
}
const METHOD = (s) => (['kokemuskauppa', 'offerilla', 'elamyslahjat'].includes(s) ? `partner_voucher_${s}` : 'partner_voucher');
const METHOD_LABEL = (s) => (['kokemuskauppa', 'offerilla', 'elamyslahjat'].includes(s) ? `Lahjakortti – ${VCR_SOURCE_LABELS[s]}` : 'Kumppanin lahjakortti');
export const VCR_MOCK_URLS = { elamyslahjat: 'https://partnerit.elamyslahjat.fi/partnerit/', kokemuskauppa: 'https://partner.kokemuskauppa.com/p/login', offerilla: 'https://offerilla.com/minun-tilini/' };
const SEED = [['KK534536G5', 'kokemuskauppa'], ['OK12345ABC', 'offerilla'], ['B8DQ2ZG6S0XW', 'elamyslahjat'], ['KK771204Q1', 'offerilla'], ['7731-0092-55', 'offerilla']];

export function voucherRedeemMockHandlers({ st, need, err, now = new Date() }) {
  const isStaff = () => seed();
  st.vcrUrls ||= { ...VCR_MOCK_URLS };
  const seed = () => {
    if (st.vcr) return;
    const live = (st.reservations || []).filter((r) => r.status !== 'cancelled');
    const pick = [...live.filter((r) => r.payment_status !== 'paid'), ...live.filter((r) => r.payment_status === 'paid')].slice(0, SEED.length);
    for (const r of pick) r.payment_status = 'unpaid';   // kokeilutila: lahjakortilla maksettava tilaus on maksamatta kunnes koodi lunastetaan
    st.vcr = pick.map((r, i) => ({ id: 900 + i, code: SEED[i][0], source: SEED[i][1], status: 'open', order_id: r.order_id, created_at: new Date(now.getTime() - (i + 1) * 36e5 * 5).toISOString(), resolved_at: null, resolved_by: null, amount: null, payment_id: null }));
  };
  const res = (c) => (st.reservations || []).find((r) => r.order_id === c.order_id) || {};
  const row = (c) => {
    const r = res(c), g = guessSource(c.code), open = ['open', 'processing', 'problem'].includes(c.status);
    return {
      id: c.id, status: c.status, problem_code: null, code: c.code, code_masked: `…${c.code.replace(/[^A-Z0-9]/gi, '').slice(-4)}`,
      source: c.source, source_label: VCR_SOURCE_LABELS[c.source] || c.source,
      source_suggested: g.source, source_suggested_label: g.source ? VCR_SOURCE_LABELS[g.source] : null, suggestion_confidence: g.confidence, source_suggested_stored: g.source,
      payment_method: METHOD(c.source), payment_method_label: METHOD_LABEL(c.source), redeem_url: st.vcrUrls[c.source] || null,
      order_id: c.order_id, order_no: r.order_no ?? null, order_status: r.order_status ?? null, payment_status: r.payment_status ?? null,
      reservation_id: r.reservation_id ?? null, starts_at: r.starts_at ?? null, product_name: r.product_name ?? null, customer_name: r.customer_name ?? null,
      unpaid: c.status === 'redeemed' ? 0 : Number(r.total_gross ?? 0), voucher_value: null, amount: c.amount, payment_id: c.payment_id, partner_ref: null, needs_review: false,
      resolved_at: c.resolved_at, resolved_by: c.resolved_by, redeemed_via: c.status === 'redeemed' ? c.resolved_by : null, created_at: c.created_at,
      can_change_source: open, can_redeem: open,
    };
  };
  const canManage = () => st.perms.includes('giftcards.manage');
  const find = (id) => { seed(); const c = st.vcr.find((x) => x.id === +id); if (!c) throw err('not_found', 'Lunastuspyyntöä ei löydy'); return c; };
  return {
    admin_order_voucher_claims: (a) => {
      isStaff();
      const list = st.vcr.filter((c) => c.order_id === +a.p_order_id && ['open', 'processing', 'problem', 'redeemed'].includes(c.status)).sort((x, y) => y.id - x.id);
      return { ok: true, order_id: +a.p_order_id, can_manage: canManage(), claims: list.map(row) };
    },
    admin_unredeemed_voucher_claims: (a) => {
      isStaff();
      const src = a.p_source ? String(a.p_source) : null;
      if (src && !VCR_SOURCE_LABELS[src]) throw err('invalid_source', 'Tuntematon myyjä');
      const open = st.vcr.filter((c) => ['open', 'processing', 'problem'].includes(c.status));
      const counts = {}; for (const c of open) counts[c.source] = (counts[c.source] || 0) + 1;
      const list = open.filter((c) => !src || c.source === src).sort((x, y) => x.created_at.localeCompare(y.created_at)).slice(0, Math.max(1, Math.min(500, +a.p_limit || 200)));
      return { ok: true, source: src, counts, total: open.length, redeem_urls: { ...st.vcrUrls }, can_manage: canManage(), claims: list.map(row) };
    },
    admin_set_voucher_claim_source: (a) => {
      need('giftcards.manage');
      const v = String(a.p_source ?? '').trim().toLowerCase();
      if (!['kokemuskauppa', 'offerilla', 'elamyslahjat', 'partner_other'].includes(v)) throw err('invalid_source', 'Valitse myyjä');
      const c = find(a.p_id);
      if (!['open', 'processing', 'problem'].includes(c.status)) throw err('invalid_state', 'Pyyntöä ei voi enää muuttaa');
      if (c.source === v) throw err('unchanged', 'Myyjä on jo sama');
      const old = c.source; c.source = v;
      return { ok: true, id: c.id, old_source: old, source: v, payment_method: METHOD(v), payment_method_label: METHOD_LABEL(v) };
    },
    admin_mark_voucher_claim_redeemed: (a) => {
      need('giftcards.manage');
      const c = find(a.p_id);
      if (c.status === 'redeemed') return { ok: true, already: true, id: c.id, payment_id: c.payment_id, amount: c.amount, redeemed_via: c.resolved_by, resolved_at: c.resolved_at, payment_method: METHOD(c.source), payment_method_label: METHOD_LABEL(c.source) };
      if (!['open', 'processing', 'problem'].includes(c.status)) throw err('invalid_state', 'Pyyntö on jo käsitelty');
      // booking_174: arvo käsin (> 0, ≤ maksettava); pienempi → erotus maksulinkkinä (kuten palvelin: payment_link + sähköposti, ei kuittisähköpostia)
      const r = res(c), due = Number(r.total_gross ?? 0);
      if (a.p_amount != null && (!(+a.p_amount > 0) || Math.round(+a.p_amount * 100) !== +a.p_amount * 100)) throw err('invalid_amount', 'Lahjakortin arvon pitää olla yli 0 €');
      if (a.p_amount != null && +a.p_amount > due) throw err('voucher_exceeds_total', 'Lahjakortin arvo ylittää maksettavan summan');
      const amount = a.p_amount != null ? +a.p_amount : due;
      const difference = Math.round((due - amount) * 100) / 100;
      Object.assign(c, { status: 'redeemed', resolved_at: new Date().toISOString(), resolved_by: 'staff', amount, payment_id: 70000 + c.id });
      if (r.reservation_id) r.payment_status = difference > 0 ? 'partial' : 'paid';
      const link = difference > 0 ? { payment_id: 80000 + c.id, amount: difference, link_token: `mock-${c.id}`, link_path: `/maksa/?p=mock-${c.id}`, link_expires_at: null, status: 'pending', online_payment_enabled: true } : null;
      return { ok: true, already: false, id: c.id, payment_id: c.payment_id, amount, redeemed_via: 'staff', resolved_at: c.resolved_at, payment_method: METHOD(c.source), payment_method_label: METHOD_LABEL(c.source),
        voucher_value: amount, due, difference: link ? difference : null, payment_link: link, email_queued: !!link };
    },
    admin_set_voucher_redeem_urls: (a) => {
      need('settings.edit'); seed();
      const p = a.p && typeof a.p === 'object' ? a.p : {};
      for (const [k, v] of Object.entries(p)) {
        if (!['elamyslahjat', 'kokemuskauppa', 'offerilla'].includes(k)) throw err('invalid_setting', `Tuntematon myyjä ${k}`);
        const s = String(v ?? '').trim();
        if (s && (s.length > VCR_URL_MAX || !VCR_URL_RE.test(s))) throw err('invalid_url', 'Osoitteen pitää alkaa https://');
      }
      for (const [k, v] of Object.entries(p)) { const s = String(v ?? '').trim(); if (s) st.vcrUrls[k] = s; else delete st.vcrUrls[k]; }
      return { ok: true, redeem_urls: { ...st.vcrUrls } };
    },
  };
}
