// booking_173: kumppanilahjakorttien lunastus hallinnassa – logiikka, kokeilutilan rajapinta, rivin piirto (ei "null"/"undefined"), tekstit ja kytkennät.
// Ei verkkoa eikä tietokantaa. SQL-puoli: supabase/tests/giftcards/t173_voucher_sellers.sql.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
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
const { voucherRedeemMockHandlers, VCR_MOCK_URLS, guessSource } = await import('../admin/voucher-redeem-mock.js');
const { claimRow } = await import('../admin/views/voucher-redeem.js');
const { createAdminMock } = await import('../admin/options-mock.js');

const row = (o = {}) => ({ id: 1, reservation_id: 41, status: 'open', code: 'KK534536G5', code_masked: '…36G5', source: 'kokemuskauppa', source_label: 'Kokemuskauppa', source_suggested: 'kokemuskauppa', source_suggested_label: 'Kokemuskauppa',
  suggestion_confidence: 'high', payment_method: 'partner_voucher_kokemuskauppa', payment_method_label: 'Lahjakortti – Kokemuskauppa', redeem_url: VCR_MOCK_URLS.kokemuskauppa, order_id: 5, order_no: 7002,
  starts_at: '2026-10-25T16:00:00Z', product_name: 'Savusauna', customer_name: 'Testi Asiakas', unpaid: 85, voucher_value: null, can_change_source: true, can_redeem: true, ...o });

test('logiikka: myyjät, linkit, ristiriita vain varmalla/todennäköisellä arvauksella, ryhmittely ja suodatinnapit', () => {
  assert.deepEqual(L.VCR_SELLERS, ['kokemuskauppa', 'offerilla', 'elamyslahjat']);
  assert.ok(!L.VCR_CHOICES.includes('kiitoskauppa'), 'Kiitoskauppa ei valinnoissa');
  assert.equal(L.sellerLabel('kiitoskauppa'), 'Kiitoskauppa', 'vanha rivi näkyy nimellä');
  assert.equal(L.sellerLabel(null), '–'); assert.equal(L.sellerLabel(undefined, null), '–');
  for (const u of Object.values(VCR_MOCK_URLS)) assert.equal(L.safeRedeemUrl(u), u);
  for (const bad of ['http://x.fi', 'javascript:alert(1)', 'https://x.fi/"><b', '', null, `https://x.fi/${'a'.repeat(300)}`]) assert.equal(L.safeRedeemUrl(bad), null, String(bad));
  assert.deepEqual(L.checkRedeemUrls({ kokemuskauppa: ' https://a.fi/p ', offerilla: '', elamyslahjat: 'ftp://x' }), { ok: false, bad: ['elamyslahjat'] });
  assert.deepEqual(L.checkRedeemUrls({ kokemuskauppa: 'https://a.fi/p' }), { ok: true, value: { kokemuskauppa: 'https://a.fi/p', offerilla: '', elamyslahjat: '' } });
  assert.equal(L.guessDiffers(row({ source: 'offerilla' })), true);
  assert.equal(L.guessDiffers(row({ source: 'kokemuskauppa', source_suggested: 'offerilla', suggestion_confidence: 'low' })), false, 'pelkkä Offerilla-ehdotus ei ole ristiriita');
  assert.equal(L.guessDiffers(row({ source: 'partner_other' })), false);
  const g = L.groupBySource([row({ id: 1, source: 'offerilla' }), row({ id: 2 }), row({ id: 3, source: 'kiitoskauppa' }), row({ id: 4, source: 'offerilla' })]);
  assert.deepEqual(g.map((x) => [x.source, x.claims.map((c) => c.id)]), [['kokemuskauppa', [2]], ['offerilla', [1, 4]], ['kiitoskauppa', [3]]]);
  const chips = L.filterChips({ offerilla: 2, kiitoskauppa: 1 }, 'offerilla');
  assert.deepEqual(chips.map((c) => [c.source, c.n, c.active]), [[null, 3, false], ['kokemuskauppa', 0, false], ['offerilla', 2, true], ['elamyslahjat', 0, false], ['kiitoskauppa', 1, false]]);
  assert.equal(L.orderHref(7002), '#/tilaukset?order=7002');
  assert.equal(L.reservationHref({ reservation_id: 41, starts_at: '2026-10-25T16:00:00Z' }), '#/tilaukset?tab=reservations&id=41');
  assert.equal(L.reservationHref({ starts_at: '2026-10-25T22:30:00Z' }), '#/?d=2026-10-26', 'ilman id:tä päivä Helsingin ajassa'); assert.equal(L.orderHref(null), null);
  assert.deepEqual(L.markArgs(row(), { amount: '12.5', ref: ' R1 ', note: '' }), { p_id: 1, p_amount: 12.5, p_partner_ref: 'R1' });
  assert.deepEqual(L.setSourceArgs(row(), 'offerilla'), { p_id: 1, p_source: 'offerilla' });
});

test('kokeilutila vastaa palvelimen muotoa: KK534536G5 → Kokemuskauppa, myyjän vaihto, idempotentti lunastusmerkintä, URL-asetus', async () => {
  assert.deepEqual(guessSource('kk534536g5'), { source: 'kokemuskauppa', confidence: 'high' });
  assert.deepEqual(guessSource(' KK-534 536 G5 '), { source: 'kokemuskauppa', confidence: 'high' });
  assert.deepEqual(guessSource('ZZ1'), { source: 'offerilla', confidence: 'low' });
  const m = createAdminMock();
  const u = await m.rpc('admin_unredeemed_voucher_claims', {});
  assert.equal(u.ok, true); assert.equal(u.can_manage, true); assert.equal(u.total, u.claims.length); assert.ok(u.total >= 3);
  assert.deepEqual(u.redeem_urls, VCR_MOCK_URLS);
  const kk = u.claims.find((c) => c.code === 'KK534536G5');
  assert.equal(kk.source_suggested, 'kokemuskauppa'); assert.equal(kk.suggestion_confidence, 'high'); assert.equal(kk.payment_method_label, 'Lahjakortti – Kokemuskauppa');
  assert.equal(kk.redeem_url, VCR_MOCK_URLS.kokemuskauppa);
  const only = await m.rpc('admin_unredeemed_voucher_claims', { p_source: 'offerilla' });
  assert.ok(only.claims.length && only.claims.every((c) => c.source === 'offerilla')); assert.equal(only.total, u.total, 'laskurit koko joukosta');
  await assert.rejects(m.rpc('admin_unredeemed_voucher_claims', { p_source: 'xx' }), (e) => e.code === 'invalid_source');
  const ch = await m.rpc('admin_set_voucher_claim_source', { p_id: kk.id, p_source: 'offerilla' });
  assert.equal(ch.payment_method, 'partner_voucher_offerilla');
  await assert.rejects(m.rpc('admin_set_voucher_claim_source', { p_id: kk.id, p_source: 'offerilla' }), (e) => e.code === 'unchanged');
  await assert.rejects(m.rpc('admin_set_voucher_claim_source', { p_id: kk.id, p_source: 'kiitoskauppa' }), (e) => e.code === 'invalid_source');
  const r1 = await m.rpc('admin_mark_voucher_claim_redeemed', { p_id: kk.id });
  assert.equal(r1.already, false); assert.equal(r1.redeemed_via, 'staff'); assert.equal(r1.payment_method_label, 'Lahjakortti – Offerilla');
  const r2 = await m.rpc('admin_mark_voucher_claim_redeemed', { p_id: kk.id });
  assert.equal(r2.already, true); assert.equal(r2.payment_id, r1.payment_id, 'idempotentti');
  await assert.rejects(m.rpc('admin_set_voucher_claim_source', { p_id: kk.id, p_source: 'kokemuskauppa' }), (e) => e.code === 'invalid_state');
  const o = await m.rpc('admin_order_voucher_claims', { p_order_id: kk.order_id });
  assert.equal(o.claims[0].status, 'redeemed');
  assert.equal((await m.rpc('admin_unredeemed_voucher_claims', {})).total, u.total - 1);
  await assert.rejects(m.rpc('admin_set_voucher_redeem_urls', { p: { kokemuskauppa: 'http://x.fi' } }), (e) => e.code === 'invalid_url');
  await assert.rejects(m.rpc('admin_set_voucher_redeem_urls', { p: { kiitoskauppa: 'https://x.fi' } }), (e) => e.code === 'invalid_setting');
  const s = await m.rpc('admin_set_voucher_redeem_urls', { p: { offerilla: 'https://offerilla.com/uusi/', elamyslahjat: '' } });
  assert.deepEqual(s.redeem_urls, { kokemuskauppa: VCR_MOCK_URLS.kokemuskauppa, offerilla: 'https://offerilla.com/uusi/' });
  const st = createAdminMock({ perms: ['bookings.view'] });
  await assert.rejects(st.rpc('admin_mark_voucher_claim_redeemed', { p_id: 900 }), (e) => e.code === 'forbidden');
  assert.equal((await st.rpc('admin_unredeemed_voucher_claims', {})).can_manage, false);
  void voucherRedeemMockHandlers;
});

test('rivi: koodi + Kopioi, arvaus ja valinta nimettyinä, Lunasta uuteen välilehteen, kaksivaiheinen merkintä; ei "null"/"undefined"', async () => {
  const calls = [];
  const rpc = async (n, a) => { calls.push([n, a]); return { ok: true, already: false, amount: 85, payment_method_label: 'Lahjakortti – Kokemuskauppa' }; };
  let changed = 0;
  const el = claimRow(row(), { rpc, canManage: true, onChanged: () => { changed++; } });
  const txt = el.textContent;
  assert.doesNotMatch(txt, /null|undefined|NaN|\{\{/);
  assert.equal(el.q('vcr-code').textContent, 'KK534536G5');
  assert.ok(el.q('vcr-copy'));
  assert.match(el.q('vcr-guess').textContent, /Järjestelmän arvaus: Kokemuskauppa · varma/);
  assert.match(el.q('vcr-choice').textContent, /Asiakkaan valinta:/);
  assert.equal(el.q('vcr-source').value, 'kokemuskauppa');
  assert.match(el.q('vcr-method').textContent, /Maksutapa: Lahjakortti – Kokemuskauppa/);
  const a = el.q('vcr-redeem');
  assert.equal(a.tagName, 'A'); assert.equal(a.attrs.target, '_blank'); assert.match(a.attrs.rel, /noopener/); assert.equal(a.attrs.href, VCR_MOCK_URLS.kokemuskauppa);
  assert.equal(el.q('vcr-order-link').attrs.href, '#/tilaukset?order=7002');
  assert.equal(el.q('vcr-differs'), null);
  assert.equal(el.q('vcr-res-link').attrs.href, '#/tilaukset?tab=reservations&id=41');
  el.q('vcr-mark').click();
  assert.equal(calls.length, 0, 'ensimmäinen painallus vain kysyy');
  assert.match(el.q('vcr-confirm').textContent, /Lahjakortti – Kokemuskauppa/);
  el.q('vcr-mark-yes').click();
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(calls, [['admin_mark_voucher_claim_redeemed', { p_id: 1 }]]); assert.equal(changed, 1);
  // ristiriita + ei URL:ia + ei arvausta + ei oikeutta
  const b = claimRow(row({ source: 'offerilla', redeem_url: null, payment_method_label: null }), { rpc, canManage: false });
  assert.ok(b.q('vcr-differs')); assert.ok(b.q('vcr-no-url')); assert.equal(b.q('vcr-mark'), null); assert.equal(b.q('vcr-source'), null);
  assert.doesNotMatch(b.textContent, /null|undefined/);
  const c = claimRow(row({ code: null, source_suggested: null, source_suggested_label: null, suggestion_confidence: null, order_no: null, starts_at: null, product_name: null, customer_name: null, unpaid: null }), { rpc, canManage: true });
  assert.doesNotMatch(c.textContent, /null|undefined|NaN/); assert.match(c.q('vcr-guess').textContent, /ei arvausta/); assert.equal(c.q('vcr-code').textContent, '…36G5');
  // vanha Kiitoskauppa-rivi: näkyy nimellä, valittavissa vain nykyisenä
  const k = claimRow(row({ source: 'kiitoskauppa', source_label: 'Kiitoskauppa', code: 'ZXQW98765432', source_suggested: 'elamyslahjat', suggestion_confidence: 'medium' }), { rpc, canManage: true });
  const opts = k.q('vcr-source').children.map((o) => o.attrs.value ?? o.value);
  assert.deepEqual(opts, ['kokemuskauppa', 'offerilla', 'elamyslahjat', 'partner_other', 'kiitoskauppa']);
  // lunastettu: ei toimintoja, merkki
  const d = claimRow(row({ status: 'redeemed', resolved_by: 'bot', redeemed_via: 'bot', resolved_at: '2026-10-25T10:00:00Z' }), { rpc, canManage: true });
  assert.equal(d.q('vcr-mark'), null); assert.equal(d.q('vcr-redeem'), null); assert.match(d.textContent, /Lunastettu .*\(botti\)/);
});

test('tekstit: FI = EN avaimet, pending-import-68 (+ 69, booking_174) täsmää, ei <-merkkiä, ei emojeja, ei sinistä', () => {
  assert.deepEqual(Object.keys(VCR_TEXTS.fi).sort(), Object.keys(VCR_TEXTS.en).sort());
  const rows = [...JSON.parse(rd('../content/site-texts.pending-import-68.json')), ...JSON.parse(rd('../content/site-texts.pending-import-69.json')).filter((r) => r.key.startsWith('ui.admin.vcr.'))];   // booking_174: arvo käsin
  assert.equal(new Set(rows.map((r) => `${r.key}|${r.lang}`)).size, rows.length);
  for (const lang of ['fi', 'en']) for (const [k, v] of Object.entries(VCR_TEXTS[lang])) {
    const r = rows.find((x) => x.key === k && x.lang === lang); assert.ok(r, `${k} ${lang}`); assert.equal(r.text, v);
    assert.deepEqual(r.placeholders.sort(), [...new Set(v.match(/\{\{[^{}]+\}\}/g) || [])].sort(), k);
  }
  for (const r of rows) { assert.ok(!r.text.includes('<'), r.key); assert.doesNotMatch(r.text, /\p{Extended_Pictographic}|https?:\/\//u, r.key); assert.ok(r.max_len >= r.text.length); assert.equal(r.class, 'normal'); }
  assert.equal(vcrText('ui.admin.vcr.redeem', { source: 'Offerilla' }, 'en'), 'Redeem (Offerilla)');
  assert.equal(vcrText('ui.admin.vcr.redeem', {}, 'fi'), 'Lunasta ()', 'puuttuva muuttuja → tyhjä, ei "undefined"');
  const css = rd('admin/admin.css'); const block = css.slice(css.indexOf('/* booking_173')).replace(/\/\*[\s\S]*?\*\//g, '');
  assert.ok(block.length > 300); assert.doesNotMatch(block, /#[0-9a-f]{3,8}\b|rgb\(|hsl\(|blue/i);
  assert.doesNotMatch(rd('admin/views/voucher-redeem.js'), /\p{Extended_Pictographic}/u);
});

test('kytkennät: Tarkista-osio, tilauksen ikkuna, Talous-tilaus, Procountor-tilit myyjittäin, Lunastussivut-asetus, build-lista', () => {
  assert.match(rd('admin/views/review.js'), /unredeemedSection\(\{ rpc \}\)/);
  assert.match(rd('admin/views/shared.js'), /orderVoucherBox\(\{ rpc, orderId: r\.order_id/);
  assert.match(rd('admin/views/talous-orders.js'), /orderVoucherBox\(\{ rpc, orderId: id/);
  assert.match(rd('admin/views/orders.js'), /createOrdersTab\(\{ api, ctx, gift, rpc \}\)/, 'Tilaukset-näkymä antaa rpc:n');
  const s = rd('admin/views/settings.js');
  for (const k of ['partner_voucher_kokemuskauppa', 'partner_voucher_offerilla', 'partner_voucher_elamyslahjat']) assert.match(s, new RegExp(`\\['${k}', 'method_${k}'\\]`));
  assert.match(s, /\['partner_voucher', 'method_partner_voucher_fallback'\]/, 'vanha yhteinen tili jää varatiliksi');
  assert.match(s, /redeemUrlsCard\(\)/); assert.match(s, /VCR_RPC\.setUrls/);
  assert.match(rd('../scripts/build-pages.mjs'), /'voucher-redeem-logic\.js', 'voucher-redeem-texts\.js', 'voucher-redeem-mock\.js', 'views\/voucher-redeem\.js'/);
  assert.match(rd('admin/views/talous-ui.js'), /'partner_voucher_kokemuskauppa', 'partner_voucher_offerilla', 'partner_voucher_elamyslahjat'/);
});
