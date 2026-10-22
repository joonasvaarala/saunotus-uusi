// Palveluroolin tunnistus hyvitysfunktioille, joiden verify_jwt on true.
// Kaksi hyväksyttyä polkua, tässä järjestyksessä:
//   1) Bearer on täsmälleen SUPABASE_SERVICE_ROLE_KEY (legacy-JWT tai uusi sb_secret_-avain). Ei trimmausta.
//   2) Bearer on JWT, jonka payloadin oma claim `role` on täsmälleen "service_role".
// Polku 2 ei tarkista allekirjoitusta: portti on jo hylännyt väärin allekirjoitetun tokenin.
// Purku ei heitä. user_metadata- tai muuta sisäkkäistä roolia ei lueta.
// Älä käytä JWT-polkua funktiossa, jonka verify_jwt on false — väärennetty token menisi läpi.

const MAX_PAYLOAD_CHARS = 8192;

/** Täsmäysavain tai portin varmentama service_role-JWT. Token on Bearer-skeeman jälkeinen osa. */
export function isServiceRoleBearer(token: string, serviceRoleKey: string | undefined): boolean {
  if (token === serviceRoleKey) return true;
  return jwtHasServiceRoleClaim(token);
}

/** Payloadin oma `role` on täsmälleen service_role. Väärä syöte palauttaa false. */
export function jwtHasServiceRoleClaim(token: string): boolean {
  try {
    return payloadRole(token) === "service_role";
  } catch {
    return false;
  }
}

function payloadRole(token: string): string | null {
  if (typeof token !== "string") return null;
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const [header, payload, signature] = parts;
  if (!header || !payload || !signature) return null;
  if (payload.length > MAX_PAYLOAD_CHARS) return null;
  const text = decodeBase64Url(payload);
  if (text.length > MAX_PAYLOAD_CHARS) return null;
  const value: unknown = JSON.parse(text);
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  if (!Object.hasOwn(value, "role")) return null;
  const role = (value as { role: unknown }).role;
  return typeof role === "string" ? role : null;
}

function decodeBase64Url(input: string): string {
  if (!/^[A-Za-z0-9_-]+$/.test(input)) throw new Error("bad_b64");
  const pad = input.length % 4 === 0 ? "" : "=".repeat(4 - (input.length % 4));
  const bin = atob(input.replace(/-/g, "+").replace(/_/g, "/") + pad);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}

/**
 * Sama järjestys kuin hyvitysfunktioissa: ei Bearer-skeemaa → false;
 * palvelurooli → true ilman oikeustarkistusta; muuten has_permission-polku.
 * hasPermission saa alkuperäisen Authorization-otsikon (Bearer-etuliite mukana).
 */
export async function authorizeServiceRoleOrPermission(
  authorization: string | null,
  serviceRoleKey: string | undefined,
  hasPermission: (authorization: string) => Promise<boolean>,
): Promise<boolean> {
  const auth = authorization ?? "";
  if (!auth.toLowerCase().startsWith("bearer ")) return false;
  if (isServiceRoleBearer(auth.slice(7), serviceRoleKey)) return true;
  return await hasPermission(auth);
}
