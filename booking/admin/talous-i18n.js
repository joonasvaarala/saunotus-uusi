// Talous-näkymien kieli (FI/EN). Muu hallinta on toistaiseksi vain suomeksi; Talous-sivulla on FI/EN-valitsin. Kieli: ?lang=en (osoitteessa tai #/talous?lang=en) → localStorage → fi.
// Puhdas moduuli (ei riippuvuuksia, DOM-viitteet suojattu) → node --test voi tarkistaa, että kaikki avaimet löytyvät molemmilla kielillä.
import { TEXTS } from './talous-texts.js';
export const LANGS = ['fi', 'en'];
const KEY = 'booking.admin.lang';
const LOCALE = { fi: 'fi-FI', en: 'en-GB' };
const TZ = 'Europe/Helsinki';
function initial() {
  try {
    const q = new URLSearchParams(typeof location !== 'undefined' ? location.search : ''), hq = new URLSearchParams(typeof location !== 'undefined' ? (location.hash || '').split('?')[1] || '' : '');
    const l = hq.get('lang') || q.get('lang') || (typeof localStorage !== 'undefined' ? localStorage.getItem(KEY) : null);
    return LANGS.includes(l) ? l : 'fi';
  } catch { return 'fi'; }
}
let lang = initial();
export const getLang = () => lang;
export function setLang(l) { if (!LANGS.includes(l)) return; lang = l; try { localStorage.setItem(KEY, l); } catch { /* yksityinen selaus */ } }
export function t(key, vars) {
  const v = TEXTS[lang][key] ?? TEXTS.fi[key];
  if (v == null) return key;
  if (typeof v === 'function') return v(vars || {});
  return vars ? v.replace(/\{(\w+)\}/g, (_, k) => (vars[k] == null ? '' : vars[k])) : v;
}
export const has = (key) => TEXTS.fi[key] != null;
const nf = (o) => new Intl.NumberFormat(LOCALE[lang], o);
const df = (o) => new Intl.DateTimeFormat(LOCALE[lang], { timeZone: TZ, ...o });
export const fmt = {
  money: (n) => (n == null || n === '' ? '–' : nf({ style: 'currency', currency: 'EUR' }).format(+n)),
  int: (n) => nf({ maximumFractionDigits: 0 }).format(+n || 0),
  pct: (n) => `${nf({ maximumFractionDigits: 2 }).format(+n || 0)} %`,
  date: (iso) => (iso ? df({ day: 'numeric', month: 'numeric', year: 'numeric' }).format(new Date(iso.length === 10 ? `${iso}T12:00:00Z` : iso)) : '–'),
  time: (iso) => df({ hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(iso)).replace('.', ':'),
  dt: (iso) => (iso ? `${fmt.date(iso)} ${fmt.time(iso)}` : '–'),
  month: (ym) => df({ month: 'long', year: 'numeric' }).format(new Date(`${ym}-15T12:00:00Z`)),
};
