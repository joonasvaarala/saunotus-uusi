// Maksuvalinta varausvahvistussivulle (/varaa/vahvistus/#token): "Maksa MobilePaylla" + "Maksa lahjakortilla" (yksi "Lahjakortin koodi" -kenttä) – SAMAT moduulit ja RPC:t kuin tilaussivulla:
//   public_payment_options + mobilepay-start / mobilepay-notify (mobilepay-api/-ui/-logic), public_gift_card_packages + public_resolve_gift_code / public_apply_gift_card /
//   public_submit_voucher_claim / public_get_order_voucher_claims (gift-api, order-gift.js redeemSection + claimsSection). Tämä tiedosto vain kokoaa ne yhteen osioon; ei kopioi logiikkaa.
// Puuttuva RPC / virhe / ei sallittu → ei mitään näkyviin (sivu ennallaan). Ei oleteta maksutapaa: kaikki päätökset tulevat palvelimelta (public_payment_options, redeem_enabled).
import { functionUrl } from './sb.js';
import { createMobilepayApi } from './mobilepay-api.js';
import { normOptions, shouldShowButton, testUiEnabled } from './mobilepay-logic.js';
import { payBlock } from './mobilepay-ui.js';
import { createGiftApi } from './gift-api.js';
import { redeemSection, claimsSection } from './order-gift.js';
import { h, makeFmt } from './gift-ui.js';
import { pt } from './pay-choices-texts.js';

const PAYABLE = ['confirmed', 'pending'];
let seq = 0;

// Lataa maksutavat: MobilePay (public_payment_options) ja lahjakortti (redeem_enabled + lunastuspyynnöt). token = null → vain yleistieto (kassa, ennen varausta).
export async function loadPayChoices({ rpc, token = null, fetchImpl, cfg = (typeof window !== 'undefined' && window.BOOKING_CONFIG) || {}, search = typeof location !== 'undefined' ? location.search : '' } = {}) {
  const env = { testUi: testUiEnabled(cfg, search), mock: !!fetchImpl, official: cfg.mobilepayOfficialButton !== false };
  const mp = createMobilepayApi({ rpc, token, functionUrl, anonKey: cfg.anonKey, fetchImpl });
  const gapi = createGiftApi({ rpc, mock: false });
  const [o, pk] = await Promise.all([mp.options().catch(() => null), gapi.packages().catch(() => null)]);
  const opts = normOptions(o);
  const redeem = !!(pk?.ok && pk.redeem_enabled);
  const vc = token && redeem ? await gapi.orderClaims(token).catch(() => null) : null;   // kumppanilahjakortit (§13.12): pyynnöt vain kun lunastus käytössä
  return { env, mp, gapi, opts, mpShow: shouldShowButton(opts, env), redeem, claims: vc?.ok && Array.isArray(vc.claims) ? vc.claims : [] };
}

// Mitä asiakkaalle voidaan tarjota: { mobilepay, gift, claims } (booking = public_get_booking-vastaus)
export function offers(model, booking) {
  const payable = !!booking && PAYABLE.includes(booking.status) && booking.payment_status !== 'paid';
  return { mobilepay: payable && model.mpShow, gift: payable && model.redeem, claims: !!booking && model.claims.length > 0 };
}
// Maksettava jäljellä: ensisijaisesti palvelimen public_payment_options.order.unpaid; muuten total - paid; muuten null (summaa ei näytetä)
export function dueAmount(model, booking) {
  if (model.opts?.unpaid != null && Number.isFinite(+model.opts.unpaid)) return +model.opts.unpaid;
  if (booking && Number.isFinite(+booking.unpaid)) return +booking.unpaid;
  if (booking && Number.isFinite(+booking.total) && Number.isFinite(+booking.paid)) return Math.max(0, +booking.total - +booking.paid);
  return booking && booking.payment_status === 'unpaid' && Number.isFinite(+booking.total) ? +booking.total : null;
}
// Tuleeko kassalla/vahvistussivulla näyttää "maksu paikan päällä" -oletusta: ei silloin kun verkkomaksutapa on tarjolla
export const onlineAvailable = (model) => !!model && (model.mpShow || model.redeem);

// Kassa (ennen varausta, ei tokenia): tieto vain siitä että verkkomaksutapa on käytössä (MobilePay-tapa; testitila vain testiympäristössä) tai lahjakortin käyttö on päällä
export const onlineAtCheckout = (model) => !!model && !!((model.opts?.method && (model.opts.method.test !== true || model.env.testUi)) || model.redeem);

// Osio. h = DOM-apuri; handlers: onApplied(text) / onClaimed({text, extra}) / onChanged(...) → sivu lataa varauksen uudelleen ja näyttää ilmoituksen.
/* Ilmoitus maksusta (lahjakortti käytetty). Näytetään myös kun maksuosio poistuu, koska tilaus tuli kokonaan maksetuksi. */
export function payNotice(L, notice) {
  return h('p', { class: 'bk-ok', role: 'status', tabindex: '-1', 'data-testid': 'pc-notice' }, h('strong', { text: `${notice.title || pt(L, 'noticeTitle')}. ` }), notice.text || '', notice.extra ? ` ${notice.extra}` : '');
}

export function payChoicesSection({ S, L, token, model, booking, onApplied, onClaimed, onChanged, notice = null }) {
  const F = makeFmt(L), tx = (k, v) => pt(L, k, v);
  const of = offers(model, booking);
  if (!of.mobilepay && !of.gift && !of.claims) return null;
  const due = dueAmount(model, booking);
  const id = `pc-${++seq}`;
  const kids = [h('h3', { id: `${id}-t`, text: tx('title') })];
  if (of.mobilepay || of.gift) {
    if (due != null && due > 0) kids.push(h('p', { class: 'mp-amount', 'data-testid': 'pc-due', text: tx('amountDue', { amount: F.money(due) }) }));
    kids.push(h('p', { class: 'bk-note', text: booking.status === 'confirmed' ? tx('leadConfirmed') : tx('leadPending') }));
  }
  const claimNotice = notice && notice.kind === 'claim' && of.claims ? { ok: true, text: notice.text, extra: notice.extra } : null;   // lunastuspyynnön vahvistus näytetään pyyntölistan yläosassa (kuten tilaussivulla)
  if (notice && !claimNotice) kids.push(payNotice(L, notice));
  if (of.mobilepay) kids.push(h('div', { class: 'pc-opt', 'data-testid': 'pc-mobilepay' }, payBlock({ S, L, api: model.mp, opts: model.opts, env: model.env })));
  if (of.gift) {
    const panel = h('div', { class: 'pc-gift-panel', id: `${id}-g`, hidden: true, 'data-testid': 'pc-gift-panel' },
      redeemSection({ L, api: model.gapi, token, bare: true, balance: true, unpaid: due, onApplied, onClaimed }));
    const btn = h('button', { type: 'button', class: 'btn light ord-btn pc-gift-btn', 'aria-expanded': 'false', 'aria-controls': `${id}-g`, 'data-testid': 'pc-gift-btn', text: tx('giftBtn'),
      onclick: () => { const open = panel.hidden; panel.hidden = !open; btn.setAttribute('aria-expanded', String(open)); btn.textContent = tx(open ? 'giftBtnClose' : 'giftBtn'); if (open) panel.querySelector('input')?.focus(); } });
    kids.push(h('div', { class: 'pc-opt', 'data-testid': 'pc-gift' }, btn, panel));
  }
  if (of.claims) kids.push(claimsSection({ S, L, api: model.gapi, token, claims: model.claims, notice: claimNotice, onChanged }));
  return h('section', { class: 'bk-paychoices ord-card', 'aria-labelledby': `${id}-t`, 'data-testid': 'pay-choices' }, kids);
}
