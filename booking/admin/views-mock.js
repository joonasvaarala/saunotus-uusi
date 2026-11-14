// YHT-08: kokeilutilan (?mock=1) puuttuvat näkymät: Resurssit (vuorosäännöt, sulut), Kalenterisulut, Käyttäjät ja asiakasnäkymä.
// Vain selaimen muistissa (options-mock.js liittää nämä handlereihin); ei verkkokutsuja, mikään ei tallennu. Muodot kuten tuotannon RPC:t.
const clone = (x) => structuredClone(x);

export function viewsMockHandlers({ st, need, err, now = new Date(), resources = [] }) {
  const iso = (days, hh = 12) => new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + days, hh - 2)).toISOString();
  const spaces = resources.filter((r) => r.kind === 'space');
  const prods = (st.products || []).filter((p) => p.active !== false).slice(0, 4);
  st.scheduleRules ??= prods.map((p, i) => ({
    id: i + 1, product_id: p.id, label: p.name, weekdays: i % 2 ? [6, 7] : [3, 4, 5], start_time: `${String(14 + i).padStart(2, '0')}:00:00`, duration_minutes: 90,
    mode: i % 2 ? 'shared' : 'exclusive', min_persons: 1, max_persons: i % 2 ? 10 : 6, price_mode: i % 2 ? 'per_person' : 'fixed', included_persons: null,
    valid_from: null, valid_to: null, active: i !== 3, deadline_minutes: 60, sort_order: i + 1,
  }));
  st.spaceBlocks ??= spaces.length ? [{ id: 1, space_id: spaces[0].id, resource_code: spaces[0].code, starts_at: iso(3, 10), ends_at: iso(3, 14), reason: 'Huolto (esimerkki)', closure_event_id: null, active: true }] : [];
  st.closureEvents ??= [
    { id: 1, calendar_code: 'saunottajat', reason: 'Saunottaja lomalla (esimerkki)', starts_at: iso(5, 0), ends_at: iso(6, 0), all_day: true, class: 'closure', effective_block: true, override: null, override_note: null },
    { id: 2, calendar_code: 'saunottajat', reason: 'Koulutusjakso (esimerkki)', starts_at: iso(9, 8), ends_at: iso(11, 18), all_day: false, class: 'rough', effective_block: false, override: null, override_note: null },
  ];
  st.staff ??= [
    { user_id: 'mock-1', name: 'Kokeilu Käyttäjä', email: 'kokeilu@example.com', role: 'admin', active: true, public_staff_id: 1 },
    { user_id: 'mock-2', name: 'Aino Saunottaja', email: 'aino.saunottaja@example.com', role: 'staff', active: true, public_staff_id: 2 },
    { user_id: 'mock-3', name: 'Eero Päällikkö', email: 'eero.paallikko@example.com', role: 'manager', active: true, public_staff_id: null },
    { user_id: 'mock-4', name: 'Entinen Työntekijä', email: 'entinen@example.com', role: 'staff', active: false, public_staff_id: null },
  ];
  const ROLES = [{ code: 'admin', label: 'Pääkäyttäjä', is_staff: true }, { code: 'manager', label: 'Päällikkö', is_staff: true }, { code: 'staff', label: 'Työntekijä', is_staff: true }, { code: 'bot', label: 'Botti', is_staff: false }];
  const PUBLIC_STAFF = [{ id: 1, name: 'Kokeilu Käyttäjä', active: true }, { id: 2, name: 'Aino', active: true }, { id: 3, name: 'Eero', active: true }];
  const byId = (rows, id, what) => { const r = rows.find((x) => x.id === Number(id)); if (!r) throw err('not_found', `${what} ei löydy`); return r; };

  const customerOrders = (cid) => {
    const by = new Map();
    for (const r of st.reservations.filter((x) => x.customer_id === cid)) {
      const o = by.get(r.order_id) || { order_id: r.order_id, order_no: r.order_no, status: r.order_status, payment_status: r.payment_status, total: 0, created_at: r.created_at, reservations: [] };
      o.total += Number(r.total_gross) || 0;
      o.reservations.push({ id: r.reservation_id, status: r.status, starts_at: r.starts_at, ends_at: r.ends_at, product_name: r.product_name, persons: r.persons });
      by.set(r.order_id, o);
    }
    return [...by.values()];
  };

  return {
    'select:schedule_rules': () => clone(st.scheduleRules),
    'select:space_blocks': () => clone(st.spaceBlocks.filter((b) => b.active && b.ends_at >= now.toISOString())),
    admin_create_block: (a) => {
      need('blocks.manage');
      const sp = spaces.find((s) => s.id === Number(a.p_space_id)); if (!sp) throw err('not_found', 'Tilaa ei löydy');
      if (!(a.p_ends_at > a.p_starts_at)) throw err('invalid_param', 'Sulun loppu on ennen alkua');
      const b = { id: Math.max(0, ...st.spaceBlocks.map((x) => x.id)) + 1, space_id: sp.id, resource_code: sp.code, starts_at: a.p_starts_at, ends_at: a.p_ends_at, reason: a.p_reason || null, closure_event_id: null, active: true };
      st.spaceBlocks.push(b); return { ok: true, id: b.id };
    },
    admin_delete_block: (a) => { need('blocks.manage'); const b = byId(st.spaceBlocks, a.p_id, 'Sulkua'); b.active = false; return { ok: true }; },
    admin_update_resource: (a) => { need('resources.edit'); const r = byId(resources, a.p_id, 'Resurssia'); Object.assign(r, a.p_patch || {}); return { ok: true }; },
    admin_update_schedule_rule: (a) => {
      need('rules.edit');
      const r = byId(st.scheduleRules, a.p_id, 'Sääntöä');
      const allowed = ['label', 'active', 'min_persons', 'max_persons', 'deadline_minutes', 'valid_from', 'valid_to'];
      for (const [k, v] of Object.entries(a.p_patch || {})) if (allowed.includes(k)) r[k] = v;
      return { ok: true };
    },
    admin_closure_overview: () => {
      need('blocks.manage');
      return {
        calendars: [
          { code: 'saunottajat', name: 'Saunottajien kalenteri (esimerkki)', active: true, configured: true, resource_code: resources.find((r) => r.kind === 'person')?.code || null, consecutive_failures: 0, last_success_at: iso(-1, 22), last_stats: { events_seen: 2, candidates: 1, rough: 1 }, last_error: null },
          { code: 'huolto', name: 'Huoltokalenteri (esimerkki)', active: false, configured: false, resource_code: spaces[0]?.code || null, consecutive_failures: 0, last_success_at: null, last_stats: null, last_error: null },
        ],
        events: clone(st.closureEvents), conflicts: [],
        runs: [{ calendar_code: 'saunottajat', started_at: iso(-1, 22), outcome: 'ok', error: null, stats: { events_seen: 2, candidates: 1 } }],
      };
    },
    admin_set_closure_override: (a) => {
      need('blocks.manage');
      const e = byId(st.closureEvents, a.p_event_id, 'Tapahtumaa');
      const before = e.effective_block;
      e.override = a.p_override || null; e.override_note = a.p_note || null;
      e.effective_block = e.override === 'block' ? true : e.override === 'ignore' ? false : e.class === 'closure';
      return { ok: true, blocks_inserted: !before && e.effective_block ? 1 : 0, blocks_updated: 0, blocks_deleted: before && !e.effective_block ? 1 : 0 };
    },
    admin_list_staff: () => { need('staff.manage'); return clone(st.staff); },
    admin_list_roles: () => clone(ROLES),
    admin_list_public_staff: () => clone(PUBLIC_STAFF),
    admin_set_staff_role: (a) => {
      need('staff.manage');
      const s = st.staff.find((x) => x.user_id === a.p_user_id); if (!s) throw err('not_found', 'Käyttäjää ei löydy');
      if (!ROLES.some((r) => r.code === a.p_role && r.is_staff)) throw err('invalid_param', 'Tuntematon rooli');
      s.role = a.p_role; return { ok: true };
    },
    admin_link_public_staff: (a) => {
      need('staff.manage');
      const s = st.staff.find((x) => x.user_id === a.p_user_id); if (!s) throw err('not_found', 'Käyttäjää ei löydy');
      s.public_staff_id = a.p_public_staff_id == null || a.p_public_staff_id === '' ? null : Number(a.p_public_staff_id); return { ok: true };
    },
    admin_get_customer: (a) => {
      const c = st.customers.find((x) => x.id === Number(a.p_id)); if (!c) throw err('not_found', 'Asiakasta ei löydy');
      const orders = customerOrders(c.id);
      const open = orders.filter((o) => ['unpaid', 'partially_paid'].includes(o.payment_status) && !['cancelled', 'expired'].includes(o.status));
      return {
        id: c.id, name: c.name, email: c.email || null, phone: c.phone || null, customer_kind: c.customer_kind || 'private', company: c.company || null, business_id: c.business_id || null,
        language: c.language || 'fi', notes: c.notes || '', marketing_consent: c.id % 2 === 1, marketing_consent_at: c.id % 2 === 1 ? '2026-06-01T09:00:00Z' : null, marketing_consent_source: c.id % 2 === 1 ? 'shop' : null,
        created_at: c.created_at || '2026-05-01T09:00:00Z', anonymized_at: c.anonymized_at || null, merged_into: null,
        open_balance: open.reduce((n, o) => n + o.total, 0), open_orders: open.length,
        gift_cards: { bought_count: 0, bought_total: 0, redeemed_count: 0, bought: [] },
        annual_cards: (st.annualCards || []).filter((x) => x.customer_id === c.id).map((x) => ({ code: x.code, valid_from: x.valid_from, valid_to: x.valid_to, active: x.active !== false })),
        orders,
      };
    },
  };
}
