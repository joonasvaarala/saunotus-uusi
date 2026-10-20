// Asetukset → Varaukset: varauskalenterin vienti. Oletus pois. Ei kirjoita Googleen tästä näkymästä.
import { rpc } from '../sb.js';
import { h, field, toast, run } from '../ui.js';
import { calendarExportText as cx } from '../calendar-export-texts.js';
import { collectCalendarSettings, firstCalendarError } from '../calendar-export-logic.js';

const choice = (value, text, current) => h('option', { value, text, selected: value === current || null });

function noteFor(mode) {
  if (mode === 'dry_run') return cx('ui.admin.calendar_export.dry_note');
  if (mode === 'off' || !mode) return cx('ui.admin.calendar_export.off_note');
  return '';
}

export function renderCalendarExport({ state, failed, isAdmin, reload }) {
  if (failed || !state) {
    return h('section', { class: 'card', 'data-testid': 'calendar-export' },
      h('h2', { text: cx('ui.admin.calendar_export.title') }),
      h('p', { class: 'err', 'data-testid': 'calendar-export-error', text: cx('ui.admin.calendar_export.unavailable') }));
  }
  const resources = Array.isArray(state.resources) ? state.resources : [];
  const mode = h('select', { disabled: !isAdmin, 'data-testid': 'calendar-export-mode' }, [
    choice('off', cx('ui.admin.calendar_export.mode_off'), state.mode || 'off'),
    choice('dry_run', cx('ui.admin.calendar_export.mode_dry_run'), state.mode),
    choice('live', cx('ui.admin.calendar_export.mode_live'), state.mode),
  ]);
  const shared = h('input', { type: 'text', value: state.shared_calendar_id || '', disabled: !isAdmin, 'data-testid': 'calendar-export-shared', autocomplete: 'off', spellcheck: 'false' });
  const adminUrl = h('input', { type: 'text', value: state.admin_base_url || '', disabled: !isAdmin, 'data-testid': 'calendar-export-admin-url', autocomplete: 'off' });
  const timezone = h('input', { type: 'text', value: state.timezone || 'Europe/Helsinki', disabled: !isAdmin, 'data-testid': 'calendar-export-tz' });
  const back = h('input', { type: 'number', min: '0', max: '60', value: String(state.window_back_days ?? 7), disabled: !isAdmin, 'data-testid': 'calendar-export-back' });
  const forward = h('input', { type: 'number', min: '1', max: '366', value: String(state.window_forward_days ?? 180), disabled: !isAdmin, 'data-testid': 'calendar-export-forward' });
  const fast = h('input', { type: 'checkbox', disabled: !isAdmin, 'data-testid': 'calendar-export-fast' });
  fast.checked = state.fast_nudge === true;
  const resourceInputs = resources.map((r) => ({
    code: r.code,
    input: h('input', { type: 'text', value: r.calendar_id || '', disabled: !isAdmin, 'data-testid': `calendar-export-resource-${r.code}`, autocomplete: 'off', spellcheck: 'false' }),
    name: r.name || r.code,
  }));
  const previewOut = h('p', { 'data-testid': 'calendar-export-preview' });
  const modeNote = h('p', { class: 'muted', 'data-testid': 'calendar-export-mode-note', text: noteFor(state.mode) });
  const last = state.last
    ? `${cx('ui.admin.calendar_export.last')}: ${state.last.error || cx('ui.admin.calendar_export.last_ok')}`
    : cx('ui.admin.calendar_export.last_none');
  const collect = () => collectCalendarSettings({
    mode: mode.value,
    timezone: timezone.value,
    window_back_days: back.value,
    window_forward_days: forward.value,
    admin_base_url: adminUrl.value,
    shared_calendar_id: shared.value,
    fast_nudge: fast.checked,
    resource_calendars: Object.fromEntries(resourceInputs.map((r) => [r.code, r.input.value])),
  });
  const save = h('button', { class: 'btn', type: 'button', text: cx('ui.admin.calendar_export.save'), 'data-testid': 'calendar-export-save', onclick: (e) => run(e.target, async () => {
    const payload = collect();
    if (firstCalendarError(payload)) { toast(cx('ui.admin.calendar_export.error_invalid'), 'err'); return; }
    try {
      await rpc('admin_set_booking_calendar', { p: payload });
    } catch (err) {
      if (err?.code === 'closure_calendar') { toast(cx('ui.admin.calendar_export.error_closure'), 'err'); return; }
      if (err?.code === 'invalid_calendar') { toast(cx('ui.admin.calendar_export.error_invalid'), 'err'); return; }
      throw err;
    }
    toast(cx('ui.admin.calendar_export.saved'));
    if (reload) await reload();
  }) });
  const preview = h('button', { class: 'btn', type: 'button', text: cx('ui.admin.calendar_export.preview'), 'data-testid': 'calendar-export-preview-btn', onclick: (e) => run(e.target, async () => {
    const res = await rpc('admin_booking_calendar_preview');
    previewOut.textContent = [
      `${cx('ui.admin.calendar_export.preview_private')} ${res.private_events ?? 0}`,
      `${cx('ui.admin.calendar_export.preview_days')} ${res.day_bars ?? 0}`,
      `${cx('ui.admin.calendar_export.preview_unconfigured')} ${res.unconfigured ?? 0}`,
      cx('ui.admin.calendar_export.preview_not_sent'),
    ].join(' · ');
  }) });
  return h('section', { class: 'card', 'data-testid': 'calendar-export' },
    h('h2', { text: cx('ui.admin.calendar_export.title') }),
    h('p', { class: 'muted', text: cx('ui.admin.calendar_export.lead') }),
    modeNote,
    h('p', { 'data-testid': 'calendar-export-last', text: last }),
    h('div', { class: 'stack' },
      field(cx('ui.admin.calendar_export.mode'), mode),
      field(cx('ui.admin.calendar_export.shared'), shared, cx('ui.admin.calendar_export.shared_hint')),
      field(cx('ui.admin.calendar_export.admin_url'), adminUrl, cx('ui.admin.calendar_export.admin_url_hint')),
      field(cx('ui.admin.calendar_export.timezone'), timezone),
      field(cx('ui.admin.calendar_export.window_back'), back),
      field(cx('ui.admin.calendar_export.window_forward'), forward),
      field(cx('ui.admin.calendar_export.fast'), fast, cx('ui.admin.calendar_export.fast_hint'))),
    resources.length ? h('h3', { text: cx('ui.admin.calendar_export.resources') }) : null,
    resources.length ? h('div', { class: 'stack' }, resourceInputs.map((r) => field(r.name, r.input, cx('ui.admin.calendar_export.resource_hint')))) : null,
    isAdmin ? save : null,
    preview,
    previewOut);
}
