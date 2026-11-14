// HALL-ASIAKKAAT-01: asiakasnäkymän kortit muokattaviksi paikallaan (ei modaalia): yhteystiedot, markkinointilupa (kytkin),
// muistiinpano (oma Muokkaa-painike), vuosikortti (oma kortti, vahvistukset confirmDialogilla). Kaikki tallennus admin_update_customer-,
// admin_create_annual_card- ja admin_revoke_annual_card-kutsuilla (oikeus: customers.manage / annual_cards.manage); logiikka customer-edit-logic.js.
import { h, run, toast, field, todayHel, addDays } from '../ui.js';
import { fmt } from '../talous-i18n.js';
import { ov } from '../order-view-texts.js';
import { confirmDialog } from '../confirm.js';
import { normalizeCode } from '../../shop/src/discount-code-logic.js';
import { amText, amCreatedMessage } from '../annual-manage-texts.js';
import { contactValues, contactProblems, contactPatch, notePatch, consentPatch, revokeArgs, LANG_CODES } from '../customer-edit-logic.js';

const c = (k, vars) => ov(`customer_view.${k}`, vars);
const kv = (rows) => h('dl', { class: 'ov-kv' }, rows.filter(Boolean).map(([k, v]) => [h('dt', { text: k }), h('dd', { text: v || '–' })]));
const langName = (l) => (l === 'en' ? c('lang_en') : l === 'fi' ? c('lang_fi') : l === 'sv' ? c('lang_sv') : (l || '–'));
const cardShell = (testid) => h('section', { class: 'ov-card', 'data-testid': testid });
const head = (title, ...actions) => h('div', { class: 'ov-card-head' }, h('div', { class: 'row between' }, h('h2', { class: 'ov-h', text: title }), ...actions));
const linkBtn = (testid, text, onclick) => h('button', { type: 'button', class: 'linkish', 'data-testid': testid, text, onclick });
// Kenttä + virheviesti kentän viereen
function fld(label, input) {
  const err = h('small', { class: 'fld-err', role: 'status', hidden: true });
  input.addEventListener('input', () => { err.hidden = true; input.removeAttribute('aria-invalid'); });
  return { node: h('label', { class: 'fld' }, h('span', { text: label }), input, err), input, err };
}
const inp = (name, value, o = {}) => h('input', { name, value: value || '', autocomplete: 'off', ...o });

/** Yhteystiedot: kieli, tyyppi, yritystiedot ja osoite muokattavissa kortissa. */
export function contactCard({ rpc, m, raw, canEdit, onSaved }) {
  const root = cardShell('cv-contact');
  const v0 = contactValues(raw);
  const paintView = () => {
    const addr = [v0.address, [v0.zip, v0.city].filter(Boolean).join(' ')].filter(Boolean).join(', ');
    const einv = [v0.einvoice_address, v0.einvoice_operator].filter(Boolean).join(' / ');
    root.replaceChildren(head(c('contact'), canEdit ? linkBtn('cv-edit', c('edit'), paintEdit) : null),
      kv([[c('phone'), m.phone], [c('email_label'), m.email], [c('language'), langName(m.language)], [c('type'), m.kind === 'company' ? c('kind_company') : c('kind_private')],
        v0.company ? [c('company'), v0.company] : null, v0.business_id ? [c('business_id'), v0.business_id] : null, m.kind === 'company' && m.person ? [c('contact_person'), m.person] : null,
        addr ? [c('address_label'), addr] : null, einv ? [c('einvoice_label'), einv] : null, v0.invoice_reference ? [c('reference_label'), v0.invoice_reference] : null]));
  };
  function paintEdit() {
    let kind = v0.kind;
    const F = {
      name: fld(c('name'), inp('name', v0.name, { required: true, autocapitalize: 'words' })),
      email: fld(c('email_label'), inp('email', v0.email, { type: 'email', inputmode: 'email', autocapitalize: 'off', spellcheck: 'false' })),
      phone: fld(c('phone'), inp('phone', v0.phone, { type: 'tel', inputmode: 'tel' })),
      language: fld(c('language'), h('select', { name: 'language' }, LANG_CODES.map((l) => h('option', { value: l, selected: l === v0.language || null, text: langName(l) })))),
      company: fld(c('company_name'), inp('company', v0.company, { autocapitalize: 'words' })),
      business_id: fld(c('business_id'), inp('business_id', v0.business_id, { placeholder: '1234567-8', inputmode: 'numeric' })),
      address: fld(c('street'), inp('address', v0.address, { autocapitalize: 'words' })),
      zip: fld(c('zip'), inp('zip', v0.zip, { inputmode: 'numeric', maxlength: 5 })),
      city: fld(c('city'), inp('city', v0.city, { autocapitalize: 'words' })),
      einvoice_address: fld(c('einvoice_address'), inp('einvoice_address', v0.einvoice_address, { inputmode: 'numeric' })),
      einvoice_operator: fld(c('einvoice_operator'), inp('einvoice_operator', v0.einvoice_operator, { autocapitalize: 'characters' })),
      invoice_reference: fld(c('invoice_reference'), inp('invoice_reference', v0.invoice_reference)),
    };
    const companyOnly = [F.business_id, F.einvoice_address, F.einvoice_operator, F.invoice_reference];
    const hint = h('small', { class: 'fld-hint', text: c('kind_hint') });
    const sync = () => {
      for (const x of companyOnly) x.node.hidden = kind !== 'company';
      hint.hidden = kind !== 'company';
      F.company.node.querySelector('span').textContent = kind === 'company' ? c('company_name') : c('company_name_optional');
      F.name.node.querySelector('span').textContent = kind === 'company' ? c('contact_name') : c('name');
    };
    const kinds = h('fieldset', { class: 'kindset' }, h('legend', { text: c('type') }), h('div', { class: 'seg', role: 'presentation' },
      [['private', c('kind_private')], ['company', c('kind_company')]].map(([k, label]) => h('label', { class: 'kindopt' },
        h('input', { type: 'radio', name: 'kind', value: k, checked: k === kind || null, onchange: () => { kind = k; sync(); } }), h('span', { text: label })))));
    const values = () => ({ kind, ...Object.fromEntries(Object.entries(F).map(([k, f]) => [k, f.input.value])) });
    const form = h('form', { class: 'stack ov-edit', 'data-testid': 'cv-contact-form', novalidate: true, onsubmit: (ev) => {
      ev.preventDefault();
      for (const f of Object.values(F)) { f.err.hidden = true; f.input.removeAttribute('aria-invalid'); }
      const probs = contactProblems(values());
      for (const p of probs) { const f = F[p.field]; f.err.textContent = c(p.key); f.err.hidden = false; f.input.setAttribute('aria-invalid', 'true'); }
      if (probs.length) { F[probs[0].field].input.focus(); return; }
      const patch = contactPatch(raw, values());
      if (!Object.keys(patch).length) { toast(c('no_changes')); paintView(); return; }
      run(form.querySelector('button[type=submit]'), async () => { await rpc('admin_update_customer', { p_id: m.id, p_patch: patch }); toast(c('saved')); onSaved(); });
    } },
      kinds, hint, F.name.node, h('div', { class: 'cf-pair' }, F.email.node, F.phone.node), F.language.node,
      F.company.node, F.business_id.node, F.address.node, h('div', { class: 'cf-addr' }, F.zip.node, F.city.node),
      F.einvoice_address.node, F.einvoice_operator.node, F.invoice_reference.node,
      h('div', { class: 'row wrap' }, h('button', { type: 'submit', class: 'btn primary', 'data-testid': 'cv-contact-save', text: c('save') }),
        h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'cv-contact-cancel', text: c('cancel'), onclick: paintView })));
    sync();
    root.replaceChildren(head(c('contact_edit_title')), form);
    F.name.input.focus();
  }
  paintView();
  return root;
}

/** Markkinointilupa kytkimenä: tallentuu heti (lupa kirjataan aikaleimalla, lähde admin; palvelin hoitaa). */
export function consentCard({ rpc, m, canEdit, onSaved }) {
  const status = () => h('div', {},
    h('p', { class: 'ov-small', text: m.consent.given ? c('consent_given', { when: m.consent.at ? fmt.date(m.consent.at) : '–', source: m.consent.source || '–' }) : c('consent_none') }),
    m.consent.unsubscribed_at ? h('p', { class: 'muted ov-small', text: c('consent_unsub', { when: fmt.date(m.consent.unsubscribed_at) }) }) : null);
  let sw = null;
  if (canEdit) {
    const box = h('input', { type: 'checkbox', role: 'switch', 'data-testid': 'cv-consent-switch', checked: m.consent.given || null,
      'aria-label': m.consent.given ? c('consent_switch_on') : c('consent_switch_off') });
    box.checked = !!m.consent.given;
    box.addEventListener('change', () => run(box, async () => {
      const on = box.checked;
      try { await rpc('admin_update_customer', { p_id: m.id, p_patch: consentPatch(on) }); }
      catch (e) { box.checked = !on; throw e; }
      toast(on ? c('consent_on_done') : c('consent_off_done')); onSaved();
    }));
    sw = h('label', { class: 'switch ov-switch' }, box, h('i', { 'aria-hidden': 'true' }));
  }
  return h('section', { class: 'ov-card', 'data-testid': 'cv-consent' }, head(c('consent'), sw), status());
}

/** Muistiinpano: oma Muokkaa-painike (tai Lisää muistiinpano, kun tyhjä); muokkaus paikallaan. */
export function notesCard({ rpc, m, canEdit, onSaved }) {
  const root = cardShell('cv-notes');
  const paintView = () => root.replaceChildren(...[
    head(c('notes'), canEdit && m.notes ? linkBtn('cv-notes-edit', c('edit'), paintEdit) : null),
    m.notes ? h('p', { class: 'ov-note', 'data-testid': 'cv-note', text: m.notes }) : h('p', { class: 'muted ov-small', text: c('notes_none') }),
    canEdit && !m.notes ? h('button', { type: 'button', class: 'btn sm', 'data-testid': 'cv-notes-add', text: c('notes_add'), onclick: paintEdit }) : null,
    h('p', { class: 'muted ov-small', text: c('notes_hint') })].filter(Boolean));
  function paintEdit() {
    const ta = h('textarea', { name: 'notes', rows: 4, 'data-testid': 'cv-notes-input', 'aria-label': c('notes_label'), value: m.notes });
    const form = h('form', { class: 'stack ov-edit', 'data-testid': 'cv-notes-form', onsubmit: (ev) => {
      ev.preventDefault();
      const patch = notePatch(m.notes, ta.value);
      if (!patch) { paintView(); return; }
      run(form.querySelector('button[type=submit]'), async () => { await rpc('admin_update_customer', { p_id: m.id, p_patch: patch }); toast(c('notes_saved')); onSaved(); });
    } }, ta, h('div', { class: 'row wrap' }, h('button', { type: 'submit', class: 'btn primary', 'data-testid': 'cv-notes-save', text: c('save') }),
      h('button', { type: 'button', class: 'btn ghost', text: c('cancel'), onclick: paintView })));
    root.replaceChildren(head(c('notes')), form);
    ta.focus();
  }
  paintView();
  return root;
}

/** Vuosikortti omana korttina: lista (voimassa/peruttu), Peru kortti (confirmDialog) ja Myönnä vuosikortti (oikeus annual_cards.manage). */
export function annualCard({ rpc, m, canManage, onSaved }) {
  const cards = m.annual_cards || [];
  if (!cards.length && !canManage) return null;
  const root = cardShell('cv-annual');
  const date = (d) => (d ? fmt.date(`${d}T12:00:00Z`) : '–');
  const revoke = async (a) => {
    if (!(await confirmDialog({ title: c('annual_revoke_title'), body: c('annual_revoke_body', { code: a.code || '' }), yes: c('annual_revoke'), no: c('cancel'), testid: 'annual-revoke-dialog' }))) return;
    // Esc / sulku = Säilytä varaukset (varaukset eivät peru itseään vahingossa)
    const cancelFuture = await confirmDialog({ title: c('annual_future_title'), body: c('annual_future_body'), yes: c('annual_future_yes'), no: c('annual_future_no'), testid: 'annual-future-dialog' });
    const r = await rpc('admin_revoke_annual_card', revokeArgs(a.id, cancelFuture));
    toast(r?.cancelled ? c('annual_revoked_done_n', { n: r.cancelled }) : c('annual_revoked_done')); onSaved();
  };
  const grant = canManage ? h('form', { class: 'row wrap box', 'data-testid': 'cv-annual-grant', onsubmit: (ev) => {
    ev.preventDefault();
    run(grant.querySelector('button[type=submit]'), async () => {
      const created = await rpc('admin_create_annual_card', { p_customer_id: m.id, p_valid_from: grant.vf.value, p_valid_to: grant.vt.value || null, p_code: normalizeCode(grant.vcode.value) || null, p_notes: grant.vn.value || null, p_send_email: grant.vsend.checked });
      toast(amCreatedMessage(created)); onSaved();
    });
  } },
    field(c('annual_from'), h('input', { type: 'date', name: 'vf', value: todayHel(), required: true })), field(c('annual_to'), h('input', { type: 'date', name: 'vt', value: addDays(todayHel(), 365), required: true })),
    field(c('annual_note'), h('input', { name: 'vn' })),
    field(amText('ui.admin.annual_manage.code_label_optional'), h('input', { name: 'vcode', maxlength: 40, autocomplete: 'off', oninput: (e) => { e.target.value = normalizeCode(e.target.value); } }), amText('ui.admin.annual_manage.code_hint')),
    h('label', { class: 'check', title: amText('ui.admin.annual_manage.send_email_hint') }, h('input', { type: 'checkbox', name: 'vsend', checked: true }), ' ', amText('ui.admin.annual_manage.send_email')),
    h('button', { class: 'btn', type: 'submit', text: c('annual_grant') })) : null;
  root.append(head(c('annual')),
    cards.length ? h('ul', { class: 'reslist' }, cards.map((a) => h('li', { class: 'resrow', 'data-testid': 'cv-annual-row' },
      h('span', { class: 'ov-small', text: [a.code, c('annual_period', { from: date(a.valid_from), to: date(a.valid_to) }), a.notes].filter(Boolean).join(' · ') }),
      h('span', { class: 'meta' }, h('span', { class: `badge ${a.active ? 'ok' : 'muted'}`, text: a.active ? c('annual_active') : c('annual_revoked') }),
        canManage && a.active ? h('button', { type: 'button', class: 'btn danger sm', 'data-testid': 'cv-annual-revoke', text: c('annual_revoke'), onclick: (e) => run(e.currentTarget, () => revoke(a)) }) : null))))
      : h('p', { class: 'muted ov-small', text: c('annual_none') }),
    ...(grant ? [grant] : []));
  return root;
}
