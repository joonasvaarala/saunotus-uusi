// LOCAL ONLY: stdin is the actual LOCAL SQL export plan. No credentials or network client.
import { runExport, planOps } from '../../functions/booking-calendar-sync/core.ts';
let input = ''; for await (const s of process.stdin) input += s;
const { plan, fail = false } = JSON.parse(input); let payload; const calls = [];
const result = await runExport({ plan: async () => ({ ...plan, mode: 'live' }), finish: async (p) => { payload = p; } }, {
  deleteEvent: async (calendar, id) => { calls.push({ calendar, id }); if (fail) throw new Error('synthetic LOCAL deletion failure'); return 'gone'; },
  insertEvent: async () => { throw new Error('unexpected insert'); }, patchEvent: async () => { throw new Error('unexpected patch'); }
});
console.log(JSON.stringify({ result, payload, calls, ops: planOps(plan).ops }));
