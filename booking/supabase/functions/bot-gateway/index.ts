// bot-gateway (koodari_otto.md §1): Oton botin yhdyskäytävä. verify_jwt = false (config.toml); tunnistus x-bot-key,
// jonka sha256-tiiviste tarkistetaan tietokannassa (botgw.bot_clients.key_hash). Logiikka: ./core.ts.
//
// Salaisuudet / ympäristö (vain Edge-ympäristössä, ei repossa):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (Supabase asettaa), BOTGW_DISABLED=1 -> 503 kaikkiin pyyntöihin.
// Kutsu: POST {"action": "...", "args": {...}}, otsikko x-bot-key. Vastaus {ok, data, request_id?} tai {ok:false, error}.
// Ainoat RPC:t: public.botgw_call(p_key_hash text, p_action text, p_args jsonb) ja
//   public.botgw_log_failure(p_key_hash text, p_action text, p_error text) (EXECUTE vain service_rolella).
// Ei suoria taulu- eikä kalenterikirjoituksia: vuoromuutokset kulkevat botgw.call -> public.shift_apply_change -> shift_outbox
//   -> calendar-sync-v2 push.
// Käyttöönotto (EI tästä haarasta): ks. booking/supabase/manual/botgw_kayttoonotto.md.
import { createClient } from "npm:@supabase/supabase-js@2";
import { createHandler, type Rpc } from "./core.ts";

const RPC_TIMEOUT_MS = 15_000;

const url = Deno.env.get("SUPABASE_URL");
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const supa = url && serviceKey
  ? createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
  : null;

const rpc: Rpc = async (fn, args) => {
  if (!supa) throw new Error("not_configured");
  const { data, error } = await supa.rpc(fn, args).abortSignal(AbortSignal.timeout(RPC_TIMEOUT_MS));
  return { data, error: error ? { code: error.code, message: error.message } : null };
};

const disabled = () => {
  const v = (Deno.env.get("BOTGW_DISABLED") ?? "").trim().toLowerCase();
  return v === "1" || v === "true" || v === "yes" || !supa; // asetukset puuttuvat -> pois päältä
};

Deno.serve(createHandler({ rpc, disabled }));
