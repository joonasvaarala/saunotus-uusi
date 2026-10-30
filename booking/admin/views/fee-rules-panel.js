// Asetukset › Maksut: provisiosäännöt (booking_216). Tallennus admin_upsert_payment_fee_rule, oikeus settings.edit.
import { rpc } from '../sb.js';
import { h, field, toast, run } from '../ui.js';
import { reportText as rt } from '../reports-texts.js';
import { parseFeeAmount, providerAdminLabel } from '../fee-report-logic.js';

const PROVIDERS = ['montonio', 'visma_pay', 'mobilepay', 'manual', 'johku'];
const METHODS = ['*', 'montonio', 'visma_pay', 'mobilepay', 'card_terminal', 'bank_transfer', 'invoice', 'gift_card', 'partner_voucher', 'pay_later', 'other'];
const METHOD_LABELS = {
  montonio: 'Maksa verkossa',
  visma_pay: 'Visma Pay',
  mobilepay: 'MobilePay',
  card_terminal: 'Korttipääte',
  bank_transfer: 'Tilisiirto',
  invoice: 'Lasku',
  gift_card: 'Lahjakortti',
  partner_voucher: 'Kumppanin lahjakortti',
  pay_later: 'Paikan päällä',
  other: 'Muu',
};

function methodLabel(code) {
  if (code === '*') return rt('ui.admin.reports.fee_rules_all_methods');
  return METHOD_LABELS[code] || code;
}

export function feeRulesCard() {
  const box = h('div', { 'data-testid': 'fee-rules' });
  const provider = h('select', { 'data-testid': 'fee-rule-provider', 'aria-label': rt('ui.admin.reports.fee_rules_provider') }, PROVIDERS.map((code) => h('option', { value: code, text: providerAdminLabel(code) })));
  const method = h('select', { 'data-testid': 'fee-rule-method', 'aria-label': rt('ui.admin.reports.fee_rules_method') }, METHODS.map((code) => h('option', { value: code, text: methodLabel(code) })));
  const fixed = h('input', { type: 'text', inputmode: 'decimal', autocomplete: 'off', value: '0', 'data-testid': 'fee-rule-fixed', 'aria-label': rt('ui.admin.reports.fee_rules_fixed') });
  const percent = h('input', { type: 'text', inputmode: 'decimal', autocomplete: 'off', value: '0', 'data-testid': 'fee-rule-percent', 'aria-label': rt('ui.admin.reports.fee_rules_percent') });
  const active = h('input', { type: 'checkbox', 'data-testid': 'fee-rule-active' });
  active.checked = true;
  const activeRow = h('div', { class: 'switch-row' },
    h('div', {}, h('b', { text: rt('ui.admin.reports.fee_rules_active') })),
    h('label', { class: 'switch' }, active, h('i'), h('span', { class: 'sr', text: rt('ui.admin.reports.fee_rules_active') })));
  const err = h('p', { class: 'err', role: 'alert', hidden: true, 'data-testid': 'fee-rule-err' });
  const list = h('div', { 'data-testid': 'fee-rule-list' });
  const save = h('button', { type: 'button', class: 'btn primary', 'data-testid': 'fee-rule-save', text: rt('ui.admin.reports.fee_rules_save') });

  function draw(rows) {
    if (!rows.length) { list.replaceChildren(h('p', { class: 'muted', text: rt('ui.admin.reports.fee_rules_empty') })); return; }
    const cols = [rt('ui.admin.reports.fee_rules_provider'), rt('ui.admin.reports.fee_rules_method'), rt('ui.admin.reports.fee_rules_fixed'), rt('ui.admin.reports.fee_rules_percent'), rt('ui.admin.reports.fee_rules_active'), ''];
    list.replaceChildren(h('table', { class: 'tl-table' },
      h('thead', {}, h('tr', {}, cols.map((c, i) => h('th', { scope: 'col', class: i && i < 5 ? 'r' : '', text: c })))),
      h('tbody', {}, rows.map((row) => h('tr', {},
        h('th', { scope: 'row', text: row.provider_label || providerAdminLabel(row.provider) }),
        h('td', { class: 'r', 'data-label': cols[1], text: methodLabel(row.method) }),
        h('td', { class: 'r', 'data-label': cols[2], text: String(row.fixed_eur).replace('.', ',') }),
        h('td', { class: 'r', 'data-label': cols[3], text: String(row.percent).replace('.', ',') }),
        h('td', { class: 'r', 'data-label': cols[4], text: row.active ? rt('ui.admin.reports.fee_rules_active') : '–' }),
        h('td', {}, h('button', { type: 'button', class: 'btn', 'data-testid': `fee-rule-remove-${row.id}`, text: rt('ui.admin.reports.fee_rules_remove'), onclick: (e) => run(e.currentTarget, async () => { await rpc('admin_delete_payment_fee_rule', { p_id: row.id }); toast(rt('ui.admin.reports.fee_rules_saved')); await load(); }) })))))));
  }
  async function load() {
    const res = await rpc('admin_list_payment_fee_rules');
    draw(Array.isArray(res?.rows) ? res.rows : []);
  }
  save.addEventListener('click', () => run(save, async () => {
    const fixedEur = parseFeeAmount(fixed.value, 1000);
    const pct = parseFeeAmount(percent.value, 100);
    if (fixedEur == null || pct == null) { err.textContent = rt('ui.admin.reports.fee_rules_invalid'); err.hidden = false; return; }
    err.hidden = true;
    await rpc('admin_upsert_payment_fee_rule', { p: { provider: provider.value, method: method.value, fixed_eur: fixedEur, percent: pct, active: active.checked } });
    toast(rt('ui.admin.reports.fee_rules_saved'));
    await load();
  }));
  box.append(
    h('div', { class: 'tl-sortrow' }, field(rt('ui.admin.reports.fee_rules_provider'), provider), field(rt('ui.admin.reports.fee_rules_method'), method)),
    h('div', { class: 'tl-sortrow' }, field(rt('ui.admin.reports.fee_rules_fixed'), fixed), field(rt('ui.admin.reports.fee_rules_percent'), percent)),
    activeRow,
    err, save, list);
  list.append(h('p', { class: 'muted', text: rt('ui.admin.reports.fee_rules_loading') }));
  load().catch((e) => { list.replaceChildren(h('p', { class: 'muted', text: e?.message || rt('ui.admin.reports.fee_unavailable') })); });
  return h('section', { class: 'card', 'data-testid': 'fee-rules-card' },
    h('h2', { text: rt('ui.admin.reports.fee_rules_title') }),
    h('p', { class: 'muted', text: rt('ui.admin.reports.fee_rules_help') }),
    box);
}
