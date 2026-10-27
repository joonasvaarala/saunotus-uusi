// montonio-return: asiakkaan paluu. order-token varmennetaan, sitten ohjaus vain tietokannan tilaussivulle.
import type { Db, Env, Fetch } from "../_shared/mobilepay.ts";
import { applyVerified } from "../_shared/montonio_flow.ts";
import { readCreds, shopReturn, verifyJwt } from "../_shared/montonio.ts";

export type Deps = { db: Db; env: Env; fetch: Fetch };

const html = (status: number, msg: string) => new Response(`<!doctype html><meta charset="utf-8"><title>Verkkomaksu</title><p>${msg}</p>`, {
  status, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
});

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== "GET") return html(405, "Virheellinen pyyntö.");
  const token = new URL(req.url).searchParams.get("order-token") || "";
  if (!token) return html(400, "Maksun tunnistetta ei voitu lukea.");
  const creds = readCreds(deps.env);
  if (!creds) return html(503, "Maksun vahvistus ei ole juuri nyt käytettävissä. Jos maksoit, älä maksa uudelleen.");
  const verified = await verifyJwt(token, creds.secretKey);
  if (!verified.ok) return html(401, "Maksun paluuviestiä ei voitu varmentaa. Tilausta ei muutettu.");
  const ref = String(verified.payload.merchantReference || "");
  if (!/^sauna-[a-z0-9_-]+$/i.test(ref)) return html(400, "Maksun tunnistetta ei voitu lukea.");
  const { data, error } = await deps.db.rpc("montonio_payment_lookup", { p_order_number: ref });
  if (error || !data?.found) return html(404, "Maksua ei löytynyt. Palaa tilaussivulle ja tarkista tilanne sieltä.");
  await applyVerified(deps.db, verified.payload, {
    accessKey: creds.accessKey,
    merchantReference: ref,
    amount: Number(data.amount),
    orderUuid: data.order_uuid ?? null,
  });
  const back = shopReturn(data.site_base_url, data.order_page_path, data.order_token);
  if (!back) return html(200, "Maksu on käsitelty. Palaa tilaussivulle.");
  return new Response(null, { status: 302, headers: { location: back, "cache-control": "no-store" } });
}
