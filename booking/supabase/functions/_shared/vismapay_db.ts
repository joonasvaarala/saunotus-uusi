// Visma Payn tietokantarajapinta. Lukee integration_config.key = vismapay (ei MobilePayn tilaa).
import type { Db, Env, Mode } from "./mobilepay.ts";

export type VismaMode = Mode | "dry_run";

export function realDb(createClient: (url: string, key: string, opts: unknown) => any, env: Env): Db & { vismaMode: () => Promise<VismaMode> } {
  const sb = createClient(env.get("SUPABASE_URL")!, env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const read = async (): Promise<VismaMode> => {
    const { data } = await sb.schema("booking").from("integration_config").select("mode").eq("key", "vismapay").maybeSingle();
    const m = data?.mode;
    return m === "test" || m === "live" || m === "dry_run" ? m : "off";
  };
  return {
    rpc: (fn, args) => sb.schema("booking").rpc(fn, args ?? {}),
    mode: async () => {
      const m = await read();
      return m === "test" || m === "live" ? m : "off";
    },
    vismaMode: read,
  };
}
