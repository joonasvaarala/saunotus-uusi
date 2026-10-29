// Yksityisvuoro ja jälkilöylyt: "N vapaana" on kapasiteetti, ei vapaiden paikkojen määrä. Merkki pois.
// Yleinen vuoro ja tapahtuma näyttävät määrän. Täynnä / ei varattavissa eivät kuulu tähän.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const { wholeSpaceBooking } = await import(pathToFileURL(join(root, 'shop/src/whole-space.js')).href);
const read = (rel) => readFileSync(join(repo, rel), 'utf8');

test('koko tila: exclusive, yksityisvuoro ja jälkilöylyt; yleinen ja tapahtuma eivät', () => {
  const jalki = { category: 'private_sauna', sale_kind: 'private_shift', slug: 'jalkiloylyt' };
  const priv = { category: 'private_sauna', sale_kind: 'private_shift', slug: 'oma-saunavuoro' };
  const shared = { category: 'public_sauna', sale_kind: 'public_shift' };
  const event = { category: 'event', sale_kind: 'other' };
  assert.equal(wholeSpaceBooking({ mode: 'exclusive', remaining: 20 }, jalki), true);
  assert.equal(wholeSpaceBooking({ mode: 'exclusive', remaining: 18 }, priv), true);
  assert.equal(wholeSpaceBooking({ mode: 'shared', remaining: 20 }, jalki), true, 'jälkilöylyt ilman exclusive-tietoa');
  assert.equal(wholeSpaceBooking({ remaining: 20 }, priv), true);
  assert.equal(wholeSpaceBooking({ mode: 'exclusive' }, { category: 'corporate', slug: 'jalkiloylyt-yrityksille' }), true);
  assert.equal(wholeSpaceBooking({ mode: 'shared', remaining: 8 }, shared), false);
  assert.equal(wholeSpaceBooking({ mode: 'shared', remaining: 4 }, event), false);
  assert.equal(wholeSpaceBooking({ mode: 'shared', remaining: 12 }, {}), false);
});

test('vuorolista: vapaa koko tila ilman merkkiä, täynnä säilyy, yleinen näyttää määrän', () => {
  const shop = read('booking/shop/src/shop.js');
  const slot = shop.slice(shop.indexOf('function slotItem'), shop.indexOf('function viewEventClosed'));
  const day = shop.slice(shop.indexOf('function dayItem'), shop.indexOf('function treatItem'));
  const change = shop.slice(shop.indexOf('async function loadSessions'), shop.indexOf('const horizon = state.settings?'));
  for (const [name, body] of [['tuotesivu', slot], ['päivä', day], ['muutos', change]]) {
    assert.match(body, /spotBadge\(/, name);
    assert.doesNotMatch(body, /bk-badge free/, name);
  }
  assert.match(shop, /function spotBadge\(r, p, ok/);
  assert.match(shop, /wholeSpaceBooking\(r, p\)/);
  assert.match(read('.github/workflows/pages.yml'), /node --test booking\/tests\/koko-tila-vapaana\.test\.mjs/);
});
