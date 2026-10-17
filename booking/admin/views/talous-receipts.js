// Talous › kuitit: PDF-lataus (receipt-pdf?t=<public_token>), kuitin teksti (admin_get_receipt) ja uudelleenlähetys (admin_resend_receipt).
// Käytetään sekä Tilaukset-näkymässä (maksujen alla) että Maksut-listassa. Sopimus: KOODARI_talous_A_D_fi.md §3, §9.1.
import { h, dialog, toast } from '../ui.js';
import { icon } from '../icons.js';
import { t, fmt } from '../talous-i18n.js';
import { friendly, loading, errorBox } from './talous-ui.js';

const ico = (name) => h('span', { class: 'tl-ico', 'aria-hidden': 'true' }, icon(name, 20));

// "Lataa kuitti (PDF)": tavallinen linkki edge-funktioon (verify_jwt=false) → avautuu uuteen välilehteen. short = lyhyt teksti listarivillä.
export function pdfLink({ api, token, no, short = false, testid = 'receipt-dl' }) {
  const href = api.receiptPdfUrl(token);
  if (!href) return null;
  return h('a', { class: 'btn tl-btn tl-rc-btn', href, target: '_blank', rel: 'noopener noreferrer', 'data-testid': testid, 'aria-label': `${t('receipt.download')} ${no || ''}`.trim(), title: t('receipt.pdfOpens') },
    ico('download'), h('span', { text: t(short ? 'receipt.downloadShort' : 'receipt.download') }));
}

// kuitin yksi rivi: numero, laji, päivä, summa + toiminnot
export function receiptItem({ api, ctx, receipt: r }) {
  return h('li', { 'data-testid': 'receipt-item', 'data-receipt-no': r.receipt_no },
    h('span', { class: 'tl-sub-main' }, h('strong', { 'data-testid': 'receipt-no', text: r.receipt_no }), ' ', h('span', { class: `badge${r.kind === 'refund_receipt' ? ' warn' : ''}`, text: t(`receipt.${r.kind}`) })),
    h('span', { class: 'tl-sub-meta', text: [fmt.dt(r.issued_at), r.sent_at ? `${t('receipts.sent')} ${fmt.date(r.sent_at)}` : t('receipts.notSent')].join(' · ') }),
    h('span', { class: 'tl-sub-sum' }, r.total != null ? h('strong', { 'data-testid': 'receipt-total', text: fmt.money(r.total) }) : null),
    h('div', { class: 'tl-rc-actions' }, ...receiptActions({ api, ctx, receipt: r })));
}
export function receiptActions({ api, ctx, receipt: r, short = true }) {
  return [pdfLink({ api, token: r.public_token, no: r.receipt_no, short }), viewButton({ api, ctx, receipt: r, short }), resendButton({ api, ctx, receipt: r, short })];
}
export function receiptsList({ api, ctx, receipts, testid = 'order-receipts' }) {
  return receipts.length ? h('ul', { class: 'tl-sub tl-rc', 'data-testid': testid }, receipts.map((receipt) => receiptItem({ api, ctx, receipt }))) : h('p', { class: 'empty tl-empty', role: 'status', 'data-testid': `${testid}-none`, text: t('receipts.none') });
}

export function viewButton({ api, ctx, receipt: r, short = false }) {
  return h('button', { type: 'button', class: 'btn tl-btn tl-rc-btn', 'data-testid': 'receipt-view', 'aria-label': `${t('receipt.view')} ${r.receipt_no}`, onclick: () => showReceipt({ api, ctx, receipt: r }) },
    ico('eye'), h('span', { text: t(short ? 'receipt.viewShort' : 'receipt.view') }));
}
export function resendButton({ api, ctx, receipt: r, short = false }) {
  const noPerm = api.isMock('resendReceipt') || ctx?.can?.('payments.manage') ? null : t('resend.noPerm');
  return h('button', { type: 'button', class: `btn tl-btn tl-rc-btn${noPerm ? ' is-off' : ''}`, 'data-testid': 'receipt-resend', disabled: noPerm ? true : null, title: noPerm, 'aria-label': `${t('receipt.resend')} ${r.receipt_no}`, onclick: () => resendDialog({ api, receipt: r }) },
    ico('mail'), h('span', { text: t(short ? 'receipt.resendShort' : 'receipt.resend') }));
}

// kopiointi: Clipboard API, varalla valinta + execCommand (http / rajoitetut selaimet)
async function copyText(text, node) {
  try { await navigator.clipboard.writeText(text); return true; } catch { /* varakeino */ }
  try { const range = document.createRange(); range.selectNodeContents(node); const sel = getSelection(); sel.removeAllRanges(); sel.addRange(range); return document.execCommand('copy'); } catch { return false; }
}

// "Näytä kuitti": snapshotista muodostettu teksti (text_body), kopioitava
export function showReceipt({ api, ctx, receipt: r }) {
  const box = h('div', { class: 'stack tl-rc-dialog', 'data-testid': 'receipt-dialog' }, loading());
  const d = dialog(t('receipt.dialogTitle', { no: r.receipt_no }), box, { wide: true });
  const load = async () => {
    box.replaceChildren(loading());
    try {
      const rc = await api.getReceipt(r.id);
      const pre = h('pre', { class: 'tl-rc-text', tabindex: '0', 'data-testid': 'receipt-text', 'aria-label': t('receipt.text'), text: rc.text_body || t('receipt.noText') });
      const copy = h('button', { type: 'button', class: 'btn tl-btn tl-rc-btn', 'data-testid': 'receipt-copy', disabled: rc.text_body ? null : true, onclick: async () => { toast(await copyText(rc.text_body, pre) ? t('receipt.copied') : t('receipt.copyFailed'), 'ok'); } }, ico('copy'), h('span', { text: t('receipt.copy') }));
      box.replaceChildren(
        h('p', { class: 'muted tl-meta', text: [t(`receipt.${rc.kind}`), fmt.dt(rc.issued_at), fmt.money(rc.total), rc.sent_at ? `${t('receipts.sent')} ${fmt.date(rc.sent_at)}` : t('receipts.notSent')].join(' · ') }), pre,
        h('div', { class: 'tl-actions' }, copy, pdfLink({ api, token: rc.public_token || r.public_token, no: rc.receipt_no }), resendButton({ api, ctx, receipt: { ...r, ...rc } })));
    } catch (e) { box.replaceChildren(h('p', { class: 'err', role: 'alert', text: t('receipt.loadFailed') }), errorBox(e, load)); }
  };
  load();
  return d;
}

// "Lähetä kuitti uudelleen": vahvistus → admin_resend_receipt → tulosviesti. Kertoo myös jos sähköpostin lähetys on testitilassa/pois (integration_config.resend.mode).
export function resendDialog({ api, receipt: r }) {
  const modeBox = h('p', { class: 'tl-banner', role: 'status', 'data-testid': 'resend-mode', text: t('resend.mode.unknown') });
  let modeKnown = 'unknown';
  api.resendMode().then((m) => { modeKnown = m || 'unknown'; modeBox.textContent = t(`resend.mode.${modeKnown}`); modeBox.dataset.mode = modeKnown; if (modeKnown === 'live') modeBox.classList.remove('tl-banner'); }).catch(() => {});
  const body = h('div', { class: 'stack', 'data-testid': 'resend-dialog' });
  const close = h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'resend-cancel', onclick: () => d.close() }, t('resend.cancel'));
  const submit = h('button', { type: 'button', class: 'btn primary', 'data-testid': 'resend-submit', text: t('resend.submit'), onclick: async () => {
    submit.disabled = true;
    try {
      const res = await api.resendReceipt(r.id);
      const queued = res?.email_queued !== false;
      body.replaceChildren(h('p', { class: queued ? '' : 'err', role: 'status', 'data-testid': 'resend-result', 'data-queued': String(queued), text: queued ? t('resend.queued', { no: r.receipt_no }) : t('resend.notQueued') }),
        queued ? modeBox : null, res?.mock ? h('p', { class: 'muted', text: t('mock.note') }) : null, h('div', { class: 'tl-actions' }, h('button', { type: 'button', class: 'btn primary', 'data-testid': 'resend-close', onclick: () => d.close() }, t('resend.close'))));
    } catch (e) { submit.disabled = false; toast(friendly(e), 'err'); }
  } });
  body.replaceChildren(h('p', { text: t('resend.confirm', { no: r.receipt_no }) }), modeBox, h('div', { class: 'tl-actions' }, close, submit));
  const d = dialog(t('resend.title'), body);
  return d;
}
