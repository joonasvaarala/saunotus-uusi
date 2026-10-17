// Lahjakorttien julkiset rajapinnat (kauppa). Sopimus: KOODARI_talous_A_D_fi.md §13.2. Palvelimen virheet ovat HTTP 200 + {ok:false, code, message}.
// Puuttuva RPC (404 / PGRST202 / 42883) → {ok:false, notReady:true}. Mock vain osoitteella ?mock=1.
import { normalizeCode } from './gift-logic.js';
import { createGiftMock } from './gift-mock.js';
export const GRPC = { packages: 'public_gift_card_packages', buy: 'public_buy_gift_card', check: 'public_check_gift_card', apply: 'public_apply_gift_card', orderCards: 'public_get_order_gift_cards', card: 'public_get_gift_card' };
const isMissingRpc = (e) => !!e && (e.status === 404 || e.code === 'PGRST202' || e.code === '42883' || /could not find the function/i.test(e.message || ''));
const wantsMock = () => typeof location !== 'undefined' && new URLSearchParams(location.search || '').get('mock') === '1';
const num = (v, d = 0) => (v == null || v === '' || Number.isNaN(+v) ? d : +v);
export function normPackages(r) {
  if (!r || r.ok === false) return r || { ok: false };
  return { ok: true, sale_enabled: r.sale_enabled === true, redeem_enabled: r.redeem_enabled === true, max_cards: num(r.max_cards_per_order, 10), currency: r.currency || 'EUR',
    packages: (r.packages || []).map((p) => ({ code: p.code, name: p.name, name_en: p.name_en || p.name, description: p.description || '', description_en: p.description_en || p.description || '', kind: p.kind, is_open: !!p.is_open,
      price: p.price == null ? null : num(p.price), min_amount: num(p.min_amount, 29), max_amount: num(p.max_amount, 500), persons: p.persons == null ? null : num(p.persons), vat_rate: num(p.vat_rate), valid_months: num(p.valid_months, 6), items: Array.isArray(p.items) ? p.items : [] })) };
}
export function createGiftApi({ rpc, mock = wantsMock(), mockFactory = () => createGiftMock({ delay: 120 }) } = {}) {
  const call = mock ? mockFactory().rpc : rpc;
  const run = (name, args) => (async () => { try { return await call(name, args); } catch (e) { if (!mock && isMissingRpc(e)) return { ok: false, notReady: true, rpc: name }; throw e; } })();
  let pk = null;
  return {
    mock,
    packages: (force = false) => (pk && !force ? pk : (pk = run(GRPC.packages, {}).then(normPackages).catch((e) => { pk = null; throw e; }))),
    buy: (args) => run(GRPC.buy, args),
    check: (code) => run(GRPC.check, { p_code: normalizeCode(code) }),
    apply: ({ token, code, amount }) => run(GRPC.apply, amount == null ? { p_token: token, p_code: normalizeCode(code) } : { p_token: token, p_code: normalizeCode(code), p_amount: amount }),
    orderCards: (token) => run(GRPC.orderCards, { p_token: token }),
    card: (publicToken) => run(GRPC.card, { p_public_token: publicToken }),
  };
}
// PDF-nappi (tilaussivu, kortti valmis): config.js giftCardPdf – oletus true (edge function gift-card-pdf on tuotannossa, sopimus §13.9); false piilottaa napin, merkkijono = toisen funktion nimi.
// Linkki: <functions>/gift-card-pdf?t=<kortin public_token>&lang=fi|en (sivun kieli; sama käytäntö kuin receipt-pdf). Ilman asetusta (S.giftCardPdf, config.js puuttuu) nappia ei näytetä.
export const pdfSetting = (S) => { const c = typeof window !== 'undefined' ? window.BOOKING_CONFIG?.giftCardPdf : undefined; return c !== undefined && c !== null ? c : S?.giftCardPdf; };
export const pdfEnabled = (S) => { const v = pdfSetting(S); return !!v && v !== 'false' && v !== '0'; };
export function pdfHref(S, cardToken, functionUrl, lang) {
  if (!pdfEnabled(S) || !cardToken) return '';
  const v = pdfSetting(S);
  return functionUrl(typeof v === 'string' && !['true', '1'].includes(v) ? v : 'gift-card-pdf', { t: cardToken, lang: lang === 'en' ? 'en' : 'fi' });
}
