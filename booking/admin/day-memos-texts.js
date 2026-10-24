// Päivänäkymän muistiinpanojen, henkilöstötiedotteiden, varausmuistiinpanon ja "Seuraava oma vuoro" -painikkeen tekstit (FI + EN).
// Avaimet: ui.admin.day_memos.* (paketti 04, booking_140). Sama mekanismi kuin day-texts.js: public_get_site_texts (rpc tai
// admin_day_bundle.site_texts) peittää sanakirjan. Rivi puuttuu, haku epäonnistuu tai paikkamerkki ei täyty → DAY_MEMO_TEXTS.
// Tuonti: content/site-texts.pending-import-41.json (vain uudet avaimet).
import { getLang } from './talous-i18n.js';
import { getSiteTexts } from './site-texts-cache.js';

export const PREFIX = 'ui.admin.day_memos.';

export const DAY_MEMO_TEXTS = {
  fi: {
    'ui.admin.day_memos.bulletins_title': 'Tiedotteet',
    'ui.admin.day_memos.bulletins_aria': 'Henkilöstötiedotteet',
    'ui.admin.day_memos.bulletin_add': 'Lisää tiedote',
    'ui.admin.day_memos.bulletin_none': 'Ei voimassa olevia tiedotteita.',
    'ui.admin.day_memos.bulletin_period': 'Voimassa {{var:start}}–{{var:end}}',
    'ui.admin.day_memos.bulletin_edit': 'Muokkaa',
    'ui.admin.day_memos.bulletin_delete': 'Poista',
    'ui.admin.day_memos.bulletin_delete_confirm': 'Poistetaanko tiedote?',
    'ui.admin.day_memos.bulletin_deleted': 'Tiedote poistettu.',
    'ui.admin.day_memos.bulletin_saved': 'Tiedote tallennettu.',
    'ui.admin.day_memos.bulletin_dialog_new': 'Lisää tiedote',
    'ui.admin.day_memos.bulletin_dialog_edit': 'Muokkaa tiedotetta',
    'ui.admin.day_memos.bulletin_start': 'Alkamispäivä',
    'ui.admin.day_memos.bulletin_end': 'Päättymispäivä',
    'ui.admin.day_memos.bulletin_body': 'Viesti',
    'ui.admin.day_memos.bulletin_save': 'Tallenna tiedote',
    'ui.admin.day_memos.bulletin_invalid': 'Tarkista päivämäärät ja viesti.',
    'ui.admin.day_memos.notes_title': 'Päivän muistiinpanot',
    'ui.admin.day_memos.notes_none': 'Ei muistiinpanoja tälle päivälle.',
    'ui.admin.day_memos.note_label': 'Uusi muistiinpano',
    'ui.admin.day_memos.note_placeholder': 'Kirjoita sisäinen muistiinpano seuraavaa vuoroa varten',
    'ui.admin.day_memos.note_add': 'Lisää muistiinpano',
    'ui.admin.day_memos.note_added': 'Muistiinpano lisätty.',
    'ui.admin.day_memos.note_delete': 'Poista',
    'ui.admin.day_memos.note_delete_confirm': 'Poistetaanko muistiinpano?',
    'ui.admin.day_memos.note_deleted': 'Muistiinpano poistettu.',
    'ui.admin.day_memos.note_author_fallback': 'Henkilöstö',
    'ui.admin.day_memos.next_own_shift': 'Seuraava oma vuoro',
    'ui.admin.day_memos.next_own_shift_none': 'Ei tulevia omia työvuoroja.',
    'ui.admin.day_memos.next_own_shift_failed': 'Seuraavaa omaa vuoroa ei saatu haettua.',
    'ui.admin.day_memos.res_note_label': 'Muistiinpano / huomio',
    'ui.admin.day_memos.res_note_save': 'Tallenna muistiinpano',
    'ui.admin.day_memos.res_note_saved': 'Muistiinpano tallennettu.',
    'ui.admin.day_memos.shifts_none': 'Ei näytettäviä työvuoroja tälle päivälle.',
  },
  en: {
    'ui.admin.day_memos.bulletins_title': 'Notices',
    'ui.admin.day_memos.bulletins_aria': 'Staff notices',
    'ui.admin.day_memos.bulletin_add': 'Add notice',
    'ui.admin.day_memos.bulletin_none': 'No current notices.',
    'ui.admin.day_memos.bulletin_period': 'Valid {{var:start}}–{{var:end}}',
    'ui.admin.day_memos.bulletin_edit': 'Edit',
    'ui.admin.day_memos.bulletin_delete': 'Delete',
    'ui.admin.day_memos.bulletin_delete_confirm': 'Delete this notice?',
    'ui.admin.day_memos.bulletin_deleted': 'Notice deleted.',
    'ui.admin.day_memos.bulletin_saved': 'Notice saved.',
    'ui.admin.day_memos.bulletin_dialog_new': 'Add notice',
    'ui.admin.day_memos.bulletin_dialog_edit': 'Edit notice',
    'ui.admin.day_memos.bulletin_start': 'Start date',
    'ui.admin.day_memos.bulletin_end': 'End date',
    'ui.admin.day_memos.bulletin_body': 'Message',
    'ui.admin.day_memos.bulletin_save': 'Save notice',
    'ui.admin.day_memos.bulletin_invalid': 'Check the dates and the message.',
    'ui.admin.day_memos.notes_title': 'Notes for the day',
    'ui.admin.day_memos.notes_none': 'No notes for this day.',
    'ui.admin.day_memos.note_label': 'New note',
    'ui.admin.day_memos.note_placeholder': 'Write an internal note for the next shift',
    'ui.admin.day_memos.note_add': 'Add note',
    'ui.admin.day_memos.note_added': 'Note added.',
    'ui.admin.day_memos.note_delete': 'Delete',
    'ui.admin.day_memos.note_delete_confirm': 'Delete this note?',
    'ui.admin.day_memos.note_deleted': 'Note deleted.',
    'ui.admin.day_memos.note_author_fallback': 'Staff',
    'ui.admin.day_memos.next_own_shift': 'My next shift',
    'ui.admin.day_memos.next_own_shift_none': 'You have no upcoming shifts.',
    'ui.admin.day_memos.next_own_shift_failed': 'Your next shift could not be loaded.',
    'ui.admin.day_memos.res_note_label': 'Note',
    'ui.admin.day_memos.res_note_save': 'Save note',
    'ui.admin.day_memos.res_note_saved': 'Note saved.',
    'ui.admin.day_memos.shifts_none': 'No shifts to show for this day.',
  },
};

let db = new Map();
let loaded = false;

export function fillMemoText(text, vars) {
  return String(text ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}

/** Täyttää {{var:nimi}}. Tuntematon paikkamerkki tai puuttuva arvo → null (kutsuja käyttää sanakirjaa). */
function applyLive(raw, vars) {
  for (const m of String(raw).matchAll(/\{\{([^{}]*)\}\}/g)) {
    const name = /^var:([a-z0-9_]+)$/.exec(m[1]);
    if (!name || vars?.[name[1]] == null) return null;
  }
  const out = fillMemoText(raw, vars);
  return /\{\{|\}\}/.test(out) ? null : out;
}

export function primeMemoTexts(rows) {
  if (!Array.isArray(rows)) return false;
  const next = new Map();
  for (const r of rows) {
    if (!r || typeof r.key !== 'string' || !r.key.startsWith(PREFIX)) continue;
    if (r.lang !== 'fi' && r.lang !== 'en') continue;
    if (typeof r.text !== 'string' || !r.text.trim()) continue;
    next.set(`${r.key}|${r.lang}`, r.text);
  }
  db = next;
  loaded = true;
  return true;
}

/** Päivänipun rivit (rows) tai jaettu site_texts-välimuisti. Virhe ei kaada näkymää: memoText käyttää sanakirjaa. */
export async function loadMemoTexts(rpcFn, rows = null) {
  if (primeMemoTexts(rows)) return true;
  if (loaded) return true;
  if (typeof rpcFn !== 'function') return false;
  try {
    const t = await getSiteTexts(rpcFn);
    if (!t || t.ok !== true || !Array.isArray(t.texts)) return false;
    return primeMemoTexts(t.texts);
  } catch {
    return false;
  }
}

export function clearMemoTextCache() { db = new Map(); loaded = false; }

export function memoText(key, vars, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  const filled = live != null ? applyLive(live, vars) : null;
  if (filled != null) return filled;
  const raw = DAY_MEMO_TEXTS[lang]?.[key] ?? DAY_MEMO_TEXTS.fi[key] ?? key;
  return vars ? fillMemoText(raw, vars) : raw;
}
