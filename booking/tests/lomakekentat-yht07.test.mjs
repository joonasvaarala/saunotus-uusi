// YHT-07: lomakekentät, virheet ja fokus yhdenmukaisiksi (sivusto, kauppa, hallinta). Ei verkkoa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = resolve(new URL('../..', import.meta.url).pathname);
const rd = (p) => readFileSync(join(root, p), 'utf8');
const strip = (css) => css.replace(/\/\*[\s\S]*?\*\//g, '');
const site = strip(rd('src/styles.css'));
const shop = strip(rd('booking/shop/src/shop.css'));
const admin = strip(rd('booking/admin/admin.css'));
const tokens = rd('booking/shared/tokens.css');

const lum = (hex) => {
  const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
};
const contrast = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };

test('kenttäreunus ja fokusväri täyttävät 3:1 (WCAG 1.4.11) kaikilla pinnoilla', () => {
  for (const bg of ['#FFFFFF', '#F4EFE7', '#FAF7F1']) {
    assert.ok(contrast('#8B7F73', bg) >= 3, `reunus ${bg}`);
    assert.ok(contrast('#7A5530', bg) >= 3, `fokus ${bg}`);
  }
  for (const dark of ['#2B3A30', '#15110d']) assert.ok(contrast('#EDE3D0', dark) >= 3, `vaalea fokus ${dark}`);
  assert.ok(contrast('#7B1D12', '#FBEAEA') >= 4.5, 'virheteksti');
});

test('sama kenttätyyli: reunus #8B7F73 ja pyöristys --r-md kaikissa kolmessa', () => {
  assert.match(tokens, /--c-field:\s*#8B7F73/i);
  assert.match(site, /--field:#8B7F73/i);
  assert.match(site, /\.co-form input,\.co-form textarea\{[^}]*border:1px solid var\(--field\)[^}]*border-radius:var\(--r-md\)/);
  assert.match(shop, /\.bk-field input,\.bk-field textarea\{[^}]*border:1px solid var\(--field\)[^}]*border-radius:var\(--r-md\)/);
  assert.match(admin, /\ninput,select,textarea\{[^}]*border:1px solid var\(--c-field\)[^}]*border-radius:var\(--r-md\)/);
  assert.doesNotMatch(site.match(/\.co-form input,\.co-form textarea\{[^}]*\}/)[0], /var\(--line\)/);
});

test('yksi virheväri: ei vanhoja sävyjä (#5c241c, #c0392b) eikä kovakoodattua #7b1d12 kaupassa', () => {
  assert.doesNotMatch(site, /#5c241c/i);
  assert.doesNotMatch(shop, /#c0392b|#7b1d12/i);
  assert.match(site, /--danger:#7B1D12/i);
  assert.match(site.match(/\.co-msg\{[^}]*\}/)[0], /color:var\(--danger\)/);
});

test('yksi fokusväri: ei sinistä, ei tummaa --ink-kehystä kaupassa', () => {
  assert.doesNotMatch(site, /#1d6fd8/i);
  assert.match(site, /:focus-visible\{outline:3px solid var\(--gold\)/);
  assert.doesNotMatch(shop, /outline:3px solid var\(--ink\)/);
  assert.match(site, /\.hero :focus-visible,\.ritual :focus-visible,\.site-footer :focus-visible\{outline-color:#EDE3D0\}/);
  assert.match(admin, /:focus-visible\{outline:var\(--focus\)/);
});

test('hallinnan ohje- ja virhetekstit ovat vähintään 14 px', () => {
  for (const sel of ['.fld-hint', '.fld-err', '.tl-hint', '.inv-price-note', '.dayshifts-note']) {
    const m = admin.match(new RegExp(sel.replace('.', '\\.') + '\\{[^}]*font-size:([^;}]+)'));
    assert.ok(m, sel);
    assert.ok(m[1] === 'var(--fs-sm)' || parseInt(m[1], 10) >= 14, `${sel}: ${m[1]}`);
  }
  assert.doesNotMatch(shop.match(/\.bk-hint\{[^}]*\}/)[0], /font-size:1[0-3]px/);
});

test('Yrityksille-lomake: virheviesti kunkin kentän alla, id ja role=alert', async () => {
  const { companies } = await import(pathToFileURL(join(root, 'src/render.mjs')));
  const { classForContent } = await import(pathToFileURL(join(root, 'src/content-texts.mjs')));
  assert.ok(classForContent);
  const src = rd('src/render.mjs');
  for (const code of ['invalid_company', 'invalid_contact', 'invalid_email', 'invalid_phone', 'invalid_when', 'invalid_persons', 'invalid_offerings', 'invalid_offering_other', 'invalid_message', 'privacy_required']) {
    assert.ok(src.includes(`msg("${code}")`), code);
  }
  assert.equal(typeof companies, 'function');
  const js = rd('public/js/companies-form.js');
  assert.match(js, /aria-invalid/);
  assert.match(js, /aria-describedby/);
});
