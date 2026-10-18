// send-emails: pg_cron (1 min) kutsuu POST + x-sync-secret. Lukee booking.email_outbox_claim(), renderöi templates.ts:llä ja lähettää Resendillä.
// Tilat (booking.integration_config.resend.mode): off -> skipped; dry_run (oletus) -> renderöidään ja merkitään dry_run, MITÄÄN EI LÄHDE; live -> lähetys (vaatii RESEND_API_KEY).
// Salaisuus: RESEND_API_KEY (Edge Function secret). Ei muita salaisuuksia; SUPABASE_URL/SERVICE_ROLE_KEY tulevat ympäristöstä.
import { createClient } from "npm:@supabase/supabase-js@2";
import { render, type Kind } from "./templates.ts";
import { EMAIL_TEXTS } from "./texts.ts";
import { fetchSiteTexts, makeT } from "../_shared/site_texts.ts";

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } });
const b64 = (u8: Uint8Array) => { let s = ""; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode(...u8.subarray(i, i + 0x8000)); return btoa(s); };

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, error: "method" }, 405);
  const url = Deno.env.get("SUPABASE_URL")!;
  const sb = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const bk = sb.schema("booking");
  const ok = await bk.rpc("_cron_secret_ok", { p_secret: req.headers.get("x-sync-secret") });
  if (ok.error || ok.data !== true) return json({ ok: false, error: "unauthorized" }, 401);

  const cfg = await bk.from("integration_config").select("mode,settings").eq("key", "resend").maybeSingle();
  const mode: string = cfg.data?.mode ?? "off";
  const from: string = cfg.data?.settings?.from ?? "Sipoonjoen Perinnesauna <savusauna@saunotus.fi>";
  const replyTo: string | undefined = cfg.data?.settings?.reply_to;
  const key = Deno.env.get("RESEND_API_KEY");
  const rs = await bk.from("settings").select("value").eq("key", "gift_cards.redeem_enabled").maybeSingle();
  const redeemOnline = rs.data?.value === true;
  const claimed = await bk.rpc("email_outbox_claim", { p_limit: 20 });
  if (claimed.error) return json({ ok: false, error: claimed.error.message }, 500);
  const rows: any[] = claimed.data ?? [];
  const stats = { mode, claimed: rows.length, sent: 0, dry_run: 0, skipped: 0, failed: 0 };
  // viestien asiakasnäkyvät tekstit: tietokanta (email.*, anon-avain, vain luku; §18) → repon oletus jos haku epäonnistuu tai rivi puuttuu. Haetaan vain kun on lähetettävää.
  const st = rows.length ? await fetchSiteTexts({ url, anonKey: Deno.env.get("SUPABASE_ANON_KEY"), prefixes: ["email."] }) : null;
  const t = makeT(EMAIL_TEXTS, st?.rows, st?.settings);

  for (const r of rows) {
    try {
      if (mode === "off") { await bk.rpc("email_outbox_mark", { p_id: r.id, p_result: "skipped", p_error: "resend.mode=off" }); stats.skipped++; continue; }
      if (!r.to || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(r.to)) { await bk.rpc("email_outbox_mark", { p_id: r.id, p_result: "skipped", p_error: "ei kelvollista vastaanottajaa" }); stats.skipped++; continue; }
      const isGc = r.kind === "gift_card_buyer" || r.kind === "gift_card_recipient";
      if (isGc) {
        // vain maksetut/käytettävissä olevat kortit; perutut/maksamattomat -> ei viestiä
        r.gift_cards = (r.gift_cards ?? []).filter((g: any) => g.public_token && ["active", "used", "expired"].includes(g.status));
        if (!r.gift_cards.length) { await bk.rpc("email_outbox_mark", { p_id: r.id, p_result: "skipped", p_error: "ei lähetettäviä lahjakortteja (peruttu/maksamaton)" }); stats.skipped++; continue; }
        r.functions_url = `${url}/functions/v1`; r.redeem_online = redeemOnline;
      }
      if (r.kind === "voucher_claim_problem" && r.voucher_claim?.status !== "problem") { await bk.rpc("email_outbox_mark", { p_id: r.id, p_result: "skipped", p_error: "pyyntö ei enää ongelmatilassa" }); stats.skipped++; continue; }
      if (r.kind === "voucher_claim_received" && (!r.voucher_claim || ["cancelled", "expired"].includes(r.voucher_claim.status))) { await bk.rpc("email_outbox_mark", { p_id: r.id, p_result: "skipped", p_error: "pyyntö peruttu/vanhentunut" }); stats.skipped++; continue; }
      const m = render(r.kind as Kind, r, r.locale, t);
      if (!m.subject || !m.text || !m.html) throw new Error("tyhjä mallipohja");
      if (mode !== "live") { await bk.rpc("email_outbox_mark", { p_id: r.id, p_result: "dry_run", p_error: `dry_run: ${m.subject}` }); stats.dry_run++; continue; }
      if (!key) throw new Error("RESEND_API_KEY puuttuu");
      const attachments: { filename: string; content: string }[] = [];
      if ((r.kind === "receipt" || r.kind === "refund_receipt") && r.receipt?.public_token) {
        const pdf = await fetch(`${url}/functions/v1/receipt-pdf?t=${r.receipt.public_token}`);
        if (!pdf.ok) throw new Error(`receipt-pdf ${pdf.status}`);
        attachments.push({ filename: `${r.kind === "refund_receipt" ? "hyvityskuitti" : "kuitti"}-${r.receipt.receipt_no}.pdf`, content: b64(new Uint8Array(await pdf.arrayBuffer())) });
      }
      if (isGc) {
        let k = 0;
        // ostajan viestissä liitteenä vain ostajalle toimitettavat kortit; suoraan saajalle toimitettavien PDF menee saajan viestissä
        for (const g of r.gift_cards.filter((x: any) => r.kind === "gift_card_recipient" || (x.delivery_to ?? "buyer") !== "recipient")) {
          const pdf = await fetch(`${url}/functions/v1/gift-card-pdf?t=${g.public_token}&lang=${g.locale === "en" ? "en" : "fi"}`);
          if (!pdf.ok) throw new Error(`gift-card-pdf ${pdf.status}`);
          attachments.push({ filename: `${g.locale === "en" ? "gift-card" : "lahjakortti"}${r.gift_cards.length > 1 && r.kind === "gift_card_buyer" ? "-" + (++k) : ""}.pdf`, content: b64(new Uint8Array(await pdf.arrayBuffer())) });
        }
      }
      const res = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { authorization: `Bearer ${key}`, "content-type": "application/json", "idempotency-key": `booking-outbox-${r.id}` },
        body: JSON.stringify({ from, to: [r.to], subject: m.subject, text: m.text, html: m.html, ...(replyTo ? { reply_to: replyTo } : {}), ...(attachments.length ? { attachments } : {}) }),
      });
      const body = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(`resend ${res.status}: ${JSON.stringify(body).slice(0, 300)}`);
      await bk.rpc("email_outbox_mark", { p_id: r.id, p_result: "sent", p_provider_id: body.id ?? null }); stats.sent++;
    } catch (e) {
      await bk.rpc("email_outbox_mark", { p_id: r.id, p_result: "failed", p_error: String((e as Error).message ?? e) }); stats.failed++;
    }
  }
  return json({ ok: true, ...stats });
});
