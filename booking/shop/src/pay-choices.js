// Maksuvalinta varausvahvistussivulle (/varaa/vahvistus/#token): "Maksa MobilePaylla" + "Maksa lahjakortilla" (yksi "Lahjakortin koodi" -kenttä) – SAMAT moduulit ja RPC:t kuin tilaussivulla:
//   public_payment_options + mobilepay-start / mobilepay-notify (mobilepay-api/-ui/-logic), public_gift_card_packages + public_resolve_gift_code / public_apply_gift_card /
//   public_submit_voucher_claim / public_get_order_voucher_claims (gift-api, order-gift.js redeemSection + claimsSection). Tämä tiedosto vain kokoaa ne yhteen osioon; ei kopioi logiikkaa.
// Puuttuva RPC / virhe / ei sallittu → ei mitään näkyviin (sivu ennallaan). Ei oleteta maksutapaa: kaikki päätökset tulevat palvelimelta (public_payment_options, redeem_enabled).
import { functionUrl } from './sb.js';
import { createMobilepayApi } from './mobilepay-api.js';
import { normOptions, normCheckoutOptions, shouldShowButton, testUiEnabled } from './mobilepay-logic.js';
import { payBlock } from './mobilepay-ui.js';
import { createGiftApi } from './gift-api.js';
import { redeemSection, claimsSection } from './order-gift.js';
import { h, makeFmt } from './gift-ui.js';
import { pt } from './pay-choices-texts.js';
import { normVisma, shouldShowVisma } from './vismapay-logic.js';
import { createVismapayApi } from './vismapay-api.js';
import { vismaPayBlock } from './vismapay-ui.js';
import { ht, payLaterError } from './hold-texts.js';
import { paysByInvoice } from './company-pay.js';
import { onlineMethod, showOnline } from './online-pay-logic.js';
import { createOnlinePayApi } from './online-pay-api.js';
import { onlinePayBlock, payMark, setMethodLabel } from './online-pay-ui.js';

const PAYABLE = ['confirmed', 'pending'];
let seq = 0;

// Lataa maksutavat. Tokenilla (vahvistussivu): MobilePay (public_payment_options) + lahjakortti (redeem_enabled + lunastuspyynnöt). Ilman tokenia (kassa, ennen varausta): public_checkout_payment_options (§14.7).
export async function loadPayChoices({ rpc, token = null, fetchImpl, cfg = (typeof window !== 'undefined' && window.BOOKING_CONFIG) || {}, search = typeof location !== 'undefined' ? location.search : '' } = {}) {
  const env = { testUi: testUiEnabled(cfg, search), mock: !!fetchImpl, official: cfg.mobilepayOfficialButton !== false };
  const mp = createMobilepayApi({ rpc, token, functionUrl, anonKey: cfg.anonKey, fetchImpl });
  const gapi = createGiftApi({ rpc, mock: false });
  if (!token) {   // kassa (ei tokenia, §14.7): yksi RPC kertoo verkkomaksun ja lahjakortin käytön; ei public_payment_options(null)-kutsua
    const raw = await mp.checkoutOptions();
    const co = normCheckoutOptions(raw);
    co.online = onlineMethod(raw?.methods);
    return { env, mp, gapi, opts: co, mpShow: false, onlineShow: showOnline(co.online, env), redeem: co.gift, claims: [], checkout: co };
  }
  const [o, pk] = await Promise.all([mp.options().catch(() => null), gapi.packages().catch(() => null)]);
  const opts = normOptions(o);
  const vpOpts = normVisma(o);
  const vp = createVismapayApi({ token, functionUrl, anonKey: cfg.anonKey, fetchImpl });
  const online = onlineMethod(o?.methods);
  const onlineApi = createOnlinePayApi({ token, functionUrl, anonKey: cfg.anonKey, fetchImpl });
  const redeem = !!(pk?.ok && pk.redeem_enabled);
  const vc = redeem ? await gapi.orderClaims(token).catch(() => null) : null;   // kumppanilahjakortit (§13.12): pyynnöt vain kun lunastus käytössä
  return { env, mp, gapi, opts, vp, vpOpts, online: onlineApi, onlineOpts: online, payLater: opts.payLater || null, mpShow: shouldShowButton(opts, env), vpShow: shouldShowVisma(vpOpts), onlineShow: !!(online && o?.order?.can_pay_online === true && showOnline(online, env)), redeem, claims: vc?.ok && Array.isArray(vc.claims) ? vc.claims : [] };
}

// Mitä asiakkaalle voidaan tarjota: { mobilepay, gift, claims, payLater } (booking = public_get_booking-vastaus). payLater = booking_57-testivaihtoehto: vain kun palvelin listasi pay_later-tavan (ei env.testUi-ehtoa)
export function offers(model, booking) {
  const payable = !!booking && PAYABLE.includes(booking.status) && booking.payment_status !== 'paid' && booking.payment_status !== 'invoiced' && !paysByInvoice(booking) && booking.checkout_state !== 'preliminary' && booking.checkout_state !== 'expired';   // laskulla maksettava yritys ja alustava varaus eivät maksa verkossa
  return { mobilepay: payable && model.mpShow, vismapay: payable && !!model.vpShow, online: payable && !!model.onlineShow, gift: payable && model.redeem, claims: !!booking && model.claims.length > 0, payLater: payable && !!model.payLater };
}
// Maksettava jäljellä: ensisijaisesti palvelimen public_payment_options.order.unpaid; muuten total - paid; muuten null (summaa ei näytetä)
export function dueAmount(model, booking) {
  if (model.opts?.unpaid != null && Number.isFinite(+model.opts.unpaid)) return +model.opts.unpaid;
  if (booking && Number.isFinite(+booking.unpaid)) return +booking.unpaid;
  if (booking && Number.isFinite(+booking.total) && Number.isFinite(+booking.paid)) return Math.max(0, +booking.total - +booking.paid);
  return booking && booking.payment_status === 'unpaid' && Number.isFinite(+booking.total) ? +booking.total : null;
}
// Tuleeko kassalla/vahvistussivulla näyttää "maksu paikan päällä" -oletusta: ei silloin kun verkkomaksutapa on tarjolla
export const onlineAvailable = (model) => !!model && (model.onlineShow || model.mpShow || model.vpShow || model.redeem);

// Kassa (ennen varausta, ei tokenia): verkkomaksu (code online; vanha mobilepay/visma vain jos palvelin vielä listaa sen) tai lahjakortti. Testitila vain testiympäristössä.
export const onlineAtCheckout = (model) => !!model && !!((model.opts?.online && (model.opts.online.test !== true || model.env.testUi)) || (model.opts?.method && (model.opts.method.test !== true || model.env.testUi)) || model.opts?.visma || model.redeem);

// booking_57: "Testivaihtoehto: maksu paikan päällä". Nappi kutsuu palvelimen ilmoittamaa confirm_rpc:tä (public_confirm_pay_later) order_token:illa.
// Onnistuessa (ok:true, checkout_state confirmed_unpaid) kutsutaan onPayLater(vastaus) → sivu latautuu uudelleen ja näyttää vahvistetun, maksamattoman tilan. Virheillä ystävällinen FI/EN-viesti (role=alert); nappi pois käytöstä kesken pyynnön (ei tuplaklikkiä).
function payLaterBlock({ L, model, onPayLater, onHoldError }) {
  const msg = h('p', { class: 'bk-error pc-paylater-msg', role: 'alert', hidden: true, 'data-testid': 'pc-paylater-error' });
  let busy = false;
  const btn = h('button', { type: 'button', class: 'btn light ord-btn pc-paylater-btn', 'data-testid': 'pc-paylater-btn', text: ht(L, 'payLater.btn'),
    onclick: async () => {
      if (busy) return;
      busy = true; btn.disabled = true; btn.setAttribute('aria-busy', 'true'); btn.textContent = ht(L, 'payLater.working'); msg.hidden = true; msg.textContent = '';
      const r = await model.mp.confirmPayLater(model.payLater.confirmRpc);
      if (r && r.ok === true) { if (onPayLater) onPayLater(r); return; }   // sivu päivittyy; nappi jää pois käytöstä
      const code = r && r.code;
      msg.textContent = payLaterError(L, code); msg.hidden = false;
      busy = false; btn.removeAttribute('aria-busy'); btn.textContent = ht(L, 'payLater.btn');
      btn.disabled = code === 'pay_later_unavailable' || code === 'order_cancelled' || code === 'order_expired';   // ei järkeä yrittää uudelleen
      if (['order_expired', 'order_cancelled', 'payment_in_progress', 'not_found'].includes(code) && onHoldError) onHoldError(code);   // hae tila uudelleen (laskuri/vanhentunut-näkymä)
    } });
  return h('div', { class: 'pc-opt pc-paylater', 'data-testid': 'pc-paylater' }, btn, h('p', { class: 'bk-note pc-paylater-note', text: ht(L, 'payLater.text') }), msg);
}

// Osio. h = DOM-apuri; handlers: onApplied(text) / onClaimed({text, extra}) / onChanged(...) → sivu lataa varauksen uudelleen ja näyttää ilmoituksen.
/* Ilmoitus maksusta (lahjakortti käytetty). Näytetään myös kun maksuosio poistuu, koska tilaus tuli kokonaan maksetuksi. */
export function payNotice(L, notice) {
  return h('p', { class: 'bk-ok', role: 'status', tabindex: '-1', 'data-testid': 'pc-notice' }, h('strong', { text: `${notice.title || pt(L, 'noticeTitle')}. ` }), notice.text || '', notice.extra ? ` ${notice.extra}` : '');
}

export function payChoicesSection({ S, L, token, model, booking, onApplied, onClaimed, onChanged, onPayLater = null, notice = null, hold = false, onHoldError = null, heading = null, leadText = null }) {
  const F = makeFmt(L), tx = (k, v) => pt(L, k, v);
  const of = offers(model, booking);
  if (!of.online && !of.gift && !of.claims && !of.payLater) return null;
  const due = dueAmount(model, booking);
  const partial = !!(booking && +booking.paid > 0.004 && due > 0);
  const id = `pc-${++seq}`;
  const kids = [h('h3', { id: `${id}-t`, text: heading || tx('title') })];
  if (of.online || of.gift) {
    if (due != null && due > 0) kids.push(h('p', { class: 'mp-amount', 'data-testid': 'pc-due', text: tx(partial ? 'amountDue' : 'amountToPay', { amount: F.money(due) }) }));
    const lead = leadText || (hold ? ht(L, 'chooseOnline') : booking.status === 'confirmed' ? tx('leadOnlineConfirmed') : tx('leadOnline'));
    kids.push(h('p', { class: 'bk-note', 'data-testid': 'pc-lead', text: lead }));   // pitotilassa ei mainita "maksu paikan päällä": varaus vahvistuu vasta maksun jälkeen
  }
  const claimNotice = notice && notice.kind === 'claim' && of.claims ? { ok: true, text: notice.text, extra: notice.extra } : null;   // lunastuspyynnön vahvistus näytetään pyyntölistan yläosassa (kuten tilaussivulla)
  if (notice && !claimNotice) kids.push(payNotice(L, notice));
  if (of.online) kids.push(h('div', { class: 'pc-opt', 'data-testid': 'pc-online' }, onlinePayBlock({ L, api: model.online, method: model.onlineOpts, env: model.env, testid: 'pc-method', showTest: true, onFail: onHoldError ? (code) => { if (['order_expired', 'order_preliminary', 'payment_in_progress'].includes(code)) onHoldError(code); } : null })));
  if (of.gift) {
    const panel = h('div', { class: 'pc-gift-panel', id: `${id}-g`, hidden: true, 'data-testid': 'pc-gift-panel' },
      redeemSection({ L, api: model.gapi, token, bare: true, balance: true, unpaid: due, onApplied, onClaimed, onFail: onHoldError ? (code) => { if (['order_expired', 'order_preliminary', 'payment_in_progress'].includes(code)) onHoldError(code); } : null }));
    const giftLabel = h('span', { class: 'op-method-label', text: tx('giftBtn') });
    const btn = h('button', { type: 'button', class: 'btn light ord-btn pc-gift-btn', 'aria-expanded': 'false', 'aria-controls': `${id}-g`, 'data-testid': 'pc-gift-btn',
      onclick: () => { const open = panel.hidden; panel.hidden = !open; btn.setAttribute('aria-expanded', String(open)); setMethodLabel(btn, tx(open ? 'giftBtnClose' : 'giftBtn')); if (open) panel.querySelector('input')?.focus(); } }, payMark('gift'), giftLabel);
    btn._opLabel = giftLabel;
    kids.push(h('div', { class: 'pc-opt', 'data-testid': 'pc-gift' }, btn, panel));
  }
  if (of.payLater) kids.push(payLaterBlock({ L, model, onPayLater, onHoldError }));   // booking_57: oikea nappi (ei enää pelkkä tietolaatikko); näkyy vain kun palvelin listaa pay_later-tavan
  if (of.claims) kids.push(claimsSection({ S, L, api: model.gapi, token, claims: model.claims, notice: claimNotice, onChanged }));
  return h('section', { class: 'bk-paychoices ord-card', 'aria-labelledby': `${id}-t`, 'data-testid': 'pay-choices' }, kids);
}
