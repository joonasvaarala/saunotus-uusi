// shift_offer_horizon (history-sync, tuotannossa ajettu 25.10.2026 versiona 20261025165813): tarjousmoottorin käsin siirrettävä takaraja.
// Rakennetestit (CI:ssä ei Postgresia): history-sync-kääre ja vartija, runko = tuotannon lause (md5), rollback, SQL-testin muoto,
// kytkimiin ei kosketa. SQL-käyttäytyminen: booking/supabase/tests/vuorotarjous/thorizon_shift_offer_horizon.sql (paikallinen PG / tuotanto).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const rd = (p) => readFileSync(resolve(root, p), 'utf8');
const V = '20261025165813';
const MIG = `booking/supabase/migrations/${V}_shift_offer_horizon.sql`;
const RB = `booking/supabase/rollbacks/${V}_shift_offer_horizon_ROLLBACK.sql`;
const SQLT = 'booking/supabase/tests/vuorotarjous/thorizon_shift_offer_horizon.sql';
const PROD_MD5 = 'd99e6ac3f1764a038d585ea74378c98e';
const code = (sql) => sql.split('\n').filter((l) => !/^\s*--/.test(l)).join('\n');
const body = () => {
  const m = rd(MIG);
  const a = m.indexOf(`  execute $hs_${V}$\n`) + `  execute $hs_${V}$\n`.length;
  const b = m.lastIndexOf(`$hs_${V}$;\n`);
  return m.slice(a, b);
};

test('migraatio, rollback ja SQL-testi olemassa', () => {
  for (const p of [MIG, RB, SQLT]) assert.ok(existsSync(resolve(root, p)), p);
});

test('history-sync: otsake, vartija, runko = tuotannon statements[1] (md5)', () => {
  const m = rd(MIG);
  assert.ok(m.startsWith('-- HISTORY-SYNC: applied in production 25.10.2026, do not rerun.'));
  assert.ok(m.includes(PROD_MD5));
  assert.match(m, /p\.proname = 'shift_offer_horizon_until'/);
  assert.ok(m.trimEnd().endsWith(`$hs_${V}$;\nend $hs$;`));
  assert.equal(createHash('md5').update(body(), 'utf8').digest('hex'), PROD_MD5);
});

test('runko: asetus 2026-12-17, apufunktiot, fail closed, viisi paikattua funktiota', () => {
  const c = code(body());
  assert.ok(c.includes("'shift_offer.offer_horizon_until', to_jsonb('2026-12-17'::text)"));
  assert.match(c, /on conflict \(key\) do nothing/);
  assert.ok(c.includes("(p_starts at time zone 'Europe/Helsinki')::date <= booking.shift_offer_horizon_until(), false)"));
  for (const f of ['public.shift_offer_tick', 'public.shift_offer_ensure', 'public.shift_offer_service_closures',
    'public.shift_offer_cancel_for_closure', 'booking.shift_offer_report_issues']) {
    assert.match(c, new RegExp(`create or replace function ${f.replace('.', '\\.')}\\(`, 'i'), f);
  }
  assert.ok(c.includes("'reason', 'horizon'") && c.includes("'reason', 'no_horizon'"));
});

test('kytkimiin ei kosketa (migraatio, rollback)', () => {
  for (const sql of [code(rd(MIG)), code(rd(RB))]) {
    assert.ok(!/update\s+public\.shift_offer_engine_settings/i.test(sql));
    assert.ok(!/update\s+public\.shift_offer_settings/i.test(sql));
    assert.ok(!/allow_staff_ids\s*=/i.test(sql));
    assert.ok(!/update\s+booking\.settings/i.test(sql));
  }
});

test('rollback: transaktio, apufunktiot ja asetus pois', () => {
  const r = code(rd(RB));
  assert.match(r, /^begin;/m);
  assert.ok(r.endsWith('\ncommit;\n'));
  assert.ok(r.includes('drop function if exists booking.shift_offer_in_horizon(timestamptz);'));
  assert.ok(r.includes('drop function if exists booking.shift_offer_horizon_until();'));
  assert.ok(r.includes("delete from booking.settings where key = 'shift_offer.offer_horizon_until';"));
  const raw = rd(RB);
  const inner = raw.slice(raw.indexOf('\nbegin;\n') + '\nbegin;\n'.length, raw.lastIndexOf('commit;\n'));
  assert.equal(createHash('md5').update(inner, 'utf8').digest('hex'), '4836f50f647e8dba8551b1a9174cfc04'); // Bottiavustuksen rollback sanatarkasti
});

test('SQL-testi: rajat, fail closed, TRBK0, kumoaa itsensä', () => {
  const t = rd(SQLT);
  for (const s of ["timestamptz '2026-12-17 23:59 Europe/Helsinki'", "timestamptz '2026-12-18 00:00 Europe/Helsinki'",
    "timestamptz '2026-12-17 22:30 UTC'", "delete from booking.settings where key = 'shift_offer.offer_horizon_until'",
    'public.shift_offer_tick(false, t0)', 'public.shift_offer_ensure(S_IN, t0, false)']) assert.ok(t.includes(s), s);
  assert.match(t, /errcode\s*=\s*'TRBK0'/);
  assert.ok(!/\btest\.[a-z_]+\(/.test(code(t)));
  assert.ok(!/update\s+public\.shift_offer_engine_settings/i.test(code(t)));
});

test('CI ajaa horizon-testit', () => {
  assert.ok(rd('.github/workflows/pages.yml').includes('booking/tests/vuorotarjous-horizon.test.mjs'));
});
