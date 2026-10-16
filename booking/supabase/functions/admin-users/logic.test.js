// Ajo: node --test booking/supabase/functions/admin-users/logic.test.js   tai   deno test booking/supabase/functions/admin-users/logic.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { validateRequest, ROLE_WHITELIST, parseAllowedOrigins, corsHeaders, isOriginAllowed, resolveRedirect, mapDbError, isUuid, normalizeEmail } from './logic.js';

const U = '00000000-0000-4000-8000-0000000000a1';
test('rooliwhitelist ei sisällä asiakasrooleja', () => {
  assert.deepEqual([...ROLE_WHITELIST], ['admin', 'manager', 'staff']);
  for (const r of ['customer', 'annual_card', '', 'ADMIN', 'root', null, undefined, 1, ['admin']]) {
    const v = validateRequest({ action: 'invite', email: 'a@b.fi', name: 'Aa', role: r });
    assert.equal(v.ok, false, String(r)); assert.equal(v.code, 'invalid_role');
  }
});
test('invite: kelvollinen pyyntö normalisoidaan', () => {
  const v = validateRequest({ action: 'invite', email: '  Matti.Meikalainen@Example.FI ', name: '  Matti   Meikäläinen ', role: 'manager' });
  assert.deepEqual(v, { ok: true, action: 'invite', email: 'matti.meikalainen@example.fi', name: 'Matti Meikäläinen', role: 'manager' });
});
test('invite: virheelliset sähköpostit hylätään', () => {
  for (const e of ['', 'abc', 'a@b', 'a b@c.fi', 'a@b.c', '<x>@y.fi', 'a@b.fi,c@d.fi', undefined, null, 5, 'x'.repeat(250) + '@y.fi']) {
    assert.equal(validateRequest({ action: 'invite', email: e, name: 'N', role: 'staff' }).code, 'invalid_email', String(e).slice(0, 20));
  }
});
test('invite: nimi pakollinen, max 100, ei ohjausmerkkejä eikä <>', () => {
  for (const n of ['', '   ', 'x'.repeat(101), 'a<b', 'a\u0000b', undefined, 7]) assert.equal(validateRequest({ action: 'invite', email: 'a@b.fi', name: n, role: 'staff' }).code, 'invalid_name');
  assert.equal(validateRequest({ action: 'invite', email: 'a@b.fi', name: 'x'.repeat(100), role: 'staff' }).ok, true);
});
test('tuntematon toiminto, runko ja ylimääräiset kentät hylätään', () => {
  for (const b of [null, undefined, 'x', 5, [], {}, { action: 'delete' }, { action: 'deleteUser', user_id: U }]) assert.equal(validateRequest(b).ok, false);
  assert.equal(validateRequest({ action: 'invite', email: 'a@b.fi', name: 'N', role: 'staff', is_admin: true }).code, 'unknown_field');
  assert.equal(validateRequest({ action: 'deactivate', user_id: U, role: 'admin' }).code, 'unknown_field');
});
test('deactivate/reactivate: vaatii UUID:n', () => {
  for (const a of ['deactivate', 'reactivate']) {
    assert.deepEqual(validateRequest({ action: a, user_id: U.toUpperCase() }), { ok: true, action: a, user_id: U });
    for (const id of ['', 'abc', U + 'x', "' or 1=1 --", undefined, null, 1]) assert.equal(validateRequest({ action: a, user_id: id }).code, 'invalid_user_id');
  }
  assert.equal(isUuid(U), true); assert.equal(normalizeEmail(' A@B.FI '), 'a@b.fi'); assert.equal(normalizeEmail(5), '');
});
test('CORS: vain sallitut originit, ei jokerimerkkiä', () => {
  const allowed = parseAllowedOrigins(' https://hallinta.example.fi/ , http://localhost:4180,*, ');
  assert.deepEqual(allowed, ['https://hallinta.example.fi', 'http://localhost:4180']);
  assert.equal(isOriginAllowed('https://hallinta.example.fi', allowed), true);
  assert.equal(isOriginAllowed('https://evil.example', allowed), false);
  assert.equal(isOriginAllowed('https://hallinta.example.fi.evil.example', allowed), false);
  assert.equal(isOriginAllowed(undefined, allowed), false);
  assert.equal(corsHeaders('https://evil.example', allowed), null);
  assert.equal(corsHeaders('http://localhost:4180', allowed)['Access-Control-Allow-Origin'], 'http://localhost:4180');
  assert.equal(corsHeaders('http://localhost:4180', parseAllowedOrigins('')), null);
  assert.deepEqual(parseAllowedOrigins('*'), []);
});
test('kutsulinkin kohde: https tai localhost', () => {
  assert.equal(resolveRedirect({ SITE_URL: 'https://hallinta.example.fi/' }), 'https://hallinta.example.fi/admin/');
  assert.equal(resolveRedirect({ INVITE_REDIRECT_URL: 'https://x.example.fi/hallinta/', SITE_URL: 'https://y.example.fi' }), 'https://x.example.fi/hallinta/');
  assert.equal(resolveRedirect({ SITE_URL: 'http://localhost:4180' }), 'http://localhost:4180/admin/');
  assert.equal(resolveRedirect({ SITE_URL: 'http://example.fi' }), null);
  assert.equal(resolveRedirect({ SITE_URL: 'javascript:alert(1)' }), null);
  assert.equal(resolveRedirect({}), null);
});
test('tietokantavirheet kartoitetaan, tuntematon ei vuoda sisäisiä tietoja', () => {
  assert.equal(mapDbError({ details: 'last_admin' }).status, 409);
  assert.equal(mapDbError({ details: 'cannot_change_self' }).status, 409);
  assert.equal(mapDbError({ details: 'forbidden' }).status, 403);
  const x = mapDbError({ message: 'relation "auth.users" secret detail', details: 'select * from x' });
  assert.deepEqual(x, { status: 500, code: 'internal', message: 'Palvelinvirhe' });
  assert.equal(mapDbError(null).status, 500);
});
