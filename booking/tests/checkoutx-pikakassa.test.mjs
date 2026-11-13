// booking_286: Pikakassan kortti puhelimella (CheckoutX / Surfboard demo). Keinotekoinen DOM, ei verkkoa eikä tietokantaa.
// Edge-funktion oma logiikka (Surfboard-mock) testataan Denolla: supabase/functions/_tests/checkoutx_test.ts.
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import test from 'node:test';
const href = (rel) => new URL(rel, import.meta.url).href;
const read = (rel) => readFileSync(new URL(rel, import.meta.url), 'utf8');

// Sama keinotekoinen DOM kuin pikakassa-nakyma.test.mjs:ssä (luetaan sieltä, ettei kahta kopiota tarvitse ylläpitää).
const domSrc = read('./pikakassa-nakyma.test.mjs');
const start = domSrc.indexOf('function installDom() {');
const end = domSrc.indexOf('\ninstallDom();');
assert.ok(start >= 0 && end > start, 'installDom löytyy');
new Function(`${domSrc.slice(start, end)}\ninstallDom();`)();
globalThis.location = { search: '?mock=1', hash: '', pathname: '/hallinta/' };
globalThis.window = globalThis;
const mem = new Map();
globalThis.localStorage = { getItem: (k) => (mem.has(k) ? mem.get(k) : null), setItem: (k, v) => mem.set(k, String(v)), removeItem: (k) => mem.delete(k) };

const cxm = await import(href('../admin/checkoutx-pos.js'));
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

// ---------- puhtaat apurit ----------
test('cxEnabled ja tenderAvailable: vain tila test näyttää maksutavan', () => {
  const t = { code: 'checkoutx', handler: 'checkoutx', channels: ['pos'], active: true };
  assert.equal(cxm.cxEnabled({ checkoutx_mode: 'test' }), true);
  for (const m of [undefined, null, {}, { checkoutx_mode: 'off' }, { checkoutx_mode: 'live' }]) {
    assert.equal(cxm.cxEnabled(m), false);
    assert.equal(tenderAvailable(t, m), false);
  }
  assert.equal(tenderAvailable(t, { checkoutx_mode: 'test' }), true);
  assert.equal(tenderAvailable({ ...t, active: false }, { checkoutx_mode: 'test' }), false);
  assert.equal(posSheetTenders([t]).length, 1, 'kassan listalle kelpaa');
  // muut maksutavat ennallaan
  assert.equal(tenderAvailable({ code: 'payment_link', handler: 'payment_link', active: true }, { montonio_mode: 'test', checkoutx_mode: 'off' }), true);
  assert.equal(tenderAvailable({ code: 'card_terminal', handler: 'terminal', active: true }, { checkoutx_mode: 'test' }), false);
});

test('puhelimen muisti: kelvollinen tunnus, valinta palvelimen listasta, kesken jäänyt maksu vanhenee', () => {
  const s = new Map();
  const st = { getItem: (k) => s.get(k) ?? null, setItem: (k, v) => s.set(k, v), removeItem: (k) => s.delete(k) };
  assert.equal(cxm.saveTerminal(st, { terminal_id: 'bad id!' }), null);
  assert.deepEqual(cxm.saveTerminal(st, { terminal_id: '83abab731f6fb00704', label: 'Kassa' }), { terminal_id: '83abab731f6fb00704', label: 'Kassa' });
  assert.deepEqual(cxm.readTerminal(st), { terminal_id: '83abab731f6fb00704', label: 'Kassa' });
  s.set(cxm.CX_TERMINAL_KEY, '{rikki');
  assert.equal(cxm.readTerminal(st), null);
  const list = [{ terminal_id: 'T0001', label: 'A' }, { terminal_id: 'T0002', label: 'B' }];
  assert.deepEqual(cxm.pickTerminal({ terminal_id: 'T0002', label: '' }, list), { terminal_id: 'T0002', label: 'B' });
  assert.equal(cxm.pickTerminal({ terminal_id: 'GONE1' }, list), null, 'poistettu puhelin ei kelpaa');
  assert.deepEqual(cxm.pickTerminal(null, [list[0]]), { terminal_id: 'T0001', label: 'A' });
  assert.equal(cxm.pickTerminal(null, []), null);
  cxm.savePending(st, { order_id: 5, payment_id: 9 }, 1000);
  assert.deepEqual(cxm.readPending(st, 1000 + 60000), { order_id: 5, payment_id: 9, at: 1000 });
  assert.equal(cxm.readPending(st, 1000 + cxm.CX_PENDING_TTL_MS + 1), null);
  assert.equal(cxm.savePending(st, { order_id: 'x', payment_id: 9 }), null);
  cxm.clearPending(st);
  assert.equal(cxm.readPending(st), null);
});

test('syvälinkki: vain checkoutx://com.surfboard.checkoutx/, avataan tilapäisellä linkillä', () => {
  assert.equal(cxm.isCheckoutxLink('checkoutx://com.surfboard.checkoutx/transaction?redirectUrl=abc&data=def'), true);
  for (const bad of ['https://evil.example', 'javascript:alert(1)', 'checkoutx://other/x', 'checkoutx://com.surfboard.checkoutx/x y', null]) assert.equal(cxm.isCheckoutxLink(bad), false);
  reset();
  const clicked = [];
  const origCreate = document.createElement.bind(document);
  const doc = { createElement: (tag) => { const el = origCreate(tag); el.click = () => clicked.push(el.href); return el; }, body: document.body };
  assert.equal(cxm.openAppLink('https://evil.example', doc), false);
  assert.equal(cxm.openAppLink('checkoutx://com.surfboard.checkoutx/configure?redirectUrl=x', doc), true);
  assert.deepEqual(clicked, ['checkoutx://com.surfboard.checkoutx/configure?redirectUrl=x']);
});

test('virhekoodit ja tilat', () => {
  assert.equal(cxm.cxErrorKey('terminal_not_connected'), 'cx_not_connected');
  assert.equal(cxm.cxErrorKey('mystery'), 'cx_provider_error');
  assert.equal(cxm.cxStateOf({ state: 'paid' }), 'paid');
  assert.equal(cxm.cxStateOf({ state: 'weird' }), 'pending');
  assert.equal(cxm.cxStateOf(null), 'pending');
});

// ---------- tekstit ----------
test('tekstit: FI+EN samat avaimet, import 141 = koodin sanakirja, kaikki avaimet käytössä', () => {
  const fi = texts.POS_CHECKOUTX_TEXTS.fi, en = texts.POS_CHECKOUTX_TEXTS.en;
  assert.deepEqual(Object.keys(fi).sort(), Object.keys(en).sort());
  const rows = JSON.parse(read('../../content/site-texts.pending-import-141.json'));
  assert.equal(rows.length, Object.keys(fi).length * 2);
  const seen = new Set();
  for (const r of rows) {
    assert.match(r.key, /^ui\.pos\.(method_checkoutx|cx_[a-z_]+)$/);
    assert.ok(['fi', 'en'].includes(r.lang));
    assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain'); assert.deepEqual(r.placeholders, []);
    const k = r.key.slice('ui.pos.'.length);
    assert.equal(r.text, texts.POS_CHECKOUTX_TEXTS[r.lang][k]);
    assert.equal(texts.posText(k, r.lang), r.text);
    assert.ok(!seen.has(`${r.key}|${r.lang}`)); seen.add(`${r.key}|${r.lang}`);
    assert.ok(!/[<>]/.test(r.text));
  }
  // ei päällekkäisyyttä aiempien pos-sanakirjojen kanssa
  for (const other of ['POS_TEXTS', 'POS_EDIT_TEXTS', 'POS_PAY_TEXTS', 'POS_LINK_TEXTS', 'POS_CUSTOMER_TEXTS', 'POS_CUSTOM_TEXTS']) {
    for (const k of Object.keys(fi)) assert.equal(Object.hasOwn(texts[other].fi, k), false, `${other}.${k}`);
  }
  // muut tuontitiedostot eivät käytä samoja avaimia
  const dir = new URL('../../content/', import.meta.url);
  for (const f of readdirSync(dir).filter((x) => /^site-texts\.pending-import-\d+\.json$/.test(x) && x !== 'site-texts.pending-import-141.json')) {
    const other = JSON.parse(readFileSync(new URL(f, dir), 'utf8'));
    for (const r of Array.isArray(other) ? other : []) assert.equal(seen.has(`${r.key}|${r.lang}`), false, `${f}: ${r.key}`);
  }
  const src = read('../admin/pos-screen.js') + read('../admin/checkoutx-pos.js');
  for (const k of Object.keys(fi)) assert.ok(src.includes(`'${k}'`), `käyttämätön avain ${k}`);
  for (const k of ['done', 'failed', 'not_supported', 'retry_later', 'not_configured', 'none', 'off', 'forbidden', 'error']) {
    assert.ok(talous.TEXTS.fi[`refund.cx.${k}`] && talous.TEXTS.en[`refund.cx.${k}`], `refund.cx.${k}`);
  }
});

// ---------- turvallisuus ja tuotannon muuttumattomuus (staattinen) ----------
test('ei salaisuuksia selaimeen, Edge verify_jwt, migraatio oletuksena off eikä koske public-skeemaan', () => {
  const adminFiles = readdirSync(new URL('../admin/', import.meta.url)).filter((f) => f.endsWith('.js'));
  for (const f of adminFiles) {
    const s = read(`../admin/${f}`);
    assert.equal(/SURFBOARD_API_(KEY|SECRET|URL)|API-SECRET/.test(s), false, f);
  }
  const cfg = read('../supabase/config.toml');
  assert.match(cfg, /\[functions\.checkoutx-pos\]\nverify_jwt = true/);
  const migDir = new URL('../supabase/migrations/', import.meta.url);
  const migs = readdirSync(migDir).filter((f) => /_booking_286_/.test(f));
  assert.equal(migs.length, 1);
  const m = readFileSync(new URL(migs[0], migDir), 'utf8');
  assert.equal(/\bpublic\./i.test(m.replace(/--[^\n]*/g, '')), false, 'ei public-skeemaa');
  assert.match(m, /values \('checkoutx', 'off'/);
  assert.match(m, /integration_config_checkoutx_no_live[\s\S]*mode in \('off', 'test'\)/);
  assert.match(m, /p_mode not in \('off', 'test'\)/);
  assert.match(m, /where t\.handler <> 'checkoutx' or v_cx = 'test'/);
  for (const fn of ['checkoutx_pos_prepare(bigint,text,uuid)', 'checkoutx_pos_apply(bigint,text,text,jsonb)', 'checkoutx_terminal_save(text,text,uuid)', 'checkoutx_refund_complete(bigint,jsonb)']) {
    assert.ok(m.includes(`revoke all on function booking.${fn} from public, anon, authenticated;`), fn);
    assert.ok(m.includes(`grant execute on function booking.${fn} to service_role;`), fn);
  }
  const rb = readFileSync(new URL(`../supabase/rollbacks/${migs[0].replace(/_checkoutx_pos\.sql$/, '_ROLLBACK.sql')}`, import.meta.url), 'utf8');
  assert.match(rb, /443e6462ede3ec9d3118d08be43759fa/);
  const edge = read('../supabase/functions/checkoutx-pos/handler.ts');
  assert.match(edge, /if \(mode !== "test"\)/);
  assert.match(read('../supabase/functions/_shared/checkoutx.ts'), /CHECKOUTX_ENV"\) \?\? ""\)\.trim\(\) === "demo"/);
});

// ---------- näkymä ----------
function cxRpc({ mode = 'test', terminals = [{ terminal_id: 'T0001', label: 'Kassapuhelin' }] } = {}) {
  const mock = createAdminMock({ delay: 0 });
  const st = { paid: false, calls: [] };
  const rpc = async (name, args) => {
    st.calls.push(name);
    if (name === 'admin_pos_tenders') {
      const r = await mock.rpc(name, args);
      const base = { ...r, checkoutx_mode: mode, tenders: (r.tenders || []).filter((x) => x.handler !== 'checkoutx') };
      if (mode === 'test') base.tenders = [...base.tenders, { code: 'checkoutx', handler: 'checkoutx', channels: ['pos'], active: true, sort_order: 15 }];
      return base;
    }
    if (name === 'admin_get_checkoutx_status') return { ok: true, mode, terminals };
    if (name === 'admin_pos_status' && st.paid) {
      const r = await mock.rpc(name, args);
      return { ...r, payment_status: 'paid', receipts: [{ receipt_no: 'K-1' }] };
    }
    return mock.rpc(name, args);
  };
  return { rpc, st };
}
const ctx = { can: (p) => p === 'pos.use' || p === 'catalog.edit' || p === 'settings.edit' };
async function mountWith(rpc, fn) {
  reset();
  const root = await renderPos({ ctx, rpc, fn });
  document.body.append(root);
  return root;
}
const tenderRadio = (dlg, v) => all(dlg).find((n) => n.getAttribute('name') === 'tender' && n.value === v);

test('tila off (tuotanto): ei CheckoutX-vaihtoehtoa eikä tilakyselyä', async () => {
  mem.clear();
  const { rpc, st } = cxRpc({ mode: 'off' });
  const root = await mountWith(rpc, async (name) => { throw new Error(`fn:${name}`); });
  q(root, 'pos-product-101').click();
  q(root, 'pos-pay').click();
  const dlg = document.getElementById('pos-pay-dialog');
  assert.equal(tenderRadio(dlg, 'checkoutx'), undefined);
  assert.equal(st.calls.includes('admin_get_checkoutx_status'), false);
  assert.equal(dlg.textContent.includes('CheckoutX'), false);
});

test('tila test: maksu käynnistää CheckoutX:n, tila haetaan Edge-funktiolta ja maksettu näkyy', async () => {
  mem.clear();
  const { rpc, st } = cxRpc();
  const fnCalls = [];
  const fn = async (name, body) => {
    fnCalls.push([name, body]);
    if (body.action === 'start') return { ok: true, payment_id: 77, amount: 3, deep_link: 'checkoutx://com.surfboard.checkoutx/transaction?redirectUrl=a&data=b', configure_link: 'checkoutx://com.surfboard.checkoutx/configure?redirectUrl=a' };
    if (body.action === 'status') { st.paid = true; return { ok: true, state: 'paid' }; }
    throw new Error('odottamaton');
  };
  const root = await mountWith(rpc, fn);
  q(root, 'pos-product-101').click();
  q(root, 'pos-pay').click();
  let dlg = document.getElementById('pos-pay-dialog');
  const radio = tenderRadio(dlg, 'checkoutx');
  assert.ok(radio, 'vaihtoehto näkyy');
  assert.match(radio.parent.textContent, /Kortti puhelimella \(CheckoutX\)/);
  radio.dispatch('change');
  dlg = document.getElementById('pos-pay-dialog');
  assert.ok(q(dlg, 'pos-cx'));
  assert.match(q(dlg, 'pos-cx-test-note').textContent, /Testiympäristö/);
  assert.equal(q(dlg, 'pos-cx-no-terminal'), null, 'ainoa puhelin valitaan automaattisesti');
  q(dlg, 'pos-confirm').click();
  await flush();
  const startCall = fnCalls.find(([, b]) => b.action === 'start');
  assert.ok(startCall);
  assert.equal(startCall[0], 'checkoutx-pos');
  assert.equal(startCall[1].terminal_id, 'T0001');
  assert.equal(startCall[1].return, 'chrome');
  assert.ok(Number.isInteger(startCall[1].order_id));
  assert.ok(fnCalls.some(([, b]) => b.action === 'status' && b.payment_id === 77));
  await flush();
  dlg = document.getElementById('pos-pay-dialog');
  assert.ok(q(dlg, 'pos-paid-dialog'), 'maksettu');
  assert.equal(mem.has(cxm.CX_PENDING_KEY), false, 'kesken-merkintä poistettu');
  q(dlg, 'pos-next-dialog').click();
});

test('tila test: epäonnistunut maksu → virhe, uusi yritys ja peruutus (Surfboard ensin, sitten kassa)', async () => {
  mem.clear();
  const { rpc, st } = cxRpc();
  const fnCalls = [];
  let n = 0;
  const fn = async (name, body) => {
    fnCalls.push(body.action);
    if (body.action === 'start') return { ok: true, payment_id: 80 + (++n), amount: 3, deep_link: 'checkoutx://com.surfboard.checkoutx/transaction?redirectUrl=a&data=b' };
    if (body.action === 'status') return { ok: true, state: 'failed', failure_reason: 'DECLINED' };
    if (body.action === 'cancel') return { ok: true, state: 'cancelled' };
    throw new Error('odottamaton');
  };
  const root = await mountWith(rpc, fn);
  q(root, 'pos-product-101').click();
  q(root, 'pos-pay').click();
  tenderRadio(document.getElementById('pos-pay-dialog'), 'checkoutx').dispatch('change');
  q(document.getElementById('pos-pay-dialog'), 'pos-confirm').click();
  await flush();
  let dlg = document.getElementById('pos-pay-dialog');
  assert.match(q(dlg, 'pos-cx-failed').textContent, /Korttimaksu ei onnistunut\. \(DECLINED\)/);
  q(dlg, 'pos-cx-retry').click();
  await flush();
  assert.equal(fnCalls.filter((a) => a === 'start').length, 2);
  dlg = document.getElementById('pos-pay-dialog');
  q(dlg, 'pos-cx-cancel').click();
  await flush();
  assert.ok(st.calls.includes('admin_pos_void'));
  assert.equal(fnCalls.includes('cancel'), false, 'epäonnistunutta ei tarvitse perua Surfboardista');
  assert.equal(mem.has(cxm.CX_PENDING_KEY), false);
});

test('tila test: puhelinta ei liitetty → ei Surfboard-kutsua; ylläpitäjä voi liittää puhelimen', async () => {
  mem.clear();
  const { rpc } = cxRpc({ terminals: [] });
  const fnCalls = [];
  const fn = async (name, body) => {
    fnCalls.push(body.action);
    if (body.action === 'register_start') return { ok: true, registration_code: 'reg1', deep_link: 'checkoutx://com.surfboard.checkoutx/register?redirectUrl=a&data=b' };
    throw new Error('odottamaton');
  };
  const root = await mountWith(rpc, fn);
  q(root, 'pos-product-101').click();
  q(root, 'pos-pay').click();
  tenderRadio(document.getElementById('pos-pay-dialog'), 'checkoutx').dispatch('change');
  let dlg = document.getElementById('pos-pay-dialog');
  assert.match(q(dlg, 'pos-cx-no-terminal').textContent, /ei ole liitetty/);
  q(dlg, 'pos-confirm').click();
  await flush();
  assert.equal(fnCalls.includes('start'), false);
  dlg = document.getElementById('pos-pay-dialog');
  assert.match(q(dlg, 'pos-pay-error').textContent, /ei ole liitetty/);
  q(dlg, 'pos-cx-register').click();
  await flush();
  assert.deepEqual(fnCalls, ['register_start']);
  assert.ok(q(document.getElementById('pos-pay-dialog'), 'pos-cx-register-wait'));
  q(document.getElementById('pos-pay-dialog'), 'pos-pay-close').click();
  document.body.replaceChildren();
  await flush();
});

// ---------- kokeilutila (?mock=1): simuloitu CheckoutX ilman Surfboard-tunnuksia ----------
test('kokeilutila: simuloitu maksu hylätään (?cx=decline) ja uusi yritys hyväksytään; ei syvälinkkiä, ei verkkoa', async () => {
  mem.clear();
  globalThis.location = { search: '?mock=1&cx=decline', hash: '', pathname: '/hallinta/' };
  try {
    assert.equal((await createAdminMock({ delay: 0 }).rpc('admin_pos_tenders')).checkoutx_mode, 'off', 'oletuksena pois');
    const mock = createAdminMock({ delay: 0, checkoutx: true });
    const ten = await mock.rpc('admin_pos_tenders');
    assert.equal(ten.checkoutx_mode, 'test');
    assert.ok(ten.tenders.some((x) => x.code === 'checkoutx'));
    await assert.rejects(mock.fn('montonio-refund', {}), (e) => e.code === 'mock_unsupported');
    const root = await mountWith(mock.rpc, mock.fn);
    q(root, 'pos-product-101').click();
    q(root, 'pos-pay').click();
    tenderRadio(document.getElementById('pos-pay-dialog'), 'checkoutx').dispatch('change');
    let dlg = document.getElementById('pos-pay-dialog');
    assert.match(q(dlg, 'pos-cx-test-note').textContent, /Simuloitu maksu/);
    q(dlg, 'pos-confirm').click();
    await flush();
    dlg = document.getElementById('pos-pay-dialog');
    assert.ok(q(dlg, 'pos-cx-simulated'));
    assert.equal(q(dlg, 'pos-cx-open'), null, 'sovellusta ei avata');
    await new Promise((r) => setTimeout(r, 2700)); await flush();
    dlg = document.getElementById('pos-pay-dialog');
    assert.match(q(dlg, 'pos-cx-failed').textContent, /\(DECLINED\)/);
    q(dlg, 'pos-cx-retry').click();
    await flush();
    await new Promise((r) => setTimeout(r, 2700)); await flush();
    dlg = document.getElementById('pos-pay-dialog');
    assert.ok(q(dlg, 'pos-paid-dialog'), 'toinen yritys maksettu');
    const calls = mock.state.calls.map((c) => c.name);
    assert.equal(calls.filter((n) => n === 'fn:checkoutx-pos').length >= 4, true);
    assert.equal(mock.state.cx.payments.length, 2);
    assert.deepEqual(mock.state.cx.payments.map((x) => x.state), ['failed', 'paid']);
    q(dlg, 'pos-next-dialog').click();
  } finally {
    globalThis.location = { search: '?mock=1', hash: '', pathname: '/hallinta/' };
    document.body.replaceChildren();
  }
});
