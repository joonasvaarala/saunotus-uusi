// Kaupan KOKEILUTILA (?mock=1): kaikki RPC-kutsut vastataan selaimessa dev/treatment-mock.mjs:llä (kopioidaan buildissa nimellä treatment-mock.js). EI yhteyttä palvelimeen,
// ei oikeita varauksia: tuotekatalogi (Saunahoito + hoitovalitsin), saatavuus, varaus, vahvistussivu ja muutos toimivat muistissa; varaukset säilyvät vain tässä selaimen istunnossa
// (sessionStorage), jotta vahvistussivu ja "Muuta varausta" toimivat. Tuntematon RPC → 404 (PGRST202) = "ei käytössä", ei koskaan varakutsua oikealle palvelimelle.
// Virhekokeilu: ?mock=1&fail=option_required|invalid_option → seuraava varaus/muutos palauttaa kyseisen palvelinvirheen kerran (näkee virhekäsittelyn; sama muoto kuin palvelimella {ok:false, code, message}).
// Erikoissähköpostit (kuten dev-mockissa): taken@test.fi → aika varattu, time_window@test.fi → aikaikkuna, locked@test.fi → muutosaika umpeutunut.
import { ApiError } from './sb.js';
import { treatmentRpc, catalogEntries, snapshotBookings, restoreBookings } from './treatment-mock.js';
import { createOrderMock } from './order-mock.js';

const KEY = 'booking.shopmock.v1';
const MUTATING = new Set(['public_create_treatment_booking', 'public_change_treatment_booking']);
// scenario=pay|pay-prod|pay-off: vahvistussivun maksuvalinta (MobilePay + lahjakortti) – maksutila, lahjakortit ja mobilepay-funktiot tulevat order-mock.js:stä (sama mock kuin tilaussivulla); mpResult = paluutulos (paid|failed|pending|…).
// Demo ilman omaa varausta: tuntematon token → valmis maksamaton varaus (vahvistussivu: /varaa/vahvistus/?mock=1&scenario=pay#<mikä tahansa uuid>).
const PAY_RPC = new Set(['public_payment_options', 'public_checkout_payment_options', 'public_gift_card_packages', 'public_check_gift_card', 'public_apply_gift_card', 'public_get_order_gift_cards', 'public_resolve_gift_code', 'public_submit_voucher_claim', 'public_get_order_voucher_claims', 'public_update_voucher_claim_code']);
export function createShopMock({ storage = globalThis.sessionStorage, now = () => Date.now(), fail = null, scenario = '', mpResult = '' } = {}) {
  const pay = /^pay(-prod|-off)?$/.test(scenario) ? createOrderMock({ scenario, mpResult }) : null;
  let failOnce = ['option_required', 'invalid_option'].includes(fail) ? fail : null;
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
      return { ...b, status: po.status, payment_status: po.payment_status, total: po.total, paid: po.paid, unpaid: po.unpaid };
    }
    switch (name) {
      case 'public_catalog': return catalogEntries();
      case 'public_settings': return { public_booking_enabled: true, public_treatment_horizon_days: 14 };
      case 'public_product_images': return [];
      case 'public_payment_options': return { ok: true, online_enabled: false, methods: [] };
      case 'public_checkout_payment_options': return { ok: true, mobilepay_enabled: false, gift_card_redeem_enabled: false, methods: [] };
      case 'public_get_booking': {
        const r = treatmentRpc(name, args, now());
        return r ? r.body : { ok: false, code: 'not_found', message: 'Varausta ei löytynyt' };
      }
      default: {
        if (failOnce && MUTATING.has(name)) { const code = failOnce; failOnce = null; return { ok: false, code, message: code === 'option_required' ? 'Valitse hoito' : 'Valittu hoito ei kelpaa' }; }
        const r = treatmentRpc(name, args, now());
        if (!r) throw missing(name);
        if (r.status >= 400) throw new ApiError(r.body.message, { status: r.status, code: r.body.details || r.body.code, details: r.body });
        if (MUTATING.has(name)) save();
        return r.body;
      }
    }
  }
  return { rpc, mpFetch: pay ? pay.mpFetch : undefined };
}
