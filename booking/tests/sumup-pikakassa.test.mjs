// booking_295: Pikakassan korttipääte (SumUp Solo, Cloud API). Keinotekoinen DOM, ei verkkoa eikä tietokantaa.
// Edge-funktioiden logiikka (checkout-pyyntö, tilakone, webhook, hyvitys) testataan Denolla: supabase/functions/_tests/sumup_test.ts.
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import test from 'node:test';
const href = (rel) => new URL(rel, import.meta.url).href;
const read = (rel) => readFileSync(new URL(rel, import.meta.url), 'utf8');

const domSrc = read('./pikakassa-nakyma.test.mjs');
const start = domSrc.indexOf('function installDom() {');
const end = domSrc.indexOf('\ninstallDom();');
assert.ok(start >= 0 && end > start, 'installDom löytyy');
new Function(`${domSrc.slice(start, end)}\ninstallDom();`)();
globalThis.location = { search: '?mock=1', hash: '', pathname: '/hallinta/' };
globalThis.window = globalThis;
const mem = new Map();
globalThis.localStorage = { getItem: (k) => (mem.has(k) ? mem.get(k) : null), setItem: (k, v) => mem.set(k, String(v)), removeItem: (k) => mem.delete(k) };

const su = await import(href('../admin/sumup-pos.js'));
const { tenderAvailable, posSheetTenders } = await import(href('../admin/pos-logic.js'));
const texts = await import(href('../admin/pos-texts.js'));
const { renderPos } = await import(href('../admin/pos-screen.js'));
const { createAdminMock } = await import(href('../admin/options-mock.js'));
const talous = await import(href('../admin/talous-texts.js'));

function all(node, acc = []) {
  if (node?.nodeType === 1) { acc.push(node); for (const c of node.children || []) all(c, acc); }
  return acc;
}
const q = (node, id) => all(node).find((n) => n.getAttribute('data-testid') === id) || null;
async function flush() { for (let i = 0; i < 15; i++) await new Promise((r) => setTimeout(r, 0)); }
function reset() {
  document.body.replaceChildren();
  document.body.className = ''; document.body.style.overflow = ''; document.body.dataset = {};
  document.documentElement.className = ''; document.documentElement.style.overflow = ''; document.documentElement.dataset = {};
  document.listeners = {}; document.activeElement = document.body;
}

// ---------- näkyvyys: off / test / live ----------
test('suEnabled ja tenderAvailable: off → ei näy lainkaan, test ja live → näkyy', () => {
  const t = { code: 'sumup', handler: 'sumup', channels: ['pos'], active: true };
  for (const m of [undefined, null, {}, { sumup_mode: 'off' }, { sumup_mode: 'dry_run' }, { sumup_mode: 'weird' }]) {
    assert.equal(su.suEnabled(m), false);
    assert.equal(tenderAvailable(t, m), false);
  }
  for (const mode of ['test', 'live']) {
    assert.equal(su.suEnabled({ sumup_mode: mode }), true);
    assert.equal(tenderAvailable(t, { sumup_mode: mode }), true);
  }
  assert.equal(tenderAvailable({ ...t, active: false }, { sumup_mode: 'test' }), false);
  assert.equal(posSheetTenders([t]).length, 1, 'kassan listalle kelpaa');
  assert.equal(tenderAvailable({ code: 'payment_link', handler: 'payment_link', active: true }, { montonio_mode: 'test', sumup_mode: 'off' }), true);
});

test('lukijan muisti: kelvollinen tunnus, oletuslukija, valinta palvelimen listasta, kesken jäänyt maksu vanhenee', () => {
  const s = new Map();
  const st = { getItem: (k) => s.get(k) ?? null, setItem: (k, v) => s.set(k, v), removeItem: (k) => s.delete(k) };
  assert.equal(su.saveReader(st, { reader_id: 'bad id!' }), null);
  assert.deepEqual(su.saveReader(st, { reader_id: 'rdr_0001', name: 'Kassa' }), { reader_id: 'rdr_0001', name: 'Kassa' });
  assert.deepEqual(su.readReader(st), { reader_id: 'rdr_0001', name: 'Kassa' });
  s.set(su.SU_READER_KEY, '{rikki');
  assert.equal(su.readReader(st), null);
  const list = [{ reader_id: 'rdr_0001', name: 'A' }, { reader_id: 'rdr_0002', name: 'B', is_default: true }];
  assert.deepEqual(su.pickReader({ reader_id: 'rdr_0001' }, list), { reader_id: 'rdr_0001', name: 'A' }, 'muistettu voittaa');
  assert.deepEqual(su.pickReader(null, list), { reader_id: 'rdr_0002', name: 'B' }, 'oletus');
  assert.equal(su.pickReader({ reader_id: 'GONE_1' }, [list[0], { ...list[0], reader_id: 'rdr_0003' }]), null, 'poistettu lukija ei kelpaa, useita ilman oletusta');
  assert.deepEqual(su.pickReader(null, [list[0]]), { reader_id: 'rdr_0001', name: 'A' });
  assert.equal(su.pickReader(null, []), null);
  su.savePending(st, { order_id: 5, payment_id: 9 }, 1000);
  assert.deepEqual(su.readPending(st, 1000 + 60000), { order_id: 5, payment_id: 9, at: 1000 });
  assert.equal(su.readPending(st, 1000 + su.SU_PENDING_TTL_MS + 1), null);
  assert.equal(su.savePending(st, { order_id: 'x', payment_id: 9 }), null);
  su.clearPending(st);
  assert.equal(su.readPending(st), null);
});

test('parituskoodi, tilat ja virhekoodit', () => {
  assert.equal(su.normalizePairingCode(' ab cd 1234 '), 'ABCD1234');
  assert.equal(su.validPairingCode('abcd1234'), true);
  for (const bad of ['', 'abc', 'ab-cd-123', '1234567890123', null]) assert.equal(su.validPairingCode(bad), false);
  assert.equal(su.suStateOf({ state: 'paid' }), 'paid');
  assert.equal(su.suStateOf({ state: 'failed' }), 'failed');
  assert.equal(su.suStateOf({ state: 'cancelled' }), 'cancelled');
  assert.equal(su.suStateOf({ state: 'weird' }), 'pending');
  assert.equal(su.suStateOf(null), 'pending');
  assert.equal(su.suErrorKey('reader_offline'), 'su_reader_offline');
  assert.equal(su.suErrorKey('mystery'), 'su_provider_error');
});

// ---------- tekstit ----------
test('tekstit: FI+EN samat avaimet, import 150 = koodin sanakirja, kaikki avaimet käytössä', () => {
  const fi = texts.POS_SUMUP_TEXTS.fi, en = texts.POS_SUMUP_TEXTS.en;
  assert.deepEqual(Object.keys(fi).sort(), Object.keys(en).sort());
  const rows = JSON.parse(read('../../content/site-texts.pending-import-150.json'));
  assert.equal(rows.length, Object.keys(fi).length * 2);
  const seen = new Set();
  for (const r of rows) {
    assert.match(r.key, /^ui\.pos\.(method_sumup|su_[a-z_]+)$/);
    assert.ok(['fi', 'en'].includes(r.lang));
    assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain'); assert.deepEqual(r.placeholders, []);
    const k = r.key.slice('ui.pos.'.length);
    assert.equal(r.text, texts.POS_SUMUP_TEXTS[r.lang][k]);
    assert.equal(texts.posText(k, r.lang), r.text);
    assert.ok(!seen.has(`${r.key}|${r.lang}`)); seen.add(`${r.key}|${r.lang}`);
    assert.ok(!/[<>]/.test(r.text));
  }
  for (const other of ['POS_TEXTS', 'POS_EDIT_TEXTS', 'POS_PAY_TEXTS', 'POS_LINK_TEXTS', 'POS_CUSTOMER_TEXTS', 'POS_CUSTOM_TEXTS', 'POS_CHECKOUTX_TEXTS']) {
    for (const k of Object.keys(fi)) assert.equal(Object.hasOwn(texts[other].fi, k), false, `${other}.${k}`);
  }
  const dir = new URL('../../content/', import.meta.url);
  for (const f of readdirSync(dir).filter((x) => /^site-texts\.pending-import-\d+b?\.json$/.test(x) && x !== 'site-texts.pending-import-150.json' && x !== 'site-texts.pending-import-182.json')) {
    const other = JSON.parse(readFileSync(new URL(f, dir), 'utf8'));
    for (const r of Array.isArray(other) ? other : []) assert.equal(seen.has(`${r.key}|${r.lang}`), false, `${f}: ${r.key}`);
  }
  const src = read('../admin/pos-screen.js') + read('../admin/sumup-pos.js') + read('../admin/views/sumup-settings.js');
  for (const k of Object.keys(fi)) assert.ok(src.includes(`'${k}'`), `käyttämätön avain ${k}`);
  for (const k of ['done', 'failed', 'not_supported', 'retry_later', 'not_configured', 'none', 'off', 'forbidden', 'error']) {
    assert.ok(talous.TEXTS.fi[`refund.su.${k}`] && talous.TEXTS.en[`refund.su.${k}`], `refund.su.${k}`);
  }
});

// ---------- turvallisuus ja tuotannon muuttumattomuus (staattinen) ----------
test('ei salaisuuksia selaimeen, Edge verify_jwt, migraatio oletuksena off, live vaatii approved_by, ei public-skeemaa', () => {
  const adminFiles = readdirSync(new URL('../admin/', import.meta.url)).filter((f) => f.endsWith('.js'));
  for (const f of adminFiles) {
    const s = read(`../admin/${f}`);
    assert.equal(/SUMUP_(API|AFFILIATE|WEBHOOK)|sup_sk_|sup_afk_|affiliate/i.test(s), false, f);
  }
  const cfg = read('../supabase/config.toml');
  assert.match(cfg, /\[functions\.sumup-pos\]\nverify_jwt = true/);
  assert.match(cfg, /\[functions\.sumup-notify\]\nverify_jwt = false/);
  const migDir = new URL('../supabase/migrations/', import.meta.url);
  const migs = readdirSync(migDir).filter((f) => /_booking_295_/.test(f));
  assert.equal(migs.length, 1);
  assert.equal(migs[0], "20261121115144_booking_295_sumup_pos.sql"); // PROD-version mukaan
  const m = readFileSync(new URL(migs[0], migDir), 'utf8');
  assert.equal(/\bpublic\./i.test(m.replace(/--[^\n]*/g, '')), false, 'ei public-skeemaa');
  assert.match(m, /values \('sumup', 'off'/);
  assert.match(m, /new\.mode in \('test', 'live'\) and coalesce\(btrim\(new\.settings ->> 'approved_by'\), ''\) = ''/);
  assert.match(m, /p_mode in \('test', 'live'\) and v_by is null/);
  assert.match(m, /where t\.handler <> 'checkoutx' and \(t\.handler <> 'sumup' or v_su in \('test', 'live'\)\)/);
  assert.match(m, /if p_confirmed_by is distinct from 'api'/);
  for (const fn of ['sumup_pos_prepare(bigint,text,uuid)', 'sumup_pos_apply(bigint,text,text,text,numeric,jsonb)', 'sumup_reader_save(text,text,uuid)', 'sumup_refund_complete(bigint,jsonb)', 'sumup_pos_lookup_ref(text)']) {
    assert.ok(m.includes(`revoke all on function booking.${fn} from public, anon, authenticated;`), fn);
    assert.ok(m.includes(`grant execute on function booking.${fn} to service_role;`), fn);
  }
  const rb = readFileSync(new URL(`../supabase/rollbacks/${migs[0].replace(/_sumup_pos\.sql$/, '_ROLLBACK.sql')}`, import.meta.url), 'utf8');
  assert.match(rb, /864bc26d1e42f6cb36eaf06da46dd6e6/);
  const edge = read('../supabase/functions/sumup-pos/handler.ts');
  assert.match(edge, /mode !== "test" && mode !== "live"/);
  assert.match(edge, /envMatchesMode/);
  const notify = read('../supabase/functions/sumup-notify/handler.ts');
  assert.match(notify, /safeEqual\(given, cfg\.webhookSecret\)/);
  assert.match(read('../supabase/functions/_shared/sumup_flow.ts'), /p_confirmed_by: "api"/);
});

// ---------- näkymä ----------
const ctx = { can: (p) => p === 'pos.use' || p === 'catalog.edit' || p === 'settings.edit' };
function suRpc({ mode = 'test', readers = [{ reader_id: 'rdr_0001', name: 'Kassalukija', is_default: true }] } = {}) {
  const mock = createAdminMock({ delay: 0 });
  const st = { paid: false, calls: [], rpcArgs: [] };
  const rpc = async (name, args) => {
    st.calls.push(name); st.rpcArgs.push([name, args]);
    if (name === 'admin_pos_tenders') {
      const r = await mock.rpc(name, args);
      const base = { ...r, sumup_mode: mode, tenders: (r.tenders || []).filter((x) => x.handler !== 'sumup') };
      if (mode === 'test' || mode === 'live') base.tenders = [...base.tenders, { code: 'sumup', handler: 'sumup', channels: ['pos'], active: true, sort_order: 14 }];
      return base;
    }
    if (name === 'admin_get_sumup_status') return { ok: true, mode, readers };
    if (name === 'admin_pos_status' && st.paid) {
      const r = await mock.rpc(name, args);
      return { ...r, payment_status: 'paid', receipts: [{ receipt_no: 'K-1' }] };
    }
    if (name === 'admin_sumup_reader_set_default' || name === 'admin_sumup_reader_remove') return { ok: true };
    return mock.rpc(name, args);
  };
  return { rpc, st };
}
async function mountWith(rpc, fn, c = ctx) {
  reset();
  const root = await renderPos({ ctx: c, rpc, fn });
  document.body.append(root);
  return root;
}
const tenderRadio = (dlg, v) => all(dlg).find((n) => n.getAttribute('name') === 'tender' && n.value === v);

test('tila off (tuotanto): ei korttipäätettä eikä tilakyselyä', async () => {
  mem.clear();
  const { rpc, st } = suRpc({ mode: 'off' });
  const root = await mountWith(rpc, async (name) => { throw new Error(`fn:${name}`); });
  q(root, 'pos-product-101').click();
  q(root, 'pos-pay').click();
  const dlg = document.getElementById('pos-pay-dialog');
  assert.equal(tenderRadio(dlg, 'sumup'), undefined);
  assert.equal(st.calls.includes('admin_get_sumup_status'), false);
  assert.equal(dlg.textContent.includes('SumUp'), false);
});

test('tila test: maksu → POST start lukijalle, tila haetaan Edge-funktiolta, maksettu näkyy', async () => {
  mem.clear();
  const { rpc, st } = suRpc();
  const fnCalls = [];
  const fn = async (name, body) => {
    fnCalls.push([name, body]);
    if (body.action === 'start') return { ok: true, payment_id: 77, amount: 3 };
    if (body.action === 'status') { st.paid = true; return { ok: true, state: 'paid' }; }
    throw new Error('odottamaton');
  };
  const root = await mountWith(rpc, fn);
  q(root, 'pos-product-101').click();
  q(root, 'pos-pay').click();
  let dlg = document.getElementById('pos-pay-dialog');
  const radio = tenderRadio(dlg, 'sumup');
  assert.ok(radio, 'vaihtoehto näkyy');
  assert.match(radio.parent.textContent, /Korttipääte \(SumUp Solo\)/);
  radio.dispatch('change');
  dlg = document.getElementById('pos-pay-dialog');
  // t1865u: maksuikkunassa vain summa, maksutapa ja Vahvista maksu: ei lukijavalintaa eikä paritusta
  assert.equal(q(dlg, 'pos-su'), null);
  assert.equal(all(dlg).some((n) => n.tagName === 'SELECT'), false);
  assert.equal(q(dlg, 'pos-su-pair'), null);
  q(dlg, 'pos-confirm').click();
  await flush();
  const startCall = fnCalls.find(([, b]) => b.action === 'start');
  assert.ok(startCall);
  assert.equal(startCall[0], 'sumup-pos');
  assert.equal(startCall[1].reader_id, 'rdr_0001');
  assert.ok(Number.isInteger(startCall[1].order_id));
  assert.equal(Object.keys(startCall[1]).some((k) => /key|secret|affiliate|amount|price/i.test(k)), false, 'selain ei lähetä summaa eikä avaimia');
  assert.ok(fnCalls.some(([, b]) => b.action === 'status' && b.payment_id === 77));
  await flush();
  dlg = document.getElementById('pos-pay-dialog');
  assert.ok(q(dlg, 'pos-paid-dialog'), 'onnistui');
  assert.equal(mem.has(su.SU_PENDING_KEY), false, 'kesken-merkintä poistettu');
  q(dlg, 'pos-next-dialog').click();
});

test('odotus: tila pending näyttää odotusviestin ja Peru-napin; peruutus lukijalta (terminate) ennen kassatilauksen perumista', async () => {
  mem.clear();
  const { rpc, st } = suRpc();
  const fnCalls = [];
  const fn = async (name, body) => {
    fnCalls.push(body.action);
    if (body.action === 'start') return { ok: true, payment_id: 70, amount: 3 };
    if (body.action === 'status') return { ok: true, state: 'pending' };
    if (body.action === 'cancel') return { ok: true, state: 'cancelled' };
    throw new Error('odottamaton');
  };
  const root = await mountWith(rpc, fn);
  q(root, 'pos-product-101').click();
  q(root, 'pos-pay').click();
  tenderRadio(document.getElementById('pos-pay-dialog'), 'sumup').dispatch('change');
  q(document.getElementById('pos-pay-dialog'), 'pos-confirm').click();
  await flush();
  let dlg = document.getElementById('pos-pay-dialog');
  assert.match(q(dlg, 'pos-su-help').textContent, /Lukija näyttää summan/);
  assert.equal(q(dlg, 'pos-su-failed'), null);
  assert.ok(mem.has(su.SU_PENDING_KEY), 'kesken-merkintä talteen');
  q(dlg, 'pos-su-cancel').click();
  await flush();
  assert.ok(fnCalls.includes('cancel'));
  assert.ok(st.calls.includes('admin_pos_void'));
  assert.ok(fnCalls.indexOf('cancel') >= 0);
  assert.equal(mem.has(su.SU_PENDING_KEY), false);
  document.body.replaceChildren();
});

test('hylätty ja peruttu: virhe näkyy, uusi yritys käynnistää uuden checkoutin', async () => {
  for (const [state, re] of [['failed', /Korttimaksu ei onnistunut/], ['cancelled', /Korttimaksu peruttiin/]]) {
    mem.clear();
    const { rpc, st } = suRpc();
    const fnCalls = [];
    let n = 0;
    const fn = async (name, body) => {
      fnCalls.push(body.action);
      if (body.action === 'start') return { ok: true, payment_id: 80 + (++n), amount: 3 };
      if (body.action === 'status') return { ok: true, state };
      throw new Error('odottamaton');
    };
    const root = await mountWith(rpc, fn);
    q(root, 'pos-product-101').click();
    q(root, 'pos-pay').click();
    tenderRadio(document.getElementById('pos-pay-dialog'), 'sumup').dispatch('change');
    q(document.getElementById('pos-pay-dialog'), 'pos-confirm').click();
    await flush();
    let dlg = document.getElementById('pos-pay-dialog');
    const box = q(dlg, 'pos-su-failed');
    assert.match(box.textContent, re);
    assert.equal(box.getAttribute('data-state'), state);
    q(dlg, 'pos-su-retry').click();
    await flush();
    assert.equal(fnCalls.filter((a) => a === 'start').length, 2);
    dlg = document.getElementById('pos-pay-dialog');
    q(dlg, 'pos-su-cancel').click();
    await flush();
    assert.ok(st.calls.includes('admin_pos_void'));
    assert.equal(fnCalls.includes('cancel'), false, 'päättynyttä ei tarvitse perua lukijalta');
    assert.equal(mem.has(su.SU_PENDING_KEY), false);
  }
});

test('ei oletuslukijaa → ei SumUp-kutsua; selkeä virhe ohjaa Asetuksiin (settings.edit) tai ylläpitäjälle (t1865u)', async () => {
  mem.clear();
  const fnCalls = [];
  const fn = async (name, body) => { fnCalls.push(body); throw new Error('odottamaton'); };
  for (const readers of [[], [{ reader_id: 'rdr_0001', name: 'A' }]]) {
    const root = await mountWith(suRpc({ readers }).rpc, fn);
    q(root, 'pos-product-101').click();
    q(root, 'pos-pay').click();
    tenderRadio(document.getElementById('pos-pay-dialog'), 'sumup').dispatch('change');
    q(document.getElementById('pos-pay-dialog'), 'pos-confirm').click();
    await flush();
    const dlg = document.getElementById('pos-pay-dialog');
    assert.match(q(dlg, 'pos-pay-error').textContent, /Oletuslukijaa ei ole valittu.*Asetukset/);
    assert.equal(q(dlg, 'pos-su-open-settings').getAttribute('href'), '#/asetukset/maksut');
    q(dlg, 'pos-pay-close').click();
  }
  assert.equal(fnCalls.length, 0);
  const root2 = await mountWith(suRpc({ readers: [] }).rpc, fn, { can: (p) => p === 'pos.use' || p === 'catalog.edit' });
  q(root2, 'pos-product-101').click();
  q(root2, 'pos-pay').click();
  tenderRadio(document.getElementById('pos-pay-dialog'), 'sumup').dispatch('change');
  q(document.getElementById('pos-pay-dialog'), 'pos-confirm').click();
  await flush();
  const dlg2 = document.getElementById('pos-pay-dialog');
  assert.equal(q(dlg2, 'pos-su-open-settings'), null);
  assert.match(q(dlg2, 'pos-su-ask-admin').textContent, /ylläpitäjää/);
  document.body.replaceChildren();
  await flush();
});

test('useita lukijoita: korttimaksu käyttää automaattisesti oletuslukijaa (ei muistettua valintaa)', async () => {
  mem.clear();
  mem.set(su.SU_READER_KEY, JSON.stringify({ reader_id: 'rdr_0001', name: 'A' }));
  const readers = [{ reader_id: 'rdr_0001', name: 'A' }, { reader_id: 'rdr_0002', name: 'B', is_default: true }];
  const { rpc } = suRpc({ readers });
  const fnCalls = [];
  const fn = async (name, body) => { fnCalls.push(body); if (body.action === 'start') return { ok: true, payment_id: 91, amount: 3 }; return { ok: true, state: 'pending' }; };
  const root = await mountWith(rpc, fn);
  q(root, 'pos-product-101').click();
  q(root, 'pos-pay').click();
  tenderRadio(document.getElementById('pos-pay-dialog'), 'sumup').dispatch('change');
  assert.equal(q(document.getElementById('pos-pay-dialog'), 'pos-su-reader'), null);
  q(document.getElementById('pos-pay-dialog'), 'pos-confirm').click();
  await flush();
  assert.equal(fnCalls.find((b) => b.action === 'start').reader_id, 'rdr_0002');
  q(document.getElementById('pos-pay-dialog'), 'pos-su-cancel').click(); // pysäyttää kyselyajastimen
  await flush();
  document.body.replaceChildren();
});

test('Asetukset › Maksut: SumUp-korttipääte-osio (settings.edit), samat RPC- ja Edge-kutsut', () => {
  const card = read('../admin/views/sumup-settings.js');
  const set = read('../admin/views/settings.js');
  assert.match(set, /import \{ sumupSettingsCard \} from '\.\/sumup-settings\.js'/);
  assert.match(set, /sumupSettingsCard\(\{ ctx \}\)/);
  assert.match(card, /if \(!ctx\?\.can\?\.\('settings\.edit'\)\) return null;/);
  for (const s of ["rpc('admin_get_sumup_status')", "rpc('admin_sumup_reader_set_default', { p_reader_id:", "rpc('admin_sumup_reader_remove', { p_reader_id:", "callFn('sumup-pos', { action: 'reader_pair'", 'validPairingCode(st.pairCode)']) assert.ok(card.includes(s), s);
  for (const id of ['set-sumup-reader', 'set-sumup-default', 'set-sumup-remove', 'set-sumup-pair-code', 'set-sumup-pair-name', 'set-sumup-pair']) assert.ok(card.includes(`'${id}'`), id);
  const pos = read('../admin/pos-screen.js');
  for (const gone of ['pos-su-reader', 'pos-su-pair', 'pos-su-default', 'pos-su-remove', 'admin_sumup_reader_set_default', 'reader_pair', 'terminal_later']) assert.equal(pos.includes(gone), false, gone);
  assert.equal(su.defaultReader([{ reader_id: 'rdr_0001' }, { reader_id: 'rdr_0002', is_default: true }]).reader_id, 'rdr_0002');
  assert.equal(su.defaultReader([{ reader_id: 'rdr_0001' }]), null);
  assert.equal(su.defaultReader([{ reader_id: 'rdr_0003', is_default: true, active: false }]), null);
});

test('virhe aloituksessa (lukija offline): kassatilaus perutaan ja virhe näytetään suomeksi', async () => {
  mem.clear();
  const { rpc, st } = suRpc();
  const fn = async () => { const e = new Error('x'); e.code = 'reader_offline'; throw e; };
  const root = await mountWith(rpc, fn);
  q(root, 'pos-product-101').click();
  q(root, 'pos-pay').click();
  tenderRadio(document.getElementById('pos-pay-dialog'), 'sumup').dispatch('change');
  q(document.getElementById('pos-pay-dialog'), 'pos-confirm').click();
  await flush();
  assert.ok(st.calls.includes('admin_pos_void'));
  assert.match(q(document.getElementById('pos-pay-dialog'), 'pos-pay-error').textContent, /Lukija ei ole yhteydessä/);
  document.body.replaceChildren();
});

// ---------- kokeilutila (?mock=1): simuloitu SumUp ilman tunnuksia ----------
test('kokeilutila: oletuksena off; simuloitu maksu hylätään (?su=decline) ja uusi yritys hyväksytään; ei verkkoa', async () => {
  mem.clear();
  globalThis.location = { search: '?mock=1&su=decline', hash: '', pathname: '/hallinta/' };
  try {
    const plain = await createAdminMock({ delay: 0 }).rpc('admin_pos_tenders');
    assert.equal(plain.sumup_mode, 'off', 'oletuksena pois');
    assert.equal(plain.tenders.some((x) => x.code === 'sumup'), false);
    const mock = createAdminMock({ delay: 0, sumup: true });
    const ten = await mock.rpc('admin_pos_tenders');
    assert.equal(ten.sumup_mode, 'test');
    assert.ok(ten.tenders.some((x) => x.code === 'sumup'));
    assert.equal(ten.tenders.some((x) => x.code === 'checkoutx'), false);
    await assert.rejects(mock.fn('montonio-refund', {}), (e) => e.code === 'mock_unsupported');
    const root = await mountWith(mock.rpc, mock.fn);
    q(root, 'pos-product-101').click();
    q(root, 'pos-pay').click();
    tenderRadio(document.getElementById('pos-pay-dialog'), 'sumup').dispatch('change');
    let dlg = document.getElementById('pos-pay-dialog');
    q(dlg, 'pos-confirm').click();
    await flush();
    dlg = document.getElementById('pos-pay-dialog');
    assert.ok(q(dlg, 'pos-su-simulated'));
    await new Promise((r) => setTimeout(r, 2700)); await flush();
    dlg = document.getElementById('pos-pay-dialog');
    assert.match(q(dlg, 'pos-su-failed').textContent, /Korttimaksu ei onnistunut/);
    q(dlg, 'pos-su-retry').click();
    await flush();
    await new Promise((r) => setTimeout(r, 2700)); await flush();
    dlg = document.getElementById('pos-pay-dialog');
    assert.ok(q(dlg, 'pos-paid-dialog'), 'toinen yritys maksettu');
    assert.equal(mock.state.su.payments.length, 2);
    assert.deepEqual(mock.state.su.payments.map((x) => x.state), ['failed', 'paid']);
    q(dlg, 'pos-next-dialog').click();
  } finally {
    globalThis.location = { search: '?mock=1', hash: '', pathname: '/hallinta/' };
    document.body.replaceChildren();
  }
});

test('tekstit: import 182 = POS_SUMUP_SETTINGS_TEXTS, FI+EN, uudet avaimet käytössä', () => {
  const T = texts.POS_SUMUP_SETTINGS_TEXTS;
  assert.deepEqual(Object.keys(T.fi).sort(), Object.keys(T.en).sort());
  const rows = JSON.parse(read('../../content/site-texts.pending-import-182.json'));
  assert.equal(rows.length, Object.keys(T.fi).length * 2);
  for (const r of rows) {
    const k = r.key.slice('ui.pos.'.length);
    assert.match(r.key, /^ui\.pos\.su_[a-z_]+$/);
    assert.equal(r.text, T[r.lang][k]); assert.equal(texts.posText(k, r.lang), r.text);
    assert.equal(Object.hasOwn(texts.POS_SUMUP_TEXTS.fi, k), false, k);
  }
  const src = read('../admin/pos-screen.js') + read('../admin/views/sumup-settings.js');
  for (const k of Object.keys(T.fi)) assert.ok(src.includes(`'${k}'`), `käyttämätön avain ${k}`);
});
