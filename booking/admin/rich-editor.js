// Kevyt työkalurivi tuotekuvauksille ja Viestit-kentille. Trix 2.1.15 (MIT, 37signals),
// vendoroitu booking/admin/vendor/trix/. Ei bundleria: ESM ladataan vasta kun lomake aukeaa.
// Oletuslohko on p, otsikko on h2 ja alaotsikko h3. Liitteet estetään.
import { plainToEditorHtml, normalizeStored } from './rich-text.js';
import { richText } from './rich-texts.js';

let loading = null;
let seq = 0;

function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function ensureCss() {
  if (document.querySelector('link[data-trix-css]')) return;
  const link = document.createElement('link');
  link.rel = 'stylesheet';
  link.href = new URL('./vendor/trix/trix.css', import.meta.url).href;
  link.dataset.trixCss = '1';
  document.head.append(link);
}

function canHostEditor() {
  if (typeof customElements === 'undefined' || typeof document === 'undefined') return false;
  return typeof customElements.whenDefined === 'function' && typeof document.head?.append === 'function';
}

async function loadTrix() {
  if (!canHostEditor()) throw new Error('rich-editor: selain ei tue editoria');
  if (!loading) {
    loading = (async () => {
      try {
        const mod = await import('./vendor/trix/trix.esm.min.js');
        const Trix = mod.default;
        Trix.config.blockAttributes.default.tagName = 'p';
        Trix.config.blockAttributes.heading1.tagName = 'h2';
        Trix.config.blockAttributes.heading2 = { tagName: 'h3', terminal: true, breakOnReturn: true, group: false };
        ensureCss();
        await customElements.whenDefined('trix-editor');
        document.addEventListener('trix-file-accept', (ev) => ev.preventDefault());
        document.addEventListener('trix-attachment-add', (ev) => ev.attachment?.remove?.());
        return Trix;
      } catch (e) {
        loading = null;
        throw e;
      }
    })();
  }
  return loading;
}

function labels() {
  return {
    bold: richText('bold'),
    italic: richText('italic'),
    heading: richText('heading'),
    subheading: richText('subheading'),
    bullets: richText('bullets'),
    numbers: richText('numbers'),
    link: richText('link'),
    unlink: richText('unlink'),
    url: richText('url'),
    urlPlaceholder: richText('url_placeholder'),
    undo: richText('undo'),
    redo: richText('redo'),
  };
}

function toolbarHtml(L) {
  const btn = (label, attr, action) => `<button type="button" class="trix-button rich-btn" ${attr ? `data-trix-attribute="${attr}"` : ''} ${action ? `data-trix-action="${action}"` : ''} title="${esc(label)}">${esc(label)}</button>`;
  return `<div class="trix-button-row">
    <span class="trix-button-group" data-trix-button-group="text-tools">
      ${btn(L.bold, 'bold')}${btn(L.italic, 'italic')}${btn(L.link, 'href', 'link')}
    </span>
    <span class="trix-button-group" data-trix-button-group="block-tools">
      ${btn(L.heading, 'heading1')}${btn(L.subheading, 'heading2')}${btn(L.bullets, 'bullet')}${btn(L.numbers, 'number')}
    </span>
    <span class="trix-button-group" data-trix-button-group="history-tools">
      ${btn(L.undo, '', 'undo')}${btn(L.redo, '', 'redo')}
    </span>
  </div>
  <div class="trix-dialogs" data-trix-dialogs>
    <div class="trix-dialog trix-dialog--link" data-trix-dialog="href" data-trix-dialog-attribute="href">
      <div class="trix-dialog__link-fields">
        <input type="text" name="href" class="trix-input trix-input--dialog" placeholder="${esc(L.urlPlaceholder)}" aria-label="${esc(L.url)}" data-trix-validate-href required data-trix-input>
        <div class="trix-button-group">
          <input type="button" class="trix-button trix-button--dialog" value="${esc(L.link)}" data-trix-method="setAttribute">
          <input type="button" class="trix-button trix-button--dialog" value="${esc(L.unlink)}" data-trix-method="removeAttribute">
        </div>
      </div>
    </div>
  </div>`;
}

function labelText(textarea) {
  const host = textarea.closest('label, .fld');
  const span = host?.querySelector(':scope > span');
  return (span?.textContent || textarea.getAttribute('aria-label') || '').trim();
}

function mountOne(textarea) {
  const id = `rich-${++seq}`;
  const input = document.createElement('input');
  input.type = 'hidden';
  input.id = id;
  input.name = textarea.name || '';
  input.value = plainToEditorHtml(textarea.value);
  input.dataset.richValue = '1';
  const bar = document.createElement('trix-toolbar');
  bar.id = `${id}-bar`;
  bar.innerHTML = toolbarHtml(labels());
  const editor = document.createElement('trix-editor');
  editor.setAttribute('input', id);
  editor.setAttribute('toolbar', bar.id);
  editor.setAttribute('aria-label', labelText(textarea) || richText('hint'));
  editor.classList.add('rich-editor');
  const wrap = document.createElement('div');
  wrap.className = 'rich-field';
  wrap.append(bar, input, editor);
  const host = textarea.closest('label');
  textarea.replaceWith(wrap);
  if (host && host.tagName === 'LABEL') {
    const div = document.createElement('div');
    div.className = host.className;
    while (host.firstChild) div.append(host.firstChild);
    host.replaceWith(div);
  }
  editor.addEventListener('trix-file-accept', (ev) => ev.preventDefault());
  editor.addEventListener('trix-attachment-add', (ev) => ev.attachment?.remove?.());
}

/** Korvaa data-rich-tekstikentät editorilla. Pois käytöstä oleva kenttä jää tekstialueeksi.
 *  Kutsu vasta kun lomake on dialogissa: editori latautuu taustalla, tekstialue kelpaa siihen asti. */
export async function mountRichFields(root) {
  const areas = [...(root?.querySelectorAll?.('textarea[data-rich]') || [])].filter((el) => !el.disabled);
  if (!areas.length || !canHostEditor()) return;
  await loadTrix();
  for (const area of areas) if (area.isConnected !== false) mountOne(area);
}

/** Kirjoita puhdistettu HTML piilokenttiin ennen FormDataa. */
export function syncRichFields(root) {
  for (const input of root?.querySelectorAll?.('input[data-rich-value]') || []) input.value = normalizeStored(input.value);
}
