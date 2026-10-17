// Tuotevalinnat (booking_50): vaihtoehtojen hallinta Tuotteet-sivun alaosassa. Lukeminen: kaikki henkilökunta (admin_list_product_options); muokkaus: catalog.edit
// (admin_upsert_product_option, admin_set_product_option_settings). Poisto = passivointi (vanhat varaukset säilyttävät valintansa). Tekstit FI/EN (options-logic.js).
import { rpc } from '../sb.js';
import { h, dialog, field, toast, run, badge } from '../ui.js';
import { ot, optName, optErr, clearOptionConfig } from '../options.js';

const CODE_RE = /^[a-z0-9_]{1,40}$/;
export async function productOptionsAdmin({ ctx }) {
  const can = ctx.can('catalog.edit');
  const wrap = h('section', { class: 'stack', 'aria-labelledby': 'popts-h', 'data-testid': 'product-options' });
  async function draw() {
    let rows; try { rows = (await rpc('admin_list_product_options')) || []; } catch (e) { wrap.replaceChildren(h('h2', { id: 'popts-h', text: ot('mgTitle') }), h('p', { class: 'err', role: 'alert', text: optErr(e) })); return; }
    clearOptionConfig();
    const card = (p) => {
      const active = (p.options || []).filter((o) => o.active).length;
      return h('div', { class: 'box optcard', 'data-testid': 'option-product', 'data-product': p.product_id },
        h('div', { class: 'row wrap' }, h('strong', { text: p.product_name }), ' ', p.option_required ? badge('ok', ot('mgRequired')) : badge('muted', ot('mgOptional')),
          !active ? badge('warn', ot('mgNoActive')) : null, p.reservations_without_option > 0 ? badge('warn', ot('mgWithout', { n: p.reservations_without_option })) : null),
        h('div', { class: 'optrow' }, h('div', { class: 'optlist' }, (p.options || []).map((o) => {
          const label = `${optName(o)}${o.active ? '' : ` (${ot('mgInactive')})`}`;
          return can ? h('button', { type: 'button', class: `optitem${o.active ? '' : ' off'}`, 'data-code': o.code, onclick: () => editOption(p, o), text: label }) : h('span', { class: `optitem${o.active ? '' : ' off'}`, 'data-code': o.code, text: label });
        }))),
        can ? h('div', { class: 'row wrap' }, h('button', { type: 'button', class: 'btn', 'data-testid': 'option-add', text: ot('mgAdd'), onclick: () => editOption(p, null) }),
          h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'option-settings', text: ot('mgSettings'), onclick: () => settings(p) })) : null);
    };
    wrap.replaceChildren(...[h('h2', { id: 'popts-h', text: ot('mgTitle') }), h('p', { class: 'muted', text: ot('mgLead') }), can ? null : h('p', { class: 'muted', text: ot('mgReadonly') }),
      ...(rows.length ? rows.map(card) : [h('p', { class: 'empty', text: ot('mgEmpty') })])].filter(Boolean));
  }
  function editOption(p, o) {
    const code = h('input', { name: 'code', maxlength: 40, value: o?.code || '', disabled: o ? true : null, autocapitalize: 'off', spellcheck: 'false' });
    const name = h('input', { name: 'name', maxlength: 80, value: o?.name || '', required: true }), nameEn = h('input', { name: 'name_en', maxlength: 80, value: o?.name_en || '' });
    const sort = h('input', { name: 'sort', type: 'number', min: '0', step: '10', value: o?.sort_order ?? 100 });
    const active = h('input', { name: 'active', type: 'checkbox', checked: o ? !!o.active : true });
    const desc = h('textarea', { name: 'desc', rows: 2, maxlength: 300 }); desc.value = o?.description || ''; const descEn = h('textarea', { name: 'desc_en', rows: 2, maxlength: 300 }); descEn.value = o?.description_en || '';
    const err = h('p', { class: 'err', role: 'alert', hidden: true, 'data-testid': 'option-form-error' });
    const f = h('form', { class: 'stack', novalidate: true, 'data-testid': 'option-form', onsubmit: (ev) => { ev.preventDefault(); run(f.querySelector('button[type=submit]'), async () => {
      err.hidden = true; const c = code.value.trim().toLowerCase();
      const fail = (m) => { err.textContent = m; err.hidden = false; };
      if (!CODE_RE.test(c)) return fail(ot('mgCodeInvalid')); if (!name.value.trim()) return fail(ot('mgNameMissing'));
      try {
        await rpc('admin_upsert_product_option', { p_product_id: p.product_id, p_code: c, p_name: name.value.trim(), p_name_en: nameEn.value.trim() || null, p_sort_order: +sort.value || 0, p_active: active.checked, p_description: desc.value.trim() || null, p_description_en: descEn.value.trim() || null });
      } catch (e) { return fail(optErr(e)); }
      toast(ot('mgSavedOpt')); d.close(); await draw();
    }); } },
      field(ot('fCode'), code, ot('fCodeHint')), field(ot('fName'), name), field(ot('fNameEn'), nameEn), field(ot('fSort'), sort),
      h('label', { class: 'check' }, active, ` ${ot('fActive')}`), field(ot('fDesc'), desc), field(ot('fDescEn'), descEn), err,
      h('button', { class: 'btn primary', type: 'submit', text: ot('mgSaveOpt') }));
    const d = dialog(`${o ? ot('mgEditOpt') : ot('mgNewOpt')} – ${p.product_name}`, f);
  }
  function settings(p) {
    const req = h('input', { name: 'required', type: 'checkbox', checked: !!p.option_required });
    const label = h('input', { name: 'label', maxlength: 80, value: p.option_label || '' }), labelEn = h('input', { name: 'label_en', maxlength: 80, value: p.option_label_en || '' });
    const err = h('p', { class: 'err', role: 'alert', hidden: true, 'data-testid': 'settings-error' });
    const f = h('form', { class: 'stack', novalidate: true, 'data-testid': 'option-settings-form', onsubmit: (ev) => { ev.preventDefault(); run(f.querySelector('button[type=submit]'), async () => {
      err.hidden = true;
      try { await rpc('admin_set_product_option_settings', { p_product_id: p.product_id, p_required: req.checked, p_label: label.value.trim() || null, p_label_en: labelEn.value.trim() || null }); }
      catch (e) { err.textContent = optErr(e); err.hidden = false; return; }
      toast(ot('mgSavedSet')); d.close(); await draw();
    }); } }, h('label', { class: 'check' }, req, ` ${ot('fRequired')}`), field(ot('fLabel'), label), field(ot('fLabelEn'), labelEn), err, h('button', { class: 'btn primary', type: 'submit', text: ot('mgSaveSet') }));
    const d = dialog(`${ot('mgSettingsOf')} – ${p.product_name}`, f);
  }
  await draw();
  return wrap;
}
