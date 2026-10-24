// Tietosuojaseloste v4 (kb.policies id 7, avain policy.7.body): content/site-texts.pending-propose-61.json.
// Lisää puuttuvan kohdan "7. Evästeetön kävijämittaus", johon v3:n kohdat 1 ja 5 viittasivat. Sisältö tarkistetaan
// toteutusta vasten (public/js/analytics.js, booking_150 public_track_event/_analytics_path, booking_157 analytics_cleanup).
// Ehdotus: texts_propose → Joonaksen hyväksyntä → kb.policies.body → kb-snapshot. Ei verkkoa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';

const root = resolve(new URL('../..', import.meta.url).pathname);
delete process.env.SITE_ENV; process.env.SITE_URL = 'https://uusi.saunotus.com';
const J = (f) => JSON.parse(readFileSync(resolve(root, f), 'utf8'));
const R0 = (f) => readFileSync(resolve(root, f), 'utf8');
const md5 = (s) => createHash('md5').update(s).digest('hex');
const rows = J('content/site-texts.pending-propose-61.json');
const row = rows[0];
const t = row.text;
const v3 = J('content/site-texts.pending-propose-59.json')[0].text;
const quiet = (fn) => { const w = console.warn; console.warn = () => {}; try { return fn(); } finally { console.warn = w; } };

test('tiedosto: vain policy.7.body fi, protected/plain, ehdotus, pohja = tuotannon v3, new_md5/new_length oikein', () => {
  assert.deepEqual(rows.map((r) => `${r.key}|${r.lang}`), ['policy.7.body|fi']);
  assert.equal(row.class, 'protected');
  assert.equal(row.kind, 'plain');
  assert.equal(row.apply, 'texts_propose');
  assert.deepEqual(row.placeholders, []);
  assert.equal(row.base_version, 3);
  assert.equal(row.base_md5, 'f1fd3bc09b7021c500d295f1ba60d317');
  assert.equal(md5(v3), row.base_md5);
  assert.equal(md5(t), row.new_md5);
  assert.equal(t.length, row.new_length);
  assert.ok(t.length <= row.max_len && row.max_len === 20000);
});

test('pelkkää tekstiä (_text_validate plain): ei <, ei linkkimerkintää, ei URL-osoitteita, ei ohjausmerkkejä', () => {
  assert.ok(!t.includes('<'));
  assert.ok(!/\]\(|\{\{|\}\}|javascript:|https?:\/\//i.test(t));
  assert.ok(!/[\x01-\x08\x0B\x0C\x0E-\x1F]/.test(t));
});

test('vain lisäys: uusi kohta 7 ennen päivityspäivää, viittaukset kohdissa 1 ja 5 osoittavat kohtaan 7, muu teksti ennallaan', () => {
  const lines = t.split('\n');
  assert.deepEqual(lines.filter((l) => /^[0-9]\. /.test(l)).map((l) => l.slice(0, 2)), ['1.', '2.', '3.', '4.', '5.', '6.', '7.']);
  assert.ok(lines.includes('7. Evästeetön kävijämittaus'));
  assert.ok(t.endsWith('Päivitetty 24.10.2026.'));
  assert.ok(t.includes('Evästeetön kävijämittaus on kuvattu kohdassa 7.'));
  assert.ok(t.includes('Kävijämittaus: ks. kohta 7 Evästeetön kävijämittaus.'));
  assert.ok(!/kävijämittaus[^\n]*alla/i.test(t), 'ei viittauksia olemattomaan kohtaan alla');
  const back = t.slice(0, t.indexOf('7. Evästeetön kävijämittaus')) + 'Päivitetty 24.10.2026.';
  const v3n = v3.replace('Evästeetön kävijämittaus on kuvattu omassa kohdassaan alla.', 'Evästeetön kävijämittaus on kuvattu kohdassa 7.')
    .replace('Kävijämittaus: ks. kohta Evästeetön kävijämittaus alla.', 'Kävijämittaus: ks. kohta 7 Evästeetön kävijämittaus.');
  assert.equal(back, v3n);
});

test('kohta 7 vastaa toteutusta: kerätyt tiedot, ei evästeitä/IP:tä, 13 kk → kuukausikooste, oikeutettu etu', () => {
  const s = t.slice(t.indexOf('7. Evästeetön kävijämittaus'));
  const js = R0('public/js/analytics.js');
  const m150 = R0('booking/supabase/migrations/20261024120719_booking_150_analytics_hardening.sql');
  const m157 = R0('booking/supabase/migrations/20261024165608_booking_157_privacy_retention.sql');
  // ei evästeitä / selaintallennusta
  assert.match(s, /ilman evästeitä/);
  assert.ok(!/document\.cookie|localStorage\.|sessionStorage\./.test(js.replace(/^\/\/.*$/gm, '')));
  // kerätyt kentät (selain lähettää vain nämä)
  for (const k of ['path', 'locale', 'device_type', 'referrer_domain', 'utm_source', 'utm_medium', 'utm_campaign', 'session_key']) assert.ok(js.includes(k), k);
  assert.match(s, /osoitteen ilman URL-parametreja/);
  assert.match(s, /verkkotunnuksen \(ei koko osoitetta\)/);
  assert.match(s, /utm-lähde, -media ja -kampanja/);
  assert.match(s, /laitetyypin \(puhelin, tabletti tai tietokone näytön leveyden perusteella\)/);
  assert.match(js, /deviceType\(width\) \{ return width < 700 \? 'mobile' : width < 1024 \? 'tablet' : 'desktop'/);
  assert.match(s, /voimassa vain yhden sivunlatauksen ajan/);
  assert.match(s, /tilaus, sen tuote ja summa/);
  // IP ja user-agent
  assert.match(s, /Emme tallenna IP-osoitetta, selaimen tunnistetietoja/);
  assert.match(m150, /'analytics:ip:' \|\| md5\(v_today::text \|\| ':' \|\| v_ip\)/);
  assert.ok(!/insert into booking\.analytics_events\([^)]*\b(ip|user_agent)\b/.test(m150));
  assert.match(s, /enintään 2 vuorokautta päiväkohtainen tiiviste/);
  // säilytys: 13 kk raakana, sitten kuukausikooste (booking_157 analytics_cleanup) ja poisto
  assert.match(s, /säilytetään 13 kuukautta\. Sen jälkeen ne yhdistetään automaattisesti kuukausittaisiksi yhteenvedoiksi ja poistetaan/);
  assert.match(m150, /'analytics_retention_months', '13'::jsonb/);
  assert.match(m157, /delete from booking\.analytics_events where event_date < v_cut returning \*/);
  assert.match(m157, /insert into booking\.analytics_monthly/);
  assert.match(m157, /'analytics_k_min', '5'::jsonb/);
  assert.match(s, /alle 5 tapahtuman ryhmät yhdistetään/);
  const monthlyCols = m157.match(/create table if not exists booking\.analytics_monthly \(([\s\S]*?)\n\);/)[1];
  for (const c of ['session_key', 'order_id', 'referrer_domain', 'utm_']) assert.ok(!monthlyCols.includes(c), c);
  assert.match(s, /ei ole istuntotunnisteita, tilauksia, viittaavien sivustojen verkkotunnuksia eikä kampanjatunnisteita/);
  // oikeusperuste yhtenäinen kohdan 2 kanssa
  assert.match(s, /Oikeusperuste on oikeutettu etu \(6 artiklan 1 kohdan f alakohta\)/);
  assert.match(t, /evästeetön kävijämittaus sekä väärinkäytösten esto[^\n]*6 artiklan 1 kohdan f alakohta/);
  assert.match(s, /Do Not Track- tai Global Privacy Control/);
  assert.match(js, /globalPrivacyControl === true \|\| navigator\.doNotTrack === '1'/);
  // ei vanhaa "poistetaan 13 kk" -väitettä ilman koostetta
  assert.ok(!/13 kuukautta, minkä jälkeen tiedot poistetaan/.test(t));
});

test('tietosuojasivu: kun kb-tekstissä on kohta 7, erillistä ui.site.privacy_analytics -kohtaa ei näytetä kahdesti', async () => {
  const lib = await import('../../src/lib.mjs');
  const R = await import('../../src/render.mjs');
  const PA = await import('../../src/privacy-analytics.mjs');
  assert.equal(PA.policyHasAnalyticsSection(t), true);
  assert.equal(PA.policyHasAnalyticsSection(v3), false);
  assert.equal(PA.policyHasAnalyticsSection('Evästeetön kävijämittaus on kuvattu kohdassa 7.'), false);
  assert.equal(PA.policyHasAnalyticsSection('8. Cookieless visitor analytics'), true);
  const p = lib.kb.policies.find((x) => x.id === 7);
  const orig = p.body;
  const count = (html) => (html.match(/Evästeetön kävijämittaus<\/(h2|p)>/g) || []).length;
  try {
    p.body = v3;
    const a = quiet(() => R.policyPage('privacy', 'privacy', 'fi'));
    assert.match(a, /<h2>Evästeetön kävijämittaus<\/h2>/);   // v3: erillinen kohta näkyy
    assert.equal(count(a), 1);
    p.body = t;
    const b = quiet(() => R.policyPage('privacy', 'privacy', 'fi'));
    assert.doesNotMatch(b, /<h2>Evästeetön kävijämittaus<\/h2>/);
    assert.match(b, /<p>7\. Evästeetön kävijämittaus<\/p>/);
    assert.equal(count(b), 1);
    assert.match(b, /<a href="tel:\+358102992866">010 299 2866<\/a>/);
  } finally { p.body = orig; }
});
