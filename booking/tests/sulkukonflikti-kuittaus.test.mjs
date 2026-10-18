// Tarkista: sulkukonfliktin kuittaus (booking_73). Puhdas logiikka ja mock, ei verkkoa eikä tietokantaa.
// SQL-testi: booking/supabase/tests/73_closure_conflict_ack.test.sql. Sääntö: docs/sulkukonfliktin-kuittaus.md
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { REVIEW_TEXTS, fillReviewText, reviewText, clearReviewTextCache } from '../admin/review-texts.js';
import { reviewAttentionCount, canAckBlockConflict, conflictReason, nextAckStep, nextUnackStep, ackArgs, ackNoteOk } from '../admin/review-logic.js';
import { createAdminMock } from '../admin/options-mock.js';

const importRows = JSON.parse(readFileSync(new URL('../../content/site-texts.pending-import-6.json', import.meta.url), 'utf8'));
const fallback = JSON.parse(readFileSync(new URL('../../content/site-texts.fallback.json', import.meta.url), 'utf8'));
const reviewSrc = readFileSync(new URL('../admin/views/review.js', import.meta.url), 'utf8');

const placeholders = (text) => [...new Set([...String(text).matchAll(/\{\{[^{}]*\}\}/g)].map((m) => m[0]))].sort();

test('FI ja EN sisältävät samat ui.admin.review-avaimet, ilman numeroita', () => {
  const fi = Object.keys(REVIEW_TEXTS.fi).sort();
  const en = Object.keys(REVIEW_TEXTS.en).sort();
  assert.deepEqual(fi, en);
  assert.ok(fi.every((k) => k.startsWith('ui.admin.review.')));
  assert.equal(fi.length, 21);
  for (const lang of ['fi', 'en']) {
    for (const [key, text] of Object.entries(REVIEW_TEXTS[lang])) {
      assert.equal(/\d/.test(text), false, `${key} ${lang}`);
      assert.ok(text.trim().length >= 3, key);
    }
  }
  assert.match(REVIEW_TEXTS.fi['ui.admin.review.ack_button'], /Kuittaa \(ei todellinen\)/);
  assert.match(REVIEW_TEXTS.fi['ui.admin.review.ack_note_default'], /Sulku tehty käsin Johkussa/);
  assert.match(REVIEW_TEXTS.fi['ui.admin.review.block_hint'], /kuittaa/);
  assert.match(REVIEW_TEXTS.fi['ui.admin.review.block_hint'], /saatavuutta/);
  assert.equal(REVIEW_TEXTS.fi['ui.admin.review.unack_button'], 'Pura kuittaus');
});

test('tuontitiedosto vastaa sanakirjaa, luokka on normal, ei lukittuja eikä vanhoja avaimia', () => {
  assert.equal(importRows.length, 42);
  const fallbackKeys = new Set((fallback.texts || []).map((r) => r.key));
  for (const lang of ['fi', 'en']) {
    for (const [key, text] of Object.entries(REVIEW_TEXTS[lang])) {
      const row = importRows.find((r) => r.key === key && r.lang === lang);
      assert.ok(row, `${key} ${lang}`);
      assert.equal(row.text, text);
      assert.equal(row.class, 'normal');
      assert.equal(row.kind, 'plain');
      assert.equal(row.max_len, 400);
      assert.deepEqual(row.placeholders, placeholders(text));
      assert.equal(fallbackKeys.has(key), false);
    }
  }
  assert.equal(importRows.some((r) => r.class === 'locked' || r.class === 'protected'), false);
  assert.equal(reviewText('ui.admin.review.block_reason', { reason: 'Perinnesaunotusilta' }), 'Sulku: Perinnesaunotusilta');
  assert.equal(fillReviewText(REVIEW_TEXTS.fi['ui.admin.review.acked_meta'], { by: ' (Joonas)', reason: 'käsin' }), 'Kuitattu (Joonas): käsin');
  clearReviewTextCache();
});

test('kuitatut eivät kasvata tarkistettavien lukua', () => {
  const list = {
    missing_therapist: [{}],
    therapist_conflicts: [],
    block_conflicts: [{ reservation_id: 1 }],
    acked_block_conflicts: [{ reservation_id: 2 }, { reservation_id: 3 }],
    overrides: [],
    orphan_addons: [],
  };
  assert.equal(reviewAttentionCount(list), 2);
  assert.equal(reviewAttentionCount({}), 0);
});

test('kuittaus on kaksivaiheinen ja lyhyt perustelu ei etene', () => {
  assert.equal(ackNoteOk('ab'), false);
  assert.equal(ackNoteOk('  abc  '), true);
  assert.deepEqual(nextAckStep('edit', 'x'), { phase: 'edit', error: 'note_required', submit: false });
  const first = nextAckStep('edit', 'Sulku tehty käsin Johkussa');
  assert.equal(first.submit, false);
  assert.equal(first.phase, 'confirm');
  assert.equal(nextAckStep('confirm', 'Sulku tehty käsin Johkussa').submit, true);
  assert.deepEqual(nextUnackStep('edit'), { phase: 'confirm', submit: false });
  assert.equal(nextUnackStep('confirm').submit, true);
  assert.deepEqual(ackArgs({ reservation_id: 8, block_id: 3 }, '  abc  ', '  '), {
    p_reservation_id: 8, p_block_id: 3, p_note: 'abc', p_label: null,
  });
});

test('sulun nimi tulee kalenterista tai sulun syystä; oikeus on TAI', () => {
  assert.equal(conflictReason({ calendar_name: '1 savusauna kiinni', closure_reason: 'Perinnesaunotusilta', block_reason: 'muu' }), '1 savusauna kiinni: Perinnesaunotusilta');
  assert.equal(conflictReason({ block_reason: 'Sulku tehty käsin Johkussa' }), 'Sulku tehty käsin Johkussa');
  assert.equal(canAckBlockConflict((p) => p === 'blocks.manage'), true);
  assert.equal(canAckBlockConflict((p) => p === 'bookings.override'), true);
  assert.equal(canAckBlockConflict((p) => p === 'bookings.manage'), false);
  assert.equal(canAckBlockConflict(null), false);
});

test('mock: kuittaus siirtää rivin, ei muuta saatavuutta, purku palauttaa', async () => {
  const m = createAdminMock({ now: new Date('2026-10-18T09:00:00.000Z') });
  const open = await m.rpc('admin_review_list');
  assert.equal(open.block_conflicts.length, 1);
  assert.equal(open.acked_block_conflicts.length, 0);
  assert.equal(m.state.availabilityBlocked, true);
  const note = { p_reservation_id: 8801, p_block_id: 501, p_note: 'Sulku tehty käsin Johkussa', p_label: 'Joonas (päätös)' };
  const ack = await m.rpc('admin_ack_block_conflict', note);
  assert.equal(ack.already, false);
  const mid = await m.rpc('admin_review_list');
  assert.equal(mid.block_conflicts.length, 0);
  assert.equal(mid.acked_block_conflicts[0].ack_reason, 'Sulku tehty käsin Johkussa');
  assert.equal(mid.acked_block_conflicts[0].closure_reason, 'Perinnesaunotusilta');
  assert.equal(m.state.availabilityBlocked, true);
  const again = await m.rpc('admin_ack_block_conflict', note);
  assert.equal(again.already, true);
  assert.equal(m.state.blockAcks.length, 1);
  const back = await m.rpc('admin_unack_block_conflict', { p_reservation_id: 8801, p_block_id: 501 });
  assert.equal(back.revoked, true);
  const after = await m.rpc('admin_review_list');
  assert.equal(after.block_conflicts.length, 1);
  assert.equal(after.acked_block_conflicts.length, 0);
  assert.equal(m.state.availabilityBlocked, true);
});

test('mock: ilman blocks.manage- ja bookings.override-oikeutta kuittaus estyy', async () => {
  const plain = createAdminMock({ perms: ['bookings.manage'], role: 'staff' });
  await assert.rejects(
    () => plain.rpc('admin_ack_block_conflict', { p_reservation_id: 8801, p_block_id: 501, p_note: 'Sulku tehty käsin Johkussa' }),
    (e) => e.code === 'forbidden',
  );
  const onlyBlocks = createAdminMock({ perms: ['blocks.manage'], role: 'staff' });
  const ok = await onlyBlocks.rpc('admin_ack_block_conflict', { p_reservation_id: 8801, p_block_id: 501, p_note: 'abc' });
  assert.equal(ok.ok, true);
  assert.equal(onlyBlocks.state.availabilityBlocked, true);
});

test('näkymä kutsuu kuittaus-RPC:t ja ohjeteksti ei ole enää pelkkä siirto tai peruutus', () => {
  assert.match(reviewSrc, /admin_ack_block_conflict/);
  assert.match(reviewSrc, /admin_unack_block_conflict/);
  assert.match(reviewSrc, /data-testid': 'ack-btn'/);
  assert.match(reviewSrc, /data-testid': 'unack-btn'/);
  assert.match(reviewSrc, /acked_block_conflicts/);
  assert.equal(reviewSrc.includes('Siirrä tai peru varaus.'), false);
  assert.match(reviewSrc, /ui\.admin\.review\.block_hint/);
});
