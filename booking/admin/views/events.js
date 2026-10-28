// booking_158: Tapahtumat ja koulutukset (#/tapahtumat). Lista → tapahtuma (#/tapahtumat?tapahtuma=<tuote-id>): kerrat, osallistujamäärät,
// resurssivaraukset (suhteellinen / kellonaika, aikajana), myyntikanavat ja kopiointi. Henkilökunta (staff) näkee, catalog.edit muokkaa.
// Kaikki käyttäjän syöttämät nimet piirretään textContentina (h(), ei HTML-merkkijonoja). Tekstit: events-texts.js (FI+EN, pending-import-57).
// RPC-sopimus: booking/docs/tapahtumat-158.md (admin_event_list, admin_event_rule_upsert/_delete/_copy, admin_event_blocks_set, admin_event_set_channels, admin_event_copy).
import { rpc } from '../sb.js';
import { h, dialog, field, toast, badge, errMsg, fmtDate, fmtTime, todayHel } from '../ui.js';
import { loadEventsTexts, evText as T } from '../events-texts.js';
import { getLang } from '../talous-i18n.js';
import { buildSeries, defaultLabel, validateBlock, blockToRow, blocksPayload, timeline, selectableResources, channelsOf, normChannels, CHANNELS,
  copyArgs, copyName, occSummary, conflictsOf, localParts, MAX_BLOCKS } from '../events-logic.js';
import { eventQueueParts } from '../event-waitlist.js';

const ERR_CODES = new Set(['conflict', 'has_reservations', 'has_waitlist', 'max_below_sold', 'multi_day_training_only', 'invalid_resource', 'not_event', 'event_managed']);
const evErr = (e) => (e?.code && ERR_CODES.has(e.code) ? T(`err_${e.code}`) : errMsg(e));
const span = (iso1, iso2) => {
  const a = localParts(iso1), b = localParts(iso2);
  return a.date === b.date ? `${fmtDate(iso1)} ${fmtTime(iso1)}–${fmtTime(iso2)}` : `${fmtDate(iso1)} ${fmtTime(iso1)} – ${fmtDate(iso2)} ${fmtTime(iso2)}`;
};
const catName = (c) => (c === 'training' ? T('cat_training') : T('cat_event'));
const hrefOf = (q) => { const s = new URLSearchParams(Object.entries(q).filter(([, v]) => v != null && v !== '' && v !== false)).toString(); return `#/tapahtumat${s ? `?${s}` : ''}`; };

export async function render({ ctx, refs, reload, query }) {
  await loadEventsTexts(rpc);
  const canEdit = ctx.can('catalog.edit');
  const q = query || new URLSearchParams();
  const cat = ['event', 'training'].includes(q.get('kategoria')) ? q.get('kategoria') : '';
  const past = q.get('menneet') === '1';
  const openId = Number(q.get('tapahtuma')) || null;
  const list = await rpc('admin_event_list', { p_category: cat || null, p_include_past: past || !!openId });
  const res = selectableResources(refs?.resources);
  const resName = new Map((refs?.resources || []).map((r) => [r.id, r.name]));
  const state = { cat, past };
  const go = (extra = {}) => { location.hash = hrefOf({ kategoria: state.cat, menneet: state.past ? '1' : '', ...extra }); };
  const refresh = () => { ctx.refs = null; reload(); };

  if (openId) {
    const p = (list || []).find((x) => x.product_id === openId);
    if (!p) return [h('p', {}, h('a', { href: hrefOf({ kategoria: cat }), text: `‹ ${T('title')}` })), h('p', { class: 'empty', text: T('empty') })];
    return detail(p);
  }

  // ---- lista ----
  const seg = h('fieldset', { class: 'srcset ev-filter', 'data-testid': 'events-filter' }, h('legend', { class: 'sr', text: T('title') }),
    [['', T('filter_all')], ['event', T('filter_event')], ['training', T('filter_training')]].map(([v, label]) => h('label', { class: 'srcopt' },
      h('input', { type: 'radio', name: 'evcat', value: v, checked: v === cat || null, onchange: () => { state.cat = v; go(); } }), h('span', { text: label }))));
  const pastBox = h('label', { class: 'check' }, h('input', { type: 'checkbox', checked: past || null, 'data-testid': 'events-past', onchange: (e) => { state.past = e.target.checked; go(); } }), ' ', T('show_past'));
  const saleOff = (list || []).some((p) => p.sale_enabled === false);
  const cards = (list || []).map((p) => {
    const rules = p.rules || [];
    const up = rules.filter((r) => past || !occSummary(r).past).slice(0, past ? 50 : 6);
    return h('li', { class: 'card ev-card', 'data-testid': 'event-card' },
      h('div', { class: 'row between wrap' },
        h('h2', { class: 'ev-name' }, h('a', { href: hrefOf({ kategoria: cat, menneet: past ? '1' : '', tapahtuma: p.product_id }), text: p.name })),
        h('span', { class: 'meta' }, badge('muted', catName(p.category)), p.sale_enabled === false ? badge('warn', T('badge_sale_off')) : null, p.active === false ? badge('err', T('badge_hidden')) : null)),
      h('p', { class: 'muted ev-channels' }, `${T('channels')}: `, channelsOf(p).map((c) => T(`channel_${c}`)).join(', ') || T('channels_none')),
      up.length ? h('ul', { class: 'ev-occ-mini' }, up.map((r) => { const s = occSummary(r);
        return h('li', {}, h('span', { text: span(r.starts_at, r.ends_at) }), ' ',
          h('span', { class: 'muted', text: s.max == null ? T('sold_nomax', { sold: s.sold }) : T('sold', { sold: s.sold, max: s.max }) }),
          s.waitlist ? h('span', { class: 'muted', text: ` · ${T('waitlist', { n: s.waitlist })}` }) : null,
          !s.active ? h('span', {}, ' ', badge('muted', T('badge_inactive'))) : null, s.full ? h('span', {}, ' ', badge('err', T('badge_full'))) : null); }))
        : h('p', { class: 'muted', text: T('no_occurrences') }),
      h('a', { class: 'btn sm', href: hrefOf({ kategoria: cat, menneet: past ? '1' : '', tapahtuma: p.product_id }), 'data-testid': 'event-open' }, T('open'), h('span', { class: 'sr', text: ` ${p.name}` })));
  });
  return [h('h1', { text: T('title') }), h('p', { class: 'muted', text: canEdit ? T('lead') : T('lead_staff') }),
    saleOff ? h('p', { class: 'ev-note', role: 'note', 'data-testid': 'events-sale-off', text: T('sale_off_note') }) : null,
    h('div', { class: 'row wrap ev-filters' }, seg, pastBox),
    cards.length ? h('ul', { class: 'ev-list' }, cards) : h('p', { class: 'empty', text: T('empty') })];

  // ---- yksi tapahtuma ----
  function detail(p) {
    const back = h('p', {}, h('a', { href: hrefOf({ kategoria: cat, menneet: past ? '1' : '' }), 'data-testid': 'events-back', text: `‹ ${T('title')}` }));
    const head = h('div', { class: 'row between wrap' }, h('h1', { class: 'ev-name', text: p.name }),
      h('span', { class: 'meta' }, badge('muted', catName(p.category)), p.sale_enabled === false ? badge('warn', T('badge_sale_off')) : null, p.active === false ? badge('err', T('badge_hidden')) : null, canEdit ? null : badge('muted', T('read_only'))));
    const actions = h('div', { class: 'row wrap' },
      h('a', { class: 'btn', href: `#/tuotteet?muokkaa=${p.product_id}`, 'data-testid': 'event-edit-product', text: T('edit_product') }),
      canEdit ? h('button', { type: 'button', class: 'btn', 'data-testid': 'event-copy', text: T('copy_event'), onclick: () => copyEvent(p) }) : null);
    // myyntikanavat
    const cur = channelsOf(p);
    const boxes = CHANNELS.map((c) => h('label', { class: 'check' }, h('input', { type: 'checkbox', value: c, checked: cur.includes(c) || null, disabled: !canEdit, 'data-testid': `event-channel-${c}` }), ' ', T(`channel_${c}`)));
    const chanSave = canEdit ? h('button', { type: 'button', class: 'btn sm', 'data-testid': 'event-channels-save', text: T('save'), onclick: (e) => act(e.target, async () => {
      const next = normChannels(boxes.map((b) => b.querySelector('input')).filter((i) => i.checked).map((i) => i.value));
      await rpc('admin_event_set_channels', { p_product_id: p.product_id, p_channels: next }); toast(T('channels_saved'));
    }) }) : null;
    const chan = h('fieldset', { class: 'card ev-chan', 'data-testid': 'event-channels' }, h('legend', { text: T('channels') }), h('div', { class: 'row wrap' }, boxes, chanSave));
    const occ = h('section', { class: 'stack', 'aria-labelledby': 'ev-occ-h' }, h('h2', { id: 'ev-occ-h', text: T('occurrences') }),
      (p.rules || []).length ? h('ul', { class: 'ev-occ' }, p.rules.map((r) => occItem(p, r))) : h('p', { class: 'muted', text: T('no_occurrences') }));
    return [back, head, p.sale_enabled === false ? h('p', { class: 'ev-note', role: 'note', text: T('sale_off_note') }) : null, actions, chan, canEdit ? addForm(p) : null, occ];
  }

  // Kertojen lisäys: päivät × alkuajat (yksi kerrallaan tai monivalinta). Päiväkenttä lisää päivän listaan.
  function addForm(p) {
    const today = todayHel();
    const dates = h('textarea', { name: 'dates', rows: 2, 'data-testid': 'event-add-dates', 'aria-describedby': 'ev-dates-hint' });
    const picker = h('input', { type: 'date', min: today, 'aria-label': T('add_pick_date'), 'data-testid': 'event-add-pick',
      onchange: (e) => { const v = e.target.value; if (!v) return; const cur = dates.value.split(/[\s,;]+/).filter(Boolean); if (!cur.includes(v)) dates.value = [...cur, v].join(', '); e.target.value = ''; preview(); } });
    const times = h('input', { name: 'times', value: '17:00', 'data-testid': 'event-add-times' });
    const num = (name, v, o = {}) => h('input', { name, type: 'number', value: v ?? '', inputmode: 'numeric', ...o });
    const dur = num('duration_minutes', p.duration_minutes || 120, { min: 15, max: 20160, 'data-testid': 'event-add-duration' });
    const max = num('max_persons', p.max_persons ?? '', { min: 1, max: 500, 'data-testid': 'event-add-max' });
    const min = num('min_persons', '', { min: 1, max: 500 });
    const dl = num('deadline_minutes', '', { min: 0, max: 20160 });
    const lab = h('input', { name: 'label', maxlength: 200 }), labEn = h('input', { name: 'label_en', maxlength: 200 });
    const out = h('p', { class: 'muted', role: 'status', 'aria-live': 'polite', 'data-testid': 'event-add-preview' });
    const read = () => buildSeries({ dates: dates.value, times: times.value, duration_minutes: dur.value, max_persons: max.value, min_persons: min.value, deadline_minutes: dl.value, label: lab.value, label_en: labEn.value });
    const seriesErr = (r) => T(`err_${r.error}`, { list: (r.invalid || []).join(', '), n: r.count });
    function preview() { const r = read(); out.textContent = r.ok ? T('add_preview', { n: r.patches.length }) : (dates.value.trim() ? seriesErr(r) : ''); }
    for (const el of [dates, times, dur, max, min, dl]) el.addEventListener('input', preview);
    const submit = h('button', { type: 'submit', class: 'btn primary', 'data-testid': 'event-add-submit', text: T('add_submit') });
    const f = h('form', { class: 'card stack ev-add', 'data-testid': 'event-add-form', novalidate: true },
      h('h2', { text: T('add_title') }), h('p', { class: 'muted', text: T('add_hint') }),
      h('div', { class: 'row wrap' }, field(T('add_dates'), dates), field(T('add_pick_date'), picker)),
      h('small', { id: 'ev-dates-hint', class: 'muted', text: T('add_dates_hint') }),
      h('div', { class: 'row wrap' }, field(T('add_times'), times, T('add_times_hint')), field(T('duration'), dur)),
      h('div', { class: 'row wrap' }, field(T('max_persons'), max, T('max_hint')), field(T('min_persons'), min), field(T('deadline'), dl)),
      h('div', { class: 'row wrap' }, field(T('label_fi'), lab, T('label_hint', { example: defaultLabel(today, '17:00', 'fi') })), field(T('label_en'), labEn, T('label_hint', { example: defaultLabel(today, '17:00', 'en') }))),
      out, submit);
    f.addEventListener('submit', (ev) => { ev.preventDefault(); const r = read();
      if (!r.ok) { out.textContent = seriesErr(r); toast(seriesErr(r), 'err'); return; }
      act(submit, async () => {
        let ok = 0;
        for (const patch of r.patches) {
          try { await rpc('admin_event_rule_upsert', { p_id: null, p_product_id: p.product_id, p_patch: patch }); ok++; }
          catch (e) { toast(T('add_partial', { ok, n: r.patches.length, error: evErr(e) }), 'err'); if (ok) refresh(); return; }
        }
        toast(T('added', { n: ok })); refresh();
      }); });
    return f;
  }

  function occItem(p, r) {
    const s = occSummary(r), label = (getLang() === 'en' && r.label_en) || r.label || defaultLabel(r.date, r.start_time);
    const blocksHost = h('div', { class: 'ev-blocks-host' });
    const showBlocks = () => { blocksHost.replaceChildren(canEdit ? blocksEditor(p, r) : blocksReadOnly(r)); };
    const btn = (testid, text, onclick, cls = 'btn sm') => h('button', { type: 'button', class: cls, 'data-testid': testid, onclick }, text, h('span', { class: 'sr', text: ` – ${label}` }));
    const queue = eventQueueParts(h, { lang: getLang(), ruleId: r.id, rpc });
    const li = h('li', { class: `card ev-occ-item${s.active ? '' : ' off'}`, 'data-testid': 'event-occurrence' },
      h('div', { class: 'row between wrap' },
        h('div', {}, h('strong', { class: 'ev-occ-label', text: label }), h('div', { class: 'muted', text: span(r.starts_at, r.ends_at) })),
        h('div', { class: 'meta' },
          h('span', { text: s.max == null ? T('sold_nomax', { sold: s.sold }) : T('sold', { sold: s.sold, max: s.max }) }),
          s.waitlist ? h('span', { class: 'muted', text: ` · ${T('waitlist', { n: s.waitlist })}` }) : null,
          !s.active ? badge('muted', T('badge_inactive')) : null, s.full ? badge('err', T('badge_full')) : null, s.past ? badge('muted', T('badge_past')) : null)),
      h('div', { class: 'row wrap ev-occ-actions' },
        btn('event-occ-blocks', T('blocks'), () => showBlocks(), 'btn sm ghost'),
        queue.button,
        canEdit ? btn('event-occ-edit', T('edit_occurrence'), () => editOcc(p, r)) : null,
        canEdit ? btn('event-occ-copy', T('copy_to_date'), () => copyOcc(r)) : null,
        canEdit ? btn('event-occ-delete', T('delete'), () => deleteOcc(r, label), 'btn sm danger') : null),
      queue.host,
      blocksHost);
    if ((r.blocks || []).length && !canEdit) showBlocks();
    return li;
  }

  function editOcc(p, r) {
    const num = (name, v, o = {}) => h('input', { name, type: 'number', value: v ?? '', inputmode: 'numeric', ...o });
    const f = h('form', { class: 'stack', 'data-testid': 'event-occ-form', novalidate: true },
      h('div', { class: 'row wrap' }, field(T('add_dates'), h('input', { name: 'date', type: 'date', value: r.date, required: true })), field(T('add_times'), h('input', { name: 'start_time', type: 'time', value: r.start_time, required: true })), field(T('duration'), num('duration_minutes', r.duration_minutes, { min: 15, max: 20160 }))),
      h('div', { class: 'row wrap' }, field(T('max_persons'), num('max_persons', r.max_persons, { min: 1, max: 500, 'data-testid': 'event-occ-max' })), field(T('min_persons'), num('min_persons', r.min_persons, { min: 1, max: 500 })), field(T('deadline'), num('deadline_minutes', r.deadline_minutes, { min: 0, max: 20160 }))),
      h('div', { class: 'row wrap' }, field(T('label_fi'), h('input', { name: 'label', value: r.label || '', maxlength: 200 })), field(T('label_en'), h('input', { name: 'label_en', value: r.label_en || '', maxlength: 200 }))),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'active', checked: r.active !== false || null }), ' ', T('active')),
      h('button', { type: 'submit', class: 'btn primary', 'data-testid': 'event-occ-save', text: T('save') }));
    const d = dialog(`${T('edit_occurrence')}: ${p.name}`, f);
    f.addEventListener('submit', (ev) => { ev.preventDefault(); act(f.querySelector('button[type=submit]'), async () => {
      const fd = new FormData(f), n = (k) => (String(fd.get(k) ?? '').trim() === '' ? null : Number(fd.get(k)));
      await rpc('admin_event_rule_upsert', { p_id: r.id, p_product_id: null, p_patch: { date: fd.get('date'), start_time: fd.get('start_time'), duration_minutes: n('duration_minutes'),
        max_persons: n('max_persons'), min_persons: n('min_persons'), deadline_minutes: n('deadline_minutes'), label: String(fd.get('label') || '').trim() || null, label_en: String(fd.get('label_en') || '').trim() || null, active: f.active.checked } });
      toast(T('saved')); d.close(); refresh();
    }); });
  }
  function copyOcc(r) {
    const date = h('input', { type: 'date', required: true, min: todayHel(), 'data-testid': 'event-occ-copy-date' });
    const f = h('form', { class: 'stack' }, field(T('copy_date'), date), h('button', { type: 'submit', class: 'btn primary', 'data-testid': 'event-occ-copy-submit', text: T('copy_to_date') }));
    const d = dialog(T('copy_to_date'), f);
    f.addEventListener('submit', (ev) => { ev.preventDefault(); if (!date.value) { date.focus(); return; } act(f.querySelector('button'), async () => {
      await rpc('admin_event_rule_copy', { p_rule_id: r.id, p_date: date.value }); toast(T('copied_rule')); d.close(); refresh(); }); });
  }
  function deleteOcc(r, label) {
    const f = h('form', { class: 'stack' }, h('p', { text: T('delete_confirm', { label }) }), h('button', { type: 'submit', class: 'btn danger', 'data-testid': 'event-occ-delete-confirm', text: T('delete') }));
    const d = dialog(T('delete'), f);
    f.addEventListener('submit', (ev) => { ev.preventDefault(); act(f.querySelector('button'), async () => {
      await rpc('admin_event_rule_delete', { p_id: r.id }); toast(T('deleted')); d.close(); refresh(); }); });
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
      act(f.querySelector('button'), async () => { const out = await rpc(a.fn, a.args); toast(T('copied_event', { n: out?.rules_copied ?? 0 })); d.close(); ctx.refs = null; go({ tapahtuma: out?.product_id }); }); });
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

// Aikajanan palkki: sijainti CSSOM:lla (ei style-attribuuttia → toimii tiukallakin CSP:llä)
function barEl(cls, g) { const el = h('span', { class: `ev-tl-bar ${cls}` }); el.style.left = `${g.left}%`; el.style.width = `${g.width}%`; return el; }

// run() + tapahtumakohtaiset virhetekstit
async function act(btn, fn) {
  if (btn) btn.disabled = true;
  try { return await fn(); } catch (e) { toast(evErr(e), 'err'); } finally { if (btn) btn.disabled = false; }
}
