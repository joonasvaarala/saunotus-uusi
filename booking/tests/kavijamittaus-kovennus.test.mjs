// booking_150: kävijämittauksen kovennus (booking_144:n jatko).
// SQL-käyttäytyminen (IP-raja, päiväkatto, polkujen normalisointi, UTM-hylkäys, palvelimen lähdekategoria, kooste, siivous):
// booking/supabase/tests/analytics/t150_analytics_hardening.sql (paikallinen PG17, koko ketju + rollback + uudelleenajo; ei CI:ssä).
// Tämä testi: migraation/rollbackin rakenne staattisesti ja public/js/analytics.js ajonaikaisesti valeselaimessa (ei fetch-käärettä).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const MIG = 'booking/supabase/migrations/20261024120719_booking_150_analytics_hardening.sql';
const RB = 'booking/supabase/rollbacks/20261024120719_booking_150_ROLLBACK.sql';
const M144 = 'booking/supabase/migrations/20261024113416_booking_144_cookieless_analytics.sql';
const mig = read(MIG), rb = read(RB), m144 = read(M144);
const code = (s) => s.replace(/--[^\n]*/g, '');
const fnBlock = (src, name) => {
  const a = src.indexOf(`create or replace function booking.${name}(`);
  assert.ok(a >= 0, `${name} puuttuu`);
  const b = src.indexOf('$$;', src.indexOf('$$', src.indexOf('$$', a) + 2));
  return src.slice(a, b + 3);
};

test('migraatio: asetukset, päivälaskuri, indeksi ja vain analytiikan funktiot', () => {
  const c = code(mig);
  for (const k of ['analytics_rl_ip_per_10min', 'analytics_rl_noip_per_10min', 'analytics_daily_cap', 'analytics_retention_months']) assert.match(c, new RegExp(`'${k}'`));
  assert.match(c, /'analytics_retention_months', '13'::jsonb/);
  assert.match(c, /on conflict \(key\) do nothing/);
  assert.match(c, /create index if not exists analytics_events_date_type_session_idx on booking\.analytics_events\(event_date, event_type, session_key\)/);
  assert.match(c, /alter table booking\.analytics_daily_counts enable row level security/);
  const fns = [...c.matchAll(/create or replace function ([a-z_.]+)\(/g)].map((m) => m[1]).sort();
  assert.deepEqual(fns, ['booking._analytics_path', 'booking._analytics_utm_ok', 'booking.admin_analytics_summary', 'booking.analytics_cleanup', 'booking.public_track_event'].sort(),
    'ei kosketa muiden avointen töiden (145/146/148/149) funktioihin');
  assert.doesNotMatch(c, /(^|[^a-z_])public\.[a-z_]+/m, 'ei public-skeemaan');
  assert.doesNotMatch(c, /\b(price|vat|alv)[a-z_]*\s*=/i, 'ei hintoja/ALV:tä');
});

test('migraatio: IP-raja _rate_limitillä ilman raakaa IP:tä, katto hiljaa, lähde palvelimelta', () => {
  const f = code(fnBlock(mig, 'public_track_event'));
  assert.match(f, /booking\._client_ip\(\)/);
  assert.match(f, /booking\._rate_limit\(/);
  assert.match(f, /md5\(/, 'IP vain päiväkohtaisena tiivisteenä');
  assert.match(f, /'analytics:noip'/);
  assert.match(f, /"code":"rate_limited"/);
  assert.match(f, /analytics_daily_cap/);
  assert.match(f, /v_source := booking\._analytics_source\(/);
  assert.doesNotMatch(f, /p_payload->>'source_category'/, 'asiakkaan lähdekategoria ohitetaan');
  assert.match(f, /booking\._analytics_path\(p_payload->>'path'\)/);
  assert.match(f, /booking\._analytics_utm_ok\(v_us, 40\)/);
  assert.match(f, /booking\._analytics_utm_ok\(v_uc, 60\)/);
  const s = code(fnBlock(mig, 'admin_analytics_summary'));
  assert.match(s, /group by a\.event_date/);
  assert.match(s, /'daily_series'/);
});

test('migraatio: tunnetut polut kattavat sivuston sivut, tilaus- ja artikkelisivut', () => {
  const f = fnBlock(mig, '_analytics_path');
  const site = JSON.parse(read('content/site.json'));
  const art = JSON.parse(read('content/articles.json'));
  const paths = [...Object.values(site.pages).flatMap((p) => [p.fi, p.en]), art.path.fi, art.path.en, '/tilaus/', '/en/order/'].filter(Boolean);
  // /en/privacy/ (cursor/en-privacy-sivu) ei vielä _analytics_path-listassa → kirjautuu '/muu'; lisätään erillisellä migraatiolla (ei tässä PR:ssä, ei tietokantamuutoksia)
  const PENDING_PATHS = new Set(['/en/privacy/']);
  for (const p of paths) if (!PENDING_PATHS.has(p)) assert.ok(f.includes(`'${p}'`), `polku ${p} puuttuu tunnetuista`);
  assert.match(f, /return '\/muu'/);
  assert.match(f, /(hallinta|admin)/);
});

test('cron: booking_analytics_cleanup luodaan idempotentisti ja rollback poistaa sen', () => {
  const c = code(mig);
  assert.match(c, /to_regprocedure\('cron\.schedule\(text,text,text\)'\) is not null/);
  assert.match(c, /not exists \(select 1 from cron\.job where jobname = 'booking_analytics_cleanup'\)/);
  assert.match(c, /cron\.schedule\('booking_analytics_cleanup', '[0-9* ]+', 'select booking\.analytics_cleanup\(\)'\)/);
  assert.match(c, /grant execute on function booking\.analytics_cleanup\(\) to service_role/);
  assert.match(code(rb), /cron\.unschedule\('booking_analytics_cleanup'\)/);
});

test('rollback palauttaa booking_144:n määritelmät sellaisenaan ja poistaa 150:n lisäykset', () => {
  for (const fn of ['public_track_event', 'admin_analytics_summary']) assert.equal(fnBlock(rb, fn), fnBlock(m144, fn), `${fn} = 144`);
  const c = code(rb);
  for (const d of ['drop function if exists booking.analytics_cleanup()', 'drop function if exists booking._analytics_path(text)',
    'drop function if exists booking._analytics_utm_ok(text, integer)', 'drop table if exists booking.analytics_daily_counts',
    'drop index if exists booking.analytics_events_date_type_session_idx']) assert.ok(c.includes(d), d);
  assert.match(c, /delete from booking\.settings where key in \('analytics_rl_ip_per_10min', 'analytics_rl_noip_per_10min', 'analytics_daily_cap', 'analytics_retention_months'\)/);
  assert.match(read('booking/supabase/tests/analytics/t150_analytics_hardening.sql'), /TESTRESULT/);
});

test('analytics.js: ei fetch-käärettä, mittaus edelleen oletuksena pois', () => {
  const src = read('public/js/analytics.js'), c = src.replace(/\/\/[^\n]*/g, '');
  assert.doesNotMatch(c, /window\.fetch\s*=|globalThis\.fetch\s*=|installNetworkListener|\.clone\(\)/);
  assert.doesNotMatch(c, /document\.cookie|localStorage|sessionStorage|indexedDB/);
  assert.match(src, /cfg\?\.enabled !== true/);
  assert.doesNotMatch(c, /source_category/, 'lähdekategoriaa ei lähetetä');
});

test('analytics.js: UTM- ja polkusäännöt samat kuin palvelimella', async () => {
  const m = await import(pathToFileURL(join(root, 'public/js/analytics.js')).href);
  assert.equal(m.normUtm('Google', 40), 'google');
  assert.equal(m.normUtm('kevat_2026', 60), 'kevat_2026');
  for (const bad of ['matti@example.com', 'x0401234567', '040-123-45-67', '12345', '-alku', 'a b', 'ä', 'x'.repeat(41)]) assert.equal(m.normUtm(bad, 40), undefined, bad);
  assert.equal(m.normUtm('x'.repeat(60), 60), 'x'.repeat(60));
  assert.equal(m.sitePath('/saunotus-uusi/varaa/', '/saunotus-uusi'), '/varaa/');
  assert.equal(m.sitePath('//varaa//', ''), '/varaa/');
  const T = '0b8f6f3c-1d2e-4f5a-8b9c-0d1e2f3a4b5c';
  assert.equal(m.orderTokenFrom({ pathname: '/tilaus/', search: `?t=${T}`, hash: '' }, ''), T);
  assert.equal(m.orderTokenFrom({ pathname: '/en/order/', search: `?t=${T.toUpperCase()}`, hash: '' }, ''), T);
  assert.equal(m.orderTokenFrom({ pathname: '/varaa/', search: '', hash: `#${T}` }, ''), T);
  assert.equal(m.orderTokenFrom({ pathname: '/varaa/', search: `?t=${T}`, hash: '#/tuote/x' }, ''), null);
  assert.equal(m.orderTokenFrom({ pathname: '/tilaus/', search: '?t=ei-token', hash: '' }, ''), null);
  assert.equal(m.track('page_view'), undefined);
});

// Valeselain: window = globalThis. Moduuli luetaan uudelleen query-parametrilla, jolloin sivuvaikutukset ajetaan.
async function browser({ path = '/', search = '', hash = '', dnt = undefined, replies = [], failFetch = false, tag }) {
  const calls = [], timers = [], listeners = {};
  const realFetch = async () => { throw new Error('ei verkkoa'); };
  const saved = {};
  const set = (k, v) => { saved[k] = Object.getOwnPropertyDescriptor(globalThis, k); Object.defineProperty(globalThis, k, { value: v, configurable: true, writable: true }); };
  set('window', globalThis);
  set('SAUNA_ANALYTICS_CONFIG', { enabled: true, url: 'https://x.supabase.co/', anonKey: 'anon' });
  set('navigator', { doNotTrack: dnt, webdriver: false });
  set('location', { pathname: path, search, hash, href: `https://saunotus.fi${path}${search}${hash}` });
  set('document', { referrer: 'https://www.google.com/search?q=matti', documentElement: { lang: 'fi' }, addEventListener: () => {} });
  set('innerWidth', 390);
  set('addEventListener', (t, f) => { listeners[t] = f; });
  set('setTimeout', (f, ms) => { timers.push({ f, ms }); return timers.length; });
  const fetchStub = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body).p_payload });
    if (failFetch) throw new Error('verkko poikki');
    const r = replies.length ? replies.shift() : { ok: true };
    return { json: async () => r };
  };
  set('fetch', fetchStub);
  await import(pathToFileURL(join(root, 'public/js/analytics.js')).href + `?case=${tag}`);
  await new Promise((r) => setImmediate(r)); await new Promise((r) => setImmediate(r));
  const sameFetch = globalThis.fetch === fetchStub;
  const restore = () => { for (const [k, d] of Object.entries(saved)) { if (d) Object.defineProperty(globalThis, k, d); else delete globalThis[k]; } };
  const flush = async () => { await new Promise((r) => setImmediate(r)); await new Promise((r) => setImmediate(r)); };
  return { calls, timers, listeners, sameFetch, restore, flush, realFetch };
}

test('analytics.js valeselaimessa: page_view ilman queryä, kelvoton UTM pois, fetch koskematon', async () => {
  const b = await browser({ path: '/varaa/', search: '?utm_source=Matti%40example.com&utm_campaign=Kevat_2026&utm_medium=0401234567', tag: 'pv' });
  try {
    assert.ok(b.sameFetch, 'window.fetch ei vaihdu');
    assert.equal(b.calls.length, 1);
    const p = b.calls[0].body;
    assert.equal(p.event_type, 'page_view');
    assert.equal(p.path, '/varaa/');
    assert.equal(p.utm_source, undefined);
    assert.equal(p.utm_medium, undefined);
    assert.equal(p.utm_campaign, 'kevat_2026');
    assert.equal(p.referrer_domain, 'www.google.com');
    assert.equal(p.source_category, undefined);
    assert.equal(b.calls[0].init.credentials, 'omit');
    assert.ok(!JSON.stringify(p).includes('matti'), 'ei henkilötietoa');
  } finally { b.restore(); }
});

test('analytics.js valeselaimessa: osto tilaussivulla eksplisiittisesti, not_paid → rajattu uudelleenyritys', async () => {
  const T = '0b8f6f3c-1d2e-4f5a-8b9c-0d1e2f3a4b5c';
  const np = { ok: false, code: 'not_paid' };
  const b = await browser({ path: '/tilaus/', search: `?t=${T}`, replies: [{ ok: true }, np, np, np, np, np], tag: 'buy' });
  try {
    assert.ok(b.sameFetch);
    assert.deepEqual(b.calls.map((c) => c.body.event_type), ['page_view', 'purchase']);
    assert.equal(b.calls[0].body.path, '/tilaus/');
    assert.equal(b.calls[0].body.order_token, undefined, 'token ei page_view-tapahtumaan');
    assert.equal(b.calls[1].body.order_token, T);
    for (const ms of [15000, 45000, 120000]) {
      assert.equal(b.timers.length > 0, true);
      const t = b.timers.shift(); assert.equal(t.ms, ms);
      t.f(); await b.flush();
    }
    assert.equal(b.timers.length, 0, 'enintään 3 uudelleenyritystä');
    assert.equal(b.calls.filter((c) => c.body.event_type === 'purchase').length, 4);
    // hashchange samalla tokenilla ei käynnistä uutta kierrosta
    b.listeners.hashchange?.(); await b.flush();
    assert.equal(b.calls.filter((c) => c.body.event_type === 'purchase').length, 4);
  } finally { b.restore(); }
});

test('analytics.js valeselaimessa: maksettu osto kerran; verkkovirhe ei heitä; DNT estää', async () => {
  const T = '1b8f6f3c-1d2e-4f5a-8b9c-0d1e2f3a4b5c';
  const ok = await browser({ path: '/varaa/', hash: `#${T}`, tag: 'paid' });
  try { assert.equal(ok.calls.filter((c) => c.body.event_type === 'purchase').length, 1); assert.equal(ok.timers.length, 0); } finally { ok.restore(); }
  const fail = await browser({ path: '/tilaus/', search: `?t=${T}`, failFetch: true, tag: 'fail' });
  try { assert.equal(fail.calls.length, 2); assert.equal(fail.timers.length, 0); } finally { fail.restore(); }
  const dnt = await browser({ path: '/', dnt: '1', tag: 'dnt' });
  try { assert.equal(dnt.calls.length, 0); } finally { dnt.restore(); }
});

test('tietosuojaseloste: evästeettömän mittauksen kohta vastaa toteutusta (FI+EN pending-import-50 = koodin oletus, ei <, ei uutta sivua)', async () => {
  const P = await import(pathToFileURL(join(root, 'src/privacy-analytics.mjs')).href);
  const rows = JSON.parse(read('content/site-texts.pending-import-50.json'));
  assert.equal(rows.length, 4);
  for (const r of rows) {
    assert.ok(r.key in P.PRIVACY_ANALYTICS_TEXTS, r.key);
    assert.ok(['fi', 'en'].includes(r.lang));
    assert.doesNotMatch(r.text, /</);
    assert.equal(r.class, 'protected');
    assert.ok(r.text.length <= r.max_len);
    assert.equal(r.text, P.PRIVACY_ANALYTICS_TEXTS[r.key][r.lang]);
  }
  for (const k of Object.keys(P.PRIVACY_ANALYTICS_TEXTS)) for (const l of ['fi', 'en']) assert.ok(rows.some((r) => r.key === k && r.lang === l), `${k} ${l}`);
  const fi = P.PRIVACY_ANALYTICS_TEXTS['ui.site.privacy_analytics_text'].fi, en = P.PRIVACY_ANALYTICS_TEXTS['ui.site.privacy_analytics_text'].en;
  const retention = /\('analytics_retention_months', '(\d+)'::jsonb/.exec(mig)[1];
  assert.match(fi, new RegExp(`Säilytys: ${retention} kuukautta`));
  assert.match(en, new RegExp(`Retention: ${retention} months`));
  for (const re of [/ilman evästeitä/, /IP-osoitetta ei tallenneta/, /oikeutettu etu/, /utm/, /istuntotunniste/, /tilaukseen/, /Do Not Track/, /tietosuojavaltuutetulle/]) assert.match(fi, re);
  for (const re of [/without cookies/, /not stored/, /legitimate interest/, /utm/, /session identifier/, /linked to the order/]) assert.match(en, re);
  // sivu: sama rakenne kuin muut kohdat (h2 + p), vain tietosuojasivulla; EN-sivu (/en/privacy/) vain kb:n _en-teksteillä (tietosuoja-en.test.mjs)
  assert.equal(JSON.parse(read('content/site.json')).pages.privacy.en, '/en/privacy/');
  // pending-propose-61: kohta jätetään pois vain, jos kb-tekstissä on jo oma "N. Evästeetön kävijämittaus" -kohta (ei kahdesti).
  assert.match(read('src/render.mjs'), /\$\{name === 'privacy' && !items\.some\(\(p\) => policyHasAnalyticsSection\(p\.body\)\) \? privacyAnalyticsHtml\(lang, e, txt\) : ''\}/);
  const html = P.privacyAnalyticsHtml('fi', (s) => s, (s) => s.split(/\n+/).map((l) => `<p>${l}</p>`).join(''));
  assert.match(html, /^<h2>Evästeetön kävijämittaus<\/h2>(<p>[^<]+<\/p>){6}$/);
});
