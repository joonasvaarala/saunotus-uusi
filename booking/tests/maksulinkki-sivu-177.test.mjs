// booking_177: maksulinkkisivu /maksa/?p=<link_token> (+ EN /en/pay/). Sähköpostin, hallinnan ja pikakassan maksulinkit osoittivat
// settings.payment_link_path = '/maksa/' -polkuun, jota ei rakennettu → 404. Sivu kutsuu vismapay-start {link_token} ja ohjaa Visma Payhin.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, mkdtempSync, cpSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
const rd = (p) => readFileSync(join(root, p), 'utf8');

// kevyt DOM (parent + remove), kuten muissa näkymätesteissä
class Text { constructor(t) { this.nodeType = 3; this.data = String(t); this.parent = null; } get textContent() { return this.data; } }
class El {
  constructor(tag) { this.nodeType = 1; this.tagName = tag.toUpperCase(); this.children = []; this.attrs = {}; this.listeners = {}; this.parent = null; this.className = ''; this.disabled = false; this.hidden = false; }
  append(...k) { for (const x of k) { const n = x && x.nodeType ? x : new Text(x); n.parent = this; this.children.push(n); } }
  replaceChildren(...k) { this.children = []; this.append(...k); }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this); this.parent = null; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return this.attrs[k] ?? null; }
  addEventListener(t, f) { (this.listeners[t] ||= []).push(f); }
  async click() { for (const f of this.listeners.click || []) await f({ target: this }); }
  set textContent(v) { this.children = [new Text(v)]; }
  get textContent() { return this.children.map((c) => c.textContent).join(''); }
  all() { return this.children.flatMap((c) => (c.nodeType === 1 ? [c, ...c.all()] : [])); }
  q(id) { return this.all().find((e) => e.attrs['data-testid'] === id) || null; }
}
globalThis.document = { createElement: (t) => new El(t), createTextNode: (t) => new Text(t), getElementById: () => null };

// pay-link.js tuo './sb.js':n (rakennuksessa kopio booking/shared/sb.js:stä) → sama asettelu väliaikaiskansioon
const tmp = mkdtempSync(join(tmpdir(), 'maksulinkki-'));
cpSync(join(root, 'booking/shop/src'), tmp, { recursive: true });
cpSync(join(root, 'booking/shared/sb.js'), join(tmp, 'sb.js'));
writeFileSync(join(tmp, 'package.json'), '{"type":"module"}');
const imp = (f) => import(pathToFileURL(join(tmp, f)).href);
const { PLT, plt } = await imp('pay-link-texts.js');
const { linkTokenFrom, classifyLinkError, switchHref } = await imp('pay-link-logic.js');
const { payLinkView } = await imp('pay-link.js');
const { createVismapayApi } = await imp('vismapay-api.js');
const TOK = 'c5e82850-2458-4f3e-abcd-1b52cb9e8c17';
const VISMA = 'https://www.vismapay.com/pbwapi/token/abc123';

test('tekstit: FI/EN samat avaimet, ei tyhjiä, ei <, ei osoitteita, ei emojeita', () => {
  assert.deepEqual(Object.keys(PLT.fi).sort(), Object.keys(PLT.en).sort());
  for (const l of ['fi', 'en']) for (const [k, v] of Object.entries(PLT[l])) {
    assert.ok(typeof v === 'string' && v.trim() === v && v, `${l}.${k}`);
    assert.doesNotMatch(v, /[<>]|https?:\/\/|www\./, `${l}.${k}`);
    assert.ok(!/\p{Extended_Pictographic}/u.test(v), `${l}.${k}: emoji`);
  }
  assert.equal(plt('en', 'amount', { amount: '30,00 €' }), 'Amount due: 30,00 €');
  assert.ok(rd('booking/shop/src/text-registry.js').includes("{ id: 'PLT', area: 'paylink', dict: PLT }"), 'rekisteröity (ui.paylink.*)');
});

test('logiikka: ?p=<uuid> luetaan, muu hylätään; virhekoodit → teksti ja lopullisuus; kielivalinta säilyttää tokenin', () => {
  assert.equal(linkTokenFrom(`?p=${TOK}`), TOK);
  assert.equal(linkTokenFrom(`?p=${TOK.toUpperCase()}&utm=x`), TOK);
  for (const bad of ['', '?p=', '?p=abc', '?t=' + TOK, `?p=${TOK}x`, '?p=<script>']) assert.equal(linkTokenFrom(bad), null, bad);
  const cases = { link_expired: ['err.expired', true], payment_not_pending: ['err.expired', true], already_paid: ['err.paid', true], not_found: ['err.not_found', true],
    invalid_param: ['err.invalid', true], link_stale: ['err.stale', true], other_provider_started: ['err.other', true], order_not_payable: ['err.not_payable', true],
    rate_limited: ['err.rate', false], payment_in_progress: ['err.busy', false], vismapay_off: ['err.off', false], provider_error: ['err.provider', false],
    http_502: ['err.provider', false], network: ['err.network', false], timeout: ['err.network', false], whatever: ['err.generic', false] };
  for (const [code, [key, final]] of Object.entries(cases)) { assert.deepEqual(classifyLinkError(code), { key, final }, code); assert.ok(PLT.fi[key] && PLT.en[key], key); }
  assert.equal(switchHref('/saunotus-uusi/en/pay/', `?p=${TOK}`), `/saunotus-uusi/en/pay/?p=${TOK}`);
  assert.equal(switchHref('/maksa/', '?p=x'), '/maksa/');
});

test('vismapay-api: linkToken → POST vismapay-start {link_token} (ei order_tokenia)', async () => {
  const seen = [];
  const api = createVismapayApi({ linkToken: TOK, functionUrl: (n) => `https://x.supabase.co/functions/v1/${n}`, anonKey: 'k', fetchImpl: async (u, i) => { seen.push({ u, i }); return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, redirect_url: VISMA }) }; } });
  const r = await api.start();
  assert.equal(r.redirect_url, VISMA);
  assert.equal(seen[0].u, 'https://x.supabase.co/functions/v1/vismapay-start');
  assert.deepEqual(JSON.parse(seen[0].i.body), { link_token: TOK });
  assert.equal(seen[0].i.headers.apikey, 'k');
  const old = createVismapayApi({ token: 'ord', functionUrl: (n) => n, fetchImpl: async (u, i) => ({ ok: true, status: 200, text: async () => i.body }) });
  assert.deepEqual(await old.start(), { order_token: 'ord' }, 'tilaussivun kutsu ennallaan');
});

test('näkymä: painike → Visma-ohjaus; virheet FI/EN; lopullinen virhe poistaa painikkeen; puuttuva token → virhe heti; puhelin', async () => {
  const nav = [];
  let v = payLinkView({ L: 'fi', token: TOK, api: { start: async () => ({ ok: true, redirect_url: VISMA, amount: 30 }) }, phone: '010 299 2866', phoneTel: '+358102992866', navigate: (u) => nav.push(u), money: (n) => `${n} €` });
  assert.equal(v.attrs['data-testid'], 'pay-link-page');
  assert.equal(v.q('pl-button').textContent, 'Siirry maksamaan');
  const tel = v.q('pl-contact').all().find((e) => e.tagName === 'A');
  assert.equal(tel.attrs.href, 'tel:+358102992866'); assert.equal(tel.textContent, '010 299 2866');
  await v.q('pl-button').click();
  assert.deepEqual(nav, [VISMA]);
  assert.match(v.q('pl-amount').textContent, /30 €/);
  // ei-Visma-osoite hylätään (ei avointa uudelleenohjausta)
  nav.length = 0;
  v = payLinkView({ L: 'fi', token: TOK, api: { start: async () => ({ ok: true, redirect_url: 'https://evil.example/x' }) }, navigate: (u) => nav.push(u) });
  await v.q('pl-button').click();
  assert.deepEqual(nav, []); assert.equal(v.q('pl-error').attrs['data-code'], 'generic'); assert.ok(v.q('pl-button'), 'yleisvirhe: painike jää');
  for (const [L, code, re] of [['fi', 'link_expired', /vanhentunut/], ['en', 'already_paid', /already been paid/], ['en', 'not_found', /not found/]]) {
    v = payLinkView({ L, token: TOK, api: { start: async () => ({ ok: false, code }) }, navigate: () => assert.fail('ei ohjausta') });
    await v.q('pl-button').click();
    assert.equal(v.q('pl-error').attrs['data-code'], code); assert.match(v.q('pl-error').textContent, re); assert.equal(v.q('pl-button'), null, `${code}: painike pois`);
  }
  v = payLinkView({ L: 'fi', token: TOK, api: { start: async () => ({ ok: false, code: 'rate_limited' }) } });
  await v.q('pl-button').click();
  assert.ok(v.q('pl-button') && !v.q('pl-button').disabled, 'uusi yritys sallittu'); assert.match(v.q('pl-error').textContent, /Liian monta/);
  v = payLinkView({ L: 'en', token: null, api: { start: async () => assert.fail('ei kutsua ilman tokenia') } });
  assert.equal(v.q('pl-button'), null); assert.equal(v.q('pl-error').attrs['data-code'], 'invalid_param'); assert.match(v.q('pl-error').textContent, /invalid/);
});

test('lähde: payLinkView ei kutsu palvelinta ennen painallusta; sivu käynnistyy vain page=paylink; kielivalinta saa ?p=', () => {
  const s = rd('booking/shop/src/pay-link.js');
  assert.match(s, /window\.BOOKING_SHOP\?\.page === 'paylink'\) main\(\)/);
  assert.match(s, /createVismapayApi\(\{ linkToken: token, functionUrl, anonKey: cfg\.anonKey \}\)/);
  assert.match(s, /\.lang a\[hreflang\]/);
  assert.doesNotMatch(s, /#[0-9a-f]{6}/i, 'ei kovakoodattuja värejä (tyylit shop.css:stä)');
});

test('build: /maksa/ ja /en/pay/ syntyvät polkuetuliitteellä (GitHub Pages) ja juureen (saunotus.fi); noindex, ei sitemapissa, pay-link.js, kielivalinta', () => {
  const work = mkdtempSync(join(tmpdir(), 'maksa-build-'));
  const run = (dist, url, n) => spawnSync('node', ['booking/shop/build.mjs'], { cwd: root, encoding: 'utf8', env: { PATH: process.env.PATH, HOME: process.env.HOME, ARTICLES_FIXTURE: '1', ARTICLES_IMAGES: '0', SITE_TEXTS_FIXTURE: '1', SHOP_DIST: dist, SITE_ENV: 'test', SITE_URL: url, ARTICLES_CACHE_DIR: join(work, 'ac' + n), SITE_TEXTS_CACHE_DIR: join(work, 'sc' + n) } });
  for (const [n, url, base] of [[1, 'https://joonasvaarala.github.io/saunotus-uusi', '/saunotus-uusi'], [2, 'https://saunotus.fi', '']]) {
    const dist = join(work, 'd' + n);
    const r = run(dist, url, n);
    assert.equal(r.status, 0, r.stderr + r.stdout);
    for (const [lang, p, other] of [['fi', 'maksa', 'en/pay'], ['en', 'en/pay', 'maksa']]) {
      const f = join(dist, p, 'index.html');
      assert.ok(existsSync(f), `${p}/index.html puuttuu (${url})`);
      const html = readFileSync(f, 'utf8');
      assert.match(html, new RegExp(`<html lang="${lang}"`));
      assert.match(html, /<meta name="robots" content="noindex,nofollow">/);
      assert.match(html, /<meta name="referrer" content="no-referrer">/);
      assert.doesNotMatch(html, /<link rel="canonical"/);
      assert.ok(html.includes('id="pay-link-app"'));
      assert.match(html, new RegExp(`<script type="module" src="${base}/booking/pay-link\\.js\\?v=[0-9a-f]{10}"`));
      assert.match(html, new RegExp(`<script src="${base}/booking/config\\.js`));
      assert.match(html, /"page":"paylink"/);
      assert.ok(html.includes(`"otherHref":"${base}/${other}/"`), 'otherHref');
      assert.match(html, new RegExp(`<div class="lang"[^>]*>.*?<a href="${base}/${other}/"`, 's'), 'kielivalinta toisen kielen maksusivulle');
      assert.ok(html.includes('tel:+358102992866'), 'noscript-puhelin');
      const main = html.slice(html.indexOf('<main'), html.indexOf('</main>'));
      assert.ok(main.includes('pay-link-app')); assert.doesNotMatch(main, /\p{Extended_Pictographic}/u, 'ei emojeita sivun sisällössä');
    }
    assert.ok(existsSync(join(dist, 'booking/pay-link.js')) && existsSync(join(dist, 'booking/pay-link-logic.js')) && existsSync(join(dist, 'booking/pay-link-texts.js')));
    if (existsSync(join(dist, 'sitemap.xml'))) assert.doesNotMatch(readFileSync(join(dist, 'sitemap.xml'), 'utf8'), /\/maksa\/|\/en\/pay\//);
  }
});

test('hallinnan maksulinkki: absLink säilyttää sivuston polkuetuliitteen (ei …github.io/maksa/)', async () => {
  const A = await import(pathToFileURL(join(root, 'booking/admin/talous-api.js')).href);
  assert.equal(A.absLink('/maksa/?p=1', { order_page_path: 'https://joonasvaarala.github.io/saunotus-uusi/tilaus/?t=abc' }), 'https://joonasvaarala.github.io/saunotus-uusi/maksa/?p=1');
  assert.equal(A.absLink('/maksa/?p=1', { order_page_path: 'https://saunotus.fi/tilaus/?t=abc' }), 'https://saunotus.fi/maksa/?p=1');
  assert.equal(A.siteBase({ order_page_path: 'https://saunotus.fi/tilaus/?t=abc' }), 'https://saunotus.fi/');
  assert.equal(A.absLink('', {}), '');
  // pikakassa: joinUrl(site_base_url, link_path) säilyttää polun
  const P = await import(pathToFileURL(join(root, 'booking/admin/pos-logic.js')).href);
  assert.equal(P.joinUrl('https://joonasvaarala.github.io/saunotus-uusi', '/maksa/?p=1'), 'https://joonasvaarala.github.io/saunotus-uusi/maksa/?p=1');
});

test('tekstit: pending-import-72 = ui.paylink.* FI+EN koodin oletuksista, uudet avaimet (ei muissa tuontitiedostoissa eikä tuotannossa)', async () => {
  const { readdirSync } = await import('node:fs');
  const R = await import(pathToFileURL(join(root, 'booking/shop/src/text-registry.js')).href);
  const def = new Map(R.collectDefaults().filter((r) => r.id === 'PLT').map((r) => [`${r.key}|${r.lang}`, r.text]));
  // booking_177b lisäsi avaimia (yhteenveto) → pending-import-73; yhdessä tiedostot kattavat PLT:n täsmälleen, ei päällekkäisyyksiä
  const rows = JSON.parse(rd('content/site-texts.pending-import-72.json'));
  const rows73 = JSON.parse(rd('content/site-texts.pending-import-73.json'));
  const rows74 = JSON.parse(rd('content/site-texts.pending-import-74.json'));   // booking_178: uusintaviesti
  assert.equal(rows.length, 42); assert.equal(rows.length + rows73.length + rows74.length, def.size); assert.equal(def.size, Object.keys(PLT.fi).length * 2);
  assert.ok(!rows73.some((r) => rows.some((x) => x.key === r.key)), 'import-72 ja -73 eivät mene päällekkäin');
  for (const r of rows) { assert.ok(r.key.startsWith('ui.paylink.')); assert.equal(r.text, def.get(`${r.key}|${r.lang}`), `${r.key} ${r.lang}`); assert.ok(r.max_len >= r.text.length); }
  const keys = new Set(rows.map((r) => r.key));
  for (const f of readdirSync(join(root, 'content')).filter((f) => /^site-texts\.(pending-import|imported).*\.json$/.test(f) && f !== 'site-texts.pending-import-72.json' && f !== 'site-texts.pending-import-73.json')) {
    const rs = JSON.parse(rd(`content/${f}`)); if (Array.isArray(rs)) for (const r of rs) assert.ok(!keys.has(r?.key), `${r?.key} jo tiedostossa ${f}`);
  }
  for (const r of JSON.parse(rd('content/site-texts.fallback.json')).texts) assert.ok(!keys.has(r.key), `${r.key} jo tuotannossa`);
});
