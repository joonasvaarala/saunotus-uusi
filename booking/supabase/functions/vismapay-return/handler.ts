// vismapay-return: asiakkaan paluu Visma Paysta. MAC tarkistetaan, tila vahvistetaan Visma Paysta, sitten ohjaus vain tietokannan tilaussivulle.
import type { Db, Env, Fetch } from "../_shared/mobilepay.ts";
import { buildReturnUrl } from "../_shared/mobilepay.ts";
import { envOf, settleOrder } from "../_shared/vismapay_flow.ts";
import { macMatches, ORDER_NUMBER_RE, readCreds, returnMacMessage, VismaApi } from "../_shared/vismapay.ts";

export type Deps = { db: Db; env: Env; fetch: Fetch };

const html = (status: number, msg: string) => new Response(`<!doctype html><meta charset="utf-8"><title>Visma Pay</title><p>${msg}</p>`, {
  status, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
});

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== "GET") return html(405, "Virheellinen pyyntö.");
  const q = Object.fromEntries(new URL(req.url).searchParams.entries());
  const orderNumber = q.ORDER_NUMBER || "";
  if (!ORDER_NUMBER_RE.test(orderNumber)) return html(400, "Maksun tunnistetta ei voitu lukea.");
  const { data, error } = await deps.db.rpc("vismapay_payment_lookup", { p_order_number: orderNumber });
  if (error || !data?.found) return html(404, "Maksua ei löytynyt. Palaa tilaussivulle ja tarkista tilanne sieltä.");
  const creds = readCreds(deps.env, envOf(data.env));
  if (!creds) return html(503, "Maksun vahvistus ei ole juuri nyt käytettävissä. Jos maksoit, älä maksa uudelleen.");
  const ok = await macMatches(creds.privateKey, returnMacMessage(q), q.AUTHCODE);
  if (!ok) return html(401, "Maksun paluuviestiä ei voitu varmentaa. Tilaa ei muutettu.");
  await settleOrder(new VismaApi(creds, deps.fetch), deps.db, orderNumber);
  const back = shopReturn(data.site_base_url, data.order_page_path, data.order_token);
  if (!back) return html(200, "Maksu on käsitelty. Palaa tilaussivulle.");
  return new Response(null, { status: 302, headers: { location: back, "cache-control": "no-store" } });
}

function shopReturn(siteBase: string | null, orderPath: string | null, orderToken: string | null): string | null {
  if (!orderToken) return null;
  const url = buildReturnUrl(siteBase, orderPath, orderToken);
  if (!url) return null;
  const u = new URL(url);
  u.searchParams.set("pay", "vismapay");
  return u.toString();
}
