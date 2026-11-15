// Viikko-ohjelman ajonaikainen ohjaus (etusivu + saunavuorot): hakee julkiset RPC:t viikko kerrallaan, rakentaa mallin (week-grid-logic.js)
// ja piirtää sen (week-grid-view.js, createElement + textContent). Viikkoja selataan nuolilla; mobiilissa päivänauha valitsee yhden päivän.
// Haut: public_availability_all, public_quiet_offers (≤ 14 pv), public_events, public_catalog, public_settings (hoitojen varausikkuna
// public_treatment_horizon_days, nyt 90 pv) ja hoidoille public_treatment_availability (treatments.js, rajattu näkyvän viikon ja ikkunan leikkaukseen). Hakuvirhe ei riko sivua: staattinen varaversio jää, tai viikko piirretään ilman puuttuvaa osaa.
import { addDaysIso, quietWindow } from './quiet-offers-logic.js';
import { buildWeek, clampWeek, weekStartOf, CARE_HORIZON_DAYS, careEntry } from './week-grid-logic.js';
import { weekGridTree, toDom } from './week-grid-view.js';

const enc = encodeURIComponent;
export const shopHrefs = (base) => ({
  product: (slug, date) => `${base}#/tuote/${enc(slug)}/${date}`,
  care: (slug, date) => `${base}#/tuote/${enc(slug)}?n=1&d=${date}`,
  after: (rule, date) => `${base}#/varaa/${enc(rule)}/${date}/26`,
  event: (slug, date) => `${base}#/tuote/${enc(slug)}/${date}`,
  eventOpen: (slug) => `${base}#/tuote/${enc(slug)}`,
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const errCode = (e) => e?.code || e?.details?.code || null;
export const CARE_RETRY_MS = 1200;
/** Hoitotuotteiden vapaat päivät viikolle. rate_limited / busy yritetään uudelleen (enintään 2 kertaa, treatments.js yrittää busy-tilannetta jo itse).
 *  Virhe yhdessä tuotteessa ei estä muita; kaikki epäonnistuvat → null. */
export async function loadCare(catalog, from, to, { retryMs = CARE_RETRY_MS, wait = sleep } = {}) {
  const T = await import('./treatments.js');
  const list = T.splitCatalog(catalog, new Map()).treatments.filter(T.isListed);
  if (!list.length) return [];
  let ok = 0;
  const out = await Promise.all(list.map(async (p) => {
    for (let tries = 0; ; tries++) {
      try { const byDay = await T.loadAvailability(p, 1, from, to); ok++; return careEntry(p, byDay); } catch (e) {
        if (!T.isRetryable(errCode(e)) || tries >= 2) return null;
        await wait(retryMs * (tries + 1));
      }
    }
  }));
  return ok ? out.filter(Boolean) : null;
}

/** Viikon haut. Kaikki osat ovat valinnaisia: null = ei saatu. */
export async function loadWeek(start, { rpc, today, catalog, horizon = CARE_HORIZON_DAYS, loadCareFn = loadCare }) {
  const from = start < today ? today : start, to = addDaysIso(start, 6);
  const qEnd = quietWindow(today);
  const offerFrom = from, offerTo = to < qEnd ? to : qEnd;
  const careEnd = addDaysIso(today, horizon - 1), careTo = to < careEnd ? to : careEnd;
  const [rows, offers, care] = await Promise.all([
    to < today ? Promise.resolve([]) : rpc('public_availability_all', { p_from: from, p_to: to, p_audience: 'consumer' }).then((r) => (Array.isArray(r) ? r : null)).catch(() => null),
    offerFrom <= offerTo ? rpc('public_quiet_offers', { p_from: offerFrom, p_to: offerTo, p_audience: 'consumer' }).then((r) => (Array.isArray(r) ? r : [])).catch(() => []) : Promise.resolve([]),
    Array.isArray(catalog) && from <= careTo ? loadCareFn(catalog, from, careTo).catch(() => null) : Promise.resolve(from > careEnd ? [] : null),
  ]);
  return { rows, offers, care };
}

/** Hoitojen varausikkuna päivinä public_settingsistä (treatments.js horizonDays; POLICY.horizonDays vain varalla). */
export async function careHorizon(settings) {
  try { return (await import('./treatments.js')).horizonDays(settings); } catch { return CARE_HORIZON_DAYS; }
}

/** shared: valinnainen () => Promise<{ events, catalog }>; sivun muu skripti (quiet-week.js) jakaa saman haun, jolloin katalogia ja tapahtumia ei haeta kahdesti. */
export const NAV_DEBOUNCE_MS = 250;
export function mountWeekGrid(root, { rpc, lang = 'fi', shopHref = '', now = () => Date.now(), loadCareFn, shared: sharedFetch, debounceMs = NAV_DEBOUNCE_MS } = {}) {
  const doc = root.ownerDocument;
  if (!root.getAttribute('lang')) root.setAttribute('lang', lang);   // tavutus (hyphens:auto) sivun kielen mukaan
  let T, opts;
  try { T = JSON.parse(root.dataset.vkTexts || ''); opts = JSON.parse(root.dataset.vkOpts || '{}'); } catch { return null; }
  if (!T || !Array.isArray(T.daysLong)) return null;
  const hrefs = shopHrefs(shopHref);
  const todayOf = () => new Date(now()).toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
  const today = todayOf();
  const cache = new Map();
  let shared = null;   // { catalog, events, horizon }
  let start = weekStartOf(today), sel = null, token = 0, target = null, timer = null, focusKind = null;

  const fetchShared = () => (shared ||= Promise.all([
    sharedFetch ? sharedFetch().then(({ events, catalog }) => [events, Array.isArray(catalog) ? catalog : null]).catch(() => [null, null]) : Promise.all([
      rpc('public_events', { p_from: today, p_channel: 'shop' }).catch(() => null),
      rpc('public_catalog', {}).then((r) => (Array.isArray(r) ? r : null)).catch(() => null),
    ]),
    rpc('public_settings', {}).catch(() => null).then(careHorizon),
  ]).then(([[events, catalog], horizon]) => ({ events, catalog, horizon })));
  const fetchWeek = (s) => {
    if (!cache.has(s)) {
      const pr = fetchShared().then(({ catalog, horizon }) => loadWeek(s, { rpc, today, catalog, horizon, loadCareFn }));
      cache.set(s, pr);
      // Puutteellista tulosta (hoidot tai viikon rivit puuttuvat) ei jätetä pysyvästi välimuistiin: seuraava näyttökerta hakee uudelleen.
      pr.then((d) => { if ((d.care == null || d.rows == null) && cache.get(s) === pr) cache.delete(s); }, () => { if (cache.get(s) === pr) cache.delete(s); });
    }
    return cache.get(s);
  };

  function draw(model, focus) {
    if (sel == null || model.days[sel]?.past) sel = model.todayIdx >= 0 ? model.todayIdx : 0;
    root.replaceChildren(...weekGridTree(model, T, { ...opts, selected: sel }).map((n) => toDom(doc, n)));
    root.classList.add('is-js');
    root.removeAttribute('aria-busy');
    root.classList.remove('is-loading');
    const f = focus && root.querySelector(`[data-vk-nav="${focus}"]:not([disabled])`);
    if (f) f.focus();
  }
  async function show(s, focus) {
    const my = ++token;
    root.setAttribute('aria-busy', 'true');
    root.classList.add('is-loading');
    const [{ events, catalog, horizon }, data] = await Promise.all([fetchShared(), fetchWeek(s)]);
    if (my !== token) return;
    const failed = data.rows == null;
    if (failed && s === weekStartOf(today) && !root.dataset.vkLive) { root.classList.remove('is-loading'); root.classList.add('is-js'); root.removeAttribute('aria-busy'); return; }   // ensimmäinen haku kaatui: staattinen varaversio jää
    const model = buildWeek({ start: s, today, now: now(), rows: data.rows, catalog, care: data.care, events, offers: data.offers, lang, hrefs, careHorizon: horizon });
    model.error = failed;
    root.dataset.vkLive = '1';
    start = s;
    draw(model, focus);
  }
  root.addEventListener('click', (ev) => {
    const t = ev.target.closest?.('[data-vk-nav],[data-vk-pick]');
    if (!t || !root.contains(t)) return;
    if (t.dataset.vkPick != null) {
      sel = +t.dataset.vkPick;
      root.querySelector('.vk-days')?.setAttribute('data-vk-sel', String(sel));
      root.querySelectorAll('.vk-day').forEach((d) => d.classList.toggle('is-on', +d.dataset.vkDay === sel));
      root.querySelectorAll('.vk-tab').forEach((b) => { const on = +b.dataset.vkPick === sel; b.classList.toggle('is-on', on); b.setAttribute('aria-pressed', String(on)); });
      return;
    }
    // Viikkoselaus viivästetään: nopea selaus hakee vain viimeisen viikon (väliviikoille ei lähetä hoitohakua).
    const kind = t.dataset.vkNav;
    if (kind === 'now') target = weekStartOf(today), focusKind = 'next', sel = null;
    else { target = clampWeek(addDaysIso(target ?? start, kind === 'next' ? 7 : -7), today); focusKind = kind; }
    clearTimeout(timer);
    timer = setTimeout(() => { const s = target; target = null; timer = null; if (s !== start || kind === 'now') show(s, focusKind); }, debounceMs);
  });
  show(start, null);
  return { show, get start() { return start; } };
}
