// YHT-08: kokeilutila (?mock=1) avaa myös Resurssit, Kalenterisulut, Käyttäjät ja asiakasnäkymän (views-mock.js). Ei verkkokutsuja.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createAdminMock } from '../admin/options-mock.js';

const read = (p) => readFileSync(new URL(`../${p}`, import.meta.url), 'utf8');
const used = (f) => [...read(`admin/views/${f}`).matchAll(/(?:rpc|select)\('([a-z_]+)'/g)].map((m) => (m[0].startsWith('select') ? `select:${m[1]}` : m[1]));

test('näkymien latauskutsut on mockattu kaikilla rooleilla, joilla näkymä on sallittu', async () => {
  const views = { 'resources.js': ['select:schedule_rules', 'select:space_blocks'], 'closures.js': ['admin_closure_overview'], 'users.js': ['admin_list_staff', 'admin_list_roles', 'admin_list_public_staff'], 'customer-view.js': ['admin_get_customer'] };
  for (const [f, need] of Object.entries(views)) for (const n of need) assert.ok(used(f).includes(n), `${f} käyttää ${n}`);
  for (const role of ['admin', 'manager']) {
    const m = createAdminMock({ role });
    assert.ok(m.state.perms.includes('blocks.manage') && m.state.perms.includes('resources.edit') && m.state.perms.includes('rules.edit'), role);
    for (const n of Object.values(views).flat()) {
      if (n === 'admin_list_staff' && role !== 'admin') continue;
      await m.rpc(n, n === 'admin_get_customer' ? { p_id: 1 } : {});
    }
  }
  await assert.rejects(createAdminMock({ role: 'manager' }).rpc('admin_list_staff'), /staff\.manage/);
});

test('mock-data on näkymien muotoista: säännöt, sulut, kalenterit, käyttäjät ja asiakas', async () => {
  const m = createAdminMock({ role: 'admin' });
  const rules = await m.rpc('select:schedule_rules');
  assert.ok(rules.length > 0);
  for (const r of rules) { assert.ok(Array.isArray(r.weekdays) && /^\d\d:\d\d:\d\d$/.test(r.start_time) && r.duration_minutes > 0); }
  const blocks = await m.rpc('select:space_blocks');
  assert.ok(blocks.every((b) => b.space_id && b.starts_at < b.ends_at));
  const ov = await m.rpc('admin_closure_overview', { p_days: 60 });
  assert.ok(ov.calendars.length && Array.isArray(ov.events) && Array.isArray(ov.conflicts) && Array.isArray(ov.runs));
  const ev = ov.events.find((e) => e.effective_block);
  const r = await m.rpc('admin_set_closure_override', { p_event_id: ev.id, p_override: 'ignore', p_note: null });
  assert.equal(r.blocks_deleted, 1);
  assert.equal((await m.rpc('admin_closure_overview')).events.find((e) => e.id === ev.id).effective_block, false);
  const staff = await m.rpc('admin_list_staff');
  assert.ok(staff.some((s) => !s.active) && staff.every((s) => s.user_id && s.role));
  await m.rpc('admin_set_staff_role', { p_user_id: staff[1].user_id, p_role: 'manager' });
  assert.equal((await m.rpc('admin_list_staff'))[1].role, 'manager');
  await assert.rejects(m.rpc('admin_set_staff_role', { p_user_id: staff[1].user_id, p_role: 'bot' }), /rooli/i);
  const c = await m.rpc('admin_get_customer', { p_id: 1 });
  assert.equal(c.id, 1); assert.ok(Array.isArray(c.orders) && Array.isArray(c.annual_cards));
  await assert.rejects(m.rpc('admin_get_customer', { p_id: 99999 }), /ei löydy/);
  const b = await m.rpc('admin_create_block', { p_space_id: 1, p_starts_at: '2099-01-01T10:00:00Z', p_ends_at: '2099-01-01T12:00:00Z', p_reason: 'testi' });
  assert.ok((await m.rpc('select:space_blocks')).some((x) => x.id === b.id));
  await m.rpc('admin_delete_block', { p_id: b.id });
  assert.ok(!(await m.rpc('select:space_blocks')).some((x) => x.id === b.id));
});

test('kokeilutilan mock ei tee verkkokutsuja: views-mock.js ei tuo sb.js:ää eikä käytä fetchiä', () => {
  const s = read('admin/views-mock.js');
  assert.doesNotMatch(s, /from '\.\/sb\.js'|fetch\(|XMLHttpRequest/);
  assert.match(read('admin/options-mock.js'), /viewsMockHandlers\(\{ st, need, err, now, resources:/);
});
