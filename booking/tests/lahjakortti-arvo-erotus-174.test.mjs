// booking_174: kumppanilahjakortin arvo käsin ennen hyväksyntää + erotus maksulinkkinä; kuitti vain kirjanpitoon (ei kuittisähköpostia).
// Logiikka (sentit, säännöt kuten palvelimella), vahvistuksen piirto ja RPC-argumentit, kokeilutila, tekstit (pending-import-69), CSS-värit, migraatio + rollback rakenteena.
// Ei verkkoa eikä tietokantaa. SQL-puoli: supabase/tests/giftcards/t174_partner_receipt_no_email.sql.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const rd = (p) => readFileSync(join(here, '..', p), 'utf8');

class Text { constructor(t) { this.nodeType = 3; this.data = String(t); } get textContent() { return this.data; } }
class El {
  constructor(tag) { this.nodeType = 1; this.tagName = tag.toUpperCase(); this.children = []; this.attrs = {}; this.listeners = {}; this.hidden = false; this.className = ''; this.dataset = {}; this.value = '';
    this.classList = { toggle() {}, add() {}, remove() {}, contains: () => false }; }
  append(...k) { for (const x of k) this.children.push(x && x.nodeType ? x : new Text(x)); }   // kuten selain: null → "null"
  replaceChildren(...k) { this.children = []; this.append(...k); }
  setAttribute(k, v) { this.attrs[k] = String(v); if (k === 'hidden') this.hidden = true; }
  getAttribute(k) { return this.attrs[k] ?? null; }
  addEventListener(t, f) { (this.listeners[t] ||= []).push(f); }
  click() { for (const f of this.listeners.click || []) f({ target: this, preventDefault() {} }); }
  set textContent(v) { this.children = [new Text(v)]; }
  get textContent() { return this.children.map((c) => c.textContent).join(''); }
  focus() {}
  all() { return this.children.flatMap((c) => (c.nodeType === 1 ? [c, ...c.all()] : [])); }
  q(id) { return this.all().find((e) => e.attrs['data-testid'] === id) || null; }
}
globalThis.document = { createElement: (t) => new El(t), createElementNS: (_, t) => new El(t), createTextNode: (t) => new Text(t), body: new El('body'), getElementById: () => null };

const L = await import('../admin/voucher-redeem-logic.js');
const { VCR_TEXTS, vcrText } = await import('../admin/voucher-redeem-texts.js');
const { claimRow } = await import('../admin/views/voucher-redeem.js');
const { createAdminMock } = await import('../admin/options-mock.js');
const tick = () => new Promise((r) => setTimeout(r, 0));
const typeIn = (inp, v) => { inp.value = v; for (const f of inp.listeners.input || []) f({ target: inp }); };
const row = (o = {}) => ({ id: 3, reservation_id: 41, status: 'open', code: 'KK534536G5', source: 'kokemuskauppa', source_label: 'Kokemuskauppa', payment_method: 'partner_voucher_kokemuskauppa',
  payment_method_label: 'Lahjakortti – Kokemuskauppa', redeem_url: 'https://partner.kokemuskauppa.com/p/login', order_id: 5, order_no: 7002, unpaid: 80, voucher_value: null, can_change_source: true, can_redeem: true, ...o });

test('voucherValueCheck: sentit, pilkku/piste, > 0, enintään 2 desimaalia, ≤ maksettava; erotus', () => {
  assert.deepEqual(L.voucherValueCheck('50', 80), { ok: true, value: 50, difference: 30, partial: true });
  assert.deepEqual(L.voucherValueCheck('50,10', 80), { ok: true, value: 50.1, difference: 29.9, partial: true });
  assert.deepEqual(L.voucherValueCheck(' 80.00 € ', 80), { ok: true, value: 80, difference: 0, partial: false });
  assert.deepEqual(L.voucherValueCheck('0,1', 0.3), { ok: true, value: 0.1, difference: 0.2, partial: true }, 'ei liukulukuvirhettä');
  for (const bad of ['0', '0,00', '-5', '', 'abc', '10,005', '1e3', null]) assert.equal(L.voucherValueCheck(bad, 80).error, 'invalid_amount', String(bad));
  assert.equal(L.voucherValueCheck('80,01', 80).error, 'voucher_exceeds_total');
  assert.equal(L.voucherValueDefault(80), '80,00'); assert.equal(L.voucherValueDefault(12.5), '12,50'); assert.equal(L.voucherValueDefault(null), '');
  const r = row();
  assert.deepEqual(L.markArgsWithValue(r, L.voucherValueCheck('80,00', 80), 80), { p_id: 3 }, 'täysi arvo → kuten ennen (ei p_amount)');
  assert.deepEqual(L.markArgsWithValue(r, L.voucherValueCheck('50', 80), 80), { p_id: 3, p_amount: 50 });
});

test('vahvistus: arvokenttä (oletus maksettava), erotuksen huomautus, virheet estävät hyväksynnän, osittainen → p_amount ja maksulinkkitoasti', async () => {
  const calls = [];
  const rpc = async (n, a) => { calls.push([n, a]); return { ok: true, already: false, amount: a.p_amount ?? 80, payment_method_label: 'Lahjakortti – Kokemuskauppa', voucher_value: a.p_amount ?? 80, due: 80,
    difference: a.p_amount ? 80 - a.p_amount : null, payment_link: a.p_amount ? { payment_id: 9, amount: 80 - a.p_amount, link_path: '/maksa/?p=x' } : null, email_queued: !!a.p_amount }; };
  const el = claimRow(row(), { rpc, canManage: true });
  el.q('vcr-mark').click();
  const inp = el.q('vcr-value');
  assert.ok(inp); assert.equal(inp.value, '80,00'); assert.equal(inp.attrs.inputmode, 'decimal');
  assert.match(el.q('vcr-diff').textContent, /kattaa koko summan 80,00/);
  assert.match(el.q('vcr-ask').textContent, /Kuitti tehdään kirjanpitoon, asiakkaalle ei lähetetä kuittia/);
  typeIn(inp, '0'); assert.equal(el.q('vcr-mark-yes').disabled, true); assert.match(el.q('vcr-value-err').textContent, /yli 0 €/); assert.equal(el.q('vcr-value-err').hidden, false);
  typeIn(inp, '80,01'); assert.equal(el.q('vcr-mark-yes').disabled, true); assert.match(el.q('vcr-value-err').textContent, /ei voi olla suurempi/);
  typeIn(inp, '50'); assert.equal(el.q('vcr-mark-yes').disabled, false); assert.equal(el.q('vcr-value-err').hidden, true);
  assert.match(el.q('vcr-diff').textContent, /Lahjakortti 50,00\s€, varauksen summa 80,00\s€\. Erotus 30,00\s€ lähetetään asiakkaalle maksulinkkinä/);
  assert.match(el.q('vcr-ask').textContent, /Kirjataan maksu 50,00\s€/);
  assert.equal(calls.length, 0);
  el.q('vcr-mark-yes').click(); await tick();
  assert.deepEqual(calls, [['admin_mark_voucher_claim_redeemed', { p_id: 3, p_amount: 50 }]]);
  assert.doesNotMatch(el.textContent, /null|undefined|NaN/);
  // täysi arvo → ei p_amount (sama kutsu kuin booking_173)
  const calls2 = []; const el2 = claimRow(row(), { rpc: async (n, a) => { calls2.push([n, a]); return { ok: true, amount: 80 }; }, canManage: true });
  el2.q('vcr-mark').click(); el2.q('vcr-mark-yes').click(); await tick();
  assert.deepEqual(calls2, [['admin_mark_voucher_claim_redeemed', { p_id: 3 }]]);
  // maksamaton summa tuntematon → ei kenttää, vanha vahvistus
  const el3 = claimRow(row({ unpaid: 0, voucher_value: 40 }), { rpc, canManage: true }); el3.q('vcr-mark').click();
  assert.equal(el3.q('vcr-value'), null); assert.match(el3.q('vcr-ask').textContent, /40,00/);
});

test('kokeilutila: osittainen arvo → maksulinkki + sähköposti, täysi → ei linkkiä, virheet koodeilla', async () => {
  const m = createAdminMock();
  const u = await m.rpc('admin_unredeemed_voucher_claims', {});
  const [a, b, c] = u.claims;
  await assert.rejects(m.rpc('admin_mark_voucher_claim_redeemed', { p_id: a.id, p_amount: 0 }), (e) => e.code === 'invalid_amount');
  await assert.rejects(m.rpc('admin_mark_voucher_claim_redeemed', { p_id: a.id, p_amount: a.unpaid + 0.01 }), (e) => e.code === 'voucher_exceeds_total');
  const part = Math.round((a.unpaid - 10) * 100) / 100;
  const r1 = await m.rpc('admin_mark_voucher_claim_redeemed', { p_id: a.id, p_amount: part });
  assert.equal(r1.amount, part); assert.equal(r1.difference, 10); assert.equal(r1.payment_link.amount, 10); assert.equal(r1.email_queued, true); assert.match(r1.payment_link.link_path, /^\/maksa\/\?p=/);
  const r2 = await m.rpc('admin_mark_voucher_claim_redeemed', { p_id: b.id, p_amount: b.unpaid });
  assert.equal(r2.payment_link, null); assert.equal(r2.email_queued, false);
  const r3 = await m.rpc('admin_mark_voucher_claim_redeemed', { p_id: c.id });
  assert.equal(r3.payment_link, null); assert.equal(r3.amount, c.unpaid);
});

test('tekstit: uudet ui.admin.vcr.* ja email.payment_link.voucher_* FI+EN pending-import-69:ssä samoina kuin koodissa; ei <, ei emojeja, ei linkkejä; avaimet uusia', async () => {
  const { EMAIL_TEXTS } = await import('../supabase/functions/send-emails/texts.ts').catch(() => ({ EMAIL_TEXTS: null }));
  const rows = JSON.parse(rd('../content/site-texts.pending-import-69.json'));
  assert.equal(new Set(rows.map((r) => `${r.key}|${r.lang}`)).size, rows.length);
  const keys = [...new Set(rows.map((r) => r.key))];
  for (const k of keys) for (const l of ['fi', 'en']) {
    const r = rows.find((x) => x.key === k && x.lang === l); assert.ok(r, `${k} ${l}`);
    const code = k.startsWith('ui.admin.vcr.') ? VCR_TEXTS[l][k] : EMAIL_TEXTS?.[k]?.[l];
    if (k.startsWith('ui.') || EMAIL_TEXTS) assert.equal(r.text, code, `${k} ${l}`);
    assert.deepEqual([...r.placeholders].sort(), [...new Set(r.text.match(/\{\{[^{}]+\}\}/g) || [])].sort(), k);
    assert.ok(!r.text.includes('<')); assert.doesNotMatch(r.text, /\p{Extended_Pictographic}|https?:\/\//u); assert.ok(r.max_len >= r.text.length); assert.equal(r.class, 'normal');
  }
  for (const k of ['email.payment_link.voucher_subject', 'email.payment_link.voucher_intro', 'email.payment_link.voucher_amount_label']) assert.ok(keys.includes(k));
  assert.match(rows.find((r) => r.key === 'email.payment_link.voucher_intro' && r.lang === 'fi').text, /\{\{var:total\}\}.*\{\{var:voucher\}\}.*\{\{var:difference\}\}/);
  for (const k of keys.filter((x) => x.startsWith('ui.'))) assert.ok(VCR_TEXTS.fi[k] && VCR_TEXTS.en[k], k);
  const others = readdirSync(join(here, '../../content')).filter((f) => /^site-texts\.(pending-import|imported).*\.json$/.test(f) && f !== 'site-texts.pending-import-69.json');
  for (const f of others) { const rs = JSON.parse(rd(`../content/${f}`)); if (!Array.isArray(rs)) continue; for (const r of rs) assert.ok(!keys.includes(r?.key), `${r?.key} on jo tiedostossa ${f}`); }
  assert.equal(vcrText('ui.admin.vcr.value_partial', { value: '50,00 €', due: '80,00 €', difference: '30,00 €' }, 'en'), 'Gift card 50,00 €, booking total 80,00 €. The difference of 30,00 € is sent to the customer as a payment link by email.');
});

test('CSS ja näkymä: vain teeman muuttujat (ei sinistä, ei heksoja), ei emojeja, kapea näyttö ei vieritä sivuttain; teeman värit #2B3A30 / #F4EFE7 / #7A5530 ja kontrasti ≥ 4.5:1', () => {
  const css = rd('admin/admin.css');
  const block = css.slice(css.indexOf('/* booking_174')).replace(/\/\*[\s\S]*?\*\//g, '');
  assert.ok(block.includes('.vcr-value') && block.includes('.vcr-diff'));
  assert.doesNotMatch(block, /#[0-9a-f]{3,8}\b|rgb\(|hsl\(|blue/i);
  assert.doesNotMatch(block, /width:\s*\d{3,}px|min-width:\s*\d{3,}px|white-space:\s*nowrap/);
  const root = css.slice(0, css.indexOf('}'));
  for (const [v, hex] of [['green', '#2B3A30'], ['bg', '#F4EFE7'], ['gold', '#7A5530']]) assert.match(root, new RegExp(`--${v}:${hex}`));
  const lum = (hx) => { const c = hx.match(/\w\w/g).map((x) => parseInt(x, 16) / 255).map((x) => (x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4)); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
  const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
  const val = (v) => { const x = root.match(new RegExp(`--${v}:#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})\\b`))[1]; return x.length === 3 ? x.replace(/./g, '$&$&') : x; };
  for (const [fg, bg] of [['ink', 'card'], ['ink', 'bg'], ['err', 'bg'], ['err', 'card'], ['muted', 'bg'], ['gold', 'bg'], ['card', 'green']]) assert.ok(ratio(val(fg), val(bg)) >= 4.5, `${fg}/${bg} ${ratio(val(fg), val(bg)).toFixed(2)}`);
  const v = rd('admin/views/voucher-redeem.js');
  assert.doesNotMatch(v, /\p{Extended_Pictographic}/u);
  assert.match(v, /voucherValueCheck\(input\.value, due\)/); assert.match(v, /markArgsWithValue\(row, check, due\)/);
});

test('migraatio + rollback: vartijat, kuittisähköposti pois kumppanimaksulta, erotus maksulinkkinä olemassa olevalla mekanismilla; rollback palauttaa tuotannon md5:t', () => {
  const mig = rd('supabase/migrations/20261024234000_booking_174_partner_receipt_no_email.sql');
  const rb = rd('supabase/rollbacks/20261024234000_booking_174_ROLLBACK.sql');
  for (const md of ['86338dfa031158ffc12b0e7025f0a68f', 'e14d131d428518ec88581fd3e473af90', '4620f0d7531b524a6a5cfa322fc0e7a7', '4796edc6ebadaf599fd78287a75d29e8']) assert.ok(mig.includes(md), md);
  assert.match(mig, /if booking\._is_partner_method\(v_method\) then return; end if;\s*perform booking\._enqueue_email\('receipt'/);
  assert.match(mig, /booking\._create_link_payment\(o\.id, 14,/); assert.match(mig, /_enqueue_email\('payment_link'/); assert.match(mig, /'variant', 'voucher_difference'/);
  assert.match(mig, /_err\('voucher_exceeds_total'/); assert.match(mig, /_err\('invalid_amount'/);
  assert.doesNotMatch(mig, /\bpublic\.|^\s*\\/m); assert.doesNotMatch(mig, /procountor.*(live|daily_enabled\s*=\s*true)/i);
  for (const md of ['86338dfa031158ffc12b0e7025f0a68f', 'e14d131d428518ec88581fd3e473af90', '4620f0d7531b524a6a5cfa322fc0e7a7']) assert.ok(rb.includes(md), md);
  assert.match(rb, /drop function if exists booking\._vc_due/);
  const t = rd('supabase/tests/giftcards/t174_partner_receipt_no_email.sql');
  assert.doesNotMatch(t, /^\s*\\/m, 'ei psql-metakomentoja'); assert.match(t, /^begin;/m); assert.match(t, /^rollback;/m); assert.match(t, /returning id into/);
});
