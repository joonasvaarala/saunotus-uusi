// Kaupan KOKEILUTILA (?mock=1): kaikki RPC-kutsut vastataan selaimessa dev/treatment-mock.mjs:llä (kopioidaan buildissa nimellä treatment-mock.js). EI yhteyttä palvelimeen,
// ei oikeita varauksia: tuotekatalogi (Saunahoito + hoitovalitsin), saatavuus, varaus, vahvistussivu ja muutos toimivat muistissa; varaukset säilyvät vain tässä selaimen istunnossa
// (sessionStorage), jotta vahvistussivu ja "Muuta varausta" toimivat. Tuntematon RPC → 404 (PGRST202) = "ei käytössä", ei koskaan varakutsua oikealle palvelimelle.
// Virhekokeilu: ?mock=1&fail=option_required|invalid_option → seuraava varaus/muutos palauttaa kyseisen palvelinvirheen kerran (näkee virhekäsittelyn; sama muoto kuin palvelimella {ok:false, code, message}).
// Erikoissähköpostit (kuten dev-mockissa): taken@test.fi → aika varattu, time_window@test.fi → aikaikkuna, locked@test.fi → muutosaika umpeutunut.
import { ApiError } from './sb.js';
import { treatmentRpc, catalogEntries, snapshotBookings, restoreBookings } from './treatment-mock.js';

const KEY = 'booking.shopmock.v1';
const MUTATING = new Set(['public_create_treatment_booking', 'public_change_treatment_booking']);
export function createShopMock({ storage = globalThis.sessionStorage, now = () => Date.now(), fail = null } = {}) {
  let failOnce = ['option_required', 'invalid_option'].includes(fail) ? fail : null;
  try { restoreBookings(JSON.parse(storage?.getItem(KEY) || 'null')); } catch { /* tyhjä alku */ }
  const save = () => { try { storage?.setItem(KEY, JSON.stringify(snapshotBookings())); } catch { /* ei säilytystä */ } };
  const missing = (name) => new ApiError(`Could not find the function booking.${name} in the schema cache`, { status: 404, code: 'PGRST202' });
  async function rpc(name, args = {}) {
    switch (name) {
      case 'public_catalog': return catalogEntries();
      case 'public_settings': return { public_booking_enabled: true, public_treatment_horizon_days: 14 };
      case 'public_product_images': return [];
      case 'public_payment_options': return { ok: true, online_enabled: false, methods: [] };
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
  return { rpc };
}
