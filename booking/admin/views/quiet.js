// Hiljaiset ajat (booking_162): hiljaisten aikojen alen portaat, kytkin ja esikatselu. Kaikki muutokset palvelimen RPC:illä:
//   admin_quiet_rules_list                         (henkilökunta; palauttaa can_edit / can_toggle)
//   admin_quiet_rule_upsert / admin_quiet_rule_delete (catalog.edit)
//   admin_quiet_set_enabled                        (settings.edit) – asetus quiet_discounts.enabled, oletus false
//   admin_quiet_preview                            (henkilökunta; näyttää tarjoukset myös kytkimen ollessa pois)
// Tekstit: ui.admin.quiet.* (quiet-texts.js). Ei innerHTML:ää; kaikki palvelimen data textContentina h():n kautta.
// Pohja: GPT-paketin views/quiet.js (rakenne: kytkin, porraslista, muokkausdialogi, esikatselu); RPC-nimet ja kentät tämän repon migraation mukaan.
import { rpc } from '../sb.js';
import { h, field, toast, run, dialog, empty, money, badge, fmtDate, fmtDT, todayHel } from '../ui.js';
import { quietText as qt, loadQuietTexts } from '../quiet-texts.js';
import { validateQuietRule } from '../quiet-logic.js';
import { getLang } from '../talous-i18n.js';

const pctText = (n) => { const s = String(+n); return getLang() === 'fi' ? s.replace('.', ',') : s; };
const dOnly = (ds) => (ds ? fmtDate(`${ds}T12:00:00Z`) : '');

export async function render({ reload }) {
  const [data] = await Promise.all([rpc('admin_quiet_rules_list'), loadQuietTexts(rpc)]);
  const rules = data?.rules || [], products = data?.products || [];
  const canEdit = !!data?.can_edit, canToggle = !!data?.can_toggle, enabled = !!data?.enabled;
  const pname = (id) => products.find((p) => +p.id === +id)?.name || `#${id}`;

  const root = h('section', { class: 'stack', 'data-testid': 'quiet-page', 'aria-labelledby': 'quiet-h' },
    h('h1', { id: 'quiet-h', text: qt('ui.admin.quiet.title') }),
    h('p', { class: 'muted', text: qt('ui.admin.quiet.intro') }));

  // ---- kytkin
  const toggle = h('div', { class: 'card row between wrap', 'data-testid': 'quiet-status' },
    h('span', { class: 'row wrap' }, badge(enabled ? 'ok' : 'muted', qt(enabled ? 'ui.admin.quiet.status_on' : 'ui.admin.quiet.status_off'))),
    canToggle
      ? h('button', { type: 'button', class: `btn ${enabled ? 'ghost' : 'primary'}`, 'data-testid': 'quiet-toggle', onclick: (e) => {
        if (!confirm(qt(enabled ? 'ui.admin.quiet.disable_confirm' : 'ui.admin.quiet.enable_confirm'))) return;
        run(e.currentTarget, async () => { await rpc('admin_quiet_set_enabled', { p_enabled: !enabled }); toast(qt('ui.admin.quiet.status_saved')); reload(); });
      } }, qt(enabled ? 'ui.admin.quiet.disable' : 'ui.admin.quiet.enable'))
      : h('small', { class: 'muted', text: qt('ui.admin.quiet.toggle_readonly') }));
  root.append(toggle);

  // ---- portaat
  const ruleLine = (r) => qt('ui.admin.quiet.rule_line', { products: (r.product_ids || []).map(pname).join(', '), hours: r.hours_before, pct: pctText(r.percent) });
  const list = h('div', { class: 'list', 'data-testid': 'quiet-rules' }, rules.length ? rules.map((r) => h('div', { class: 'card stack', 'data-testid': `quiet-rule-${r.id}` },
    h('div', { class: 'row between wrap' }, h('strong', { text: getLang() === 'en' && r.label_en ? r.label_en : r.label }),
      badge(r.active ? 'ok' : 'muted', qt(r.active ? 'ui.admin.quiet.active' : 'ui.admin.quiet.inactive'))),
    h('span', { text: ruleLine(r) }),
    (r.valid_from || r.valid_to) ? h('small', { class: 'muted', text: [r.valid_from ? qt('ui.admin.quiet.valid_from', { date: dOnly(r.valid_from) }) : null,
      r.valid_to ? qt('ui.admin.quiet.valid_to', { date: dOnly(r.valid_to) }) : null].filter(Boolean).join(' · ') }) : null,
    canEdit ? h('div', { class: 'row wrap' },
      h('button', { type: 'button', class: 'btn sm', 'data-testid': `quiet-edit-${r.id}`, onclick: () => edit(r) }, qt('ui.admin.quiet.edit')),
      h('button', { type: 'button', class: 'btn ghost sm', 'data-testid': `quiet-delete-${r.id}`, onclick: (e) => {
        if (!confirm(qt('ui.admin.quiet.delete_confirm', { name: r.label }))) return;
        run(e.currentTarget, async () => { await rpc('admin_quiet_rule_delete', { p_id: r.id }); toast(qt('ui.admin.quiet.deleted')); reload(); });
      } }, qt('ui.admin.quiet.delete'))) : null)) : empty(qt('ui.admin.quiet.no_rules')));
  root.append(h('div', { class: 'row between wrap' }, h('h2', { text: qt('ui.admin.quiet.rules') }),
    canEdit ? h('button', { type: 'button', class: 'btn primary', 'data-testid': 'quiet-new', onclick: () => edit(null) }, qt('ui.admin.quiet.new')) : null),
    h('p', { class: 'muted', text: qt('ui.admin.quiet.condition') }),
    ...(canEdit ? [] : [h('p', { class: 'muted', text: qt('ui.admin.quiet.readonly') })]), list);

  // ---- esikatselu
  const days = h('select', { 'data-testid': 'quiet-days' }, ...[3, 7, 14].map((n) => h('option', { value: String(n), text: String(n), selected: n === 7 })));
  const out = h('div', { class: 'list', 'data-testid': 'quiet-preview', 'aria-live': 'polite' });
  const loadPreview = async () => {
    const p = await rpc('admin_quiet_preview', { p_from: todayHel(), p_days: +days.value });
    const offers = p?.offers || [];
    out.replaceChildren(...(offers.length ? offers.map((o) => h('div', { class: 'card row between wrap', 'data-testid': 'quiet-offer' },
      h('span', { class: 'stack' }, h('strong', { text: `${pname(o.product_id)} · ${fmtDT(o.starts_at)}` }),
        h('small', { class: 'muted', text: qt('ui.admin.quiet.preview_line', { hours: o.hours_before, pct: pctText(o.percent) }) })),
      h('span', { class: 'row wrap' }, h('del', { text: money(o.base_price) }), h('strong', { text: money(o.discounted_price) })))) : [empty(qt('ui.admin.quiet.no_preview'))]));
  };
  const refresh = h('button', { type: 'button', class: 'btn sm', 'data-testid': 'quiet-refresh', onclick: (e) => run(e.currentTarget, loadPreview) }, qt('ui.admin.quiet.refresh'));
  root.append(h('h2', { text: qt('ui.admin.quiet.preview') }), h('p', { class: 'muted', text: qt('ui.admin.quiet.preview_intro') }),
    h('div', { class: 'row wrap' }, field(qt('ui.admin.quiet.days'), days), refresh), out);
  run(null, loadPreview);
  return root;

  function edit(r) {
    const v = r || { label: '', label_en: '', product_ids: [], hours_before: 72, percent: 20, valid_from: null, valid_to: null, active: true };
    const label = h('input', { type: 'text', maxlength: '80', required: true, value: v.label || '', 'data-testid': 'quiet-f-label' });
    const labelEn = h('input', { type: 'text', maxlength: '80', value: v.label_en || '', 'data-testid': 'quiet-f-label-en' });
    const hours = h('input', { type: 'number', min: '1', max: '336', step: '1', required: true, value: String(v.hours_before ?? ''), 'data-testid': 'quiet-f-hours' });
    const pct = h('input', { type: 'text', inputmode: 'decimal', required: true, value: pctText(v.percent ?? ''), 'data-testid': 'quiet-f-percent' });
    const from = h('input', { type: 'date', value: v.valid_from || '', 'data-testid': 'quiet-f-from' });
    const to = h('input', { type: 'date', value: v.valid_to || '', 'data-testid': 'quiet-f-to' });
    const active = h('input', { type: 'checkbox', checked: v.active !== false, 'data-testid': 'quiet-f-active' });
    const boxes = products.map((p) => h('label', { class: 'row' }, h('input', { type: 'checkbox', value: String(p.id), checked: (v.product_ids || []).map(Number).includes(+p.id) }), h('span', { text: p.name })));
    const msg = h('p', { class: 'err', role: 'alert', hidden: true, 'data-testid': 'quiet-f-error' });
    const save = h('button', { type: 'submit', class: 'btn primary', 'data-testid': 'quiet-f-save' }, qt('ui.admin.quiet.save'));
    const form = h('form', { class: 'stack', novalidate: true },
      field(qt('ui.admin.quiet.name'), label), field(qt('ui.admin.quiet.name_en'), labelEn),
      h('fieldset', { class: 'stack' }, h('legend', { text: qt('ui.admin.quiet.products') }), ...boxes),
      field(qt('ui.admin.quiet.hours'), hours), field(qt('ui.admin.quiet.percent'), pct),
      h('div', { class: 'row wrap' }, field(qt('ui.admin.quiet.from'), from), field(qt('ui.admin.quiet.to'), to)),
      h('label', { class: 'row' }, active, h('span', { text: qt('ui.admin.quiet.active') })),
      msg, h('div', { class: 'row wrap' }, save, h('button', { type: 'button', class: 'btn ghost', onclick: () => d.close() }, qt('ui.admin.quiet.cancel'))));
    const d = dialog(qt(r ? 'ui.admin.quiet.edit' : 'ui.admin.quiet.new'), form);
    form.addEventListener('submit', (e) => {
      e.preventDefault();
      const chk = validateQuietRule({ id: r?.id, label: label.value, label_en: labelEn.value, hours_before: hours.value, percent: pct.value,
        valid_from: from.value || null, valid_to: to.value || null, active: active.checked,
        product_ids: boxes.map((b) => b.querySelector('input')).filter((i) => i.checked).map((i) => +i.value) }, rules);
      if (!chk.ok) { msg.textContent = chk.errors.map((k) => qt(`ui.admin.quiet.v_${k}`)).join(' '); msg.hidden = false; return; }
      msg.hidden = true;
      run(save, async () => {
        try { await rpc('admin_quiet_rule_upsert', { p_id: r?.id ?? null, p_patch: { ...chk.patch, percent: Number(chk.patch.percent) } }); } catch (err) {
          if (err?.code === 'quiet_overlap') { msg.textContent = qt('ui.admin.quiet.v_overlap'); msg.hidden = false; return; }
          throw err;
        }
        toast(qt('ui.admin.quiet.saved')); d.close(); reload();
      });
    });
  }
}
