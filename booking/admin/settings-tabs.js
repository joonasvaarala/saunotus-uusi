// Asetusten välilehdet. Puhdas moduuli: ei DOM:ia. Oikeus settings.edit näkee asetusryhmät,
// pos.use tai settings.edit näkee QR-tulostuksen. Tuntematon avain jää Yleisiin, jotta mitään riviä ei katoa.
import { parseAdminHash } from './reservation-query.js';

export const TAB_ORDER = ['yleiset', 'varaukset', 'maksut', 'sahkoposti', 'laskutus', 'kirjanpito', 'lahjakortit', 'rajat', 'qr'];

const PAYMENT_KEYS = new Set([
  'public_payment_mode', 'hold_minutes', 'pay_later_test_enabled', 'payment_link_path',
  'checkout_hold_minutes', 'checkout_mobilepay_grace_minutes', 'checkout_mobilepay_max_wait_minutes',
]);

export function groupSettingKey(key) {
  const k = String(key || '');
  if (k.startsWith('rl_') || k.includes('_rl_') || k.includes('.rl_')) return 'rajat';
  if (k.startsWith('invoice_') || k === 'checkout_company_invoice_enabled') return 'laskutus';
  if (k.startsWith('gift_cards.') || k.startsWith('voucher_claims.')) return 'lahjakortit';
  if (k === 'seller' || k === 'receipt_series') return 'kirjanpito';
  if (k.startsWith('business_quote_notify_')) return 'sahkoposti';
  if (k.startsWith('public_treatment_') || k.startsWith('checkout_group_') || k === 'customer_change_hours_before' || k === 'annual_card_max_persons') return 'varaukset';
  if (PAYMENT_KEYS.has(k) || k.startsWith('checkout_mobilepay_') || k.startsWith('checkout_hold_')) return 'maksut';
  return 'yleiset';
}

export function visibleSettingTabs({ can, keys = [] } = {}) {
  const allow = typeof can === 'function' ? can : () => false;
  const groups = new Set((keys || []).map(groupSettingKey));
  const seeSettings = allow('settings.edit');
  const seeQr = allow('pos.use') || allow('settings.edit');
  return TAB_ORDER.filter((id) => {
    if (id === 'qr') return seeQr;
    if (!seeSettings) return false;
    if (id === 'kirjanpito') return true;
    return groups.has(id);
  });
}

export function settingsHref(tab) {
  return `#/asetukset/${tab}`;
}

export function tabFromHash(hash, tabs) {
  const list = tabs || [];
  const { path, rest } = parseAdminHash(hash);
  const id = path === 'asetukset' ? String(rest || '').split('/')[0] : '';
  if (list.includes(id)) return id;
  return list[0] || '';
}
