// booking_230: Hoidot kiinni sulkee saunottajaa tarvitsevat tuotteet (Joonas 1.11.2026).
// SQL-käyttäytyminen ajetaan psql:llä: booking/supabase/tests/t230_hoidot_saunottaja_closure.sql
// Tämä tarkistus ei tarvitse tietokantaa. Se varmistaa, että migraatio, rollback ja testi ovat paikallaan
// eikä sääntö ole kovakoodattu tuotetunnuksiin.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(new URL('../supabase/migrations/20261101213000_booking_230_hoidot_saunottaja_closure.sql', import.meta.url), 'utf8');
const rollback = readFileSync(new URL('../supabase/rollbacks/20261101213000_booking_230_ROLLBACK.sql', import.meta.url), 'utf8');
const sqlTest = readFileSync(new URL('../supabase/tests/t230_hoidot_saunottaja_closure.sql', import.meta.url), 'utf8');

test('migraatio kirjaa säännön eikä kovakoodaa tuotteita', () => {
  assert.match(migration, /required_skill/);
  assert.match(migration, /therapist_closed/);
  assert.match(migration, /therapist_missing/);
  assert.match(migration, /comment on function booking\._treatment_plan_status/);
  assert.match(migration, /comment on function booking\._check_claim/);
  assert.doesNotMatch(migration, /product_id\s*(=|in)\s*\(?\s*\d+/i);
  assert.doesNotMatch(migration, /create or replace function/i);
});

test('rollback poistaa vain kommentit', () => {
  assert.match(rollback, /_treatment_plan_status\(bigint, timestamp with time zone, timestamp with time zone, integer\) is null/);
  assert.match(rollback, /_check_claim\(bigint, bigint, bigint, text, text, timestamp with time zone, timestamp with time zone, integer, bigint\[\], text, text, boolean, boolean, text\) is null/);
  assert.doesNotMatch(rollback, /create or replace function/i);
});

test('SQL-testi kattaa sulun, Raunin, savusaunan ja kassan', () => {
  for (const piece of [
    'saunotusrituaali',
    'saunarituaali-ja-savusaunavuoro',
    'saunahoito-2',
    'yleinensauna',
    'oma-saunavuoro',
    'therapist_closed',
    'therapist_missing',
    'slot_unavailable',
    'p_override',
    'Rauni kiinni',
    'savusaunaosaan',
    'TESTRESULT pass=',
    'rollback',
  ]) {
    assert.ok(sqlTest.includes(piece), piece);
  }
  assert.match(sqlTest, /closure_calendars c where c\.code = 'hoidot'/);
  assert.doesNotMatch(sqlTest, /where id = (7|8|10|14)\b/);
});
