// booking_257/258: Hallinnan Viestit-sivun «Viesti asiakkaalle» -välilehti.
// booking_258: tuotevalinta vain valitun päivän/välin varatuista/myydyistä (ei katalogia).
import { rpc } from '../sb.js';
import { h, field, toast, run } from '../ui.js';
import { customerMessageText as T } from '../customer-message-texts.js';
import { newsletterText } from '../newsletter-texts.js';
import {
  CUSTOMER_MESSAGE_PLACEHOLDERS,
  fillCustomerMessage,
  validateCustomerMessageDraft,
  parseCustomerMessageDates,
  pruneSelectedProductIds,
  groupCustomerMessageProducts,
} from '../customer-message-logic.js';

const ERR = {
  invalid_dates: () => T('ui.admin.customer_message.error_dates'),
  invalid_products: () => T('ui.admin.customer_message.error_products'),
  invalid_text: () => T('ui.admin.customer_message.error_text'),
};

function fmtWhen(iso) {
  if (!iso) return '';
  try {
    return new Date(iso).toLocaleString('fi-FI', { timeZone: 'Europe/Helsinki' });
  } catch {
    return String(iso);
  }
}

function tabHref(id) {
  return id === 'pohjat' ? '#/viestit' : `#/viestit?valilehti=${id}`;
}

export function messagesTabBar(active) {
  return h('nav', { class: 'tl-tabs', 'aria-label': 'Viestit' },
    h('a', { href: tabHref('pohjat'), class: `tl-tabbtn${active === 'pohjat' ? ' active' : ''}`, 'data-testid': 'messages-tab-pohjat', text: T('ui.admin.customer_message.tab_templates') }),
    h('a', { href: tabHref('asiakkaalle'), class: `tl-tabbtn${active === 'asiakkaalle' ? ' active' : ''}`, 'data-testid': 'messages-tab-asiakkaalle', text: T('ui.admin.customer_message.tab') }),
    h('a', { href: tabHref('uutiskirje'), class: `tl-tabbtn${active === 'uutiskirje' ? ' active' : ''}`, 'data-testid': 'messages-tab-uutiskirje', text: newsletterText('tab') }),
  );
}

export function currentMessagesTab() {
  try {
    const q = new URLSearchParams((location.hash.split('?')[1] || '').replace(/#.*$/, ''));
    const t = q.get('valilehti');
    return t === 'asiakkaalle' || t === 'uutiskirje' ? t : 'pohjat';
  } catch {
    return 'pohjat';
  }
}

export async function renderCustomerMessagePanel({ wrap }) {
  const from = h('input', { type: 'date', required: true, 'data-testid': 'customer-message-from' });
  const to = h('input', { type: 'date', 'data-testid': 'customer-message-to' });
  const productHost = h('div', { class: 'msg-products', 'data-testid': 'customer-message-products' });
  const productStatus = h('p', {
    class: 'muted',
    'data-testid': 'customer-message-products-status',
    text: T('ui.admin.customer_message.products_need_dates'),
  });
  let boxes = [];
  let availableIds = [];
  let productFetchSeq = 0;

  function selectedIds() {
    return boxes.filter((el) => el.checked).map((el) => Number(el.value));
  }

  function paintProducts(products, keepIds) {
    const keep = new Set(pruneSelectedProductIds(keepIds, (products || []).map((p) => p.id)));
    boxes = [];
    availableIds = (products || []).map((p) => Number(p.id)).filter((n) => Number.isInteger(n) && n > 0);
    const { cats, grouped } = groupCustomerMessageProducts(products);
    productHost.replaceChildren(
      ...cats.map((cat) => {
        const items = grouped.get(cat);
        return h('fieldset', { class: 'box' },
          h('legend', { text: items[0]?.category_label || cat }),
          items.map((p) => {
            const cb = h('input', {
              type: 'checkbox', name: 'product', value: String(p.id),
              'data-testid': `customer-message-product-${p.id}`,
            });
            if (keep.has(Number(p.id))) cb.checked = true;
            cb.addEventListener('change', invalidate);
            boxes.push(cb);
            return h('label', { class: 'check' }, cb, ` ${p.name}${p.active === false ? ` ${T('ui.admin.customer_message.hidden')}` : ''}`);
          }));
      }),
    );
  }

  async function refreshProducts() {
    const my = ++productFetchSeq;
    const keep = selectedIds();
    invalidate();
    const parsed = parseCustomerMessageDates(from.value, to.value);
    if (!parsed.ok) {
      if (my !== productFetchSeq) return;
      boxes = [];
      availableIds = [];
      productHost.replaceChildren();
      productStatus.hidden = false;
      productStatus.textContent = T('ui.admin.customer_message.products_need_dates');
      return;
    }
    productStatus.hidden = false;
    productStatus.textContent = T('ui.admin.customer_message.products_loading');
    productHost.replaceChildren();
    boxes = [];
    availableIds = [];
    try {
      const rows = await rpc('admin_customer_message_products', {
        p_from: parsed.value.from,
        p_to: parsed.value.to,
      });
      if (my !== productFetchSeq) return;
      const products = Array.isArray(rows) ? rows : [];
      if (!products.length) {
        productStatus.textContent = T('ui.admin.customer_message.products_empty');
        productStatus.hidden = false;
        productHost.replaceChildren();
        return;
      }
      productStatus.hidden = true;
      productStatus.textContent = '';
      paintProducts(products, keep);
    } catch {
      if (my !== productFetchSeq) return;
      boxes = [];
      availableIds = [];
      productHost.replaceChildren();
      productStatus.hidden = false;
      productStatus.textContent = T('ui.admin.customer_message.products_error');
    }
  }

  const fields = {};
  const editor = h('div', { class: 'training-language-editors' }, ['fi', 'en'].map((lang) => {
    const subject = h('input', { maxlength: 200, required: true, 'data-testid': `customer-message-subject-${lang}` });
    const body = h('textarea', { rows: 8, maxlength: 4000, required: true, 'data-testid': `customer-message-body-${lang}` });
    fields[lang] = { subject, body };
    return h('fieldset', { class: 'card stack' },
      h('legend', { text: T(lang === 'fi' ? 'ui.admin.customer_message.lang_fi' : 'ui.admin.customer_message.lang_en') }),
      field(T('ui.admin.customer_message.subject'), subject),
      field(T('ui.admin.customer_message.body'), body));
  }));

  const previewHost = h('div', { class: 'card stack', 'data-testid': 'customer-message-preview', hidden: true });
  const confirm = h('input', { type: 'checkbox', 'data-testid': 'customer-message-confirm' });
  let previewOk = false;

  function draft() {
    return validateCustomerMessageDraft({
      from: from.value,
      to: to.value,
      productIds: pruneSelectedProductIds(selectedIds(), availableIds),
      subjectFi: fields.fi.subject.value,
      bodyFi: fields.fi.body.value,
      subjectEn: fields.en.subject.value,
      bodyEn: fields.en.body.value,
    });
  }

  function payload(v, confirmSend) {
    return {
      p_from: v.from,
      p_to: v.to,
      p_product_ids: v.product_ids,
      p_subject_fi: v.subject_fi,
      p_body_fi: v.body_fi,
      p_subject_en: v.subject_en,
      p_body_en: v.body_en,
      p_confirm: confirmSend,
    };
  }

  const send = h('button', {
    type: 'button', class: 'btn primary', 'data-testid': 'customer-message-send',
    text: T('ui.admin.customer_message.send'), disabled: true,
    onclick: (e) => run(e.target, async () => {
      const v = draft();
      if (!v.ok) throw new Error(ERR[v.code] ? ERR[v.code]() : v.code);
      if (!previewOk || !confirm.checked) throw new Error(T('ui.admin.customer_message.need_preview'));
      const res = await rpc('admin_customer_message_send', payload(v, true));
      toast(T('ui.admin.customer_message.sent'));
      invalidate();
      await drawLog();
      return res;
    }),
  });

  function invalidate() {
    previewOk = false;
    confirm.checked = false;
    send.disabled = true;
    previewHost.hidden = true;
  }

  from.addEventListener('change', refreshProducts);
  to.addEventListener('change', refreshProducts);
  from.addEventListener('input', invalidate);
  to.addEventListener('input', invalidate);
  ['fi', 'en'].forEach((lang) => {
    fields[lang].subject.addEventListener('input', invalidate);
    fields[lang].body.addEventListener('input', invalidate);
  });
  confirm.addEventListener('change', () => { send.disabled = !previewOk || !confirm.checked; });

  const logHost = h('div', { 'data-testid': 'customer-message-log' });
  async function drawLog() {
    let rows = [];
    try { rows = await rpc('admin_customer_messages_list') || []; } catch { rows = []; }
    if (!Array.isArray(rows)) rows = [];
    logHost.replaceChildren(
      h('h2', { text: T('ui.admin.customer_message.log') }),
      rows.length
        ? h('ul', {}, rows.map((m) => h('li', { text: `${fmtWhen(m.created_at)} · ${m.subject_fi} · ${m.queued_count}` })))
        : h('p', { class: 'muted', text: T('ui.admin.customer_message.log_empty') }),
    );
  }

  const previewBtn = h('button', {
    type: 'button', class: 'btn', 'data-testid': 'customer-message-preview-button',
    text: T('ui.admin.customer_message.preview'),
    onclick: (e) => run(e.target, async () => {
      const v = draft();
      if (!v.ok) throw new Error(ERR[v.code] ? ERR[v.code]() : v.code);
      const res = await rpc('admin_customer_message_send', payload(v, false));
      const rec = Array.isArray(res?.recipients) ? res.recipients : [];
      const skip = Array.isArray(res?.skipped) ? res.skipped : [];
      const parts = [
        h('p', { text: T('ui.admin.customer_message.preview_n').replace('{n}', String(res?.recipient_count ?? rec.length)) }),
        rec.length
          ? h('ul', {}, rec.map((x) => h('li', { text: `${x.name || '—'} · ${x.order_no || ''} · ${x.language || ''}` })))
          : h('p', { class: 'muted', text: T('ui.admin.customer_message.none') }),
      ];
      if (skip.length || Number(res?.skipped_count) > 0) {
        parts.push(h('p', { text: T('ui.admin.customer_message.skipped_n').replace('{n}', String(res?.skipped_count ?? skip.length)) }));
        if (skip.length) {
          parts.push(h('ul', {}, skip.map((x) => h('li', { text: `${x.name || '—'} · ${x.order_no || ''} · ${T('ui.admin.customer_message.no_email')}` }))));
        }
      }
      const sample = res?.preview;
      if (sample && (sample.subject_fi || sample.body_fi)) {
        parts.push(h('h3', { text: T('ui.admin.customer_message.sample') }));
        for (const lang of ['fi', 'en']) {
          const subject = sample[`subject_${lang}`] || fillCustomerMessage(v[`subject_${lang}`], sample.vars || {});
          const body = sample[`body_${lang}`] || fillCustomerMessage(v[`body_${lang}`], sample.vars || {});
          parts.push(h('pre', { class: 'ev-mail', text: `${subject}\n\n${body}` }));
        }
      }
      previewHost.hidden = false;
      previewHost.replaceChildren(...parts);
      previewOk = true;
      confirm.checked = false;
      send.disabled = true;
    }),
  });

  wrap.replaceChildren(
    messagesTabBar('asiakkaalle'),
    h('h1', { id: 'messages-h', text: T('ui.admin.customer_message.title') }),
    h('p', { class: 'muted', text: T('ui.admin.customer_message.lead_date_products') }),
    h('div', { class: 'row wrap' },
      field(T('ui.admin.customer_message.from'), from),
      field(T('ui.admin.customer_message.to'), to, T('ui.admin.customer_message.to_hint'))),
    h('fieldset', { class: 'box' },
      h('legend', { text: T('ui.admin.customer_message.products') }),
      h('div', { class: 'row wrap' },
        h('button', {
          type: 'button', class: 'btn ghost', 'data-testid': 'customer-message-select-all',
          text: T('ui.admin.customer_message.select_all'),
          onclick: () => { boxes.forEach((cb) => { cb.checked = true; }); invalidate(); },
        }),
        h('button', {
          type: 'button', class: 'btn ghost', 'data-testid': 'customer-message-clear',
          text: T('ui.admin.customer_message.clear'),
          onclick: () => { boxes.forEach((cb) => { cb.checked = false; }); invalidate(); },
        })),
      productStatus,
      productHost),
    editor,
    h('div', { class: 'box', 'data-testid': 'customer-message-placeholders' },
      h('strong', { text: T('ui.admin.customer_message.vars') }),
      h('ul', {}, CUSTOMER_MESSAGE_PLACEHOLDERS.map((p) => h('li', {}, h('code', { text: p.token }), ` ${T(p.helpKey)}`)))),
    h('div', { class: 'row wrap' }, previewBtn),
    previewHost,
    h('label', { class: 'check' }, confirm, T('ui.admin.customer_message.send_confirm')),
    h('div', { class: 'row wrap' }, send),
    logHost,
  );
  await drawLog();
}
