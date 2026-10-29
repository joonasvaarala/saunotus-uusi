// booking_202: Tapahtumat ja koulutukset (#/tapahtumat). Yleiskatsaus (lista tai kalenteri), tapahtuman välilehdet
// (Yleiskatsaus, Kerrat, Osallistujat, Viestit, Asetukset), kertojen lisäys kalenterista ja viikkotoistolla,
// osallistujalista (CSV + tuloste, henkilökunnan muistiinpanot) ja viesti osallistujille.
// Henkilökunta näkee, catalog.edit muokkaa kertoja, messages.edit lähettää viestin. Kaikki nimet textContentina.
// Tekstit: events-texts.js (FI+EN, pending-import-57 ja pending-import-97). RPC:t booking_158 + booking_202.
import { rpc } from '../sb.js';
import { h, dialog, field, toast, badge, errMsg, fmtDate, fmtTime, fmtDT, todayHel, STATUS, PAY } from '../ui.js';
import { downloadCsv } from '../csv.js';
import { loadEventsTexts, evText as T } from '../events-texts.js';
import { getLang } from '../talous-i18n.js';
import { buildSeries, defaultLabel, validateBlock, blockToRow, blocksPayload, timeline, selectableResources, channelsOf, normChannels, CHANNELS,
  copyArgs, copyName, conflictsOf, localParts, MAX_BLOCKS, occurrenceFlags, bookingCount, isPastMove, messageDraft, customerMessageText, participantsToCsv, weekdayIso } from '../events-logic.js';
import { eventQueueParts } from '../event-waitlist.js';

const ERR_CODES = new Set(['conflict', 'has_reservations', 'has_waitlist', 'max_below_sold', 'past_move', 'multi_day_training_only', 'invalid_resource', 'not_event', 'event_managed',
  'no_subject', 'subject_long', 'no_body', 'body_long', 'provider_name', 'no_recipients', 'no_confirm', 'bad_range', 'no_weekdays']);
const evErr = (e) => (e?.code && ERR_CODES.has(e.code) ? T(`err_${e.code}`) : errMsg(e));
const span = (iso1, iso2) => {
  const a = localParts(iso1), b = localParts(iso2);
  return a.date === b.date ? `${fmtDate(iso1)} ${fmtTime(iso1)}–${fmtTime(iso2)}` : `${fmtDate(iso1)} ${fmtTime(iso1)} – ${fmtDate(iso2)} ${fmtTime(iso2)}`;
};
const catName = (c) => (c === 'training' ? T('cat_training') : T('cat_event'));
const occLabel = (r) => (getLang() === 'en' && r.label_en) || r.label || defaultLabel(r.date, r.start_time, getLang());
const hrefOf = (q) => {
  const s = new URLSearchParams();
  for (const [k, v] of Object.entries(q || {})) if (v != null && v !== '' && v !== false) s.set(k, String(v));
  const str = s.toString();
  return `#/tapahtumat${str ? `?${str}` : ''}`;
};
const STATUS_KEY = { on_sale: 'status_on_sale', full: 'status_full', cancelled: 'status_cancelled', sales_closed: 'status_sales_closed', past: 'badge_past' };
const STATUS_KIND = { on_sale: 'ok', full: 'err', cancelled: 'err', sales_closed: 'warn', past: 'muted' };
const TABS = [['yleiskatsaus', 'tab_overview'], ['kerrat', 'tab_occurrences'], ['osallistujat', 'tab_participants'], ['viestit', 'tab_messages'], ['asetukset', 'tab_settings']];
const SAFE_EMAIL = /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[A-Za-z]{2,}$/;
const SAFE_PHONE = /^\+?[0-9][0-9 ().-]{5,28}$/;

export async function render({ ctx, refs, reload, query }) {
  await loadEventsTexts(rpc);
  const canEdit = ctx.can('catalog.edit');
  const canSend = ctx.can('messages.edit');
  const q = query || new URLSearchParams();
  const cat = ['event', 'training'].includes(q.get('kategoria')) ? q.get('kategoria') : '';
  const when = ['tulevat', 'menneet', 'kaikki'].includes(q.get('jakso')) ? q.get('jakso') : (q.get('menneet') === '1' ? 'menneet' : 'tulevat');
  const viewMode = q.get('nakyma') === 'kalenteri' ? 'kalenteri' : 'lista';
  const statusFilter = ['on_sale', 'full', 'cancelled', 'sales_closed'].includes(q.get('tila')) ? q.get('tila') : '';
  const productFilter = Number(q.get('tuote')) || 0;
  const dayFilter = /^\d{4}-\d{2}-\d{2}$/.test(q.get('paiva') || '') ? q.get('paiva') : '';
  const openId = Number(q.get('tapahtuma')) || null;
  const tab = TABS.some(([id]) => id === q.get('valilehti')) ? q.get('valilehti') : 'yleiskatsaus';
  const kertaQ = Number(q.get('kerta')) || 0;
  const res = selectableResources(refs?.resources);
  const resName = new Map((refs?.resources || []).map((r) => [r.id, r.name]));
  const state = { cat, when, viewMode, statusFilter, productFilter, dayFilter, month: /^\d{4}-\d{2}$/.test(q.get('kk') || '') ? q.get('kk') : todayHel().slice(0, 7) };
  const listQuery = (extra = {}) => ({ kategoria: state.cat, jakso: state.when === 'tulevat' ? '' : state.when, tuote: state.productFilter || '', tila: state.statusFilter, nakyma: state.viewMode === 'kalenteri' ? 'kalenteri' : '', paiva: state.dayFilter, kk: state.viewMode === 'kalenteri' ? state.month : '', ...extra });
  const go = (extra = {}) => { location.hash = hrefOf(listQuery(extra)); };
  const refresh = () => { ctx.refs = null; reload(); };
  const list = await rpc('admin_event_list', { p_category: cat || null, p_include_past: when !== 'tulevat' || !!openId });

  if (openId) {
    const p = (list || []).find((x) => x.product_id === openId);
    if (!p) return [h('p', {}, h('a', { href: hrefOf(listQuery()), text: `‹ ${T('title')}` })), h('p', { class: 'empty', text: T('empty') })];
    const [peopleRaw, logRaw] = await Promise.all([
      rpc('admin_event_participants', { p_product_id: p.product_id, p_rule_id: null }).catch((e) => ({ error: e })),
      rpc('admin_event_messages_list', { p_product_id: p.product_id }).catch((e) => ({ error: e })),
    ]);
    return detail(p, Array.isArray(peopleRaw) ? peopleRaw : [], peopleRaw?.error || null, Array.isArray(logRaw) ? logRaw : [], logRaw?.error || null);
  }
  return overview(list || []);

  function flagsOf(p, r) { return occurrenceFlags(r, { saleEnabled: p.sale_enabled !== false }); }
  function statusNodes(flags) {
    const nodes = [badge(STATUS_KIND[flags.status] || 'muted', T(STATUS_KEY[flags.status] || 'status_all'))];
    if (flags.full && flags.status !== 'full' && flags.status !== 'cancelled') nodes.push(badge('err', T('status_full')));
    if (!flags.active && flags.status !== 'cancelled' && flags.status !== 'sales_closed') nodes.push(badge('muted', T('badge_inactive')));
    return nodes;
  }
  function capNode(flags) {
    if (flags.max == null) return h('span', { text: T('sold_nomax', { sold: flags.sold }) });
    const pct = flags.max > 0 ? Math.max(0, Math.min(100, Math.round((flags.sold / flags.max) * 100))) : 0;
    const fill = h('span', { class: 'ev-cap-fill' });
    fill.style.width = `${pct}%`;
    return h('span', { class: 'ev-cap' }, h('span', { class: 'ev-cap-track', 'aria-hidden': 'true' }, fill), h('span', { class: 'ev-cap-num', text: T('sold', { sold: flags.sold, max: flags.max }) }));
  }
  function matches(p, r, flags) {
    if (state.productFilter && p.product_id !== state.productFilter) return false;
    if (state.when === 'tulevat' && (flags.past || flags.status === 'past')) return false;
    if (state.when === 'menneet' && !flags.past) return false;
    if (state.statusFilter === 'full') return flags.full && !flags.cancelled;
    if (state.statusFilter && flags.status !== state.statusFilter) return false;
    if (state.dayFilter && r.date !== state.dayFilter) return false;
    return true;
  }
  function rowsOf(products) {
    const rows = [];
    for (const p of products) for (const r of p.rules || []) {
      const flags = flagsOf(p, r);
      if (matches(p, r, flags)) rows.push({ p, r, flags });
    }
    rows.sort((a, b) => String(a.r.starts_at).localeCompare(String(b.r.starts_at)) || a.r.id - b.r.id);
    return rows;
  }

  function overview(products) {
    const rows = rowsOf(products);
    const saleOff = products.some((p) => p.sale_enabled === false);
    const upcoming = rows.filter((x) => !x.flags.past);
    const soldSum = upcoming.reduce((n, x) => n + x.flags.sold, 0);
    const next = upcoming[0];
    const seg = (name, value, options, testid) => h('fieldset', { class: 'srcset ev-filter', 'data-testid': testid }, h('legend', { class: 'sr', text: T('title') }),
      options.map(([v, label]) => h('label', { class: 'srcopt' },
        h('input', { type: 'radio', name, value: v, checked: v === value || null, 'data-testid': name === 'evwhen' && v === 'menneet' ? 'events-past' : null, onchange: () => {
          if (name === 'evwhen') state.when = v; else if (name === 'evcat') state.cat = v; else state.viewMode = v;
          go();
        } }), h('span', { text: label }))));
    const eventSel = h('select', { 'aria-label': T('filter_pick_event'), 'data-testid': 'events-event', onchange: (e) => { state.productFilter = Number(e.target.value) || 0; go(); } },
      h('option', { value: '', text: T('filter_event_all') }),
      products.map((p) => h('option', { value: p.product_id, text: p.name, selected: p.product_id === state.productFilter || null })));
    const statusSel = h('select', { 'aria-label': T('filter_status'), 'data-testid': 'events-status', onchange: (e) => { state.statusFilter = e.target.value; go(); } },
      [['', T('status_all')], ['on_sale', T('status_on_sale')], ['full', T('status_full')], ['cancelled', T('status_cancelled')], ['sales_closed', T('status_sales_closed')]]
        .map(([v, label]) => h('option', { value: v, text: label, selected: v === state.statusFilter || null })));
    const kpis = h('ul', { class: 'ev-kpis' },
      kpi(T('kpi_upcoming'), String(upcoming.length)),
      kpi(T('kpi_sold'), String(soldSum)),
      kpi(T('kpi_next'), next ? span(next.r.starts_at, next.r.ends_at) : '–'));
    const body = state.viewMode === 'kalenteri' ? calendarBlock(rows, products) : tableBlock(rows);
    return [h('h1', { text: T('title') }), h('p', { class: 'muted', text: canEdit ? T('lead_manage') : T('lead_staff') }),
      saleOff ? h('p', { class: 'ev-note', role: 'note', 'data-testid': 'events-sale-off', text: T('sale_off_note') }) : null,
      h('div', { class: 'ev-filters stack', 'data-testid': 'events-overview' },
        h('div', { class: 'row wrap' }, seg('evwhen', state.when, [['tulevat', T('when_upcoming')], ['menneet', T('when_past')], ['kaikki', T('when_all')]], 'events-when'),
          seg('evcat', state.cat, [['', T('filter_all')], ['event', T('filter_event')], ['training', T('filter_training')]], 'events-filter'),
          seg('evview', state.viewMode, [['lista', T('view_list')], ['kalenteri', T('view_calendar')]], 'events-view')),
        h('div', { class: 'row wrap' }, field(T('filter_pick_event'), eventSel), field(T('filter_status'), statusSel))),
      kpis, body];
  }
  function kpi(label, value) {
    return h('li', { class: 'card ev-kpi' }, h('span', { class: 'muted', text: label }), h('strong', { text: value }));
  }
  function quickLinks(p, r) {
    const q = { tapahtuma: p.product_id };
    return h('div', { class: 'row wrap ev-quick' },
      h('a', { class: 'btn sm', href: hrefOf(listQuery({ ...q, valilehti: 'yleiskatsaus' })) }, T('open')),
      h('a', { class: 'btn sm ghost', href: hrefOf(listQuery({ ...q, valilehti: 'osallistujat', kerta: r.id })) }, T('quick_people')),
      h('a', { class: 'btn sm ghost', href: hrefOf(listQuery({ ...q, valilehti: 'viestit', kerta: r.id })) }, T('quick_message')));
  }
  function tableBlock(rows) {
    if (!rows.length) return h('p', { class: 'empty', text: T('overview_empty') });
    const head = h('tr', {}, [T('col_when'), T('filter_pick_event'), T('col_sold'), T('col_status'), T('col_actions')].map((t) => h('th', { scope: 'col', text: t })));
    const body = rows.map(({ p, r, flags }) => h('tr', { 'data-testid': 'event-row' },
      h('td', { 'data-label': T('col_when') }, h('a', { href: hrefOf(listQuery({ tapahtuma: p.product_id, valilehti: 'kerrat' })), text: occLabel(r) }), h('div', { class: 'muted', text: span(r.starts_at, r.ends_at) })),
      h('td', { 'data-label': T('filter_pick_event') }, h('span', { text: p.name }), ' ', badge('muted', catName(p.category))),
      h('td', { 'data-label': T('col_sold') }, capNode(flags)),
      h('td', { 'data-label': T('col_status') }, h('span', { class: 'meta' }, statusNodes(flags))),
      h('td', { 'data-label': T('col_actions') }, quickLinks(p, r))));
    return h('div', { class: 'ev-table-wrap' }, h('table', { class: 'ev-table' }, h('thead', {}, head), h('tbody', {}, body)));
  }
  function calendarBlock(rows) {
    const grid = monthGrid(state.month, rows, (day) => { state.dayFilter = state.dayFilter === day ? '' : day; go(); }, (month) => { state.month = month; state.dayFilter = ''; go(); });
    const inMonth = rows.filter((x) => String(x.r.date || '').startsWith(state.month) && (!state.dayFilter || x.r.date === state.dayFilter));
    return h('div', { class: 'stack', 'data-testid': 'events-calendar' }, grid, tableBlock(inMonth));
  }

  function detail(p, people, peopleErr, log, logErr) {
    const back = h('p', {}, h('a', { href: hrefOf(listQuery()), 'data-testid': 'events-back', text: `‹ ${T('title')}` }));
    const head = h('div', { class: 'row between wrap' }, h('h1', { class: 'ev-name', text: p.name }),
      h('span', { class: 'meta' }, badge('muted', catName(p.category)), p.sale_enabled === false ? badge('warn', T('badge_sale_off')) : null, p.active === false ? badge('err', T('badge_hidden')) : null, canEdit ? null : badge('muted', T('read_only'))));
    const tablist = h('div', { class: 'tl-tabs ev-tabs', role: 'tablist', 'aria-label': p.name, 'data-testid': 'event-tabs' },
      TABS.map(([id, key]) => h('button', { type: 'button', class: 'tl-tabbtn', role: 'tab', 'aria-selected': String(id === tab), 'data-testid': `event-tab-${id}`, onclick: () => go({ tapahtuma: p.product_id, valilehti: id, kerta: kertaQ || '' }) }, T(key))));
    const panel = (id, ...nodes) => h('div', { hidden: tab !== id || null, 'data-testid': `event-panel-${id}`, class: id === tab ? null : 'ev-no-print' }, nodes);
    const rules = [...(p.rules || [])].sort((a, b) => String(a.starts_at).localeCompare(String(b.starts_at)));
    return [back, head, p.sale_enabled === false ? h('p', { class: 'ev-note ev-no-print', role: 'note', text: T('sale_off_note') }) : null, tablist,
      panel('yleiskatsaus', eventOverview(p, rules)),
      panel('kerrat', canEdit ? addPanel(p) : null, rules.length ? h('ul', { class: 'ev-occ' }, rules.map((r) => occItem(p, r))) : h('p', { class: 'muted', text: T('no_occurrences') })),
      panel('osallistujat', participantsPanel(p, rules, people, peopleErr)),
      panel('viestit', messagesPanel(p, rules, people, log, logErr)),
      panel('asetukset', settingsPanel(p))];
  }

  function eventOverview(p, rules) {
    const rows = rules.map((r) => ({ p, r, flags: flagsOf(p, r) })).filter((x) => !x.flags.past && x.flags.status !== 'cancelled');
    const sold = rows.reduce((n, x) => n + x.flags.sold, 0);
    const next = rows[0];
    return h('div', { class: 'stack' },
      h('ul', { class: 'ev-kpis' }, kpi(T('kpi_upcoming'), String(rows.length)), kpi(T('kpi_sold'), String(sold)), kpi(T('kpi_next'), next ? span(next.r.starts_at, next.r.ends_at) : '–')),
      rows.length ? tableBlock(rows.slice(0, 8)) : h('p', { class: 'muted', text: T('no_occurrences') }));
  }

  function settingsPanel(p) {
    const cur = channelsOf(p);
    const boxes = CHANNELS.map((c) => h('label', { class: 'check' }, h('input', { type: 'checkbox', value: c, checked: cur.includes(c) || null, disabled: !canEdit, 'data-testid': `event-channel-${c}` }), ' ', T(`channel_${c}`)));
    const chanSave = canEdit ? h('button', { type: 'button', class: 'btn sm', 'data-testid': 'event-channels-save', text: T('save'), onclick: (e) => act(e.target, async () => {
      const next = normChannels(boxes.map((b) => b.querySelector('input')).filter((i) => i.checked).map((i) => i.value));
      await rpc('admin_event_set_channels', { p_product_id: p.product_id, p_channels: next }); toast(T('channels_saved'));
    }) }) : null;
    return h('div', { class: 'stack' },
      h('p', { class: 'muted', text: T('settings_lead') }),
      h('div', { class: 'row wrap' },
        h('a', { class: 'btn', href: `#/tuotteet?muokkaa=${p.product_id}`, 'data-testid': 'event-edit-product', text: T('edit_product') }),
        canEdit ? h('button', { type: 'button', class: 'btn', 'data-testid': 'event-copy', text: T('copy_event'), onclick: () => copyEvent(p) }) : null),
      h('fieldset', { class: 'card ev-chan', 'data-testid': 'event-channels' }, h('legend', { text: T('channels') }), h('div', { class: 'row wrap' }, boxes, chanSave)));
  }

  function occItem(p, r) {
    const flags = flagsOf(p, r);
    const label = occLabel(r);
    const blocksHost = h('div', { class: 'ev-blocks-host' });
    const editHost = h('div');
    const showBlocks = () => { blocksHost.replaceChildren(canEdit ? blocksEditor(p, r) : blocksReadOnly(r)); };
    const btn = (testid, text, onclick, cls = 'btn sm') => h('button', { type: 'button', class: cls, 'data-testid': testid, onclick }, text, h('span', { class: 'sr', text: ` – ${label}` }));
    const booked = bookingCount(r);
    const queue = eventQueueParts(h, { lang: getLang(), ruleId: r.id, rpc });
    const li = h('li', { class: `card ev-occ-item${flags.active && !flags.cancelled ? '' : ' off'}`, 'data-testid': 'event-occurrence' },
      h('div', { class: 'row between wrap' },
        h('div', {}, h('strong', { class: 'ev-occ-label', text: label }), h('div', { class: 'muted', text: span(r.starts_at, r.ends_at) })),
        h('div', { class: 'meta' }, capNode(flags), ...statusNodes(flags), flags.waitlist ? h('span', { class: 'muted', text: T('waitlist', { n: flags.waitlist }) }) : null)),
      h('div', { class: 'row wrap ev-occ-actions' },
        btn('event-occ-blocks', T('blocks'), () => showBlocks(), 'btn sm ghost'),
        h('a', { class: 'btn sm ghost', href: hrefOf(listQuery({ tapahtuma: p.product_id, valilehti: 'osallistujat', kerta: r.id })) }, T('quick_people')),
        queue.button,
        canEdit ? btn('event-occ-edit', T('edit_occurrence'), () => { editHost.replaceChildren(inlineForm(p, r, () => editHost.replaceChildren())); }) : null,
        canEdit ? btn('event-occ-copy', T('copy_to_date'), () => copyOcc(r)) : null,
        canEdit && booked ? btn('event-occ-cancel', T('cancel'), () => cancelOcc(r, label), 'btn sm danger') : null,
        canEdit ? btn('event-occ-delete', T('delete'), () => deleteOcc(p, r, label), 'btn sm danger') : null),
      queue.host,
      editHost, blocksHost);
    if ((r.blocks || []).length && !canEdit) showBlocks();
    return li;
  }

  function inlineForm(p, r, close) {
    const num = (name, v, o = {}) => h('input', { name, type: 'number', value: v ?? '', inputmode: 'numeric', ...o });
    const booked = bookingCount(r);
    const f = h('form', { class: 'stack ev-inline', 'data-testid': 'event-occ-form', novalidate: true },
      booked ? h('p', { class: 'ev-warn', text: T('warn_bookings', { n: booked }) }) : null,
      h('div', { class: 'row wrap' }, field(T('add_dates'), h('input', { name: 'date', type: 'date', value: r.date, required: true, min: r.date >= localParts(new Date().toISOString()).date ? localParts(new Date().toISOString()).date : null })), field(T('add_times'), h('input', { name: 'start_time', type: 'time', value: String(r.start_time || '').slice(0, 5), required: true })), field(T('duration'), num('duration_minutes', r.duration_minutes, { min: 15, max: 20160 }))),
      h('div', { class: 'row wrap' }, field(T('max_persons'), num('max_persons', r.max_persons, { min: 1, max: 500, 'data-testid': 'event-occ-max' })), field(T('min_persons'), num('min_persons', r.min_persons, { min: 1, max: 500 })), field(T('deadline'), num('deadline_minutes', r.deadline_minutes, { min: 0, max: 20160 }))),
      h('div', { class: 'row wrap' }, field(T('label_fi'), h('input', { name: 'label', value: r.label || '', maxlength: 200 })), field(T('label_en'), h('input', { name: 'label_en', value: r.label_en || '', maxlength: 200 }))),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'active', checked: r.active !== false && !r.cancelled_at || null, disabled: booked ? true : null }), ' ', T('active')),
      h('div', { class: 'row wrap' }, h('button', { type: 'submit', class: 'btn primary', 'data-testid': 'event-occ-save', text: T('occ_inline_save') }), h('button', { type: 'button', class: 'btn ghost', text: T('time_changed_skip'), onclick: () => close() })));
    f.addEventListener('submit', (ev) => { ev.preventDefault(); act(f.querySelector('[data-testid="event-occ-save"]'), async () => {
      const fd = new FormData(f), n = (k) => (String(fd.get(k) ?? '').trim() === '' ? null : Number(fd.get(k)));
      const patch = { date: fd.get('date'), start_time: String(fd.get('start_time') || '').slice(0, 5), duration_minutes: n('duration_minutes'),
        max_persons: n('max_persons'), min_persons: n('min_persons'), deadline_minutes: n('deadline_minutes'), label: String(fd.get('label') || '').trim() || null, label_en: String(fd.get('label_en') || '').trim() || null, active: f.active.checked && !r.cancelled_at };
      if (isPastMove({ date: r.date, start_time: r.start_time }, { date: patch.date, start_time: patch.start_time })) { toast(T('err_past_move'), 'err'); return; }
      const before = `${r.date}|${String(r.start_time).slice(0, 5)}|${r.duration_minutes}`;
      const out = await rpc('admin_event_rule_upsert', { p_id: r.id, p_product_id: null, p_patch: patch });
      const after = `${out?.date}|${String(out?.start_time || '').slice(0, 5)}|${out?.duration_minutes}`;
      toast(T('saved'));
      if ((Number(out?.moved_bookings) > 0 || (before !== after && booked > 0))) offerTimeMessage(p, r, out);
      else refresh();
    }); });
    return f;
  }
  function offerTimeMessage(p, r, out) {
    const label = occLabel(out || r);
    const when = out?.starts_at ? span(out.starts_at, out.ends_at) : '';
    const f = h('div', { class: 'stack' }, h('p', { text: T('time_changed_body') }), h('div', { class: 'row wrap' },
      h('button', { type: 'button', class: 'btn primary', 'data-testid': 'event-time-message', text: T('time_changed_send'), onclick: () => {
        try { sessionStorage.setItem('ev-msg-draft', JSON.stringify({ product_id: p.product_id, rule_id: r.id, subject: T('time_changed_subject', { label }), body: T('time_changed_draft', { when }) })); } catch { /* ei tallennustilaa */ }
        d.close(); go({ tapahtuma: p.product_id, valilehti: 'viestit', kerta: r.id });
      } }),
      h('button', { type: 'button', class: 'btn', text: T('time_changed_skip'), onclick: () => { d.close(); refresh(); } })));
    const d = dialog(T('time_changed_title'), f);
  }
  function copyOcc(r) {
    const date = h('input', { type: 'date', required: true, min: todayHel(), 'data-testid': 'event-occ-copy-date' });
    const f = h('form', { class: 'stack' }, field(T('copy_date'), date), h('button', { type: 'submit', class: 'btn primary', 'data-testid': 'event-occ-copy-submit', text: T('copy_to_date') }));
    const d = dialog(T('copy_to_date'), f);
    f.addEventListener('submit', (ev) => { ev.preventDefault(); if (!date.value) { date.focus(); return; } act(f.querySelector('button'), async () => {
      await rpc('admin_event_rule_copy', { p_rule_id: r.id, p_date: date.value }); toast(T('copied_rule')); d.close(); refresh(); }); });
  }
  function deleteOcc(p, r, label) {
    if (bookingCount(r) || r.waitlist_count) {
      const f = h('div', { class: 'stack' }, h('p', { text: T('cancel_instead') }), h('button', { type: 'button', class: 'btn danger', 'data-testid': 'event-occ-cancel-instead', text: T('cancel'), onclick: () => { d.close(); cancelOcc(r, label); } }));
      const d = dialog(T('delete'), f);
      return;
    }
    const f = h('form', { class: 'stack' }, h('p', { text: T('delete_confirm', { label }) }), h('button', { type: 'submit', class: 'btn danger', 'data-testid': 'event-occ-delete-confirm', text: T('delete') }));
    const d = dialog(T('delete'), f);
    f.addEventListener('submit', (ev) => { ev.preventDefault(); act(f.querySelector('button'), async () => {
      await rpc('admin_event_rule_delete', { p_id: r.id }); toast(T('deleted')); d.close(); refresh(); }); });
  }
  function cancelOcc(r, label) {
    const f = h('form', { class: 'stack' }, h('p', { text: T('cancel_confirm', { label }) }), h('button', { type: 'submit', class: 'btn danger', 'data-testid': 'event-occ-cancel-confirm', text: T('cancel') }));
    const d = dialog(T('cancel'), f);
    f.addEventListener('submit', (ev) => { ev.preventDefault(); act(f.querySelector('button'), async () => {
      await rpc('admin_event_occurrence_cancel', { p_id: r.id }); toast(T('cancelled_done')); d.close(); refresh(); }); });
  }
  function copyEvent(p) {
    const inc = h('input', { type: 'checkbox', name: 'include_rules', 'data-testid': 'event-copy-rules' });
    const shift = h('input', { type: 'number', name: 'shift_days', value: 7, min: -3650, max: 3650, inputmode: 'numeric', 'data-testid': 'event-copy-shift' });
    const msg = h('p', { class: 'err', role: 'alert' });
    const f = h('form', { class: 'stack', 'data-testid': 'event-copy-form' },
      h('p', { text: T('ui.admin.product.copy_confirm', { name: copyName(p.name) }) }),
      h('label', { class: 'check' }, inc, ' ', T('copy_include_rules')), field(T('copy_shift'), shift, T('copy_shift_hint')), msg,
      h('button', { type: 'submit', class: 'btn primary', 'data-testid': 'event-copy-submit', text: T('ui.admin.product.copy_submit') }));
    const d = dialog(T('copy_event'), f);
    f.addEventListener('submit', (ev) => { ev.preventDefault(); const a = copyArgs({ product_id: p.product_id, event: true, include_rules: inc.checked, shift_days: shift.value });
      if (!a.ok) { msg.textContent = T(`err_${a.error}`); return; }
      act(f.querySelector('button'), async () => { const out = await rpc(a.fn, a.args); toast(T('copied_event', { n: out?.rules_copied ?? 0 })); d.close(); ctx.refs = null; go({ tapahtuma: out?.product_id, valilehti: 'yleiskatsaus' }); }); });
  }

  function addPanel(p) {
    const today = todayHel();
    const stateA = { cursor: today.slice(0, 7), selected: new Set(), repeat: false, weekdays: new Set([weekdayIso(today)]), from: today, until: addDaysIso(today, 28), times: ['17:00'] };
    const gridHost = h('div', { class: 'ev-month', 'data-testid': 'event-add-calendar' });
    const timesHost = h('div', { class: 'stack' });
    const previewHost = h('div', { 'data-testid': 'event-add-preview-list' });
    const datesMirror = h('input', { type: 'hidden', 'data-testid': 'event-add-dates' });
    const num = (name, v, o = {}) => h('input', { name, type: 'number', value: v ?? '', inputmode: 'numeric', ...o });
    const dur = num('duration_minutes', p.duration_minutes || 120, { min: 15, max: 20160, 'data-testid': 'event-add-duration' });
    const max = num('max_persons', p.max_persons ?? '', { min: 1, max: 500, 'data-testid': 'event-add-max' });
    const min = num('min_persons', '', { min: 1, max: 500 });
    const dl = num('deadline_minutes', '', { min: 0, max: 20160 });
    const lab = h('input', { name: 'label', maxlength: 200 }), labEn = h('input', { name: 'label_en', maxlength: 200 });
    const from = h('input', { type: 'date', value: stateA.from, 'data-testid': 'event-repeat-from', onchange: (e) => { stateA.from = e.target.value; paint(); } });
    const until = h('input', { type: 'date', value: stateA.until, 'data-testid': 'event-repeat-until', onchange: (e) => { stateA.until = e.target.value; paint(); } });
    const repeatBox = h('input', { type: 'checkbox', 'data-testid': 'event-add-repeat', onchange: (e) => { stateA.repeat = e.target.checked; paint(); } });
    const weekdayBoxes = [1, 2, 3, 4, 5, 6, 7].map((d) => h('label', { class: 'check ev-wd' }, h('input', { type: 'checkbox', checked: stateA.weekdays.has(d) || null, onchange: (e) => { if (e.target.checked) stateA.weekdays.add(d); else stateA.weekdays.delete(d); paint(); } }), ' ', T(`wd_${d}`)));
    const repeatRow = h('div', { class: 'stack', hidden: true }, h('div', { class: 'row wrap' }, field(T('repeat_from'), from), field(T('repeat_until'), until)), h('div', { class: 'row wrap', role: 'group', 'aria-label': T('repeat') }, weekdayBoxes));
    function seriesNow() {
      let dates = [...stateA.selected];
      if (stateA.repeat) {
        const rep = buildSeries({ dates, times: stateA.times, repeat: { from: stateA.from, until: stateA.until, weekdays: [...stateA.weekdays] }, duration_minutes: dur.value, max_persons: max.value, min_persons: min.value, deadline_minutes: dl.value, label: lab.value, label_en: labEn.value });
        return rep;
      }
      return buildSeries({ dates, times: stateA.times, duration_minutes: dur.value, max_persons: max.value, min_persons: min.value, deadline_minutes: dl.value, label: lab.value, label_en: labEn.value });
    }
    function paintTimes() {
      timesHost.replaceChildren(...stateA.times.map((tm, i) => h('div', { class: 'row wrap' },
        h('input', { type: 'time', value: tm, 'data-testid': i === 0 ? 'event-add-times' : null, 'aria-label': T('add_times'), onchange: (e) => { stateA.times[i] = e.target.value; paintPreview(); } }),
        stateA.times.length > 1 ? h('button', { type: 'button', class: 'btn sm ghost', text: T('remove_time'), onclick: () => { stateA.times.splice(i, 1); paintTimes(); paintPreview(); } }) : null)));
    }
    function paintGrid() {
      gridHost.replaceChildren(monthGrid(stateA.cursor, [], (day) => {
        if (stateA.selected.has(day)) stateA.selected.delete(day); else stateA.selected.add(day);
        paintGrid(); paintPreview();
      }, (month) => { stateA.cursor = month; paintGrid(); }, stateA.selected));
    }
    function paintPreview() {
      const r = seriesNow();
      datesMirror.value = r.ok ? r.patches.map((x) => x.date).filter((d, i, a) => a.indexOf(d) === i).join(', ') : [...stateA.selected].sort().join(', ');
      if (!r.ok) {
        const msg = (datesMirror.value || stateA.repeat || stateA.times.some(Boolean)) ? T(`err_${r.error}`, { list: (r.invalid || []).join(', '), n: r.count }) : T('preview_empty');
        previewHost.replaceChildren(h('p', { class: 'muted', role: 'status', 'data-testid': 'event-add-preview', text: msg }));
        return;
      }
      previewHost.replaceChildren(h('h3', { text: T('preview_title') }), h('p', { class: 'muted', role: 'status', 'data-testid': 'event-add-preview', text: T('add_preview', { n: r.patches.length }) }),
        h('ul', { class: 'ev-preview' }, r.patches.map((x) => h('li', { text: `${defaultLabel(x.date, x.start_time, getLang())} · ${x.duration_minutes} min` }))));
    }
    function paint() { repeatRow.hidden = !stateA.repeat; paintGrid(); paintTimes(); paintPreview(); }
    const submit = h('button', { type: 'submit', class: 'btn primary', 'data-testid': 'event-add-submit', text: T('confirm_create') });
    const f = h('form', { class: 'card stack ev-add', 'data-testid': 'event-add-form', novalidate: true },
      h('h2', { text: T('add_open') }), h('p', { class: 'muted', text: T('pick_hint') }),
      h('div', { class: 'row between wrap' }, h('strong', { text: T('pick_dates') })),
      gridHost, datesMirror,
      h('label', { class: 'check' }, repeatBox, ' ', T('repeat')), repeatRow,
      h('div', { class: 'row wrap' }, h('strong', { text: T('add_times') }), h('button', { type: 'button', class: 'btn sm', text: T('add_time'), onclick: () => { stateA.times.push('17:00'); paintTimes(); } })),
      timesHost,
      h('div', { class: 'row wrap' }, field(T('duration'), dur), field(T('max_persons'), max, T('max_hint')), field(T('min_persons'), min), field(T('deadline'), dl)),
      h('div', { class: 'row wrap' }, field(T('label_fi'), lab, T('label_hint', { example: defaultLabel(today, '17:00', 'fi') })), field(T('label_en'), labEn, T('label_hint', { example: defaultLabel(today, '17:00', 'en') }))),
      previewHost, submit);
    for (const el of [dur, max, min, dl, lab, labEn]) el.addEventListener('input', paintPreview);
    f.addEventListener('submit', (ev) => { ev.preventDefault(); const r = seriesNow();
      if (!r.ok) { toast(T(`err_${r.error}`, { list: (r.invalid || []).join(', '), n: r.count }), 'err'); paintPreview(); return; }
      const okBtn = h('button', { type: 'submit', class: 'btn primary', 'data-testid': 'event-add-confirm', text: T('confirm_create') });
      const list = h('ul', { class: 'ev-preview' }, r.patches.map((x) => h('li', { text: `${defaultLabel(x.date, x.start_time, getLang())}` })));
      const box = h('form', { class: 'stack' }, h('p', { text: T('add_preview', { n: r.patches.length }) }), list, okBtn);
      const d = dialog(T('preview_title'), box);
      box.addEventListener('submit', (e2) => { e2.preventDefault(); act(okBtn, async () => {
        let ok = 0;
        for (const patch of r.patches) {
          try { await rpc('admin_event_rule_upsert', { p_id: null, p_product_id: p.product_id, p_patch: patch }); ok++; }
          catch (e) { toast(T('add_partial', { ok, n: r.patches.length, error: evErr(e) }), 'err'); d.close(); if (ok) refresh(); return; }
        }
        toast(T('added', { n: ok })); d.close(); refresh();
      }); });
    });
    paint();
    return f;
  }

  function participantsPanel(p, rules, people, peopleErr) {
    if (peopleErr) return h('p', { class: 'ev-note', role: 'status', text: T('participants_unavailable') });
    let ruleId = kertaQ || 0;
    const host = h('div', { class: 'stack', 'data-testid': 'event-participants' });
    const sel = h('select', { 'aria-label': T('occurrences'), 'data-testid': 'event-participants-rule', onchange: (e) => { ruleId = Number(e.target.value) || 0; draw(); } },
      h('option', { value: '', text: T('participants_all') }),
      rules.map((r) => h('option', { value: r.id, text: occLabel(r), selected: r.id === ruleId || null })));
    function shown() { return people.filter((x) => !ruleId || x.rule_id === ruleId); }
    function extraText(row) {
      const bits = [];
      const opt = (getLang() === 'en' && row.option_label_en) || row.option_label;
      if (opt) bits.push(`${T('extra_option')}: ${opt}`);
      if (row.customer_note) bits.push(`${T('extra_customer')}: ${row.customer_note}`);
      if (row.adults) bits.push(`${row.adults} ${T('extra_adults')}`);
      if (row.children) bits.push(`${row.children} ${T('extra_children')}`);
      return bits.join('\n');
    }
    function csvRows(list) {
      return list.map((row) => ({
        occurrence: occLabel(rules.find((r) => r.id === row.rule_id) || { date: '', start_time: '00:00', label: row.occurrence_label }),
        name: row.name || '', email: row.email || '', phone: row.phone || '', persons: row.persons ?? '',
        order_status: STATUS[row.order_status] || row.order_status || '', payment_status: PAY[row.payment_status] || row.payment_status || '',
        booked_at: row.booked_at ? fmtDT(row.booked_at) : '', extra: extraText(row).replace(/\n/g, ' | '), note: row.staff_note || '',
      }));
    }
    function draw() {
      const list = shown();
      const headers = [T('occurrences'), T('col_name'), T('col_contact'), T('col_contact'), T('col_persons'), T('col_status'), T('col_payment'), T('col_booked'), T('col_extra'), T('col_note')];
      host.replaceChildren(
        h('div', { class: 'row wrap ev-no-print' }, field(T('occurrences'), sel),
          h('button', { type: 'button', class: 'btn sm', 'data-testid': 'event-csv', text: T('csv_download'), onclick: () => downloadCsv(`osallistujat_${p.slug || p.product_id}.csv`, participantsToCsv(csvRows(list), headers)) }),
          h('button', { type: 'button', class: 'btn sm', 'data-testid': 'event-print', text: T('print_list'), onclick: () => printList() })),
        list.length ? h('div', { class: 'ev-table-wrap ev-screen-only' }, h('table', { class: 'ev-table' },
          h('thead', {}, h('tr', {}, [T('occurrences'), T('col_name'), T('col_contact'), T('col_persons'), T('col_payment'), T('col_booked'), T('col_extra'), T('col_note')].map((t) => h('th', { scope: 'col', text: t })))),
          h('tbody', {}, list.map((row) => participantRow(row, rules))))) : h('p', { class: 'empty', text: T('participants_empty') }),
        printTable(list, rules));
    }
    function printList() {
      document.body.classList.add('ev-printing');
      const prev = document.title;
      document.title = `${T('print_title')} – ${p.name}`;
      const done = () => { document.body.classList.remove('ev-printing'); document.title = prev; window.removeEventListener('afterprint', done); };
      window.addEventListener('afterprint', done);
      window.print();
    }
    draw();
    return host;
  }
  function participantRow(row, rules) {
    const rule = rules.find((r) => r.id === row.rule_id);
    const note = h('textarea', { rows: 2, maxlength: 2000, 'data-testid': 'event-note', 'aria-label': T('note_placeholder') });
    note.value = row.staff_note || '';
    const email = String(row.email || '').trim();
    const phone = String(row.phone || '').trim();
    const contact = h('div', { class: 'ev-contact' },
      SAFE_EMAIL.test(email) ? h('a', { href: `mailto:${email}`, text: email }) : (email ? h('span', { text: email }) : null),
      SAFE_PHONE.test(phone) ? h('a', { href: `tel:${phone.replace(/\s/g, '')}`, text: phone }) : (phone ? h('span', { text: phone }) : null));
    const orderBits = h('div', {}, badge(`st-${row.order_status || 'pending'}`, STATUS[row.order_status] || row.order_status || '–'), ' ', badge(`pay-${row.payment_status || 'unpaid'}`, PAY[row.payment_status] || row.payment_status || '–'),
      row.order_no ? h('div', { class: 'muted', text: `#${row.order_no}` }) : null);
    return h('tr', { 'data-testid': 'event-participant' },
      h('td', { 'data-label': T('occurrences'), text: rule ? occLabel(rule) : (row.occurrence_label || '') }),
      h('td', { 'data-label': T('col_name'), text: row.name || '' }),
      h('td', { 'data-label': T('col_contact') }, contact),
      h('td', { 'data-label': T('col_persons'), text: String(row.persons ?? '') }),
      h('td', { 'data-label': T('col_payment') }, orderBits),
      h('td', { 'data-label': T('col_booked'), text: row.booked_at ? fmtDT(row.booked_at) : '' }),
      h('td', { 'data-label': T('col_extra'), class: 'ev-extra' }, extraNode(row)),
      h('td', { 'data-label': T('col_note') }, note, h('button', { type: 'button', class: 'btn sm', text: T('note_save'), onclick: (e) => act(e.target, async () => {
        const saved = await rpc('admin_event_participant_note_set', { p_reservation_id: row.reservation_id, p_note: note.value });
        row.staff_note = saved?.note || '';
        note.value = row.staff_note;
        toast(T('note_saved'));
      }) })));
  }
  function extraNode(row) {
    const opt = (getLang() === 'en' && row.option_label_en) || row.option_label;
    const bits = [];
    if (opt) bits.push(h('div', {}, h('span', { class: 'muted', text: `${T('extra_option')}: ` }), h('span', { text: opt })));
    if (row.customer_note) bits.push(h('div', {}, h('span', { class: 'muted', text: `${T('extra_customer')}: ` }), h('span', { text: row.customer_note })));
    if (row.adults) bits.push(h('div', { text: `${row.adults} ${T('extra_adults')}` }));
    if (row.children) bits.push(h('div', { text: `${row.children} ${T('extra_children')}` }));
    return bits.length ? h('div', {}, bits) : h('span', { class: 'muted', text: '–' });
  }
  function printTable(list, rules) {
    return h('div', { class: 'ev-print-only' }, h('h1', { text: `${T('print_title')}` }),
      h('table', { class: 'ev-table' }, h('thead', {}, h('tr', {}, [T('occurrences'), T('col_name'), T('col_contact'), T('col_persons'), T('col_payment'), T('col_booked'), T('col_extra'), T('col_note')].map((t) => h('th', { scope: 'col', text: t })))),
        h('tbody', {}, list.map((row) => {
          const rule = rules.find((r) => r.id === row.rule_id);
          const opt = (getLang() === 'en' && row.option_label_en) || row.option_label || '';
          const extra = [opt && `${T('extra_option')}: ${opt}`, row.customer_note && `${T('extra_customer')}: ${row.customer_note}`].filter(Boolean).join(' · ');
          return h('tr', {},
            h('td', { text: rule ? occLabel(rule) : '' }), h('td', { text: row.name || '' }), h('td', { text: [row.email, row.phone].filter(Boolean).join(' · ') }),
            h('td', { text: String(row.persons ?? '') }), h('td', { text: `${STATUS[row.order_status] || ''} ${PAY[row.payment_status] || ''}`.trim() }),
            h('td', { text: row.booked_at ? fmtDT(row.booked_at) : '' }), h('td', { text: extra }), h('td', { text: row.staff_note || '' }));
        }))));
  }

  function messagesPanel(p, rules, people, log, logErr) {
    if (logErr && !canSend) return h('p', { class: 'ev-note', text: T('messages_unavailable') });
    let draft = null;
    try { draft = JSON.parse(sessionStorage.getItem('ev-msg-draft') || 'null'); if (draft?.product_id === p.product_id) sessionStorage.removeItem('ev-msg-draft'); else draft = null; } catch { draft = null; }
    const subject = h('input', { maxlength: 200, 'data-testid': 'event-msg-subject', value: draft?.subject || '' });
    const body = h('textarea', { rows: 6, maxlength: 4000, 'data-testid': 'event-msg-body' });
    body.value = draft?.body || '';
    const initialScope = draft?.rule_id || kertaQ || 0;
    const scope = h('select', { 'data-testid': 'event-msg-scope', 'aria-label': T('msg_scope_all') },
      h('option', { value: '', text: T('msg_scope_all'), selected: !initialScope || null }),
      rules.map((r) => h('option', { value: r.id, text: occLabel(r), selected: r.id === initialScope || null })));
    const previewHost = h('div', { class: 'card ev-preview-card', 'data-testid': 'event-message-preview' });
    const confirm = h('input', { type: 'checkbox', 'data-testid': 'event-msg-confirm' });
    let lastPreview = null;
    function scopeId() { return Number(scope.value) || null; }
    function localPreview() {
      const rule = rules.find((r) => r.id === scopeId());
      const eventName = p.name;
      const whenText = rule ? span(rule.starts_at, rule.ends_at) : '';
      return customerMessageText({ subject: subject.value, body: body.value, eventName, whenText, lang: getLang() });
    }
    const previewBtn = h('button', { type: 'button', class: 'btn', 'data-testid': 'event-msg-preview', text: T('msg_preview'), onclick: (e) => act(e.target, async () => {
      const local = localPreview();
      if (!local.ok) { toast(T(`err_${local.error}`), 'err'); return; }
      const resPrev = await rpc('admin_event_message_send', { p_product_id: p.product_id, p_rule_id: scopeId(), p_subject: local.subject, p_body: local.body, p_confirm: false });
      lastPreview = resPrev;
      const names = (resPrev?.recipients || []).slice(0, 12);
      previewHost.replaceChildren(
        h('p', {}, h('strong', { text: T('msg_recipients', { n: resPrev?.recipient_count ?? 0 }) }), resPrev?.skipped_count ? h('span', { class: 'muted', text: ` · ${T('msg_skipped', { n: resPrev.skipped_count })}` }) : null),
        names.length ? h('ul', { class: 'ev-preview' }, names.map((r) => h('li', { text: `${r.name || '–'} · ${r.persons ?? ''}` }))) : null,
        h('pre', { class: 'ev-mail', text: local.text }));
    }) });
    const sendBtn = h('button', { type: 'submit', class: 'btn primary', 'data-testid': 'event-message-send', text: T('msg_send'), disabled: canSend ? null : true });
    const form = h('form', { class: 'stack card', 'data-testid': 'event-message-form', novalidate: true },
      h('h2', { text: T('tab_messages') }),
      h('p', { class: 'muted', text: T('msg_sign_note') }),
      canSend ? null : h('p', { class: 'ev-note', text: T('read_only') }),
      field(T('msg_scope_all'), scope),
      field(T('msg_subject'), subject),
      field(T('msg_body'), body),
      h('div', { class: 'row wrap' }, previewBtn),
      previewHost,
      h('label', { class: 'check' }, confirm, ' ', T('msg_confirm')),
      sendBtn);
    form.addEventListener('submit', (ev) => { ev.preventDefault();
      const local = localPreview();
      if (!local.ok) { toast(T(`err_${local.error}`), 'err'); return; }
      if (!confirm.checked || !lastPreview) { toast(T('err_no_confirm'), 'err'); return; }
      if (!lastPreview.recipient_count) { toast(T('err_no_recipients'), 'err'); return; }
      act(sendBtn, async () => {
        const out = await rpc('admin_event_message_send', { p_product_id: p.product_id, p_rule_id: scopeId(), p_subject: local.subject, p_body: local.body, p_confirm: true });
        toast(T('msg_sent', { n: out?.queued_count ?? out?.recipient_count ?? 0 }));
        refresh();
      });
    });
    const logList = logErr ? h('p', { class: 'ev-note', text: T('messages_unavailable') })
      : (log.length ? h('ul', { class: 'ev-log', 'data-testid': 'event-message-log' }, log.map((m) => h('li', { class: 'card' },
        h('strong', { text: T('msg_queued_line', { when: m.created_at ? fmtDT(m.created_at) : '', subject: m.subject || '', n: m.queued_count ?? m.recipient_count ?? 0 }) }),
        m.skipped_count ? h('div', { class: 'muted', text: T('msg_skipped', { n: m.skipped_count }) }) : null,
        h('pre', { class: 'ev-mail', text: m.body || '' })))) : h('p', { class: 'muted', text: T('msg_log_empty') }));
    return h('div', { class: 'stack' }, form, h('section', {}, h('h2', { text: T('msg_log') }), logList), people ? null : null);
  }

  function blocksReadOnly(r) {
    const rows = (r.blocks || []).map((b) => blockToRow(b, r));
    if (!rows.length) return h('p', { class: 'muted', text: T('blocks_none') });
    return h('div', { class: 'stack' }, h('ul', { class: 'ev-block-ro' }, (r.blocks || []).map((b) => h('li', {}, h('strong', { text: b.resource_name || resName.get(b.resource_id) || String(b.resource_id) }), ' ', h('span', { class: 'muted', text: `${span(b.starts_at, b.ends_at)} · ${T(`mode_${b.mode}`)}${b.note ? ` · ${b.note}` : ''}` })))), timelineNode(r, rows));
  }
  function timelineNode(r, rows) {
    const tl = timeline(r, rows);
    const bar = (cls, g, text) => h('div', { class: 'ev-tl-row' }, h('span', { class: 'ev-tl-name', text }), h('span', { class: 'ev-tl-track' }, g ? barEl(cls, g) : null));
    return h('div', { class: 'ev-tl', role: 'img', 'aria-label': `${T('timeline')}: ${span(tl.from, tl.to)}`, 'data-testid': 'event-timeline' },
      h('div', { class: 'ev-tl-scale muted' }, h('span', { text: fmtTime(tl.from) }), h('span', { text: fmtTime(tl.to) })),
      bar('occ', tl.occ, T('timeline_occurrence')), rows.map((x, i) => bar(x.mode === 'shared' ? 'shared' : 'excl', tl.bars[i], resName.get(+x.resource_id) || '–')));
  }
  function blocksEditor(p, r) {
    const rows = (r.blocks || []).map((b) => blockToRow(b, r));
    const host = h('div', { class: 'stack ev-blocks', 'data-testid': 'event-blocks' });
    const conflicts = h('div', { role: 'alert', 'aria-live': 'assertive' });
    const occLocal = (iso) => { const x = localParts(iso); return `${x.date}T${x.time}`; };
    const resSelect = (row) => h('select', { 'aria-label': T('block_resource'), 'data-testid': 'event-block-resource', onchange: (e) => { row.resource_id = +e.target.value || null; draw(); } },
      h('option', { value: '', text: '–' }),
      res.spaces.length ? h('optgroup', { label: T('block_spaces') }, res.spaces.map((x) => h('option', { value: x.id, text: x.name, selected: +row.resource_id === x.id || null }))) : null,
      res.persons.length ? h('optgroup', { label: T('block_persons') }, res.persons.map((x) => h('option', { value: x.id, text: x.name, selected: +row.resource_id === x.id || null }))) : null);
    function rowNode(row, i) {
      const v = validateBlock(r, row);
      const sel = (label, val, opts, on, testid) => field(label, h('select', { 'data-testid': testid, onchange: (e) => on(e.target.value) }, opts.map(([k, t]) => h('option', { value: k, text: t, selected: k === val || null }))));
      const numIn = (label, val, on, testid) => field(label, h('input', { type: 'number', value: val ?? '', step: 5, min: -1440, max: 20160, inputmode: 'numeric', 'data-testid': testid, onchange: (e) => on(e.target.value) }));
      const dtIn = (label, val, on, testid) => field(label, h('input', { type: 'datetime-local', value: val || '', step: 300, 'data-testid': testid, onchange: (e) => on(e.target.value) }));
      const timing = row.timing === 'relative'
        ? [numIn(T('block_from_min'), row.offset_min, (x) => { row.offset_min = x === '' ? '' : +x; row.minutes = (+row.end_min || 0) - (+row.offset_min || 0); draw(); }, 'event-block-from'),
          numIn(T('block_to_min'), row.end_min, (x) => { row.end_min = x === '' ? '' : +x; row.minutes = (+row.end_min || 0) - (+row.offset_min || 0); draw(); }, 'event-block-to')]
        : [dtIn(T('block_start'), row.start, (x) => { row.start = x; draw(); }, 'event-block-start'), dtIn(T('block_end'), row.end, (x) => { row.end = x; draw(); }, 'event-block-end')];
      const msg = !v.ok ? h('p', { class: 'err', role: 'alert', text: T(`err_${v.error}`) }) : v.warning ? h('p', { class: 'ev-warn', text: T('warn_outside') }) : null;
      return h('li', { class: `ev-block-row${v.ok ? '' : ' bad'}` },
        h('div', { class: 'row wrap' }, field(T('block_resource'), resSelect(row)),
          sel(T('block_timing'), row.timing, [['relative', T('timing_relative')], ['clock', T('timing_clock')]], (x) => {
            if (x === row.timing) return;
            if (x === 'clock') { const s = Date.parse(r.starts_at) + (+row.offset_min || 0) * 60000; row.start = occLocal(new Date(s).toISOString()); row.end = occLocal(new Date(s + (+row.minutes || r.duration_minutes) * 60000).toISOString()); }
            else { row.offset_min = 0; row.end_min = r.duration_minutes; row.minutes = r.duration_minutes; }
            row.timing = x; draw(); }, 'event-block-timing'),
          ...timing,
          sel(T('block_mode'), row.mode, [['exclusive', T('mode_exclusive')], ['shared', T('mode_shared')]], (x) => { row.mode = x; draw(); }, 'event-block-mode'),
          field(T('block_note'), h('input', { value: row.note || '', maxlength: 500, onchange: (e) => { row.note = e.target.value; } })),
          h('button', { type: 'button', class: 'btn sm ghost', 'data-testid': 'event-block-remove', onclick: () => { rows.splice(i, 1); draw(); } }, T('block_remove'))),
        msg);
    }
    function draw() {
      host.replaceChildren(h('h3', { text: T('blocks') }), h('p', { class: 'muted', text: T('blocks_hint') }),
        rows.length ? h('ul', { class: 'ev-block-list' }, rows.map(rowNode)) : h('p', { class: 'muted', text: T('blocks_none') }),
        rows.length ? timelineNode(r, rows) : null,
        h('div', { class: 'row wrap' },
          h('button', { type: 'button', class: 'btn sm', 'data-testid': 'event-block-add', disabled: rows.length >= MAX_BLOCKS || null, onclick: () => { rows.push({ resource_id: null, mode: 'exclusive', timing: 'relative', offset_min: 0, end_min: r.duration_minutes, minutes: r.duration_minutes, note: '' }); draw(); } }, T('block_add')),
          h('button', { type: 'button', class: 'btn primary sm', 'data-testid': 'event-blocks-save', onclick: (e) => save(e.target) }, T('blocks_save'))),
        conflicts);
    }
    function save(btn) {
      conflicts.replaceChildren();
      const bad = rows.map((x) => validateBlock(r, x)).find((v) => !v.ok);
      if (bad) { toast(T(`err_${bad.error}`), 'err'); return; }
      act(btn, async () => {
        try { r.blocks = await rpc('admin_event_blocks_set', { p_rule_id: r.id, p_blocks: blocksPayload(rows) }); toast(T('blocks_saved')); }
        catch (e) {
          const c = e?.code === 'conflict' ? conflictsOf(e) : [];
          if (c.length) { conflicts.replaceChildren(h('div', { class: 'ev-conflicts', 'data-testid': 'event-conflicts' }, h('p', { class: 'err', text: T('err_conflict') }),
            h('ul', {}, c.map((x) => h('li', { text: `${x.resource_name} ${span(x.starts_at, x.ends_at)}${x.reason ? ` (${T(`reason_${x.reason}`)})` : ''}` }))))); return; }
          throw e;
        }
      });
    }
    draw();
    return host;
  }
}

function addDaysIso(ds, n) { const d = new Date(`${ds}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); }
function monthGrid(cursor, rows, onDay, onMonth, selected = null) {
  const [y, m] = cursor.split('-').map(Number);
  const firstDow = (new Date(Date.UTC(y, m - 1, 1)).getUTCDay() + 6) % 7;
  const days = new Date(Date.UTC(y, m, 0)).getUTCDate();
  const loc = getLang() === 'en' ? 'en-GB' : 'fi-FI';
  const title = new Intl.DateTimeFormat(loc, { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(Date.UTC(y, m - 1, 1)));
  const prev = m === 1 ? `${y - 1}-12` : `${y}-${String(m - 1).padStart(2, '0')}`;
  const next = m === 12 ? `${y + 1}-01` : `${y}-${String(m + 1).padStart(2, '0')}`;
  const counts = new Map();
  for (const row of rows || []) {
    const d = row.r?.date || row.date;
    if (d && d.startsWith(cursor)) counts.set(d, (counts.get(d) || 0) + 1);
  }
  const cells = [];
  for (let i = 0; i < firstDow; i++) cells.push(h('span', { class: 'ev-day pad' }));
  for (let d = 1; d <= days; d++) {
    const iso = `${cursor}-${String(d).padStart(2, '0')}`;
    const n = counts.get(iso) || 0;
    const on = selected?.has(iso);
    cells.push(h('button', { type: 'button', class: `ev-day${on ? ' on' : ''}${n ? ' has' : ''}`, 'aria-pressed': selected ? String(!!on) : null, 'data-date': iso, onclick: () => onDay(iso) },
      h('span', { class: 'ev-day-n', text: String(d) }), n ? h('span', { class: 'ev-day-c', text: String(n) }) : null));
  }
  const heads = [1, 2, 3, 4, 5, 6, 7].map((i) => h('span', { class: 'ev-dow', text: T(`wd_${i}`) }));
  return h('div', { class: 'ev-cal' },
    h('div', { class: 'row between' },
      h('button', { type: 'button', class: 'btn sm ghost', 'aria-label': T('cal_prev'), onclick: () => onMonth(prev) }, '‹'),
      h('strong', { text: title }),
      h('button', { type: 'button', class: 'btn sm ghost', 'aria-label': T('cal_next'), onclick: () => onMonth(next) }, '›')),
    h('div', { class: 'ev-cal-grid' }, heads, cells));
}
function barEl(cls, g) { const el = h('span', { class: `ev-tl-bar ${cls}` }); el.style.left = `${g.left}%`; el.style.width = `${g.width}%`; return el; }
async function act(btn, fn) {
  if (btn) btn.disabled = true;
  try { return await fn(); } catch (e) { toast(evErr(e), 'err'); } finally { if (btn) btn.disabled = false; }
}
