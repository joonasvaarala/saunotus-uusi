// Asiakkaalle näkyvät tekstit edge-funktioissa (sopimus §18, osa 3 / PR 3): sähköpostit, PDF:t ja maksusivun virheet.
// Teksti haetaan tietokannasta (booking.public_get_site_texts, anon-avain, vain luku) ja paikkamerkit täytetään tässä:
//   {{var:nimi}}      → kutsujan antama arvo (tilausnumero, nimi, summa, päivä …)
//   {{setting:avain}} → public_settings()-arvo (esim. business_name); oletus alla SETTING_DEFAULTS, jos haku epäonnistuu
// Varateksti: repon oletus (kunkin funktion texts.ts, sama sisältö kuin tuotannossa) — käytetään jos haku epäonnistuu, rivi puuttuu tai
// DB-rivin paikkamerkki ei ole täytettävissä (silloin lokiin varoitus; raakaa {{…}} ei koskaan päädy viestiin). Lähetystila (dry_run) ei kuulu tähän.
// Puhdas TypeScript-tyyppisyntaksi ilman riippuvuuksia: Node 22.18+ lataa tämän suoraan testeissä.
export type Lang = "fi" | "en";
export interface TextDef { fi: string; en: string; cls?: "protected"; max?: number }
export type TextTable = Record<string, TextDef>;
export type Vars = Record<string, string | number | null | undefined>;
export interface TextRow { key: string; lang: string; text: string }
export type Settings = Record<string, unknown>;

/** Julkiset asetukset, joilla paikkamerkit täytetään jos public_settings() ei vastaa (sama arvo kuin tuotannossa 18.10.2026). */
export const SETTING_DEFAULTS: Settings = { business_name: "Sipoonjoen Perinnesauna" };

const PH = /\{\{([a-z_]+)(?::([A-Za-z0-9_]+))?\}\}/g;
export const tokensOf = (text: string): string[] => [...new Set([...String(text).matchAll(/\{\{[^{}]*\}\}/g)].map((m) => m[0]))];

export class TextError extends Error { constructor(msg: string) { super(msg); this.name = "TextError"; } }

/** Täyttää paikkamerkit. Heittää TextError: tuntematon laji, puuttuva muuttuja/asetus tai jäljelle jäävä {{ }}. */
export function fillText(text: string, ctx: { vars?: Vars; settings?: Settings } = {}): string {
  const src = String(text);
  if (/\{\{|\}\}/.test(src.replace(PH, ""))) throw new TextError("virheellinen paikkamerkki");   // tarkistus ennen arvojen asettamista (arvo saa sisältää aaltosulkeita)
  return src.replace(PH, (_m, kind: string, name: string) => {
    if (kind === "var") { const v = ctx.vars?.[name]; if (v == null) throw new TextError(`muuttuja puuttuu: {{var:${name}}}`); return String(v); }
    if (kind === "setting") { const v = ctx.settings?.[name]; if (v == null || typeof v === "object") throw new TextError(`asetus puuttuu: {{setting:${name}}}`); return String(v); }
    throw new TextError(`tuntematon paikkamerkki: {{${kind}${name ? ":" + name : ""}}}`);
  });
}

export type TFn = (key: string, lang: string | undefined, vars?: Vars) => string;

/** Tekstihaku: DB-rivi (jos täytettävissä) → muuten oletus. Tuntematon avain = ohjelmointivirhe (heittää). */
export function makeT(table: TextTable, rows?: Iterable<TextRow> | null, settings?: Settings | null, warn: (m: string) => void = (m) => console.warn(m)): TFn {
  const db = new Map<string, string>();
  for (const r of rows ?? []) if (r && typeof r.text === "string" && r.text.trim() && (r.lang === "fi" || r.lang === "en")) db.set(`${r.key}|${r.lang}`, r.text);
  const set = { ...SETTING_DEFAULTS, ...(settings ?? {}) };
  return (key, lang, vars) => {
    const def = table[key]; if (!def) throw new Error(`tuntematon tekstiavain: ${key}`);
    const l: Lang = lang === "en" ? "en" : "fi";
    const ctx = { vars, settings: set };
    const fromDb = db.get(`${key}|${l}`);
    if (fromDb !== undefined) {
      try { return fillText(fromDb, ctx); } catch (e) { warn(`site-texts: ${key} [${l}]: ${(e as Error).message}; käytetään repon oletusta`); }
    }
    return fillText(def[l], ctx);
  };
}

export interface Fetched { rows: TextRow[]; settings: Settings }
type FetchLike = (url: string, init?: RequestInit) => Promise<Response>;
const cache = new Map<string, { at: number; value: Fetched | null }>();

/**
 * Hakee tekstit (anon-avain, vain luku) ja julkiset asetukset. Epäonnistuessa palauttaa null (kutsuja käyttää oletuksia); tulos välimuistissa
 * ttlMs (oletus 5 min; epäonnistunut haku 30 s). prefixes rajaa palautettavat rivit (esim. ["email."]).
 */
export async function fetchSiteTexts(o: { url?: string | null; anonKey?: string | null; prefixes: string[]; fetchImpl?: FetchLike; timeoutMs?: number; ttlMs?: number; now?: () => number }): Promise<Fetched | null> {
  const url = String(o.url ?? "").replace(/\/$/, ""), key = String(o.anonKey ?? "");
  if (!url || !key || /^sb_secret_/.test(key)) return null;
  const now = o.now ?? Date.now, ck = `${url}|${o.prefixes.join(",")}`;
  const hit = cache.get(ck); if (hit && now() - hit.at < (hit.value ? (o.ttlMs ?? 300_000) : 30_000)) return hit.value;
  const f: FetchLike = o.fetchImpl ?? ((u, i) => fetch(u, i));
  const rpc = async (name: string, args: unknown) => {
    const res = await f(`${url}/rest/v1/rpc/${name}`, { method: "POST", signal: AbortSignal.timeout(o.timeoutMs ?? 4000),
      headers: { apikey: key, authorization: `Bearer ${key}`, "content-type": "application/json", "content-profile": "booking", "accept-profile": "booking" }, body: JSON.stringify(args) });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.json();
  };
  let value: Fetched | null = null;
  try {
    const t = await rpc("public_get_site_texts", { p_lang: null });
    if (!t || t.ok !== true || !Array.isArray(t.texts)) throw new Error("virheellinen vastaus");
    const rows: TextRow[] = t.texts.filter((r: any) => r && typeof r.key === "string" && o.prefixes.some((p) => r.key.startsWith(p))).map((r: any) => ({ key: r.key, lang: r.lang, text: r.text }));
    let settings: Settings = {};
    try { const s = await rpc("public_settings", {}); if (s && typeof s === "object") settings = s; } catch { /* oletusasetukset */ }
    value = { rows, settings };
  } catch (e) { console.warn(`site-texts: haku epäonnistui (${(e as Error).message}); käytetään repon oletustekstejä`); }
  cache.set(ck, { at: now(), value });
  return value;
}
/** Testeille. */
export const _clearTextCache = () => cache.clear();
