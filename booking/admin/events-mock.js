// booking_158: Tapahtumat-näkymän kokeilutila (/hallinta/?mock=1). Ei verkkoa, ei oikeita asiakastietoja; mikään ei tallennu.
// Vastaa booking_158-migraation RPC-muotoja (admin_event_list, admin_event_rule_upsert/_delete/_copy, admin_event_blocks_set,
// admin_event_set_channels, admin_event_copy, admin_product_copy, public_events). Myynti suljettu (events.sale_enabled = false) kuten tuotannossa.
// Esimerkki: Perinnesaunotusilta, Rauni +0…+120 min ja Savusauna +120 min…19:00 (kellonaika); koulutus kahdelle päivälle.
import { helsinkiIso, localParts, addDays, defaultLabel, copyName, CHANNELS, messageDraft } from './events-logic.js';

export const EVENT_MOCK_RESOURCES = [
  { id: 1, code: 'rauni', name: 'Rauni', kind: 'space', active: true },
  { id: 2, code: 'lovi', name: 'Lovi', kind: 'space', active: true },
  { id: 3, code: 'savusauna', name: 'Savusauna', kind: 'space', active: true },
  { id: 4, code: 'saunottaja_aino', name: 'Saunottaja Aino (esimerkki)', kind: 'person', active: true },
  { id: 5, code: 'saunottaja_eero', name: 'Saunottaja Eero (esimerkki)', kind: 'person', active: true },
  { id: 90, code: 'event_rule_1', name: 'Kerran kapasiteetti', kind: 'capacity_pool', active: true },
];
const err = (code, message, details) => Object.assign(new Error(message || code), { name: 'ApiError', code, status: 400, details });
const clone = (v) => structuredClone(v);

export function createEventsMock({ today, resources = EVENT_MOCK_RESOURCES, products = null } = {}) {
  const st = { saleEnabled: false, ruleSeq: 500, blockSeq: 900, productSeq: 700, msgSeq: 1, events: [], participants: [], messages: [] };
  const resById = new Map(resources.map((r) => [r.id, r]));
  const ruleObj = (p, r) => {
    const starts_at = helsinkiIso(`${r.date}T${r.start_time}`), ends_at = new Date(Date.parse(starts_at) + r.duration_minutes * 60000).toISOString();
    return { ...r, product_id: p.product_id, kind: 'event', starts_at, ends_at, space_id: null, pool_id: null,
      cancelled_at: r.cancelled_at || null, reservation_count: r.reservation_count ?? r.sold_persons ?? 0,
      blocks: (r.blocks || []).map((b) => blockObj(starts_at, b)) };
  };
  const blockObj = (s0, b) => {
    const rel = b.offset_min != null;
    const starts_at = rel ? new Date(Date.parse(s0) + b.offset_min * 60000).toISOString() : b.starts_at;
    const ends_at = rel ? new Date(Date.parse(s0) + (b.offset_min + b.minutes) * 60000).toISOString() : b.ends_at;
    const res = resById.get(b.resource_id) || {};
    return { id: b.id, resource_id: b.resource_id, resource_name: res.name || `#${b.resource_id}`, resource_code: res.code || null, resource_kind: res.kind || null,
      mode: b.mode || 'exclusive', timing: rel ? 'relative' : 'clock', offset_min: rel ? b.offset_min : null, minutes: rel ? b.minutes : null, starts_at, ends_at, note: b.note || null, materialized: (b.mode || 'exclusive') === 'exclusive' && res.kind === 'space' };
  };
  const d1 = addDays(today, 21), d2 = addDays(today, 49), t1 = addDays(today, 35);
  const s19 = (d) => helsinkiIso(`${d}T19:00`);
  const rule = (date, start_time, duration_minutes, max_persons, extra = {}) => ({ id: ++st.ruleSeq, date, start_time, duration_minutes, max_persons, min_persons: 1, deadline_minutes: 120,
    label: defaultLabel(date, start_time), label_en: null, active: true, price_variant_id: null, sold_persons: 0, waitlist_count: 0, blocks: [], ...extra });
  st.events = [
    { product_id: 31, slug: 'perinnesaunotusilta', name: 'Perinnesaunotusilta', name_en: 'Traditional sauna evening', category: 'event', active: true, bookable: true, shop_visible: true, lifecycle: 'current',
      channels: null, max_persons: 10, duration_minutes: 180, image_path: null, price: 69, price_text: null,
      rules: [rule(d1, '16:00', 180, 10, { sold_persons: 4, waitlist_count: 0, blocks: [{ id: ++st.blockSeq, resource_id: 1, mode: 'exclusive', offset_min: 0, minutes: 120 }, { id: ++st.blockSeq, resource_id: 3, mode: 'exclusive', starts_at: helsinkiIso(`${d1}T18:00`), ends_at: s19(d1) }, { id: ++st.blockSeq, resource_id: 4, mode: 'exclusive', offset_min: -30, minutes: 210, note: 'Lämmitys ja valmistelu' }] }),
        rule(d2, '16:00', 180, 10, { sold_persons: 10, waitlist_count: 2 })] },
    { product_id: 32, slug: 'naisten-joulusauna', name: 'Naisten joulusauna', name_en: 'Women’s Christmas sauna', category: 'event', active: true, bookable: true, shop_visible: true, lifecycle: 'current',
      channels: null, max_persons: 12, duration_minutes: 150, image_path: null, price: 59, price_text: null, rules: [] },
    { product_id: 33, slug: 'saunottajakoulutus', name: 'Saunottajakoulutus', name_en: 'Sauna host training', category: 'training', active: true, bookable: true, shop_visible: false, lifecycle: 'current',
      channels: null, max_persons: 8, duration_minutes: 1980, image_path: null, price: 390, price_text: null,
      rules: [rule(t1, '09:00', 1980, 8, { sold_persons: 2 })] },
  ];
  const evening = st.events[0].rules[0];
  const full = st.events[0].rules[1];
  const past = addDays(today, -14);
  st.events[0].rules.push(rule(past, '16:00', 180, 10, { sold_persons: 6, active: true }));
  // booking_213: Johku-myynnistä tuotu kerta – myydyt sisältävät Johku-paikat (8 / 8, täynnä).
  st.events[1].rules.push(rule(addDays(today, 3), '17:00', 150, 8, { sold_persons: 8, johku_persons: 8, johku_count: 6, reservation_count: 6 }));
  st.events[1].rules.push(rule(addDays(today, 30), '17:00', 150, 12, { sold_persons: 3, cancelled_at: `${today}T08:00:00.000Z`, active: false, reservation_count: 3, label: 'Peruttu kerta' }));
  const bookedAt = `${addDays(today, -2)}T08:15:00.000Z`;
  st.participants = [
    { reservation_id: 9101, rule_id: evening.id, order_id: 8101, order_no: 88021, name: 'Maija Mallikas', email: 'maija.mallikas@example.com', phone: '0401234567', persons: 2, order_status: 'confirmed', payment_status: 'paid', booked_at: bookedAt, customer_note: 'Tulen ystävän kanssa.', option_label: null, option_label_en: null, adults: 2, children: null, staff_note: 'Paikka oven vieressä.' },
    { reservation_id: 9102, rule_id: evening.id, order_id: 8102, order_no: 88022, name: 'Elias Esimerkki', email: 'elias.esimerkki@example.com', phone: '0509876543', persons: 2, order_status: 'confirmed', payment_status: 'unpaid', booked_at: bookedAt, customer_note: null, option_label: null, option_label_en: null, adults: 1, children: 1, staff_note: '' },
    { reservation_id: 9103, rule_id: full.id, order_id: 8103, order_no: 88030, name: 'Aino Asiakas', email: 'aino.asiakas@example.com', phone: '0451112233', persons: 4, order_status: 'confirmed', payment_status: 'paid', booked_at: bookedAt, customer_note: null, option_label: null, option_label_en: null, adults: 4, children: null, staff_note: '' },
  ];
  evening.reservation_count = 2;
  st.messages = [{ id: 1, product_id: 31, rule_id: evening.id, subject: 'Muistutus illasta', body: 'Otathan pyyhkeen mukaan.', recipient_count: 2, queued_count: 2, skipped_count: 0, created_at: bookedAt }];
  const find = (id) => { const p = st.events.find((x) => x.product_id === +id); if (!p) throw err('not_found', 'Tapahtumaa ei löydy'); return p; };
  const locate = (id) => { for (const p of st.events) { const r = p.rules.find((x) => x.id === +id); if (r) return { p, r }; } throw err('not_found', 'Tapahtumakertaa ei löydy'); };
  const listRow = (p, includePast) => ({ product_id: p.product_id, slug: p.slug, name: p.name, name_en: p.name_en, category: p.category, active: p.active, bookable: p.bookable, shop_visible: p.shop_visible,
    lifecycle: p.lifecycle, channels: p.channels ?? (p.category === 'training' ? ['widget'] : ['shop']), max_persons: p.max_persons, duration_minutes: p.duration_minutes, image_path: p.image_path,
    price: p.price, price_text: p.price_text, sale_enabled: st.saleEnabled,
    rules: p.rules.filter((r) => includePast || r.date >= addDays(today, -1)).sort((a, b) => (a.date + a.start_time).localeCompare(b.date + b.start_time)).map((r) => ruleObj(p, r)) });
  const handlers = {
    admin_event_list: (a) => st.events.filter((p) => !a.p_category || p.category === a.p_category).map((p) => listRow(p, !!a.p_include_past)),
    admin_event_rule_upsert: (a) => {
      const patch = a.p_patch || {};
      for (const k of Object.keys(patch)) if (!['date', 'start_time', 'duration_minutes', 'max_persons', 'min_persons', 'deadline_minutes', 'label', 'label_en', 'active', 'price_variant_id', 'single_room_max'].includes(k)) throw err('unknown_field', `Kenttää ei saa muokata: ${k}`);
      if (a.p_id) {
        const { p, r } = locate(a.p_id);
        if (patch.max_persons != null && patch.max_persons < r.sold_persons) throw err('max_below_sold', 'Osallistujamäärä on pienempi kuin myyty määrä');
        const before = `${r.date}|${r.start_time}|${r.duration_minutes}`;
        if (patch.active === false && r.active !== false && (r.sold_persons || r.reservation_count)) throw err('has_reservations', 'Kerralla on varauksia');
        for (const [k, v] of Object.entries(patch)) if (v !== undefined) r[k] = v;
        if (patch.start_time) r.start_time = String(patch.start_time).slice(0, 5);
        if (!r.label) r.label = defaultLabel(r.date, r.start_time);
        const after = `${r.date}|${r.start_time}|${r.duration_minutes}`;
        const obj = ruleObj(p, r);
        obj.moved_bookings = before !== after ? (r.sold_persons || 0) : 0;
        return obj;
      }
      const p = find(a.p_product_id);
      if (!patch.date || !patch.start_time) throw err('invalid_param', 'date ja start_time vaaditaan');
      const dur = patch.duration_minutes || p.duration_minutes || 120;
      if (dur > 1440 && p.category !== 'training') throw err('multi_day_training_only', 'Yli vuorokauden kerta vain koulutukselle');
      const r = rule(patch.date, patch.start_time, dur, patch.max_persons ?? p.max_persons, { ...patch, duration_minutes: dur, label: patch.label || defaultLabel(patch.date, patch.start_time) });
      p.rules.push(r);
      return ruleObj(p, r);
    },
    admin_event_rule_delete: (a) => {
      const { p, r } = locate(a.p_id);
      if (r.sold_persons) throw err('has_reservations', 'Kerralla on varauksia');
      if (r.waitlist_count) throw err('has_waitlist', 'Kerralla on jonottajia');
      p.rules = p.rules.filter((x) => x !== r);
      return { ok: true, deleted: r.id };
    },
    admin_event_blocks_set: (a) => {
      const { p, r } = locate(a.p_rule_id);
      const s0 = helsinkiIso(`${r.date}T${r.start_time}`);
      const next = (a.p_blocks || []).map((b) => {
        const res = resById.get(+b.resource_id);
        if (!res || !['space', 'person'].includes(res.kind)) throw err('invalid_resource', 'Valitse aktiivinen tila tai henkilöresurssi');
        return { id: ++st.blockSeq, resource_id: res.id, mode: b.mode || 'exclusive', offset_min: b.offset_min ?? null, minutes: b.minutes ?? null, starts_at: b.starts_at ?? null, ends_at: b.ends_at ?? null, note: b.note || null };
      });
      // ristiriita toisen tapahtuman yksinoikeusvarauksen kanssa (sama resurssi, päällekkäinen aika)
      const hits = [];
      for (const b of next) {
        const x = blockObj(s0, b);
        for (const q of st.events) for (const o of q.rules) if (o !== r) for (const ob of ruleObj(q, o).blocks) {
          if (ob.resource_id === b.resource_id && ob.mode === 'exclusive' && b.mode === 'exclusive' && Date.parse(ob.starts_at) < Date.parse(x.ends_at) && Date.parse(x.starts_at) < Date.parse(ob.ends_at)) hits.push({ resource_id: b.resource_id, resource_name: x.resource_name, starts_at: ob.starts_at, ends_at: ob.ends_at, reason: 'event_block' });
        }
      }
      if (hits.length) throw err('conflict', `Resurssi on jo varattu tälle ajalle (${hits.length} ristiriitaa)`, { hint: JSON.stringify(hits) });
      r.blocks = next;
      return ruleObj(p, r).blocks;
    },
    admin_event_set_channels: (a) => {
      const p = find(a.p_product_id);
      const bad = (a.p_channels || []).find((c) => !CHANNELS.includes(c));
      if (bad) throw err('invalid_param', `Tuntematon kanava: ${bad}`);
      p.channels = [...new Set(a.p_channels || [])];
      return { ok: true, product_id: p.product_id, channels: p.channels };
    },
    admin_event_rule_copy: (a) => {
      const { p, r } = locate(a.p_rule_id);
      const c = { ...clone(r), id: ++st.ruleSeq, date: a.p_date, sold_persons: 0, waitlist_count: 0, label: r.label === defaultLabel(r.date, r.start_time) ? defaultLabel(a.p_date, r.start_time) : r.label,
        blocks: r.blocks.map((b) => ({ ...b, id: ++st.blockSeq, ...(b.offset_min == null ? shiftClock(b, r.date, a.p_date) : {}) })) };
      p.rules.push(c);
      return ruleObj(p, c);
    },
    admin_event_copy: (a) => {
      const src = find(a.p_product_id), id = ++st.productSeq, shift = +a.p_shift_days || 0;
      const rules = a.p_include_rules ? src.rules.filter((r) => r.date >= today).map((r) => ({ ...clone(r), id: ++st.ruleSeq, date: addDays(r.date, shift), active: false, sold_persons: 0, waitlist_count: 0,
        label: r.label === defaultLabel(r.date, r.start_time) ? defaultLabel(addDays(r.date, shift), r.start_time) : r.label,
        blocks: r.blocks.map((b) => ({ ...b, id: ++st.blockSeq, ...(b.offset_min == null ? shiftClock(b, r.date, addDays(r.date, shift)) : {}) })) })) : [];
      st.events.push({ ...clone(src), product_id: id, slug: `${src.slug}-kopio-${id}`, name: copyName(src.name), active: false, bookable: false, shop_visible: false, rules });
      products?.push({ id, name: copyName(src.name), name_en: src.name_en, price: src.price, vat_rate: 25.5, active: false, category: src.category, config: { bookable: false, shop_visible: false, lifecycle: 'current' } });
      return { product_id: id, slug: `${src.slug}-kopio-${id}`, rules_copied: rules.length };
    },
    admin_event_participants: (a) => {
      const p = find(a.p_product_id);
      const ids = new Set(p.rules.map((r) => r.id));
      return st.participants.filter((x) => ids.has(x.rule_id) && (!a.p_rule_id || x.rule_id === +a.p_rule_id));
    },
    admin_event_participant_note_set: (a) => {
      const row = st.participants.find((x) => x.reservation_id === +a.p_reservation_id);
      if (!row) throw err('not_found', 'Varausta ei löydy');
      const note = String(a.p_note ?? '').trim();
      if (note.length > 2000) throw err('invalid_param', 'Muistiinpano on liian pitkä');
      row.staff_note = note;
      return { ok: true, reservation_id: row.reservation_id, note };
    },
    admin_event_occurrence_cancel: (a) => {
      const { p, r } = locate(a.p_id);
      r.cancelled_at = r.cancelled_at || new Date().toISOString();
      r.active = false;
      return ruleObj(p, r);
    },
    admin_event_messages_list: (a) => st.messages.filter((m) => m.product_id === +a.p_product_id),
    admin_event_message_send: (a) => {
      const draft = messageDraft({ subject: a.p_subject, body: a.p_body });
      if (!draft.ok) throw err(draft.error, draft.error);
      const p = find(a.p_product_id);
      const ids = new Set(p.rules.filter((r) => !a.p_rule_id || r.id === +a.p_rule_id).map((r) => r.id));
      const rows = st.participants.filter((x) => ids.has(x.rule_id) && x.order_status !== 'cancelled' && x.email);
      const byOrder = new Map();
      for (const row of rows) if (!byOrder.has(row.order_id)) byOrder.set(row.order_id, row);
      const recipients = [...byOrder.values()].map((r) => ({ name: r.name, order_no: r.order_no, persons: r.persons }));
      const preview = { ok: true, recipient_count: recipients.length, skipped_count: 0, recipients, subject: draft.subject, signature: null };
      if (a.p_confirm !== true) return preview;
      if (!recipients.length) throw err('no_recipients', 'Ei vastaanottajia');
      const msg = { id: ++st.msgSeq, product_id: p.product_id, rule_id: a.p_rule_id || null, subject: draft.subject, body: draft.body, recipient_count: recipients.length, queued_count: recipients.length, skipped_count: 0, created_at: new Date().toISOString() };
      st.messages.unshift(msg);
      return { ...preview, sent: true, queued_count: recipients.length, id: msg.id };
    },
    public_events: (a) => {
      const ch = a.p_channel || 'shop';
      return st.events.filter((p) => p.active && p.bookable && (p.channels ?? (p.category === 'training' ? ['widget'] : ['shop'])).includes(ch)).map((p) => ({
        product_id: p.product_id, slug: p.slug, name: p.name, name_en: p.name_en, description_short: null, description_short_en: null, price: p.price, price_text: p.price_text,
        image_path: p.image_path, image_alt: null, category: p.category, sale_open: st.saleEnabled,
        occurrences: p.rules.filter((r) => r.active && r.date >= (a.p_from || today)).map((r) => { const o = ruleObj(p, r);
          return { rule_id: r.id, starts_at: o.starts_at, ends_at: o.ends_at, label: r.label, label_en: r.label_en, status: !st.saleEnabled ? 'closed' : r.sold_persons >= r.max_persons ? 'full' : 'available', remaining: Math.max(0, r.max_persons - r.sold_persons), price: p.price }; }),
      })).filter((p) => p.occurrences.length);
    },
  };
  const shiftClock = (b, from, to) => {
    const days = Math.round((Date.parse(`${to}T12:00:00Z`) - Date.parse(`${from}T12:00:00Z`)) / 864e5);
    const mv = (iso) => { const x = localParts(iso); return helsinkiIso(`${addDays(x.date, days)}T${x.time}`); };
    return { starts_at: mv(b.starts_at), ends_at: mv(b.ends_at) };
  };
  return { handlers: Object.fromEntries(Object.entries(handlers).map(([k, f]) => [k, (a) => clone(f(a || {}))])), state: st };
}
