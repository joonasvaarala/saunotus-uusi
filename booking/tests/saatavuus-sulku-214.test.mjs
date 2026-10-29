// booking_214: hoitojen saatavuus = pidon säännöt myös kirjautuneelle henkilökunnalle (suljetut hoito-/perinnesaunotusajat eivät näy vapaina).
// Ei tietokantaa: tarkistaa migraation ja rollbackin rakenteen. Tietokantatestit ajettu DEV:ssä (rollback-transaktio) ja PROD:ssa (read only).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const MIGS = 'booking/supabase/migrations';
const MIG = `${MIGS}/20261029123913_booking_214_treatment_availability_matches_hold.sql`;
const RB = 'booking/supabase/rollbacks/20261029123913_booking_214_ROLLBACK.sql';
const read = (rel) => readFileSync(resolve(root, rel), 'utf8');
const fn = (sql, name) => {
  const a = sql.search(new RegExp(`create or replace function booking\\.${name}\\(`, 'i'));
  assert.ok(a >= 0, name);
  const b = sql.indexOf('$function$', sql.indexOf('$function$', a) + 10);
  return sql.slice(a, b);
};

test('vain yksi booking_214-migraatio', () => {
  assert.deepEqual(readdirSync(resolve(root, MIGS)).filter((f) => /booking_214_/.test(f)), [MIG.split('/').pop()]);
});

test('henkilökunnan liput eivät voi olla NULL', () => {
  const sql = read(MIG);
  assert.match(fn(sql, '_staff_overbook'), /coalesce\(current_setting\('booking\.allow_overbook', true\), ''\) = 'on' and coalesce\(booking\.is_admin\(\), false\)/);
  assert.match(fn(sql, '_staff_off_schedule'), /coalesce\(current_setting\('booking\.allow_off_schedule', true\), ''\) = 'on' and coalesce\(booking\.has_permission\('bookings\.manage'\), false\)/);
});

test('julkinen saatavuus käyttää pidon tarkistusta', () => {
  const sql = read(MIG);
  const helper = fn(sql, '_public_treatment_slot_status');
  assert.match(helper, /booking\._treatment_slot_check\(p_product, p_start, p_persons, true\)/);
  assert.match(helper, /booking\._treatment_plan_status\(/);
  assert.match(helper, /sqlstate 'BK001'/);
  assert.match(sql, /revoke all on function booking\._public_treatment_slot_status\(bigint, timestamptz, integer\) from public, anon, authenticated/);
  const core = fn(sql, '_treatment_availability_core');
  assert.ok(core.indexOf('perform booking._clear_staff_overrides()') < core.indexOf('select * into pc'), 'liput nollataan ensin');
  assert.match(core, /v_st := booking\._public_treatment_slot_status\(p_product_id, v_s, p_persons\)/);
  assert.match(core, /if v_st is not null then v_need := true; end if;/);   // ylityshaku: suljettu aika vain needs_override-merkinnällä
  assert.match(core, /therapist_missing := \(v_st = 'therapist_missing'\)/); // saunottaja puuttuu -käytös ennallaan
  assert.doesNotMatch(sql, /create or replace function booking\.(public_treatment_availability|_treatment_slot_check|_check_claim|_plan_legs|public_create_treatment_booking)\b/i);
  assert.doesNotMatch(sql, /service_role|eyJ/);
});

test('rollback palauttaa funktiot ja poistaa apufunktion', () => {
  const rb = read(RB);
  for (const n of ['_staff_overbook', '_staff_off_schedule', '_treatment_availability_core']) assert.match(rb, new RegExp(`CREATE OR REPLACE FUNCTION booking\\.${n}\\(`));
  assert.match(rb, /drop function if exists booking\._public_treatment_slot_status\(bigint, timestamptz, integer\)/);
  assert.match(read('.github/workflows/pages.yml'), /saatavuus-sulku-214\.test\.mjs/);
});
