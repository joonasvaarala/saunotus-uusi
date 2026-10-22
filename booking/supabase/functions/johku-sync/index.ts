// johku-sync: Varmistajan cron kutsuu POST + x-johku-sync-secret.
// verify_jwt = false. Salaisuus JOHKU_SYNC_SECRET vain Edge-ympäristössä.
// Funktio ei palauta eikä kirjaa henkilötietoja tai lahjakorttikoodeja.
import { createClient } from "npm:@supabase/supabase-js@2";
import { handle, realDb } from "./handler.ts";

Deno.serve((req) => handle(req, { db: realDb(createClient, Deno.env), env: Deno.env }));
