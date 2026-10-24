// Hallinnan päivänipun lyhyt istuntovälimuisti; myös kesken oleva RPC jaetaan.
const cache = new Map();
const DEFAULT_TTL = 30_000;

export function clearDayBundles() { cache.clear(); }
export function seedDayBundle(date, value) {
  if (value && typeof value === 'object') cache.set(date, { at: Date.now(), value });
}
export function cachedDayBundle(date, loader, ttl = DEFAULT_TTL) {
  const old = cache.get(date);
  if (old && Date.now() - old.at < ttl) return old.promise || Promise.resolve(old.value);
  const promise = Promise.resolve().then(() => loader(date)).then((value) => {
    if (cache.get(date)?.promise === promise) {
      if (value && typeof value === 'object') seedDayBundle(date, value);
      else cache.delete(date);
    }
    return value;
  }).catch((error) => {
    if (cache.get(date)?.promise === promise) cache.delete(date);
    throw error;
  });
  cache.set(date, { at: Date.now(), promise });
  return promise;
}
