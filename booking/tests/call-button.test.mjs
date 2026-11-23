// Terassin kutsunappi (booking_340–342): call-button-press / call-button-hangup ja Shelly-skriptin jäsennys.
// Mockattu RPC ja 46elks-mock: ei verkkoa, ei kantaa, ei oikeita soittoja.
// Ajo: node --test booking/tests/call-button.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import vm from 'node:vm';
import {
  voiceStartFor, handlePress, handleHangup, hmacHex, hangupSigMessage, safeEqual, mapHangupState, audioUrlFor, ELKS_CALLS_URL,
} from '../supabase/functions/_shared/call_button.js';

const SECRET = 'test-webhook-secret-123';
const PHONE = '+358401234567';
const baseEnv = {
  CALL_BUTTON_WEBHOOK_SECRET: SECRET, ELKS_API_USERNAME: 'u_test', ELKS_API_PASSWORD: 'p_test',
  ELKS_FROM_NUMBER: '+358900000000', SUPABASE_URL: 'https://proj.supabase.co',
};
const envOf = (o) => ({ get: (k) => o[k] });

function mocks({ press, result, env = baseEnv, elks } = {}) {
  const calls = { rpc: [], fetch: [], logs: [] };
  let pressQueue = Array.isArray(press) ? [...press] : null;
  const rpc = async (fn, args) => {
    calls.rpc.push({ fn, args });
    if (fn === 'svc_call_button_press') {
      const r = pressQueue ? pressQueue.shift() : press;
      return typeof r === 'function' ? r(args) : r;
    }
    if (fn === 'svc_call_button_result') return result ? result(args) : { data: { ok: true, press_id: args.p_press_id, call_status: args.p_status, attempt_no: 1 }, error: null };
    throw new Error('tuntematon rpc ' + fn);
  };
  let n = 0;
  const fetch = async (url, init) => {
    calls.fetch.push({ url, init });
    if (elks) return elks(url, init);
    n += 1;
    return new Response(JSON.stringify({ id: 'c' + n, state: 'ongoing', direction: 'outgoing' }), { status: 200 });
  };
  return { deps: { rpc, fetch, env: envOf(env), log: (...a) => calls.logs.push(a.join(' ')) }, calls };
}
const pressReq = (body, secret = SECRET) => new Request('https://x/functions/v1/call-button-press', {
  method: 'POST', headers: { 'content-type': 'application/json', ...(secret !== null ? { 'x-call-button-secret': secret } : {}) },
  body: JSON.stringify(body),
});
const BODY = { mac: 'aa:bb:cc:dd:ee:01', pid: 12, event: 'single_push', gateway: 'gw-mokki', rssi: -70, battery: 95 };
const callRes = (id, extra = {}) => ({ data: { ok: true, duplicate: false, call: true, call_status: 'pending', press_id: id, repeat_of: null,
  device: 'Mökki', place_name: 'mökki', message: 'Asiakas odottaa mökissä.', staff_id: 's1', staff_name: 'X',
  role: 'reception', phone: PHONE, phone_masked: '+358…67', attempt_no: 1, ...extra }, error: null });
const noLeak = (calls, res) => {
  const all = calls.logs.join('\n') + (res ?? '');
  for (const s of [PHONE, '401234567', SECRET, 'p_test', 'u_test']) assert.ok(!all.includes(s), 'vuoto: ' + s);
};

test('väärä tai puuttuva salaisuus → 401, ei RPC:tä', async () => {
  for (const s of ['wrong', '', null, SECRET + 'x', SECRET.slice(0, -1)]) {
    const { deps, calls } = mocks({ press: callRes(1) });
    const r = await handlePress(pressReq(BODY, s), deps);
    assert.equal(r.status, 401);
    assert.equal(calls.rpc.length, 0); assert.equal(calls.fetch.length, 0);
  }
});

test('salaisuus puuttuu ympäristöstä → 500 misconfigured, ei RPC:tä', async () => {
  const { deps, calls } = mocks({ press: callRes(1), env: { ...baseEnv, CALL_BUTTON_WEBHOOK_SECRET: '' } });
  const r = await handlePress(pressReq(BODY, ''), deps);
  assert.equal(r.status, 500); assert.equal(calls.rpc.length, 0);
});

test('vain POST', async () => {
  const { deps } = mocks({ press: callRes(1) });
  assert.equal((await handlePress(new Request('https://x/', { method: 'GET' }), deps)).status, 405);
  assert.equal((await handleHangup(new Request('https://x/', { method: 'GET' }), deps)).status, 405);
});

test('RPC saa oikeat parametrit', async () => {
  const { deps, calls } = mocks({ press: { data: { ok: true, duplicate: false, call: false, call_status: 'disabled', press_id: 5 }, error: null } });
  await handlePress(pressReq(BODY), deps);
  assert.deepEqual(calls.rpc[0], { fn: 'svc_call_button_press', args: { p_mac: BODY.mac, p_pid: 12, p_gateway: 'gw-mokki', p_event: 'single_push' } });
});

for (const [name, data] of [
  ['duplicate', { ok: true, duplicate: true, call: false, press_id: 7, place_name: 'mökki', call_status: 'calling' }],
  ['disabled', { ok: true, duplicate: false, call: false, call_status: 'disabled', press_id: 8, phone: null, phone_masked: '+358…67', attempt_no: 0 }],
  ['buffered (booking_342: sama nappi < 60 s)', { ok: true, duplicate: false, call: false, call_status: 'buffered', press_id: 9, repeat_of: 4, attempt_no: 0 }],
  ['no_recipient', { ok: true, duplicate: false, call: false, call_status: 'no_recipient', press_id: 10, attempt_no: 0 }],
  ['ignored', { ok: true, duplicate: false, call: false, call_status: 'ignored', press_id: 11, attempt_no: 0 }],
  ['unknown_device', { ok: false, code: 'unknown_device', press_id: 12, call: false }],
  ['call puuttuu / ei tiukasti true', { ok: true, duplicate: false, call: 'true', call_status: 'pending', press_id: 13, phone: PHONE }],
]) {
  test(`${name} → ei soittoa, ei tulosta, 200`, async () => {
    const { deps, calls } = mocks({ press: { data, error: null } });
    const r = await handlePress(pressReq(BODY), deps);
    assert.equal(r.status, 200);
    const j = await r.json();
    assert.equal(j.call, false);
    assert.equal(calls.fetch.length, 0);
    assert.equal(calls.rpc.filter((c) => c.fn === 'svc_call_button_result').length, 0);
    noLeak(calls, JSON.stringify(j));
  });
}

test('call=true → tasan yksi 46elks-POST ja result calling', async () => {
  const { deps, calls } = mocks({ press: callRes(21) });
  const r = await handlePress(pressReq(BODY), deps);
  const j = await r.json();
  assert.equal(r.status, 200);
  assert.deepEqual(j, { ok: true, call: true, call_status: 'calling', press_id: 21, attempt_no: 1 });
  assert.equal(calls.fetch.length, 1);
  const { url, init } = calls.fetch[0];
  assert.equal(url, ELKS_CALLS_URL);
  assert.equal(init.method, 'POST');
  assert.equal(init.headers.authorization, 'Basic ' + btoa('u_test:p_test'));
  const f = new URLSearchParams(init.body);
  assert.equal(f.get('from'), '+358900000000');
  assert.equal(f.get('to'), PHONE);
  assert.equal(f.get('timeout'), '30');
  assert.deepEqual(JSON.parse(f.get('voice_start')), { play: 'https://saunotus.fi/call-button/mokki.mp3' });
  const wh = new URL(f.get('whenhangup'));
  assert.equal(wh.origin + wh.pathname, 'https://proj.supabase.co/functions/v1/call-button-hangup');
  assert.equal(wh.searchParams.get('press_id'), '21');
  assert.equal(wh.searchParams.get('attempt'), '1');
  assert.equal(wh.searchParams.get('sig'), await hmacHex(SECRET, '21.1'));
  const res = calls.rpc.filter((c) => c.fn === 'svc_call_button_result');
  assert.deepEqual(res, [{ fn: 'svc_call_button_result', args: { p_press_id: 21, p_status: 'calling', p_provider_call_id: 'c1', p_error: null } }]);
  noLeak(calls, JSON.stringify(j));
});

test('yläterassi valitsee oman mp3:n; tuntematon paikka → ei toistoa (hangup), CALL_BUTTON_AUDIO_BASE', async () => {
  assert.equal(audioUrlFor('yläterassi'), 'https://saunotus.fi/call-button/ylaterassi.mp3');
  assert.equal(audioUrlFor('Mökki'), 'https://saunotus.fi/call-button/mokki.mp3');
  assert.equal(audioUrlFor('mökissä'), 'https://saunotus.fi/call-button/mokki.mp3');
  assert.equal(audioUrlFor('yläterassilla'), 'https://saunotus.fi/call-button/ylaterassi.mp3');
  assert.equal(audioUrlFor('sauna 3'), null);
  assert.equal(audioUrlFor(null), null);
  assert.equal(audioUrlFor('mökki', 'https://cdn.test/a'), 'https://cdn.test/a/mokki.mp3');
  assert.deepEqual(JSON.parse(voiceStartFor('sauna 3')), { hangup: 'reject' });
  const { deps, calls } = mocks({ press: callRes(22, { place_name: 'yläterassi' }) });
  await handlePress(pressReq(BODY), deps);
  assert.deepEqual(JSON.parse(new URLSearchParams(calls.fetch[0].init.body).get('voice_start')), { play: 'https://saunotus.fi/call-button/ylaterassi.mp3' });
});

test('tuntematon paikka → soitto silti kerran, voice_start ilman play-toimintoa', async () => {
  const { deps, calls } = mocks({ press: callRes(23, { place_name: 'piha' }) });
  const j = await (await handlePress(pressReq(BODY), deps)).json();
  assert.equal(j.call_status, 'calling'); assert.equal(calls.fetch.length, 1);
  const vs = new URLSearchParams(calls.fetch[0].init.body).get('voice_start');
  assert.deepEqual(JSON.parse(vs), { hangup: 'reject' });
  assert.ok(!vs.includes('play') && !vs.includes('.mp3'));
});

test('kaksi eri painallusta → kaksi soittoa; kahden gatewayn sama pid → yksi soitto', async () => {
  const dup = { data: { ok: true, duplicate: true, call: false, press_id: 31, place_name: 'mökki', call_status: 'calling' }, error: null };
  const { deps, calls } = mocks({ press: [callRes(31), dup, callRes(32)] });
  await handlePress(pressReq({ ...BODY, pid: 40, gateway: 'gw-mokki' }), deps);
  await handlePress(pressReq({ ...BODY, pid: 40, gateway: 'gw-ylaterassi' }), deps);
  await handlePress(pressReq({ ...BODY, pid: 41 }), deps);
  assert.equal(calls.fetch.length, 2);
  const res = calls.rpc.filter((c) => c.fn === 'svc_call_button_result').map((c) => [c.args.p_press_id, c.args.p_status]);
  assert.deepEqual(res, [[31, 'calling'], [32, 'calling']]);
});

test('46elks POST-virhe → failed, ei uusintaa, numero ei päädy virheeseen', async () => {
  const { deps, calls } = mocks({ press: callRes(41), elks: async () => new Response(`Invalid to number ${PHONE}`, { status: 403 }) });
  const r = await handlePress(pressReq(BODY), deps);
  const j = await r.json();
  assert.equal(r.status, 200); assert.equal(j.call_status, 'failed');
  assert.equal(calls.fetch.length, 1);
  const res = calls.rpc.filter((c) => c.fn === 'svc_call_button_result');
  assert.equal(res.length, 1);
  assert.equal(res[0].args.p_status, 'failed');
  assert.equal(res[0].args.p_provider_call_id, null);
  assert.match(res[0].args.p_error, /^http 403: Invalid to number \[num\]$/);
  noLeak(calls, JSON.stringify(j) + JSON.stringify(res));
});

test('46elks verkkovirhe → failed network_error, ei uusintaa', async () => {
  const { deps, calls } = mocks({ press: callRes(42), elks: async () => { throw new TypeError('fetch failed'); } });
  const j = await (await handlePress(pressReq(BODY), deps)).json();
  assert.equal(j.call_status, 'failed'); assert.equal(calls.fetch.length, 1);
  assert.equal(calls.rpc.at(-1).args.p_error, 'network_error: TypeError');
});

test('ELKS_FROM_NUMBER puuttuu → ei soittoa, failed missing_from_number', async () => {
  const { deps, calls } = mocks({ press: callRes(51), env: { ...baseEnv, ELKS_FROM_NUMBER: '' } });
  const j = await (await handlePress(pressReq(BODY), deps)).json();
  assert.equal(calls.fetch.length, 0);
  assert.equal(j.call_status, 'failed'); assert.equal(j.error, 'missing_from_number');
  assert.deepEqual(calls.rpc.at(-1).args, { p_press_id: 51, p_status: 'failed', p_provider_call_id: null, p_error: 'missing_from_number' });
});

test('ELKS-tunnukset puuttuvat → ei soittoa, failed missing_elks_credentials', async () => {
  const { deps, calls } = mocks({ press: callRes(52), env: { ...baseEnv, ELKS_API_PASSWORD: '' } });
  const j = await (await handlePress(pressReq(BODY), deps)).json();
  assert.equal(calls.fetch.length, 0); assert.equal(j.error, 'missing_elks_credentials');
});

test('RPC-virhe → 503 (gateway saa uusia, kanta deduppaa), ei soittoa', async () => {
  const { deps, calls } = mocks({ press: { data: null, error: { code: 'XX000', message: 'boom' } } });
  const r = await handlePress(pressReq(BODY), deps);
  assert.equal(r.status, 503); assert.equal(calls.fetch.length, 0);
});

test('virheellinen JSON → 400, virheellinen pid → ei RPC:tä', async () => {
  const { deps, calls } = mocks({ press: callRes(1) });
  const bad = new Request('https://x/', { method: 'POST', headers: { 'x-call-button-secret': SECRET }, body: '{nope' });
  assert.equal((await handlePress(bad, deps)).status, 400);
  const j = await (await handlePress(pressReq({ ...BODY, pid: 'x' }), deps)).json();
  assert.equal(j.code, 'invalid_pid'); assert.equal(calls.rpc.length, 0);
});

// ---------- hangup ----------
const hangupReq = async (pressId, attempt, form, sig) => {
  const s = sig ?? await hmacHex(SECRET, hangupSigMessage(pressId, attempt));
  return new Request(`https://proj.supabase.co/functions/v1/call-button-hangup?press_id=${pressId}&attempt=${attempt}&sig=${s}`, {
    method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(form).toString(),
  });
};

test('hangup: väärä allekirjoitus → 401, ei RPC:tä', async () => {
  const { deps, calls } = mocks();
  for (const sig of ['00', await hmacHex(SECRET, '22.1'), await hmacHex('other', '21.1'), '']) {
    const r = await handleHangup(await hangupReq(21, 1, { state: 'success', id: 'c1' }, sig), deps);
    assert.equal(r.status, 401);
  }
  assert.equal(calls.rpc.length, 0);
});

test('hangup: tilakartoitus success/busy/failed', async () => {
  const cases = [
    [{ state: 'success', id: 'c1', start: '2026-11-23T20:00:01', duration: '5' }, 'answered', null],
    [{ state: 'busy', id: 'c1' }, 'busy', null],
    [{ state: 'failed', id: 'c1', duration: '0' }, 'no_answer', null],
    [{ state: 'failed', id: 'c1', start: '2026-11-23T20:00:01' }, 'failed', '46elks state=failed'],
    [{ state: 'weird', id: 'c1' }, 'failed', '46elks state=weird'],
  ];
  for (const [form, status, err] of cases) {
    const { deps, calls } = mocks();
    const r = await handleHangup(await hangupReq(21, 1, { ...form, from: '+358900000000', to: PHONE }), deps);
    assert.equal(r.status, 200);
    assert.deepEqual(calls.rpc, [{ fn: 'svc_call_button_result', args: { p_press_id: 21, p_status: status, p_provider_call_id: 'c1', p_error: err } }]);
    assert.deepEqual(await r.json(), { ok: true, press_id: 21, call_status: status, attempt_no: 1 });
    assert.equal(calls.fetch.length, 0, 'hangup ei soita koskaan');
    noLeak(calls);
  }
  assert.deepEqual(mapHangupState('SUCCESS'), { status: 'answered', error: null });
});

test('hangup: late → late:true, ei toimenpiteitä', async () => {
  const { deps, calls } = mocks({ result: () => ({ data: { ok: true, press_id: 21, call_status: 'answered', late: true }, error: null }) });
  const r = await handleHangup(await hangupReq(21, 1, { state: 'failed', id: 'c-old' }), deps);
  const j = await r.json();
  assert.equal(r.status, 200); assert.equal(j.late, true); assert.equal(j.call_status, 'answered');
  assert.equal(calls.fetch.length, 0);
});

test('hangup: kannan ok:false → 200 koodilla (46elks ei toista); RPC-virhe → 503', async () => {
  const a = mocks({ result: () => ({ data: { ok: false, code: 'not_calling' }, error: null }) });
  const r1 = await handleHangup(await hangupReq(21, 1, { state: 'busy', id: 'c1' }), a.deps);
  assert.equal(r1.status, 200); assert.deepEqual(await r1.json(), { ok: false, code: 'not_calling', press_id: 21 });
  const b = mocks({ result: () => ({ data: null, error: { message: 'down' } }) });
  assert.equal((await handleHangup(await hangupReq(21, 1, { state: 'busy', id: 'c1' }), b.deps)).status, 503);
});

test('hangup: virheelliset parametrit → 400', async () => {
  const { deps } = mocks();
  const r = await handleHangup(new Request('https://x/?press_id=abc&attempt=1&sig=00', { method: 'POST', body: '' }), deps);
  assert.equal(r.status, 400);
});

test('safeEqual', () => {
  assert.equal(safeEqual('abc', 'abc'), true);
  assert.equal(safeEqual('abc', 'abd'), false);
  assert.equal(safeEqual('abc', 'ab'), false);
  assert.equal(safeEqual('', ''), true);
  assert.equal(safeEqual('a', undefined), false);
});

// ---------- Shelly-skripti ----------
function loadShelly(kvs = { cb_url: 'https://proj.supabase.co/functions/v1/call-button-press', cb_secret: SECRET, cb_gateway: 'gw-mokki' }, httpCodes = []) {
  const src = readFileSync(new URL('../shelly/call-button-gateway.js', import.meta.url), 'utf8');
  const posts = [], timers = [], prints = [];
  let sub = null;
  const ctx = {
    print: (s) => prints.push(s),
    Shelly: {
      getDeviceInfo: () => ({ id: 'shellyblugwg3-test' }),
      call: (method, params, cb) => {
        if (method === 'KVS.Get') return cb(kvs[params.key] !== undefined ? { value: kvs[params.key] } : null, kvs[params.key] !== undefined ? 0 : -105);
        if (method === 'HTTP.Request') { posts.push(params); const c = httpCodes.length ? httpCodes.shift() : 200; return cb(c ? { code: c } : null, c ? 0 : -1, c ? '' : 'timeout'); }
        throw new Error(method);
      },
    },
    BLE: { Scanner: { SCAN_RESULT: 2, INFINITE_SCAN: -1, isRunning: () => true, Start: () => {}, Subscribe: (f) => { sub = f; } } },
    Timer: { set: (ms, rep, cb) => { timers.push(ms); cb(); } },
  };
  vm.createContext(ctx);
  vm.runInContext(src, ctx);
  return { ctx, posts, timers, prints, scan: (addr, bytes) => sub(2, { addr, rssi: -60, service_data: { fcd2: String.fromCharCode(...bytes) } }) };
}

test('Shelly: BTHome v2 button-eventit 1–6, 0x80 → nimet; 0 ohitetaan; muu → press', () => {
  const s = loadShelly();
  const want = { 1: 'single_push', 2: 'double_push', 3: 'triple_push', 4: 'long_push', 5: 'long_double_push', 6: 'long_triple_push', 0x80: 'hold', 0x10: 'press' };
  let pid = 0;
  for (const [v, name] of Object.entries(want)) {
    s.scan('AA:BB:CC:DD:EE:01', [0x44, 0x00, ++pid, 0x01, 0x5f, 0x3a, Number(v)]);
    const p = s.posts.at(-1);
    assert.deepEqual(JSON.parse(p.body), { mac: 'aa:bb:cc:dd:ee:01', pid, event: name, gateway: 'gw-mokki', rssi: -60, battery: 95 });
    assert.equal(p.headers['x-call-button-secret'], SECRET);
    assert.equal(p.method, 'POST');
  }
  const n = s.posts.length;
  s.scan('AA:BB:CC:DD:EE:01', [0x44, 0x00, 99, 0x3a, 0x00]); // none
  assert.equal(s.posts.length, n);
  assert.ok(!s.prints.join('\n').includes(SECRET));
});

test('Shelly: sama pid toistuva mainos → yksi POST; muut BTHome-paketit ja salatut ohitetaan', () => {
  const s = loadShelly();
  s.scan('aa:bb:cc:dd:ee:02', [0x44, 0x00, 7, 0x3a, 0x01]);
  s.scan('aa:bb:cc:dd:ee:02', [0x44, 0x00, 7, 0x3a, 0x01]);
  assert.equal(s.posts.length, 1);
  s.scan('aa:bb:cc:dd:ee:03', [0x44, 0x00, 1, 0x02, 0x10, 0x09]); // lämpötila, ei nappia
  s.scan('aa:bb:cc:dd:ee:04', [0x45, 0x00, 1, 0x3a, 0x01]); // salattu
  s.scan('aa:bb:cc:dd:ee:05', [0x24, 0x00, 1, 0x3a, 0x01]); // BTHome v1
  assert.equal(s.posts.length, 1);
});

test('Shelly: uusinnat 2× (1 s, 3 s) verkkovirheelle ja 5xx:lle, ei 401:lle', () => {
  const a = loadShelly(undefined, [0, 503, 200]);
  a.scan('aa:bb:cc:dd:ee:06', [0x44, 0x00, 1, 0x3a, 0x01]);
  assert.equal(a.posts.length, 3); assert.deepEqual(a.timers, [1000, 3000]);
  const b = loadShelly(undefined, [500, 500, 500, 500]);
  b.scan('aa:bb:cc:dd:ee:06', [0x44, 0x00, 1, 0x3a, 0x01]);
  assert.equal(b.posts.length, 3, 'enintään 1 + 2 yritystä');
  const c = loadShelly(undefined, [401]);
  c.scan('aa:bb:cc:dd:ee:06', [0x44, 0x00, 1, 0x3a, 0x01]);
  assert.equal(c.posts.length, 1);
});

test('Shelly: gateway-oletus laitteen id, KVS-puute ei lähetä', () => {
  const a = loadShelly({ cb_url: 'https://x', cb_secret: 's' });
  a.scan('aa:bb:cc:dd:ee:07', [0x44, 0x00, 1, 0x3a, 0x01]);
  assert.equal(JSON.parse(a.posts[0].body).gateway, 'shellyblugwg3-test');
  const b = loadShelly({});
  b.scan('aa:bb:cc:dd:ee:07', [0x44, 0x00, 1, 0x3a, 0x01]);
  assert.equal(b.posts.length, 0);
});

test('mp3-tiedostot: vain mokki ja ylaterassi, MP3-muotoa; vanha yleistiedosto poistettu (t1928u)', () => {
  for (const f of ['mokki', 'ylaterassi']) {
    const b = readFileSync(new URL(`../../public/call-button/${f}.mp3`, import.meta.url));
    assert.ok(b.length > 10000 && b.length < 200000, f);
    assert.ok((b[0] === 0x49 && b[1] === 0x44 && b[2] === 0x33) || (b[0] === 0xff && (b[1] & 0xe0) === 0xe0), f + ' ei MP3');
  }
  assert.deepEqual(readdirSync(new URL('../../public/call-button/', import.meta.url)).sort(), ['mokki.mp3', 'ylaterassi.mp3']);
});

test('puhelun ja asennusohjeen teksteissä ei Joonaksen kieltämiä sanoja (t1928u)', () => {
  for (const rel of ['../supabase/functions/_shared/call_button.js', '../shelly/call-button-gateway.js', '../shelly/README.md',
    '../supabase/functions/call-button-press/index.ts', '../supabase/functions/call-button-hangup/index.ts']) {
    const t = readFileSync(new URL(rel, import.meta.url), 'utf8').toLowerCase();
    const banned = [['h', '\u00e4lyty'], ['h', 'alyty'], ['ap', 'ua']].map((x) => x.join(''));
    for (const w of banned) assert.ok(!t.includes(w), rel + ': ' + w);
  }
});
