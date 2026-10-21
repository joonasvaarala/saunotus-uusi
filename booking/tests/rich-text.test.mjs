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
  const sql = read('booking/supabase/migrations/20261021150000_booking_122_rich_text.sql');
  const back = read('booking/supabase/rollbacks/20261021150000_booking_122_ROLLBACK.sql');
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
  assert.match(read('booking/admin/vendor/trix/trix.esm.min.js'), /Trix 2\.1\.19/);
  assert.match(read('booking/admin/rich-editor.js'), /2\.1\.19/);
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
