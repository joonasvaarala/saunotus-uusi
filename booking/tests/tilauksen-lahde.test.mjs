// booking_241 / tilauksen lähde: public/js/analytics.js tallentaa välilehden lähteen vain sessionStorageen,
// booking/shop/src/attribution.js lukee sen ja lisää p_attribution kuuteen tilauksen luovaan julkiseen funktioon.
// Tietosuojaselosteen ehdotus: content/site-texts.pending-propose-124.json. Ei verkkoa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { buildSource, loadOrInitSource, readStoredSource, referrerDomain, STORAGE_KEY, SESSION_KEY_RE } from '../../public/js/analytics.js';
import { cleanAttribution, readAttribution, withAttribution, ATTRIBUTION_RPCS, STORAGE_KEY as SHOP_KEY } from '../shop/src/attribution.js';

const root = resolve(new URL('../..', import.meta.url).pathname);
const R = (f) => readFileSync(resolve(root, f), 'utf8');
const KEY = '3f2b8c1e-9a4d-4e7f-8b2a-1c3d5e7f9a0b';
function mem(init = {}) {
  const m = new Map(Object.entries(init)); let writes = 0;
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => { writes++; m.set(k, String(v)); }, removeItem: (k) => m.delete(k), get writes() { return writes; }, m };
}
const throwing = { getItem() { throw new Error('SecurityError'); }, setItem() { throw new Error('QuotaExceeded'); } };

test('buildSource: verkkotunnus, siivotut utm:t, polku ilman queryä, laite, kieli, istunto; ei source_categorya', () => {
  const s = buildSource({ pathname: '/en/gift-card/', search: '?utm_source=Instagram&utm_medium=story&utm_campaign=xmas_2026&fbclid=abc&email=a@b.fi',
    referrer: 'https://l.instagram.com/path?u=secret', width: 390, lang: 'en', sessionKey: KEY });
  assert.deepEqual(s, { session_key: KEY, referrer_domain: 'l.instagram.com', utm_source: 'instagram', utm_medium: 'story', utm_campaign: 'xmas_2026',
    landing_path: '/en/gift-card/', device_type: 'mobile', locale: 'en' });
  assert.ok(!JSON.stringify(s).includes('secret') && !JSON.stringify(s).includes('fbclid'));
});
test('buildSource: kelvottomat utm:t ja verkkotunnukset pudotetaan, kelvoton istunto → null', () => {
  const s = buildSource({ pathname: '/varaa/', search: '?utm_source=123456&utm_medium=a@b&utm_campaign=' + 'x'.repeat(61), referrer: 'http://localhost:8080/', width: 1300, lang: 'fi', sessionKey: KEY });
  assert.deepEqual(s, { session_key: KEY, landing_path: '/varaa/', device_type: 'desktop', locale: 'fi' });
  assert.equal(buildSource({ sessionKey: 'EI-UUID' }), null);
  assert.equal(buildSource({ sessionKey: KEY.toUpperCase() }), null);
  assert.equal(referrerDomain('not a url'), undefined);
  assert.equal(buildSource({ pathname: '/saunotus-uusi/lahjakortti/', basePath: '/saunotus-uusi', sessionKey: KEY, width: 800 }).landing_path, '/lahjakortti/');
  assert.equal(buildSource({ pathname: '/', sessionKey: KEY, width: 800 }).device_type, 'tablet');
});
test('loadOrInitSource: ensimmäinen lataus tallentaa, myöhemmät lataukset käyttävät samaa (istunto säilyy välilehdellä)', () => {
  const st = mem();
  let made = 0;
  const make = () => { made++; return buildSource({ pathname: '/', referrer: 'https://www.google.com/', sessionKey: KEY, width: 1200, lang: 'fi' }); };
  const a = loadOrInitSource(st, make);
  assert.equal(a.session_key, KEY); assert.equal(st.writes, 1); assert.equal(made, 1);
  const b = loadOrInitSource(st, () => { made++; return buildSource({ pathname: '/varaa/', referrer: 'https://saunotus.fi/', sessionKey: '11111111-2222-4333-8444-555555555555' }); });
  assert.deepEqual(b, a); assert.equal(st.writes, 1); assert.equal(made, 1, 'myöhempi lataus ei laske lähdettä uudelleen');
  assert.deepEqual(JSON.parse(st.m.get(STORAGE_KEY)), a);
});
test('loadOrInitSource: rikkinäinen tietue korvataan, tallennusvirhe tai puuttuva tallennus ei estä mittausta', () => {
  const st = mem({ [STORAGE_KEY]: '{rikki' });
  assert.equal(readStoredSource(st), null);
  assert.equal(loadOrInitSource(st, () => buildSource({ sessionKey: KEY })).session_key, KEY);
  assert.equal(readStoredSource(st).session_key, KEY);
  assert.equal(loadOrInitSource(throwing, () => buildSource({ sessionKey: KEY })).session_key, KEY);
  assert.equal(loadOrInitSource(null, () => buildSource({ sessionKey: KEY })).session_key, KEY);
  assert.equal(loadOrInitSource(mem(), () => { throw new Error('x'); }), null);
  assert.equal(readStoredSource(mem({ [STORAGE_KEY]: JSON.stringify({ session_key: 'x' }) })), null);
});

// Selainsimulaatio: analytics.js:n latausaikainen toiminta (globaalit vaihdetaan, moduuli tuodaan uudelleen query-parametrilla).
let n = 0;
async function loadPage({ storage, path = '/', search = '', referrer = '', dnt, gpc, webdriver, enabled = true, uuid = KEY } = {}) {
  const sent = [];
  const nav = { doNotTrack: dnt, globalPrivacyControl: gpc, webdriver };
  const g = globalThis, saved = {};
  const set = { window: g, navigator: nav, location: { pathname: path, search, hash: '' }, document: { referrer, documentElement: { lang: 'fi' }, addEventListener() {} },
    sessionStorage: storage, innerWidth: 1280, SAUNA_ANALYTICS_CONFIG: { enabled, url: 'https://x.supabase.co', anonKey: 'anon' },
    fetch: (u, o) => { sent.push(JSON.parse(o.body).p_payload); return Promise.resolve({ json: () => ({ ok: true }) }); },
    crypto: { randomUUID: () => uuid }, addEventListener() {} };
  for (const k of Object.keys(set)) { saved[k] = Object.getOwnPropertyDescriptor(g, k); Object.defineProperty(g, k, { value: set[k], configurable: true, writable: true }); }
  try { await import(`../../public/js/analytics.js?sim=${++n}`); await new Promise((r) => setTimeout(r, 0)); }
  finally { for (const k of Object.keys(set)) { if (saved[k]) Object.defineProperty(g, k, saved[k]); else delete g[k]; } }
  return sent;
}
test('selain: ensimmäinen lataus tallentaa lähteen sessionStorageen, toinen lataus käyttää samaa istuntoa', async () => {
  const st = mem();
  const a = await loadPage({ storage: st, path: '/lahjakortti/', search: '?utm_source=newsletter&x=1', referrer: 'https://www.facebook.com/x' });
  const rec = JSON.parse(st.m.get(STORAGE_KEY));
  assert.deepEqual(rec, { session_key: KEY, referrer_domain: 'www.facebook.com', utm_source: 'newsletter', landing_path: '/lahjakortti/', device_type: 'desktop', locale: 'fi' });
  assert.equal(a[0].event_type, 'page_view'); assert.equal(a[0].session_key, KEY);
  const b = await loadPage({ storage: st, path: '/varaa/', referrer: 'https://saunotus.fi/lahjakortti/', uuid: '11111111-2222-4333-8444-555555555555' });
  assert.equal(b[0].session_key, KEY, 'sama istunto välilehdellä');
  assert.equal(b[0].path, '/varaa/');
  assert.equal(st.writes, 1);
});
test('selain: poissulut (DNT, GPC, webdriver, /hallinta, mock=1, pois päältä) → ei tallenneta eikä lähetetä mitään', async () => {
  for (const o of [{ dnt: '1' }, { gpc: true }, { webdriver: true }, { path: '/hallinta/' }, { search: '?mock=1' }, { enabled: false }]) {
    const st = mem();
    const sent = await loadPage({ storage: st, ...o });
    assert.equal(st.writes, 0, JSON.stringify(o)); assert.equal(sent.length, 0, JSON.stringify(o));
  }
});
test('selain: sessionStorage heittää → mittaus toimii silti sivukohtaisella istunnolla', async () => {
  const sent = await loadPage({ storage: throwing });
  assert.equal(sent[0]?.session_key, KEY);
});

// --- kauppa: p_attribution ---
const env = (storage, extra = {}) => ({ navigator: {}, location: { search: '', hash: '' }, sessionStorage: storage, ...extra });
test('kauppa: sama tallennusavain ja kentät kuin analytics.js; source_category ja ylimääräiset kentät eivät lähde', () => {
  assert.equal(SHOP_KEY, STORAGE_KEY);
  const src = buildSource({ pathname: '/en/gift-card/', search: '?utm_source=ig', referrer: 'https://l.instagram.com/', width: 390, lang: 'en', sessionKey: KEY });
  assert.deepEqual(cleanAttribution({ ...src, source_category: 'social', email: 'a@b.fi' }), src);
  assert.deepEqual(cleanAttribution({ session_key: KEY, utm_source: 'a@b', utm_medium: '1234567', device_type: 'phone', locale: 'sv', landing_path: '/x?y=1', referrer_domain: 'localhost' }), { session_key: KEY });
  assert.equal(cleanAttribution({ session_key: 'x' }), null);
  assert.equal(cleanAttribution(null), null);
  assert.ok(SESSION_KEY_RE.test(KEY));
});
test('kauppa: readAttribution lukee turvallisesti; poissulut ja virheet → null', () => {
  const st = mem({ [STORAGE_KEY]: JSON.stringify({ session_key: KEY, locale: 'fi' }) });
  assert.deepEqual(readAttribution(env(st)), { session_key: KEY, locale: 'fi' });
  assert.equal(readAttribution(env(mem())), null);
  assert.equal(readAttribution(env(mem({ [STORAGE_KEY]: '{rikki' }))), null);
  assert.equal(readAttribution(env(throwing)), null);
  const getterThrows = { navigator: {}, location: { search: '' }, get sessionStorage() { throw new Error('denied'); } };
  assert.equal(readAttribution(getterThrows), null);
  assert.equal(readAttribution(env(st, { navigator: { doNotTrack: '1' } })), null);
  assert.equal(readAttribution(env(st, { navigator: { globalPrivacyControl: true } })), null);
  assert.equal(readAttribution(env(st, { navigator: { webdriver: true } })), null);
  assert.equal(readAttribution(env(st, { location: { search: '?mock=1', hash: '' } })), null);
  assert.equal(readAttribution(null), null);
});
test('kauppa: withAttribution lisää p_attributionin vain kuuteen funktioon ja vain kun lähde on tallessa', () => {
  const a = { session_key: KEY, utm_source: 'ig' };
  const args = { p_name: 'Testi', p_locale: 'fi' };
  assert.deepEqual(ATTRIBUTION_RPCS, ['public_create_booking', 'public_create_booking_code', 'public_create_treatment_booking', 'public_buy_gift_card', 'public_buy_annual_card', 'public_create_training_signup']);
  for (const fn of ATTRIBUTION_RPCS) assert.deepEqual(withAttribution(fn, args, () => a), { ...args, p_attribution: a });
  for (const fn of ['public_create_business_quote', 'public_drinks_checkout', 'public_upsell_checkout_attach', 'public_catalog']) assert.equal(withAttribution(fn, args, () => a), args);
  assert.equal(withAttribution('public_create_booking', args, () => null), args, 'ei lähdettä → parametri jätetään pois');
  assert.ok(!('p_attribution' in withAttribution('public_create_booking', args, () => null)));
  assert.equal(withAttribution('public_create_booking', args, () => { throw new Error('x'); }), args, 'virhe ei koskaan estä tilausta');
  assert.deepEqual(args, { p_name: 'Testi', p_locale: 'fi' }, 'alkuperäistä ei muuteta');
});
test('kauppa: kaikki kuusi kutsupaikkaa käyttävät withAttributionia (FI ja EN sama koodi)', () => {
  const shop = R('booking/shop/src/shop.js'), tr = R('booking/shop/src/treatments.js'), ts = R('booking/shop/src/training-signup.js'), gift = R('booking/shop/src/gift-api.js');
  assert.match(shop, /rpc\('public_buy_annual_card', withAttribution\('public_buy_annual_card', \{/);
  assert.match(shop, /rpc\('public_create_booking_code', withAttribution\('public_create_booking_code', \{ \.\.\.args, p_code: code\.value \}\)\)/);
  assert.match(shop, /rpc\('public_create_booking', withAttribution\('public_create_booking', args\)\)/);
  assert.match(tr, /rpc\(RPC\.create, withAttribution\(RPC\.create, args\.create\(p, data\)\)\)/);
  assert.match(ts, /rpc\('public_create_training_signup', withAttribution\('public_create_training_signup', \{/);
  assert.match(gift, /buy: \(args\) => run\(GRPC\.buy, withAttribution\(GRPC\.buy, args\)\)/);
  for (const s of [shop, tr, ts, gift]) assert.match(s, /import \{ withAttribution \} from '\.\/attribution\.js';/);
  assert.doesNotMatch(R('booking/shared/sb.js'), /attribution/, 'jaettu sb.js (myös hallinta) ennallaan');
  for (const [f, fn] of [['booking/shop/src/shop.js', 'public_create_business_quote'], ['booking/shop/src/shop.js', 'public_upsell_checkout_attach']]) {
    assert.doesNotMatch(R(f), new RegExp(`withAttribution\\('${fn}'`));
  }
});

// --- tietosuojaseloste (vain suomi, ehdotus) ---
test('seloste: pending-propose-124 = tuotannon v5 + yksi virke lähteestä + kaksi ristiriitaista virkettä korjattu, plain, ei <', () => {
  const rows = JSON.parse(R('content/site-texts.pending-propose-124.json'));
  assert.deepEqual(rows.map((r) => `${r.key}|${r.lang}|${r.apply}|${r.class}|${r.kind}`), ['policy.7.body|fi|texts_propose|protected|plain']);
  const r = rows[0], t = r.text, md5 = (s) => createHash('md5').update(s).digest('hex');
  assert.equal(r.base_version, 5); assert.equal(r.base_md5, '0b51adfd5cb3e7e6fb1f2f17797739a1');
  assert.equal(md5(t), r.new_md5); assert.equal(t.length, r.new_length); assert.ok(t.length <= r.max_len);
  assert.ok(!t.includes('<'));
  assert.ok(!/\]\(|\{\{|\}\}|javascript:|https?:\/\//i.test(t));
  const s7 = t.slice(t.indexOf('7. Evästeetön kävijämittaus'));
  assert.match(s7, /tallennetaan vain selaimen istuntokohtaiseen tallennustilaan \(session storage\) niin kauaksi aikaa kuin välilehti on auki, ja lähde liitetään tilaukseen/);
  assert.match(s7, /ilman evästeitä/);
  assert.doesNotMatch(t, /Selaimeen ei tallenneta mitään|yhden sivunlatauksen ajan/);
  // Tekstin pohja on tuotannon julkaistu v5: kun muutokset perutaan, md5 täsmää.
  const back = t.replace('Emme käytä evästeitä emmekä pysyviä tunnisteita.', 'Selaimeen ei tallenneta mitään: emme käytä evästeitä emmekä muita selaimeen tallennettavia tai pysyviä tunnisteita.')
    .replace(/Istuntotunniste on voimassa vain saman selainvälilehden ajan\. [^\n]*?jos teet tilauksen\./, 'Istuntotunniste on voimassa vain yhden sivunlatauksen ajan, eikä sitä tallenneta selaimeen.')
    .replace('Päivitetty 3.11.2026.', 'Päivitetty 24.10.2026.');
  assert.equal(md5(back), r.base_md5);
});
