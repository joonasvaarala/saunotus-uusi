import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createEventsMock, EVENT_MOCK_RESOURCES } from '../admin/events-mock.js';
import { trainingCards, paymentState, validSpaceTime, nextTrainingStep, trainingExport, messagePreviewGate, orderedWaiters, calendarSpaceDays } from '../admin/training-logic.js';
import { TRAINING_TEXTS } from '../admin/training-texts.js';
const root=join(dirname(fileURLToPath(import.meta.url)), '..');
const read=rel=>readFileSync(join(root,'..',rel),'utf8');
function installDom() {
  const html = [];
  class Text { constructor(d) { this.nodeType = 3; this.data = String(d); this.parent = null; } get textContent() { return this.data; } }
  class El {
    constructor(tag) { this.nodeType = 1; this.tagName = String(tag).toUpperCase(); this.attrs = {}; this.children = []; this.listeners = {}; this.style = {}; this.dataset = {}; this.className = ''; this.value = ''; this.parent = null;
      this.classList = { add: () => {}, remove: () => {}, toggle: () => {}, contains: () => false }; }
    set innerHTML(v) { html.push(String(v)); this.children = []; }
    get innerHTML() { return ''; }
    get textContent() { return this.children.map((c) => c.textContent).join(''); }
    set textContent(v) { this.children = [new Text(v)]; }
    get innerText() { return this.textContent; }
    setAttribute(k, v) { this.attrs[k] = String(v); if (k === 'class') this.className = String(v); if(k === 'checked') this.checked = true; if(k === 'disabled') this.disabled = true; }
    getAttribute(k) { return this.attrs[k] ?? null; }
    hasAttribute(k) { return k in this.attrs; }
    removeAttribute(k) { delete this.attrs[k]; }
    addEventListener(t, f) { (this.listeners[t] ||= []).push(f); }
    removeEventListener() {}
    append(...xs) { for (const x of xs) { if (x == null || x === false) continue; const n = x.nodeType ? x : new Text(x); n.parent = this; this.children.push(n); } }
    prepend(...xs) { this.append(...xs); }
    after() {} before() {}
    replaceChildren(...xs) { this.children = []; this.append(...xs); }
    remove() { if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this); }
    appendChild(n) { this.append(n); return n; }
    showModal() {} close() { for (const f of this.listeners.close || []) f({}); }
    focus() {} scrollIntoView() {} closest() { return null; }
    all() { return this.children.filter((c) => c.nodeType === 1).flatMap((c) => [c, ...c.all()]); }
    querySelectorAll(sel) { const m = sel.match(/^\[data-testid="?([^"\]]+)"?\]$/); return this.all().filter((e) => (m ? e.attrs['data-testid'] === m[1] : e.tagName === sel.toUpperCase())); }
    querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  }
  const body = new El('body');
  globalThis.document = { body, documentElement: new El('html'), createElement: (t) => new El(t), createElementNS: (_n, t) => new El(t), createTextNode: (t) => new Text(t), addEventListener() {}, querySelector: () => null, getElementById: () => null };
  globalThis.window = globalThis;
  globalThis.location = { hash: '#/tapahtumat', search: '?mock=1', pathname: '/hallinta/' };
  globalThis.localStorage ??= { getItem: () => null, setItem() {}, removeItem() {} };
  globalThis.matchMedia = () => ({ matches: false, addEventListener() {} });
  return { html, body };
}

const tmp = join(mkdtempSync(join(tmpdir(), 'koulutukset-')), 'admin');
cpSync(join(root, 'admin'), tmp, { recursive: true });
cpSync(join(root, 'shared/sb.js'), join(tmp, 'sb.js'));
const dom = installDom();
const sb = await import(pathToFileURL(join(tmp, 'sb.js')).href);


const koulutukset = await import(pathToFileURL(join(tmp, 'views/koulutukset.js')).href);


const flat = out => { dom.body.replaceChildren(...[out].flat(Infinity)); return dom.body; };
async function fire(el, event='click') { assert.ok(el, 'control exists'); for(const f of el.listeners[event]||[]) await f({target:el,preventDefault(){},stopPropagation(){}}); }
function setup() {
  const mock = createEventsMock({ today:'2026-11-06' });
  const r=mock.state.events.find(p=>p.category==='training').rules[0];
  mock.state.participants.push({reservation_id:9300,order_id:8300,order_no:8300,rule_id:r.id,name:'Participant <img src=x>',email:'test@example.test',persons:1,order_status:'confirmed',payment_status:'unpaid',language:'en'});
  const calls=[];
  sb.setRpcOverride(async(fn,a)=>{calls.push([fn,a]);if(fn==='public_get_site_texts')return {ok:true,texts:[]};if(!mock.handlers[fn])throw new Error('Missing '+fn);return mock.handlers[fn](a);});
  const ctx={can:()=>true,role:'manager',refs:{resources:EVENT_MOCK_RESOURCES}};
  return {mock,r,calls,ctx};
}
const show = async (s, panel='osallistujat') => flat(await koulutukset.render({ctx:s.ctx,refs:s.ctx.refs,reload(){},query:new URLSearchParams(`tapahtuma=33&kerta=${s.r.id}&valilehti=${panel}`)}));

test('cards use category, split Journey by id and hide capacity-only segments',()=>{
 const rows=[{product_id:114,category:'training',rules:[{id:1,date:'2027-03-05',ends_at:'2027-03-09',kind:'rules'}]}, {product_id:121,category:'training',rules:[{id:2,date:'2027-03-05',ends_at:'2027-03-09'}]}, {product_id:9,category:'event',rules:[{id:3,date:'2027-03-05'}]}];
 assert.deepEqual(trainingCards(rows,{group:'training',today:'2026-11-06'}).map(x=>x.p.product_id),[114]);
 assert.deepEqual(trainingCards(rows,{group:'trip',today:'2026-11-06'}).map(x=>x.p.product_id),[121]);
 assert.equal(trainingCards([{...rows[0],rules:[{...rows[0].rules[0],training_segment_only:true}]}],{today:'2026-11-06'}).length,0);
});
test('payment status is based on actual payment, not nominal signup deposit',()=>{
 assert.equal(paymentState({deposit_paid:570,paid_actual:0,due_actual:1950}),'unpaid');
 assert.equal(paymentState({paid_actual:570,due_actual:1380}),'partial');
 assert.equal(paymentState({paid_actual:1950,due_actual:0}),'paid');
});
test('space times and readiness, independent of event primary resource',()=>{
 assert.ok(validSpaceTime('2027-03-05','14:00','16:00'));
 assert.ok(!validSpaceTime('2027-03-05','16:00','14:00'));
 assert.equal(nextTrainingStep({}), 'spaces');
 assert.equal(nextTrainingStep({blocks:[{}],people:[{due_actual:20}]}),'payments');
});
test('preview gate rejects stale asynchronous preview and invalidates on edit',()=>{
 const gate=messagePreviewGate(),rev=gate.revision();gate.invalidate();assert.equal(gate.accept({id:1},rev),false);
 assert.equal(gate.read(),null);assert.ok(gate.accept({id:2},gate.revision()));gate.invalidate();assert.equal(gate.read(),null);
});
test('waiting order is stable, CSV is Excel-safe and includes practical details and attendance',()=>{
 assert.deepEqual(orderedWaiters([{id:2,created_at:'2026-11-06'},{id:1,created_at:'2026-11-06'}]).map(x=>x.id),[1,2]);
 const csv=trainingExport([{name:'=cmd()',diet:'vegan',present:true}],['Name']);
 assert.ok(csv.startsWith('\uFEFF'));assert.ok(csv.includes("'=cmd()"));assert.ok(csv.includes('vegan'));assert.ok(csv.includes(';1;'));
});
test('calendar paints every covered Helsinki day, but not the exclusive midnight end',()=>{
 const block={starts_at:'2027-03-05T20:00:00Z',ends_at:'2027-03-06T22:00:00Z'};
 assert.deepEqual([...calendarSpaceDays([block],'2027-03-01','2027-03-10').keys()],['2027-03-05','2027-03-06']);
});
test('session page has summary and four sections in fixed order, no send on render',async()=>{
 const s=setup(),host=await show(s);
 assert.ok(host.querySelector('[data-testid="training-summary"]'));
 const hrefs=host.all().map(x=>x.attrs.href||'').filter(x=>x.includes('valilehti='));
 assert.deepEqual(hrefs.filter(x=>['osallistujat','viestit','maksut','tilat'].some(k=>x.endsWith('valilehti='+k))).slice(-4).map(x=>new URLSearchParams(x.split('?')[1]).get('valilehti')),['osallistujat','viestit','maksut','tilat']);
 assert.ok(host.textContent.includes('Participant <img src=x>'));assert.equal(host.querySelectorAll('img').length,0);
 assert.ok(!s.calls.some(([fn])=>fn.endsWith('_send')));
});
test('messages require preview + explicit confirmation; an edit revokes preview',async()=>{
 const s=setup(),host=await show(s,'viestit');
 const send=host.querySelector('[data-testid="training-message-send"]');
 await fire(send);assert.ok(!s.calls.some(([fn])=>fn==='admin_training_message_send'));
 for(const lang of ['fi','en'])host.querySelector(`[data-testid="training-body-${lang}"]`).value='Completed arrival instructions';
 await fire(host.querySelector('[data-testid="training-message-preview-button"]'));
 const confirm=host.querySelector('[data-testid="training-message-confirm"]');confirm.checked=true;await fire(confirm,'change');assert.equal(send.disabled,false);
 await fire(host.querySelector('[data-testid="training-body-en"]'),'input');assert.equal(send.disabled,true);
 await fire(send);assert.ok(!s.calls.some(([fn])=>fn==='admin_training_message_send'));
 await fire(host.querySelector('[data-testid="training-message-preview-button"]'));confirm.checked=true;await fire(confirm,'change');await fire(send);
 assert.equal(s.calls.filter(([fn])=>fn==='admin_training_message_send').length,1);
 assert.equal(s.calls.find(([fn])=>fn==='admin_training_message_send')[1].p_confirm,true);
});
test('opening space form does not reserve; cancellation asks confirmation',async()=>{
 const s=setup(),host=await show(s,'tilat');await fire(host.querySelector('[data-testid="training-reserve"]'));
 assert.ok(!s.calls.some(([fn])=>fn==='admin_training_space_add'));
 assert.ok(dom.body.textContent.includes('Peruuta'));
});
test('all new FI/EN texts are in pending-import and contain no angle brackets',()=>{
 const rows=JSON.parse(read('content/site-texts.pending-import-127.json'));
 for(const lang of ['fi','en'])for(const [k,text] of Object.entries(TRAINING_TEXTS[lang])){
  assert.equal(rows.find(x=>x.key==='admin.training.'+k&&x.lang===lang)?.text,text,k);assert.doesNotMatch(text,/[<>]/);
 }
});
test('migration does not replace existing capacity/checkout functions or schedule messages',()=>{
 const sql=read('booking/supabase/migrations/20261106180719_booking_255_training_workspace.sql');
 assert.doesNotMatch(sql,/create (or replace )?function booking\.(public_create_training_signup|_training_hold_segment|_training_option_seats_left|_event_rule_res_ids|_check_claim)\(/i);
 assert.doesNotMatch(sql,/cron\.schedule|alter table public\.|create table public\./i);
 assert.match(sql,/booking\._lock_resources/);assert.match(sql,/reminders_paused_at/);
});
test.after(()=>sb.setRpcOverride(null));
