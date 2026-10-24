// Tietosuojaselosteen (kb.policies id 7, avain policy.7.body) uusi FI-teksti: content/site-texts.pending-propose-59.json.
// Lähdetaulupohjainen avain: admin_texts_import hylkää policy.*-avaimen (reserved_key), joten teksti viedään ehdotuksena
// (texts_propose → Joonaksen hyväksyntä → julkaisu kirjoittaa kb.policies.body). Testi tarkistaa sisällön lopullisia
// säilytyspäätöksiä vasten (booking_157 + booking_160, Joonas 24.10.2026) sekä puhelin- ja sähköpostilinkit sivulla. Ei verkkoa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';

const root = resolve(new URL('../..', import.meta.url).pathname);
delete process.env.SITE_ENV; process.env.SITE_URL = 'https://saunotus.fi';
const PL = await import('../../src/policy-lang.mjs');
const J = (f) => JSON.parse(readFileSync(resolve(root, f), 'utf8'));
const rows = J('content/site-texts.pending-propose-59.json');
const row = rows.find((r) => r.key === 'policy.7.body' && r.lang === 'fi');
const t = row.text;
const md5 = (s) => createHash('md5').update(s).digest('hex');

test('tiedosto: vain policy.7.body fi, protected/plain, ehdotus (ei tuontia), pohja = nykyinen kb.policies 7', () => {
  assert.deepEqual(rows.map((r) => `${r.key}|${r.lang}`), ['policy.7.body|fi']);
  assert.equal(row.class, 'protected');
  assert.equal(row.kind, 'plain');
  assert.equal(row.apply, 'texts_propose');
  assert.deepEqual(row.placeholders, []);
  assert.ok(t.length <= row.max_len && row.max_len === 20000);
  // Ehdotus on julkaistu tuotannossa versiona 3 (md5 f1fd3bc0…). kb.json voi olla vielä pohjaversio (v2), tämä teksti (v3)
  // tai jo seuraava ehdotus (pending-propose-61, v4) sen mukaan, milloin kb-snapshot on päivitetty.
  assert.equal(row.base_md5, '89ffef08347494f4c524e6ffb0ada93d');
  assert.equal(md5(t), 'f1fd3bc09b7021c500d295f1ba60d317');
  const cur = J('content/kb/kb.json').policies.find((p) => p.id === 7);
  const next = J('content/site-texts.pending-propose-61.json')[0];
  assert.ok([row.base_md5, md5(t), next.new_md5].includes(md5(cur.body)), 'kb.json:n policy 7 ei ole mikään tunnettu versio');
});

test('teksti on pelkkää tekstiä (_text_validate plain): ei <, ei linkkimerkintää, ei paikkamerkkejä, ei ohjausmerkkejä', () => {
  assert.ok(!t.includes('<'));
  assert.ok(!/\]\(|\{\{|\}\}|javascript:/i.test(t));
  assert.ok(!/[\x01-\x08\x0B\x0C\x0E-\x1F]/.test(t));
  assert.ok(!/\[(TARKISTETTAVA|TÄYDENNETÄÄN|PÄIVÄMÄÄRÄ)/.test(t), 'luonnoksen merkinnät eivät saa jäädä tekstiin');
});

test('rekisterinpitäjä ja yhteystiedot kuten vanhassa tekstissä', () => {
  assert.match(t, /^Rekisterinpitäjä: Sipoonjoen Perinnesauna \/ Havuhattu Oy \(3018112-1\), Hindsbyntie 124, 04130 Sipoo/);
  assert.match(t, /010 299 2866/);
  assert.match(t, /savusauna@saunotus\.fi/);
  assert.match(t, /Hetzner Online GmbH[^\n]*Helsingissä/);
});

test('lopulliset säilytyspäätökset', () => {
  // sähköpostit: rivi säilyy, henkilötiedot tyhjennetään 3 v lähetyksestä; ei 12 kk poistoa
  assert.match(t, /Lähetetyt sähköpostit: lähetettyjä viestejä ei poisteta[^\n]*vastaanottaja ja henkilökohtainen sisältö[^\n]*3 vuoden kuluttua lähettämisestä/);
  assert.ok(!/(sähköpost|viest)[^\n.]*12 kuuka/i.test(t));
  // PDF:t
  assert.match(t, /Lahjakorttien PDF-tiedostot: 3 vuotta/);
  assert.match(t, /Kuitti- ja lasku-PDF:t säilytetään 6 vuotta/);
  assert.match(t, /kirjanpitolaki 2 luku 10 §/);
  // anonymisointi
  assert.match(t, /asiakastiedot anonymisoidaan: rivit säilyvät/);
  assert.match(t, /voimassa oleva markkinointilupa, tietojasi säilytetään niin kauan kuin lupa on voimassa/);
  assert.match(t, /Yritysasiakkaan nimi ja Y-tunnus säilyvät/);
  assert.match(t, /Kirjautumistili poistetaan/);
  assert.ok(!/asiakasrivit? poistetaan/i.test(t));
});

test('vanhan selosteen vanhentuneet kohdat poistettu (Oma Johku, Johku-rekisteri, henkilötunnus, profilointi, mainosevästeet)', () => {
  assert.ok(!/Oma Johku|johku\.com|johku\.fi/i.test(t));
  assert.ok(!/rekisteri sijaitsee Johku/i.test(t));
  assert.ok(!/henkilötunnus/i.test(t));
  assert.ok(!/mainontaevästeitä/i.test(t));
  assert.ok(!/voidaan käyttää profilointiin/i.test(t));
  assert.ok(!/https?:\/\//.test(t), 'ei URL-osoitteita (URL:t lukittuja)');
});

test('linkContacts: puhelin tel:+358102992866 ja sähköposti mailto:, vain kokonaiset osumat, escapoitu teksti säilyy', () => {
  const c = { phone: '010 299 2866', phoneEn: '+358 10 299 2866', phoneTel: '+358102992866', email: 'savusauna@saunotus.fi' };
  assert.equal(PL.linkContacts('puhelin 010 299 2866, savusauna@saunotus.fi.', c),
    'puhelin <a href="tel:+358102992866">010 299 2866</a>, <a href="mailto:savusauna@saunotus.fi">savusauna@saunotus.fi</a>.');
  assert.equal(PL.linkContacts('Phone +358 10 299 2866', c), 'Phone <a href="tel:+358102992866">+358 10 299 2866</a>');
  assert.equal(PL.linkContacts('x.savusauna@saunotus.fi.fi 9010 299 28660 &amp;', c), 'x.savusauna@saunotus.fi.fi 9010 299 28660 &amp;');
  assert.equal(PL.linkContacts('a', {}), 'a');
});

test('tietosuojasivu: kb-tekstin puhelin ja sähköposti ovat linkkejä (nykyinen teksti), muut ehtosivut ennallaan', async () => {
  const R = await import('../../src/render.mjs');
  const w = console.warn; console.warn = () => {};
  try {
    const html = R.policyPage('privacy', 'privacy', 'fi');
    const prose = html.slice(html.indexOf('<div class="narrow prose">'));
    assert.match(prose, /<a href="tel:\+358102992866">010 299 2866<\/a>/);
    assert.match(prose, /<a href="mailto:savusauna@saunotus\.fi">savusauna@saunotus\.fi<\/a>/);
    const terms = R.policyPage('terms', 'terms', 'fi');
    const tp = terms.slice(terms.indexOf('<div class="narrow prose">'));
    assert.ok(!/<a href="mailto:savusauna@saunotus\.fi">savusauna/.test(tp.slice(0, tp.indexOf('</main>'))), 'ehtosivun kb-tekstiin ei lisätä linkkejä');
  } finally { console.warn = w; }
});
