// Asetuskortit, jotka asuvat asian omassa näkymässä (HALL-ASETUKSET-01): sähköpostin lähettäjä Viesteissä, lahjakorttiasetukset Lahjakorteissa.
// Sama admin_save_settings-polku ja samat tarkistukset kuin ennen; yksi tallennuspalkki per paneeli. Vaatii settings.edit.
import { rpc } from './sb.js';
import { h, field, toast, run } from './ui.js';
import { loadVcrTexts, vcrText } from './voucher-redeem-texts.js';
import { VCR_SELLERS, VCR_RPC, VCR_URL_MAX, sellerLabel, checkRedeemUrls } from './voucher-redeem-logic.js';
import { loadSettingsTexts } from './settings-texts.js';
import { splitFrom } from './settings-logic.js';
import { createSaveBar } from './settings-savebar.js';
import { tx, toggle, num, textField, card, stat } from './settings-widgets.js';

// booking_173: kumppanien lunastussivut (asetus voucher_claims.redeem_urls; admin_set_voucher_redeem_urls). Oma tallennus.
function redeemUrlsCard() {
  const inputs = Object.fromEntries(VCR_SELLERS.map((k) => [k, h('input', { type: 'url', inputmode: 'url', autocomplete: 'off', maxlength: String(VCR_URL_MAX), placeholder: 'https://', 'data-testid': `redeem-url-${k}` })]));
  const err = h('p', { class: 'err', role: 'alert', hidden: true, 'data-testid': 'redeem-urls-err' });
  const save = h('button', { type: 'button', class: 'btn primary', 'data-testid': 'save-redeem-urls', text: vcrText('ui.admin.vcr.urls_save') });
  save.addEventListener('click', () => run(save, async () => {
    const chk = checkRedeemUrls(Object.fromEntries(VCR_SELLERS.map((k) => [k, inputs[k].value])));
    if (!chk.ok) { err.textContent = vcrText('ui.admin.vcr.urls_bad', { sources: chk.bad.map((k) => sellerLabel(k)).join(', ') }); err.hidden = false; return; }
    err.hidden = true;
    const res = await rpc(VCR_RPC.setUrls, { p: chk.value });
    for (const k of VCR_SELLERS) inputs[k].value = res?.redeem_urls?.[k] || '';
    toast(vcrText('ui.admin.vcr.urls_saved'));
  }));
  const node = card(vcrText('ui.admin.vcr.urls_title'), vcrText('ui.admin.vcr.urls_lead'),
    h('div', { class: 'stack', 'data-testid': 'redeem-urls' }, VCR_SELLERS.map((k) => field(sellerLabel(k), inputs[k]))), err, save);
  rpc(VCR_RPC.unredeemed, { p_limit: 1 }).then((v) => { for (const k of VCR_SELLERS) if (!inputs[k].value) inputs[k].value = v?.redeem_urls?.[k] || ''; }).catch(() => { /* vanha tietokanta: kentät tyhjinä */ });
  return node;
}

async function loadBundle() {
  await loadSettingsTexts(rpc);
  return rpc('admin_settings_bundle');
}

export async function mailSettingsPanel({ reload } = {}) {
  let bundle = null;
  try { bundle = await loadBundle(); } catch { bundle = null; }
  if (!bundle?.settings) return h('p', { class: 'err', role: 'alert', text: tx('load_failed') });
  const s = bundle.settings;
  const from = splitFrom(bundle.resend?.from) || { name: '', email: '' };
  const name = textField(tx('mail_from'), from.name, null, { testid: 'from-name' });
  const reply = textField(tx('mail_reply'), bundle.resend?.reply_to, null, { type: 'email', testid: 'reply-to' });
  const quoteEmail = textField(tx('quote_email'), s.business_quote_notify_email, null, { type: 'email' });
  const quoteName = textField(tx('quote_name'), s.business_quote_notify_name);
  const bar = createSaveBar({ reload, testid: 'mail-settings-bar' });
  const root = h('section', { class: 'stack set-page set-embedded', 'data-testid': 'mail-settings' },
    h('h2', { text: tx('mail_from_title') }),
    h('p', { class: 'muted', text: tx('mail_sender_note') }),
    card(tx('mail_from_title'), null, name.node, stat(tx('mail_from_locked'), h('b', { text: from.email || '–' })), reply.node),
    card(tx('quote_title'), tx('quote_help'), quoteEmail.node, quoteName.node), bar.node);
  bar.section('email_sender', () => ({ from_name: name.input.value, reply_to: reply.input.value }));
  bar.section('email_staff', () => ({ business_quote_notify_email: quoteEmail.input.value, business_quote_notify_name: quoteName.input.value }));
  bar.watch(root);
  return root;
}

export async function giftSettingsPanel({ reload } = {}) {
  let bundle = null;
  try { bundle = await loadBundle(); await loadVcrTexts(rpc); } catch { bundle = null; }
  if (!bundle?.settings) return h('p', { class: 'err', role: 'alert', text: tx('load_failed') });
  const s = bundle.settings;
  const sale = toggle(tx('gift_sale'), null, s['gift_cards.sale_enabled'] === true, { testid: 'gift-sale', confirmOn: tx('gift_confirm_sale') });
  const redeem = toggle(tx('gift_redeem'), null, s['gift_cards.redeem_enabled'] === true, { testid: 'gift-redeem', confirmOn: tx('gift_confirm_redeem') });
  const max = num(tx('gift_max'), s['gift_cards.max_cards_per_order'], tx('unit_cards'), 1, 30);
  const per = num(tx('partner_max'), s['voucher_claims.max_per_order'], tx('unit_cards'), 1, 30);
  const remind = num(tx('partner_remind'), s['voucher_claims.remind_after_hours'], tx('unit_hours'), 1, 720);
  const packs = Array.isArray(bundle.gift_packages) ? bundle.gift_packages : [];
  const bar = createSaveBar({ reload, testid: 'gift-settings-bar' });
  const root = h('section', { class: 'stack set-page set-embedded', 'data-testid': 'panel-lahjakortit' },
    card(tx('gift_title'), tx('gift_help'), sale.row, redeem.row, max.node),
    card(tx('partner_title'), null, per.node, remind.node),
    card(tx('gift_valid_title'), tx('gift_valid_help'),
      packs.length ? h('div', {}, packs.map((p) => stat(p.name, h('b', { text: `${p.valid_months} ${tx('unit_months')}` })))) : h('p', { class: 'muted', text: '–' })),
    redeemUrlsCard(), bar.node);
  bar.section('gift_own', () => ({ sale_enabled: sale.input.checked, redeem_enabled: redeem.input.checked, max_cards_per_order: Number(max.input.value) }));
  bar.section('gift_partner', () => ({ max_per_order: Number(per.input.value), remind_after_hours: Number(remind.input.value) }));
  bar.watch(root);
  return root;
}
