// Uusi lasku: tuoterivit kortteina (mobiili) ja taulukkorivinä (leveä). Sama lohko on editor()-lomakkeessa.
import { h, money } from './ui.js';
import { icon } from './icons.js';
import {
  UNITS, amountsForLine, catalogPriceString, formatFiScaled, formatRateFi,
  lineToPayload, rateTenthsOf, suggestLines, summarize, validateLine,
} from './invoice-lines.js';

const ERR = {
  description: 'ui.admin.invoices.err_desc',
  quantity: 'ui.admin.invoices.err_qty',
  price: 'ui.admin.invoices.err_price',
  vat: 'ui.admin.invoices.err_vat',
};

function euro(cents) {
  return money(Number(cents) / 100);
}

function lineAmounts(ln) {
  return amountsForLine({
    quantity: ln.quantity,
    priceNet: ln.price_net,
    priceGross: ln.price_gross,
    vatRate: ln.vat_rate,
    basis: ln.basis === 'net' ? 'net' : 'gross',
  });
}

export function mountInvoiceLines({ rates, products, tx }) {
  const active = (rates || []).filter((r) => r && r.active !== false);
  const defRate = active.length ? String(active.reduce((a, b) => (Number(b.rate) > Number(a.rate) ? b : a)).rate) : '';
  const state = { showErrors: false, lines: [blank()] };
  const lineBox = h('div', { class: 'inv-lines', 'data-testid': 'invoice-lines' });
  const totals = h('div', { class: 'inv-totals', 'data-testid': 'invoice-totals' });
  const blockErr = h('p', { class: 'fld-err', role: 'alert', 'data-testid': 'invoice-lines-error' });
  const block = h('div', { class: 'inv-lineblock' },
    h('h3', { class: 'inv-lines-h', text: tx('ui.admin.invoices.lines') }),
    h('p', { class: 'inv-price-note', text: tx('ui.admin.invoices.price_either') }),
    blockErr,
    lineBox,
    h('button', { type: 'button', class: 'inv-add', 'data-testid': 'invoice-add-line', onclick: () => addLine() }, `+ ${tx('ui.admin.invoices.add_line')}`),
    totals);

  function blank() {
    return { description: '', quantity: '1', unit: 'kpl', price_net: '', price_gross: '', basis: 'gross', vat_rate: defRate, productId: null, touched: {} };
  }
  function addLine() {
    state.lines.push(blank());
    paint();
    const cards = lineBox.querySelectorAll('[data-testid=invoice-line]');
    cards[cards.length - 1]?.querySelector('[data-testid=invoice-line-desc]')?.focus();
  }
  function remove(index) {
    state.lines.splice(index, 1);
    if (!state.lines.length) state.lines.push(blank());
    paint();
  }
  function refreshTotals() {
    const rows = state.lines.map((ln) => lineAmounts(ln));
    const s = summarize(rows);
    const vatRows = s.vatByRate.map((r) => h('p', { class: 'inv-tot-row' },
      h('span', { text: `${tx('ui.admin.invoices.vat')} ${formatRateFi(r.rateTenths)}` }),
      h('span', { text: euro(r.vatCents) })));
    totals.replaceChildren(
      h('p', { class: 'inv-tot-row' }, h('span', { text: tx('ui.admin.invoices.total_net') }), h('span', { text: euro(s.netCents) })),
      ...(vatRows.length ? vatRows : [h('p', { class: 'inv-tot-row' }, h('span', { text: tx('ui.admin.invoices.vat') }), h('span', { text: euro(0n) }))]),
      h('p', { class: 'inv-tot-row grand' }, h('span', { text: tx('ui.admin.invoices.total') }), h('strong', { text: euro(s.grossCents) })));
  }
  function paint() {
    lineBox.replaceChildren(...state.lines.map((ln, i) => card(ln, i)));
    refreshTotals();
  }
  function card(ln, index) {
    const descErr = h('span', { class: 'fld-err', role: 'alert' });
    const qtyErr = h('span', { class: 'fld-err', role: 'alert' });
    const netErr = h('span', { class: 'fld-err', role: 'alert' });
    const grossErr = h('span', { class: 'fld-err', role: 'alert' });
    const vatErr = h('span', { class: 'fld-err', role: 'alert' });
    const sumEl = h('strong', { class: 'inv-line-sum', 'data-testid': 'invoice-line-sum' });
    const list = h('ul', { class: 'inv-suggest', role: 'listbox', hidden: true });
    const hits = { items: [], hi: -1 };
    const desc = h('input', {
      type: 'text', value: ln.description, autocomplete: 'off', role: 'combobox', 'aria-autocomplete': 'list', 'aria-expanded': 'false',
      placeholder: tx('ui.admin.invoices.line_product_ph'), 'data-testid': 'invoice-line-desc',
      oninput: (e) => { ln.description = e.target.value; ln.productId = null; openSuggest(e.target.value); sync(); },
      onkeydown: (e) => onDescKey(e),
      onblur: () => { ln.touched.description = true; setTimeout(() => { if (!list.contains(document.activeElement)) { list.hidden = true; desc.setAttribute('aria-expanded', 'false'); } showErr(); }, 180); },
    });
    const qty = h('input', {
      type: 'text', inputmode: 'decimal', value: ln.quantity, autocomplete: 'off', 'data-testid': 'invoice-line-qty',
      oninput: (e) => { ln.quantity = e.target.value; refreshPair(); },
      onkeydown: blockEnter,
      onblur: () => { ln.touched.quantity = true; showErr(); },
    });
    const unit = h('select', {
      'data-testid': 'invoice-line-unit', onchange: (e) => { ln.unit = e.target.value; },
    }, ...UNITS.map((u) => h('option', { value: u, text: u })));
    unit.value = UNITS.includes(ln.unit) ? ln.unit : 'kpl';
    const priceNet = h('input', {
      type: 'text', inputmode: 'decimal', value: ln.price_net, autocomplete: 'off', 'data-testid': 'invoice-line-price-net',
      oninput: (e) => applySource('net', e.target.value),
      onkeydown: blockEnter,
      onblur: () => { ln.touched.price_net = true; showErr(); },
    });
    const priceGross = h('input', {
      type: 'text', inputmode: 'decimal', value: ln.price_gross, autocomplete: 'off', 'data-testid': 'invoice-line-price-gross',
      oninput: (e) => applySource('gross', e.target.value),
      onkeydown: blockEnter,
      onblur: () => { ln.touched.price_gross = true; showErr(); },
    });
    const vat = h('select', {
      class: 'inv-vat', 'data-testid': 'invoice-line-vat', onchange: (e) => { ln.vat_rate = e.target.value; refreshPair(); showErr(); },
    }, ...active.map((r) => h('option', { value: String(r.rate), text: r.label || formatRateFi(rateTenthsOf(r.rate) || 0n) })));
    if (defRate || ln.vat_rate) vat.value = String(ln.vat_rate || defRate);
    ln.vat_rate = vat.value;

    function blockEnter(e) { if (e.key === 'Enter') e.preventDefault(); }
    function openSuggest(q) {
      const sug = suggestLines(products, q);
      hits.items = [
        ...sug.products.map((p) => ({ kind: 'product', product: p })),
        ...(sug.freeText ? [{ kind: 'free', text: sug.freeText }] : []),
      ];
      hits.hi = -1;
      if (!hits.items.length) { list.hidden = true; desc.setAttribute('aria-expanded', 'false'); list.replaceChildren(); return; }
      list.hidden = false;
      desc.setAttribute('aria-expanded', 'true');
      list.replaceChildren(...hits.items.map((item) => h('li', { role: 'presentation' }, item.kind === 'free'
        ? h('button', {
          type: 'button', role: 'option', class: 'inv-hit inv-hit-free', 'data-testid': 'invoice-free-text',
          onmousedown: (e) => { e.preventDefault(); acceptFree(item.text); },
        }, h('span', { text: `${tx('ui.admin.invoices.free_text')}: ${item.text}` }))
        : h('button', {
          type: 'button', role: 'option', class: 'inv-hit', 'data-testid': 'invoice-product-hit',
          onmousedown: (e) => { e.preventDefault(); pick(item.product); },
        }, h('span', { text: item.product.name }), h('small', { text: `${money(item.product.price)} · ${formatRateFi(rateTenthsOf(item.product.vat_rate) || 0n)}` })))));
    }
    function mark() {
      const buttons = [...list.querySelectorAll('[role=option]')];
      buttons.forEach((b, i) => b.setAttribute('aria-selected', i === hits.hi ? 'true' : 'false'));
      buttons[hits.hi]?.scrollIntoView({ block: 'nearest' });
    }
    function onDescKey(e) {
      if (e.key === 'Enter') {
        e.preventDefault();
        if (list.hidden) return;
        if (hits.hi >= 0) choose(hits.items[hits.hi]);
        else {
          const free = hits.items.find((item) => item.kind === 'free');
          if (free) acceptFree(free.text);
        }
        return;
      }
      if (list.hidden || !hits.items.length) return;
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        const n = hits.items.length;
        hits.hi = e.key === 'ArrowDown' ? (hits.hi < 0 ? 0 : (hits.hi + 1) % n) : (hits.hi <= 0 ? n - 1 : hits.hi - 1);
        mark();
      } else if (e.key === 'Escape') {
        list.hidden = true;
        desc.setAttribute('aria-expanded', 'false');
      }
    }
    function choose(item) {
      if (item.kind === 'free') acceptFree(item.text);
      else pick(item.product);
    }
    function acceptFree(text) {
      ln.description = text;
      ln.productId = null;
      desc.value = text;
      list.hidden = true;
      desc.setAttribute('aria-expanded', 'false');
      ln.touched.description = true;
      sync();
      showErr();
      qty.focus();
    }
    function pick(p) {
      ln.description = String(p.name);
      ln.productId = p.id ?? null;
      desc.value = ln.description;
      const rate = active.find((r) => rateTenthsOf(r.rate) === rateTenthsOf(p.vat_rate));
      if (rate) { ln.vat_rate = String(rate.rate); vat.value = ln.vat_rate; }
      ln.basis = 'gross';
      ln.price_gross = catalogPriceString(p.price);
      priceGross.value = ln.price_gross;
      const a = lineAmounts(ln);
      ln.price_net = a ? formatFiScaled(a.net10000, 4, 2) : '';
      priceNet.value = ln.price_net;
      list.hidden = true;
      desc.setAttribute('aria-expanded', 'false');
      ln.touched.description = true;
      ln.touched.price_gross = true;
      sync();
      showErr();
      qty.focus();
    }
    function applySource(which, raw) {
      ln.basis = which;
      ln.productId = null;
      if (which === 'net') ln.price_net = raw;
      else ln.price_gross = raw;
      const a = lineAmounts(ln);
      if (a && which === 'gross') {
        ln.price_net = formatFiScaled(a.net10000, 4, 2);
        priceNet.value = ln.price_net;
      } else if (a && which === 'net') {
        ln.price_gross = formatFiScaled(a.gross10000, 4, 2);
        priceGross.value = ln.price_gross;
      }
      sumEl.textContent = a ? euro(a.grossCents) : '–';
      refreshTotals();
    }
    function refreshPair() {
      const a = lineAmounts(ln);
      if (a && ln.basis === 'net') {
        ln.price_gross = formatFiScaled(a.gross10000, 4, 2);
        priceGross.value = ln.price_gross;
      } else if (a) {
        ln.price_net = formatFiScaled(a.net10000, 4, 2);
        priceNet.value = ln.price_net;
      }
      sumEl.textContent = a ? euro(a.grossCents) : '–';
      refreshTotals();
    }
    function sync() {
      const a = lineAmounts(ln);
      sumEl.textContent = a ? euro(a.grossCents) : '–';
      refreshTotals();
    }
    function showErr() {
      const errs = validateLine({ description: ln.description, quantity: ln.quantity, priceNet: ln.price_net, priceGross: ln.price_gross, vatRate: ln.vat_rate, rates: active, basis: ln.basis });
      apply(desc, descErr, 'description', errs.description);
      apply(qty, qtyErr, 'quantity', errs.quantity);
      apply(priceNet, netErr, 'price_net', errs.price_net);
      apply(priceGross, grossErr, 'price_gross', errs.price_gross);
      apply(vat, vatErr, 'vat', errs.vat);
    }
    function apply(input, errEl, key, code) {
      const on = Boolean((state.showErrors || ln.touched[key]) && code);
      if (on) input.setAttribute('aria-invalid', 'true'); else input.removeAttribute('aria-invalid');
      errEl.textContent = on ? tx(ERR[code] || ERR.price) : '';
    }
    sync();
    showErr();
    return h('article', { class: 'inv-line', 'data-testid': 'invoice-line' },
      h('div', { class: 'inv-desc' }, h('label', { class: 'fld' }, h('span', { text: tx('ui.admin.invoices.line_product') }), desc, descErr), list),
      h('div', { class: 'inv-nums' },
        h('label', { class: 'fld' }, h('span', { text: tx('ui.admin.invoices.qty') }), qty, qtyErr),
        h('label', { class: 'fld' }, h('span', { text: tx('ui.admin.invoices.unit') }), unit),
        h('label', { class: 'fld' }, h('span', { text: tx('ui.admin.invoices.vat_pct') }), vat, vatErr)),
      h('div', { class: 'inv-prices' },
        h('label', { class: 'fld' }, h('span', { text: tx('ui.admin.invoices.unit_net') }), priceNet, netErr),
        h('label', { class: 'fld' }, h('span', { text: tx('ui.admin.invoices.unit_gross') }), priceGross, grossErr)),
      h('div', { class: 'inv-line-foot' },
        h('p', { class: 'inv-line-sumline' }, h('span', { text: tx('ui.admin.invoices.line_sum') }), sumEl),
        h('button', { type: 'button', class: 'icon-btn', 'aria-label': tx('ui.admin.invoices.remove_line'), 'data-testid': 'invoice-line-remove', onclick: () => remove(index) }, icon('trash', 22))));
  }

  paint();
  return {
    node: block,
    // focus: false → vain merkitään virheet; kutsuja päättää, mikä kenttä saa fokuksen (lomakkeen ensimmäinen virhe).
    validateAndPayload({ focus = true } = {}) {
      state.showErrors = true;
      blockErr.textContent = '';
      for (const ln of state.lines) {
        const a = lineAmounts(ln);
        if (a && ln.basis === 'net') ln.price_gross = formatFiScaled(a.gross10000, 4, 2);
        else if (a) ln.price_net = formatFiScaled(a.net10000, 4, 2);
        ln.touched.description = true;
        ln.touched.quantity = true;
        ln.touched.price_net = true;
        ln.touched.price_gross = true;
        ln.touched.vat = true;
      }
      const all = state.lines.map((ln) => validateLine({ description: ln.description, quantity: ln.quantity, priceNet: ln.price_net, priceGross: ln.price_gross, vatRate: ln.vat_rate, rates: active, basis: ln.basis }));
      const bad = all.findIndex((e) => Object.keys(e).length);
      paint();
      if (bad >= 0) {
        if (focus) this.focusFirstError();
        return null;
      }
      return state.lines.map((ln) => lineToPayload(ln));
    },
    /** Ensimmäinen virheellinen rivikenttä näkyviin ja fokukseen. Palauttaa elementin tai null. */
    focusFirstError() {
      const el = lineBox.querySelector('[aria-invalid=true]') || (blockErr.textContent ? lineBox.querySelector('[data-testid=invoice-line-desc]') : null);
      if (!el) return null;
      el.scrollIntoView?.({ block: 'center' });
      el.focus?.({ preventScroll: true });
      return el;
    },
    /** Palvelimen rivivirhe (invalid_lines, invalid_vat): näkyvä viesti rivien yläpuolella. */
    setServerError(msg) {
      blockErr.textContent = msg || '';
    },
  };
}
