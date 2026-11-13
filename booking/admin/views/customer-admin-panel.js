// Tilausnäkymä v3 (PR 4): asiakkaan Yhdistä- ja Anonymisoi-toiminnot asiakasnäkymän sivupalkissa (booking_285).
// Näkyy vain, kun käyttäjällä on customers.admin (admin, manager) JA palvelimen kytkin on päällä (admin_customer_admin_status).
// Jokainen toiminto: esikatselu (p_confirm=false) → vahvistus valintaruudulla (+ syy) → toteutus. Palvelin tarkistaa oikeudet ja kytkimet joka kutsussa.
import { h, errMsg, toast } from '../ui.js';
import { ov } from '../order-view-texts.js';
import {
  panelAccess, mergeCountRows, anonCountRows, mergeDirection, warningRows, blockerRows, canConfirmMerge, canConfirmAnonymize,
} from '../customer-admin-logic.js';

const c = (k, vars) => ov(`customer_view.${k}`, vars);
const t = (key, vars) => ov(key, vars);
const lines = (rows) => (rows.length ? h('ul', { class: 'ov-small' }, rows.map((r) => h('li', { text: t(r.key, r.vars) }))) : null);

/** Hakee tilan (kytkimet + oikeus). Vanha palvelin (ei migraatiota) tai virhe → null → osiota ei näytetä. */
export async function loadAdminStatus(rpc) {
  try { return await rpc('admin_customer_admin_status'); } catch { return null; }
}

export function renderCustomerAdminPanel({ rpc, ctx, customer, status, onDone = () => {} }) {
  const access = panelAccess({ canAdmin: ctx?.can?.('customers.admin'), status, anonymized: customer.anonymized, mergedInto: customer.merged_into });
  if (access.hint) return h('section', { class: 'ov-card', 'data-testid': 'cv-admin-hint' }, h('p', { class: 'muted ov-small', text: c('permission_hint') }));
  if (!access.merge && !access.anonymize) return null;
  const root = h('section', { class: 'ov-card', 'data-testid': 'cv-admin' }, h('div', { class: 'ov-card-head' }, h('h2', { class: 'ov-h', text: c('admin_title') })));
  if (access.merge) root.append(mergeBlock({ rpc, customer, onDone }));
  if (access.anonymize) root.append(anonymizeBlock({ rpc, customer, onDone }));
  return root;
}

function planView(plan, group) {
  const counts = group === 'merge' ? mergeCountRows(plan.counts) : anonCountRows(plan.counts);
  const box = h('div', { class: 'stack', 'data-testid': `cv-${group}-plan` });
  box.append(h('h3', { class: 'ov-cap', text: c(`${group}.preview_title`) }));
  if (group === 'merge') {
    box.append(h('p', { class: 'ov-small' }, h('strong', { text: `${c('merge.keep_label')}: ` }), `${plan.keep?.name || '–'} (#${plan.keep?.id}) · ${c('merge.orders_n', { n: plan.keep?.orders ?? 0 })}`),
      h('p', { class: 'ov-small' }, h('strong', { text: `${c('merge.merge_label')}: ` }), `${plan.merge?.name || '–'} (#${plan.merge?.id}) · ${c('merge.orders_n', { n: plan.merge?.orders ?? 0 })}`));
  }
  const blockers = blockerRows(plan, group);
  if (blockers.length) box.append(h('ul', { class: 'err ov-small', role: 'alert', 'data-testid': `cv-${group}-blockers` }, blockers.map((r) => h('li', { text: t(r.key) }))));
  box.append(h('h3', { class: 'ov-cap', text: c(`${group}.counts_title`) }));
  box.append(lines(counts) || h('p', { class: 'muted ov-small', text: c('merge.count.none') }));
  if (group === 'merge') {
    if (plan.consent?.action) box.append(h('p', { class: 'ov-small', text: c(`merge.consent.${plan.consent.action}`) }));
    if (plan.johku && plan.johku !== 'none') box.append(h('p', { class: 'ov-small', text: c(`merge.johku.${plan.johku}`) }));
  } else {
    box.append(h('p', { class: 'ov-small', text: c('anonymize.keeps') }), h('p', { class: 'ov-small', text: c('anonymize.removes') }));
    if (plan.suppression) box.append(h('p', { class: 'ov-small', text: c('anonymize.suppression') }));
  }
  const warns = warningRows(plan, group);
  if (warns.length) box.append(h('ul', { class: 'muted ov-small', 'data-testid': `cv-${group}-warnings` }, warns.map((r) => h('li', { text: t(r.key, r.vars) }))));
  return box;
}

function mergeBlock({ rpc, customer, onDone }) {
  const wrap = h('div', { class: 'stack', 'data-testid': 'cv-merge' });
  const results = h('div', { class: 'stack' });
  const planBox = h('div', { class: 'stack' });
  const confirmBox = h('div', { class: 'stack' });
  const q = h('input', { type: 'search', 'data-testid': 'cv-merge-q', 'aria-label': c('merge.search_label') });
  let other = null; let swapped = false; let plan = null; let busy = false;

  const dir = () => mergeDirection(customer.id, other?.id, swapped);
  async function runPreview() {
    plan = null; planBox.replaceChildren(); confirmBox.replaceChildren();
    if (!other) return;
    const d = dir();
    try { plan = await rpc('admin_merge_customers_preview', { p_keep: d.keep, p_merge: d.merge }); }
    catch (e) { planBox.append(h('p', { class: 'err', role: 'alert', text: c('merge.preview_failed', { error: errMsg(e) }) })); return; }
    planBox.append(planView(plan, 'merge'));
    if (plan.already_merged) { planBox.append(h('p', { class: 'muted ov-small', text: c('merge.already') })); return; }
    if (!plan.ok) return;
    const reason = h('input', { type: 'text', maxlength: '500', 'data-testid': 'cv-merge-reason', 'aria-label': c('merge.reason_label') });
    const check = h('input', { type: 'checkbox', 'data-testid': 'cv-merge-check' });
    const btn = h('button', { type: 'button', class: 'btn danger', 'data-testid': 'cv-merge-confirm', text: c('merge.confirm_btn'), disabled: true });
    const sync = () => { btn.disabled = !canConfirmMerge({ plan, checked: check.checked, busy }); };
    check.addEventListener('change', sync);
    btn.addEventListener('click', async () => {
      busy = true; sync(); btn.textContent = c('merge.working');
      try {
        const r = await rpc('admin_merge_customers', { p_keep: d.keep, p_merge: d.merge, p_confirm: true, p_reason: reason.value.trim() || null });
        toast(r?.already_merged ? c('merge.already') : c('merge.done'), 'ok');
        onDone(d.keep);
      } catch (e) {
        busy = false; btn.textContent = c('merge.confirm_btn'); sync();
        confirmBox.append(h('p', { class: 'err', role: 'alert', text: c('merge.failed', { error: errMsg(e) }) }));
      }
    });
    confirmBox.append(h('label', { class: 'fld' }, h('span', { text: c('merge.reason_label') }), reason),
      h('label', { class: 'row' }, check, h('span', { text: c('merge.confirm_check') })), btn);
  }
  function pick(row) {
    other = row; swapped = false;
    results.replaceChildren(); planBox.replaceChildren(); confirmBox.replaceChildren();
    const label = h('p', { class: 'ov-small', 'data-testid': 'cv-merge-direction' });
    const paint = () => { const d = dir(); label.textContent = c('merge.direction', { keep: d.keep === customer.id ? customer.name : other.name, merge: d.merge === customer.id ? customer.name : other.name }); };
    paint();
    const swap = h('button', { type: 'button', class: 'linkish', 'data-testid': 'cv-merge-swap', text: c('merge.swap'), onclick: () => { swapped = !swapped; paint(); planBox.replaceChildren(); confirmBox.replaceChildren(); } });
    const prev = h('button', { type: 'button', class: 'btn', 'data-testid': 'cv-merge-preview', text: c('merge.preview_btn'), onclick: () => runPreview() });
    results.append(label, h('div', { class: 'row' }, swap, prev));
  }
  async function search() {
    results.replaceChildren(); planBox.replaceChildren(); confirmBox.replaceChildren(); other = null;
    const term = q.value.trim(); if (term.length < 2) return;
    let rows;
    try { rows = await rpc('admin_list_customers', { p_search: term, p_limit: 8, p_offset: 0 }); }
    catch (e) { results.append(h('p', { class: 'err', role: 'alert', text: c('merge.search_failed', { error: errMsg(e) }) })); return; }
    rows = (rows || []).filter((r) => Number(r.id) !== Number(customer.id));
    if (!rows.length) { results.append(h('p', { class: 'muted ov-small', text: c('merge.no_results') })); return; }
    for (const r of rows) results.append(h('div', { class: 'row between', 'data-testid': 'cv-merge-result' },
      h('span', { class: 'ov-small', text: [r.customer_kind === 'company' && r.company ? r.company : r.name, r.email, r.phone].filter(Boolean).join(' · ') }),
      h('button', { type: 'button', class: 'btn ghost', text: c('merge.pick'), onclick: () => pick({ id: Number(r.id), name: r.customer_kind === 'company' && r.company ? r.company : r.name }) })));
  }
  q.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); search(); } });
  wrap.append(h('h3', { class: 'ov-cap', text: c('merge.title') }), h('p', { class: 'muted ov-small', text: c('merge.intro') }),
    h('label', { class: 'fld' }, h('span', { text: c('merge.search_label') }), q),
    h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'cv-merge-search', text: c('merge.search_btn'), onclick: () => search() }),
    results, planBox, confirmBox);
  return wrap;
}

function anonymizeBlock({ rpc, customer, onDone }) {
  const wrap = h('div', { class: 'stack', 'data-testid': 'cv-anonymize' });
  const planBox = h('div', { class: 'stack' });
  const confirmBox = h('div', { class: 'stack' });
  let busy = false;
  async function runPreview() {
    planBox.replaceChildren(); confirmBox.replaceChildren();
    let plan;
    try { plan = await rpc('admin_anonymize_customer_preview', { p_id: customer.id }); }
    catch (e) { planBox.append(h('p', { class: 'err', role: 'alert', text: c('anonymize.preview_failed', { error: errMsg(e) }) })); return; }
    planBox.append(planView(plan, 'anonymize'));
    if (plan.already_anonymized) { planBox.append(h('p', { class: 'muted ov-small', text: c('anonymize.already') })); return; }
    if (!plan.ok) return;
    const reason = h('input', { type: 'text', maxlength: '500', 'data-testid': 'cv-anon-reason', 'aria-label': c('anonymize.reason_label') });
    const check = h('input', { type: 'checkbox', 'data-testid': 'cv-anon-check' });
    const btn = h('button', { type: 'button', class: 'btn danger', 'data-testid': 'cv-anon-confirm', text: c('anonymize.confirm_btn'), disabled: true });
    const sync = () => { btn.disabled = !canConfirmAnonymize({ plan, checked: check.checked, reason: reason.value, busy }); };
    check.addEventListener('change', sync); reason.addEventListener('input', sync);
    btn.addEventListener('click', async () => {
      busy = true; sync(); btn.textContent = c('anonymize.working');
      try {
        const r = await rpc('admin_anonymize_customer', { p_id: customer.id, p_reason: reason.value.trim(), p_confirm: true });
        toast(r?.already_anonymized ? c('anonymize.already') : c('anonymize.done'), 'ok');
        onDone(customer.id);
      } catch (e) {
        busy = false; btn.textContent = c('anonymize.confirm_btn'); sync();
        confirmBox.append(h('p', { class: 'err', role: 'alert', text: c('anonymize.failed', { error: errMsg(e) }) }));
      }
    });
    confirmBox.append(h('label', { class: 'fld' }, h('span', { text: c('anonymize.reason_label') }), reason),
      h('label', { class: 'row' }, check, h('span', { text: c('anonymize.confirm_check') })), btn);
  }
  wrap.append(h('h3', { class: 'ov-cap', text: c('anonymize.title') }), h('p', { class: 'muted ov-small', text: c('anonymize.intro') }),
    h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'cv-anon-preview', text: c('anonymize.preview_btn'), onclick: () => runPreview() }), planBox, confirmBox);
  return wrap;
}
