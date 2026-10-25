// Maksulinkkisivu /maksa/?p=<link_token> (EN /en/pay/?p=…). Sähköpostin maksulinkit (settings.payment_link_path), hallinnan ja pikakassan linkit.
// Ei omaa tietokantakutsua: painike kutsuu vismapay-start {link_token} (sama edge kuin tilaussivun Visma-painike) ja ohjaa Visma Payn sivulle,
// jossa summa ja viite näkyvät. Maksua ei avata ilman painalluksen (sähköpostin linkkiesikatselu ei luo maksua). Virheet (vanhentunut, maksettu, virheellinen) FI/EN.
import { functionUrl } from './sb.js';
import { h } from './gift-ui.js';
import { createVismapayApi } from './vismapay-api.js';
import { safeVismaRedirect } from './vismapay-logic.js';
import { PLT, plt } from './pay-link-texts.js';
import { linkTokenFrom, classifyLinkError, switchHref } from './pay-link-logic.js';
import { applyShopTexts } from './site-texts.js';

export function payLinkView({ L, token, api, phone = '', phoneTel = '', navigate = (u) => location.assign(u), money = (n) => String(n) }) {
  const tx = (k, v) => plt(L, k, v);
  const msg = h('div', { class: 'ord-msg', 'aria-live': 'polite', 'data-testid': 'pl-msg' });
  const contact = h('p', { class: 'bk-note', 'data-testid': 'pl-contact' }, `${tx('contact')} `, phone ? h('a', { href: `tel:${phoneTel || phone.replace(/\s+/g, '')}`, text: phone }) : null);
  const showError = (code) => {
    const c = classifyLinkError(code);
    msg.replaceChildren(h('p', { class: 'bk-error', role: 'alert', 'data-testid': 'pl-error', 'data-code': String(code || 'generic'), text: tx(c.key) }));
    return c;
  };
  let busy = false;
  const btn = h('button', { type: 'button', class: 'btn ord-btn', 'data-testid': 'pl-button', text: tx('btn'), onclick: async () => {
    if (busy) return;
    busy = true; btn.disabled = true; btn.textContent = tx('busy'); msg.replaceChildren();
    let r = null;
    try { r = await api.start(); } catch { r = { ok: false, code: 'network' }; }
    const url = r?.ok ? safeVismaRedirect(r.redirect_url) : null;
    if (url) {
      msg.replaceChildren(h('p', { class: 'bk-note', role: 'status', 'data-testid': 'pl-redirect', text: tx('redirecting') }),
        r.amount != null ? h('p', { class: 'mp-amount', 'data-testid': 'pl-amount', text: tx('amount', { amount: money(r.amount) }) }) : null);
      navigate(url);
      return;
    }
    if (r?.ok && (r.dry_run || r.mode === 'dry_run')) {
      msg.replaceChildren(h('p', { class: 'bk-note', role: 'status', 'data-testid': 'pl-dryrun', text: tx('dryRun') }));
      busy = false; btn.disabled = false; btn.textContent = tx('btn');
      return;
    }
    const c = showError(r?.ok ? 'generic' : r?.code);
    if (c.final) btn.remove();   // lopullinen tila: uusi yritys ei auta (.btn-tyyli ohittaisi hidden-attribuutin)
    busy = false; btn.disabled = false; btn.textContent = tx('btn');
  } });
  const card = h('section', { class: 'ord-card', 'data-testid': 'pay-link-page', 'aria-labelledby': 'pl-title' },
    h('h3', { id: 'pl-title', text: tx('title') }),
    h('p', { text: tx('lead') }), btn, msg, contact);
  if (!token) { showError('invalid_param'); btn.remove(); }
  return card;
}

async function main() {
  const S = window.BOOKING_SHOP || {};
  const L = PLT[S.lang] ? S.lang : 'fi';
  const root = document.getElementById('pay-link-app');
  if (!root) return;
  try { await applyShopTexts(S); } catch { /* repon oletustekstit */ }
  const token = linkTokenFrom(location.search);
  // kielivalinta säilyttää ?p= (FI /maksa/ ↔ EN /en/pay/)
  if (S.otherHref) for (const a of document.querySelectorAll('.lang a[hreflang]')) a.setAttribute('href', switchHref(S.otherHref, location.search));
  const cfg = window.BOOKING_CONFIG || {};
  const api = createVismapayApi({ linkToken: token, functionUrl, anonKey: cfg.anonKey });
  const money = (n) => new Intl.NumberFormat(L === 'fi' ? 'fi-FI' : 'en-GB', { style: 'currency', currency: 'EUR' }).format(+n || 0);
  root.replaceChildren(payLinkView({ L, token, api, phone: S.phone, phoneTel: S.phoneTel, money }));
  root.setAttribute('aria-busy', 'false');
}

if (typeof window !== 'undefined' && typeof document !== 'undefined' && window.BOOKING_SHOP?.page === 'paylink') main();
