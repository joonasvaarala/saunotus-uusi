// Paketti 11 / booking_144: SEO (Schema.org, og:locale:alternate, vanhojen osoitteiden noindex-ohjaukset) ja evästeetön kävijämittaus.
// Mittaus on OLETUKSENA POIS: skripti lisätään vain, kun SITE_ANALYTICS=on JA SITE_ENV != test. Ei mittaus-ID:itä eikä avaimia.
// SQL-käyttäytyminen: booking/supabase/tests/analytics/t144_cookieless_analytics.sql (paikallinen PG17, ei CI:ssä).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const imp = (p) => import(pathToFileURL(join(root, p)).href);
const MIG = 'booking/supabase/migrations/20261024113416_booking_144_cookieless_analytics.sql';
const RB = 'booking/supabase/rollbacks/20261024113416_booking_144_ROLLBACK.sql';
const migration = read(MIG), rollback = read(RB);
const sqlBody = migration.replace(/--[^\n]*/g, '');

test('SQL booking_144: taulu, RLS, oikeudet, security definer + search_path', () => {
  assert.match(sqlBody, /create table if not exists booking\.analytics_events/);
  assert.match(sqlBody, /alter table booking\.analytics_events enable row level security/);
  assert.match(sqlBody, /revoke all on booking\.analytics_events from (public, )?anon, authenticated/);
  assert.match(sqlBody, /grant execute on function booking\.public_track_event\(jsonb\) to anon, ?authenticated/);
  assert.match(sqlBody, /grant execute on function booking\.admin_analytics_summary\(date, ?date\) to authenticated/);
  assert.match(sqlBody, /revoke all on function booking\.admin_analytics_summary\(date, ?date\) from public, ?anon;/);
  for (const fn of ['public_track_event', 'admin_analytics_summary']) {
    const i = sqlBody.indexOf(`function booking.${fn}(`);
    assert.ok(i > 0, fn);
    assert.match(sqlBody.slice(i, i + 400), /security definer/i, fn);
    assert.match(sqlBody.slice(i, i + 400), /set search_path = ''/i, `${fn}: tyhjä search_path`);
  }
  // raportti vain samalla oikeudella kuin Raportit
  assert.match(sqlBody, /has_permission\('reports\.view'\)/);
  assert.match(sqlBody, /has_permission\('reports\.daily'\)/);
  // ei henkilötietosarakkeita: ei IP-osoitetta, user agentia, sähköpostia, nimeä eikä täyttä URL:ää
  const table = sqlBody.slice(sqlBody.indexOf('create table if not exists booking.analytics_events'), sqlBody.indexOf(');', sqlBody.indexOf('create table if not exists booking.analytics_events')));
  assert.doesNotMatch(table, /\b(ip|ip_address|user_agent|email|phone|customer_name|full_url|query_string)\b/i);
  // ei kosketa paketti 10:n (booking_142) eikä booking_143:n funktioihin, ei public-skeemaan
  assert.doesNotMatch(sqlBody, /annual_card|discount_code|vuosikortti|alennuskoodi/i);
  assert.doesNotMatch(sqlBody, /\bpublic\.\w+/i);
  assert.doesNotMatch(sqlBody, /\bdrop\s+(table|function)/i, 'migraatio ei pudota mitään');
  assert.match(read('booking/supabase/tests/analytics/t144_cookieless_analytics.sql'), /TESTRESULT/);
});

test('SQL booking_144: rollback pudottaa vain booking_144:n oliot', () => {
  assert.match(rollback, /drop function if exists booking\.admin_analytics_summary\(date, ?date\)/);
  assert.match(rollback, /drop function if exists booking\.public_track_event\(jsonb\)/);
  assert.match(rollback, /drop function if exists booking\._analytics_source\(/);
  assert.match(rollback, /drop table if exists booking\.analytics_events/);
  const drops = rollback.match(/\bdrop\s+\w+\s+if exists\s+booking\.\w+/g) || [];
  assert.equal(drops.length, 4);
});

test('selainskripti: ei evästeitä eikä selaintallennusta, oletuksena pois, DNT/GPC kunnioitetaan', async () => {
  const src = read('public/js/analytics.js');
  assert.doesNotMatch(src.replace(/\/\/[^\n]*/g, ''), /document\.cookie|localStorage|sessionStorage|indexedDB/);
  assert.match(src, /credentials: 'omit'/);
  assert.match(src, /cfg\?\.enabled !== true/);
  assert.match(src, /globalPrivacyControl/);
  assert.match(src, /doNotTrack/);
  assert.doesNotMatch(src, /G-[A-Z0-9]{6,}|UA-\d|GTM-|gtag\(|fbq\(|googletagmanager/i, 'ei kolmannen osapuolen mittaus-ID:itä');
  const m = await imp('public/js/analytics.js');   // Node: ei windowia → ei sivuvaikutuksia
  assert.equal(m.deviceType(390), 'mobile');
  assert.equal(m.deviceType(800), 'tablet');
  assert.equal(m.deviceType(1280), 'desktop');
  assert.equal(m.track('page_view'), undefined);
});

test('build-pages: mittaus vain SITE_ANALYTICS=on eikä koskaan testisivulla; ei hallintaan eikä ohjaussivuille', () => {
  const bp = read('scripts/build-pages.mjs');
  assert.match(bp, /const ANALYTICS_ON = process\.env\.SITE_ANALYTICS === 'on' && process\.env\.SITE_ENV !== 'test';/);
  assert.match(bp, /if \(ANALYTICS_ON\) \{/);
  assert.match(bp, /\['hallinta', 'vuoro', 'juomat', 'drinks', 'booking'\]/);
  assert.match(bp, /data-redirect="legacy"/);
  assert.match(bp, /kävijämittaus mukana, vaikka se on pois päältä/);
  assert.match(bp, /'views\/talous-analytics\.js', 'analytics-mock\.js'/);
  const wf = read('.github/workflows/pages.yml');
  assert.doesNotMatch(wf, /SITE_ANALYTICS/, 'CI ei kytke mittausta päälle');
  assert.match(wf, /SITE_ENV: test/);
});

test('SEO: Schema.org-lisäykset sivupohjassa, ei arvostelumerkintöjä', () => {
  const r = read('src/render.mjs');
  assert.match(r, /'@type': \['DaySpa', 'HealthAndBeautyBusiness'\], '@id': abs\('\/#business'\)/);
  assert.match(r, /priceRange: '€€'/);
  assert.match(r, /og:locale:alternate/);
  assert.match(r, /seoSchemaForPage\(\{ lang, key, url, body \}\)\.map\(jsonLdScript\)/);
  const s = read('src/seo-enhance.mjs');
  assert.doesNotMatch(s.replace(/\/\/[^\n]*/g, ''), /aggregateRating|reviewCount|ratingValue/);
});

test('SEO: seoSchemaForPage merkitsee vain näkyvät kortit ja infosivun näkyvät kysymykset', async () => {
  const S = await imp('src/seo-enhance.mjs');
  assert.deepEqual(S.seoSchemaForPage({ lang: 'fi', key: 'sauna', url: 'https://x.test/saunavuorot/', body: '' }), [], 'ei näkyviä kortteja → ei Product-merkintää');
  assert.deepEqual(S.seoSchemaForPage({ lang: 'fi', key: 'home', url: 'https://x.test/', body: '<h3>x</h3>' }), []);
  assert.deepEqual(S.seoSchemaForPage({ lang: 'fi', key: 'info', url: 'https://x.test/info/', body: '' }), []);
  assert.match(S.jsonLdScript({ a: '</script>' }), /\\u003c\/script>/);
});

test('vanhat osoitteet: noindex-ohjaukset, eivät korvaa nykyisiä sivuja eivätkä ole sitemapissa', async () => {
  const S = await imp('src/seo-enhance.mjs');
  const { site } = await imp('src/lib.mjs');
  const current = new Set(Object.values(site.pages).flatMap((x) => [x.fi, x.en]));
  const valid = S.validLegacyRedirects();
  assert.ok(valid.length >= 1);
  for (const [from, to] of valid) { assert.ok(!current.has(from), from); assert.ok(current.has(to), to); }
  assert.deepEqual(S.validLegacyRedirects({ x: { fi: '/varaa-sauna/' }, y: { fi: '/varaa/' } }).map((x) => x[0]).includes('/varaa-sauna/'), false, 'nykyinen polku ei jää ohjauksen alle');
  const html = S.redirectHtml('/varaa/');
  assert.match(html, /<meta name="robots" content="noindex,follow">/);
  assert.match(html, /<meta http-equiv="refresh" content="0;url=[^"]+\/varaa\/">/);
  assert.match(html, /data-redirect="legacy"/);
  assert.equal((html.match(/<h1>/g) || []).length, 1);
  assert.doesNotMatch(html, /blue|#00f|#0000ff/i);
  for (const c of html.match(/#[0-9a-f]{6}\b/gi) || []) assert.ok(['#F4EFE7', '#2B3A30', '#7A5530'].includes(c.toUpperCase()), c);
  const b = read('scripts/build.mjs');
  assert.match(b, /validLegacyRedirects\(\)\.filter\(\(\[oldPath\]\) => !existsSync/);
  assert.doesNotMatch(b.split('\n').find((l) => l.startsWith("write('/sitemap.xml'")), /legacy/, 'ohjaukset eivät ole sitemapissa');
  const ch = read('scripts/check.mjs');
  assert.match(ch, /ohjaussivulta puuttuu noindex/);
});

test('tekstit: ohjaussivun tekstit pending-import-44:ssä FI+EN, ei <-merkkejä, sama kuin koodin oletus', async () => {
  const rows = JSON.parse(read('content/site-texts.pending-import-44.json'));
  const S = await imp('src/seo-enhance.mjs');
  assert.equal(rows.length, 6);
  for (const r of rows) {
    assert.ok(r.key.startsWith('ui.site.redirect_'), r.key);
    assert.ok(['fi', 'en'].includes(r.lang));
    assert.ok(!r.text.includes('<'));
    assert.ok(r.text.length <= r.max_len);
    assert.equal(r.text, S.REDIRECT_TEXTS[r.key][r.lang]);
  }
  for (const k of Object.keys(S.REDIRECT_TEXTS)) for (const l of ['fi', 'en']) assert.ok(rows.some((r) => r.key === k && r.lang === l), `${k} ${l}`);
  // muut pending-import-tiedostot eivät määrittele samoja avaimia
  for (const f of readdirSync(join(root, 'content')).filter((n) => /^site-texts\.pending-import-\d+\.json$/.test(n) && n !== 'site-texts.pending-import-44.json')) {
    assert.ok(!JSON.parse(read(`content/${f}`)).some((r) => r.key.startsWith('ui.site.redirect_')), f);
  }
});

test('hallinta: Kävijät-välilehti Raporttien oikeudella, tekstit FI+EN, teeman värit', async () => {
  const tl = read('booking/admin/views/talous.js');
  assert.match(tl, /\['analytics', 'tab\.analytics'\]/);
  assert.match(tl, /k === 'reports' \|\| k === 'analytics' \? canDaily/);
  assert.match(tl, /analytics: \(\) => createAnalyticsTab\(\)/);
  const v = read('booking/admin/views/talous-analytics.js');
  assert.match(v, /rpcCall\('admin_analytics_summary', ?\{ ?p_from: ?from, ?p_to: ?to ?\}\)/);
  assert.doesNotMatch(v, /#[0-9a-f]{3,8}\b|blue/i, 'ei kovakoodattuja värejä');
  assert.doesNotMatch(v, /\p{Extended_Pictographic}/u);
  const { TEXTS } = await imp('booking/admin/talous-texts.js');
  const used = [...v.matchAll(/'(a\.[a-zA-Z_.]+|tab\.analytics)'/g)].map((m) => m[1]);
  assert.ok(used.length > 30);
  for (const k of used) for (const l of ['fi', 'en']) assert.ok(TEXTS[l][k], `${l} ${k}`);
  const { analyticsMock } = await imp('booking/admin/analytics-mock.js');
  const r = analyticsMock('2026-10-01', '2026-10-07');
  assert.equal(r.daily_series.length, 7);
  assert.ok(r.funnel.visitors >= r.funnel.product_viewers && r.funnel.product_viewers >= r.funnel.checkout_starters && r.funnel.checkout_starters >= r.funnel.buyers);
  const tm = await imp('booking/admin/talous-mock.js');
  const res = await tm.createMock({ n: 30 }).rpc('admin_analytics_summary', { p_from: '2026-10-01', p_to: '2026-10-02' });
  assert.equal(res.daily_series.length, 2);
  assert.match(read('booking/admin/options-mock.js'), /admin_analytics_summary: \(a\) => \{ needAny\('reports\.view', 'reports\.daily'\)/);
});
