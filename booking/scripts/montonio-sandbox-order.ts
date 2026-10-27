// Luo yhden sandbox-tilauksen ja tulostaa maksuosoitteen. Ei tulosta avaimia.
// Käyttö: MONTONIO_ACCESS_KEY=... MONTONIO_SECRET_KEY=... deno run -A booking/scripts/montonio-sandbox-order.ts
// MONTONIO_MODE=live hylätään. Oletus on sandbox.
import { PayApi, readCreds, safePaymentUrl } from "../supabase/functions/_shared/montonio.ts";

const mode = (Deno.env.get("MONTONIO_MODE") || "sandbox").trim().toLowerCase();
if (mode === "live") {
  console.error("Kieltäydytään: skripti luo vain sandbox-tilauksen.");
  Deno.exit(2);
}
if (mode !== "sandbox") {
  console.error("MONTONIO_MODE pitää olla sandbox.");
  Deno.exit(2);
}
const creds = readCreds(Deno.env);
if (!creds) {
  console.error("MONTONIO_ACCESS_KEY ja MONTONIO_SECRET_KEY puuttuvat ympäristöstä.");
  Deno.exit(2);
}
const ref = `sauna-smoke-${Date.now()}`;
const api = new PayApi(creds.accessKey, creds.secretKey, "https://sandbox-stargate.montonio.com");
const created = await api.createOrder({
  merchantReference: ref,
  amount: 1,
  currency: "EUR",
  locale: "fi",
  returnUrl: "https://example.invalid/return",
  notificationUrl: "https://example.invalid/notify",
  method: "paymentInitiation",
  description: "Testitilaus",
});
const url = safePaymentUrl(created.paymentUrl);
if (!url) {
  console.error("Maksuosoitetta ei saatu.");
  Deno.exit(1);
}
console.log(`merchantReference=${ref}`);
console.log(`paymentUrl=${url}`);
