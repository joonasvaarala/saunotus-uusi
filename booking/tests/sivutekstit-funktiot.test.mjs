// Sivutekstit osa 3 / PR 3 (sopimus §18): sähköpostien, PDF:ien ja edge-funktioiden (mobilepay-start) asiakasnäkyvät tekstit avaimiksi.
//  * content/site-texts.imported-pr66.json noudattaa admin_texts_import-sääntöjä (booking_62) ja §18.2-nimeämistä; generoitu koodista; ei ylikirjoita tuotannon rivejä
//  * sähköpostit: render() antaa SAMAT tavut kuin ennen siirtoa (golden-email.json, 94 tapausta) sekä repon oletuksilla että tuontitiedosto DB:nä; DB-teksti näkyy; rikkinäinen DB-rivi → oletus
//  * jokainen taulukon avain on käytössä; paikkamerkit vain {{var:…}} / {{setting:business_name}}; staattisen sivuston build ei kaadu uusista riveistä; kauppa ei saa email.*-rivejä
// PDF:t (Deno): booking/supabase/functions/pdf-golden.test.ts. Vaatii Noden tyyppien poiston (22.18+); vanhemmalla Nodella ohitetaan (CI ajaa Node 22:lla).
// Ei verkkoa eikä tietokantaa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const root = resolve(new URL('../..', import.meta.url).pathname);
const rd = (p) => readFileSync(join(root, p), 'utf8');
const J = (p) => JSON.parse(rd(p));
const imp = (p) => import(pathToFileURL(join(root, p)));
const work = mkdtempSync(join(tmpdir(), 'sivutekstit-funktiot-'));
test.after(() => rmSync(work, { recursive: true, force: true }));

let FT = null, TPL = null, ST = null;
try { FT = await imp('src/function-texts.mjs'); TPL = await imp('booking/supabase/functions/send-emails/templates.ts'); ST = await imp('booking/supabase/functions/_shared/site_texts.ts'); }
catch (e) { if (!/ERR_UNKNOWN_FILE_EXTENSION|Unknown file extension/.test(String(e?.code || e))) throw e; }
const skip = FT ? false : 'Node ei tue .ts-tuontia (tarvitaan Node >= 22.18)';
const L = await imp('booking/shop/src/site-texts-logic.js');
const B = await imp('src/site-texts.mjs');
const { emailCases } = await imp('booking/supabase/functions/send-emails/golden-cases.mjs');

const FILE = 'content/site-texts.imported-pr66.json';
const PENDING = J(FILE);
const FALLBACK = J('content/site-texts.fallback.json');
// Tuotannossa muokattu tuonnin jälkeen (varateksti versio 2). Tuontitiedosto säilyy v1-tekstinä eikä ylikirjoita kantaa.
const REVISED = new Set(['email.gift_card.how_online', 'email.gift_card.how_offline', 'email.gift_card_pdf.how_online', 'email.gift_card_pdf.how_offline']);
// booking_176: kumppanilahjakorttivarauksen vanha "Kiitos lahjakorttivarauksesta" -viesti korvattu varausvahvistuksella (email.voucher.confirm_*, pending-import-71) → avaimet poistuivat koodista (tuotannon rivit jäävät käyttämättöminä).
const RETIRED = new Set(['email.voucher.received_subject', 'email.voucher.received_title', 'email.voucher.received_p1', 'email.voucher.received_p2', 'email.voucher.more_received']);
const publishedText = (key, lang) => FALLBACK.texts.find((r) => r.key === key && r.lang === lang);
const OTHERS = ['content/site-texts.imported-pr61.json', 'content/site-texts.imported-pr62.json', 'content/site-texts.imported-pr64.json', 'content/site-texts.imported.json', 'content/site-texts.imported-pr71.json'].map(J);
const GOLDEN = J('booking/supabase/functions/send-emails/golden-email.json');
const AREAS = /^(email\.[a-z0-9_]+|ui\.mobilepay\.start_error_[a-z0-9_]+)(\.|$)/;
const VARS = new Set(['name', 'no', 'amount', 'date', 'phone', 'email', 'from', 'who', 'when', 'time', 'n', 'label', 'what', 'code', 'id', 'ref', 'web', 'contact']);   // PR-kuvauksessa mainitut muuttujat
const sha = (s) => createHash('sha256').update(s).digest('hex');
const rowsAsDb = (rows) => rows.map((r) => {
  const fb = publishedText(r.key, r.lang);
  return { key: r.key, lang: r.lang, text: REVISED.has(r.key) && fb?.version > 1 ? fb.text : r.text };
});

test('tuontitiedosto noudattaa admin_texts_import-sääntöjä ja §18.2-nimeämistä', { skip }, () => {
  assert.ok(Array.isArray(PENDING) && PENDING.length > 100 && PENDING.length <= 500, `rivejä ${PENDING.length} (yksi erä ≤500)`);
  const seen = new Set();
  for (const r of PENDING) {
    const w = `${r.key} [${r.lang}]`;
    assert.match(r.key, /^[a-z0-9_]+(\.[a-z0-9_-]+)+$/, w); assert.ok(r.key.length <= 120, w);
    assert.match(r.key, /^(email|ui)\./, w);
    assert.ok(!/^(product|faq|policy|addon|option|giftpkg|schedule|location|hours|event|business|timeline|product_voucher)\.[0-9a-z_-]+\./.test(r.key), `${w}: varattu etuliite`);
    assert.ok(AREAS.test(r.key), `${w}: avainalue`);
    assert.ok(['fi', 'en'].includes(r.lang), w);
    assert.ok(['normal', 'protected'].includes(r.class), w);
    assert.equal(r.kind, 'plain', `${w}: kind (ei lihavointia sähköposteissa/PDF:issä)`);
    assert.ok(r.text && r.text === r.text.trim(), `${w}: tyhjä tai reunavälit`);
    assert.ok(r.max_len >= r.text.length && r.max_len <= 4000, `${w}: max_len`);
    assert.doesNotMatch(r.text, /<\s*\/?\s*[A-Za-z!?]|javascript:|\bon[a-z]+\s*=\s*["']/i, `${w}: raaka HTML ei sallittu (booking_60)`);
    assert.doesNotMatch(r.text, /\]\(/, w); assert.doesNotMatch(r.text, /[\x01-\x08\x0B\x0C\x0E-\x1F]/, w);
    assert.deepEqual([...r.placeholders].sort(), [...new Set(L.tokensOf(r.text))].sort(), `${w}: placeholders ≠ tekstin merkinnät`);
    for (const tok of L.tokensOf(r.text)) {
      assert.match(tok, L.TOKEN_RE, `${w}: ${tok}`);
      const [kind, name] = tok.slice(2, -2).split(':');
      assert.ok(kind === 'var' ? VARS.has(name) : kind === 'setting' && name === 'business_name', `${w}: sallitut paikkamerkit vain {{var:…}} (${[...VARS]}) ja {{setting:business_name}}: ${tok}`);
    }
    assert.doesNotMatch(r.text.replace(/\{\{[^{}]*\}\}/g, ''), /[{}]/, `${w}: yksittäinen aaltosulku`);
    assert.ok(!seen.has(`${r.key}|${r.lang}`), `kaksoisrivi ${w}`); seen.add(`${r.key}|${r.lang}`);
    assert.ok(r.reason && /Osa 3 PR 3/.test(r.reason), w);
  }
  // jokaiselle avaimelle FI + EN
  const byKey = new Map(); for (const r of PENDING) { (byKey.get(r.key) || byKey.set(r.key, new Set()).get(r.key)).add(r.lang); }
  for (const [k, l] of byKey) assert.deepEqual([...l].sort(), ['en', 'fi'], `${k}: FI+EN`);
  // luokat: protected = yhteystiedot, käyttöohjeet, peruutus-/lunastusviestit ja kuitin lakisääteiset kentät
  const prot = new Set(PENDING.filter((r) => r.class === 'protected').map((r) => r.key));
  for (const k of ['email.common.contact', 'email.cancel_request_ack.message', 'email.gift_card.how_online', 'email.receipt_pdf.title', 'email.receipt_pdf.vat_id', 'email.voucher.expired_p1']) assert.ok(prot.has(k), `${k} protected`);
  for (const k of ['email.common.hello', 'email.order_confirmation.title', 'email.payment_link.pay_button', 'ui.mobilepay.start_error_default']) assert.ok(!prot.has(k), `${k} normal`);
});

test('ei päällekkäisiä avaimia muiden tuontien kanssa; tuotannossa jo olevat rivit vastaavat tiedostoa (synkan jälkeenkin)', { skip }, () => {
  const mine = new Map(PENDING.map((r) => [`${r.key}|${r.lang}`, r.text]));
  for (const rows of OTHERS) for (const r of rows) assert.ok(!mine.has(`${r.key}|${r.lang}`), `päällekkäinen ${r.key} [${r.lang}]`);
  for (const r of FALLBACK.texts) {
    const id = `${r.key}|${r.lang}`;
    if (!mine.has(id)) continue;
    if (REVISED.has(r.key)) {
      assert.equal(r.version, 2, `${r.key} [${r.lang}]: tuotannon muokkaus on versio 2`);
      assert.notEqual(r.text, mine.get(id), `${r.key}: tuontitiedoston v1-teksti ei saa vaihtua`);
    } else assert.equal(r.text, mine.get(id), `${r.key}: tuotannossa eri teksti kuin tiedostossa`);
  }
});

test('tiedosto on generoitu koodista (texts.ts) eikä voi poiketa oletuksista', { skip }, () => {
  const prod = join(work, 'empty-prod.json'); writeFileSync(prod, JSON.stringify({ ok: true, texts: [] }));
  const out = join(work, 'gen.json');
  const r = spawnSync(process.execPath, [join(root, 'scripts/site-texts-extract-functions.mjs'), '--prod', prod, '--out', out], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  const gen = JSON.parse(readFileSync(out, 'utf8'));
  const g = new Map(gen.map((x) => [`${x.key}|${x.lang}`, x]));
  for (const f of PENDING) {
    if (RETIRED.has(f.key)) { assert.ok(!g.has(`${f.key}|${f.lang}`), `${f.key}: poistettu avain (booking_176)`); continue; }
    const got = g.get(`${f.key}|${f.lang}`);
    if (REVISED.has(f.key)) {
      const fb = publishedText(f.key, f.lang);
      assert.equal(fb?.text, got.text, `${f.key} [${f.lang}]: varateksti ≠ texts.ts`);
      assert.equal(f.class, got.class);
      assert.equal(f.kind, got.kind);
      assert.deepEqual(f.placeholders, got.placeholders);
      assert.equal(f.reason, got.reason);
      assert.ok(got.max_len >= got.text.length);
    } else assert.deepEqual(f, got, `${f.key}: tiedosto ≠ generaattori`);
  }
  const fb = new Set(FALLBACK.texts.map((x) => `${x.key}|${x.lang}`));
  const extraKnown = new Map([...J('content/site-texts.pending-import-4.json'), ...J('content/site-texts.imported-pr75.json'), ...J('content/site-texts.pending-import-12.json'), ...J('content/site-texts.pending-import-14.json'), ...J('content/site-texts.pending-import-18.json'), ...J('content/site-texts.pending-import-29.json').filter((r) => r.key.startsWith('email.')), ...J('content/site-texts.pending-import-34.json').filter((r) => r.key.startsWith('email.')), ...J('content/site-texts.pending-import-46.json').filter((r) => r.key.startsWith('email.')), ...J('content/site-texts.pending-import-48.json').filter((r) => r.key.startsWith('email.')), ...J('content/site-texts.pending-import-54.json').filter((r) => r.key.startsWith('email.')), ...J('content/site-texts.pending-import-67.json'), ...J('content/site-texts.pending-import-69.json').filter((r) => r.key.startsWith('email.')), ...J('content/site-texts.pending-import-71.json'), ...J('content/site-texts.pending-import-86.json').filter((r) => r.key.startsWith('email.')), ...J('content/site-texts.pending-import-92.json').filter((r) => r.key.startsWith('email.')), ...J('content/site-texts.pending-import-99.json').filter((r) => r.key.startsWith('email.')), ...J('content/site-texts.pending-import-97.json').filter((r) => r.key.startsWith('email.'))].map((r) => [`${r.key}|${r.lang}`, r]));
  for (const [k, x] of g) if (!PENDING.some((f) => `${f.key}|${f.lang}` === k)) {
    const row = extraKnown.get(k);
    if (row) assert.deepEqual({ ...row, reason: x.reason }, x, `${k}: tuontitiedosto ≠ generaattori`);
    else assert.ok(fb.has(k), `${k}: puuttuu tiedostosta eikä ole tuotannossa`);   // tuonnin jälkeen rivit siirtyvät varatekstiin
  }
  // sama generointi tuoreesta tuotantovastauksesta, jossa osa riveistä on jo: vain puuttuvat
  const half = PENDING.slice(0, 10).map((x) => ({ key: x.key, lang: x.lang, text: x.text, version: 1, placeholders: x.placeholders }));
  writeFileSync(prod, JSON.stringify({ ok: true, texts: half })); spawnSync(process.execPath, [join(root, 'scripts/site-texts-extract-functions.mjs'), '--prod', prod, '--out', out]);
  assert.equal(JSON.parse(readFileSync(out, 'utf8')).length, gen.length - 10);
});

test('FI-oletukset eivät sisällä kovakoodattua yritysnimeä muualla kuin paikkamerkissä (poikkeus: taivutettu muoto), EN ei sisällä FI-sanoja', { skip }, () => {
  for (const r of PENDING) {
    if (r.lang === 'en') assert.doesNotMatch(r.text, /\b(Kiitos|Hei|Tilaus|Ystävällisin|lahjakortti)\b/, `${r.key}: FI-sana EN-tekstissä`);
    if (r.key === 'email.gift_card.intro_recipient' && r.lang === 'fi') continue;       // "Sipoonjoen Perinnesaunalle" (taivutus ei onnistu paikkamerkillä)
    assert.doesNotMatch(r.text, /Sipoonjoen Perinnesauna/i, `${r.key} [${r.lang}]: yritysnimi → {{setting:business_name}}`);
  }
});

// ---------- sähköpostit ----------
const run = (t) => Object.fromEntries(emailCases().map((c) => { const m = TPL.render(c.kind, structuredClone(c.data), c.locale, t); return [c.name, { subject: sha(m.subject), text: sha(m.text), html: sha(m.html) }]; }));
test('sähköpostit: sama sisältö tavu tavulta kuin ennen siirtoa (repon oletukset)', { skip }, () => {
  const got = run(undefined);
  assert.equal(Object.keys(got).length, Object.keys(GOLDEN).length);
  for (const k of Object.keys(GOLDEN)) assert.deepEqual(got[k], GOLDEN[k], `${k}: viesti muuttui`);
});
test('sähköpostit: sama sisältö kun KAIKKI tuontitiedoston rivit ovat tietokannassa', { skip }, () => {
  const got = run(ST.makeT(TPL.EMAIL_TEXTS, rowsAsDb(PENDING.filter((r) => r.key.startsWith('email.'))), { business_name: 'Sipoonjoen Perinnesauna' }));
  for (const k of Object.keys(GOLDEN)) assert.deepEqual(got[k], GOLDEN[k], `${k}: DB-rivit eivät vastaa oletuksia`);
});
test('sähköpostit: jokainen email.*-avain on käytössä ja jokaisella käytetyllä avaimella on rivi', { skip }, () => {
  const used = new Set();
  const t = ST.makeT(TPL.EMAIL_TEXTS); const spy = (k, l, v) => { used.add(k); return t(k, l, v); };
  for (const c of emailCases()) TPL.render(c.kind, structuredClone(c.data), c.locale, spy);
  const quoteNotify = { to_name: 'Joonas', reply_to: 'maija@example.test', quote: { id: 42, company_name: 'Sipoon Testi Oy', contact_name: 'Maija Meikäläinen', email: 'maija@example.test', phone: '040 123 4567', persons: 12, offerings: ['ritual', 'forest_yoga', 'campfire_meal', 'sauna', 'vihta_workshop', 'other'], offering_other: 'yrityssaunaretki', preferred_when: 'ensi viikon perjantai', message: 'toive', locale: 'en', created_at: '2026-10-18T19:14:00Z' } };
  for (const locale of ['fi', 'en']) {
    TPL.render('business_quote_ack', { to_name: 'Maija Meikäläinen', locale }, locale, spy);
    TPL.render('business_quote_notify', { ...quoteNotify, locale }, locale, spy);
    TPL.render('waitlist_spot_freed', { locale, to_name: 'Aada Testi', waitlist: { product_name: 'Yleinen vuoro', starts_at: '2026-11-02T14:00:00Z', ends_at: '2026-11-02T17:00:00Z', persons: 2, book_url: 'https://example.test/varaa/#/varaa/1/2026-11-02/2?n=2', leave_url: 'https://example.test/varaa/?poistu_jonosta=3f2b8c1e-7a4d-4e9b-9c55-1d2e3f4a5b6c' } }, locale, spy);
    // booking_148: yksityisvuoron jonopaikka → persons null, vuororivi ilman henkilömäärää
    TPL.render('waitlist_spot_freed', { locale, to_name: 'Aada Testi', waitlist: { product_name: 'Yksityissauna', starts_at: '2026-11-02T14:00:00Z', ends_at: '2026-11-02T17:00:00Z', persons: null, book_url: 'https://example.test/varaa/#/varaa/1/2026-11-02/2?wl=3f2b8c1e-7a4d-4e9b-9c55-1d2e3f4a5b6c', leave_url: 'https://example.test/varaa/?poistu_jonosta=3f2b8c1e-7a4d-4e9b-9c55-1d2e3f4a5b6c' } }, locale, spy);
    TPL.render('waitlist_joined', { locale, to_name: 'Aada Testi', waitlist: { product_name: 'Kekri', starts_at: '2026-10-31T13:00:00Z', ends_at: '2026-10-31T17:00:00Z', persons: 2, leave_url: 'https://example.test/varaa/?poistu_jonosta=3f2b8c1e-7a4d-4e9b-9c55-1d2e3f4a5b6c' } }, locale, spy);
    TPL.render('annual_card_code', { locale, to_name: 'Aada', annual_card: { code: 'VK7QK9TXM3', valid_from: '2026-10-24', valid_to: '2027-10-23', active: true, revoked: false, booking_url: 'https://example.test/varaa/' } }, locale, spy);   // booking_146
    TPL.render('annual_card_code', { locale, to_name: 'Aada', annual_card: { code: 'VK7QK9TXM3', valid_from: '2026-10-24', valid_to: '2027-10-23', active: true, revoked: false, source: 'admin', booking_url: 'https://example.test/varaa/' } }, locale, spy);   // booking_154
    TPL.render('payment_link', { locale, to_name: 'Aada', order: { order_no: 1 }, payment: { amount: 30, link_url: 'https://example.test/maksa/?p=3f2b8c1e-7a4d-4e9b-9c55-1d2e3f4a5b6c' }, voucher_difference: { total: 80, voucher_value: 50, difference: 30 } }, locale, spy);   // booking_174
    TPL.render('unpaid_booking_cancelled', { locale, to_name: 'Aada', order: { order_no: 1, order_url: 'https://example.test/tilaus/?t=3f2b8c1e-7a4d-4e9b-9c55-1d2e3f4a5b6c' }, unpaid_booking: { retry_url: 'https://example.test/varaa/#/tuote/saunahoito-2', product_name: 'Saunahoito', starts_at: '2026-11-07T15:00:00Z' } }, locale, spy);   // booking_190
    TPL.render('event_message', { locale, to_name: 'Aada', event_message: { subject: 'Ilta', body: 'Ota pyyhe mukaan.', event_name: 'Joulusauna', event_name_en: 'Christmas sauna', when_text: '14.11.2026 17:00' } }, locale, spy);   // booking_202
    TPL.render('event_message', { locale, to_name: 'Aada', event_message: { body: 'Ota pyyhe mukaan.', event_name: 'Joulusauna', when_text: '14.11.2026 17:00' } }, locale, spy);
    TPL.render('product_message', { locale, to_name: 'Aada', order: { order_no: 1, order_url: 'https://example.test/tilaus/?t=3f2b8c1e-7a4d-4e9b-9c55-1d2e3f4a5b6c' }, product_message: { category: 'after_marketing', text: 'Hei', link_url: 'https://example.test/a', unsubscribe_url: 'https://example.test/tilaus/?u=3f2b8c1e-7a4d-4e9b-9c55-1d2e3f4a5b6c', marketing_consent: true } }, locale, spy);
  }
  const all = Object.keys(TPL.EMAIL_TEXTS);
  assert.deepEqual(all.filter((k) => !used.has(k)), [], 'käyttämättömiä avaimia');
  assert.deepEqual([...used].filter((k) => !TPL.EMAIL_TEXTS[k]), []);
  assert.ok(all.every((k) => /^email\.[a-z0-9_]+\.[a-z0-9_]+$/.test(k)));
});
test('sähköpostit: yksityisvuoron jonoilmoitus (booking_148, persons null) ei näytä henkilömäärää; yleinen näyttää', { skip }, () => {
  const t = ST.makeT(TPL.EMAIL_TEXTS);
  const w = (persons) => ({ product_name: 'Yksityissauna', starts_at: '2026-11-02T14:00:00Z', ends_at: '2026-11-02T17:00:00Z', persons, book_url: 'https://example.test/varaa/#/varaa/1/2026-11-02/2', leave_url: 'https://example.test/varaa/?poistu_jonosta=3f2b8c1e-7a4d-4e9b-9c55-1d2e3f4a5b6c' });
  for (const locale of ['fi', 'en']) {
    const p = TPL.render('waitlist_spot_freed', { locale, to_name: 'Aada', waitlist: w(null) }, locale, t);
    assert.ok(p.text.includes('Yksityissauna') && !/hlö|guests/.test(p.text), `${locale}: yksityisvuorolla ei henkilömäärää`);
    const g = TPL.render('waitlist_spot_freed', { locale, to_name: 'Aada', waitlist: w(3) }, locale, t);
    assert.ok(locale === 'fi' ? g.text.includes('3 hlö') : g.text.includes('3 guests'), `${locale}: yleisellä vuorolla henkilömäärä`);
  }
});
const rowsFor = (o) => Object.entries(o).flatMap(([k, v]) => ['fi', 'en'].map((l) => ({ key: k, lang: l, text: v[l] })));
test('sähköpostit: DB-teksti näkyy viestissä (teksti, HTML escapattuna, aihe, yritysnimi asetuksesta)', { skip }, () => {
  const d = emailCases().find((c) => c.name === 'order_confirmation.fi').data;
  const t = ST.makeT(TPL.EMAIL_TEXTS, [
    { key: 'email.order_confirmation.intro', lang: 'fi', text: 'Kiitos & tervetuloa <3 {{var:no}}?'.replace('{{var:no}}?', '') },
    { key: 'email.order_confirmation.subject', lang: 'fi', text: 'Vahvistus {{var:no}} / {{setting:business_name}}' },
  ], { business_name: 'Uusi Nimi' }, () => {});
  const m = TPL.render('order_confirmation', d, 'fi', t);
  assert.equal(m.subject, 'Vahvistus 15321 / Uusi Nimi');
  assert.ok(m.text.includes('Kiitos & tervetuloa <3') && m.html.includes('Kiitos &amp; tervetuloa &lt;3') && !m.html.includes('<3'));
  const en = TPL.render('order_confirmation', { ...d, locale: 'en' }, 'en', t);
  assert.equal(en.subject, 'Order confirmation 15321 – Uusi Nimi', 'EN-riviä ei ole → repon oletus; yritysnimi asetuksesta');
});
test('sähköpostit: rikkinäinen DB-rivi (tuntematon paikkamerkki/muuttuja) → repon oletus, viesti lähtee (ei raakaa {{…}})', { skip }, () => {
  const warns = [];
  const rows = [{ key: 'email.common.contact', lang: 'fi', text: 'Soita {{var:eiole}}' }, { key: 'email.order_change.message', lang: 'fi', text: 'Hinta {{price:7}}' }, { key: 'email.order_change.title', lang: 'fi', text: 'Rikki {{var:no' }];
  const t = ST.makeT(TPL.EMAIL_TEXTS, rows, null, (w) => warns.push(w));
  const c = emailCases().find((x) => x.name === 'order_change.fi'); const m = TPL.render(c.kind, c.data, c.locale, t);
  const g = TPL.render(c.kind, c.data, c.locale);
  assert.deepEqual(m, g); assert.ok(!/\{\{|\}\}/.test(m.subject + m.text + m.html)); assert.equal(warns.length, 3);
});
test('sähköpostit: asiakkaan nimi/tiedot eivät voi rikkoa paikkamerkkejä ({{…}} nimessä)', { skip }, () => {
  const d = structuredClone(emailCases().find((c) => c.name === 'order_confirmation.fi').data); d.to_name = '{{var:no}} {{x}}';
  const m = TPL.render('order_confirmation', d, 'fi', ST.makeT(TPL.EMAIL_TEXTS, rowsAsDb(PENDING.filter((r) => r.key.startsWith('email.')))));
  assert.ok(m.text.includes('Hei {{var:no}},'));
});
test('send-emails/index.ts: tekstit haetaan vain kun on lähetettävää, anon-avaimella; lähetystila ennallaan (dry_run)', { skip }, () => {
  const s = rd('booking/supabase/functions/send-emails/index.ts');
  assert.match(s, /rows\.length \? await fetchSiteTexts\(\{ url, anonKey: Deno\.env\.get\("SUPABASE_ANON_KEY"\), prefixes: \["email\."\] \}\) : null/);
  assert.match(s, /render\(r\.kind as Kind, r, r\.locale, t\)/);
  assert.match(s, /if \(mode !== "live"\) \{ await bk\.rpc\("email_outbox_mark", \{ p_id: r\.id, p_result: "dry_run"/);
  assert.match(s, /const mode: string = cfg\.data\?\.mode \?\? "off";/);
});
test('ei kovakoodattuja kielivalintoja tekstille (en ? "…" : "…") sähköposti-, PDF- ja maksusivukoodissa', { skip }, () => {
  for (const f of ['booking/supabase/functions/send-emails/templates.ts', 'booking/supabase/functions/gift-card-pdf/render.ts', 'booking/supabase/functions/receipt-pdf/render.ts', 'booking/supabase/functions/mobilepay-start/handler.ts']) {
    const bad = rd(f).split('\n').filter((l) => /\ben \? [`"][^`"]*[A-Za-zÄÖäö]{3}/.test(l) && !/en \? "en" : "fi"|new Intl|en \? `€|en \? s :|en \? g\.deliver|en \? o\.name_en|en \? it\.label_en|en \? d\.package|en \? g\?\./.test(l));
    assert.deepEqual(bad.map((l) => l.trim().slice(0, 100)), [], `${f}: kovakoodattu kielivalinta`);
  }
});

// ---------- build ja kauppa ----------
test('staattisen sivuston build ei kaadu uusista riveistä; kaupan datakuormassa ei email.*- eikä mobilepay-virhesivun rivejä', { skip }, async () => {
  const f = join(work, 'fx.json'); const base = J('tests/fixtures/site-texts/rpc.json');
  writeFileSync(f, JSON.stringify({ ...base, texts: [...base.texts, ...PENDING.map((r) => ({ key: r.key, lang: r.lang, text: r.text, version: 1, placeholders: r.placeholders }))] }));
  const state = await B.loadSiteTexts({ env: { SITE_TEXTS_FIXTURE: f }, log: { warn() {}, log() {} }, cacheDir: join(work, 'cache') });
  assert.ok(state.rows.some((r) => r.key === 'email.common.hello'));
  const p = B.shopPayload(state);
  assert.ok(p.texts.every((r) => !r.key.startsWith('email.') && !r.key.startsWith('ui.mobilepay.start_error_')));
  // tuntematon paikkamerkki uudessa rivissä kaataa buildin (§18.3)
  writeFileSync(f, JSON.stringify({ ...base, texts: [...base.texts, { key: 'email.x.y', lang: 'fi', text: 'A {{price:99999}}', version: 1, placeholders: ['{{price:99999}}'] }] }));
  await assert.rejects(B.loadSiteTexts({ env: { SITE_TEXTS_FIXTURE: f }, log: { warn() {}, log() {} }, cacheDir: join(work, 'cache2') }), /PAIKKAMERKKIVIRHE/);
});
test('mobilepay-start: virhesivun tekstit ovat taulukossa; kaikki viestit tulevat texts.ts:stä', { skip }, () => {
  const h = rd('booking/supabase/functions/mobilepay-start/handler.ts');
  for (const k of Object.keys(FT.FUNCTION_TABLES.find((t) => t[0].startsWith('mobilepay-start'))[1])) assert.ok(h.includes(k), `${k} ei käytössä handler.ts:ssä`);
  assert.ok(!/message: "[A-ZÄÖ]/.test(h) && !/, "[A-ZÄÖ][^"]*\)\)?;?$/m.test(h.split('fail(')[0] ?? ''), 'ei kovakoodattua message-tekstiä');
});
