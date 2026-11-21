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
test('cxEnabled ja tenderAvailable: CheckoutX on piilotettu Pikakassasta (booking_295), apurit säilyvät', () => {
  const t = { code: 'checkoutx', handler: 'checkoutx', channels: ['pos'], active: true };
  assert.equal(cxm.cxEnabled({ checkoutx_mode: 'test' }), true, 'apuri itse ennallaan');
  for (const m of [undefined, null, {}, { checkoutx_mode: 'off' }, { checkoutx_mode: 'test' }, { checkoutx_mode: 'live' }]) {
    assert.equal(tenderAvailable(t, m), false, 'ei koskaan käytettävissä kassalla');
  }
  assert.equal(posSheetTenders([t]).length, 0, 'ei kassan maksulistalla');
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
const ctx = { can: (p) => p === 'pos.use' || p === 'catalog.edit' || p === 'settings.edit' };
test('Pikakassa ei näytä CheckoutX:ää, vaikka palvelin kertoisi checkoutx_mode = test (booking_295)', async () => {
  mem.clear();
  const mock = createAdminMock({ delay: 0, checkoutx: true });
  const ten = await mock.rpc('admin_pos_tenders');
  assert.equal(ten.checkoutx_mode, 'test');
  assert.ok(ten.tenders.some((x) => x.code === 'checkoutx'), 'vanha vastaus sisältää rivin');
  reset();
  const calls = [];
  const rpc = async (name, args) => { calls.push(name); return mock.rpc(name, args); };
  const root = await renderPos({ ctx, rpc, fn: async () => { throw new Error('ei fn-kutsuja'); } });
  document.body.append(root);
  q(root, 'pos-product-101').click();
  q(root, 'pos-pay').click();
  const dlg = document.getElementById('pos-pay-dialog');
  assert.equal(all(dlg).find((n) => n.getAttribute('name') === 'tender' && n.value === 'checkoutx'), undefined);
  assert.equal(dlg.textContent.includes('CheckoutX'), false);
  assert.equal(calls.includes('admin_get_checkoutx_status'), false, 'ei CheckoutX-tilakyselyä');
  document.body.replaceChildren();
});
