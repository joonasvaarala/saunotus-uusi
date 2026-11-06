import { assertEquals, assertMatch, assertRejects } from 'jsr:@std/assert@1';
const assert = { equal: assertEquals, deepEqual: assertEquals, match: assertMatch,
  rejects: async (fn: () => Promise<unknown>, pattern: RegExp) => { const e = await assertRejects(fn, Error); assertMatch(e.message, pattern); } };
import { runExport, type Db, type DesiredEvent, type ExportPlan, type Google, type GReadEvent } from './core.ts';
import { createGoogle } from './google.ts';

const ev: DesiredEvent = {
  event_key: 'e:block:11', kind: 'event', resource_code: 'rauni', google_calendar_id: 'rauni-calendar',
  google_event_id: 'bke00111', summary: 'Hoitosauna Rauni – training', description: 'Training room',
  starts_at: '2027-09-04T08:00:00+03:00', ends_at: '2027-09-05T09:00:00+03:00', content_hash: 'before', timezone: 'Europe/Helsinki',
};
const owned: GReadEvent = { id: ev.google_event_id, status: 'confirmed', etag: 'etag-before',
  start: { dateTime: ev.starts_at }, end: { dateTime: ev.ends_at },
  extendedProperties: { private: { booking_source: 'booking_calendar', booking_key: ev.event_key } },
};
function setup(remote: GReadEvent = owned, changed: DesiredEvent[] = [ev]) {
  const calls: string[] = []; const finishes: Record<string, unknown>[] = [];
  const plan: ExportPlan = { mode: 'live', run_id: 'lease', reconcile: true, events: [{ ...ev }], mapped: [{ ...ev, google_calendar_id: ev.google_calendar_id! }] };
  let input: Record<string, unknown>[] = [];
  const db: Db = {
    plan: async () => plan,
    applyTraining: async (id, events) => { assert.equal(id,'lease'); calls.push('apply'); input = events; return { events: changed }; },
    finish: async p => { calls.push('finish'); finishes.push(p); },
  };
  const google: Google = {
    getEvent: async (cal, id) => { assert.equal(cal, ev.google_calendar_id); assert.equal(id, ev.google_event_id); calls.push('read'); return remote; },
    insertEvent: async () => { calls.push('insert'); return 'created'; },
    patchEvent: async (_c, _i, _e, etag) => { calls.push('patch'); assert.equal(etag, 'etag-before'); return 'patched'; },
    deleteEvent: async () => { calls.push('delete'); return 'deleted'; },
  };
  return { calls, finishes, plan, db, google, input: () => input };
}
Deno.test('training: read and apply time change BEFORE reconcile, then map refreshed times with ETag', async () => {
  const after = { ...ev, starts_at: '2027-09-04T10:00:00+03:00', content_hash: 'after' };
  const f = setup({ ...owned, start: { dateTime: after.starts_at } }, [after]);
  const result = await runExport(f.db,f.google);
  assert.equal(result.ok,true); assert.deepEqual(f.calls,['read','apply','patch','finish']);
  assert.equal(f.input()[0].starts_at,after.starts_at);
  assert.equal((f.finishes[0].upserts as Record<string,unknown>[])[0].starts_at,after.starts_at);
});
Deno.test('training: minimal cancellation tombstone releases room, never inserts or resurrects it', async () => {
  const f=setup({id:ev.google_event_id,status:'cancelled'},[]);
  const result=await runExport(f.db,f.google);
  assert.equal(result.ok,true); assert.deepEqual(f.calls,['read','apply','delete','finish']);
  assert.deepEqual(f.finishes[0].deletes,[ev.event_key]);
});
Deno.test('training: off, mode dry_run and explicit dryRun never read/apply/write', async () => {
  for (const mode of ['off','dry_run','live']) {
    const f=setup();f.plan.mode=mode;
    await runExport(f.db,f.google,{dryRun:true});
    assert.deepEqual(f.calls, mode==='off'?[]:['finish']);
  }
});
Deno.test('training: first export uses existing insert path, never discovers calendar-created events', async () => {
  const f=setup();f.plan.mapped=[];
  const result=await runExport(f.db,f.google);
  assert.equal(result.inserted,1);assert.deepEqual(f.calls,['insert','finish']);
});
Deno.test('training: deleted/inactive Hallinta block only deletes mapped export, no inbound', async () => {
  const f=setup();f.plan.events=[];
  await runExport(f.db,f.google);assert.deepEqual(f.calls,['delete','finish']);
});
Deno.test('training: blocked calendar is never read/applied/written', async () => {
  const f=setup();f.plan.closure_calendar_ids=[ev.google_calendar_id!];
  await runExport(f.db,f.google);assert.deepEqual(f.calls,['finish']);
});
Deno.test('training: inbound failures fail closed and release lease without writes', async () => {
  const f=setup();f.db.applyTraining=async()=>{throw new Error('conflict');};
  const out=await runExport(f.db,f.google);
  assert.equal(out.ok,false);assert.deepEqual(f.calls,['read','finish']);
  assert.deepEqual(f.finishes[0].upserts,[]);assert.deepEqual(f.finishes[0].deletes,[]);
});
Deno.test('training: unowned, recurring, all-day and identity-mismatched events fail closed', async () => {
  for(const remote of [{...owned,extendedProperties:{}},{...owned,recurrence:['RRULE:FREQ=DAILY']},
    {...owned,start:{date:'2027-09-04'}},{...owned,id:'copied-event'}]) {
    const f=setup(remote);const out=await runExport(f.db,f.google);
    assert.equal(out.ok,false);assert.deepEqual(f.calls,['read','finish']);
  }
});
Deno.test('training: deletion racing after read never triggers missing-event reinsertion', async () => {
  const f=setup();f.google.patchEvent=async()=>{f.calls.push('patch');return 'missing';};
  const out=await runExport(f.db,f.google);
  assert.equal(out.ok,false);assert.equal(out.failed,1);
  assert.deepEqual(f.calls,['read','apply','patch','finish']);assert.deepEqual(f.finishes[0].upserts,[]);
});
Deno.test('training: precondition error after read preserves room mapping for retry', async () => {
  const f=setup();f.google.patchEvent=async()=>{throw new Error('precondition');};
  assert.equal((await runExport(f.db,f.google)).ok,false);assert.deepEqual(f.finishes[0].upserts,[]);
});
Deno.test('Google: cancelled tombstone is returned without listing', async () => {
  let n=0;const g=createGoogle((async()=>{n++;return Response.json({id:ev.google_event_id,status:'cancelled'});}) as typeof fetch,{token:async()=>'fake'});
  assert.equal((await g.getEvent!(ev.google_calendar_id!,ev.google_event_id)).status,'cancelled');assert.equal(n,1);
});
Deno.test('Google: missing event is cancellation only after successful calendar events.list', async () => {
  const urls:string[]=[];const g=createGoogle((async(input)=>{urls.push(String(input));return urls.length===1?new Response('',{status:404}):Response.json({items:[]});}) as typeof fetch,{token:async()=>'fake'});
  assert.equal((await g.getEvent!(ev.google_calendar_id!,ev.google_event_id)).status,'cancelled');
  assert.equal(urls.length,2);assert.match(urls[1],/showDeleted=true/);
});
Deno.test('Google: lost calendar sharing is an error, never a room cancellation', async () => {
  const g=createGoogle((async()=>new Response('',{status:404})) as typeof fetch,{token:async()=>'fake'});
  await assert.rejects(()=>g.getEvent!(ev.google_calendar_id!,ev.google_event_id),/404/);
});
Deno.test('Google: training conditional patch sends If-Match and propagates 412', async () => {
  const g=createGoogle((async(_url,opts)=>{assert.equal((opts!.headers as Record<string,string>)['if-match'],'etag-before');return new Response('',{status:412});}) as typeof fetch,{token:async()=>'fake'});
  await assert.rejects(()=>g.patchEvent('rauni-calendar',ev.google_event_id,{} as never,'etag-before'),/412/);
});
Deno.test('Google: insert into missing calendar cannot be recorded as created', async () => {
  const g=createGoogle((async()=>new Response('',{status:404})) as typeof fetch,{token:async()=>'fake'});
  await assert.rejects(()=>g.insertEvent('missing-calendar',{} as never),/404/);
});

Deno.test('training: interrupted first export recovers mapping only for unchanged owned event', async () => {
  const f=setup();f.plan.mapped=[];f.google.insertEvent=async()=>{f.calls.push('insert');return 'exists';};
  const out=await runExport(f.db,f.google);
  assert.equal(out.ok,true);assert.deepEqual(f.calls,['insert','read','finish']);
  assert.equal((f.finishes[0].upserts as unknown[]).length,1);
});
Deno.test('training: edited/cancelled first-export orphan is never overwritten or adopted', async () => {
  for(const remote of [{...owned,start:{dateTime:'2027-09-04T10:00:00+03:00'}},{id:ev.google_event_id,status:'cancelled'}]) {
    const f=setup(remote);f.plan.mapped=[];f.google.insertEvent=async()=>{f.calls.push('insert');return 'exists';};
    const out=await runExport(f.db,f.google);
    assert.equal(out.ok,false);assert.deepEqual(f.calls,['insert','read','finish']);assert.deepEqual(f.finishes[0].upserts,[]);
  }
});
