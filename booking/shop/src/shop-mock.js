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
import { mockQuietOffers } from './quiet-offers-mock.js';
import { createRitualMock, SHARED_PRODUCT } from './ritual-addon-mock.js';

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
  const annualSale = /[?&]annual=1(&|$)/.test(globalThis.location?.search || '');
  const quietOn = /[?&]quiet=1(&|$)/.test(globalThis.location?.search || '');   // booking_162
  // booking_166: ?ritual=1 → yleinen vuoro (kb 1) + saunarituaali lisäpalveluna (ritual-addon-mock.js); oletus pois (muut mockit ennallaan)
  const ritual = /[?&]ritual=1(&|$)/.test(globalThis.location?.search || '') ? createRitualMock({ storage, now, fail }) : null;
  const noTimes = fail === 'notimes';   // ?mock=1&fail=notimes: public_treatment_availability palauttaa aina tyhjän ("Ei vapaita aikoja" -tila)
  let failOnce = ['option_required', 'invalid_option', 'online_payment_unavailable', 'too_many_pending'].includes(fail) ? fail : null;
  try { restoreBookings(JSON.parse(storage?.getItem(KEY) || 'null')); } catch { /* tyhjä alku */ }
  const save = () => { try { storage?.setItem(KEY, JSON.stringify(snapshotBookings())); } catch { /* ei säilytystä */ } };
  const missing = (name) => new ApiError(`Could not find the function booking.${name} in the schema cache`, { status: 404, code: 'PGRST202' });
  const canned = (po) => ({ ok: true, order_no: po.order_no, status: po.status, payment_status: po.payment_status, total: po.total, currency: 'EUR', created_at: po.created_at, first_name: po.first_name, customer_kind: 'private',
    items: [{ product_name: 'Yleinen saunavuoro', quantity: 1, line_total: po.total, vat_rate: 25.5, product_id: 1, rule_id: null, starts_at: po.reservations[0].starts_at, ends_at: po.reservations[0].ends_at, persons: 2, mode: 'slots', status: 'confirmed', hold_expires_at: null, option: null }],
    addons: [], payment_methods: [], booking_kind: 'slots', can_change: false, change_deadline: null, change_hours_before: 48 });
  async function rpc(name, args = {}) {
    if (scenario === 'invoice_locked' && name === 'public_cancel_booking') return { ok: false, code: 'order_invoiced', message: 'Tilaus on laskutettu. Peruutus tehdään henkilökunnan kautta.' };
    if (pay && PAY_RPC.has(name)) return pay.rpc(name, args);
    if (pay && name === 'public_get_booking') {
      const po = await pay.rpc('public_get_order', { p_token: args.p_token }), r = treatmentRpc(name, args, now());
      const b = r ? r.body : canned(po);
      const CK = ['checkout_state', 'awaiting_payment', 'hold_kind', 'hold_expires_at', 'seconds_left', 'server_now', 'remaining_amount', 'payment_in_progress'];
      return { ...b, status: po.status, payment_status: po.payment_status, total: po.total, paid: po.paid, unpaid: po.unpaid, ...(pay.hold ? { ...Object.fromEntries(CK.map((k) => [k, po[k]])), payment_methods: pay.hold.methods() } : {}) };
    }
    if (ritual) {
      const rr = ritual(name, args);
      if (rr !== undefined) return rr;
      if (name === 'public_catalog' || name === 'public_catalog_for') return [SHARED_PRODUCT, ...(await rpc(name === 'public_catalog' ? '__catalog' : '__catalog_for', args))];
      if (name === 'public_availability_all') return [...ritual('public_availability', { ...args, p_product_id: 1 }).map((r) => ({ ...r, product_id: 1 })), ...(await rpc('__availability_all', args))];
    }
    switch (name) {
      case '__catalog': return catalogEntries();
      case '__catalog_for': return pickCatalog(catalogEntries(), args.p_audience);
      case 'public_join_waitlist': {
        const token = globalThis.crypto?.randomUUID?.() || '11111111-1111-4111-8111-' + String(waitlist.size + 1).padStart(12, '0');
        const old = [...waitlist.values()].find((x) => x.rule_id === +args.p_rule_id && x.date === args.p_date && x.email === String(args.p_email || '').toLowerCase() && x.status !== 'cancelled');
        const row = old || { token, rule_id: +args.p_rule_id, date: args.p_date, email: String(args.p_email || '').toLowerCase() };
        if (!Number.isInteger(+args.p_persons) || +args.p_persons < 1 || +args.p_persons > 6) return { ok: false, code: 'invalid_persons' };   // booking_134: 1–6
        row.persons = +args.p_persons; row.status = 'waiting';
        waitlist.set(row.token, row); saveWaitlist();
        return { ok: true, token: row.token, persons: row.persons, starts_at: `${args.p_date}T12:00:00+03:00`, ends_at: `${args.p_date}T14:00:00+03:00` };
      }
      case 'public_waitlist_claim': {   // booking_134: mockissa paikkoja riittää aina, jos jonovaraus on voimassa
        const row = waitlist.get(args.p_token);
        if (!row || row.status === 'cancelled') return { ok: false, code: 'not_found' };
        return { ok: true, rule_id: row.rule_id, product_id: row.product_id ?? null, session_date: row.date, persons: row.persons, enough: true };
      }
      case 'public_leave_waitlist': {
        const row = waitlist.get(args.p_token);
        if (row) { row.status = 'cancelled'; saveWaitlist(); }
        return { ok: true, cancelled: !!row };
      }
      // vuosikortti (booking_142): ?mock=1&annual=1 näyttää myynnin (oletus pois kuten tuotannossa); osto ohjaa tilaussivun mockiin (scenario=annual)
      case 'public_annual_card_offer': return annualSale ? { available: true, product_id: 43, name: 'Vuosikortti', name_en: 'Annual card', price: 290, vat_rate: 25.5, valid_months: 12 } : { available: false };
      case 'public_buy_annual_card': return annualSale ? { ok: true, order_no: 9142, token: '00000000-0000-4000-8000-000000000142', status: 'pending', total: 290, payment_mode: 'pay_later' } : { ok: false, code: 'sale_disabled', message: 'Vuosikorttien verkkomyynti ei ole käytössä' };
      case 'public_catalog': return catalogEntries();
      case 'public_catalog_for': return pickCatalog(catalogEntries(), args.p_audience);
      case '__availability_all':
      case 'public_availability_all': {
        const catalog = pickCatalog(catalogEntries(), args.p_audience);
        return catalog.filter((p) => p.booking_kind !== 'slots').flatMap((p) => {
          const response = treatmentRpc('public_availability', { p_product_id: p.id, p_from: args.p_from, p_to: args.p_to }, now());
          return Array.isArray(response?.body) ? response.body.map((r) => ({ ...r, product_id: +p.id })) : [];
        });
      }
      // booking_162: hiljaisten aikojen ale vain ?quiet=1 (oletus pois kuten tuotannossa)
      case 'public_quiet_offers': {
        if (!quietOn) return [];
        const rows = await rpc('public_availability_all', { p_from: args.p_from, p_to: args.p_to, p_audience: args.p_audience });
        return mockQuietOffers(rows, now());
      }
      case 'public_settings': return { public_booking_enabled: true, public_treatment_horizon_days: 14 };
      case 'public_product_images': return [];
      // booking_158: tapahtumat myynti suljettuna (events.sale_enabled = false) → kaikki kerrat 'closed'; ?mock=1 → #/tuote/perinnesaunotusilta
      case 'public_events': {
        const at = (d, hh, mm = 0) => { const x = new Date(now()); x.setUTCDate(x.getUTCDate() + d); x.setUTCHours(hh - 2, mm, 0, 0); return x.toISOString(); };
        return [
          { product_id: 31, slug: 'perinnesaunotusilta', name: 'Perinnesaunotusilta', name_en: 'Traditional sauna evening', description_short: 'Perinteinen saunotusilta savusaunassa.', description_short_en: 'A traditional sauna evening in the smoke sauna.', price: 69, price_text: null, image_path: null, image_alt: null, category: 'event', sale_open: false,
            occurrences: [{ rule_id: 9001, starts_at: at(21, 16), ends_at: at(21, 19), label: null, label_en: null, status: 'closed', remaining: null, price: 69 }, { rule_id: 9002, starts_at: at(49, 16), ends_at: at(49, 19), label: 'Joulun perinnesaunotus', label_en: 'Christmas sauna evening', status: 'closed', remaining: null, price: 69 }] },
          { product_id: 33, slug: 'saunottajakoulutus', name: 'Saunottajakoulutus', name_en: 'Sauna host training', description_short: null, description_short_en: null, price: 390, price_text: null, image_path: null, image_alt: null, category: 'training', sale_open: false,
            occurrences: [{ rule_id: 9003, starts_at: at(35, 9), ends_at: at(36, 16), label: null, label_en: null, status: 'closed', remaining: null, price: 390 }] },
        ];
      }
      case 'public_addons': return ADDONS;   // lisäpalvelut (booking_61: pyyhe resurssivaraukselle, tuote 7); sama muoto kuin tuotannon public_addons()
      case 'public_payment_options': return { ok: true, online_enabled: false, methods: [] };
      case 'public_checkout_payment_options': return { ok: true, mobilepay_enabled: false, gift_card_redeem_enabled: false, methods: [] };
      case 'public_get_booking': {
        if (scenario === 'invoice_locked') {
          const start = new Date(now() + 5 * 864e5).toISOString();
          return { ok: true, order_no: 185, status: 'pending', payment_status: 'invoiced', invoice_locked: true, total: 40, currency: 'EUR',
            can_change: true, change_deadline: new Date(now() + 3 * 864e5).toISOString(), change_hours_before: 48,
            items: [{ product_name: 'Yleinen saunavuoro', product_id: 1, quantity: 1, line_total: 40, vat_rate: 25.5, persons: 2, starts_at: start, ends_at: new Date(now() + 5 * 864e5 + 90 * 60e3).toISOString(), rule_id: 1, status: 'confirmed', mode: 'slots' }],
            addons: [] };
        }
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
