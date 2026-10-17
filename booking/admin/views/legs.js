// Resurssivarausten (migraatio 17) yhteiset esitystavat: tila, legit (tila / saunottaja), ylitys, elinkaari. Kaikki kentät ovat valinnaisia (vanhempi tietokanta / vanhat rivit).
import { h, fmtTime, badge } from '../ui.js';
import { missingBadge } from './therapist.js';

export const ROLE_FI = { space: 'Tila', therapist: 'Saunottaja', group: 'Sulkuryhmä' };
export const SKILL_FI = { yleinen: 'yleinen', saunotus: 'saunotus', laura: 'Laura', morsiussauna: 'morsiussauna' };
export const resName = (refs, code) => refs?.resources?.find((x) => x.code === code)?.name || code || '–';
const hhmm = (iso) => fmtTime(iso);

// Yhden legin rivi: "Hoitosauna Rauni · 15:00–16:00 · 1 hlö" / "Saunottaja (yleinen) · 15:00–15:20 · 1 hlö"
export function legText(l, refs) {
  const what = l.role === 'therapist' ? `Saunottaja${l.skill ? ` (${SKILL_FI[l.skill] || l.skill})` : ''}` : l.role === 'group' ? `${ROLE_FI.group}: ${resName(refs, l.resource_code)}` : resName(refs, l.resource_code);
  return `${what} · ${hhmm(l.starts_at)}–${hhmm(l.ends_at)}${l.persons ? ` · ${l.persons} hlö` : ''}`;
}
export const legsList = (legs, refs) => (legs?.length ? h('ul', { class: 'legs', 'aria-label': 'Resurssit' }, legs.map((l) => h('li', { class: `leg leg-${l.role}`, text: legText(l, refs) }))) : null);

// Merkit: vanha tuote, ylitys, kiintiövapaa (tyhjä taulukko jos ei mitään)
export const resourceBadges = (r) => [
  r.lifecycle === 'old' ? badge('muted lc-old', 'Vanha tuote') : null,
  r.override_reason ? badge('warn ovr', 'Ylitys') : null,
  r.quota_exempt ? badge('muted', 'Kiintiövapaa') : null,
  missingBadge(r),   // migraatio 22: Ei saunottajaa / Saunottaja sovittu
].filter(Boolean);

// Tilamerkki (vain kun varaus on resurssimallissa eli legejä tai muu kuin savusauna): "Rauni" / "Lovi"
export const spaceBadge = (r, refs) => (r.space_code && r.space_code !== 'savusauna' ? badge('space', resName(refs, r.space_code)) : null);
export const hasLegs = (r) => Array.isArray(r.legs) && r.legs.length > 0;

// Tuotekategorioiden suomenkieliset nimet (kb.products.category); tuntematon koodi näytetään sellaisenaan
export const CATEGORY_FI = { public_sauna: 'Yleiset saunavuorot', private_sauna: 'Yksityiset saunavuorot', corporate: 'Yritykset', treatment: 'Hoidot', ritual: 'Rituaalit', ceremony: 'Seremoniat', event: 'Tapahtumat', gift_card: 'Lahjakortit', season_card: 'Kausikortit', product_rental: 'Vuokrattavat tuotteet', training: 'Koulutukset', add_on: 'Lisäpalvelut' };
export const catLabel = (c) => CATEGORY_FI[c] || c || 'Ilman kategoriaa';
