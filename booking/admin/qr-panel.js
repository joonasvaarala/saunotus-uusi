// Asetukset › QR-koodin tulostus. Esikatselu on samalla sivulla. Tulostus on selaimen oma tulostus, ei uutta ikkunaa.
import { rpc } from './sb.js';
import { h, toast, errMsg, money } from './ui.js';
import { settingsText as tx } from './settings-texts.js';
import { filterProducts, qrEligible } from './pos-logic.js';
import { printSheetHtml, printSheetSvg } from './qr-print.js';
import { qrSvgElement } from './qrsvg.js';

function downloadBlob(filename, blob) {
  const a = document.createElement('a');
  const url = URL.createObjectURL(blob);
  a.href = url;
  a.download = filename;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1500);
}

function svgToPngBlob(markup) {
  return new Promise((resolve, reject) => {
    const blob = new Blob([markup], { type: 'image/svg+xml;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const img = new Image();
    img.onload = () => {
      const canvas = document.createElement('canvas');
      const w = 1200;
      const h = Math.max(1, Math.round(w * (img.naturalHeight || img.height) / (img.naturalWidth || img.width || 1)));
      canvas.width = w;
      canvas.height = h;
      const g = canvas.getContext('2d');
      g.fillStyle = '#ffffff';
      g.fillRect(0, 0, w, h);
      g.drawImage(img, 0, 0, w, h);
      canvas.toBlob((b) => {
        URL.revokeObjectURL(url);
        if (b) resolve(b);
        else reject(new Error('png'));
      }, 'image/png');
    };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('svg')); };
    img.src = url;
  });
}

export async function renderQrPanel() {
  const t = (k) => tx(`ui.admin.qr.${k}`);
  let products = [];
  let codes = [];
  let query = '';
  let picked = null;
  let label = '';
  const chosen = new Set();

  async function load() {
    const [list, rows] = await Promise.all([
      rpc('admin_list_products'),
      rpc('admin_list_product_qr'),
    ]);
    products = Array.isArray(list) ? list : [];
    codes = Array.isArray(rows) ? rows : [];
    for (const id of [...chosen]) if (!codes.some((c) => c.id === id)) chosen.delete(id);
    if (!chosen.size) for (const c of codes) if (c.active) chosen.add(c.id);
  }

  function selectedItems() {
    return codes.filter((c) => chosen.has(c.id)).map((c) => ({
      name: c.name,
      priceText: money(c.price),
      url: c.print_url || c.path,
      label: c.label || '',
    }));
  }

  function drawSheet(root) {
    const items = selectedItems();
    root.replaceChildren();
    if (!items.length) {
      root.append(h('p', { class: 'muted', text: codes.length ? t('pick') : t('empty') }));
      return;
    }
    const sheet = h('div', { class: 'qr-sheet', 'data-testid': 'qr-sheet' });
    for (const it of items) {
      const card = h('article', { class: 'qr-card', 'data-url': it.url });
      card.append(
        h('h2', { text: it.name }),
        h('p', { class: 'qr-price', text: it.priceText }),
        it.label ? h('p', { class: 'qr-where', text: it.label }) : null,
        qrSvgElement(it.url, { size: 280, label: it.name }),
        h('p', { class: 'qr-scan', text: t('scan') }),
      );
      sheet.append(card);
    }
    root.append(sheet);
    root.dataset.sheet = printSheetHtml(items, { scan: t('scan'), empty: t('empty') });
  }

  const preview = h('div', { class: 'qr-print-root', 'data-testid': 'qr-preview' });
  const listBox = h('div', { class: 'stack' });
  const hits = h('div', { class: 'stack', 'data-testid': 'qr-hits' });

  function paint() {
    const q = filterProducts(products.filter(qrEligible), query);
    hits.replaceChildren(...q.slice(0, 30).map((p) => h('button', {
      type: 'button', class: 'btn qr-hit' + (picked === p.id ? ' is-on' : ''), 'data-testid': `qr-hit-${p.id}`,
      onclick: () => { picked = p.id; paint(); },
    }, h('span', { class: 'grow', text: p.name }), h('span', { text: money(p.price) }), p.config?.shop_visible === false ? h('small', { text: t('hidden') }) : null)));
    if (!q.length) hits.append(h('p', { class: 'muted', text: t('pick') }));

    listBox.replaceChildren();
    if (!codes.length) listBox.append(h('p', { 'data-testid': 'qr-empty', text: t('empty') }));
    for (const c of codes) {
      const box = h('input', { type: 'checkbox', checked: chosen.has(c.id) || null, 'aria-label': t('include') });
      box.addEventListener('change', () => { if (box.checked) chosen.add(c.id); else chosen.delete(c.id); drawSheet(preview); });
      listBox.append(h('div', { class: 'qr-row' },
        h('label', { class: 'qr-inc' }, box, h('span', { class: 'sr', text: t('include') })),
        h('span', { class: 'grow' }, h('strong', { text: c.name }), h('small', { text: c.label ? ` · ${c.label}` : '' }), h('small', { text: ` · ${money(c.price)}` })),
        h('button', { type: 'button', class: 'btn danger', text: t('remove'), 'data-testid': `qr-del-${c.id}`, onclick: () => rpc('admin_delete_product_qr', { p_id: c.id }).then(async () => { toast(t('removed')); await load(); paint(); }).catch((e) => toast(errMsg(e))) })));
    }
    drawSheet(preview);
  }

  const search = h('input', { type: 'search', 'aria-label': t('search'), 'data-testid': 'qr-search', oninput: (e) => { query = e.target.value; paint(); } });
  const labelInp = h('input', { type: 'text', maxlength: 120, placeholder: t('label_ph'), 'aria-label': t('label'), 'data-testid': 'qr-label', oninput: (e) => { label = e.target.value; } });
  const create = h('button', {
    type: 'button', class: 'btn primary qr-create', 'data-testid': 'qr-create', text: t('create'),
    onclick: () => {
      if (!picked) { toast(t('pick')); return; }
      const product = products.find((p) => p.id === picked);
      if (!qrEligible(product)) { toast(t('age')); return; }
      rpc('admin_create_product_qr', { p_product_id: picked, p_label: label.trim() || null })
        .then(async (row) => { toast(t('saved')); label = ''; labelInp.value = ''; picked = null; if (row?.id) chosen.add(row.id); await load(); paint(); })
        .catch((e) => toast(errMsg(e)));
    },
  });

  await load();
  paint();

  const actions = h('div', { class: 'qr-actions set-noprint' },
    h('button', { type: 'button', class: 'btn primary', 'data-testid': 'qr-print', text: t('print'), onclick: () => { if (!selectedItems().length) { toast(t('pick')); return; } window.print(); } }),
    h('button', { type: 'button', class: 'btn', 'data-testid': 'qr-svg', text: t('download_svg'), onclick: () => {
      const items = selectedItems();
      if (!items.length) { toast(t('pick')); return; }
      downloadBlob('qr.svg', new Blob([printSheetSvg(items, { scan: t('scan') })], { type: 'image/svg+xml' }));
    } }),
    h('button', { type: 'button', class: 'btn', 'data-testid': 'qr-png', text: t('download_png'), onclick: () => {
      const items = selectedItems();
      if (!items.length) { toast(t('pick')); return; }
      svgToPngBlob(printSheetSvg(items, { scan: t('scan') })).then((b) => downloadBlob('qr.png', b)).catch((e) => toast(errMsg(e)));
    } }));

  return h('div', { 'data-testid': 'qr-panel' },
    h('p', { class: 'muted set-noprint', text: t('lead') }),
    h('div', { class: 'stack set-noprint' },
      h('label', { class: 'fld' }, h('span', { text: t('search') }), search),
      hits,
      h('label', { class: 'fld' }, h('span', { text: t('label') }), labelInp),
      create,
      h('h2', { text: t('sheet') }),
      listBox),
    h('h2', { class: 'set-noprint', text: t('preview') }),
    actions,
    preview);
}
