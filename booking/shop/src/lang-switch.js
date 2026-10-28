// Kielivalinta säilyttää näkymän: tuote, päivä, vaihe (hash) ja tilaussivun ?t=.
// Tilaussivulla ?lang=fi|en on asiakkaan oma valinta: tilauksen locale ei hyppää takaisin.
// Lähettämätön lomake tallennetaan sessionStorageen samalle hash-polulle (ei lähetetä, ei uutta varausta).

const DRAFT = 'bk-lang-draft';
const DRAFT_MS = 30 * 60 * 1000;

/** Toisen kielen sivun osoite + nykyinen haku ja hash. Tilaussivulle lisätään lang=. */
export function otherPageHref(otherBase, loc = {}) {
  const path = String(otherBase || '').split('?')[0].split('#')[0];
  const raw = String(loc.search || '');
  const sp = new URLSearchParams(raw.startsWith('?') ? raw.slice(1) : raw);
  if (/\/(?:tilaus|order)\/?$/.test(path)) sp.set('lang', /\/en\//.test(path) ? 'en' : 'fi');
  const q = sp.toString();
  return path + (q ? `?${q}` : '') + String(loc.hash || '');
}

export function saveDraft(root = typeof document !== 'undefined' ? document.getElementById('booking-app') : null, loc = typeof location !== 'undefined' ? location : { hash: '' }) {
  if (!root || typeof sessionStorage === 'undefined') return;
  const data = {};
  for (const el of root.querySelectorAll('input, textarea, select')) {
    const k = el.name || el.id;
    if (!k || el.type === 'password' || el.type === 'file' || el.type === 'hidden') continue;
    if ((el.type === 'radio' || el.type === 'checkbox') && !el.checked) continue;
    data[k] = el.type === 'checkbox' ? '1' : el.value;
  }
  try { sessionStorage.setItem(DRAFT, JSON.stringify({ hash: String(loc.hash || '').split('?')[0], data, t: Date.now() })); } catch { /* yksityinen tila */ }
}

export function restoreDraft(root, loc = typeof location !== 'undefined' ? location : { hash: '' }, now = Date.now()) {
  if (!root || typeof sessionStorage === 'undefined') return false;
  let d;
  try { d = JSON.parse(sessionStorage.getItem(DRAFT) || ''); } catch { return false; }
  if (!d || d.hash !== String(loc.hash || '').split('?')[0] || now - d.t > DRAFT_MS) return false;
  let n = 0;
  for (const [k, v] of Object.entries(d.data || {})) {
    const sel = typeof CSS !== 'undefined' && CSS.escape ? CSS.escape(k) : k.replace(/["\\]/g, '\\$&');
    for (const el of root.querySelectorAll(`[name="${sel}"], #${sel}`)) {
      if (el.type === 'radio') { if (el.value === v && !el.checked) { el.checked = true; el.dispatchEvent(new Event('change', { bubbles: true })); n++; } }
      else if (el.type === 'checkbox') { const on = v === '1' || v === 'on' || v === el.value; if (el.checked !== on) { el.checked = on; el.dispatchEvent(new Event('change', { bubbles: true })); n++; } }
      else if (el.value !== v) { el.value = v; el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true })); n++; }
    }
  }
  return n > 0;
}

/** Päivittää kielilinkin juuri ennen siirtymää, jotta replaceState-hash (valittu päivä) säilyy. */
export function bindLangLinks(otherBase) {
  if (!otherBase || typeof document === 'undefined') return;
  const apply = () => {
    const href = otherPageHref(otherBase, location);
    for (const a of document.querySelectorAll('.lang a[hreflang]')) a.setAttribute('href', href);
  };
  apply();
  window.addEventListener('hashchange', apply);
  document.querySelector('.lang')?.addEventListener('pointerenter', apply);
  document.querySelector('.lang')?.addEventListener('focusin', apply);
  document.addEventListener('click', (ev) => {
    const a = ev.target?.closest?.('.lang a[hreflang]');
    if (!a) return;
    apply();
    saveDraft();
  }, true);
  document.getElementById('booking-app')?.addEventListener('input', () => saveDraft());
}
