// booking_165: tietosuojaselosteen (kb.policies id 7) EN-tekstiavaimet policy.7.title / policy.7.body [en] ja needs_translation pois neljältä fi-tekstiltä.
// Rakennetarkistukset (ei verkkoa eikä tietokantaa). SQL-käytös: booking/supabase/tests/t165_policy_en_keys.sql (paikallinen PG17:
// lähtötila = tuotanto, migraatio, vartijat, uudelleenajo, rollback x2 + md5, propose -> submit -> approve kirjoittaa kb.policies 7 title_en/body_en).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const repo = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (rel) => readFileSync(join(repo, rel), 'utf8');
const MIG = 'booking/supabase/migrations/20261024370000_booking_165_policy_en_keys.sql';
const RB = 'booking/supabase/rollbacks/20261024370000_booking_165_ROLLBACK.sql';
const T = 'booking/supabase/tests/t165_policy_en_keys.sql';
const PROD = '6e5d43c7dbbc13c75830cd492d94eddd'; // tuotannon md5(pg_get_functiondef(booking._texts_register_sources)) ennen booking_165:tä
const NEW = 'ff8a4cb6fd632d1d967f03c16b0101b1'; // booking_165:n jälkeen
const OLD_WHERE = "s.id <> 7 and lower(coalesce(s.category, '')) <> 'privacy' and s.title !~* '(tietosuoja|privacy)'";
const NEW_WHERE = "(s.id = 7 or (lower(coalesce(s.category, '')) <> 'privacy' and s.title !~* '(tietosuoja|privacy)'))";
const KEYS = {
  'ui.site.privacy_analytics_text': ['e9cc50625f6d01b023c0322bdad083ba', '3e21bd16fd3771a62e68b1921339fc5a'],
  'page.booking_info.note': ['980e5c5d517f47e77ac9c833b389359f', '2ee9d493aeff66f1333956c2081928b3'],
  'page.terms.note': ['3edfc6733fb636d729af638054287cc7', 'f36370fedc3ad4234f9a63b2e8dcf57f'],
  'seo.booking_info.description': ['e53dc5e4bacee6ad80da9a5b6c9893eb', '77061ef3c9f19e9e6b872246bfbab3c1'],
};
const count = (s, sub) => s.split(sub).length - 1;
const code = (s) => s.replace(/--[^\n]*/g, '');

test('booking_165: tiedostot olemassa, yksi migraatio, ei public-skeemaa eikä skeemamuutoksia', () => {
  assert.deepEqual(readdirSync(join(repo, 'booking/supabase/migrations')).filter((n) => /booking_165_/.test(n)), ['20261024370000_booking_165_policy_en_keys.sql']);
  for (const f of [MIG, RB]) {
    const s = code(read(f));
    assert.doesNotMatch(s, /\bpublic\./i, `${f}: ei public-skeemaa`);
    assert.doesNotMatch(s, /\b(alter|drop)\s+table\b|\bcreate\s+table\b|\badd\s+column\b/i, `${f}: ei skeemamuutoksia`);
    assert.match(s, /set local lock_timeout = '5s';/);
  }
});

test('migraatio: md5-vartija, id 7 sallittu vain rekisteröintiehdossa, rivit vain id 7:lle, ei julkaisua', () => {
  const s = read(MIG), c = code(s);
  assert.match(c, new RegExp(`v_md5 not in \\('${PROD}', '${NEW}'\\)`));
  assert.ok(s.indexOf('do $g$') < s.indexOf('CREATE OR REPLACE FUNCTION booking._texts_register_sources()'), 'vartija ennen funktion korvausta');
  assert.equal(count(c, 'CREATE OR REPLACE FUNCTION'), 1, 'vain _texts_register_sources korvataan');
  assert.equal(count(c, NEW_WHERE), 2);
  assert.equal(count(c, OLD_WHERE), 0);
  assert.match(c, /booking\._texts_reg\('kb\.policies', 'id', 'policy', 'title', 'title_en', \$\$'en'\$\$, \$\$'protected'\$\$, \$\$s\.id = 7 and /);
  assert.match(c, /booking\._texts_reg\('kb\.policies', 'id', 'policy', 'body', 'body_en', \$\$'en'\$\$, \$\$'protected'\$\$, \$\$s\.id = 7 and /);
  assert.doesNotMatch(c, /texts_propose|admin_texts_approve|admin_texts_publish|_text_publish\(|update kb\.policies/i, 'ei julkaise eikä kirjoita kb.policies-tauluun');
  assert.doesNotMatch(c, /perform booking\._texts_register_sources\(\)|select booking\._texts_register_sources\(\)/, 'ei rekisteröi muita lähteitä');
});

test('needs_translation: vain neljä fi-avainta, vartijat (en-aika >= fi-aika, versiot ja md5), rollback palauttaa samat', () => {
  const m = code(read(MIG)), r = code(read(RB));
  for (const [k, [fi, en]] of Object.entries(KEYS)) {
    const row = new RegExp(`\\('${k.replace(/\./g, '\\.')}',\\s+2, '${fi}', 2, '${en}'\\)`);
    assert.match(m, row, `migraatio: ${k}`);
    assert.match(r, row, `rollback: ${k}`);
  }
  assert.match(m, /e\.published_at < f\.published_at/);
  assert.match(m, /update booking\.site_texts set needs_translation = false where id = f\.id and lang = 'fi' and needs_translation;/);
  assert.equal(count(m, 'needs_translation = false'), 1);
  assert.match(r, /set needs_translation = true\s+where f\.key = r\.key and f\.lang = 'fi' and not f\.needs_translation/);
});

test('rollback: funktio täsmälleen tuotannon muodossa (md5 kommentissa), kieltäytyy julkaistun tai avoimen version kanssa', () => {
  const s = read(RB), c = code(s);
  assert.match(s, new RegExp(`booking\\._texts_register_sources: ${PROD}`));
  assert.match(c, new RegExp(`v_md5 not in \\('${NEW}', '${PROD}'\\)`));
  assert.equal(count(c, OLD_WHERE), 2);
  assert.equal(count(c, NEW_WHERE), 0);
  assert.match(c, /published_version > 0\) then\s+raise exception/);
  assert.match(c, /status in \('draft', 'proposed', 'approved', 'published'\)\) then\s+raise exception/);
  assert.ok(s.indexOf('do $rb$') < s.indexOf('CREATE OR REPLACE FUNCTION'), 'vartija ennen funktion palautusta');
  // muu funktion runko identtinen migraation kanssa (vain kaksi ehtoa ja kommentit eroavat)
  const fn = (x) => x.slice(x.indexOf('CREATE OR REPLACE FUNCTION booking._texts_register_sources()'), x.indexOf('end $function$') + 14);
  const norm = (x) => fn(x).replaceAll(NEW_WHERE, 'W').replaceAll(OLD_WHERE, 'W').replace(/  -- kb_policies_en_source[^\n]*/g, '');
  assert.equal(norm(read(MIG)), norm(s));
});

test('SQL-testi t165 ajaa migraation ja rollbackin, md5:t yhtenevät; CI ajaa tämän testin', () => {
  const t = read(T);
  assert.match(t, /\\ir \.\.\/migrations\/20261024370000_booking_165_policy_en_keys\.sql/);
  assert.match(t, /\\ir \.\.\/rollbacks\/20261024370000_booking_165_ROLLBACK\.sql/);
  assert.ok(t.includes(`'${PROD}'`) && t.includes(`'${NEW}'`));
  assert.match(t, /TESTRESULT pass=% fail=%/);
  assert.match(read('.github/workflows/pages.yml'), /node --test booking\/tests\/tietosuoja-en-avaimet\.test\.mjs/);
});
