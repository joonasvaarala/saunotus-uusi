// Sisältöosion (Saunatietoa) asetukset ja URL-apurit. Kaikki nimet ja polut tulevat content/articles.json:sta (ei kovakoodausta muualla).
import { readFileSync } from 'node:fs';
import { abs, href } from '../lib.mjs';

export const cfg = JSON.parse(readFileSync(new URL('../../content/articles.json', import.meta.url), 'utf8'));
export const LANGS = ['fi', 'en'];
export const t = (lang, key, vars = {}) => String(cfg.ui[lang][key] ?? '').replace(/\{(\w+)\}/g, (_, k) => (vars[k] ?? ''));
export const label = (lang) => cfg.label[lang];

// Tagin URL-tunnus: pienet kirjaimet, diakriitit pois (ä→a, ö→o), muut merkit → '-'
export const tagSlug = (tag) => String(tag).toLowerCase().normalize('NFKD').replace(/[\u0300-\u036f]/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'x';

// Poluet (aina vinoviivalla alkavia ja päättyviä, ilman BASE-etuliitettä)
export const listPath = (lang) => cfg.path[lang];
export const articlePath = (lang, slug) => `${cfg.path[lang]}${slug}/`;
export const tagPath = (lang, slug, page = 1) => `${cfg.path[lang]}${cfg.tagSegment[lang]}/${slug}/${page > 1 ? `${cfg.pageSegment[lang]}/${page}/` : ''}`;
export const listPagePath = (lang, page = 1) => `${cfg.path[lang]}${page > 1 ? `${cfg.pageSegment[lang]}/${page}/` : ''}`;
export const articleUrl = (lang, slug) => abs(articlePath(lang, slug));
export const articleHref = (lang, slug) => href(articlePath(lang, slug));
export const listHref = (lang) => href(listPath(lang));

// Kielet, joiden osio näkyy navigaatiossa; asetetaan rakennuksessa (build.mjs) ja luetaan varauskaupan rakennuksessa tilatiedostosta.
export const dateFmt = (iso, lang) => {
  const d = new Date(iso);
  if (Number.isNaN(+d)) return '';
  return lang === 'fi'
    ? d.toLocaleDateString('fi-FI', { timeZone: 'Europe/Helsinki', day: 'numeric', month: 'numeric', year: 'numeric' })
    : d.toLocaleDateString('en-GB', { timeZone: 'Europe/Helsinki', day: 'numeric', month: 'short', year: 'numeric' });
};
export const isoDay = (iso) => new Date(iso).toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
