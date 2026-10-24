// /en/privacy/: EN-tietosuojasivu kb.policies-kentistä title_en/body_en. Varalla (EN-teksti puuttuu) sivua ei rakenneta,
// sitemap/kielivalitsin eivät viittaa siihen ja alatunnisteen EN-linkki osoittaa suomenkieliseen sivuun. Ei verkkoa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const root = resolve(new URL('../..', import.meta.url).pathname);
delete process.env.SITE_ENV; process.env.SITE_URL = 'https://saunotus.fi';
const PL = await import('../../src/policy-lang.mjs');
const lib = await import('../../src/lib.mjs');
const R = await import('../../src/render.mjs');
const J = (f) => JSON.parse(readFileSync(resolve(root, f), 'utf8'));
const quiet = (fn) => { const w = console.warn; console.warn = () => {}; try { return fn(); } finally { console.warn = w; } };
const footer = (html) => html.match(/<div class="fbottom">[\s\S]*?<\/div>/)[0];

const P7 = { id: 7, category: 'privacy', title: 'Tietosuojaseloste', body: 'Rekisterinpitäjä: Havuhattu Oy', language: 'fi' };
const P7EN = { ...P7, title_en: 'Privacy policy', body_en: 'Controller: Havuhattu Oy' };

test('policyText: EN vain kun title_en ja body_en ovat molemmat; FI ennallaan', () => {
  assert.deepEqual(PL.policyText(P7, 'fi'), { title: P7.title, body: P7.body });
  assert.equal(PL.policyText(P7, 'en'), null);
  assert.equal(PL.policyText({ ...P7, title_en: 'Privacy' }, 'en'), null);
  assert.equal(PL.policyText({ ...P7, body_en: 'x' }, 'en'), null);
  assert.deepEqual(PL.policyText(P7EN, 'en'), { title: 'Privacy policy', body: 'Controller: Havuhattu Oy' });
  assert.equal(PL.policyText(null, 'fi'), null);
});

test('policiesReady / resolvePrivacyPages: puuttuva, sisäinen tai tyhjä kohta → privacy.en = null, alkuperäinen olio ennallaan', () => {
  const pages = { home: { fi: '/', en: '/en/' }, privacy: { fi: '/tietosuoja/', en: '/en/privacy/' } };
  assert.equal(PL.resolvePrivacyPages(pages, [P7EN], [7]), pages);
  for (const [pol, ids] of [[[P7], [7]], [[P7EN], [8]], [[{ ...P7EN, internal: true }], [7]], [[P7EN], []], [[P7EN], undefined]]) {
    const out = PL.resolvePrivacyPages(pages, pol, ids);
    assert.equal(out.privacy.en, null);
    assert.equal(out.privacy.fi, '/tietosuoja/');
    assert.equal(out.home, pages.home);
  }
  assert.equal(pages.privacy.en, '/en/privacy/');
  const off = { privacy: { fi: '/tietosuoja/', en: null } };
  assert.equal(PL.resolvePrivacyPages(off, [P7EN], [7]), off);
});

test('sisältö: site.json /en/privacy/, ei privacy.json-EN-lohkoa (ei uusia tekstiavaimia), kb-snapshot vie title_en/body_en', () => {
  assert.equal(J('content/site.json').pages.privacy.en, '/en/privacy/');
  assert.deepEqual(Object.keys(J('content/pages/privacy.json')), ['fi']);
  // main (booking_151/#147): kb-snapshot vie _en-kentät EN-taulukon kautta (policies: ['title_en', 'body_en']).
  assert.match(readFileSync(resolve(root, 'scripts/kb-snapshot.mjs'), 'utf8'), /policies: \['title_en', 'body_en'\]/);
});

test('privacyDocFor: EN-meta/hero kb:n EN-tekstistä, kuvat FI-sivulta; ilman EN-tekstiä null; FI ennallaan', () => {
  const fi = J('content/pages/privacy.json').fi;
  assert.equal(PL.privacyDocFor(fi, [P7EN], 'fi'), fi);
  assert.equal(PL.privacyDocFor(fi, [P7], 'en'), null);
  const en = PL.privacyDocFor(fi, [{ ...P7EN, body_en: '\nController: Havuhattu Oy\nMore' }], 'en');
  assert.deepEqual(en, {
    meta: { title: 'Privacy policy | Sipoonjoen Perinnesauna', description: 'Controller: Havuhattu Oy', og: fi.meta.og },
    hero: { title: 'Privacy policy', text: '', img: fi.hero.img },
    policies: fi.policies,
  });
  const long = PL.privacyDocFor(fi, [{ ...P7EN, body_en: 'x'.repeat(300) }], 'en');
  assert.equal(long.meta.description.length, 158);
  assert.ok(long.meta.description.endsWith('…'));
});

test('varalla (kb.json ilman _en-tekstejä): ei EN-sivua, EN-alatunniste linkittää suomenkieliseen sivuun', () => {
  const p = lib.kb.policies.find((x) => x.id === 7);
  assert.ok(p && !p.body_en, 'testi olettaa, että snapshotissa ei vielä ole body_en');
  assert.equal(lib.site.pages.privacy.en, null);
  assert.equal(lib.site.pages.privacy.fi, '/tietosuoja/');
  const f = footer(quiet(() => R.layout({ lang: 'en', key: 'home', meta: { title: 't', description: 'd' }, body: '' })));
  assert.match(f, /<a href="\/tietosuoja\/" hreflang="fi" lang="fi">/);
  assert.doesNotMatch(f, /\/en\/privacy\//);
});

test('EN-tekstit olemassa: /en/privacy/ näyttää title_en/body_en, alatunniste ja kielivalitsin osoittavat EN-sivuun', () => {
  const p = lib.kb.policies.find((x) => x.id === 7);
  Object.assign(p, { title_en: 'Privacy policy (EN)', body_en: 'Controller: Havuhattu Oy.\nContact: savusauna@saunotus.fi' });
  lib.site.pages = PL.resolvePrivacyPages(J('content/site.json').pages, lib.kb.policies, J('content/pages/privacy.json').fi.policies);
  try {
    assert.equal(lib.site.pages.privacy.en, '/en/privacy/');
    const html = quiet(() => R.policyPage('privacy', 'privacy', 'en'));
    assert.match(html, /<h2>Privacy policy \(EN\)<\/h2><p>Controller: Havuhattu Oy\.<\/p><p>Contact: <a href=\"mailto:savusauna@saunotus\.fi\">savusauna@saunotus\.fi<\/a><\/p>/);
    assert.doesNotMatch(html, new RegExp(`<h2>${p.title.replace(/[()]/g, '\\$&')}</h2>`));
    assert.match(footer(html), /<a href="\/en\/privacy\/">Privacy policy \(EN\)<\/a>/);
    assert.match(html, /<h1>Privacy policy \(EN\)<\/h1>/);
    assert.match(html, /<title>Privacy policy \(EN\) \| Sipoonjoen Perinnesauna<\/title>/);
    assert.match(html, /href="\/tietosuoja\/"/);          // kielivalitsin / hreflang FI-versioon
    const fi = quiet(() => R.policyPage('privacy', 'privacy', 'fi'));
    assert.match(fi, new RegExp(`<h2>${p.title.replace(/[()]/g, '\\$&')}</h2>`));
    assert.match(fi, /href="\/en\/privacy\/"/);
  } finally { delete p.title_en; delete p.body_en; }
});
