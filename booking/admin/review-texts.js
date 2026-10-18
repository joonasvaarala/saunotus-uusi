// Tarkista-näkymän sulkukonfliktin kuittaus (FI + EN). Avaimet: ui.admin.review.* (§18).
// Sama mekanismi kuin päivänäkymä: public_get_site_texts, kieli talous-i18n.
// Sanakirja on vain varalla. Tuonti: content/site-texts.pending-import-6.json.
import { getLang } from './talous-i18n.js';

export const REVIEW_TEXTS = {
  fi: {
    'ui.admin.review.block_hint': 'Varaus osuu myöhemmin lisättyyn sulkuun. Siirrä tai peru varaus, tai kuittaa konflikti, jos sulku ei ole todellinen (esimerkiksi käsin tehty sulku Johkussa). Kuittaus ei muuta saatavuutta.',
    'ui.admin.review.block_reason': 'Sulku: {{var:reason}}',
    'ui.admin.review.ack_button': 'Kuittaa (ei todellinen)',
    'ui.admin.review.ack_note_label': 'Perustelu',
    'ui.admin.review.ack_note_default': 'Sulku tehty käsin Johkussa',
    'ui.admin.review.ack_label_label': 'Kuittaaja (valinnainen)',
    'ui.admin.review.ack_label_placeholder': 'Esim. Joonas (päätös)',
    'ui.admin.review.ack_confirm': 'Kuitataanko sulkukonflikti ei-todelliseksi? Varaus ja sulku jäävät ennalleen, eikä saatavuus muutu.',
    'ui.admin.review.ack_confirm_button': 'Vahvista kuittaus',
    'ui.admin.review.ack_cancel': 'Peruuta',
    'ui.admin.review.ack_done': 'Sulku kuitattu ei-todelliseksi. Saatavuus ei muuttunut.',
    'ui.admin.review.ack_already': 'Konflikti oli jo kuitattu.',
    'ui.admin.review.ack_note_required': 'Anna perustelu (vähintään kolme merkkiä).',
    'ui.admin.review.acked_title': 'Kuitatut sulkukonfliktit',
    'ui.admin.review.acked_hint': 'Nämä sulkukonfliktit on kuitattu ei-todellisiksi. Saatavuus ei ole muuttunut. Kuittauksen voi purkaa.',
    'ui.admin.review.acked_meta': 'Kuitattu{{var:by}}: {{var:reason}}',
    'ui.admin.review.acked_empty': 'Ei kuitattuja sulkukonflikteja.',
    'ui.admin.review.unack_button': 'Pura kuittaus',
    'ui.admin.review.unack_confirm': 'Puretaanko kuittaus? Konflikti palaa Sulkukonfliktit-listalle. Saatavuus ei muutu.',
    'ui.admin.review.unack_confirm_button': 'Vahvista purku',
    'ui.admin.review.unack_done': 'Kuittaus purettu.',
  },
  en: {
    'ui.admin.review.block_hint': 'The booking overlaps a closure added later. Move or cancel the booking, or acknowledge the conflict if the closure is not real (for example a block added manually in Johku). Acknowledging does not change availability.',
    'ui.admin.review.block_reason': 'Closure: {{var:reason}}',
    'ui.admin.review.ack_button': 'Acknowledge (not real)',
    'ui.admin.review.ack_note_label': 'Reason',
    'ui.admin.review.ack_note_default': 'Closure added manually in Johku',
    'ui.admin.review.ack_label_label': 'Acknowledged by (optional)',
    'ui.admin.review.ack_label_placeholder': 'E.g. Joonas (decision)',
    'ui.admin.review.ack_confirm': 'Acknowledge this closure conflict as not real? The booking and the closure stay as they are, and availability does not change.',
    'ui.admin.review.ack_confirm_button': 'Confirm acknowledgement',
    'ui.admin.review.ack_cancel': 'Cancel',
    'ui.admin.review.ack_done': 'Closure conflict acknowledged as not real. Availability did not change.',
    'ui.admin.review.ack_already': 'This conflict was already acknowledged.',
    'ui.admin.review.ack_note_required': 'Enter a reason (at least three characters).',
    'ui.admin.review.acked_title': 'Acknowledged closure conflicts',
    'ui.admin.review.acked_hint': 'These closure conflicts were acknowledged as not real. Availability has not changed. An acknowledgement can be revoked.',
    'ui.admin.review.acked_meta': 'Acknowledged{{var:by}}: {{var:reason}}',
    'ui.admin.review.acked_empty': 'No acknowledged closure conflicts.',
    'ui.admin.review.unack_button': 'Revoke acknowledgement',
    'ui.admin.review.unack_confirm': 'Revoke the acknowledgement? The conflict returns to the closure-conflict list. Availability does not change.',
    'ui.admin.review.unack_confirm_button': 'Confirm revoke',
    'ui.admin.review.unack_done': 'Acknowledgement revoked.',
  },
};

const PREFIX = 'ui.admin.review.';
let db = new Map();
let loaded = false;

export function fillReviewText(text, vars) {
  return String(text ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}

function applyLive(raw, vars) {
  const tokens = [...String(raw).matchAll(/\{\{([^{}]*)\}\}/g)];
  for (const m of tokens) {
    const name = /^var:([a-z0-9_]+)$/.exec(m[1]);
    if (!name || vars?.[name[1]] == null) return null;
  }
  if (/\{\{|\}\}/.test(fillReviewText(raw, vars))) return null;
  return fillReviewText(raw, vars);
}

/** Lukee ui.admin.review.*-rivit. Virhe ei kaada näkymää: reviewText käyttää sanakirjaa. */
export async function loadReviewTexts(rpcFn) {
  if (loaded) return true;
  if (typeof rpcFn !== 'function') return false;
  try {
    const t = await rpcFn('public_get_site_texts', { p_lang: null });
    if (!t || t.ok !== true || !Array.isArray(t.texts)) return false;
    const next = new Map();
    for (const r of t.texts) {
      if (!r || typeof r.key !== 'string' || !r.key.startsWith(PREFIX)) continue;
      if (r.lang !== 'fi' && r.lang !== 'en') continue;
      if (typeof r.text !== 'string' || !r.text.trim()) continue;
      next.set(`${r.key}|${r.lang}`, r.text);
    }
    db = next;
    loaded = true;
    return true;
  } catch {
    return false;
  }
}

export function clearReviewTextCache() {
  db = new Map();
  loaded = false;
}

export function reviewText(key, vars, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  const filled = live != null ? applyLive(live, vars) : null;
  if (filled != null) return filled;
  const raw = REVIEW_TEXTS[lang]?.[key] ?? REVIEW_TEXTS.fi[key] ?? key;
  return vars ? fillReviewText(raw, vars) : raw;
}
