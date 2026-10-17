// Vipps MobilePay -webhookin rekisteröinti (Webhooks API). AJETAAN KÄSIN omistajan toimesta; ei koskaan tulosta avaimia tai webhook-salaisuutta.
//
//   deno run -A booking/scripts/mobilepay-webhook.ts register test  --project-ref sxbofnuisemspgquoxyv
//   deno run --allow-env --allow-net booking/scripts/mobilepay-webhook.ts list test
//   deno run --allow-env --allow-net booking/scripts/mobilepay-webhook.ts delete test <webhook-id>
//
// Ympäristömuuttujat (ei tiedostoon): MOBILEPAY_CLIENT_ID, MOBILEPAY_CLIENT_SECRET, MOBILEPAY_SUBSCRIPTION_KEY, MOBILEPAY_MSN
// register: luo webhookin osoitteeseen https://<project-ref>.supabase.co/functions/v1/mobilepay-notify ja tallentaa palautuneen salaisuuden
//   suoraan Supabasen Edge-salaisuudeksi MOBILEPAY_WEBHOOK_SECRET (supabase CLI; salaisuutta ei tulosteta; väliaikainen 0600-tiedosto vain muistilevyllä /dev/shm, poistetaan heti).
//   Vipps palauttaa salaisuuden vain kerran: jos tallennus epäonnistuu, poista webhook (delete) ja rekisteröi uudelleen.
// Huom: testi- ja tuotantoympäristö ovat erilliset webhook-rekisterit -> aja sekä `test` että `live` (live vasta kun mobilepay.mode='live' on sovittu).
import { MobilePayApi, readCreds, VippsError } from "../supabase/functions/_shared/mobilepay.ts";

const EVENTS = ["epayments.payment.authorized.v1", "epayments.payment.aborted.v1", "epayments.payment.expired.v1", "epayments.payment.terminated.v1"];
const [cmd, envName, arg] = Deno.args;
const mode = envName === "live" ? "live" : envName === "test" ? "test" : null;
if (!cmd || !mode) { console.error("Käyttö: <register|list|delete> <test|live> [webhook-id] [--project-ref REF]"); Deno.exit(2); }
const creds = readCreds(Deno.env);
if (!creds) { console.error("Puuttuvia ympäristömuuttujia: MOBILEPAY_CLIENT_ID / _CLIENT_SECRET / _SUBSCRIPTION_KEY / _MSN"); Deno.exit(2); }
const api = new MobilePayApi(mode, creds);

async function call(method: string, path: string, body?: unknown) {
  const token = await api.getToken();
  const res = await fetch(`${api.base}${path}`, { method, headers: { Authorization: `Bearer ${token}`, "Ocp-Apim-Subscription-Key": creds!.subscriptionKey, "Merchant-Serial-Number": creds!.msn, ...(body ? { "Content-Type": "application/json" } : {}) }, body: body ? JSON.stringify(body) : undefined });
  const text = await res.text();
  if (!res.ok) throw new VippsError(res.status, "webhooks", text.slice(0, 300));
  return text ? JSON.parse(text) : null;
}

try {
  if (cmd === "list") {
    const r = await call("GET", "/webhooks/v1/webhooks");
    for (const w of r?.webhooks ?? []) console.log(w.id, w.url, (w.events ?? []).join(","));
  } else if (cmd === "delete") {
    if (!arg) throw new Error("webhook-id puuttuu");
    await call("DELETE", `/webhooks/v1/webhooks/${encodeURIComponent(arg)}`); console.log("poistettu", arg);
  } else if (cmd === "register") {
    const i = Deno.args.indexOf("--project-ref"); const ref = i >= 0 ? Deno.args[i + 1] : Deno.env.get("SUPABASE_PROJECT_REF");
    if (!ref) throw new Error("--project-ref puuttuu");
    const url = `https://${ref}.supabase.co/functions/v1/mobilepay-notify`;
    const w = await call("POST", "/webhooks/v1/webhooks", { url, events: EVENTS });
    if (!w?.secret) throw new Error("Vipps ei palauttanut salaisuutta");
    // CLI ei lue --env-file /dev/stdin -putkea: väliaikainen tiedosto muistilevylle (/dev/shm, 0600), poistetaan heti.
    const tmp = await Deno.makeTempFile({ dir: Deno.build.os === "linux" ? "/dev/shm" : undefined, prefix: "mpwh" });
    let out: Deno.CommandOutput;
    try {
      await Deno.chmod(tmp, 0o600);
      await Deno.writeTextFile(tmp, `MOBILEPAY_WEBHOOK_SECRET=${w.secret}\nMOBILEPAY_WEBHOOK_URL=${url}\n`);
      out = await new Deno.Command("supabase", { args: ["secrets", "set", "--project-ref", ref, "--env-file", tmp], stdout: "null", stderr: "piped" }).output();
    } finally { await Deno.remove(tmp).catch(() => {}); }
    if (!out.success) { console.error(`Salaisuuden tallennus epäonnistui. Poista webhook (delete ${mode} ${w.id}) ja yritä uudelleen.`); Deno.exit(1); }
    console.log(`Webhook ${w.id} rekisteröity (${mode}) -> ${url}; MOBILEPAY_WEBHOOK_SECRET tallennettu Supabase-salaisuuksiin.`);
  } else throw new Error("tuntematon komento");
} catch (e) { console.error("Virhe:", e instanceof VippsError ? `${e.op} ${e.status}` : (e as Error).message); Deno.exit(1); }
