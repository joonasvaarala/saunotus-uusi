// Ajastettu synkka tunnistautuu omalla salaisuudellaan, ei käyttäjän JWT:llä.
import { createHmac, timingSafeEqual } from "node:crypto";

export function secretOk(expected: string | undefined, provided: string | null): boolean {
  if (!expected || !provided) return false;
  const a = createHmac("sha256", "johku-sync-v1").update(expected).digest();
  const b = createHmac("sha256", "johku-sync-v1").update(provided).digest();
  return timingSafeEqual(a, b);
}
