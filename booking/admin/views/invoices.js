// Hallinta › Laskut: haku näkyvissä, muut suodattimet kiinni. Luonnos, lähetys, hyvitys, itse tehty lasku tai tilauksesta.
import { rpc, functionUrl } from '../sb.js';
import { h, money, toast, dialog, field, empty } from '../ui.js';
import { countActive, filterDrawer } from '../filter-drawer.js';
import { invoiceText, loadInvoiceTexts } from '../invoices-texts.js';
import { lookupSearch } from './customerform.js';
import { customerDirty, routeSearchTerm } from '../invoice-customer-search.js';
import { fetchYtj } from '../ytj.js';

const STATUSES = ['draft', 'sent', 'paid', 'overdue', 'credited', 'voided'];
const tx = (k) => invoiceText(k);

function input(attrs) {
  return h('input', { class: 'inp', ...attrs });
}

function statusLabel(s) {
  return tx(`ui.admin.invoices.st_${s}`);
}

export async function render() {
  await loadInvoiceTexts(rpc);
  const st = { search: '', status: '', kind: '', from: '', to: '' };
  const list = h('div', { class: 'list', 'data-testid': 'invoices-list' });
  const detail = h('div', { id: 'invoice-detail' });
  const search = input({ type: 'search', placeholder: tx('ui.admin.invoices.search_ph'), 'aria-label': tx('ui.admin.invoices.search'), 'data-testid': 'invoices-search', oninput: (e) => { st.search = e.target.value; draw(); } });
  const statusSel = h('select', { onchange: (e) => { st.status = e.target.value; draw(); } }, h('option', { value: '', text: tx('ui.admin.invoices.all') }), ...STATUSES.map((s) => h('option', { value: s, text: statusLabel(s) })));
  const kindSel = h('select', { onchange: (e) => { st.kind = e.target.value; draw(); } }, h('option', { value: '', text: tx('ui.admin.invoices.all') }), h('option', { value: 'debit', text: tx('ui.admin.invoices.kind_debit') }), h('option', { value: 'credit', text: tx('ui.admin.invoices.kind_credit') }));
  const from = input({ type: 'date', onchange: (e) => { st.from = e.target.value; draw(); } });
  const to = input({ type: 'date', onchange: (e) => { st.to = e.target.value; draw(); } });
  const drawer = filterDrawer({
    testid: 'invoices-filters',
    search: [field(tx('ui.admin.invoices.search'), search)],
    filters: [
      field(tx('ui.admin.invoices.status'), statusSel),
      field(tx('ui.admin.invoices.kind'), kindSel),
      field(tx('ui.admin.invoices.from'), from),
      field(tx('ui.admin.invoices.to'), to),
    ],
    activeCount: () => countActive(st, { status: '', kind: '', from: '', to: '' }),
  });
  let rows = [];
  async function load() {
    const r = await rpc('admin_list_invoices', { p_search: st.search || null, p_status: st.status || null, p_kind: st.kind || null, p_from: st.from || null, p_to: st.to || null, p_limit: 100, p_offset: 0 });
    rows = r.rows || [];
    list.replaceChildren(...(rows.length ? rows.map(rowBtn) : [empty(tx('ui.admin.invoices.empty'))]));
  }
  function rowBtn(inv) {
    const c = inv.customer || {};
    return h('button', { type: 'button', class: 'listrow', 'data-testid': 'invoice-row', onclick: () => open(inv.id) },
      h('span', { class: 'what' }, h('strong', { text: inv.invoice_no || statusLabel('draft') }), h('small', { text: ` ${c.name || c.company_name || ''}` })),
      h('span', { class: 'meta' }, h('span', { class: `badge st-${inv.status}`, text: statusLabel(inv.status) }), h('small', { text: ` ${money(inv.total_gross)} · ${inv.due_date || ''}` })));
  }
  async function draw() { try { await load(); } catch (e) { list.replaceChildren(h('p', { class: 'err', text: e.message || String(e) })); } }
  async function open(id) {
    const inv = await rpc('admin_get_invoice', { p_id: id });
    detail.replaceChildren(preview(inv));
  }
  function preview(inv) {
    const c = inv.customer || {};
    const seller = inv.seller_snapshot || {};
    const lines = inv.lines || [];
    const locked = inv.status !== 'draft';
    const pdf = inv.public_token && inv.invoice_no ? h('a', { class: 'btn', href: `${functionUrl('invoice-pdf')}?t=${inv.public_token}`, target: '_blank', rel: 'noopener', text: tx('ui.admin.invoices.pdf') }) : null;
    const actions = h('div', { class: 'row' },
      inv.status === 'draft' ? h('button', { class: 'btn primary', type: 'button', onclick: () => send(inv.id, true, false) }, tx('ui.admin.invoices.send_einvoice')) : null,
      inv.status === 'draft' || inv.status === 'sent' || inv.status === 'overdue' ? h('button', { class: 'btn', type: 'button', onclick: () => send(inv.id, false, true) }, tx('ui.admin.invoices.send_email')) : null,
      inv.status === 'sent' || inv.status === 'overdue' ? h('button', { class: 'btn', type: 'button', onclick: () => act('admin_mark_invoice_paid', inv.id) }, tx('ui.admin.invoices.mark_paid')) : null,
      inv.kind === 'debit' && ['sent', 'paid', 'overdue'].includes(inv.status) ? h('button', { class: 'btn', type: 'button', onclick: () => act('admin_credit_invoice', inv.id) }, tx('ui.admin.invoices.credit')) : null,
      inv.status === 'draft' ? h('button', { class: 'btn ghost', type: 'button', onclick: () => act('admin_void_invoice', inv.id) }, tx('ui.admin.invoices.void')) : null,
      ['failed', 'dry_run', 'skipped'].includes(inv.dispatch_status) ? h('button', { class: 'btn ghost', type: 'button', onclick: () => act('admin_retry_invoice_dispatch', inv.id) }, tx('ui.admin.invoices.retry')) : null,
      pdf);
    return h('article', { class: 'card pad', 'data-testid': 'invoice-preview' },
      h('h2', { text: tx('ui.admin.invoices.preview') }),
      h('p', {}, h('strong', { text: seller.legal_name || seller.name || '' }), h('br'), seller.business_id ? `${tx('ui.admin.invoices.business_id')}: ${seller.business_id}` : '', seller.vat_id ? ` · ${tx('ui.admin.invoices.vat_id')}: ${seller.vat_id}` : ''),
      h('p', {}, h('strong', { text: c.company_name || c.name || '' }), h('br'), [c.business_id, c.einvoice_address, c.einvoice_operator, c.email].filter(Boolean).join(' · ')),
      h('p', { text: `${tx('ui.admin.invoices.number')}: ${inv.invoice_no || '–'} · ${tx('ui.admin.invoices.reference')}: ${inv.reference_no || '–'} · ${tx('ui.admin.invoices.due')}: ${inv.due_date}` }),
      h('p', { text: `${tx('ui.admin.invoices.dispatch')}: ${inv.dispatch_status || 'none'}${inv.dispatch_error ? ' — ' + inv.dispatch_error : ''}` }),
      locked ? h('p', { class: 'muted', text: tx('ui.admin.invoices.locked') }) : null,
      h('table', { class: 'grid' }, h('thead', {}, h('tr', {}, h('th', { text: tx('ui.admin.invoices.desc') }), h('th', { text: tx('ui.admin.invoices.qty') }), h('th', { text: tx('ui.admin.invoices.vat') }), h('th', { text: tx('ui.admin.invoices.total') }))),
        h('tbody', {}, ...lines.map((l) => h('tr', {}, h('td', { text: l.description }), h('td', { text: `${l.quantity} ${l.unit}` }), h('td', { text: String(l.vat_rate) }), h('td', { text: money(l.line_gross) }))))),
      h('p', {}, h('strong', { text: `${tx('ui.admin.invoices.total')} ${money(inv.total_gross)}` })),
      inv.notes ? h('p', { text: inv.notes }) : null,
      h('p', { class: 'muted', text: tx('ui.admin.invoices.terms') }),
      h('p', { class: 'muted', text: tx('ui.admin.invoices.privacy') }),
      actions);
  }
  async function act(fn, id) {
    try {
      const inv = await rpc(fn, { p_id: id });
      toast(statusLabel(inv.status));
      await draw();
      detail.replaceChildren(preview(inv));
    } catch (e) { toast(e.message || String(e)); }
  }
  async function send(id, einvoice, email) {
    try {
      const inv = await rpc('admin_send_invoice', { p_id: id, p_einvoice: einvoice, p_email: email });
      toast(statusLabel(inv.status));
      await draw();
      detail.replaceChildren(preview(inv));
    } catch (e) { toast(e.message || String(e)); }
  }
  const bar = h('div', { class: 'row' },
    h('button', { class: 'btn primary', type: 'button', onclick: () => editor(null) }, tx('ui.admin.invoices.new')),
    h('button', { class: 'btn', type: 'button', onclick: fromOrder }, tx('ui.admin.invoices.from_order')));
  await draw();
  return h('section', { class: 'pad' }, h('h1', { text: tx('ui.admin.invoices.title') }), bar, drawer.node, list, detail);

  async function fromOrder() {
    const orderId = input({ type: 'number', min: 1, required: true });
    const body = h('form', { class: 'form' }, field(tx('ui.admin.invoices.order'), orderId), h('button', { class: 'btn primary', type: 'submit' }, tx('ui.admin.invoices.from_order')));
    const dlg = dialog(tx('ui.admin.invoices.from_order'), body);
    body.onsubmit = async (ev) => {
      ev.preventDefault();
      try {
        const inv = await rpc('admin_create_invoice_from_order', { p_order_id: Number(orderId.value) });
        dlg.close(); toast(tx('ui.admin.invoices.saved')); await draw(); detail.replaceChildren(preview(inv));
      } catch (e) { toast(e.message || String(e)); }
    };
  }

  function customerFromError(e) {
    const raw = e?.details?.hint;
    if (!raw) return null;
    try {
      const c = typeof raw === 'string' ? JSON.parse(raw) : raw;
      return c && (c.id || c.company_name) ? c : null;
    } catch { return null; }
  }
  function choose(title, text, actions) {
    return new Promise((resolve) => {
      let settled = false;
      const done = (v) => { if (settled) return; settled = true; resolve(v); if (dlg.open) dlg.close(); };
      const body = h('div', { class: 'stack' }, h('p', { text }), h('div', { class: 'stack' }, ...actions.map((a) => h('button', { type: 'button', class: a.primary ? 'btn primary' : 'btn', onclick: () => done(a.value) }, a.label))));
      const dlg = dialog(title, body);
      dlg.addEventListener('close', () => { if (!settled) { settled = true; resolve(null); } });
    });
  }

  async function editor(existing) {
    const rates = ((await rpc('admin_list_vat_rates').catch(() => ({ rates: [] }))).rates || []).filter((r) => r.active);
    const defRate = rates.length ? String(rates.reduce((a, b) => (Number(b.rate) > Number(a.rate) ? b : a)).rate) : '';
    const lines = [{ description: '', quantity: 1, unit: 'kpl', unit_price_net: '', vat_rate: defRate }];
    const f = {};
    const cust = { row: null, snap: null, bookingId: null };
    const box = h('form', { class: 'form inv-editor', 'data-testid': 'invoice-new-form', novalidate: true });
    const add = (key, label, attrs = {}) => { f[key] = input({ name: key, ...attrs }); return field(label, f[key]); };
    const lineBox = h('div', { class: 'inv-lines' });
    function paintLines() {
      lineBox.replaceChildren(...lines.map((ln) => h('div', { class: 'row' },
        input({ value: ln.description, placeholder: tx('ui.admin.invoices.desc'), oninput: (e) => { ln.description = e.target.value; } }),
        input({ value: String(ln.quantity), inputmode: 'decimal', style: 'width:5rem', 'aria-label': tx('ui.admin.invoices.qty'), oninput: (e) => { ln.quantity = e.target.value; } }),
        input({ value: ln.unit, style: 'width:5rem', 'aria-label': tx('ui.admin.invoices.unit'), oninput: (e) => { ln.unit = e.target.value; } }),
        input({ value: String(ln.unit_price_net), inputmode: 'decimal', style: 'width:7rem', 'aria-label': tx('ui.admin.invoices.price'), oninput: (e) => { ln.unit_price_net = e.target.value; } }),
        h('select', { 'aria-label': tx('ui.admin.invoices.vat'), onchange: (e) => { ln.vat_rate = e.target.value; } }, ...rates.map((r) => h('option', { value: String(r.rate), selected: String(r.rate) === String(ln.vat_rate) || null, text: r.label || String(r.rate) }))))));
    }
    paintLines();
    const readFields = () => ({
      company_name: f.company_name.value, business_id: f.business_id.value, contact_name: f.contact_name.value, email: f.email.value, phone: f.phone.value,
      einvoice_address: f.einvoice_address.value, einvoice_operator: f.einvoice_operator.value, street: f.street.value, zip: f.zip.value, city: f.city.value, buyer_reference: f.buyer_reference.value,
    });
    const payloadOf = () => {
      const raw = readFields();
      const out = {};
      for (const [k, v] of Object.entries(raw)) out[k] = String(v || '').trim() || null;
      if (out.company_name) out.company_name = out.company_name.replace(/\s+/g, ' ');
      return out;
    };
    const applyMoved = (term) => {
      const moved = routeSearchTerm(term, readFields());
      if (moved.filled && f[moved.field]) f[moved.field].value = moved.value;
      return moved;
    };
    function fillFromCustomer(c) {
      const map = {
        company_name: c.company_name || c.name || '', business_id: c.business_id || '', contact_name: c.contact_name || '', email: c.email || '', phone: c.phone || '',
        einvoice_address: c.einvoice_address || '', einvoice_operator: c.einvoice_operator || '', street: c.street || '', zip: c.zip || '', city: c.city || '', buyer_reference: c.buyer_reference || '',
      };
      for (const [k, v] of Object.entries(map)) if (f[k]) f[k].value = v;
      if (c.source === 'booking') {
        cust.row = null; cust.snap = null; cust.bookingId = c.customer_id || null;
      } else {
        cust.row = c; cust.snap = map; cust.bookingId = null;
      }
    }
    const orLine = h('p', { class: 'nb-or muted', text: tx('ui.admin.invoices.find_or') });
    function ytjNode(term, moved) {
      const boxY = h('div', { class: 'stack', 'data-testid': 'invoice-ytj' });
      const msg = moved.filled ? tx(moved.field === 'business_id' ? 'ui.admin.invoices.moved_bid' : 'ui.admin.invoices.moved') : tx('ui.admin.invoices.not_overwritten');
      const btn = h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'invoice-ytj-btn', onclick: async () => {
        btn.disabled = true; boxY.replaceChildren(h('p', { class: 'muted', text: tx('ui.admin.invoices.ytj_loading') }));
        try {
          const rows = await fetchYtj(term);
          boxY.replaceChildren(rows.length ? h('div', { class: 'found' }, ...rows.map((y) => h('button', { type: 'button', class: 'listrow', 'data-testid': 'invoice-ytj-hit', onclick: () => applyYtj(y) }, h('strong', { text: y.company_name || y.business_id }), h('small', { text: ` ${[y.business_id, y.city].filter(Boolean).join(' · ')} · ${tx('ui.admin.invoices.ytj_hit')}` })))) : h('p', { class: 'muted', text: tx('ui.admin.invoices.ytj_empty') }));
        } catch { boxY.replaceChildren(h('p', { class: 'err', role: 'alert', text: tx('ui.admin.invoices.ytj_error') })); }
        finally { btn.disabled = false; }
      } }, tx('ui.admin.invoices.ytj'));
      return h('div', { class: 'stack' },
        h('p', { class: 'notfound', role: 'status', 'data-testid': 'invoice-customer-notfound' }, h('strong', { text: tx('ui.admin.invoices.not_found') }), h('small', { text: ` ${msg}` })),
        btn, h('p', { class: 'muted', text: tx('ui.admin.invoices.ytj_note') }), boxY);
    }
    const cs = lookupSearch({
      placeholder: tx('ui.admin.invoices.find_ph'), ariaLabel: tx('ui.admin.invoices.find_aria'), buttonLabel: tx('ui.admin.invoices.find_btn'),
      buttonTestId: 'invoice-customer-search', pickedTestId: 'invoice-customer-picked',
      search: async (term) => {
        const rows = await rpc('admin_search_invoice_customers', { p_search: term, p_limit: 10 });
        return Array.isArray(rows) ? rows : [];
      },
      hitTitle: (c) => c.company_name || c.name || '',
      hitMeta: (c) => [c.business_id, c.email, tx(c.source === 'booking' ? 'ui.admin.invoices.src_booking' : 'ui.admin.invoices.src_invoice')].filter(Boolean).join(' · '),
      onPick: (c) => { fillFromCustomer(c); orLine.hidden = true; },
      pickedTitle: (c) => c.company_name || c.name || '',
      pickedMeta: (c) => {
        const bits = [c.business_id, c.email].filter(Boolean).join(' · ');
        const note = c.source === 'booking' ? tx('ui.admin.invoices.booking_note') : tx('ui.admin.invoices.found_note');
        return bits ? `${bits} · ${note}` : note;
      },
      newLabel: tx('ui.admin.invoices.new_customer'),
      onReset: () => { cust.row = null; cust.snap = null; cust.bookingId = null; orLine.hidden = false; },
      onExplicitMiss: (term) => ytjNode(term, applyMoved(term)),
    });
    function applyYtj(y) {
      if (y.company_name) f.company_name.value = y.company_name;
      if (y.business_id) f.business_id.value = y.business_id;
      if (y.street) f.street.value = y.street;
      if (y.zip) f.zip.value = y.zip;
      if (y.city) f.city.value = y.city;
      cs.reset();
    }
    cs.input.addEventListener('blur', (ev) => {
      if (ev.relatedTarget && cs.found.contains(ev.relatedTarget)) return;
      const term = cs.input.value.trim();
      const moved = cust.row || cust.bookingId ? null : applyMoved(term);
      setTimeout(() => {
        if (cust.row || cust.bookingId || cs.found.querySelector('.picked-cust, .listrow, [data-testid="invoice-ytj"]')) return;
        if (term.length < 2) return;
        cs.found.replaceChildren(ytjNode(term, moved || routeSearchTerm(term, readFields())));
      }, 200);
    });
    async function offerExisting(e) {
      const existing = customerFromError(e);
      if (e?.code === 'customer_exists' && existing) {
        const choice = await choose(tx('ui.admin.invoices.exists_title'), `${tx('ui.admin.invoices.exists_body')} ${existing.company_name || ''} (${existing.business_id || ''})`.trim(), [
          { value: 'use', label: tx('ui.admin.invoices.use_existing'), primary: true },
        ]);
        if (choice !== 'use') return null;
        cs.pick(existing);
        return { id: existing.id, mode: 'registry' };
      }
      if (e?.code === 'name_email_match' && existing) {
        const choice = await choose(tx('ui.admin.invoices.name_email_title'), `${tx('ui.admin.invoices.name_email_body')} ${existing.company_name || ''}`.trim(), [
          { value: 'use', label: tx('ui.admin.invoices.use_existing'), primary: true },
          { value: 'new', label: tx('ui.admin.invoices.save_anyway') },
        ]);
        if (choice === 'use') { cs.pick(existing); return { id: existing.id, mode: 'registry' }; }
        if (choice === 'new') {
          const created = await rpc('admin_save_invoice_customer', { p_id: null, p: { ...payloadOf(), customer_id: cust.bookingId || null, ack_name_email: true } });
          return { id: created.id, mode: 'registry' };
        }
        return null;
      }
      return undefined;
    }
    async function persistCustomer(payload) {
      if (cust.row && !customerDirty(payload, cust.snap)) return { id: cust.row.id, mode: 'registry' };
      if (cust.row) {
        const choice = await choose(tx('ui.admin.invoices.changed_title'), tx('ui.admin.invoices.changed_body'), [
          { value: 'customer', label: tx('ui.admin.invoices.update_customer'), primary: true },
          { value: 'invoice', label: tx('ui.admin.invoices.only_invoice') },
        ]);
        if (!choice) return null;
        if (choice === 'invoice') return { id: cust.row.id, mode: 'invoice' };
        try {
          await rpc('admin_save_invoice_customer', { p_id: cust.row.id, p: payload });
          return { id: cust.row.id, mode: 'registry' };
        } catch (e) {
          const alt = await offerExisting(e);
          if (alt !== undefined) return alt;
          throw e;
        }
      }
      try {
        const created = await rpc('admin_save_invoice_customer', { p_id: null, p: { ...payload, customer_id: cust.bookingId || null } });
        return { id: created.id, mode: 'registry' };
      } catch (e) {
        if (cust.bookingId && e?.code === 'customer_exists') {
          const existing = customerFromError(e);
          if (existing?.id) return { id: existing.id, mode: 'registry' };
        }
        const alt = await offerExisting(e);
        if (alt !== undefined) return alt;
        throw e;
      }
    }
    box.append(
      h('div', { class: 'nb-search' }, h('span', { class: 'fld-lab', text: tx('ui.admin.invoices.find') }), cs.row, cs.found),
      orLine,
      add('company_name', tx('ui.admin.invoices.company')),
      add('business_id', tx('ui.admin.invoices.business_id')),
      add('contact_name', tx('ui.admin.invoices.contact')),
      add('email', tx('ui.admin.invoices.email'), { type: 'email', inputmode: 'email' }),
      add('phone', tx('ui.admin.invoices.phone'), { type: 'tel', inputmode: 'tel' }),
      add('einvoice_address', tx('ui.admin.invoices.ovt'), { inputmode: 'numeric' }),
      add('einvoice_operator', tx('ui.admin.invoices.operator')),
      add('street', tx('ui.admin.invoices.street')), add('zip', tx('ui.admin.invoices.zip'), { inputmode: 'numeric' }), add('city', tx('ui.admin.invoices.city')),
      add('buyer_reference', tx('ui.admin.invoices.buyer_ref')),
      add('invoice_date', tx('ui.admin.invoices.date'), { type: 'date' }),
      add('due_date', tx('ui.admin.invoices.due'), { type: 'date' }),
      add('notes', tx('ui.admin.invoices.notes')),
      h('h3', { text: tx('ui.admin.invoices.desc') }), lineBox,
      h('button', { type: 'button', class: 'btn ghost', onclick: () => { lines.push({ description: '', quantity: 1, unit: 'kpl', unit_price_net: '', vat_rate: defRate }); paintLines(); } }, tx('ui.admin.invoices.add_line')),
      h('button', { class: 'btn primary', type: 'submit' }, tx('ui.admin.invoices.save')));
    const dlg = dialog(tx('ui.admin.invoices.new'), box, { wide: true });
    box.onsubmit = async (ev) => {
      ev.preventDefault();
      if (!cust.row) applyMoved(cs.input.value);
      const payload = payloadOf();
      if (!payload.company_name || payload.company_name.length < 2) { toast(tx('ui.admin.invoices.need_company')); f.company_name.focus(); return; }
      try {
        const linked = await persistCustomer(payload);
        if (!linked) return;
        const inv = await rpc('admin_save_invoice', { p_id: existing, p: {
          customer_id: linked.id, snapshot_mode: linked.mode, customer_override: linked.mode === 'invoice' ? payload : null,
          invoice_date: f.invoice_date.value || null, due_date: f.due_date.value || null,
          buyer_reference: payload.buyer_reference, notes: f.notes.value.trim() || null,
          lines: lines.map((ln) => ({ description: ln.description, quantity: Number(ln.quantity), unit: ln.unit || 'kpl', unit_price_net: Number(ln.unit_price_net), vat_rate: Number(ln.vat_rate) })),
        } });
        dlg.close(); toast(tx('ui.admin.invoices.saved')); await draw(); detail.replaceChildren(preview(inv));
      } catch (e) { toast(e.message || String(e)); }
    };
  }
}
