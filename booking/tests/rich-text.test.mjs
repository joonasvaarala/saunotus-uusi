// node --test booking/tests/rich-text.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '../..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const rt = await import(pathToFileURL(join(root, 'booking/shared/rich-text.js')).href);
const { fillMessage } = await import(pathToFileURL(join(root, 'booking/admin/messages-logic.js')).href);

const COPIES = [
  'booking/shared/rich-text.js',
  'booking/admin/rich-text.js',
  'booking/shop/src/rich-text.js',
  'booking/supabase/functions/_shared/rich-text.js',
];

test('allowlist-kopiot ovat samat tavut', () => {
  const a = read(COPIES[0]);
  for (const p of COPIES.slice(1)) assert.equal(read(p), a, p);
});

test('skripti, onerror ja javascript-linkki katoavat', () => {
  assert.equal(rt.sanitizeRich('<p>Hei</p><script>alert(1)</script>'), '<p>Hei</p>');
  assert.equal(rt.sanitizeRich('<p>Hei<img src=x onerror="alert(1)"></p>'), '<p>Hei</p>');
  assert.equal(rt.sanitizeRich('<p onclick="alert(1)">Hei</p>'), '<p>Hei</p>');
  assert.equal(rt.sanitizeRich('<p style="color:red">Hei</p>'), '<p>Hei</p>');
  assert.equal(rt.sanitizeRich('<p><a href="javascript:alert(1)">x</a></p>'), '<p>x</p>');
  assert.equal(rt.sanitizeRich('<p><a href="JAVASCRIPT:alert(1)">x</a></p>'), '<p>x</p>');
  assert.equal(rt.sanitizeRich('<p><a href="java\nscript:alert(1)">x</a></p>'), '<p>x</p>');
  assert.equal(rt.sanitizeRich('<p><a href="&#106;avascript:alert(1)">x</a></p>'), '<p>x</p>');
  assert.equal(rt.sanitizeRich('<p><a href="data:text/html,hi">x</a></p>'), '<p>x</p>');
  assert.equal(rt.sanitizeRich('<p><a href="//evil.example">x</a></p>'), '<p>x</p>');
  assert.equal(rt.sanitizeRich('<script>alert(1)</script>'), '');
  assert.equal(rt.isRichHtml('Teksti <script>'), false);
});

test('sallittu muotoilu, paikkamerkit ja osoitteet säilyvät', () => {
  const html = '<p>Hei {asiakas_nimi}</p><h2>Otsikko</h2><h3>Ala</h3><ul><li>yksi</li></ul><ol><li>kaksi</li></ol><p><strong>b</strong> <em>i</em> <a href="https://example.com/a">linkki</a> <a href="mailto:a@b.fi">posti</a> <a href="{tilaus_linkki}">tilaus</a> <a href="{linkki}">nappi</a></p>';
  const clean = rt.sanitizeRich(html);
  assert.match(clean, /<p>Hei \{asiakas_nimi\}<\/p>/);
  assert.match(clean, /<h2>Otsikko<\/h2>/);
  assert.match(clean, /<h3>Ala<\/h3>/);
  assert.match(clean, /<ul><li>yksi<\/li><\/ul>/);
  assert.match(clean, /<ol><li>kaksi<\/li><\/ol>/);
  assert.match(clean, /<strong>b<\/strong>/);
  assert.match(clean, /<em>i<\/em>/);
  assert.match(clean, /href="https:\/\/example\.com\/a"/);
  assert.match(clean, /href="mailto:a@b\.fi"/);
  assert.match(clean, /href="\{tilaus_linkki\}"/);
  assert.match(clean, /href="\{linkki\}"/);
  assert.equal(clean.includes('style='), false);
});

test('h1, div ja tyhjä editori', () => {
  assert.equal(rt.sanitizeRich('<h1>Iso</h1><div>Lohko</div>'), '<h2>Iso</h2><p>Lohko</p>');
  assert.equal(rt.sanitizeRich('<p><br></p>'), '');
  assert.equal(rt.normalizeStored('  <p><br></p>  '), '');
  assert.equal(rt.normalizeStored('  Tavallinen rivi  '), 'Tavallinen rivi');
});

test('vanha pelkkä teksti näyttää samalta ja editori säilyttää rivinvaihdot', () => {
  const plain = 'Ensimmäinen rivi\nToinen\n\nUusi kappale';
  assert.equal(rt.isRichHtml(plain), false);
  assert.equal(rt.toPlainText(plain), plain);
  assert.equal(rt.richToText(plain), plain);
  assert.equal(rt.plainToEditorHtml(plain), '<p>Ensimmäinen rivi<br>Toinen</p><p>Uusi kappale</p>');
  assert.equal(rt.toPlainText('<p>Hei <strong>sauna</strong></p>'), 'Hei sauna');
});

test('sähköpostin teksti ja inline-HTML', () => {
  const src = '<h2>Otsikko</h2><p>Katso <a href="https://example.com/a">ohje</a>.</p><ul><li>Pyyhe</li><li>Vettä</li></ul><ol><li>A</li><li>B</li></ol>';
  assert.equal(rt.richToText(src), 'Otsikko\n\nKatso ohje (https://example.com/a).\n\n• Pyyhe\n• Vettä\n\n1. A\n2. B');
  const html = rt.emailHtml(src, { p: 'margin:0', h2: 'color:#1f3d2b', a: 'color:#1f3d2b', li: 'margin:0', ul: 'padding:0', ol: 'padding:0' });
  assert.match(html, /<h2 style="color:#1f3d2b">/);
  assert.match(html, /<a style="color:#1f3d2b" href="https:\/\/example\.com\/a">/);
  assert.equal(html.includes('<script'), false);
  assert.equal(rt.emailHtml('pelkkä teksti'), null);
});

test('asiakkaan nimi ei pääse tagiksi paikkamerkin kautta', () => {
  const attack = '<a href="https://evil.example/pay">Maksa lisämaksu</a>';
  const plain = fillMessage('Hei {asiakas_nimi}', { asiakas_nimi: attack });
  assert.equal(plain.includes('<'), false);
  assert.equal(rt.isRichHtml('Hei {asiakas_nimi}'), false);
  assert.equal(rt.isRichHtml(plain), false);
  const filled = fillMessage('<p>Hei {asiakas_nimi}</p>', { asiakas_nimi: 'A</p><script>alert(1)</script><p>' });
  assert.equal(rt.isRichHtml('<p>Hei {asiakas_nimi}</p>'), true);
  assert.equal(/<(script|a)\b/i.test(filled), false);
  const clean = rt.sanitizeRich(filled);
  assert.equal(clean.startsWith('<p>Hei A'), true);
  assert.equal(/<(script|a)\b/i.test(clean), false);
});

test('pending-import-30: työkalurivin tekstit, 26 riviä, FI+EN, ei hintoja eikä osoitteita', async () => {
  const pending = JSON.parse(read('content/site-texts.pending-import-30.json'));
  const { RICH_TEXTS } = await import(pathToFileURL(join(root, 'booking/admin/rich-texts.js')).href);
  const keys = new Set();
  assert.equal(pending.length, 28);
  for (const row of pending) {
    assert.equal(row.class, 'normal');
    assert.equal(row.kind, 'plain');
    assert.deepEqual(row.placeholders, []);
    assert.match(row.key, /^ui\.admin\.rich\./);
    assert.ok(row.lang === 'fi' || row.lang === 'en');
    assert.equal(row.text, RICH_TEXTS[row.lang][row.key]);
    assert.doesNotMatch(row.text, /\d|€|@|https?:|www\./);
    keys.add(`${row.key}|${row.lang}`);
  }
  for (const lang of ['fi', 'en']) {
    for (const key of Object.keys(RICH_TEXTS[lang])) assert.ok(keys.has(`${key}|${lang}`), key);
  }
  assert.equal(keys.size, Object.keys(RICH_TEXTS.fi).length * 2);
});

test('migraatio 122 vaihtaa vain kuvauksen lajin ja pituuden', () => {
  const sql = read('booking/supabase/migrations/20261021171915_booking_122_rich_text.sql');
  const back = read('booking/supabase/rollbacks/20261021171915_booking_122_ROLLBACK.sql');
  assert.match(sql, /kind in \('plain', 'lite', 'rich'\)/);
  assert.match(sql, /booking\._rich_text_check/);
  assert.match(sql, /javascript/);
  const check = sql.slice(sql.indexOf('function booking._rich_text_check'), sql.indexOf('revoke all on function booking._rich_text_check'));
  assert.doesNotMatch(check, /p_text ~\* 'data/);
  assert.match(check, /href\\s\*=\\s\*\[''"]\?\\s\*\(javascript\|vbscript\|data\)/);
  assert.ok(sql.includes("translate(coalesce(p_vars ->> k, ''), '<>\"'"));
  assert.match(sql, /function booking\.admin_update_product/i);
  assert.match(sql, /function booking\.admin_product_create/i);
  assert.match(sql, /position\('<' in/);
  assert.match(sql, /booking\._message_is_rich/);
  assert.match(sql, /set kind = 'rich', max_len = 8000/);
  assert.match(sql, /source_column in \('description', 'description_en'\)/);
  assert.doesNotMatch(sql, /set published_text/i);
  assert.match(back, /set kind = 'plain', max_len = 4000/);
  assert.match(back, /kind in \('plain', 'lite'\)/);
  assert.match(back, /drop function if exists booking\._rich_text_check/);
  assert.match(back, /comment on column booking\.site_texts\.kind is null;/);
  assert.match(back, /coalesce\(p_vars ->> k, ''\)/);
  assert.doesNotMatch(back, /translate\(coalesce\(p_vars/);
  assert.match(read('booking/admin/vendor/quill/quill.js.LICENSE.txt'), /Quill Editor v2\.0\.3/);
  assert.match(read('booking/admin/rich-editor.js'), /Quill 2/);
  assert.doesNotMatch(read('booking/admin/views/products.js'), /asiakas_nimi/);
  assert.match(read('booking/admin/views/messages.js'), /hint_message/);
  assert.doesNotMatch(read('booking/admin/rich-texts.js').match(/'ui\.admin\.rich\.hint': '([^']+)'/)[1], /asiakas_nimi/);
  assert.match(read('booking/shop/build.mjs'), /rich-text\.js/);
  assert.match(read('booking/shop/build.mjs'), /invoice-validate\.js/);
  assert.match(read('booking/shop/src/shop.js'), /richHost/);
  assert.match(read('booking/shop/src/order.js'), /richHost/);
  assert.match(read('booking/admin/views/messages.js'), /data-rich/);
  assert.match(read('booking/admin/views/products.js'), /data-rich/);
});

test('Quill 2 on vendoroitu paikallisesti BSD-3-Clause-lisenssillä, eikä Trixiä tarvita', () => {
  assert.match(read('booking/admin/vendor/quill/quill.js.LICENSE.txt'), /Quill Editor v2\.0\.3/);
  assert.match(read('booking/admin/vendor/quill/LICENSE'), /Redistribution and use in source and binary forms/);
  assert.match(read('booking/admin/vendor/quill/quill.snow.css'), /\.ql-editor/);
  assert.match(read('booking/admin/vendor/quill/quill.js'), /sourceMappingURL|function/);
  const editor = read('booking/admin/rich-editor.js');
  assert.match(editor, /vendor\/quill\/quill\.js/);
  assert.match(editor, /vendor\/quill\/quill\.snow\.css/);
  assert.match(editor, /plainToEditorHtml/);
  assert.match(editor, /normalizeStored/);
  assert.doesNotMatch(editor, /vendor\/trix|https?:\/\/cdn/);
});

test('Quill-editori ladataan vain aktiiviseen kenttään; tallennus käyttää piilokenttää', async () => {
  const { mountRichFields, syncRichFields } = await import(pathToFileURL(join(root, 'booking/admin/rich-editor.js')).href);
  const oldDoc = globalThis.document;
  const oldQuill = globalThis.Quill;
  const created = [];
  const mounted = [];
  class Element {
    constructor(name) {
      this.tagName = name.toUpperCase();
      this.children = []; this.parentNode = null; this.listeners = {};
      this.dataset = {}; this.attributes = {}; this.className = '';
      this.classList = { toggle() {} };
      this.isConnected = true; this.value = '';
      created.push(this);
    }
    append(...items) {
      for (const item of items) {
        if (item.parentNode) item.parentNode.children.splice(item.parentNode.children.indexOf(item), 1);
        this.children.push(item); item.parentNode = this;
      }
    }
    get firstChild() { return this.children[0] || null; }
    replaceWith(item) {
      const p = this.parentNode;
      if (p) { p.children.splice(p.children.indexOf(this), 1, item); item.parentNode = p; }
      this.isConnected = false;
    }
    closest(selector) {
      if (selector === 'label' || selector === 'label, .fld') return this.label || null;
      return null;
    }
    querySelector(selector) { return selector === ':scope > span' ? { textContent: 'Kuvaus' } : null; }
    setAttribute(name, value) { this.attributes[name] = String(value); }
    getAttribute(name) { return this.attributes[name] || ''; }
    addEventListener(name, listener) { this.listeners[name] = listener; }
    focus() {}
    setCustomValidity() {}
    reportValidity() { return true; }
  }
  class MockLink { static sanitize(href) { return href; } }
  class MockQuill {
    static import(key) { return key === 'delta' ? class Delta {} : MockLink; }
    static register() {}
    constructor(host, options) {
      mounted.push(this);
      this.host = host; this.options = options; this.handlers = {};
      this.history = { clear() {}, undo() {}, redo() {} };
      this.clipboard = { addMatcher() {}, dangerouslyPasteHTML: (html) => { this.html = html; } };
      this.html = '<p><br></p>';
    }
    getSemanticHTML() { return this.html; }
    hasFocus() { return !!this.focused; }
    get selection() { return { savedRange: { index: 0, length: 3 } }; }
    getModule(name) { return name === 'toolbar' ? { update: (range) => { this.updated = range; } } : null; }
    on(name, cb) { this.handlers[name] = cb; }
    getFormat() { return {}; }
    getSelection() { return { index: 0, length: 1 }; }
    format() {}
    focus() {}
    setSelection() {}
  }
  const head = new Element('head');
  head.append = (...nodes) => {
    for (const node of nodes) {
      head.children.push(node);
      if (node.tagName === 'SCRIPT') queueMicrotask(() => node.listeners.load());
    }
  };
  globalThis.document = {
    head,
    createElement: (name) => new Element(name),
    querySelector: (selector) => selector === 'link[data-quill-css]' ? head.children.find((node) => node.dataset.quillCss) : null,
  };
  globalThis.Quill = MockQuill;
  try {
    const noFields = { querySelectorAll: () => [] };
    await mountRichFields(noFields);
    assert.equal(head.children.length, 0, 'Ei tiedostoja ilman aktiivista textarea-kenttää');
    const disabled = new Element('textarea'); disabled.disabled = true;
    await mountRichFields({ querySelectorAll: () => [disabled] });
    assert.equal(head.children.length, 0, 'Pois käytöstä oleva textarea ei lataa editoria');

    const form = new Element('form');
    const label = new Element('label'); label.className = 'fld';
    const area = new Element('textarea'); area.name = 'description'; area.value = 'Moi {asiakas_nimi}'; area.label = label;
    label.append(area); form.append(label);
    await mountRichFields({ querySelectorAll: () => [area] });
    assert.equal(mounted.length, 1);
    assert.deepEqual(head.children.map((el) => el.tagName).sort(), ['LINK', 'SCRIPT']);
    assert.deepEqual(mounted[0].options.formats, ['bold', 'italic', 'header', 'list', 'link']);
    // Snow-teema ja Quillin oma kuvakerivi (ei omia tekstipainikkeita, ei toolbar: false).
    const opts = mounted[0].options;
    assert.equal(opts.theme, 'snow');
    const tb = opts.modules.toolbar.container;
    assert.ok(tb && tb.tagName === 'DIV', 'toolbar-kontti annetaan Quillille');
    assert.equal(tb.attributes.role, 'toolbar');
    assert.equal(tb.attributes['aria-label'], 'Tekstin muotoilu');
    const btns = tb.children.flatMap((g) => { assert.equal(g.className, 'ql-formats'); return g.children; });
    assert.deepEqual(btns.map((b) => `${b.className}${b.value ? '=' + b.value : ''}`),
      ['ql-bold', 'ql-italic', 'ql-link', 'ql-header=2', 'ql-header=3', 'ql-list=bullet', 'ql-list=ordered', 'ql-clean', 'ql-undo', 'ql-redo']);
    assert.deepEqual(btns.map((b) => b.attributes['aria-label']),
      ['Lihavointi', 'Kursivointi', 'Linkki', 'Otsikko', 'Alaotsikko', 'Luettelo', 'Numerointi', 'Poista muotoilu', 'Kumoa', 'Tee uudelleen']);
    for (const b of btns) { assert.equal(b.title, b.attributes['aria-label']); assert.equal(b.type, 'button'); assert.ok(!b.textContent, 'kuvake, ei tekstiä'); }
    assert.ok(btns.find((b) => b.className === 'ql-undo').innerHTML.includes('<svg'));
    assert.deepEqual(Object.keys(opts.modules.toolbar.handlers).sort(), ['link', 'redo', 'undo']);
    // Toggle-regressio (#154): painike ei vie fokusta (mousedown preventDefault), ja jos fokus silti lähti,
    // ql-active päivitetään tallennetusta valinnasta ennen Quillin click-käsittelyä (capture).
    for (const b of btns) {
      let prevented = false;
      b.listeners.mousedown({ preventDefault() { prevented = true; } });
      assert.ok(prevented, `${b.className} mousedown ei saa viedä fokusta`);
    }
    mounted[0].focused = true; tb.listeners.click();
    assert.equal(mounted[0].updated, undefined, 'fokuksessa Quill hoitaa tilan itse');
    mounted[0].focused = false; tb.listeners.click();
    assert.deepEqual(mounted[0].updated, { index: 0, length: 3 });
    assert.ok(opts.modules.history);
    const hidden = created.find((el) => el.tagName === 'INPUT' && el.dataset.richValue === '1');
    assert.equal(hidden.name, 'description');
    assert.equal(hidden.type, 'hidden');
    assert.equal(hidden.value, '<p>Moi {asiakas_nimi}</p>');
    mounted[0].html = '<p><strong>Moi</strong> <img src=x> {tilaus_linkki}</p>';
    syncRichFields({ querySelectorAll: () => [hidden] });
    assert.equal(hidden.value, '<p><strong>Moi</strong>  {tilaus_linkki}</p>');
    mounted[0].html = '<p><br></p>';
    syncRichFields({ querySelectorAll: () => [hidden] });
    assert.equal(hidden.value, '');
    // Uusi mount ei saa ladata skriptiä tai CSS:ää uudelleen.
    const other = new Element('textarea'); other.name = 'body'; other.label = label;
    label.append(other);
    await mountRichFields({ querySelectorAll: () => [other] });
    assert.equal(head.children.length, 2);
    assert.equal(mounted.length, 2, 'viestikenttä saa oman Quill-editorin');
    assert.equal(mounted[1].options.theme, 'snow');
    assert.ok(mounted[1].options.modules.toolbar.container !== mounted[0].options.modules.toolbar.container);
  } finally {
    if (oldDoc === undefined) delete globalThis.document; else globalThis.document = oldDoc;
    if (oldQuill === undefined) delete globalThis.Quill; else globalThis.Quill = oldQuill;
  }
});

test('Quill: työkalurivin tila ei siirrä kursoria kirjoittaessa (getFormat vain annetulla alueella)', async () => {
  // Regressio: quill.getFormat() ilman aluetta kutsuu getSelection(true), joka palauttaa vanhan valinnan
  // kesken text-change-tapahtuman ja hukkaa merkkejä. Aktiivitilan päivittää nyt Quillin oma toolbar-moduuli
  // (getFormat(range)); omassa koodissa getFormat kutsutaan vain annetulla alueella.
  const editor = read('booking/admin/rich-editor.js');
  assert.doesNotMatch(editor, /quill\.getFormat\(\)/);
  assert.doesNotMatch(editor, /on\('text-change', updateButtons\)/);
  for (const tag of ['IMG', 'IFRAME', 'SCRIPT', 'STYLE', 'SVG']) assert.match(editor, new RegExp(`'${tag}'`));
  assert.doesNotMatch(editor, /formats: \[[^\]]*(image|video|formula|code-block|color|background)/);
});

test('Quill-vendor: versioitu 2.0.3, ei source mapia eikä ulkoisia osoitteita, hallinnan build tarkistaa tiedostot', () => {
  const js = read('booking/admin/vendor/quill/quill.js');
  const css = read('booking/admin/vendor/quill/quill.snow.css');
  assert.doesNotMatch(js, /sourceMappingURL/);
  assert.doesNotMatch(css, /sourceMappingURL/);
  assert.match(css, /Quill Editor v2\.0\.3/);
  assert.match(read('booking/admin/vendor/quill/LICENSE'), /Slab/);
  const pages = read('scripts/build-pages.mjs');
  for (const f of ['rich-editor.js', 'vendor/quill/quill.js', 'vendor/quill/quill.snow.css', 'vendor/quill/LICENSE']) assert.ok(pages.includes(`'${f}'`), f);
  const doc = read('docs/rich-text.md');
  assert.match(doc, /BSD-3-Clause/);
  assert.match(doc, /CVE-2025-15056/);
  // Hallinnan CSS: linkki ruskea, ei Quillin sinistä oletusta.
  const adminCss = read('booking/admin/admin.css');
  assert.match(adminCss, /\.rich-field \.ql-editor a\{color:var\(--gold\)/);
  assert.doesNotMatch(adminCss.slice(adminCss.indexOf('/* Rich-teksti (Quill 2)'), adminCss.indexOf('@media(min-width:700px){.pos-grid')), /#06c|blue/i);
});

test('Quill alustetaan tuotekuvauksille (FI+EN) ja viestiteksteille; ei omaa tekstipainikeriviä', () => {
  const products = read('booking/admin/views/products.js');
  const messages = read('booking/admin/views/messages.js');
  for (const name of ['description', 'description_en']) assert.ok(products.includes(`inp('${name}', p.${name}, { area: true, 'data-rich': '1' })`), name);
  for (const name of ['short_fi', 'short_en', 'body_fi', 'body_en']) assert.ok(messages.includes(`inp('${name}', row.${name}, { area: true, 'data-rich': '1' })`), name);
  for (const src of [products, messages]) assert.match(src, /await mountRichFields\(f\)/);
  const editor = read('booking/admin/rich-editor.js');
  assert.doesNotMatch(editor, /toolbar: false/);
  assert.match(editor, /theme: 'snow'/);
  assert.doesNotMatch(editor, /rich-button-group|data-rich-action/);
  // Ei omia format(x, true) -käsittelijöitä: bold/italic/header/list/clean jäävät Quillin toggle-logiikalle.
  assert.doesNotMatch(editor, /handlers: \{[^}]*\b(bold|italic|header|list|clean)\s*:/);
  assert.doesNotMatch(editor, /\.format\('(bold|italic|header|list)', true/);
  assert.match(editor, /addEventListener\('mousedown', \(event\) => event\.preventDefault\(\)\)/);
  assert.match(editor, /savedRange/);
});

test('Quill-kuvakerivi: kompakti myös mobiilissa, talon värit, ei Quillin sinistä', () => {
  const css = read('booking/admin/admin.css');
  const block = css.slice(css.indexOf('/* Rich-teksti (Quill 2)'), css.indexOf('@media(min-width:700px){.pos-grid'));
  assert.doesNotMatch(block, /#06c|blue|grid-template-columns:repeat\(3/i);
  assert.match(block, /\.ql-toolbar\.ql-snow\{display:flex;flex-wrap:wrap/);
  assert.match(block, /button:hover \.ql-stroke[^{]*\{stroke:var\(--gold\)\}/);
  assert.match(block, /button\.ql-active\{color:#fff;background:var\(--green\)\}/);
  assert.match(block, /\.ql-tooltip\{display:none!important\}/);
  // Spesifisyys voittaa Quillin touch-säännön .ql-snow.ql-toolbar button:hover:not(.ql-active) .ql-stroke (CSS ladataan myöhemmin).
  assert.match(block, /\.rich-field \.rich-toolbar\.ql-toolbar\.ql-snow button:hover \.ql-stroke/);
  assert.match(block, /@media\(max-width:480px\)\{.*ql-snow button\{width:30px/);
  // Kontrasti >= 4,5:1: #2B3A30 ja #7A5530 hiekkaa #F4EFE7 ja valkoista vasten, valkoinen #2B3A30:aa vasten.
  const lum = (hex) => { const c = hex.match(/\w\w/g).map((x) => parseInt(x, 16) / 255).map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4)); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
  const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
  for (const [fg, bg] of [['2B3A30', 'F4EFE7'], ['7A5530', 'F4EFE7'], ['7A5530', 'FFFFFF'], ['FFFFFF', '2B3A30']]) assert.ok(ratio(fg, bg) >= 4.5, `${fg}/${bg}`);
  assert.match(css, /--green:#2B3A30/); assert.match(css, /--gold:#7A5530/); assert.match(css, /--bg:#F4EFE7/);
});

test('Varapolku vain, jos Quill ei lataudu: textarea jää, matala, eikä muotoiluohjetta näytetä', async () => {
  const { mountRichFields } = await import(pathToFileURL(join(root, 'booking/admin/rich-editor.js')).href + '?varapolku');
  const { richText } = await import(pathToFileURL(join(root, 'booking/admin/rich-texts.js')).href);
  const oldDoc = globalThis.document;
  const added = [];
  const head = { append: (node) => { added.push(node); queueMicrotask(() => node.listeners.error?.()); } };
  const mk = (tag) => ({ tagName: tag.toUpperCase(), dataset: {}, listeners: {}, addEventListener(n, f) { this.listeners[n] = f; } });
  globalThis.document = { head, createElement: mk, querySelector: () => null };
  try {
    const hint = { textContent: richText('hint'), hidden: false };
    const fld = { querySelector: (sel) => (sel === ':scope > small' ? hint : null) };
    const classes = new Set();
    const area = { disabled: false, isConnected: true, rows: 5, classList: { add: (c) => classes.add(c) }, closest: () => fld };
    await assert.rejects(mountRichFields({ querySelectorAll: () => [area] }), /Quill-lataus epäonnistui/);
    assert.equal(added.filter((n) => n.tagName === 'SCRIPT').length, 1);
    assert.ok(classes.has('rich-fallback'));
    assert.equal(area.rows, 4);
    assert.equal(hint.hidden, true);
  } finally {
    if (oldDoc === undefined) delete globalThis.document; else globalThis.document = oldDoc;
  }
});
