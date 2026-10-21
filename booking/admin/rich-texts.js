// Hallinnan rich-text-työkalurivin tekstit (FI+EN). Tuotannossa sama sisältö tuodaan site_texts-tauluun
// (content/site-texts.pending-import-30.json). Sanakirja on varalla, kunnes tuonti on ajettu.
// Hintoja, ALV-kantoja ja osoitteita ei ole näissä teksteissä.
import { getLang } from './talous-i18n.js';

export const PREFIX = 'ui.admin.rich.';

export const RICH_TEXTS = {
  fi: {
    'ui.admin.rich.bold': 'Lihavointi',
    'ui.admin.rich.italic': 'Kursivointi',
    'ui.admin.rich.heading': 'Otsikko',
    'ui.admin.rich.subheading': 'Alaotsikko',
    'ui.admin.rich.bullets': 'Luettelo',
    'ui.admin.rich.numbers': 'Numerointi',
    'ui.admin.rich.link': 'Linkki',
    'ui.admin.rich.unlink': 'Poista linkki',
    'ui.admin.rich.url': 'Osoite',
    'ui.admin.rich.url_placeholder': 'Kirjoita osoite',
    'ui.admin.rich.undo': 'Kumoa',
    'ui.admin.rich.redo': 'Tee uudelleen',
    'ui.admin.rich.hint': 'Voit lihavoida, kursivoida, lisätä otsikon, luettelon ja linkin.',
    'ui.admin.rich.hint_message': 'Voit lihavoida, kursivoida, lisätä otsikon, luettelon ja linkin. Paikkamerkit, kuten {asiakas_nimi}, kirjoitetaan tekstin sekaan.',
  },
  en: {
    'ui.admin.rich.bold': 'Bold',
    'ui.admin.rich.italic': 'Italic',
    'ui.admin.rich.heading': 'Heading',
    'ui.admin.rich.subheading': 'Subheading',
    'ui.admin.rich.bullets': 'Bullet list',
    'ui.admin.rich.numbers': 'Numbered list',
    'ui.admin.rich.link': 'Link',
    'ui.admin.rich.unlink': 'Remove link',
    'ui.admin.rich.url': 'Address',
    'ui.admin.rich.url_placeholder': 'Enter an address',
    'ui.admin.rich.undo': 'Undo',
    'ui.admin.rich.redo': 'Redo',
    'ui.admin.rich.hint': 'You can use bold, italic, a heading, a list and a link.',
    'ui.admin.rich.hint_message': 'You can use bold, italic, a heading, a list and a link. Placeholders such as {asiakas_nimi} stay in the text.',
  },
};

let db = new Map();
let loaded = false;

export async function loadRichTexts(rpcFn) {
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

export function clearRichTextCache() {
  db = new Map();
  loaded = false;
}

export function richText(key, lang = getLang()) {
  const full = key.startsWith(PREFIX) ? key : PREFIX + key;
  const live = db.get(`${full}|${lang}`);
  if (live) return live;
  return RICH_TEXTS[lang]?.[full] || RICH_TEXTS.fi[full] || key;
}
