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

function mountOne(textarea, Quill) {
  const id = `rich-${++seq}`;
  const input = document.createElement('input');
  input.type = 'hidden';
  input.name = textarea.name || '';
  input.id = id;
  input.dataset.richValue = '1';
  input.value = plainToEditorHtml(textarea.value);

  const toolbar = document.createElement('div');
  toolbar.className = 'rich-toolbar';
  toolbar.setAttribute('role', 'toolbar');
  const buttons = new Map();
  const groups = [['bold', 'italic', 'link', 'unlink'], ['heading', 'subheading', 'bullets', 'numbers'], ['undo', 'redo']];
  for (const actions of groups) {
    const group = document.createElement('span');
    group.className = 'rich-button-group';
    for (const action of actions) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'rich-btn';
      button.dataset.richAction = action;
      button.textContent = richText(action);
      button.title = richText(action);
      button.setAttribute('aria-label', richText(action));
      button.addEventListener('mousedown', (event) => event.preventDefault());
      buttons.set(action, button);
      group.append(button);
    }
    toolbar.append(group);
  }

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
  linkDialog.append(url, apply);

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
  }

  const quill = new Quill(editorHost, {
    theme: 'snow',
    modules: { toolbar: false, history: { delay: 500, maxStack: 100, userOnly: true } },
    formats: ['bold', 'italic', 'header', 'list', 'link'],
  });
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

  let selection = null;
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
  apply.addEventListener('click', applyLink);
  url.addEventListener('input', () => url.setCustomValidity(''));
  url.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') { event.preventDefault(); applyLink(); }
    if (event.key === 'Escape') { event.preventDefault(); linkDialog.hidden = true; restoreSelection(); }
  });

  function updateButtons() {
    // Ei quill.getFormat() ilman aluetta: se kutsuu getSelection(true), joka palauttaa vanhan valinnan
    // kesken kirjoituksen (text-change) ja hukkaa tai siirtää merkkejä.
    const range = quill.getSelection(false);
    const format = range ? quill.getFormat(range.index, range.length) : {};
    for (const [action, active] of [
      ['bold', !!format.bold], ['italic', !!format.italic],
      ['heading', format.header === 2], ['subheading', format.header === 3],
      ['bullets', format.list === 'bullet'], ['numbers', format.list === 'ordered'],
      ['link', !!format.link],
    ]) {
      buttons.get(action).classList.toggle('active', active);
      buttons.get(action).setAttribute('aria-pressed', String(active));
    }
  }
  function onAction(action) {
    if (action === 'link') {
      selection = quill.getSelection() || selection;
      url.value = quill.getFormat().link || '';
      linkDialog.hidden = false;
      url.focus();
      return;
    }
    linkDialog.hidden = true;
    if (action === 'undo' || action === 'redo') quill.history[action]();
    else if (action === 'unlink') {
      const range = linkRange(quill, quill.getSelection() || selection);
      if (range) quill.formatText(range.index, range.length, 'link', false, 'user');
    }
    else if (action === 'bold' || action === 'italic') quill.format(action, !quill.getFormat()[action], 'user');
    else if (action === 'heading' || action === 'subheading') {
      const level = action === 'heading' ? 2 : 3;
      quill.format('header', quill.getFormat().header === level ? false : level, 'user');
    } else if (action === 'bullets' || action === 'numbers') {
      const list = action === 'bullets' ? 'bullet' : 'ordered';
      quill.format('list', quill.getFormat().list === list ? false : list, 'user');
    }
    quill.focus();
    updateButtons();
  }
  for (const [action, button] of buttons) button.addEventListener('click', () => onAction(action));
  quill.on('selection-change', (range) => { if (range) selection = range; updateButtons(); });
  quill.on('text-change', updateButtons);
  updateButtons();
}

/** Korvaa vain käytössä olevat data-rich-tekstikentät. Ei lataa Quillia tyhjällä lomakkeella. */
export async function mountRichFields(root) {
  const areas = [...(root?.querySelectorAll?.('textarea[data-rich]') || [])].filter((el) => !el.disabled);
  if (!areas.length || !canHostEditor()) return;
  const Quill = await loadQuill();
  for (const area of areas) if (area.isConnected !== false) mountOne(area, Quill);
}

/** Päivitä puhdistettu HTML piilokenttiin ennen FormDatan lukua. */
export function syncRichFields(root) {
  for (const input of root?.querySelectorAll?.('input[type="hidden"][data-rich-value="1"]') || []) {
    input.value = normalizeStored(instances.get(input)?.getSemanticHTML() ?? input.value);
  }
}
