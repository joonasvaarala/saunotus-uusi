// HALL-PAIVA-01: päivänäkymän järjestys, leveydet, vuoron tyyppimerkki ja täyttöaste.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { sessionFill } from '../admin/day-logic.js';
import { DAY_TEXTS } from '../admin/day-texts.js';

const read = (p) => readFileSync(new URL(`../${p}`, import.meta.url), 'utf8');

test('täyttöaste: yleinen vuoro "6/10", yksityinen vain varattuna, puuttuva max → henkilömäärä', () => {
  assert.equal(sessionFill({ mode: 'shared', max_persons: 10 }, 6), '6/10');
  assert.equal(sessionFill({ mode: 'shared', max_persons: 10 }, 0), '0/10');
  assert.equal(sessionFill({ mode: 'shared', max_persons: null }, 4), '4 hlö');
  assert.equal(sessionFill({ mode: 'exclusive', max_persons: 6 }, 0), '');
  assert.equal(sessionFill({ mode: 'exclusive', max_persons: 6 }, 3), '3 hlö');
});

test('vuoron tyyppi luettavissa tekstinä', () => {
  assert.equal(DAY_TEXTS.fi['ui.admin.day.kind_shared'], 'Yleinen');
  assert.equal(DAY_TEXTS.fi['ui.admin.day.kind_exclusive'], 'Yksityinen');
  const day = read('admin/views/dayparts.js');
  assert.match(day, /ui\.admin\.day\.kind_exclusive/);
});

test('päivänäkymä: työkalurivi heti otsikon alla, yksi Uusi varaus, Sulut painikkeena, ei yhteenvetoriviä, kortit samassa sarakkeessa', () => {
  const day = read('admin/views/day.js'), css = read('admin/admin.css');
  assert.doesNotMatch(day, /text: '\+ Uusi varaus'/);
  assert.doesNotMatch(day, /yhteensä\./);
  assert.match(day, /'data-testid': 'day-blocks-btn'/);
  assert.match(day, /h\('h1'[^]*?h\('div', \{ class: 'daycol' \},\s*toolbar,/);
  assert.match(css, /\.daycol\{max-width:760px/);
  assert.doesNotMatch(css, /\.(dayrev|prepcard|day-notes)[^{]*\{[^}]*max-width:760px/);
});
