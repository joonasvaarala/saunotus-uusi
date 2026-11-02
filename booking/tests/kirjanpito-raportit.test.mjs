// Kirjanpitoraporttien tekstit: sanakirja, PDF-oletukset ja pending-import-27 täsmäävät. FI+EN, ei hintoja eikä osoitteita.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const { REPORT_TEXTS, PREFIXES } = await import(pathToFileURL(join(root, 'admin/reports-texts.js')));
const { GC_PAY_METHODS } = await import(pathToFileURL(join(root, 'admin/giftcards-api.js')));
const pending = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-27.json'), 'utf8'));
const pending104 = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-104.json'), 'utf8'));
const pending108 = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-108.json'), 'utf8'));
const pending119 = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-119.json'), 'utf8'));
const pending120 = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-120.json'), 'utf8'));
const pending121 = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-121.json'), 'utf8'));

function tsTable(file) {
  const src = readFileSync(file, 'utf8');
  const out = {};
  const re = /"((?:ui\.admin|email\.receipt_pdf)\.[^"]+)": \{ fi: ("(?:\\.|[^"\\])*"), en: ("(?:\\.|[^"\\])*")/g;
  for (const m of src.matchAll(re)) out[m[1]] = { fi: JSON.parse(m[2]), en: JSON.parse(m[3]) };
  return out;
}
const reportPdf = tsTable(join(root, 'supabase/functions/report-pdf/texts.ts'));
const receipt = tsTable(join(root, 'supabase/functions/receipt-pdf/texts.ts'));
const RECEIPT_KEYS = ['email.receipt_pdf.col_vat_pct', 'email.receipt_pdf.col_vat_eur', 'email.receipt_pdf.col_gross', 'email.receipt_pdf.word_qty', 'email.receipt_pdf.word_net', 'email.receipt_pdf.word_vat', 'email.receipt_pdf.word_gross', 'email.receipt_pdf.giftcard_info'];
const SHOP_TEXTS = {
  'ui.gift.err.gift_card_vat_rate': {
    fi: 'Lahjakortilla voi maksaa vain tuotteita, joiden arvonlisävero on 25,5 %.',
    en: 'A gift card can pay only for products with 25.5% VAT.',
  },
};

test('pending-import-27 vastaa sanakirjoja, FI+EN, ilman hintoja ja osoitteita', () => {
  const by = new Map(pending.map((r) => [`${r.key}|${r.lang}`, r]));
  const over = new Map([...pending104, ...pending108, ...pending119, ...pending120, ...pending121].map((r) => [`${r.key}|${r.lang}`, r]));
  assert.equal(by.size, pending.length);
  assert.equal(over.size, pending104.length + pending108.length + pending119.length + pending120.length + pending121.length);
  assert.equal(pending.length % 2, 0);
  assert.equal(pending104.length % 2, 0);
  assert.equal(pending108.length % 2, 0);
  assert.equal(pending119.length % 2, 0);
  assert.equal(pending120.length % 2, 0);
  assert.equal(pending121.length % 2, 0);
  for (const lang of ['fi', 'en']) {
    for (const [key, text] of Object.entries(REPORT_TEXTS[lang])) {
      const row = over.get(`${key}|${lang}`) || by.get(`${key}|${lang}`);
      assert.ok(row, key + ' ' + lang);
      assert.equal(row.text, text);
      assert.equal(row.class, 'normal');
      assert.equal(row.kind, 'plain');
      assert.ok(row.max_len >= row.text.length, key);
      assert.equal(reportPdf[key][lang], text);
      assert.equal(key === 'ui.admin.giftcards.vat_rate_error' || !/https?:|@|\d+[.,]\d+/.test(text), true, key);
      assert.ok(PREFIXES.some((p) => key.startsWith(p)));
      if (!over.has(`${key}|${lang}`)) assert.equal(by.get(`${key}|${lang}`).text, text, key);
    }
  }
  for (const r of [...pending104, ...pending108, ...pending119, ...pending120, ...pending121]) assert.equal(REPORT_TEXTS[r.lang][r.key], r.text, r.key);
  for (const key of RECEIPT_KEYS) {
    for (const lang of ['fi', 'en']) {
      const row = by.get(`${key}|${lang}`);
      assert.equal(row.text, receipt[key][lang]);
      assert.equal(row.class, 'protected');
      assert.equal(/https?:|@|\d+[.,]\d+/.test(row.text), false, key);
    }
  }
  assert.equal(receipt['email.receipt_pdf.col_vat'].fi, 'ALV');
  for (const [key, texts] of Object.entries(SHOP_TEXTS)) {
    for (const lang of ['fi', 'en']) {
      const row = by.get(`${key}|${lang}`);
      assert.equal(row.text, texts[lang], key);
      assert.equal(row.class, 'normal');
      assert.equal(row.kind, 'plain');
    }
  }
  assert.equal(Object.keys(REPORT_TEXTS.fi).length, Object.keys(REPORT_TEXTS.en).length);
  const covered = new Set([...pending, ...pending104, ...pending108, ...pending119, ...pending120, ...pending121].filter((r) => r.key.startsWith('ui.admin.reports.') || r.key.startsWith('ui.admin.giftcards.vat_') || r.key.startsWith('ui.gift.') || RECEIPT_KEYS.includes(r.key)).map((r) => `${r.key}|${r.lang}`));
  for (const lang of ['fi', 'en']) for (const key of Object.keys(REPORT_TEXTS[lang])) assert.ok(covered.has(`${key}|${lang}`), key);
});

test('käteinen ei ole uusissa maksutavoissa, ja migraatioissa ei ole commitia', () => {
  assert.equal(GC_PAY_METHODS.includes('cash'), false);
  assert.equal(readFileSync(join(root, 'admin/views/talous-orders.js'), 'utf8').includes("const MANUAL = ['card_terminal'"), true);
  for (const f of ['20261020140000_booking_117_giftcard_vat.sql', '20261020141000_booking_118_accounting_reports.sql', '20261020142000_booking_119_receipt_cash.sql']) {
    const sql = readFileSync(join(root, 'supabase/migrations', f), 'utf8');
    assert.equal(/\bcommit\s*;/i.test(sql), false, f);
  }
  const vat = readFileSync(join(root, 'supabase/migrations/20261020140000_booking_117_giftcard_vat.sql'), 'utf8');
  assert.match(vat, /vat_treatment = 'at_sale'/);
  assert.match(vat, /vat_rate = 25\.5/);
  assert.match(vat, /complimentary/);
  assert.match(vat, /delete from booking\.settings where key = 'gift_cards\.complimentary_vat_treatment'/);
  assert.match(vat, /drop function if exists booking\._gc_complimentary_vat/);
  assert.doesNotMatch(vat, /insert into booking\.settings[\s\S]*complimentary_vat_treatment/);
  assert.match(vat, /gift_card_vat_rate/);
  const cash = readFileSync(join(root, 'supabase/migrations/20261020142000_booking_119_receipt_cash.sql'), 'utf8');
  assert.match(cash, /cash_not_accepted/);
  assert.match(cash, /active = false/);
});
