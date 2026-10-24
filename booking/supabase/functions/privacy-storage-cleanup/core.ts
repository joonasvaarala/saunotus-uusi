// privacy-storage-cleanup: puhdas logiikka (testattava ilman verkkoa). booking_160.
// Lista tulee booking.privacy_storage_due():sta: { enabled, dry_run, total, items: [{ bucket, path }] }.
// Poisto vain kun enabled === true JA dry_run === false (asetukset privacy_retention.enabled / .dry_run) JA pyyntö ei pyydä kuivaharjoitusta.

export const CHUNK = 100;
// Julkisia kuvasäiliöitä ei koskaan siivota tällä funktiolla.
export const NEVER_BUCKETS = new Set(["product-images", "article-images"]);

export type DueItem = { bucket: string; path: string };
export type Due = { enabled?: unknown; dry_run?: unknown; total?: unknown; items?: unknown };
export type Plan = { mode: "disabled" | "dry_run" | "remove"; batches: { bucket: string; paths: string[] }[]; rejected: number; total: number };

export function validItem(x: unknown): x is DueItem {
  if (!x || typeof x !== "object") return false;
  const { bucket, path } = x as Record<string, unknown>;
  if (typeof bucket !== "string" || typeof path !== "string") return false;
  if (!bucket || !path || NEVER_BUCKETS.has(bucket)) return false;
  if (path.startsWith("/") || path.split("/").some((s) => s === ".." || s === "." || s === "")) return false;
  return path.length <= 1024;
}

export function chunk<T>(a: T[], n = CHUNK): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < a.length; i += n) out.push(a.slice(i, i + n));
  return out;
}

export function planRemoval(due: Due | null | undefined, requestDryRun: boolean): Plan {
  const items = Array.isArray(due?.items) ? due!.items as unknown[] : [];
  const ok = items.filter(validItem);
  const byBucket = new Map<string, string[]>();
  for (const it of ok) {
    const l = byBucket.get(it.bucket) ?? [];
    if (!l.includes(it.path)) l.push(it.path);
    byBucket.set(it.bucket, l);
  }
  const batches = [...byBucket.entries()].sort(([a], [b]) => a.localeCompare(b)).flatMap(([bucket, paths]) => chunk(paths).map((p) => ({ bucket, paths: p })));
  const mode: Plan["mode"] = due?.enabled !== true ? "disabled" : (due?.dry_run !== false || requestDryRun) ? "dry_run" : "remove";
  return { mode, batches, rejected: items.length - ok.length, total: typeof due?.total === "number" ? due.total : items.length };
}
