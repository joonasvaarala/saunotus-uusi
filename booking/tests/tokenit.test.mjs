// UX-uudistus vaihe 1: jaetut tokenit (booking/shared/tokens.css) ja peruskomponentit (booking/shared/ui.css).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const read = (p) => readFileSync(resolve(repo, p), 'utf8');
const strip = (css) => css.replace(/\/\*[\s\S]*?\*\//g, '');
const tokens = read('booking/shared/tokens.css');
const ui = read('booking/shared/ui.css');
const defined = (css) => Object.fromEntries([...strip(css).matchAll(/(--[\w-]+)\s*:\s*([^;}]+)/g)].map((m) => [m[1], m[2].trim()]));
const T = defined(tokens);
const norm = (v) => String(v).toLowerCase().replace(/\s+/g, '');

test('tokens.css: värit, kirjasimet, kokoasteikko, välistys, muoto ja tilavärit määritelty', () => {
  for (const k of ['--c-ink', '--c-text', '--c-muted', '--c-brand', '--c-accent', '--c-bg', '--c-surface', '--c-line', '--c-field',
    '--c-ok', '--c-ok-bg', '--c-warn', '--c-warn-bg', '--c-danger', '--c-danger-bg', '--c-info', '--c-info-bg', '--c-neutral', '--c-neutral-bg',
    '--f-ui', '--f-head', '--f-body', '--f-label', '--fs-xs', '--fs-sm', '--fs-md', '--fs-lg', '--fs-xl', '--fs-2xl',
    '--sp-1', '--sp-8', '--r-sm', '--r-md', '--r-lg', '--r-pill', '--shadow-card', '--shadow-pop', '--focus', '--tap']) {
    assert.ok(T[k], `puuttuu ${k}`);
  }
  assert.equal(T['--tap'], '44px');
  assert.deepEqual(['--fs-xs', '--fs-sm', '--fs-md', '--fs-lg', '--fs-xl', '--fs-2xl'].map((k) => T[k]), ['12px', '14px', '16px', '18px', '22px', '28px']);
});

test('vanhat muuttujat (sivusto ja hallinta) eivät poikkea tokeneista', () => {
  const site = defined(read('src/styles.css').match(/:root\{[^}]*\}/)[0]);
  const admin = defined(read('booking/admin/admin.css').match(/:root\{[^}]*\}/)[0]);
  const same = [['--ink', '--c-ink'], ['--text', '--c-text'], ['--muted', '--c-muted'], ['--green', '--c-brand'], ['--bg', '--c-bg'], ['--tint', '--c-tint']];
  for (const [old, tok] of same) {
    assert.equal(norm(site[old]), norm(T[tok]), `sivusto ${old} ≠ ${tok}`);
    assert.equal(norm(admin[old] ?? T[tok]), norm(T[tok]), `hallinta ${old} ≠ ${tok}`);
  }
  assert.equal(norm(site['--gold']), norm(T['--c-accent']), 'sivuston --gold on ruskea korostusväri');
  assert.equal(norm(admin['--gold']), norm(T['--c-accent']));
  assert.equal(norm(admin['--line']), norm(T['--c-line']));
  assert.equal(norm(admin['--ok']), norm(T['--c-ok']));
  assert.equal(norm(admin['--okbg']), norm(T['--c-ok-bg']));
  assert.equal(norm(admin['--err']), norm(T['--c-danger']));
  assert.equal(norm(admin['--errbg']), norm(T['--c-danger-bg']));
  assert.equal(norm(admin['--warnbg']), norm(T['--c-warn-bg']));
});

test('ui.css: kaikki luokat ux-etuliitteellä, kaikki muuttujat määritelty tokens.css:ssä, ei omia heksavärejä paitsi valkoinen ja varjot', () => {
  const css = strip(ui);
  const sels = [...css.matchAll(/(?:^|})\s*([^{}@]+)\{/g)].flatMap((m) => m[1].split(','));
  for (const s of sels) {
    const classes = s.match(/\.[\w-]+/g) || [];
    for (const c of classes) assert.ok(c.startsWith('.ux-') || c === '.r', `luokka ilman ux-etuliitettä: ${c}`);
  }
  for (const m of css.matchAll(/var\((--[\w-]+)/g)) assert.ok(T[m[1]], `ui.css käyttää määrittelemätöntä ${m[1]}`);
  const hex = (css.match(/#[0-9a-fA-F]{3,6}\b/g) || []).filter((x) => !/^#fff(fff)?$/i.test(x));
  assert.ok(hex.length <= 6, `liikaa omia heksavärejä: ${hex.join(' ')}`);
  for (const c of ['.ux-btn', '.ux-btn--primary', '.ux-btn--danger', '.ux-badge--ok', '.ux-chip', '.ux-seg', '.ux-tabs', '.ux-card', '.ux-table', '.ux-field', '.ux-input', '.ux-switch', '.ux-alert', '.ux-empty', '.ux-skeleton', 'dialog.ux-dialog']) assert.ok(css.includes(c), `puuttuu ${c}`);
});

test('käyttöönotto: hallinta lataa tokenit ennen admin.css:ää, build kopioi tiedostot; sivusto ei upota käyttämättömiä tokeneita', () => {
  assert.doesNotMatch(read('src/render.mjs'), /booking\/shared\/tokens\.css/);
  const html = read('booking/admin/index.html');
  const i = (n) => html.indexOf(`href="${n}"`);
  assert.ok(i('tokens.css') > 0 && i('tokens.css') < i('ui.css') && i('ui.css') < i('admin.css') && i('admin.css') < i('calendar.css'));
  const bp = read('scripts/build-pages.mjs');
  assert.match(bp, /cpSync\('booking\/shared\/tokens\.css'/);
  assert.match(bp, /cpSync\('booking\/shared\/ui\.css'/);
});

test('hallinnan kuori: tabletilla (600–899 px) valikko nimineen, yläpalkin kosketuskohteet ≥ 44 px', () => {
  const css = strip(read('booking/admin/admin.css'));
  const tablet = css.slice(css.indexOf('@media(min-width:600px) and (max-width:899px)'));
  assert.match(tablet, /--side-narrow:196px/);
  assert.match(tablet, /#shell \.nav \.lbl\{display:inline\}/);
  assert.match(tablet, /#shell \.nav-toggle\{display:none\}/);
  for (const m of css.matchAll(/(\.top \.quick-action|\.quick-search-toggle|\.quick-search|\.top \.user-toggle)\{([^}]*)\}/g)) {
    for (const d of m[2].matchAll(/(?:min-width|min-height|width|flex-basis|flex):(?:0 0 )?(\d+)px/g)) assert.ok(+d[1] >= 44, `${m[1]}: ${d[0]}`);
  }
});
