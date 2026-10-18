// procountor-sync: pg_cron kutsuu POST + x-sync-secret (booking.procountor_daily_dispatch).
// Toinen polku action=send_invoice: normalisoitu lasku (ks. docs/procountor-integraatio.md). Ei luo booking.invoices-tauluja.
// Ilman PROCOUNTOR_*-salaisuuksia toiminto on dry_run. accounting_outboxia ei lähetetä (päiväkirja on myyntikirjaus).
import { createClient } from "npm:@supabase/supabase-js@2";
import { handle, realDb } from "./handler.ts";

Deno.serve((req) => handle(req, { db: realDb(createClient, Deno.env), env: Deno.env, fetchImpl: fetch }));
