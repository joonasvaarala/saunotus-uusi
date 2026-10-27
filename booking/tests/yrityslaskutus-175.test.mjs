// booking_175: yritysasiakkaan laskutustapa (verkkolasku / PDF), verkkokaupan verkkolasku automaattisesti jonoon, viite 7310 + 7-3-1, tila Laskutettu,
// lasku auki Laskut-näkymässä (#/laskut?invoice=<id>). Ei verkkoa eikä tietokantaa. SQL-puoli: supabase/tests/invoices/t175_yrityslaskutus.sql.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const rd = (p) => readFileSync(join(here, '..', p), 'utf8');
const md5 = (s) => createHash('md5').update(s).digest('hex');
const MIG = 'supabase/migrations/20261025090100_booking_175_yrityslaskutus.sql';
const RB = 'supabase/rollbacks/20261025090100_booking_175_ROLLBACK.sql';
// tuotanto (sxbofnuisemspgquoxyv, pg_get_functiondef 25.10.2026) → booking_175
const REPLACED = {
  'booking._clean_company': ['4e8d9dddda117bdc208f3b1bb281f97a', '53fa5a8a98e98aeb4a97000d2f6b37ec'],
  'booking._stamp_order_billing': ['709b28b59f549df7be252b2942e77256', '693f24abfe0dddfbf4a2e345e1596e73'],
  'booking._invoice_allocate': ['ad7dbbd30a6b3362bf4011d4e8ff296e', '46a3326812f896077fc2614ba783ff3d'],
  'booking.orders_invoice_draft_trg': ['a9a389358507c2dca37acbacdcfd3d61', 'a48fe50340cff5f6e9709ad46055ecb9'],
};
const DEPS = {
  _invoice_queue_dispatch: 'f3cfdb0e2d484ab6f63c6286c4ff8560', _ensure_draft_invoice: 'eefa8e82c7aab1a148bdb3e319ae65ae', _fi_reference: 'f7c4076dcc85d8efc97e7335c349da2c',
  _setting: '70fcfa245e9e7d070dae7a6c1e90ce4d', invoices_lock_trg: '63f39183d475f2b04bcc7a9e9aaf251e', orders_invoice_status_trg: '9ec5c212604145e284fa07d2fd2686f6',
  admin_send_invoice: '7ea29743e8e199c74ced1d62c730b27f', public_create_booking: 'befba768679c4e414c4f3966ac4aa136', admin_create_booking: '7ac1ba613b8db0ae6a4c2e6d9b3ce5c7',
  _on_payment_paid: 'de9084871640d213d10527a045157bf2', email_outbox_claim: '2db9a1233a06e6293d0877f17de1ab72', admin_mark_voucher_claim_redeemed: '525d1fa96fd7c37df4d7e502edf1bf71', _vc_due: 'bea9cd9a32eb273ee72caed0aedd1e2e',
  _enqueue_email: '350304b26e7240c42a6cf38f604eb689', _valid_email: '6775eff3f255a0388b3da493a4d730be', email_outbox_claim_base_132: '0b10986533285645d8592449a90a1e0c',
  email_outbox_claim_base_146: '9c63ce8c8b6f46347692859a117d110d', email_outbox_mark: '2ba0222fdfee71942fb09053bd7ea803',
};
// funktiorungot tiedostosta: CREATE OR REPLACE … end $function$ (+ rivinvaihto = pg_get_functiondef-muoto)
const bodies = (sql) => Object.fromEntries([...sql.matchAll(/CREATE OR REPLACE FUNCTION (booking\.[a-z_]+)\([\s\S]*?\nend \$function\$/g)].map((m) => [m[1], m[0] + '\n']));
const code = (sql) => sql.replace(/CREATE OR REPLACE FUNCTION[\s\S]*?\nend \$function\$;/g, '').replace(/--.*$/gm, '');   // muu kuin funktiorungot ja kommentit
const lum = (hex) => { const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((x) => (x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4)); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
const contrast = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };

test('migraatio: korvattujen funktioiden rungot = booking_175-md5, vartija hyväksyy tuotannon tai booking_175:n, riippuvuudet tarkasti', () => {
  const sql = rd(MIG); const b = bodies(sql);
  assert.deepEqual(Object.keys(b).sort(), Object.keys(REPLACED).sort());
  for (const [fn, [prod, after]] of Object.entries(REPLACED)) {
    assert.equal(md5(b[fn]), after, `${fn} runko`);
    assert.ok(sql.includes(`not in ('${prod}', '${after}')`), `${fn} vartija`);
  }
  for (const [fn, h] of Object.entries(DEPS)) assert.ok(new RegExp(`${fn}\\b[\\s\\S]*${h}`).test(sql) && sql.includes(`'${h}'`), `riippuvuus ${fn}`);
  assert.match(sql, /insert into booking\.settings\(key, value, description, is_public\)[\s\S]*'invoice_reference_prefix', '"7310"'[\s\S]*on conflict \(key\) do nothing/);
  assert.doesNotMatch(sql, /\bpublic\./i, 'ei public-skeemaa');
  assert.doesNotMatch(code(sql), /integration_config|daily_enabled|update booking\./i, 'ei Procountor- tai lähetystilan muutoksia');
  assert.match(sql, /'invoice_einvoice_auto_send', 'false'::jsonb,[\s\S]*?false\)\s*on conflict \(key\) do nothing/, 'asetus oletuksena false, ei julkinen');
  assert.doesNotMatch(sql, /insert into booking\.email_outbox|send_email/i, 'ei suoria sähköpostirivejä (vain _enqueue_email)');
  const trgEmails = [...b['booking.orders_invoice_draft_trg'].matchAll(/_enqueue_email\(/g)].length;
  assert.equal(trgEmails, 1, 'yksi jonotuskohta');
  for (const [fn, body] of Object.entries(b)) if (fn !== 'booking.orders_invoice_draft_trg') assert.doesNotMatch(body, /_enqueue_email|email_outbox/, `${fn}: ei sähköposteja`);
  assert.doesNotMatch(sql.replace(/--.*$/gm, ''), /price|vat_rate|slug/i, 'hinnat, ALV, slugit ennallaan');
  // automaattinen jonotus vain verkkokaupan verkkolaskulle, virhe ei kaada tilausta
  const trg = b['booking.orders_invoice_draft_trg'].replace(/--.*$/gm, '');
  assert.match(trg, /new\.source_channel = 'web' and new\.status = 'confirmed' and new\.billing ->> 'invoice_method' in \('einvoice', 'pdf'\)/);
  // verkkolasku: jonotus vain asetuksen takana (oletus false) → muuten luonnos
  assert.match(trg, /if booking\._setting\('invoice_einvoice_auto_send', 'false'::jsonb\) = 'true'::jsonb then\s*perform booking\._invoice_allocate\(v_inv\);\s*perform booking\._invoice_queue_dispatch\(v_inv\);\s*end if;/);
  assert.equal([...trg.matchAll(/_invoice_queue_dispatch/g)].length, 1, 'jonotus vain asetuksen takana');
  // PDF: numerointi kuten admin_send_invoice + yksi invoice_pdf-viesti laskua kohden (dedupe)
  assert.match(trg, /perform booking\._invoice_allocate\(v_inv\);\s*if not booking\._enqueue_email\('invoice_pdf', new\.id, null, null, 'invoice_pdf:auto:' \|\| v_inv,/);
  assert.match(trg, /'to_email', \(select lower\(btrim\(c\.email\)\) from booking\.customers c where c\.id = new\.customer_id\)/, 'varaajan osoite');
  assert.match(trg, /booking\._err\('invalid_email'/, 'ei "lähetetty" ilman viestiä');
  assert.match(trg, /kind = 'debit' and status = 'draft'/, 'vain luonnos → toisto ei jonota uudelleen');
  assert.match(b['booking.orders_invoice_draft_trg'], /exception when others then[\s\S]*'invoice_auto_send_failed'/);
  assert.match(b['booking._invoice_allocate'], /invoice_reference_prefix/); assert.match(b['booking._invoice_allocate'], /char_length\(v_ref\) > 20/);
  assert.match(b['booking._invoice_allocate'], /customer_snapshot_locked/, 'tuotannon lukitus säilyy');
});

test('rollback: palauttaa tuotannon rungot tavu tavulta (md5) ja poistaa asetuksen; vartija + jälkitarkistus', () => {
  const sql = rd(RB); const b = bodies(sql);
  assert.deepEqual(Object.keys(b).sort(), Object.keys(REPLACED).sort());
  for (const [fn, [prod, after]] of Object.entries(REPLACED)) {
    assert.equal(md5(b[fn]), prod, `${fn} = tuotanto`);
    assert.ok(sql.includes(prod) && sql.includes(after), fn);
  }
  assert.match(sql, /delete from booking\.settings where key in \('invoice_reference_prefix', 'invoice_einvoice_auto_send'\);/);
  assert.doesNotMatch(sql, /\bpublic\./i);
  assert.doesNotMatch(code(sql), /update booking\.|reference_no/, 'jo syntyneitä viitteitä ei muuteta');
});

test('SQL-testi t175: tuotantokelpoinen rakenne (yksi transaktio, ei psql-metakomentoja, ei kiinteitä id:itä, oikea henkilökunta, SQLSTATE)', () => {
  const t = rd('supabase/tests/invoices/t175_yrityslaskutus.sql');
  assert.match(t, /^begin;$/m); assert.match(t, /^rollback;$/m); assert.match(t, /raise exception 'TESTRESULT pass=% fail=% skip=%/);
  assert.doesNotMatch(t, /^\s*\\/m, 'ei psql-metakomentoja');
  assert.doesNotMatch(t, /\bpublic\.t175|create function public\./i);
  assert.match(t, /insert into auth\.users/); assert.match(t, /insert into booking\.staff/); assert.match(t, /set local role authenticated/); assert.match(t, /request\.jwt\.claims/);
  assert.doesNotMatch(t, /\bid\s*=\s*\d{2,}\b|values \(\d{3,},/, 'ei kiinteitä id-arvoja');
  assert.match(t, /'invoice_pdf:auto:' \|\| i\.id/); assert.match(t, /set value = 'true'::jsonb where key = 'invoice_einvoice_auto_send'/);
  for (const code of ['invalid_invoice_method', 'einvoice_incomplete', 'invalid_setting', 'already_sent', '42501']) assert.ok(t.includes(code), code);
  for (const lbl of ['A7b ', 'C3 ', 'C4 ', 'C6 ', 'C8 ', 'D1 ', 'D4 ', 'D8 ', 'E1b ', 'E2 ', 'E3 ', 'E5 ', 'F1 ', 'F2 ', 'G4 ', 'H1 ', 'H2 ']) assert.ok(t.includes(`'${lbl}`), lbl);
});

test('viite: 7310 + järjestysnumero + 7-3-1-tarkiste (kuten _fi_reference), kokeilutila samoin', async () => {
  const { fiReference } = await import('../shop/src/invoice-validate.js');
  assert.equal(fiReference('73101'), '731010');
  assert.equal(fiReference('7310123'), '73101237');   // 3·7+2·3+1·1+0·7+1·3+3·1+7·7 = 83 → 7
  assert.ok(fiReference('7310' + '9'.repeat(15)).length <= 20);
  const { createAdminMock } = await import('../admin/options-mock.js');
  const m = createAdminMock();
  const c = await m.rpc('admin_save_invoice_customer', { p: { company_name: 'T175 Oy', business_id: '0112038-9', einvoice_address: '003701120389', einvoice_operator: '003723327487', email: 'a@example.test' } });
  const d = await m.rpc('admin_save_invoice', { p: { customer_id: c.id, lines: [{ description: 'Saunavuoro', quantity: 1, unit: 'kpl', unit_price_net: 10, vat_rate: 25.5 }] } });
  assert.equal(d.status, 'draft'); assert.equal(d.reference_no, null);
  const s = await m.rpc('admin_send_invoice', { p_id: d.id, p_einvoice: true, p_email: false });
  assert.equal(s.reference_no, '731010'); assert.match(s.reference_no, /^7310\d+$/);
});

test('Laskut-linkki: #/laskut?invoice=<id> avaa laskun; avaus hallinnan varauksen jälkeen vain yrityksen laskumaksulla', async () => {
  const L = await import('../admin/invoice-link.js');
  assert.equal(L.invoiceIdFromQuery(new URLSearchParams('invoice=42')), 42);
  for (const bad of ['', 'invoice=', 'invoice=0', 'invoice=-1', 'invoice=1.5', 'invoice=abc', 'invoice=1e3', 'invoice=99999999999999999']) assert.equal(L.invoiceIdFromQuery(new URLSearchParams(bad)), null, bad);
  assert.equal(L.invoiceIdFromQuery(undefined), null);
  assert.equal(L.invoiceHref(7), '#/laskut?invoice=7');
  const ok = { card: false, method: 'invoice', kind: 'company', canInvoices: true, orderId: 5 };
  assert.equal(L.openInvoiceAfterBooking(ok), true);
  for (const o of [{ card: true }, { method: 'pay_later' }, { kind: 'private' }, { canInvoices: false }, { orderId: null }]) assert.equal(L.openInvoiceAfterBooking({ ...ok, ...o }), false, JSON.stringify(o));
  const inv = rd('admin/views/invoices.js');
  assert.match(inv, /export async function render\(\{ query \} = \{\}\)/); assert.match(inv, /invoiceIdFromQuery\(query\)/);
  assert.match(inv, /'ui\.admin\.invoices\.send_einvoice'|send_einvoice/, 'lähetysnapit ennallaan');
  const nb = rd('admin/views/newbooking.js');
  assert.match(nb, /openInvoiceAfterBooking\(\{ card, method: method\.value, kind: kindNow\(\), canInvoices: ctx\.can\('invoices\.manage'\), orderId: r\.order_id \}\)/);
  assert.match(nb, /admin_create_invoice_from_order/); assert.doesNotMatch(nb, /admin_send_invoice/, 'ei automaattista lähetystä hallinnasta');
  const txt = rd('admin/invoices-texts.js');
  assert.match(txt, /'ui\.admin\.invoices\.send_einvoice': 'Lähetä verkkolasku'/); assert.match(txt, /'ui\.admin\.invoices\.send_email': 'Lähetä PDF sähköpostilla'/);
});

test('kauppa: laskutustapa verkkolasku / PDF, OVT vain verkkolaskulla, invoice_method RPC:lle; tila Laskutettu', async () => {
  const shop = rd('shop/src/shop.js');
  assert.match(shop, /\[\['einvoice', t\.invoiceMethodEinvoice\], \['pdf', t\.invoiceMethodPdf\], \['online', t\.invoiceMethodOnline\]\]/);
  assert.match(shop, /einvoiceBox\.hidden = invoiceMethod !== 'einvoice'/);
  assert.match(shop, /el\.required = kind === 'company' && invoiceMethod === 'einvoice'/);
  assert.match(shop, /invoice_method: invoiceMethod, einvoice_address: ei \? normOvt\(val\('einvoice_address'\)\) : null/);
  assert.doesNotMatch(shop, /t\.companyInvoiceNote\b/); assert.doesNotMatch(rd('shop/src/treatment-ui.js'), /t\.companyInvoiceNote\b/);
  const { T } = await import('../shop/src/i18n.js');
  const { OT } = await import('../shop/src/order-texts.js');
  assert.equal(OT.fi['pay.invoiced'], 'Laskutettu'); assert.equal(OT.en['pay.invoiced'], 'Invoiced');
  assert.equal(T.fi.invoiceMethodPdf, 'PDF-lasku sähköpostiin'); assert.equal(T.en.invoiceMethodEinvoice, 'E-invoice');
  assert.equal(T.fi.errors.invalid_invoice_method, 'Valitse laskutustapa.');
});

test('tekstit: pending-import-70 FI+EN = koodin oletukset (text-registry), uudet avaimet, ei <, ei emojeja', async () => {
  const R = await import('../shop/src/text-registry.js');
  const def = new Map(R.collectDefaults().map((r) => [`${r.key}|${r.lang}`, r.text]));
  const rows = JSON.parse(rd('../content/site-texts.pending-import-70.json'));
  assert.equal(rows.length, 18); assert.equal(new Set(rows.map((r) => `${r.key}|${r.lang}`)).size, rows.length);
  const keys = [...new Set(rows.map((r) => r.key))];
  for (const k of ['ui.shop.invoice_method_label', 'ui.shop.invoice_method_einvoice', 'ui.shop.invoice_method_pdf', 'ui.shop.einvoice_details_title', 'ui.shop.einvoice_details_hint',
    'ui.shop.einvoice_details_required', 'ui.shop.company_invoice_method_note', 'ui.shop.error_invalid_invoice_method', 'ui.order.pay.invoiced']) assert.ok(keys.includes(k), k);
  for (const r of rows) {
    assert.equal(r.text, def.get(`${r.key}|${r.lang}`), `${r.key} ${r.lang}`);
    assert.ok(!r.text.includes('<')); assert.doesNotMatch(r.text, /\p{Extended_Pictographic}|https?:\/\//u);
    assert.ok(r.max_len >= r.text.length); assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain'); assert.deepEqual(r.placeholders, []);
  }
  for (const k of keys) for (const l of ['fi', 'en']) assert.ok(rows.some((r) => r.key === k && r.lang === l), `${k} ${l}`);
  const others = readdirSync(join(here, '../../content')).filter((f) => /^site-texts\.(pending-import|imported).*\.json$/.test(f) && f !== 'site-texts.pending-import-70.json');
  for (const f of others) { const rs = JSON.parse(rd(`../content/${f}`)); if (!Array.isArray(rs)) continue; for (const r of rs) assert.ok(!keys.includes(r?.key), `${r?.key} on jo tiedostossa ${f}`); }
  const fb = JSON.parse(rd('../content/site-texts.fallback.json'));
  for (const r of fb.texts || []) assert.ok(!keys.includes(r.key), `${r.key} on jo tuotannossa`);
});

test('CSS: Laskutettu-merkki teeman väreillä (#F4EFE7 / #7A5530, kontrasti ≥ 4.5:1), ei sinistä; laskutustapa ei vieritä sivuttain', () => {
  const css = rd('shop/src/shop.css');
  const badge = css.match(/\.ord-badge\.pay-invoiced\{([^}]*)\}/);
  assert.ok(badge); assert.match(badge[1], /background:#F4EFE7/); assert.match(badge[1], /color:#7A5530/);
  assert.ok(contrast('#7A5530', '#F4EFE7') >= 4.5); assert.ok(contrast('#2B3A30', '#F4EFE7') >= 4.5);
  const blk = css.slice(css.indexOf('/* booking_175: yritysasiakkaan laskutustapa'), css.indexOf('/* booking_175: yritysasiakkaan laskutustapa') + 400).split('\n').slice(0, 3).join('\n');
  assert.doesNotMatch(blk + badge[0], /blue|#00f|#0000ff|width:\s*\d{4}px|min-width:\s*[4-9]\d\dpx/i);
  assert.match(css, /\.bk-kindrow\{display:flex;gap:10px;flex-wrap:wrap\}/, 'valinnat rivittyvät kapealla näytöllä');
});
