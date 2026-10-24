// Päivänäkymän sisäiset muistiinpanot ja ajastetut henkilöstötiedotteet (paketti 04, booking_140).
// Tekstit: ui.admin.day_memos.* (day-memos-texts.js). Kaikki käyttäjän syöte tulostetaan textContentina.
import { rpc } from '../sb.js';
import { h, dialog, field, toast, run, fmtDT, fmtDate } from '../ui.js';
import { icon } from '../icons.js';
import { firstSentence } from '../day-memos-logic.js';
import { memoText as t } from '../day-memos-texts.js';

/** Nipun notes_bundle (booking_140) tai erillinen admin_list_day_notes. Virhe ei kaada päivänäkymää. */
export async function loadDayMemos(date, preloaded) {
  if (preloaded && typeof preloaded === 'object') return preloaded;
  try { return await rpc('admin_list_day_notes', { p_date: date }); }
  catch (e) { console.error('Päivän muistiinpanoja ei saatu haettua', e); return { day_notes: [], bulletins: [] }; }
}

function bulletinDialog(date, row, reload) {
  const from = h('input', { type: 'date', name: 'bulletin_start', value: row?.start_date || date, required: true });
  const to = h('input', { type: 'date', name: 'bulletin_end', value: row?.end_date || date, required: true });
  const body = h('textarea', { name: 'bulletin_body', rows: 5, maxlength: 4000, required: true, value: row?.body || '' });
  const save = h('button', { type: 'submit', class: 'btn primary', 'data-testid': 'bulletin-save', text: t('ui.admin.day_memos.bulletin_save') });
  const f = h('form', { class: 'stack', onsubmit: (ev) => { ev.preventDefault(); run(save, async () => {
    if (!body.value.trim() || !from.value || !to.value || to.value < from.value) throw new Error(t('ui.admin.day_memos.bulletin_invalid'));
    await rpc('admin_save_bulletin', { p_id: row?.id ?? null, p_start_date: from.value, p_end_date: to.value, p_body: body.value, p_active: true });
    toast(t('ui.admin.day_memos.bulletin_saved')); d.close(); reload?.();
  }); } },
    h('div', { class: 'row wrap' }, field(t('ui.admin.day_memos.bulletin_start'), from), field(t('ui.admin.day_memos.bulletin_end'), to)),
    field(t('ui.admin.day_memos.bulletin_body'), body), save);
  const d = dialog(t(row ? 'ui.admin.day_memos.bulletin_dialog_edit' : 'ui.admin.day_memos.bulletin_dialog_new'), f);
  return d;
}

/** Voimassa olevat tiedotteet. Perustyöntekijälle kortti näkyy vain, kun tiedotteita on; shifts.view_all saa lisätä ja muokata. */
export function bulletinCard({ date, bulletins = [], can = () => false, reload }) {
  const manager = can('shifts.view_all');
  const list = (bulletins || []).filter((b) => b.active !== false && date >= b.start_date && date <= b.end_date);
  if (!list.length && !manager) return null;
  const items = list.map((b) => {
    const preview = firstSentence(b.body);
    const extended = String(b.body || '').trim() !== preview;
    const content = h('p', { class: 'bulletin-full', hidden: true, text: b.body });
    const toggle = extended
      ? h('button', { type: 'button', class: 'bulletin-toggle', 'data-testid': 'bulletin-toggle', 'aria-expanded': 'false', text: preview, onclick: () => {
        const open = content.hidden;
        content.hidden = !open;
        toggle.setAttribute('aria-expanded', String(open));
        toggle.classList.toggle('open', open);
      } }, icon('chev', 18))
      : h('span', { class: 'bulletin-preview', text: preview });
    const period = manager ? h('small', { class: 'muted bulletin-period', text: t('ui.admin.day_memos.bulletin_period', { start: fmtDate(`${b.start_date}T12:00:00Z`), end: fmtDate(`${b.end_date}T12:00:00Z`) }) }) : null;
    const del = manager ? h('button', { type: 'button', class: 'btn ghost sm', 'data-testid': 'bulletin-delete', onclick: () => {
      if (!confirm(t('ui.admin.day_memos.bulletin_delete_confirm'))) return;
      run(del, async () => { await rpc('admin_delete_bulletin', { p_id: b.id }); toast(t('ui.admin.day_memos.bulletin_deleted')); reload?.(); });
    } }, icon('trash', 18), ` ${t('ui.admin.day_memos.bulletin_delete')}`) : null;
    const actions = manager ? h('span', { class: 'bulletin-actions' },
      h('button', { type: 'button', class: 'btn ghost sm', 'data-testid': 'bulletin-edit', text: t('ui.admin.day_memos.bulletin_edit'), onclick: () => bulletinDialog(date, b, reload) }), del) : null;
    return h('li', { class: 'bulletin-item' }, h('div', { class: 'bulletin-head' }, toggle, actions), content, period);
  });
  return h('section', { class: 'day-bulletins', 'data-testid': 'day-bulletins', 'aria-label': t('ui.admin.day_memos.bulletins_aria') },
    h('div', { class: 'day-memos-heading' }, h('h2', { text: t('ui.admin.day_memos.bulletins_title') }),
      manager ? h('button', { type: 'button', class: 'btn sm', 'data-testid': 'bulletin-add', onclick: () => bulletinDialog(date, null, reload) }, icon('add', 18), ` ${t('ui.admin.day_memos.bulletin_add')}`) : null),
    items.length ? h('ul', { class: 'bulletin-list' }, items) : h('p', { class: 'muted', text: t('ui.admin.day_memos.bulletin_none') }));
}

/** Päivän sisäiset muistiinpanot: kaikki henkilöstö näkee ja lisää; poisto shifts.view_all (RPC sallii myös kirjoittajan). */
export function dayNotesCard({ date, dayNotes = [], can = () => false, reload }) {
  const manager = can('shifts.view_all');
  const input = h('textarea', { name: 'day_note', rows: 2, maxlength: 2000, required: true, placeholder: t('ui.admin.day_memos.note_placeholder'), 'aria-label': t('ui.admin.day_memos.note_label') });
  const save = h('button', { type: 'submit', class: 'btn sm primary', 'data-testid': 'day-note-add', text: t('ui.admin.day_memos.note_add') });
  const form = h('form', { class: 'day-note-form', onsubmit: (ev) => { ev.preventDefault(); run(save, async () => {
    const text = String(input.value || '').trim(); if (!text) return;
    await rpc('admin_save_day_note', { p_date: date, p_body: text, p_id: null });
    input.value = ''; toast(t('ui.admin.day_memos.note_added')); reload?.();
  }); } }, input, save);
  const entries = (dayNotes || []).map((n) => {
    const del = manager ? h('button', { type: 'button', class: 'btn ghost sm', 'data-testid': 'day-note-delete', 'aria-label': t('ui.admin.day_memos.note_delete'), onclick: () => {
      if (!confirm(t('ui.admin.day_memos.note_delete_confirm'))) return;
      run(del, async () => { await rpc('admin_delete_day_note', { p_id: n.id }); toast(t('ui.admin.day_memos.note_deleted')); reload?.(); });
    } }, icon('trash', 18)) : null;
    return h('li', { class: 'day-note-entry', 'data-testid': 'day-note' },
      h('div', { class: 'day-note-main' },
        h('p', { class: 'day-note-body', text: n.body }),
        h('small', { class: 'muted', text: `${n.author_name || t('ui.admin.day_memos.note_author_fallback')} · ${n.created_at ? fmtDT(n.created_at) : ''}` })),
      del);
  });
  return h('section', { class: 'day-notes card', 'data-testid': 'day-notes' },
    h('h2', { text: t('ui.admin.day_memos.notes_title') }),
    entries.length ? h('ul', { class: 'day-note-list' }, entries) : h('p', { class: 'muted', text: t('ui.admin.day_memos.notes_none') }), form);
}
