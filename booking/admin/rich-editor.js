// Quill 2 (2.0.3, BSD-3-Clause, Slab), vendoroitu booking/admin/vendor/quill/ (ei CDN:ää).
// Editorin JavaScript ja CSS ladataan vain, kun aktiivinen data-rich-kenttä avataan.
// XSS: editorin HTML (getSemanticHTML) kulkee aina normalizeStored-allowlistin läpi ennen piilokenttää,
// ja sama allowlist ajetaan tallennuksessa (booking._rich_text_check), kaupassa ja sähköpostissa.
// Quill 2.0.3:n CVE-2025-15056 koskee formula- ja video-upotuksia; ne eivät ole formats-listalla.
import { plainToEditorHtml, normalizeStored } from './rich-text.js';
import { richText } from './rich-texts.js';

let loading = null;
let seq = 0;
let LinkBlot = null;
const instances = new WeakMap();

function canHostEditor() {
  return typeof document !== 'undefined' && typeof document.createElement === 'function' && typeof document.head?.append === 'function';
}

function ensureCss() {
  if (document.querySelector('link[data-quill-css]')) return;
  const link = document.createElement('link');
  link.rel = 'stylesheet';
  link.href = new URL('./vendor/quill/quill.snow.css', import.meta.url).href;
  link.dataset.quillCss = '1';
  document.head.append(link);
}

function allowPlaceholders(Quill) {
  const Link = Quill.import('formats/link');
  class RichLink extends Link {
    static sanitize(href) {
      if (href === '{tilaus_linkki}' || href === '{linkki}') return href;
      return super.sanitize(href);
    }
  }
  Quill.register(RichLink, true);
  LinkBlot = RichLink;
}

/** Linkin koko alue, kun kursori on linkin sisällä ilman valintaa. */
function linkRange(quill, range) {
  if (!range || range.length > 0 || !LinkBlot || !quill.scroll?.descendant) return range;
  const [link, offset] = quill.scroll.descendant(LinkBlot, range.index);
  if (!link) return range;
  return { index: range.index - offset, length: link.length() };
}

async function loadQuill() {
  if (!canHostEditor()) throw new Error('rich-editor: selain ei tue editoria');
  if (!loading) {
    loading = new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = new URL('./vendor/quill/quill.js', import.meta.url).href;
      script.async = true;
      script.dataset.quillJs = '1';
      script.addEventListener('load', () => {
        try {
          const Quill = globalThis.Quill;
          if (typeof Quill !== 'function') throw new Error('rich-editor: Quill ei latautunut');
          allowPlaceholders(Quill);
          resolve(Quill);
        } catch (error) { reject(error); }
      }, { once: true });
      script.addEventListener('error', () => reject(new Error('rich-editor: Quill-lataus epäonnistui')), { once: true });
      document.head.append(script);
    }).catch((error) => { loading = null; throw error; });
  }
  ensureCss();
  return loading;
}

function labelText(textarea) {
  const host = textarea.closest('label, .fld');
  const span = host?.querySelector(':scope > span');
  return (span?.textContent || textarea.getAttribute('aria-label') || '').trim();
}

function escAttr(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function allowedHref(href) {
  if (!href) return false;
  const sample = `<a href="${escAttr(href)}">x</a>`;
  return normalizeStored(sample) === sample;
}

// Kumoa/Tee uudelleen -kuvakkeet Quillin omaan tyyliin (18×18, ql-stroke → sama väri kuin muut kuvakkeet).
const UNDO_ICON = '<svg viewBox="0 0 18 18" aria-hidden="true"><polyline class="ql-stroke" points="5 4 2 7 5 10"></polyline><path class="ql-stroke" d="M2.5,7H11a4,4,0,0,1,0,8H7"></path></svg>';
const REDO_ICON = '<svg viewBox="0 0 18 18" aria-hidden="true"><polyline class="ql-stroke" points="13 4 16 7 13 10"></polyline><path class="ql-stroke" d="M15.5,7H7a4,4,0,0,0,0,8h4"></path></svg>';

// Yksi kompakti kuvakerivi (Quill Snow): [luokka, arvo, tekstiavain]. Rivitys hoituu flex-wrapilla.
export const TOOLBAR_GROUPS = [
  [['bold', null, 'bold'], ['italic', null, 'italic'], ['link', null, 'link']],
  [['header', '2', 'heading'], ['header', '3', 'subheading']],
  [['list', 'bullet', 'bullets'], ['list', 'ordered', 'numbers']],
  [['clean', null, 'clean']],
  [['undo', null, 'undo'], ['redo', null, 'redo']],
];

function buildToolbar() {
  const toolbar = document.createElement('div');
  toolbar.className = 'rich-toolbar';
  toolbar.setAttribute('role', 'toolbar');
  toolbar.setAttribute('aria-label', richText('toolbar'));
  for (const group of TOOLBAR_GROUPS) {
    const span = document.createElement('span');
    span.className = 'ql-formats';
    for (const [format, value, key] of group) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = `ql-${format}`;
      if (value != null) button.value = value;
      button.title = richText(key);
      button.setAttribute('aria-label', richText(key));
      button.setAttribute('aria-pressed', 'false');
      if (format === 'undo') button.innerHTML = UNDO_ICON;
      if (format === 'redo') button.innerHTML = REDO_ICON;
      span.append(button);
    }
    toolbar.append(span);
  }
  return toolbar;
}

function mountOne(textarea, Quill) {
  const id = `rich-${++seq}`;
  const input = document.createElement('input');
  input.type = 'hidden';
  input.name = textarea.name || '';
  input.id = id;
  input.dataset.richValue = '1';
  input.value = plainToEditorHtml(textarea.value);

  const toolbar = buildToolbar();

  const linkDialog = document.createElement('div');
  linkDialog.className = 'rich-link-dialog';
  linkDialog.hidden = true;
  const url = document.createElement('input');
  url.type = 'text';
  url.placeholder = richText('url_placeholder');
  url.setAttribute('aria-label', richText('url'));
  const apply = document.createElement('button');
  apply.type = 'button';
  apply.className = 'rich-btn';
  apply.textContent = richText('link');
  const remove = document.createElement('button');
  remove.type = 'button';
  remove.className = 'rich-btn';
  remove.textContent = richText('unlink');
  remove.hidden = true;
  linkDialog.append(url, apply, remove);

  const editorHost = document.createElement('div');
  editorHost.className = 'rich-editor';
  editorHost.setAttribute('aria-label', labelText(textarea) || richText('hint'));
  // Quill ei hyväksy näitä formaatteja: kuva, video, tiedosto tai kaava.
  const wrap = document.createElement('div');
  wrap.className = 'rich-field';
  wrap.append(toolbar, linkDialog, input, editorHost);
  const label = textarea.closest('label');
  textarea.replaceWith(wrap);
  if (label?.tagName === 'LABEL') {
    const div = document.createElement('div');
    div.className = label.className;
    while (label.firstChild) div.append(label.firstChild);
    label.replaceWith(div);
    // Pelkkä työkaluriviohje on turha kuvakerivin kanssa (varatekstikentässä se jää näkyviin).
    const hint = div.querySelector?.(':scope > small');
    if (hint && hint.textContent === richText('hint')) hint.hidden = true;
  }

  let quill = null;
  let selection = null;
  function openLink() {
    selection = quill.getSelection() || selection;
    const range = linkRange(quill, selection);
    const current = range ? quill.getFormat(range.index, range.length).link : null;
    url.value = current || '';
    remove.hidden = !current;
    linkDialog.hidden = false;
    url.focus();
  }
  quill = new Quill(editorHost, {
    theme: 'snow',
    modules: {
      toolbar: {
        container: toolbar,
        handlers: {
          link: () => openLink(),
          undo: () => quill.history.undo(),
          redo: () => quill.history.redo(),
        },
      },
      history: { delay: 500, maxStack: 100, userOnly: true },
    },
    formats: ['bold', 'italic', 'header', 'list', 'link'],
  });
  wrap.classList?.add?.('rich-ready');
  const Delta = Quill.import('delta');
  for (const tag of ['IMG', 'VIDEO', 'AUDIO', 'IFRAME', 'OBJECT', 'EMBED', 'SCRIPT', 'STYLE', 'TEMPLATE', 'NOSCRIPT', 'SVG', 'MATH']) {
    quill.clipboard.addMatcher(tag, () => new Delta());
  }
  if (input.value) quill.clipboard.dangerouslyPasteHTML(input.value, 'api');
  quill.history.clear();
  const sync = () => { input.value = normalizeStored(quill.getSemanticHTML()); };
  instances.set(input, quill);
  quill.on('text-change', sync);
  sync();

  // Tiedostot ja liitteet eivät saa päätyä Deltaan edes pudottamalla tai liittämällä.
  editorHost.addEventListener('dragover', (event) => event.preventDefault(), true);
  editorHost.addEventListener('drop', (event) => event.preventDefault(), true);
  editorHost.addEventListener('paste', (event) => {
    if ([...(event.clipboardData?.items || [])].some((item) => item.kind === 'file')) event.preventDefault();
  }, true);

  function restoreSelection() {
    if (selection) quill.setSelection(selection.index, selection.length, 'silent');
    quill.focus();
  }
  function applyLink() {
    const href = url.value.trim();
    if (!allowedHref(href)) {
      url.setCustomValidity(richText('url'));
      url.reportValidity();
      return;
    }
    url.setCustomValidity('');
    restoreSelection();
    const range = linkRange(quill, selection || quill.getSelection());
    if (range && range.length > 0) quill.formatText(range.index, range.length, 'link', href, 'user');
    else if (range) {
      // Ei valintaa: lisätään osoite tekstiksi ja linkiksi (kuten aiemmin Trix).
      quill.insertText(range.index, href, { link: href }, 'user');
      quill.setSelection(range.index + href.length, 0, 'silent');
    }
    linkDialog.hidden = true;
    sync();
  }
  function removeLink() {
    restoreSelection();
    const range = linkRange(quill, selection || quill.getSelection());
    if (range) quill.formatText(range.index, range.length, 'link', false, 'user');
    linkDialog.hidden = true;
    sync();
  }
  apply.addEventListener('click', applyLink);
  remove.addEventListener('click', removeLink);
  url.addEventListener('input', () => url.setCustomValidity(''));
  url.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') { event.preventDefault(); applyLink(); }
    if (event.key === 'Escape') { event.preventDefault(); linkDialog.hidden = true; restoreSelection(); }
  });
  quill.on('selection-change', (range) => { if (range) selection = range; });
}

/** Korvaa vain käytössä olevat data-rich-tekstikentät. Ei lataa Quillia tyhjällä lomakkeella. */
export async function mountRichFields(root) {
  const areas = [...(root?.querySelectorAll?.('textarea[data-rich]') || [])].filter((el) => !el.disabled);
  if (!areas.length || !canHostEditor()) return;
  let Quill;
  try {
    Quill = await loadQuill();
  } catch (error) {
    // Varapolku vain, jos Quill ei lataudu: tavallinen, matala tekstikenttä ilman harhaanjohtavaa muotoiluohjetta.
    for (const area of areas) {
      area.classList?.add?.('rich-fallback');
      area.rows = 4;
      const hint = area.closest?.('label, .fld')?.querySelector?.(':scope > small');
      if (hint && hint.textContent === richText('hint')) hint.hidden = true;
    }
    throw error;
  }
  for (const area of areas) if (area.isConnected !== false) mountOne(area, Quill);
}

/** Päivitä puhdistettu HTML piilokenttiin ennen FormDatan lukua. */
export function syncRichFields(root) {
  for (const input of root?.querySelectorAll?.('input[type="hidden"][data-rich-value="1"]') || []) {
    input.value = normalizeStored(instances.get(input)?.getSemanticHTML() ?? input.value);
  }
}
