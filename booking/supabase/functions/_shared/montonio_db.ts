// Verkkomaksun tietokantarajapinta. Lukee integration_config.key = montonio.
import type { Db, Env, Mode } from "./mobilepay.ts";

export type PayMode = Mode | "dry_run";

export function realDb(createClient: (url: string, key: string, opts: unknown) => any, env: Env): Db & { payMode: () => Promise<PayMode> } {
  const sb = createClient(env.get("SUPABASE_URL")!, env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const read = async (): Promise<PayMode> => {
    const { data } = await sb.schema("booking").from("integration_config").select("mode").eq("key", "montonio").maybeSingle();
    const m = data?.mode;
    return m === "test" || m === "live" || m === "dry_run" ? m : "off";
  };
  return {
    rpc: (fn, args) => sb.schema("booking").rpc(fn, args ?? {}),
    mode: async () => {
      const m = await read();
      return m === "test" || m === "live" ? m : "off";
    },
    payMode: read,
  };
}
