// booking_349 (K9): maksuvälittäjän tilitykset provisioraportin alla. Lista (reports.view), kulutili ja CSV-tuonti (settings.edit).
// Tuonti: ensin esikatselu (p_dry_run), sitten vahvistus. Kuluja ei kirjata kirjanpitoon (posted = false). Muoto: booking/docs/tilitys-csv.md.
import { h, toast, errMsg } from '../ui.js';
import { fmt } from '../talous-i18n.js';
import { reportText as rt } from '../reports-texts.js';

const PROVIDERS = ['montonio', 'sumup', 'vismapay', 'mobilepay', 'checkoutx'];
const MAX_BYTES = 1048576;

export function renderSettlements({ api, span, canImport = false }) {
  const box = h('section', { class: 'tl-sec', 'data-testid': 'r-settlements' });
  const M = fmt.money;
  async function load() {
    let data;
    try { data = await api.listSettlements(span.from, span.to); } catch (e) { box.replaceChildren(h('p', { class: 'error', text: errMsg(e) })); return; }
    if (!data) { box.hidden = true; return; }
    box.hidden = false;
    const cols = ['stl_col_date', 'stl_col_provider', 'stl_col_batch', 'stl_col_gross', 'stl_col_fee', 'stl_col_net', 'stl_col_unmatched'].map((k) => rt(`ui.admin.reports.${k}`));
    const list = data.rows.length
      ? h('table', { class: 'tl-table', 'data-testid': 'r-settlements-table' },
          h('thead', {}, h('tr', {}, cols.map((c, i) => h('th', { scope: 'col', class: i > 2 ? 'r' : '', text: c })))),
          h('tbody', {}, data.rows.map((x) => h('tr', {}, h('th', { scope: 'row', text: x.settled_on ? fmt.date(x.settled_on) : '' }), h('td', { text: x.provider_label }), h('td', { text: x.batch_ref }),
            h('td', { class: 'r', text: M(x.gross) }), h('td', { class: 'r', text: M(x.fee) }), h('td', { class: 'r', text: M(x.net) }), h('td', { class: 'r', text: fmt.int(x.unmatched) })))),
          h('tfoot', {}, h('tr', {}, h('th', { scope: 'row', text: rt('ui.admin.reports.total') }), h('td'), h('td'), h('td', { class: 'r', text: M(data.totals.gross) }), h('td', { class: 'r', text: M(data.totals.fee) }), h('td', { class: 'r', text: M(data.totals.net) }), h('td', { class: 'r', text: fmt.int(data.totals.unmatched) }))))
      : h('p', { class: 'muted', text: rt('ui.admin.reports.stl_none') });
    box.replaceChildren(h('h3', { text: rt('ui.admin.reports.stl_title') }), h('p', { class: 'muted', text: rt('ui.admin.reports.stl_help') }), list, account(data.fee_account), canImport ? importForm() : null);
  }
  function account(current) {
    const line = h('p', { 'data-testid': 'r-stl-fee-account', text: current ? `${rt('ui.admin.reports.stl_fee_account')}: ${current}. ${rt('ui.admin.reports.stl_not_posted')}` : rt('ui.admin.reports.stl_fee_account_missing') });
    if (!canImport) return line;
    const input = h('input', { type: 'text', value: current || '', maxlength: '20', 'aria-label': rt('ui.admin.reports.stl_fee_account'), 'data-testid': 'r-stl-fee-account-input' });
    const save = h('button', { type: 'button', class: 'btn', text: rt('ui.admin.reports.stl_fee_account_save'), onclick: async () => {
      save.disabled = true;
      try { await api.setProviderFeeAccount(input.value.trim()); toast(rt('ui.admin.reports.stl_saved')); load(); } catch (e) { toast(errMsg(e), 'error'); } finally { save.disabled = false; }
    } });
    return h('div', {}, line, h('label', {}, rt('ui.admin.reports.stl_fee_account'), ' ', input), ' ', save);
  }
  function importForm() {
    const provider = h('select', { 'aria-label': rt('ui.admin.reports.stl_provider'), 'data-testid': 'r-stl-provider' }, PROVIDERS.map((p) => h('option', { value: p, text: p })));
    const file = h('input', { type: 'file', accept: '.csv,text/csv', 'aria-label': rt('ui.admin.reports.stl_file'), 'data-testid': 'r-stl-file' });
    const overwrite = h('input', { type: 'checkbox', 'data-testid': 'r-stl-overwrite' });
    const result = h('p', { 'data-testid': 'r-stl-result', 'aria-live': 'polite' });
    const confirm = h('button', { type: 'button', class: 'btn primary', text: rt('ui.admin.reports.stl_confirm'), disabled: true, 'data-testid': 'r-stl-confirm' });
    let pending = null;
    async function read() {
      const f = file.files?.[0];
      if (!f || f.size > MAX_BYTES) throw new Error('CSV: max 1 MB');
      return { provider: provider.value, csv: await f.text(), filename: f.name, overwriteFees: overwrite.checked };
    }
    const preview = h('button', { type: 'button', class: 'btn', text: rt('ui.admin.reports.stl_preview'), 'data-testid': 'r-stl-preview', onclick: async () => {
      confirm.disabled = true; pending = null; result.textContent = '';
      try {
        const args = await read();
        const r = await api.importSettlementCsv({ ...args, dryRun: true });
        result.textContent = rt('ui.admin.reports.stl_preview_summary', { rows: r.rows, batches: (r.batches || []).length, unmatched: (r.unmatched || []).length, conflicts: (r.fee_conflicts || []).length });
        pending = args; confirm.disabled = false;
      } catch (e) { result.textContent = errMsg(e); }
    } });
    confirm.addEventListener('click', async () => {
      if (!pending) return;
      confirm.disabled = true;
      try {
        const r = await api.importSettlementCsv({ ...pending, dryRun: false });
        toast(rt('ui.admin.reports.stl_imported', { fees: r.fees_set ?? 0 }));
        pending = null; load();
      } catch (e) { result.textContent = errMsg(e); confirm.disabled = false; }
    });
    for (const el of [provider, file, overwrite]) el.addEventListener('change', () => { pending = null; confirm.disabled = true; });
    return h('div', { class: 'tl-stl-import' }, h('h4', { text: rt('ui.admin.reports.stl_import') }),
      h('label', {}, rt('ui.admin.reports.stl_provider'), ' ', provider), ' ', h('label', {}, rt('ui.admin.reports.stl_file'), ' ', file),
      h('label', {}, overwrite, ' ', rt('ui.admin.reports.stl_overwrite')), h('div', {}, preview, ' ', confirm), result);
  }
  load();
  return box;
}
