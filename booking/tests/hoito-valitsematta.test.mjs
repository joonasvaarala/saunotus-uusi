// Hoito valitsematta: päivänäkymän linkki avaa varauslistan suodattimella treatment_unassigned + period=upcoming.
// Palvelin (booking_72, p_option_missing) rajaa sivutuksen kanssa. Ennen migraatiota selain rajaa option_missing-kentästä.
// Tekstit: ui.admin.options.* sanakirjassa ja content/site-texts.pending-import-10.json (ei vielä fallbackissa).
// pending-import-4.json on jo tuotu (myyntikäyrä ja suodatinpainike); sitä ei muuteta.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createAdminMock, helIso } from '../admin/options-mock.js';
import { OPTION_TEXTS, fillOptionText, optionText, loadOptionTexts, clearOptionTextCache } from '../admin/options-texts.js';
import {
  TREATMENT_UNASSIGNED, UNASSIGNED_HREF, reservationsHref, stateFromQuery, parseAdminHash, needsManualRoute,
  isTreatmentUnassigned, isUnassignedFilterUnsupported, loadReservationPage,
} from '../admin/reservation-query.js';

const NOW = new Date('2026-10-18T08:00:00Z');
const base = (m, from = helIso(m.today, '00:00')) => ({ p_from: from, p_to: null, p_search: null, p_status: null, p_product_id: null });

test('linkki avaa tulevat varaukset, joilla hoito on valitsematta', () => {
  assert.equal(UNASSIGNED_HREF, '#/varaukset?filter=treatment_unassigned&period=upcoming');
  const parsed = parseAdminHash(UNASSIGNED_HREF);
  assert.equal(parsed.path, 'varaukset');
  const st = stateFromQuery(parsed.query);
  assert.equal(st.treatment, TREATMENT_UNASSIGNED);
  assert.equal(st.period, 'upcoming');
  assert.equal(reservationsHref(st), UNASSIGNED_HREF);
  assert.equal(stateFromQuery('filter=treatment_unassigned').period, 'all', 'pelkkä suodatin ei pakota jaksoa');
  assert.equal(stateFromQuery('period=eilen').period, 'all');
  const custom = { treatment: '', period: 'custom', status: 'confirmed', product: '10', source: 'native', search: 'aino', sort: 'soon', id: '', from: '2026-10-01', to: '2026-10-18' };
  assert.equal(reservationsHref(custom), '#/varaukset?period=custom&status=confirmed&product=10&source=native&q=aino&from=2026-10-01&to=2026-10-18');
  assert.deepEqual(stateFromQuery(reservationsHref(custom).split('?')[1]), custom);
  assert.equal(reservationsHref({ period: 'custom', from: 'eilen', to: '20.10.2026' }), '#/varaukset?period=custom');
  assert.equal(needsManualRoute(UNASSIGNED_HREF, UNASSIGNED_HREF), true);
  assert.equal(needsManualRoute('#/varaukset', '#/varaukset'), true);
  assert.equal(needsManualRoute('#/', UNASSIGNED_HREF), false);
  assert.equal(needsManualRoute('#/varaukset', UNASSIGNED_HREF), false);
  assert.equal(parseAdminHash('#/?d=2026-10-18').path, '');
  assert.equal(isTreatmentUnassigned({ option_missing: true }), true);
  assert.equal(isTreatmentUnassigned({ option_missing: false }), false);
  assert.equal(isTreatmentUnassigned({ option_missing: 'true' }), false);
  assert.equal(isUnassignedFilterUnsupported(Object.assign(new Error('Could not find the function in the schema cache'), { status: 404, code: 'PGRST202' })), true);
  assert.equal(isUnassignedFilterUnsupported(Object.assign(new Error('permission denied'), { status: 401 })), false);
});

test('palvelinsuodatin rajaa tulevat hoitovaraukset ja valinta poistaa rivin sekä kortin luvun', async () => {
  const m = createAdminMock({ now: NOW });
  const args = [];
  const rpc = async (name, a) => { args.push({ name, a }); return m.rpc(name, a); };
  const page = await loadReservationPage(rpc, base(m), { treatment: TREATMENT_UNASSIGNED, offset: 0, limit: 50, cache: {} });
  assert.equal(page.mode, 'server');
  assert.equal(page.total, 2);
  assert.equal(page.rows.length, 2);
  assert.ok(page.rows.every((r) => r.option_missing === true && r.product_id === 10));
  assert.ok(args.some((c) => c.name === 'admin_list_reservations' && c.a.p_option_missing === true && c.a.p_from === helIso(m.today, '00:00')));
  const later = await loadReservationPage(m.rpc, base(m, helIso('2026-10-19', '00:00')), { treatment: TREATMENT_UNASSIGNED, offset: 0, limit: 50, cache: {} });
  assert.equal(later.total, 1, 'huomisesta eteenpäin jää vain ylihuominen valitsematta');
  assert.equal(later.rows[0].status, 'pending');
  const card = async () => (await m.rpc('admin_list_product_options')).reduce((n, p) => n + p.reservations_without_option, 0);
  assert.equal(await card(), 2);
  const id = page.rows[0].reservation_id;
  await m.rpc('admin_set_reservation_option', { p_reservation_id: id, p_option_code: 'vihtahoito' });
  const again = await loadReservationPage(m.rpc, base(m), { treatment: TREATMENT_UNASSIGNED, offset: 0, limit: 50, cache: {} });
  assert.equal(again.total, 1);
  assert.ok(again.rows.every((r) => r.reservation_id !== id && r.option_missing === true));
  assert.equal(await card(), 1);
  const all = await m.rpc('admin_list_reservations', { p_limit: 50 });
  assert.equal(all.filter((r) => r.option_missing).length, 1);
  assert.equal(all.find((r) => r.reservation_id === id).option_code, 'vihtahoito');
});

test('ennen migraatiota selain käy sivut läpi ja pitää vain option_missing-rivit', async () => {
  const pages = [
    Array.from({ length: 100 }, (_, i) => ({ reservation_id: i + 1, option_missing: false, total_count: 102, product_id: 8 })),
    [
      { reservation_id: 101, option_missing: true, total_count: 102, product_id: 10 },
      { reservation_id: 102, option_missing: false, total_count: 102, product_id: 8 },
    ],
  ];
  const calls = [];
  const rpc = async (name, a) => {
    calls.push(a);
    assert.equal(name, 'admin_list_reservations');
    if (a.p_option_missing != null) {
      const e = new Error('Could not find the function booking.admin_list_reservations(p_option_missing) in the schema cache');
      e.status = 404; e.code = 'PGRST202';
      throw e;
    }
    return pages[(a.p_offset || 0) === 0 ? 0 : 1];
  };
  const cache = {};
  const page = await loadReservationPage(rpc, { p_from: '2026-10-18T00:00:00Z' }, { treatment: TREATMENT_UNASSIGNED, offset: 0, limit: 50, cache });
  assert.equal(page.mode, 'client');
  assert.equal(page.total, 1);
  assert.deepEqual(page.rows.map((r) => r.reservation_id), [101]);
  assert.equal(calls.filter((c) => c.p_option_missing != null).length, 1);
  assert.ok(calls.some((c) => c.p_offset === 100 && c.p_option_missing == null));
  const rest = await loadReservationPage(rpc, { p_from: '2026-10-18T00:00:00Z' }, { treatment: TREATMENT_UNASSIGNED, offset: 50, limit: 50, cache });
  assert.equal(rest.rows.length, 0);
  assert.equal(rest.total, 1);
  assert.equal(calls.length, 3, 'Näytä lisää käyttää välimuistia eikä hae uudelleen');
  const boom = Object.assign(new Error('permission denied'), { status: 401 });
  await assert.rejects(
    () => loadReservationPage(async () => { throw boom; }, {}, { treatment: TREATMENT_UNASSIGNED, offset: 0, limit: 50, cache: {} }),
    (e) => e.status === 401,
  );
});

test('tekstit: FI ja EN, tuontitiedosto vastaa sanakirjaa, fallbackissa ei vielä ole', () => {
  assert.deepEqual(Object.keys(OPTION_TEXTS.fi).sort(), Object.keys(OPTION_TEXTS.en).sort());
  for (const key of Object.keys(OPTION_TEXTS.fi)) {
    assert.ok(OPTION_TEXTS.fi[key].length > 0 && OPTION_TEXTS.en[key].length > 0, key);
    assert.match(key, /^ui\.admin\.options\.[a-z0-9_]+$/);
  }
  assert.equal(fillOptionText(OPTION_TEXTS.fi['ui.admin.options.reminder'], { n: 2 }), '2 tulevaa hoitovarausta ilman valittua hoitoa.');
  assert.equal(OPTION_TEXTS.fi['ui.admin.options.reminder_link'], 'Avaa varaukset');
  assert.equal(OPTION_TEXTS.fi['ui.admin.options.not_chosen'], 'valitsematta');
  assert.equal(OPTION_TEXTS.fi['ui.admin.options.filter_unassigned'], 'Hoito valitsematta');
  const pending = JSON.parse(readFileSync(new URL('../../content/site-texts.pending-import-10.json', import.meta.url), 'utf8'));
  const keys = new Set(Object.keys(OPTION_TEXTS.fi));
  assert.equal(pending.length, keys.size * 2);
  const imported4 = JSON.parse(readFileSync(new URL('../../content/site-texts.pending-import-4.json', import.meta.url), 'utf8'));
  assert.equal(imported4.filter((r) => String(r.key || '').startsWith('ui.admin.options.')).length, 0);
  for (const row of pending) {
    assert.ok(keys.has(row.key), row.key);
    assert.ok(row.lang === 'fi' || row.lang === 'en');
    assert.equal(row.text, OPTION_TEXTS[row.lang][row.key]);
    assert.equal(row.class, 'normal');
    assert.equal(row.kind, 'plain');
    assert.equal(row.max_len, 200);
    const found = [...row.text.matchAll(/\{\{[^}]+\}\}/g)].map((m) => m[0]);
    assert.deepEqual(found, row.placeholders);
    for (const ph of found) assert.match(ph, /^\{\{[a-z_]+:[A-Za-z0-9_]+\}\}$/);
  }
  const fallback = JSON.parse(readFileSync(new URL('../../content/site-texts.fallback.json', import.meta.url), 'utf8'));
  assert.equal((fallback.texts || []).filter((r) => String(r.key || '').startsWith('ui.admin.options.')).length, 0);
});

test('site_texts peittää sanakirjan; täyttymätön paikkamerkki jää varalle', async () => {
  clearOptionTextCache();
  assert.equal(optionText('ui.admin.options.filter_unassigned', null, 'fi'), 'Hoito valitsematta');
  const ok = await loadOptionTexts(async (name, args) => {
    assert.equal(name, 'public_get_site_texts');
    assert.equal(args.p_lang, null);
    return { ok: true, texts: [
      { key: 'ui.admin.options.filter_unassigned', lang: 'fi', text: 'Hoito puuttuu' },
      { key: 'ui.admin.options.reminder', lang: 'fi', text: 'Avoinna {{var:n}}' },
      { key: 'ui.admin.options.reminder', lang: 'en', text: 'Broken {{amount}}' },
      { key: 'ui.shop.x', lang: 'fi', text: 'ei tähän' },
    ] };
  });
  assert.equal(ok, true);
  assert.equal(optionText('ui.admin.options.filter_unassigned', null, 'fi'), 'Hoito puuttuu');
  assert.equal(optionText('ui.admin.options.filter_unassigned', null, 'en'), 'Treatment not chosen', 'EN-rivi puuttuu: sanakirja');
  assert.equal(optionText('ui.admin.options.reminder', { n: 2 }, 'fi'), 'Avoinna 2');
  assert.equal(optionText('ui.admin.options.reminder', { n: 2 }, 'en'), OPTION_TEXTS.en['ui.admin.options.reminder'].replace('{{var:n}}', '2'));
  assert.equal(await loadOptionTexts(async () => { throw new Error('toinen haku'); }), true, 'onnistunut haku jää välimuistiin');
  clearOptionTextCache();
  assert.equal(await loadOptionTexts(async () => { throw new Error('verkko'); }), false);
  assert.equal(optionText('ui.admin.options.not_chosen', null, 'fi'), 'valitsematta');
  clearOptionTextCache();
});

test('linkki, reititys ja migraatio ovat tiedostoissa; hoitovalintaa ei muuteta', () => {
  const options = readFileSync(new URL('../admin/options.js', import.meta.url), 'utf8');
  const admin = readFileSync(new URL('../admin/admin.js', import.meta.url), 'utf8');
  const list = readFileSync(new URL('../admin/views/reservations.js', import.meta.url), 'utf8');
  const logic = readFileSync(new URL('../admin/options-logic.js', import.meta.url), 'utf8');
  const sql = readFileSync(new URL('../supabase/migrations/20261018191000_booking_72_option_missing_filter.sql', import.meta.url), 'utf8');
  const rollback = readFileSync(new URL('../supabase/rollbacks/20261018191000_booking_72_ROLLBACK.sql', import.meta.url), 'utf8');
  const t12 = readFileSync(new URL('../supabase/tests/12_johku_marker.test.sql', import.meta.url), 'utf8');
  assert.match(options, /UNASSIGNED_HREF/);
  assert.match(options, /opt-reminder-link/);
  assert.doesNotMatch(options, /href:\s*['"]#\/varaukset['"]/);
  assert.doesNotMatch(logic, /reminderLink|tulevaa hoitovarausta/);
  assert.match(admin, /needsManualRoute/);
  assert.match(admin, /const ASSET_VER = '';/);
  assert.match(list, /treatment-filter/);
  assert.match(list, /active-filters/);
  assert.match(list, /loadReservationPage/);
  assert.match(list, /filterDrawer\(/);
  assert.match(list, /testid: 'reservations-filters'/);
  assert.match(list, /data-testid': 'reservations-search'/);
  assert.match(list, /status: activeBar/);
  assert.match(list, /reviewAttentionCount/);
  assert.doesNotMatch(list, /admin_set_reservation_option/);
  assert.match(sql, /p_option_missing boolean default null/);
  assert.match(sql, /p_option_missing is not true/);
  assert.match(sql, /po\.id is null and exists \(select 1 from booking\.product_options x where x\.product_id = r\.product_id and x\.active\)/);
  assert.match(sql, /drop function if exists booking\.admin_list_reservations\(timestamptz, timestamptz, text, text, bigint, integer, integer, text\)/);
  assert.doesNotMatch(sql, /create table|alter table/i);
  assert.match(rollback, /drop function if exists booking\.admin_list_reservations\(timestamptz, timestamptz, text, text, bigint, integer, integer, text, boolean\)/);
  assert.match(rollback, /p_source text default null\)/);
  assert.doesNotMatch(rollback, /p_option_missing boolean/);
  assert.match(t12, /timestamptz,timestamptz,text,text,bigint,integer,integer,text,boolean/);
  assert.match(t12, /p_option_missing/);
});
