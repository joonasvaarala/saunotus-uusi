// Hallinnan UX-uudistus (t388u): selkokieli, Tarkista vain huomiota vaativat, Uusi varaus -tyyppinimet.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import {
  reviewAttentionCount, reviewAttentionSections, attentionKeysEmpty, attentionKeysWithItems, ATTENTION_LABELS_FI,
} from '../admin/review-logic.js';
import { GC_FI, GC_EN } from '../admin/giftcards-texts.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = (p) => readFileSync(join(root, p), 'utf8');

test('selkokieli: tekniset avaimet pois lahjakorteista, tuotteista, viesteistä ja Tarkista-vihjauksesta', () => {
  assert.equal(GC_FI['gc.set.hint'].includes('gift_cards.'), false);
  assert.equal(GC_EN['gc.set.hint'].includes('gift_cards.'), false);
  assert.equal(GC_FI['gc.o.off'].includes('gift_cards.'), false);
  assert.equal(GC_EN['gc.o.off'].includes('gift_cards.'), false);
  const products = src('admin/views/products.js');
  assert.equal(products.includes('kb-taul'), false);
  assert.equal(products.includes('audit-lok'), false);
  assert.equal(products.includes('kb.change_log'), false);
  const messages = src('admin/views/messages.js');
  assert.equal(messages.includes('off, dry_run, live'), false);
  assert.match(messages, /pois \/ harjoitus \/ käytössä/);
  const review = src('admin/views/review.js');
  assert.equal(review.includes('bookings.override'), false);
  const vouchers = src('admin/vouchers-texts.js');
  assert.equal(vouchers.includes('audit-lok'), false);
  assert.equal(vouchers.includes('audit log'), false);
});

test('Tarkista: nollat Kunnossa-riville, vain täydet osiot näkyviin, määrä laskee oikein', () => {
  const list = {
    missing_therapist: [],
    therapist_conflicts: [],
    block_conflicts: [{ reservation_id: 1 }],
    acked_block_conflicts: [{ reservation_id: 9 }],
    overrides: [],
    orphan_addons: [],
  };
  assert.equal(reviewAttentionCount(list), 1);
  assert.equal(reviewAttentionCount(list, 5), 6);
  assert.equal(reviewAttentionSections(list), 1);
  assert.equal(reviewAttentionSections(list, 5), 2);
  assert.deepEqual(attentionKeysWithItems(list), ['block_conflicts']);
  assert.deepEqual(attentionKeysEmpty(list), ['missing_therapist', 'therapist_conflicts', 'overrides', 'orphan_addons']);
  assert.equal(ATTENTION_LABELS_FI.block_conflicts, 'Sulku osuu varaukseen');
  assert.equal(ATTENTION_LABELS_FI.overrides, 'Poikkeukset');
  const review = src('admin/views/review.js');
  assert.match(review, /review-ok/);
  assert.match(review, /hideEmpty: true/);
  assert.match(review, /asiaa vaatii huomiota/);
  assert.match(review, /Kunnossa:/);
  assert.equal(review.includes("empty(opt.empty || 'Ei tarkistettavaa.')"), false);
});

test('yläpalkin Tarkista-määrämerkki on kytketty', () => {
  assert.match(src('admin/index.html'), /id="quick-review-count"/);
  assert.match(src('admin/admin.js'), /refreshReviewBadge/);
  assert.match(src('admin/admin.js'), /quick-review-count/);
  assert.match(src('admin/admin.css'), /\.quick-review-count/);
});

test('Uusi varaus: Saunavuoro, Hoito tai tila, Jälkikirjaus + yhden rivin selitys', () => {
  const rb = src('admin/views/resbooking.js');
  assert.match(rb, /\['', 'Saunavuoro', 'Yleinen tai yksityinen vuoro'\]/);
  assert.match(rb, /\['resurssi', 'Hoito tai tila',/);
  assert.match(rb, /\['vanha', 'Jälkikirjaus',/);
  assert.match(rb, /nb-typecard/);
  assert.equal(rb.includes("'Vuoro']"), false);
  assert.equal(rb.includes("'Resurssivaraus'"), false);
  assert.equal(rb.includes("'Vanha varaus'"), false);
  assert.match(src('admin/admin.css'), /\.nb-typecard/);
  assert.match(src('admin/views/reservations.js'), /Jälkikirjaus/);
});
