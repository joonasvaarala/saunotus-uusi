// Kaupan KOKEILUTILA (?mock=1): kaikki RPC-kutsut vastataan selaimessa dev/treatment-mock.mjs:llä (kopioidaan buildissa nimellä treatment-mock.js). EI yhteyttä palvelimeen,
// ei oikeita varauksia: tuotekatalogi (Saunahoito + hoitovalitsin), saatavuus, varaus, vahvistussivu ja muutos toimivat muistissa; varaukset säilyvät vain tässä selaimen istunnossa
// (sessionStorage), jotta vahvistussivu ja "Muuta varausta" toimivat. Tuntematon RPC → 404 (PGRST202) = "ei käytössä", ei koskaan varakutsua oikealle palvelimelle.
// Virhekokeilu: ?mock=1&fail=option_required|invalid_option → seuraava varaus/muutos palauttaa kyseisen palvelinvirheen kerran (näkee virhekäsittelyn; sama muoto kuin palvelimella {ok:false, code, message}).
// Erikoissähköpostit (kuten dev-mockissa): taken@test.fi → aika varattu, time_window@test.fi → aikaikkuna, locked@test.fi → muutosaika umpeutunut.
import { ApiError } from './sb.js';
import { treatmentRpc, catalogEntries, snapshotBookings, restoreBookings, ADDONS } from './treatment-mock.js';
import { createOrderMock } from './order-mock.js';
import { isHoldScenario, holdMockParams, HOLD_ERRORS } from './hold-mock.js';
import { pickCatalog } from './catalog-audience.js';

const KEY = 'booking.shopmock.v1';
const MUTATING = new Set(['public_create_treatment_booking', 'public_change_treatment_booking']);
// scenario=pay|pay-prod|pay-off: vahvistussivun maksuvalinta (MobilePay + lahjakortti) – maksutila, lahjakortit ja mobilepay-funktiot tulevat order-mock.js:stä (sama mock kuin tilaussivulla); mpResult = paluutulos (paid|failed|pending|…).
// Demo ilman omaa varausta: tuntematon token → valmis maksamaton varaus (vahvistussivu: /varaa/vahvistus/?mock=1&scenario=pay#<mikä tahansa uuid>).
const PAY_RPC = new Set(['public_payment_options', 'public_checkout_payment_options', 'public_confirm_pay_later', 'public_gift_card_packages', 'public_check_gift_card', 'public_apply_gift_card', 'public_get_order_gift_cards', 'public_resolve_gift_code', 'public_submit_voucher_claim', 'public_get_order_voucher_claims', 'public_update_voucher_claim_code']);
export function createShopMock({ storage = globalThis.sessionStorage, now = () => Date.now(), fail = null, scenario = '', mpResult = '' } = {}) {
  const pay = /^pay(-prod|-off)?$/.test(scenario) || isHoldScenario(scenario) ? createOrderMock({ scenario, mpResult, ...holdMockParams() }) : null;   // hold* = kassan paikanpito (hold-mock.js)
  const waitlistKey = 'booking.shopmock.waitlist.v1';
  const waitlist = new Map();
  try { for (const row of JSON.parse(storage?.getItem(waitlistKey) || '[]')) waitlist.set(row.token, row); } catch { /* mock toimii myös ilman sessionStoragea */ }
  const saveWaitlist = () => { try { storage?.setItem(waitlistKey, JSON.stringify([...waitlist.values()])); } catch { /* storage pois */ } };
  const noTimes = fail === 'notimes';   // ?mock=1&fail=notimes: public_treatment_availability palauttaa aina tyhjän ("Ei vapaita aikoja" -tila)
  let failOnce = ['option_required', 'invalid_option', 'online_payment_unavailable', 'too_many_pending'].includes(fail) ? fail : null;
  try { restoreBookings(JSON.parse(storage?.getItem(KEY) || 'null')); } catch { /* tyhjä alku */ }
  const save = () => { try { storage?.setItem(KEY, JSON.stringify(snapshotBookings())); } catch { /* ei säilytystä */ } };
  const missing = (name) => new ApiError(`Could not find the function booking.${name} in the schema cache`, { status: 404, code: 'PGRST202' });
  const canned = (po) => ({ ok: true, order_no: po.order_no, status: po.status, payment_status: po.payment_status, total: po.total, currency: 'EUR', created_at: po.created_at, first_name: po.first_name, customer_kind: 'private',
    items: [{ product_name: 'Yleinen saunavuoro', quantity: 1, line_total: po.total, vat_rate: 25.5, product_id: 1, rule_id: null, starts_at: po.reservations[0].starts_at, ends_at: po.reservations[0].ends_at, persons: 2, mode: 'slots', status: 'confirmed', hold_expires_at: null, option: null }],
    addons: [], payment_methods: [], booking_kind: 'slots', can_change: false, change_deadline: null, change_hours_before: 48 });
  async function rpc(name, args = {}) {
    if (pay && PAY_RPC.has(name)) return pay.rpc(name, args);
    if (pay && name === 'public_get_booking') {
      const po = await pay.rpc('public_get_order', { p_token: args.p_token }), r = treatmentRpc(name, args, now());
      const b = r ? r.body : canned(po);
      const CK = ['checkout_state', 'awaiting_payment', 'hold_kind', 'hold_expires_at', 'seconds_left', 'server_now', 'remaining_amount', 'payment_in_progress'];
      return { ...b, status: po.status, payment_status: po.payment_status, total: po.total, paid: po.paid, unpaid: po.unpaid, ...(pay.hold ? { ...Object.fromEntries(CK.map((k) => [k, po[k]])), payment_methods: pay.hold.methods() } : {}) };
    }
    switch (name) {
      case 'public_join_waitlist': {
        const token = globalThis.crypto?.randomUUID?.() || '11111111-1111-4111-8111-' + String(waitlist.size + 1).padStart(12, '0');
        const old = [...waitlist.values()].find((x) => x.rule_id === +args.p_rule_id && x.date === args.p_date && x.email === String(args.p_email || '').toLowerCase() && x.status !== 'cancelled');
        const row = old || { token, rule_id: +args.p_rule_id, date: args.p_date, email: String(args.p_email || '').toLowerCase() };
        row.persons = +args.p_persons || 1; row.status = 'waiting';
        waitlist.set(row.token, row); saveWaitlist();
        return { ok: true, token: row.token, persons: row.persons, starts_at: `${args.p_date}T12:00:00+03:00`, ends_at: `${args.p_date}T14:00:00+03:00` };
      }
      case 'public_leave_waitlist': {
        const row = waitlist.get(args.p_token);
        if (row) { row.status = 'cancelled'; saveWaitlist(); }
        return { ok: true, cancelled: !!row };
      }
      case 'public_catalog': return catalogEntries();
      case 'public_catalog_for': return pickCatalog(catalogEntries(), args.p_audience);
      case 'public_availability_all': {
        const catalog = pickCatalog(catalogEntries(), args.p_audience);
        return catalog.filter((p) => p.booking_kind !== 'slots').flatMap((p) => {
          const response = treatmentRpc('public_availability', { p_product_id: p.id, p_from: args.p_from, p_to: args.p_to }, now());
          return Array.isArray(response?.body) ? response.body.map((r) => ({ ...r, product_id: +p.id })) : [];
        });
      }
      case 'public_settings': return { public_booking_enabled: true, public_treatment_horizon_days: 14 };
      case 'public_product_images': return [];
      case 'public_addons': return ADDONS;   // lisäpalvelut (booking_61: pyyhe resurssivaraukselle, tuote 7); sama muoto kuin tuotannon public_addons()
      case 'public_payment_options': return { ok: true, online_enabled: false, methods: [] };
      case 'public_checkout_payment_options': return { ok: true, mobilepay_enabled: false, gift_card_redeem_enabled: false, methods: [] };
      case 'public_get_booking': {
        const r = treatmentRpc(name, args, now());
        return r ? r.body : { ok: false, code: 'not_found', message: 'Varausta ei löytynyt' };
      }
      default: {
        if (failOnce && MUTATING.has(name)) { const code = failOnce; failOnce = null; return { ok: false, code, message: code === 'option_required' ? 'Valitse hoito' : code === 'invalid_option' ? 'Valittu hoito ei kelpaa' : HOLD_ERRORS[code] }; }
        if (noTimes && name === 'public_treatment_availability') return [];
        const r = treatmentRpc(name, args, now());
        if (!r) throw missing(name);
        if (r.status >= 400) throw new ApiError(r.body.message, { status: r.status, code: r.body.details || r.body.code, details: r.body });
        if (MUTATING.has(name)) save();
        if (pay?.hold && name === 'public_create_treatment_booking' && r.body?.ok) pay.hold.restart();   // kassa luo pidon: laskuri alkaa nollasta
        return r.body;
      }
    }
  }
  return { rpc, mpFetch: pay ? pay.mpFetch : undefined };
}
